# Vegetation Placement Pipeline

![MeshFill current framework](../graphs/meshfill_current_framework.svg)

## Overview

植被放置系统基于 **高度分带（Height-Band）** 的互斥占用机制，所有波段打包在一张 **RGBA16F** 纹理中，通过 GPU Compute Shader 加速处理。粗树干等刚体部分另写独立 `collision_occupancy`，用于最终放置互斥。

**4 种植被类型，每种占据一个主要高度波段：**

```
Terrain → Rocks → VegetationExclusion(GPU)
                    ├─ canopy_tree  → canopy     (A)  6m+
                    ├─ midstory_tree → midstory  (B)  2–6m
                    ├─ bush         → understory (G)  0.3–2m
                    └─ grass        → ground     (R)  0–0.3m
                  → AutoSceneVoxel + BrushSceneVoxel
                  → blend_scene_voxels()
                  → CollisionVoxel
                  → SceneVoxel → Voxel Volume → Validate → (loop / place)
```

这条链路不是同步副作用调用，而是按 `generation_tick` 分批提交：当前 tick 的自动生成、笔刷修改和表面变化先写入 delta，commit 后才成为下一 tick 可读取的 `SceneState`。

---

## 1. Buffer 定义

### 1.1 Packed Occupancy Buffer (`_occupancy`)

单张 RGBA16F Image @ 256×256，每通道对应一个高度波段：

```
┌─────────────────────────────────────────────────────────┐
│                  _occupancy (RGBA16F)                    │
│                     256 × 256                           │
├──────────┬──────────┬──────────┬──────────┤             │
│  R 通道  │  G 通道  │  B 通道  │  A 通道  │             │
│  ground  │understory│ midstory │  canopy  │             │
│  ch=0    │  ch=1    │  ch=2    │  ch=3    │             │
├──────────┼──────────┼──────────┼──────────┤             │
│ 0-0.3m   │ 0.3-2m   │ 2-6m     │ 6m+      │ 高度范围   │
│ cplx=1.0 │ cplx=0.7 │ cplx=0.4 │ cplx=0.2 │ 复杂度     │
│ 绿色     │ 黄色     │ 蓝色     │ 红色     │ 调试颜色   │
└──────────┴──────────┴──────────┴──────────┘
```

**像素语义：**
- `0.0` = 空闲
- `> 0.01` = 已占用，值 = 该波段的 `complexity`（`color.a`）

### 1.2 Band Color（float4 = 一个 Color）

```
Color(R, G, B, A)
       │  │  │  └── complexity (0.0-1.0) 复杂度/密度
       └──┴──┘
       调试可视化颜色 RGB
```

每个波段仅需一个 `Color` 即可携带调试颜色 + 复杂度，无需额外字段。

### 1.3 其他关键 Buffer

| Buffer | 格式 | 分辨率 | 来源 | 用途 |
|--------|------|--------|------|------|
| `rock_mask_img` | RF | 256² | CliffGenerator | 岩石遮罩，阻止所有植被 |
| `collision_occupancy` | RF | 256² | `collision_voxels` | 粗树干/刚体互斥层 |
| `scene_depth_img` | RF | 256² | 场景深度捕获 | 地形高度 |
| `candidate_img` | RGBAH | 256² | GPU compute (band_filter) | 候选像素图，R=1.0 if unblocked |

---

## 2. Pipeline 流程（generation tick 解耦）

`generation_tick` 是所有生成系统之间的同步边界。每个系统只读上一轮已经提交的 `SceneState[tick - 1]`，只写当前轮的 delta；只有 commit 阶段会把本轮 delta 混合并发布为 `SceneState[tick]`。

```text
SceneState[tick - 1]
  ├─ surfaces
  ├─ occupancy
  └─ SceneVoxel

Systems at generation_tick = tick
  ├─ auto systems  → AutoSceneVoxelDelta[tick]
  ├─ brush systems → BrushSceneVoxelDelta[tick]
  └─ surface/build systems → SurfaceDelta[tick]

Commit
  ├─ blend_scene_voxels(tick)
  ├─ rebuild_global_voxel_field(tick)
  ├─ build_voxel_volume(tick)
  └─ publish SceneState[tick]
```

核心规则：

- 岩石、植被、表面重建、笔刷编辑之间不直接互相调用。
- 自动生成只写 `AutoSceneVoxelDelta[tick]`。
- 笔刷和主动修改只写 `BrushSceneVoxelDelta[tick]`。
- 后续系统读取的是 `SceneState[tick]`，因此一个系统想消费另一个系统的结果时，需要排到下一个 tick。

