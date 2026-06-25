class_name AutoVoxelRuntimeProfileContainer
extends RefCounted

const AssetDescriptorScript := preload("res://scripts/auto_voxel_descriptor.gd")
const AutoVoxelProfile := preload("res://scripts/auto_voxel_profile.gd")
const SemanticProbeProfileScript := preload("res://scripts/semantic_probe_profile.gd")
const SharedPropertyTypeScript := preload("res://scripts/shared_property_type.gd")

const PROFILE_TABLE_BUFFER := "profile_table"
const PROBE_RECORD_BUFFER := "probe_records"
const PIVOT_RECORD_BUFFER := "pivot_records"
const COLLISION_RECORD_BUFFER := "collision_records"
const GPU_BUFFER_NAMES := [
	PROFILE_TABLE_BUFFER,
	PROBE_RECORD_BUFFER,
	PIVOT_RECORD_BUFFER,
	COLLISION_RECORD_BUFFER,
]

const PROFILE_TABLE_STRIDE_BYTES := 64
const PROBE_RECORD_STRIDE_BYTES := 32
const PIVOT_RECORD_STRIDE_BYTES := 32
const COLLISION_RECORD_STRIDE_BYTES := 32

var descriptor_hash_to_profile_id: Dictionary = {}
var dirty_profile_ids: Array[int] = []

var _profile_hash_to_id: Dictionary = {}
var _profile_id_to_hash: Dictionary = {}
var _profile_id_to_table_entry: Dictionary = {}
var _profile_id_to_normalized_data: Dictionary = {}
var _source_key_to_profile_id: Dictionary = {}
var _profile_order: Array[int] = []
var _staging_profile_table: Array[Dictionary] = []
var _staging_probe_records: Array[Dictionary] = []
var _staging_pivot_records: Array[Dictionary] = []
var _staging_collision_records: Array[Dictionary] = []
var _staging_probe_ranges: Array[Dictionary] = []
var _staging_pivot_ranges: Array[Dictionary] = []
var _staging_collision_ranges: Array[Dictionary] = []

var _rd: RenderingDevice
var _owns_rendering_device := false
var _gpu_runtime_ready := false
var _gpu_revision := 0
var _staging_revision := 0
var _uploaded_revision := -1
var _last_upload_error := ""
var _gpu_buffers: Dictionary = {}
var _gpu_buffer_byte_sizes: Dictionary = {}
var _gpu_logical_byte_sizes: Dictionary = {}
var _gpu_record_counts: Dictionary = {}
var _gpu_strides: Dictionary = {}


func clear() -> void:
	_release_gpu_buffers()
	descriptor_hash_to_profile_id.clear()
	dirty_profile_ids.clear()
	_profile_hash_to_id.clear()
	_profile_id_to_hash.clear()
	_profile_id_to_table_entry.clear()
	_profile_id_to_normalized_data.clear()
	_source_key_to_profile_id.clear()
	_profile_order.clear()
	_staging_profile_table.clear()
	_staging_probe_records.clear()
	_staging_pivot_records.clear()
	_staging_collision_records.clear()
	_staging_probe_ranges.clear()
	_staging_pivot_ranges.clear()
	_staging_collision_ranges.clear()
	_last_upload_error = ""
	_mark_staging_changed()


func dispose(sync_before_free: bool = false) -> void:
	_submit_and_sync_before_dispose(sync_before_free)
	_release_gpu_buffers()
	if _rd != null and _owns_rendering_device:
		_rd.free()
	_rd = null
	_owns_rendering_device = false


func ensure_device(prefer_local_device: bool = true, allow_global_fallback: bool = true) -> bool:
	if _rd != null:
		return true

	if prefer_local_device:
		_rd = RenderingServer.create_local_rendering_device()
		_owns_rendering_device = _rd != null

	if _rd == null and allow_global_fallback:
		_rd = RenderingServer.get_rendering_device()
		_owns_rendering_device = false

	if _rd == null:
		_last_upload_error = "no_rendering_device"
		_gpu_runtime_ready = false
		return false

	_last_upload_error = ""
	return true


func attach_rendering_device(rendering_device: RenderingDevice, owns_device: bool = false) -> bool:
	if rendering_device == null:
		_last_upload_error = "external_rendering_device_is_null"
		return false
	if _rd != null and _rd != rendering_device:
		dispose()
	_rd = rendering_device
	_owns_rendering_device = owns_device
	_last_upload_error = ""
	return true


func get_rendering_device() -> RenderingDevice:
	return _rd


func owns_rendering_device() -> bool:
	return _owns_rendering_device


func _should_sync_before_dispose(sync_before_free: bool) -> bool:
	return sync_before_free and _rd != null and _owns_rendering_device


func _submit_and_sync_before_dispose(sync_before_free: bool) -> void:
	if not _should_sync_before_dispose(sync_before_free):
		return
	_rd.submit()
	_rd.sync()


