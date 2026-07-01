class_name VoxelFootprintBaker

## 资产 footprint(占位体)烘焙子系统(从 VoxelPlacementGenerator 抽出)。
## box/cylinder/point footprint 的 CPU 与 GPU 烘焙、Y 轴旋转、去重、批量旋转烘焙。
## 自带 footprint compute shader，自洽(GPU 实例方法各自 ensure_device)，无生成器实例状态耦合。
extends "res://scripts/godot_compute_shader_base.gd"

const UtilsBufferUtils := preload("res://scripts/utils_buffer_utils.gd")

const FOOTPRINT_CAPACITY := 128
const RECORD_STRIDE := 4
const FLAG_SUPPORT := 1
const FLAG_CLEARANCE := 2
const BOX_FOOTPRINT_BAKE_SHADER_PATH := "res://shaders/bake_box_footprint.glsl"
const BOX_FOOTPRINT_BAKE_LOCAL_SIZE := 64
const CYLINDER_FOOTPRINT_BAKE_SHADER_PATH := "res://shaders/bake_cylinder_footprint.glsl"
const CYLINDER_FOOTPRINT_BAKE_LOCAL_SIZE := 64
const ROTATE_FOOTPRINT_Y_SHADER_PATH := "res://shaders/rotate_footprint_y.glsl"
const ROTATE_FOOTPRINT_Y_LOCAL_SIZE := 64

## --- 复制自 generator 的值解析辅助 ---


