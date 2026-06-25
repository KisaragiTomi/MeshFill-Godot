@tool
extends RefCounted


static func decode_float_buffer(bytes: PackedByteArray, expected_size: int) -> PackedFloat32Array:
	var expected_count := maxi(expected_size, 0)
	var expected_bytes := expected_count * 4
	var available_bytes := mini(bytes.size(), expected_bytes)
	available_bytes -= available_bytes % 4
	var values := bytes.slice(0, available_bytes).to_float32_array()
	values.resize(expected_count)
	return values


static func decode_u32_buffer(bytes: PackedByteArray, expected_size: int) -> PackedInt32Array:
	var expected_count := maxi(expected_size, 0)
	var expected_bytes := expected_count * 4
	var available_bytes := mini(bytes.size(), expected_bytes)
	available_bytes -= available_bytes % 4
	var values := bytes.slice(0, available_bytes).to_int32_array()
	values.resize(expected_count)
	return values
