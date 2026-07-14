# MeshFill 3D Object Volume Score：单物体体积采样评分

本文记录 3D placement score 阶段的设计契约：以 prefilter 交接（`anchor_candidate_handoff`，
one origin per anchor）的每个 anchor 为候选原点，在 shader 内按 `rotation_slots` 个 yaw 旋转
asset 体素记录集，对 CurrentSV 与 TargetSV 求五维 residual gain，取最优 pivot × yaw 写回。
评分并入 `VoxelPlacementGenerator`（VPG）的评分阶段，不再是独立管线。

## 现状与归属

- **评分器**：`shaders/score_anchor_asset_residual.glsl` 是唯一评分器。一个 workgroup 评一个
  `(anchor, top-K asset 槽)` 候选对，64 线程分摊 `pivot × yaw` 组合（每原点扫
  `rotation_slots`，默认 `12` 个 yaw），`AssetVoxelRecord` 分批流过 shared memory 并在同一次
  遍历里累计五维 residual gain；`shaders/reduce_anchor_candidates.glsl` 在全资产共用候选池里按
  gain 裁决；`shaders/stamp_asset_voxels.glsl` 按记录里的 profile/pivot/yaw 做 mixed-asset 盖章
  （写值与 compose 是共享的 `@@GEN ad_voxel_compose` 规则，评分预测 == 盖章结果）；旋转经
  record→`results_to_world_gpu`→实例 yaw 以同一 Godot `Basis(UP, θ)` 约定贯通。生产路径
  （SPA → `run_multi_asset`）一条 GPU 链跑完全部 asset。
- **退役**：原 tile 管线（`score_voxel_tile.glsl` / `reduce_voxel_tiles.glsl` /
  `stamp_voxel_field.glsl`、每 tile 512 候选原点枚举、`run_minimal` 每资产一次调用）已随
  candidate route 删除，由 anchor-origin residual-gain 管线取代。更早的独立两遍原型
  `scripts/object_volume_score_gpu.gd`（`score_object_subtile.glsl` +
  `reduce_object_rotation_scores.glsl`）及其 **CPU 预烘 per-rotation sample records** 方案亦已
  **删除**——体素记录烘一次（容器注册期）、shader 内旋转采样。2.5D heightfield 路径亦已废弃移除。
- **Demo provider**：`demos/placement-score-3d/volume_score_demo.gd` 是一个 volume-score
  provider，向同场景兄弟 `CoreSPADemo`（`ScenePlacementActor`）`register_volume_score_provider`
  注册，接管编辑器工具栏「Anchors」「Score」按钮与 Anchor 模式点选：
  - **Anchors**：`VolumeScore3D.generate_anchors` 在场景场表面按 `anchor_spacing`（默认 `32`）铺锚点。
  - **Score**：全部 `AssetDescriptor` 资产一次 `VPG.run_multi_asset`（in-shader `12` 旋转、
    五维 residual gain），开 `debug_read_fine_candidates` 回读公共候选池——每
    `(anchor × asset)` 一条 `{gain, valid, yaw_slot}` 记录——得每锚点 × 每资产排名；
    点选锚点显示排名与最优朝向。
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
| `anchor` | 候选放置原点体素，取自 target 体积内（`target_field.a > min_target_interest`）；经 `anchor_candidate_handoff` 常驻交接，一个 anchor 就是一个候选 origin。 |
| `asset voxel record` | asset 的体素记录集（`AssetVoxelRecord`，32 B：local voxel + `collision_q8` + rgba8（alpha=complexity）+ `weight` + `flags`，`FLAG_CLEARANCE` 派生行），register 时烘一次并常驻（`asset_voxel_records`）、评分时 shader 内按 yaw 旋转。旧 `collision_records` 概念已退役。 |
| `dimension` | 固定五维 `[collision, complexity, R, G, B]`；residual gain 按维加权（push `dim_w_*`），资产侧值来自每条 `AssetVoxelRecord` 自身，不再是 per-asset 单值画像。 |
| `rotation slot` | `rotation_slots` 个待评测 yaw 之一；绕 Y 轴，步进 `360 / rotation_slots` 度。 |

