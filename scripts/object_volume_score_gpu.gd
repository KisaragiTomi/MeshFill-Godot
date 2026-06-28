@tool
class_name ObjectVolumeScoreGpu
extends "res://scripts/godot_compute_shader_base.gd"

## 3D object volume scoring GPU pipeline.
##
## Implements the two-pass architecture from meshfill-object-volume-score-3d.md:
##   Pass A: score_object_subtile.glsl  — per-rotation valid sample accumulation
##   Pass B: reduce_object_rotation_scores.glsl — reduce + best rotation pick
##
## Usage:
##   var scorer = ObjectVolumeScoreGpu.new()
##   var results = scorer.score_all_assets(scene_fields, asset_footprints, anchors)
##   scorer.dispose()

const SCORE_SUBTILE_SHADER := "res://shaders/score_object_subtile.glsl"
const REDUCE_SHADER := "res://shaders/reduce_object_rotation_scores.glsl"

const SUBTILE_SIZE := 8
const SAMPLE_GROUP_SIZE := SUBTILE_SIZE * SUBTILE_SIZE * SUBTILE_SIZE
const ROTATION_SLOTS := 12
const RESULT_STRIDE := 2
const TIER_COUNT := 9
const SAMPLE_RECORD_STRIDE_INTS := 4
const SAMPLE_BOUNDS_STRIDE_INTS := 8
const MAX_VARIANT_AXIS := 32
const MAX_VARIANTS_PER_ROTATION := MAX_VARIANT_AXIS * MAX_VARIANT_AXIS * MAX_VARIANT_AXIS
const MAX_SAMPLE_GROUPS := 64

## Discrete size tiers used for compatibility/debug display. Actual scoring
## uses per-rotation valid footprint samples capped at MAX_VARIANTS_PER_ROTATION.
## Each entry: [debug_axis, sample_extent, sample_groups_per_axis].
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
]

## Size thresholds for each tier (meters). Index matches EXTENT_TIERS.
static var TIER_THRESHOLDS: PackedFloat32Array = PackedFloat32Array([
	0.10, 0.30, 0.60, 1.00, 1.50, 2.00, 2.50, 3.00, INF,
])

var _score_shader: RID
var _score_pipeline: RID
var _reduce_shader: RID
var _reduce_pipeline: RID


## 根据资产世界空间 AABB 的最长轴（米）查找尺寸分级（tier）。
## 返回固定的分级参数——不做插值，也不引入着色器分支。
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
		"sample_group_count": spa * spa * spa,
		"max_variant_axis": mini(tier.y, MAX_VARIANT_AXIS),
		"max_variant_count": mini(tier.y, MAX_VARIANT_AXIS) * mini(tier.y, MAX_VARIANT_AXIS) * mini(tier.y, MAX_VARIANT_AXIS),
	}


## GPU 评分主入口：在所有 anchor 处对每个资产做两遍（Pass A/B）体积评分。
## 准备场景/资产/anchor 缓冲区，逐资产派发计算着色器，回读并解码结果。
## 返回每个资产一个结果字典（含各 anchor 的分数、最佳旋转槽、yaw 等）。
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
	var voxel_count := VoxelGeneral.voxel_count(grid)
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

	var max_partial_count := anchor_count * MAX_SAMPLE_GROUPS * ROTATION_SLOTS
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

		var sample_profile := ensure_rotation_sample_profile(
			fp,
			scene_fields.get("voxel_size", Vector3.ZERO)
		)
		if not bool(sample_profile.get("ok", false)):
			results.append({
				"asset_index": asset_idx,
				"ok": false,
				"reason": str(sample_profile.get("reason", "empty_sample_profile")),
			})
			continue
		var variant_capacity := int(sample_profile.get("variant_capacity", 0))
		var sample_group_count := int(sample_profile.get("sample_group_count", 0))
		var max_sample_count := int(sample_profile.get("max_sample_count", 0))
		if variant_capacity <= 0 or sample_group_count <= 0 or max_sample_count <= 0:
			results.append({"asset_index": asset_idx, "ok": false, "reason": "empty_sample_profile"})
			continue

		begin_scope(SCOPE_PASS)
		var sample_records_buf := storage_buffer_from_bytes(
			sample_profile["records_bytes"], SCOPE_PASS, "sample_records_%d" % asset_idx)
		var sample_counts_buf := storage_buffer_from_bytes(
			sample_profile["counts_bytes"], SCOPE_PASS, "sample_counts_%d" % asset_idx)
		var fp_props_buf := storage_buffer_from_bytes(
			fp["props_bytes"], SCOPE_PASS, "fp_props_%d" % asset_idx)

		var partial_count := anchor_count * sample_group_count * ROTATION_SLOTS
		buffer_zero(partial_buf, partial_count * 4)
		buffer_zero(result_buf, result_count * 16)

		var asset_color: Color = fp.get("color", Color(0.5, 0.5, 0.5, 0.5))
		_dispatch_pass_a(
			cx_buf, coll_buf, target_buf,
			sample_records_buf, fp_props_buf, anchor_buf, sample_counts_buf, partial_buf,
			grid, asset_color, anchor_count, variant_capacity, sample_group_count, max_sample_count)
		_dispatch_pass_b(partial_buf, result_buf, anchor_count,
			sample_group_count)

		submit_and_sync()

		var rd := get_rendering_device()
		var result_bytes := rd.buffer_get_data(result_buf, 0, result_count * 16)
		end_scope()

		var decoded := _decode_results(result_bytes, anchor_count, asset_idx)
		decoded["sample_extent"] = int(sample_profile.get("sample_extent", 1))
		decoded["sample_variant_count"] = max_sample_count
		decoded["sample_variant_capacity"] = variant_capacity
		decoded["sample_group_count"] = sample_group_count
		decoded["subtile_count"] = sample_group_count
		decoded["rotation_sample_counts"] = sample_profile.get("sample_counts", PackedInt32Array())
		decoded["rotation_sample_bounds"] = sample_profile.get("bounds_by_slot", [])
		results.append(decoded)

	gc_frame()
	return results


