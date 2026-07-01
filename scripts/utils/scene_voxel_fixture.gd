@tool
extends RefCounted


const DEFAULT_TILE_SIZE := VoxelGeneral.DEFAULT_TILE_SIZE


static func make_sv(
	grid_size: Vector3i,
	voxel_size: Vector3,
	grid_origin: Vector3,
	complexity_field: PackedFloat32Array,
	collision_field: PackedFloat32Array,
	tile_size: int = DEFAULT_TILE_SIZE,
	dirty_tiles: Dictionary = {}
) -> Dictionary:
	var tile_grid_size := VoxelGeneral.tile_grid_size_for_grid(grid_size, tile_size)
	return {
		"type": "SV",
		"grid_size": grid_size,
		"voxel_size": voxel_size,
		"grid_origin": grid_origin,
		"complexity_field": complexity_field,
		"collision_field": collision_field,
		"tile_grid_size": tile_grid_size,
		"total_tiles": tile_grid_size.x * tile_grid_size.y * tile_grid_size.z,
		"dirty_tiles": dirty_tiles.duplicate(true),
	}


static func make_flat_ground_sv(
	grid_size: Vector3i,
	voxel_size: Vector3,
	tile_size: int = DEFAULT_TILE_SIZE,
	grid_origin: Vector3 = Vector3.ZERO
) -> Dictionary:
	var count := VoxelGeneral.voxel_count(grid_size)
	var complexity_field := PackedFloat32Array()
	var collision_field := PackedFloat32Array()
	complexity_field.resize(count)
	collision_field.resize(count)
	for z in range(maxi(grid_size.z, 0)):
		for x in range(maxi(grid_size.x, 0)):
			var index := VoxelGeneral.voxel_index(Vector3i(x, 0, z), grid_size)
			if index >= 0 and index < complexity_field.size():
				complexity_field[index] = 1.0
	return make_sv(
		grid_size,
		voxel_size,
		grid_origin,
		complexity_field,
		collision_field,
		tile_size
	)
