class_name SceneVoxelCollisionField

## 场景体素碰撞/占据场与盖章子系统(Stage 3 抽出)。拥有 occupancy 与三层 collision field 的真实存储，
## 以及 disc 盖章、collision 场 make/resample/merge、shared field layers、occupancy 盖章、mask import。
## committer 通过同名转发属性(occupancy/_collision_field/...)对外暴露，自身核心代码无需改动。
extends "res://scripts/godot_compute_shader_base.gd"

const VOXEL_OCCUPIED_EPSILON := VoxelGeneral.VOXEL_OCCUPIED_EPSILON

const SV_RESIDENT_TILE_SIZE := 8

const SCENE_VOXEL_TILE_SIZE_SETTING := "meshfill/scene_voxel_tile/size_voxels"

const DEFAULT_SCENE_VOXEL_TILE_SIZE := Vector3i(4, 4, 4)

const SCENE_VOXEL_TILE_RECORD_BUFFER := "scene_voxel_tile_records"
const SCENE_VOXEL_TILE_SUMMARY_BUFFER := "scene_voxel_tile_summaries"
const SCENE_VOXEL_TILE_DIRTY_INDEX_BUFFER := "scene_voxel_tile_dirty_indices"
const SCENE_VOXEL_TILE_OBJECT_REF_BUFFER := "scene_voxel_tile_object_refs"
const SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER := "scene_voxel_tile_complexity_field"
const SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER := "scene_voxel_tile_collision_field"
const SCENE_VOXEL_TILE_GPU_BUFFER_NAMES := [
	SCENE_VOXEL_TILE_RECORD_BUFFER,
	SCENE_VOXEL_TILE_SUMMARY_BUFFER,
	SCENE_VOXEL_TILE_DIRTY_INDEX_BUFFER,
	SCENE_VOXEL_TILE_OBJECT_REF_BUFFER,
	SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER,
	SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER,
]
const SCENE_VOXEL_TILE_RECORD_STRIDE_BYTES := 128
const SCENE_VOXEL_TILE_SUMMARY_STRIDE_BYTES := 32
const SCENE_VOXEL_TILE_INDEX_STRIDE_BYTES := 4
const SCENE_VOXEL_TILE_REF_STRIDE_BYTES := 4
const SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT := 8
const SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_PATH := "res://shaders/scene_voxel_tile_object_ref_update.glsl"
const SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_NAME := "scene_voxel_tile_object_ref_update.glsl"
const SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_LOCAL_SIZE_X := 64
const SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_STATS_CAPACITY := 10
const SCENE_VOXEL_TILE_OBJECT_REF_DIRTY_DELTA_STRIDE_BYTES := 80
const SCENE_VOXEL_TILE_OBJECT_REF_DIRTY_FLAG_SCHEMA_SCENE_VOXEL_TILE := 0
const SCENE_VOXEL_TILE_OBJECT_REF_DIRTY_FLAG_SCHEMA_GPU_AUTOOBJECT_RUNTIME := 1
const SCENE_VOXEL_TILE_OBJECT_REF_SCHEMA_NUMERIC := "u32_numeric_ref_key_v1"
const SCENE_VOXEL_TILE_OBJECT_REF_SCHEMA_LEGACY_HASH := "legacy_stable_hash_debug"
const SCENE_VOXEL_TILE_FIELD_STRIDE_BYTES := 16
const SCENE_VOXEL_TILE_REDUCE_SUMMARY_UINT_STRIDE := 6
const SCENE_VOXEL_TILE_COMPACT_SUMMARY_UINT_STRIDE := 8
const SCENE_VOXEL_TILE_REDUCE_QUANT_SCALE := 1000000.0
const SCENE_VOXEL_COMMIT_SOURCE_FLOAT_STRIDE := 16
const SCENE_VOXEL_COMMIT_OUTPUT_FLOAT_STRIDE := 12
const SCENE_VOXEL_COMMITTED_PAYLOAD_STRIDE_BYTES := SCENE_VOXEL_COMMIT_OUTPUT_FLOAT_STRIDE * 4
const SCENE_VOXEL_COMMITTED_KEY_COORD_STRIDE_BYTES := 16
const SCENE_VOXEL_COMMITTED_KEY_COORD_FORMAT := "ivec4(slice_index, voxel_x, voxel_z, reserved)"
const SCENE_COMPLEXITY_FIELD_PROJECTION_SOURCE_STREAMS := 0
const SCENE_COMPLEXITY_FIELD_PROJECTION_COMMITTED_PAYLOADS := 1
const SCENE_VOXEL_COMMIT_SOURCE_NONE := 0
const SCENE_VOXEL_COMMIT_SOURCE_AUTO := 1
const SCENE_VOXEL_COMMIT_SOURCE_BRUSH := 2
const SCENE_VOXEL_SOURCE_CANDIDATE_STRIDE_BYTES := 16
const SCENE_VOXEL_SOURCE_CANDIDATE_RANGE_STRIDE_BYTES := 16
const SCENE_VOXEL_SOURCE_CANDIDATE_GROUP_INDEX_STRIDE_BYTES := 4
const SCENE_VOXEL_SOURCE_PAYLOAD_STRIDE_BYTES := SCENE_VOXEL_COMMIT_SOURCE_FLOAT_STRIDE * 4
const ACCEPTED_PLACEMENT_SOURCE_BUFFER_INCOMPLETE_REASON := "incomplete_source_candidate_handoff_missing_payload_and_group_index_buffers"

const SCENE_VOXEL_TILE_FLAG_COMPLEXITY := 1
const SCENE_VOXEL_TILE_FLAG_COLLISION := 2
const SCENE_VOXEL_TILE_FLAG_AUTO := 4
const SCENE_VOXEL_TILE_FLAG_BRUSH := 8
const SCENE_VOXEL_TILE_FLAG_TARGET := 16
const SCENE_VOXEL_TILE_FLAG_ROUTING := 32
const SCENE_VOXEL_TILE_FLAG_SCORING := 64
const SCENE_VOXEL_TILE_FLAG_FEEDBACK := 128
const SCENE_VOXEL_TILE_FLAG_OBJECT_REFS := 256
const SCENE_VOXEL_TILE_FLAG_MASK := 512

const CHANNEL_COUNT := VoxelGeneral.CHANNEL_COUNT

const SharedPropertyTypeScript := preload("res://scripts/shared_property_type.gd")
const SceneVoxelProfileScript := preload("res://scripts/scene_voxel_profile.gd")
const SceneVoxelSourceRecordScript := preload("res://scripts/scene_voxel_source_record.gd")
const SceneVoxelScript := preload("res://scripts/scene_voxel.gd")
const SceneVoxelCommitPayloadScript := preload("res://scripts/scene_voxel_commit_payload.gd")
const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")
const SceneVoxelVolumeChannelsScript := preload("res://scripts/scene_voxel_volume_channels.gd")
const SceneVoxelBrushScript := preload("res://scripts/scene_voxel_brush.gd")
const SceneVoxelTargetScript := preload("res://scripts/scene_voxel_target.gd")
const VoxelGeneralScript := preload("res://scripts/voxel_general.gd")
const SceneVoxelDebugScript := preload("res://scripts/scene_voxel_debug.gd")


