@tool
extends "res://scripts/core_demo_contract_fixture.gd"

## ScenePlacementActor (SPA) — GPU AutoObject Placement Demo
##
## SPA lifecycle (initialize → register_asset → GPU profile) drives a GPU
## batch-spawn of AutoObjects (spawn_batch_from_accepted_placement_records),
## flushed into SVTile object refs. All AutoObjects are GPU-generated; there is
## no CPU per-node manual placement.
##
## Selection is read-only inspection over GPU/data views:
##   GPU AutoObject points, SVTile, SceneVoxel, Anchor, TargetSV.
##
## Controls:
##   LMB click       — select under current mode (GPU AutoObject / data voxel)
##   Shift+0..5      — switch selection mode (Mixed/AutoObject/SVTile/Anchor/SV/TargetSV)
##   G               — print GPU readiness report
##   Space           — re-register all assets + re-run GPU batch spawn
##   Escape          — deselect

const AutoAssetFactory := preload("res://scripts/auto_asset_factory.gd")
const TerrainConfigScript := preload("res://scripts/terrain_config.gd")
const AssetDescriptorScript := preload("res://scripts/asset_descriptor.gd")
const ScenePlacementActorScript := preload("res://scripts/scene_placement_actor.gd")
const SceneVoxelCommitterScript := preload("res://scripts/scene_voxel_committer.gd")
const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")
const GPUAutoObjectRuntimeScript := preload("res://scripts/gpu_autoobject_runtime.gd")
const VoxelPickGPUScript := preload("res://scripts/voxel_pick_gpu.gd")
const VoxelDisplay := preload("res://scripts/utils/voxel_display.gd")
const VoxelDebugLabel := preload("res://scripts/utils/voxel_debug_label.gd")
const AutoObjectScript := preload("res://scripts/auto_object.gd")
const MeshVoxelizerGpuScript := preload("res://scripts/mesh_voxelizer_gpu.gd")
const AutoVoxelProfileScript := preload("res://scripts/auto_voxel_profile.gd")
const DemoAssets := preload("res://scripts/utils/demo_assets.gd")
const DemoUI := preload("res://scripts/utils/demo_ui.gd")
const TargetSVLookup := preload("res://scripts/utils/target_sv_lookup.gd")
const SPAEditorContract := preload("res://scripts/spa_editor_contract.gd")
const SPATestScript := preload("res://demos/core-SPA-scene-placement-actor/spa_test.gd")
const SELECT_COLOR := Color(1.0, 0.85, 0.0, 1.0)

## Selection mode contract:
## - MIXED: editor-friendly priority pick. It first tries GPU AutoObject points,
##   then volume-score anchors, then data voxels (TargetSV first, SVTile second).
## - AUTOOBJECT: only GPUAutoObjectRuntime point markers; returns object_id,
##   asset/profile, voxel range, and owning SVTile coordinates.
## - SVTILE: SceneVoxelTile aggregate/debug record for the clicked voxel's tile;
##   useful for object-ref counts and tile payload inspection.
## - ANCHOR: anchor inspection. Volume-score provider anchors are preferred;
##   otherwise a clicked voxel is reported as an anchor candidate.
## - SV: committed SceneVoxel cell from SceneVoxelCommitter; reads complexity,
##   collision, tile coordinate, and payload for the clicked voxel.
## - TARGETSV: guidance TargetSV cell from TargetSVSetup buffers; this is desired
##   target data, not committed SceneVoxel placement.
enum SelectionMode { MIXED, AUTOOBJECT, SVTILE, ANCHOR, SV, TARGETSV }

const SELECTION_MODE_NAMES := SPAEditorContract.SELECTION_MODE_NAMES
const SELECTION_DOMAIN_AUTOOBJECT := SPAEditorContract.SELECTION_DOMAIN_AUTOOBJECT
const SELECTION_DOMAIN_SVTILE := SPAEditorContract.SELECTION_DOMAIN_SVTILE
const SELECTION_DOMAIN_ANCHOR := SPAEditorContract.SELECTION_DOMAIN_ANCHOR
const SELECTION_DOMAIN_SV := SPAEditorContract.SELECTION_DOMAIN_SV
const SELECTION_DOMAIN_TARGETSV := SPAEditorContract.SELECTION_DOMAIN_TARGETSV
const SELECTION_GEOMETRY_TRIANGLE := SPAEditorContract.SELECTION_GEOMETRY_TRIANGLE
const SELECTION_GEOMETRY_VOXEL := SPAEditorContract.SELECTION_GEOMETRY_VOXEL
const SELECTION_GEOMETRY_GPU_POINT := SPAEditorContract.SELECTION_GEOMETRY_GPU_POINT
const SELECTION_GEOMETRY_VOLUME_SCORE_ANCHOR := SPAEditorContract.SELECTION_GEOMETRY_VOLUME_SCORE_ANCHOR
const SELECTION_FADED_TRANSPARENCY := 0.76
const ANCHOR_SAMPLE_BOUNDS_COLOR := Color(1.0, 0.08, 0.04, 0.95)
const SVTILE_AUTOOBJECT_OVERLAY_ROOT_NAME := "SVTileAutoObjectOverlay"
const LEGACY_SVTILE_OBJECT_REF_OVERLAY_ROOT_NAME := "SVTileObjectRefOverlay"
const HUD_ROOT_NAME := "HUD"
const EXTERNAL_VOXEL_DISPLAY_ROOT_NAME := SPAEditorContract.EXTERNAL_VOXEL_DISPLAY_ROOT_NAME
const VOXEL_DISPLAY_GPU_OBJECTS := SPAEditorContract.VOXEL_DISPLAY_GPU_OBJECTS
const VOXEL_DISPLAY_SVTILE := SPAEditorContract.VOXEL_DISPLAY_SVTILE
const VOXEL_DISPLAY_ANCHOR := SPAEditorContract.VOXEL_DISPLAY_ANCHOR
const VOXEL_DISPLAY_SV := SPAEditorContract.VOXEL_DISPLAY_SV
const VOXEL_DISPLAY_TARGETSV := SPAEditorContract.VOXEL_DISPLAY_TARGETSV
## 旧版 CPU 手动放置链遗留的容器节点名，启动时一并清理
const LEGACY_AUTOOBJECT_ROOT_NAME := "EditorAutoObjects"
const LEGACY_EDITOR_WIREFRAME_ROOT_NAME := "EditorWireframes"
const LEGACY_EDITOR_LABEL_ROOT_NAME := "EditorLabels"
const GENERATED_EDITOR_NODE_NAMES := [
	LEGACY_AUTOOBJECT_ROOT_NAME,
	LEGACY_EDITOR_WIREFRAME_ROOT_NAME,
	LEGACY_EDITOR_LABEL_ROOT_NAME,
	SVTILE_AUTOOBJECT_OVERLAY_ROOT_NAME,
	LEGACY_SVTILE_OBJECT_REF_OVERLAY_ROOT_NAME,
	EXTERNAL_VOXEL_DISPLAY_ROOT_NAME,
	HUD_ROOT_NAME,
]

@export var autoobject_count := 65536
@export var autoobject_grid_resolution := 512
@export_range(8, 48, 1) var asset_voxel_grid_count: int = 16
## 启动时是否 GPU 批量 spawn AutoObject。以 volume-score provider 为主的场景（如
## placement-score-3d）关掉它，避免默认铺满 autoobject；Space 手动重跑仍可触发。
@export var spawn_autoobjects_on_start := true
@export var voxel_display_host_only := false
@export var show_svtile_autoobject_overlay := true
@export var show_anchor_sample_bounds := true
@export var select_gpu_autoobjects := true
@export var gpu_autoobject_pick_radius_px := 28.0
var _selection_mode := SelectionMode.MIXED
@export_enum("Mixed", "AutoObject", "SVTile", "Anchor", "SV", "TargetSV") var selection_mode: int = SelectionMode.MIXED:
	set(value):
		set_spa_selection_mode(int(value), false)
	get:
		return _selection_mode

# ---- SPA state ----
var _spa
var _sv_committer
var _voxel_pick_gpu
var _initialized := false
var _init_time_ms := 0.0
var _register_time_ms := 0.0
var _descriptors: Array = []
var _profile_ids: Array[int] = []
var _runtime_setup_result: Dictionary = {}

# ---- object state ----
var _meshes: Array[Mesh] = []

# ---- visuals ----
var _hud_label: Label
var _autoobject_overlay_root: Node3D
var _svtile_heatmap: MultiMeshInstance3D
var _autoobject_points: MultiMeshInstance3D
var _autoobject_overlay_label: Label3D
## 统一选中可视：单个线框 box marker + 单个 Label3D，所有点选域共用
var _selection_marker: MeshInstance3D
var _selection_label: Label3D
## anchor 专属范围框（语义是范围而非点选标记，作为可选附加层保留）
var _anchor_sample_bounds_marker: MeshInstance3D
var _external_voxel_display_root: Node3D
var _volume_score_provider: Node
var _voxel_display_visible := SPAEditorContract.default_voxel_display_state()

# ---- SVTile / GPU AutoObject runtime state ----
var _autoobject_runtime_ready := false
var _autoobject_spawn_result: Dictionary = {}
var _autoobject_flush_result: Dictionary = {}
var _svtile_summary: Dictionary = {}
var _autoobject_spawn_time_ms := 0.0
var _autoobject_flush_time_ms := 0.0
var _autoobject_visual_time_ms := 0.0
var _svtile_total_tile_count := 0
var _svtile_occupied_tile_count := 0
var _svtile_max_refs_per_tile := 0
var _svtile_total_refs := 0
var _autoobject_positions: Array[Vector3] = []
var _autoobject_asset_indices: Array[int] = []
var _autoobject_ids: Array[int] = []
var _autoobject_side_count := 0
var _autoobject_spacing_voxels := 1
## 唯一活动选中记录：autoobject / 数据体素 / volume-score anchor 镜像的单一真相来源
var _active_selection: Dictionary = {}

# ---- terrain cache ----
var _terrain_field: PackedFloat32Array
var _terrain_field_res := 0


## 引擎就绪回调：仅编辑器模式触发初始化
func _ready() -> void:
	super._ready()
	if not Engine.is_editor_hint():
		return
	if is_scene_startup_blocked():
		return
	_validate_selection_bindings()
	if voxel_display_host_only:
		_cleanup_editor_nodes()
		_ensure_external_voxel_display_root()
		_apply_selection_mode_visuals()
		return
	_editor_init()


## 编辑器模式初始化入口：创建节点、加载资源、初始化SPA
func _editor_init() -> void:
	_cleanup_editor_nodes()
	_autoobject_overlay_root = Node3D.new()
	_autoobject_overlay_root.name = SVTILE_AUTOOBJECT_OVERLAY_ROOT_NAME
	add_child(_autoobject_overlay_root, true)
	_load_meshes()
	ensure_test_terrain_initialized()
	_cache_terrain_field()
	_init_spa()
	_register_all_assets()
	if spawn_autoobjects_on_start:
		_run_gpu_autoobject_batch()
	_setup_hud()
	_frame_camera()
	_apply_selection_mode_visuals()
	_update_hud()
	if _initialized:
		print("[SPA Editor] SPA initialized: gpu_ready=%s, assets=%d" % [
			str(_spa.is_gpu_ready()), _descriptors.size()])


## 启动自检：合同表里的 pick_method/record_method 都是字符串方法名，靠 callv 动态派发，
## 没有编译期链接。任何改名/手误会让对应模式变成"静默死点击"（点了没反应、也不报错）。
## 这里在编辑器加载时逐条校验，缺失即 push_error，让 -e 加载立刻暴露断掉的绑定。
func _validate_selection_bindings() -> void:
	for raw_binding in SPAEditorContract.VOXEL_DOMAIN_BINDINGS:
		var binding: Dictionary = raw_binding
		for method_key in ["pick_method", "record_method"]:
			var method_name := str(binding.get(method_key, ""))
			if method_name.is_empty():
				continue
			if not has_method(method_name):
				push_error("[SPA Selection] 合同绑定失效：mode=%s domain=%s 的 %s=\"%s\" 在本节点上不存在——该模式会静默点不中" % [
					str(binding.get("mode", -1)),
					str(binding.get("domain", "")),
					method_key,
					method_name,
				])


## 设置选择模式并清除旧选中状态；插件工具栏和 Shift+数字快捷键都进入这里
func set_spa_selection_mode(mode: int, clear_existing_selection: bool = true) -> void:
	var next := clampi(mode, SPAEditorContract.MODE_MIXED, SELECTION_MODE_NAMES.size() - 1)
	var changed := _selection_mode != next
	_selection_mode = next
	if clear_existing_selection and changed and is_inside_tree():
		clear_active_selection(false)
		_consume_editor_mouse_release = false
		_select_editor_selection_anchor_for_mode()
	_apply_selection_mode_visuals()
	_update_hud()
	if changed:
		print("[SPA Selection] Mode: %s" % _selection_mode_name())


## 返回当前选择模式枚举值
func get_spa_selection_mode() -> int:
	return _selection_mode


## 返回当前选择模式的可读名称
func get_spa_selection_mode_name() -> String:
	return _selection_mode_name()


func get_scene_placement_actor() -> Object:
	return _spa


## 编辑器桥入口：运行 GPU 常驻直连写回端到端检查（spa_test 的静态检查函数）。
func run_resident_placement_writeback_check() -> Dictionary:
	return SPATestScript.check_resident_placement_writeback()


## 编辑器桥入口：stamp-only 提交 + BrushSV/BlendSV/feedback 端到端检查。
func run_stamp_only_commit_check() -> Dictionary:
	return SPATestScript.check_stamp_only_commit_and_blend_sv()


func own_autoobject(autoobject_ref: Object, asset_id: int = -1) -> bool:
	if _spa == null or not _spa.has_method("own_autoobject"):
		return false
	if not (autoobject_ref is AutoObject):
		return false
	return bool(_spa.call("own_autoobject", autoobject_ref, asset_id))


## 在视口屏幕坐标处执行选择（按当前模式分派）
func select_at_viewport_position(x: float, y: float, mode: int = -1) -> Dictionary:
	if mode >= 0:
		set_spa_selection_mode(mode)
	var cam := _editor_camera if _editor_camera != null else _get_camera()
	if cam == null:
		return {"ok": false, "reason": "missing_camera"}
	var result := _select_current_mode_at_screen_position(cam, Vector2(x, y))
	if result.is_empty():
		return {"ok": false, "reason": "no_hit", "mode": _selection_mode_name()}
	return result


## 按体素坐标执行数据选择；只适用于 SVTile/Anchor/SV/TargetSV 这类数据域
func select_data_voxel(mode: int, x: int, y: int, z: int) -> Dictionary:
	var mode_id := int(mode)
	set_spa_selection_mode(mode_id)
	if _mode_requires_scene_voxel_committer(mode_id) and _sv_committer == null:
		return {"ok": false, "reason": "scene_voxel_committer_unavailable", "mode": _selection_mode_name(mode_id)}
	var record := _data_record_for_voxel(mode_id, Vector3i(int(x), int(y), int(z)))
	if record.is_empty():
		return {"ok": false, "reason": "no_data_record", "mode": _selection_mode_name(mode_id)}
	set_active_selection(record)
	return {"ok": true, "domain": str(record.get("domain", "")), "geometry": str(record.get("geometry", "")), "record": record}


## 获取当前选中的统一记录字典
func get_current_selection_record() -> Dictionary:
	if not _active_selection.is_empty():
		return _active_selection.duplicate(true)
	return {}


## Register a demo/provider that owns volume-score anchor generation and top-k state.
func register_volume_score_provider(provider: Node) -> void:
	if provider == null:
		return
	_volume_score_provider = provider
	print("[SPA VolumeScore] Provider registered: %s" % str(provider.get_path()))
	refresh_volume_score_anchor_selection()


