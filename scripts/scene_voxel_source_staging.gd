class_name SceneVoxelSourceStaging

## 场景体素来源(scene voxel source)候选暂存、resolve 与 commit/blend 子系统。
## 从 SceneVoxelCommitter 抽出(Stage 2):拥有 auto/brush 源流、候选 staging 常驻缓冲、
## resolve GPU pass、committed payload/key-coord 缓冲、public debug cache。
## 由 committer 持有，借用其 RenderingDevice，通过 _committer 反向引用读取 _volume/tick 等。
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
const SCENE_VOXEL_TILE_FIELD_STRIDE_BYTES := 4
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


## committer 反向引用(读 _volume/_generation_tick/_committed_tick，回调 tile dirty 查询)。
var _committer: SceneVoxelCommitter = null

## 本组件自有的 source compute shader 就绪标志
var _gpu_ready: bool = false

## --- source compute shader 管线(本组件拥有) ---
var _shader_blend_complexity_fields: RID
var _pipeline_blend_complexity_fields: RID
var _shader_resolve_scene_sources: RID
var _pipeline_resolve_scene_sources: RID

## --- source 运行时状态(从 committer 迁入) ---
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
var _scene_voxel_source_candidate_payloads_buffer: RID
var _scene_voxel_source_candidate_payloads_capacity := 0
var _scene_voxel_source_candidate_payloads_count := 0
var _scene_voxel_source_candidate_group_indices_buffer: RID
var _scene_voxel_source_candidate_group_indices_capacity := 0
var _scene_voxel_source_candidate_group_indices_count := 0
var _scene_voxel_source_candidate_staging_epoch := 0
var _last_scene_voxel_source_resolve_summary: Dictionary = {}
var _last_blend_scene_voxel_commit_summary: Dictionary = {}
var _committed_scene_voxel_payload_buffer: RID
var _committed_scene_voxel_payload_buffer_count := 0
var _committed_scene_voxel_payload_buffer_byte_count := 0
var _committed_scene_voxel_payload_buffer_commit_tick := -1
var _committed_scene_voxel_payload_buffer_source := "none"
var _committed_scene_voxel_key_coord_buffer: RID
var _committed_scene_voxel_key_coord_buffer_count := 0
var _committed_scene_voxel_key_coord_buffer_byte_count := 0
var _committed_scene_voxel_key_coord_buffer_commit_tick := -1
var _committed_scene_voxel_key_coord_buffer_source := "none"


## 由 committer 调用：绑定反向引用、加载 source compute shader。调用前须 attach_rendering_device(_rd, false)。
func setup(committer, base_resolution: int) -> void:
	_committer = committer
	log_name = "SceneVoxelSourceStaging"
	_init_source_gpu()

## 加载 resolve / blend-fields compute shader 与管线。
func _init_source_gpu() -> void:
	_shader_resolve_scene_sources = load_compute_shader("res://shaders/resolve_scene_voxel_sources.glsl")
	if _shader_resolve_scene_sources.is_valid():
		_pipeline_resolve_scene_sources = create_compute_pipeline(_shader_resolve_scene_sources)
	_shader_blend_complexity_fields = load_compute_shader("res://shaders/blend_scene_voxel_fields.glsl")
	if _shader_blend_complexity_fields.is_valid():
		_pipeline_blend_complexity_fields = create_compute_pipeline(_shader_blend_complexity_fields)
	_gpu_ready = _pipeline_resolve_scene_sources.is_valid() and _pipeline_blend_complexity_fields.is_valid()

## 释放本组件的常驻缓冲与 shader，断开反向引用。committer 须在自身 dispose 之前调用。
func teardown() -> void:
	_release_scene_voxel_source_candidate_resident_buffers()
	_release_committed_scene_voxel_payload_buffer()
	_release_committed_scene_voxel_key_coord_buffer()
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


## Bind and dispatch a single pipeline within an open compute list (no begin/end).
## Use for multi-pass sequences where the caller manages begin_compute_list/end_compute_list.
func _gpu_dispatch_pipeline(cl: int, pipeline: RID, uniform_set: RID, push: PackedByteArray, groups: Vector3i) -> void:
	_rd.compute_list_bind_compute_pipeline(cl, pipeline)
	_rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, groups.x, groups.y, groups.z)

## --- 迁移自 committer 的 source 函数 ---
func _dirty_scene_voxel_source_keys(current_scene_voxels: Dictionary, previous_scene_voxels: Dictionary, dirty_scene_voxel_tiles: Dictionary) -> Dictionary:

	var keys := {}

	if dirty_scene_voxel_tiles.is_empty():

		return keys

	for key in current_scene_voxels.keys():

		var scene_voxel = current_scene_voxels[key]

		if scene_voxel is Dictionary and _committer._scene_voxel_in_dirty_scene_voxel_tiles(scene_voxel as Dictionary, dirty_scene_voxel_tiles):

			keys[key] = true

	for key in previous_scene_voxels.keys():

		if keys.has(key):

			continue

		var scene_voxel = previous_scene_voxels[key]

		if scene_voxel is Dictionary and _committer._scene_voxel_in_dirty_scene_voxel_tiles(scene_voxel as Dictionary, dirty_scene_voxel_tiles):

			keys[key] = true

	return keys

## 收集源流映射中落在脏 tile 内的场景体素键

func _dirty_scene_voxel_source_stream_keys(previous_scene_voxels: Dictionary, dirty_scene_voxel_tiles: Dictionary) -> Dictionary:

	return _dirty_scene_voxel_source_keys(_scene_voxel_source_stream_map(), previous_scene_voxels, dirty_scene_voxel_tiles)

## 上传场景体素 tile 的各类存储缓冲到 GPU,可选强制全量上传

func _pack_scene_voxel_commit_source_values(source_stream: Dictionary, source_keys: Array) -> PackedFloat32Array:
	return SceneVoxelCommitPayloadScript.pack_source_values(source_stream, source_keys, SCENE_VOXEL_COMMIT_SOURCE_FLOAT_STRIDE)

## 尝试解析源键为体素坐标字典

func _try_parse_scene_voxel_source_key_coord(source_key) -> Dictionary:
	var parts := str(source_key).split(":")
	if parts.size() != 3:
		return {}
	return {
		"slice_index": int(parts[0]),
		"voxel_x": int(parts[1]),
		"voxel_z": int(parts[2]),
	}

## 将已提交源键打包为坐标字节

func _pack_committed_scene_voxel_key_coord_bytes(source_keys: Array) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(source_keys.size() * SCENE_VOXEL_COMMITTED_KEY_COORD_STRIDE_BYTES)
	for slot in range(source_keys.size()):
		var coord := _try_parse_scene_voxel_source_key_coord(source_keys[slot])
		if coord.is_empty():
			return PackedByteArray()
		var offset := slot * SCENE_VOXEL_COMMITTED_KEY_COORD_STRIDE_BYTES
		bytes.encode_s32(offset, int(coord.get("slice_index", 0)))
		bytes.encode_s32(offset + 4, int(coord.get("voxel_x", 0)))
		bytes.encode_s32(offset + 8, int(coord.get("voxel_z", 0)))
		bytes.encode_s32(offset + 12, 0)
	return bytes

## Merged resolve+commit. After [method _flush_pending_scene_voxel_source_candidates] runs
## the merged resolve shader, reads committed payloads directly from
## [member _committed_scene_voxel_payload_buffer] without CPU roundtrips.
## Falls back to CPU dictionary packing when GPU buffer is not available.

