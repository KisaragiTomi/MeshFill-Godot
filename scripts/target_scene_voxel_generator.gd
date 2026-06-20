class_name TargetSceneVoxelGenerator
extends "res://scripts/godot_compute_shader_base.gd"

const TARGET_STATS_BYTE_SIZE := 28
const TARGET_STATS_QUANT_SCALE := 1000000.0
const TARGET_STATS_MIN_PACK_BASE := 1000001.0
const TARGET_STATS_ACTIVE_THRESHOLD := 0.001
const TARGET_STATS_MAX_COMPLETELY_OFFSET := 0
const TARGET_STATS_MAX_COLLISION_OFFSET := 4
const TARGET_STATS_ACTIVE_COUNT_OFFSET := 8
const TARGET_STATS_COLLISION_COUNT_OFFSET := 12
const TARGET_STATS_VISUAL_COUNT_OFFSET := 16
const TARGET_STATS_MIN_ACTIVE_PACKED_OFFSET := 20
const TARGET_STATS_MAX_VISUAL_OFFSET := 24
const TARGET_PACK_PUSH_BYTE_SIZE := 16
const TARGET_PACK_PUSH_VOXEL_COUNT_OFFSET := 0
const TARGET_PACK_PUSH_USE_COLLISION_OFFSET := 4  # set to 1 to derive completely from max(complexity, collision) when no completely input
const TARGET_PACK_PUSH_COMPLETELY_VALID_OFFSET := 8  # set to 1 if binding 2 has valid completely input per voxel
const TARGET_PACK_PUSH_WRITE_PACKED_OFFSET := 12
const TARGET_GENERATE_PUSH_BYTE_SIZE := 48
const TARGET_GENERATE_PUSH_MAX_HEIGHT_OFFSET := 0
const TARGET_GENERATE_PUSH_CAPTURE_SIZE_OFFSET := 4
const TARGET_GENERATE_PUSH_VERTICAL_SPAN_OFFSET := 8
const TARGET_GENERATE_PUSH_SLOPE_START_OFFSET := 12
const TARGET_GENERATE_PUSH_SLOPE_FULL_OFFSET := 16
const TARGET_GENERATE_PUSH_TEXTURE_SIZE_OFFSET := 20
const TARGET_GENERATE_PUSH_SLICE_COUNT_OFFSET := 24
const TARGET_GENERATE_PUSH_DIRTY_X_OFFSET := 28
const TARGET_GENERATE_PUSH_DIRTY_Y_OFFSET := 32
const TARGET_GENERATE_PUSH_DIRTY_W_OFFSET := 36
const TARGET_GENERATE_PUSH_DIRTY_H_OFFSET := 40
const TARGET_GENERATE_PUSH_PAD0_OFFSET := 44

const TerrainConfigScript := preload("res://scripts/terrain_config.gd")

var texture_size: int = 256      # TargetSV XZ 分辨率
var slice_count: int = 8         # TargetSV 纵向切片数
var max_height: float = TerrainConfigScript.MAX_HEIGHT    # 目标高度解码上限 (规范真值源)
var capture_size: float = TerrainConfigScript.CAPTURE_SIZE  # 俯视捕获场景范围 (规范真值源)
var vertical_span: float = 16.0  # 写入 3D flat buffer 的高度跨度
var slope_start: float = 0.35
var slope_full: float = 0.8

var _shader: RID
var _pipeline: RID
var _shader_pack: RID
var _pipeline_pack: RID
var _sampler: RID


static func _decode_target_stats(stats_bytes: PackedByteArray) -> Dictionary:
	if stats_bytes.size() < TARGET_STATS_BYTE_SIZE:
		return {
			"max_completely": 0.0,
			"max_collision": 0.0,
			"active_voxel_count": 0,
			"collision_voxel_count": 0,
			"visual_voxel_count": 0,
			"min_active_completely": 0.0,
			"max_visual_complexity": 0.0,
		}
	var min_active_packed := stats_bytes.decode_u32(TARGET_STATS_MIN_ACTIVE_PACKED_OFFSET)
	return {
		"max_completely": float(stats_bytes.decode_u32(TARGET_STATS_MAX_COMPLETELY_OFFSET)) / TARGET_STATS_QUANT_SCALE,
		"max_collision": float(stats_bytes.decode_u32(TARGET_STATS_MAX_COLLISION_OFFSET)) / TARGET_STATS_QUANT_SCALE,
		"active_voxel_count": int(stats_bytes.decode_u32(TARGET_STATS_ACTIVE_COUNT_OFFSET)),
		"collision_voxel_count": int(stats_bytes.decode_u32(TARGET_STATS_COLLISION_COUNT_OFFSET)),
		"visual_voxel_count": int(stats_bytes.decode_u32(TARGET_STATS_VISUAL_COUNT_OFFSET)),
		"min_active_completely": (TARGET_STATS_MIN_PACK_BASE - float(min_active_packed)) / TARGET_STATS_QUANT_SCALE if min_active_packed > 0 else 0.0,
		"max_visual_complexity": float(stats_bytes.decode_u32(TARGET_STATS_MAX_VISUAL_OFFSET)) / TARGET_STATS_QUANT_SCALE,
	}


