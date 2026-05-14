class_name AutoObjectSdfStamp
extends Resource

@export var stamp_id: String = ""
@export var resolution: Vector2i = Vector2i(33, 33)
@export var world_size: Vector2 = Vector2(4.0, 4.0)
@export var values: PackedFloat32Array = PackedFloat32Array()
@export var alpha: PackedFloat32Array = PackedFloat32Array()


func is_valid_stamp() -> bool:
	return resolution.x > 0 and resolution.y > 0 and values.size() == resolution.x * resolution.y


func get_world_size() -> Vector2:
	return Vector2(maxf(world_size.x, 0.001), maxf(world_size.y, 0.001))


func sample_uv(uv: Vector2) -> Vector2:
	if not is_valid_stamp():
		return Vector2.ZERO
	if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
		return Vector2.ZERO

	var px := uv.x * float(resolution.x - 1)
	var py := uv.y * float(resolution.y - 1)
	var x0 := clampi(int(floor(px)), 0, resolution.x - 1)
	var y0 := clampi(int(floor(py)), 0, resolution.y - 1)
	var x1 := clampi(x0 + 1, 0, resolution.x - 1)
	var y1 := clampi(y0 + 1, 0, resolution.y - 1)
	var tx := px - float(x0)
	var ty := py - float(y0)

	var v00 := _sample_value(x0, y0)
	var v10 := _sample_value(x1, y0)
	var v01 := _sample_value(x0, y1)
	var v11 := _sample_value(x1, y1)
	var a00 := _sample_alpha(x0, y0)
	var a10 := _sample_alpha(x1, y0)
	var a01 := _sample_alpha(x0, y1)
	var a11 := _sample_alpha(x1, y1)

	var v0 := lerpf(v00, v10, tx)
	var v1 := lerpf(v01, v11, tx)
	var a0 := lerpf(a00, a10, tx)
	var a1 := lerpf(a01, a11, tx)
	return Vector2(lerpf(v0, v1, ty), lerpf(a0, a1, ty))


func set_samples(size: Vector2i, world_size_value: Vector2, value_samples: PackedFloat32Array, alpha_samples: PackedFloat32Array) -> void:
	resolution = Vector2i(maxi(size.x, 1), maxi(size.y, 1))
	world_size = Vector2(maxf(world_size_value.x, 0.001), maxf(world_size_value.y, 0.001))
	var count := resolution.x * resolution.y
	values = value_samples
	alpha = alpha_samples
	values.resize(count)
	alpha.resize(count)


func _sample_value(x: int, y: int) -> float:
	return clampf(values[_sample_index(x, y)], 0.0, 1.0)


func _sample_alpha(x: int, y: int) -> float:
	if alpha.size() != resolution.x * resolution.y:
		return 1.0
	return clampf(alpha[_sample_index(x, y)], 0.0, 1.0)


func _sample_index(x: int, y: int) -> int:
	return clampi(y, 0, resolution.y - 1) * resolution.x + clampi(x, 0, resolution.x - 1)


static func create_radial(
	stamp_id_value: String,
	size: Vector2i,
	world_size_value: Vector2,
	radius: float,
	feather: float,
	strength: float = 1.0
) -> Resource:
	var stamp := new()
	stamp.stamp_id = stamp_id_value
	var res := Vector2i(maxi(size.x, 1), maxi(size.y, 1))
	var count := res.x * res.y
	var value_samples := PackedFloat32Array()
	var alpha_samples := PackedFloat32Array()
	value_samples.resize(count)
	alpha_samples.resize(count)
	var stamp_world_size := Vector2(maxf(world_size_value.x, 0.001), maxf(world_size_value.y, 0.001))
	var edge := maxf(feather, 0.001)
	var idx := 0
	for y in range(res.y):
		for x in range(res.x):
			var uv := Vector2((float(x) + 0.5) / float(res.x), (float(y) + 0.5) / float(res.y))
			var local := (uv - Vector2(0.5, 0.5)) * stamp_world_size
			var d := local.length()
			var mask := _soft_distance_mask(d, radius, edge)
			value_samples[idx] = clampf(strength * mask, 0.0, 1.0)
			alpha_samples[idx] = mask
			idx += 1
	stamp.set_samples(res, stamp_world_size, value_samples, alpha_samples)
	return stamp


static func create_box(
	stamp_id_value: String,
	size: Vector2i,
	world_size_value: Vector2,
	half_extents: Vector2,
	feather: float,
	strength: float = 1.0
) -> Resource:
	var stamp := new()
	stamp.stamp_id = stamp_id_value
	var res := Vector2i(maxi(size.x, 1), maxi(size.y, 1))
	var count := res.x * res.y
	var value_samples := PackedFloat32Array()
	var alpha_samples := PackedFloat32Array()
	value_samples.resize(count)
	alpha_samples.resize(count)
	var stamp_world_size := Vector2(maxf(world_size_value.x, 0.001), maxf(world_size_value.y, 0.001))
	var edge := maxf(feather, 0.001)
	var idx := 0
	for y in range(res.y):
		for x in range(res.x):
			var uv := Vector2((float(x) + 0.5) / float(res.x), (float(y) + 0.5) / float(res.y))
			var local := (uv - Vector2(0.5, 0.5)) * stamp_world_size
			var q := Vector2(absf(local.x), absf(local.y)) - half_extents
			var outside := Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length()
			var inside := minf(maxf(q.x, q.y), 0.0)
			var d := outside + inside
			var mask := _soft_distance_mask(d, 0.0, edge)
			value_samples[idx] = clampf(strength * mask, 0.0, 1.0)
			alpha_samples[idx] = mask
			idx += 1
	stamp.set_samples(res, stamp_world_size, value_samples, alpha_samples)
	return stamp


static func _soft_distance_mask(distance_value: float, hard_radius: float, feather: float) -> float:
	if distance_value <= hard_radius:
		return 1.0
	if distance_value >= hard_radius + feather:
		return 0.0
	var t := 1.0 - (distance_value - hard_radius) / feather
	return clampf(t * t * (3.0 - 2.0 * t), 0.0, 1.0)
