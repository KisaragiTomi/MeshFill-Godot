class_name VoxelPlacementGenerator
extends "res://scripts/godot_compute_shader_base.gd"
## Minimal GPU prototype for 3D voxel-space object placement.
##
## This is intentionally independent from the current 2.5D CliffGenerator path:
## callers provide compact scene/collision occupancy buffers and a simplified
## asset footprint, then receive compact placement records and stamped occupancy.

const TILE_SIZE := 8
const FOOTPRINT_CAPACITY := 128
const RECORD_STRIDE := 4
const DELTA_STRIDE := 2
const FLAG_SUPPORT := 1
const FLAG_CLEARANCE := 2
const NUM_DEBUG_CHANNELS := 8
const DEBUG_CHANNEL_NAMES: PackedStringArray = [
	"target_coverage",
	"target_value_fit",
	"target_color_fit",
	"target_density",
	"placement_score",
	"support_ratio",
	"solid_collision",
	"clearance_overlap",
]
const DEPRECATED_SENCE_LAYER_VOXEL_KEY := "SenceLayerVoxel"
const ASSET_VOXEL_RECORD_CONFIG_KEYS := [
	"asset",
	"base_pixel",
	"capture_size",
	"create_asset_voxel_record",
	"defer_blend",
	"generation_tick",
	"group",
	"groups",
	"material",
	"mesh",
	"name",
	"placement_mesh",
	"record_id",
	"texture_resolution",
	"vegetation_exclusion",
	"volume_xz_resolution",
	"asset_voxel_record",
	"world_capture_size",
]

var top_k: int = 4
var result_capacity: int = 8
var solid_threshold: float = 192.0 / 255.0
var collision_limit: float = 0.0
var min_support_ratio: float = 1.0
var clearance_limit: float = 0.0
var support_weight: float = 10.0
var collision_penalty: float = 100.0
var overlap_penalty: float = 1.0
var clearance_penalty: float = 10.0
var min_distance_voxels: float = 2.0
var scene_write_scale: float = 1.0
var collision_write_scale: float = 1.0
var asset_index: int = 0
var rotation_index: int = 0
var scale_index: int = 0
var asset_color: Color = Color.WHITE

var _shader_score: RID
var _shader_reduce: RID
var _shader_stamp: RID
var _pipeline_score: RID
var _pipeline_reduce: RID
var _pipeline_stamp: RID


static func _legacy_create_asset_voxel_record_key() -> String:
	return "create_" + AutoObject.legacy_asset_voxel_record_key()


static func _deprecated_create_asset_voxel_record_key() -> String:
	return "create_" + AutoObject.deprecated_asset_voxel_record_key()


static func _get_config_asset_voxel_record(config: Dictionary) -> Dictionary:
	for key in AutoObject.asset_voxel_record_meta_keys():
		var raw_record = config.get(key, {})
		if raw_record is Dictionary:
			var record := raw_record as Dictionary
			if not record.is_empty():
				return record.duplicate(true)
	return {}


static func _should_create_asset_voxel_record(config: Dictionary) -> bool:
	return bool(config.get(
		"create_asset_voxel_record",
		config.get(_deprecated_create_asset_voxel_record_key(), config.get(_legacy_create_asset_voxel_record_key(), false))
	))


# ---------------------------------------------------------------------------
# Multi-asset sequential pipeline
# ---------------------------------------------------------------------------
# Each asset_def: {collision_voxels, result_capacity, min_distance_voxels,
#                  settings, priority, weight}
#   priority (int, default 0): higher = processed first
#   weight (float, default 1.0): weighted random shuffle within same priority
# common_settings may contain:
#   global_quota (int, default -1 = unlimited): max total placements
#   seed (int, default -1 = nondeterministic): RNG seed for weight shuffle
#   auto_object_manager (AutoObjectManager): optional same-type exclusion gate
# Returns: {asset_results: [{asset_index, results, world_results, result_count}],
#           scene_occupancy_out, collision_occupancy_out, total_placed,
#           processing_order: [original indices in execution order]}

func run_multi_asset(
	scene_occupancy: PackedFloat32Array,
	collision_occupancy: PackedFloat32Array,
	asset_defs: Array,
	grid_size: Vector3i,
	voxel_size: Vector3,
	grid_origin: Vector3 = Vector3.ZERO,
	common_settings: Dictionary = {}
) -> Dictionary:
	var current_scene := scene_occupancy.duplicate()
	var current_collision := collision_occupancy.duplicate()
	var total_placed := 0
	var global_quota := int(common_settings.get("global_quota", -1))

	var order := _sort_asset_defs_by_priority_weight(asset_defs, common_settings)
	var result_by_index: Dictionary = {}

	for slot in order:
		var orig_idx: int = slot
		var asset_def: Dictionary = asset_defs[orig_idx]

		if global_quota >= 0 and total_placed >= global_quota:
			result_by_index[orig_idx] = {
				"asset_index": orig_idx, "results": [], "world_results": [],
				"result_count": 0, "stamp_deltas": [], "skipped_quota": true,
			}
			continue

		var cv: Array = asset_def.get("collision_voxels", [])
		if cv.is_empty():
			result_by_index[orig_idx] = {
				"asset_index": orig_idx, "results": [], "world_results": [], "result_count": 0,
			}
			continue

		var base_footprint := bake_footprint_from_collision_voxels(
			cv, voxel_size,
			bool(asset_def.get("add_support", true)),
			int(asset_def.get("clearance_slices", 1)))
		if base_footprint.is_empty():
			result_by_index[orig_idx] = {
				"asset_index": orig_idx, "results": [], "world_results": [], "result_count": 0,
			}
			continue

		var per_asset_settings := common_settings.duplicate(true)
		var overrides: Dictionary = asset_def.get("settings", {})
		for key in overrides:
			per_asset_settings[key] = overrides[key]
		var routed_regions_by_asset: Dictionary = common_settings.get("candidate_voxel_sparses_by_asset", {})
		if asset_def.has("candidate_voxel_sparses"):
			per_asset_settings["candidate_voxel_sparses"] = asset_def.candidate_voxel_sparses
		elif common_settings.has("candidate_voxel_sparses_by_asset"):
			var route_key = orig_idx if routed_regions_by_asset.has(orig_idx) else str(orig_idx)
			var routed_regions = routed_regions_by_asset.get(route_key, [])
			if routed_regions.is_empty():
				result_by_index[orig_idx] = {
					"asset_index": orig_idx, "results": [], "world_results": [], "result_count": 0,
					"stamp_deltas": [],
					"skipped_prefilter": true,
				}
				continue
			per_asset_settings["candidate_voxel_sparses"] = routed_regions
		if asset_def.has("result_capacity"):
			per_asset_settings["result_capacity"] = int(asset_def.result_capacity)
		if asset_def.has("min_distance_voxels"):
			per_asset_settings["min_distance_voxels"] = float(asset_def.min_distance_voxels)
		per_asset_settings["asset_index"] = orig_idx
		var same_type_filter := _filter_candidate_voxel_sparses_by_same_type_exclusion(
			per_asset_settings,
			asset_def,
			grid_size,
			voxel_size,
			grid_origin
		)
		if not same_type_filter.is_empty():
			var kept_regions: Array = same_type_filter.get("candidate_voxel_sparses", [])
			if kept_regions.is_empty():
				result_by_index[orig_idx] = {
					"asset_index": orig_idx,
					"results": [], "world_results": [], "result_count": 0,
					"stamp_deltas": [], "skipped_same_type_exclusion": true,
					"same_type_exclusion": same_type_filter,
				}
				continue
			per_asset_settings["candidate_voxel_sparses"] = kept_regions
			per_asset_settings["same_type_exclusion"] = same_type_filter

		if global_quota >= 0:
			var remaining := global_quota - total_placed
			var cap := int(per_asset_settings.get("result_capacity", result_capacity))
			per_asset_settings["result_capacity"] = mini(cap, remaining)

		var pivot_variants = load("res://scripts/auto_voxel_descriptor.gd").normalize_pivot_variants(asset_def.get("pivot_variants", [{"name": "bottom", "offset": Vector3.ZERO, "score_bias": 0.0}]))
		var best_gpu_out: Dictionary = {}
		var best_pivot: Dictionary = {}
		var best_pivot_score := -INF
		for pivot in pivot_variants:
			var pivot_offset := _vector3_from_value(pivot.get("offset", Vector3.ZERO), Vector3.ZERO)
			var pivot_voxels := _world_offset_to_voxels(pivot_offset, voxel_size)
			var footprint := apply_pivot_to_footprint(base_footprint, pivot_voxels)
			var gpu_out := run_minimal(current_scene, current_collision, footprint, grid_size, per_asset_settings)
			var pivot_score := _placement_output_score(gpu_out) + float(pivot.get("score_bias", 0.0))
			if not gpu_out.is_empty() and pivot_score > best_pivot_score:
				best_gpu_out = gpu_out
				best_pivot = pivot
				best_pivot_score = pivot_score

		if best_gpu_out.is_empty():
			result_by_index[orig_idx] = {
				"asset_index": orig_idx, "results": [], "world_results": [], "result_count": 0,
			}
			continue

		var count := int(best_gpu_out.get("result_count", 0))
		var raw_results: Array = best_gpu_out.get("results", [])
		var world := results_to_world(raw_results, voxel_size, grid_origin, 24, best_pivot)

		current_scene = best_gpu_out.get("scene_occupancy_out", current_scene)
		current_collision = best_gpu_out.get("collision_occupancy_out", current_collision)
		total_placed += count

		result_by_index[orig_idx] = {
			"asset_index": orig_idx,
			"results": raw_results,
			"world_results": world,
			"result_count": count,
			"stamp_deltas": best_gpu_out.get("stamp_deltas", []),
			"pivot_variant": best_pivot,
			"pivot_variant_count": pivot_variants.size(),
			"same_type_exclusion": per_asset_settings.get("same_type_exclusion", {}),
		}

	var asset_results: Array[Dictionary] = []
	for i in range(asset_defs.size()):
		asset_results.append(result_by_index.get(i, {
			"asset_index": i, "results": [], "world_results": [], "result_count": 0,
		}))

	return {
		"asset_results": asset_results,
		"scene_occupancy_out": current_scene,
		"collision_occupancy_out": current_collision,
		"total_placed": total_placed,
		"processing_order": order,
	}


