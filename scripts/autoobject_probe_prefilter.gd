class_name AutoObjectProbePrefilter
extends RefCounted

const SemanticProbeProfileScript := preload("res://scripts/semantic_probe_profile.gd")
const TILE_SIZE := 8
const ANCHOR_KIND_GROUND := AutoObject.ANCHOR_KIND_GROUND
const ANCHOR_KIND_TARGET_TOP := AutoObject.ANCHOR_KIND_TARGET_TOP

var anchor_topk: int = 4
var max_scene_occupancy: float = 0.15
var max_collision_occupancy: float = 0.05
var min_support: float = 0.25
var min_target_interest: float = 0.01
var min_prefilter_score: float = 0.35


func run_probe_prefilter(
	gvf: GlobalVoxelField,
	target_occupancy: PackedFloat32Array,
	target_color: PackedColorArray,
	autoobjects: Array,
	dirty_tile_ids: Array[int] = []
) -> Dictionary:
	if gvf == null:
		return {"anchors": [], "anchor_autoobject_topk": {}, "autoobject_candidate_tiles": {}}
	var tile_ids := dirty_tile_ids.duplicate()
	if tile_ids.is_empty():
		tile_ids = gvf.get_dirty_tile_ids()
	if tile_ids.is_empty():
		tile_ids = _all_tile_ids(gvf)
	var anchors := collect_anchors(gvf, target_occupancy, tile_ids)
	var anchor_results := score_and_select(anchors, autoobjects, gvf, target_occupancy, target_color)
	var tile_candidates := reduce_to_tiles(anchors, anchor_results, autoobjects, gvf)
	return {
		"anchors": anchors,
		"anchor_autoobject_topk": anchor_results,
		"autoobject_candidate_tiles": tile_candidates,
		"ground_anchor_count": _count_anchor_kind(anchors, ANCHOR_KIND_GROUND),
		"target_top_anchor_count": _count_anchor_kind(anchors, ANCHOR_KIND_TARGET_TOP),
	}


func collect_anchors(
	gvf: GlobalVoxelField,
	target_occupancy: PackedFloat32Array,
	dirty_tile_ids: Array[int]
) -> Array[Dictionary]:
	var anchors: Array[Dictionary] = []
	var seen_anchors: Dictionary = {}
	var seen_top_columns: Dictionary = {}
	for tile_id in dirty_tile_ids:
		var tile_pos := gvf.tile_id_to_pos(tile_id)
		var bounds := gvf.get_tile_voxel_bounds(tile_pos)
		var vmin: Vector3i = bounds.get("vmin", Vector3i.ZERO)
		var vmax: Vector3i = bounds.get("vmax", Vector3i.ZERO)
		for z in range(vmin.z, vmax.z):
			for y in range(vmin.y, vmax.y):
				for x in range(vmin.x, vmax.x):
					_try_append_ground_anchor(anchors, seen_anchors, gvf, target_occupancy, Vector3i(x, y, z), tile_id)
		for z in range(vmin.z, vmax.z):
			for x in range(vmin.x, vmax.x):
				var column_key := "%d:%d" % [x, z]
				if seen_top_columns.has(column_key):
					continue
				seen_top_columns[column_key] = true
				_try_append_target_top_anchor(anchors, seen_anchors, gvf, target_occupancy, x, z)
	return anchors


func score_and_select(
	anchors: Array[Dictionary],
	autoobjects: Array,
	gvf: GlobalVoxelField,
	target_occupancy: PackedFloat32Array,
	target_color: PackedColorArray
) -> Dictionary:
	var probe_cache: Dictionary = {}
	for obj_idx in range(autoobjects.size()):
		var autoobject := autoobjects[obj_idx] as AutoObject
		if autoobject == null:
			continue
		for anchor_kind in autoobject.get_allowed_anchor_kinds():
			var kind := str(anchor_kind)
			probe_cache[_probe_cache_key(obj_idx, kind)] = autoobject.get_semantic_probes(autoobject.semantic_probe_density, kind)
	var anchor_results: Dictionary = {}
	for anchor in anchors:
		var kind := str(anchor.get("anchor_kind", ANCHOR_KIND_GROUND))
		var candidates: Array[Dictionary] = []
		for obj_idx in range(autoobjects.size()):
			var autoobject := autoobjects[obj_idx] as AutoObject
			if autoobject == null:
				continue
			if not autoobject.accepts_anchor_kind(kind):
				continue
			var probes: Array = probe_cache.get(_probe_cache_key(obj_idx, kind), [])
			var score := score_autoobject(anchor, probes, gvf, target_occupancy, target_color)
			if score < min_prefilter_score:
				continue
			candidates.append({"autoobject_idx": obj_idx, "score": score, "anchor_kind": kind})
		candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.get("score", 0.0)) > float(b.get("score", 0.0)))
		anchor_results[int(anchor.get("id", -1))] = candidates.slice(0, anchor_topk)
	return anchor_results


