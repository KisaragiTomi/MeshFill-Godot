class_name SceneVoxelTileStore

## 场景体素瓦片(scene voxel tile)GPU 缓冲存储与归约子系统。
## 从 SceneVoxelCommitter 抽出：拥有瓦片记录/摘要/脏索引/object-ref/field 六类 GPU 缓冲，
## 以及它们的创建/复用/上传/reduce/compact/object-ref 更新全流程。
## 由 committer 持有，借用其 RenderingDevice(attach_rendering_device(_rd, false))，
## 通过 _committer 反向引用读取 committer 的 grid/_volume/_sv 等上下文。
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
const UtilsBufferUtils := preload("res://scripts/utils_buffer_utils.gd")
const SceneVoxelVolumeChannelsScript := preload("res://scripts/scene_voxel_volume_channels.gd")
const SceneVoxelBrushScript := preload("res://scripts/scene_voxel_brush.gd")
const SceneVoxelTargetScript := preload("res://scripts/scene_voxel_target.gd")
const VoxelGeneralScript := preload("res://scripts/voxel_general.gd")
const SceneVoxelDebugScript := preload("res://scripts/scene_voxel_debug.gd")


## committer 反向引用：读取 grid_size/_volume/_sv/_base_res/_generation_tick/_committed_tick，
## 并回调 _make_sv_collision_field / _mark_legacy_sv_tiles_for_scene_voxel_tile / 写 _sv_dirty。
## 由 committer 在 setup() 中设置，teardown() 中置空以打破引用环。
var _committer: SceneVoxelCommitter = null

## 瓦片 compute shader 就绪标志(本组件自有的 5 个 tile shader)
var _gpu_ready: bool = false

## --- tile compute shader 管线(本组件拥有) ---
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

## --- tile 运行时状态(从 committer 迁入) ---
var _scene_voxel_tiles: Dictionary = {}
var _scene_voxel_tile_gpu_autoobject_refs: Dictionary = {}
var _scene_voxel_tile_object_ids_debug: Array[String] = []
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
# 旧式 SV 像素瓦片脏图（A 表示）：键为 _sv_tile_key 字符串，与 _scene_voxel_tiles 的 3D 脏标志(B)双向同步
var _sv_dirty_tiles: Dictionary = {}
var _scene_voxel_tile_last_upload_mode := "none"
var _scene_voxel_tile_last_upload_tile_ids: Array[String] = []
var _scene_voxel_tile_last_upload_resident_voxel_count := 0
var _scene_voxel_tile_last_upload_range_count := 0
var _scene_voxel_tile_last_summary_dirty_range_update_source := "none"
var _scene_voxel_tile_object_ref_last_update_stats: Dictionary = {}
var _scene_voxel_tile_object_ref_key_schema := SCENE_VOXEL_TILE_OBJECT_REF_SCHEMA_LEGACY_HASH
var _scene_voxel_tile_object_ref_numeric_schema_confirmed := false
var _scene_voxel_tile_fixed_object_ref_tile_count := 0
var _scene_voxel_tile_fixed_object_ref_slot_count := 0
var _scene_voxel_tile_object_ref_rebuild_required := false
var _scene_voxel_tile_object_ref_overflow_count := 0
var _scene_voxel_tile_object_ref_overflow_tile_ids: Array[String] = []


## 由 committer 调用：绑定反向引用与基础分辨率，加载 tile compute shader。
## 调用前 committer 须已 attach_rendering_device(_rd, false)。
func setup(committer, base_resolution: int) -> void:
	_committer = committer
	log_name = "SceneVoxelTileStore"
	_init_tile_gpu()

## 加载本组件负责的 5 个 tile compute shader 与管线，置 _gpu_ready。
func _init_tile_gpu() -> void:
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
	_gpu_ready = (_pipeline_reduce_scene_voxel_tile_summaries.is_valid()
		and _pipeline_init_scene_voxel_tile_summaries.is_valid()
		and _pipeline_compact_scene_voxel_tile_summaries.is_valid()
		and _pipeline_update_scene_voxel_tile_summary_ranges.is_valid()
		and _pipeline_scene_voxel_tile_object_ref_update.is_valid())

## 释放本组件的 tile GPU 缓冲与 shader，断开反向引用。committer 须在自身 dispose 之前调用。
func teardown() -> void:
	_release_scene_voxel_tile_gpu_buffers()
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
func _gpu_dispatch_pipeline(cl: int, pipeline: RID, uniform_set: RID, push: PackedByteArray, groups: Vector3i) -> void:
	_rd.compute_list_bind_compute_pipeline(cl, pipeline)
	_rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, groups.x, groups.y, groups.z)


## 帧级 GC 但保留指定 RID(复制自 committer，作用于本组件自己的 _resources)
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

## --- 迁移自 committer 的 tile 函数 ---
func _register_scene_voxel_tile_project_settings() -> void:
	SceneVoxelTileCodecScript.register_project_settings(SCENE_VOXEL_TILE_SIZE_SETTING, DEFAULT_SCENE_VOXEL_TILE_SIZE)

## 读取配置的场景体素 tile 尺寸

func _scene_voxel_tile_size() -> Vector3i:

	return SceneVoxelTileCodecScript.configured_size(SCENE_VOXEL_TILE_SIZE_SETTING, DEFAULT_SCENE_VOXEL_TILE_SIZE)

## 根据网格尺寸与 tile 尺寸计算 tile 网格尺寸

func _scene_voxel_tile_grid_size(tile_size: Vector3i = Vector3i.ZERO) -> Vector3i:

	var size := tile_size if tile_size.x > 0 and tile_size.y > 0 and tile_size.z > 0 else _scene_voxel_tile_size()
	return SceneVoxelTileCodecScript.tile_grid_size(_committer.grid_size, size)

## 由体素坐标反推所属 tile 坐标

func _scene_voxel_tile_coord_from_voxel(voxel_coord: Vector3i) -> Vector3i:
	return SceneVoxelTileCodecScript.tile_coord_from_voxel(voxel_coord, _committer.grid_size, _scene_voxel_tile_size())

## 返回指定 tile 坐标的体素边界与基础矩形

func _scene_voxel_tile_bounds(tile_coord: Vector3i) -> Dictionary:
	return SceneVoxelTileCodecScript.tile_bounds(tile_coord, _committer.grid_size, _scene_voxel_tile_size())

## 构造指定 tile 坐标的默认 tile 记录字典

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

		"last_commit_tick": _committer._committed_tick,

		"scene_minmax": Vector2.ZERO,

		"collision_minmax": Vector2.ZERO,

		"object_range_start": 0,

		"object_range_count": 0,

		"object_debug_range_start": 0,

		"object_debug_range_count": 0,

		"auto_object_ids_debug": [],

		"scene_voxel_count": 0,

		"collision_cell_count": 0,

		"summary": {

			"scene_minmax": Vector2.ZERO,

			"collision_minmax": Vector2.ZERO,

			"scene_voxel_count": 0,

			"collision_cell_count": 0,

		},

		"dirty": false,

		"updated_this_commit": false,

	}

## 从 tile 记录中提取摘要信息

func _scene_voxel_tile_summary(tile: Dictionary) -> Dictionary:

	return {

		"scene_minmax": tile.get("scene_minmax", Vector2.ZERO),

		"collision_minmax": tile.get("collision_minmax", Vector2.ZERO),

		"scene_voxel_count": int(tile.get("scene_voxel_count", 0)),

		"collision_cell_count": int(tile.get("collision_cell_count", 0)),

	}

## 从记录中按候选键顺序取首个 Vector3i 值

func _scene_voxel_tile_first_vector3i(record: Dictionary, keys: Array[String], fallback: Vector3i = Vector3i.ZERO) -> Vector3i:
	return SceneVoxelTileCodecScript.first_vector3i(record, keys, fallback)

## 判断记录中是否包含任一候选键

func _scene_voxel_tile_has_any_key(record: Dictionary, keys: Array[String]) -> bool:
	return SceneVoxelTileCodecScript.has_any_key(record, keys)

## 规范化体素边界并裁剪到网格范围内

func _scene_voxel_tile_normalized_bounds(voxel_min: Vector3i, voxel_max: Vector3i) -> Dictionary:
	return SceneVoxelTileCodecScript.normalized_bounds(voxel_min, voxel_max, _committer.grid_size)

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

## 从记录字段解析 tile 的体素边界，支持显式边界或基于像素换算

func _scene_voxel_tile_bounds_from_record(record: Dictionary) -> Dictionary:

	if _scene_voxel_tile_has_any_key(record, ["voxel_min", "bounds_min", "new_voxel_min", "new_bounds_min"]) and _scene_voxel_tile_has_any_key(record, ["voxel_max", "bounds_max", "new_voxel_max", "new_bounds_max"]):

		var explicit_min := _scene_voxel_tile_first_vector3i(record, ["voxel_min", "bounds_min", "new_voxel_min", "new_bounds_min"], Vector3i.ZERO)

		var explicit_max := _scene_voxel_tile_first_vector3i(record, ["voxel_max", "bounds_max", "new_voxel_max", "new_bounds_max"], explicit_min + Vector3i.ONE)

		return _scene_voxel_tile_normalized_bounds(explicit_min, explicit_max)

	var xz_res := int(_committer._volume.get("xz_res", _committer.grid_size.x)) if not _committer._volume.is_empty() else maxi(_committer.grid_size.x, 1)

	var center_px := Vector2i.ZERO

	var base_px = record.get("base_pixel", null)

	if base_px is Vector2i:

		center_px = _committer._volume_px_from_base(base_px, xz_res)

	else:

		var voxel_xz = record.get("voxel_xz", Vector2i.ZERO)

		if voxel_xz is Vector2i:

			var source_res := maxi(int(record.get("volume_xz_resolution", xz_res)), 1)

			if source_res != xz_res:

				center_px = VoxelGeneralScript.base_pixel_to_volume_pixel(voxel_xz, source_res, xz_res)

			else:

				center_px = Vector2i(clampi(voxel_xz.x, 0, xz_res - 1), clampi(voxel_xz.y, 0, xz_res - 1))

	var radius_vol := _committer._volume_radius_from_base_radius(_committer._record_radius_px(record), xz_res)

	var min_y := 0

	var max_y := 1

	var slice_indices: Array = record.get("slice_indices", [])

	if not slice_indices.is_empty():

		min_y = maxi(_committer.grid_size.y, 1)

		max_y = 0

		for raw_slice in slice_indices:

			var slice_index := clampi(int(raw_slice), 0, maxi(_committer.grid_size.y - 1, 0))

			min_y = mini(min_y, slice_index)

			max_y = maxi(max_y, slice_index + 1)

	else:

		var slice_index := clampi(int(record.get("slice_index", 0)), 0, maxi(_committer.grid_size.y - 1, 0))

		min_y = slice_index

		max_y = slice_index + 1

	return _scene_voxel_tile_normalized_bounds(

		Vector3i(maxi(center_px.x - radius_vol, 0), min_y, maxi(center_px.y - radius_vol, 0)),

		Vector3i(mini(center_px.x + radius_vol + 1, _committer.grid_size.x), mini(max_y, _committer.grid_size.y), mini(center_px.y + radius_vol + 1, _committer.grid_size.z))

	)

