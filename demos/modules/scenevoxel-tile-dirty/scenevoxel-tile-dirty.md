# SceneVoxelTile Dirty 模块测试场景

模块：`SceneVoxelTile` dirty sidecar
场景：`res://demos/modules/scenevoxel-tile-dirty/scenevoxel-tile-dirty.tscn`

## 覆盖源文档

- `res://docs/core/scenevoxeltile.md`
- `res://docs/core/scene-voxel-field-system.md`
- `res://docs/core/autoobject-gpu-runtime-architecture.md`

## 测试方法

1. 打开场景，确认该模块覆盖 dirty API、tile size、summary、object/source range、GPU dirty delta handoff 和 get_sv/clear 后的 GPU lifecycle。
2. 运行 dirty tile 测试：

```bash
<godot> --headless --path . --script tools/test_voxel_dirty_tile_upload.gd
<godot> --path . --rendering-driver vulkan --script tools/test_voxel_dirty_tile_upload.gd
<godot> --headless --path . --script tools/test_scene_voxel_field.gd
```

3. 检查 headless 日志中 GPU 子项只能 `SKIP`；无 RenderingDevice 时不要启动 runtime 替代路径。
4. 检查非 headless Vulkan 日志中 `SceneVoxelTile` metadata 通过 GPU storage buffer upload/readback：`ensure_scene_voxel_tile_buffers_uploaded()` 成功，`get_scene_voxel_tile_gpu_buffer_summary()` 的 required buffer RID 有效，stale revision 不会继续作为 runtime read source，`readback_scene_voxel_tile_debug_snapshot()` 只作为 debug view。
5. 检查 `project.godot` 中 `meshfill/scene_voxel_tile/size_voxels` 的配置与文档中的默认/覆盖规则。

## 验收标准

- `SceneVoxelTile` 是 SV owner 的 coarse cell sidecar，默认语义为 `4x4x4` voxels，项目设置可覆盖。
- named dirty API 能同步 legacy dirty storage，并能在 SV snapshot 中发布 dirty tile 和 object/source debug range。
- 有 RenderingDevice 时，tile record、summary、dirty index、object ref 和 source ref 必须上传到 GPU storage buffers，并通过 readback 验收。
- runtime resident success 以 GPU buffer summary / valid RIDs / upload revision 为准；CPU staging、debug label 或 snapshot 不能替代 resident metadata。
- staging revision 前进后，旧 buffers 必须标记 stale；`get_sv()` auto-upload 后，post-publish dirty index 必须为空，padding bytes 不能被解码成 dirty tile。
- 无 RenderingDevice 时只允许明确 `SKIP`，不能走 runtime 替代路径。
- `scene_minmax`、`collision_minmax` 等 summary 不写入 committed `SceneVoxel` payload（判断是否有内容使用 `scene_count > 0 || collision_count > 0`）。
