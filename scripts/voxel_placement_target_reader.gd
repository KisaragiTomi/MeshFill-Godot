class_name VoxelPlacementTargetReader


extends RefCounted
## Normalizes target-field inputs and the resident target-buffer handoff used by
## VoxelPlacementGenerator. This helper is stateless so the generator remains
## responsible only for GPU allocation and dispatch.

const TargetReadBufferBorrow := preload("res://scripts/utils/target_read_buffer_borrow.gd")
const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")


## 从 settings 取出目标可视化 RGBA8 字节（每体素 4 字节）。
## 预打包字节够长则原样返回（超长截断到期望长度）；缺失或过短则返回全零占位。
static func target_visual_rgba8_bytes_from_settings(
	settings: Dictionary,
	voxel_count: int
) -> PackedByteArray:
	var expected_bytes := maxi(voxel_count, 1) * 4
	var prepacked: PackedByteArray = settings.get("target_visual_rgba8_bytes", PackedByteArray())
	if prepacked.size() >= expected_bytes:
		return prepacked if prepacked.size() == expected_bytes else prepacked.slice(0, expected_bytes)
	var bytes := PackedByteArray()
	bytes.resize(expected_bytes)
	return bytes


## 从 settings 规范化目标场字节（每体素 vec4 = 4 个 float）。兼容 PackedFloat32Array
## 与 PackedByteArray 两种输入。返回带元信息的字典：bytes（截齐到期望长度的场数据）、
## has_target（是否拿到足量数据）、source、以及格式/步长/字节数等描述字段；数据不足时
## has_target=false 并返回全零占位。
static func target_field_bytes_from_settings(settings: Dictionary, voxel_count: int) -> Dictionary:
	var expected_floats := maxi(voxel_count, 1) * 4
	var raw_field = settings.get("target_field_bytes", PackedFloat32Array())
	var prepacked := PackedFloat32Array()
	if raw_field is PackedFloat32Array:
		prepacked = raw_field
	elif raw_field is PackedByteArray:
		prepacked = (raw_field as PackedByteArray).to_float32_array()
	if prepacked.size() >= expected_floats:
		var field_bytes := prepacked if prepacked.size() == expected_floats else prepacked.slice(0, expected_floats)
		return {
			"bytes": field_bytes,
			"has_target": true,
			"source": "target_field_bytes",
			"expected_float_count": expected_floats,
			"actual_float_count": field_bytes.size(),
			"target_field_byte_count": field_bytes.size() * 4,
			"target_field_format": "vec4",
			"target_field_stride_bytes": 16,
		}
	var empty := PackedFloat32Array()
	empty.resize(expected_floats)
	return {
		"bytes": empty,
		"has_target": false,
		"source": "none",
		"expected_float_count": expected_floats,
		"actual_float_count": prepacked.size(),
		"target_field_byte_count": 0,
		"target_field_format": "vec4",
		"target_field_stride_bytes": 16,
	}


## 从 settings 取出目标碰撞 R8 打包字节。期望长度按 SceneVoxelTileCodec 的
## u32_field_byte_count（每体素 1 个 uint32，量化值存低字节）计算；够长原样返回（超长截断），
## 缺失或过短返回全零占位。
## 从 settings 取出目标碰撞 R8 字节（展开成 u32 布局，字节数由 codec 的
## u32_field_byte_count 决定）。预打包够长则原样返回（超长截断）；否则返回全零占位。
static func target_collision_r8_bytes_from_settings(
	settings: Dictionary,
	voxel_count: int
) -> PackedByteArray:
	var expected_bytes := SceneVoxelTileCodecScript.u32_field_byte_count(maxi(voxel_count, 1))
	var prepacked: PackedByteArray = settings.get("target_collision_r8_bytes", PackedByteArray())
	if prepacked.size() >= expected_bytes:
		return prepacked if prepacked.size() == expected_bytes else prepacked.slice(0, expected_bytes)
	var bytes := PackedByteArray()
	bytes.resize(expected_bytes)
	return bytes


