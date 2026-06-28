@tool
class_name SceneVoxelDebug
extends RefCounted

## 场景体素调试工具集合（自 scene_voxel_committer.gd 抽取的 debug 相关逻辑）。
## - 无状态纯函数以 static 暴露；
## - 与 committer 状态耦合的函数以 static 接收 committer 实例作为首参（见本文件后续批次）。
## committer 保留薄封装委托至本类，行为不变。SPA 暂不介入（后续再让 SPA 作为发起方）。

## 镜像 SceneVoxelCommitter 的提交负载布局常量（GPU 布局稳定，极少变动）。
const COMMIT_OUTPUT_FLOAT_STRIDE := 12
const COMMIT_SOURCE_NONE := 0
const COMMITTED_KEY_COORD_STRIDE_BYTES := 16

## 镜像 SceneVoxelCommitter 的 tile GPU buffer 名称（若 committer 改名，readback 测试会暴露）。
const TILE_RECORD_BUFFER := "scene_voxel_tile_records"
const TILE_SUMMARY_BUFFER := "scene_voxel_tile_summaries"
const TILE_DIRTY_INDEX_BUFFER := "scene_voxel_tile_dirty_indices"
const TILE_OBJECT_REF_BUFFER := "scene_voxel_tile_object_refs"
const TILE_COMPLEXITY_FIELD_BUFFER := "scene_voxel_tile_complexity_field"
const TILE_COLLISION_FIELD_BUFFER := "scene_voxel_tile_collision_field"

const SceneVoxelCommitPayloadScript := preload("res://scripts/scene_voxel_commit_payload.gd")
const SceneVoxelScript := preload("res://scripts/scene_voxel.gd")
const SharedPropertyTypeScript := preload("res://scripts/shared_property_type.gd")
const SceneVoxelSourceRecordScript := preload("res://scripts/scene_voxel_source_record.gd")


# ============================================================
# 无状态纯函数（tile 调试 ID / 调试值列表 / 已提交负载槽解码）
# ============================================================

## 从源记录候选键中取调试用对象 ID。原 _scene_voxel_tile_debug_object_id。
static func tile_object_id(source_record: Dictionary) -> String:
	for key in ["auto_object_id", "auto_id", "id", "record_id"]:
		var value := str(source_record.get(key, ""))
		if not value.is_empty():
			return value
	return ""


## 从源记录候选键中取调试用源 ID。原 _scene_voxel_tile_debug_source_id。
static func tile_source_id(source_record: Dictionary) -> String:
	for key in ["record_id", "id", "source_id", "auto_object_id", "auto_id"]:
		var value := str(source_record.get(key, ""))
		if not value.is_empty():
			return value
	return ""


## 将值列表追加到目标数组，返回追加区间的起止索引。原 _append_scene_voxel_tile_debug_range。
static func append_tile_range(target: Array[String], values: Array) -> Vector2i:
	var start := target.size()
	for raw_value in values:
		var value := str(raw_value)
		if not value.is_empty():
			target.append(value)
	return Vector2i(start, target.size() - start)


## 追加调试值到列表，可选去重。原 _append_scene_voxel_tile_debug_value。
static func append_tile_value(values: Array, value: String, unique: bool = true) -> void:
	if value.is_empty():
		return
	if unique and values.has(value):
		return
	values.append(value)