## 从记录多个候选键中取首个非空 GPU autoobject ID

func _scene_voxel_tile_gpu_autoobject_id(record: Dictionary) -> String:

	for key in ["object_id", "auto_object_id", "auto_id", "id", "record_id"]:

		if not record.has(key):

			continue

		var value := str(record.get(key, ""))

		if not value.is_empty():

			return value

	return ""

## 从源记录候选键中取调试用对象 ID

func _scene_voxel_tile_debug_object_id(source_record: Dictionary) -> String:

	return SceneVoxelDebugScript.tile_object_id(source_record)

## 从源记录候选键中取调试用源 ID

func _scene_voxel_tile_debug_source_id(source_record: Dictionary) -> String:

	return SceneVoxelDebugScript.tile_source_id(source_record)

## 将值列表追加到目标数组，返回追加区间的起止索引

func _append_scene_voxel_tile_debug_range(target: Array[String], values: Array) -> Vector2i:

	return SceneVoxelDebugScript.append_tile_range(target, values)

## 追加调试值到列表，可选去重

func _append_scene_voxel_tile_debug_value(values: Array, value: String, unique: bool = true) -> void:

	SceneVoxelDebugScript.append_tile_value(values, value, unique)

## 向 tile 追加记录的调试对象引用，返回更新后的 tile

func _append_scene_voxel_tile_record_refs(tile: Dictionary, record: Dictionary, unique_source: bool = false) -> Dictionary:

	var debug_id := _scene_voxel_tile_debug_object_id(record)

	var ids: Array = tile.get("auto_object_ids_debug", [])

	_append_scene_voxel_tile_debug_value(ids, debug_id, true)

	tile["auto_object_ids_debug"] = ids

	return tile

## 对边界内所有 tile 追加记录引用

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

## 重建 tile 紧凑对象引用区间，统计溢出并更新调试 ID 列表

func _rebuild_scene_voxel_tile_compact_ranges() -> void:

	_scene_voxel_tile_object_ids_debug.clear()

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

		_scene_voxel_tiles[tile_id] = tile

## 重建 tile 源引用，重置引用字段后按 GPU autoobject 引用重新填充

func _rebuild_scene_voxel_tile_source_refs() -> void:

	for tile_id in _scene_voxel_tiles.keys():

		var tile: Dictionary = _scene_voxel_tiles[tile_id]

		tile["auto_object_ids_debug"] = []

		tile["object_range_start"] = 0

		tile["object_range_count"] = 0

		tile["object_debug_range_start"] = 0

		tile["object_debug_range_count"] = 0

		_scene_voxel_tiles[tile_id] = tile

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

## 触摸指定 tile，更新边界与脏标记并返回该 tile

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

	tile["write_tick"] = _committer._generation_tick

	tile["last_commit_tick"] = _committer._committed_tick

	tile["dirty"] = true

	tile["updated_this_commit"] = true

	tile = _append_scene_voxel_tile_record_refs(tile, source_record, true)

	_scene_voxel_tiles[tile_id] = tile

	_mark_scene_voxel_tile_staging_dirty("touch_scene_voxel_tile")

	_committer._sv_dirty = true

	return tile

## 由切片索引与像素坐标触摸对应 tile

func _touch_scene_voxel_tile_from_voxel(slice_index: int, voxel_xz: Vector2i, dirty_flags = {}, source_record: Dictionary = {}) -> void:

	var coord := _scene_voxel_tile_coord_from_voxel(Vector3i(voxel_xz.x, slice_index, voxel_xz.y))

	_touch_scene_voxel_tile(coord, dirty_flags, source_record)

## 为场景体素 tile 标记对应遗留 SV tile 为脏

func _reset_scene_voxel_tile_summaries() -> void:

	for tile_id in _scene_voxel_tiles.keys():

		var tile: Dictionary = _scene_voxel_tiles[tile_id]

		tile["scene_minmax"] = Vector2.ZERO

		tile["collision_minmax"] = Vector2.ZERO

		tile["scene_voxel_count"] = 0

		tile["collision_cell_count"] = 0

		tile["summary"] = _scene_voxel_tile_summary(tile)

		_scene_voxel_tiles[tile_id] = tile

	_mark_scene_voxel_tile_staging_dirty("summary_reset")

## 累加更新 tile 的场景复杂度摘要（计数与最值）

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

	tile["summary"] = _scene_voxel_tile_summary(tile)

	_scene_voxel_tiles[tile_id] = tile

	_mark_scene_voxel_tile_staging_dirty("scene_summary_rebuild")

## 累加更新 tile 的碰撞强度摘要（计数与最值）

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

	tile["summary"] = _scene_voxel_tile_summary(tile)

	_scene_voxel_tiles[tile_id] = tile

	_mark_scene_voxel_tile_staging_dirty("collision_summary_rebuild")

## 清除所有 tile 的脏标记并更新提交 tick

func _clear_scene_voxel_tile_dirty_flags() -> void:

	for tile_id in _scene_voxel_tiles.keys():

		var tile: Dictionary = _scene_voxel_tiles[tile_id]

		tile["dirty_flags"] = {}

		tile["dirty"] = false

		tile["updated_this_commit"] = false

		tile["last_commit_tick"] = _committer._committed_tick

		tile["summary"] = _scene_voxel_tile_summary(tile)

		_scene_voxel_tiles[tile_id] = tile

	_mark_scene_voxel_tile_staging_dirty("dirty_clear")

## 返回当前所有脏 tile 的快照字典

func _dirty_scene_voxel_tile_snapshot() -> Dictionary:

	var result := {}

	for tile_id in _scene_voxel_tiles.keys():

		var tile: Dictionary = _scene_voxel_tiles[tile_id]

		if bool(tile.get("dirty", false)):

			result[tile_id] = tile.duplicate(true)

	return result

## 返回当前所有脏 SV 像素瓦片(_sv_dirty_tiles)的快照字典；由 committer 提交路径调用，对应 _sv["dirty_tiles"]
func _dirty_sv_pixel_tile_snapshot() -> Dictionary:

	return _sv_dirty_tiles.duplicate(true)

## 统一清除全部脏标记：SV 像素瓦片(_sv_dirty_tiles) + committer 脏矩形(_sv_dirty_rects) + SceneVoxelTile 脏标志(B)；由 committer 提交路径与 clear_sv_dirty 调用
func clear_all_dirty() -> void:

	_sv_dirty_tiles.clear()

	_committer._sv_dirty_rects.clear()

	_clear_scene_voxel_tile_dirty_flags()

## 标记指定 SV 像素瓦片为脏(写入 _sv_dirty_tiles)并可选联动场景体素瓦片(B)；由 committer._mark_sv_tile_dirty 桩与本地 _mark_legacy_sv_tiles_for_scene_voxel_tile 调用
func _mark_sv_tile_dirty(
	slice_index: int,
	voxel_xz: Vector2i,
	layer: String = "scene",
	tile_size: int = SV_RESIDENT_TILE_SIZE,
	source_record: Dictionary = {},
	update_scene_voxel_tile: bool = true
) -> void:

	if _committer._volume.is_empty():

		return

	var xz_res := int(_committer._volume.get("xz_res", _committer._base_res))

	if xz_res <= 0:

		return

	var px := Vector2i(

		clampi(voxel_xz.x, 0, xz_res - 1),

		clampi(voxel_xz.y, 0, xz_res - 1)

	)

	var key := SceneVoxelTileCodecScript.sv_tile_key(slice_index, px, layer, tile_size)

	_sv_dirty_tiles[key] = {

		"tile_id": key,  # dirty tile storage key

		"clip_level": 0,  # clipmap level; 0 in current SV

		"layer": layer,  # scene or collision

		"slice_index": slice_index,  # Y slice

		"tile_size": tile_size,  # voxel tile edge size

		"bounds": SceneVoxelTileCodecScript.sv_tile_bounds(px, tile_size),  # XZ bounds in volume pixels

		"write_tick": _committer._generation_tick,  # generation tick that dirtied the tile

		"commit_tick": _committer._committed_tick,  # committed SV snapshot epoch; not per-voxel provenance

		"dirty": true,  # needs resident buffer refresh

	}

	if update_scene_voxel_tile:

		_touch_scene_voxel_tile_from_voxel(slice_index, px, {layer: true}, source_record)

	_committer._sv_dirty = true

## 将 SceneVoxelTile 三维坐标反映射为旧式 SV 瓦片像素坐标并标记为脏(B→A 反向同步)；由 mark_scene_voxel_tile_dirty 调用
func _mark_legacy_sv_tiles_for_scene_voxel_tile(tile_coord: Vector3i, dirty_flags: Dictionary) -> void:

	if _committer._volume.is_empty():

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

## 判断场景体素是否落在任一脏 tile 的体素边界内

func _scene_voxel_in_dirty_scene_voxel_tiles(scene_voxel: Dictionary, dirty_scene_voxel_tiles: Dictionary) -> bool:

	if dirty_scene_voxel_tiles.is_empty():

		return false

	var voxel_xz = scene_voxel.get("voxel_xz", Vector2i(-1, -1))

	if not voxel_xz is Vector2i:

		return false

	var px: Vector2i = voxel_xz

	var slice_index := int(scene_voxel.get("slice_index", 0))

	for raw_tile in dirty_scene_voxel_tiles.values():

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

## 收集当前与上一帧中落在脏 tile 内的场景体素键