## 主入口：把目标场输入规范化成 VoxelPlacementGenerator 需要的 "pack" 契约字典。
## **resident-GPU-only**：只接受借用 ScenePlacementActor 常驻 GPU 缓冲
## （_borrowed_pack，零拷贝）。借用失败（无常驻交接 / RID 无效 / 设备不符 / 字节数不符）
## → push_error + _blocked_pack 阻断（reason 带 `_gpu_resident_required` 后缀）。
## **无 CPU 字节上传回退**——目标场必须由上游以常驻 GPU buffer 交接（与
## AutoObjectProbePrefilterGPU 同策略）。rd 用于校验借用缓冲与本设备一致。
## 返回的字典键集被契约测试逐字断言。
static func pack(settings: Dictionary, voxel_count: int, rd: RenderingDevice) -> Dictionary:
	var expected_field_bytes := maxi(voxel_count, 1) * 16
	var expected_collision_bytes := SceneVoxelTileCodecScript.u32_field_byte_count(maxi(voxel_count, 1))
	var target_read_buffers: Dictionary = settings.get("target_read_buffers", {})
	if target_read_buffers.is_empty() and settings.get("resident_target_read_buffer_handoff_summary", null) is Dictionary:
		target_read_buffers = settings

	var borrowed := _borrowed_pack(target_read_buffers, expected_field_bytes, expected_collision_bytes, rd)
	if bool(borrowed.get("ready", false)):
		return borrowed
	return _blocked_pack(str(borrowed.get("reason", "resident_handoff_absent")), expected_field_bytes)


## 把 pack() 结果压缩成一份可读的诊断摘要（供报告/日志用）：RID 只暴露 valid/none
## 状态而非裸 RID，并补齐 source/ownership/lifetime/字节数/格式等字段的缺省值。
static func summary(pack_data: Dictionary) -> Dictionary:
	var raw_field = pack_data.get("target_field_buffer", RID())
	var field_buffer: RID = raw_field if raw_field is RID else RID()
	var raw_color = pack_data.get("target_visual_rgba8_buffer", RID())
	var color_buffer: RID = raw_color if raw_color is RID else RID()
	var raw_collision = pack_data.get("target_collision_buffer", RID())
	var collision_buffer: RID = raw_collision if raw_collision is RID else RID()
	return {
		"ready": bool(pack_data.get("ready", false)),
		"target_read_buffer_source": str(pack_data.get("target_read_buffer_source", "none")),
		"target_read_buffer_ownership": str(pack_data.get("target_read_buffer_ownership", "none")),
		"target_read_buffer_lifetime": str(pack_data.get("target_read_buffer_lifetime", "none")),
		"target_read_buffers_borrowed": bool(pack_data.get("target_read_buffers_borrowed", false)),
		"target_read_buffers_uploaded": bool(pack_data.get("target_read_buffers_uploaded", false)),
		"target_field_bytes_uploaded": bool(pack_data.get("target_field_bytes_uploaded", false)),
		"target_color_bytes_uploaded": bool(pack_data.get("target_color_bytes_uploaded", false)),
		"target_collision_bytes_uploaded": bool(pack_data.get("target_collision_bytes_uploaded", false)),
		"target_field_buffer_rid": "valid" if field_buffer.is_valid() else "none",
		"target_field_buffer_rid_valid": field_buffer.is_valid(),
		"target_field_byte_count": int(pack_data.get("target_field_byte_count", 0)),
		"target_field_format": str(pack_data.get("target_field_format", "none")),
		"target_field_stride_bytes": int(pack_data.get("target_field_stride_bytes", 0)),
		"target_visual_rgba8_buffer_rid": "valid" if color_buffer.is_valid() else "none",
		"target_visual_rgba8_buffer_rid_valid": color_buffer.is_valid(),
		"target_visual_rgba8_byte_count": int(pack_data.get("target_visual_rgba8_byte_count", 0)),
		"target_collision_buffer_rid": "valid" if collision_buffer.is_valid() else "none",
		"target_collision_buffer_rid_valid": collision_buffer.is_valid(),
		"target_collision_byte_count": int(pack_data.get("target_collision_byte_count", 0)),
		"target_collision_format": str(pack_data.get("target_collision_format", "none")),
		"expected_byte_count": int(pack_data.get("expected_byte_count", 0)),
		"target_color_format": str(pack_data.get("target_color_format", "none")),
		"target_color_stride_bytes": int(pack_data.get("target_color_stride_bytes", 0)),
		"has_target": bool(pack_data.get("has_target", false)),
		"owner": str(pack_data.get("owner", "none")),
		"producer": str(pack_data.get("producer", "none")),
		"borrowed_from": str(pack_data.get("borrowed_from", "none")),
		"source_reason": str(pack_data.get("source_reason", "none")),
		"rendering_device_match": bool(pack_data.get("rendering_device_match", false)),
		"contract_blocked": bool(pack_data.get("contract_blocked", false)),
		"gpu_first": true,
		"cpu_fallback": false,
	}