func _try_blend_scene_voxel_commit_payloads_gpu(source_keys: Array, _commit_tick: int) -> Dictionary:

	if source_keys.is_empty():
		var empty_result := {
			"payloads": PackedFloat32Array(),
			"source_stream_buffer_source": "none",
			"final_source_stream_resident": false,
		}
		empty_result.merge(get_committed_scene_voxel_payload_buffer_summary(), true)
		return empty_result

	if not _gpu_ready or _rd == null:
		return {}

	_flush_pending_scene_voxel_source_candidates()

	var committed_buffer := _committed_scene_voxel_payload_buffer
	if committed_buffer.is_valid() \
			and _committed_scene_voxel_payload_buffer_count == source_keys.size() \
			and _committed_scene_voxel_payload_buffer_byte_count > 0:

		var output_float_count := source_keys.size() * SCENE_VOXEL_COMMIT_OUTPUT_FLOAT_STRIDE
		var output_byte_count := output_float_count * 4
		var output_bytes := _rd.buffer_get_data(committed_buffer, 0, mini(output_byte_count, _committed_scene_voxel_payload_buffer_byte_count))
		var payloads := SceneVoxelCommitPayloadScript.decode_float_buffer(output_bytes, output_float_count)

		var result := {
			"payloads": payloads,
			"source_stream_buffer_source": "merged_resolve_commit_gpu",
			"final_source_stream_resident": true,
		}
		result.merge(get_committed_scene_voxel_payload_buffer_summary(), true)
		return result

	return {}

## 检查已提交体素负载缓冲是否有效且字节计数匹配

func _committed_scene_voxel_payload_buffer_ready() -> bool:
	return (
		_committed_scene_voxel_payload_buffer.is_valid()
		and _committed_scene_voxel_payload_buffer_count > 0
		and _committed_scene_voxel_payload_buffer_byte_count == _committed_scene_voxel_payload_buffer_count * SCENE_VOXEL_COMMITTED_PAYLOAD_STRIDE_BYTES
	)

## 检查已提交体素关键坐标缓冲是否有效且字节计数匹配

func _committed_scene_voxel_key_coord_buffer_ready() -> bool:
	return (
		_committed_scene_voxel_key_coord_buffer.is_valid()
		and _committed_scene_voxel_key_coord_buffer_count > 0
		and _committed_scene_voxel_key_coord_buffer_byte_count == _committed_scene_voxel_key_coord_buffer_count * SCENE_VOXEL_COMMITTED_KEY_COORD_STRIDE_BYTES
	)

## 检查已提交负载与关键坐标缓冲是否构成可用的密集投影

func _committed_scene_voxel_dense_projection_ready(expected_count: int = -1) -> bool:
	if expected_count >= 0 and _committed_scene_voxel_payload_buffer_count != expected_count:
		return false
	return (
		_gpu_ready
		and _rd != null
		and _committed_scene_voxel_payload_buffer_ready()
		and _committed_scene_voxel_key_coord_buffer_ready()
		and _committed_scene_voxel_payload_buffer_count == _committed_scene_voxel_key_coord_buffer_count
	)

## 汇总已提交关键坐标缓冲的就绪状态与诊断信息

func get_committed_scene_voxel_key_coord_buffer_summary() -> Dictionary:
	var ready := _committed_scene_voxel_key_coord_buffer_ready()
	var dense_projection_ready := _committed_scene_voxel_dense_projection_ready()
	return {
		"resident_committed_scene_voxel_key_coord_buffer": ready,
		"committed_scene_voxel_key_coord_buffer": ready,
		"committed_scene_voxel_key_coord_buffer_owner": "SceneVoxelCommitter" if ready else "none",
		"committed_scene_voxel_key_coord_buffer_rid": str(_committed_scene_voxel_key_coord_buffer) if ready else "none",
		"committed_scene_voxel_key_coord_buffer_lifetime": "persistent_until_next_scene_voxel_commit" if ready else "none",
		"committed_scene_voxel_key_coord_buffer_stride_bytes": SCENE_VOXEL_COMMITTED_KEY_COORD_STRIDE_BYTES if ready else 0,
		"committed_scene_voxel_key_coord_buffer_format": SCENE_VOXEL_COMMITTED_KEY_COORD_FORMAT if ready else "none",
		"committed_scene_voxel_key_coord_buffer_count": _committed_scene_voxel_key_coord_buffer_count if ready else 0,
		"committed_scene_voxel_key_coord_buffer_byte_count": _committed_scene_voxel_key_coord_buffer_byte_count if ready else 0,
		"committed_scene_voxel_key_coord_buffer_commit_tick": _committed_scene_voxel_key_coord_buffer_commit_tick,
		"committed_scene_voxel_key_coord_buffer_source": _committed_scene_voxel_key_coord_buffer_source if ready else "none",
		"committed_scene_voxel_key_coord_runtime_read_source": "resident_committed_scene_voxel_key_coord_buffer" if ready else "none",
		"committed_scene_voxel_payload_slot_map_runtime_source": "resident_committed_scene_voxel_key_coord_buffer" if ready else "none",
		"committed_scene_voxel_payload_slot_map_cpu_dictionary_source": false,
		"committed_scene_voxel_payload_slot_map_public_dictionary_source": false,
		"committed_scene_voxel_payload_slots_have_resident_key_coord_map": ready,
		"committed_scene_voxel_dense_projection_ready": dense_projection_ready,
		"rendering_device_available": _rd != null,
		"gpu_first": true,
		"cpu_fallback": false,
	}

## 检查公共调试缓存是否已根据提交缓冲填充完毕

func _scene_voxel_public_debug_cache_hydrated() -> bool:
	return SceneVoxelDebugScript.public_cache_hydrated(_committer)

## 返回已填充的公共调试缓存条目数量

func _scene_voxel_public_debug_cache_count() -> int:
	return SceneVoxelDebugScript.public_cache_count(_committer)

## 汇总已提交体素负载缓冲及公共投影的诊断信息

