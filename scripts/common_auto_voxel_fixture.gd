@tool
extends RefCounted

const AssetDescriptorScript := preload("res://scripts/auto_voxel_descriptor.gd")
const AutoVoxelProfileScript := preload("res://scripts/auto_voxel_profile.gd")
const SemanticProbeProfileScript := preload("res://scripts/semantic_probe_profile.gd")


static func make_runtime_profile_descriptor() -> AssetDescriptor:
	var descriptor: AssetDescriptor = AssetDescriptorScript.new()
	descriptor.set_color_and_complexity(Color(0.2, 0.4, 0.6, 1.0), 0.5)
	descriptor.set_collision([])
	descriptor.set_pivot_variants([{
		"name": "root",
		"offset": Vector3(0.0, -0.25, 0.0),
		"score_bias": 0.1,
	}])
	descriptor.semantic_probe_density = 1.0
	descriptor.context_sensing_radius = 0.5
	descriptor.set_semantic_probes([SemanticProbeProfileScript.make_probe(
		Vector3(0.25, 0.5, -0.25),
		Color(0.2, 0.4, 0.6, 0.5),
		0.3,
		1.0, 1.0, 1.0,
		"manual"
	)])
	return descriptor


static func make_runtime_profile() -> AutoVoxelProfile:
	var profile: AutoVoxelProfile = AutoVoxelProfileScript.new()
	profile.color = Color(0.15, 0.25, 0.35, 1.0)
	profile.complexity = 0.65
	profile.collision = []
	return profile


static func make_spa_test_descriptor(id_name: String) -> AssetDescriptor:
	var descriptor: AssetDescriptor = AssetDescriptorScript.new()
	descriptor.asset_id = id_name
	descriptor.object_type = "vegetation"
	descriptor.color = Color(0.3, 0.7, 0.4, 0.8)
	descriptor.complexity = 0.8
	descriptor.set_collision([{"offset": Vector3.ZERO, "radius": 0.2, "height": 0.5}])
	descriptor.mesh_create_method = "create_sample_autoobject_mesh"
	return descriptor


static func make_mesh_description_descriptor(
	asset_id: String,
	mesh: Mesh,
	source_mesh: Mesh,
	source_mesh_path: String
) -> AssetDescriptor:
	var descriptor: AssetDescriptor = AssetDescriptorScript.new()
	descriptor.asset_id = asset_id
	descriptor.object_type = "vegetation"
	descriptor.mesh = mesh
	descriptor.source_mesh = source_mesh
	descriptor.source_mesh_path = source_mesh_path
	descriptor.set_color_and_complexity(Color(0.2, 0.7, 0.3, 1.0), 0.6)
	descriptor.set_collision([])
	descriptor.set_pivot_variants([{
		"name": "root",
		"offset": Vector3.ZERO,
		"score_bias": 0.0,
	}])
	descriptor.set_semantic_probes([SemanticProbeProfileScript.make_probe(
		Vector3.ZERO,
		Color(0.2, 0.7, 0.3, 0.6),
		0.5,
		1.0, 0.0, 0.0,
		"manual"
	)])
	return descriptor
