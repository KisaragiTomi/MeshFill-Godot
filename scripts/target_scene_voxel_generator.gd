class_name TargetSceneVoxelGenerator
extends "res://scripts/godot_compute_shader_base.gd"

const BufferUtils := preload("res://scripts/utils/buffer_utils.gd")
const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")
const DebugBufferSetScript := preload("res://scripts/utils/debug_buffer_set.gd")

# 布局/量化/反转-min 编码的单一真源 = DebugBufferSet.TARGET_STATS schema。
const TARGET_STATS_ACTIVE_THRESHOLD := DebugBufferSetScript.TARGET_STATS_ACTIVE_THRESHOLD
const TARGET_PACK_PUSH_BYTE_SIZE := 16
const TARGET_PACK_PUSH_VOXEL_COUNT_OFFSET := 0
const TARGET_PACK_PUSH_USE_COLLISION_OFFSET := 4  # set to 1 to derive completeness from max(complexity, collision) when no completeness input
const TARGET_PACK_PUSH_COMPLETENESS_VALID_OFFSET := 8  # set to 1 if binding 2 has valid completeness input per voxel
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
const TARGET_VISUAL_FORMAT_RGBA8 := "rgba8"
const TARGET_VISUAL_FORMAT_RGBA32F := "rgba32f"
const TARGET_SCALAR_FORMAT_R8 := "r8_unorm"
const TARGET_SCALAR_FORMAT_R32F := "r32f"
const TARGET_RGBA8_STRIDE_BYTES := 4
const TARGET_R8_STRIDE_BYTES := 1
const TARGET_LEGACY_RGBA32F_STRIDE_BYTES := 16
const TARGET_LEGACY_R32F_STRIDE_BYTES := 4

const TARGET_PACK_PUSH := [
	["voxel_count", "int"],
	["use_collision", "int"],
	["completeness_valid", "int"],
	["write_packed", "int"],
]
const TARGET_GENERATE_PUSH := [
	["max_height", "float"],
	["capture_size", "float"],
	["vertical_span", "float"],
	["slope_start", "float"],
	["slope_full", "float"],
	["texture_size", "int"],
	["slice_count", "int"],
	["dirty_x", "int"],
	["dirty_y", "int"],
	["dirty_w", "int"],
	["dirty_h", "int"],
	["_pad0", "int"],
]

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
	var stats_set := DebugBufferSetScript.new(DebugBufferSetScript.TARGET_STATS)
	var words: PackedInt32Array = stats_set.readback(null, stats_bytes).get("words", PackedInt32Array())
	var shaped: Dictionary = stats_set.decode_shaped(words)
	return {
		"max_completeness": float(shaped.get("max_completeness", 0.0)),
		"max_occupancy": float(shaped.get("max_completeness", 0.0)),
		"max_collision": float(shaped.get("max_collision", 0.0)),
		"active_voxel_count": int(shaped.get("active_voxel_count", 0)),
		"collision_voxel_count": int(shaped.get("collision_voxel_count", 0)),
		"visual_voxel_count": int(shaped.get("visual_voxel_count", 0)),
		"min_active_completeness": float(shaped.get("min_active_completeness", 0.0)),
		"min_active_occupancy": float(shaped.get("min_active_completeness", 0.0)),
		"max_visual_complexity": float(shaped.get("max_visual_complexity", 0.0)),
	}


static func _target_field_vec4_from_color_and_completeness(
	color_rgba32f_bytes: PackedByteArray,
	completeness_bytes: PackedByteArray,
	voxel_count: int
) -> PackedFloat32Array:
	var safe_count := maxi(voxel_count, 0)
	var field := PackedFloat32Array()
	field.resize(safe_count * 4)
	var color_values := PackedFloat32Array()
	if color_rgba32f_bytes.size() >= safe_count * 16:
		color_values = color_rgba32f_bytes.to_float32_array()
	var completeness_values := PackedFloat32Array()
	if completeness_bytes.size() >= safe_count * 4:
		completeness_values = completeness_bytes.to_float32_array()
	for i in range(safe_count):
		var field_base := i * 4
		var color_base := i * 4
		if color_values.size() >= color_base + 4:
			field[field_base + 0] = color_values[color_base + 0]
			field[field_base + 1] = color_values[color_base + 1]
			field[field_base + 2] = color_values[color_base + 2]
		if completeness_values.size() > i:
			field[field_base + 3] = completeness_values[i]
		elif color_values.size() >= color_base + 4:
			field[field_base + 3] = color_values[color_base + 3]
	return field


static func _target_rgba8_byte_count(voxel_count: int) -> int:
	return SceneVoxelTileCodecScript.rgba8_byte_count(voxel_count)


static func _target_r8_byte_count(voxel_count: int) -> int:
	return SceneVoxelTileCodecScript.r8_byte_count(voxel_count)


