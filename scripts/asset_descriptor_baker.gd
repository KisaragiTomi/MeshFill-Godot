@tool
class_name AssetDescriptorBaker
extends RefCounted

const AssetDescriptorScript := preload("res://scripts/asset_descriptor.gd")
const AutoVoxelProfileScript := preload("res://scripts/auto_voxel_profile.gd")
const SemanticProbeGeneratorScript := preload("res://scripts/semantic_probe_generator.gd")


## Converts a MeshVoxelizerGPU result into the canonical collision sample shape.
## Grid X/Z are centered and the lowest occupied Y slice becomes placement Y=0.
static func collision_samples_from_voxel_result(voxel_result: Dictionary) -> Array[Dictionary]:
	var samples: Array[Dictionary] = []
	var voxels: Array = voxel_result.get("voxels", [])
	var grid: Vector3i = voxel_result.get("grid", Vector3i.ZERO)
	var min_y := 0x7FFFFFFF
	for raw_voxel in voxels:
		if not raw_voxel is Dictionary:
			continue
		var voxel := raw_voxel as Dictionary
		if float(voxel.get("collision", 0.0)) <= 0.0:
			continue
		var grid_position: Vector3i = voxel.get("voxel", Vector3i.ZERO)
		min_y = mini(min_y, grid_position.y)
	if min_y == 0x7FFFFFFF:
		return samples

	var half_x := grid.x / 2
	var half_z := grid.z / 2
	for raw_voxel in voxels:
		if not raw_voxel is Dictionary:
			continue
		var voxel := raw_voxel as Dictionary
		var strength := float(voxel.get("collision", 0.0))
		if strength <= 0.0:
			continue
		var grid_position: Vector3i = voxel.get("voxel", Vector3i.ZERO)
		var local := Vector3i(grid_position.x - half_x, grid_position.y - min_y, grid_position.z - half_z)
		samples.append(AutoVoxelProfileScript.make_collision_sample(local, strength, 1.0))
	return samples


## Converts occupied voxels to the mesh-local sample shape consumed by semantic probes.
static func interior_samples_from_voxel_result(voxel_result: Dictionary) -> Array[Dictionary]:
	var samples: Array[Dictionary] = []
	for raw_voxel in voxel_result.get("voxels", []):
		if not raw_voxel is Dictionary:
			continue
		var voxel := raw_voxel as Dictionary
		if float(voxel.get("collision", 0.0)) <= 0.0:
			continue
		samples.append({
			"local_pos": voxel.get("local_center", Vector3.ZERO),
			"color": voxel.get("color", Color.WHITE),
			"complexity": float(voxel.get("complexity", 1.0)),
			"collision": float(voxel.get("collision", 0.0)),
		})
	return samples


## Converts occupied mesh voxels into the descriptor-local records consumed by
## fine scoring and stamping. Coordinates use the same bottom-centred convention
## as collision_samples_from_voxel_result().
static func asset_voxels_from_voxel_result(voxel_result: Dictionary) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	var voxels: Array = voxel_result.get("voxels", [])
	var grid: Vector3i = voxel_result.get("grid", Vector3i.ZERO)
	var min_y := 0x7FFFFFFF
	for raw_voxel in voxels:
		if not raw_voxel is Dictionary:
			continue
		var voxel := raw_voxel as Dictionary
		if float(voxel.get("collision", 0.0)) <= 0.0:
			continue
		var grid_position: Vector3i = voxel.get("voxel", Vector3i.ZERO)
		min_y = mini(min_y, grid_position.y)
	if min_y == 0x7FFFFFFF:
		return records

	var half_x := grid.x / 2
	var half_z := grid.z / 2
	for raw_voxel in voxels:
		if not raw_voxel is Dictionary:
			continue
		var voxel := raw_voxel as Dictionary
		var collision_strength := clampf(float(voxel.get("collision", 0.0)), 0.0, 1.0)
		if collision_strength <= 0.0:
			continue
		var grid_position: Vector3i = voxel.get("voxel", Vector3i.ZERO)
		var local_voxel := Vector3i(grid_position.x - half_x, grid_position.y - min_y, grid_position.z - half_z)
		var voxel_color: Color = voxel.get("color", Color.WHITE)
		var voxel_complexity := clampf(float(voxel.get("complexity", voxel_color.a)), 0.0, 1.0)
		voxel_color.a = voxel_complexity
		records.append({
			"voxel": local_voxel,
			"color": voxel_color,
			"complexity": voxel_complexity,
			"collision_strength": collision_strength,
			"weight": maxf(float(voxel.get("weight", 1.0)), 0.0),
			"flags": int(voxel.get("flags", 0)),
		})
	return records


## Builds a complete descriptor from an already-voxelized mesh. The scene/importer owns
## voxelization and persistence; this method owns the descriptor data contract.
static func descriptor_from_voxel_result(
	mesh: Mesh,
	voxel_result: Dictionary,
	config: Dictionary = {}
) -> AssetDescriptor:
	if mesh == null:
		return null

	var color: Color = config.get("color", Color.WHITE)
	var complexity := clampf(float(config.get("complexity", color.a)), 0.0, 1.0)
	var probe_density := clampf(float(config.get("probe_density", 1.0)), 0.1, 8.0)
	var collision_samples := collision_samples_from_voxel_result(voxel_result)
	var interior_samples := interior_samples_from_voxel_result(voxel_result)
	var asset_voxels := asset_voxels_from_voxel_result(voxel_result)

	var descriptor: AssetDescriptor = AssetDescriptorScript.new()
	descriptor.mesh = mesh
	descriptor.set_color_and_complexity(color, complexity)
	descriptor.set_collision(collision_samples)
	descriptor.set_asset_voxels(asset_voxels)
	descriptor.asset_id = str(config.get("asset_id", ""))
	descriptor.object_type = str(config.get("object_type", ""))
	descriptor.source_mesh_path = str(config.get("source_mesh_path", ""))

	var voxel_profile: AutoVoxelProfile = AutoVoxelProfileScript.create_profile(color, complexity)
	voxel_profile.collision = collision_samples.duplicate(true)
	descriptor.voxel_profile = voxel_profile

	var probe_profile := SemanticProbeGeneratorScript.new()
	probe_profile.density = probe_density
	probe_profile.probes = SemanticProbeGeneratorScript.generate_from_mesh(
		mesh,
		interior_samples,
		color,
		complexity,
		probe_density,
		probe_profile.max_probe_count
	)
	descriptor.semantic_probe_generator = probe_profile
	descriptor.semantic_probe_density = probe_density
	return descriptor
