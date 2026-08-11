# ScenePlacementActor

`ScenePlacementActor`（SPA）是 placement 场景中唯一的生命周期、网格和
RenderingDevice 所有者。它是 `@tool Node3D`（`scripts/scene_placement_actor.gd`），
由使用它的场景直接实例化并常驻场景树（例如
`res://demos/placement-score-3d/placement-score-3d.tscn` 的 `SPA` 节点）；没有独立的
SPA 预制场景文件。SPA 本身已收敛为 facade——编排主体住在
`scripts/scene_placement_runtime.gd` 与 `scripts/spa_selection_host.gd`
（第三个宿主 `scripts/spa_interaction_host.gd` 已删除，见
[`core-scene-placement-actor.md`](core-scene-placement-actor.md)）。

## 固定场景结构

```text
SPA: ScenePlacementActor
├── Volumes
│   ├── TargetSV: TargetSVSetup
│   ├── SceneSV
│   ├── BrushSV
│   ├── BlendSV
│   └── VolumeScore（由具体场景提供）
├── Interaction
│   ├── SelectionHost: SPASelectionHost
│   └── MeshFillBrush
└── Displays
```

`TargetSV`、`SelectionHost` 和 `MeshFillBrush` 由 SPA 直接接线。Brush 与
SelectionHost 不再做 sibling/root/name fallback lookup，也不能直接改
TargetSV 的 channel/visibility；显示和选择命令统一进入 SPA。

## 生命周期

生命周期由 SceneTree 驱动，不提供外部 RD/committer 注入入口：

```text
_enter_tree()
  └── 建立/校验固定子树，注入 TargetSV

_ready()
  ├── 创建 SceneVoxelTileStore
  ├── 创建 SceneVoxelFieldBuilder
  ├── 创建 SceneVoxelCommitter（显式借用以上两个组件）
  ├── 获取唯一 RenderingDevice
  ├── 配置 256 x 16 x 256 网格并播种 terrain collision
  ├── 创建 ScenePlacementRuntime，共享同一 RD
  ├── 注册场景 placement_assets
  ├── 初始化 SceneSV / SVTile GPU 固定拓扑
  └── 创建 TargetSV resident read buffers

_exit_tree() / PREDELETE
  └── 逆依赖顺序 shutdown，且重复通知不会二次释放
```

`PlacementStageEnv` 只是借用 READY SPA 的阶段缓存。它不创建或释放 SPA、
committer、tile store、field builder、Volume 或 RenderingDevice。

## 所有权

- SPA 创建并销毁唯一 `ScenePlacementRuntime`。
- SPA 创建并销毁唯一 `SceneVoxelCommitter`。
- SPA 创建并销毁唯一 `SceneVoxelTileStore` 和
  `SceneVoxelFieldBuilder`；committer 的构造函数要求显式传入二者，内部
  没有 fallback `new()` 或 `_owns_*` 分支。
- SPA 创建并持有 `GPUAutoObjectRuntime`、profile container、TargetSV read
  buffers 和 BrushSV/BlendSV buffers。
- provider、PlacementStageEnv 和编辑器插件全部只借用。
- **整个场景只允许存在一份 `PlacementStageEnv`，owner = SPA，provider 经
  `spa_host.get_placement_stage_env()` 借用。** 两份 env 挂同一个 SPA 会互相拆台：
  `ensure_target_ready()` 在重建时释放上一份常驻 target 缓冲，谁后跑谁就把对方手里的 RID
  变成野指针。此前 `Interaction/DemoHost` 违反了这一条（它自己 `make()` 一份），已移除。

`get_identity_report()` 暴露 SPA/runtime/RD/committer/tile store/field
builder 的 instance id、make/dispose count 和网格信息。
`get_volume_ownership_report()` 暴露 Volume、SVTile 与 pipeline handoff 的
owner path、revision、capacity 和 RD identity。

## 网格单一事实源

当前生产网格为：

```gdscript
grid_size = Vector3i(256, 16, 256)
voxel_size = Vector3(4.0, 2.0, 4.0)
grid_origin = Vector3(-512.0, 0.0, -512.0)
```

它与 `assets/target_sv/target_sv_point_cloud.json` 的
`texture_size=256`、`slice_count=16`、`voxel_count=1,048,576` 一致。
PlacementStageEnv 拒绝与 SPA 不一致的 grid/capture override。

