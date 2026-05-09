class_name GlobalVoxelField
extends RefCounted
## Standalone 3D voxel field for GPU-based object placement.
##
## Manages scene_occupancy and collision_occupancy as flat PackedFloat32Array
## with 8×8×8 tile-based dirty tracking. Bridges between world-space data
## (heightmap, existing objects) and VoxelPlacementGenerator's GPU pipeline.

const TILE_SIZE := 8
const VPG := preload("res://scripts/voxel_placement_generator.gd")
const AutoObjectProbePrefilterScript := preload("res://scripts/autoobject_probe_prefilter.gd")

var grid_size: Vector3i
var voxel_size: Vector3
var grid_origin: Vector3

var scene_occupancy: PackedFloat32Array
var collision_occupancy: PackedFloat32Array

var _tile_grid_size: Vector3i
var _dirty_tiles: Dictionary = {}


func _init(
	p_grid_size: Vector3i,
	p_voxel_size: Vector3,
	p_grid_origin: Vector3 = Vector3.ZERO
) -> void:
	grid_size = p_grid_size
	voxel_size = p_voxel_size
	grid_origin = p_grid_origin
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	scene_occupancy = PackedFloat32Array()
	scene_occupancy.resize(voxel_count)
	collision_occupancy = PackedFloat32Array()
	collision_occupancy.resize(voxel_count)
	_tile_grid_size = Vector3i(
		ceili(float(grid_size.x) / float(TILE_SIZE)),
		ceili(float(grid_size.y) / float(TILE_SIZE)),
		ceili(float(grid_size.z) / float(TILE_SIZE)),
	)


# ---------------------------------------------------------------------------
# Index helpers
# ---------------------------------------------------------------------------

func voxel_index(p: Vector3i) -> int:
	return p.x + grid_size.x * (p.z + grid_size.z * p.y)


func is_in_bounds(p: Vector3i) -> bool:
	return (p.x >= 0 and p.x < grid_size.x
		and p.y >= 0 and p.y < grid_size.y
		and p.z >= 0 and p.z < grid_size.z)


func world_to_voxel(world_pos: Vector3) -> Vector3i:
	var local := world_pos - grid_origin
	return Vector3i(
		floori(local.x / voxel_size.x),
		floori(local.y / voxel_size.y),
		floori(local.z / voxel_size.z),
	)


func voxel_to_world(voxel_pos: Vector3i) -> Vector3:
	return grid_origin + Vector3(
		float(voxel_pos.x) * voxel_size.x,
		float(voxel_pos.y) * voxel_size.y,
		float(voxel_pos.z) * voxel_size.z,
	)


# ---------------------------------------------------------------------------
# Read / write single voxels
# ---------------------------------------------------------------------------

func set_scene(p: Vector3i, value: float) -> void:
	if is_in_bounds(p):
		scene_occupancy[voxel_index(p)] = value
		_mark_dirty(p)


func set_collision(p: Vector3i, value: float) -> void:
	if is_in_bounds(p):
		collision_occupancy[voxel_index(p)] = value
		_mark_dirty(p)


func get_scene(p: Vector3i) -> float:
	if is_in_bounds(p):
		return scene_occupancy[voxel_index(p)]
	return 0.0


func get_collision(p: Vector3i) -> float:
	if is_in_bounds(p):
		return collision_occupancy[voxel_index(p)]
	return 0.0


# ---------------------------------------------------------------------------
# Bulk populate — ground plane
# ---------------------------------------------------------------------------

func fill_ground_plane(y_level: int = 0, value: float = 1.0) -> void:
	y_level = clampi(y_level, 0, grid_size.y - 1)
	for z in range(grid_size.z):
		for x in range(grid_size.x):
			set_scene(Vector3i(x, y_level, z), value)


func fill_ground_from_depth_image(
	depth_image: Image,
	max_height: float,
	capture_size: float
) -> void:
	var img_res := depth_image.get_width()
	var half := capture_size / 2.0
	for z in range(grid_size.z):
		for x in range(grid_size.x):
			var world_x := grid_origin.x + float(x) * voxel_size.x
			var world_z := grid_origin.z + float(z) * voxel_size.z
			var px := clampi(int((world_x + half) / capture_size * float(img_res)), 0, img_res - 1)
			var pz := clampi(int((world_z + half) / capture_size * float(img_res)), 0, img_res - 1)
			var terrain_h := max_height - depth_image.get_pixelv(Vector2i(px, pz)).r
			var surface_y := clampi(floori(terrain_h / voxel_size.y), 0, grid_size.y - 1)
			set_scene(Vector3i(x, surface_y, z), 1.0)


