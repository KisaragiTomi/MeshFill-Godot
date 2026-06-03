extends SceneTree

const VPG := preload("res://scripts/voxel_placement_generator.gd")
const FLAG_SUPPORT := 1
const FLAG_CLEARANCE := 2


func _init() -> void:
	var ok := true
	ok = ok and _test_bake_float_voxels()
	ok = ok and _test_bake_cylinder()
	ok = ok and _test_bake_cylinder_gpu_or_skip()
	ok = ok and _test_bake_box()
	ok = ok and _test_bake_box_gpu_or_skip()
	ok = ok and _test_bake_rotation()
	ok = ok and _test_bake_rotation_gpu_or_skip()
	ok = ok and _test_bake_rotated_set()
	var rendering_device := RenderingServer.create_local_rendering_device()
	if rendering_device != null:
		rendering_device.free()
		ok = ok and _test_full_pipeline()
	else:
		print("[VoxelFootprintBake] SKIP: full pipeline requires RenderingDevice")
	ok = ok and _test_results_to_world()

	if ok:
		print("[VoxelFootprintBake] ALL TESTS PASSED")
		quit(0)
	else:
		push_error("[VoxelFootprintBake] SOME TESTS FAILED")
		quit(1)


func _test_bake_float_voxels() -> bool:
	print("[VoxelFootprintBake] test_bake_float_voxels...")
	var collision: Array = [
		{"voxel": Vector3i(0, 0, 0), "collision_strength": 0.25},
		{"voxel": Vector3i(0, 1, 0), "collision_strength": 1.0},
		{"local_pos": Vector3i(1, 1, 0), "collision_strength": 0.5},
	]
	var footprint := VPG.bake_footprint_from_collision(
		collision, Vector3(0.5, 0.5, 0.5), true, 1)
	var has_support := false
	var has_clearance := false
	var has_full_collision := false
	var has_partial_collision := false
	for entry in footprint:
		var pos: Vector3i = entry.local_pos
		var strength := float(entry.collision_strength)
		var flags := int(entry.flags)
		if pos == Vector3i(0, 0, 0) and flags & FLAG_SUPPORT:
			has_support = true
		if pos == Vector3i(0, 1, 0) and strength >= 0.99:
			has_full_collision = true
		if pos == Vector3i(1, 1, 0) and absf(strength - 0.5) <= 0.01:
			has_partial_collision = true
		if flags & FLAG_CLEARANCE:
			has_clearance = true
	if not has_support:
		push_error("  FAIL: float voxels did not infer support")
		return false
	if not has_clearance:
		push_error("  FAIL: float voxels did not generate clearance")
		return false
	if not has_full_collision:
		push_error("  FAIL: collision_strength was not preserved")
		return false
	if not has_partial_collision:
		push_error("  FAIL: collision_strength was not preserved")
		return false
	print("  OK: %d float voxel entries" % footprint.size())
	return true


func _test_bake_cylinder() -> bool:
	print("[VoxelFootprintBake] test_bake_cylinder...")
	var collision: Array = [
		{
			"shape": "cylinder",
			"radius": 0.5,
			"y_min": 0.0,
			"y_max": 2.0,
			"collision_strength": 1.0,
		}
	]
	var voxel_size := Vector3(0.5, 0.5, 0.5)
	var footprint := VPG.bake_footprint_from_collision(
		collision, voxel_size, true, 1)

	if footprint.is_empty():
		push_error("  FAIL: footprint is empty")
		return false

	var has_support := false
	var has_clearance := false
	var has_solid := false
	for entry in footprint:
		var flags := int(entry.flags)
		var strength := float(entry.collision_strength)
		if flags & FLAG_SUPPORT:
			has_support = true
		if flags & FLAG_CLEARANCE:
			has_clearance = true
		if strength >= 0.75:
			has_solid = true

	if not has_support:
		push_error("  FAIL: no support voxels found")
		return false
	if not has_clearance:
		push_error("  FAIL: no clearance voxels found")
		return false
	if not has_solid:
		push_error("  FAIL: no solid collision samples found")
		return false

	print("  OK: %d voxels (support=%s clearance=%s solid=%s)" % [
		footprint.size(), has_support, has_clearance, has_solid])
	return true


