# 高维体素 × 多资产的匹配扩展方案（感受野聚合 vs 深度学习）

本文回答一个扩展性问题：当资产数 `N` 与每体素语义通道数 `C` 增长时，现有「probe 粗筛 →
residual-gain 细筛」链路还能不能保住放置速度与准确性；如果不能，深度学习应该替换哪一段、
何时替换。现管线契约见 [`doc/auto-object-probe-prefilter.md`](doc/auto-object-probe-prefilter.md)、
[`doc/scene-voxel-field-system.md`](doc/scene-voxel-field-system.md)。本文是 plan 文档，
按用户要求存放在仓库根目录（`doc/` 收纳规则的显式例外）。

先校准一件事：「为每个体素找到最适合放置的物体」不是新需求——anchor 就是 target 体积内的
体素（地形相对采样层），粗筛 top-K + 细筛 winner 已经在逐 anchor 做这件事。所以真正的问题是
**打分内核随 `N` 与 `C` 的扩展性**，而不是缺一个逐体素选资产的机制。

## 结论

| 规模区间 | 判定 | 路线 |
| --- | --- | --- |
| `N ≤ 64`（Arena 现容量）且 `C = 5` 且 recall@4 达标 | 不上深度学习 | 方案 A：量测 + 无学习强化；现瓶颈不在维度也不在感受野 |
| `N ∈ 64–256` 或新增评分侧通道（`C > 5`）或 recall@4 掉线 | 引入学习 | 方案 B：two-tower 蒸馏替换粗筛打分内核，handoff 契约与细筛不动 |
| `N > 256`（超 `MAX_ASSETS` 容量）或开放式资产库 | 重构粗筛 | 方案 C：全场 embedding field + 近邻检索（远期） |

对提问的两个半句分别回答：

- **「当前体素维度是否足够、高维信息靠感受野获得？」——对一半。** 邻域上下文（感受野）
  当前架构已经显式存在：coarse probe 的 offset 采样集与 fine 的全 `ProfileSample` 遍历
  （实测最大 12,806 点/资产）本身就是资产形状驱动的稀疏感受野，`context` probe 还专门做
  AABB 外围环采样。所以**不需要**为"获得邻域信息"引入深度学习。但感受野换不来另外三样：
  通道间非线性交互（现打分是线性加权和）、跨资产共享的表示（每资产独立手工权重）、通道
  扩张时的自动标定。这三样才是深度学习（表示学习）的真实收益位。
- **「用深度学习为每个体素选最合适资产」——成立，但只替换粗筛打分内核。** 细筛
  residual gain 是对 TargetSV 的精确逐格判定（`loss_before - loss_after`，合成规则与
  stamp 逐字节一致），它是端到端准确性的底线，**不由模型替代**。这与
  [`doc/auto-object-probe-prefilter.md`](doc/auto-object-probe-prefilter.md) TODO 中
  「MLP 只作候选内二次验证、不绕过 prefilter、不替代细筛」的既有边界一致；本方案动的是
  粗筛内核本身，产出仍是 `anchor_candidate_handoff` top-K。

## 现状成本模型

记号：`A` = anchor 数（实测 45,552 @ `anchor_vertical_stride = 0`，随靶数据变化——另一版
靶数据实测 22,588；容量 131,072）；`N` = 资产数（当前 5，Arena 容量 64，
`MAX_ASSETS = 256`）；`P` = 每资产 coarse probe 数（density 1.0 实测：grass 1 / leaf 9 /
cliff 25，上限 128）；`S` = 每资产 fine `ProfileSample` 数（实测最大 12,806，槽容量
16,384）；`K = 4`（编译期契约）；pivot 实测 ≤ 3（容量 8）；yaw 档 `rotation_slots`
默认 12；`C` = 每体素语义通道数（当前 5：R/G/B/complexity/collision，8bit unorm，
scene + target 双场）。