func upload_profiles(force: bool = false) -> bool:
	if not ensure_device():
		return false
	if not force and is_runtime_ready():
		return true

	var packed_profile_table := _pack_profile_table_bytes()
	var packed_probes := _pack_probe_record_bytes()
	var packed_pivots := _pack_pivot_record_bytes()
	var packed_collisions := _pack_collision_record_bytes()

	_release_gpu_buffers()
	var ok := true
	ok = ok and _create_storage_buffer(
		PROFILE_TABLE_BUFFER,
		packed_profile_table,
		_staging_profile_table.size(),
		PROFILE_TABLE_STRIDE_BYTES
	)
	ok = ok and _create_storage_buffer(
		PROBE_RECORD_BUFFER,
		packed_probes,
		_staging_probe_records.size(),
		PROBE_RECORD_STRIDE_BYTES
	)
	ok = ok and _create_storage_buffer(
		PIVOT_RECORD_BUFFER,
		packed_pivots,
		_staging_pivot_records.size(),
		PIVOT_RECORD_STRIDE_BYTES
	)
	ok = ok and _create_storage_buffer(
		COLLISION_RECORD_BUFFER,
		packed_collisions,
		_staging_collision_records.size(),
		COLLISION_RECORD_STRIDE_BYTES
	)

	if not ok:
		_release_gpu_buffers()
		_gpu_runtime_ready = false
		return false

	_gpu_runtime_ready = true
	_uploaded_revision = _staging_revision
	_gpu_revision += 1
	_last_upload_error = ""
	clear_dirty_profiles()
	return true


func is_runtime_ready() -> bool:
	if _rd == null or not _gpu_runtime_ready:
		return false
	if _uploaded_revision != _staging_revision:
		return false
	if not dirty_profile_ids.is_empty():
		return false
	for buffer_name in GPU_BUFFER_NAMES:
		var rid: RID = _gpu_buffers.get(buffer_name, RID())
		if not rid.is_valid():
			return false
	return true


func get_gpu_buffer(buffer_name: String) -> RID:
	return _gpu_buffers.get(buffer_name, RID())


func get_profile_table_buffer() -> RID:
	return get_gpu_buffer(PROFILE_TABLE_BUFFER)


func get_probe_buffer() -> RID:
	return get_gpu_buffer(PROBE_RECORD_BUFFER)


func get_pivot_buffer() -> RID:
	return get_gpu_buffer(PIVOT_RECORD_BUFFER)


func get_collision_records_buffer() -> RID:
	return get_gpu_buffer(COLLISION_RECORD_BUFFER)


func get_gpu_buffer_summary() -> Dictionary:
	var buffers := {}
	for buffer_name in GPU_BUFFER_NAMES:
		var rid: RID = _gpu_buffers.get(buffer_name, RID())
		buffers[buffer_name] = {
			"rid_valid": rid.is_valid(),
			"record_count": int(_gpu_record_counts.get(buffer_name, 0)),
			"stride_bytes": int(_gpu_strides.get(buffer_name, _stride_for_buffer(buffer_name))),
			"logical_byte_count": int(_gpu_logical_byte_sizes.get(buffer_name, 0)),
			"gpu_byte_count": int(_gpu_buffer_byte_sizes.get(buffer_name, 0)),
		}
	return {
		"read_source": "gpu_buffers",
		"runtime_read_source": "gpu_buffers" if is_runtime_ready() else "none",
		"readback_source": "gpu_buffers" if is_runtime_ready() else "none",
		"staging_source": "descriptor_profile_staging",
		"control_plane": "runtime_profile_container",
		"runtime_payload": "gpu_profile_buffers",
		"gpu_first": true,
		"cpu_fallback": false,
		"per_object_runtime_manager": false,
		"owns_object_lifecycle": false,
		"has_rendering_device": _rd != null,
		"runtime_ready": is_runtime_ready(),
		"staging_profile_count": get_profile_count(),
		"gpu_revision": _gpu_revision,
		"staging_revision": _staging_revision,
		"uploaded_revision": _uploaded_revision,
		"last_upload_error": _last_upload_error,
		"dirty_profile_ids": dirty_profile_ids.duplicate(),
		"buffers": buffers,
	}


func readback_debug_snapshot() -> Dictionary:
	var summary := get_gpu_buffer_summary()
	if not is_runtime_ready():
		return {
			"read_source": "gpu_buffers",
			"runtime_read_source": "none",
			"readback_source": "none",
			"staging_source": "descriptor_profile_staging",
			"control_plane": "runtime_profile_container",
			"runtime_payload": "gpu_profile_buffers",
			"gpu_first": true,
			"cpu_fallback": false,
			"readback_snapshot": false,
			"per_object_runtime_manager": false,
			"owns_object_lifecycle": false,
			"runtime_ready": false,
			"staging_profile_count": get_profile_count(),
			"dirty_profile_ids": dirty_profile_ids.duplicate(),
			"gpu_buffer_summary": summary,
		}

	var buffer_bytes := {}
	for buffer_name in GPU_BUFFER_NAMES:
		buffer_bytes[buffer_name] = _readback_buffer_bytes(buffer_name)
	var readback_validation := _validate_readback_byte_counts(buffer_bytes)
	var readback_ok := bool(readback_validation.get("ok", false))
	var profile_table_bytes: PackedByteArray = buffer_bytes.get(PROFILE_TABLE_BUFFER, PackedByteArray())
	return {
		"read_source": "gpu_buffers",
		"runtime_read_source": "gpu_buffers",
		"readback_source": "gpu_buffers" if readback_ok else "none",
		"failed_readback_source": "none" if readback_ok else "gpu_buffers",
		"control_plane": "runtime_profile_container",
		"runtime_payload": "gpu_profile_buffers",
		"gpu_first": true,
		"cpu_fallback": false,
		"readback_snapshot": readback_ok,
		"readback_validation": readback_validation,
		"readback_error": "" if readback_ok else str(readback_validation.get("reason", "readback_byte_count_mismatch")),
		"per_object_runtime_manager": false,
		"owns_object_lifecycle": false,
		"runtime_ready": true,
		"profile_count": int(_gpu_record_counts.get(PROFILE_TABLE_BUFFER, 0)),
		"dirty_profile_ids": dirty_profile_ids.duplicate(),
		"gpu_buffer_summary": summary,
		"buffer_bytes": buffer_bytes,
		"profile_table_bytes": profile_table_bytes,
		"probe_record_bytes": buffer_bytes.get(PROBE_RECORD_BUFFER, PackedByteArray()),
		"pivot_record_bytes": buffer_bytes.get(PIVOT_RECORD_BUFFER, PackedByteArray()),
		"collision_record_bytes": buffer_bytes.get(COLLISION_RECORD_BUFFER, PackedByteArray()),
		"decoded_profile_table": _decode_profile_table_bytes(
			profile_table_bytes,
			int(_gpu_record_counts.get(PROFILE_TABLE_BUFFER, 0))
		),
	}


