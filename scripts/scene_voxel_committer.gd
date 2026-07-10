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
## Stamp-only commit：CPU 入口盖章的 field 写入记录 (x, z, slice, complexity, r, g, b, collision)
## stride/路径/键/展平契约已抽取到 utils/sv_field_scatter.gd（与 SPA BrushSV 散射共享）。
const SvFieldScatter := preload("res://scripts/utils/sv_field_scatter.gd")
const SV_FIELD_RECORD_FLOAT_STRIDE := SvFieldScatter.RECORD_FLOAT_STRIDE
const SV_FIELD_SCATTER_SHADER_PATH := SvFieldScatter.SHADER_PATH

## std430 push-constant 布局：_flush_pending_sv_field_records 的 field 散射（16B，4×int）
const SV_FIELD_SCATTER_PUSH := [
	["xz_res", "int"],
	["total_slices", "int"],
	["record_count", "int"],
	["merge_mode", "int"],
]

## std430 push-constant 布局：_make_occupancy_slice_image_gpu 的占据切片投影（32B，6×int + 2×float）
const OCCUPANCY_SLICE_PUSH := [
	["xz_res", "int"],
	["xz_res_2", "int"],
	["occ_width", "int"],
	["occ_height", "int"],
	["base_res", "int"],
	["channel", "int"],
	["epsilon", "float"],
	["_pad_f", "float"],
]

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
const SceneVoxelSourceRecordScript := preload("res://scripts/scene_voxel_source_record.gd")
const SceneVoxelScript := preload("res://scripts/scene_voxel.gd")
const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")
const SceneVoxelVolumeChannelsScript := preload("res://scripts/scene_voxel_volume_channels.gd")
const SceneVoxelTargetScript := preload("res://scripts/scene_voxel_target.gd")
const VariantUtils := preload("res://scripts/utils/variant_utils.gd")
const VoxelGeneralScript := preload("res://scripts/utils/voxel_general.gd")

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
var _terrain_base_collision_field: Image:
	get:
		return _field_builder._terrain_base_collision_field if _field_builder else null
	set(value):
		if _field_builder:
			_field_builder._terrain_base_collision_field = value

## 初始化体素提交器，设置基础分辨率、捕获范围并按需启用 GPU
func _init(base_resolution: int, capture_size: float, _enable_gpu: bool = true) -> void:

	_base_res = base_resolution

	_capture_size = capture_size

	_tile_store = SceneVoxelTileStoreScript.new()

	_tile_store._committer = self

	_field_builder = SceneVoxelCollisionFieldScript.new()

	_field_builder._committer = self

	_register_scene_voxel_tile_project_settings()

	grid_origin = _default_grid_origin()

	voxel_size = _voxel_size_for_resolution(_base_res, 1.0)

	grid_size = Vector3i(_base_res, 1, _base_res)

	occupancy = Image.create(_base_res, _base_res, false, Image.FORMAT_RGBAH)

	occupancy.fill(Color(0.0, 0.0, 0.0, 0.0))

	_terrain_base_collision_field = _create_collision_image(_base_res)

	_init_gpu()

	_tile_store.attach_rendering_device(_rd, false)

	_tile_store.setup(self, _base_res)

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

## 释放 sampler 并重置 GPU 就绪状态(shader/pipeline 已下沉至三子系统)
func _free_gpu() -> void:

	dispose()

	_sampler = RID()

	_gpu_ready = false

## 释放前回调，清理场景体素 tile 与碰撞场子系统的常驻 GPU 缓冲
func _on_before_dispose() -> void:

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