static func _target_r8_word_byte_count(voxel_count: int) -> int:
	return SceneVoxelTileCodecScript.r8_word_byte_count(voxel_count)


static func _visual_format_from_bytes(bytes: PackedByteArray, voxel_count: int, hint: String = "") -> String:
	var hint_l := hint.to_lower()
	var rgba8_bytes := _target_rgba8_byte_count(voxel_count)
	var rgba32f_bytes := maxi(voxel_count, 0) * TARGET_LEGACY_RGBA32F_STRIDE_BYTES
	if hint_l in [TARGET_VISUAL_FORMAT_RGBA8, "rgba8_u32", "rgba8_unorm"] and bytes.size() >= rgba8_bytes:
		return TARGET_VISUAL_FORMAT_RGBA8
	if hint_l in [TARGET_VISUAL_FORMAT_RGBA32F, "rgba32f_storage_buffer", "vec4"] and bytes.size() >= rgba32f_bytes:
		return TARGET_VISUAL_FORMAT_RGBA32F
	if bytes.size() == rgba8_bytes:
		return TARGET_VISUAL_FORMAT_RGBA8
	if bytes.size() >= rgba32f_bytes:
		return TARGET_VISUAL_FORMAT_RGBA32F
	if bytes.size() >= rgba8_bytes:
		return TARGET_VISUAL_FORMAT_RGBA8
	return ""


static func _scalar_format_from_bytes(bytes: PackedByteArray, voxel_count: int, hint: String = "") -> String:
	var hint_l := hint.to_lower()
	var r8_bytes := _target_r8_byte_count(voxel_count)
	var r32f_bytes := maxi(voxel_count, 0) * TARGET_LEGACY_R32F_STRIDE_BYTES
	if hint_l in [TARGET_SCALAR_FORMAT_R8, "r8", "r8_unorm_storage_buffer"] and bytes.size() >= r8_bytes:
		return TARGET_SCALAR_FORMAT_R8
	if hint_l in [TARGET_SCALAR_FORMAT_R32F, "r32f_storage_buffer", "float"] and bytes.size() >= r32f_bytes:
		return TARGET_SCALAR_FORMAT_R32F
	if bytes.size() == r8_bytes:
		return TARGET_SCALAR_FORMAT_R8
	if bytes.size() >= r32f_bytes:
		return TARGET_SCALAR_FORMAT_R32F
	if bytes.size() >= r8_bytes:
		return TARGET_SCALAR_FORMAT_R8
	return ""


static func _rgba8_bytes_from_visual_bytes(
	visual_bytes: PackedByteArray,
	voxel_count: int,
	visual_format: String
) -> PackedByteArray:
	var out := PackedByteArray()
	var rgba8_bytes := _target_rgba8_byte_count(voxel_count)
	out.resize(rgba8_bytes)
	if visual_format == TARGET_VISUAL_FORMAT_RGBA8:
		var byte_count := mini(visual_bytes.size(), rgba8_bytes)
		for i in range(byte_count):
			out[i] = visual_bytes[i]
		return out
	if visual_format != TARGET_VISUAL_FORMAT_RGBA32F:
		return out
	var available := mini(voxel_count, int(visual_bytes.size() / TARGET_LEGACY_RGBA32F_STRIDE_BYTES))
	for i in range(available):
		var base := i * TARGET_LEGACY_RGBA32F_STRIDE_BYTES
		var color := Color(
			visual_bytes.decode_float(base + 0),
			visual_bytes.decode_float(base + 4),
			visual_bytes.decode_float(base + 8),
			visual_bytes.decode_float(base + 12)
		)
		out.encode_u32(i * TARGET_RGBA8_STRIDE_BYTES, BufferUtils.pack_shader_rgba8_word(color))
	return out


static func _r8_bytes_from_scalar_bytes(
	scalar_bytes: PackedByteArray,
	voxel_count: int,
	scalar_format: String
) -> PackedByteArray:
	var out := PackedByteArray()
	var r8_bytes := _target_r8_byte_count(voxel_count)
	out.resize(r8_bytes)
	if scalar_format == TARGET_SCALAR_FORMAT_R8:
		var byte_count := mini(scalar_bytes.size(), r8_bytes)
		for i in range(byte_count):
			out[i] = scalar_bytes[i]
		return out
	if scalar_format != TARGET_SCALAR_FORMAT_R32F:
		return out
	var available := mini(voxel_count, int(scalar_bytes.size() / TARGET_LEGACY_R32F_STRIDE_BYTES))
	for i in range(available):
		out[i] = BufferUtils.quantize_unorm8(scalar_bytes.decode_float(i * TARGET_LEGACY_R32F_STRIDE_BYTES))
	return out


