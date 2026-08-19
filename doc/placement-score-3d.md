# MeshFill 3D Object Volume Score：单物体体积采样评分

本文记录 3D placement score 阶段的设计契约：以 prefilter 交接（`anchor_candidate_handoff`，
one origin per anchor）的每个 anchor 为候选原点，在 shader 内按 `rotation_slots` 个 yaw 旋转
asset 的 Fine `ProfileSample` 集，对 CurrentSV 与 TargetSV 求五维 residual gain，取最优 pivot × yaw 写回。
评分并入 `VoxelPlacementGenerator`（VPG）的评分阶段，不再是独立管线。

## 场景与上游文档

场景：`res://scenes/placement-score-3d/placement-score-3d.tscn`（脚本
`scenes/placement-score-3d/volume_score_demo.gd`）。这是仓库中仅存的 placement demo 场景，
下列 core 文档的 `## 测试场景` 段都指向它：

- `res://doc/auto-object-gpu-runtime-architecture.md`
- `res://doc/scene-placement-actor.md`
- `res://doc/scene-voxel-field-system.md`
- `res://doc/scene-voxel-tile.md`

对应地，`placement-score-3d.tscn` 的 `DemoSetup` 节点用 `metadata/source_docs`（`;` 分隔）
登记这四份来源文档，`metadata/source_doc` 仍指向本文。

## 现状与归属

- **评分器**：`shaders/score_anchor_asset_residual.glsl` 是唯一评分器。一个 workgroup 评一个
  `(anchor, top-K asset 槽)` 候选对，16 线程（`local_size_x = 16`）分摊 `pivot × yaw` 组合（每原点扫
  `rotation_slots`，默认 `12` 个 yaw），`ProfileSample` 分批流过 shared memory 并在同一次
  遍历里累计五维 residual gain。三阶段 Reduce 为每个 Anchor 选出 gain 最高的有效 Fine 候选，
  经迭代贪心得分 NMS 仲裁同轮冲突（高分优先存活，与串行贪心等价），再紧凑写出；`shaders/stamp_asset_voxels.glsl` 按记录里的 profile/pivot/yaw 做 mixed-asset 盖章
  （写值与 compose 是共享的 `@@GEN ad_voxel_compose` 规则，评分预测 == 盖章结果）；旋转经
  record→`results_to_world_gpu`→实例 yaw 以同一 Godot `Basis(UP, θ)` 约定贯通。生产路径
  （SPA → `run_multi_asset`）一条 GPU 链跑完全部 asset。
- **退役**：原 tile 管线（`score_voxel_tile.glsl` / `reduce_voxel_tiles.glsl` /
  `stamp_voxel_field.glsl`、每 tile 512 候选原点枚举、`run_minimal` 每资产一次调用）已随
  candidate route 删除，由 anchor-origin residual-gain 管线取代。更早的独立两遍原型
  `scripts/object_volume_score_gpu.gd`（`score_object_subtile.glsl` +
  `reduce_object_rotation_scores.glsl`）及其 **CPU 预烘 per-rotation sample records** 方案亦已
  **删除**——体素记录烘一次（容器注册期）、shader 内旋转采样。2.5D heightfield 路径亦已废弃移除。