## 加载 Pass A/B 两个计算着色器并创建管线；两者均有效时返回 true。
func _init_pipelines() -> bool:
	_score_shader = load_compute_shader(SCORE_SUBTILE_SHADER)
	_score_pipeline = create_compute_pipeline(_score_shader)
	_reduce_shader = load_compute_shader(REDUCE_SHADER)
	_reduce_pipeline = create_compute_pipeline(_reduce_shader)
	return (_score_pipeline.is_valid() and _reduce_pipeline.is_valid())


## 派发 Pass A：逐旋转累计有效采样点。绑定场景/采样/anchor 缓冲与推送常量，
## 以 (sample_group_count, anchor_count, 1) 网格分发，并加入计算屏障。
func _dispatch_pass_a(
	cx_buf: RID, coll_buf: RID, target_buf: RID,
	sample_records_buf: RID, fp_props_buf: RID, anchor_buf: RID,
	sample_counts_buf: RID, partial_buf: RID,
	grid: Vector3i, asset_color: Color,
	anchor_count: int, variant_capacity: int, sample_group_count: int, max_sample_count: int
) -> void:
	var rd := get_rendering_device()
	var set0 := create_uniform_set([
		make_storage_uniform(0, cx_buf),
		make_storage_uniform(1, coll_buf),
		make_storage_uniform(2, target_buf),
		make_storage_uniform(3, sample_records_buf),
		make_storage_uniform(4, fp_props_buf),
		make_storage_uniform(5, anchor_buf),
		make_storage_uniform(6, sample_counts_buf),
		make_storage_uniform(7, partial_buf),
	], _score_shader, 0)

	var push := _score_push_constant(grid, asset_color,
		variant_capacity, sample_group_count, max_sample_count)
	var cl := begin_compute_list()
	rd.compute_list_bind_compute_pipeline(cl, _score_pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, sample_group_count, anchor_count, 1)
	rd.compute_list_add_barrier(cl)
	end_compute_list()


## 派发 Pass B：归约 Pass A 的部分分数并为每个 anchor 选出最佳旋转。
## 以 (anchor_count, 1, 1) 分发，每个 anchor 一个线程。
func _dispatch_pass_b(
	partial_buf: RID, result_buf: RID, anchor_count: int,
	sample_group_count: int
) -> void:
	var rd := get_rendering_device()
	var set0 := create_uniform_set([
		make_storage_uniform(0, partial_buf),
		make_storage_uniform(1, result_buf),
	], _reduce_shader, 0)

	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, anchor_count)
	push.encode_s32(4, sample_group_count)
	push.encode_s32(8, ROTATION_SLOTS)
	push.encode_s32(12, RESULT_STRIDE)

	var cl := begin_compute_list()
	rd.compute_list_bind_compute_pipeline(cl, _reduce_pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, anchor_count, 1, 1)
	end_compute_list()


## 构建 Pass A 的 80 字节推送常量：网格尺寸、体素总数、变体容量、采样组数、
## 旋转槽数、最大采样数（其余保留位填 0），以及资产颜色 RGBA。
func _score_push_constant(
	grid: Vector3i, asset_color: Color,
	variant_capacity: int, sample_group_count: int, max_sample_count: int
) -> PackedByteArray:
	var push := PackedByteArray()
	push.resize(80)
	push.encode_s32(0, grid.x)
	push.encode_s32(4, grid.y)
	push.encode_s32(8, grid.z)
	push.encode_s32(12, VoxelGeneral.voxel_count(grid))
	push.encode_s32(16, variant_capacity)
	push.encode_s32(20, sample_group_count)
	push.encode_s32(24, ROTATION_SLOTS)
	push.encode_s32(28, max_sample_count)
	push.encode_s32(32, 0)
	push.encode_s32(36, 0)
	push.encode_s32(40, 0)
	push.encode_s32(44, 0)
	push.encode_s32(48, 0)
	push.encode_s32(52, 0)
	push.encode_s32(56, 0)
	push.encode_s32(60, 0)
	push.encode_float(64, asset_color.r)
	push.encode_float(68, asset_color.g)
	push.encode_float(72, asset_color.b)
	push.encode_float(76, asset_color.a)
	return push


## 将 anchor 位置打包为 ivec4 字节数组（每个 anchor 存 x, y, z, 0）。
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


## 将 Pass B 回读的字节解码为每个 anchor 的结果字典
## （score、rotation_slot、yaw、valid）；越界时填入无效占位项。
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