static func _r8_word_bytes_from_r8_bytes(r8_bytes: PackedByteArray, voxel_count: int) -> PackedByteArray:
	return SceneVoxelTileCodecScript.r8_word_bytes_from_r8_bytes(r8_bytes, voxel_count)


static func _r8_bytes_from_word_bytes(word_bytes: PackedByteArray, voxel_count: int) -> PackedByteArray:
	return SceneVoxelTileCodecScript.r8_bytes_from_word_bytes(word_bytes, voxel_count)


static func _r8_value_at(r8_bytes: PackedByteArray, index: int) -> float:
	if index < 0 or index >= r8_bytes.size():
		return 0.0
	return float(r8_bytes[index] & 0xFF) / 255.0


static func _rgba8_color_at(rgba8_bytes: PackedByteArray, index: int) -> Color:
	var offset := index * TARGET_RGBA8_STRIDE_BYTES
	if offset + TARGET_RGBA8_STRIDE_BYTES > rgba8_bytes.size():
		return Color(0.0, 0.0, 0.0, 0.0)
	return BufferUtils.shader_rgba8_word_to_color(rgba8_bytes.decode_u32(offset))


static func _target_field_vec4_from_rgba8_and_r8(
	color_rgba8_bytes: PackedByteArray,
	completeness_r8_bytes: PackedByteArray,
	voxel_count: int
) -> PackedFloat32Array:
	var field := PackedFloat32Array()
	var safe_count := maxi(voxel_count, 0)
	field.resize(safe_count * 4)
	for i in range(safe_count):
		var color := _rgba8_color_at(color_rgba8_bytes, i)
		var base := i * 4
		field[base + 0] = color.r
		field[base + 1] = color.g
		field[base + 2] = color.b
		field[base + 3] = _r8_value_at(completeness_r8_bytes, i)
	return field


static func decode_target_read_buffers(
	visual_bytes: PackedByteArray,
	collision_bytes: PackedByteArray,
	texture_size: int,
	slice_count: int,
	use_collision_as_completeness: bool = true,
	completeness_bytes: PackedByteArray = PackedByteArray()
) -> Dictionary:
	var tex_size := maxi(texture_size, 1)
	var slices := maxi(slice_count, 1)
	var voxel_count := tex_size * tex_size * slices
	var expected_visual_bytes := _target_rgba8_byte_count(voxel_count)
	var expected_collision_bytes := _target_r8_byte_count(voxel_count)
	var legacy_expected_visual_bytes := voxel_count * TARGET_LEGACY_RGBA32F_STRIDE_BYTES
	var legacy_expected_collision_bytes := voxel_count * TARGET_LEGACY_R32F_STRIDE_BYTES
	var target_completeness := PackedFloat32Array()
	var target_collision := PackedFloat32Array()
	var target_color := PackedColorArray()
	target_completeness.resize(voxel_count)
	target_collision.resize(voxel_count)
	target_color.resize(voxel_count)
	var visual_format := _visual_format_from_bytes(visual_bytes, voxel_count)
	var collision_format := _scalar_format_from_bytes(collision_bytes, voxel_count)
	var completeness_format := _scalar_format_from_bytes(completeness_bytes, voxel_count)
	var visual_valid := not visual_format.is_empty()
	var collision_valid := not collision_format.is_empty()
	var completeness_valid := not completeness_format.is_empty()
	if not visual_valid and not collision_valid:
		return {
			"valid": false,
			"reason": "target_buffer_size_mismatch",
			"texture_size": tex_size,
			"slice_count": slices,
			"voxel_count": voxel_count,
			"expected_visual_bytes": expected_visual_bytes,
			"legacy_expected_visual_bytes": legacy_expected_visual_bytes,
			"actual_visual_bytes": visual_bytes.size(),
			"expected_collision_bytes": expected_collision_bytes,
			"legacy_expected_collision_bytes": legacy_expected_collision_bytes,
			"actual_collision_bytes": collision_bytes.size(),
			"target_completeness": target_completeness,
			"target_collision": target_collision,
			"target_field": target_completeness,
			"target_color": target_color,
		}
	var visual_rgba8 := _rgba8_bytes_from_visual_bytes(visual_bytes, voxel_count, visual_format)
	var collision_r8 := _r8_bytes_from_scalar_bytes(collision_bytes, voxel_count, collision_format)
	var completeness_r8 := _r8_bytes_from_scalar_bytes(completeness_bytes, voxel_count, completeness_format) if completeness_valid else PackedByteArray()

	var max_completeness := 0.0
	var max_collision := 0.0
	var active_voxel_count := 0
	var collision_voxel_count := 0
	var visual_voxel_count := 0
	var min_active_completeness := 0.0
	var max_visual_complexity := 0.0
	for i in range(voxel_count):
		var color := _rgba8_color_at(visual_rgba8, i) if visual_valid else Color(0.0, 0.0, 0.0, 0.0)
		var complexity := color.a
		var collision := _r8_value_at(collision_r8, i) if collision_valid else 0.0
		complexity = clampf(complexity, 0.0, 1.0)
		collision = clampf(collision, 0.0, 1.0)
		target_collision[i] = collision
		var completeness := complexity
		if completeness_valid:
			completeness = clampf(_r8_value_at(completeness_r8, i), 0.0, 1.0)
		elif use_collision_as_completeness:
			completeness = maxf(complexity, collision)
		target_completeness[i] = completeness
		target_color[i] = Color(
			clampf(color.r, 0.0, 1.0),
			clampf(color.g, 0.0, 1.0),
			clampf(color.b, 0.0, 1.0),
			complexity
		)
		max_completeness = maxf(max_completeness, completeness)
		max_collision = maxf(max_collision, collision)
		max_visual_complexity = maxf(max_visual_complexity, complexity)
		if completeness > TARGET_STATS_ACTIVE_THRESHOLD:
			active_voxel_count += 1
			min_active_completeness = completeness if active_voxel_count == 1 else minf(min_active_completeness, completeness)
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
		"legacy_expected_visual_bytes": legacy_expected_visual_bytes,
		"actual_visual_bytes": visual_bytes.size(),
		"expected_collision_bytes": expected_collision_bytes,
		"legacy_expected_collision_bytes": legacy_expected_collision_bytes,
		"actual_collision_bytes": collision_bytes.size(),
		"visual_format": visual_format,
		"collision_format": collision_format,
		"visual_stride_bytes": TARGET_RGBA8_STRIDE_BYTES if visual_format == TARGET_VISUAL_FORMAT_RGBA8 else TARGET_LEGACY_RGBA32F_STRIDE_BYTES,
		"collision_stride_bytes": TARGET_R8_STRIDE_BYTES if collision_format == TARGET_SCALAR_FORMAT_R8 else TARGET_LEGACY_R32F_STRIDE_BYTES,
		"canonical_visual_format": TARGET_VISUAL_FORMAT_RGBA8,
		"canonical_collision_format": TARGET_SCALAR_FORMAT_R8,
		"target_completeness": target_completeness,
		"target_collision": target_collision,
		"target_field": target_completeness,
		"target_color": target_color,
		"max_completeness": max_completeness,
		"max_occupancy": max_completeness,
		"max_collision": max_collision,
		"active_voxel_count": active_voxel_count,
		"collision_voxel_count": collision_voxel_count,
		"visual_voxel_count": visual_voxel_count,
		"min_active_completeness": min_active_completeness,
		"min_active_occupancy": min_active_completeness,
		"max_visual_complexity": max_visual_complexity,
		"target_completeness_source": "gpu_target_completeness_buffer" if completeness_valid else "decoded_visual_collision",
	}


