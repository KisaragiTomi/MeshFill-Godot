# docs/history/voxel-3d-migration-plan.md 测试场景

源文档：`res://docs/history/voxel-3d-migration-plan.md`  
测试场景：`res://demos/history-voxel-3d-migration-plan/history-voxel-3d-migration-plan.tscn`

## 测试方法

1. 打开场景，确认它标记为 historical contract fixture。
2. 运行当前 3D voxel placement 的回归测试：

```bash
<godot> --headless --path . --script tools/test_voxel_footprint_bake.gd
<godot> --headless --path . --script tools/test_voxel_placement_generator.gd
<godot> --headless --path . --script tools/test_scene_voxel_field.gd
```

3. 人工检查该历史文档的状态说明，确认 active ownership 已指向 `core/meshfill-framework.md` 和 `core/scene-voxel-field-system.md`。

## 验收标准

- 历史文档保留已完成迁移结论，不把旧字段或旧流程写成当前 API。
- footprint、candidate scoring、stamp、SceneVoxel commit 的现行测试通过。
- 与当前专题文档冲突的内容必须标记为历史记录或迁移背景。

