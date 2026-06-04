extends SceneTree


func _init() -> void:
	var ok := true
	ok = _test_vegetation_descriptor_factory_contract() and ok
	ok = _test_vegetation_instance_configuration() and ok
	ok = _test_object_factory_collision_contract() and ok
	ok = _test_profile_fallback_keeps_descriptor_collision() and ok
	ok = _test_typed_profile_fallback_keeps_descriptor_shared_fields() and ok
	ok = _test_isws_metadata_alias_contract() and ok
	ok = _test_factory_isws_wrapper_aliases() and ok

	if ok:
		print("[AutoAssetScripting] ALL TESTS PASSED")
		quit(OK)
	else:
		push_error("[AutoAssetScripting] SOME TESTS FAILED")
		quit(1)


func _test_vegetation_descriptor_factory_contract() -> bool:
	print("[AutoAssetScripting] test_vegetation_descriptor_factory_contract...")
	var collision := [{
		"shape": "cylinder",
		"radius": 0.3,
		"y_min": 0.0,
		"y_max": 1.0,
		"collision_strength": 0.6,
	}]
	var descriptor := AutoAssetFactory.create_voxel_descriptor(
		Color(0.9, 0.35, 0.5, 0.7),
		0.7,
		0.25,
		collision
	) as AutoVoxelDescriptor
	descriptor.asset_id = "auto_asset_contract_flower"
	descriptor.object_type = "vegetation"
	descriptor.object_subtype = "flower"
	descriptor.vegetation_channel = 2
	descriptor.vegetation_radius = 0.25
	descriptor.scatter_min_distance = 0.35
	descriptor.scatter_max_count = 800
	descriptor.scatter_max_scale = 0.7
	descriptor.visual_layer = 14
	descriptor.group = "placed_flowers"
	descriptor.mesh_create_method = "create_sample_autoobject_mesh"

	if not AutoAssetFactory.is_supported_vegetation_mesh_create_method("create_sample_autoobject_mesh"):
		push_error("  FAIL: supported mesh_create_method rejected")
		return false
	for method_name in ["create_legacy_mesh", "create_old_scatter_mesh"]:
		if AutoAssetFactory.is_supported_vegetation_mesh_create_method(method_name):
			push_error("  FAIL: unsupported mesh_create_method accepted: %s" % method_name)
			return false
	if AutoAssetFactory.is_supported_vegetation_mesh_create_method("create_procedural_asset_mesh"):
		push_error("  FAIL: unsupported mesh_create_method accepted")
		return false
	if descriptor.get_mesh() == null:
		push_error("  FAIL: descriptor mesh_create_method did not create a mesh")
		return false

	var config := descriptor.make_instance_config()
	if config.get("voxel_descriptor", null) != descriptor:
		push_error("  FAIL: make_instance_config did not include descriptor")
		return false
	if int(config.get("channel", -1)) != 2 or int(config.get("vegetation_channel", -1)) != 2:
		push_error("  FAIL: make_instance_config did not preserve channel fields")
		return false
	var config_collision: Array = config.get("collision", [])
	if config_collision.size() != 1:
		push_error("  FAIL: instance config should keep only canonical collision")
		return false
	if absf(float(config_collision[0].get("collision_strength", -1.0)) - 0.6) > 0.001:
		push_error("  FAIL: collision_strength was not normalized")
		return false

	print("  OK: descriptor carries semantics, mesh factory, scatter, and canonical collision")
	return true