## Remove the volume-score provider when its owner exits the tree.
func unregister_volume_score_provider(provider: Node) -> void:
	if provider != null and _volume_score_provider == provider:
		_volume_score_provider = null
		if _active_selection_is_volume_score_anchor():
			_active_selection.clear()
			_update_anchor_sample_bounds_marker()
			_update_hud()


## True when SPA has a live volume-score provider to delegate editor actions to.
func has_volume_score_provider() -> bool:
	return _volume_score_provider_node() != null


## SPA entry: generate visible volume-score anchors.
func generate_volume_score_anchors() -> Dictionary:
	return _call_volume_score_provider("generate_anchors")


## SPA entry: calculate volume scores for generated anchors.
func calculate_volume_score() -> Dictionary:
	return _call_volume_score_provider("calculate_voxel_scores")


## SPA entry: compact selected anchor score summary for editor toolbar.
func get_selected_anchor_summary_text() -> String:
	var provider := _volume_score_provider_node()
	if provider != null and provider.has_method("get_selected_anchor_summary_text"):
		return str(provider.call("get_selected_anchor_summary_text"))
	return ""


## SPA entry: expanded selected anchor score details for editor toolbar tooltip.
func get_selected_anchor_tooltip_text() -> String:
	var provider := _volume_score_provider_node()
	if provider != null and provider.has_method("get_selected_anchor_tooltip_text"):
		return str(provider.call("get_selected_anchor_tooltip_text"))
	return ""


## Refresh SPA-owned visuals for the provider's current volume-score anchor.
## provider 选中/清除/切换 anchor 时回调进来，把权威态镜像进 _active_selection。
## provider 选中/清除/切换 anchor 时回调进来：SPA 是唯一绘制点，经 canonical selection
## visual 画高亮 box + top-k 标签 + 红色 sample-bounds 框。
func refresh_volume_score_anchor_selection() -> Dictionary:
	var record := _volume_score_selection_record()
	if record.is_empty():
		# provider 已无 anchor：清镜像 + 隐藏 marker/label，不动其它域的选中
		if _active_selection_is_volume_score_anchor():
			_active_selection.clear()
			_hide_node_if_valid(_selection_marker)
			_hide_node_if_valid(_selection_label)
		_update_anchor_sample_bounds_marker()
		_update_hud()
		return {"ok": false, "reason": "no_selected_anchor"}
	_active_selection = record.duplicate(true)
	_apply_selection_visual(_active_selection)
	_apply_selection_mode_visuals()
	_update_hud()
	return {"ok": true, "record": record}


## 设置指定体素调试域是否显示
func set_voxel_display_visible(display_key: String, visible: bool) -> void:
	_normalize_voxel_display_state()
	if not _voxel_display_visible.has(display_key):
		return
	_voxel_display_visible[display_key] = visible
	_apply_external_voxel_display_visibility(display_key)
	_apply_selection_mode_visuals()
	_update_hud()


## 返回指定体素调试域是否显示
func is_voxel_display_visible(display_key: String) -> bool:
	return _voxel_display_is_visible(display_key)


## 返回当前所有体素显示开关状态
func get_voxel_display_state() -> Dictionary:
	_normalize_voxel_display_state()
	return _voxel_display_visible.duplicate(true)


## 重建体素显示开关，供编辑器MCP/热重载后刷新
func refresh_voxel_display_controls() -> void:
	_apply_all_external_voxel_display_visibility()
	_apply_selection_mode_visuals()


## Return the SPA-owned parent for external voxel display nodes.
func get_voxel_display_root(owner_key: String = "external") -> Node3D:
	var external_root := _ensure_external_voxel_display_root()
	if external_root == null:
		return null
	var owner_name := _external_voxel_display_owner_name(owner_key)
	var owner_root := external_root.get_node_or_null(NodePath(owner_name)) as Node3D
	if owner_root == null:
		owner_root = Node3D.new()
		owner_root.name = owner_name
		external_root.add_child(owner_root, true)
	return owner_root


## Attach a demo-owned display root under SPA so the editor has one entry point.
func attach_voxel_display_root(display_root: Node3D, owner_key: String = "external") -> Node3D:
	if display_root == null:
		return null
	var owner_root := get_voxel_display_root(owner_key)
	if owner_root == null:
		return null
	if display_root.get_parent() != owner_root:
		var keep_global := display_root.is_inside_tree()
		var global_before := display_root.global_transform if keep_global else Transform3D.IDENTITY
		var parent := display_root.get_parent()
		if parent != null:
			parent.remove_child(display_root)
		owner_root.add_child(display_root, true)
		if keep_global and display_root.is_inside_tree():
			display_root.global_transform = global_before
	return owner_root


## Register one external display node with one of SPA's voxel display keys.
func register_voxel_display_node(display_key: String, node: Node3D, owner_key: String = "external") -> void:
	_normalize_voxel_display_state()
	if node == null or not _voxel_display_visible.has(display_key):
		return
	_ensure_external_voxel_display_root()
	node.add_to_group(_voxel_display_group(display_key))
	node.visible = _voxel_display_effective_visible(display_key)


## 根据模式枚举返回可读名称
func _selection_mode_name(mode: int = -1) -> String:
	var idx := _selection_mode if mode < 0 else mode
	return SPAEditorContract.selection_mode_name(idx)


## 查询体素显示开关状态（纯手动开关，不含模式过滤，供工具栏勾选状态查询）
func _voxel_display_is_visible(display_key: String) -> bool:
	_normalize_voxel_display_state()
	return bool(_voxel_display_visible.get(display_key, true))


## 实际渲染可见性：手动开关 AND 当前选择模式关联性。
## 非 Mixed 模式下，与当前模式无关的体素域一律隐藏（而不只是淡化）。
func _voxel_display_effective_visible(display_key: String) -> bool:
	if display_key.is_empty():
		return true
	if not _voxel_display_is_visible(display_key):
		return false
	return SPAEditorContract.mode_focuses_display_key(_selection_mode, display_key)


## 确保运行时显示状态覆盖合同表里的所有体素域
func _normalize_voxel_display_state() -> void:
	for display_key in SPAEditorContract.default_voxel_display_state().keys():
		if not _voxel_display_visible.has(display_key):
			_voxel_display_visible[display_key] = true


## 统一将选择域映射到显示开关
func _voxel_display_key_for_domain(domain: String) -> String:
	return SPAEditorContract.voxel_display_key_for_domain(domain)


func _volume_score_provider_node() -> Node:
	if _volume_score_provider != null and is_instance_valid(_volume_score_provider):
		return _volume_score_provider
	_volume_score_provider = null
	return null


func _call_volume_score_provider(method_name: String, args: Array = []) -> Dictionary:
	var provider := _volume_score_provider_node()
	if provider == null:
		return {"ok": false, "reason": "missing_volume_score_provider"}
	if not provider.has_method(method_name):
		return {"ok": false, "reason": "volume_score_method_missing", "method": method_name}
	var result = provider.callv(method_name, args)
	if result is Dictionary:
		return result
	return {"ok": true, "return": result}


func _volume_score_anchor_selection_allowed() -> bool:
	var anchor_key := SPAEditorContract.voxel_display_key_for_mode(SelectionMode.ANCHOR)
	return _voxel_display_is_visible(anchor_key) \
		and SPAEditorContract.mode_is_active(_selection_mode, SelectionMode.ANCHOR)


func _volume_score_anchor_display_active() -> bool:
	if not _volume_score_anchor_selection_allowed():
		return false
	var provider := _volume_score_provider_node()
	if provider == null:
		return false
	if provider.has_method("has_volume_score_anchors"):
		return bool(provider.call("has_volume_score_anchors"))
	return provider.has_method("select_anchor_at_viewport_position")


## SPA 拥有 volume-score anchor 点选：射线优先命中胜出物体世界 AABB（点树身即选中该锚点），
## 回退锚点小球；点中后调 provider.select_anchor（只置状态 + 回调 refresh，由 SPA 统一绘制反馈）。
func _select_volume_score_anchor_at_position(cam: Camera3D, screen_pos: Vector2) -> Dictionary:
	if not _volume_score_anchor_selection_allowed():
		return {}
	var provider := _volume_score_provider_node()
	if provider == null or not provider.has_method("select_anchor"):
		return {}
	var anchor_index := _pick_volume_score_anchor(provider, cam, screen_pos)
	if anchor_index < 0:
		return {}
	# 清掉非 anchor 域的旧选中（点云染色 / box marker），保留 provider。
	clear_active_selection(false, false)
	var result = provider.call("select_anchor", anchor_index)
	if not (result is Dictionary) or not bool(result.get("ok", false)):
		return {}
	var record := _volume_score_selection_record(result)
	return {
		"ok": true,
		"domain": SELECTION_DOMAIN_ANCHOR,
		"geometry": SELECTION_GEOMETRY_VOLUME_SCORE_ANCHOR,
		"record": record,
		"anchor_index": anchor_index,
		"topk": result.get("topk", record.get("topk", [])),
	}


## 射线点选 volume-score 锚点：胜出物体世界 AABB 命中优先，取最近；无命中回退锚点小球半径。
## 数据来自 provider（get_selectable_anchor_bounds / get_anchor_world_positions / get_anchor_marker_radius）。
func _pick_volume_score_anchor(provider: Node, cam: Camera3D, screen_pos: Vector2) -> int:
	if cam == null:
		return -1
	var ray_origin := cam.project_ray_origin(screen_pos)
	var ray_dir := cam.project_ray_normal(screen_pos).normalized()
	var best_idx := -1
	var best_t := INF
	if provider.has_method("get_selectable_anchor_bounds"):
		for b in provider.call("get_selectable_anchor_bounds"):
			if not (b is Dictionary):
				continue
			var raw_aabb = (b as Dictionary).get("aabb", null)
			if not (raw_aabb is AABB):
				continue
			var hit = (raw_aabb as AABB).intersects_ray(ray_origin, ray_dir)
			if hit is Vector3:
				var hp: Vector3 = hit
				var t := (hp - ray_origin).dot(ray_dir)
				if t >= 0.0 and t < best_t:
					best_t = t
					best_idx = int((b as Dictionary).get("anchor_index", -1))
	if best_idx >= 0:
		return best_idx
	if not provider.has_method("get_anchor_world_positions"):
		return -1
	var positions: PackedVector3Array = provider.call("get_anchor_world_positions")
	var radius := 4.0
	if provider.has_method("get_anchor_marker_radius"):
		radius = maxf(float(provider.call("get_anchor_marker_radius")) * 2.5, 0.1)
	var radius_sq := radius * radius
	var best_dist := INF
	for i in range(positions.size()):
		var world_pos := positions[i]
		if cam.is_position_behind(world_pos):
			continue
		var ray_t := (world_pos - ray_origin).dot(ray_dir)
		if ray_t < 0.0:
			continue
		var closest := ray_origin + ray_dir * ray_t
		var d := closest.distance_squared_to(world_pos)
		if d <= radius_sq and d < best_dist:
			best_dist = d
			best_idx = i
	return best_idx


func _cycle_volume_score_anchor_topk(delta: int) -> bool:
	if not SPAEditorContract.mode_is_active(_selection_mode, SelectionMode.ANCHOR):
		return false
	if not _has_volume_score_selection():
		return false
	var provider := _volume_score_provider_node()
	if provider == null or not provider.has_method("cycle_selected_anchor_topk"):
		return false
	var result = provider.call("cycle_selected_anchor_topk", delta)
	if not (result is Dictionary) or not bool(result.get("ok", false)):
		return false
	var record := _volume_score_selection_record(result)
	if not record.is_empty():
		_active_selection = record.duplicate(true)
	_update_anchor_sample_bounds_marker(record)
	_update_hud()
	return true


func _has_volume_score_selection() -> bool:
	var provider := _volume_score_provider_node()
	if provider != null and provider.has_method("has_selected_anchor"):
		return bool(provider.call("has_selected_anchor"))
	return false


func _volume_score_selection_record(selection_result: Dictionary = {}) -> Dictionary:
	var provider := _volume_score_provider_node()
	if provider == null:
		return {}
	if provider.has_method("get_selected_anchor_record"):
		var record = provider.call("get_selected_anchor_record")
		if record is Dictionary and not record.is_empty():
			return record.duplicate(true)
	if provider.has_method("has_selected_anchor") and not bool(provider.call("has_selected_anchor")):
		return {}
	var record := selection_result.duplicate(true)
	if record.is_empty():
		record["summary"] = get_selected_anchor_summary_text()
		record["tooltip"] = get_selected_anchor_tooltip_text()
	record["domain"] = SELECTION_DOMAIN_ANCHOR
	record["geometry"] = SELECTION_GEOMETRY_VOLUME_SCORE_ANCHOR
	if not record.has("id"):
		record["id"] = "volume_score_anchor:%d" % int(record.get("anchor_index", -1))
	return record


func _ensure_external_voxel_display_root() -> Node3D:
	if _external_voxel_display_root != null and is_instance_valid(_external_voxel_display_root):
		return _external_voxel_display_root
	var existing := get_node_or_null(NodePath(EXTERNAL_VOXEL_DISPLAY_ROOT_NAME)) as Node3D
	if existing != null:
		_external_voxel_display_root = existing
		return _external_voxel_display_root
	_external_voxel_display_root = Node3D.new()
	_external_voxel_display_root.name = EXTERNAL_VOXEL_DISPLAY_ROOT_NAME
	add_child(_external_voxel_display_root, true)
	return _external_voxel_display_root


func _external_voxel_display_owner_name(owner_key: String) -> String:
	return SPAEditorContract.external_voxel_display_owner_name(owner_key)


func _voxel_display_group(display_key: String) -> String:
	return SPAEditorContract.voxel_display_group(display_key)


func _apply_all_external_voxel_display_visibility() -> void:
	for display_key in _voxel_display_visible.keys():
		_apply_external_voxel_display_visibility(str(display_key))


func _apply_external_voxel_display_visibility(display_key: String) -> void:
	if _external_voxel_display_root == null or not is_instance_valid(_external_voxel_display_root):
		return
	_apply_voxel_display_group_visibility(
		_external_voxel_display_root,
		_voxel_display_group(display_key),
		_voxel_display_effective_visible(display_key)
	)


func _apply_voxel_display_group_visibility(node: Node, group_name: String, visible: bool) -> void:
	if node is Node3D and node.is_in_group(group_name):
		(node as Node3D).visible = visible
	for child in node.get_children():
		_apply_voxel_display_group_visibility(child, group_name, visible)


## 当前活动选中是否为 volume-score anchor（权威态在 provider，SPA 只持镜像）
func _active_selection_is_volume_score_anchor() -> bool:
	return str(_active_selection.get("geometry", "")) == SELECTION_GEOMETRY_VOLUME_SCORE_ANCHOR


## 当前活动选中的 GPU AutoObject 点云索引；非 autoobject 域返回 -1
func _active_selection_autoobject_index() -> int:
	if str(_active_selection.get("geometry", "")) == SELECTION_GEOMETRY_GPU_POINT:
		return int(_active_selection.get("object_index", -1))
	return -1


## 当前活动选中的 box marker / label 是否应显示。SPA 统一出 box（含 volume-score anchor）。
func _active_selection_box_visible() -> bool:
	if _active_selection.is_empty():
		return false
	var key := _voxel_display_key_for_domain(str(_active_selection.get("domain", "")))
	return key.is_empty() or _voxel_display_is_visible(key)


