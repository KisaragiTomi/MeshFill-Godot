extends SceneTree

const UtilsBufferUtils := preload("res://scripts/utils_buffer_utils.gd")


func _init() -> void:
	var ok := true
	ok = _test_pack_s32_layout() and ok
	ok = _test_pack_vec3i4_layout() and ok
	ok = _test_encode_vec3i4_writes_at_offset() and ok
	ok = _test_encode_vec3i4_with_w_and_decode() and ok
	ok = _test_decode_vec4_xyz() and ok
	ok = _test_pack_transform_mat4_layout() and ok
	ok = _test_encode_transform_mat4_writes_at_offset() and ok
	ok = _test_decode_transform_mat4_short_buffer_fallback() and ok

	if ok:
		print("[UtilsBufferUtils] ALL TESTS PASSED")
		quit(0)
	else:
		push_error("[UtilsBufferUtils] SOME TESTS FAILED")
		quit(1)


func _test_pack_s32_layout() -> bool:
	print("[UtilsBufferUtils] test_pack_s32_layout...")
	var bytes := UtilsBufferUtils.pack_s32(-123456)
	if bytes.size() != UtilsBufferUtils.SCALAR32_BYTES:
		push_error("  FAIL: expected 4 byte s32 payload")
		return false
	if bytes.decode_s32(0) != -123456:
		push_error("  FAIL: s32 payload did not round trip")
		return false
	print("  OK: int packs as s32")
	return true


func _test_pack_vec3i4_layout() -> bool:
	print("[UtilsBufferUtils] test_pack_vec3i4_layout...")
	var bytes := UtilsBufferUtils.pack_vec3i4(Vector3i(-7, 12, 4096))
	if bytes.size() != UtilsBufferUtils.IVEC4_BYTES:
		push_error("  FAIL: expected 16 byte ivec4 payload")
		return false
	if bytes.decode_s32(0) != -7 or bytes.decode_s32(4) != 12 or bytes.decode_s32(8) != 4096 or bytes.decode_s32(12) != 0:
		push_error("  FAIL: vec3i4 components were not encoded as x/y/z/0")
		return false
	print("  OK: Vector3i packs as ivec4 x/y/z/0")
	return true


func _test_encode_vec3i4_writes_at_offset() -> bool:
	print("[UtilsBufferUtils] test_encode_vec3i4_writes_at_offset...")
	var bytes := PackedByteArray()
	bytes.resize(UtilsBufferUtils.IVEC4_BYTES * 2)
	bytes.encode_s32(0, 99)
	UtilsBufferUtils.encode_vec3i4(bytes, UtilsBufferUtils.IVEC4_BYTES, Vector3i(1, 2, 3))
	if bytes.decode_s32(0) != 99:
		push_error("  FAIL: encode_vec3i4 overwrote data before offset")
		return false
	if bytes.decode_s32(16) != 1 or bytes.decode_s32(20) != 2 or bytes.decode_s32(24) != 3 or bytes.decode_s32(28) != 0:
		push_error("  FAIL: encode_vec3i4 did not write x/y/z/0 at the requested offset")
		return false
	print("  OK: encode_vec3i4 writes in place at offset")
	return true


func _test_encode_vec3i4_with_w_and_decode() -> bool:
	print("[UtilsBufferUtils] test_encode_vec3i4_with_w_and_decode...")
	var bytes := PackedByteArray()
	bytes.resize(UtilsBufferUtils.IVEC4_BYTES)
	UtilsBufferUtils.encode_vec3i4_with_w(bytes, 0, Vector3i(5, 6, 7), 99)
	if UtilsBufferUtils.decode_vec3i4(bytes) != Vector3i(5, 6, 7):
		push_error("  FAIL: vec3i4 xyz did not decode")
		return false
	if bytes.decode_s32(12) != 99:
		push_error("  FAIL: vec3i4 w slot was not encoded")
		return false
	if UtilsBufferUtils.decode_vec3i4(bytes, -1) != Vector3i.ZERO:
		push_error("  FAIL: negative vec3i4 offset should decode to zero")
		return false
	print("  OK: Vector3i encodes with custom w slot and decodes xyz")
	return true


