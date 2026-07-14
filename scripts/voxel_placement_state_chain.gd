class_name VoxelPlacementStateChain


extends RefCounted
## State-chain contracts and compact CPU delta application for voxel placement.

const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")


static func _full_field_readback_contract(voxel_count: int, output_source: String, is_gpu_readback: bool) -> Dictionary:
	var complexity_byte_count := SceneVoxelTileCodecScript.rgba8_byte_count(voxel_count)
	var collision_byte_count := SceneVoxelTileCodecScript.u32_field_byte_count(voxel_count)
	return {
		"complexity_field_out_source": output_source,
		"collision_field_out_source": output_source,
		"complexity_field_out_is_full_field": true,
		"collision_field_out_is_full_field": true,
		"complexity_field_out_byte_count": complexity_byte_count,
		"collision_field_out_byte_count": collision_byte_count,
		"complexity_field_out_format": SceneVoxelTileCodecScript.COMPLEXITY_FIELD_FORMAT_RGBA8,
		"collision_field_out_format": SceneVoxelTileCodecScript.COLLISION_FIELD_FORMAT_UNORM8_U32,
		"complexity_field_out_stride_bytes": SceneVoxelTileCodecScript.COMPLEXITY_FIELD_STRIDE_BYTES,
		"collision_field_out_stride_bytes": SceneVoxelTileCodecScript.COLLISION_FIELD_U32_STRIDE_BYTES,
		"collision_field_out_upload_stride_bytes": 4,
		"complexity_field_out_gpu_storage_buffer_readback": is_gpu_readback,
		"collision_field_out_gpu_storage_buffer_readback": is_gpu_readback,
		"cpu_state_chaining": true,
		"cpu_state_chain_mode": "full_field_readback",
		"cpu_state_chain_source": output_source,
		"stamp_delta_cpu_state_chaining": false,
		"full_field_readback_required": true,
	}


## CPU-input state chain: compact stamp-delta contract. Used when the caller
## provides CPU field arrays instead of resident GPU buffers (demos/tests).
## CPU 输入状态链：紧凑戳记增量（compact stamp-delta）契约，
## 调用方传 CPU 场数组（而非常驻 GPU 缓冲）时使用（演示/测试路径）。
static func _compact_delta_state_chain_contract(
	voxel_count: int,
	stamp_delta_count: int,
	decoded_delta_count: int
) -> Dictionary:
	return {
		"complexity_field_out_source": "cpu_state_chain_compact_stamp_deltas",
		"collision_field_out_source": "cpu_state_chain_compact_stamp_deltas",
		"complexity_field_out_is_full_field": false,
		"collision_field_out_is_full_field": false,
		"complexity_field_out_byte_count": 0,
		"collision_field_out_byte_count": 0,
		"complexity_field_out_format": SceneVoxelTileCodecScript.COMPLEXITY_FIELD_FORMAT_RGBA8,
		"collision_field_out_format": SceneVoxelTileCodecScript.COLLISION_FIELD_FORMAT_UNORM8_U32,
		"complexity_field_out_stride_bytes": SceneVoxelTileCodecScript.COMPLEXITY_FIELD_STRIDE_BYTES,
		"collision_field_out_stride_bytes": SceneVoxelTileCodecScript.COLLISION_FIELD_U32_STRIDE_BYTES,
		"collision_field_out_upload_stride_bytes": 4,
		"complexity_field_out_gpu_storage_buffer_readback": false,
		"collision_field_out_gpu_storage_buffer_readback": false,
		"cpu_state_chaining": true,
		"cpu_state_chain_mode": "compact_stamp_deltas",
		"cpu_state_chain_source": "stamp_shader_storage_buffer",
		"stamp_delta_cpu_state_chaining": true,
		"stamp_delta_gpu_storage_buffer_readback": true,
		"stamp_delta_count": stamp_delta_count,
		"stamp_delta_decoded_count": decoded_delta_count,
		"voxel_count": maxi(voxel_count, 0),
		"full_field_readback_required": false,
	}


