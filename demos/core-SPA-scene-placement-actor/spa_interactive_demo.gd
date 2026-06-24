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
const AssetDescriptorScript := preload("res://scripts/auto_voxel_descriptor.gd")
const ScenePlacementActorScript := preload("res://scripts/scene_placement_actor.gd")
const SceneVoxelCommitterScript := preload("res://scripts/scene_voxel_committer.gd")
const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")
const GPUAutoObjectRuntimeScript := preload("res://scripts/gpu_autoobject_runtime.gd")
const VoxelPickGPUScript := preload("res://scripts/voxel_pick_gpu.gd")
const VoxelDisplay := preload("res://scripts/voxel_display.gd")
const AutoObjectScript := preload("res://scripts/auto_object.gd")
const CommonDemoAssets := preload("res://scripts/common_demo_assets.gd")
const CommonDemoUI := preload("res://scripts/common_demo_ui.gd")
const SPAEditorContract := preload("res://scripts/spa_editor_contract.gd")
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
@export var stress_grid_resolution := 512
@export var voxel_display_host_only := false
@export var run_svtile_autoobject_stress := true
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
var _gpu_runtime
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
var _stress_overlay_root: Node3D
var _stress_tile_heatmap: MultiMeshInstance3D
var _autoobject_points: MultiMeshInstance3D
var _stress_label: Label3D
var _autoobject_selection_marker: MeshInstance3D
var _autoobject_selection_label: Label3D
var _data_selection_marker: MeshInstance3D
var _data_selection_label: Label3D
var _anchor_sample_bounds_marker: MeshInstance3D
var _selected_data_record: Dictionary = {}
var _external_voxel_display_root: Node3D
var _volume_score_provider: Node
var _voxel_display_visible := {
	VOXEL_DISPLAY_GPU_OBJECTS: true,
	VOXEL_DISPLAY_SVTILE: true,
	VOXEL_DISPLAY_ANCHOR: true,
	VOXEL_DISPLAY_SV: true,
	VOXEL_DISPLAY_TARGETSV: true,
}

# ---- SVTile / AutoObject stress state ----
var _stress_ready := false
var _stress_spawn_result: Dictionary = {}
var _stress_flush_result: Dictionary = {}
var _stress_tile_summary: Dictionary = {}
var _stress_spawn_time_ms := 0.0
var _stress_flush_time_ms := 0.0
var _stress_visual_time_ms := 0.0
var _stress_tile_count := 0
var _stress_occupied_tile_count := 0
var _stress_max_refs_per_tile := 0
var _stress_total_refs := 0
var _autoobject_positions: Array[Vector3] = []
var _autoobject_asset_indices: Array[int] = []
var _autoobject_ids: Array[int] = []
var _autoobject_side_count := 0
var _autoobject_spacing_voxels := 1
var _selected_autoobject_index := -1
var _selected_autoobject_record: Dictionary = {}

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
	if voxel_display_host_only:
		_cleanup_editor_nodes()
		_ensure_external_voxel_display_root()
		_apply_selection_mode_visuals()
		return
	_editor_init()


## 编辑器模式初始化入口：创建节点、加载资源、初始化SPA
func _editor_init() -> void:
	_cleanup_editor_nodes()
	_stress_overlay_root = Node3D.new()
	_stress_overlay_root.name = SVTILE_AUTOOBJECT_OVERLAY_ROOT_NAME
	add_child(_stress_overlay_root, true)
	_load_meshes()
	ensure_test_terrain_initialized()
	_cache_terrain_field()
	_init_spa()
	_register_all_assets()
	_run_svtile_autoobject_stress_test()
	_setup_hud()
	_frame_camera()
	_apply_selection_mode_visuals()
	_update_hud()
	if _initialized:
		print("[SPA Editor] SPA initialized: gpu_ready=%s, assets=%d" % [
			str(_spa.is_gpu_ready()), _descriptors.size()])


## 设置选择模式并清除旧选中状态；插件工具栏和 Shift+数字快捷键都进入这里
func set_spa_selection_mode(mode: int, clear_existing_selection: bool = true) -> void:
	var next := clampi(mode, SelectionMode.MIXED, SelectionMode.TARGETSV)
	var changed := _selection_mode != next
	_selection_mode = next
	if clear_existing_selection and changed and is_inside_tree():
		_clear_autoobject_selection(false)
		_clear_data_selection(false)
		_clear_volume_score_selection()
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
	var record := _data_record_for_voxel(mode_id, Vector3i(int(x), int(y), int(z)))
	if record.is_empty():
		return {"ok": false, "reason": "no_data_record", "mode": _selection_mode_name(mode_id)}
	_select_data_record(record)
	return {"ok": true, "domain": str(record.get("domain", "")), "geometry": str(record.get("geometry", "")), "record": record}


## 获取当前选中的统一记录字典
func get_current_selection_record() -> Dictionary:
	if not _selected_data_record.is_empty():
		return _selected_data_record.duplicate(true)
	if not _selected_autoobject_record.is_empty():
		return _selected_autoobject_record.duplicate(true)
	var volume_score_record := _volume_score_selection_record()
	if not volume_score_record.is_empty():
		return volume_score_record
	return {}


## Register a demo/provider that owns volume-score anchor generation and top-k state.
func register_volume_score_provider(provider: Node) -> void:
	if provider == null:
		return
	_volume_score_provider = provider
	print("[SPA VolumeScore] Provider registered: %s" % str(provider.get_path()))


## Remove the volume-score provider when its owner exits the tree.
func unregister_volume_score_provider(provider: Node) -> void:
	if provider != null and _volume_score_provider == provider:
		_volume_score_provider = null


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


## 设置指定体素调试域是否显示
func set_voxel_display_visible(display_key: String, visible: bool) -> void:
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
	if node == null or not _voxel_display_visible.has(display_key):
		return
	_ensure_external_voxel_display_root()
	node.add_to_group(_voxel_display_group(display_key))
	node.visible = _voxel_display_is_visible(display_key)


## 根据模式枚举返回可读名称
func _selection_mode_name(mode: int = -1) -> String:
	var idx := _selection_mode if mode < 0 else mode
	if idx >= 0 and idx < SELECTION_MODE_NAMES.size():
		return SELECTION_MODE_NAMES[idx]
	return "Unknown"


## 查询体素显示开关状态
func _voxel_display_is_visible(display_key: String) -> bool:
	return bool(_voxel_display_visible.get(display_key, true))


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
	return _voxel_display_is_visible(VOXEL_DISPLAY_ANCHOR) \
		and (_selection_mode == SelectionMode.MIXED or _selection_mode == SelectionMode.ANCHOR)


func _volume_score_anchor_display_active() -> bool:
	if not _volume_score_anchor_selection_allowed():
		return false
	var provider := _volume_score_provider_node()
	if provider == null:
		return false
	if provider.has_method("has_volume_score_anchors"):
		return bool(provider.call("has_volume_score_anchors"))
	return provider.has_method("select_anchor_at_viewport_position")