func score_autoobject(
	anchor: Dictionary,
	probes: Array,
	gvf: GlobalVoxelField,
	target_occupancy: PackedFloat32Array,
	target_color: PackedColorArray
) -> float:
	if probes.is_empty():
		return -INF
	var total_score := 0.0
	var total_weight := 0.0
	var anchor_pos: Vector3i = anchor.get("voxel_pos", Vector3i.ZERO)
	for raw_probe in probes:
		if not raw_probe is Dictionary:
			continue
		var probe := raw_probe as Dictionary
		var offset := _vector3_from_value(probe.get("offset", Vector3.ZERO), Vector3.ZERO)
		var sample_pos := anchor_pos + _voxelize_offset(offset, gvf.voxel_size)
		if not gvf.is_in_bounds(sample_pos):
			continue
		var weight := maxf(float(probe.get("weight", 1.0)), 0.000001)
		var probe_score := score_probe(sample_pos, probe, gvf, target_occupancy, target_color)
		total_score += probe_score * weight
		total_weight += weight
	return total_score / maxf(total_weight, 0.000001)


func score_probe(
	p: Vector3i,
	probe: Dictionary,
	gvf: GlobalVoxelField,
	target_occupancy: PackedFloat32Array,
	target_color: PackedColorArray
) -> float:
	var idx := gvf.voxel_index(p)
	var flags := int(probe.get("flags", SemanticProbeProfileScript.FLAG_COLOR | SemanticProbeProfileScript.FLAG_COMPLEXITY))
	var kind := str(probe.get("kind", "positive"))
	var sample_color := target_color[idx] if idx < target_color.size() else Color(0.0, 0.0, 0.0, 0.0)
	var sample_complexity := sample_color.a
	var sample_collision := _target_value(target_occupancy, idx)
	var sample_scene := gvf.scene_occupancy[idx]
	if (flags & SemanticProbeProfileScript.FLAG_EMPTY) != 0 or kind == "negative":
		return clampf(1.0 - maxf(sample_complexity, maxf(sample_collision, sample_scene)), 0.0, 1.0)
	if (flags & SemanticProbeProfileScript.FLAG_SUPPORT) != 0:
		var below := p + Vector3i(0, -1, 0)
		var support := 0.0
		if gvf.is_in_bounds(below):
			support = maxf(gvf.get_scene(below), gvf.get_collision(below))
		return clampf(support, 0.0, 1.0)
	var expected_color := _color_from_value(probe.get("expected_color", Color.WHITE), Color.WHITE)
	var expected_complexity := clampf(float(probe.get("expected_complexity", expected_color.a)), 0.0, 1.0)
	var expected_collision := clampf(float(probe.get("expected_collision", 0.0)), 0.0, 1.0)
	var score := 0.0
	var weight_sum := 0.0
	if (flags & SemanticProbeProfileScript.FLAG_COLOR) != 0:
		var rgb_distance := Vector3(sample_color.r, sample_color.g, sample_color.b).distance_to(Vector3(expected_color.r, expected_color.g, expected_color.b))
		score += clampf(1.0 - rgb_distance / sqrt(3.0), 0.0, 1.0)
		weight_sum += 1.0
	if (flags & SemanticProbeProfileScript.FLAG_COMPLEXITY) != 0:
		score += clampf(1.0 - absf(sample_complexity - expected_complexity), 0.0, 1.0)
		weight_sum += 1.0
	if (flags & SemanticProbeProfileScript.FLAG_COLLISION) != 0:
		score += clampf(1.0 - absf(sample_collision - expected_collision), 0.0, 1.0)
		weight_sum += 1.0
	return score / maxf(weight_sum, 0.000001)