## Anchor-only sample bounds marker; providers must supply sample_bounds.
func _anchor_sample_bounds_visible(record: Dictionary) -> bool:
	if not show_anchor_sample_bounds:
		return false
	if not SPAEditorContract.mode_is_active(_selection_mode, SelectionMode.ANCHOR):
		return false
	if not _voxel_display_is_visible(SPAEditorContract.voxel_display_key_for_mode(SelectionMode.ANCHOR)):
		return false
	return str(record.get("domain", "")) == SELECTION_DOMAIN_ANCHOR and record.has("sample_bounds")


## Refresh the score-stage sample bounds marker; hidden outside anchor-pick modes.
func _update_anchor_sample_bounds_marker(record: Dictionary = {}) -> void:
	if not SPAEditorContract.mode_is_active(_selection_mode, SelectionMode.ANCHOR):
		_hide_node_if_valid(_anchor_sample_bounds_marker)
		return
	var source := record
	if source.is_empty() or str(source.get("geometry", "")) == SELECTION_GEOMETRY_VOLUME_SCORE_ANCHOR:
		var fresh_source := _volume_score_selection_record()
		if not fresh_source.is_empty():
			source = fresh_source
		elif source.is_empty() and _active_selection_is_volume_score_anchor():
			source = _active_selection
	if not _anchor_sample_bounds_visible(source):
		_hide_node_if_valid(_anchor_sample_bounds_marker)
		return
	var raw_bounds = source.get("sample_bounds", {})
	var aabb := _sample_bounds_aabb(raw_bounds)
	if aabb.size.length_squared() <= 0.000001:
		_hide_node_if_valid(_anchor_sample_bounds_marker)
		return
	_ensure_anchor_sample_bounds_marker()
	if _anchor_sample_bounds_marker == null:
		return
	_anchor_sample_bounds_marker.transform = _sample_bounds_transform(raw_bounds, aabb)
	_anchor_sample_bounds_marker.visible = true


## Oriented-box transform when the provider supplies obb_center/obb_size/obb_yaw;
## otherwise axis-aligned from the AABB. The marker mesh is a unit cube centered at
## the origin, so the basis carries scale (and yaw for the OBB), origin is the center.
func _sample_bounds_transform(raw_bounds, aabb: AABB) -> Transform3D:
	if raw_bounds is Dictionary:
		var b := raw_bounds as Dictionary
		var obb_size: Vector3 = b.get("obb_size", Vector3.ZERO)
		if bool(b.get("has_obb", false)) and obb_size.length_squared() > 0.000001:
			var obb_center: Vector3 = b.get("obb_center", aabb.position + aabb.size * 0.5)
			var obb_yaw := float(b.get("obb_yaw", 0.0))
			var basis := Basis.from_euler(Vector3(0.0, obb_yaw, 0.0)) * Basis.from_scale(obb_size)
			return Transform3D(basis, obb_center)
	return Transform3D(Basis.from_scale(aabb.size), aabb.position + aabb.size * 0.5)


## Accept either a direct AABB or a provider dictionary with position/size.
func _sample_bounds_aabb(raw_bounds) -> AABB:
	if raw_bounds is AABB:
		return raw_bounds
	if not (raw_bounds is Dictionary):
		return AABB()
	var bounds := raw_bounds as Dictionary
	if bounds.has("aabb") and bounds["aabb"] is AABB:
		return bounds["aabb"]
	var position: Vector3 = bounds.get("position", Vector3.ZERO)
	var size: Vector3 = bounds.get("size", Vector3.ZERO)
	return AABB(position, size)


## Reuse the existing selection marker mesh with a red transparent wire material.
func _ensure_anchor_sample_bounds_marker() -> void:
	var parent := _autoobject_overlay_root if _autoobject_overlay_root != null else self
	if _anchor_sample_bounds_marker == null or not is_instance_valid(_anchor_sample_bounds_marker):
		_anchor_sample_bounds_marker = _make_selection_marker("SelectedAnchorSampleBounds")
		parent.add_child(_anchor_sample_bounds_marker)
	_configure_selection_marker(_anchor_sample_bounds_marker)
	_anchor_sample_bounds_marker.material_override = _make_unshaded_material(
		ANCHOR_SAMPLE_BOUNDS_COLOR,
		false,
		true,
		true
	)


## 在编辑器选中列表中锚定当前节点
func _select_editor_selection_anchor_for_mode() -> void:
	if not Engine.is_editor_hint():
		return
	if _selection_mode == SelectionMode.MIXED:
		return
	var sel := EditorInterface.get_selection()
	sel.clear()
	sel.add_node(self)


## mode → Callable 拾取/记录派发表（直接方法引用，编译期检查），首次用到时惰性建立。
var _data_pick_callables: Dictionary = {}
var _data_record_callables: Dictionary = {}


## 用直接方法引用建立 mode → Callable 派发表，取代按字符串名 callv 动态派发。
## 好处：拾取/记录函数被改名/手误时，这里就是解析期 "Identifier not found" 报错，
## 而不是运行时 has_method 落空导致该模式静默点不中（无任何报错）。
func _ensure_selection_callables() -> void:
	if not _data_pick_callables.is_empty():
		return
	_data_pick_callables = {
		SelectionMode.SVTILE: _pick_svtile_record_with_camera,
		SelectionMode.ANCHOR: _pick_anchor_record_with_camera,
		SelectionMode.SV: _pick_sv_record_with_camera,
		SelectionMode.TARGETSV: _pick_targetsv_record_with_camera,
	}
	_data_record_callables = {
		SelectionMode.SVTILE: _svtile_record_for_voxel,
		SelectionMode.ANCHOR: _anchor_record_for_voxel,
		SelectionMode.SV: _sv_record_for_voxel,
		SelectionMode.TARGETSV: _targetsv_record_for_selection_voxel,
	}


## 按模式将体素坐标转为对应数据记录；AutoObject 没有体素直选记录，需走点云拾取
func _data_record_for_voxel(mode: int, raw_voxel: Vector3i) -> Dictionary:
	var mode_id := int(mode)
	_ensure_selection_callables()
	var cb: Callable = _data_record_callables.get(mode_id, Callable())
	if not cb.is_valid():
		return {}
	var voxel := _clamp_selection_voxel(raw_voxel) if _mode_requires_scene_voxel_committer(mode_id) else raw_voxel
	var result = cb.call(voxel)
	return result if result is Dictionary else {}


## 判断该选择模式是否依赖SceneVoxelCommitter运行时
func _mode_requires_scene_voxel_committer(mode_id: int) -> bool:
	return SPAEditorContract.mode_requires_scene_voxel_committer(mode_id)


## 将体素坐标限制在合法范围内
func _clamp_selection_voxel(voxel: Vector3i) -> Vector3i:
	if _sv_committer == null:
		var res := maxi(autoobject_grid_resolution, 1)
		return Vector3i(clampi(voxel.x, 0, res - 1), maxi(voxel.y, 0), clampi(voxel.z, 0, res - 1))
	var grid: Vector3i = _sv_committer.grid_size
	return Vector3i(
		clampi(voxel.x, 0, maxi(grid.x - 1, 0)),
		clampi(voxel.y, 0, maxi(grid.y - 1, 0)),
		clampi(voxel.z, 0, maxi(grid.z - 1, 0))
	)


## 清理上一次编辑器运行残留的子节点（含旧版 CPU 手动放置链遗留容器）
func _cleanup_editor_nodes() -> void:
	for name_str in GENERATED_EDITOR_NODE_NAMES:
		var old := get_node_or_null(NodePath(name_str))
		if old != null:
			_clear_scene_owner_recursive(old)
			var parent := old.get_parent()
			if parent != null:
				parent.remove_child(old)
			old.queue_free()


## 递归清除节点的场景所有者
func _clear_scene_owner_recursive(node: Node) -> void:
	if node == null:
		return
	node.owner = null
	for child in node.get_children():
		_clear_scene_owner_recursive(child)


# ---- SPA lifecycle ---------------------------------------------------------

## 初始化ScenePlacementActor及GPU运行时、SV提交器
func _init_spa() -> void:
	var t0 := Time.get_ticks_msec()
	_dispose_spa_components(false)
	_sv_committer = SceneVoxelCommitterScript.new(autoobject_grid_resolution, TerrainConfigScript.CAPTURE_SIZE, true)
	_spa = ScenePlacementActorScript.new()
	_spa.set_autoobject_runtime_capacity(autoobject_count)
	_spa.initialize(true, true, _sv_committer)
	var merged_report: Dictionary = _spa.get_merged_gpu_buffer_summary() if _spa.has_method("get_merged_gpu_buffer_summary") else {}
	_runtime_setup_result = merged_report.get("gpu_runtime_scene_voxel_setup", {})
	_initialized = _spa.is_initialized()
	_init_time_ms = float(Time.get_ticks_msec() - t0)
	print("[SPA Demo] %s (%.0f ms)" % ["OK" if _initialized else "FAILED", _init_time_ms])
	print("[SPA SVTile] Runtime setup: ok=%s reason=%s same_rd=%s max_objects=%d" % [
		str(_runtime_setup_result.get("ok", false)),
		str(_runtime_setup_result.get("reason", "")),
		str(_runtime_setup_result.get("same_rendering_device", false)),
		int(_runtime_setup_result.get("max_objects", 0)),
	])


## 释放SPA、GPU运行时、SV提交器资源
func _dispose_spa_components(sync_before_free: bool = false) -> void:
	if _voxel_pick_gpu != null:
		_voxel_pick_gpu.dispose(sync_before_free)
		_voxel_pick_gpu = null
	if _spa != null:
		_spa.dispose(sync_before_free)
		_spa = null
	if _sv_committer != null:
		_sv_committer.dispose(sync_before_free)
		_sv_committer = null
	_initialized = false
	_runtime_setup_result.clear()
	_reset_autoobject_runtime_state()


## 将所有网格资产注册到SPA并生成描述符
func _register_all_assets() -> void:
	_descriptors.clear()
	_profile_ids.clear()
	if not _initialized:
		return
	_spa.clear_assets()
	var t0 := Time.get_ticks_msec()
	var voxelizer = MeshVoxelizerGpuScript.new()
	for i in range(_meshes.size()):
		var color := DemoAssets.asset_color(i)
		var collision_samples := _collision_samples_from_mesh(voxelizer, _meshes[i], color)
		var descriptor := AutoObjectScript.create_voxel_descriptor(
			color, color.a, 1.0, collision_samples)
		_descriptors.append(descriptor)
		var pid: int = _spa.register_asset(descriptor, _meshes[i])
		_profile_ids.append(pid)
		print("[SPA Demo] Registered [%d] %s → profile_id=%d (%d collision voxels)" % [
			i, DemoAssets.asset_name(i, "?"), pid, collision_samples.size()])
	_register_time_ms = float(Time.get_ticks_msec() - t0)


## 用通用的 mesh 体素化路径为资产生成 per-voxel collision footprint samples
## （替代早期硬编码的 cylinder 基元）。每个实心体素 → 一条 point collision sample。
func _collision_samples_from_mesh(voxelizer, mesh: Mesh, color: Color) -> Array:
	var samples: Array = []
	if mesh == null:
		return samples
	var result: Dictionary = voxelizer.voxelize(mesh, maxi(asset_voxel_grid_count, 1), color, 0.9, 4)
	if not bool(result.get("ok", false)):
		push_warning("[SPA Demo] voxelize failed (%s); asset collision footprint is empty" % str(result.get("reason", "unknown")))
		return samples
	for v in result.get("voxels", []):
		var strength := float(v.get("collision", 0.0))
		if strength <= 0.0:
			continue
		samples.append(AutoVoxelProfileScript.make_collision_sample(v["voxel"], strength, 1.0))
	return samples


# ---- SVTile / GPU AutoObject runtime visualization ------------------------

## 运行SVTile+GPU AutoObject正式批量流程
func _run_gpu_autoobject_batch() -> void:
	_reset_autoobject_runtime_state()
	if not _initialized or _spa == null or _sv_committer == null:
		_autoobject_flush_result = {"ok": false, "reason": "spa_or_svtile_not_ready"}
		print("[SPA SVTile] SKIP: %s" % str(_autoobject_flush_result.get("reason", "")))
		return
	if _profile_ids.is_empty():
		_autoobject_spawn_result = {"ok": false, "reason": "no_registered_profiles"}
		print("[SPA SVTile] SKIP: no registered profiles")
		return

	if not _spa.is_autoobject_runtime_ready():
		_autoobject_spawn_result = {"ok": false, "reason": "gpu_autoobject_runtime_not_ready"}
		print("[SPA SVTile] FAIL: GPU AutoObject runtime not ready")
		return

	var tile_size := _svtile_tile_size()
	var tile_grid := _svtile_grid_size(tile_size)
	var tile_counts := PackedInt32Array()
	tile_counts.resize(tile_grid.x * tile_grid.y * tile_grid.z)
	_autoobject_positions.clear()
	_autoobject_asset_indices.clear()
	_autoobject_ids.clear()
	var spawn_records := _build_autoobject_spawn_records(tile_size, tile_grid, tile_counts, _autoobject_positions, _autoobject_asset_indices)
	_svtile_total_tile_count = tile_counts.size()
	_collect_svtile_ref_count_stats(tile_counts)

	var metadata_t0 := Time.get_ticks_msec()
	_sv_committer.mark_scene_voxel_tile_bounds_dirty(
		Vector3i.ZERO,
		_sv_committer.grid_size,
		{"auto": true, "object_refs": true},
		{"id": "spa_svtile_autoobject_batch", "source_id": "gpu_autoobject_batch"}
	)
	var uploaded: bool = _sv_committer.ensure_scene_voxel_tile_buffers_uploaded(true)
	var metadata_ms := Time.get_ticks_msec() - metadata_t0
	if not uploaded:
		_autoobject_flush_result = _sv_committer.get_scene_voxel_tile_gpu_buffer_summary()
		_autoobject_flush_result["ok"] = false
		_autoobject_flush_result["reason"] = str(_autoobject_flush_result.get("reason", "scene_voxel_tile_upload_failed"))
		print("[SPA SVTile] FAIL: tile metadata upload failed (%s)" % str(_autoobject_flush_result.get("reason", "")))
		return

	var spawn_t0 := Time.get_ticks_msec()
	_autoobject_spawn_result = _spa.spawn_autoobject_batch_from_accepted_placement_records(spawn_records, {
		"use_accepted_placement_record_shader": true,
	})
	_autoobject_spawn_time_ms = float(Time.get_ticks_msec() - spawn_t0)
	if not bool(_autoobject_spawn_result.get("ok", false)):
		print("[SPA SVTile] FAIL: spawn %d GPU AutoObjects failed: %s" % [
			spawn_records.size(),
			str(_autoobject_spawn_result.get("reason", "unknown")),
		])
		return
	_cache_autoobject_ids(_autoobject_spawn_result.get("object_ids", []))

	var flush_t0 := Time.get_ticks_msec()
	_autoobject_flush_result = _spa.flush_autoobject_runtime_to_scene_voxel_committer({})
	_autoobject_flush_time_ms = float(Time.get_ticks_msec() - flush_t0)
	_svtile_summary = _sv_committer.get_scene_voxel_tile_gpu_buffer_summary()

	if show_svtile_autoobject_overlay:
		var visual_t0 := Time.get_ticks_msec()
		_build_svtile_autoobject_overlay(tile_counts, _autoobject_positions, _autoobject_asset_indices, tile_grid, tile_size)
		_autoobject_visual_time_ms = float(Time.get_ticks_msec() - visual_t0)

	var spawned := int(_autoobject_spawn_result.get("spawned_count", 0))
	var inserted := int(_autoobject_flush_result.get("object_ref_inserted_slot_count", 0))
	var overflow := int(_autoobject_flush_result.get("object_ref_overflow_count", 0))
	_autoobject_runtime_ready = bool(_autoobject_flush_result.get("ok", false)) and inserted == spawned and overflow == 0
	print("[SPA SVTile] Metadata upload: ok=%s tiles=%d grid=%s tile_size=%s (%d ms)" % [
		str(uploaded), _svtile_total_tile_count, str(tile_grid), str(tile_size), metadata_ms,
	])
	print("[SPA SVTile] Spawned GPU AutoObjects: ok=%s count=%d shader=%s dispatch=%d time=%.0f ms" % [
		str(_autoobject_spawn_result.get("ok", false)),
		spawned,
		str(_autoobject_spawn_result.get("accepted_placement_record_shader_consumed", false)),
		int(_autoobject_spawn_result.get("accepted_placement_record_shader_dispatch_count", 0)),
		_autoobject_spawn_time_ms,
	])
	print("[SPA SVTile] Object refs flush: ok=%s inserted=%d touched=%d overflow=%d dirty_tiles=%d time=%.0f ms" % [
		str(_autoobject_flush_result.get("ok", false)),
		inserted,
		int(_autoobject_flush_result.get("object_ref_touched_count", 0)),
		overflow,
		int(_autoobject_flush_result.get("dirty_scene_voxel_tile_count", _svtile_summary.get("dirty_tile_count", 0))),
		_autoobject_flush_time_ms,
	])
	print("[SPA SVTile] Visualization: tiles=%d occupied=%d refs_per_tile avg=%.2f max=%d object_points=%d time=%.0f ms" % [
		_svtile_total_tile_count,
		_svtile_occupied_tile_count,
		(float(_svtile_total_refs) / float(maxi(_svtile_occupied_tile_count, 1))),
		_svtile_max_refs_per_tile,
		_autoobject_positions.size(),
		_autoobject_visual_time_ms,
	])