func _select_volume_score_anchor_at_position(cam: Camera3D, screen_pos: Vector2) -> Dictionary:
	if not _volume_score_anchor_selection_allowed():
		return {}
	var provider := _volume_score_provider_node()
	if provider == null or not provider.has_method("select_anchor_at_viewport_position"):
		return {}
	var result = provider.call("select_anchor_at_viewport_position", cam, screen_pos)
	if not (result is Dictionary) or not bool(result.get("ok", false)):
		return {}
	_clear_autoobject_selection(false)
	_clear_data_selection(false)
	var record := _volume_score_selection_record(result)
	_update_anchor_sample_bounds_marker(record)
	_update_hud()
	return {
		"ok": true,
		"domain": SELECTION_DOMAIN_ANCHOR,
		"geometry": SELECTION_GEOMETRY_VOLUME_SCORE_ANCHOR,
		"record": record,
		"anchor_index": int(result.get("anchor_index", record.get("anchor_index", -1))),
		"topk": result.get("topk", record.get("topk", [])),
	}


func _cycle_volume_score_anchor_topk(delta: int) -> bool:
	if _selection_mode != SelectionMode.ANCHOR or not _has_volume_score_selection():
		return false
	var provider := _volume_score_provider_node()
	if provider == null or not provider.has_method("cycle_selected_anchor_topk"):
		return false
	var result = provider.call("cycle_selected_anchor_topk", delta)
	if not (result is Dictionary) or not bool(result.get("ok", false)):
		return false
	var record := _volume_score_selection_record(result)
	_update_anchor_sample_bounds_marker(record)
	_update_hud()
	return true


func _clear_volume_score_selection() -> void:
	var provider := _volume_score_provider_node()
	if provider != null and provider.has_method("clear_selected_anchor"):
		provider.call("clear_selected_anchor")
	_hide_node_if_valid(_anchor_sample_bounds_marker)


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
		_voxel_display_is_visible(display_key)
	)


func _apply_voxel_display_group_visibility(node: Node, group_name: String, visible: bool) -> void:
	if node is Node3D and node.is_in_group(group_name):
		(node as Node3D).visible = visible
	for child in node.get_children():
		_apply_voxel_display_group_visibility(child, group_name, visible)


## 判断当前数据选中记录是否允许显示
func _selected_data_record_display_visible() -> bool:
	if _selected_data_record.is_empty():
		return false
	var key := _voxel_display_key_for_domain(str(_selected_data_record.get("domain", "")))
	return key.is_empty() or _voxel_display_is_visible(key)


## Anchor-only sample bounds marker; providers must supply sample_bounds.
func _anchor_sample_bounds_visible(record: Dictionary) -> bool:
	if not show_anchor_sample_bounds:
		return false
	if _selection_mode != SelectionMode.ANCHOR:
		return false
	if not _voxel_display_is_visible(VOXEL_DISPLAY_ANCHOR):
		return false
	return str(record.get("domain", "")) == SELECTION_DOMAIN_ANCHOR and record.has("sample_bounds")


## Refresh the score-stage sample bounds marker; hidden outside Anchor mode.
func _update_anchor_sample_bounds_marker(record: Dictionary = {}) -> void:
	if _selection_mode != SelectionMode.ANCHOR:
		_hide_node_if_valid(_anchor_sample_bounds_marker)
		return
	var source := record
	if source.is_empty():
		source = _volume_score_selection_record()
	if not _anchor_sample_bounds_visible(source):
		_hide_node_if_valid(_anchor_sample_bounds_marker)
		return
	var aabb := _sample_bounds_aabb(source.get("sample_bounds", {}))
	if aabb.size.length_squared() <= 0.000001:
		_hide_node_if_valid(_anchor_sample_bounds_marker)
		return
	_ensure_anchor_sample_bounds_marker()
	if _anchor_sample_bounds_marker == null:
		return
	_anchor_sample_bounds_marker.position = aabb.position + aabb.size * 0.5
	_anchor_sample_bounds_marker.scale = aabb.size
	_anchor_sample_bounds_marker.visible = true


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
	var parent := _stress_overlay_root if _stress_overlay_root != null else self
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


## 按模式将体素坐标转为对应数据记录；AutoObject 没有体素直选记录，需走点云拾取
func _data_record_for_voxel(mode: int, raw_voxel: Vector3i) -> Dictionary:
	var mode_id := int(mode)
	if mode_id == SelectionMode.SVTILE:
		return _svtile_record_for_voxel(_clamp_selection_voxel(raw_voxel))
	if mode_id == SelectionMode.SV:
		return _sv_record_for_voxel(_clamp_selection_voxel(raw_voxel))
	if mode_id == SelectionMode.ANCHOR:
		return _anchor_record_for_voxel(_clamp_selection_voxel(raw_voxel))
	if mode_id == SelectionMode.TARGETSV:
		return _targetsv_record_for_indices(raw_voxel.x, raw_voxel.y, raw_voxel.z)
	return {}


## 将体素坐标限制在合法范围内
func _clamp_selection_voxel(voxel: Vector3i) -> Vector3i:
	if _sv_committer == null:
		var res := maxi(stress_grid_resolution, 1)
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
	if run_svtile_autoobject_stress:
		_sv_committer = SceneVoxelCommitterScript.new(stress_grid_resolution, TerrainConfigScript.CAPTURE_SIZE, true)
		_gpu_runtime = GPUAutoObjectRuntimeScript.new(autoobject_count, false)
	_spa = ScenePlacementActorScript.new()
	if run_svtile_autoobject_stress:
		_spa.initialize(true, true, _sv_committer, _gpu_runtime)
	else:
		_spa.initialize(true, true)
	var merged_report: Dictionary = _spa.get_merged_gpu_buffer_summary() if _spa.has_method("get_merged_gpu_buffer_summary") else {}
	_runtime_setup_result = merged_report.get("gpu_runtime_scene_voxel_setup", {})
	_initialized = _spa.is_initialized()
	_init_time_ms = float(Time.get_ticks_msec() - t0)
	print("[SPA Demo] %s (%.0f ms)" % ["OK" if _initialized else "FAILED", _init_time_ms])
	if run_svtile_autoobject_stress:
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
	if _gpu_runtime != null:
		_gpu_runtime.dispose(sync_before_free)
		_gpu_runtime = null
	if _sv_committer != null:
		_sv_committer.dispose(sync_before_free)
		_sv_committer = null
	_initialized = false
	_runtime_setup_result.clear()