static func _vector3_from_value(value, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	if value is Vector3:
		return value as Vector3
	if value is Array:
		var arr := value as Array
		if arr.size() >= 3:
			return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
	if value is Dictionary:
		var d := value as Dictionary
		return Vector3(float(d.get("x", fallback.x)), float(d.get("y", fallback.y)), float(d.get("z", fallback.z)))
	return fallback





# ---------------------------------------------------------------------------
# Instantiation - create AutoObject nodes from GPU placement results
# ---------------------------------------------------------------------------
# node_class: all classes create AutoObject (AutoObject for heightfield objects, AutoObject for generic objects).




func _pack_footprint(footprint: Array) -> Dictionary:
	var pos_bytes := PackedByteArray()
	var weight_bytes := PackedByteArray()
	pos_bytes.resize(footprint.size() * UtilsBufferUtils.IVEC4_BYTES)
	weight_bytes.resize(footprint.size() * UtilsBufferUtils.IVEC4_BYTES)

	for i in range(footprint.size()):
		var entry: Dictionary = footprint[i]
		var local_pos: Vector3i = entry.get("local_pos", Vector3i.ZERO)
		var collision_q8 := clampi(roundi(clampf(float(entry.get("collision_strength", 0.0)), 0.0, 1.0) * 255.0), 0, 255)
		var flags := int(entry.get("flags", 0))
		var weight := maxf(float(entry.get("weight", 1.0)), 0.0)
		var pos_offset := i * UtilsBufferUtils.IVEC4_BYTES
		UtilsBufferUtils.encode_vec3i4_with_w(pos_bytes, pos_offset, local_pos, collision_q8)
		weight_bytes.encode_float(pos_offset + 0, weight)
		weight_bytes.encode_float(pos_offset + 4, float(flags))
		weight_bytes.encode_float(pos_offset + 8, float(entry.get("radius", 0.0)))
		weight_bytes.encode_float(pos_offset + 12, 0.0)
	return {
		"pos_bytes": pos_bytes,
		"weight_bytes": weight_bytes,
	}



## 创建一个用于 GPU footprint 烘焙的实例(静态入口内部用)。
static func _new_baker():
	return load("res://scripts/voxel_footprint_baker.gd").new()

## --- 迁移自 generator 的 footprint 函数 ---
static func bake_footprint_from_collision(
	collision_layers: Array,
	voxel_size: Vector3,
	add_support: bool = true,
	clearance_slices: int = 1,
	prefer_gpu: bool = true
) -> Array[Dictionary]:
	var combined: Array[Dictionary] = []
	var point_samples: Array[Dictionary] = []
	for cv in collision_layers:
		if not cv is Dictionary:
			continue
		var collision_entry := cv as Dictionary
		if _is_point_collision_sample(collision_entry):
			point_samples.append(collision_entry)
			continue
		var shape := str(collision_entry.get("shape", "cylinder")).to_lower()
		if prefer_gpu:
			var gpu_result := _bake_footprint_entry_gpu(
				collision_entry,
				shape,
				voxel_size,
				add_support,
				clearance_slices
			)
			if bool(gpu_result.get("ok", false)):
				combined.append_array(gpu_result.get("footprint", []))
				continue
			push_error("VoxelPlacementGenerator: GPU footprint bake blocked for %s: %s" % [
				shape,
				str(gpu_result.get("reason", "unknown")),
			])
			return []
		if shape == "cylinder":
			combined.append_array(_bake_cylinder(collision_entry, voxel_size, add_support, clearance_slices))
		elif shape == "box" or shape == "cube":
			combined.append_array(_bake_box(collision_entry, voxel_size, add_support, clearance_slices))
	if not point_samples.is_empty():
		combined.append_array(_bake_point_collision(point_samples, add_support, clearance_slices))
	var result := _deduplicate_footprint(combined)
	if result.size() > FOOTPRINT_CAPACITY:
		push_warning("VoxelPlacementGenerator: footprint has %d voxels, truncating to %d" % [
			result.size(), FOOTPRINT_CAPACITY])
		result.resize(FOOTPRINT_CAPACITY)
	return result



static func bake_box_footprint_gpu(
	collision_entry: Dictionary,
	voxel_size: Vector3,
	add_support: bool = true,
	clearance_slices: int = 1
) -> Dictionary:
	var generator = _new_baker()
	return generator._bake_box_footprint_gpu(collision_entry, voxel_size, add_support, clearance_slices)



static func bake_cylinder_footprint_gpu(
	collision_entry: Dictionary,
	voxel_size: Vector3,
	add_support: bool = true,
	clearance_slices: int = 1
) -> Dictionary:
	var generator = _new_baker()
	return generator._bake_cylinder_footprint_gpu(collision_entry, voxel_size, add_support, clearance_slices)



static func _bake_footprint_entry_gpu(
	collision_entry: Dictionary,
	shape: String,
	voxel_size: Vector3,
	add_support: bool,
	clearance_slices: int
) -> Dictionary:
	var generator = _new_baker()
	if shape == "cylinder":
		return generator._bake_cylinder_footprint_gpu(collision_entry, voxel_size, add_support, clearance_slices)
	if shape == "box" or shape == "cube":
		return generator._bake_box_footprint_gpu(collision_entry, voxel_size, add_support, clearance_slices)
	return {
		"ok": false,
		"reason": "unsupported_shape",
		"gpu_first": true,
		"cpu_fallback": false,
	}



func _bake_box_footprint_gpu(
	collision_entry: Dictionary,
	voxel_size: Vector3,
	add_support: bool,
	clearance_slices: int
) -> Dictionary:
	if collision_entry.is_empty():
		return _box_footprint_gpu_blocked("missing_collision_entry")
	var shape := str(collision_entry.get("shape", "box")).to_lower()
	if shape != "box" and shape != "cube":
		return _box_footprint_gpu_blocked("unsupported_shape")
	if voxel_size.x <= 0.0 or voxel_size.y <= 0.0 or voxel_size.z <= 0.0:
		return _box_footprint_gpu_blocked("invalid_voxel_size")

	var bounds := _box_footprint_voxel_bounds(collision_entry, voxel_size)
	var x_min_v := int(bounds.get("x_min", 0))
	var x_max_v := int(bounds.get("x_max", -1))
	var y_min_v := int(bounds.get("y_min", 0))
	var y_max_v := int(bounds.get("y_max", -1))
	var z_min_v := int(bounds.get("z_min", 0))
	var z_max_v := int(bounds.get("z_max", -1))
	var dim_x := x_max_v - x_min_v + 1
	var dim_y := y_max_v - y_min_v + 1
	var dim_z := z_max_v - z_min_v + 1
	if dim_x <= 0 or dim_y <= 0 or dim_z <= 0:
		return _box_footprint_gpu_blocked("empty_box_bounds")

	var solid_count := dim_x * dim_y * dim_z
	var clear_slices := maxi(clearance_slices, 0)
	var clearance_count := dim_x * clear_slices * dim_z
	var total_count := solid_count + clearance_count
	var write_count := mini(total_count, FOOTPRINT_CAPACITY)
	if write_count <= 0:
		return _box_footprint_gpu_blocked("empty_footprint")

	log_name = "VoxelPlacementBoxFootprintBake"
	sync_global_device = false
	if not ensure_device(true, false):
		dispose()
		return _box_footprint_gpu_blocked("missing_rendering_device", total_count, write_count)

	var shader := load_compute_shader(BOX_FOOTPRINT_BAKE_SHADER_PATH)
	var pipeline := create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		dispose()
		return _box_footprint_gpu_blocked("box_footprint_shader_not_ready", total_count, write_count)

	var pos_buffer := storage_buffer_zero(write_count * 16, SCOPE_FRAME, "box_footprint_pos_strength_i32x4")
	var weight_buffer := storage_buffer_zero(write_count * 16, SCOPE_FRAME, "box_footprint_weight_flags_f32x4")
	if not pos_buffer.is_valid() or not weight_buffer.is_valid():
		dispose()
		return _box_footprint_gpu_blocked("box_footprint_buffer_create_failed", total_count, write_count)

	var set0 := create_uniform_set([
		make_storage_uniform(0, pos_buffer),
		make_storage_uniform(1, weight_buffer),
	], shader, 0, SCOPE_PASS, "box_footprint_bake_set0")
	if not set0.is_valid():
		dispose()
		return _box_footprint_gpu_blocked("box_footprint_uniform_set_failed", total_count, write_count)

	var push := PackedByteArray()
	push.resize(80)
	push.encode_s32(0, x_min_v)
	push.encode_s32(4, y_min_v)
	push.encode_s32(8, z_min_v)
	push.encode_s32(12, solid_count)
	push.encode_s32(16, dim_x)
	push.encode_s32(20, dim_y)
	push.encode_s32(24, dim_z)
	push.encode_s32(28, 1 if add_support else 0)
	push.encode_s32(32, x_min_v)
	push.encode_s32(36, y_max_v + 1)
	push.encode_s32(40, z_min_v)
	push.encode_s32(44, clearance_count)
	push.encode_s32(48, dim_x)
	push.encode_s32(52, clear_slices)
	push.encode_s32(56, dim_z)
	push.encode_s32(60, write_count)
	push.encode_float(64, clampf(float(collision_entry.get("collision_strength", 1.0)), 0.0, 1.0))
	push.encode_float(68, 1.0)
	push.encode_float(72, 0.5)
	push.encode_float(76, 0.0)

	var groups := dispatch_groups_1d(write_count, BOX_FOOTPRINT_BAKE_LOCAL_SIZE)
	var cl := begin_compute_list()
	if cl < 0:
		dispose()
		return _box_footprint_gpu_blocked("box_footprint_compute_list_begin_failed", total_count, write_count)
	_rd.compute_list_bind_compute_pipeline(cl, pipeline)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, groups.x, 1, 1)
	end_compute_list()
	submit_and_sync()

	var pos_bytes := _rd.buffer_get_data(pos_buffer, 0, write_count * 16)
	var weight_bytes := _rd.buffer_get_data(weight_buffer, 0, write_count * 16)
	dispose()
	if pos_bytes.size() != write_count * 16 or weight_bytes.size() != write_count * 16:
		return _box_footprint_gpu_blocked("box_footprint_readback_failed", total_count, write_count)

	return {
		"ok": true,
		"reason": "ok",
		"gpu_first": true,
		"cpu_fallback": false,
		"shape": shape,
		"voxel_size": voxel_size,
		"bounds_min": Vector3i(x_min_v, y_min_v, z_min_v),
		"bounds_max": Vector3i(x_max_v, y_max_v, z_max_v),
		"solid_count": solid_count,
		"clearance_count": clearance_count,
		"total_generated_count": total_count,
		"footprint_count": write_count,
		"output_capacity": FOOTPRINT_CAPACITY,
		"truncated": total_count > write_count,
		"pos_strength_format": "ivec4(x,y,z,collision_q8)",
		"weight_flags_format": "vec4(weight,flags,radius,pad)",
		"pos_strength_stride_bytes": 16,
		"weight_flags_stride_bytes": 16,
		"local_size_x": BOX_FOOTPRINT_BAKE_LOCAL_SIZE,
		"dispatch_groups": groups,
		"pos_bytes": pos_bytes,
		"weight_bytes": weight_bytes,
		"footprint": _decode_gpu_footprint_buffers(pos_bytes, weight_bytes, write_count),
		"readback_source": "bake_box_footprint_compute",
	}