## 获取资产的旋转采样剖面：命中缓存则复用，否则现场构建并写回缓存。
## 是否可用场景体素单位决定使用的缓存键及匹配校验条件。
static func ensure_rotation_sample_profile(
	asset_footprint: Dictionary,
	scene_voxel_size: Vector3 = Vector3.ZERO
) -> Dictionary:
	var use_scene_units := _can_build_scene_voxel_profile(asset_footprint, scene_voxel_size)
	var cache_key := "rotation_sample_profile_scene" if use_scene_units else "rotation_sample_profile"
	var profile_value = asset_footprint.get(cache_key, {})
	if profile_value is Dictionary:
		var profile := profile_value as Dictionary
		if bool(profile.get("ok", false)) \
				and (not use_scene_units or _profile_matches_scene_voxel_size(profile, scene_voxel_size)):
			return profile
	var profile_voxel_size := scene_voxel_size if use_scene_units else Vector3.ZERO
	var built := build_rotation_sample_profile(asset_footprint, profile_voxel_size)
	asset_footprint[cache_key] = built
	return built


## 为每个 yaw 旋转槽构建精确的占用足迹采样。每条记录为
## ivec4(scene_offset.xyz, footprint_props_index)，按旋转槽分别打包。
static func build_rotation_sample_profile(
	asset_footprint: Dictionary,
	scene_voxel_size: Vector3 = Vector3.ZERO
) -> Dictionary:
	var fp_grid: Vector3i = asset_footprint.get("grid", Vector3i.ZERO)
	var fp_pivot: Vector3i = asset_footprint.get("pivot", Vector3i.ZERO)
	var fp_voxel_count := fp_grid.x * fp_grid.y * fp_grid.z
	if fp_voxel_count <= 0:
		return _empty_rotation_sample_profile("empty_footprint")
	var occupancy_bytes: PackedByteArray = asset_footprint.get("occupancy_bytes", PackedByteArray())
	var occupancy := occupancy_bytes.to_int32_array()
	if occupancy.size() < fp_voxel_count:
		return _empty_rotation_sample_profile("occupancy_size_mismatch")
	var props_bytes: PackedByteArray = asset_footprint.get("props_bytes", PackedByteArray())
	var props := props_bytes.to_float32_array()
	var use_scene_units := _can_build_scene_voxel_profile(asset_footprint, scene_voxel_size)

	var max_records_per_slot := _variant_capacity_for_grid(fp_grid)
	var per_slot_records: Array = []
	var sample_counts := PackedInt32Array()
	sample_counts.resize(ROTATION_SLOTS)
	var bounds_i32 := PackedInt32Array()
	bounds_i32.resize(ROTATION_SLOTS * SAMPLE_BOUNDS_STRIDE_INTS)
	var bounds_by_slot: Array[Dictionary] = []
	var max_sample_count := 0
	var max_bounds_volume := 0
	var max_axis := 1

	for slot in range(ROTATION_SLOTS):
		var raw_records := _build_slot_sample_records(
			occupancy,
			props,
			fp_grid,
			fp_pivot,
			slot,
			asset_footprint,
			scene_voxel_size,
			use_scene_units
		)
		var records := _limit_sample_records(raw_records, max_records_per_slot)
		per_slot_records.append(records)
		var sample_count := records.size() / SAMPLE_RECORD_STRIDE_INTS
		sample_counts[slot] = sample_count
		max_sample_count = maxi(max_sample_count, sample_count)

		var bounds := _sample_bounds_for_records(records)
		bounds["rotation_slot"] = slot
		bounds_by_slot.append(bounds)
		_write_sample_bounds_i32(bounds_i32, slot, bounds, sample_count)
		var span: Vector3i = bounds.get("span", Vector3i.ZERO)
		max_axis = maxi(max_axis, maxi(span.x, maxi(span.y, span.z)))
		max_bounds_volume = maxi(max_bounds_volume, int(bounds.get("bounds_volume", 0)))

	if max_sample_count <= 0:
		return _empty_rotation_sample_profile("no_valid_samples")

	var variant_capacity := max_sample_count
	var sample_group_count := clampi(
		_ceili_div(max_sample_count, SAMPLE_GROUP_SIZE), 1, MAX_SAMPLE_GROUPS)
	var packed_records := _pack_rotation_sample_records(per_slot_records, variant_capacity)
	return {
		"ok": true,
		"reason": "ok",
		"variant_capacity": variant_capacity,
		"sample_group_count": sample_group_count,
		"max_sample_count": max_sample_count,
		"sample_extent": clampi(max_axis, 1, MAX_VARIANT_AXIS),
		"max_bounds_volume": max_bounds_volume,
		"sample_counts": sample_counts,
		"counts_bytes": sample_counts.to_byte_array(),
		"sample_bounds": bounds_i32,
		"bounds_bytes": bounds_i32.to_byte_array(),
		"bounds_by_slot": bounds_by_slot,
		"records": packed_records,
		"records_bytes": packed_records.to_byte_array(),
		"max_variants_per_rotation": MAX_VARIANTS_PER_ROTATION,
		"scene_voxel_units": use_scene_units,
		"scene_voxel_size": scene_voxel_size if use_scene_units else Vector3.ZERO,
	}


