class_name SceneVoxelCommitter

extends "res://scripts/godot_compute_shader_base.gd"

const VOXEL_OCCUPIED_EPSILON := 0.01

const SV_RESIDENT_TILE_SIZE := 8

const SCENE_VOXEL_TILE_SIZE_SETTING := "meshfill/scene_voxel_tile/size_voxels"

const DEFAULT_SCENE_VOXEL_TILE_SIZE := Vector3i(4, 4, 4)

const SCENE_VOXEL_TILE_RECORD_BUFFER := "scene_voxel_tile_records"
const SCENE_VOXEL_TILE_SUMMARY_BUFFER := "scene_voxel_tile_summaries"
const SCENE_VOXEL_TILE_DIRTY_INDEX_BUFFER := "scene_voxel_tile_dirty_indices"
const SCENE_VOXEL_TILE_OBJECT_REF_BUFFER := "scene_voxel_tile_object_refs"
const SCENE_VOXEL_TILE_SOURCE_REF_BUFFER := "scene_voxel_tile_source_refs"
const SCENE_VOXEL_TILE_SCENE_FIELD_BUFFER := "scene_voxel_tile_scene_field"
const SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER := "scene_voxel_tile_collision_field"
const SCENE_VOXEL_TILE_GPU_BUFFER_NAMES := [
	SCENE_VOXEL_TILE_RECORD_BUFFER,
	SCENE_VOXEL_TILE_SUMMARY_BUFFER,
	SCENE_VOXEL_TILE_DIRTY_INDEX_BUFFER,
	SCENE_VOXEL_TILE_OBJECT_REF_BUFFER,
	SCENE_VOXEL_TILE_SOURCE_REF_BUFFER,
	SCENE_VOXEL_TILE_SCENE_FIELD_BUFFER,
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
const SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_STATS_CAPACITY := 8
const SCENE_VOXEL_TILE_OBJECT_REF_DIRTY_DELTA_STRIDE_BYTES := 80
const SCENE_VOXEL_TILE_FIELD_STRIDE_BYTES := 4
const SCENE_VOXEL_TILE_REDUCE_SUMMARY_UINT_STRIDE := 6
const SCENE_VOXEL_TILE_COMPACT_SUMMARY_UINT_STRIDE := 8
const SCENE_VOXEL_TILE_REDUCE_QUANT_SCALE := 1000000.0
const SCENE_VOXEL_COMMIT_SOURCE_FLOAT_STRIDE := 16
const SCENE_VOXEL_COMMIT_OUTPUT_FLOAT_STRIDE := 8
const SCENE_VOXEL_COMMIT_SOURCE_NONE := 0
const SCENE_VOXEL_COMMIT_SOURCE_AUTO := 1
const SCENE_VOXEL_COMMIT_SOURCE_BRUSH := 2
const SCENE_VOXEL_SOURCE_CANDIDATE_STRIDE_BYTES := 16
const SCENE_VOXEL_SOURCE_CANDIDATE_RANGE_STRIDE_BYTES := 8

const SCENE_VOXEL_TILE_FLAG_SCENE := 1
const SCENE_VOXEL_TILE_FLAG_COLLISION := 2
const SCENE_VOXEL_TILE_FLAG_AUTO := 4
const SCENE_VOXEL_TILE_FLAG_BRUSH := 8
const SCENE_VOXEL_TILE_FLAG_TARGET := 16
const SCENE_VOXEL_TILE_FLAG_ROUTING := 32
const SCENE_VOXEL_TILE_FLAG_SCORING := 64
const SCENE_VOXEL_TILE_FLAG_FEEDBACK := 128
const SCENE_VOXEL_TILE_FLAG_OBJECT_REFS := 256
const SCENE_VOXEL_TILE_FLAG_MASK := 512

const CHANNEL_COUNT := 4

const SharedPropertyTypeScript := preload("res://scripts/shared_property_type.gd")
const SceneVoxelFeedbackScript := preload("res://scripts/scene_voxel_feedback.gd")
const SceneVoxelProfileScript := preload("res://scripts/scene_voxel_profile.gd")
const SceneVoxelSourceRecordScript := preload("res://scripts/scene_voxel_source_record.gd")
const SceneVoxelPayloadScript := preload("res://scripts/scene_voxel_payload.gd")
const SceneVoxelCommitPayloadScript := preload("res://scripts/scene_voxel_commit_payload.gd")
const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")
const SceneVoxelValidationScript := preload("res://scripts/scene_voxel_validation.gd")
const SceneVoxelVolumeChannelsScript := preload("res://scripts/scene_voxel_volume_channels.gd")
const SceneVoxelBrushScript := preload("res://scripts/scene_voxel_brush.gd")
const SceneVoxelTargetScript := preload("res://scripts/scene_voxel_target.gd")

var _base_res: int  ## Base resolution for world↔pixel coordinate mapping

var _capture_size: float

var grid_size: Vector3i  ## SV grid dimensions in voxels

var voxel_size: Vector3  ## World-space size of one voxel

var grid_origin: Vector3  ## World-space origin for voxel index conversion

## Packed RGBA occupancy: one value per explicit channel.

var _occupancy: Image

## Source collision scalar field generated through the shared max-stamp path.

## Terrain base remains a separate input; both are published as one resident collision field.

var _source_collision_field: Image

## Authoritative terrain/base collision input layer.

var _terrain_base_collision_field: Image

## Resident collision read field: max(TerrainBaseCollision, source collision field).

var _collision_field: Image

## GPU resources

var _sampler: RID

var _shader_import: RID

var _pipeline_import: RID

var _shader_filter: RID

var _pipeline_filter: RID

var _shader_max_collision: RID

var _pipeline_max_collision: RID

var _shader_blend_scene_fields: RID

var _pipeline_blend_scene_fields: RID

var _shader_commit_scene_voxels: RID

var _pipeline_commit_scene_voxels: RID

var _shader_resolve_scene_sources: RID

var _pipeline_resolve_scene_sources: RID

var _shader_stamp_r32_disc: RID

var _pipeline_stamp_r32_disc: RID

var _shader_stamp_rgba_channel_disc: RID

var _pipeline_stamp_rgba_channel_disc: RID

var _shader_merge_sv_collision_records: RID

var _pipeline_merge_sv_collision_records: RID

var _shader_score_scene_voxel_feedback: RID

var _pipeline_score_scene_voxel_feedback: RID

var _shader_reduce_scene_voxel_stats: RID

var _pipeline_reduce_scene_voxel_stats: RID

var _shader_reduce_scene_voxel_tile_summaries: RID

var _pipeline_reduce_scene_voxel_tile_summaries: RID

var _shader_init_scene_voxel_tile_summaries: RID

var _pipeline_init_scene_voxel_tile_summaries: RID

var _shader_compact_scene_voxel_tile_summaries: RID

var _pipeline_compact_scene_voxel_tile_summaries: RID

var _shader_update_scene_voxel_tile_summary_ranges: RID

var _pipeline_update_scene_voxel_tile_summary_ranges: RID

var _shader_scene_voxel_tile_object_ref_update: RID

var _pipeline_scene_voxel_tile_object_ref_update: RID

var _shader_collect_disc_pixels: RID

var _pipeline_collect_disc_pixels: RID

var _shader_sample_r32_pixel: RID

var _pipeline_sample_r32_pixel: RID

var _gpu_ready: bool = false
var _legacy_scatter_warning_emitted: bool = false

func _init(base_resolution: int, capture_size: float, _enable_gpu: bool = true) -> void:

	_base_res = base_resolution

	_capture_size = capture_size

	_register_scene_voxel_tile_project_settings()

	grid_origin = _default_grid_origin()

	voxel_size = _voxel_size_for_resolution(_base_res, 1.0)

	grid_size = Vector3i(_base_res, 1, _base_res)

	_occupancy = Image.create(_base_res, _base_res, false, Image.FORMAT_RGBAH)

	_occupancy.fill(Color(0.0, 0.0, 0.0, 0.0))

	_source_collision_field = _create_collision_image(_base_res)

	_terrain_base_collision_field = _create_collision_image(_base_res)

	_collision_field = _create_collision_image(_base_res)

	_init_gpu()

func _init_gpu() -> void:

	log_name = "SceneVoxelCommitter"

	if not ensure_device(true, false):

		_gpu_fatal("Failed to create RenderingDevice — GPU compute required")

		return

	_sampler = create_linear_sampler()

	_shader_import = load_compute_shader("res://shaders/channel_import_mask.glsl")

	if _shader_import.is_valid():

		_pipeline_import = create_compute_pipeline(_shader_import)

	_shader_filter = load_compute_shader("res://shaders/channel_filter_candidates.glsl")

	if _shader_filter.is_valid():

		_pipeline_filter = create_compute_pipeline(_shader_filter)

	_shader_max_collision = load_compute_shader("res://shaders/max_collision_images.glsl")

	if _shader_max_collision.is_valid():

		_pipeline_max_collision = create_compute_pipeline(_shader_max_collision)

	_shader_blend_scene_fields = load_compute_shader("res://shaders/blend_scene_voxel_fields.glsl")

	if _shader_blend_scene_fields.is_valid():

		_pipeline_blend_scene_fields = create_compute_pipeline(_shader_blend_scene_fields)

	_shader_commit_scene_voxels = load_compute_shader("res://shaders/commit_scene_voxel_payloads.glsl")

	if _shader_commit_scene_voxels.is_valid():

		_pipeline_commit_scene_voxels = create_compute_pipeline(_shader_commit_scene_voxels)

	_shader_resolve_scene_sources = load_compute_shader("res://shaders/resolve_scene_voxel_sources.glsl")

	if _shader_resolve_scene_sources.is_valid():

		_pipeline_resolve_scene_sources = create_compute_pipeline(_shader_resolve_scene_sources)
	_shader_stamp_r32_disc = load_compute_shader("res://shaders/stamp_r32_disc.glsl")

	if _shader_stamp_r32_disc.is_valid():

		_pipeline_stamp_r32_disc = create_compute_pipeline(_shader_stamp_r32_disc)
	_shader_stamp_rgba_channel_disc = load_compute_shader("res://shaders/stamp_rgba_channel_disc.glsl")

	if _shader_stamp_rgba_channel_disc.is_valid():

		_pipeline_stamp_rgba_channel_disc = create_compute_pipeline(_shader_stamp_rgba_channel_disc)
	_shader_merge_sv_collision_records = load_compute_shader("res://shaders/merge_sv_collision_records.glsl")

	if _shader_merge_sv_collision_records.is_valid():

		_pipeline_merge_sv_collision_records = create_compute_pipeline(_shader_merge_sv_collision_records)
	_shader_score_scene_voxel_feedback = load_compute_shader("res://shaders/score_scene_voxel_feedback.glsl")

	if _shader_score_scene_voxel_feedback.is_valid():

		_pipeline_score_scene_voxel_feedback = create_compute_pipeline(_shader_score_scene_voxel_feedback)

	_shader_reduce_scene_voxel_stats = load_compute_shader("res://shaders/reduce_scene_voxel_stats.glsl")

	if _shader_reduce_scene_voxel_stats.is_valid():

		_pipeline_reduce_scene_voxel_stats = create_compute_pipeline(_shader_reduce_scene_voxel_stats)

	_shader_reduce_scene_voxel_tile_summaries = load_compute_shader("res://shaders/reduce_scene_voxel_tile_summaries.glsl")

	if _shader_reduce_scene_voxel_tile_summaries.is_valid():

		_pipeline_reduce_scene_voxel_tile_summaries = create_compute_pipeline(_shader_reduce_scene_voxel_tile_summaries)

	_shader_init_scene_voxel_tile_summaries = load_compute_shader("res://shaders/init_scene_voxel_tile_summaries.glsl")

	if _shader_init_scene_voxel_tile_summaries.is_valid():

		_pipeline_init_scene_voxel_tile_summaries = create_compute_pipeline(_shader_init_scene_voxel_tile_summaries)

	_shader_compact_scene_voxel_tile_summaries = load_compute_shader("res://shaders/compact_scene_voxel_tile_summaries.glsl")

	if _shader_compact_scene_voxel_tile_summaries.is_valid():

		_pipeline_compact_scene_voxel_tile_summaries = create_compute_pipeline(_shader_compact_scene_voxel_tile_summaries)

	_shader_update_scene_voxel_tile_summary_ranges = load_compute_shader("res://shaders/update_scene_voxel_tile_summary_ranges.glsl")

	if _shader_update_scene_voxel_tile_summary_ranges.is_valid():

		_pipeline_update_scene_voxel_tile_summary_ranges = create_compute_pipeline(_shader_update_scene_voxel_tile_summary_ranges)

	_shader_scene_voxel_tile_object_ref_update = load_compute_shader(SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_PATH)

	if _shader_scene_voxel_tile_object_ref_update.is_valid():

		_pipeline_scene_voxel_tile_object_ref_update = create_compute_pipeline(_shader_scene_voxel_tile_object_ref_update)

	_shader_collect_disc_pixels = load_compute_shader("res://shaders/collect_disc_pixels.glsl")

	if _shader_collect_disc_pixels.is_valid():

		_pipeline_collect_disc_pixels = create_compute_pipeline(_shader_collect_disc_pixels)

	_shader_sample_r32_pixel = load_compute_shader("res://shaders/sample_r32_pixel.glsl")

	if _shader_sample_r32_pixel.is_valid():

		_pipeline_sample_r32_pixel = create_compute_pipeline(_shader_sample_r32_pixel)

	var missing_gpu_rids: Array[String] = []

	if not _sampler.is_valid():

		missing_gpu_rids.append("sampler")

	if not _shader_import.is_valid():

		missing_gpu_rids.append("shader_import")

	if not _pipeline_import.is_valid():

		missing_gpu_rids.append("pipeline_import")

	if not _shader_filter.is_valid():

		missing_gpu_rids.append("shader_filter")

	if not _pipeline_filter.is_valid():

		missing_gpu_rids.append("pipeline_filter")

	if not _shader_max_collision.is_valid():

		missing_gpu_rids.append("shader_max_collision")

	if not _pipeline_max_collision.is_valid():

		missing_gpu_rids.append("pipeline_max_collision")

	if not _shader_blend_scene_fields.is_valid():

		missing_gpu_rids.append("shader_blend_scene_fields")

	if not _pipeline_blend_scene_fields.is_valid():

		missing_gpu_rids.append("pipeline_blend_scene_fields")

	if not _shader_commit_scene_voxels.is_valid():

		missing_gpu_rids.append("shader_commit_scene_voxels")

	if not _pipeline_commit_scene_voxels.is_valid():

		missing_gpu_rids.append("pipeline_commit_scene_voxels")

	if not _shader_resolve_scene_sources.is_valid():

		missing_gpu_rids.append("shader_resolve_scene_sources")

	if not _pipeline_resolve_scene_sources.is_valid():

		missing_gpu_rids.append("pipeline_resolve_scene_sources")
	if not _shader_stamp_r32_disc.is_valid():

		missing_gpu_rids.append("shader_stamp_r32_disc")
	if not _pipeline_stamp_r32_disc.is_valid():

		missing_gpu_rids.append("pipeline_stamp_r32_disc")
	if not _shader_stamp_rgba_channel_disc.is_valid():

		missing_gpu_rids.append("shader_stamp_rgba_channel_disc")
	if not _pipeline_stamp_rgba_channel_disc.is_valid():

		missing_gpu_rids.append("pipeline_stamp_rgba_channel_disc")
	if not _shader_merge_sv_collision_records.is_valid():

		missing_gpu_rids.append("shader_merge_sv_collision_records")
	if not _pipeline_merge_sv_collision_records.is_valid():

		missing_gpu_rids.append("pipeline_merge_sv_collision_records")
	if not _shader_score_scene_voxel_feedback.is_valid():

		missing_gpu_rids.append("shader_score_scene_voxel_feedback")
	if not _pipeline_score_scene_voxel_feedback.is_valid():

		missing_gpu_rids.append("pipeline_score_scene_voxel_feedback")
	if not _shader_reduce_scene_voxel_stats.is_valid():

		missing_gpu_rids.append("shader_reduce_scene_voxel_stats")
	if not _pipeline_reduce_scene_voxel_stats.is_valid():

		missing_gpu_rids.append("pipeline_reduce_scene_voxel_stats")
	if not _shader_reduce_scene_voxel_tile_summaries.is_valid():

		missing_gpu_rids.append("shader_reduce_scene_voxel_tile_summaries")
	if not _pipeline_reduce_scene_voxel_tile_summaries.is_valid():

		missing_gpu_rids.append("pipeline_reduce_scene_voxel_tile_summaries")
	if not _shader_init_scene_voxel_tile_summaries.is_valid():

		missing_gpu_rids.append("shader_init_scene_voxel_tile_summaries")
	if not _pipeline_init_scene_voxel_tile_summaries.is_valid():

		missing_gpu_rids.append("pipeline_init_scene_voxel_tile_summaries")
	if not _shader_compact_scene_voxel_tile_summaries.is_valid():

		missing_gpu_rids.append("shader_compact_scene_voxel_tile_summaries")
	if not _pipeline_compact_scene_voxel_tile_summaries.is_valid():

		missing_gpu_rids.append("pipeline_compact_scene_voxel_tile_summaries")
	if not _shader_update_scene_voxel_tile_summary_ranges.is_valid():

		missing_gpu_rids.append("shader_update_scene_voxel_tile_summary_ranges")
	if not _pipeline_update_scene_voxel_tile_summary_ranges.is_valid():

		missing_gpu_rids.append("pipeline_update_scene_voxel_tile_summary_ranges")
	if not _shader_scene_voxel_tile_object_ref_update.is_valid():

		missing_gpu_rids.append("shader_scene_voxel_tile_object_ref_update")
	if not _pipeline_scene_voxel_tile_object_ref_update.is_valid():

		missing_gpu_rids.append("pipeline_scene_voxel_tile_object_ref_update")
	if not _shader_collect_disc_pixels.is_valid():

		missing_gpu_rids.append("shader_collect_disc_pixels")
	if not _pipeline_collect_disc_pixels.is_valid():

		missing_gpu_rids.append("pipeline_collect_disc_pixels")
	if not _shader_sample_r32_pixel.is_valid():

		missing_gpu_rids.append("shader_sample_r32_pixel")
	if not _pipeline_sample_r32_pixel.is_valid():

		missing_gpu_rids.append("pipeline_sample_r32_pixel")

	_gpu_ready = missing_gpu_rids.is_empty()

	if _gpu_ready:

		print("[SceneVoxelCommitter] GPU compute ready (18 shaders loaded)")

	else:

		_gpu_fatal("Scene voxel compute resources are not ready: %s" % ", ".join(missing_gpu_rids))

func _gpu_fatal(msg: String) -> void:

	var full := "[SceneVoxelCommitter] GPU ERROR: %s" % msg

	push_error(full)

	OS.alert(full, "SceneVoxelCommitter — GPU Required")

	_gpu_ready = false

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
func _gpu_dispatch_pipeline(cl: int, pipeline: RID, uniform_set: RID, push: PackedByteArray, groups: Vector3i) -> void:
	_rd.compute_list_bind_compute_pipeline(cl, pipeline)
	_rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, groups.x, groups.y, groups.z)

func _free_gpu() -> void:

	_release_scene_voxel_tile_gpu_buffers()

	dispose()

	_pipeline_import = RID()

	_shader_import = RID()

	_pipeline_filter = RID()

	_shader_filter = RID()

	_pipeline_max_collision = RID()

	_shader_max_collision = RID()

	_pipeline_blend_scene_fields = RID()

	_shader_blend_scene_fields = RID()

	_pipeline_commit_scene_voxels = RID()

	_shader_commit_scene_voxels = RID()

	_pipeline_resolve_scene_sources = RID()

	_shader_resolve_scene_sources = RID()
	_pipeline_stamp_r32_disc = RID()

	_shader_stamp_r32_disc = RID()

	_pipeline_stamp_rgba_channel_disc = RID()

	_shader_stamp_rgba_channel_disc = RID()

	_pipeline_merge_sv_collision_records = RID()

	_shader_merge_sv_collision_records = RID()

	_pipeline_score_scene_voxel_feedback = RID()

	_shader_score_scene_voxel_feedback = RID()

	_pipeline_reduce_scene_voxel_stats = RID()

	_shader_reduce_scene_voxel_stats = RID()

	_pipeline_reduce_scene_voxel_tile_summaries = RID()

	_shader_reduce_scene_voxel_tile_summaries = RID()

	_pipeline_init_scene_voxel_tile_summaries = RID()

	_shader_init_scene_voxel_tile_summaries = RID()

	_pipeline_compact_scene_voxel_tile_summaries = RID()

	_shader_compact_scene_voxel_tile_summaries = RID()

	_pipeline_update_scene_voxel_tile_summary_ranges = RID()

	_shader_update_scene_voxel_tile_summary_ranges = RID()

	_pipeline_scene_voxel_tile_object_ref_update = RID()

	_shader_scene_voxel_tile_object_ref_update = RID()

	_pipeline_collect_disc_pixels = RID()

	_shader_collect_disc_pixels = RID()

	_pipeline_sample_r32_pixel = RID()

	_shader_sample_r32_pixel = RID()

	_sampler = RID()

	_gpu_ready = false

func _on_before_dispose() -> void:

	_release_scene_voxel_source_candidate_resident_buffers()

	_release_scene_voxel_tile_gpu_buffers()

func _default_grid_origin() -> Vector3:

	var half := _capture_size * 0.5

	return Vector3(-half, 0.0, -half)

func _voxel_size_for_resolution(resolution: int, y_size: float = 1.0) -> Vector3:

	var res := maxi(resolution, 1)

	var xz_size := _capture_size / float(res)

	return Vector3(xz_size, maxf(y_size, 0.0001), xz_size)

func configure_scene_voxel_grid(

	p_grid_size: Vector3i,

	p_voxel_size: Vector3,

	p_grid_origin: Vector3 = Vector3.ZERO

) -> void:

	var previous_grid_size := grid_size

	var previous_voxel_size := voxel_size

	var previous_grid_origin := grid_origin

	grid_size = Vector3i(maxi(p_grid_size.x, 1), maxi(p_grid_size.y, 1), maxi(p_grid_size.z, 1))

	voxel_size = Vector3(

		maxf(p_voxel_size.x, 0.0001),

		maxf(p_voxel_size.y, 0.0001),

		maxf(p_voxel_size.z, 0.0001)

	)

	grid_origin = p_grid_origin

	_capture_size = voxel_size.x * float(grid_size.x)

	if previous_grid_size != grid_size or previous_voxel_size != voxel_size or previous_grid_origin != grid_origin:

		_mark_scene_voxel_full_rebuild_dirty("grid_configured")

	else:

		_mark_scene_voxel_tile_staging_dirty("grid_configured")

func configure_from_sv(sv) -> void:

	if sv == null:

		return

	var sv_grid_size: Vector3i = sv.get("grid_size", grid_size) if sv is Dictionary else sv.grid_size

	var sv_voxel_size: Vector3 = sv.get("voxel_size", voxel_size) if sv is Dictionary else sv.voxel_size

	var sv_grid_origin: Vector3 = sv.get("grid_origin", grid_origin) if sv is Dictionary else sv.grid_origin

	configure_scene_voxel_grid(

		sv_grid_size,

		sv_voxel_size,

		sv_grid_origin

	)

func _apply_volume_grid_metadata(xz_res: int, total_slices: int, y_min: float = 0.0, y_max: float = 1.0) -> void:

	var safe_xz := maxi(xz_res, 1)

	var safe_y := maxi(total_slices, 1)

	var y_span := maxf(y_max - y_min, 0.0001)

	var origin_x := grid_origin.x

	var origin_z := grid_origin.z

	grid_size = Vector3i(safe_xz, safe_y, safe_xz)

	voxel_size = _voxel_size_for_resolution(safe_xz, y_span / float(safe_y))

	grid_origin = Vector3(origin_x, y_min, origin_z)

	_mark_scene_voxel_full_rebuild_dirty("volume_grid_metadata")

func _create_collision_image(resolution: int) -> Image:

	var safe_res := maxi(resolution, 1)

	var img := Image.create(safe_res, safe_res, false, Image.FORMAT_RF)

	img.fill(Color(0.0, 0.0, 0.0, 0.0))

	return img

func _max_collision_images(a: Image, b: Image) -> Image:

	return _max_collision_images_gpu(a, b)

func _max_collision_images_gpu(a: Image, b: Image) -> Image:

	if a == null or a.is_empty() or b == null or b.is_empty():

		push_error("[SceneVoxelCommitter] Collision max compute requires two valid images")

		return _create_collision_image(_base_res)

	if not _gpu_ready or _rd == null or not _shader_max_collision.is_valid() or not _pipeline_max_collision.is_valid():

		push_error("[SceneVoxelCommitter] Collision max compute resources are not ready")

		return _create_collision_image(_base_res)

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

		_base_res,

		_base_res,

		RenderingDevice.DATA_FORMAT_R32_SFLOAT,

		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT,

		SCOPE_FRAME,

		"collision_max_r32f"

	)

	if not tex_a.is_valid() or not tex_b.is_valid() or not out_tex.is_valid():

		gc_frame()

		push_error("[SceneVoxelCommitter] Collision max compute texture allocation failed")

		return _create_collision_image(_base_res)

	var set0 := create_uniform_set([

		make_sampler_uniform(0, _sampler, tex_a),

		make_sampler_uniform(1, _sampler, tex_b),

	], _shader_max_collision, 0)

	var set1 := create_uniform_set([

		make_image_uniform(0, out_tex),

	], _shader_max_collision, 1)

	var push := PackedByteArray()

	push.resize(16)

	push.encode_s32(0, _base_res)

	push.encode_s32(4, _base_res)

	push.encode_s32(8, 0)

	push.encode_s32(12, 0)

	var groups := ceili(float(_base_res) / 32.0)

	if not _gpu_dispatch_and_sync(_pipeline_max_collision, [set0, set1], push, Vector3i(groups, groups, 1)):
		gc_frame()
		push_error("[SceneVoxelCommitter] Collision max compute list begin failed")
		return _create_collision_image(_base_res)

	var data := _rd.texture_get_data(out_tex, 0)

	var result := Image.create_from_data(_base_res, _base_res, false, Image.FORMAT_RF, data)

	gc_frame()

	return result

func _refresh_combined_collision_field() -> void:

	_collision_field = _max_collision_images(_terrain_base_collision_field, _source_collision_field)

func _slice_voxel_size_y(slice_index: int = 0) -> float:

	if _volume.is_empty():

		return maxf(voxel_size.y, 0.0001)

	var meta: Array = _volume.get("slice_meta", [])

	if slice_index >= 0 and slice_index < meta.size() and meta[slice_index] is Dictionary:

		var m := meta[slice_index] as Dictionary

		return maxf(float(m.get("y_max", 1.0)) - float(m.get("y_min", 0.0)), 0.0001)

	return maxf(voxel_size.y, 0.0001)

func world_to_voxel(world_pos: Vector3, resolution: int = -1) -> Vector3i:

	var res := maxi(resolution if resolution > 0 else _base_res, 1)

	var size := _voxel_size_for_resolution(res, voxel_size.y)

	var local := world_pos - grid_origin

	return Vector3i(

		clampi(floori(local.x / size.x), 0, res - 1),

		maxi(floori(local.y / size.y), 0),

		clampi(floori(local.z / size.z), 0, res - 1)

	)

func voxel_to_world(voxel_pos: Vector3i, resolution: int = -1) -> Vector3:

	var res := maxi(resolution if resolution > 0 else _base_res, 1)

	var size := _voxel_size_for_resolution(res, voxel_size.y)

	return grid_origin + Vector3(

		float(voxel_pos.x) * size.x,

		float(voxel_pos.y) * size.y,

		float(voxel_pos.z) * size.z

	)

func world_to_volume_pixel(world_pos: Vector3, resolution: int = -1) -> Vector2i:

	var res := maxi(resolution if resolution > 0 else _base_res, 1)

	var voxel := world_to_voxel(world_pos, res)

	return Vector2i(voxel.x, voxel.z)

func volume_pixel_to_world(voxel_xz: Vector2i, resolution: int = -1, y: float = 0.0) -> Vector3:

	var res := maxi(resolution if resolution > 0 else _base_res, 1)

	var size := _voxel_size_for_resolution(res, voxel_size.y)

	return grid_origin + Vector3(

		float(voxel_xz.x) * size.x,

		y,

		float(voxel_xz.y) * size.z

	)

func _is_valid_channel(channel: int) -> bool:

	return channel >= 0 and channel < CHANNEL_COUNT

func import_mask_channel(channel: int, mask_img: Image, complexity: float = 1.0) -> void:

	assert(_gpu_ready, "[SceneVoxelCommitter] GPU not ready — cannot import mask")

	if not _is_valid_channel(channel):

		push_error("[SceneVoxelCommitter] Invalid channel: %d" % channel)

		return

	_gpu_import_mask(channel, clampf(complexity, 0.0, 1.0), mask_img)

func _gpu_import_mask(channel: int, complexity: float, mask_img: Image) -> void:

	var tex_src := upload_texture_2d(mask_img)

	var tex_occ := create_rw_texture_2d(_base_res, _base_res, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT)

	# Upload current occupancy into rw texture

	var occ_rgba := _occupancy.duplicate()

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

	push.encode_s32(12, _base_res)

	var groups := ceili(float(_base_res) / 32.0)

	if not _gpu_dispatch_and_sync(_pipeline_import, [set0, set1], push, Vector3i(groups, groups, 1)):
		gc_frame()
		push_error("[SceneVoxelCommitter] Channel import compute list begin failed")
		return

	# Read back packed occupancy

	var data := _rd.texture_get_data(tex_occ, 0)

	_occupancy = Image.create_from_data(_base_res, _base_res, false, Image.FORMAT_RGBAH, data)

	gc_frame()

static func profile_channel(

	channel: int,

	radius: float = 0.2,

	color: Color = Color.WHITE,

	complexity: float = 1.0,

	y_min: float = 0.0,

	y_max: float = 1.0,

	subdivisions: int = 1

) -> Array[Dictionary]:
	return SceneVoxelProfileScript.profile_channel(channel, radius, color, complexity, y_min, y_max, subdivisions)

static func profile_custom(entries: Array[Dictionary]) -> Array[Dictionary]:
	return SceneVoxelProfileScript.profile_custom(entries)

## ─── Core Operations (GPU only) ───

## Build a vec4 profile mask from a profile: 1.0 in channels this profile uses.

## Convert world-meter radius to pixels at base resolution.

func _radius_to_px(radius_m: float) -> int:

	var pixel_size := _capture_size / float(_base_res)

	return maxi(1, ceili(radius_m / pixel_size))

func _stamp_scalar_image_disc(img: Image, center_px: Vector2i, radius_px: int, value: float, channel: int = 0) -> Image:

	if img == null or img.is_empty():

		return img

	var stamped := _stamp_scalar_image_disc_gpu(img, center_px, radius_px, value, channel)

	if stamped != null and not stamped.is_empty():

		return stamped

	push_error("[SceneVoxelCommitter] GPU scalar disc stamp failed")

	return img

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

func _collect_disc_pixels_gpu(
	previous_img: Image,
	center_px: Vector2i,
	radius_px: int,
	value: float,
	force_write: bool = false,
	source_compare: bool = false
) -> Array[Vector2i]:
	var pixels: Array[Vector2i] = []
	if previous_img == null or previous_img.is_empty():
		return pixels
	if not _gpu_ready or _rd == null or not _sampler.is_valid():
		return pixels
	if not _shader_collect_disc_pixels.is_valid() or not _pipeline_collect_disc_pixels.is_valid():
		return pixels

	var width := previous_img.get_width()
	var height := previous_img.get_height()
	var radius := maxi(radius_px, 0)
	var disc_size := radius * 2 + 1
	var max_records := maxi(disc_size * disc_size, 1)
	var src_tex := upload_texture_2d(
		previous_img,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		Image.FORMAT_RF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		SCOPE_FRAME,
		"collect_disc_pixels_src"
	)
	var records_buffer := storage_buffer_zero(max_records * 16, SCOPE_FRAME, "collect_disc_pixel_records")
	var counter_buffer := storage_buffer_zero(4, SCOPE_FRAME, "collect_disc_pixel_counter")
	if not src_tex.is_valid() or not records_buffer.is_valid() or not counter_buffer.is_valid():
		gc_frame()
		return pixels

	var set0 := create_uniform_set([
		make_sampler_uniform(0, _sampler, src_tex),
		make_storage_uniform(1, records_buffer),
		make_storage_uniform(2, counter_buffer),
	], _shader_collect_disc_pixels, 0, SCOPE_PASS, "collect_disc_pixels")
	if not set0.is_valid():
		gc_frame()
		return pixels

	var push := PackedByteArray()
	push.resize(48)
	var compare_mode := 1 if force_write else (2 if source_compare else 0)
	push.encode_s32(0, width)
	push.encode_s32(4, height)
	push.encode_s32(8, max_records)
	push.encode_s32(12, compare_mode)
	push.encode_s32(16, clampi(center_px.x, 0, width - 1))
	push.encode_s32(20, clampi(center_px.y, 0, height - 1))
	push.encode_s32(24, radius)
	push.encode_s32(28, disc_size)
	push.encode_float(32, clampf(value, 0.0, 1.0))
	push.encode_float(36, VOXEL_OCCUPIED_EPSILON)
	push.encode_float(40, 0.00001)
	push.encode_float(44, SCENE_VOXEL_TILE_REDUCE_QUANT_SCALE)

	var groups := dispatch_groups_2d(disc_size, disc_size, 16, 16)
	if not _gpu_dispatch_and_sync(_pipeline_collect_disc_pixels, [set0], push, groups):
		gc_frame()
		return pixels

	var counter_bytes := _rd.buffer_get_data(counter_buffer, 0, 4)
	var record_count := 0
	if counter_bytes.size() >= 4:
		record_count = clampi(int(counter_bytes.decode_u32(0)), 0, max_records)
	if record_count <= 0:
		gc_frame()
		return pixels

	var record_bytes := _rd.buffer_get_data(records_buffer, 0, record_count * 16)
	gc_frame()
	for i in range(record_count):
		var base := i * 16
		var x := int(record_bytes.decode_u32(base + 0)) if base + 4 <= record_bytes.size() else 0
		var z := int(record_bytes.decode_u32(base + 4)) if base + 8 <= record_bytes.size() else 0
		pixels.append(Vector2i(x, z))
	return pixels

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

func _collision_effective_radius(collision: Dictionary) -> float:

	var radius := maxf(float(collision.get("radius", 0.0)), 0.0)

	var erosion := maxf(float(collision.get("erosion_radius", 0.0)), 0.0)

	var dilation := maxf(float(collision.get("dilation_radius", 0.0)), 0.0)

	if erosion > 0.0 and radius <= erosion:

		return 0.0

	return maxf(radius - erosion, 0.0) + dilation

func _is_point_collision_sample(collision: Dictionary) -> bool:

	return collision.has("voxel") or collision.has("local_pos") or collision.has("voxel_offset")

func _vector3i_from_value(value, fallback: Vector3i = Vector3i.ZERO) -> Vector3i:

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

		var dict := value as Dictionary

		return Vector3i(

			int(dict.get("x", fallback.x)),

			int(dict.get("y", fallback.y)),

			int(dict.get("z", fallback.z))

		)

	return fallback