static func _sort_asset_defs_by_priority_weight(
	asset_defs: Array, common_settings: Dictionary
) -> Array[int]:
	if asset_defs.is_empty():
		return []

	var entries: Array[Dictionary] = []
	for i in range(asset_defs.size()):
		var d: Dictionary = asset_defs[i]
		entries.append({
			"index": i,
			"priority": int(d.get("priority", 0)),
			"weight": maxf(float(d.get("weight", 1.0)), 0.0001),
		})

	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.priority) > int(b.priority))

	var rng := RandomNumberGenerator.new()
	var rng_seed := int(common_settings.get("seed", -1))
	if rng_seed >= 0:
		rng.seed = rng_seed
	else:
		rng.randomize()

	var result: Array[int] = []
	var group_start := 0
	while group_start < entries.size():
		var group_priority := int(entries[group_start].priority)
		var group_end := group_start + 1
		while group_end < entries.size() and int(entries[group_end].priority) == group_priority:
			group_end += 1

		if group_end - group_start <= 1:
			result.append(int(entries[group_start].index))
		else:
			var group: Array[Dictionary] = []
			for gi in range(group_start, group_end):
				group.append(entries[gi])
			var shuffled := _weighted_shuffle(group, rng)
			for s in shuffled:
				result.append(int(s.index))

		group_start = group_end
	return result


static func _filter_candidate_voxel_sparses_by_same_type_exclusion(
	per_asset_settings: Dictionary,
	asset_def: Dictionary,
	grid_size: Vector3i,
	voxel_size: Vector3,
	grid_origin: Vector3
) -> Dictionary:
	var manager = per_asset_settings.get("auto_object_manager", null)
	if manager == null or not manager.has_method("find_same_type_exclusion"):
		return {}
	if not bool(per_asset_settings.get("enable_same_type_exclusion", true)):
		return {}

	var type_info := _asset_type_info(asset_def)
	var object_type := str(type_info.get("object_type", ""))
	var object_subtype := str(type_info.get("object_subtype", ""))
	if object_type.is_empty() and object_subtype.is_empty():
		return {}

	var candidate_spacing := _asset_min_spacing(asset_def, voxel_size)
	if candidate_spacing <= 0.0:
		return {}

	var tile_counts := Vector3i(
		ceili(float(grid_size.x) / float(TILE_SIZE)),
		ceili(float(grid_size.y) / float(TILE_SIZE)),
		ceili(float(grid_size.z) / float(TILE_SIZE))
	)
	var tile_count := tile_counts.x * tile_counts.y * tile_counts.z
	var raw_regions: Array = per_asset_settings.get("candidate_voxel_sparses", [])
	if raw_regions.is_empty():
		for tile_id in range(tile_count):
			raw_regions.append(_voxel_sparse_to_tile_pos(tile_id, tile_counts))
	var filtered_regions: Array = []
	var blocked_count := 0
	var first_block: Dictionary = {}
	var seen := {}
	var manager_cell_size := float(manager.get("spatial_cell_size"))
	var search_radius := float(per_asset_settings.get("same_type_exclusion_search_radius", -1.0))
	var placement_search_radius := _normalize_search_radius(per_asset_settings.get("search_radius", Vector3i.ZERO))

	for raw_region in raw_regions:
		var tile_pos := _voxel_sparse_to_tile_pos(raw_region, tile_counts)
		var tile_id := _voxel_sparse_to_tile_id(tile_pos, tile_counts)
		if tile_id < 0 or tile_id >= tile_count or seen.has(tile_id):
			continue
		seen[tile_id] = true
		var conflict := _find_same_type_voxel_sparse_exclusion(
			manager,
			tile_pos,
			grid_size,
			voxel_size,
			grid_origin,
			placement_search_radius,
			object_type,
			object_subtype,
			candidate_spacing,
			search_radius,
			manager_cell_size
		)
		if bool(conflict.get("blocked", false)):
			blocked_count += 1
			if first_block.is_empty():
				first_block = conflict.duplicate(true)
				first_block["voxel_sparse"] = tile_pos
				first_block.erase("neighbor")
			continue
		filtered_regions.append(tile_pos)

	if blocked_count <= 0:
		return {}
	return {
		"candidate_voxel_sparses": filtered_regions,
		"input_voxel_sparse_count": seen.size(),
		"kept_voxel_sparse_count": filtered_regions.size(),
		"blocked_voxel_sparse_count": blocked_count,
		"object_type": object_type,
		"object_subtype": object_subtype,
		"candidate_min_spacing": candidate_spacing,
		"search_radius": search_radius if search_radius >= 0.0 else "auto",
		"first_block": first_block,
	}


static func _find_same_type_voxel_sparse_exclusion(
	manager: Object,
	tile_pos: Vector3i,
	grid_size: Vector3i,
	voxel_size: Vector3,
	grid_origin: Vector3,
	placement_search_radius: Vector3i,
	object_type: String,
	object_subtype: String,
	candidate_spacing: float,
	search_radius: float,
	manager_cell_size: float
) -> Dictionary:
	if not manager.has_method("query_same_type_objects"):
		return {}

	var bounds := _voxel_sparse_world_xz_bounds(tile_pos, grid_size, voxel_size, grid_origin, placement_search_radius)
	var center: Vector3 = bounds.center
	var half_diag := Vector2(float(bounds.max_x) - center.x, float(bounds.max_z) - center.z).length()
	var query_radius := search_radius
	if query_radius < 0.0:
		query_radius = half_diag + candidate_spacing + manager_cell_size
	var neighbors: Array = manager.call(
		"query_same_type_objects",
		center,
		query_radius,
		object_type,
		object_subtype,
		true
	)
	for raw_neighbor in neighbors:
		if not raw_neighbor is AutoObject:
			continue
		var neighbor := raw_neighbor as AutoObject
		var record: Dictionary = manager.call("get_record_by_instance_id", neighbor.refresh_instance_id())
		var neighbor_pos := neighbor.global_position if neighbor.is_inside_tree() else neighbor.position
		var closest_x := clampf(neighbor_pos.x, float(bounds.min_x), float(bounds.max_x))
		var closest_z := clampf(neighbor_pos.z, float(bounds.min_z), float(bounds.max_z))
		var distance := Vector2(neighbor_pos.x, neighbor_pos.z).distance_to(Vector2(closest_x, closest_z))
		var neighbor_spacing := maxf(float(record.get("min_spacing", neighbor.min_spacing)), neighbor.min_spacing)
		var required_distance := candidate_spacing + neighbor_spacing
		if required_distance <= 0.0:
			continue
		if distance < required_distance:
			return {
				"blocked": true,
				"neighbor_instance_id": neighbor.refresh_instance_id(),
				"neighbor_id": str(record.get("id", neighbor.auto_id)),
				"distance": distance,
				"required_distance": required_distance,
				"candidate_min_spacing": candidate_spacing,
				"neighbor_min_spacing": neighbor_spacing,
				"object_type": object_type,
				"object_subtype": object_subtype,
			}
	return {"blocked": false}


static func _asset_type_info(asset_def: Dictionary) -> Dictionary:
	var object_type := str(asset_def.get("object_type", ""))
	var object_subtype := str(asset_def.get("object_subtype", asset_def.get("node_class", "")))
	var asset = asset_def.get("asset", null)
	if asset != null:
		if object_type.is_empty():
			object_type = str(asset.get("object_type")) if _object_has_property(asset, "object_type") else ""
		if object_subtype.is_empty():
			object_subtype = str(asset.get("object_subtype")) if _object_has_property(asset, "object_subtype") else ""
		if object_type.is_empty() and asset is AutoRock:
			object_type = "rock"
		elif object_type.is_empty() and asset is AutoVegetationAsset:
			object_type = "vegetation"
		elif object_type.is_empty() and asset is AutoVegetation:
			object_type = "vegetation"
	if object_type.is_empty() and not object_subtype.is_empty():
		object_type = "rock" if ["rock", "cliff"].has(object_subtype) else "vegetation"
	return {
		"object_type": object_type.strip_edges().to_lower(),
		"object_subtype": object_subtype.strip_edges().to_lower(),
	}


static func _asset_min_spacing(asset_def: Dictionary, voxel_size: Vector3) -> float:
	if asset_def.has("min_spacing"):
		return maxf(float(asset_def.get("min_spacing", 0.0)), 0.0)
	if asset_def.has("minimum_spacing"):
		return maxf(float(asset_def.get("minimum_spacing", 0.0)), 0.0)
	var asset = asset_def.get("asset", null)
	if asset != null and _object_has_property(asset, "min_spacing"):
		return maxf(float(asset.get("min_spacing")), 0.0)
	if asset is AutoVegetationAsset:
		return maxf(float((asset as AutoVegetationAsset).scatter_min_distance) * 0.5, 0.0)
	return _collision_xz_radius_from_voxels(asset_def.get("collision_voxels", []), voxel_size)


