@tool
extends "res://demos/core_demo_contract_fixture.gd"

## 3D Object Volume Score — Stress Test
##
## Loads all geo meshes, voxelizes them, generates a scene field from terrain,
## distributes anchors across the surface, then scores every asset at every
## anchor with 12 rotation slots via GPU compute.
##
## This is defined as a STRESS TEST: every anchor evaluates ALL objects
## simultaneously so they can be compared head-to-head.

const AutoAssetFactory := preload("res://scripts/auto_asset_factory.gd")
const MeshVoxelizerGpuScript := preload("res://scripts/mesh_voxelizer_gpu.gd")
const ObjectVolumeScoreGpuScript := preload("res://scripts/object_volume_score_gpu.gd")
const TerrainConfigScript := preload("res://scripts/terrain_config.gd")

const GEO_PATHS := [
	"res://geo/SM_TestLeaf_Test2.FBX",
	"res://geo/cliff_01.FBX",
	"res://geo/cliff_02.FBX",
	"res://geo/SM_Cliff_06.FBX",
]

const ASSET_COLORS := [
	Color(0.35, 0.58, 0.24, 0.45),
	Color(0.48, 0.42, 0.35, 0.75),
	Color(0.52, 0.46, 0.38, 0.70),
	Color(0.55, 0.50, 0.44, 0.80),
]

const ASSET_DISPLAY_COLORS := [
	Color(0.2, 0.9, 0.3, 0.85),
	Color(0.9, 0.4, 0.2, 0.85),
	Color(0.2, 0.5, 1.0, 0.85),
	Color(1.0, 0.85, 0.1, 0.85),
]

const ASSET_NAMES := ["Leaf", "Cliff01", "Cliff02", "Cliff06"]

@export_range(16, 128, 1) var grid_resolution: int = 64
@export_range(4, 32, 1) var grid_height_slices: int = 16
@export_range(2, 16, 1) var anchor_spacing: int = 4
@export_range(8, 48, 1) var voxel_grid_count: int = 24
@export_range(0.0, 1.0, 0.05) var target_min_height_frac: float = 0.0
@export_range(0.0, 1.0, 0.05) var target_max_height_frac: float = 0.25
@export var auto_run_on_start := true

var _assets: Array[Dictionary] = []
var _footprints: Array[Dictionary] = []
var _anchors := PackedVector3Array()
var _anchor_world_positions := PackedVector3Array()
var _scene_fields: Dictionary = {}
var _results: Array[Dictionary] = []
var _winner_per_anchor: PackedInt32Array = PackedInt32Array()
var _terrain_height := PackedFloat32Array()

var _hud_label: Label
var _display_root: Node3D
var _voxelized := false
var _scored := false
var _elapsed_voxelize_ms := 0.0
var _elapsed_score_ms := 0.0
var _total_anchors := 0
var _total_dispatches := 0


func _ready() -> void:
	super._ready()
	if is_scene_startup_blocked():
		return
	_setup_hud()
	_display_root = Node3D.new()
	_display_root.name = "StressTestDisplay"
	add_child(_display_root)
	if auto_run_on_start:
		_full_pipeline.call_deferred()


func _full_pipeline() -> void:
	if not Engine.is_editor_hint():
		return
	_load_and_voxelize()
	_build_scene_fields()
	_generate_anchors()
	_run_gpu_scoring()
	_build_visualization()
	_frame_camera()
	_update_hud()


func _unhandled_input(event: InputEvent) -> void:
	if not Engine.is_editor_hint():
		return
	if not event is InputEventKey:
		return
	var ke := event as InputEventKey
	if not ke.pressed or ke.echo:
		return
	match ke.keycode:
		KEY_R:
			_rerun()
		KEY_BRACKETLEFT:
			anchor_spacing = clampi(anchor_spacing + 1, 2, 16)
			_rerun()
		KEY_BRACKETRIGHT:
			anchor_spacing = clampi(anchor_spacing - 1, 2, 16)
			_rerun()
		_:
			return
	get_viewport().set_input_as_handled()


func _rerun() -> void:
	_generate_anchors()
	_run_gpu_scoring()
	_build_visualization()
	_update_hud()


# --- Asset Loading & Voxelization -----------------------------------------

