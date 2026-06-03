# docs/placement/meshfill-rock-placement-flow.md 测试场景

源文档：`res://docs/placement/meshfill-rock-placement-flow.md`  
测试场景：`res://demos/placement-meshfill-rock-placement-flow/placement-meshfill-rock-placement-flow.tscn`

## 测试方法

1. 打开 `placement-meshfill-rock-placement-flow.tscn`，确认它验证 heightfield fitting producer 和 rock consumer handoff。
2. 运行 placement 相关测试：

```bash
<godot> --headless --path . --script tools/test_placement_fitting_generator_logic.gd
<godot> --headless --path . --script tools/test_voxel_placement_generator.gd
<godot> --headless --path . --script tools/test_voxel_footprint_bake.gd
```

3. 在需要图像检查时，打开主场景或本 fixture 对照 `debug readback images`，确认每次 accepted placement 后 current height 只向目标高度上升。

## 验收标准

- `PlacementFittingGenerator.generate_placement()` / `generate_surface_placement()` 输出合法 placement result，`mesh_index` 和 scale 在资产范围内。
- CPU consumer 将结果实例化为 `AutoRock`，并派生 `instance_stamp_write_spec`。
- 文档中的 compute pass 顺序与 shader 文件和 `placement_fitting_generator.gd` 保持一致。