func _test_vegetation_instance_configuration() -> bool:
	print("[AutoAssetScripting] test_vegetation_instance_configuration...")
	var descriptor := AutoAssetFactory.create_voxel_descriptor(
		Color(0.2, 0.8, 0.3, 0.5),
		0.5,
		0.4,
		[]
	) as AutoVoxelDescriptor
	descriptor.object_type = "vegetation"
	descriptor.object_subtype = "flower"
	descriptor.mesh_create_method = "create_sample_autoobject_mesh"
	descriptor.group = "placed_flowers"

	var vegetation := AutoObject.new()
	AutoAssetFactory.configure_vegetation_instance(vegetation, descriptor, {"name": "FactoryFlower"})
	if vegetation.voxel_descriptor != descriptor:
		push_error("  FAIL: configured vegetation did not keep descriptor")
		vegetation.free()
		return false
	if vegetation.get_record_object_type() != "vegetation" or vegetation.get_record_object_subtype() != "flower":
		push_error("  FAIL: configured vegetation type/subtype mismatch")
		vegetation.free()
		return false
	for key in ["voxel_color", "voxel_complexity", "auto_collision", "semantic_probe_profile", "semantic_probe_count", "semantic_probe_density", "pivot_variant_count", "allowed_anchor_kinds"]:
		if vegetation.has_meta(key):
			push_error("  FAIL: metadata mirrored semantic field: %s" % key)
			vegetation.free()
			return false

	print("  OK: factory configures descriptor-backed vegetation without semantic metadata mirrors")
	vegetation.free()
	return true


func _test_object_factory_collision_contract() -> bool:
	print("[AutoAssetScripting] test_object_factory_collision_contract...")
	var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	var height_texture := ImageTexture.create_from_image(image)
	var collision := [{
		"shape": "cylinder",
		"radius": 1.2,
		"y_min": 0.0,
		"y_max": 2.0,
	}]
	var obj := AutoAssetFactory.create_or_update_object_asset(
		AutoRock.new(),
		BoxMesh.new(),
		height_texture,
		4.2,
		null,
		Color(0.55, 0.5, 0.45, 1.0),
		1.0,
		collision
	)
	if not obj is AutoRock:
		push_error("  FAIL: expected AutoRock asset")
		obj.free()
		return false
	var config := obj.make_instance_config()
	if not config.has("collision"):
		push_error("  FAIL: object config should keep only canonical collision")
		obj.free()
		return false
	var obj_collision: Array = obj.get_collision(obj.mesh_size * 0.5)
	if obj_collision.size() != 1:
		push_error("  FAIL: object collision did not persist through descriptor-backed fields")
		obj.free()
		return false
	if not is_equal_approx(float(obj_collision[0].get("radius", 0.0)), 1.2):
		push_error("  FAIL: object collision radius mismatch")
		obj.free()
		return false

	print("  OK: object factory writes descriptor-backed canonical collision config")
	obj.free()
	return true


func _test_profile_fallback_keeps_descriptor_collision() -> bool:
	print("[AutoAssetScripting] test_profile_fallback_keeps_descriptor_collision...")
	var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	var height_texture := ImageTexture.create_from_image(image)

	var descriptor := AutoVoxelDescriptor.new()
	descriptor.set_color_and_complexity(Color(0.1, 0.2, 0.3, 0.4), 0.4)
	descriptor.set_collision([{"voxel": Vector3i(1, 0, 0), "collision_strength": 0.25}])

	var profile := AutoVoxelProfile.new()
	profile.color = Color(0.8, 0.7, 0.6, 0.9)
	profile.complexity = 0.9
	profile.collision = [{"voxel": Vector3i(9, 0, 0), "collision_strength": 1.0}]

	var obj := AutoRock.new()
	obj.voxel_descriptor = descriptor
	obj = AutoAssetFactory.create_or_update_object_asset(
		obj,
		BoxMesh.new(),
		height_texture,
		2.0,
		profile
	)
	var got_collision: Array = obj.get_collision(1.0)
	if got_collision.is_empty() or got_collision[0].get("voxel", Vector3i.ZERO) != Vector3i(1, 0, 0):
		push_error("  FAIL: profile fallback overwrote descriptor canonical collision")
		obj.free()
		return false
	if not _color_close(obj.get_voxel_color(), Color(0.1, 0.2, 0.3, 0.4), 0.001):
		push_error("  FAIL: profile fallback overwrote descriptor color/complexity")
		obj.free()
		return false

	print("  OK: profile fallback does not overwrite descriptor canonical shared fields")
	obj.free()
	return true