static func decode_target_read_buffers(
	visual_bytes: PackedByteArray,
	collision_bytes: PackedByteArray,
	texture_size: int,
	slice_count: int,
	use_collision_as_completely: bool = true,
	completely_bytes: PackedByteArray = PackedByteArray()
) -> Dictionary:
	var tex_size := maxi(texture_size, 1)
	var slices := maxi(slice_count, 1)
	var voxel_count := tex_size * tex_size * slices
	var expected_visual_bytes := voxel_count * 16
	var expected_collision_bytes := voxel_count * 4
	var target_completely := PackedFloat32Array()
	var target_color := PackedColorArray()
	target_completely.resize(voxel_count)
	target_color.resize(voxel_count)
	var visual_valid := visual_bytes.size() >= expected_visual_bytes
	var collision_valid := collision_bytes.size() >= expected_collision_bytes
	var completely_valid := use_collision_as_completely and completely_bytes.size() >= expected_collision_bytes
	if not visual_valid and not collision_valid:
		return {
			"valid": false,
			"reason": "target_buffer_size_mismatch",
			"texture_size": tex_size,
			"slice_count": slices,
			"voxel_count": voxel_count,
			"expected_visual_bytes": expected_visual_bytes,
			"actual_visual_bytes": visual_bytes.size(),
			"expected_collision_bytes": expected_collision_bytes,
			"actual_collision_bytes": collision_bytes.size(),
			"target_completely": target_completely,
			"target_color": target_color,
		}

	var max_completely := 0.0
	var max_collision := 0.0
	var active_voxel_count := 0
	var collision_voxel_count := 0
	var visual_voxel_count := 0
	var min_active_completely := 0.0
	var max_visual_complexity := 0.0
	for i in range(voxel_count):
		var r := 0.0
		var g := 0.0
		var b := 0.0
		var complexity := 0.0
		if visual_valid:
			var visual_offset := i * 16
			r = visual_bytes.decode_float(visual_offset + 0)
			g = visual_bytes.decode_float(visual_offset + 4)
			b = visual_bytes.decode_float(visual_offset + 8)
			complexity = visual_bytes.decode_float(visual_offset + 12)
		var collision := 0.0
		var scalar_offset := i * 4
		if collision_valid:
			collision = collision_bytes.decode_float(scalar_offset)
		complexity = clampf(complexity, 0.0, 1.0)
		collision = clampf(collision, 0.0, 1.0)
		var completely := complexity
		if completely_valid:
			completely = clampf(completely_bytes.decode_float(scalar_offset), 0.0, 1.0)
		elif use_collision_as_completely:
			completely = maxf(complexity, collision)
		target_completely[i] = completely
		target_color[i] = Color(
			clampf(r, 0.0, 1.0),
			clampf(g, 0.0, 1.0),
			clampf(b, 0.0, 1.0),
			complexity
		)
		max_completely = maxf(max_completely, completely)
		max_collision = maxf(max_collision, collision)
		max_visual_complexity = maxf(max_visual_complexity, complexity)
		if completely > TARGET_STATS_ACTIVE_THRESHOLD:
			active_voxel_count += 1
			min_active_completely = completely if active_voxel_count == 1 else minf(min_active_completely, completely)
		if collision > TARGET_STATS_ACTIVE_THRESHOLD:
			collision_voxel_count += 1
		if complexity > TARGET_STATS_ACTIVE_THRESHOLD:
			visual_voxel_count += 1

	return {
		"valid": visual_valid and collision_valid,
		"partial": not (visual_valid and collision_valid),
		"reason": "" if visual_valid and collision_valid else "target_buffer_partial",
		"texture_size": tex_size,
		"slice_count": slices,
		"voxel_count": voxel_count,
		"expected_visual_bytes": expected_visual_bytes,
		"actual_visual_bytes": visual_bytes.size(),
		"expected_collision_bytes": expected_collision_bytes,
		"actual_collision_bytes": collision_bytes.size(),
		"target_completely": target_completely,
		"target_color": target_color,
		"max_completely": max_completely,
		"max_collision": max_collision,
		"active_voxel_count": active_voxel_count,
		"collision_voxel_count": collision_voxel_count,
		"visual_voxel_count": visual_voxel_count,
		"min_active_completely": min_active_completely,
		"max_visual_complexity": max_visual_complexity,
		"target_completely_source": "gpu_target_completely_buffer" if completely_valid else "decoded_visual_collision",
	}


