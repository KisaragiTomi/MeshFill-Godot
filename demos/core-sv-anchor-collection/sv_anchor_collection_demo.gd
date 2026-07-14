@tool
extends "res://scripts/core_demo_contract_fixture.gd"

# Anchor collection demo: cached TargetSV + terrain height → GPU prefilter.
#
# Uses TargetSVLoader for cached buffers, TerrainInitializer for height field,
# VoxelDisplay.build_field_gpu for TargetSV rendering (same pipeline as
# target-sv-point-cloud-conversion-c demo).

const TargetSVLoaderScript := preload("res://scripts/target_sv_loader.gd")
const TargetSceneVoxelGeneratorScript := preload("res://scripts/target_scene_voxel_generator.gd")
const VoxelFieldDisplayGPU := preload("res://scripts/utils/voxel_field_display_gpu.gd")
const ScenePlacementActorScript := preload("res://scripts/scene_placement_actor.gd")
const VoxelDisplay := preload("res://scripts/utils/voxel_display.gd")
const BufferUtils := preload("res://scripts/utils/buffer_utils.gd")
const DemoUI := preload("res://scripts/utils/demo_ui.gd")
const DemoAssets := preload("res://scripts/utils/demo_assets.gd")
const SceneVoxelFixture := preload("res://scripts/utils/voxel_fixtures.gd")

const TILE_SIZE := 8

const LAYER_SUPPORT := "support"
const LAYER_DEMAND := "demand"
const LAYER_CANDIDATE := "candidate"
const LAYER_ANCHOR := "anchor"
const LAYER_TARGETSV := "targetsv"

const COLOR_SUPPORT := Color(0.45, 0.45, 0.5, 0.45)
const COLOR_DEMAND := Color(0.7, 0.25, 1.0, 0.5)
const COLOR_HIT := Color(0.2, 1.0, 0.35, 0.85)
const COLOR_CANDIDATE := Color(0.4, 0.85, 1.0, 0.6)

const MAX_DISPLAY_VOXELS := 8192
const LAYER_SAMPLE_STRIDE := 4
const TERRAIN_OCCUPANCY_THRESHOLD := 0.3

@export_range(0.0, 1.0, 0.01) var max_complexity_field: float = 0.15
@export_range(0.0, 1.0, 0.01) var max_collision_field: float = 0.05
@export_range(0.0, 1.0, 0.01) var min_support: float = 0.25
@export_range(0.0, 1.0, 0.01) var min_target_interest: float = 0.01

var _grid := Vector3i.ZERO
var _voxel_size := Vector3.ONE
var _grid_origin := Vector3.ZERO
var _complexity_field := PackedFloat32Array()
var _collision_field := PackedFloat32Array()
var _target_field := PackedFloat32Array()
var _terrain_height := PackedFloat32Array()
var _gpu_field_cache: Dictionary = {}
var _targetsv_node: MultiMeshInstance3D
var _assets: Array = []
var _spa: Object
var _anchor_set := {}
var _anchor_count := 0
var _collected := false
var _last_reason := ""
var _current_layer := LAYER_ANCHOR
var _display_root: Node3D
var _hud_label: Label
var _targetsv_valid := false
var _anchor_list: Array[Dictionary] = []
var _topk_data: Dictionary = {}
var _selected_anchor_id: int = -1
var _selected_anchor_pos := Vector3i(-1, -1, -1)
## CoreSPADemo（SPA 反馈拥有者）——点选 + marker/label/红框由它画；本 demo 作 provider 出数据。
var _spa_host: Node


func _ready() -> void:
	super._ready()
	if is_scene_startup_blocked():
		return
	_setup_visualization()
	_setup_hud()
	_deferred_init.call_deferred()


func _deferred_init() -> void:
	if not Engine.is_editor_hint() or not is_inside_tree():
		return
	_build_fields_from_terrain()
	_build_assets()
	if _targetsv_valid:
		_run_collection()
	_register_with_spa_host()
	_show_layer(LAYER_ANCHOR)
	_frame_camera.call_deferred()


