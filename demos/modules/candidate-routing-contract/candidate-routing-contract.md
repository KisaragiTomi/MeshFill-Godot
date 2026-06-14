# Candidate Routing Contract 模块测试场景

模块：candidate voxel-region routing  
场景：`res://demos/modules/candidate-routing-contract/candidate-routing-contract.tscn`

## 覆盖源文档

- `res://docs/placement/voxel-semantic-routing.md`
- `res://docs/placement/voxel-semantic-routing-todo.md`
- `res://docs/core/meshfill-framework.md`

## 测试方法

1. 打开场景，确认该模块聚焦 `candidate_voxel_regions_by_asset`、legacy `candidate_voxel_sparses_by_asset` alias 和 empty route skip。
2. 运行 routing contract 测试：

```bash
<godot> --path . --rendering-driver vulkan --script tools/test_voxel_candidate_routing_contract.gd
<godot> --path . --rendering-driver vulkan --script tools/test_voxel_placement_generator.gd
<godot> --path . --rendering-driver vulkan --script tools/test_markdown_contracts.gd
```

#### 禁止 `--headless`

所有 GPU 测试均依赖 RenderingDevice，使用 --headless 会导致测试无法访问 GPU。GPU 测试必须在 Vulkan 驱动下运行，CPU fallback 不得作为通过条件。

3. 检查 `shaders/score_voxel_tile.glsl` 不包含全资产语义检索、`semantic_score` 或 `route_score` 主路径。

## 验收标准

- 当前主接口接受每个 asset 的 `candidate_voxel_regions*` candidate voxel-region 集合，并支持 legacy `candidate_voxel_sparses*` alias。
- 某个 asset candidate region 为空时跳过该 asset，不回退到 full-grid placement。
- semantic rerank / learned matcher 只能在候选集内部 validate / rerank / prune。
