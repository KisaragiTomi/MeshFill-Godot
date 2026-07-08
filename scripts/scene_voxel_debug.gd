@tool
class_name SceneVoxelDebug
extends RefCounted

## 场景体素调试工具集合（自 scene_voxel_committer.gd 抽取的 debug 相关逻辑）。
## - 无状态纯函数以 static 暴露；
## - 与 committer 状态耦合的函数以 static 接收 committer 实例作为首参。
## Stamp-only commit 后，committed payload 投影/公共缓存 hydrate 系列已随
## source-candidate 裁决管线一并删除；公共 scene_voxels 投影由盖章路径直写。

const VariantUtils := preload("res://scripts/utils/variant_utils.gd")

## 镜像 SceneVoxelCommitter 的 tile GPU buffer 名称（若 committer 改名，readback 测试会暴露）。
const TILE_RECORD_BUFFER := "scene_voxel_tile_records"
const TILE_SUMMARY_BUFFER := "scene_voxel_tile_summaries"
const TILE_OBJECT_REF_BUFFER := "scene_voxel_tile_object_refs"
const TILE_COMPLEXITY_FIELD_BUFFER := "scene_voxel_tile_complexity_field"
const TILE_COLLISION_FIELD_BUFFER := "scene_voxel_tile_collision_field"


## 从源记录候选键中取调试用对象 ID。原 _scene_voxel_tile_debug_object_id。
static func tile_object_id(source_record: Dictionary) -> String:
	return VariantUtils.first_non_empty_string(source_record, ["auto_object_id", "auto_id", "id", "record_id"])


## 从源记录候选键中取调试用源 ID。原 _scene_voxel_tile_debug_source_id。
static func tile_source_id(source_record: Dictionary) -> String:
	return VariantUtils.first_non_empty_string(source_record, ["record_id", "id", "source_id", "auto_object_id", "auto_id"])


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


## 回读 tile GPU 缓冲并组装调试快照字典。原 readback_scene_voxel_tile_debug_snapshot。
static func readback_tile_snapshot(committer) -> Dictionary:
	var summary = committer.get_scene_voxel_tile_gpu_buffer_summary()
	if not committer.is_scene_voxel_tile_gpu_ready():
		summary["readback_snapshot"] = false
		summary["tile_record_bytes"] = PackedByteArray()
		summary["summary_record_bytes"] = PackedByteArray()
		summary["object_ref_bytes"] = PackedByteArray()
		summary["complexity_field_bytes"] = PackedByteArray()
		summary["collision_field_bytes"] = PackedByteArray()
		summary["complexity_field_values"] = PackedFloat32Array()
		summary["collision_field_values"] = PackedFloat32Array()
		return summary
	var tile_record_bytes = committer._tile_store._read_scene_voxel_tile_buffer_bytes(TILE_RECORD_BUFFER)
	var summary_record_bytes = committer._tile_store._read_scene_voxel_tile_buffer_bytes(TILE_SUMMARY_BUFFER)
	var object_ref_bytes = committer._tile_store._read_scene_voxel_tile_buffer_bytes(TILE_OBJECT_REF_BUFFER)
	var complexity_field_bytes = committer._tile_store._read_scene_voxel_tile_buffer_bytes(TILE_COMPLEXITY_FIELD_BUFFER)
	var collision_field_bytes = committer._tile_store._read_scene_voxel_tile_buffer_bytes(TILE_COLLISION_FIELD_BUFFER)
	summary["readback_snapshot"] = true
	summary["tile_record_bytes"] = tile_record_bytes
	summary["summary_record_bytes"] = summary_record_bytes
	summary["object_ref_bytes"] = object_ref_bytes
	summary["complexity_field_bytes"] = complexity_field_bytes
	summary["collision_field_bytes"] = collision_field_bytes
	var resident_voxel_count := int(summary.get("resident_field_voxel_count", summary.get("complexity_field_voxel_count", 0)))
	summary["complexity_field_values"] = committer._tile_store._decode_scene_voxel_tile_complexity_field_bytes(complexity_field_bytes, resident_voxel_count)
	summary["collision_field_values"] = committer._tile_store._decode_scene_voxel_tile_collision_field_bytes(collision_field_bytes, resident_voxel_count)
	summary["tile_ids"] = committer._tile_store._scene_voxel_tile_gpu_tile_ids.duplicate()
	summary["dirty_tile_ids"] = committer._tile_store._scene_voxel_tile_gpu_dirty_tile_ids.duplicate()
	summary["tile_records"] = committer._tile_store._decode_scene_voxel_tile_records(tile_record_bytes, committer._tile_store._scene_voxel_tile_gpu_tile_ids)
	summary["summary_records"] = committer._tile_store._decode_scene_voxel_tile_summaries(summary_record_bytes, committer._tile_store._scene_voxel_tile_gpu_tile_ids)
	return summary