## 从已提交负载槽位解码单个体素的调试投影字典。原 _committed_scene_voxel_debug_payload_from_slot。
static func committed_payload_from_slot(
	payloads: PackedFloat32Array,
	payload_base: int,
	slice_index: int,
	voxel_xz: Vector2i
) -> Dictionary:
	if payload_base + COMMIT_OUTPUT_FLOAT_STRIDE > payloads.size():
		return {}
	if int(payloads[payload_base + 7] + 0.5) <= 0:
		return {}
	var source_selector := int(payloads[payload_base + 5] + 0.5)
	if source_selector == COMMIT_SOURCE_NONE:
		return {}
	var complexity := clampf(payloads[payload_base + 0], 0.0, 1.0)
	var color := Color(
		clampf(payloads[payload_base + 1], 0.0, 1.0),
		clampf(payloads[payload_base + 2], 0.0, 1.0),
		clampf(payloads[payload_base + 3], 0.0, 1.0),
		complexity
	)
	var scene_voxel := {
		"complexity": complexity,
		"color": color,
		"slice_index": slice_index,
		"voxel_xz": voxel_xz,
		"base_pixel": voxel_xz,
		"auto_mix": clampf(payloads[payload_base + 6], 0.0, 1.0),
	}
	var source_fields := {
		"color": color,
		"complexity": complexity,
	}
	var collision_summary := SceneVoxelCommitPayloadScript.collision_summary_from_payload(
		payloads,
		payload_base,
		COMMIT_OUTPUT_FLOAT_STRIDE
	)
	var include_collision := bool(collision_summary.get("has_collision", false))
	if include_collision:
		source_fields["collision"] = SceneVoxelCommitPayloadScript.collision_debug_array_from_summary(
			collision_summary,
			slice_index,
			voxel_xz
		)
	return SceneVoxelScript.accepted_internal(
		SharedPropertyTypeScript.apply_to_scene_voxel(scene_voxel, source_fields, complexity, include_collision)
	)


# ============================================================
# 与 committer 状态耦合的函数（static，首参传入 committer 实例；typed 以获得解析期校验）
# ============================================================

## 公共调试缓存是否已按当前已提交负载填充。原 _scene_voxel_public_debug_cache_hydrated。
## committer 参数无类型，避免与 SceneVoxelCommitter 形成 preload/类型循环依赖。
static func public_cache_hydrated(committer) -> bool:
	if committer._volume.is_empty():
		return false
	var raw_scene_voxels = committer._volume.get("scene_voxels", {})
	if not raw_scene_voxels is Dictionary:
		return false
	if int(committer._volume.get("scene_voxels_debug_api_projection_commit_tick", -1)) != committer._source_staging._committed_scene_voxel_payload_buffer_commit_tick:
		return false
	if str(committer._volume.get("scene_voxels_debug_api_projection_source", "none")) != "resident_committed_scene_voxel_payload_key_coord_buffers":
		return false
	var expected_count := int(committer._volume.get("scene_voxels_debug_api_projection_expected_count", committer._source_staging._committed_scene_voxel_payload_buffer_count))
	return (raw_scene_voxels as Dictionary).size() == expected_count


## 返回已填充的公共调试缓存条目数量。原 _scene_voxel_public_debug_cache_count。
static func public_cache_count(committer) -> int:
	if not public_cache_hydrated(committer):
		return 0
	var raw_scene_voxels = committer._volume.get("scene_voxels", {})
	return (raw_scene_voxels as Dictionary).size() if raw_scene_voxels is Dictionary else 0


## 标记公共调试缓存为待从已提交缓冲填充的暂存状态。原 _stage_scene_voxel_public_debug_cache_from_committed_buffers。
static func stage_public_cache_from_committed_buffers(committer, commit_tick: int, expected_count: int) -> void:
	if committer._volume.is_empty():
		return
	committer._volume["scene_voxels"] = {}
	committer._volume["scene_voxels_debug_api_projection_role"] = "debug_api_projection"
	committer._volume["scene_voxels_debug_api_projection_source"] = "resident_committed_scene_voxel_payload_key_coord_buffers"
	committer._volume["scene_voxels_debug_api_projection_readback_source"] = "none"
	committer._volume["scene_voxels_debug_api_projection_hydrated"] = false
	committer._volume["scene_voxels_debug_api_projection_expected_count"] = expected_count
	committer._volume["scene_voxels_debug_api_projection_commit_tick"] = commit_tick
	committer._volume["scene_voxels_debug_api_projection_runtime_owner"] = false
	committer._volume["scene_voxels_debug_api_projection_complexity_field_source"] = false
	committer._volume["scene_voxels_debug_api_collision_projection_source"] = "resident_committed_scene_voxel_payload_buffer"
	committer._volume["scene_voxels_debug_api_collision_projection_exact_layers"] = false


