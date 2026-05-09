class_name NutritionLayer
extends PCGLayer

var _rd: RenderingDevice
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

	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		push_error("[NutritionLayer] Failed to create RenderingDevice")
		return

	_load_shader()

	var dr := dirty_rect
	if dr.size.x <= 0 or dr.size.y <= 0:
		dr = Rect2i(0, 0, texture_size, texture_size)

	var ss := RDSamplerState.new()
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	_sampler = _rd.sampler_create(ss)

	var tex_depth := _upload_texture(scene_depth_img)
	var tex_rock := _upload_texture(rock_mask_img)
	var tex_output := _create_rw_texture(texture_size, texture_size)

	var u_depth := RDUniform.new()
	u_depth.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_depth.binding = 0
	u_depth.add_id(_sampler)
	u_depth.add_id(tex_depth)

	var u_rock := RDUniform.new()
	u_rock.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_rock.binding = 1
	u_rock.add_id(_sampler)
	u_rock.add_id(tex_rock)

	var set0 := _rd.uniform_set_create([u_depth, u_rock], _shader, 0)

	var u_out := RDUniform.new()
	u_out.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_out.binding = 0
	u_out.add_id(tex_output)
	var set1 := _rd.uniform_set_create([u_out], _shader, 1)

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

	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_bind_uniform_set(cl, set1, 1)
	_rd.compute_list_set_push_constant(cl, push_buf, push_buf.size())
	_rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()

	var data := _rd.texture_get_data(tex_output, 0)
	var result_img := Image.create_from_data(texture_size, texture_size, false, Image.FORMAT_RGBAH, data)
	outputs["nutrition"] = result_img

	_rd.free_rid(tex_depth)
	_rd.free_rid(tex_rock)
	_rd.free_rid(tex_output)
	_rd.free_rid(_pipeline)
	_rd.free_rid(_shader)
	_rd.free_rid(_sampler)
	_rd.free()
	_rd = null


func _load_shader() -> void:
	var shader_file := load("res://shaders/compute_nutrition.glsl") as RDShaderFile
	if shader_file == null:
		push_error("[NutritionLayer] Failed to load shader")
		return
	var spirv := shader_file.get_spirv()
	var err_msg := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if err_msg != "":
		push_error("[NutritionLayer] GLSL compile error: %s" % err_msg)
		return
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)


func _upload_texture(image: Image) -> RID:
	var img := image
	if img.get_format() != Image.FORMAT_RGBAH:
		img = img.duplicate()
		img.convert(Image.FORMAT_RGBAH)
	var tf := RDTextureFormat.new()
	tf.width = img.get_width()
	tf.height = img.get_height()
	tf.depth = 1
	tf.array_layers = 1
	tf.mipmaps = 1
	tf.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tf.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)
	return _rd.texture_create(tf, RDTextureView.new(), [img.get_data()])


func _create_rw_texture(w: int, h: int) -> RID:
	var tf := RDTextureFormat.new()
	tf.width = w
	tf.height = h
	tf.depth = 1
	tf.array_layers = 1
	tf.mipmaps = 1
	tf.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tf.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	)
	return _rd.texture_create(tf, RDTextureView.new())
