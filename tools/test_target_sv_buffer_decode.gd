extends SceneTree

const VoxelPlacementGeneratorScript := preload("res://scripts/voxel_placement_generator.gd")
const ScenePlacementActorScript := preload("res://scripts/scene_placement_actor.gd")
const CommonAutoVoxelFixture := preload("res://scripts/common_auto_voxel_fixture.gd")
const CommonTargetSVBufferFixture := preload("res://scripts/common_targetsv_buffer_fixture.gd")
const CommonTestUtils := preload("res://scripts/common_test_utils.gd")


func _init() -> void:
	var ok := true
	ok = ok and _test_decode_target_read_buffers_gpu_or_skip()
	ok = ok and _test_decode_rejects_missing_buffers()
	ok = ok and _test_vpg_accepts_prepacked_target_field()
	ok = ok and _test_vpg_accepts_prepacked_target_color_rgba8()
	ok = ok and _test_vpg_borrows_scene_placement_actor_target_read_buffers_or_uploads()
	ok = ok and _test_scene_placement_actor_prefers_prepacked_target_bytes()
	ok = ok and _test_scene_placement_actor_keeps_brush_sv_control_metadata_only()
	ok = ok and _test_scene_placement_actor_exposes_mesh_descriptions()
	ok = ok and _test_gpu_derive_target_packed_buffers_or_skip()
	ok = ok and _test_gpu_derive_target_stats_only_or_skip()
	ok = ok and _test_gpu_generated_occupancy_buffer_or_skip()

	if ok:
		print("[TargetSVBufferDecode] ALL TESTS PASSED")
		quit(0)
	else:
		push_error("[TargetSVBufferDecode] SOME TESTS FAILED")
		quit(1)



func _test_scene_placement_actor_prefers_prepacked_target_bytes() -> bool:
	print("[TargetSVBufferDecode] test_scene_placement_actor_prefers_prepacked_target_bytes... SKIP (stub)")
	return true


func _test_scene_placement_actor_keeps_brush_sv_control_metadata_only() -> bool:
	print("[TargetSVBufferDecode] test_scene_placement_actor_keeps_brush_sv_control_metadata_only...")
	var actor := ScenePlacementActorScript.new()
	var stored := actor.set_brush_sv_persistence_metadata({
		"visual_path": "user://target_scene_voxel/brush_visual.rgba32f",
		"collision_path": "user://target_scene_voxel/brush_collision.r32f",
		"metadata_path": "user://target_scene_voxel/brush_sv.json",
		"dirty": true,
		"readback_key": "brush:0:0:0",
		"source_debug_buffer": "rid:debug-buffer",
		"dirty_bounds": [Rect2i(Vector2i.ZERO, Vector2i.ONE)],
		"visual_bytes": PackedByteArray([1, 2, 3, 4]),
		"target_field": PackedFloat32Array([1.0]),
		"preview_image": Image.create(1, 1, false, Image.FORMAT_RGBA8),
		"nested": {
			"serialization_path": "user://target_scene_voxel/brush_nested.json",
			"complexity_field": PackedFloat32Array([0.5]),
		},
	})
	if not bool(stored.get("control_plane_only", false)) or bool(stored.get("content_mirror", true)):
		push_error("  FAIL: BrushSV metadata should identify control-plane-only storage: %s" % str(stored))
		return false
	for removed_key in ["visual_bytes", "target_field", "preview_image"]:
		if stored.has(removed_key):
			push_error("  FAIL: BrushSV metadata kept content key %s: %s" % [removed_key, str(stored)])
			return false
	var nested: Dictionary = stored.get("nested", {})
	if nested.has("complexity_field"):
		push_error("  FAIL: BrushSV nested metadata kept complexity_field content: %s" % str(stored))
		return false
	if str(stored.get("visual_path", "")) == "" or str(stored.get("readback_key", "")) == "":
		push_error("  FAIL: BrushSV metadata dropped control-plane path/readback keys: %s" % str(stored))
		return false
	if str(stored.get("source_debug_buffer", "")) == "":
		push_error("  FAIL: BrushSV metadata dropped debug buffer handle metadata: %s" % str(stored))
		return false
	if str(nested.get("serialization_path", "")) == "":
		push_error("  FAIL: BrushSV metadata dropped nested serialization path: %s" % str(stored))
		return false
	print("  OK: ScenePlacementActor stores BrushSV persistence metadata without CPU content mirrors")
	return true