static func decode_target_read_buffers_gpu(
	visual_bytes: PackedByteArray,
	collision_bytes: PackedByteArray,
	texture_size: int,
	slice_count: int,
	use_collision_as_completely: bool = true,
	completely_bytes: PackedByteArray = PackedByteArray()
) -> Dictionary:
	# GPU-only TargetSV_B decode for placement/readback buffers.
	# Buffer layout: visual is RGBA32F (16 bytes/voxel), collision and completely are R32F
	# (4 bytes/voxel), placement color is RGBA8 u32 (4 bytes/voxel), and legacy
	# color-array decode reads GPU-clamped RGBA32F (16 bytes/voxel).
	var tex_size := maxi(texture_size, 1)
	var slices := maxi(slice_count, 1)
	var voxel_count := tex_size * tex_size * slices
	var expected_visual_bytes := voxel_count * 16
	var expected_collision_bytes := voxel_count * 4
	var target_completely := PackedFloat32Array()
	var target_color := PackedColorArray()
	target_completely.resize(voxel_count)
	target_color.resize(voxel_count)
	var visual_valid := visual_bytes.size() >= expected_visual_bytes
	var collision_valid := collision_bytes.size() >= expected_collision_bytes
	if not visual_valid and not collision_valid:
		return {
			"valid": false,
			"reason": "target_buffer_size_mismatch",
			"gpu_first": true,
			"cpu_fallback": false,
			"texture_size": tex_size,
			"slice_count": slices,
			"voxel_count": voxel_count,
			"expected_visual_bytes": expected_visual_bytes,
			"actual_visual_bytes": visual_bytes.size(),
			"expected_collision_bytes": expected_collision_bytes,
			"actual_collision_bytes": collision_bytes.size(),
			"target_completely": target_completely,
			"target_color": target_color,
		}

	var generator := TargetSceneVoxelGenerator.new()
	var packed := generator.derive_target_packed_buffers(
		visual_bytes,
		collision_bytes,
		tex_size,
		slices,
		use_collision_as_completely,
		completely_bytes,
		true
	)
	if not bool(packed.get("ok", false)):
		packed["valid"] = false
		packed["target_completely"] = target_completely
		packed["target_color"] = target_color
		return packed

	var completely_out: PackedByteArray = packed.get("target_completely_bytes", PackedByteArray())
	var color_out: PackedByteArray = packed.get("target_color_rgba32f_bytes", PackedByteArray())
	if completely_out.size() < expected_collision_bytes or color_out.size() < expected_visual_bytes:
		packed["valid"] = false
		packed["reason"] = "target_gpu_readback_size_mismatch"
		packed["target_completely"] = target_completely
		packed["target_color"] = target_color
		return packed

	target_completely = completely_out.slice(0, expected_collision_bytes).to_float32_array()
	var color_values := color_out.slice(0, expected_visual_bytes).to_float32_array()
	target_color.resize(voxel_count)
	for i in range(voxel_count):
		var color_base := i * 4
		target_color[i] = Color(
			color_values[color_base + 0],
			color_values[color_base + 1],
			color_values[color_base + 2],
			color_values[color_base + 3]
		)

	packed["valid"] = visual_valid and collision_valid
	packed["partial"] = not (visual_valid and collision_valid)
	packed["reason"] = "ok" if visual_valid and collision_valid else "target_buffer_partial"
	packed["target_completely"] = target_completely
	packed["target_color"] = target_color
	packed["decode_source"] = "target_sv_pack_read_buffers_compute"
	packed["target_color_decode_format"] = "rgba32f_storage_buffer"
	packed["target_color_stride_bytes"] = 16
	packed["target_completely_stride_bytes"] = 4
	return packed