## committer 反向引用(读 _volume/_base_res/_capture_size/_sv_dirty，调 _is_valid_channel/_radius_to_px 等)。
var _committer: SceneVoxelCommitter = null
var _gpu_ready: bool = false

## --- occupancy 与 collision field 真实存储(从 committer 迁入；committer 留转发属性) ---
var occupancy: Image
var _source_collision_field: Image
var _terrain_base_collision_field: Image
var _collision_field: Image

## 本组件自有的线性采样器(collision/stamp GPU 采样用)
var _sampler: RID

## --- collision compute shader 管线(本组件拥有) ---
var _shader_import: RID
var _pipeline_import: RID
var _shader_filter: RID
var _pipeline_filter: RID
var _shader_max_collision: RID
var _pipeline_max_collision: RID
var _shader_stamp_r32_disc: RID
var _pipeline_stamp_r32_disc: RID
var _shader_stamp_rgba_channel_disc: RID
var _pipeline_stamp_rgba_channel_disc: RID
var _shader_merge_sv_collision_records: RID
var _pipeline_merge_sv_collision_records: RID
var _shader_stamp_collect_voxel_disc: RID
var _pipeline_stamp_collect_voxel_disc: RID
var _shader_sample_r32_pixel: RID
var _pipeline_sample_r32_pixel: RID


func setup(committer, base_resolution: int) -> void:
	_committer = committer
	log_name = "SceneVoxelCollisionField"
	_init_collision_gpu()

func _init_collision_gpu() -> void:
	var specs := {
		"import": "res://shaders/channel_import_mask.glsl",
		"filter": "res://shaders/channel_filter_candidates.glsl",
		"max_collision": "res://shaders/max_collision_images.glsl",
		"stamp_r32_disc": "res://shaders/stamp_r32_disc.glsl",
		"stamp_rgba_channel_disc": "res://shaders/stamp_rgba_channel_disc.glsl",
		"merge_sv_collision_records": "res://shaders/merge_sv_collision_records.glsl",
		"stamp_collect_voxel_disc": "res://shaders/stamp_collect_voxel_disc_3d.glsl",
		"sample_r32_pixel": "res://shaders/sample_r32_pixel.glsl",
	}
	_sampler = create_linear_sampler()
	var ok := _sampler.is_valid()
	for key in specs:
		var sh: RID = load_compute_shader(specs[key])
		set("_shader_" + key, sh)
		if sh.is_valid():
			set("_pipeline_" + key, create_compute_pipeline(sh))
		if not sh.is_valid() or not RID(get("_pipeline_" + key)).is_valid():
			ok = false
	_gpu_ready = ok

func teardown() -> void:
	dispose()
	_committer = null

## --- 复制自 committer 的 dispatch 辅助 ---

## Dispatch a single compute pipeline with uniform sets and push constants,
## then submit_and_sync. Returns true on success, false if begin_compute_list fails.
func _gpu_dispatch_and_sync(pipeline: RID, uniform_sets: Array, push: PackedByteArray, groups: Vector3i) -> bool:
	var cl := begin_compute_list()
	if cl < 0:
		return false
	_rd.compute_list_bind_compute_pipeline(cl, pipeline)
	for set_index in range(uniform_sets.size()):
		_rd.compute_list_bind_uniform_set(cl, uniform_sets[set_index], set_index)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, groups.x, groups.y, groups.z)
	end_compute_list()
	submit_and_sync()
	return true

## Bind and dispatch a single pipeline within an open compute list (no begin/end).
## Use for multi-pass sequences where the caller manages begin_compute_list/end_compute_list.

## --- 迁移自 committer 的 collision/occupancy/stamp 函数 ---
func _create_collision_image(resolution: int) -> Image:

	return VoxelGeneralScript.create_r32_image(resolution)

## GPU 逐像素取两张碰撞图像的最大值，返回合成后的 R32 图像

func _max_collision_images_gpu(a: Image, b: Image) -> Image:

	if a == null or a.is_empty() or b == null or b.is_empty():

		push_error("[SceneVoxelCommitter] Collision max compute requires two valid images")

		return _create_collision_image(_committer._base_res)

	if not _gpu_ready or _rd == null or not _shader_max_collision.is_valid() or not _pipeline_max_collision.is_valid():

		push_error("[SceneVoxelCommitter] Collision max compute resources are not ready")

		return _create_collision_image(_committer._base_res)

	var tex_a := upload_texture_2d(

		a,

		RenderingDevice.DATA_FORMAT_R32_SFLOAT,

		Image.FORMAT_RF,

		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,

		SCOPE_FRAME,

		"collision_a_r32f"

	)

	var tex_b := upload_texture_2d(

		b,

		RenderingDevice.DATA_FORMAT_R32_SFLOAT,

		Image.FORMAT_RF,

		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,

		SCOPE_FRAME,

		"collision_b_r32f"

	)

	var out_tex := create_rw_texture_2d(

		_committer._base_res,

		_committer._base_res,

		RenderingDevice.DATA_FORMAT_R32_SFLOAT,

		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT,

		SCOPE_FRAME,

		"collision_max_r32f"

	)

	if not tex_a.is_valid() or not tex_b.is_valid() or not out_tex.is_valid():

		gc_frame()

		push_error("[SceneVoxelCommitter] Collision max compute texture allocation failed")

		return _create_collision_image(_committer._base_res)

	var set0 := create_uniform_set([

		make_sampler_uniform(0, _sampler, tex_a),

		make_sampler_uniform(1, _sampler, tex_b),

	], _shader_max_collision, 0)

	var set1 := create_uniform_set([

		make_image_uniform(0, out_tex),

	], _shader_max_collision, 1)

	var push := PackedByteArray()

	push.resize(16)

	push.encode_s32(0, _committer._base_res)

	push.encode_s32(4, _committer._base_res)

	push.encode_s32(8, 0)

	push.encode_s32(12, 0)

	var groups := ceili(float(_committer._base_res) / 32.0)

	if not _gpu_dispatch_and_sync(_pipeline_max_collision, [set0, set1], push, Vector3i(groups, groups, 1)):
		gc_frame()
		push_error("[SceneVoxelCommitter] Collision max compute list begin failed")
		return _create_collision_image(_committer._base_res)

	var data := _rd.texture_get_data(out_tex, 0)

	var result := Image.create_from_data(_committer._base_res, _committer._base_res, false, Image.FORMAT_RF, data)

	gc_frame()

	return result

## 用 GPU 合成地形基础碰撞与源碰撞，刷新合并后的碰撞场

func _refresh_combined_collision_field() -> void:

	_collision_field = _max_collision_images_gpu(_terrain_base_collision_field, _source_collision_field)

## 返回指定切片在 Y 方向的体素尺寸