func _test_bake_cylinder_gpu_or_skip() -> bool:
	print("[VoxelFootprintBake] test_bake_cylinder_gpu_or_skip...")
	var rendering_device := RenderingServer.create_local_rendering_device()
	if rendering_device == null:
		print("  SKIP: no RenderingDevice available for GPU cylinder footprint bake")
		return true
	rendering_device.free()

	var collision := {
		"shape": "cylinder",
		"offset": Vector3(0.5, 0.25, -0.5),
		"radius": 0.75,
		"y_min": 0.0,
		"y_max": 1.0,
		"collision_strength": 0.65,
	}
	var voxel_size := Vector3(0.5, 0.5, 0.5)
	var cpu_footprint := VPG.bake_footprint_from_collision([collision], voxel_size, true, 1)
	var gpu := VPG.bake_cylinder_footprint_gpu(collision, voxel_size, true, 1)
	if not bool(gpu.get("ok", false)):
		push_error("  FAIL: GPU cylinder footprint bake failed: %s" % str(gpu))
		return false
	if bool(gpu.get("cpu_fallback", true)):
		push_error("  FAIL: GPU cylinder footprint bake must not report CPU fallback")
		return false
	if str(gpu.get("readback_source", "")) != "bake_cylinder_footprint_compute":
		push_error("  FAIL: GPU cylinder footprint readback source mismatch: %s" % str(gpu))
		return false
	if str(gpu.get("pos_strength_format", "")) != "ivec4(x,y,z,collision_q8)" \
			or str(gpu.get("weight_flags_format", "")) != "vec4(weight,flags,radius,pad)" \
			or str(gpu.get("stats_format", "")) != "u32_valid_count":
		push_error("  FAIL: GPU cylinder footprint format metadata mismatch: %s" % str(gpu))
		return false
	if int(gpu.get("pos_strength_stride_bytes", 0)) != 16 \
			or int(gpu.get("weight_flags_stride_bytes", 0)) != 16 \
			or int(gpu.get("stats_stride_bytes", 0)) != 4:
		push_error("  FAIL: GPU cylinder footprint stride metadata mismatch")
		return false
	if int(gpu.get("local_size_x", 0)) != 64:
		push_error("  FAIL: GPU cylinder footprint local size should be 64")
		return false
	var groups: Vector3i = gpu.get("dispatch_groups", Vector3i.ZERO)
	if groups.x <= 0 or groups.y != 1 or groups.z != 1:
		push_error("  FAIL: GPU cylinder footprint dispatch groups invalid: %s" % str(groups))
		return false

	var gpu_footprint: Array = gpu.get("footprint", [])
	if gpu_footprint.size() != cpu_footprint.size():
		push_error("  FAIL: GPU/CPU cylinder footprint count mismatch: gpu=%d cpu=%d" % [gpu_footprint.size(), cpu_footprint.size()])
		return false
	if int(gpu.get("footprint_count", -1)) != gpu_footprint.size() \
			or int(gpu.get("total_generated_count", -1)) != cpu_footprint.size():
		push_error("  FAIL: GPU cylinder count metadata mismatch: %s" % str(gpu))
		return false
	if bool(gpu.get("truncated", true)):
		push_error("  FAIL: test cylinder footprint should not be capacity-truncated")
		return false

	var cpu_by_pos := _footprint_by_pos(cpu_footprint)
	var gpu_by_pos := _footprint_by_pos(gpu_footprint)
	for key in cpu_by_pos.keys():
		if not gpu_by_pos.has(key):
			push_error("  FAIL: GPU cylinder missing footprint voxel %s" % key)
			return false
		var cpu: Dictionary = cpu_by_pos[key]
		var g: Dictionary = gpu_by_pos[key]
		if absf(float(g.get("collision_strength", 0.0)) - float(cpu.get("collision_strength", 0.0))) > (1.0 / 255.0 + 0.001):
			push_error("  FAIL: GPU cylinder strength mismatch at %s: gpu=%.4f cpu=%.4f" % [
				key,
				float(g.get("collision_strength", 0.0)),
				float(cpu.get("collision_strength", 0.0)),
			])
			return false
		if int(g.get("flags", 0)) != int(cpu.get("flags", 0)):
			push_error("  FAIL: GPU cylinder flags mismatch at %s: gpu=%d cpu=%d" % [
				key,
				int(g.get("flags", 0)),
				int(cpu.get("flags", 0)),
			])
			return false
		if absf(float(g.get("weight", 0.0)) - float(cpu.get("weight", 0.0))) > 0.001:
			push_error("  FAIL: GPU cylinder weight mismatch at %s" % key)
			return false

	var pos_bytes: PackedByteArray = gpu.get("pos_bytes", PackedByteArray())
	var weight_bytes: PackedByteArray = gpu.get("weight_bytes", PackedByteArray())
	if pos_bytes.size() != gpu_footprint.size() * 16 or weight_bytes.size() != gpu_footprint.size() * 16:
		push_error("  FAIL: GPU cylinder raw buffer sizes mismatch")
		return false

	print("  OK: GPU cylinder footprint matches CPU bake and packed placement buffer layout")
	return true