static func _collision_xz_radius_from_voxels(collision_voxels: Array, voxel_size: Vector3) -> float:
	var result := 0.0
	for raw_collision in collision_voxels:
		if not raw_collision is Dictionary:
			continue
		var collision := raw_collision as Dictionary
		var radius := maxf(float(collision.get("radius", 0.0)), 0.0)
		var dilation := maxf(float(collision.get("dilation_radius", 0.0)), 0.0)
		var offset := _vector3_from_value(collision.get("offset", collision.get("center", collision.get("position", Vector3.ZERO))), Vector3.ZERO)
		var half_extents := _vector3_from_value(collision.get("half_extents", Vector3.ZERO), Vector3.ZERO)
		if half_extents.length_squared() <= 0.0001:
			var size := _vector3_from_value(collision.get("size", Vector3.ZERO), Vector3.ZERO)
			if size.length_squared() > 0.0001:
				half_extents = size * 0.5
		var shape_radius := radius
		if half_extents.length_squared() > 0.0001:
			shape_radius = Vector2(absf(half_extents.x), absf(half_extents.z)).length()
		result = maxf(result, Vector2(offset.x, offset.z).length() + shape_radius + dilation)
	if result <= 0.0:
		result = maxf(voxel_size.x, voxel_size.z)
	return result


static func _voxel_sparse_to_tile_pos(tile: Variant, tile_counts: Vector3i) -> Vector3i:
	if tile is Vector3i:
		return tile as Vector3i
	if tile is Vector3:
		var v := tile as Vector3
		return Vector3i(int(v.x), int(v.y), int(v.z))
	var tile_id := int(tile)
	var tx := tile_id % tile_counts.x
	var ty := (tile_id / tile_counts.x) % tile_counts.y
	var tz := tile_id / (tile_counts.x * tile_counts.y)
	return Vector3i(tx, ty, tz)


static func _voxel_sparse_tile_world_center(
	tile_pos: Vector3i,
	grid_size: Vector3i,
	voxel_size: Vector3,
	grid_origin: Vector3
) -> Vector3:
	var vmin := Vector3i(
		tile_pos.x * TILE_SIZE,
		tile_pos.y * TILE_SIZE,
		tile_pos.z * TILE_SIZE
	)
	var vmax := Vector3i(
		mini(vmin.x + TILE_SIZE, grid_size.x),
		mini(vmin.y + TILE_SIZE, grid_size.y),
		mini(vmin.z + TILE_SIZE, grid_size.z)
	)
	var center_voxel := Vector3(
		(float(vmin.x) + float(vmax.x)) * 0.5,
		(float(vmin.y) + float(vmax.y)) * 0.5,
		(float(vmin.z) + float(vmax.z)) * 0.5
	)
	return grid_origin + Vector3(
		center_voxel.x * voxel_size.x,
		center_voxel.y * voxel_size.y,
		center_voxel.z * voxel_size.z
	)


static func _voxel_sparse_world_xz_bounds(
	tile_pos: Vector3i,
	grid_size: Vector3i,
	voxel_size: Vector3,
	grid_origin: Vector3,
	search_radius: Vector3i = Vector3i.ZERO
) -> Dictionary:
	var vmin := Vector3i(
		maxi(tile_pos.x * TILE_SIZE - search_radius.x, 0),
		maxi(tile_pos.y * TILE_SIZE - search_radius.y, 0),
		maxi(tile_pos.z * TILE_SIZE - search_radius.z, 0)
	)
	var vmax := Vector3i(
		mini((tile_pos.x + 1) * TILE_SIZE + search_radius.x, grid_size.x),
		mini((tile_pos.y + 1) * TILE_SIZE + search_radius.y, grid_size.y),
		mini((tile_pos.z + 1) * TILE_SIZE + search_radius.z, grid_size.z)
	)
	var min_x := grid_origin.x + float(vmin.x) * voxel_size.x
	var max_x := grid_origin.x + float(vmax.x) * voxel_size.x
	var min_z := grid_origin.z + float(vmin.z) * voxel_size.z
	var max_z := grid_origin.z + float(vmax.z) * voxel_size.z
	var center := Vector3((min_x + max_x) * 0.5, grid_origin.y, (min_z + max_z) * 0.5)
	return {
		"center": center,
		"min_x": min_x,
		"max_x": max_x,
		"min_z": min_z,
		"max_z": max_z,
	}


static func _object_has_property(object: Object, property_name: String) -> bool:
	if object == null:
		return false
	for property in object.get_property_list():
		if str((property as Dictionary).get("name", "")) == property_name:
			return true
	return false


static func _weighted_shuffle(
	group: Array[Dictionary], rng: RandomNumberGenerator
) -> Array[Dictionary]:
	var remaining := group.duplicate()
	var result: Array[Dictionary] = []
	while remaining.size() > 1:
		var total_weight := 0.0
		for e in remaining:
			total_weight += float(e.weight)
		var pick := rng.randf() * total_weight
		var cumulative := 0.0
		var chosen_idx := 0
		for j in range(remaining.size()):
			cumulative += float(remaining[j].weight)
			if cumulative >= pick:
				chosen_idx = j
				break
		result.append(remaining[chosen_idx])
		remaining.remove_at(chosen_idx)
	if not remaining.is_empty():
		result.append(remaining[0])
	return result



static func apply_pivot_to_footprint(footprint: Array, pivot_voxels: Vector3i) -> Array[Dictionary]:
	if pivot_voxels == Vector3i.ZERO:
		var copied: Array[Dictionary] = []
		for e in footprint:
			if e is Dictionary:
				copied.append((e as Dictionary).duplicate(true))
		return copied
	var shifted: Array[Dictionary] = []
	for e in footprint:
		if not e is Dictionary:
			continue
		var entry := (e as Dictionary).duplicate(true)
		entry["local_pos"] = _vector3i_from_value(entry.get("local_pos", Vector3i.ZERO), Vector3i.ZERO) - pivot_voxels
		shifted.append(entry)
	return shifted


static func _world_offset_to_voxels(offset: Vector3, voxel_size: Vector3) -> Vector3i:
	return Vector3i(
		roundi(offset.x / maxf(voxel_size.x, 0.0001)),
		roundi(offset.y / maxf(voxel_size.y, 0.0001)),
		roundi(offset.z / maxf(voxel_size.z, 0.0001))
	)


static func _placement_output_score(gpu_out: Dictionary) -> float:
	if gpu_out.is_empty():
		return -INF
	var count := int(gpu_out.get("result_count", 0))
	if count <= 0:
		return -INF
	var score := 0.0
	var results: Array = gpu_out.get("results", [])
	for raw in results:
		if raw is Dictionary and bool((raw as Dictionary).get("valid", false)):
			score += float((raw as Dictionary).get("score", 0.0))
	return score


