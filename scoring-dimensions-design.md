# 精细语义打分:可拓展维度系统设计

## 目标

把 placement 打分从「写死的公式」(support / collision / complexity / clearance 四项 + 固定权重)
改成**数据驱动的维度表**:

- 一个「维度(Dimension)」= 一个打分轴。
- 新增打分维度 = **加数据**(维度表一行 + 场一个通道 + 资产画像一列),**不改 shader 结构、不改公式**。
- 真正的打分逻辑落在 **VPG(`VoxelPlacementGenerator`)+ score shader**;
  demo 只负责**声明用哪些维度 + 提供数据 + 调用**,不含打分逻辑。

命名:这套 per-voxel 的打分即「**精细语义打分**」。

---

## 核心模型:维度 =(场通道 × 拟合模式 × 权重)+ 每资产取值

**一句话**:一个「维度(Dimension)」= 一个**打分轴 / 一条比较标准**——拿**资产画像在该轴上的期望值**,
去比**环境场在该通道上的实际值**,得到一个 `0..1` 契合度,再按权重并入总分。把「环境特征」和「资产画像」
都看成一个向量,每个维度就是这个向量空间里的**一根坐标轴**;打分 = 在每根轴上量二者的接近程度、再合并。
这既是它叫「维度」的原因,也是为何**加一条判据 = 加一根轴(加数据),不改 shader**。

一个维度的字段:

| 字段 | 含义 |
|---|---|
| `channel` | 读环境场的哪一路通道 |
| `mode` | 怎么比;当前只实现 `MATCH`(`fit = 1 − |env − asset|`),`PENALTY` / `GATE` 预留未实现(fit=0) |
| `weight` | 该轴在总分里的权重 |
| `min` / `max` | 该轴取值范围;**当前 `MATCH` 未消费**(预留给归一化,现直接用原始 `0..1` 值) |

打分**两侧来源不同**:**环境侧** = `env_channels[voxel]`(TargetSV / 场景场实际长什么样);
**资产侧** = `asset_dimension_profile`(资产“想匹配 / 代表”的值)。见下「判断源」。

### 三张表

```text
// ① 维度注册表(全局,一行 = 一个打分轴)
Dimension {
  name          // "collision_fit" / "color_fit" / "complexity_fit" / "collision_gate" …
  field_channel // 读场(环境)的哪个通道
  fit_mode      // MATCH | PENALTY | GATE   ← 唯一的"代码",小枚举
  weight        // 进 score 的权重(GATE 可为 0)
  constraint    // 可选:有效性门 { min, max }
}

// ② 场(环境)= 每体素多通道特征向量,可加通道
Field[voxel] = float[channel_count]
  ch0   = collision      // 刚性占据(可视化里的白色 voxel)
  ch1   = complexity     // 视觉复杂度
  ch2..4 = color.rgb     // 颜色
  ch5+  = 未来(坡度 / 湿度 / 生态区 / 遮挡 …)
  ※ 来源:TargetSV / 场景场(环境),不是 AssetDescriptor。

// ③ 资产画像 = 资产在每个维度轴上的取值,可加列
AssetProfile[asset] = float[dimension_count]
  ※ 来源:AssetDescriptor(见「判断源」)。
  rock = { collision:0.9, complexity:0.2, color:灰… }
  tree = { collision:0.1, complexity:0.8, color:绿… }
```

### 打分 = 一个循环(在 VPG / score shader 内)

```text
// 每个 (voxel, asset) 的语义分 = 各维度契合度的加权平均
score(voxel, asset) = ( Σ_d  dim[d].weight · fit( dim[d].mode,
                                                  Field[voxel][dim[d].channel],
                                                  AssetProfile[asset][d] ) )
                      / Σ_d dim[d].weight        // 归一化 → 落在 fit 量纲(MATCH ⟹ 0..1)

valid(voxel, asset) = 有 target coverage(collision 采样覆盖到 TargetSV 内容)   // 无约束型维度不设门;胜者 = 最高语义分
```

> GPU 版(`score_voxel_tile.glsl`, `dim_count > 0`)按 **collision 采样权重**逐体素累加同一公式,分母是参与的
> 采样权重和;`valid` 仅要求 `target_coverage > 0`(MATCH 维度本身不淘汰),否则写 `INVALID_SCORE`
> (`-1e18`)哨兵。下游 reduce / stamp 一律按 **valid flag** 取舍,不看分数符号。