## 为单个旋转槽构建去重后的采样记录：旋转每个被占用的足迹体素，按偏移量
## 去重，同一偏移保留碰撞强度更高的足迹索引。
static func _build_slot_sample_records(
	occupancy: PackedInt32Array,
	props: PackedFloat32Array,
	fp_grid: Vector3i,
	fp_pivot: Vector3i,
	rotation_slot: int,
	asset_footprint: Dictionary = {},
	scene_voxel_size: Vector3 = Vector3.ZERO,
	use_scene_units: bool = false
) -> PackedInt32Array:
	var records := PackedInt32Array()
	var offset_to_record := {}
	var angle := float(clampi(rotation_slot, 0, ROTATION_SLOTS - 1)) * TAU / float(ROTATION_SLOTS)
	var ca := cos(angle)
	var sa := sin(angle)
	for y in range(fp_grid.y):
		for z in range(fp_grid.z):
			for x in range(fp_grid.x):
				var fp_index := x + fp_grid.x * (z + fp_grid.z * y)
				if occupancy[fp_index] == 0:
					continue
				var offset := Vector3i.ZERO
				if use_scene_units:
					offset = _scene_voxel_offset_for_asset_voxel(
						Vector3i(x, y, z),
						asset_footprint,
						scene_voxel_size,
						ca,
						sa
					)
				else:
					var rel := Vector3i(x - fp_pivot.x, y - fp_pivot.y, z - fp_pivot.z)
					offset = Vector3i(
						int(round(ca * float(rel.x) + sa * float(rel.z))),
						rel.y,
						int(round(-sa * float(rel.x) + ca * float(rel.z)))
					)
				var key := "%d,%d,%d" % [offset.x, offset.y, offset.z]
				if not offset_to_record.has(key):
					offset_to_record[key] = records.size() / SAMPLE_RECORD_STRIDE_INTS
					records.append(offset.x)
					records.append(offset.y)
					records.append(offset.z)
					records.append(fp_index)
				else:
					var record_index := int(offset_to_record[key])
					var old_fp_index := records[record_index * SAMPLE_RECORD_STRIDE_INTS + 3]
					if _footprint_collision_strength(props, fp_index) > _footprint_collision_strength(props, old_fp_index):
						records[record_index * SAMPLE_RECORD_STRIDE_INTS + 3] = fp_index
	return records


## 将记录数下采样到不超过 max_record_count（按均匀步长抽样保留）。
static func _limit_sample_records(records: PackedInt32Array, max_record_count: int) -> PackedInt32Array:
	var record_count := records.size() / SAMPLE_RECORD_STRIDE_INTS
	var safe_max := clampi(max_record_count, 1, MAX_VARIANTS_PER_ROTATION)
	if record_count <= safe_max:
		return records
	var limited := PackedInt32Array()
	limited.resize(safe_max * SAMPLE_RECORD_STRIDE_INTS)
	for i in range(safe_max):
		var src_record := int(floor(float(i) * float(record_count) / float(safe_max)))
		var src_base := src_record * SAMPLE_RECORD_STRIDE_INTS
		var dst_base := i * SAMPLE_RECORD_STRIDE_INTS
		limited[dst_base] = records[src_base]
		limited[dst_base + 1] = records[src_base + 1]
		limited[dst_base + 2] = records[src_base + 2]
		limited[dst_base + 3] = records[src_base + 3]
	return limited


## 将各旋转槽的记录打包进一个扁平数组，每槽使用固定的容量步长。
static func _pack_rotation_sample_records(per_slot_records: Array, variant_capacity: int) -> PackedInt32Array:
	var safe_capacity := clampi(variant_capacity, 1, MAX_VARIANTS_PER_ROTATION)
	var packed := PackedInt32Array()
	packed.resize(ROTATION_SLOTS * safe_capacity * SAMPLE_RECORD_STRIDE_INTS)
	for slot in range(ROTATION_SLOTS):
		if slot >= per_slot_records.size() or not (per_slot_records[slot] is PackedInt32Array):
			continue
		var records := per_slot_records[slot] as PackedInt32Array
		var count := mini(records.size() / SAMPLE_RECORD_STRIDE_INTS, safe_capacity)
		var dst_slot_base := slot * safe_capacity * SAMPLE_RECORD_STRIDE_INTS
		for i in range(count * SAMPLE_RECORD_STRIDE_INTS):
			packed[dst_slot_base + i] = records[i]
	return packed


## 计算一组采样记录的最小/最大偏移、跨度 span 与包围盒体积。
static func _sample_bounds_for_records(records: PackedInt32Array) -> Dictionary:
	var count := records.size() / SAMPLE_RECORD_STRIDE_INTS
	if count <= 0:
		return {
			"min_offset": Vector3i.ZERO,
			"max_offset": Vector3i.ZERO,
			"max_exclusive": Vector3i.ZERO,
			"span": Vector3i.ZERO,
			"bounds_volume": 0,
		}
	var inf := 1073741824
	var min_offset := Vector3i(inf, inf, inf)
	var max_offset := Vector3i(-inf, -inf, -inf)
	for i in range(count):
		var base := i * SAMPLE_RECORD_STRIDE_INTS
		var offset := Vector3i(records[base], records[base + 1], records[base + 2])
		min_offset.x = mini(min_offset.x, offset.x)
		min_offset.y = mini(min_offset.y, offset.y)
		min_offset.z = mini(min_offset.z, offset.z)
		max_offset.x = maxi(max_offset.x, offset.x)
		max_offset.y = maxi(max_offset.y, offset.y)
		max_offset.z = maxi(max_offset.z, offset.z)
	var max_exclusive := max_offset + Vector3i.ONE
	var span := max_exclusive - min_offset
	return {
		"min_offset": min_offset,
		"max_offset": max_offset,
		"max_exclusive": max_exclusive,
		"span": span,
		"bounds_volume": span.x * span.y * span.z,
	}


