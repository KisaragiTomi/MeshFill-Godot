@tool
extends "res://demos/core_demo_contract_fixture.gd"

# Anchor collection demo: cached TargetSV + terrain height → GPU prefilter.
#
# Uses TargetSVLoader for cached buffers, TerrainInitializer for height field,
# VoxelDisplay.build_field_gpu for TargetSV rendering (same pipeline as
# target-sv-point-cloud-conversion-c demo).

const Prefilter := preload("res://scripts/autoobject_probe_prefilter_gpu.gd")
const ProbeProfile := preload("res://scripts/semantic_probe_profile.gd")
const TargetSVLoaderScript := preload("res://scripts/target_sv_loader.gd")
const TargetSceneVoxelGeneratorScript := preload("res://scripts/target_scene_voxel_generator.gd")
const VoxelFieldDisplayGPU := preload("res://scripts/voxel_field_display_gpu.gd")

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


func _ready() -> void:
	super._ready()
	if is_scene_startup_blocked():
		return
	_setup_visualization()
	_setup_hud()
	_deferred_init.call_deferred()


func _deferred_init() -> void:
	if not Engine.is_editor_hint():
		return
	_build_fields_from_terrain()
	_build_assets()
	if _targetsv_valid:
		_run_collection()
	_show_layer(LAYER_ANCHOR)
	_frame_camera.call_deferred()


func _frame_camera() -> void:
	var cam := get_node_or_null("DemoSetup/FlyCamera") as Camera3D
	if cam == null:
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
	var voxel_count := texture_size * slice_count * texture_size

	_grid = Vector3i(texture_size, slice_count, texture_size)
	_voxel_size = Vector3(
		capture_size / maxf(float(texture_size), 1.0),
		vertical_span / maxf(float(slice_count), 1.0),
		capture_size / maxf(float(texture_size), 1.0)
	)
	_grid_origin = Vector3(-capture_size * 0.5, 0.0, -capture_size * 0.5)

	var visual_raw := TargetSVLoaderScript.visual_bytes()
	var collision_raw := TargetSVLoaderScript.collision_bytes()
	if visual_raw.is_empty():
		push_error("[SVAnchorDemo] TargetSVLoader visual_bytes empty")
		return

	_target_field = _extract_float_field(visual_raw, voxel_count * 4, 4)

	var raw_collision := _extract_float_field(collision_raw, voxel_count, 4)
	_complexity_field = PackedFloat32Array()
	_complexity_field.resize(voxel_count)
	_collision_field = PackedFloat32Array()
	_collision_field.resize(voxel_count)
	for z in range(texture_size):
		for x in range(texture_size):
			var idx := x + texture_size * (z + texture_size * 0)
			_complexity_field[idx] = 1.0
			_collision_field[idx] = raw_collision[idx] if idx < raw_collision.size() else 1.0

	var terrain := TerrainInitializerScript.find_edit_time_terrain(self) as MeshInstance3D
	var max_h := float(meta.get("max_height", 120.0))
	_terrain_height = TerrainInitializerScript.terrain_height_field_from_mesh(
		terrain, texture_size, max_h)

	var decoded := TargetSceneVoxelGeneratorScript.decode_target_read_buffers_gpu(
		visual_raw, collision_raw, texture_size, slice_count)
	if not bool(decoded.get("valid", false)):
		decoded = TargetSceneVoxelGeneratorScript.decode_target_read_buffers(
			visual_raw, collision_raw, texture_size, slice_count)
	var occupancy: PackedFloat32Array = decoded.get("target_completely", PackedFloat32Array())
	var target_color: PackedColorArray = decoded.get("target_color", PackedColorArray())
	var collision_decoded: PackedFloat32Array = decoded.get("target_collision", PackedFloat32Array())
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
		"collision": collision_decoded if collision_decoded.size() == voxel_count else raw_collision,
		"color_rgba": color_rgba,
		"terrain_height": _terrain_height.duplicate(),
	}

	_targetsv_valid = true
	print("[SVAnchorDemo] Cached TargetSV: grid=%s voxels=%d non_empty=%d" % [
		str(_grid), voxel_count, int(meta.get("non_empty_voxel_count", 0))])


