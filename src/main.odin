package sprite_renderer

// The code not really relevant to the rendering, like defining our sprites,
// tick and input can be found in `non_renderer_code.odin`

import "base:runtime"

import "core:c"
import "core:fmt"
import "core:slice"
import "core:time"

import stbi "vendor:stb/image"

import sapp "third_party/sokol/app"
import sg "third_party/sokol/gfx"
import sglue "third_party/sokol/glue"
import slog "third_party/sokol/log"

import "shaders"

// Our renderer will have a resolution of 320x180, 16:9
// - 40 tiles wide
// - 22.5 tiles high, with the half tile being on the top
TILES_X :: 40
TILES_Y :: 22.5
TILE_UNIT :: 8
GAME_WIDTH :: TILES_X * TILE_UNIT
GAME_HEIGHT :: TILES_Y * TILE_UNIT

// I just like having this so I don't accidentally define my quads incorrectly
QUAD_INDEX_SIZE :: 6

BUDGET_SPRITES :: 1024

Sprite_Batch :: struct {
    // Odin uses manual memory management but there is no memory to manage if it's in "rodata" heh!
    // We could also use `[dynamic]` in combination with the `temp_allocator` and begin our frame with
    // `defer free_all(context.temp_allocator)`, whatever floats your boat.
    // I like the idea of having a "budget" for small games.
    // https://odin-lang.org/docs/overview/#allocators
    instances: [BUDGET_SPRITES]Sprite_Instance,
    len:       uint,
}

// This is the thing we will upload to the GPU!
Sprite_Instance :: struct {
    location: [2]f32,
    size:     [2]f32,
    position: [2]f32,
    scale:    [2]f32,
    color:    [4]f32,
}

// This is what we render our game to
Offscreen :: struct {
    pixel_to_viewport_multiplier: [2]f32,
    sprite_atlas_size:            [2]i32,
    pass:                         sg.Pass,
    pipeline:                     sg.Pipeline,
    bindings:                     sg.Bindings,
}

// Our display scales up the `Offscreen` to match our physical display
Display :: struct {
    pass_action: sg.Pass_Action,
    pipeline:    sg.Pipeline,
    bindings:    sg.Bindings,
}

Renderer :: struct {
    offscreen:    Offscreen,
    display:      Display,
    sprite_batch: Sprite_Batch,
}

///////////////////////////////////////////////////////////////////////////////

// Global struct to store the things we need to render
renderer: Renderer

// see `not_renderer_code.odin`
timer: Timer
input: Input

///////////////////////////////////////////////////////////////////////////////

