class_name TargetSceneVoxelGenerator
extends RefCounted

var texture_size: int = 256
var slice_count: int = 8
var max_height: float = 50.0
var capture_size: float = 120.0
var vertical_span: float = 16.0
var slope_start: float = 0.35
var slope_full: float = 0.8

var _rd: RenderingDevice
var _is_local_rd: bool = false
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

	_rd = RenderingServer.create_local_rendering_device()
	if _rd != null:
		_is_local_rd = true
	else:
		_rd = RenderingServer.get_rendering_device()
		_is_local_rd = false
	if _rd == null:
		push_error("[TargetSV] No RenderingDevice available; GPU TargetSV generation is required")
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

	var tex_scene := _upload_texture(scene_depth_img)
	var tex_target := _upload_texture(target_height_img)
	var tex_rock := _upload_texture(rock_img)
	var preview_tex := _create_rw_texture(texture_size, texture_size)
	var voxel_count := texture_size * texture_size * slice_count
	var visual_buffer := _storage_buffer_zero(voxel_count * 16)
	var collision_buffer := _storage_buffer_zero(voxel_count * 4)

	var set0 := _rd.uniform_set_create([
		_make_sampler_uniform(0, tex_scene),
		_make_sampler_uniform(1, tex_target),
		_make_sampler_uniform(2, tex_rock),
	], _shader, 0)
	var set1 := _rd.uniform_set_create([
		_make_storage_uniform(0, visual_buffer),
		_make_storage_uniform(1, collision_buffer),
	], _shader, 1)
	var set2 := _rd.uniform_set_create([
		_make_image_uniform(0, preview_tex),
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
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_bind_uniform_set(cl, set1, 1)
	_rd.compute_list_bind_uniform_set(cl, set2, 2)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, groups_x, groups_y, groups_z)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()

	var visual_bytes := _rd.buffer_get_data(visual_buffer)
	var collision_bytes := _rd.buffer_get_data(collision_buffer)
	var preview_data := _rd.texture_get_data(preview_tex, 0)
	var preview_img := Image.create_from_data(texture_size, texture_size, false, Image.FORMAT_RGBAH, preview_data)

	for rid in [tex_scene, tex_target, tex_rock, preview_tex, visual_buffer, collision_buffer]:
		if rid.is_valid():
			_rd.free_rid(rid)
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
	var path := "res://shaders/target_scene_voxel.glsl"
	var spirv: RDShaderSPIRV
	var source_text := _read_compute_shader_source(path)
	if not source_text.is_empty():
		var source := RDShaderSource.new()
		source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
		source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, source_text)
		spirv = _rd.shader_compile_spirv_from_source(source)
	else:
		var shader_file := load(path) as RDShaderFile
		if shader_file != null:
			spirv = shader_file.get_spirv()
	if spirv == null:
		push_error("[TargetSV] Failed to compile compute shader: %s" % path)
		return
	var err_msg := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if err_msg != "":
		push_error("[TargetSV] GLSL compile error [%s]: %s" % [path, err_msg])
		return
	_shader = _rd.shader_create_from_spirv(spirv)
	if _shader.is_valid():
		_pipeline = _rd.compute_pipeline_create(_shader)


func _read_compute_shader_source(path: String) -> String:
	var absolute_path := ProjectSettings.globalize_path(path)
	var source_text := FileAccess.get_file_as_string(absolute_path)
	if source_text.is_empty():
		source_text = FileAccess.get_file_as_string(path)
	if source_text.is_empty():
		return ""
	var lines := source_text.split("\n")
	var filtered: Array[String] = []
	for line in lines:
		if line.strip_edges() == "#[compute]":
			continue
		filtered.append(line)
	return "\n".join(filtered)


func _create_sampler() -> void:
	var ss := RDSamplerState.new()
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	_sampler = _rd.sampler_create(ss)


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
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	return _rd.texture_create(tf, RDTextureView.new(), [img.get_data()])


func _create_rw_texture(width: int, height: int) -> RID:
	var tf := RDTextureFormat.new()
	tf.width = width
	tf.height = height
	tf.depth = 1
	tf.array_layers = 1
	tf.mipmaps = 1
	tf.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tf.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	return _rd.texture_create(tf, RDTextureView.new())


func _storage_buffer_zero(byte_count: int) -> RID:
	var bytes := PackedByteArray()
	bytes.resize(maxi(byte_count, 4))
	return _rd.storage_buffer_create(bytes.size(), bytes)


func _make_sampler_uniform(binding: int, tex: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = binding
	uniform.add_id(_sampler)
	uniform.add_id(tex)
	return uniform


func _make_storage_uniform(binding: int, buffer: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform


func _make_image_uniform(binding: int, tex: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = binding
	uniform.add_id(tex)
	return uniform


func _free_gpu() -> void:
	for rid in [_pipeline, _shader, _sampler]:
		if rid.is_valid() and _rd != null:
			_rd.free_rid(rid)
	_pipeline = RID()
	_shader = RID()
	_sampler = RID()
	if _rd != null and _is_local_rd:
		_rd.free()
	_rd = null
	_is_local_rd = false