func _load_and_voxelize() -> void:
	var t0 := Time.get_ticks_msec()
	_assets.clear()
	_footprints.clear()
	var voxelizer = MeshVoxelizerGpuScript.new()

	for i in range(GEO_PATHS.size()):
		var mesh := AutoAssetFactory.load_mesh(GEO_PATHS[i])
		if mesh == null:
			push_warning("[VolumeScore] Cannot load %s" % GEO_PATHS[i])
			mesh = BoxMesh.new()
		var aabb := mesh.get_aabb()
		var vol := aabb.size.x * aabb.size.y * aabb.size.z
		var longest := maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
		var color: Color = ASSET_COLORS[i] if i < ASSET_COLORS.size() else Color.WHITE
		var vox_result := voxelizer.voxelize(mesh, voxel_grid_count, color, 0.9, 4)
		var footprint := ObjectVolumeScoreGpuScript.footprint_from_voxelizer_result(
			vox_result, color, longest)
		var ext := ObjectVolumeScoreGpuScript.compute_extent_params(longest)
		_assets.append({
			"name": ASSET_NAMES[i] if i < ASSET_NAMES.size() else GEO_PATHS[i].get_file(),
			"mesh": mesh,
			"volume": vol,
			"aabb": aabb,
			"color": color,
			"voxelized": bool(vox_result.get("ok", false)),
			"voxel_count": vox_result.get("voxels", []).size(),
			"fp_grid": footprint.get("grid", Vector3i.ZERO),
			"world_longest": longest,
			"tier": ext["tier"],
			"sample_extent": ext["sample_extent"],
			"subtile_count": ext["subtile_count"],
		})
		_footprints.append(footprint)
		print("[VolumeScore] Asset %d [%s] aabb=%.2fm tier=%d ext=%d stc=%d voxels=%d fp_grid=%s" % [
			i, _assets[i].name, longest, ext["tier"], ext["sample_extent"],
			ext["subtile_count"], _assets[i].voxel_count, str(_assets[i].fp_grid)])

	_voxelized = true
	_elapsed_voxelize_ms = float(Time.get_ticks_msec() - t0)
	print("[VolumeScore] Voxelized %d assets in %.0f ms" % [
		_assets.size(), _elapsed_voxelize_ms])


# --- Scene Field Construction ---------------------------------------------

func _build_scene_fields() -> void:
	var capture_size := TerrainConfigScript.CAPTURE_SIZE
	var max_height := TerrainConfigScript.MAX_HEIGHT
	var gx := grid_resolution
	var gy := grid_height_slices
	var gz := grid_resolution
	var voxel_count := gx * gy * gz
	var voxel_size_xz := capture_size / float(gx)
	var voxel_size_y := max_height / float(gy)

	_terrain_height = _sample_terrain_height(gx, gz, capture_size)

	var cx_floats := PackedFloat32Array()
	cx_floats.resize(voxel_count * 4)
	var coll_floats := PackedFloat32Array()
	coll_floats.resize(voxel_count)
	var target_floats := PackedFloat32Array()
	target_floats.resize(voxel_count * 4)

	for z in range(gz):
		for x in range(gx):
			var hi := z * gx + x
			var terrain_y := _terrain_height[hi] if hi < _terrain_height.size() else 0.0
			var ground_slice := clampi(int(terrain_y / voxel_size_y), 0, gy - 1)

			for y in range(gy):
				var idx := x + gx * (z + gz * y)
				if y <= ground_slice:
					cx_floats[idx * 4 + 3] = 0.8
					coll_floats[idx] = 0.9
				elif y <= ground_slice + 1:
					cx_floats[idx * 4 + 3] = 0.3
					coll_floats[idx] = 0.1
				else:
					cx_floats[idx * 4 + 3] = 0.0
					coll_floats[idx] = 0.0

				var above_ground := y - ground_slice
				var min_above := int(target_min_height_frac * float(gy))
				var max_above := maxi(int(target_max_height_frac * float(gy)), min_above + 2)
				if above_ground >= min_above and above_ground <= max_above:
					var frac := 1.0 - float(above_ground - min_above) / maxf(float(max_above - min_above), 1.0)
					target_floats[idx * 4] = 0.45
					target_floats[idx * 4 + 1] = 0.42
					target_floats[idx * 4 + 2] = 0.35
					target_floats[idx * 4 + 3] = clampf(frac * 0.7 + 0.1, 0.0, 1.0)

	_scene_fields = {
		"grid": Vector3i(gx, gy, gz),
		"voxel_size": Vector3(voxel_size_xz, voxel_size_y, voxel_size_xz),
		"grid_origin": Vector3(-capture_size * 0.5, 0.0, -capture_size * 0.5),
		"complexity_bytes": cx_floats.to_byte_array(),
		"collision_bytes": coll_floats.to_byte_array(),
		"target_bytes": target_floats.to_byte_array(),
	}
	print("[VolumeScore] Scene field: grid=%s voxels=%d" % [
		str(_scene_fields.grid), voxel_count])