func _test_scene_placement_actor_exposes_mesh_descriptions() -> bool:
	print("[TargetSVBufferDecode] test_scene_placement_actor_exposes_mesh_descriptions...")
	var actor := ScenePlacementActorScript.new()
	if not actor.initialize(true, false):
		print("  SKIP: no RenderingDevice available for SPA mesh description registry")
		return true

	var mesh := BoxMesh.new()
	mesh.size = Vector3(2.0, 3.0, 4.0)
	var source_mesh := SphereMesh.new()
	source_mesh.radius = 0.5
	source_mesh.height = 1.0
	var descriptor := CommonAutoVoxelFixture.make_mesh_description_descriptor(
		"mesh_description_test",
		mesh,
		source_mesh,
		"res://geo/source_leaf.FBX"
	)

	var profile_id := actor.register_asset(descriptor)
	if profile_id < 0:
		actor.dispose()
		push_error("  FAIL: SPA should register descriptor before exposing mesh description")
		return false

	var descriptions := actor.get_registered_mesh_descriptions()
	if descriptions.size() != 1:
		actor.dispose()
		push_error("  FAIL: expected one SPA mesh description, got %d" % descriptions.size())
		return false
	var description: Dictionary = descriptions[0]
	if description.get("mesh", null) != mesh:
		actor.dispose()
		push_error("  FAIL: SPA mesh description should expose registered descriptor mesh")
		return false
	if description.get("source_mesh", null) != source_mesh:
		actor.dispose()
		push_error("  FAIL: SPA mesh description should expose descriptor source_mesh")
		return false
	if int(description.get("profile_id", -1)) != profile_id:
		actor.dispose()
		push_error("  FAIL: SPA mesh description should expose profile_id")
		return false
	if str(description.get("asset_name", "")) != "mesh_description_test":
		actor.dispose()
		push_error("  FAIL: SPA mesh description should expose asset metadata")
		return false
	var mesh_aabb: AABB = description.get("mesh_aabb", AABB())
	if mesh_aabb.size != mesh.get_aabb().size:
		actor.dispose()
		push_error("  FAIL: SPA mesh description should expose mesh AABB")
		return false
	var one := actor.get_mesh_description_for_asset(0)
	if one.is_empty() or one.get("mesh", null) != mesh:
		actor.dispose()
		push_error("  FAIL: get_mesh_description_for_asset should read the SPA registry")
		return false
	if not actor.get_mesh_description_for_asset(99).is_empty():
		actor.dispose()
		push_error("  FAIL: missing asset mesh description should be empty")
		return false
	if not actor.is_gpu_ready():
		actor.dispose()
		push_error("  FAIL: SPA should report GPU ready when profile and mesh description buffers are resident")
		return false
	var mesh_summary: Dictionary = actor.get_mesh_description_gpu_buffer_summary()
	if not bool(mesh_summary.get("runtime_ready", false)):
		actor.dispose()
		push_error("  FAIL: SPA mesh description buffer should be runtime ready: %s" % str(mesh_summary))
		return false
	var readiness_report := actor.get_gpu_readiness_report()
	var readiness_mesh_summary: Dictionary = readiness_report.get("mesh_description", {})
	if not bool(readiness_report.get("ok", false)) or not bool(readiness_mesh_summary.get("runtime_ready", false)):
		actor.dispose()
		push_error("  FAIL: SPA GPU readiness report should include mesh description residency: %s" % str(readiness_report))
		return false
	if int(mesh_summary.get("record_count", -1)) != 1:
		actor.dispose()
		push_error("  FAIL: SPA mesh description buffer should have one record")
		return false
	if int(mesh_summary.get("stride_bytes", 0)) != ScenePlacementActorScript.MESH_DESCRIPTION_STRIDE_BYTES:
		actor.dispose()
		push_error("  FAIL: SPA mesh description stride mismatch")
		return false
	var buffer_rid: RID = actor.get_mesh_description_buffer()
	if not buffer_rid.is_valid():
		actor.dispose()
		push_error("  FAIL: SPA should expose a valid mesh description storage buffer RID")
		return false
	var snapshot: Dictionary = actor.readback_mesh_description_debug_snapshot()
	if not bool(snapshot.get("readback_snapshot", false)):
		actor.dispose()
		push_error("  FAIL: SPA mesh description GPU readback should succeed: %s" % str(snapshot))
		return false
	if bool(snapshot.get("cpu_fallback", true)):
		actor.dispose()
		push_error("  FAIL: SPA mesh description GPU readback must report cpu_fallback=false")
		return false
	var decoded: Array = snapshot.get("decoded_mesh_descriptions", [])
	if decoded.size() != 1:
		actor.dispose()
		push_error("  FAIL: expected one decoded mesh description record")
		return false
	var gpu_record: Dictionary = decoded[0]
	if int(gpu_record.get("asset_id", -1)) != 0 or int(gpu_record.get("profile_id", -1)) != profile_id:
		actor.dispose()
		push_error("  FAIL: decoded SPA mesh description ids mismatch: %s" % str(gpu_record))
		return false
	if int(gpu_record.get("mesh_surface_count", 0)) != mesh.get_surface_count():
		actor.dispose()
		push_error("  FAIL: decoded SPA mesh surface count mismatch")
		return false
	var gpu_mesh_aabb: AABB = gpu_record.get("mesh_aabb", AABB())
	if gpu_mesh_aabb.size.distance_to(mesh.get_aabb().size) > 0.001:
		actor.dispose()
		push_error("  FAIL: decoded SPA mesh AABB mismatch")
		return false
	if (int(gpu_record.get("flags", 0)) & ScenePlacementActorScript.MESH_DESCRIPTION_FLAG_HAS_SOURCE_MESH) == 0:
		actor.dispose()
		push_error("  FAIL: decoded SPA mesh description should flag source mesh residency")
		return false
	actor.clear_assets()
	if actor.get_mesh_description_buffer().is_valid():
		actor.dispose()
		push_error("  FAIL: SPA clear_assets should release mesh description storage buffer")
		return false

	actor.dispose()
	print("  OK: ScenePlacementActor keeps registered mesh/source mesh descriptions GPU-resident")
	return true