func _bake_cylinder_footprint_gpu(
	collision_entry: Dictionary,
	voxel_size: Vector3,
	add_support: bool,
	clearance_slices: int
) -> Dictionary:
	if collision_entry.is_empty():
		return _cylinder_footprint_gpu_blocked("missing_collision_entry")
	var shape := str(collision_entry.get("shape", "cylinder")).to_lower()
	if shape != "cylinder":
		return _cylinder_footprint_gpu_blocked("unsupported_shape")
	if voxel_size.x <= 0.0 or voxel_size.y <= 0.0 or voxel_size.z <= 0.0:
		return _cylinder_footprint_gpu_blocked("invalid_voxel_size")

	var radius := maxf(float(collision_entry.get("radius", 1.0)), 0.01)
	var y_min := float(collision_entry.get("y_min", 0.0))
	var y_max := maxf(float(collision_entry.get("y_max", 2.0)), y_min + 0.01)
	var center := _vector3_from_value(
		collision_entry.get("offset", collision_entry.get("center", collision_entry.get("position", Vector3.ZERO))),
		Vector3.ZERO
	)
	var r_vx := ceili(radius / voxel_size.x)
	var r_vz := ceili(radius / voxel_size.z)
	var center_x_v := roundi(center.x / voxel_size.x)
	var center_z_v := roundi(center.z / voxel_size.z)
	var y_min_v := floori((center.y + y_min) / voxel_size.y)
	var y_max_v := ceili((center.y + y_max) / voxel_size.y)
	var solid_y_count := y_max_v - y_min_v + 1
	var x_count := r_vx * 2 + 1
	var z_count := r_vz * 2 + 1
	if solid_y_count <= 0 or x_count <= 0 or z_count <= 0:
		return _cylinder_footprint_gpu_blocked("empty_cylinder_bounds")

	var clear_slices := maxi(clearance_slices, 0)
	var solid_candidate_count := solid_y_count * x_count * z_count
	var clearance_candidate_count := clear_slices * x_count * z_count
	var candidate_count := solid_candidate_count + clearance_candidate_count
	var output_capacity := mini(candidate_count, FOOTPRINT_CAPACITY)
	if output_capacity <= 0:
		return _cylinder_footprint_gpu_blocked("empty_footprint")

	log_name = "VoxelPlacementCylinderFootprintBake"
	sync_global_device = false
	if not ensure_device(true, false):
		dispose()
		return _cylinder_footprint_gpu_blocked("missing_rendering_device", candidate_count, 0, output_capacity)

	var shader := load_compute_shader(CYLINDER_FOOTPRINT_BAKE_SHADER_PATH)
	var pipeline := create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		dispose()
		return _cylinder_footprint_gpu_blocked("cylinder_footprint_shader_not_ready", candidate_count, 0, output_capacity)

	var pos_buffer := storage_buffer_zero(output_capacity * 16, SCOPE_FRAME, "cylinder_footprint_pos_strength_i32x4")
	var weight_buffer := storage_buffer_zero(output_capacity * 16, SCOPE_FRAME, "cylinder_footprint_weight_flags_f32x4")
	var stats_buffer := storage_buffer_zero(4, SCOPE_FRAME, "cylinder_footprint_stats_u32")
	if not pos_buffer.is_valid() or not weight_buffer.is_valid() or not stats_buffer.is_valid():
		dispose()
		return _cylinder_footprint_gpu_blocked("cylinder_footprint_buffer_create_failed", candidate_count, 0, output_capacity)

	var set0 := create_uniform_set([
		make_storage_uniform(0, pos_buffer),
		make_storage_uniform(1, weight_buffer),
		make_storage_uniform(2, stats_buffer),
	], shader, 0, SCOPE_PASS, "cylinder_footprint_bake_set0")
	if not set0.is_valid():
		dispose()
		return _cylinder_footprint_gpu_blocked("cylinder_footprint_uniform_set_failed", candidate_count, 0, output_capacity)

	var push := PackedByteArray()
	push.resize(96)
	push.encode_s32(0, center_x_v)
	push.encode_s32(4, center_z_v)
	push.encode_s32(8, r_vx)
	push.encode_s32(12, r_vz)
	push.encode_s32(16, y_min_v)
	push.encode_s32(20, solid_y_count)
	push.encode_s32(24, y_max_v + 1)
	push.encode_s32(28, clear_slices)
	push.encode_s32(32, x_count)
	push.encode_s32(36, z_count)
	push.encode_s32(40, solid_candidate_count)
	push.encode_s32(44, candidate_count)
	push.encode_s32(48, output_capacity)
	push.encode_s32(52, 1 if add_support else 0)
	push.encode_s32(56, 0)
	push.encode_s32(60, 0)
	push.encode_float(64, voxel_size.x)
	push.encode_float(68, voxel_size.z)
	push.encode_float(72, radius * radius)
	push.encode_float(76, clampf(float(collision_entry.get("collision_strength", 1.0)), 0.0, 1.0))
	push.encode_float(80, 1.0)
	push.encode_float(84, 0.5)
	push.encode_float(88, 0.0)
	push.encode_float(92, 0.0)

	var groups := dispatch_groups_1d(candidate_count, CYLINDER_FOOTPRINT_BAKE_LOCAL_SIZE)
	var cl := begin_compute_list()
	if cl < 0:
		dispose()
		return _cylinder_footprint_gpu_blocked("cylinder_footprint_compute_list_begin_failed", candidate_count, 0, output_capacity)
	_rd.compute_list_bind_compute_pipeline(cl, pipeline)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, groups.x, 1, 1)
	end_compute_list()
	submit_and_sync()

	var stats_bytes := _rd.buffer_get_data(stats_buffer, 0, 4)
	var generated_count := int(stats_bytes.decode_u32(0)) if stats_bytes.size() >= 4 else 0
	var footprint_count := mini(generated_count, output_capacity)
	var pos_bytes := _rd.buffer_get_data(pos_buffer, 0, footprint_count * 16)
	var weight_bytes := _rd.buffer_get_data(weight_buffer, 0, footprint_count * 16)
	dispose()
	if stats_bytes.size() < 4 or pos_bytes.size() != footprint_count * 16 or weight_bytes.size() != footprint_count * 16:
		return _cylinder_footprint_gpu_blocked("cylinder_footprint_readback_failed", candidate_count, generated_count, output_capacity)

	return {
		"ok": true,
		"reason": "ok",
		"gpu_first": true,
		"cpu_fallback": false,
		"shape": shape,
		"voxel_size": voxel_size,
		"center_voxel_xz": Vector2i(center_x_v, center_z_v),
		"radius": radius,
		"radius_voxels": Vector2i(r_vx, r_vz),
		"solid_y_range": Vector2i(y_min_v, y_max_v),
		"candidate_count": candidate_count,
		"total_generated_count": generated_count,
		"footprint_count": footprint_count,
		"output_capacity": output_capacity,
		"truncated": generated_count > output_capacity,
		"pos_strength_format": "ivec4(x,y,z,collision_q8)",
		"weight_flags_format": "vec4(weight,flags,radius,pad)",
		"pos_strength_stride_bytes": 16,
		"weight_flags_stride_bytes": 16,
		"stats_format": "u32_valid_count",
		"stats_stride_bytes": 4,
		"volume_layout": "solid_y_z_x_then_clearance_y_z_x",
		"local_size_x": CYLINDER_FOOTPRINT_BAKE_LOCAL_SIZE,
		"dispatch_groups": groups,
		"pos_bytes": pos_bytes,
		"weight_bytes": weight_bytes,
		"footprint": _decode_gpu_footprint_buffers(pos_bytes, weight_bytes, footprint_count),
		"readback_source": "bake_cylinder_footprint_compute",
	}