func _collision_local_voxel(collision: Dictionary) -> Vector3i:

	return _vector3i_from_value(collision.get("voxel", collision.get("local_pos", collision.get("voxel_offset", Vector3i.ZERO))), Vector3i.ZERO)

func _collision_layer_base_px(base_px: Vector2i, collision: Dictionary) -> Vector2i:

	if not _is_point_collision_sample(collision):

		return base_px

	var local := _collision_local_voxel(collision)

	return Vector2i(

		clampi(base_px.x + local.x, 0, _base_res - 1),

		clampi(base_px.y + local.z, 0, _base_res - 1)

	)

func _collision_radius_px(collision: Dictionary) -> int:

	if _is_point_collision_sample(collision):

		return maxi(int(collision.get("radius_px", 0)), 0)

	if collision.has("radius_px"):

		return maxi(int(collision.radius_px), 1)

	return maxi(1, _radius_to_px(_collision_effective_radius(collision)))

func _normalize_shared_field_layers(field_layers: Array, base_px: Vector2i = Vector2i(-1, -1)) -> Array[Dictionary]:

	var result: Array[Dictionary] = []

	var canonical_layers := AutoVoxelDescriptor.normalize_collision(field_layers, 0.0)

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

		collision_entry["radius_px"] = _radius_to_px(effective_radius)

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

func _make_source_collision(base_px: Vector2i, collision_layers: Array, rec: Dictionary = {}) -> Array[Dictionary]:

	var updated: Array[Dictionary] = []

	var source_type := str(rec.get("source_voxel_type", ""))

	if source_type == "TargetSceneVoxel":

		return updated

	var xz_res := _base_res

	if not _volume.is_empty():

		xz_res = int(_volume.get("xz_res", _base_res))

	var layers := _normalize_shared_field_layers(collision_layers, base_px)

	for layer in layers:

		var collision_strength := clampf(float(layer.get("collision_strength", 1.0)), 0.0, 1.0)

		var radius_px := _collision_radius_px(layer)

		var layer_base_px := _collision_layer_base_px(base_px, layer)

		var source_layer := layer.duplicate(true)

		source_layer["collision_strength"] = collision_strength

		source_layer["base_pixel"] = layer_base_px

		source_layer["voxel_xz"] = _volume_px_from_base(layer_base_px, xz_res)

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

func _field_cell_key(field_name: String, px: Vector2i) -> String:

	return "%s:%d:%d" % [field_name, px.x, px.y]

func _ensure_volume_collision_layer() -> void:

	if _volume.is_empty():

		return

	var xz_res: int = _volume.xz_res

	if not _volume.has("terrain_base_collision_field"):

		_volume["terrain_base_collision_field"] = _resample_collision_field(_terrain_base_collision_field, xz_res)

	if not _volume.has("source_collision_field"):

		_volume["source_collision_field"] = _resample_collision_field(_source_collision_field, xz_res)

	if not _volume.has("collision_field"):

		var img := _resample_collision_field(_collision_field, xz_res)

		_volume["collision_field"] = img

	if not _volume.has("collision"):

		_volume["collision"] = {}

func _resample_collision_field(source_img: Image, xz_res: int) -> Image:
	var gpu_img := _resample_collision_field_gpu(source_img, xz_res)
	if gpu_img != null and not gpu_img.is_empty():
		return gpu_img
	var img := _create_collision_image(maxi(xz_res, 1))
	if source_img != null and not source_img.is_empty() and xz_res > 0:
		push_error("[SceneVoxelCommitter] Collision field resample GPU compute failed")
	return img


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
	push.encode_s32(16, _base_res)
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

	if _volume.is_empty():

		return base_px

	_ensure_volume_collision_layer()

	var xz_res: int = _volume.xz_res

	var field_img: Image = _volume.get(field_name, _create_collision_image(xz_res))

	var previous_field_img := field_img

	var voxel_px := _volume_px_from_base(base_px, xz_res)

	var radius_vol := _volume_radius_from_base_radius(radius_px, xz_res)

	field_img = _stamp_scalar_image_disc(field_img, voxel_px, radius_vol, value, 0)

	var cell_map: Dictionary = _volume.get(cell_map_name, {})

	var field_value := clampf(value, 0.0, 1.0)

	var changed_pixels := _collect_disc_pixels_gpu(previous_field_img, voxel_px, radius_vol, field_value, false)
	for px in changed_pixels:
		var cell := cell_template.duplicate(true)
		cell[value_key] = field_value
		cell["base_pixel"] = base_px
		cell["voxel_xz"] = px
		cell["slice_index"] = int(cell.get("slice_index", 0))
		cell["radius_px"] = radius_px
		cell_map[_field_cell_key(cell_key_prefix, px)] = cell
		_mark_sv_tile_dirty(int(cell.slice_index), px, dirty_layer, SV_RESIDENT_TILE_SIZE, cell)

	_volume[field_name] = field_img

	_volume[cell_map_name] = cell_map

	return voxel_px

func _stamp_shared_field_layer(base_px: Vector2i, source_layer: Dictionary, rec: Dictionary = {}) -> Dictionary:

	var normalized := _normalize_shared_field_layers([source_layer], base_px)

	if normalized.is_empty():

		return {}

	var layer := normalized[0]

	var radius_px := _collision_radius_px(layer)

	var collision_strength := clampf(float(layer.get("collision_strength", 1.0)), 0.0, 1.0)

	layer["collision_strength"] = collision_strength

	var layer_base_px := _collision_layer_base_px(base_px, layer)

	_source_collision_field = _stamp_scalar_image_disc(_source_collision_field, layer_base_px, radius_px, collision_strength, 0)

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

	if not _volume.is_empty():

		var xz_res: int = _volume.xz_res

		_refresh_combined_collision_field()

		_volume["collision_field"] = _resample_collision_field(_collision_field, xz_res)

	layer["base_pixel"] = layer_base_px

	layer["voxel_xz"] = voxel_px

	layer["volume_xz_resolution"] = int(_volume.xz_res) if not _volume.is_empty() else _base_res

	layer["collision_buffer_applied"] = true

	return layer

func _stamp_shared_field_layers(base_px: Vector2i, field_layers: Array, rec: Dictionary = {}) -> Array[Dictionary]:

	var updated: Array[Dictionary] = []

	var layers := _normalize_shared_field_layers(field_layers, base_px)

	for layer in layers:

		var stamped := _stamp_shared_field_layer(base_px, layer, rec)

		if not stamped.is_empty():

			updated.append(stamped)

	_refresh_combined_collision_field()

	return updated

func _clear_shared_field_cache() -> void:

	_source_collision_field.fill(Color(0.0, 0.0, 0.0, 0.0))

	_refresh_combined_collision_field()

	if _volume.is_empty():

		return

	var xz_res: int = _volume.xz_res

	var img := _resample_collision_field(_collision_field, xz_res)

	_volume["source_collision_field"] = _resample_collision_field(_source_collision_field, xz_res)

	_volume["collision_field"] = img

	_volume["collision"] = {}

func _rebuild_shared_field_cache_from_scene_voxels(scene_voxels: Dictionary) -> void:

	_clear_shared_field_cache()

	if _volume.is_empty():

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

func _stamp_occupancy_channel(base_px: Vector2i, channel: int, radius_px: int, complexity: float) -> void:

	if not _is_valid_channel(channel):

		return

	_occupancy = _stamp_scalar_image_disc(_occupancy, base_px, maxi(radius_px, 1), complexity, channel)

func _stamp_occupancy(base_px: Vector2i, profile: Array[Dictionary]) -> void:

	for entry in profile:

		var ch := int(entry.get("channel", -1))

		if not _is_valid_channel(ch):

			continue

		var complexity := SceneVoxelProfileScript.profile_entry_complexity(entry, 1.0)

		var r_px := _radius_to_px(float(entry.get("radius", 0.0)))

		_stamp_occupancy_channel(base_px, ch, r_px, complexity)

## ─── GPU Candidate Filtering ───

## Returns an Image at _base_res where R = 1.0 if candidate, 0.0 if blocked.

func _gpu_filter_candidates(profile: Array[Dictionary]) -> Image:

	var tex_occ := upload_texture_2d(_occupancy)

	var tex_out := create_rw_texture_2d(_base_res, _base_res, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT)

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

	push.encode_s32(20, _base_res)

	push.encode_s32(24, 0)  # pad0

	push.encode_s32(28, 0)  # pad1

	var groups := ceili(float(_base_res) / 32.0)

	if not _gpu_dispatch_and_sync(_pipeline_filter, [set0, set1], push, Vector3i(groups, groups, 1)):
		gc_frame()
		push_error("[SceneVoxelCommitter] Candidate filter compute list begin failed")
		var empty := Image.create(_base_res, _base_res, false, Image.FORMAT_RGBAH)
		empty.fill(Color(0.0, 0.0, 0.0, 0.0))
		return empty

	var data := _rd.texture_get_data(tex_out, 0)

	var result := Image.create_from_data(_base_res, _base_res, false, Image.FORMAT_RGBAH, data)

	gc_frame()

	return result

## ─── Deprecated Scatter Compatibility ───

## Old SceneVoxelCommitter vegetation scatter used CPU candidate selection and
## direct stamps. Runtime placement now belongs to the GPU prefilter + VPG path.

func scatter(

	_profile: Array[Dictionary],

	_scene_depth_img: Image,

	_max_height: float,

	_min_dist: float = 3.0,

	_max_scale: float = 4.0,

	_max_count: int = 500,

	_veg_type: String = "tree",

	_collision: Array[Dictionary] = []

) -> Array[Dictionary]:

	return _reject_legacy_scatter("scatter")

func scatter_from_mask(

	_profile: Array[Dictionary],

	_candidate_mask_img: Image,

	_scene_depth_img: Image,

	_max_height: float,

	_min_dist: float = 3.0,

	_max_scale: float = 4.0,

	_max_count: int = 500,

	_veg_type: String = "tree",

	_collision: Array[Dictionary] = [],

	_min_mask_strength: float = 0.01

) -> Array[Dictionary]:

	return _reject_legacy_scatter("scatter_from_mask")

func _reject_legacy_scatter(api_name: String) -> Array[Dictionary]:

	if not _legacy_scatter_warning_emitted:

		push_warning("[SceneVoxelCommitter] %s is disabled: legacy CPU vegetation scatter was removed. Use AutoObjectProbePrefilterGPU + VoxelPlacementGenerator for runtime placement." % api_name)

		_legacy_scatter_warning_emitted = true

	return []

## ─── Query & Debug ───

func get_occupancy() -> Image:

	return _occupancy

## Get the combined coarse collision field image.

func get_collision_field() -> Image:

	return _collision_field

func get_terrain_base_collision_field() -> Image:

	return _terrain_base_collision_field

func set_terrain_base_collision_field(base_collision: Image) -> void:

	_terrain_base_collision_field = _resample_collision_field(base_collision, _base_res)

	_refresh_combined_collision_field()

	if not _volume.is_empty():

		var xz_res: int = _volume.xz_res

		_volume["terrain_base_collision_field"] = _resample_collision_field(_terrain_base_collision_field, xz_res)

		_volume["collision_field"] = _resample_collision_field(_collision_field, xz_res)

		_mark_scene_voxel_full_rebuild_dirty("terrain_base_collision")

	else:

		_sv_dirty = true

## Get every placed mesh voxel_write_spec.

func get_voxel_write_specs() -> Array[Dictionary]:

	var records: Array[Dictionary] = []

	for record in _voxel_write_specs:

		var typed_record := record as Dictionary

		records.append(typed_record.duplicate(true))

	return records

func get_instance_stamp_write_specs() -> Array[Dictionary]:

	return get_voxel_write_specs()

## Get one placed mesh voxel_write_spec by id.

func get_voxel_write_spec(mesh_id: String) -> Dictionary:

	if not _voxel_write_spec_index.has(mesh_id):

		return {}

	var idx: int = _voxel_write_spec_index[mesh_id]

	var record: Dictionary = _voxel_write_specs[idx]

	return record.duplicate(true)

func get_instance_stamp_write_spec(mesh_id: String) -> Dictionary:

	return get_voxel_write_spec(mesh_id)

func get_voxel_write_spec_count() -> int:

	return _voxel_write_specs.size()

func _record_channel(record: Dictionary) -> int:
	var ch := int(record.get("channel", -1))
	if not _is_valid_channel(ch):
		return -1
	return ch

func _record_radius_px(record: Dictionary) -> int:
	if record.has("radius_px"):
		return maxi(int(record.radius_px), 1)
	if record.has("radius"):
		return _radius_to_px(float(record.radius))
	return 1

func _volume_px_from_base(base_px: Vector2i, xz_res: int) -> Vector2i:

	return Vector2i(

		clampi(int(float(base_px.x) / float(_base_res) * float(xz_res)), 0, xz_res - 1),

		clampi(int(float(base_px.y) / float(_base_res) * float(xz_res)), 0, xz_res - 1)

	)

func _volume_radius_from_base_radius(radius_px: int, xz_res: int) -> int:

	if radius_px <= 0:

		return 0

	return maxi(1, ceili(float(radius_px) / float(_base_res) * float(xz_res)))

func _next_write_tick() -> int:

	return _generation_tick if _generation_tick > _committed_tick else _committed_tick + 1

func begin_generation_tick(tick: int = -1) -> int:

	var write_tick := tick if tick >= 0 else _next_write_tick()

	_generation_tick = write_tick

	_sv_dirty = true

	return write_tick

func _slice_indices_for_channel_record(entry: Dictionary, channel: int) -> Array[int]:

	var indices: Array[int] = []

	if _volume.is_empty():

		return indices

	if entry.has("slice_indices"):

		var raw_indices: Array = entry.slice_indices

		for idx in raw_indices:

			var si := int(idx)

			if si >= 0 and si < int(_volume.total_slices):

				indices.append(si)

	if indices.is_empty():

		var meta: Array = _volume.slice_meta

		for si in range(meta.size()):

			var m: Dictionary = meta[si]

			if int(m.channel) == channel:

				indices.append(si)

	return indices

func _register_scene_voxel_tile_project_settings() -> void:
	SceneVoxelTileCodecScript.register_project_settings(SCENE_VOXEL_TILE_SIZE_SETTING, DEFAULT_SCENE_VOXEL_TILE_SIZE)

func _scene_voxel_tile_size() -> Vector3i:

	return SceneVoxelTileCodecScript.configured_size(SCENE_VOXEL_TILE_SIZE_SETTING, DEFAULT_SCENE_VOXEL_TILE_SIZE)

func _scene_voxel_tile_grid_size(tile_size: Vector3i = Vector3i.ZERO) -> Vector3i:

	var size := tile_size if tile_size.x > 0 and tile_size.y > 0 and tile_size.z > 0 else _scene_voxel_tile_size()
	return SceneVoxelTileCodecScript.tile_grid_size(grid_size, size)

func _scene_voxel_tile_coord_from_voxel(voxel_coord: Vector3i) -> Vector3i:
	return SceneVoxelTileCodecScript.tile_coord_from_voxel(voxel_coord, grid_size, _scene_voxel_tile_size())

func _scene_voxel_tile_bounds(tile_coord: Vector3i) -> Dictionary:
	return SceneVoxelTileCodecScript.tile_bounds(tile_coord, grid_size, _scene_voxel_tile_size())

func _default_scene_voxel_tile_record(tile_coord: Vector3i) -> Dictionary:

	var bounds := _scene_voxel_tile_bounds(tile_coord)

	return {

		"scene_voxel_tile_id": SceneVoxelTileCodecScript.tile_id(tile_coord),

		"tile_id": SceneVoxelTileCodecScript.tile_id(tile_coord),

		"tile_coord": tile_coord,

		"tile_size": bounds.tile_size,

		"voxel_min": bounds.voxel_min,

		"voxel_max": bounds.voxel_max,

		"base_rect": bounds.base_rect,

		"dirty_flags": {},

		"epoch": 0,

		"last_commit_tick": _committed_tick,

		"non_empty": false,

		"scene_minmax": Vector2.ZERO,

		"collision_minmax": Vector2.ZERO,

		"object_range_start": 0,

		"object_range_count": 0,

		"object_debug_range_start": 0,

		"object_debug_range_count": 0,

		"source_range_start": 0,

		"source_range_count": 0,

		"auto_object_ids_debug": [],

		"source_ids_debug": [],

		"scene_voxel_count": 0,

		"collision_cell_count": 0,

		"summary": {

			"non_empty": false,

			"scene_minmax": Vector2.ZERO,

			"collision_minmax": Vector2.ZERO,

			"scene_voxel_count": 0,

			"collision_cell_count": 0,

		},

		"dirty": false,

		"updated_this_commit": false,

	}

func _scene_voxel_tile_summary(tile: Dictionary) -> Dictionary:

	return {

		"non_empty": bool(tile.get("non_empty", false)),

		"scene_minmax": tile.get("scene_minmax", Vector2.ZERO),

		"collision_minmax": tile.get("collision_minmax", Vector2.ZERO),

		"scene_voxel_count": int(tile.get("scene_voxel_count", 0)),

		"collision_cell_count": int(tile.get("collision_cell_count", 0)),

	}

func _scene_voxel_tile_first_vector3i(record: Dictionary, keys: Array[String], fallback: Vector3i = Vector3i.ZERO) -> Vector3i:
	return SceneVoxelTileCodecScript.first_vector3i(record, keys, fallback)

func _scene_voxel_tile_has_any_key(record: Dictionary, keys: Array[String]) -> bool:
	return SceneVoxelTileCodecScript.has_any_key(record, keys)

func _scene_voxel_tile_normalized_bounds(voxel_min: Vector3i, voxel_max: Vector3i) -> Dictionary:
	return SceneVoxelTileCodecScript.normalized_bounds(voxel_min, voxel_max, grid_size)

## Iterate over all scene voxel tile coordinates within voxel bounds,
## calling [param action] with each tile's Vector3i coordinate.
func _for_each_scene_voxel_tile_in_bounds(voxel_min: Vector3i, voxel_max: Vector3i, action: Callable) -> void:
	var bounds := _scene_voxel_tile_normalized_bounds(voxel_min, voxel_max)
	var tile_min := _scene_voxel_tile_coord_from_voxel(bounds.voxel_min)
	var tile_max := _scene_voxel_tile_coord_from_voxel(Vector3i(
		bounds.voxel_max.x - 1,
		bounds.voxel_max.y - 1,
		bounds.voxel_max.z - 1
	))
	for ty in range(tile_min.y, tile_max.y + 1):
		for tz in range(tile_min.z, tile_max.z + 1):
			for tx in range(tile_min.x, tile_max.x + 1):
				action.call(Vector3i(tx, ty, tz))

func _scene_voxel_tile_bounds_from_record(record: Dictionary) -> Dictionary:

	if _scene_voxel_tile_has_any_key(record, ["voxel_min", "bounds_min", "new_voxel_min", "new_bounds_min"]) and _scene_voxel_tile_has_any_key(record, ["voxel_max", "bounds_max", "new_voxel_max", "new_bounds_max"]):

		var explicit_min := _scene_voxel_tile_first_vector3i(record, ["voxel_min", "bounds_min", "new_voxel_min", "new_bounds_min"], Vector3i.ZERO)

		var explicit_max := _scene_voxel_tile_first_vector3i(record, ["voxel_max", "bounds_max", "new_voxel_max", "new_bounds_max"], explicit_min + Vector3i.ONE)

		return _scene_voxel_tile_normalized_bounds(explicit_min, explicit_max)

	var xz_res := int(_volume.get("xz_res", grid_size.x)) if not _volume.is_empty() else maxi(grid_size.x, 1)

	var center_px := Vector2i.ZERO

	var base_px = record.get("base_pixel", null)

	if base_px is Vector2i:

		center_px = _volume_px_from_base(base_px, xz_res)

	else:

		var voxel_xz = record.get("voxel_xz", Vector2i.ZERO)

		if voxel_xz is Vector2i:

			var source_res := maxi(int(record.get("volume_xz_resolution", xz_res)), 1)

			if source_res != xz_res:

				center_px = Vector2i(

					clampi(int(float(voxel_xz.x) / float(source_res) * float(xz_res)), 0, xz_res - 1),

					clampi(int(float(voxel_xz.y) / float(source_res) * float(xz_res)), 0, xz_res - 1)

				)

			else:

				center_px = Vector2i(clampi(voxel_xz.x, 0, xz_res - 1), clampi(voxel_xz.y, 0, xz_res - 1))

	var radius_vol := _volume_radius_from_base_radius(_record_radius_px(record), xz_res)

	var min_y := 0

	var max_y := 1

	var slice_indices: Array = record.get("slice_indices", [])

	if not slice_indices.is_empty():

		min_y = maxi(grid_size.y, 1)

		max_y = 0

		for raw_slice in slice_indices:

			var slice_index := clampi(int(raw_slice), 0, maxi(grid_size.y - 1, 0))

			min_y = mini(min_y, slice_index)

			max_y = maxi(max_y, slice_index + 1)

	else:

		var slice_index := clampi(int(record.get("slice_index", 0)), 0, maxi(grid_size.y - 1, 0))

		min_y = slice_index

		max_y = slice_index + 1

	return _scene_voxel_tile_normalized_bounds(

		Vector3i(maxi(center_px.x - radius_vol, 0), min_y, maxi(center_px.y - radius_vol, 0)),

		Vector3i(mini(center_px.x + radius_vol + 1, grid_size.x), mini(max_y, grid_size.y), mini(center_px.y + radius_vol + 1, grid_size.z))

	)

func _scene_voxel_tile_gpu_autoobject_id(record: Dictionary) -> String:

	for key in ["object_id", "auto_object_id", "auto_id", "id", "record_id"]:

		if not record.has(key):

			continue

		var value := str(record.get(key, ""))

		if not value.is_empty():

			return value

	return ""

func _scene_voxel_tile_debug_object_id(source_record: Dictionary) -> String:

	for key in ["auto_object_id", "auto_id", "id", "record_id"]:

		var value := str(source_record.get(key, ""))

		if not value.is_empty():

			return value

	return ""

func _scene_voxel_tile_debug_source_id(source_record: Dictionary) -> String:

	for key in ["record_id", "id", "source_id", "auto_object_id", "auto_id"]:

		var value := str(source_record.get(key, ""))

		if not value.is_empty():

			return value

	return ""

func _append_scene_voxel_tile_debug_range(target: Array[String], values: Array) -> Vector2i:

	var start := target.size()

	for raw_value in values:

		var value := str(raw_value)

		if not value.is_empty():

			target.append(value)

	return Vector2i(start, target.size() - start)

func _append_scene_voxel_tile_debug_value(values: Array, value: String, unique: bool = true) -> void:

	if value.is_empty():

		return

	if unique and values.has(value):

		return

	values.append(value)

func _append_scene_voxel_tile_record_refs(tile: Dictionary, record: Dictionary, unique_source: bool = false) -> Dictionary:

	var debug_id := _scene_voxel_tile_debug_object_id(record)

	var ids: Array = tile.get("auto_object_ids_debug", [])

	_append_scene_voxel_tile_debug_value(ids, debug_id, true)

	tile["auto_object_ids_debug"] = ids

	var source_id := _scene_voxel_tile_debug_source_id(record)

	var source_ids: Array = tile.get("source_ids_debug", [])

	_append_scene_voxel_tile_debug_value(source_ids, source_id, unique_source)

	tile["source_ids_debug"] = source_ids

	return tile

func _append_scene_voxel_tile_record_refs_for_bounds(
	record: Dictionary,
	voxel_min: Vector3i,
	voxel_max: Vector3i,
	unique_source: bool = true
) -> void:

	if record.is_empty():

		return

	if _scene_voxel_tile_debug_object_id(record).is_empty() and _scene_voxel_tile_debug_source_id(record).is_empty():

		return

	_for_each_scene_voxel_tile_in_bounds(voxel_min, voxel_max, func(tile_coord: Vector3i):
		var tile_id := SceneVoxelTileCodecScript.tile_id(tile_coord)
		var tile: Dictionary = _scene_voxel_tiles.get(tile_id, _default_scene_voxel_tile_record(tile_coord))
		tile = _append_scene_voxel_tile_record_refs(tile, record, unique_source)
		_scene_voxel_tiles[tile_id] = tile
	)

func _rebuild_scene_voxel_tile_compact_ranges() -> void:

	_scene_voxel_tile_object_ids_debug.clear()

	_scene_voxel_tile_source_ids_debug.clear()

	_scene_voxel_tile_object_ref_rebuild_required = false

	_scene_voxel_tile_object_ref_overflow_count = 0

	_scene_voxel_tile_object_ref_overflow_tile_ids.clear()

	var tile_ids := _scene_voxel_tiles.keys()

	tile_ids.sort()

	var refs_per_tile := SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT

	var tile_grid := _scene_voxel_tile_grid_size()

	var fixed_tile_count := _scene_voxel_tile_total_tile_count(tile_grid)

	_scene_voxel_tile_fixed_object_ref_tile_count = fixed_tile_count

	_scene_voxel_tile_fixed_object_ref_slot_count = fixed_tile_count * refs_per_tile

	for tile_id in tile_ids:

		var tile: Dictionary = _scene_voxel_tiles[tile_id]

		var object_debug_range := _append_scene_voxel_tile_debug_range(
			_scene_voxel_tile_object_ids_debug,
			tile.get("auto_object_ids_debug", [])
		)

		var source_range := _append_scene_voxel_tile_debug_range(
			_scene_voxel_tile_source_ids_debug,
			tile.get("source_ids_debug", [])
		)

		tile["object_debug_range_start"] = object_debug_range.x

		tile["object_debug_range_count"] = object_debug_range.y

		var tile_coord: Vector3i = tile.get("tile_coord", Vector3i.ZERO)

		var fixed_tile_index := _scene_voxel_tile_flattened_tile_index(tile_coord, tile_grid)

		tile["object_range_start"] = fixed_tile_index * refs_per_tile

		tile["object_range_count"] = mini(object_debug_range.y, refs_per_tile)

		if object_debug_range.y > refs_per_tile:

			_scene_voxel_tile_object_ref_rebuild_required = true

			_scene_voxel_tile_object_ref_overflow_count += object_debug_range.y - refs_per_tile

			_scene_voxel_tile_object_ref_overflow_tile_ids.append(str(tile_id))

		tile["source_range_start"] = source_range.x

		tile["source_range_count"] = source_range.y

		_scene_voxel_tiles[tile_id] = tile

func _rebuild_scene_voxel_tile_source_refs() -> void:

	for tile_id in _scene_voxel_tiles.keys():

		var tile: Dictionary = _scene_voxel_tiles[tile_id]

		tile["auto_object_ids_debug"] = []

		tile["source_ids_debug"] = []

		tile["object_range_start"] = 0

		tile["object_range_count"] = 0

		tile["object_debug_range_start"] = 0

		tile["object_debug_range_count"] = 0

		tile["source_range_start"] = 0

		tile["source_range_count"] = 0

		_scene_voxel_tiles[tile_id] = tile

	for raw_metadata in _scene_source_metadata.values():

		if not raw_metadata is Dictionary:

			continue

		var source_metadata: Dictionary = raw_metadata

		var voxel_xz = source_metadata.get("voxel_xz", Vector2i.ZERO)

		if not voxel_xz is Vector2i:

			continue

		var px: Vector2i = voxel_xz

		var coord := _scene_voxel_tile_coord_from_voxel(Vector3i(
			px.x,
			int(source_metadata.get("slice_index", 0)),
			px.y
		))

		var tile_id := SceneVoxelTileCodecScript.tile_id(coord)

		var tile: Dictionary = _scene_voxel_tiles.get(tile_id, _default_scene_voxel_tile_record(coord))

		if _scene_voxel_tile_debug_source_id(source_metadata).is_empty():

			source_metadata["source_id"] = str(SceneVoxelSourceRecordScript.scene_voxel_key(int(source_metadata.get("slice_index", 0)), px))

		tile = _append_scene_voxel_tile_record_refs(tile, source_metadata, false)

		_scene_voxel_tiles[tile_id] = tile

	for record in _voxel_write_specs:

		if not record is Dictionary:

			continue

		var rec: Dictionary = record

		if rec.is_empty() or SceneVoxelTargetScript.is_target_type(str(rec.get("source_voxel_type", ""))):

			continue

		var base_px = rec.get("voxel_xz", rec.get("base_pixel", Vector2i.ZERO))

		if not base_px is Vector2i:

			continue

		var ch := _record_channel(rec)

		var slice_indices: Array[int] = []

		if ch >= 0:

			slice_indices = _slice_indices_for_channel_record(rec, ch)

		if slice_indices.is_empty():

			slice_indices.append(clampi(int(rec.get("slice_index", 0)), 0, maxi(grid_size.y - 1, 0)))

		var xz_res := int(_volume.get("xz_res", grid_size.x))

		var center_px := _volume_px_from_base(base_px, xz_res)

		var radius_vol := _volume_radius_from_base_radius(_record_radius_px(rec), xz_res)

		for slice_index in slice_indices:

			var min_voxel := Vector3i(
				maxi(center_px.x - radius_vol, 0),
				clampi(int(slice_index), 0, maxi(grid_size.y - 1, 0)),
				maxi(center_px.y - radius_vol, 0)
			)

			var max_voxel := Vector3i(
				mini(center_px.x + radius_vol + 1, grid_size.x),
				mini(clampi(int(slice_index), 0, maxi(grid_size.y - 1, 0)) + 1, grid_size.y),
				mini(center_px.y + radius_vol + 1, grid_size.z)
			)

			_for_each_scene_voxel_tile_in_bounds(min_voxel, max_voxel, func(tile_coord: Vector3i):
				var tile_id := SceneVoxelTileCodecScript.tile_id(tile_coord)
				var tile: Dictionary = _scene_voxel_tiles.get(tile_id, _default_scene_voxel_tile_record(tile_coord))
				tile = _append_scene_voxel_tile_record_refs(tile, rec, true)
				_scene_voxel_tiles[tile_id] = tile
			)

	for raw_ref in _scene_voxel_tile_gpu_autoobject_refs.values():

		if not raw_ref is Dictionary:

			continue

		var ref_record: Dictionary = raw_ref

		if bool(ref_record.get("removed", false)):

			continue

		var ref_min: Vector3i = ref_record.get("voxel_min", Vector3i.ZERO)

		var ref_max: Vector3i = ref_record.get("voxel_max", ref_min + Vector3i.ONE)

		_append_scene_voxel_tile_record_refs_for_bounds(ref_record, ref_min, ref_max, true)

	_rebuild_scene_voxel_tile_compact_ranges()

func _touch_scene_voxel_tile(tile_coord: Vector3i, dirty_flags = {}, source_record: Dictionary = {}) -> Dictionary:

	var tile_grid := _scene_voxel_tile_grid_size()

	var coord := Vector3i(

		clampi(tile_coord.x, 0, tile_grid.x - 1),

		clampi(tile_coord.y, 0, tile_grid.y - 1),

		clampi(tile_coord.z, 0, tile_grid.z - 1)

	)

	var tile_id := SceneVoxelTileCodecScript.tile_id(coord)

	var tile: Dictionary = _scene_voxel_tiles.get(tile_id, _default_scene_voxel_tile_record(coord))

	var bounds := _scene_voxel_tile_bounds(coord)

	tile["tile_coord"] = coord

	tile["tile_size"] = bounds.tile_size

	tile["voxel_min"] = bounds.voxel_min

	tile["voxel_max"] = bounds.voxel_max

	tile["base_rect"] = bounds.base_rect

	var flags: Dictionary = tile.get("dirty_flags", {})

	for key in SceneVoxelTileCodecScript.flags_from_value(dirty_flags).keys():

		flags[key] = true

	tile["dirty_flags"] = flags

	_scene_voxel_tile_epoch += 1

	tile["epoch"] = _scene_voxel_tile_epoch

	tile["write_tick"] = _generation_tick

	tile["last_commit_tick"] = _committed_tick

	tile["dirty"] = true

	tile["updated_this_commit"] = true

	tile = _append_scene_voxel_tile_record_refs(tile, source_record, true)

	_scene_voxel_tiles[tile_id] = tile

	_mark_scene_voxel_tile_staging_dirty("touch_scene_voxel_tile")

	_sv_dirty = true

	return tile

func _touch_scene_voxel_tile_from_voxel(slice_index: int, voxel_xz: Vector2i, dirty_flags = {}, source_record: Dictionary = {}) -> void:

	var coord := _scene_voxel_tile_coord_from_voxel(Vector3i(voxel_xz.x, slice_index, voxel_xz.y))

	_touch_scene_voxel_tile(coord, dirty_flags, source_record)

func _mark_legacy_sv_tiles_for_scene_voxel_tile(tile_coord: Vector3i, dirty_flags: Dictionary) -> void:

	if _volume.is_empty():

		return

	var bounds := _scene_voxel_tile_bounds(tile_coord)

	var voxel_min: Vector3i = bounds.voxel_min

	var voxel_max: Vector3i = bounds.voxel_max

	var layer_names: Array[String] = []

	if bool(dirty_flags.get("scene", false)):

		layer_names.append("scene")

	if bool(dirty_flags.get("collision", false)):

		layer_names.append("collision")

	if layer_names.is_empty():

		return

	for slice_index in range(voxel_min.y, voxel_max.y):

		for tile_z in range(int(voxel_min.z / SV_RESIDENT_TILE_SIZE), int((voxel_max.z - 1) / SV_RESIDENT_TILE_SIZE) + 1):

			for tile_x in range(int(voxel_min.x / SV_RESIDENT_TILE_SIZE), int((voxel_max.x - 1) / SV_RESIDENT_TILE_SIZE) + 1):

				var legacy_px := Vector2i(tile_x * SV_RESIDENT_TILE_SIZE, tile_z * SV_RESIDENT_TILE_SIZE)

				for layer in layer_names:

					_mark_sv_tile_dirty(slice_index, legacy_px, layer, SV_RESIDENT_TILE_SIZE, {}, false)

func _reset_scene_voxel_tile_summaries() -> void:

	for tile_id in _scene_voxel_tiles.keys():

		var tile: Dictionary = _scene_voxel_tiles[tile_id]

		tile["non_empty"] = false

		tile["scene_minmax"] = Vector2.ZERO

		tile["collision_minmax"] = Vector2.ZERO

		tile["scene_voxel_count"] = 0

		tile["collision_cell_count"] = 0

		tile["summary"] = _scene_voxel_tile_summary(tile)

		_scene_voxel_tiles[tile_id] = tile

	_mark_scene_voxel_tile_staging_dirty("summary_reset")

func _update_scene_voxel_tile_scene_summary(slice_index: int, voxel_xz: Vector2i, complexity: float) -> void:

	var coord := _scene_voxel_tile_coord_from_voxel(Vector3i(voxel_xz.x, slice_index, voxel_xz.y))

	var tile_id := SceneVoxelTileCodecScript.tile_id(coord)

	var tile: Dictionary = _scene_voxel_tiles.get(tile_id, _default_scene_voxel_tile_record(coord))

	var count := int(tile.get("scene_voxel_count", 0))

	var minmax: Vector2 = tile.get("scene_minmax", Vector2(complexity, complexity))

	if count <= 0:

		minmax = Vector2(complexity, complexity)

	else:

		minmax = Vector2(minf(minmax.x, complexity), maxf(minmax.y, complexity))

	tile["scene_voxel_count"] = count + 1

	tile["scene_minmax"] = minmax

	tile["non_empty"] = true

	tile["summary"] = _scene_voxel_tile_summary(tile)

	_scene_voxel_tiles[tile_id] = tile

	_mark_scene_voxel_tile_staging_dirty("scene_summary_rebuild")

