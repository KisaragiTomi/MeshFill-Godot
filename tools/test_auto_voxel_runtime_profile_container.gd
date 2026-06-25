extends SceneTree

const RuntimeProfileContainerScript := preload("res://scripts/auto_voxel_runtime_profile_container.gd")
const CommonAutoVoxelFixture := preload("res://scripts/common_auto_voxel_fixture.gd")


func _init() -> void:
	var ok := true
	ok = ok and _test_descriptor_registration_stages_profile_data()
	ok = ok and _test_gpu_upload_readback_or_skip()
	ok = ok and _test_dispose_sync_guard_respects_borrowed_device_or_skip()
	ok = ok and _test_readback_byte_count_validation_contract()
	ok = ok and _test_equivalent_descriptors_reuse_profile_id()
	ok = ok and _test_profile_registration_is_stable()
	ok = ok and _test_dirty_profile_marking()
	ok = ok and _test_container_stays_gpu_profile_control_plane()
	ok = ok and _test_descriptor_profile_id_and_probe_range_lookup()

	if ok:
		print("[AutoVoxelRuntimeProfileContainer] ALL TESTS PASSED")
		quit(0)
	else:
		push_error("[AutoVoxelRuntimeProfileContainer] SOME TESTS FAILED")
		quit(1)


func _test_descriptor_registration_stages_profile_data() -> bool:
	print("[AutoVoxelRuntimeProfileContainer] test_descriptor_registration_stages_profile_data...")
	var descriptor := CommonAutoVoxelFixture.make_runtime_profile_descriptor()
	var container = RuntimeProfileContainerScript.new()
	var profile_id: int = container.register_descriptor(descriptor, 0.25)
	if profile_id <= 0:
		push_error("  FAIL: expected positive profile_id")
		return false
	if container.get_profile_count() != 1:
		push_error("  FAIL: expected one registered profile")
		return false

	var table: Array = container.export_profile_table()
	if table.size() != 1:
		push_error("  FAIL: expected one profile table entry")
		return false
	var entry: Dictionary = table[0]
	if int(entry.get("profile_id", -1)) != profile_id:
		push_error("  FAIL: profile table entry id mismatch")
		return false
	var legacy_residency_key := "gpu_" + "resident"
	if entry.has(legacy_residency_key):
		push_error("  FAIL: staging table must not carry legacy residency marker")
		return false
	if container.is_runtime_ready():
		push_error("  FAIL: registration alone must not mark runtime ready before GPU upload")
		return false
	var summary: Dictionary = container.get_gpu_buffer_summary()
	if bool(summary.get("runtime_ready", true)):
		push_error("  FAIL: GPU summary should not be runtime ready before upload")
		return false
	if bool(summary.get("cpu_fallback", true)):
		push_error("  FAIL: staged profile summary must report cpu_fallback=false")
		return false
	if str(summary.get("runtime_read_source", "")) != "none":
		push_error("  FAIL: staged profile summary must not expose a runtime read source")
		return false
	if str(summary.get("read_source", "")) != "gpu_buffers":
		push_error("  FAIL: runtime read source should be named gpu_buffers")
		return false

	var probe_ranges: Array = container.export_probe_ranges()
	var pivot_ranges: Array = container.export_pivot_ranges()
	if probe_ranges.size() != 1 or int((probe_ranges[0] as Dictionary).get("count", 0)) != 1:
		push_error("  FAIL: expected one probe range with one probe")
		return false
	if pivot_ranges.size() != 1 or int((pivot_ranges[0] as Dictionary).get("count", 0)) != 1:
		push_error("  FAIL: expected one pivot range with one pivot")
		return false

	var snapshot: Dictionary = container.readback_debug_snapshot()
	if bool(snapshot.get("runtime_ready", true)):
		push_error("  FAIL: readback snapshot before upload must not claim runtime ready")
		return false
	if bool(snapshot.get("readback_snapshot", true)):
		push_error("  FAIL: readback snapshot before upload must not claim GPU readback")
		return false
	if not container.descriptor_hash_to_profile_id.has(entry.get("profile_hash", "")):
		push_error("  FAIL: expected descriptor hash to profile id staging mapping")
		return false
	print("  OK: staged profile_id=%d hash=%s" % [profile_id, str(entry.get("profile_hash", ""))])
	container.dispose()
	return true