// https://odin-lang.org/docs/overview/#calling-conventions
init :: proc "c" () {
    // https://odin-lang.org/docs/overview/#explicit-context-definition
    context = runtime.default_context()

    sg.setup({environment = sglue.environment(), logger = {func = slog.func}})

    ////////////////////////////////////////////////////////////////////////////
    // Offscreen renderer
    // The offscreen renderer renders our game to a low resolution
    // "render target.
    // This render target is used as a texture in the display renderer to do a
    // pixel perfact upscale as close as possible to the window size.

    ////////////////////////////////////////////////////////////////////////////

    assert(GAME_WIDTH > 0, fmt.tprintf("game_width > 0: %v", GAME_WIDTH))
    assert(GAME_HEIGHT > 0, fmt.tprintf("game_height > 0: %v", GAME_HEIGHT))
    // This is a multiplier to translate our GAME coordinates to viewport coordinates
    pixel_to_viewport_multiplier := gfx_get_pixel_to_viewport_multiplier(
        GAME_WIDTH,
        GAME_HEIGHT,
    )

    OFFSCREEN_PIXEL_FORMAT :: sg.Pixel_Format.RGBA8
    OFFSCREEN_SAMPLE_COUNT :: 1

    ////////////////////////////////////////////////////////////////////////////
    // `render_target` is a color attachment in the offscreen rendering pass.
    // But also a fragement shader texture in the display rendering pass.
    // Everything that is rendered in our GAME is rendered to this image.
    image_description := sg.Image_Desc {
        render_target = true,
        width         = i32(GAME_WIDTH),
        height        = i32(GAME_HEIGHT),
        pixel_format  = OFFSCREEN_PIXEL_FORMAT,
        sample_count  = OFFSCREEN_SAMPLE_COUNT,
        label         = "color-image-render-target",
    }
    render_target := sg.make_image(image_description)

    // Depth stencil for alpha blending, so we can have transparent sprites.
    image_description.pixel_format = .DEPTH
    image_description.label = "depth-image-render-target"
    depth_image := sg.make_image(image_description)

    // Attach the render target to our offscreen pass.
    offscreen_pass := sg.Pass {
        attachments = sg.make_attachments(
            {
                colors = {0 = {image = render_target}},
                depth_stencil = {image = depth_image},
                label = "offscreen-attachments",
            },
        ),
        action = {
            colors = {
                0 = {
                    load_action = .CLEAR,
                    clear_value = sg.Color{0.2, 0.2, 0.2, 1},
                },
            },
        },
        label = "offscreen-pass",
    }

    // Single quad reused by all our sprites.
    // odinfmt: disable
    // The `offscreen_index_buffer_vertices` will map the values
    // `0, 1, 3` and `1, 2, 3` to these coordinates.
    offscreen_vertex_buffer_vertices := [8]f32{
        1, 1, // [0]
        1, 0, // [1]
        0, 0, // [2]
        0, 1, // [3]
    }
    // Two triangles creates a quad
    // [2] {0, 0}    [1] {1, 0}
    //  \            /
    //   x----------x
    //   |         /|
    //   |  2    /  |
    //   |     /    |
    //   |   /   1  |
    //   | /        |
    //   x__________x
    //  /            \
    // [3] {0, 1}   [0] {1, 1}
    offscreen_index_buffer_vertices := [6]u16{
        0, 1, 3, // triangle 1
        1, 2, 3, // triangle 2
    }
    // odinfmt: enable

    offscreen_vertex_buffer := sg.make_buffer(
        {
            type = .VERTEXBUFFER,
            data = as_range(&offscreen_vertex_buffer_vertices),
            label = "offscreen-vertex-buffer",
        },
    )

    offscreen_index_buffer := sg.make_buffer(
        {
            type = .INDEXBUFFER,
            data = as_range(&offscreen_index_buffer_vertices),
            label = "offscreen-index-buffer",
        },
    )

    // Another vertex buffer, instanced for all data for each sprite.
    // see `usage = .STREAM`
    // This buffer will contain the actual position, color, size etc.
    // We will put a bunch of `Sprite_Instance`s in this each frame.
    offscreen_instance_buffer := sg.make_buffer(
        {
            usage = .STREAM,
            type = .VERTEXBUFFER,
            size = BUDGET_SPRITES * size_of(Sprite_Instance),
            label = "offscreen-instance-buffer",
        },
    )

    // Offscreen pipeline
    offscreen_pipeline := sg.make_pipeline(
        {
            layout = {
                buffers = {1 = {step_func = .PER_INSTANCE}},
                attrs = {
                    // Our quad vertex buffer, index 0
                    shaders.ATTR_offscreen_vertex_position = {
                        format = .FLOAT2,
                        buffer_index = 0,
                    },
                    // All these other values are tied to our instance buffer
                    // Notice how each `format =` lines up with our `Sprite_Instance` struct
                    shaders.ATTR_offscreen_location = {
                        format = .FLOAT2,
                        buffer_index = 1,
                    },
                    shaders.ATTR_offscreen_size = {
                        format = .FLOAT2,
                        buffer_index = 1,
                    },
                    shaders.ATTR_offscreen_position = {
                        format = .FLOAT2,
                        buffer_index = 1,
                    },
                    shaders.ATTR_offscreen_scale = {
                        format = .FLOAT2,
                        buffer_index = 1,
                    },
                    shaders.ATTR_offscreen_color = {
                        format = .FLOAT4,
                        buffer_index = 1,
                    },
                },
            },
            index_type = .UINT16,
            // Load the shader!
            shader = sg.make_shader(
                shaders.offscreen_shader_desc(sg.query_backend()),
            ),
            depth = {
                pixel_format = .DEPTH,
                compare = .LESS_EQUAL,
                write_enabled = true,
            },
            colors = {
                0 = {
                    // This is what enables our sprites to be transparent.
                    // This is also what decides _how_ the are ordered.
                    // https://learnopengl.com/Advanced-OpenGL/Blending
                    blend = {
                        enabled = true,
                        src_factor_rgb = .SRC_ALPHA,
                        dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
                        op_rgb = .ADD,
                        src_factor_alpha = .SRC_ALPHA,
                        dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
                        op_alpha = .ADD,
                    },
                    pixel_format = OFFSCREEN_PIXEL_FORMAT,
                },
            },
            color_count = 1,
            sample_count = OFFSCREEN_SAMPLE_COUNT,
            label = "offscreen-pipeline",
        },
    )

    offscreen_sampler := sg.make_sampler(
        {
            min_filter = .NEAREST,
            mag_filter = .NEAREST,
            label = "offscreen-sampler",
        },
    )

    // Load and create our sprite atlas texture using `stb_image`
    // `#load` embeds the image in our binary!
    // This allows us to ship a single .exe without any assets laying around.
    // https://odin-lang.org/docs/overview/#loadstring-path-or-loadstring-path-type
    asset_sprite_atlas := #load("assets/Pink_Monster.png")
    sa_w, sa_h, channels: i32
    stbi.set_flip_vertically_on_load(1)
    sprite_atlas := stbi.load_from_memory(
        raw_data(asset_sprite_atlas),
        i32(len(asset_sprite_atlas)),
        &sa_w,
        &sa_h,
        &channels,
        4,
    )
    // free the loaded image at the end of init.
    // `sg.make_image` will do the allocation needed and return a handle
    // after this we don't need the stbi_loaded image.
    // In general all `sg.make_` function do an allocation and return a handle!
    // https://github.com/floooh/sokol/blob/master/sokol_gfx.h#L1320
    // These are (I think lol) the only allocation that are done in this code.
    // https://odin-lang.org/docs/overview/#defer-statement
    defer stbi.image_free(sprite_atlas)

    // Create the image (in the sokol sense), this will be our texture in the shader.
    sprite_atlas_image := sg.make_image(
        {
            width = sa_w,
            height = sa_h,
            data = {
                subimage = {
                    0 = {
                        0 = {
                            ptr = sprite_atlas,
                            size = c.size_t(sa_w * sa_h * 4),
                        },
                    },
                },
            },
            pixel_format = OFFSCREEN_PIXEL_FORMAT,
            label = "sprite-atlas",
        },
    )

    // Here we set the buffers, sampler and image.
    // To get the image into the shader we need:
    // - A texture - our image!
    // - A sampler
    offscreen_bindings := sg.Bindings {
        vertex_buffers = {
            0 = offscreen_vertex_buffer,
            1 = offscreen_instance_buffer,
        },
        index_buffer = offscreen_index_buffer,
        samplers = {shaders.SMP_smp = offscreen_sampler},
        images = {shaders.IMG_tex = sprite_atlas_image},
    }

    ////////////////////////////////////////////////////////////////////////////

    // Store all the things we need in our global struct.
    renderer.offscreen = {
        pixel_to_viewport_multiplier = pixel_to_viewport_multiplier,
        sprite_atlas_size            = {sa_w, sa_h},
        pass                         = offscreen_pass,
        pipeline                     = offscreen_pipeline,
        bindings                     = offscreen_bindings,
    }

    ////////////////////////////////////////////////////////////////////////////
    // Display renderer
    // The display renderer is simpler.
    // The only thing this does is to render our image from the offscreen pass.
    // This image is then scaled up to match our viewport size.

    display_pass_action: sg.Pass_Action
    display_pass_action.colors[0] = {
        load_action = .CLEAR,
        clear_value = {r = 0, g = 0, b = 0, a = 0},
    }

    // The same rules with the two quads as in the offscreen pass applies here too.
    // The only difference is that the viewport coordinate space is
    // {-1, 1} instead of {0, 1}
    // Hence we pass two values:
    // The first is the viewport coordinates
    // The second is the quad from before (offscreen pass) coordinates.
    // Honestly I am not even sure if the name `uv` is correct here.
    // The following code is kinda the same as the Offscreen renderer with one big difference:
    // in the `display_bindings` we set the `image` to the `render_target`!
    // odinfmt: disable
    quad_vertices := [16]f32 {
        // position   uv
        +1, +1,       1, 1,
        +1, -1,       1, 0,
        -1, -1,       0, 0,
        -1, +1,       0, 1,
    }
    // odinfmt: enable
    display_vertex_buffer := sg.make_buffer(
        {
            type = .VERTEXBUFFER,
            data = as_range(&quad_vertices),
            label = "display-vertex-buffer",
        },
    )

    display_index_buffer_vertex := [QUAD_INDEX_SIZE]u16{0, 1, 3, 1, 2, 3}
    display_index_buffer := sg.make_buffer(
        {
            type = .INDEXBUFFER,
            data = as_range(&display_index_buffer_vertex),
            label = "display-index-buffer",
        },
    )

    display_pipeline := sg.make_pipeline(
        {
            layout = {
                attrs = {
                    shaders.ATTR_display_vertex_position = {format = .FLOAT2},
                    shaders.ATTR_display_vertex_uv = {format = .FLOAT2},
                },
            },
            index_type = .UINT16,
            shader = sg.make_shader(
                shaders.display_shader_desc(sg.query_backend()),
            ),
            depth = {compare = .LESS_EQUAL, write_enabled = true},
            label = "display-pipeline",
        },
    )

    display_sampler := sg.make_sampler(
        {
            min_filter = .NEAREST,
            mag_filter = .NEAREST,
            label = "display-sampler",
        },
    )

    display_bindings := sg.Bindings {
        vertex_buffers = {0 = display_vertex_buffer},
        index_buffer = display_index_buffer,
        samplers = {shaders.IMG_tex = display_sampler},
        // Notice how the refer to the `render_target` here!
        // This is the thing we rendered everything to in the offscreen pass.
        images = {shaders.SMP_smp = render_target},
    }

    ////////////////////////////////////////////////////////////////////////////

    // Store all the things we need in our global struct.
    renderer.display = {
        pass_action = display_pass_action,
        pipeline    = display_pipeline,
        bindings    = display_bindings,
    }

    // Phew, that's it.
    // We have defined all the resources we need for our two render passes!
}