func _frame_camera() -> void:
	if not is_inside_tree():
		return
	var cam := DemoUI.find_camera(self, "DemoSetup/FlyCamera", "", false, false)
	if cam == null or not cam.is_inside_tree():
		return
	var cx := _grid_origin.x + float(_grid.x) * _voxel_size.x * 0.5
	var cz := _grid_origin.z + float(_grid.z) * _voxel_size.z * 0.5
	var avg_h := _avg_terrain_height()
	var cy := avg_h + float(_grid.y) * _voxel_size.y * 0.5
	var extent := maxf(float(_grid.x) * _voxel_size.x, float(_grid.z) * _voxel_size.z)
	cam.global_position = Vector3(cx + extent * 0.5, cy + extent * 0.35, cz + extent * 0.5)
	cam.look_at(Vector3(cx, cy, cz), Vector3.UP)
	cam.fov = 55.0


func _avg_terrain_height() -> float:
	if _terrain_height.is_empty():
		return 0.0
	var total := 0.0
	var count := 0
	var step := maxi(_terrain_height.size() / 256, 1)
	for i in range(0, _terrain_height.size(), step):
		total += _terrain_height[i]
		count += 1
	return total / maxf(float(count), 1.0)


func _exit_tree() -> void:
	if _spa_host != null and is_instance_valid(_spa_host) and _spa_host.has_method("unregister_volume_score_provider"):
		_spa_host.call("unregister_volume_score_provider", self)
	_spa_host = null
	if _spa != null:
		_spa.dispose(false)
		_spa = null
	for asset in _assets:
		if is_instance_valid(asset):
			asset.free()
	_assets.clear()


# --- Field construction from real terrain + TargetSV -----------------------

func _build_fields_from_terrain() -> void:
	_targetsv_valid = false
	var meta := TargetSVLoaderScript.metadata()
	if meta.is_empty():
		push_error("[SVAnchorDemo] TargetSVLoader metadata empty")
		return

	var texture_size := int(meta.get("texture_size", 256))
	var slice_count := int(meta.get("slice_count", 16))
	var capture_size := float(meta.get("capture_size", 1020.0))
	var vertical_span := float(meta.get("vertical_span", 32.0))

	_grid = Vector3i(texture_size, slice_count, texture_size)
	var voxel_count := VoxelGeneral.voxel_count(_grid)
	_voxel_size = VoxelGeneral.voxel_size_for_resolution(
		capture_size,
		texture_size,
		vertical_span / maxf(float(slice_count), 1.0)
	)
	_grid_origin = VoxelGeneral.default_grid_origin(capture_size)

	var visual_raw := TargetSVLoaderScript.visual_bytes()
	var collision_raw := TargetSVLoaderScript.collision_bytes()
	if visual_raw.is_empty():
		push_error("[SVAnchorDemo] TargetSVLoader visual_bytes empty")
		return

	var decoded := TargetSceneVoxelGeneratorScript.decode_target_read_buffers_gpu(
		visual_raw, collision_raw, texture_size, slice_count)
	if not bool(decoded.get("valid", false)):
		decoded = TargetSceneVoxelGeneratorScript.decode_target_read_buffers(
			visual_raw, collision_raw, texture_size, slice_count)
	if not bool(decoded.get("valid", false)):
		push_error("[SVAnchorDemo] TargetSV decode failed: %s" % str(decoded))
		return

	var occupancy: PackedFloat32Array = decoded.get("target_completeness", PackedFloat32Array())
	var target_color: PackedColorArray = decoded.get("target_color", PackedColorArray())
	var collision_decoded: PackedFloat32Array = decoded.get("target_collision", PackedFloat32Array())
	_target_field = PackedFloat32Array()
	_target_field.resize(voxel_count * 4)
	for i in range(voxel_count):
		var c := target_color[i] if i < target_color.size() else Color(0.0, 0.0, 0.0, 0.0)
		_target_field[i * 4 + 0] = c.r
		_target_field[i * 4 + 1] = c.g
		_target_field[i * 4 + 2] = c.b
		_target_field[i * 4 + 3] = occupancy[i] if i < occupancy.size() else c.a

	# 刻意的受控脚手架(勿改成整层真实 complexity):y=0 作「地面/支撑层」,complexity 硬编码 1.0
	# 提供 support 信号,collision 取真实 TargetSV;y>0 的 complexity/collision 保持 0,让表面候选
	# 体素满足「自身够空(≤ 阈值)+ 脚下有支撑」的 anchor 判定。若把整层换成真实 complexity,占据
	# 体素自身复杂度超阈值 → 采集不到任何 anchor(本 demo 的规则演示会失效)。
	_complexity_field = PackedFloat32Array()
	_complexity_field.resize(voxel_count)
	_collision_field = PackedFloat32Array()
	_collision_field.resize(voxel_count)
	for z in range(texture_size):
		for x in range(texture_size):
			var idx := VoxelGeneral.voxel_index(Vector3i(x, 0, z), _grid)
			_complexity_field[idx] = 1.0
			_collision_field[idx] = collision_decoded[idx] if idx < collision_decoded.size() else 1.0

	var terrain := TerrainInitializerScript.find_edit_time_terrain(self) as MeshInstance3D
	var max_h := float(meta.get("max_height", 120.0))
	_terrain_height = TerrainInitializerScript.terrain_height_field_from_mesh(
		terrain, texture_size, max_h)

	var color_rgba := PackedFloat32Array()
	color_rgba.resize(voxel_count * 4)
	for i in range(mini(voxel_count, target_color.size())):
		var c := target_color[i]
		color_rgba[i * 4] = c.r; color_rgba[i * 4 + 1] = c.g
		color_rgba[i * 4 + 2] = c.b; color_rgba[i * 4 + 3] = c.a
	_gpu_field_cache = {
		"texture_size": texture_size, "slice_count": slice_count,
		"capture_size": capture_size, "vertical_span": vertical_span,
		"height_span": max_h, "voxel_count": voxel_count,
		"occupancy": occupancy,
		"collision": collision_decoded,
		"color_rgba": color_rgba,
		"terrain_height": _terrain_height.duplicate(),
	}

	_targetsv_valid = true
	print("[SVAnchorDemo] Cached TargetSV: grid=%s voxels=%d non_empty=%d" % [
		str(_grid), voxel_count, int(meta.get("non_empty_voxel_count", 0))])


