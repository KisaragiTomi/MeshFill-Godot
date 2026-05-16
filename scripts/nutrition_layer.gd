class_name NutritionLayer
extends PCGLayer

const ComputeShaderBaseScript := preload("res://scripts/godot_compute_shader_base.gd")

var _rd: RenderingDevice
var _compute
var _shader: RID
var _pipeline: RID
var _sampler: RID
var texture_size: int = 256
var max_height: float = 50.0
var capture_size: float = 60.0


func _init() -> void:
	layer_name = "nutrition"


func generate(dirty_rect: Rect2i = Rect2i()) -> void:
	var scene_depth_img: Image = inputs.get("scene_depth")
	var rock_mask_img: Image = inputs.get("rock_mask")
	if scene_depth_img == null:
		push_error("[NutritionLayer] Missing required input: scene_depth")
		return

	if rock_mask_img == null:
		rock_mask_img = Image.create(texture_size, texture_size, false, Image.FORMAT_RGBAF)
		rock_mask_img.fill(Color(0.0, 0.0, 0.0, 0.0))

	_compute = ComputeShaderBaseScript.new()
	_compute.log_name = "NutritionLayer"
	if not _compute.ensure_device():
		return
	_rd = _compute.get_rendering_device()

	_load_shader()

	var dr := dirty_rect
	if dr.size.x <= 0 or dr.size.y <= 0:
		dr = Rect2i(0, 0, texture_size, texture_size)

	_sampler = _compute.create_linear_sampler()

	var tex_depth: RID = _compute.upload_texture_2d(scene_depth_img)
	var tex_rock: RID = _compute.upload_texture_2d(rock_mask_img)
	var tex_output: RID = _compute.create_rw_texture_2d(texture_size, texture_size)

	var set0: RID = _compute.create_uniform_set([
		_compute.make_sampler_uniform(0, _sampler, tex_depth),
		_compute.make_sampler_uniform(1, _sampler, tex_rock),
	], _shader, 0)
	var set1: RID = _compute.create_uniform_set([
		_compute.make_image_uniform(0, tex_output),
	], _shader, 1)

	var push_buf := PackedByteArray()
	push_buf.resize(32)
	push_buf.encode_float(0, max_height)
	push_buf.encode_float(4, capture_size)
	push_buf.encode_s32(8, dr.position.x)
	push_buf.encode_s32(12, dr.position.y)
	push_buf.encode_s32(16, dr.size.x)
	push_buf.encode_s32(20, dr.size.y)

	var groups_x := ceili(float(dr.size.x) / 32.0)
	var groups_y := ceili(float(dr.size.y) / 32.0)

	var cl: int = _compute.begin_compute_list()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_bind_uniform_set(cl, set1, 1)
	_rd.compute_list_set_push_constant(cl, push_buf, push_buf.size())
	_rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	_compute.end_compute_list()
	_compute.submit_and_sync()

	var data := _rd.texture_get_data(tex_output, 0)
	var result_img := Image.create_from_data(texture_size, texture_size, false, Image.FORMAT_RGBAH, data)
	outputs["nutrition"] = result_img

	_compute.dispose()
	_rd = null
	_compute = null
	_shader = RID()
	_pipeline = RID()
	_sampler = RID()


func _load_shader() -> void:
	_shader = _compute.load_compute_shader("res://shaders/compute_nutrition.glsl")
	if _shader.is_valid():
		_pipeline = _compute.create_compute_pipeline(_shader)
