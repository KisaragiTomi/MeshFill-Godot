class_name SceneVoxelCommitter

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

var _base_res: int  ## Base resolution for world↔pixel coordinate mapping

var _capture_size: float

var grid_size: Vector3i  ## SV grid dimensions in voxels

var voxel_size: Vector3  ## World-space size of one voxel

var grid_origin: Vector3  ## World-space origin for voxel index conversion

## Packed RGBA completely field: one value per explicit channel, representing how completely each voxel is filled.
## When max(complexity, collision) == 0, the voxel is empty (nothing there).


## Source collision scalar field generated through the shared max-stamp path.

## Terrain base remains a separate input; both are published as one resident collision field.


## Authoritative terrain/base collision input layer.


## Resident collision read field: max(TerrainBaseCollision, source collision field).


## GPU resources

var _sampler: RID

















var _shader_score_scene_voxel_feedback: RID

var _pipeline_score_scene_voxel_feedback: RID

var _shader_reduce_scene_voxel_stats: RID

var _pipeline_reduce_scene_voxel_stats: RID















var _gpu_ready: bool = false

## 场景体素瓦片 GPU 缓冲存储子系统(Stage 1 抽出)
const SceneVoxelTileStoreScript := preload("res://scripts/scene_voxel_tile_store.gd")
var _tile_store: SceneVoxelTileStoreScript = null

## 场景体素来源候选/commit 子系统(Stage 2 抽出)
const SceneVoxelSourceStagingScript := preload("res://scripts/scene_voxel_source_staging.gd")
var _source_staging: SceneVoxelSourceStagingScript = null

## 碰撞/占据场与盖章子系统(Stage 3 抽出)
const SceneVoxelCollisionFieldScript := preload("res://scripts/scene_voxel_collision_field.gd")
var _field_builder: SceneVoxelCollisionFieldScript = null

## --- occupancy/collision field 转发属性(真实存储在 _field_builder) ---
var occupancy: Image:
	get:
		return _field_builder.occupancy if _field_builder else null
	set(value):
		if _field_builder:
			_field_builder.occupancy = value
var _source_collision_field: Image:
	get:
		return _field_builder._source_collision_field if _field_builder else null
	set(value):
		if _field_builder:
			_field_builder._source_collision_field = value
var _terrain_base_collision_field: Image:
	get:
		return _field_builder._terrain_base_collision_field if _field_builder else null
	set(value):
		if _field_builder:
			_field_builder._terrain_base_collision_field = value
var _collision_field: Image:
	get:
		return _field_builder._collision_field if _field_builder else null
	set(value):
		if _field_builder:
			_field_builder._collision_field = value


## 初始化体素提交器，设置基础分辨率、捕获范围并按需启用 GPU
func _init(base_resolution: int, capture_size: float, _enable_gpu: bool = true) -> void:

	_base_res = base_resolution

	_capture_size = capture_size

	_tile_store = SceneVoxelTileStoreScript.new()

	_tile_store._committer = self

	_source_staging = SceneVoxelSourceStagingScript.new()

	_source_staging._committer = self

	_field_builder = SceneVoxelCollisionFieldScript.new()

	_field_builder._committer = self

	_register_scene_voxel_tile_project_settings()

	grid_origin = _default_grid_origin()

	voxel_size = _voxel_size_for_resolution(_base_res, 1.0)

	grid_size = Vector3i(_base_res, 1, _base_res)

	occupancy = Image.create(_base_res, _base_res, false, Image.FORMAT_RGBAH)

	occupancy.fill(Color(0.0, 0.0, 0.0, 0.0))

	_source_collision_field = _create_collision_image(_base_res)

	_terrain_base_collision_field = _create_collision_image(_base_res)

	_collision_field = _create_collision_image(_base_res)

	_init_gpu()

	_tile_store.attach_rendering_device(_rd, false)

	_tile_store.setup(self, _base_res)

	_source_staging.attach_rendering_device(_rd, false)

	_source_staging.setup(self, _base_res)

	_field_builder.attach_rendering_device(_rd, false)

	_field_builder.setup(self, _base_res)

## 初始化 GPU 资源，加载全部 compute shader 并构建管线，校验资源完整性
func _init_gpu() -> void:

	log_name = "SceneVoxelCommitter"

	if not ensure_device(true, false):

		_gpu_fatal("Failed to create RenderingDevice — GPU compute required")

		return

	_sampler = create_linear_sampler()





















	_shader_score_scene_voxel_feedback = load_compute_shader("res://shaders/score_scene_voxel_feedback.glsl")

	if _shader_score_scene_voxel_feedback.is_valid():

		_pipeline_score_scene_voxel_feedback = create_compute_pipeline(_shader_score_scene_voxel_feedback)

	_shader_reduce_scene_voxel_stats = load_compute_shader("res://shaders/reduce_scene_voxel_stats.glsl")

	if _shader_reduce_scene_voxel_stats.is_valid():

		_pipeline_reduce_scene_voxel_stats = create_compute_pipeline(_shader_reduce_scene_voxel_stats)






















	var missing_gpu_rids: Array[String] = []

	if not _sampler.is_valid():

		missing_gpu_rids.append("sampler")


		missing_gpu_rids.append("shader_import")


		missing_gpu_rids.append("pipeline_import")


		missing_gpu_rids.append("shader_filter")


		missing_gpu_rids.append("pipeline_filter")


		missing_gpu_rids.append("shader_max_collision")


		missing_gpu_rids.append("pipeline_max_collision")









		missing_gpu_rids.append("shader_stamp_r32_disc")

		missing_gpu_rids.append("pipeline_stamp_r32_disc")

		missing_gpu_rids.append("shader_stamp_rgba_channel_disc")

		missing_gpu_rids.append("pipeline_stamp_rgba_channel_disc")

		missing_gpu_rids.append("shader_merge_sv_collision_records")

		missing_gpu_rids.append("pipeline_merge_sv_collision_records")
	if not _shader_score_scene_voxel_feedback.is_valid():

		missing_gpu_rids.append("shader_score_scene_voxel_feedback")
	if not _pipeline_score_scene_voxel_feedback.is_valid():

		missing_gpu_rids.append("pipeline_score_scene_voxel_feedback")
	if not _shader_reduce_scene_voxel_stats.is_valid():

		missing_gpu_rids.append("shader_reduce_scene_voxel_stats")
	if not _pipeline_reduce_scene_voxel_stats.is_valid():

		missing_gpu_rids.append("pipeline_reduce_scene_voxel_stats")











		missing_gpu_rids.append("shader_stamp_collect_voxel_disc")

		missing_gpu_rids.append("pipeline_stamp_collect_voxel_disc")

		missing_gpu_rids.append("shader_sample_r32_pixel")

		missing_gpu_rids.append("pipeline_sample_r32_pixel")

	_gpu_ready = missing_gpu_rids.is_empty()

	if _gpu_ready:

		print("[SceneVoxelCommitter] GPU compute ready (2 shaders; tile/source/collision → 3 subsystems)")

	else:

		_gpu_fatal("Scene voxel compute resources are not ready: %s" % ", ".join(missing_gpu_rids))

## 报告 GPU 致命错误，弹出提示并标记 GPU 未就绪
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

## 释放所有 GPU shader 与管线资源并重置 GPU 就绪状态
func _free_gpu() -> void:

	dispose()
















	_pipeline_score_scene_voxel_feedback = RID()

	_shader_score_scene_voxel_feedback = RID()

	_pipeline_reduce_scene_voxel_stats = RID()

	_shader_reduce_scene_voxel_stats = RID()















	_sampler = RID()

	_gpu_ready = false

## 释放前回调，清理场景体素 tile 与 source candidate 的常驻 GPU 缓冲
func _on_before_dispose() -> void:

	if _source_staging != null:
		_source_staging.teardown()
		_source_staging = null

	if _field_builder != null:
		_field_builder.teardown()
		_field_builder = null

	if _tile_store != null:
		_tile_store.teardown()
		_tile_store = null

## 返回基于捕获尺寸的默认网格原点
func _default_grid_origin() -> Vector3:

	return VoxelGeneralScript.default_grid_origin(_capture_size)

## 根据分辨率计算单个体素的世界空间尺寸
func _voxel_size_for_resolution(resolution: int, y_size: float = 1.0) -> Vector3:

	return VoxelGeneralScript.voxel_size_for_resolution(_capture_size, resolution, y_size)

## 配置场景体素网格的尺寸、体素大小与原点，并按需标记重建脏标记
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

## 从给定场景体素对象读取网格参数并应用配置
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

## 根据体积分辨率与切片数应用网格元数据，更新尺寸并标记全量重建
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