func _update_scene_voxel_tile_collision_summary(slice_index: int, voxel_xz: Vector2i, collision_strength: float) -> void:

	var coord := _scene_voxel_tile_coord_from_voxel(Vector3i(voxel_xz.x, slice_index, voxel_xz.y))

	var tile_id := SceneVoxelTileCodecScript.tile_id(coord)

	var tile: Dictionary = _scene_voxel_tiles.get(tile_id, _default_scene_voxel_tile_record(coord))

	var count := int(tile.get("collision_cell_count", 0))

	var minmax: Vector2 = tile.get("collision_minmax", Vector2(collision_strength, collision_strength))

	if count <= 0:

		minmax = Vector2(collision_strength, collision_strength)

	else:

		minmax = Vector2(minf(minmax.x, collision_strength), maxf(minmax.y, collision_strength))

	tile["collision_cell_count"] = count + 1

	tile["collision_minmax"] = minmax

	tile["non_empty"] = true

	tile["summary"] = _scene_voxel_tile_summary(tile)

	_scene_voxel_tiles[tile_id] = tile

	_mark_scene_voxel_tile_staging_dirty("collision_summary_rebuild")

func _clear_scene_voxel_tile_dirty_flags() -> void:

	for tile_id in _scene_voxel_tiles.keys():

		var tile: Dictionary = _scene_voxel_tiles[tile_id]

		tile["dirty_flags"] = {}

		tile["dirty"] = false

		tile["updated_this_commit"] = false

		tile["last_commit_tick"] = _committed_tick

		tile["summary"] = _scene_voxel_tile_summary(tile)

		_scene_voxel_tiles[tile_id] = tile

	_mark_scene_voxel_tile_staging_dirty("dirty_clear")

func _dirty_scene_voxel_tile_snapshot() -> Dictionary:

	var result := {}

	for tile_id in _scene_voxel_tiles.keys():

		var tile: Dictionary = _scene_voxel_tiles[tile_id]

		if bool(tile.get("dirty", false)):

			result[tile_id] = tile.duplicate(true)

	return result

func _scene_voxel_in_dirty_scene_voxel_tiles(scene_voxel: Dictionary, dirty_tiles: Dictionary) -> bool:

	if dirty_tiles.is_empty():

		return false

	var voxel_xz = scene_voxel.get("voxel_xz", Vector2i(-1, -1))

	if not voxel_xz is Vector2i:

		return false

	var px: Vector2i = voxel_xz

	var slice_index := int(scene_voxel.get("slice_index", 0))

	for raw_tile in dirty_tiles.values():

		if not raw_tile is Dictionary:

			continue

		var tile: Dictionary = raw_tile

		var voxel_min: Vector3i = tile.get("voxel_min", Vector3i.ZERO)

		var voxel_max: Vector3i = tile.get("voxel_max", voxel_min + Vector3i.ONE)

		if px.x >= voxel_min.x and px.x < voxel_max.x \
			and slice_index >= voxel_min.y and slice_index < voxel_max.y \
			and px.y >= voxel_min.z and px.y < voxel_max.z:

			return true

	return false

func _dirty_scene_voxel_source_keys(current_scene_voxels: Dictionary, previous_scene_voxels: Dictionary, dirty_tiles: Dictionary) -> Dictionary:

	var keys := {}

	if dirty_tiles.is_empty():

		return keys

	for key in current_scene_voxels.keys():

		var scene_voxel = current_scene_voxels[key]

		if scene_voxel is Dictionary and _scene_voxel_in_dirty_scene_voxel_tiles(scene_voxel as Dictionary, dirty_tiles):

			keys[key] = true

	for key in previous_scene_voxels.keys():

		if keys.has(key):

			continue

		var scene_voxel = previous_scene_voxels[key]

		if scene_voxel is Dictionary and _scene_voxel_in_dirty_scene_voxel_tiles(scene_voxel as Dictionary, dirty_tiles):

			keys[key] = true

	return keys

func _dirty_scene_voxel_source_stream_keys(previous_scene_voxels: Dictionary, dirty_tiles: Dictionary) -> Dictionary:

	return _dirty_scene_voxel_source_keys(_scene_voxel_source_stream_map(), previous_scene_voxels, dirty_tiles)

func ensure_scene_voxel_tile_buffers_uploaded(force: bool = false) -> bool:

	_scene_voxel_tile_last_upload_error = ""

	if not _ensure_scene_voxel_tile_rendering_device():

		_scene_voxel_tile_gpu_ready = false

		_scene_voxel_tile_last_upload_error = "no_rendering_device"

		_scene_voxel_tile_gpu_stale_reason = "no_rendering_device"

		return false

	_rebuild_scene_voxel_tile_source_refs()

	if not force and is_scene_voxel_tile_gpu_ready():

		return true

	_scene_voxel_tile_gpu_last_reused_buffers.clear()

	var scene_field := _scene_voxel_tile_scene_field_for_upload()

	var collision_field := _scene_voxel_tile_collision_field_for_upload()

	var resident_voxel_count := maxi(scene_field.size(), collision_field.size())

	if scene_field.size() != resident_voxel_count:

		scene_field.resize(resident_voxel_count)

	if collision_field.size() != resident_voxel_count:

		collision_field.resize(resident_voxel_count)

	var packed_scene_field := _pack_scene_voxel_tile_float_field_bytes(scene_field)

	var packed_collision_field := _pack_scene_voxel_tile_float_field_bytes(collision_field)

	var tile_ids := _scene_voxel_tile_sorted_ids()

	var packed_records := _pack_scene_voxel_tile_record_bytes(tile_ids)

	var packed_summaries := _pack_scene_voxel_tile_summary_bytes(tile_ids)

	var packed_dirty_indices := _pack_scene_voxel_tile_dirty_index_bytes(tile_ids)

	var packed_object_refs := _pack_scene_voxel_tile_fixed_object_ref_hash_bytes(
		tile_ids,
		SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT
	)

	var packed_source_refs := _pack_scene_voxel_tile_ref_hash_bytes(_scene_voxel_tile_source_ids_debug)
	var packed_gpu_tile_ids := _scene_voxel_tile_gpu_tile_ids.duplicate()
	var packed_gpu_dirty_tile_ids := _scene_voxel_tile_gpu_dirty_tile_ids.duplicate()

	if not force and _update_scene_voxel_tile_dirty_ranges(
		tile_ids,
		packed_records,
		packed_summaries,
		packed_dirty_indices,
		packed_object_refs,
		packed_source_refs,
		scene_field,
		collision_field,
		packed_scene_field,
		packed_collision_field
	):

		return true

	var reusable_resident_field_buffers := _scene_voxel_tile_reusable_resident_field_buffers(
		packed_scene_field,
		scene_field.size(),
		packed_collision_field,
		collision_field.size()
	)

	_release_scene_voxel_tile_gpu_buffers(reusable_resident_field_buffers)
	_scene_voxel_tile_gpu_tile_ids = packed_gpu_tile_ids
	_scene_voxel_tile_gpu_dirty_tile_ids = packed_gpu_dirty_tile_ids

	var ok := true

	ok = _create_scene_voxel_tile_storage_buffer(
		SCENE_VOXEL_TILE_RECORD_BUFFER,
		packed_records,
		tile_ids.size(),
		SCENE_VOXEL_TILE_RECORD_STRIDE_BYTES
	) and ok

	ok = _create_scene_voxel_tile_storage_buffer(
		SCENE_VOXEL_TILE_SUMMARY_BUFFER,
		packed_summaries,
		tile_ids.size(),
		SCENE_VOXEL_TILE_SUMMARY_STRIDE_BYTES
	) and ok

	ok = _create_scene_voxel_tile_storage_buffer(
		SCENE_VOXEL_TILE_DIRTY_INDEX_BUFFER,
		packed_dirty_indices,
		_scene_voxel_tile_gpu_dirty_tile_ids.size(),
		SCENE_VOXEL_TILE_INDEX_STRIDE_BYTES
	) and ok

	ok = _create_scene_voxel_tile_storage_buffer(
		SCENE_VOXEL_TILE_OBJECT_REF_BUFFER,
		packed_object_refs,
		int(packed_object_refs.size() / SCENE_VOXEL_TILE_REF_STRIDE_BYTES),
		SCENE_VOXEL_TILE_REF_STRIDE_BYTES
	) and ok

	ok = _create_scene_voxel_tile_storage_buffer(
		SCENE_VOXEL_TILE_SOURCE_REF_BUFFER,
		packed_source_refs,
		_scene_voxel_tile_source_ids_debug.size(),
		SCENE_VOXEL_TILE_REF_STRIDE_BYTES
	) and ok

	if reusable_resident_field_buffers.has(SCENE_VOXEL_TILE_SCENE_FIELD_BUFFER):
		ok = _reuse_scene_voxel_tile_storage_buffer(
			SCENE_VOXEL_TILE_SCENE_FIELD_BUFFER,
			packed_scene_field,
			scene_field.size(),
			SCENE_VOXEL_TILE_FIELD_STRIDE_BYTES
		) and ok
	else:
		ok = _create_scene_voxel_tile_storage_buffer(
			SCENE_VOXEL_TILE_SCENE_FIELD_BUFFER,
			packed_scene_field,
			scene_field.size(),
			SCENE_VOXEL_TILE_FIELD_STRIDE_BYTES
		) and ok

	if reusable_resident_field_buffers.has(SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER):
		ok = _reuse_scene_voxel_tile_storage_buffer(
			SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER,
			packed_collision_field,
			collision_field.size(),
			SCENE_VOXEL_TILE_FIELD_STRIDE_BYTES
		) and ok
	else:
		ok = _create_scene_voxel_tile_storage_buffer(
			SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER,
			packed_collision_field,
			collision_field.size(),
			SCENE_VOXEL_TILE_FIELD_STRIDE_BYTES
		) and ok

	if not ok:

		_release_scene_voxel_tile_gpu_buffers()

		_scene_voxel_tile_gpu_ready = false

		if _scene_voxel_tile_last_upload_error.is_empty():

			_scene_voxel_tile_last_upload_error = "storage_buffer_create_failed"

		return false

	_scene_voxel_tile_gpu_ready = true

	_scene_voxel_tile_uploaded_revision = _scene_voxel_tile_staging_revision

	_scene_voxel_tile_gpu_revision += 1

	_scene_voxel_tile_gpu_last_upload_tick = _generation_tick

	_scene_voxel_tile_gpu_stale_reason = ""

	_scene_voxel_tile_last_upload_error = ""

	_scene_voxel_tile_pending_resident_upload_tiles.clear()

	_scene_voxel_tile_last_upload_mode = "full_storage_buffer_upload"

	_scene_voxel_tile_last_summary_dirty_range_update_source = "packed_summary_full_upload"

	_scene_voxel_tile_last_upload_tile_ids = tile_ids.duplicate()

	_scene_voxel_tile_last_upload_resident_voxel_count = resident_voxel_count

	_scene_voxel_tile_last_upload_range_count = 1 if resident_voxel_count > 0 else 0

	return true

func _update_scene_voxel_tile_dirty_ranges(
	tile_ids: Array[String],
	packed_records: PackedByteArray,
	_packed_summaries: PackedByteArray,
	packed_dirty_indices: PackedByteArray,
	packed_object_refs: PackedByteArray,
	packed_source_refs: PackedByteArray,
	scene_field: PackedFloat32Array,
	collision_field: PackedFloat32Array,
	packed_scene_field: PackedByteArray,
	packed_collision_field: PackedByteArray
) -> bool:

	var scoped_tile_ids := _scene_voxel_tile_dirty_upload_ids(tile_ids)

	if scoped_tile_ids.is_empty():

		return false

	if not _scene_voxel_tile_can_update_existing_buffers(tile_ids, scene_field.size(), collision_field.size()):

		return false

	if not _scene_voxel_tile_can_prove_buffer_bytes_equal(
		SCENE_VOXEL_TILE_OBJECT_REF_BUFFER,
		packed_object_refs,
		int(packed_object_refs.size() / SCENE_VOXEL_TILE_REF_STRIDE_BYTES),
		SCENE_VOXEL_TILE_REF_STRIDE_BYTES
	):

		return false

	if not _scene_voxel_tile_can_prove_buffer_bytes_equal(
		SCENE_VOXEL_TILE_SOURCE_REF_BUFFER,
		packed_source_refs,
		int(packed_source_refs.size() / SCENE_VOXEL_TILE_REF_STRIDE_BYTES),
		SCENE_VOXEL_TILE_REF_STRIDE_BYTES
	):

		return false

	var ok := true

	ok = _update_scene_voxel_tile_record_ranges(
		SCENE_VOXEL_TILE_RECORD_BUFFER,
		packed_records,
		SCENE_VOXEL_TILE_RECORD_STRIDE_BYTES,
		tile_ids,
		scoped_tile_ids
	) and ok

	ok = _update_scene_voxel_tile_whole_buffer(
		SCENE_VOXEL_TILE_DIRTY_INDEX_BUFFER,
		packed_dirty_indices,
		_scene_voxel_tile_gpu_dirty_tile_ids.size(),
		SCENE_VOXEL_TILE_INDEX_STRIDE_BYTES
	) and ok

	var scene_update := _update_scene_voxel_tile_field_ranges(
		SCENE_VOXEL_TILE_SCENE_FIELD_BUFFER,
		scene_field.size(),
		packed_scene_field,
		scoped_tile_ids
	)

	var collision_update := _update_scene_voxel_tile_field_ranges(
		SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER,
		collision_field.size(),
		packed_collision_field,
		scoped_tile_ids
	)

	ok = bool(scene_update.get("ok", false)) and ok

	ok = bool(collision_update.get("ok", false)) and ok

	if not ok:

		if _scene_voxel_tile_last_upload_error.is_empty():

			_scene_voxel_tile_last_upload_error = "dirty_range_update_failed"

		return false

	submit_and_sync()

	var summary_update := _update_scene_voxel_tile_summary_dirty_ranges_compute(
		tile_ids,
		scoped_tile_ids,
		scene_field.size(),
		collision_field.size()
	)

	ok = bool(summary_update.get("ok", false)) and ok

	if not ok:

		if _scene_voxel_tile_last_upload_error.is_empty():

			_scene_voxel_tile_last_upload_error = str(summary_update.get("reason", "dirty_summary_range_update_failed"))

		return false

	_scene_voxel_tile_gpu_ready = true

	_scene_voxel_tile_uploaded_revision = _scene_voxel_tile_staging_revision

	_scene_voxel_tile_gpu_revision += 1

	_scene_voxel_tile_gpu_last_upload_tick = _generation_tick

	_scene_voxel_tile_gpu_stale_reason = ""

	_scene_voxel_tile_last_upload_error = ""

	_scene_voxel_tile_pending_resident_upload_tiles.clear()

	_scene_voxel_tile_last_upload_mode = "dirty_scene_voxel_tile_ranges"

	_scene_voxel_tile_last_upload_tile_ids = scoped_tile_ids.duplicate()

	_scene_voxel_tile_last_upload_resident_voxel_count = maxi(
		int(scene_update.get("voxel_count", 0)),
		int(collision_update.get("voxel_count", 0))
	)

	_scene_voxel_tile_last_upload_range_count = maxi(
		int(scene_update.get("range_count", 0)),
		int(collision_update.get("range_count", 0))
	)

	return true

func _scene_voxel_tile_dirty_upload_ids(tile_ids: Array[String]) -> Array[String]:

	var dirty_lookup := {}

	var dirty_tiles := _dirty_scene_voxel_tile_snapshot()

	if dirty_tiles.is_empty() and not _scene_voxel_tile_pending_resident_upload_tiles.is_empty():

		dirty_tiles = _scene_voxel_tile_pending_resident_upload_tiles

	for raw_id in dirty_tiles.keys():

		dirty_lookup[str(raw_id)] = true

	var scoped: Array[String] = []

	for tile_id in tile_ids:

		if dirty_lookup.has(tile_id):

			scoped.append(tile_id)

	return scoped

func _scene_voxel_tile_can_update_existing_buffers(tile_ids: Array[String], scene_field_count: int, collision_field_count: int) -> bool:

	if _rd == null or _scene_voxel_tile_uploaded_revision < 0:

		return false

	if not _scene_voxel_tile_string_arrays_equal(_scene_voxel_tile_gpu_tile_ids, tile_ids):

		return false

	if int(_scene_voxel_tile_gpu_record_counts.get(SCENE_VOXEL_TILE_RECORD_BUFFER, -1)) != tile_ids.size():

		return false

	if int(_scene_voxel_tile_gpu_record_counts.get(SCENE_VOXEL_TILE_SUMMARY_BUFFER, -1)) != tile_ids.size():

		return false

	if int(_scene_voxel_tile_gpu_record_counts.get(SCENE_VOXEL_TILE_SCENE_FIELD_BUFFER, -1)) != scene_field_count:

		return false

	if int(_scene_voxel_tile_gpu_record_counts.get(SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER, -1)) != collision_field_count:

		return false

	for buffer_name in SCENE_VOXEL_TILE_GPU_BUFFER_NAMES:

		var rid: RID = _scene_voxel_tile_gpu_buffers.get(buffer_name, RID())

		if not rid.is_valid():

			return false

	return true

func _scene_voxel_tile_string_arrays_equal(a: Array[String], b: Array[String]) -> bool:

	if a.size() != b.size():

		return false

	for i in range(a.size()):

		if str(a[i]) != str(b[i]):

			return false

	return true

func _update_scene_voxel_tile_record_ranges(
	buffer_name: String,
	bytes: PackedByteArray,
	stride_bytes: int,
	tile_ids: Array[String],
	scoped_tile_ids: Array[String]
) -> bool:

	for tile_id in scoped_tile_ids:

		var tile_index := tile_ids.find(tile_id)

		if tile_index < 0:

			continue

		var offset := tile_index * stride_bytes

		var slice := bytes.slice(offset, offset + stride_bytes)

		if not _update_scene_voxel_tile_buffer_bytes(buffer_name, offset, slice):

			return false

	_scene_voxel_tile_gpu_buffer_byte_sizes[buffer_name] = bytes.size()

	_scene_voxel_tile_gpu_record_counts[buffer_name] = tile_ids.size()

	_scene_voxel_tile_gpu_strides[buffer_name] = stride_bytes

	_scene_voxel_tile_gpu_buffer_hashes[buffer_name] = 0

	return true

func _update_scene_voxel_tile_whole_buffer(buffer_name: String, bytes: PackedByteArray, record_count: int, stride_bytes: int) -> bool:

	var upload_bytes := bytes.duplicate()

	if upload_bytes.is_empty():

		upload_bytes.resize(maxi(stride_bytes, 4))

	if not _update_scene_voxel_tile_buffer_bytes(buffer_name, 0, upload_bytes):

		return false

	_scene_voxel_tile_gpu_buffer_byte_sizes[buffer_name] = bytes.size()

	_scene_voxel_tile_gpu_buffer_upload_byte_sizes[buffer_name] = maxi(
		int(_scene_voxel_tile_gpu_buffer_upload_byte_sizes.get(buffer_name, 0)),
		upload_bytes.size()
	)

	_scene_voxel_tile_gpu_record_counts[buffer_name] = record_count

	_scene_voxel_tile_gpu_strides[buffer_name] = stride_bytes

	_scene_voxel_tile_gpu_buffer_hashes[buffer_name] = _scene_voxel_tile_bytes_hash(bytes)

	return true

func _update_scene_voxel_tile_field_ranges(
	buffer_name: String,
	value_count: int,
	field_bytes: PackedByteArray,
	scoped_tile_ids: Array[String]
) -> Dictionary:

	if _volume.is_empty() or value_count <= 0 or field_bytes.is_empty():

		return {"ok": true, "voxel_count": 0, "range_count": 0}

	var xz_res := int(_volume.get("xz_res", grid_size.x))
	var expected_byte_count := value_count * SCENE_VOXEL_TILE_FIELD_STRIDE_BYTES
	if field_bytes.size() < expected_byte_count:
		return {
			"ok": false,
			"reason": "dirty_range_source_bytes_too_small",
			"voxel_count": 0,
			"range_count": 0,
			"gpu_first": true,
			"cpu_fallback": false,
			"readback_source": "none",
		}

	var voxel_count := 0

	var range_count := 0

	for tile_id in scoped_tile_ids:

		var tile: Dictionary = _scene_voxel_tiles.get(tile_id, {})

		if tile.is_empty():

			continue

		var voxel_min: Vector3i = tile.get("voxel_min", Vector3i.ZERO)

		var voxel_max: Vector3i = tile.get("voxel_max", Vector3i.ZERO)

		var row_width := maxi(voxel_max.x - voxel_min.x, 0)

		if row_width <= 0:

			continue

		for y in range(voxel_min.y, voxel_max.y):

			for z in range(voxel_min.z, voxel_max.z):

				var start_index := voxel_min.x + xz_res * (z + xz_res * y)

				if start_index < 0 or start_index + row_width > value_count:

					continue

				var start_byte := start_index * SCENE_VOXEL_TILE_FIELD_STRIDE_BYTES

				var row_byte_count := row_width * SCENE_VOXEL_TILE_FIELD_STRIDE_BYTES

				if start_byte < 0 or start_byte + row_byte_count > field_bytes.size():

					continue

				var row_bytes := field_bytes.slice(start_byte, start_byte + row_byte_count)

				if not _update_scene_voxel_tile_buffer_bytes(buffer_name, start_byte, row_bytes):

					return {
						"ok": false,
						"reason": "dirty_range_update_failed",
						"voxel_count": voxel_count,
						"range_count": range_count,
						"gpu_first": true,
						"cpu_fallback": false,
						"readback_source": "none",
					}

				voxel_count += row_width

				range_count += 1

	_scene_voxel_tile_gpu_buffer_byte_sizes[buffer_name] = expected_byte_count

	_scene_voxel_tile_gpu_record_counts[buffer_name] = value_count

	_scene_voxel_tile_gpu_strides[buffer_name] = SCENE_VOXEL_TILE_FIELD_STRIDE_BYTES

	_scene_voxel_tile_gpu_buffer_hashes[buffer_name] = 0

	return {"ok": true, "voxel_count": voxel_count, "range_count": range_count}

func _scene_voxel_tile_scoped_index_bytes(tile_ids: Array[String], scoped_tile_ids: Array[String]) -> PackedByteArray:

	var indices := PackedInt32Array()

	for tile_id in scoped_tile_ids:

		var tile_index := tile_ids.find(tile_id)

		if tile_index >= 0:

			indices.append(tile_index)

	return indices.to_byte_array()

func _update_scene_voxel_tile_summary_dirty_ranges_compute(
	tile_ids: Array[String],
	scoped_tile_ids: Array[String],
	scene_field_count: int,
	collision_field_count: int
) -> Dictionary:

	if scoped_tile_ids.is_empty():

		return {"ok": false, "reason": "empty_summary_dirty_tile_scope"}

	if not _gpu_ready or _rd == null:

		return {"ok": false, "reason": "summary_range_compute_not_ready"}

	if not _shader_update_scene_voxel_tile_summary_ranges.is_valid() or not _pipeline_update_scene_voxel_tile_summary_ranges.is_valid():

		return {"ok": false, "reason": "summary_range_compute_pipeline_not_ready"}

	var scene_buffer: RID = _scene_voxel_tile_gpu_buffers.get(SCENE_VOXEL_TILE_SCENE_FIELD_BUFFER, RID())

	var collision_buffer: RID = _scene_voxel_tile_gpu_buffers.get(SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER, RID())

	var summary_buffer: RID = _scene_voxel_tile_gpu_buffers.get(SCENE_VOXEL_TILE_SUMMARY_BUFFER, RID())

	var record_buffer: RID = _scene_voxel_tile_gpu_buffers.get(SCENE_VOXEL_TILE_RECORD_BUFFER, RID())

	if not scene_buffer.is_valid() or not collision_buffer.is_valid() or not summary_buffer.is_valid() or not record_buffer.is_valid():

		return {"ok": false, "reason": "summary_range_missing_resident_buffer"}

	var xz_res := int(_volume.get("xz_res", grid_size.x)) if not _volume.is_empty() else grid_size.x

	var total_slices := int(_volume.get("total_slices", grid_size.y)) if not _volume.is_empty() else grid_size.y

	var voxel_count := xz_res * xz_res * total_slices

	if xz_res <= 0 or total_slices <= 0 or voxel_count <= 0:

		return {"ok": false, "reason": "summary_range_invalid_volume_dims"}

	if scene_field_count < voxel_count or collision_field_count < voxel_count:

		return {"ok": false, "reason": "summary_range_field_count_mismatch"}

	var index_bytes := _scene_voxel_tile_scoped_index_bytes(tile_ids, scoped_tile_ids)

	var dirty_count := int(index_bytes.size() / SCENE_VOXEL_TILE_INDEX_STRIDE_BYTES)

	if dirty_count <= 0:

		return {"ok": false, "reason": "empty_summary_dirty_worklist"}

	var transient_dirty_index_buffer := storage_buffer_from_bytes(
		index_bytes,
		SCOPE_FRAME,
		"scene_voxel_tile_summary_dirty_indices"
	)

	if not transient_dirty_index_buffer.is_valid():

		gc_frame()

		return {"ok": false, "reason": "summary_range_dirty_index_buffer_create_failed"}

	var set0 := create_uniform_set([
		make_storage_uniform(0, scene_buffer),
		make_storage_uniform(1, collision_buffer),
		make_storage_uniform(2, summary_buffer),
		make_storage_uniform(3, transient_dirty_index_buffer),
		make_storage_uniform(4, record_buffer),
	], _shader_update_scene_voxel_tile_summary_ranges, 0, SCOPE_PASS, "update_scene_voxel_tile_summary_ranges")

	if not set0.is_valid():

		gc_frame()

		return {"ok": false, "reason": "summary_range_uniform_set_create_failed"}

	var tile_size := _scene_voxel_tile_size()

	var tile_grid := _scene_voxel_tile_grid_size(tile_size)

	var summary_stride_words := int(SCENE_VOXEL_TILE_SUMMARY_STRIDE_BYTES / 4)

	var record_stride_words := int(SCENE_VOXEL_TILE_RECORD_STRIDE_BYTES / 4)

	var push := PackedByteArray()

	push.resize(64)

	push.encode_s32(0, xz_res)
	push.encode_s32(4, total_slices)
	push.encode_s32(8, voxel_count)
	push.encode_s32(12, dirty_count)
	push.encode_s32(16, tile_size.x)
	push.encode_s32(20, tile_size.y)
	push.encode_s32(24, tile_size.z)
	push.encode_s32(28, summary_stride_words)
	push.encode_s32(32, tile_grid.x)
	push.encode_s32(36, tile_grid.y)
	push.encode_s32(40, tile_grid.z)
	push.encode_s32(44, tile_ids.size())
	push.encode_float(48, VOXEL_OCCUPIED_EPSILON)
	push.encode_float(52, SCENE_VOXEL_TILE_REDUCE_QUANT_SCALE)
	push.encode_float(56, float(record_stride_words))
	push.encode_float(60, 0.0)

	if not _gpu_dispatch_and_sync(_pipeline_update_scene_voxel_tile_summary_ranges, [set0], push, Vector3i(dirty_count, 1, 1)):

		gc_frame()

		return {"ok": false, "reason": "summary_range_compute_dispatch_failed"}

	gc_frame()

	_scene_voxel_tile_gpu_buffer_byte_sizes[SCENE_VOXEL_TILE_SUMMARY_BUFFER] = tile_ids.size() * SCENE_VOXEL_TILE_SUMMARY_STRIDE_BYTES

	_scene_voxel_tile_gpu_record_counts[SCENE_VOXEL_TILE_SUMMARY_BUFFER] = tile_ids.size()

	_scene_voxel_tile_gpu_strides[SCENE_VOXEL_TILE_SUMMARY_BUFFER] = SCENE_VOXEL_TILE_SUMMARY_STRIDE_BYTES

	_scene_voxel_tile_gpu_buffer_hashes[SCENE_VOXEL_TILE_SUMMARY_BUFFER] = 0

	_scene_voxel_tile_last_summary_dirty_range_update_source = "update_scene_voxel_tile_summary_ranges_compute"

	return {
		"ok": true,
		"reason": "ok",
		"summary_dirty_range_update_source": _scene_voxel_tile_last_summary_dirty_range_update_source,
		"dirty_tile_count": dirty_count,
		"dispatch_group_count": dirty_count,
		"gpu_dispatched": true,
		"cpu_fallback": false,
	}

func _pack_gpu_autoobject_dirty_delta_words(deltas: Array) -> PackedByteArray:
	var bytes := PackedByteArray()
	for raw_delta in deltas:
		if not raw_delta is Dictionary:
			continue
		var delta: Dictionary = raw_delta
		var base := bytes.size()
		bytes.resize(base + SCENE_VOXEL_TILE_OBJECT_REF_DIRTY_DELTA_STRIDE_BYTES)

		var object_id := _scene_voxel_tile_numeric_object_id(delta)
		var object_type := int(delta.get("object_type", 0))
		var profile_id := int(delta.get("profile_id", delta.get("runtime_profile_id", 0)))
		var generation := int(delta.get("generation", 0))
		var removed := bool(delta.get("removed", delta.get("freed", delta.get("killed", false)))) or bool(delta.has("alive") and not bool(delta.get("alive", true)))
		var alive_after := bool(delta.get("alive", not removed))
		var current_min_keys: Array[String] = ["new_voxel_min", "voxel_min", "bounds_min", "new_bounds_min"]
		var current_max_keys: Array[String] = ["new_voxel_max", "voxel_max", "bounds_max", "new_bounds_max"]
		var previous_min_keys: Array[String] = ["old_voxel_min", "previous_voxel_min", "old_bounds_min", "previous_bounds_min"]
		var previous_max_keys: Array[String] = ["old_voxel_max", "previous_voxel_max", "old_bounds_max", "previous_bounds_max"]
		var new_min := _scene_voxel_tile_first_vector3i(delta, current_min_keys, _scene_voxel_tile_first_vector3i(delta, previous_min_keys, Vector3i.ZERO))
		var new_max := _scene_voxel_tile_first_vector3i(delta, current_max_keys, _scene_voxel_tile_first_vector3i(delta, previous_max_keys, new_min + Vector3i.ONE))
		var old_min := _scene_voxel_tile_first_vector3i(delta, previous_min_keys, new_min)
		var old_max := _scene_voxel_tile_first_vector3i(delta, previous_max_keys, new_max)
		var dirty_flags := SceneVoxelTileCodecScript.flags_from_value(delta.get("dirty_flags", {"auto": true, "object_refs": true}), "")

		bytes.encode_s32(base + 0, object_id)
		bytes.encode_s32(base + 4, object_type)
		bytes.encode_s32(base + 8, profile_id)
		bytes.encode_s32(base + 12, generation)
		bytes.encode_s32(base + 16, old_min.x)
		bytes.encode_s32(base + 20, old_min.y)
		bytes.encode_s32(base + 24, old_min.z)
		bytes.encode_s32(base + 28, 1 if removed else 0)
		bytes.encode_s32(base + 32, old_max.x)
		bytes.encode_s32(base + 36, old_max.y)
		bytes.encode_s32(base + 40, old_max.z)
		bytes.encode_s32(base + 44, 1 if alive_after else 0)
		bytes.encode_s32(base + 48, new_min.x)
		bytes.encode_s32(base + 52, new_min.y)
		bytes.encode_s32(base + 56, new_min.z)
		bytes.encode_s32(base + 60, SceneVoxelTileCodecScript.flags_to_bits(dirty_flags))
		bytes.encode_s32(base + 64, new_max.x)
		bytes.encode_s32(base + 68, new_max.y)
		bytes.encode_s32(base + 72, new_max.z)
		bytes.encode_s32(base + 76, int(delta.get("flush_epoch", 0)))
	return bytes

func _pack_scene_voxel_tile_object_ref_update_push(
	dirty_delta_count: int,
	dirty_delta_capacity: int,
	object_ref_capacity: int,
	stats_capacity: int
) -> PackedByteArray:
	var tile_size := _scene_voxel_tile_size()
	var tile_grid := _scene_voxel_tile_grid_size(tile_size)
	var push := PackedByteArray()
	push.resize(80)
	push.encode_s32(0, grid_size.x)
	push.encode_s32(4, grid_size.y)
	push.encode_s32(8, grid_size.z)
	push.encode_s32(12, dirty_delta_count)
	push.encode_s32(16, tile_size.x)
	push.encode_s32(20, tile_size.y)
	push.encode_s32(24, tile_size.z)
	push.encode_s32(28, SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT)
	push.encode_s32(32, tile_grid.x)
	push.encode_s32(36, tile_grid.y)
	push.encode_s32(40, tile_grid.z)
	push.encode_s32(44, _scene_voxel_tile_total_tile_count(tile_grid))
	push.encode_s32(48, dirty_delta_capacity)
	push.encode_s32(52, object_ref_capacity)
	push.encode_s32(56, 0)
	push.encode_s32(60, stats_capacity)
	push.encode_s32(64, 0)
	push.encode_s32(68, 0)
	push.encode_s32(72, 0)
	push.encode_s32(76, 0)
	return push

func _empty_scene_voxel_tile_object_ref_update_stats(reason: String) -> Dictionary:
	return {
		"ok": false,
		"reason": reason,
		"gpu_dispatched": false,
		"stats_available": false,
		"source": "none",
		"shader": SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_NAME,
		"overflow": 0,
		"non_numeric": 0,
		"duplicate": 0,
		"touched": 0,
		"removed_slots": 0,
		"inserted_slots": 0,
		"invalid_bounds": 0,
		"skipped": 0,
	}

func _scene_voxel_tile_object_ref_update_stat(words: PackedInt32Array, index: int) -> int:
	if index < 0 or index >= words.size():
		return 0
	return maxi(int(words[index]), 0)