func _sample_terrain_height(gx: int, gz: int, capture_size: float) -> PackedFloat32Array:
	var field := PackedFloat32Array()
	field.resize(gx * gz)
	var terrain := TerrainInitializerScript.find_edit_time_terrain(self) as MeshInstance3D
	if terrain != null and terrain.mesh != null:
		var source := TerrainInitializerScript.terrain_height_field_from_mesh(
			terrain, gx, TerrainConfigScript.MAX_HEIGHT)
		if source.size() == field.size():
			return source
	var max_h := TerrainConfigScript.MAX_HEIGHT * 0.3
	for z in range(gz):
		for x in range(gx):
			var u := float(x) / maxf(float(gx - 1), 1.0) - 0.5
			var v := float(z) / maxf(float(gz - 1), 1.0) - 0.5
			field[z * gx + x] = (sin(u * 6.28) * cos(v * 6.28) * 0.5 + 0.5) * max_h
	return field


# --- Anchor Generation ----------------------------------------------------

func _generate_anchors() -> void:
	_anchors = PackedVector3Array()
	_anchor_world_positions = PackedVector3Array()
	var grid: Vector3i = _scene_fields.get("grid", Vector3i.ZERO)
	var voxel_size: Vector3 = _scene_fields.get("voxel_size", Vector3.ONE)
	var origin: Vector3 = _scene_fields.get("grid_origin", Vector3.ZERO)
	var gx := grid.x
	var gy := grid.y
	var gz := grid.z
	var voxel_size_y := voxel_size.y

	for z in range(0, gz, anchor_spacing):
		for x in range(0, gx, anchor_spacing):
			var hi := z * gx + x
			var terrain_y := _terrain_height[hi] if hi < _terrain_height.size() else 0.0
			var ground_slice := clampi(int(terrain_y / voxel_size_y), 0, gy - 2)
			var anchor_y := ground_slice + 1

			_anchors.append(Vector3(x, anchor_y, z))
			var world := origin + (Vector3(x, anchor_y, z) + Vector3.ONE * 0.5) * voxel_size
			world.y = terrain_y + voxel_size_y * 0.5
			_anchor_world_positions.append(world)

	_total_anchors = _anchors.size()
	print("[VolumeScore] Generated %d anchors (spacing=%d)" % [_total_anchors, anchor_spacing])


# --- GPU Scoring -----------------------------------------------------------

func _run_gpu_scoring() -> void:
	_results.clear()
	_winner_per_anchor = PackedInt32Array()
	_scored = false

	if _anchors.is_empty() or _footprints.is_empty():
		return
	if RenderingServer.get_rendering_device() == null:
		push_warning("[VolumeScore] No RenderingDevice — GPU scoring skipped")
		return

	var t0 := Time.get_ticks_msec()
	var scorer = ObjectVolumeScoreGpuScript.new()
	_results = scorer.score_all_assets(_scene_fields, _footprints, _anchors)
	scorer.dispose()
	_elapsed_score_ms = float(Time.get_ticks_msec() - t0)
	_total_dispatches = _footprints.size() * 2

	_compute_winners()
	_scored = true
	print("[VolumeScore] GPU scoring: %d assets × %d anchors in %.0f ms (%d dispatches)" % [
		_footprints.size(), _total_anchors, _elapsed_score_ms, _total_dispatches])


func _compute_winners() -> void:
	_winner_per_anchor.resize(_total_anchors)
	for a_idx in range(_total_anchors):
		var best_score := -1.0
		var best_asset := -1
		for r_idx in range(_results.size()):
			var r: Dictionary = _results[r_idx]
			if not bool(r.get("ok", false)):
				continue
			var per_anchor: Array = r.get("anchor_results", [])
			if a_idx >= per_anchor.size():
				continue
			var ar: Dictionary = per_anchor[a_idx]
			var score: float = ar.get("score", -1.0)
			if score > best_score:
				best_score = score
				best_asset = int(r.get("asset_index", r_idx))
		_winner_per_anchor[a_idx] = best_asset


