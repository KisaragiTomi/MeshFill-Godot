@tool
extends RefCounted

const SCALAR32_BYTES := 4
const VEC4_BYTES := 16
const IVEC4_BYTES := 16
const MAT4_BYTES := 64


static func decode_float_buffer(bytes: PackedByteArray, expected_size: int) -> PackedFloat32Array:
	var expected_count := maxi(expected_size, 0)
	var expected_bytes := expected_count * SCALAR32_BYTES
	var available_bytes := mini(bytes.size(), expected_bytes)
	available_bytes -= available_bytes % SCALAR32_BYTES
	var values := bytes.slice(0, available_bytes).to_float32_array()
	values.resize(expected_count)
	return values


static func decode_u32_buffer(bytes: PackedByteArray, expected_size: int) -> PackedInt32Array:
	var expected_count := maxi(expected_size, 0)
	var expected_bytes := expected_count * SCALAR32_BYTES
	var available_bytes := mini(bytes.size(), expected_bytes)
	available_bytes -= available_bytes % SCALAR32_BYTES
	var values := bytes.slice(0, available_bytes).to_int32_array()
	values.resize(expected_count)
	return values


static func decode_u32_count(bytes: PackedByteArray) -> int:
	if bytes.size() < SCALAR32_BYTES:
		return 0
	return int(bytes.decode_u32(0))


static func decoded_record_count(bytes: PackedByteArray, expected_count: int, byte_stride: int) -> int:
	# Guard against modulo/division by zero below; a non-positive stride can never yield a complete record.
	if byte_stride <= 0:
		return 0
	var available_bytes := mini(bytes.size(), expected_count * byte_stride)
	available_bytes -= available_bytes % byte_stride
	return mini(expected_count, int(available_bytes / byte_stride))


