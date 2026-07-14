extends "res://scripts/utils/scene_tree_test.gd"

const AssetDescriptorBaker := preload("res://scripts/asset_descriptor_baker.gd")


func _init() -> void:
	run_suite("AssetDescriptorBaker", [
		Callable(self, "_test_voxel_result_conversion"),
		Callable(self, "_test_descriptor_contract"),
	])


func fail(message: String) -> bool:
	push_error("  FAIL: %s" % message)
	return false


func _voxel_result() -> Dictionary:
	return {
		"ok": true,
		"grid": Vector3i(6, 8, 4),
		"voxels": [
			{
				"voxel": Vector3i(3, 4, 2),
				"local_center": Vector3(0.25, 0.5, -0.25),
				"color": Color(0.2, 0.4, 0.6, 0.7),
				"complexity": 0.7,
				"collision": 0.8,
			},
			{
				"voxel": Vector3i(4, 6, 1),
				"local_center": Vector3(0.75, 1.5, -0.75),
				"color": Color(0.3, 0.5, 0.7, 0.6),
				"complexity": 0.6,
				"collision": 0.4,
			},
			{
				"voxel": Vector3i(0, 0, 0),
				"local_center": Vector3.ZERO,
				"color": Color.BLACK,
				"complexity": 0.0,
				"collision": 0.0,
			},
		],
	}


func _test_voxel_result_conversion() -> bool:
	var collision := AssetDescriptorBaker.collision_samples_from_voxel_result(_voxel_result())
	if collision.size() != 2:
		return fail("expected two occupied collision samples")
	if collision[0].get("voxel", Vector3i.ZERO) != Vector3i(0, 0, 0):
		return fail("first collision sample should define centered/base-local origin")
	if collision[1].get("voxel", Vector3i.ZERO) != Vector3i(1, 2, -1):
		return fail("second collision sample should preserve relative voxel offset")

	var interior := AssetDescriptorBaker.interior_samples_from_voxel_result(_voxel_result())
	if interior.size() != 2:
		return fail("expected two occupied semantic-probe interior samples")
	if interior[0].get("local_pos", Vector3.ZERO) != Vector3(0.25, 0.5, -0.25):
		return fail("interior sample should preserve mesh-local center")
	if not is_equal_approx(float(interior[1].get("collision", 0.0)), 0.4):
		return fail("interior sample should preserve collision channel")
	return true


func _test_descriptor_contract() -> bool:
	var mesh := BoxMesh.new()
	var descriptor = AssetDescriptorBaker.descriptor_from_voxel_result(mesh, _voxel_result(), {
		"color": Color(0.2, 0.4, 0.6, 0.9),
		"complexity": 0.7,
		"asset_id": "baked_test",
		"object_type": "rock",
		"source_mesh_path": "res://geo/test.FBX",
		"probe_density": 1.5,
	})
	if descriptor == null:
		return fail("descriptor should be created for a valid mesh")
	if descriptor.mesh != mesh or descriptor.asset_id != "baked_test" or descriptor.object_type != "rock":
		return fail("descriptor identity fields should come from baker config")
	if descriptor.source_mesh_path != "res://geo/test.FBX":
		return fail("descriptor should preserve source mesh path")
	if descriptor.get_collision().size() != 2 or descriptor.voxel_profile.collision.size() != 2:
		return fail("descriptor and voxel profile should share normalized collision shape")
	if not is_equal_approx(descriptor.get_complexity(), 0.7):
		return fail("descriptor should preserve canonical complexity")
	if descriptor.semantic_probe_generator == null or descriptor.semantic_probe_generator.probes.is_empty():
		return fail("descriptor baker should generate the semantic probe profile")
	if not is_equal_approx(descriptor.semantic_probe_density, 1.5):
		return fail("descriptor should preserve semantic probe density")
	return true