static func _cylinder_footprint_gpu_blocked(
	reason: String,
	candidate_count: int = 0,
	generated_count: int = 0,
	output_capacity: int = 0
) -> Dictionary:
	return {
		"ok": false,
		"reason": reason,
		"gpu_first": true,
		"cpu_fallback": false,
		"candidate_count": candidate_count,
		"total_generated_count": generated_count,
		"footprint_count": mini(generated_count, output_capacity),
		"output_capacity": output_capacity,
	}



static func _box_footprint_gpu_blocked(reason: String, total_count: int = 0, write_count: int = 0) -> Dictionary:
	return {
		"ok": false,
		"reason": reason,
		"gpu_first": true,
		"cpu_fallback": false,
		"total_generated_count": total_count,
		"footprint_count": write_count,
	}



static func _box_footprint_voxel_bounds(cv: Dictionary, voxel_size: Vector3) -> Dictionary:
	var center := _vector3_from_value(cv.get("offset", cv.get("center", cv.get("position", Vector3.ZERO))), Vector3.ZERO)
	var half_extents := _vector3_from_value(cv.get("half_extents", Vector3.ZERO), Vector3.ZERO)
	var min_world: Vector3
	var max_world: Vector3
	if half_extents.length_squared() <= 0.0001:
		var size := _vector3_from_value(cv.get("size", Vector3.ZERO), Vector3.ZERO)
		if size.length_squared() > 0.0001:
			half_extents = size * 0.5
	if half_extents.length_squared() > 0.0001:
		min_world = center - half_extents
		max_world = center + half_extents
		if cv.has("y_min") or cv.has("y_max"):
			min_world.y = center.y + float(cv.get("y_min", min_world.y - center.y))
			max_world.y = center.y + float(cv.get("y_max", max_world.y - center.y))
	else:
		var radius := maxf(float(cv.get("radius", 1.0)), 0.01)
		var y_min := float(cv.get("y_min", 0.0))
		var y_max := maxf(float(cv.get("y_max", 2.0)), y_min + 0.01)
		min_world = center + Vector3(-radius, y_min, -radius)
		max_world = center + Vector3(radius, y_max, radius)
	return {
		"x_min": floori(min_world.x / voxel_size.x),
		"x_max": ceili(max_world.x / voxel_size.x),
		"y_min": floori(min_world.y / voxel_size.y),
		"y_max": ceili(max_world.y / voxel_size.y),
		"z_min": floori(min_world.z / voxel_size.z),
		"z_max": ceili(max_world.z / voxel_size.z),
	}



