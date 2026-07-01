class_name VoxelPickGPU
extends "res://scripts/godot_compute_shader_base.gd"

const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")
const SHADER_PATH := "res://shaders/pick_scene_voxel.glsl"
const OUTPUT_BYTES := 64
const MODE_SCENE_VOXEL := 0
const MODE_TARGETSV := 1

var _shader := RID()
var _pipeline := RID()
var _dummy_buffer := RID()
var _target_visual_buffer := RID()
var _target_collision_buffer := RID()
var _target_visual_bytes := 0
var _target_collision_bytes := 0


func _init() -> void:
	log_name = "VoxelPickGPU"


func pick_scene_voxel(
	ray_origin: Vector3,
	ray_dir: Vector3,
	terrain_height: PackedFloat32Array,
	terrain_res: int,
	grid_origin: Vector3,
	grid_size: Vector3i,
	voxel_size: Vector3,
	capture_size: float,
	max_height: float,
	surface_offset: float
) -> Dictionary:
	if not _ensure_pipeline():
		return {"ok": false, "reason": "gpu_pick_pipeline_unavailable"}

	var safe_terrain := terrain_height
	var safe_res := terrain_res
	if safe_terrain.is_empty() or safe_res <= 0:
		safe_terrain = PackedFloat32Array([0.0])
		safe_res = 1

	var terrain_buffer := storage_buffer_from_floats(safe_terrain, SCOPE_PASS, "pick_terrain_height")
	if not terrain_buffer.is_valid():
		gc_frame()
		return {"ok": false, "reason": "terrain_buffer_create_failed"}

	var push := _pack_push(
		MODE_SCENE_VOXEL,
		ray_origin,
		ray_dir,
		grid_origin,
		grid_size,
		voxel_size,
		safe_res,
		1,
		1,
		0,
		0,
		0,
		capture_size,
		max_height,
		surface_offset,
		0.0,
		1.0,
		0.001,
		5000.0
	)
	return _dispatch_pick(push, terrain_buffer, _dummy_storage_buffer(), _dummy_storage_buffer())


func pick_targetsv(
	ray_origin: Vector3,
	ray_dir: Vector3,
	base_x: int,
	base_z: int,
	visual_bytes: PackedByteArray,
	collision_bytes: PackedByteArray,
	texture_size: int,
	slice_count: int,
	capture_size: float,
	vertical_span: float,
	display_scale: float,
	target_origin: Vector3,
	terrain_height: PackedFloat32Array,
	terrain_res: int,
	search_radius: int = 4,
	occupancy_threshold: float = 0.001
) -> Dictionary:
	if texture_size <= 0 or slice_count <= 0:
		return {"ok": false, "reason": "invalid_targetsv_dimensions"}
	if not _ensure_pipeline():
		return {"ok": false, "reason": "gpu_pick_pipeline_unavailable"}

	var voxel_count := texture_size * texture_size * slice_count
	var expected_visual := voxel_count * 4
	var expected_collision := voxel_count
	if visual_bytes.size() < expected_visual or collision_bytes.size() < expected_collision:
		return {
			"ok": false,
			"reason": "targetsv_buffer_size_mismatch",
			"expected_visual": expected_visual,
			"actual_visual": visual_bytes.size(),
			"expected_collision": expected_collision,
			"actual_collision": collision_bytes.size(),
		}

	var collision_word_bytes := SceneVoxelTileCodecScript.r8_word_bytes_from_r8_bytes(collision_bytes.slice(0, expected_collision), voxel_count)
	if not _ensure_target_buffers(visual_bytes.slice(0, expected_visual), collision_word_bytes):
		return {"ok": false, "reason": "targetsv_gpu_buffer_create_failed"}

	var safe_terrain := terrain_height
	var safe_res := terrain_res
	if safe_terrain.is_empty() or safe_res <= 0:
		safe_terrain = PackedFloat32Array([0.0])
		safe_res = 1
	var terrain_buffer := storage_buffer_from_floats(safe_terrain, SCOPE_PASS, "pick_targetsv_terrain")
	if not terrain_buffer.is_valid():
		gc_frame()
		return {"ok": false, "reason": "terrain_buffer_create_failed"}

	var push := _pack_push(
		MODE_TARGETSV,
		ray_origin,
		ray_dir,
		target_origin,
		Vector3i.ONE,
		Vector3.ONE,
		safe_res,
		texture_size,
		slice_count,
		search_radius,
		base_x,
		base_z,
		capture_size,
		0.0,
		0.0,
		vertical_span,
		display_scale,
		occupancy_threshold,
		5000.0
	)
	return _dispatch_pick(push, terrain_buffer, _target_visual_buffer, _target_collision_buffer)


func _ensure_pipeline() -> bool:
	if _pipeline.is_valid():
		return true
	if not ensure_device(true, true):
		return false
	_shader = load_compute_shader(SHADER_PATH, SCOPE_PERSISTENT, "pick_scene_voxel")
	if not _shader.is_valid():
		return false
	_pipeline = create_compute_pipeline(_shader, SCOPE_PERSISTENT, "pick_scene_voxel")
	return _pipeline.is_valid()