## 构建GPU AutoObject批量放置记录列表
func _build_autoobject_spawn_records(
	tile_size: Vector3i,
	tile_grid: Vector3i,
	tile_counts: PackedInt32Array,
	object_positions: Array[Vector3],
	object_asset_indices: Array[int]
) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	var requested_count := maxi(autoobject_count, 0)
	var grid_res := maxi(autoobject_grid_resolution, 1)
	var side_count := maxi(int(ceil(sqrt(float(maxi(requested_count, 1))))), 1)
	var spacing_voxels := maxi(int(floor(float(grid_res) / float(side_count))), 1)
	_autoobject_side_count = side_count
	_autoobject_spacing_voxels = spacing_voxels
	var flags := GPUAutoObjectRuntimeScript.OBJECT_FLAG_VISIBLE \
		| GPUAutoObjectRuntimeScript.OBJECT_FLAG_SOURCE \
		| GPUAutoObjectRuntimeScript.OBJECT_FLAG_DIRTY
	for i in range(requested_count):
		var px := i % side_count
		var pz := int(floor(float(i) / float(side_count)))
		var vx := clampi(px * spacing_voxels, 0, grid_res - 1)
		var vz := clampi(pz * spacing_voxels, 0, grid_res - 1)
		var voxel_min := Vector3i(vx, 0, vz)
		var voxel_max := voxel_min + Vector3i.ONE
		var asset_idx := i % _profile_ids.size()
		var world_pos := _autoobject_position_on_terrain(voxel_min)
		records.append({
			"profile_id": int(_profile_ids[asset_idx]),
			"object_type": asset_idx + 1,
			"object_flags": flags,
			"voxel_min": voxel_min,
			"voxel_max": voxel_max,
			"transform": Transform3D(Basis(), world_pos),
			"dirty_flags": {"auto": true, "object_refs": true},
			"asset_index": asset_idx,
			"result_index": i,
		})
		object_positions.append(world_pos)
		object_asset_indices.append(asset_idx)
		var tile_index := SceneVoxelTileCodecScript.tile_index_from_voxel(voxel_min, _scene_voxel_grid_size(), tile_size)
		if tile_index >= 0 and tile_index < tile_counts.size():
			tile_counts[tile_index] = tile_counts[tile_index] + 1
	return records


## 构建SVTile热力图和GPU AutoObject点云叠加层
func _build_svtile_autoobject_overlay(
	tile_counts: PackedInt32Array,
	object_positions: Array[Vector3],
	object_asset_indices: Array[int],
	tile_grid: Vector3i,
	tile_size: Vector3i
) -> void:
	if _autoobject_overlay_root == null:
		_autoobject_overlay_root = Node3D.new()
		_autoobject_overlay_root.name = SVTILE_AUTOOBJECT_OVERLAY_ROOT_NAME
		add_child(_autoobject_overlay_root, true)
	for child in _autoobject_overlay_root.get_children():
		child.queue_free()
	_clear_autoobject_overlay_refs()

	_svtile_heatmap = _make_tile_heatmap_multimesh(tile_counts, tile_grid, tile_size)
	_svtile_heatmap.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_autoobject_overlay_root.add_child(_svtile_heatmap)

	_autoobject_points = _make_object_points_multimesh(object_positions, object_asset_indices)
	_autoobject_points.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_autoobject_overlay_root.add_child(_autoobject_points)

	# 总览标题：非 billboard、放大字号；样式统一走 VoxelDebugLabel（保留原有 28 / 0.45 / 8 观感）
	_autoobject_overlay_label = VoxelDebugLabel.make(
		"SPA -> GPU AutoObject -> SVTile refs\n%d autoobjects / %d occupied tiles / max %d refs per tile" % [
			object_positions.size(),
			_svtile_occupied_tile_count,
			_svtile_max_refs_per_tile,
		],
		Color(0.95, 0.98, 1.0, 1.0),
		28,     # font_size
		0.0,    # width（不换行）
		0.45,   # pixel_size
		8,      # outline_size
		false,  # billboard（总览标题不面朝相机）
	)
	_autoobject_overlay_label.name = "SVTileAutoObjectLegend"
	_autoobject_overlay_label.position = _position_on_terrain_from_voxel_center(Vector3(12.0, 0.0, 12.0), 10.0)
	_autoobject_overlay_root.add_child(_autoobject_overlay_label)
	_ensure_selection_visual()
	_apply_selection_mode_visuals()


## 创建SVTile占用密度热力图的MultiMeshInstance3D（通过 VoxelDisplay）
func _make_tile_heatmap_multimesh(tile_counts: PackedInt32Array, tile_grid: Vector3i, tile_size: Vector3i) -> MultiMeshInstance3D:
	var transforms: Array[Transform3D] = []
	var colors := PackedColorArray()
	for tile_index in range(tile_counts.size()):
		var count := int(tile_counts[tile_index])
		if count <= 0:
			continue
		var tile_coord := SceneVoxelTileCodecScript.tile_coord_from_index(tile_index, tile_grid)
		var bounds := SceneVoxelTileCodecScript.tile_bounds(tile_coord, _scene_voxel_grid_size(), tile_size)
		var tile_min: Vector3i = bounds.get("voxel_min", Vector3i.ZERO)
		var tile_max: Vector3i = bounds.get("voxel_max", tile_min + Vector3i.ONE)
		var center_voxel := Vector3(
			(float(tile_min.x) + float(tile_max.x)) * 0.5,
			0.0,
			(float(tile_min.z) + float(tile_max.z)) * 0.5
		)
		var center := _position_on_terrain_from_voxel_center(center_voxel, 0.22)
		var size := Vector3(
			maxf(float(tile_max.x - tile_min.x) * _sv_committer.voxel_size.x * 0.88, 0.2),
			0.35,
			maxf(float(tile_max.z - tile_min.z) * _sv_committer.voxel_size.z * 0.88, 0.2)
		)
		transforms.append(Transform3D(Basis().scaled(size), center))
		colors.append(_svtile_ref_color(count))
	return VoxelDisplay.build_from_transforms(transforms, colors, {
		"name": "SVTileHeatmap", "unshaded": true, "no_depth_test": true})


## 创建GPU AutoObject点云可视化的MultiMeshInstance3D（通过 VoxelDisplay）
func _make_object_points_multimesh(object_positions: Array[Vector3], object_asset_indices: Array[int]) -> MultiMeshInstance3D:
	var transforms: Array[Transform3D] = []
	var colors := PackedColorArray()
	var point_size := _autoobject_point_size()
	var scale := Vector3(point_size, point_size * 1.8, point_size)
	for i in range(object_positions.size()):
		transforms.append(Transform3D(Basis().scaled(scale), object_positions[i]))
		var asset_idx := int(object_asset_indices[i]) if i < object_asset_indices.size() else 0
		colors.append(_autoobject_color(asset_idx))
	return VoxelDisplay.build_from_transforms(transforms, colors, {
		"name": "GPUAutoObjectPoints", "unshaded": true, "no_depth_test": true})


## 缓存GPU批量生成的object_id列表
func _cache_autoobject_ids(raw_ids) -> void:
	_autoobject_ids.clear()
	if raw_ids == null:
		return
	if not (raw_ids is Array) and not (raw_ids is PackedInt32Array):
		return
	for raw_id in raw_ids:
		_autoobject_ids.append(int(raw_id))


## 确保统一选中 marker/label 节点存在（所有点选域共用一套）
func _ensure_selection_visual() -> void:
	var parent := _autoobject_overlay_root if _autoobject_overlay_root != null else self
	if _selection_marker == null or not is_instance_valid(_selection_marker):
		_selection_marker = _make_selection_marker("SelectedVoxelMarker")
		parent.add_child(_selection_marker)
	_configure_selection_marker(_selection_marker)
	if _selection_label == null or not is_instance_valid(_selection_label):
		_selection_label = _make_selection_label("SelectedVoxelLabel")
		parent.add_child(_selection_label)


## 创建一个选中标记用的线框 Box 节点
func _make_selection_marker(node_name: String) -> MeshInstance3D:
	var marker := MeshInstance3D.new()
	marker.name = node_name
	_configure_selection_marker(marker)
	marker.visible = false
	return marker


## 确保旧编辑器会话里已存在的选中标记也切换到线框
func _configure_selection_marker(marker: MeshInstance3D) -> void:
	if marker == null:
		return
	if not (marker.mesh is ImmediateMesh):
		marker.mesh = _make_selection_wire_box_mesh()
	if marker.material_override == null:
		marker.material_override = _make_selection_material()
	marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## 创建单位立方体线框 Mesh；调用方通过 MeshInstance scale 控制实际尺寸
func _make_selection_wire_box_mesh() -> ImmediateMesh:
	var half := 0.5
	var corners := [
		Vector3(-half, -half, -half),
		Vector3(half, -half, -half),
		Vector3(half, -half, half),
		Vector3(-half, -half, half),
		Vector3(-half, half, -half),
		Vector3(half, half, -half),
		Vector3(half, half, half),
		Vector3(-half, half, half),
	]
	var edges := [
		[0, 1], [1, 2], [2, 3], [3, 0],
		[4, 5], [5, 6], [6, 7], [7, 4],
		[0, 4], [1, 5], [2, 6], [3, 7],
	]
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for edge in edges:
		mesh.surface_add_vertex(corners[int(edge[0])])
		mesh.surface_add_vertex(corners[int(edge[1])])
	mesh.surface_end()
	return mesh


## 创建一个选中标签用的 Label3D 节点
func _make_selection_label(node_name: String, modulate: Color = Color.WHITE) -> Label3D:
	# 统一样式来自 VoxelDebugLabel（默认即体素悬浮字：24 / 0.16 / 6 + billboard + 底边对齐）
	var label := VoxelDebugLabel.make("", modulate)
	label.name = node_name
	label.visible = false
	return label


## 创建无光照透明材质的统一工厂
func _make_unshaded_material(albedo: Color, use_vertex_color: bool, no_depth_test: bool, cull_disabled: bool = true) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = albedo
	mat.vertex_color_use_as_albedo = use_vertex_color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED if cull_disabled else BaseMaterial3D.CULL_BACK
	mat.no_depth_test = no_depth_test
	return mat


## 创建无光照高亮选中材质
func _make_selection_material() -> StandardMaterial3D:
	return _make_unshaded_material(Color(1.0, 0.9, 0.08, 0.92), false, true, true)


## 设置GPU AutoObject点云中单个实例的颜色。点云实例数据只存在于 GPU 缓冲
## （VoxelDisplay GPU 直写），必须经 writer 改色；MultiMesh.set_instance_color
## 会以全零 CPU cache 整块回传，抹掉同一脏区内所有实例的 transform。
func _set_autoobject_instance_color(object_index: int, color: Color) -> void:
	if _autoobject_points == null or not is_instance_valid(_autoobject_points):
		return
	VoxelDisplay.write_instance_color(_autoobject_points, object_index, color)


## 若节点有效则隐藏它
func _hide_node_if_valid(node: Node) -> void:
	if node != null and is_instance_valid(node):
		node.visible = false


## 清除当前活动选中：恢复点云染色、隐藏 marker/label、（可选）清 provider anchor。
## clear_provider=false 用于"在 provider 上选中 anchor 之前"——保留 provider 待随即选中。
func clear_active_selection(update_hud: bool = true, clear_provider: bool = true) -> void:
	var prev_index := _active_selection_autoobject_index()
	if prev_index >= 0:
		_set_autoobject_instance_color(prev_index, _autoobject_color(_safe_asset_index(prev_index)))
	_active_selection.clear()
	_hide_node_if_valid(_selection_marker)
	_hide_node_if_valid(_selection_label)
	if clear_provider:
		var provider := _volume_score_provider_node()
		if provider != null and provider.has_method("clear_selected_anchor"):
			provider.call("clear_selected_anchor")
	_hide_node_if_valid(_anchor_sample_bounds_marker)
	if update_hud:
		_update_hud()


## 唯一选中写入口：清旧 → 存 record → 可视反馈 → 编辑器同步 → print → 刷新。
## 各点选域 picker 只负责产出 record 并调用本函数收尾。volume-score anchor 走
## provider 回调（refresh_volume_score_anchor_selection），不经过这里。
func set_active_selection(record: Dictionary) -> void:
	if record.is_empty():
		return
	clear_active_selection(false)
	_active_selection = record.duplicate(true)
	# 域特有副作用：GPU AutoObject 给点云实例染高亮色
	var object_index := _active_selection_autoobject_index()
	if object_index >= 0:
		_set_autoobject_instance_color(object_index, SELECT_COLOR)
	_apply_selection_visual(_active_selection)
	_sync_editor_selection()
	_print_active_selection(_active_selection)
	_apply_selection_mode_visuals()
	_update_hud()


## 按统一 record 刷新选中可视：线框 box marker + Label3D + （anchor）sample-bounds。
## 几何形状决定摆位：gpu_point 顶在点云上方，voxel 直接落在 world_position。
func _apply_selection_visual(record: Dictionary) -> void:
	var geometry := str(record.get("geometry", ""))
	_ensure_selection_visual()
	var color := _selection_domain_color(str(record.get("domain", "data")))
	var marker_pos: Vector3
	var marker_scale: Vector3
	var label_pos: Vector3
	if geometry == SELECTION_GEOMETRY_GPU_POINT:
		var base: Vector3 = record.get("position", Vector3.ZERO)
		var s := _autoobject_point_size() * 2.4
		marker_pos = base + Vector3(0.0, s * 0.45, 0.0)
		marker_scale = Vector3(s, s * 1.8, s)
	else:
		var base: Vector3 = record.get("world_position", Vector3.ZERO)
		var size: Vector3 = record.get("marker_size", _default_voxel_marker_size())
		marker_pos = base
		marker_scale = size
	# 标签统一贴在 marker box 顶面正上方：水平居中于体素中心、竖直落在头顶
	label_pos = _selection_label_top_position(marker_pos, marker_scale)
	if _selection_marker != null:
		_selection_marker.position = marker_pos
		_selection_marker.scale = marker_scale
		var mat := _selection_marker.material_override as StandardMaterial3D
		if mat != null:
			mat.albedo_color = color
		_selection_marker.visible = true
	if _selection_label != null:
		_selection_label.position = label_pos
		_selection_label.modulate = color
		_selection_label.text = _format_selection_label(record)
		_selection_label.visible = true
	_update_anchor_sample_bounds_marker(record)