static func _vector3_from_value(value, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	if value is Vector3:
		return value as Vector3
	if value is Array:
		var arr := value as Array
		if arr.size() >= 3:
			return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
	if value is Dictionary:
		var d := value as Dictionary
		return Vector3(float(d.get("x", fallback.x)), float(d.get("y", fallback.y)), float(d.get("z", fallback.z)))
	return fallback


static func _vector3i_from_value(value, fallback: Vector3i = Vector3i.ZERO) -> Vector3i:
	if value is Vector3i:
		return value as Vector3i
	if value is Vector3:
		var v := value as Vector3
		return Vector3i(roundi(v.x), roundi(v.y), roundi(v.z))
	if value is Array:
		var arr := value as Array
		if arr.size() >= 3:
			return Vector3i(int(arr[0]), int(arr[1]), int(arr[2]))
	if value is Dictionary:
		var d := value as Dictionary
		return Vector3i(int(d.get("x", fallback.x)), int(d.get("y", fallback.y)), int(d.get("z", fallback.z)))
	return fallback


# ---------------------------------------------------------------------------
# Instantiation — create AutoObject nodes from GPU placement results
# ---------------------------------------------------------------------------
# node_class: "canopy_tree", "midstory_tree", "bush", "grass", "rock", "vegetation"

static func instantiate_placement(
	world_result: Dictionary,
	node_class: String,
	placement_mesh: Mesh,
	extra_config: Dictionary = {}
) -> AutoObject:
	var node: AutoObject = _create_node_for_class(node_class)
	var cfg := extra_config.duplicate(true)

	cfg["position"] = world_result.get("position", Vector3.ZERO)
	cfg["rotation_mode"] = "Y"
	cfg["rotation_degrees"] = world_result.get("rotation_degrees", Vector3.ZERO)
	cfg["scale"] = world_result.get("scale", Vector3.ONE)
	cfg["mesh"] = placement_mesh
	cfg["auto_source"] = "voxel_placement"

	if not cfg.has("name"):
		cfg["name"] = "%s_%d" % [node_class, int(world_result.get("asset_index", 0))]

	var asset = cfg.get("asset", null)
	if node is AutoRock and asset is AutoRock:
		AutoAssetFactory.configure_rock_instance(node as AutoRock, asset as AutoRock, cfg)
	else:
		_configure_node(node, node_class, cfg)

	var record := _get_config_asset_voxel_record(cfg)
	if not record.is_empty():
		record = attach_placement_asset_voxel_record(node, record)
	elif _should_create_asset_voxel_record(cfg):
		record = make_placement_asset_voxel_record(node, world_result, node_class, cfg)
		if not record.is_empty():
			record = attach_placement_asset_voxel_record(node, record)

	var target = cfg.get("vegetation_exclusion", null)
	if not record.is_empty() and target is VegetationExclusion:
		var applied := (target as VegetationExclusion).apply_mesh_asset_voxel_record(
			record,
			bool(cfg.get("defer_blend", false)),
			int(cfg.get("generation_tick", -1))
		)
		if not applied.is_empty():
			attach_placement_asset_voxel_record(node, applied)
	return node


static func instantiate_placements(
	world_results: Array,
	node_class: String,
	placement_mesh: Mesh,
	extra_config: Dictionary = {}
) -> Array[AutoObject]:
	var nodes: Array[AutoObject] = []
	for i in range(world_results.size()):
		var cfg := extra_config.duplicate(true)
		cfg["name"] = "%s_%d" % [node_class, i]
		var node := instantiate_placement(world_results[i], node_class, placement_mesh, cfg)
		nodes.append(node)
	return nodes


static func make_placement_asset_voxel_record(
	node: AutoObject,
	world_result: Dictionary,
	node_class: String,
	record_config: Dictionary = {}
) -> Dictionary:
	if node == null:
		return {}

	var resolution := maxi(int(record_config.get("volume_xz_resolution", record_config.get("texture_resolution", 256))), 1)
	var capture := float(record_config.get("capture_size", record_config.get("world_capture_size", float(resolution))))
	if capture <= 0.0:
		capture = float(resolution)
	var base_px := _placement_base_pixel(world_result, record_config, capture, resolution)
	var record_id := str(record_config.get("record_id", record_config.get("id", node.name)))
	if record_id.is_empty():
		record_id = "%s_%d" % [node_class, int(world_result.get("asset_index", 0))]

	var fields := _placement_record_extra_fields(node, world_result, node_class, record_config)
	var record := node.make_asset_voxel_record(
		record_id,
		base_px,
		resolution,
		fields
	)
	record["rotation_mode"] = str(world_result.get("rotation_mode", record_config.get("rotation_mode", "Y"))).to_upper()
	record["rotation_degrees"] = world_result.get("rotation_degrees", node.rotation_degrees)
	record["mesh_name"] = node.name
	return record


static func attach_placement_asset_voxel_record(node: AutoObject, record: Dictionary) -> Dictionary:
	if node == null or record.is_empty():
		return {}
	var rec := record.duplicate(true)
	node.refresh_bound_spacing()
	var instance_id := node.refresh_instance_id()
	var record_id := str(rec.get("id", node.name))
	if record_id.is_empty():
		record_id = node.name
	rec["id"] = record_id
	rec["mesh_name"] = node.name
	rec["position"] = node.position
	rec["scale"] = node.scale
	rec["rotation_degrees"] = rec.get("rotation_degrees", node.rotation_degrees)
	rec["instance_id"] = instance_id
	rec["auto_instance_id"] = instance_id
	if node.auto_id.is_empty():
		node.auto_id = record_id
	rec["auto_id"] = node.auto_id
	rec["auto_object_id"] = node.auto_id
	rec["instance_mesh_id"] = instance_id
	rec["mesh_instance_id"] = instance_id
	rec["auto_source"] = node.auto_source
	rec["object_type"] = node.object_type
	rec["object_subtype"] = node.object_subtype
	if node.is_inside_tree():
		rec["node_path"] = str(node.get_path())
	node.set_asset_voxel_record(rec)
	return node.get_asset_voxel_record()


static func world_to_texture_pixel(
	world_pos: Vector3,
	capture_size: float,
	resolution: int
) -> Vector2i:
	var res := maxi(resolution, 1)
	var size := maxf(capture_size, 0.0001)
	var half := size * 0.5
	var px := clampi(floori((world_pos.x + half) / size * float(res)), 0, res - 1)
	var pz := clampi(floori((world_pos.z + half) / size * float(res)), 0, res - 1)
	return Vector2i(px, pz)


static func _placement_base_pixel(
	world_result: Dictionary,
	record_config: Dictionary,
	capture_size: float,
	resolution: int
) -> Vector2i:
	var raw_base = record_config.get("base_pixel", world_result.get("base_pixel", null))
	if raw_base is Vector2i:
		return raw_base as Vector2i
	if raw_base is Vector2:
		var v := raw_base as Vector2
		return Vector2i(roundi(v.x), roundi(v.y))
	if raw_base is Array:
		var arr := raw_base as Array
		if arr.size() >= 2:
			return Vector2i(int(arr[0]), int(arr[1]))
	var world_pos: Vector3 = world_result.get("position", Vector3.ZERO)
	return world_to_texture_pixel(world_pos, capture_size, resolution)


static func _placement_record_extra_fields(
	node: AutoObject,
	world_result: Dictionary,
	node_class: String,
	record_config: Dictionary
) -> Dictionary:
	var fields := {}
	for key in record_config.keys():
		if ASSET_VOXEL_RECORD_CONFIG_KEYS.has(key) or AutoObject.asset_voxel_record_meta_keys().has(key) or key == _deprecated_create_asset_voxel_record_key() or key == _legacy_create_asset_voxel_record_key():
			continue
		fields[key] = record_config[key]

	fields["auto_source"] = str(record_config.get("auto_source", node.auto_source))
	fields["placement_source"] = "voxel_placement"
	fields["source_kind"] = str(record_config.get("source_kind", fields.auto_source)).to_lower()
	if str(fields.source_kind).is_empty():
		fields["source_kind"] = "voxel_placement"
	fields["source_voxel_type"] = str(record_config.get("source_voxel_type", "AutoSceneVoxel"))
	fields["producer_stage"] = str(record_config.get("producer_stage", "voxel_placement"))
	fields["object_subtype"] = node.object_subtype if not node.object_subtype.is_empty() else node_class
	fields["asset_index"] = int(world_result.get("asset_index", record_config.get("asset_index", 0)))
	fields["rotation_index"] = int(world_result.get("rotation_index", record_config.get("rotation_index", 0)))
	fields["scale_index"] = int(world_result.get("scale_index", record_config.get("scale_index", 0)))
	fields["voxel_origin"] = world_result.get("voxel_origin", Vector3i.ZERO)

	for debug_key in [
		"score",
		"support_ratio",
		"solid_collision",
		"scene_overlap",
		"clearance_overlap",
		"ignored_sample",
	]:
		if world_result.has(debug_key):
			fields[debug_key] = world_result[debug_key]
	if node is AutoRock:
		fields["mesh_index"] = int((node as AutoRock).mesh_index)
	return fields


static func _create_node_for_class(node_class: String) -> AutoObject:
	match node_class:
		"canopy_tree":
			return AutoCanopyTree.new()
		"midstory_tree":
			return AutoMidstoryTree.new()
		"bush":
			return AutoBush.new()
		"grass":
			return AutoGrass.new()
		"rock", "cliff":
			return AutoCliffRock.new()
		_:
			return AutoVegetation.new()


static func _configure_node(node: AutoObject, node_class: String, cfg: Dictionary) -> void:
	match node_class:
		"canopy_tree":
			(node as AutoCanopyTree).configure_canopy_tree(cfg)
		"midstory_tree":
			(node as AutoMidstoryTree).configure_midstory_tree(cfg)
		"bush":
			(node as AutoBush).configure_bush(cfg)
		"grass":
			(node as AutoGrass).configure_grass(cfg)
		"rock", "cliff":
			(node as AutoCliffRock).configure_cliff(cfg)
		_:
			(node as AutoVegetation).configure_vegetation(cfg)


func run_minimal(
	scene_occupancy: PackedFloat32Array,
	collision_occupancy: PackedFloat32Array,
	footprint: Array,
	grid_size: Vector3i,
	settings: Dictionary = {}
) -> Dictionary:
	_apply_settings(settings)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	if voxel_count <= 0:
		push_error("VoxelPlacementGenerator: grid_size must be positive")
		return {}
	if footprint.is_empty():
		push_error("VoxelPlacementGenerator: footprint must not be empty")
		return {}
	if footprint.size() > FOOTPRINT_CAPACITY:
		push_error("VoxelPlacementGenerator: footprint is limited to %d voxels" % FOOTPRINT_CAPACITY)
		return {}

	var scene_data := _normalize_float_array(scene_occupancy, voxel_count)
	var collision_data := _normalize_float_array(collision_occupancy, voxel_count)
	var footprint_buffers := _pack_footprint(footprint)

	log_name = "VoxelPlacementGenerator"
	sync_global_device = true
	if not ensure_device(true, true):
		return {}

	_load_shaders()
	if not _shader_score.is_valid() or not _shader_reduce.is_valid() or not _shader_stamp.is_valid():
		_free_gpu()
		return {}

	var tile_counts := Vector3i(
		ceili(float(grid_size.x) / float(TILE_SIZE)),
		ceili(float(grid_size.y) / float(TILE_SIZE)),
		ceili(float(grid_size.z) / float(TILE_SIZE))
	)
	var tile_count := tile_counts.x * tile_counts.y * tile_counts.z
	var candidate_voxel_sparse_ids := _build_candidate_voxel_sparse_ids(settings, tile_counts, tile_count)
	var candidate_voxel_sparse_count := candidate_voxel_sparse_ids.size()
	var candidate_count := candidate_voxel_sparse_count * top_k
	var stamp_capacity := result_capacity * footprint.size()

	var scene_buffer := storage_buffer_from_floats(scene_data)
	var collision_buffer := storage_buffer_from_floats(collision_data)
	var footprint_pos_buffer := storage_buffer_from_bytes(footprint_buffers.pos_bytes)
	var footprint_weight_buffer := storage_buffer_from_bytes(footprint_buffers.weight_bytes)
	var candidate_voxel_sparse_buffer := storage_buffer_from_bytes(_pack_u32_array(candidate_voxel_sparse_ids))
	var tile_topk_buffer := storage_buffer_zero(candidate_count * RECORD_STRIDE * 16)
	var result_buffer := storage_buffer_zero(result_capacity * RECORD_STRIDE * 16)
	var result_count_buffer := storage_buffer_zero(4)
	var stamp_delta_buffer := storage_buffer_zero(maxi(stamp_capacity, 1) * DELTA_STRIDE * 16)

	var raw_target: PackedFloat32Array = settings.get("target_occupancy", PackedFloat32Array())
	var target_data := _normalize_float_array(raw_target, voxel_count) if raw_target.size() > 0 else PackedFloat32Array()
	if target_data.size() == 0:
		target_data.resize(voxel_count)
	var has_target := 1 if raw_target.size() > 0 else 0
	var target_buffer := storage_buffer_from_floats(target_data)

	var raw_target_color: PackedColorArray = settings.get("target_color", PackedColorArray())
	var target_color_buffer := storage_buffer_from_bytes(_pack_color_array_rgba8(raw_target_color, voxel_count))

	var debug_voxel_buffer := storage_buffer_zero(voxel_count * NUM_DEBUG_CHANNELS * 4)

	_dispatch_score(
		scene_buffer,
		collision_buffer,
		footprint_pos_buffer,
		footprint_weight_buffer,
		candidate_voxel_sparse_buffer,
		tile_topk_buffer,
		target_buffer,
		target_color_buffer,
		debug_voxel_buffer,
		grid_size,
		tile_counts,
		tile_count,
		candidate_voxel_sparse_count,
		footprint.size(),
		has_target,
		settings
	)
	_dispatch_reduce(tile_topk_buffer, result_buffer, result_count_buffer, candidate_count)
	_dispatch_stamp(
		scene_buffer,
		collision_buffer,
		result_buffer,
		result_count_buffer,
		footprint_pos_buffer,
		footprint_weight_buffer,
		stamp_delta_buffer,
		grid_size,
		footprint.size(),
		settings
	)

	submit_and_sync(true)

	var result_count_data := _rd.buffer_get_data(result_count_buffer)
	var result_count := int(result_count_data.decode_u32(0))
	result_count = clampi(result_count, 0, result_capacity)
	var result_data := _rd.buffer_get_data(result_buffer)
	var tile_topk_data := _rd.buffer_get_data(tile_topk_buffer)
	var scene_out_data := _rd.buffer_get_data(scene_buffer)
	var collision_out_data := _rd.buffer_get_data(collision_buffer)
	var stamp_delta_data := _rd.buffer_get_data(stamp_delta_buffer)
	var debug_voxel_data := _rd.buffer_get_data(debug_voxel_buffer)

	var output := {
		"result_count": result_count,
		"results": _decode_records(result_data, result_count),
		"tile_topk": _decode_records(tile_topk_data, candidate_count),
		"scene_occupancy_out": _decode_float_array(scene_out_data, voxel_count),
		"collision_occupancy_out": _decode_float_array(collision_out_data, voxel_count),
		"stamp_deltas": _decode_stamp_deltas(stamp_delta_data, stamp_capacity),
		"debug_voxel": _decode_float_array(debug_voxel_data, voxel_count * NUM_DEBUG_CHANNELS),
		"debug_channel_names": DEBUG_CHANNEL_NAMES,
		"debug_channel_count": NUM_DEBUG_CHANNELS,
		"tile_count": tile_count,
		"tile_counts": tile_counts,
		"candidate_voxel_sparse_count": candidate_voxel_sparse_count,
		"candidate_voxel_sparse_ids": candidate_voxel_sparse_ids,
		"candidate_count": candidate_count,
	}

	_free_gpu()
	return output


func _apply_settings(settings: Dictionary) -> void:
	top_k = int(settings.get("top_k", top_k))
	result_capacity = int(settings.get("result_capacity", result_capacity))
	solid_threshold = float(settings.get("solid_threshold", solid_threshold))
	collision_limit = float(settings.get("collision_limit", collision_limit))
	min_support_ratio = float(settings.get("min_support_ratio", min_support_ratio))
	clearance_limit = float(settings.get("clearance_limit", clearance_limit))
	support_weight = float(settings.get("support_weight", support_weight))
	collision_penalty = float(settings.get("collision_penalty", collision_penalty))
	overlap_penalty = float(settings.get("overlap_penalty", overlap_penalty))
	clearance_penalty = float(settings.get("clearance_penalty", clearance_penalty))
	min_distance_voxels = float(settings.get("min_distance_voxels", min_distance_voxels))
	scene_write_scale = float(settings.get("scene_write_scale", scene_write_scale))
	collision_write_scale = float(settings.get("collision_write_scale", collision_write_scale))
	asset_index = int(settings.get("asset_index", asset_index))
	rotation_index = int(settings.get("rotation_index", rotation_index))
	scale_index = int(settings.get("scale_index", scale_index))
	asset_color = Color(settings.get("asset_color", asset_color))
	top_k = clampi(top_k, 1, 8)
	result_capacity = maxi(result_capacity, 1)


func _load_shaders() -> void:
	_shader_score = load_compute_shader("res://shaders/score_voxel_tile.glsl")
	_shader_reduce = load_compute_shader("res://shaders/reduce_voxel_tiles.glsl")
	_shader_stamp = load_compute_shader("res://shaders/stamp_voxel_field.glsl")
	if _shader_score.is_valid():
		_pipeline_score = create_compute_pipeline(_shader_score)
	if _shader_reduce.is_valid():
		_pipeline_reduce = create_compute_pipeline(_shader_reduce)
	if _shader_stamp.is_valid():
		_pipeline_stamp = create_compute_pipeline(_shader_stamp)


func _pack_u32_array(values: PackedInt32Array) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(maxi(values.size(), 1) * 4)
	for i in range(values.size()):
		bytes.encode_u32(i * 4, values[i])
	return bytes


func _build_candidate_voxel_sparse_ids(settings: Dictionary, tile_counts: Vector3i, tile_count: int) -> PackedInt32Array:
	var ids := PackedInt32Array()
	var raw_regions: Variant = settings.get("candidate_voxel_sparses", null)
	if raw_regions == null:
		ids.resize(tile_count)
		for i in range(tile_count):
			ids[i] = i
		return ids

	var seen := {}
	for region in raw_regions:
		var tile_id := _voxel_sparse_to_tile_id(region, tile_counts)
		if tile_id < 0 or tile_id >= tile_count or seen.has(tile_id):
			continue
		seen[tile_id] = true
		ids.append(tile_id)

	if ids.is_empty():
		push_warning("VoxelPlacementGenerator: candidate_voxel_sparses produced no valid regions; using full grid")
		ids.resize(tile_count)
		for i in range(tile_count):
			ids[i] = i
	return ids


static func _voxel_sparse_to_tile_id(region: Variant, tile_counts: Vector3i) -> int:
	if region is Vector3i:
		return region.x + tile_counts.x * (region.y + tile_counts.y * region.z)
	if region is Vector3:
		var v := Vector3i(int(region.x), int(region.y), int(region.z))
		return v.x + tile_counts.x * (v.y + tile_counts.y * v.z)
	return int(region)


static func _normalize_search_radius(value: Variant) -> Vector3i:
	if value is Vector3i:
		return Vector3i(
			clampi(value.x, 0, 4),
			clampi(value.y, 0, 4),
			clampi(value.z, 0, 4)
		)
	if value is Vector3:
		return Vector3i(
			clampi(int(value.x), 0, 4),
			clampi(int(value.y), 0, 4),
			clampi(int(value.z), 0, 4)
		)
	var radius := clampi(int(value), 0, 4)
	return Vector3i(radius, radius, radius)


func _dispatch_score(
	scene_buffer: RID,
	collision_buffer: RID,
	footprint_pos_buffer: RID,
	footprint_weight_buffer: RID,
	candidate_voxel_sparse_buffer: RID,
	tile_topk_buffer: RID,
	target_buffer: RID,
	target_color_buffer: RID,
	debug_voxel_buffer: RID,
	grid_size: Vector3i,
	tile_counts: Vector3i,
	tile_count: int,
	candidate_voxel_sparse_count: int,
	footprint_count: int,
	has_target: int,
	settings: Dictionary
) -> void:
	var set0 := create_uniform_set([
		make_storage_uniform(0, scene_buffer),
		make_storage_uniform(1, collision_buffer),
		make_storage_uniform(2, footprint_pos_buffer),
		make_storage_uniform(3, footprint_weight_buffer),
		make_storage_uniform(4, tile_topk_buffer),
		make_storage_uniform(5, candidate_voxel_sparse_buffer),
		make_storage_uniform(6, target_buffer),
		make_storage_uniform(7, target_color_buffer),
		make_storage_uniform(8, debug_voxel_buffer),
	], _shader_score, 0)

	var sample_min: Vector3i = settings.get("sample_min", Vector3i.ZERO)
	var sample_max: Vector3i = settings.get("sample_max", grid_size)
	var search_radius: Vector3i = _normalize_search_radius(settings.get("search_radius", Vector3i.ZERO))
	var packed_color := _pack_color_rgba8(asset_color)
	var push := PackedByteArray()
	push.resize(128)
	push.encode_s32(0, grid_size.x)
	push.encode_s32(4, grid_size.y)
	push.encode_s32(8, grid_size.z)
	push.encode_s32(12, tile_count)
	push.encode_s32(16, tile_counts.x)
	push.encode_s32(20, tile_counts.y)
	push.encode_s32(24, tile_counts.z)
	push.encode_s32(28, top_k)
	push.encode_s32(32, sample_min.x)
	push.encode_s32(36, sample_min.y)
	push.encode_s32(40, sample_min.z)
	push.encode_u32(44, packed_color)
	push.encode_s32(48, sample_max.x)
	push.encode_s32(52, sample_max.y)
	push.encode_s32(56, sample_max.z)
	push.encode_s32(60, has_target)
	push.encode_s32(64, footprint_count)
	push.encode_s32(68, asset_index)
	push.encode_s32(72, rotation_index)
	push.encode_s32(76, scale_index)
	push.encode_float(80, solid_threshold)
	push.encode_float(84, collision_limit)
	push.encode_float(88, min_support_ratio)
	push.encode_float(92, clearance_limit)
	push.encode_float(96, support_weight)
	push.encode_float(100, collision_penalty)
	push.encode_float(104, overlap_penalty)
	push.encode_float(108, clearance_penalty)
	push.encode_s32(112, candidate_voxel_sparse_count)
	push.encode_s32(116, search_radius.x)
	push.encode_s32(120, search_radius.y)
	push.encode_s32(124, search_radius.z)

	var cl := begin_compute_list()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline_score)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, candidate_voxel_sparse_count, 1, 1)
	end_compute_list()