func import_mask_channel(channel: int, mask_img: Image, complexity: float = 1.0) -> void:

	assert(_gpu_ready, "[SceneVoxelCommitter] GPU not ready — cannot import mask")

	if not _committer._is_valid_channel(channel):

		push_error("[SceneVoxelCommitter] Invalid channel: %d" % channel)

		return

	_gpu_import_mask(channel, clampf(complexity, 0.0, 1.0), mask_img)

## GPU 执行通道掩码导入，将掩码按复杂度写入 occupancy 纹理

func _gpu_import_mask(channel: int, complexity: float, mask_img: Image) -> void:

	var tex_src := upload_texture_2d(mask_img)

	var tex_occ := create_rw_texture_2d(_committer._base_res, _committer._base_res, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT)

	# Upload current occupancy into rw texture

	var occ_rgba := occupancy.duplicate()

	if occ_rgba.get_format() != Image.FORMAT_RGBAH:

		occ_rgba.convert(Image.FORMAT_RGBAH)

	_rd.texture_update(tex_occ, 0, occ_rgba.get_data())

	var set0 := create_uniform_set([make_sampler_uniform(0, _sampler, tex_src)], _shader_import, 0)

	var set1 := create_uniform_set([make_image_uniform(0, tex_occ)], _shader_import, 1)

	var push := PackedByteArray()

	push.resize(16)

	push.encode_s32(0, channel)

	push.encode_float(4, complexity)

	push.encode_float(8, 0.01)  # threshold

	push.encode_s32(12, _committer._base_res)

	var groups := ceili(float(_committer._base_res) / 32.0)

	if not _gpu_dispatch_and_sync(_pipeline_import, [set0, set1], push, Vector3i(groups, groups, 1)):
		gc_frame()
		push_error("[SceneVoxelCommitter] Channel import compute list begin failed")
		return

	# Read back packed occupancy

	var data := _rd.texture_get_data(tex_occ, 0)

	occupancy = Image.create_from_data(_committer._base_res, _committer._base_res, false, Image.FORMAT_RGBAH, data)

	gc_frame()

## ─── Core Operations (GPU only) ───

## Build a vec4 profile mask from a profile: 1.0 in channels this profile uses.

## Convert world-meter radius to pixels at base resolution.

## 将世界半径换算为底图分辨率下的像素半径

func _stamp_scalar_image_disc(img: Image, center_px: Vector2i, radius_px: int, value: float, channel: int = 0) -> Image:

	if img == null or img.is_empty():

		return img

	var stamped := _stamp_scalar_image_disc_gpu(img, center_px, radius_px, value, channel)

	if stamped != null and not stamped.is_empty():

		return stamped

	push_error("[SceneVoxelCommitter] GPU scalar disc stamp failed")

	return img

## GPU 执行圆形标量盖印，支持 R32 与 RGBA 通道两种格式

func _stamp_scalar_image_disc_gpu(img: Image, center_px: Vector2i, radius_px: int, value: float, channel: int = 0) -> Image:

	if img == null or img.is_empty():

		return null

	if not _gpu_ready or _rd == null or not _sampler.is_valid():

		return null

	var width := img.get_width()

	var height := img.get_height()

	var use_r32 := img.get_format() == Image.FORMAT_RF

	var shader := _shader_stamp_r32_disc if use_r32 else _shader_stamp_rgba_channel_disc

	var pipeline := _pipeline_stamp_r32_disc if use_r32 else _pipeline_stamp_rgba_channel_disc

	if not shader.is_valid() or not pipeline.is_valid():

		return null

	var data_format := RenderingDevice.DATA_FORMAT_R32_SFLOAT if use_r32 else RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT

	var image_format := Image.FORMAT_RF if use_r32 else Image.FORMAT_RGBAH

	var src_tex := upload_texture_2d(
		img,
		data_format,
		image_format,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		SCOPE_FRAME,
		"stamp_disc_src"
	)

	var out_tex := create_rw_texture_2d(
		width,
		height,
		data_format,
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT,
		SCOPE_FRAME,
		"stamp_disc_out"
	)

	if not src_tex.is_valid() or not out_tex.is_valid():

		gc_frame()

		return null

	var set0 := create_uniform_set([
		make_sampler_uniform(0, _sampler, src_tex),
	], shader, 0, SCOPE_PASS, "stamp_disc_src")

	var set1 := create_uniform_set([
		make_image_uniform(0, out_tex),
	], shader, 1, SCOPE_PASS, "stamp_disc_out")

	if not set0.is_valid() or not set1.is_valid():

		gc_frame()

		return null

	var push := PackedByteArray()

	push.resize(48)

	push.encode_s32(0, width)
	push.encode_s32(4, height)
	push.encode_s32(8, clampi(center_px.x, 0, width - 1))
	push.encode_s32(12, clampi(center_px.y, 0, height - 1))
	push.encode_s32(16, maxi(radius_px, 0))
	push.encode_s32(20, clampi(channel, 0, CHANNEL_COUNT - 1))
	push.encode_s32(24, 0)
	push.encode_s32(28, 0)
	push.encode_float(32, clampf(value, 0.0, 1.0))
	push.encode_float(36, 0.0)
	push.encode_float(40, 0.0)
	push.encode_float(44, 0.0)

	var groups := dispatch_groups_2d(width, height, 16, 16)

	if not _gpu_dispatch_and_sync(pipeline, [set0, set1], push, groups):
		gc_frame()
		return null

	var data := _rd.texture_get_data(out_tex, 0)

	var result := Image.create_from_data(width, height, false, image_format, data)

	gc_frame()

	return result

## GPU stamp a disc value across gathered R32 volume slices and collect changed
## voxels in one 3D dispatch. slice_images are processed in order as a flattened
## volume (slice-major). compare_mode selects the record condition:
## 0 = value > previous, 1 = always, 2 = source compare (value > epsilon and
## value + slop >= previous). Returns {"slices": Array[Image] (updated, same
## order), "records": Array of {x, z, slice_local}}.