func _update_gpu_autoobject_object_refs_from_dirty_delta_buffer(
	dirty_delta_buffer: RID,
	dirty_delta_count: int,
	dirty_delta_capacity: int,
	dirty_delta_source: String = "borrowed_dirty_delta_buffer"
) -> Dictionary:
	if not _gpu_ready or _rd == null:
		_scene_voxel_tile_object_ref_last_update_stats = _empty_scene_voxel_tile_object_ref_update_stats("object_ref_update_gpu_not_ready")
		return _scene_voxel_tile_object_ref_last_update_stats.duplicate(true)

	if not _shader_scene_voxel_tile_object_ref_update.is_valid() or not _pipeline_scene_voxel_tile_object_ref_update.is_valid():
		_scene_voxel_tile_object_ref_last_update_stats = _empty_scene_voxel_tile_object_ref_update_stats("object_ref_update_pipeline_not_ready")
		return _scene_voxel_tile_object_ref_last_update_stats.duplicate(true)

	if dirty_delta_count <= 0:
		_scene_voxel_tile_object_ref_last_update_stats = _empty_scene_voxel_tile_object_ref_update_stats("empty_dirty_delta_batch")
		return _scene_voxel_tile_object_ref_last_update_stats.duplicate(true)

	if not dirty_delta_buffer.is_valid():
		_scene_voxel_tile_object_ref_last_update_stats = _empty_scene_voxel_tile_object_ref_update_stats("dirty_delta_buffer_not_ready")
		return _scene_voxel_tile_object_ref_last_update_stats.duplicate(true)

	var object_ref_buffer: RID = _scene_voxel_tile_gpu_buffers.get(SCENE_VOXEL_TILE_OBJECT_REF_BUFFER, RID())
	if not object_ref_buffer.is_valid():
		_scene_voxel_tile_object_ref_last_update_stats = _empty_scene_voxel_tile_object_ref_update_stats("object_ref_buffer_not_uploaded")
		return _scene_voxel_tile_object_ref_last_update_stats.duplicate(true)

	var tile_grid := _scene_voxel_tile_grid_size()
	var object_ref_capacity := _scene_voxel_tile_total_tile_count(tile_grid) * SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT
	var expected_byte_count := object_ref_capacity * SCENE_VOXEL_TILE_REF_STRIDE_BYTES
	if int(_scene_voxel_tile_gpu_buffer_byte_sizes.get(SCENE_VOXEL_TILE_OBJECT_REF_BUFFER, 0)) < expected_byte_count:
		_scene_voxel_tile_object_ref_last_update_stats = _empty_scene_voxel_tile_object_ref_update_stats("object_ref_buffer_capacity_mismatch")
		return _scene_voxel_tile_object_ref_last_update_stats.duplicate(true)

	var stats_buffer := storage_buffer_zero(
		SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_STATS_CAPACITY * SCENE_VOXEL_TILE_REF_STRIDE_BYTES,
		SCOPE_FRAME,
		"scene_voxel_tile_object_ref_update_stats"
	)
	if not stats_buffer.is_valid():
		gc_frame()
		_scene_voxel_tile_object_ref_last_update_stats = _empty_scene_voxel_tile_object_ref_update_stats("object_ref_update_buffer_create_failed")
		return _scene_voxel_tile_object_ref_last_update_stats.duplicate(true)

	var set0 := create_uniform_set([
		make_storage_uniform(0, dirty_delta_buffer),
		make_storage_uniform(1, object_ref_buffer),
		make_storage_uniform(2, stats_buffer),
	], _shader_scene_voxel_tile_object_ref_update, 0, SCOPE_PASS, "scene_voxel_tile_object_ref_update")
	if not set0.is_valid():
		gc_frame()
		_scene_voxel_tile_object_ref_last_update_stats = _empty_scene_voxel_tile_object_ref_update_stats("object_ref_update_uniform_set_create_failed")
		return _scene_voxel_tile_object_ref_last_update_stats.duplicate(true)

	var push := _pack_scene_voxel_tile_object_ref_update_push(
		dirty_delta_count,
		maxi(dirty_delta_capacity, dirty_delta_count),
		object_ref_capacity,
		SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_STATS_CAPACITY
	)
	var dispatch_groups := Vector3i(1, 1, 1)
	if not _gpu_dispatch_and_sync(_pipeline_scene_voxel_tile_object_ref_update, [set0], push, dispatch_groups):
		gc_frame()
		_scene_voxel_tile_object_ref_last_update_stats = _empty_scene_voxel_tile_object_ref_update_stats("object_ref_update_dispatch_failed")
		return _scene_voxel_tile_object_ref_last_update_stats.duplicate(true)

	var stats_bytes := _rd.buffer_get_data(
		stats_buffer,
		0,
		SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_STATS_CAPACITY * SCENE_VOXEL_TILE_REF_STRIDE_BYTES
	)
	var stats_words := stats_bytes.to_int32_array()
	var stats := {
		"ok": true,
		"reason": "ok",
		"gpu_dispatched": true,
		"stats_available": stats_words.size() >= SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_STATS_CAPACITY,
		"source": SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_NAME,
		"shader": SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_NAME,
		"dirty_delta_source": dirty_delta_source,
		"dirty_delta_count": dirty_delta_count,
		"dirty_delta_capacity": maxi(dirty_delta_capacity, dirty_delta_count),
		"dispatch_group_count": dispatch_groups.x,
		"object_ref_capacity": object_ref_capacity,
		"overflow": _scene_voxel_tile_object_ref_update_stat(stats_words, 0),
		"non_numeric": _scene_voxel_tile_object_ref_update_stat(stats_words, 1),
		"duplicate": _scene_voxel_tile_object_ref_update_stat(stats_words, 2),
		"touched": _scene_voxel_tile_object_ref_update_stat(stats_words, 3),
		"removed_slots": _scene_voxel_tile_object_ref_update_stat(stats_words, 4),
		"inserted_slots": _scene_voxel_tile_object_ref_update_stat(stats_words, 5),
		"invalid_bounds": _scene_voxel_tile_object_ref_update_stat(stats_words, 6),
		"skipped": _scene_voxel_tile_object_ref_update_stat(stats_words, 7),
	}
	_scene_voxel_tile_gpu_buffer_hashes[SCENE_VOXEL_TILE_OBJECT_REF_BUFFER] = 0
	_scene_voxel_tile_object_ref_last_update_stats = stats
	gc_frame()
	return stats.duplicate(true)

func _update_gpu_autoobject_object_refs_from_dirty_deltas(deltas: Array) -> Dictionary:
	if deltas.is_empty():
		_scene_voxel_tile_object_ref_last_update_stats = _empty_scene_voxel_tile_object_ref_update_stats("empty_dirty_delta_batch")
		return _scene_voxel_tile_object_ref_last_update_stats.duplicate(true)

	var dirty_delta_bytes := _pack_gpu_autoobject_dirty_delta_words(deltas)
	var dirty_delta_count := int(dirty_delta_bytes.size() / SCENE_VOXEL_TILE_OBJECT_REF_DIRTY_DELTA_STRIDE_BYTES)
	if dirty_delta_count <= 0:
		_scene_voxel_tile_object_ref_last_update_stats = _empty_scene_voxel_tile_object_ref_update_stats("empty_dirty_delta_words")
		return _scene_voxel_tile_object_ref_last_update_stats.duplicate(true)

	var dirty_delta_buffer := storage_buffer_from_bytes(
		dirty_delta_bytes,
		SCOPE_FRAME,
		"scene_voxel_tile_object_ref_dirty_deltas"
	)
	if not dirty_delta_buffer.is_valid():
		gc_frame()
		_scene_voxel_tile_object_ref_last_update_stats = _empty_scene_voxel_tile_object_ref_update_stats("object_ref_update_buffer_create_failed")
		return _scene_voxel_tile_object_ref_last_update_stats.duplicate(true)

	return _update_gpu_autoobject_object_refs_from_dirty_delta_buffer(
		dirty_delta_buffer,
		dirty_delta_count,
		dirty_delta_count,
		"staged_dirty_delta_buffer"
	)

func _update_scene_voxel_tile_buffer_bytes(buffer_name: String, offset: int, bytes: PackedByteArray) -> bool:

	if _rd == null or bytes.is_empty():

		return false

	var rid: RID = _scene_voxel_tile_gpu_buffers.get(buffer_name, RID())

	if not rid.is_valid():

		return false

	var upload_capacity := int(_scene_voxel_tile_gpu_buffer_upload_byte_sizes.get(buffer_name, 0))

	if offset < 0 or offset + bytes.size() > upload_capacity:

		return false

	var err := _rd.buffer_update(rid, offset, bytes.size(), bytes)

	if err != OK:

		_scene_voxel_tile_last_upload_error = "buffer_update_failed:%s" % buffer_name

		return false

	return true

func _ensure_scene_voxel_tile_rendering_device() -> bool:

	if _rd != null:

		return true

	_rd = RenderingServer.create_local_rendering_device()

	_owns_rendering_device = _rd != null

	if _rd == null:

		return false

	_disposed = false

	_on_device_ready()

	return true

func is_scene_voxel_tile_gpu_ready() -> bool:

	if _rd == null or not _scene_voxel_tile_gpu_ready:

		return false

	if _scene_voxel_tile_uploaded_revision != _scene_voxel_tile_staging_revision:

		return false

	for buffer_name in SCENE_VOXEL_TILE_GPU_BUFFER_NAMES:

		var rid: RID = _scene_voxel_tile_gpu_buffers.get(buffer_name, RID())

		if not rid.is_valid():

			return false

	return true

func get_scene_voxel_tile_gpu_buffer(buffer_name: String) -> RID:

	return _scene_voxel_tile_gpu_buffers.get(buffer_name, RID())

func get_scene_voxel_tile_gpu_buffer_summary() -> Dictionary:

	var buffers := {}

	var runtime_ready := is_scene_voxel_tile_gpu_ready()

	var buffers_uploaded := _scene_voxel_tile_uploaded_revision >= 0

	var uploaded_revision_matches_staging := _scene_voxel_tile_uploaded_revision == _scene_voxel_tile_staging_revision

	var buffers_stale := buffers_uploaded and not uploaded_revision_matches_staging

	var reason := _scene_voxel_tile_last_upload_error

	if reason.is_empty() and not runtime_ready:

		if buffers_stale:

			reason = _scene_voxel_tile_gpu_stale_reason

		elif not buffers_uploaded:

			reason = _scene_voxel_tile_gpu_stale_reason

		if reason.is_empty():

			reason = "not_uploaded"

	var gpu_upload_status := "ready"

	if not runtime_ready:

		if reason == "no_rendering_device":

			gpu_upload_status = "skip"

		elif buffers_stale:

			gpu_upload_status = "stale"

		elif not buffers_uploaded:

			gpu_upload_status = "pending"

		else:

			gpu_upload_status = "blocked"

	var skip_reason := reason if gpu_upload_status == "skip" else ""

	var blocked_debug_reason := "" if runtime_ready else reason

	for buffer_name in SCENE_VOXEL_TILE_GPU_BUFFER_NAMES:

		var rid: RID = _scene_voxel_tile_gpu_buffers.get(buffer_name, RID())

		var byte_size := int(_scene_voxel_tile_gpu_buffer_byte_sizes.get(buffer_name, 0))

		var upload_byte_size := int(_scene_voxel_tile_gpu_buffer_upload_byte_sizes.get(buffer_name, 0))

		buffers[buffer_name] = {
			"rid_valid": rid.is_valid(),
			"record_count": int(_scene_voxel_tile_gpu_record_counts.get(buffer_name, 0)),
			"stride_bytes": int(_scene_voxel_tile_gpu_strides.get(buffer_name, 0)),
			"byte_size": byte_size,
			"logical_byte_size": byte_size,
			"upload_byte_size": upload_byte_size,
			"content_hash": int(_scene_voxel_tile_gpu_buffer_hashes.get(buffer_name, 0)),
			"reuse_count": int(_scene_voxel_tile_gpu_buffer_reuse_counts.get(buffer_name, 0)),
			"reused_last_upload": _scene_voxel_tile_gpu_last_reused_buffers.has(buffer_name),
		}

	var scene_field_buffer: Dictionary = buffers.get(SCENE_VOXEL_TILE_SCENE_FIELD_BUFFER, {})

	var collision_field_buffer: Dictionary = buffers.get(SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER, {})

	var resident_field_ready := (
		runtime_ready and
		bool(scene_field_buffer.get("rid_valid", false)) and
		bool(collision_field_buffer.get("rid_valid", false))
	)

	return {
		"runtime_ready": runtime_ready,
		"gpu_first": true,
		"cpu_fallback": false,
		"gpu_upload_status": gpu_upload_status,
		"skip_reason": skip_reason,
		"blocked_debug_reason": blocked_debug_reason,
		"rendering_device_available": _rd != null,
		"read_source": "gpu_storage_buffers" if runtime_ready else "none",
		"runtime_read_source": "gpu_storage_buffers" if runtime_ready else "none",
		"resident_field_read_source": "gpu_storage_buffers" if resident_field_ready else "none",
		"scene_field_read_source": "gpu_storage_buffers" if resident_field_ready else "none",
		"collision_field_read_source": "gpu_storage_buffers" if resident_field_ready else "none",
		"staging_source": "sv_owner_command_staging",
		"readback_source": "gpu_storage_buffers" if runtime_ready else "none",
		"reason": reason,
		"tile_count": _scene_voxel_tiles.size(),
		"dirty_tile_count": _scene_voxel_tile_gpu_dirty_tile_ids.size(),
		"object_ref_count": _scene_voxel_tile_object_ids_debug.size(),
		"object_ref_debug_count": _scene_voxel_tile_object_ids_debug.size(),
		"object_ref_capacity": _scene_voxel_tile_fixed_object_ref_slot_count,
		"object_ref_tile_count": _scene_voxel_tile_fixed_object_ref_tile_count,
		"refs_per_tile": SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT,
		"object_ref_rebuild_required": _scene_voxel_tile_object_ref_rebuild_required,
		"object_ref_overflow_count": _scene_voxel_tile_object_ref_overflow_count,
		"overflow_tile_count": _scene_voxel_tile_object_ref_overflow_tile_ids.size(),
		"object_ref_overflow_tile_ids": _scene_voxel_tile_object_ref_overflow_tile_ids.duplicate(),
		"source_ref_count": _scene_voxel_tile_source_ids_debug.size(),
		"resident_field_voxel_count": int(scene_field_buffer.get("record_count", 0)),
		"scene_field_voxel_count": int(scene_field_buffer.get("record_count", 0)),
		"collision_field_voxel_count": int(collision_field_buffer.get("record_count", 0)),
		"staging_revision": _scene_voxel_tile_staging_revision,
		"uploaded_revision": _scene_voxel_tile_uploaded_revision,
		"uploaded_revision_matches_staging": uploaded_revision_matches_staging,
		"buffers_uploaded": buffers_uploaded,
		"buffers_stale": buffers_stale,
		"gpu_revision": _scene_voxel_tile_gpu_revision,
		"last_upload_tick": _scene_voxel_tile_gpu_last_upload_tick,
		"auto_upload": _scene_voxel_tile_gpu_auto_upload,
		"last_reused_buffers": _scene_voxel_tile_gpu_last_reused_buffers.duplicate(),
		"resident_field_buffers_reused": (
			_scene_voxel_tile_gpu_last_reused_buffers.has(SCENE_VOXEL_TILE_SCENE_FIELD_BUFFER) and
			_scene_voxel_tile_gpu_last_reused_buffers.has(SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER)
		),
		"last_upload_mode": _scene_voxel_tile_last_upload_mode,
		"summary_dirty_range_update_source": _scene_voxel_tile_last_summary_dirty_range_update_source,
		"last_upload_tile_ids": _scene_voxel_tile_last_upload_tile_ids.duplicate(),
		"last_upload_tile_count": _scene_voxel_tile_last_upload_tile_ids.size(),
		"last_upload_resident_voxel_count": _scene_voxel_tile_last_upload_resident_voxel_count,
		"last_upload_range_count": _scene_voxel_tile_last_upload_range_count,
		"buffers": buffers,
	}

func readback_scene_voxel_tile_debug_snapshot() -> Dictionary:

	var summary := get_scene_voxel_tile_gpu_buffer_summary()

	if not is_scene_voxel_tile_gpu_ready():

		summary["readback_snapshot"] = false

		summary["tile_record_bytes"] = PackedByteArray()

		summary["summary_record_bytes"] = PackedByteArray()

		summary["dirty_index_bytes"] = PackedByteArray()

		summary["object_ref_bytes"] = PackedByteArray()

		summary["source_ref_bytes"] = PackedByteArray()

		summary["scene_field_bytes"] = PackedByteArray()

		summary["collision_field_bytes"] = PackedByteArray()

		summary["scene_field_values"] = PackedFloat32Array()

		summary["collision_field_values"] = PackedFloat32Array()

		return summary

	var tile_record_bytes := _read_scene_voxel_tile_buffer_bytes(SCENE_VOXEL_TILE_RECORD_BUFFER)

	var summary_record_bytes := _read_scene_voxel_tile_buffer_bytes(SCENE_VOXEL_TILE_SUMMARY_BUFFER)

	var dirty_index_bytes := _read_scene_voxel_tile_buffer_bytes(SCENE_VOXEL_TILE_DIRTY_INDEX_BUFFER)

	var object_ref_bytes := _read_scene_voxel_tile_buffer_bytes(SCENE_VOXEL_TILE_OBJECT_REF_BUFFER)

	var source_ref_bytes := _read_scene_voxel_tile_buffer_bytes(SCENE_VOXEL_TILE_SOURCE_REF_BUFFER)

	var scene_field_bytes := _read_scene_voxel_tile_buffer_bytes(SCENE_VOXEL_TILE_SCENE_FIELD_BUFFER)

	var collision_field_bytes := _read_scene_voxel_tile_buffer_bytes(SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER)

	summary["readback_snapshot"] = true

	summary["tile_record_bytes"] = tile_record_bytes

	summary["summary_record_bytes"] = summary_record_bytes

	summary["dirty_index_bytes"] = dirty_index_bytes

	summary["object_ref_bytes"] = object_ref_bytes

	summary["source_ref_bytes"] = source_ref_bytes

	summary["scene_field_bytes"] = scene_field_bytes

	summary["collision_field_bytes"] = collision_field_bytes

	summary["scene_field_values"] = _decode_scene_voxel_tile_float_field_bytes(scene_field_bytes)

	summary["collision_field_values"] = _decode_scene_voxel_tile_float_field_bytes(collision_field_bytes)

	summary["tile_ids"] = _scene_voxel_tile_gpu_tile_ids.duplicate()

	summary["dirty_tile_ids"] = _decode_scene_voxel_tile_dirty_ids(dirty_index_bytes)

	summary["tile_records"] = _decode_scene_voxel_tile_records(tile_record_bytes, _scene_voxel_tile_gpu_tile_ids)

	summary["summary_records"] = _decode_scene_voxel_tile_summaries(summary_record_bytes, _scene_voxel_tile_gpu_tile_ids)

	return summary

func _publish_scene_voxel_tile_gpu_summary_to_sv() -> void:

	if _sv.is_empty():

		return

	var summary := get_scene_voxel_tile_gpu_buffer_summary()

	_sv["scene_voxel_tile_gpu_buffer_summary"] = summary

	_sv["scene_voxel_tile_runtime_read_source"] = summary.get("runtime_read_source", "none")

	_sv["scene_voxel_tile_resident_field_read_source"] = summary.get("resident_field_read_source", "none")

	_sv["scene_voxel_tile_gpu_buffers_stale"] = bool(summary.get("buffers_stale", false))

	_sv["scene_voxel_tile_gpu_uploaded_revision"] = int(summary.get("uploaded_revision", -1))

	_sv["scene_voxel_tile_gpu_staging_revision"] = int(summary.get("staging_revision", 0))

func set_scene_voxel_tile_gpu_auto_upload(enabled: bool, upload_now: bool = false) -> bool:

	_scene_voxel_tile_gpu_auto_upload = enabled

	if enabled and upload_now:

		return ensure_scene_voxel_tile_buffers_uploaded(false)

	return true

func is_scene_voxel_tile_gpu_auto_upload_enabled() -> bool:

	return _scene_voxel_tile_gpu_auto_upload

func _mark_scene_voxel_tile_staging_dirty(reason: String = "staging_changed") -> void:

	_scene_voxel_tile_staging_revision += 1

	if _scene_voxel_tile_uploaded_revision >= 0:

		_scene_voxel_tile_gpu_ready = false

		_scene_voxel_tile_gpu_stale_reason = reason

	elif _scene_voxel_tile_gpu_stale_reason.is_empty():

		_scene_voxel_tile_gpu_stale_reason = "never_uploaded"

func _maybe_auto_upload_scene_voxel_tile_buffers(reason: String = "auto_upload") -> void:

	if not _scene_voxel_tile_gpu_auto_upload:

		return

	if ensure_scene_voxel_tile_buffers_uploaded(false):

		return

	if _scene_voxel_tile_last_upload_error.is_empty():

		_scene_voxel_tile_last_upload_error = "%s_failed" % reason

func _release_scene_voxel_tile_gpu_buffers(preserve_buffer_names: Array = []) -> void:

	var preserve := {}

	for raw_name in preserve_buffer_names:

		preserve[str(raw_name)] = true

	for buffer_name in _scene_voxel_tile_gpu_buffers.keys():

		if preserve.has(str(buffer_name)):

			continue

		var rid_value = _scene_voxel_tile_gpu_buffers[buffer_name]

		if rid_value is RID:

			var rid: RID = rid_value

			if rid.is_valid():

				release_rid(rid, false)

		_scene_voxel_tile_gpu_buffers.erase(buffer_name)

		_scene_voxel_tile_gpu_buffer_byte_sizes.erase(buffer_name)

		_scene_voxel_tile_gpu_buffer_upload_byte_sizes.erase(buffer_name)

		_scene_voxel_tile_gpu_record_counts.erase(buffer_name)

		_scene_voxel_tile_gpu_strides.erase(buffer_name)

		_scene_voxel_tile_gpu_buffer_hashes.erase(buffer_name)

		if preserve.is_empty():

			_scene_voxel_tile_gpu_buffer_reuse_counts.erase(buffer_name)

	if preserve.is_empty():

		_scene_voxel_tile_gpu_tile_ids.clear()

		_scene_voxel_tile_gpu_dirty_tile_ids.clear()

		_scene_voxel_tile_gpu_buffer_reuse_counts.clear()

		_scene_voxel_tile_gpu_last_reused_buffers.clear()

		_scene_voxel_tile_last_summary_dirty_range_update_source = "none"

	_scene_voxel_tile_gpu_ready = false

	if preserve.is_empty():

		_scene_voxel_tile_uploaded_revision = -1

		_scene_voxel_tile_gpu_last_upload_tick = -1

	_scene_voxel_tile_gpu_stale_reason = "buffers_released" if preserve.is_empty() else "buffers_released_partial"

func _create_scene_voxel_tile_storage_buffer(buffer_name: String, bytes: PackedByteArray, record_count: int, stride_bytes: int) -> bool:

	if _rd == null:

		_scene_voxel_tile_last_upload_error = "no_rendering_device"

		return false

	var logical_byte_size := bytes.size()

	var upload_bytes := bytes.duplicate()

	if upload_bytes.is_empty():

		upload_bytes.resize(maxi(stride_bytes, 4))

	var rid := storage_buffer_from_bytes(upload_bytes, SCOPE_PERSISTENT, "scene_voxel_tile:%s" % buffer_name)

	if not rid.is_valid():

		_scene_voxel_tile_last_upload_error = "storage_buffer_create_failed:%s" % buffer_name

		return false

	_scene_voxel_tile_gpu_buffers[buffer_name] = rid

	_scene_voxel_tile_gpu_buffer_byte_sizes[buffer_name] = logical_byte_size

	_scene_voxel_tile_gpu_buffer_upload_byte_sizes[buffer_name] = upload_bytes.size()

	_scene_voxel_tile_gpu_record_counts[buffer_name] = record_count

	_scene_voxel_tile_gpu_strides[buffer_name] = stride_bytes

	_scene_voxel_tile_gpu_buffer_hashes[buffer_name] = _scene_voxel_tile_bytes_hash(bytes)

	return true

func _reuse_scene_voxel_tile_storage_buffer(buffer_name: String, bytes: PackedByteArray, record_count: int, stride_bytes: int) -> bool:

	if not _scene_voxel_tile_can_reuse_storage_buffer(buffer_name, bytes, record_count, stride_bytes):

		_scene_voxel_tile_last_upload_error = "storage_buffer_reuse_failed:%s" % buffer_name

		return false

	_scene_voxel_tile_gpu_buffer_byte_sizes[buffer_name] = bytes.size()

	_scene_voxel_tile_gpu_record_counts[buffer_name] = record_count

	_scene_voxel_tile_gpu_strides[buffer_name] = stride_bytes

	_scene_voxel_tile_gpu_buffer_hashes[buffer_name] = _scene_voxel_tile_bytes_hash(bytes)

	_scene_voxel_tile_gpu_buffer_reuse_counts[buffer_name] = int(_scene_voxel_tile_gpu_buffer_reuse_counts.get(buffer_name, 0)) + 1

	if not _scene_voxel_tile_gpu_last_reused_buffers.has(buffer_name):

		_scene_voxel_tile_gpu_last_reused_buffers.append(buffer_name)

	return true

func _scene_voxel_tile_reusable_resident_field_buffers(
	packed_scene_field: PackedByteArray,
	scene_field_count: int,
	packed_collision_field: PackedByteArray,
	collision_field_count: int
) -> Array[String]:

	var reusable: Array[String] = []

	if _scene_voxel_tile_can_reuse_storage_buffer(
		SCENE_VOXEL_TILE_SCENE_FIELD_BUFFER,
		packed_scene_field,
		scene_field_count,
		SCENE_VOXEL_TILE_FIELD_STRIDE_BYTES
	):

		reusable.append(SCENE_VOXEL_TILE_SCENE_FIELD_BUFFER)

	if _scene_voxel_tile_can_reuse_storage_buffer(
		SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER,
		packed_collision_field,
		collision_field_count,
		SCENE_VOXEL_TILE_FIELD_STRIDE_BYTES
	):

		reusable.append(SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER)

	return reusable

func _scene_voxel_tile_can_reuse_storage_buffer(buffer_name: String, bytes: PackedByteArray, record_count: int, stride_bytes: int) -> bool:

	var rid: RID = _scene_voxel_tile_gpu_buffers.get(buffer_name, RID())

	if not rid.is_valid():

		return false

	if int(_scene_voxel_tile_gpu_buffer_byte_sizes.get(buffer_name, -1)) != bytes.size():

		return false

	if int(_scene_voxel_tile_gpu_record_counts.get(buffer_name, -1)) != record_count:

		return false

	if int(_scene_voxel_tile_gpu_strides.get(buffer_name, -1)) != stride_bytes:

		return false

	if not _scene_voxel_tile_gpu_buffer_hashes.has(buffer_name):

		return false

	return int(_scene_voxel_tile_gpu_buffer_hashes.get(buffer_name, 0)) == _scene_voxel_tile_bytes_hash(bytes)

func _scene_voxel_tile_can_prove_buffer_bytes_equal(buffer_name: String, bytes: PackedByteArray, record_count: int, stride_bytes: int) -> bool:

	var rid: RID = _scene_voxel_tile_gpu_buffers.get(buffer_name, RID())

	if not rid.is_valid():

		return false

	if int(_scene_voxel_tile_gpu_buffer_byte_sizes.get(buffer_name, -1)) != bytes.size():

		return false

	if int(_scene_voxel_tile_gpu_buffer_upload_byte_sizes.get(buffer_name, -1)) < bytes.size():

		return false

	if int(_scene_voxel_tile_gpu_record_counts.get(buffer_name, -1)) != record_count:

		return false

	if int(_scene_voxel_tile_gpu_strides.get(buffer_name, -1)) != stride_bytes:

		return false

	if not _scene_voxel_tile_gpu_buffer_hashes.has(buffer_name):

		return false

	var stored_hash := int(_scene_voxel_tile_gpu_buffer_hashes.get(buffer_name, 0))

	if stored_hash == 0:

		return false

	return stored_hash == _scene_voxel_tile_bytes_hash(bytes)

func _scene_voxel_tile_bytes_hash(bytes: PackedByteArray) -> int:

	var h := 2166136261

	for value in bytes:

		h = (h ^ int(value)) & 0xffffffff

		h = (h * 16777619) & 0xffffffff

	return h

func _read_scene_voxel_tile_buffer_bytes(buffer_name: String) -> PackedByteArray:

	if _rd == null:

		return PackedByteArray()

	var rid: RID = _scene_voxel_tile_gpu_buffers.get(buffer_name, RID())

	if not rid.is_valid():

		return PackedByteArray()

	var byte_size := int(_scene_voxel_tile_gpu_buffer_byte_sizes.get(buffer_name, 0))

	if byte_size <= 0:

		return PackedByteArray()

	return _rd.buffer_get_data(rid, 0, byte_size)

func _scene_voxel_tile_scene_field_for_upload() -> PackedFloat32Array:

	if not _sv.is_empty():

		var sv_field := _scene_voxel_tile_packed_float_field(_sv.get("scene_field", PackedFloat32Array()))

		if sv_field.size() > 0:

			return sv_field

	if _volume.is_empty():

		return PackedFloat32Array()

	var xz_res := int(_volume.get("xz_res", _base_res))

	var total_slices := int(_volume.get("total_slices", grid_size.y))

	return _try_make_sv_scene_field_from_source_streams_gpu(xz_res, total_slices)

func _scene_voxel_tile_collision_field_for_upload() -> PackedFloat32Array:

	if not _sv.is_empty():

		var sv_field := _scene_voxel_tile_packed_float_field(_sv.get("collision_field", PackedFloat32Array()))

		if sv_field.size() > 0:

			return sv_field

	if _volume.is_empty():

		return PackedFloat32Array()

	var xz_res := int(_volume.get("xz_res", _base_res))

	var total_slices := int(_volume.get("total_slices", grid_size.y))

	var collision: Dictionary = _volume.get("collision", {})

	return _make_sv_collision_field(collision, xz_res, total_slices)

func _scene_voxel_tile_packed_float_field(value) -> PackedFloat32Array:
	return SceneVoxelTileCodecScript.packed_float_field(value)

func _pack_scene_voxel_tile_float_field_bytes(values: PackedFloat32Array) -> PackedByteArray:
	return SceneVoxelTileCodecScript.pack_float_field_bytes(values)

func _decode_scene_voxel_tile_float_field_bytes(bytes: PackedByteArray) -> PackedFloat32Array:
	return SceneVoxelTileCodecScript.decode_float_field_bytes(bytes)

func _scene_voxel_tile_sorted_ids() -> Array[String]:
	return SceneVoxelTileCodecScript.sorted_tile_ids(_scene_voxel_tiles)

func _pack_scene_voxel_tile_record_bytes(tile_ids: Array[String]) -> PackedByteArray:

	_scene_voxel_tile_gpu_tile_ids = tile_ids.duplicate()
	return SceneVoxelTileCodecScript.pack_record_bytes(tile_ids, _scene_voxel_tiles, _scene_voxel_tile_size())

func _pack_scene_voxel_tile_summary_bytes(tile_ids: Array[String]) -> PackedByteArray:
	return SceneVoxelTileCodecScript.pack_summary_bytes(tile_ids, _scene_voxel_tiles)

func _pack_scene_voxel_tile_dirty_index_bytes(tile_ids: Array[String]) -> PackedByteArray:
	_scene_voxel_tile_gpu_dirty_tile_ids.clear()
	var packed: Dictionary = SceneVoxelTileCodecScript.pack_dirty_index_bytes(tile_ids, _scene_voxel_tiles)
	var dirty_tile_ids: Array[String] = []
	for raw_id in packed.get("dirty_tile_ids", []):
		dirty_tile_ids.append(str(raw_id))
	_scene_voxel_tile_gpu_dirty_tile_ids = dirty_tile_ids
	var bytes: PackedByteArray = packed.get("bytes", PackedByteArray())
	return bytes

func _pack_scene_voxel_tile_ref_hash_bytes(values: Array[String]) -> PackedByteArray:
	return SceneVoxelTileCodecScript.pack_ref_hash_bytes(values)

func _pack_scene_voxel_tile_fixed_object_ref_hash_bytes(
	tile_ids: Array[String],
	refs_per_tile: int = SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT
) -> PackedByteArray:
	var safe_refs_per_tile := maxi(refs_per_tile, 1)
	var tile_grid := _scene_voxel_tile_grid_size()
	var tile_count := _scene_voxel_tile_total_tile_count(tile_grid)
	var bytes := PackedByteArray()
	bytes.resize(tile_count * safe_refs_per_tile * SCENE_VOXEL_TILE_REF_STRIDE_BYTES)

	for tile_id in tile_ids:
		var tile: Dictionary = _scene_voxel_tiles.get(tile_id, {})
		var tile_coord: Vector3i = tile.get("tile_coord", Vector3i.ZERO)
		var tile_index := _scene_voxel_tile_flattened_tile_index(tile_coord, tile_grid)
		if tile_index < 0 or tile_index >= tile_count:
			continue
		var refs: Array = tile.get("auto_object_ids_debug", [])
		var ref_count := mini(refs.size(), safe_refs_per_tile)
		for ref_index in range(ref_count):
			var ref_value := str(refs[ref_index])
			if ref_value.is_empty():
				continue
			var byte_offset := (tile_index * safe_refs_per_tile + ref_index) * SCENE_VOXEL_TILE_REF_STRIDE_BYTES
			bytes.encode_u32(byte_offset, SceneVoxelTileCodecScript.stable_hash(ref_value))

	return bytes

func _scene_voxel_tile_total_tile_count(tile_grid: Vector3i = Vector3i.ZERO) -> int:
	var grid := tile_grid if tile_grid.x > 0 and tile_grid.y > 0 and tile_grid.z > 0 else _scene_voxel_tile_grid_size()
	return maxi(grid.x, 0) * maxi(grid.y, 0) * maxi(grid.z, 0)

func _scene_voxel_tile_flattened_tile_index(tile_coord: Vector3i, tile_grid: Vector3i = Vector3i.ZERO) -> int:
	var grid := tile_grid if tile_grid.x > 0 and tile_grid.y > 0 and tile_grid.z > 0 else _scene_voxel_tile_grid_size()
	return tile_coord.x + grid.x * (tile_coord.z + grid.z * tile_coord.y)

func _scene_voxel_tile_numeric_object_id_from_value(value) -> int:
	if value is int:
		return int(value)
	if value is float:
		var numeric := int(value)
		return numeric if is_equal_approx(float(numeric), float(value)) else -1
	var text := str(value)
	if text.is_valid_int():
		return int(text)
	return -1

func _scene_voxel_tile_numeric_object_id(record: Dictionary) -> int:
	for key in ["object_id", "auto_object_id", "auto_id", "id", "record_id"]:
		if record.has(key):
			var numeric_id := _scene_voxel_tile_numeric_object_id_from_value(record.get(key))
			if numeric_id >= 0:
				return numeric_id
	return -1

func _pack_scene_voxel_tile_numeric_object_ref_bytes(refs_per_tile: int = SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT) -> PackedByteArray:
	var safe_refs_per_tile := maxi(refs_per_tile, 1)
	var tile_grid := _scene_voxel_tile_grid_size()
	var tile_count := _scene_voxel_tile_total_tile_count(tile_grid)
	var bytes := PackedByteArray()
	bytes.resize(tile_count * safe_refs_per_tile * SCENE_VOXEL_TILE_REF_STRIDE_BYTES)
	if tile_count <= 0:
		return bytes

	for raw_ref in _scene_voxel_tile_gpu_autoobject_refs.values():
		if not raw_ref is Dictionary:
			continue
		var ref_record: Dictionary = raw_ref
		if bool(ref_record.get("removed", false)):
			continue
		var numeric_id := _scene_voxel_tile_numeric_object_id(ref_record)
		if numeric_id < 0:
			continue
		var ref_key := numeric_id + 1
		if ref_key <= 0:
			continue

		var ref_min: Vector3i = ref_record.get("voxel_min", Vector3i.ZERO)
		var ref_max: Vector3i = ref_record.get("voxel_max", ref_min + Vector3i.ONE)
		_for_each_scene_voxel_tile_in_bounds(ref_min, ref_max, func(tile_coord: Vector3i):
			var tile_index := _scene_voxel_tile_flattened_tile_index(tile_coord, tile_grid)
			if tile_index < 0 or tile_index >= tile_count:
				return
			var slot_base := tile_index * safe_refs_per_tile
			for slot in range(safe_refs_per_tile):
				var byte_offset := (slot_base + slot) * SCENE_VOXEL_TILE_REF_STRIDE_BYTES
				if bytes.decode_u32(byte_offset) == ref_key:
					return
			for slot in range(safe_refs_per_tile):
				var byte_offset := (slot_base + slot) * SCENE_VOXEL_TILE_REF_STRIDE_BYTES
				if bytes.decode_u32(byte_offset) == 0:
					bytes.encode_u32(byte_offset, ref_key)
					return
		)

	return bytes