static func decode_target_read_buffers_gpu(
	visual_bytes: PackedByteArray,
	collision_bytes: PackedByteArray,
	texture_size: int,
	slice_count: int,
	use_collision_as_completeness: bool = true,
	completeness_bytes: PackedByteArray = PackedByteArray()
) -> Dictionary:
	# GPU-only TargetSV_B decode for placement/readback buffers.
	# Canonical layout is visual RGBA8 (4 bytes/voxel) plus scalar R8 fields
	# (1 byte/voxel, packed four values per uint for compute). Legacy fp32 input
	# is converted to the canonical 8bit layout before GPU dispatch.
	var tex_size := maxi(texture_size, 1)
	var slices := maxi(slice_count, 1)
	var voxel_count := tex_size * tex_size * slices
	var expected_visual_bytes := _target_rgba8_byte_count(voxel_count)
	var expected_collision_bytes := _target_r8_byte_count(voxel_count)
	var legacy_expected_visual_bytes := voxel_count * TARGET_LEGACY_RGBA32F_STRIDE_BYTES
	var legacy_expected_collision_bytes := voxel_count * TARGET_LEGACY_R32F_STRIDE_BYTES
	var target_completeness := PackedFloat32Array()
	var target_collision := PackedFloat32Array()
	var target_color := PackedColorArray()
	target_completeness.resize(voxel_count)
	target_collision.resize(voxel_count)
	target_color.resize(voxel_count)
	var visual_format := _visual_format_from_bytes(visual_bytes, voxel_count)
	var collision_format := _scalar_format_from_bytes(collision_bytes, voxel_count)
	var visual_valid := not visual_format.is_empty()
	var collision_valid := not collision_format.is_empty()
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
			"legacy_expected_visual_bytes": legacy_expected_visual_bytes,
			"actual_visual_bytes": visual_bytes.size(),
			"expected_collision_bytes": expected_collision_bytes,
			"legacy_expected_collision_bytes": legacy_expected_collision_bytes,
			"actual_collision_bytes": collision_bytes.size(),
			"target_completeness": target_completeness,
			"target_collision": target_collision,
			"target_field": target_completeness,
			"target_color": target_color,
		}

	var generator_script := load("res://scripts/target_scene_voxel_generator.gd") as Script
	if generator_script == null:
		return {
			"valid": false,
			"ok": false,
			"reason": "target_scene_voxel_generator_script_missing",
			"gpu_first": true,
			"cpu_fallback": false,
			"target_completeness": target_completeness,
			"target_collision": target_collision,
			"target_field": target_completeness,
			"target_color": target_color,
		}
	var generator = generator_script.new()
	var packed: Dictionary = generator.derive_target_packed_buffers(
		visual_bytes,
		collision_bytes,
		tex_size,
		slices,
		use_collision_as_completeness,
		completeness_bytes,
		true
	)
	if not bool(packed.get("ok", false)):
		packed["valid"] = false
		packed["target_completeness"] = target_completeness
		packed["target_collision"] = target_collision
		packed["target_field"] = target_completeness
		packed["target_color"] = target_color
		return packed

	var completeness_out: PackedByteArray = packed.get("target_completeness_bytes", PackedByteArray())
	var color_out: PackedByteArray = packed.get("target_visual_rgba8_bytes", PackedByteArray())
	if completeness_out.size() < expected_collision_bytes or color_out.size() < expected_visual_bytes:
		packed["valid"] = false
		packed["reason"] = "target_gpu_readback_size_mismatch"
		packed["target_completeness"] = target_completeness
		packed["target_collision"] = target_collision
		packed["target_color"] = target_color
		return packed

	target_completeness.resize(voxel_count)
	target_collision.resize(voxel_count)
	target_color.resize(voxel_count)
	var collision_r8 := _r8_bytes_from_scalar_bytes(collision_bytes, voxel_count, collision_format)
	for i in range(voxel_count):
		target_completeness[i] = _r8_value_at(completeness_out, i)
		target_collision[i] = _r8_value_at(collision_r8, i)
		target_color[i] = _rgba8_color_at(color_out, i)

	packed["valid"] = visual_valid and collision_valid
	packed["partial"] = not (visual_valid and collision_valid)
	packed["reason"] = "ok" if visual_valid and collision_valid else "target_buffer_partial"
	packed["target_completeness"] = target_completeness
	packed["target_collision"] = target_collision
	packed["target_field"] = target_completeness
	packed["target_color"] = target_color
	packed["max_occupancy"] = packed.get("max_completeness", 0.0)
	packed["min_active_occupancy"] = packed.get("min_active_completeness", 0.0)
	packed["decode_source"] = "target_sv_pack_read_buffers_compute"
	packed["target_color_decode_format"] = TARGET_VISUAL_FORMAT_RGBA8
	packed["target_color_stride_bytes"] = TARGET_RGBA8_STRIDE_BYTES
	packed["target_completeness_stride_bytes"] = TARGET_R8_STRIDE_BYTES
	return packed