## 将所有网格资产注册到SPA并生成描述符
func _register_all_assets() -> void:
	_descriptors.clear()
	_profile_ids.clear()
	if not _initialized:
		return
	_spa.clear_assets()
	var t0 := Time.get_ticks_msec()
	for i in range(_meshes.size()):
		var color := CommonDemoAssets.asset_color(i)
		var descriptor := AutoObjectScript.create_voxel_descriptor(
			color, color.a, 1.0,
			[{"shape": "cylinder", "radius": 1.0, "y_min": 0.0, "y_max": 2.0}])
		_descriptors.append(descriptor)
		var pid: int = _spa.register_asset(descriptor, _meshes[i])
		_profile_ids.append(pid)
		print("[SPA Demo] Registered [%d] %s → profile_id=%d" % [
			i, CommonDemoAssets.asset_name(i, "?"), pid])
	_register_time_ms = float(Time.get_ticks_msec() - t0)


# ---- SVTile / AutoObject stress visualization -----------------------------

## 运行SVTile+GPU AutoObject压力测试全流程
func _run_svtile_autoobject_stress_test() -> void:
	_reset_stress_state()
	if not run_svtile_autoobject_stress:
		return
	if not _initialized or _spa == null or _sv_committer == null:
		_stress_flush_result = {"ok": false, "reason": "spa_or_svtile_not_ready"}
		print("[SPA SVTile] SKIP: %s" % str(_stress_flush_result.get("reason", "")))
		return
	if _profile_ids.is_empty():
		_stress_spawn_result = {"ok": false, "reason": "no_registered_profiles"}
		print("[SPA SVTile] SKIP: no registered profiles")
		return

	_gpu_runtime = _spa.get_gpu_runtime()
	if _gpu_runtime == null or not _gpu_runtime.is_ready():
		_stress_spawn_result = {"ok": false, "reason": "gpu_autoobject_runtime_not_ready"}
		print("[SPA SVTile] FAIL: GPU AutoObject runtime not ready")
		return

	var tile_size := _stress_tile_size()
	var tile_grid := _stress_tile_grid_size(tile_size)
	var tile_counts := PackedInt32Array()
	tile_counts.resize(tile_grid.x * tile_grid.y * tile_grid.z)
	_autoobject_positions.clear()
	_autoobject_asset_indices.clear()
	_autoobject_ids.clear()
	var spawn_records := _build_stress_spawn_records(tile_size, tile_grid, tile_counts, _autoobject_positions, _autoobject_asset_indices)
	_stress_tile_count = tile_counts.size()
	_collect_stress_tile_count_stats(tile_counts)

	var metadata_t0 := Time.get_ticks_msec()
	_sv_committer.mark_scene_voxel_tile_bounds_dirty(
		Vector3i.ZERO,
		_sv_committer.grid_size,
		{"auto": true, "object_refs": true},
		{"id": "spa_svtile_autoobject_stress", "source_id": "gpu_autoobject_batch"}
	)
	var uploaded: bool = _sv_committer.ensure_scene_voxel_tile_buffers_uploaded(true)
	var metadata_ms := Time.get_ticks_msec() - metadata_t0
	if not uploaded:
		_stress_flush_result = _sv_committer.get_scene_voxel_tile_gpu_buffer_summary()
		_stress_flush_result["ok"] = false
		_stress_flush_result["reason"] = str(_stress_flush_result.get("reason", "scene_voxel_tile_upload_failed"))
		print("[SPA SVTile] FAIL: tile metadata upload failed (%s)" % str(_stress_flush_result.get("reason", "")))
		return

	var spawn_t0 := Time.get_ticks_msec()
	_stress_spawn_result = _gpu_runtime.spawn_batch_from_accepted_placement_records(spawn_records, {
		"use_accepted_placement_record_shader": true,
	})
	_stress_spawn_time_ms = float(Time.get_ticks_msec() - spawn_t0)
	if not bool(_stress_spawn_result.get("ok", false)):
		print("[SPA SVTile] FAIL: spawn %d GPU AutoObjects failed: %s" % [
			spawn_records.size(),
			str(_stress_spawn_result.get("reason", "unknown")),
		])
		return
	_cache_autoobject_ids(_stress_spawn_result.get("object_ids", []))

	var flush_t0 := Time.get_ticks_msec()
	_stress_flush_result = _gpu_runtime.flush_to_scene_voxel_committer(_sv_committer, {})
	_stress_flush_time_ms = float(Time.get_ticks_msec() - flush_t0)
	_stress_tile_summary = _sv_committer.get_scene_voxel_tile_gpu_buffer_summary()

	if show_svtile_autoobject_overlay:
		var visual_t0 := Time.get_ticks_msec()
		_build_svtile_autoobject_overlay(tile_counts, _autoobject_positions, _autoobject_asset_indices, tile_grid, tile_size)
		_stress_visual_time_ms = float(Time.get_ticks_msec() - visual_t0)

	var spawned := int(_stress_spawn_result.get("spawned_count", 0))
	var inserted := int(_stress_flush_result.get("object_ref_inserted_slot_count", 0))
	var overflow := int(_stress_flush_result.get("object_ref_overflow_count", 0))
	_stress_ready = bool(_stress_flush_result.get("ok", false)) and inserted == spawned and overflow == 0
	print("[SPA SVTile] Metadata upload: ok=%s tiles=%d grid=%s tile_size=%s (%d ms)" % [
		str(uploaded), _stress_tile_count, str(tile_grid), str(tile_size), metadata_ms,
	])
	print("[SPA SVTile] Spawned GPU AutoObjects: ok=%s count=%d shader=%s dispatch=%d time=%.0f ms" % [
		str(_stress_spawn_result.get("ok", false)),
		spawned,
		str(_stress_spawn_result.get("accepted_placement_record_shader_consumed", false)),
		int(_stress_spawn_result.get("accepted_placement_record_shader_dispatch_count", 0)),
		_stress_spawn_time_ms,
	])
	print("[SPA SVTile] Object refs flush: ok=%s inserted=%d touched=%d overflow=%d dirty_tiles=%d time=%.0f ms" % [
		str(_stress_flush_result.get("ok", false)),
		inserted,
		int(_stress_flush_result.get("object_ref_touched_count", 0)),
		overflow,
		int(_stress_flush_result.get("dirty_scene_voxel_tile_count", _stress_tile_summary.get("dirty_tile_count", 0))),
		_stress_flush_time_ms,
	])
	print("[SPA SVTile] Visualization: tiles=%d occupied=%d refs_per_tile avg=%.2f max=%d object_points=%d time=%.0f ms" % [
		_stress_tile_count,
		_stress_occupied_tile_count,
		(float(_stress_total_refs) / float(maxi(_stress_occupied_tile_count, 1))),
		_stress_max_refs_per_tile,
		_autoobject_positions.size(),
		_stress_visual_time_ms,
	])
	_print_autoobject_selection_self_test()


