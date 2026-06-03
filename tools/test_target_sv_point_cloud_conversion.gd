extends SceneTree

const TargetSceneVoxelGeneratorScript := preload("res://scripts/target_scene_voxel_generator.gd")

const SCENE_PATH := "res://demos/target-sv-point-cloud-conversion/target-sv-point-cloud-conversion.tscn"
const META_PATH := "res://demos/target-sv-point-cloud-conversion/target_sv_point_cloud.json"


func _init() -> void:
	var ok := true
	ok = _test_scene_loads() and ok
	ok = _test_fixture_buffers_decode() and ok
	if ok:
		print("[TargetSVPointCloudConversion] ALL TESTS PASSED")
		quit(0)
	else:
		push_error("[TargetSVPointCloudConversion] SOME TESTS FAILED")
		quit(1)


func _test_scene_loads() -> bool:
	print("[TargetSVPointCloudConversion] test_scene_loads...")
	var scene := load(SCENE_PATH)
	if scene == null:
		push_error("  FAIL: scene does not load: %s" % SCENE_PATH)
		return false
	var instance = scene.instantiate()
	if instance == null:
		push_error("  FAIL: scene does not instantiate")
		return false
	instance.call("_ready")
	if instance.get_node_or_null("HeightTextureTerrain") == null:
		push_error("  FAIL: scene did not build height terrain")
		instance.free()
		return false
	if instance.get_node_or_null("TargetSVPreviewOverlay") == null:
		push_error("  FAIL: scene did not build TargetSV preview overlay")
		instance.free()
		return false
	var voxel_samples := instance.get_node_or_null("TargetSVVoxelSamples") as MultiMeshInstance3D
	if voxel_samples == null or voxel_samples.multimesh == null or voxel_samples.multimesh.instance_count <= 0:
		push_error("  FAIL: scene did not build TargetSV voxel samples")
		instance.free()
		return false
	instance.free()
	print("  OK: scene resource loads and builds visualization nodes")
	return true


func _test_fixture_buffers_decode() -> bool:
	print("[TargetSVPointCloudConversion] test_fixture_buffers_decode...")
	var metadata := _read_metadata()
	if metadata.is_empty():
		return false
	var texture_size := int(metadata.get("texture_size", 0))
	var slice_count := int(metadata.get("slice_count", 0))
	var voxel_count := texture_size * texture_size * slice_count
	var visual_bytes := _read_bytes(str(metadata.get("visual_path", "")))
	var collision_bytes := _read_bytes(str(metadata.get("collision_path", "")))
	var ok := true
	if visual_bytes.size() != voxel_count * 16:
		push_error("  FAIL: visual buffer size mismatch: %d" % visual_bytes.size())
		ok = false
	if collision_bytes.size() != voxel_count * 4:
		push_error("  FAIL: collision buffer size mismatch: %d" % collision_bytes.size())
		ok = false

	var decoded := TargetSceneVoxelGeneratorScript.decode_target_read_buffers(visual_bytes, collision_bytes, texture_size, slice_count)
	if not bool(decoded.get("valid", false)):
		push_error("  FAIL: decode_target_read_buffers rejected fixture: %s" % str(decoded))
		ok = false
	if float(decoded.get("max_occupancy", 0.0)) <= 0.0:
		push_error("  FAIL: decoded target occupancy is empty")
		ok = false
	if float(decoded.get("max_collision", 0.0)) <= 0.0:
		push_error("  FAIL: decoded target collision is empty")
		ok = false
	if not bool(metadata.get("target_guidance_only", false)):
		push_error("  FAIL: metadata must preserve target_guidance_only=true")
		ok = false
	if absf(float(metadata.get("max_height", 0.0)) - 120.0) > 0.001:
		push_error("  FAIL: metadata max_height must be 120m, got %.4f" % float(metadata.get("max_height", 0.0)))
		ok = false
	if bool(metadata.get("height_buffer_applied", true)) or bool(metadata.get("collision_buffer_applied", true)):
		push_error("  FAIL: TargetSV conversion must not mark source buffers as applied")
		ok = false
	if int(metadata.get("used_point_count", 0)) <= 0 or int(metadata.get("non_empty_voxel_count", 0)) <= 0:
		push_error("  FAIL: metadata point or voxel counts are empty")
		ok = false

	if ok:
		print("  OK: %d voxels decode with max occupancy %.3f and max collision %.3f" % [
			voxel_count,
			float(decoded.get("max_occupancy", 0.0)),
			float(decoded.get("max_collision", 0.0)),
		])
	return ok


func _read_metadata() -> Dictionary:
	var file := FileAccess.open(META_PATH, FileAccess.READ)
	if file == null:
		push_error("  FAIL: missing metadata: %s" % META_PATH)
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary:
		return parsed
	push_error("  FAIL: invalid metadata JSON")
	return {}


func _read_bytes(path: String) -> PackedByteArray:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("  FAIL: missing buffer: %s" % path)
		return PackedByteArray()
	return file.get_buffer(file.get_length())
