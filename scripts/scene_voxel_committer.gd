class_name SceneVoxelCommitter

extends "res://scripts/godot_compute_shader_base.gd"

const VOXEL_OCCUPIED_EPSILON := VoxelGeneral.VOXEL_OCCUPIED_EPSILON

const SV_RESIDENT_TILE_SIZE := 8

const SCENE_VOXEL_TILE_SIZE_SETTING := "meshfill/scene_voxel_tile/size_voxels"

const DEFAULT_SCENE_VOXEL_TILE_SIZE := Vector3i(4, 4, 4)

const SCENE_VOXEL_TILE_RECORD_BUFFER := "scene_voxel_tile_records"
const SCENE_VOXEL_TILE_SUMMARY_BUFFER := "scene_voxel_tile_summaries"
const SCENE_VOXEL_TILE_OBJECT_REF_BUFFER := "scene_voxel_tile_object_refs"
const SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER := "scene_voxel_tile_complexity_field"
const SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER := "scene_voxel_tile_collision_field"
const SCENE_VOXEL_TILE_GPU_BUFFER_NAMES := [
	SCENE_VOXEL_TILE_RECORD_BUFFER,
	SCENE_VOXEL_TILE_SUMMARY_BUFFER,
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
const SCENE_VOXEL_TILE_COMPLEXITY_FIELD_FORMAT := "rgba8_unorm"
const SCENE_VOXEL_TILE_COLLISION_FIELD_FORMAT := "r8_unorm"
const SCENE_VOXEL_TILE_COMPLEXITY_FIELD_STRIDE_BYTES := 4
const SCENE_VOXEL_TILE_COLLISION_FIELD_STRIDE_BYTES := 1
const SCENE_VOXEL_TILE_COLLISION_FIELD_UPLOAD_STRIDE_BYTES := 4
const SCENE_VOXEL_TILE_FIELD_STRIDE_BYTES := SCENE_VOXEL_TILE_COMPLEXITY_FIELD_STRIDE_BYTES
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

## 初始化 GPU 资源(仅创建 sampler；compute shader 已下沉至 tile/source/collision 三子系统)，校验资源完整性
func _init_gpu() -> void:

	log_name = "SceneVoxelCommitter"

	if not ensure_device(true, false):

		_gpu_fatal("Failed to create RenderingDevice — GPU compute required")

		return

	_sampler = create_linear_sampler()

	var missing_gpu_rids: Array[String] = []

	if not _sampler.is_valid():

		missing_gpu_rids.append("sampler")

	_gpu_ready = missing_gpu_rids.is_empty()

	if _gpu_ready:

		print("[SceneVoxelCommitter] GPU ready (coordinator: sampler only; tile/source/collision → 3 subsystems)")

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

## 释放 sampler 并重置 GPU 就绪状态(shader/pipeline 已下沉至三子系统)
func _free_gpu() -> void:

	dispose()

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

## 判断通道索引是否在有效范围内
func _is_valid_channel(channel: int) -> bool:

	return VoxelGeneralScript.is_valid_channel(channel)

## 将世界半径（米）换算为基础分辨率下的像素半径；委托 VoxelGeneralScript；由 _record_radius_px 和 apply_voxel_write_spec 调用
func _radius_to_px(radius_m: float) -> int:

	return VoxelGeneralScript.world_radius_to_texture_radius(radius_m, _capture_size, _base_res)

## 返回全部已注册体素写入规格的深度副本；由 ScenePlacementActor、调试工具、_rebuild_scene_voxels_from_records 调用
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

## 将 SceneVoxelTile 三维坐标反映射为旧式 SV 瓦片像素坐标并标记为脏(B→A 反向同步)；实现现归 _tile_store，此处为委托桩
func _mark_legacy_sv_tiles_for_scene_voxel_tile(tile_coord: Vector3i, dirty_flags: Dictionary) -> void:
	_tile_store._mark_legacy_sv_tiles_for_scene_voxel_tile(tile_coord, dirty_flags)

## 从 _tile_store 读取 GPU 缓冲摘要并将关键字段回写进 _sv 字典；由 _rebuild_sv、get_sv、clear_sv_dirty 调用
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

## 构造 SV 瓦片的字符串存储键（slice/x/z/layer/size 组合）；委托 SceneVoxelTileCodecScript；由 _mark_sv_tile_dirty 调用
func _sv_tile_key(slice_index: int, voxel_px: Vector2i, layer: String = "scene", tile_size: int = SV_RESIDENT_TILE_SIZE) -> String:
	return SceneVoxelTileCodecScript.sv_tile_key(slice_index, voxel_px, layer, tile_size)

## 计算SV瓦片的XZ边界矩形
func _sv_tile_bounds(voxel_px: Vector2i, tile_size: int = SV_RESIDENT_TILE_SIZE) -> Rect2i:
	return SceneVoxelTileCodecScript.sv_tile_bounds(voxel_px, tile_size)

## 标记指定 SV 像素瓦片为脏；状态(_sv_dirty_tiles)现归 _tile_store 所有，此处为委托桩
func _mark_sv_tile_dirty(
	slice_index: int,
	voxel_xz: Vector2i,
	layer: String = "scene",
	tile_size: int = SV_RESIDENT_TILE_SIZE,
	source_record: Dictionary = {},
	update_scene_voxel_tile: bool = true
) -> void:
	_tile_store._mark_sv_tile_dirty(slice_index, voxel_xz, layer, tile_size, source_record, update_scene_voxel_tile)

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

## 在执行 gc_frame 时临时保留指定 RID 列表不被释放，帧结束后恢复原 scope；由需要跨帧持有中间 GPU 缓冲的 pass 调用
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

	var dirty_tiles_snapshot := _tile_store._dirty_sv_pixel_tile_snapshot()

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
		"complexity_field_format": SCENE_VOXEL_TILE_COMPLEXITY_FIELD_FORMAT,
		"complexity_field_stride_bytes": SCENE_VOXEL_TILE_COMPLEXITY_FIELD_STRIDE_BYTES,

		"collision_field_runtime_read_source": "resident_gpu_buffer" if collision_summary_buffer.is_valid() else "cpu_computed",
		"collision_field_format": SCENE_VOXEL_TILE_COLLISION_FIELD_FORMAT,
		"collision_field_stride_bytes": SCENE_VOXEL_TILE_COLLISION_FIELD_STRIDE_BYTES,
		"collision_field_upload_stride_bytes": SCENE_VOXEL_TILE_COLLISION_FIELD_UPLOAD_STRIDE_BYTES,

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

	_tile_store.clear_all_dirty()

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

## 应用单条体素写入规格并返回提交报告(占位/实例盖章写入的统一入口)
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

## ─── 3D Voxel Volume ───

##

## Aggregates all 2D channel occupancy into a unified 3D voxel grid.

var _volume: Dictionary = {}

## Per placed runtime voxel_write_spec entries. These connect runtime MeshInstance3D nodes back

## to the voxel channel data that was stamped for them.

var _voxel_write_specs: Array[Dictionary] = []

var _voxel_write_spec_index: Dictionary = {}

var _sv: Dictionary = {}

# _sv_dirty_tiles(A 表示)现归 _tile_store 所有，见 scene_voxel_tile_store.gd
var _sv_dirty_rects: Array[Rect2i] = []

var _generation_tick: int = 1

var _committed_tick: int = 0

var _sv_dirty: bool = true

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
	var voxel_px := world_to_volume_pixel(Vector3(wx, height_above_terrain, wz), int(_volume.xz_res))
	var slices: Array = _volume.slices
	var meta: Array = _volume.slice_meta
	var scene_voxels: Dictionary = _volume.get("scene_voxels", {})
	for i in range(meta.size()):
		var m: Dictionary = meta[i]
		if height_above_terrain >= m.y_min and height_above_terrain < m.y_max:
			var sample := _sample_scalar_image_pixel_gpu(slices[i] as Image, voxel_px)
			if sample.is_empty():
				push_error("[SceneVoxelCommitter] query_voxel GPU sample failed")
				return {"complexity": 0.0, "color": Color.BLACK}
			var v := clampf(float(sample.get("value", 0.0)), 0.0, 1.0)
			# 命中已提交 scene_voxel 用其字段,否则用采样值 + meta 颜色;统一经 SceneVoxel.accepted_internal 规范化
			var committed = scene_voxels.get(SceneVoxelSourceRecordScript.scene_voxel_key(i, voxel_px), {})
			var source: Dictionary
			if committed is Dictionary and not (committed as Dictionary).is_empty():
				source = committed
			else:
				var color: Color = m.color
				color.a = v
				source = {"complexity": v, "color": color}
			var rec := SceneVoxelScript.accepted_internal(source)
			rec["slice_index"] = i
			rec["voxel_xz"] = voxel_px
			return rec
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

	_tile_store.clear_all_dirty()

	if not _sv.is_empty():

		_sv["dirty_tile_count"] = 0

		_sv["dirty_tiles"] = {}

		_sv["dirty_scene_voxel_tile_count"] = 0

		_sv["dirty_scene_voxel_tiles"] = {}

		_sv["dirty_rects"] = []

		_sv["scene_voxel_tile_gpu_autoobject_ref_count"] = _tile_store._scene_voxel_tile_gpu_autoobject_refs.size()

	_maybe_auto_upload_scene_voxel_tile_buffers("clear_sv_dirty")

	_publish_scene_voxel_tile_gpu_summary_to_sv()

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

## ===== SceneVoxelTileStore 委托桩(抽出后保持内部/外部调用兼容) =====
## 将 GPU 归约出的 tile 摘要写入内部状态；由 _rebuild_sv 调用，委托 _tile_store
func _apply_scene_voxel_tile_reduce_summaries(reduced: Dictionary) -> void:
	_tile_store._apply_scene_voxel_tile_reduce_summaries(reduced)
## 清除所有 SceneVoxelTile 的脏标记；由 _rebuild_sv 调用，委托 _tile_store
func _clear_scene_voxel_tile_dirty_flags() -> void:
	_tile_store._clear_scene_voxel_tile_dirty_flags()
## 返回当前脏 SceneVoxelTile 字典快照；由 blend_scene_voxels、_rebuild_sv 调用，委托 _tile_store
func _dirty_scene_voxel_tile_snapshot() -> Dictionary:
	return _tile_store._dirty_scene_voxel_tile_snapshot()
## 从归约摘要构建旧式 tile 摘要字典（供 _sv["tiles"] 使用）；由 _rebuild_sv 调用，委托 _tile_store
func _legacy_sv_tiles_from_reduce_summaries(reduced: Dictionary,
	tile_size: int,
	dirty_tiles_snapshot: Dictionary) -> Dictionary:
	return _tile_store._legacy_sv_tiles_from_reduce_summaries(reduced, tile_size, dirty_tiles_snapshot)
## 标记 SceneVoxelTile 暂存为脏，触发下次上传；由 configure_scene_voxel_grid 等调用，委托 _tile_store
func _mark_scene_voxel_tile_staging_dirty(reason: String = "staging_changed") -> void:
	_tile_store._mark_scene_voxel_tile_staging_dirty(reason)
## 若自动上传开启则将暂存 tile 数据上传至 GPU；由 _rebuild_sv、get_sv、clear_sv_dirty 调用，委托 _tile_store
func _maybe_auto_upload_scene_voxel_tile_buffers(reason: String = "auto_upload") -> void:
	_tile_store._maybe_auto_upload_scene_voxel_tile_buffers(reason)
## 重建所有 SceneVoxelTile 的 source_ref 引用表；由 _rebuild_sv 调用，委托 _tile_store
func _rebuild_scene_voxel_tile_source_refs() -> void:
	_tile_store._rebuild_scene_voxel_tile_source_refs()
## GPU 归约体素复杂度/碰撞场为 tile 级别摘要；由 _rebuild_sv 调用，委托 _tile_store
func _reduce_scene_voxel_tile_summaries_gpu(complexity_field: PackedFloat32Array,
	collision_field: PackedFloat32Array,
	xz_res: int,
	total_slices: int,
	tile_size: Vector3i,
	buffer_contract: Dictionary = {}) -> Dictionary:
	return _tile_store._reduce_scene_voxel_tile_summaries_gpu(complexity_field, collision_field, xz_res, total_slices, tile_size, buffer_contract)
## 注册场景体素 tile 尺寸的项目设置项；由 _init 调用，委托 _tile_store
func _register_scene_voxel_tile_project_settings() -> void:
	_tile_store._register_scene_voxel_tile_project_settings()
## 重置所有 SceneVoxelTile 的摘要字段；由 _rebuild_sv 调用，委托 _tile_store
func _reset_scene_voxel_tile_summaries() -> void:
	_tile_store._reset_scene_voxel_tile_summaries()
## 判断指定体素是否属于脏 SceneVoxelTile；由 source stream 过滤路径调用，委托 _tile_store
func _scene_voxel_in_dirty_scene_voxel_tiles(scene_voxel: Dictionary, dirty_scene_voxel_tiles: Dictionary) -> bool:
	return _tile_store._scene_voxel_in_dirty_scene_voxel_tiles(scene_voxel, dirty_scene_voxel_tiles)
## 返回 tile 坐标对应的体素包围盒字典；由 _mark_legacy_sv_tiles_for_scene_voxel_tile 调用，委托 _tile_store
func _scene_voxel_tile_bounds(tile_coord: Vector3i) -> Dictionary:
	return _tile_store._scene_voxel_tile_bounds(tile_coord)
## 从写入规格记录推算 SceneVoxelTile 包围盒；由 apply_voxel_write_spec 调用，委托 _tile_store
func _scene_voxel_tile_bounds_from_record(record: Dictionary) -> Dictionary:
	return _tile_store._scene_voxel_tile_bounds_from_record(record)
## 返回当前 SceneVoxelTile 的三维体素尺寸 Vector3i；由 _rebuild_sv 调用，委托 _tile_store
func _scene_voxel_tile_size() -> Vector3i:
	return _tile_store._scene_voxel_tile_size()
## 标记指定体素所在的 SceneVoxelTile 为脏；由 _mark_sv_tile_dirty 调用，委托 _tile_store
func _touch_scene_voxel_tile_from_voxel(slice_index: int, voxel_xz: Vector2i, dirty_flags = {}, source_record: Dictionary = {}) -> void:
	_tile_store._touch_scene_voxel_tile_from_voxel(slice_index, voxel_xz, dirty_flags, source_record)
## 应用单条 GPU autoobject 脏增量到 tile object_ref 缓冲；由 GPUAutoObjectRuntime 调用，委托 _tile_store
func apply_gpu_autoobject_dirty_delta(delta: Dictionary, dispatch_object_ref_update: bool = false) -> Dictionary:
	return _tile_store.apply_gpu_autoobject_dirty_delta(delta, dispatch_object_ref_update)
## 批量应用 GPU autoobject 脏增量；由 GPUAutoObjectRuntime 批量更新时调用，委托 _tile_store
func apply_gpu_autoobject_dirty_deltas(deltas: Array) -> Dictionary:
	return _tile_store.apply_gpu_autoobject_dirty_deltas(deltas)
## 确保 SceneVoxelTile GPU 缓冲已上传；由渲染前强制同步路径调用，委托 _tile_store
func ensure_scene_voxel_tile_buffers_uploaded(force: bool = false) -> bool:
	return _tile_store.ensure_scene_voxel_tile_buffers_uploaded(force)
## 返回当前脏 SceneVoxelTile 字典（外部查询）；由调试工具、ScenePlacementActor 调用，委托 _tile_store
func get_dirty_scene_voxel_tiles() -> Dictionary:
	return _tile_store.get_dirty_scene_voxel_tiles()
## 返回 GPU autoobject object_ref 分配策略诊断信息；由调试工具调用，委托 _tile_store
func get_gpu_autoobject_object_ref_range_policy_diagnostics(refs_per_tile: int = SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT) -> Dictionary:
	return _tile_store.get_gpu_autoobject_object_ref_range_policy_diagnostics(refs_per_tile)
## 返回指定 tile 坐标的 SceneVoxelTile 数据字典；由外部查询与调试工具调用，委托 _tile_store
func get_scene_voxel_tile(tile_coord: Vector3i) -> Dictionary:
	return _tile_store.get_scene_voxel_tile(tile_coord)
## 返回指定名称的 SceneVoxelTile GPU 缓冲 RID；由 AutoObjectProbePrefilterGPU 等 GPU pass 调用，委托 _tile_store
func get_scene_voxel_tile_gpu_buffer(buffer_name: String) -> RID:
	return _tile_store.get_scene_voxel_tile_gpu_buffer(buffer_name)
## 返回 SceneVoxelTile GPU 缓冲状态摘要字典；由 _publish_scene_voxel_tile_gpu_summary_to_sv 调用，委托 _tile_store
func get_scene_voxel_tile_gpu_buffer_summary() -> Dictionary:
	return _tile_store.get_scene_voxel_tile_gpu_buffer_summary()
## 返回 SceneVoxelTile summary GPU 缓冲 RID；由 _publish_scene_voxel_tile_gpu_summary_to_sv 调用，委托 _tile_store
func get_scene_voxel_tile_summary_gpu_buffer() -> RID:
	return _tile_store.get_scene_voxel_tile_summary_gpu_buffer()
## 返回所有 SceneVoxelTile 字典的副本；由外部查询与调试工具调用，委托 _tile_store
func get_scene_voxel_tiles() -> Dictionary:
	return _tile_store.get_scene_voxel_tiles()
## 查询 SceneVoxelTile GPU 自动上传开关状态；由调试工具调用，委托 _tile_store
func is_scene_voxel_tile_gpu_auto_upload_enabled() -> bool:
	return _tile_store.is_scene_voxel_tile_gpu_auto_upload_enabled()
## 返回 SceneVoxelTile GPU 缓冲是否就绪；由渲染路径前置检查调用，委托 _tile_store
func is_scene_voxel_tile_gpu_ready() -> bool:
	return _tile_store.is_scene_voxel_tile_gpu_ready()
## 将所有 SceneVoxelTile 标记为脏；由 _mark_scene_voxel_full_rebuild_dirty 调用，委托 _tile_store
func mark_all_scene_voxel_tiles_dirty(dirty_flags = {}, source_record: Dictionary = {}) -> Dictionary:
	return _tile_store.mark_all_scene_voxel_tiles_dirty(dirty_flags, source_record)
## 将指定体素包围盒内的 SceneVoxelTile 标记为脏；由 apply_voxel_write_spec 调用，委托 _tile_store
func mark_scene_voxel_tile_bounds_dirty(voxel_min: Vector3i, voxel_max: Vector3i, dirty_flags = {}, source_record: Dictionary = {}) -> void:
	_tile_store.mark_scene_voxel_tile_bounds_dirty(voxel_min, voxel_max, dirty_flags, source_record)
## 标记指定 tile 坐标为脏；由外部直接调用路径使用，委托 _tile_store
func mark_scene_voxel_tile_dirty(tile_coord: Vector3i, dirty_flags = {}, source_record: Dictionary = {}) -> void:
	_tile_store.mark_scene_voxel_tile_dirty(tile_coord, dirty_flags, source_record)
## CPU 回读 SceneVoxelTile GPU 缓冲内容用于调试；由调试工具调用，委托 _tile_store
func readback_scene_voxel_tile_debug_snapshot() -> Dictionary:
	return _tile_store.readback_scene_voxel_tile_debug_snapshot()
## 设置 SceneVoxelTile GPU 自动上传开关并可选立即上传；由外部控制路径调用，委托 _tile_store
func set_scene_voxel_tile_gpu_auto_upload(enabled: bool, upload_now: bool = false) -> bool:
	return _tile_store.set_scene_voxel_tile_gpu_auto_upload(enabled, upload_now)
## 尝试对 CPU 增量列表执行 GPU object_ref update pass；由 GPUAutoObjectRuntime 调用，委托 _tile_store
func try_apply_gpu_autoobject_object_ref_update_pass(deltas: Array) -> Dictionary:
	return _tile_store.try_apply_gpu_autoobject_object_ref_update_pass(deltas)
## 尝试直接从 GPU 缓冲执行 object_ref update pass（零拷贝路径）；由 GPUAutoObjectRuntime 调用，委托 _tile_store
func try_apply_gpu_autoobject_object_ref_update_pass_from_buffer(dirty_delta_buffer: RID,
	dirty_delta_count: int,
	dirty_delta_capacity: int = -1,
	dirty_delta_source: String = "borrowed_dirty_delta_buffer") -> Dictionary:
	return _tile_store.try_apply_gpu_autoobject_object_ref_update_pass_from_buffer(dirty_delta_buffer, dirty_delta_count, dirty_delta_capacity, dirty_delta_source)

## ===== SceneVoxelSourceStaging 委托桩(抽出后保持内部/外部调用兼容) =====
## 清空所有场景体素 source stream；由 _rebuild_scene_voxels_from_records 调用，委托 _source_staging
func _clear_scene_voxel_source_streams() -> void:
	_source_staging._clear_scene_voxel_source_streams()
## 将 GPU payload 数组写入最终 scene_voxels 字典；由 blend_scene_voxels 调用，委托 _source_staging
func _commit_scene_voxel_sources_from_gpu_payloads(source_keys: Array,
	payloads: PackedFloat32Array,
	final_scene_voxels: Dictionary,
	commit_tick: int) -> void:
	_source_staging._commit_scene_voxel_sources_from_gpu_payloads(source_keys, payloads, final_scene_voxels, commit_tick)
## 判断已提交 payload 的 dense GPU projection 是否就绪；由 blend_scene_voxels 调用，委托 _source_staging
func _committed_scene_voxel_dense_projection_ready(expected_count: int = -1) -> bool:
	return _source_staging._committed_scene_voxel_dense_projection_ready(expected_count)
## 返回与脏 tile 相关联的 source stream 键集合；由 blend_scene_voxels 调用，委托 _source_staging
func _dirty_scene_voxel_source_stream_keys(previous_scene_voxels: Dictionary, dirty_scene_voxel_tiles: Dictionary) -> Dictionary:
	return _source_staging._dirty_scene_voxel_source_stream_keys(previous_scene_voxels, dirty_scene_voxel_tiles)
## 将源体素记录入队等待 flush；由 _stamp_volume_slices 调用，委托 _source_staging
func _enqueue_scene_voxel_source_record(source_voxel: Dictionary, source_tick: int = -1) -> void:
	_source_staging._enqueue_scene_voxel_source_record(source_voxel, source_tick)
## 从已提交 GPU 缓冲回填 CPU 调试缓存 scene_voxels；由 get_scene_voxels、get_scene_voxel 等调用，委托 _source_staging
func _hydrate_scene_voxel_public_debug_cache_from_committed_buffers() -> bool:
	return _source_staging._hydrate_scene_voxel_public_debug_cache_from_committed_buffers()
## 构建场景体素源记录模板字典；由 apply_voxel_write_spec 内的 stamp 路径调用，委托 _source_staging
func _make_scene_voxel_source_record_template(record: Dictionary,

	layer: Dictionary,

	voxel_px: Vector2i,

	complexity: float) -> Dictionary:
	return _source_staging._make_scene_voxel_source_record_template(record, layer, voxel_px, complexity)
## 标记公共调试缓存已从 CPU committed map 更新；由 blend_scene_voxels 调用，委托 _source_staging
func _mark_scene_voxel_public_debug_cache_from_committed_map(commit_tick: int, expected_count: int) -> void:
	_source_staging._mark_scene_voxel_public_debug_cache_from_committed_map(commit_tick, expected_count)
## 将调试缓存摘要回写进 _sv 字典；由 get_sv 调用，委托 _source_staging
func _publish_scene_voxel_public_debug_cache_summary_to_sv() -> void:
	_source_staging._publish_scene_voxel_public_debug_cache_summary_to_sv()
## 释放已提交 payload GPU 缓冲 RID；由 blend_scene_voxels source_resolve 失败路径调用，委托 _source_staging
func _release_committed_scene_voxel_payload_buffer() -> void:
	_source_staging._release_committed_scene_voxel_payload_buffer()
## 从 source resolve 摘要提取 bridge 诊断字段；由 blend_scene_voxels 构建最终 commit 摘要时调用，委托 _source_staging
func _scene_voxel_source_bridge_diagnostics_from_summary(summary: Dictionary) -> Dictionary:
	return _source_staging._scene_voxel_source_bridge_diagnostics_from_summary(summary)
## 返回 source candidate 常驻缓冲诊断信息；由 source candidate 批量报告路径调用，委托 _source_staging
func _scene_voxel_source_candidate_resident_diagnostics(staged: bool) -> Dictionary:
	return _source_staging._scene_voxel_source_candidate_resident_diagnostics(staged)
## 判断 GPU source resolve dispatch 当前是否被阻断；由 blend_scene_voxels 前置检查调用，委托 _source_staging
func _scene_voxel_source_resolve_blocked() -> bool:
	return _source_staging._scene_voxel_source_resolve_blocked()
## 返回所有激活 source stream 的键值映射；由 blend_scene_voxels 调用，委托 _source_staging
func _scene_voxel_source_stream_map() -> Dictionary:
	return _source_staging._scene_voxel_source_stream_map()
## 从已提交 GPU 缓冲异步暂存公共调试缓存；由 blend_scene_voxels 在 dense projection 就绪时调用，委托 _source_staging
func _stage_scene_voxel_public_debug_cache_from_committed_buffers(commit_tick: int, expected_count: int) -> void:
	_source_staging._stage_scene_voxel_public_debug_cache_from_committed_buffers(commit_tick, expected_count)
## 尝试在 GPU 上归并 source stream 为 commit payload；由 blend_scene_voxels 调用，委托 _source_staging
func _try_blend_scene_voxel_commit_payloads_gpu(source_keys: Array, _commit_tick: int) -> Dictionary:
	return _source_staging._try_blend_scene_voxel_commit_payloads_gpu(source_keys, _commit_tick)
## 从 source stream 在 GPU 上构建 complexity field（PackedFloat32Array）；由 _rebuild_sv 调用，委托 _source_staging
func _try_make_sv_complexity_field_from_source_streams_gpu(xz_res: int, total_slices: int) -> PackedFloat32Array:
	return _source_staging._try_make_sv_complexity_field_from_source_streams_gpu(xz_res, total_slices)
## 同上并返回含 RID 与元数据的完整结果字典；由 _rebuild_sv 调用，委托 _source_staging
func _try_make_sv_complexity_field_from_source_streams_gpu_result(xz_res: int,
	total_slices: int,
	output_buffer_scope: String = "") -> Dictionary:
	return _source_staging._try_make_sv_complexity_field_from_source_streams_gpu_result(xz_res, total_slices, output_buffer_scope)
## 返回已提交 payload GPU 缓冲摘要；由 blend_scene_voxels 与 _rebuild_sv 调用，委托 _source_staging
func get_committed_scene_voxel_payload_buffer_summary() -> Dictionary:
	return _source_staging.get_committed_scene_voxel_payload_buffer_summary()
## 将待处理 source candidate 上传到 GPU resident 缓冲（外部手动 flush 入口）；由 ScenePlacementActor 调用，委托 _source_staging
func stage_pending_scene_voxel_source_candidates_to_resident_buffers() -> Dictionary:
	return _source_staging.stage_pending_scene_voxel_source_candidates_to_resident_buffers()

## ===== SceneVoxelCollisionField 委托桩 =====
## 创建指定分辨率的空白 R32F 碰撞图像；由 _init 初始化碰撞场时调用，委托 _field_builder
func _create_collision_image(resolution: int) -> Image:
	return _field_builder._create_collision_image(resolution)
## 将 collision_layers 盖印到 source 碰撞场并返回更新后的层列表；由 apply_voxel_write_spec 调用，委托 _field_builder
func _make_source_collision(base_px: Vector2i, collision_layers: Array, rec: Dictionary = {}) -> Array[Dictionary]:
	return _field_builder._make_source_collision(base_px, collision_layers, rec)
## 从 collision 字典构建体素级别碰撞 float field；由 _rebuild_sv 调用，委托 _field_builder
func _make_sv_collision_field(collision: Dictionary, xz_res: int, total_slices: int) -> PackedFloat32Array:
	return _field_builder._make_sv_collision_field(collision, xz_res, total_slices)
## CPU 路径：从碰撞记录汇总构建 collision summary float field；由 _rebuild_sv GPU 路径失败时回退调用，委托 _field_builder
func _make_sv_collision_record_summary_field(collision: Dictionary, xz_res: int, total_slices: int) -> PackedFloat32Array:
	return _field_builder._make_sv_collision_record_summary_field(collision, xz_res, total_slices)
## GPU 路径：将碰撞记录摘要上传为 GPU storage buffer；由 _rebuild_sv 调用，委托 _field_builder
func _make_sv_collision_record_summary_gpu_buffer(collision: Dictionary,
	xz_res: int,
	total_slices: int,
	output_buffer_scope: String) -> Dictionary:
	return _field_builder._make_sv_collision_record_summary_gpu_buffer(collision, xz_res, total_slices, output_buffer_scope)
## 从已提交 scene_voxels 重建共享碰撞场缓存；由 blend_scene_voxels 提交完成后调用，委托 _field_builder
func _rebuild_shared_field_cache_from_scene_voxels(scene_voxels: Dictionary) -> void:
	_field_builder._rebuild_shared_field_cache_from_scene_voxels(scene_voxels)
## 将碰撞场图像双线性重采样到目标分辨率；由 build_voxel_volume 等需要分辨率对齐时调用，委托 _field_builder
func _resample_collision_field(source_img: Image, xz_res: int) -> Image:
	return _field_builder._resample_collision_field(source_img, xz_res)
## 在 GPU 上采样 R32F 图像指定像素值；由 query_voxel 调用，委托 _field_builder
func _sample_scalar_image_pixel_gpu(img: Image, px: Vector2i) -> Dictionary:
	return _field_builder._sample_scalar_image_pixel_gpu(img, px)
## GPU 圆形盖印：在多个 slice 上同时写入体素值并收集被修改的体素坐标；由 _stamp_volume_slices 调用，委托 _field_builder
func _stamp_collect_voxel_disc_gpu(slice_images: Array,
	center_px: Vector2i,
	radius_px: int,
	value: float,
	compare_mode: int) -> Dictionary:
	return _field_builder._stamp_collect_voxel_disc_gpu(slice_images, center_px, radius_px, value, compare_mode)
## 将复杂度值盖印到 occupancy RGBA 图像的指定通道；由 apply_voxel_write_spec 调用，委托 _field_builder
func _stamp_occupancy_channel(base_px: Vector2i, channel: int, radius_px: int, complexity: float) -> void:
	_field_builder._stamp_occupancy_channel(base_px, channel, radius_px, complexity)
## 将 collision_layers 盖印到共享碰撞场并返回成功应用的层列表；由 apply_voxel_write_spec 调用，委托 _field_builder
func _stamp_shared_field_layers(base_px: Vector2i, field_layers: Array, rec: Dictionary = {}) -> Array[Dictionary]:
	return _field_builder._stamp_shared_field_layers(base_px, field_layers, rec)
## 将外部掩码图像导入到指定 occupancy 通道，按 complexity 混合；由 ScenePlacementActor 导入地形遮罩时调用，委托 _field_builder
func import_mask_channel(channel: int, mask_img: Image, complexity: float = 1.0) -> void:
	_field_builder.import_mask_channel(channel, mask_img, complexity)
## 设置地形基础碰撞场（TerrainBase 层）；由 ScenePlacementActor 更新地形时调用，委托 _field_builder
func set_terrain_base_collision_field(base_collision: Image) -> void:
	_field_builder.set_terrain_base_collision_field(base_collision)