func _test_bake_box() -> bool:
	print("[VoxelFootprintBake] test_bake_box...")
	var collision: Array = [
		{
			"shape": "box",
			"offset": Vector3(1.0, 0.0, 0.0),
			"half_extents": Vector3(0.5, 0.5, 0.5),
			"collision_strength": 1.0,
		}
	]
	var voxel_size := Vector3(0.5, 0.5, 0.5)
	var footprint := VPG.bake_footprint_from_collision(
		collision, voxel_size, true, 1)

	if footprint.is_empty():
		push_error("  FAIL: box footprint is empty")
		return false

	var has_support := false
	var has_clearance := false
	var has_solid := false
	var has_offset := false
	for entry in footprint:
		var flags := int(entry.flags)
		var strength := float(entry.collision_strength)
		var pos: Vector3i = entry.local_pos
		if flags & FLAG_SUPPORT:
			has_support = true
		if flags & FLAG_CLEARANCE:
			has_clearance = true
		if strength >= 0.75:
			has_solid = true
		if pos.x >= 1:
			has_offset = true

	if not has_support:
		push_error("  FAIL: box has no support voxels")
		return false
	if not has_clearance:
		push_error("  FAIL: box has no clearance voxels")
		return false
	if not has_solid:
		push_error("  FAIL: box has no solid collision samples")
		return false
	if not has_offset:
		push_error("  FAIL: box offset was not applied")
		return false

	print("  OK: %d box voxels" % footprint.size())
	return true


