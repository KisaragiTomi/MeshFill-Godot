@tool
extends RefCounted

# resident target read buffer 借用的共享解析/校验核心。
# AutoObjectProbePrefilterGPU 与 VoxelPlacementGenerator 原各持一份 ~45 行的
# 同构三重校验（RID 有效性 → RenderingDevice 一致 → 字节数匹配）；此处只负责
# 解析 + 校验并返回解析出的公共字段，success/blocked 结果字典留在各调用方
# （其键集与 reason 后缀被契约测试逐字断言，不在此收敛）。


## 从 target_read_buffers 交接字典解析并校验借用的常驻 target_field 缓冲。
## field_buffer_keys：按顺序尝试的顶层缓冲键（summary.target_field_buffer 恒为
## 最后回退；prefilter 额外接受 resident_target_field_buffer 别名，VPG 不接受）。
## 失败返回 {"ok": false, "reason": <borrow reason>}；成功返回解析出的缓冲与来源字段。
static func resolve(
	target_read_buffers: Dictionary,
	expected_field_bytes: int,
	rd: RenderingDevice,
	field_buffer_keys: Array = ["target_field_buffer"]
) -> Dictionary:
	if target_read_buffers.is_empty():
		return {"ok": false, "reason": "resident_handoff_absent"}

	var summary: Dictionary = target_read_buffers.get("resident_target_read_buffer_handoff_summary", {})
	var raw_field = summary.get("target_field_buffer", RID())
	for key in field_buffer_keys:
		if target_read_buffers.has(key):
			raw_field = target_read_buffers.get(key)
			break
	var field_buffer: RID = raw_field if raw_field is RID else RID()
	if not field_buffer.is_valid():
		return {"ok": false, "reason": "resident_target_read_buffer_rid_invalid"}

	var raw_source_rd = target_read_buffers.get("rendering_device", summary.get("rendering_device", null))
	var source_rd: RenderingDevice = raw_source_rd as RenderingDevice
	if source_rd == null or rd == null or source_rd != rd:
		return {"ok": false, "reason": "resident_target_read_buffer_rendering_device_mismatch"}

	var field_byte_count := int(target_read_buffers.get(
		"target_field_byte_count",
		summary.get(
			"target_field_byte_count",
			target_read_buffers.get("expected_byte_count", summary.get("expected_byte_count", 0))
		)
	))
	if field_byte_count != expected_field_bytes:
		return {"ok": false, "reason": "resident_target_read_buffer_byte_count_mismatch"}

	return {
		"ok": true,
		"field_buffer": field_buffer,
		"field_byte_count": field_byte_count,
		"lifetime": str(target_read_buffers.get("resident_target_read_buffer_lifetime", summary.get("target_read_buffer_lifetime", "ScenePlacementActor owned"))),
		"field_format": str(target_read_buffers.get("target_field_format", summary.get("target_field_format", "vec4"))),
		"field_stride_bytes": int(target_read_buffers.get("target_field_stride_bytes", summary.get("target_field_stride_bytes", 16))),
		"owner": str(target_read_buffers.get("resident_target_read_buffer_owner", summary.get("owner", "ScenePlacementActor"))),
		"producer": str(summary.get("producer", "ScenePlacementActorTargetReadBuffers")),
		"source_reason": str(summary.get("reason", "ok")),
	}
