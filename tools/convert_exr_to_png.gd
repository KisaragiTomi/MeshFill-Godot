extends SceneTree

const ComputeShaderBaseScript := preload("res://scripts/godot_compute_shader_base.gd")

const RAW_PATH := "res://textures/scene_depth.raw"
const TEX_RES := 256
const MAX_HEIGHT := 120.0

const OUTPUT_PATH := "res://textures/scene_height_0_1.png"


func _init() -> void:
	var raw_img := _load_raw_rgba32f(RAW_PATH, TEX_RES, TEX_RES)
	if raw_img == null:
		quit(1)
		return

	_save_height_png(raw_img, OUTPUT_PATH)
	quit(0)

func _load_raw_rgba32f(path: String, width: int, height: int) -> Image:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("Failed to open raw file: %s" % path)
		return null

	var data := f.get_buffer(f.get_length())
	var expected_size := width * height * 4 * 4
	if data.size() != expected_size:
		push_warning("Raw size mismatch for %s: got %d, expected %d" % [path, data.size(), expected_size])
		return null

	return Image.create_from_data(width, height, false, Image.FORMAT_RGBAF, data)

func _save_height_png(img: Image, output_path: String) -> void:
	var result := _raw_depth_to_height_png_gpu(img)
	if result.is_empty():
		push_error("Failed to convert raw depth to height PNG on GPU")
		return

	var mm: Vector2 = result.get("height_range", Vector2.ZERO)
	print("height range: %.6f - %.6f" % [mm.x, mm.y])

	var out: Image = result.get("image")
	if out == null or out.is_empty():
		push_error("GPU conversion returned no image")
		return
	out.convert(Image.FORMAT_L8)

	var err := out.save_png(output_path)
	if err != OK:
		push_error("Failed to save PNG: %s (error %d)" % [output_path, err])
	else:
		print("Saved height PNG to: %s" % output_path)


func _raw_depth_to_height_png_gpu(img: Image) -> Dictionary:
	if img == null or img.is_empty():
		return {}
	var width := img.get_width()
	var height := img.get_height()
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		return {}
	probe_rd.free()

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "RawDepthToHeightPng"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return {}
	var rd: RenderingDevice = compute.get_rendering_device()
	var minmax_shader := compute.load_compute_shader("res://shaders/height_channel_minmax.glsl")
	var minmax_pipeline := compute.create_compute_pipeline(minmax_shader)
	var png_shader := compute.load_compute_shader("res://shaders/raw_depth_to_height_png.glsl")
	var png_pipeline := compute.create_compute_pipeline(png_shader)
	if not minmax_shader.is_valid() or not minmax_pipeline.is_valid() or not png_shader.is_valid() or not png_pipeline.is_valid():
		compute.dispose()
		return {}

	var depth_tex := compute.upload_texture_2d(
		img,
		RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
		Image.FORMAT_RGBAF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"raw_depth_rgba32f"
	)
	var minmax_bytes := PackedByteArray()
	minmax_bytes.resize(8)
	minmax_bytes.encode_u32(0, 0xFFFFFFFF)
	minmax_bytes.encode_u32(4, 0)
	var minmax_buf := compute.storage_buffer_from_bytes(minmax_bytes, ComputeShaderBaseScript.SCOPE_FRAME, "raw_depth_minmax_u32")
	var out_tex := compute.create_rw_texture_2d(
		width,
		height,
		RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM,
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"raw_depth_height_png_rgba8"
	)
	if not depth_tex.is_valid() or not minmax_buf.is_valid() or not out_tex.is_valid():
		compute.dispose()
		return {}

	var sampler := compute.create_linear_sampler()
	if not sampler.is_valid():
		compute.dispose()
		return {}
	var minmax_set0 := compute.create_uniform_set([
		compute.make_sampler_uniform(0, sampler, depth_tex),
	], minmax_shader, 0)
	var minmax_set1 := compute.create_uniform_set([
		compute.make_storage_uniform(0, minmax_buf),
	], minmax_shader, 1)
	var png_set0 := compute.create_uniform_set([
		compute.make_sampler_uniform(0, sampler, depth_tex),
		compute.make_storage_uniform(1, minmax_buf),
	], png_shader, 0)
	var png_set1 := compute.create_uniform_set([
		compute.make_image_uniform(0, out_tex),
	], png_shader, 1)
	if not minmax_set0.is_valid() or not minmax_set1.is_valid() or not png_set0.is_valid() or not png_set1.is_valid():
		compute.dispose()
		return {}

	var minmax_push := PackedByteArray()
	minmax_push.resize(16)
	minmax_push.encode_s32(0, width)
	minmax_push.encode_s32(4, height)
	minmax_push.encode_s32(8, 0)
	minmax_push.encode_s32(12, 0)

	var groups_x := ceili(float(width) / 32.0)
	var groups_y := ceili(float(height) / 32.0)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return {}
	rd.compute_list_bind_compute_pipeline(cl, minmax_pipeline)
	rd.compute_list_bind_uniform_set(cl, minmax_set0, 0)
	rd.compute_list_bind_uniform_set(cl, minmax_set1, 1)
	rd.compute_list_set_push_constant(cl, minmax_push, minmax_push.size())
	rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var png_push := PackedByteArray()
	png_push.resize(16)
	png_push.encode_s32(0, width)
	png_push.encode_s32(4, height)
	png_push.encode_float(8, MAX_HEIGHT)
	png_push.encode_float(12, 0.0001)

	cl = compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return {}
	rd.compute_list_bind_compute_pipeline(cl, png_pipeline)
	rd.compute_list_bind_uniform_set(cl, png_set0, 0)
	rd.compute_list_bind_uniform_set(cl, png_set1, 1)
	rd.compute_list_set_push_constant(cl, png_push, png_push.size())
	rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var minmax_data := rd.buffer_get_data(minmax_buf, 0, 8)
	var out_data := rd.texture_get_data(out_tex, 0)
	compute.dispose()
	if minmax_data.size() < 8:
		return {}
	var depth_min := _ordered_uint_to_float(int(minmax_data.decode_u32(0)))
	var depth_max := _ordered_uint_to_float(int(minmax_data.decode_u32(4)))
	return {
		"image": Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, out_data),
		"height_range": Vector2(MAX_HEIGHT - depth_max, MAX_HEIGHT - depth_min),
	}


func _ordered_uint_to_float(key: int) -> float:
	var bits := 0
	if (key & 0x80000000) != 0:
		bits = key ^ 0x80000000
	else:
		bits = (~key) & 0xFFFFFFFF
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_u32(0, bits)
	return bytes.decode_float(0)