func ensure_scene_voxel_tile_buffers_uploaded(force: bool = false) -> bool:

	_scene_voxel_tile_last_upload_error = ""

	if not ensure_device(true, false):

		_scene_voxel_tile_gpu_ready = false

		_scene_voxel_tile_last_upload_error = "no_rendering_device"

		_scene_voxel_tile_gpu_stale_reason = "no_rendering_device"

		return false

	_rebuild_scene_voxel_tile_source_refs()

	if not force and is_scene_voxel_tile_gpu_ready():

		return true

	_scene_voxel_tile_gpu_last_reused_buffers.clear()

	var complexity_field := _scene_voxel_tile_complexity_field_for_upload()

	var collision_field := _scene_voxel_tile_collision_field_for_upload()

	var resident_voxel_count := _scene_voxel_tile_resident_voxel_count_for_upload(
		complexity_field,
		collision_field
	)

	var packed_complexity_field := _pack_scene_voxel_tile_complexity_field_bytes(
		complexity_field,
		resident_voxel_count
	)

	var packed_collision_field := _pack_scene_voxel_tile_collision_field_bytes(
		collision_field,
		resident_voxel_count
	)

	var tile_ids := _scene_voxel_tile_sorted_ids()

	var packed_records := _pack_scene_voxel_tile_record_bytes(tile_ids)

	var packed_summaries := _pack_scene_voxel_tile_summary_bytes(tile_ids)

	_refresh_scene_voxel_tile_dirty_tile_ids(tile_ids)

	var use_numeric_object_refs := not _scene_voxel_tile_gpu_autoobject_refs.is_empty()
	var packed_object_refs := _pack_scene_voxel_tile_numeric_object_ref_bytes(
		SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT
	) if use_numeric_object_refs else _pack_scene_voxel_tile_fixed_object_ref_hash_bytes(
		tile_ids,
		SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT
	)
	_scene_voxel_tile_object_ref_key_schema = SCENE_VOXEL_TILE_OBJECT_REF_SCHEMA_NUMERIC if use_numeric_object_refs else SCENE_VOXEL_TILE_OBJECT_REF_SCHEMA_LEGACY_HASH
	_scene_voxel_tile_object_ref_numeric_schema_confirmed = use_numeric_object_refs

	var packed_gpu_tile_ids := _scene_voxel_tile_gpu_tile_ids.duplicate()
	var packed_gpu_dirty_tile_ids := _scene_voxel_tile_gpu_dirty_tile_ids.duplicate()

	if not force and _update_scene_voxel_tile_dirty_ranges(
		tile_ids,
		packed_records,
		packed_summaries,
		packed_object_refs,
		complexity_field,
		collision_field,
		packed_complexity_field,
		packed_collision_field
	):

		return true

	var reusable_resident_field_buffers := _scene_voxel_tile_reusable_resident_field_buffers(
		packed_complexity_field,
		resident_voxel_count,
		packed_collision_field,
		resident_voxel_count
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
		SCENE_VOXEL_TILE_OBJECT_REF_BUFFER,
		packed_object_refs,
		int(packed_object_refs.size() / SCENE_VOXEL_TILE_REF_STRIDE_BYTES),
		SCENE_VOXEL_TILE_REF_STRIDE_BYTES
	) and ok

	if reusable_resident_field_buffers.has(SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER):
		ok = _reuse_scene_voxel_tile_storage_buffer(
			SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER,
			packed_complexity_field,
			resident_voxel_count,
			SCENE_VOXEL_TILE_COMPLEXITY_FIELD_STRIDE_BYTES
		) and ok
	else:
		ok = _create_scene_voxel_tile_storage_buffer(
			SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER,
			packed_complexity_field,
			resident_voxel_count,
			SCENE_VOXEL_TILE_COMPLEXITY_FIELD_STRIDE_BYTES
		) and ok

	if reusable_resident_field_buffers.has(SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER):
		ok = _reuse_scene_voxel_tile_storage_buffer(
			SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER,
			packed_collision_field,
			resident_voxel_count,
			SCENE_VOXEL_TILE_COLLISION_FIELD_STRIDE_BYTES
		) and ok
	else:
		ok = _create_scene_voxel_tile_storage_buffer(
			SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER,
			packed_collision_field,
			resident_voxel_count,
			SCENE_VOXEL_TILE_COLLISION_FIELD_STRIDE_BYTES
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

	_scene_voxel_tile_gpu_last_upload_tick = _committer._generation_tick

	_scene_voxel_tile_gpu_stale_reason = ""

	_scene_voxel_tile_last_upload_error = ""

	_scene_voxel_tile_pending_resident_upload_tiles.clear()

	_scene_voxel_tile_last_upload_mode = "full_storage_buffer_upload"

	_scene_voxel_tile_last_summary_dirty_range_update_source = "packed_summary_full_upload"

	_scene_voxel_tile_last_upload_tile_ids = tile_ids.duplicate()

	_scene_voxel_tile_last_upload_resident_voxel_count = resident_voxel_count

	_scene_voxel_tile_last_upload_range_count = 1 if resident_voxel_count > 0 else 0

	_scene_voxel_tile_gpu_last_reused_buffers.clear()
	for buf_name in reusable_resident_field_buffers:
		_scene_voxel_tile_gpu_last_reused_buffers.append(buf_name)

	return true

## 增量更新脏 tile 对应的存储缓冲区段并刷新摘要

func _update_scene_voxel_tile_dirty_ranges(
	tile_ids: Array[String],
	packed_records: PackedByteArray,
	_packed_summaries: PackedByteArray,
	packed_object_refs: PackedByteArray,
	complexity_field: PackedFloat32Array,
	collision_field: PackedFloat32Array,
	packed_complexity_field: PackedByteArray,
	packed_collision_field: PackedByteArray
) -> bool:

	var scoped_tile_ids := _scene_voxel_tile_dirty_upload_ids(tile_ids)

	if scoped_tile_ids.is_empty():

		return false

	# Resident fields are now GPU-native 8bit buffers. Collision stores four R8
	# voxels in each uint word, so dirty row writes need word-aligned read/modify
	# handling. Use the existing full upload path until that partial updater is
	# specialized for packed R8.
	return false

	if not _scene_voxel_tile_can_update_existing_buffers(tile_ids, complexity_field.size(), collision_field.size()):

		return false

	if not _scene_voxel_tile_can_prove_buffer_bytes_equal(
		SCENE_VOXEL_TILE_OBJECT_REF_BUFFER,
		packed_object_refs,
		int(packed_object_refs.size() / SCENE_VOXEL_TILE_REF_STRIDE_BYTES),
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

	var scene_update := _update_scene_voxel_tile_field_ranges(
		SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER,
		complexity_field.size(),
		packed_complexity_field,
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
		complexity_field.size(),
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

	_scene_voxel_tile_gpu_last_upload_tick = _committer._generation_tick

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

	_scene_voxel_tile_gpu_last_reused_buffers.clear()
	_scene_voxel_tile_gpu_last_reused_buffers.append(SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER)
	_scene_voxel_tile_gpu_last_reused_buffers.append(SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER)

	return true

## 从待上传 tile 列表中筛选出实际脏 tile 的 ID

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

## 校验现有 GPU 缓冲是否可复用于当前 tile 集合与字段容量

func _scene_voxel_tile_can_update_existing_buffers(tile_ids: Array[String], complexity_field_count: int, collision_field_count: int) -> bool:

	if _rd == null or _scene_voxel_tile_uploaded_revision < 0:

		return false

	if not _scene_voxel_tile_string_arrays_equal(_scene_voxel_tile_gpu_tile_ids, tile_ids):

		return false

	if int(_scene_voxel_tile_gpu_record_counts.get(SCENE_VOXEL_TILE_RECORD_BUFFER, -1)) != tile_ids.size():

		return false

	if int(_scene_voxel_tile_gpu_record_counts.get(SCENE_VOXEL_TILE_SUMMARY_BUFFER, -1)) != tile_ids.size():

		return false

	if int(_scene_voxel_tile_gpu_record_counts.get(SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER, -1)) != complexity_field_count:

		return false

	if int(_scene_voxel_tile_gpu_record_counts.get(SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER, -1)) != collision_field_count:

		return false

	for buffer_name in SCENE_VOXEL_TILE_GPU_BUFFER_NAMES:

		var rid: RID = _scene_voxel_tile_gpu_buffers.get(buffer_name, RID())

		if not rid.is_valid():

			return false

	return true

## 逐项比较两个字符串数组是否完全相等

func _scene_voxel_tile_string_arrays_equal(a: Array[String], b: Array[String]) -> bool:

	if a.size() != b.size():

		return false

	for i in range(a.size()):

		if str(a[i]) != str(b[i]):

			return false

	return true

## 按 tile 索引更新记录缓冲的对应字节区段

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

## 按 tile 体素边界逐行更新场缓冲的字节区段

func _update_scene_voxel_tile_field_ranges(
	buffer_name: String,
	value_count: int,
	field_bytes: PackedByteArray,
	scoped_tile_ids: Array[String]
) -> Dictionary:

	if _committer._volume.is_empty() or value_count <= 0 or field_bytes.is_empty():

		return {"ok": true, "voxel_count": 0, "range_count": 0}

	var xz_res := int(_committer._volume.get("xz_res", _committer.grid_size.x))
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

## 根据作用域瓦片ID列表构建瓦片索引字节数组

func _scene_voxel_tile_scoped_index_bytes(tile_ids: Array[String], scoped_tile_ids: Array[String]) -> PackedByteArray:

	var indices := PackedInt32Array()

	for tile_id in scoped_tile_ids:

		var tile_index := tile_ids.find(tile_id)

		if tile_index >= 0:

			indices.append(tile_index)

	return indices.to_byte_array()

## 通过Compute Shader更新瓦片摘要脏范围

func _update_scene_voxel_tile_summary_dirty_ranges_compute(
	tile_ids: Array[String],
	scoped_tile_ids: Array[String],
	complexity_field_count: int,
	collision_field_count: int
) -> Dictionary:

	if scoped_tile_ids.is_empty():

		return {"ok": false, "reason": "empty_summary_dirty_tile_scope"}

	if not _gpu_ready or _rd == null:

		return {"ok": false, "reason": "summary_range_compute_not_ready"}

	if not _shader_update_scene_voxel_tile_summary_ranges.is_valid() or not _pipeline_update_scene_voxel_tile_summary_ranges.is_valid():

		return {"ok": false, "reason": "summary_range_compute_pipeline_not_ready"}

	var complexity_buffer: RID = _scene_voxel_tile_gpu_buffers.get(SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER, RID())

	var collision_buffer: RID = _scene_voxel_tile_gpu_buffers.get(SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER, RID())

	var summary_buffer: RID = _scene_voxel_tile_gpu_buffers.get(SCENE_VOXEL_TILE_SUMMARY_BUFFER, RID())

	var record_buffer: RID = _scene_voxel_tile_gpu_buffers.get(SCENE_VOXEL_TILE_RECORD_BUFFER, RID())

	if not complexity_buffer.is_valid() or not collision_buffer.is_valid() or not summary_buffer.is_valid() or not record_buffer.is_valid():

		return {"ok": false, "reason": "summary_range_missing_resident_buffer"}

	var xz_res := int(_committer._volume.get("xz_res", _committer.grid_size.x)) if not _committer._volume.is_empty() else _committer.grid_size.x

	var total_slices := int(_committer._volume.get("total_slices", _committer.grid_size.y)) if not _committer._volume.is_empty() else _committer.grid_size.y

	var voxel_count := xz_res * xz_res * total_slices

	if xz_res <= 0 or total_slices <= 0 or voxel_count <= 0:

		return {"ok": false, "reason": "summary_range_invalid_volume_dims"}

	if complexity_field_count < voxel_count or collision_field_count < voxel_count:

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
		make_storage_uniform(0, complexity_buffer),
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

## 将GPU自动对象脏增量打包为字节序列

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
		UtilsBufferUtils.encode_vec3i4_with_w(bytes, base + 16, old_min, 1 if removed else 0)
		UtilsBufferUtils.encode_vec3i4_with_w(bytes, base + 32, old_max, 1 if alive_after else 0)
		UtilsBufferUtils.encode_vec3i4_with_w(bytes, base + 48, new_min, SceneVoxelTileCodecScript.flags_to_bits(dirty_flags))
		UtilsBufferUtils.encode_vec3i4_with_w(bytes, base + 64, new_max, int(delta.get("flush_epoch", 0)))
	return bytes

## 打包对象引用更新Compute Shader的push constant字节

func _pack_scene_voxel_tile_object_ref_update_push(
	dirty_delta_count: int,
	dirty_delta_capacity: int,
	object_ref_capacity: int,
	stats_capacity: int,
	dirty_tile_flag_capacity: int = 0,
	dirty_tile_worklist_capacity: int = 0,
	dirty_flag_schema: int = SCENE_VOXEL_TILE_OBJECT_REF_DIRTY_FLAG_SCHEMA_SCENE_VOXEL_TILE
) -> PackedByteArray:
	var tile_size := _scene_voxel_tile_size()
	var tile_grid := _scene_voxel_tile_grid_size(tile_size)
	var push := PackedByteArray()
	push.resize(80)
	push.encode_s32(0, _committer.grid_size.x)
	push.encode_s32(4, _committer.grid_size.y)
	push.encode_s32(8, _committer.grid_size.z)
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
	push.encode_s32(68, dirty_tile_flag_capacity)
	push.encode_s32(72, dirty_tile_worklist_capacity)
	push.encode_s32(76, dirty_flag_schema)
	return push

## 构造空的对象引用更新统计结果

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
		"transient_dirty_scene_voxel_tile_gpu_emitted": false,
		"transient_dirty_scene_voxel_tile_count": 0,
		"transient_dirty_scene_voxel_tile_worklist_count": 0,
		"transient_dirty_scene_voxel_tile_flagged_count": 0,
		"transient_dirty_scene_voxel_tile_ids": [],
		"transient_dirty_scene_voxel_tile_indices": [],
		"transient_dirty_scene_voxel_tile_flags": {},
		"transient_dirty_scene_voxel_tile_flag_bits": {},
		"transient_dirty_scene_voxel_tile_flag_schema": "none",
		"transient_dirty_scene_voxel_tile_source": "none",
		"transient_dirty_scene_voxel_tile_flag_capacity": 0,
		"transient_dirty_scene_voxel_tile_worklist_capacity": 0,
		"transient_dirty_scene_voxel_tile_worklist_overflow_count": 0,
		"transient_dirty_scene_voxel_tile_cpu_metadata_bridge": "none",
	}

## 安全读取统计字数组的指定索引值

func _scene_voxel_tile_object_ref_update_stat(words: PackedInt32Array, index: int) -> int:
	if index < 0 or index >= words.size():
		return 0
	return maxi(int(words[index]), 0)

## 根据脏增量来源返回对应的脏标记schema枚举

func _scene_voxel_tile_object_ref_dirty_flag_schema(dirty_delta_source: String) -> int:
	if dirty_delta_source.contains("gpu_autoobject_runtime"):
		return SCENE_VOXEL_TILE_OBJECT_REF_DIRTY_FLAG_SCHEMA_GPU_AUTOOBJECT_RUNTIME
	return SCENE_VOXEL_TILE_OBJECT_REF_DIRTY_FLAG_SCHEMA_SCENE_VOXEL_TILE

## 将脏标记schema枚举转为可读名称

func _scene_voxel_tile_object_ref_dirty_flag_schema_name(schema: int) -> String:
	if schema == SCENE_VOXEL_TILE_OBJECT_REF_DIRTY_FLAG_SCHEMA_GPU_AUTOOBJECT_RUNTIME:
		return "gpu_autoobject_runtime_dirty_flags"
	return "scene_voxel_tile_dirty_flags"

## 由扁平瓦片索引还原三维瓦片坐标

func _scene_voxel_tile_coord_from_object_ref_tile_index(tile_index: int, tile_grid: Vector3i) -> Vector3i:
	var safe_x := maxi(tile_grid.x, 1)
	var safe_z := maxi(tile_grid.z, 1)
	var x := tile_index % safe_x
	var zy := int(tile_index / safe_x)
	var z := zy % safe_z
	var y := int(zy / safe_z)
	return Vector3i(x, y, z)

## 解码瞬态脏瓦片的标记位与工作清单

func _decode_scene_voxel_tile_object_ref_transient_dirty_tiles(
	dirty_flag_bytes: PackedByteArray,
	dirty_worklist_bytes: PackedByteArray,
	tile_grid: Vector3i,
	worklist_count: int
) -> Dictionary:
	var tile_count := _scene_voxel_tile_total_tile_count(tile_grid)
	var available_flag_count := mini(tile_count, int(dirty_flag_bytes.size() / SCENE_VOXEL_TILE_REF_STRIDE_BYTES))
	var flagged_tile_count := 0
	for tile_index in range(available_flag_count):
		if int(dirty_flag_bytes.decode_u32(tile_index * SCENE_VOXEL_TILE_REF_STRIDE_BYTES)) != 0:
			flagged_tile_count += 1

	var available_worklist_count := mini(
		maxi(worklist_count, 0),
		int(dirty_worklist_bytes.size() / SCENE_VOXEL_TILE_INDEX_STRIDE_BYTES)
	)
	var tile_ids: Array[String] = []
	var tile_indices: Array[int] = []
	var flags_by_tile_id := {}
	var flag_bits_by_tile_id := {}

	for slot in range(available_worklist_count):
		var tile_index := int(dirty_worklist_bytes.decode_u32(slot * SCENE_VOXEL_TILE_INDEX_STRIDE_BYTES))
		if tile_index < 0 or tile_index >= tile_count:
			continue
		var flag_offset := tile_index * SCENE_VOXEL_TILE_REF_STRIDE_BYTES
		var flag_bits := 0
		if flag_offset + SCENE_VOXEL_TILE_REF_STRIDE_BYTES <= dirty_flag_bytes.size():
			flag_bits = int(dirty_flag_bytes.decode_u32(flag_offset))
		if flag_bits == 0:
			continue
		var tile_coord := _scene_voxel_tile_coord_from_object_ref_tile_index(tile_index, tile_grid)
		var tile_id := SceneVoxelTileCodecScript.tile_id(tile_coord)
		tile_ids.append(tile_id)
		tile_indices.append(tile_index)
		flag_bits_by_tile_id[tile_id] = flag_bits
		flags_by_tile_id[tile_id] = SceneVoxelTileCodecScript.flags_from_bits(flag_bits)

	return {
		"flagged_tile_count": flagged_tile_count,
		"worklist_read_count": available_worklist_count,
		"tile_ids": tile_ids,
		"tile_indices": tile_indices,
		"flag_bits_by_tile_id": flag_bits_by_tile_id,
		"flags_by_tile_id": flags_by_tile_id,
	}

## 将瞬态脏瓦片结果合并到返回字典

func _merge_scene_voxel_tile_object_ref_transient_dirty_result(result: Dictionary, update_stats: Dictionary) -> void:
	result["transient_dirty_scene_voxel_tile_gpu_emitted"] = bool(update_stats.get("transient_dirty_scene_voxel_tile_gpu_emitted", false))
	result["transient_dirty_scene_voxel_tile_count"] = int(update_stats.get("transient_dirty_scene_voxel_tile_count", 0))
	result["transient_dirty_scene_voxel_tile_worklist_count"] = int(update_stats.get("transient_dirty_scene_voxel_tile_worklist_count", 0))
	result["transient_dirty_scene_voxel_tile_flagged_count"] = int(update_stats.get("transient_dirty_scene_voxel_tile_flagged_count", 0))
	result["transient_dirty_scene_voxel_tile_ids"] = update_stats.get("transient_dirty_scene_voxel_tile_ids", [])
	result["transient_dirty_scene_voxel_tile_indices"] = update_stats.get("transient_dirty_scene_voxel_tile_indices", [])
	result["transient_dirty_scene_voxel_tile_flags"] = update_stats.get("transient_dirty_scene_voxel_tile_flags", {})
	result["transient_dirty_scene_voxel_tile_flag_bits"] = update_stats.get("transient_dirty_scene_voxel_tile_flag_bits", {})
	result["transient_dirty_scene_voxel_tile_flag_schema"] = str(update_stats.get("transient_dirty_scene_voxel_tile_flag_schema", "none"))
	result["transient_dirty_scene_voxel_tile_source"] = str(update_stats.get("transient_dirty_scene_voxel_tile_source", "none"))
	result["transient_dirty_scene_voxel_tile_flag_capacity"] = int(update_stats.get("transient_dirty_scene_voxel_tile_flag_capacity", 0))
	result["transient_dirty_scene_voxel_tile_worklist_capacity"] = int(update_stats.get("transient_dirty_scene_voxel_tile_worklist_capacity", 0))
	result["transient_dirty_scene_voxel_tile_worklist_overflow_count"] = int(update_stats.get("transient_dirty_scene_voxel_tile_worklist_overflow_count", 0))
	result["transient_dirty_scene_voxel_tile_cpu_metadata_bridge"] = str(update_stats.get("transient_dirty_scene_voxel_tile_cpu_metadata_bridge", "none"))

## 基于借用脏增量缓冲执行GPU对象引用更新

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
	var tile_count := _scene_voxel_tile_total_tile_count(tile_grid)
	var object_ref_capacity := tile_count * SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT
	var expected_byte_count := object_ref_capacity * SCENE_VOXEL_TILE_REF_STRIDE_BYTES
	if int(_scene_voxel_tile_gpu_buffer_byte_sizes.get(SCENE_VOXEL_TILE_OBJECT_REF_BUFFER, 0)) < expected_byte_count:
		_scene_voxel_tile_object_ref_last_update_stats = _empty_scene_voxel_tile_object_ref_update_stats("object_ref_buffer_capacity_mismatch")
		return _scene_voxel_tile_object_ref_last_update_stats.duplicate(true)

	var dirty_tile_flag_capacity := tile_count
	var dirty_tile_worklist_capacity := tile_count
	var stats_buffer := storage_buffer_zero(
		SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_STATS_CAPACITY * SCENE_VOXEL_TILE_REF_STRIDE_BYTES,
		SCOPE_FRAME,
		"scene_voxel_tile_object_ref_update_stats"
	)
	var dirty_tile_flag_buffer := storage_buffer_zero(
		dirty_tile_flag_capacity * SCENE_VOXEL_TILE_REF_STRIDE_BYTES,
		SCOPE_FRAME,
		"scene_voxel_tile_object_ref_update_dirty_flags"
	)
	var dirty_tile_worklist_buffer := storage_buffer_zero(
		dirty_tile_worklist_capacity * SCENE_VOXEL_TILE_INDEX_STRIDE_BYTES,
		SCOPE_FRAME,
		"scene_voxel_tile_object_ref_update_dirty_worklist"
	)
	if not stats_buffer.is_valid() or not dirty_tile_flag_buffer.is_valid() or not dirty_tile_worklist_buffer.is_valid():
		gc_frame()
		_scene_voxel_tile_object_ref_last_update_stats = _empty_scene_voxel_tile_object_ref_update_stats("object_ref_update_buffer_create_failed")
		return _scene_voxel_tile_object_ref_last_update_stats.duplicate(true)

	var set0 := create_uniform_set([
		make_storage_uniform(0, dirty_delta_buffer),
		make_storage_uniform(1, object_ref_buffer),
		make_storage_uniform(2, stats_buffer),
		make_storage_uniform(3, dirty_tile_flag_buffer),
		make_storage_uniform(4, dirty_tile_worklist_buffer),
	], _shader_scene_voxel_tile_object_ref_update, 0, SCOPE_PASS, "scene_voxel_tile_object_ref_update")
	if not set0.is_valid():
		gc_frame()
		_scene_voxel_tile_object_ref_last_update_stats = _empty_scene_voxel_tile_object_ref_update_stats("object_ref_update_uniform_set_create_failed")
		return _scene_voxel_tile_object_ref_last_update_stats.duplicate(true)

	var push := _pack_scene_voxel_tile_object_ref_update_push(
		dirty_delta_count,
		maxi(dirty_delta_capacity, dirty_delta_count),
		object_ref_capacity,
		SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_STATS_CAPACITY,
		dirty_tile_flag_capacity,
		dirty_tile_worklist_capacity,
		_scene_voxel_tile_object_ref_dirty_flag_schema(dirty_delta_source)
	)
	var dispatch_groups := Vector3i(1, 1, 1)
	if not _gpu_dispatch_and_sync(_pipeline_scene_voxel_tile_object_ref_update, [set0], push, dispatch_groups):
		gc_frame()
		_scene_voxel_tile_object_ref_last_update_stats = _empty_scene_voxel_tile_object_ref_update_stats("object_ref_update_dispatch_failed")
		return _scene_voxel_tile_object_ref_last_update_stats.duplicate(true)

	# DEBUG READBACK: stats, dirty worklist, and dirty flags read from GPU for diagnostics.
	# Primary GPU state is exposed via resident_dirty_tile_worklist_buffer_rid / resident_dirty_tile_flag_buffer_rid.
	var stats_bytes := _rd.buffer_get_data(
		stats_buffer,
		0,
		SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_STATS_CAPACITY * SCENE_VOXEL_TILE_REF_STRIDE_BYTES
	)
	var stats_words := stats_bytes.to_int32_array()
	var transient_dirty_tile_count := _scene_voxel_tile_object_ref_update_stat(stats_words, 8)
	var dirty_worklist_read_count := mini(transient_dirty_tile_count, dirty_tile_worklist_capacity)
	# DEBUG READBACK only — dirty worklist and flags decoded for diagnostic metadata.
	# Downstream GPU consumers should use resident_dirty_tile_worklist_buffer_rid RIDs.
	var dirty_worklist_bytes := _rd.buffer_get_data(
		dirty_tile_worklist_buffer,
		0,
		dirty_worklist_read_count * SCENE_VOXEL_TILE_INDEX_STRIDE_BYTES
	)
	# DEBUG READBACK only — dirty flag bits decoded for diagnostic metadata.
	var dirty_flag_bytes := _rd.buffer_get_data(
		dirty_tile_flag_buffer,
		0,
		dirty_tile_flag_capacity * SCENE_VOXEL_TILE_REF_STRIDE_BYTES
	)
	var transient_dirty := _decode_scene_voxel_tile_object_ref_transient_dirty_tiles(
		dirty_flag_bytes,
		dirty_worklist_bytes,
		tile_grid,
		dirty_worklist_read_count
	)
	var dirty_flag_schema := _scene_voxel_tile_object_ref_dirty_flag_schema(dirty_delta_source)
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
		"object_ref_tile_count": tile_count,
		"object_ref_tile_grid_size": tile_grid,
		"overflow": _scene_voxel_tile_object_ref_update_stat(stats_words, 0),
		"non_numeric": _scene_voxel_tile_object_ref_update_stat(stats_words, 1),
		"duplicate": _scene_voxel_tile_object_ref_update_stat(stats_words, 2),
		"touched": _scene_voxel_tile_object_ref_update_stat(stats_words, 3),
		"removed_slots": _scene_voxel_tile_object_ref_update_stat(stats_words, 4),
		"inserted_slots": _scene_voxel_tile_object_ref_update_stat(stats_words, 5),
		"invalid_bounds": _scene_voxel_tile_object_ref_update_stat(stats_words, 6),
		"skipped": _scene_voxel_tile_object_ref_update_stat(stats_words, 7),
		"transient_dirty_scene_voxel_tile_gpu_emitted": true,
		"transient_dirty_scene_voxel_tile_count": transient_dirty_tile_count,
		"transient_dirty_scene_voxel_tile_worklist_count": dirty_worklist_read_count,
		"transient_dirty_scene_voxel_tile_flagged_count": int(transient_dirty.get("flagged_tile_count", 0)),
		"transient_dirty_scene_voxel_tile_ids": transient_dirty.get("tile_ids", []),
		"transient_dirty_scene_voxel_tile_indices": transient_dirty.get("tile_indices", []),
		"transient_dirty_scene_voxel_tile_flags": transient_dirty.get("flags_by_tile_id", {}),
		"transient_dirty_scene_voxel_tile_flag_bits": transient_dirty.get("flag_bits_by_tile_id", {}),
		"transient_dirty_scene_voxel_tile_flag_schema": _scene_voxel_tile_object_ref_dirty_flag_schema_name(dirty_flag_schema),
		"transient_dirty_scene_voxel_tile_source": SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_NAME,
		"transient_dirty_scene_voxel_tile_flag_capacity": dirty_tile_flag_capacity,
		"transient_dirty_scene_voxel_tile_worklist_capacity": dirty_tile_worklist_capacity,
		"transient_dirty_scene_voxel_tile_worklist_overflow_count": _scene_voxel_tile_object_ref_update_stat(stats_words, 9),
		"transient_dirty_scene_voxel_tile_cpu_metadata_bridge": "none",
		## Expose GPU-resident dirty tile worklist and flag buffers as RIDs for downstream
		## GPU consumers (prefilter, summary reduce, VPG route scope).
		## CPU readback above (lines 3866-3881) is retained for debug/diagnostics only.
		"resident_dirty_tile_worklist_buffer_rid": str(dirty_tile_worklist_buffer),
		"resident_dirty_tile_flag_buffer_rid": str(dirty_tile_flag_buffer),
		"resident_dirty_tile_worklist_capacity": dirty_tile_worklist_capacity,
		"resident_dirty_tile_flag_capacity": dirty_tile_flag_capacity,
		"cpu_readback_debug_only": true,
	}
	_scene_voxel_tile_gpu_buffer_hashes[SCENE_VOXEL_TILE_OBJECT_REF_BUFFER] = 0
	_scene_voxel_tile_object_ref_key_schema = SCENE_VOXEL_TILE_OBJECT_REF_SCHEMA_NUMERIC
	_scene_voxel_tile_object_ref_numeric_schema_confirmed = true
	_scene_voxel_tile_object_ref_last_update_stats = stats
	gc_frame()
	return stats.duplicate(true)

## 由脏增量数组打包并派发GPU对象引用更新

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

## 更新指定瓦片GPU缓冲的字节区间

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

## 判断场景体素瓦片GPU缓冲是否就绪

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

## 获取指定名称的瓦片GPU缓冲RID

func get_scene_voxel_tile_gpu_buffer(buffer_name: String) -> RID:

	return _scene_voxel_tile_gpu_buffers.get(buffer_name, RID())


## Returns the resident SceneVoxelTile summary storage buffer RID
## for direct GPU-first prefilter consumption without CPU readback.

func get_scene_voxel_tile_summary_gpu_buffer() -> RID:
	return _scene_voxel_tile_gpu_buffers.get(SCENE_VOXEL_TILE_SUMMARY_BUFFER, RID())

## 返回场景体素瓦片GPU缓冲汇总信息

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
		if buffer_name == SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER:
			buffers[buffer_name]["format"] = SCENE_VOXEL_TILE_COMPLEXITY_FIELD_FORMAT
			buffers[buffer_name]["logical_byte_size"] = int(_scene_voxel_tile_gpu_record_counts.get(buffer_name, 0)) * SCENE_VOXEL_TILE_COMPLEXITY_FIELD_STRIDE_BYTES
			buffers[buffer_name]["upload_stride_bytes"] = SCENE_VOXEL_TILE_COMPLEXITY_FIELD_STRIDE_BYTES
		elif buffer_name == SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER:
			buffers[buffer_name]["format"] = SCENE_VOXEL_TILE_COLLISION_FIELD_FORMAT
			buffers[buffer_name]["logical_byte_size"] = int(_scene_voxel_tile_gpu_record_counts.get(buffer_name, 0)) * SCENE_VOXEL_TILE_COLLISION_FIELD_STRIDE_BYTES
			buffers[buffer_name]["upload_stride_bytes"] = SCENE_VOXEL_TILE_COLLISION_FIELD_UPLOAD_STRIDE_BYTES

	var complexity_field_buffer: Dictionary = buffers.get(SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER, {})

	var collision_field_buffer: Dictionary = buffers.get(SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER, {})

	var resident_field_ready := (
		runtime_ready and
		bool(complexity_field_buffer.get("rid_valid", false)) and
		bool(collision_field_buffer.get("rid_valid", false))
	)
	var object_ref_last_stats := _scene_voxel_tile_object_ref_last_update_stats.duplicate(true)

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
		"complexity_field_read_source": "gpu_storage_buffers" if resident_field_ready else "none",
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
		"object_ref_tile_size": _scene_voxel_tile_size(),
		"object_ref_tile_grid_size": _scene_voxel_tile_grid_size(),
		"refs_per_tile": SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT,
		"object_ref_stride_bytes": SCENE_VOXEL_TILE_REF_STRIDE_BYTES,
		"object_ref_key_schema": _scene_voxel_tile_object_ref_key_schema,
		"object_ref_numeric_schema_confirmed": _scene_voxel_tile_object_ref_numeric_schema_confirmed,
		"gpu_autoobject_ref_key_schema": _scene_voxel_tile_object_ref_key_schema,
		"gpu_autoobject_ref_key_schema_numeric_confirmed": _scene_voxel_tile_object_ref_numeric_schema_confirmed,
		"gpu_autoobject_ref_key_schema_note": "Use u32 ref_key entries; 0 is empty, numeric GPU AutoObject object_id + 1 is the pending runtime key, and legacy CPU string hashes remain debug-only.",
		"object_ref_rebuild_required": _scene_voxel_tile_object_ref_rebuild_required,
		"object_ref_overflow_count": _scene_voxel_tile_object_ref_overflow_count,
		"overflow_tile_count": _scene_voxel_tile_object_ref_overflow_tile_ids.size(),
		"object_ref_overflow_tile_ids": _scene_voxel_tile_object_ref_overflow_tile_ids.duplicate(),
		"object_ref_update_stats_available": bool(object_ref_last_stats.get("stats_available", false)),
		"object_ref_update_source": str(object_ref_last_stats.get("source", "none")),
		"object_ref_update_reason": str(object_ref_last_stats.get("reason", "not_dispatched")),
		"object_ref_update_gpu_dispatched": bool(object_ref_last_stats.get("gpu_dispatched", false)),
		"object_ref_non_numeric_count": int(object_ref_last_stats.get("non_numeric", 0)),
		"object_ref_duplicate_count": int(object_ref_last_stats.get("duplicate", 0)),
		"object_ref_touched_count": int(object_ref_last_stats.get("touched", 0)),
		"object_ref_removed_slot_count": int(object_ref_last_stats.get("removed_slots", 0)),
		"object_ref_inserted_slot_count": int(object_ref_last_stats.get("inserted_slots", 0)),
		"object_ref_invalid_bounds_count": int(object_ref_last_stats.get("invalid_bounds", 0)),
		"object_ref_skipped_count": int(object_ref_last_stats.get("skipped", 0)),
		"resident_field_voxel_count": int(complexity_field_buffer.get("record_count", 0)),
		"complexity_field_voxel_count": int(complexity_field_buffer.get("record_count", 0)),
		"collision_field_voxel_count": int(collision_field_buffer.get("record_count", 0)),
		"complexity_field_format": SCENE_VOXEL_TILE_COMPLEXITY_FIELD_FORMAT,
		"collision_field_format": SCENE_VOXEL_TILE_COLLISION_FIELD_FORMAT,
		"complexity_field_stride_bytes": SCENE_VOXEL_TILE_COMPLEXITY_FIELD_STRIDE_BYTES,
		"collision_field_stride_bytes": SCENE_VOXEL_TILE_COLLISION_FIELD_STRIDE_BYTES,
		"collision_field_upload_stride_bytes": SCENE_VOXEL_TILE_COLLISION_FIELD_UPLOAD_STRIDE_BYTES,
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
			_scene_voxel_tile_gpu_last_reused_buffers.has(SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER) and
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

## 回读瓦片GPU缓冲的调试快照

func readback_scene_voxel_tile_debug_snapshot() -> Dictionary:

	return SceneVoxelDebugScript.readback_tile_snapshot(_committer)

## 将GPU摘要发布到场景体素字典

func set_scene_voxel_tile_gpu_auto_upload(enabled: bool, upload_now: bool = false) -> bool:

	_scene_voxel_tile_gpu_auto_upload = enabled

	if enabled and upload_now:

		return ensure_scene_voxel_tile_buffers_uploaded(false)

	return true

## 查询GPU自动上传是否启用

func is_scene_voxel_tile_gpu_auto_upload_enabled() -> bool:

	return _scene_voxel_tile_gpu_auto_upload

## 标记staging数据已变更需要重新上传

func _mark_scene_voxel_tile_staging_dirty(reason: String = "staging_changed") -> void:

	_scene_voxel_tile_staging_revision += 1

	if _scene_voxel_tile_uploaded_revision >= 0:

		_scene_voxel_tile_gpu_ready = false

		_scene_voxel_tile_gpu_stale_reason = reason

	elif _scene_voxel_tile_gpu_stale_reason.is_empty():

		_scene_voxel_tile_gpu_stale_reason = "never_uploaded"

## 在启用自动上传时尝试上传瓦片缓冲

func _maybe_auto_upload_scene_voxel_tile_buffers(reason: String = "auto_upload") -> void:

	if not _scene_voxel_tile_gpu_auto_upload:

		return

	if ensure_scene_voxel_tile_buffers_uploaded(false):

		return

	if _scene_voxel_tile_last_upload_error.is_empty():

		_scene_voxel_tile_last_upload_error = "%s_failed" % reason

## 释放瓦片GPU缓冲并可保留指定缓冲

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

	if not preserve.has(SCENE_VOXEL_TILE_OBJECT_REF_BUFFER):
		_scene_voxel_tile_object_ref_key_schema = SCENE_VOXEL_TILE_OBJECT_REF_SCHEMA_LEGACY_HASH
		_scene_voxel_tile_object_ref_numeric_schema_confirmed = false

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

## 创建瓦片存储缓冲并登记元数据

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

## 复用已有瓦片存储缓冲并刷新元数据

func _reuse_scene_voxel_tile_storage_buffer(buffer_name: String, bytes: PackedByteArray, record_count: int, stride_bytes: int) -> bool:

	if not _scene_voxel_tile_can_reuse_storage_buffer(buffer_name, bytes, record_count, stride_bytes):

		_scene_voxel_tile_last_upload_error = "storage_buffer_reuse_failed:%s" % buffer_name

		return false

	_scene_voxel_tile_gpu_buffer_byte_sizes[buffer_name] = bytes.size()

	_scene_voxel_tile_gpu_record_counts[buffer_name] = record_count

	_scene_voxel_tile_gpu_strides[buffer_name] = stride_bytes

	_scene_voxel_tile_gpu_buffer_hashes[buffer_name] = _scene_voxel_tile_bytes_hash(bytes)

	_scene_voxel_tile_gpu_buffer_reuse_counts[buffer_name] = int(_scene_voxel_tile_gpu_buffer_reuse_counts.get(buffer_name, 0)) + 1

	return true

## 返回可复用的常驻字段缓冲名称列表

func _scene_voxel_tile_reusable_resident_field_buffers(
	packed_complexity_field: PackedByteArray,
	complexity_field_count: int,
	packed_collision_field: PackedByteArray,
	collision_field_count: int
) -> Array[String]:

	var reusable: Array[String] = []

	if _scene_voxel_tile_can_reuse_storage_buffer(
		SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER,
		packed_complexity_field,
		complexity_field_count,
		SCENE_VOXEL_TILE_COMPLEXITY_FIELD_STRIDE_BYTES
	):

		reusable.append(SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER)

	if _scene_voxel_tile_can_reuse_storage_buffer(
		SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER,
		packed_collision_field,
		collision_field_count,
		SCENE_VOXEL_TILE_COLLISION_FIELD_STRIDE_BYTES
	):

		reusable.append(SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER)

	return reusable

## 判断存储缓冲是否可按内容哈希复用

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

## 通过哈希证明缓冲字节完全相等

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

## 计算字节序列的FNV哈希

func _scene_voxel_tile_bytes_hash(bytes: PackedByteArray) -> int:

	var h := 2166136261

	for value in bytes:

		h = (h ^ int(value)) & 0xffffffff

		h = (h * 16777619) & 0xffffffff

	return h

## 回读指定瓦片GPU缓冲的字节

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

## 准备上传用的复杂度字段数组

func _scene_voxel_tile_complexity_field_for_upload() -> PackedFloat32Array:

	if not _committer._sv.is_empty():

		var sv_field := _scene_voxel_tile_packed_float_field(_committer._sv.get("complexity_field", PackedFloat32Array()))

		if sv_field.size() > 0:

			return _expand_complexity_field_to_vec4(sv_field)

	if _committer._volume.is_empty():

		return PackedFloat32Array()

	var xz_res := int(_committer._volume.get("xz_res", _committer._base_res))

	var total_slices := int(_committer._volume.get("total_slices", _committer.grid_size.y))

	return _committer._try_make_sv_complexity_field_from_source_streams_gpu(xz_res, total_slices)

## 将单通道复杂度字段扩展为vec4交错格式

func _expand_complexity_field_to_vec4(field: PackedFloat32Array) -> PackedFloat32Array:
	return VoxelGeneralScript.expand_scalar_field_to_vec4(field)

## 准备上传用的碰撞字段数组

func _scene_voxel_tile_collision_field_for_upload() -> PackedFloat32Array:

	if not _committer._sv.is_empty():

		var sv_field := _scene_voxel_tile_packed_float_field(_committer._sv.get("collision_field", PackedFloat32Array()))

		if sv_field.size() > 0:

			return sv_field

	if _committer._volume.is_empty():

		return PackedFloat32Array()

	var xz_res := int(_committer._volume.get("xz_res", _committer._base_res))

	var total_slices := int(_committer._volume.get("total_slices", _committer.grid_size.y))

	var collision: Dictionary = _committer._volume.get("collision", {})

	return _committer._make_sv_collision_field(collision, xz_res, total_slices)

func _scene_voxel_tile_resident_voxel_count_for_upload(
	complexity_field: PackedFloat32Array,
	collision_field: PackedFloat32Array
) -> int:
	if not _committer._volume.is_empty():
		var xz_res := int(_committer._volume.get("xz_res", _committer._base_res))
		var total_slices := int(_committer._volume.get("total_slices", _committer.grid_size.y))
		var volume_count := maxi(xz_res, 0) * maxi(xz_res, 0) * maxi(total_slices, 0)
		if volume_count > 0:
			return volume_count
	return maxi(
		SceneVoxelTileCodecScript.infer_complexity_voxel_count(complexity_field),
		SceneVoxelTileCodecScript.infer_scalar_voxel_count(collision_field)
	)

## 将任意值转为打包浮点字段

func _scene_voxel_tile_packed_float_field(value) -> PackedFloat32Array:
	return SceneVoxelTileCodecScript.packed_float_field(value)

## 将浮点字段打包为字节

func _pack_scene_voxel_tile_complexity_field_bytes(values: PackedFloat32Array, voxel_count: int = -1) -> PackedByteArray:
	return SceneVoxelTileCodecScript.pack_complexity_field_rgba8_bytes(values, voxel_count)

func _pack_scene_voxel_tile_collision_field_bytes(values: PackedFloat32Array, voxel_count: int = -1) -> PackedByteArray:
	return SceneVoxelTileCodecScript.pack_collision_field_r8_word_bytes(values, voxel_count)

func _pack_scene_voxel_tile_float_field_bytes(values: PackedFloat32Array) -> PackedByteArray:
	return SceneVoxelTileCodecScript.pack_float_field_bytes(values)

## 将字节解码为浮点字段

func _decode_scene_voxel_tile_float_field_bytes(bytes: PackedByteArray) -> PackedFloat32Array:
	return SceneVoxelTileCodecScript.decode_float_field_bytes(bytes)

func _decode_scene_voxel_tile_complexity_field_bytes(bytes: PackedByteArray, voxel_count: int) -> PackedFloat32Array:
	return SceneVoxelTileCodecScript.decode_complexity_field_rgba8_vec4_bytes(bytes, voxel_count)

func _decode_scene_voxel_tile_collision_field_bytes(bytes: PackedByteArray, voxel_count: int) -> PackedFloat32Array:
	return SceneVoxelTileCodecScript.decode_collision_field_r8_word_bytes(bytes, voxel_count)

## 返回排序后的瓦片ID列表

func _scene_voxel_tile_sorted_ids() -> Array[String]:
	return SceneVoxelTileCodecScript.sorted_tile_ids(_scene_voxel_tiles)

## 打包瓦片记录为字节并缓存ID

func _pack_scene_voxel_tile_record_bytes(tile_ids: Array[String]) -> PackedByteArray:

	_scene_voxel_tile_gpu_tile_ids = tile_ids.duplicate()
	return SceneVoxelTileCodecScript.pack_record_bytes(tile_ids, _scene_voxel_tiles, _scene_voxel_tile_size())

## 打包瓦片摘要为字节

func _pack_scene_voxel_tile_summary_bytes(tile_ids: Array[String]) -> PackedByteArray:
	return SceneVoxelTileCodecScript.pack_summary_bytes(tile_ids, _scene_voxel_tiles)

## 刷新脏瓦片ID列表(由 codec 依据各 tile 的 dirty 标志计算)

func _refresh_scene_voxel_tile_dirty_tile_ids(tile_ids: Array[String]) -> void:
	_scene_voxel_tile_gpu_dirty_tile_ids = SceneVoxelTileCodecScript.dirty_tile_ids(tile_ids, _scene_voxel_tiles)

## 按稳定哈希打包固定槽位对象引用字节

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

## 计算瓦片网格的总瓦片数

func _scene_voxel_tile_total_tile_count(tile_grid: Vector3i = Vector3i.ZERO) -> int:
	var grid := tile_grid if tile_grid.x > 0 and tile_grid.y > 0 and tile_grid.z > 0 else _scene_voxel_tile_grid_size()
	return SceneVoxelTileCodecScript.tile_count(grid)

## 由三维瓦片坐标计算扁平索引

func _scene_voxel_tile_flattened_tile_index(tile_coord: Vector3i, tile_grid: Vector3i = Vector3i.ZERO) -> int:
	var grid := tile_grid if tile_grid.x > 0 and tile_grid.y > 0 and tile_grid.z > 0 else _scene_voxel_tile_grid_size()
	return SceneVoxelTileCodecScript.tile_index_unclamped(tile_coord, grid)

## 从任意值解析出数值对象ID

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

## 从记录字典中提取数值对象ID

func _scene_voxel_tile_numeric_object_id(record: Dictionary) -> int:
	for key in ["object_id", "auto_object_id", "auto_id", "id", "record_id"]:
		if record.has(key):
			var numeric_id := _scene_voxel_tile_numeric_object_id_from_value(record.get(key))
			if numeric_id >= 0:
				return numeric_id
	return -1

## 按数值键打包对象引用字节并统计溢出

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
			_scene_voxel_tile_object_ref_rebuild_required = true
			_scene_voxel_tile_object_ref_overflow_count += 1
			var tile_id := SceneVoxelTileCodecScript.tile_id(tile_coord)
			if not _scene_voxel_tile_object_ref_overflow_tile_ids.has(tile_id):
				_scene_voxel_tile_object_ref_overflow_tile_ids.append(tile_id)
		)

	return bytes