```
┌─────────────────────────────────────────────────────────────────┐
│  Generation Tick N: Occupancy Generation + Voxel Validation     │
│                                                                 │
│  read SceneState[N - 1]                                         │
│    ├─ reset candidate occupancy + collision occupancy            │
│    ├─ import committed rocks / masks                            │
│    ├─ scatter(tree)  → check/write CollisionVoxel + delta[N]     │
│    ├─ scatter(bush)  → write AutoSceneVoxelDelta[N]             │
│    ├─ scatter(grass) → write AutoSceneVoxelDelta[N]             │
│    ├─ merge BrushSceneVoxelDelta[N]                             │
│    ├─ blend_scene_voxels(N) → SceneVoxel[N] candidate           │
│    ├─ build_voxel_volume(N)                                     │
│    └─ validate_voxel() ──┐                                      │
│                          ├── PASS → commit SceneState[N]        │
│       FAIL ← adjust density_scale ← discard candidate delta     │
│       (max 4 attempts, 超过后强制 commit candidate)             │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  Mesh Placement / Preview                                       │
│                                                                 │
│  read committed SceneState[N]                                   │
│  tree_results  → MeshInstance3D × N                             │
│  bush_results  → MeshInstance3D × N                             │
│  grass_results → MeshInstance3D × N                             │
└─────────────────────────────────────────────────────────────────┘
```

**自循环调节策略：**
- 占用率过高 → `density_scale *= 0.7`（降低密度）
- 占用率过低 → `density_scale *= 1.4`（提高密度）
- 多样性不足 → `density_scale *= 0.85`

验证失败时丢弃本 tick 的候选 delta，不修改已提交的 `SceneState[N - 1]`。验证通过或达到最大尝试次数后，才把候选结果提交为 `SceneState[N]`。

---

### Step 1 — 初始化占用系统

```gdscript
_veg_exclusion = VegetationExclusion.new(256, 60.0)
# 注册 4 个波段，打包到 RGBA 通道
add_band("ground",     0.0, 0.3, 256, Color(0.2,0.8,0.2, 1.0))  # → R
add_band("understory", 0.3, 2.0, 128, Color(0.8,0.6,0.2, 0.7))  # → G
add_band("midstory",   2.0, 6.0, 128, Color(0.2,0.5,0.8, 0.4))  # → B
add_band("canopy",     6.0, 99., 64,  Color(0.8,0.2,0.2, 0.2))  # → A
```

创建时初始化 GPU：加载 3 个 compute shader，创建 pipeline。

### Step 2 — 导入岩石遮罩 (GPU × 4)

```
rock_mask_img → [band_import_mask.glsl] → _occupancy 的每个通道
```

对每个波段分别 dispatch 一次，将岩石遮罩写入对应 RGBA 通道：

```
dispatch(ch=0, complexity=1.0)  → _occupancy.R 写入 1.0 (岩石处)
dispatch(ch=1, complexity=0.7)  → _occupancy.G 写入 0.7
dispatch(ch=2, complexity=0.4)  → _occupancy.B 写入 0.4
dispatch(ch=3, complexity=0.2)  → _occupancy.A 写入 0.2
```

**Buffer 状态（岩石导入后）：**
```
_occupancy 像素示例：
  无岩石处: (0.0, 0.0, 0.0, 0.0)
  岩石处:   (1.0, 0.7, 0.4, 0.2)  ← 全通道被岩石占用
```

### Step 3 — 放置冠层树 (canopy band, GPU filter + CPU Poisson)

**Profile:** `canopy(r=3.0m)` → `profile_mask = (0,0,0,1)`

```
  GPU filter: 仅检查 A(canopy) 通道
    → 岩石处(A>0) 被拒绝 ✓
    → 空地(A=0) 通过 ✓

  CPU Poisson: min_dist=3.0m, max_scale=4.0, max 300
    stamp → canopy ch=3: 写 0.2, r=13px
```

### Step 4 — 放置中层树 (midstory band, GPU filter + CPU Poisson)

**Profile:** `midstory(r=2.0m)` → `profile_mask = (0,0,1,0)`

```
  GPU filter: 仅检查 B(midstory) 通道
    → 岩石处(B>0) 被拒绝 ✓
    → 冠层树的 A 通道不影响 → 中层树可在大树下 ✓

  CPU Poisson: min_dist=2.0m, max_scale=2.5, max 400
    stamp → midstory ch=2: 写 0.4, r=9px
```

### Step 5 — 放置灌木 (understory band, GPU filter + CPU Poisson)

