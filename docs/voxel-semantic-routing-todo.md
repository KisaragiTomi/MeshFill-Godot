# Project TODO

## 使用规则

- 这里记录跨文档、跨模块的后续事项。
- 具体设计仍写在对应设计文档中；本文件只保留可执行 TODO。
- 每个主题用独立二级标题分组。
- 已完成事项勾选后可移动到对应设计文档或变更记录中。

---

## Voxel Semantic Routing

### 第一版实现

- [ ] 创建 `VoxelSemanticDB`，负责 asset embedding / target preference 注册与导出。
- [ ] 实现 `precompute_voxel_context.glsl`，输出 16D scene context。
- [ ] 实现 `precompute_target_scene_context.glsl`，输出 local/wide target color + complexity context。
- [ ] 实现 `select_voxel_assets.glsl`，输出 voxel 级 top-N asset / `EMPTY_ASSET_ID`。
- [ ] 实现 `reduce_tile_assets.glsl`，输出 tile 级 top-K asset。
- [ ] 扩展 `GlobalVoxelField`，支持 full rebuild 与 dirty semantic update。
- [ ] 扩展 `VoxelPlacementGenerator.run_multi_asset()`，支持 `semantic_routing`。
- [ ] 添加集成测试：full init、dirty update、target context、routing dispatch 削减。

### 暂缓项

- [ ] 将 `edge` 加回 `voxel_context`：使用 6 邻居 `scene_occupancy` 梯度表示边缘/边界，但不放入第一版实现。
- [ ] 将 `slope` 加回 `voxel_context`：使用 `scene_occupancy` 水平邻居差表示坡度偏好；第一版先由 `TargetSceneVoxel` 生成阶段直接规定目标。
- [ ] 将 `support_below` 从单点下方支撑扩展为 asset footprint 支撑点数量估计。
- [ ] 为 target context 增加 debug 可视化：显示 local/wide `A` 平均复杂度与主导颜色。

### MLP 感受视野

目标：用 MLP 替换或增强手工 `voxel_context -> semantic embedding`，但仍只在初始化 / dirty update 阶段运行，不进入 `score_voxel_tile.glsl` hot path。

#### Phase 1：tiny MLP

- [ ] 保留当前手工 16D context。
- [ ] 新增 tiny MLP：`16 -> 32 -> 16`。
- [ ] 输出 `learned_voxel_context[16]`。
- [ ] `select_voxel_assets.glsl` 使用 `learned_voxel_context × asset_embedding`。
- [ ] 增加开关：手工 context / learned context 可切换对比。

#### Phase 2：加入颜色与复杂度上下文

- [ ] 将 `target_scene_context_rgba8` 解包为 MLP 输入特征。
- [ ] 对 local/wide target context 做降维输入，例如 16 packed cells -> 16 到 32 维 float 特征。
- [ ] 学习 target color / complexity 与 asset preference 的非线性匹配。

#### Phase 3：训练数据

- [ ] 记录用户手动放置或修正的 `(voxel_context, target_context, asset_id)` 样本。
- [ ] 记录用户清空/拒绝放置的 `EMPTY` 样本。
- [ ] 导出离线训练数据。
- [ ] 训练后导入权重到 Godot shader buffer。

#### MLP 验收标准

- [ ] MLP 只影响 semantic routing。
- [ ] `score_voxel_tile.glsl` 不读取 MLP 输出。
- [ ] dirty update 只重新计算 affected voxels。
- [ ] 未启用 MLP 时，回退到手工 16D context。

---

## TargetSceneVoxel Projection

设计文档：

```text
docs/target-scene-voxel-projection.md
```

### 后续阶段

- [ ] Phase 1：保留现有 anchor 向外感知，继续使用 `target_scene_context_rgba8`。
- [ ] Phase 2：新增 `target_anchor_projection_rgba8`，先实现垂直柱压缩。
- [ ] Phase 3：将 projection 投影到 nearest support / ground anchor。
- [ ] Phase 4：增加水平扩散与 falloff，让树冠/大体积目标影响多个 anchor。
- [ ] Phase 5：为 asset 烘焙 `asset_anchor_pref_rgba8`。
- [ ] Phase 6：在 semantic matcher 中加入 `projection_score`。
- [ ] Phase 7：将 projection context 纳入 MLP / learned matcher。
- [ ] 评估 projection pooling 策略：高复杂度加权、Top-K、peak+mass、occupancy ratio、softmax pooling、双峰/分位数摘要。

---

## Asset Semantic Probes

设计文档：

```text
docs/asset-semantic-probes.md
```

### 后续阶段

- [ ] 定义 `SemanticProbe` 数据结构：offset、expected_rgba8、expected_collision、weight、flags。
- [ ] 从 asset voxelized profile 自动生成 probes。
- [ ] 实现分层 Top-K + 空间去重的 probe 选择策略。
- [ ] 为 tree / rock / grass 等 asset 增加可选关键点模板。
- [ ] 实现 ground anchor 生成，只遍历地面 / 可支撑 anchor。
- [ ] 实现 `select_ground_anchor_assets.glsl`，按 `anchors * assets * probes` 计算语义分数。
- [ ] 输出 ground anchor / voxel 级 top-K asset，并接入 tile routing。