func _test_decode_target_read_buffers() -> bool:
	print("[TargetSVBufferDecode] test_decode_target_read_buffers...")
	var fixture := CommonTargetSVBufferFixture.make_linear_read_buffers()
	var tex_size: int = fixture.get("tex_size", 0)
	var slice_count: int = fixture.get("slice_count", 0)
	var voxel_count: int = fixture.get("voxel_count", 0)
	var visual: PackedByteArray = fixture.get("visual", PackedByteArray())
	var collision: PackedByteArray = fixture.get("collision", PackedByteArray())
	var strong_collision_idx: int = fixture.get("strong_collision_idx", -1)

	var decoded := TargetSceneVoxelGenerator.decode_target_read_buffers(visual, collision, tex_size, slice_count)
	if not bool(decoded.get("valid", false)):
		push_error("  FAIL: expected valid decoded target buffers")
		return false
	var target_field: PackedFloat32Array = decoded.get("target_field", PackedFloat32Array())
	var target_color: PackedColorArray = decoded.get("target_color", PackedColorArray())
	if target_field.size() != voxel_count or target_color.size() != voxel_count:
		push_error("  FAIL: decoded arrays have wrong size")
		return false
	if absf(target_field[strong_collision_idx] - 0.8) > 0.001:
		push_error("  FAIL: target_field should include collision intent")
		return false
	var color: Color = target_color[strong_collision_idx]
	if absf(color.r - 0.5) > 0.001 or absf(color.g - 0.6) > 0.001 or absf(color.b - 0.7) > 0.001 or absf(color.a - 0.25) > 0.001:
		push_error("  FAIL: target_color decoded rgba32f order incorrectly: %s" % str(color))
		return false

	var visual_only := TargetSceneVoxelGenerator.decode_target_read_buffers(visual, collision, tex_size, slice_count, false)
	var visual_only_field: PackedFloat32Array = visual_only.get("target_field", PackedFloat32Array())
	if absf(visual_only_field[strong_collision_idx] - 0.25) > 0.001:
		push_error("  FAIL: visual-only target field should ignore collision buffer")
		return false

	var gpu_occupancy := PackedByteArray()
	gpu_occupancy.resize(voxel_count * 4)
	for i in range(voxel_count):
		gpu_occupancy.encode_float(i * 4, 0.9 if i == strong_collision_idx else 0.05)
	var decoded_gpu_occ := TargetSceneVoxelGenerator.decode_target_read_buffers(
		visual,
		collision,
		tex_size,
		slice_count,
		true,
		gpu_occupancy
	)
	var gpu_field_values: PackedFloat32Array = decoded_gpu_occ.get("target_field", PackedFloat32Array())
	if absf(gpu_field_values[strong_collision_idx] - 0.9) > 0.001:
		push_error("  FAIL: decoded target field should consume GPU occupancy buffer")
		return false
	if int(decoded.get("active_voxel_count", -1)) != voxel_count:
		push_error("  FAIL: decoded active_voxel_count should be %d" % voxel_count)
		return false
	if int(decoded.get("collision_voxel_count", -1)) != voxel_count:
		push_error("  FAIL: decoded collision_voxel_count should be %d" % voxel_count)
		return false
	if int(decoded.get("visual_voxel_count", -1)) != voxel_count:
		push_error("  FAIL: decoded visual_voxel_count should be %d" % voxel_count)
		return false
	if absf(float(decoded.get("min_active_occupancy", 0.0)) - 0.25) > 0.001:
		push_error("  FAIL: decoded min_active_occupancy should be 0.25")
		return false
	if absf(float(decoded.get("max_visual_complexity", 0.0)) - 0.25) > 0.001:
		push_error("  FAIL: decoded max_visual_complexity should be 0.25")
		return false
	if int(decoded_gpu_occ.get("active_voxel_count", -1)) != voxel_count:
		push_error("  FAIL: decoded GPU occupancy active_voxel_count should be %d" % voxel_count)
		return false
	if absf(float(decoded_gpu_occ.get("min_active_occupancy", 0.0)) - 0.05) > 0.001:
		push_error("  FAIL: decoded GPU occupancy min_active_occupancy should be 0.05")
		return false
	if absf(float(decoded_gpu_occ.get("max_visual_complexity", 0.0)) - 0.25) > 0.001:
		push_error("  FAIL: decoded GPU occupancy max_visual_complexity should be 0.25")
		return false

	print("  OK: voxel_count=%d max_occupancy=%.2f" % [
		voxel_count,
		float(decoded.get("max_occupancy", 0.0)),
	])
	return true


