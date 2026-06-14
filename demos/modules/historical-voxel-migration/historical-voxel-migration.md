# Historical Voxel Migration 模块测试场景

模块：historical 3D voxel migration record  
场景：`res://demos/modules/historical-voxel-migration/historical-voxel-migration.tscn`

## 覆盖源文档

- `res://docs/history/voxel-3d-migration-plan.md`
- `res://docs/core/meshfill-framework.md`
- `res://docs/core/scene-voxel-field-system.md`

## 测试方法

1. 打开场景，确认该模块验证历史文档边界，而不是当前主路径实现说明。
2. 运行当前 3D voxel placement 回归测试：

```bash
<godot> --path . --rendering-driver vulkan --script tools/test_voxel_footprint_bake.gd
<godot> --path . --rendering-driver vulkan --script tools/test_voxel_placement_generator.gd
<godot> --path . --rendering-driver vulkan --script tools/test_scene_voxel_field.gd
```

#### 禁止 `--headless`

所有 GPU 测试均依赖 RenderingDevice，使用 --headless 会导致测试无法访问 GPU。GPU 测试必须在 Vulkan 驱动下运行，CPU fallback 不得作为通过条件。

3. 人工检查历史文档开头的 status，以及是否指向当前 owning docs。

## 验收标准

- 历史文档只保留迁移结论和背景，不把旧字段或旧流程写成当前 API。
- active ownership 指向 `core/meshfill-framework.md`、`core/scene-voxel-field-system.md` 等当前专题文档。
- 当前 footprint、placement、source commit 测试通过。