# --- Visualization ---------------------------------------------------------

func _build_visualization() -> void:
	for child in _display_root.get_children():
		child.queue_free()

	if _anchor_world_positions.is_empty():
		return

	var voxel_size: Vector3 = _scene_fields.get("voxel_size", Vector3.ONE)
	var centers := PackedVector3Array()
	var colors := PackedColorArray()

	for i in range(_anchor_world_positions.size()):
		centers.append(_anchor_world_positions[i])
		var winner := _winner_per_anchor[i] if i < _winner_per_anchor.size() else -1
		if winner >= 0 and winner < ASSET_DISPLAY_COLORS.size():
			colors.append(ASSET_DISPLAY_COLORS[winner])
		else:
			colors.append(Color(0.5, 0.5, 0.5, 0.4))

	var cell := Vector3(voxel_size.x, voxel_size.y * 0.5, voxel_size.z)
	var node := VoxelDisplay.build_colored(centers, cell, colors, {
		"name": "AnchorWinners", "unshaded": true})
	if node != null:
		_display_root.add_child(node)

	_build_legend()


func _build_legend() -> void:
	var y_offset := 0.0
	for i in range(mini(_assets.size(), ASSET_DISPLAY_COLORS.size())):
		var label := Label3D.new()
		label.name = "Legend_%d" % i
		var win_count := 0
		for w in _winner_per_anchor:
			if w == i:
				win_count += 1
		label.text = "%s: %d wins" % [_assets[i].name, win_count]
		label.position = Vector3(-100.0, 80.0 - y_offset, -100.0)
		label.font_size = 36
		label.pixel_size = 0.04
		label.outline_size = 8
		label.modulate = ASSET_DISPLAY_COLORS[i]
		_display_root.add_child(label)
		y_offset += 12.0


func _frame_camera() -> void:
	var cam := get_node_or_null("DemoSetup/FlyCamera") as Camera3D
	if cam == null:
		return
	var capture_size := TerrainConfigScript.CAPTURE_SIZE
	cam.global_position = Vector3(0.0, capture_size * 0.4, capture_size * 0.45)
	cam.look_at(Vector3.ZERO, Vector3.UP)
	cam.fov = 55.0


# --- HUD -------------------------------------------------------------------

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
	var rd_status := "ready" if RenderingServer.get_rendering_device() != null else "NO GPU"
	var lines: Array[String] = [
		"3D Object Volume Score — STRESS TEST",
		"GPU: %s   grid=%dx%dx%d   voxel_grid_count=%d" % [
			rd_status, grid_resolution, grid_height_slices, grid_resolution, voxel_grid_count],
		"Assets: %d   Anchors: %d (spacing=%d)   Rotations: %d" % [
			_assets.size(), _total_anchors, anchor_spacing,
			ObjectVolumeScoreGpuScript.ROTATION_SLOTS],
		"Voxelize: %.0f ms   Score: %.0f ms   Dispatches: %d" % [
			_elapsed_voxelize_ms, _elapsed_score_ms, _total_dispatches],
		"",
		"R: re-run   [/]: adjust anchor spacing",
		"",
	]

	for i in range(_assets.size()):
		var a: Dictionary = _assets[i]
		var win_count := 0
		var max_score := -1.0
		var avg_score := 0.0
		var valid_count := 0
		if i < _results.size() and bool(_results[i].get("ok", false)):
			var per_anchor: Array = _results[i].get("anchor_results", [])
			for ar in per_anchor:
				if ar is Dictionary:
					var score: float = ar.get("score", -1.0)
					if score > max_score:
						max_score = score
					if bool(ar.get("valid", false)):
						avg_score += score
						valid_count += 1
			if valid_count > 0:
				avg_score /= float(valid_count)
		for w in _winner_per_anchor:
			if w == i:
				win_count += 1
		lines.append("[%d] %s  aabb=%.2fm  T%d(ext=%d,stc=%d)  voxels=%d  wins=%d  avg=%.3f  max=%.3f" % [
			i, a.name, a.get("world_longest", 0.0),
			a.get("tier", -1), a.get("sample_extent", -1), a.get("subtile_count", -1),
			a.voxel_count, win_count, avg_score, max_score])

	if not _scored:
		lines.append("")
		lines.append("(scoring not complete)")

	_hud_label.text = "\n".join(lines)