## GPU-resident state chain: scene/collision buffers live on GPU as borrowed RIDs.
## No full-field readback, no CPU array pass-through. This is the production default.
## GPU 常驻状态链：场景/碰撞缓冲以借用的 RID 形式常驻显存，无需完整场回读，
## 也无需 CPU 数组传递，是生产环境的默认路径。
static func _gpu_resident_state_chain_contract(
	voxel_count: int,
	gpu_resident: bool,
	scene_rid: RID,
	collision_rid: RID,
	source_label: String = "caller_provided_rid",
	owner: String = "external",
	borrowed_external: bool = true,
	blocked_reason: String = "none"
) -> Dictionary:
	return {
		"complexity_field_out_source": "gpu_resident_buffer" if gpu_resident else "gpu_resident_unavailable",
		"collision_field_out_source": "gpu_resident_buffer" if gpu_resident else "gpu_resident_unavailable",
		"complexity_field_out_is_full_field": false,
		"collision_field_out_is_full_field": false,
		"complexity_field_out_byte_count": 0,
		"collision_field_out_byte_count": 0,
		"complexity_field_out_format": SceneVoxelTileCodecScript.COMPLEXITY_FIELD_FORMAT_RGBA8,
		"collision_field_out_format": SceneVoxelTileCodecScript.COLLISION_FIELD_FORMAT_UNORM8_U32,
		"complexity_field_out_stride_bytes": SceneVoxelTileCodecScript.COMPLEXITY_FIELD_STRIDE_BYTES,
		"collision_field_out_stride_bytes": SceneVoxelTileCodecScript.COLLISION_FIELD_U32_STRIDE_BYTES,
		"collision_field_out_upload_stride_bytes": 4,
		"complexity_field_out_gpu_storage_buffer_readback": false,
		"collision_field_out_gpu_storage_buffer_readback": false,
		"gpu_state_chaining": gpu_resident,
		"gpu_state_chain_mode": "resident_buffer_borrow",
		"gpu_state_chain_source": source_label if gpu_resident else "none",
		"gpu_state_chain_owner": owner if gpu_resident else "none",
		"gpu_state_chain_borrowed_external": gpu_resident and borrowed_external,
		"gpu_state_chain_blocked_reason": "none" if gpu_resident else blocked_reason,
		"cpu_state_chaining": false,
		"cpu_state_chain_mode": "none",
		"stamp_delta_cpu_state_chaining": false,
		"stamp_delta_gpu_storage_buffer_readback": false,
		"stamp_delta_count": 0,
		"stamp_delta_decoded_count": 0,
		"voxel_count": maxi(voxel_count, 0),
		"full_field_readback_required": false,
		"complexity_field_buffer_rid": scene_rid if gpu_resident else RID(),
		"collision_field_buffer_rid": collision_rid if gpu_resident else RID(),
	}


## 判断 CPU 输入模式下是否使用紧凑戳记增量状态链（默认开启，PCIe 带宽较
## 全场回读省 90%+：256³=67MB → 仅 stamp deltas）。
## 传 force_full_field_readback=true 可退回调试用的全场回读路径。
static func _compact_delta_state_chain_requested(settings: Dictionary) -> bool:
	return not bool(settings.get("force_full_field_readback", false))


## GPU-resident state chain: scene/collision buffers live entirely on GPU.
## This is the production default path. No CPU arrays for state transfer.
## 判断是否启用 GPU 常驻状态链（生产环境默认路径），可通过
## `disable_gpu_state_chain` 或 `force_full_field_readback` 关闭。
static func _gpu_state_chain_enabled(settings: Dictionary) -> bool:
	if bool(settings.get("disable_gpu_state_chain", false)):
		return false
	if bool(settings.get("force_full_field_readback", false)):
		return false
	return true


## 将戳记增量（stamp deltas）应用到 CPU 端的复杂度/碰撞场数组，
## 并返回已应用、跳过的增量数量等统计信息。
static func _apply_stamp_deltas_to_cpu_state(
	current_complexity: PackedFloat32Array,
	current_collision: PackedFloat32Array,
	stamp_deltas: Array,
	grid_size: Vector3i
) -> Dictionary:
	var expected_voxel_count := VoxelGeneral.voxel_count(grid_size)
	var applied_count := 0
	var complexity_write_count := 0
	var collision_write_count := 0
	var skipped_count := 0
	for raw_delta in stamp_deltas:
		if not raw_delta is Dictionary:
			skipped_count += 1
			continue
		var delta: Dictionary = raw_delta
		var voxel := VoxelGeneral.vector3i_from_value(delta.get("voxel", Vector3i.ZERO), Vector3i.ZERO)
		if voxel.x < 0 or voxel.y < 0 or voxel.z < 0 \
				or voxel.x >= grid_size.x or voxel.y >= grid_size.y or voxel.z >= grid_size.z:
			skipped_count += 1
			continue
		var index := VoxelGeneral.voxel_index(voxel, grid_size)
		if index < 0 or index >= current_complexity.size() or index >= current_collision.size():
			skipped_count += 1
			continue
		var scene_value := clampf(float(delta.get("complexity", 0.0)), 0.0, 1.0)
		var collision_value := clampf(float(delta.get("collision_strength", 0.0)), 0.0, 1.0)
		if scene_value > current_complexity[index]:
			current_complexity[index] = scene_value
			complexity_write_count += 1
		if collision_value > current_collision[index]:
			current_collision[index] = collision_value
			collision_write_count += 1
		applied_count += 1
	return {
		"mode": "compact_stamp_deltas",
		"source": "stamp_shader_storage_buffer",
		"cpu_state_chaining": true,
		"full_field_readback_required": false,
		"stamp_delta_cpu_state_chaining": true,
		"stamp_delta_count": stamp_deltas.size(),
		"applied_delta_count": applied_count,
		"complexity_write_count": complexity_write_count,
		"collision_write_count": collision_write_count,
		"skipped_delta_count": skipped_count,
		"voxel_count": expected_voxel_count,
	}
