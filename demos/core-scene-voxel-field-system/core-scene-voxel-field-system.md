# docs/core/scene-voxel-field-system.md 测试场景

源文档：`res://docs/core/scene-voxel-field-system.md`  
测试场景：`res://demos/core-scene-voxel-field-system/core-scene-voxel-field-system.tscn`

## 测试方法

1. 打开 `core-scene-voxel-field-system.tscn`，确认场景 focus 为 source write / commit / resident fields。
2. 运行 SceneVoxel 主契约测试：

```bash
<godot> --headless --path . --script tools/test_scene_voxel_field.gd
<godot> --headless --path . --script tools/test_voxel_placement_record_commit.gd
<godot> --headless --path . --script tools/test_blendsv_feedback_score.gd
<godot> --headless --path . --script tools/test_voxel_dirty_tile_upload.gd
```

3. 对照 `scripts/scene_voxel_committer.gd`，检查 `_write_source_scene_voxel()`、`blend_scene_voxels()`、`_rebuild_sv()` 的职责没有互相越界。

## 验收标准

- 可提交 source record 只来自 `AutoSceneVoxel` / `BrushSceneVoxel`，`TargetSceneVoxel` guidance record 被跳过。
- committed `SceneVoxel` 公开 payload 只保留最小读取字段，不暴露 source-only sidecar。
- `scene_field` / `collision_field` 由 committed state 和 terrain collision 重建，不成为第二套权威输入。