func _voxel_index(p: Vector3i) -> int:
	return VoxelGeneral.voxel_index(p, _grid)


func _voxel_count() -> int:
	return VoxelGeneral.voxel_count(_grid)


# --- Assets ----------------------------------------------------------------

func _build_assets() -> void:
	_assets = DemoAssets.make_sv_anchor_collection_assets()


func _sync_assets_with_spa() -> bool:
	if RenderingServer.get_rendering_device() == null:
		_last_reason = "missing_rendering_device"
		return false
	if _spa == null:
		_spa = ScenePlacementActorScript.new()
	if not _spa.is_initialized():
		if not _spa.initialize(true, true):
			_last_reason = "spa_initialize_failed"
			return false
	if not _spa.replace_all_autoobject_assets(_assets):
		_last_reason = "spa_asset_registration_failed"
		return false
	return true


# --- GPU collection --------------------------------------------------------

func _run_collection() -> void:
	_anchor_set = {}
	_anchor_list.clear()
	_topk_data = {}
	_anchor_count = 0
	_last_reason = ""
	_selected_anchor_id = -1
	_selected_anchor_pos = Vector3i(-1, -1, -1)
	if not _targetsv_valid:
		_last_reason = "targetsv_not_valid"
		return
	if RenderingServer.get_rendering_device() == null:
		_last_reason = "missing_rendering_device"
		return
	if not _sync_assets_with_spa():
		return

	var sv := SceneVoxelFixture.make_sv(
		_grid,
		_voxel_size,
		_grid_origin,
		_complexity_field,
		_collision_field,
		TILE_SIZE
	)
	# GPU-resident-only：目标场以自建常驻缓冲交接给 prefilter（CPU 字节上传路径已删除）。
	var rd: RenderingDevice = _spa.get_rendering_device()
	if rd == null:
		_last_reason = "missing_rendering_device"
		return
	var target_field_bytes := _target_field.to_byte_array()
	var target_field_buf := rd.storage_buffer_create(target_field_bytes.size(), target_field_bytes)
	# run_autoobject_prefilter 的 dirty_tile_ids 形参是 Array[int]；传无类型 [] 会在
	# 运行时报"元素类型不一致"并中断 _run_collection（锚点列表建不起来 → 点选无锚点可命中）。
	var no_dirty_tiles: Array[int] = []
	var result: Dictionary = _spa.run_autoobject_prefilter(
		sv,
		no_dirty_tiles,
		{
			"target_field_buffer": target_field_buf,
			"rendering_device": rd,
			"target_field_byte_count": target_field_bytes.size(),
			"resident_target_read_buffer_handoff": true,
			"resident_target_read_buffer_owner": "sv_anchor_collection_demo",
			"debug_readback_topk": true,
		},
		{
			"max_complexity_field": max_complexity_field,
			"max_collision_field": max_collision_field,
			"min_support": min_support,
			"min_target_interest": min_target_interest,
			"min_prefilter_score": 0.0,
			"debug_read_anchors": true,  # this demo visualizes anchors, so opt into the readback
		}
	)
	rd.free_rid(target_field_buf)
	_last_reason = str(result.get("prefilter_reason", result.get("reason", "")))
	var anchors: Array = result.get("anchors", [])
	for anchor in anchors:
		if anchor is Dictionary:
			var d := anchor as Dictionary
			var pos := d.get("voxel_pos", Vector3i(-1, -1, -1)) as Vector3i
			_anchor_set[pos] = true
			_anchor_list.append(d)
	_topk_data = result.get("anchor_autoobject_topk", {})
	_anchor_count = _anchor_set.size()
	_collected = true
	print("[SVAnchorDemo] Collected %d anchors, topk entries=%d (reason=%s)" % [
		_anchor_count, _topk_data.size(), _last_reason])