## _gc_frame_preserving_rids 已上移到计算基类 godot_compute_shader_base.gd（供本类与 SceneVoxelTileStore 共享）。

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

	# Stamp-only commit：常驻 field buffer 即 committed SV 主状态（stamp/散射直写，不再从源流重建）。
	# Explicit Dictionary type: the committer<->tile_store preload cycle prevents GDScript from
	# inferring the return type of _tile_store methods with :=.
	var field_buffers: Dictionary = _tile_store.ensure_resident_field_buffers()

	var complexity_field := PackedFloat32Array()

	var complexity_field_buffer: RID = field_buffers.get("complexity_field_buffer", RID())

	var complexity_field_source := "resident_stamped_field_buffer"
	var complexity_field_runtime_read_source := "resident_stamped_field_buffer" if complexity_field_buffer.is_valid() else "none"

	if not complexity_field_buffer.is_valid():
		push_error("[SceneVoxelCommitter] SV resident complexity field buffer unavailable")
		complexity_field_source = "resident_field_buffer_missing"

	var collision_field := PackedFloat32Array()

	var collision_summary_buffer_scope := "_rebuild_sv_collision_summary_buffer"

	# 该临时摘要 buffer 由 _field_builder 创建并登记在它自己的 tracker 上；gc 必须落在同一实例
	_field_builder.gc_scope(collision_summary_buffer_scope)

	# 摘要口径：collision 侧刻意用"仅 CPU 碰撞记录"的临时摘要场（不含 terrain base，避免地面 tile 全部
	# 报告 collision 占用；也不含 VPG 双写进常驻场的碰撞——VPG 放置物的 tile 占用由 complexity 侧体现）。
	var collision_summary_buffer_result := _make_sv_collision_record_summary_gpu_buffer(collision, xz_res, total_slices, collision_summary_buffer_scope)

	var collision_summary_buffer: RID = collision_summary_buffer_result.get("collision_field_buffer", RID())

	var collision_summary_field := PackedFloat32Array()

	if not collision_summary_buffer.is_valid():
		collision_summary_field = _make_sv_collision_record_summary_field(collision, xz_res, total_slices)

	_volume["collision_field"] = _resample_collision_field(_terrain_base_collision_field, xz_res)

	var tile_grid_size := Vector3i(

		ceili(float(grid_size.x) / float(tile_size)),

		ceili(float(grid_size.y) / float(tile_size)),

		ceili(float(grid_size.z) / float(tile_size))

	)

	var total_tiles := tile_grid_size.x * tile_grid_size.y * tile_grid_size.z

	var dirty_tiles_snapshot: Dictionary = _tile_store._copy_sv_pixel_tile()

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

	_field_builder.gc_scope(collision_summary_buffer_scope)

	_rebuild_scene_voxel_tile_source_refs()

	dirty_scene_voxel_tiles_snapshot = _copy_scene_voxel_tile()
	if not dirty_scene_voxel_tiles_snapshot.is_empty():
		_tile_store._scene_voxel_tile_pending_resident_upload_tiles = dirty_scene_voxel_tiles_snapshot.duplicate(true)

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

		"commit_mode": "stamp_only_commit",

		"last_commit_summary": _last_commit_summary.duplicate(true),

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

		"collision_voxel_count": collision.size(),

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

## 在3D体素切片上盖章圆形复杂度；stamp 即提交：直接写公共投影并排队常驻 field 散射记录
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

	var force_source_write := bool(scene_voxel_template.get("write_empty_voxels", false))

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
		var stamp_color := VariantUtils.color_from_value(scene_voxel_template.get("color", Color.WHITE), Color.WHITE)
		var resolved_tick := write_tick if write_tick >= 0 else _generation_tick
		var scene_voxels: Dictionary = _volume.get("scene_voxels", {})
		for rec in stamp_result.get("records", []):
			var local_slice := int(rec.slice_local)
			if local_slice < 0 or local_slice >= slice_indices.size():
				continue
			var slice_index: int = slice_indices[local_slice]
			var stamp_voxel_px := Vector2i(int(rec.x), int(rec.z))
			var scene_voxel := scene_voxel_template.duplicate(true)
			scene_voxel["slice_index"] = slice_index
			scene_voxel["voxel_xz"] = stamp_voxel_px
			scene_voxel["complexity"] = v
			scene_voxel = SharedPropertyTypeScript.apply_to_scene_voxel(scene_voxel, scene_voxel, v, SharedPropertyTypeScript.has_collision_fields(scene_voxel))
			scene_voxel = SceneVoxelSourceRecordScript.prepare_source_record(scene_voxel, resolved_tick)
			scene_voxel["commit_tick"] = resolved_tick
			scene_voxels[SceneVoxelSourceRecordScript.scene_voxel_key(slice_index, stamp_voxel_px)] = scene_voxel
			_queue_sv_field_record(stamp_voxel_px, slice_index, v, stamp_color, 0.0)
			_mark_sv_tile_dirty(slice_index, stamp_voxel_px, "scene", SV_RESIDENT_TILE_SIZE, scene_voxel)
		_volume["scene_voxels"] = scene_voxels

	_volume["slices"] = slices

	return voxel_px