func _test_bake_box_gpu_or_skip() -> bool:
	print("[VoxelFootprintBake] test_bake_box_gpu_or_skip...")
	var rendering_device := RenderingServer.create_local_rendering_device()
	if rendering_device == null:
		print("  SKIP: no RenderingDevice available for GPU box footprint bake")
		return true
	rendering_device.free()

	var collision := {
		"shape": "box",
		"offset": Vector3(1.0, 0.25, -0.5),
		"size": Vector3(1.0, 1.0, 1.5),
		"collision_strength": 0.6,
	}
	var voxel_size := Vector3(0.5, 0.5, 0.5)
	var cpu_footprint := VPG.bake_footprint_from_collision([collision], voxel_size, true, 2)
	var gpu := VPG.bake_box_footprint_gpu(collision, voxel_size, true, 2)
	if not bool(gpu.get("ok", false)):
		push_error("  FAIL: GPU box footprint bake failed: %s" % str(gpu))
		return false
	if bool(gpu.get("cpu_fallback", true)):
		push_error("  FAIL: GPU box footprint bake must not report CPU fallback")
		return false
	if str(gpu.get("readback_source", "")) != "bake_box_footprint_compute":
		push_error("  FAIL: GPU box footprint readback source mismatch: %s" % str(gpu))
		return false
	if str(gpu.get("pos_strength_format", "")) != "ivec4(x,y,z,collision_q8)" \
			or str(gpu.get("weight_flags_format", "")) != "vec4(weight,flags,radius,pad)":
		push_error("  FAIL: GPU box footprint format metadata mismatch: %s" % str(gpu))
		return false
	if int(gpu.get("pos_strength_stride_bytes", 0)) != 16 or int(gpu.get("weight_flags_stride_bytes", 0)) != 16:
		push_error("  FAIL: GPU box footprint stride metadata mismatch")
		return false
	if int(gpu.get("local_size_x", 0)) != 64:
		push_error("  FAIL: GPU box footprint local size should be 64")
		return false
	var groups: Vector3i = gpu.get("dispatch_groups", Vector3i.ZERO)
	if groups.x <= 0 or groups.y != 1 or groups.z != 1:
		push_error("  FAIL: GPU box footprint dispatch groups invalid: %s" % str(groups))
		return false

	var gpu_footprint: Array = gpu.get("footprint", [])
	if gpu_footprint.size() != cpu_footprint.size():
		push_error("  FAIL: GPU/CPU box footprint count mismatch: gpu=%d cpu=%d" % [gpu_footprint.size(), cpu_footprint.size()])
		return false
	if int(gpu.get("footprint_count", -1)) != gpu_footprint.size():
		push_error("  FAIL: GPU footprint_count metadata mismatch")
		return false
	if int(gpu.get("solid_count", 0)) <= 0 or int(gpu.get("clearance_count", 0)) <= 0:
		push_error("  FAIL: GPU box footprint should report solid and clearance counts: %s" % str(gpu))
		return false

	for i in range(cpu_footprint.size()):
		var cpu: Dictionary = cpu_footprint[i]
		var g: Dictionary = gpu_footprint[i]
		if (g.get("local_pos", Vector3i.ZERO) as Vector3i) != (cpu.get("local_pos", Vector3i.ZERO) as Vector3i):
			push_error("  FAIL: GPU box footprint position mismatch at %d: gpu=%s cpu=%s" % [
				i,
				str(g.get("local_pos", Vector3i.ZERO)),
				str(cpu.get("local_pos", Vector3i.ZERO)),
			])
			return false
		if absf(float(g.get("collision_strength", 0.0)) - float(cpu.get("collision_strength", 0.0))) > (1.0 / 255.0 + 0.001):
			push_error("  FAIL: GPU box footprint strength mismatch at %d: gpu=%.4f cpu=%.4f" % [
				i,
				float(g.get("collision_strength", 0.0)),
				float(cpu.get("collision_strength", 0.0)),
			])
			return false
		if int(g.get("flags", 0)) != int(cpu.get("flags", 0)):
			push_error("  FAIL: GPU box footprint flags mismatch at %d: gpu=%d cpu=%d" % [
				i,
				int(g.get("flags", 0)),
				int(cpu.get("flags", 0)),
			])
			return false
		if absf(float(g.get("weight", 0.0)) - float(cpu.get("weight", 0.0))) > 0.001:
			push_error("  FAIL: GPU box footprint weight mismatch at %d" % i)
			return false

	var pos_bytes: PackedByteArray = gpu.get("pos_bytes", PackedByteArray())
	var weight_bytes: PackedByteArray = gpu.get("weight_bytes", PackedByteArray())
	if pos_bytes.size() != gpu_footprint.size() * 16 or weight_bytes.size() != gpu_footprint.size() * 16:
		push_error("  FAIL: GPU box footprint raw buffer sizes mismatch")
		return false

	print("  OK: GPU box footprint matches CPU bake and packed placement buffer layout")
	return true