func _test_typed_profile_fallback_keeps_descriptor_shared_fields() -> bool:
	print("[AutoAssetScripting] test_typed_profile_fallback_keeps_descriptor_shared_fields...")
	var profile := AutoVoxelProfile.new()
	profile.color = Color(0.8, 0.7, 0.6, 0.9)
	profile.complexity = 0.9
	profile.collision = [{"voxel": Vector3i(9, 0, 0), "collision_strength": 1.0}]

	var rock_descriptor := AutoVoxelDescriptor.new()
	rock_descriptor.set_color_and_complexity(Color(0.1, 0.2, 0.3, 0.4), 0.4)
	rock_descriptor.set_collision([{"voxel": Vector3i(1, 0, 0), "collision_strength": 0.25}])

	var rock := AutoRock.new()
	rock.voxel_descriptor = rock_descriptor
	obj.configure_object({"voxel_profile": profile})
	if not _color_close(rock.get_voxel_color(), Color(0.1, 0.2, 0.3, 0.4), 0.001):
		push_error("  FAIL: rock profile fallback overwrote descriptor color/complexity")
		rock.free()
		return false
	var rock_collision: Array = rock.get_collision(1.0)
	if rock_collision.is_empty() or rock_collision[0].get("voxel", Vector3i.ZERO) != Vector3i(1, 0, 0):
		push_error("  FAIL: rock profile fallback overwrote descriptor collision")
		rock.free()
		return false
	rock.free()

	var vegetation_descriptor := AutoVoxelDescriptor.new()
	vegetation_descriptor.set_color_and_complexity(Color(0.25, 0.5, 0.2, 0.35), 0.35)
	vegetation_descriptor.object_type = "vegetation"
	vegetation_descriptor.object_subtype = "soft_leaf"

	var vegetation := AutoObject.new()
	vegetation.configure_auto_object({
		"voxel_descriptor": vegetation_descriptor,
		"voxel_profile": profile,
		"name": "DescriptorBackedSoftLeaf",
	})
	if vegetation.voxel_descriptor != vegetation_descriptor:
		push_error("  FAIL: vegetation did not keep config descriptor")
		vegetation.free()
		return false
	if not _color_close(vegetation.get_voxel_color(), Color(0.25, 0.5, 0.2, 0.35), 0.001):
		push_error("  FAIL: vegetation profile fallback overwrote descriptor color/complexity")
		vegetation.free()
		return false
	if not vegetation.get_collision().is_empty():
		push_error("  FAIL: vegetation profile fallback filled descriptor-empty collision")
		vegetation.free()
		return false

	print("  OK: typed profile fallback preserves descriptor-backed shared fields")
	vegetation.free()
	return true