**Profile:** `understory(r=1.0m)` → `profile_mask = (0,1,0,0)`

```
  GPU filter: 仅检查 G(understory) 通道
    → 岩石处(G>0) 被拒绝 ✓
    → 冠层/中层树不影响 → 灌木可在任何树下 ✓

  CPU Poisson: min_dist=1.5m, max_scale=1.5, max 500
    stamp → understory ch=1: 写 0.7, r=4px
```

### Step 6 — 放置草地 (ground band, GPU filter + CPU Poisson)

**Profile:** `ground(r=0.2m)` → `profile_mask = (1,0,0,0)`

```
  GPU filter: 仅检查 R(ground) 通道
    → 岩石处(R>0) 被拒绝 ✓
    → 所有上层植被不影响 → 草可在任何植被下 ✓

  CPU Poisson: min_dist=0.5m, max_scale=0.8, max 2000
    stamp → ground ch=0: 写 1.0, r=1px
```

**Buffer 状态（全部放置后）：**
```
_occupancy 像素示例（最终状态）：
  纯草地:         (1.0, 0,   0,   0  )    ← 仅 R
  灌木下草地:     (1.0, 0.7, 0,   0  )    ← R+G，不同类型共存
  大树下全生态:   (1.0, 0.7, 0.4, 0.2)    ← 四层全有植被
  岩石:           (1.0, 0.7, 0.4, 0.2)    ← 全通道被岩石阻塞
  空地:           (0,   0,   0,   0  )
```

**关键：** 同一 XZ 位置可以同时有草+灌木+中层树+冠层树，因为每种仅检查自己的波段通道。只有同类植被之间互斥。

### Step 7 — 构建 3D 体素体积 + 验证

```
SceneState[N - 1] + candidate _occupancy (2D RGBA)
  → build_auto_scene_voxels(N) → AutoSceneVoxelDelta[N]
  → merge BrushSceneVoxelDelta[N]
  → blend_scene_voxels(N) → SceneVoxel[N] candidate
  → rebuild_global_voxel_field(N) → sparse occupancy tiles
  → build_voxel_volume(N) → 6 层 Y 切片
  ground     → 1 slice  (0.0-0.3m)
  understory → 2 slices (0.3-1.15m, 1.15-2.0m)
  midstory   → 2 slices (2.0-4.0m, 4.0-6.0m)
  canopy     → 1 slice  (6.0-99.0m)
```

自动生成流程只写当前 tick 的 `AutoSceneVoxelDelta[N]`。笔刷、擦除、锁定和其他主动修改只写当前 tick 的 `BrushSceneVoxelDelta[N]`；该 delta 只记录 `modified_voxels` 和 `auto_mix`，默认 `auto_mix = 0.0` 表示完全不混合 auto。后续验证、查询、调试和网格放置只读取 commit 后的 `SceneVoxel[N]` 和由它重建的 `GlobalVoxelField`，避免自动生成逻辑和主动编辑逻辑直接互相覆盖。

**验证准则 (`validate_voxel`)：**

| 指标 | 默认阈值 | 含义 |
|------|---------|------|
| `min_ground_occupancy` | 5% | ground 层至少有 5% 被植被填充 |
| `max_ground_occupancy` | 85% | ground 层不超过 85% (避免过饱和) |
| `max_canopy_occupancy` | 60% | 树冠层不超过 60% (保持空隙) |
| `min_diversity_score` | 2 | 至少 2 个波段有 >1% 的占用 |

验证失败 → 丢弃 `AutoSceneVoxelDelta[N]` candidate → 调整 `density_scale` → `reset_occupancy()` → 重新生成。通过后才 commit 为 `SceneState[N]`。

### Step 8 — 摆放实例 / 预览

仅在当前 `generation_tick` 验证通过并 commit 为 `SceneState[N]` 后执行：

```text
缓存的 canopy_results   → CanopyTree_N   (TREE_VISUAL_LAYER=11)
缓存的 midstory_results → MidstoryTree_N (MIDSTORY_VISUAL_LAYER=13)
缓存的 bush_results     → Bush_N         (BUSH_VISUAL_LAYER=12)
缓存的 grass_results    → Grass_N        (GRASS_VISUAL_LAYER=14)
```

此步不修改 `_occupancy`，仅消费已提交的 `SceneState[N]` 和本 tick 缓存的放置数据。

**每实例属性（scatter 输出）：**