## 构建压力测试的GPU批量放置记录列表
func _build_stress_spawn_records(
	tile_size: Vector3i,
	tile_grid: Vector3i,
	tile_counts: PackedInt32Array,
	object_positions: Array[Vector3],
	object_asset_indices: Array[int]
) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	var requested_count := maxi(autoobject_count, 0)
	var grid_res := maxi(stress_grid_resolution, 1)
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
		var tile_index := SceneVoxelTileCodecScript.tile_index_from_voxel(voxel_min, _stress_grid_size(), tile_size)
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
	if _stress_overlay_root == null:
		_stress_overlay_root = Node3D.new()
		_stress_overlay_root.name = SVTILE_AUTOOBJECT_OVERLAY_ROOT_NAME
		add_child(_stress_overlay_root, true)
	for child in _stress_overlay_root.get_children():
		child.queue_free()

	_stress_tile_heatmap = _make_tile_heatmap_multimesh(tile_counts, tile_grid, tile_size)
	_stress_tile_heatmap.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_stress_overlay_root.add_child(_stress_tile_heatmap)

	_autoobject_points = _make_object_points_multimesh(object_positions, object_asset_indices)
	_autoobject_points.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_stress_overlay_root.add_child(_autoobject_points)

	_stress_label = Label3D.new()
	_stress_label.name = "SVTileAutoObjectLegend"
	_stress_label.text = "SPA -> GPU AutoObject -> SVTile refs\n%d autoobjects / %d occupied tiles / max %d refs per tile" % [
		object_positions.size(),
		_stress_occupied_tile_count,
		_stress_max_refs_per_tile,
	]
	_stress_label.position = _stress_position_on_terrain_from_voxel_center(Vector3(12.0, 0.0, 12.0), 10.0)
	_stress_label.font_size = 28
	_stress_label.pixel_size = 0.45
	_stress_label.outline_size = 8
	_stress_label.modulate = Color(0.95, 0.98, 1.0, 1.0)
	_stress_overlay_root.add_child(_stress_label)
	_ensure_autoobject_selection_visuals()
	_clear_autoobject_selection(false)
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
		var bounds := SceneVoxelTileCodecScript.tile_bounds(tile_coord, _stress_grid_size(), tile_size)
		var tile_min: Vector3i = bounds.get("voxel_min", Vector3i.ZERO)
		var tile_max: Vector3i = bounds.get("voxel_max", tile_min + Vector3i.ONE)
		var center_voxel := Vector3(
			(float(tile_min.x) + float(tile_max.x)) * 0.5,
			0.0,
			(float(tile_min.z) + float(tile_max.z)) * 0.5
		)
		var center := _stress_position_on_terrain_from_voxel_center(center_voxel, 0.22)
		var size := Vector3(
			maxf(float(tile_max.x - tile_min.x) * _sv_committer.voxel_size.x * 0.88, 0.2),
			0.35,
			maxf(float(tile_max.z - tile_min.z) * _sv_committer.voxel_size.z * 0.88, 0.2)
		)
		transforms.append(Transform3D(Basis().scaled(size), center))
		colors.append(_stress_tile_color(count))
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


## 确保压力测试选中标记和标签节点存在
func _ensure_autoobject_selection_visuals() -> void:
	if _stress_overlay_root == null:
		return
	if _autoobject_selection_marker == null or not is_instance_valid(_autoobject_selection_marker):
		_autoobject_selection_marker = _make_selection_marker("SelectedGPUAutoObjectMarker")
		_stress_overlay_root.add_child(_autoobject_selection_marker)
	_configure_selection_marker(_autoobject_selection_marker)
	if _autoobject_selection_label == null or not is_instance_valid(_autoobject_selection_label):
		_autoobject_selection_label = _make_selection_label("SelectedGPUAutoObjectLabel", SELECT_COLOR)
		_stress_overlay_root.add_child(_autoobject_selection_label)


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
	var label := Label3D.new()
	label.name = node_name
	label.font_size = 24
	label.pixel_size = 0.16
	label.outline_size = 6
	label.modulate = modulate
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


## 设置压力测试点云中单个实例的颜色
func _set_autoobject_instance_color(object_index: int, color: Color) -> void:
	if _autoobject_points == null or _autoobject_points.multimesh == null:
		return
	var mm := _autoobject_points.multimesh
	if object_index < 0 or object_index >= mm.instance_count:
		return
	mm.set_instance_color(object_index, color)


## 若节点有效则隐藏它
func _hide_node_if_valid(node: Node) -> void:
	if node != null and is_instance_valid(node):
		node.visible = false


## 清除GPU AutoObject压力测试选中
func _clear_autoobject_selection(update_hud: bool = true) -> void:
	if _selected_autoobject_index >= 0:
		_set_autoobject_instance_color(_selected_autoobject_index, _autoobject_color(_safe_asset_index(_selected_autoobject_index)))
	_selected_autoobject_index = -1
	_selected_autoobject_record.clear()
	_hide_node_if_valid(_autoobject_selection_marker)
	_hide_node_if_valid(_autoobject_selection_label)
	if update_hud:
		_update_hud()


## 清除体素数据选中
func _clear_data_selection(update_hud: bool = true) -> void:
	_selected_data_record.clear()
	_hide_node_if_valid(_data_selection_marker)
	_hide_node_if_valid(_data_selection_label)
	_update_anchor_sample_bounds_marker()
	if update_hud:
		_update_hud()


## 选中一个GPU AutoObject并显示标记
func _select_autoobject(selection: Dictionary) -> void:
	if selection.is_empty():
		return
	_clear_autoobject_selection(false)
	_clear_data_selection(false)
	_clear_volume_score_selection()
	_selected_autoobject_index = int(selection.get("object_index", -1))
	_selected_autoobject_record = selection.duplicate(true)
	if _selected_autoobject_index < 0:
		return
	_set_autoobject_instance_color(_selected_autoobject_index, SELECT_COLOR)
	_ensure_autoobject_selection_visuals()
	var pos: Vector3 = selection.get("position", Vector3.ZERO)
	var marker_size := _autoobject_point_size() * 2.4
	if _autoobject_selection_marker != null:
		_autoobject_selection_marker.position = pos + Vector3(0.0, marker_size * 0.45, 0.0)
		_autoobject_selection_marker.scale = Vector3(marker_size, marker_size * 1.8, marker_size)
		_autoobject_selection_marker.visible = true
	if _autoobject_selection_label != null:
		_autoobject_selection_label.position = pos + Vector3(0.0, marker_size * 3.2, 0.0)
		_autoobject_selection_label.text = "GPU AutoObject %d\nobject_id=%d  tile=%s" % [
			_selected_autoobject_index,
			int(selection.get("object_id", -1)),
			str(selection.get("tile_coord", Vector3i.ZERO)),
		]
		_autoobject_selection_label.visible = true
	if Engine.is_editor_hint():
		var sel := EditorInterface.get_selection()
		sel.clear()
		if _autoobject_selection_marker != null:
			sel.add_node(_autoobject_selection_marker)
		else:
			sel.add_node(self)
	print("[SPA SVTile] Selected GPU AutoObject: index=%d object_id=%d tile=%s profile_id=%d pos=%s" % [
		_selected_autoobject_index,
		int(selection.get("object_id", -1)),
		str(selection.get("tile_coord", Vector3i.ZERO)),
		int(selection.get("profile_id", -1)),
		str(pos),
	])
	_apply_selection_mode_visuals()
	_update_hud()