## 将单个旋转槽的包围盒信息（min_offset、sample_count、max_exclusive、
## bounds_volume）写入打包好的 i32 边界数组对应位置。
static func _write_sample_bounds_i32(
	bounds_i32: PackedInt32Array,
	rotation_slot: int,
	bounds: Dictionary,
	sample_count: int
) -> void:
	var base := rotation_slot * SAMPLE_BOUNDS_STRIDE_INTS
	if base + SAMPLE_BOUNDS_STRIDE_INTS > bounds_i32.size():
		return
	var min_offset: Vector3i = bounds.get("min_offset", Vector3i.ZERO)
	var max_exclusive: Vector3i = bounds.get("max_exclusive", Vector3i.ZERO)
	bounds_i32[base] = min_offset.x
	bounds_i32[base + 1] = min_offset.y
	bounds_i32[base + 2] = min_offset.z
	bounds_i32[base + 3] = sample_count
	bounds_i32[base + 4] = max_exclusive.x
	bounds_i32[base + 5] = max_exclusive.y
	bounds_i32[base + 6] = max_exclusive.z
	bounds_i32[base + 7] = int(bounds.get("bounds_volume", 0))


## 判断能否构建“场景体素单位”剖面：场景体素尺寸与资产 cell_size 须均为正。
static func _can_build_scene_voxel_profile(
	asset_footprint: Dictionary,
	scene_voxel_size: Vector3
) -> bool:
	if scene_voxel_size.x <= 0.000001 \
			or scene_voxel_size.y <= 0.000001 \
			or scene_voxel_size.z <= 0.000001:
		return false
	return float(asset_footprint.get("cell_size", 0.0)) > 0.000001


## 判断缓存剖面记录的场景体素尺寸是否与给定尺寸近似相等。
static func _profile_matches_scene_voxel_size(profile: Dictionary, scene_voxel_size: Vector3) -> bool:
	var cached: Vector3 = profile.get("scene_voxel_size", Vector3.ZERO)
	return is_equal_approx(cached.x, scene_voxel_size.x) \
		and is_equal_approx(cached.y, scene_voxel_size.y) \
		and is_equal_approx(cached.z, scene_voxel_size.z)


## 将资产网格体素坐标转换为相对足迹中心（pivot）、经 yaw 旋转的场景体素偏移。
static func _scene_voxel_offset_for_asset_voxel(
	coord: Vector3i,
	asset_footprint: Dictionary,
	scene_voxel_size: Vector3,
	ca: float,
	sa: float
) -> Vector3i:
	var cell_size := float(asset_footprint.get("cell_size", 1.0))
	var aabb_min: Vector3 = asset_footprint.get("aabb_min", Vector3.ZERO)
	var fp_grid: Vector3i = asset_footprint.get("grid", Vector3i.ONE)
	var aabb_size: Vector3 = asset_footprint.get(
		"aabb_size",
		Vector3(float(fp_grid.x), float(fp_grid.y), float(fp_grid.z)) * cell_size
	)
	var pivot_local: Vector3 = asset_footprint.get(
		"pivot_local",
		aabb_min + Vector3(aabb_size.x * 0.5, 0.0, aabb_size.z * 0.5)
	)
	var coord_f := Vector3(float(coord.x), float(coord.y), float(coord.z))
	var local_center := aabb_min + (coord_f + Vector3(0.5, 0.5, 0.5)) * cell_size
	var rel := local_center - pivot_local
	var rx := ca * rel.x + sa * rel.z
	var rz := -sa * rel.x + ca * rel.z
	return Vector3i(
		int(round(rx / scene_voxel_size.x)),
		int(floor(rel.y / scene_voxel_size.y)),
		int(round(rz / scene_voxel_size.z))
	)


## 由足迹网格尺寸（各轴钳制后相乘）计算每个旋转槽的最大采样记录数。
static func _variant_capacity_for_grid(fp_grid: Vector3i) -> int:
	var sx := clampi(fp_grid.x, 1, MAX_VARIANT_AXIS)
	var sy := clampi(fp_grid.y, 1, MAX_VARIANT_AXIS)
	var sz := clampi(fp_grid.z, 1, MAX_VARIANT_AXIS)
	return clampi(sx * sy * sz, 1, MAX_VARIANTS_PER_ROTATION)


## 返回指定足迹体素索引的碰撞强度（props[idx*4+3]）；索引越界时返回 0。
static func _footprint_collision_strength(props: PackedFloat32Array, fp_index: int) -> float:
	var base := fp_index * 4 + 3
	if fp_index < 0 or base >= props.size():
		return 0.0
	return props[base]