func _stamp_collect_voxel_disc_gpu(
	slice_images: Array,
	center_px: Vector2i,
	radius_px: int,
	value: float,
	compare_mode: int
) -> Dictionary:
	var fallback := {"slices": slice_images, "records": []}
	var depth := slice_images.size()
	if depth <= 0:
		return fallback
	if not _gpu_ready or _rd == null:
		return fallback
	if not _shader_stamp_collect_voxel_disc.is_valid() or not _pipeline_stamp_collect_voxel_disc.is_valid():
		return fallback

	var first := slice_images[0] as Image
	if first == null or first.is_empty():
		return fallback
	var xz_res := first.get_width()
	if xz_res <= 0 or first.get_height() != xz_res:
		return fallback
	var voxel_per_slice := xz_res * xz_res

	var volume_floats := PackedFloat32Array()
	for i in range(depth):
		var img := slice_images[i] as Image
		if img == null or img.is_empty() or img.get_width() != xz_res or img.get_height() != xz_res or img.get_format() != Image.FORMAT_RF:
			return fallback
		var slice_floats := img.get_data().to_float32_array()
		if slice_floats.size() != voxel_per_slice:
			return fallback
		volume_floats.append_array(slice_floats)

	var radius := maxi(radius_px, 0)
	var disc_size := radius * 2 + 1
	var max_records := maxi(disc_size * disc_size * depth, 1)

	# Separate in/out buffers (both seeded with the previous volume) keep
	# previous_value clean at clamped disc edges; out retains non-disc cells.
	var in_buffer := storage_buffer_from_floats(volume_floats, SCOPE_FRAME, "stamp_collect_voxel_in")
	var out_buffer := storage_buffer_from_floats(volume_floats, SCOPE_FRAME, "stamp_collect_voxel_out")
	var records_buffer := storage_buffer_zero(max_records * 16, SCOPE_FRAME, "stamp_collect_voxel_records")
	var counter_buffer := storage_buffer_zero(4, SCOPE_FRAME, "stamp_collect_voxel_counter")
	if not in_buffer.is_valid() or not out_buffer.is_valid() or not records_buffer.is_valid() or not counter_buffer.is_valid():
		gc_frame()
		return fallback

	var set0 := create_uniform_set([
		make_storage_uniform(0, in_buffer),
		make_storage_uniform(1, out_buffer),
		make_storage_uniform(2, records_buffer),
		make_storage_uniform(3, counter_buffer),
	], _shader_stamp_collect_voxel_disc, 0, SCOPE_PASS, "stamp_collect_voxel_disc")
	if not set0.is_valid():
		gc_frame()
		return fallback

	var push := PackedByteArray()
	push.resize(48)
	push.encode_s32(0, xz_res)
	push.encode_s32(4, depth)
	push.encode_s32(8, max_records)
	push.encode_s32(12, clampi(compare_mode, 0, 2))
	push.encode_s32(16, clampi(center_px.x, 0, xz_res - 1))
	push.encode_s32(20, clampi(center_px.y, 0, xz_res - 1))
	push.encode_s32(24, radius)
	push.encode_s32(28, disc_size)
	push.encode_float(32, clampf(value, 0.0, 1.0))
	push.encode_float(36, VOXEL_OCCUPIED_EPSILON)
	push.encode_float(40, 0.00001)
	push.encode_float(44, SCENE_VOXEL_TILE_REDUCE_QUANT_SCALE)

	var groups := dispatch_groups_3d(disc_size, disc_size, depth, 8, 8, 1)
	if not _gpu_dispatch_and_sync(_pipeline_stamp_collect_voxel_disc, [set0], push, groups):
		gc_frame()
		return fallback

	var out_bytes := _rd.buffer_get_data(out_buffer)
	var updated_slices: Array = []
	updated_slices.resize(depth)
	var slice_byte_len := voxel_per_slice * 4
	for i in range(depth):
		var start := i * slice_byte_len
		if start + slice_byte_len > out_bytes.size():
			updated_slices[i] = slice_images[i]
			continue
		updated_slices[i] = Image.create_from_data(xz_res, xz_res, false, Image.FORMAT_RF, out_bytes.slice(start, start + slice_byte_len))

	var records: Array = []
	var counter_bytes := _rd.buffer_get_data(counter_buffer, 0, 4)
	var record_count := 0
	if counter_bytes.size() >= 4:
		record_count = clampi(int(counter_bytes.decode_u32(0)), 0, max_records)
	if record_count > 0:
		var record_bytes := _rd.buffer_get_data(records_buffer, 0, record_count * 16)
		for i in range(record_count):
			var base := i * 16
			if base + 12 > record_bytes.size():
				break
			records.append({
				"x": int(record_bytes.decode_u32(base + 0)),
				"z": int(record_bytes.decode_u32(base + 4)),
				"slice_local": int(record_bytes.decode_u32(base + 8)),
			})

	gc_frame()
	return {"slices": updated_slices, "records": records}

## GPU 采样 R32 图像指定像素，返回单像素值字典

func _sample_scalar_image_pixel_gpu(img: Image, px: Vector2i) -> Dictionary:
	if img == null or img.is_empty():
		return {}
	if not _gpu_ready or _rd == null or not _sampler.is_valid():
		return {}
	if not _shader_sample_r32_pixel.is_valid() or not _pipeline_sample_r32_pixel.is_valid():
		return {}

	var width := img.get_width()
	var height := img.get_height()
	var src_tex := upload_texture_2d(
		img,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		Image.FORMAT_RF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		SCOPE_FRAME,
		"sample_r32_pixel_src"
	)
	var output_buffer := storage_buffer_zero(4, SCOPE_FRAME, "sample_r32_pixel_out")
	if not src_tex.is_valid() or not output_buffer.is_valid():
		gc_frame()
		return {}

	var set0 := create_uniform_set([
		make_sampler_uniform(0, _sampler, src_tex),
		make_storage_uniform(1, output_buffer),
	], _shader_sample_r32_pixel, 0, SCOPE_PASS, "sample_r32_pixel")
	if not set0.is_valid():
		gc_frame()
		return {}

	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, width)
	push.encode_s32(4, height)
	push.encode_s32(8, px.x)
	push.encode_s32(12, px.y)

	if not _gpu_dispatch_and_sync(_pipeline_sample_r32_pixel, [set0], push, Vector3i(1, 1, 1)):
		gc_frame()
		return {}

	var output_bytes := _rd.buffer_get_data(output_buffer, 0, 4)
	gc_frame()
	if output_bytes.size() < 4:
		return {}
	return {
		"ok": true,
		"value": output_bytes.decode_float(0),
		"gpu_dispatched": true,
		"cpu_fallback": false,
	}

## 计算碰撞记录的有效半径（半径减腐蚀加膨胀）

func _collision_effective_radius(collision: Dictionary) -> float:

	return VoxelGeneralScript.collision_effective_radius(collision)

## 判断碰撞记录是否为点采样类型（含 voxel/local_pos/voxel_offset）

func _is_point_collision_sample(collision: Dictionary) -> bool:

	return VoxelGeneralScript.is_point_collision_sample(collision)

## 从多种类型（Vector3i/Vector3/Array/Dictionary）解析出 Vector3i

func _collision_local_voxel(collision: Dictionary) -> Vector3i:

	return VoxelGeneralScript.collision_local_voxel(collision)

## 计算碰撞层在底图上的基础像素坐标（点采样类型叠加本地偏移）

func _collision_layer_base_px(base_px: Vector2i, collision: Dictionary) -> Vector2i:

	return VoxelGeneralScript.collision_layer_base_px(base_px, collision, _committer._base_res)

## 计算碰撞记录的像素半径，点采样优先用 radius_px 字段

func _collision_radius_px(collision: Dictionary) -> int:

	return VoxelGeneralScript.collision_radius_px(collision, _committer._capture_size, _committer._base_res)

## 规范化共享场层列表，统一字段并计算有效半径与像素半径