| 阶段 | 成本公式 | 当前量级（推算） | 随 `N` | 随 `C` |
| --- | --- | --- | --- | --- |
| anchor 收集 | `O(体素数)` | 一次全 dirty 扫描 | 无关 | 无关 |
| coarse 打分（`score_anchor_asset_probes.glsl`） | `A × N × P` 次采样，每次 4 读 | ≈ 5.7M 次采样 | **线性** | 线性（读数与 fit 项） |
| top-K 选择 | `A × N` | 0.23M 比较 | 线性 | 无关 |
| fine 细筛（`score_anchor_asset_residual.glsl`） | `A × K × S` 流式读；pivot×yaw 组合在寄存器累加 | ≈ 4–5 × 10⁸ 次 sample 流读 | **与 `N` 解耦（只看 `K`）** | 线性 |
| NMS reduce | 预算 256 轮，GPU 自检收敛 | 与得分结构相关 | 间接 | 无关 |
| `asset_scores` 显存 | `A × N × 4 B` | 45,552 × 5 ≈ 0.9 MiB | 线性（满容量 131,072 × 256 = 128 MiB，transient） | 无关 |

三个结构性结论：

1. **两级漏斗已经把 `N` 挡在细筛之外**：细筛成本只含 `K`，资产库涨到 256 也不碰细筛。
   `N` 的增长只打粗筛（线性）——粗筛每 (anchor, asset) 只有 ≤ 128 次采样，`N = 256` 时
   约 2.9 × 10⁸ 次采样（当前的 ~50 倍，推算），对用户触发的 Place（非每帧）仍可承受。
   **算力不是第一个撞墙点。**
2. **第一个撞墙点是 recall**：`N = 5` 时 top-4 几乎无损；当库里出现几十个相似资产
   （如 30 种石头变体），线性加权和 + 手工权重分不开它们，细筛真正的最优资产可能被挤出
   top-4——细筛再准也救不回没进候选的资产。准确性风险全部集中在这里。
3. **第二个撞墙点是通道扩张的手工位点**。评分侧每加一个通道要同时改五处：
   新常驻 field buffer 对（scene + target）；`ProfileSample` 32 B 记录的 `payload` 打包位
   （`reserved` u32 只够再塞约 4 个 8bit 通道，再多就得 bump Arena `layout_version`）；
   `evaluate_profile_sample` 的 coarse/fine 两套公式；每 probe 的新权重 authoring 与标定；
   `score_match_config.cfg` 的新维度 budget。若新通道要进提交（stamp），还要定义 compose
   语义——这一条深度学习也豁免不了。

## 方案 A：无学习强化（`N ≤ 64`、`C = 5` 区间的默认路线）

保持线性加权和内核，砍常数、护 recall：

| 手段 | 做法 | 收益 | 极限 |
| --- | --- | --- | --- |
| A1 tile 级预剪枝 | 复用 `SceneVoxelTile` 摘要（8×8×8）先做 tile × asset 粗判，只让通过的资产进 anchor 级打分 | coarse 从 `A × N` 降到 `A × N'`，`N' ≪ N`；一支新 shader，无训练 | 摘要是均值级信号，剪枝阈值保守才不伤 recall |
| A2 资产聚类代表元 | bake 期按 probe 统计（期望色/复杂度/碰撞分布）把 `N` 聚成 `M` 簇，先评代表元再展开胜出簇 | 等价于手工 ANN；`N > 64` 前最便宜的续命手段 | 簇内相似资产的区分仍靠线性内核，恰是它的弱项 |
| A3 提升 / 自适应 `K` | 直接升 `TOPK`（细筛线性变贵），或只对得分平坦（歧义）的 anchor 扩 K | 直接补 recall | `TOPK` 是编译期契约，自适应 K 破坏 handoff 定长布局，需改交接结构 |

方案 A 修不了的：打分函数的表达力上限（线性、手工权重、通道无交互）与通道扩张的五个
手工位点。这两条撞上任意一条，转方案 B。

## 方案 B：two-tower 蒸馏（推荐的学习方案）

### 替换点与边界

只换 `score_anchor_asset_probes.glsl` 这一支的内核，管线其余全部不动：

