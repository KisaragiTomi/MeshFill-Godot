extends RefCounted

const RECORD_STRIDE_BYTES := 128
const SUMMARY_STRIDE_BYTES := 32
const INDEX_STRIDE_BYTES := 4
const REF_STRIDE_BYTES := 4
const FIELD_STRIDE_BYTES := 4

const FLAG_SCENE := 1
const FLAG_COLLISION := 2
const FLAG_AUTO := 4
const FLAG_BRUSH := 8
const FLAG_TARGET := 16
const FLAG_ROUTING := 32
const FLAG_SCORING := 64
const FLAG_FEEDBACK := 128
const FLAG_OBJECT_REFS := 256
const FLAG_MASK := 512

static func register_project_settings(setting_name: String, default_size: Vector3i) -> void:
	if not ProjectSettings.has_setting(setting_name):
		ProjectSettings.set_setting(setting_name, default_size)

	ProjectSettings.add_property_info({
		"name": setting_name,
		"type": TYPE_VECTOR3I,
		"hint": PROPERTY_HINT_NONE,
	})

static func configured_size(setting_name: String, default_size: Vector3i) -> Vector3i:
	var value = ProjectSettings.get_setting(setting_name, default_size)
	var size := vector3i_from_value(value, default_size)
	return Vector3i(maxi(size.x, 1), maxi(size.y, 1), maxi(size.z, 1))

static func tile_grid_size(grid_size: Vector3i, tile_size: Vector3i) -> Vector3i:
	return Vector3i(
		maxi(ceili(float(maxi(grid_size.x, 1)) / float(tile_size.x)), 1),
		maxi(ceili(float(maxi(grid_size.y, 1)) / float(tile_size.y)), 1),
		maxi(ceili(float(maxi(grid_size.z, 1)) / float(tile_size.z)), 1)
	)

static func tile_coord_from_voxel(voxel_coord: Vector3i, grid_size: Vector3i, tile_size: Vector3i) -> Vector3i:
	var tile_grid := tile_grid_size(grid_size, tile_size)
	return Vector3i(
		clampi(int(voxel_coord.x / tile_size.x), 0, tile_grid.x - 1),
		clampi(int(voxel_coord.y / tile_size.y), 0, tile_grid.y - 1),
		clampi(int(voxel_coord.z / tile_size.z), 0, tile_grid.z - 1)
	)

static func tile_id(tile_coord: Vector3i) -> String:
	return "%d:%d:%d" % [tile_coord.x, tile_coord.y, tile_coord.z]

static func tile_bounds(tile_coord: Vector3i, grid_size: Vector3i, tile_size: Vector3i) -> Dictionary:
	var voxel_min := Vector3i(
		clampi(tile_coord.x * tile_size.x, 0, maxi(grid_size.x - 1, 0)),
		clampi(tile_coord.y * tile_size.y, 0, maxi(grid_size.y - 1, 0)),
		clampi(tile_coord.z * tile_size.z, 0, maxi(grid_size.z - 1, 0))
	)
	var voxel_max := Vector3i(
		clampi(voxel_min.x + tile_size.x, voxel_min.x + 1, maxi(grid_size.x, 1)),
		clampi(voxel_min.y + tile_size.y, voxel_min.y + 1, maxi(grid_size.y, 1)),
		clampi(voxel_min.z + tile_size.z, voxel_min.z + 1, maxi(grid_size.z, 1))
	)

	return {
		"tile_size": tile_size,
		"voxel_min": voxel_min,
		"voxel_max": voxel_max,
		"base_rect": Rect2i(
			Vector2i(voxel_min.x, voxel_min.z),
			Vector2i(maxi(voxel_max.x - voxel_min.x, 1), maxi(voxel_max.z - voxel_min.z, 1))
		),
	}

