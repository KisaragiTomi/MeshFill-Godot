@tool
class_name VolumeScore3D
extends RefCounted

## Terrain-height + surface-anchor helpers for the placement-score-3d demo.

const TerrainConfigScript := preload("res://scripts/terrain_config.gd")
const TerrainInitializerScript := preload("res://scripts/terrain_initializer.gd")


static func sample_terrain_height_for_node(owner: Node, gx: int, gz: int) -> PackedFloat32Array:
	var expected_size := maxi(gx, 0) * maxi(gz, 0)
	if owner != null:
		var terrain := TerrainInitializerScript.find_edit_time_terrain(owner) as MeshInstance3D
		if terrain != null and terrain.mesh != null:
			var source := TerrainInitializerScript.terrain_height_field_from_mesh(
				terrain, gx, TerrainConfigScript.MAX_HEIGHT)
			if source.size() == expected_size:
				return source
	# 无真实 Terrain mesh 时的退化兜底:平坦零高度场(不再合成地形)。
	var flat := PackedFloat32Array()
	flat.resize(expected_size)
	return flat


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
