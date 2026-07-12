# MeshFill 3D Object Volume Score：单物体体积采样评分

本文记录 3D placement score 阶段的设计契约：对每个候选原点（anchor voxel），在 shader 内按
`rotation_slots` 个 yaw 旋转 asset collision 采样集，对场景场（`SV` / `TargetSV_B`）做三线性体积
采样并评分，取最优 yaw 写回。评分并入 `VoxelPlacementGenerator`（VPG）的评分阶段，不再是独立管线。

## 现状与归属

- **评分器**：`shaders/score_voxel_tile.glsl` 是唯一评分器。每个候选原点在 shader 内扫
  `rotation_slots`（默认 `12`）个 yaw，逐一用完整物理/语义模型评分并取最优槽；
  `shaders/stamp_voxel_field.glsl` 按记录里的最优槽旋转采样集盖章；旋转经现有
  record→`results_to_world_gpu`→实例 yaw 以同一 Godot `Basis(UP, θ)` 约定贯通，
  `shaders/reduce_voxel_tiles.glsl` 原样复用。生产路径（SPA → `run_multi_asset`）已在编辑器
  Vulkan 下验证。
- **退役**：原独立两遍原型 `scripts/object_volume_score_gpu.gd`（`score_object_subtile.glsl` +
  `reduce_object_rotation_scores.glsl`）及其 **CPU 预烘 per-rotation sample records** 方案已**删除**
  ——改为 collision 采样烘一次（容器注册期）、shader 内旋转采样。2.5D heightfield 路径亦已废弃移除。
- **Demo provider**：`demos/placement-score-3d/volume_score_demo.gd` 是一个 volume-score
  provider，向同场景兄弟 `CoreSPADemo`（`ScenePlacementActor`）`register_volume_score_provider`
  注册，接管编辑器工具栏「Anchors」「Score」按钮与 Anchor 模式点选：
  - **Anchors**：`VolumeScore3D.generate_anchors` 在场景场表面按 `anchor_spacing`（默认 `32`）铺锚点。
  - **Score**：对每个 `AssetDescriptor` 资产用 `VPG.run_minimal`（`debug_read_voxel_channels`、in-shader
    `12` 旋转、维度评分）评分，从 per-voxel debug buffer 按锚点体素回读
    `{score, best_rotation_slot}`，得每锚点 × 每资产 top-k 排名；点选锚点显示排名与最优朝向。
- **放置物体一律实例真实 mesh**：每锚点胜出资产实例化 `AssetDescriptor.get_mesh()`，绝不用占位
  方盒子（见 `CLAUDE.md`「Placement / Score Demos」）。资产在 `.tscn` 以 `ext_resource` 挂到
  `@export Array[AssetDescriptor] placement_assets`；评分形状取自 descriptor collision 剖面（注册进
  profile 容器），展示时按最优 yaw 旋转、原生 FBX 轴心贴地。`AssetDescriptor` 已标 `@tool`，其
  `get_mesh()` 等方法方能在编辑器 @tool demo 里运行。
- 同场景 `CoreSPADemo` 以 `spawn_autoobjects_on_start = false` 关默认 autoobject 批量 spawn；
  `selection_mode = 3`（Anchor）使锚点点选开箱即用。

## 运行方式

> **@tool 编辑器模式，禁止 F6。** 在 Godot 编辑器中双击打开 `.tscn` 即可，脚本在视口实时运行，
> R 重算、`[` / `]` 调间距。F6（Run Current Scene）和 F5（Run Project）被
> `core_demo_contract_fixture.gd` 守卫代码禁止。

## 术语

| 术语 | 含义 |
| --- | --- |
| `volume` | 整个 voxel 数据 buffer；不是单个元素。 |
| `voxel` | `volume` 中的单个 `(x, y, z)` cell。 |
| `anchor` | 候选放置原点体素，取自 target 体积内（`target_field.a > min_target_interest`）。 |
| `collision` | asset 的占据体素集（每格 `local_pos` + `collision_strength` + `flags` + `weight`，含派生 clearance），register 时烘一次并常驻、评分时 shader 内按 yaw 旋转。旧的"每次现打包"中间概念已退役。 |
| `channels` | asset 的语义通道向量 `[collision-mean, complexity, color.rgb]`，dims 里与环境通道 MATCH 的资产目标值；源自 descriptor 属性、常驻。 |
| `rotation slot` | `rotation_slots` 个待评测 yaw 之一；绕 Y 轴，步进 `360 / rotation_slots` 度。 |