static func _is_point_collision_sample(collision: Dictionary) -> bool:
	return collision.has("voxel") or collision.has("local_pos") or collision.has("voxel_offset")



static func _collision_sample_position(collision: Dictionary) -> Vector3i:
	return VoxelGeneral.vector3i_from_value(collision.get("voxel", collision.get("local_pos", collision.get("voxel_offset", Vector3i.ZERO))), Vector3i.ZERO)



static func _collision_sample_strength(collision: Dictionary) -> float:
	return clampf(float(collision.get("collision_strength", 1.0)), 0.0, 1.0)



static func _bake_point_collision(
	collision_layers: Array[Dictionary],
	add_support: bool,
	clearance_slices: int
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var min_y := 2147483647
	var top_by_xz := {}
	for collision_entry in collision_layers:
		if not bool(collision_entry.get("enabled", true)):
			continue
		var local_pos := _collision_sample_position(collision_entry)
		var collision_strength := _collision_sample_strength(collision_entry)
		var flags := int(collision_entry.get("flags", 0))
		var weight := maxf(float(collision_entry.get("weight", 1.0)), 0.0)
		result.append({
			"local_pos": local_pos,
			"collision_strength": collision_strength,
			"flags": flags,
			"weight": weight,
		})
		if collision_strength <= 0.0:
			continue
		min_y = mini(min_y, local_pos.y)
		var key := "%d,%d" % [local_pos.x, local_pos.z]
		if not top_by_xz.has(key) or local_pos.y > int(top_by_xz[key].y):
			top_by_xz[key] = local_pos
	if add_support and min_y < 2147483647:
		for entry in result:
			var pos: Vector3i = entry.local_pos
			if pos.y == min_y and float(entry.collision_strength) > 0.0:
				entry["flags"] = int(entry.flags) | FLAG_SUPPORT
	if clearance_slices > 0:
		for top in top_by_xz.values():
			var pos := top as Vector3i
			for cy in range(pos.y + 1, pos.y + 1 + clearance_slices):
				result.append({
					"local_pos": Vector3i(pos.x, cy, pos.z),
					"collision_strength": 0.0,
					"flags": FLAG_CLEARANCE,
					"weight": 0.5,
				})
	return result



static func _bake_cylinder(
	cv: Dictionary,
	voxel_size: Vector3,
	add_support: bool,
	clearance_slices: int
) -> Array[Dictionary]:
	var radius := maxf(float(cv.get("radius", 1.0)), 0.01)
	var y_min := float(cv.get("y_min", 0.0))
	var y_max := maxf(float(cv.get("y_max", 2.0)), y_min + 0.01)
	var collision_strength := clampf(float(cv.get("collision_strength", 1.0)), 0.0, 1.0)
	var center := _vector3_from_value(cv.get("offset", cv.get("center", cv.get("position", Vector3.ZERO))), Vector3.ZERO)

	var r_vx := ceili(radius / voxel_size.x)
	var r_vz := ceili(radius / voxel_size.z)
	var center_x_v := roundi(center.x / voxel_size.x)
	var center_z_v := roundi(center.z / voxel_size.z)
	var y_min_v := floori((center.y + y_min) / voxel_size.y)
	var y_max_v := ceili((center.y + y_max) / voxel_size.y)
	var radius_sq := radius * radius

	var result: Array[Dictionary] = []

	for y in range(y_min_v, y_max_v + 1):
		for z in range(-r_vz, r_vz + 1):
			for x in range(-r_vx, r_vx + 1):
				var wx := float(x) * voxel_size.x
				var wz := float(z) * voxel_size.z
				if wx * wx + wz * wz > radius_sq:
					continue
				var flags := 0
				if add_support and y == y_min_v:
					flags |= FLAG_SUPPORT
				result.append({
					"local_pos": Vector3i(center_x_v + x, y, center_z_v + z),
					"collision_strength": collision_strength,
					"flags": flags,
					"weight": 1.0,
				})

	if clearance_slices > 0:
		for cy in range(y_max_v + 1, y_max_v + 1 + clearance_slices):
			for z in range(-r_vz, r_vz + 1):
				for x in range(-r_vx, r_vx + 1):
					var wx := float(x) * voxel_size.x
					var wz := float(z) * voxel_size.z
					if wx * wx + wz * wz > radius_sq:
						continue
					result.append({
						"local_pos": Vector3i(center_x_v + x, cy, center_z_v + z),
						"collision_strength": 0.0,
						"flags": FLAG_CLEARANCE,
						"weight": 0.5,
					})

	return result



static func _bake_box(
	cv: Dictionary,
	voxel_size: Vector3,
	add_support: bool,
	clearance_slices: int
) -> Array[Dictionary]:
	var center := _vector3_from_value(cv.get("offset", cv.get("center", cv.get("position", Vector3.ZERO))), Vector3.ZERO)
	var half_extents := _vector3_from_value(cv.get("half_extents", Vector3.ZERO), Vector3.ZERO)
	if half_extents.length_squared() <= 0.0001:
		var size := _vector3_from_value(cv.get("size", Vector3.ZERO), Vector3.ZERO)
		if size.length_squared() > 0.0001:
			half_extents = size * 0.5
	var min_world: Vector3
	var max_world: Vector3
	if half_extents.length_squared() > 0.0001:
		min_world = center - half_extents
		max_world = center + half_extents
		if cv.has("y_min") or cv.has("y_max"):
			min_world.y = center.y + float(cv.get("y_min", min_world.y - center.y))
			max_world.y = center.y + float(cv.get("y_max", max_world.y - center.y))
	else:
		var radius := maxf(float(cv.get("radius", 1.0)), 0.01)
		var y_min := float(cv.get("y_min", 0.0))
		var y_max := maxf(float(cv.get("y_max", 2.0)), y_min + 0.01)
		min_world = center + Vector3(-radius, y_min, -radius)
		max_world = center + Vector3(radius, y_max, radius)
	var collision_strength := clampf(float(cv.get("collision_strength", 1.0)), 0.0, 1.0)
	var x_min_v := floori(min_world.x / voxel_size.x)
	var x_max_v := ceili(max_world.x / voxel_size.x)
	var y_min_v := floori(min_world.y / voxel_size.y)
	var y_max_v := ceili(max_world.y / voxel_size.y)
	var z_min_v := floori(min_world.z / voxel_size.z)
	var z_max_v := ceili(max_world.z / voxel_size.z)
	var result: Array[Dictionary] = []
	for y in range(y_min_v, y_max_v + 1):
		for z in range(z_min_v, z_max_v + 1):
			for x in range(x_min_v, x_max_v + 1):
				var flags := 0
				if add_support and y == y_min_v:
					flags |= FLAG_SUPPORT
				result.append({
					"local_pos": Vector3i(x, y, z),
					"collision_strength": collision_strength,
					"flags": flags,
					"weight": 1.0,
				})
	if clearance_slices > 0:
		for cy in range(y_max_v + 1, y_max_v + 1 + clearance_slices):
			for z in range(z_min_v, z_max_v + 1):
				for x in range(x_min_v, x_max_v + 1):
					result.append({
						"local_pos": Vector3i(x, cy, z),
						"collision_strength": 0.0,
						"flags": FLAG_CLEARANCE,
						"weight": 0.5,
					})
	return result



static func _deduplicate_footprint(entries: Array[Dictionary]) -> Array[Dictionary]:
	var by_pos := {}
	for entry in entries:
		var pos: Vector3i = entry.get("local_pos", Vector3i.ZERO)
		var key := "%d,%d,%d" % [pos.x, pos.y, pos.z]
		if by_pos.has(key):
			var existing: Dictionary = by_pos[key]
			existing["collision_strength"] = maxf(
				float(existing.get("collision_strength", 0.0)), float(entry.get("collision_strength", 0.0)))
			existing["flags"] = int(existing.flags) | int(entry.flags)
			existing["weight"] = maxf(float(existing.weight), float(entry.weight))
		else:
			by_pos[key] = entry.duplicate()
	var result: Array[Dictionary] = []
	for entry in by_pos.values():
		result.append(entry)
	return result



static func _decode_gpu_footprint_buffers(pos_bytes: PackedByteArray, weight_bytes: PackedByteArray, count: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var available := mini(count, mini(int(pos_bytes.size() / UtilsBufferUtils.IVEC4_BYTES), int(weight_bytes.size() / UtilsBufferUtils.IVEC4_BYTES)))
	for i in range(available):
		var pos_offset := i * UtilsBufferUtils.IVEC4_BYTES
		var weight_offset := i * UtilsBufferUtils.IVEC4_BYTES
		result.append({
			"local_pos": UtilsBufferUtils.decode_vec3i4(pos_bytes, pos_offset),
			"collision_strength": clampf(float(pos_bytes.decode_s32(pos_offset + 12)) / 255.0, 0.0, 1.0),
			"flags": roundi(weight_bytes.decode_float(weight_offset + 4)),
			"weight": maxf(weight_bytes.decode_float(weight_offset + 0), 0.0),
		})
	return result


# ---------------------------------------------------------------------------
# Footprint rotation — pre-bake 24 yaw versions
# ---------------------------------------------------------------------------


static func rotate_footprint_y(
	footprint: Array[Dictionary], yaw_degrees: float
) -> Array[Dictionary]:
	if absf(yaw_degrees) < 0.01:
		var out: Array[Dictionary] = []
		for e in footprint:
			out.append(e.duplicate())
		return out
	var rad := deg_to_rad(yaw_degrees)
	var cos_r := cos(rad)
	var sin_r := sin(rad)
	var rotated: Array[Dictionary] = []
	for entry in footprint:
		var pos: Vector3i = entry.get("local_pos", Vector3i.ZERO)
		var rx := float(pos.x) * cos_r - float(pos.z) * sin_r
		var rz := float(pos.x) * sin_r + float(pos.z) * cos_r
		var new_entry := entry.duplicate()
		new_entry["local_pos"] = Vector3i(roundi(rx), pos.y, roundi(rz))
		rotated.append(new_entry)
	return _deduplicate_footprint(rotated)



static func rotate_footprint_y_gpu(footprint: Array[Dictionary], yaw_degrees: float) -> Dictionary:
	var generator = _new_baker()
	return generator._rotate_footprint_y_gpu(footprint, yaw_degrees)



func _rotate_footprint_y_gpu(footprint: Array[Dictionary], yaw_degrees: float) -> Dictionary:
	var footprint_count := footprint.size()
	if footprint_count <= 0:
		return _rotate_footprint_y_gpu_blocked("empty_footprint")

	var packed := _pack_footprint(footprint)
	var input_pos_bytes: PackedByteArray = packed.get("pos_bytes", PackedByteArray())
	var input_weight_bytes: PackedByteArray = packed.get("weight_bytes", PackedByteArray())
	if input_pos_bytes.size() != footprint_count * 16 or input_weight_bytes.size() != footprint_count * 16:
		return _rotate_footprint_y_gpu_blocked("pack_failed", footprint_count)

	log_name = "VoxelPlacementFootprintRotateY"
	sync_global_device = false
	if not ensure_device(true, false):
		dispose()
		return _rotate_footprint_y_gpu_blocked("missing_rendering_device", footprint_count)

	var shader := load_compute_shader(ROTATE_FOOTPRINT_Y_SHADER_PATH)
	var pipeline := create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		dispose()
		return _rotate_footprint_y_gpu_blocked("rotate_footprint_shader_not_ready", footprint_count)

	var pos_in_buffer := storage_buffer_from_bytes(input_pos_bytes, SCOPE_FRAME, "rotate_footprint_pos_in_i32x4")
	var weight_in_buffer := storage_buffer_from_bytes(input_weight_bytes, SCOPE_FRAME, "rotate_footprint_weight_in_f32x4")
	var pos_out_buffer := storage_buffer_zero(footprint_count * 16, SCOPE_FRAME, "rotate_footprint_pos_out_i32x4")
	var weight_out_buffer := storage_buffer_zero(footprint_count * 16, SCOPE_FRAME, "rotate_footprint_weight_out_f32x4")
	if (
		not pos_in_buffer.is_valid()
		or not weight_in_buffer.is_valid()
		or not pos_out_buffer.is_valid()
		or not weight_out_buffer.is_valid()
	):
		dispose()
		return _rotate_footprint_y_gpu_blocked("rotate_footprint_buffer_create_failed", footprint_count)

	var set0 := create_uniform_set([
		make_storage_uniform(0, pos_in_buffer),
		make_storage_uniform(1, weight_in_buffer),
		make_storage_uniform(2, pos_out_buffer),
		make_storage_uniform(3, weight_out_buffer),
	], shader, 0, SCOPE_PASS, "rotate_footprint_y_set0")
	if not set0.is_valid():
		dispose()
		return _rotate_footprint_y_gpu_blocked("rotate_footprint_uniform_set_failed", footprint_count)

	var radians := deg_to_rad(yaw_degrees)
	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, footprint_count)
	push.encode_float(4, cos(radians))
	push.encode_float(8, sin(radians))
	push.encode_float(12, 0.0)

	var groups := dispatch_groups_1d(footprint_count, ROTATE_FOOTPRINT_Y_LOCAL_SIZE)
	var cl := begin_compute_list()
	if cl < 0:
		dispose()
		return _rotate_footprint_y_gpu_blocked("rotate_footprint_compute_list_begin_failed", footprint_count)
	_rd.compute_list_bind_compute_pipeline(cl, pipeline)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, groups.x, groups.y, groups.z)
	end_compute_list()
	submit_and_sync()

	var pos_bytes := _rd.buffer_get_data(pos_out_buffer, 0, footprint_count * 16)
	var weight_bytes := _rd.buffer_get_data(weight_out_buffer, 0, footprint_count * 16)
	dispose()
	if pos_bytes.size() != footprint_count * 16 or weight_bytes.size() != footprint_count * 16:
		return _rotate_footprint_y_gpu_blocked("rotate_footprint_readback_failed", footprint_count)

	return {
		"ok": true,
		"reason": "ok",
		"gpu_first": true,
		"cpu_fallback": false,
		"rotation_axis": "Y",
		"yaw_degrees": yaw_degrees,
		"footprint_count": footprint_count,
		"pos_strength_format": "ivec4(x,y,z,collision_q8)",
		"weight_flags_format": "vec4(weight,flags,radius,pad)",
		"pos_strength_stride_bytes": 16,
		"weight_flags_stride_bytes": 16,
		"valid_range": "collision_q8 clamped 0..255; weight/flags/radius copied",
		"volume_layout": "one packed footprint entry per invocation",
		"local_size_x": ROTATE_FOOTPRINT_Y_LOCAL_SIZE,
		"dispatch_groups": groups,
		"edge_guard": "idx >= footprint_count returns without writing",
		"pos_bytes": pos_bytes,
		"weight_bytes": weight_bytes,
		"footprint": _decode_gpu_footprint_buffers(pos_bytes, weight_bytes, footprint_count),
		"readback_source": "rotate_footprint_y_compute",
	}