func _decode_scene_voxel_tile_dirty_ids(bytes: PackedByteArray) -> Array[String]:
	return SceneVoxelTileCodecScript.decode_dirty_ids(bytes, _scene_voxel_tile_gpu_tile_ids)

func _decode_scene_voxel_tile_records(bytes: PackedByteArray, tile_ids: Array[String]) -> Array[Dictionary]:
	return SceneVoxelTileCodecScript.decode_records(bytes, tile_ids)

func _decode_scene_voxel_tile_summaries(bytes: PackedByteArray, tile_ids: Array[String]) -> Array[Dictionary]:
	return SceneVoxelTileCodecScript.decode_summaries(bytes, tile_ids)

static func _stable_scene_voxel_tile_hash(value: String) -> int:
	return SceneVoxelTileCodecScript.stable_hash(value)

func _sv_tile_key(slice_index: int, voxel_px: Vector2i, layer: String = "scene", tile_size: int = SV_RESIDENT_TILE_SIZE) -> String:
	return SceneVoxelTileCodecScript.sv_tile_key(slice_index, voxel_px, layer, tile_size)

func _sv_tile_bounds(voxel_px: Vector2i, tile_size: int = SV_RESIDENT_TILE_SIZE) -> Rect2i:
	return SceneVoxelTileCodecScript.sv_tile_bounds(voxel_px, tile_size)

func _mark_sv_tile_dirty(
	slice_index: int,
	voxel_xz: Vector2i,
	layer: String = "scene",
	tile_size: int = SV_RESIDENT_TILE_SIZE,
	source_record: Dictionary = {},
	update_scene_voxel_tile: bool = true
) -> void:

	if _volume.is_empty():

		return

	var xz_res := int(_volume.get("xz_res", _base_res))

	if xz_res <= 0:

		return

	var px := Vector2i(

		clampi(voxel_xz.x, 0, xz_res - 1),

		clampi(voxel_xz.y, 0, xz_res - 1)

	)

	var key := _sv_tile_key(slice_index, px, layer, tile_size)

	_sv_dirty_tiles[key] = {

		"tile_id": key,  # dirty tile storage key

		"clip_level": 0,  # clipmap level; 0 in current SV

		"layer": layer,  # scene or collision

		"slice_index": slice_index,  # Y slice

		"tile_size": tile_size,  # voxel tile edge size

		"bounds": _sv_tile_bounds(px, tile_size),  # XZ bounds in volume pixels

		"write_tick": _generation_tick,  # generation tick that dirtied the tile

		"commit_tick": _committed_tick,  # committed SV snapshot epoch; not per-voxel provenance

		"dirty": true,  # needs resident buffer refresh

	}

	if update_scene_voxel_tile:

		_touch_scene_voxel_tile_from_voxel(slice_index, px, {layer: true}, source_record)

	_sv_dirty = true

func _clip_base_rect(rect: Rect2i) -> Rect2i:

	return rect.intersection(Rect2i(0, 0, _base_res, _base_res))

func _mark_sv_rect_dirty(base_rect: Rect2i, slice_indices: Array = [], include_collision: bool = true) -> void:

	var clipped := _clip_base_rect(base_rect)

	if clipped.size.x <= 0 or clipped.size.y <= 0:

		return

	_sv_dirty_rects.append(clipped)

	if _volume.is_empty():

		_sv_dirty = true

		return

	var xz_res := int(_volume.get("xz_res", _base_res))

	var start_px := _volume_px_from_base(clipped.position, xz_res)

	var end_base := Vector2i(

		clipped.position.x + clipped.size.x - 1,

		clipped.position.y + clipped.size.y - 1

	)

	var end_px := _volume_px_from_base(end_base, xz_res)

	var tile_min_x := int(mini(start_px.x, end_px.x) / SV_RESIDENT_TILE_SIZE)

	var tile_min_y := int(mini(start_px.y, end_px.y) / SV_RESIDENT_TILE_SIZE)

	var tile_max_x := int(maxi(start_px.x, end_px.x) / SV_RESIDENT_TILE_SIZE)

	var tile_max_y := int(maxi(start_px.y, end_px.y) / SV_RESIDENT_TILE_SIZE)

	var slices: Array[int] = []

	if slice_indices.is_empty():

		var total_slices := int(_volume.get("total_slices", 0))

		for si in range(total_slices):

			slices.append(si)

	else:

		for raw_slice in slice_indices:

			var si := int(raw_slice)

			if si >= 0 and si < int(_volume.get("total_slices", 0)):

				slices.append(si)

	for si in slices:

		for ty in range(tile_min_y, tile_max_y + 1):

			for tx in range(tile_min_x, tile_max_x + 1):

				var tile_px := Vector2i(tx * SV_RESIDENT_TILE_SIZE, ty * SV_RESIDENT_TILE_SIZE)

				_mark_sv_tile_dirty(si, tile_px, "scene")

				if include_collision:

					_mark_sv_tile_dirty(si, tile_px, "collision")

func _pack_scene_voxel_commit_source_values(source_stream: Dictionary, source_keys: Array) -> PackedFloat32Array:
	return SceneVoxelCommitPayloadScript.pack_source_values(source_stream, source_keys, SCENE_VOXEL_COMMIT_SOURCE_FLOAT_STRIDE)

func _try_blend_scene_voxel_commit_payloads_gpu(source_keys: Array, _commit_tick: int) -> PackedFloat32Array:

	if source_keys.is_empty():

		return PackedFloat32Array()

	if not _gpu_ready or _rd == null:

		return PackedFloat32Array()

	if not _pipeline_commit_scene_voxels.is_valid() or not _shader_commit_scene_voxels.is_valid():

		return PackedFloat32Array()

	var auto_values := _pack_scene_voxel_commit_source_values(_auto_scene_voxel_sources, source_keys)

	var brush_values := _pack_scene_voxel_commit_source_values(_brush_scene_voxel_sources, source_keys)

	var output_float_count := source_keys.size() * SCENE_VOXEL_COMMIT_OUTPUT_FLOAT_STRIDE

	var auto_buffer := storage_buffer_from_floats(auto_values, SCOPE_FRAME, "commit_auto_scene_voxels")

	var brush_buffer := storage_buffer_from_floats(brush_values, SCOPE_FRAME, "commit_brush_scene_voxels")

	var output_buffer := storage_buffer_zero(output_float_count * 4, SCOPE_FRAME, "commit_scene_voxel_payloads")

	if not auto_buffer.is_valid() or not brush_buffer.is_valid() or not output_buffer.is_valid():

		gc_frame()

		return PackedFloat32Array()

	var set0 := create_uniform_set([

		make_storage_uniform(0, auto_buffer),

		make_storage_uniform(1, brush_buffer),

		make_storage_uniform(2, output_buffer),

	], _shader_commit_scene_voxels, 0, SCOPE_PASS, "commit_scene_voxel_payloads")

	if not set0.is_valid():

		gc_frame()

		return PackedFloat32Array()

	var push := PackedByteArray()

	push.resize(16)

	push.encode_s32(0, source_keys.size())

	push.encode_s32(4, SCENE_VOXEL_COMMIT_SOURCE_FLOAT_STRIDE)

	push.encode_s32(8, SCENE_VOXEL_COMMIT_OUTPUT_FLOAT_STRIDE)

	var groups := dispatch_groups_1d(source_keys.size(), 64)

	if not _gpu_dispatch_and_sync(_pipeline_commit_scene_voxels, [set0], push, groups):
		gc_frame()
		return PackedFloat32Array()

	var output_bytes := _rd.buffer_get_data(output_buffer, 0, output_float_count * 4)

	var payloads := SceneVoxelCommitPayloadScript.decode_float_buffer(output_bytes, output_float_count)

	gc_frame()

	return payloads

func _commit_scene_voxel_sources_from_gpu_payloads(
	source_keys: Array,
	payloads: PackedFloat32Array,
	final_scene_voxels: Dictionary,
	commit_tick: int
) -> void:
	SceneVoxelCommitPayloadScript.commit_sources_from_payloads(
		source_keys,
		payloads,
		final_scene_voxels,
		_auto_scene_voxel_sources,
		_brush_scene_voxel_sources,
		_scene_source_metadata,
		commit_tick,
		SCENE_VOXEL_COMMIT_OUTPUT_FLOAT_STRIDE
	)

func _try_make_sv_scene_field_from_source_streams_gpu(xz_res: int, total_slices: int) -> PackedFloat32Array:
	var result := _try_make_sv_scene_field_from_source_streams_gpu_result(xz_res, total_slices)
	var field: PackedFloat32Array = result.get("field", PackedFloat32Array())
	return field

func _try_make_sv_scene_field_from_source_streams_gpu_result(
	xz_res: int,
	total_slices: int,
	output_buffer_scope: String = ""
) -> Dictionary:

	_flush_pending_scene_voxel_source_candidates()

	var voxel_count := xz_res * xz_res * total_slices

	if voxel_count <= 0:

		return {}

	if _scene_voxel_source_resolve_blocked():

		return {}

	var source_keys := _scene_voxel_source_stream_map().keys()

	source_keys.sort()

	var keep_output_buffer := not output_buffer_scope.is_empty()

	if source_keys.is_empty():

		var empty_field := PackedFloat32Array()

		empty_field.resize(voxel_count)

		var empty_result := {
			"field": empty_field,
			"voxel_count": voxel_count,
		}
		if keep_output_buffer and _gpu_ready and _rd != null:
			var empty_buffer := storage_buffer_zero(voxel_count * 4, output_buffer_scope, "blend_scene_field_out_empty")
			if empty_buffer.is_valid():
				empty_result["scene_field_buffer"] = empty_buffer
		return empty_result

	if not _gpu_ready or _rd == null or not _pipeline_blend_scene_fields.is_valid() or not _shader_blend_scene_fields.is_valid():
		push_error("[SceneVoxelCommitter] SV scene field compute resources are not ready")

		return {}

	var auto_values := _pack_scene_voxel_commit_source_values(_auto_scene_voxel_sources, source_keys)

	var brush_values := _pack_scene_voxel_commit_source_values(_brush_scene_voxel_sources, source_keys)

	var auto_buffer := storage_buffer_from_floats(auto_values, SCOPE_FRAME, "blend_auto_scene_sources")

	var brush_buffer := storage_buffer_from_floats(brush_values, SCOPE_FRAME, "blend_brush_scene_sources")

	var output_scope := output_buffer_scope if keep_output_buffer else SCOPE_FRAME

	var output_buffer := storage_buffer_zero(voxel_count * 4, output_scope, "blend_scene_field_out")

	if not auto_buffer.is_valid() or not brush_buffer.is_valid() or not output_buffer.is_valid():

		if keep_output_buffer:
			gc_scope(output_buffer_scope)

		gc_frame()

		return {}

	var set0 := create_uniform_set([

		make_storage_uniform(0, auto_buffer),

		make_storage_uniform(1, brush_buffer),

		make_storage_uniform(2, output_buffer),

	], _shader_blend_scene_fields, 0, SCOPE_PASS, "blend_scene_fields")

	if not set0.is_valid():

		if keep_output_buffer:
			gc_scope(output_buffer_scope)

		gc_frame()

		return {}

	var push := PackedByteArray()

	push.resize(16)

	push.encode_s32(0, source_keys.size())

	push.encode_s32(4, SCENE_VOXEL_COMMIT_SOURCE_FLOAT_STRIDE)

	push.encode_s32(8, xz_res)

	push.encode_s32(12, total_slices)

	var groups := dispatch_groups_1d(source_keys.size(), 64)

	if not _gpu_dispatch_and_sync(_pipeline_blend_scene_fields, [set0], push, groups):
		if keep_output_buffer:
			gc_scope(output_buffer_scope)
		gc_frame()
		return {}

	var output_bytes := _rd.buffer_get_data(output_buffer, 0, voxel_count * 4)

	var field := SceneVoxelCommitPayloadScript.decode_float_buffer(output_bytes, voxel_count)

	gc_frame()

	var result := {
		"field": field,
		"voxel_count": voxel_count,
	}
	if keep_output_buffer:
		result["scene_field_buffer"] = output_buffer
	return result

func _make_sv_collision_field(collision: Dictionary, xz_res: int, total_slices: int) -> PackedFloat32Array:

	var terrain_base_img: Image = _volume.get("terrain_base_collision_field", _resample_collision_field(_terrain_base_collision_field, xz_res))

	var field := _make_terrain_base_collision_volume_field(terrain_base_img, xz_res, total_slices)

	if collision.is_empty():

		return field

	var merged_field := _merge_sv_collision_records_gpu(field, collision, xz_res, total_slices)

	if merged_field.size() == field.size():

		return merged_field

	push_error("[SceneVoxelCommitter] SV collision record merge compute failed")

	return field

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


func _make_terrain_base_collision_volume_field(terrain_base_img: Image, xz_res: int, total_slices: int) -> PackedFloat32Array:
	if terrain_base_img == null or terrain_base_img.is_empty():
		var empty_field := PackedFloat32Array()
		empty_field.resize(maxi(xz_res * xz_res * total_slices, 0))
		return empty_field

	var gpu_field := _make_terrain_base_collision_volume_field_gpu(terrain_base_img, xz_res, total_slices)
	if gpu_field.is_empty() and xz_res * xz_res * total_slices > 0:
		push_error("[SceneVoxelCommitter] Terrain collision volume compute failed")
	return gpu_field


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


func _make_scene_voxel_source_record_template(

	record: Dictionary,

	layer: Dictionary,

	voxel_px: Vector2i,

	complexity: float

) -> Dictionary:

	var shared_fields := SharedPropertyTypeScript.normalize_shared_fields(layer, record, complexity)

	var complexity_value := float(shared_fields.complexity)

	var source_voxel := SharedPropertyTypeScript.apply_to_scene_voxel({

		"complexity": complexity_value,

		"channel": int(layer.get("channel", -1)),

		"slice_index": -1,  # filled per stamped voxel before pending source enqueue

		"voxel_xz": voxel_px,  # template XZ address; overwritten per stamped voxel

		"base_pixel": layer.get("base_pixel", record.get("base_pixel", Vector2i.ZERO)),  # original placement pixel

	}, shared_fields, complexity_value, false)

	var source_type := str(record.get("source_voxel_type", ""))

	source_voxel["type"] = source_type

	source_voxel["source_voxel_type"] = source_type  # source stream kind

	var record_id := str(record.get("record_id", record.get("id", "")))

	source_voxel["record_id"] = record_id

	source_voxel["source_id"] = str(record.get("source_id", record_id))

	source_voxel["auto_object_id"] = str(record.get("auto_object_id", record.get("auto_id", record_id)))

	var source_write_tick := int(record.get("write_tick", _generation_tick))

	var max_read_tick := maxi(source_write_tick - 1, 0)

	source_voxel["generation_tick"] = source_write_tick  # source write tick

	source_voxel["read_tick"] = clampi(int(record.get("read_tick", max_read_tick)), 0, max_read_tick)  # stable read tick

	source_voxel["write_tick"] = source_write_tick  # current write tick

	if source_type != "TargetSceneVoxel":

		var collision_layers: Array = record.get("collision", [])

		if not collision_layers.is_empty():

			source_voxel = SharedPropertyTypeScript.apply_to_scene_voxel(

				source_voxel,

				{"collision": collision_layers},

				float(source_voxel.get("complexity", 1.0))

			)

	if source_type == "BrushSceneVoxel":

		SceneVoxelBrushScript.apply_brush_fields(source_voxel, record)

	if source_type == "TargetSceneVoxel":

		SceneVoxelTargetScript.apply_target_fields(source_voxel, record)

	return source_voxel

func _clear_scene_voxel_source_streams() -> void:

	_auto_scene_voxel_sources.clear()

	_brush_scene_voxel_sources.clear()

	_pending_auto_scene_voxel_source_candidates.clear()

	_pending_brush_scene_voxel_source_candidates.clear()

	_last_scene_voxel_source_resolve_summary.clear()

	_clear_scene_voxel_source_candidate_resident_counts()

func _source_stream_current(source_type: String, key: String):

	if source_type == "BrushSceneVoxel":

		return _brush_scene_voxel_sources.get(key, {})

	return _auto_scene_voxel_sources.get(key, {})

func _store_scene_voxel_source(source_type: String, key: String, source_metadata: Dictionary) -> void:

	if source_type == "BrushSceneVoxel":

		_brush_scene_voxel_sources[key] = source_metadata

	else:

		_auto_scene_voxel_sources[key] = source_metadata

func _pending_source_stream(source_type: String) -> Dictionary:

	if source_type == "BrushSceneVoxel":

		return _pending_brush_scene_voxel_source_candidates

	return _pending_auto_scene_voxel_source_candidates

func _source_candidate_write_tick(source_voxel: Dictionary) -> int:

	return int(source_voxel.get("write_tick", -1))

func _queue_scene_voxel_source_candidate(source_type: String, key: String, source_metadata: Dictionary) -> void:

	var pending_stream := _pending_source_stream(source_type)

	var candidates: Array = pending_stream.get(key, [])

	var candidate_tick := _source_candidate_write_tick(source_metadata)

	if candidates.is_empty():

		var current = _source_stream_current(source_type, key)

		if current is Dictionary:

			var current_voxel := current as Dictionary

			if not current_voxel.is_empty() and _source_candidate_write_tick(current_voxel) == candidate_tick:

				candidates.append(current_voxel)

	elif _source_candidate_write_tick(candidates.back() as Dictionary) != candidate_tick:

		candidates.clear()

	candidates.append(source_metadata)

	pending_stream[key] = candidates

func _append_pending_source_candidate_groups(groups: Array[Dictionary], source_type: String, pending_stream: Dictionary) -> void:

	for key in pending_stream.keys():

		var raw_candidates = pending_stream[key]

		if not raw_candidates is Array or (raw_candidates as Array).is_empty():

			continue

		groups.append({

			"source_type": source_type,

			"key": str(key),

			"candidates": raw_candidates,

		})

func _pending_scene_voxel_source_candidate_groups() -> Array[Dictionary]:
	var groups: Array[Dictionary] = []
	_append_pending_source_candidate_groups(groups, "AutoSceneVoxel", _pending_auto_scene_voxel_source_candidates)
	_append_pending_source_candidate_groups(groups, "BrushSceneVoxel", _pending_brush_scene_voxel_source_candidates)
	return groups

func _flatten_source_candidate_groups(groups: Array[Dictionary]) -> Array[Dictionary]:

	var result: Array[Dictionary] = []

	for group in groups:

		var candidates: Array = group.get("candidates", [])

		for raw_candidate in candidates:

			if raw_candidate is Dictionary:

				result.append(raw_candidate as Dictionary)

	return result

func _pack_scene_voxel_source_candidate_groups(groups: Array[Dictionary]) -> Dictionary:
	var candidate_records := PackedFloat32Array()
	var ranges := PackedInt32Array()
	var candidate_count := 0

	for group in groups:

		var candidates: Array = group.get("candidates", [])

		ranges.append(candidate_count)

		ranges.append(candidates.size())

		for raw_candidate in candidates:

			if not raw_candidate is Dictionary:

				continue

			var candidate := raw_candidate as Dictionary

			candidate_records.append(float(candidate.get("priority", 0.0)))

			candidate_records.append(SceneVoxelPayloadScript.voxel_complexity(candidate))

			candidate_records.append(float(SceneVoxelSourceRecordScript.source_type_code(candidate)))

			candidate_records.append(1.0 if candidate.has("priority") else 0.0)

			candidate_count += 1

	return {
		"candidate_bytes": pack_float_array(candidate_records),
		"candidate_count": candidate_count,
		"range_bytes": pack_u32_array(ranges),
		"range_count": groups.size(),
	}

func _release_scene_voxel_source_candidate_resident_buffers() -> void:
	if _scene_voxel_source_candidate_records_buffer.is_valid():
		release_rid(_scene_voxel_source_candidate_records_buffer, false)
	if _scene_voxel_source_candidate_ranges_buffer.is_valid():
		release_rid(_scene_voxel_source_candidate_ranges_buffer, false)
	_scene_voxel_source_candidate_records_buffer = RID()
	_scene_voxel_source_candidate_records_capacity = 0
	_scene_voxel_source_candidate_records_count = 0
	_scene_voxel_source_candidate_ranges_buffer = RID()
	_scene_voxel_source_candidate_ranges_capacity = 0
	_scene_voxel_source_candidate_ranges_count = 0

func _clear_scene_voxel_source_candidate_resident_counts() -> void:
	_scene_voxel_source_candidate_records_count = 0
	_scene_voxel_source_candidate_ranges_count = 0

func _stage_scene_voxel_source_candidate_records(bytes: PackedByteArray, record_count: int) -> bool:
	if _rd == null or record_count <= 0:
		_scene_voxel_source_candidate_records_count = 0
		return false
	var required_capacity := maxi(record_count, 1)
	var upload_byte_count := maxi(
		required_capacity * SCENE_VOXEL_SOURCE_CANDIDATE_STRIDE_BYTES,
		maxi(bytes.size(), 4)
	)
	var upload_bytes := bytes.duplicate()
	if upload_bytes.size() < upload_byte_count:
		upload_bytes.resize(upload_byte_count)
	if not _scene_voxel_source_candidate_records_buffer.is_valid() or _scene_voxel_source_candidate_records_capacity < required_capacity:
		if _scene_voxel_source_candidate_records_buffer.is_valid():
			release_rid(_scene_voxel_source_candidate_records_buffer, false)
		_scene_voxel_source_candidate_records_buffer = storage_buffer_from_bytes(
			upload_bytes,
			SCOPE_PERSISTENT,
			"scene_voxel_source_candidate_records"
		)
		if not _scene_voxel_source_candidate_records_buffer.is_valid():
			_scene_voxel_source_candidate_records_capacity = 0
			_scene_voxel_source_candidate_records_count = 0
			return false
		_scene_voxel_source_candidate_records_capacity = required_capacity
	else:
		var buffer_byte_capacity := maxi(
			_scene_voxel_source_candidate_records_capacity * SCENE_VOXEL_SOURCE_CANDIDATE_STRIDE_BYTES,
			4
		)
		if upload_bytes.size() < buffer_byte_capacity:
			upload_bytes.resize(buffer_byte_capacity)
		var err := _rd.buffer_update(
			_scene_voxel_source_candidate_records_buffer,
			0,
			upload_bytes.size(),
			upload_bytes
		)
		if err != OK:
			_scene_voxel_source_candidate_records_count = 0
			return false
	_scene_voxel_source_candidate_records_count = record_count
	return true

func _stage_scene_voxel_source_candidate_ranges(bytes: PackedByteArray, range_count: int) -> bool:
	if _rd == null or range_count <= 0:
		_scene_voxel_source_candidate_ranges_count = 0
		return false
	var required_capacity := maxi(range_count, 1)
	var upload_byte_count := maxi(
		required_capacity * SCENE_VOXEL_SOURCE_CANDIDATE_RANGE_STRIDE_BYTES,
		maxi(bytes.size(), 4)
	)
	var upload_bytes := bytes.duplicate()
	if upload_bytes.size() < upload_byte_count:
		upload_bytes.resize(upload_byte_count)
	if not _scene_voxel_source_candidate_ranges_buffer.is_valid() or _scene_voxel_source_candidate_ranges_capacity < required_capacity:
		if _scene_voxel_source_candidate_ranges_buffer.is_valid():
			release_rid(_scene_voxel_source_candidate_ranges_buffer, false)
		_scene_voxel_source_candidate_ranges_buffer = storage_buffer_from_bytes(
			upload_bytes,
			SCOPE_PERSISTENT,
			"scene_voxel_source_candidate_ranges"
		)
		if not _scene_voxel_source_candidate_ranges_buffer.is_valid():
			_scene_voxel_source_candidate_ranges_capacity = 0
			_scene_voxel_source_candidate_ranges_count = 0
			return false
		_scene_voxel_source_candidate_ranges_capacity = required_capacity
	else:
		var buffer_byte_capacity := maxi(
			_scene_voxel_source_candidate_ranges_capacity * SCENE_VOXEL_SOURCE_CANDIDATE_RANGE_STRIDE_BYTES,
			4
		)
		if upload_bytes.size() < buffer_byte_capacity:
			upload_bytes.resize(buffer_byte_capacity)
		var err := _rd.buffer_update(
			_scene_voxel_source_candidate_ranges_buffer,
			0,
			upload_bytes.size(),
			upload_bytes
		)
		if err != OK:
			_scene_voxel_source_candidate_ranges_count = 0
			return false
	_scene_voxel_source_candidate_ranges_count = range_count
	return true

func _stage_scene_voxel_source_candidate_resident_buffers(
	candidate_bytes: PackedByteArray,
	candidate_count: int,
	range_bytes: PackedByteArray,
	range_count: int
) -> bool:
	if not _stage_scene_voxel_source_candidate_records(candidate_bytes, candidate_count):
		_clear_scene_voxel_source_candidate_resident_counts()
		return false
	if not _stage_scene_voxel_source_candidate_ranges(range_bytes, range_count):
		_clear_scene_voxel_source_candidate_resident_counts()
		return false
	_scene_voxel_source_candidate_staging_epoch += 1
	return true

func stage_pending_scene_voxel_source_candidates_to_resident_buffers() -> Dictionary:
	var groups := _pending_scene_voxel_source_candidate_groups()
	var report := {
		"ok": true,
		"reason": "ok" if not groups.is_empty() else "no_pending_source_candidates",
		"gpu_first": true,
		"cpu_fallback": false,
		"source_write_handoff_mode": "cpu_batch_isws_pending_source_candidate_bridge",
		"cpu_pending_source_candidate_bridge": true,
		"pending_source_candidate_flush_api": "stage_pending_scene_voxel_source_candidates_to_resident_buffers;blend_scene_voxels->_flush_pending_scene_voxel_source_candidates",
		"source_candidate_resolve_api": "resolve_scene_voxel_sources.glsl",
		"candidate_group_count": groups.size(),
		"candidate_count": 0,
		"runtime_read_source": "none",
		"resident_gpu_allocator_writeback": false,
		"resident_gpu_allocator_writeback_mode": "none",
	}
	report.merge(_scene_voxel_source_candidate_cpu_bridge_diagnostics("none", 0, false), true)

	if groups.is_empty():
		var resident_current := (
			_scene_voxel_source_candidate_records_buffer.is_valid()
			and _scene_voxel_source_candidate_ranges_buffer.is_valid()
			and _scene_voxel_source_candidate_records_count > 0
			and _scene_voxel_source_candidate_ranges_count > 0
		)
		report.merge(_scene_voxel_source_candidate_resident_diagnostics(resident_current), true)
		return report

	if not _gpu_ready or _rd == null:
		_init_gpu()

	if not _gpu_ready or _rd == null:
		report["ok"] = false
		report["reason"] = "missing_rendering_device"
		report.merge(_scene_voxel_source_candidate_resident_diagnostics(false), true)
		return report

	var packed := _pack_scene_voxel_source_candidate_groups(groups)
	var candidate_count := int(packed.get("candidate_count", 0))
	var range_count := int(packed.get("range_count", 0))
	report["candidate_count"] = candidate_count
	report["candidate_group_count"] = range_count

	if candidate_count <= 0 or range_count <= 0:
		report["ok"] = false
		report["reason"] = "empty_source_candidate_records"
		report.merge(_scene_voxel_source_candidate_resident_diagnostics(false), true)
		return report

	var candidate_bytes: PackedByteArray = packed.get("candidate_bytes", PackedByteArray())
	var range_bytes: PackedByteArray = packed.get("range_bytes", PackedByteArray())
	var staged := _stage_scene_voxel_source_candidate_resident_buffers(
		candidate_bytes,
		candidate_count,
		range_bytes,
		range_count
	)
	if not staged:
		report["ok"] = false
		report["reason"] = "source_candidate_resident_staging_failed"

	report.merge(_scene_voxel_source_candidate_resident_diagnostics(staged), true)
	return report

func _scene_voxel_source_candidate_resident_diagnostics(staged: bool) -> Dictionary:
	var resident_ready := (
		staged
		and _scene_voxel_source_candidate_records_buffer.is_valid()
		and _scene_voxel_source_candidate_ranges_buffer.is_valid()
		and _scene_voxel_source_candidate_records_count > 0
		and _scene_voxel_source_candidate_ranges_count > 0
	)
	if not resident_ready:
		return {
			"resident_source_write_buffer": false,
			"resident_source_write_buffer_owner": "none",
			"resident_source_write_buffer_rid": "none",
			"resident_source_write_buffer_lifetime": "none",
			"resident_source_write_buffer_stride_bytes": 0,
			"resident_source_write_buffer_range_count": 0,
			"resident_source_candidate_buffer_rid": "none",
			"resident_source_candidate_buffer_stride_bytes": 0,
			"resident_source_candidate_buffer_capacity": 0,
			"resident_source_candidate_buffer_count": 0,
			"resident_source_range_buffer_rid": "none",
			"resident_source_range_buffer_stride_bytes": 0,
			"resident_source_range_buffer_capacity": 0,
			"resident_source_range_buffer_count": 0,
			"resident_source_candidate_staging_epoch": _scene_voxel_source_candidate_staging_epoch,
		}
	return {
		"resident_source_write_buffer": true,
		"resident_source_write_buffer_owner": "SceneVoxelCommitter",
		"resident_source_write_buffer_rid": str(_scene_voxel_source_candidate_records_buffer),
		"resident_source_write_buffer_lifetime": "persistent_candidate_range_staging",
		"resident_source_write_buffer_stride_bytes": SCENE_VOXEL_SOURCE_CANDIDATE_STRIDE_BYTES,
		"resident_source_write_buffer_range_count": _scene_voxel_source_candidate_ranges_count,
		"resident_source_candidate_buffer_rid": str(_scene_voxel_source_candidate_records_buffer),
		"resident_source_candidate_buffer_stride_bytes": SCENE_VOXEL_SOURCE_CANDIDATE_STRIDE_BYTES,
		"resident_source_candidate_buffer_capacity": _scene_voxel_source_candidate_records_capacity,
		"resident_source_candidate_buffer_count": _scene_voxel_source_candidate_records_count,
		"resident_source_range_buffer_rid": str(_scene_voxel_source_candidate_ranges_buffer),
		"resident_source_range_buffer_stride_bytes": SCENE_VOXEL_SOURCE_CANDIDATE_RANGE_STRIDE_BYTES,
		"resident_source_range_buffer_capacity": _scene_voxel_source_candidate_ranges_capacity,
		"resident_source_range_buffer_count": _scene_voxel_source_candidate_ranges_count,
		"resident_source_candidate_staging_epoch": _scene_voxel_source_candidate_staging_epoch,
	}

func _scene_voxel_source_candidate_cpu_bridge_diagnostics(
	winner_readback_source: String,
	winner_readback_count: int,
	cpu_apply_bridge: bool
) -> Dictionary:
	var winner_readback_stride := 4 if winner_readback_source != "none" and not winner_readback_source.is_empty() else 0
	return {
		"source_candidate_winner_readback_source": winner_readback_source,
		"source_candidate_winner_readback_count": maxi(winner_readback_count, 0),
		"source_candidate_winner_readback_stride_bytes": winner_readback_stride,
		"source_candidate_cpu_apply_bridge": cpu_apply_bridge,
		"source_candidate_cpu_apply_bridge_target": "_auto_scene_voxel_sources/_brush_scene_voxel_sources" if cpu_apply_bridge else "none",
		"final_source_stream_resident": false,
		"final_source_stream_resident_source": "none",
	}

func _scene_voxel_source_bridge_diagnostics_from_summary(summary: Dictionary) -> Dictionary:
	return {
		"source_candidate_winner_readback_source": str(summary.get("source_candidate_winner_readback_source", "none")),
		"source_candidate_winner_readback_count": int(summary.get("source_candidate_winner_readback_count", 0)),
		"source_candidate_winner_readback_stride_bytes": int(summary.get("source_candidate_winner_readback_stride_bytes", 0)),
		"source_candidate_cpu_apply_bridge": bool(summary.get("source_candidate_cpu_apply_bridge", false)),
		"source_candidate_cpu_apply_bridge_target": str(summary.get("source_candidate_cpu_apply_bridge_target", "none")),
		"final_source_stream_resident": bool(summary.get("final_source_stream_resident", false)),
		"final_source_stream_resident_source": str(summary.get("final_source_stream_resident_source", "none")),
	}

func _try_resolve_scene_voxel_source_candidates_gpu(groups: Array[Dictionary]) -> PackedInt32Array:

	if groups.is_empty():

		return PackedInt32Array()

	if not _gpu_ready or _rd == null:
		_init_gpu()

	if not _gpu_ready or _rd == null:

		return PackedInt32Array()

	if not _pipeline_resolve_scene_sources.is_valid() or not _shader_resolve_scene_sources.is_valid():

		return PackedInt32Array()

	var packed := _pack_scene_voxel_source_candidate_groups(groups)
	var candidate_count := int(packed.get("candidate_count", 0))
	var range_count := int(packed.get("range_count", groups.size()))

	if candidate_count <= 0:

		return PackedInt32Array()

	var candidate_bytes: PackedByteArray = packed.get("candidate_bytes", PackedByteArray())
	var range_bytes: PackedByteArray = packed.get("range_bytes", PackedByteArray())

	if not _stage_scene_voxel_source_candidate_resident_buffers(candidate_bytes, candidate_count, range_bytes, range_count):

		return PackedInt32Array()

	var candidate_buffer := _scene_voxel_source_candidate_records_buffer

	var ranges_buffer := _scene_voxel_source_candidate_ranges_buffer

	var winners_buffer := storage_buffer_zero(groups.size() * 4, SCOPE_FRAME, "resolve_source_winner_indices")

	if not candidate_buffer.is_valid() or not ranges_buffer.is_valid() or not winners_buffer.is_valid():

		gc_frame()

		return PackedInt32Array()

	var set0 := create_uniform_set([

		make_storage_uniform(0, candidate_buffer),

		make_storage_uniform(1, ranges_buffer),

		make_storage_uniform(2, winners_buffer),

	], _shader_resolve_scene_sources, 0, SCOPE_PASS, "resolve_scene_sources")

	if not set0.is_valid():

		gc_frame()

		return PackedInt32Array()

	var push := PackedByteArray()

	push.resize(16)

	push.encode_s32(0, groups.size())

	var dispatch_groups := dispatch_groups_1d(groups.size(), 64)

	if not _gpu_dispatch_and_sync(_pipeline_resolve_scene_sources, [set0], push, dispatch_groups):
		gc_frame()
		return PackedInt32Array()

	var output_bytes := _rd.buffer_get_data(winners_buffer, 0, groups.size() * 4)
	if output_bytes.size() < groups.size() * 4:
		gc_frame()
		return PackedInt32Array()

	var winners := PackedInt32Array()
	winners.resize(groups.size())
	for group_index in range(groups.size()):
		var offset := group_index * 4
		winners[group_index] = int(output_bytes.decode_u32(offset)) if offset + 4 <= output_bytes.size() else 0

	gc_frame()

	return winners