## 排队一条 stamp-only 提交的 field 散射记录；complexity < 0 表示仅写碰撞。
## 同体素记录合并：复杂度/颜色后写者胜（与公共投影语义一致），碰撞取 max（与 GPU atomic 一致）。
func _queue_sv_field_record(voxel_xz: Vector2i, slice_index: int, complexity: float, color: Color, collision_strength: float) -> void:
	var record_key := SvFieldScatter.record_key(voxel_xz, slice_index)
	var slot: PackedFloat32Array = _pending_sv_field_records.get(record_key, PackedFloat32Array())
	if slot.is_empty():
		slot.resize(SV_FIELD_RECORD_FLOAT_STRIDE)
		slot[0] = float(voxel_xz.x)
		slot[1] = float(voxel_xz.y)
		slot[2] = float(slice_index)
		slot[3] = -1.0
	if complexity >= 0.0:
		slot[3] = complexity
		slot[4] = color.r
		slot[5] = color.g
		slot[6] = color.b
	slot[7] = maxf(slot[7], clampf(collision_strength, 0.0, 1.0))
	_pending_sv_field_records[record_key] = slot

## 将 pending field 记录一次稀疏散射进常驻 field buffer（stamp-only commit 的 CPU 入口半边）
func _flush_pending_sv_field_records() -> Dictionary:
	var record_count := _pending_sv_field_records.size()
	if record_count <= 0:
		return {"ok": true, "record_count": 0, "gpu_dispatched": false}
	if _volume.is_empty() or not _gpu_ready or _rd == null:
		return {"ok": false, "reason": "gpu_or_volume_not_ready", "record_count": record_count, "gpu_dispatched": false}

	var field_buffers: Dictionary = _tile_store.ensure_resident_field_buffers()
	var complexity_buffer: RID = field_buffers.get("complexity_field_buffer", RID())
	var collision_buffer: RID = field_buffers.get("collision_field_buffer", RID())
	if not complexity_buffer.is_valid() or not collision_buffer.is_valid():
		return {"ok": false, "reason": "resident_field_buffers_missing", "record_count": record_count, "gpu_dispatched": false}

	var shader := load_compute_shader(SV_FIELD_SCATTER_SHADER_PATH, SCOPE_FRAME, "scatter_sv_field_records")
	var pipeline := create_compute_pipeline(shader, SCOPE_FRAME, "scatter_sv_field_records")
	if not shader.is_valid() or not pipeline.is_valid():
		gc_frame()
		return {"ok": false, "reason": "scatter_shader_not_ready", "record_count": record_count, "gpu_dispatched": false}

	var record_floats := SvFieldScatter.flatten_record_slots(_pending_sv_field_records)

	var record_buffer := storage_buffer_from_floats(record_floats, SCOPE_FRAME, "sv_field_scatter_records")
	if not record_buffer.is_valid():
		gc_frame()
		return {"ok": false, "reason": "scatter_record_buffer_failed", "record_count": record_count, "gpu_dispatched": false}

	var set0 := create_uniform_set([
		make_storage_uniform(0, complexity_buffer),
		make_storage_uniform(1, collision_buffer),
		make_storage_uniform(2, record_buffer),
	], shader, 0, SCOPE_PASS, "scatter_sv_field_records")
	if not set0.is_valid():
		gc_frame()
		return {"ok": false, "reason": "scatter_uniform_set_failed", "record_count": record_count, "gpu_dispatched": false}

	# committed SV 用 max-by-complexity 合并：常驻 field 可能已含 VPG state-chain stamp 内容，
	# CPU compare 门（基于 slices）看不到它们，单调合并防止低值覆写（merge_mode=1）。
	var push := PushConstantLayout.new(SV_FIELD_SCATTER_PUSH).pack({
		xz_res = int(_volume.xz_res),
		total_slices = int(_volume.get("total_slices", grid_size.y)),
		record_count = record_count,
		merge_mode = 1,
	})

	var groups := dispatch_groups_1d(record_count, 64)
	if not _gpu_dispatch_and_sync(pipeline, [set0], push, groups):
		gc_frame()
		return {"ok": false, "reason": "scatter_dispatch_failed", "record_count": record_count, "gpu_dispatched": false}

	gc_frame()
	_pending_sv_field_records.clear()
	return {"ok": true, "record_count": record_count, "gpu_dispatched": true}