static func flags_from_value(value, default_layer: String = "scene") -> Dictionary:
	var flags := {}

	if value is Dictionary:
		for key in (value as Dictionary).keys():
			if bool((value as Dictionary).get(key, false)):
				flags[str(key)] = true
	elif value is Array:
		for item in value as Array:
			var flag_name := str(item)
			if not flag_name.is_empty():
				flags[flag_name] = true
	elif value is String:
		var flag := str(value)
		if not flag.is_empty():
			flags[flag] = true
	elif value is int:
		if int(value) != 0:
			flags["mask"] = int(value)

	var guidance_only := (
		bool(flags.get("target", false))
		or bool(flags.get("routing", false))
		or bool(flags.get("scoring", false))
		or bool(flags.get("feedback", false))
	) and not flags.has("scene") and not flags.has("collision")

	if not flags.has("scene") and not flags.has("collision") and not guidance_only and not default_layer.is_empty():
		flags[default_layer] = true

	return flags

static func vector3i_from_value(value, fallback: Vector3i = Vector3i.ZERO) -> Vector3i:
	if value is Vector3i:
		return value
	if value is Vector3:
		var v3: Vector3 = value
		return Vector3i(roundi(v3.x), roundi(v3.y), roundi(v3.z))
	if value is Vector2i:
		var v2i: Vector2i = value
		return Vector3i(v2i.x, fallback.y, v2i.y)
	if value is Vector2:
		var v2: Vector2 = value
		return Vector3i(roundi(v2.x), fallback.y, roundi(v2.y))
	if value is Array:
		var arr: Array = value
		if arr.size() >= 3:
			return Vector3i(int(arr[0]), int(arr[1]), int(arr[2]))
		if arr.size() >= 2:
			return Vector3i(int(arr[0]), fallback.y, int(arr[1]))
	if value is Dictionary:
		var dict: Dictionary = value
		return Vector3i(
			int(dict.get("x", dict.get("r", fallback.x))),
			int(dict.get("y", dict.get("g", fallback.y))),
			int(dict.get("z", dict.get("b", fallback.z)))
		)
	return fallback

static func first_vector3i(record: Dictionary, keys: Array[String], fallback: Vector3i = Vector3i.ZERO) -> Vector3i:
	for key in keys:
		if record.has(key):
			return vector3i_from_value(record.get(key), fallback)
	return fallback

static func has_any_key(record: Dictionary, keys: Array[String]) -> bool:
	for key in keys:
		if record.has(key):
			return true
	return false

static func normalized_bounds(voxel_min: Vector3i, voxel_max: Vector3i, grid_size: Vector3i) -> Dictionary:
	var min_v := Vector3i(
		clampi(mini(voxel_min.x, voxel_max.x - 1), 0, maxi(grid_size.x - 1, 0)),
		clampi(mini(voxel_min.y, voxel_max.y - 1), 0, maxi(grid_size.y - 1, 0)),
		clampi(mini(voxel_min.z, voxel_max.z - 1), 0, maxi(grid_size.z - 1, 0))
	)
	var max_v := Vector3i(
		clampi(maxi(voxel_min.x + 1, voxel_max.x), min_v.x + 1, maxi(grid_size.x, 1)),
		clampi(maxi(voxel_min.y + 1, voxel_max.y), min_v.y + 1, maxi(grid_size.y, 1)),
		clampi(maxi(voxel_min.z + 1, voxel_max.z), min_v.z + 1, maxi(grid_size.z, 1))
	)
	return {
		"voxel_min": min_v,
		"voxel_max": max_v,
	}

static func sv_tile_key(slice_index: int, voxel_px: Vector2i, layer: String = "scene", tile_size: int = 8) -> String:
	var tile_x := int(voxel_px.x / tile_size)
	var tile_y := int(voxel_px.y / tile_size)
	if layer == "collision":
		return "%d:collision:%d:%d" % [slice_index, tile_x, tile_y]
	return "%d:%d:%d" % [slice_index, tile_x, tile_y]

static func sv_tile_bounds(voxel_px: Vector2i, tile_size: int = 8) -> Rect2i:
	return Rect2i(
		Vector2i(int(voxel_px.x / tile_size) * tile_size, int(voxel_px.y / tile_size) * tile_size),
		Vector2i(tile_size, tile_size)
	)

static func packed_float_field(value) -> PackedFloat32Array:
	if value is PackedFloat32Array:
		return (value as PackedFloat32Array).duplicate()

	var result := PackedFloat32Array()
	if value is Array:
		for raw_value in value:
			result.append(float(raw_value))
	return result