## 设计常量

| 常量 | 值 | 来源 / 说明 |
| --- | --- | --- |
| `rotation_slots` | `12` | 每候选原点评测的 yaw 档数（VPG 成员默认、demo `@export`）。 |
| `TILE_SIZE` / `local_size` | `8` / `8×8×8 = 512` | score dispatch：一个 workgroup 一个 tile，512 线程各评一个候选原点。 |
| `COLLISION_SAMPLE_CAPACITY` | `128` | 单 asset collision 采样上限（容器注册期截断；shader shared 预载数组同长）。 |
| `NUM_DEBUG_CHANNELS` | `8` | per-voxel debug buffer 通道数（评分回读来源，见「评分回读」）。 |
| `top_k` | `1..8`（demo `1`） | per-tile top-K；demo 每锚点取最优 1。 |
| `MAX_SCORING_DIMENSIONS` | `16` | 维度评分表上限（`_dim_count` 钳制）。 |
| `env_channel_count` | 动态（demo `5`） | 环境通道数：collision / complexity / color r/g/b。 |
| `asset_dimension_profile` | `8` 槽 | 每资产维度画像 = 资产 `channels`（`ScoreConfig` SSBO `cfg_asset_profile0/1`）；目标改为常驻直读，见「常驻 collision 与 channels」。 |

## 数据流

```text
anchor voxel (target 体积内) + asset collision (register 时常驻) + descriptor
  -> VPG.run_minimal(每资产一次；debug_read_voxel_channels)
  -> score_voxel_tile.glsl：一个 workgroup 一个 tile，512 线程各评一个候选原点
       每原点在 shader 内扫 rotation_slots 个 yaw：
         sample offset 按 yaw 旋转（NO CPU 预烘）-> 连续场景坐标
         -> 对 SV / TargetSV_B 做 8 邻三线性采样 -> 按维度 / 物理模型评分
       取最优 yaw，写 per-voxel debug buffer（placement_score + best_rotation_slot）
  -> CPU 从 debug buffer 按锚点体素回读 {score, best_rotation_slot}
  -> 每锚点 × 每资产 top-k 排名（demo），或经 reduce -> result -> stamp 生产盖章
```

## 采样与旋转

- **shader 内旋转**：collision 体素集（rotation-invariant）以容器常驻 `collision_records`
  （`CollisionSampleRecord{pos_strength, weight_flags}`，≤ `COLLISION_SAMPLE_CAPACITY`）提供；
  shader 对每个 yaw slot 用 `rotate_sample_offset_y_f`（rigid yaw，无 round、无 scale）把每个体素
  offset 旋成连续坐标 `pf = anchor + rotated_offset`。CPU 不预烘 per-rotation 副本。
- **来源**：collision 取自 descriptor（`get_collision()` → 容器注册期 `_bake_collision_records`，
  含 clearance）；无 collision 剖面时按 mesh AABB 体素跨度建实心采样注册。此份数据**在 register 时
  烘一次并常驻**、score 阶段按 `profile_id` 直读——见「常驻 collision 与 channels」节。
- **三线性采样**：`sample_field_trilinear` 在连续位置 `pf` 对 complexity（RGBA8 `.a`）与
  collision（R8）各取 8 邻。越界角点权重计 0，按命中权重和 `wsum` 归一化——贴边 sample 不被网格
  边缘错误变暗；仅 8 邻全越界（`wsum == 0`）时跳过该 sample，与 prefilter 越界规则一致。
- **pivot**：sample offset 先减 `sample_pivot`（shift-then-rotate 顺序），再施 yaw。

## 常驻 collision 与 channels（旧中间形状概念已退役）

> 状态：**collision 侧已落地（方案 B2，2026-07-11）**。descriptor 的 collision 在注册时烘一次并
> 常驻（`collision_records`），score/stamp 按 `profile_id` 直读；旧的每-run 烘焙/打包函数与
> 双 buffer 已删除。**channels 直读仍为未竟项**（见节尾）。