static func _rgba8_word_to_color(word: int) -> Color:
	var rgba8 := word & 0xFFFFFFFF
	return Color(
		float((rgba8 >> 24) & 0xFF) / 255.0,
		float((rgba8 >> 16) & 0xFF) / 255.0,
		float((rgba8 >> 8) & 0xFF) / 255.0,
		float(rgba8 & 0xFF) / 255.0
	)


func derive_target_packed_buffers(
	visual_bytes: PackedByteArray,
	collision_bytes: PackedByteArray,
	texture_size: int,
	slice_count: int,
	use_collision_as_completely: bool = true,
	completely_bytes: PackedByteArray = PackedByteArray(),
	readback_packed_buffers: bool = true
) -> Dictionary:
	var tex_size := maxi(texture_size, 1)
	var slices := maxi(slice_count, 1)
	var voxel_count := tex_size * tex_size * slices
	var expected_visual_bytes := voxel_count * 16
	var expected_collision_bytes := voxel_count * 4
	var visual_valid := visual_bytes.size() >= expected_visual_bytes
	var collision_valid := collision_bytes.size() >= expected_collision_bytes
	if not visual_valid and not collision_valid:
		return {
			"ok": false,
			"reason": "target_buffer_size_mismatch",
			"gpu_first": true,
			"cpu_fallback": false,
			"voxel_count": voxel_count,
			"expected_visual_bytes": expected_visual_bytes,
			"actual_visual_bytes": visual_bytes.size(),
			"expected_collision_bytes": expected_collision_bytes,
			"actual_collision_bytes": collision_bytes.size(),
		}

	log_name = "TargetSceneVoxelGenerator"
	sync_global_device = true
	if not ensure_device(true, true):
		return {
			"ok": false,
			"reason": "missing_rendering_device",
			"gpu_first": true,
			"cpu_fallback": false,
			"voxel_count": voxel_count,
		}

	_load_pack_shader()
	if not _shader_pack.is_valid() or not _pipeline_pack.is_valid():
		_free_gpu()
		return {
			"ok": false,
			"reason": "target_pack_shader_not_ready",
			"gpu_first": true,
			"cpu_fallback": false,
			"voxel_count": voxel_count,
	}

	var completely_valid := use_collision_as_completely and completely_bytes.size() >= expected_collision_bytes
	# Partial TargetSV_B decode stays GPU-only: missing visual/collision input is a full-size zero SSBO.
	# Shader input layout is visual RGBA32F, 16 bytes/voxel, and collision R32F, 4 bytes/voxel.
	var visual_buffer := storage_buffer_from_bytes(
		visual_bytes.slice(0, expected_visual_bytes),
		SCOPE_FRAME,
		"target_visual_rgba32f"
	) if visual_valid else storage_buffer_zero(expected_visual_bytes, SCOPE_FRAME, "target_visual_zero_rgba32f")
	var collision_buffer := storage_buffer_from_bytes(
		collision_bytes.slice(0, expected_collision_bytes),
		SCOPE_FRAME,
		"target_collision_r32f"
	) if collision_valid else storage_buffer_zero(expected_collision_bytes, SCOPE_FRAME, "target_collision_zero_r32f")
	var completely_input_buffer := storage_buffer_from_bytes(
		completely_bytes.slice(0, expected_collision_bytes),
		SCOPE_FRAME,
		"target_completely_input_r32f"
	) if completely_valid else storage_buffer_zero(4, SCOPE_FRAME, "target_completely_input_r32f")
	var completely_out_buffer := storage_buffer_zero(
		expected_collision_bytes if readback_packed_buffers else 4,
		SCOPE_FRAME,
		"target_completely_out_r32f"
	)
	var color_rgba8_out_buffer := storage_buffer_zero(
		voxel_count * 4 if readback_packed_buffers else 4,
		SCOPE_FRAME,
		"target_color_rgba8_out"
	)
	var color_rgba32f_out_buffer := storage_buffer_zero(
		expected_visual_bytes if readback_packed_buffers else 16,
		SCOPE_FRAME,
		"target_color_rgba32f_out"
	)
	var stats_out_buffer := storage_buffer_zero(TARGET_STATS_BYTE_SIZE, SCOPE_FRAME, "target_pack_stats_u32")

	var set0 := create_uniform_set([
		make_storage_uniform(0, visual_buffer),
		make_storage_uniform(1, collision_buffer),
		make_storage_uniform(2, completely_input_buffer),
		make_storage_uniform(3, completely_out_buffer),
		make_storage_uniform(4, color_rgba8_out_buffer),
		make_storage_uniform(5, stats_out_buffer),
		make_storage_uniform(6, color_rgba32f_out_buffer),
	], _shader_pack, 0)

	var push := PackedByteArray()
	push.resize(TARGET_PACK_PUSH_BYTE_SIZE)
	push.encode_s32(TARGET_PACK_PUSH_VOXEL_COUNT_OFFSET, voxel_count)
	push.encode_s32(TARGET_PACK_PUSH_USE_COLLISION_OFFSET, 1 if use_collision_as_completely else 0)
	push.encode_s32(TARGET_PACK_PUSH_COMPLETELY_VALID_OFFSET, 1 if completely_valid else 0)
	push.encode_s32(TARGET_PACK_PUSH_WRITE_PACKED_OFFSET, 1 if readback_packed_buffers else 0)

	var groups := ceili(float(voxel_count) / 64.0)
	var cl := begin_compute_list()
	if cl < 0:
		_free_gpu()
		return {
			"ok": false,
			"reason": "target_pack_compute_list_begin_failed",
			"gpu_first": true,
			"cpu_fallback": false,
			"voxel_count": voxel_count,
			"texture_size": tex_size,
			"slice_count": slices,
		}
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline_pack)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	end_compute_list()
	submit_and_sync(true)

	var packed_completely := PackedByteArray()
	var packed_color := PackedByteArray()
	var decoded_color := PackedByteArray()
	if readback_packed_buffers:
		packed_completely = _rd.buffer_get_data(completely_out_buffer, 0, expected_collision_bytes)
		packed_color = _rd.buffer_get_data(color_rgba8_out_buffer, 0, voxel_count * 4)
		decoded_color = _rd.buffer_get_data(color_rgba32f_out_buffer, 0, expected_visual_bytes)
	var stats_bytes := _rd.buffer_get_data(stats_out_buffer, 0, TARGET_STATS_BYTE_SIZE)
	var stats := _decode_target_stats(stats_bytes)
	_free_gpu()

	return {
		"ok": true,
		"reason": "ok",
		"gpu_first": true,
		"cpu_fallback": false,
		"voxel_count": voxel_count,
		"texture_size": tex_size,
		"slice_count": slices,
		"partial": not (visual_valid and collision_valid),
		"dispatch_local_size": 64,
		"dispatch_groups": Vector3i(groups, 1, 1),
		"readback_packed_buffers": readback_packed_buffers,
		"write_packed_buffers": readback_packed_buffers,
		"completely_format": "r32f",
		"target_color_format": "rgba8_u32",
		"target_color_decode_format": "rgba32f_storage_buffer",
		"visual_buffer_source": "visual_bytes" if visual_valid else "zero_filled",
		"collision_buffer_source": "collision_bytes" if collision_valid else "zero_filled",
		"expected_visual_bytes": expected_visual_bytes,
		"actual_visual_bytes": visual_bytes.size(),
		"expected_collision_bytes": expected_collision_bytes,
		"actual_collision_bytes": collision_bytes.size(),
		"target_completely_source": "gpu_target_completely_buffer" if completely_valid else "gpu_derived_visual_collision",
		"target_completely_bytes": packed_completely,
		"target_color_rgba8_bytes": packed_color,
		"target_color_rgba32f_bytes": decoded_color,
		"max_completely": stats.get("max_completely", 0.0),
		"max_collision": stats.get("max_collision", 0.0),
		"active_voxel_count": stats.get("active_voxel_count", 0),
		"collision_voxel_count": stats.get("collision_voxel_count", 0),
		"visual_voxel_count": stats.get("visual_voxel_count", 0),
		"min_active_completely": stats.get("min_active_completely", 0.0),
		"max_visual_complexity": stats.get("max_visual_complexity", 0.0),
		"target_stats_source": "target_sv_pack_read_buffers_compute",
	}


