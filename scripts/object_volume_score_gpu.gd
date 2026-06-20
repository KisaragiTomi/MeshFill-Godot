class_name ObjectVolumeScoreGpu
extends "res://scripts/godot_compute_shader_base.gd"

## 3D object volume scoring GPU pipeline.
##
## Implements the two-pass architecture from meshfill-object-volume-score-3d.md:
##   Pass A: score_object_subtile.glsl  — per-subtile partial accumulation
##   Pass B: reduce_object_rotation_scores.glsl — reduce + best rotation pick
##
## Usage:
##   var scorer = ObjectVolumeScoreGpu.new()
##   var results = scorer.score_all_assets(scene_fields, asset_footprints, anchors)
##   scorer.dispose()

const SCORE_SUBTILE_SHADER := "res://shaders/score_object_subtile.glsl"
const REDUCE_SHADER := "res://shaders/reduce_object_rotation_scores.glsl"

const SUBTILE_SIZE := 8
const ROTATION_SLOTS := 12
const RESULT_STRIDE := 2
const TIER_COUNT := 12

## 12 discrete extent tiers — no branching, no interpolation.
## Each entry: [max_aabb_size_m, sample_extent, subtiles_per_axis].
## Objects larger than the last tier threshold get tier 11 (full 50^3).
const EXTENT_TIERS: Array[Vector3i] = [
	Vector3i(  1,  1, 1),   # tier 0:  <=0.10m  extent=1   stc=1
	Vector3i(  4,  4, 1),   # tier 1:  <=0.30m  extent=4   stc=1
	Vector3i(  8,  8, 1),   # tier 2:  <=0.60m  extent=8   stc=1
	Vector3i( 12, 12, 2),   # tier 3:  <=1.00m  extent=12  stc=8
	Vector3i( 16, 16, 2),   # tier 4:  <=1.50m  extent=16  stc=8
	Vector3i( 20, 20, 3),   # tier 5:  <=2.00m  extent=20  stc=27
	Vector3i( 24, 24, 3),   # tier 6:  <=2.50m  extent=24  stc=27
	Vector3i( 28, 28, 4),   # tier 7:  <=3.00m  extent=28  stc=64
	Vector3i( 32, 32, 4),   # tier 8:  <=3.50m  extent=32  stc=64
	Vector3i( 40, 40, 5),   # tier 9:  <=4.00m  extent=40  stc=125
	Vector3i( 44, 44, 6),   # tier 10: <=4.50m  extent=44  stc=216
	Vector3i( 50, 50, 7),   # tier 11: >4.50m   extent=50  stc=343
]

## Size thresholds for each tier (meters). Index matches EXTENT_TIERS.
static var TIER_THRESHOLDS: PackedFloat32Array = PackedFloat32Array([
	0.10, 0.30, 0.60, 1.00, 1.50, 2.00, 2.50, 3.00, 3.50, 4.00, 4.50, INF,
])

var _score_shader: RID
var _score_pipeline: RID
var _reduce_shader: RID
var _reduce_pipeline: RID


## Look up extent tier from asset world-space AABB longest axis (meters).
## Returns fixed tier parameters — no interpolation, no shader branching.
static func compute_extent_params(world_aabb_longest_axis: float) -> Dictionary:
	var size := maxf(world_aabb_longest_axis, 0.0)
	var tier_idx := TIER_COUNT - 1
	for i in range(TIER_COUNT):
		if size <= TIER_THRESHOLDS[i]:
			tier_idx = i
			break
	var tier := EXTENT_TIERS[tier_idx]
	var spa := tier.z
	return {
		"tier": tier_idx,
		"sample_extent": tier.y,
		"subtiles_per_axis": spa,
		"subtile_count": spa * spa * spa,
	}