static func pack_float_field_bytes(values: PackedFloat32Array) -> PackedByteArray:
	return values.to_byte_array()

static func decode_float_field_bytes(bytes: PackedByteArray) -> PackedFloat32Array:
	var available_bytes := bytes.size()
	available_bytes -= available_bytes % FIELD_STRIDE_BYTES
	return bytes.slice(0, available_bytes).to_float32_array()

static func sorted_tile_ids(scene_voxel_tiles: Dictionary) -> Array[String]:
	var ids: Array[String] = []
	for raw_id in scene_voxel_tiles.keys():
		ids.append(str(raw_id))
	ids.sort()
	return ids

static func pack_record_bytes(tile_ids: Array[String], scene_voxel_tiles: Dictionary, default_tile_size: Vector3i) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(tile_ids.size() * RECORD_STRIDE_BYTES)

	for i in range(tile_ids.size()):
		var tile_id := tile_ids[i]
		var tile: Dictionary = scene_voxel_tiles.get(tile_id, {})
		var base := i * RECORD_STRIDE_BYTES
		var tile_coord: Vector3i = tile.get("tile_coord", Vector3i.ZERO)
		var tile_size: Vector3i = tile.get("tile_size", default_tile_size)
		var voxel_min: Vector3i = tile.get("voxel_min", Vector3i.ZERO)
		var voxel_max: Vector3i = tile.get("voxel_max", voxel_min + Vector3i.ONE)
		var base_rect: Rect2i = tile.get("base_rect", Rect2i())
		var dirty_flags: Dictionary = tile.get("dirty_flags", {})

		bytes.encode_s32(base + 0, tile_coord.x)
		bytes.encode_s32(base + 4, tile_coord.y)
		bytes.encode_s32(base + 8, tile_coord.z)
		bytes.encode_s32(base + 12, flags_to_bits(dirty_flags))
		bytes.encode_s32(base + 16, tile_size.x)
		bytes.encode_s32(base + 20, tile_size.y)
		bytes.encode_s32(base + 24, tile_size.z)
		bytes.encode_s32(base + 28, int(tile.get("epoch", 0)))
		bytes.encode_s32(base + 32, voxel_min.x)
		bytes.encode_s32(base + 36, voxel_min.y)
		bytes.encode_s32(base + 40, voxel_min.z)
		bytes.encode_s32(base + 44, int(tile.get("last_commit_tick", 0)))
		bytes.encode_s32(base + 48, voxel_max.x)
		bytes.encode_s32(base + 52, voxel_max.y)
		bytes.encode_s32(base + 56, voxel_max.z)
		bytes.encode_s32(base + 60, int(tile.get("write_tick", 0)))
		bytes.encode_s32(base + 64, base_rect.position.x)
		bytes.encode_s32(base + 68, base_rect.position.y)
		bytes.encode_s32(base + 72, base_rect.size.x)
		bytes.encode_s32(base + 76, base_rect.size.y)
		bytes.encode_s32(base + 80, int(tile.get("object_range_start", 0)))
		bytes.encode_s32(base + 84, int(tile.get("object_range_count", 0)))
		bytes.encode_s32(base + 88, int(tile.get("source_range_start", 0)))
		bytes.encode_s32(base + 92, int(tile.get("source_range_count", 0)))
		bytes.encode_s32(base + 96, int(tile.get("scene_voxel_count", 0)))
		bytes.encode_s32(base + 100, int(tile.get("collision_cell_count", 0)))
		bytes.encode_s32(base + 104, 1 if bool(tile.get("non_empty", false)) else 0)
		bytes.encode_s32(base + 108, 1 if bool(tile.get("updated_this_commit", false)) else 0)
		bytes.encode_u32(base + 112, stable_hash(tile_id))
		bytes.encode_s32(base + 116, 1 if bool(tile.get("dirty", false)) else 0)
		bytes.encode_s32(base + 120, 0)
		bytes.encode_s32(base + 124, 0)

	return bytes

