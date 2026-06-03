extends RefCounted

const COMMIT_SOURCE_NONE := 0
const COMMIT_SOURCE_AUTO := 1
const COMMIT_SOURCE_BRUSH := 2

const SharedPropertyTypeScript := preload("res://scripts/shared_property_type.gd")
const SceneVoxelPayloadScript := preload("res://scripts/scene_voxel_payload.gd")

static func decode_float_buffer(bytes: PackedByteArray, expected_size: int) -> PackedFloat32Array:
	var expected_count := maxi(expected_size, 0)
	var expected_bytes := expected_count * 4
	var available_bytes := mini(bytes.size(), expected_bytes)
	available_bytes -= available_bytes % 4
	var values := bytes.slice(0, available_bytes).to_float32_array()
	values.resize(expected_count)
	return values

static func decode_u32_buffer(bytes: PackedByteArray, expected_size: int) -> PackedInt32Array:
	var expected_count := maxi(expected_size, 0)
	var expected_bytes := expected_count * 4
	var available_bytes := mini(bytes.size(), expected_bytes)
	available_bytes -= available_bytes % 4
	var values := bytes.slice(0, available_bytes).to_int32_array()
	values.resize(expected_count)
	return values

static func pack_source_values(source_stream: Dictionary, source_keys: Array, source_float_stride: int) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	values.resize(source_keys.size() * source_float_stride)

	for i in range(source_keys.size()):
		var key := str(source_keys[i])
		var source = source_stream.get(key, {})
		if not source is Dictionary:
			continue

		var voxel := source as Dictionary
		if voxel.is_empty():
			continue

		var base := i * source_float_stride
		var complexity := SceneVoxelPayloadScript.voxel_complexity(voxel)
		var color := SharedPropertyTypeScript.color_from_value(voxel.get("color", Color.WHITE), Color.WHITE)
		color.a = complexity

		values[base + 0] = complexity
		values[base + 1] = clampf(color.r, 0.0, 1.0)
		values[base + 2] = clampf(color.g, 0.0, 1.0)
		values[base + 3] = clampf(color.b, 0.0, 1.0)
		values[base + 4] = complexity
		values[base + 5] = 1.0
		values[base + 6] = clampf(float(voxel.get("auto_mix", 0.0)), 0.0, 1.0)
		values[base + 7] = 1.0 if SharedPropertyTypeScript.has_collision_fields(voxel) else 0.0
		values[base + 8] = float(int(voxel.get("slice_index", -1)))

		var voxel_xz = voxel.get("voxel_xz", Vector2i(-1, -1))
		if voxel_xz is Vector2i:
			values[base + 9] = float((voxel_xz as Vector2i).x)
			values[base + 10] = float((voxel_xz as Vector2i).y)

		var base_pixel = voxel.get("base_pixel", voxel_xz)
		if base_pixel is Vector2i:
			values[base + 11] = float((base_pixel as Vector2i).x)
			values[base + 12] = float((base_pixel as Vector2i).y)

	return values

static func source_selector_from_payload(payloads: PackedFloat32Array, payload_base: int) -> int:
	if payload_base + 5 >= payloads.size():
		return COMMIT_SOURCE_NONE
	return int(payloads[payload_base + 5] + 0.5)

static func selected_source_for_selector(
	auto_source: Dictionary,
	brush_source: Dictionary,
	source_selector: int
) -> Dictionary:
	match source_selector:
		COMMIT_SOURCE_AUTO:
			return auto_source
		COMMIT_SOURCE_BRUSH:
			return brush_source
		_:
			return {}

static func metadata_for_selector(
	auto_source: Dictionary,
	brush_source: Dictionary,
	source_selector: int,
	snapshot_epoch: int
) -> Dictionary:
	var selected := selected_source_for_selector(auto_source, brush_source, source_selector)
	if selected.is_empty():
		return {}

	var source_metadata := selected.duplicate(true)
	source_metadata.erase("commit_tick")
	source_metadata["snapshot_epoch"] = snapshot_epoch
	return source_metadata

static func committed_scene_voxel_from_payload(
	auto_source: Dictionary,
	brush_source: Dictionary,
	payloads: PackedFloat32Array,
	payload_base: int,
	output_float_stride: int
) -> Dictionary:
	if payload_base + output_float_stride > payloads.size():
		return {}

	var source_selector := source_selector_from_payload(payloads, payload_base)
	var selected := selected_source_for_selector(auto_source, brush_source, source_selector)
	if selected.is_empty():
		return {}

	var complexity := clampf(payloads[payload_base + 0], 0.0, 1.0)
	var color := Color(
		clampf(payloads[payload_base + 1], 0.0, 1.0),
		clampf(payloads[payload_base + 2], 0.0, 1.0),
		clampf(payloads[payload_base + 3], 0.0, 1.0),
		complexity
	)
	var scene_voxel := {
		"complexity": complexity,
		"color": color,
		"slice_index": int(selected.get("slice_index", -1)),
		"base_pixel": selected.get("base_pixel", selected.get("voxel_xz", Vector2i.ZERO)),
	}
	if payload_base + 6 < payloads.size():
		scene_voxel["auto_mix"] = clampf(payloads[payload_base + 6], 0.0, 1.0)

	var voxel_xz = selected.get("voxel_xz", Vector2i(-1, -1))
	if voxel_xz is Vector2i:
		scene_voxel["voxel_xz"] = voxel_xz

	var source_fields := {
		"color": color,
		"complexity": complexity,
	}
	var include_collision := SharedPropertyTypeScript.has_collision_fields(selected)
	if include_collision:
		source_fields["collision"] = selected.get("collision", [])

	return SceneVoxelPayloadScript.internal_payload(
		SharedPropertyTypeScript.apply_to_scene_voxel(
			scene_voxel,
			source_fields,
			complexity,
			include_collision
		)
	)

static func commit_sources_from_payloads(
	source_keys: Array,
	payloads: PackedFloat32Array,
	final_scene_voxels: Dictionary,
	auto_scene_voxel_sources: Dictionary,
	brush_scene_voxel_sources: Dictionary,
	scene_source_metadata: Dictionary,
	commit_tick: int,
	output_float_stride: int
) -> void:
	for i in range(source_keys.size()):
		var key := str(source_keys[i])
		var auto_source := {}
		var raw_auto_source = auto_scene_voxel_sources.get(key, {})
		if raw_auto_source is Dictionary:
			auto_source = raw_auto_source as Dictionary

		var brush_source := {}
		var raw_brush_source = brush_scene_voxel_sources.get(key, {})
		if raw_brush_source is Dictionary:
			brush_source = raw_brush_source as Dictionary

		var payload_base := i * output_float_stride
		var source_selector := source_selector_from_payload(payloads, payload_base)
		if source_selector == COMMIT_SOURCE_NONE:
			final_scene_voxels.erase(key)
			scene_source_metadata.erase(key)
			continue

		var blended_scene_voxel := committed_scene_voxel_from_payload(
			auto_source,
			brush_source,
			payloads,
			payload_base,
			output_float_stride
		)
		if blended_scene_voxel.is_empty():
			final_scene_voxels.erase(key)
			scene_source_metadata.erase(key)
			continue

		final_scene_voxels[key] = blended_scene_voxel
		scene_source_metadata[key] = metadata_for_selector(
			auto_source,
			brush_source,
			source_selector,
			commit_tick
		)