## 解码瓦片记录字节为字典数组

func _decode_scene_voxel_tile_records(bytes: PackedByteArray, tile_ids: Array[String]) -> Array[Dictionary]:
	return SceneVoxelTileCodecScript.decode_records(bytes, tile_ids)

## 解码摘要字节为字典数组

func _decode_scene_voxel_tile_summaries(bytes: PackedByteArray, tile_ids: Array[String]) -> Array[Dictionary]:
	return SceneVoxelTileCodecScript.decode_summaries(bytes, tile_ids)

## 计算字符串的稳定哈希

static func _stable_scene_voxel_tile_hash(value: String) -> int:
	return SceneVoxelTileCodecScript.stable_hash(value)

## 生成SV瓦片的存储键

func _tile_coord_from_summary_index(index: int, tile_grid: Vector3i) -> Vector3i:
	var safe_x := maxi(tile_grid.x, 1)
	var safe_y := maxi(tile_grid.y, 1)
	var x := index % safe_x
	var yz := int(index / safe_x)
	var y := yz % safe_y
	var z := int(yz / safe_y)
	return Vector3i(x, y, z)

## 将量化后的整数值还原为体素摘要浮点值

func _decode_tile_summary_value(raw_value: int) -> float:
	return float(maxi(raw_value, 0)) / SCENE_VOXEL_TILE_REDUCE_QUANT_SCALE