| 字段 | 类型或来源 | 说明 |
|---|---|---|
| `position` | `world_pos` | 世界坐标 |
| `rotation_mode` | `Y` 或 `XYZ` | 旋转模式；`Y` 只读取 `.y`，`XYZ` 读取 `.x/.y/.z` |
| `rotation_degrees` | `Vector3` | 实例旋转角度 |
| `scale` | `Vector3.ONE * scale_val` | 随机缩放后的实例 scale |
| `type` | `canopy_tree` 等 | `tree`、`bush`、`grass` 或具体植被类型 |
| `color` | `inst_color` | 影响波段的平均颜色，alpha 同步 `complexity` |
| `complexity` | `inst_complexity` | 最高复杂度，来自受影响波段 |
| `auto_object_id` | 例如 `CanopyTree_12` | 摆放成 `AutoObject` 后写入 `SceneVoxel` 的对象编号 |
| `instance_mesh_id` | `MeshInstance3D.get_instance_id()` | 摆放成 `MeshInstance3D` 后写入 `SceneVoxel` 的实例 id |
| `scene_layers` | `inst_bands` | 每个写入 visual layer 的详细信息 |
| `collision_voxels` | 粗树干等刚体描述 | 只有需要最终互斥的部分写入；草、树叶、细枝为空 |

`scene_layers` 单项结构：

| 字段 | 类型 | 示例 | 说明 |
|---|---|---|---|
| `band` | `String` | `canopy` | 波段名 |
| `channel` | `int` | `3` | RGBA channel index |
| `radius` | `float` | `3.0` | 世界单位半径 |
| `complexity` | `float` | `0.2` | 写入 occupancy 的值 |
| `color` | `Color` | `Color(0.8, 0.2, 0.2, 0.2)` | debug 颜色 |

`collision_voxels` 单项结构：

| 字段 | 类型 | 示例 | 说明 |
|---|---|---|---|
| `shape` | `String` | `cylinder` | 当前按 XZ 圆柱 footprint 检查 |
| `radius` | `float` | `0.45` | 原始世界单位半径 |
| `y_min` / `y_max` | `float` | `0.0` / `2.2` | 记录碰撞体素覆盖高度 |
| `erosion_radius` / `dilation_radius` | `float` | `0.04` / `0.08` | 先侵蚀去掉细部，再扩张得到保守互斥半径 |
| `effective_radius` | `float` | `0.49` | 运行时实际写入半径 |

**材质应用 (`_make_veg_material`)：**
- `albedo_color` ← 波段平均颜色 RGB
- `roughness` ← lerp(0.9, 0.4, complexity)  — 高复杂度更光滑
- `metallic` ← complexity × 0.1

**Metadata 存储在 MeshInstance3D 上（运行时可查询）：**
- `mi.get_meta("veg_color")` → Color
- `mi.get_meta("veg_complexity")` → float
- `mi.get_meta("asset_voxel_record")` → Dictionary
- `mi.get_meta("veg_collision_voxels")` / `auto_collision_voxels` → Array[Dictionary]

---

## 3. 冲突矩阵

高度 band 仍然只处理生态层占用；最终互斥另由 `collision_occupancy` 处理粗树干等刚体部分。

| 类型 | 高度 band | 碰撞体素 | 与其它类型的关系 |
|---|---|---|---|
| `canopy_tree` | A / `canopy` | 粗树干 | 树冠按 A 互斥；树干跨类型互斥 |
| `midstory_tree` | B / `midstory` | 较细树干 | 树冠按 B 互斥；树干跨类型互斥 |
| `bush` | G / `understory` | 通常为空 | 按 G 互斥，不阻挡树干层 |
| `grass` | R / `ground` | 空 | 按 R 互斥，不写刚体碰撞 |

**关键交互：**

| 场景 | R(ground) | G(understory) | B(midstory) | A(canopy) | Collision | 结果 |
|------|-----------|---------------|-------------|-----------|---|------|
| 草+灌木+中层+冠层 同位置 | 草写R | 灌木写G | 中层写B | 冠层写A | 树干若同位则冲突 | 生态层可共存，刚体层互斥 |
| 两棵冠层树 | - | - | - | A冲突 | 树干也冲突 | **互斥** ✓ |
| 两棵灌木 | - | G冲突 | - | - | 通常为空 | **互斥** ✓ |
| 冠层树 + 中层树 树干同位 | - | - | 中层B独立 | 冠层A独立 | collision 冲突 | **互斥** ✓ |
| 冠层树 + 中层树 树干错开 | - | - | 中层B独立 | 冠层A独立 | 无冲突 | **共存** ✓ |

---

## 4. Compute Shader 清单

