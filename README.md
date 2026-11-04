# ZRenderer

A CPU path tracer written in Zig **0.17**, verified with **0.17.1** on Windows.
It renders a random sphere scene with diffuse, metal and dielectric materials,
using a BVH for acceleration, and saves the result as `random_scene.png`.

## Requirements

- Zig 0.17 on `PATH` (tested with 0.17.1).
- No additional packages or Vulkan SDK are needed for the current renderer.
  The bundled stb C implementation is compiled and linked by the build script.

## Build & run

```powershell
zig build
zig build run -Doptimize=ReleaseFast
```

The executable is installed to `zig-out/bin/`. The default render uses a
600-pixel-wide image and 100 samples per pixel, so a complete render can take
time. Progress and elapsed time are written to stderr.

### Parallel rendering

Rendering defaults to the available logical CPU count, capped by the number of
row blocks. Workers dynamically claim blocks of 8 rows and write disjoint parts
of one RGB buffer. The main thread also renders; PNG encoding happens once after
all workers finish. Scene construction and PNG encoding remain single-threaded.

```powershell
zig build run -Doptimize=ReleaseFast -- --threads 8
zig build run -Doptimize=ReleaseFast -- --threads 1
zig build run -Doptimize=ReleaseFast -- --threads 0
```

`--threads 0` selects automatically; `--threads 1` provides a serial baseline.
Use an optimized build for performance comparisons, not the default Debug build.
`--help` prints usage without rendering. Relative output paths remain relative
to the working directory; the default output is still `random_scene.png`.

Each native thread has its own RNG. Sampling is seeded per output row, so the
same scene, render seed and settings produce identical pixels regardless of
worker count or block scheduling (within the same build). This changes the old
global-RNG sample sequence, but does not change the sampling quality settings.
`RenderParams` also exposes `rows_per_task` and `seed` for programmatic control.
The scene, materials and textures must not be mutated during a render.

## Tests

```powershell
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test "-Dtest-filter=BVH"
```

Tests cover public API compilation, allocation failures, random ranges,
geometry, BVH construction, noise, timing and PNG render/readback. Parallel
regressions verify byte-identical pixels across worker counts and block sizes,
thread-local RNG isolation, partial row blocks, PNG orientation, allocation
cleanup and CLI validation.
Temporary PNG files are cleaned up automatically. Scene objects use an arena
allocator; image textures loaded through stb must be released with `deinit()`.

The workspace config routes VS Code's Zig test runner through `zig build test`
so that tests link the same stb implementation as the application.

## Layout

- `src/main.zig` — scene construction and application entry point.
- `src/render.zig`, `src/color.zig` — rendering, timing and light transport.
- `src/object.zig`, `src/material.zig`, `src/texture.zig` — scene primitives.
- `src/math.zig`, `src/random.zig`, `src/noise.zig`, `src/pdf.zig` — sampling and math.
- `src/camera.zig` — camera and ray generation.
- `src/stb.zig`, `src/stb_impl.c` — image loading and PNG output.
- `src/tests.zig` — regression tests.
- `src/vulkan.zig` — retained generated Vulkan binding; not used by this build.
- `build.zig` — build, run and test steps, with C compiler warnings enabled.