## 标签锚点：marker box 顶面 + 少量净空，水平居中于体素中心。
## 配合 Label3D 底边对齐，文字底部正好贴在体素头顶再向上生长。
func _selection_label_top_position(marker_pos: Vector3, marker_scale: Vector3) -> Vector3:
	var top_y := marker_pos.y + marker_scale.y * 0.5
	var clearance := maxf(marker_scale.y * 0.25, 0.4)
	return Vector3(marker_pos.x, top_y + clearance, marker_pos.z)


## 把活动选中同步到编辑器 Selection（锚定到 marker，缺失时退回自身）
func _sync_editor_selection() -> void:
	if not Engine.is_editor_hint():
		return
	var sel := EditorInterface.get_selection()
	sel.clear()
	if _selection_marker != null and is_instance_valid(_selection_marker):
		sel.add_node(_selection_marker)
	else:
		sel.add_node(self)


## 打印活动选中（保留各域原有日志前缀）
func _print_active_selection(record: Dictionary) -> void:
	if str(record.get("geometry", "")) == SELECTION_GEOMETRY_GPU_POINT:
		print("[SPA SVTile] Selected GPU AutoObject: index=%d object_id=%d tile=%s profile_id=%d pos=%s" % [
			int(record.get("object_index", -1)),
			int(record.get("object_id", -1)),
			str(record.get("tile_coord", Vector3i.ZERO)),
			int(record.get("profile_id", -1)),
			str(record.get("position", Vector3.ZERO)),
		])
	else:
		print("[SPA Selection] Selected %s: %s" % [
			str(record.get("domain", "data")),
			str(record.get("id", "")),
		])


## 获取默认体素标记框尺寸
func _default_voxel_marker_size() -> Vector3:
	if _sv_committer == null:
		return Vector3.ONE * 2.0
	return Vector3(
		maxf(_sv_committer.voxel_size.x * 0.9, 0.25),
		maxf(_sv_committer.voxel_size.y * 0.9, 0.5),
		maxf(_sv_committer.voxel_size.z * 0.9, 0.25)
	)


## 根据选中域类型返回对应高亮颜色
func _selection_domain_color(domain: String) -> Color:
	match domain:
		SELECTION_DOMAIN_SVTILE:
			return Color(0.1, 0.65, 1.0, 0.92)
		SELECTION_DOMAIN_SV:
			return Color(0.1, 1.0, 0.62, 0.92)
		SELECTION_DOMAIN_TARGETSV:
			return Color(1.0, 0.28, 0.95, 0.92)
		SELECTION_DOMAIN_ANCHOR:
			return Color(1.0, 0.64, 0.1, 0.95)
	return SELECT_COLOR


## 统一的选中 marker 标签文本（表驱动，autoobject 与各数据域共用）
func _format_selection_label(record: Dictionary) -> String:
	var domain := str(record.get("domain", "data"))
	var voxel: Vector3i = record.get("voxel_coord", Vector3i.ZERO)
	var tile: Vector3i = record.get("tile_coord", Vector3i.ZERO)
	if str(record.get("geometry", "")) == SELECTION_GEOMETRY_GPU_POINT:
		return "GPU AutoObject %d\nobject_id=%d  tile=%s" % [
			int(record.get("object_index", -1)),
			int(record.get("object_id", -1)),
			str(tile),
		]
	if str(record.get("geometry", "")) == SELECTION_GEOMETRY_VOLUME_SCORE_ANCHOR:
		var lines := PackedStringArray(["Anchor #%d %s" % [int(record.get("anchor_index", -1)), str(voxel)]])
		for entry in record.get("topk", []):
			if not (entry is Dictionary):
				continue
			var e := entry as Dictionary
			var sc := float(e.get("score", -INF))
			var sc_text := ("%.2f" % sc) if sc > -1.0e20 else "n/a"
			var mark := "*" if bool(e.get("selected", false)) else " "
			var valid_suffix := "" if bool(e.get("valid", false)) else " invalid"
			lines.append("%s#%d %s  %s  yaw=%.0f%s" % [
				mark, int(e.get("rank", 0)), str(e.get("asset_name", "?")), sc_text, float(e.get("yaw", 0.0)), valid_suffix])
		return "\n".join(lines)
	match domain:
		SELECTION_DOMAIN_SVTILE:
			return "SVTile %s\nrefs=%d  voxel=%s" % [
				str(tile),
				int(record.get("object_ref_count", 0)),
				str(voxel),
			]
		SELECTION_DOMAIN_SV:
			return "SceneVoxel %s\ncomplexity=%.3f collision=%.3f" % [
				str(voxel),
				float(record.get("complexity", 0.0)),
				float(record.get("collision", 0.0)),
			]
		SELECTION_DOMAIN_TARGETSV:
			return "TargetSV %s\ncomplexity=%.3f collision=%.3f" % [
				str(voxel),
				float(record.get("complexity", 0.0)),
				float(record.get("collision", 0.0)),
			]
		SELECTION_DOMAIN_ANCHOR:
			return "Anchor %s\nkind=%s" % [
				str(voxel),
				str(record.get("anchor_kind", "candidate")),
			]
	return "%s %s" % [domain, str(record.get("id", ""))]


## 获取选中记录对应的可视节点引用
func _selection_record_visual_node(record: Dictionary) -> Node:
	var domain := str(record.get("domain", ""))
	if domain == SELECTION_DOMAIN_TARGETSV:
		var targetsv := _find_targetsv_setup()
		if targetsv != null:
			var display := targetsv.get_node_or_null("TargetSVVoxels")
			return display if display != null else targetsv
	if domain == SELECTION_DOMAIN_SVTILE or domain == SELECTION_DOMAIN_SV or domain == SELECTION_DOMAIN_ANCHOR:
		return _svtile_heatmap if _svtile_heatmap != null else _autoobject_overlay_root
	return null


## 在场景树中查找TargetSVSetup节点
func _find_targetsv_setup() -> Node:
	if not is_inside_tree():
		return null
	var root := get_tree().edited_scene_root if get_tree() != null else null
	return TargetSVLookup.find_setup(self, root, true, false, true)


## 按网格索引选中GPU AutoObject（API入口）
func select_autoobject_by_index(object_index: int = -1) -> Dictionary:
	if not _autoobject_runtime_ready:
		return {"ok": false, "reason": "autoobject_runtime_not_ready"}
	if _autoobject_positions.is_empty():
		return {"ok": false, "reason": "no_autoobjects"}
	var idx := object_index
	if idx < 0:
		idx = int(floor(float(_autoobject_positions.size()) * 0.5))
	idx = clampi(idx, 0, _autoobject_positions.size() - 1)
	var selection := _make_autoobject_selection_record(idx, 0.0)
	set_active_selection(selection)
	return {
		"ok": true,
		"probe_index": idx,
		"selected_index": int(selection.get("object_index", -1)),
		"object_id": int(selection.get("object_id", -1)),
		"asset_index": int(selection.get("asset_index", -1)),
		"profile_id": int(selection.get("profile_id", -1)),
		"tile_coord": selection.get("tile_coord", Vector3i.ZERO),
		"position": selection.get("position", Vector3.ZERO),
	}


## 根据当前选择模式淡化非相关几何体；这只影响显示焦点，不改变拾取优先级
func _apply_selection_mode_visuals() -> void:
	for binding in _selection_mode_visual_bindings():
		_apply_selection_mode_visual_binding(binding)
	_apply_autoobject_overlay_label_visual()
	_apply_targetsv_visuals(
		_selection_mode_focuses(SelectionMode.TARGETSV),
		SPAEditorContract.voxel_display_key_for_mode(SelectionMode.TARGETSV)
	)
	var box_visible := _active_selection_box_visible()
	if _selection_marker != null:
		_selection_marker.visible = box_visible
		_selection_marker.transparency = 0.0
	if _selection_label != null:
		_selection_label.visible = box_visible
	_update_anchor_sample_bounds_marker()
	_apply_all_external_voxel_display_visibility()


func _selection_mode_visual_bindings() -> Array[Dictionary]:
	return [
		{
			"node": _autoobject_points,
			"display_key": SPAEditorContract.voxel_display_key_for_mode(SelectionMode.AUTOOBJECT),
			"mode": SelectionMode.AUTOOBJECT,
		},
		{
			"node": _svtile_heatmap,
			"display_key": SPAEditorContract.voxel_display_key_for_mode(SelectionMode.SVTILE),
			"focus_modes": SPAEditorContract.SVTILE_OVERLAY_FOCUS_MODES,
		},
	]


func _apply_selection_mode_visual_binding(binding: Dictionary) -> void:
	var node := binding.get("node") as GeometryInstance3D
	if node == null:
		return
	var display_key := str(binding.get("display_key", ""))
	node.visible = _voxel_display_effective_visible(display_key)
	node.transparency = 0.0 if _selection_mode_visual_focused(binding) else SELECTION_FADED_TRANSPARENCY


func _selection_mode_visual_focused(binding: Dictionary) -> bool:
	if binding.has("focus_modes"):
		return _selection_mode_focuses_any(binding.get("focus_modes", []))
	return _selection_mode_focuses(int(binding.get("mode", -1)))


func _selection_mode_focuses(mode_id: int) -> bool:
	return SPAEditorContract.mode_is_active(_selection_mode, mode_id)


func _selection_mode_focuses_any(mode_ids: Array) -> bool:
	return SPAEditorContract.mode_in_list(_selection_mode, mode_ids)


func _apply_autoobject_overlay_label_visual() -> void:
	if _autoobject_overlay_label == null:
		return
	var gpu_objects_visible := _voxel_display_effective_visible(SPAEditorContract.voxel_display_key_for_mode(SelectionMode.AUTOOBJECT))
	var svtile_visible := _voxel_display_effective_visible(SPAEditorContract.voxel_display_key_for_mode(SelectionMode.SVTILE))
	var label_color := _autoobject_overlay_label.modulate
	_autoobject_overlay_label.visible = gpu_objects_visible or svtile_visible
	label_color.a = 1.0 if _selection_mode_focuses_any(SPAEditorContract.SVTILE_OVERLAY_FOCUS_MODES) else 0.25
	_autoobject_overlay_label.modulate = label_color


## 设置TargetSV体素显示状态和透明度
func _apply_targetsv_visuals(target_focus: bool, target_key: String = "") -> void:
	var targetsv := _find_targetsv_setup()
	if targetsv == null:
		return
	if target_key.is_empty():
		target_key = SPAEditorContract.voxel_display_key_for_mode(SelectionMode.TARGETSV)
	var target_visible := _voxel_display_effective_visible(target_key)
	if targetsv.has_method("set_display_visible"):
		targetsv.set_display_visible(target_visible)
	var display := targetsv.get_node_or_null("TargetSVVoxels")
	if display != null:
		display.visible = target_visible
	if display is GeometryInstance3D:
		(display as GeometryInstance3D).transparency = 0.0 if target_focus else SELECTION_FADED_TRANSPARENCY


## 根据SVTile引用密度计算热力图颜色
func _svtile_ref_color(ref_count: int) -> Color:
	var density := clampf(float(ref_count) / float(maxi(SceneVoxelCommitterScript.SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT, 1)), 0.0, 1.0)
	return Color(0.12 + density * 0.85, 0.58 + density * 0.35, 0.95 - density * 0.55, 0.34 + density * 0.36)


## 越界安全地取得对象的资产索引
func _safe_asset_index(object_index: int) -> int:
	return _autoobject_asset_indices[object_index] if object_index >= 0 and object_index < _autoobject_asset_indices.size() else 0


## 根据资产索引获取GPU点云颜色
func _autoobject_color(asset_idx: int) -> Color:
	var color := DemoAssets.wire_color(asset_idx % maxi(DemoAssets.count(), 1))
	color.a = 0.96
	return color


## 统计SVTile占用数、最大引用数等指标
func _collect_svtile_ref_count_stats(tile_counts: PackedInt32Array) -> void:
	_svtile_occupied_tile_count = 0
	_svtile_max_refs_per_tile = 0
	_svtile_total_refs = 0
	for count in tile_counts:
		var c := int(count)
		if c <= 0:
			continue
		_svtile_occupied_tile_count += 1
		_svtile_total_refs += c
		_svtile_max_refs_per_tile = maxi(_svtile_max_refs_per_tile, c)


## 从项目设置读取SVTile尺寸
func _svtile_tile_size() -> Vector3i:
	return SceneVoxelTileCodecScript.configured_size(
		SceneVoxelCommitterScript.SCENE_VOXEL_TILE_SIZE_SETTING,
		SceneVoxelCommitterScript.DEFAULT_SCENE_VOXEL_TILE_SIZE
	)


## 当前SPA GPU AutoObject运行时使用的SceneVoxel网格尺寸
func _scene_voxel_grid_size() -> Vector3i:
	if _sv_committer != null:
		return _sv_committer.grid_size
	return Vector3i(autoobject_grid_resolution, 1, autoobject_grid_resolution)


## 根据体素网格计算SVTile网格维度
func _svtile_grid_size(tile_size: Vector3i) -> Vector3i:
	return SceneVoxelTileCodecScript.tile_grid_size(_scene_voxel_grid_size(), tile_size)


## 根据网格索引反算体素最小坐标
func _autoobject_voxel_min_from_index(object_index: int) -> Vector3i:
	if _autoobject_side_count <= 0:
		return Vector3i.ZERO
	var px := object_index % _autoobject_side_count
	var pz := int(floor(float(object_index) / float(_autoobject_side_count)))
	return Vector3i(
		clampi(px * _autoobject_spacing_voxels, 0, autoobject_grid_resolution - 1),
		0,
		clampi(pz * _autoobject_spacing_voxels, 0, autoobject_grid_resolution - 1)
	)


## 获取指定网格索引的GPU对象ID
func _autoobject_id_for_index(object_index: int) -> int:
	if object_index >= 0 and object_index < _autoobject_ids.size():
		return int(_autoobject_ids[object_index])
	return object_index


func _ensure_voxel_pick_gpu() -> bool:
	if _voxel_pick_gpu == null:
		_voxel_pick_gpu = VoxelPickGPUScript.new()
	if _voxel_pick_gpu == null:
		return false
	return _voxel_pick_gpu.ensure_device(true, true)


## 通过射线+屏幕投影拾取最近的GPU AutoObject
func _pick_autoobject_with_camera(cam: Camera3D, screen_pos: Vector2) -> Dictionary:
	if not _selection_allows_gpu_autoobjects() or not _autoobject_runtime_ready:
		return {}
	if cam == null or _autoobject_positions.is_empty():
		return {}
	var terrain_hit := _pick_voxel_hit_with_camera(cam, screen_pos) if _sv_committer != null else {}
	if _sv_committer != null and not terrain_hit.is_empty():
		var local_hit := _nearest_autoobject_at_world(
			terrain_hit.get("world_position", Vector3.ZERO),
			cam,
			screen_pos
		)
		if not local_hit.is_empty():
			return local_hit
	return _nearest_autoobject_on_screen(cam, screen_pos, gpu_autoobject_pick_radius_px)


