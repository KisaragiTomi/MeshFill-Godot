class_name VoxelPlacementStateChain


extends RefCounted
## State-chain mode selection and compact CPU stamp-delta application for voxel placement.


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
## 并返回已应用的增量数量等统计信息。
## **非法增量不再静默跳过计数**：deltas 由 stamp shader 写、
## VoxelPlacementGenerator._decode_stamp_deltas 解码，非 Dictionary / 越界体素 /
## 越界线性下标全部意味着 shader 或解码 ABI 出错。原来的 skipped_count 会让状态链
## 少应用一部分写入，CPU 端场与 GPU 端场从此静默漂移。任一条非法即 push_error +
## assert + 返回空字典（调用方拿不到 applied_delta_count，不会把半应用当成功）。
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
	for delta_index in range(stamp_deltas.size()):
		var raw_delta = stamp_deltas[delta_index]
		if not raw_delta is Dictionary:
			push_error("VoxelPlacementStateChain: stamp delta[%d] 不是 Dictionary（实际 %s）—— stamp 解码 ABI 出错" % [
				delta_index, type_string(typeof(raw_delta))])
			assert(false, "VoxelPlacementStateChain: stamp delta is not a Dictionary")
			return {}
		var delta: Dictionary = raw_delta
		var voxel := VoxelGeneral.vector3i_from_value(delta.get("voxel", Vector3i.ZERO), Vector3i.ZERO)
		if voxel.x < 0 or voxel.y < 0 or voxel.z < 0 \
				or voxel.x >= grid_size.x or voxel.y >= grid_size.y or voxel.z >= grid_size.z:
			push_error("VoxelPlacementStateChain: stamp delta[%d] 体素越界 voxel=%s grid_size=%s —— stamp shader 写出了网格外坐标" % [
				delta_index, str(voxel), str(grid_size)])
			assert(false, "VoxelPlacementStateChain: stamp delta voxel out of grid")
			return {}
		var index := VoxelGeneral.voxel_index(voxel, grid_size)
		if index < 0 or index >= current_complexity.size() or index >= current_collision.size():
			push_error("VoxelPlacementStateChain: stamp delta[%d] 线性下标越界 index=%d voxel=%s complexity_size=%d collision_size=%d（期望 voxel_count=%d）" % [
				delta_index, index, str(voxel), current_complexity.size(), current_collision.size(), expected_voxel_count])
			assert(false, "VoxelPlacementStateChain: stamp delta index out of field array")
			return {}
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
		# 非法增量已改为硬失败，走到这里恒为 0（键保留：报告契约字段）。
		"skipped_delta_count": 0,
		"voxel_count": expected_voxel_count,
	}