func register_descriptor(
	descriptor: Resource,
	default_radius: float = 0.0,
	density_override: float = -1.0,
	world_scale: Vector3 = Vector3.ONE,
	mesh: Mesh = null
) -> int:
	if descriptor == null:
		return -1
	var normalized := normalize_descriptor(descriptor, default_radius, density_override, world_scale, mesh)
	var profile_id := register_normalized_profile(normalized)
	var source_key := _descriptor_source_key(descriptor)
	if not source_key.is_empty() and profile_id >= 0:
		_source_key_to_profile_id[source_key] = profile_id
	return profile_id


func register_profile(profile: AutoVoxelProfile, default_radius: float = 0.0) -> int:
	if profile == null:
		return -1
	return register_normalized_profile(normalize_profile(profile, default_radius))


func register_normalized_profile(raw_profile: Dictionary) -> int:
	var normalized := _normalize_profile_record(raw_profile)
	var profile_hash := str(normalized.get("profile_hash", ""))
	if profile_hash.is_empty():
		return -1
	if _profile_hash_to_id.has(profile_hash):
		return int(_profile_hash_to_id[profile_hash])

	var profile_id := _profile_id_from_hash(profile_hash)
	var profile_index := _profile_order.size()
	var probe_range := _append_range(_staging_probe_records, normalized.get("semantic_probes", []))
	var pivot_range := _append_range(_staging_pivot_records, normalized.get("pivot_variants", []))
	var collision_range := _append_range(_staging_collision_records, normalized.get("collision", []))

	var probe_range_entry := _make_range_entry(profile_id, profile_index, probe_range)
	var pivot_range_entry := _make_range_entry(profile_id, profile_index, pivot_range)
	var collision_range_entry := _make_range_entry(profile_id, profile_index, collision_range)
	_staging_probe_ranges.append(probe_range_entry)
	_staging_pivot_ranges.append(pivot_range_entry)
	_staging_collision_ranges.append(collision_range_entry)

	var table_entry := {
		"profile_id": profile_id,
		"profile_index": profile_index,
		"profile_hash": profile_hash,
		"color": normalized.get("color", Color.WHITE),
		"complexity": float(normalized.get("complexity", 1.0)),
		"semantic_probe_density": float(normalized.get("semantic_probe_density", 1.0)),
		"context_sensing_radius": float(normalized.get("context_sensing_radius", 0.0)),
		"probe_range": probe_range_entry.duplicate(true),
		"pivot_range": pivot_range_entry.duplicate(true),
		"collision_range": collision_range_entry.duplicate(true),
		"source_kind": str(normalized.get("source_kind", "")),
		"source_path": str(normalized.get("source_path", "")),
		"asset_id": str(normalized.get("asset_id", "")),
		"object_type": str(normalized.get("object_type", "")),
	}

	_profile_hash_to_id[profile_hash] = profile_id
	descriptor_hash_to_profile_id[profile_hash] = profile_id
	_profile_id_to_hash[profile_id] = profile_hash
	_profile_id_to_table_entry[profile_id] = table_entry
	_profile_id_to_normalized_data[profile_id] = normalized
	_profile_order.append(profile_id)
	_staging_profile_table.append(table_entry)
	_mark_staging_changed()
	return profile_id


func mark_profile_dirty(profile_id: int) -> void:
	if profile_id < 0:
		return
	if dirty_profile_ids.find(profile_id) < 0:
		dirty_profile_ids.append(profile_id)
	_uploaded_revision = -1
	_gpu_runtime_ready = false


func mark_descriptor_dirty(descriptor: Resource, default_radius: float = 0.0) -> int:
	if descriptor == null:
		return -1
	var source_key := _descriptor_source_key(descriptor)
	if not source_key.is_empty() and _source_key_to_profile_id.has(source_key):
		var source_profile_id := int(_source_key_to_profile_id[source_key])
		mark_profile_dirty(source_profile_id)
		return source_profile_id
	var normalized := normalize_descriptor(descriptor, default_radius)
	var profile_hash := str(normalized.get("profile_hash", ""))
	var profile_id := int(descriptor_hash_to_profile_id.get(profile_hash, -1))
	mark_profile_dirty(profile_id)
	return profile_id