func _flush_pending_scene_voxel_source_candidates() -> void:

	var groups := _pending_scene_voxel_source_candidate_groups()

	if groups.is_empty():

		return

	var flattened_candidates := _flatten_source_candidate_groups(groups)

	var staging_epoch_before := _scene_voxel_source_candidate_staging_epoch

	var winners := _try_resolve_scene_voxel_source_candidates_gpu(groups)

	var source_candidate_staged := _scene_voxel_source_candidate_staging_epoch > staging_epoch_before

	var resolve_mode := "compute_winner_indices"

	if winners.size() != groups.size():
		_last_scene_voxel_source_resolve_summary = {
			"mode": "compute_dispatch_failed",
			"gpu_dispatched": false,
			"candidate_group_count": groups.size(),
			"candidate_count": flattened_candidates.size(),
			"cpu_runtime_fallback": false,
		}
		_last_scene_voxel_source_resolve_summary.merge(
			_scene_voxel_source_candidate_resident_diagnostics(source_candidate_staged),
			true
		)
		_last_scene_voxel_source_resolve_summary.merge(
			_scene_voxel_source_candidate_cpu_bridge_diagnostics("none", 0, false),
			true
		)
		push_error("[SceneVoxelCommitter] GPU source candidate resolve dispatch failed")
		return

	for group_index in range(groups.size()):

		var winner_index := int(winners[group_index])

		if winner_index < 0 or winner_index >= flattened_candidates.size():

			continue

		var group := groups[group_index]

		_store_scene_voxel_source(

			str(group.get("source_type", "AutoSceneVoxel")),

			str(group.get("key", "")),

			flattened_candidates[winner_index]

		)

	_last_scene_voxel_source_resolve_summary = {

		"mode": resolve_mode,

		"gpu_dispatched": resolve_mode == "compute_winner_indices",

		"candidate_group_count": groups.size(),

		"candidate_count": flattened_candidates.size(),

		"cpu_runtime_fallback": false,

	}
	_last_scene_voxel_source_resolve_summary.merge(
		_scene_voxel_source_candidate_resident_diagnostics(source_candidate_staged),
		true
	)
	_last_scene_voxel_source_resolve_summary.merge(
		_scene_voxel_source_candidate_cpu_bridge_diagnostics(
			"resolve_source_winner_indices_buffer_get_data",
			winners.size(),
			true
		),
		true
	)

	_pending_auto_scene_voxel_source_candidates.clear()

	_pending_brush_scene_voxel_source_candidates.clear()

func _scene_voxel_source_resolve_blocked() -> bool:

	return str(_last_scene_voxel_source_resolve_summary.get("mode", "")) == "compute_dispatch_failed"

func _scene_voxel_source_stream_map() -> Dictionary:

	_flush_pending_scene_voxel_source_candidates()

	var result := {}

	for key in _auto_scene_voxel_sources.keys():

		result[key] = _auto_scene_voxel_sources[key]

	for key in _brush_scene_voxel_sources.keys():

		result[key] = _brush_scene_voxel_sources[key]

	return result

func _enqueue_scene_voxel_source_record(source_voxel: Dictionary, source_tick: int = -1) -> void:

	if source_voxel.is_empty():

		return

	var source_type := str(source_voxel.get("source_voxel_type", source_voxel.get("type", "AutoSceneVoxel")))

	if SceneVoxelTargetScript.is_target_type(source_type):

		return

	var slice_index := int(source_voxel.get("slice_index", -1))

	var voxel_xz = source_voxel.get("voxel_xz", Vector2i(-1, -1))

	if slice_index < 0 or not voxel_xz is Vector2i:

		return

	var key := SceneVoxelSourceRecordScript.scene_voxel_key(slice_index, voxel_xz)

	if SceneVoxelBrushScript.is_brush_type(source_type) and not SceneVoxelSourceRecordScript.source_modifies_key(source_voxel, key):

		return

	var write_tick := int(source_voxel.get("write_tick", _generation_tick))

	var resolved_write_tick := source_tick if source_tick >= 0 else write_tick

	var source_metadata := source_voxel.duplicate(true)

	source_metadata.erase("commit_tick")
	source_metadata["write_tick"] = resolved_write_tick

	_queue_scene_voxel_source_candidate(source_type, key, source_metadata)

	_mark_sv_tile_dirty(slice_index, voxel_xz, "scene", SV_RESIDENT_TILE_SIZE, source_metadata)

func _mark_target_guidance_dirty(record: Dictionary) -> void:

	var bounds := _scene_voxel_tile_bounds_from_record(record)

	mark_scene_voxel_tile_bounds_dirty(bounds.voxel_min, bounds.voxel_max, SceneVoxelTargetScript.target_dirty_flags(), {})

func _tile_coord_from_summary_index(index: int, tile_grid: Vector3i) -> Vector3i:
	var safe_x := maxi(tile_grid.x, 1)
	var safe_y := maxi(tile_grid.y, 1)
	var x := index % safe_x
	var yz := int(index / safe_x)
	var y := yz % safe_y
	var z := int(yz / safe_y)
	return Vector3i(x, y, z)

func _decode_tile_summary_value(raw_value: int) -> float:
	return float(maxi(raw_value, 0)) / SCENE_VOXEL_TILE_REDUCE_QUANT_SCALE

func _decode_scene_voxel_tile_compact_summaries(bytes: PackedByteArray, record_count: int, tile_grid: Vector3i) -> Array[Dictionary]:
	var summaries: Array[Dictionary] = []
	var byte_stride := SCENE_VOXEL_TILE_COMPACT_SUMMARY_UINT_STRIDE * 4
	var available_bytes := mini(bytes.size(), record_count * byte_stride)
	available_bytes -= available_bytes % byte_stride
	var available := mini(record_count, int(available_bytes / byte_stride))
	for record_index in range(available):
		var base := record_index * byte_stride

		var tile_index := int(bytes.decode_u32(base + 0))
		var scene_count := int(bytes.decode_u32(base + 4))
		var collision_count := int(bytes.decode_u32(base + 16))
		if scene_count <= 0 and collision_count <= 0:
			continue

		var scene_minmax := Vector2.ZERO
		if scene_count > 0:
			scene_minmax = Vector2(
				_decode_tile_summary_value(int(bytes.decode_u32(base + 8))),
				_decode_tile_summary_value(int(bytes.decode_u32(base + 12)))
			)

		var collision_minmax := Vector2.ZERO
		if collision_count > 0:
			collision_minmax = Vector2(
				_decode_tile_summary_value(int(bytes.decode_u32(base + 20))),
				_decode_tile_summary_value(int(bytes.decode_u32(base + 24)))
			)

		summaries.append({
			"tile_coord": _tile_coord_from_summary_index(tile_index, tile_grid),
			"scene_voxel_count": scene_count,
			"collision_cell_count": collision_count,
			"scene_minmax": scene_minmax,
			"collision_minmax": collision_minmax,
		})
	return summaries

func _gc_frame_preserving_rids(preserved_rids: Array) -> void:
	if preserved_rids.is_empty():
		gc_frame()
		return

	var preserved_entries: Array[Dictionary] = []
	var preserve_scope := "_scene_voxel_summary_prebound_preserve"
	for entry in _resources:
		if not bool(entry.get("alive", false)):
			continue
		var rid: RID = entry.get("rid", RID())
		if not rid.is_valid() or not preserved_rids.has(rid):
			continue
		var scope := str(entry.get("scope", ""))
		if scope != SCOPE_FRAME and scope != SCOPE_PASS:
			continue
		preserved_entries.append({
			"entry": entry,
			"scope": scope,
		})
		entry["scope"] = preserve_scope

	gc_frame()

	for preserved in preserved_entries:
		var entry: Dictionary = preserved.get("entry", {})
		if not bool(entry.get("alive", false)):
			continue
		if str(entry.get("scope", "")) == preserve_scope:
			entry["scope"] = str(preserved.get("scope", SCOPE_FRAME))

func _reduce_scene_voxel_tile_summaries_gpu(
	scene_field: PackedFloat32Array,
	collision_field: PackedFloat32Array,
	xz_res: int,
	total_slices: int,
	tile_size: Vector3i,
	buffer_contract: Dictionary = {}
) -> Dictionary:
	var voxel_count := xz_res * xz_res * total_slices
	if voxel_count <= 0:
		return {}

	var contract_voxel_count := int(buffer_contract.get("voxel_count", 0))
	var prebound_scene_buffer: RID = buffer_contract.get("scene_field_buffer", buffer_contract.get("scene_buffer", RID()))
	var prebound_collision_buffer: RID = buffer_contract.get("collision_field_buffer", buffer_contract.get("collision_buffer", RID()))
	var use_prebound_scene_buffer := prebound_scene_buffer.is_valid() and contract_voxel_count == voxel_count
	var use_prebound_collision_buffer := prebound_collision_buffer.is_valid() and contract_voxel_count == voxel_count
	if not use_prebound_scene_buffer and scene_field.size() != voxel_count:
		return {}
	if not use_prebound_collision_buffer and collision_field.size() != voxel_count:
		return {}
	if not _gpu_ready or _rd == null:
		return {}
	if not _shader_reduce_scene_voxel_tile_summaries.is_valid() or not _pipeline_reduce_scene_voxel_tile_summaries.is_valid():
		return {}
	if not _shader_init_scene_voxel_tile_summaries.is_valid() or not _pipeline_init_scene_voxel_tile_summaries.is_valid():
		return {}
	if not _shader_compact_scene_voxel_tile_summaries.is_valid() or not _pipeline_compact_scene_voxel_tile_summaries.is_valid():
		return {}

	var safe_tile_size := Vector3i(maxi(tile_size.x, 1), maxi(tile_size.y, 1), maxi(tile_size.z, 1))
	var summary_grid_size := Vector3i(xz_res, total_slices, xz_res)
	var tile_grid := SceneVoxelTileCodecScript.tile_grid_size(summary_grid_size, safe_tile_size)
	var tile_count := tile_grid.x * tile_grid.y * tile_grid.z
	if tile_count <= 0:
		return {}

	var preserved_buffers: Array = []
	var scene_buffer := prebound_scene_buffer
	if use_prebound_scene_buffer:
		preserved_buffers.append(scene_buffer)
	else:
		scene_buffer = storage_buffer_from_floats(scene_field, SCOPE_FRAME, "scene_voxel_tile_summary_scene_field")

	var collision_buffer := prebound_collision_buffer
	if use_prebound_collision_buffer:
		preserved_buffers.append(collision_buffer)
	else:
		collision_buffer = storage_buffer_from_floats(collision_field, SCOPE_FRAME, "scene_voxel_tile_summary_collision_field")

	var summary_buffer := storage_buffer_zero(tile_count * SCENE_VOXEL_TILE_REDUCE_SUMMARY_UINT_STRIDE * 4, SCOPE_FRAME, "scene_voxel_tile_summary_counts")
	var compact_buffer := storage_buffer_zero(tile_count * SCENE_VOXEL_TILE_COMPACT_SUMMARY_UINT_STRIDE * 4, SCOPE_FRAME, "scene_voxel_tile_summary_compact")
	var compact_counter_buffer := storage_buffer_zero(4, SCOPE_FRAME, "scene_voxel_tile_summary_compact_counter")
	if not scene_buffer.is_valid() or not collision_buffer.is_valid() or not summary_buffer.is_valid() or not compact_buffer.is_valid() or not compact_counter_buffer.is_valid():
		_gc_frame_preserving_rids(preserved_buffers)
		return {}

	var init_set := create_uniform_set([
		make_storage_uniform(0, summary_buffer),
	], _shader_init_scene_voxel_tile_summaries, 0, SCOPE_PASS, "init_scene_voxel_tile_summaries")
	if not init_set.is_valid():
		_gc_frame_preserving_rids(preserved_buffers)
		return {}

	var set0 := create_uniform_set([
		make_storage_uniform(0, scene_buffer),
		make_storage_uniform(1, collision_buffer),
		make_storage_uniform(2, summary_buffer),
	], _shader_reduce_scene_voxel_tile_summaries, 0, SCOPE_PASS, "reduce_scene_voxel_tile_summaries")
	if not set0.is_valid():
		_gc_frame_preserving_rids(preserved_buffers)
		return {}

	var compact_set := create_uniform_set([
		make_storage_uniform(0, summary_buffer),
		make_storage_uniform(1, compact_buffer),
		make_storage_uniform(2, compact_counter_buffer),
	], _shader_compact_scene_voxel_tile_summaries, 0, SCOPE_PASS, "compact_scene_voxel_tile_summaries")
	if not compact_set.is_valid():
		_gc_frame_preserving_rids(preserved_buffers)
		return {}

	var init_push := PackedByteArray()
	init_push.resize(16)
	init_push.encode_s32(0, tile_count)
	init_push.encode_s32(4, SCENE_VOXEL_TILE_REDUCE_SUMMARY_UINT_STRIDE)
	init_push.encode_s32(8, 0x7FFFFFFF)
	init_push.encode_s32(12, 0)

	var push := PackedByteArray()
	push.resize(64)
	push.encode_s32(0, xz_res)
	push.encode_s32(4, total_slices)
	push.encode_s32(8, voxel_count)
	push.encode_s32(12, tile_count)
	push.encode_s32(16, safe_tile_size.x)
	push.encode_s32(20, safe_tile_size.y)
	push.encode_s32(24, safe_tile_size.z)
	push.encode_s32(28, SCENE_VOXEL_TILE_REDUCE_SUMMARY_UINT_STRIDE)
	push.encode_s32(32, tile_grid.x)
	push.encode_s32(36, tile_grid.y)
	push.encode_s32(40, tile_grid.z)
	push.encode_s32(44, 0)
	push.encode_float(48, VOXEL_OCCUPIED_EPSILON)
	push.encode_float(52, SCENE_VOXEL_TILE_REDUCE_QUANT_SCALE)
	push.encode_float(56, 0.0)
	push.encode_float(60, 0.0)

	var compact_push := PackedByteArray()
	compact_push.resize(16)
	compact_push.encode_s32(0, tile_count)
	compact_push.encode_s32(4, SCENE_VOXEL_TILE_REDUCE_SUMMARY_UINT_STRIDE)
	compact_push.encode_s32(8, SCENE_VOXEL_TILE_COMPACT_SUMMARY_UINT_STRIDE)
	compact_push.encode_s32(12, 0)

	var groups := dispatch_groups_1d(voxel_count, 64)
	var cl := begin_compute_list()
	if cl < 0:
		_gc_frame_preserving_rids(preserved_buffers)
		return {}
	_gpu_dispatch_pipeline(cl, _pipeline_init_scene_voxel_tile_summaries, init_set, init_push, dispatch_groups_1d(tile_count, 64))
	_rd.compute_list_add_barrier(cl)
	_gpu_dispatch_pipeline(cl, _pipeline_reduce_scene_voxel_tile_summaries, set0, push, groups)
	_rd.compute_list_add_barrier(cl)
	_gpu_dispatch_pipeline(cl, _pipeline_compact_scene_voxel_tile_summaries, compact_set, compact_push, dispatch_groups_1d(tile_count, 64))
	end_compute_list()
	submit_and_sync()

	var counter_bytes := _rd.buffer_get_data(compact_counter_buffer, 0, 4)
	var compact_record_count := 0
	if counter_bytes.size() >= 4:
		compact_record_count = clampi(int(counter_bytes.decode_u32(0)), 0, tile_count)
	var compact_value_count := compact_record_count * SCENE_VOXEL_TILE_COMPACT_SUMMARY_UINT_STRIDE
	var compact_bytes := PackedByteArray()
	if compact_value_count > 0:
		compact_bytes = _rd.buffer_get_data(compact_buffer, 0, compact_value_count * 4)
	_gc_frame_preserving_rids(preserved_buffers)
	if compact_bytes.size() < compact_value_count * 4:
		return {}

	return {
		"tile_grid": tile_grid,
		"tile_size": safe_tile_size,
		"tile_count": tile_count,
		"compact_summary_count": compact_record_count,
		"summaries": _decode_scene_voxel_tile_compact_summaries(compact_bytes, compact_record_count, tile_grid),
		"gpu_dispatched": true,
		"cpu_fallback": false,
		"summary_source": "reduce_scene_voxel_tile_summaries_compute",
		"summary_compaction_source": "compact_scene_voxel_tile_summaries_compute",
	}

func _apply_scene_voxel_tile_reduce_summaries(reduced: Dictionary) -> void:
	var summaries: Array = reduced.get("summaries", [])
	for raw_summary in summaries:
		if not raw_summary is Dictionary:
			continue
		var summary: Dictionary = raw_summary
		var tile_coord: Vector3i = summary.get("tile_coord", Vector3i.ZERO)
		var tile_id := SceneVoxelTileCodecScript.tile_id(tile_coord)
		var tile: Dictionary = _scene_voxel_tiles.get(tile_id, _default_scene_voxel_tile_record(tile_coord))
		var scene_count := int(summary.get("scene_voxel_count", 0))
		var collision_count := int(summary.get("collision_cell_count", 0))
		tile["scene_voxel_count"] = scene_count
		tile["collision_cell_count"] = collision_count
		tile["scene_minmax"] = summary.get("scene_minmax", Vector2.ZERO)
		tile["collision_minmax"] = summary.get("collision_minmax", Vector2.ZERO)
		tile["non_empty"] = scene_count > 0 or collision_count > 0
		tile["summary"] = _scene_voxel_tile_summary(tile)
		_scene_voxel_tiles[tile_id] = tile
	if not summaries.is_empty():
		_mark_scene_voxel_tile_staging_dirty("tile_summary_reduce")

func _legacy_sv_tiles_from_reduce_summaries(
	reduced: Dictionary,
	tile_size: int,
	dirty_tiles_snapshot: Dictionary
) -> Dictionary:
	var tiles: Dictionary = {}
	var summaries: Array = reduced.get("summaries", [])
	for raw_summary in summaries:
		if not raw_summary is Dictionary:
			continue
		var summary: Dictionary = raw_summary
		var tile_coord: Vector3i = summary.get("tile_coord", Vector3i.ZERO)
		var px := Vector2i(tile_coord.x * tile_size, tile_coord.z * tile_size)
		var slice_index := tile_coord.y
		var scene_count := int(summary.get("scene_voxel_count", 0))
		var scene_minmax: Vector2 = summary.get("scene_minmax", Vector2.ZERO)
		if scene_count > 0:
			var scene_key := _sv_tile_key(slice_index, px, "scene", tile_size)
			tiles[scene_key] = {
				"tile_id": scene_key,
				"clip_level": 0,
				"layer": "scene",
				"tile_size": tile_size,
				"bounds": _sv_tile_bounds(px, tile_size),
				"dirty": false,
				"updated_this_commit": dirty_tiles_snapshot.has(scene_key),
				"distance_or_occupancy": "occupancy",
				"scene_voxel_count": scene_count,
				"collision_cell_count": 0,
				"max_complexity": scene_minmax.y,
			}

		var collision_count := int(summary.get("collision_cell_count", 0))
		var collision_minmax: Vector2 = summary.get("collision_minmax", Vector2.ZERO)
		if collision_count > 0:
			var collision_key := _sv_tile_key(slice_index, px, "collision", tile_size)
			tiles[collision_key] = {
				"tile_id": collision_key,
				"clip_level": 0,
				"layer": "collision",
				"tile_size": tile_size,
				"bounds": _sv_tile_bounds(px, tile_size),
				"dirty": false,
				"updated_this_commit": dirty_tiles_snapshot.has(collision_key),
				"distance_or_occupancy": "occupancy",
				"scene_voxel_count": 0,
				"collision_cell_count": collision_count,
				"max_complexity": collision_minmax.y,
			}
	return tiles

func _rebuild_sv(tile_size: int = SV_RESIDENT_TILE_SIZE) -> Dictionary:

	if _volume.is_empty():

		_sv = {}

		return {}

	var xz_res: int = _volume.xz_res

	var total_slices := int(_volume.get("total_slices", grid_size.y))

	var scene_voxels: Dictionary = _volume.get("scene_voxels", {})

	var collision: Dictionary = _volume.get("collision", {})

	var expected_scene_field_count := xz_res * xz_res * total_slices

	var scene_field_buffer_scope := "_rebuild_sv_scene_field_buffer"

	gc_scope(scene_field_buffer_scope)

	var scene_field_result := _try_make_sv_scene_field_from_source_streams_gpu_result(xz_res, total_slices, scene_field_buffer_scope)

	var scene_field: PackedFloat32Array = scene_field_result.get("field", PackedFloat32Array())

	var scene_field_buffer: RID = scene_field_result.get("scene_field_buffer", RID())

	var scene_field_source := "auto_brush_source_stream_compute"

	if scene_field.size() != expected_scene_field_count:
		push_error("[SceneVoxelCommitter] SV scene field compute failed")
		scene_field = PackedFloat32Array()
		scene_field_buffer = RID()
		scene_field_source = "auto_brush_source_stream_compute_failed"

	var collision_field := _make_sv_collision_field(collision, xz_res, total_slices)

	var collision_summary_buffer_scope := "_rebuild_sv_collision_summary_buffer"

	gc_scope(collision_summary_buffer_scope)

	var collision_summary_buffer_result := _make_sv_collision_record_summary_gpu_buffer(collision, xz_res, total_slices, collision_summary_buffer_scope)

	var collision_summary_buffer: RID = collision_summary_buffer_result.get("collision_field_buffer", RID())

	var collision_summary_field := PackedFloat32Array()

	if not collision_summary_buffer.is_valid():
		collision_summary_field = _make_sv_collision_record_summary_field(collision, xz_res, total_slices)

	_volume["collision_field"] = _resample_collision_field(_collision_field, xz_res)

	var tile_grid_size := Vector3i(

		ceili(float(grid_size.x) / float(tile_size)),

		ceili(float(grid_size.y) / float(tile_size)),

		ceili(float(grid_size.z) / float(tile_size))

	)

	var total_tiles := tile_grid_size.x * tile_grid_size.y * tile_grid_size.z

	var dirty_tiles_snapshot := _sv_dirty_tiles.duplicate(true)

	var dirty_rects_snapshot := _sv_dirty_rects.duplicate(true)

	var dirty_scene_voxel_tiles_snapshot := {}

	var tiles: Dictionary = {}

	_reset_scene_voxel_tile_summaries()

	var summary_buffer_contract := {
		"voxel_count": expected_scene_field_count,
	}
	if scene_field_buffer.is_valid():
		summary_buffer_contract["scene_field_buffer"] = scene_field_buffer
	if collision_summary_buffer.is_valid():
		summary_buffer_contract["collision_field_buffer"] = collision_summary_buffer

	var scene_voxel_tile_summary := _reduce_scene_voxel_tile_summaries_gpu(
		scene_field,
		collision_summary_field,
		xz_res,
		total_slices,
		_scene_voxel_tile_size(),
		summary_buffer_contract
	)
	var scene_voxel_tile_summary_source := str(scene_voxel_tile_summary.get("summary_source", "scene_voxel_tile_summary_compute_failed"))
	if scene_voxel_tile_summary.is_empty():
		push_error("[SceneVoxelCommitter] SceneVoxelTile summary reduce compute failed")
	else:
		_apply_scene_voxel_tile_reduce_summaries(scene_voxel_tile_summary)

	var legacy_tile_summary := _reduce_scene_voxel_tile_summaries_gpu(
		scene_field,
		collision_summary_field,
		xz_res,
		total_slices,
		Vector3i(maxi(tile_size, 1), 1, maxi(tile_size, 1)),
		summary_buffer_contract
	)
	var legacy_tile_summary_source := str(legacy_tile_summary.get("summary_source", "legacy_tile_summary_compute_failed"))
	if legacy_tile_summary.is_empty():
		push_error("[SceneVoxelCommitter] Legacy SV tile summary reduce compute failed")
	else:
		tiles = _legacy_sv_tiles_from_reduce_summaries(legacy_tile_summary, tile_size, dirty_tiles_snapshot)

	gc_scope(scene_field_buffer_scope)

	gc_scope(collision_summary_buffer_scope)

	_rebuild_scene_voxel_tile_source_refs()

	dirty_scene_voxel_tiles_snapshot = _dirty_scene_voxel_tile_snapshot()
	if not dirty_scene_voxel_tiles_snapshot.is_empty():
		_scene_voxel_tile_pending_resident_upload_tiles = dirty_scene_voxel_tiles_snapshot.duplicate(true)

	_sv = {

		"type": "SV",

		"gpu_first": true,

		"cpu_fallback": false,

		"runtime_read_source": "none",

		"scene_field_runtime_read_source": "none",

		"collision_field_runtime_read_source": "none",

		"scene_field_staging_source": "sv_owner_control_snapshot",

		"scene_field_source": scene_field_source,

		"collision_field_staging_source": "sv_owner_control_snapshot",

		"scene_voxel_tile_summary_source": scene_voxel_tile_summary_source,

		"legacy_tile_summary_source": legacy_tile_summary_source,

		"tile_summary_gpu_dispatched": not scene_voxel_tile_summary.is_empty() and not legacy_tile_summary.is_empty(),

		"tile_size": tile_size,  # resident tile edge size

		"clip_level": 0,  # clipmap level; 0 in current SV

		"bounds": Rect2i(Vector2i.ZERO, Vector2i(xz_res, xz_res)),  # full XZ volume bounds

		"grid_size": grid_size,  # SV grid dimensions

		"voxel_size": voxel_size,  # world-space voxel size

		"grid_origin": grid_origin,  # world-space grid origin

		"scene_field": scene_field,  # resident occupancy/complexity buffer

		"collision_field": collision_field,  # resident collision + terrain base buffer

		"dirty": false,  # resident state has been rebuilt

		"distance_or_occupancy": "occupancy",  # current SV stores occupancy, not SDF

		"commit_tick": _committed_tick,  # committed SV epoch

		"generation_tick": _generation_tick,  # current generation tick

		"tile_count": tiles.size(),

		"tile_grid_size": tile_grid_size,

		"total_tiles": total_tiles,

		"scene_voxel_count": scene_voxels.size(),

		"collision_cell_count": collision.size(),

		"dirty_tile_count": dirty_tiles_snapshot.size(),

		"dirty_tiles": dirty_tiles_snapshot,  # dirty tile storage/debug map

		"scene_voxel_tile_size_setting": SCENE_VOXEL_TILE_SIZE_SETTING,

		"scene_voxel_tile_default_size": DEFAULT_SCENE_VOXEL_TILE_SIZE,

		"scene_voxel_tile_size": _scene_voxel_tile_size(),

		"scene_voxel_tile_count": _scene_voxel_tiles.size(),

		"scene_voxel_tile_gpu_autoobject_ref_count": _scene_voxel_tile_gpu_autoobject_refs.size(),

		"scene_voxel_tile_object_ids_debug": _scene_voxel_tile_object_ids_debug.duplicate(),

		"scene_voxel_tile_source_ids_debug": _scene_voxel_tile_source_ids_debug.duplicate(),

		"scene_voxel_tiles": _scene_voxel_tiles.duplicate(true),

		"dirty_scene_voxel_tile_count": dirty_scene_voxel_tiles_snapshot.size(),

		"dirty_scene_voxel_tiles": dirty_scene_voxel_tiles_snapshot,  # named SceneVoxelTile dirty records

		"dirty_rects": dirty_rects_snapshot,  # dirty voxel regions in XZ rect form

		"tiles": tiles,  # occupied scene/collision tile summaries

	}

	_sv_dirty_tiles.clear()

	_sv_dirty_rects.clear()

	_clear_scene_voxel_tile_dirty_flags()

	_maybe_auto_upload_scene_voxel_tile_buffers("sv_publish")

	_publish_scene_voxel_tile_gpu_summary_to_sv()

	_sv_dirty = false

	return _sv.duplicate(true)

func _stamp_volume_slices(

	base_px: Vector2i,

	radius_px: int,

	complexity: float,

	slice_indices: Array[int],

	scene_voxel_template: Dictionary = {},

	write_tick: int = -1

) -> Vector2i:

	if _volume.is_empty() or slice_indices.is_empty():

		return base_px

	var xz_res: int = _volume.xz_res

	var voxel_px := _volume_px_from_base(base_px, xz_res)

	var radius_vol := _volume_radius_from_base_radius(radius_px, xz_res)

	var v := clampf(complexity, 0.0, 1.0)

	var slices: Array = _volume.slices

	var source_type := str(scene_voxel_template.get("source_voxel_type", scene_voxel_template.get("type", "")))

	var force_source_write := source_type == "BrushSceneVoxel" or bool(scene_voxel_template.get("write_empty_voxels", false))

	for si in slice_indices:

		var img: Image = slices[si]

		var previous_img := img

		img = _stamp_scalar_image_disc(img, voxel_px, radius_vol, v, 0)

		var changed_pixels := _collect_disc_pixels_gpu(previous_img, voxel_px, radius_vol, v, force_source_write, true) if not scene_voxel_template.is_empty() else []
		for px in changed_pixels:
			var scene_voxel := scene_voxel_template.duplicate(true)
			scene_voxel["slice_index"] = si
			scene_voxel["voxel_xz"] = px
			scene_voxel["complexity"] = v
			scene_voxel = SharedPropertyTypeScript.apply_to_scene_voxel(scene_voxel, scene_voxel, v, SharedPropertyTypeScript.has_collision_fields(scene_voxel))
			scene_voxel = SceneVoxelSourceRecordScript.prepare_source_record(scene_voxel, write_tick if write_tick >= 0 else _generation_tick)
			_enqueue_scene_voxel_source_record(scene_voxel)

		slices[si] = img

	_volume["slices"] = slices

	return voxel_px

## Apply an actual placed mesh's ISWS / legacy voxel_write_spec into SceneVoxel and buffers.

## This keeps runtime MeshInstance3D placement and the occupancy/voxel volume in sync.

func apply_voxel_write_spec(record: Dictionary, defer_blend: bool = false, generation_tick: int = -1) -> Dictionary:
	if record.is_empty():
		return {}

	var write_tick := generation_tick if generation_tick >= 0 else _next_write_tick()
	var rec := SceneVoxelSourceRecordScript.prepare_source_record(record, write_tick)
	var record_id := str(rec.get("id", "mesh_%d" % _voxel_write_specs.size()))
	rec["id"] = record_id
	if SceneVoxelTargetScript.is_target_type(str(rec.get("source_voxel_type", ""))):
		rec["target_guidance_only"] = true
		rec["height_buffer_applied"] = false
		rec["height_buffer_channels"] = []
		rec["collision_source_attached"] = false
		rec["collision_buffer_applied"] = false
		var bounds := _scene_voxel_tile_bounds_from_record(rec)
		mark_scene_voxel_tile_bounds_dirty(
			bounds.voxel_min,
			bounds.voxel_max,
			SceneVoxelTargetScript.target_dirty_flags(),
			{}
		)
		return rec

	var applied_channels: Array[int] = []
	var rec_base_px: Vector2i = rec.get("base_pixel", Vector2i.ZERO)
	var collision_layers: Array = rec.get("collision", [])
	var stamped_collision_layers: Array = _stamp_shared_field_layers(rec_base_px, collision_layers, rec)
	var collision_buffer_applied := not stamped_collision_layers.is_empty()
	var collision_source_layers: Array = stamped_collision_layers if not stamped_collision_layers.is_empty() else collision_layers
	var updated_collision_layers := _make_source_collision(rec_base_px, collision_source_layers, rec)
	rec["collision"] = updated_collision_layers

	var ch := _record_channel(rec)
	if ch >= 0:
		var channel_record := rec.duplicate(true)
		channel_record["channel"] = ch
		channel_record["base_pixel"] = rec_base_px
		var radius_px := _record_radius_px(channel_record)
		var complexity := clampf(float(channel_record.get("complexity", rec.get("complexity", 1.0))), 0.0, 1.0)
		var color := SharedPropertyTypeScript.color_from_value(channel_record.get("color", rec.get("color", Color.WHITE)), Color.WHITE)
		color.a = complexity
		var slice_indices := _slice_indices_for_channel_record(channel_record, ch)
		var source_voxel_template := {}
		if not _volume.is_empty():
			var template_voxel_px := _volume_px_from_base(rec_base_px, int(_volume.xz_res))
			source_voxel_template = _make_scene_voxel_source_record_template(rec, channel_record, template_voxel_px, complexity)

		_stamp_occupancy_channel(rec_base_px, ch, radius_px, complexity)
		var voxel_px := _stamp_volume_slices(
			rec_base_px,
			radius_px,
			complexity,
			slice_indices,
			source_voxel_template,
			write_tick
		)

		rec["channel"] = ch
		rec["base_pixel"] = rec_base_px
		rec["voxel_xz"] = voxel_px
		rec["radius_px"] = radius_px
		rec["complexity"] = complexity
		rec["color"] = color
		rec["slice_indices"] = slice_indices
		if not applied_channels.has(ch):
			applied_channels.append(ch)
	else:
		rec["base_pixel"] = rec_base_px
		if _volume.is_empty():
			rec["voxel_xz"] = rec_base_px
			rec["volume_xz_resolution"] = _base_res
		else:
			rec["voxel_xz"] = _volume_px_from_base(rec_base_px, int(_volume.xz_res))
			rec["volume_xz_resolution"] = int(_volume.xz_res)

	if not _volume.is_empty():
		rec["volume_xz_resolution"] = int(_volume.xz_res)
	rec["collision"] = updated_collision_layers
	rec["height_buffer_applied"] = not applied_channels.is_empty()
	rec["height_buffer_channels"] = applied_channels
	rec["collision_source_attached"] = not updated_collision_layers.is_empty()
	rec["collision_buffer_applied"] = collision_buffer_applied

	if _voxel_write_spec_index.has(record_id):
		var idx: int = _voxel_write_spec_index[record_id]
		_voxel_write_specs[idx] = rec
	else:
		_voxel_write_spec_index[record_id] = _voxel_write_specs.size()
		_voxel_write_specs.append(rec)

	if not defer_blend and not _volume.is_empty():
		blend_scene_voxels(write_tick)

	return rec

func apply_instance_stamp_write_spec(record: Dictionary, defer_blend: bool = false, generation_tick: int = -1) -> Dictionary:

	return apply_voxel_write_spec(record, defer_blend, generation_tick)

func apply_voxel_write_specs(records: Array, defer_blend: bool = false, generation_tick: int = -1) -> Dictionary:
	return _apply_voxel_write_spec_batch(records, defer_blend, generation_tick, "apply_voxel_write_specs")

func apply_instance_stamp_write_specs(records: Array, defer_blend: bool = false, generation_tick: int = -1) -> Dictionary:
	return _apply_voxel_write_spec_batch(records, defer_blend, generation_tick, "apply_instance_stamp_write_specs")

