@tool
extends RefCounted


static func _quantize_unorm8(value: float) -> int:
	return clampi(int(round(clampf(value, 0.0, 1.0) * 255.0)), 0, 255)


static func _pack_rgba8_word(color: Color) -> int:
	var r := _quantize_unorm8(color.r)
	var g := _quantize_unorm8(color.g)
	var b := _quantize_unorm8(color.b)
	var a := _quantize_unorm8(color.a)
	return ((r & 0xFF) << 24) | ((g & 0xFF) << 16) | ((b & 0xFF) << 8) | (a & 0xFF)


static func make_linear_read_buffers(
	tex_size: int = 2,
	slice_count: int = 2,
	visual_alpha: float = 0.25,
	base_collision: float = 0.1,
	strong_collision_idx: int = 5,
	strong_collision: float = 0.8
) -> Dictionary:
	var voxel_count := maxi(tex_size, 0) * maxi(tex_size, 0) * maxi(slice_count, 0)
	var visual := PackedByteArray()
	var collision := PackedByteArray()
	visual.resize(voxel_count * 4)
	collision.resize(voxel_count)

	for i in range(voxel_count):
		visual.encode_u32(i * 4, _pack_rgba8_word(Color(
			float(i) / 10.0,
			float(i + 1) / 10.0,
			float(i + 2) / 10.0,
			visual_alpha
		)))
		collision[i] = _quantize_unorm8(base_collision)

	if strong_collision_idx >= 0 and strong_collision_idx < voxel_count:
		collision[strong_collision_idx] = _quantize_unorm8(strong_collision)

	return {
		"tex_size": tex_size,
		"slice_count": slice_count,
		"voxel_count": voxel_count,
		"visual": visual,
		"collision": collision,
		"strong_collision_idx": strong_collision_idx,
		"strong_collision": strong_collision,
		"visual_alpha": visual_alpha,
		"base_collision": base_collision,
		"visual_format": "rgba8",
		"collision_format": "r8_unorm",
	}