func _test_decode_vec4_xyz() -> bool:
	print("[UtilsBufferUtils] test_decode_vec4_xyz...")
	var bytes := PackedByteArray()
	bytes.resize(UtilsBufferUtils.VEC4_BYTES)
	UtilsBufferUtils.encode_vec4(bytes, 0, Vector3(1.25, -2.5, 3.75), 99.0)
	if UtilsBufferUtils.decode_vec4_xyz(bytes) != Vector3(1.25, -2.5, 3.75):
		push_error("  FAIL: vec4 xyz did not decode")
		return false
	if UtilsBufferUtils.decode_vec4_xyz(bytes, -1) != Vector3.ZERO:
		push_error("  FAIL: negative vec4 offset should decode to zero")
		return false
	var short_bytes := PackedByteArray()
	short_bytes.resize(UtilsBufferUtils.VEC4_BYTES - 1)
	if UtilsBufferUtils.decode_vec4_xyz(short_bytes) != Vector3.ZERO:
		push_error("  FAIL: short vec4 payload should decode to zero")
		return false
	print("  OK: vec4 xyz decodes with safe fallbacks")
	return true


func _test_pack_transform_mat4_layout() -> bool:
	print("[UtilsBufferUtils] test_pack_transform_mat4_layout...")
	var transform := Transform3D(
		Basis(Vector3(1.0, 2.0, 3.0), Vector3(4.0, 5.0, 6.0), Vector3(7.0, 8.0, 9.0)),
		Vector3(10.0, 11.0, 12.0)
	)
	var bytes := UtilsBufferUtils.pack_transform_mat4(transform)
	if bytes.size() != UtilsBufferUtils.MAT4_BYTES:
		push_error("  FAIL: expected 64 byte mat4 payload")
		return false
	if not _assert_mat4_bytes(bytes, 0, transform):
		return false
	var decoded := UtilsBufferUtils.decode_transform_mat4(bytes)
	if decoded != transform:
		push_error("  FAIL: decoded transform does not match original")
		return false
	print("  OK: Transform3D packs and decodes as mat4 columns")
	return true


func _test_encode_transform_mat4_writes_at_offset() -> bool:
	print("[UtilsBufferUtils] test_encode_transform_mat4_writes_at_offset...")
	var transform := Transform3D(Basis.IDENTITY.scaled(Vector3(2.0, 3.0, 4.0)), Vector3(-1.0, -2.0, -3.0))
	var bytes := PackedByteArray()
	bytes.resize(UtilsBufferUtils.MAT4_BYTES * 2)
	bytes.encode_float(0, 99.0)
	UtilsBufferUtils.encode_transform_mat4(bytes, UtilsBufferUtils.MAT4_BYTES, transform)
	if not is_equal_approx(bytes.decode_float(0), 99.0):
		push_error("  FAIL: encode_transform_mat4 overwrote data before offset")
		return false
	if not _assert_mat4_bytes(bytes, UtilsBufferUtils.MAT4_BYTES, transform):
		return false
	if UtilsBufferUtils.decode_transform_mat4(bytes, UtilsBufferUtils.MAT4_BYTES) != transform:
		push_error("  FAIL: offset decoded transform does not match original")
		return false
	print("  OK: encode_transform_mat4 writes in place at offset")
	return true


func _test_decode_transform_mat4_short_buffer_fallback() -> bool:
	print("[UtilsBufferUtils] test_decode_transform_mat4_short_buffer_fallback...")
	var bytes := PackedByteArray()
	bytes.resize(UtilsBufferUtils.MAT4_BYTES - 1)
	if UtilsBufferUtils.decode_transform_mat4(bytes) != Transform3D.IDENTITY:
		push_error("  FAIL: short mat4 payload should decode to identity")
		return false
	print("  OK: short mat4 payload falls back to identity")
	return true


func _assert_mat4_bytes(bytes: PackedByteArray, offset: int, transform: Transform3D) -> bool:
	var checks := [
		[offset + 0, transform.basis.x.x],
		[offset + 4, transform.basis.x.y],
		[offset + 8, transform.basis.x.z],
		[offset + 12, 0.0],
		[offset + 16, transform.basis.y.x],
		[offset + 20, transform.basis.y.y],
		[offset + 24, transform.basis.y.z],
		[offset + 28, 0.0],
		[offset + 32, transform.basis.z.x],
		[offset + 36, transform.basis.z.y],
		[offset + 40, transform.basis.z.z],
		[offset + 44, 0.0],
		[offset + 48, transform.origin.x],
		[offset + 52, transform.origin.y],
		[offset + 56, transform.origin.z],
		[offset + 60, 1.0],
	]
	for check in checks:
		var byte_offset := int(check[0])
		var expected := float(check[1])
		if not is_equal_approx(bytes.decode_float(byte_offset), expected):
			push_error("  FAIL: mat4 float at byte %d expected %.3f got %.3f" % [byte_offset, expected, bytes.decode_float(byte_offset)])
			return false
	return true