# --- Visualization ---------------------------------------------------------

func _setup_visualization() -> void:
	_display_root = Node3D.new()
	_display_root.name = "AnchorDisplay"
	add_child(_display_root)


func _world_center(p: Vector3i) -> Vector3:
	return VoxelGeneral.terrain_relative_voxel_center_to_world(
		p, _grid, _grid_origin, _voxel_size, _terrain_height)


func _show_layer(layer: String) -> void:
	_current_layer = layer
	for child in _display_root.get_children():
		child.free()
	_targetsv_node = null

	if layer == LAYER_TARGETSV:
		_build_targetsv_gpu_display()
		_update_hud()
		return

	var centers := PackedVector3Array()
	var colors := PackedColorArray()
	match layer:
		LAYER_ANCHOR:
			_collect_anchor_cells(centers, colors)
		LAYER_SUPPORT:
			_collect_support_cells(centers, colors)
		LAYER_DEMAND:
			_collect_demand_cells(centers, colors)
		LAYER_CANDIDATE:
			_collect_candidate_cells(centers, colors)

	if not centers.is_empty():
		var node := VoxelDisplay.build_colored(centers, _voxel_size, colors, {
			"name": "Layer_%s" % layer, "unshaded": true})
		if node != null:
			_display_root.add_child(node)
	_update_hud()


func _collect_anchor_cells(centers: PackedVector3Array, colors: PackedColorArray) -> void:
	# 选中高亮由 SPA 的 SelectedVoxelMarker 负责；这里所有锚点统一色。
	for pos in _anchor_set.keys():
		centers.append(_world_center(pos))
		colors.append(COLOR_HIT)


func _collect_support_cells(centers: PackedVector3Array, colors: PackedColorArray) -> void:
	_iterate_grid_sampled(func(idx: int, p: Vector3i) -> bool:
		var support := maxf(
			_complexity_field[idx] if idx < _complexity_field.size() else 0.0,
			_collision_field[idx] if idx < _collision_field.size() else 0.0)
		if support >= min_support:
			centers.append(_world_center(p))
			colors.append(COLOR_SUPPORT)
			return centers.size() >= MAX_DISPLAY_VOXELS
		return false)


func _collect_demand_cells(centers: PackedVector3Array, colors: PackedColorArray) -> void:
	_iterate_grid_sampled(func(idx: int, p: Vector3i) -> bool:
		var demand := _target_field[idx * 4 + 3] if idx * 4 + 3 < _target_field.size() else 0.0
		if demand >= min_target_interest:
			centers.append(_world_center(p))
			colors.append(COLOR_DEMAND)
			return centers.size() >= MAX_DISPLAY_VOXELS
		return false)


