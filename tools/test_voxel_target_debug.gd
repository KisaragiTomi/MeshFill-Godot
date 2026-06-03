extends SceneTree

const VoxelPlacementGeneratorScript := preload("res://scripts/voxel_placement_generator.gd")
const FLAG_SUPPORT := 1
const FLAG_CLEARANCE := 2


func _init() -> void:
	var grid_size := Vector3i(16, 4, 16)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var scene := PackedFloat32Array()
	var collision := PackedFloat32Array()
	scene.resize(voxel_count)
	collision.resize(voxel_count)

	var generator = VoxelPlacementGeneratorScript.new()
	for z in range(grid_size.z):
		for x in range(grid_size.x):
			scene[generator.voxel_index(Vector3i(x, 0, z), grid_size)] = 1.0

	var target := PackedFloat32Array()
	target.resize(voxel_count)
	for z in range(4, 12):
		for x in range(4, 12):
			target[generator.voxel_index(Vector3i(x, 0, z), grid_size)] = 0.8
			target[generator.voxel_index(Vector3i(x, 1, z), grid_size)] = 0.6

	var target_color := PackedColorArray()
	target_color.resize(voxel_count)
	for z in range(4, 12):
		for x in range(4, 12):
			target_color[generator.voxel_index(Vector3i(x, 0, z), grid_size)] = Color(0.2, 0.6, 0.1, 1.0)
			target_color[generator.voxel_index(Vector3i(x, 1, z), grid_size)] = Color(0.2, 0.6, 0.1, 1.0)

	var footprint: Array[Dictionary] = [
		{"local_pos": Vector3i(0, 0, 0), "collision_strength": 0.25, "flags": FLAG_SUPPORT, "weight": 1.0},
		{"local_pos": Vector3i(0, 1, 0), "collision_strength": 1.0, "flags": 0, "weight": 1.0},
		{"local_pos": Vector3i(0, 2, 0), "collision_strength": 0.0, "flags": FLAG_CLEARANCE, "weight": 1.0},
	]

	var settings := {
		"top_k": 4,
		"result_capacity": 4,
		"min_distance_voxels": 2.0,
		"collision_limit": 0.0,
		"min_support_ratio": 1.0,
		"clearance_limit": 0.0,
		"target_occupancy_bytes": target.to_byte_array(),
		"target_color_rgba8_bytes": _pack_target_color_rgba8(target_color),
		"asset_color": Color(0.3, 0.7, 0.2, 1.0),
		"read_debug_voxel": true,
	}

	var out := generator.run_minimal(scene, collision, footprint, grid_size, settings)
	if _is_missing_rendering_device_skip(out):
		print("[TargetDebugTest] SKIP: no RenderingDevice available for GPU-only target debug channels")
		quit(0)
		return
	if out.is_empty():
		push_error("[TargetDebugTest] run_minimal returned empty")
		quit(1)
		return

	# --- verify debug_voxel is present and correctly sized ---
	var debug_voxel: PackedFloat32Array = out.get("debug_voxel", PackedFloat32Array())
	var expected_size := voxel_count * VoxelPlacementGeneratorScript.NUM_DEBUG_CHANNELS
	if debug_voxel.size() != expected_size:
		push_error("[TargetDebugTest] debug_voxel size mismatch: got %d, expected %d" % [debug_voxel.size(), expected_size])
		quit(1)
		return
	if str(out.get("debug_voxel_readback_source", "")) != "score_shader_debug_voxel_buffer":
		push_error("[TargetDebugTest] debug_voxel readback source mismatch: %s" % str(out.get("debug_voxel_readback_source", "")))
		quit(1)
		return
	print("[TargetDebugTest] debug_voxel size OK: %d" % debug_voxel.size())

	# --- verify channel names ---
	var names: PackedStringArray = out.get("debug_channel_names", PackedStringArray())
	if names.size() != VoxelPlacementGeneratorScript.NUM_DEBUG_CHANNELS:
		push_error("[TargetDebugTest] channel names count mismatch")
		quit(1)
		return
	print("[TargetDebugTest] channel names: %s" % str(names))
	var gpu_debug_max: PackedFloat32Array = out.get("debug_channel_max", PackedFloat32Array())
	if gpu_debug_max.size() != VoxelPlacementGeneratorScript.NUM_DEBUG_CHANNELS:
		push_error("[TargetDebugTest] GPU debug_channel_max size mismatch: got %d" % gpu_debug_max.size())
		quit(1)
		return
	if str(out.get("debug_channel_max_source", "")) != "score_shader_storage_buffer":
		push_error("[TargetDebugTest] GPU debug_channel_max source mismatch: %s" % str(out.get("debug_channel_max_source", "")))
		quit(1)
		return

	# --- extract each channel and check non-zero values exist inside target region ---
	for ch in range(VoxelPlacementGeneratorScript.NUM_DEBUG_CHANNELS):
		var channel_data := VoxelPlacementGeneratorScript.get_debug_channel(debug_voxel, ch, voxel_count)
		if channel_data.size() != voxel_count:
			push_error("[TargetDebugTest] channel %d size mismatch" % ch)
			quit(1)
			return
		var max_val := 0.0
		var positive_max := 0.0
		for i in range(channel_data.size()):
			max_val = maxf(max_val, absf(channel_data[i]))
			positive_max = maxf(positive_max, clampf(channel_data[i], 0.0, 1.0))
		if absf(gpu_debug_max[ch] - positive_max) > 0.002:
			push_error("[TargetDebugTest] GPU debug max mismatch for ch %d: got %.4f expected %.4f" % [ch, gpu_debug_max[ch], positive_max])
			quit(1)
			return
		print("[TargetDebugTest] ch %d (%s): max=%.4f gpu_max=%.4f" % [ch, names[ch], max_val, gpu_debug_max[ch]])

	# --- verify target_coverage > 0 for a voxel inside the target region ---
	var coverage_ch := VoxelPlacementGeneratorScript.get_debug_channel(debug_voxel, 0, voxel_count)
	var center_idx := generator.voxel_index(Vector3i(8, 0, 8), grid_size)
	if coverage_ch[center_idx] <= 0.0:
		push_error("[TargetDebugTest] target_coverage at center (8,0,8) should be > 0, got %.4f" % coverage_ch[center_idx])
		quit(1)
		return
	print("[TargetDebugTest] target_coverage at center: %.4f" % coverage_ch[center_idx])

	# --- verify placement_score > 0 for at least one voxel ---
	var score_ch := VoxelPlacementGeneratorScript.get_debug_channel(debug_voxel, 4, voxel_count)
	var any_positive := false
	for i in range(score_ch.size()):
		if score_ch[i] > 0.0:
			any_positive = true
			break
	if not any_positive:
		push_error("[TargetDebugTest] No voxel has placement_score > 0")
		quit(1)
		return
	print("[TargetDebugTest] placement_score has positive values")

	for z in range(grid_size.z):
		for y in range(grid_size.y):
			for x in range(grid_size.x):
				var p := Vector3i(x, y, z)
				var idx := generator.voxel_index(p, grid_size)
				if target[idx] <= 0.01 and score_ch[idx] > 0.0:
					push_error("[TargetDebugTest] placement_score outside target should be 0 at %s, got %.4f" % [str(p), score_ch[idx]])
					quit(1)
					return
	print("[TargetDebugTest] target zero-complexity voxels are excluded")

	# --- run without target to ensure debug buffer still works (all target channels ~0) ---
	var no_target_settings := settings.duplicate(true)
	no_target_settings.erase("target_occupancy_bytes")
	no_target_settings.erase("target_color_rgba8_bytes")
	var out2 := generator.run_minimal(scene, collision, footprint, grid_size, no_target_settings)
	var debug2: PackedFloat32Array = out2.get("debug_voxel", PackedFloat32Array())
	var coverage2 := VoxelPlacementGeneratorScript.get_debug_channel(debug2, 0, voxel_count)
	var max_coverage2 := 0.0
	for i in range(coverage2.size()):
		max_coverage2 = maxf(max_coverage2, absf(coverage2[i]))
	if max_coverage2 > 0.001:
		push_error("[TargetDebugTest] target_coverage should be ~0 without target, got max=%.4f" % max_coverage2)
		quit(1)
		return
	print("[TargetDebugTest] no-target run: target_coverage max=%.4f (expected ~0)" % max_coverage2)

	print("[TargetDebugTest] ALL TESTS PASSED")
	quit(0)


func _pack_target_color_rgba8(colors: PackedColorArray) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(colors.size() * 4)
	for i in range(colors.size()):
		bytes.encode_u32(i * 4, VoxelPlacementGeneratorScript._pack_color_rgba8(colors[i]))
	return bytes


func _is_missing_rendering_device_skip(result: Dictionary) -> bool:
	if not bool(result.get("contract_blocked", false)):
		return false
	var contract: Dictionary = result.get("gpu_runtime_profile_contract", {})
	if str(contract.get("reason", "")) != "missing_rendering_device":
		return false
	if bool(result.get("cpu_fallback", true)):
		push_error("[TargetDebugTest] GPU blocked path must not enable CPU fallback")
		return false
	if str(result.get("readback_source", "")) != "none":
		push_error("[TargetDebugTest] GPU blocked path must not expose readback_source")
		return false
	return true
