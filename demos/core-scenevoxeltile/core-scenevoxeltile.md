# docs/core/scenevoxeltile.md 测试场景

源文档：`res://docs/core/scenevoxeltile.md`
测试场景：`res://demos/core-scenevoxeltile/core-scenevoxeltile.tscn`

## 测试方法

1. 打开 `core-scenevoxeltile.tscn`，确认 focus 指向 dirty sidecar 而不是 committed payload。
2. 先运行 headless smoke；无 `RenderingDevice` 时 GPU upload/readback 子项只能 SKIP：

```bash
<godot> --headless --path . --script tools/test_voxel_dirty_tile_upload.gd
<godot> --headless --path . --script tools/test_scene_voxel_field.gd
```

3. 再运行非 headless Vulkan 验收，确认真实 `RenderingDevice`、GPU storage buffers 和 readback 路径：

```bash
<godot> --path . --rendering-driver vulkan --script tools/test_voxel_dirty_tile_upload.gd
```

4. 检查 `project.godot` 中 `meshfill/scene_voxel_tile/size_voxels` 的覆盖值是否与文档说明一致。

## 验收标准

- `SceneVoxelTile` 默认语义是 `4x4x4` voxel block，项目设置可覆盖。
- dirty flags、object/source debug range、summary 都属于 SV owner staging / debug sidecar。
- 有 `RenderingDevice` 时，tile record、summary、dirty index、object ref 和 source ref 必须上传到 GPU storage buffers，并通过 readback 验收。
- runtime resident success 以 GPU buffer summary / valid RIDs / upload revision 为准；CPU staging、debug label 或 snapshot 不能替代 resident metadata。
- `scene_minmax`、`collision_minmax`、`non_empty` 不写回 committed per-voxel payload。