func derive_target_packed_buffers(
	visual_bytes: PackedByteArray,
	collision_bytes: PackedByteArray,
	texture_size: int,
	slice_count: int,
	use_collision_as_completeness: bool = true,
	completeness_bytes: PackedByteArray = PackedByteArray(),
	readback_packed_buffers: bool = true
) -> Dictionary:
	var tex_size := maxi(texture_size, 1)
	var slices := maxi(slice_count, 1)
	var voxel_count := tex_size * tex_size * slices
	var expected_visual_bytes := _target_rgba8_byte_count(voxel_count)
	var expected_collision_bytes := _target_r8_byte_count(voxel_count)
	var legacy_expected_visual_bytes := voxel_count * TARGET_LEGACY_RGBA32F_STRIDE_BYTES
	var legacy_expected_collision_bytes := voxel_count * TARGET_LEGACY_R32F_STRIDE_BYTES
	var visual_format := _visual_format_from_bytes(visual_bytes, voxel_count)
	var collision_format := _scalar_format_from_bytes(collision_bytes, voxel_count)
	var visual_valid := not visual_format.is_empty()
	var collision_valid := not collision_format.is_empty()
	if not visual_valid and not collision_valid:
		return {
			"ok": false,
			"reason": "target_buffer_size_mismatch",
			"gpu_first": true,
			"cpu_fallback": false,
			"voxel_count": voxel_count,
			"expected_visual_bytes": expected_visual_bytes,
			"legacy_expected_visual_bytes": legacy_expected_visual_bytes,
			"actual_visual_bytes": visual_bytes.size(),
			"expected_collision_bytes": expected_collision_bytes,
			"legacy_expected_collision_bytes": legacy_expected_collision_bytes,
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

	_shader_pack = load_compute_shader("res://shaders/target_sv_pack_read_buffers.glsl")
	if _shader_pack.is_valid():
		_pipeline_pack = create_compute_pipeline(_shader_pack)
	if not _shader_pack.is_valid() or not _pipeline_pack.is_valid():
		_free_gpu()
		return {
			"ok": false,
			"reason": "target_pack_shader_not_ready",
			"gpu_first": true,
			"cpu_fallback": false,
			"voxel_count": voxel_count,
	}

	var completeness_format := _scalar_format_from_bytes(completeness_bytes, voxel_count)
	var completeness_valid := not completeness_format.is_empty()
	var visual_rgba8 := _rgba8_bytes_from_visual_bytes(visual_bytes, voxel_count, visual_format)
	var collision_r8 := _r8_bytes_from_scalar_bytes(collision_bytes, voxel_count, collision_format)
	var completeness_r8 := _r8_bytes_from_scalar_bytes(completeness_bytes, voxel_count, completeness_format) if completeness_valid else PackedByteArray()
	var collision_words := _r8_word_bytes_from_r8_bytes(collision_r8, voxel_count)
	var completeness_input_words := _r8_word_bytes_from_r8_bytes(completeness_r8, voxel_count) if completeness_valid else PackedByteArray()
	var r8_word_byte_count := _target_r8_word_byte_count(voxel_count)
	# Partial TargetSV_B decode stays GPU-only: missing visual/collision input is a full-size zero SSBO.
	# Shader input layout is canonical RGBA8 u32 plus R8 scalar values packed four voxels per uint.
	var visual_buffer := storage_buffer_from_bytes(
		visual_rgba8.slice(0, expected_visual_bytes),
		SCOPE_FRAME,
		"target_visual_rgba8"
	) if visual_valid else storage_buffer_zero(expected_visual_bytes, SCOPE_FRAME, "target_visual_zero_rgba8")
	var collision_buffer := storage_buffer_from_bytes(
		collision_words.slice(0, r8_word_byte_count),
		SCOPE_FRAME,
		"target_collision_r8_words"
	) if collision_valid else storage_buffer_zero(r8_word_byte_count, SCOPE_FRAME, "target_collision_zero_r8_words")
	var completeness_input_buffer := storage_buffer_from_bytes(
		completeness_input_words.slice(0, r8_word_byte_count),
		SCOPE_FRAME,
		"target_completeness_input_r8_words"
	) if completeness_valid else storage_buffer_zero(4, SCOPE_FRAME, "target_completeness_input_r8_words")
	var completeness_out_buffer := storage_buffer_zero(
		r8_word_byte_count if readback_packed_buffers else 4,
		SCOPE_FRAME,
		"target_completeness_out_r8_words"
	)
	var color_rgba8_out_buffer := storage_buffer_zero(
		voxel_count * 4 if readback_packed_buffers else 4,
		SCOPE_FRAME,
		"target_visual_rgba8_out"
	)
	var stats_set := DebugBufferSetScript.new(DebugBufferSetScript.TARGET_STATS)
	var stats_out_buffer := stats_set.allocate(self, 0, {}, SCOPE_FRAME, "target_pack_stats_u32")

	var set0 := create_uniform_set([
		make_storage_uniform(0, visual_buffer),
		make_storage_uniform(1, collision_buffer),
		make_storage_uniform(2, completeness_input_buffer),
		make_storage_uniform(3, completeness_out_buffer),
		make_storage_uniform(4, color_rgba8_out_buffer),
		make_storage_uniform(5, stats_out_buffer),
	], _shader_pack, 0)

	var push := PushConstantLayout.new(TARGET_PACK_PUSH).pack({
		voxel_count = voxel_count,
		use_collision = 1 if use_collision_as_completeness else 0,
		completeness_valid = 1 if completeness_valid else 0,
		write_packed = 1 if readback_packed_buffers else 0,
	})

	var groups := ceil_div(voxel_count, 64)
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
	_gpu_dispatch_pipeline_sets(cl, _pipeline_pack, [set0], push, Vector3i(groups, 1, 1))
	end_compute_list()
	submit_and_sync(true)

	var packed_completeness := PackedByteArray()
	var packed_color := PackedByteArray()
	if readback_packed_buffers:
		var completeness_words := _rd.buffer_get_data(completeness_out_buffer, 0, r8_word_byte_count)
		packed_completeness = _r8_bytes_from_word_bytes(completeness_words, voxel_count)
		packed_color = _rd.buffer_get_data(color_rgba8_out_buffer, 0, voxel_count * 4)
	var target_field_bytes := _target_field_vec4_from_rgba8_and_r8(packed_color, packed_completeness, voxel_count) if readback_packed_buffers else PackedFloat32Array()
	var stats_bytes := _rd.buffer_get_data(stats_out_buffer, 0, stats_set.byte_count())
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
		"visual_format": TARGET_VISUAL_FORMAT_RGBA8,
		"collision_format": TARGET_SCALAR_FORMAT_R8,
		"completeness_format": TARGET_SCALAR_FORMAT_R8,
		"target_color_format": TARGET_VISUAL_FORMAT_RGBA8,
		"target_color_decode_format": TARGET_VISUAL_FORMAT_RGBA8,
		"target_color_stride_bytes": TARGET_RGBA8_STRIDE_BYTES,
		"target_completeness_stride_bytes": TARGET_R8_STRIDE_BYTES,
		"input_visual_format": visual_format,
		"input_collision_format": collision_format,
		"input_completeness_format": completeness_format if completeness_valid else "",
		"visual_buffer_source": "visual_bytes" if visual_valid else "zero_filled",
		"collision_buffer_source": "collision_bytes" if collision_valid else "zero_filled",
		"expected_visual_bytes": expected_visual_bytes,
		"legacy_expected_visual_bytes": legacy_expected_visual_bytes,
		"actual_visual_bytes": visual_bytes.size(),
		"expected_collision_bytes": expected_collision_bytes,
		"legacy_expected_collision_bytes": legacy_expected_collision_bytes,
		"actual_collision_bytes": collision_bytes.size(),
		"target_completeness_source": "gpu_target_completeness_buffer" if completeness_valid else "gpu_derived_visual_collision",
		"target_completeness_bytes": packed_completeness,
		"target_field_bytes": target_field_bytes,
		"target_visual_rgba8_bytes": packed_color,
		"max_completeness": stats.get("max_completeness", 0.0),
		"max_occupancy": stats.get("max_occupancy", stats.get("max_completeness", 0.0)),
		"max_collision": stats.get("max_collision", 0.0),
		"active_voxel_count": stats.get("active_voxel_count", 0),
		"collision_voxel_count": stats.get("collision_voxel_count", 0),
		"visual_voxel_count": stats.get("visual_voxel_count", 0),
		"min_active_completeness": stats.get("min_active_completeness", 0.0),
		"min_active_occupancy": stats.get("min_active_occupancy", stats.get("min_active_completeness", 0.0)),
		"max_visual_complexity": stats.get("max_visual_complexity", 0.0),
		"target_stats_source": "target_sv_pack_read_buffers_compute",
	}