static func _extract_float_field(raw: PackedByteArray, float_count: int, bytes_per_float: int) -> PackedFloat32Array:
	var needed := float_count * bytes_per_float
	if raw.size() >= needed:
		return raw.slice(0, needed).to_float32_array()
	var field := PackedFloat32Array()
	field.resize(float_count)
	return field


func _voxel_index(p: Vector3i) -> int:
	return p.x + _grid.x * (p.z + _grid.z * p.y)


func _voxel_count() -> int:
	return _grid.x * _grid.y * _grid.z


func _make_sv() -> Dictionary:
	var tile_grid := Vector3i(
		ceili(float(_grid.x) / float(TILE_SIZE)),
		ceili(float(_grid.y) / float(TILE_SIZE)),
		ceili(float(_grid.z) / float(TILE_SIZE))
	)
	return {
		"type": "SV",
		"grid_size": _grid,
		"voxel_size": _voxel_size,
		"grid_origin": _grid_origin,
		"complexity_field": _complexity_field,
		"collision_field": _collision_field,
		"tile_grid_size": tile_grid,
		"total_tiles": tile_grid.x * tile_grid.y * tile_grid.z,
		"dirty_tiles": {},
	}


func _all_tile_ids(sv: Dictionary) -> Array[int]:
	var ids: Array[int] = []
	for i in range(int(sv.get("total_tiles", 0))):
		ids.append(i)
	return ids


# --- Assets ----------------------------------------------------------------

func _build_assets() -> void:
	var a0 := AutoObject.new()
	a0.name = "rock_small"
	a0.set_semantic_probes([
		ProbeProfile.make_probe(Vector3.ZERO, Color(0.5, 0.45, 0.4), 0.6, 0.0, 0.0, 0.8, "rock_small")
	])
	var a1 := AutoObject.new()
	a1.name = "bush_medium"
	a1.set_semantic_probes([
		ProbeProfile.make_probe(Vector3.ZERO, Color(0.2, 0.6, 0.15), 0.3, 0.0, 0.4, 0.4, "bush_medium"),
		ProbeProfile.make_probe(Vector3(0, 1, 0), Color(0.25, 0.7, 0.2), 0.2, 0.0, 0.2, 0.0, "bush_medium_top")
	])
	var a2 := AutoObject.new()
	a2.name = "tree_tall"
	a2.set_semantic_probes([
		ProbeProfile.make_probe(Vector3.ZERO, Color(0.35, 0.25, 0.15), 0.9, 0.0, 0.0, 1.0, "tree_trunk"),
		ProbeProfile.make_probe(Vector3(0, 2, 0), Color(0.15, 0.5, 0.1), 0.4, 0.0, 0.3, 0.0, "tree_canopy")
	])
	var a3 := AutoObject.new()
	a3.name = "grass_patch"
	a3.set_semantic_probes([
		ProbeProfile.make_probe(Vector3.ZERO, Color(0.3, 0.7, 0.2), 0.1, 0.0, 0.1, 0.0, "grass")
	])
	_assets = [a0, a1, a2, a3]


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

	var sv := _make_sv()
	var prefilter := Prefilter.new()
	prefilter.max_complexity_field = max_complexity_field
	prefilter.max_collision_field = max_collision_field
	prefilter.min_support = min_support
	prefilter.min_target_interest = min_target_interest
	prefilter.min_prefilter_score = 0.0

	var result: Dictionary = prefilter.run_probe_prefilter(
		sv, _assets, _all_tile_ids(sv), null, _target_field, {"debug_readback_topk": true})
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
	prefilter.dispose()
	print("[SVAnchorDemo] Collected %d anchors, topk entries=%d (reason=%s)" % [
		_anchor_count, _topk_data.size(), _last_reason])


