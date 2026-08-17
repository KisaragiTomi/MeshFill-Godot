@tool
class_name SceneVoxelDebug
extends RefCounted

## 场景体素调试工具集合（自 scene_voxel_committer.gd 抽取的 debug 相关逻辑）。
## - 无状态纯函数以 static 暴露；
## - 与常驻 GPU 状态耦合的函数以 static 接收 SPA 的 tile store 作为首参。
## Stamp-only commit 后，committed payload 投影/公共缓存 hydrate 系列已随
## source-candidate 裁决管线一并删除；公共 scene_voxels 投影由盖章路径直写。

const VariantUtils := preload("res://scripts/utils/variant_utils.gd")
const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")

## 镜像 SceneVoxelTileStore 的 GPU buffer 名称（若 store 改名，readback 测试会暴露）。
const TILE_RECORD_BUFFER := "scene_voxel_tile_records"
const TILE_SUMMARY_BUFFER := "scene_voxel_tile_summaries"
const TILE_OBJECT_REF_BUFFER := "scene_voxel_tile_object_refs"
const TILE_DIRTY_FLAG_BUFFER := "scene_voxel_tile_dirty_flags"
const TILE_DIRTY_WORKLIST_BUFFER := "scene_voxel_tile_dirty_worklist"
const TILE_DIRTY_COUNT_BUFFER := "scene_voxel_tile_dirty_count"
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


