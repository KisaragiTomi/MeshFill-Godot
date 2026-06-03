extends RefCounted

const SceneVoxelPayloadScript := preload("res://scripts/scene_voxel_payload.gd")
const ComputeShaderBaseScript := preload("res://scripts/godot_compute_shader_base.gd")

static func validate_volume(volume: Dictionary, params: Dictionary, channel_count: int, occupied_epsilon: float) -> Dictionary:
	if volume.is_empty():
		return {"passed": false, "reason": "No voxel volume built", "metrics": {}}

	var min_channel_occupancy: Dictionary = params.get("min_channel_occupancy", {})
	var max_channel_occupancy: Dictionary = params.get("max_channel_occupancy", {})
	var min_diversity: int = params.get("min_diversity_score", 2)
	var channel_occ: Array[float] = []
	var xz_res: int = volume.xz_res
	var slices: Array = volume.slices
	var meta: Array = volume.slice_meta
	var scene_voxels: Dictionary = volume.get("scene_voxels", {})
	var channel_counts: Array[int] = []
	var channel_totals: Array[int] = []
	var gpu_dispatched := false
	var stats_source := "scene_voxel_payload_map"

	for _i in range(channel_count):
		channel_counts.append(0)
		channel_totals.append(0)

	for i in range(slices.size()):
		var m: Dictionary = meta[i]
		var ch: int = int(m.channel)
		var total := xz_res * xz_res
		if ch >= 0 and ch < channel_totals.size():
			channel_totals[ch] += total

	if not scene_voxels.is_empty():
		for key in scene_voxels.keys():
			var scene_voxel = scene_voxels[key]
			if not scene_voxel is Dictionary:
				continue
			var voxel := scene_voxel as Dictionary
			if not SceneVoxelPayloadScript.voxel_is_occupied(voxel, occupied_epsilon):
				continue

			var slice_index := int(voxel.get("slice_index", -1))
			if slice_index < 0 or slice_index >= meta.size():
				continue
			var slice_meta: Dictionary = meta[slice_index]
			var channel := int(slice_meta.get("channel", -1))
			if channel >= 0 and channel < channel_counts.size():
				channel_counts[channel] += 1
	else:
		var gpu_counts := _count_slice_image_occupancy_gpu(slices, meta, channel_count, occupied_epsilon)
		if not bool(gpu_counts.get("valid", false)):
			return {
				"passed": false,
				"reason": "SceneVoxel validation GPU occupancy count failed",
				"metrics": {
					"gpu_dispatched": false,
					"cpu_fallback": false,
				},
			}
		var raw_counts: Array = gpu_counts.get("channel_counts", [])
		for i in range(mini(channel_counts.size(), raw_counts.size())):
			channel_counts[i] = int(raw_counts[i])
		gpu_dispatched = true
		stats_source = "volume_slice_texture"

	for ch in range(channel_count):
		var pct := float(channel_counts[ch]) / float(channel_totals[ch]) * 100.0 if channel_totals[ch] > 0 else 0.0
		channel_occ.append(pct)

	var diversity := 0
	for pct in channel_occ:
		if pct > 1.0:
			diversity += 1

	var metrics := {
		"channel_occupancy_pct": channel_occ,
		"channels": range(channel_count),
		"diversity_score": diversity,
		"gpu_dispatched": gpu_dispatched,
		"cpu_fallback": false,
		"stats_source": stats_source,
	}

	for raw_channel in min_channel_occupancy.keys():
		var ch := int(raw_channel)
		var min_occ := float(min_channel_occupancy[raw_channel])
		var occ := channel_occ[ch] if ch >= 0 and ch < channel_occ.size() else 0.0
		if occ < min_occ:
			return {"passed": false, "reason": "Channel %d occupancy too low: %.1f%% < %.1f%%" % [ch, occ, min_occ], "metrics": metrics}

	for raw_channel in max_channel_occupancy.keys():
		var ch := int(raw_channel)
		var max_occ := float(max_channel_occupancy[raw_channel])
		var occ := channel_occ[ch] if ch >= 0 and ch < channel_occ.size() else 0.0
		if occ > max_occ:
			return {"passed": false, "reason": "Channel %d occupancy too high: %.1f%% > %.1f%%" % [ch, occ, max_occ], "metrics": metrics}

	if diversity < min_diversity:
		return {"passed": false, "reason": "Diversity too low: %d < %d channels active" % [diversity, min_diversity], "metrics": metrics}

	return {"passed": true, "reason": "OK", "metrics": metrics}