## 设计常量

| 常量 | 值 | 来源 / 说明 |
| --- | --- | --- |
| `rotation_slots` | `12` | 每候选原点评测的 yaw 档数（VPG 成员默认、demo `@export`）。 |
| `WORKGROUP_SIZE` | `64` | score dispatch：一个 workgroup 一个 `(anchor, top-K asset 槽)` 候选对，64 线程分摊 `pivot × yaw` 组合。 |
| `AD_BATCH_CAPACITY` | `128` | `AssetVoxelRecord` shared-memory 分批长度；记录数**无 per-asset 上限**（任意数量分批流过，旧 `COLLISION_SAMPLE_CAPACITY` 截断已退役）。 |
| `NUM_DEBUG_CHANNELS` | `8` | per-voxel debug buffer 通道数（`debug_read_voxel_channels` 回读来源，见「评分回读」）。 |
| `topk` | `4` | 每 anchor 参与细筛的 asset 槽数（prefilter 编译期契约）。 |
| `gain_threshold` | `score_gain_threshold`（默认 `0.0`） | no-op 是隐式 baseline：`gain > threshold` 才 valid。 |
| 维度权重 | `dim_w_collision` / `dim_w_complexity` / `dim_w_color` | 五维 residual gain 的 push 权重（color 三通道共用一档）。 |

## 数据流

```text
anchor_candidate_handoff (anchor / anchor_count / topk buffer) + asset_voxel_records (register 时常驻)
  -> VPG.run_multi_asset（一条 GPU 链跑完全部 asset）
  -> fine_score_dispatch_finalize.glsl：anchor_count -> 间接派发（origin_count == anchor_count）
  -> score_anchor_asset_residual.glsl：一个 workgroup 一个 (anchor, top-K asset 槽)
       64 线程分摊 pivot x yaw 组合；AssetVoxelRecord 分批流过 shared memory：
         记录 offset 减 pivot、按 yaw 旋转并 voxel-snap（与 stamp 同一映射，NO CPU 预烘）
         -> 读 CurrentSV / TargetSV 同一体素 -> 一次遍历累计五维 loss_before / loss_after
       取最优 pivot x yaw，写 fine-candidate 记录（可选写 per-voxel debug buffer）
  -> reduce_anchor_candidates.glsl：全资产公共候选池按 residual gain 裁决
  -> init_stamp_bounds -> stamp_asset_voxels.glsl 生产盖章
  -> demo：debug_read_fine_candidates 回读候选池得每锚点 x 每资产 {gain, valid, yaw_slot}
```

## 采样与旋转

- **shader 内旋转**：asset 体素集（rotation-invariant）以容器常驻 `asset_voxel_records`
  （`AssetVoxelRecord{pos_strength, color_rgba8, weight, flags}`，32 B，无记录数上限）提供；
  shader 对每个 yaw slot 用 `rotate_sample_offset_y`（round x/z、y 不变的 voxel-snap 版）把每个
  体素 offset 旋到整数体素 `p = anchor + rotated_offset`。CPU 不预烘 per-rotation 副本。
- **来源**：体素记录取自 descriptor voxel profile（容器注册期 `_bake_asset_voxel_records`，
  含派生 clearance 行）；此份数据**在 register 时烘一次并常驻**、score 阶段按 profile table
  的 `asset_voxel_range` 直读。
- **voxel-snap 采样（非三线性）**：细筛在 compose 语义下必须与 stamp 逐体素一致，因此按
  整数体素读 CurrentSV（RGBA8 complexity + R8 collision）与 TargetSV（`target_field` +
  `target_collision`）同一 cell；越界体素直接跳过。旧 tile 评分器的 8 邻三线性采样随
  `score_voxel_tile.glsl` 退役。
