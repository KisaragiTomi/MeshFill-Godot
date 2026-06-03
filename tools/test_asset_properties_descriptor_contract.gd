extends SceneTree

const SharedPropertyTypeScript := preload("res://scripts/shared_property_type.gd")
const AutoVoxelDescriptorScript := preload("res://scripts/auto_voxel_descriptor.gd")
const AutoAssetFactoryScript := preload("res://scripts/auto_asset_factory.gd")
const AutoObjectScript := preload("res://scripts/auto_object.gd")
const AutoRockScript := preload("res://scripts/auto_rock.gd")


func _init() -> void:
	var ok := true
	ok = ok and _test_shared_field_contract()
	ok = ok and _test_descriptor_collision_canonical()
	ok = ok and _test_auto_object_descriptor_getters()
	ok = ok and _test_auto_object_config_preserves_existing_descriptor()
	ok = ok and _test_channel_and_scatter_fields_are_not_shared()
	ok = ok and _test_factory_and_subclass_canonical_collision()
	if ok:
		print("[AssetPropertiesDescriptorContract] ALL TESTS PASSED")
		quit(0)
	else:
		push_error("[AssetPropertiesDescriptorContract] SOME TESTS FAILED")
		quit(1)


func _test_shared_field_contract() -> bool:
	if SharedPropertyTypeScript.SHARED_FIELD_KEYS != ["color", "complexity", "collision"]:
		push_error("Expected shared fields to be color, complexity, collision")
		return false
	if SharedPropertyTypeScript.SHARED_FIELD_KEYS.has("channel"):
		push_error("Channel routing fields must not be shared semantic fields")
		return false
	var fields: Dictionary = SharedPropertyTypeScript.normalize_shared_fields({
		"color": Color(0.2, 0.3, 0.4, 0.8),
		"collision": [{"shape": "cylinder", "radius": 0.5, "collision_strength": 0.25}],
	})
	var color: Color = fields.color
	if not _approx(color.a, 0.8, 0.001) or not _approx(float(fields.complexity), 0.8, 0.001):
		push_error("Expected color alpha and complexity to stay synchronized")
		return false
	if not fields.has("collision"):
		push_error("Expected only canonical collision in shared fields")
		return false
	var collision: Array = fields.collision
	if collision.is_empty() or not _approx(float((collision[0] as Dictionary).get("collision_strength", 0.0)), 0.25, 0.001):
		push_error("Expected collision_strength to normalize from canonical collision")
		return false
	return true


func _test_descriptor_collision_canonical() -> bool:
	var descriptor: AutoVoxelDescriptor = AutoVoxelDescriptorScript.new()
	descriptor.set_color_and_complexity(Color(0.7, 0.1, 0.2, 1.0), 0.6)
	descriptor.set_collision([{
		"shape": "cylinder",
		"radius": 0.3,
		"y_min": 0.0,
		"y_max": 1.5,
		"collision_strength": 0.4,
	}])
	var collisions := descriptor.get_collision(0.2)
	if collisions.size() != 1:
		push_error("Expected descriptor canonical collision to be readable")
		return false
	if not _approx(float(collisions[0].get("collision_strength", 0.0)), 0.4, 0.001):
		push_error("Expected descriptor collision_strength to survive normalization")
		return false
	var record_fields := descriptor.to_record_fields(0.2)
	if not record_fields.has("collision"):
		push_error("Expected descriptor record fields to include only canonical collision")
		return false
	return true


func _test_auto_object_descriptor_getters() -> bool:
	var descriptor: AutoVoxelDescriptor = AutoVoxelDescriptorScript.new()
	descriptor.set_color_and_complexity(Color(0.1, 0.9, 0.2, 1.0), 0.35)
	descriptor.set_collision([{"voxel": Vector3i(1, 2, 3), "collision_strength": 0.7}])

	var obj: AutoObject = AutoObjectScript.new()
	obj.voxel_descriptor = descriptor
	obj.voxel_color = Color(1.0, 0.0, 0.0, 1.0)
	obj.voxel_complexity = 1.0
	obj.collision = [{"voxel": Vector3i(9, 9, 9), "collision_strength": 1.0}]
	var got_color := obj.get_voxel_color()
	if not _color_close(got_color, Color(0.1, 0.9, 0.2, 0.35), 0.001):
		push_error("Expected AutoObject getter to read descriptor color")
		obj.free()
		return false
	var got_collision := obj.get_collision()
	if got_collision.is_empty() or (got_collision[0] as Dictionary).get("voxel", Vector3i.ZERO) != Vector3i(1, 2, 3):
		push_error("Expected AutoObject getter to read descriptor collision")
		obj.free()
		return false
	obj.free()
	return true