## 标记公共调试缓存已从已提交状态映射填充完成。原 _mark_scene_voxel_public_debug_cache_from_committed_map。
static func mark_public_cache_from_committed_map(committer, commit_tick: int, expected_count: int) -> void:
	if committer._volume.is_empty():
		return
	committer._volume["scene_voxels_debug_api_projection_role"] = "debug_api_projection"
	committer._volume["scene_voxels_debug_api_projection_source"] = "committed_scene_voxel_state_map"
	committer._volume["scene_voxels_debug_api_projection_readback_source"] = "none"
	committer._volume["scene_voxels_debug_api_projection_hydrated"] = true
	committer._volume["scene_voxels_debug_api_projection_expected_count"] = expected_count
	committer._volume["scene_voxels_debug_api_projection_commit_tick"] = commit_tick
	committer._volume["scene_voxels_debug_api_projection_runtime_owner"] = false
	committer._volume["scene_voxels_debug_api_projection_complexity_field_source"] = false
	committer._volume["scene_voxels_debug_api_collision_projection_source"] = "committed_scene_voxel_payload_summary_map"
	committer._volume["scene_voxels_debug_api_collision_projection_readback_source"] = "none"
	committer._volume["scene_voxels_debug_api_collision_projection_exact_layers"] = false


## 将公共调试缓存摘要发布到 sv 字典。原 _publish_scene_voxel_public_debug_cache_summary_to_sv。
static func publish_public_cache_summary_to_sv(committer) -> void:
	if committer._sv.is_empty():
		return
	var committed_payload_summary = committer.get_committed_scene_voxel_payload_buffer_summary()
	committer._sv["committed_scene_voxel_payload_buffer_summary"] = committed_payload_summary
	committer._sv["committed_scene_voxel_runtime_read_source"] = committed_payload_summary.get("committed_scene_voxel_runtime_read_source", "none")
	committer._sv["public_scene_voxel_projection_source"] = committed_payload_summary.get("public_scene_voxel_projection_source", "none")
	committer._sv["public_scene_voxel_projection_readback_source"] = committed_payload_summary.get("public_scene_voxel_projection_readback_source", "none")
	committer._sv["public_scene_voxel_projection_readback"] = bool(committed_payload_summary.get("public_scene_voxel_projection_readback", false))
	committer._sv["public_scene_voxel_collision_projection_source"] = committed_payload_summary.get("public_scene_voxel_collision_projection_source", "none")
	committer._sv["public_scene_voxel_collision_projection_readback_source"] = committed_payload_summary.get("public_scene_voxel_collision_projection_readback_source", "none")
	committer._sv["public_scene_voxel_collision_projection_exact_layers"] = bool(committed_payload_summary.get("public_scene_voxel_collision_projection_exact_layers", false))
	committer._sv["public_scene_voxel_projection_role"] = committed_payload_summary.get("public_scene_voxel_projection_role", "none")
	committer._sv["public_scene_voxel_projection_debug_only"] = bool(committed_payload_summary.get("public_scene_voxel_projection_debug_only", false))
	committer._sv["public_scene_voxel_projection_api_only"] = bool(committed_payload_summary.get("public_scene_voxel_projection_api_only", false))
	committer._sv["public_scene_voxel_projection_runtime_owner"] = bool(committed_payload_summary.get("public_scene_voxel_projection_runtime_owner", false))
	committer._sv["public_scene_voxel_projection_complexity_field_source"] = bool(committed_payload_summary.get("public_scene_voxel_projection_complexity_field_source", false))
	committer._sv["public_scene_voxel_projection_runtime_read_source"] = committed_payload_summary.get("public_scene_voxel_projection_runtime_read_source", "none")
	committer._sv["public_scene_voxel_projection_api"] = committed_payload_summary.get("public_scene_voxel_projection_api", "none")
	committer._sv["public_scene_voxel_projection_cache_hydrated"] = bool(committed_payload_summary.get("public_scene_voxel_projection_cache_hydrated", false))
	committer._sv["public_scene_voxel_projection_cache_pending"] = bool(committed_payload_summary.get("public_scene_voxel_projection_cache_pending", false))
	committer._sv["public_scene_voxel_projection_cache_count"] = int(committed_payload_summary.get("public_scene_voxel_projection_cache_count", 0))
	committer._sv["public_scene_voxel_projection_expected_count"] = int(committed_payload_summary.get("public_scene_voxel_projection_expected_count", 0))
	committer._sv["public_scene_voxel_projection_cache_commit_tick"] = int(committed_payload_summary.get("public_scene_voxel_projection_cache_commit_tick", -1))
	if bool(committed_payload_summary.get("public_scene_voxel_projection_cache_hydrated", false)):
		committer._sv["scene_voxel_count"] = int(committed_payload_summary.get("public_scene_voxel_projection_cache_count", committer._sv.get("scene_voxel_count", 0)))


