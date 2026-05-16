extends SceneTree

const VPG := preload("res://scripts/voxel_placement_generator.gd")


func _init() -> void:
	var mesh := VegetationScatter.create_bush_mesh()
	var veg := VegetationExclusion.new(32, 32.0, false)
	veg.add_band("ground", 0.0, 0.3, 32, Color(0.2, 0.8, 0.2, 1.0))
	veg.add_band("understory", 0.3, 2.0, 32, Color(0.8, 0.6, 0.2, 0.8))

	var world_result := {
		"position": Vector3(0.0, 0.5, 0.0),
		"rotation_degrees": Vector3(0.0, 30.0, 0.0),
		"scale": Vector3.ONE,
		"asset_index": 2,
		"rotation_index": 2,
		"voxel_origin": Vector3i(8, 1, 8),
		"score": 7.5,
	}

	var node := VPG.instantiate_placement(world_result, "bush", mesh, {
		"name": "VoxelBushRecord_0",
		"record_id": "voxel_bush_record_0",
		"create_asset_voxel_record": true,
		"vegetation_exclusion": veg,
		"capture_size": 32.0,
		"volume_xz_resolution": 32,
	})

	if node == null:
		push_error("Expected instantiated node")
		quit(1)
		return
	if not node.has_meta("asset_voxel_record"):
		push_error("Expected node asset_voxel_record metadata")
		node.free()
		quit(1)
		return

	var record: Dictionary = node.get_meta("asset_voxel_record")
	if str(record.get("id", "")) != "voxel_bush_record_0":
		push_error("Expected voxel_bush_record_0 record id, got %s" % str(record.get("id", "")))
		node.free()
		quit(1)
		return
	if str(record.get("producer_stage", "")) != "voxel_placement":
		push_error("Expected producer_stage=voxel_placement")
		node.free()
		quit(1)
		return
	if record.get("base_pixel", Vector2i(-1, -1)) != Vector2i(16, 16):
		push_error("Expected base_pixel=(16,16), got %s" % str(record.get("base_pixel", Vector2i(-1, -1))))
		node.free()
		quit(1)
		return

	var legacy_config := {
		"name": "LegacyVoxelBushRecord_0",
	}
	legacy_config[AutoObject.legacy_asset_voxel_record_key()] = {
		"id": "legacy_bush_record_0",
		"type": "bush",
		"color": Color(0.8, 0.6, 0.2, 0.8),
		"complexity": 0.8,
	}
	var legacy_node := VPG.instantiate_placement(world_result, "bush", mesh, legacy_config)
	if legacy_node == null or not legacy_node.has_meta(AutoObject.ASSET_VOXEL_RECORD_META_KEY):
		push_error("Expected legacy record config to migrate to asset_voxel_record metadata")
		node.free()
		if legacy_node != null:
			legacy_node.free()
		quit(1)
		return
	if legacy_node.has_meta(AutoObject.legacy_asset_voxel_record_key()):
		push_error("Expected legacy record metadata to be removed after migration")
		node.free()
		legacy_node.free()
		quit(1)
		return

	veg.build_voxel_volume(16, 1)
	var scene_voxels := veg.get_scene_voxels()
	var source_deltas := veg.get_source_voxel_deltas(veg.get_committed_tick())
	var global_field := veg.get_global_voxel_field()

	if scene_voxels.is_empty():
		push_error("Expected committed SceneVoxel entries")
		node.free()
		legacy_node.free()
		quit(1)
		return
	if source_deltas.is_empty() or (source_deltas.get("auto", {}) as Dictionary).is_empty():
		push_error("Expected AutoSceneVoxel source delta entries")
		node.free()
		legacy_node.free()
		quit(1)
		return
	if int(global_field.get("tile_count", 0)) <= 0:
		push_error("Expected GlobalVoxelField tiles")
		node.free()
		legacy_node.free()
		quit(1)
		return

	print("[test_voxel_placement_record_commit] record=%s scene_voxels=%d tiles=%d commit_tick=%d" % [
		str(record.id),
		scene_voxels.size(),
		int(global_field.get("tile_count", 0)),
		veg.get_committed_tick(),
	])
	node.free()
	legacy_node.free()
	quit(0)