## 构造盖章体素的公共投影模板（写入 _volume.scene_voxels 的调试/查询投影；stamp-only commit 无来源裁决）
func _make_stamped_scene_voxel_template(
	record: Dictionary,
	layer: Dictionary,
	voxel_px: Vector2i,
	complexity: float
) -> Dictionary:
	var shared_fields := SharedPropertyTypeScript.normalize_shared_fields(layer, record, complexity)
	var complexity_value := float(shared_fields.complexity)
	var scene_voxel := SharedPropertyTypeScript.apply_to_scene_voxel({
		"complexity": complexity_value,
		"channel": int(layer.get("channel", -1)),
		"slice_index": -1,  # filled per stamped voxel
		"voxel_xz": voxel_px,  # template XZ address; overwritten per stamped voxel
		"base_pixel": layer.get("base_pixel", record.get("base_pixel", Vector2i.ZERO)),  # original placement pixel
	}, shared_fields, complexity_value, false)
	var record_id := str(record.get("record_id", record.get("id", "")))
	scene_voxel["record_id"] = record_id
	scene_voxel["source_id"] = str(record.get("source_id", record_id))
	scene_voxel["auto_object_id"] = str(record.get("auto_object_id", record.get("auto_id", record_id)))
	var collision_layers: Array = record.get("collision", [])
	if not collision_layers.is_empty():
		scene_voxel = SharedPropertyTypeScript.apply_to_scene_voxel(
			scene_voxel,
			{"collision": collision_layers},
			float(scene_voxel.get("complexity", 1.0))
		)
	return scene_voxel

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
	# 碰撞为逐体素点采样：排队 collision-only field 散射记录（complexity < 0 跳过颜色写入）
	for collision_layer in updated_collision_layers:
		if not collision_layer is Dictionary:
			continue
		var layer_dict := collision_layer as Dictionary
		var layer_strength := clampf(float(layer_dict.get("collision_strength", 0.0)), 0.0, 1.0)
		if layer_strength <= VOXEL_OCCUPIED_EPSILON:
			continue
		var layer_voxel_xz = layer_dict.get("voxel_xz", Vector2i(-1, -1))
		if not layer_voxel_xz is Vector2i:
			continue
		_queue_sv_field_record(layer_voxel_xz, int(layer_dict.get("slice_index", 0)), -1.0, Color.BLACK, layer_strength)

	var ch := _record_channel(rec)
	if ch >= 0:
		var channel_record := rec.duplicate(true)
		channel_record["channel"] = ch
		channel_record["base_pixel"] = rec_base_px
		var radius_px := _record_radius_px(channel_record)
		var complexity := clampf(float(channel_record.get("complexity", rec.get("complexity", 1.0))), 0.0, 1.0)
		var color := VariantUtils.color_from_value(channel_record.get("color", rec.get("color", Color.WHITE)), Color.WHITE)
		color.a = complexity
		var slice_indices := _slice_indices_for_channel_record(channel_record, ch)
		var source_voxel_template := {}
		if not _volume.is_empty():
			var template_voxel_px := _volume_px_from_base(rec_base_px, int(_volume.xz_res))
			source_voxel_template = _make_stamped_scene_voxel_template(rec, channel_record, template_voxel_px, complexity)

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
		commit_scene_voxels(write_tick)

	return rec

## ─── 3D Voxel Volume ───

##

## Aggregates all 2D channel occupancy into a unified 3D voxel grid.

var _volume: Dictionary = {}

## Per placed runtime voxel_write_spec entries. These connect runtime MeshInstance3D nodes back

## to the voxel channel data that was stamped for them.

var _voxel_write_specs: Array[Dictionary] = []

var _voxel_write_spec_index: Dictionary = {}

var _sv: Dictionary = {}

## Stamp-only commit：待散射进常驻 field buffer 的 CPU 入口盖章记录。
## 按体素线性 index 去重（复杂度后写者胜、碰撞取 max），保证单次散射 dispatch 内无同体素竞态；
## 值为 SV_FIELD_RECORD_FLOAT_STRIDE 长度的 PackedFloat32Array 槽。
var _pending_sv_field_records: Dictionary = {}

## 最近一次 commit_scene_voxels 的提交摘要
var _last_commit_summary: Dictionary = {}

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

## 从已有写入规格记录重建场景体素状态（清空常驻 field 后逐记录重放 stamp）
func _rebuild_scene_voxels_from_records() -> void:

	if _volume.is_empty():

		return

	var write_tick := _next_write_tick()

	begin_generation_tick(write_tick)

	_volume["scene_voxels"] = {}

	_pending_sv_field_records.clear()

	_field_builder._clear_shared_field_cache()

	_tile_store.reset_resident_field_buffers()

	var records := get_voxel_write_specs()

	for record in records:

		apply_voxel_write_spec(record, true, write_tick)