func _test_gpu_upload_readback_or_skip() -> bool:
	print("[AutoVoxelRuntimeProfileContainer] test_gpu_upload_readback_or_skip...")
	var descriptor := CommonAutoVoxelFixture.make_runtime_profile_descriptor()
	var container = RuntimeProfileContainerScript.new()
	var profile_id: int = container.register_descriptor(descriptor, 0.25)
	if profile_id <= 0:
		push_error("  FAIL: expected positive profile_id")
		return false

	if not container.ensure_device():
		if container.upload_profiles():
			container.dispose()
			push_error("  FAIL: upload_profiles must not succeed without RenderingDevice")
			return false
		if container.is_runtime_ready():
			container.dispose()
			push_error("  FAIL: runtime must not be ready without RenderingDevice")
			return false
		print("  SKIP: no RenderingDevice available for GPU-only profile upload")
		return true

	if not container.upload_profiles():
		container.dispose(true)
		push_error("  FAIL: upload_profiles should create storage buffers when RenderingDevice exists")
		return false
	if not container.is_runtime_ready():
		container.dispose(true)
		push_error("  FAIL: container should be runtime ready after successful GPU upload")
		return false

	var summary: Dictionary = container.get_gpu_buffer_summary()
	var buffers: Dictionary = summary.get("buffers", {})
	var expected_counts := {
		RuntimeProfileContainerScript.PROFILE_TABLE_BUFFER: 1,
		RuntimeProfileContainerScript.PROBE_RECORD_BUFFER: 1,
		RuntimeProfileContainerScript.PIVOT_RECORD_BUFFER: 1,
		RuntimeProfileContainerScript.COLLISION_RECORD_BUFFER: 0,
	}
	for buffer_name in expected_counts.keys():
		var buffer_summary: Dictionary = buffers.get(buffer_name, {})
		if not bool(buffer_summary.get("rid_valid", false)):
			container.dispose(true)
			push_error("  FAIL: expected valid RID for %s" % buffer_name)
			return false
		if int(buffer_summary.get("record_count", -1)) != int(expected_counts[buffer_name]):
			container.dispose(true)
			push_error("  FAIL: expected %s record_count=%d, got %d" % [
				buffer_name,
				int(expected_counts[buffer_name]),
				int(buffer_summary.get("record_count", -1)),
			])
			return false

	var snapshot: Dictionary = container.readback_debug_snapshot()
	if not bool(snapshot.get("runtime_ready", false)):
		container.dispose(true)
		push_error("  FAIL: readback snapshot should report GPU runtime ready")
		return false
	if not bool(snapshot.get("readback_snapshot", false)):
		container.dispose(true)
		push_error("  FAIL: readback snapshot should report GPU readback after upload")
		return false
	if bool(snapshot.get("cpu_fallback", true)):
		container.dispose(true)
		push_error("  FAIL: uploaded profile snapshot must report cpu_fallback=false")
		return false
	var readback_validation: Dictionary = snapshot.get("readback_validation", {})
	if not bool(readback_validation.get("ok", false)):
		container.dispose(true)
		push_error("  FAIL: readback validation should confirm byte counts: %s" % str(readback_validation))
		return false
	var profile_bytes: PackedByteArray = snapshot.get("profile_table_bytes", PackedByteArray())
	var probe_bytes: PackedByteArray = snapshot.get("probe_record_bytes", PackedByteArray())
	var pivot_bytes: PackedByteArray = snapshot.get("pivot_record_bytes", PackedByteArray())
	var collision_bytes: PackedByteArray = snapshot.get("collision_record_bytes", PackedByteArray())
	if profile_bytes.size() != RuntimeProfileContainerScript.PROFILE_TABLE_STRIDE_BYTES:
		container.dispose(true)
		push_error("  FAIL: profile table byte size mismatch")
		return false
	if probe_bytes.size() != RuntimeProfileContainerScript.PROBE_RECORD_STRIDE_BYTES:
		container.dispose(true)
		push_error("  FAIL: probe byte size mismatch")
		return false
	if not snapshot.has("collision_record_bytes"):
		container.dispose(true)
		push_error("  FAIL: snapshot must include collision_record_bytes for GPU-resident collision buffer")
		return false
	if collision_bytes.size() != 0:
		container.dispose(true)
		push_error("  FAIL: GPU collision record byte size mismatch (expected 0-byte empty buffer, got %d)" % collision_bytes.size())
		return false
	if pivot_bytes.size() != RuntimeProfileContainerScript.PIVOT_RECORD_STRIDE_BYTES:
		container.dispose(true)
		push_error("  FAIL: pivot byte size mismatch")
		return false

	var profile_words := profile_bytes.to_int32_array()
	var profile_values := profile_bytes.to_float32_array()
	var probe_values := probe_bytes.to_float32_array()
	var pivot_values := pivot_bytes.to_float32_array()
	var read_profile_id := profile_words[0] if profile_words[0] >= 0 else profile_words[0] + 4294967296
	if int(read_profile_id) != profile_id:
		container.dispose(true)
		push_error("  FAIL: GPU profile table profile_id readback mismatch")
		return false
	if int(profile_words[2]) != 0 or int(profile_words[3]) != 1:
		container.dispose(true)
		push_error("  FAIL: GPU profile table probe range readback mismatch")
		return false
	if int(profile_words[4]) != 0 or int(profile_words[5]) != 0:
		container.dispose(true)
		push_error("  FAIL: GPU profile table collision range should be 0/0 for empty collision")
		return false
	if not (absf(profile_values[8] - 0.2) <= 0.001) or not (absf(profile_values[11] - 0.5) <= 0.001):
		container.dispose(true)
		push_error("  FAIL: GPU profile table color/complexity readback mismatch")
		return false
	if not (absf(probe_values[0] - 0.25) <= 0.001) or not (absf(probe_values[5] - 0.3) <= 0.001):
		container.dispose(true)
		push_error("  FAIL: GPU probe record readback mismatch")
		return false
	if not (absf(pivot_values[1] - -0.25) <= 0.001) or not (absf(pivot_values[3] - 0.1) <= 0.001):
		container.dispose(true)
		push_error("  FAIL: GPU pivot record readback mismatch")
		return false

	print("  OK: uploaded profile_id=%d bytes profile/probe/pivot=%d/%d/%d" % [
		profile_id,
		profile_bytes.size(),
		probe_bytes.size(),
		pivot_bytes.size(),
	])
	container.dispose(true)
	return true