## 选中一个数据体素记录并显示标记
func _select_data_record(record: Dictionary) -> void:
	if record.is_empty():
		return
	_clear_autoobject_selection(false)
	_clear_data_selection(false)
	_clear_volume_score_selection()
	_selected_data_record = record.duplicate(true)
	_ensure_data_selection_visuals()
	var pos: Vector3 = record.get("world_position", Vector3.ZERO)
	var marker_size: Vector3 = record.get("marker_size", _default_voxel_marker_size())
	var domain := str(record.get("domain", "data"))
	var color := _selection_domain_color(domain)
	if _data_selection_marker != null:
		_data_selection_marker.position = pos
		_data_selection_marker.scale = marker_size
		var mat := _data_selection_marker.material_override as StandardMaterial3D
		if mat != null:
			mat.albedo_color = color
		_data_selection_marker.visible = true
	if _data_selection_label != null:
		_data_selection_label.position = pos + Vector3(0.0, marker_size.y * 1.25 + 2.0, 0.0)
		_data_selection_label.modulate = color
		_data_selection_label.text = _format_data_selection_label(record)
		_data_selection_label.visible = true
	if Engine.is_editor_hint():
		var sel := EditorInterface.get_selection()
		sel.clear()
		if _data_selection_marker != null:
			sel.add_node(_data_selection_marker)
		else:
			sel.add_node(self)
	print("[SPA Selection] Selected %s: %s" % [domain, str(record.get("id", ""))])
	_update_anchor_sample_bounds_marker(_selected_data_record)
	_apply_selection_mode_visuals()
	_update_hud()


## 确保数据选中标记和标签节点存在
func _ensure_data_selection_visuals() -> void:
	var parent := _stress_overlay_root if _stress_overlay_root != null else self
	if _data_selection_marker == null or not is_instance_valid(_data_selection_marker):
		_data_selection_marker = _make_selection_marker("SelectedDataVoxelMarker")
		parent.add_child(_data_selection_marker)
	_configure_selection_marker(_data_selection_marker)
	if _data_selection_label == null or not is_instance_valid(_data_selection_label):
		_data_selection_label = _make_selection_label("SelectedDataVoxelLabel")
		parent.add_child(_data_selection_label)


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


## 格式化数据选中标签文本
func _format_data_selection_label(record: Dictionary) -> String:
	var domain := str(record.get("domain", "data"))
	var voxel: Vector3i = record.get("voxel_coord", Vector3i.ZERO)
	var tile: Vector3i = record.get("tile_coord", Vector3i.ZERO)
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
		return _stress_tile_heatmap if _stress_tile_heatmap != null else _stress_overlay_root
	return null


## 在场景树中查找TargetSVSetup节点
func _find_targetsv_setup() -> Node:
	if not is_inside_tree():
		return null
	var root := get_tree().edited_scene_root if get_tree() != null else null
	if root != null:
		var found := root.find_child("TargetSVSetup", true, false)
		if found != null:
			return found
	if get_parent() != null:
		var sibling := get_parent().find_child("TargetSVSetup", true, false)
		if sibling != null:
			return sibling
	return find_child("TargetSVSetup", true, false)


## 按网格索引选中GPU AutoObject（API入口）
func select_autoobject_by_index(object_index: int = -1) -> Dictionary:
	if _autoobject_positions.is_empty():
		return {"ok": false, "reason": "no_autoobjects"}
	var idx := object_index
	if idx < 0:
		idx = int(floor(float(_autoobject_positions.size()) * 0.5))
	idx = clampi(idx, 0, _autoobject_positions.size() - 1)
	var selection := _make_autoobject_selection_record(idx, 0.0)
	_select_autoobject(selection)
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


## 自检：对已知位置执行GPU AutoObject拾取验证
func _print_autoobject_selection_self_test() -> void:
	if _autoobject_positions.is_empty():
		return
	var probe_index := mini(_autoobject_positions.size() - 1, maxi(_autoobject_side_count + 1, 0))
	var selection := _nearest_autoobject_at_world(_autoobject_positions[probe_index], null, Vector2.ZERO)
	print("[SPA SVTile] Selection mode: ok=%s probe_index=%d selected_index=%d object_id=%d tile=%s" % [
		str(not selection.is_empty()),
		probe_index,
		int(selection.get("object_index", -1)),
		int(selection.get("object_id", -1)),
		str(selection.get("tile_coord", Vector3i.ZERO)),
	])




## 根据当前选择模式淡化非相关几何体；这只影响显示焦点，不改变拾取优先级
func _apply_selection_mode_visuals() -> void:
	var auto_focus := _selection_mode == SelectionMode.MIXED or _selection_mode == SelectionMode.AUTOOBJECT
	var svtile_focus := _selection_mode == SelectionMode.MIXED or _selection_mode == SelectionMode.SVTILE
	var sv_focus := _selection_mode == SelectionMode.MIXED or _selection_mode == SelectionMode.SV
	var target_focus := _selection_mode == SelectionMode.MIXED or _selection_mode == SelectionMode.TARGETSV
	var anchor_focus := _selection_mode == SelectionMode.MIXED or _selection_mode == SelectionMode.ANCHOR
	var gpu_objects_visible := _voxel_display_is_visible(VOXEL_DISPLAY_GPU_OBJECTS)
	var svtile_visible := _voxel_display_is_visible(VOXEL_DISPLAY_SVTILE)

	if _autoobject_points != null:
		_autoobject_points.visible = gpu_objects_visible
		_autoobject_points.transparency = 0.0 if auto_focus else SELECTION_FADED_TRANSPARENCY
	if _stress_tile_heatmap != null:
		var tile_active := svtile_focus or sv_focus or anchor_focus
		_stress_tile_heatmap.visible = svtile_visible
		_stress_tile_heatmap.transparency = 0.0 if tile_active else SELECTION_FADED_TRANSPARENCY
	if _stress_label != null:
		var label_color := _stress_label.modulate
		_stress_label.visible = gpu_objects_visible or svtile_visible
		label_color.a = 1.0 if (_selection_mode == SelectionMode.MIXED or svtile_focus or sv_focus or anchor_focus) else 0.25
		_stress_label.modulate = label_color

	_apply_targetsv_visuals(target_focus)
	if _autoobject_selection_marker != null:
		_autoobject_selection_marker.visible = _selected_autoobject_index >= 0 and gpu_objects_visible
		_autoobject_selection_marker.transparency = 0.0
	if _autoobject_selection_label != null:
		_autoobject_selection_label.visible = _selected_autoobject_index >= 0 and gpu_objects_visible
	if _data_selection_marker != null:
		_data_selection_marker.visible = _selected_data_record_display_visible()
		_data_selection_marker.transparency = 0.0
	if _data_selection_label != null:
		_data_selection_label.visible = _selected_data_record_display_visible()
	_update_anchor_sample_bounds_marker()
	_apply_all_external_voxel_display_visibility()