func _test_bake_rotation() -> bool:
	print("[VoxelFootprintBake] test_bake_rotation...")
	var footprint: Array[Dictionary] = [
		{"local_pos": Vector3i(2, 0, 0), "collision_strength": 1.0, "flags": FLAG_SUPPORT, "weight": 1.0},
		{"local_pos": Vector3i(2, 1, 0), "collision_strength": 1.0, "flags": 0, "weight": 1.0},
	]

	var rotated_90 := VPG.rotate_footprint_y(footprint, 90.0)
	if rotated_90.is_empty():
		push_error("  FAIL: rotated footprint is empty")
		return false

	var found_rotated := false
	for entry in rotated_90:
		var pos: Vector3i = entry.local_pos
		if pos.x == 0 and pos.z == 2 and pos.y == 0:
			found_rotated = true
			break
		if pos.x == 0 and pos.z == -2 and pos.y == 0:
			found_rotated = true
			break

	if not found_rotated:
		var positions := []
		for entry in rotated_90:
			positions.append(entry.local_pos)
		push_error("  FAIL: expected (2,0,0) rotated 90° around Y, got %s" % str(positions))
		return false

	var identity := VPG.rotate_footprint_y(footprint, 0.0)
	if identity.size() != footprint.size():
		push_error("  FAIL: identity rotation changed count")
		return false

	print("  OK: 90° rotation correct, identity preserved")
	return true


func _test_bake_rotation_gpu_or_skip() -> bool:
	print("[VoxelFootprintBake] test_bake_rotation_gpu_or_skip...")
	var rendering_device := RenderingServer.create_local_rendering_device()
	if rendering_device == null:
		print("  SKIP: no RenderingDevice available for GPU footprint rotation")
		return true
	rendering_device.free()

	var footprint: Array[Dictionary] = []
	for i in range(65):
		footprint.append({
			"local_pos": Vector3i(i, i % 4, 1),
			"collision_strength": float(i % 17) / 16.0,
			"flags": FLAG_SUPPORT if i % 2 == 0 else FLAG_CLEARANCE,
			"weight": 0.25 + float(i % 5) * 0.1,
		})

	var gpu := VPG.rotate_footprint_y_gpu(footprint, 90.0)
	if not bool(gpu.get("ok", false)):
		push_error("  FAIL: GPU footprint rotation failed: %s" % str(gpu))
		return false
	if bool(gpu.get("cpu_fallback", true)):
		push_error("  FAIL: GPU footprint rotation must not report CPU fallback")
		return false
	if str(gpu.get("readback_source", "")) != "rotate_footprint_y_compute":
		push_error("  FAIL: GPU footprint rotation readback source mismatch: %s" % str(gpu))
		return false
	if str(gpu.get("pos_strength_format", "")) != "ivec4(x,y,z,collision_q8)" \
			or str(gpu.get("weight_flags_format", "")) != "vec4(weight,flags,radius,pad)":
		push_error("  FAIL: GPU footprint rotation format metadata mismatch: %s" % str(gpu))
		return false
	if int(gpu.get("pos_strength_stride_bytes", 0)) != 16 \
			or int(gpu.get("weight_flags_stride_bytes", 0)) != 16:
		push_error("  FAIL: GPU footprint rotation stride metadata mismatch")
		return false
	if int(gpu.get("local_size_x", 0)) != 64:
		push_error("  FAIL: GPU footprint rotation local size should be 64")
		return false
	var groups: Vector3i = gpu.get("dispatch_groups", Vector3i.ZERO)
	if groups.x != 2 or groups.y != 1 or groups.z != 1:
		push_error("  FAIL: GPU footprint rotation should dispatch two guarded groups for 65 entries: %s" % str(groups))
		return false

	var expected := VPG.rotate_footprint_y(footprint, 90.0)
	var actual: Array = gpu.get("footprint", [])
	if actual.size() != expected.size():
		push_error("  FAIL: GPU/CPU rotated footprint count mismatch: gpu=%d cpu=%d" % [actual.size(), expected.size()])
		return false

	var expected_by_pos := _footprint_by_pos(expected)
	var actual_by_pos := _footprint_by_pos(actual)
	for key in expected_by_pos.keys():
		if not actual_by_pos.has(key):
			push_error("  FAIL: GPU footprint rotation missing voxel %s" % key)
			return false
		var cpu: Dictionary = expected_by_pos[key]
		var g: Dictionary = actual_by_pos[key]
		if absf(float(g.get("collision_strength", 0.0)) - float(cpu.get("collision_strength", 0.0))) > (1.0 / 255.0 + 0.001):
			push_error("  FAIL: GPU rotated strength mismatch at %s" % key)
			return false
		if int(g.get("flags", 0)) != int(cpu.get("flags", 0)):
			push_error("  FAIL: GPU rotated flags mismatch at %s" % key)
			return false
		if absf(float(g.get("weight", 0.0)) - float(cpu.get("weight", 0.0))) > 0.001:
			push_error("  FAIL: GPU rotated weight mismatch at %s" % key)
			return false

	var pos_bytes: PackedByteArray = gpu.get("pos_bytes", PackedByteArray())
	var weight_bytes: PackedByteArray = gpu.get("weight_bytes", PackedByteArray())
	if pos_bytes.size() != actual.size() * 16 or weight_bytes.size() != actual.size() * 16:
		push_error("  FAIL: GPU rotated footprint raw buffer sizes mismatch")
		return false

	print("  OK: GPU footprint rotation matches CPU helper and guarded packed buffer layout")
	return true


