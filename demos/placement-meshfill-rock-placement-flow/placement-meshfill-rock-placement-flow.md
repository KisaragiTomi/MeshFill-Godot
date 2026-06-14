# docs/placement/meshfill-rock-placement-flow.md 测试场景

源文档：`res://docs/placement/meshfill-rock-placement-flow.md`  
测试场景：`res://demos/placement-meshfill-rock-placement-flow/placement-meshfill-rock-placement-flow.tscn`

## 测试方法

1. 打开 `placement-meshfill-rock-placement-flow.tscn`，确认它验证 heightfield fitting producer 和 descriptor-backed consumer handoff。
2. 运行 placement 相关测试：

```bash
<godot> --path . --rendering-driver vulkan --script tools/test_placement_fitting_generator_logic.gd
<godot> --path . --rendering-driver vulkan --script tools/test_voxel_placement_generator.gd
<godot> --path . --rendering-driver vulkan --script tools/test_voxel_footprint_bake.gd
```

#### 禁止 `--headless`

所有 GPU 测试均依赖 RenderingDevice，使用 --headless 会导致测试无法访问 GPU。GPU 测试必须在 Vulkan 驱动下运行，CPU fallback 不得作为通过条件。

3. 在需要图像检查时，打开主场景或本 fixture 对照 `debug readback images`，确认每次 accepted placement 后 current height 只向目标高度上升。

## 验收标准

- `PlacementFittingGenerator.generate_placement()` / `generate_surface_placement()` 输出合法 placement result，`mesh_index` 和 scale 在资产范围内。
- CPU consumer 将结果实例化为 descriptor-backed object，并派生 `instance_stamp_write_spec`。
- 文档中的 compute pass 顺序与 shader 文件和 `placement_fitting_generator.gd` 保持一致。

