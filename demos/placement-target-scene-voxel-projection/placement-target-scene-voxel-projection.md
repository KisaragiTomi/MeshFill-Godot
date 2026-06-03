# docs/placement/target-scene-voxel-projection.md 测试场景

源文档：`res://docs/placement/target-scene-voxel-projection.md`  
测试场景：`res://demos/placement-target-scene-voxel-projection/placement-target-scene-voxel-projection.tscn`

## 测试方法

1. 打开 `placement-target-scene-voxel-projection.tscn`，确认 focus 为 TargetSV / BrushSV / TargetSV_B guidance 边界。
2. 运行 TargetSV buffer 和 source boundary 测试：

```bash
<godot> --headless --path . --script tools/test_target_sv_buffer_decode.gd
<godot> --headless --path . --script tools/test_target_guidance_source_boundary.gd
<godot> --headless --path . --script tools/test_voxel_target_debug.gd
```

3. 手工检查 `user://target_scene_voxel/` 持久化输出时，确认 raw buffer、preview 和 metadata 名称与文档一致。

## 验收标准

- `decode_target_read_buffers()` 将 visual alpha 与 collision intent 合成为 `target_occupancy`，并保留 `target_color.a`。
- `TargetSceneVoxel` / `TargetSV_B` 只作为 prefilter、routing、score、feedback 的 target input。
- 任何 target guidance record 都不能进入 `blend_scene_voxels()` 的 committed source。