SceneVoxelTile 使用配置驱动的默认 `8 x 8 x 8` tile，因此当前网格固定有
`32 x 2 x 32 = 2,048` 个 GPU tile。

## GPU-first 约束

- Runtime payload 只来自 GPU storage buffers。
- CPU 只负责 descriptor/profile staging、GPU command staging 和显式
  debug readback；这些数据不能成为 runtime success 或 CPU fallback。
- `runtime_ready == true`、有效 RID、正确 record count/stride/format 和
  `runtime_read_source`/`resident_field_read_source` 才表示 GPU resident
  success。
- `readback_scene_voxel_tile_debug_snapshot()` 与 mesh-description
  `readback_debug_snapshot` 是只读诊断入口；snapshot 不会回流生产状态。
- 无 RenderingDevice 时 GPU 路径只能 SKIP 或明确失败，不能改走 CPU 替代
  路径；报告保持 `cpu_fallback=false`。

## 资产注册

场景通过 `placement_assets: Array[AssetDescriptor]` 声明资产。SPA 在 ready
阶段批量注册，并使固定槽位 Profile Arena 常驻。

常用只读/命令入口：

- `load_baked_assets(force)`：扫 Bake 目录 → 校验 → 事务式替换 Arena（Inspector 的
  `Load Baked Assets` / `Reload` 两个按钮就是它，`force` 区分二者）。
- `register_asset()` / `register_assets()`：显式增量注册。
- `replace_all_assets()` / `clear_assets()`：完整替换或清空注册表。
- `refresh_slot_mesh_description(asset_index)`：单槽整覆盖更新，不重传整份 Arena。
- `get_registered_descriptors()` / `get_registered_profile_ids()`。
- `get_profile_arena_buffer()` / `get_profile_arena_summary()`。
- `get_mesh_description_for_asset()` /
  `get_mesh_description_gpu_buffer_summary()`。
- `get_gpu_readiness_report()` / `get_merged_gpu_buffer_summary()`。

### 一键加载与 Arena 状态

`Placement` 分组的操作区分两排：

```text
[Load Baked Assets]  [Reload]
[Anchors]  [Score]  [Place]
```

- 用户不再需要手工维护 `placement_assets` 数组；`placement_assets_summary` 是只读的
  已加载资产列表（asset_id / slot / sample 与 pivot 用量 / mesh 是否有效 / slot 状态）。
- `placement_status` 顶部是只读 Arena 面板：已加载 profile 数与容量、Arena 字节数、
  slot stride、sample 与 pivot 的有效量与容量、空闲比例、Revision。
- Arena 未就绪时 `Anchors` / `Score` / `Place` 禁用，Tooltip 说明原因
  （`get_placement_blocked_reason()`）。
- 加载状态：`Not Loaded` / `Loading` / `Ready` / `Stale` / `Failed`。`Stale` 表示 Bake
  产物已变化但仍在用上一版 Arena——Bake **不会**隐式改写运行中的 Arena，新版本由用户
  点 `Reload` 显式提交。
- 加载是事务式的：任一 descriptor 不合法就在替换**之前**整批拒绝，旧 Arena 的 RID、
  内容、Registry 与 Revision 全部不变，面板显示 `Previous Arena Still Active`。

内部批量注册、mesh buffer refresh 和 ownership bookkeeping API 保留在
`ScenePlacementRuntime`，不再由 SPA 重复暴露无消费者的 thin facade。

## Volume 与交互入口

- `get_volume()` / `get_volume_ownership_report()`。
- `get_scene_sv_snapshot()` / `get_target_sv_snapshot()`。
- `ensure_svtile_gpu_ready()` / `get_svtile_gpu_status()` /
  `get_svtile_gpu_buffer()`。
- `set_volume_display()` / `set_volume_display_channel()`。
- `select_data_voxel(domain: String, x, y, z)` —— 首参是域名（`"svtile"` / `"sv"` / `"targetsv"` /
  `"anchor"`）。⚠ 2026-08-10 之前是模式号 `int`；`set_selection_mode()` / `get_selection_mode()`
  门面已于 2026-08-07 随选择模式机制删除，准入只看显示开关。
- `apply_brush_input()` / `clear_brush_sv()`。
- `run_anchors()` / `run_score()` / `run_place()`。
- `get_placement_selection_handoff()` / `get_anchor_candidate_handoff()` /
  `get_fine_score_handoff()` / `get_anchor_revision()` / `get_score_revision()`
  （见「常驻选择 handoff」）。