frame :: proc "c" () {
    context = runtime.default_context()

    ////////////////////////////////////////////////////////////////////////////
    // Timers & Input
    // see `non_renderer_code.odin`
    tick()
    handle_input()

    // Setup resolution scale depending on current display size
    dpi_scale := sapp.dpi_scale()
    display_width := sapp.widthf()
    display_height := sapp.heightf()
    resolution_scale := gfx_get_resolution_scaling(
        display_width,
        display_height,
        dpi_scale,
    )

    ////////////////////////////////////////////////////////////////////////////
    // Sprite batch
    // A "sprite batch" is a big slice of `Sprite_Instance`s which we send to
    // our vertex buffer with index 1 (offscreen_instance_buffer).
    // This way we can send ALL sprites to the shaders at once.
    // This allows to draw several sprites with only one draw call.
    // People told me draw calls can be a bottleneck in rendering so only doing
    // one sounds good!

    // Don't forget to reset the batch every frame!
    renderer.sprite_batch.len = 0

    // A little helper to animate our sprites with the `frames` we defined.
    for &sprite, idx in sprites_to_render {
        is_last := idx == len(sprites_to_render) - 1
        frames := len(sprite.sprite.frames)
        location := sprite.sprite.frames[int(timer.animation) % frames]

        // move sprite last in the list at the four times of the speed of the TICK_ANIMATION 200 units to the right and then reset it
        x :=
            is_last ? sprite.position.x + int(timer.animation * 4) % 200 : sprite.position.x

        // This is where the sprite is added to the batch, navigate to this function.
        // On could easily do this manually.
        // See the documentation of the function!
        gfx_draw_sprite(
            position = {x, sprite.position.y},
            scale = sprite.scale,
            color = sprite.color,
            location = location,
            size = sprite.sprite.size,
            sprite_batch = &renderer.sprite_batch,
        )
    }

    // Upload the sprite batch to the GPU!
    if renderer.sprite_batch.len > 0 {
        sprite_batch := renderer.sprite_batch.instances[:renderer.sprite_batch.len]

        sg.update_buffer(
            renderer.offscreen.bindings.vertex_buffers[1],

            // Notice the `as_range` which is a [Explicit procedure overloading].
            // https://odin-lang.org/docs/overview/#explicit-procedure-overloading
            as_range(sprite_batch),
        )
    }

    ////////////////////////////////////////////////////////////////////////////
    // Offscreen rendering pass

    // Pass a single uniform struct to the shaders.
    // These are the values that will be reused by _all_ our sprites.
    // Meaning, they are the same for all sprites, we only need to upload them once.
    vertex_shader_uniforms := shaders.Vs_Params {
        pixel_to_viewport_multiplier = renderer.offscreen.pixel_to_viewport_multiplier,
        sprite_atlas_size            = {
            f32(renderer.offscreen.sprite_atlas_size.x),
            f32(renderer.offscreen.sprite_atlas_size.y),
        },
    }

    // Begin the pass.
    sg.begin_pass(renderer.offscreen.pass)

    // Apply the pipelines.
    sg.apply_pipeline(renderer.offscreen.pipeline)
    sg.apply_bindings(renderer.offscreen.bindings)
    // Apply the uniforms we declared above.
    sg.apply_uniforms(
        shaders.UB_vs_params,
        {
            ptr = &vertex_shader_uniforms,
            size = size_of(vertex_shader_uniforms),
        },
    )
    // Do the drawing.
    // We do an instanced drawing.
    // We draw the 6 item quad we talked about earlier
    // Instanced the amount of sprite we have in our sprite batch.
    // I am not good at explaning -> https://learnopengl.com/Advanced-OpenGL/Instancing
    sg.draw(0, QUAD_INDEX_SIZE, renderer.sprite_batch.len)

    // The offscreen pass is over, we have now drawn all of our sprites on the `render_target`.
    sg.end_pass()

    ////////////////////////////////////////////////////////////////////////////
    // Display rendering pass

    sg.begin_pass(
        {
            action    = renderer.display.pass_action,
            // Notice how this pass has a swapchain.
            // This means we are no longer drawing to an attached image
            // (the `render_target`), we are drawing on the real screen instead!
            swapchain = sglue.swapchain(),
            label     = "display-pass",
        },
    )
    sg.apply_pipeline(renderer.display.pipeline)
    sg.apply_bindings(renderer.display.bindings)
    // The viewport is the area in which we are drawing.
    // Try resizing the window and you will see that the viewport snaps to
    // different pixel perfect resolutions (different multipliers of {320, 180}
    vp := gfx_get_pixel_perfect_viewport(
        display_width,
        display_height,
        dpi_scale,
        resolution_scale,
    )
    sg.apply_viewport(vp.x, vp.y, vp.z, vp.w, false)

    // In comparison to the other draw call - we only draw one instance here.
    // We simply draw the image from the offscreen renderer to the newly scaled viewport.
    // Our sprites are shown!
    sg.draw(0, QUAD_INDEX_SIZE, 1)
    sg.end_pass()
    // We did it!
    sg.commit()
}