```text
collect_sv_anchors.glsl                      # 不动
  -> anchor_embed.glsl（新）                 # 每 anchor：多尺度邻域采样 -> 小 MLP -> d 维嵌入
  -> anchor_asset_dot.glsl（新）             # A x N 内积 -> asset_scores（布局与现 buffer 相同）
  -> select_anchor_topk.glsl                 # 不动
  -> anchor_candidate_handoff                # 不动（SCOPE_PERSISTENT，one_origin_per_anchor）
  -> score_anchor_asset_residual.glsl 细筛   # 不动：准确性底线仍是精确 residual gain
  -> NMS / compact / stamp                   # 不动
```

- 体素塔（在线，GPU）：输入 = 以 anchor 为中心的多尺度固定采样（例如中心 3³ + 两级半径
  角点 + 所在 tile 摘要，约 40 个 tap × 10 通道 = scene 5 + target 5），输出 `d = 16`
  嵌入。感受野在这里由网络显式吃进去，替代手工 probe offset。
- 资产塔（离线，bake 期）：输入 = 该资产 `ProfileSample` 集合（offset / rgba / collision /
  权重）的 PointNet-lite 聚合，输出同维嵌入；注册时随 `register_asset()` 上传一块
  `N × d` 小 SSBO（256 × 16 × fp16 = 8 KiB）。Arena slot 预留的 128 B `MeshDescription`
  区也放得下（d ≤ 32 fp32），但独立 SSBO 不动 Arena 布局版本，先选后者。
- `score(anchor, asset) = dot(e_anchor, e_asset)`：粗筛从「每 (anchor, asset) 显式邻域
  采样 `O(P × C)`」变成「一次编码 + `O(d)` 内积」。新资产入库 = 算一条嵌入，**零权重调参**；
  新评分侧通道 = 编码器多一个输入位，**五个手工位点消失**。

### 规模数字（推算）

| 项 | 量级 |
| --- | --- |
| 体素塔参数 | 400→128→64→16 MLP ≈ 60k 参数（fp16 权重 ≈ 120 KiB SSBO） |
| 体素塔算力 | ≈ 60k MAC/anchor × 131k anchors ≈ 8 × 10⁹ MAC，桌面 GPU ms 级 |
| 内积 pass | `A × N × d` = 131k × 256 × 16 ≈ 5.4 × 10⁸ MAC |
| 嵌入显存 | anchor 侧 `A × d` fp16 = 4 MiB；资产侧 8 KiB |

关键对比：`N = 256` 时粗筛采样内核 ≈ 2.9 × 10⁸ 次 **4 读采样**（访存约束），two-tower
是一次编码后纯算术内积（算力约束且与 `P` 无关）——`N` 与 `C` 同时涨时差距继续拉大。

### 训练数据与蒸馏

- **teacher 是细筛，不是现粗筛**：粗筛的职责是预测「哪些资产能在细筛胜出」，所以标签取
  细筛全资产扫描的 per-anchor 分数/valid（按 `K = 4` 分批喂全部资产即可得到，无需改
  shader）。student 直接对 recall@K 负责，蒸馏目标用 listwise 排序损失（每 anchor 对
  `N` 个资产 softmax），不回归重尾的原始分值。
- **采集只走 `-e` 编辑器 + bridge（127.0.0.1:6800）**，落盘 `(anchor, asset, fine_score,
  valid)` 与 anchor 邻域 patch；本仓 runtime/headless 启动是被禁的，采集工具不得例外。
- **数据集必须携带版本键**：descriptor hash 集合、target bake 版本、grid 参数、
  `score_match_config`。重烘会整体替换评分数据源（采样密度、clearance 都会变），版本键
  不匹配的数据禁止混训。
- 任何 CPU/Python 侧的公式镜像只准用于增广，且须与 GPU dump 逐项精确相等校验后才可用
  （中间量一律 float64，防截断漂移）。
- 冷启动数据量：`A × N` 标签/场景快照（45k × 64 ≈ 2.9M），几十个靶数据快照即到 10⁸
  量级，无需人工标注。

### 上线与验收

