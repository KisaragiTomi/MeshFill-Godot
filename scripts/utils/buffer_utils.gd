@tool
extends RefCounted

const SCALAR32_BYTES := 4
const VEC4_BYTES := 16
const IVEC4_BYTES := 16
const MAT4_BYTES := 64


static func decode_float_buffer(bytes: PackedByteArray, expected_size: int) -> PackedFloat32Array:
	var expected_count := maxi(expected_size, 0)
	var expected_bytes := expected_count * SCALAR32_BYTES
	if bytes.size() < expected_bytes:
		push_error("BufferUtils.decode_float_buffer: 回读字节数不足 期望 %d 实际 %d（expected_size=%d）—— 解码结果不可信,拒绝零填充" % [expected_bytes, bytes.size(), expected_count])
		assert(false, "BufferUtils.decode_float_buffer: short read")
		return PackedFloat32Array()
	var values := bytes.slice(0, expected_bytes).to_float32_array()
	values.resize(expected_count)
	return values


static func decode_u32_buffer(bytes: PackedByteArray, expected_size: int) -> PackedInt32Array:
	var expected_count := maxi(expected_size, 0)
	var expected_bytes := expected_count * SCALAR32_BYTES
	if bytes.size() < expected_bytes:
		push_error("BufferUtils.decode_u32_buffer: 回读字节数不足 期望 %d 实际 %d（expected_size=%d）—— 解码结果不可信,拒绝零填充" % [expected_bytes, bytes.size(), expected_count])
		assert(false, "BufferUtils.decode_u32_buffer: short read")
		return PackedInt32Array()
	var values := bytes.slice(0, expected_bytes).to_int32_array()
	values.resize(expected_count)
	return values


static func decode_u32_count(bytes: PackedByteArray) -> int:
	if bytes.size() < SCALAR32_BYTES:
		push_error("BufferUtils.decode_u32_count: count 缓冲回读不足 4 字节 实际 %d —— 计数不可信,拒绝按 0 继续" % bytes.size())
		assert(false, "BufferUtils.decode_u32_count: short read")
		return 0
	return int(bytes.decode_u32(0))


## “count 缓冲回读 → decode_u32_count → clampi 到容量 → 按 stride 回读记录缓冲”
## 四步块的共享实现（原 voxel_placement_generator 内三处逐字重复）。
## 语义逐字保持原站点：
##   count        = clampi(decode_u32_count(count_bytes), 0, capacity)
##   record_count = count * records_per_count
##   record_bytes = rd.buffer_get_data(record_buffer, 0, maxi(record_count, 0) * byte_stride)
## count_read_bytes <= 0 ⟹ 整读 count 缓冲（保持原 `buffer_get_data(buf)` 调用形态，
## 回读字节统计口径不变）；> 0 ⟹ 只读前 count_read_bytes 字节（原站点的 `, 0, 4` 形态）。
## `maxi(record_count, 0)` 在 capacity >= 0 时是恒等变换（本仓所有 capacity 均由
## maxi(...,1) / 非负乘积得出）；仅在退化的负 capacity 下把「负长度回读」压成 0 长度。
## 本函数不持有任何跨调用状态（纯回读，无缓存），因此没有失效条件。
## 返回 {"count", "record_count", "record_bytes", "readback_bytes"}；
## readback_bytes = count 字节数 + 记录字节数，供调用方的回读字节统计累加。
static func read_records_by_count(
	rd: RenderingDevice,
	count_buffer: RID,
	record_buffer: RID,
	byte_stride: int,
	capacity: int,
	records_per_count: int = 1,
	count_read_bytes: int = 0
) -> Dictionary:
	var count_bytes: PackedByteArray
	if count_read_bytes <= 0:
		count_bytes = rd.buffer_get_data(count_buffer)
	else:
		count_bytes = rd.buffer_get_data(count_buffer, 0, count_read_bytes)
	var raw_count := decode_u32_count(count_bytes)
	# GPU 侧 append 一律 atomicAdd 后再 `if (idx < cap)` 才写；计数超出容量 ⟹ 已有记录被丢弃，
	# 原先的 clampi 会把「溢出丢数据」伪装成「刚好装满」。不再钳回容量继续。
	if raw_count > capacity:
		push_error("BufferUtils.read_records_by_count: GPU 计数 %d 超出缓冲容量 %d（stride=%d, records_per_count=%d）—— 记录已在着色器侧被丢弃,结果不完整" % [raw_count, capacity, byte_stride, records_per_count])
		assert(false, "BufferUtils.read_records_by_count: gpu count overflow")
		return {
			"count": 0,
			"record_count": 0,
			"record_bytes": PackedByteArray(),
			"readback_bytes": count_bytes.size(),
		}
	if raw_count < 0:
		push_error("BufferUtils.read_records_by_count: GPU 计数为负 %d —— count 缓冲内容不可信" % raw_count)
		assert(false, "BufferUtils.read_records_by_count: negative gpu count")
		return {
			"count": 0,
			"record_count": 0,
			"record_bytes": PackedByteArray(),
			"readback_bytes": count_bytes.size(),
		}
	var count := raw_count
	var record_count := count * records_per_count
	var requested_bytes := record_count * byte_stride
	var record_bytes := rd.buffer_get_data(record_buffer, 0, requested_bytes)
	if record_bytes.size() < requested_bytes:
		push_error("BufferUtils.read_records_by_count: 记录缓冲回读不足 期望 %d 字节 实际 %d（count=%d, stride=%d）" % [requested_bytes, record_bytes.size(), count, byte_stride])
		assert(false, "BufferUtils.read_records_by_count: short record read")
		return {
			"count": 0,
			"record_count": 0,
			"record_bytes": PackedByteArray(),
			"readback_bytes": count_bytes.size() + record_bytes.size(),
		}
	return {
		"count": count,
		"record_count": record_count,
		"record_bytes": record_bytes,
		"readback_bytes": count_bytes.size() + record_bytes.size(),
	}