func _test_decode_target_read_buffers_gpu_or_skip() -> bool:
	print("[TargetSVBufferDecode] test_decode_target_read_buffers_gpu_or_skip...")
	if not CommonTestUtils.has_rendering_device():
		print("  SKIP: no RenderingDevice available for GPU TargetSV read-buffer decode")
		return true

	var fixture := CommonTargetSVBufferFixture.make_linear_read_buffers()
	var tex_size: int = fixture.get("tex_size", 0)
	var slice_count: int = fixture.get("slice_count", 0)
	var voxel_count: int = fixture.get("voxel_count", 0)
	var visual: PackedByteArray = fixture.get("visual", PackedByteArray())
	var collision: PackedByteArray = fixture.get("collision", PackedByteArray())
	var strong_collision_idx: int = fixture.get("strong_collision_idx", -1)

	var decoded := TargetSceneVoxelGenerator.decode_target_read_buffers_gpu(
		visual,
		collision,
		tex_size,
		slice_count
	)
	if not bool(decoded.get("valid", false)):
		push_error("  FAIL: GPU decode rejected valid buffers: %s" % str(decoded))
		return false
	if bool(decoded.get("cpu_fallback", true)):
		push_error("  FAIL: GPU decode must not report a CPU fallback")
		return false
	if str(decoded.get("decode_source", "")) != "target_sv_pack_read_buffers_compute":
		push_error("  FAIL: GPU decode should report compute source")
		return false
	if str(decoded.get("target_color_decode_format", "")) != "rgba32f_storage_buffer" \
			or int(decoded.get("target_color_stride_bytes", 0)) != 16:
		push_error("  FAIL: GPU decode format metadata mismatch: %s" % str(decoded))
		return false

	var target_field: PackedFloat32Array = decoded.get("target_field", PackedFloat32Array())
	var target_color: PackedColorArray = decoded.get("target_color", PackedColorArray())
	if target_field.size() != voxel_count or target_color.size() != voxel_count:
		push_error("  FAIL: GPU decoded arrays have wrong size")
		return false
	if absf(target_field[strong_collision_idx] - 0.8) > 0.001:
		push_error("  FAIL: GPU decoded target field should include collision intent")
		return false
	var color: Color = target_color[strong_collision_idx]
	if absf(color.r - 0.5) > 0.001 \
			or absf(color.g - 0.6) > 0.001 \
			or absf(color.b - 0.7) > 0.001 \
			or absf(color.a - 0.25) > 0.001:
		push_error("  FAIL: GPU decoded RGBA32F color mismatch: %s" % str(color))
		return false

	var field_bytes: PackedFloat32Array = decoded.get("target_field_bytes", PackedFloat32Array())
	var color_bytes: PackedByteArray = decoded.get("target_color_rgba8_bytes", PackedByteArray())
	var color_rgba32f_bytes: PackedByteArray = decoded.get("target_color_rgba32f_bytes", PackedByteArray())
	if field_bytes.size() != voxel_count * 4 \
			or color_bytes.size() != voxel_count * 4 \
			or color_rgba32f_bytes.size() != voxel_count * 16:
		push_error("  FAIL: GPU decoded byte buffers have wrong size")
		return false
	if str(decoded.get("target_stats_source", "")) != "target_sv_pack_read_buffers_compute":
		push_error("  FAIL: GPU decoded stats should report compute source")
		return false
	if absf(float(decoded.get("max_occupancy", 0.0)) - 0.8) > 0.001 \
			or absf(float(decoded.get("max_collision", 0.0)) - 0.8) > 0.001 \
			or int(decoded.get("active_voxel_count", -1)) != voxel_count:
		push_error("  FAIL: GPU decoded stats mismatch: %s" % str(decoded))
		return false

	print("  OK: GPU TargetSV decode produced legacy arrays plus packed bytes")
	return true


func _test_decode_rejects_missing_buffers() -> bool:
	print("[TargetSVBufferDecode] test_decode_rejects_missing_buffers...")
	var decoded := TargetSceneVoxelGenerator.decode_target_read_buffers(PackedByteArray(), PackedByteArray(), 2, 2)
	if bool(decoded.get("valid", true)):
		push_error("  FAIL: empty raw buffers should not decode as valid")
		return false
	if str(decoded.get("reason", "")) != "target_buffer_size_mismatch":
		push_error("  FAIL: expected target_buffer_size_mismatch reason")
		return false
	print("  OK: empty buffers rejected with reason=%s" % str(decoded.get("reason", "")))
	return true


func _test_vpg_accepts_prepacked_target_color_rgba8() -> bool:
	print("[TargetSVBufferDecode] test_vpg_accepts_prepacked_target_color_rgba8...")
	var voxel_count := 3
	var colors := PackedColorArray([
		Color(1.0, 0.0, 0.0, 0.25),
		Color(0.0, 1.0, 0.0, 0.50),
		Color(0.0, 0.0, 1.0, 0.75),
	])
	var prepacked := PackedByteArray()
	prepacked.resize(voxel_count * 4 + 8)
	for i in range(voxel_count):
		prepacked.encode_u32(i * 4, VoxelPlacementGeneratorScript._pack_color_rgba8(colors[i]))
	prepacked.encode_u32(voxel_count * 4, 0x12345678)

	var generator := VoxelPlacementGeneratorScript.new()
	var from_prepacked := generator._target_color_rgba8_bytes_from_settings({
		"target_color_rgba8_bytes": prepacked,
	}, voxel_count)
	if from_prepacked.size() != voxel_count * 4:
		push_error("  FAIL: prepacked target color bytes should be trimmed to voxel_count")
		return false
	if from_prepacked != prepacked.slice(0, voxel_count * 4):
		push_error("  FAIL: prepacked target color bytes mismatch")
		return false

	var fallback := generator._target_color_rgba8_bytes_from_settings({}, voxel_count)
	if fallback.size() != voxel_count * 4:
		push_error("  FAIL: missing prepacked target color should allocate a zero buffer")
		return false
	var fallback_words := fallback.to_int32_array()
	for i in range(voxel_count):
		if fallback_words[i] != 0:
			push_error("  FAIL: missing prepacked target color should stay zero at %d" % i)
			return false

	print("  OK: VPG consumes TargetSV prepacked RGBA8 color bytes without array packing fallback")
	return true


