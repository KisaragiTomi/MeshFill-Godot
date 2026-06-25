@tool
class_name CommonVolumeScore3D
extends RefCounted

const MeshVoxelizerGpuScript := preload("res://scripts/mesh_voxelizer_gpu.gd")
const ObjectVolumeScoreGpuScript := preload("res://scripts/object_volume_score_gpu.gd")
const TerrainConfigScript := preload("res://scripts/terrain_config.gd")
const TerrainInitializerScript := preload("res://scripts/terrain_initializer.gd")
const CommonDemoAssets := preload("res://scripts/common_demo_assets.gd")
const CommonVoxelSpaceScript := preload("res://scripts/common_voxel_space.gd")


static func voxelize_common_assets(voxel_grid_count: int, fallback_to_box: bool = true) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var assets: Array[Dictionary] = []
	var footprints: Array[Dictionary] = []
	var voxelizer = MeshVoxelizerGpuScript.new()

	for i in range(CommonDemoAssets.count()):
		var asset_path := CommonDemoAssets.geo_path(i)
		var mesh := CommonDemoAssets.load_mesh(asset_path)
		var fallback := false
		if mesh == null:
			if not fallback_to_box:
				continue
			mesh = BoxMesh.new()
			fallback = true
		var aabb := mesh.get_aabb()
		var volume := aabb.size.x * aabb.size.y * aabb.size.z
		var longest := maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
		var color := CommonDemoAssets.asset_color(i)
		var vox_result := voxelizer.voxelize(mesh, voxel_grid_count, color, 0.9, 4)
		var footprint := ObjectVolumeScoreGpuScript.footprint_from_voxelizer_result(
			vox_result, color, longest)
		var ext := ObjectVolumeScoreGpuScript.compute_extent_params(longest)
		var sample_profile := ObjectVolumeScoreGpuScript.ensure_rotation_sample_profile(footprint)
		var asset := {
			"name": CommonDemoAssets.asset_name(i, asset_path.get_file()),
			"path": asset_path,
			"mesh": mesh,
			"volume": volume,
			"aabb": aabb,
			"color": color,
			"voxelized": bool(vox_result.get("ok", false)),
			"voxel_count": vox_result.get("voxels", []).size(),
			"fp_grid": footprint.get("grid", Vector3i.ZERO),
			"world_longest": longest,
			"tier": ext["tier"],
			"sample_extent": sample_profile.get("sample_extent", ext["sample_extent"]),
			"sample_variant_count": sample_profile.get("max_sample_count", 0),
			"sample_group_count": sample_profile.get("sample_group_count", 0),
			"subtile_count": sample_profile.get("sample_group_count", 0),
			"footprint": footprint,
			"fallback": fallback,
		}
		assets.append(asset)
		footprints.append(footprint)

	voxelizer.dispose()
	return {
		"assets": assets,
		"footprints": footprints,
		"elapsed_ms": float(Time.get_ticks_msec() - t0),
	}


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
	var voxel_count := CommonVoxelSpaceScript.voxel_count(grid)
	var voxel_size_y := max_height / float(gy)
	var voxel_size := CommonVoxelSpaceScript.voxel_size_for_resolution(capture_size, gx, voxel_size_y)
	var terrain := terrain_height
	if terrain.size() != gx * gz:
		terrain = procedural_terrain(gx, gz)

	var cx_floats := PackedFloat32Array()
	cx_floats.resize(voxel_count * 4)
	var coll_floats := PackedFloat32Array()
	coll_floats.resize(voxel_count)
	var target_floats := PackedFloat32Array()
	target_floats.resize(voxel_count * 4)

	for z in range(gz):
		for x in range(gx):
			var hi := z * gx + x
			var terrain_y := terrain[hi] if hi < terrain.size() else 0.0
			var ground_slice := clampi(int(terrain_y / voxel_size_y), 0, gy - 1)
			var min_above := int(target_min_height_frac * float(gy))
			var max_above := maxi(int(target_max_height_frac * float(gy)), min_above + 2)

			for y in range(gy):
				var idx := CommonVoxelSpaceScript.voxel_index(Vector3i(x, y, z), grid)
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
				if above_ground >= min_above and above_ground <= max_above:
					var frac := 1.0 - float(above_ground - min_above) / maxf(float(max_above - min_above), 1.0)
					target_floats[idx * 4] = 0.45
					target_floats[idx * 4 + 1] = 0.42
					target_floats[idx * 4 + 2] = 0.35
					target_floats[idx * 4 + 3] = clampf(frac * 0.7 + 0.1, 0.0, 1.0)

	return {
		"grid": grid,
		"voxel_size": voxel_size,
		"grid_origin": CommonVoxelSpaceScript.default_grid_origin(capture_size),
		"complexity_bytes": cx_floats.to_byte_array(),
		"collision_bytes": coll_floats.to_byte_array(),
		"target_bytes": target_floats.to_byte_array(),
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
		var world := CommonVoxelSpaceScript.voxel_float_center_to_world(anchor + Vector3.ONE * 0.5, origin, voxel_size)
		var hi := int(anchor.z) * grid.x + int(anchor.x)
		var terrain_y := terrain_height[hi] if hi >= 0 and hi < terrain_height.size() else world.y
		world.y = terrain_y + voxel_size.y * 0.5
		positions.append(world)
	return positions