func _test_bake_rotated_set() -> bool:
	print("[VoxelFootprintBake] test_bake_rotated_set...")
	var collision: Array = [
		{"shape": "cylinder", "radius": 0.3, "y_min": 0.0, "y_max": 1.0, "collision_strength": 1.0}
	]
	var voxel_size := Vector3(0.5, 0.5, 0.5)
	var rotations := VPG.bake_rotated_footprints(collision, voxel_size, 24, true, 1)

	if rotations.size() != 24:
		push_error("  FAIL: expected 24 rotations, got %d" % rotations.size())
		return false

	for i in range(24):
		var fp: Array = rotations[i]
		if fp.is_empty():
			push_error("  FAIL: rotation %d produced empty footprint" % i)
			return false

	print("  OK: 24 rotations, each non-empty")
	return true


func _test_full_pipeline() -> bool:
	print("[VoxelFootprintBake] test_full_pipeline...")
	var grid_size := Vector3i(16, 8, 16)
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var voxel_size := Vector3(0.5, 0.5, 0.5)

	var generator := VPG.new()
	var scene := PackedFloat32Array()
	var collision_field := PackedFloat32Array()
	scene.resize(voxel_count)
	collision_field.resize(voxel_count)

	for z in range(grid_size.z):
		for x in range(grid_size.x):
			scene[generator.voxel_index(Vector3i(x, 0, z), grid_size)] = 1.0

	var collision: Array = [
		{"shape": "cylinder", "radius": 0.45, "y_min": 0.0, "y_max": 2.0, "collision_strength": 1.0}
	]
	var footprint := VPG.bake_footprint_from_collision(
		collision, voxel_size, true, 1)

	if footprint.is_empty():
		push_error("  FAIL: baked footprint is empty")
		return false

	var settings := {
		"top_k": 4,
		"result_capacity": 4,
		"min_distance_voxels": 3.0,
		"collision_limit": 0.0,
		"min_support_ratio": 1.0,
		"clearance_limit": 0.0,
	}

	var result := generator.run_minimal(scene, collision_field, footprint, grid_size, settings)
	if result.is_empty():
		push_error("  FAIL: run_minimal returned empty")
		return false

	var count := int(result.get("result_count", 0))
	if count <= 0:
		push_error("  FAIL: no placements found")
		return false

	var results: Array = result.get("results", [])
	var first: Dictionary = results[0]
	if not bool(first.get("valid", false)):
		push_error("  FAIL: first placement not valid")
		return false

	var stamped_collision: PackedFloat32Array = result.get("collision_field_out", PackedFloat32Array())
	var first_origin: Vector3i = first.voxel_origin
	var any_collision_written := false
	for entry in footprint:
		var strength := float(entry.collision_strength)
		if strength < 0.75:
			continue
		var pos: Vector3i = entry.local_pos
		var world_pos := first_origin + pos
		if world_pos.x < 0 or world_pos.x >= grid_size.x:
			continue
		if world_pos.y < 0 or world_pos.y >= grid_size.y:
			continue
		if world_pos.z < 0 or world_pos.z >= grid_size.z:
			continue
		var idx := generator.voxel_index(world_pos, grid_size)
		if stamped_collision[idx] > 0.01:
			any_collision_written = true
			break

	if not any_collision_written:
		push_error("  FAIL: stamp did not write collision for baked footprint")
		return false

	var second := generator.run_minimal(
		result.get("scene_field_out", PackedFloat32Array()),
		result.get("collision_field_out", PackedFloat32Array()),
		footprint, grid_size, settings)
	var second_count := int(second.get("result_count", 0))
	if second_count <= 0:
		push_error("  FAIL: second round found no placements")
		return false

	var second_origin: Vector3i = (second.get("results", []) as Array)[0].get("voxel_origin", Vector3i.ZERO)
	if second_origin == first_origin:
		push_error("  FAIL: second round placed at same origin as first")
		return false

	print("  OK: footprint=%d first=%s second=%s rounds=2" % [
		footprint.size(), str(first_origin), str(second_origin)])
	return true