- **Demo provider（真实链版，批 3b）**：`scenes/placement-score-3d/volume_score_demo.gd` 是一个
  volume-score provider，作为真实 `ScenePlacementActor` 的常驻 Volume 子节点
  `register_volume_provider` 注册，响应 `SPA` Inspector 的「Anchors」「Score」「Place」按钮与
  Anchor 模式点选。SPA 在 ready 期间一次构建真实上游；`PlacementStageEnv`
  （`scripts/checks/placement_stage_env.gd`）只验证并借用 READY SPA，不创建 runtime、RD 或 committer：
  - **Anchors（S6）**：`SPA.run_autoobject_prefilter`（4-pass GPU）**在地形高度采样 target 体积**
    （`max(target_complexity, target_collision) > min_target_interest`，采到就发锚）收集锚点体素。
    网格 Y 是地形相对的，地表因此是一个常数切片 `terrain_slice = floor(-grid_origin.y / voxel_size.y)`
    （生产配置 = `12`），这条 pass 不需要地形高度场。`anchor_vertical_stride` 决定地表**之上**再叠几层
    （`0` = 只采地形那一格，此时 `256×256` XZ 网格上限恰为列数 `65536`；`1` = 地表及以上每个
    qualifying voxel）；地形以下一律不发锚。锚点仍是 3D 体素、可悬空（预期行为；世界坐标按 TargetSV
    `height_relative` 口径加地形高度）。`raw_anchor_count > ANCHOR_CAPACITY`（`131072`）
    属于不变量错误并终止，不做分区兜底。`prefilter_tile_rect` 空（默认）
    表示单次全图，非空表示指定单区域。golden 入口通过 `_full_map_region_rects` 强制单次全图
    （不读交互导出）——测试口径 = 全量计算。旧 `VolumeScore3D` CPU 地表锚点（`anchor_spacing` 网格）
    已随文件删除退役。
  - **Score（S7）**：`VolumeScoreFineSelection.run`（`scripts/volume_score_fine_selection.gd`）
    吃真实 S6 常驻 `anchor_candidate_handoff` + S5 常驻 target 读缓冲，CurrentSV 读/写场 =
    `SPA.compose_blend_sv_fields` 合成的 BlendSV 工作对（committed SV 副本——stamp 写在副本上，
    逐次评分幂等，run 后 `release_blend_sv_fields`），一次 `VPG.run_multi_asset`（in-shader
    `12` 旋转、五维 residual gain）+ `debug_read_fine_candidates` 回读公共候选池。结果模型按
    **线性体素索引 `x + grid.x*(z + grid.z*y)` 升序**重排锚点（`collect_sv_anchors` 的
    atomicAdd 追加序跨 run 不确定，集合确定、顺序随机）；每锚点归组其 topk 槽记录
    （`record.asset_index` 键控——真实 prefilter 的 topk 槽 ≠ asset_index，
    `min_prefilter_score` 淘汰的资产自然缺席）。点选锚点显示排名与最优朝向。
  - **Place（S5→S9）**：流程收尾步——`SPA.run_place()` 用 `PlacementStageEnv` 的三段会话
    `begin_place_session()` / `run_place_session_batch()` / `end_place_session()` 驱动，批循环住在 SPA
    （`place_max_batches` / `place_result_capacity`），每批跑真实 prefilter + score + stamp + GPU 常驻直连 writeback（spawn 真实 AutoObject）+ commit
    （**改写 committed SV**），随后回读活对象态、按各 descriptor 真实 mesh 实例化渲染实际放置结果
    （注册到 `GPU Objects` 显示组，与 Anchor 组的评分预览分离，可按模式独立观察）。门限
    （`rotation_slots` / `min_target_interest` / `min_prefilter_score`）与 Anchors/Score 同导出、评分
    shader 同源。Score 展示每个 Anchor 的 Fine 胜者；Place 再经迭代贪心得分 NMS 清除 Anchor 间
    冲突（高分优先存活），并按 quota / `result_capacity` 紧凑写出，且与 Anchors/Score 一样走**单次全图
    prefilter**（`dirty_tile_ids=[]`）；超出 `131072` 时按同一不变量错误终止。
    Place 后 committed SV 已变，再 Score 在新场上重评。整条流程的端到端测试场景见
    [`core-scene-placement-actor.md`](core-scene-placement-actor.md)。
- **放置物体一律实例真实 mesh**：每锚点胜出资产实例化 `AssetDescriptor.get_mesh()`，绝不用占位
  方盒子（见 `CLAUDE.md`「Placement / Score Demos」）。资产由 SPA 的 `load_baked_assets()`
  扫 `res://scenes/asset-overview/baked_descriptors/` 注册，本 demo 直读
  `SPA.get_registered_descriptors()`，自己不持有数组也不扫盘；评分形状取自 descriptor collision 剖面（注册进
  profile 容器），展示时按最优 yaw 旋转、原生 FBX 轴心贴地。`AssetDescriptor` 已标 `@tool`，其
  `get_mesh()` 等方法方能在编辑器 @tool demo 里运行。
