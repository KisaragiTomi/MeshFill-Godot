class_name TargetSceneVoxelGenerator
extends "res://scripts/godot_compute_shader_base.gd"

var texture_size: int = 256
var slice_count: int = 8
var max_height: float = 50.0
var capture_size: float = 120.0
var vertical_span: float = 16.0
var slope_start: float = 0.35
var slope_full: float = 0.8

var _shader: RID
var _pipeline: RID
var _sampler: RID


func generate(scene_depth_img: Image, target_height_img: Image, rock_mask_img: Image = null, dirty_rect: Rect2i = Rect2i()) -> Dictionary:
	if scene_depth_img == null or target_height_img == null:
		push_error("[TargetSV] Missing scene_depth or target_height input")
		return {}

	texture_size = scene_depth_img.get_width()
	var dr := dirty_rect
	if dr.size.x <= 0 or dr.size.y <= 0:
		dr = Rect2i(0, 0, texture_size, texture_size)
	dr = dr.intersection(Rect2i(0, 0, texture_size, texture_size))
	if dr.size.x <= 0 or dr.size.y <= 0:
		push_error("[TargetSV] Empty dirty rect")
		return {}

	log_name = "TargetSceneVoxelGenerator"
	sync_global_device = true
	if not ensure_device(true, true):
		return {}

	_load_shader()
	if not _shader.is_valid() or not _pipeline.is_valid():
		_free_gpu()
		return {}

	_create_sampler()
	var rock_img := rock_mask_img
	if rock_img == null:
		rock_img = Image.create(texture_size, texture_size, false, Image.FORMAT_RGBAF)
		rock_img.fill(Color(0.0, 0.0, 0.0, 0.0))

	var tex_scene := upload_texture_2d(scene_depth_img)
	var tex_target := upload_texture_2d(target_height_img)
	var tex_rock := upload_texture_2d(rock_img)
	var preview_tex := create_rw_texture_2d(texture_size, texture_size)
	var voxel_count := texture_size * texture_size * slice_count
	var visual_buffer := storage_buffer_zero(voxel_count * 16)
	var collision_buffer := storage_buffer_zero(voxel_count * 4)

	var set0 := create_uniform_set([
		make_sampler_uniform(0, _sampler, tex_scene),
		make_sampler_uniform(1, _sampler, tex_target),
		make_sampler_uniform(2, _sampler, tex_rock),
	], _shader, 0)
	var set1 := create_uniform_set([
		make_storage_uniform(0, visual_buffer),
		make_storage_uniform(1, collision_buffer),
	], _shader, 1)
	var set2 := create_uniform_set([
		make_image_uniform(0, preview_tex),
	], _shader, 2)

	var push := PackedByteArray()
	push.resize(48)
	push.encode_float(0, max_height)
	push.encode_float(4, capture_size)
	push.encode_float(8, vertical_span)
	push.encode_float(12, slope_start)
	push.encode_float(16, slope_full)
	push.encode_s32(20, texture_size)
	push.encode_s32(24, slice_count)
	push.encode_s32(28, dr.position.x)
	push.encode_s32(32, dr.position.y)
	push.encode_s32(36, dr.size.x)
	push.encode_s32(40, dr.size.y)
	push.encode_s32(44, 0)

	var groups_x := ceili(float(dr.size.x) / 8.0)
	var groups_y := ceili(float(slice_count) / 4.0)
	var groups_z := ceili(float(dr.size.y) / 8.0)
	var cl := begin_compute_list()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_bind_uniform_set(cl, set1, 1)
	_rd.compute_list_bind_uniform_set(cl, set2, 2)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, groups_x, groups_y, groups_z)
	end_compute_list()
	submit_and_sync(true)

	var visual_bytes := _rd.buffer_get_data(visual_buffer)
	var collision_bytes := _rd.buffer_get_data(collision_buffer)
	var preview_data := _rd.texture_get_data(preview_tex, 0)
	var preview_img := Image.create_from_data(texture_size, texture_size, false, Image.FORMAT_RGBAH, preview_data)

	_free_gpu()

	return {
		"valid": true,
		"texture_size": texture_size,
		"slice_count": slice_count,
		"voxel_count": voxel_count,
		"max_height": max_height,
		"capture_size": capture_size,
		"vertical_span": vertical_span,
		"visual_format": "rgba32f",
		"collision_format": "r32f",
		"visual_bytes": visual_bytes,
		"collision_bytes": collision_bytes,
		"preview_image": preview_img,
	}


func _load_shader() -> void:
	_shader = load_compute_shader("res://shaders/target_scene_voxel.glsl")
	if _shader.is_valid():
		_pipeline = create_compute_pipeline(_shader)


func _create_sampler() -> void:
	_sampler = create_linear_sampler()


func _free_gpu() -> void:
	dispose()
	_pipeline = RID()
	_shader = RID()
	_sampler = RID()