func _test_results_to_world() -> bool:
	print("[VoxelFootprintBake] test_results_to_world...")
	var voxel_size := Vector3(0.5, 1.0, 0.5)
	var grid_origin := Vector3(-10.0, 0.0, -10.0)

	var mock_results: Array[Dictionary] = [
		{
			"voxel_origin": Vector3i(4, 2, 6),
			"score": 8.5,
			"valid": true,
			"rotation_index": 6,
			"scale_index": 0,
			"asset_index": 0,
			"support_ratio": 1.0,
			"solid_collision": 0.0,
			"scene_overlap": 0.0,
			"clearance_overlap": 0.0,
			"ignored_sample": 0.0,
		},
		{
			"voxel_origin": Vector3i(10, 1, 3),
			"score": -1.0,
			"valid": false,
			"rotation_index": 0,
			"scale_index": 0,
			"asset_index": 0,
			"support_ratio": 0.0,
			"solid_collision": 5.0,
			"scene_overlap": 0.0,
			"clearance_overlap": 0.0,
			"ignored_sample": 0.0,
		},
	]

	var world := VPG.results_to_world(mock_results, voxel_size, grid_origin, 24)

	if world.size() != 1:
		push_error("  FAIL: expected 1 valid result, got %d" % world.size())
		return false

	var w: Dictionary = world[0]
	var expected_pos := grid_origin + Vector3(4.0 * 0.5, 2.0 * 1.0, 6.0 * 0.5)
	var pos: Vector3 = w.position
	if pos.distance_to(expected_pos) > 0.01:
		push_error("  FAIL: position %s != expected %s" % [str(pos), str(expected_pos)])
		return false

	var expected_yaw := 6.0 * 360.0 / 24.0
	var yaw := float((w.get("rotation_degrees", Vector3.ZERO) as Vector3).y)
	if absf(yaw - expected_yaw) > 0.1:
		push_error("  FAIL: yaw %.1f != expected %.1f" % [yaw, expected_yaw])
		return false

	print("  OK: position=%s yaw=%.1f (filtered invalid)" % [str(pos), yaw])
	return true


func _footprint_by_pos(footprint: Array) -> Dictionary:
	var result := {}
	for entry in footprint:
		var dict := entry as Dictionary
		var pos: Vector3i = dict.get("local_pos", Vector3i.ZERO)
		result["%d,%d,%d" % [pos.x, pos.y, pos.z]] = dict
	return result