func get_committed_scene_voxel_payload_buffer_summary() -> Dictionary:
	var ready := _committed_scene_voxel_payload_buffer_ready()
	var dense_projection_ready := _committed_scene_voxel_dense_projection_ready()
	var public_projection_ready := ready and dense_projection_ready
	var public_cache_hydrated := _scene_voxel_public_debug_cache_hydrated()
	var public_cache_count := _scene_voxel_public_debug_cache_count()
	var public_expected_count := int(_committer._volume.get("scene_voxels_debug_api_projection_expected_count", _committed_scene_voxel_payload_buffer_count)) if not _committer._volume.is_empty() else _committed_scene_voxel_payload_buffer_count
	var summary := {
		"resident_committed_scene_voxel_payload_buffer": ready,
		"committed_scene_voxel_payload_buffer": ready,
		"committed_scene_voxel_payload_buffer_owner": "SceneVoxelCommitter" if ready else "none",
		"committed_scene_voxel_payload_buffer_rid": str(_committed_scene_voxel_payload_buffer) if ready else "none",
		"committed_scene_voxel_payload_buffer_lifetime": "persistent_until_next_scene_voxel_commit" if ready else "none",
		"committed_scene_voxel_payload_buffer_stride_bytes": SCENE_VOXEL_COMMITTED_PAYLOAD_STRIDE_BYTES if ready else 0,
		"committed_scene_voxel_payload_buffer_count": _committed_scene_voxel_payload_buffer_count if ready else 0,
		"committed_scene_voxel_payload_buffer_byte_count": _committed_scene_voxel_payload_buffer_byte_count if ready else 0,
		"committed_scene_voxel_payload_buffer_commit_tick": _committed_scene_voxel_payload_buffer_commit_tick,
		"committed_scene_voxel_payload_buffer_source": _committed_scene_voxel_payload_buffer_source if ready else "none",
		"committed_scene_voxel_runtime_read_source": "resident_committed_scene_voxel_payload_buffer" if ready else "none",
		"committed_scene_voxel_payload_readback_source": "gpu_storage_buffer_debug_projection" if ready else "none",
		"committed_scene_voxel_payload_collision_summary": ready,
		"committed_scene_voxel_payload_collision_summary_source": "resident_committed_scene_voxel_payload_buffer" if ready else "none",
		"committed_scene_voxel_payload_collision_exact_layers": false,
		"public_scene_voxel_projection_source": "resident_committed_scene_voxel_payload_key_coord_buffers" if public_projection_ready else "none",
		"public_scene_voxel_projection_readback_source": "resident_committed_scene_voxel_payload_buffer_debug_api_readback" if public_cache_hydrated else "none",
		"public_scene_voxel_projection_readback": public_cache_hydrated,
		"public_scene_voxel_collision_projection_source": "resident_committed_scene_voxel_payload_buffer" if public_projection_ready else "none",
		"public_scene_voxel_collision_projection_readback_source": "resident_committed_scene_voxel_payload_buffer_debug_api_readback" if public_cache_hydrated else "none",
		"public_scene_voxel_collision_projection_exact_layers": false,
		"public_scene_voxel_projection_role": "debug_api_projection" if public_projection_ready else "none",
		"public_scene_voxel_projection_debug_only": public_projection_ready,
		"public_scene_voxel_projection_api_only": public_projection_ready,
		"public_scene_voxel_projection_runtime_owner": false,
		"public_scene_voxel_projection_complexity_field_source": false,
		"public_scene_voxel_projection_runtime_read_source": "none",
		"public_scene_voxel_projection_api": "get_scene_voxels/get_scene_voxel" if public_projection_ready else "none",
		"public_scene_voxel_projection_cache_hydrated": public_cache_hydrated,
		"public_scene_voxel_projection_cache_pending": public_projection_ready and not public_cache_hydrated,
		"public_scene_voxel_projection_cache_count": public_cache_count,
		"public_scene_voxel_projection_expected_count": public_expected_count if public_projection_ready else 0,
		"public_scene_voxel_projection_cache_commit_tick": _committed_scene_voxel_payload_buffer_commit_tick if public_cache_hydrated else -1,
		"committed_scene_voxel_dense_projection_ready": dense_projection_ready,
		"committed_scene_voxel_complexity_field_projection_source": "resident_committed_scene_voxel_payload_buffer" if dense_projection_ready else "none",
		"rendering_device_available": _rd != null,
		"gpu_first": true,
		"cpu_fallback": false,
	}
	summary.merge(get_committed_scene_voxel_key_coord_buffer_summary(), true)
	return summary

## 释放已提交体素负载及关键坐标缓冲并重置状态

func _release_committed_scene_voxel_payload_buffer() -> void:
	if _committed_scene_voxel_payload_buffer.is_valid():
		release_rid(_committed_scene_voxel_payload_buffer, false)
	_release_committed_scene_voxel_key_coord_buffer()
	_committed_scene_voxel_payload_buffer = RID()
	_committed_scene_voxel_payload_buffer_count = 0
	_committed_scene_voxel_payload_buffer_byte_count = 0
	_committed_scene_voxel_payload_buffer_commit_tick = -1
	_committed_scene_voxel_payload_buffer_source = "none"

## 释放已提交体素关键坐标缓冲并重置相关状态

func _release_committed_scene_voxel_key_coord_buffer() -> void:
	if _committed_scene_voxel_key_coord_buffer.is_valid():
		release_rid(_committed_scene_voxel_key_coord_buffer, false)
	_committed_scene_voxel_key_coord_buffer = RID()
	_committed_scene_voxel_key_coord_buffer_count = 0
	_committed_scene_voxel_key_coord_buffer_byte_count = 0
	_committed_scene_voxel_key_coord_buffer_commit_tick = -1
	_committed_scene_voxel_key_coord_buffer_source = "none"

## 标记公共调试缓存为待从已提交缓冲填充的暂存状态

func _stage_scene_voxel_public_debug_cache_from_committed_buffers(commit_tick: int, expected_count: int) -> void:
	SceneVoxelDebugScript.stage_public_cache_from_committed_buffers(_committer, commit_tick, expected_count)

## 标记公共调试缓存已从已提交状态映射填充完成

func _mark_scene_voxel_public_debug_cache_from_committed_map(commit_tick: int, expected_count: int) -> void:
	SceneVoxelDebugScript.mark_public_cache_from_committed_map(_committer, commit_tick, expected_count)

## 从已提交负载槽位解码单个体素的调试投影字典

func _committed_scene_voxel_debug_payload_from_slot(
	payloads: PackedFloat32Array,
	payload_base: int,
	slice_index: int,
	voxel_xz: Vector2i
) -> Dictionary:
	return SceneVoxelDebugScript.committed_payload_from_slot(payloads, payload_base, slice_index, voxel_xz)

## 将公共调试缓存摘要发布到 sv 字典

func _publish_scene_voxel_public_debug_cache_summary_to_sv() -> void:
	SceneVoxelDebugScript.publish_public_cache_summary_to_sv(_committer)

## 从已提交 GPU 缓冲回读并填充公共调试体素缓存

func _hydrate_scene_voxel_public_debug_cache_from_committed_buffers() -> bool:
	return SceneVoxelDebugScript.hydrate_public_cache_from_committed_buffers(_committer)

## 将 GPU 负载数据提交写入最终场景体素源映射

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

## 尝试用 GPU 源流生成场景体素复杂度场并回读

func _try_make_sv_complexity_field_from_source_streams_gpu(xz_res: int, total_slices: int) -> PackedFloat32Array:
	var result := _try_make_sv_complexity_field_from_source_streams_gpu_result(xz_res, total_slices)
	var field: PackedFloat32Array = result.get("field", PackedFloat32Array())
	return field

## 生成场景体素复杂度场并返回包含来源与缓冲的详细结果