static func pack_summary_bytes(tile_ids: Array[String], scene_voxel_tiles: Dictionary) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(tile_ids.size() * SUMMARY_STRIDE_BYTES)

	for i in range(tile_ids.size()):
		var tile: Dictionary = scene_voxel_tiles.get(tile_ids[i], {})
		var scene_minmax: Vector2 = tile.get("scene_minmax", Vector2.ZERO)
		var collision_minmax: Vector2 = tile.get("collision_minmax", Vector2.ZERO)
		var base := i * SUMMARY_STRIDE_BYTES

		bytes.encode_float(base + 0, scene_minmax.x)
		bytes.encode_float(base + 4, scene_minmax.y)
		bytes.encode_float(base + 8, collision_minmax.x)
		bytes.encode_float(base + 12, collision_minmax.y)
		bytes.encode_s32(base + 16, int(tile.get("scene_voxel_count", 0)))
		bytes.encode_s32(base + 20, int(tile.get("collision_cell_count", 0)))
		bytes.encode_s32(base + 24, 1 if bool(tile.get("non_empty", false)) else 0)
		bytes.encode_s32(base + 28, 0)

	return bytes

static func pack_dirty_index_bytes(tile_ids: Array[String], scene_voxel_tiles: Dictionary) -> Dictionary:
	var dirty_indices := PackedInt32Array()
	var dirty_tile_ids: Array[String] = []

	for i in range(tile_ids.size()):
		var tile: Dictionary = scene_voxel_tiles.get(tile_ids[i], {})
		if bool(tile.get("dirty", false)):
			dirty_indices.append(i)
			dirty_tile_ids.append(tile_ids[i])

	return {
		"bytes": dirty_indices.to_byte_array(),
		"dirty_tile_ids": dirty_tile_ids,
	}

static func pack_ref_hash_bytes(values: Array[String]) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(values.size() * REF_STRIDE_BYTES)
	for i in range(values.size()):
		bytes.encode_u32(i * REF_STRIDE_BYTES, stable_hash(str(values[i])))
	return bytes

static func decode_dirty_ids(bytes: PackedByteArray, tile_ids: Array[String]) -> Array[String]:
	var result: Array[String] = []
	var available_bytes := mini(bytes.size(), tile_ids.size() * INDEX_STRIDE_BYTES)
	available_bytes -= available_bytes % INDEX_STRIDE_BYTES
	var dirty_count := int(available_bytes / INDEX_STRIDE_BYTES)
	for i in range(dirty_count):
		var tile_index := bytes.decode_s32(i * INDEX_STRIDE_BYTES)
		if tile_index >= 0 and tile_index < tile_ids.size():
			result.append(tile_ids[tile_index])
	return result

static func decode_records(bytes: PackedByteArray, tile_ids: Array[String]) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	var available_bytes := mini(bytes.size(), tile_ids.size() * RECORD_STRIDE_BYTES)
	available_bytes -= available_bytes % RECORD_STRIDE_BYTES
	var count := mini(tile_ids.size(), int(available_bytes / RECORD_STRIDE_BYTES))

	for i in range(count):
		var base := i * RECORD_STRIDE_BYTES
		records.append({
			"scene_voxel_tile_id": tile_ids[i],
			"tile_coord": Vector3i(bytes.decode_s32(base + 0), bytes.decode_s32(base + 4), bytes.decode_s32(base + 8)),
			"dirty_flags": flags_from_bits(bytes.decode_s32(base + 12)),
			"tile_size": Vector3i(bytes.decode_s32(base + 16), bytes.decode_s32(base + 20), bytes.decode_s32(base + 24)),
			"epoch": bytes.decode_s32(base + 28),
			"voxel_min": Vector3i(bytes.decode_s32(base + 32), bytes.decode_s32(base + 36), bytes.decode_s32(base + 40)),
			"last_commit_tick": bytes.decode_s32(base + 44),
			"voxel_max": Vector3i(bytes.decode_s32(base + 48), bytes.decode_s32(base + 52), bytes.decode_s32(base + 56)),
			"write_tick": bytes.decode_s32(base + 60),
			"base_rect": Rect2i(
				Vector2i(bytes.decode_s32(base + 64), bytes.decode_s32(base + 68)),
				Vector2i(bytes.decode_s32(base + 72), bytes.decode_s32(base + 76))
			),
			"object_range_start": bytes.decode_s32(base + 80),
			"object_range_count": bytes.decode_s32(base + 84),
			"source_range_start": bytes.decode_s32(base + 88),
			"source_range_count": bytes.decode_s32(base + 92),
			"scene_voxel_count": bytes.decode_s32(base + 96),
			"collision_cell_count": bytes.decode_s32(base + 100),
			"non_empty": bytes.decode_s32(base + 104) != 0,
			"updated_this_commit": bytes.decode_s32(base + 108) != 0,
			"tile_hash": int(bytes.decode_u32(base + 112)),
			"dirty": bytes.decode_s32(base + 116) != 0,
		})

	return records