func _test_dispose_sync_guard_respects_borrowed_device_or_skip() -> bool:
	print("[AutoVoxelRuntimeProfileContainer] test_dispose_sync_guard_respects_borrowed_device_or_skip...")
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		print("  SKIP: no RenderingDevice available for borrowed dispose sync guard")
		return true
	var container = RuntimeProfileContainerScript.new()
	if not container.attach_rendering_device(rd, false):
		rd.free()
		push_error("  FAIL: container should attach borrowed RenderingDevice")
		return false
	if container._should_sync_before_dispose(true):
		container.dispose(false)
		rd.free()
		push_error("  FAIL: borrowed RenderingDevice must not be submitted/synced by profile container dispose")
		return false
	container.dispose(true)
	var bytes := PackedByteArray()
	bytes.resize(4)
	var rid := rd.storage_buffer_create(bytes.size(), bytes)
	var rd_still_usable := rid.is_valid()
	if rid.is_valid():
		rd.free_rid(rid)
	rd.free()
	if not rd_still_usable:
		push_error("  FAIL: borrowed RenderingDevice should remain owned and usable after container dispose")
		return false
	print("  OK: borrowed RenderingDevice sync is guarded by owner state")
	return true


func _test_readback_byte_count_validation_contract() -> bool:
	print("[AutoVoxelRuntimeProfileContainer] test_readback_byte_count_validation_contract...")
	var container = RuntimeProfileContainerScript.new()
	var matching_bytes := {}
	for buffer_name in RuntimeProfileContainerScript.GPU_BUFFER_NAMES:
		container._gpu_logical_byte_sizes[buffer_name] = 0
		matching_bytes[buffer_name] = PackedByteArray()
	var matching_validation: Dictionary = container._validate_readback_byte_counts(matching_bytes)
	if not bool(matching_validation.get("ok", false)):
		push_error("  FAIL: zero-length logical buffers should validate when read back as zero bytes")
		return false

	container._gpu_logical_byte_sizes[RuntimeProfileContainerScript.PROBE_RECORD_BUFFER] = RuntimeProfileContainerScript.PROBE_RECORD_STRIDE_BYTES
	var short_probe_bytes := PackedByteArray()
	short_probe_bytes.resize(4)
	matching_bytes[RuntimeProfileContainerScript.PROBE_RECORD_BUFFER] = short_probe_bytes
	var mismatch_validation: Dictionary = container._validate_readback_byte_counts(matching_bytes)
	if bool(mismatch_validation.get("ok", true)):
		push_error("  FAIL: short probe readback must not validate")
		return false
	if str(mismatch_validation.get("reason", "")) != "readback_byte_count_mismatch":
		push_error("  FAIL: short probe readback should name byte-count mismatch")
		return false
	if bool(mismatch_validation.get("cpu_fallback", true)) or not bool(mismatch_validation.get("gpu_first", false)):
		push_error("  FAIL: readback byte-count mismatch must stay GPU-first without CPU fallback")
		return false
	var buffers: Dictionary = mismatch_validation.get("buffers", {})
	var probe_status: Dictionary = buffers.get(RuntimeProfileContainerScript.PROBE_RECORD_BUFFER, {})
	if bool(probe_status.get("ok", true)):
		push_error("  FAIL: probe buffer status should fail independently")
		return false
	if bool(probe_status.get("cpu_fallback", true)) or not bool(probe_status.get("gpu_first", false)):
		push_error("  FAIL: nested probe byte-count status must stay GPU-first without CPU fallback")
		return false
	if int(probe_status.get("expected_byte_count", -1)) != RuntimeProfileContainerScript.PROBE_RECORD_STRIDE_BYTES \
	   or int(probe_status.get("actual_byte_count", -1)) != 4:
		push_error("  FAIL: probe byte-count status should expose expected/actual sizes")
		return false
	print("  OK: debug readback snapshot now requires matching byte counts")
	return true