## 整数向上取整除法（value 钳为非负，divisor 钳为至少 1）。
static func _ceili_div(value: int, divisor: int) -> int:
	return (maxi(value, 0) + maxi(divisor, 1) - 1) / maxi(divisor, 1)


## 返回一个全部置零的空采样剖面字典（ok=false，并附失败原因 reason）。
static func _empty_rotation_sample_profile(reason: String) -> Dictionary:
	var counts := PackedInt32Array()
	counts.resize(ROTATION_SLOTS)
	var bounds := PackedInt32Array()
	bounds.resize(ROTATION_SLOTS * SAMPLE_BOUNDS_STRIDE_INTS)
	var records := PackedInt32Array()
	records.resize(ROTATION_SLOTS * SAMPLE_RECORD_STRIDE_INTS)
	return {
		"ok": false,
		"reason": reason,
		"variant_capacity": 1,
		"sample_group_count": 1,
		"max_sample_count": 0,
		"sample_extent": 1,
		"sample_counts": counts,
		"counts_bytes": counts.to_byte_array(),
		"sample_bounds": bounds,
		"bounds_bytes": bounds.to_byte_array(),
		"bounds_by_slot": [],
		"records": records,
		"records_bytes": records.to_byte_array(),
		"max_variants_per_rotation": MAX_VARIANTS_PER_ROTATION,
		"scene_voxel_units": false,
		"scene_voxel_size": Vector3.ZERO,
	}


## 从 score_all_assets() 的回读结果，为某个 anchor 构建按分数排序的资产列表（前 K 个）。
static func build_anchor_asset_topk(
	score_results: Array,
	assets: Array,
	anchor_index: int,
	top_k: int
) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	if anchor_index < 0 or top_k <= 0:
		return entries
	for result_index in range(score_results.size()):
		var result = score_results[result_index]
		if not result is Dictionary:
			continue
		var result_dict := result as Dictionary
		var asset_index := int(result_dict.get("asset_index", result_index))
		var entry := {
			"asset_index": asset_index,
			"asset_name": _asset_name_for_topk(assets, asset_index),
			"score": -INF,
			"rotation_slot": -1,
			"yaw": 0.0,
			"valid": false,
			"ok": bool(result_dict.get("ok", false)),
			"reason": str(result_dict.get("reason", "")),
		}
		if bool(result_dict.get("ok", false)):
			var per_anchor: Array = result_dict.get("anchor_results", [])
			if anchor_index < per_anchor.size() and per_anchor[anchor_index] is Dictionary:
				var anchor_result := per_anchor[anchor_index] as Dictionary
				entry["score"] = float(anchor_result.get("score", -INF))
				entry["rotation_slot"] = int(anchor_result.get("rotation_slot", -1))
				entry["yaw"] = float(anchor_result.get("yaw", 0.0))
				entry["valid"] = bool(anchor_result.get("valid", false))
		entries.append(entry)
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_valid := bool(a.get("valid", false))
		var b_valid := bool(b.get("valid", false))
		if a_valid != b_valid:
			return a_valid
		var a_score := float(a.get("score", -INF))
		var b_score := float(b.get("score", -INF))
		if not is_equal_approx(a_score, b_score):
			return a_score > b_score
		return int(a.get("asset_index", 0)) < int(b.get("asset_index", 0))
	)
	var limit := mini(entries.size(), top_k)
	var top_entries: Array[Dictionary] = []
	for rank in range(limit):
		var ranked := entries[rank].duplicate(true)
		ranked["rank"] = rank + 1
		top_entries.append(ranked)
	return top_entries


## 返回每个 anchor 的最佳有效资产索引；该 anchor 无任何评分时为 -1。
static func best_asset_per_anchor(score_results: Array, anchor_count: int) -> PackedInt32Array:
	var winners := PackedInt32Array()
	winners.resize(maxi(anchor_count, 0))
	for anchor_index in range(winners.size()):
		winners[anchor_index] = best_asset_index_for_anchor(score_results, anchor_index)
	return winners


## 返回第一个含任意有效评分的 anchor 索引；都没有则返回 -1。
static func first_anchor_with_valid_score(score_results: Array, anchor_count: int) -> int:
	for anchor_index in range(anchor_count):
		for result in score_results:
			if not (result is Dictionary):
				continue
			var result_dict := result as Dictionary
			if not bool(result_dict.get("ok", false)):
				continue
			var per_anchor: Array = result_dict.get("anchor_results", [])
			if anchor_index >= per_anchor.size() or not (per_anchor[anchor_index] is Dictionary):
				continue
			var entry := per_anchor[anchor_index] as Dictionary
			if bool(entry.get("valid", false)):
				return anchor_index
	return -1


## 返回指定 anchor 上有效分数最高的资产索引；无有效评分则返回 -1。
static func best_asset_index_for_anchor(score_results: Array, anchor_index: int) -> int:
	if anchor_index < 0:
		return -1
	var best_score := -INF
	var best_asset := -1
	for result_index in range(score_results.size()):
		var result = score_results[result_index]
		if not (result is Dictionary):
			continue
		var result_dict := result as Dictionary
		if not bool(result_dict.get("ok", false)):
			continue
		var per_anchor: Array = result_dict.get("anchor_results", [])
		if anchor_index >= per_anchor.size() or not (per_anchor[anchor_index] is Dictionary):
			continue
		var anchor_result := per_anchor[anchor_index] as Dictionary
		if not bool(anchor_result.get("valid", false)):
			continue
		var score := float(anchor_result.get("score", -INF))
		if score > best_score:
			best_score = score
			best_asset = int(result_dict.get("asset_index", result_index))
	return best_asset