func _dispatch_pick(push: PackedByteArray, terrain_buffer: RID, visual_buffer: RID, collision_buffer: RID) -> Dictionary:
	if _rd == null or not _pipeline.is_valid():
		return {"ok": false, "reason": "gpu_pick_not_ready"}
	var output_buffer := storage_buffer_zero(OUTPUT_BYTES, SCOPE_PASS, "pick_output")
	if not output_buffer.is_valid():
		gc_frame()
		return {"ok": false, "reason": "output_buffer_create_failed"}

	var set0 := create_uniform_set([
		make_storage_uniform(0, terrain_buffer),
		make_storage_uniform(1, visual_buffer),
		make_storage_uniform(2, collision_buffer),
		make_storage_uniform(3, output_buffer),
	], _shader, 0, SCOPE_PASS, "pick_scene_voxel_set")
	if not set0.is_valid():
		gc_frame()
		return {"ok": false, "reason": "uniform_set_create_failed"}

	var cl := begin_compute_list()
	if cl < 0:
		gc_frame()
		return {"ok": false, "reason": "compute_list_begin_failed"}
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, 1, 1, 1)
	end_compute_list()
	submit_and_sync(true)

	var bytes := _rd.buffer_get_data(output_buffer, 0, OUTPUT_BYTES)
	var result := _decode_output(bytes)
	gc_frame()
	return result


func _decode_output(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < OUTPUT_BYTES:
		return {"ok": false, "reason": "output_readback_too_small"}
	if bytes.decode_u32(0) == 0:
		return {"ok": false, "reason": "no_gpu_hit", "pick_backend": "gpu_compute"}
	var voxel := Vector3i(
		int(bytes.decode_u32(4)),
		int(bytes.decode_u32(8)),
		int(bytes.decode_u32(12))
	)
	var world_pos := Vector3(
		bytes.decode_float(16),
		bytes.decode_float(20),
		bytes.decode_float(24)
	)
	var complexity := clampf(bytes.decode_float(32), 0.0, 1.0)
	var collision := clampf(bytes.decode_float(36), 0.0, 1.0)
	return {
		"ok": true,
		"voxel_coord": voxel,
		"world_position": world_pos,
		"screen_score": bytes.decode_float(28),
		"complexity": complexity,
		"collision": collision,
		"occupancy": maxf(complexity, collision),
		"buffer_index": int(bytes.decode_u32(44)),
		"pick_backend": "gpu_compute",
	}


func _ensure_target_buffers(visual_bytes: PackedByteArray, collision_bytes: PackedByteArray) -> bool:
	if _target_visual_buffer.is_valid() \
			and _target_collision_buffer.is_valid() \
			and _target_visual_bytes == visual_bytes.size() \
			and _target_collision_bytes == collision_bytes.size():
		return true

	if _target_visual_buffer.is_valid():
		release_rid(_target_visual_buffer, false)
	if _target_collision_buffer.is_valid():
		release_rid(_target_collision_buffer, false)
	_target_visual_buffer = storage_buffer_from_bytes(visual_bytes, SCOPE_PERSISTENT, "targetsv_visual_pick")
	_target_collision_buffer = storage_buffer_from_bytes(collision_bytes, SCOPE_PERSISTENT, "targetsv_collision_pick")
	_target_visual_bytes = visual_bytes.size()
	_target_collision_bytes = collision_bytes.size()
	return _target_visual_buffer.is_valid() and _target_collision_buffer.is_valid()


func _dummy_storage_buffer() -> RID:
	if _dummy_buffer.is_valid():
		return _dummy_buffer
	var bytes := PackedByteArray()
	bytes.resize(16)
	_dummy_buffer = storage_buffer_from_bytes(bytes, SCOPE_PERSISTENT, "pick_dummy")
	return _dummy_buffer


func _pack_push(
	mode: int,
	ray_origin: Vector3,
	ray_dir: Vector3,
	grid_origin: Vector3,
	grid_size: Vector3i,
	voxel_size: Vector3,
	terrain_res: int,
	target_size: int,
	target_slices: int,
	search_radius: int,
	base_x: int,
	base_z: int,
	capture_size: float,
	max_height: float,
	surface_offset: float,
	vertical_span: float,
	display_scale: float,
	occupancy_threshold: float,
	max_t: float
) -> PackedByteArray:
	var dir := ray_dir.normalized()
	if dir.length_squared() <= 0.000001:
		dir = Vector3(0.0, -1.0, 0.0)
	var push := PackedByteArray()
	push.resize(128)
	push.encode_s32(0, mode)
	push.encode_s32(4, grid_size.x)
	push.encode_s32(8, grid_size.y)
	push.encode_s32(12, grid_size.z)
	push.encode_s32(16, terrain_res)
	push.encode_s32(20, target_size)
	push.encode_s32(24, target_slices)
	push.encode_s32(28, search_radius)
	push.encode_s32(32, base_x)
	push.encode_s32(36, base_z)
	push.encode_s32(40, 0)
	push.encode_s32(44, 0)
	push.encode_float(48, ray_origin.x)
	push.encode_float(52, ray_origin.y)
	push.encode_float(56, ray_origin.z)
	push.encode_float(60, dir.x)
	push.encode_float(64, dir.y)
	push.encode_float(68, dir.z)
	push.encode_float(72, grid_origin.x)
	push.encode_float(76, grid_origin.y)
	push.encode_float(80, grid_origin.z)
	push.encode_float(84, voxel_size.x)
	push.encode_float(88, voxel_size.y)
	push.encode_float(92, voxel_size.z)
	push.encode_float(96, capture_size)
	push.encode_float(100, max_height)
	push.encode_float(104, surface_offset)
	push.encode_float(108, vertical_span)
	push.encode_float(112, display_scale)
	push.encode_float(116, occupancy_threshold)
	push.encode_float(120, max_t)
	push.encode_float(124, 0.0)
	return push