**加一个新维度** → 追加 `Dimension` 一行 + `Field` 一个通道 + `AssetProfile` 一列;
shader 只按 `dimension_count` 循环,**不改**。这就是可拓展性的落点。

---

## 拟合模式(fit_mode,小枚举)

初始系统只用一种模式:

| 模式 | 语义 | 累加 |
|---|---|---|
| `MATCH` | 资产画像与场越接近越好 | `+= (1 − |field − asset|)` |

> **按需加模式**:真正要新增一种「拟合方式」时,才加一个枚举 + 一个 shader 分支;
> 新增「维度」若用现有模式则是纯数据。
> 已按此原则去掉 `SUPPORT`(锚点已保证)、`PENALTY` / `GATE`(collision 改走 `MATCH`;无悬垂 / 堆叠)。
> 将来若需「物理不穿插」或「堆叠净空」,再加回 `PENALTY` / `GATE` 模式即可。

---

## 判断源(重要)

打分有两侧,分别来自不同的地方:

- **资产侧**(`AssetProfile`,每维取值)——**全部来自 `AssetDescriptor`**:
  现有 `color` / `complexity` / `collision` 直接映射到对应维度;
  未来新维度在 descriptor 上加一个**可拓展的「维度画像」字段**(`dimension_name → value`)。
  ✔ 「打分判断源来自 asset descriptor」——**仅就资产这半边成立**。
  （注:资产的 collision 画像**已由 descriptor 派生**——demo 与 SPA 同走 profile 容器注册,
  注册期烘焙的 collision_records 常驻 GPU 供 score/stamp 直读;无 collision 的资产按 mesh AABB
  合成采样注册,旧的每-run 形状烘焙通道已于 2026-07-11 删除。)

- **环境侧**(`Field`,每体素通道)——来自 **TargetSV / 场景场**(环境),**不是 descriptor**。

- 打分 = 拿「资产画像(descriptor)」去比对「环境场(TargetSV)」。

---

## 旧物理项如何处理(全部去掉)

| 旧项 | 处理 |
|---|---|
| ~~support~~ | **删除**(锚点已保证支撑) |
| ~~clearance~~ | **删除**(inert:无悬垂 / 堆叠) |
| ~~collision 淘汰 / gate~~ | **删除** 物理门;collision 改由 `collision_fit`(MATCH)以语义方式承载 |

新系统 = **纯语义特征匹配**(3 条判据 / 5 行 `MATCH` 维度,颜色 = r/g/b),无物理门。

结果:anchor 28(TargetSV collision 高、无植被色)→ rock 的 `collision_fit` 高、`color_fit` 符 → **石头赢**;
tree 因 `collision_fit` 低、`color_fit` 不符而落败。

## 初始维度集(当前实现)

概念上 **3 条判据**,实现成 **5 行维度表**(颜色 = r/g/b 三个标量通道,各占 ~0.34 权重,合计 ≈1.0,
避免颜色相对 collision / complexity 被三倍加权)。全部 `MATCH`、无 gate。对应 demo 的
[`_scoring_dimensions()`](demos/placement-score-3d/volume_score_demo.gd),`channel` 一一对应 5 通道
环境场 `[collision, complexity, r, g, b]`:

| # | 维度 | 场通道 (channel) | mode | weight | 说明 |
|---|---|---|---|---|---|
| 1 | `collision_fit` | 0 collision | `MATCH` | 1.0 | 岩石地(高 collision)配石头 |
| 2 | `complexity_fit` | 1 complexity | `MATCH` | 1.0 | 复杂度匹配 |
| 3 | `color_fit.r` | 2 color.r | `MATCH` | 0.34 | 颜色匹配(r) |
| 4 | `color_fit.g` | 3 color.g | `MATCH` | 0.34 | 颜色匹配(g) |
| 5 | `color_fit.b` | 4 color.b | `MATCH` | 0.34 | 颜色匹配(b) |

资产侧 `asset_dimension_profile` = `[mean_collision_strength, complexity, color.r, color.g, color.b]`
(5 值,与 5 通道对齐;由 `AssetDescriptor` 派生)。

