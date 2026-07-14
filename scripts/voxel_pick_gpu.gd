class_name VoxelPickGPU
extends "res://scripts/godot_compute_shader_base.gd"

const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")
const SHADER_PATH := "res://shaders/pick_scene_voxel.glsl"
const OUTPUT_BYTES := 64
const MODE_SCENE_VOXEL := 0
const MODE_TARGETSV := 1

# push constant 布局（std430；与原 _pack_push 的 128 字节手工 encode 逐字节一致：12×int 后接 20×float）。
const PICK_PUSH := [
	["mode", "int"], ["grid_x", "int"], ["grid_y", "int"], ["grid_z", "int"],
	["terrain_res", "int"], ["target_size", "int"], ["target_slices", "int"], ["search_radius", "int"],
	["base_x", "int"], ["base_z", "int"], ["_pad0", "int"], ["_pad1", "int"],
	["ray_origin_x", "float"], ["ray_origin_y", "float"], ["ray_origin_z", "float"],
	["dir_x", "float"], ["dir_y", "float"], ["dir_z", "float"],
	["grid_origin_x", "float"], ["grid_origin_y", "float"], ["grid_origin_z", "float"],
	["voxel_size_x", "float"], ["voxel_size_y", "float"], ["voxel_size_z", "float"],
	["capture_size", "float"], ["max_height", "float"], ["surface_offset", "float"],
	["vertical_span", "float"], ["display_scale", "float"], ["occupancy_threshold", "float"],
	["max_t", "float"], ["_pad2", "float"],
]

var _shader := RID()
var _pipeline := RID()
var _dummy_buffer := RID()
var _target_visual_buffer := RID()
var _target_collision_buffer := RID()
var _target_visual_bytes := 0
var _target_collision_bytes := 0
var _pick_layout: PushConstantLayout = null


# 初始化日志名称，便于在 GPU 拾取相关输出中区分该组件。
func _init() -> void:
	log_name = "VoxelPickGPU"
	_pick_layout = PushConstantLayout.new(PICK_PUSH)


# 使用场景体素网格和地形高度图执行一次 GPU 射线拾取，返回命中的体素与世界坐标信息。
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


# 使用目标体素贴图数据执行 GPU 射线拾取，适用于 TargetSV 视觉/碰撞体素缓冲的命中检测。
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

	var collision_word_bytes := SceneVoxelTileCodecScript.u32_bytes_from_r8_bytes(collision_bytes.slice(0, expected_collision), voxel_count)
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


# 确保计算着色器与计算管线已加载完成，首次调用时会创建并缓存相关 GPU 资源。
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


# 提交一次完整的 GPU 拾取 dispatch，读取输出缓冲并解码为统一的拾取结果字典。
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
	_gpu_dispatch_pipeline_sets(cl, _pipeline, [set0], push, Vector3i(1, 1, 1))
	end_compute_list()
	submit_and_sync(true)

	var bytes := _rd.buffer_get_data(output_buffer, 0, OUTPUT_BYTES)
	var result := _decode_output(bytes)
	gc_frame()
	return result


# 解析着色器输出缓冲，将原始字节数据转换为可直接使用的拾取结果。
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


# 根据当前 TargetSV 数据尺寸维护持久化 GPU 缓冲：同尺寸时用 buffer_update 覆写既有缓冲
# （RID 稳定、零重分配，内容始终跟随本次输入）；尺寸变化或覆写失败时释放旧缓冲并重建。
func _ensure_target_buffers(visual_bytes: PackedByteArray, collision_bytes: PackedByteArray) -> bool:
	if _target_visual_buffer.is_valid() \
			and _target_collision_buffer.is_valid() \
			and _target_visual_bytes == visual_bytes.size() \
			and _target_collision_bytes == collision_bytes.size():
		if _rd != null \
				and _rd.buffer_update(_target_visual_buffer, 0, visual_bytes.size(), visual_bytes) == OK \
				and _rd.buffer_update(_target_collision_buffer, 0, collision_bytes.size(), collision_bytes) == OK:
			return true
		# buffer_update 失败时退回释放重建路径，绝不沿用陈旧内容。

	if _target_visual_buffer.is_valid():
		release_rid(_target_visual_buffer, false)
	if _target_collision_buffer.is_valid():
		release_rid(_target_collision_buffer, false)
	_target_visual_buffer = storage_buffer_from_bytes(visual_bytes, SCOPE_PERSISTENT, "targetsv_visual_pick")
	_target_collision_buffer = storage_buffer_from_bytes(collision_bytes, SCOPE_PERSISTENT, "targetsv_collision_pick")
	_target_visual_bytes = visual_bytes.size()
	_target_collision_bytes = collision_bytes.size()
	return _target_visual_buffer.is_valid() and _target_collision_buffer.is_valid()


# 提供一个最小占位 storage buffer，供不需要真实体素数据的拾取模式复用。
func _dummy_storage_buffer() -> RID:
	if _dummy_buffer.is_valid():
		return _dummy_buffer
	var bytes := PackedByteArray()
	bytes.resize(16)
	_dummy_buffer = storage_buffer_from_bytes(bytes, SCOPE_PERSISTENT, "pick_dummy")
	return _dummy_buffer


# 将拾取参数按着色器约定打包为 push constant，统一两种拾取模式的输入布局。
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
	return _pick_layout.pack({
		mode = mode, grid_x = grid_size.x, grid_y = grid_size.y, grid_z = grid_size.z,
		terrain_res = terrain_res, target_size = target_size, target_slices = target_slices, search_radius = search_radius,
		base_x = base_x, base_z = base_z,
		ray_origin_x = ray_origin.x, ray_origin_y = ray_origin.y, ray_origin_z = ray_origin.z,
		dir_x = dir.x, dir_y = dir.y, dir_z = dir.z,
		grid_origin_x = grid_origin.x, grid_origin_y = grid_origin.y, grid_origin_z = grid_origin.z,
		voxel_size_x = voxel_size.x, voxel_size_y = voxel_size.y, voxel_size_z = voxel_size.z,
		capture_size = capture_size, max_height = max_height, surface_offset = surface_offset,
		vertical_span = vertical_span, display_scale = display_scale, occupancy_threshold = occupancy_threshold,
		max_t = max_t,
	})
