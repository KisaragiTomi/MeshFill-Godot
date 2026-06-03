# docs/core/meshfill-framework.md 测试场景

源文档：`res://docs/core/meshfill-framework.md`  
测试场景：`res://demos/core-meshfill-framework/core-meshfill-framework.tscn`

## 测试方法

1. 打开 `core-meshfill-framework.tscn`，确认它覆盖 target guidance -> prefilter -> routing -> placement -> commit -> feedback 的总流程。
2. 运行框架主路径测试：

```bash
<godot> --headless --path . --script tools/test_markdown_contracts.gd
<godot> --headless --path . --script tools/test_autoobject_probe_prefilter.gd
<godot> --headless --path . --script tools/test_voxel_candidate_routing_contract.gd
<godot> --headless --path . --script tools/test_voxel_placement_generator.gd
<godot> --headless --path . --script tools/test_scene_voxel_field.gd
<godot> --headless --path . --script tools/test_blendsv_feedback_score.gd
```

3. 对照 `docs/graphs/meshfill_current_framework.svg`，检查文档中的模块边界和当前源码入口一致。

## 验收标准

- `TargetSV_B` 只作为 guidance/read input，不进入 source write 或 committed `SceneVoxel`。
- prefilter 只收窄候选，physical placement 仍由 `score_voxel_tile.glsl` 等路径验收。
- placement 后必须通过 `blend_scene_voxels()` 发布 `BlendSV[tick]` / committed `SceneVoxel[tick]`，feedback 只评价提交结果。