func _normalize_shared_field_layers(field_layers: Array, base_px: Vector2i = Vector2i(-1, -1)) -> Array[Dictionary]:

	var result: Array[Dictionary] = []

	var canonical_layers: Array[Dictionary] = SharedPropertyTypeScript.collision_from_fields({SharedPropertyTypeScript.COLLISION_KEY: field_layers})

	for raw_layer in canonical_layers:

		if not raw_layer is Dictionary:

			continue

		var collision_entry := (raw_layer as Dictionary).duplicate(true)

		if not bool(collision_entry.get("enabled", true)):

			continue

		if _is_point_collision_sample(collision_entry):

			var local := _collision_local_voxel(collision_entry)

			collision_entry["voxel"] = local

			collision_entry["local_pos"] = local

			if not collision_entry.has("collision_strength"):

				collision_entry["collision_strength"] = 1.0

			collision_entry["collision_strength"] = clampf(float(collision_entry.get("collision_strength", 1.0)), 0.0, 1.0)

			collision_entry["radius_px"] = maxi(int(collision_entry.get("radius_px", 0)), 0)

			collision_entry["effective_radius"] = 0.0

			if not collision_entry.has("slice_index"):

				collision_entry["slice_index"] = local.y

			if base_px.x >= 0 and base_px.y >= 0:

				collision_entry["base_pixel"] = _collision_layer_base_px(base_px, collision_entry)

			result.append(collision_entry)

			continue

		var effective_radius := _collision_effective_radius(collision_entry)

		if effective_radius <= 0.0:

			continue

		collision_entry["shape"] = str(collision_entry.get("shape", "cylinder"))

		collision_entry["radius"] = maxf(float(collision_entry.get("radius", effective_radius)), 0.0)

		collision_entry["effective_radius"] = effective_radius

		collision_entry["radius_px"] = _committer._radius_to_px(effective_radius)

		if not collision_entry.has("collision_strength"):

			collision_entry["collision_strength"] = 1.0

		collision_entry["collision_strength"] = clampf(float(collision_entry.get("collision_strength", 1.0)), 0.0, 1.0)

		if not collision_entry.has("y_min"):

			collision_entry["y_min"] = 0.0

		if not collision_entry.has("y_max"):

			collision_entry["y_max"] = 2.0

		if base_px.x >= 0 and base_px.y >= 0:

			collision_entry["base_pixel"] = base_px

		result.append(collision_entry)

	return result

## 根据基础像素与碰撞层生成源碰撞层列表，跳过目标体素类型

func _make_source_collision(base_px: Vector2i, collision_layers: Array, rec: Dictionary = {}) -> Array[Dictionary]:

	var updated: Array[Dictionary] = []

	var source_type := str(rec.get("source_voxel_type", ""))

	if source_type == "TargetSceneVoxel":

		return updated

	var xz_res := _committer._base_res

	if not _committer._volume.is_empty():

		xz_res = int(_committer._volume.get("xz_res", _committer._base_res))

	var layers := _normalize_shared_field_layers(collision_layers, base_px)

	for layer in layers:

		var collision_strength := clampf(float(layer.get("collision_strength", 1.0)), 0.0, 1.0)

		var radius_px := _collision_radius_px(layer)

		var layer_base_px := _collision_layer_base_px(base_px, layer)

		var source_layer := layer.duplicate(true)

		source_layer["collision_strength"] = collision_strength

		source_layer["base_pixel"] = layer_base_px

		source_layer["voxel_xz"] = _committer._volume_px_from_base(layer_base_px, xz_res)

		source_layer["volume_xz_resolution"] = xz_res

		source_layer["radius_px"] = radius_px

		source_layer["collision_shape"] = str(layer.get("shape", "point" if _is_point_collision_sample(layer) else "cylinder"))

		source_layer["collision_radius"] = layer.get("radius", 0.0)

		source_layer["effective_radius"] = layer.get("effective_radius", 0.0)

		source_layer["source_voxel_type"] = source_type

		source_layer["record_id"] = str(rec.get("id", ""))

		source_layer["auto_object_id"] = str(rec.get("auto_object_id", rec.get("auto_id", rec.get("id", ""))))

		source_layer["auto_instance_id"] = int(rec.get("auto_instance_id", rec.get("instance_id", 0)))

		source_layer["instance_mesh_id"] = int(rec.get("instance_mesh_id", rec.get("mesh_instance_id", rec.get("instance_id", 0))))

		source_layer["collision_buffer_applied"] = false

		updated.append(source_layer)

	return updated

## 生成场单元的字符串键（字段名:像素x:像素y）

func _field_cell_key(field_name: String, px: Vector2i) -> String:

	return "%s:%d:%d" % [field_name, px.x, px.y]

## 确保体量对象中包含重采样后的碰撞层字段

func _ensure_volume_collision_layer() -> void:

	if _committer._volume.is_empty():

		return

	var xz_res: int = _committer._volume.xz_res

	if not _committer._volume.has("terrain_base_collision_field"):

		_committer._volume["terrain_base_collision_field"] = _resample_collision_field(_terrain_base_collision_field, xz_res)

	if not _committer._volume.has("source_collision_field"):

		_committer._volume["source_collision_field"] = _resample_collision_field(_source_collision_field, xz_res)

	if not _committer._volume.has("collision_field"):

		var img := _resample_collision_field(_collision_field, xz_res)

		_committer._volume["collision_field"] = img

	if not _committer._volume.has("collision"):

		_committer._volume["collision"] = {}

## 重采样碰撞场到指定 XZ 分辨率，GPU 失败时返回空白图像

func _resample_collision_field(source_img: Image, xz_res: int) -> Image:
	var gpu_img := _resample_collision_field_gpu(source_img, xz_res)
	if gpu_img != null and not gpu_img.is_empty():
		return gpu_img
	var img := _create_collision_image(maxi(xz_res, 1))
	if source_img != null and not source_img.is_empty() and xz_res > 0:
		push_error("[SceneVoxelCommitter] Collision field resample GPU compute failed")
	return img


## GPU 将碰撞场重采样到目标 XZ 分辨率

func _resample_collision_field_gpu(source_img: Image, xz_res: int) -> Image:
	if source_img == null or source_img.is_empty() or xz_res <= 0:
		return null
	if not _gpu_ready or _rd == null or not _sampler.is_valid():
		return null

	var shader := load_compute_shader("res://shaders/resample_collision_field.glsl", SCOPE_FRAME, "resample_collision_field")
	var pipeline := create_compute_pipeline(shader, SCOPE_FRAME, "resample_collision_field")
	if not shader.is_valid() or not pipeline.is_valid():
		gc_frame()
		return null

	var src_tex := upload_texture_2d(
		source_img,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		Image.FORMAT_RF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		SCOPE_FRAME,
		"resample_collision_src_r32f"
	)
	var out_tex := create_rw_texture_2d(
		xz_res,
		xz_res,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT,
		SCOPE_FRAME,
		"resample_collision_out_r32f"
	)
	if not src_tex.is_valid() or not out_tex.is_valid():
		gc_frame()
		return null

	var set0 := create_uniform_set([
		make_sampler_uniform(0, _sampler, src_tex),
	], shader, 0, SCOPE_PASS, "resample_collision_src")
	var set1 := create_uniform_set([
		make_image_uniform(0, out_tex),
	], shader, 1, SCOPE_PASS, "resample_collision_out")
	if not set0.is_valid() or not set1.is_valid():
		gc_frame()
		return null

	var push := PackedByteArray()
	push.resize(32)
	push.encode_s32(0, xz_res)
	push.encode_s32(4, xz_res)
	push.encode_s32(8, source_img.get_width())
	push.encode_s32(12, source_img.get_height())
	push.encode_s32(16, _committer._base_res)
	push.encode_s32(20, 0)
	push.encode_s32(24, 0)
	push.encode_s32(28, 0)

	var groups := dispatch_groups_2d(xz_res, xz_res, 32, 32)
	if not _gpu_dispatch_and_sync(pipeline, [set0, set1], push, groups):
		gc_frame()
		return null

	var data := _rd.texture_get_data(out_tex, 0)
	var result := Image.create_from_data(xz_res, xz_res, false, Image.FORMAT_RF, data)
	gc_frame()
	return result


