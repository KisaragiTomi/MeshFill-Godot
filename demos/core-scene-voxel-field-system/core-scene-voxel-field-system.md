# docs/core/scene-voxel-field-system.md 测试场景

源文档：`res://demos/core-scene-voxel-field-system/scene-voxel-field-system.md`  
测试场景：`res://demos/core-scene-voxel-field-system/core-scene-voxel-field-system.tscn`

## 运行方式

> **@tool 编辑器模式，禁止 F6。**
>
> 在 Godot 编辑器中双击打开 `.tscn` 场景文件即可。脚本在编辑器视口中实时运行。
> F6（Run Current Scene）和 F5（Run Project）被 `core_demo_contract_fixture.gd` 守卫代码禁止。

## 测试方法

1. 打开 `core-scene-voxel-field-system.tscn`，确认场景 focus 为 source write / commit / resident fields。
2. 运行 SceneVoxel 主契约测试：

```bash
<godot> --path . --rendering-driver vulkan --script tools/test_scene_voxel_field.gd
<godot> --headless --path . --script tools/test_voxel_placement_record_commit.gd
<godot> --path . --rendering-driver vulkan --script tools/test_blendsv_feedback_score.gd
<godot> --path . --rendering-driver vulkan --script tools/test_voxel_dirty_tile_upload.gd
```

#### 禁止 `--headless`

所有 GPU 测试均依赖 RenderingDevice，使用 --headless 会导致测试无法访问 GPU。GPU 测试必须在 Vulkan 驱动下运行，CPU fallback 不得作为通过条件。

3. 对照 `scripts/scene_voxel_committer.gd`，检查 `_write_source_scene_voxel()`、`blend_scene_voxels()`、`_rebuild_sv()` 的职责没有互相越界。

## 验收标准

- 可提交 source record 只来自 `AutoSceneVoxel` / `BrushSceneVoxel`，`TargetSceneVoxel` guidance record 被跳过。
- committed `SceneVoxel` 公开 payload 只保留最小读取字段，不暴露 source-only sidecar。
- `complexity_field` / `collision_field` 由 committed state 和 terrain collision 重建，不成为第二套权威输入。