func _test_auto_object_config_preserves_existing_descriptor() -> bool:
	var descriptor: AutoVoxelDescriptor = AutoVoxelDescriptorScript.new()
	descriptor.set_color_and_complexity(Color(0.2, 0.3, 0.8, 1.0), 0.4)
	descriptor.set_collision([{"voxel": Vector3i(2, 0, 0), "collision_strength": 0.3}])

	var obj: AutoObject = AutoObjectScript.new()
	obj.voxel_descriptor = descriptor
	obj.voxel_color = Color(1.0, 0.0, 0.0, 1.0)
	obj.voxel_complexity = 1.0
	obj.collision = [{"voxel": Vector3i(9, 9, 9), "collision_strength": 1.0}]
	obj.configure_auto_object({"name": "stale_mirror_contract"})

	var got_color := obj.get_voxel_color()
	if not _color_close(got_color, Color(0.2, 0.3, 0.8, 0.4), 0.001):
		push_error("Expected config without shared fields to preserve descriptor color over stale mirror")
		obj.free()
		return false
	var got_collision := obj.get_collision()
	if got_collision.is_empty() or (got_collision[0] as Dictionary).get("voxel", Vector3i.ZERO) != Vector3i(2, 0, 0):
		push_error("Expected config without shared fields to preserve descriptor collision over stale mirror")
		obj.free()
		return false

	var record := obj.make_instance_stamp_write_spec("stale_mirror_record", Vector2i(1, 1), 8)
	var record_color: Color = record.get("color", Color.TRANSPARENT)
	if not _color_close(record_color, Color(0.2, 0.3, 0.8, 0.4), 0.001):
		push_error("Expected ISWS record to use descriptor color over stale mirror")
		obj.free()
		return false
	var record_collision: Array = record.get("collision", [])
	if record_collision.is_empty() or (record_collision[0] as Dictionary).get("voxel", Vector3i.ZERO) != Vector3i(2, 0, 0):
		push_error("Expected ISWS record to use descriptor collision over stale mirror")
		obj.free()
		return false
	obj.free()
	return true


func _test_channel_and_scatter_fields_are_not_shared() -> bool:
	var normalized: Dictionary = SharedPropertyTypeScript.normalize_shared_fields({
		"color": Color(0.1, 0.2, 0.3, 0.6),
		"complexity": 0.6,
		"channel": 2,
		"vegetation_channel": 3,
		"vegetation_radius": 0.7,
	})
	for non_shared_key in ["channel", "vegetation_channel", "vegetation_radius"]:
		if normalized.has(non_shared_key):
			push_error("Expected %s to stay out of normalized shared fields" % non_shared_key)
			return false

	var descriptor: AutoVoxelDescriptor = AutoVoxelDescriptorScript.new()
	descriptor.vegetation_channel = 2
	descriptor.vegetation_radius = 0.45
	var fields := descriptor.to_record_fields(0.45)
	for non_shared_key in ["channel", "vegetation_channel", "vegetation_radius"]:
		if fields.has(non_shared_key):
			push_error("Expected descriptor record fields to keep %s out of shared fields" % non_shared_key)
			return false
	return true


func _test_factory_and_subclass_canonical_collision() -> bool:
	var descriptor := AutoAssetFactoryScript.create_voxel_descriptor(
		Color(0.3, 0.4, 0.5, 1.0),
		0.45,
		0.25,
		[{"shape": "cylinder", "radius": 0.2, "collision_strength": 0.5}]
	) as AutoVoxelDescriptor
	if descriptor == null:
		push_error("Expected factory to create AutoVoxelDescriptor")
		return false
	if descriptor.get_collision(0.25).is_empty():
		push_error("Expected factory-created descriptor to keep collision")
		return false

	var rock: AutoRock = AutoRockScript.new()
	rock.configure_rock({
		"color": Color(0.5, 0.5, 0.5, 1.0),
		"complexity": 0.5,
		"collision": [{"shape": "cylinder", "radius": 0.4, "collision_strength": 0.6}],
	})
	if rock.get_collision(0.4).is_empty():
		push_error("Expected AutoRock to accept canonical collision")
		rock.free()
		return false
	rock.free()
	return true


func _approx(a: float, b: float, eps: float) -> bool:
	return absf(a - b) <= eps


func _color_close(a: Color, b: Color, eps: float) -> bool:
	return (
		_approx(a.r, b.r, eps)
		and _approx(a.g, b.g, eps)
		and _approx(a.b, b.b, eps)
		and _approx(a.a, b.a, eps)
	)
