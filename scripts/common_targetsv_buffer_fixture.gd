@tool
extends RefCounted


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
	visual.resize(voxel_count * 16)
	collision.resize(voxel_count * 4)

	for i in range(voxel_count):
		var base := i * 16
		visual.encode_float(base + 0, float(i) / 10.0)
		visual.encode_float(base + 4, float(i + 1) / 10.0)
		visual.encode_float(base + 8, float(i + 2) / 10.0)
		visual.encode_float(base + 12, visual_alpha)
		collision.encode_float(i * 4, base_collision)

	if strong_collision_idx >= 0 and strong_collision_idx < voxel_count:
		collision.encode_float(strong_collision_idx * 4, strong_collision)

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
	}
