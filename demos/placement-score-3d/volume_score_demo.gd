@tool
extends "res://scripts/core_demo_contract_fixture.gd"

## placement-score-3d — Volume-Score Provider（真实链版）
##
## 真实上游：placement_stage_env 把链推进到 S6（S0 地形+S3 profile 注册+S4 committer
## 提交+S1/S5 target 读缓冲+S6 prefilter 常驻 anchor handoff），本 demo 只做 S7 细筛
## 观察：VolumeScoreFineSelection.run 吃真实 handoff + BlendSV 工作对（committed SV
## 副本，评分幂等）打分，每 (anchor x topk-asset) residual gain 排名，胜者放真实
## descriptor mesh（CLAUDE.md 规则，永不代理盒）。
## 锚点 = collect_sv_anchors 的 target-inside 体素（3D，可悬空，预期行为）；
## collect 在**地形高度**采样目标体积，采到就发锚（步长 0 = 只采地形那一格，
## ≥1 = 地形切片及其以上每 n 层再采一次）；上限为 ANCHOR_CAPACITY=131072。
## prefilter_tile_rect 空时单次处理全图，非空时处理指定 tile 区域。

const DemoUI := preload("res://scripts/utils/demo_ui.gd")
const DemoDebugVisuals := preload("res://scripts/utils/demo_debug_visuals.gd")
const TargetSVLoaderScript := preload("res://scripts/target_sv_loader.gd")
const SPAEditorContract := preload("res://scripts/spa_editor_contract.gd")
const PlacementStageEnv := preload("res://scripts/checks/placement_stage_env.gd")
const FineSelection := preload("res://scripts/volume_score_fine_selection.gd")
const ScoreTimingProfilerScript := preload("res://scripts/utils/score_timing_profiler.gd")
const VoxelDisplay := preload("res://scripts/utils/voxel_display.gd")
const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")
const SceneVoxelTileStoreScript := preload("res://scripts/scene_voxel_tile_store.gd")
const ProfileRecordSchemaScript := preload("res://scripts/utils/profile_record_schema.gd")
const PlacedInstanceDisplayScript := preload("res://scripts/utils/placed_instance_display.gd")
const SlotIdentityCheck := preload("res://scripts/checks/slot_identity_check.gd")
const VoxelDebugLabel := preload("res://scripts/utils/voxel_debug_label.gd")

const VOXEL_DISPLAY_ANCHOR := SPAEditorContract.VOXEL_DISPLAY_ANCHOR
const VOXEL_DISPLAY_GPU_OBJECTS := SPAEditorContract.VOXEL_DISPLAY_GPU_OBJECTS
const VOLUME_SCORE_DISPLAY_OWNER := "volume_score"
const SELECTION_DOMAIN_ANCHOR := SPAEditorContract.SELECTION_DOMAIN_ANCHOR
const SELECTION_GEOMETRY_VOLUME_SCORE_ANCHOR := SPAEditorContract.SELECTION_GEOMETRY_VOLUME_SCORE_ANCHOR
const ANCHOR_RADIUS_MIN := 0.06
const PLACED_AUTOOBJECTS_NODE_NAME := "PlacedAutoObjects"
# ⚠ 这里曾有 `SVTILE_OVERLAY_ROOT_NAME`（热力图的显示根节点名）。热力图整套删除后
# 成为孤儿常量（2026-08-10）。
## Place 步（run_pipeline_once，S5→S9）的放置公共参数；rotation_slots / min_target_interest /
## min_prefilter_score / result_capacity / min_distance_voxels 在 place_final_autoobjects 内
## 按导出覆盖，保持与 Anchors/Score 同门限。collision_limit 门是批间自然互斥的关键：
## 上一批盖章的 collision 使下一批候选在已放置足迹上 invalid。
## 门限的 SSOT 在 SPA——benchmark 与生产必须同门限，这里只是引用，不再各写一份字面量。
const PLACE_PIPELINE_COMMON := ScenePlacementActor.PLACE_PIPELINE_COMMON
## 视距剔除重算的最小时间间隔（ms）：相机连续快速移动时，即便每帧都越过位移阈值，也
## 最多每这么久重算一次，避免大实例量（可达 65536）下每帧 O(N) 重写拖慢编辑器。
const CULL_MIN_INTERVAL_MS := 33

# ---- Exported Tunables -----------------------------------------------------
@export_range(1, 8, 1) var selected_anchor_top_k: int = 4      # 选中锚点显示的 Top-K 资产数
# ---- 生产参数转发（SSOT = SPA 的 "Placement Tuning" 导出组）------------------
#
# 这 9 个参数直接决定评分与放置结果，存储已归 SPA。这里保留同名转发，只是让 demo 的
# benchmark / HUD / golden 读取点不必逐个改写——**没有第二份存储**，也就没有"两边默认值
# 一样、改了一边才发现对不上"的漂移。
# ⚠ 别把它们改回 @export：那会重新引入第二份存储，正是本次要消灭的东西。
# SPA 不可达时返回与 SPA 相同的声明默认值（仅发生在未挂进 SPA 子树的孤立实例上）。
var rotation_slots: int:
	get:
		var spa := _spa_display_host()
		return spa.rotation_slots if spa != null else 12
	set(value):
		var spa := _spa_display_host()
		if spa != null: spa.rotation_slots = value
var min_target_interest: float:
	get:
		var spa := _spa_display_host()
		return spa.min_target_interest if spa != null else 0.01
	set(value):
		var spa := _spa_display_host()
		if spa != null: spa.min_target_interest = value
var anchor_vertical_stride: int:
	get:
		var spa := _spa_display_host()
		return spa.anchor_vertical_stride if spa != null else 0
	set(value):
		var spa := _spa_display_host()
		if spa != null: spa.anchor_vertical_stride = value
var min_prefilter_score: float:
	get:
		var spa := _spa_display_host()
		return spa.min_prefilter_score if spa != null else 0.35
	set(value):
		var spa := _spa_display_host()
		if spa != null: spa.min_prefilter_score = value
var place_result_capacity: int:
	get:
		var spa := _spa_display_host()
		return spa.place_result_capacity if spa != null else 1024
	set(value):
		var spa := _spa_display_host()
		if spa != null: spa.place_result_capacity = value
var place_max_batches: int:
	get:
		var spa := _spa_display_host()
		return spa.place_max_batches if spa != null else 24
	set(value):
		var spa := _spa_display_host()
		if spa != null: spa.place_max_batches = value
var place_min_distance_voxels: float:
	get:
		var spa := _spa_display_host()
		return spa.place_min_distance_voxels if spa != null else 2.0
	set(value):
		var spa := _spa_display_host()
		if spa != null: spa.place_min_distance_voxels = value
var prefilter_tile_rect: Rect2i:
	get:
		var spa := _spa_display_host()
		return spa.prefilter_tile_rect if spa != null else Rect2i()
	set(value):
		var spa := _spa_display_host()
		if spa != null: spa.prefilter_tile_rect = value

## ⚠ 这里曾有 `@export var placement_assets: Array[AssetDescriptor]` 与一个默认指向
## `res://assets` 的 `@export_dir asset_descriptor_dir` 回退扫描。两者已删除：本类不再
## 持有任何资产列表，也不扫盘——AD 的加载逻辑只此一份，在 SPA
## （`ScenePlacementActor.load_baked_assets()` 扫 `baked_descriptors/`）。
## 需要资产时一律现取 `_load_descriptors()`，它直读 SPA registry，不留副本。
@export var auto_run_on_start := true
## 开:每次 run 打印 score→reduce→stamp→readback 分阶段耗时——用于定位 GPU 打分管线
## 性能瓶颈。见 [ScoreTimingProfiler]。默认关(零开销)。
@export var profile_score_timing := false
## golden 快照锚点段上限（排序序前 N；0=全量）。Golden 场景显式设为 1024；js diff 侧已有大文件
## 护栏（超限退化为首个差异行摘要），全量快照不再受 O(n²) LCS 约束。
@export_range(0, 131072, 1) var golden_anchor_limit := 0

# ---- View-Distance Culling（放置/胜出模型逐实例视距剔除）--------------------
## 开:放置/胜出的资产模型按到相机的距离逐实例剔除——超出 model_cull_distance 的实例
## 不再渲染，随相机移动实时更新。anchor 蓝色球点标记不走资产模型路径 → 不受影响
## （用户口径：仅剔除真实资产模型）。
## 两条路各自实现同一个语义：胜出预览走 CPU（`_apply_model_cull` 压缩
## `visible_instance_count`），放置结果走 GPU（emit kernel 给被剔实例写零基向量）。
@export var cull_models_by_distance := true:
	set(value):
		cull_models_by_distance = value
		if is_node_ready():
			_on_cull_settings_changed()
## 剔除距离（世界单位）：实例中心到相机超过此值即隐藏。放置 mesh 是原生 FBX 尺度
## （草 ~2u），1024u 地形上默认 300u 给明显中景剔除——按场景尺度调。
@export_range(1.0, 8192.0, 1.0) var model_cull_distance := 300.0:
	set(value):
		model_cull_distance = maxf(value, 1.0)
		if is_node_ready():
			_cull_dirty = true
## 相机移动超过该阈值（世界单位）才重算剔除——静止/纯转视时零重写开销。
@export_range(0.0, 64.0, 0.5) var model_cull_recompute_move := 1.0

# ---- State -----------------------------------------------------------------
var _assets: Array[Dictionary] = []       # 每资产：{descriptor, name, mesh, color, aabb, material}
var _model: Dictionary = {}               # FineSelection 结果模型（唯一评分状态）
# 选中态的 SSOT 是 SPASelectionHost（SPA/Interaction/SelectionHost）。这里只做转发，
# **没有第二份存储**——demo 的 HUD、winner-profile 观察态与红框都读同一个数。
# ⚠ 别改回 `var _selected_anchor_idx := -1`：那会让 demo 画的东西和实际选中的锚点各走各的。
var _selected_anchor_idx: int:
	get:
		var host := _selection_host_or_null()
		return host.get_selected_anchor_index() if host != null else -1
	set(value):
		var host := _selection_host_or_null()
		if host == null:
			return
		if value < 0:
			host.clear_selected_anchor()
		else:
			host.select_anchor(value)
var _env = null                           # PlacementStageEnv（S0..S6 底座，由 SPA host 持有）
var _env_error := ""                      # 最近一次 env 构建失败原因（HUD 展示）
var _last_env_ready_phases_ms := {}
var _spa_host: ScenePlacementActor = null
var _last_score_timing_profile: Dictionary = {}
var _last_visualization_timing_profile: Dictionary = {}
var _last_winner_visualization_timing_profile: Dictionary = {}
var _visualization_cache_positions := PackedVector3Array()
var _visualization_cache_winners := PackedInt32Array()
var _visualization_cache_rotations := PackedInt32Array()
var _visualization_cache_rotation_slots := -1
var _placed_result: Dictionary = {}       # 最近一次 Place 的结果（HUD 展示）
# 诊断留存（debug_anchor_breakdown / _debug_target_neighborhood 消费；懒加载——
# 评分链走 S5 常驻 GPU，不再依赖这份 CPU 副本）
var _diag_target_completeness := PackedFloat32Array()
var _diag_target_collision := PackedFloat32Array()
var _diag_target_color := PackedColorArray()
## 调试可视化用的 descriptor fine 体素缓存：instance_id -> Array[Dictionary]{voxel, color}。
## get_profile_samples() 每次调用都全量 normalize + 深拷贝（五资产合计约 5 万条采样），
## 而 _rebuild_winner_voxel_profile_node（每次点选锚点）与 pivot sweep（pivot×yaw 双重循环）
## 都在热路径上——按 descriptor 实例缓存一次转换结果。资产重载（_reload_placement_descriptors
## → SPA 重扫，BakedAssetLoader 以 CACHE_MODE_REPLACE 就地覆盖同一实例）时整体清空：
## 实例地址不变而内容已换，不清就会拿旧采样。
var _descriptor_fine_voxel_cache: Dictionary = {}

# ---- Display Nodes ---------------------------------------------------------
var _hud_label: Label
var _display_root: Node3D

# 逐实例视距剔除：每组保存受剔除 MultiMesh 的完整实例变换源（节点内 MultiMesh 只驻留
# 在范围内实例，源在此以便随相机移动重算）。项 = {"node", "transforms"(Array[Transform3D])}。
var _cull_groups: Array[Dictionary] = []
var _last_cull_camera_pos := Vector3(INF, INF, INF)
var _last_cull_time_ms := 0
var _cull_dirty := true

# 放置实例的 GPU 直提显示器（PlacedInstanceDisplay，节点名 PLACED_AUTOOBJECTS_NODE_NAME）。
# ⚠ 它**不进** _cull_groups：那条路会调 set_instance_transform()，一次就把 MultiMesh 拉回
# CPU 缓冲并静默清零全部 GPU 写入的实例。它的视距剔除由 emit kernel 承担（写零基向量）。
var _placed_display: Node3D = null
var _placed_display_result: Dictionary = {}

# ⚠ 这里曾有 SVTile object-ref 热力图的整套状态（overlay 根 / heatmap / 总览标签 /
# 四个统计成员）。它是 DemoHost 移除那一轮被"抢救"下来的——当时的理由是
# 「热力图是全项目唯一的 SVTile 可视化，删了这个域就永远不可见、按『看不见就选不中』
# 将永久不可选」。⚠ 那条理由**不成立**：热力图从来没有 PICK_DRAWABLE_META、也没进
# `voxel_display_group("svtile")`，它根本不在 ID pass 里，保住的只是"看得见"。
#
# 2026-08-07 `SVTileVolume` 建了真正可点选的八面体之后，两者并存：同一个 `svtile` 显示键、
# 同样是八面体、空间上叠在同一批砖（一个贴地 0.35 m、一个悬在瓦片中心 14.4 m），
# 只是数据不同（object-ref 计数 vs 体素占用计数）。
#
# ⇒ 用户裁定（2026-08-10）：**一个可视化，点击拿全部信息**。热力图整套删除；
# object-ref 计数并不丢失——`SPASelectionHost._svtile_record_for_voxel()` 本来就带
# `object_ref_count`（读同一个槽位缓冲）与完整 `tile_record`，点中那块砖即可见。

# ---- Ctrl+H：选中锚点胜出者的 voxel profile 观察（临时观察逻辑）----------------
# 隐藏全部 anchor 胜出 mesh、就地显示选中锚点胜出者 canonical fine 采样的彩色体素盒；再按恢复；
# 未选中任何锚点则恢复全部显示。⚠ 约定：demo 临时/观察逻辑，只切换显示，不碰评分·放置。
var _winner_profile_mode := false
var _winner_profile_node: Node3D = null

# ⚠ 编辑器软重载（@tool 脚本重新解析）后的成员修复，别当成冗余判空删掉。
#
# 事实依据（gdscript.cpp GDScriptInstance::reload_members）：软重载只把**重载前已存在**
# 的成员按名字搬进新槽位（值原样保留，不回初始值）；本次重载**新增**的成员槽是默认构造
# 的 Variant = nil，声明里的初始化器**不会**重跑。带静态类型也拦不住——实例槽本身是
# Variant。本 demo 是编辑器场景里常驻的 @tool 节点，重载后的第一帧 _process() 就会炸在
# `_cull_groups.is_empty()`（在 Nil 上找方法），HUD/评分路径同理会炸在
# `_model.get(...)`、`_placed_object_ids.size()` 等位置；`_visualization_cache_rotation_slots`
# 这类 int 还会被拿去做取模/下标。
#
# ⚠ 必须用 `is` 而不是 `== null`：对静态类型已知的操作数 GDScript 会挑验证求值器
# （gdscript_byte_codegen.cpp write_binary_operator），而 Variant 给 (INT, NIL)、
# (DICTIONARY, NIL) 这类组合注册的是 OperatorEvaluatorAlwaysFalse（variant_op.cpp），
# `x == null` 会被编成恒 false，判空形同虚设。
# `is` 编成 OPCODE_TYPE_TEST_BUILTIN，查的是运行时真实类型，nil 一定为假。
#
# 语义：只回填 nil 槽，正常路径一个值都不动。全部回到"什么都还没算过"的冷态——
# 各缓存清空即缓存未命中（只多算一次，不会误命中），`_cull_dirty = true` 保证下一帧
# 重新计算剔除分组，`_visualization_cache_rotation_slots = -1` 是既有的"缓存无效"哨兵。
func _repair_soft_reloaded_members() -> void:
	if not (_assets is Array): _assets = []
	if not (_model is Dictionary): _model = {}
	# _selected_anchor_idx 已无本地存储（转发到 SelectionHost），软重载没有槽位可修
	# ——修复由 host 自己那个成员负责。
	if not (_env_error is String): _env_error = ""
	if not (_last_env_ready_phases_ms is Dictionary): _last_env_ready_phases_ms = {}
	if not (_last_score_timing_profile is Dictionary): _last_score_timing_profile = {}
	if not (_last_visualization_timing_profile is Dictionary): _last_visualization_timing_profile = {}
	if not (_last_winner_visualization_timing_profile is Dictionary): _last_winner_visualization_timing_profile = {}
	if not (_visualization_cache_positions is PackedVector3Array): _visualization_cache_positions = PackedVector3Array()
	if not (_visualization_cache_winners is PackedInt32Array): _visualization_cache_winners = PackedInt32Array()
	if not (_visualization_cache_rotations is PackedInt32Array): _visualization_cache_rotations = PackedInt32Array()
	if not (_visualization_cache_rotation_slots is int): _visualization_cache_rotation_slots = -1
	if not (_placed_result is Dictionary): _placed_result = {}
	if not (_placed_display_result is Dictionary): _placed_display_result = {}
	if not (_diag_target_completeness is PackedFloat32Array): _diag_target_completeness = PackedFloat32Array()
	if not (_diag_target_collision is PackedFloat32Array): _diag_target_collision = PackedFloat32Array()
	if not (_diag_target_color is PackedColorArray): _diag_target_color = PackedColorArray()
	if not (_descriptor_fine_voxel_cache is Dictionary): _descriptor_fine_voxel_cache = {}
	if not (_cull_groups is Array): _cull_groups = []
	if not (_last_cull_camera_pos is Vector3): _last_cull_camera_pos = Vector3(INF, INF, INF)
	if not (_last_cull_time_ms is int): _last_cull_time_ms = 0
	if not (_cull_dirty is bool): _cull_dirty = true
	if not (_winner_profile_mode is bool): _winner_profile_mode = false


## Register with the ancestor SPA; there is no process-global provider registry.
func _ready() -> void:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	super._ready()
	if is_scene_startup_blocked():
		return
	_setup_hud()
	_ensure_display_root()
	_update_cull_processing()  # 无组时关处理；模型构建（registration）时再打开
	# SPA 绑定需重复：编辑器刚打开组合场景时子场景可能未同步完成
	_sync_spa_bindings()
	_sync_spa_bindings.call_deferred()
	if auto_run_on_start:
		calculate_voxel_scores.call_deferred()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_unregister_spa_volume_score_provider()
		_dispose_pipeline(false)


func _exit_tree() -> void:
	# The provider's cached VPG borrows the SPA RenderingDevice. Release it while
	# that device is still alive; PREDELETE can occur after the parent SPA has
	# already shut the device down during an editor scene switch.
	_unregister_spa_volume_score_provider()
	_dispose_pipeline(false)


## Release provider/session resources only. The adapter and every GPU owner are
## borrowed from the ancestor SPA and remain alive.
##
## reconcile_display=false 只给拆卸路径（_exit_tree / PREDELETE）用，原因见
## _reconcile_display() 的注释：那两处不能再动节点树。其余调用点一律用默认 true，
## 让"清空 _model"必然带上"显示消失"。
func _dispose_pipeline(reconcile_display: bool = true) -> void:
	var spa_host := _spa_display_host()
	if spa_host != null and is_instance_valid(spa_host) \
			and spa_host.has_method("set_autoobject_pick_data"):
		spa_host.call("set_autoobject_pick_data", {})
	# ⚠ 绝不能 _env.dispose()：这份 env 是**借来的**，owner 是 SPA（见 _ensure_env_ready）。
	# demo 拆自己的显示不该顺手把 SPA 的阶段底座和常驻 target 缓冲一起拆了。
	# 只丢引用；真正的释放在 SPA._shutdown。
	_env = null
	_last_env_ready_phases_ms = {}
	_invalidate_visualization_cache()
	_placed_result = {}
	# 放在最后：_publish_model 会调和显示，而显示重建要读上面这些已复位的状态。
	if reconcile_display:
		_publish_model({})
	else:
		_model = {}


## 内容写入口：清空 _model 时必须经由本函数，让"数据失效 ⇒ 显示消失"成为一次调用而不是
## 两处要各自记得的清理。
##
## 本函数存在的直接原因——以下路径都清空了 _model 却到不了显示重建，于是锚点/胜出网格
## 继续渲染在一份已经不存在的数据上：
##   reload_and_rescore()            清空后重算在 _ensure_env_ready() 失败时提前返回
##   benchmark_score_stamp_once_json / benchmark_place_once_json /
##   benchmark_scene_bootstrap_once_json   清空后根本不重建（桥一次调用即可复现）
func _publish_model(next_model: Dictionary) -> void:
	_model = next_model
	# 选中态是 _model 里锚点数组的下标：数据没了，下标必然失效，必须在同一处一起作废。
	# 不能指望 _build_visualization() 里的越界钳制——它在「锚点为空」的提前返回之后，
	# 空模型压根走不到。漏掉这一半的后果是 has_selected_anchor() 仍为 true 而记录为空，
	# 宿主侧 _volume_score_selection_record() 于是合成出 volume_score_anchor:-1，
	# 把黄色选中框停在世界原点。
	if _model.is_empty():
		_clear_selection()
	_reconcile_display()


## 显示调和。拆卸期（_exit_tree / PREDELETE）必须直接返回，不能再动节点树：
##  - _exit_tree 期间 add_child 不会被拦：Node::_propagate_exit_tree 先跑完子节点循环、
##    最后才把 data.tree 置空，所以此时新增的子节点会收到 ENTER_TREE 却永远收不到
##    EXIT_TREE，留下一个 tree 指针陈旧的节点。
##  - PREDELETE 是反向派发的，GDScript 处理器先于 Node::_notification 里 memdelete 子节点
##    执行——在一个下一条语句就要被销毁的节点上重建 MultiMesh 是纯粹的浪费。
## 因此拆卸路径走 _dispose_pipeline(false)：只清数据，显示交给节点销毁本身。
func _reconcile_display() -> void:
	if not is_inside_tree():
		return
	_build_visualization()


# ---- 模型派生 getter（旧 _scored/_anchor_world_positions/_total_anchors 成员替代）----

## 按需物化 _model 的 CPU 锚点数组——点选 / 显示 / HUD / golden / 诊断的统一触发口。
##
## prefilter 与细筛全程只跑 GPU：prefilter 不回读 anchor 位置，runner 返回的模型带
## cpu_anchor_model_pending=true，锚点坐标还留在 GPU 常驻缓冲里。本函数第一次被调用
## 时回读一次并把补全后的模型写回 _model（pending 清成 false）。
## ⚠ 一次 Score 点击必然经过 _build_visualization → 本函数，所以**带显示的 Score 并没有
## 省下这次回读**（字节数与改动前顺带回读时相同，只是时机变了）；省下的是 Place 批次 /
## 纯 GPU benchmark 这些从头到尾不需要 CPU 锚点坐标的路径。
##
## 失效条件（不新造平行状态）：缓存就是 _model 字典本身。每次 Score / Anchors / Place
## 都整份替换 _model（_run_scoring 直接赋值、generate_anchors 赋值、_publish_model 写入），
## 新模型自带 pending=true，于是"GPU 结果换代 ⇒ CPU 模型缓存作废"是同一次赋值的必然
## 结果；同一批 GPU 结果内的重复点选只做一次 O(1) 标记判断，不会重复回读。
func _ensure_anchor_cpu_model() -> void:
	if not bool(_model.get("cpu_anchor_model_pending", false)):
		return
	# 物化归 SPA：模型的 SSOT 在那边，就地补全后必须写回 SPA 的那一份，
	# 否则 demo 补一次、SPA 还留着 pending，下一次同步又把补全结果冲掉。
	var spa := _spa_display_host()
	_model = spa.ensure_score_model_cpu_anchors() if spa != null \
		else FineSelection.materialize_cpu_anchor_model(_model)