编辑器插件对 placement 输入只调用 `handle_editor_input()`。没有 SPA 时仅
允许 Asset Overview 使用自己的非 placement `_editor_viewport_input`。

## Placement pipeline

`run_placement_pipeline(sv, placement_common)` 执行 resident TargetSV →
prefilter/anchor handoff → fine/placement → GPU AutoObject writeback → SceneSV
commit。Dirty tile 由 GPU dirty worklist/count RID 传递；Fine 只消费 Anchor
handoff，不再上传 CPU tile id 列表。

`prepare_target_read_buffers_from_common_gpu()` 创建或复用 SPA-owned
TargetSV field/collision buffers；不同 RenderingDevice 的消费者必须
contract-block，不能复制到 CPU 再上传。

## 常驻选择 handoff

SPA 是 anchor / fine 常驻缓冲对点选侧的**唯一发布者**。消费方读
`get_placement_selection_handoff()`，不找 provider、不自己回读、不持有 CPU cache。

`get_placement_selection_handoff()`（`scene_placement_actor.gd`）返回一份自洽的只读记录。
成功时的键：

```text
ok / scored / anchor_revision / score_revision
anchor_buffer_rid / anchor_count_buffer_rid / topk_buffer_rid
fine_candidate_buffer_rid / fine_winner_buffer_rid          # scored=false 时为空 RID
anchor_capacity / anchor_stride_bytes / topk / topk_stride_bytes
fine_record_stride_bytes / live_anchor_count                # scored=false 时为 0 / -1
asset_stride / grid_size / voxel_size / grid_origin
rendering_device / borrowed / owner_path
```

失败时只有 `{ok=false, reason="selection_data_unavailable", detail=…}`。
**没有** `anchor_available` / `score_available` / `source` / `asset_count` 这些键——
它们是旧契约，按名读会一律取到默认值。

`scored` 是唯一的「已评分」判据：Fine 侧要么 candidate 与 winner 整对有效（`scored=true`），
要么整对判空。只跑过 Anchors 没跑过 Score 时 `scored=false` 是合法状态。

### 发布点

| 入口 | 行为 |
| --- | --- |
| `run_autoobject_prefilter()` | 经 `_publish_anchor_result()` 发布 Anchor 交接并 `_anchor_revision += 1`，同时作废 Score 交接 |
| `run_anchors()` | 同样过 `_publish_anchor_result()`，但传入的是不带 `anchor_candidate_handoff` 的薄状态字典 ⇒ **不换代**（交接已由内层 prefilter 发布过） |
| `run_score()` | 经 `_publish_score_result()` 发布 `fine_score_handoff` 并 `_score_revision += 1` |
| `run_place()` / `run_placement_pipeline()` | 经 `_publish_place_result()`——**不发布 anchor 交接**，只在 `ok` 时 `_invalidate_score_handoff()` |

换句话说，Anchor 交接的唯一换代点是 `_publish_anchor_result()`，而它只在结果里真的带
`anchor_candidate_handoff`（或嵌套的 `prefilter_result.anchor_candidate_handoff`）时才递增。
**新增第三处真正跑 prefilter 的生产路径必须一并登记**，否则那条路径产出的 anchor 对点选侧
不可见——而且是静默不可见，不报错。

作废是私有的：`_invalidate_score_handoff()` 无参、只解除发布（换代 + 丢键），不释放显存
（Fine candidate/winner 的 owner 是 VPG）。anchor 侧没有对应的对外作废方法——
`invalidate_anchor_handoff(reason)` / `invalidate_score_handoff(reason)` 都不存在。

### 为什么必须比对 revision，不能只看 RID

prefilter 的 anchor/count/topk 三块缓冲是**复用**的：再跑一次 prefilter 会把内容整体覆写，
而 RID 一个不变。消费规则：读取前后各取一次 revision，中途变化 ⇒ 丢弃结果、最多重试一次；
RID 是借的，消费方不得 `free_rid()` / `release_rid()` / buffer update / dispatch。

## 测试场景

| 场景 | 说明 | Godot 场景 |
| --- | --- | --- |
| [Placement Score 3D](placement-score-3d.md) | 仓库中唯一仍在的 placement demo 场景，覆盖本文的 GPU 常驻路径 | [`placement-score-3d.tscn`](../demos/placement-score-3d/placement-score-3d.tscn) |