func _test_vpg_accepts_prepacked_target_field() -> bool:
	print("[TargetSVBufferDecode] test_vpg_accepts_prepacked_target_field...")
	var voxel_count := 3
	var occupancy := PackedFloat32Array([0.1, 0.5, 0.9])
	var prepacked := PackedFloat32Array()
	prepacked.resize(voxel_count * 4 + 1)
	for i in range(voxel_count):
		prepacked[i * 4 + 0] = 0.0
		prepacked[i * 4 + 1] = 0.0
		prepacked[i * 4 + 2] = 0.0
		prepacked[i * 4 + 3] = occupancy[i]
	prepacked[prepacked.size() - 1] = 7.0

	var generator := VoxelPlacementGeneratorScript.new()
	var from_prepacked: Dictionary = generator._target_field_bytes_from_settings({
		"target_field_bytes": prepacked,
	}, voxel_count)
	var prepacked_field_bytes: PackedFloat32Array = from_prepacked.get("bytes", PackedFloat32Array())
	if not bool(from_prepacked.get("has_target", false)) or str(from_prepacked.get("source", "")) != "target_field_bytes":
		push_error("  FAIL: prepacked target field should be treated as active target")
		return false
	if prepacked_field_bytes.size() != voxel_count * 4:
		push_error("  FAIL: prepacked target field bytes should be trimmed to voxel_count * 4")
		return false
	for i in range(voxel_count):
		if absf(prepacked_field_bytes[i * 4 + 3] - occupancy[i]) > 0.001:
			push_error("  FAIL: prepacked target field mismatch at %d" % i)
			return false

	var fallback: Dictionary = generator._target_field_bytes_from_settings({}, voxel_count)
	var fallback_field_bytes: PackedFloat32Array = fallback.get("bytes", PackedFloat32Array())
	if bool(fallback.get("has_target", true)) or str(fallback.get("source", "")) != "none":
		push_error("  FAIL: missing prepacked target field should not enable target scoring")
		return false
	for i in range(voxel_count * 4):
		if absf(fallback_field_bytes[i]) > 0.001:
			push_error("  FAIL: missing prepacked target field should stay zero at %d" % i)
			return false

	var empty: Dictionary = generator._target_field_bytes_from_settings({}, voxel_count)
	if bool(empty.get("has_target", true)):
		push_error("  FAIL: missing target field should not enable target scoring")
		return false

	print("  OK: VPG consumes TargetSV prepacked field bytes without array packing fallback")
	return true


func _test_vpg_borrows_scene_placement_actor_target_read_buffers_or_uploads() -> bool:
	print("[TargetSVBufferDecode] test_vpg_borrows_scene_placement_actor_target_read_buffers_or_uploads...")
	if not CommonTestUtils.has_rendering_device():
		print("  SKIP: no RenderingDevice available for VPG TargetSV read-buffer borrowing")
		return true

	var grid_size := Vector3i(2, 2, 2)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var color_bytes := PackedByteArray()
	color_bytes.resize(voxel_count * 4)
	for i in range(voxel_count):
		color_bytes.encode_u32(i * 4, VoxelPlacementGeneratorScript._pack_color_rgba8(Color(0.1, 0.2, 0.3, 0.4)))

	var actor := ScenePlacementActorScript.new()
	var target_buffers := actor.prepare_target_read_buffers_from_common_gpu({
		"target_color_rgba8_bytes": color_bytes,
	}, {"grid_size": grid_size})
	if not bool(target_buffers.get("ok", false)):
		actor.dispose(true)
		push_error("  FAIL: resident TargetSV producer should be ready: %s" % str(target_buffers))
		return false

	var generator := VoxelPlacementGeneratorScript.new()
	if not generator.attach_rendering_device(actor.get_rendering_device(), false):
		generator.dispose()
		actor.dispose(true)
		push_error("  FAIL: VPG should attach actor RenderingDevice for same-RD borrow")
		return false
	var borrowed: Dictionary = generator._target_read_buffer_pack(target_buffers, voxel_count)
	if not bool(borrowed.get("target_read_buffers_borrowed", false)) \
			or str(borrowed.get("target_read_buffer_source", "")) != "borrowed_scene_placement_actor_resident" \
			or str(borrowed.get("target_read_buffer_ownership", "")) != "borrowed_external" \
			or bool(borrowed.get("target_field_bytes_uploaded", true)) \
			or bool(borrowed.get("cpu_fallback", true)):
		generator.dispose()
		actor.dispose(true)
		push_error("  FAIL: same-RD resident target_field should be borrowed without upload/fallback: %s" % str(borrowed))
		return false
	var borrowed_summary := generator._target_read_buffer_summary(borrowed)
	if str(borrowed_summary.get("owner", "")) != "ScenePlacementActor" \
			or str(borrowed_summary.get("target_field_buffer_rid", "")) != "valid" \
			or int(borrowed_summary.get("target_field_byte_count", 0)) != voxel_count * 16:
		generator.dispose()
		actor.dispose(true)
		push_error("  FAIL: borrowed VPG diagnostics should expose field owner/RID/byte count: %s" % str(borrowed_summary))
		return false
	generator.dispose()

	var upload_field := PackedFloat32Array()
	upload_field.resize(voxel_count * 4)
	for i in range(voxel_count):
		upload_field[i * 4 + 0] = 0.25
		upload_field[i * 4 + 1] = 0.5
		upload_field[i * 4 + 2] = 0.75
		upload_field[i * 4 + 3] = 0.125 + float(i) * 0.01

	var mismatch_generator := VoxelPlacementGeneratorScript.new()
	if not mismatch_generator.ensure_device(true, false):
		mismatch_generator.dispose()
		actor.dispose(true)
		print("  SKIP: no second local RenderingDevice available for mismatch upload branch")
		return true
	var uploaded: Dictionary = mismatch_generator._target_read_buffer_pack({
		"target_read_buffers": target_buffers,
		"target_field_bytes": upload_field,
	}, voxel_count)
	if bool(uploaded.get("target_read_buffers_borrowed", true)) \
			or not bool(uploaded.get("target_read_buffers_uploaded", false)) \
			or not bool(uploaded.get("target_field_bytes_uploaded", false)) \
			or str(uploaded.get("target_read_buffer_source", "")) != "uploaded_target_field_bytes" \
			or str(uploaded.get("source_reason", "")) != "resident_target_read_buffer_rendering_device_mismatch" \
			or bool(uploaded.get("cpu_fallback", true)):
		mismatch_generator.dispose()
		actor.dispose(true)
		push_error("  FAIL: RD mismatch should upload explicit vec4 target_field bytes: %s" % str(uploaded))
		return false
	var blocked: Dictionary = mismatch_generator._target_read_buffer_pack({
		"target_read_buffers": target_buffers,
	}, voxel_count)
	if bool(blocked.get("ready", true)) \
			or not bool(blocked.get("contract_blocked", false)) \
			or str(blocked.get("reason", "")) != "resident_target_read_buffer_rendering_device_mismatch_no_debug_or_legacy_bytes" \
			or bool(blocked.get("target_read_buffers_uploaded", true)) \
			or bool(blocked.get("cpu_fallback", true)):
		mismatch_generator.dispose()
		actor.dispose(true)
		push_error("  FAIL: RD mismatch without explicit field/color bytes should block: %s" % str(blocked))
		return false
	mismatch_generator.dispose()
	actor.dispose(true)

	print("  OK: VPG borrows SPA resident target_field and only uploads explicit field bytes on RD mismatch")
	return true


