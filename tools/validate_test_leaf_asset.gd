extends SceneTree


func _init() -> void:
	var asset := load("res://assets/vegetation/sm_test_leaf_test2_asset.tres") as AutoVoxelDescriptor
	if asset == null:
		push_error("Failed to load sm_test_leaf_test2 AutoVoxelDescriptor")
		quit(ERR_FILE_CANT_OPEN)
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
	print("asset_id=%s subtype=%s channel=%d" % [asset.asset_id, asset.object_subtype, asset.vegetation_channel])
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
	print("scatter_profile=%d collision_voxels=%d semantic_probes=%d" % [
		asset.get_scatter_profile().size(),
		asset.get_collision_voxels().size(),
		probes.size(),
	])
	var instance := asset.instantiate_vegetation({
		"name": "ValidationTestLeaf",
		"scale": Vector3.ONE * asset.scatter_max_scale,
	})
	if instance == null or instance.mesh == null:
		push_error("Failed to instantiate test leaf vegetation")
		quit(ERR_CANT_CREATE)
		return
	print("instance class=%s world_bounds=%s min_spacing=%.2f" % [
		instance.get_class(),
		instance.get_world_bound_size(),
		instance.min_spacing,
	])
	instance.free()
	quit(OK)