func reduce_to_tiles(
	anchors: Array[Dictionary],
	anchor_results: Dictionary,
	autoobjects: Array,
	gvf: GlobalVoxelField
) -> Dictionary:
	var votes: Dictionary = {}
	for anchor_id in anchor_results:
		var aid := int(anchor_id)
		if aid < 0 or aid >= anchors.size():
			continue
		var anchor := anchors[aid]
		var candidates: Array = anchor_results[anchor_id]
		for raw_candidate in candidates:
			if not raw_candidate is Dictionary:
				continue
			var candidate := raw_candidate as Dictionary
			var obj_idx := int(candidate.get("autoobject_idx", -1))
			if obj_idx < 0 or obj_idx >= autoobjects.size():
				continue
			var autoobject := autoobjects[obj_idx] as AutoObject
			if autoobject == null:
				continue
			if not votes.has(obj_idx):
				votes[obj_idx] = {}
			var tile_map: Dictionary = votes[obj_idx]
			var affected_tiles := _asset_footprint_tiles(anchor, autoobject, gvf)
			for tile_id in affected_tiles:
				tile_map[tile_id] = float(tile_map.get(tile_id, 0.0)) + float(candidate.get("score", 0.0))
	var result: Dictionary = {}
	for obj_idx in votes:
		var entries: Array[Dictionary] = []
		var tile_map: Dictionary = votes[obj_idx]
		for tile_id in tile_map:
			entries.append({"tile_id": int(tile_id), "score": float(tile_map[tile_id])})
		entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.get("score", 0.0)) > float(b.get("score", 0.0)))
		var tile_positions: Array[Vector3i] = []
		for entry in entries:
			tile_positions.append(gvf.tile_id_to_pos(int(entry.get("tile_id", -1))))
		result[obj_idx] = tile_positions
	return result


func _try_append_ground_anchor(
	anchors: Array[Dictionary],
	seen: Dictionary,
	gvf: GlobalVoxelField,
	target_occupancy: PackedFloat32Array,
	p: Vector3i,
	tile_id: int
) -> void:
	if not gvf.is_in_bounds(p):
		return
	var idx := gvf.voxel_index(p)
	var scene_value := gvf.scene_occupancy[idx]
	var collision_value := gvf.collision_occupancy[idx]
	var target_value := _target_value(target_occupancy, idx)
	if scene_value > max_scene_occupancy:
		return
	if collision_value > max_collision_occupancy:
		return
	if target_value < min_target_interest:
		return
	var below := p + Vector3i(0, -1, 0)
	var support := 0.0
	if gvf.is_in_bounds(below):
		support = maxf(gvf.get_scene(below), gvf.get_collision(below))
	if support < min_support:
		return
	_append_anchor(anchors, seen, p, tile_id, ANCHOR_KIND_GROUND, support, target_value)


func _try_append_target_top_anchor(
	anchors: Array[Dictionary],
	seen: Dictionary,
	gvf: GlobalVoxelField,
	target_occupancy: PackedFloat32Array,
	x: int,
	z: int
) -> void:
	for y in range(gvf.grid_size.y - 1, -1, -1):
		var p := Vector3i(x, y, z)
		if not gvf.is_in_bounds(p):
			continue
		var idx := gvf.voxel_index(p)
		var target_value := _target_value(target_occupancy, idx)
		if target_value < min_target_interest:
			continue
		var scene_value := gvf.scene_occupancy[idx]
		var collision_value := gvf.collision_occupancy[idx]
		if scene_value > max_scene_occupancy:
			return
		if collision_value > max_collision_occupancy:
			return
		var below := p + Vector3i(0, -1, 0)
		var support := 0.0
		if gvf.is_in_bounds(below):
			support = maxf(gvf.get_scene(below), gvf.get_collision(below))
		_append_anchor(anchors, seen, p, gvf._tile_id(p), ANCHOR_KIND_TARGET_TOP, support, target_value)
		return


func _append_anchor(
	anchors: Array[Dictionary],
	seen: Dictionary,
	p: Vector3i,
	tile_id: int,
	anchor_kind: String,
	support: float,
	target_value: float
) -> void:
	var key := "%d:%d:%d:%s" % [p.x, p.y, p.z, anchor_kind]
	if seen.has(key):
		return
	seen[key] = true
	anchors.append({
		"id": anchors.size(),
		"voxel_pos": p,
		"tile_id": tile_id,
		"anchor_kind": anchor_kind,
		"support": support,
		"target_value": target_value,
	})