////////////////////////////////////////////////////////////////////////////////
// Draw a sprite by adding it to the sprite batch for the upcoming frame
// position: X and Y coordinates with {0, 0} being bottom-left - I like this for platformers, I guess???
// scale:    Scale of the sprite being rendered
// color:    Color multiplier of the sprite, {255, 255, 255, 1} format
// location: Location in the sprite sheet with {0, 0} being top-left
// size:     Size of the area of the sprite sheet to render
gfx_draw_sprite :: proc(
    position: [2]int,
    scale: [2]i32 = {1, 1},
    color: [4]f32 = {255, 255, 255, 1},
    location: [2]u16,
    size: [2]u16,
    sprite_batch: ^Sprite_Batch,
) {
    if sprite_batch.len > BUDGET_SPRITES do return

    vertex: Sprite_Instance = {
        location = {f32(location.x), f32(location.y)},
        size     = {f32(size.x), f32(size.y)},
        position = {f32(position.x), f32(position.y)},
        scale    = {f32(scale.x), f32(scale.y)},
        color    = color,
    }
    sprite_batch.instances[sprite_batch.len] = vertex
    sprite_batch.len += 1
}

////////////////////////////////////////////////////////////////////////////////
// Multiplier to convert from from pixel to viewport coordinates
gfx_get_pixel_to_viewport_multiplier :: proc(
    display_width, display_height: f32,
) -> [2]f32 {
    // some Y-axis flipping to put {0, 0} at the bottom-left
    return {2 / display_width, -2 / display_height}
}