# ---------------------------------------------------------------------------
# Bulk populate — import collision from existing AutoObject nodes
# ---------------------------------------------------------------------------

func import_collision_from_objects(objects: Array) -> int:
	var count := 0
	for obj in objects:
		if not obj is Node3D:
			continue
		var node := obj as Node3D
		var world_pos := node.global_position
		var base_voxel := world_to_voxel(world_pos)
		if not is_in_bounds(base_voxel):
			continue

		var cv: Array = []
		if node.has_method("get_collision_voxels"):
			cv = node.call("get_collision_voxels")
		elif node is AutoObject:
			cv = (node as AutoObject).collision_voxels

		if cv.is_empty():
			set_collision(base_voxel, 1.0)
			count += 1
			continue

		var footprint := VPG.bake_footprint_from_collision_voxels(cv, voxel_size, false, 0)
		for entry in footprint:
			var local_pos: Vector3i = entry.local_pos
			var degree := int(entry.collision_degree)
			if degree < 1:
				continue
			var stamp_pos := base_voxel + local_pos
			if is_in_bounds(stamp_pos):
				set_collision(stamp_pos, maxf(get_collision(stamp_pos), float(degree) / 255.0))
				count += 1
	return count


# ---------------------------------------------------------------------------
# Import VegetationExclusion volume slices into this 3D field
# ---------------------------------------------------------------------------

func import_from_vegetation_volume(volume: Dictionary, capture_size: float) -> void:
	if volume.is_empty():
		return
	var xz_res: int = volume.get("xz_res", 128)
	var slices: Array = volume.get("slices", [])
	var meta: Array = volume.get("slice_meta", [])
	var half := capture_size / 2.0

	for si in range(slices.size()):
		var img: Image = slices[si]
		var m: Dictionary = meta[si]
		var y_mid := (float(m.y_min) + float(m.y_max)) * 0.5
		var voxel_y := clampi(floori(y_mid / voxel_size.y), 0, grid_size.y - 1)

		for pz in range(xz_res):
			for px_coord in range(xz_res):
				var val := img.get_pixelv(Vector2i(px_coord, pz)).r
				if val < 0.01:
					continue
				var world_x := float(px_coord) / float(xz_res) * capture_size - half
				var world_z := float(pz) / float(xz_res) * capture_size - half
				var vx := clampi(floori((world_x - grid_origin.x) / voxel_size.x), 0, grid_size.x - 1)
				var vz := clampi(floori((world_z - grid_origin.z) / voxel_size.z), 0, grid_size.z - 1)
				var p := Vector3i(vx, voxel_y, vz)
				set_scene(p, maxf(get_scene(p), val))

	var collision_img: Image = volume.get("collision_occupancy", null)
	if collision_img != null:
		for pz in range(xz_res):
			for px_coord in range(xz_res):
				var val := collision_img.get_pixelv(Vector2i(px_coord, pz)).r
				if val < 0.01:
					continue
				var world_x := float(px_coord) / float(xz_res) * capture_size - half
				var world_z := float(pz) / float(xz_res) * capture_size - half
				var vx := clampi(floori((world_x - grid_origin.x) / voxel_size.x), 0, grid_size.x - 1)
				var vz := clampi(floori((world_z - grid_origin.z) / voxel_size.z), 0, grid_size.z - 1)
				for y in range(grid_size.y):
					var p := Vector3i(vx, y, vz)
					set_collision(p, maxf(get_collision(p), val))


# ---------------------------------------------------------------------------
# GPU pipeline integration
# ---------------------------------------------------------------------------

func apply_gpu_output(gpu_output: Dictionary) -> void:
	var scene_out: PackedFloat32Array = gpu_output.get("scene_occupancy_out", PackedFloat32Array())
	var collision_out: PackedFloat32Array = gpu_output.get("collision_occupancy_out", PackedFloat32Array())
	if scene_out.size() == scene_occupancy.size():
		scene_occupancy = scene_out
	if collision_out.size() == collision_occupancy.size():
		collision_occupancy = collision_out
	_mark_all_dirty()


