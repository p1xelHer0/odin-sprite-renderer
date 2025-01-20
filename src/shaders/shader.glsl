#pragma sokol @header package shaders
#pragma sokol @header import sg "../third_party/sokol/gfx"

////////////////////////////////////////////////////////////////////////////////

#pragma sokol @vs vs_offscreen
#pragma sokol @glsl_options flip_vert_y

in vec2 vertex_position;

layout(binding = 0) uniform vs_params {
    vec2 pixel_to_viewport_multiplier;
    vec2 sprite_atlas_size;
};

in vec2 location;
in vec2 size;
in vec2 position;
in vec2 scale;
in vec4 color;

out vec2 uv;
out vec4 rgba;

void main() {
    vec2 viewport_offset = vec2(-1, 1);

    vec2 pixel_position = vertex_position * size * scale + position;

    gl_Position = vec4(pixel_position * pixel_to_viewport_multiplier + viewport_offset, 0.0, 1.0);

    vec2 uv_size = 1 / sprite_atlas_size * size;
    vec2 uv_location = 1 / sprite_atlas_size * location;
    vec2 uv_position = uv_size * vertex_position;

    uv = vec2(uv_location.x + uv_position.x, 1.0 - uv_size.y - uv_location.y + uv_position.y);

    rgba = vec4(color.xyz / 255.0, color.w);
}
#pragma sokol @end

///////////////////////////////////////////////////////////////////////////////

#pragma sokol @fs fs_offscreen

in vec2 uv;
in vec4 rgba;

layout(binding = 0) uniform texture2D tex;
layout(binding = 0) uniform sampler smp;

out vec4 frag_color;

void main() {
    vec4 tex_color = texture(sampler2D(tex, smp), uv);

    frag_color = rgba * tex_color;
}
#pragma sokol @end

////////////////////////////////////////////////////////////////////////////////

#pragma sokol @vs vs_display

in vec2 vertex_position;
in vec2 vertex_uv;

out vec2 uv;

void main() {
    gl_Position = vec4(vertex_position, 0.0, 1.0);

    uv = vertex_uv;
}
#pragma sokol @end

////////////////////////////////////////////////////////////////////////////////

#pragma sokol @fs fs_display

in vec2 uv;

layout(binding = 0) uniform texture2D tex;
layout(binding = 0) uniform sampler smp;

out vec4 frag_color;

void main() {
    frag_color = texture(sampler2D(tex, smp), uv);
}
#pragma sokol @end

////////////////////////////////////////////////////////////////////////////////

#pragma sokol @program offscreen vs_offscreen fs_offscreen
#pragma sokol @program display vs_display fs_display
