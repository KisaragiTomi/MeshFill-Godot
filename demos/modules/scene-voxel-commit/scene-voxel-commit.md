# SceneVoxel Commit 模块测试场景

模块：source write / committed `SceneVoxel` / SV resident fields  
场景：`res://demos/modules/scene-voxel-commit/scene-voxel-commit.tscn`

## 覆盖源文档

- `res://docs/core/scene-voxel-field-system.md`
- `res://docs/core/meshfill-framework.md`
- `res://docs/placement/meshfill-rock-placement-flow.md`

## 测试方法

1. 打开场景，确认该模块覆盖 source write、`blend_scene_voxels()`、resident field rebuild 和 feedback。
2. 运行 SceneVoxel commit 测试：

```bash
<godot> --headless --path . --script tools/test_scene_voxel_field.gd
<godot> --headless --path . --script tools/test_voxel_placement_record_commit.gd
<godot> --headless --path . --script tools/test_blendsv_feedback_score.gd
```

3. 对照 `scripts/scene_voxel_committer.gd`，检查 source-only sidecar 没有进入 public payload。

## 验收标准

- 可提交 source 只来自 `AutoSceneVoxel` / `BrushSceneVoxel`。
- committed `SceneVoxel` 公开 payload 保持最小字段；`occupied`、`source_voxel_type`、`commit_tick` 等不进入公开 per-voxel payload。
- `complexity_field` / `collision_field` 是由 committed state 发布的 resident read input，不是第二套 source of truth。