## 在体量场的圆形区域盖印标量值，并收集变更像素更新单元映射

func _stamp_scalar_volume_disc(
	field_name: String,
	cell_map_name: String,
	cell_key_prefix: String,
	dirty_layer: String,
	base_px: Vector2i,
	radius_px: int,
	value_key: String,
	value: float,
	cell_template: Dictionary
) -> Vector2i:

	if _committer._volume.is_empty():

		return base_px

	_ensure_volume_collision_layer()

	var xz_res: int = _committer._volume.xz_res

	var field_img: Image = _committer._volume.get(field_name, _create_collision_image(xz_res))

	var voxel_px := _committer._volume_px_from_base(base_px, xz_res)

	var radius_vol := _committer._volume_radius_from_base_radius(radius_px, xz_res)

	var cell_map: Dictionary = _committer._volume.get(cell_map_name, {})

	var field_value := clampf(value, 0.0, 1.0)

	# Stamp + collect the flat collision field as a depth-1 voxel volume.
	var stamp_result := _stamp_collect_voxel_disc_gpu([field_img], voxel_px, radius_vol, field_value, 0)
	var updated_slices: Array = stamp_result.get("slices", [field_img])
	if updated_slices.size() > 0 and updated_slices[0] is Image:
		field_img = updated_slices[0]
	for rec in stamp_result.get("records", []):
		var px := Vector2i(int(rec.x), int(rec.z))
		var cell := cell_template.duplicate(true)
		cell[value_key] = field_value
		cell["base_pixel"] = base_px
		cell["voxel_xz"] = px
		cell["slice_index"] = int(cell.get("slice_index", 0))
		cell["radius_px"] = radius_px
		cell_map[_field_cell_key(cell_key_prefix, px)] = cell
		_committer._mark_sv_tile_dirty(int(cell.slice_index), px, dirty_layer, SV_RESIDENT_TILE_SIZE, cell)

	_committer._volume[field_name] = field_img

	_committer._volume[cell_map_name] = cell_map

	return voxel_px

## 盖印单个共享场层到碰撞与复杂度场，返回更新后的层字典

func _stamp_shared_field_layer(base_px: Vector2i, source_layer: Dictionary, rec: Dictionary = {}) -> Dictionary:

	var normalized := _normalize_shared_field_layers([source_layer], base_px)

	if normalized.is_empty():

		return {}

	var layer := normalized[0]

	var radius_px := _collision_radius_px(layer)

	var collision_strength := clampf(float(layer.get("collision_strength", 1.0)), 0.0, 1.0)

	layer["collision_strength"] = collision_strength

	var layer_base_px := _collision_layer_base_px(base_px, layer)

	# Non-terrain collision stamping disabled; only terrain base collision is preserved.
	# _source_collision_field remains zero, so _refresh_combined_collision_field() yields terrain-only.
	# _source_collision_field = _stamp_scalar_image_disc(_source_collision_field, layer_base_px, radius_px, collision_strength, 0)

	var cell_template := {
		"slice_index": int(layer.get("slice_index", 0)),
		"collision_shape": str(layer.get("shape", "point" if _is_point_collision_sample(layer) else "cylinder")),
		"collision_radius": layer.get("radius", 0.0),
		"effective_radius": layer.get("effective_radius", 0.0),
		"source_voxel_type": str(layer.get("source_voxel_type", rec.get("source_voxel_type", ""))),
		"record_id": str(layer.get("record_id", rec.get("id", ""))),
		"auto_object_id": str(rec.get("auto_object_id", rec.get("auto_id", rec.get("id", "")))),
		"auto_instance_id": int(rec.get("auto_instance_id", rec.get("instance_id", 0))),
		"instance_mesh_id": int(rec.get("instance_mesh_id", rec.get("mesh_instance_id", 0))),
	}

	var voxel_px := _stamp_scalar_volume_disc(
		"source_collision_field",
		"collision",
		"collision",
		"collision",
		layer_base_px,
		radius_px,
		"collision_strength",
		collision_strength,
		cell_template
	)

	if not _committer._volume.is_empty():

		var xz_res: int = _committer._volume.xz_res

		_refresh_combined_collision_field()

		_committer._volume["collision_field"] = _resample_collision_field(_collision_field, xz_res)

	layer["base_pixel"] = layer_base_px

	layer["voxel_xz"] = voxel_px

	layer["volume_xz_resolution"] = int(_committer._volume.xz_res) if not _committer._volume.is_empty() else _committer._base_res

	layer["collision_buffer_applied"] = true

	return layer

## 盖印多个共享场层并刷新合并碰撞场，返回更新后的层列表

func _stamp_shared_field_layers(base_px: Vector2i, field_layers: Array, rec: Dictionary = {}) -> Array[Dictionary]:

	var updated: Array[Dictionary] = []

	var layers := _normalize_shared_field_layers(field_layers, base_px)

	for layer in layers:

		var stamped := _stamp_shared_field_layer(base_px, layer, rec)

		if not stamped.is_empty():

			updated.append(stamped)

	_refresh_combined_collision_field()

	return updated

## 清空源碰撞场缓存并重置体量中的碰撞层字段

func _clear_shared_field_cache() -> void:

	_source_collision_field.fill(Color(0.0, 0.0, 0.0, 0.0))

	_refresh_combined_collision_field()

	if _committer._volume.is_empty():

		return

	var xz_res: int = _committer._volume.xz_res

	var img := _resample_collision_field(_collision_field, xz_res)

	_committer._volume["source_collision_field"] = _resample_collision_field(_source_collision_field, xz_res)

	_committer._volume["collision_field"] = img

	_committer._volume["collision"] = {}

## 从场景体素字典重建共享场缓存，按脚印去重盖印碰撞层