func apply_multi_asset_output(multi_output: Dictionary) -> void:
	var scene_out: PackedFloat32Array = multi_output.get("scene_occupancy_out", PackedFloat32Array())
	var collision_out: PackedFloat32Array = multi_output.get("collision_occupancy_out", PackedFloat32Array())
	if scene_out.size() == scene_occupancy.size():
		scene_occupancy = scene_out
	if collision_out.size() == collision_occupancy.size():
		collision_occupancy = collision_out
	_mark_all_dirty()


func run_placement(
	generator: RefCounted,
	asset_defs: Array,
	common_settings: Dictionary = {}
) -> Dictionary:
	return generator.run_multi_asset(
		scene_occupancy, collision_occupancy,
		asset_defs, grid_size, voxel_size, grid_origin,
		common_settings)


func run_placement_dirty(
	generator: RefCounted,
	asset_defs: Array,
	common_settings: Dictionary = {},
	apply_deltas: bool = true,
	clear_processed: bool = true
) -> Dictionary:
	var dirty_ids := get_dirty_tile_ids()
	if dirty_ids.is_empty():
		return {"asset_results": [], "total_placed": 0, "dirty_tile_count": 0}

	var dirty_positions := get_dirty_tile_positions()
	var settings := common_settings.duplicate(true)
	settings["candidate_tiles"] = dirty_positions

	var result: Dictionary = generator.run_multi_asset(
		scene_occupancy, collision_occupancy,
		asset_defs, grid_size, voxel_size, grid_origin,
		settings)

	if result.is_empty():
		return result

	if apply_deltas:
		var delta_count := 0
		var asset_results: Array = result.get("asset_results", [])
		for ar in asset_results:
			var deltas: Array = ar.get("stamp_deltas", [])
			if not deltas.is_empty():
				delta_count += apply_stamp_deltas(deltas)
		result["applied_delta_count"] = delta_count

	if clear_processed:
		clear_dirty_tiles(dirty_ids)

	result["dirty_tile_count"] = dirty_ids.size()
	return result


func run_prefiltered_placement_dirty(
	generator: RefCounted,
	asset_defs: Array,
	autoobjects: Array,
	target_occupancy: PackedFloat32Array,
	target_color: PackedColorArray,
	common_settings: Dictionary = {},
	apply_deltas: bool = true,
	clear_processed: bool = true
) -> Dictionary:
	var dirty_ids := get_dirty_tile_ids()
	if dirty_ids.is_empty():
		return {"asset_results": [], "total_placed": 0, "dirty_tile_count": 0, "prefilter": {}}

	var prefilter = AutoObjectProbePrefilterScript.new()
	var prefilter_result: Dictionary = prefilter.run_probe_prefilter(
		self,
		target_occupancy,
		target_color,
		autoobjects,
		dirty_ids
	)

	var settings := common_settings.duplicate(true)
	settings["candidate_tiles_by_asset"] = prefilter_result.get("autoobject_candidate_tiles", {})
	settings["target_occupancy"] = target_occupancy
	settings["target_color"] = target_color

	var result: Dictionary = generator.run_multi_asset(
		scene_occupancy, collision_occupancy,
		asset_defs, grid_size, voxel_size, grid_origin,
		settings)

	if result.is_empty():
		result["prefilter"] = prefilter_result
		return result

	if apply_deltas:
		var delta_count := 0
		var asset_results: Array = result.get("asset_results", [])
		for ar in asset_results:
			var deltas: Array = ar.get("stamp_deltas", [])
			if not deltas.is_empty():
				delta_count += apply_stamp_deltas(deltas)
		result["applied_delta_count"] = delta_count

	if clear_processed:
		clear_dirty_tiles(dirty_ids)

	result["dirty_tile_count"] = dirty_ids.size()
	result["prefilter"] = prefilter_result
	return result


# ---------------------------------------------------------------------------
# Dirty tile tracking
# ---------------------------------------------------------------------------

func get_dirty_tile_ids() -> Array[int]:
	var ids: Array[int] = []
	for key in _dirty_tiles:
		ids.append(int(key))
	return ids


