extends RefCounted

const COMMIT_SOURCE_NONE := 0
const COMMIT_SOURCE_AUTO := 1
const COMMIT_SOURCE_BRUSH := 2

const SRC_HAS_COLLISION := 7
const SRC_COLLISION_STRENGTH := 13
const SRC_COLLISION_LAYER_COUNT := 14

const OUT_COLLISION_STRENGTH := 8
const OUT_COLLISION_LAYER_COUNT := 9
const OUT_HAS_COLLISION := 10

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
		var collision_summary := collision_summary_from_source(voxel)
		values[base + SRC_HAS_COLLISION] = 1.0 if bool(collision_summary.get("has_collision", false)) else 0.0
		values[base + 8] = float(int(voxel.get("slice_index", -1)))

		var voxel_xz = voxel.get("voxel_xz", Vector2i(-1, -1))
		if voxel_xz is Vector2i:
			values[base + 9] = float((voxel_xz as Vector2i).x)
			values[base + 10] = float((voxel_xz as Vector2i).y)

		var base_pixel = voxel.get("base_pixel", voxel_xz)
		if base_pixel is Vector2i:
			values[base + 11] = float((base_pixel as Vector2i).x)
			values[base + 12] = float((base_pixel as Vector2i).y)
		if source_float_stride > SRC_COLLISION_STRENGTH:
			values[base + SRC_COLLISION_STRENGTH] = clampf(float(collision_summary.get("collision_strength", 0.0)), 0.0, 1.0)
		if source_float_stride > SRC_COLLISION_LAYER_COUNT:
			values[base + SRC_COLLISION_LAYER_COUNT] = float(maxi(int(collision_summary.get("layer_count", 0)), 0))

	return values

static func collision_summary_from_source(source: Dictionary) -> Dictionary:
	var has_collision := SharedPropertyTypeScript.has_collision_fields(source)
	var summary := {
		"has_collision": has_collision,
		"collision_strength": 0.0,
		"layer_count": 0,
	}
	if not has_collision:
		return summary

	var raw_collision = source.get("collision", [])
	if raw_collision is float or raw_collision is int:
		var scalar_strength := clampf(float(raw_collision), 0.0, 1.0)
		summary["collision_strength"] = scalar_strength
		summary["layer_count"] = 1 if scalar_strength > 0.0 else 0
		return summary

	if not raw_collision is Array:
		return summary

	var layers := SharedPropertyTypeScript.collision_from_fields(source)
	summary["layer_count"] = layers.size()
	var max_strength := 0.0
	for layer in layers:
		max_strength = maxf(max_strength, clampf(float(layer.get("collision_strength", 1.0)), 0.0, 1.0))
	summary["collision_strength"] = max_strength
	return summary

static func collision_summary_from_payload(
	payloads: PackedFloat32Array,
	payload_base: int,
	output_float_stride: int
) -> Dictionary:
	var summary := {
		"has_collision": false,
		"collision_strength": 0.0,
		"layer_count": 0,
		"summary_source": "committed_scene_voxel_payload",
	}
	if payload_base + output_float_stride > payloads.size():
		return summary
	if output_float_stride <= OUT_HAS_COLLISION:
		return summary
	var has_collision := payloads[payload_base + OUT_HAS_COLLISION] > 0.5
	summary["has_collision"] = has_collision
	if not has_collision:
		return summary
	summary["collision_strength"] = clampf(payloads[payload_base + OUT_COLLISION_STRENGTH], 0.0, 1.0)
	summary["layer_count"] = maxi(int(payloads[payload_base + OUT_COLLISION_LAYER_COUNT] + 0.5), 0)
	return summary

static func collision_debug_array_from_summary(
	summary: Dictionary,
	slice_index: int = -1,
	voxel_xz: Vector2i = Vector2i(-1, -1)
) -> Array:
	if not bool(summary.get("has_collision", false)):
		return []
	var layer_count := maxi(int(summary.get("layer_count", 0)), 0)
	var collision_strength := clampf(float(summary.get("collision_strength", 0.0)), 0.0, 1.0)
	if layer_count <= 0 and collision_strength <= 0.0:
		return []

	return [{
		"shape": "debug_summary",
		"collision_shape": "debug_summary",
		"debug_summary": true,
		"summary_source": str(summary.get("summary_source", "committed_scene_voxel_payload")),
		"exact_layer_fidelity": false,
		"layer_count": layer_count,
		"collision_strength": collision_strength,
		"max_collision_strength": collision_strength,
		"slice_index": slice_index,
		"voxel_xz": voxel_xz,
	}]

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
	var collision_summary := collision_summary_from_payload(payloads, payload_base, output_float_stride)
	var include_collision := bool(collision_summary.get("has_collision", false))
	if include_collision:
		var selected_collision := SharedPropertyTypeScript.collision_from_fields(selected)
		if not selected_collision.is_empty():
			source_fields["collision"] = selected_collision
		else:
			source_fields["collision"] = collision_debug_array_from_summary(
				collision_summary,
				int(scene_voxel.get("slice_index", -1)),
				scene_voxel.get("voxel_xz", Vector2i(-1, -1))
			)

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
