@tool
class_name VolumeScore3D
extends RefCounted

## Terrain-derived scene-field + anchor helpers for the placement-score-3d demo.
## Asset voxelization / volume-scorer footprints were retired together with
## ObjectVolumeScoreGpu when volume scoring merged into VoxelPlacementGenerator.

const TerrainConfigScript := preload("res://scripts/terrain_config.gd")
const TerrainInitializerScript := preload("res://scripts/terrain_initializer.gd")
const BufferUtils := preload("res://scripts/utils/buffer_utils.gd")


static func sample_terrain_height_for_node(owner: Node, gx: int, gz: int) -> PackedFloat32Array:
	var expected_size := maxi(gx, 0) * maxi(gz, 0)
	if owner != null:
		var terrain := TerrainInitializerScript.find_edit_time_terrain(owner) as MeshInstance3D
		if terrain != null and terrain.mesh != null:
			var source := TerrainInitializerScript.terrain_height_field_from_mesh(
				terrain, gx, TerrainConfigScript.MAX_HEIGHT)
			if source.size() == expected_size:
				return source
	return procedural_terrain(gx, gz)


static func procedural_terrain(gx: int, gz: int) -> PackedFloat32Array:
	var field := PackedFloat32Array()
	field.resize(maxi(gx, 0) * maxi(gz, 0))
	var max_h := TerrainConfigScript.MAX_HEIGHT * 0.3
	for z in range(gz):
		for x in range(gx):
			var u := float(x) / maxf(float(gx - 1), 1.0) - 0.5
			var v := float(z) / maxf(float(gz - 1), 1.0) - 0.5
			field[z * gx + x] = (sin(u * 6.28) * cos(v * 6.28) * 0.5 + 0.5) * max_h
	return field


static func build_scene_fields(
	grid_resolution: int,
	grid_height_slices: int,
	terrain_height: PackedFloat32Array,
	target_min_height_frac: float = 0.0,
	target_max_height_frac: float = 0.25
) -> Dictionary:
	var capture_size := TerrainConfigScript.CAPTURE_SIZE
	var max_height := TerrainConfigScript.MAX_HEIGHT
	var gx := maxi(grid_resolution, 1)
	var gy := maxi(grid_height_slices, 2)
	var gz := gx
	var grid := Vector3i(gx, gy, gz)
	var voxel_count := VoxelGeneral.voxel_count(grid)
	var voxel_size_y := max_height / float(gy)
	var voxel_size := VoxelGeneral.voxel_size_for_resolution(capture_size, gx, voxel_size_y)
	var terrain := terrain_height
	if terrain.size() != gx * gz:
		terrain = procedural_terrain(gx, gz)

	# Scene fields are emitted 8-bit per component for the 3D score stage:
	#   complexity -> RGBA8 (rgb = color placeholder, a = complexity),
	#   collision  -> R8,
	#   target     -> RGBA8 (rgb = color, a = coverage).
	# PackedByteArray.resize() zero-fills, so only non-zero components are written.
	var cx_bytes := PackedByteArray()
	cx_bytes.resize(voxel_count * 4)
	var coll_bytes := PackedByteArray()
	coll_bytes.resize(voxel_count)
	var target_bytes := PackedByteArray()
	target_bytes.resize(voxel_count * 4)

	for z in range(gz):
		for x in range(gx):
			var hi := z * gx + x
			var terrain_y := terrain[hi] if hi < terrain.size() else 0.0
			var ground_slice := clampi(int(terrain_y / voxel_size_y), 0, gy - 1)
			var min_above := int(target_min_height_frac * float(gy))
			var max_above := maxi(int(target_max_height_frac * float(gy)), min_above + 2)

			for y in range(gy):
				var idx := VoxelGeneral.voxel_index(Vector3i(x, y, z), grid)
				if y <= ground_slice:
					cx_bytes[idx * 4 + 3] = BufferUtils.quantize_unorm8(0.8)
					coll_bytes[idx] = BufferUtils.quantize_unorm8(0.9)
				elif y <= ground_slice + 1:
					cx_bytes[idx * 4 + 3] = BufferUtils.quantize_unorm8(0.3)
					coll_bytes[idx] = BufferUtils.quantize_unorm8(0.1)

				var above_ground := y - ground_slice
				if above_ground >= min_above and above_ground <= max_above:
					var frac := 1.0 - float(above_ground - min_above) / maxf(float(max_above - min_above), 1.0)
					target_bytes[idx * 4] = BufferUtils.quantize_unorm8(0.45)
					target_bytes[idx * 4 + 1] = BufferUtils.quantize_unorm8(0.42)
					target_bytes[idx * 4 + 2] = BufferUtils.quantize_unorm8(0.35)
					target_bytes[idx * 4 + 3] = BufferUtils.quantize_unorm8(clampf(frac * 0.7 + 0.1, 0.0, 1.0))

	return {
		"grid": grid,
		"voxel_size": voxel_size,
		"grid_origin": VoxelGeneral.default_grid_origin(capture_size),
		"complexity_bytes": cx_bytes,
		"collision_bytes": coll_bytes,
		"target_bytes": target_bytes,
		"terrain_height": terrain,
	}


static func generate_anchors(
	scene_fields: Dictionary,
	terrain_height: PackedFloat32Array,
	spacing: int
) -> PackedVector3Array:
	var anchors := PackedVector3Array()
	var grid: Vector3i = scene_fields.get("grid", Vector3i.ZERO)
	var voxel_size: Vector3 = scene_fields.get("voxel_size", Vector3.ONE)
	var step := maxi(spacing, 1)
	if grid.x <= 0 or grid.y <= 1 or grid.z <= 0:
		return anchors
	for z in range(0, grid.z, step):
		for x in range(0, grid.x, step):
			var hi := z * grid.x + x
			var terrain_y := terrain_height[hi] if hi < terrain_height.size() else 0.0
			var ground_slice := clampi(int(terrain_y / voxel_size.y), 0, grid.y - 2)
			anchors.append(Vector3(x, ground_slice + 1, z))
	return anchors


static func anchor_world_positions(
	scene_fields: Dictionary,
	terrain_height: PackedFloat32Array,
	anchors: PackedVector3Array
) -> PackedVector3Array:
	var positions := PackedVector3Array()
	var grid: Vector3i = scene_fields.get("grid", Vector3i.ZERO)
	var voxel_size: Vector3 = scene_fields.get("voxel_size", Vector3.ONE)
	var origin: Vector3 = scene_fields.get("grid_origin", Vector3.ZERO)
	for anchor in anchors:
		var world := VoxelGeneral.voxel_float_center_to_world(anchor + Vector3.ONE * 0.5, origin, voxel_size)
		var hi := int(anchor.z) * grid.x + int(anchor.x)
		var terrain_y := terrain_height[hi] if hi >= 0 and hi < terrain_height.size() else world.y
		# 锚点落在地形表面。胜出 mesh 按其原生 FBX 轴心对齐到这个世界 Y
		# （volume_score_demo._winner_placement），锚点小球也画在这里。此前加了
		# voxel_size.y * 0.5（锚点体素中心），会把整个放置基准抬高半个体素。
		world.y = terrain_y
		positions.append(world)
	return positions