func clear_dirty_profiles() -> void:
	dirty_profile_ids.clear()


func get_dirty_profile_ids() -> Array[int]:
	var ids: Array[int] = []
	for profile_id in dirty_profile_ids:
		ids.append(profile_id)
	return ids


func is_profile_dirty(profile_id: int) -> bool:
	return dirty_profile_ids.find(profile_id) >= 0


func get_profile_count() -> int:
	return _profile_order.size()


func has_profile(profile_id: int) -> bool:
	return _profile_id_to_table_entry.has(profile_id)


func get_profile_hash(profile_id: int) -> String:
	return str(_profile_id_to_hash.get(profile_id, ""))


func get_profile_id_for_hash(profile_hash: String) -> int:
	return int(descriptor_hash_to_profile_id.get(profile_hash, -1))


func get_profile_id_for_descriptor(
	descriptor: Resource,
	default_radius: float = 0.0,
	density_override: float = -1.0,
	world_scale: Vector3 = Vector3.ONE,
	mesh: Mesh = null
) -> int:
	if descriptor == null:
		return -1
	var normalized := normalize_descriptor(descriptor, default_radius, density_override, world_scale, mesh)
	var profile_hash := str(normalized.get("profile_hash", ""))
	if profile_hash.is_empty():
		return -1
	return get_profile_id_for_hash(profile_hash)


func get_probe_range_for_profile_id(profile_id: int) -> Dictionary:
	if not _profile_id_to_table_entry.has(profile_id):
		return {}
	var entry: Dictionary = _profile_id_to_table_entry[profile_id]
	var probe_range: Dictionary = entry.get("probe_range", {})
	return probe_range.duplicate(true)


func get_normalized_profile_data(profile_id: int) -> Dictionary:
	if not _profile_id_to_normalized_data.has(profile_id):
		return {}
	return (_profile_id_to_normalized_data[profile_id] as Dictionary).duplicate(true)


func export_profile_table() -> Array[Dictionary]:
	return _duplicate_dictionary_array(_staging_profile_table)


func get_profile_table() -> Array[Dictionary]:
	return export_profile_table()


func export_probe_ranges() -> Array[Dictionary]:
	return _duplicate_dictionary_array(_staging_probe_ranges)


func get_probe_ranges() -> Array[Dictionary]:
	return export_probe_ranges()


func export_pivot_ranges() -> Array[Dictionary]:
	return _duplicate_dictionary_array(_staging_pivot_ranges)


func get_pivot_ranges() -> Array[Dictionary]:
	return export_pivot_ranges()


func export_probe_records() -> Array[Dictionary]:
	return _duplicate_dictionary_array(_staging_probe_records)


func get_probe_records() -> Array[Dictionary]:
	return export_probe_records()


func export_pivot_records() -> Array[Dictionary]:
	return _duplicate_dictionary_array(_staging_pivot_records)


func get_pivot_records() -> Array[Dictionary]:
	return export_pivot_records()


func to_debug_dictionary() -> Dictionary:
	return readback_debug_snapshot()


func _mark_staging_changed() -> void:
	_staging_revision += 1
	_uploaded_revision = -1
	_gpu_runtime_ready = false


func _release_gpu_buffers() -> void:
	if _rd != null:
		for raw_rid in _gpu_buffers.values():
			if raw_rid is RID:
				var rid := raw_rid as RID
				if rid.is_valid():
					_rd.free_rid(rid)
	_gpu_buffers.clear()
	_gpu_buffer_byte_sizes.clear()
	_gpu_logical_byte_sizes.clear()
	_gpu_record_counts.clear()
	_gpu_strides.clear()
	_gpu_runtime_ready = false
	_uploaded_revision = -1


func _create_storage_buffer(buffer_name: String, bytes: PackedByteArray, record_count: int, stride_bytes: int) -> bool:
	if _rd == null:
		_last_upload_error = "no_rendering_device"
		return false
	var upload_bytes := bytes
	var logical_size := upload_bytes.size()
	if upload_bytes.is_empty():
		upload_bytes.resize(4)
	var rid := _rd.storage_buffer_create(upload_bytes.size(), upload_bytes)
	if not rid.is_valid():
		_last_upload_error = "storage_buffer_create_failed:%s" % buffer_name
		return false
	_gpu_buffers[buffer_name] = rid
	_gpu_buffer_byte_sizes[buffer_name] = upload_bytes.size()
	_gpu_logical_byte_sizes[buffer_name] = logical_size
	_gpu_record_counts[buffer_name] = record_count
	_gpu_strides[buffer_name] = stride_bytes
	return true


func _readback_buffer_bytes(buffer_name: String) -> PackedByteArray:
	if _rd == null:
		return PackedByteArray()
	var rid: RID = _gpu_buffers.get(buffer_name, RID())
	var byte_count := int(_gpu_logical_byte_sizes.get(buffer_name, 0))
	if not rid.is_valid() or byte_count <= 0:
		return PackedByteArray()
	return _rd.buffer_get_data(rid, 0, byte_count)