- `SPA/Interaction/DemoHost`（`SPAInteractionHost`，脚本 `scripts/spa_interaction_host.gd`
  已于 2026-08-07 删除）**已从本场景移除**——它在
  `_editor_init` 里无条件造第二份 `PlacementStageEnv`，两份 env 挂同一个 SPA 会互相释放对方的
  常驻 target 缓冲。它仅有的在用功能已迁入 `VolumeScore`：SVTile object-ref 热力图、G/Space
  视口热键、`SelectionHost` 的 demo 侧接线（`_wire_selection_host` → `configure()` +
  `refresh_terrain_cache()`）。其余表面（约 20 个转发方法、4 个 check 桥入口）迁移时调用方为 0。
  选择模式没有对应导出：`.tscn` 里没有 `selection_mode` 赋值；SPA 的
  `set_selection_mode()` / `get_selection_mode()` 门面已于 2026-08-07 删除，模式号
  （`MODE_*` / `SelectionMode`）已于 2026-08-10 删除，显隐与点选准入只看各显示开关（visible）。

## 生产计算参数

评分 / 放置门限的 SSOT 在 `ScenePlacementActor`（`scripts/scene_placement_actor.gd` 的
`Placement Tuning` 导出组）——**不在** `volume_score_demo.gd` 上；源码注释明确禁止在 demo/host 上
再放一份同名导出。

| 参数 | 归属 | 默认 | 说明 |
| --- | --- | --- | --- |
| `rotation_slots` | SPA | `12` | 每候选原点扫描的 yaw 档数。 |
| `min_target_interest` | SPA | `0.01` | S6 锚点门控：`max(target_complexity, target_collision)` 超过该值 = "在目标体积内"。 |
| `anchor_vertical_stride` | SPA | `0` | S6 竖直锚点密度（体素层，越小越密）：锚点自**地形切片**起每这么多层采样一次。`0` = 只采地形那一格（每列至多一个锚，且一定站在地面上）；`1` = 地表及以上每个 in-target 体素；`n > 1` = 地形切片 + 其上每 n 层。地形以下永不发锚。 |
| `min_prefilter_score` | SPA | `0.35` | S6 探针分数门：低于门的资产不进该锚点 topk（细筛自然缺席该资产）。 |
| `prefilter_tile_rect` | SPA | `Rect2i()`（空） | prefilter 观察 tile 子区域（XZ tile 坐标，tile=8³，全 Y 层）。空 = 单次全图；非空 = 单区域。golden 强制单次全图，不受本导出影响。 |
| `place_result_capacity` / `place_max_batches` / `place_min_distance_voxels` | SPA | `1024` / `24` / `2.0` | Place 每批输出上限、单次命令最多批数、reduce 最小间距。 |
| `autoobject_capacity` | SPA | `65536` | GPU AutoObject runtime 容量（**不存在** `PLACEMENT_AUTOOBJECT_CAPACITY` 这样的常量）。 |
| `golden_anchor_limit` | demo | `0` | golden 快照锚点段上限（排序序前 N；`0` = 全量）。js diff 侧对超大文件退化为首差异摘要。 |
| ~~`spawn_autoobjects_on_start`~~ | ~~`SPAInteractionHost`~~ | — | 已随 `SPAInteractionHost` 宿主脚本删除（2026-08-07）；本场景从未启用它。 |

## 术语

| 术语 | 含义 |
| --- | --- |
| `volume` | 整个 voxel 数据 buffer；不是单个元素。 |
| `voxel` | `volume` 中的单个 `(x, y, z)` cell。 |
| `anchor` | 候选放置原点体素：`max(target_complexity, target_collision) > min_target_interest` **且**落在地形切片或其之上的采样层（相位锁 `terrain_slice`、层距 `anchor_vertical_stride`，步长 `0` 即只有地形切片；两门合取，见 `shaders/collect_sv_anchors.glsl`）；经 `anchor_candidate_handoff` 常驻交接，一个 anchor 就是一个候选 origin。 |
| `profile sample` | 统一 32 B `ProfileSample`：米制 local offset、`sample_weight`、rgba8、collision/语义权重、flags；同一槽位内 coarse/Fine 通过连续 range 区分。 |
| `dimension` | 固定五维 `[collision, complexity, R, G, B]`；residual gain 按维加权（push `dim_w_*`），资产侧值来自每条 `ProfileSample` 自身，不再是 per-asset 单值画像。 |
| `rotation slot` | `rotation_slots` 个待评测 yaw 之一；绕 Y 轴，步进 `360 / rotation_slots` 度。 |

