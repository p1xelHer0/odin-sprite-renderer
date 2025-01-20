# odin-sprite-renderer

A 320 x 180 sprite renderer with automatic resolution scaling written in [Odin](https://github.com/odin-lang/odin) using the [sokol headers](https://github.com/floooh/sokol) in a single file.

A try to explain things to my best ability in the comments found in the source.

Some non-renderer code (ticks, input handling via `sokol_app`) can be found in [`non_renderer_code.odin`](src/non_renderer_code.odin) if you are interested. It showcases some neat Odin features as well!

https://github.com/user-attachments/assets/34b047c1-2d15-486f-90b8-97636b0b255e

## Odin and sokol

The bindings to the `sokol headers` are included in [`src/third_party`](src/third_party)

- This project has been built with [`Odin @ bca016a`](https://github.com/odin-lang/Odin/commit/bca016ae941602864cb614c60d42fc9231543dee)

- The sokol headers are version [`sokol-odin @ cee69e0`](https://github.com/floooh/sokol-odin/commit/cee69e0f828aade2e7a999482052e8af758bfe6e)

## Running the program

Run the Odin compiler in the [`src directory`](src). Move with `WASD` or you arrow keys. Press `Q` to quit or `F` to toggle fullscreen.

```
odin run src
```

If you for some reason want to force OpenGL you can do the following:

```
odin run src -define:SOKOL_USE_GL=true
```

## Why?

Sharing is better than not sharing. Also I kinda wrote this renderer once without revisiting it for a long time. I felt like my knowledge was deteoriating a bit so doing this and writing the comments is a good exercise for myself.

I've been slowly getting into graphics and systems programming. I stumbled upon Odin and sokol and figured I'd give them a try. I always liked the look of games like [Celeste](https://www.celestegame.com/) and wanted to figure out how I could render a game like those. This is the result. I added a lot of comments, for myself, and hopefully others, in the source code.
There are probably a lot of things that can be done better here, graphics programming seems to be the deepest of rabbit holes there is! If you have any feedback feel free to reach out on X, Discord, here or any other place on the indernet under the same name `@p1xelHer0`.

After looking into different ways to render a "pixel art" game I landed in this technique which is probably the "dumbest": render the game to 320 x 180 and then scale it up the match the display.

## Acknowledgements

I learned most of the things by following [LearnOpenGL](https://learnopengl.com/) in tandem with reading them [written in sokol](https://github.com/zeromake/learnopengl-examples), reading the [`sokol_gfx source code`](https://github.com/floooh/sokol/blob/master/sokol_gfx.h), getting help from the awesome [Odin Discord](https://discord.com/invite/odinlang) and [d7samurai's Gists](https://gist.github.com/d7samurai). As you can see I even use the same sprite as d7samurai here... I thought it fit well to showcase.

The sprite sheet usees the "Pink Monster" from [Tiny Heroes @ CraftPix.net](https://craftpix.net/freebies/free-pixel-art-tiny-hero-sprites/)

## macOS

I personally develop on macOS (right now, lol) and here are some tips:

- You can enable the Metal overlay HUD by running `export MTL_HUD_ENABLED=1`

- You can debug the GPU magic happening with Xcode (since sokol runs Metal):

```
odin build src -out:debug
```

After the executable has been built, go to Xcode, `Debug` -> `Debug Executable...` and find the `debug` executable you built. Press the play button - the program should now run. Now go into the menu `Debug` -> `Capture GPU Workload`. Tadaa!

## Shaders

The shaders have already been compiled to OpenGL (`glsl430`), DXD11 (`hlsl5`) and Metal (`metal_macos`) and should run on Linux, Windows and macOS.

If you want to recompile the shaders you can do so with [sokol-shdc](https://github.com/floooh/sokol-tools/blob/master/docs/sokol-shdc.md).
I've included a binary of it as a submodule in this repository. Get it by getting the Git submodules:

```

git submodule update --init --recursive

```

Compile the shaders with `sokol-shdc` found in the directory: [`./bin/sokol-tools-bin/bin/{linux,osx,osx_arm64,win32}`](https://github.com/floooh/sokol-tools-bin/tree/d80b1d8f20fef813092ba37f26723d3880839651/bin)

You should be able to copy paste the commands below for your platform to do compile the shader.

### Compiling for Linux

```

./bin/sokol-tools-bin/bin/linux/sokol-shdc -i src/shaders/shader.glsl -o src/shaders/shader.glsl.odin -l glsl430:hlsl5:metal_macos -f sokol_odin

```

### Compiling for Windows

```

bin\sokol-tools-bin\bin\win32\sokol-shdc -i src\shaders\shader.glsl -o src\shaders\shader.glsl.odin -l glsl430:hlsl5:metal_macos -f sokol_odin

```

### Compiling for macOS (ARM)

```

./bin/sokol-tools-bin/bin/osx_arm64/sokol-shdc -i src/shaders/shader.glsl -o src/shaders/shader.glsl.odin -l glsl430:hlsl5:metal_macos -f sokol_odin

```

### Compiling for macOS (Intel)

```

./bin/sokol-tools-bin/bin/osx/sokol-shdc -i src/shaders/shader.glsl -o src/shaders/shader.glsl.odin -l glsl430:hlsl5:metal_macos -f sokol_odin

```

### Compiling for macOS OpenGL

Run the same command but change `glsl430` to `glsl410`.
