extends SceneTree

const VoxelPlacementGeneratorScript := preload("res://scripts/voxel_placement_generator.gd")
const FLAG_SUPPORT := 1
const FLAG_CLEARANCE := 2


func _init() -> void:
	var grid_size := Vector3i(16, 4, 16)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var scene := PackedFloat32Array()
	var collision := PackedFloat32Array()
	scene.resize(voxel_count)
	collision.resize(voxel_count)

	var generator = VoxelPlacementGeneratorScript.new()
	for z in range(grid_size.z):
		for x in range(grid_size.x):
			scene[generator.voxel_index(Vector3i(x, 0, z), grid_size)] = 1.0

	var footprint: Array[Dictionary] = [
		{
			"local_pos": Vector3i(0, 0, 0),
			"collision_degree": 64,
			"flags": FLAG_SUPPORT,
			"weight": 1.0,
		},
		{
			"local_pos": Vector3i(0, 1, 0),
			"collision_degree": 255,
			"flags": 0,
			"weight": 1.0,
		},
		{
			"local_pos": Vector3i(0, 2, 0),
			"collision_degree": 0,
			"flags": FLAG_CLEARANCE,
			"weight": 1.0,
		},
	]

	var settings := {
		"top_k": 4,
		"result_capacity": 4,
		"min_distance_voxels": 2.0,
		"collision_limit": 0.0,
		"min_support_ratio": 1.0,
		"clearance_limit": 0.0,
	}

	var first := generator.run_minimal(scene, collision, footprint, grid_size, settings)
	if first.is_empty() or int(first.get("result_count", 0)) <= 0:
		push_error("[VoxelPlacementTest] Expected at least one placement")
		quit(1)
		return

	var results: Array = first.get("results", [])
	var first_result: Dictionary = results[0]
	if not bool(first_result.get("valid", false)):
		push_error("[VoxelPlacementTest] First placement should be valid")
		quit(1)
		return
	if float(first_result.get("support_ratio", 0.0)) < 1.0:
		push_error("[VoxelPlacementTest] Expected full support under first placement")
		quit(1)
		return

	var first_origin: Vector3i = first_result.voxel_origin
	var stamped_collision: PackedFloat32Array = first.get("collision_occupancy_out", PackedFloat32Array())
	var collision_idx := generator.voxel_index(first_origin + Vector3i(0, 1, 0), grid_size)
	if stamped_collision[collision_idx] <= 0.01:
		push_error("[VoxelPlacementTest] Stamp pass did not write collision occupancy")
		quit(1)
		return

	var second := generator.run_minimal(
		first.get("scene_occupancy_out", PackedFloat32Array()),
		first.get("collision_occupancy_out", PackedFloat32Array()),
		footprint,
		grid_size,
		settings
	)
	if second.is_empty() or int(second.get("result_count", 0)) <= 0:
		push_error("[VoxelPlacementTest] Expected a second placement after stamp")
		quit(1)
		return

	var second_results: Array = second.get("results", [])
	var second_origin: Vector3i = second_results[0].get("voxel_origin", Vector3i.ZERO)
	if second_origin == first_origin:
		push_error("[VoxelPlacementTest] Second placement should avoid the stamped collision voxel")
		quit(1)
		return

	var compact_scene := PackedFloat32Array()
	var compact_collision := PackedFloat32Array()
	compact_scene.resize(voxel_count)
	compact_collision.resize(voxel_count)
	for z in range(grid_size.z):
		for x in range(grid_size.x):
			compact_scene[generator.voxel_index(Vector3i(x, 0, z), grid_size)] = 1.0

	var blocker_origin := Vector3i(7, 1, 0)
	compact_collision[generator.voxel_index(blocker_origin + Vector3i(0, 1, 0), grid_size)] = 1.0
	var compact_settings := settings.duplicate()
	compact_settings["candidate_voxel_sparses"] = [Vector3i(0, 0, 0)]
	compact_settings["search_radius"] = Vector3i(1, 0, 0)
	compact_settings["sample_min"] = Vector3i(7, 0, 0)
	compact_settings["result_capacity"] = 1
	compact_settings["min_distance_voxels"] = 0.0
	var compact := generator.run_minimal(compact_scene, compact_collision, footprint, grid_size, compact_settings)
	if compact.is_empty() or int(compact.get("candidate_voxel_sparse_count", 0)) != 1:
		push_error("[VoxelPlacementTest] Expected compact candidate voxel-region dispatch")
		quit(1)
		return
	var compact_results: Array = compact.get("results", [])
	if compact_results.is_empty():
		push_error("[VoxelPlacementTest] Expected compact dispatch result")
		quit(1)
		return
	var compact_origin: Vector3i = compact_results[0].get("voxel_origin", Vector3i.ZERO)
	if compact_origin != Vector3i(8, 1, 0):
		push_error("[VoxelPlacementTest] Search radius should find neighbor origin, got %s" % str(compact_origin))
		quit(1)
		return

	print("[VoxelPlacementTest] first=%s second=%s compact=%s stamped=%d deltas=%d tiles=%d compact_tiles=%d" % [
		str(first_origin),
		str(second_origin),
		str(compact_origin),
		(first.get("stamp_deltas", []) as Array).size(),
		(second.get("stamp_deltas", []) as Array).size(),
		int(first.get("tile_count", 0)),
		int(compact.get("candidate_voxel_sparse_count", 0)),
	])
	quit(0)