func score_all_assets(
	scene_fields: Dictionary,
	asset_footprints: Array[Dictionary],
	anchors: PackedVector3Array
) -> Array[Dictionary]:
	log_name = "ObjectVolumeScoreGpu"
	var results: Array[Dictionary] = []
	if anchors.is_empty() or asset_footprints.is_empty():
		return results
	if not ensure_device():
		push_error("[%s] No RenderingDevice" % log_name)
		return results

	if not _init_pipelines():
		dispose()
		return results

	var anchor_count := anchors.size()
	var anchor_data := _pack_anchor_positions(anchors)
	var anchor_buf := storage_buffer_from_bytes(anchor_data, SCOPE_FRAME, "anchors")

	var grid: Vector3i = scene_fields.get("grid", Vector3i.ZERO)
	var voxel_count := grid.x * grid.y * grid.z
	if voxel_count <= 0:
		push_error("[%s] Empty scene grid" % log_name)
		dispose()
		return results

	var cx_buf := storage_buffer_from_bytes(
		scene_fields["complexity_bytes"], SCOPE_FRAME, "scene_complexity")
	var coll_buf := storage_buffer_from_bytes(
		scene_fields["collision_bytes"], SCOPE_FRAME, "scene_collision")
	var target_buf := storage_buffer_from_bytes(
		scene_fields["target_bytes"], SCOPE_FRAME, "scene_target")

	var max_tier := EXTENT_TIERS[TIER_COUNT - 1]
	var max_spa := max_tier.z
	var max_stc := max_spa * max_spa * max_spa
	var max_partial_count := anchor_count * max_stc * ROTATION_SLOTS
	var partial_buf := storage_buffer_zero(
		max_partial_count * 4, SCOPE_FRAME, "partials")
	var result_count := anchor_count * RESULT_STRIDE
	var result_buf := storage_buffer_zero(
		result_count * 16, SCOPE_FRAME, "results")

	for asset_idx in range(asset_footprints.size()):
		var fp: Dictionary = asset_footprints[asset_idx]
		var fp_grid: Vector3i = fp.get("grid", Vector3i.ZERO)
		var fp_pivot: Vector3i = fp.get("pivot", Vector3i.ZERO)
		var fp_voxel_count := fp_grid.x * fp_grid.y * fp_grid.z
		if fp_voxel_count <= 0:
			results.append({"asset_index": asset_idx, "ok": false, "reason": "empty_footprint"})
			continue

		var world_size: float = fp.get("world_aabb_longest", 1.0)
		var ext := compute_extent_params(world_size)
		var sample_extent: int = ext["sample_extent"]
		var subtiles_per_axis: int = ext["subtiles_per_axis"]
		var subtile_count: int = ext["subtile_count"]

		begin_scope(SCOPE_PASS)
		var fp_occ_buf := storage_buffer_from_bytes(
			fp["occupancy_bytes"], SCOPE_PASS, "fp_occ_%d" % asset_idx)
		var fp_props_buf := storage_buffer_from_bytes(
			fp["props_bytes"], SCOPE_PASS, "fp_props_%d" % asset_idx)

		var partial_count := anchor_count * subtile_count * ROTATION_SLOTS
		buffer_zero(partial_buf, partial_count * 4)
		buffer_zero(result_buf, result_count * 16)

		var asset_color: Color = fp.get("color", Color(0.5, 0.5, 0.5, 0.5))
		_dispatch_pass_a(
			cx_buf, coll_buf, target_buf,
			fp_occ_buf, fp_props_buf, anchor_buf, partial_buf,
			grid, fp_grid, fp_pivot, asset_color, anchor_count,
			sample_extent, subtiles_per_axis, subtile_count)
		_dispatch_pass_b(partial_buf, result_buf, anchor_count,
			subtile_count)

		submit_and_sync()

		var rd := get_rendering_device()
		var result_bytes := rd.buffer_get_data(result_buf, 0, result_count * 16)
		end_scope()

		var decoded := _decode_results(result_bytes, anchor_count, asset_idx)
		decoded["sample_extent"] = sample_extent
		decoded["subtile_count"] = subtile_count
		results.append(decoded)

	gc_frame()
	return results


func _init_pipelines() -> bool:
	_score_shader = load_compute_shader(SCORE_SUBTILE_SHADER)
	_score_pipeline = create_compute_pipeline(_score_shader)
	_reduce_shader = load_compute_shader(REDUCE_SHADER)
	_reduce_pipeline = create_compute_pipeline(_reduce_shader)
	return (_score_pipeline.is_valid() and _reduce_pipeline.is_valid())


func _dispatch_pass_a(
	cx_buf: RID, coll_buf: RID, target_buf: RID,
	fp_occ_buf: RID, fp_props_buf: RID, anchor_buf: RID, partial_buf: RID,
	grid: Vector3i, fp_grid: Vector3i, fp_pivot: Vector3i,
	asset_color: Color, anchor_count: int,
	sample_extent: int, subtiles_per_axis: int, subtile_count: int
) -> void:
	var rd := get_rendering_device()
	var set0 := create_uniform_set([
		make_storage_uniform(0, cx_buf),
		make_storage_uniform(1, coll_buf),
		make_storage_uniform(2, target_buf),
		make_storage_uniform(3, fp_occ_buf),
		make_storage_uniform(4, fp_props_buf),
		make_storage_uniform(5, anchor_buf),
		make_storage_uniform(6, partial_buf),
	], _score_shader, 0)

	var push := _score_push_constant(grid, fp_grid, fp_pivot, asset_color,
		sample_extent, subtiles_per_axis, subtile_count)
	var cl := begin_compute_list()
	rd.compute_list_bind_compute_pipeline(cl, _score_pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, subtile_count, anchor_count, 1)
	rd.compute_list_add_barrier(cl)
	end_compute_list()