## Stamp-only 提交发布点：散射 pending 盖章记录进常驻 field，推进 tick 并重建 tile 摘要。
## VPG 的 GPU state-chain stamp 已原位写入常驻 field；本函数只负责 CPU 入口盖章的散射与发布。
func commit_scene_voxels(tick: int = -1) -> Dictionary:

	if _volume.is_empty():

		return {}

	var commit_tick := tick if tick >= 0 else _generation_tick

	var scatter_result := _flush_pending_sv_field_records()

	var scene_voxels := {}

	var raw_scene_voxels = _volume.get("scene_voxels", {})

	if raw_scene_voxels is Dictionary:

		scene_voxels = raw_scene_voxels as Dictionary

	_last_commit_summary = {
		"ok": bool(scatter_result.get("ok", false)),
		"gpu_first": true,
		"cpu_fallback": false,
		"mode": "stamp_only_commit",
		"commit_tick": commit_tick,
		"scattered_field_record_count": int(scatter_result.get("record_count", 0)),
		"field_scatter_gpu_dispatched": bool(scatter_result.get("gpu_dispatched", false)),
		"field_scatter_reason": str(scatter_result.get("reason", "none")),
		"committed_scene_voxel_count": scene_voxels.size(),
		"dirty_tile_count": _copy_scene_voxel_tile().size(),
	}

	if not bool(scatter_result.get("ok", false)):
		push_error("[SceneVoxelCommitter] stamp-only commit field scatter failed: %s" % str(scatter_result.get("reason", "unknown")))

	_committed_tick = max(_committed_tick, commit_tick)

	_generation_tick = max(_generation_tick, commit_tick + 1)

	_sv_dirty = true

	_rebuild_sv()

	return SceneVoxelScript.accepted_map(scene_voxels)

## 返回最近一次 stamp-only 提交摘要的副本
func get_last_scene_voxel_commit_summary() -> Dictionary:
	return _last_commit_summary.duplicate(true)

## Debug 回读：把常驻 field buffer 解码为 CPU float 投影（显式调试/契约测试路径，不进运行时）
func readback_sv_field_debug_projection() -> Dictionary:
	if _volume.is_empty() or _rd == null:
		return {}
	var field_buffers := _tile_store.ensure_resident_field_buffers()
	var voxel_count := int(field_buffers.get("voxel_count", 0))
	var complexity_rid: RID = field_buffers.get("complexity_field_buffer", RID())
	var collision_rid: RID = field_buffers.get("collision_field_buffer", RID())
	if voxel_count <= 0 or not complexity_rid.is_valid() or not collision_rid.is_valid():
		return {}
	var complexity_bytes := _rd.buffer_get_data(complexity_rid, 0, voxel_count * SCENE_VOXEL_TILE_COMPLEXITY_FIELD_STRIDE_BYTES)
	var collision_bytes := _rd.buffer_get_data(collision_rid, 0, SceneVoxelTileCodecScript.r8_word_byte_count(voxel_count))
	return {
		"voxel_count": voxel_count,
		"readback_source": "resident_stamped_field_buffer_debug_readback",
		"complexity_field": SceneVoxelTileCodecScript.decode_complexity_field_rgba8_alpha_bytes(complexity_bytes, voxel_count),
		"collision_field": SceneVoxelTileCodecScript.decode_collision_field_r8_word_bytes(collision_bytes, voxel_count),
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

		"source_collision_field": _create_collision_image(xz_res),

		"collision_field": _resample_collision_field(_terrain_base_collision_field, xz_res),

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

	commit_scene_voxels(_generation_tick)

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

	var push := PushConstantLayout.new(OCCUPANCY_SLICE_PUSH).pack({
		xz_res = xz_res,
		xz_res_2 = xz_res,
		occ_width = occupancy.get_width(),
		occ_height = occupancy.get_height(),
		base_res = _base_res,
		channel = channel,
		epsilon = VOXEL_OCCUPIED_EPSILON,
	})

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

## 获取已提交的场景体素映射（stamp-only commit：盖章时直写的公共投影）
func get_scene_voxels() -> Dictionary:

	if _volume.is_empty():

		return {}

	var scene_voxels: Dictionary = _volume.get("scene_voxels", {})

	return SceneVoxelScript.accepted_map(scene_voxels)

## 获取场景体素状态字典并在需要时重建
func get_sv() -> Dictionary:

	if _sv_dirty and not _volume.is_empty():

		_rebuild_sv()

	elif not _sv.is_empty():

		_maybe_auto_upload_scene_voxel_tile_buffers("get_sv")

		_publish_scene_voxel_tile_gpu_summary_to_sv()

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
## 返回当前脏 SceneVoxelTile 字典快照；由 commit_scene_voxels、_rebuild_sv 调用，委托 _tile_store
func _copy_scene_voxel_tile() -> Dictionary:
	return _tile_store._copy_scene_voxel_tile()
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