func _collect_candidate_cells(centers: PackedVector3Array, colors: PackedColorArray) -> void:
	_iterate_grid_sampled(func(idx: int, p: Vector3i) -> bool:
		var cx := _complexity_field[idx] if idx < _complexity_field.size() else 0.0
		var cv := _collision_field[idx] if idx < _collision_field.size() else 0.0
		var demand := _target_field[idx * 4 + 3] if idx * 4 + 3 < _target_field.size() else 0.0
		if cx > max_complexity_field or cv > max_collision_field or demand < min_target_interest:
			return false
		if p.y > 0:
			var bi := _voxel_index(Vector3i(p.x, p.y - 1, p.z))
			var support := maxf(
				_complexity_field[bi] if bi < _complexity_field.size() else 0.0,
				_collision_field[bi] if bi < _collision_field.size() else 0.0)
			if support >= min_support:
				centers.append(_world_center(p))
				colors.append(COLOR_CANDIDATE)
				return centers.size() >= MAX_DISPLAY_VOXELS
		return false)


func _build_targetsv_gpu_display() -> void:
	if _targetsv_node != null and is_instance_valid(_targetsv_node):
		_targetsv_node.free()
		_targetsv_node = null
	if _gpu_field_cache.is_empty():
		return
	var texture_size := int(_gpu_field_cache["texture_size"])
	var slice_count := int(_gpu_field_cache["slice_count"])
	var capture_size := float(_gpu_field_cache["capture_size"])
	var vertical_span := float(_gpu_field_cache["vertical_span"])
	var height_span := float(_gpu_field_cache["height_span"])
	var voxel_count := int(_gpu_field_cache["voxel_count"])
	var cell_size := capture_size / maxf(float(texture_size - 1), 1.0)
	var slice_height := vertical_span / maxf(float(slice_count), 1.0)
	var cell := Vector3(cell_size, slice_height, cell_size)
	var half := capture_size * 0.5 + cell_size
	var y_max := (height_span + vertical_span) + cell_size
	var aabb := AABB(Vector3(-half, -cell_size, -half), Vector3(2.0 * half, y_max + 2.0 * cell_size, 2.0 * half))
	var instance := VoxelDisplay.build_field_gpu(
		voxel_count, cell, aabb,
		{
			"occupancy": _gpu_field_cache["occupancy"],
			"collision": _gpu_field_cache["collision"],
			"color_rgba": _gpu_field_cache["color_rgba"],
			"terrain_height": _gpu_field_cache["terrain_height"],
		},
		{
			"xz_res": texture_size, "slice_count": slice_count,
			"view_mode": VoxelFieldDisplayGPU.VIEW_TARGET_COLOR,
			"capture_size": capture_size, "display_scale": 1.0,
			"vertical_span": vertical_span, "height_span": height_span,
			"threshold": 0.001,
		},
		{"name": "TargetSVVoxels", "fill": 1.0})
	if instance != null:
		_targetsv_node = instance
		_display_root.add_child(instance)


func _iterate_grid_sampled(callback: Callable) -> void:
	var stride := LAYER_SAMPLE_STRIDE if _voxel_count() > MAX_DISPLAY_VOXELS * 2 else 1
	for y in range(_grid.y):
		for z in range(0, _grid.z, stride):
			for x in range(0, _grid.x, stride):
				var p := Vector3i(x, y, z)
				var idx := _voxel_index(p)
				if callback.call(idx, p):
					return


# --- HUD & input -----------------------------------------------------------

func _setup_hud() -> void:
	_hud_label = DemoUI.setup_hud_label(self)


