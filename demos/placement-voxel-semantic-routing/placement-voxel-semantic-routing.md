# docs/placement/voxel-semantic-routing.md 测试场景

源文档：`res://docs/placement/voxel-semantic-routing.md`  
测试场景：`res://demos/placement-voxel-semantic-routing/placement-voxel-semantic-routing.tscn`

## 测试方法

1. 打开 `placement-voxel-semantic-routing.tscn`，确认场景 focus 为 candidate voxel-region routing。
2. 运行路由契约和 placement skip 测试：

```bash
<godot> --headless --path . --script tools/test_voxel_candidate_routing_contract.gd
<godot> --headless --path . --script tools/test_autoobject_probe_prefilter.gd
<godot> --headless --path . --script tools/test_voxel_placement_generator.gd
<godot> --headless --path . --script tools/test_markdown_contracts.gd
```

3. 检查 `shaders/score_voxel_tile.glsl`，确认 physical score 不包含 `semantic_score`、`route_score` 或全资产 embedding 查找。

## 验收标准

- `candidate_voxel_regions_by_asset` 表示每个 asset 本轮要检查的 candidate voxel regions；`candidate_voxel_sparses_by_asset` 仅作为 legacy alias。
- 某个 asset 没有 candidate region 时，本轮跳过该 asset，不回退到全场搜索。
- semantic rerank、context pooling、learned matcher 只允许在候选集内部验证或裁剪。