func _scored() -> bool:
	return bool(_model.get("ok", false))


func _anchor_world_positions() -> PackedVector3Array:
	_ensure_anchor_cpu_model()
	return _model.get("anchor_world_positions", PackedVector3Array())


func _total_anchors() -> int:
	_ensure_anchor_cpu_model()
	return int(_model.get("anchor_count", 0))


func _voxel_size() -> Vector3:
	return _model.get("voxel_size", Vector3.ONE)


func _anchor_voxel(anchor_index: int) -> Vector3i:
	_ensure_anchor_cpu_model()
	var voxels: Array = _model.get("anchor_voxels", [])
	if anchor_index < 0 or anchor_index >= voxels.size():
		return Vector3i(-1, -1, -1)
	return voxels[anchor_index]


func _asset_names() -> Array:
	var names: Array = []
	for entry in _assets:
		names.append(str(entry.get("name", "Asset%d" % names.size())))
	return names


# ---- Public API — SPA provider interface -----------------------------------

## 每次 AD bake 之后刷新：meshfill 插件的 "Bake AD" 按钮在烘焙成功后经
## SPA 在 descriptor bake 后调到这里。令 SPA 重扫 baked_descriptors 目录刷新 registry
## (新烘焙的自动出现、重烘焙的刷新、删除的消失)、清 _assets 缓存；描述符变了——probes/collision 全过期 →
## env（含 SPA 注册 + prefilter 常驻 handoff）与 runner（VPG 缓存）整体失效重建。
func reload_and_rescore() -> Dictionary:
	if not Engine.is_editor_hint():
		return {"ok": false, "reason": "not_editor_hint"}
	_reload_placement_descriptors()   # 内部经 SPA 的 baked_assets_reloaded 广播回到本类
	return calculate_voxel_scores()


## 作废一切从 descriptor 派生的东西。
##
## 接线方式是**订阅**而不是被点名：SPA 在 `register_volume_provider()` 时发现本类实现了
## 本方法，就把它挂到 `baked_assets_reloaded` 信号上（注销时对称断开）。所以无论换代由
## 谁触发——SPA 的 Reload、init、Bake AD 后的插件刷新——都会走到这里，本类不需要知道是谁。
##
## ⚠ 为什么不能靠"descriptor 换了新实例"来自然失效：`BakedAssetLoader` 用
## `CACHE_MODE_REPLACE` 就地覆盖同一个 Resource 实例，实例地址不变而内容已换。
## 下面两个缓存都以 descriptor 实例为键，不显式清就会稳稳命中旧条目——
## 表现正是"点了 Reload 但 AD 没更新"。
func invalidate_asset_caches() -> void:
	_descriptor_fine_voxel_cache.clear()   # profile_samples 变了 → 调试体素缓存整体作废
	_assets.clear()                        # 让 _ensure_assets_ready 重建 mesh/color/aabb
	_dispose_pipeline()                    # env + runner 里存的是上一代 profile_id
	_diag_target_completeness = PackedFloat32Array()
	_diag_target_collision = PackedFloat32Array()
	_diag_target_color = PackedColorArray()


## 让 SPA 强制重扫 Bake 目录，使一次 Bake AD 立刻生效：新烘焙的出现、重烘焙的刷新、
## 删除的消失。本类不持有资产列表，缓存作废由 SPA 的 baked_assets_reloaded 广播完成。
func _reload_placement_descriptors() -> void:
	var spa := _spa_display_host()
	if spa == null:
		push_warning("[VolumeScore] 找不到 SPA 宿主——无法重扫 Bake 目录。")
		invalidate_asset_caches()   # 没有 SPA 就收不到广播，自己清
		return
	# 强制重扫（force=true）：重烘焙常同名覆盖、目录签名不变，非 force 会被短路吃掉。
	var report := spa.load_baked_assets(true)
	if not bool(report.get("ok", false)):
		push_warning("[VolumeScore] 重载资产失败（%s）——沿用上一版 registry。" % [
			str(report.get("reason", "unknown"))])
		invalidate_asset_caches()   # 失败路径不发广播，仍要清：内容可能已部分换代


