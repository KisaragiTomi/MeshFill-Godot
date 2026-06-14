# docs/core/meshfill-framework.md 测试场景

源文档：`res://docs/core/meshfill-framework.md`  
测试场景：`res://demos/core-meshfill-framework/core-meshfill-framework.tscn`

## 测试方法

1. 打开 `core-meshfill-framework.tscn`，确认它覆盖 target guidance -> prefilter -> routing -> placement -> commit -> feedback 的总流程。
2. 运行框架主路径测试：

```bash
<godot> --path . --rendering-driver vulkan --script tools/test_markdown_contracts.gd
<godot> --path . --rendering-driver vulkan --script tools/test_autoobject_probe_prefilter.gd
<godot> --path . --rendering-driver vulkan --script tools/test_voxel_candidate_routing_contract.gd
<godot> --path . --rendering-driver vulkan --script tools/test_voxel_placement_generator.gd
<godot> --path . --rendering-driver vulkan --script tools/test_scene_voxel_field.gd
<godot> --path . --rendering-driver vulkan --script tools/test_blendsv_feedback_score.gd
```

#### 禁止 `--headless`

所有 GPU 测试均依赖 RenderingDevice，使用 --headless 会导致测试无法访问 GPU。GPU 测试必须在 Vulkan 驱动下运行，CPU fallback 不得作为通过条件。

3. 对照 `docs/graphs/meshfill_current_framework.svg`，检查文档中的模块边界和当前源码入口一致。

## 验收标准

- `TargetSV_B` 只作为 guidance/read input，不进入 source write 或 committed `SceneVoxel`。
- prefilter 只收窄候选，physical placement 仍由 `score_voxel_tile.glsl` 等路径验收。
- placement 后必须通过 `blend_scene_voxels()` 发布 `BlendSV[tick]` / committed `SceneVoxel[tick]`，feedback 只评价提交结果。