## 按当前模式分派到对应数据域拾取器。
## AutoObject 不在这里处理；它在 _select_current_mode_at_screen_position() 中
## 先走 GPU 点云拾取。Mixed 的数据域 fallback 只尝试 TargetSV -> SVTile，
## 避免一次点击在所有体素域之间产生含糊选择。
func _pick_data_selection_record_with_camera(cam: Camera3D, screen_pos: Vector2) -> Dictionary:
	for mode_id in SPAEditorContract.data_pick_modes_for_selection_mode(_selection_mode):
		var allow_empty_fallback := not (_selection_mode == SelectionMode.MIXED and int(mode_id) == SelectionMode.TARGETSV)
		var hit := _pick_bound_data_selection_record(int(mode_id), cam, screen_pos, allow_empty_fallback)
		if not hit.is_empty():
			return hit
	return {}


## 通过合同表检查显示/依赖后调用对应体素域拾取器
func _pick_bound_data_selection_record(mode_id: int, cam: Camera3D, screen_pos: Vector2, allow_empty_fallback: bool = true) -> Dictionary:
	var display_key := SPAEditorContract.voxel_display_key_for_mode(mode_id)
	if not display_key.is_empty() and not _voxel_display_is_visible(display_key):
		return {}
	if _mode_requires_scene_voxel_committer(mode_id) and _sv_committer == null:
		return {}
	if mode_id == SelectionMode.ANCHOR and _volume_score_anchor_display_active():
		return {}
	_ensure_selection_callables()
	var cb: Callable = _data_pick_callables.get(mode_id, Callable())
	if not cb.is_valid():
		return {}
	var result: Variant
	if mode_id == SelectionMode.TARGETSV and not allow_empty_fallback:
		result = cb.call(cam, screen_pos, false)
	else:
		result = cb.call(cam, screen_pos)
	return result if result is Dictionary else {}


## 射线命中地形并返回世界坐标和体素坐标
func _pick_voxel_hit_with_camera(cam: Camera3D, screen_pos: Vector2) -> Dictionary:
	if cam == null:
		return {}
	var gpu_hit := _pick_voxel_hit_gpu(cam, screen_pos)
	if not gpu_hit.is_empty():
		return gpu_hit
	var terrain_hit := _ray_to_terrain(cam, screen_pos)
	var world_pos: Vector3
	if terrain_hit.is_empty():
		world_pos = _ray_xz_plane_cam(cam, screen_pos, 0.0)
		if not _position_in_capture_xz(world_pos):
			return {}
	else:
		world_pos = terrain_hit.get("position", Vector3.ZERO)
	var voxel := _world_to_selection_voxel(world_pos)
	return {
		"screen_pos": screen_pos,
		"world_position": world_pos,
		"voxel_coord": voxel,
		"pick_backend": "cpu_fallback",
	}


## 世界坐标→限制在有效范围的体素坐标
## GPU 拾取不可用时是否已提示过（节流，避免每次点击刷屏）。
var _warned_gpu_pick_unavailable := false


## GPU 拾取设备/管线不可用时，点选会静默回落 CPU 射线（可能命中与 GPU 不同的体素），
## 之前无任何提示 → "选中错误体素"很难排查。首次不可用时 push_warning 一次让它不再隐形；
## 恢复可用时清标志以便下次掉了再提示。
func _ensure_voxel_pick_gpu_or_warn() -> bool:
	if _ensure_voxel_pick_gpu():
		_warned_gpu_pick_unavailable = false
		return true
	if not _warned_gpu_pick_unavailable:
		_warned_gpu_pick_unavailable = true
		push_warning("[SPA Selection] GPU 体素拾取不可用，点选回落到 CPU 射线（可能与 GPU 命中不同的体素）。")
	return false


func _pick_voxel_hit_gpu(cam: Camera3D, screen_pos: Vector2) -> Dictionary:
	if cam == null:
		return {}
	if _terrain_field.is_empty() or _terrain_field_res <= 0:
		_cache_terrain_field()
	if not _ensure_voxel_pick_gpu_or_warn():
		return {}
	var capture := TerrainConfigScript.CAPTURE_SIZE
	var res := maxi(autoobject_grid_resolution, 1)
	var grid_origin := VoxelGeneral.default_grid_origin(capture)
	var grid_size := Vector3i(res, 1, res)
	var voxel_size := VoxelGeneral.voxel_size_for_resolution(capture, res, 1.0)
	if _sv_committer != null:
		grid_origin = _sv_committer.grid_origin
		grid_size = _sv_committer.grid_size
		voxel_size = _sv_committer.voxel_size
	var result: Dictionary = _voxel_pick_gpu.pick_scene_voxel(
		cam.project_ray_origin(screen_pos),
		cam.project_ray_normal(screen_pos),
		_terrain_field,
		_terrain_field_res,
		grid_origin,
		grid_size,
		voxel_size,
		capture,
		TerrainConfigScript.MAX_HEIGHT,
		_autoobject_point_size() * 0.4
	)
	if not bool(result.get("ok", false)):
		return {}
	return {
		"screen_pos": screen_pos,
		"world_position": result.get("world_position", Vector3.ZERO),
		"voxel_coord": result.get("voxel_coord", Vector3i.ZERO),
		"pick_backend": str(result.get("pick_backend", "gpu_compute")),
		"gpu_score": float(result.get("screen_score", 0.0)),
	}


func _world_to_selection_voxel(world_pos: Vector3) -> Vector3i:
	if _sv_committer != null:
		var voxel: Vector3i = _sv_committer.world_to_voxel(world_pos, autoobject_grid_resolution)
		var grid: Vector3i = _sv_committer.grid_size
		return Vector3i(
			clampi(voxel.x, 0, maxi(grid.x - 1, 0)),
			clampi(voxel.y, 0, maxi(grid.y - 1, 0)),
			clampi(voxel.z, 0, maxi(grid.z - 1, 0))
		)
	var capture := TerrainConfigScript.CAPTURE_SIZE
	var res := maxi(autoobject_grid_resolution, 1)
	return VoxelGeneral.world_to_voxel(
		world_pos,
		VoxelGeneral.default_grid_origin(capture),
		VoxelGeneral.voxel_size_for_resolution(capture, res, 1.0),
		Vector3i(res, 1, res)
	)


## 拾取相机点击处体素并交给指定构建器生成记录
func _pick_record_via_voxel(cam: Camera3D, screen_pos: Vector2, record_builder: Callable) -> Dictionary:
	if _sv_committer == null:
		return {}
	var hit := _pick_voxel_hit_with_camera(cam, screen_pos)
	if hit.is_empty():
		return {}
	var voxel: Vector3i = hit.get("voxel_coord", Vector3i.ZERO)
	var record: Dictionary = record_builder.call(voxel)
	if not record.is_empty():
		record["pick_backend"] = str(hit.get("pick_backend", ""))
		record["pick_world_position"] = hit.get("world_position", record.get("world_position", Vector3.ZERO))
		record["pick_screen_pos"] = screen_pos
	return record


## 拾取相机点击处的SVTile记录
func _pick_svtile_record_with_camera(cam: Camera3D, screen_pos: Vector2) -> Dictionary:
	return _pick_record_via_voxel(cam, screen_pos, _svtile_record_for_voxel)


## 为指定体素构建SVTile选中记录
func _svtile_record_for_voxel(voxel: Vector3i) -> Dictionary:
	var tile := _tile_info_for_voxel(voxel)
	var tile_size: Vector3i = tile.get("size", Vector3i.ONE)
	var tile_coord: Vector3i = tile.get("coord", Vector3i.ZERO)
	var tile_index := int(tile.get("index", -1))
	var tile_record: Dictionary = _sv_committer.get_scene_voxel_tile(tile_coord) if _sv_committer != null else {}
	var object_refs := SceneVoxelTileCodecScript.object_ref_count(tile_record)
	var marker := _svtile_marker_transform(tile_coord, tile_size)
	return {
		"domain": SELECTION_DOMAIN_SVTILE,
		"geometry": SELECTION_GEOMETRY_VOXEL,
		"id": "svtile:%s" % str(tile_coord),
		"world_position": marker.get("position", _selection_voxel_marker_position(voxel, 1.0)),
		"marker_size": marker.get("size", _default_voxel_marker_size()),
		"voxel_coord": voxel,
		"tile_coord": tile_coord,
		"tile_index": tile_index,
		"tile_record": tile_record,
		"object_ref_count": object_refs,
		"payload": tile_record,
	}


## 拾取相机点击处的SceneVoxel记录
func _pick_sv_record_with_camera(cam: Camera3D, screen_pos: Vector2) -> Dictionary:
	return _pick_record_via_voxel(cam, screen_pos, _sv_record_for_voxel)


## 为指定体素构建SceneVoxel选中记录
func _sv_record_for_voxel(voxel: Vector3i) -> Dictionary:
	var hit_pos := _selection_voxel_marker_position(voxel, 0.0)
	var scene_voxel: Dictionary = _sv_committer.get_scene_voxel(voxel.y, Vector2i(voxel.x, voxel.z)) if _sv_committer != null else {}
	var query: Dictionary = _sv_committer.query_voxel(hit_pos.x, hit_pos.z, 0.0) if _sv_committer != null else {}
	var complexity := float(scene_voxel.get("complexity", query.get("complexity", 0.0))) if not scene_voxel.is_empty() else float(query.get("complexity", 0.0))
	var collision := float(scene_voxel.get("collision", query.get("collision", 0.0))) if not scene_voxel.is_empty() else float(query.get("collision", 0.0))
	var tile := _tile_info_for_voxel(voxel)
	var tile_coord: Vector3i = tile.get("coord", Vector3i.ZERO)
	var tile_index := int(tile.get("index", -1))
	return {
		"domain": SELECTION_DOMAIN_SV,
		"geometry": SELECTION_GEOMETRY_VOXEL,
		"id": "sv:%s" % str(voxel),
		"world_position": _selection_voxel_marker_position(voxel, 1.0),
		"marker_size": _default_voxel_marker_size(),
		"voxel_coord": voxel,
		"tile_coord": tile_coord,
		"tile_index": tile_index,
		"complexity": complexity,
		"collision": collision,
		"payload": scene_voxel if not scene_voxel.is_empty() else query,
	}


## 拾取相机点击处的Anchor记录
func _pick_anchor_record_with_camera(cam: Camera3D, screen_pos: Vector2) -> Dictionary:
	return _pick_record_via_voxel(cam, screen_pos, _anchor_record_for_voxel)


## 为指定体素构建Anchor选中记录
func _anchor_record_for_voxel(voxel: Vector3i) -> Dictionary:
	var hit_pos := _selection_voxel_marker_position(voxel, 0.0)
	var query: Dictionary = _sv_committer.query_voxel(hit_pos.x, hit_pos.z, 0.0) if _sv_committer != null else {}
	var tile := _tile_info_for_voxel(voxel)
	var tile_coord: Vector3i = tile.get("coord", Vector3i.ZERO)
	var tile_index := int(tile.get("index", -1))
	var complexity := float(query.get("complexity", 0.0))
	return {
		"domain": SELECTION_DOMAIN_ANCHOR,
		"geometry": SELECTION_GEOMETRY_VOXEL,
		"id": "anchor:%s" % str(voxel),
		"world_position": _selection_voxel_marker_position(voxel, 2.0),
		"marker_size": _default_voxel_marker_size() * 1.35,
		"voxel_coord": voxel,
		"tile_coord": tile_coord,
		"tile_index": tile_index,
		"anchor_kind": "candidate" if complexity <= 0.01 else "occupied_candidate",
		"complexity": complexity,
		"payload": query,
	}


## 拾取相机点击处的TargetSV体素记录
func _pick_targetsv_record_with_camera(cam: Camera3D, screen_pos: Vector2, allow_empty_fallback: bool = true) -> Dictionary:
	var targetsv := _find_targetsv_setup()
	if targetsv == null or not targetsv.has_method("is_targetsv_ready") or not targetsv.is_targetsv_ready():
		return {}
	var hit := _pick_voxel_hit_with_camera(cam, screen_pos)
	if hit.is_empty():
		return {}
	var metadata: Dictionary = targetsv.get_metadata() if targetsv.has_method("get_metadata") else {}
	var texture_size := maxi(int(metadata.get("texture_size", 0)), 1)
	var slice_count := maxi(int(metadata.get("slice_count", 1)), 1)
	var capture := float(metadata.get("capture_size", TerrainConfigScript.CAPTURE_SIZE))
	var vertical_span := float(metadata.get("vertical_span", 16.0))
	var world_pos: Vector3 = hit.get("world_position", Vector3.ZERO)
	var base_x := clampi(roundi(((world_pos.x / capture) + 0.5) * float(texture_size - 1)), 0, texture_size - 1)
	var base_z := clampi(roundi(((world_pos.z / capture) + 0.5) * float(texture_size - 1)), 0, texture_size - 1)
	var visual: PackedByteArray = targetsv.get_visual_bytes() if targetsv.has_method("get_visual_bytes") else PackedByteArray()
	var collision: PackedByteArray = targetsv.get_collision_bytes() if targetsv.has_method("get_collision_bytes") else PackedByteArray()
	var best := _pick_targetsv_voxel_gpu(targetsv, cam, screen_pos, base_x, base_z, texture_size, slice_count, visual, collision, capture, vertical_span)
	if best.is_empty() and allow_empty_fallback:
		best = _targetsv_record_for_voxel(targetsv, cam, screen_pos, base_x, 0, base_z, texture_size, slice_count, visual, collision)
		best["pick_backend"] = "gpu_scene_cpu_empty_fallback"
	if best.is_empty():
		return {}
	var cell_size := capture / maxf(float(texture_size - 1), 1.0)
	var slice_height := vertical_span / maxf(float(slice_count), 1.0)
	best["marker_size"] = Vector3(maxf(cell_size * 0.9, 0.2), maxf(slice_height * 0.9, 0.2), maxf(cell_size * 0.9, 0.2))
	return best


## 按统一体素坐标构建TargetSV选中记录
func _targetsv_record_for_selection_voxel(voxel: Vector3i) -> Dictionary:
	return _targetsv_record_for_indices(voxel.x, voxel.y, voxel.z)


## 按显式索引构建TargetSV选中记录
func _targetsv_record_for_indices(x: int, slice_index: int, z: int) -> Dictionary:
	var targetsv := _find_targetsv_setup()
	if targetsv == null or not targetsv.has_method("is_targetsv_ready") or not targetsv.is_targetsv_ready():
		return {}
	var metadata: Dictionary = targetsv.get_metadata() if targetsv.has_method("get_metadata") else {}
	var texture_size := maxi(int(metadata.get("texture_size", 0)), 1)
	var slice_count := maxi(int(metadata.get("slice_count", 1)), 1)
	var capture := float(metadata.get("capture_size", TerrainConfigScript.CAPTURE_SIZE))
	var vertical_span := float(metadata.get("vertical_span", 16.0))
	var visual: PackedByteArray = targetsv.get_visual_bytes() if targetsv.has_method("get_visual_bytes") else PackedByteArray()
	var collision: PackedByteArray = targetsv.get_collision_bytes() if targetsv.has_method("get_collision_bytes") else PackedByteArray()
	var clamped_x := clampi(x, 0, texture_size - 1)
	var clamped_slice := clampi(slice_index, 0, slice_count - 1)
	var clamped_z := clampi(z, 0, texture_size - 1)
	var record := _targetsv_record_for_voxel(targetsv, null, Vector2.ZERO, clamped_x, clamped_slice, clamped_z, texture_size, slice_count, visual, collision)
	var cell_size := capture / maxf(float(texture_size - 1), 1.0)
	var slice_height := vertical_span / maxf(float(slice_count), 1.0)
	record["marker_size"] = Vector3(maxf(cell_size * 0.9, 0.2), maxf(slice_height * 0.9, 0.2), maxf(cell_size * 0.9, 0.2))
	return record