「CPU 每次 `run_minimal` 现打包一份形状」的中间概念**已退役**——那份数据本质就是 descriptor 的
collision（含派生 clearance）。现在在 profile 容器注册时经
`AutoVoxelRuntimeProfileContainer._bake_collision_records`（体素对齐 + 合成 clearance / 去重 /
截断 `COLLISION_SAMPLE_CAPACITY`）**烘一次**，上传成按 `profile_id` 索引的常驻 buffer。

两类常驻数据（挂在 profile 容器 / SPA 下，按 `profile_id`）：

| 数据 | 是什么 | 角色 | arity | 来源 |
| --- | --- | --- | --- | --- |
| `collision`（空间） | 占据体素集（voxel+strength+flags+weight，含派生 clearance） | 决定在哪采样、算 collision/clearance | per-voxel | `get_collision()` → 容器 `_bake_collision_records`（register 时一次） |
| `channels`（语义） | `[collision-mean, complexity, color.r, color.g, color.b]` | dims 里与环境通道 MATCH 的资产目标值 | per-asset | descriptor 属性（`get_color` / `get_complexity` / collision 均值） |

**扁平 buffer + range（已落地）**：所有 asset 的 collision 记录拼进一个扁平 `collision_records`
buffer（`GPU_BUFFER_NAMES` 第 4 个，stride 32B），每 asset 的 `collision_range`（`start` / `count`）
标出自己的切片（与 `probe_range` / `pivot_range` 同款，见 `auto_voxel_runtime_profile_container.gd`）。

**B2 绑定（与 set1 避让契约解耦，已落地）**：常驻 collision buffer 绑在 **set0 binding 2**
（`CollisionSampleRecord{pos_strength, weight_flags}`，binding 3/5 随旧双 buffer 布局退役）；
`start` 走 **`ScoreConfig` SSBO（set0 binding 10，`cfg_sample_range.x`）**、`count` 走 push
（`ids_counts.x = sample_count`；stamp 侧 start 走 push `sample_start` 槽），**不**走 set1 的
profile table。故形状读取不依赖 set1 profile 绑定，无论避让契约绑没绑上都能评分。（未采用的
B1 = 挂 set1 profile table 直读，会把形状读取绑死在避让契约 blocker 上，故弃。）VPG 侧由
`_resolve_collision_sample_range`（容器 + `profile_id` → range/buffer，含设备对齐）统一解析。

**channels 直读（未竟）**：dims 的资产值（`asset_profile_value(d)`）改读常驻 channels（profile
table 的 `color_complexity` + `density` 已常驻，补 `collision-mean`），不再每次经
`asset_dimension_profile` → `ScoreConfig` 组装副本。

**对 `run_multi_asset` 的影响（已落地）**：per-asset × per-pivot 循环里**零形状打包**（register 时
一次），消掉每 pivot 的重复开销；collision 按 `profile_id` 常驻直读，故**调用方须先注册**
（SPA `register_asset`；volume-score demo 自建 `AutoVoxelRuntimeProfileContainer` 注册，含
mesh-AABB 合成采样的无 collision 兜底）。因 B2 走 set0 + `ScoreConfig`、不与 set1 契约耦合，
`run_multi_asset` 的形状读取不受该绑定状态影响。

## 维度评分（data-driven）

评分有两条路径，由 `dim_count`（= `scoring_dimensions.size()`，钳到 `MAX_SCORING_DIMENSIONS`）选择：

- **`dim_count > 0`（维度语义评分，demo 走此路）**：每个维度是一条 `DimRecord`：

```gdscript
{"channel": 0, "mode": 0, "weight": 1.0, "min": 0.0, "max": 1.0}
# channel: env 通道索引；mode: 0=MATCH（PENALTY/GATE 保留未实现）
# weight:  该维权重；min/max: 约束区间（MATCH 下不约束有效性）
```

  每 collision 采样体素、每维度在其最近体素读 env 通道值 `env`，与该资产画像值
  `asset_profile_value(d)`（= 常驻 `channels`，见上节；迁移前为每次经 `asset_dimension_profile`
  组装的副本）做 MATCH fit：`fit = clamp(1 - |env - av|, 0, 1)`，累加
  `weight * fit * sample_weight`。最终 `score = semantic_score / semantic_weight`（`>= 0`，仍高于
  `INVALID_SCORE`）。有效性 = coverage-only（`has_target == 0` 或采样命中 target）。env 场按
  `env_channels[voxel * env_channel_count + ch]` 扁平布局上传（demo 5 通道见「设计常量」）。

