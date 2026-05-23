# Project TODO

本文只保留当前候选路由方案的后续事项。旧版“全资产语义查找”任务已移除；语义匹配只能在 `anchor_autoobject_topk` 的候选集内部 rerank、validate 或 prune。

![Voxel semantic routing overview](../graphs/voxel-semantic-routing.svg)

## Voxel Semantic Routing

### P0：候选路由主线

- [ ] 将 `anchor_autoobject_topk` 的候选记录统一为 `{asset_index, score, tile_id}`，anchor 本体保持 position-only。
- [ ] 实现候选 route 归一化、去重和低置信度剔除。
- [ ] 聚合 surviving routes 为 candidate voxel regions；目标命名为 `candidate_voxel_regions_by_asset`，当前兼容视图仍可读写 `candidate_voxel_sparses_by_asset`。
- [ ] 聚合 candidate voxel regions 时按 footprint、probe offset bounds、context 半径和 interpolation guard 保守扩张。
- [ ] 确认 `VoxelPlacementGenerator.run_multi_asset()` 对空 candidate voxel region 的 asset 直接 skip。
- [ ] 增加集成测试：prefilter route、empty route skip、dirty voxel-region route rebuild。

### P1：候选集内部验证

- [ ] 可选生成 `voxel_context_buffer`，只用于候选 route 验证和 EMPTY 判断。
- [ ] 可选生成 `target_scene_context_rgba8_buffer`，用于局部 / wide TargetSV 颜色与复杂度验证。
- [ ] 为所有 TargetSV_B probe / context 采样应用 clamp 边界规则。
- [ ] 在 debug 输出中记录 `clamped_sample_count`。
- [ ] 评估 `route_score` 默认阈值和 `empty_region_threshold`。

### P2：TargetSceneVoxel Projection

设计文档：

```text
docs/placement/target-scene-voxel-projection.md
```

- [ ] Phase 1：保留现有 anchor 向外感知，继续使用 `target_scene_context_rgba8`。
- [ ] Phase 2：新增 `target_anchor_projection_rgba8`，先实现垂直柱压缩。
- [ ] Phase 3：将 projection 投影到 nearest support / ground anchor。
- [ ] Phase 4：增加水平扩散与 falloff，让树冠、岩体或墙体影响多个 anchor。
- [ ] Phase 5：为 asset 烘焙 `asset_anchor_pref_rgba8`。
- [ ] Phase 6：只在候选 route 内加入 `projection_score`。

### P3：Asset Semantic Probes

设计文档：

```text
docs/core/asset-semantic-probes.md
```

- [ ] 明确 `SemanticProbe` flags 的稳定 bit layout。
- [ ] 为 `context` probe 增加可视化 / inspect 输出。
- [ ] 验证支撑面 / target-top 两类 position-only anchor 对 probe offset 的覆盖。
- [ ] 添加测试：probe 生成确定性、context probe 数量、TargetSV_B clamp 采样。

### P4：MLP / learned matcher

MLP 只能影响候选集内部的 route validation，不能绕过 upstream prefilter。

- [ ] 保留手工 16D context 作为 baseline。
- [ ] 新增 tiny MLP：`16 -> 32 -> 16`，输出 `learned_route_context`。
- [ ] 只对 `anchor_autoobject_topk` 中已有候选计算 learned score。
- [ ] 增加开关：手工 context / learned context 可切换对比。
- [ ] 记录用户手动放置、修正或拒绝的候选 route 样本。

## 验收边界

- [ ] 不新增全资产枚举 shader。
- [ ] 不恢复 `voxel_asset_topk_buffer` / `tile_asset_topk_buffer` 作为主路径。
- [ ] `score_voxel_tile.glsl` 保持物理评分职责。
- [ ] 未启用 route validation 时，现有 placement 行为保持不变。
