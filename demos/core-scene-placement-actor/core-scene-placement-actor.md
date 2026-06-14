# docs/core/scene-placement-actor.md 测试场景

源文档：`res://docs/core/scene-placement-actor.md`  
测试场景：`res://demos/core-scene-placement-actor/core-scene-placement-actor.tscn`

## 测试方法

1. 打开 `core-scene-placement-actor.tscn`，确认该 fixture 覆盖 SPA 的 asset registry、profile container ownership、prefilter -> placement -> commit 编排和外部引用边界。
2. 运行 Vulkan GPU 验收，确认真实 `RenderingDevice`、profile GPU buffers、prefilter readback 和 VPG contract 仍按 GPU-first 路径工作：

```bash
<godot> --path . --rendering-driver vulkan --script tools/test_auto_voxel_runtime_profile_container.gd
<godot> --path . --rendering-driver vulkan --script tools/test_autoobject_probe_prefilter.gd
<godot> --path . --rendering-driver vulkan --script tools/test_voxel_multi_asset.gd
<godot> --path . --rendering-driver vulkan --script tools/test_target_sv_buffer_decode.gd
<godot> --path . --rendering-driver vulkan --script tools/test_core_demo_contracts.gd
```

#### 禁止 `--headless`

所有 GPU 测试均依赖 RenderingDevice，使用 --headless 会导致测试无法访问 GPU。GPU 测试必须在 Vulkan 驱动下运行，CPU fallback 不得作为通过条件。

3. 对照 `docs/graphs/scene-placement-actor.svg`，检查 SPA 只拥有 `AutoVoxelRuntimeProfileContainer`，并只借用 `SceneVoxelCommitter` / `GPUAutoObjectRuntime`。

## 验收标准

- SPA 是 descriptor 注册、GPU profile buffer 生命周期和 placement pipeline 的统一入口。
- `AutoVoxelRuntimeProfileContainer` 由 SPA 创建、管理和释放，profile/probe/collision/pivot buffers 必须 GPU resident。
- `SceneVoxelCommitter`、`GPUAutoObjectRuntime` 和 `TargetSV_B` read buffers 由外部 owner 提供，SPA 不复制它们的权威状态。
- 缺少 `RenderingDevice`、profile container 未 ready 或 VPG contract blocked 时只能报告 blocked / SKIP，不能改走 CPU 替代路径。