func _validate_readback_byte_counts(buffer_bytes: Dictionary) -> Dictionary:
	var buffers := {}
	var all_ok := true
	for buffer_name in GPU_BUFFER_NAMES:
		var raw_bytes = buffer_bytes.get(buffer_name, PackedByteArray())
		var bytes := PackedByteArray()
		if raw_bytes is PackedByteArray:
			bytes = raw_bytes as PackedByteArray
		var expected_byte_count := int(_gpu_logical_byte_sizes.get(buffer_name, 0))
		var actual_byte_count := bytes.size()
		var buffer_ok := actual_byte_count == expected_byte_count
		if not buffer_ok:
			all_ok = false
		buffers[buffer_name] = {
			"expected_byte_count": expected_byte_count,
			"actual_byte_count": actual_byte_count,
			"ok": buffer_ok,
			"gpu_first": true,
			"cpu_fallback": false,
		}
	return {
		"ok": all_ok,
		"reason": "ok" if all_ok else "readback_byte_count_mismatch",
		"buffers": buffers,
		"gpu_first": true,
		"cpu_fallback": false,
		"readback_source": "gpu_buffers" if all_ok else "none",
	}


func _pack_profile_table_bytes() -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(_staging_profile_table.size() * PROFILE_TABLE_STRIDE_BYTES)
	for i in range(_staging_profile_table.size()):
		var entry: Dictionary = _staging_profile_table[i]
		var base := i * PROFILE_TABLE_STRIDE_BYTES
		var probe_range: Dictionary = entry.get("probe_range", {})
		var pivot_range: Dictionary = entry.get("pivot_range", {})
		var collision_range: Dictionary = entry.get("collision_range", {})
		var color := SharedPropertyTypeScript.color_from_value(entry.get("color", Color.WHITE), Color.WHITE)
		var complexity := clampf(float(entry.get("complexity", color.a)), 0.0, 1.0)
		color.a = complexity

		bytes.encode_u32(base + 0, int(entry.get("profile_id", 0)))
		bytes.encode_u32(base + 4, int(entry.get("profile_index", i)))
		bytes.encode_u32(base + 8, int(probe_range.get("start", 0)))
		bytes.encode_u32(base + 12, int(probe_range.get("count", 0)))
		bytes.encode_u32(base + 16, int(collision_range.get("start", 0)))
		bytes.encode_u32(base + 20, int(collision_range.get("count", 0)))
		bytes.encode_u32(base + 24, int(pivot_range.get("start", 0)))
		bytes.encode_u32(base + 28, int(pivot_range.get("count", 0)))
		bytes.encode_float(base + 32, color.r)
		bytes.encode_float(base + 36, color.g)
		bytes.encode_float(base + 40, color.b)
		bytes.encode_float(base + 44, complexity)
		bytes.encode_float(base + 48, float(entry.get("semantic_probe_density", 1.0)))
		bytes.encode_float(base + 52, float(entry.get("context_sensing_radius", 0.0)))
		bytes.encode_u32(base + 56, _hex_to_u32(str(entry.get("profile_hash", ""))))
		bytes.encode_u32(base + 60, 0)
	return bytes


func _pack_probe_record_bytes() -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(_staging_probe_records.size() * PROBE_RECORD_STRIDE_BYTES)
	for i in range(_staging_probe_records.size()):
		var probe: Dictionary = _staging_probe_records[i]
		var offset := _vector3_from_value(probe.get("offset", Vector3.ZERO), Vector3.ZERO)
		var weight := maxf(float(probe.get("weight", 1.0)), 0.0)
		var rgba8 := _shader_rgba8_from_probe(probe)
		var expected_collision := clampf(float(probe.get("expected_collision", 0.0)), 0.0, 1.0)
		var wc := _probe_metric_weights(probe)

		var base := i * PROBE_RECORD_STRIDE_BYTES
		bytes.encode_float(base + 0, offset.x)
		bytes.encode_float(base + 4, offset.y)
		bytes.encode_float(base + 8, offset.z)
		bytes.encode_float(base + 12, wc.z)       # w_collision
		bytes.encode_u32(base + 16, rgba8)
		bytes.encode_float(base + 20, expected_collision)
		bytes.encode_float(base + 24, wc.x)       # w_color
		bytes.encode_float(base + 28, wc.y)       # w_complexity
	return bytes


func _pack_pivot_record_bytes() -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(_staging_pivot_records.size() * PIVOT_RECORD_STRIDE_BYTES)
	for i in range(_staging_pivot_records.size()):
		var pivot: Dictionary = _staging_pivot_records[i]
		var offset := _vector3_from_value(pivot.get("offset", Vector3.ZERO), Vector3.ZERO)
		var base := i * PIVOT_RECORD_STRIDE_BYTES
		bytes.encode_float(base + 0, offset.x)
		bytes.encode_float(base + 4, offset.y)
		bytes.encode_float(base + 8, offset.z)
		bytes.encode_float(base + 12, float(pivot.get("score_bias", 0.0)))
		bytes.encode_u32(base + 16, _stable_u32_hash(str(pivot.get("name", ""))))
		bytes.encode_u32(base + 20, 0)
		bytes.encode_u32(base + 24, 0)
		bytes.encode_u32(base + 28, 0)
	return bytes