func _try_make_sv_complexity_field_from_source_streams_gpu_result(
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

	var keep_output_buffer := not output_buffer_scope.is_empty()
	var expected_committed_payload_count := -1
	var raw_scene_voxels = _committer._volume.get("scene_voxels", {})
	if raw_scene_voxels is Dictionary and not (raw_scene_voxels as Dictionary).is_empty():
		expected_committed_payload_count = (raw_scene_voxels as Dictionary).size()
	var committed_projection_ready := _committed_scene_voxel_dense_projection_ready(expected_committed_payload_count)
	var source_keys: Array = []

	if not committed_projection_ready:
		source_keys = _scene_voxel_source_stream_map().keys()
		source_keys.sort()

	if not committed_projection_ready and source_keys.is_empty():

		var empty_field := PackedFloat32Array()

		empty_field.resize(voxel_count * 4)

		var empty_result := {
			"field": empty_field,
			"voxel_count": voxel_count,
			"complexity_field_source": "auto_brush_source_stream_compute",
			"complexity_field_runtime_read_source": "none",
			"complexity_field_projection_mode": "empty_source_streams",
			"complexity_field_committed_payload_projection": false,
		}
		if keep_output_buffer and _gpu_ready and _rd != null:
			var empty_buffer := storage_buffer_zero(voxel_count * SCENE_VOXEL_TILE_FIELD_STRIDE_BYTES, output_buffer_scope, "blend_complexity_field_out_empty")
			if empty_buffer.is_valid():
				empty_result["complexity_field_buffer"] = empty_buffer
		return empty_result

	if not _gpu_ready or _rd == null or not _pipeline_blend_complexity_fields.is_valid() or not _shader_blend_complexity_fields.is_valid():
		push_error("[SceneVoxelCommitter] SV complexity field compute resources are not ready")

		return {}

	var projection_mode := SCENE_COMPLEXITY_FIELD_PROJECTION_SOURCE_STREAMS
	var projection_count := source_keys.size()
	var auto_buffer: RID = RID()
	var brush_buffer: RID = RID()
	var committed_payload_buffer: RID = RID()
	var committed_key_coord_buffer: RID = RID()

	if committed_projection_ready:
		projection_mode = SCENE_COMPLEXITY_FIELD_PROJECTION_COMMITTED_PAYLOADS
		projection_count = _committed_scene_voxel_payload_buffer_count
		auto_buffer = storage_buffer_zero(4, SCOPE_FRAME, "blend_complexity_field_dummy_auto_source")
		brush_buffer = storage_buffer_zero(4, SCOPE_FRAME, "blend_complexity_field_dummy_brush_source")
		committed_payload_buffer = _committed_scene_voxel_payload_buffer
		committed_key_coord_buffer = _committed_scene_voxel_key_coord_buffer
	else:
		committed_payload_buffer = _committed_scene_voxel_payload_buffer
		if committed_payload_buffer.is_valid():
			projection_mode = SCENE_COMPLEXITY_FIELD_PROJECTION_COMMITTED_PAYLOADS
			projection_count = _committed_scene_voxel_payload_buffer_count
			auto_buffer = storage_buffer_zero(4, SCOPE_FRAME, "blend_complexity_field_dummy_auto_source")
			brush_buffer = storage_buffer_zero(4, SCOPE_FRAME, "blend_complexity_field_dummy_brush_source")
			committed_key_coord_buffer = _committed_scene_voxel_key_coord_buffer
		else:
			var auto_values := _pack_scene_voxel_commit_source_values(_auto_scene_voxel_sources, source_keys)
			var brush_values := _pack_scene_voxel_commit_source_values(_brush_scene_voxel_sources, source_keys)
			auto_buffer = storage_buffer_from_floats(auto_values, SCOPE_FRAME, "blend_auto_scene_sources")
			brush_buffer = storage_buffer_from_floats(brush_values, SCOPE_FRAME, "blend_brush_scene_sources")
	if not committed_projection_ready:
		committed_payload_buffer = storage_buffer_zero(
			SCENE_VOXEL_COMMITTED_PAYLOAD_STRIDE_BYTES,
			SCOPE_FRAME,
			"blend_complexity_field_dummy_committed_payloads"
		)
		committed_key_coord_buffer = storage_buffer_zero(
			SCENE_VOXEL_COMMITTED_KEY_COORD_STRIDE_BYTES,
			SCOPE_FRAME,
			"blend_complexity_field_dummy_committed_key_coords"
		)

	var output_scope := output_buffer_scope if keep_output_buffer else SCOPE_FRAME

	var output_buffer := storage_buffer_zero(voxel_count * SCENE_VOXEL_TILE_FIELD_STRIDE_BYTES, output_scope, "blend_complexity_field_out")

	if not auto_buffer.is_valid() \
			or not brush_buffer.is_valid() \
			or not committed_payload_buffer.is_valid() \
			or not committed_key_coord_buffer.is_valid() \
			or not output_buffer.is_valid():

		if keep_output_buffer:
			gc_scope(output_buffer_scope)

		gc_frame()

		return {}

	var set0 := create_uniform_set([

		make_storage_uniform(0, auto_buffer),

		make_storage_uniform(1, brush_buffer),

		make_storage_uniform(2, output_buffer),

		make_storage_uniform(3, committed_payload_buffer),

		make_storage_uniform(4, committed_key_coord_buffer),

	], _shader_blend_complexity_fields, 0, SCOPE_PASS, "blend_complexity_fields")

	if not set0.is_valid():

		if keep_output_buffer:
			gc_scope(output_buffer_scope)

		gc_frame()

		return {}

	var push := PackedByteArray()

	push.resize(32)

	push.encode_s32(0, projection_count)

	push.encode_s32(4, SCENE_VOXEL_COMMIT_SOURCE_FLOAT_STRIDE)

	push.encode_s32(8, xz_res)

	push.encode_s32(12, total_slices)

	push.encode_s32(16, projection_mode)

	push.encode_s32(20, SCENE_VOXEL_COMMIT_OUTPUT_FLOAT_STRIDE)

	push.encode_s32(24, SCENE_VOXEL_COMMITTED_KEY_COORD_STRIDE_BYTES)

	push.encode_s32(28, 0)

	var groups := dispatch_groups_1d(projection_count, 64)

	if not _gpu_dispatch_and_sync(_pipeline_blend_complexity_fields, [set0], push, groups):
		if keep_output_buffer:
			gc_scope(output_buffer_scope)
		gc_frame()
		return {}

	var output_bytes := PackedByteArray()
	var field := PackedFloat32Array()

	# When keep_output_buffer is true, skip CPU readback entirely.
	# The output_buffer RID is kept alive for the caller to use as primary state.
	if not keep_output_buffer:
		output_bytes = _rd.buffer_get_data(output_buffer, 0, voxel_count * SCENE_VOXEL_TILE_FIELD_STRIDE_BYTES)
		field = SceneVoxelTileCodecScript.decode_complexity_field_rgba8_vec4_bytes(output_bytes, voxel_count)

	gc_frame()

	var complexity_field_source := "auto_brush_source_stream_compute"
	var complexity_field_runtime_read_source := "gpu_resident_blend_output" if keep_output_buffer else "cpu_readback_debug"
	var source_stream_buffer_source := "gpu_resident_blend_output" if keep_output_buffer else "cpu_source_dictionary_pack"
	if committed_projection_ready:
		complexity_field_source = "resident_committed_scene_voxel_payload_buffers"
		complexity_field_runtime_read_source = "resident_committed_scene_voxel_payload_buffer"
		source_stream_buffer_source = "resident_committed_scene_voxel_payload_buffers"

	var result := {
		"field": field,
		"voxel_count": voxel_count,
		"complexity_field_source": complexity_field_source,
		"complexity_field_runtime_read_source": complexity_field_runtime_read_source,
		"complexity_field_projection_mode": "committed_payload_dense_scatter" if committed_projection_ready else "auto_brush_source_stream_scatter",
		"complexity_field_committed_payload_projection": committed_projection_ready,
		"complexity_field_committed_payload_count": _committed_scene_voxel_payload_buffer_count if committed_projection_ready else 0,
		"complexity_field_committed_key_coord_count": _committed_scene_voxel_key_coord_buffer_count if committed_projection_ready else 0,
		"source_stream_buffer_source": source_stream_buffer_source,
		"final_source_stream_resident": committed_projection_ready,
	}
	if keep_output_buffer:
		result["complexity_field_buffer"] = output_buffer
	return result

## 合并地形基础碰撞场与场景体素碰撞记录生成最终碰撞场

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

	var source_write_tick := int(record.get("write_tick", _committer._generation_tick))

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

## 清空所有场景体素源流及候选并释放已提交缓冲

func _clear_scene_voxel_source_streams() -> void:

	_auto_scene_voxel_sources.clear()

	_brush_scene_voxel_sources.clear()

	_pending_auto_scene_voxel_source_candidates.clear()

	_pending_brush_scene_voxel_source_candidates.clear()

	_last_scene_voxel_source_resolve_summary.clear()

	_clear_scene_voxel_source_candidate_resident_counts()

	_release_committed_scene_voxel_payload_buffer()

## 返回指定源流类型中给定键的当前源记录

func _source_stream_current(source_type: String, key: String):

	if source_type == "BrushSceneVoxel":

		return _brush_scene_voxel_sources.get(key, {})

	return _auto_scene_voxel_sources.get(key, {})

## 将源元数据存入对应类型的源流字典

func _store_scene_voxel_source(source_type: String, key: String, source_metadata: Dictionary) -> void:

	if source_type == "BrushSceneVoxel":

		_brush_scene_voxel_sources[key] = source_metadata

	else:

		_auto_scene_voxel_sources[key] = source_metadata

## 返回指定源类型对应的待处理候选流字典

func _pending_source_stream(source_type: String) -> Dictionary:

	if source_type == "BrushSceneVoxel":

		return _pending_brush_scene_voxel_source_candidates

	return _pending_auto_scene_voxel_source_candidates

## 读取源候选字典的写入 tick 值

func _source_candidate_write_tick(source_voxel: Dictionary) -> int:

	return int(source_voxel.get("write_tick", -1))

## 将源候选加入对应键的待处理候选队列

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

## 将待处理候选流按键分组追加到组列表

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

## 收集所有待处理场景体素源候选分组

func _pending_scene_voxel_source_candidate_groups() -> Array[Dictionary]:
	var groups: Array[Dictionary] = []
	_append_pending_source_candidate_groups(groups, "AutoSceneVoxel", _pending_auto_scene_voxel_source_candidates)
	_append_pending_source_candidate_groups(groups, "BrushSceneVoxel", _pending_brush_scene_voxel_source_candidates)
	return groups

## 将候选分组展开为扁平的候选字典数组

func _flatten_source_candidate_groups(groups: Array[Dictionary]) -> Array[Dictionary]:

	var result: Array[Dictionary] = []

	for group in groups:

		var candidates: Array = group.get("candidates", [])

		for raw_candidate in candidates:

			if raw_candidate is Dictionary:

				result.append(raw_candidate as Dictionary)

	return result

## 从候选分组中提取去重排序后的源键列表

func _source_keys_from_candidate_groups(groups: Array[Dictionary]) -> Array:
	var key_set := {}
	for group in groups:
		key_set[str(group.get("key", ""))] = true
	var source_keys := key_set.keys()
	source_keys.sort()
	return source_keys

## 将候选分组打包为 GPU 缓冲所需的字节与范围数据

func _pack_scene_voxel_source_candidate_groups(groups: Array[Dictionary]) -> Dictionary:
	# Build per-source-key candidate buckets: {key_str: {"auto": [candidates], "brush": [candidates]}}
	var key_buckets := {}
	for group in groups:
		var key_str := str(group.get("key", ""))
		var source_type := str(group.get("source_type", ""))
		var candidates: Array = group.get("candidates", [])
		if candidates.is_empty():
			continue
		if not key_buckets.has(key_str):
			key_buckets[key_str] = {"auto": [], "brush": []}
		var bucket: Dictionary = key_buckets[key_str]
		var target_list: Array = bucket["auto"] if source_type == "AutoSceneVoxel" else bucket["brush"]
		for c in candidates:
			if c is Dictionary:
				target_list.append(c)

	var source_keys := key_buckets.keys()
	source_keys.sort()

	var candidate_records := PackedFloat32Array()
	var ranges := PackedInt32Array()
	var group_source_key_indices := PackedInt32Array()
	var candidate_source_stream := {}
	var candidate_source_keys := []
	var candidate_count := 0

	for key_idx in range(source_keys.size()):
		var key_str := str(source_keys[key_idx])
		group_source_key_indices.append(key_idx)

		var buckets: Dictionary = key_buckets.get(key_str, {"auto": [], "brush": []})
		var auto_candidates: Array = buckets.get("auto", [])
		var brush_candidates: Array = buckets.get("brush", [])

		# Auto range
		var auto_start := candidate_count
		var auto_valid := 0
		for raw_candidate in auto_candidates:
			if not raw_candidate is Dictionary:
				continue
			var candidate := raw_candidate as Dictionary
			var candidate_key := str(candidate_count)
			candidate_source_stream[candidate_key] = candidate
			candidate_source_keys.append(candidate_key)
			candidate_records.append(float(candidate.get("priority", 0.0)))
			candidate_records.append(SceneVoxelScript.complexity(candidate))
			candidate_records.append(float(SceneVoxelSourceRecordScript.source_type_code(candidate)))
			candidate_records.append(1.0 if candidate.has("priority") else 0.0)
			candidate_count += 1
			auto_valid += 1
		ranges.append(auto_start)
		ranges.append(auto_valid)

		# Brush range
		var brush_start := candidate_count
		var brush_valid := 0
		for raw_candidate in brush_candidates:
			if not raw_candidate is Dictionary:
				continue
			var candidate := raw_candidate as Dictionary
			var candidate_key := str(candidate_count)
			candidate_source_stream[candidate_key] = candidate
			candidate_source_keys.append(candidate_key)
			candidate_records.append(float(candidate.get("priority", 0.0)))
			candidate_records.append(SceneVoxelScript.complexity(candidate))
			candidate_records.append(float(SceneVoxelSourceRecordScript.source_type_code(candidate)))
			candidate_records.append(1.0 if candidate.has("priority") else 0.0)
			candidate_count += 1
			brush_valid += 1
		ranges.append(brush_start)
		ranges.append(brush_valid)

	var candidate_payloads := _pack_scene_voxel_commit_source_values(candidate_source_stream, candidate_source_keys)

	return {
		"candidate_bytes": pack_float_array(candidate_records),
		"candidate_count": candidate_count,
		"candidate_payload_bytes": pack_float_array(candidate_payloads),
		"range_bytes": pack_u32_array(ranges),
		"range_count": source_keys.size(),
		"group_source_key_index_bytes": pack_u32_array(group_source_key_indices),
		"group_source_key_index_count": group_source_key_indices.size(),
		"source_keys": source_keys,
		"source_key_count": source_keys.size(),
	}

## 释放所有常驻源候选缓冲并重置容量与计数

func _release_scene_voxel_source_candidate_resident_buffers() -> void:
	if _scene_voxel_source_candidate_records_buffer.is_valid():
		release_rid(_scene_voxel_source_candidate_records_buffer, false)
	if _scene_voxel_source_candidate_ranges_buffer.is_valid():
		release_rid(_scene_voxel_source_candidate_ranges_buffer, false)
	if _scene_voxel_source_candidate_payloads_buffer.is_valid():
		release_rid(_scene_voxel_source_candidate_payloads_buffer, false)
	if _scene_voxel_source_candidate_group_indices_buffer.is_valid():
		release_rid(_scene_voxel_source_candidate_group_indices_buffer, false)
	_scene_voxel_source_candidate_records_buffer = RID()
	_scene_voxel_source_candidate_records_capacity = 0
	_scene_voxel_source_candidate_records_count = 0
	_scene_voxel_source_candidate_ranges_buffer = RID()
	_scene_voxel_source_candidate_ranges_capacity = 0
	_scene_voxel_source_candidate_ranges_count = 0
	_scene_voxel_source_candidate_payloads_buffer = RID()
	_scene_voxel_source_candidate_payloads_capacity = 0
	_scene_voxel_source_candidate_payloads_count = 0
	_scene_voxel_source_candidate_group_indices_buffer = RID()
	_scene_voxel_source_candidate_group_indices_capacity = 0
	_scene_voxel_source_candidate_group_indices_count = 0

## 清零常驻源候选缓冲的条目计数(不释放缓冲)

func _clear_scene_voxel_source_candidate_resident_counts() -> void:
	_scene_voxel_source_candidate_records_count = 0
	_scene_voxel_source_candidate_ranges_count = 0
	_scene_voxel_source_candidate_payloads_count = 0
	_scene_voxel_source_candidate_group_indices_count = 0

## 上传或更新常驻源候选记录缓冲并返回是否成功

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

## 上传或更新常驻源候选范围缓冲并返回是否成功

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

## 上传或更新常驻源候选负载缓冲并返回是否成功

func _stage_scene_voxel_source_candidate_payloads(bytes: PackedByteArray, payload_count: int) -> bool:
	if _rd == null or payload_count <= 0:
		_scene_voxel_source_candidate_payloads_count = 0
		return false
	var required_capacity := maxi(payload_count, 1)
	var upload_byte_count := maxi(
		required_capacity * SCENE_VOXEL_SOURCE_PAYLOAD_STRIDE_BYTES,
		maxi(bytes.size(), 4)
	)
	var upload_bytes := bytes.duplicate()
	if upload_bytes.size() < upload_byte_count:
		upload_bytes.resize(upload_byte_count)
	if not _scene_voxel_source_candidate_payloads_buffer.is_valid() or _scene_voxel_source_candidate_payloads_capacity < required_capacity:
		if _scene_voxel_source_candidate_payloads_buffer.is_valid():
			release_rid(_scene_voxel_source_candidate_payloads_buffer, false)
		_scene_voxel_source_candidate_payloads_buffer = storage_buffer_from_bytes(
			upload_bytes,
			SCOPE_PERSISTENT,
			"scene_voxel_source_candidate_payloads"
		)
		if not _scene_voxel_source_candidate_payloads_buffer.is_valid():
			_scene_voxel_source_candidate_payloads_capacity = 0
			_scene_voxel_source_candidate_payloads_count = 0
			return false
		_scene_voxel_source_candidate_payloads_capacity = required_capacity
	else:
		var buffer_byte_capacity := maxi(
			_scene_voxel_source_candidate_payloads_capacity * SCENE_VOXEL_SOURCE_PAYLOAD_STRIDE_BYTES,
			4
		)
		if upload_bytes.size() < buffer_byte_capacity:
			upload_bytes.resize(buffer_byte_capacity)
		var err := _rd.buffer_update(
			_scene_voxel_source_candidate_payloads_buffer,
			0,
			upload_bytes.size(),
			upload_bytes
		)
		if err != OK:
			_scene_voxel_source_candidate_payloads_count = 0
			return false
	_scene_voxel_source_candidate_payloads_count = payload_count
	return true

## 上传或更新常驻源候选分组索引缓冲并返回是否成功

func _stage_scene_voxel_source_candidate_group_indices(bytes: PackedByteArray, group_count: int) -> bool:
	if _rd == null or group_count <= 0:
		_scene_voxel_source_candidate_group_indices_count = 0
		return false
	var required_capacity := maxi(group_count, 1)
	var upload_byte_count := maxi(
		required_capacity * SCENE_VOXEL_SOURCE_CANDIDATE_GROUP_INDEX_STRIDE_BYTES,
		maxi(bytes.size(), 4)
	)
	var upload_bytes := bytes.duplicate()
	if upload_bytes.size() < upload_byte_count:
		upload_bytes.resize(upload_byte_count)
	if not _scene_voxel_source_candidate_group_indices_buffer.is_valid() or _scene_voxel_source_candidate_group_indices_capacity < required_capacity:
		if _scene_voxel_source_candidate_group_indices_buffer.is_valid():
			release_rid(_scene_voxel_source_candidate_group_indices_buffer, false)
		_scene_voxel_source_candidate_group_indices_buffer = storage_buffer_from_bytes(
			upload_bytes,
			SCOPE_PERSISTENT,
			"scene_voxel_source_candidate_group_indices"
		)
		if not _scene_voxel_source_candidate_group_indices_buffer.is_valid():
			_scene_voxel_source_candidate_group_indices_capacity = 0
			_scene_voxel_source_candidate_group_indices_count = 0
			return false
		_scene_voxel_source_candidate_group_indices_capacity = required_capacity
	else:
		var buffer_byte_capacity := maxi(
			_scene_voxel_source_candidate_group_indices_capacity * SCENE_VOXEL_SOURCE_CANDIDATE_GROUP_INDEX_STRIDE_BYTES,
			4
		)
		if upload_bytes.size() < buffer_byte_capacity:
			upload_bytes.resize(buffer_byte_capacity)
		var err := _rd.buffer_update(
			_scene_voxel_source_candidate_group_indices_buffer,
			0,
			upload_bytes.size(),
			upload_bytes
		)
		if err != OK:
			_scene_voxel_source_candidate_group_indices_count = 0
			return false
	_scene_voxel_source_candidate_group_indices_count = group_count
	return true

## 统一组装上传全部常驻源候选缓冲并推进暂存纪元

func _stage_scene_voxel_source_candidate_resident_buffers(
	candidate_bytes: PackedByteArray,
	candidate_count: int,
	range_bytes: PackedByteArray,
	range_count: int,
	candidate_payload_bytes: PackedByteArray,
	group_source_key_index_bytes: PackedByteArray
) -> bool:
	if not _stage_scene_voxel_source_candidate_records(candidate_bytes, candidate_count):
		_clear_scene_voxel_source_candidate_resident_counts()
		return false
	if not _stage_scene_voxel_source_candidate_ranges(range_bytes, range_count):
		_clear_scene_voxel_source_candidate_resident_counts()
		return false
	if not _stage_scene_voxel_source_candidate_payloads(candidate_payload_bytes, candidate_count):
		_clear_scene_voxel_source_candidate_resident_counts()
		return false
	if not _stage_scene_voxel_source_candidate_group_indices(group_source_key_index_bytes, range_count):
		_clear_scene_voxel_source_candidate_resident_counts()
		return false
	_scene_voxel_source_candidate_staging_epoch += 1
	return true

## 将待处理源候选暂存至常驻 GPU 缓冲并返回诊断报告

func stage_pending_scene_voxel_source_candidates_to_resident_buffers() -> Dictionary:
	var groups := _pending_scene_voxel_source_candidate_groups()
	var report := {
		"ok": true,
		"reason": "ok" if not groups.is_empty() else "no_pending_source_candidates",
		"gpu_first": true,
		"cpu_fallback": false,
		"source_write_handoff_mode": "gpu_resident_source_write_buffer",
		"cpu_pending_source_candidate_bridge": false,
		"pending_source_candidate_flush_api": "stage_pending_scene_voxel_source_candidates_to_resident_buffers;blend_scene_voxels->_flush_pending_scene_voxel_source_candidates",
		"source_candidate_resolve_api": "resolve_scene_voxel_sources.glsl",
		"candidate_group_count": groups.size(),
		"candidate_count": 0,
		"runtime_read_source": "resident_gpu_source_candidate_buffer",
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
		_init_source_gpu()

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
	var candidate_payload_bytes: PackedByteArray = packed.get("candidate_payload_bytes", PackedByteArray())
	var group_source_key_index_bytes: PackedByteArray = packed.get("group_source_key_index_bytes", PackedByteArray())
	var staged := _stage_scene_voxel_source_candidate_resident_buffers(
		candidate_bytes,
		candidate_count,
		range_bytes,
		range_count,
		candidate_payload_bytes,
		group_source_key_index_bytes
	)
	if not staged:
		report["ok"] = false
		report["reason"] = "source_candidate_resident_staging_failed"

	report.merge(_scene_voxel_source_candidate_resident_diagnostics(staged), true)
	return report

## 生成常驻源候选缓冲的就绪状态与容量诊断字典

func _scene_voxel_source_candidate_resident_diagnostics(staged: bool) -> Dictionary:
	var resident_ready := (
		staged
		and _scene_voxel_source_candidate_records_buffer.is_valid()
		and _scene_voxel_source_candidate_ranges_buffer.is_valid()
		and _scene_voxel_source_candidate_payloads_buffer.is_valid()
		and _scene_voxel_source_candidate_group_indices_buffer.is_valid()
		and _scene_voxel_source_candidate_records_count > 0
		and _scene_voxel_source_candidate_ranges_count > 0
		and _scene_voxel_source_candidate_payloads_count > 0
		and _scene_voxel_source_candidate_group_indices_count > 0
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
			"resident_source_candidate_payload_buffer": false,
			"resident_source_candidate_payload_buffer_rid": "none",
			"resident_source_candidate_payload_buffer_stride_bytes": 0,
			"resident_source_candidate_payload_buffer_capacity": 0,
			"resident_source_candidate_payload_buffer_count": 0,
			"resident_source_candidate_group_index_buffer": false,
			"resident_source_candidate_group_index_buffer_rid": "none",
			"resident_source_candidate_group_index_buffer_stride_bytes": 0,
			"resident_source_candidate_group_index_buffer_capacity": 0,
			"resident_source_candidate_group_index_buffer_count": 0,
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
		"resident_source_candidate_payload_buffer": true,
		"resident_source_candidate_payload_buffer_rid": str(_scene_voxel_source_candidate_payloads_buffer),
		"resident_source_candidate_payload_buffer_stride_bytes": SCENE_VOXEL_SOURCE_PAYLOAD_STRIDE_BYTES,
		"resident_source_candidate_payload_buffer_capacity": _scene_voxel_source_candidate_payloads_capacity,
		"resident_source_candidate_payload_buffer_count": _scene_voxel_source_candidate_payloads_count,
		"resident_source_candidate_group_index_buffer": true,
		"resident_source_candidate_group_index_buffer_rid": str(_scene_voxel_source_candidate_group_indices_buffer),
		"resident_source_candidate_group_index_buffer_stride_bytes": SCENE_VOXEL_SOURCE_CANDIDATE_GROUP_INDEX_STRIDE_BYTES,
		"resident_source_candidate_group_index_buffer_capacity": _scene_voxel_source_candidate_group_indices_capacity,
		"resident_source_candidate_group_index_buffer_count": _scene_voxel_source_candidate_group_indices_count,
		"resident_source_candidate_staging_epoch": _scene_voxel_source_candidate_staging_epoch,
	}

## 返回已解析源流的运行时读取来源诊断字典

func _resolved_scene_voxel_source_stream_diagnostics(_resident: bool) -> Dictionary:
	return {
		"runtime_read_source": "merged_resolve_commit",
		"final_source_stream_resident": _committed_scene_voxel_payload_buffer.is_valid(),
		"final_source_stream_resident_source": "resolve_scene_voxel_sources.glsl",
		"final_source_stream_resident_owner": "SceneVoxelCommitter",
		"final_source_stream_resident_count": _committed_scene_voxel_payload_buffer_count,
		"final_source_stream_resident_stride_bytes": SCENE_VOXEL_COMMIT_OUTPUT_FLOAT_STRIDE * 4,
	}

## 生成源候选 CPU 桥接的诊断字典

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

## 从摘要字典提取并整理源桥接诊断字段

func _scene_voxel_source_bridge_diagnostics_from_summary(summary: Dictionary) -> Dictionary:
	return {
		"runtime_read_source": str(summary.get("runtime_read_source", "none")),
		"source_candidate_winner_readback_source": str(summary.get("source_candidate_winner_readback_source", "none")),
		"source_candidate_winner_readback_count": int(summary.get("source_candidate_winner_readback_count", 0)),
		"source_candidate_winner_readback_stride_bytes": int(summary.get("source_candidate_winner_readback_stride_bytes", 0)),
		"source_candidate_cpu_apply_bridge": bool(summary.get("source_candidate_cpu_apply_bridge", false)),
		"source_candidate_cpu_apply_bridge_target": str(summary.get("source_candidate_cpu_apply_bridge_target", "none")),
		"final_source_stream_resident": bool(summary.get("final_source_stream_resident", false)),
		"final_source_stream_resident_source": str(summary.get("final_source_stream_resident_source", "none")),
		"final_source_stream_resident_owner": str(summary.get("final_source_stream_resident_owner", "none")),
		"final_source_stream_resident_epoch": int(summary.get("final_source_stream_resident_epoch", 0)),
		"final_source_stream_resident_count": int(summary.get("final_source_stream_resident_count", 0)),
		"final_source_stream_resident_stride_bytes": int(summary.get("final_source_stream_resident_stride_bytes", 0)),
		"resident_auto_source_stream_buffer_rid": str(summary.get("resident_auto_source_stream_buffer_rid", "none")),
		"resident_brush_source_stream_buffer_rid": str(summary.get("resident_brush_source_stream_buffer_rid", "none")),
	}

## 计算源候选用于投影比较的优先级分数

func _source_candidate_priority_for_projection(candidate: Dictionary) -> float:
	if candidate.has("priority"):
		return float(candidate.get("priority", 0.0))
	return 100.0 if SceneVoxelSourceRecordScript.source_type_code(candidate) == SCENE_VOXEL_COMMIT_SOURCE_BRUSH else 10.0

## 判断候选是否在优先级或复杂度上胜过当前选中项

func _source_candidate_beats_projection(candidate: Dictionary, current: Dictionary) -> bool:
	var candidate_priority := _source_candidate_priority_for_projection(candidate)
	var current_priority := _source_candidate_priority_for_projection(current)
	if candidate_priority > current_priority:
		return true
	if candidate_priority < current_priority:
		return false
	return SceneVoxelScript.complexity(candidate) >= SceneVoxelScript.complexity(current)

## 从候选数组中选出用于公共投影的最佳源候选

func _selected_source_candidate_for_public_projection(candidates: Array) -> Dictionary:
	var selected := {}
	for raw_candidate in candidates:
		if not raw_candidate is Dictionary:
			continue
		var candidate := raw_candidate as Dictionary
		if selected.is_empty() or _source_candidate_beats_projection(candidate, selected):
			selected = candidate
	return selected

## 将解析后的源候选投影写入源流并返回投影数量

func _project_resolved_source_candidates_for_public_debug(groups: Array[Dictionary]) -> int:
	return SceneVoxelDebugScript.project_resolved_source_candidates(_committer, groups)

## 尝试在 GPU 上解析场景体素源候选并返回结果字典

func _try_resolve_scene_voxel_source_candidates_gpu(groups: Array[Dictionary]) -> Dictionary:

	if groups.is_empty():

		return {}

	if not _gpu_ready or _rd == null:
		_init_source_gpu()

	if not _gpu_ready or _rd == null:

		return {}

	if not _pipeline_resolve_scene_sources.is_valid() or not _shader_resolve_scene_sources.is_valid():

		return {}

	var packed := _pack_scene_voxel_source_candidate_groups(groups)
	var candidate_count := int(packed.get("candidate_count", 0))
	var range_count := int(packed.get("range_count", 0))
	var source_keys: Array = packed.get("source_keys", [])
	var source_key_count := int(packed.get("source_key_count", source_keys.size()))

	if candidate_count <= 0:

		return {}

	if source_key_count <= 0:

		return {}

	var candidate_bytes: PackedByteArray = packed.get("candidate_bytes", PackedByteArray())
	var range_bytes: PackedByteArray = packed.get("range_bytes", PackedByteArray())
	var candidate_payload_bytes: PackedByteArray = packed.get("candidate_payload_bytes", PackedByteArray())
	var group_source_key_index_bytes: PackedByteArray = packed.get("group_source_key_index_bytes", PackedByteArray())

	if not _stage_scene_voxel_source_candidate_resident_buffers(
		candidate_bytes,
		candidate_count,
		range_bytes,
		range_count,
		candidate_payload_bytes,
		group_source_key_index_bytes
	):

		return {}

	var output_float_stride := SCENE_VOXEL_COMMIT_OUTPUT_FLOAT_STRIDE
	var output_byte_count := source_key_count * output_float_stride * 4

	var committed_payload_buffer: RID
	var committed_payload_reused := false

	if _committed_scene_voxel_payload_buffer.is_valid() and _committed_scene_voxel_payload_buffer_byte_count == output_byte_count:
		if buffer_zero(_committed_scene_voxel_payload_buffer, output_byte_count):
			committed_payload_buffer = _committed_scene_voxel_payload_buffer
			committed_payload_reused = true

	if not committed_payload_reused:
		_release_committed_scene_voxel_payload_buffer()
		committed_payload_buffer = storage_buffer_zero(output_byte_count, SCOPE_PERSISTENT, "committed_scene_voxel_payloads")
		if not committed_payload_buffer.is_valid():
			gc_frame()
			return {}

	var candidate_buffer := _scene_voxel_source_candidate_records_buffer

	var ranges_buffer := _scene_voxel_source_candidate_ranges_buffer

	var candidate_payload_buffer := _scene_voxel_source_candidate_payloads_buffer

	var group_source_key_index_buffer := _scene_voxel_source_candidate_group_indices_buffer

	if not candidate_buffer.is_valid() \
			or not ranges_buffer.is_valid() \
			or not candidate_payload_buffer.is_valid() \
			or not group_source_key_index_buffer.is_valid():

		if not committed_payload_reused:
			release_rid(committed_payload_buffer, false)
		_committed_scene_voxel_payload_buffer = RID()
		gc_frame()

		return {}

	var set0 := create_uniform_set([

		make_storage_uniform(0, candidate_buffer),

		make_storage_uniform(1, ranges_buffer),

		make_storage_uniform(2, candidate_payload_buffer),

		make_storage_uniform(3, committed_payload_buffer),

	], _shader_resolve_scene_sources, 0, SCOPE_PASS, "resolve_scene_sources")

	if not set0.is_valid():

		if not committed_payload_reused:
			release_rid(committed_payload_buffer, false)
		_committed_scene_voxel_payload_buffer = RID()
		gc_frame()

		return {}

	var push := PackedByteArray()

	push.resize(16)

	push.encode_s32(0, source_key_count)
	push.encode_s32(4, SCENE_VOXEL_COMMIT_SOURCE_FLOAT_STRIDE)
	push.encode_s32(8, output_float_stride)

	var dispatch_groups := dispatch_groups_1d(source_key_count, 64)

	if not _gpu_dispatch_and_sync(_pipeline_resolve_scene_sources, [set0], push, dispatch_groups):
		if not committed_payload_reused:
			release_rid(committed_payload_buffer, false)
			_committed_scene_voxel_payload_buffer = RID()
		gc_frame()
		return {}

	_committed_scene_voxel_payload_buffer = committed_payload_buffer
	_committed_scene_voxel_payload_buffer_count = source_key_count
	_committed_scene_voxel_payload_buffer_byte_count = output_byte_count
	_committed_scene_voxel_payload_buffer_source = "resolve_scene_voxel_sources_merged"
	_committed_scene_voxel_payload_buffer_commit_tick = _committer._committed_tick

	# Stage matching key_coord buffer so blend shader can map slot→voxel.
	_release_committed_scene_voxel_key_coord_buffer()
	var key_coord_bytes := _pack_committed_scene_voxel_key_coord_bytes(source_keys)
	var key_coord_byte_count := source_key_count * SCENE_VOXEL_COMMITTED_KEY_COORD_STRIDE_BYTES
	var key_coord_buffer := storage_buffer_from_bytes(
		key_coord_bytes,
		SCOPE_PERSISTENT,
		"committed_scene_voxel_key_coords"
	)
	if key_coord_buffer.is_valid():
		_committed_scene_voxel_key_coord_buffer = key_coord_buffer
		_committed_scene_voxel_key_coord_buffer_count = source_key_count
		_committed_scene_voxel_key_coord_buffer_byte_count = key_coord_byte_count
		_committed_scene_voxel_key_coord_buffer_commit_tick = _committer._committed_tick
		_committed_scene_voxel_key_coord_buffer_source = "resolve_scene_voxel_sources_merged"

	gc_frame()

	return {
		"source_keys": source_keys,
		"source_key_count": source_key_count,
		"candidate_group_count": groups.size(),
		"final_source_stream_resident": true,
	}

## 刷新待处理的场景体素源候选并尝试GPU解析提交

func _flush_pending_scene_voxel_source_candidates() -> void:

	var groups := _pending_scene_voxel_source_candidate_groups()

	if groups.is_empty():

		return

	var flattened_candidates := _flatten_source_candidate_groups(groups)

	var staging_epoch_before := _scene_voxel_source_candidate_staging_epoch

	var resolve_result := _try_resolve_scene_voxel_source_candidates_gpu(groups)

	var source_candidate_staged := _scene_voxel_source_candidate_staging_epoch > staging_epoch_before

	var final_source_stream_resident := bool(resolve_result.get("final_source_stream_resident", false))

	if not final_source_stream_resident:
		_last_scene_voxel_source_resolve_summary = {
			"mode": "compute_dispatch_failed",
			"gpu_dispatched": false,
			"candidate_group_count": groups.size(),
			"candidate_count": flattened_candidates.size(),
			"public_projection_source": "none",
			"public_projection_count": 0,
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
		_last_scene_voxel_source_resolve_summary.merge(
			_resolved_scene_voxel_source_stream_diagnostics(false),
			true
		)
		push_error("[SceneVoxelCommitter] GPU source candidate resolve dispatch failed")
		return

	var public_projection_count := _project_resolved_source_candidates_for_public_debug(groups)

	_last_scene_voxel_source_resolve_summary = {

		"mode": "resolve_resident_source_streams",

		"gpu_dispatched": true,

		"candidate_group_count": groups.size(),

		"candidate_count": flattened_candidates.size(),

		"public_projection_source": "cpu_debug_projection_from_pending_candidates",

		"public_projection_count": public_projection_count,

		"cpu_runtime_fallback": false,

	}
	_last_scene_voxel_source_resolve_summary.merge(
		_scene_voxel_source_candidate_resident_diagnostics(source_candidate_staged),
		true
	)
	_last_scene_voxel_source_resolve_summary.merge(
		_scene_voxel_source_candidate_cpu_bridge_diagnostics(
			"none",
			0,
			false
		),
		true
	)
	_last_scene_voxel_source_resolve_summary.merge(
		_resolved_scene_voxel_source_stream_diagnostics(final_source_stream_resident),
		true
	)

	_pending_auto_scene_voxel_source_candidates.clear()

	_pending_brush_scene_voxel_source_candidates.clear()

## 判断上次场景体素源GPU解析是否失败被阻塞

func _scene_voxel_source_resolve_blocked() -> bool:

	return str(_last_scene_voxel_source_resolve_summary.get("mode", "")) == "compute_dispatch_failed"

## 刷新候选并返回自动与笔刷体素源的合并流映射

func _scene_voxel_source_stream_map() -> Dictionary:

	_flush_pending_scene_voxel_source_candidates()

	var result := {}

	for key in _auto_scene_voxel_sources.keys():

		result[key] = _auto_scene_voxel_sources[key]

	for key in _brush_scene_voxel_sources.keys():

		result[key] = _brush_scene_voxel_sources[key]

	return result

## 将单条场景体素源记录入队为候选并标记对应瓦片脏

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

	var write_tick := int(source_voxel.get("write_tick", _committer._generation_tick))

	var resolved_write_tick := source_tick if source_tick >= 0 else write_tick

	var source_metadata := source_voxel.duplicate(true)

	source_metadata.erase("commit_tick")
	source_metadata["write_tick"] = resolved_write_tick

	_queue_scene_voxel_source_candidate(source_type, key, source_metadata)

	_committer._mark_sv_tile_dirty(slice_index, voxel_xz, "scene", SV_RESIDENT_TILE_SIZE, source_metadata)

## 根据记录的瓦片边界标记目标引导瓦片为脏