static func pack_s32(value: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(SCALAR32_BYTES)
	bytes.encode_s32(0, value)
	return bytes


static func encode_vec3i4(bytes: PackedByteArray, offset: int, value: Vector3i) -> void:
	encode_vec3i4_with_w(bytes, offset, value, 0)


static func encode_vec3i4_with_w(bytes: PackedByteArray, offset: int, value: Vector3i, w: int) -> void:
	bytes.encode_s32(offset + 0, value.x)
	bytes.encode_s32(offset + 4, value.y)
	bytes.encode_s32(offset + 8, value.z)
	bytes.encode_s32(offset + 12, w)


static func decode_vec3i4(bytes: PackedByteArray, offset: int = 0) -> Vector3i:
	if offset < 0 or bytes.size() < offset + IVEC4_BYTES:
		return Vector3i.ZERO
	return Vector3i(
		bytes.decode_s32(offset + 0),
		bytes.decode_s32(offset + 4),
		bytes.decode_s32(offset + 8)
	)


static func pack_vec3i4(value: Vector3i) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(IVEC4_BYTES)
	encode_vec3i4(bytes, 0, value)
	return bytes


static func encode_vec4(bytes: PackedByteArray, offset: int, value: Vector3, w: float) -> void:
	bytes.encode_float(offset + 0, value.x)
	bytes.encode_float(offset + 4, value.y)
	bytes.encode_float(offset + 8, value.z)
	bytes.encode_float(offset + 12, w)


static func decode_vec4_xyz(bytes: PackedByteArray, offset: int = 0) -> Vector3:
	if offset < 0 or bytes.size() < offset + VEC4_BYTES:
		return Vector3.ZERO
	return Vector3(
		bytes.decode_float(offset + 0),
		bytes.decode_float(offset + 4),
		bytes.decode_float(offset + 8)
	)


static func decode_vec4(bytes: PackedByteArray, offset: int = 0) -> Vector4:
	if offset < 0 or bytes.size() < offset + VEC4_BYTES:
		return Vector4.ZERO
	return Vector4(
		bytes.decode_float(offset + 0),
		bytes.decode_float(offset + 4),
		bytes.decode_float(offset + 8),
		bytes.decode_float(offset + 12)
	)


static func encode_transform_mat4(bytes: PackedByteArray, offset: int, transform: Transform3D) -> void:
	encode_vec4(bytes, offset + 0, transform.basis.x, 0.0)
	encode_vec4(bytes, offset + 16, transform.basis.y, 0.0)
	encode_vec4(bytes, offset + 32, transform.basis.z, 0.0)
	encode_vec4(bytes, offset + 48, transform.origin, 1.0)


static func pack_transform_mat4(transform: Transform3D) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(MAT4_BYTES)
	encode_transform_mat4(bytes, 0, transform)
	return bytes


static func decode_transform_mat4(bytes: PackedByteArray, offset: int = 0) -> Transform3D:
	if offset < 0 or bytes.size() < offset + MAT4_BYTES:
		return Transform3D.IDENTITY
	var basis_x := decode_vec4_xyz(bytes, offset + 0)
	var basis_y := decode_vec4_xyz(bytes, offset + 16)
	var basis_z := decode_vec4_xyz(bytes, offset + 32)
	var origin := decode_vec4_xyz(bytes, offset + 48)
	return Transform3D(Basis(basis_x, basis_y, basis_z), origin)


# ============================================================
# RGBA8 打包/量化原语（自 rgba8_utils.gd 合并，8 位 UNORM 颜色 <-> u32 字）
# ============================================================

static func quantize_unorm8(value: float) -> int:
	return clampi(int(round(clampf(value, 0.0, 1.0) * 255.0)), 0, 255)


static func pack_shader_rgba8_word(color: Color) -> int:
	var r := quantize_unorm8(color.r)
	var g := quantize_unorm8(color.g)
	var b := quantize_unorm8(color.b)
	var a := quantize_unorm8(color.a)
	return ((r & 0xFF) << 24) | ((g & 0xFF) << 16) | ((b & 0xFF) << 8) | (a & 0xFF)


static func shader_rgba8_word_to_color(word: int) -> Color:
	var rgba8 := word & 0xFFFFFFFF
	return Color(
		float((rgba8 >> 24) & 0xFF) / 255.0,
		float((rgba8 >> 16) & 0xFF) / 255.0,
		float((rgba8 >> 8) & 0xFF) / 255.0,
		float(rgba8 & 0xFF) / 255.0
	)


static func pack_semantic_rgba8_word(color: Color) -> int:
	var r := quantize_unorm8(color.r)
	var g := quantize_unorm8(color.g)
	var b := quantize_unorm8(color.b)
	var a := quantize_unorm8(color.a)
	return (r & 0xFF) | ((g & 0xFF) << 8) | ((b & 0xFF) << 16) | ((a & 0xFF) << 24)


static func semantic_rgba8_word_to_color(word: int) -> Color:
	var rgba8 := word & 0xFFFFFFFF
	return Color(
		float(rgba8 & 0xFF) / 255.0,
		float((rgba8 >> 8) & 0xFF) / 255.0,
		float((rgba8 >> 16) & 0xFF) / 255.0,
		float((rgba8 >> 24) & 0xFF) / 255.0
	)


static func semantic_to_shader_rgba8_word(word: int) -> int:
	return pack_shader_rgba8_word(semantic_rgba8_word_to_color(word))


## 将 s32 数组与 f32 数组按序拼接为 push constant 字节（ints-then-floats 布局）。
## 类型化数组拼接不产生手写 encode_* 偏移那类错位风险；是偏移式打包的安全替代习语,
## 仅适用于整段 s32 后接整段 f32 的布局(std430 下两段各自 4 字节对齐,天然合法)。
static func pack_push_ints_floats(ints: PackedInt32Array, floats: PackedFloat32Array) -> PackedByteArray:
	var bytes := ints.to_byte_array()
	bytes.append_array(floats.to_byte_array())
	return bytes