////////////////////////////////////////////////////////////////////////////////
// Get viewport size to the largest pixel perfect resolution given game size
gfx_get_pixel_perfect_viewport :: proc(
    display_width, display_height, dpi_scale: f32,
    resolution_scale: u16,
) -> [4]f32 {
    width := display_width / dpi_scale
    height := display_height / dpi_scale

    game_width := GAME_WIDTH * f32(resolution_scale)
    game_height := GAME_HEIGHT * f32(resolution_scale)

    vp_x := dpi_scale * (width - game_width) / 2
    vp_y := dpi_scale * (height - game_height) / 2
    vp_w := dpi_scale * game_width
    vp_h := dpi_scale * game_height

    return {vp_x, vp_y, vp_w, vp_h}
}

////////////////////////////////////////////////////////////////////////////////
// Get the largest possible resolution scaling based on display and GAME size
// For example running on a 1440p monitor will result in a resolution scaling of
// 8 x 180 = 1440 -> 8
gfx_get_resolution_scaling :: proc(
    display_width, display_height, dpi_scale: f32,
) -> u16 {
    width := display_width / dpi_scale
    height := display_height / dpi_scale

    display_aspect := width / height
    offscreen_aspect := f32(GAME_WIDTH / GAME_HEIGHT)

    res :=
        u16(height / GAME_HEIGHT) if offscreen_aspect < display_aspect else u16(width / GAME_WIDTH)

    return res if res > 1 else 1
}