## 回读 tile GPU 缓冲并组装只读调试快照。
static func readback_tile_snapshot(tile_store) -> Dictionary:
	var summary = tile_store.get_scene_voxel_tile_gpu_buffer_status()
	if not tile_store.is_scene_voxel_tile_gpu_ready():
		summary["readback_snapshot"] = false
		summary["tile_record_bytes"] = PackedByteArray()
		summary["summary_record_bytes"] = PackedByteArray()
		summary["object_ref_bytes"] = PackedByteArray()
		summary["dirty_flag_bytes"] = PackedByteArray()
		summary["dirty_worklist_bytes"] = PackedByteArray()
		summary["dirty_count_bytes"] = PackedByteArray()
		summary["complexity_field_bytes"] = PackedByteArray()
		summary["collision_field_bytes"] = PackedByteArray()
		summary["complexity_field_values"] = PackedFloat32Array()
		summary["collision_field_values"] = PackedFloat32Array()
		return summary
	# ⚠ 走**公开**口 `read_scene_voxel_tile_buffer_bytes()`，不是它转发的那个私有版：
	# 公开口的注释是「常驻场是多兆字节的同步回读，绝不能进每帧循环」这条警示的唯一存放处，
	# 越过它去调私有版等于绕开了唯一的告警位（本模块 8 处此前都在越界调用，2026-08-17 改回）。
	var tile_record_bytes = tile_store.read_scene_voxel_tile_buffer_bytes(TILE_RECORD_BUFFER)
	var summary_record_bytes = tile_store.read_scene_voxel_tile_buffer_bytes(TILE_SUMMARY_BUFFER)
	var object_ref_bytes = tile_store.read_scene_voxel_tile_buffer_bytes(TILE_OBJECT_REF_BUFFER)
	var dirty_flag_bytes = tile_store.read_scene_voxel_tile_buffer_bytes(TILE_DIRTY_FLAG_BUFFER)
	var dirty_worklist_bytes = tile_store.read_scene_voxel_tile_buffer_bytes(TILE_DIRTY_WORKLIST_BUFFER)
	var dirty_count_bytes = tile_store.read_scene_voxel_tile_buffer_bytes(TILE_DIRTY_COUNT_BUFFER)
	var complexity_field_bytes = tile_store.read_scene_voxel_tile_buffer_bytes(TILE_COMPLEXITY_FIELD_BUFFER)
	var collision_field_bytes = tile_store.read_scene_voxel_tile_buffer_bytes(TILE_COLLISION_FIELD_BUFFER)
	summary["readback_snapshot"] = true
	summary["tile_record_bytes"] = tile_record_bytes
	summary["summary_record_bytes"] = summary_record_bytes
	summary["object_ref_bytes"] = object_ref_bytes
	summary["dirty_flag_bytes"] = dirty_flag_bytes
	summary["dirty_worklist_bytes"] = dirty_worklist_bytes
	summary["dirty_count_bytes"] = dirty_count_bytes
	summary["complexity_field_bytes"] = complexity_field_bytes
	summary["collision_field_bytes"] = collision_field_bytes
	var resident_voxel_count := int(summary.get("resident_field_voxel_count", summary.get("complexity_field_voxel_count", 0)))
	var gpu_tile_ids: Array[String] = []
	var expected_tile_count := int(summary.get("tile_count", 0))
	var tile_grid: Vector3i = summary.get("object_ref_tile_grid_size", Vector3i.ZERO)
	for tile_index in range(expected_tile_count):
		var tile_coord := SceneVoxelTileCodecScript.tile_coord_from_index(tile_index, tile_grid)
		gpu_tile_ids.append(SceneVoxelTileCodecScript.tile_key(tile_coord))
	summary["complexity_field_values"] = SceneVoxelTileCodecScript.decode_complexity_field_rgba8_vec4_bytes(complexity_field_bytes, resident_voxel_count)
	summary["collision_field_values"] = SceneVoxelTileCodecScript.decode_collision_field_u32_bytes(collision_field_bytes, resident_voxel_count)
	summary["tile_ids"] = gpu_tile_ids.duplicate()
	# dirty_count buffer 是固定 2 个 u32（count + overflow）的常驻缓冲：
	# 回读不足 8 字节说明缓冲损坏或回读失败，以前会静默当成 "0 个脏 tile + 0 溢出"，
	# 快照看起来一切正常，实际是没读到东西。
	if dirty_count_bytes.size() < 8:
		push_error("[SceneVoxelDebug] readback_tile_snapshot: dirty_count 缓冲回读长度不足 —— 期望 >= 8 字节（count + overflow 两个 u32），实际 %d 字节；不再伪造 0 脏 tile" % dirty_count_bytes.size())
		assert(false, "SceneVoxelDebug: dirty count buffer readback too short")
		summary["readback_snapshot"] = false
		summary["readback_error"] = "dirty_count_buffer_readback_too_short"
		return summary
	var required_flag_bytes := expected_tile_count * 4
	if dirty_flag_bytes.size() < required_flag_bytes:
		push_error("[SceneVoxelDebug] readback_tile_snapshot: dirty flag 缓冲回读长度不足 —— tile_count=%d 期望 >= %d 字节，实际 %d 字节；以前尾部 tile 的脏标记会被静默读成 0" % [expected_tile_count, required_flag_bytes, dirty_flag_bytes.size()])
		assert(false, "SceneVoxelDebug: dirty flag buffer readback too short")
		summary["readback_snapshot"] = false
		summary["readback_error"] = "dirty_flag_buffer_readback_too_short"
		return summary
	# clampi 上界是遍历安全阈（worklist 容量 = tile 数），溢出量另有 overflow 字单独上报。
	var dirty_count := clampi(int(dirty_count_bytes.decode_u32(0)), 0, expected_tile_count)
	var dirty_indices: Array[int] = []
	var dirty_ids: Array[String] = []
	if dirty_worklist_bytes.size() < dirty_count * 4:
		push_error("[SceneVoxelDebug] readback_tile_snapshot: dirty worklist 回读长度不足 —— dirty_count=%d 期望 >= %d 字节，实际 %d 字节；以前会中途 break 并报告一份被截断的脏 tile 列表" % [dirty_count, dirty_count * 4, dirty_worklist_bytes.size()])
		assert(false, "SceneVoxelDebug: dirty worklist buffer readback too short")
		summary["readback_snapshot"] = false
		summary["readback_error"] = "dirty_worklist_buffer_readback_too_short"
		return summary
	for work_index in range(dirty_count):
		var byte_offset := work_index * 4
		var tile_index := int(dirty_worklist_bytes.decode_u32(byte_offset))
		if tile_index < 0 or tile_index >= expected_tile_count:
			# worklist 前 dirty_count 项由 GPU 写入且恒为合法 tile 索引；
			# 越界说明 count 与内容不一致，以前静默跳过会漏报脏 tile。
			push_error("[SceneVoxelDebug] readback_tile_snapshot: dirty worklist 第 %d 项 tile_index=%d 越界（tile_count=%d）—— 脏 tile 列表不可信" % [work_index, tile_index, expected_tile_count])
			assert(false, "SceneVoxelDebug: dirty worklist tile index out of range")
			summary["readback_snapshot"] = false
			summary["readback_error"] = "dirty_worklist_tile_index_out_of_range"
			return summary
		dirty_indices.append(tile_index)
		dirty_ids.append(gpu_tile_ids[tile_index])
	var records := SceneVoxelTileCodecScript.decode_records(tile_record_bytes, gpu_tile_ids)
	if records.size() != expected_tile_count:
		# decode_records 已 push_error/assert（长度不符即返回空）；这里做硬失败传播，
		# 不再让下面的 tile_index < records.size() 把缺失的 tile 悄悄跳过。
		summary["readback_snapshot"] = false
		summary["readback_error"] = "tile_record_decode_failed"
		return summary
	for tile_index in dirty_indices:
		var flag_bits := int(dirty_flag_bytes.decode_u32(tile_index * 4))
		records[tile_index]["dirty"] = flag_bits != 0
		records[tile_index]["dirty_flags"] = SceneVoxelTileCodecScript.flags_from_bits(flag_bits)
	summary["dirty_tile_count"] = dirty_indices.size()
	summary["dirty_tile_overflow"] = int(dirty_count_bytes.decode_u32(4))
	summary["dirty_tile_indices"] = dirty_indices
	summary["dirty_tile_ids"] = dirty_ids
	summary["tile_records"] = records
	summary["summary_records"] = SceneVoxelTileCodecScript.decode_summaries(summary_record_bytes, gpu_tile_ids)
	return summary