## 在像素邻域搜索最近的有内容TargetSV体素
func _pick_targetsv_voxel_gpu(
	targetsv: Node,
	cam: Camera3D,
	screen_pos: Vector2,
	base_x: int,
	base_z: int,
	texture_size: int,
	slice_count: int,
	visual: PackedByteArray,
	collision: PackedByteArray,
	capture: float,
	vertical_span: float
) -> Dictionary:
	if cam == null or targetsv == null:
		return {}
	if _terrain_field.is_empty() or _terrain_field_res <= 0:
		_cache_terrain_field()
	if not _ensure_voxel_pick_gpu_or_warn():
		return {}
	var display_scale := 1.0
	var display_scale_value = targetsv.get("display_scale")
	if display_scale_value != null:
		display_scale = float(display_scale_value)
	var target_origin := Vector3.ZERO
	if targetsv is Node3D:
		target_origin = (targetsv as Node3D).global_transform.origin
	var gpu_hit: Dictionary = _voxel_pick_gpu.pick_targetsv(
		cam.project_ray_origin(screen_pos),
		cam.project_ray_normal(screen_pos),
		base_x,
		base_z,
		visual,
		collision,
		texture_size,
		slice_count,
		capture,
		vertical_span,
		display_scale,
		target_origin,
		_terrain_field,
		_terrain_field_res,
		4,
		0.001
	)
	if not bool(gpu_hit.get("ok", false)):
		return {}
	var voxel: Vector3i = gpu_hit.get("voxel_coord", Vector3i.ZERO)
	var record := _targetsv_record_for_voxel(targetsv, null, screen_pos, voxel.x, voxel.y, voxel.z, texture_size, slice_count, visual, collision)
	if record.is_empty():
		return {}
	record["world_position"] = gpu_hit.get("world_position", record.get("world_position", Vector3.ZERO))
	record["complexity"] = float(gpu_hit.get("complexity", record.get("complexity", 0.0)))
	record["collision"] = float(gpu_hit.get("collision", record.get("collision", 0.0)))
	record["occupancy"] = float(gpu_hit.get("occupancy", record.get("occupancy", 0.0)))
	record["screen_score"] = float(gpu_hit.get("screen_score", 0.0))
	record["buffer_index"] = int(gpu_hit.get("buffer_index", -1))
	record["pick_backend"] = str(gpu_hit.get("pick_backend", "gpu_compute"))
	var payload: Dictionary = record.get("payload", {})
	payload["buffer_index"] = int(gpu_hit.get("buffer_index", payload.get("buffer_index", -1)))
	record["payload"] = payload
	return record


## 为指定体素构建TargetSV选中记录
func _targetsv_record_for_voxel(
	targetsv: Node,
	cam: Camera3D,
	screen_pos: Vector2,
	x: int,
	slice_index: int,
	z: int,
	texture_size: int,
	slice_count: int,
	visual: PackedByteArray,
	collision: PackedByteArray
) -> Dictionary:
	var idx := (slice_index * texture_size + z) * texture_size + x
	var complexity := 0.0
	var visual_offset := idx * 16 + 12
	if visual_offset + 4 <= visual.size():
		complexity = clampf(visual.decode_float(visual_offset), 0.0, 1.0)
	var collision_value := 0.0
	var collision_offset := idx * 4
	if collision_offset + 4 <= collision.size():
		collision_value = clampf(collision.decode_float(collision_offset), 0.0, 1.0)
	var occupancy := maxf(complexity, collision_value)
	var local_pos: Vector3 = targetsv.voxel_to_world(x, slice_index, z) if targetsv.has_method("voxel_to_world") else Vector3.ZERO
	var world_pos: Vector3 = (targetsv as Node3D).to_global(local_pos) if targetsv is Node3D else local_pos
	var score := INF
	if cam != null and not cam.is_position_behind(world_pos):
		score = cam.unproject_position(world_pos).distance_squared_to(screen_pos)
	var voxel := Vector3i(x, slice_index, z)
	return {
		"domain": SELECTION_DOMAIN_TARGETSV,
		"geometry": SELECTION_GEOMETRY_VOXEL,
		"id": "targetsv:%s" % str(voxel),
		"world_position": world_pos,
		"voxel_coord": voxel,
		"tile_coord": Vector3i.ZERO,
		"complexity": complexity,
		"collision": collision_value,
		"occupancy": occupancy,
		"screen_score": score,
		"payload": {
			"texture_size": texture_size,
			"slice_count": slice_count,
			"buffer_index": idx,
		},
	}


## 计算SVTile标记的世界位置和尺寸
func _svtile_marker_transform(tile_coord: Vector3i, tile_size: Vector3i) -> Dictionary:
	var voxel_size := VoxelGeneral.voxel_size_for_resolution(
		TerrainConfigScript.CAPTURE_SIZE,
		autoobject_grid_resolution,
		1.0
	)
	if _sv_committer != null:
		voxel_size = _sv_committer.voxel_size
	var bounds := SceneVoxelTileCodecScript.tile_bounds(tile_coord, _scene_voxel_grid_size(), tile_size)
	var voxel_min: Vector3i = bounds.get("voxel_min", Vector3i.ZERO)
	var voxel_max: Vector3i = bounds.get("voxel_max", voxel_min + Vector3i.ONE)
	var center_voxel := Vector3(
		(float(voxel_min.x) + float(voxel_max.x)) * 0.5,
		0.0,
		(float(voxel_min.z) + float(voxel_max.z)) * 0.5
	)
	var center := _position_on_terrain_from_voxel_center(center_voxel, 1.0)
	var span_world := VoxelGeneral.voxel_span_to_world_size(voxel_max - voxel_min, voxel_size)
	var size := Vector3(
		maxf(span_world.x * 0.96, 0.2),
		2.5,
		maxf(span_world.z * 0.96, 0.2)
	)
	return {"position": center, "size": size}


## 计算体素选中标记的世界位置（带高度偏移）
func _selection_voxel_marker_position(voxel: Vector3i, y_offset: float) -> Vector3:
	var world := _voxel_center_to_world(voxel, 0.0)
	world.y = _sample_height(world.x, world.z) + y_offset
	return world


## 对地形高度场做射线检测（步进+二分求精）
func _ray_to_terrain(cam: Camera3D, screen_pos: Vector2) -> Dictionary:
	var origin := cam.project_ray_origin(screen_pos)
	var dir := cam.project_ray_normal(screen_pos)
	var interval := _ray_capture_interval(origin, dir)
	if interval.is_empty():
		var fallback := _ray_xz_plane_cam(cam, screen_pos, 0.0)
		if _position_in_capture_xz(fallback):
			return {"ok": true, "position": fallback}
		return {}

	var t0 := float(interval.get("t_min", 0.0))
	var t1 := float(interval.get("t_max", 0.0))
	if t1 <= t0:
		return {}

	var steps := 48
	var surface_offset := _autoobject_point_size() * 0.4
	var prev_t := t0
	var prev_pos := origin + dir * prev_t
	var prev_delta := prev_pos.y - (_sample_height(prev_pos.x, prev_pos.z) + surface_offset)
	var best_pos := prev_pos
	var best_abs := absf(prev_delta)
	for step in range(1, steps + 1):
		var t := lerpf(t0, t1, float(step) / float(steps))
		var pos := origin + dir * t
		var delta := pos.y - (_sample_height(pos.x, pos.z) + surface_offset)
		var delta_abs := absf(delta)
		if delta_abs < best_abs:
			best_abs = delta_abs
			best_pos = pos
		if (prev_delta >= 0.0 and delta <= 0.0) or (prev_delta <= 0.0 and delta >= 0.0):
			var lo := prev_t
			var hi := t
			for _i in range(8):
				var mid := (lo + hi) * 0.5
				var mid_pos := origin + dir * mid
				var mid_delta := mid_pos.y - (_sample_height(mid_pos.x, mid_pos.z) + surface_offset)
				if (prev_delta >= 0.0 and mid_delta >= 0.0) or (prev_delta <= 0.0 and mid_delta <= 0.0):
					lo = mid
				else:
					hi = mid
			return {"ok": true, "position": origin + dir * ((lo + hi) * 0.5)}
		prev_t = t
		prev_delta = delta
	if best_abs <= TerrainConfigScript.MAX_HEIGHT + 64.0 and _position_in_capture_xz(best_pos):
		return {"ok": true, "position": best_pos}
	return {}


## 计算射线与捕获区域AABB的相交区间
func _ray_capture_interval(origin: Vector3, dir: Vector3) -> Dictionary:
	var half := TerrainConfigScript.CAPTURE_SIZE * 0.5
	var t_min := 0.0
	var t_max := 5000.0
	if absf(dir.x) < 0.00001:
		if origin.x < -half or origin.x > half:
			return {}
	else:
		var tx1 := (-half - origin.x) / dir.x
		var tx2 := (half - origin.x) / dir.x
		t_min = maxf(t_min, minf(tx1, tx2))
		t_max = minf(t_max, maxf(tx1, tx2))
	if absf(dir.z) < 0.00001:
		if origin.z < -half or origin.z > half:
			return {}
	else:
		var tz1 := (-half - origin.z) / dir.z
		var tz2 := (half - origin.z) / dir.z
		t_min = maxf(t_min, minf(tz1, tz2))
		t_max = minf(t_max, maxf(tz1, tz2))
	if t_max < t_min or t_max < 0.0:
		return {}
	return {"ok": true, "t_min": maxf(t_min, 0.0), "t_max": t_max}


## 检查位置是否在捕获区域XZ范围内
func _position_in_capture_xz(pos: Vector3) -> bool:
	var half := TerrainConfigScript.CAPTURE_SIZE * 0.5
	return pos.x >= -half and pos.x <= half and pos.z >= -half and pos.z <= half


## 由体素坐标一次性求出 tile 尺寸/网格/线性索引/坐标
func _tile_info_for_voxel(voxel: Vector3i) -> Dictionary:
	var tile_size := _svtile_tile_size()
	return SceneVoxelTileCodecScript.tile_info_for_voxel(voxel, _scene_voxel_grid_size(), tile_size)


## 由 GPU AutoObject 索引构建统一的选中记录字典
func _make_autoobject_selection_record(object_index: int, screen_score: float) -> Dictionary:
	var asset_idx := _safe_asset_index(object_index)
	var voxel_min := _autoobject_voxel_min_from_index(object_index)
	var tile := _tile_info_for_voxel(voxel_min)
	return {
		"domain": SELECTION_DOMAIN_AUTOOBJECT,
		"geometry": SELECTION_GEOMETRY_GPU_POINT,
		"id": "gpu_autoobject:%d" % _autoobject_id_for_index(object_index),
		"object_index": object_index,
		"object_id": _autoobject_id_for_index(object_index),
		"asset_index": asset_idx,
		"asset_name": DemoAssets.asset_name(asset_idx, "unknown"),
		"profile_id": _profile_ids[asset_idx] if asset_idx >= 0 and asset_idx < _profile_ids.size() else -1,
		"position": _autoobject_positions[object_index],
		"voxel_min": voxel_min,
		"voxel_max": voxel_min + Vector3i.ONE,
		"tile_coord": tile.get("coord", Vector3i.ZERO),
		"tile_index": int(tile.get("index", -1)),
		"screen_score": screen_score,
	}


## 在世界坐标附近搜索最近的GPU AutoObject
func _nearest_autoobject_at_world(world_pos: Vector3, cam: Camera3D, screen_pos: Vector2) -> Dictionary:
	if _sv_committer == null or _autoobject_side_count <= 0 or _autoobject_spacing_voxels <= 0:
		return {}
	var voxel_center := VoxelGeneral.world_to_voxel_center(
		world_pos,
		_sv_committer.grid_origin,
		_sv_committer.voxel_size
	)
	var base_px := int(round(voxel_center.x / float(_autoobject_spacing_voxels)))
	var base_pz := int(round(voxel_center.z / float(_autoobject_spacing_voxels)))
	var best_index := -1
	var best_score := INF
	var best_xz_dist2 := INF
	var search_radius := 2
	for dz in range(-search_radius, search_radius + 1):
		for dx in range(-search_radius, search_radius + 1):
			var px := base_px + dx
			var pz := base_pz + dz
			if px < 0 or pz < 0 or px >= _autoobject_side_count:
				continue
			var object_index := pz * _autoobject_side_count + px
			if object_index < 0 or object_index >= _autoobject_positions.size():
				continue
			var pos := _autoobject_positions[object_index]
			var xz_dist2 := Vector2(pos.x, pos.z).distance_squared_to(Vector2(world_pos.x, world_pos.z))
			var score := xz_dist2
			if cam != null:
				var projected := cam.unproject_position(pos)
				score = projected.distance_squared_to(screen_pos)
			if score < best_score:
				best_score = score
				best_xz_dist2 = xz_dist2
				best_index = object_index
	if best_index < 0:
		return {}
	var pick_radius := maxf(
		_autoobject_point_size() * 3.5,
		float(_autoobject_spacing_voxels) * maxf(_sv_committer.voxel_size.x, _sv_committer.voxel_size.z) * 1.25
	)
	if best_xz_dist2 > pick_radius * pick_radius and best_score > 42.0 * 42.0:
		return {}
	return _make_autoobject_selection_record(best_index, best_score)


## 按屏幕投影距离搜索最近的GPU AutoObject
func _nearest_autoobject_on_screen(cam: Camera3D, screen_pos: Vector2, radius_px: float) -> Dictionary:
	if cam == null or _autoobject_positions.is_empty():
		return {}
	var best_index := -1
	var best_score := INF
	var radius2 := maxf(radius_px, 1.0) * maxf(radius_px, 1.0)
	for object_index in range(_autoobject_positions.size()):
		var pos := _autoobject_positions[object_index]
		if cam.is_position_behind(pos):
			continue
		var projected := cam.unproject_position(pos)
		var score := projected.distance_squared_to(screen_pos)
		if score < best_score:
			best_score = score
			best_index = object_index
	if best_index < 0 or best_score > radius2:
		return {}
	return _make_autoobject_selection_record(best_index, best_score)


## 整数体素→世界坐标
func _voxel_center_to_world(voxel: Vector3i, y: float) -> Vector3:
	return _voxel_float_center_to_world(Vector3(float(voxel.x) + 0.5, float(voxel.y) + 0.5, float(voxel.z) + 0.5), y)


## 浮点体素中心→世界坐标
func _voxel_float_center_to_world(voxel_center: Vector3, y: float) -> Vector3:
	if _sv_committer == null:
		var res := maxi(autoobject_grid_resolution, 1)
		return VoxelGeneral.voxel_float_center_to_world_xz(
			voxel_center,
			VoxelGeneral.default_grid_origin(TerrainConfigScript.CAPTURE_SIZE),
			VoxelGeneral.voxel_size_for_resolution(TerrainConfigScript.CAPTURE_SIZE, res, 1.0),
			y
		)
	return VoxelGeneral.voxel_float_center_to_world_xz(
		voxel_center,
		_sv_committer.grid_origin,
		_sv_committer.voxel_size,
		y
	)


## 体素中心→地形表面世界坐标
func _position_on_terrain_from_voxel_center(voxel_center: Vector3, y_offset: float) -> Vector3:
	var world_pos := _voxel_float_center_to_world(voxel_center, 0.0)
	world_pos.y = _sample_height(world_pos.x, world_pos.z) + y_offset
	return world_pos


## GPU AutoObject对象→地形表面世界坐标
func _autoobject_position_on_terrain(voxel: Vector3i) -> Vector3:
	var center := Vector3(float(voxel.x) + 0.5, float(voxel.y) + 0.5, float(voxel.z) + 0.5)
	return _position_on_terrain_from_voxel_center(center, _autoobject_point_size() * 0.9)


## GPU AutoObject点云的点尺寸
func _autoobject_point_size() -> float:
	if _sv_committer == null:
		return 1.0
	return maxf(minf(_sv_committer.voxel_size.x, _sv_committer.voxel_size.z) * 0.52, 0.35)