func _update_hud() -> void:
	if _hud_label == null:
		return
	var rd_line := "GPU: ready" if RenderingServer.get_rendering_device() != null else "GPU: no RenderingDevice"
	var sv_line := "TargetSV: %s  grid=%s  voxel_size=%s" % [
		"valid" if _targetsv_valid else "INVALID", str(_grid), str(_voxel_size)]
	var reason := _last_reason if not _last_reason.is_empty() else "ok"
	var collected_line := "anchors = %d   assets = %d   reason = %s" % [_anchor_count, _assets.size(), reason] if _collected else "not computed — press Shift+G"
	var lines := [
		"SV Anchor Collection (terrain + TargetSV)",
		rd_line,
		sv_line,
		"layer = %s   (1:support 2:demand 3:candidate 4:anchor 5:targetsv)" % _current_layer,
		collected_line,
		"max_cx=%.2f max_coll=%.2f min_support=%.2f min_target=%.2f" % [
			max_complexity_field, max_collision_field, min_support, min_target_interest],
		"Click: select anchor   Esc: deselect   Shift+G: recompute   R: re-run",
	]
	lines.append_array(_build_topk_hud_lines())
	_hud_label.text = "\n".join(lines)


func _build_topk_hud_lines() -> Array[String]:
	var lines: Array[String] = []
	if _selected_anchor_id < 0:
		lines.append("--- click an anchor to inspect top-k ---")
		return lines
	lines.append("--- selected anchor #%d  pos=%s ---" % [_selected_anchor_id, str(_selected_anchor_pos)])
	var entries: Array = _topk_data.get(_selected_anchor_id, [])
	if entries.is_empty():
		lines.append("  (no top-k data for this anchor)")
		return lines
	for entry in entries:
		if not entry is Dictionary:
			continue
		var d := entry as Dictionary
		var aid := int(d.get("asset_id", -1))
		var score := float(d.get("score", -1.0))
		var rank := int(d.get("rank", -1))
		var asset_name := _asset_name_by_id(aid)
		lines.append("  rank %d: asset #%d [%s]  score=%.4f" % [rank, aid, asset_name, score])
	return lines


func _asset_name_by_id(asset_index: int) -> String:
	if asset_index >= 0 and asset_index < _assets.size():
		var obj = _assets[asset_index]
		if obj != null:
			return obj.name
	return "?"


## CoreSPADemo（SPA 反馈拥有者）把它未消费的编辑器视口事件转发到这里。
## 鼠标点选锚点由 SPA 拥有（本 demo 作 provider 出数据）；这里只保留 demo 自己的
## 图层切换 / 阈值调节快捷键。ESC 取消选中也由 SPA 处理（会回调 clear_selected_anchor）。
func forward_editor_viewport_input(_viewport_camera: Camera3D, event: InputEvent) -> bool:
	if not event is InputEventKey:
		return false
	var ke := event as InputEventKey
	if not ke.pressed or ke.echo:
		return false
	match ke.keycode:
		KEY_G:
			if ke.shift_pressed:
				_rerun()
			else:
				return false
		KEY_1: _show_layer(LAYER_SUPPORT)
		KEY_2: _show_layer(LAYER_DEMAND)
		KEY_3: _show_layer(LAYER_CANDIDATE)
		KEY_4: _show_layer(LAYER_ANCHOR)
		KEY_5: _show_layer(LAYER_TARGETSV)
		KEY_BRACKETLEFT:
			min_support = clampf(min_support - 0.05, 0.0, 1.0)
			_rerun()
		KEY_BRACKETRIGHT:
			min_support = clampf(min_support + 0.05, 0.0, 1.0)
			_rerun()
		KEY_MINUS:
			min_target_interest = clampf(min_target_interest - 0.05, 0.0, 1.0)
			_rerun()
		KEY_EQUAL:
			min_target_interest = clampf(min_target_interest + 0.05, 0.0, 1.0)
			_rerun()
		KEY_R:
			_rerun()
		_:
			return false
	return true


# ---- SPA volume-score-anchor provider contract ----------------------------
# CoreSPADemo 拥有点选与反馈（marker/label/HUD/红框）；本 demo 只出锚点数据 + 保留自己的
# 图层可视化。SPA 用下列方法射线点选锚点、取记录来画反馈。锚点在世界空间（terrain 高度），
# SPA 的相机射线直接命中它们，坐标一致。

func _register_with_spa_host() -> void:
	if not is_inside_tree():
		return
	_spa_host = _find_spa_host()
	if _spa_host != null and _spa_host.has_method("register_volume_score_provider"):
		_spa_host.call("register_volume_score_provider", self)


func _find_spa_host() -> Node:
	var host := find_child("CoreSPADemo", true, false)
	if host != null and host.has_method("register_volume_score_provider"):
		return host
	return null


