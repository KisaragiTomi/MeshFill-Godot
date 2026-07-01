@tool
class_name ObjectVolumeScoreGpu
extends "res://scripts/godot_compute_shader_base.gd"

## 3D object volume scoring GPU pipeline.
##
## Implements the two-pass architecture from placement-score-3d.md:
##   Pass A: score_object_subtile.glsl  — per-rotation valid sample accumulation
##   Pass B: reduce_object_rotation_scores.glsl — reduce + best rotation pick
##
## Usage:
##   var scorer = ObjectVolumeScoreGpu.new()
##   var results = scorer.score_all_assets(scene_fields, asset_footprints, anchors)
##   scorer.dispose()

const SCORE_SUBTILE_SHADER := "res://shaders/score_object_subtile.glsl"
const REDUCE_SHADER := "res://shaders/reduce_object_rotation_scores.glsl"
const BufferUtils := preload("res://scripts/utils/buffer_utils.gd")

## descriptor voxel-profile source. 评分采样点取自 profile.collision 的体素位置。
const AutoVoxelProfileScript := preload("res://scripts/auto_voxel_profile.gd")

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

	# Scene fields upload as 8-bit 3D textures sampled with hardware trilinear in
	# the score shader. Texture dims (gx, gz, gy) make the byte order
	# x + gx*(z + gz*y) match the shader's sv_idx layout. complexity/target are
	# RGBA8 (a = complexity/coverage); collision is R8.
	var field_sampler := _create_clamped_linear_sampler()
	var field_usage := RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var cx_tex := upload_texture_3d(
		grid.x, grid.z, grid.y, scene_fields["complexity_bytes"],
		RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM, field_usage, SCOPE_FRAME, "scene_complexity")
	var coll_tex := upload_texture_3d(
		grid.x, grid.z, grid.y, scene_fields["collision_bytes"],
		RenderingDevice.DATA_FORMAT_R8_UNORM, field_usage, SCOPE_FRAME, "scene_collision")
	var target_tex := upload_texture_3d(
		grid.x, grid.z, grid.y, scene_fields["target_bytes"],
		RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM, field_usage, SCOPE_FRAME, "scene_target")
	if not (field_sampler.is_valid() and cx_tex.is_valid() and coll_tex.is_valid() and target_tex.is_valid()):
		push_error("[%s] Failed to create scene field 3D textures/sampler" % log_name)
		dispose()
		return results

	var max_partial_count := anchor_count * MAX_SAMPLE_GROUPS * ROTATION_SLOTS
	var partial_buf := storage_buffer_zero(
		max_partial_count * 4, SCOPE_FRAME, "partials")
	var result_count := anchor_count * RESULT_STRIDE
	var result_buf := storage_buffer_zero(
		result_count * 16, SCOPE_FRAME, "results")

	for asset_idx in range(asset_footprints.size()):
		var fp: Dictionary = asset_footprints[asset_idx]
		var fp_grid: Vector3i = fp.get("grid", Vector3i.ZERO)
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
		# GPU 采样用连续偏移（frac_records）做 8 邻三线性插值；整数 records 仅供 CPU bounds。
		var sample_records_buf := storage_buffer_from_bytes(
			sample_profile["frac_records_bytes"], SCOPE_PASS, "sample_records_%d" % asset_idx)
		var sample_counts_buf := storage_buffer_from_bytes(
			sample_profile["counts_bytes"], SCOPE_PASS, "sample_counts_%d" % asset_idx)
		var fp_props_buf := storage_buffer_from_bytes(
			fp["props_bytes"], SCOPE_PASS, "fp_props_%d" % asset_idx)

		var partial_count := anchor_count * sample_group_count * ROTATION_SLOTS
		buffer_zero(partial_buf, partial_count * 4)
		buffer_zero(result_buf, result_count * 16)

		var asset_color: Color = fp.get("color", Color(0.5, 0.5, 0.5, 0.5))
		_dispatch_pass_a(
			cx_tex, coll_tex, target_tex, field_sampler,
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


## 创建 CLAMP_TO_EDGE 的线性采样器，供场景场 3D 纹理在评分着色器中做硬件三线性采样。
func _create_clamped_linear_sampler() -> RID:
	var rd := get_rendering_device()
	if rd == null:
		return RID()
	var state := RDSamplerState.new()
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	return track_rid(rd.sampler_create(state), KIND_SAMPLER, SCOPE_FRAME, "scene_field_sampler")


## 派发 Pass A：逐旋转累计有效采样点。绑定场景/采样/anchor 缓冲与推送常量，
## 以 (sample_group_count, anchor_count, 1) 网格分发，并加入计算屏障。
func _dispatch_pass_a(
	cx_tex: RID, coll_tex: RID, target_tex: RID, field_sampler: RID,
	sample_records_buf: RID, fp_props_buf: RID, anchor_buf: RID,
	sample_counts_buf: RID, partial_buf: RID,
	grid: Vector3i, asset_color: Color,
	anchor_count: int, variant_capacity: int, sample_group_count: int, max_sample_count: int
) -> void:
	var rd := get_rendering_device()
	var set0 := create_uniform_set([
		make_sampler_uniform(0, field_sampler, cx_tex),
		make_sampler_uniform(1, field_sampler, coll_tex),
		make_sampler_uniform(2, field_sampler, target_tex),
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
	data.resize(anchors.size() * BufferUtils.IVEC4_BYTES)
	for i in range(anchors.size()):
		var a := anchors[i]
		BufferUtils.encode_vec3i4(data, i * BufferUtils.IVEC4_BYTES, Vector3i(int(a.x), int(a.y), int(a.z)))
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


## 获取资产的旋转采样剖面（场景体素单位）：命中缓存且体素尺寸匹配则复用，
## 否则现场构建并写回缓存。
static func ensure_rotation_sample_profile(
	asset_footprint: Dictionary,
	scene_voxel_size: Vector3 = Vector3.ZERO
) -> Dictionary:
	var profile_value = asset_footprint.get("rotation_sample_profile", {})
	if profile_value is Dictionary:
		var profile := profile_value as Dictionary
		if bool(profile.get("ok", false)) \
				and _profile_matches_scene_voxel_size(profile, scene_voxel_size):
			return profile
	var built := build_rotation_sample_profile(asset_footprint, scene_voxel_size)
	asset_footprint["rotation_sample_profile"] = built
	return built


## 为每个 yaw 旋转槽构建精确的占用足迹采样。每条记录为
## ivec4(scene_offset.xyz, footprint_props_index)，按旋转槽分别打包。
static func build_rotation_sample_profile(
	asset_footprint: Dictionary,
	scene_voxel_size: Vector3 = Vector3.ZERO
) -> Dictionary:
	var fp_grid: Vector3i = asset_footprint.get("grid", Vector3i.ZERO)
	var fp_voxel_count := fp_grid.x * fp_grid.y * fp_grid.z
	if fp_voxel_count <= 0:
		return _empty_rotation_sample_profile("empty_footprint")
	if not _can_build_scene_voxel_profile(asset_footprint, scene_voxel_size):
		return _empty_rotation_sample_profile("missing_scene_voxel_units")
	var props_bytes: PackedByteArray = asset_footprint.get("props_bytes", PackedByteArray())
	var props := props_bytes.to_float32_array()
	if props.size() < fp_voxel_count * 4:
		return _empty_rotation_sample_profile("props_size_mismatch")
	var profile_voxels := _profile_collision_voxels(asset_footprint)
	if profile_voxels.is_empty():
		return _empty_rotation_sample_profile("no_profile_samples")

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
			profile_voxels,
			props,
			fp_grid,
			slot,
			asset_footprint,
			scene_voxel_size
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
	var packed_frac_records := _pack_rotation_frac_records(
		packed_records, sample_counts, variant_capacity, asset_footprint, scene_voxel_size)
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
		"frac_records": packed_frac_records,
		"frac_records_bytes": packed_frac_records.to_byte_array(),
		"max_variants_per_rotation": MAX_VARIANTS_PER_ROTATION,
		"scene_voxel_units": true,
		"scene_voxel_size": scene_voxel_size,
	}


## 为单个旋转槽构建去重后的采样记录：采样点取自 descriptor voxel_profile 的 collision
## 体素位置（局部体素→世界→场景体素偏移）。按偏移去重，同一偏移保留碰撞强度更高的足迹索引。
static func _build_slot_sample_records(
	profile_voxels: Array,
	props: PackedFloat32Array,
	fp_grid: Vector3i,
	rotation_slot: int,
	asset_footprint: Dictionary,
	scene_voxel_size: Vector3
) -> PackedInt32Array:
	var records := PackedInt32Array()
	var offset_to_record := {}
	var angle := float(clampi(rotation_slot, 0, ROTATION_SLOTS - 1)) * TAU / float(ROTATION_SLOTS)
	var ca := cos(angle)
	var sa := sin(angle)
	var voxel_count := props.size() / 4
	for coord in profile_voxels:
		var fp_index := VoxelGeneral.voxel_index(coord, fp_grid)
		if fp_index < 0 or fp_index >= voxel_count:
			continue
		_accumulate_slot_sample_record(
			records, offset_to_record, props, coord, fp_index,
			asset_footprint, scene_voxel_size, ca, sa)
	return records


## 把一个足迹体素（局部体素坐标）转成场景体素偏移并累加到记录表：新偏移建记录，
## 重复偏移保留碰撞强度更高的足迹索引（fp_index 供着色器查 props 颜色/碰撞）。
static func _accumulate_slot_sample_record(
	records: PackedInt32Array,
	offset_to_record: Dictionary,
	props: PackedFloat32Array,
	coord: Vector3i,
	fp_index: int,
	asset_footprint: Dictionary,
	scene_voxel_size: Vector3,
	ca: float,
	sa: float
) -> void:
	var offset := _scene_voxel_offset_for_asset_voxel(
		coord, asset_footprint, scene_voxel_size, ca, sa)
	var key := "%d,%d,%d" % [offset.x, offset.y, offset.z]
	if not offset_to_record.has(key):
		offset_to_record[key] = records.size() / SAMPLE_RECORD_STRIDE_INTS
		records.append(offset.x)
		records.append(offset.y)
		records.append(offset.z)
		records.append(fp_index)
		return
	var record_index := int(offset_to_record[key])
	var old_fp_index := records[record_index * SAMPLE_RECORD_STRIDE_INTS + 3]
	if _footprint_collision_strength(props, fp_index) > _footprint_collision_strength(props, old_fp_index):
		records[record_index * SAMPLE_RECORD_STRIDE_INTS + 3] = fp_index


## 读取 descriptor voxel_profile 的 collision 体素位置（asset 局部体素坐标）。
## 无 profile 或无点采样时返回空数组，build_rotation_sample_profile 据此判定无有效采样。
static func _profile_collision_voxels(asset_footprint: Dictionary) -> Array:
	var voxels: Array = []
	var profile = asset_footprint.get("voxel_profile", null)
	var samples: Array = []
	if profile != null and is_instance_valid(profile) and profile.has_method("get_collision"):
		samples = profile.get_collision()
	elif asset_footprint.has("collision_samples"):
		samples = asset_footprint.get("collision_samples", [])
	for raw in samples:
		if not (raw is Dictionary):
			continue
		var entry := raw as Dictionary
		if not (entry.has("voxel") or entry.has("local_pos") or entry.has("voxel_offset")):
			continue
		voxels.append(_sample_voxel_coord(
			entry.get("voxel", entry.get("local_pos", entry.get("voxel_offset", Vector3i.ZERO)))))
	return voxels


## 把采样项里的体素坐标值解析为 Vector3i（兼容 Vector3i / Vector3 / Array / Dictionary）。
static func _sample_voxel_coord(value) -> Vector3i:
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
		return Vector3i(int(d.get("x", 0)), int(d.get("y", 0)), int(d.get("z", 0)))
	return Vector3i.ZERO


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


## 将资产网格体素坐标转换为相对足迹中心（pivot）、经 yaw 旋转的**连续**场景体素偏移
## （未量化，单位为场景体素）。GPU 用它在 anchor+offset 处做 8 邻体素三线性插值采样，
## 而不是直接移动到体素中心。
static func _scene_voxel_frac_offset_for_asset_voxel(
	coord: Vector3i,
	asset_footprint: Dictionary,
	scene_voxel_size: Vector3,
	ca: float,
	sa: float
) -> Vector3:
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
	return Vector3(
		rx / scene_voxel_size.x,
		rel.y / scene_voxel_size.y,
		rz / scene_voxel_size.z
	)


## 上面连续偏移的量化版（x/z round、y floor），用作去重键与场景体素 bounds 元数据。
static func _scene_voxel_offset_for_asset_voxel(
	coord: Vector3i,
	asset_footprint: Dictionary,
	scene_voxel_size: Vector3,
	ca: float,
	sa: float
) -> Vector3i:
	var f := _scene_voxel_frac_offset_for_asset_voxel(
		coord, asset_footprint, scene_voxel_size, ca, sa)
	return Vector3i(
		int(round(f.x)),
		int(floor(f.y)),
		int(round(f.z))
	)


## 为 GPU 三线性采样打包每条保留样本的**连续**场景体素偏移（xyz）+ footprint props 索引
## （w，存为 float）。布局与 packed_records 完全一致（按 variant_capacity 步长分槽）；偏移由
## 该样本的 fp_index 反推体素坐标后用连续版重算，保证与去重/裁剪/排序后的整数记录逐条对应。
static func _pack_rotation_frac_records(
	packed_records: PackedInt32Array,
	sample_counts: PackedInt32Array,
	variant_capacity: int,
	asset_footprint: Dictionary,
	scene_voxel_size: Vector3
) -> PackedFloat32Array:
	var frac := PackedFloat32Array()
	frac.resize(packed_records.size())
	var fp_grid: Vector3i = asset_footprint.get("grid", Vector3i.ONE)
	var safe_capacity := clampi(variant_capacity, 1, MAX_VARIANTS_PER_ROTATION)
	for slot in range(ROTATION_SLOTS):
		if slot >= sample_counts.size():
			continue
		var angle := float(slot) * TAU / float(ROTATION_SLOTS)
		var ca := cos(angle)
		var sa := sin(angle)
		var count := sample_counts[slot]
		var slot_base := slot * safe_capacity * SAMPLE_RECORD_STRIDE_INTS
		for i in range(count):
			var base := slot_base + i * SAMPLE_RECORD_STRIDE_INTS
			if base + 3 >= packed_records.size():
				break
			var fp_index := packed_records[base + 3]
			var coord := VoxelGeneral.voxel_from_index(fp_index, fp_grid)
			var f := _scene_voxel_frac_offset_for_asset_voxel(
				coord, asset_footprint, scene_voxel_size, ca, sa)
			frac[base] = f.x
			frac[base + 1] = f.y
			frac[base + 2] = f.z
			frac[base + 3] = float(fp_index)
	return frac


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
	var frac_records := PackedFloat32Array()
	frac_records.resize(ROTATION_SLOTS * SAMPLE_RECORD_STRIDE_INTS)
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
		"frac_records": frac_records,
		"frac_records_bytes": frac_records.to_byte_array(),
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


## 返回指定资产在该 anchor 的 anchor bound（紧贴物体的世界 AABB，由 profile 体素世界
## 位置算出，不做场景体素量化）。即使该资产在此 anchor 没有有效评分，仍会用其足迹采样
## 剖面确定 anchor bound 与采样分配的元数据。
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
	var origin: Vector3 = scene_fields.get("grid_origin", Vector3.ZERO)
	# anchor bound：用 profile 体素世界位置算紧贴物体的 AABB（局部体素→世界、按 yaw 旋转、
	# 相对 pivot_local），不再用场景体素量化的 span——量化会把框按场景体素粒度放大。
	var world_rel := _anchor_world_relative_bounds(footprint, rotation_slot)
	var min_corner: Vector3
	var size: Vector3
	var obb_center := Vector3.ZERO
	var obb_size := Vector3.ZERO
	var obb_yaw := 0.0
	var has_obb := false
	if bool(world_rel.get("ok", false)):
		var anchor_center := VoxelGeneral.voxel_to_world(
			anchor_voxel_at(anchors, anchor_index), origin, voxel_size) + voxel_size * 0.5
		var min_rel: Vector3 = world_rel.get("min_rel", Vector3.ZERO)
		var max_rel: Vector3 = world_rel.get("max_rel", Vector3.ZERO)
		min_corner = anchor_center + min_rel
		size = max_rel - min_rel
		obb_center = anchor_center + (world_rel.get("obb_center_rel", Vector3.ZERO) as Vector3)
		obb_size = world_rel.get("obb_size", Vector3.ZERO)
		obb_yaw = float(world_rel.get("obb_yaw", 0.0))
		has_obb = true
	else:
		var span := max_voxel - min_voxel + Vector3i.ONE
		min_corner = VoxelGeneral.voxel_to_world(min_voxel, origin, voxel_size)
		size = VoxelGeneral.voxel_span_to_world_size(span, voxel_size)
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
		"obb_center": obb_center,
		"obb_size": obb_size,
		"obb_yaw": obb_yaw,
		"has_obb": has_obb,
	}


## 计算某旋转槽在指定 anchor 处、落在场景网格内的采样点的场景体素 AABB（仅用于采样
## 计数/元数据；可视的 anchor bound 见 _anchor_world_relative_bounds，按物体精度贴合）。
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


## anchor bound 的世界相对范围：由 profile 体素位置算紧贴物体的框，单位为相对 anchor
## (物体 pivot) 的世界米。取实心体素的局部 AABB（aabb_min + coord*cell_size，相对
## pivot_local），不做场景体素量化。返回两套：min_rel/max_rel 是轴对齐 AABB（会被旋转撑大）；
## obb_* 是 OBB（局部 AABB 尺寸 + 旋转中心 + yaw），渲染成带朝向的盒子，斜放也紧贴物体。
## 无 profile 体素时返回 ok=false。
static func _anchor_world_relative_bounds(
	asset_footprint: Dictionary,
	rotation_slot: int
) -> Dictionary:
	var profile_voxels := _profile_collision_voxels(asset_footprint)
	if profile_voxels.is_empty():
		return {"ok": false}
	var cell_size := float(asset_footprint.get("cell_size", 1.0))
	var aabb_min: Vector3 = asset_footprint.get("aabb_min", Vector3.ZERO)
	var fp_grid: Vector3i = asset_footprint.get("grid", Vector3i.ONE)
	var pivot_local: Vector3 = asset_footprint.get(
		"pivot_local",
		aabb_min + Vector3(float(fp_grid.x), 0.0, float(fp_grid.z)) * cell_size * 0.5)
	var big := 1073741824
	var min_c := Vector3i(big, big, big)
	var max_c := Vector3i(-big, -big, -big)
	for coord in profile_voxels:
		min_c.x = mini(min_c.x, coord.x)
		min_c.y = mini(min_c.y, coord.y)
		min_c.z = mini(min_c.z, coord.z)
		max_c.x = maxi(max_c.x, coord.x)
		max_c.y = maxi(max_c.y, coord.y)
		max_c.z = maxi(max_c.z, coord.z)
	# Solid-voxel AABB in asset-local meters, relative to pivot (voxel-inclusive corners).
	var lo := aabb_min + Vector3(min_c) * cell_size - pivot_local
	var hi := aabb_min + Vector3(max_c + Vector3i.ONE) * cell_size - pivot_local
	var angle := float(clampi(rotation_slot, 0, ROTATION_SLOTS - 1)) * TAU / float(ROTATION_SLOTS)
	var ca := cos(angle)
	var sa := sin(angle)
	var min_rel := Vector3(INF, lo.y, INF)
	var max_rel := Vector3(-INF, hi.y, -INF)
	for corner in [Vector2(lo.x, lo.z), Vector2(lo.x, hi.z), Vector2(hi.x, lo.z), Vector2(hi.x, hi.z)]:
		var c := corner as Vector2
		var rx := ca * c.x + sa * c.y
		var rz := -sa * c.x + ca * c.y
		min_rel.x = minf(min_rel.x, rx)
		max_rel.x = maxf(max_rel.x, rx)
		min_rel.z = minf(min_rel.z, rz)
		max_rel.z = maxf(max_rel.z, rz)
	# OBB：未旋转的局部 AABB 尺寸 + 旋转后的中心 + yaw，渲染时按 yaw 朝向立方体，
	# 框紧贴斜放的物体（不像 min_rel/max_rel 的轴对齐 AABB 会被旋转撑大）。
	var center_local := (lo + hi) * 0.5
	var obb_center_rel := Vector3(
		ca * center_local.x + sa * center_local.z,
		center_local.y,
		-sa * center_local.x + ca * center_local.z)
	return {
		"ok": true,
		"min_rel": min_rel,
		"max_rel": max_rel,
		"obb_center_rel": obb_center_rel,
		"obb_size": hi - lo,
		"obb_yaw": angle,
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
	# 锚点 = FBX 原始 pivot（网格局部原点），不按 AABB 计算。打分与放置都以此锚定，
	# 故二者始终一致；每个资产嵌入/站立的方式完全由其 FBX pivot 决定。
	var pivot_local := Vector3.ZERO

	var props := PackedFloat32Array()
	props.resize(voxel_count * 4)

	# descriptor voxel-profile：每个实心体素转成一条 point collision sample
	# （canonical 局部 footprint sample 列表）。评分采样点只取自 profile.collision 的
	# 体素位置（局部体素→世界→场景体素偏移），不再维护稠密 occupancy 网格。
	var collision_samples: Array[Dictionary] = []
	for v in voxels:
		var coord: Vector3i = v["voxel"]
		var idx := VoxelGeneral.voxel_index(coord, grid)
		if idx < 0 or idx >= voxel_count:
			continue
		var c: Color = v.get("color", Color.WHITE)
		var collision: float = v.get("collision", 0.0)
		props[idx * 4] = c.r
		props[idx * 4 + 1] = c.g
		props[idx * 4 + 2] = c.b
		props[idx * 4 + 3] = collision
		collision_samples.append(
			AutoVoxelProfileScript.make_collision_sample(coord, collision, 1.0))

	var pivot := Vector3i.ZERO

	var voxel_profile := AutoVoxelProfileScript.new()
	voxel_profile.color = asset_color
	voxel_profile.complexity = clampf(asset_color.a, 0.0, 1.0)
	voxel_profile.collision = collision_samples

	var footprint := {
		"grid": grid,
		"pivot": pivot,
		"props_bytes": props.to_byte_array(),
		"color": asset_color,
		"world_aabb_longest": world_aabb_longest,
		"cell_size": cell_size,
		"aabb_min": aabb_min,
		"aabb_size": aabb_size,
		"pivot_local": pivot_local,
		"voxel_profile": voxel_profile,
	}
	# 旋转采样剖面按需构建：需要场景体素尺寸，由 ensure_rotation_sample_profile() 在
	# 评分/放置时用场景 voxel_size 生成（见 build_rotation_sample_profile）。
	return footprint
