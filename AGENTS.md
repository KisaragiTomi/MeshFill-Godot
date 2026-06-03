# Project Rules

## Godot RenderingDevice Tests

- Do not use `--headless` when running or validating Godot paths that require `RenderingDevice`, compute shaders, Vulkan, storage buffers, GPU readback, or RenderDoc.
- Run those scripts with the Vulkan rendering driver:

```powershell
godot --path . --rendering-driver vulkan --script tools/test_x.gd
```

- Use `--headless` only for scripts that are explicitly CPU-only and do not require `RenderingDevice`.
- A missing `RenderingDevice` must cause a GPU test to skip or fail explicitly. Do not add a CPU fallback and report the GPU path as passing.
