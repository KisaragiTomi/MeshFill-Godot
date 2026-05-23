# AutoObject Probe 粗筛选

从 `SceneVoxel`（`SV`）中提取可放置 anchor，用 descriptor-backed semantic probes 对目标体素采样评分，把每个 anchor 的候选 `AutoObject` score / top-K 保留在 GPU anchor state 中，减少后续 GPU footprint scoring 的 dispatch 数量。

粗筛只负责语义匹配筛选，物理可行性由 `score_voxel_tile.glsl` 精筛完成。正常路径不需要把 score / top-K 回读到 CPU；CPU readback 只作为 debug、统计或旧接口兼容。

![AutoObject probe prefilter pipeline](../graphs/autoobject_probe_prefilter_pipeline.svg)

![AutoObject probe scoring logic](../graphs/autoobject_probe_scoring_logic.svg)

---

## `SceneVoxelActor` / 同生命周期容器

需要一个 actor-like runtime owner（暂名 `SceneVoxelActor`）统一持有与一个 SV epoch / tick 同生命周期的数据。它不是新的逐体素语义层，而是把 committed scene state、目标画布、资产 registry、anchor state 和 GPU route buffer 放到同一生命周期里管理。

| 子状态 | 归属 / 生命周期 | 存储要求 |
| --- | --- | --- |
| `SceneVoxel` / `SceneVoxelLocal` | 当前 `SV` epoch 及其 runtime sampling/query view | 跟随 `SV[tick]`；`scene_field` / `collision_field` 是 probe sampling、placement sampling、validation 和 debug 读取的 GPU/CPU buffer。 |
| `AnchorState` / `anchor_buffer` | 从 `SV` + `TargetSV_B` 派生的 GPU anchor state | 生命周期与当前 `SV` epoch 一致；保存 position-only anchors，score/top-K 使用 GPU sidecar，不作为 CPU 结果字典。 |
| `AutoObject` registry / probe buffers | 当前可用资产集合和 descriptor-backed semantic probes | 挂在 actor 下供 prefilter / placement 读取；probe 打包可按 asset registry 版本缓存。 |
| `TargetSV` | 源目标画布 | 需要持久化；用于重建、导入、debug 和与 brush delta 重新合成。 |
| `BrushSV` | 目标画布的笔刷 delta / override | 需要持久化；不要只把 brush 结果烘进 `TargetSV_B` 而丢失源笔刷层。 |
| `TargetSV_B` | `TargetSV + BrushSV` 的 brush-composited read buffer | 挂在 actor 下作为 prefilter / routing / scoring 的默认目标输入；可缓存 / 持久化，但权威来源是 `TargetSV` 与 `BrushSV`。 |
| dirty metadata | dirty voxel regions / compat dirty tiles / dirty rect / affected target bounds | 决定 actor 下哪些 GPU buffer 需要局部重建。 |

```text
SceneVoxelActor[tick]
  ├─ SceneVoxel[tick] / SceneVoxelLocal(scene_field, collision_field)
  ├─ TargetSV              // stored source target canvas
  ├─ BrushSV               // stored brush delta canvas
  ├─ TargetSV_B            // derived/composited target read buffer
  ├─ AutoObject registry + descriptor-backed probe buffers
  └─ AnchorState GPU buffers
       position-only anchors
       score/topK per anchor
       candidate route / voxel-region votes
```

---

## 目标与非目标

```text
SceneVoxelActor → anchor 提取 → probe 采样 → anchor score/top-K → GPU candidate route → dispatch
```

- **目标** — 排除不可放置位置；按 probe 语义匹配排序 asset；把 score / top-K 写入 anchor state，并生成 GPU candidate route / voxel regions 以限定 dispatch。
- **非目标** — 不替代 footprint 精筛；不做精确几何碰撞检测；不使用 `AutoObject.scale`（强制 `Vector3.ONE`）。

---

## Actor 输入 / GPU 输出

### 输入

| 数据 | 来源 | 用途 |
| --- | --- | --- |
| `SceneVoxelActor.SceneVoxelLocal` | 当前 `SV` epoch 的 runtime sampling/query view | anchor 可放置性、占用/碰撞/支撑、probe 采样和后续 placement 采样。 |
| `SceneVoxelActor.TargetSV_B` | `TargetSV + BrushSV` 的 brush-composited 目标场景体素 | probe scoring 的实际目标输入；源 `TargetSV` 与 `BrushSV` 都需要存储，便于重建 `TargetSV_B`。 |
| `SceneVoxelActor.AutoObject[]` | actor 下当前可用资产 registry | 通过 `AutoObject.get_semantic_probes()` 读取 descriptor-backed probes；颜色、复杂度、碰撞 voxel 也应来自 descriptor-backed getter 或明确的运行时约束字段。 |
| `SceneVoxelActor.dirty_tiles` | 编辑/生成阶段 | 当前兼容名；语义上限制粗筛 dirty voxel regions。 |

Buffer 映射：

| 字段 | Buffer |
| --- | --- |
| 当前占用 | `scene_field` |
| 当前碰撞 | `collision_field` |
| 目标强度 | `target_occupancy` |
| 目标颜色/复杂度 | `target_color` (packed `RGBA8`) |

### 输出

| 输出 | 含义 |
| --- | --- |
| `AnchorState` / `anchor_buffer` | GPU 常驻 anchor state；通过可放置测试的 position-only anchor voxel，以及每个 anchor 的 score / top-K sidecar。 |
| `candidate route buffer` / `voxel_sparse_votes` | GPU 常驻候选 voxel-region vote / route buffer；`voxel_sparse_votes` 是当前 shader buffer 兼容名。 |
| `autoobject_candidate_voxel_sparses` | 可选 CPU debug / 旧接口兼容视图；语义上是 per-asset candidate voxel regions，不是权威输出，也不是正常路径必需 readback。 |
| `debug_prefilter_score` | 可选调试体素 / overlay。 |

---

## TargetSV 生成

TargetSV 描述每个体素位置应填充的颜色、复杂度（value）和碰撞意图，不包含 asset 标签。目标架构使用 **AutoObject stamp** 绘制 TargetSV；当前实现为纯程序化过渡版。

详细设计见 [`target-scene-voxel-projection.md`](target-scene-voxel-projection.md)。