## 设计常量

| 常量 | 值 | 来源 / 说明 |
| --- | --- | --- |
| `rotation_slots` | `12` | 每候选原点评测的 yaw 档数（VPG 成员默认、demo `@export`）。 |
| `WORKGROUP_SIZE` | `16` | score dispatch：一个 workgroup 一个 `(anchor, top-K asset 槽)` 候选对，16 线程分摊 `pivot × yaw` 组合（`score_anchor_asset_residual.glsl` 的 `layout(local_size_x = 16)` 与 `const uint WORKGROUP_SIZE = 16u`）。 |
| `AD_BATCH_CAPACITY` | `128` | `ProfileSample` shared-memory 分批长度；记录数**无 per-asset 上限**，任意数量按 fine range 分批流过。 |
| `NUM_DEBUG_CHANNELS` | `8` | per-voxel debug buffer 通道数（`debug_read_voxel_channels` 回读来源，见「评分回读」）。 |
| `topk` | `4` | 每 anchor 参与细筛的 asset 槽数（prefilter 编译期契约）。 |
| `min_match_fraction` | 默认 `0.05`（`score_match_config.cfg` 可调） | 严格匹配门：逐体素正匹配减空目标 collision 负分后的 signed score > 此值才 valid；no-op 仍是隐式 baseline。 |
| 逐维匹配预算 | `color_match_max_l1` `0.3` / `collision_match_max` `0.25` / `complexity_overfill_percent` `20`（push `match_limits` vec4，complexity 槽存比例 `1+N/100`；`score_match_config.cfg` 可调） | 逐体素合取判定：**任一维**超预算即该体素不计入匹配。color = post-compose rgb L1（0..3）、collision = 对称 \|pred−tgt\|（0..1）；**complexity 非对称、纯比例**——仅当 `pred.a > tgt.a*(1+N/100)` 才判超差（过填 >N% 才拒，欠填/精确放行；无绝对松弛项）。 |
| 维度权重 | `dim_w_collision` / `dim_w_complexity` / `dim_w_color` | 五维 residual gain 的 push 权重（color 三通道共用一档）；gain 现只作"improved"判定与破平局项。 |
| 逐资产覆盖 | `AssetDescriptor.score_*`（7 项：min_match_fraction + 3 权重 + 3 预算） | 每项 `-1`=继承上面的全局 config，`>=0`=覆盖该资产。generator 打 per-asset SSBO（fine shader `set1 binding15`，按 `asset_id` 读、`per_asset>=0 ? per_asset : global`），旧 `.tres` 无字段→全继承→行为不变。编辑入口 = asset-overview 场景选中资产 → **Asset Info** 弹窗；Bake AD 会保留已存覆盖。 |

## 数据流

```text
anchor_candidate_handoff (anchor / anchor_count / topk buffer) + 常驻 Profile Arena (register 时上传)
  -> VPG.run_multi_asset（一条 GPU 链跑完全部 asset）
  -> fine_score_dispatch_finalize.glsl：anchor_count -> 间接派发（origin_count == anchor_count）
  -> score_anchor_asset_residual.glsl：一个 workgroup 一个 (anchor, top-K asset 槽)
       16 线程分摊 pivot x yaw 组合；ProfileSample fine 段分批流过 shared memory：
         记录 offset 减 pivot、按 yaw 旋转并 voxel-snap（与 stamp 同一映射，NO CPU 预烘）
         -> 读 CurrentSV / TargetSV 同一体素 -> 一次遍历累计五维 loss_before / loss_after
       取最优 pivot x yaw，写 fine-candidate 记录（可选写 per-voxel debug buffer）
  -> init_anchor_atomic_reduce：每个 Anchor 选唯一 Fine 候选、建立 XZ 直接索引，
       过格点门与跨批 clearance 后播种三态 NMS 状态机并按活跃 anchor 数写间接派发参数
  -> arbitrate_anchor_conflicts：迭代式贪心得分 NMS（得分降序、同分 anchor id 升序），
       每轮由最后完成的工作组做 GPU 收敛检查，收敛后自清零间接参数、剩余轮次零工作组空转；
       结果与"按得分逐个取、淘汰冲突者"的串行贪心完全一致
  -> compact_anchor_atomic_reduce：只接受 SELECTED 态，按 Anchor ID 应用 quota/capacity 并写出
  -> init_stamp_bounds -> stamp_asset_voxels.glsl 生产盖章
  -> demo：debug_read_fine_candidates 回读候选池得每锚点 x 每资产 {score, valid, yaw_slot}
```