func _pack_collision_record_bytes() -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(_staging_collision_records.size() * COLLISION_RECORD_STRIDE_BYTES)
	for i in range(_staging_collision_records.size()):
		var entry: Dictionary = _staging_collision_records[i]
		var center := _vector3_from_value(entry.get("offset", entry.get("center", entry.get("position", Vector3.ZERO))), Vector3.ZERO)
		var shape := str(entry.get("shape", "cylinder"))
		var kind := 0
		if shape == "cylinder":
			kind = 1
		elif shape == "box":
			kind = 2
		var radius := maxf(float(entry.get("radius", 1.0)), 0.01)
		var y_min := float(entry.get("y_min", 0.0))
		var y_max := maxf(float(entry.get("y_max", 2.0)), y_min + 0.01)
		var strength := clampf(float(entry.get("collision_strength", 1.0)), 0.0, 1.0)

		var base := i * COLLISION_RECORD_STRIDE_BYTES
		bytes.encode_float(base + 0, center.x)
		bytes.encode_float(base + 4, center.y)
		bytes.encode_float(base + 8, center.z)
		bytes.encode_u32(base + 12, kind)
		bytes.encode_float(base + 16, radius)
		bytes.encode_float(base + 20, y_min)
		bytes.encode_float(base + 24, y_max)
		bytes.encode_float(base + 28, strength)
	return bytes