## 完整管线：env（S0..S5 底座）→ 真实 S6 prefilter → S7 细筛 → 可视化
## region_rects 空 = 按 prefilter_tile_rect 导出解析（空导出 → 单次全图）；
## 冻结名（SPA 字符串调用无参形态不变），golden 入口传 _full_map_region_rects()
## 强制全量计算（与交互导出解耦——用户把导出改成单区域也不影响 golden 口径）。
## 评分入口。细筛链、score cache key 与 Fine 常驻交接都归 SPA（run_score）；
## 本方法只剩 demo 侧的展示尾巴与墙钟计时。
func run_volume_score_pipeline(
	region_rects: Array = [],
	full_candidate_diagnostics: bool = false,
	allow_model_cache: bool = true,
	allow_non_editor_contract: bool = false
) -> Dictionary:
	if not Engine.is_editor_hint() and not allow_non_editor_contract:
		return {"ok": false, "reason": "not_editor_hint"}
	var spa := _spa_display_host()
	if spa == null:
		return {"ok": false, "reason": "ancestor_scene_placement_actor_unavailable"}
	var wall_profiler := ScoreTimingProfilerScript.new(profile_score_timing, "volume_score_click_wall")
	var cache_timing_ms := {}
	var phase_t0_usec := Time.get_ticks_usec()
	wall_profiler.mark("run_start")
	_sync_spa_bindings()
	cache_timing_ms["sync_spa_before"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	phase_t0_usec = Time.get_ticks_usec()
	wall_profiler.mark("sync_inputs")
	var status: Dictionary = spa.run_score({
		"region_rects": region_rects,
		"full_candidate_diagnostics": full_candidate_diagnostics,
		"allow_model_cache": allow_model_cache,
		"profile_timing": profile_score_timing,
	})
	_sync_model_from_spa()
	var score_cache_hit := bool(status.get("score_cache_hit", false))
	cache_timing_ms["score_or_cache_match"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	phase_t0_usec = Time.get_ticks_usec()
	wall_profiler.mark("score_cache_hit" if score_cache_hit else "score_core")
	_build_visualization()
	cache_timing_ms["visualization"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	phase_t0_usec = Time.get_ticks_usec()
	wall_profiler.mark("visualization")
	_sync_spa_bindings()
	cache_timing_ms["sync_spa_after"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	phase_t0_usec = Time.get_ticks_usec()
	wall_profiler.mark("sync_spa_bindings")
	_update_hud()
	cache_timing_ms["update_hud"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	phase_t0_usec = Time.get_ticks_usec()
	wall_profiler.mark("hud")
	_notify_spa_selected_anchor_changed()
	cache_timing_ms["notify_selection"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	wall_profiler.mark("spa_notify")
	wall_profiler.mark("done")
	if score_cache_hit:
		status["score_cache_timing_ms"] = cache_timing_ms
	if profile_score_timing:
		_last_score_timing_profile = wall_profiler.build_report(false)
		_last_score_timing_profile["score_core_detail"] = _model.get("score_core_timing_profile", {})
		_last_score_timing_profile["visualization_detail"] = _last_visualization_timing_profile
		status["score_timing_profile"] = _last_score_timing_profile
		print(wall_profiler.format_report())
	else:
		_last_score_timing_profile = {}
	return status


## 把 SPA 的结果模型同步成 demo 的本地视图。
## ⚠ _model 自此是**镜像**，不是 demo 自己的状态：所有换代都发生在 SPA 侧，
## demo 只在每次 SPA 命令之后重新取一次。别再往 _model 里直接写评分结果。
func _sync_model_from_spa() -> void:
	var spa := _spa_display_host()
	_model = spa.get_last_score_model() if spa != null else {}
	if _model.is_empty():
		_clear_selection()
	_invalidate_visualization_cache()


## 仅推进到 S6 并显示锚点（不评分）。
## 流水线本身已归 SPA（run_anchors）；本方法只剩 demo 侧的展示尾巴。
func generate_anchors() -> Dictionary:
	if not Engine.is_editor_hint():
		return {"ok": false, "reason": "not_editor_hint"}
	var spa := _spa_display_host()
	if spa == null:
		return {"ok": false, "reason": "ancestor_scene_placement_actor_unavailable"}
	var result := spa.run_anchors()
	_sync_model_from_spa()
	_clear_selection()
	_build_visualization()
	_update_hud()
	return result


## 评分入口；名字对齐 SPA run_score → provider.call("calculate_voxel_scores")——
## 语义 = run_volume_score_pipeline（真实链下锚点由 S6 产出，无独立"先锚点后评分"两步）。
func calculate_voxel_scores() -> Dictionary:
	var result := run_volume_score_pipeline()
	if bool(result.get("ok", false)):
		_prepare_ready_place_resources.call_deferred()
	return result


## 编辑器桥单次 Score 性能入口。profile_stages=false 测真实交互墙钟；true 会启用
## pass 间 submit+sync，并在 timing 中返回 VPG、模型、可视化和 HUD/SPA 分段。
func benchmark_score_once_json(profile_stages = false) -> String:
	var previous_profile := profile_score_timing
	profile_score_timing = bool(profile_stages)
	var t0_usec := Time.get_ticks_usec()
	var status := run_volume_score_pipeline([], false, false)
	var wall_ms := float(Time.get_ticks_usec() - t0_usec) / 1000.0
	profile_score_timing = previous_profile
	return JSON.stringify({
		"ok": bool(status.get("ok", false)),
		"wall_ms": wall_ms,
		"anchor_count": _total_anchors(),
		"asset_count": _assets.size(),
		"timing": status.get("score_timing_profile", {}),
		"score_cache_hit": bool(status.get("score_cache_hit", false)),
		"fine_dispatch_count": int(status.get("fine_dispatch_count", -1)),
	})


func benchmark_score_cache_once_json() -> String:
	var warm := run_volume_score_pipeline([], false, false)
	if not bool(warm.get("ok", false)):
		return JSON.stringify({"ok": false, "reason": "cache_warm_failed"})
	var t0_usec := Time.get_ticks_usec()
	var status := run_volume_score_pipeline([], false, true)
	var wall_ms := float(Time.get_ticks_usec() - t0_usec) / 1000.0
	return JSON.stringify({
		"ok": bool(status.get("ok", false)),
		"wall_ms": wall_ms,
		"anchor_count": _total_anchors(),
		"score_cache_hit": bool(status.get("score_cache_hit", false)),
		"fine_dispatch_count": int(status.get("fine_dispatch_count", -1)),
		"timing": status.get("score_cache_timing_ms", {}),
	})


## Runs one real placement batch for bridge-driven Fine/Stamp validation. The
## mutated resident fields are disposed before returning so later score samples
## rebuild the editor-only environment from its canonical inputs.
func benchmark_score_stamp_once_json(profile_stages = true, result_capacity = 64) -> String:
	if not Engine.is_editor_hint():
		return JSON.stringify({"ok": false, "reason": "not_editor_hint"})
	_sync_spa_bindings()
	if not _ensure_env_ready():
		return JSON.stringify({"ok": false, "reason": _env_error})
	var common := PLACE_PIPELINE_COMMON.duplicate()
	common["rotation_slots"] = rotation_slots
	common["min_target_interest"] = min_target_interest
	common["anchor_vertical_stride"] = anchor_vertical_stride
	common["min_prefilter_score"] = min_prefilter_score
	common["result_capacity"] = clampi(int(result_capacity), 1, 1024)
	common["min_distance_voxels"] = place_min_distance_voxels
	common["score_timing_profile"] = bool(profile_stages)
	common["score_timing_label"] = "volume_score_stamp_validation"
	var t0_usec := Time.get_ticks_usec()
	var pipeline_result: Dictionary = _env.run_pipeline_once(common)
	var wall_ms := float(Time.get_ticks_usec() - t0_usec) / 1000.0
	var placement_result: Dictionary = pipeline_result.get("placement_result", {})
	var prefilter_result: Dictionary = pipeline_result.get("prefilter_result", {})
	var stamp_writeback: Dictionary = placement_result.get("instance_stamp_writeback", {})
	var profile_contract: Dictionary = placement_result.get("gpu_runtime_profile_contract", {})
	var stamp_dispatched := str(stamp_writeback.get("reason", "")) == "gpu_state_chain_stamp_committed"
	var report := {
		"ok": bool(pipeline_result.get("ok", false))
			and bool(profile_contract.get("ok", false))
			and stamp_dispatched,
		"wall_ms": wall_ms,
		"anchor_count": int(prefilter_result.get("anchor_count", 0)),
		"placed_count": int(placement_result.get("total_placed", 0)),
		"stamp_dispatched": stamp_dispatched,
		"stamp_writeback_reason": str(stamp_writeback.get("reason", "missing")),
		"profile_contract_ok": bool(profile_contract.get("ok", false)),
		"profile_contract_reason": str(profile_contract.get("reason", "missing")),
		"timing": placement_result.get("score_timing_profile", {}),
	}
	_dispose_pipeline()
	return JSON.stringify(report)


func benchmark_place_once_json(profile_stages = false, max_batches = 3) -> String:
	var previous_profile := profile_score_timing
	var previous_max_batches := place_max_batches
	profile_score_timing = bool(profile_stages)
	place_max_batches = clampi(int(max_batches), 1, 16)
	_dispose_pipeline()
	var t0_usec := Time.get_ticks_usec()
	var env_ready := _ensure_env_ready()
	var prepare := _prepare_ready_place_resources() if env_ready else {
		"ok": false,
		"reason": _env_error,
	}
	var result := place_final_autoobjects() if bool(prepare.get("ok", false)) else prepare
	var wall_ms := float(Time.get_ticks_usec() - t0_usec) / 1000.0
	profile_score_timing = previous_profile
	place_max_batches = previous_max_batches
	var report := result.duplicate(true)
	report["ok"] = bool(result.get("ok", false))
	report["wall_ms"] = wall_ms
	return JSON.stringify(report)


## Measures cold scene bootstrap through resident prefilter and Place pipeline
## readiness. The method leaves the resulting environment alive for a following
## ready-state Place sample, but does not dispatch placement itself.
func benchmark_scene_bootstrap_once_json(max_batches = 3) -> String:
	if not Engine.is_editor_hint():
		return JSON.stringify({"ok": false, "reason": "not_editor_hint"})
	var previous_profile := profile_score_timing
	var previous_max_batches := place_max_batches
	profile_score_timing = false
	place_max_batches = clampi(int(max_batches), 1, 16)
	_dispose_pipeline()
	var t0_usec := Time.get_ticks_usec()
	var env_ready := _ensure_env_ready()
	var prepare := _prepare_ready_place_resources() if env_ready else {
		"ok": false,
		"reason": _env_error,
	}
	var wall_ms := float(Time.get_ticks_usec() - t0_usec) / 1000.0
	var identity := _place_ready_identity() if env_ready else {}
	profile_score_timing = previous_profile
	place_max_batches = previous_max_batches
	return JSON.stringify({
		"ok": env_ready and bool(prepare.get("ok", false)) and bool(identity.get("ready", false)),
		"reason": "ok" if env_ready and bool(prepare.get("ok", false)) else str(prepare.get("reason", _env_error)),
		"wall_ms": wall_ms,
		"env_phases_ms": _last_env_ready_phases_ms.duplicate(true),
		"prepare": prepare,
		"identity": identity,
	})


## Measures Place only after the scene-owned resources are ready. Fixture reset,
## pipeline preparation, and readiness assertions are outside wall_ms.
func benchmark_place_ready_once_json(profile_stages = false, max_batches = 3) -> String:
	if not Engine.is_editor_hint():
		return JSON.stringify({"ok": false, "reason": "not_editor_hint"})
	var previous_profile := profile_score_timing
	var previous_max_batches := place_max_batches
	profile_score_timing = bool(profile_stages)
	place_max_batches = clampi(int(max_batches), 1, 16)
	if not _ensure_env_ready():
		profile_score_timing = previous_profile
		place_max_batches = previous_max_batches
		return JSON.stringify({"ok": false, "reason": _env_error})
	var reset := _reset_place_benchmark_fixture()
	var prepare := _prepare_ready_place_resources() if bool(reset.get("ok", false)) else {
		"ok": false,
		"reason": str(reset.get("reason", "fixture_reset_failed")),
	}
	var identity_before := _place_ready_identity() if bool(prepare.get("ok", false)) else {}
	var guard_t0_usec := Time.get_ticks_usec()
	var guard_ok := _ensure_env_ready()
	var ready_guard_ms := float(Time.get_ticks_usec() - guard_t0_usec) / 1000.0
	var ready_guard_cached := guard_ok and bool(_last_env_ready_phases_ms.get("cached", false))
	var t0_usec := Time.get_ticks_usec()
	var result := place_final_autoobjects() if ready_guard_cached else {
		"ok": false,
		"reason": "ready_guard_not_cached",
	}
	var wall_ms := float(Time.get_ticks_usec() - t0_usec) / 1000.0
	var identity_after := _place_ready_identity()
	var identity_stable := not identity_before.is_empty() and identity_before == identity_after
	profile_score_timing = previous_profile
	place_max_batches = previous_max_batches
	var report := result.duplicate(true)
	report["ok"] = bool(result.get("ok", false)) \
		and bool(reset.get("ok", false)) \
		and bool(prepare.get("ok", false)) \
		and ready_guard_cached \
		and identity_stable
	report["reason"] = "ok" if bool(report["ok"]) else str(result.get("reason", "ready_state_contract_failed"))
	report["wall_ms"] = wall_ms
	report["fixture_reset"] = reset
	report["prepare"] = prepare
	report["ready_guard_ms"] = ready_guard_ms
	report["ready_guard_cached"] = ready_guard_cached
	report["identity_stable"] = identity_stable
	report["identity_before"] = identity_before
	report["identity_after"] = identity_after
	return JSON.stringify(report)


func benchmark_incremental_fine_consistency_json(batch_count = 3) -> String:
	if not Engine.is_editor_hint():
		return JSON.stringify({"ok": false, "reason": "not_editor_hint"})
	if not _ensure_env_ready():
		return JSON.stringify({"ok": false, "reason": _env_error})
	var safe_batch_count := clampi(int(batch_count), 1, 16)
	var incremental := _benchmark_place_sequence_for_consistency(false, safe_batch_count)
	var forced_full := _benchmark_place_sequence_for_consistency(true, safe_batch_count)
	var incremental_records: Array = incremental.get("_canonical_records", [])
	var forced_full_records: Array = forced_full.get("_canonical_records", [])
	var comparison := _compare_canonical_place_records(incremental_records, forced_full_records)
	incremental.erase("_canonical_records")
	forced_full.erase("_canonical_records")
	var incremental_batches: Array = incremental.get("batch_reports", [])
	var forced_full_batches: Array = forced_full.get("batch_reports", [])
	var gpu_buffer_comparison := _compare_incremental_fine_validation_batches(
		incremental_batches, forced_full_batches)
	# incremental_fine_active/cache_hit in batch_reports are informational only:
	# the fine dirty-mask pipeline has been removed (the generator always reports
	# active=false), so consistency rests on canonical records, SHA-256 digests,
	# and the forced-full contract below.
	var forced_full_ready := forced_full_batches.size() == safe_batch_count
	for raw_batch in forced_full_batches:
		var batch: Dictionary = raw_batch
		forced_full_ready = forced_full_ready \
			and not bool(batch.get("incremental_fine_active", true)) \
			and bool(batch.get("incremental_fine_force_full", false))
	var ok := bool(incremental.get("ok", false)) \
		and bool(forced_full.get("ok", false)) \
		and bool(comparison.get("equal", false)) \
		and bool(gpu_buffer_comparison.get("equal", false)) \
		and forced_full_ready
	return JSON.stringify({
		"ok": ok,
		"reason": "ok" if ok else "incremental_fine_consistency_failed",
		"batch_count": safe_batch_count,
		"record_comparison": comparison,
		"gpu_buffer_comparison": gpu_buffer_comparison,
		"forced_full_ready": forced_full_ready,
		"incremental": incremental,
		"forced_full": forced_full,
	})


func benchmark_place_resource_lifecycle_json(batch_count = 60) -> String:
	if not Engine.is_editor_hint():
		return JSON.stringify({"ok": false, "reason": "not_editor_hint"})
	if not _ensure_env_ready():
		return JSON.stringify({"ok": false, "reason": _env_error})
	var reset := _reset_place_benchmark_fixture()
	if not bool(reset.get("ok", false)):
		return JSON.stringify({"ok": false, "reason": str(reset.get("reason", "fixture_reset_failed"))})
	var common := PLACE_PIPELINE_COMMON.duplicate(true)
	common["rotation_slots"] = rotation_slots
	common["min_target_interest"] = min_target_interest
	common["anchor_vertical_stride"] = anchor_vertical_stride
	common["min_prefilter_score"] = min_prefilter_score
	common["result_capacity"] = place_result_capacity
	common["min_distance_voxels"] = place_min_distance_voxels
	common["score_timing_profile"] = false
	var prepare: Dictionary = _env.prepare_place_ready(common)
	if not bool(prepare.get("ok", false)):
		return JSON.stringify({"ok": false, "reason": str(prepare.get("reason", "prepare_failed"))})
	var session: Dictionary = _env.begin_place_session(common)
	if not bool(session.get("ok", false)):
		return JSON.stringify({"ok": false, "reason": str(session.get("reason", "session_begin_failed"))})
	var seeds := PackedFloat32Array()
	var first_summary := {}
	var last_summary := {}
	var max_tracked_total := 0
	var max_frame_count := 0
	var max_pass_count := 0
	var incremental_active_count := 0
	var total_placed := 0
	var safe_batch_count := clampi(int(batch_count), 1, 256)
	for batch_index in range(safe_batch_count):
		var result: Dictionary = _env.run_place_session_batch(seeds)
		if not bool(result.get("ok", false)):
			_env.end_place_session()
			return JSON.stringify({
				"ok": false,
				"reason": str(result.get("reason", "batch_failed")),
				"batch_index": batch_index,
			})
		var placement_result: Dictionary = result.get("placement_result", {})
		var fine_contract: Dictionary = placement_result.get("anchor_fine_contract", {})
		incremental_active_count += 1 if bool(
			fine_contract.get("incremental_fine_active", false)) else 0
		for raw_asset_result in placement_result.get("asset_results", []):
			if not raw_asset_result is Dictionary:
				continue
			var asset_result: Dictionary = raw_asset_result
			var asset_index := int(asset_result.get("asset_index", -1))
			for raw_record in asset_result.get("results", []):
				if not raw_record is Dictionary:
					continue
				var origin: Vector3i = (raw_record as Dictionary).get(
					"voxel_origin", Vector3i.ZERO)
				seeds.append(float(origin.x))
				seeds.append(float(origin.y))
				seeds.append(float(origin.z))
				seeds.append(float(asset_index))
				total_placed += 1
		var resource_summary: Dictionary = _env.get_spa().get_place_resource_lifecycle_summary()
		if batch_index == 0:
			first_summary = resource_summary.duplicate(true)
		last_summary = resource_summary.duplicate(true)
		max_tracked_total = maxi(max_tracked_total, int(resource_summary.get("tracked_total", 0)))
		max_frame_count = maxi(max_frame_count, int(resource_summary.get("frame_count", 0)))
		max_pass_count = maxi(max_pass_count, int(resource_summary.get("pass_count", 0)))
	_env.end_place_session()
	var stable_fields := [
		"tracked_total",
		"tracked_owned",
		"tracked_borrowed",
		"frame_count",
		"pass_count",
		"persistent_count",
		"resident_candidate_valid",
		"resident_candidate_bytes",
		"resident_candidate_initialized",
	]
	var stable := not first_summary.is_empty() and not last_summary.is_empty()
	for field in stable_fields:
		stable = stable and first_summary.get(field) == last_summary.get(field)
	stable = stable \
		and max_tracked_total == int(first_summary.get("tracked_total", -1)) \
		and max_frame_count == 0 \
		and max_pass_count == 0
	return JSON.stringify({
		"ok": stable,
		"reason": "ok" if stable else "placement_resource_lifecycle_growth",
		"batch_count": safe_batch_count,
		"total_placed": total_placed,
		"incremental_active_count": incremental_active_count,
		"first": first_summary,
		"last": last_summary,
		"max_tracked_total": max_tracked_total,
		"max_frame_count": max_frame_count,
		"max_pass_count": max_pass_count,
	})


func _benchmark_place_sequence_for_consistency(force_full: bool, batch_count: int) -> Dictionary:
	var reset := _reset_place_benchmark_fixture()
	if not bool(reset.get("ok", false)):
		return {"ok": false, "reason": str(reset.get("reason", "fixture_reset_failed"))}
	var common := PLACE_PIPELINE_COMMON.duplicate(true)
	common["rotation_slots"] = rotation_slots
	common["min_target_interest"] = min_target_interest
	common["anchor_vertical_stride"] = anchor_vertical_stride
	common["min_prefilter_score"] = min_prefilter_score
	common["result_capacity"] = place_result_capacity
	common["min_distance_voxels"] = place_min_distance_voxels
	common["score_timing_profile"] = false
	common["force_full_place_recompute"] = force_full
	common["validate_incremental_fine_candidates"] = true
	var prepare: Dictionary = _env.prepare_place_ready(common)
	if not bool(prepare.get("ok", false)):
		return {"ok": false, "reason": str(prepare.get("reason", "prepare_failed"))}
	var session: Dictionary = _env.begin_place_session(common)
	if not bool(session.get("ok", false)):
		return {"ok": false, "reason": str(session.get("reason", "session_begin_failed"))}
	var seeds := PackedFloat32Array()
	var canonical_records: Array = []
	var batch_reports: Array = []
	for batch_index in range(batch_count):
		var t0_usec := Time.get_ticks_usec()
		var result: Dictionary = _env.run_place_session_batch(seeds)
		if not bool(result.get("ok", false)):
			_env.end_place_session()
			return {"ok": false, "reason": str(result.get("reason", "batch_failed"))}
		var placement_result: Dictionary = result.get("placement_result", {})
		var fine_contract: Dictionary = placement_result.get("anchor_fine_contract", {})
		var fine_validation: Dictionary = fine_contract.get("incremental_fine_validation", {})
		var batch_record_count := 0
		for raw_asset_result in placement_result.get("asset_results", []):
			if not raw_asset_result is Dictionary:
				continue
			var asset_result: Dictionary = raw_asset_result
			var asset_index := int(asset_result.get("asset_index", -1))
			for raw_record in asset_result.get("results", []):
				if not raw_record is Dictionary:
					continue
				var record: Dictionary = raw_record
				var origin: Vector3i = record.get("voxel_origin", Vector3i.ZERO)
				canonical_records.append([
					batch_index, asset_index,
					origin.x, origin.y, origin.z,
					int(record.get("anchor_id", -1)),
					int(record.get("rotation_index", -1)),
					int(record.get("global_pivot_index", -1)),
					float(record.get("score", 0.0)),
					float(record.get("solid_collision", 0.0)),
					float(record.get("loss_before", 0.0)),
					float(record.get("loss_after", 0.0)),
					float(record.get("clearance_overlap", 0.0)),
				])
				seeds.append(float(origin.x))
				seeds.append(float(origin.y))
				seeds.append(float(origin.z))
				seeds.append(float(asset_index))
				batch_record_count += 1
		batch_reports.append({
			"batch_index": batch_index,
			"wall_ms": float(Time.get_ticks_usec() - t0_usec) / 1000.0,
			"record_count": batch_record_count,
			"incremental_fine_active": bool(fine_contract.get("incremental_fine_active", false)),
			"incremental_fine_cache_hit": bool(fine_contract.get("incremental_fine_cache_hit", false)),
			"incremental_fine_force_full": bool(fine_contract.get("incremental_fine_force_full", false)),
			"anchor_count": int(fine_validation.get("anchor_count", 0)),
			"candidate_record_count": int(fine_validation.get("candidate_record_count", 0)),
			"candidate_sha256": str(fine_validation.get("candidate_sha256", "")),
			"winner_record_count": int(fine_validation.get("winner_record_count", 0)),
			"winner_sha256": str(fine_validation.get("winner_sha256", "")),
			"workload": fine_validation.get("workload", {}),
		})
	_env.end_place_session()
	return {
		"ok": true,
		"force_full": force_full,
		"record_count": canonical_records.size(),
		"batch_reports": batch_reports,
		"_canonical_records": canonical_records,
	}


static func _compare_canonical_place_records(lhs: Array, rhs: Array) -> Dictionary:
	var shared_count := mini(lhs.size(), rhs.size())
	for index in range(shared_count):
		if lhs[index] != rhs[index]:
			return {
				"equal": false,
				"lhs_count": lhs.size(),
				"rhs_count": rhs.size(),
				"first_mismatch_index": index,
				"lhs": lhs[index],
				"rhs": rhs[index],
			}
	return {
		"equal": lhs.size() == rhs.size(),
		"lhs_count": lhs.size(),
		"rhs_count": rhs.size(),
		"first_mismatch_index": -1 if lhs.size() == rhs.size() else shared_count,
	}


static func _compare_incremental_fine_validation_batches(lhs: Array, rhs: Array) -> Dictionary:
	if lhs.size() != rhs.size():
		return {
			"equal": false,
			"lhs_batch_count": lhs.size(),
			"rhs_batch_count": rhs.size(),
			"first_mismatch_batch": mini(lhs.size(), rhs.size()),
		}
	var fields := [
		"anchor_count",
		"candidate_record_count",
		"candidate_sha256",
		"winner_record_count",
		"winner_sha256",
	]
	for batch_index in range(lhs.size()):
		var lhs_batch: Dictionary = lhs[batch_index]
		var rhs_batch: Dictionary = rhs[batch_index]
		if int(lhs_batch.get("anchor_count", 0)) <= 0 \
				or str(lhs_batch.get("candidate_sha256", "")).is_empty() \
				or str(lhs_batch.get("winner_sha256", "")).is_empty():
			return {
				"equal": false,
				"lhs_batch_count": lhs.size(),
				"rhs_batch_count": rhs.size(),
				"first_mismatch_batch": batch_index,
				"field": "validation_payload",
				"lhs": lhs_batch,
			}
		for field in fields:
			if lhs_batch.get(field) != rhs_batch.get(field):
				return {
					"equal": false,
					"lhs_batch_count": lhs.size(),
					"rhs_batch_count": rhs.size(),
					"first_mismatch_batch": batch_index,
					"field": field,
					"lhs": lhs_batch.get(field),
					"rhs": rhs_batch.get(field),
				}
	return {
		"equal": true,
		"lhs_batch_count": lhs.size(),
		"rhs_batch_count": rhs.size(),
		"first_mismatch_batch": -1,
	}


func _prepare_ready_place_resources() -> Dictionary:
	if _env == null:
		return {"ok": false, "reason": "environment_not_ready"}
	var common := PLACE_PIPELINE_COMMON.duplicate(true)
	common["rotation_slots"] = rotation_slots
	common["min_target_interest"] = min_target_interest
	common["anchor_vertical_stride"] = anchor_vertical_stride
	common["min_prefilter_score"] = min_prefilter_score
	common["result_capacity"] = place_result_capacity
	common["min_distance_voxels"] = place_min_distance_voxels
	var t0_usec := Time.get_ticks_usec()
	var result: Dictionary = _env.prepare_place_ready(common)
	result["wall_ms"] = float(Time.get_ticks_usec() - t0_usec) / 1000.0
	return result


func _reset_place_benchmark_fixture() -> Dictionary:
	if _env == null:
		return {"ok": false, "reason": "environment_not_ready"}
	var t0_usec := Time.get_ticks_usec()
	var result: Dictionary = _env.reset_place_fixture()
	if not bool(result.get("ok", false)):
		result["wall_ms"] = float(Time.get_ticks_usec() - t0_usec) / 1000.0
		return result
	_placed_result = {}
	# 累积表的 SSOT 在 SPA（Place 归它跑），fixture 把场清回空就必须让它一起归零。
	var reset_spa := _spa_display_host()
	if reset_spa != null:
		reset_spa.reset_place_accumulation()
	_model = {}
	if _display_root != null and is_instance_valid(_display_root):
		var old := _display_root.get_node_or_null(PLACED_AUTOOBJECTS_NODE_NAME)
		if old != null:
			_display_root.remove_child(old)
			old.queue_free()
	_placed_display = null
	_placed_display_result.clear()
	_update_cull_processing()
	var spa_host := _spa_display_host()
	if spa_host != null and spa_host.has_method("set_autoobject_pick_data"):
		spa_host.call("set_autoobject_pick_data", {})
	result["wall_ms"] = float(Time.get_ticks_usec() - t0_usec) / 1000.0
	return result


func _place_ready_identity() -> Dictionary:
	if _env == null or not _env.is_ready():
		return {}
	var spa = _env.get_spa()
	var committer = _env.get_committer()
	if spa == null or committer == null:
		return {}
	var rd = committer.get_rendering_device()
	var profile_container = spa.get_runtime_profile_container()
	var runtime = spa.get_gpu_runtime()
	var target: Dictionary = _env.ensure_target_ready()
	var target_field: RID = target.get("target_field_buffer", RID())
	var target_collision: RID = target.get("target_collision_buffer", RID())
	# 阶段 B：Header/Samples/Pivots/MeshDescription 已收敛为单一固定槽位 Arena。
	var profile_arena: RID = spa.get_profile_arena_buffer()
	var runtime_alive: RID = runtime.get_gpu_buffer("alive") if runtime != null else RID()
	var pipeline: Dictionary = spa.get_place_pipeline_readiness()
	var spa_host := _spa_display_host()
	var host_identity: Dictionary = spa_host.get_identity_report() if spa_host != null else {}
	var host_spa_matches: bool = spa_host != null and spa_host == spa \
		and int(host_identity.get("spa_instance_id", 0)) == spa.get_instance_id()
	var ready: bool = (
		rd != null
		and profile_container != null
		and target_field.is_valid()
		and target_collision.is_valid()
		and profile_arena.is_valid()
		and runtime_alive.is_valid()
		and bool(pipeline.get("ok", false))
		and host_spa_matches
	)
	return {
		"ready": ready,
		"scene_owned_spa": host_spa_matches,
		"core_spa_host_instance_id": spa_host.get_instance_id() if spa_host != null else 0,
		"scene_owned_environment_make_count": int(host_identity.get("make_count", -1)),
		"scene_owned_environment_dispose_count": int(host_identity.get("dispose_count", -1)),
		"env_instance_id": _env.get_instance_id(),
		"spa_instance_id": spa.get_instance_id(),
		"committer_instance_id": committer.get_instance_id(),
		"rendering_device_instance_id": rd.get_instance_id() if rd != null else 0,
		"profile_container_instance_id": profile_container.get_instance_id() if profile_container != null else 0,
		"runtime_instance_id": runtime.get_instance_id() if runtime != null else 0,
		"profile_arena_rid": str(profile_arena),
		"target_field_rid": str(target_field),
		"target_collision_rid": str(target_collision),
		"runtime_alive_rid": str(runtime_alive),
		"target_revision": int(target.get("target_revision", -1)),
		"place_pipeline_ready": bool(pipeline.get("placement_pipeline_ready", false)),
	}


## 编辑器桥性能入口：预热后重复运行真实 S6 prefilter，返回可机器解析的 JSON。
## Score / Place 都按单次全图；两者只在 anchor 位置是否回读上有差异。
func benchmark_anchor_prefilter_timing_json(sample_count = 7, warmup_count = 2) -> String:
	return JSON.stringify(benchmark_anchor_prefilter_timing(int(sample_count), int(warmup_count)))


func benchmark_anchor_prefilter_timing(sample_count := 7, warmup_count := 2) -> Dictionary:
	if not Engine.is_editor_hint():
		return {"ok": false, "reason": "not_editor_hint"}
	if not _ensure_env_ready():
		return {"ok": false, "reason": _env_error}
	var sv := _committed_sv_metadata()
	var grid_size: Vector3i = sv.get("grid_size", Vector3i.ZERO)
	var tile_grid: Vector3i = sv.get("tile_grid_size", Vector3i.ZERO)
	if tile_grid.x <= 0 or tile_grid.y <= 0 or tile_grid.z <= 0:
		return {"ok": false, "reason": "invalid_tile_grid"}

	sample_count = clampi(sample_count, 1, 50)
	warmup_count = clampi(warmup_count, 0, 10)
	var full_rect := Rect2i(0, 0, tile_grid.x, tile_grid.z)
	var scenarios: Array[Dictionary] = [
		{
			"name": "score_full_map_readback",
			"regions": _full_map_region_rects(),
			"debug_read_anchors": true,
		},
		{
			"name": "place_full_map_resident",
			"regions": [full_rect],
			"debug_read_anchors": false,
		},
	]
	var scenario_reports: Array[Dictionary] = []
	for scenario in scenarios:
		var measured_samples: Array[Dictionary] = []
		var run_count := warmup_count + sample_count
		for run_index in range(run_count):
			var sample := _benchmark_anchor_scenario_once(scenario)
			if not bool(sample.get("ok", false)):
				_env.invalidate_prefilter_cache()
				return {
					"ok": false,
					"reason": str(sample.get("reason", "anchor_benchmark_failed")),
					"scenario": str(scenario.get("name", "unknown")),
					"run_index": run_index,
				}
			if run_index >= warmup_count:
				measured_samples.append(sample)
		var summarized := _summarize_anchor_timing_samples(measured_samples)
		summarized["name"] = str(scenario.get("name", "unknown"))
		summarized["region_count"] = (scenario.get("regions", []) as Array).size()
		summarized["debug_read_anchors"] = bool(scenario.get("debug_read_anchors", false))
		scenario_reports.append(summarized)

	# Drop the benchmark cache so the next interactive call reapplies normal settings;
	# ScenePlacementActor resets profile_timing=false when the key is absent.
	_env.invalidate_prefilter_cache()
	return {
		"ok": true,
		"sample_count": sample_count,
		"warmup_count": warmup_count,
		"grid_size": [grid_size.x, grid_size.y, grid_size.z],
		"tile_grid_size": [tile_grid.x, tile_grid.y, tile_grid.z],
		"asset_count": _assets.size(),
		"gpu_name": RenderingServer.get_video_adapter_name(),
		"gpu_vendor": RenderingServer.get_video_adapter_vendor(),
		"scenarios": scenario_reports,
		"measurement_note": "Each profiled GPU stage includes one submit+sync boundary; target buffers stay resident across samples",
	}


func _benchmark_anchor_scenario_once(scenario: Dictionary) -> Dictionary:
	var combined_phases := {}
	var total_usec := 0
	var anchor_count := 0
	var tile_count := 0
	var collect_cache_hits := 0
	var regions: Array = scenario.get("regions", [])
	for raw_region in regions:
		var region: Rect2i = raw_region
		_env.invalidate_prefilter_cache()
		_mark_prefilter_region_dirty(region)
		var result: Dictionary = _env.ensure_prefilter({
			"min_target_interest": min_target_interest,
			"anchor_vertical_stride": anchor_vertical_stride,
			"min_prefilter_score": min_prefilter_score,
			"debug_read_anchors": bool(scenario.get("debug_read_anchors", false)),
			"decode_anchor_dictionaries": false,
			"profile_timing": true,
		})
		if not bool(result.get("ok", false)):
			return {"ok": false, "reason": str(result.get("prefilter_reason", result.get("reason", "prefilter_failed")))}
		var timing: Dictionary = result.get("anchor_timing_profile", {})
		if timing.is_empty():
			return {"ok": false, "reason": "missing_anchor_timing_profile"}
		total_usec += int(timing.get("total_usec", 0))
		anchor_count += int(timing.get("anchor_count", 0))
		tile_count += int(timing.get("tile_count", 0))
		if bool(timing.get("collect_cache_hit", false)):
			collect_cache_hits += 1
		var phases: Dictionary = timing.get("phases_by_name", {})
		for phase_name in phases:
			combined_phases[phase_name] = int(combined_phases.get(phase_name, 0)) + int(phases[phase_name])
	return {
		"ok": true,
		"total_usec": total_usec,
		"anchor_count": anchor_count,
		"tile_count": tile_count,
		"collect_cache_hits": collect_cache_hits,
		"collect_runs": regions.size(),
		"phases_by_name": combined_phases,
	}


static func _summarize_anchor_timing_samples(samples: Array[Dictionary]) -> Dictionary:
	var total_values: Array[int] = []
	var anchor_values: Array[int] = []
	var phase_values := {}
	var tile_count := 0
	var collect_cache_hits := 0
	var collect_runs := 0
	for sample in samples:
		total_values.append(int(sample.get("total_usec", 0)))
		anchor_values.append(int(sample.get("anchor_count", 0)))
		tile_count = int(sample.get("tile_count", tile_count))
		collect_cache_hits += int(sample.get("collect_cache_hits", 0))
		collect_runs += int(sample.get("collect_runs", 0))
		var phases: Dictionary = sample.get("phases_by_name", {})
		for phase_name in phases:
			if not phase_values.has(phase_name):
				phase_values[phase_name] = []
			(phase_values[phase_name] as Array).append(int(phases[phase_name]))
	var phase_stats := {}
	for phase_name in phase_values:
		phase_stats[phase_name] = _timing_stats_ms(phase_values[phase_name])
	return {
		"total_ms": _timing_stats_ms(total_values),
		"anchor_count": _integer_stats(anchor_values),
		"tile_count": tile_count,
		"collect_cache_hits": collect_cache_hits,
		"collect_runs": collect_runs,
		"collect_cache_hit_rate": float(collect_cache_hits) / float(maxi(collect_runs, 1)),
		"phases_ms": phase_stats,
		"raw_total_ms": _usec_values_to_ms(total_values),
	}


static func _timing_stats_ms(values: Array) -> Dictionary:
	if values.is_empty():
		return {}
	var sorted := values.duplicate()
	sorted.sort()
	var sum_usec := 0
	for value in sorted:
		sum_usec += int(value)
	var p50_index := clampi(int(ceili(float(sorted.size()) * 0.50)) - 1, 0, sorted.size() - 1)
	var p95_index := clampi(int(ceili(float(sorted.size()) * 0.95)) - 1, 0, sorted.size() - 1)
	return {
		"min": float(int(sorted[0])) / 1000.0,
		"mean": float(sum_usec) / float(sorted.size()) / 1000.0,
		"p50": float(int(sorted[p50_index])) / 1000.0,
		"p95": float(int(sorted[p95_index])) / 1000.0,
		"max": float(int(sorted[sorted.size() - 1])) / 1000.0,
	}


static func _integer_stats(values: Array[int]) -> Dictionary:
	if values.is_empty():
		return {}
	var sorted := values.duplicate()
	sorted.sort()
	var total := 0
	for value in sorted:
		total += value
	return {
		"min": sorted[0],
		"mean": float(total) / float(sorted.size()),
		"max": sorted[sorted.size() - 1],
	}


static func _usec_values_to_ms(values: Array[int]) -> Array[float]:
	var out: Array[float] = []
	for value in values:
		out.append(float(value) / 1000.0)
	return out


# ---- Place（流程收尾步：真实提交 S8 + commit S9）----------------------------

## 整条流程收尾：跑 env 全链一轮（run_pipeline_once，S5→S9）——真实 prefilter + score +
## stamp + GPU 常驻 writeback（spawn 真实 AutoObject）+ commit（改写 committed SV）。随后
## 回读活对象态、按各自 descriptor 真实 mesh 实例化渲染实际放置结果（GPU_OBJECTS 显示组，
## AutoObject/Mixed 模式可见；与 Anchor 组的评分预览分离，可按模式独立观察）。
## 冻结名（SPA run_place → provider.call("place_final_autoobjects") → 此方法）。
## ⚠ Place 改写了 committed SV：再次 Score 会在新场上重评（run_pipeline_once 已失效 env 缓存，
## coherent）。门限（rotation_slots / min_target_interest / min_prefilter_score）与 Anchors/Score
## 同导出、评分 shader 同源。每批先保留各 Anchor 的最佳 Fine 候选，再按稳定 random 优先级
## 原子失效 Anchor 间冲突并提交至多 `place_result_capacity` 个；Score 展示的是冲突裁决前的
## per-Anchor Fine 胜者。单轮 Reduce 不保证把可用空间填满。
## 单次全图 prefilter（run_pipeline_once 恒 dirty_tile_ids=[]，与 Anchors/Score 同口径）。collect
## 在地形高度采样目标体积发锚（anchor_vertical_stride 决定地表之上再叠几层），上限 ANCHOR_CAPACITY=131072；
## raw count 超限属于不变量错误并终止。
func place_final_autoobjects() -> Dictionary:
	if not Engine.is_editor_hint():
		return {"ok": false, "reason": "not_editor_hint"}
	var spa := _spa_display_host()
	if spa == null:
		return {"ok": false, "reason": "ancestor_scene_placement_actor_unavailable"}
	# ⚠ 本方法后面要用 _env 做对象态回读（_readback_object_states）。放置本身走 SPA、
	# 不碰 _env，所以单独调用 Place（不先经过任何评分入口）时 _env 是 null——
	# 回读拿不到东西 ⇒ 渲染 0 个实例、推 0 条 pick 数据，而 spawned 照报几百个。
	# 依赖 _env 的是本方法，就由本方法保证它就绪，别指望调用顺序。
	if not _ensure_env_ready():
		return {"ok": false, "reason": "placement_stage_env_unavailable:%s" % _env_error}
	var place_t0_usec := Time.get_ticks_usec()
	var place_phases_ms := {}
	var phase_t0_usec := place_t0_usec
	var result := spa.run_place()
	place_phases_ms["spa_run_place"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	if not bool(result.get("ok", false)):
		_placed_result = result
		_update_hud()
		return _placed_result
	# Place 换了场 ⇒ 上一轮评分模型作废。同步回本地镜像，别让旧模型继续喂显示。
	_sync_model_from_spa()
	phase_t0_usec = Time.get_ticks_usec()
	var states := _readback_object_states(spa.get_placed_object_ids())
	place_phases_ms["readback_object_states"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	phase_t0_usec = Time.get_ticks_usec()
	states = _terrain_rebase_object_states(states)
	place_phases_ms["rebase_object_states"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	phase_t0_usec = Time.get_ticks_usec()
	var rendered := _sync_placed_instances_gpu(_active_cull_camera_position())
	place_phases_ms["build_render_instances"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	phase_t0_usec = Time.get_ticks_usec()
	_push_placed_pick_data_to_spa(states)
	place_phases_ms["push_pick_data"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	_placed_result = result.duplicate(true)
	_placed_result["rendered"] = rendered
	phase_t0_usec = Time.get_ticks_usec()
	_frame_camera_on_placed(states)
	place_phases_ms["frame_camera"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	print("[VolumeScore] Place -> spawned=%d in %d batch(es), rendered_total=%d (committed SV modified)" % [
		int(result.get("spawned", 0)), int(result.get("batches", 0)), rendered])
	phase_t0_usec = Time.get_ticks_usec()
	_update_hud()
	place_phases_ms["update_hud"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	_placed_result["place_phases_ms"] = place_phases_ms
	_placed_result["wall_ms"] = float(Time.get_ticks_usec() - place_t0_usec) / 1000.0
	return _placed_result


## Place 后把 demo FlyCamera 框到放置簇上（放置 mesh 是原生 FBX 尺度——草 ~2u——在 1024u
## 地形的默认远机位下只有几个像素；不框过去用户会以为"什么都没发生"）。相机归用户所有，
## demo 初始化本就摆相机（DemoUI 惯例），此处只在 Place 动作后重新取景一次。
func _frame_camera_on_placed(states: Array) -> void:
	var center := Vector3.ZERO
	var count := 0
	var bound_min := Vector3(INF, INF, INF)
	var bound_max := Vector3(-INF, -INF, -INF)
	for state in states:
		if not (state is Dictionary) or not bool((state as Dictionary).get("alive", false)):
			continue
		var pos := ((state as Dictionary).get("transform", Transform3D.IDENTITY) as Transform3D).origin
		center += pos
		bound_min = bound_min.min(pos)
		bound_max = bound_max.max(pos)
		count += 1
	if count <= 0:
		return
	var cam := DemoUI.find_camera(self, "", "FlyCamera", false, true)
	if cam == null:
		return
	center /= float(count)
	var radius := maxf((bound_max - bound_min).length() * 0.5, 10.0)
	var distance := clampf(radius * 2.2, 30.0, 600.0)
	cam.global_position = center + Vector3(0.55, 0.75, 0.55).normalized() * distance
	cam.look_at(center, Vector3.UP)


## 把 Place 的回读对象态转成 SPA 宿主的 autoobject pick 数据（AutoObject 模式 LMB 点选
## 放置结果；side_count=0 → host 屏幕空间最近邻拾取，对齐 spa_interactive_demo
## ._push_autoobject_pick_data_from_states）。
func _push_placed_pick_data_to_spa(states: Array) -> void:
	var spa := _spa_display_host()
	if spa == null or not spa.has_method("set_autoobject_pick_data") or _env == null:
		return
	var profile_ids: Array[int] = _env.get_profile_ids()
	var positions: Array[Vector3] = []
	var asset_indices: Array[int] = []
	var object_ids: Array[int] = []
	var voxel_mins: Array[Vector3i] = []
	for state in states:
		if not (state is Dictionary) or not bool((state as Dictionary).get("alive", false)):
			continue
		var record := state as Dictionary
		positions.append((record.get("transform", Transform3D.IDENTITY) as Transform3D).origin)
		asset_indices.append(maxi(profile_ids.find(int(record.get("profile_id", -1))), 0))
		object_ids.append(int(record.get("object_id", -1)))
		voxel_mins.append(record.get("voxel_min", Vector3i.ZERO))
	var asset_names: Array[String] = []
	for name in _asset_names():
		asset_names.append(str(name))
	spa.call("set_autoobject_pick_data", {
		"runtime_ready": not positions.is_empty(),
		"positions": positions,
		"asset_indices": asset_indices,
		"object_ids": object_ids,
		"voxel_mins": voxel_mins,
		"side_count": 0,
		"spacing_voxels": 1,
		"profile_ids": profile_ids,
		"asset_names": asset_names,
	})


## 回读活对象态（GPU storage buffer readback）。走 runtime 批量口
## readback_object_states_bulk（每缓冲整读一次）——逐 id 调试口在数千对象规模下
## 是几万次同步回读，不可用。
func _readback_object_states(object_ids: Array[int]) -> Array:
	# 没有要读的对象 = 合法的空，静默返回。
	if object_ids.is_empty():
		return []
	# 以下每一条都是"被要求回读 N 个对象却读不了"，属于硬失败。
	#
	# ⚠ 原实现四条全部静默 return []：调用方（Place 收尾）拿到空数组后照常继续，
	# 渲染 0 个实例、推 0 条 pick 数据，而 place 报告里的 spawned 仍是几百——
	# 表现成"放置成功但场上什么都没有"，整条链一条日志都没有。这不是防御，是把
	# 一个确定的失败伪装成一个正常的空结果。
	if _env == null:
		push_error("[VolumeScore] _readback_object_states: _env 缺失，%d 个对象无法回读。" % object_ids.size())
		assert(false, "VolumeScoreDemo._readback_object_states: env missing")
		return []
	var spa = _env.get_spa()
	if spa == null:
		push_error("[VolumeScore] _readback_object_states: env 没有 SPA，%d 个对象无法回读。" % object_ids.size())
		assert(false, "VolumeScoreDemo._readback_object_states: spa missing")
		return []
	var runtime = spa.get_gpu_runtime()
	if runtime == null:
		push_error("[VolumeScore] _readback_object_states: SPA 无 GPU AutoObject runtime，%d 个对象无法回读。" % object_ids.size())
		assert(false, "VolumeScoreDemo._readback_object_states: gpu runtime missing")
		return []
	if not runtime.is_ready():
		var reason := str(runtime.get_not_ready_reason()) if runtime.has_method("get_not_ready_reason") else "unknown"
		push_error("[VolumeScore] _readback_object_states: GPU AutoObject runtime 未就绪（%s），%d 个对象无法回读 —— 放置的 alive/transform 缓冲同样不会被写入。" % [
			reason, object_ids.size()])
		assert(false, "VolumeScoreDemo._readback_object_states: gpu runtime not ready")
		return []
	return runtime.readback_object_states_bulk(object_ids)


## GPU runtime transform 为 flat 口径（Y 不含地形）；TargetSV height_relative → 观察层重基
## （Y += 该 XZ 列地形高度，与 anchor / winner mesh 的 terrain-relative 口径一致）。
## 对齐 spa_interactive_demo._terrain_rebase_object_states；高度场缺失时 no-op。
func _terrain_rebase_object_states(states: Array) -> Array:
	if _env == null:
		return states
	var heights: PackedFloat32Array = _env.get_terrain_height_field()
	if heights.is_empty():
		return states
	var grid: Vector3i = _env.get_grid_size()
	var origin: Vector3 = _env.get_grid_origin()
	var voxel: Vector3 = _env.get_voxel_size()
	for state in states:
		if not (state is Dictionary):
			continue
		var record := state as Dictionary
		var t: Transform3D = record.get("transform", Transform3D.IDENTITY)
		var vx := clampi(int(floorf((t.origin.x - origin.x) / maxf(voxel.x, 0.0001))), 0, grid.x - 1)
		var vz := clampi(int(floorf((t.origin.z - origin.z) / maxf(voxel.z, 0.0001))), 0, grid.z - 1)
		var height_index := vz * grid.x + vx
		if height_index >= 0 and height_index < heights.size():
			t.origin.y += heights[height_index]
			record["transform"] = t
	return states


## 放置结果的 **GPU 直提渲染**：`shaders/autoobject_emit_instances.glsl` 从 SPA 的常驻对象池
## （alive / transform / profile / asset_index / flags）直接写出 MultiMesh 形状的
## `instance_render[]`，`PlacedInstanceDisplay` 只做一次不透明的整块字节搬运——GDScript
## 不解码 mat4、不打包 float、不按 profile_id 分组。
##
## 取代的旧路径：`_readback_object_states` → CPU 地形 rebase → 按 profile_id 分组 →
## `_pack_multimesh_transforms` 逐实例打 12 float。回读那一步现在只剩点选数据要用
## （UnifiedPickGPU 的 BIT_AUTOOBJECT 域尚未接线）与 Place 后的相机取景。
##
## 视距剔除交给 emit（`cull_distance` → 被剔实例写零基向量），**不进 `_cull_groups`**：
## CPU 那条路会调 `set_instance_transform()`，一次就把 MultiMesh 拉回 CPU 缓冲并静默
## 清零全部 GPU 写入的实例。
##
## 渲染进 display_root 的 PlacedAutoObjects 节点、注册到 GPU_OBJECTS 显示组
## （AutoObject/Mixed 模式可见）。无 mesh 的资产由 PlacedInstanceDisplay 丢批 +
## push_warning，绝不代理盒（CLAUDE.md）。
func _sync_placed_instances_gpu(cam_pos := Vector3(INF, INF, INF), force := false) -> int:
	var display := _ensure_placed_display()
	if display == null:
		_placed_display_result = {"ok": false, "reason": "placed_display_unavailable"}
		return 0
	var spa := _spa_display_host()
	if spa == null:
		_placed_display_result = {"ok": false, "reason": "spa_display_host_unavailable"}
		return 0
	var options: Dictionary = {}
	if force:
		options["force"] = true
	if cull_models_by_distance and cam_pos.x != INF:
		options["camera_position"] = cam_pos
		options["cull_distance"] = model_cull_distance
		options["camera_move_epsilon"] = model_cull_recompute_move
	if _env != null:
		var heights: PackedFloat32Array = _env.get_terrain_height_field()
		if not heights.is_empty():
			options["terrain_heights"] = heights
			options["terrain_key"] = "volume_score_demo:%d:%d" % [heights.size(), hash(heights)]
	_placed_display_result = display.sync_from_spa(spa, options)
	if not bool(_placed_display_result.get("ok", false)):
		push_warning("[VolumeScore] 放置实例 GPU 直提失败（%s）——场上不会出现放置物体。" % str(
			_placed_display_result.get("reason", "unknown")))
		return 0
	return int(_placed_display_result.get("instances", 0))


## 显示器节点惰性建立；建成后要让 _process 跑起来（视距剔除的重 emit 由它驱动）。
func _ensure_placed_display() -> Node3D:
	if _placed_display != null and is_instance_valid(_placed_display) and _placed_display.is_inside_tree():
		return _placed_display
	_ensure_display_root()   # 自挂在本节点下，父子关系由它保证
	var old := _display_root.get_node_or_null(PLACED_AUTOOBJECTS_NODE_NAME)
	if old != null:
		# 先摘下再 free：queue_free 挂起期内旧节点仍占名，同帧新建同名节点会被
		# 自动改名（@Node3D@N）→ 下轮按名清理漏掉、节点积累。
		_display_root.remove_child(old)
		old.queue_free()
	var display: Node3D = PlacedInstanceDisplayScript.new()
	display.name = PLACED_AUTOOBJECTS_NODE_NAME
	_display_root.add_child(display)
	_placed_display = display
	_register_spa_voxel_display_node(VOXEL_DISPLAY_GPU_OBJECTS, display)
	_update_cull_processing()
	return _placed_display


func _has_placed_gpu_display() -> bool:
	return _placed_display != null and is_instance_valid(_placed_display) and _placed_display.is_inside_tree()


## 放置批的重 emit（相机移动 ⇒ 剔除集合变化）。renderer 自带相机位移守卫，相机没真动时
## 这里空转到底：不 dispatch、不回读、不上传。
##
## ⚠ `force` 不能省：renderer 的空转守卫看的是 `_object_revision` + 相机位移，而
## `cull_models_by_distance` / `model_cull_distance` 变化两者都不动——不强制的话，关掉剔除
## 或调大距离在放置批上**完全没有反应**（被剔的实例继续保持零基向量）。
func _refresh_placed_gpu_cull(cam_pos: Vector3, force := false) -> void:
	if not _has_placed_gpu_display() or cam_pos.x == INF:
		return
	_sync_placed_instances_gpu(cam_pos, force)


## Golden-master 消费链入口：跑固定评分管线并返回确定性文本快照 v2。
## 桥调用：call_method path=SPA/Volumes/VolumeScore method=run_golden_snapshot —— tools/golden_snapshot_check.js。
## 输入 = 真实 S6 锚点（prefilter_tile_rect 区域内 target-inside 体素，按线性体素索引排序）+
## BlendSV 副本评分（复跑幂等）。锚点段截前 golden_anchor_limit 个（meta 可审计）。
func run_golden_snapshot() -> String:
	if not Engine.is_editor_hint():
		return "ERROR not_editor_hint"
	return _run_golden_snapshot_contract()


## Test-only implementation seam. The editor bridge keeps using
## run_golden_snapshot(); standalone contract runners may call this on a node
## attached beneath a real scene-resident SPA without creating a second owner.
func _run_golden_snapshot_contract() -> String:
	if not _ensure_env_ready():
		return "ERROR env_not_ready reason=%s" % _env_error
	# golden 单次跑完整 256x256 XZ 图；锚点按地形高度采样发出，上限 131072。
	# GPU atomic 追加序不稳定，因此快照前仍按线性体素索引重排，保证跨会话确定。
	# 强制 _full_map_region_rects()（不读交互导出）；meta tile_rect=0,0,0x0 表示全图。
	# 锚点段仍按 golden_anchor_limit 截取排序序前 N（输出采样，计算是全量的）。
	var status := run_volume_score_pipeline(_full_map_region_rects(), true, false, true)
	if not bool(status.get("ok", false)):
		return "ERROR pipeline_not_ok anchors=%d scored=%s reason=%s" % [
			int(status.get("anchors", 0)), str(status.get("scored", false)), str(status.get("reason", ""))]
	_ensure_anchor_cpu_model()   # golden 逐锚点输出，必须先把 CPU 锚点数组物化
	return FineSelection.golden_snapshot_text(_model, _asset_names(), {
		"rotation_slots": rotation_slots,
		"min_target_interest": min_target_interest,
		"min_prefilter_score": min_prefilter_score,
		"prefilter_tile_rect": Rect2i(),
		"golden_anchor_limit": golden_anchor_limit,
	})


# ---- Data source for SPA-owned pick ---------------------------------------
# SPA 用这些数据做射线点选（胜出物体 AABB 优先，锚点小球回退），点中后调 select_anchor。

## 桥诊断：放置实例的位置对账。回答的是一个**二选一**问题——"物体画错地方了"到底是
## 渲染路径把位置搬歪了，还是常驻 transform 本身就在那儿（即放置/pivot 真的错了）。
##
## 对同一批对象同时取四个量：
##   resident        常驻 transform 原点（`placement_results_to_world.glsl` 写的，flat Y）
##   cpu_rebased     旧 CPU 渲染路径的结果（resident + CPU 地形重基）
##   gpu_emitted     emit kernel 写进 instance_render/instance_pick 的原点（今天画出来的）
##   nearest_anchor  最近的 anchor 世界位置与距离
##
## 判据（**这是本函数存在的全部理由**）：
##   `max_gpu_vs_cpu` ≈ 0  ⇒ 渲染忠实，两条路等价；偏移在放置链上游，与渲染无关。
##   `max_gpu_vs_cpu` 显著 ⇒ 渲染路径引入的，查 emit 的地形重基/列采样。
## `anchor_distance` 与 `resident` 的关系则单独回答 pivot：它只反映
## `world_origin = anchor_world - basis * pivot` 那一步，与渲染路径无关。
func debug_placed_instance_alignment(limit: int = 8) -> String:
	var spa := _spa_display_host()
	if spa == null:
		return "ERROR spa_display_host_unavailable"
	var runtime = spa.get_gpu_runtime()
	if runtime == null or not runtime.has_method("get_instance_renderer"):
		return "ERROR gpu_runtime_unavailable"
	var renderer = runtime.get_instance_renderer()
	if renderer == null:
		return "ERROR instance_renderer_unavailable"
	var object_ids: Array[int] = spa.get_placed_object_ids()
	if object_ids.is_empty():
		return "ERROR no_placed_objects (run Place first)"

	# (a) 常驻 + (b) 旧 CPU 路径：先取原始，再单独重基一份副本，两者都要留住。
	var raw_states := _readback_object_states(object_ids)
	var resident_by_id: Dictionary = {}
	for state in raw_states:
		if state is Dictionary and bool((state as Dictionary).get("alive", false)):
			resident_by_id[int((state as Dictionary).get("object_id", -1))] = \
				((state as Dictionary).get("transform", Transform3D.IDENTITY) as Transform3D).origin
	var rebased_by_id: Dictionary = {}
	for state in _terrain_rebase_object_states(_readback_object_states(object_ids)):
		if state is Dictionary and bool((state as Dictionary).get("alive", false)):
			rebased_by_id[int((state as Dictionary).get("object_id", -1))] = \
				((state as Dictionary).get("transform", Transform3D.IDENTITY) as Transform3D).origin

	# (c) GPU：扫 instance_pick，按 object_id 建表（slot 序 ≠ object_id 序）。
	var live := int(renderer.readback_live_count())
	var gpu_by_id: Dictionary = {}
	var gpu_flags_by_id: Dictionary = {}
	for slot in range(maxi(live, 0)):
		var record: Dictionary = renderer.readback_pick_record(slot)
		if record.is_empty():
			continue
		var row0: Array = record.get("row0", [0.0, 0.0, 0.0, 0.0])
		var row1: Array = record.get("row1", [0.0, 0.0, 0.0, 0.0])
		var row2: Array = record.get("row2", [0.0, 0.0, 0.0, 0.0])
		gpu_by_id[int(record.get("object_id", -1))] = Vector3(
			float(row0[3]), float(row1[3]), float(row2[3]))
		gpu_flags_by_id[int(record.get("object_id", -1))] = int(record.get("flags", 0))

	# (d) anchor：只取世界位置做最近邻，不动评分状态。
	var anchors := _anchor_world_positions()

	var lines: Array[String] = []
	var max_gpu_vs_cpu := 0.0
	var max_rebase_lift := 0.0
	var sum_anchor_distance := 0.0
	var counted := 0
	for object_id in object_ids:
		if not resident_by_id.has(object_id) or not gpu_by_id.has(object_id):
			continue
		var resident: Vector3 = resident_by_id[object_id]
		var cpu: Vector3 = rebased_by_id.get(object_id, resident)
		var gpu: Vector3 = gpu_by_id[object_id]
		max_gpu_vs_cpu = maxf(max_gpu_vs_cpu, gpu.distance_to(cpu))
		max_rebase_lift = maxf(max_rebase_lift, absf(cpu.y - resident.y))
		var nearest := Vector3.ZERO
		var nearest_distance := INF
		for anchor in anchors:
			var d := (anchor as Vector3).distance_to(gpu)
			if d < nearest_distance:
				nearest_distance = d
				nearest = anchor
		if nearest_distance < INF:
			sum_anchor_distance += nearest_distance
			counted += 1
		if lines.size() < maxi(limit, 0):
			lines.append("id=%d resident=%s cpu_rebased=%s gpu_emitted=%s |gpu-cpu|=%.6f nearest_anchor=%s dist=%.3f flags=%d" % [
				object_id, str(resident), str(cpu), str(gpu),
				gpu.distance_to(cpu), str(nearest), nearest_distance,
				int(gpu_flags_by_id.get(object_id, 0))])

	var verdict := "RENDER_FAITHFUL (gpu==cpu; 偏移不在渲染路径上)" if max_gpu_vs_cpu <= 0.001 \
		else "RENDER_DIVERGENT (gpu!=cpu; 偏移由渲染路径引入)"
	return "\n".join([
		"verdict=%s" % verdict,
		"placed=%d live_emitted=%d matched=%d anchors=%d" % [object_ids.size(), live, counted, anchors.size()],
		"max_gpu_vs_cpu=%.6f  max_terrain_rebase_lift=%.3f  avg_nearest_anchor_distance=%.3f" % [
			max_gpu_vs_cpu, max_rebase_lift,
			(sum_anchor_distance / float(maxi(counted, 1)))],
		"terrain: emit_resident=%s res=%d | env_field=%d" % [
			str(renderer.get_status_report().get("terrain_resident", false)),
			int(renderer.get_status_report().get("terrain_resolution", 0)),
			(_env.get_terrain_height_field().size() if _env != null else -1)],
	] + lines)


## 桥诊断：「槽位即身份」不变量的在仓复验。判据与实现见
## `scripts/checks/slot_identity_check.gd`；本方法只负责把 emit 真的驱动起来。
##
## 桥调用：call_method path=SPA/Volumes/VolumeScore method=debug_slot_identity_stability
## —— **必须先 Place**，场上没有放置对象时 0 个槽位的比对是空洞的绿。
##
## 三轮 emit 走两个相机位置（近 → 远 → 回到近）。换相机是刻意的：它让剔除集合在轮间
## 真的变化，而"剔除不得改变槽位归属"正是被验的那半句；三轮里的第三轮回到起点，
## 顺带排除"置换只是跟着相机单调漂移"。`force=true` 不能省 —— renderer 的 revision +
## 相机位移守卫会让不强制的重复调用直接空转，那样三轮读的是同一份 GPU 输出，恒等于通过。
func debug_slot_identity_stability() -> String:
	var spa := _spa_display_host()
	if spa == null:
		return "ERROR spa_display_host_unavailable"
	var runtime = spa.get_gpu_runtime()
	if runtime == null or not runtime.has_method("get_instance_renderer"):
		return "ERROR gpu_runtime_unavailable"
	var renderer = runtime.get_instance_renderer()
	if renderer == null:
		return "ERROR instance_renderer_unavailable"
	if not _has_placed_gpu_display():
		return "ERROR no_placed_display (run Place first)"
	if not cull_models_by_distance:
		return "ERROR cull_models_by_distance_off (剔除关掉后各轮输入相同，验不到相机窗口)"
	var near_camera := _active_cull_camera_position()
	if near_camera.x == INF:
		return "ERROR no_cull_camera"
	# 远机位要真的跨过 model_cull_distance，否则两轮的剔除集合可能一模一样（报告里
	# cull_varied=false 会把这种情况标成 WEAK，但先在这里就把它拉开更省事）。
	var far_camera := near_camera + Vector3(1.0, 0.35, 1.0).normalized() * (model_cull_distance * 1.5)
	var result: Dictionary = SlotIdentityCheck.run_rounds(
		renderer,
		func(camera: Vector3) -> void: _sync_placed_instances_gpu(camera, true),
		[near_camera, far_camera, near_camera])
	# 复验会把 emit 停在最后一轮的相机上；恢复成当前真实机位，别让诊断改变场上状态。
	_sync_placed_instances_gpu(near_camera, true)
	return SlotIdentityCheck.format_report(result)


## 桥诊断：pivot 链对账。`debug_placed_instance_alignment` 判定"不是渲染问题"之后，
## 这一条回答"那 pivot 错在哪"。
##
## `placement_results_to_world.glsl` 算的是 `origin = anchor_world - basis * pivot`。
## 于是「网格体坐在 anchor 上」要求 pivot 指向**网格体的底部**，即 `pivot.y ≈ mesh_aabb.position.y`。
## 本函数把三个量摆在一起，让它们能被直接核对：
##
##   mesh_aabb.y        网格几何相对自身原点的纵向跨度。下界为负的大数 = 原点在网格**体内**
##                      （中心 pivot 的网格），此时即便 pivot=0 也已经埋掉半个网格。
##   pivot_variants     descriptor 交给放置链的候选。三变体（bottom/middle/upper）自动生成
##                      已于 2026-08-05 删除，所以这里正常只应看到**一条零偏移 bottom**；
##                      出现多条即说明该 descriptor 显式写了 `pivot_variants`。
##   predicted_body     用该 pivot 放置后，网格体相对 anchor 的纵向占位 = mesh_aabb.y 区间 − pivot.y。
##                      期望是这个区间以 0 为下界（贴着 anchor 往上长）。
func debug_placement_pivot_report() -> String:
	var spa := _spa_display_host()
	if spa == null:
		return "ERROR spa_display_host_unavailable"
	var descriptors: Array = spa.get_registered_descriptors()
	if descriptors.is_empty():
		return "ERROR no_registered_descriptors"
	var lines: Array[String] = [
		"公式: origin = anchor_world - basis * pivot   ⇒ 期望 pivot.y ≈ mesh_aabb.position.y（网格体底部）",
		"三变体自动生成已删除 ⇒ 未显式配置 pivot_variants 的资产应恰好一条 'bottom' offset=(0,0,0)",
		"",
	]
	for asset_index in range(descriptors.size()):
		var descriptor = descriptors[asset_index]
		if descriptor == null:
			continue
		var mesh: Mesh = descriptor.get_mesh() if descriptor.has_method("get_mesh") else null
		var aabb := mesh.get_aabb() if mesh != null else AABB()
		var variants: Array = descriptor.get_pivot_variants() if descriptor.has_method("get_pivot_variants") else []
		lines.append("[%d] %s  mesh_aabb.y=[%+.3f, %+.3f]  height=%.3f%s" % [
			asset_index,
			str(descriptor.asset_id if ("asset_id" in descriptor) else "?"),
			aabb.position.y, aabb.position.y + aabb.size.y, aabb.size.y,
			"   ⚠ 原点在网格体内部（中心 pivot 网格）" if aabb.position.y < -0.5 else "",
		])
		if variants.is_empty():
			lines.append("      pivot_variants: <空>")
		for variant in variants:
			# get_pivot_variants() 已经过 normalize_pivot_variants ⇒ offset 必是 Vector3。
			var offset: Vector3 = variant.get("offset", Vector3.ZERO)
			var low := aabb.position.y - offset.y
			var high := aabb.position.y + aabb.size.y - offset.y
			lines.append("      pivot '%s' offset.y=%+.3f  ⇒ predicted_body vs anchor = [%+.3f, %+.3f]%s" % [
				str(variant.get("name", "?")), offset.y, low, high,
				"" if absf(low) <= 1.0 else "   ⚠ 下界偏离 anchor %.1f m" % low,
			])
		lines.append("")
	return "\n".join(lines)


func get_anchor_world_positions() -> PackedVector3Array:
	return _anchor_world_positions()


func get_anchor_marker_radius() -> float:
	return _anchor_marker_radius()


## [{anchor_index, aabb}]：有有效胜出物体的锚点及其世界 AABB（SPA 射线点选目标）。
## 点选面 = 显示面：遍历全部胜者（分数降序，命中优先高分锚点）。
func get_selectable_anchor_bounds() -> Array:
	_ensure_anchor_cpu_model()
	var out: Array = []
	for anchor_index in FineSelection.ranked_winner_anchor_indices(_model):
		var aabb := _winner_world_aabb(anchor_index)
		if aabb.size.length_squared() > 0.000001:
			out.append({"anchor_index": anchor_index, "aabb": aabb})
	return out



# ---- 真实链装配（S0..S6，placement_stage_env 底座）--------------------------

## S0..S5 底座：env 一次构建常驻（terrain 种子 + committer 提交 + baked .tres 注册 +
## target 读缓冲）。失败置 _env_error 供 HUD。
## 阶段底座**借自 SPA**，demo 不再自己 make 一份。
##
## ⚠ 两个 env 挂同一个 SPA 会互相拆台：`ensure_target_ready()` 在重建时释放上一份常驻
## target 缓冲，谁后跑谁就把对方手里的 RID 变成野指针；`ensure_prefilter` 的缓存也会
## 各算各的，凭空多跑整轮全图 prefilter。所以整个场景只允许有一份，owner = SPA。
func _ensure_env_ready() -> bool:
	var total_t0_usec := Time.get_ticks_usec()
	var spa_host := _spa_display_host()
	if spa_host == null:
		_env_error = "ancestor_scene_placement_actor_unavailable"
		_env = null
		return false
	if _env != null and _env.is_ready() and _env == spa_host.get_placement_stage_env():
		_last_env_ready_phases_ms = {"cached": true, "total": 0.0}
		return true
	_last_env_ready_phases_ms = {"cached": false}
	if not spa_host.ensure_placement_env():
		_env_error = spa_host.get_placement_env_error()
		_env = null
		return false
	_env = spa_host.get_placement_stage_env()
	# 场网格必须与 TargetSV 网格一致（旧的就地改 grid 重建锚点的适配 hack 退役 → 硬失败）
	var grid: Vector3i = (_env.get_committed_sv_metadata() as Dictionary).get("grid_size", Vector3i.ZERO)
	var meta := TargetSVLoaderScript.metadata()
	var tsv_grid := Vector3i(int(meta.get("texture_size", 0)), int(meta.get("slice_count", 0)), int(meta.get("texture_size", 0)))
	if meta.is_empty() or grid != tsv_grid:
		_env_error = "grid_mismatch sv=%s targetsv=%s" % [grid, tsv_grid]
		push_warning("[VolumeScore] %s —— 不打分" % _env_error)
		_env = null
		return false
	# demo 的展示资产表（名字/颜色/AABB/材质）仍要就绪，胜出 mesh 才画得出来。
	if not _ensure_assets_ready():
		_env_error = "no_asset_descriptors"
		return false
	_env_error = ""
	_attach_env_committer_to_spa()
	_last_env_ready_phases_ms["total"] = float(Time.get_ticks_usec() - total_t0_usec) / 1000.0
	return true


## 把一个 tile 子区域标脏，让下一轮 prefilter 覆盖到它（benchmark 的区域扫描入口用）。
func _mark_prefilter_region_dirty(region_rect: Rect2i) -> void:
	if region_rect.size.x > 0 and region_rect.size.y > 0:
		var spa: ScenePlacementActor = _env.get_spa()
		var tile_size: Vector3i = SceneVoxelTileCodecScript.configured_size(
			SceneVoxelTileStoreScript.SCENE_VOXEL_TILE_SIZE_SETTING,
			SceneVoxelTileStoreScript.DEFAULT_SCENE_VOXEL_TILE_SIZE)
		var grid_size: Vector3i = spa.grid_size
		spa.mark_svtile_bounds_dirty(
			Vector3i(region_rect.position.x * tile_size.x, 0, region_rect.position.y * tile_size.z),
			Vector3i(
				mini((region_rect.position.x + region_rect.size.x) * tile_size.x, grid_size.x),
				grid_size.y,
				mini((region_rect.position.y + region_rect.size.y) * tile_size.z, grid_size.z)),
			{"routing": true, "scoring": true},
			{"id": "volume_score_region", "source_id": "volume_score_region"})


## env 初始化时已完成首次 commit；热路径读取四个网格标量，不深拷贝完整 SV。
## 保留冷态回退，避免私有 helper 被测试或热重载在未提交状态直接调用时失效。
func _committed_sv_metadata() -> Dictionary:
	var sv: Dictionary = _env.get_committed_sv_metadata()
	if sv.is_empty():
		sv = _env.ensure_sv_committed().get("sv", {})
	return sv


## 全图区域（golden 与交互空导出共用口径）。collect 按 anchor_vertical_stride 在每个
## 地形高度上采样发锚（步长 0 = 只采地形那一格）；罩住上限的是 ANCHOR_CAPACITY=131072。
func _full_map_region_rects() -> Array:
	var sv := _committed_sv_metadata()
	var tile_grid: Vector3i = sv.get("tile_grid_size", Vector3i.ZERO)
	if tile_grid.x <= 0 or tile_grid.z <= 0:
		return []
	return [Rect2i(0, 0, tile_grid.x, tile_grid.z)]


func _ensure_assets_ready() -> bool:
	if not _assets.is_empty():
		return true
	for d in _load_descriptors():
		var mesh: Mesh = d.get_mesh()
		if mesh == null:
			continue
		_assets.append({
			"descriptor": d,
			"name": str(d.asset_id) if str(d.asset_id) != "" else "Asset%d" % _assets.size(),
			"mesh": mesh,
			"color": d.get_color(),
			"aabb": mesh.get_aabb(),
			"material": d.material,
		})
	return not _assets.is_empty()


## HUD 用的 Top-K 条目（按分数序，无"当前第几条"高亮——滚轮切换已退役）。
func _selected_anchor_topk_entries() -> Array[Dictionary]:
	_ensure_anchor_cpu_model()
	return FineSelection.topk_entries(
		_model, _selected_anchor_idx, selected_anchor_top_k, _asset_names(), rotation_slots)


## Clear provider state and immediately invalidate SPA's mirrored selection.
## Every data rebuild goes through this entry so stale anchor details cannot
## survive Generate Anchors or Score.
func _clear_selection() -> void:
	_selected_anchor_idx = -1
	_notify_spa_selected_anchor_changed()


func _status(require_scored: bool) -> Dictionary:
	var ok := _total_anchors() > 0
	if require_scored:
		ok = ok and _scored()
	var status := {
		"ok": ok,
		"anchors": _total_anchors(),
		"scored": _scored(),
		"asset_count": _assets.size(),
		"score_ms": float(_model.get("elapsed_ms", 0.0)),
	}
	# Fine 常驻交接原样上浮给 SPA（run_score → _publish_score_result → 只读点选交接）。
	# 借用语义不变：RID 归 VPG，途经的任何一层都不得释放。
	# 多区域 Score 走 merge_models，合并模型不带该键——此时 SPA 侧 scored=false，
	# 点选只能用 anchor 层，这是有意的：合并结果没有单一常驻 winner buffer 可指。
	var fine_handoff: Dictionary = _model.get("fine_score_handoff", {})
	if not fine_handoff.is_empty():
		status["fine_score_handoff"] = fine_handoff
	return status


# ---- Diagnostics（细筛 residual breakdown + TargetSV 邻域）-------------------

## Dump 某资产的 **coarse 探针样本**（粗筛打分的全部输入）。
##
## 粗筛每条样本的贡献是 `sample_weight * dot((w_color, w_complexity, w_collision), fits)`，
## 三个 fit 由该样本的 color / complexity / collision 与目标场现算。所以「这个资产的粗筛分
## 为什么是这个值 / 为什么不随目标变」只能从这张表回答：offset 决定探哪些体素、
## 三个 w_* 决定哪一维说了算、color/collision 决定它期待看到什么。
## bridge 调：call_method path=SPA/Volumes/VolumeScore method=debug_asset_probe_samples args=[0]
func debug_asset_probe_samples(asset_index: int, limit: int = 64) -> String:
	if not _ensure_assets_ready():
		return "ERROR assets not ready"
	if asset_index < 0 or asset_index >= _assets.size():
		return "ERROR asset_index %d out of range (assets=%d)" % [asset_index, _assets.size()]
	var entry: Dictionary = _assets[asset_index]
	var descriptor = entry.get("descriptor", null)
	if descriptor == null or not descriptor.has_method("get_profile_samples"):
		return "ERROR asset[%d] 无 descriptor / 无 get_profile_samples" % asset_index
	var samples: Array = descriptor.get_profile_samples(entry.get("mesh", null))
	var flag_coarse := ProfileRecordSchemaScript.SAMPLE_FLAG_COARSE
	var lines: Array[String] = [
		"asset[%d] %s — coarse 探针样本（粗筛输入）" % [asset_index, str(entry.get("name", "?"))],
		"  样本总数=%d" % samples.size(),
		"  idx | offset(local, m)            | color rgba                | coll | s_w   | w_color w_cplx w_coll",
	]
	var shown := 0
	var coarse_total := 0
	var w_sum := Vector3.ZERO
	var weight_sum := 0.0
	for raw in samples:
		if not (raw is Dictionary):
			continue
		var sample := raw as Dictionary
		if int(sample.get("flags", 0)) & flag_coarse == 0:
			continue
		coarse_total += 1
		var wc := float(sample.get("w_color", 1.0))
		var wx := float(sample.get("w_complexity", 1.0))
		var wl := float(sample.get("w_collision", 1.0))
		var sw := float(sample.get("sample_weight", 1.0))
		w_sum += Vector3(absf(wc), absf(wx), absf(wl)) * sw
		weight_sum += sw
		if shown >= limit:
			continue
		shown += 1
		var off: Vector3 = sample.get("local_offset_world", Vector3.ZERO)
		var col: Color = sample.get("color", Color.WHITE)
		lines.append("  %3d | (%7.2f,%7.2f,%7.2f) | (%.2f,%.2f,%.2f,a=%.2f) | %.2f | %5.2f | %6.2f %6.2f %6.2f" % [
			coarse_total - 1, off.x, off.y, off.z,
			col.r, col.g, col.b, col.a,
			float(sample.get("collision", 0.0)), sw, wc, wx, wl])
	lines.append("  coarse 合计=%d（显示前 %d 条）" % [coarse_total, shown])
	if coarse_total > 0:
		lines.append("  Σ(sample_weight)=%.3f  Σ(sw*|w_*|)=(%.3f, %.3f, %.3f) ⇒ 归一化分母=%.3f" % [
			weight_sum, w_sum.x, w_sum.y, w_sum.z, w_sum.x + w_sum.y + w_sum.z])
	return "\n".join(lines)


## 每资产的 coarse / fine 采样数——**粗筛与细筛用的是两套样本**。
## 用于回答「某资产过了粗筛门却从不出现在细筛记录里」：粗筛读 coarse 段、细筛读 fine 段，
## fine 段为 0 的资产会被粗筛照常放行，却在细筛侧一条记录都产不出（表现为该资产
## `prefilter_hits > 0` 而 `fine_valid == 0`，或整个锚点零候选）。
## bridge 调：call_method path=SPA/Volumes/VolumeScore method=debug_asset_sample_ranges
func debug_asset_sample_ranges() -> String:
	if not _ensure_assets_ready():
		return "ERROR assets not ready"
	var spa := _spa_display_host()
	if spa == null or not spa.has_method("get_runtime_profile_container"):
		return "ERROR SPA 缺少 get_runtime_profile_container"
	var container = spa.get_runtime_profile_container()
	if container == null:
		return "ERROR profile container 未就绪"
	# ⚠ 事实源是 SPA 的注册表，**不是** `_env.get_profile_ids()`：后者是旧注册路的产物，
	# 资产注册收进 SPA 之后它恒为空（实测 size=0），照它读会得到「五个资产全都 profile_id 缺失」。
	var profile_ids: Array = spa.get_registered_profile_ids() if spa.has_method("get_registered_profile_ids") else []
	var lines: Array[String] = ["asset sample ranges (coarse = 粗筛探针, fine = 细筛样本)"]
	for asset_index in range(_assets.size()):
		var name := str(_assets[asset_index].get("name", "?"))
		if asset_index >= profile_ids.size():
			lines.append("  [%d] %-22s profile_id 缺失（profile_ids.size=%d）" % [
				asset_index, name, profile_ids.size()])
			continue
		var profile_id := int(profile_ids[asset_index])
		var coarse: Dictionary = container.get_coarse_sample_range_for_profile_id(profile_id)
		var fine: Dictionary = container.get_fine_sample_range_for_profile_id(profile_id)
		var fine_count := int(fine.get("count", 0))
		lines.append("  [%d] %-22s profile_id=%-3d coarse=%-5d fine=%-5d %s" % [
			asset_index, name, profile_id,
			int(coarse.get("count", 0)), fine_count,
			"" if fine_count > 0 else "⚠ fine=0 ⇒ 细筛对它产不出任何候选记录"])
	return "\n".join(lines)


## 输出某锚点的**粗筛**探针分：每资产一行（分数 / 是否过 `min_prefilter_score` 门）。
## 用于回答「这个锚点为什么一个候选都没有」——细筛侧此时全是 `-INF` 占位，
## 从那里分不出「探针分确实低」与「门限设高了」，只有这里能分。bridge 调：
##   call_method path=SPA/Volumes/VolumeScore method=debug_anchor_prefilter_scores args=[13315]
##
## ⚠ 序号换算是本函数存在的主要理由：分数按 collect 的 **source anchor index** 存，
## 而评分模型按线性体素索引重排过。两者经 `source_anchor_indices` 换算，直接拿模型序去读
## 会读到另一个锚点的分数且看不出错。模型缺该表时如实报错，不猜。
func debug_anchor_prefilter_scores(anchor_index: int) -> String:
	_ensure_anchor_cpu_model()
	if not _scored():
		return "ERROR not scored (auto-run may not have finished)"
	if anchor_index < 0 or anchor_index >= _total_anchors():
		return "ERROR anchor_index %d out of range (total=%d)" % [anchor_index, _total_anchors()]
	var spa := _spa_display_host()
	if spa == null or not spa.has_method("debug_read_prefilter_asset_scores"):
		return "ERROR SPA 缺少 debug_read_prefilter_asset_scores（粗筛分数无取用口）"
	var source_indices: PackedInt32Array = _model.get("source_anchor_indices", PackedInt32Array())
	if anchor_index >= source_indices.size():
		return "ERROR 模型缺 source_anchor_indices（size=%d）—— 无法把模型序 %d 换算成 collect 的 source 序" % [
			source_indices.size(), anchor_index]
	var source_index := source_indices[anchor_index]
	var out: Dictionary = spa.debug_read_prefilter_asset_scores(source_index)
	if not bool(out.get("ok", false)):
		return "ERROR 粗筛分数回读失败：%s（source_index=%d）" % [str(out.get("reason", "?")), source_index]
	var scores: PackedFloat32Array = out.get("scores", PackedFloat32Array())
	var gate := float(out.get("min_prefilter_score", 0.0))
	var av := _anchor_voxel(anchor_index)
	var winners: PackedInt32Array = _model.get("winner_per_anchor", PackedInt32Array())
	var winner_name := str(_assets[winners[anchor_index]].get("name", "?")) \
		if anchor_index < winners.size() and winners[anchor_index] >= 0 else "NONE"
	# ⚠ 粗筛当前**不淘汰**（2026-08-10 裁决，见 `shaders/select_anchor_topk.glsl` 文件头）：
	# 分数只决定排序，全部资产都进候选池。所以这里不再打 PASS/below gate ——那会让人
	# 以为门还在起作用；`min_prefilter_score` 只作参考值列出。
	var lines: Array[String] = [
		"anchor #%d (source #%d) voxel=%s winner=%s" % [anchor_index, source_index, str(av), winner_name],
		"-- prefilter probe scores（粗筛暂停淘汰：分数只排序，全部资产进 top-K；" \
			+ "min_prefilter_score=%.3f 当前被 shader 忽略）--" % gate,
	]
	var counted := mini(scores.size(), _assets.size())
	for asset_index in range(counted):
		lines.append("  [%d] %-22s score=%.4f" % [
			asset_index, str(_assets[asset_index].get("name", "?")), scores[asset_index]])
	if scores.size() > _assets.size():
		lines.append("  （分数表 stride=%d 大于已注册资产数 %d，多出的槽位未使用）" % [
			scores.size(), _assets.size()])
	lines.append("-- %d 个资产全部进入候选池；是否有胜出者由细筛决定（见 debug_anchor_breakdown）--"
		% counted)
	return "\n".join(lines)


## 输出某锚点的细筛 residual buffer:每资产一行 (gain/valid/loss_before/loss_after/
## solid_collision/clearance)，外加该锚点邻域的 TargetSV 字段特征(collision/complexity/
## color)——用于回答「为什么 collision-heavy 处放了树」。bridge 调:
##   call_method path=SPA/Volumes/VolumeScore method=debug_anchor_breakdown args=[43, 2]
func debug_anchor_breakdown(anchor_index: int, radius: int = 2) -> String:
	_ensure_anchor_cpu_model()
	if not _scored():
		return "ERROR not scored (auto-run may not have finished)"
	if anchor_index < 0 or anchor_index >= _total_anchors():
		return "ERROR anchor_index %d out of range (total=%d)" % [anchor_index, _total_anchors()]
	var winners: PackedInt32Array = _model.get("winner_per_anchor", PackedInt32Array())
	var av := _anchor_voxel(anchor_index)
	var world := _anchor_world_positions()[anchor_index] if anchor_index < _anchor_world_positions().size() else Vector3.ZERO
	var lines: Array[String] = [
		"anchor #%d voxel=%s world=%s winner=%s" % [
			anchor_index, str(av), str(world),
			str(_assets[winners[anchor_index]].get("name", "?")) if anchor_index < winners.size() and winners[anchor_index] >= 0 else "NONE"],
		"-- per-asset fine-candidate residual (gain>0 improves target-fit; valid needs gain>threshold & collision/clearance under limit) --",
		"   raw = 未归一化匹配分（净覆盖权重格数，随体积增长）；frac = raw/footprint（有效性判定用的就是它）；",
		"   footprint = 该候选落在网格内、地表以上的足迹权重。loss_* 的分母只算压在目标上的部分，与 frac 不同口径。",
	]
	for a in range(_assets.size()):
		var rec := FineSelection.anchor_asset_record(_model, anchor_index, a)
		var asset := _assets[a]
		var col: Color = asset.get("color", Color.WHITE)
		var footprint := FineSelection.record_total_weight(rec)
		lines.append("  [%d] %-22s raw=%+9.2f frac=%+.4f footprint=%s | score=%+.4f valid=%-5s | loss_before=%.4f loss_after=%.4f Δ=%+.4f | solid_collision=%.4f clearance=%.4f yaw=%d | asset(cplx=%.2f rgb=%.2f,%.2f,%.2f)" % [
			a, str(asset.get("name", "?")),
			float(rec.get("raw_match_score", 0.0)),
			FineSelection.record_match_fraction(rec),
			("%.1f" % footprint) if footprint >= 0.0 else "n/a",
			float(rec.get("score", 0.0)), str(rec.get("valid", false)),
			float(rec.get("loss_before", 0.0)), float(rec.get("loss_after", 0.0)),
			float(rec.get("loss_after", 0.0)) - float(rec.get("loss_before", 0.0)),
			float(rec.get("solid_collision", 0.0)), float(rec.get("clearance_overlap", 0.0)),
			int(rec.get("rotation_index", 0)),
			asset.get("descriptor").get_complexity() if asset.get("descriptor") != null else -1.0,
			col.r, col.g, col.b])
	lines.append("-- TargetSV field in anchor neighborhood (radius=%d voxels) --" % radius)
	_ensure_diag_target_bytes()
	lines.append(_debug_target_neighborhood(av, radius))
	return "\n".join(lines)


## 诊断:跨全部锚点统计每资产的「筛选」通过情况——回答「为什么某资产(草)没通过任何筛选」。
## 每资产报:prefilter 命中锚点数(进 topk 候选池=过粗筛) / 细筛 valid 数 / 胜出数 / 最佳分及锚点。
## bridge 调: call_method path=SPA/Volumes/VolumeScore method=debug_asset_survey
func debug_asset_survey() -> String:
	_ensure_anchor_cpu_model()
	if not _scored():
		return "ERROR not scored"
	var winners: PackedInt32Array = _model.get("winner_per_anchor", PackedInt32Array())
	var n := _assets.size()
	var appear := PackedInt32Array(); appear.resize(n)
	var valid_cnt := PackedInt32Array(); valid_cnt.resize(n)
	var win_cnt := PackedInt32Array(); win_cnt.resize(n)
	var best_score := PackedFloat32Array(); best_score.resize(n); best_score.fill(-INF)
	var best_anchor := PackedInt32Array(); best_anchor.resize(n); best_anchor.fill(-1)
	var anchor_total := int(_model.get("anchor_count", 0))
	for ai in range(anchor_total):
		for a in range(n):
			var rec := FineSelection.anchor_asset_record(_model, ai, a)
			var s := float(rec.get("score", -INF))
			if s <= -INF:
				continue
			appear[a] += 1
			if bool(rec.get("valid", false)):
				valid_cnt[a] += 1
			if s > best_score[a]:
				best_score[a] = s
				best_anchor[a] = ai
	var no_winner := 0
	for w in winners:
		if w >= 0 and w < n:
			win_cnt[w] += 1
		elif w < 0:
			no_winner += 1
	var total := anchor_total
	var lines: Array[String] = [
		"asset survey over %d anchors  (prefilter topk gate -> fine valid gate -> winner)" % total,
		"anchors with NO valid winner: %d / %d" % [no_winner, total],
	]
	for a in range(n):
		var bs := best_score[a]
		lines.append("  [%d] %-22s prefilter_hits=%5d/%d  fine_valid=%5d  wins=%5d  best_gain=%s @anchor %d" % [
			a, str(_assets[a].get("name", "?")),
			appear[a], total, valid_cnt[a], win_cnt[a],
			("%+.4f" % bs) if bs > -1.0e20 else "n/a", best_anchor[a]])
	return "\n".join(lines)


## 诊断:对比每个资产的原始 descriptor(_assets,从磁盘 .tres 加载)与注册 descriptor
## (_env.get_descriptors(),评分实际使用——无 collision 的资产会被 _registration_descriptors
## 合成 AABB fallback 整份替换,丢掉 profile_samples/probes)的真实数据量。定位"草无体素数据 /
## 被 fallback 降级"。bridge: call_method path=SPA/Volumes/VolumeScore method=debug_registered_descriptors
func debug_registered_descriptors() -> String:
	if not _ensure_env_ready():
		return "ERROR env not ready: %s" % _env_error
	var reg: Array = _env.get_descriptors()
	var lines: Array[String] = ["asset (RAW from disk  ->  REGISTERED, what scoring uses):"]
	for i in range(_assets.size()):
		var raw = _assets[i].get("descriptor")
		var r = reg[i] if i < reg.size() else null
		lines.append("[%d] %s\n     raw: %s\n     reg: %s" % [
			i, str(_assets[i].get("name", "?")),
			_descriptor_data_summary(raw), _descriptor_data_summary(r)])
	return "\n".join(lines)


## 调试读取端的 canonical 入口：descriptor 的 `profile_samples` → 可评分 fine 体素列表
## （Array[Dictionary]，键 `voxel` = Vector3i 局部体素索引、`color` = 采样色）。
##
## 双向兼容（重烘焙前后同一读法）：descriptor 已带 canonical profile_samples 时
## get_profile_samples() 原样返回；仍是 legacy `asset_voxels` 的旧 .tres 则由
## ProfileRecordSchema.profile_samples_from_legacy_voxels 派生等价 FINE 采样，
## 其 local_offset_world = voxel * collision_voxel_size —— 这里按同一 cell 反解回体素索引。
##
## 只取「资产的可评分体」：FINE 阶段位命中，且排除 CLEARANCE（物理约束记录，非语义体，不画；
## 新编码 SAMPLE_FLAG_CLEARANCE = 1<<2，取代 legacy asset_voxel 的 LEGACY_CLEARANCE_FLAG = 2）。
func _descriptor_fine_voxels(d) -> Array[Dictionary]:
	if d == null or not d.has_method("get_profile_samples"):
		return []
	var cache_key: int = d.get_instance_id()
	if _descriptor_fine_voxel_cache.has(cache_key):
		var cached: Array[Dictionary] = _descriptor_fine_voxel_cache[cache_key]
		return cached
	var raw_cell = d.get("collision_voxel_size")
	# 与 AssetDescriptor.get_profile_samples 传给 profile_samples_from_legacy_voxels 的 voxel_size 同口径
	var inv_cell := 1.0 / maxf(float(raw_cell) if raw_cell != null else 1.0, 1.0e-6)
	var result: Array[Dictionary] = []
	for raw in d.get_profile_samples():
		if not (raw is Dictionary):
			continue
		var sample := raw as Dictionary
		var flags := int(sample.get("flags", 0))
		if (flags & ProfileRecordSchemaScript.SAMPLE_FLAG_FINE) == 0:
			continue   # coarse/probe 采样不是资产可评分体
		if (flags & ProfileRecordSchemaScript.SAMPLE_FLAG_CLEARANCE) != 0:
			continue   # clearance：物理约束记录，非语义体，不画
		var offset: Vector3 = sample.get("local_offset_world", Vector3.ZERO)
		var col: Color = sample.get("color", Color.WHITE)
		result.append({
			"voxel": Vector3i(
				roundi(offset.x * inv_cell), roundi(offset.y * inv_cell), roundi(offset.z * inv_cell)),
			"color": col,
		})
	_descriptor_fine_voxel_cache[cache_key] = result
	return result


func _descriptor_data_summary(d) -> String:
	if d == null:
		return "<null>"
	var col: int = (d.get_collision().size() if d.has_method("get_collision") else -1)
	var av: int = (_descriptor_fine_voxels(d).size() if d.has_method("get_profile_samples") else -1)
	var prb := 0
	var gen = d.get("semantic_probe_generator")
	if gen != null:
		prb = gen.probes.size()
	var c: Color = (d.get_color() if d.has_method("get_color") else Color.BLACK)
	return "collision=%d fine_samples=%d probes=%d | scalar rgb=%.2f,%.2f,%.2f cplx=%.2f" % [
		col, av, prb, c.r, c.g, c.b, d.get_complexity()]


## 诊断用 CPU 目标场副本（懒加载；评分链走 S5 常驻 GPU，不再依赖这份）。
## 直接取 TargetSVLoader.decode() 的分离数组（母计划"改调用已有API"表该行落地：
## 删旧 CPU 逐体素 vec4 打包循环与 r8→u32 codec 展开——诊断读原始 scalar 即可）。
## decode() 的 GPU 路径带静态缓存，二次调用零开销。
func _ensure_diag_target_bytes() -> bool:
	if not _diag_target_completeness.is_empty():
		return true
	var decoded := TargetSVLoaderScript.decode()
	if not bool(decoded.get("valid", false)):
		return false
	_diag_target_completeness = decoded.get("target_completeness", PackedFloat32Array())
	_diag_target_collision = decoded.get("target_collision", PackedFloat32Array())
	_diag_target_color = decoded.get("target_color", PackedColorArray())
	return not _diag_target_completeness.is_empty()


## 采样 TargetSV 在 center 周围 (2r+1)^3 邻域的字段:占用体素数、collision/complexity
## 的均值与峰值、平均颜色——揭示该处目标「想要什么」。
func _debug_target_neighborhood(center: Vector3i, radius: int) -> String:
	var grid: Vector3i = _model.get("grid", Vector3i.ZERO)
	if grid == Vector3i.ZERO or _diag_target_completeness.is_empty():
		return "  (target field unavailable)"
	var n := 0; var occupied := 0
	var sum_coll := 0.0; var max_coll := 0.0
	var sum_cplx := 0.0; var max_cplx := 0.0
	var sum_r := 0.0; var sum_g := 0.0; var sum_b := 0.0
	for dy in range(-radius, radius + 1):
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				var p := center + Vector3i(dx, dy, dz)
				if p.x < 0 or p.y < 0 or p.z < 0 or p.x >= grid.x or p.y >= grid.y or p.z >= grid.z:
					continue
				var idx := VoxelGeneral.voxel_index(p, grid)
				if idx >= _diag_target_completeness.size():
					continue
				var cplx := _diag_target_completeness[idx]
				var coll := _diag_target_collision[idx] if idx < _diag_target_collision.size() else 0.0
				var c: Color = _diag_target_color[idx] if idx < _diag_target_color.size() else Color(0, 0, 0, 0)
				n += 1
				if maxf(cplx, coll) > 0.01:
					occupied += 1
				sum_coll += coll; max_coll = maxf(max_coll, coll)
				sum_cplx += cplx; max_cplx = maxf(max_cplx, cplx)
				sum_r += c.r; sum_g += c.g; sum_b += c.b
	if n == 0:
		return "  (no voxels sampled)"
	return "  voxels=%d occupied=%d(%.0f%%) | collision avg=%.3f max=%.3f | complexity avg=%.3f max=%.3f | color avg=(%.2f,%.2f,%.2f)" % [
		n, occupied, 100.0 * float(occupied) / float(n),
		sum_coll / n, max_coll, sum_cplx / n, max_cplx, sum_r / n, sum_g / n, sum_b / n]


# ---- Visualization ---------------------------------------------------------

func _invalidate_visualization_cache() -> void:
	_visualization_cache_positions = PackedVector3Array()
	_visualization_cache_winners = PackedInt32Array()
	_visualization_cache_rotations = PackedInt32Array()
	_visualization_cache_rotation_slots = -1


func _visualization_cache_matches_model() -> bool:
	if _visualization_cache_rotation_slots != rotation_slots \
			or _winner_profile_mode or not _placed_result.is_empty():
		return false
	# 「上一次的可视化产物还在不在」——⚠ 显示归属已迁到 `SPA/Volumes/Anchor`（2026-08-10），
	# 这里必须问那个节点。原判据查的是 `_display_root` 下的 AnchorPoints，节点搬走之后
	# 它恒为 null ⇒ 缓存**永不命中** ⇒ 每次评分都整块重建可视化（白付一次建表与建节点）。
	var anchor_volume := _anchor_volume()
	if anchor_volume == null or (anchor_volume.call("display_nodes") as Array).is_empty():
		return false
	return _visualization_cache_positions == _model.get("anchor_world_positions", PackedVector3Array()) \
		and _visualization_cache_winners == _model.get("winner_per_anchor", PackedInt32Array()) \
		and _visualization_cache_rotations == _model.get("winner_rotation_indices", PackedInt32Array())


func _capture_visualization_cache() -> void:
	_visualization_cache_positions = _model.get("anchor_world_positions", PackedVector3Array())
	_visualization_cache_winners = _model.get("winner_per_anchor", PackedInt32Array())
	_visualization_cache_rotations = _model.get("winner_rotation_indices", PackedInt32Array())
	_visualization_cache_rotation_slots = rotation_slots


func _build_visualization() -> void:
	var profiler := ScoreTimingProfilerScript.new(profile_score_timing, "volume_score_visualization")
	profiler.mark("run_start")
	# 显示是 CPU 锚点的第一个消费方，且必须排在缓存比对之前：待物化模型的
	# anchor_world_positions 是空的，先比对会把"新一批 GPU 结果"误判成缓存命中。
	_ensure_anchor_cpu_model()
	_ensure_display_root()   # 自挂在本节点下，父子关系由它保证
	profiler.mark("ensure_root")
	if _visualization_cache_matches_model():
		profiler.mark("cache_hit")
		profiler.mark("done")
		if profile_score_timing:
			_last_visualization_timing_profile = profiler.build_report(false)
			_last_visualization_timing_profile["cache_mode"] = "model_output_reuse"
		return
	_invalidate_visualization_cache()
	_clear_display_children()
	profiler.mark("clear_nodes")
	# 重建即离开 Ctrl+H voxel-profile 观察态（胜出 mesh 会以可见态重建）。
	_winner_profile_mode = false
	_winner_profile_node = null
	# 显示重建（Anchors/Score）废除上一次 Place 的放置渲染与状态（下游步骤已失效）。
	if not _placed_result.is_empty():
		_placed_result = {}
		var spa := _spa_display_host()
		if spa != null and spa.has_method("set_autoobject_pick_data"):
			spa.call("set_autoobject_pick_data", {})
	if _anchor_world_positions().is_empty():
		_last_visualization_timing_profile = profiler.build_report(false) if profile_score_timing else {}
		return
	if _selected_anchor_idx >= _anchor_world_positions().size():
		_selected_anchor_idx = -1
	# ⚠ 三档可视化的**挂载与登记**已迁给 `SPA/Volumes/Anchor`（AnchorVolume，2026-08-10）：
	# 本 demo 只算数据、建节点（工厂），由那边按当前档挂载、登记、管生命周期。
	# 这里触发一次它的重建即可——档位与互斥都由它裁。
	_request_anchor_volume_rebuild()
	profiler.mark("anchor_drawables")
	_capture_visualization_cache()
	profiler.mark("done")
	if profile_score_timing:
		_last_visualization_timing_profile = profiler.build_report(false)
		_last_visualization_timing_profile["cache_mode"] = "rebuilt"
		_last_visualization_timing_profile["winner_detail"] = _last_winner_visualization_timing_profile


# ══════════════════════════════════════════════════════════════════════════════
# anchor 显示契约（消费方：`SPA/Volumes/Anchor` 的 AnchorVolume）
#
# 分工：本 demo 算数据、建节点；AnchorVolume 挂载、登记 pick、管生命周期与**档位互斥**。
# ⚠ 工厂**不得** add_child、不得 set_meta(PICK_DRAWABLE_META)、不得注册显示组——
# 那三件现在由基类的 `register_pick_drawable()` 一次做完（含三项校验）。
# ══════════════════════════════════════════════════════════════════════════════

## 建某一档的全部 drawable，返回 `[{node, key}]`（无内容时空数组）。`key` 原样回传给下面的寻址口。
##
## winner 档画**全场每个锚点的第 `rank` 名**候选（rank 从 0 起，Shift+A 切）。同一排名下不同
## 锚点的胜出资产往往不同，而一个 MultiMesh 只能绑一个 mesh 资源 ⇒ **按资产分组，每组一个节点**，
## 由 AnchorVolume 一次全部挂上（基类 `_build_display_drawables()` 支持多条）。
##
## ⚠ 入口处必须确保展示资产就绪：本函数由 AnchorVolume 按**显示**时机调用，而
## `_ensure_assets_ready()` 原先只挂在 env 准备路径上——评分缓存命中那一趟会跳过它。
## 少这一句的表现是「评分成功、锚点也有胜者，winner 档却一个节点都建不出来」
## （`mesh_valid` 全 0 ⇒ 分组表为空），且零提示。它自带 `_assets` 非空即早退，零成本。
func build_anchor_drawables(mode: String, rank: int = 0) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _anchor_world_positions().is_empty():
		return out
	if mode != "marker" and not _ensure_assets_ready():
		return out
	match mode:
		"marker":
			var marker := _build_anchor_point_drawable()
			if marker != null:
				out.append({"node": marker, "key": null})
		"winner":
			return _build_winner_drawables(rank)
		"profile":
			var profile := _build_winner_profile_drawable()
			if profile != null:
				out.append({"node": profile, "key": _selected_anchor_idx})
	return out


## 确保逐锚点 top-K 数据在 CPU 手上（Shift+A 切到第 2 名及以后才需要）。返回是否已可用。
##
## ⚠ 名次是 **Score 本来就算好的**：细筛对每个 (anchor × top-K asset) 求 residual gain，
## 整片候选池 Score 之后**常驻显存**，由 `fine_score_handoff.fine_candidate_buffer_rid` 借出
## （VPG 的注释：「候选/胜出记录留在显存里，消费方借 RID 自取」）。
## 交互 Score 只是**不回读**它——`read_fine_candidate_bytes` 挂在 `full_candidate_diagnostics`
## 上，常规那趟只回读 winner 一份（锚点数 × 64 B），整片候选池是它的 topk 倍。
##
## 所以这里要做的只是**借 RID 回读一次**，不是重跑评分：显示第 2 名与显示第 1 名读的是同一次
## Score 的产物，重评既浪费又可能因场变化而与当前显示的第 1 名不同源。
## ⚠ RID 归 VPG 所有，借方只读不 free。
func ensure_winner_rank_data() -> bool:
	if not _scored():
		return false
	if not PackedByteArray(_model.get("fine_candidate_bytes", PackedByteArray())).is_empty():
		return true
	var handoff: Dictionary = _model.get("fine_score_handoff", {})
	var rd: RenderingDevice = handoff.get("rendering_device", null)
	var candidate_rid: RID = handoff.get("fine_candidate_buffer_rid", RID())
	var byte_count := int(handoff.get("candidate_buffer_bytes", 0))
	if rd == null or not candidate_rid.is_valid() or byte_count <= 0:
		push_warning("[VolumeScore] 取不到常驻候选池（rd=%s rid_valid=%s bytes=%d）—— 第 2 名及以后无数据可显示。" % [
			str(rd != null), str(candidate_rid.is_valid()), byte_count])
		return false
	var bytes := rd.buffer_get_data(candidate_rid, 0, byte_count)
	if bytes.size() < byte_count:
		push_warning("[VolumeScore] 常驻候选池回读长度不足（%d / %d）—— 不按截断数据出名次。" % [
			bytes.size(), byte_count])
		return false
	_model["fine_candidate_bytes"] = bytes
	_model["fine_candidate_record_count"] = int(bytes.size() / 64)
	return true


## winner 档可切的排名档数 = 全场任一锚点拥有的最多有效候选数（上限 topk）。
## 0 = 还没评分或一个有效候选都没有（此时 Shift+A 无可切）。
## ⚠ 未取候选池时恒为 1（只有第 1 名）——先调 `ensure_winner_rank_data()` 再问。
func anchor_winner_rank_count() -> int:
	if not _scored() or not _ensure_assets_ready():
		return 0
	var topk := int(_model.get("topk", 4))
	for rank in range(topk - 1, -1, -1):
		var pick: Dictionary = FineSelection.rank_pick_per_anchor(_model, rank)
		var assets: PackedInt32Array = pick.get("assets", PackedInt32Array())
		for anchor_index in range(assets.size()):
			var asset_index := assets[anchor_index]
			if asset_index >= 0 and asset_index < _assets.size() \
					and _assets[asset_index].get("mesh", null) != null:
				return rank + 1
	return 0


## 实例序 → `anchor_index`。三档三种映射，统一由本口回答（此前是三个 resolve_* 方法）。
##
## ⚠ winner 档必须读 `visible_payload_indices` 而不是源序：`_apply_model_cull` 把幸存实例
## **压缩**到 0..visible-1，实例序随相机变化。用源序解会在开着视距剔除时静默选中另一个锚点。
## 越界一律返回 -1（基类据此判死），不钳。
func anchor_element_for_drawable(key, local_index: int) -> int:
	if local_index < 0:
		return -1
	# marker 档：一个 MultiMesh 罩全部锚点，实例序 == anchor_index（恒等）。
	if key == null:
		return local_index if local_index < _anchor_world_positions().size() else -1
	# profile 档：整块 drawable 就是"选中的那一个锚点"，key 即它（体素盒实例序无意义）。
	if _winner_profile_node != null and is_instance_valid(_winner_profile_node):
		return int(key)
	# winner 档：key 是节点 instance_id，按当前可见压缩表反查。
	var instance_id := int(key)
	for group in _cull_groups:
		var node = group.get("node")
		if not is_instance_valid(node) or node.get_instance_id() != instance_id:
			continue
		var payloads: PackedInt32Array = group.get("visible_payload_indices", PackedInt32Array())
		return int(payloads[local_index]) if local_index < payloads.size() else -1
	return -1


## 让 anchor 卷节点按当前档重建显示（评分/放置重算数据之后调）。
## ⚠ 走 force_：本 demo 重算胜出模型不会推进 anchor 交接号，基类的修订号早退会把
## 重算后的显示挡在门外（表现是"重新评分了但画面没变"）。
func _request_anchor_volume_rebuild() -> void:
	var volume := _anchor_volume()
	if volume != null:
		volume.call("force_rebuild_display")


## `SPA/Volumes/Anchor` 节点（显示归属方）。
func _anchor_volume() -> Node:
	var spa := _spa_display_host()
	if spa == null or not spa.has_method("get_volume"):
		return null
	var node = spa.call("get_volume", &"Anchor")
	return node if node != null and node.has_method("force_rebuild_display") else null


## 锚点小球（marker 档）：一个 MultiMesh 罩全部锚点，实例序 == anchor_index。
func _build_anchor_point_drawable() -> MultiMeshInstance3D:
	var radius := _anchor_marker_radius()
	var marker_mesh := SphereMesh.new()
	marker_mesh.radius = radius
	marker_mesh.height = radius * 2.0
	marker_mesh.radial_segments = 8
	marker_mesh.rings = 4
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = marker_mesh
	var positions := _anchor_world_positions()
	mm.instance_count = positions.size()
	mm.set_buffer(_pack_multimesh_positions(positions))
	var points := MultiMeshInstance3D.new()
	points.name = "AnchorPoints"
	points.multimesh = mm
	points.material_override = DemoDebugVisuals.make_unshaded_material(
		Color(0.20, 0.85, 1.0, 0.82), false, true)
	# ⚠ custom_aabb 必填：基类登记会判死空盒（整批实例会被视锥剔除，画不出也点不中）。
	points.custom_aabb = _points_local_aabb(positions, radius)
	return points


## 小球批的局部包围盒（含半径外扩）。
func _points_local_aabb(positions: PackedVector3Array, radius: float) -> AABB:
	if positions.is_empty():
		return AABB()
	var box := AABB(positions[0], Vector3.ZERO)
	for i in range(1, positions.size()):
		box = box.expand(positions[i])
	return box.grow(maxf(radius, 0.01))


## 某锚点胜出资产的放置信息（transform/winner/yaw/aabb/fit_scale）——渲染、红框 bound、
## 点选三处共用同一变换，保证「红框恰好包住放置的树」且「点树身即选中该锚点」。
## 数学下沉 FineSelection.winner_placement_transform（真实 FBX 轴心/缩放注释在彼处）。
func _winner_placement(anchor_index: int) -> Dictionary:
	_ensure_anchor_cpu_model()
	return FineSelection.winner_placement_transform(_model, anchor_index, _assets, rotation_slots)


## 胜出物体的世界 AABB（点选用：射线命中它 = 选中该锚点）。
func _winner_world_aabb(anchor_index: int) -> AABB:
	var pl := _winner_placement(anchor_index)
	if pl.is_empty():
		return AABB()
	return (pl.transform as Transform3D) * (pl.aabb as AABB)


## 胜出实体（winner 档）：全场每个锚点的**第 `rank` 名**候选，用各资产自己的真实 mesh
## （CLAUDE.md 明令不得用合成代理形状顶替放置对象）。统一经 _winner_placement 变换，无显示上限。
## 只建不挂，见本节顶部的契约说明。
##
## ⚠ 同一排名下不同锚点的候选资产不同，而一个 MultiMesh 只能绑一个 mesh 资源 ⇒
## **按资产分组、每组一个节点**，一次全部返回。挂载与登记由 AnchorVolume 走基类
## `_build_display_drawables()` 完成（它支持多条）。
##
## ⚠ rank 0 与旧「winner 档」逐项一致：`rank_pick_per_anchor()` 的排序规则
## （只取 valid、分数降序）与 `winner_per_anchor` 的选法同源。
func _build_winner_drawables(rank: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var profiler := ScoreTimingProfilerScript.new(profile_score_timing, "volume_score_winner_visualization")
	profiler.mark("run_start")
	if not _scored():
		_last_winner_visualization_timing_profile = profiler.build_report(false) if profile_score_timing else {}
		return out
	var pick: Dictionary = FineSelection.rank_pick_per_anchor(_model, maxi(rank, 0))
	var winners: PackedInt32Array = pick.get("assets", PackedInt32Array())
	var rotations: PackedInt32Array = pick.get("rotations", PackedInt32Array())
	var world_positions: PackedVector3Array = _model.get("anchor_world_positions", PackedVector3Array())
	var slot_count := maxi(rotation_slots, 1)
	var bases: Array[Basis] = []
	bases.resize(slot_count)
	for rotation_index in range(slot_count):
		var yaw := deg_to_rad(float(rotation_index) * (360.0 / float(slot_count)))
		bases[rotation_index] = Basis(Vector3.UP, yaw)
	var pivots: Array[Vector3] = []
	pivots.resize(_assets.size())
	var mesh_valid := PackedByteArray()
	mesh_valid.resize(_assets.size())
	for asset_index in range(_assets.size()):
		var mesh: Mesh = _assets[asset_index].get("mesh", null)
		if mesh == null:
			continue
		var aabb: AABB = _assets[asset_index].get("aabb", mesh.get_aabb())
		pivots[asset_index] = Vector3(
			aabb.position.x + aabb.size.x * 0.5, 0.0,
			aabb.position.z + aabb.size.z * 0.5)
		mesh_valid[asset_index] = 1
	profiler.mark("prepare_assets")
	# 渲染只需按资产分组；点选所需的分数排序仍由 ranked_winner_anchor_indices 单独提供。
	var transforms_by_asset := {}
	# 与 transforms_by_asset 逐项并行的 anchor_index：胜出 mesh 按资产分组后，
	# 「第几个实例」与 anchor_index 之间**没有**任何算术关系（只有这份并行表能反查）。
	# 三角形 ID 拾取的载荷就靠它，不建这份表就只能猜。
	var anchors_by_asset := {}
	var anchor_count := mini(winners.size(), world_positions.size())
	for anchor_index in range(anchor_count):
		var winner := winners[anchor_index]
		if winner < 0 or winner >= _assets.size() or mesh_valid[winner] == 0:
			continue
		if not transforms_by_asset.has(winner):
			transforms_by_asset[winner] = []
			# ⚠ 必须是 Array 而不是 PackedInt32Array：Packed 系是**值类型**，
			# `dict[key].append(v)` 只会往取出来的那份副本上追加，字典里的那份纹丝不动
			# ——表现是载荷表恒为空、每个胜出 mesh 都被 _build_mesh_multimesh 判死。
			# Array 是引用类型，与上面 transforms_by_asset 的用法同构；
			# 出口处再转成 PackedInt32Array。
			anchors_by_asset[winner] = []
		var rotation_index := rotations[anchor_index] if anchor_index < rotations.size() else 0
		var basis := bases[rotation_index] if rotation_index >= 0 and rotation_index < bases.size() \
			else Basis(Vector3.UP, deg_to_rad(float(rotation_index) * (360.0 / float(slot_count))))
		var origin := world_positions[anchor_index] - basis * pivots[winner]
		transforms_by_asset[winner].append(Transform3D(basis, origin))
		anchors_by_asset[winner].append(anchor_index)
	profiler.mark("build_transforms")
	# 本排名下每种资产各建一组。顺序取 `_assets` 的下标序（稳定可预期，不用分组字典的插入序）。
	for target in range(_assets.size()):
		if not transforms_by_asset.has(target):
			continue
		var node := _build_mesh_multimesh(
			_assets[target].get("mesh", null),
			transforms_by_asset[target],
			"Winner_%d_%s" % [target, str(_assets[target].get("name", ""))],
			PackedInt32Array(anchors_by_asset[target]))
		if node == null:
			continue
		var mat: Material = _assets[target].get("material", null)
		if mat != null:
			node.material_override = mat
		# ⚠ 只**建**不挂：挂载 / pick 登记 / 显示组注册由 AnchorVolume 走基类完成。
		# key = 节点 instance_id，与 `_cull_groups` 的查找键一致（剔除压缩表按它索引）。
		out.append({"node": node, "key": node.get_instance_id()})
	profiler.mark("build_nodes")
	profiler.mark("done")
	if profile_score_timing:
		_last_winner_visualization_timing_profile = profiler.build_report(false)
	return out


# ---- 视口热键 ------------------------------------------------------------------
# 输入经 SPA.handle_editor_input 转发到 provider。
# ⚠ demo 临时/观察逻辑：只切换显示或重跑，不改变评分·放置的算法。
#
# G / Space 自 SPA/Interaction/DemoHost 迁入。原先 SPA.handle_editor_input 为 DemoHost
# 单独留了一跳转发，DemoHost 移除后那一跳一并删掉，热键改由本 provider 承接：
# - G     行为不变（读 SPA 的 GPU readiness 报告，与任何 stage env 无关）。
# - Space 由「重跑 DemoHost 自己的放置链」改为「跑 VolumeScore 的 Place」——DemoHost 那条
#         链随它的第二份 env 一起消失了，这是场景里仅存的等价动作。

## Ctrl+H 切换：隐藏全部 anchor 胜出 mesh + 就地显示选中锚点胜出者的 voxel profile；再按恢复。
## 未选中锚点（或选中锚点无有效胜出者）时一律恢复正常显示。
## G：打印 SPA GPU readiness 报告。Space：跑一次 Place。
func forward_editor_viewport_input(_viewport_camera: Camera3D, event: InputEvent) -> bool:
	if not (event is InputEventKey):
		return false
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return false
	if key.keycode == KEY_H and key.ctrl_pressed \
			and not key.shift_pressed and not key.alt_pressed and not key.meta_pressed:
		_toggle_winner_voxel_profile()
		return true
	if key.ctrl_pressed or key.shift_pressed or key.alt_pressed or key.meta_pressed:
		return false
	match key.keycode:
		KEY_G:
			_print_gpu_readiness_report()
			return true
		KEY_SPACE:
			place_final_autoobjects()
			return true
	return false


## G 热键：SPA 的 GPU 就绪报告（自 DemoHost 迁入，逐字保持原输出格式）。
func _print_gpu_readiness_report() -> void:
	var spa := _spa_display_host()
	if spa == null:
		print("[VolumeScore] No SPA instance")
		return
	var report: Dictionary = spa.get_gpu_readiness_report()
	print("[VolumeScore] GPU Readiness Report:")
	for report_key in report.keys():
		print("  %s: %s" % [str(report_key), str(report[report_key])])


## Ctrl+H：在 PROFILE 档与 WINNER 档之间来回。
##
## ⚠ 三档互斥之后这就是一次**切档**（2026-08-10）。此前它是「隐藏 Winner_* 前缀的节点 +
## 另建 profile 节点」——按名字前缀直接写 `visible`，正是 `Winner_*` 三个 visible 写入方
## 之一（一次显示开关刷新就能覆盖掉观察态）。现在可见性只剩基类一个写入方。
func _toggle_winner_voxel_profile() -> void:
	var volume := _anchor_volume()
	if volume == null:
		return
	if _winner_profile_mode:
		_exit_winner_voxel_profile()
		return
	# 进入前需有「带有效胜出者」的选中锚点；否则按 spec 恢复/保持正常显示。
	if _selected_anchor_idx < 0 or _winner_placement(_selected_anchor_idx).is_empty():
		_exit_winner_voxel_profile()
		return
	volume.call("set_display_mode_name", "profile")
	_winner_profile_mode = true
	_update_hud()


func _exit_winner_voxel_profile() -> void:
	var was_active := _winner_profile_mode or _winner_profile_node != null
	_winner_profile_mode = false
	_clear_winner_voxel_profile_node()
	var volume := _anchor_volume()
	if volume != null:
		volume.call("set_display_mode_name", "winner")
	if was_active:
		_cull_dirty = true   # 复显的胜出 mesh 需重算逐实例视距剔除
	_update_hud()


func _clear_winner_voxel_profile_node() -> void:
	if _winner_profile_node != null and is_instance_valid(_winner_profile_node):
		_winner_profile_node.queue_free()
	_winner_profile_node = null


## 为当前选中锚点的胜出者建 voxel profile：胜出 descriptor 的 canonical fine 采样
## （_descriptor_fine_voxels：局部体素坐标 → 局部中心 Vector3(x, y+0.5, z)*collision_voxel_size）
## 经胜出者放置变换（与胜出 mesh 同变换 _winner_placement）就地定位，彩色体素盒经公用
## VoxelDisplay.build_colored 渲染。
func _build_winner_profile_drawable() -> MultiMeshInstance3D:
	_clear_winner_voxel_profile_node()
	if _selected_anchor_idx < 0:
		return null
	var pl := _winner_placement(_selected_anchor_idx)
	if pl.is_empty():
		return null
	var winner_idx: int = int(pl.get("winner", -1))
	if winner_idx < 0 or winner_idx >= _assets.size():
		return null
	var descriptor = _assets[winner_idx].get("descriptor")
	# 缓存命中即零成本；clearance 记录已在 _descriptor_fine_voxels 内按新编码滤除
	var voxels: Array[Dictionary] = _descriptor_fine_voxels(descriptor)
	if voxels.is_empty():
		return
	var xform: Transform3D = pl.get("transform", Transform3D.IDENTITY)
	var cvs := float(descriptor.collision_voxel_size)
	var cell_world := maxf(cvs * xform.basis.get_scale().x, 0.001)
	var centers := PackedVector3Array()
	var colors := PackedColorArray()
	for entry in voxels:
		var lv: Vector3i = entry.get("voxel", Vector3i.ZERO)
		var local_center := Vector3(float(lv.x), float(lv.y) + 0.5, float(lv.z)) * cvs
		centers.append(xform * local_center)
		var col: Color = entry.get("color", Color.WHITE)
		col.a = 0.92   # 烘焙 color.a==complexity 太淡，提亮成实心 debug 盒
		colors.append(col)
	if centers.is_empty():
		return null
	var display := VoxelDisplay.build_colored(
		centers, Vector3(cell_world, cell_world, cell_world), colors,
		{"name": "WinnerVoxelProfile", "unshaded": true})
	if display == null:
		return null
	# 整份 profile 只属于**当前选中的那一个**锚点，所以每个实例的载荷都是同一个
	# anchor_index —— 契约的 key 直接带上它（见 anchor_element_for_drawable），
	# 解码不需要任何逐实例表。
	_winner_profile_node = display
	# ⚠ 只建不挂：挂载 / 登记 / 显示组由 AnchorVolume 走基类完成。
	return display


# ⚠ 这里曾有 `resolve_winner_profile_pick()`。三条 drawable 的解码口已统一为
# `anchor_element_for_drawable()`（本文件的 anchor 显示契约段），载荷形状由基类
# `PickableDomain.resolve_pick` 给出，各域不再各写各的字段。


## 桥/诊断：Ctrl+H voxel-profile 观察态摘要（bridge call_method 验证切换生效）。
func debug_winner_profile_state() -> String:
	var winner_nodes := 0
	var hidden := 0
	if _display_root != null and is_instance_valid(_display_root):
		for child in _display_root.get_children():
			if child is MultiMeshInstance3D and str(child.name).begins_with("Winner_"):
				winner_nodes += 1
				if not (child as Node3D).visible:
					hidden += 1
	var profile_valid := _winner_profile_node != null and is_instance_valid(_winner_profile_node)
	var profile_boxes := 0
	if profile_valid:
		var mm := (_winner_profile_node as MultiMeshInstance3D).multimesh
		profile_boxes = mm.instance_count if mm != null else 0
	return "mode=%s selected_anchor=%d winner_mesh_nodes=%d hidden=%d profile_node=%s profile_boxes=%d" % [
		str(_winner_profile_mode), _selected_anchor_idx, winner_nodes, hidden, str(profile_valid), profile_boxes]


## 桥/诊断：拆解某锚点胜出者「命中 target 的体素」的颜色匹配——回答「树干棕、target 绿，
## 为何评分还高」。CPU 复刻 score shader 逐体素合取判定的 **color 维**（近似：用 record 的 yaw、
## pivot=0、忽略 cur SV 混合——即假设 pred.rgb==asset 体素色，对空场上方体素成立）。把胜出
## descriptor 的 canonical fine 采样映射到 scene voxel，仅统计落在 occupied target(max(complexity,collision)>0.05)
## 上的体素：体素色 vs target 色的 L1、是否过 color 预算、绿/棕分类、命中体素 y 跨度。
## bridge: call_method path=SPA/Volumes/VolumeScore method=debug_winner_voxel_target_match args=[30794]
func debug_winner_voxel_target_match(anchor_index: int) -> String:
	if not _scored():
		return "ERROR not scored"
	if anchor_index < 0 or anchor_index >= _total_anchors():
		return "ERROR anchor %d out of range (total=%d)" % [anchor_index, _total_anchors()]
	var winners: PackedInt32Array = _model.get("winner_per_anchor", PackedInt32Array())
	var winner := winners[anchor_index] if anchor_index < winners.size() else -1
	if winner < 0 or winner >= _assets.size():
		return "anchor %d 无有效胜出者" % anchor_index
	if not _ensure_diag_target_bytes():
		return "ERROR target field unavailable"
	var rec := FineSelection.anchor_asset_record(_model, anchor_index, winner)
	var yaw_slot := int(rec.get("rotation_index", 0))
	var yaw := deg_to_rad(float(yaw_slot) * 360.0 / float(maxi(rotation_slots, 1)))
	var ca := cos(yaw); var sa := sin(yaw)
	var av := _anchor_voxel(anchor_index)
	var grid: Vector3i = _model.get("grid", Vector3i.ZERO)
	var d = _assets[winner].get("descriptor")
	var voxels: Array[Dictionary] = _descriptor_fine_voxels(d)
	var color_max := 0.6   # score_match_config.cfg color_match_max_l1（改了配置需同步此值）
	var off_grid := 0; var off_target := 0; var on_target := 0; var color_pass := 0
	var green_on := 0; var green_pass := 0; var other_on := 0; var other_pass := 0
	var sum_l1 := 0.0
	var svr := 0.0; var svg := 0.0; var svb := 0.0
	var tvr := 0.0; var tvg := 0.0; var tvb := 0.0
	var ymin := 1 << 30; var ymax := -(1 << 30)
	for entry in voxels:
		var lv: Vector3i = entry.get("voxel", Vector3i.ZERO)
		var rx := int(round(ca * lv.x + sa * lv.z))
		var rz := int(round(-sa * lv.x + ca * lv.z))
		var sv := av + Vector3i(rx, lv.y, rz)
		if sv.x < 0 or sv.y < 0 or sv.z < 0 or sv.x >= grid.x or sv.y >= grid.y or sv.z >= grid.z:
			off_grid += 1
			continue
		var idx := VoxelGeneral.voxel_index(sv, grid)
		if idx < 0 or idx >= _diag_target_completeness.size():
			off_grid += 1
			continue
		var tcplx := _diag_target_completeness[idx]
		var tcol := _diag_target_collision[idx] if idx < _diag_target_collision.size() else 0.0
		if maxf(tcplx, tcol) <= 0.05:
			off_target += 1
			continue
		on_target += 1
		var tc: Color = _diag_target_color[idx] if idx < _diag_target_color.size() else Color(0, 0, 0, 0)
		var vc: Color = entry.get("color", Color.WHITE)
		var l1 := absf(vc.r - tc.r) + absf(vc.g - tc.g) + absf(vc.b - tc.b)
		sum_l1 += l1
		var passed := l1 <= color_max
		if passed:
			color_pass += 1
		if vc.g > vc.r and vc.g > vc.b:
			green_on += 1
			if passed: green_pass += 1
		else:
			other_on += 1
			if passed: other_pass += 1
		svr += vc.r; svg += vc.g; svb += vc.b
		tvr += tc.r; tvg += tc.g; tvb += tc.b
		ymin = mini(ymin, lv.y); ymax = maxi(ymax, lv.y)
	var lines: Array[String] = [
		"anchor #%d winner=%s yaw_slot=%d  (CPU 复刻 color 维；忽略 cur SV 混合/pivot=0)" % [
			anchor_index, str(_assets[winner].get("name", "?")), yaw_slot],
		"fine_samples=%d  off_grid=%d  off_target(空目标→按collision负分)=%d  ON-TARGET=%d" % [
			voxels.size(), off_grid, off_target, on_target],
	]
	if on_target > 0:
		var inv := 1.0 / float(on_target)
		lines.append("ON-TARGET color_pass(L1<=%.2f)=%d/%d (%.0f%%)  avg_L1=%.3f" % [
			color_max, color_pass, on_target, 100.0 * color_pass * inv, sum_l1 * inv])
		lines.append("  绿体素=%d(pass %d) | 棕/其他体素=%d(pass %d)" % [
			green_on, green_pass, other_on, other_pass])
		lines.append("  avg on-target 体素色=(%.2f,%.2f,%.2f)  target 色=(%.2f,%.2f,%.2f)" % [
			svr * inv, svg * inv, svb * inv, tvr * inv, tvg * inv, tvb * inv])
		lines.append("  on-target 体素局部 y=%d..%d（低=贴地/树干，高=树冠）" % [ymin, ymax])
	return "\n".join(lines)


## 桥/诊断：对比「渲染对齐 vs 评分器最优对齐」——证明「渲染用 pivot ≠ 评分用 pivot」。
## rendered = pivot 0 + 胜出 yaw（胜出 mesh 实际画出来的位置，用户所见=树干贴地）；
## best = 扫全部 vertical-pivot × yaw 里 color 命中占比最高者（≈评分器实际采到的位置——
## 评分器用 vertical pivot 把绿树冠下移对到地面绿 target）。bridge args=[30794]。
func debug_winner_pivot_sweep(anchor_index: int) -> String:
	if not _scored():
		return "ERROR not scored"
	if anchor_index < 0 or anchor_index >= _total_anchors():
		return "ERROR anchor %d out of range" % anchor_index
	var winners: PackedInt32Array = _model.get("winner_per_anchor", PackedInt32Array())
	var winner := winners[anchor_index] if anchor_index < winners.size() else -1
	if winner < 0 or winner >= _assets.size():
		return "anchor %d 无有效胜出者" % anchor_index
	if not _ensure_diag_target_bytes():
		return "ERROR target field unavailable"
	var rec := FineSelection.anchor_asset_record(_model, anchor_index, winner)
	var winner_yaw := int(rec.get("rotation_index", 0))
	var av := _anchor_voxel(anchor_index)
	var grid: Vector3i = _model.get("grid", Vector3i.ZERO)
	var vsize := _voxel_size()
	var d = _assets[winner].get("descriptor")
	# pivot×yaw 双重循环重复扫这份采样——取一次缓存结果，不在循环里重复 get_profile_samples()
	var voxels: Array[Dictionary] = _descriptor_fine_voxels(d)
	var pivots: Array = [{"name": "zero", "offset": Vector3.ZERO}]
	if d != null and d.has_method("get_pivot_variants"):
		for pv in d.get_pivot_variants():
			pivots.append(pv)
	var slots := maxi(rotation_slots, 1)
	var winner_ca := cos(deg_to_rad(float(winner_yaw) * 360.0 / float(slots)))
	var winner_sa := sin(deg_to_rad(float(winner_yaw) * 360.0 / float(slots)))
	var rendered := _color_match_scan(voxels, av, grid, Vector3i.ZERO, winner_ca, winner_sa)
	var best := {}
	var best_frac := -1.0
	var best_name := "?"; var best_pvox := Vector3i.ZERO; var best_yaw := 0
	for pv in pivots:
		var pw: Vector3 = (pv as Dictionary).get("offset", Vector3.ZERO)
		var pvox := Vector3i(int(round(pw.x / maxf(vsize.x, 0.001))),
			int(round(pw.y / maxf(vsize.y, 0.001))), int(round(pw.z / maxf(vsize.z, 0.001))))
		for ys in range(slots):
			var yy := deg_to_rad(float(ys) * 360.0 / float(slots))
			var r := _color_match_scan(voxels, av, grid, pvox, cos(yy), sin(yy))
			var ot := int(r.get("on_target", 0))
			if ot <= 0:
				continue
			var frac := float(r.get("pass", 0)) / float(ot)
			if frac > best_frac or (is_equal_approx(frac, best_frac) and ot > int(best.get("on_target", 0))):
				best = r; best_frac = frac
				best_name = str((pv as Dictionary).get("name", "?")); best_pvox = pvox; best_yaw = ys
	return "\n".join([
		"anchor #%d winner=%s  vertical pivots=%d yaw slots=%d  (record yaw=%d, global_pivot_index=%d)" % [
			anchor_index, str(_assets[winner].get("name", "?")), pivots.size(), slots,
			winner_yaw, int(rec.get("global_pivot_index", -1))],
		"— RENDERED（pivot=0 + 胜出 yaw=%d = 你看到的胜出 mesh 位置）—" % winner_yaw,
		_fmt_match_scan(rendered),
		"— BEST（评分器可选 pivot×yaw 里 color 命中最高 ≈ 实际评分位置）: pivot=%s pivot_voxels=%s yaw=%d —" % [
			best_name, str(best_pvox), best_yaw],
		_fmt_match_scan(best),
	])


## debug_winner_pivot_sweep 用：把 _descriptor_fine_voxels 的 fine 体素（clearance 已滤除）
## 按 (pivot_voxels, yaw ca/sa) 映射到 scene voxel，
## 统计落在 occupied target 上体素的 color 命中（L1<=0.6）。返回统计字典。
func _color_match_scan(voxels: Array[Dictionary], av: Vector3i, grid: Vector3i, pivot_voxels: Vector3i, ca: float, sa: float) -> Dictionary:
	var color_max := 0.6
	var on_target := 0; var passed := 0; var green_on := 0
	var sum_l1 := 0.0
	var svr := 0.0; var svg := 0.0; var svb := 0.0; var tvr := 0.0; var tvg := 0.0; var tvb := 0.0
	var ymin := 1 << 30; var ymax := -(1 << 30)
	for entry in voxels:
		var lv: Vector3i = entry.get("voxel", Vector3i.ZERO)
		var bx := lv.x - pivot_voxels.x; var by := lv.y - pivot_voxels.y; var bz := lv.z - pivot_voxels.z
		var rx := int(round(ca * bx + sa * bz))
		var rz := int(round(-sa * bx + ca * bz))
		var sv := av + Vector3i(rx, by, rz)
		if sv.x < 0 or sv.y < 0 or sv.z < 0 or sv.x >= grid.x or sv.y >= grid.y or sv.z >= grid.z:
			continue
		var idx := VoxelGeneral.voxel_index(sv, grid)
		if idx < 0 or idx >= _diag_target_completeness.size():
			continue
		var tcplx := _diag_target_completeness[idx]
		var tcol := _diag_target_collision[idx] if idx < _diag_target_collision.size() else 0.0
		if maxf(tcplx, tcol) <= 0.05:
			continue
		on_target += 1
		var tc: Color = _diag_target_color[idx] if idx < _diag_target_color.size() else Color(0, 0, 0, 0)
		var vc: Color = entry.get("color", Color.WHITE)
		var l1 := absf(vc.r - tc.r) + absf(vc.g - tc.g) + absf(vc.b - tc.b)
		sum_l1 += l1
		if l1 <= color_max:
			passed += 1
		if vc.g > vc.r and vc.g > vc.b:
			green_on += 1
		svr += vc.r; svg += vc.g; svb += vc.b; tvr += tc.r; tvg += tc.g; tvb += tc.b
		ymin = mini(ymin, by); ymax = maxi(ymax, by)
	return {"on_target": on_target, "pass": passed, "green_on": green_on, "sum_l1": sum_l1,
		"svr": svr, "svg": svg, "svb": svb, "tvr": tvr, "tvg": tvg, "tvb": tvb,
		"ymin": ymin, "ymax": ymax}


func _fmt_match_scan(r: Dictionary) -> String:
	var ot := int(r.get("on_target", 0))
	if ot <= 0:
		return "  ON-TARGET=0（无体素落在 occupied target 上）"
	var inv := 1.0 / float(ot)
	return "  ON-TARGET=%d  color_pass(L1<=0.6)=%d (%.0f%%)  avg_L1=%.3f  绿体素=%d\n  avg 体素色=(%.2f,%.2f,%.2f) target色=(%.2f,%.2f,%.2f)  anchor 相对 y=%d..%d" % [
		ot, int(r.get("pass", 0)), 100.0 * float(r.get("pass", 0)) * inv, float(r.get("sum_l1", 0.0)) * inv,
		int(r.get("green_on", 0)),
		float(r.get("svr", 0.0)) * inv, float(r.get("svg", 0.0)) * inv, float(r.get("svb", 0.0)) * inv,
		float(r.get("tvr", 0.0)) * inv, float(r.get("tvg", 0.0)) * inv, float(r.get("tvb", 0.0)) * inv,
		int(r.get("ymin", 0)), int(r.get("ymax", 0))]


## 选中锚点胜出物体的定向包围盒（供 SPA 画红色 sample-bounds 框）。
func _selected_anchor_sample_bounds() -> Dictionary:
	var pl := _winner_placement(_selected_anchor_idx)
	if pl.is_empty():
		return {}
	var aabb: AABB = pl.aabb
	var t: Transform3D = pl.transform
	var obb_size: Vector3 = aabb.size * float(pl.fit_scale)
	var obb_center: Vector3 = t * (aabb.position + aabb.size * 0.5)
	return {
		"has_obb": true,
		"obb_center": obb_center,
		"obb_size": obb_size,
		"obb_yaw": float(pl.yaw),
		"aabb": AABB(obb_center - obb_size * 0.5, obb_size),
	}


func _anchor_marker_radius() -> float:
	var voxel_size := _voxel_size()
	return maxf(minf(voxel_size.x, voxel_size.z) * 0.12, ANCHOR_RADIUS_MIN)


## `payload_indices[i]` = 第 i 个源变换对应的域载荷（胜出 mesh 用 anchor_index）。
## 它随实例一起进剔除组，剔除压缩后由 _apply_model_cull 同步压缩——见那里的说明。
func _build_mesh_multimesh(mesh: Mesh, transforms: Array, node_name: String,
		payload_indices: PackedInt32Array) -> MultiMeshInstance3D:
	if mesh == null or transforms.is_empty():
		return null
	if payload_indices.size() != transforms.size():
		# 数量对不上就无法把「点中第几个实例」映射回 anchor_index，而错位的表现是
		# 「点这棵树选中了别的锚点」——一个完全合法的结果，从界面上看不出错。
		push_error("[VolumeScore] _build_mesh_multimesh(%s): payload_indices 数量 %d 与 transforms 数量 %d 不一致 —— 拒绝建立无法反查载荷的 drawable。" % [
			node_name, payload_indices.size(), transforms.size()])
		assert(false, "VolumeScore._build_mesh_multimesh: payload/transform count mismatch")
		return null
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	mm.set_buffer(_pack_multimesh_transforms(transforms))
	var node := MultiMeshInstance3D.new()
	node.name = node_name
	node.multimesh = mm
	# 胜出预览模型经此 → 注册进 CPU 逐实例视距剔除（anchor 点标记走别处，不受影响）。
	# ⚠ 放置结果**不再**走这里：它是 GPU 直提的（_sync_placed_instances_gpu），一旦进了
	# 剔除组，_apply_model_cull 的 set_instance_transform() 会静默清零全部 GPU 写入的实例。
	_register_model_cull_group(node, mesh, transforms, payload_indices)
	# ⚠ 不再自己 set_meta(PICK_DRAWABLE_META)：pick 登记由 AnchorVolume 走基类的
	# `register_pick_drawable()` 完成（含几何 / custom_aabb / 参与点选三项校验）。
	# 契约的 key 就是本节点 instance_id —— 与 `_cull_groups` 的查找键一致。
	return node


# ---- View-Distance Culling -------------------------------------------------

## 注册一个放置/胜出资产 MultiMesh 进逐实例视距剔除：捕获完整实例变换（源），并设置
## 覆盖全体实例的 custom_aabb（动态改 visible_instance_count 后防整节点被视锥误剔）。
## 首次剔除交给 _process——此刻 node 尚未入树，global_transform 未定。
func _register_model_cull_group(node: MultiMeshInstance3D, mesh: Mesh, transforms: Array,
		payload_indices: PackedInt32Array) -> void:
	_prune_cull_groups()
	node.custom_aabb = _instances_local_aabb(mesh, transforms)
	# visible_payload_indices 由 _apply_model_cull 维护，初值 = 未剔除的全序
	# （剔除还没跑过时 visible_instance_count 也还是 -1，两者一致）。
	_cull_groups.append({
		"node": node,
		"transforms": transforms,
		"payload_indices": payload_indices,
		"visible_payload_indices": payload_indices,
	})
	_cull_dirty = true
	_update_cull_processing()


# ⚠ 这里曾有 `resolve_cull_group_pick()`（按 `visible_payload_indices` 反查的解码口）。
# 那段查找已并入 `anchor_element_for_drawable()` 的 winner 分支——三条 drawable 一个口。
# 「必须读压缩表而不是源序」这条约束原样保留在那里。


## Godot 的 TRANSFORM_3D MultiMesh buffer 每实例为 3 行 vec4：
## basis row 0 + origin.x、row 1 + origin.y、row 2 + origin.z。
func _pack_multimesh_positions(positions: PackedVector3Array) -> PackedFloat32Array:
	var buffer := PackedFloat32Array()
	buffer.resize(positions.size() * 12)
	for i in range(positions.size()):
		var base := i * 12
		var position := positions[i]
		buffer[base] = 1.0
		buffer[base + 3] = position.x
		buffer[base + 5] = 1.0
		buffer[base + 7] = position.y
		buffer[base + 10] = 1.0
		buffer[base + 11] = position.z
	return buffer


func _pack_multimesh_transforms(transforms: Array) -> PackedFloat32Array:
	var buffer := PackedFloat32Array()
	buffer.resize(transforms.size() * 12)
	for i in range(transforms.size()):
		var base := i * 12
		var transform: Transform3D = transforms[i]
		var basis := transform.basis
		buffer[base] = basis.x.x
		buffer[base + 1] = basis.y.x
		buffer[base + 2] = basis.z.x
		buffer[base + 3] = transform.origin.x
		buffer[base + 4] = basis.x.y
		buffer[base + 5] = basis.y.y
		buffer[base + 6] = basis.z.y
		buffer[base + 7] = transform.origin.y
		buffer[base + 8] = basis.x.z
		buffer[base + 9] = basis.y.z
		buffer[base + 10] = basis.z.z
		buffer[base + 11] = transform.origin.z
	return buffer


## 全体实例（未剔除）在节点本地空间的合并 AABB，作 custom_aabb 用。
func _instances_local_aabb(mesh: Mesh, transforms: Array) -> AABB:
	var local := mesh.get_aabb() if mesh != null else AABB()
	var result := AABB()
	var has := false
	for t in transforms:
		var transform: Transform3D = t
		var box: AABB = transform * local
		result = box if not has else result.merge(box)
		has = true
	return result


## 视距参照相机：编辑器=编辑器 3D 视口的导航相机（随浏览实时变化），运行时=当前视口
## Camera3D（回退场景 FlyCamera）；取不到返回 null。
## ⚠ get_viewport().get_camera_3d() 在编辑器里返回的是场景常驻相机（FlyCamera，停在远处
## 俯瞰位、不随导航移动），会拿一个 ~1400u 外的定点当参照把实例全剔光；故编辑器下显式
## 取 EditorInterface 的视口导航相机（这才是"你实际在看的视角"）。
func _active_cull_camera() -> Camera3D:
	if Engine.is_editor_hint():
		var evp := EditorInterface.get_editor_viewport_3d(0)
		var ed_cam := evp.get_camera_3d() if evp != null else null
		if ed_cam != null:
			return ed_cam
	return DemoUI.find_camera(self, "", "FlyCamera", true, true)


func _active_cull_camera_position() -> Vector3:
	var cam := _active_cull_camera()
	return cam.global_position if cam != null else Vector3(INF, INF, INF)


## 有 CPU 剔除组（胜出预览）或有 GPU 放置批，_process 就得跑——后者的剔除也是随相机
## 重算的，只是重算发生在 emit kernel 里。
func _update_cull_processing() -> void:
	set_process(cull_models_by_distance and (not _cull_groups.is_empty() or _has_placed_gpu_display()))


## 丢弃已释放（显示 rebuild / queue_free）的组。
func _prune_cull_groups() -> void:
	var kept: Array[Dictionary] = []
	for group in _cull_groups:
		var node = group.get("node")
		if node != null and is_instance_valid(node):
			kept.append(group)
	if kept.size() != _cull_groups.size():
		_cull_groups = kept


## 剔除开关/参数变化：强制下轮重算；关闭时立即恢复全可见，开启时立即按当前相机剔除。
func _on_cull_settings_changed() -> void:
	_cull_dirty = true
	_last_cull_camera_pos = Vector3(INF, INF, INF)
	_update_cull_processing()
	_apply_model_cull(_active_cull_camera_position())


func _process(_delta: float) -> void:
	# 软重载后编辑器里第一个跑到的就是本函数，收口在这里最稳（见 _repair_soft_reloaded_members）
	_repair_soft_reloaded_members()
	if not cull_models_by_distance or (_cull_groups.is_empty() and not _has_placed_gpu_display()):
		return
	var cam_pos := _active_cull_camera_position()
	if cam_pos.x == INF:
		return
	if not _cull_dirty:
		# 静止/微动早退：只有相机移动超过阈值（或参数变脏）才付 O(N) 重写代价。
		if cam_pos.distance_to(_last_cull_camera_pos) < model_cull_recompute_move:
			return
		# 时间节流：快速连续飞行时最多每 CULL_MIN_INTERVAL_MS 重算一次（脏标志不受节流）。
		if Time.get_ticks_msec() - _last_cull_time_ms < CULL_MIN_INTERVAL_MS:
			return
	_last_cull_time_ms = Time.get_ticks_msec()
	_apply_model_cull(cam_pos)


## 逐实例按到相机距离重建各组 MultiMesh 的可见集（在范围内实例 compaction 到前段 +
## visible_instance_count 截断）。关闭剔除或无相机时恢复全可见。只动显示节点、绝不
## 触碰评分状态（_model）——golden 快照不受影响。
func _apply_model_cull(cam_pos: Vector3) -> void:
	if not is_inside_tree():
		return
	_prune_cull_groups()
	var enabled := cull_models_by_distance and cam_pos.x != INF
	var max_sq := model_cull_distance * model_cull_distance
	for group in _cull_groups:
		var node: MultiMeshInstance3D = group["node"]
		if not is_instance_valid(node) or not node.is_inside_tree():
			continue
		var mm: MultiMesh = node.multimesh
		if mm == null:
			continue
		var transforms: Array = group["transforms"]
		# 载荷表必须与实例序**同步压缩**：三角形 ID 拾取拿到的是 MultiMesh 实例序，
		# 而这里每次剔除都在重排实例序。漏更新 = 开着剔除时点树选中另一个锚点。
		var payloads: PackedInt32Array = group.get("payload_indices", PackedInt32Array())
		if not enabled:
			# 恢复全可见：把源按原序写回并放开 visible count。
			for i in range(transforms.size()):
				mm.set_instance_transform(i, transforms[i])
			mm.visible_instance_count = -1
			group["visible_payload_indices"] = payloads
			continue
		var to_world := node.global_transform
		var visible := 0
		var visible_payloads := PackedInt32Array()
		for i in range(transforms.size()):
			var t: Transform3D = transforms[i]
			var world_origin: Vector3 = to_world * t.origin
			if cam_pos.distance_squared_to(world_origin) <= max_sq:
				mm.set_instance_transform(visible, t)
				if i < payloads.size():
					visible_payloads.append(payloads[i])
				visible += 1
		mm.visible_instance_count = visible
		group["visible_payload_indices"] = visible_payloads
	# 放置批走 GPU：剔除在 emit kernel 里做，这里只是把同一个相机位姿转交过去。
	# 剔除参数变脏（开关/距离改了）时必须强制重 emit——见 _refresh_placed_gpu_cull。
	_refresh_placed_gpu_cull(cam_pos, _cull_dirty)
	_last_cull_camera_pos = cam_pos
	_cull_dirty = false


## 读当前各组（可见, 总）实例数——不触发重算，读上一轮 _apply_model_cull 的结果。
func _read_cull_counts() -> Vector2i:
	var total := 0
	var visible := 0
	for group in _cull_groups:
		var node = group.get("node")
		if not is_instance_valid(node):
			continue
		var mm: MultiMesh = (node as MultiMeshInstance3D).multimesh
		if mm == null:
			continue
		total += mm.instance_count
		visible += mm.instance_count if mm.visible_instance_count < 0 else mm.visible_instance_count
	return Vector2i(visible, total)


## ⚠ 放置批的**剔除后**可见数读不出来：GPU 剔除靠写零基向量隐藏实例，被剔者仍占着
## `[0, instance_count)` 里的槽位。放置批的 `visible_instance_count` 现在等于**本批存活数**
## （R3 §7.8：截掉 next_power_of_2 的容量 padding，见 PlacedInstanceDisplay），不是剔除结果。
## 回读 emit 的 live_count 只为凑一个 HUD 数字不值当（阻塞往返进 HUD 路径），
## 所以这里如实分开报：CPU 组报 可见/总，GPU 组只报总数 + 剔除在 GPU 上。
func _model_cull_hud_text() -> String:
	var placed := int(_placed_display_result.get("instances", 0)) if _has_placed_gpu_display() else 0
	var placed_text := "" if placed <= 0 else "; placed %d on GPU" % placed
	if not cull_models_by_distance:
		return "off (all shown)%s" % placed_text
	var c := _read_cull_counts()
	return "%d/%d visible @ %.0fu%s" % [c.x, c.y, model_cull_distance, placed_text]


## 逐实例视距剔除诊断（桥/HUD 可读）：先按当前相机强制重算，再回读 total/visible。
## 只读显示节点，绝不触碰评分状态。
func get_model_cull_stats() -> Dictionary:
	_apply_model_cull(_active_cull_camera_position())
	var c := _read_cull_counts()
	return {
		"enabled": cull_models_by_distance,
		"cull_distance": model_cull_distance,
		"groups": _cull_groups.size(),
		"total_instances": c.y,
		"visible_instances": c.x,
		"camera_position": _active_cull_camera_position(),
		# 放置批不在 groups 里：它走 GPU 直提，剔除由 emit kernel 做（零基向量隐藏），
		# 故没有 CPU 侧可见数可报——上面的 total/visible 只覆盖胜出预览那些 CPU 组。
		"gpu_placed_display": _has_placed_gpu_display(),
		"gpu_placed_instances": int(_placed_display_result.get("instances", 0)),
		"gpu_placed_batches": int(_placed_display_result.get("batches", 0)),
		"gpu_placed_reason": str(_placed_display_result.get("reason", "never_synced")),
	}


# ---- Descriptor loading ----------------------------------------------------

## 直读 SPA registry，不留副本。
##
## ⚠ 无目录回退、无本地列表：拿不到就是空。旧实现先看本类的 `placement_assets`，空了才回退
## 扫 `res://assets`——那与 SPA 的 `baked_descriptors/` 是两个不同目录，一旦触发，评分用的
## 资产集就和 SPA registry 悄悄分叉。空的处理按 `CLAUDE.md`：调用方 push warning 且不放置，
## **绝不**退化成代理盒。
func _load_descriptors() -> Array:
	var spa := _spa_display_host()
	if spa == null:
		return []
	var result: Array = []
	for d in spa.get_registered_descriptors():
		if _is_asset_descriptor(d) and d.get_mesh() != null:
			result.append(d)
	return result


func _is_asset_descriptor(res) -> bool:
	return res != null and res is Resource and res.has_method("get_mesh") and res.has_method("get_collision")


# ---- SPA binding -----------------------------------------------------------

func _sync_spa_bindings() -> void:
	_ensure_display_root()
	_register_spa_volume_score_provider()
	_attach_env_committer_to_spa()
	_wire_selection_host()


## SelectionHost 的 demo 侧接线（自 DemoHost 迁入）。
##
## ⚠ 这不是可选的锦上添花：SPA 只在**自己创建** SelectionHost 时才 configure 它
## （scene_placement_actor.gd 的 `if _selection_host == null` 分支内），而本场景的
## SelectionHost 是 .tscn 声明的 ⇒ SPA 那一支永远不走。DemoHost 移除后若没有这里，
## `refresh_terrain_cache()` 将无人调用，而 `_terrain_field` 没有第二个写入点——
## 地形高度场恒为空，`position_on_terrain_from_voxel_center()` 把所有 overlay
## （SVTile 热力图、锚点采样框）摆到错误的 Y 上，且不报任何错。
##
## configure 用 `options.get(k, 当前值)` 取那四个标量，传空字典即保持不变；但两个回调
## 没有这层兜底（`options.get(k, Callable())`），所以必须每次都带上，否则调用一次
## configure 就等于把它们清掉。
func _wire_selection_host() -> void:
	var host := _selection_host_or_null()
	if host == null:
		return
	# ⚠ visuals_refresh 钩子随热力图总览标签一并删除（2026-08-10）：那个钩子只淡化标签，
	# 而标签是热力图的一部分。host 侧的钩子仍然支持，只是本 demo 不再需要。
	host.configure({
		"hud_update": _update_hud,
	})
	host.refresh_terrain_cache()


## 清空显示根的子节点。
## 用 remove_child + free 而不是裸 queue_free()：queue_free 要到帧末才真正销毁，节点在
## 本帧内仍占着名字，紧接着重建的同名节点会被 Godot 改成 "AnchorPoints2"，而缓存命中判断
## 是按名字查节点的（见 _visualization_cache_matches_model 一侧的 get_node_or_null），
## 于是交替重建时缓存判断会错位。remove_child 立刻让出名字。
## 同款写法见 scripts/utils/target_sv_setup.gd 的显示清理。
func _clear_display_children() -> void:
	if _display_root == null or not is_instance_valid(_display_root):
		return
	for child in _display_root.get_children():
		_display_root.remove_child(child)
		child.free()


## _display_root 懒建 + 自愈回收，并且**必须挂在本节点下**。
##
## 为什么是本节点而不是 SPA 的 display owner root：Node::_notification(PREDELETE) 会
## memdelete 全部子节点，所以 provider 一死，它的可视化必然一起死——这条绑定不需要任何
## 清理代码，也就不会有人忘记写。反过来，挂到 SPA 子树下就是把可视化的寿命交给了另一个
## 比它活得久的节点，正是"数据没了、锚点还画着"的成因。
##
## 回收顺序：先认本节点下的既有节点；再认旧位置（SPA owner root 下）遗留的孤儿并**搬回
## 本节点**——不这么做的话，改动前那些已经挂在旧位置的节点将永远无人回收。
##
## 变换基准：实例变换里装的是世界坐标，所以显示根必须处于世界单位变换。VolumeScore 的
## 父节点 Volumes 是普通 Node，故 VolumeScore 本身即变换根，这里把局部变换置为单位即可。
func _ensure_display_root() -> Node3D:
	if _display_root != null and is_instance_valid(_display_root):
		return _display_root
	_display_root = get_node_or_null("VolumeScoreDisplay") as Node3D
	if _display_root == null:
		var spa := _spa_display_host()
		if spa != null and spa.has_method("get_voxel_display_root"):
			var owner_root: Node3D = spa.call("get_voxel_display_root", VOLUME_SCORE_DISPLAY_OWNER)
			if owner_root != null:
				_display_root = owner_root.get_node_or_null("VolumeScoreDisplay") as Node3D
				if _display_root != null:
					owner_root.remove_child(_display_root)   # 旧位置的孤儿：搬回来
	if _display_root == null:
		_display_root = Node3D.new()
		_display_root.name = "VolumeScoreDisplay"
	if _display_root.get_parent() == null:
		add_child(_display_root)
	_display_root.transform = Transform3D.IDENTITY
	return _display_root


## 把 env 的 committer 接进 SPA 宿主选择层：SV / SVTile 数据域点选与 HUD 在本组合场景可用
## （Place 改写 committed SV 后可直接点体素验证）。宿主自有 stage env 时该调用被忽略。
func _attach_env_committer_to_spa() -> void:
	pass


## 选中态宿主（借用）。SPA 装配并拥有它；拿不到就说明 demo 没挂在 SPA 子树下。
func _selection_host_or_null() -> SPASelectionHost:
	var spa := _spa_display_host()
	return spa.get_selection_host() if spa != null else null


func _spa_display_host() -> ScenePlacementActor:
	if _spa_host != null and is_instance_valid(_spa_host) and _spa_host.is_inside_tree():
		return _spa_host
	if not is_inside_tree():
		return null
	var ancestor: Node = get_parent()
	while ancestor != null:
		if ancestor is ScenePlacementActor:
			_spa_host = ancestor as ScenePlacementActor
			return _spa_host
		ancestor = ancestor.get_parent()
	return null


func _register_spa_volume_score_provider() -> void:
	var spa := _spa_display_host()
	if spa != null and spa.has_method("register_volume_provider"):
		spa.call("register_volume_provider", self)


func _unregister_spa_volume_score_provider() -> void:
	var spa := _spa_display_host()
	if spa != null and spa.has_method("unregister_volume_provider"):
		spa.call("unregister_volume_provider", self)


func _notify_spa_selected_anchor_changed() -> void:
	var spa := _spa_display_host()
	if spa != null and spa.has_method("refresh_volume_score_anchor_selection"):
		spa.call("refresh_volume_score_anchor_selection")


func _register_spa_voxel_display_node(display_key: String, node: Node3D) -> void:
	if node == null:
		return
	var spa := _spa_display_host()
	if spa != null and spa.has_method("register_voxel_display_node"):
		spa.call("register_voxel_display_node", display_key, node, VOLUME_SCORE_DISPLAY_OWNER)
	# ⚠ 曾问 `voxel_display_effective_visible`——该口 2026-08-11 已删（与本口逐字同义）。
	# `has_method` 守卫会把"方法没了"静默成"不设可见性"，改名时必须连这里一起改。
	if spa != null and spa.has_method("is_voxel_display_visible"):
		node.visible = bool(spa.call("is_voxel_display_visible", display_key))


# ---- HUD -------------------------------------------------------------------

func _setup_hud() -> void:
	_hud_label = DemoUI.setup_hud_label(self)


func _selected_anchor_hud_lines() -> Array[String]:
	var lines: Array[String] = []
	if not _scored():
		lines.append("Selected anchor: run Score first")
		return lines
	if _selected_anchor_idx < 0:
		lines.append("Selected anchor: click an anchor")
		return lines
	lines.append("Selected anchor #%d voxel=%s top-%d:" % [
		_selected_anchor_idx, str(_anchor_voxel(_selected_anchor_idx)), selected_anchor_top_k])
	var entries := _selected_anchor_topk_entries()
	if entries.is_empty():
		lines.append("  (no score entries)")
		return lines
	for entry in entries:
		lines.append("  %s" % _format_topk_entry(entry))
	return lines


func _format_topk_entry(entry: Dictionary) -> String:
	var score := float(entry.get("score", -INF))
	var score_text := "%.3f" % score if score > -1.0e20 else "n/a"
	return "#%d %s score=%s yaw=%.0f %s" % [
		int(entry.get("rank", 0)), str(entry.get("asset_name", "?")),
		score_text, float(entry.get("yaw", 0.0)),
		"valid" if bool(entry.get("valid", false)) else "invalid"]


## Place 步的 HUD 摘要：未放置 / 失败 / 成功（提交数 + 渲染数）。
func _placed_hud_text() -> String:
	if _placed_result.is_empty():
		return "— (press Place to commit real AutoObjects + modify SV)"
	if not bool(_placed_result.get("ok", false)):
		return "FAILED: %s" % str(_placed_result.get("reason", "?"))
	return "%d AutoObjects committed in %d batch(es) (SV modified), %d rendered" % [
		int(_placed_result.get("spawned", 0)),
		int(_placed_result.get("batches", 1)),
		int(_placed_result.get("rendered", 0))]


func _update_hud() -> void:
	if _hud_label == null:
		return
	_ensure_anchor_cpu_model()   # HUD 报锚点数/胜者数，同样是 CPU 锚点的消费方
	var rd_status := "ready" if RenderingServer.get_rendering_device() != null else "NO GPU"
	var grid: Vector3i = _model.get("grid", _env.get_grid_size() if _env != null else Vector3i.ZERO)
	var env_status := "ready" if _env != null else ("error:%s" % _env_error if not _env_error.is_empty() else "not built")
	var winners: PackedInt32Array = _model.get("winner_per_anchor", PackedInt32Array())
	var winner_total := 0
	for w in winners:
		if w >= 0:
			winner_total += 1
	var lines: Array[String] = [
		"placement-score-3d (real-chain S6 anchors / VPG fine-selection)",
		"GPU: %s   grid=%s   assets=%d   env=%s" % [rd_status, str(grid), _assets.size(), env_status],
		"Anchors: %d (tile_rect=%s, target-inside)   Rotations: %d   Score: %.0f ms" % [
			_total_anchors(), str(prefilter_tile_rect), rotation_slots, float(_model.get("elapsed_ms", 0.0))],
		"Winners shown: %d/%d (all)" % [winner_total, winner_total],
		"Placed: %s" % _placed_hud_text(),
		"Model cull: %s" % _model_cull_hud_text(),
		"Ctrl+H: %s — hide anchor meshes, show selected winner's voxel profile" % ("ON (voxel profile)" if _winner_profile_mode else "off"),
		"SPA Inspector: Anchors → S6 anchors, Score → rank assets, Place → commit real AutoObjects + modify SV; click an anchor to inspect top-%d" % selected_anchor_top_k,
		"",
	]
	for i in range(_assets.size()):
		var wins := 0
		for w in winners:
			if w == i:
				wins += 1
		lines.append("[%d] %s  wins=%d" % [i, str(_assets[i].get("name", "?")), wins])
	if not _scored():
		lines.append("")
		lines.append("(scoring not complete — press Score)")
	else:
		lines.append("")
		lines.append_array(_selected_anchor_hud_lines())
	_hud_label.text = "\n".join(lines)