- shadow A/B：同一次 Place 双跑两个粗筛内核，比较 (1) recall@4（以细筛全扫为真值）、
  (2) 最终 accepted 放置的分数和与数量。对比用**集合级指标**——emit 槽位下标每次重排，
  逐槽位对比无效。
- 新 shader 过既有离线 GLSL 编译门禁与 `-e` 门禁；权重 SSBO 带模型 hash，与数据集版本键
  同源。
- 回退开关：粗筛内核可逐 Place 切回 probe 路径（两内核共用 `asset_scores` 布局与
  top-K pass，切换零迁移成本）。

## 方案 C：远期（`N > 256` 或开放式资产库）

- 全场 embedding field：每 tick 对 SV + TargetSV 跑一次稀疏 3D 编码（UNet / 稀疏卷积），
  产出常驻逐体素嵌入场；Place 时 anchor 直接查场，摊销掉逐 anchor 编码。
- 资产侧全库预编码 + 近邻检索（`N` 大到内积扫不动时才需要；`N ≤ 10³` 量级暴力内积仍然
  便宜，不要提前上 ANN）。
- 细筛与 stamp 仍然保持非学习的精确判定不变——任何规模下这条都不放。

## 方案对比

| 维度 | A 无学习强化 | B two-tower 蒸馏 | C embedding field + 检索 |
| --- | --- | --- | --- |
| 速度随 `N` | 线性（剪枝降常数） | 编码一次 + `O(d)` 内积 | 同 B 且编码摊销到 tick |
| recall 随资产相似度 | 线性内核，相似资产分不开 | 排序蒸馏直接优化 recall@K | 同 B |
| 通道扩张成本 | 五个手工位点全在 | 编码器加输入位 + 重训 | 同 B |
| 工程成本 | 低（1–2 支 shader） | 中（训练管线 + 2 支 shader + 版本管理） | 高 |
| 新增风险 | 无 | 训练数据版本失效、train/serve 偏差 | 常驻显存、tick 延迟 |
| 触发条件 | 现规模默认 | `N > 64` 或 `C > 5` 或 recall@4 掉线 | `N > 256` 或开放库 |

## 落地里程碑

| 阶段 | 内容 | 产出 / 判据 |
| --- | --- | --- |
| S0 量测基线（无论选哪条路都先做） | RD timestamp 分段计时 coarse / fine / NMS；bridge 驱动细筛全资产分批扫描，建立 recall@4 真值基线；顺手落地数据 dump 工具与版本键 | 「撞墙点在哪」从推算变实测；S0 的 dump 工具即 S2 的采集工具 |
| S1（A 路线） | tile 预剪枝 + 资产聚类代表元 | coarse 常数下降且 recall@4 不降 |
| S2（B 路线） | 离线蒸馏训练；`anchor_embed` / `anchor_asset_dot` 两支 GLSL；shadow A/B | recall@4 ≥ probe 基线且不低于 0.95（初始阈值，S0 后校准）；accepted 集合分数和不降 |
| S3 通道扩张 | 新评分侧通道只进编码器输入；提交侧通道另行定义 stamp compose 语义 | 加通道不再触碰五个手工位点 |

## 风险与开放问题

- **数据版本失效**：重烘 descriptor / target 即作废旧标签，版本键强校验是硬约束，不是
  可选项。
- **train/serve 偏差**：输入本来就是 8bit unorm 量化值，student 训练直接吃量化后数据，
  无偏差来源；权重 fp16。teacher 标签一律来自 GPU 真实管线 dump。
- **推理预算**：Place 是用户触发的非每帧操作，ms 级编码 pass 预算宽松；嵌入 buffer 4 MiB
  量级，transient。
- **`TOPK = 4` 是否保留**：B 路线提升 recall 后 4 可能继续够用；若仍不够，升 K 只线性
  加细筛成本，与 B 正交。
- **开放**：tile 摘要是否作为体素塔的一个输入尺度（免采样、现成常驻）；资产塔是否直接
  在 bake 链里出嵌入并存进 descriptor `.tres`（随 descriptor hash 版本化）。