func get_dirty_tile_positions() -> Array[Vector3i]:
	var positions: Array[Vector3i] = []
	for key in _dirty_tiles:
		positions.append(tile_id_to_pos(int(key)))
	return positions


func get_dirty_tile_count() -> int:
	return _dirty_tiles.size()


func clear_dirty() -> void:
	_dirty_tiles.clear()


func clear_dirty_tiles(tile_ids: Array[int]) -> void:
	for tid in tile_ids:
		_dirty_tiles.erase(tid)


func tile_id_to_pos(tile_id: int) -> Vector3i:
	var tx := tile_id % _tile_grid_size.x
	var tz := (tile_id / _tile_grid_size.x) % _tile_grid_size.z
	var ty := tile_id / (_tile_grid_size.x * _tile_grid_size.z)
	return Vector3i(tx, ty, tz)


func tile_pos_to_id(tile_pos: Vector3i) -> int:
	return tile_pos.x + _tile_grid_size.x * (tile_pos.z + _tile_grid_size.z * tile_pos.y)


func get_tile_voxel_bounds(tile_pos: Vector3i) -> Dictionary:
	var vmin := Vector3i(
		tile_pos.x * TILE_SIZE,
		tile_pos.y * TILE_SIZE,
		tile_pos.z * TILE_SIZE,
	)
	var vmax := Vector3i(
		mini(vmin.x + TILE_SIZE, grid_size.x),
		mini(vmin.y + TILE_SIZE, grid_size.y),
		mini(vmin.z + TILE_SIZE, grid_size.z),
	)
	return {"vmin": vmin, "vmax": vmax}


func _tile_id(p: Vector3i) -> int:
	var tx := clampi(p.x / TILE_SIZE, 0, _tile_grid_size.x - 1)
	var ty := clampi(p.y / TILE_SIZE, 0, _tile_grid_size.y - 1)
	var tz := clampi(p.z / TILE_SIZE, 0, _tile_grid_size.z - 1)
	return tx + _tile_grid_size.x * (tz + _tile_grid_size.z * ty)


func _mark_dirty(p: Vector3i) -> void:
	_dirty_tiles[_tile_id(p)] = true


func _mark_all_dirty() -> void:
	var total := _tile_grid_size.x * _tile_grid_size.y * _tile_grid_size.z
	for i in range(total):
		_dirty_tiles[i] = true


# ---------------------------------------------------------------------------
# Stamp delta application — selective voxel update from GPU output
# ---------------------------------------------------------------------------

func apply_stamp_deltas(deltas: Array) -> int:
	var count := 0
	for delta in deltas:
		if not delta is Dictionary:
			continue
		var voxel: Vector3i = delta.get("voxel", Vector3i(-1, -1, -1))
		if not is_in_bounds(voxel):
			continue
		var idx := voxel_index(voxel)
		var scene_val := float(delta.get("scene_value", 0.0))
		var collision_val := float(delta.get("collision_value", 0.0))
		if scene_val > 0.0:
			scene_occupancy[idx] = maxf(scene_occupancy[idx], scene_val)
		if collision_val > 0.0:
			collision_occupancy[idx] = maxf(collision_occupancy[idx], collision_val)
		_mark_dirty(voxel)
		count += 1
	return count


# ---------------------------------------------------------------------------
# Stats
# ---------------------------------------------------------------------------

func get_stats() -> Dictionary:
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var scene_occupied := 0
	var collision_occupied := 0
	for i in range(voxel_count):
		if scene_occupancy[i] > 0.01:
			scene_occupied += 1
		if collision_occupancy[i] > 0.01:
			collision_occupied += 1
	var total_tiles := _tile_grid_size.x * _tile_grid_size.y * _tile_grid_size.z
	return {
		"grid_size": grid_size,
		"voxel_size": voxel_size,
		"grid_origin": grid_origin,
		"voxel_count": voxel_count,
		"scene_occupied": scene_occupied,
		"collision_occupied": collision_occupied,
		"scene_pct": "%.1f%%" % [float(scene_occupied) / float(maxi(voxel_count, 1)) * 100.0],
		"collision_pct": "%.1f%%" % [float(collision_occupied) / float(maxi(voxel_count, 1)) * 100.0],
		"tile_grid_size": _tile_grid_size,
		"total_tiles": total_tiles,
		"dirty_tiles": _dirty_tiles.size(),
	}
