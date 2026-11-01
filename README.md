# ZRenderer

A Zig **0.17.0** project with a working Vulkan binding. For now the program just
prints `helloworld`, but it also creates a real `VkInstance`, enumerates the
machine's physical devices and tears the instance down cleanly — proving the
binding compiles *and* runs against the installed Vulkan loader/driver.

## Requirements

- Zig `0.17.0` (the shell's `zig` may still point at 0.16; use the 0.17 binary,
  e.g. `E:\zig-x86_64-windows-0.17.0\zig.exe`).
- The Vulkan SDK installed at `E:\Vulkan` (or override with `-Dvulkan-sdk=`).
- A Vulkan-capable GPU/driver (loader `vulkan-1.dll` in `C:\Windows\System32`).

## Build & run

```powershell
E:\zig-x86_64-windows-0.17.0\zig.exe build run
```

Example output:

```
helloworld
Vulkan instance created; 2 physical device(s) found
  - NVIDIA GeForce RTX 5070 Ti
  - AMD Radeon(TM) Graphics
```

`helloworld` is written to stdout; the Vulkan diagnostics go to stderr.

To just build the executable (placed in `zig-out\bin\zrenderer.exe`):

```powershell
E:\zig-x86_64-windows-0.17.0\zig.exe build
```

## Layout

- `src/main.zig` — entry point: prints `helloworld`, creates a Vulkan instance,
  enumerates physical devices, destroys the instance.
- `src/vulkan.zig` — the generated Vulkan binding (see below).
- `build.zig` — wires up the Vulkan SDK include path, import library
  (`vulkan-1.lib`) and the `run` step.

## Regenerating the binding

`src/vulkan.zig` is generated from the SDK's `vulkan/vulkan.h` with the Zig
0.17.0 C-translation CLI (`@cImport` was removed in 0.17.0):

```powershell
E:\zig-x86_64-windows-0.17.0\zig.exe translate-c -I "E:\Vulkan\Include" "E:\Vulkan\Include\vulkan\vulkan.h" > src\vulkan.zig
```

If your shell adds a UTF-8 BOM to the redirect, strip the leading `EF BB BF`
bytes before building (Zig rejects the BOM).

## Notes

- `build.zig` accepts `-Dvulkan-sdk=<path>` to point at a non-default SDK
  location (default `E:/Vulkan`).
- The binding is linked against `vulkan-1.lib`, which resolves to the system
  loader `vulkan-1.dll` at runtime.