func _notify_spa_selected_anchor_changed() -> void:
	if _spa_host != null and is_instance_valid(_spa_host) and _spa_host.has_method("refresh_volume_score_anchor_selection"):
		_spa_host.call("refresh_volume_score_anchor_selection")


func has_volume_score_anchors() -> bool:
	return not _anchor_list.is_empty()


func has_selected_anchor() -> bool:
	return _selected_anchor_id >= 0


func get_anchor_world_positions() -> PackedVector3Array:
	var out := PackedVector3Array()
	for anchor in _anchor_list:
		out.append(_world_center(anchor.get("voxel_pos", Vector3i.ZERO)))
	return out


func get_anchor_marker_radius() -> float:
	return maxf(_voxel_size.x, _voxel_size.z) * 0.5


## [{anchor_index, aabb}]：每个锚点 cell 的世界 AABB（SPA 射线点选目标）。
func get_selectable_anchor_bounds() -> Array:
	var out: Array = []
	var half := _voxel_size * 0.5
	for i in range(_anchor_list.size()):
		var center := _world_center(_anchor_list[i].get("voxel_pos", Vector3i.ZERO))
		out.append({"anchor_index": i, "aabb": AABB(center - half, _voxel_size)})
	return out


## 选中锚点（仅置状态，不自绘）；点选/高亮由 SPA 拥有。anchor_index 是 _anchor_list 下标。
func select_anchor(anchor_index: int) -> Dictionary:
	if anchor_index < 0 or anchor_index >= _anchor_list.size():
		return {"ok": false, "reason": "anchor_index_out_of_range"}
	var anchor := _anchor_list[anchor_index]
	_selected_anchor_id = int(anchor.get("id", anchor_index))
	_selected_anchor_pos = anchor.get("voxel_pos", Vector3i(-1, -1, -1))
	_update_hud()
	_notify_spa_selected_anchor_changed()
	return {"ok": true, "anchor_index": anchor_index}


func clear_selected_anchor() -> Dictionary:
	_selected_anchor_id = -1
	_selected_anchor_pos = Vector3i(-1, -1, -1)
	_update_hud()
	_notify_spa_selected_anchor_changed()
	return {"ok": true}


func get_selected_anchor_record() -> Dictionary:
	if _selected_anchor_id < 0 or _selected_anchor_pos.x < 0:
		return {}
	return {
		"domain": "anchor",
		"geometry": "volume_score_anchor",
		"id": "sv_anchor:%d" % _selected_anchor_id,
		"anchor_index": _selected_anchor_id,
		"voxel_coord": _selected_anchor_pos,
		"world_position": _world_center(_selected_anchor_pos),
		"marker_size": _voxel_size,
		"topk": _selected_anchor_topk_entries(),
		"summary": get_selected_anchor_summary_text(),
		"tooltip": get_selected_anchor_tooltip_text(),
	}


func get_selected_anchor_summary_text() -> String:
	if _selected_anchor_id < 0:
		return "Anchor: click one"
	return "Anchor #%d  pos=%s" % [_selected_anchor_id, str(_selected_anchor_pos)]


func get_selected_anchor_tooltip_text() -> String:
	return "\n".join(_build_topk_hud_lines())


## 本 demo 的锚点 top-k 只读展示、无可循环选择态，滚轮循环不适用。
func cycle_selected_anchor_topk(_delta: int) -> Dictionary:
	return {"ok": false, "reason": "no_topk_cycle"}


## 把 _topk_data 里该锚点的 top-k 整理成 SPA anchor 标签期望的字段形状。
func _selected_anchor_topk_entries() -> Array:
	var out: Array = []
	if _selected_anchor_id < 0:
		return out
	for entry in _topk_data.get(_selected_anchor_id, []):
		if not entry is Dictionary:
			continue
		var d := entry as Dictionary
		out.append({
			"rank": int(d.get("rank", 0)),
			"asset_name": _asset_name_by_id(int(d.get("asset_id", -1))),
			"score": float(d.get("score", -INF)),
			"valid": true,
			"yaw": 0.0,
		})
	return out


func _rerun() -> void:
	_run_collection()
	_show_layer(LAYER_ANCHOR)