////////////////////////////////////////////////////////////////////////////////
// Convert common types to sokol_gfx Range
// https://odin-lang.org/docs/overview/#explicit-procedure-overloading
as_range :: proc {
    slice_as_range,
    dynamic_array_as_range,
    array_ptr_as_range,
}

// https://odin-lang.org/docs/overview/#parametric-polymorphism
// https://odin-lang.org/docs/overview/#calling-conventions
slice_as_range :: proc "contextless" (val: $T/[]$E) -> (range: sg.Range) {
    range.ptr = raw_data(val)
    range.size = c.size_t(len(val)) * size_of(E)
    return
}

dynamic_array_as_range :: proc "contextless" (
    val: $T/[dynamic]$E,
) -> (
    range: sg.Range,
) {
    range.ptr = raw_data(val)
    range.size = u64(len(val)) * size_of(E)
    return
}

array_ptr_as_range :: proc "contextless" (
    val: ^$T/[$N]$E,
) -> (
    range: sg.Range,
) {
    range.ptr = raw_data(val)
    range.size = c.size_t(len(val)) * size_of(E)
    return
}

main :: proc() {
    sapp.run(
        {
            init_cb = init,
            frame_cb = frame,
            event_cb = event,
            high_dpi = true,
            window_title = "odin-sprite-renderer",
            logger = {func = slog.func},
        },
    )
}