- **pivot**：记录 offset 先减 pivot（shift-then-rotate 顺序，`pivot_records` 按
  `global_pivot_index` 直读；`-1` = 零 pivot），再施 yaw。

## 常驻 asset_voxel_records（旧 collision_records / channels 概念已退役）

> 状态：**已落地**。descriptor 的体素剖面在注册时烘一次并常驻（`asset_voxel_records`），
> score / stamp 按 profile table 的 `asset_voxel_range` 直读。旧 `collision_records` 常驻
> buffer、`_bake_collision_records`、`COLLISION_SAMPLE_CAPACITY` 截断、`ScoreConfig` SSBO
> （B2 绑定）与 per-asset `channels` 单值画像均已随 tile 评分器删除。

`AssetVoxelRecord`（32 B）同时承载空间与语义，一条记录既是采样点也是盖章写值：

| 字段 | 内容 | 角色 |
| --- | --- | --- |
| `pos_strength.xyz` | local voxel offset | 决定在哪采样 / 盖章 |
| `pos_strength.w` | `collision_q8`（0..255） | collision 维写值 + solid 判定 |
| `color_rgba8` | rgba8，alpha = complexity | complexity / R / G / B 四维写值 |
| `weight` | 采样权重（>= 0） | gain 与物理累计的加权 |
| `flags` | `FLAG_CLEARANCE = 2` | clearance 行只进物理 clearance 累计，不参与 compose |

**扁平 buffer + range**：所有 asset 的记录拼进一个扁平 `asset_voxel_records` buffer
（stride 32 B），每 asset 的 `asset_voxel_range`（`start` / `count`）在 profile table 里标出
自己的切片（与 `probe_range` / `pivot_range` 同款，见 `auto_voxel_runtime_profile_container.gd`
的 `_bake_asset_voxel_records`）。score 绑 set1 binding 13、stamp 同源直读——评分预测与盖章读
写的是同一份数据，无 CPU 中间打包。

**对 `run_multi_asset` 的影响**：per-asset 调用循环消失——一条 GPU 链跑完全部 asset；记录
register 时烘一次、按 profile table 直读，故**调用方须先注册**（SPA `register_asset`；
volume-score demo 自建 `AutoVoxelRuntimeProfileContainer` 注册，`asset_voxel_range` 为空的
资产直接跳过）。

## 评分模型（五维 residual gain）

每个 `(anchor, top-K asset 槽)` 候选对的每个 `pivot × yaw` 组合，在**一次** `AssetVoxelRecord`
遍历里同时累计五维（collision, complexity, R, G, B）的前后损失：

```text
loss_before = Σ_dim dim_w · |CurrentSV(p) - TargetSV(p)|
loss_after  = Σ_dim dim_w · |compose(CurrentSV, AD)(p) - TargetSV(p)|
score       = Σ (loss_before - loss_after) · weight / Σ (dim_w_total · weight)
```

- `compose()` 与 stamp 共享 `@@GEN ad_voxel_compose` 规则（complexity/color 按 alpha
  monotonic-max、collision 取 max）——评分时的预测值 == 盖章后的实际值。
- clearance 行（`FLAG_CLEARANCE`）不进 compose，只累计物理 `clearance_overlap`。
- 物理累计（`solid_collision` / `clearance_overlap`）与语义 gain 分开；有效性 =
  `solid_collision <= collision_limit` 且 `clearance_overlap <= clearance_limit` 且
  （无 target 或 coverage 命中）且 `score > gain_threshold`。
- **"什么都不放"是隐式 baseline**：`gain <= threshold` 的候选无效，负收益放置天然被拒。
- 旧 `DimRecord` / MATCH 维度表（`scoring_dimensions`、`MAX_SCORING_DIMENSIONS`、
  `env_channels` 上传）与 `dim_count == 0` penalty-only 分支已随 tile 评分器删除；
  `INVALID_SCORE = -1e18` 仍作无效哨兵。