func derive_target_stats(
	visual_bytes: PackedByteArray,
	collision_bytes: PackedByteArray,
	texture_size: int,
	slice_count: int,
	use_collision_as_completely: bool = true,
	completely_bytes: PackedByteArray = PackedByteArray()
) -> Dictionary:
	var stats := derive_target_packed_buffers(
		visual_bytes,
		collision_bytes,
		texture_size,
		slice_count,
		use_collision_as_completely,
		completely_bytes,
		false
	)
	stats.erase("target_completely_bytes")
	stats.erase("target_color_rgba8_bytes")
	stats.erase("target_color_rgba32f_bytes")
	stats["stats_only"] = true
	return stats


func generate(scene_depth_img: Image, target_height_img: Image, rock_mask_img: Image = null, dirty_rect: Rect2i = Rect2i()) -> Dictionary:
	if scene_depth_img == null or target_height_img == null:
		push_error("[TargetSV] Missing scene_depth or target_height input")
		return {}

	texture_size = scene_depth_img.get_width()
	var dr := dirty_rect
	if dr.size.x <= 0 or dr.size.y <= 0:
		dr = Rect2i(0, 0, texture_size, texture_size)
	dr = dr.intersection(Rect2i(0, 0, texture_size, texture_size))
	if dr.size.x <= 0 or dr.size.y <= 0:
		push_error("[TargetSV] Empty dirty rect")
		return {}

	log_name = "TargetSceneVoxelGenerator"
	sync_global_device = true
	if not ensure_device(true, true):
		return {}

	_load_shader()
	if not _shader.is_valid() or not _pipeline.is_valid():
		_free_gpu()
		return {}

	_create_sampler()
	var rock_img := rock_mask_img
	if rock_img == null:
		rock_img = Image.create(texture_size, texture_size, false, Image.FORMAT_RGBAF)
		rock_img.fill(Color(0.0, 0.0, 0.0, 0.0))

	var tex_scene := upload_texture_2d(scene_depth_img)         # terrain depth 输入
	var tex_target := upload_texture_2d(target_height_img)      # target height 输入
	var tex_rock := upload_texture_2d(rock_img)                 # rock mask 输入
	var preview_tex := create_rw_texture_2d(texture_size, texture_size)  # TargetSV preview
	var voxel_count := texture_size * texture_size * slice_count         # 3D flat buffer voxel 数
	var visual_buffer := storage_buffer_zero(voxel_count * 16)           # vec4(color.rgb, complexity)
	var collision_buffer := storage_buffer_zero(voxel_count * 4)         # collision_peak
	var completely_buffer := storage_buffer_zero(voxel_count * 4)         # max(complexity, collision)
	var color_rgba8_buffer := storage_buffer_zero(voxel_count * 4)       # uint RGBA8 for placement shaders
	var stats_buffer := storage_buffer_zero(TARGET_STATS_BYTE_SIZE)       # u32 max completely/collision/count stats

	var set0 := create_uniform_set([
		make_sampler_uniform(0, _sampler, tex_scene),
		make_sampler_uniform(1, _sampler, tex_target),
		make_sampler_uniform(2, _sampler, tex_rock),
	], _shader, 0)
	var set1 := create_uniform_set([
		make_storage_uniform(0, visual_buffer),
		make_storage_uniform(1, collision_buffer),
		make_storage_uniform(2, completely_buffer),
		make_storage_uniform(3, color_rgba8_buffer),
		make_storage_uniform(4, stats_buffer),
	], _shader, 1)
	var set2 := create_uniform_set([
		make_image_uniform(0, preview_tex),
	], _shader, 2)

	var push := PackedByteArray()
	push.resize(TARGET_GENERATE_PUSH_BYTE_SIZE)
	push.encode_float(TARGET_GENERATE_PUSH_MAX_HEIGHT_OFFSET, max_height)
	push.encode_float(TARGET_GENERATE_PUSH_CAPTURE_SIZE_OFFSET, capture_size)
	push.encode_float(TARGET_GENERATE_PUSH_VERTICAL_SPAN_OFFSET, vertical_span)
	push.encode_float(TARGET_GENERATE_PUSH_SLOPE_START_OFFSET, slope_start)
	push.encode_float(TARGET_GENERATE_PUSH_SLOPE_FULL_OFFSET, slope_full)
	push.encode_s32(TARGET_GENERATE_PUSH_TEXTURE_SIZE_OFFSET, texture_size)
	push.encode_s32(TARGET_GENERATE_PUSH_SLICE_COUNT_OFFSET, slice_count)
	push.encode_s32(TARGET_GENERATE_PUSH_DIRTY_X_OFFSET, dr.position.x)
	push.encode_s32(TARGET_GENERATE_PUSH_DIRTY_Y_OFFSET, dr.position.y)
	push.encode_s32(TARGET_GENERATE_PUSH_DIRTY_W_OFFSET, dr.size.x)
	push.encode_s32(TARGET_GENERATE_PUSH_DIRTY_H_OFFSET, dr.size.y)
	push.encode_s32(TARGET_GENERATE_PUSH_PAD0_OFFSET, 0)

	var groups_x := ceili(float(dr.size.x) / 8.0)
	var groups_y := ceili(float(slice_count) / 4.0)
	var groups_z := ceili(float(dr.size.y) / 8.0)
	var cl := begin_compute_list()
	if cl < 0:
		push_error("[TargetSV] Compute list begin failed")
		_free_gpu()
		return {}
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_bind_uniform_set(cl, set1, 1)
	_rd.compute_list_bind_uniform_set(cl, set2, 2)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, groups_x, groups_y, groups_z)
	end_compute_list()
	submit_and_sync(true)

	var visual_bytes := _rd.buffer_get_data(visual_buffer)
	var collision_bytes := _rd.buffer_get_data(collision_buffer)
	var completely_bytes := _rd.buffer_get_data(completely_buffer)
	var color_rgba8_bytes := _rd.buffer_get_data(color_rgba8_buffer)
	var stats_bytes := _rd.buffer_get_data(stats_buffer, 0, TARGET_STATS_BYTE_SIZE)
	var preview_data := _rd.texture_get_data(preview_tex, 0)
	var preview_img := Image.create_from_data(texture_size, texture_size, false, Image.FORMAT_RGBAH, preview_data)
	var stats := _decode_target_stats(stats_bytes)

	_free_gpu()

	return {
		"valid": true,                       # 生成结果可用
		"texture_size": texture_size,        # 3D flat buffer XZ 分辨率
		"slice_count": slice_count,          # 3D flat buffer 纵向切片数
		"voxel_count": voxel_count,          # texture_size * slice_count * texture_size
		"max_height": max_height,            # 目标高度解码上限
		"capture_size": capture_size,        # 俯视捕获场景范围
		"vertical_span": vertical_span,      # TargetSV 高度跨度
		"visual_format": "rgba32f",          # visual buffer 格式
		"collision_format": "r32f",          # collision buffer 格式
		"completely_format": "r32f",          # target completely buffer 格式
		"target_color_format": "rgba8_u32",  # placement shader RGBA8 格式
		"visual_bytes": visual_bytes,        # 源 visual buffer 字节
		"collision_bytes": collision_bytes,  # 源 collision buffer 字节
		"target_completely_bytes": completely_bytes,  # GPU 解码后的 max(complexity, collision)
		"target_color_rgba8_bytes": color_rgba8_bytes, # GPU 打包后的 target_color
		"max_completely": stats.get("max_completely", 0.0), # GPU stats: max target completely in dirty dispatch
		"max_collision": stats.get("max_collision", 0.0), # GPU stats: max target collision in dirty dispatch
		"active_voxel_count": stats.get("active_voxel_count", 0), # GPU stats: completely > 0.001
		"collision_voxel_count": stats.get("collision_voxel_count", 0), # GPU stats: collision > 0.001
		"visual_voxel_count": stats.get("visual_voxel_count", 0), # GPU stats: complexity > 0.001
		"min_active_completely": stats.get("min_active_completely", 0.0), # GPU stats: min completely above threshold
		"max_visual_complexity": stats.get("max_visual_complexity", 0.0), # GPU stats: max visual complexity
		"target_stats_source": "target_scene_voxel_compute",
		"preview_image": preview_img,        # TargetSV preview 图像
	}


func _load_shader() -> void:
	_shader = load_compute_shader("res://shaders/target_scene_voxel.glsl")
	if _shader.is_valid():
		_pipeline = create_compute_pipeline(_shader)


func _load_pack_shader() -> void:
	_shader_pack = load_compute_shader("res://shaders/target_sv_pack_read_buffers.glsl")
	if _shader_pack.is_valid():
		_pipeline_pack = create_compute_pipeline(_shader_pack)


func _create_sampler() -> void:
	_sampler = create_linear_sampler()


func _free_gpu() -> void:
	dispose()
	_pipeline = RID()
	_shader = RID()
	_pipeline_pack = RID()
	_shader_pack = RID()
	_sampler = RID()