func _dispatch_reduce(tile_topk_buffer: RID, result_buffer: RID, result_count_buffer: RID, candidate_count: int) -> void:
	var set0 := create_uniform_set([
		make_storage_uniform(0, tile_topk_buffer),
		make_storage_uniform(1, result_buffer),
		make_storage_uniform(2, result_count_buffer),
	], _shader_reduce, 0)

	var push := PackedByteArray()
	push.resize(32)
	push.encode_s32(0, candidate_count)
	push.encode_s32(4, result_capacity)
	push.encode_s32(8, RECORD_STRIDE)
	push.encode_s32(12, 0)
	push.encode_float(16, min_distance_voxels)
	push.encode_float(20, 0.0)
	push.encode_float(24, 0.0)
	push.encode_float(28, 0.0)

	var cl := begin_compute_list()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline_reduce)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, 1, 1, 1)
	end_compute_list()


func _dispatch_stamp(
	scene_buffer: RID,
	collision_buffer: RID,
	result_buffer: RID,
	result_count_buffer: RID,
	footprint_pos_buffer: RID,
	footprint_weight_buffer: RID,
	stamp_delta_buffer: RID,
	grid_size: Vector3i,
	footprint_count: int,
	settings: Dictionary
) -> void:
	var set0 := create_uniform_set([
		make_storage_uniform(0, scene_buffer),
		make_storage_uniform(1, collision_buffer),
		make_storage_uniform(2, result_buffer),
		make_storage_uniform(3, result_count_buffer),
		make_storage_uniform(4, footprint_pos_buffer),
		make_storage_uniform(5, footprint_weight_buffer),
		make_storage_uniform(6, stamp_delta_buffer),
	], _shader_stamp, 0)

	var write_min: Vector3i = settings.get("write_min", Vector3i.ZERO)
	var write_max: Vector3i = settings.get("write_max", grid_size)
	var push := PackedByteArray()
	push.resize(64)
	push.encode_s32(0, grid_size.x)
	push.encode_s32(4, grid_size.y)
	push.encode_s32(8, grid_size.z)
	push.encode_s32(12, footprint_count)
	push.encode_s32(16, write_min.x)
	push.encode_s32(20, write_min.y)
	push.encode_s32(24, write_min.z)
	push.encode_s32(28, 0)
	push.encode_s32(32, write_max.x)
	push.encode_s32(36, write_max.y)
	push.encode_s32(40, write_max.z)
	push.encode_s32(44, 0)
	push.encode_float(48, solid_threshold)
	push.encode_float(52, scene_write_scale)
	push.encode_float(56, collision_write_scale)
	push.encode_float(60, 0.0)

	var total_threads := result_capacity * footprint_count
	var groups := ceili(float(maxi(total_threads, 1)) / 64.0)
	var cl := begin_compute_list()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline_stamp)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	end_compute_list()


