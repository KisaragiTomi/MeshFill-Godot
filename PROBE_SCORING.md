# Probe 评分方案（简化版）

每个 probe 携带三个独立的 metric 权重，**无 flag / kind 分支**。

## 数据结构

```text
probe = {
  offset:             Vector3,   # 相对采样位置
  expected_color:     Color,     # 期望颜色 (RGB + A=complexity)
  expected_collision: float,     # 期望碰撞强度
  w_color:            float,     # 颜色匹配权重
  w_complexity:       float,     # 复杂度匹配权重
  w_collision:        float,     # 碰撞匹配权重
  source:             String,    # 生成来源
}
```

## GPU 数据布局（2 × vec4 = 32 字节 / probe）

```text
d0 = (offset.x, offset.y, offset.z, w_collision)
d1 = (rgba8_bits, expected_collision, w_color, w_complexity)
```

## 评分公式

```text
sample_pos = anchor_pos + round(probe.offset / voxel_size)

target = target_field[sample_pos]

color_fit      = 1 − dist(target.rgb, expected.rgb) / √3
complexity_fit = 1 − |target.a − expected_complexity|
collision_fit  = 1 − |target.a − expected_collision|

probe_score = w_color × color_fit
            + w_complexity × complexity_fit
            + w_collision × collision_fit
```

## 聚合

```text
asset_score = Σ probe_score_i        # 所有 probe 直接求和
```

权重越大的 metric 对总分贡献越大；权重为 0 的 metric 不参与。

## Top-K

```text
topk[anchor][0..3] = 按 asset_score 降序取前 4 个 asset
```

## 自动生成规则

| 层 | w_color | w_complexity | w_collision | 说明 |
| --- | --- | --- | --- | --- |
| convex hull | 1 | 1 | 1 | 三项等权 |
| voxel interior | 1 | 1 | 1 | 三项等权 |
| voxel interior (底层 = support) | 0.05 | 0.05 | 1 | 只关注碰撞/支撑 |
| poisson surface | 1 | 1 | 1 | 三项等权 |
| context sensing | 1 | 1 | 1 | 三项等权 |
| **exclusion zone** | **0** | **0** | **-0.5** | **惩罚现有碰撞，防聚簇** |

底层 = voxel interior 中 Y 坐标最小的一层。

### 负权重与排斥区

权重允许负值。负的 `w_collision` 含义：

```text
exclusion probe: expected_collision=1.0, w_collision=-0.5

场景已有碰撞 → collision_fit ≈ 1.0 → score += -0.5 × 1.0 = -0.5 (惩罚)
场景无碰撞   → collision_fit ≈ 0.0 → score += -0.5 × 0.0 = 0.0 (无影响)
```

exclusion zone 自动在 AABB 外环生成（margin = 15% 半径），防止同类资产在相邻位置堆叠。

### SV 场景采样

`eval_probe` 同时采样 `target_field` 和 `complexity_coll`（场景已有状态）：

```text
collision_fit = 1 − |max(target.a, scene_collision) − expected_collision|
```

`max(target.a, scene_collision)` 确保已放置的物体碰撞也参与评分。

## 示例：一棵树

```text
tree_tall (auto-generated):
  probe[0..N] 非底层体素: w_color=1  w_complexity=1  w_collision=1
  probe[M..K] 底层支撑:   w_color=0.05  w_complexity=0.05  w_collision=1

anchor (128, 3, 200):
  普通: color_fit×1 + complexity_fit×1 + collision_fit×1
  底层: color_fit×0.05 + complexity_fit×0.05 + collision_fit×1 ≈ collision_fit
```

评分无 CPU 退路——所有 probe 评分均在 GPU 完成。

## 多轮迭代与残差填充

单次 prefilter 只选出当前 target demand 下的最优 asset。大型/高分 asset 先放置后，场景中会产生 **空腔**（放置模型与目标形状之间的间隙）。这些空腔通过多轮迭代自然由小型 asset 填充：

```text
TargetSV: 画了一片碰撞区域（目标形状）

Round 1 — prefilter → 树得分最高 → 放置树 → commit SV → blend
          ↳ 树的碰撞体只占目标的一部分，形状不完全吻合
          ↳ 空腔 = target demand 残差

Round 2 — prefilter（用更新后的 SV[t]）
          ↳ 已放置区域 target demand 降低
          ↳ 草/灌木 在空腔处得分升高 → 放置 → commit

Round 3 — ...直到 target demand 被消耗殆尽或低于阈值
```

**为什么能自动解决？**

- 每轮 `commit SV + blend_scene_voxels()` 后，已放置区域的 `complexity_field` 和 `collision_field` 升高
- `TargetSV_B.completely` 在已填充区域被消耗，残差集中在空腔
- 小型 asset（草）的 probe 权重全是 1，在小空腔中三项 fit 都能拿到高分
- 大型 asset（树）的 probe 采样到已放置区域，collision_fit 降低，不再重复放置

**示例：树 + 草填充**

```text
目标: 一块 4×4×3 的实心碰撞区域

Round 1:
  tree_tall 得分最高 → 放置在 (2,0,2)
  树干占 1×3×1 碰撞, 树冠占 2×1×2 复杂度
  残差: 除树干/树冠外的周围体素仍有 target demand

Round 2:
  树干位置 target 已消耗 → tree_tall 在此 anchor 分数降低
  草 probe (w=1,1,1) 在残差体素上匹配良好 → grass 进 top-K
  → 放置草填充空隙

Round 3:
  再次检查残差 → 可能还有小灌木能填
  ...
```

这个机制不需要额外的多样性逻辑——**迭代放置 + SV 更新 + 残差 target = 自然多样性**。

**核心思想：probe 的行为完全由三个权重控制，不再需要 flag 或 kind 分支。**