func _dispatch_pass_b(
	partial_buf: RID, result_buf: RID, anchor_count: int,
	subtile_count: int
) -> void:
	var rd := get_rendering_device()
	var set0 := create_uniform_set([
		make_storage_uniform(0, partial_buf),
		make_storage_uniform(1, result_buf),
	], _reduce_shader, 0)

	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, anchor_count)
	push.encode_s32(4, subtile_count)
	push.encode_s32(8, ROTATION_SLOTS)
	push.encode_s32(12, RESULT_STRIDE)

	var cl := begin_compute_list()
	rd.compute_list_bind_compute_pipeline(cl, _reduce_pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, anchor_count, 1, 1)
	end_compute_list()


func _score_push_constant(
	grid: Vector3i, fp_grid: Vector3i, fp_pivot: Vector3i, asset_color: Color,
	sample_extent: int, subtiles_per_axis: int, subtile_count: int
) -> PackedByteArray:
	var push := PackedByteArray()
	push.resize(80)
	push.encode_s32(0, grid.x)
	push.encode_s32(4, grid.y)
	push.encode_s32(8, grid.z)
	push.encode_s32(12, grid.x * grid.y * grid.z)
	push.encode_s32(16, fp_grid.x)
	push.encode_s32(20, fp_grid.y)
	push.encode_s32(24, fp_grid.z)
	push.encode_s32(28, fp_grid.x * fp_grid.y * fp_grid.z)
	push.encode_s32(32, fp_pivot.x)
	push.encode_s32(36, fp_pivot.y)
	push.encode_s32(40, fp_pivot.z)
	push.encode_s32(44, sample_extent)
	push.encode_s32(48, ROTATION_SLOTS)
	push.encode_s32(52, subtiles_per_axis)
	push.encode_s32(56, subtile_count)
	push.encode_s32(60, 0)
	push.encode_float(64, asset_color.r)
	push.encode_float(68, asset_color.g)
	push.encode_float(72, asset_color.b)
	push.encode_float(76, asset_color.a)
	return push


func _pack_anchor_positions(anchors: PackedVector3Array) -> PackedByteArray:
	var data := PackedByteArray()
	data.resize(anchors.size() * 16)
	for i in range(anchors.size()):
		var a := anchors[i]
		data.encode_s32(i * 16, int(a.x))
		data.encode_s32(i * 16 + 4, int(a.y))
		data.encode_s32(i * 16 + 8, int(a.z))
		data.encode_s32(i * 16 + 12, 0)
	return data


func _decode_results(
	result_bytes: PackedByteArray, anchor_count: int, asset_index: int
) -> Dictionary:
	var per_anchor: Array[Dictionary] = []
	var floats := result_bytes.to_float32_array()
	var stride := RESULT_STRIDE * 4
	for i in range(anchor_count):
		var base := i * stride
		if base + 3 >= floats.size():
			per_anchor.append({"score": -1.0, "rotation_slot": 0, "yaw": 0.0, "valid": false})
			continue
		per_anchor.append({
			"score": floats[base],
			"rotation_slot": int(floats[base + 1]),
			"yaw": floats[base + 2],
			"valid": floats[base + 3] > 0.5,
		})
	return {
		"asset_index": asset_index,
		"ok": true,
		"anchor_results": per_anchor,
	}


## Prepare footprint data from a MeshVoxelizerGpu result.
## world_aabb_longest is the mesh's world-space AABB longest axis (meters),
## used to derive dynamic sample_extent.
static func footprint_from_voxelizer_result(
	result: Dictionary, asset_color: Color, world_aabb_longest: float = 1.0
) -> Dictionary:
	if not bool(result.get("ok", false)):
		return {"grid": Vector3i.ZERO, "pivot": Vector3i.ZERO,
				"occupancy_bytes": PackedByteArray(),
				"props_bytes": PackedByteArray(),
				"color": asset_color,
				"world_aabb_longest": world_aabb_longest}

	var grid: Vector3i = result["grid"]
	var voxels: Array = result["voxels"]
	var voxel_count := grid.x * grid.y * grid.z

	var occ := PackedInt32Array()
	occ.resize(voxel_count)
	var props := PackedFloat32Array()
	props.resize(voxel_count * 4)

	for v in voxels:
		var coord: Vector3i = v["voxel"]
		var idx := coord.x + grid.x * (coord.z + grid.z * coord.y)
		if idx < 0 or idx >= voxel_count:
			continue
		occ[idx] = 1
		var c: Color = v.get("color", Color.WHITE)
		var collision: float = v.get("collision", 0.0)
		props[idx * 4] = c.r
		props[idx * 4 + 1] = c.g
		props[idx * 4 + 2] = c.b
		props[idx * 4 + 3] = collision

	var pivot := Vector3i(grid.x / 2, 0, grid.z / 2)

	return {
		"grid": grid,
		"pivot": pivot,
		"occupancy_bytes": occ.to_byte_array(),
		"props_bytes": props.to_byte_array(),
		"color": asset_color,
		"world_aabb_longest": world_aabb_longest,
	}