func _pack_footprint(footprint: Array) -> Dictionary:
	var pos_bytes := PackedByteArray()
	var weight_bytes := PackedByteArray()
	pos_bytes.resize(footprint.size() * 16)
	weight_bytes.resize(footprint.size() * 16)

	for i in range(footprint.size()):
		var entry: Dictionary = footprint[i]
		var local_pos: Vector3i = entry.get("local_pos", Vector3i.ZERO)
		var collision_degree := clampi(int(entry.get("collision_degree", 0)), 0, 255)
		var flags := int(entry.get("flags", 0))
		var weight := maxf(float(entry.get("weight", 1.0)), 0.0)
		var pos_offset := i * 16
		pos_bytes.encode_s32(pos_offset + 0, local_pos.x)
		pos_bytes.encode_s32(pos_offset + 4, local_pos.y)
		pos_bytes.encode_s32(pos_offset + 8, local_pos.z)
		pos_bytes.encode_s32(pos_offset + 12, collision_degree)
		weight_bytes.encode_float(pos_offset + 0, weight)
		weight_bytes.encode_float(pos_offset + 4, float(flags))
		weight_bytes.encode_float(pos_offset + 8, float(entry.get("radius", 0.0)))
		weight_bytes.encode_float(pos_offset + 12, 0.0)
	return {
		"pos_bytes": pos_bytes,
		"weight_bytes": weight_bytes,
	}


func _normalize_float_array(values: PackedFloat32Array, expected_size: int) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(expected_size)
	var copy_count := mini(values.size(), expected_size)
	for i in range(copy_count):
		result[i] = values[i]
	return result


func _pack_float_array(values: PackedFloat32Array) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(values.size() * 4)
	for i in range(values.size()):
		bytes.encode_float(i * 4, values[i])
	return bytes


func _decode_float_array(bytes: PackedByteArray, value_count: int) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	values.resize(value_count)
	var available := mini(value_count, bytes.size() / 4)
	for i in range(available):
		values[i] = bytes.decode_float(i * 4)
	return values


func _decode_vec4(bytes: PackedByteArray, offset: int) -> Vector4:
	return Vector4(
		bytes.decode_float(offset + 0),
		bytes.decode_float(offset + 4),
		bytes.decode_float(offset + 8),
		bytes.decode_float(offset + 12)
	)


func _decode_records(bytes: PackedByteArray, record_count: int) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	var byte_stride := RECORD_STRIDE * 16
	var available := mini(record_count, bytes.size() / byte_stride)
	for i in range(available):
		var base := i * byte_stride
		var pose := _decode_vec4(bytes, base + 0)
		var ids := _decode_vec4(bytes, base + 16)
		var debug0 := _decode_vec4(bytes, base + 32)
		var debug1 := _decode_vec4(bytes, base + 48)
		records.append({
			"voxel_origin": Vector3i(int(roundf(pose.x)), int(roundf(pose.y)), int(roundf(pose.z))),
			"score": pose.w,
			"tile_id": int(roundf(ids.x)),
			"asset_index": int(roundf(ids.y)),
			"rotation_index": int(roundf(ids.z)),
			"scale_index": int(roundf(ids.w)),
			"support_ratio": debug0.x,
			"solid_collision": debug0.y,
			"scene_overlap": debug0.z,
			"clearance_overlap": debug0.w,
			"ignored_sample": debug1.x,
			"valid": debug1.y > 0.5,
			"support_hit": debug1.z,
			"support_total": debug1.w,
		})
	return records


func _decode_stamp_deltas(bytes: PackedByteArray, delta_count: int) -> Array[Dictionary]:
	var deltas: Array[Dictionary] = []
	var byte_stride := DELTA_STRIDE * 16
	var available := mini(delta_count, bytes.size() / byte_stride)
	for i in range(available):
		var base := i * byte_stride
		var pos_scene := _decode_vec4(bytes, base + 0)
		var collision_meta := _decode_vec4(bytes, base + 16)
		if collision_meta.w <= 0.5:
			continue
		deltas.append({
			"voxel": Vector3i(int(roundf(pos_scene.x)), int(roundf(pos_scene.y)), int(roundf(pos_scene.z))),
			"scene_value": pos_scene.w,
			"collision_value": collision_meta.x,
			"result_index": int(roundf(collision_meta.y)),
			"footprint_index": int(roundf(collision_meta.z)),
		})
	return deltas


static func _pack_color_rgba8(c: Color) -> int:
	var r := clampi(int(roundf(c.r * 255.0)), 0, 255)
	var g := clampi(int(roundf(c.g * 255.0)), 0, 255)
	var b := clampi(int(roundf(c.b * 255.0)), 0, 255)
	var a := clampi(int(roundf(c.a * 255.0)), 0, 255)
	return (r << 24) | (g << 16) | (b << 8) | a