## 返回指定 资产+anchor 的单 anchor 结果字典；未找到或无效时返回空字典 {}。
static func anchor_result_for_asset(score_results: Array, asset_index: int, anchor_index: int) -> Dictionary:
	if asset_index < 0 or anchor_index < 0:
		return {}
	for result in score_results:
		if not (result is Dictionary):
			continue
		var result_dict := result as Dictionary
		if not bool(result_dict.get("ok", false)):
			continue
		if int(result_dict.get("asset_index", -1)) != asset_index:
			continue
		var per_anchor: Array = result_dict.get("anchor_results", [])
		if anchor_index >= per_anchor.size() or not (per_anchor[anchor_index] is Dictionary):
			return {}
		return (per_anchor[anchor_index] as Dictionary).duplicate(true)
	return {}


## 镜像 score_object_subtile.glsl，返回指定资产的场景体素单元包围盒。
## 即使该资产在此 anchor 没有有效评分，仍会用其足迹采样剖面来确定
## 包围盒与采样分配的元数据。
static func anchor_sample_bounds_info(
	score_results: Array,
	assets: Array,
	asset_footprints: Array,
	scene_fields: Dictionary,
	anchors: PackedVector3Array,
	anchor_index: int,
	asset_index: int = -1
) -> Dictionary:
	if anchor_index < 0 or anchor_index >= anchors.size():
		return {}
	var resolved_asset_index := asset_index
	if resolved_asset_index < 0:
		resolved_asset_index = best_asset_index_for_anchor(score_results, anchor_index)
	if resolved_asset_index < 0 or resolved_asset_index >= asset_footprints.size():
		return {}

	var footprint_value = asset_footprints[resolved_asset_index]
	if not (footprint_value is Dictionary):
		return {}
	var footprint := footprint_value as Dictionary
	var voxel_size: Vector3 = scene_fields.get("voxel_size", Vector3.ONE)
	var sample_profile := ensure_rotation_sample_profile(footprint, voxel_size)
	if not bool(sample_profile.get("ok", false)):
		return {}
	var anchor_result := anchor_result_for_asset(score_results, resolved_asset_index, anchor_index)
	var score_valid := not anchor_result.is_empty() and bool(anchor_result.get("valid", false))
	var rotation_slot := clampi(
		int(anchor_result.get("rotation_slot", 0)),
		0,
		ROTATION_SLOTS - 1
	)
	var scene_grid: Vector3i = scene_fields.get("grid", scene_fields.get("grid_size", Vector3i.ZERO))
	var voxel_bounds := anchor_contributing_voxel_bounds(
		footprint,
		scene_grid,
		anchor_voxel_at(anchors, anchor_index),
		int(sample_profile.get("sample_extent", 1)),
		rotation_slot,
		voxel_size
	)
	if voxel_bounds.is_empty():
		return {}

	var min_voxel: Vector3i = voxel_bounds.get("min_voxel", Vector3i.ZERO)
	var max_voxel: Vector3i = voxel_bounds.get("max_voxel", Vector3i.ZERO)
	var span := max_voxel - min_voxel + Vector3i.ONE
	var origin: Vector3 = scene_fields.get("grid_origin", Vector3.ZERO)
	var min_corner := VoxelGeneral.voxel_to_world(min_voxel, origin, voxel_size)
	var size := VoxelGeneral.voxel_span_to_world_size(span, voxel_size)
	return {
		"bounds_kind": "score_footprint" if score_valid else "asset_footprint_no_score",
		"asset_index": resolved_asset_index,
		"asset_name": _asset_name_for_topk(assets, resolved_asset_index),
		"sample_extent": int(sample_profile.get("sample_extent", 1)),
		"sample_group_count": int(sample_profile.get("sample_group_count", 0)),
		"max_sample_count": int(sample_profile.get("max_sample_count", 0)),
		"sample_variant_capacity": int(sample_profile.get("variant_capacity", 0)),
		"sample_voxel_count": int(voxel_bounds.get("sample_count", 0)),
		"sample_variant_count": int(voxel_bounds.get("sample_count", 0)),
		"sample_bounds_volume": int(voxel_bounds.get("bounds_volume", 0)),
		"rotation_slot": rotation_slot,
		"yaw": float(anchor_result.get("yaw", 0.0)),
		"score_valid": score_valid,
		"score": float(anchor_result.get("score", -INF)),
		"min_voxel": min_voxel,
		"max_voxel": max_voxel,
		"contributing_voxel_count": int(voxel_bounds.get("voxel_count", 0)),
		"position": min_corner,
		"size": size,
		"aabb": AABB(min_corner, size),
	}