## 从已提交 GPU 缓冲回读并填充公共调试体素缓存。原 _hydrate_scene_voxel_public_debug_cache_from_committed_buffers。
static func hydrate_public_cache_from_committed_buffers(committer) -> bool:
	if public_cache_hydrated(committer):
		return true
	if committer._volume.is_empty():
		return false
	if str(committer._volume.get("scene_voxels_debug_api_projection_source", "none")) != "resident_committed_scene_voxel_payload_key_coord_buffers":
		return false
	var expected_count := int(committer._volume.get("scene_voxels_debug_api_projection_expected_count", committer._source_staging._committed_scene_voxel_payload_buffer_count))
	if not committer._committed_scene_voxel_dense_projection_ready(expected_count):
		return false
	var payload_bytes = committer._rd.buffer_get_data(
		committer._source_staging._committed_scene_voxel_payload_buffer,
		0,
		committer._source_staging._committed_scene_voxel_payload_buffer_byte_count
	)
	if payload_bytes.size() < committer._source_staging._committed_scene_voxel_payload_buffer_byte_count:
		return false
	var key_coord_bytes = committer._rd.buffer_get_data(
		committer._source_staging._committed_scene_voxel_key_coord_buffer,
		0,
		committer._source_staging._committed_scene_voxel_key_coord_buffer_byte_count
	)
	if key_coord_bytes.size() < committer._source_staging._committed_scene_voxel_key_coord_buffer_byte_count:
		return false
	var payloads := SceneVoxelCommitPayloadScript.decode_float_buffer(
		payload_bytes,
		committer._source_staging._committed_scene_voxel_payload_buffer_count * COMMIT_OUTPUT_FLOAT_STRIDE
	)
	var projected_scene_voxels := {}
	for slot in range(committer._source_staging._committed_scene_voxel_payload_buffer_count):
		var coord_offset := slot * COMMITTED_KEY_COORD_STRIDE_BYTES
		if coord_offset + COMMITTED_KEY_COORD_STRIDE_BYTES > key_coord_bytes.size():
			return false
		var slice_index = key_coord_bytes.decode_s32(coord_offset)
		var voxel_xz := Vector2i(
			key_coord_bytes.decode_s32(coord_offset + 4),
			key_coord_bytes.decode_s32(coord_offset + 8)
		)
		var key := SceneVoxelSourceRecordScript.scene_voxel_key(slice_index, voxel_xz)
		var scene_voxel := committed_payload_from_slot(
			payloads,
			slot * COMMIT_OUTPUT_FLOAT_STRIDE,
			slice_index,
			voxel_xz
		)
		if not scene_voxel.is_empty():
			projected_scene_voxels[key] = scene_voxel
	var expected_public_count := int(committer._volume.get("scene_voxels_debug_api_projection_expected_count", projected_scene_voxels.size()))
	committer._volume["scene_voxels"] = projected_scene_voxels
	committer._volume["scene_voxels_debug_api_projection_role"] = "debug_api_projection"
	committer._volume["scene_voxels_debug_api_projection_source"] = "resident_committed_scene_voxel_payload_key_coord_buffers"
	committer._volume["scene_voxels_debug_api_projection_readback_source"] = "resident_committed_scene_voxel_payload_buffer_debug_api_readback"
	committer._volume["scene_voxels_debug_api_projection_hydrated"] = true
	committer._volume["scene_voxels_debug_api_projection_expected_count"] = expected_public_count
	committer._volume["scene_voxels_debug_api_projection_commit_tick"] = committer._source_staging._committed_scene_voxel_payload_buffer_commit_tick
	committer._volume["scene_voxels_debug_api_projection_runtime_owner"] = false
	committer._volume["scene_voxels_debug_api_projection_complexity_field_source"] = false
	committer._volume["scene_voxels_debug_api_collision_projection_source"] = "resident_committed_scene_voxel_payload_buffer"
	committer._volume["scene_voxels_debug_api_collision_projection_readback_source"] = "resident_committed_scene_voxel_payload_buffer_debug_api_readback"
	committer._volume["scene_voxels_debug_api_collision_projection_exact_layers"] = false
	committer._source_staging._last_blend_scene_voxel_commit_summary.merge(committer.get_committed_scene_voxel_payload_buffer_summary(), true)
	publish_public_cache_summary_to_sv(committer)
	return true


