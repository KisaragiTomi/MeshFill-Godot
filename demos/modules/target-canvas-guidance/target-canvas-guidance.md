# Target Canvas Guidance 模块测试场景

模块：`TargetSV` / `BrushSV` / `TargetSV_B` guidance canvas  
场景：`res://demos/modules/target-canvas-guidance/target-canvas-guidance.tscn`

## 覆盖源文档

- `res://docs/placement/target-scene-voxel-projection.md`
- `res://docs/core/meshfill-framework.md`
- `res://docs/core/scene-voxel-field-system.md`

## 测试方法

1. 打开场景，确认 focus 为 Target canvas guidance，而不是 placement 或 committed source。
2. 运行目标画布测试：

```bash
<godot> --headless --path . --script tools/test_target_sv_buffer_decode.gd
<godot> --headless --path . --script tools/test_target_guidance_source_boundary.gd
<godot> --headless --path . --script tools/test_voxel_target_debug.gd
```

3. 需要人工检查持久化时，确认 `user://target_scene_voxel/` 下输出 raw buffer、preview 和 metadata，并与源文档命名一致。

## 验收标准

- `TargetSV_B` 解码为 `target_occupancy` / `target_color`，`target_occupancy` 使用 visual alpha 与 collision intent 的最大值。
- `TargetSceneVoxel` guidance record 不进入 source write，也不出现在 committed `SceneVoxel`。
- Target dirty 只触发 routing / score / feedback 读取更新，不成为第二套 source of truth。