## 计算某旋转槽在指定 anchor 处、落在场景网格内的足迹采样点的世界体素 AABB。
static func anchor_contributing_voxel_bounds(
	asset_footprint: Dictionary,
	scene_grid: Vector3i,
	anchor_voxel: Vector3i,
	_sample_extent: int,
	rotation_slot: int,
	scene_voxel_size: Vector3 = Vector3.ZERO
) -> Dictionary:
	if scene_grid.x <= 0 or scene_grid.y <= 0 or scene_grid.z <= 0:
		return {}
	var sample_profile := ensure_rotation_sample_profile(asset_footprint, scene_voxel_size)
	if not bool(sample_profile.get("ok", false)):
		return {}
	var variant_capacity := int(sample_profile.get("variant_capacity", 0))
	var sample_counts: PackedInt32Array = sample_profile.get("sample_counts", PackedInt32Array())
	var records: PackedInt32Array = sample_profile.get("records", PackedInt32Array())
	var slot := clampi(rotation_slot, 0, ROTATION_SLOTS - 1)
	if variant_capacity <= 0 or slot >= sample_counts.size():
		return {}
	var sample_count := sample_counts[slot]
	var slot_base := slot * variant_capacity * SAMPLE_RECORD_STRIDE_INTS
	if sample_count <= 0 or slot_base + sample_count * SAMPLE_RECORD_STRIDE_INTS > records.size():
		return {}
	var inf := 1073741824
	var min_voxel := Vector3i(inf, inf, inf)
	var max_voxel := Vector3i(-inf, -inf, -inf)
	var hit_count := 0

	for i in range(sample_count):
		var base := slot_base + i * SAMPLE_RECORD_STRIDE_INTS
		var offset := Vector3i(records[base], records[base + 1], records[base + 2])
		var world_pos := anchor_voxel + offset
		if not _voxel_in_grid(world_pos, scene_grid):
			continue
		min_voxel.x = mini(min_voxel.x, world_pos.x)
		min_voxel.y = mini(min_voxel.y, world_pos.y)
		min_voxel.z = mini(min_voxel.z, world_pos.z)
		max_voxel.x = maxi(max_voxel.x, world_pos.x)
		max_voxel.y = maxi(max_voxel.y, world_pos.y)
		max_voxel.z = maxi(max_voxel.z, world_pos.z)
		hit_count += 1

	if hit_count <= 0:
		return {}
	var span := max_voxel - min_voxel + Vector3i.ONE
	return {
		"min_voxel": min_voxel,
		"max_voxel": max_voxel,
		"voxel_count": hit_count,
		"sample_count": sample_count,
		"bounds_volume": span.x * span.y * span.z,
	}


## 解析资产显示名（优先字典 "name"，其次对象的 name，否则回退为 "Asset{N}"）。
static func _asset_name_for_topk(assets: Array, asset_index: int) -> String:
	if asset_index < 0 or asset_index >= assets.size():
		return "Asset%d" % asset_index
	var asset = assets[asset_index]
	if asset is Dictionary:
		var asset_dict := asset as Dictionary
		return str(asset_dict.get("name", "Asset%d" % asset_index))
	if asset is Object:
		var object := asset as Object
		var object_name = object.get("name")
		if object_name != null and not str(object_name).is_empty():
			return str(object_name)
	return "Asset%d" % asset_index


## 返回 anchor 的整数体素坐标；索引越界时返回 fallback。
static func anchor_voxel_at(
	anchors: PackedVector3Array,
	anchor_index: int,
	fallback: Vector3i = Vector3i.ZERO
) -> Vector3i:
	if anchor_index < 0 or anchor_index >= anchors.size():
		return fallback
	var anchor := anchors[anchor_index]
	return Vector3i(int(anchor.x), int(anchor.y), int(anchor.z))


## 边界检查：体素在各轴上均位于 [0, grid) 范围内时返回 true。
static func _voxel_in_grid(voxel: Vector3i, grid: Vector3i) -> bool:
	return (
		voxel.x >= 0
		and voxel.y >= 0
		and voxel.z >= 0
		and voxel.x < grid.x
		and voxel.y < grid.y
		and voxel.z < grid.z
	)


## 由 MeshVoxelizerGpu 的结果构建足迹（footprint）数据。
## world_aabb_longest 为网格世界空间 AABB 的最长轴（米），
## 仅用于兼容/调试分级（tier）的展示。
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
	var voxel_count := VoxelGeneral.voxel_count(grid)
	var cell_size := float(result.get("cell_size", 1.0))
	var aabb_min: Vector3 = result.get("aabb_min", Vector3.ZERO)
	var aabb_size: Vector3 = result.get(
		"aabb_size",
		Vector3(float(grid.x), float(grid.y), float(grid.z)) * cell_size
	)
	var pivot_local := aabb_min + Vector3(aabb_size.x * 0.5, 0.0, aabb_size.z * 0.5)

	var occ := PackedInt32Array()
	occ.resize(voxel_count)
	var props := PackedFloat32Array()
	props.resize(voxel_count * 4)

	for v in voxels:
		var coord: Vector3i = v["voxel"]
		var idx := VoxelGeneral.voxel_index(coord, grid)
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

	var footprint := {
		"grid": grid,
		"pivot": pivot,
		"occupancy_bytes": occ.to_byte_array(),
		"props_bytes": props.to_byte_array(),
		"color": asset_color,
		"world_aabb_longest": world_aabb_longest,
		"cell_size": cell_size,
		"aabb_min": aabb_min,
		"aabb_size": aabb_size,
		"pivot_local": pivot_local,
	}
	footprint["rotation_sample_profile"] = build_rotation_sample_profile(footprint)
	return footprint