## 创建指定分辨率的空白 R32 碰撞图像
func _slice_voxel_size_y(slice_index: int = 0) -> float:

	if _volume.is_empty():

		return maxf(voxel_size.y, 0.0001)

	var meta: Array = _volume.get("slice_meta", [])

	if slice_index >= 0 and slice_index < meta.size() and meta[slice_index] is Dictionary:

		var m := meta[slice_index] as Dictionary

		return maxf(float(m.get("y_max", 1.0)) - float(m.get("y_min", 0.0)), 0.0001)

	return maxf(voxel_size.y, 0.0001)

## 将世界坐标转换为体素索引坐标
func world_to_voxel(world_pos: Vector3, resolution: int = -1) -> Vector3i:

	var res := maxi(resolution if resolution > 0 else _base_res, 1)

	var size := _voxel_size_for_resolution(res, voxel_size.y)

	return VoxelGeneralScript.world_to_voxel(
		world_pos,
		grid_origin,
		size,
		Vector3i(res, maxi(grid_size.y, 1), res),
		false
	)

## 将体素索引坐标转换为世界坐标
func voxel_to_world(voxel_pos: Vector3i, resolution: int = -1) -> Vector3:

	var res := maxi(resolution if resolution > 0 else _base_res, 1)

	var size := _voxel_size_for_resolution(res, voxel_size.y)

	return VoxelGeneralScript.voxel_to_world(voxel_pos, grid_origin, size)

## 将世界坐标转换为体积分辨率下的 XZ 像素坐标
func world_to_volume_pixel(world_pos: Vector3, resolution: int = -1) -> Vector2i:

	var res := maxi(resolution if resolution > 0 else _base_res, 1)

	return VoxelGeneralScript.world_to_volume_pixel(
		world_pos,
		res,
		grid_origin,
		_voxel_size_for_resolution(res, voxel_size.y)
	)

## 将体积分辨率下的 XZ 像素坐标转换回世界坐标
func volume_pixel_to_world(voxel_xz: Vector2i, resolution: int = -1, y: float = 0.0) -> Vector3:

	var res := maxi(resolution if resolution > 0 else _base_res, 1)

	var size := _voxel_size_for_resolution(res, voxel_size.y)

	return VoxelGeneralScript.volume_pixel_to_world(voxel_xz, grid_origin, size, y)

## 静态方法：将体素中心坐标转换为世界坐标（XZ 平面）
static func voxel_center_to_world_static(voxel_pos: Vector3i, p_grid_origin: Vector3, p_voxel_size: Vector3, y: float = 0.0) -> Vector3:

	return VoxelGeneralScript.voxel_center_to_world_xz(voxel_pos, p_grid_origin, p_voxel_size, y)

## 静态方法：将浮点体素中心坐标转换为世界坐标（XZ 平面）
static func voxel_float_center_to_world_static(voxel_center: Vector3, p_grid_origin: Vector3, p_voxel_size: Vector3, y: float = 0.0) -> Vector3:

	return VoxelGeneralScript.voxel_float_center_to_world_xz(voxel_center, p_grid_origin, p_voxel_size, y)

## 判断通道索引是否在有效范围内
func _is_valid_channel(channel: int) -> bool:

	return VoxelGeneralScript.is_valid_channel(channel)

## 导入掩码图像到指定通道，按复杂度混合进 occupancy
func _radius_to_px(radius_m: float) -> int:

	return VoxelGeneralScript.world_radius_to_texture_radius(radius_m, _capture_size, _base_res)

## 在图像上盖印一个圆形标量区域，失败时回退返回原图
func _vector3i_from_value(value, fallback: Vector3i = Vector3i.ZERO) -> Vector3i:

	return VoxelGeneralScript.vector3i_from_value(value, fallback)

## 从碰撞记录中提取本地体素坐标
func get_voxel_write_specs() -> Array[Dictionary]:

	var records: Array[Dictionary] = []

	for record in _voxel_write_specs:

		var typed_record := record as Dictionary

		records.append(typed_record.duplicate(true))

	return records

## Get one placed mesh voxel_write_spec by id.

## 按网格ID获取单条体素写入规格记录
func get_voxel_write_spec(mesh_id: String) -> Dictionary:

	if not _voxel_write_spec_index.has(mesh_id):

		return {}

	var idx: int = _voxel_write_spec_index[mesh_id]

	var record: Dictionary = _voxel_write_specs[idx]

	return record.duplicate(true)

## 返回已注册体素写入规格的数量
func get_voxel_write_spec_count() -> int:

	return _voxel_write_specs.size()

## 从记录中读取有效通道索引，无效返回 -1
func _record_channel(record: Dictionary) -> int:
	var ch := int(record.get("channel", -1))
	if not _is_valid_channel(ch):
		return -1
	return ch

## 从记录中读取或换算像素半径，至少为 1
func _record_radius_px(record: Dictionary) -> int:
	if record.has("radius_px"):
		return maxi(int(record.radius_px), 1)
	if record.has("radius"):
		return _radius_to_px(float(record.radius))
	return 1

## 将基础像素坐标转换为体积分辨率下的像素坐标
func _volume_px_from_base(base_px: Vector2i, xz_res: int) -> Vector2i:

	return VoxelGeneralScript.base_pixel_to_volume_pixel(base_px, _base_res, xz_res)

## 将基础分辨率像素半径转换为体积分辨率像素半径
func _volume_radius_from_base_radius(radius_px: int, xz_res: int) -> int:

	return VoxelGeneralScript.base_radius_to_volume_radius(radius_px, _base_res, xz_res)

## 计算下一个写入 tick，取生成 tick 或已提交 tick+1
func _next_write_tick() -> int:

	return _generation_tick if _generation_tick > _committed_tick else _committed_tick + 1

## 开始一个生成 tick，标记场景体素为脏并返回该 tick
func begin_generation_tick(tick: int = -1) -> int:

	var write_tick := tick if tick >= 0 else _next_write_tick()

	_generation_tick = write_tick

	_sv_dirty = true

	return write_tick

## 根据记录与通道返回对应的切片索引列表
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

## 注册场景体素 tile 尺寸的项目设置
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

## 重置所有 tile 的摘要统计字段并标记暂存脏
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

	_sv["scene_voxel_tile_summary_gpu_rid"] = get_scene_voxel_tile_summary_gpu_buffer()

## 设置GPU自动上传开关并可选立即上传
func _sv_tile_key(slice_index: int, voxel_px: Vector2i, layer: String = "scene", tile_size: int = SV_RESIDENT_TILE_SIZE) -> String:
	return SceneVoxelTileCodecScript.sv_tile_key(slice_index, voxel_px, layer, tile_size)

## 计算SV瓦片的XZ边界矩形
func _sv_tile_bounds(voxel_px: Vector2i, tile_size: int = SV_RESIDENT_TILE_SIZE) -> Rect2i:
	return SceneVoxelTileCodecScript.sv_tile_bounds(voxel_px, tile_size)

## 标记指定SV瓦片为脏并可选联动场景体素瓦片
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

## 将矩形裁剪到基础分辨率范围内
func _clip_base_rect(rect: Rect2i) -> Rect2i:

	return rect.intersection(Rect2i(0, 0, _base_res, _base_res))

## 标记矩形区域内所有SV瓦片为脏
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

## 打包场景体素提交的源流数值
func _mark_target_guidance_dirty(record: Dictionary) -> void:

	var bounds := _scene_voxel_tile_bounds_from_record(record)

	mark_scene_voxel_tile_bounds_dirty(bounds.voxel_min, bounds.voxel_max, SceneVoxelTargetScript.target_dirty_flags(), {})

## 把线性索引转换为瓦片网格三维坐标
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