> 权重/阈值全部走 push constant（`gain_threshold`、`collision_limit` / `clearance_limit`、
> `dim_w_*`、write scales），布局见 `score_anchor_asset_residual.glsl` 的 `Params`（保持在
> Godot 的 128 字节上限内）；旧 `ScoreConfig` SSBO 已删除。

## 评分回读（debug buffer）

demo 排名回读走 **fine-candidate 公共候选池**（`debug_read_fine_candidates`）：每
`(anchor × asset)` 一条 4×vec4 记录（`{gain, valid, yaw_slot, ...}`，与 placement record 同
布局）。旧 `tile_topk` / `tile_topk_buffer` 已随 tile 管线整体删除。

**per-voxel debug buffer** 仍可用（`debug_read_voxel_channels`），每 voxel
`NUM_DEBUG_CHANNELS = 8` 个 float（通道名保持布局稳定，1/2/3 槽在 residual-gain 迁移后复用）：

| ch | 名称 | 含义 |
| --- | --- | --- |
| 0 | `target_coverage` | 采样命中 target 的加权比例 |
| 1 | `target_complexity_fit` | 复用槽：现写 `loss_before_mean` |
| 2 | `target_color_fit` | 复用槽：现写 `loss_after_mean` |
| 3 | `target_density` | 保留槽（恒 0） |
| 4 | `placement_score` | 最优组合的 residual gain |
| 5 | `best_rotation_slot` | 最优 yaw 槽索引 `0..rotation_slots-1`（复用退役的 `support_ratio` 槽） |
| 6 | `solid_collision` | 实心碰撞累计 |
| 7 | `clearance_overlap` | clearance 重叠累计 |

- CPU 按锚点体素索引读通道：布局（index_space=`voxel_dense_xzy`、通道号、stride）来自
  `DebugBufferSet(VOXEL_DEBUG_CHANNELS)` 单一真源（`voxel_dense_xzy_index(av, grid)` +
  `channel_index(...)`，不硬编码 `vidx*8+4/5`）。
- 打开 `debug_read_voxel_channels` 即从 `score_shader_debug_voxel_buffer` 回读 `debug_voxel`
  （禁用时整键不发；通道名/数查 `DebugBufferSet.VOXEL_DEBUG_CHANNELS`，不随结果回显）。

## 契约边界

- 本路径只接替 placement **fine score** 阶段，不改 probe prefilter 与 commit 契约（上游候选
  anchors 仍由 `autoobject-probe-prefilter.md` 的 prefilter 经 `anchor_candidate_handoff` 提供）。
- `anchor_count == 0` 空帧自然穿过（0 组间接派发），不回退 full grid。
- score 不写 committed `SceneVoxel`；接受的 placement 由 VPG state-chain stamp 原位提交
  （`instance_stamp_writeback.accepted_placement_writeback_mode == "gpu_state_chain_stamp"`）。
- TargetSV 是独立输入对（`target_field` vec4 rgb+complexity + `target_collision` r8-packed），
  只作 target / guidance 采样输入，不进 committed source、不与 CurrentSV 混写。
- 不引入 float `atomicAdd`。
- **常驻 `asset_voxel_records` 按 profile table 索引**：调用方须先 `register_asset`；
  `asset_voxel_range` 为空的资产该候选写 invalid record，不产生放置。

## Open Questions

- 12 旋转是否只绕 Y，还是需少量 pitch / roll slot 支持斜面贴合。
- residual gain 的五维权重（`dim_w_*`）是否需要 per-asset 覆写。
- ✅ ~~常驻 collision（B2）落地验证被 profile-binding 挡路~~：该失败签名已消失（回溯=`9ede930`
  修的 >128B push 静默清零；根因取证与 check 修复见 `6c3be73`）——
  `run_resident_placement_writeback_check` 现全绿，contract 链 + B2 常驻路径经桥端到端验证。