static func _rotate_footprint_y_gpu_blocked(reason: String, footprint_count: int = 0) -> Dictionary:
	return {
		"ok": false,
		"reason": reason,
		"gpu_first": true,
		"cpu_fallback": false,
		"footprint_count": footprint_count,
	}



static func bake_rotated_footprints(
	collision: Array,
	voxel_size: Vector3,
	rotation_count: int = 24,
	add_support: bool = true,
	clearance_slices: int = 1,
	prefer_gpu: bool = true
) -> Array:
	if prefer_gpu:
		var gpu_result := bake_rotated_footprints_gpu(
			collision,
			voxel_size,
			rotation_count,
			add_support,
			clearance_slices
		)
		if bool(gpu_result.get("ok", false)):
			return gpu_result.get("rotations", [])
		push_error("VoxelPlacementGenerator: GPU rotated footprint bake blocked: %s" % str(gpu_result))
		return []

	var base := bake_footprint_from_collision(
		collision, voxel_size, add_support, clearance_slices, false)
	var result: Array = []
	for i in range(rotation_count):
		var yaw := float(i) * 360.0 / float(maxi(rotation_count, 1))
		result.append(rotate_footprint_y(base, yaw))
	return result



static func bake_rotated_footprints_gpu(
	collision: Array,
	voxel_size: Vector3,
	rotation_count: int = 24,
	add_support: bool = true,
	clearance_slices: int = 1
) -> Dictionary:
	var safe_rotation_count := maxi(rotation_count, 0)
	var base := bake_footprint_from_collision(
		collision,
		voxel_size,
		add_support,
		clearance_slices,
		true
	)
	if base.is_empty():
		return _bake_rotated_footprints_gpu_blocked("base_footprint_gpu_bake_blocked", safe_rotation_count)

	var result: Array = []
	var rotation_readback_sources := PackedStringArray()
	var gpu_rotation_count := 0
	var identity_rotation_count := 0
	for i in range(safe_rotation_count):
		var yaw := float(i) * 360.0 / float(maxi(safe_rotation_count, 1))
		if absf(yaw) < 0.01:
			var identity: Array[Dictionary] = []
			for entry in base:
				identity.append(entry.duplicate())
			result.append(identity)
			rotation_readback_sources.append("identity_base_footprint")
			identity_rotation_count += 1
			continue

		var gpu_rotation := rotate_footprint_y_gpu(base, yaw)
		if not bool(gpu_rotation.get("ok", false)):
			var blocked := _bake_rotated_footprints_gpu_blocked(
				str(gpu_rotation.get("reason", "rotate_footprint_gpu_blocked")),
				safe_rotation_count,
				i,
				yaw,
				base.size()
			)
			blocked["rotation_gpu_result"] = gpu_rotation
			blocked["partial_rotation_count"] = result.size()
			return blocked
		if bool(gpu_rotation.get("cpu_fallback", false)):
			var fallback_blocked := _bake_rotated_footprints_gpu_blocked(
				"rotate_footprint_gpu_reported_cpu_fallback",
				safe_rotation_count,
				i,
				yaw,
				base.size()
			)
			fallback_blocked["rotation_gpu_result"] = gpu_rotation
			fallback_blocked["partial_rotation_count"] = result.size()
			return fallback_blocked
		result.append(gpu_rotation.get("footprint", []))
		rotation_readback_sources.append(str(gpu_rotation.get("readback_source", "none")))
		gpu_rotation_count += 1

	return {
		"ok": true,
		"reason": "ok",
		"gpu_first": true,
		"cpu_fallback": false,
		"rotation_count": safe_rotation_count,
		"base_footprint_count": base.size(),
		"rotations": result,
		"rotation_readback_sources": rotation_readback_sources,
		"gpu_rotation_count": gpu_rotation_count,
		"identity_rotation_count": identity_rotation_count,
		"readback_source": "rotate_footprint_y_compute",
	}



static func _bake_rotated_footprints_gpu_blocked(
	reason: String,
	rotation_count: int = 0,
	rotation_index: int = -1,
	yaw_degrees: float = 0.0,
	base_footprint_count: int = 0
) -> Dictionary:
	return {
		"ok": false,
		"reason": reason,
		"gpu_first": true,
		"cpu_fallback": false,
		"rotation_count": rotation_count,
		"rotation_index": rotation_index,
		"yaw_degrees": yaw_degrees,
		"base_footprint_count": base_footprint_count,
		"rotations": [],
		"readback_source": "none",
	}