Score-only 分支（`fine_candidates_only`，Score 按钮）不跑上面的三阶段 Reduce，而是在 fine pass 之后
接一遍 `shaders/select_anchor_winners.glsl`（`voxel_placement_generator.gd:2299` 加载）把公共候选池
压成每 Anchor 一条胜者记录，写进 `fine_winner_buffer_rid`。

## 采样与旋转

- **shader 内旋转**：asset 的 rotation-invariant 样本以容器常驻 Profile Arena 槽位
  （`ProfileSample{offset_weight, payload}`，32 B）的 fine range 提供；
  shader 对每个 yaw slot 用 `rotate_sample_offset_y`（round x/z、y 不变的 voxel-snap 版）把每个
  体素 offset 旋到整数体素 `p = anchor + rotated_offset`。CPU 不预烘 per-rotation 副本。
- **来源**：新 descriptor 直接持久化 canonical `profile_samples`；旧 `asset_voxels` 只在资源读取边界
  转换为米制 Fine samples。数据在 register 时上传一次，score 阶段按 profile table 的
  `fine_sample_range` 直读。
- **voxel-snap 采样（非三线性）**：细筛在 compose 语义下必须与 stamp 逐体素一致，因此按
  整数体素读 CurrentSV（RGBA8 complexity + R8 collision）与 TargetSV（`target_field` +
  `target_collision`）同一 cell；越界体素直接跳过。旧 tile 评分器的 8 邻三线性采样随
  `score_voxel_tile.glsl` 退役。
- **pivot**：记录 offset 先减 pivot（shift-then-rotate 顺序，pivot 槽位按
  `global_pivot_index` 直读；`-1` = 零 pivot），再施 yaw。

## 常驻统一 ProfileSample（固定槽位 Profile Arena）

> 状态：**已落地**。descriptor 的 coarse/Fine 样本统一常驻在**单个** `profile_arena` buffer
> （`AutoVoxelRuntimeProfileContainer.ALL_GPU_BUFFER_NAMES == ["profile_arena"]`）；
> Probe、Fine 与 Stamp 绑定同一个 RID，分别读取槽内的 coarse 段或 fine 段。
> 生产路径不再创建第二种样本 SSBO。旧的三 buffer 拆分
> （`profile_table` / `profile_sample_records` / `pivot_records`）已合入 Arena 的定长槽位。

`ProfileSample`（32 B）同时承载空间与语义：

| 字段 | 内容 | 角色 |
| --- | --- | --- |
| `offset_weight.xyz` | 米制 local offset | 减 pivot、按 yaw 旋转、除当前 `voxel_size` 后 round |
| `offset_weight.w` | `sample_weight` | 均匀 Houdini 样本固定为 `1.0` |
| `payload.x` | rgba8，alpha = complexity | complexity / R / G / B 写值 |
| `payload.y` | collision unorm8 + 三个 semantic snorm8 weight | collision 与 signed 语义权重 |
| `payload.z` | `ProfileSample` flags | coarse/Fine、clearance、stamp-write、score-only 用途 |
| `payload.w` | reserved | 首版为 `0` |

**定长槽位 + range**：每个 asset 的 coarse/Fine 记录住在 Arena 的一个定长槽位里（sample stride
32 B），槽位由稠密 `profile_index` 寻址（不是 hash 派生的 `profile_id`），槽内以
`coarse_sample_range` 和 `fine_sample_range` 标出切片，coarse 段恒从槽内 0 起算。
Probe 读 coarse 段；score 绑 `set = 1, binding = 6` 的 `ProfileArena`、stamp 读同一 RID 的 fine 段。三个消费者的
decode、pivot/yaw/round、边界检查来自同一个 `profile_sample_runtime` 生成块。

