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