func _rebuild_shared_field_cache_from_scene_voxels(scene_voxels: Dictionary) -> void:

	_clear_shared_field_cache()

	if _committer._volume.is_empty():

		return

	var stamped_footprints: Dictionary = {}

	for key in scene_voxels.keys():

		var scene_voxel = scene_voxels[key]

		if not scene_voxel is Dictionary:

			continue

		var voxel := scene_voxel as Dictionary

		var collision_layers := SharedPropertyTypeScript.collision_from_fields(voxel)

		if collision_layers.is_empty():

			continue

		var base_px = voxel.get("base_pixel", voxel.get("voxel_xz", Vector2i.ZERO))

		if not base_px is Vector2i:

			continue

		var stamp_key := "%d:%d:%s" % [base_px.x, base_px.y, str(collision_layers)]

		if stamped_footprints.has(stamp_key):

			continue

		stamped_footprints[stamp_key] = true

		_stamp_shared_field_layers(base_px, collision_layers, voxel)

## 在指定通道上盖印 occupancy 的圆形区域

func _stamp_occupancy_channel(base_px: Vector2i, channel: int, radius_px: int, complexity: float) -> void:

	if not _committer._is_valid_channel(channel):

		return

	occupancy = _stamp_scalar_image_disc(occupancy, base_px, maxi(radius_px, 1), complexity, channel)

## 按 profile 在 occupancy 上逐通道盖印圆形区域

func _stamp_occupancy(base_px: Vector2i, profile: Array[Dictionary]) -> void:

	for entry in profile:

		var ch := int(entry.get("channel", -1))

		if not _committer._is_valid_channel(ch):

			continue

		var complexity := SceneVoxelProfileScript.profile_entry_complexity(entry, 1.0)

		var r_px := _committer._radius_to_px(float(entry.get("radius", 0.0)))

		_stamp_occupancy_channel(base_px, ch, r_px, complexity)

## ─── GPU Candidate Filtering ───

## Returns an Image at _committer._base_res where R = 1.0 if candidate, 0.0 if blocked.

## GPU 按profile筛选候选并输出候选图像

func _gpu_filter_candidates(profile: Array[Dictionary]) -> Image:

	var tex_occ := upload_texture_2d(occupancy)

	var tex_out := create_rw_texture_2d(_committer._base_res, _committer._base_res, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT)

	var set0 := create_uniform_set([make_sampler_uniform(0, _sampler, tex_occ)], _shader_filter, 0)

	var set1 := create_uniform_set([make_image_uniform(0, tex_out)], _shader_filter, 1)

	var pmask := SceneVoxelProfileScript.profile_to_mask(profile)

	var push := PackedByteArray()

	push.resize(32)

	push.encode_float(0, pmask.r)

	push.encode_float(4, pmask.g)

	push.encode_float(8, pmask.b)

	push.encode_float(12, pmask.a)

	push.encode_float(16, 0.01)  # block_threshold

	push.encode_s32(20, _committer._base_res)

	push.encode_s32(24, 0)  # pad0

	push.encode_s32(28, 0)  # pad1

	var groups := ceili(float(_committer._base_res) / 32.0)

	if not _gpu_dispatch_and_sync(_pipeline_filter, [set0, set1], push, Vector3i(groups, groups, 1)):
		gc_frame()
		push_error("[SceneVoxelCommitter] Candidate filter compute list begin failed")
		var empty := Image.create(_committer._base_res, _committer._base_res, false, Image.FORMAT_RGBAH)
		empty.fill(Color(0.0, 0.0, 0.0, 0.0))
		return empty

	var data := _rd.texture_get_data(tex_out, 0)

	var result := Image.create_from_data(_committer._base_res, _committer._base_res, false, Image.FORMAT_RGBAH, data)

	gc_frame()

	return result

## ─── Query & Debug ───

## 设置地形基础碰撞场，重采样后刷新合并场并标记重建

func set_terrain_base_collision_field(base_collision: Image) -> void:

	_terrain_base_collision_field = _resample_collision_field(base_collision, _committer._base_res)

	_refresh_combined_collision_field()

	if not _committer._volume.is_empty():

		var xz_res: int = _committer._volume.xz_res

		_committer._volume["terrain_base_collision_field"] = _resample_collision_field(_terrain_base_collision_field, xz_res)

		_committer._volume["collision_field"] = _resample_collision_field(_collision_field, xz_res)

		_committer._mark_scene_voxel_full_rebuild_dirty("terrain_base_collision")

	else:

		_committer._sv_dirty = true

## Get every placed mesh voxel_write_spec.

## 获取全部体素写入规格记录列表

func _make_sv_collision_field(collision: Dictionary, xz_res: int, total_slices: int) -> PackedFloat32Array:

	var terrain_base_img: Image = _committer._volume.get("terrain_base_collision_field", _resample_collision_field(_terrain_base_collision_field, xz_res))

	var field := _make_terrain_base_collision_volume_field(terrain_base_img, xz_res, total_slices)

	if collision.is_empty():

		return field

	var merged_field := _merge_sv_collision_records_gpu(field, collision, xz_res, total_slices)

	if merged_field.size() == field.size():

		return merged_field

	push_error("[SceneVoxelCommitter] SV collision record merge compute failed")

	return field

## 生成仅含碰撞记录摘要的碰撞场(不含地形基底)

func _make_sv_collision_record_summary_field(collision: Dictionary, xz_res: int, total_slices: int) -> PackedFloat32Array:
	var voxel_count := xz_res * xz_res * total_slices
	var field := PackedFloat32Array()
	field.resize(maxi(voxel_count, 0))
	if voxel_count <= 0 or collision.is_empty():
		return field

	var merged_field := _merge_sv_collision_records_gpu(field, collision, xz_res, total_slices)
	if merged_field.size() == voxel_count:
		return merged_field

	push_error("[SceneVoxelCommitter] SV collision summary record merge compute failed")
	return field

## 在 GPU 上构建碰撞记录摘要缓冲并保留输出 RID

func _make_sv_collision_record_summary_gpu_buffer(
	collision: Dictionary,
	xz_res: int,
	total_slices: int,
	output_buffer_scope: String
) -> Dictionary:
	var voxel_count := xz_res * xz_res * total_slices
	if voxel_count <= 0 or output_buffer_scope.is_empty():
		return {}
	if not _gpu_ready or _rd == null:
		return {}

	var field_buffer := storage_buffer_zero(voxel_count * 4, output_buffer_scope, "sv_collision_record_summary")
	if not field_buffer.is_valid():
		return {}

	var result := {
		"collision_field_buffer": field_buffer,
		"voxel_count": voxel_count,
	}
	if collision.is_empty():
		return result

	var collision_records := _pack_sv_collision_records(collision, xz_res, total_slices)
	var record_count := int(collision_records.size() / 4)
	if record_count <= 0:
		return result

	if not _shader_merge_sv_collision_records.is_valid() or not _pipeline_merge_sv_collision_records.is_valid():
		gc_scope(output_buffer_scope)
		return {}

	var record_buffer := storage_buffer_from_floats(collision_records, SCOPE_FRAME, "sv_collision_record_summary_merge_records")
	if not record_buffer.is_valid():
		gc_scope(output_buffer_scope)
		gc_frame()
		return {}

	var set0 := create_uniform_set([
		make_storage_uniform(0, field_buffer),
		make_storage_uniform(1, record_buffer),
	], _shader_merge_sv_collision_records, 0, SCOPE_PASS, "sv_collision_record_summary_merge")

	if not set0.is_valid():
		gc_scope(output_buffer_scope)
		gc_frame()
		return {}

	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, xz_res)
	push.encode_s32(4, total_slices)
	push.encode_s32(8, voxel_count)
	push.encode_s32(12, record_count)

	var groups := dispatch_groups_1d(record_count, 64)
	if not _gpu_dispatch_and_sync(_pipeline_merge_sv_collision_records, [set0], push, groups):
		gc_scope(output_buffer_scope)
		gc_frame()
		return {}

	gc_frame()
	return result

