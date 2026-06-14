extends SceneTree

const EXPECTED_ASSET_ID := "sm_test_leaf_test2"
const EXPECTED_SUBTYPE := "test_leaf"
const EXPECTED_GROUP := "placed_test_leaves"
const EXPECTED_MESH_PATH := "res://geo/SM_TestLeaf_Test2.FBX"


func _init() -> void:
	var asset := load("res://assets/vegetation/sm_test_leaf_test2_asset.tres") as AssetDescriptor
	if asset == null:
		push_error("Failed to load sm_test_leaf_test2 AssetDescriptor")
		quit(ERR_FILE_CANT_OPEN)
		return
	if not _validate_asset(asset):
		quit(ERR_FILE_CORRUPT)
		return

	var mesh := asset.get_mesh()
	var source_mesh := asset.get_source_mesh()
	if mesh == null:
		push_error("sm_test_leaf_test2 asset has no mesh")
		quit(ERR_FILE_CORRUPT)
		return
	if source_mesh == null:
		push_error("sm_test_leaf_test2 asset has no source mesh")
		quit(ERR_FILE_CORRUPT)
		return

	var probes := asset.get_semantic_probes()
	var aabb := mesh.get_aabb()
	var source_aabb := source_mesh.get_aabb()
	print("asset_id=%s subtype=%s" % [asset.asset_id, asset.object_subtype])
	print("mesh_surfaces=%d aabb_pos=%s aabb_size=%s" % [mesh.get_surface_count(), aabb.position, aabb.size])
	print("source_mesh_surfaces=%d source_aabb_pos=%s source_aabb_size=%s explicit_source=%s" % [
		source_mesh.get_surface_count(),
		source_aabb.position,
		source_aabb.size,
		source_mesh != mesh,
	])
	print("scatter min=%.2f max_count=%d max_scale=%.2f group=%s" % [
		asset.scatter_min_distance,
		asset.scatter_max_count,
		asset.scatter_max_scale,
		asset.group,
	])
	print("scatter_profile=%d collision=%d semantic_probes=%d" % [
		asset.get_scatter_profile().size(),
		asset.get_collision().size(),
		probes.size(),
	])
	if asset.get_collision().size() != 0 or asset.get_collision().size() != 0:
		push_error("Test leaf descriptor must keep flexible leaf collision empty")
		quit(ERR_FILE_CORRUPT)
		return
	var instance_config := asset.make_instance_config()
	if not _validate_instance_config(instance_config, asset):
		quit(ERR_FILE_CORRUPT)
		return
	var instance := asset.instantiate_vegetation({
		"name": "ValidationTestLeaf",
		"scale": Vector3.ONE * asset.scatter_max_scale,
	})
	if instance == null or instance.mesh == null:
		push_error("Failed to instantiate test leaf vegetation")
		quit(ERR_CANT_CREATE)
		return
	if not _validate_instance(instance, asset):
		instance.free()
		quit(ERR_CANT_CREATE)
		return
	print("instance class=%s world_bounds=%s min_spacing=%.2f" % [
		instance.get_class(),
		instance.get_world_bound_size(),
		instance.min_spacing,
	])
	instance.free()
	quit(OK)


func _validate_asset(asset: AssetDescriptor) -> bool:
	if asset.asset_id != EXPECTED_ASSET_ID:
		push_error("Unexpected asset_id: %s" % asset.asset_id)
		return false
	if asset.object_type != "vegetation":
		push_error("Expected object_type=vegetation, got %s" % asset.object_type)
		return false
	if asset.object_subtype != EXPECTED_SUBTYPE:
		push_error("Unexpected subtype: %s" % asset.object_subtype)
		return false
	if asset.group != EXPECTED_GROUP:
		push_error("Unexpected group: %s" % asset.group)
		return false
	if asset.source_mesh_path != EXPECTED_MESH_PATH:
		push_error("Unexpected source_mesh_path: %s" % asset.source_mesh_path)
		return false
	if asset.resource_path.get_base_dir() != "res://assets/vegetation":
		push_error("Vegetation descriptor should live under res://assets/vegetation")
		return false
	return true


func _validate_instance_config(config: Dictionary, asset: AssetDescriptor) -> bool:
	if config.get("voxel_descriptor", null) != asset:
		push_error("make_instance_config must include the descriptor as voxel_descriptor")
		return false
	if str(config.get("object_type", "")) != "vegetation":
		push_error("make_instance_config must preserve vegetation object_type")
		return false
	if not config.has("collision"):
		push_error("make_instance_config must include only canonical collision")
		return false
	if not (config.collision is Array):
		push_error("Collision must be an array")
		return false
	if not (config.collision as Array).is_empty():
		push_error("Test leaf collision must stay empty")
		return false
	if not config.has("semantic_probes"):
		push_error("make_instance_config must include descriptor-backed semantic_probes")
		return false
	return true


func _validate_instance(instance: AutoObject, asset: AssetDescriptor) -> bool:
	if not instance is AutoObject:
		push_error("Expected AutoObject instance")
		return false
	if instance.get_record_object_subtype() != EXPECTED_SUBTYPE:
		push_error("Unexpected instance subtype: %s" % instance.get_record_object_subtype())
		return false
	if instance.voxel_descriptor != asset:
		push_error("Instance should keep descriptor as voxel_descriptor")
		return false
	if instance.get_collision().size() != 0 or instance.get_collision().size() != 0:
		push_error("Instance collision must stay descriptor-backed and empty")
		return false
	for key in ["voxel_color", "voxel_complexity", "auto_collision", "semantic_probe_profile", "semantic_probe_count", "semantic_probe_density", "pivot_variant_count", "allowed_anchor_kinds"]:
		if instance.has_meta(key):
			push_error("Instance metadata must not mirror asset semantic field: %s" % key)
			return false
	if instance.has_meta(AutoObject.VOXEL_WRITE_SPEC_META_KEY):
		push_error("Fresh descriptor instantiation should not create voxel_write_spec metadata")
		return false
	return true
