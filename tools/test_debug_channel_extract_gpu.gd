extends SceneTree

const VoxelPlacementGeneratorScript := preload("res://scripts/voxel_placement_generator.gd")


func _init() -> void:
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		print("[DebugChannelGpuTest] SKIP: no RenderingDevice available for GPU debug channel extraction")
		quit(0)
		return
	rd.free()

	var voxel_count := 17
	var debug_voxel := PackedFloat32Array()
	debug_voxel.resize(voxel_count * VoxelPlacementGeneratorScript.NUM_DEBUG_CHANNELS)
	for voxel_idx in range(voxel_count):
		for channel_idx in range(VoxelPlacementGeneratorScript.NUM_DEBUG_CHANNELS):
			debug_voxel[voxel_idx * VoxelPlacementGeneratorScript.NUM_DEBUG_CHANNELS + channel_idx] = float(voxel_idx * 10 + channel_idx) / 7.0

	var channel := 5
	var expected := VoxelPlacementGeneratorScript.get_debug_channel(debug_voxel, channel, voxel_count)
	var generator := VoxelPlacementGeneratorScript.new()
	var gpu := generator.get_debug_channel_gpu(debug_voxel, channel, voxel_count)
	if not bool(gpu.get("ok", false)):
		push_error("[DebugChannelGpuTest] GPU channel extraction failed: %s" % str(gpu))
		quit(1)
		return
	if bool(gpu.get("cpu_fallback", true)):
		push_error("[DebugChannelGpuTest] GPU channel extraction must not report CPU fallback")
		quit(1)
		return
	if str(gpu.get("readback_source", "")) != "extract_debug_voxel_channel_compute":
		push_error("[DebugChannelGpuTest] unexpected readback source: %s" % str(gpu.get("readback_source", "")))
		quit(1)
		return
	if int(gpu.get("channel_stride", -1)) != VoxelPlacementGeneratorScript.NUM_DEBUG_CHANNELS:
		push_error("[DebugChannelGpuTest] channel stride mismatch")
		quit(1)
		return
	if int(gpu.get("local_size_x", 0)) != 64 or int(gpu.get("dispatch_groups_x", 0)) != 1:
		push_error("[DebugChannelGpuTest] dispatch metadata mismatch: %s" % str(gpu))
		quit(1)
		return

	var actual: PackedFloat32Array = gpu.get("debug_channel", PackedFloat32Array())
	if actual.size() != expected.size():
		push_error("[DebugChannelGpuTest] output size mismatch: got %d expected %d" % [actual.size(), expected.size()])
		quit(1)
		return
	for i in range(voxel_count):
		if absf(actual[i] - expected[i]) > 0.0001:
			push_error("[DebugChannelGpuTest] output mismatch at %d: got %.6f expected %.6f" % [i, actual[i], expected[i]])
			quit(1)
			return

	var invalid := generator.get_debug_channel_gpu(debug_voxel, -1, voxel_count)
	if bool(invalid.get("ok", true)) or str(invalid.get("reason", "")) != "debug_channel_out_of_range":
		push_error("[DebugChannelGpuTest] invalid channel should be rejected explicitly: %s" % str(invalid))
		quit(1)
		return
	if bool(invalid.get("cpu_fallback", true)):
		push_error("[DebugChannelGpuTest] invalid channel path must not report CPU fallback")
		quit(1)
		return

	print("[DebugChannelGpuTest] ALL TESTS PASSED")
	quit(0)
