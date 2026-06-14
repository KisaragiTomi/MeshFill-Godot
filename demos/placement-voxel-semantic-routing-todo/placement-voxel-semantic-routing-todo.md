# docs/placement/voxel-semantic-routing-todo.md 测试场景

源文档：`res://docs/placement/voxel-semantic-routing-todo.md`  
测试场景：`res://demos/placement-voxel-semantic-routing-todo/placement-voxel-semantic-routing-todo.tscn`

## 测试方法

1. 打开 `placement-voxel-semantic-routing-todo.tscn`，确认它是 TODO checklist fixture，不是功能实现说明。
2. 运行当前已落地基线测试：

```bash
<godot> --path . --rendering-driver vulkan --script tools/test_voxel_candidate_routing_contract.gd
<godot> --path . --rendering-driver vulkan --script tools/test_autoobject_probe_prefilter.gd
<godot> --path . --rendering-driver vulkan --script tools/test_target_sv_buffer_decode.gd
<godot> --path . --rendering-driver vulkan --script tools/test_voxel_dirty_tile_upload.gd
```

#### 禁止 `--headless`

所有 GPU 测试均依赖 RenderingDevice，使用 --headless 会导致测试无法访问 GPU。GPU 测试必须在 Vulkan 驱动下运行，CPU fallback 不得作为通过条件。

3. 人工检查 `[x]` 项是否有对应源码或测试入口，`[ ]` 项是否仍以 TODO / plan 形式描述。

## 验收标准

- 已落地基线通过现有测试，尤其是 route key、空候选 skip、TargetSV buffer decode、SceneVoxelTile dirty。
- 未实现项不能作为当前主路径、默认权重或验收条件写入其它文档。
- TODO 分组仍按 P0-P6 表达优先级和边界。