static func _count_slice_image_occupancy_gpu(slices: Array, meta: Array, channel_count: int, occupied_epsilon: float) -> Dictionary:
	var channel_counts: Array[int] = []
	for _i in range(channel_count):
		channel_counts.append(0)

	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		return {}
	probe_rd.free()

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "SceneVoxelValidationOccupancy"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return {}
	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader("res://shaders/mask_has_pixels.glsl")
	var pipeline := compute.create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return {}

	var sampler := compute.create_linear_sampler(ComputeShaderBaseScript.SCOPE_PERSISTENT, "scene_voxel_validation_sampler")
	if not sampler.is_valid():
		compute.dispose()
		return {}

	for i in range(slices.size()):
		if i >= meta.size() or not meta[i] is Dictionary:
			continue
		var m: Dictionary = meta[i]
		var ch := int(m.get("channel", -1))
		if ch < 0 or ch >= channel_counts.size():
			continue
		var raw_img = slices[i]
		if not raw_img is Image:
			continue
		var img := raw_img as Image
		if img == null or img.is_empty():
			continue

		var mask_tex := compute.upload_texture_2d(
			img,
			RenderingDevice.DATA_FORMAT_R32_SFLOAT,
			Image.FORMAT_RF,
			RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
			ComputeShaderBaseScript.SCOPE_FRAME,
			"scene_voxel_validation_mask_r32f"
		)
		var counter_bytes := PackedByteArray()
		counter_bytes.resize(4)
		counter_bytes.encode_u32(0, 0)
		var counter_buf := compute.storage_buffer_from_bytes(
			counter_bytes,
			ComputeShaderBaseScript.SCOPE_FRAME,
			"scene_voxel_validation_hit_count_u32"
		)
		if not mask_tex.is_valid() or not counter_buf.is_valid():
			compute.dispose()
			return {}

		var set0 := compute.create_uniform_set([
			compute.make_sampler_uniform(0, sampler, mask_tex),
		], shader, 0)
		var set1 := compute.create_uniform_set([
			compute.make_storage_uniform(0, counter_buf),
		], shader, 1)
		if not set0.is_valid() or not set1.is_valid():
			compute.dispose()
			return {}

		var push := PackedByteArray()
		push.resize(16)
		push.encode_s32(0, img.get_width())
		push.encode_s32(4, img.get_height())
		push.encode_float(8, occupied_epsilon)
		push.encode_float(12, 0.0)

		var groups_x := ceili(float(img.get_width()) / 32.0)
		var groups_y := ceili(float(img.get_height()) / 32.0)
		var cl := compute.begin_compute_list()
		if cl < 0:
			compute.dispose()
			return {}
		rd.compute_list_bind_compute_pipeline(cl, pipeline)
		rd.compute_list_bind_uniform_set(cl, set0, 0)
		rd.compute_list_bind_uniform_set(cl, set1, 1)
		rd.compute_list_set_push_constant(cl, push, push.size())
		rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
		compute.end_compute_list()
		compute.submit_and_sync()

		var data := rd.buffer_get_data(counter_buf, 0, 4)
		if data.size() < 4:
			compute.dispose()
			return {}
		channel_counts[ch] += int(data.decode_u32(0))
		compute.gc_frame()

	compute.dispose()
	return {
		"valid": true,
		"channel_counts": channel_counts,
	}


static func voxel_column(volume: Dictionary, px: int, pz: int) -> Array[Dictionary]:
	var column: Array[Dictionary] = []
	if volume.is_empty():
		return column

	var xz_res: int = volume.xz_res
	px = clampi(px, 0, xz_res - 1)
	pz = clampi(pz, 0, xz_res - 1)
	var slices: Array = volume.slices
	var meta: Array = volume.slice_meta

	for i in range(slices.size()):
		var m: Dictionary = meta[i]
		column.append({
			"slice": i,
			"channel": int(m.channel),
			"y_min": m.y_min,
			"y_max": m.y_max,
			"color": m.color,
			"complexity": m.complexity,
		})

	return column