func _pack_color_array_rgba8(colors: PackedColorArray, voxel_count: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(maxi(voxel_count, 1) * 4)
	var copy_count := mini(colors.size(), voxel_count)
	for i in range(copy_count):
		var c: Color = colors[i]
		bytes.encode_u32(i * 4, _pack_color_rgba8(c))
	return bytes


static func get_debug_channel(debug_voxel: PackedFloat32Array, channel: int, voxel_count: int) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(voxel_count)
	if channel < 0 or channel >= NUM_DEBUG_CHANNELS:
		return result
	for i in range(mini(voxel_count, debug_voxel.size() / NUM_DEBUG_CHANNELS)):
		result[i] = debug_voxel[i * NUM_DEBUG_CHANNELS + channel]
	return result


func voxel_index(p: Vector3i, grid_size: Vector3i) -> int:
	return p.x + grid_size.x * (p.z + grid_size.z * p.y)


# ---------------------------------------------------------------------------
# Footprint baking — collision_voxels → GPU footprint array
# ---------------------------------------------------------------------------

static func bake_footprint_from_collision_voxels(
	collision_voxels: Array,
	voxel_size: Vector3,
	add_support: bool = true,
	clearance_slices: int = 1
) -> Array[Dictionary]:
	var combined: Array[Dictionary] = []
	var float_voxels: Array[Dictionary] = []
	for cv in collision_voxels:
		if not cv is Dictionary:
			continue
		var collision := cv as Dictionary
		if _is_float_collision_voxel(collision):
			float_voxels.append(collision)
			continue
		var shape := str(collision.get("shape", "cylinder")).to_lower()
		if shape == "cylinder":
			combined.append_array(
				_bake_cylinder(collision, voxel_size, add_support, clearance_slices))
		elif shape == "box" or shape == "cube":
			combined.append_array(
				_bake_box(collision, voxel_size, add_support, clearance_slices))
	if not float_voxels.is_empty():
		combined.append_array(_bake_float_collision_voxels(float_voxels, add_support, clearance_slices))
	var result := _deduplicate_footprint(combined)
	if result.size() > FOOTPRINT_CAPACITY:
		push_warning("VoxelPlacementGenerator: footprint has %d voxels, truncating to %d" % [
			result.size(), FOOTPRINT_CAPACITY])
		result.resize(FOOTPRINT_CAPACITY)
	return result


static func _is_float_collision_voxel(collision: Dictionary) -> bool:
	return collision.has("voxel") or collision.has("local_pos") or collision.has("voxel_offset")


static func _collision_voxel_position(collision: Dictionary) -> Vector3i:
	return _vector3i_from_value(collision.get("voxel", collision.get("local_pos", collision.get("voxel_offset", Vector3i.ZERO))), Vector3i.ZERO)


static func _collision_voxel_degree(collision: Dictionary) -> int:
	if collision.has("collision_degree"):
		return clampi(int(collision.get("collision_degree", 255)), 0, 255)
	return clampi(int(clampf(float(collision.get("value", 1.0)), 0.0, 1.0) * 255.0), 0, 255)


static func _bake_float_collision_voxels(
	collision_voxels: Array[Dictionary],
	add_support: bool,
	clearance_slices: int
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var min_y := 2147483647
	var top_by_xz := {}
	for collision in collision_voxels:
		if not bool(collision.get("enabled", true)):
			continue
		var local_pos := _collision_voxel_position(collision)
		var collision_degree := _collision_voxel_degree(collision)
		var flags := int(collision.get("flags", 0))
		var weight := maxf(float(collision.get("weight", 1.0)), 0.0)
		result.append({
			"local_pos": local_pos,
			"collision_degree": collision_degree,
			"flags": flags,
			"weight": weight,
		})
		if collision_degree <= 0:
			continue
		min_y = mini(min_y, local_pos.y)
		var key := "%d,%d" % [local_pos.x, local_pos.z]
		if not top_by_xz.has(key) or local_pos.y > int(top_by_xz[key].y):
			top_by_xz[key] = local_pos
	if add_support and min_y < 2147483647:
		for entry in result:
			var pos: Vector3i = entry.local_pos
			if pos.y == min_y and int(entry.collision_degree) > 0:
				entry["flags"] = int(entry.flags) | FLAG_SUPPORT
	if clearance_slices > 0:
		for top in top_by_xz.values():
			var pos := top as Vector3i
			for cy in range(pos.y + 1, pos.y + 1 + clearance_slices):
				result.append({
					"local_pos": Vector3i(pos.x, cy, pos.z),
					"collision_degree": 0,
					"flags": FLAG_CLEARANCE,
					"weight": 0.5,
				})
	return result


static func _bake_cylinder(
	cv: Dictionary,
	voxel_size: Vector3,
	add_support: bool,
	clearance_slices: int
) -> Array[Dictionary]:
	var radius := maxf(float(cv.get("radius", 1.0)), 0.01)
	var y_min := float(cv.get("y_min", 0.0))
	var y_max := maxf(float(cv.get("y_max", 2.0)), y_min + 0.01)
	var value := clampf(float(cv.get("value", 1.0)), 0.0, 1.0)
	var collision_degree := clampi(int(value * 255.0), 0, 255)
	var center := _vector3_from_value(cv.get("offset", cv.get("center", cv.get("position", Vector3.ZERO))), Vector3.ZERO)

	var r_vx := ceili(radius / voxel_size.x)
	var r_vz := ceili(radius / voxel_size.z)
	var center_x_v := roundi(center.x / voxel_size.x)
	var center_z_v := roundi(center.z / voxel_size.z)
	var y_min_v := floori((center.y + y_min) / voxel_size.y)
	var y_max_v := ceili((center.y + y_max) / voxel_size.y)
	var radius_sq := radius * radius

	var result: Array[Dictionary] = []

	for y in range(y_min_v, y_max_v + 1):
		for z in range(-r_vz, r_vz + 1):
			for x in range(-r_vx, r_vx + 1):
				var wx := float(x) * voxel_size.x
				var wz := float(z) * voxel_size.z
				if wx * wx + wz * wz > radius_sq:
					continue
				var flags := 0
				if add_support and y == y_min_v:
					flags |= FLAG_SUPPORT
				result.append({
					"local_pos": Vector3i(center_x_v + x, y, center_z_v + z),
					"collision_degree": collision_degree,
					"flags": flags,
					"weight": 1.0,
				})

	if clearance_slices > 0:
		for cy in range(y_max_v + 1, y_max_v + 1 + clearance_slices):
			for z in range(-r_vz, r_vz + 1):
				for x in range(-r_vx, r_vx + 1):
					var wx := float(x) * voxel_size.x
					var wz := float(z) * voxel_size.z
					if wx * wx + wz * wz > radius_sq:
						continue
					result.append({
						"local_pos": Vector3i(center_x_v + x, cy, center_z_v + z),
						"collision_degree": 0,
						"flags": FLAG_CLEARANCE,
						"weight": 0.5,
					})

	return result


static func _bake_box(
	cv: Dictionary,
	voxel_size: Vector3,
	add_support: bool,
	clearance_slices: int
) -> Array[Dictionary]:
	var center := _vector3_from_value(cv.get("offset", cv.get("center", cv.get("position", Vector3.ZERO))), Vector3.ZERO)
	var half_extents := _vector3_from_value(cv.get("half_extents", Vector3.ZERO), Vector3.ZERO)
	if half_extents.length_squared() <= 0.0001:
		var size := _vector3_from_value(cv.get("size", Vector3.ZERO), Vector3.ZERO)
		if size.length_squared() > 0.0001:
			half_extents = size * 0.5
	var min_world: Vector3
	var max_world: Vector3
	if half_extents.length_squared() > 0.0001:
		min_world = center - half_extents
		max_world = center + half_extents
		if cv.has("y_min") or cv.has("y_max"):
			min_world.y = center.y + float(cv.get("y_min", min_world.y - center.y))
			max_world.y = center.y + float(cv.get("y_max", max_world.y - center.y))
	else:
		var radius := maxf(float(cv.get("radius", 1.0)), 0.01)
		var y_min := float(cv.get("y_min", 0.0))
		var y_max := maxf(float(cv.get("y_max", 2.0)), y_min + 0.01)
		min_world = center + Vector3(-radius, y_min, -radius)
		max_world = center + Vector3(radius, y_max, radius)
	var value := clampf(float(cv.get("value", 1.0)), 0.0, 1.0)
	var collision_degree := clampi(int(value * 255.0), 0, 255)
	var x_min_v := floori(min_world.x / voxel_size.x)
	var x_max_v := ceili(max_world.x / voxel_size.x)
	var y_min_v := floori(min_world.y / voxel_size.y)
	var y_max_v := ceili(max_world.y / voxel_size.y)
	var z_min_v := floori(min_world.z / voxel_size.z)
	var z_max_v := ceili(max_world.z / voxel_size.z)
	var result: Array[Dictionary] = []
	for y in range(y_min_v, y_max_v + 1):
		for z in range(z_min_v, z_max_v + 1):
			for x in range(x_min_v, x_max_v + 1):
				var flags := 0
				if add_support and y == y_min_v:
					flags |= FLAG_SUPPORT
				result.append({
					"local_pos": Vector3i(x, y, z),
					"collision_degree": collision_degree,
					"flags": flags,
					"weight": 1.0,
				})
	if clearance_slices > 0:
		for cy in range(y_max_v + 1, y_max_v + 1 + clearance_slices):
			for z in range(z_min_v, z_max_v + 1):
				for x in range(x_min_v, x_max_v + 1):
					result.append({
						"local_pos": Vector3i(x, cy, z),
						"collision_degree": 0,
						"flags": FLAG_CLEARANCE,
						"weight": 0.5,
					})
	return result


static func _deduplicate_footprint(entries: Array[Dictionary]) -> Array[Dictionary]:
	var by_pos := {}
	for entry in entries:
		var pos: Vector3i = entry.get("local_pos", Vector3i.ZERO)
		var key := "%d,%d,%d" % [pos.x, pos.y, pos.z]
		if by_pos.has(key):
			var existing: Dictionary = by_pos[key]
			existing["collision_degree"] = maxi(
				int(existing.collision_degree), int(entry.collision_degree))
			existing["flags"] = int(existing.flags) | int(entry.flags)
			existing["weight"] = maxf(float(existing.weight), float(entry.weight))
		else:
			by_pos[key] = entry.duplicate()
	var result: Array[Dictionary] = []
	for entry in by_pos.values():
		result.append(entry)
	return result


# ---------------------------------------------------------------------------
# Footprint rotation — pre-bake 24 yaw versions
# ---------------------------------------------------------------------------

static func rotate_footprint_y(
	footprint: Array[Dictionary], yaw_degrees: float
) -> Array[Dictionary]:
	if absf(yaw_degrees) < 0.01:
		var out: Array[Dictionary] = []
		for e in footprint:
			out.append(e.duplicate())
		return out
	var rad := deg_to_rad(yaw_degrees)
	var cos_r := cos(rad)
	var sin_r := sin(rad)
	var rotated: Array[Dictionary] = []
	for entry in footprint:
		var pos: Vector3i = entry.get("local_pos", Vector3i.ZERO)
		var rx := float(pos.x) * cos_r - float(pos.z) * sin_r
		var rz := float(pos.x) * sin_r + float(pos.z) * cos_r
		var new_entry := entry.duplicate()
		new_entry["local_pos"] = Vector3i(roundi(rx), pos.y, roundi(rz))
		rotated.append(new_entry)
	return _deduplicate_footprint(rotated)


static func bake_rotated_footprints(
	collision_voxels: Array,
	voxel_size: Vector3,
	rotation_count: int = 24,
	add_support: bool = true,
	clearance_slices: int = 1
) -> Array:
	var base := bake_footprint_from_collision_voxels(
		collision_voxels, voxel_size, add_support, clearance_slices)
	var result: Array = []
	for i in range(rotation_count):
		var yaw := float(i) * 360.0 / float(maxi(rotation_count, 1))
		result.append(rotate_footprint_y(base, yaw))
	return result


# ---------------------------------------------------------------------------
# GPU result → world-space placement data
# ---------------------------------------------------------------------------

static func results_to_world(
	results: Array[Dictionary],
	voxel_size: Vector3,
	grid_origin: Vector3,
	rotation_count: int = 24,
	pivot_variant: Dictionary = {}
) -> Array[Dictionary]:
	var world_results: Array[Dictionary] = []
	for r in results:
		if not bool(r.get("valid", false)):
			continue
		var origin: Vector3i = r.get("voxel_origin", Vector3i.ZERO)
		var rot_idx := int(r.get("rotation_index", 0))
		var scale_idx := int(r.get("scale_index", 0))
		var world_pos := grid_origin + Vector3(
			float(origin.x) * voxel_size.x,
			float(origin.y) * voxel_size.y,
			float(origin.z) * voxel_size.z
		)
		var yaw := float(rot_idx) * 360.0 / float(maxi(rotation_count, 1))
		var pivot_offset := _vector3_from_value(pivot_variant.get("offset", Vector3.ZERO), Vector3.ZERO)
		var pivot_world_offset := pivot_offset.rotated(Vector3.UP, deg_to_rad(yaw))
		var instance_pos := world_pos - pivot_world_offset
		world_results.append({
			"position": instance_pos,
			"anchor_position": world_pos,
			"pivot_variant": str(pivot_variant.get("name", "bottom")),
			"pivot_offset": pivot_offset,
			"rotation_y": yaw,
			"rotation_degrees": Vector3(0.0, yaw, 0.0),
			"rotation_mode": "Y",
			"scale": Vector3.ONE,
			"score": float(r.get("score", 0.0)),
			"voxel_origin": origin,
			"rotation_index": rot_idx,
			"scale_index": scale_idx,
			"asset_index": int(r.get("asset_index", 0)),
			"support_ratio": float(r.get("support_ratio", 0.0)),
			"solid_collision": float(r.get("solid_collision", 0.0)),
			"scene_overlap": float(r.get("scene_overlap", 0.0)),
			"clearance_overlap": float(r.get("clearance_overlap", 0.0)),
			"ignored_sample": float(r.get("ignored_sample", 0.0)),
		})
	return world_results


# ---------------------------------------------------------------------------
# asset_voxel_record creation — compatible with _attach_vegetation_asset_voxel_record
# ---------------------------------------------------------------------------

static func make_asset_voxel_record(
	world_result: Dictionary,
	node: AutoObject,
	config: Dictionary = {}
) -> Dictionary:
	if node != null:
		var node_record_id := str(config.get("id", node.name if not node.name.is_empty() else "voxel_placement_%d" % int(world_result.get("asset_index", 0))))
		var fields := config.duplicate(true)
		fields.erase("id")
		fields.erase("id_prefix")
		if not fields.has("auto_source"):
			fields["auto_source"] = "voxel_placement"
		if not fields.has("source_voxel_type"):
			fields["source_voxel_type"] = "AutoSceneVoxel"
		if not fields.has("source_kind"):
			fields["source_kind"] = "voxel_placement"
		if not fields.has("producer_stage"):
			fields["producer_stage"] = "voxel_placement"
		if config.has("type") and not fields.has("object_subtype"):
			fields["object_subtype"] = str(config.type)
		fields["score"] = float(world_result.get("score", 0.0))
		fields["voxel_origin"] = world_result.get("voxel_origin", Vector3i.ZERO)
		fields["rotation_index"] = int(world_result.get("rotation_index", 0))
		fields["rotation_y"] = float(world_result.get("rotation_y", 0.0))
		fields["asset_index"] = int(world_result.get("asset_index", 0))
		var node_record := node.make_asset_voxel_record(node_record_id, Vector2i.ZERO, 0, fields)
		node_record["position"] = world_result.get("position", node.position)
		node_record["scale"] = world_result.get("scale", node.scale)
		if world_result.has("rotation_degrees"):
			node_record["rotation_degrees"] = world_result.rotation_degrees
		elif world_result.has("rotation_y"):
			node_record["rotation_mode"] = "Y"
			node_record["rotation_degrees"] = Vector3(0.0, float(world_result.rotation_y), 0.0)
		return node_record

	var color: Color = config.get("color", node.voxel_color if node != null else Color.WHITE)
	var complexity := clampf(float(config.get("complexity", color.a)), 0.0, 1.0)
	color.a = complexity
	var position: Vector3 = world_result.get("position", node.position if node != null else Vector3.ZERO)
	var scale_val: Vector3 = world_result.get("scale", node.scale if node != null else Vector3.ONE)
	var record_id := str(config.get("id", node.name if node != null else "voxel_placement_%d" % int(world_result.get("asset_index", 0))))
	var collision_voxels: Array = config.get("collision_voxels", [])
	if collision_voxels.is_empty() and node != null and node.has_method("get_collision_voxels"):
		collision_voxels = node.call("get_collision_voxels")

	var record := {
		"id": record_id,
		"type": config.get("type", node.object_subtype if node != null else "vegetation"),
		"auto_source": "voxel_placement",
		"source_voxel_type": "AutoSceneVoxel",
		"source_kind": "voxel_placement",
		"producer_stage": "voxel_placement",
		"position": position,
		"scale": scale_val,
		"base_pixel": Vector2i.ZERO,
		"voxel_xz": Vector2i.ZERO,
		"volume_xz_resolution": 0,
		"color": color,
		"complexity": complexity,
		"collision_voxels": collision_voxels,
		"score": float(world_result.get("score", 0.0)),
		"voxel_origin": world_result.get("voxel_origin", Vector3i.ZERO),
		"rotation_index": int(world_result.get("rotation_index", 0)),
		"rotation_y": float(world_result.get("rotation_y", 0.0)),
		"asset_index": int(world_result.get("asset_index", 0)),
	}
	record[DEPRECATED_SENCE_LAYER_VOXEL_KEY] = []
	return record


static func make_asset_voxel_records(
	world_results: Array,
	nodes: Array,
	config: Dictionary = {}
) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	for i in range(world_results.size()):
		var node: AutoObject = nodes[i] if i < nodes.size() else null
		var cfg := config.duplicate(true)
		cfg["id"] = "%s_%d" % [str(config.get("id_prefix", "voxel_placement")), i]
		records.append(make_asset_voxel_record(world_results[i], node, cfg))
	return records


func _free_gpu() -> void:
	dispose()
	_pipeline_score = RID()
	_pipeline_reduce = RID()
	_pipeline_stamp = RID()
	_shader_score = RID()
	_shader_reduce = RID()
	_shader_stamp = RID()