**对 `run_multi_asset` 的影响**：per-asset 调用循环消失——一条 GPU 链跑完全部 asset；记录
register 时烘一次、按 profile table 直读，故**调用方须先注册**（SPA `register_asset`；
volume-score demo 经 `SPA` scene-owned `PlacementStageEnv` 内的 SPA 注册——demo 自建容器已随真实链改造退役，
`fine_sample_range` 为空的资产直接跳过）。

## 评分模型（严格逐体素 signed match score）

每个 `(anchor, top-K asset 槽)` 候选对的每个 `pivot × yaw` 组合，在**一次** `ProfileSample`
遍历里对每个语义体素做合取判定，并同步累计五维（collision, complexity, R, G, B）残差：

```text
occupied      = max(tgt.a, tgt_collision) > TARGET_OCCUPIED_MIN   # 目标要内容（0.05，压过烘焙渗漏）
color_ok      = L1(pred.rgb, tgt.rgb)  <= color_match_max_l1      # pred = compose(cur, AD)
collision_ok  = |pred_col - tgt_col|   <= collision_match_max
complexity_ok = pred.a <= tgt.a*(1+N/100)    # 非对称纯比例：仅过填(overfill>N%)被拒，N=complexity_overfill_percent
improved      = loss_before - loss_after > eps                    # 五维加权残差净改善
pass          = occupied && color_ok && collision_ok && complexity_ok && improved
empty_penalty = !occupied ? stamp_collision·weight : 0
score         = (Σ pass·weight - Σ empty_penalty) / Σ footprint_weight
                + 0.05 · clamp(mean_gain, -1, 1)
```

三项维度预算**任一超差即整个体素不计入匹配**；阈值权威来源是根目录
`score_match_config.cfg`（`[score_match]` 段，每次运行重读，改文件重跑即生效），
settings 字典同名键可在其上逐调用覆盖。

- 分母是完整的 in-grid footprint 权重（`total_weight`）。采样到空目标
  （`max(tgt.a,tgt_col) <= TARGET_OCCUPIED_MIN`）时，按资产实际 stamp 的 collision 值
  计负分：`-ad_col_val*weight`。因此 collision 为 0 的空目标采样不罚，collision 越强
  负分越大；`target_coverage = coverage_weight / total_weight` 仍保留作诊断。
- `improved` 保证已满足的体素不重复计分（多轮循环不叠放）；mean_gain 项只在占比打平的
  combo 间排序（±0.05 上限），有效性只看占比。
- `compose()` 与 stamp 共享 `@@GEN ad_voxel_compose` 规则（complexity/color 按 alpha
  monotonic-max、collision 取 max）——评分时的预测值 == 盖章后的实际值。
- clearance 行（`FLAG_CLEARANCE`）不进 compose，只累计物理 `clearance_overlap`。
- 物理累计（`solid_collision` / `clearance_overlap`）与语义匹配分开；有效性 =
  `solid_collision <= collision_limit` 且 `clearance_overlap <= clearance_limit` 且
  signed `match_fraction > min_match_fraction`（无 target 时回退旧 mean-gain 分数比同一阈值槽）。
- **"什么都不放"仍是隐式 baseline**：占比不过门的候选无效，负收益/贴皮放置天然被拒。
- 旧 `DimRecord` / MATCH 维度表（`scoring_dimensions`、`MAX_SCORING_DIMENSIONS`、
  `env_channels` 上传）与 `dim_count == 0` penalty-only 分支已随 tile 评分器删除；
  `INVALID_SCORE = -1e18` 仍作无效哨兵。

> 权重/阈值全部走 push constant（`min_match_fraction`、`match_limits` vec4（三项逐维预算）、
> `collision_limit` / `clearance_limit`、`dim_w_*`、write scales），布局见
> `score_anchor_asset_residual.glsl` 的 `Params`（128 字节，恰在 Godot 上限）；旧
> `ScoreConfig` SSBO 已删除。逐维预算的可调来源是 `score_match_config.cfg`。