func _test_isws_metadata_alias_contract() -> bool:
	print("[AutoAssetScripting] test_isws_metadata_alias_contract...")
	var obj := AutoObject.new()
	obj.name = "ISWSAliasObject"
	var descriptor := AutoVoxelDescriptor.new()
	descriptor.set_color_and_complexity(Color(0.3, 0.4, 0.5, 0.6), 0.6)
	obj.voxel_descriptor = descriptor
	var record := obj.make_instance_stamp_write_spec("isws_alias_record", Vector2i(4, 5), 16)
	obj.set_instance_stamp_write_spec(record)

	if not obj.has_meta(AutoObject.INSTANCE_STAMP_WRITE_SPEC_META_KEY):
		push_error("  FAIL: canonical ISWS metadata key missing")
		obj.free()
		return false
	if not obj.has_meta(AutoObject.VOXEL_WRITE_SPEC_META_KEY):
		push_error("  FAIL: legacy voxel_write_spec metadata key missing")
		obj.free()
		return false
	var isws: Dictionary = obj.get_instance_stamp_write_spec()
	var legacy: Dictionary = obj.get_voxel_write_spec()
	if str(isws.get("id", "")) != "isws_alias_record" or str(legacy.get("id", "")) != "isws_alias_record":
		push_error("  FAIL: ISWS alias did not preserve record id")
		obj.free()
		return false
	if AutoObject.voxel_write_spec_meta_keys()[0] != AutoObject.INSTANCE_STAMP_WRITE_SPEC_META_KEY:
		push_error("  FAIL: canonical ISWS key should be preferred during metadata lookup")
		obj.free()
		return false
	obj.set_meta(AutoObject.VOXEL_WRITE_SPEC_META_KEY, {
		"id": "legacy_only_stale_record",
		"base_pixel": Vector2i.ZERO,
		"volume_xz_resolution": 1,
	})
	var preferred: Dictionary = obj.get_instance_stamp_write_spec()
	if str(preferred.get("id", "")) != "isws_alias_record":
		push_error("  FAIL: canonical ISWS metadata should win over stale legacy metadata")
		obj.free()
		return false

	var legacy_only := AutoObject.new()
	legacy_only.name = "LegacyOnlyISWSObject"
	legacy_only.set_meta(AutoObject.VOXEL_WRITE_SPEC_META_KEY, {
		"id": "legacy_only_record",
		"base_pixel": Vector2i(2, 3),
		"volume_xz_resolution": 8,
	})
	var promoted: Dictionary = legacy_only.get_instance_stamp_write_spec()
	if str(promoted.get("id", "")) != "legacy_only_record":
		push_error("  FAIL: legacy-only voxel_write_spec metadata was not readable as ISWS")
		obj.free()
		legacy_only.free()
		return false
	if not legacy_only.has_meta(AutoObject.INSTANCE_STAMP_WRITE_SPEC_META_KEY):
		push_error("  FAIL: legacy-only voxel_write_spec metadata was not promoted to canonical ISWS metadata")
		obj.free()
		legacy_only.free()
		return false
	legacy_only.free()

	print("  OK: canonical ISWS metadata/API aliases legacy voxel_write_spec")
	obj.free()
	return true


func _test_factory_isws_wrapper_aliases() -> bool:
	print("[AutoAssetScripting] test_factory_isws_wrapper_aliases...")
	var profile := AutoVoxelProfile.new()
	profile.color = Color(0.25, 0.35, 0.45, 0.55)
	profile.complexity = 0.55
	profile.collision = [{"voxel": Vector3i.ZERO, "collision_strength": 0.5}]
	var isws := AutoAssetFactory.make_profile_instance_stamp_write_spec(
		"factory_isws_record",
		"rock",
		Vector3.ZERO,
		Vector3.ZERO,
		Vector3.ONE,
		Vector2i(1, 2),
		8,
		profile,
		1.0,
		0.0,
		1.0,
		[],
		{"channel": 3}
	)
	var legacy := AutoAssetFactory.make_profile_voxel_write_spec(
		"factory_isws_record",
		"rock",
		Vector3.ZERO,
		Vector3.ZERO,
		Vector3.ONE,
		Vector2i(1, 2),
		8,
		profile,
		1.0,
		0.0,
		1.0,
		[],
		{"channel": 3}
	)
	if isws != legacy:
		push_error("  FAIL: factory canonical ISWS wrapper diverged from legacy voxel_write_spec helper")
		return false
	if isws.has("object_subtype"):
		push_error("  FAIL: profile ISWS helper should not create a new object_subtype schema dependency")
		return false

	print("  OK: factory canonical ISWS wrappers share the legacy helper record")
	return true


func _color_close(a: Color, b: Color, eps: float) -> bool:
	return (
		absf(a.r - b.r) <= eps
		and absf(a.g - b.g) <= eps
		and absf(a.b - b.b) <= eps
		and absf(a.a - b.a) <= eps
	)