## 构造 pack 契约字典的基线模板（ready=true 的全字段默认值）。借用/上传/阻断三条
## 分支都先取此模板再 merge 覆盖各自字段，保证键集完整一致（契约测试要求）。
static func _base_pack(expected_field_bytes: int) -> Dictionary:
	return {
		"ready": true,
		"target_read_buffer_source": "none",
		"target_read_buffer_ownership": "none",
		"target_read_buffer_lifetime": "none",
		"target_read_buffers_borrowed": false,
		"target_read_buffers_uploaded": false,
		"target_field_bytes_uploaded": false,
		"target_color_bytes_uploaded": false,
		"target_collision_bytes_uploaded": false,
		"target_field_buffer": RID(),
		"target_field_bytes": PackedFloat32Array(),
		"target_field_byte_count": expected_field_bytes,
		"expected_byte_count": expected_field_bytes,
		"target_field_format": "vec4",
		"target_field_stride_bytes": 16,
		"target_visual_rgba8_buffer": RID(),
		"target_visual_rgba8_bytes": PackedByteArray(),
		"target_visual_rgba8_byte_count": 0,
		"target_collision_buffer": RID(),
		"target_collision_r8_bytes": PackedByteArray(),
		"target_collision_byte_count": 0,
		"target_collision_format": "unorm8_u32",
		"target_color_format": "none",
		"target_color_stride_bytes": 0,
		"has_target": false,
		"owner": "none",
		"producer": "none",
		"borrowed_from": "none",
		"source_reason": "none",
		"rendering_device_match": false,
		"rid_valid": false,
		"gpu_first": true,
		"cpu_fallback": false,
	}


## 尝试借用 ScenePlacementActor 常驻 GPU 目标缓冲：解析/校验核心委托给共享的
## TargetReadBufferBorrow.resolve（RID 有效性 → 设备一致 → 字节数匹配）。借用失败
## 返回 {ready:false, reason}；成功则在 _base_pack 模板上填入借来的 field/collision
## RID 与来源元信息（ownership=borrowed_external，不拥有、不释放）。
static func _borrowed_pack(
	target_read_buffers: Dictionary,
	expected_field_bytes: int,
	expected_collision_bytes: int,
	rd: RenderingDevice
) -> Dictionary:
	var resolved := TargetReadBufferBorrow.resolve(
		target_read_buffers, expected_field_bytes, rd,
		["target_field_buffer"], expected_collision_bytes,
		["target_collision_buffer"])
	if not bool(resolved.get("ok", false)):
		return {"ready": false, "reason": str(resolved.get("reason", "resident_handoff_absent"))}
	var result := _base_pack(expected_field_bytes)
	result.merge({
		"target_read_buffer_source": "borrowed_scene_placement_actor_resident",
		"target_read_buffer_ownership": "borrowed_external",
		"target_read_buffer_lifetime": str(resolved.get("lifetime", "ScenePlacementActor owned")),
		"target_read_buffers_borrowed": true,
		"target_field_buffer": resolved.get("field_buffer", RID()),
		"target_collision_buffer": resolved.get("collision_buffer", RID()),
		"target_field_byte_count": int(resolved.get("field_byte_count", 0)),
		"target_field_format": str(resolved.get("field_format", "vec4")),
		"target_field_stride_bytes": int(resolved.get("field_stride_bytes", 16)),
		"target_collision_byte_count": int(resolved.get("collision_byte_count", 0)),
		"target_collision_format": str(resolved.get("collision_format", "unorm8_u32")),
		"has_target": true,
		"owner": str(resolved.get("owner", "ScenePlacementActor")),
		"producer": str(resolved.get("producer", "ScenePlacementActorTargetReadBuffers")),
		"borrowed_from": "ScenePlacementActor",
		"source_reason": str(resolved.get("source_reason", "ok")),
		"rendering_device_match": true,
		"rid_valid": true,
	}, true)
	return result


## 构造"阻断"结果字典：resident GPU 交接缺失或不合规（无常驻交接 / RID 无效 /
## 设备不符 / 字节数不符）时返回。**resident-GPU-only，无 CPU 上传回退**：push_error
## 并置 ready=false / contract_blocked=true / reason 带 `_gpu_resident_required` 后缀
## （与 AutoObjectProbePrefilterGPU._blocked_target_read_buffer_pack 同口径）。
static func _blocked_pack(borrow_reason: String, expected_field_bytes: int) -> Dictionary:
	var reason := "%s_gpu_resident_required" % borrow_reason
	push_error("[VoxelPlacementTargetReader] target read buffers require a resident GPU handoff: %s" % reason)
	var result := _base_pack(expected_field_bytes)
	result.merge({
		"ready": false,
		"reason": reason,
		"producer": "ScenePlacementActorTargetReadBuffers",
		"borrowed_from": "ScenePlacementActor",
		"source_reason": borrow_reason,
		"rendering_device_match": borrow_reason != "resident_target_read_buffer_rendering_device_mismatch",
		"contract_blocked": true,
	}, true)
	return result