func _apply_voxel_write_spec_batch(records: Array, defer_blend: bool, generation_tick: int, batch_api: String) -> Dictionary:
	var report := {
		"ok": true,
		"reason": "ok",
		"gpu_first": true,
		"cpu_fallback": false,
		"source_write_handoff_mode": "cpu_batch_isws_pending_source_candidate_bridge",
		"source_write_batch_api": batch_api,
		"cpu_pending_source_candidate_bridge": true,
		"pending_source_candidate_flush_api": "blend_scene_voxels->_flush_pending_scene_voxel_source_candidates",
		"source_candidate_resolve_api": "resolve_scene_voxel_sources.glsl",
		"resident_source_write_buffer": false,
		"resident_source_write_buffer_owner": "none",
		"resident_source_write_buffer_rid": "none",
		"resident_source_write_buffer_lifetime": "none",
		"resident_source_write_buffer_stride_bytes": 0,
		"resident_source_write_buffer_range_count": 0,
		"source_record_count": 0,
		"applied_count": 0,
		"failed_count": 0,
		"apply_results": [],
	}
	report.merge(_scene_voxel_source_candidate_resident_diagnostics(false), true)
	if records.is_empty():
		report["reason"] = "empty_records"
		return report

	var staging_epoch_before := _scene_voxel_source_candidate_staging_epoch

	var write_tick := begin_generation_tick(generation_tick)
	for raw_record in records:
		if not raw_record is Dictionary:
			report["ok"] = false
			report["reason"] = "invalid_instance_stamp_write_spec"
			report["failed_count"] = int(report.get("failed_count", 0)) + 1
			continue
		var record := raw_record as Dictionary
		report["source_record_count"] = int(report.get("source_record_count", 0)) + 1
		var applied := apply_voxel_write_spec(record, true, write_tick)
		if applied.is_empty():
			report["ok"] = false
			report["reason"] = "scene_voxel_committer_apply_failed"
			report["failed_count"] = int(report.get("failed_count", 0)) + 1
			continue
		(report["apply_results"] as Array).append(applied.duplicate(true))
		report["applied_count"] = int(report.get("applied_count", 0)) + 1

	if not defer_blend and not _volume.is_empty() and int(report.get("applied_count", 0)) > 0:
		blend_scene_voxels(write_tick)
		report.merge(
			_scene_voxel_source_candidate_resident_diagnostics(
				_scene_voxel_source_candidate_staging_epoch > staging_epoch_before
			),
			true
		)

	return report

func clear_all() -> void:

	_occupancy.fill(Color(0.0, 0.0, 0.0, 0.0))

	_volume = {}

	_voxel_write_specs.clear()

	_voxel_write_spec_index.clear()

	_scene_state_by_tick.clear()

	_scene_source_metadata.clear()

	_clear_scene_voxel_source_streams()

	_sv.clear()

	_sv_dirty_tiles.clear()

	_sv_dirty_rects.clear()

	_scene_voxel_tiles.clear()

	_scene_voxel_tile_gpu_autoobject_refs.clear()

	_scene_voxel_tile_object_ids_debug.clear()

	_scene_voxel_tile_source_ids_debug.clear()

	_scene_voxel_tile_object_ref_last_update_stats.clear()

	_scene_voxel_tile_fixed_object_ref_tile_count = 0

	_scene_voxel_tile_fixed_object_ref_slot_count = 0

	_scene_voxel_tile_object_ref_rebuild_required = false

	_scene_voxel_tile_object_ref_overflow_count = 0

	_scene_voxel_tile_object_ref_overflow_tile_ids.clear()

	_scene_voxel_tile_epoch = 0

	_release_scene_voxel_tile_gpu_buffers()

	_mark_scene_voxel_tile_staging_dirty("clear_all")

	_generation_tick = 1

	_committed_tick = 0

	_sv_dirty = true

## ─── 3D Voxel Volume ───

##

## Aggregates all 2D channel occupancy into a unified 3D voxel grid.

var _volume: Dictionary = {}

## Per placed runtime voxel_write_spec entries. These connect runtime MeshInstance3D nodes back

## to the voxel channel data that was stamped for them.

var _voxel_write_specs: Array[Dictionary] = []

var _voxel_write_spec_index: Dictionary = {}

var _scene_state_by_tick: Dictionary = {}

var _scene_source_metadata: Dictionary = {}

var _auto_scene_voxel_sources: Dictionary = {}

var _brush_scene_voxel_sources: Dictionary = {}

var _pending_auto_scene_voxel_source_candidates: Dictionary = {}

var _pending_brush_scene_voxel_source_candidates: Dictionary = {}

var _scene_voxel_source_candidate_records_buffer: RID

var _scene_voxel_source_candidate_records_capacity := 0

var _scene_voxel_source_candidate_records_count := 0

var _scene_voxel_source_candidate_ranges_buffer: RID

var _scene_voxel_source_candidate_ranges_capacity := 0

var _scene_voxel_source_candidate_ranges_count := 0

var _scene_voxel_source_candidate_staging_epoch := 0

var _last_scene_voxel_source_resolve_summary: Dictionary = {}

var _last_blend_scene_voxel_commit_summary: Dictionary = {}

var _sv: Dictionary = {}

var _sv_dirty_tiles: Dictionary = {}

var _sv_dirty_rects: Array[Rect2i] = []

var _scene_voxel_tiles: Dictionary = {}

var _scene_voxel_tile_gpu_autoobject_refs: Dictionary = {}

var _scene_voxel_tile_object_ids_debug: Array[String] = []

var _scene_voxel_tile_source_ids_debug: Array[String] = []

var _scene_voxel_tile_epoch: int = 0

var _scene_voxel_tile_gpu_ready := false

var _scene_voxel_tile_gpu_revision := 0

var _scene_voxel_tile_staging_revision := 0

var _scene_voxel_tile_uploaded_revision := -1

var _scene_voxel_tile_last_upload_error := ""

var _scene_voxel_tile_gpu_buffers: Dictionary = {}

var _scene_voxel_tile_gpu_buffer_byte_sizes: Dictionary = {}

var _scene_voxel_tile_gpu_buffer_upload_byte_sizes: Dictionary = {}

var _scene_voxel_tile_gpu_record_counts: Dictionary = {}

var _scene_voxel_tile_gpu_strides: Dictionary = {}

var _scene_voxel_tile_gpu_buffer_hashes: Dictionary = {}

var _scene_voxel_tile_gpu_buffer_reuse_counts: Dictionary = {}

var _scene_voxel_tile_gpu_tile_ids: Array[String] = []

var _scene_voxel_tile_gpu_dirty_tile_ids: Array[String] = []

var _scene_voxel_tile_gpu_stale_reason := "never_uploaded"

var _scene_voxel_tile_gpu_last_upload_tick := -1

var _scene_voxel_tile_gpu_auto_upload := false

var _scene_voxel_tile_gpu_last_reused_buffers: Array[String] = []

var _scene_voxel_tile_pending_resident_upload_tiles: Dictionary = {}

var _scene_voxel_tile_last_upload_mode := "none"

var _scene_voxel_tile_last_upload_tile_ids: Array[String] = []

var _scene_voxel_tile_last_upload_resident_voxel_count := 0

var _scene_voxel_tile_last_upload_range_count := 0

var _scene_voxel_tile_last_summary_dirty_range_update_source := "none"

var _scene_voxel_tile_object_ref_last_update_stats: Dictionary = {}

var _scene_voxel_tile_fixed_object_ref_tile_count := 0

var _scene_voxel_tile_fixed_object_ref_slot_count := 0

var _scene_voxel_tile_object_ref_rebuild_required := false

var _scene_voxel_tile_object_ref_overflow_count := 0

var _scene_voxel_tile_object_ref_overflow_tile_ids: Array[String] = []

var _generation_tick: int = 1

var _committed_tick: int = 0

var _sv_dirty: bool = true

func _make_mesh_voxel_write_spec(
	mesh_id: String,
	mesh_type: String,
	base_px: Vector2i,
	world_pos: Vector3,
	inst_color: Color,
	inst_complexity: float,
	inst_channel_specs: Array[Dictionary],
	instance_scale: float,
	collision: Array[Dictionary] = []
) -> Dictionary:
	var channel_specs: Array[Dictionary] = []
	for spec in inst_channel_specs:
		var ch: int = int(spec.get("channel", -1))
		if not _is_valid_channel(ch):
			continue
		var spec_color := SceneVoxelProfileScript.profile_entry_color(spec, inst_color)
		var spec_complexity := SceneVoxelProfileScript.profile_entry_complexity(spec, spec_color.a)
		spec_color.a = spec_complexity
		var y_min := float(spec.get("y_min", 0.0))
		var y_max := float(spec.get("y_max", y_min + 1.0))
		if y_max <= y_min:
			y_max = y_min + 1.0
		channel_specs.append({
			"channel": ch,
			"base_pixel": base_px,
			"radius": float(spec.get("radius", 0.0)),
			"radius_px": _radius_to_px(float(spec.get("radius", 0.0))),
			"y_min": y_min,
			"y_max": y_max,
			"color": spec_color,
			"complexity": spec_complexity,
			"subdivisions": maxi(int(spec.get("subdivisions", 1)), 1),
			"slice_indices": [],
		})

	var record := {
		"id": mesh_id,
		"type": mesh_type,
		"source_voxel_type": "AutoSceneVoxel",
		"position": world_pos,
		"base_pixel": base_px,
		"voxel_xz": base_px,
		"volume_xz_resolution": _base_res,
		"scale": Vector3.ONE * instance_scale,
		"color": inst_color,
		"complexity": inst_complexity,
		"collision": collision.duplicate(true),
	}
	if not channel_specs.is_empty():
		var primary := channel_specs[0]
		record["channel"] = int(primary.channel)
		record["radius"] = float(primary.radius)
		record["radius_px"] = int(primary.radius_px)
		record["y_min"] = float(primary.y_min)
		record["y_max"] = float(primary.y_max)
		record["subdivisions"] = int(primary.subdivisions)
		record["slice_indices"] = (primary.get("slice_indices", []) as Array).duplicate(true)
	return record

func _register_voxel_write_spec(record: Dictionary) -> Dictionary:

	var record_id: String = str(record.get("id", "mesh_%d" % _voxel_write_specs.size()))

	record["id"] = record_id

	_voxel_write_spec_index[record_id] = _voxel_write_specs.size()

	_voxel_write_specs.append(record)

	return record

func _update_voxel_write_specs_for_volume() -> void:
	if _volume.is_empty():
		return
	var xz_res: int = _volume.xz_res
	var meta: Array = _volume.slice_meta
	for ri in range(_voxel_write_specs.size()):
		var record: Dictionary = _voxel_write_specs[ri]
		var base_px: Vector2i = record.get("base_pixel", Vector2i.ZERO)
		var vx := clampi(int(float(base_px.x) / float(_base_res) * float(xz_res)), 0, xz_res - 1)
		var vz := clampi(int(float(base_px.y) / float(_base_res) * float(xz_res)), 0, xz_res - 1)
		record["voxel_xz"] = Vector2i(vx, vz)
		record["volume_xz_resolution"] = xz_res
		var ch := _record_channel(record)
		if ch >= 0:
			var slice_indices: Array[int] = []
			for si in range(meta.size()):
				var m: Dictionary = meta[si]
				if int(m.channel) == ch:
					slice_indices.append(si)
			record["slice_indices"] = slice_indices
		var collision_layers: Array = record.get("collision", [])
		for ci in range(collision_layers.size()):
			if not collision_layers[ci] is Dictionary:
				continue
			var collision_layer := (collision_layers[ci] as Dictionary).duplicate(true)
			collision_layer["voxel_xz"] = Vector2i(vx, vz)
			collision_layer["volume_xz_resolution"] = xz_res
			collision_layers[ci] = collision_layer
		record["collision"] = collision_layers
		_voxel_write_specs[ri] = record
		_voxel_write_spec_index[str(record.id)] = ri

func _rebuild_scene_voxels_from_records() -> void:

	if _volume.is_empty():

		return

	var write_tick := _next_write_tick()

	begin_generation_tick(write_tick)

	_volume["scene_voxels"] = {}

	_scene_source_metadata.clear()

	_clear_scene_voxel_source_streams()

	var records := get_voxel_write_specs()

	for record in records:

		apply_voxel_write_spec(record, true, write_tick)

func blend_scene_voxels(tick: int = -1) -> Dictionary:

	if _volume.is_empty():

		return {}

	var commit_tick := tick if tick >= 0 else _generation_tick

	var current_source_voxels := _scene_voxel_source_stream_map()

	if _scene_voxel_source_resolve_blocked():

		var previous_on_resolve_failure := {}

		var raw_previous_on_resolve_failure = _scene_state_by_tick.get(_committed_tick, {})

		if raw_previous_on_resolve_failure is Dictionary:

			previous_on_resolve_failure = (raw_previous_on_resolve_failure as Dictionary).duplicate(true)

		_last_blend_scene_voxel_commit_summary = {

			"ok": false,

			"gpu_first": true,

			"mode": "source_resolve_compute_failed",

			"payload_blend_mode": "not_dispatched",

			"dirty_tile_count": _dirty_scene_voxel_tile_snapshot().size(),

			"processed_source_key_count": 0,

			"total_source_key_count": current_source_voxels.size(),

			"committed_scene_voxel_count": previous_on_resolve_failure.size(),

			"runtime_read_source": "none",

			"control_plane_source": "auto_brush_source_streams",

			"source_resolve": _last_scene_voxel_source_resolve_summary.duplicate(true),

			"gpu_dispatched": false,

			"cpu_fallback": false,

		}
		_last_blend_scene_voxel_commit_summary.merge(
			_scene_voxel_source_bridge_diagnostics_from_summary(_last_scene_voxel_source_resolve_summary),
			true
		)

		push_error("[SceneVoxelCommitter] GPU SceneVoxel source resolve dispatch failed")

		return SceneVoxelPayloadScript.public_map(previous_on_resolve_failure)

	var previous_scene_voxels := {}

	var raw_previous = _scene_state_by_tick.get(_committed_tick, {})

	if raw_previous is Dictionary:

		previous_scene_voxels = (raw_previous as Dictionary).duplicate(true)

	var dirty_scene_voxel_tiles := _dirty_scene_voxel_tile_snapshot()

	var dirty_source_keys := _dirty_scene_voxel_source_stream_keys(previous_scene_voxels, dirty_scene_voxel_tiles)

	var use_dirty_limited_source_write := not dirty_scene_voxel_tiles.is_empty() and not dirty_source_keys.is_empty()

	var final_scene_voxels: Dictionary = previous_scene_voxels.duplicate(true) if use_dirty_limited_source_write else {}

	var source_keys: Array = dirty_source_keys.keys() if use_dirty_limited_source_write else current_source_voxels.keys()

	source_keys.sort()

	if not use_dirty_limited_source_write:

		_scene_source_metadata.clear()

	var payload_blend_mode := "commit_scene_voxel_payloads_compute"

	var gpu_payloads := _try_blend_scene_voxel_commit_payloads_gpu(source_keys, commit_tick)

	var gpu_payload_ok := gpu_payloads.size() == source_keys.size() * SCENE_VOXEL_COMMIT_OUTPUT_FLOAT_STRIDE

	if gpu_payload_ok:

		_commit_scene_voxel_sources_from_gpu_payloads(source_keys, gpu_payloads, final_scene_voxels, commit_tick)

	else:

		_last_blend_scene_voxel_commit_summary = {

			"ok": false,

			"gpu_first": true,

			"mode": "compute_dispatch_failed",

			"payload_blend_mode": "commit_scene_voxel_payloads_failed",

			"dirty_tile_count": dirty_scene_voxel_tiles.size(),

			"processed_source_key_count": source_keys.size(),

			"total_source_key_count": current_source_voxels.size(),

			"committed_scene_voxel_count": previous_scene_voxels.size(),

			"runtime_read_source": "none",

			"control_plane_source": "auto_brush_source_streams",

			"source_resolve": _last_scene_voxel_source_resolve_summary.duplicate(true),

			"gpu_dispatched": false,

			"cpu_fallback": false,

		}
		_last_blend_scene_voxel_commit_summary.merge(
			_scene_voxel_source_bridge_diagnostics_from_summary(_last_scene_voxel_source_resolve_summary),
			true
		)

		push_error("[SceneVoxelCommitter] GPU SceneVoxel payload blend dispatch failed")

		return SceneVoxelPayloadScript.public_map(previous_scene_voxels)

	_last_blend_scene_voxel_commit_summary = {
		"ok": true,
		"gpu_first": true,
		"mode": "dirty_scene_voxel_tiles" if use_dirty_limited_source_write else "full_source_stream_scan",
		"dirty_tile_count": dirty_scene_voxel_tiles.size(),
		"processed_source_key_count": source_keys.size(),
		"total_source_key_count": current_source_voxels.size(),
		"committed_scene_voxel_count": final_scene_voxels.size(),
		"runtime_read_source": "none",
		"control_plane_source": "auto_brush_source_streams",
		"payload_blend_mode": payload_blend_mode,
		"gpu_dispatched": gpu_payload_ok,
		"source_resolve": _last_scene_voxel_source_resolve_summary.duplicate(true),
		"cpu_fallback": false,
	}
	_last_blend_scene_voxel_commit_summary.merge(
		_scene_voxel_source_bridge_diagnostics_from_summary(_last_scene_voxel_source_resolve_summary),
		true
	)

	_volume["scene_voxels"] = final_scene_voxels

	_rebuild_shared_field_cache_from_scene_voxels(final_scene_voxels)

	_scene_state_by_tick[commit_tick] = final_scene_voxels.duplicate(true)

	_committed_tick = max(_committed_tick, commit_tick)

	_generation_tick = max(_generation_tick, commit_tick + 1)

	_sv_dirty = true

	_rebuild_sv()

	return SceneVoxelPayloadScript.public_map(final_scene_voxels)

func score_blendsv_feedback_against_target(

	target_occupancy: PackedFloat32Array,

	target_role: String = "TargetSV_B",

	threshold: float = VOXEL_OCCUPIED_EPSILON

) -> Dictionary:
	var result := _score_blendsv_feedback_against_target_gpu(target_occupancy, target_role, threshold)

	if not result.is_empty():
		return result

	push_error("[SceneVoxelCommitter] BlendSV feedback score compute failed")

	return SceneVoxelFeedbackScript.empty_result(target_role)

func _score_blendsv_feedback_against_target_gpu(
	target_occupancy: PackedFloat32Array,
	target_role: String,
	threshold: float = VOXEL_OCCUPIED_EPSILON
) -> Dictionary:

	if _volume.is_empty() or target_occupancy.is_empty():

		return SceneVoxelFeedbackScript.empty_result(target_role)

	var xz_res := int(_volume.get("xz_res", grid_size.x))

	var total_slices := int(_volume.get("total_slices", grid_size.y))

	var voxel_count := xz_res * xz_res * total_slices

	var sample_count := mini(voxel_count, target_occupancy.size())

	if sample_count <= 0:

		return SceneVoxelFeedbackScript.empty_result(target_role)

	if not _gpu_ready or _rd == null or not _shader_score_scene_voxel_feedback.is_valid() or not _pipeline_score_scene_voxel_feedback.is_valid():

		return {}

	var scene_field := _scene_voxel_tile_packed_float_field(_sv.get("scene_field", PackedFloat32Array())) if not _sv.is_empty() else PackedFloat32Array()

	if scene_field.size() < sample_count:

		scene_field = _try_make_sv_scene_field_from_source_streams_gpu(xz_res, total_slices)

	if scene_field.size() < sample_count:

		return {}

	var scene_buffer := storage_buffer_from_floats(scene_field, SCOPE_FRAME, "feedback_scene_field")

	var target_buffer := storage_buffer_from_floats(target_occupancy, SCOPE_FRAME, "feedback_target_field")

	var stats_buffer := storage_buffer_zero(8 * 4, SCOPE_FRAME, "feedback_stats")

	if not scene_buffer.is_valid() or not target_buffer.is_valid() or not stats_buffer.is_valid():

		gc_frame()

		return {}

	var set0 := create_uniform_set([
		make_storage_uniform(0, scene_buffer),
		make_storage_uniform(1, target_buffer),
		make_storage_uniform(2, stats_buffer),
	], _shader_score_scene_voxel_feedback, 0, SCOPE_PASS, "score_scene_voxel_feedback")

	if not set0.is_valid():

		gc_frame()

		return {}

	var target_threshold := maxf(threshold, VOXEL_OCCUPIED_EPSILON)

	var push := PackedByteArray()

	push.resize(32)
	push.encode_s32(0, sample_count)
	push.encode_s32(4, 0)
	push.encode_s32(8, 0)
	push.encode_s32(12, 0)
	push.encode_float(16, target_threshold)
	push.encode_float(20, 0.0)
	push.encode_float(24, 0.0)
	push.encode_float(28, 0.0)

	if not _gpu_dispatch_and_sync(_pipeline_score_scene_voxel_feedback, [set0], push, Vector3i(1, 1, 1)):
		gc_frame()
		return {}

	var stats_bytes := _rd.buffer_get_data(stats_buffer, 0, 8 * 4)

	gc_frame()

	var error_sum := stats_bytes.decode_float(0) if stats_bytes.size() >= 4 else 0.0

	var scene_occupied_count := int(roundf(stats_bytes.decode_float(4) if stats_bytes.size() >= 8 else 0.0))

	var target_occupied_count := int(roundf(stats_bytes.decode_float(8) if stats_bytes.size() >= 12 else 0.0))

	var overlap_occupied_count := int(roundf(stats_bytes.decode_float(12) if stats_bytes.size() >= 16 else 0.0))

	var complexity_fit := clampf(1.0 - error_sum / float(sample_count), 0.0, 1.0)

	var union_count := scene_occupied_count + target_occupied_count - overlap_occupied_count

	var occupancy_iou := 1.0 if union_count <= 0 else float(overlap_occupied_count) / float(union_count)

	var target_recall := 1.0 if target_occupied_count <= 0 else float(overlap_occupied_count) / float(target_occupied_count)

	var result_precision := 1.0 if scene_occupied_count <= 0 else float(overlap_occupied_count) / float(scene_occupied_count)

	var color_fit := 1.0

	var score := clampf(complexity_fit * 0.6 + occupancy_iou * 0.4, 0.0, 1.0)

	return {
		"stage": "post_commit_blendsv_feedback",
		"target_role": target_role,
		"score": score,
		"complexity_fit": complexity_fit,
		"occupancy_iou": occupancy_iou,
		"target_recall": target_recall,
		"result_precision": result_precision,
		"color_fit": color_fit,
		"color_sample_count": 0,
		"sample_count": sample_count,
		"scene_occupied_count": scene_occupied_count,
		"target_occupied_count": target_occupied_count,
		"overlap_occupied_count": overlap_occupied_count,
		"gpu_dispatched": true,
		"cpu_fallback": false,
		"score_source": "score_scene_voxel_feedback_compute",
	}

func build_voxel_volume(

	xz_resolution: int = -1,

	channel_profiles = 1,

) -> Dictionary:

	var xz_res := xz_resolution if xz_resolution > 0 else maxi(_base_res / 2, 32)

	var descriptors := SceneVoxelVolumeChannelsScript.collect_descriptors(channel_profiles, _voxel_write_specs, CHANNEL_COUNT)

	var slices: Array[Image] = []

	var slice_meta: Array[Dictionary] = []

	for descriptor in descriptors:

		var ch := int(descriptor.channel)

		if not _is_valid_channel(ch):

			continue

		var subs := maxi(int(descriptor.get("subdivisions", 1)), 1)

		var y_min_base := float(descriptor.get("y_min", 0.0))

		var y_max_base := float(descriptor.get("y_max", y_min_base + 1.0))

		if y_max_base <= y_min_base:

			y_max_base = y_min_base + 1.0

		var thickness := y_max_base - y_min_base

		var color: Color = descriptor.get("color", Color.WHITE)

		var complexity := clampf(float(descriptor.get("complexity", color.a)), 0.0, 1.0)

		color.a = complexity

		for si in range(subs):

			var y_min: float = y_min_base + thickness * float(si) / float(subs)

			var y_max: float = y_min_base + thickness * float(si + 1) / float(subs)

			var slice_img := _make_occupancy_slice_image(ch, xz_res)

			slices.append(slice_img)

			slice_meta.append({

				"channel": ch,

				"y_min": y_min,

				"y_max": y_max,

				"complexity": complexity,

				"color": color,

			})

	var volume_y_min := 0.0

	var volume_y_max := 1.0

	if not slice_meta.is_empty():

		volume_y_min = INF

		volume_y_max = -INF

		for raw_meta in slice_meta:

			if not raw_meta is Dictionary:

				continue

			var typed_meta := raw_meta as Dictionary

			volume_y_min = minf(volume_y_min, float(typed_meta.get("y_min", 0.0)))

			volume_y_max = maxf(volume_y_max, float(typed_meta.get("y_max", 1.0)))

		if volume_y_min == INF or volume_y_max <= volume_y_min:

			volume_y_min = 0.0

			volume_y_max = 1.0

	_apply_volume_grid_metadata(xz_res, slices.size(), volume_y_min, volume_y_max)

	_volume = {

		"xz_res": xz_res,

		"total_slices": slices.size(),

		"grid_size": grid_size,

		"voxel_size": voxel_size,

		"grid_origin": grid_origin,

		"world_capture_size": _capture_size,

		"slices": slices,

		"slice_meta": slice_meta,

		"scene_voxels": {},

		"terrain_base_collision_field": _resample_collision_field(_terrain_base_collision_field, xz_res),

		"source_collision_field": _resample_collision_field(_source_collision_field, xz_res),

		"collision_field": _resample_collision_field(_collision_field, xz_res),

		"collision": {},

	}

	var pending_dirty_rects := _sv_dirty_rects.duplicate()

	_sv_dirty_rects.clear()

	for dirty_rect in pending_dirty_rects:

		if dirty_rect is Rect2i:

			var typed_dirty_rect: Rect2i = dirty_rect

			_mark_sv_rect_dirty(typed_dirty_rect)

	_update_voxel_write_specs_for_volume()

	_rebuild_scene_voxels_from_records()

	blend_scene_voxels(_generation_tick)

	return _volume


func _make_occupancy_slice_image(channel: int, xz_res: int) -> Image:
	var gpu_img := _make_occupancy_slice_image_gpu(channel, xz_res)
	if gpu_img != null and not gpu_img.is_empty():
		return gpu_img
	var safe_res := maxi(xz_res, 1)
	var slice_img := Image.create(safe_res, safe_res, false, Image.FORMAT_RF)
	slice_img.fill(Color(0.0, 0.0, 0.0, 0.0))
	if channel >= 0 and channel < CHANNEL_COUNT and xz_res > 0:
		push_error("[SceneVoxelCommitter] Occupancy slice GPU compute failed")
	return slice_img


func _make_occupancy_slice_image_gpu(channel: int, xz_res: int) -> Image:
	if channel < 0 or channel >= CHANNEL_COUNT or xz_res <= 0:
		return null
	if _occupancy == null or _occupancy.is_empty():
		return null
	if not _gpu_ready or _rd == null or not _sampler.is_valid():
		return null

	var shader := load_compute_shader("res://shaders/occupancy_slice_image.glsl", SCOPE_FRAME, "occupancy_slice_image")
	var pipeline := create_compute_pipeline(shader, SCOPE_FRAME, "occupancy_slice_image")
	if not shader.is_valid() or not pipeline.is_valid():
		gc_frame()
		return null

	var occupancy_tex := upload_texture_2d(
		_occupancy,
		RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
		Image.FORMAT_RGBAH,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		SCOPE_FRAME,
		"occupancy_slice_rgba16f"
	)
	var out_tex := create_rw_texture_2d(
		xz_res,
		xz_res,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT,
		SCOPE_FRAME,
		"occupancy_slice_r32f"
	)
	if not occupancy_tex.is_valid() or not out_tex.is_valid():
		gc_frame()
		return null

	var set0 := create_uniform_set([
		make_sampler_uniform(0, _sampler, occupancy_tex),
	], shader, 0, SCOPE_PASS, "occupancy_slice_src")
	var set1 := create_uniform_set([
		make_image_uniform(0, out_tex),
	], shader, 1, SCOPE_PASS, "occupancy_slice_out")
	if not set0.is_valid() or not set1.is_valid():
		gc_frame()
		return null

	var push := PackedByteArray()
	push.resize(32)
	push.encode_s32(0, xz_res)
	push.encode_s32(4, xz_res)
	push.encode_s32(8, _occupancy.get_width())
	push.encode_s32(12, _occupancy.get_height())
	push.encode_s32(16, _base_res)
	push.encode_s32(20, channel)
	push.encode_float(24, VOXEL_OCCUPIED_EPSILON)
	push.encode_float(28, 0.0)

	var groups := dispatch_groups_2d(xz_res, xz_res, 32, 32)
	if not _gpu_dispatch_and_sync(pipeline, [set0, set1], push, groups):
		gc_frame()
		return null

	var data := _rd.texture_get_data(out_tex, 0)
	var result := Image.create_from_data(xz_res, xz_res, false, Image.FORMAT_RF, data)
	gc_frame()
	return result


func query_voxel(wx: float, wz: float, height_above_terrain: float) -> Dictionary:

	if _volume.is_empty():

		return {"complexity": 0.0, "color": Color.BLACK}

	var xz_res: int = _volume.xz_res

	var voxel_px := world_to_volume_pixel(Vector3(wx, height_above_terrain, wz), xz_res)

	var px := voxel_px.x

	var pz := voxel_px.y

	var slices: Array = _volume.slices

	var meta: Array = _volume.slice_meta

	for i in range(meta.size()):

		var m: Dictionary = meta[i]

		if height_above_terrain >= m.y_min and height_above_terrain < m.y_max:

			var img: Image = slices[i]

			var sample := _sample_scalar_image_pixel_gpu(img, Vector2i(px, pz))

			if sample.is_empty():

				push_error("[SceneVoxelCommitter] query_voxel GPU sample failed")

				return {"complexity": 0.0, "color": Color.BLACK}

			var v := clampf(float(sample.get("value", 0.0)), 0.0, 1.0)

			var color: Color = m.color

			color.a = v

			var voxel_key := SceneVoxelSourceRecordScript.scene_voxel_key(i, Vector2i(px, pz))

			var scene_voxels: Dictionary = _volume.get("scene_voxels", {})

			if scene_voxels.has(voxel_key):

				var scene_voxel = scene_voxels[voxel_key]

				if scene_voxel is Dictionary:

					var typed_scene_voxel := (scene_voxel as Dictionary).duplicate(true)

					var committed_value := clampf(float(typed_scene_voxel.get("complexity", v)), 0.0, 1.0)

					typed_scene_voxel["complexity"] = committed_value

					typed_scene_voxel = SharedPropertyTypeScript.apply_to_scene_voxel(typed_scene_voxel, typed_scene_voxel, committed_value, SharedPropertyTypeScript.has_collision_fields(typed_scene_voxel))

					typed_scene_voxel["slice_index"] = i

					typed_scene_voxel["voxel_xz"] = Vector2i(px, pz)

					return typed_scene_voxel

			var query_scene_voxel := {

				"complexity": v,

				"slice_index": i,

				"voxel_xz": Vector2i(px, pz),

			}

			return SharedPropertyTypeScript.apply_to_scene_voxel(query_scene_voxel, {"color": color, "complexity": v}, v, false)

	return {"complexity": 0.0, "color": Color.BLACK}

func get_scene_voxels() -> Dictionary:

	if _volume.is_empty():

		return {}

	var scene_voxels: Dictionary = _volume.get("scene_voxels", {})

	return SceneVoxelPayloadScript.public_map(scene_voxels)

func get_sv() -> Dictionary:

	if _sv_dirty and not _volume.is_empty():

		_rebuild_sv()

	elif not _sv.is_empty():

		_maybe_auto_upload_scene_voxel_tile_buffers("get_sv")

		_publish_scene_voxel_tile_gpu_summary_to_sv()

	return _sv.duplicate(true)

func invalidate_sv_tile(slice_index: int, voxel_xz: Vector2i, layer: String = "scene") -> void:

	_mark_sv_tile_dirty(slice_index, voxel_xz, layer)

func invalidate_sv_rect(base_rect: Rect2i, slice_indices: Array = [], include_collision: bool = true) -> void:

	_mark_sv_rect_dirty(base_rect, slice_indices, include_collision)

func get_sv_dirty_tiles() -> Dictionary:

	return _sv_dirty_tiles.duplicate(true)

func mark_scene_voxel_tile_dirty(tile_coord: Vector3i, dirty_flags = {}, source_record: Dictionary = {}) -> void:

	var flags := SceneVoxelTileCodecScript.flags_from_value(dirty_flags)

	_touch_scene_voxel_tile(tile_coord, flags, source_record)

	_mark_legacy_sv_tiles_for_scene_voxel_tile(tile_coord, flags)

func mark_scene_voxel_tile_bounds_dirty(voxel_min: Vector3i, voxel_max: Vector3i, dirty_flags = {}, source_record: Dictionary = {}) -> void:

	_for_each_scene_voxel_tile_in_bounds(voxel_min, voxel_max, func(tile_coord: Vector3i):
		mark_scene_voxel_tile_dirty(tile_coord, dirty_flags, source_record)
	)

func _mark_scene_voxel_full_rebuild_dirty(reason: String = "full_rebuild") -> Dictionary:

	return mark_all_scene_voxel_tiles_dirty(

		{"scene": true, "collision": true},

		{

			"id": reason,

			"source_id": reason,

		}

	)

func mark_all_scene_voxel_tiles_dirty(dirty_flags = {}, source_record: Dictionary = {}) -> Dictionary:

	var flags := SceneVoxelTileCodecScript.flags_from_value(dirty_flags, "")

	if flags.is_empty():

		flags["scene"] = true

		flags["collision"] = true

	var tile_grid := _scene_voxel_tile_grid_size()

	for ty in range(tile_grid.y):

		for tz in range(tile_grid.z):

			for tx in range(tile_grid.x):

				mark_scene_voxel_tile_dirty(Vector3i(tx, ty, tz), flags, source_record)

	var dirty_snapshot := _dirty_scene_voxel_tile_snapshot()

	return {

		"tile_grid_size": tile_grid,

		"tile_count": tile_grid.x * tile_grid.y * tile_grid.z,

		"dirty_scene_voxel_tile_count": dirty_snapshot.size(),

		"dirty_scene_voxel_tiles": dirty_snapshot,

	}

func get_gpu_autoobject_object_ref_range_policy_diagnostics(refs_per_tile: int = SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT) -> Dictionary:

	var safe_refs_per_tile := maxi(refs_per_tile, 1)

	var tile_count := maxi(_scene_voxel_tile_fixed_object_ref_tile_count, _scene_voxel_tiles.size())

	return {
		"object_ref_range_policy": "fixed_per_tile_pending_shader",
		"object_ref_range_owner": "SceneVoxelCommitter",
		"object_ref_range_shader": "none",
		"object_ref_range_shader_path": "none",
		"object_ref_range_shader_ready": false,
		"object_ref_range_stride_bytes": SCENE_VOXEL_TILE_REF_STRIDE_BYTES,
		"refs_per_tile": safe_refs_per_tile,
		"object_ref_capacity": tile_count * safe_refs_per_tile,
		"object_ref_tile_count": tile_count,
		"object_ref_tile_size": _scene_voxel_tile_size(),
		"object_ref_tile_grid_size": _scene_voxel_tile_grid_size(),
		"object_ref_rebuild_required": _scene_voxel_tile_object_ref_rebuild_required,
		"object_ref_update_stats_available": false,
		"object_ref_update_source": "none",
		"object_ref_update_reason": "resident_object_ref_update_pass_not_enabled",
		"object_ref_update_gpu_dispatched": false,
		"object_ref_update_dispatch_count": 0,
		"object_ref_overflow_count": _scene_voxel_tile_object_ref_overflow_count,
		"overflow_tile_count": _scene_voxel_tile_object_ref_overflow_tile_ids.size(),
		"object_ref_overflow_tile_ids": _scene_voxel_tile_object_ref_overflow_tile_ids.duplicate(),
		"object_ref_non_numeric_count": 0,
		"object_ref_duplicate_count": 0,
		"object_ref_touched_count": 0,
		"object_ref_removed_slot_count": 0,
		"object_ref_inserted_slot_count": 0,
		"object_ref_invalid_bounds_count": 0,
		"object_ref_skipped_count": 0,
		"gpu_autoobject_ref_key_schema": "u32_numeric_ref_key_v1",
		"gpu_autoobject_ref_key_schema_note": "Use u32 ref_key entries; 0 is empty, numeric GPU AutoObject object_id + 1 is the pending runtime key, and legacy CPU string hashes remain debug-only.",
	}