func _decode_profile_table_bytes(bytes: PackedByteArray, record_count: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var byte_stride := PROFILE_TABLE_STRIDE_BYTES
	var available_bytes := mini(bytes.size(), record_count * byte_stride)
	available_bytes -= available_bytes % byte_stride
	var available := mini(record_count, int(available_bytes / byte_stride))
	for i in range(available):
		var base := i * byte_stride
		result.append({
			"profile_id": int(bytes.decode_u32(base + 0)),
			"profile_index": int(bytes.decode_u32(base + 4)),
			"probe_start": int(bytes.decode_u32(base + 8)),
			"probe_count": int(bytes.decode_u32(base + 12)),
			"collision_start": int(bytes.decode_u32(base + 16)),
			"collision_count": int(bytes.decode_u32(base + 20)),
			"pivot_start": int(bytes.decode_u32(base + 24)),
			"pivot_count": int(bytes.decode_u32(base + 28)),
			"color": Color(
				bytes.decode_float(base + 32),
				bytes.decode_float(base + 36),
				bytes.decode_float(base + 40),
				bytes.decode_float(base + 44)
			),
			"semantic_probe_density": bytes.decode_float(base + 48),
			"context_sensing_radius": bytes.decode_float(base + 52),
			"profile_hash_u32": int(bytes.decode_u32(base + 56)),
		})
	return result


func _stride_for_buffer(buffer_name: String) -> int:
	match buffer_name:
		PROFILE_TABLE_BUFFER:
			return PROFILE_TABLE_STRIDE_BYTES
		PROBE_RECORD_BUFFER:
			return PROBE_RECORD_STRIDE_BYTES
		PIVOT_RECORD_BUFFER:
			return PIVOT_RECORD_STRIDE_BYTES
		COLLISION_RECORD_BUFFER:
			return COLLISION_RECORD_STRIDE_BYTES
		_:
			return 0


static func _vector3_from_value(value, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	if value is Vector3:
		return value as Vector3
	if value is Vector3i:
		var vi := value as Vector3i
		return Vector3(float(vi.x), float(vi.y), float(vi.z))
	if value is Array:
		var arr := value as Array
		if arr.size() >= 3:
			return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
	if value is Dictionary:
		var dict := value as Dictionary
		return Vector3(
			float(dict.get("x", fallback.x)),
			float(dict.get("y", fallback.y)),
			float(dict.get("z", fallback.z))
		)
	return fallback


static func _shader_rgba8_from_probe(probe: Dictionary) -> int:
	if probe.has("expected_color") or probe.has("color"):
		var color := SemanticProbeProfileScript.color_from_value(probe.get("expected_color", probe.get("color", Color.WHITE)), Color.WHITE)
		color.a = clampf(float(probe.get("expected_complexity", probe.get("complexity", color.a))), 0.0, 1.0)
		return _pack_shader_rgba8(color)
	var semantic_packed := int(probe.get("expected_rgba8", SemanticProbeProfileScript.pack_rgba8(Color.WHITE)))
	return _pack_shader_rgba8(_color_from_semantic_rgba8(semantic_packed))


static func _pack_shader_rgba8(color: Color) -> int:
	var r := clampi(roundi(color.r * 255.0), 0, 255)
	var g := clampi(roundi(color.g * 255.0), 0, 255)
	var b := clampi(roundi(color.b * 255.0), 0, 255)
	var a := clampi(roundi(color.a * 255.0), 0, 255)
	return (r << 24) | (g << 16) | (b << 8) | a


static func _color_from_semantic_rgba8(packed: int) -> Color:
	return Color(
		float(packed & 0xff) / 255.0,
		float((packed >> 8) & 0xff) / 255.0,
		float((packed >> 16) & 0xff) / 255.0,
		float((packed >> 24) & 0xff) / 255.0
	)


static func _probe_metric_weights(p: Dictionary) -> Vector3:
	return Vector3(
		float(p.get("w_color", 1.0)),
		float(p.get("w_complexity", 1.0)),
		float(p.get("w_collision", 1.0)),
	)


static func _hex_to_u32(hex_value: String) -> int:
	var result := 0
	for i in range(hex_value.length()):
		var c := hex_value.unicode_at(i)
		var nibble := -1
		if c >= 48 and c <= 57:
			nibble = c - 48
		elif c >= 65 and c <= 70:
			nibble = c - 65 + 10
		elif c >= 97 and c <= 102:
			nibble = c - 97 + 10
		if nibble < 0:
			continue
		result = ((result << 4) | nibble) & 0xffffffff
	return result


static func normalize_descriptor(
	descriptor: Resource,
	default_radius: float = 0.0,
	density_override: float = -1.0,
	world_scale: Vector3 = Vector3.ONE,
	mesh: Mesh = null
) -> Dictionary:
	if descriptor == null:
		return _normalize_profile_record({})
	var shared_fields := SharedPropertyTypeScript.from_descriptor(descriptor, default_radius)
	var collision := SharedPropertyTypeScript.duplicate_dictionary_array(shared_fields.get("collision", []))
	var semantic_probe_density := clampf(
		density_override if density_override > 0.0 else _float_property(descriptor, "semantic_probe_density", 1.0),
		0.1,
		8.0
	)
	var probes: Array = []
	if descriptor.has_method("get_semantic_probes"):
		if mesh != null:
			probes = descriptor.call("get_semantic_probes", mesh, semantic_probe_density, world_scale, collision)
		else:
			probes = descriptor.call("get_semantic_probes", semantic_probe_density)
	elif _object_has_property(descriptor, "semantic_probe_profile"):
		var probe_profile = descriptor.get("semantic_probe_profile")
		if probe_profile != null and probe_profile.has_method("get_probes"):
			probes = probe_profile.call("get_probes")

	var pivots: Array = []
	if descriptor.has_method("get_pivot_variants"):
		pivots = descriptor.call("get_pivot_variants")
	elif _object_has_property(descriptor, "pivot_variants"):
		var raw_pivots = descriptor.get("pivot_variants")
		if raw_pivots is Array:
			pivots = raw_pivots

	return _normalize_profile_record({
		"source_kind": "descriptor",
		"source_path": descriptor.resource_path,
		"asset_id": str(_property_or_default(descriptor, "asset_id", "")),
		"object_type": str(_property_or_default(descriptor, "object_type", "")),
		"color": shared_fields.get("color", Color.WHITE),
		"complexity": float(shared_fields.get("complexity", 1.0)),
		"collision": collision,
		"pivot_variants": pivots,
		"semantic_probes": probes,
		"semantic_probe_density": semantic_probe_density,
		"context_sensing_radius": _float_property(descriptor, "context_sensing_radius", 0.0),
	})


static func normalize_profile(profile: AutoVoxelProfile, default_radius: float = 0.0) -> Dictionary:
	if profile == null:
		return _normalize_profile_record({})
	var shared_fields := SharedPropertyTypeScript.from_profile(profile, default_radius)
	return _normalize_profile_record({
		"source_kind": "profile",
		"source_path": profile.resource_path,
		"color": shared_fields.get("color", Color.WHITE),
		"complexity": float(shared_fields.get("complexity", 1.0)),
		"collision": shared_fields.get("collision", []),
		"pivot_variants": [],
		"semantic_probes": [],
		"semantic_probe_density": 1.0,
		"context_sensing_radius": 0.0,
	})


static func _normalize_profile_record(raw_profile: Dictionary) -> Dictionary:
	var color := SharedPropertyTypeScript.color_from_value(raw_profile.get("color", Color.WHITE), Color.WHITE)
	var complexity := clampf(float(raw_profile.get("complexity", color.a)), 0.0, 1.0)
	color.a = complexity

	var collision := AssetDescriptorScript.normalize_collision(_array_from_value(raw_profile.get("collision", [])), 0.0)
	var pivots := AssetDescriptorScript.normalize_pivot_variants(_array_from_value(raw_profile.get("pivot_variants", [])))
	var probes := SemanticProbeProfileScript.duplicate_probe_array(_array_from_value(raw_profile.get("semantic_probes", [])))

	var normalized := {
		"source_kind": str(raw_profile.get("source_kind", "")),
		"source_path": str(raw_profile.get("source_path", "")),
		"asset_id": str(raw_profile.get("asset_id", "")),
		"object_type": str(raw_profile.get("object_type", "")),
		"color": color,
		"complexity": complexity,
		"collision": collision,
		"pivot_variants": pivots,
		"semantic_probes": probes,
		"semantic_probe_density": clampf(float(raw_profile.get("semantic_probe_density", 1.0)), 0.1, 8.0),
		"context_sensing_radius": maxf(float(raw_profile.get("context_sensing_radius", 0.0)), 0.0),
	}
	normalized["profile_hash"] = _stable_hash_hex(_canonical_string(_profile_hash_source(normalized)))
	return normalized


static func _profile_hash_source(normalized: Dictionary) -> Dictionary:
	return {
		"color": normalized.get("color", Color.WHITE),
		"complexity": float(normalized.get("complexity", 1.0)),
		"collision": _sorted_canonical_entries(normalized.get("collision", [])),
		"pivot_variants": _sorted_canonical_entries(normalized.get("pivot_variants", [])),
		"semantic_probes": _sorted_canonical_entries(normalized.get("semantic_probes", [])),
		"semantic_probe_density": float(normalized.get("semantic_probe_density", 1.0)),
		"context_sensing_radius": float(normalized.get("context_sensing_radius", 0.0)),
	}


func _profile_id_from_hash(profile_hash: String) -> int:
	var profile_id := _stable_u31_hash("profile_id:" + profile_hash)
	if profile_id <= 0:
		profile_id = 1
	while _profile_id_to_hash.has(profile_id) and str(_profile_id_to_hash[profile_id]) != profile_hash:
		profile_id += 1
		if profile_id <= 0:
			profile_id = 1
	return profile_id


func _append_range(target: Array[Dictionary], source) -> Dictionary:
	var start := target.size()
	if source is Array:
		for raw_entry in source:
			if raw_entry is Dictionary:
				target.append((raw_entry as Dictionary).duplicate(true))
	return {
		"start": start,
		"count": target.size() - start,
		"end": target.size(),
	}


static func _make_range_entry(profile_id: int, profile_index: int, range_data: Dictionary) -> Dictionary:
	return {
		"profile_id": profile_id,
		"profile_index": profile_index,
		"start": int(range_data.get("start", 0)),
		"count": int(range_data.get("count", 0)),
		"end": int(range_data.get("end", 0)),
	}


static func _duplicate_dictionary_array(source: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for raw_entry in source:
		if raw_entry is Dictionary:
			result.append((raw_entry as Dictionary).duplicate(true))
	return result


static func _array_from_value(value) -> Array:
	if value is Array:
		return (value as Array).duplicate(true)
	return []


static func _sorted_canonical_entries(value) -> Array[String]:
	var result: Array[String] = []
	if value is Array:
		for raw_entry in value:
			result.append(_canonical_string(raw_entry))
	result.sort()
	return result


static func _canonical_string(value) -> String:
	match typeof(value):
		TYPE_NIL:
			return "nil"
		TYPE_BOOL:
			return "b:%s" % str(value)
		TYPE_INT:
			return "i:%d" % int(value)
		TYPE_FLOAT:
			return "f:%s" % _format_float(float(value))
		TYPE_STRING:
			var s := str(value)
			return "s:%d:%s" % [s.length(), s]
		TYPE_VECTOR2:
			var v2: Vector2 = value
			return "v2:%s,%s" % [_format_float(v2.x), _format_float(v2.y)]
		TYPE_VECTOR2I:
			var v2i: Vector2i = value
			return "v2i:%d,%d" % [v2i.x, v2i.y]
		TYPE_VECTOR3:
			var v3: Vector3 = value
			return "v3:%s,%s,%s" % [_format_float(v3.x), _format_float(v3.y), _format_float(v3.z)]
		TYPE_VECTOR3I:
			var v3i: Vector3i = value
			return "v3i:%d,%d,%d" % [v3i.x, v3i.y, v3i.z]
		TYPE_COLOR:
			var c: Color = value
			return "color:%s,%s,%s,%s" % [
				_format_float(c.r),
				_format_float(c.g),
				_format_float(c.b),
				_format_float(c.a),
			]
		TYPE_ARRAY:
			var parts: Array[String] = []
			for entry in value:
				parts.append(_canonical_string(entry))
			return "a:[%s]" % ",".join(parts)
		TYPE_DICTIONARY:
			var keys := (value as Dictionary).keys()
			keys.sort()
			var dict_parts: Array[String] = []
			for key in keys:
				dict_parts.append("%s=%s" % [_canonical_string(key), _canonical_string((value as Dictionary)[key])])
			return "d:{%s}" % ",".join(dict_parts)
		_:
			return "v:%s" % str(value)


static func _format_float(value: float) -> String:
	var v := value
	if absf(v) <= 0.0000005:
		v = 0.0
	return "%.6f" % v


static func _stable_hash_hex(value: String) -> String:
	return "%08x" % _stable_u32_hash(value)


static func _stable_u31_hash(value: String) -> int:
	var h := _stable_u32_hash(value) & 0x7fffffff
	return h if h > 0 else 1


static func _stable_u32_hash(value: String) -> int:
	var h := 2166136261
	for i in range(value.length()):
		h = (h ^ value.unicode_at(i)) & 0xffffffff
		h = (h * 16777619) & 0xffffffff
	return h


static func _descriptor_source_key(descriptor: Resource) -> String:
	if descriptor == null:
		return ""
	if not descriptor.resource_path.is_empty():
		return "path:%s" % descriptor.resource_path
	return "instance:%d" % descriptor.get_instance_id()


static func _float_property(object: Object, property_name: String, fallback: float) -> float:
	var value = _property_or_default(object, property_name, fallback)
	if value == null:
		return fallback
	return float(value)


static func _property_or_default(object: Object, property_name: String, fallback):
	if not _object_has_property(object, property_name):
		return fallback
	return object.get(property_name)


static func _object_has_property(object: Object, property_name: String) -> bool:
	if object == null:
		return false
	for property in object.get_property_list():
		if str((property as Dictionary).get("name", "")) == property_name:
			return true
	return false