## 将碰撞字典打包为 GPU 合并所需的扁平浮点记录数组

func _pack_sv_collision_records(collision: Dictionary, xz_res: int, total_slices: int) -> PackedFloat32Array:

	var records := PackedFloat32Array()

	for key in collision.keys():

		var collision_cell = collision[key]

		if not collision_cell is Dictionary:

			continue

		var voxel := collision_cell as Dictionary

		var collision_strength := clampf(float(voxel.get("collision_strength", 0.0)), 0.0, 1.0)

		if collision_strength <= VOXEL_OCCUPIED_EPSILON:

			continue

		var voxel_xz = voxel.get("voxel_xz", Vector2i.ZERO)

		if not voxel_xz is Vector2i:

			continue

		var px: Vector2i = voxel_xz

		var slice_index := int(voxel.get("slice_index", 0))

		if px.x < 0 or px.x >= xz_res or px.y < 0 or px.y >= xz_res or slice_index < 0 or slice_index >= total_slices:

			continue

		records.append(float(px.x))
		records.append(float(px.y))
		records.append(float(slice_index))
		records.append(collision_strength)

	return records

## 在 GPU 上将碰撞记录合并进基础碰撞场并回读结果

func _merge_sv_collision_records_gpu(base_field: PackedFloat32Array, collision: Dictionary, xz_res: int, total_slices: int) -> PackedFloat32Array:

	var voxel_count := xz_res * xz_res * total_slices

	if voxel_count <= 0 or base_field.size() != voxel_count:

		return PackedFloat32Array()

	var collision_records := _pack_sv_collision_records(collision, xz_res, total_slices)

	var record_count := int(collision_records.size() / 4)

	if record_count <= 0:

		return base_field

	if not _gpu_ready or _rd == null or not _shader_merge_sv_collision_records.is_valid() or not _pipeline_merge_sv_collision_records.is_valid():

		return PackedFloat32Array()

	var field_buffer := storage_buffer_from_floats(base_field, SCOPE_FRAME, "sv_collision_field_merge")

	var record_buffer := storage_buffer_from_floats(collision_records, SCOPE_FRAME, "sv_collision_record_merge")

	if not field_buffer.is_valid() or not record_buffer.is_valid():

		gc_frame()

		return PackedFloat32Array()

	var set0 := create_uniform_set([
		make_storage_uniform(0, field_buffer),
		make_storage_uniform(1, record_buffer),
	], _shader_merge_sv_collision_records, 0, SCOPE_PASS, "merge_sv_collision_records")

	if not set0.is_valid():

		gc_frame()

		return PackedFloat32Array()

	var push := PackedByteArray()

	push.resize(16)
	push.encode_s32(0, xz_res)
	push.encode_s32(4, total_slices)
	push.encode_s32(8, voxel_count)
	push.encode_s32(12, record_count)

	var groups := dispatch_groups_1d(record_count, 64)

	if not _gpu_dispatch_and_sync(_pipeline_merge_sv_collision_records, [set0], push, groups):
		gc_frame()
		return PackedFloat32Array()

	var output_bytes := _rd.buffer_get_data(field_buffer, 0, voxel_count * 4)

	var merged_field := SceneVoxelCommitPayloadScript.decode_float_buffer(output_bytes, voxel_count)

	gc_frame()

	return merged_field


## 生成地形基础碰撞体素场,失败时返回空场

func _make_terrain_base_collision_volume_field(terrain_base_img: Image, xz_res: int, total_slices: int) -> PackedFloat32Array:
	if terrain_base_img == null or terrain_base_img.is_empty():
		var empty_field := PackedFloat32Array()
		empty_field.resize(maxi(xz_res * xz_res * total_slices, 0))
		return empty_field

	var gpu_field := _make_terrain_base_collision_volume_field_gpu(terrain_base_img, xz_res, total_slices)
	if gpu_field.is_empty() and xz_res * xz_res * total_slices > 0:
		push_error("[SceneVoxelCommitter] Terrain collision volume compute failed")
	return gpu_field


## 用 GPU compute 着色器从地形图像生成三维碰撞体素场

func _make_terrain_base_collision_volume_field_gpu(terrain_base_img: Image, xz_res: int, total_slices: int) -> PackedFloat32Array:
	var voxel_count := xz_res * xz_res * total_slices
	if terrain_base_img == null or terrain_base_img.is_empty() or voxel_count <= 0:
		return PackedFloat32Array()
	if not _gpu_ready or _rd == null or not _sampler.is_valid():
		return PackedFloat32Array()

	var shader := load_compute_shader("res://shaders/terrain_collision_volume.glsl", SCOPE_FRAME, "terrain_collision_volume")
	var pipeline := create_compute_pipeline(shader, SCOPE_FRAME, "terrain_collision_volume")
	if not shader.is_valid() or not pipeline.is_valid():
		gc_frame()
		return PackedFloat32Array()

	var src_tex := upload_texture_2d(
		terrain_base_img,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		Image.FORMAT_RF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		SCOPE_FRAME,
		"terrain_collision_volume_src_r32f"
	)
	var output_buffer := storage_buffer_zero(voxel_count * 4, SCOPE_FRAME, "terrain_collision_volume_out")
	if not src_tex.is_valid() or not output_buffer.is_valid():
		gc_frame()
		return PackedFloat32Array()

	var set0 := create_uniform_set([
		make_sampler_uniform(0, _sampler, src_tex),
		make_storage_uniform(1, output_buffer),
	], shader, 0, SCOPE_PASS, "terrain_collision_volume")
	if not set0.is_valid():
		gc_frame()
		return PackedFloat32Array()

	var push := PackedByteArray()
	push.resize(32)
	push.encode_s32(0, xz_res)
	push.encode_s32(4, total_slices)
	push.encode_s32(8, terrain_base_img.get_width())
	push.encode_s32(12, terrain_base_img.get_height())
	push.encode_s32(16, voxel_count)
	push.encode_float(20, VOXEL_OCCUPIED_EPSILON)
	push.encode_float(24, 0.0)
	push.encode_float(28, 0.0)

	var groups := dispatch_groups_1d(voxel_count, 64)
	if not _gpu_dispatch_and_sync(pipeline, [set0], push, groups):
		gc_frame()
		return PackedFloat32Array()

	var output_bytes := _rd.buffer_get_data(output_buffer, 0, voxel_count * 4)
	var field := SceneVoxelCommitPayloadScript.decode_float_buffer(output_bytes, voxel_count)
	gc_frame()
	return field


## 根据记录与图层构造场景体素源模板字典