## 重置所有GPU AutoObject运行时状态变量和节点
func _reset_autoobject_runtime_state() -> void:
	_autoobject_runtime_ready = false
	_autoobject_spawn_result.clear()
	_autoobject_flush_result.clear()
	_svtile_summary.clear()
	_autoobject_spawn_time_ms = 0.0
	_autoobject_flush_time_ms = 0.0
	_autoobject_visual_time_ms = 0.0
	_svtile_total_tile_count = 0
	_svtile_occupied_tile_count = 0
	_svtile_max_refs_per_tile = 0
	_svtile_total_refs = 0
	_autoobject_positions.clear()
	_autoobject_asset_indices.clear()
	_autoobject_ids.clear()
	_autoobject_side_count = 0
	_autoobject_spacing_voxels = 1
	# 重建点云使 autoobject/数据选中失效；volume-score anchor 权威态在 provider，保留镜像
	if not _active_selection_is_volume_score_anchor():
		_active_selection.clear()
	if _autoobject_overlay_root != null:
		for child in _autoobject_overlay_root.get_children():
			child.queue_free()
	_clear_autoobject_overlay_refs()


## 清除GPU AutoObject/SVTile叠加层及选择标记节点引用
func _clear_autoobject_overlay_refs() -> void:
	_svtile_heatmap = null
	_autoobject_points = null
	_autoobject_overlay_label = null
	_selection_marker = null
	_selection_label = null
	_anchor_sample_bounds_marker = null


# ---- mesh + terrain --------------------------------------------------------

## 从配置路径加载网格资源
func _load_meshes() -> void:
	_meshes.clear()
	for path in DemoAssets.geo_paths():
		var m := AutoAssetFactory.load_mesh(path)
		if m == null:
			m = BoxMesh.new()
		_meshes.append(m)


## 从地形网格缓存高度场数据
func _cache_terrain_field() -> void:
	var terrain := TerrainInitializerScript.find_edit_time_terrain(self) as MeshInstance3D
	if terrain == null or terrain.mesh == null:
		_terrain_field_res = 0
		_terrain_field = PackedFloat32Array()
		return
	_terrain_field_res = 128
	_terrain_field = TerrainInitializerScript.terrain_height_field_from_mesh(
		terrain, _terrain_field_res, TerrainConfigScript.MAX_HEIGHT)


## 在世界XZ坐标采样地形高度
func _sample_height(wx: float, wz: float) -> float:
	if _terrain_field_res <= 0 or _terrain_field.is_empty():
		return 0.0
	var capture := TerrainConfigScript.CAPTURE_SIZE
	var u := clampf((wx / capture) + 0.5, 0.0, 1.0)
	var v := clampf((wz / capture) + 0.5, 0.0, 1.0)
	var px := clampi(int(u * float(_terrain_field_res - 1)), 0, _terrain_field_res - 1)
	var pz := clampi(int(v * float(_terrain_field_res - 1)), 0, _terrain_field_res - 1)
	var idx := pz * _terrain_field_res + px
	return _terrain_field[idx] if idx < _terrain_field.size() else 0.0


# ---- Input -----------------------------------------------------------------

var _editor_camera: Camera3D
var _consume_editor_mouse_release := false


## 检查当前模式是否允许选择GPU AutoObject点云
func _selection_allows_gpu_autoobjects() -> bool:
	var gpu_display_key := SPAEditorContract.voxel_display_key_for_mode(SelectionMode.AUTOOBJECT)
	return select_gpu_autoobjects \
		and _voxel_display_is_visible(gpu_display_key) \
		and SPAEditorContract.mode_is_active(_selection_mode, SelectionMode.AUTOOBJECT)


## 检查是否有任何类型的选中状态
func _has_active_selection() -> bool:
	return not _active_selection.is_empty()


## 鼠标点击的统一选择入口。
## 顺序很重要：
## 1. Mixed/AutoObject 先尝试 GPU AutoObject 点云。
## 2. Mixed/Anchor 再尝试外部 volume-score anchor provider。
## 3. 最后按当前数据模式构建 SVTile/SV/Anchor/TargetSV 记录。
func _select_current_mode_at_screen_position(cam: Camera3D, screen_pos: Vector2) -> Dictionary:
	if _selection_allows_gpu_autoobjects():
		var gpu_hit := _pick_autoobject_with_camera(cam, screen_pos)
		if not gpu_hit.is_empty():
			set_active_selection(gpu_hit)
			return {
				"ok": true,
				"domain": str(gpu_hit.get("domain", SELECTION_DOMAIN_AUTOOBJECT)),
				"geometry": str(gpu_hit.get("geometry", SELECTION_GEOMETRY_GPU_POINT)),
				"record": gpu_hit,
			}
	var volume_score_hit := _select_volume_score_anchor_at_position(cam, screen_pos)
	if not volume_score_hit.is_empty():
		return volume_score_hit
	var data_hit := _pick_data_selection_record_with_camera(cam, screen_pos)
	if not data_hit.is_empty():
		set_active_selection(data_hit)
		return {
			"ok": true,
			"domain": str(data_hit.get("domain", "")),
			"geometry": str(data_hit.get("geometry", "")),
			"record": data_hit,
		}
	return {}


## 编辑器视口输入事件分发入口
func _editor_viewport_input(viewport_camera: Camera3D, event: InputEvent) -> bool:
	_editor_camera = viewport_camera
	if event is InputEventMouseButton:
		return _handle_editor_mouse_button(viewport_camera, event as InputEventMouseButton)
	elif event is InputEventKey:
		return _handle_editor_key(event as InputEventKey)
	return false


## 处理编辑器视口鼠标点击
func _handle_editor_mouse_button(cam: Camera3D, event: InputEventMouseButton) -> bool:
	if event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
		return _cycle_volume_score_anchor_topk(-1)
	if event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		return _cycle_volume_score_anchor_topk(1)
	if event.button_index != MOUSE_BUTTON_LEFT:
		return false
	if event.pressed:
		var selection_result := _select_current_mode_at_screen_position(cam, event.position)
		if not selection_result.is_empty():
			_consume_editor_mouse_release = true
			return true
		if _has_active_selection():
			_deselect()
			_consume_editor_mouse_release = true
			return true
	else:
		if _consume_editor_mouse_release:
			_consume_editor_mouse_release = false
			return true
	return false


## 处理编辑器视口键盘事件
func _handle_editor_key(event: InputEventKey) -> bool:
	if not event.pressed or event.echo:
		return false
	if event.shift_pressed:
		var next_mode := _selection_mode_from_keycode(event.keycode)
		if next_mode >= 0:
			set_spa_selection_mode(next_mode)
			return true
	match event.keycode:
		KEY_ESCAPE:
			_deselect()
			return true
		KEY_G:
			_print_gpu_report()
			return true
		KEY_SPACE:
			_register_all_assets()
			_run_gpu_autoobject_batch()
			_update_hud()
			return true
	return false


## 键码→选择模式枚举映射；顺序必须和 SELECTION_MODE_NAMES / 插件工具栏一致
func _selection_mode_from_keycode(keycode: int) -> int:
	return SPAEditorContract.selection_mode_from_keycode(keycode)


## 相机射线与XZ平面求交
func _ray_xz_plane_cam(cam: Camera3D, screen_pos: Vector2, plane_y: float) -> Vector3:
	var origin := cam.project_ray_origin(screen_pos)
	var dir := cam.project_ray_normal(screen_pos)
	if absf(dir.y) < 0.00001:
		return origin
	var t := (plane_y - origin.y) / dir.y
	return origin + dir * t


# ---- Selection -------------------------------------------------------------

## 清除所有选中状态
func _deselect() -> void:
	clear_active_selection(false)
	_select_editor_selection_anchor_for_mode()
	_update_hud()


## 打印GPU就绪状态报告
func _print_gpu_report() -> void:
	if _spa == null:
		print("[SPA Demo] No SPA instance")
		return
	var report: Dictionary = _spa.get_gpu_readiness_report()
	print("[SPA Demo] GPU Readiness Report:")
	for key in report.keys():
		print("  %s: %s" % [key, str(report[key])])


# ---- HUD -------------------------------------------------------------------

## 创建HUD画布和标签
func _setup_hud() -> void:
	_hud_label = DemoUI.setup_hud_label(self)


## 更新HUD信息显示（GPU状态、选中信息等）
func _update_hud() -> void:
	if _hud_label == null:
		return
	var gpu_ready: bool = _spa.is_gpu_ready() if _spa != null else false
	var rd_ok := RenderingServer.get_rendering_device() != null
	var lines: Array[String] = [
		"ScenePlacementActor (SPA) — GPU AutoObject Placement Demo",
		"",
		"RD: %s   SPA: %s (%.0f ms)   GPU ready: %s" % [
			"ready" if rd_ok else "NONE",
			"OK" if _initialized else "FAIL",
			_init_time_ms,
			"YES" if gpu_ready else "NO"],
		"Assets: %d registered (%.0f ms)" % [
			_descriptors.size(), _register_time_ms],
		"Selection mode: %s   Shift+0 Mixed, Shift+1 AutoObject, Shift+2 SVTile, Shift+3 Anchor, Shift+4 SV, Shift+5 TargetSV" % [
			_selection_mode_name()
		],
	]
	var spawned := int(_autoobject_spawn_result.get("spawned_count", 0))
	var inserted := int(_autoobject_flush_result.get("object_ref_inserted_slot_count", 0))
	var overflow := int(_autoobject_flush_result.get("object_ref_overflow_count", 0))
	var touched := int(_autoobject_flush_result.get("object_ref_touched_count", 0))
	var dirty_tiles := int(_autoobject_flush_result.get("dirty_scene_voxel_tile_count", _svtile_summary.get("dirty_tile_count", 0)))
	var avg_refs := float(_svtile_total_refs) / float(maxi(_svtile_occupied_tile_count, 1))
	lines.append("AutoObjects: %s   spawned: %d/%d   SVTile refs inserted: %d" % [
		"PASS" if _autoobject_runtime_ready else "PENDING/FAIL",
		spawned,
		autoobject_count,
		inserted,
	])
	lines.append("Tiles: %d occupied / %d total   avg refs/tile %.2f   max %d   overflow %d" % [
		_svtile_occupied_tile_count,
		_svtile_total_tile_count,
		avg_refs,
		_svtile_max_refs_per_tile,
		overflow,
	])
	lines.append("Dirty/touched: %d tiles / %d refs   spawn %.0f ms   flush %.0f ms   visual %.0f ms" % [
		dirty_tiles,
		touched,
		_autoobject_spawn_time_ms,
		_autoobject_flush_time_ms,
		_autoobject_visual_time_ms,
	])
	lines.append("")
	lines.append("LMB: select under current mode (GPU AutoObject / data voxel)")
	lines.append("G: GPU report   Space: re-register + re-spawn   Esc: deselect")
	_append_active_selection_hud_lines(lines)
	_hud_label.text = "\n".join(lines)


## 把当前活动选中的明细追加到 HUD（按域分支，全部从 _active_selection 读）
func _append_active_selection_hud_lines(lines: Array[String]) -> void:
	if _active_selection.is_empty():
		return
	var record := _active_selection
	var domain := str(record.get("domain", "data"))
	lines.append("")
	if str(record.get("geometry", "")) == SELECTION_GEOMETRY_GPU_POINT:
		var pos: Vector3 = record.get("position", Vector3.ZERO)
		var voxel_min: Vector3i = record.get("voxel_min", Vector3i.ZERO)
		var voxel_max: Vector3i = record.get("voxel_max", Vector3i.ZERO)
		lines.append("Selected GPU AutoObject: index=%d  object_id=%d  asset=%s  profile_id=%d" % [
			int(record.get("object_index", -1)),
			int(record.get("object_id", -1)),
			str(record.get("asset_name", "unknown")),
			int(record.get("profile_id", -1)),
		])
		lines.append("  tile=%s  voxel=(%s -> %s)" % [
			str(record.get("tile_coord", Vector3i.ZERO)),
			str(voxel_min),
			str(voxel_max),
		])
		lines.append("  terrain pos: (%.1f, %.1f, %.1f)" % [pos.x, pos.y, pos.z])
		return
	if _active_selection_is_volume_score_anchor():
		lines.append("Selected %s: %s" % [domain, str(record.get("id", ""))])
		var summary := str(record.get("summary", ""))
		if not summary.is_empty():
			lines.append("  %s" % summary)
		return
	var voxel: Vector3i = record.get("voxel_coord", Vector3i.ZERO)
	var tile: Vector3i = record.get("tile_coord", Vector3i.ZERO)
	var world_pos: Vector3 = record.get("world_position", Vector3.ZERO)
	lines.append("Selected %s: %s" % [domain, str(record.get("id", ""))])
	lines.append("  voxel=%s  tile=%s  pos=(%.1f, %.1f, %.1f)" % [
		str(voxel), str(tile), world_pos.x, world_pos.y, world_pos.z
	])
	if domain == SELECTION_DOMAIN_SVTILE:
		lines.append("  object refs=%d" % int(record.get("object_ref_count", 0)))
	elif domain == SELECTION_DOMAIN_SV or domain == SELECTION_DOMAIN_TARGETSV:
		lines.append("  complexity=%.3f  collision=%.3f" % [
			float(record.get("complexity", 0.0)),
			float(record.get("collision", 0.0)),
		])
	elif domain == SELECTION_DOMAIN_ANCHOR:
		lines.append("  kind=%s  complexity=%.3f" % [
			str(record.get("anchor_kind", "candidate")),
			float(record.get("complexity", 0.0)),
		])


# ---- Camera ----------------------------------------------------------------

## 将相机定位到地形框景位置
func _frame_camera() -> void:
	var cam := DemoUI.find_camera(self, "", "FlyCamera", false, true)
	if cam == null:
		return
	var half := TerrainConfigScript.CAPTURE_SIZE * 0.5
	var target_y := TerrainConfigScript.MAX_HEIGHT * 0.35
	cam.global_position = Vector3(-half * 0.45, half * 0.82, half * 0.95)
	cam.look_at(Vector3(0.0, target_y, 0.0), Vector3.UP)
	cam.fov = 60.0
	cam.far = 3000.0
	cam.current = true
	_editor_camera = cam


## 获取当前激活的Camera3D
func _get_camera() -> Camera3D:
	return DemoUI.find_camera(self, "", "FlyCamera", true, true)


## 每帧更新（编辑器模式占位，当前无 per-frame 同步需求）
func _process(_delta: float) -> void:
	if not Engine.is_editor_hint():
		return
	if is_scene_startup_blocked():
		return


## GPU/SPA 资源只在节点真正被释放时清理,而不是每次编辑器标签页切换都清理。
## 编辑器在场景标签页之间切换时,会对"离开的场景"触发 NOTIFICATION_EXIT_TREE,
## 但节点并未释放;切回来时 Godot 也不会再次调用 _ready()(每个节点 _ready 只跑
## 一次)。旧实现在 _exit_tree 里 dispose,导致切走后 _spa/GPU 组件被释放、切回来
## 无法重建 → 点选 / 评分 / AutoObject 选择全部失效。改为仅在 PREDELETE(关闭标签
## 页、关闭编辑器、场景被 free)时清理,GPU 资源与子节点一样跨标签页存活。
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_dispose_spa_components(true)
	elif what == NOTIFICATION_EXIT_TREE or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		# 切编辑器标签页 / 窗口失焦时，配对的鼠标 release 可能永远不到达
		# _handle_editor_mouse_button，_consume_editor_mouse_release 会卡在 true，
		# 随后吞掉一次无关点击的 release。主动复位，避免"点击被吃掉 / 要切模式才恢复"。
		_consume_editor_mouse_release = false