## 在GPU上对复杂度与碰撞场做体素瓦片摘要归约与紧凑化
func _rebuild_sv(tile_size: int = SV_RESIDENT_TILE_SIZE) -> Dictionary:

	if _volume.is_empty():

		_sv = {}

		return {}

	var xz_res: int = _volume.xz_res

	var total_slices := int(_volume.get("total_slices", grid_size.y))

	var scene_voxels: Dictionary = _volume.get("scene_voxels", {})

	var collision: Dictionary = _volume.get("collision", {})

	var expected_complexity_field_count := xz_res * xz_res * total_slices

	var complexity_field_buffer_scope := "_rebuild_sv_complexity_field_buffer"

	gc_scope(complexity_field_buffer_scope)

	var complexity_field_result := _try_make_sv_complexity_field_from_source_streams_gpu_result(xz_res, total_slices, complexity_field_buffer_scope)

	var complexity_field: PackedFloat32Array = complexity_field_result.get("field", PackedFloat32Array())

	var complexity_field_buffer: RID = complexity_field_result.get("complexity_field_buffer", RID())

	var complexity_field_source := str(complexity_field_result.get("complexity_field_source", complexity_field_result.get("source_stream_buffer_source", "auto_brush_source_stream_compute")))
	var complexity_field_runtime_read_source := str(complexity_field_result.get("complexity_field_runtime_read_source", "none"))
	var complexity_field_projection_mode := str(complexity_field_result.get("complexity_field_projection_mode", "auto_brush_source_stream_scatter"))
	var complexity_field_committed_payload_projection := bool(complexity_field_result.get("complexity_field_committed_payload_projection", false))
	var complexity_field_committed_payload_count := int(complexity_field_result.get("complexity_field_committed_payload_count", 0))
	var complexity_field_committed_key_coord_count := int(complexity_field_result.get("complexity_field_committed_key_coord_count", 0))
	var complexity_field_final_source_stream_resident := bool(complexity_field_result.get("final_source_stream_resident", false))
	var complexity_field_final_source_stream_epoch := int(complexity_field_result.get("final_source_stream_resident_epoch", 0))

	if complexity_field.size() != expected_complexity_field_count and not complexity_field_buffer.is_valid():
		## Complexity field compute failed and no resident buffer RID available as fallback.
		push_error("[SceneVoxelCommitter] SV complexity field compute failed")
		complexity_field = PackedFloat32Array()
		complexity_field_buffer = RID()
		complexity_field_source = "auto_brush_source_stream_compute_failed"
		complexity_field_runtime_read_source = "none"
		complexity_field_projection_mode = "failed"
		complexity_field_committed_payload_projection = false
		complexity_field_committed_payload_count = 0
		complexity_field_committed_key_coord_count = 0
		complexity_field_final_source_stream_resident = false
		complexity_field_final_source_stream_epoch = 0

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
		"voxel_count": expected_complexity_field_count,
	}
	if complexity_field_buffer.is_valid():
		summary_buffer_contract["complexity_field_buffer"] = complexity_field_buffer
	if collision_summary_buffer.is_valid():
		summary_buffer_contract["collision_field_buffer"] = collision_summary_buffer

	var scene_voxel_tile_summary := _reduce_scene_voxel_tile_summaries_gpu(
		complexity_field,
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
		complexity_field,
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

	gc_scope(complexity_field_buffer_scope)

	gc_scope(collision_summary_buffer_scope)

	_rebuild_scene_voxel_tile_source_refs()

	dirty_scene_voxel_tiles_snapshot = _dirty_scene_voxel_tile_snapshot()
	if not dirty_scene_voxel_tiles_snapshot.is_empty():
		_tile_store._scene_voxel_tile_pending_resident_upload_tiles = dirty_scene_voxel_tiles_snapshot.duplicate(true)

	var committed_payload_summary := get_committed_scene_voxel_payload_buffer_summary()

	_sv = {

		"type": "SV",

		"gpu_first": true,

		"cpu_fallback": false,

		"runtime_read_source": "none",

		"complexity_field_runtime_read_source": complexity_field_runtime_read_source,

		"complexity_field_buffer_resident": complexity_field_buffer.is_valid(),
		"complexity_field_buffer_rid": str(complexity_field_buffer) if complexity_field_buffer.is_valid() else "none",

		"collision_field_runtime_read_source": "resident_gpu_buffer" if collision_summary_buffer.is_valid() else "cpu_computed",

		"complexity_field_staging_source": "sv_owner_control_snapshot",

		"complexity_field_source": complexity_field_source,

		"complexity_field_projection_mode": complexity_field_projection_mode,

		"complexity_field_committed_payload_projection": complexity_field_committed_payload_projection,

		"complexity_field_committed_payload_count": complexity_field_committed_payload_count,

		"complexity_field_committed_key_coord_count": complexity_field_committed_key_coord_count,

		"complexity_field_final_source_stream_resident": complexity_field_final_source_stream_resident,

		"complexity_field_final_source_stream_resident_epoch": complexity_field_final_source_stream_epoch,

		"committed_scene_voxel_payload_buffer_summary": committed_payload_summary,

		"committed_scene_voxel_runtime_read_source": committed_payload_summary.get("committed_scene_voxel_runtime_read_source", "none"),

		"public_scene_voxel_projection_source": committed_payload_summary.get("public_scene_voxel_projection_source", "none"),

		"public_scene_voxel_projection_readback_source": committed_payload_summary.get("public_scene_voxel_projection_readback_source", "none"),

		"public_scene_voxel_projection_readback": bool(committed_payload_summary.get("public_scene_voxel_projection_readback", false)),

		"public_scene_voxel_collision_projection_source": committed_payload_summary.get("public_scene_voxel_collision_projection_source", "none"),

		"public_scene_voxel_collision_projection_readback_source": committed_payload_summary.get("public_scene_voxel_collision_projection_readback_source", "none"),

		"public_scene_voxel_collision_projection_exact_layers": bool(committed_payload_summary.get("public_scene_voxel_collision_projection_exact_layers", false)),

		"public_scene_voxel_projection_role": committed_payload_summary.get("public_scene_voxel_projection_role", "none"),

		"public_scene_voxel_projection_debug_only": bool(committed_payload_summary.get("public_scene_voxel_projection_debug_only", false)),

		"public_scene_voxel_projection_api_only": bool(committed_payload_summary.get("public_scene_voxel_projection_api_only", false)),

		"public_scene_voxel_projection_runtime_owner": bool(committed_payload_summary.get("public_scene_voxel_projection_runtime_owner", false)),

		"public_scene_voxel_projection_complexity_field_source": bool(committed_payload_summary.get("public_scene_voxel_projection_complexity_field_source", false)),

		"public_scene_voxel_projection_runtime_read_source": committed_payload_summary.get("public_scene_voxel_projection_runtime_read_source", "none"),

		"public_scene_voxel_projection_api": committed_payload_summary.get("public_scene_voxel_projection_api", "none"),

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

		"complexity_field": complexity_field,  # lazy CPU debug projection; primary state in complexity_field_buffer RID

		"collision_field": collision_field,  # lazy CPU debug projection; primary state in collision_summary_buffer RID

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

		"scene_voxel_tile_count": _tile_store._scene_voxel_tiles.size(),

		"scene_voxel_tile_gpu_autoobject_ref_count": _tile_store._scene_voxel_tile_gpu_autoobject_refs.size(),

		"scene_voxel_tile_object_ids_debug": _tile_store._scene_voxel_tile_object_ids_debug.duplicate(),

		"scene_voxel_tiles": _tile_store._scene_voxel_tiles.duplicate(true),

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

## 在3D体素切片上盖章圆形复杂度并生成场景体素源记录入队
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

	# Gather the target slices and stamp + collect them in one 3D voxel pass.
	var gathered: Array = []
	for si in slice_indices:
		gathered.append(slices[si])

	var compare_mode := 1 if force_source_write else 2
	var stamp_result := _stamp_collect_voxel_disc_gpu(gathered, voxel_px, radius_vol, v, compare_mode)
	var updated_slices: Array = stamp_result.get("slices", gathered)
	for local_i in range(slice_indices.size()):
		var si: int = slice_indices[local_i]
		slices[si] = updated_slices[local_i] if local_i < updated_slices.size() and updated_slices[local_i] is Image else gathered[local_i]

	if not scene_voxel_template.is_empty():
		for rec in stamp_result.get("records", []):
			var local_slice := int(rec.slice_local)
			if local_slice < 0 or local_slice >= slice_indices.size():
				continue
			var scene_voxel := scene_voxel_template.duplicate(true)
			scene_voxel["slice_index"] = slice_indices[local_slice]
			scene_voxel["voxel_xz"] = Vector2i(int(rec.x), int(rec.z))
			scene_voxel["complexity"] = v
			scene_voxel = SharedPropertyTypeScript.apply_to_scene_voxel(scene_voxel, scene_voxel, v, SharedPropertyTypeScript.has_collision_fields(scene_voxel))
			scene_voxel = SceneVoxelSourceRecordScript.prepare_source_record(scene_voxel, write_tick if write_tick >= 0 else _generation_tick)
			_enqueue_scene_voxel_source_record(scene_voxel)

	_volume["slices"] = slices

	return voxel_px

## Apply an actual placed mesh's ISWS (instance stamp write spec) into SceneVoxel and buffers.

## This keeps runtime MeshInstance3D placement and the occupancy/voxel volume in sync.

## 应用实例盖章写入规格并返回提交报告
func apply_instance_stamp_write_spec(record: Dictionary, defer_blend: bool = false, generation_tick: int = -1) -> Dictionary:
	return apply_voxel_write_spec(record, defer_blend, generation_tick)

## Deprecated: use apply_instance_stamp_write_spec() instead.

## 应用单条体素写入规格并返回提交报告
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

## 批量应用体素写入规格并返回综合报告
func apply_voxel_write_specs(records: Array, defer_blend: bool = false, generation_tick: int = -1) -> Dictionary:
	return _apply_voxel_write_spec_batch(records, defer_blend, generation_tick, "apply_voxel_write_specs")

## GPU-resident entry point: directly ingest accepted placement source buffer from VPG.
## Called by VPG/GPUAutoObjectRuntime to hand off accepted placement buffer
## as resident scene voxel source candidate records without CPU readback.
func apply_accepted_placement_source_buffer(
	source_candidate_records_buffer: RID,
	source_candidate_ranges_buffer: RID,
	candidate_count: int,
	range_count: int,
	generation_tick: int = -1
) -> Dictionary:
	if not source_candidate_records_buffer.is_valid() or not source_candidate_ranges_buffer.is_valid():
		return _accepted_placement_source_buffer_blocked_report(
			"invalid_source_buffer_rid",
			source_candidate_records_buffer,
			source_candidate_ranges_buffer,
			candidate_count,
			range_count
		)
	if candidate_count <= 0 or range_count <= 0:
		return _accepted_placement_source_buffer_blocked_report(
			"empty_source_candidate_buffers",
			source_candidate_records_buffer,
			source_candidate_ranges_buffer,
			candidate_count,
			range_count
		)

	return _accepted_placement_source_buffer_blocked_report(
		ACCEPTED_PLACEMENT_SOURCE_BUFFER_INCOMPLETE_REASON,
		source_candidate_records_buffer,
		source_candidate_ranges_buffer,
		candidate_count,
		range_count
	)

## 构造已接受放置源缓冲区被阻塞的失败报告
func _accepted_placement_source_buffer_blocked_report(
	reason: String,
	source_candidate_records_buffer: RID,
	source_candidate_ranges_buffer: RID,
	candidate_count: int,
	range_count: int
) -> Dictionary:
	var report := {
		"ok": false,
		"reason": reason,
		"gpu_first": true,
		"cpu_fallback": false,
		"source_write_handoff_mode": "blocked_incomplete_gpu_resident_source_write_buffer",
		"source_write_batch_api": "apply_accepted_placement_source_buffer",
		"cpu_pending_source_candidate_bridge": false,
		"pending_source_candidate_flush_api": "none",
		"source_candidate_resolve_api": "resolve_scene_voxel_sources.glsl",
		"runtime_read_source": "none",
		"source_record_count": maxi(candidate_count, 0),
		"applied_count": 0,
		"failed_count": maxi(candidate_count, 0),
		"apply_results": [],
		"accepted_placement_source_records_rid_valid": source_candidate_records_buffer.is_valid(),
		"accepted_placement_source_ranges_rid_valid": source_candidate_ranges_buffer.is_valid(),
		"accepted_placement_source_record_count": maxi(candidate_count, 0),
		"accepted_placement_source_range_count": maxi(range_count, 0),
		"source_candidate_required_buffers": [
			"candidate_records",
			"candidate_ranges",
			"candidate_payloads",
			"group_source_key_indices",
		],
		"source_candidate_missing_buffers": [
			"candidate_payloads",
			"group_source_key_indices",
		],
		"resident_source_candidate_payload_buffer": false,
		"resident_source_candidate_group_index_buffer": false,
	}
	report.merge(_scene_voxel_source_candidate_resident_diagnostics(false), true)
	report["runtime_read_source"] = "none"
	report["source_record_count"] = maxi(candidate_count, 0)
	report["applied_count"] = 0
	report["failed_count"] = maxi(candidate_count, 0)
	return report

## 批量应用体素写入规格并汇总应用结果与脏诊断报告
func _apply_voxel_write_spec_batch(records: Array, defer_blend: bool, generation_tick: int, batch_api: String) -> Dictionary:
	var report := {
		"ok": true,
		"reason": "ok",
		"gpu_first": true,
		"cpu_fallback": false,
		"source_write_handoff_mode": "gpu_resident_source_write_buffer",
		"source_write_batch_api": batch_api,
		"cpu_pending_source_candidate_bridge": false,
		"pending_source_candidate_flush_api": "blend_scene_voxels->_flush_pending_scene_voxel_source_candidates",
		"source_candidate_resolve_api": "resolve_scene_voxel_sources.glsl",
		"resident_source_write_buffer": true,
		"resident_source_write_buffer_owner": "scene_voxel_committer",
		"resident_source_write_buffer_rid": "resident_source_candidate_records",
		"resident_source_write_buffer_lifetime": "persistent_pass_owned",
		"resident_source_write_buffer_stride_bytes": SCENE_VOXEL_SOURCE_CANDIDATE_STRIDE_BYTES,
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

	var staging_epoch_before := _source_staging._scene_voxel_source_candidate_staging_epoch

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
				_source_staging._scene_voxel_source_candidate_staging_epoch > staging_epoch_before
			),
			true
		)

	return report

## 清空所有体素通道、源流、瓦片表与GPU缓冲并重置tick
func clear_all() -> void:

	occupancy.fill(Color(0.0, 0.0, 0.0, 0.0))

	_volume = {}

	_voxel_write_specs.clear()

	_voxel_write_spec_index.clear()

	_source_staging._scene_source_metadata.clear()

	_clear_scene_voxel_source_streams()

	_sv.clear()

	_sv_dirty_tiles.clear()

	_sv_dirty_rects.clear()

	_tile_store._scene_voxel_tiles.clear()

	_tile_store._scene_voxel_tile_gpu_autoobject_refs.clear()

	_tile_store._scene_voxel_tile_object_ids_debug.clear()

	_tile_store._scene_voxel_tile_object_ref_last_update_stats.clear()

	_tile_store._scene_voxel_tile_object_ref_key_schema = SCENE_VOXEL_TILE_OBJECT_REF_SCHEMA_LEGACY_HASH

	_tile_store._scene_voxel_tile_object_ref_numeric_schema_confirmed = false

	_tile_store._scene_voxel_tile_fixed_object_ref_tile_count = 0

	_tile_store._scene_voxel_tile_fixed_object_ref_slot_count = 0

	_tile_store._scene_voxel_tile_object_ref_rebuild_required = false

	_tile_store._scene_voxel_tile_object_ref_overflow_count = 0

	_tile_store._scene_voxel_tile_object_ref_overflow_tile_ids.clear()

	_tile_store._scene_voxel_tile_epoch = 0

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































var _sv: Dictionary = {}

var _sv_dirty_tiles: Dictionary = {}

var _sv_dirty_rects: Array[Rect2i] = []





































var _generation_tick: int = 1

var _committed_tick: int = 0

var _sv_dirty: bool = true

## 根据网格放置信息构建体素写入规格记录
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

## 注册体素写入规格记录到规格表并返回记录
func _register_voxel_write_spec(record: Dictionary) -> Dictionary:

	var record_id: String = str(record.get("id", "mesh_%d" % _voxel_write_specs.size()))

	record["id"] = record_id

	_voxel_write_spec_index[record_id] = _voxel_write_specs.size()

	_voxel_write_specs.append(record)

	return record

## 根据当前体素体积刷新所有写入规格的体素坐标与切片索引
func _update_voxel_write_specs_for_volume() -> void:
	if _volume.is_empty():
		return
	var xz_res: int = _volume.xz_res
	var meta: Array = _volume.slice_meta
	for ri in range(_voxel_write_specs.size()):
		var record: Dictionary = _voxel_write_specs[ri]
		var base_px: Vector2i = record.get("base_pixel", Vector2i.ZERO)
		var voxel_px := _volume_px_from_base(base_px, xz_res)
		record["voxel_xz"] = voxel_px
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
			collision_layer["voxel_xz"] = voxel_px
			collision_layer["volume_xz_resolution"] = xz_res
			collision_layers[ci] = collision_layer
		record["collision"] = collision_layers
		_voxel_write_specs[ri] = record
		_voxel_write_spec_index[str(record.id)] = ri

## 从已有写入规格记录重建场景体素源流
func _rebuild_scene_voxels_from_records() -> void:

	if _volume.is_empty():

		return

	var write_tick := _next_write_tick()

	begin_generation_tick(write_tick)

	_volume["scene_voxels"] = {}

	_source_staging._scene_source_metadata.clear()

	_clear_scene_voxel_source_streams()

	var records := get_voxel_write_specs()

	for record in records:

		apply_voxel_write_spec(record, true, write_tick)

## 融合场景体素源流并提交体素到体积(主融合入口)
func blend_scene_voxels(tick: int = -1) -> Dictionary:

	if _volume.is_empty():

		return {}

	var commit_tick := tick if tick >= 0 else _generation_tick

	var current_source_voxels := _scene_voxel_source_stream_map()

	if _scene_voxel_source_resolve_blocked():

		_release_committed_scene_voxel_payload_buffer()

		var previous_on_resolve_failure := {}

		var raw_previous_on_resolve_failure = _volume.get("scene_voxels", {})

		if raw_previous_on_resolve_failure is Dictionary:

			previous_on_resolve_failure = (raw_previous_on_resolve_failure as Dictionary).duplicate(true)

		_source_staging._last_blend_scene_voxel_commit_summary = {

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

			"source_resolve": _source_staging._last_scene_voxel_source_resolve_summary.duplicate(true),

			"gpu_dispatched": false,

			"cpu_fallback": false,

		}
		_source_staging._last_blend_scene_voxel_commit_summary.merge(
			_scene_voxel_source_bridge_diagnostics_from_summary(_source_staging._last_scene_voxel_source_resolve_summary),
			true
		)
		_source_staging._last_blend_scene_voxel_commit_summary.merge(get_committed_scene_voxel_payload_buffer_summary(), true)

		push_error("[SceneVoxelCommitter] GPU SceneVoxel source resolve dispatch failed")

		return SceneVoxelScript.accepted_map(previous_on_resolve_failure)

	var previous_scene_voxels := {}

	var raw_previous = _volume.get("scene_voxels", {})

	if raw_previous is Dictionary:

		previous_scene_voxels = (raw_previous as Dictionary).duplicate(true)

	var dirty_scene_voxel_tiles := _dirty_scene_voxel_tile_snapshot()

	var dirty_source_keys := _dirty_scene_voxel_source_stream_keys(previous_scene_voxels, dirty_scene_voxel_tiles)

	var use_dirty_limited_source_write := not dirty_scene_voxel_tiles.is_empty() and not dirty_source_keys.is_empty()

	var final_scene_voxels: Dictionary = previous_scene_voxels.duplicate(true) if use_dirty_limited_source_write else {}

	var source_keys: Array = dirty_source_keys.keys() if use_dirty_limited_source_write else current_source_voxels.keys()

	source_keys.sort()

	if not use_dirty_limited_source_write:

		_source_staging._scene_source_metadata.clear()

	var payload_blend_mode := "merged_resolve_commit_gpu"

	var gpu_payload_result := _try_blend_scene_voxel_commit_payloads_gpu(source_keys, commit_tick)
	var gpu_payloads: PackedFloat32Array = gpu_payload_result.get("payloads", PackedFloat32Array())
	var payload_runtime_read_source := str(gpu_payload_result.get("source_stream_buffer_source", "none"))
	var payload_final_source_stream_resident := bool(gpu_payload_result.get("final_source_stream_resident", false))
	var payload_final_source_stream_epoch := int(gpu_payload_result.get("final_source_stream_resident_epoch", 0))

	var gpu_payload_ok := gpu_payloads.size() == source_keys.size() * SCENE_VOXEL_COMMIT_OUTPUT_FLOAT_STRIDE

	if gpu_payload_ok:

		_commit_scene_voxel_sources_from_gpu_payloads(source_keys, gpu_payloads, final_scene_voxels, commit_tick)

	else:

		_source_staging._last_blend_scene_voxel_commit_summary = {

			"ok": false,

			"gpu_first": true,

			"mode": "compute_dispatch_failed",

			"payload_blend_mode": "merged_resolve_commit_failed",

			"dirty_tile_count": dirty_scene_voxel_tiles.size(),

			"processed_source_key_count": source_keys.size(),

			"total_source_key_count": current_source_voxels.size(),

			"committed_scene_voxel_count": previous_scene_voxels.size(),

			"runtime_read_source": "none",

			"control_plane_source": "auto_brush_source_streams",

			"source_resolve": _source_staging._last_scene_voxel_source_resolve_summary.duplicate(true),

			"gpu_dispatched": false,

			"cpu_fallback": false,

		}
		_source_staging._last_blend_scene_voxel_commit_summary.merge(
			_scene_voxel_source_bridge_diagnostics_from_summary(_source_staging._last_scene_voxel_source_resolve_summary),
			true
		)
		_source_staging._last_blend_scene_voxel_commit_summary.merge(get_committed_scene_voxel_payload_buffer_summary(), true)
		_source_staging._last_blend_scene_voxel_commit_summary["runtime_read_source"] = "none"
		_source_staging._last_blend_scene_voxel_commit_summary["final_source_stream_resident"] = false
		_source_staging._last_blend_scene_voxel_commit_summary["final_source_stream_resident_epoch"] = 0

		push_error("[SceneVoxelCommitter] GPU SceneVoxel payload blend dispatch failed")

		return SceneVoxelScript.accepted_map(previous_scene_voxels)

	_source_staging._last_blend_scene_voxel_commit_summary = {
		"ok": true,
		"gpu_first": true,
		"mode": "dirty_scene_voxel_tiles" if use_dirty_limited_source_write else "full_source_stream_scan",
		"dirty_tile_count": dirty_scene_voxel_tiles.size(),
		"processed_source_key_count": source_keys.size(),
		"total_source_key_count": current_source_voxels.size(),
		"committed_scene_voxel_count": final_scene_voxels.size(),
		"runtime_read_source": payload_runtime_read_source,
		"control_plane_source": "auto_brush_source_streams",
		"payload_blend_mode": payload_blend_mode,
		"gpu_dispatched": gpu_payload_ok,
		"source_resolve": _source_staging._last_scene_voxel_source_resolve_summary.duplicate(true),
		"cpu_fallback": false,
	}
	_source_staging._last_blend_scene_voxel_commit_summary.merge(
		_scene_voxel_source_bridge_diagnostics_from_summary(_source_staging._last_scene_voxel_source_resolve_summary),
		true
	)

	if _committed_scene_voxel_dense_projection_ready(final_scene_voxels.size()):
		_stage_scene_voxel_public_debug_cache_from_committed_buffers(commit_tick, final_scene_voxels.size())
	else:
		_volume["scene_voxels"] = final_scene_voxels
		_mark_scene_voxel_public_debug_cache_from_committed_map(commit_tick, final_scene_voxels.size())

	_source_staging._last_blend_scene_voxel_commit_summary.merge(get_committed_scene_voxel_payload_buffer_summary(), true)
	_source_staging._last_blend_scene_voxel_commit_summary["runtime_read_source"] = payload_runtime_read_source
	_source_staging._last_blend_scene_voxel_commit_summary["final_source_stream_resident"] = payload_final_source_stream_resident
	_source_staging._last_blend_scene_voxel_commit_summary["final_source_stream_resident_epoch"] = payload_final_source_stream_epoch

	_rebuild_shared_field_cache_from_scene_voxels(final_scene_voxels)


	_committed_tick = max(_committed_tick, commit_tick)

	_generation_tick = max(_generation_tick, commit_tick + 1)

	_sv_dirty = true

	_rebuild_sv()

	return SceneVoxelScript.accepted_map(final_scene_voxels)

## 返回空的反馈评分结果字典
func _empty_blendsv_feedback_result(target_role: String) -> Dictionary:
	return {
		"stage": "post_commit_blendsv_feedback",
		"target_role": target_role,
		"score": 0.0,
		"sample_count": 0,
		"scene_occupied_count": 0,
		"target_occupied_count": 0,
		"overlap_occupied_count": 0,
	}


## 对比目标体素场评估BlendSV反馈评分
func score_blendsv_feedback_against_target(
	target_field: PackedFloat32Array,
	target_role: String = "TargetSV_B",
	threshold: float = VOXEL_OCCUPIED_EPSILON
) -> Dictionary:
	var result := _score_blendsv_feedback_against_target_gpu(target_field, target_role, threshold)

	if not result.is_empty():
		return result

	push_error("[SceneVoxelCommitter] BlendSV feedback score compute failed")

	return _empty_blendsv_feedback_result(target_role)

## GPU计算BlendSV与目标体素场的反馈评分
func _score_blendsv_feedback_against_target_gpu(
	target_field: PackedFloat32Array,
	target_role: String,
	threshold: float = VOXEL_OCCUPIED_EPSILON
) -> Dictionary:
	if _volume.is_empty() or target_field.is_empty():
		return _empty_blendsv_feedback_result(target_role)

	var xz_res := int(_volume.get("xz_res", grid_size.x))
	var total_slices := int(_volume.get("total_slices", grid_size.y))
	var voxel_count := xz_res * xz_res * total_slices
	var sample_count := mini(voxel_count, target_field.size())

	if sample_count <= 0:

		return _empty_blendsv_feedback_result(target_role)

	if not _gpu_ready or _rd == null or not _shader_score_scene_voxel_feedback.is_valid() or not _pipeline_score_scene_voxel_feedback.is_valid():

		return {}

	var complexity_field := _scene_voxel_tile_packed_float_field(_sv.get("complexity_field", PackedFloat32Array())) if not _sv.is_empty() else PackedFloat32Array()
	var collision_field := _scene_voxel_tile_packed_float_field(_sv.get("collision_field", PackedFloat32Array())) if not _sv.is_empty() else PackedFloat32Array()

	if complexity_field.size() < sample_count:

		complexity_field = _try_make_sv_complexity_field_from_source_streams_gpu(xz_res, total_slices)

	if complexity_field.size() < sample_count:

		return {}

	if collision_field.size() < sample_count:
		collision_field.resize(sample_count)

	var complexity_buffer := storage_buffer_from_floats(complexity_field, SCOPE_FRAME, "feedback_complexity_field")
	var collision_buffer := storage_buffer_from_floats(collision_field, SCOPE_FRAME, "feedback_collision_field")
	var target_buffer := storage_buffer_from_floats(target_field, SCOPE_FRAME, "feedback_target_field")
	var stats_buffer := storage_buffer_zero(8 * 4, SCOPE_FRAME, "feedback_stats")

	if not complexity_buffer.is_valid() or not collision_buffer.is_valid() or not target_buffer.is_valid() or not stats_buffer.is_valid():

		gc_frame()

		return {}

	var set0 := create_uniform_set([
		make_storage_uniform(0, complexity_buffer),
		make_storage_uniform(1, collision_buffer),
		make_storage_uniform(2, target_buffer),
		make_storage_uniform(3, stats_buffer),
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

## 构建体素体积并初始化切片与元数据
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


## 生成占位切片图像,失败时返回空白图像
func _make_occupancy_slice_image(channel: int, xz_res: int) -> Image:
	var gpu_img := _make_occupancy_slice_image_gpu(channel, xz_res)
	if gpu_img != null and not gpu_img.is_empty():
		return gpu_img
	var slice_img := VoxelGeneralScript.create_r32_image(xz_res)
	if VoxelGeneralScript.is_valid_channel(channel) and xz_res > 0:
		push_error("[SceneVoxelCommitter] Occupancy slice GPU compute failed")
	return slice_img


## GPU生成指定通道的占位切片图像
func _make_occupancy_slice_image_gpu(channel: int, xz_res: int) -> Image:
	if not VoxelGeneralScript.is_valid_channel(channel) or xz_res <= 0:
		return null
	if occupancy == null or occupancy.is_empty():
		return null
	if not _gpu_ready or _rd == null or not _sampler.is_valid():
		return null

	var shader := load_compute_shader("res://shaders/occupancy_slice_image.glsl", SCOPE_FRAME, "occupancy_slice_image")
	var pipeline := create_compute_pipeline(shader, SCOPE_FRAME, "occupancy_slice_image")
	if not shader.is_valid() or not pipeline.is_valid():
		gc_frame()
		return null

	var occupancy_tex := upload_texture_2d(
		occupancy,
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
	push.encode_s32(8, occupancy.get_width())
	push.encode_s32(12, occupancy.get_height())
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


## 查询指定世界坐标处的体素信息
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

## 获取已提交的场景体素映射
func get_scene_voxels() -> Dictionary:

	if _volume.is_empty():

		return {}

	_hydrate_scene_voxel_public_debug_cache_from_committed_buffers()

	var scene_voxels: Dictionary = _volume.get("scene_voxels", {})

	return SceneVoxelScript.accepted_map(scene_voxels)

## 获取场景体素状态字典并在需要时重建
func get_sv() -> Dictionary:

	if _sv_dirty and not _volume.is_empty():

		_rebuild_sv()

	elif not _sv.is_empty():

		_maybe_auto_upload_scene_voxel_tile_buffers("get_sv")

		_publish_scene_voxel_tile_gpu_summary_to_sv()

	_publish_scene_voxel_public_debug_cache_summary_to_sv()

	return _sv.duplicate(true)

## 标记指定SV瓦片为脏
func invalidate_sv_tile(slice_index: int, voxel_xz: Vector2i, layer: String = "scene") -> void:

	_mark_sv_tile_dirty(slice_index, voxel_xz, layer)

## 标记指定矩形区域内的SV瓦片为脏
func invalidate_sv_rect(base_rect: Rect2i, slice_indices: Array = [], include_collision: bool = true) -> void:

	_mark_sv_rect_dirty(base_rect, slice_indices, include_collision)

## 获取脏SV瓦片的快照
func get_sv_dirty_tiles() -> Dictionary:

	return _sv_dirty_tiles.duplicate(true)

## 标记指定场景体素瓦片为脏
func _mark_scene_voxel_full_rebuild_dirty(reason: String = "full_rebuild") -> Dictionary:

	return mark_all_scene_voxel_tiles_dirty(

		{"scene": true, "collision": true},

		{

			"id": reason,

			"source_id": reason,

		}

	)

## 标记全部场景体素瓦片为脏并返回快照
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

		_sv["scene_voxel_tile_gpu_autoobject_ref_count"] = _tile_store._scene_voxel_tile_gpu_autoobject_refs.size()

	_maybe_auto_upload_scene_voxel_tile_buffers("clear_sv_dirty")

	_publish_scene_voxel_tile_gpu_summary_to_sv()

## 获取上次BlendSV提交摘要的副本
func get_last_blend_scene_voxel_commit_summary() -> Dictionary:

	return _source_staging._last_blend_scene_voxel_commit_summary.duplicate(true)

## 获取上次场景体素源解析摘要的副本
func get_last_scene_voxel_source_resolve_summary() -> Dictionary:

	return _source_staging._last_scene_voxel_source_resolve_summary.duplicate(true)

## 获取指定切片与XZ坐标的场景体素记录
func get_scene_voxel(slice_index: int, voxel_xz: Vector2i) -> Dictionary:

	if _volume.is_empty():

		return {}

	_hydrate_scene_voxel_public_debug_cache_from_committed_buffers()

	var scene_voxels: Dictionary = _volume.get("scene_voxels", {})

	var key := SceneVoxelSourceRecordScript.scene_voxel_key(slice_index, voxel_xz)

	var scene_voxel = scene_voxels.get(key, {})

	if scene_voxel is Dictionary:

		return SceneVoxelScript.accepted(scene_voxel as Dictionary)

	return {}

## Get a specific Y-slice Image from the volume.

## 获取体积中指定Y切片的体素图像
func get_voxel_slice(slice_index: int) -> Image:

	if _volume.is_empty() or slice_index < 0 or slice_index >= _volume.total_slices:

		return VoxelGeneralScript.create_r32_image(1)

	return _volume.slices[slice_index]

## Get metadata for a specific slice.

## 获取指定切片的元数据
func get_voxel_slice_meta(slice_index: int) -> Dictionary:

	if _volume.is_empty() or slice_index < 0 or slice_index >= _volume.total_slices:

		return {}

	return _volume.slice_meta[slice_index]

## Get total number of slices in the volume.

## 获取体积的切片总数
func get_voxel_slice_count() -> int:

	if _volume.is_empty():

		return 0

	return _volume.total_slices

## Get full volume stats for debug.

## 构造1x1空白RF图像
func _empty_rf_image() -> Image:
	return VoxelGeneralScript.create_r32_image(1)

## 归集并校验体积切片图像列表
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

## 归集体素碰撞场图像并按分辨率重采样
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

## GPU归约场景体素统计信息
func _reduce_scene_voxel_stats_gpu(xz_res: int, total_slices: int) -> Dictionary:
	var voxel_count := xz_res * xz_res * total_slices
	if voxel_count <= 0:
		return {}
	if not _gpu_ready or _rd == null or not _sampler.is_valid():
		return {}
	if not _shader_reduce_scene_voxel_stats.is_valid() or not _pipeline_reduce_scene_voxel_stats.is_valid():
		return {}

	var scene_voxels: Dictionary = _volume.get("scene_voxels", {})
	var use_complexity_buffer := false
	var scene_source := "volume_slice_texture"
	var complexity_field := PackedFloat32Array()
	if not scene_voxels.is_empty():
		complexity_field = _scene_voxel_tile_packed_float_field(_sv.get("complexity_field", PackedFloat32Array())) if not _sv.is_empty() else PackedFloat32Array()
		if complexity_field.size() != voxel_count:
			complexity_field = _try_make_sv_complexity_field_from_source_streams_gpu(xz_res, total_slices)
		if complexity_field.size() != voxel_count:
			return {}
		use_complexity_buffer = true
		scene_source = "resident_complexity_field_buffer"

	var scene_slices := _voxel_reduce_slice_images(xz_res, total_slices)
	if use_complexity_buffer:
		if scene_slices.is_empty():
			scene_slices = [_empty_rf_image()]
	else:
		if scene_slices.is_empty():
			return {}
		complexity_field.resize(1)

	var complexity_buffer := storage_buffer_from_floats(complexity_field, SCOPE_FRAME, "voxel_stats_complexity_field")
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
	if not complexity_buffer.is_valid() or not scene_tex.is_valid() or not collision_tex.is_valid() or not counts_buffer.is_valid():
		gc_frame()
		return {}

	var set0 := create_uniform_set([
		make_storage_uniform(0, complexity_buffer),
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
	push.encode_s32(16, 1 if use_complexity_buffer else 0)
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

## 获取体素体积统计数据
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

## 重置占位、体素体积与相关缓存状态
func reset_occupancy() -> void:

	occupancy.fill(Color(0.0, 0.0, 0.0, 0.0))

	_collision_field.fill(Color(0.0, 0.0, 0.0, 0.0))

	_volume = {}

	_voxel_write_specs.clear()

	_voxel_write_spec_index.clear()

	_source_staging._scene_source_metadata.clear()

	_clear_scene_voxel_source_streams()

	_sv.clear()

	_sv_dirty_tiles.clear()

	_sv_dirty_rects.clear()

	_tile_store._scene_voxel_tiles.clear()

	_tile_store._scene_voxel_tile_gpu_autoobject_refs.clear()

	_tile_store._scene_voxel_tile_object_ids_debug.clear()

	_tile_store._scene_voxel_tile_object_ref_last_update_stats.clear()

	_tile_store._scene_voxel_tile_object_ref_key_schema = SCENE_VOXEL_TILE_OBJECT_REF_SCHEMA_LEGACY_HASH

	_tile_store._scene_voxel_tile_object_ref_numeric_schema_confirmed = false

	_tile_store._scene_voxel_tile_fixed_object_ref_tile_count = 0

	_tile_store._scene_voxel_tile_fixed_object_ref_slot_count = 0

	_tile_store._scene_voxel_tile_object_ref_rebuild_required = false

	_tile_store._scene_voxel_tile_object_ref_overflow_count = 0

	_tile_store._scene_voxel_tile_object_ref_overflow_tile_ids.clear()

	_tile_store._scene_voxel_tile_epoch = 0

	_release_scene_voxel_tile_gpu_buffers()

	_mark_scene_voxel_tile_staging_dirty("reset_occupancy")

	_generation_tick = 1

	_committed_tick = 0

	_sv_dirty = true

## 校验体素体积的通道占用与多样性
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
		if not VoxelGeneralScript.is_valid_channel(ch):
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

## 获取指定XZ像素列的体素记录数组
func get_voxel_column(px: int, pz: int) -> Array[Dictionary]:
	var column: Array[Dictionary] = []
	if _volume.is_empty():
		return column

	_hydrate_scene_voxel_public_debug_cache_from_committed_buffers()

	var xz_res: int = _volume.xz_res
	px = clampi(px, 0, xz_res - 1)
	pz = clampi(pz, 0, xz_res - 1)
	var slices: Array = _volume.get("slices", [])
	var meta: Array = _volume.get("slice_meta", [])
	var scene_voxels: Dictionary = _volume.get("scene_voxels", {})

	for i in range(slices.size()):
		if i >= meta.size() or not meta[i] is Dictionary:
			continue
		var m: Dictionary = meta[i]
		var entry := {
			"slice": i,
			"channel": int(m.get("channel", -1)),
			"y_min": m.get("y_min", 0.0),
			"y_max": m.get("y_max", 0.0),
			"color": m.get("color", Color.TRANSPARENT),
			"complexity": m.get("complexity", 0.0),
			"collision": [],
		}
		var voxel_key := SceneVoxelSourceRecordScript.scene_voxel_key(i, Vector2i(px, pz))
		var scene_voxel = scene_voxels.get(voxel_key, {})
		if scene_voxel is Dictionary:
			var accepted_fields: Dictionary = SceneVoxelScript.accepted(scene_voxel as Dictionary)
			if accepted_fields.has("collision"):
				entry["collision"] = accepted_fields.get("collision", [])
		column.append(entry)

	return column



## ===== SceneVoxelTileStore 委托桩(抽出后保持内部/外部调用兼容) =====
func _apply_scene_voxel_tile_reduce_summaries(reduced: Dictionary) -> void:
	_tile_store._apply_scene_voxel_tile_reduce_summaries(reduced)
func _clear_scene_voxel_tile_dirty_flags() -> void:
	_tile_store._clear_scene_voxel_tile_dirty_flags()
func _dirty_scene_voxel_tile_snapshot() -> Dictionary:
	return _tile_store._dirty_scene_voxel_tile_snapshot()
func _legacy_sv_tiles_from_reduce_summaries(reduced: Dictionary,
	tile_size: int,
	dirty_tiles_snapshot: Dictionary) -> Dictionary:
	return _tile_store._legacy_sv_tiles_from_reduce_summaries(reduced, tile_size, dirty_tiles_snapshot)
func _mark_scene_voxel_tile_staging_dirty(reason: String = "staging_changed") -> void:
	_tile_store._mark_scene_voxel_tile_staging_dirty(reason)
func _maybe_auto_upload_scene_voxel_tile_buffers(reason: String = "auto_upload") -> void:
	_tile_store._maybe_auto_upload_scene_voxel_tile_buffers(reason)
func _rebuild_scene_voxel_tile_source_refs() -> void:
	_tile_store._rebuild_scene_voxel_tile_source_refs()
func _reduce_scene_voxel_tile_summaries_gpu(complexity_field: PackedFloat32Array,
	collision_field: PackedFloat32Array,
	xz_res: int,
	total_slices: int,
	tile_size: Vector3i,
	buffer_contract: Dictionary = {}) -> Dictionary:
	return _tile_store._reduce_scene_voxel_tile_summaries_gpu(complexity_field, collision_field, xz_res, total_slices, tile_size, buffer_contract)
func _register_scene_voxel_tile_project_settings() -> void:
	_tile_store._register_scene_voxel_tile_project_settings()
func _release_scene_voxel_tile_gpu_buffers(preserve_buffer_names: Array = []) -> void:
	_tile_store._release_scene_voxel_tile_gpu_buffers(preserve_buffer_names)
func _reset_scene_voxel_tile_summaries() -> void:
	_tile_store._reset_scene_voxel_tile_summaries()
func _scene_voxel_in_dirty_scene_voxel_tiles(scene_voxel: Dictionary, dirty_tiles: Dictionary) -> bool:
	return _tile_store._scene_voxel_in_dirty_scene_voxel_tiles(scene_voxel, dirty_tiles)
func _scene_voxel_tile_bounds(tile_coord: Vector3i) -> Dictionary:
	return _tile_store._scene_voxel_tile_bounds(tile_coord)
func _scene_voxel_tile_bounds_from_record(record: Dictionary) -> Dictionary:
	return _tile_store._scene_voxel_tile_bounds_from_record(record)
func _scene_voxel_tile_packed_float_field(value) -> PackedFloat32Array:
	return _tile_store._scene_voxel_tile_packed_float_field(value)
func _scene_voxel_tile_size() -> Vector3i:
	return _tile_store._scene_voxel_tile_size()
func _touch_scene_voxel_tile_from_voxel(slice_index: int, voxel_xz: Vector2i, dirty_flags = {}, source_record: Dictionary = {}) -> void:
	_tile_store._touch_scene_voxel_tile_from_voxel(slice_index, voxel_xz, dirty_flags, source_record)
func apply_gpu_autoobject_dirty_delta(delta: Dictionary, dispatch_object_ref_update: bool = false) -> Dictionary:
	return _tile_store.apply_gpu_autoobject_dirty_delta(delta, dispatch_object_ref_update)
func apply_gpu_autoobject_dirty_deltas(deltas: Array) -> Dictionary:
	return _tile_store.apply_gpu_autoobject_dirty_deltas(deltas)
func ensure_scene_voxel_tile_buffers_uploaded(force: bool = false) -> bool:
	return _tile_store.ensure_scene_voxel_tile_buffers_uploaded(force)
func get_dirty_scene_voxel_tiles() -> Dictionary:
	return _tile_store.get_dirty_scene_voxel_tiles()
func get_gpu_autoobject_object_ref_range_policy_diagnostics(refs_per_tile: int = SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT) -> Dictionary:
	return _tile_store.get_gpu_autoobject_object_ref_range_policy_diagnostics(refs_per_tile)
func get_scene_voxel_tile(tile_coord: Vector3i) -> Dictionary:
	return _tile_store.get_scene_voxel_tile(tile_coord)
func get_scene_voxel_tile_gpu_buffer(buffer_name: String) -> RID:
	return _tile_store.get_scene_voxel_tile_gpu_buffer(buffer_name)
func get_scene_voxel_tile_gpu_buffer_summary() -> Dictionary:
	return _tile_store.get_scene_voxel_tile_gpu_buffer_summary()
func get_scene_voxel_tile_summary_gpu_buffer() -> RID:
	return _tile_store.get_scene_voxel_tile_summary_gpu_buffer()
func get_scene_voxel_tiles() -> Dictionary:
	return _tile_store.get_scene_voxel_tiles()
func is_scene_voxel_tile_gpu_auto_upload_enabled() -> bool:
	return _tile_store.is_scene_voxel_tile_gpu_auto_upload_enabled()
func is_scene_voxel_tile_gpu_ready() -> bool:
	return _tile_store.is_scene_voxel_tile_gpu_ready()
func mark_all_scene_voxel_tiles_dirty(dirty_flags = {}, source_record: Dictionary = {}) -> Dictionary:
	return _tile_store.mark_all_scene_voxel_tiles_dirty(dirty_flags, source_record)
func mark_scene_voxel_tile_bounds_dirty(voxel_min: Vector3i, voxel_max: Vector3i, dirty_flags = {}, source_record: Dictionary = {}) -> void:
	_tile_store.mark_scene_voxel_tile_bounds_dirty(voxel_min, voxel_max, dirty_flags, source_record)
func mark_scene_voxel_tile_dirty(tile_coord: Vector3i, dirty_flags = {}, source_record: Dictionary = {}) -> void:
	_tile_store.mark_scene_voxel_tile_dirty(tile_coord, dirty_flags, source_record)
func readback_scene_voxel_tile_debug_snapshot() -> Dictionary:
	return _tile_store.readback_scene_voxel_tile_debug_snapshot()
func set_scene_voxel_tile_gpu_auto_upload(enabled: bool, upload_now: bool = false) -> bool:
	return _tile_store.set_scene_voxel_tile_gpu_auto_upload(enabled, upload_now)
func try_apply_gpu_autoobject_object_ref_update_pass(deltas: Array) -> Dictionary:
	return _tile_store.try_apply_gpu_autoobject_object_ref_update_pass(deltas)
func try_apply_gpu_autoobject_object_ref_update_pass_from_buffer(dirty_delta_buffer: RID,
	dirty_delta_count: int,
	dirty_delta_capacity: int = -1,
	dirty_delta_source: String = "borrowed_dirty_delta_buffer") -> Dictionary:
	return _tile_store.try_apply_gpu_autoobject_object_ref_update_pass_from_buffer(dirty_delta_buffer, dirty_delta_count, dirty_delta_capacity, dirty_delta_source)



## ===== SceneVoxelSourceStaging 委托桩(抽出后保持内部/外部调用兼容) =====
func _clear_scene_voxel_source_streams() -> void:
	_source_staging._clear_scene_voxel_source_streams()
func _commit_scene_voxel_sources_from_gpu_payloads(source_keys: Array,
	payloads: PackedFloat32Array,
	final_scene_voxels: Dictionary,
	commit_tick: int) -> void:
	_source_staging._commit_scene_voxel_sources_from_gpu_payloads(source_keys, payloads, final_scene_voxels, commit_tick)
func _committed_scene_voxel_dense_projection_ready(expected_count: int = -1) -> bool:
	return _source_staging._committed_scene_voxel_dense_projection_ready(expected_count)
func _dirty_scene_voxel_source_stream_keys(previous_scene_voxels: Dictionary, dirty_tiles: Dictionary) -> Dictionary:
	return _source_staging._dirty_scene_voxel_source_stream_keys(previous_scene_voxels, dirty_tiles)
func _enqueue_scene_voxel_source_record(source_voxel: Dictionary, source_tick: int = -1) -> void:
	_source_staging._enqueue_scene_voxel_source_record(source_voxel, source_tick)
func _flush_pending_scene_voxel_source_candidates() -> void:
	_source_staging._flush_pending_scene_voxel_source_candidates()
func _hydrate_scene_voxel_public_debug_cache_from_committed_buffers() -> bool:
	return _source_staging._hydrate_scene_voxel_public_debug_cache_from_committed_buffers()
func _make_scene_voxel_source_record_template(record: Dictionary,

	layer: Dictionary,

	voxel_px: Vector2i,

	complexity: float) -> Dictionary:
	return _source_staging._make_scene_voxel_source_record_template(record, layer, voxel_px, complexity)
func _mark_scene_voxel_public_debug_cache_from_committed_map(commit_tick: int, expected_count: int) -> void:
	_source_staging._mark_scene_voxel_public_debug_cache_from_committed_map(commit_tick, expected_count)
func _publish_scene_voxel_public_debug_cache_summary_to_sv() -> void:
	_source_staging._publish_scene_voxel_public_debug_cache_summary_to_sv()
func _release_committed_scene_voxel_payload_buffer() -> void:
	_source_staging._release_committed_scene_voxel_payload_buffer()
func _release_scene_voxel_source_candidate_resident_buffers() -> void:
	_source_staging._release_scene_voxel_source_candidate_resident_buffers()
func _scene_voxel_source_bridge_diagnostics_from_summary(summary: Dictionary) -> Dictionary:
	return _source_staging._scene_voxel_source_bridge_diagnostics_from_summary(summary)
func _scene_voxel_source_candidate_resident_diagnostics(staged: bool) -> Dictionary:
	return _source_staging._scene_voxel_source_candidate_resident_diagnostics(staged)
func _scene_voxel_source_resolve_blocked() -> bool:
	return _source_staging._scene_voxel_source_resolve_blocked()
func _scene_voxel_source_stream_map() -> Dictionary:
	return _source_staging._scene_voxel_source_stream_map()
func _stage_scene_voxel_public_debug_cache_from_committed_buffers(commit_tick: int, expected_count: int) -> void:
	_source_staging._stage_scene_voxel_public_debug_cache_from_committed_buffers(commit_tick, expected_count)
func _try_blend_scene_voxel_commit_payloads_gpu(source_keys: Array, _commit_tick: int) -> Dictionary:
	return _source_staging._try_blend_scene_voxel_commit_payloads_gpu(source_keys, _commit_tick)
func _try_make_sv_complexity_field_from_source_streams_gpu(xz_res: int, total_slices: int) -> PackedFloat32Array:
	return _source_staging._try_make_sv_complexity_field_from_source_streams_gpu(xz_res, total_slices)
func _try_make_sv_complexity_field_from_source_streams_gpu_result(xz_res: int,
	total_slices: int,
	output_buffer_scope: String = "") -> Dictionary:
	return _source_staging._try_make_sv_complexity_field_from_source_streams_gpu_result(xz_res, total_slices, output_buffer_scope)
func get_committed_scene_voxel_key_coord_buffer_summary() -> Dictionary:
	return _source_staging.get_committed_scene_voxel_key_coord_buffer_summary()
func get_committed_scene_voxel_payload_buffer_summary() -> Dictionary:
	return _source_staging.get_committed_scene_voxel_payload_buffer_summary()
func stage_pending_scene_voxel_source_candidates_to_resident_buffers() -> Dictionary:
	return _source_staging.stage_pending_scene_voxel_source_candidates_to_resident_buffers()



## ===== SceneVoxelCollisionField 委托桩 =====
func _create_collision_image(resolution: int) -> Image:
	return _field_builder._create_collision_image(resolution)
func _make_source_collision(base_px: Vector2i, collision_layers: Array, rec: Dictionary = {}) -> Array[Dictionary]:
	return _field_builder._make_source_collision(base_px, collision_layers, rec)
func _make_sv_collision_field(collision: Dictionary, xz_res: int, total_slices: int) -> PackedFloat32Array:
	return _field_builder._make_sv_collision_field(collision, xz_res, total_slices)
func _make_sv_collision_record_summary_field(collision: Dictionary, xz_res: int, total_slices: int) -> PackedFloat32Array:
	return _field_builder._make_sv_collision_record_summary_field(collision, xz_res, total_slices)
func _make_sv_collision_record_summary_gpu_buffer(collision: Dictionary,
	xz_res: int,
	total_slices: int,
	output_buffer_scope: String) -> Dictionary:
	return _field_builder._make_sv_collision_record_summary_gpu_buffer(collision, xz_res, total_slices, output_buffer_scope)
func _rebuild_shared_field_cache_from_scene_voxels(scene_voxels: Dictionary) -> void:
	_field_builder._rebuild_shared_field_cache_from_scene_voxels(scene_voxels)
func _resample_collision_field(source_img: Image, xz_res: int) -> Image:
	return _field_builder._resample_collision_field(source_img, xz_res)
func _sample_scalar_image_pixel_gpu(img: Image, px: Vector2i) -> Dictionary:
	return _field_builder._sample_scalar_image_pixel_gpu(img, px)
func _stamp_collect_voxel_disc_gpu(slice_images: Array,
	center_px: Vector2i,
	radius_px: int,
	value: float,
	compare_mode: int) -> Dictionary:
	return _field_builder._stamp_collect_voxel_disc_gpu(slice_images, center_px, radius_px, value, compare_mode)
func _stamp_occupancy_channel(base_px: Vector2i, channel: int, radius_px: int, complexity: float) -> void:
	_field_builder._stamp_occupancy_channel(base_px, channel, radius_px, complexity)
func _stamp_shared_field_layers(base_px: Vector2i, field_layers: Array, rec: Dictionary = {}) -> Array[Dictionary]:
	return _field_builder._stamp_shared_field_layers(base_px, field_layers, rec)
func import_mask_channel(channel: int, mask_img: Image, complexity: float = 1.0) -> void:
	_field_builder.import_mask_channel(channel, mask_img, complexity)
func set_terrain_base_collision_field(base_collision: Image) -> void:
	_field_builder.set_terrain_base_collision_field(base_collision)