static func decode_summaries(bytes: PackedByteArray, tile_ids: Array[String]) -> Array[Dictionary]:
	var summaries: Array[Dictionary] = []
	var available_bytes := mini(bytes.size(), tile_ids.size() * SUMMARY_STRIDE_BYTES)
	available_bytes -= available_bytes % SUMMARY_STRIDE_BYTES
	var count := mini(tile_ids.size(), int(available_bytes / SUMMARY_STRIDE_BYTES))

	for i in range(count):
		var base := i * SUMMARY_STRIDE_BYTES
		summaries.append({
			"scene_voxel_tile_id": tile_ids[i],
			"scene_minmax": Vector2(bytes.decode_float(base + 0), bytes.decode_float(base + 4)),
			"collision_minmax": Vector2(bytes.decode_float(base + 8), bytes.decode_float(base + 12)),
			"scene_voxel_count": bytes.decode_s32(base + 16),
			"collision_cell_count": bytes.decode_s32(base + 20),
			"non_empty": bytes.decode_s32(base + 24) != 0,
		})

	return summaries

static func flags_to_bits(dirty_flags: Dictionary) -> int:
	var bits := 0
	if bool(dirty_flags.get("scene", false)):
		bits |= FLAG_SCENE
	if bool(dirty_flags.get("collision", false)):
		bits |= FLAG_COLLISION
	if bool(dirty_flags.get("auto", false)):
		bits |= FLAG_AUTO
	if bool(dirty_flags.get("brush", false)):
		bits |= FLAG_BRUSH
	if bool(dirty_flags.get("target", false)):
		bits |= FLAG_TARGET
	if bool(dirty_flags.get("routing", false)):
		bits |= FLAG_ROUTING
	if bool(dirty_flags.get("scoring", false)):
		bits |= FLAG_SCORING
	if bool(dirty_flags.get("feedback", false)):
		bits |= FLAG_FEEDBACK
	if bool(dirty_flags.get("object_refs", false)):
		bits |= FLAG_OBJECT_REFS
	if int(dirty_flags.get("mask", 0)) != 0:
		bits |= FLAG_MASK
	return bits

static func flags_from_bits(bits: int) -> Dictionary:
	var flags := {}
	if (bits & FLAG_SCENE) != 0:
		flags["scene"] = true
	if (bits & FLAG_COLLISION) != 0:
		flags["collision"] = true
	if (bits & FLAG_AUTO) != 0:
		flags["auto"] = true
	if (bits & FLAG_BRUSH) != 0:
		flags["brush"] = true
	if (bits & FLAG_TARGET) != 0:
		flags["target"] = true
	if (bits & FLAG_ROUTING) != 0:
		flags["routing"] = true
	if (bits & FLAG_SCORING) != 0:
		flags["scoring"] = true
	if (bits & FLAG_FEEDBACK) != 0:
		flags["feedback"] = true
	if (bits & FLAG_OBJECT_REFS) != 0:
		flags["object_refs"] = true
	if (bits & FLAG_MASK) != 0:
		flags["mask"] = true
	return flags

static func _u32_word(value: int) -> int:
	return value if value >= 0 else value + 4294967296

static func stable_hash(value: String) -> int:
	var h := 2166136261
	for i in range(value.length()):
		h = (h ^ value.unicode_at(i)) & 0xffffffff
		h = (h * 16777619) & 0xffffffff
	return h