func try_apply_gpu_autoobject_object_ref_update_pass(deltas: Array) -> Dictionary:

	var result := {
		"ok": false,
		"reason": "not_dispatched",
		"gpu_first": true,
		"cpu_fallback": false,
		"dirty_delta_bridge_mode": "explicit_scene_voxel_tile_object_ref_update_pass",
		"dirty_delta_apply_api": "try_apply_gpu_autoobject_object_ref_update_pass",
		"dirty_delta_count": deltas.size(),
		"resident_gpu_dirty_delta_update_pass": false,
		"resident_gpu_dirty_delta_update_pass_owner": "none",
		"resident_gpu_dirty_delta_update_pass_shader": "none",
		"resident_gpu_dirty_delta_update_pass_dispatch_count": 0,
		"object_ref_update_result": {},
	}

	result.merge(get_gpu_autoobject_object_ref_range_policy_diagnostics(), true)
	result["object_ref_range_policy"] = "fixed_per_tile_object_ref_update_pass"
	result["object_ref_range_shader"] = SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_NAME
	result["object_ref_range_shader_path"] = SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_PATH
	result["object_ref_range_shader_ready"] = (
		_shader_scene_voxel_tile_object_ref_update.is_valid() and
		_pipeline_scene_voxel_tile_object_ref_update.is_valid()
	)

	if deltas.is_empty():
		result["reason"] = "empty_dirty_delta_batch"
		result["object_ref_update_reason"] = "empty_dirty_delta_batch"
		return result

	if not ensure_scene_voxel_tile_buffers_uploaded(false):
		var skipped_summary := get_scene_voxel_tile_gpu_buffer_summary()
		var upload_reason := str(skipped_summary.get("reason", "scene_voxel_tile_buffer_upload_failed"))
		if upload_reason.is_empty():
			upload_reason = "scene_voxel_tile_buffer_upload_failed"
		result["reason"] = upload_reason
		result["object_ref_update_reason"] = upload_reason
		result["scene_voxel_tile_gpu_ready"] = false
		result["scene_voxel_tile_gpu_upload_status"] = str(skipped_summary.get("gpu_upload_status", "blocked"))
		result["scene_voxel_tile_gpu_skip_reason"] = str(skipped_summary.get("skip_reason", ""))
		return result

	var uploaded_summary := get_scene_voxel_tile_gpu_buffer_summary()
	result["scene_voxel_tile_gpu_ready"] = bool(uploaded_summary.get("runtime_ready", false))
	result["scene_voxel_tile_gpu_upload_status"] = str(uploaded_summary.get("gpu_upload_status", "ready"))
	result["object_ref_capacity"] = int(uploaded_summary.get("object_ref_capacity", result.get("object_ref_capacity", 0)))
	result["object_ref_tile_count"] = int(uploaded_summary.get("object_ref_tile_count", result.get("object_ref_tile_count", 0)))
	result["refs_per_tile"] = int(uploaded_summary.get("refs_per_tile", result.get("refs_per_tile", SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT)))

	var update_stats := _update_gpu_autoobject_object_refs_from_dirty_deltas(deltas)
	var dispatched := bool(update_stats.get("gpu_dispatched", false))
	var dispatch_count := int(update_stats.get("dispatch_group_count", 0)) if dispatched else 0
	var ok := bool(update_stats.get("ok", false))
	var reason := str(update_stats.get("reason", "object_ref_update_failed"))

	result["ok"] = ok
	result["reason"] = reason
	result["object_ref_update_result"] = update_stats
	result["object_ref_update_stats_available"] = bool(update_stats.get("stats_available", false))
	result["object_ref_update_source"] = str(update_stats.get("source", "none"))
	result["object_ref_update_shader"] = str(update_stats.get("shader", SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_NAME))
	result["object_ref_update_reason"] = reason
	result["object_ref_update_gpu_dispatched"] = dispatched
	result["object_ref_update_dispatch_count"] = dispatch_count
	result["object_ref_update_dispatch_group_count"] = int(update_stats.get("dispatch_group_count", 0)) if dispatched else 0
	result["resident_gpu_dirty_delta_update_pass"] = ok and dispatched
	result["resident_gpu_dirty_delta_update_pass_owner"] = "SceneVoxelCommitter" if ok and dispatched else "none"
	result["resident_gpu_dirty_delta_update_pass_shader"] = SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_NAME if ok and dispatched else "none"
	result["resident_gpu_dirty_delta_update_pass_dispatch_count"] = dispatch_count
	result["object_ref_capacity"] = int(update_stats.get("object_ref_capacity", result.get("object_ref_capacity", 0)))
	result["object_ref_overflow_count"] = int(update_stats.get("overflow", 0))
	result["object_ref_non_numeric_count"] = int(update_stats.get("non_numeric", 0))
	result["object_ref_duplicate_count"] = int(update_stats.get("duplicate", 0))
	result["object_ref_touched_count"] = int(update_stats.get("touched", 0))
	result["object_ref_removed_slot_count"] = int(update_stats.get("removed_slots", 0))
	result["object_ref_inserted_slot_count"] = int(update_stats.get("inserted_slots", 0))
	result["object_ref_invalid_bounds_count"] = int(update_stats.get("invalid_bounds", 0))
	result["object_ref_skipped_count"] = int(update_stats.get("skipped", 0))

	if int(result.get("object_ref_overflow_count", 0)) > 0:
		_scene_voxel_tile_object_ref_rebuild_required = true
		_scene_voxel_tile_object_ref_overflow_count += int(result.get("object_ref_overflow_count", 0))
		result["object_ref_rebuild_required"] = true

	return result

func try_apply_gpu_autoobject_object_ref_update_pass_from_buffer(
	dirty_delta_buffer: RID,
	dirty_delta_count: int,
	dirty_delta_capacity: int = -1,
	dirty_delta_source: String = "borrowed_dirty_delta_buffer"
) -> Dictionary:
	var result := {
		"ok": false,
		"reason": "not_dispatched",
		"gpu_first": true,
		"cpu_fallback": false,
		"dirty_delta_bridge_mode": "explicit_scene_voxel_tile_object_ref_update_pass",
		"dirty_delta_apply_api": "try_apply_gpu_autoobject_object_ref_update_pass_from_buffer",
		"dirty_delta_count": maxi(dirty_delta_count, 0),
		"resident_gpu_dirty_delta_update_pass": false,
		"resident_gpu_dirty_delta_update_pass_owner": "none",
		"resident_gpu_dirty_delta_update_pass_shader": "none",
		"resident_gpu_dirty_delta_update_pass_dispatch_count": 0,
		"object_ref_update_result": {},
	}

	result.merge(get_gpu_autoobject_object_ref_range_policy_diagnostics(), true)
	result["object_ref_range_policy"] = "fixed_per_tile_object_ref_update_pass"
	result["object_ref_range_shader"] = SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_NAME
	result["object_ref_range_shader_path"] = SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_PATH
	result["object_ref_range_shader_ready"] = (
		_shader_scene_voxel_tile_object_ref_update.is_valid() and
		_pipeline_scene_voxel_tile_object_ref_update.is_valid()
	)

	if dirty_delta_count <= 0:
		result["reason"] = "empty_dirty_delta_batch"
		result["object_ref_update_reason"] = "empty_dirty_delta_batch"
		return result

	if not dirty_delta_buffer.is_valid():
		result["reason"] = "dirty_delta_buffer_not_ready"
		result["object_ref_update_reason"] = "dirty_delta_buffer_not_ready"
		return result

	if not ensure_scene_voxel_tile_buffers_uploaded(false):
		var skipped_summary := get_scene_voxel_tile_gpu_buffer_summary()
		var upload_reason := str(skipped_summary.get("reason", "scene_voxel_tile_buffer_upload_failed"))
		if upload_reason.is_empty():
			upload_reason = "scene_voxel_tile_buffer_upload_failed"
		result["reason"] = upload_reason
		result["object_ref_update_reason"] = upload_reason
		result["scene_voxel_tile_gpu_ready"] = false
		result["scene_voxel_tile_gpu_upload_status"] = str(skipped_summary.get("gpu_upload_status", "blocked"))
		result["scene_voxel_tile_gpu_skip_reason"] = str(skipped_summary.get("skip_reason", ""))
		return result

	var uploaded_summary := get_scene_voxel_tile_gpu_buffer_summary()
	result["scene_voxel_tile_gpu_ready"] = bool(uploaded_summary.get("runtime_ready", false))
	result["scene_voxel_tile_gpu_upload_status"] = str(uploaded_summary.get("gpu_upload_status", "ready"))
	result["object_ref_capacity"] = int(uploaded_summary.get("object_ref_capacity", result.get("object_ref_capacity", 0)))
	result["object_ref_tile_count"] = int(uploaded_summary.get("object_ref_tile_count", result.get("object_ref_tile_count", 0)))
	result["refs_per_tile"] = int(uploaded_summary.get("refs_per_tile", result.get("refs_per_tile", SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT)))

	var update_stats := _update_gpu_autoobject_object_refs_from_dirty_delta_buffer(
		dirty_delta_buffer,
		dirty_delta_count,
		dirty_delta_capacity,
		dirty_delta_source
	)
	var dispatched := bool(update_stats.get("gpu_dispatched", false))
	var dispatch_count := int(update_stats.get("dispatch_group_count", 0)) if dispatched else 0
	var ok := bool(update_stats.get("ok", false))
	var reason := str(update_stats.get("reason", "object_ref_update_failed"))

	result["ok"] = ok
	result["reason"] = reason
	result["object_ref_update_result"] = update_stats
	result["object_ref_update_stats_available"] = bool(update_stats.get("stats_available", false))
	result["object_ref_update_source"] = str(update_stats.get("source", "none"))
	result["object_ref_update_shader"] = str(update_stats.get("shader", SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_NAME))
	result["object_ref_update_reason"] = reason
	result["object_ref_update_gpu_dispatched"] = dispatched
	result["object_ref_update_dispatch_count"] = dispatch_count
	result["object_ref_update_dispatch_group_count"] = int(update_stats.get("dispatch_group_count", 0)) if dispatched else 0
	result["resident_gpu_dirty_delta_update_pass"] = ok and dispatched
	result["resident_gpu_dirty_delta_update_pass_owner"] = "SceneVoxelCommitter" if ok and dispatched else "none"
	result["resident_gpu_dirty_delta_update_pass_shader"] = SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_NAME if ok and dispatched else "none"
	result["resident_gpu_dirty_delta_update_pass_dispatch_count"] = dispatch_count
	result["object_ref_capacity"] = int(update_stats.get("object_ref_capacity", result.get("object_ref_capacity", 0)))
	result["object_ref_overflow_count"] = int(update_stats.get("overflow", 0))
	result["object_ref_non_numeric_count"] = int(update_stats.get("non_numeric", 0))
	result["object_ref_duplicate_count"] = int(update_stats.get("duplicate", 0))
	result["object_ref_touched_count"] = int(update_stats.get("touched", 0))
	result["object_ref_removed_slot_count"] = int(update_stats.get("removed_slots", 0))
	result["object_ref_inserted_slot_count"] = int(update_stats.get("inserted_slots", 0))
	result["object_ref_invalid_bounds_count"] = int(update_stats.get("invalid_bounds", 0))
	result["object_ref_skipped_count"] = int(update_stats.get("skipped", 0))

	if int(result.get("object_ref_overflow_count", 0)) > 0:
		_scene_voxel_tile_object_ref_rebuild_required = true
		_scene_voxel_tile_object_ref_overflow_count += int(result.get("object_ref_overflow_count", 0))
		result["object_ref_rebuild_required"] = true

	return result

func apply_gpu_autoobject_dirty_delta(delta: Dictionary, dispatch_object_ref_update: bool = false) -> Dictionary:

	if delta.is_empty():

		return {
			"ok": false,
			"reason": "empty_dirty_delta",
			"gpu_first": true,
			"cpu_fallback": false,
			"dirty_scene_voxel_tiles": _dirty_scene_voxel_tile_snapshot(),
		}

	var object_id := _scene_voxel_tile_gpu_autoobject_id(delta)

	if object_id.is_empty():

		return {
			"ok": false,
			"reason": "missing_object_id",
			"gpu_first": true,
			"cpu_fallback": false,
			"dirty_scene_voxel_tiles": _dirty_scene_voxel_tile_snapshot(),
		}

	var flags := SceneVoxelTileCodecScript.flags_from_value(delta.get("dirty_flags", {"auto": true, "object_refs": true}), "")

	flags["auto"] = true

	flags["object_refs"] = true

	var current_min_keys: Array[String] = ["new_voxel_min", "voxel_min", "bounds_min", "new_bounds_min"]

	var current_max_keys: Array[String] = ["new_voxel_max", "voxel_max", "bounds_max", "new_bounds_max"]

	var previous_min_keys: Array[String] = ["old_voxel_min", "previous_voxel_min", "old_bounds_min", "previous_bounds_min"]

	var previous_max_keys: Array[String] = ["old_voxel_max", "previous_voxel_max", "old_bounds_max", "previous_bounds_max"]

	var has_current_min := _scene_voxel_tile_has_any_key(delta, current_min_keys)

	var has_current_max := _scene_voxel_tile_has_any_key(delta, current_max_keys)

	var has_previous_min := _scene_voxel_tile_has_any_key(delta, previous_min_keys)

	var has_previous_max := _scene_voxel_tile_has_any_key(delta, previous_max_keys)

	var has_current_bounds := has_current_min and has_current_max

	var has_previous_bounds := has_previous_min and has_previous_max

	var removed := bool(delta.get("removed", delta.get("freed", delta.get("killed", false)))) or bool(delta.has("alive") and not bool(delta.get("alive", true)))

	if has_current_min != has_current_max or has_previous_min != has_previous_max or (not has_current_bounds and (not removed or not has_previous_bounds)):

		return {
			"ok": false,
			"reason": "missing_dirty_delta_bounds",
			"gpu_first": true,
			"cpu_fallback": false,
			"object_id": object_id,
			"dirty_scene_voxel_tiles": _dirty_scene_voxel_tile_snapshot(),
		}

	var new_min := _scene_voxel_tile_first_vector3i(delta, current_min_keys, _scene_voxel_tile_first_vector3i(delta, previous_min_keys, Vector3i.ZERO))

	var new_max := _scene_voxel_tile_first_vector3i(delta, current_max_keys, _scene_voxel_tile_first_vector3i(delta, previous_max_keys, new_min + Vector3i.ONE))

	var old_min := _scene_voxel_tile_first_vector3i(delta, previous_min_keys, new_min)

	var old_max := _scene_voxel_tile_first_vector3i(delta, previous_max_keys, new_max)

	var current_bounds := _scene_voxel_tile_normalized_bounds(new_min, new_max)

	var previous_bounds := _scene_voxel_tile_normalized_bounds(old_min, old_max)

	var source_record := {

		"object_id": object_id,

		"auto_object_id": object_id,

		"source_id": "gpu_autoobject:%s" % object_id,

	}

	mark_scene_voxel_tile_bounds_dirty(previous_bounds.voxel_min, previous_bounds.voxel_max, flags, source_record)

	if not removed:

		mark_scene_voxel_tile_bounds_dirty(current_bounds.voxel_min, current_bounds.voxel_max, flags, source_record)

		var ref_record := source_record.duplicate()

		ref_record["voxel_min"] = current_bounds.voxel_min

		ref_record["voxel_max"] = current_bounds.voxel_max

		ref_record["previous_voxel_min"] = previous_bounds.voxel_min

		ref_record["previous_voxel_max"] = previous_bounds.voxel_max

		ref_record["dirty_flags"] = flags.duplicate()

		ref_record["epoch"] = _scene_voxel_tile_epoch

		ref_record["removed"] = false

		_scene_voxel_tile_gpu_autoobject_refs[object_id] = ref_record

	else:

		_scene_voxel_tile_gpu_autoobject_refs.erase(object_id)

	_sv_dirty = true

	var result := {

		"ok": true,

		"reason": "ok",

		"gpu_first": true,

		"cpu_fallback": false,

		"object_id": object_id,

		"removed": removed,

		"dirty_flags": flags,

		"previous_voxel_min": previous_bounds.voxel_min,

		"previous_voxel_max": previous_bounds.voxel_max,

		"voxel_min": current_bounds.voxel_min,

		"voxel_max": current_bounds.voxel_max,

		"dirty_scene_voxel_tiles": _dirty_scene_voxel_tile_snapshot(),

	}
	if dispatch_object_ref_update:
		var object_ref_update := {
			"ok": false,
			"reason": "resident_object_ref_update_pass_not_enabled",
			"gpu_dispatched": false,
			"stats_available": false,
			"source": "none",
			"shader": "none",
		}
		result["object_ref_update_result"] = object_ref_update
		result.merge(get_gpu_autoobject_object_ref_range_policy_diagnostics(), true)
	return result

func apply_gpu_autoobject_dirty_deltas(deltas: Array) -> Dictionary:

	var results: Array[Dictionary] = []

	var ok := true

	var reason := "ok"

	var failed_count := 0

	for raw_delta in deltas:

		var commit_result: Dictionary = {}

		if raw_delta is Dictionary:

			commit_result = apply_gpu_autoobject_dirty_delta(raw_delta as Dictionary, false)

		else:

			commit_result = {
				"ok": false,
				"reason": "invalid_dirty_delta",
				"gpu_first": true,
				"cpu_fallback": false,
			}

		results.append(commit_result)

		if commit_result.is_empty() or not bool(commit_result.get("ok", false)):

			ok = false

			failed_count += 1

			if reason == "ok":

				reason = str(commit_result.get("reason", "dirty_delta_apply_failed"))
	var dirty_tiles := _dirty_scene_voxel_tile_snapshot()

	var object_ref_update := {
		"ok": false,
		"reason": "resident_object_ref_update_pass_not_enabled",
		"gpu_dispatched": false,
		"stats_available": false,
		"source": "none",
		"shader": "none",
	}

	var result := {
		"ok": ok,
		"reason": reason,
		"gpu_first": true,
		"cpu_fallback": false,
		"dirty_delta_bridge_mode": "cpu_batch_scene_voxel_tile_ref_dirty_bridge",
		"dirty_delta_apply_api": "apply_gpu_autoobject_dirty_deltas",
		"dirty_delta_count": deltas.size(),
		"results": results,
		"commit_result_count": results.size(),
		"failed_commit_result_count": failed_count,
		"dirty_scene_voxel_tiles": dirty_tiles,
		"dirty_scene_voxel_tile_count": dirty_tiles.size(),
		"resident_gpu_dirty_delta_update_pass": false,
		"resident_gpu_dirty_delta_update_pass_owner": "none",
		"resident_gpu_dirty_delta_update_pass_shader": "none",
		"resident_gpu_dirty_delta_update_pass_dispatch_count": 0,
		"object_ref_update_result": object_ref_update,
	}
	result.merge(get_gpu_autoobject_object_ref_range_policy_diagnostics(), true)
	return result

func get_dirty_scene_voxel_tiles() -> Dictionary:

	return _dirty_scene_voxel_tile_snapshot()

func get_scene_voxel_tiles() -> Dictionary:

	return _scene_voxel_tiles.duplicate(true)

func clear_sv_dirty() -> void:

	_sv_dirty_tiles.clear()

	_sv_dirty_rects.clear()

	_clear_scene_voxel_tile_dirty_flags()

	if not _sv.is_empty():

		_sv["dirty_tile_count"] = 0

		_sv["dirty_tiles"] = {}

		_sv["dirty_scene_voxel_tile_count"] = 0

		_sv["dirty_scene_voxel_tiles"] = {}

		_sv["dirty_rects"] = []

		_sv["scene_voxel_tile_gpu_autoobject_ref_count"] = _scene_voxel_tile_gpu_autoobject_refs.size()

	_maybe_auto_upload_scene_voxel_tile_buffers("clear_sv_dirty")

	_publish_scene_voxel_tile_gpu_summary_to_sv()

func get_committed_tick() -> int:

	return _committed_tick

func get_last_blend_scene_voxel_commit_summary() -> Dictionary:

	return _last_blend_scene_voxel_commit_summary.duplicate(true)

func get_last_scene_voxel_source_resolve_summary() -> Dictionary:

	return _last_scene_voxel_source_resolve_summary.duplicate(true)

func get_generation_tick() -> int:

	return _generation_tick

func get_scene_voxel(slice_index: int, voxel_xz: Vector2i) -> Dictionary:

	if _volume.is_empty():

		return {}

	var scene_voxels: Dictionary = _volume.get("scene_voxels", {})

	var key := SceneVoxelSourceRecordScript.scene_voxel_key(slice_index, voxel_xz)

	var scene_voxel = scene_voxels.get(key, {})

	if scene_voxel is Dictionary:

		return SceneVoxelPayloadScript.public_payload(scene_voxel as Dictionary)

	return {}

## Get a specific Y-slice Image from the volume.

func get_voxel_slice(slice_index: int) -> Image:

	if _volume.is_empty() or slice_index < 0 or slice_index >= _volume.total_slices:

		return Image.create(1, 1, false, Image.FORMAT_RF)

	return _volume.slices[slice_index]

## Get metadata for a specific slice.

func get_voxel_slice_meta(slice_index: int) -> Dictionary:

	if _volume.is_empty() or slice_index < 0 or slice_index >= _volume.total_slices:

		return {}

	return _volume.slice_meta[slice_index]

## Get total number of slices in the volume.

func get_voxel_slice_count() -> int:

	if _volume.is_empty():

		return 0

	return _volume.total_slices

## Get full volume stats for debug.

func _empty_rf_image() -> Image:
	var img := Image.create(1, 1, false, Image.FORMAT_RF)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	return img

func _voxel_reduce_slice_images(xz_res: int, total_slices: int) -> Array:
	if _volume.is_empty():
		return []

	var slices: Array = _volume.get("slices", [])
	if slices.size() != total_slices:
		return []

	var out: Array = []
	for raw_img in slices:
		if not raw_img is Image:
			return []
		var img: Image = raw_img
		if img == null or img.is_empty() or img.get_width() != xz_res or img.get_height() != xz_res:
			return []
		out.append(img)
	return out

func _voxel_reduce_collision_image(xz_res: int) -> Image:
	var raw_collision = _volume.get("collision_field", null) if not _volume.is_empty() else null
	var collision_img: Image = null
	if raw_collision is Image:
		collision_img = raw_collision
	if collision_img == null or collision_img.is_empty():
		collision_img = _resample_collision_field(_collision_field, xz_res)
	if collision_img == null or collision_img.is_empty():
		return _empty_rf_image()
	if collision_img.get_width() != xz_res or collision_img.get_height() != xz_res:
		collision_img = _resample_collision_field(collision_img, xz_res)
	if collision_img == null or collision_img.is_empty():
		return _empty_rf_image()
	return collision_img

func _reduce_scene_voxel_stats_gpu(xz_res: int, total_slices: int) -> Dictionary:
	var voxel_count := xz_res * xz_res * total_slices
	if voxel_count <= 0:
		return {}
	if not _gpu_ready or _rd == null or not _sampler.is_valid():
		return {}
	if not _shader_reduce_scene_voxel_stats.is_valid() or not _pipeline_reduce_scene_voxel_stats.is_valid():
		return {}

	var scene_voxels: Dictionary = _volume.get("scene_voxels", {})
	var use_scene_buffer := false
	var scene_source := "volume_slice_texture"
	var scene_field := PackedFloat32Array()
	if not scene_voxels.is_empty():
		scene_field = _scene_voxel_tile_packed_float_field(_sv.get("scene_field", PackedFloat32Array())) if not _sv.is_empty() else PackedFloat32Array()
		if scene_field.size() != voxel_count:
			scene_field = _try_make_sv_scene_field_from_source_streams_gpu(xz_res, total_slices)
		if scene_field.size() != voxel_count:
			return {}
		use_scene_buffer = true
		scene_source = "resident_scene_field_buffer"

	var scene_slices := _voxel_reduce_slice_images(xz_res, total_slices)
	if use_scene_buffer:
		if scene_slices.is_empty():
			scene_slices = [_empty_rf_image()]
	else:
		if scene_slices.is_empty():
			return {}
		scene_field.resize(1)

	var scene_buffer := storage_buffer_from_floats(scene_field, SCOPE_FRAME, "voxel_stats_scene_field")
	var scene_tex := upload_texture_3d_from_images(
		scene_slices,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		Image.FORMAT_RF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		SCOPE_FRAME,
		"voxel_stats_scene_slices"
	)
	var collision_img := _voxel_reduce_collision_image(xz_res)
	var collision_tex := upload_texture_2d(
		collision_img,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		Image.FORMAT_RF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		SCOPE_FRAME,
		"voxel_stats_collision_field"
	)
	var count_slots := total_slices + 1
	var counts_buffer := storage_buffer_zero(count_slots * 4, SCOPE_FRAME, "voxel_stats_counts")
	if not scene_buffer.is_valid() or not scene_tex.is_valid() or not collision_tex.is_valid() or not counts_buffer.is_valid():
		gc_frame()
		return {}

	var set0 := create_uniform_set([
		make_storage_uniform(0, scene_buffer),
		make_sampler_uniform(1, _sampler, scene_tex),
		make_sampler_uniform(2, _sampler, collision_tex),
		make_storage_uniform(3, counts_buffer),
	], _shader_reduce_scene_voxel_stats, 0, SCOPE_PASS, "reduce_scene_voxel_stats")
	if not set0.is_valid():
		gc_frame()
		return {}

	var push := PackedByteArray()
	push.resize(48)
	push.encode_s32(0, xz_res)
	push.encode_s32(4, total_slices)
	push.encode_s32(8, voxel_count)
	push.encode_s32(12, count_slots)
	push.encode_s32(16, 1 if use_scene_buffer else 0)
	push.encode_s32(20, collision_img.get_width())
	push.encode_s32(24, collision_img.get_height())
	push.encode_s32(28, 0)
	push.encode_float(32, VOXEL_OCCUPIED_EPSILON)
	push.encode_float(36, 0.0)
	push.encode_float(40, 0.0)
	push.encode_float(44, 0.0)

	var groups := dispatch_groups_1d(voxel_count, 64)
	if not _gpu_dispatch_and_sync(_pipeline_reduce_scene_voxel_stats, [set0], push, groups):
		gc_frame()
		return {}

	var count_bytes := _rd.buffer_get_data(counts_buffer, 0, count_slots * 4)
	gc_frame()

	var per_slice_counts: Array[int] = []
	var occupied_voxels := 0
	for i in range(total_slices):
		var offset := i * 4
		var count := int(count_bytes.decode_u32(offset)) if offset + 4 <= count_bytes.size() else 0
		per_slice_counts.append(count)
		occupied_voxels += count
	var collision_offset := total_slices * 4
	var collision_count := int(count_bytes.decode_u32(collision_offset)) if collision_offset + 4 <= count_bytes.size() else 0

	return {
		"ok": true,
		"per_slice_counts": per_slice_counts,
		"occupied_voxels": occupied_voxels,
		"collision": collision_count,
		"stats_source": scene_source,
		"gpu_dispatched": true,
		"cpu_fallback": false,
	}

func get_voxel_stats() -> Dictionary:
	if _volume.is_empty():
		return {}

	var xz_res: int = _volume.xz_res
	var slices: Array = _volume.get("slices", [])
	var meta: Array = _volume.get("slice_meta", [])
	var total_slices := int(_volume.get("total_slices", slices.size()))
	var reduced := _reduce_scene_voxel_stats_gpu(xz_res, total_slices)
	if reduced.is_empty():
		push_error("[SceneVoxelCommitter] Voxel stats GPU reduce failed")
		return {}

	var per_slice_counts: Array = reduced.get("per_slice_counts", [])
	var total_voxels := xz_res * xz_res * total_slices
	var occupied_voxels := int(reduced.get("occupied_voxels", 0))
	var collision := int(reduced.get("collision", 0))
	var per_slice: Array[Dictionary] = []
	var slice_total := xz_res * xz_res
	for i in range(total_slices):
		var m: Dictionary = {}
		if i < meta.size() and meta[i] is Dictionary:
			m = meta[i]
		var count := int(per_slice_counts[i]) if i < per_slice_counts.size() else 0
		per_slice.append({
			"slice": i,
			"channel": int(m.get("channel", -1)),
			"y_range": "%.2f-%.2fm" % [float(m.get("y_min", 0.0)), float(m.get("y_max", 0.0))],
			"occupied": "%d/%d (%.1f%%)" % [count, slice_total, float(count) / float(slice_total) * 100.0] if slice_total > 0 else "0/0 (0.0%)",
			"color": m.get("color", Color.WHITE),
			"complexity": m.get("complexity", 0.0),
		})

	return {
 
		"xz_resolution": xz_res,
 
		"total_slices": total_slices,
 
		"grid_size": grid_size,

		"voxel_size": voxel_size,

		"grid_origin": grid_origin,

		"voxel_size_xz": "%.2fm" % [voxel_size.x],

		"total_voxels": total_voxels,

		"occupied_voxels": occupied_voxels,

		"collision": collision,

		"collision_field_pct": "%.1f%%" % [float(collision) / float(xz_res * xz_res) * 100.0] if xz_res > 0 else "0%",

		"scene_voxels": int(_volume.get("scene_voxels", {}).size()),

		"sv_tiles": int(get_sv().get("tile_count", 0)),

		"generation_tick": _generation_tick,

		"committed_tick": _committed_tick,

		"occupancy_pct": "%.1f%%" % [float(occupied_voxels) / float(total_voxels) * 100.0] if total_voxels > 0 else "0%",
 
		"per_slice": per_slice,

		"gpu_dispatched": true,

		"cpu_fallback": false,

		"stats_source": str(reduced.get("stats_source", "unknown")),
 
	}

func reset_occupancy() -> void:

	_occupancy.fill(Color(0.0, 0.0, 0.0, 0.0))

	_collision_field.fill(Color(0.0, 0.0, 0.0, 0.0))

	_volume = {}

	_voxel_write_specs.clear()

	_voxel_write_spec_index.clear()

	_scene_state_by_tick.clear()

	_scene_source_metadata.clear()

	_clear_scene_voxel_source_streams()

	_sv.clear()

	_sv_dirty_tiles.clear()

	_sv_dirty_rects.clear()

	_scene_voxel_tiles.clear()

	_scene_voxel_tile_gpu_autoobject_refs.clear()

	_scene_voxel_tile_object_ids_debug.clear()

	_scene_voxel_tile_source_ids_debug.clear()

	_scene_voxel_tile_object_ref_last_update_stats.clear()

	_scene_voxel_tile_fixed_object_ref_tile_count = 0

	_scene_voxel_tile_fixed_object_ref_slot_count = 0

	_scene_voxel_tile_object_ref_rebuild_required = false

	_scene_voxel_tile_object_ref_overflow_count = 0

	_scene_voxel_tile_object_ref_overflow_tile_ids.clear()

	_scene_voxel_tile_epoch = 0

	_release_scene_voxel_tile_gpu_buffers()

	_mark_scene_voxel_tile_staging_dirty("reset_occupancy")

	_generation_tick = 1

	_committed_tick = 0

	_sv_dirty = true

func validate_voxel(params: Dictionary = {}) -> Dictionary:
	if _volume.is_empty():
		return {"passed": false, "reason": "No voxel volume built", "metrics": {}}

	var min_channel_occupancy: Dictionary = params.get("min_channel_occupancy", {})
	var max_channel_occupancy: Dictionary = params.get("max_channel_occupancy", {})
	var min_diversity: int = params.get("min_diversity_score", 2)
	var xz_res: int = _volume.xz_res
	var slices: Array = _volume.get("slices", [])
	var meta: Array = _volume.get("slice_meta", [])
	var total_slices := int(_volume.get("total_slices", slices.size()))
	var reduced := _reduce_scene_voxel_stats_gpu(xz_res, total_slices)
	if reduced.is_empty():
		return {
			"passed": false,
			"reason": "Voxel validation GPU reduce failed",
			"metrics": {
				"gpu_dispatched": false,
				"cpu_fallback": false,
			},
		}

	var channel_counts: Array[int] = []
	var channel_totals: Array[int] = []
	for _i in range(CHANNEL_COUNT):
		channel_counts.append(0)
		channel_totals.append(0)

	var per_slice_counts: Array = reduced.get("per_slice_counts", [])
	var slice_total := xz_res * xz_res
	for i in range(total_slices):
		var m: Dictionary = {}
		if i < meta.size() and meta[i] is Dictionary:
			m = meta[i]
		var ch := int(m.get("channel", -1))
		if ch < 0 or ch >= CHANNEL_COUNT:
			continue
		channel_totals[ch] += slice_total
		channel_counts[ch] += int(per_slice_counts[i]) if i < per_slice_counts.size() else 0

	var channel_occ: Array[float] = []
	for ch in range(CHANNEL_COUNT):
		var pct := float(channel_counts[ch]) / float(channel_totals[ch]) * 100.0 if channel_totals[ch] > 0 else 0.0
		channel_occ.append(pct)

	var diversity := 0
	for pct in channel_occ:
		if pct > 1.0:
			diversity += 1

	var metrics := {
		"channel_occupancy_pct": channel_occ,
		"channels": range(CHANNEL_COUNT),
		"diversity_score": diversity,
		"gpu_dispatched": true,
		"cpu_fallback": false,
		"stats_source": str(reduced.get("stats_source", "unknown")),
	}

	for raw_channel in min_channel_occupancy.keys():
		var ch := int(raw_channel)
		var min_occ := float(min_channel_occupancy[raw_channel])
		var occ := channel_occ[ch] if ch >= 0 and ch < channel_occ.size() else 0.0
		if occ < min_occ:
			return {"passed": false, "reason": "Channel %d occupancy too low: %.1f%% < %.1f%%" % [ch, occ, min_occ], "metrics": metrics}

	for raw_channel in max_channel_occupancy.keys():
		var ch := int(raw_channel)
		var max_occ := float(max_channel_occupancy[raw_channel])
		var occ := channel_occ[ch] if ch >= 0 and ch < channel_occ.size() else 0.0
		if occ > max_occ:
			return {"passed": false, "reason": "Channel %d occupancy too high: %.1f%% > %.1f%%" % [ch, occ, max_occ], "metrics": metrics}

	if diversity < min_diversity:
		return {"passed": false, "reason": "Diversity too low: %d < %d channels active" % [diversity, min_diversity], "metrics": metrics}

	return {"passed": true, "reason": "OK", "metrics": metrics}

## Export the volume as a vertical column at pixel (px, pz) for debug.

## Returns Array[Dictionary], one per slice from bottom to top.

func get_voxel_column(px: int, pz: int) -> Array[Dictionary]:
	return SceneVoxelValidationScript.voxel_column(_volume, px, pz)