## 设置TargetSV体素显示状态和透明度
func _apply_targetsv_visuals(target_focus: bool) -> void:
	var targetsv := _find_targetsv_setup()
	if targetsv == null:
		return
	var target_visible := _voxel_display_is_visible(VOXEL_DISPLAY_TARGETSV)
	if targetsv.has_method("set_display_visible"):
		targetsv.set_display_visible(target_visible)
	var display := targetsv.get_node_or_null("TargetSVVoxels")
	if display != null:
		display.visible = target_visible
	if display is GeometryInstance3D:
		(display as GeometryInstance3D).transparency = 0.0 if target_focus else SELECTION_FADED_TRANSPARENCY


## 根据SVTile引用密度计算热力图颜色
func _stress_tile_color(ref_count: int) -> Color:
	var density := clampf(float(ref_count) / float(maxi(SceneVoxelCommitterScript.SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT, 1)), 0.0, 1.0)
	return Color(0.12 + density * 0.85, 0.58 + density * 0.35, 0.95 - density * 0.55, 0.34 + density * 0.36)


## 越界安全地取得对象的资产索引
func _safe_asset_index(object_index: int) -> int:
	return _autoobject_asset_indices[object_index] if object_index >= 0 and object_index < _autoobject_asset_indices.size() else 0


## 根据资产索引获取GPU点云颜色
func _autoobject_color(asset_idx: int) -> Color:
	var color := CommonDemoAssets.wire_color(asset_idx % maxi(CommonDemoAssets.count(), 1))
	color.a = 0.96
	return color


## 统计SVTile占用数、最大引用数等指标
func _collect_stress_tile_count_stats(tile_counts: PackedInt32Array) -> void:
	_stress_occupied_tile_count = 0
	_stress_max_refs_per_tile = 0
	_stress_total_refs = 0
	for count in tile_counts:
		var c := int(count)
		if c <= 0:
			continue
		_stress_occupied_tile_count += 1
		_stress_total_refs += c
		_stress_max_refs_per_tile = maxi(_stress_max_refs_per_tile, c)


## 从项目设置读取SVTile尺寸
func _stress_tile_size() -> Vector3i:
	return SceneVoxelTileCodecScript.configured_size(
		SceneVoxelCommitterScript.SCENE_VOXEL_TILE_SIZE_SETTING,
		SceneVoxelCommitterScript.DEFAULT_SCENE_VOXEL_TILE_SIZE
	)


## 当前SPA压力测试所使用的SceneVoxel网格尺寸
func _stress_grid_size() -> Vector3i:
	if _sv_committer != null:
		return _sv_committer.grid_size
	return Vector3i(stress_grid_resolution, 1, stress_grid_resolution)


## 根据体素网格计算SVTile网格维度
func _stress_tile_grid_size(tile_size: Vector3i) -> Vector3i:
	return SceneVoxelTileCodecScript.tile_grid_size(_stress_grid_size(), tile_size)