三条生成路径（可叠加）：

| 路径 | 来源 | 保真度 | 阶段 |
| --- | --- | --- | --- |
| **VDB 导入** | Houdini / DCC 离线导出 | 最高 | 离线基底层 |
| **AutoObject Stamp** | landscape 规则 + AutoObject `voxel_write_spec` | 高 | 运行时 stamp |
| **程序化生成** | landscape slope / height / rock_mask | 低（过渡版） | 当前实现 |

VDB 可作为基底层，stamp 在其上叠加增量修改，程序化版为无外部数据时的回退。

### 外部 VDB 导入

计划路径：未来用 `tools/vdb_to_target_sv.py` 转换器把多个 VDB 离线合并为 TargetSV flat buffer，输出格式与持久化兼容；Godot 侧再通过 `_load_external_target_sv()` 加载。当前仓库还没有这些文件/函数。

每个 VDB 包含 5 维标量 grid：`Cd.x`/`Cd.y`/`Cd.z` → visual.rgb (3), `density` → visual.a/complexity (1), `collision` → target_collision (1)。多 VDB 按顺序合并：visual lerp, collision max。

详见 [`target-scene-voxel-projection.md` § 外部 VDB 导入](target-scene-voxel-projection.md#外部-vdb-导入)。

### 目标架构：AutoObject Stamp

TargetSV 应由 stamp 系统绘制：landscape 规则调度 stamp，每个 stamp 使用 AutoObject 烘焙的 `voxel_write_spec` 作为画笔 kernel，将中性的 color + complexity + collision intent 写入 TargetSV。

```text
landscape height / slope / masks / rules
  ↓ target stamp scheduler
AutoObject voxel_write_spec (color, complexity, collision, local_pos)
  ↓ transform by stamp origin / basis / scale
  ↓ blend into TargetSV
TargetSV: color.rgb + complexity/value + collision intent
```

每个 AutoObject voxel 提供：

| Source voxel field | TargetSV usage |
| --- | --- |
| `local_pos` | 变换到目标 voxel 坐标 |
| `color` | 写入目标颜色 |
| `complexity` | 写入目标视觉复杂度 |
| `collision` / occupancy | 写入目标碰撞/solid intent |
| `weight` | 控制该 source voxel 对混合的贡献 |

Blend rule（visual 加权平均，collision 取 max）：

```text
target.rgb        = lerp(target.rgb, source.rgb, alpha)
target.complexity = lerp(target.complexity, source.complexity, alpha)
target.collision  = max(target.collision, source.collision * stamp.collision_opacity)
```

这样能保证 stamp 的目标形状和候选 AutoObject 的视觉/碰撞体积同构，probe 采样时自然匹配。低碰撞 stamp（草、树叶）不会抹掉已有的强碰撞（树干、岩石）。

### 当前实现（程序化过渡版）

当前使用 `target_scene_voxel.glsl` 从 landscape 参数程序化推导 rock/grass 信号，**不使用 AutoObject stamp**。后续应替换为 stamp-based 生成。

```text
scene_depth + target_height + rock_mask
         ↓  target_scene_voxel.glsl (GPU compute)
    evaluate_voxel() per (x, y, slice)
         ↓
    visual[]:    vec4(color.rgb, value)   — rgba32f, 16 bytes/voxel
    collision[]: float                    — r32f, 4 bytes/voxel
    preview:     image2D (rgba16f)        — 调试俯视图
```

| 文件 | 作用 |
| --- | --- |
| `scripts/target_scene_voxel_generator.gd` | GPU 宿主：创建 local RD、上传纹理、dispatch、回读 buffer |
| `shaders/target_scene_voxel.glsl` | compute shader：per-voxel 程序化材质评估 |

参数：

| 参数 | 默认值 | 含义 |
| --- | --- | --- |
| `texture_size` | 256 | XZ 分辨率，从 scene_depth 宽度取 |
| `slice_count` | 8 (`TARGET_SV_SLICE_COUNT`) | 垂直切片数 |
| `vertical_span` | 16.0 (`TARGET_SV_VERTICAL_SPAN`) | 垂直跨度 (m)，每切片 2m |
| `max_height` | 50.0 | 深度图最大高度 |
| `capture_size` | 120.0 | 正交捕获范围 (m) |
| `slope_start` / `slope_full` | `landscape_cliff_slope_*` | 坡度阈值 |

Per-voxel 程序化评估：

```text
terrain_h    = max_height - scene_depth.r
height_delta = max(target_h - terrain_h, 0)
slope        = length(surface_normal.xy)          // 0=平坦, 1=垂直
rock_signal  = max(smoothstep(slope), smoothstep(fill), rock_mask)
local_y      = (slice + 0.5) / slice_count * vertical_span

rock_value   = rock_signal × vertical_falloff(rock_top)
grass_value  = flat_signal × grass_vertical × (1 - rock_signal) × 0.45

color     = weighted blend(rock_color, grass_color)
value     = max(rock_value, grass_value)
collision = max(rock_value × 0.95, grass_value × 0.08)
```

局限性：
- **颜色/复杂度固定** — rock (0.56,0.52,0.46) / grass (0.20,0.48,0.18) 硬编码，不反映实际 AutoObject 材质。
- **无 asset 形状信息** — 纯 2D 高度差 + 坡度推导，不包含树干/树冠/灌木等 3D 结构。
- **probe 匹配精度受限** — stamp-based 生成时 probe 采样到的 TargetSV_B 与候选 AutoObject 同构，程序化版无此保证。

### TargetSV / TargetSV_B → Prefilter Buffer 映射

无论由 stamp 还是程序化生成，源 TargetSV 与 brush-composited TargetSV_B 到 prefilter 的 buffer 映射相同；prefilter 默认读取 TargetSV_B：

| TargetSV_B 输出 | Prefilter Buffer | 转换 |
| --- | --- | --- |
| `target_visual[].rgb` (color) | `target_color` 的 RGB 通道 | pack 为 RGBA8 高位字节序 |
| `target_visual[].a` (value) | `target_color` 的 A 通道 (complexity) | pack 为 RGBA8 低 8 位 |
| `target_collision[]` | `target_occupancy` | 直接使用 float |

TargetSV_B 的 `value`（视觉密度）在 prefilter 中作为 `complexity` 参与评分，`collision`（碰撞强度）作为 `target_occupancy` 参与评分。

### Probe 越界处理

当 probe 采样位置超出 SceneVoxelLocal grid 边界时（例如大型 asset 的高处或边缘 probe），采样位置 **clamp 到最近的 in-bounds voxel**，而非跳过。这保证所有 probe 都参与评分，避免边缘处因 probe 被跳过导致评分失真。

```text
if not in_bounds(sample_pos):
    sample_pos = clamp(sample_pos, (0,0,0), grid_size - 1)
```

GPU 实现见 `shaders/score_anchor_asset_probes.glsl`；GDScript 只负责 actor 侧资源组织、buffer 打包和 dispatch。正常路径下 score / top-K 保留在 GPU `AnchorState` / route buffer 中，不需要回读到 CPU。

### 持久化

`TargetSV` 与 `BrushSV` 是需要保存的源状态；`TargetSV_B` 是二者合成后的默认读取目标，可缓存 / 持久化，但不应取代源画布和笔刷 delta。当前目标场相关结果保存到 `user://target_scene_voxel/`：

| 文件 | 格式 |
| --- | --- |
| `target_scene_voxel_visual.rgba32f` | 源 `TargetSV` visual flat binary, `voxel_count × 16` bytes |
| `target_scene_voxel_collision.r32f` | 源 `TargetSV` collision flat binary, `voxel_count × 4` bytes |
| `BrushSV` delta / override | 目标画布笔刷层；需要独立保存，避免只剩合成结果 |
| `target_scene_voxel_b_visual.rgba32f` | `TargetSV_B` visual cache：`TargetSV + BrushSV` 合成结果 |
| `target_scene_voxel_b_collision.r32f` | `TargetSV_B` collision cache：`TargetSV + BrushSV` 合成结果 |
| `target_scene_voxel_preview.png` / `target_scene_voxel_b_preview.png` | RGBA8 PNG 俯视预览 |
| `target_scene_voxel.json` / `target_scene_voxel_b.json` | 元数据 (version, dims, paths) |

---

## 阶段 1：Anchor 提取

Anchor 分两个位置来源提取，但写入同一个 **position-only** `anchor_buffer`。不再存 `anchor_kind`；位置本身表达它来自支撑面还是目标顶部 / 上层目标信号。

- **Ground anchor** — 现有地面/支撑层，用于 anchor 在底部或脚点的资产。
- **Target top anchor** — 从 `TargetSV_B` 每个 XZ column 提取最高目标体素，用于 anchor 在顶部的资产，例如部分 rock。

Ground anchor 对底层 dirty tile 内每个 voxel 判断是否可放置：

```text
scene_field[p]     <= 0.15   // 基本为空
collision_field[p] <= 0.05   // 无明显碰撞
support_below(p)       >= 0.25   // 下方有支撑
target_occupancy[p]    >= 0.01   // 目标有需求
```

`support_below(p)` 初版定义：

```text
support_below = max(scene_field[p + down], collision_field[p + down])
```

Target top position 对底层 dirty tile 覆盖的局部 XZ column 取最高目标体素：

```text
p = highest voxel in whole XZ column where target_occupancy[p] >= 0.01
target_occupancy[p + up] < 0.01 or out_of_bounds(p + up)
scene_field[p]     <= 0.15
collision_field[p] <= 0.05
```

`target_top` 不强制 `support_below >= MIN_SUPPORT`，因为它是语义对齐点，不一定是物理落点。若该最高点已经满足支撑条件，ground position 检查会写入同一位置；否则 target-top path 会额外写入该 position。最终物理可行性仍由 footprint scoring 确认。

Anchor 记录：

```text
anchor_buffer[i] = uvec4(voxel_x, voxel_y, voxel_z, 0)  // w reserved

// CPU debug / compatibility readback
{
  id: uint,
  voxel_pos: Vector3i,
}
```

---

## 阶段 2：Probe 定义

通过 `auto_object.get_semantic_probes(density)` 获取。该 getter 从 `AutoVoxelDescriptor.semantic_probe_profile` 读取或生成 probes；`AutoObject` 上的同名字段只作为 Inspector / 配置字典兼容入口。约束：`scale = Vector3.ONE`，`offset` 按 asset/local space 使用。

`probe.offset` 必须相对当前资产声明的 anchor / pivot 原点生成。若资产需要顶部、中部或脚点对齐，应在资产自身的 pivot / probe profile 中体现；prefilter 不再通过 `anchor_kind` 在 anchor 记录里区分这些来源。

| 字段 | 用途 |
| --- | --- |
| `offset` | 相对 anchor 的采样偏移 |
| `expected_rgba8` | 期望颜色与复杂度 |
| `expected_collision` | 期望碰撞/实体强度 |
| `flags` | 控制参与哪些评分项 |
| `weight` | probe 权重 |
| `kind` | `positive` / `negative` |
| `source` | `convex` / `voxel_interior` / `surface` / `context` |

### Context Sensing Probes

小型资产（草、灌木）的 mesh AABB 很小，标准 probe 感受野有限，难以检测周围残余 TargetSV_B。通过 descriptor 上的 `context_sensing_radius` 在 mesh AABB 外围生成额外 probe；`AutoObject.context_sensing_radius` 只作为 Inspector / 配置字典兼容入口：

```text
context_sensing_radius = 0.0  → 禁用（默认，适合大型 rock）
context_sensing_radius = 2.0  → 感受野向外扩展 2m（适合 grass）
context_sensing_radius = 1.0  → 中等扩展（适合 bush）
```

Context probe 特征：
- **offset 超出 mesh AABB**，分布在 `[inner_r, inner_r + sensing_radius]` 环形区域
- **flags**: `FLAG_COLLISION | FLAG_COLOR`，主要检测残余 target collision
- **weight 随距离衰减**：`w = r_decay * y_decay * 0.35`，避免远处信号喧宾夺主
- **优先级最低**（Phase 4），核心 mesh probe 先占满预算，剩余位置给 context probe
- `target_count` 按 `context_sensing_radius * density * 4` 追加额外预算（上限 32）

典型场景：石头放置后周围残余 collision voxel 不足以注册新石头，草的 context probe 采样到残余 target → 得分高 → 入 top-K → 精筛通过 → 间隙被填。

`target_top` rock 不应强制依赖 support probe；物理支撑与碰撞仍交给 footprint scoring。

---

## 阶段 3：Probe 采样与评分

```text
score_autoobject(anchor, auto_object):
  total_score = 0, total_weight = 0
  for probe in auto_object.get_semantic_probes(density):
    sample_pos = anchor.voxel_pos + voxelize(probe.offset)
    sample = read TargetSV_B at sample_pos
    probe_score = score_probe(sample, probe)
    total_score += probe_score * probe.weight
    total_weight += probe.weight
  return total_score / max(total_weight, epsilon)
```

采样字段：`target_color.rgb` → color, `target_color.a` → complexity, `target_occupancy` → collision, `scene_field` → occupied, `SV[p+down]` → support。

### 地下 Probe 规则

当 probe 采样位置处于地面以下（`scene_field[sample_pos] >= UNDERGROUND_OCC_THRESHOLD`，默认 0.5）时：

- **除碰撞检测以外的所有评分内容权重归零**。
- 没有 `FLAG_COLLISION` 的 probe：整条 probe 的 weight = 0（在 `score_autoobject` 中 skip）。
- 有 `FLAG_COLLISION` 的 positive probe：仅计算 `collision_fit`，color/complexity 权重 = 0。
- Empty/negative/support probe 即使带 `FLAG_COLLISION`：返回 0（这些 probe 类型无碰撞评分含义）。

```text
if scene_field[sample_pos] >= UNDERGROUND_OCC_THRESHOLD:
  if !(flags & FLAG_COLLISION): weight = 0, skip
  if flags & FLAG_EMPTY or kind == negative: return 0
  if flags & FLAG_SUPPORT: return 0
  return collision_fit_only
```

### 评分公式

**Positive probe**：

```text
color_fit      = 1 - distance(sample.rgb, expected.rgb) / sqrt(3)
complexity_fit = 1 - abs(sample.a - expected.a)
collision_fit  = 1 - abs(sample_collision - expected_collision)
probe_score    = color_fit * w_color + complexity_fit * w_complexity + collision_fit * w_collision
```

**Empty/negative probe**：`1 - max(sample_complexity, sample_collision, sample_scene_occupied)`

**Support probe**：`clamp(sample_support, 0, 1)`

### Flag 控制

| Flag | 行为 |
| --- | --- |
| `FLAG_COLOR` | 参与 `color_fit` |
| `FLAG_COMPLEXITY` | 参与 `complexity_fit` |
| `FLAG_COLLISION` | 参与 `collision_fit` |
| `FLAG_EMPTY` | 使用 `empty_score` |
| `FLAG_SUPPORT` | 使用 `support_score` |

---

## 阶段 4：Top-K 选择与 Voxel Region 聚合

每个 anchor 先检查自身 256 个 asset 的 probe 汇总评分，过滤低质量结果，再按得分降序取 top-K（`top_k = 4`）。最终是否放置仍由后续 placement 精筛决定。

Voxel region 聚合：

```text
for anchor in AnchorState.topK:
  for autoobject in anchor.topK:
    for affected_region in asset_footprint_regions(anchor, autoobject):
      vote[autoobject][affected_region] += anchor.score
region_autoobject_topK = topK(vote)
// 输出: GPU candidate route buffer / voxel_sparse_votes (compat buffer name)
// 兼容视图: autoobject_candidate_voxel_sparses[autoobject_id] = [voxel_region_pos: Vector3i...]
```

`run_multi_asset()` 只对命中的 candidate voxel regions 运行 footprint scoring。

`target_top` anchor 的资产 footprint 可能位于 anchor 下方，因此 voxel region 聚合必须按 asset 的 anchor-relative footprint AABB 扩展候选区域，不能只使用 anchor 所在区域。

聚合输出不是精确采样点集合。由于 asset probes 会对 `TargetSV_B` / `SceneVoxel` 做插值采样，candidate voxel regions 还应覆盖 semantic probe offset bounds、`context_sensing_radius` 和至少 1 voxel 的 interpolation guard；宁可让更多 voxel 进入候选，再交给 footprint scoring 精筛。

---

## 实现

基于现有 `SceneVoxelLocal`、`AutoObject`、`SemanticProbeProfile` 接口。Probe prefilter 只保留 GPU 路径；CPU 版已删除，因为 `anchor_count × asset_count × probe_count` 的完整采样量会在 GDScript 上造成过高运算压力。

GPU 落地实现：

| 文件 | 作用 |
| --- | --- |
| `scripts/autoobject_probe_prefilter_gpu.gd` | GPU 宿主：probe 打包、4-pass dispatch、GPU anchor / route buffer 生成；CPU readback 只用于当前兼容返回值、debug 或统计。 |
| `shaders/collect_sv_anchors.glsl` | Dispatch 1 — dirty voxel regions（底层 dirty tiles）→ position-only anchor 收集（atomic append） |
| `shaders/score_anchor_asset_probes.glsl` | Dispatch 2 (Pass A) — 16×16 workgroup，anchor×asset probe 评分 |
| `shaders/select_anchor_topk.glsl` | Dispatch 3 (Pass B) — 256 线程/anchor，top-K asset 选择 |
| `shaders/reduce_anchor_topk_to_voxel_regions.glsl` | Dispatch 4 — anchor top-K → per-asset candidate voxel-region vote 聚合 |

GPU-only 约束：

- 不保留 `scripts/autoobject_probe_prefilter.gd` CPU fallback。
- 不在 GDScript 中遍历完整 `anchor × asset × probe` 组合。
- 调试验证可通过可选 GPU readback、debug overlay、少量 fixture 和 RenderDoc 完成；主路径不依赖 score / top-K CPU readback。

## GPU Compute Shader

### 约束

```text
MAX_ASSETS_PER_ANCHOR = 256
MAX_PROBES_PER_ASSET  = 128
WORKGROUP_SIZE        = 16 × 16 = 256 threads
ASSET_LANES           = 16 assets / workgroup
PROBE_LANES           = 16 probe lanes / asset
```

### 规模估算

```text
ground anchors     ≈ 256 × 256 = 65536
target_top anchors ≤ 256 × 256 = 65536
assets             = 256
probes             ≤ 128 / asset
总采样             = anchor_count × 256 × 128 (上界，实际按 anchor 层、asset mask、probe 数缩减)
```

### Dispatch 策略：四 Pass Pipeline

完整 GPU 管线拆为 4 个 dispatch：

1. **Collect** — 从 dirty voxel regions（底层 dirty tiles）收集 anchor，atomic append 到 actor 的 GPU `AnchorState`。
2. **Score (Pass A)** — 16 asset lanes × 16 probe lanes，sharedgroup 归约 probe 评分，写入 GPU sidecar / anchor score buffer。
3. **Top-K (Pass B)** — 每 anchor 256 线程加载 asset scores，串行 top-K 选择，结果留在 GPU `anchor_topk`。
4. **Reduce** — 扫描 GPU `anchor_topk`，累加 per-asset voxel-region vote / route buffer。

Pass A/B 使用二维 anchor dispatch：`anchor_grid_x = ceil(sqrt(anchor_count))`，`anchor_grid_y = ceil(anchor_count / anchor_grid_x)`。

```text
Pass A — score_anchor_asset_probes.glsl (sharedgroup 统计 probe)
  dispatch       = (anchor_grid_x, anchor_grid_y, ceil(asset_count / 16))
  workgroup_size = (16, 16, 1)
  local_x        = asset lane，1 个 workgroup 覆盖 16 个 asset
  local_y        = probe lane，每个 asset 用 16 条 lane stride 处理自身 probes
  sharedgroup    = shared_score[16][16] + shared_weight[16][16]
  输出           = asset_scores[anchor_id * 256 + asset_id]

Pass B — select_anchor_topk.glsl (anchor 内 asset 筛选)
  dispatch       = (anchor_grid_x, anchor_grid_y, 1)
  workgroup_size = (16, 16, 1)
  local_id       = local_y * 16 + local_x = asset_id 0..255
  sharedgroup    = shared_scores[256]
  行为           = 每个 anchor voxel 检查内部 256 个 asset 的 probe 汇总评分
  输出           = anchor_topk[anchor_count * TOPK]
```

映射关系：

```text
Pass A:
  anchor_id   = gl_WorkGroupID.y * anchor_grid_x + gl_WorkGroupID.x
  asset_block = gl_WorkGroupID.z
  asset_lane  = gl_LocalInvocationID.x       // 0..15
  probe_lane  = gl_LocalInvocationID.y       // 0..15
  asset_id    = asset_block * 16 + asset_lane
  probe_i     = probe_lane; probe_i < probe_count; probe_i += 16

Pass B:
  anchor_id   = gl_WorkGroupID.y * anchor_grid_x + gl_WorkGroupID.x
  local_asset = gl_LocalInvocationID.y * 16 + gl_LocalInvocationID.x // 0..255
```

选择理由：

- **固定 16×16** — 每组 256 线程，兼容 Godot/Vulkan compute 的常见 workgroup 规模。
- **按 probe 数分配** — 每个 asset 读取自己的 `probe_count`，16 条 probe lane stride 处理，短 probe asset 自动少循环。
- **sharedgroup 统计** — 线程组内先写 `shared` score/weight，再由每个 asset lane 的 `probe_lane == 0` 做列归约。
- **Pass B 独立筛选** — 每个 anchor 一组，256 线程正好覆盖 256 个 asset score，先阈值过滤再 top-K。
- **二维 anchor dispatch** — `anchor_grid_x * anchor_grid_y >= anchor_count`，避免单维 dispatch 超过设备限制。
- **不依赖 subgroup 扩展** — 不需要 `GL_KHR_shader_subgroup_arithmetic`，避免不同 GPU wave size 差异。

### Buffer 布局

```text
// Probe 扁平打包，按 asset_id 连续排列
asset_probe_range[MAX_ASSETS]   // uvec2: { start_index, probe_count }, index = asset_id
probe_packed[total_probe_count] // 每条 probe = 2 × vec4:
  // vec4[0]: offset.x, offset.y, offset.z, weight
  // vec4[1]: expected_rgba8(as float bits), expected_collision, flags(as float bits), kind(as float bits)

// 场景数据 (已有 buffer 复用)
scene_field[voxel_count]     // float
collision_field[voxel_count] // float
target_occupancy[voxel_count]    // float
target_color[voxel_count]        // uint (packed RGBA8)

// Dispatch 1 输出
anchor_buffer[ANCHOR_CAPACITY]   // uvec4: { voxel_x, voxel_y, voxel_z, reserved }
anchor_count                     // uint: atomic counter，Dispatch 1 后回读确定实际 anchor 数

// 中间 (Pass A 输出 → Pass B 输入)
asset_scores[ANCHOR_CAPACITY * 256] // float: 每 anchor 固定保留 256 个 asset 汇总评分

// Pass B 输出 → Dispatch 4 输入
anchor_topk[ANCHOR_CAPACITY * TOPK] // uvec2: { asset_id, score_as_float_bits }

// Dispatch 4 输出
voxel_sparse_votes[asset_count * tile_count] // current compat buffer; each (asset, voxel region) vote
```

### Shader 总览

| # | Shader | Dispatch | Workgroup | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `collect_sv_anchors.glsl` | `(dirty_tile_count, 1, 1)` | `(8, 8, 8)` | 底层 tile per workgroup；两类位置来源合并为 position-only anchor，atomic append |
| 2 | `score_anchor_asset_probes.glsl` | `(anchor_grid_x, anchor_grid_y, ceil(asset_count / 16))` | `(16, 16, 1)` | **Pass A** — 16 asset lanes × 16 probe lanes，sharedgroup 归约 |
| 3 | `select_anchor_topk.glsl` | `(anchor_grid_x, anchor_grid_y, 1)` | `(16, 16, 1)` | **Pass B** — 每 anchor 检查 256 asset 分数，阈值过滤 + top-K |
| 4 | `reduce_anchor_topk_to_voxel_regions.glsl` | `(1, 1, 1)` | `(1, 1, 1)` | 串行扫描 anchor top-K，累加 per-asset voxel-region vote |

Dispatch 1 收集 anchor 后需要让后续 Pass A/B 知道 `anchor_count`。当前兼容宿主可回读这个标量来决定 dispatch 维度；目标架构中它应作为 `SceneVoxelActor.AnchorState` 的 GPU/indirect dispatch metadata 常驻，不等同于回读每个 anchor 的 score / top-K。

### Dispatch 1 伪代码: `collect_sv_anchors.glsl`

```glsl
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

layout(set = 0, binding = 0, std430) restrict readonly  buffer SceneOcc    { float scene_occ[];    };
layout(set = 0, binding = 1, std430) restrict readonly  buffer CollisionOcc{ float collision_occ[]; };
layout(set = 0, binding = 2, std430) restrict readonly  buffer TargetOcc   { float target_occ[];   };
layout(set = 0, binding = 3, std430) restrict readonly  buffer DirtyTiles  { uint  dirty_tile_ids[];};
layout(set = 0, binding = 4, std430) restrict           buffer AnchorOut   { uvec4 anchors[];      };
layout(set = 0, binding = 5, std430) restrict           buffer AnchorCount { uint  anchor_count;   };

layout(push_constant, std430) uniform Params {
    ivec4 grid_size_pad;          // xyz = grid dims, w = dirty_tile_count
    ivec4 tile_grid_size_pad;     // xyz = tile grid dims, w = anchor_capacity
    vec4  thresholds;             // x=max_scene, y=max_coll, z=min_support, w=min_target
};

shared int s_top_y[8][8];        // target_top: highest Y per (lx, lz) column

// 每个 workgroup 处理一个底层 dirty tile (8×8×8 voxels)
// ground: 逐 voxel 检查可放置条件 + support_below，atomic append
// target_top: 用 shared atomicMax 找每列最高 target voxel，ly==0 线程 emit
```

### Pass A 伪代码: `score_anchor_asset_probes.glsl`

```glsl
#version 450
layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0) readonly  buffer AnchorBuf   { uvec4 anchors[];           };
layout(set = 0, binding = 1) readonly  buffer ProbeRange   { uvec2 asset_probe_range[]; };
layout(set = 0, binding = 2) readonly  buffer ProbeData    { vec4  probe_data[];        };
layout(set = 0, binding = 3) readonly  buffer SceneOcc     { float scene_occ[];         };
layout(set = 0, binding = 4) readonly  buffer CollisionOcc { float collision_occ[];     };
layout(set = 0, binding = 5) readonly  buffer TargetOcc    { float target_occ[];        };
layout(set = 0, binding = 6) readonly  buffer TargetColor  { uint  target_color[];      };
layout(set = 0, binding = 7) writeonly buffer ScoresOut    { float asset_scores[];      };

layout(push_constant, std430) uniform Params {
    ivec4 grid_size_asset_count;  // xyz = grid dims, w = asset_count
    vec4  voxel_size_inv;         // xyz = 1/voxel_size, w = unused
    uint  anchor_count;
    uint  anchor_grid_x;
    float min_prefilter_score;
    float _pad0;
};

const uint MAX_ASSETS      = 256u;
const uint ASSET_LANES     = 16u;
const uint PROBE_LANES     = 16u;
const uint FLAG_COLOR      = 1u;
const uint FLAG_COMPLEXITY = 2u;
const uint FLAG_COLLISION  = 4u;
const uint FLAG_EMPTY      = 8u;
const uint FLAG_SUPPORT    = 16u;

shared float shared_score[16][16];
shared float shared_weight[16][16];

int voxel_index(ivec3 p) {
    return p.x + grid_size_asset_count.x * (p.z + grid_size_asset_count.z * p.y);  // XZY order
}

bool in_bounds(ivec3 p) {
    return all(greaterThanEqual(p, ivec3(0))) && all(lessThan(p, grid_size_asset_count.xyz));
}

vec4 unpack_rgba8(uint packed) {
    return vec4(
        float((packed >> 24u) & 0xFFu) / 255.0,  // R
        float((packed >> 16u) & 0xFFu) / 255.0,  // G
        float((packed >>  8u) & 0xFFu) / 255.0,  // B
        float((packed >>  0u) & 0xFFu) / 255.0   // A
    );
}

const float UNDERGROUND_OCC_THRESHOLD = 0.5;

float eval_probe(ivec3 sp, uint flags, uint kind, vec4 e_col, float e_coll) {
    int idx = voxel_index(sp);
    float s_scene = scene_occ[idx];

    // Underground: only collision scoring contributes
    if (s_scene >= UNDERGROUND_OCC_THRESHOLD) {
        if ((flags & FLAG_COLLISION) == 0u) return 0.0;
        if ((flags & FLAG_EMPTY) != 0u || kind == 1u) return 0.0;
        if ((flags & FLAG_SUPPORT) != 0u || kind == 2u) return 0.0;
        return clamp(1.0 - abs(target_occ[idx] - e_coll), 0.0, 1.0);
    }

    // Empty / negative
    if ((flags & FLAG_EMPTY) != 0u || kind == 1u) {
        vec4 sc = unpack_rgba8(target_color[idx]);
        return 1.0 - max(sc.a, max(target_occ[idx], s_scene));
    }

    // Support
    if ((flags & FLAG_SUPPORT) != 0u || kind == 2u) {
        ivec3 below = sp + ivec3(0, -1, 0);
        if (!in_bounds(below)) return 0.0;
        int bi = voxel_index(below);
        return clamp(max(scene_occ[bi], collision_occ[bi]), 0.0, 1.0);
    }

    // Positive
    vec4 sc = unpack_rgba8(target_color[idx]);
    float s_coll = target_occ[idx];
    float score = 0.0, wsum = 0.0;
    if ((flags & FLAG_COLOR) != 0u) {
        score += 1.0 - distance(sc.rgb, e_col.rgb) / 1.732;
        wsum += 1.0;
    }
    if ((flags & FLAG_COMPLEXITY) != 0u) {
        score += 1.0 - abs(sc.a - e_col.a);
        wsum += 1.0;
    }
    if ((flags & FLAG_COLLISION) != 0u) {
        score += 1.0 - abs(s_coll - e_coll);
        wsum += 1.0;
    }
    return score / max(wsum, 1e-6);
}

void main() {
    uint anchor_id   = gl_WorkGroupID.y * anchor_grid_x + gl_WorkGroupID.x;
    uint asset_block = gl_WorkGroupID.z;
    uint asset_lane  = gl_LocalInvocationID.x; // 0..15
    uint probe_lane  = gl_LocalInvocationID.y; // 0..15
    uint asset_count = min(uint(grid_size_asset_count.w), MAX_ASSETS);
    uint asset_id    = asset_block * ASSET_LANES + asset_lane;

    float lane_score  = 0.0;
    float lane_weight = 0.0;

    if (anchor_id < anchor_count && asset_id < asset_count) {
        uvec4 anchor = anchors[anchor_id];
        ivec3 anchor_pos = ivec3(anchor.xyz);

        uvec2 range = asset_probe_range[asset_id];
        uint probe_start = range.x;
        uint probe_count = range.y;

        for (uint i = probe_lane; i < probe_count; i += PROBE_LANES) {
            uint pi = (probe_start + i) * 2u;
            vec4 d0 = probe_data[pi];
            vec4 d1 = probe_data[pi + 1u];

            vec3  offset = d0.xyz;
            float weight = max(d0.w, 0.0);
            uint  rgba8  = floatBitsToUint(d1.x);
            float e_coll = d1.y;
            uint  flags  = floatBitsToUint(d1.z);
            uint  kind   = floatBitsToUint(d1.w);

            ivec3 sp = anchor_pos + ivec3(round(offset * voxel_size_inv.xyz));
            if (in_bounds(sp)) {
                // Underground: skip non-collision probes (weight = 0)
                float s_scene = scene_occ[voxel_index(sp)];
                if (s_scene >= UNDERGROUND_OCC_THRESHOLD && (flags & FLAG_COLLISION) == 0u) {
                    continue;
                }
                vec4 e_col = unpack_rgba8(rgba8);
                float ps = eval_probe(sp, flags, kind, e_col, e_coll);
                lane_score  += ps * weight;
                lane_weight += weight;
            }
        }
    }

    shared_score[asset_lane][probe_lane] = lane_score;
    shared_weight[asset_lane][probe_lane] = lane_weight;
    barrier();

    if (probe_lane == 0u && anchor_id < anchor_count && asset_id < MAX_ASSETS) {
        float sum_score = 0.0;
        float sum_weight = 0.0;
        for (uint py = 0u; py < PROBE_LANES; py++) {
            sum_score += shared_score[asset_lane][py];
            sum_weight += shared_weight[asset_lane][py];
        }
        float final_score = asset_id < asset_count ? sum_score / max(sum_weight, 1e-6) : -1.0;
        asset_scores[anchor_id * MAX_ASSETS + asset_id] = final_score;
    }
}
```

### Pass B 伪代码: `select_anchor_topk.glsl`

```glsl
#version 450
layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0) readonly  buffer ScoresIn { float asset_scores[]; };
layout(set = 0, binding = 1) writeonly buffer TopKOut  { uvec2 anchor_topk[];  };

layout(push_constant) uniform Params {
    uint  anchor_count;
    uint  asset_count;
    uint  anchor_grid_x;
    float min_prefilter_score;
};

const uint MAX_ASSETS = 256u;
const uint TOPK = 4u;

shared vec2 shared_scores[256]; // x=score, y=asset_id

void main() {
    uint anchor_id = gl_WorkGroupID.y * anchor_grid_x + gl_WorkGroupID.x;
    uint tid = gl_LocalInvocationID.y * 16u + gl_LocalInvocationID.x;
    uint asset_count_clamped = min(asset_count, MAX_ASSETS);

    float score = -1.0;
    if (anchor_id < anchor_count && tid < asset_count_clamped) {
        score = asset_scores[anchor_id * MAX_ASSETS + tid];
        if (score < min_prefilter_score) {
            score = -1.0;
        }
    }
    shared_scores[tid] = vec2(score, float(tid));
    barrier();

    if (tid == 0u && anchor_id < anchor_count) {
        for (uint k = 0u; k < TOPK; k++) {
            float best = -1.0;
            uint best_id = 0xFFFFFFFFu;

            for (uint j = 0u; j < asset_count_clamped; j++) {
                if (shared_scores[j].x > best) {
                    best = shared_scores[j].x;
                    best_id = uint(shared_scores[j].y);
                }
            }

            if (best_id == 0xFFFFFFFFu) {
                anchor_topk[anchor_id * TOPK + k] = uvec2(0xFFFFFFFFu, floatBitsToUint(-1.0));
            } else {
                anchor_topk[anchor_id * TOPK + k] = uvec2(best_id, floatBitsToUint(best));
                shared_scores[best_id].x = -2.0;
            }
        }
    }
}
```

### Dispatch 4 伪代码: `reduce_anchor_topk_to_voxel_regions.glsl`

```glsl
#version 450
layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly  buffer AnchorBuf { uvec4 anchors[];      };
layout(set = 0, binding = 1, std430) restrict readonly  buffer TopKIn    { uvec2 anchor_topk[];  };
layout(set = 0, binding = 2, std430) restrict           buffer VoxelRegionVotes { float voxel_sparse_votes[]; };

layout(push_constant, std430) uniform Params {
    ivec4 tile_grid_size_pad;   // xyz = tile grid dims, w = tile_count
    uint  anchor_count;
    uint  asset_count;
    uint  topk;
    uint  _pad0;
};

// 串行扫描所有 anchor 的 top-K 结果
// anchor.xyz → tile_id → voxel_sparse_votes[asset_id * tile_count + tile_id] += score
// tile_id is the bottom-level storage/workgroup key for a voxel region
// 输出作为 GPU candidate route buffer 常驻；CPU Vector3i 列表只作为兼容/debug readback
```

### GPU 宿主调度流程

```text
1. _pack_all_probes()      — 将所有 AutoObject probe 扁平打包为 GPU buffer
2. Dispatch 1: collect     — dirty voxel regions → anchor buffer (atomic append)
3. submit() + sync()       — 当前兼容可回读 anchor_count；目标为 GPU/indirect metadata
4. anchor_grid_x = ceil(sqrt(anchor_count))
   anchor_grid_y = ceil(anchor_count / anchor_grid_x)
5. Dispatch 2: score       — (anchor_grid_x, anchor_grid_y, ceil(asset_count/16))
6. submit() + sync()
7. Dispatch 3: topk        — (anchor_grid_x, anchor_grid_y, 1)
8. submit() + sync()
9. Dispatch 4: reduce      — (1, 1, 1)
10. submit() + sync()      — route buffer 常驻 GPU；CPU readback 只用于 debug / 旧接口
11. optional _decode_results() — voxel_sparse_votes → per-asset sorted Vector3i voxel-region lists
```

---

## 与现有放置流程的关系

```text
// 现有流程
collision_voxels → bake_footprint → run_minimal → score_voxel_tile → reduce → stamp

// 加入粗筛
SceneVoxelActor(SV + TargetSV_B + AutoObject registry)
  → probe prefilter
  → AnchorState(score/topK) + GPU candidate route buffer
  → run_multi_asset / score_voxel_tile
```

粗筛只减少候选，不直接写入场景。`autoobject_candidate_voxel_sparses` 是当前 CPU debug / 兼容视图；权威运行时结果应是 actor 生命周期内的 GPU `AnchorState` 和 candidate route buffer。

---

## Debug 输出

| Debug 层 | 含义 |
| --- | --- |
| `placeable_anchor_positions` | position-only anchor；可用 Y / column / support 条件区分地面或目标顶部来源 |
| `best_autoobject_id` | 可选 readback / overlay 中显示的最高分 AutoObject |
| `best_semantic_score` | 可选 readback / overlay 中显示的最高 probe 分 |
| `rejected_reason` | 支撑不足 / 目标过低 / probe 分数过低 |

---

## 验收标准

### 功能正确性

- 从 `SV` 稳定提取支撑面 position-only anchors。
- 从 `TargetSV_B` 每个 dirty XZ column 稳定提取最高目标体素 position-only anchors。
- `anchor_topk` 按 `anchor.id` 存储；anchor 记录不携带 `anchor_kind`。
- 每个 anchor 遍历对应 asset 的 descriptor-backed semantic probes 并计算分数。
- 不同 asset 按 probe 匹配得到不同排序。
- 空白/低目标区域不输出大量 asset。
- 粗筛输出 GPU `AnchorState` / candidate route buffer 以限定 dispatch，并为 probe 插值采样保留扩张边界；`autoobject_candidate_voxel_sparses` 只作为 CPU 兼容 / debug 视图。
- 最终放置由 footprint scoring 物理确认。

### GPU 管线

- 4 个 compute shader 编译成功，无 GLSL → SPIR-V 错误。
- Dispatch 1 atomic counter 正确累计 anchor 数，不超过 `ANCHOR_CAPACITY`。
- Pass A 使用 `16×16` 线程组，结合每个 asset 的 `probe_count` 分配 probe lane，并在 sharedgroup 内完成 score/weight 统计。
- Pass B 让每个 anchor voxel 检查自身 256 个 asset 的 probe 汇总评分，过滤低质量结果后输出 anchor 级 top-K。
- Dispatch 4 candidate voxel-region vote 聚合结果能在 GPU route buffer 中按 asset 分组稳定表达。
- GPU 版 `run_probe_prefilter()` 的权威输出应能直接接入后续 GPU placement dispatch；当前 `autoobject_candidate_voxel_sparses` 字典只保留为兼容接入 `VoxelPlacementGenerator` 的临时 readback 视图。
- `voxel_index` 使用 XZY 展开顺序，`unpack_rgba8` 使用 R=bits[24:31] 高位优先字节序。

---

## TODO：后续优化

按优先级逐步减少 `anchor_count × asset_count × probe_count` 的完整采样量。

### P0：Asset 粗分流

- [ ] 为 anchor / voxel region 计算 cheap context signature。
- [ ] 为每个 `AutoObject` 预烘焙 `asset_context_signature`。
- [ ] 先用 context dot / distance 从 256 个 asset 缩到 16~32 个 asset shortlist。
- [ ] 后续 full probe scoring 只处理 shortlist 内 asset。

### P1：Probe 两级评分

- [ ] 将 `semantic_probes` 拆成 `core_probes` 与 `detail_probes`。
- [ ] `core_probes` 保留 support、negative/empty、高权重 convex、关键 collision probe。
- [ ] 第一轮只跑 `core_probes`，淘汰低分 asset。
- [ ] 第二轮只对 core 高分 asset 跑 full probes。

### P2：Probe 排序与提前拒绝

- [ ] 按拒绝能力排序 probe：support → negative/empty → high-weight convex → collision → color/complexity。
- [ ] 每 16 个 probe 做一次 chunk 统计。
- [ ] 根据 `current_score + remaining_weight` 估算最高可能分。
- [ ] 若最高可能分低于 `MIN_PREFILTER_SCORE`，提前拒绝该 asset。

### P3：Probe 数量分桶

- [ ] 按 `probe_count` 分桶：`1~32`、`33~64`、`65~128`。
- [ ] 小 probe asset 使用更短 loop / 专用 dispatch。
- [ ] 避免少 probe asset 与大 probe asset 混合导致 lane 浪费。

### P4：带宽与缓存优化

- [ ] 将 probe buffer 从 `2 × vec4` 压缩为半精度 / packed 格式。
- [ ] 评估 `offset` 使用 `int16` 或 `snorm16`。
- [ ] 评估 `weight` / `expected_collision` 使用 `float16`。
- [ ] 评估 voxel region 内 expanded TargetSV_B preload，减少相邻 anchor 重复采样。

### P5：结构级优化

- [ ] 增加 voxel-region 级 prefilter：`region_context → region_asset_shortlist`。
- [ ] anchor probe scoring 只处理所属 voxel region 的 asset shortlist。
- [ ] 将 asset 按语义 probe 聚类成 group。
- [ ] 先选择 group top-K，再在 group 内选择 asset top-K。

---

## Open Questions

- `SV` 与 `TargetSV_B` 是否分离：anchor 可放置性读 `SV`，语义匹配读 `TargetSV_B`；源 `TargetSV` 只保留生成、持久化和 debug/import 回查。
- `probe.offset` 到 voxel 坐标的换算是否使用统一 `voxel_size`。
- `FLAG_EMPTY` / `FLAG_SUPPORT` 是否需在 `SemanticProbeProfile` 生成阶段补齐。