func _test_equivalent_descriptors_reuse_profile_id() -> bool:
	print("[AutoVoxelRuntimeProfileContainer] test_equivalent_descriptors_reuse_profile_id...")
	var container = RuntimeProfileContainerScript.new()
	var descriptor_a := CommonAutoVoxelFixture.make_runtime_profile_descriptor()
	descriptor_a.asset_id = "asset_a"
	descriptor_a.object_type = "vegetation"
	var descriptor_b := CommonAutoVoxelFixture.make_runtime_profile_descriptor()
	descriptor_b.asset_id = "asset_b"
	descriptor_b.object_type = "rock"

	var id_a: int = container.register_descriptor(descriptor_a, 0.25)
	var id_b: int = container.register_descriptor(descriptor_b, 0.25)
	if id_a != id_b:
		push_error("  FAIL: equivalent descriptor profile data should reuse profile_id (%d != %d)" % [id_a, id_b])
		return false
	if container.get_profile_count() != 1:
		push_error("  FAIL: equivalent descriptors should only add one table entry")
		return false
	print("  OK: reused profile_id=%d" % id_a)
	return true


func _test_profile_registration_is_stable() -> bool:
	print("[AutoVoxelRuntimeProfileContainer] test_profile_registration_is_stable...")
	var profile_a := CommonAutoVoxelFixture.make_runtime_profile()
	var profile_b := CommonAutoVoxelFixture.make_runtime_profile()
	var container_a = RuntimeProfileContainerScript.new()
	var container_b = RuntimeProfileContainerScript.new()
	var id_a: int = container_a.register_profile(profile_a, 0.25)
	var id_b: int = container_b.register_profile(profile_b, 0.25)
	if id_a != id_b:
		push_error("  FAIL: profile_id should be stable across containers for equivalent data")
		return false
	var second_id: int = container_a.register_profile(profile_b, 0.25)
	if second_id != id_a or container_a.get_profile_count() != 1:
		push_error("  FAIL: equivalent profiles should reuse existing profile_id")
		return false
	print("  OK: stable profile_id=%d" % id_a)
	return true


func _test_dirty_profile_marking() -> bool:
	print("[AutoVoxelRuntimeProfileContainer] test_dirty_profile_marking...")
	var descriptor := CommonAutoVoxelFixture.make_runtime_profile_descriptor()
	var container = RuntimeProfileContainerScript.new()
	var profile_id: int = container.register_descriptor(descriptor, 0.25)
	descriptor.set_color_and_complexity(Color(0.9, 0.1, 0.2, 1.0), 0.4)
	var dirty_id: int = container.mark_descriptor_dirty(descriptor, 0.25)
	if dirty_id != profile_id:
		push_error("  FAIL: mark_descriptor_dirty should mark the registered source profile")
		return false
	if not container.is_profile_dirty(profile_id):
		push_error("  FAIL: profile id should be dirty")
		return false
	var dirty_ids: Array = container.get_dirty_profile_ids()
	if dirty_ids.size() != 1 or int(dirty_ids[0]) != profile_id:
		push_error("  FAIL: get_dirty_profile_ids should expose the dirty profile handoff ids")
		return false
	dirty_ids.clear()
	if container.dirty_profile_ids.size() != 1:
		push_error("  FAIL: dirty profile id accessor should return a copy")
		return false
	container.mark_profile_dirty(profile_id)
	if container.dirty_profile_ids.size() != 1:
		push_error("  FAIL: dirty profile ids should not duplicate")
		return false
	container.clear_dirty_profiles()
	if container.is_profile_dirty(profile_id):
		push_error("  FAIL: dirty profile ids should clear")
		return false
	print("  OK: dirty profile_id=%d" % profile_id)
	return true