static func decoded_record_count(bytes: PackedByteArray, expected_count: int, byte_stride: int) -> int:
	# 非正 stride 永远拼不出一条完整记录 —— 这是调用方的布局错误，不是「本次没有记录」。
	if byte_stride <= 0:
		push_error("BufferUtils.decoded_record_count: byte_stride 非正 %d（expected_count=%d）—— 记录布局错误" % [byte_stride, expected_count])
		assert(false, "BufferUtils.decoded_record_count: non-positive stride")
		return 0
	var expected_bytes := maxi(expected_count, 0) * byte_stride
	if bytes.size() < expected_bytes:
		push_error("BufferUtils.decoded_record_count: 记录字节数不足 期望 %d 实际 %d（expected_count=%d, stride=%d）—— 拒绝按较短长度解码" % [expected_bytes, bytes.size(), expected_count, byte_stride])
		assert(false, "BufferUtils.decoded_record_count: short read")
		return 0
	return maxi(expected_count, 0)


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
		push_error("BufferUtils.decode_vec3i4: 偏移越界 offset=%d 需要 %d 字节 实际 %d —— 拒绝返回零向量" % [offset, IVEC4_BYTES, bytes.size()])
		assert(false, "BufferUtils.decode_vec3i4: out of range")
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
		push_error("BufferUtils.decode_vec4_xyz: 偏移越界 offset=%d 需要 %d 字节 实际 %d —— 拒绝返回零向量" % [offset, VEC4_BYTES, bytes.size()])
		assert(false, "BufferUtils.decode_vec4_xyz: out of range")
		return Vector3.ZERO
	return Vector3(
		bytes.decode_float(offset + 0),
		bytes.decode_float(offset + 4),
		bytes.decode_float(offset + 8)
	)


static func decode_vec4(bytes: PackedByteArray, offset: int = 0) -> Vector4:
	if offset < 0 or bytes.size() < offset + VEC4_BYTES:
		push_error("BufferUtils.decode_vec4: 偏移越界 offset=%d 需要 %d 字节 实际 %d —— 拒绝返回零向量" % [offset, VEC4_BYTES, bytes.size()])
		assert(false, "BufferUtils.decode_vec4: out of range")
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
		push_error("BufferUtils.decode_transform_mat4: 偏移越界 offset=%d 需要 %d 字节 实际 %d —— 拒绝返回单位矩阵" % [offset, MAT4_BYTES, bytes.size()])
		assert(false, "BufferUtils.decode_transform_mat4: out of range")
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