## 评分回读（debug buffer）

demo 排名回读走 **fine-candidate 公共候选池**（`debug_read_fine_candidates`）：每
`(anchor × asset)` 一条 4×vec4 记录（`{score, valid, yaw_slot, match_fraction, ...}`，与
placement record 同布局）。旧 `tile_topk` / `tile_topk_buffer` 已随 tile 管线整体删除。

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

## Golden 快照（v2，真实链重录）

`run_golden_snapshot()`（桥调用 `call_method path=SPA/Volumes/VolumeScore method=run_golden_snapshot`，
`tools/golden_snapshot_check.js` 消费）跑固定评分管线并返回确定性文本快照；格式器住
`VolumeScoreFineSelection.golden_snapshot_text`。行格式逐字冻结：

```text
golden volume_score v2
meta asset_count=%d anchor_count=%d grid=%dx%dx%d rotation_slots=%d min_target_interest=%.3f min_prefilter_score=%.3f tile_rect=%d,%d,%dx%d golden_anchor_limit=%d
asset %d name=%s
anchor %d voxel=%s valid=%d yaw=%d gain_q1000=%d
```

确定性三件套（缺一 golden 复跑必 DIFF）：

- **单次全图**：collect 在地形高度采样发锚，`anchor_vertical_stride` 决定地表之上再叠几层
  （步长 `0` = 每列至多一个、`256×256` 网格最多 `65536` 个）；`raw_anchor_count > 131072`
  直接作为不变量错误。meta `tile_rect=0,0,0x0` 表示全图口径（可审计）。
  **改步长会换掉整份锚点集合，golden 必须重录。**
- **体素排序**：锚点按线性体素索引升序重排（GPU atomicAdd 追加序不进快照）；`anchor N` =
  排序后下标。
- **截断**：锚点段按排序序截前 `golden_anchor_limit` 个（`0` = 全量，默认）——观察侧截断、
  不动输入；值写进 meta。js 端对超大快照已有护栏：行数积超过 LCS 预算时退化为首差异行
  摘要而非完整 diff。

量化 `gain_q1000 = int(round(clamp(score, -1000, 1000) * 1000))`；某资产不在该锚点 topk
（prefilter 分数门淘汰）时输出 `-1000000` 哨兵行。旧 v1/v2（CPU 网格锚点 + `anchor_spacing`
meta 键）基线作废，随批 3b 整体重录。评分吃 BlendSV 副本（stamp 不写 committed SV），
复跑逐字节相等是幂等性的硬证明。

## 契约边界

- 本路径只接替 placement **fine score** 阶段，不改 probe prefilter 与 commit 契约（上游候选
  anchors 仍由 `auto-object-probe-prefilter.md` 的 prefilter 经 `anchor_candidate_handoff` 提供）。
- `anchor_count == 0` 空帧自然穿过（0 组间接派发），不回退 full grid。
- score 不写 committed `SceneVoxel`；接受的 placement 由 VPG state-chain stamp 原位提交
  （`instance_stamp_writeback.accepted_placement_writeback_mode == "gpu_state_chain_stamp"`）。
- TargetSV 是独立输入对（`target_field_rgba8` packed rgba8/u32，rgb + 低字节 complexity；
  + `target_collision` r8-packed），
  只作 target / guidance 采样输入，不进 committed source、不与 CurrentSV 混写。
- 不引入 float `atomicAdd`。
- **常驻 Profile Arena 按稠密 `profile_index` 寻址**：调用方须先 `register_asset`；
  `fine_sample_range` 为空的资产该候选写 invalid record，不产生放置。

## Open Questions

- 12 旋转是否只绕 Y，还是需少量 pitch / roll slot 支持斜面贴合。
- residual gain 的五维权重（`dim_w_*`）是否需要 per-asset 覆写。
- ✅ ~~常驻 collision（B2）落地验证被 profile-binding 挡路~~：该失败签名已消失（回溯=`9ede930`
  修的 >128B push 静默清零；根因取证与 check 修复见 `6c3be73`）——
  `run_resident_placement_writeback_check` 现全绿，contract 链 + B2 常驻路径经桥端到端验证。