func _asset_footprint_tiles(anchor: Dictionary, autoobject: AutoObject, gvf: GlobalVoxelField) -> Array[int]:
	var anchor_pos: Vector3i = anchor.get("voxel_pos", Vector3i.ZERO)
	var anchor_kind := str(anchor.get("anchor_kind", ANCHOR_KIND_GROUND))
	var aabb := autoobject.get_anchor_relative_footprint_aabb(anchor_kind)
	var min_p := _clamp_voxel_pos(anchor_pos + _voxelize_offset(aabb.position, gvf.voxel_size), gvf)
	var max_p := _clamp_voxel_pos(anchor_pos + _voxelize_offset(aabb.position + aabb.size, gvf.voxel_size), gvf)
	var min_tile := _voxel_to_tile_coord(min_p)
	var max_tile := _voxel_to_tile_coord(max_p)
	var tiles: Array[int] = []
	var seen_tiles: Dictionary = {}
	for tz in range(min_tile.z, max_tile.z + 1):
		for ty in range(min_tile.y, max_tile.y + 1):
			for tx in range(min_tile.x, max_tile.x + 1):
				var tile_origin := Vector3i(tx, ty, tz) * TILE_SIZE
				var tile_id := gvf._tile_id(tile_origin)
				if seen_tiles.has(tile_id):
					continue
				seen_tiles[tile_id] = true
				tiles.append(tile_id)
	if tiles.is_empty():
		tiles.append(int(anchor.get("tile_id", 0)))
	return tiles


func _all_tile_ids(gvf: GlobalVoxelField) -> Array[int]:
	var total := int(gvf.get_stats().get("total_tiles", 0))
	var result: Array[int] = []
	for tile_id in range(total):
		result.append(tile_id)
	return result


func _count_anchor_kind(anchors: Array[Dictionary], anchor_kind: String) -> int:
	var count := 0
	for anchor in anchors:
		if str(anchor.get("anchor_kind", "")) == anchor_kind:
			count += 1
	return count


func _probe_cache_key(obj_idx: int, anchor_kind: String) -> String:
	return "%d:%s" % [obj_idx, anchor_kind]


func _target_value(target_occupancy: PackedFloat32Array, idx: int) -> float:
	return target_occupancy[idx] if idx >= 0 and idx < target_occupancy.size() else 0.0


func _voxelize_offset(offset: Vector3, voxel_size: Vector3) -> Vector3i:
	return Vector3i(
		roundi(offset.x / maxf(voxel_size.x, 0.0001)),
		roundi(offset.y / maxf(voxel_size.y, 0.0001)),
		roundi(offset.z / maxf(voxel_size.z, 0.0001))
	)


func _clamp_voxel_pos(p: Vector3i, gvf: GlobalVoxelField) -> Vector3i:
	return Vector3i(
		clampi(p.x, 0, gvf.grid_size.x - 1),
		clampi(p.y, 0, gvf.grid_size.y - 1),
		clampi(p.z, 0, gvf.grid_size.z - 1)
	)


func _voxel_to_tile_coord(p: Vector3i) -> Vector3i:
	return Vector3i(
		floori(float(p.x) / float(TILE_SIZE)),
		floori(float(p.y) / float(TILE_SIZE)),
		floori(float(p.z) / float(TILE_SIZE))
	)


func _vector3_from_value(value, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	if value is Vector3:
		return value as Vector3
	if value is Array:
		var arr := value as Array
		if arr.size() >= 3:
			return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
	if value is Dictionary:
		var dict := value as Dictionary
		return Vector3(float(dict.get("x", fallback.x)), float(dict.get("y", fallback.y)), float(dict.get("z", fallback.z)))
	return fallback


func _color_from_value(value, fallback: Color = Color.WHITE) -> Color:
	if value is Color:
		return value as Color
	if value is Array:
		var arr := value as Array
		if arr.size() >= 3:
			var alpha := float(arr[3]) if arr.size() >= 4 else fallback.a
			return Color(float(arr[0]), float(arr[1]), float(arr[2]), alpha)
	if value is Dictionary:
		var dict := value as Dictionary
		return Color(float(dict.get("r", fallback.r)), float(dict.get("g", fallback.g)), float(dict.get("b", fallback.b)), float(dict.get("a", fallback.a)))
	return fallback