## 根据网格索引反算体素最小坐标
func _stress_voxel_min_from_index(object_index: int) -> Vector3i:
	if _autoobject_side_count <= 0:
		return Vector3i.ZERO
	var px := object_index % _autoobject_side_count
	var pz := int(floor(float(object_index) / float(_autoobject_side_count)))
	return Vector3i(
		clampi(px * _autoobject_spacing_voxels, 0, stress_grid_resolution - 1),
		0,
		clampi(pz * _autoobject_spacing_voxels, 0, stress_grid_resolution - 1)
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
	if not select_gpu_autoobjects or not _stress_ready or not _voxel_display_is_visible(VOXEL_DISPLAY_GPU_OBJECTS):
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
	match _selection_mode:
		SelectionMode.SVTILE:
			if not _voxel_display_is_visible(VOXEL_DISPLAY_SVTILE):
				return {}
			return _pick_svtile_record_with_camera(cam, screen_pos)
		SelectionMode.ANCHOR:
			if not _voxel_display_is_visible(VOXEL_DISPLAY_ANCHOR):
				return {}
			if _volume_score_anchor_display_active():
				return {}
			return _pick_anchor_record_with_camera(cam, screen_pos)
		SelectionMode.SV:
			if not _voxel_display_is_visible(VOXEL_DISPLAY_SV):
				return {}
			return _pick_sv_record_with_camera(cam, screen_pos)
		SelectionMode.TARGETSV:
			if not _voxel_display_is_visible(VOXEL_DISPLAY_TARGETSV):
				return {}
			return _pick_targetsv_record_with_camera(cam, screen_pos)
		SelectionMode.MIXED:
			if _voxel_display_is_visible(VOXEL_DISPLAY_TARGETSV):
				var target_hit := _pick_targetsv_record_with_camera(cam, screen_pos, false)
				if not target_hit.is_empty():
					return target_hit
			if _voxel_display_is_visible(VOXEL_DISPLAY_SVTILE):
				return _pick_svtile_record_with_camera(cam, screen_pos)
	return {}


## 射线命中地形并返回世界坐标和体素坐标
func _pick_voxel_hit_with_camera(cam: Camera3D, screen_pos: Vector2) -> Dictionary:
	if cam == null:
		return {}
	var gpu_hit := _pick_voxel_hit_gpu(cam, screen_pos)
	if not gpu_hit.is_empty():
		return gpu_hit
	var terrain_hit := _ray_to_stress_terrain(cam, screen_pos)
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
func _pick_voxel_hit_gpu(cam: Camera3D, screen_pos: Vector2) -> Dictionary:
	if cam == null:
		return {}
	if _terrain_field.is_empty() or _terrain_field_res <= 0:
		_cache_terrain_field()
	if not _ensure_voxel_pick_gpu():
		return {}
	var capture := TerrainConfigScript.CAPTURE_SIZE
	var res := maxi(stress_grid_resolution, 1)
	var grid_origin := Vector3(-capture * 0.5, 0.0, -capture * 0.5)
	var grid_size := Vector3i(res, 1, res)
	var voxel_size := Vector3(capture / float(res), 1.0, capture / float(res))
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
		var voxel: Vector3i = _sv_committer.world_to_voxel(world_pos, stress_grid_resolution)
		var grid: Vector3i = _sv_committer.grid_size
		return Vector3i(
			clampi(voxel.x, 0, maxi(grid.x - 1, 0)),
			clampi(voxel.y, 0, maxi(grid.y - 1, 0)),
			clampi(voxel.z, 0, maxi(grid.z - 1, 0))
		)
	var capture := TerrainConfigScript.CAPTURE_SIZE
	var res := maxi(stress_grid_resolution, 1)
	var x := clampi(floori(((world_pos.x / capture) + 0.5) * float(res)), 0, res - 1)
	var z := clampi(floori(((world_pos.z / capture) + 0.5) * float(res)), 0, res - 1)
	return Vector3i(x, 0, z)


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
	if not _ensure_voxel_pick_gpu():
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
	var voxel_size: Vector3 = _sv_committer.voxel_size if _sv_committer != null else Vector3(
		TerrainConfigScript.CAPTURE_SIZE / float(maxi(stress_grid_resolution, 1)),
		1.0,
		TerrainConfigScript.CAPTURE_SIZE / float(maxi(stress_grid_resolution, 1))
	)
	var bounds := SceneVoxelTileCodecScript.tile_bounds(tile_coord, _stress_grid_size(), tile_size)
	var voxel_min: Vector3i = bounds.get("voxel_min", Vector3i.ZERO)
	var voxel_max: Vector3i = bounds.get("voxel_max", voxel_min + Vector3i.ONE)
	var center_voxel := Vector3(
		(float(voxel_min.x) + float(voxel_max.x)) * 0.5,
		0.0,
		(float(voxel_min.z) + float(voxel_max.z)) * 0.5
	)
	var center := _stress_position_on_terrain_from_voxel_center(center_voxel, 1.0)
	var size := Vector3(
		maxf(float(voxel_max.x - voxel_min.x) * voxel_size.x * 0.96, 0.2),
		2.5,
		maxf(float(voxel_max.z - voxel_min.z) * voxel_size.z * 0.96, 0.2)
	)
	return {"position": center, "size": size}


## 计算体素选中标记的世界位置（带高度偏移）
func _selection_voxel_marker_position(voxel: Vector3i, y_offset: float) -> Vector3:
	var world := _voxel_center_to_world(voxel, 0.0)
	world.y = _sample_height(world.x, world.z) + y_offset
	return world


## 对地形高度场做射线检测（步进+二分求精）
func _ray_to_stress_terrain(cam: Camera3D, screen_pos: Vector2) -> Dictionary:
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
	var tile_size := _stress_tile_size()
	return SceneVoxelTileCodecScript.tile_info_for_voxel(voxel, _stress_grid_size(), tile_size)


## 由 GPU AutoObject 索引构建统一的选中记录字典
func _make_autoobject_selection_record(object_index: int, screen_score: float) -> Dictionary:
	var asset_idx := _safe_asset_index(object_index)
	var voxel_min := _stress_voxel_min_from_index(object_index)
	var tile := _tile_info_for_voxel(voxel_min)
	return {
		"domain": SELECTION_DOMAIN_AUTOOBJECT,
		"geometry": SELECTION_GEOMETRY_GPU_POINT,
		"id": "gpu_autoobject:%d" % _autoobject_id_for_index(object_index),
		"object_index": object_index,
		"object_id": _autoobject_id_for_index(object_index),
		"asset_index": asset_idx,
		"asset_name": CommonDemoAssets.asset_name(asset_idx, "unknown"),
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
	var voxel_x: float = ((world_pos.x - _sv_committer.grid_origin.x) / _sv_committer.voxel_size.x) - 0.5
	var voxel_z: float = ((world_pos.z - _sv_committer.grid_origin.z) / _sv_committer.voxel_size.z) - 0.5
	var base_px := int(round(voxel_x / float(_autoobject_spacing_voxels)))
	var base_pz := int(round(voxel_z / float(_autoobject_spacing_voxels)))
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
		var res := maxi(stress_grid_resolution, 1)
		var cell := TerrainConfigScript.CAPTURE_SIZE / float(res)
		return SceneVoxelCommitterScript.voxel_float_center_to_world_static(
			voxel_center,
			Vector3(-TerrainConfigScript.CAPTURE_SIZE * 0.5, 0.0, -TerrainConfigScript.CAPTURE_SIZE * 0.5),
			Vector3(cell, 1.0, cell),
			y
		)
	return SceneVoxelCommitterScript.voxel_float_center_to_world_static(
		voxel_center,
		_sv_committer.grid_origin,
		_sv_committer.voxel_size,
		y
	)


## 体素中心→地形表面世界坐标
func _stress_position_on_terrain_from_voxel_center(voxel_center: Vector3, y_offset: float) -> Vector3:
	var world_pos := _voxel_float_center_to_world(voxel_center, 0.0)
	world_pos.y = _sample_height(world_pos.x, world_pos.z) + y_offset
	return world_pos


## 压力测试对象→地形表面世界坐标
func _autoobject_position_on_terrain(voxel: Vector3i) -> Vector3:
	var center := Vector3(float(voxel.x) + 0.5, float(voxel.y) + 0.5, float(voxel.z) + 0.5)
	return _stress_position_on_terrain_from_voxel_center(center, _autoobject_point_size() * 0.9)


## GPU AutoObject点云的点尺寸
func _autoobject_point_size() -> float:
	if _sv_committer == null:
		return 1.0
	return maxf(minf(_sv_committer.voxel_size.x, _sv_committer.voxel_size.z) * 0.52, 0.35)


## 重置所有压力测试状态变量和节点
func _reset_stress_state() -> void:
	_stress_ready = false
	_stress_spawn_result.clear()
	_stress_flush_result.clear()
	_stress_tile_summary.clear()
	_stress_spawn_time_ms = 0.0
	_stress_flush_time_ms = 0.0
	_stress_visual_time_ms = 0.0
	_stress_tile_count = 0
	_stress_occupied_tile_count = 0
	_stress_max_refs_per_tile = 0
	_stress_total_refs = 0
	_autoobject_positions.clear()
	_autoobject_asset_indices.clear()
	_autoobject_ids.clear()
	_autoobject_side_count = 0
	_autoobject_spacing_voxels = 1
	_selected_autoobject_index = -1
	_selected_autoobject_record.clear()
	if _stress_overlay_root != null:
		for child in _stress_overlay_root.get_children():
			child.queue_free()
	_autoobject_selection_marker = null
	_autoobject_selection_label = null


# ---- mesh + terrain --------------------------------------------------------

## 从配置路径加载网格资源
func _load_meshes() -> void:
	_meshes.clear()
	for path in CommonDemoAssets.geo_paths():
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
	return select_gpu_autoobjects \
		and _voxel_display_is_visible(VOXEL_DISPLAY_GPU_OBJECTS) \
		and (_selection_mode == SelectionMode.MIXED or _selection_mode == SelectionMode.AUTOOBJECT)


## 检查是否有任何类型的选中状态
func _has_active_selection() -> bool:
	return _selected_autoobject_index >= 0 \
		or not _selected_data_record.is_empty() \
		or _has_volume_score_selection()


## 鼠标点击的统一选择入口。
## 顺序很重要：
## 1. Mixed/AutoObject 先尝试 GPU AutoObject 点云。
## 2. Mixed/Anchor 再尝试外部 volume-score anchor provider。
## 3. 最后按当前数据模式构建 SVTile/SV/Anchor/TargetSV 记录。
func _select_current_mode_at_screen_position(cam: Camera3D, screen_pos: Vector2) -> Dictionary:
	if _selection_allows_gpu_autoobjects():
		var gpu_hit := _pick_autoobject_with_camera(cam, screen_pos)
		if not gpu_hit.is_empty():
			_select_autoobject(gpu_hit)
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
		_select_data_record(data_hit)
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
			_run_svtile_autoobject_stress_test()
			_update_hud()
			return true
	return false


## 键码→选择模式枚举映射；顺序必须和 SELECTION_MODE_NAMES / 插件工具栏一致
func _selection_mode_from_keycode(keycode: int) -> int:
	match keycode:
		KEY_0:
			return SelectionMode.MIXED
		KEY_1:
			return SelectionMode.AUTOOBJECT
		KEY_2:
			return SelectionMode.SVTILE
		KEY_3:
			return SelectionMode.ANCHOR
		KEY_4:
			return SelectionMode.SV
		KEY_5:
			return SelectionMode.TARGETSV
	return -1


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
	_clear_autoobject_selection(false)
	_clear_data_selection(false)
	_clear_volume_score_selection()
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
	_hud_label = CommonDemoUI.setup_hud_label(self)


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
	if run_svtile_autoobject_stress:
		var spawned := int(_stress_spawn_result.get("spawned_count", 0))
		var inserted := int(_stress_flush_result.get("object_ref_inserted_slot_count", 0))
		var overflow := int(_stress_flush_result.get("object_ref_overflow_count", 0))
		var touched := int(_stress_flush_result.get("object_ref_touched_count", 0))
		var dirty_tiles := int(_stress_flush_result.get("dirty_scene_voxel_tile_count", _stress_tile_summary.get("dirty_tile_count", 0)))
		var avg_refs := float(_stress_total_refs) / float(maxi(_stress_occupied_tile_count, 1))
		lines.append("AutoObjects: %s   spawned: %d/%d   SVTile refs inserted: %d" % [
			"PASS" if _stress_ready else "PENDING/FAIL",
			spawned,
			autoobject_count,
			inserted,
		])
		lines.append("Tiles: %d occupied / %d total   avg refs/tile %.2f   max %d   overflow %d" % [
			_stress_occupied_tile_count,
			_stress_tile_count,
			avg_refs,
			_stress_max_refs_per_tile,
			overflow,
		])
		lines.append("Dirty/touched: %d tiles / %d refs   spawn %.0f ms   flush %.0f ms   visual %.0f ms" % [
			dirty_tiles,
			touched,
			_stress_spawn_time_ms,
			_stress_flush_time_ms,
			_stress_visual_time_ms,
		])
	lines.append("")
	lines.append("LMB: select under current mode (GPU AutoObject / data voxel)")
	lines.append("G: GPU report   Space: re-register + re-spawn   Esc: deselect")
	if _selected_autoobject_index >= 0 and not _selected_autoobject_record.is_empty():
		var pos: Vector3 = _selected_autoobject_record.get("position", Vector3.ZERO)
		var voxel_min: Vector3i = _selected_autoobject_record.get("voxel_min", Vector3i.ZERO)
		var voxel_max: Vector3i = _selected_autoobject_record.get("voxel_max", Vector3i.ZERO)
		lines.append("")
		lines.append("Selected GPU AutoObject: index=%d  object_id=%d  asset=%s  profile_id=%d" % [
			_selected_autoobject_index,
			int(_selected_autoobject_record.get("object_id", -1)),
			str(_selected_autoobject_record.get("asset_name", "unknown")),
			int(_selected_autoobject_record.get("profile_id", -1)),
		])
		lines.append("  tile=%s  voxel=(%s -> %s)" % [
			str(_selected_autoobject_record.get("tile_coord", Vector3i.ZERO)),
			str(voxel_min),
			str(voxel_max),
		])
		lines.append("  terrain pos: (%.1f, %.1f, %.1f)" % [pos.x, pos.y, pos.z])
	if not _selected_data_record.is_empty():
		var domain := str(_selected_data_record.get("domain", "data"))
		var voxel: Vector3i = _selected_data_record.get("voxel_coord", Vector3i.ZERO)
		var tile: Vector3i = _selected_data_record.get("tile_coord", Vector3i.ZERO)
		var pos: Vector3 = _selected_data_record.get("world_position", Vector3.ZERO)
		lines.append("")
		lines.append("Selected %s: %s" % [domain, str(_selected_data_record.get("id", ""))])
		lines.append("  voxel=%s  tile=%s  pos=(%.1f, %.1f, %.1f)" % [
			str(voxel), str(tile), pos.x, pos.y, pos.z
		])
		if domain == SELECTION_DOMAIN_SVTILE:
			lines.append("  object refs=%d" % int(_selected_data_record.get("object_ref_count", 0)))
		elif domain == SELECTION_DOMAIN_SV or domain == SELECTION_DOMAIN_TARGETSV:
			lines.append("  complexity=%.3f  collision=%.3f" % [
				float(_selected_data_record.get("complexity", 0.0)),
				float(_selected_data_record.get("collision", 0.0)),
			])
		elif domain == SELECTION_DOMAIN_ANCHOR:
			lines.append("  kind=%s  complexity=%.3f" % [
				str(_selected_data_record.get("anchor_kind", "candidate")),
				float(_selected_data_record.get("complexity", 0.0)),
			])
	_hud_label.text = "\n".join(lines)


# ---- Camera ----------------------------------------------------------------

## 将相机定位到地形框景位置
func _frame_camera() -> void:
	var cam := find_child("FlyCamera", true, false) as Camera3D
	if cam == null and get_parent() != null:
		cam = get_parent().find_child("FlyCamera", true, false) as Camera3D
	if cam == null:
		return
	var half := TerrainConfigScript.CAPTURE_SIZE * 0.5
	var target_y := TerrainConfigScript.MAX_HEIGHT * 0.35 if run_svtile_autoobject_stress else 20.0
	cam.global_position = Vector3(-half * 0.45, half * 0.82, half * 0.95)
	cam.look_at(Vector3(0.0, target_y, 0.0), Vector3.UP)
	cam.fov = 60.0
	cam.far = 3000.0
	cam.current = true
	_editor_camera = cam


## 获取当前激活的Camera3D
func _get_camera() -> Camera3D:
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		return cam
	if get_parent() != null:
		return get_parent().find_child("FlyCamera", true, false) as Camera3D
	return find_child("FlyCamera", true, false) as Camera3D


## 每帧更新（编辑器模式占位，当前无 per-frame 同步需求）
func _process(_delta: float) -> void:
	if not Engine.is_editor_hint():
		return
	if is_scene_startup_blocked():
		return


## 节点退出场景树时释放SPA资源
func _exit_tree() -> void:
	_dispose_spa_components(true)