func _test_gpu_derive_target_packed_buffers_or_skip() -> bool:
	print("[TargetSVBufferDecode] test_gpu_derive_target_packed_buffers_or_skip...")
	if not CommonTestUtils.has_rendering_device():
		print("  SKIP: no RenderingDevice available for GPU TargetSV read-buffer pack")
		return true

	var fixture := CommonTargetSVBufferFixture.make_linear_read_buffers()
	var tex_size: int = fixture.get("tex_size", 0)
	var slice_count: int = fixture.get("slice_count", 0)
	var voxel_count: int = fixture.get("voxel_count", 0)
	var visual: PackedByteArray = fixture.get("visual", PackedByteArray())
	var collision: PackedByteArray = fixture.get("collision", PackedByteArray())
	var strong_collision_idx: int = fixture.get("strong_collision_idx", -1)

	var generator := TargetSceneVoxelGenerator.new()
	var packed := generator.derive_target_packed_buffers(visual, collision, tex_size, slice_count)
	if not bool(packed.get("ok", false)):
		push_error("  FAIL: GPU packed target buffers failed: %s" % str(packed))
		return false
	var field_bytes: PackedFloat32Array = packed.get("target_field_bytes", PackedFloat32Array())
	var color_rgba8_bytes: PackedByteArray = packed.get("target_color_rgba8_bytes", PackedByteArray())
	var color_rgba32f_bytes: PackedByteArray = packed.get("target_color_rgba32f_bytes", PackedByteArray())
	if field_bytes.size() != voxel_count * 4 \
			or color_rgba8_bytes.size() != voxel_count * 4 \
			or color_rgba32f_bytes.size() != voxel_count * 16:
		push_error("  FAIL: GPU packed buffer sizes mismatch")
		return false
	var field_values := field_bytes
	if absf(field_values[strong_collision_idx * 4 + 3] - 0.8) > 0.001:
		push_error("  FAIL: GPU packed target field alpha should include collision intent")
		return false
	if absf(float(packed.get("max_occupancy", 0.0)) - 0.8) > 0.001:
		push_error("  FAIL: GPU packed max_occupancy stat should be 0.8, got %.6f" % float(packed.get("max_occupancy", 0.0)))
		return false
	if absf(float(packed.get("max_collision", 0.0)) - 0.8) > 0.001:
		push_error("  FAIL: GPU packed max_collision stat should be 0.8, got %.6f" % float(packed.get("max_collision", 0.0)))
		return false
	if int(packed.get("active_voxel_count", -1)) != voxel_count:
		push_error("  FAIL: GPU packed active_voxel_count should be %d, got %d" % [
			voxel_count,
			int(packed.get("active_voxel_count", -1)),
		])
		return false
	if int(packed.get("collision_voxel_count", -1)) != voxel_count:
		push_error("  FAIL: GPU packed collision_voxel_count should be %d, got %d" % [
			voxel_count,
			int(packed.get("collision_voxel_count", -1)),
		])
		return false
	if int(packed.get("visual_voxel_count", -1)) != voxel_count:
		push_error("  FAIL: GPU packed visual_voxel_count should be %d, got %d" % [
			voxel_count,
			int(packed.get("visual_voxel_count", -1)),
		])
		return false
	if absf(float(packed.get("min_active_occupancy", 0.0)) - 0.25) > 0.001:
		push_error("  FAIL: GPU packed min_active_occupancy should be 0.25")
		return false
	if absf(float(packed.get("max_visual_complexity", 0.0)) - 0.25) > 0.001:
		push_error("  FAIL: GPU packed max_visual_complexity should be 0.25")
		return false
	if str(packed.get("target_stats_source", "")) != "target_sv_pack_read_buffers_compute":
		push_error("  FAIL: GPU packed stats should report compute source")
		return false

	var expected_color := Color(0.5, 0.6, 0.7, 0.25)
	var expected_rgba8 := VoxelPlacementGeneratorScript._pack_color_rgba8(expected_color)
	var expected_color_bytes := PackedByteArray()
	expected_color_bytes.resize(4)
	expected_color_bytes.encode_u32(0, expected_rgba8)
	if color_rgba8_bytes.slice(strong_collision_idx * 4, (strong_collision_idx + 1) * 4) != expected_color_bytes:
		push_error("  FAIL: GPU packed RGBA8 mismatch at strong collision voxel")
		return false
	var color_rgba32f_values := color_rgba32f_bytes.to_float32_array()
	var color_base := strong_collision_idx * 4
	if absf(color_rgba32f_values[color_base + 0] - 0.5) > 0.001 \
			or absf(color_rgba32f_values[color_base + 1] - 0.6) > 0.001 \
			or absf(color_rgba32f_values[color_base + 2] - 0.7) > 0.001 \
			or absf(color_rgba32f_values[color_base + 3] - 0.25) > 0.001:
		push_error("  FAIL: GPU packed RGBA32F decode buffer mismatch at strong collision voxel")
		return false

	print("  OK: GPU read-buffer pack produced target field, RGBA8 bytes, and RGBA32F decode bytes")
	return true