## 解码紧凑摘要缓冲区为场景体素瓦片摘要数组

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

## 执行帧级GC但临时保留指定RID免被回收

func _reduce_scene_voxel_tile_summaries_gpu(
	complexity_field: PackedFloat32Array,
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
	var prebound_complexity_buffer: RID = buffer_contract.get("complexity_field_buffer", buffer_contract.get("complexity_buffer", RID()))
	var prebound_collision_buffer: RID = buffer_contract.get("collision_field_buffer", buffer_contract.get("collision_buffer", RID()))
	var use_prebound_complexity_buffer := prebound_complexity_buffer.is_valid() and contract_voxel_count == voxel_count
	var use_prebound_collision_buffer := prebound_collision_buffer.is_valid() and contract_voxel_count == voxel_count
	if not use_prebound_complexity_buffer and SceneVoxelTileCodecScript.infer_complexity_voxel_count(complexity_field, voxel_count) != voxel_count:
		return {}
	if not use_prebound_collision_buffer and SceneVoxelTileCodecScript.infer_scalar_voxel_count(collision_field, voxel_count) != voxel_count:
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
	var complexity_buffer := prebound_complexity_buffer
	if use_prebound_complexity_buffer:
		preserved_buffers.append(complexity_buffer)
	else:
		complexity_buffer = storage_buffer_from_bytes(
			_pack_scene_voxel_tile_complexity_field_bytes(complexity_field, voxel_count),
			SCOPE_FRAME,
			"scene_voxel_tile_summary_complexity_rgba8"
		)

	var collision_buffer := prebound_collision_buffer
	if use_prebound_collision_buffer:
		preserved_buffers.append(collision_buffer)
	else:
		collision_buffer = storage_buffer_from_bytes(
			_pack_scene_voxel_tile_collision_field_bytes(collision_field, voxel_count),
			SCOPE_FRAME,
			"scene_voxel_tile_summary_collision_r8_words"
		)

	var summary_buffer := storage_buffer_zero(tile_count * SCENE_VOXEL_TILE_REDUCE_SUMMARY_UINT_STRIDE * 4, SCOPE_FRAME, "scene_voxel_tile_summary_counts")
	var compact_buffer := storage_buffer_zero(tile_count * SCENE_VOXEL_TILE_COMPACT_SUMMARY_UINT_STRIDE * 4, SCOPE_FRAME, "scene_voxel_tile_summary_compact")
	var compact_counter_buffer := storage_buffer_zero(4, SCOPE_FRAME, "scene_voxel_tile_summary_compact_counter")
	if not complexity_buffer.is_valid() or not collision_buffer.is_valid() or not summary_buffer.is_valid() or not compact_buffer.is_valid() or not compact_counter_buffer.is_valid():
		_gc_frame_preserving_rids(preserved_buffers)
		return {}

	var init_set := create_uniform_set([
		make_storage_uniform(0, summary_buffer),
	], _shader_init_scene_voxel_tile_summaries, 0, SCOPE_PASS, "init_scene_voxel_tile_summaries")
	if not init_set.is_valid():
		_gc_frame_preserving_rids(preserved_buffers)
		return {}

	var set0 := create_uniform_set([
		make_storage_uniform(0, complexity_buffer),
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

## 将GPU归约得到的瓦片摘要写回场景体素瓦片表并标记脏

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
		tile["summary"] = _scene_voxel_tile_summary(tile)
		_scene_voxel_tiles[tile_id] = tile
	if not summaries.is_empty():
		_mark_scene_voxel_tile_staging_dirty("tile_summary_reduce")

## 从归约摘要生成旧版场景与碰撞瓦片记录字典

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
			var scene_key := SceneVoxelTileCodecScript.sv_tile_key(slice_index, px, "scene", tile_size)
			tiles[scene_key] = {
				"tile_id": scene_key,
				"clip_level": 0,
				"layer": "scene",
				"tile_size": tile_size,
				"bounds": SceneVoxelTileCodecScript.sv_tile_bounds(px, tile_size),
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
			var collision_key := SceneVoxelTileCodecScript.sv_tile_key(slice_index, px, "collision", tile_size)
			tiles[collision_key] = {
				"tile_id": collision_key,
				"clip_level": 0,
				"layer": "collision",
				"tile_size": tile_size,
				"bounds": SceneVoxelTileCodecScript.sv_tile_bounds(px, tile_size),
				"dirty": false,
				"updated_this_commit": dirty_tiles_snapshot.has(collision_key),
				"distance_or_occupancy": "occupancy",
				"scene_voxel_count": 0,
				"collision_cell_count": collision_count,
				"max_complexity": collision_minmax.y,
			}
	return tiles

## 重建场景体素(SV)状态并发布最终摘要快照

func mark_scene_voxel_tile_dirty(tile_coord: Vector3i, dirty_flags = {}, source_record: Dictionary = {}) -> void:

	var flags := SceneVoxelTileCodecScript.flags_from_value(dirty_flags)

	_touch_scene_voxel_tile(tile_coord, flags, source_record)

	_mark_legacy_sv_tiles_for_scene_voxel_tile(tile_coord, flags)

## 标记体素包围盒范围内所有瓦片为脏

func mark_scene_voxel_tile_bounds_dirty(voxel_min: Vector3i, voxel_max: Vector3i, dirty_flags = {}, source_record: Dictionary = {}) -> void:

	_for_each_scene_voxel_tile_in_bounds(voxel_min, voxel_max, func(tile_coord: Vector3i):
		mark_scene_voxel_tile_dirty(tile_coord, dirty_flags, source_record)
	)

## 标记全量场景体素瓦片需重建为脏

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

## 返回GPU自动对象引用范围策略诊断信息

func get_gpu_autoobject_object_ref_range_policy_diagnostics(refs_per_tile: int = SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT) -> Dictionary:

	var safe_refs_per_tile := maxi(refs_per_tile, 1)

	var tile_count := maxi(_scene_voxel_tile_fixed_object_ref_tile_count, _scene_voxel_tiles.size())
	var shader_ready := (
		_shader_scene_voxel_tile_object_ref_update.is_valid() and
		_pipeline_scene_voxel_tile_object_ref_update.is_valid()
	)
	var last_stats := _scene_voxel_tile_object_ref_last_update_stats.duplicate(true)
	var last_dispatched := bool(last_stats.get("gpu_dispatched", false))

	return {
		"object_ref_range_policy": "fixed_per_tile_object_ref_update_pass" if shader_ready else "fixed_per_tile_pending_shader",
		"object_ref_range_owner": "SceneVoxelCommitter",
		"object_ref_range_shader": SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_NAME if shader_ready else "none",
		"object_ref_range_shader_path": SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_PATH if shader_ready else "none",
		"object_ref_range_shader_ready": shader_ready,
		"object_ref_range_stride_bytes": SCENE_VOXEL_TILE_REF_STRIDE_BYTES,
		"refs_per_tile": safe_refs_per_tile,
		"object_ref_capacity": tile_count * safe_refs_per_tile,
		"object_ref_tile_count": tile_count,
		"object_ref_tile_size": _scene_voxel_tile_size(),
		"object_ref_tile_grid_size": _scene_voxel_tile_grid_size(),
		"object_ref_rebuild_required": _scene_voxel_tile_object_ref_rebuild_required,
		"object_ref_update_stats_available": bool(last_stats.get("stats_available", false)),
		"object_ref_update_source": str(last_stats.get("source", "none")),
		"object_ref_update_reason": str(last_stats.get("reason", "not_dispatched" if shader_ready else "resident_object_ref_update_pass_not_enabled")),
		"object_ref_update_gpu_dispatched": last_dispatched,
		"object_ref_update_dispatch_count": int(last_stats.get("dispatch_group_count", 0)) if last_dispatched else 0,
		"object_ref_overflow_count": _scene_voxel_tile_object_ref_overflow_count,
		"overflow_tile_count": _scene_voxel_tile_object_ref_overflow_tile_ids.size(),
		"object_ref_overflow_tile_ids": _scene_voxel_tile_object_ref_overflow_tile_ids.duplicate(),
		"object_ref_non_numeric_count": int(last_stats.get("non_numeric", 0)),
		"object_ref_duplicate_count": int(last_stats.get("duplicate", 0)),
		"object_ref_touched_count": int(last_stats.get("touched", 0)),
		"object_ref_removed_slot_count": int(last_stats.get("removed_slots", 0)),
		"object_ref_inserted_slot_count": int(last_stats.get("inserted_slots", 0)),
		"object_ref_invalid_bounds_count": int(last_stats.get("invalid_bounds", 0)),
		"object_ref_skipped_count": int(last_stats.get("skipped", 0)),
		"gpu_autoobject_ref_key_schema": "u32_numeric_ref_key_v1",
		"gpu_autoobject_ref_key_schema_note": "Use u32 ref_key entries; 0 is empty, numeric GPU AutoObject object_id + 1 is the pending runtime key, and legacy CPU string hashes remain debug-only.",
	}

## 尝试基于脏增量数组派发GPU对象引用更新通道

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
	result["object_ref_tile_count"] = int(update_stats.get("object_ref_tile_count", result.get("object_ref_tile_count", 0)))
	result["object_ref_tile_grid_size"] = update_stats.get("object_ref_tile_grid_size", result.get("object_ref_tile_grid_size", Vector3i.ZERO))
	result["object_ref_overflow_count"] = int(update_stats.get("overflow", 0))
	result["object_ref_non_numeric_count"] = int(update_stats.get("non_numeric", 0))
	result["object_ref_duplicate_count"] = int(update_stats.get("duplicate", 0))
	result["object_ref_touched_count"] = int(update_stats.get("touched", 0))
	result["object_ref_removed_slot_count"] = int(update_stats.get("removed_slots", 0))
	result["object_ref_inserted_slot_count"] = int(update_stats.get("inserted_slots", 0))
	result["object_ref_invalid_bounds_count"] = int(update_stats.get("invalid_bounds", 0))
	result["object_ref_skipped_count"] = int(update_stats.get("skipped", 0))
	_merge_scene_voxel_tile_object_ref_transient_dirty_result(result, update_stats)

	if int(result.get("object_ref_overflow_count", 0)) > 0:
		_scene_voxel_tile_object_ref_rebuild_required = true
		_scene_voxel_tile_object_ref_overflow_count += int(result.get("object_ref_overflow_count", 0))
		result["object_ref_rebuild_required"] = true

	return result

## 基于借用脏增量缓冲区派发GPU对象引用更新通道

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
	result["object_ref_tile_count"] = int(update_stats.get("object_ref_tile_count", result.get("object_ref_tile_count", 0)))
	result["object_ref_tile_grid_size"] = update_stats.get("object_ref_tile_grid_size", result.get("object_ref_tile_grid_size", Vector3i.ZERO))
	result["object_ref_overflow_count"] = int(update_stats.get("overflow", 0))
	result["object_ref_non_numeric_count"] = int(update_stats.get("non_numeric", 0))
	result["object_ref_duplicate_count"] = int(update_stats.get("duplicate", 0))
	result["object_ref_touched_count"] = int(update_stats.get("touched", 0))
	result["object_ref_removed_slot_count"] = int(update_stats.get("removed_slots", 0))
	result["object_ref_inserted_slot_count"] = int(update_stats.get("inserted_slots", 0))
	result["object_ref_invalid_bounds_count"] = int(update_stats.get("invalid_bounds", 0))
	result["object_ref_skipped_count"] = int(update_stats.get("skipped", 0))
	_merge_scene_voxel_tile_object_ref_transient_dirty_result(result, update_stats)

	if int(result.get("object_ref_overflow_count", 0)) > 0:
		_scene_voxel_tile_object_ref_rebuild_required = true
		_scene_voxel_tile_object_ref_overflow_count += int(result.get("object_ref_overflow_count", 0))
		result["object_ref_rebuild_required"] = true

	return result

## 应用单个GPU自动对象的脏增量并标记瓦片脏

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

	_committer._sv_dirty = true

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

## 批量应用GPU自动对象脏增量并聚合结果

func apply_gpu_autoobject_dirty_deltas(deltas: Array) -> Dictionary:

	var results: Array[Dictionary] = []

	var ok := true

	var reason := "ok"

	var failed_count := 0
	var numeric_delta_count := 0

	for raw_delta in deltas:
		if raw_delta is Dictionary and _scene_voxel_tile_numeric_object_id(raw_delta as Dictionary) >= 0:
			numeric_delta_count += 1

	var object_ref_update := {
		"ok": false,
		"reason": "empty_dirty_delta_batch" if deltas.is_empty() else "non_numeric_dirty_delta_requires_cpu_debug_projection",
		"gpu_dispatched": false,
		"stats_available": false,
		"source": "none",
		"shader": SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_NAME,
	}
	var resident_gpu_dirty_delta_update_pass := false
	var resident_gpu_dirty_delta_update_pass_owner := "none"
	var resident_gpu_dirty_delta_update_pass_shader := "none"
	var resident_gpu_dirty_delta_update_pass_dispatch_count := 0
	var dirty_delta_bridge_mode := "gpu_resident_scene_voxel_tile_dirty_delta_update_pass"

	if not deltas.is_empty() and numeric_delta_count == deltas.size():
		var update_result := try_apply_gpu_autoobject_object_ref_update_pass(deltas)
		object_ref_update = update_result.get("object_ref_update_result", {})
		if object_ref_update.is_empty():
			object_ref_update = {
				"ok": bool(update_result.get("ok", false)),
				"reason": str(update_result.get("reason", "object_ref_update_failed")),
				"gpu_dispatched": bool(update_result.get("object_ref_update_gpu_dispatched", false)),
				"stats_available": bool(update_result.get("object_ref_update_stats_available", false)),
				"source": str(update_result.get("object_ref_update_source", "none")),
				"shader": str(update_result.get("object_ref_update_shader", SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_NAME)),
			}
		if bool(update_result.get("resident_gpu_dirty_delta_update_pass", false)):
			resident_gpu_dirty_delta_update_pass = true
			resident_gpu_dirty_delta_update_pass_owner = str(update_result.get("resident_gpu_dirty_delta_update_pass_owner", "SceneVoxelCommitter"))
			resident_gpu_dirty_delta_update_pass_shader = str(update_result.get("resident_gpu_dirty_delta_update_pass_shader", SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_NAME))
			resident_gpu_dirty_delta_update_pass_dispatch_count = int(update_result.get("resident_gpu_dirty_delta_update_pass_dispatch_count", 0))
			dirty_delta_bridge_mode = "gpu_scene_voxel_tile_object_ref_update_with_cpu_debug_projection"

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

	var result := {
		"ok": ok,
		"reason": reason,
		"gpu_first": true,
		"cpu_fallback": false,
		"dirty_delta_bridge_mode": dirty_delta_bridge_mode,
		"dirty_delta_apply_api": "apply_gpu_autoobject_dirty_deltas",
		"dirty_delta_count": deltas.size(),
		"results": results,
		"commit_result_count": results.size(),
		"failed_commit_result_count": failed_count,
		"dirty_scene_voxel_tiles": dirty_tiles,
		"dirty_scene_voxel_tile_count": dirty_tiles.size(),
		"resident_gpu_dirty_delta_update_pass": resident_gpu_dirty_delta_update_pass,
		"resident_gpu_dirty_delta_update_pass_owner": resident_gpu_dirty_delta_update_pass_owner,
		"resident_gpu_dirty_delta_update_pass_shader": resident_gpu_dirty_delta_update_pass_shader,
		"resident_gpu_dirty_delta_update_pass_dispatch_count": resident_gpu_dirty_delta_update_pass_dispatch_count,
		"object_ref_update_result": object_ref_update,
	}
	result.merge(get_gpu_autoobject_object_ref_range_policy_diagnostics(), true)
	result["object_ref_update_result"] = object_ref_update
	result["resident_gpu_dirty_delta_update_pass"] = resident_gpu_dirty_delta_update_pass
	result["resident_gpu_dirty_delta_update_pass_owner"] = resident_gpu_dirty_delta_update_pass_owner
	result["resident_gpu_dirty_delta_update_pass_shader"] = resident_gpu_dirty_delta_update_pass_shader
	result["resident_gpu_dirty_delta_update_pass_dispatch_count"] = resident_gpu_dirty_delta_update_pass_dispatch_count
	if resident_gpu_dirty_delta_update_pass:
		result["object_ref_update_stats_available"] = bool(object_ref_update.get("stats_available", false))
		result["object_ref_update_source"] = str(object_ref_update.get("source", "none"))
		result["object_ref_update_reason"] = str(object_ref_update.get("reason", "ok"))
		result["object_ref_update_gpu_dispatched"] = true
		result["object_ref_update_dispatch_count"] = resident_gpu_dirty_delta_update_pass_dispatch_count
		result["object_ref_overflow_count"] = int(object_ref_update.get("overflow", 0))
		result["object_ref_non_numeric_count"] = int(object_ref_update.get("non_numeric", 0))
		result["object_ref_duplicate_count"] = int(object_ref_update.get("duplicate", 0))
		result["object_ref_touched_count"] = int(object_ref_update.get("touched", 0))
		result["object_ref_removed_slot_count"] = int(object_ref_update.get("removed_slots", 0))
		result["object_ref_inserted_slot_count"] = int(object_ref_update.get("inserted_slots", 0))
		result["object_ref_invalid_bounds_count"] = int(object_ref_update.get("invalid_bounds", 0))
		result["object_ref_skipped_count"] = int(object_ref_update.get("skipped", 0))
		_merge_scene_voxel_tile_object_ref_transient_dirty_result(result, object_ref_update)
	return result

## 获取脏场景体素瓦片快照

func get_dirty_scene_voxel_tiles() -> Dictionary:

	return _dirty_scene_voxel_tile_snapshot()

## 获取全部场景体素瓦片的副本

func get_scene_voxel_tiles() -> Dictionary:

	return _scene_voxel_tiles.duplicate(true)

## 获取指定坐标的场景体素瓦片记录

func get_scene_voxel_tile(tile_coord: Vector3i) -> Dictionary:

	var tile_id := SceneVoxelTileCodecScript.tile_id(tile_coord)

	var record = _scene_voxel_tiles.get(tile_id, {})

	if record is Dictionary:

		return (record as Dictionary).duplicate(true)

	return {}

## 清除所有SV脏标记并刷新摘要
