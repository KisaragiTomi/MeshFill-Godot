# GPU AutoObject Runtime Plan 模块测试场景

模块：GPU-first `AutoObject` runtime architecture
场景：`res://demos/modules/gpu-autoobject-runtime-plan/gpu-autoobject-runtime-plan.tscn`

## 覆盖源文档

- `res://docs/core/autoobject-gpu-runtime-architecture.md`
- `res://docs/core/scenevoxeltile.md`
- `res://docs/core/meshfill-framework.md`

## 测试方法

1. 打开场景，确认该模块是 GPU-first runtime 边界测试：CPU 只负责 command、staging、debug readback 和 snapshot。
2. 运行 Vulkan GPU 验收，确认真实 `RenderingDevice`、GPU buffer 和 readback 路径：

```bash
<godot> --path . --rendering-driver vulkan --script tools/test_voxel_dirty_tile_upload.gd
<godot> --path . --rendering-driver vulkan --script tools/test_autoobject_probe_prefilter.gd
<godot> --path . --rendering-driver vulkan --script tools/test_auto_voxel_runtime_profile_container.gd
<godot> --path . --rendering-driver vulkan --script tools/test_gpu_autoobject_runtime_bridge.gd
<godot> --path . --rendering-driver vulkan --script tools/test_voxel_multi_asset.gd
<godot> --path . --rendering-driver vulkan --script tools/test_markdown_contracts.gd
```

#### 禁止 `--headless`

所有 GPU 测试均依赖 RenderingDevice，使用 --headless 会导致测试无法访问 GPU。GPU 测试必须在 Vulkan 驱动下运行，CPU fallback 不得作为通过条件。

3. 人工检查文档中 `Current GPU-First Contract Points`、`Implementation Status`、`Runtime IO Contract` 的 staging / resident 边界；无 RenderingDevice 时只能 SKIP GPU upload / placement，不能改走 CPU 替代路径。VPG 的 contract validation 必须让 runtime/profile buffers bound 并被 placement consumed；失败时返回 `contract_blocked=true`、`cpu_fallback=false`。

## 验收标准

- `GPUAutoObjectRuntime` 拥有 runtime object state、profile id、spatial index 和 dirty object delta。
- `AutoVoxelRuntimeProfileContainer` 的 GPU storage buffer summary 和 readback snapshot 才能作为 GPU upload 验收。
- VPG 只能在 `GPUAutoObjectRuntime` 与 `AutoVoxelRuntimeProfileContainer` 同 RD、ready、required buffers bound/consumed 后生成 placement 结果。
- CPU staging / debug readback 不能替代 GPU upload、placement 或 resident runtime authority。
- SV grid、commit、`SceneVoxelTile` dirty、source range rebuild 和 resident fields 仍由 `SceneVoxelCommitter` / SV owner 维护。