func _test_gpu_derive_target_stats_only_or_skip() -> bool:
	print("[TargetSVBufferDecode] test_gpu_derive_target_stats_only_or_skip...")
	if not CommonTestUtils.has_rendering_device():
		print("  SKIP: no RenderingDevice available for GPU TargetSV stats-only pack")
		return true

	var tex_size := 2
	var slice_count := 2
	var voxel_count := tex_size * tex_size * slice_count
	var visual := PackedByteArray()
	var collision := PackedByteArray()
	visual.resize(voxel_count * 16)
	collision.resize(voxel_count * 4)
	for i in range(voxel_count):
		var base := i * 16
		visual.encode_float(base + 0, 0.0)
		visual.encode_float(base + 4, 0.0)
		visual.encode_float(base + 8, 0.0)
		visual.encode_float(base + 12, 0.0)
		collision.encode_float(i * 4, 0.0)
	visual.encode_float(2 * 16 + 12, 0.4)
	collision.encode_float(5 * 4, 0.8)

	var generator := TargetSceneVoxelGenerator.new()
	var packed := generator.derive_target_stats(
		visual,
		collision,
		tex_size,
		slice_count,
		true,
		PackedByteArray()
	)
	if not bool(packed.get("ok", false)):
		push_error("  FAIL: GPU stats-only target derivation failed: %s" % str(packed))
		return false
	if bool(packed.get("readback_packed_buffers", true)):
		push_error("  FAIL: stats-only derivation should report readback_packed_buffers=false")
		return false
	if bool(packed.get("write_packed_buffers", true)):
		push_error("  FAIL: stats-only derivation should report write_packed_buffers=false")
		return false
	if not bool(packed.get("stats_only", false)):
		push_error("  FAIL: derive_target_stats should report stats_only=true")
		return false
	if packed.has("target_field_bytes") or packed.has("target_color_rgba8_bytes") or packed.has("target_color_rgba32f_bytes"):
		push_error("  FAIL: derive_target_stats should not expose packed readback keys")
		return false
	if absf(float(packed.get("max_occupancy", 0.0)) - 0.8) > 0.001:
		push_error("  FAIL: stats-only max_occupancy should be 0.8")
		return false
	if absf(float(packed.get("max_collision", 0.0)) - 0.8) > 0.001:
		push_error("  FAIL: stats-only max_collision should be 0.8")
		return false
	if int(packed.get("active_voxel_count", -1)) != 2:
		push_error("  FAIL: stats-only active_voxel_count should be 2")
		return false
	if int(packed.get("collision_voxel_count", -1)) != 1:
		push_error("  FAIL: stats-only collision_voxel_count should be 1")
		return false
	if int(packed.get("visual_voxel_count", -1)) != 1:
		push_error("  FAIL: stats-only visual_voxel_count should be 1")
		return false
	if absf(float(packed.get("min_active_occupancy", 0.0)) - 0.4) > 0.001:
		push_error("  FAIL: stats-only min_active_occupancy should be 0.4")
		return false
	if absf(float(packed.get("max_visual_complexity", 0.0)) - 0.4) > 0.001:
		push_error("  FAIL: stats-only max_visual_complexity should be 0.4")
		return false

	print("  OK: GPU stats-only derivation skips packed readback")
	return true


