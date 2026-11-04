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
zig build run -Doptimize=ReleaseFast -- --width 600
```

The executable is installed to `zig-out/bin/`. The configured default width is
**8640** (8640x4860 at 16:9), with a maximum of 100 samples per pixel. This is a
large render: use `--width 600` for previews. Progress, actual average samples
per pixel, PNG encoding status and elapsed time are written to stderr.

### Parallel rendering

Rendering defaults to the available logical CPU count, capped by the number of
row blocks. Workers dynamically claim blocks of 8 rows and write disjoint parts
of one RGB buffer. The main thread also renders; PNG encoding happens once after
all workers finish. Scene construction and PNG encoding remain single-threaded.

```powershell
zig build run -Doptimize=ReleaseFast -- --width 600 --threads 8
zig build run -Doptimize=ReleaseFast -- --width 600 --threads 1
zig build run -Doptimize=ReleaseFast -- --width 600 --threads 0
```

`--threads 0` selects automatically; `--threads 1` provides a serial baseline.
Use an optimized build for performance comparisons, not the default Debug build.
`--help` prints usage without rendering. Relative output paths remain relative
to the working directory; the default output is still `random_scene.png`.

Each native thread has its own RNG. Sampling is now keyed by pixel and sample
index, so early stopping in one pixel cannot change a neighbor's samples.
The same scene, render seed and settings produce identical pixels and sample
counts regardless of worker count or block scheduling (within the same build).
`RenderParams` also exposes `rows_per_task` and `seed` for programmatic control.
The scene, materials and textures must not be mutated during a render.

## Integration and sampling

The main integrator is iterative. It accumulates radiance and path throughput,
starting throughput-dependent Russian roulette after 5 scattering events by
default (`--rr-depth`). Surviving paths are divided by their actual survival
probability; paths before roulette are no longer incorrectly amplified by 1/rr.
The `rr` parameter caps survival at 0.9 by default. There is no hard bounce cap.
Existing legacy `rayColorWith*` routines are not the optimized render path.

BVH construction caches bounds once and chooses the longest centroid axis for
a deterministic median split. Traversal tests singleton leaves once, visits the
nearer child first and shares precomputed reciprocal directions. Parallel rays
and grazing box hits are handled explicitly. This is not a full SAH/flat-BVH rewrite.

Camera sampling defaults to digitally shifted Sobol in five dimensions: film
x/y, lens x/y and shutter time. The lens uses a concentric square-to-disk map,
not rejection sampling. Later scattering and roulette still use the independent
per-sample PRNG; this is **not** a full-path Sobol or Owen-scrambled integrator.
Unshifted Sobol coordinates are shared in a bounded read-only cache (at most
80 KiB), with separate shifts for each pixel and replica.

Adaptive sampling is on by default. `--samples` is a hard sample budget, not a
minimum. Eight independent randomized replicas estimate linear RGB error from
their means. Complete power-of-two blocks are checked (16,32,64,... total), and
two consecutive checks must pass: default settings cannot stop before 32 samples.
Budgets below that simply render all requested samples. The sample budget is
never rounded up, even when it is not a multiple of eight.

```powershell
# Preview with the default Sobol + adaptive settings
zig build run -Doptimize=ReleaseFast -- --width 600 --samples 128
# Fixed-budget comparison/reference modes
zig build run -Doptimize=ReleaseFast -- --width 600 --samples 128 --no-adaptive --sampler random
zig build run -Doptimize=ReleaseFast -- --width 600 --samples 128 --no-adaptive --sampler sobol
# Stricter adaptive tolerance; output parent directory must already exist
zig build run -Doptimize=ReleaseFast -- --width 600 --samples 512 --min-samples 32 --relative-error 0.02 --absolute-error 0.001 --output preview.png
```

Adaptive stopping is a practical heuristic, not a guaranteed confidence interval:
rare bright paths may be missed and data-dependent stopping can introduce bias.
Disable it for fixed-budget reference images. Sobol may reduce error at a fixed
budget, but does not guarantee lower wall time or lower error for every scene.
Use [the mathematical explanation](docs/sampling.md) for the estimator details.

**Compatibility:** corrected roulette weights, the new sample sequences and
pixel jitter restricted to the film [0,1] intentionally change old images.
Compare against analytic/high-sample references, not old biased pixel values.
Gamma conversion still uses the actual number of samples taken at each pixel.

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
Numerical regressions cover diffuse/mirror energy, roulette and mixed-PDF
expectations, 10,000-bounce stack safety, Sobol reference points/stratification,
smooth-integral error, adaptive stopping and correct sample normalization.
Temporary PNG files are cleaned up automatically. Scene objects use an arena
allocator; image textures loaded through stb must be released with `deinit()`.

The workspace config routes VS Code's Zig test runner through `zig build test`
so that tests link the same stb implementation as the application.

## Layout

- `src/main.zig` — scene construction and application entry point.
- `src/render.zig`, `src/color.zig` — rendering, timing and light transport.
- `src/object.zig`, `src/material.zig`, `src/texture.zig` — scene primitives.
- `src/math.zig`, `src/random.zig`, `src/noise.zig`, `src/pdf.zig` — math and path sampling.
- `src/sampling.zig` — shifted Sobol camera sampling and adaptive estimates.
- `src/camera.zig` — camera and ray generation.
- `src/stb.zig`, `src/stb_impl.c` — image loading and PNG output.
- `src/tests.zig`, `src/bvh_tests.zig`, `src/integrator_tests.zig`, `src/sampling_tests.zig` — regression tests.
- `src/vulkan.zig` — retained generated Vulkan binding; not used by this build.
- `build.zig` — build, run and test steps, with C compiler warnings enabled.