# --- Visualization ---------------------------------------------------------

func _setup_visualization() -> void:
	_display_root = Node3D.new()
	_display_root.name = "AnchorDisplay"
	add_child(_display_root)


func _world_center(p: Vector3i) -> Vector3:
	var base := _grid_origin + (Vector3(p) + Vector3.ONE * 0.5) * _voxel_size
	var hi := p.z * _grid.x + p.x
	if hi >= 0 and hi < _terrain_height.size():
		base.y += _terrain_height[hi]
	return base


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
	for pos in _anchor_set.keys():
		centers.append(_world_center(pos))
		if pos == _selected_anchor_pos:
			colors.append(Color(1.0, 1.0, 0.0, 1.0))
		else:
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
	var hud := CanvasLayer.new()
	hud.name = "HUD"
	add_child(hud)
	_hud_label = Label.new()
	_hud_label.name = "Info"
	_hud_label.position = Vector2(24, 24)
	_hud_label.add_theme_font_size_override("font_size", 16)
	hud.add_child(_hud_label)


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


func _asset_name_by_id(asset_id: int) -> String:
	if asset_id >= 0 and asset_id < _assets.size():
		var obj: AutoObject = _assets[asset_id]
		if obj != null:
			return obj.name
	return "?"


func _unhandled_input(event: InputEvent) -> void:
	if not Engine.is_editor_hint():
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_try_pick_anchor(mb.position)
			get_viewport().set_input_as_handled()
			return
	if not event is InputEventKey:
		return
	var ke := event as InputEventKey
	if not ke.pressed or ke.echo:
		return
	match ke.keycode:
		KEY_G:
			if ke.shift_pressed:
				_rerun()
			else:
				return
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
		KEY_ESCAPE:
			_selected_anchor_id = -1
			_selected_anchor_pos = Vector3i(-1, -1, -1)
			_show_layer(_current_layer)
		_:
			return
	get_viewport().set_input_as_handled()


func _try_pick_anchor(screen_pos: Vector2) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var ray_origin := cam.project_ray_origin(screen_pos)
	var ray_dir := cam.project_ray_normal(screen_pos)
	var best_dist := INF
	var best_id := -1
	var best_pos := Vector3i(-1, -1, -1)
	var half := _voxel_size * 0.5
	for i in range(_anchor_list.size()):
		var anchor: Dictionary = _anchor_list[i]
		var vp: Vector3i = anchor.get("voxel_pos", Vector3i(-1, -1, -1))
		var center := _world_center(vp)
		var aabb := AABB(center - half, _voxel_size)
		var hit := _ray_intersects_aabb(ray_origin, ray_dir, aabb)
		if hit >= 0.0 and hit < best_dist:
			best_dist = hit
			best_id = int(anchor.get("id", i))
			best_pos = vp
	if best_id >= 0:
		_selected_anchor_id = best_id
		_selected_anchor_pos = best_pos
		_show_layer(_current_layer)
	else:
		_selected_anchor_id = -1
		_selected_anchor_pos = Vector3i(-1, -1, -1)
		_update_hud()


static func _ray_intersects_aabb(origin: Vector3, dir: Vector3, aabb: AABB) -> float:
	var t_min := -INF
	var t_max := INF
	for axis in range(3):
		if absf(dir[axis]) < 1e-8:
			if origin[axis] < aabb.position[axis] or origin[axis] > aabb.end[axis]:
				return -1.0
		else:
			var inv := 1.0 / dir[axis]
			var t1 := (aabb.position[axis] - origin[axis]) * inv
			var t2 := (aabb.end[axis] - origin[axis]) * inv
			if t1 > t2:
				var tmp := t1; t1 = t2; t2 = tmp
			t_min = maxf(t_min, t1)
			t_max = minf(t_max, t2)
			if t_min > t_max:
				return -1.0
	return t_min if t_min >= 0.0 else -1.0


func _rerun() -> void:
	_run_collection()
	_show_layer(LAYER_ANCHOR)