| Shader | 输入 | 输出 | Push Constants |
|--------|------|------|----------------|
| `band_import_mask.glsl` | source_mask (sampler2D) | _occupancy (image2D RGBA) | channel, complexity, threshold, out_res |
| `band_filter_candidates.glsl` | _occupancy (sampler2D) | candidate_img (image2D) | profile_mask(vec4), block_threshold, base_res |
| `band_stamp.glsl` | _occupancy (image2D RGBA), StampBuffer (SSBO) | _occupancy (image2D RGBA) | channel, complexity, occ_res, stamp_count |

`collision_occupancy` 当前在 CPU 放置复核阶段读写，因为它只服务粗树干等少量刚体互斥，不参与树叶/草地的 GPU band filter。

---

## 5. 完整时序图

```
Time ──────────────────────────────────────────────────────────────────►
  ┌── Generation Tick N (最多 VEG_MAX_ITERATIONS=4 次候选尝试) ───────┐
  │                                                                    │
  │ read SceneState[N - 1]                                             │
  │ reset_occupancy()                                                  │
  │                                                                    │
  │ ┌─ GPU × 4 ──────────────────────────────────────────────────────┐ │
  │ │ band_import_mask.glsl  rock → R, G, B, A                      │ │
  │ └─────────────────────────────┬──────────────────────────────────┘ │
  │                               │                                    │
  │ ┌─ GPU+CPU: canopy_tree ──────┼──────────────────────────────────┐ │
  │ │ profile_mask = (0,0,0,1)     │  filter → collision → stamp .A │ │
  │ │ max 300, min_dist=3.0m       │                                 │ │
  │ └─────────────────────────────┬──────────────────────────────────┘ │
  │ ┌─ GPU+CPU: midstory_tree ────┼──────────────────────────────────┐ │
  │ │ profile_mask = (0,0,1,0)     │  filter → collision → stamp .B │ │
  │ │ max 400, min_dist=2.0m       │                                 │ │
  │ └─────────────────────────────┬──────────────────────────────────┘ │
  │ ┌─ GPU+CPU: bush ─────────────┼──────────────────────────────────┐ │
  │ │ profile_mask = (0,1,0,0)     │  filter → Poisson → stamp .G   │ │
  │ │ max 500, min_dist=1.5m       │                                 │ │
  │ └─────────────────────────────┬──────────────────────────────────┘ │
  │ ┌─ GPU+CPU: grass ────────────┼──────────────────────────────────┐ │
  │ │ profile_mask = (1,0,0,0)     │  filter → Poisson → stamp .R   │ │
  │ │ max 2000, min_dist=0.5m      │                                 │ │
  │ └─────────────────────────────┬──────────────────────────────────┘ │
  │                               │                                    │
  │ build_auto_scene_voxels(N) → AutoSceneVoxelDelta[N]                │
  │ merge BrushSceneVoxelDelta[N]                                      │
  │ blend_scene_voxels(N) → SceneVoxel[N] candidate                    │
  │ build_voxel_volume(N) → 6 slices                                   │
  │ validate_voxel ─── PASS? ──→ commit SceneState[N]                  │
  │                └── FAIL? ──→ discard delta, adjust density, retry  │
  └────────────────────────────────────────────────────────────────────┘
                                  │
  ┌─ Mesh Placement / Preview reads committed SceneState[N] ───────────┐
  │ canopy_results   → CanopyTree_N   + material(color, complexity)    │
  │ midstory_results → MidstoryTree_N + material(color, complexity)    │
  │ bush_results     → Bush_N         + material(color, complexity)    │
  │ grass_results    → Grass_N        + material(color, complexity)    │
  └─────────────────────────────────────────────────────────────────────┘
```

---

## 6. 文件清单

| 文件 | 职责 |
|------|------|
| `scripts/vegetation_exclusion.gd` | 核心类：波段管理、GPU dispatch、Poisson 放置、source delta、`SceneVoxel` commit、`GlobalVoxelField`、体素构建、验证 |
| `scripts/main.gd` | 流程编排：generation tick 调度 → 4 种植被散布 → delta 混合 → 验证 → 摆放实例 |
| `scripts/vegetation_scatter.gd` | Mesh 创建工具（canopy_tree / midstory_tree / bush 几何体） |
| `shaders/band_import_mask.glsl` | 遮罩导入 compute shader |
| `shaders/band_filter_candidates.glsl` | 候选过滤 compute shader（仅检查单通道占用） |
| `shaders/band_stamp.glsl` | 批量 stamp compute shader（SSBO 驱动） |