func derive_target_stats(
	visual_bytes: PackedByteArray,
	collision_bytes: PackedByteArray,
	texture_size: int,
	slice_count: int,
	use_collision_as_completeness: bool = true,
	completeness_bytes: PackedByteArray = PackedByteArray()
) -> Dictionary:
	var stats := derive_target_packed_buffers(
		visual_bytes,
		collision_bytes,
		texture_size,
		slice_count,
		use_collision_as_completeness,
		completeness_bytes,
		false
	)
	stats.erase("target_completeness_bytes")
	stats.erase("target_field_bytes")
	stats.erase("target_visual_rgba8_bytes")
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

	_shader = load_compute_shader("res://shaders/target_scene_voxel.glsl")
	if _shader.is_valid():
		_pipeline = create_compute_pipeline(_shader)
	if not _shader.is_valid() or not _pipeline.is_valid():
		_free_gpu()
		return {}

	_sampler = create_linear_sampler()
	var rock_img := rock_mask_img
	if rock_img == null:
		rock_img = Image.create(texture_size, texture_size, false, Image.FORMAT_RGBAF)
		rock_img.fill(Color(0.0, 0.0, 0.0, 0.0))

	var tex_scene := upload_texture_2d(scene_depth_img)         # terrain depth 输入
	var tex_target := upload_texture_2d(target_height_img)      # target height 输入
	var tex_rock := upload_texture_2d(rock_img)                 # rock mask 输入
	var preview_tex := create_rw_texture_2d(texture_size, texture_size)  # TargetSV preview
	var voxel_count := texture_size * texture_size * slice_count         # 3D flat buffer voxel 数
	var r8_word_byte_count := _target_r8_word_byte_count(voxel_count)
	var visual_buffer := storage_buffer_zero(voxel_count * TARGET_RGBA8_STRIDE_BYTES) # RGBA8 u32 color+complexity
	var collision_buffer := storage_buffer_zero(r8_word_byte_count)       # collision R8, 4 voxels per uint
	var completeness_buffer := storage_buffer_zero(r8_word_byte_count)      # max(complexity, collision) R8, 4 voxels per uint
	var stats_set := DebugBufferSetScript.new(DebugBufferSetScript.TARGET_STATS)
	var stats_buffer := stats_set.allocate(self, 0, {}, SCOPE_FRAME, "target_stats_u32")  # u32 stats（DebugBufferSet TARGET_STATS）

	var set0 := create_uniform_set([
		make_sampler_uniform(0, _sampler, tex_scene),
		make_sampler_uniform(1, _sampler, tex_target),
		make_sampler_uniform(2, _sampler, tex_rock),
	], _shader, 0)
	var set1 := create_uniform_set([
		make_storage_uniform(0, visual_buffer),
		make_storage_uniform(1, collision_buffer),
		make_storage_uniform(2, completeness_buffer),
		make_storage_uniform(4, stats_buffer),
	], _shader, 1)
	var set2 := create_uniform_set([
		make_image_uniform(0, preview_tex),
	], _shader, 2)

	var push := PushConstantLayout.new(TARGET_GENERATE_PUSH).pack({
		max_height = max_height,
		capture_size = capture_size,
		vertical_span = vertical_span,
		slope_start = slope_start,
		slope_full = slope_full,
		texture_size = texture_size,
		slice_count = slice_count,
		dirty_x = dr.position.x,
		dirty_y = dr.position.y,
		dirty_w = dr.size.x,
		dirty_h = dr.size.y,
	})

	# local_size in target_scene_voxel.glsl = (8, 4, 8)
	var groups := dispatch_groups_3d(dr.size.x, slice_count, dr.size.y, 8, 4, 8)
	var cl := begin_compute_list()
	if cl < 0:
		push_error("[TargetSV] Compute list begin failed")
		_free_gpu()
		return {}
	_gpu_dispatch_pipeline_sets(cl, _pipeline, [set0, set1, set2], push, groups)
	end_compute_list()
	submit_and_sync(true)

	var visual_bytes := _rd.buffer_get_data(visual_buffer, 0, voxel_count * TARGET_RGBA8_STRIDE_BYTES)
	var collision_word_bytes := _rd.buffer_get_data(collision_buffer, 0, r8_word_byte_count)
	var completeness_word_bytes := _rd.buffer_get_data(completeness_buffer, 0, r8_word_byte_count)
	var collision_bytes := _r8_bytes_from_word_bytes(collision_word_bytes, voxel_count)
	var completeness_bytes := _r8_bytes_from_word_bytes(completeness_word_bytes, voxel_count)
	var target_field_bytes := _target_field_vec4_from_rgba8_and_r8(visual_bytes, completeness_bytes, voxel_count)
	var stats_bytes := _rd.buffer_get_data(stats_buffer, 0, stats_set.byte_count())
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
		"visual_format": TARGET_VISUAL_FORMAT_RGBA8, # visual buffer 格式
		"collision_format": TARGET_SCALAR_FORMAT_R8, # collision buffer 格式
		"completeness_format": TARGET_SCALAR_FORMAT_R8, # target completeness buffer 格式
		"target_color_format": TARGET_VISUAL_FORMAT_RGBA8, # placement shader RGBA8 格式
		"visual_stride_bytes": TARGET_RGBA8_STRIDE_BYTES,
		"collision_stride_bytes": TARGET_R8_STRIDE_BYTES,
		"target_completeness_stride_bytes": TARGET_R8_STRIDE_BYTES,
		"visual_bytes": visual_bytes,        # 源 visual buffer 字节
		"collision_bytes": collision_bytes,  # 源 collision buffer 字节
		"target_completeness_bytes": completeness_bytes,  # GPU 解码后的 max(complexity, collision)
		"target_field_bytes": target_field_bytes,
		"target_visual_rgba8_bytes": visual_bytes, # 与 visual_bytes 同一 RGBA8 数据（A-2：删除重复 dup buffer 后复用 binding0 回读）
		"max_completeness": stats.get("max_completeness", 0.0), # GPU stats: max target completeness in dirty dispatch
		"max_occupancy": stats.get("max_occupancy", stats.get("max_completeness", 0.0)),
		"max_collision": stats.get("max_collision", 0.0), # GPU stats: max target collision in dirty dispatch
		"active_voxel_count": stats.get("active_voxel_count", 0), # GPU stats: completeness > 0.001
		"collision_voxel_count": stats.get("collision_voxel_count", 0), # GPU stats: collision > 0.001
		"visual_voxel_count": stats.get("visual_voxel_count", 0), # GPU stats: complexity > 0.001
		"min_active_completeness": stats.get("min_active_completeness", 0.0), # GPU stats: min completeness above threshold
		"min_active_occupancy": stats.get("min_active_occupancy", stats.get("min_active_completeness", 0.0)),
		"max_visual_complexity": stats.get("max_visual_complexity", 0.0), # GPU stats: max visual complexity
		"target_stats_source": "target_scene_voxel_compute",
		"preview_image": preview_img,        # TargetSV preview 图像
	}


func _free_gpu() -> void:
	dispose()
	_pipeline = RID()
	_shader = RID()
	_pipeline_pack = RID()
	_shader_pack = RID()
	_sampler = RID()