func _test_container_stays_gpu_profile_control_plane() -> bool:
	print("[AutoVoxelRuntimeProfileContainer] test_container_stays_gpu_profile_control_plane...")
	var container = RuntimeProfileContainerScript.new()
	var profile_id: int = container.register_normalized_profile({
		"color": Color(0.8, 0.7, 0.1, 0.9),
		"complexity": 0.35,
		"semantic_probes": [],
		"collision": [],
		"pivot_variants": [],
		"object_id": "must_not_be_staged",
		"object_transform": Transform3D.IDENTITY,
		"runtime_instances": [{"object_id": "cpu_object"}],
		"dirty_tiles": {"0:0:0": true},
		"source_type": "AutoSceneVoxel",
		"commit_tick": 99,
		"debug": {"authoritative": true},
	})
	if profile_id <= 0:
		push_error("  FAIL: expected profile registration to succeed")
		return false
	var normalized := container.get_normalized_profile_data(profile_id)
	for key in [
		"object_id",
		"object_transform",
		"runtime_instances",
		"dirty_tiles",
		"source_type",
		"source_voxel_type",
		"commit_tick",
		"debug",
	]:
		if normalized.has(key):
			push_error("  FAIL: normalized profile must not keep per-object/runtime field %s" % key)
			return false

	var table := container.export_profile_table()
	if table.size() != 1:
		push_error("  FAIL: expected exactly one profile table entry")
		return false
	var entry: Dictionary = table[0]
	for key in ["object_id", "object_transform", "runtime_instances", "dirty_tiles", "source_type", "commit_tick", "debug"]:
		if entry.has(key):
			push_error("  FAIL: profile table must not keep per-object/runtime field %s" % key)
			return false

	var summary := container.get_gpu_buffer_summary()
	if bool(summary.get("cpu_fallback", true)):
		push_error("  FAIL: profile container summary must not expose CPU fallback")
		return false
	if bool(summary.get("per_object_runtime_manager", true)):
		push_error("  FAIL: profile container must not be a per-object runtime manager")
		return false
	if bool(summary.get("owns_object_lifecycle", true)):
		push_error("  FAIL: profile container must not own object lifecycle")
		return false
	for method_name in [
		"spawn_object",
		"register_object",
		"update_object",
		"free_object",
		"get_live_count",
		"get_objects",
		"apply_object_delta",
	]:
		if container.has_method(method_name):
			push_error("  FAIL: profile container exposes CPU runtime manager method %s" % method_name)
			return false
	print("  OK: profile container remains GPU buffer/control-plane only")
	return true


func _test_descriptor_profile_id_and_probe_range_lookup() -> bool:
	print("[AutoVoxelRuntimeProfileContainer] test_descriptor_profile_id_and_probe_range_lookup...")
	var descriptor := CommonAutoVoxelFixture.make_runtime_profile_descriptor()
	var container = RuntimeProfileContainerScript.new()
	var profile_id: int = container.register_descriptor(
		descriptor,
		0.25,
		descriptor.semantic_probe_density,
		Vector3.ONE,
		null
	)
	var lookup_id: int = container.get_profile_id_for_descriptor(
		descriptor,
		0.25,
		descriptor.semantic_probe_density,
		Vector3.ONE,
		null
	)
	if lookup_id != profile_id:
		push_error("  FAIL: descriptor profile lookup should return registered profile_id (%d != %d)" % [lookup_id, profile_id])
		return false

	var probe_range: Dictionary = container.get_probe_range_for_profile_id(profile_id)
	if int(probe_range.get("profile_id", -1)) != profile_id:
		push_error("  FAIL: probe range should preserve profile_id")
		return false
	if int(probe_range.get("start", -1)) != 0 or int(probe_range.get("count", -1)) != 1 or int(probe_range.get("end", -1)) != 1:
		push_error("  FAIL: probe range should expose the profile container probe_records slice")
		return false
	probe_range["count"] = 99
	var fresh_range: Dictionary = container.get_probe_range_for_profile_id(profile_id)
	if int(fresh_range.get("count", -1)) != 1:
		push_error("  FAIL: probe range lookup should return a copy")
		return false
	if not container.get_probe_range_for_profile_id(-123).is_empty():
		push_error("  FAIL: missing profile_id should return an empty probe range")
		return false
	print("  OK: descriptor profile_id=%d probe_range=%s" % [profile_id, str(fresh_range)])
	return true