- **`dim_count == 0`（legacy penalty-only）**：
  `score = -(solid_collision·w_col + complexity_overlap·w_ovl + clearance_overlap·w_clr)`，
  有效性 = collision/clearance 阈值门 + target coverage 门。support 已退役（正项移除），有效分
  `<= 0`；`INVALID_SCORE = -1e18` 作无效哨兵，valid-but-negative 仍是真正的胜者。

> 权重/约束沿用 `score_voxel_tile.glsl` 当前语义，本文不重定义默认值。penalty 权重、
> `env_channel_count`、8 槽资产画像与 `collision_records` 起始偏移（`cfg_sample_range`）存
> `ScoreConfig` SSBO（binding 10），以让 push constant 保持在 Godot 的 128 字节上限内。

## 评分回读（debug buffer）

评分结果经 **per-voxel debug buffer** 回读，`tile_topk` **不再回读 CPU**（`tile_topk_buffer` 仍是
GPU 内部 `reduce -> result -> stamp` 生产盖章链的生产者，未变）。

debug buffer 每 voxel `NUM_DEBUG_CHANNELS = 8` 个 float：

| ch | 名称 | 含义 |
| --- | --- | --- |
| 0 | `target_coverage` | collision 采样命中 target 的加权比例 |
| 1 | `target_complexity_fit` | `1 - mean |target complexity - collision strength|` |
| 2 | `target_color_fit` | `1 - mean RGB 距离 to asset_color` |
| 3 | `target_density` | collision 采样下 target complexity 均值 |
| 4 | `placement_score` | 最终分（yaw sweep 最优） |
| 5 | `best_rotation_slot` | 最优 yaw 槽索引 `0..rotation_slots-1`（复用退役的 `support_ratio` 槽） |
| 6 | `solid_collision` | 实心碰撞惩罚项 |
| 7 | `clearance_overlap` | clearance 重叠惩罚项 |

- CPU 按锚点体素索引读通道：布局（index_space=`voxel_dense_xzy`、通道号、stride）来自
  `DebugBufferSet(VOXEL_DEBUG_CHANNELS)` 单一真源——demo 用 `voxel_dense_xzy_index(av, grid)` +
  `channel_index("placement_score")` / `channel_index("best_rotation_slot")`，不再硬编码 `vidx*8+4/5`。
- `run_minimal` 输出已移除 `tile_topk` / `tile_topk_readback_source` 键；打开 `debug_read_voxel_channels`
  即从 `score_shader_debug_voxel_buffer` 回读 `debug_voxel`（禁用时整键不发；通道名/数查
  `DebugBufferSet.VOXEL_DEBUG_CHANNELS`，不再随结果回显）。

## 契约边界

- 本路径只接替 placement **physical / semantic score** 阶段，不改 probe prefilter、候选路由、
  commit 契约（上游候选仍由 `autoobject-probe-prefilter.md` 的 prefilter 提供）。
- 空候选直接 skip，不回退 full grid。
- score 不写 committed `SceneVoxel`；接受的 placement 由 VPG state-chain stamp 原位提交
  （`instance_stamp_writeback.accepted_placement_writeback_mode == "gpu_state_chain_stamp"`）。
- `TargetSV_B` 只作 target / guidance 采样输入，不进 committed source，越界 clamp 规则同 prefilter。
- 不引入 float `atomicAdd`。
- **常驻 collision / channels 按 `profile_id` 索引**：调用方须先 `register_asset`；未注册的资产无常驻
  collision → 该资产评分被阻断（与 prefilter 的 `missing_probe_range_for_profile` 同族，新增
  `missing_collision_range`）。

## Open Questions

- 12 旋转是否只绕 Y，还是需少量 pitch / roll slot 支持斜面贴合。
- 维度评分的 PENALTY / GATE `mode`（当前仅 MATCH 实现）与语义重排（route rerank）仍是 TODO。
- 稀疏 tile 下 512 线程对非 anchor 体素的早退开销：是否值得改紧凑 anchor 派发。
- 常驻 collision（B2）落地验证：`run_multi_asset` 在当前场景被 `score_runtime_profile_binding_missing`
  挡在评分前，故其 B2 行为**在本场景验不到**；只能经 demo 的 `run_minimal`（注册资产 + 读常驻
  collision + debug 回读）桥验证读路径。该 profile-binding 根因仍未查透（见 mem）。