## 回读 tile GPU 缓冲并组装调试快照字典。原 readback_scene_voxel_tile_debug_snapshot。
static func readback_tile_snapshot(committer) -> Dictionary:
	var summary = committer.get_scene_voxel_tile_gpu_buffer_summary()
	if not committer.is_scene_voxel_tile_gpu_ready():
		summary["readback_snapshot"] = false
		summary["tile_record_bytes"] = PackedByteArray()
		summary["summary_record_bytes"] = PackedByteArray()
		summary["dirty_index_bytes"] = PackedByteArray()
		summary["object_ref_bytes"] = PackedByteArray()
		summary["complexity_field_bytes"] = PackedByteArray()
		summary["collision_field_bytes"] = PackedByteArray()
		summary["complexity_field_values"] = PackedFloat32Array()
		summary["collision_field_values"] = PackedFloat32Array()
		return summary
	var tile_record_bytes = committer._tile_store._read_scene_voxel_tile_buffer_bytes(TILE_RECORD_BUFFER)
	var summary_record_bytes = committer._tile_store._read_scene_voxel_tile_buffer_bytes(TILE_SUMMARY_BUFFER)
	var dirty_index_bytes = committer._tile_store._read_scene_voxel_tile_buffer_bytes(TILE_DIRTY_INDEX_BUFFER)
	var object_ref_bytes = committer._tile_store._read_scene_voxel_tile_buffer_bytes(TILE_OBJECT_REF_BUFFER)
	var complexity_field_bytes = committer._tile_store._read_scene_voxel_tile_buffer_bytes(TILE_COMPLEXITY_FIELD_BUFFER)
	var collision_field_bytes = committer._tile_store._read_scene_voxel_tile_buffer_bytes(TILE_COLLISION_FIELD_BUFFER)
	summary["readback_snapshot"] = true
	summary["tile_record_bytes"] = tile_record_bytes
	summary["summary_record_bytes"] = summary_record_bytes
	summary["dirty_index_bytes"] = dirty_index_bytes
	summary["object_ref_bytes"] = object_ref_bytes
	summary["complexity_field_bytes"] = complexity_field_bytes
	summary["collision_field_bytes"] = collision_field_bytes
	summary["complexity_field_values"] = committer._tile_store._decode_scene_voxel_tile_float_field_bytes(complexity_field_bytes)
	summary["collision_field_values"] = committer._tile_store._decode_scene_voxel_tile_float_field_bytes(collision_field_bytes)
	summary["tile_ids"] = committer._tile_store._scene_voxel_tile_gpu_tile_ids.duplicate()
	summary["dirty_tile_ids"] = committer._tile_store._decode_scene_voxel_tile_dirty_ids(dirty_index_bytes)
	summary["tile_records"] = committer._tile_store._decode_scene_voxel_tile_records(tile_record_bytes, committer._tile_store._scene_voxel_tile_gpu_tile_ids)
	summary["summary_records"] = committer._tile_store._decode_scene_voxel_tile_summaries(summary_record_bytes, committer._tile_store._scene_voxel_tile_gpu_tile_ids)
	return summary


## 将已解析源候选投影到公共调试 source 流，返回投影计数。原 _project_resolved_source_candidates_for_public_debug。
static func project_resolved_source_candidates(committer, groups: Array[Dictionary]) -> int:
	var projected_count := 0
	for group in groups:
		var candidates: Array = group.get("candidates", [])
		var selected = committer._source_staging._selected_source_candidate_for_public_projection(candidates)
		if selected.is_empty():
			continue
		committer._source_staging._store_scene_voxel_source(
			str(group.get("source_type", "AutoSceneVoxel")),
			str(group.get("key", "")),
			selected
		)
		projected_count += 1
	return projected_count