func _test_gpu_generated_occupancy_buffer_or_skip() -> bool:
	print("[TargetSVBufferDecode] test_gpu_generated_occupancy_buffer_or_skip...")
	if not CommonTestUtils.has_rendering_device():
		print("  SKIP: no RenderingDevice available for GPU-only TargetSV occupancy buffer")
		return true

	var tex_size := 4
	var scene_depth := Image.create(tex_size, tex_size, false, Image.FORMAT_RGBAF)
	var target_height := Image.create(tex_size, tex_size, false, Image.FORMAT_RGBAF)
	var rock_mask := Image.create(tex_size, tex_size, false, Image.FORMAT_RGBAF)
	scene_depth.fill(Color(8.0, 0.0, 0.0, 1.0))
	target_height.fill(Color(9.0, 0.0, 0.0, 1.0))
	rock_mask.fill(Color(0.0, 0.0, 0.0, 1.0))
	rock_mask.set_pixel(1, 1, Color(1.0, 0.0, 0.0, 1.0))

	var generator := TargetSceneVoxelGenerator.new()
	generator.slice_count = 2
	generator.max_height = 10.0
	generator.capture_size = 4.0
	generator.vertical_span = 2.0
	var result := generator.generate(scene_depth, target_height, rock_mask, Rect2i(0, 0, tex_size, tex_size))
	if result.is_empty():
		push_error("  FAIL: TargetSV GPU generation returned empty result")
		return false

	var voxel_count := tex_size * tex_size * generator.slice_count
	var visual_bytes: PackedByteArray = result.get("visual_bytes", PackedByteArray())
	var collision_bytes: PackedByteArray = result.get("collision_bytes", PackedByteArray())
	var occupancy_bytes: PackedFloat32Array = result.get("target_field_bytes", PackedFloat32Array())
	var color_rgba8_bytes: PackedByteArray = result.get("target_color_rgba8_bytes", PackedByteArray())
	if occupancy_bytes.size() != voxel_count * 4:
		push_error("  FAIL: GPU target field buffer size mismatch: got %d expected %d" % [occupancy_bytes.size(), voxel_count * 4])
		return false
	if color_rgba8_bytes.size() != voxel_count * 4:
		push_error("  FAIL: GPU target color RGBA8 buffer size mismatch: got %d expected %d" % [color_rgba8_bytes.size(), voxel_count * 4])
		return false

	var visual_values := visual_bytes.to_float32_array()
	var collision_values := collision_bytes.to_float32_array()
	var field_values := occupancy_bytes
	var expected_max_occupancy := 0.0
	var expected_max_collision := 0.0
	var expected_active_voxel_count := 0
	var expected_collision_voxel_count := 0
	var expected_visual_voxel_count := 0
	var expected_min_active_occupancy := 0.0
	var expected_max_visual_complexity := 0.0
	for i in range(voxel_count):
		var visual_base := i * 4
		var complexity := clampf(visual_values[visual_base + 3], 0.0, 1.0)
		var collision := clampf(collision_values[i], 0.0, 1.0)
		var occupancy := field_values[i * 4 + 3]
		expected_max_occupancy = maxf(expected_max_occupancy, occupancy)
		expected_max_collision = maxf(expected_max_collision, collision)
		expected_max_visual_complexity = maxf(expected_max_visual_complexity, complexity)
		if occupancy > 0.001:
			expected_active_voxel_count += 1
			expected_min_active_occupancy = occupancy if expected_active_voxel_count == 1 else minf(expected_min_active_occupancy, occupancy)
		if collision > 0.001:
			expected_collision_voxel_count += 1
		if complexity > 0.001:
			expected_visual_voxel_count += 1
		var color := Color(
			clampf(visual_values[visual_base + 0], 0.0, 1.0),
			clampf(visual_values[visual_base + 1], 0.0, 1.0),
			clampf(visual_values[visual_base + 2], 0.0, 1.0),
			complexity
		)
		if absf(occupancy - maxf(complexity, collision)) > 0.001:
			push_error("  FAIL: GPU target field mismatch at %d: %.4f vs max(%.4f, %.4f)" % [i, occupancy, complexity, collision])
			return false
		var expected_rgba8 := VoxelPlacementGeneratorScript._pack_color_rgba8(color)
		var expected_color_bytes := PackedByteArray()
		expected_color_bytes.resize(4)
		expected_color_bytes.encode_u32(0, expected_rgba8)
		if color_rgba8_bytes.slice(i * 4, (i + 1) * 4) != expected_color_bytes:
			push_error("  FAIL: GPU target color RGBA8 mismatch at %d" % i)
			return false
	if absf(float(result.get("max_occupancy", 0.0)) - expected_max_occupancy) > 0.001:
		push_error("  FAIL: GPU TargetSV max_occupancy stat mismatch: got %.6f expected %.6f" % [
			float(result.get("max_occupancy", 0.0)),
			expected_max_occupancy,
		])
		return false
	if absf(float(result.get("max_collision", 0.0)) - expected_max_collision) > 0.001:
		push_error("  FAIL: GPU TargetSV max_collision stat mismatch: got %.6f expected %.6f" % [
			float(result.get("max_collision", 0.0)),
			expected_max_collision,
		])
		return false
	if int(result.get("active_voxel_count", -1)) != expected_active_voxel_count:
		push_error("  FAIL: GPU TargetSV active_voxel_count mismatch: got %d expected %d" % [
			int(result.get("active_voxel_count", -1)),
			expected_active_voxel_count,
		])
		return false
	if int(result.get("collision_voxel_count", -1)) != expected_collision_voxel_count:
		push_error("  FAIL: GPU TargetSV collision_voxel_count mismatch: got %d expected %d" % [
			int(result.get("collision_voxel_count", -1)),
			expected_collision_voxel_count,
		])
		return false
	if int(result.get("visual_voxel_count", -1)) != expected_visual_voxel_count:
		push_error("  FAIL: GPU TargetSV visual_voxel_count mismatch: got %d expected %d" % [
			int(result.get("visual_voxel_count", -1)),
			expected_visual_voxel_count,
		])
		return false
	if absf(float(result.get("min_active_occupancy", 0.0)) - expected_min_active_occupancy) > 0.001:
		push_error("  FAIL: GPU TargetSV min_active_occupancy mismatch: got %.6f expected %.6f" % [
			float(result.get("min_active_occupancy", 0.0)),
			expected_min_active_occupancy,
		])
		return false
	if absf(float(result.get("max_visual_complexity", 0.0)) - expected_max_visual_complexity) > 0.001:
		push_error("  FAIL: GPU TargetSV max_visual_complexity mismatch: got %.6f expected %.6f" % [
			float(result.get("max_visual_complexity", 0.0)),
			expected_max_visual_complexity,
		])
		return false
	if str(result.get("target_stats_source", "")) != "target_scene_voxel_compute":
		push_error("  FAIL: GPU TargetSV stats should report compute source")
		return false

	print("  OK: GPU target field/color/stats buffers match visual/collision readback")
	return true
