# Heightfield Rock Placement 模块测试场景

模块：heightfield fitting / rock placement consumer  
场景：`res://demos/modules/heightfield-rock-placement/heightfield-rock-placement.tscn`

## 覆盖源文档

- `res://docs/placement/meshfill-rock-placement-flow.md`
- `res://docs/core/meshfill-framework.md`

## 测试方法

1. 打开场景，确认该模块覆盖 compute pass flow、placement result 和 descriptor-backed consumer handoff。
2. 运行 placement 测试：

```bash
<godot> --path . --rendering-driver vulkan --script tools/test_placement_fitting_generator_logic.gd
<godot> --path . --rendering-driver vulkan --script tools/test_voxel_placement_generator.gd
<godot> --path . --rendering-driver vulkan --script tools/test_voxel_footprint_bake.gd
```

#### 禁止 `--headless`

所有 GPU 测试均依赖 RenderingDevice，使用 --headless 会导致测试无法访问 GPU。GPU 测试必须在 Vulkan 驱动下运行，CPU fallback 不得作为通过条件。

3. 人工检查 debug readback images 时，确认 accepted placement 后 current height 只向 target height 收敛。

## 验收标准

- heightfield fitting pass 顺序与 `scripts/placement_fitting_generator.gd` 和 shader 文件一致。
- placement result 包含合法 `mesh_index`、position、scale，并遵守资产随机缩放范围。
- CPU consumer 复制 descriptor-backed object 原型后生成 `instance_stamp_write_spec`，再交给 SceneVoxel source write。