> **上限**:资产画像现由两个 `vec4`(`cfg_asset_profile0 / 1`)承载 ⟹ 最多 **8 维**;超出需另建
> per-asset profile SSBO。维度表(`_pack_dimension_table`)本身上限 `MAX_SCORING_DIMENSIONS = 16`。

---

## 落地范围(逻辑都在 VPG,demo 只调用)

1. **`AssetDescriptor`**:把 `color` / `complexity` / `collision` 推广成可拓展的「维度画像」(`dimension_name → value`)。
2. **场**:TargetSV / 场景场 → **多通道特征场**(先 collision / complexity / color,预留通道)。
3. **`score_voxel_tile.glsl`**:per-voxel 内层改为 **per-dimension 循环**;push constant 加 `dim_count`
   (`env_channel_count` / 资产画像 / 惩罚权重走 `ScoreConfig` SSBO,push 受 128B 上限所限);
   `score` = 加权和,`validity` = 约束与。
4. **`VoxelPlacementGenerator`(VPG)**:构建 / 打包 **维度表 + 资产画像 + 多通道场**;
   **默认空维度表 → 对 SPA 等其他调用方向后兼容**。**打分逻辑集中在此 + shader。**
5. **demo(`volume_score_demo`)**:只**声明维度集 + 喂 TargetSV + 调 VPG**,不含打分逻辑。

---

## 实施状态

- **Phase 1(历史,CPU 参考实现,已移除)**:最早用一版 CPU 数据驱动打分打通数据契约(维度表 / 资产画像 / 锚点特征聚合)并验证语义分化。**该 CPU 参考实现已随 Phase 2 落地删除**——`score_dimensions` / `_build_asset_profiles` / `_build_anchor_features` 等函数**在代码里已不存在**,仅此处留档;当前**无 CPU 打分路径**,demo 只保留 `_scoring_dimensions()`(声明维度集)。
  - 效果(当时):分数分化,放置按语义分布(不再树通吃)。
- **Phase 2(已落,GPU)**:同一份数据契约(维度表 / 画像 / 多通道场)已端口进 `score_voxel_tile.glsl`(上面第 3 项),数据驱动 per-dimension MATCH 打分在 GPU 上跑通并经编辑器验证。
  - support 分支 / 门 / 分项已移除(锚点已保证支撑),`support_ratio/hit/total` 记录槽保留但恒 0;collision 采样烘焙(现于容器注册期)不再产生 `FLAG_SUPPORT` ground-probe。
  - per-voxel 内层已改为 **per-dimension 循环**:`score = Σ_d weight_d·fit_d`(MATCH = `1-|env_ch - asset_profile|`)按采样权重归一;`dim_count == 0` 走原 penalty-only 分支(逐字节等价,向后兼容)。
  - **维度表 / 资产画像 / 多通道场**由 VPG 打包:维度表 = set0 binding 9(`_pack_dimension_table`),多通道场 = binding 8;资产画像 + 惩罚权重 + `env_channel_count` + `collision_records` 起始偏移(`cfg_sample_range`,2026-07-11 新增)移入 **`ScoreConfig` SSBO(set0 binding 10,`_pack_score_config`)**——因 push constant 受 Godot **128 字节**上限所限(超限会被静默拒绝→shader 收到全零 push),打分参数不能再全塞 push。push 现固定为 8×16 = 128B。
  - 编辑器验证(placement-score-3d,256×16×256,3 资产 × 64 锚点):分数分化真实(如锚点 51 leaf 0.314 / cliff_02 0.230 / cliff_01 0.193;锚点 52/60 cliff_02 胜出),winner 随位置翻转,无 push/GPU 报错。

---

## 向后兼容

- 维度表为空(`dimension_count == 0`)时,scorer 退化为 **penalty-only 老路**(collision/complexity/clearance 罚分,run_multi_asset / SPA 走此路),**其他调用方不受影响**。
- 新增维度权重默认 0 时,对既有打分结果无影响,可灰度接入。

---

## 明确不在范围

- **探针语义预筛**(coarse prefilter,`score_anchor_asset_probes` / `semantic_probe_profile`):
  属于**粗筛选**,保持独立,**不并入**本维度系统。
- `support` / `clearance` / `collision_gate` 维度:**已删除**(support 锚点已证实;clearance / 物理门不再需要,collision 改走 `collision_fit`(MATCH))。
