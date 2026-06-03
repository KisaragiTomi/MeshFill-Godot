class_name VegetationScatter
extends RefCounted

const ComputeShaderBaseScript := preload("res://scripts/godot_compute_shader_base.gd")
const _VEGETATION_CHANNEL_MASK_SHADER := "res://shaders/vegetation_channel_mask.glsl"
const _VEGETATION_ALL_CHANNEL_MASK_SHADER := "res://shaders/vegetation_all_channel_mask.glsl"
const _VEGETATION_SPLIT_CHANNEL_MASKS_SHADER := "res://shaders/vegetation_split_channel_masks.glsl"
const _VEGETATION_SPLIT_CHANNEL_MASKS_WITH_COUNTS_SHADER := "res://shaders/vegetation_split_channel_masks_with_counts.glsl"
const _VEGETATION_CHANNEL_COUNTS_SHADER := "res://shaders/vegetation_channel_counts.glsl"
const _MASK_HAS_PIXELS_SHADER := "res://shaders/mask_has_pixels.glsl"
const _VEGETATION_CHANNEL_MASK_LOCAL_SIZE := 32
const _VEGETATION_ALL_CHANNEL_MASK_LOCAL_SIZE := 32
const _VEGETATION_SPLIT_CHANNEL_MASKS_LOCAL_SIZE := 32
const _VEGETATION_SPLIT_CHANNEL_MASKS_WITH_COUNTS_LOCAL_SIZE := 32
const _MASK_HAS_PIXELS_LOCAL_SIZE := 32
const _VEGETATION_CHANNEL_COUNTS_LOCAL_SIZE := 32

const TREE_VISUAL_LAYER := 11
const BUSH_VISUAL_LAYER := 12
const MIDSTORY_VISUAL_LAYER := 13
const GRASS_VISUAL_LAYER := 14


static func create_tree_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var trunk_mat := StandardMaterial3D.new()
	trunk_mat.albedo_color = Color(0.45, 0.30, 0.15)
	trunk_mat.roughness = 0.9

	var trunk_r := 0.15
	var trunk_h := 1.5
	var segments := 8
	_add_cylinder(st, Vector3.ZERO, trunk_r, trunk_h, segments)

	var crown_r := 0.8
	var crown_h := 2.0
	var crown_base := Vector3(0, trunk_h, 0)
	_add_cone(st, crown_base, crown_r, crown_h, segments)
	var crown_base2 := Vector3(0, trunk_h + crown_h * 0.4, 0)
	_add_cone(st, crown_base2, crown_r * 0.75, crown_h * 0.8, segments)

	st.generate_normals()
	var mesh := st.commit()

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.25, 0.50, 0.20)
	mat.roughness = 0.85
	mat.vertex_color_use_as_albedo = true
	mesh.surface_set_material(0, mat)
	return mesh


static func create_midstory_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var trunk_r := 0.10
	var trunk_h := 1.0
	var segments := 8
	_add_cylinder(st, Vector3.ZERO, trunk_r, trunk_h, segments)

	var crown_r := 0.6
	var crown_h := 1.2
	var crown_base := Vector3(0, trunk_h, 0)
	_add_cone(st, crown_base, crown_r, crown_h, segments)

	st.generate_normals()
	var mesh := st.commit()

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.20, 0.45, 0.30)
	mat.roughness = 0.85
	mat.vertex_color_use_as_albedo = true
	mesh.surface_set_material(0, mat)
	return mesh


static func create_bush_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var segments := 8
	_add_sphere(st, Vector3(0, 0.3, 0), 0.4, 0.35, segments)
	_add_sphere(st, Vector3(0.2, 0.25, 0.15), 0.3, 0.28, segments)
	_add_sphere(st, Vector3(-0.15, 0.2, -0.1), 0.35, 0.3, segments)

	st.generate_normals()
	var mesh := st.commit()

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.30, 0.55, 0.22)
	mat.roughness = 0.9
	mat.vertex_color_use_as_albedo = true
	mesh.surface_set_material(0, mat)
	return mesh


static func create_flower_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var segments := 6
	_add_cylinder(st, Vector3.ZERO, 0.025, 0.35, segments)
	var bloom_center := Vector3(0.0, 0.38, 0.0)
	_add_sphere(st, bloom_center, 0.055, 0.045, segments)
	for i in range(6):
		_add_petal(st, bloom_center, float(i) / 6.0 * TAU, 0.18, 0.055)

	st.generate_normals()
	var mesh := st.commit()

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.35, 0.5)
	mat.roughness = 0.75
	mat.vertex_color_use_as_albedo = true
	mesh.surface_set_material(0, mat)
	return mesh


static func _add_cylinder(st: SurfaceTool, base: Vector3, radius: float, height: float, segments: int) -> void:
	var top := base + Vector3(0, height, 0)
	for i in range(segments):
		var angle_a := float(i) / float(segments) * TAU
		var angle_b := float(i + 1) / float(segments) * TAU
		var ba := base + Vector3(cos(angle_a) * radius, 0, sin(angle_a) * radius)
		var bb := base + Vector3(cos(angle_b) * radius, 0, sin(angle_b) * radius)
		var ta := top + Vector3(cos(angle_a) * radius * 0.6, 0, sin(angle_a) * radius * 0.6)
		var tb := top + Vector3(cos(angle_b) * radius * 0.6, 0, sin(angle_b) * radius * 0.6)

		st.set_color(Color(0.45, 0.30, 0.15, 1.0))
		st.add_vertex(ba)
		st.add_vertex(bb)
		st.add_vertex(ta)
		st.add_vertex(ta)
		st.add_vertex(bb)
		st.add_vertex(tb)


static func _add_cone(st: SurfaceTool, base: Vector3, radius: float, height: float, segments: int) -> void:
	var tip := base + Vector3(0, height, 0)
	for i in range(segments):
		var angle_a := float(i) / float(segments) * TAU
		var angle_b := float(i + 1) / float(segments) * TAU
		var va := base + Vector3(cos(angle_a) * radius, 0, sin(angle_a) * radius)
		var vb := base + Vector3(cos(angle_b) * radius, 0, sin(angle_b) * radius)

		st.set_color(Color(0.25, 0.50, 0.20, 1.0))
		st.add_vertex(va)
		st.add_vertex(vb)
		st.add_vertex(tip)


static func _add_sphere(st: SurfaceTool, center: Vector3, radius_h: float, radius_v: float, segments: int) -> void:
	var rings := segments / 2
	for j in range(rings):
		var phi_a := float(j) / float(rings) * PI
		var phi_b := float(j + 1) / float(rings) * PI
		for i in range(segments):
			var theta_a := float(i) / float(segments) * TAU
			var theta_b := float(i + 1) / float(segments) * TAU

			var v00 := center + Vector3(
				sin(phi_a) * cos(theta_a) * radius_h,
				cos(phi_a) * radius_v,
				sin(phi_a) * sin(theta_a) * radius_h
			)
			var v10 := center + Vector3(
				sin(phi_b) * cos(theta_a) * radius_h,
				cos(phi_b) * radius_v,
				sin(phi_b) * sin(theta_a) * radius_h
			)
			var v01 := center + Vector3(
				sin(phi_a) * cos(theta_b) * radius_h,
				cos(phi_a) * radius_v,
				sin(phi_a) * sin(theta_b) * radius_h
			)
			var v11 := center + Vector3(
				sin(phi_b) * cos(theta_b) * radius_h,
				cos(phi_b) * radius_v,
				sin(phi_b) * sin(theta_b) * radius_h
			)

			st.set_color(Color(0.30, 0.55, 0.22, 1.0))
			st.add_vertex(v00)
			st.add_vertex(v10)
			st.add_vertex(v01)
			st.add_vertex(v01)
			st.add_vertex(v10)
			st.add_vertex(v11)


static func _add_petal(st: SurfaceTool, center: Vector3, angle: float, length: float, width: float) -> void:
	var dir := Vector3(cos(angle), 0.0, sin(angle))
	var side := Vector3(-sin(angle), 0.0, cos(angle))
	var base := center + dir * 0.035
	var tip := center + dir * length + Vector3(0.0, 0.025, 0.0)
	var left := base + side * width
	var right := base - side * width

	st.set_color(Color(0.9, 0.35, 0.5, 1.0))
	st.add_vertex(center)
	st.add_vertex(left)
	st.add_vertex(tip)
	st.add_vertex(center)
	st.add_vertex(tip)
	st.add_vertex(right)


static func make_vegetation_channel_mask_from_occupancy_gpu(
	occupancy: Image,
	channel: int,
	active_threshold: float = 0.01,
	output_size: Vector2i = Vector2i.ZERO
) -> Image:
	# GPU-only helper: reads RGBA16F occupancy and writes an R32F mask.
	# Contract: returns null when the input is invalid or no RenderingDevice exists.
	if occupancy == null or occupancy.is_empty():
		return null
	if channel < 0 or channel >= 4:
		return null

	var src_width := occupancy.get_width()
	var src_height := occupancy.get_height()
	var out_width := output_size.x if output_size.x > 0 else src_width
	var out_height := output_size.y if output_size.y > 0 else src_height
	if src_width <= 0 or src_height <= 0 or out_width <= 0 or out_height <= 0:
		return null

	var compute := ComputeShaderBaseScript.new()
	compute.log_name = "VegetationScatterChannelMask"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return null

	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader(_VEGETATION_CHANNEL_MASK_SHADER)
	var pipeline := compute.create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return null

	var sampler := compute.create_linear_sampler(
		ComputeShaderBaseScript.SCOPE_FRAME,
		"vegetation_channel_mask_sampler"
	)
	var occupancy_tex := compute.upload_texture_2d(
		occupancy,
		RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
		Image.FORMAT_RGBAH,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"vegetation_occupancy_rgba16f"
	)
	var out_tex := compute.create_rw_texture_2d(
		out_width,
		out_height,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"vegetation_channel_mask_r32f"
	)
	if not sampler.is_valid() or not occupancy_tex.is_valid() or not out_tex.is_valid():
		compute.dispose()
		return null

	var set0 := compute.create_uniform_set([
		compute.make_sampler_uniform(0, sampler, occupancy_tex),
	], shader, 0, ComputeShaderBaseScript.SCOPE_PASS, "vegetation_channel_mask_set0")
	var set1 := compute.create_uniform_set([
		compute.make_image_uniform(0, out_tex),
	], shader, 1, ComputeShaderBaseScript.SCOPE_PASS, "vegetation_channel_mask_set1")
	if not set0.is_valid() or not set1.is_valid():
		compute.dispose()
		return null

	var push := PackedByteArray()
	push.resize(32)
	push.encode_s32(0, out_width)
	push.encode_s32(4, out_height)
	push.encode_s32(8, src_width)
	push.encode_s32(12, src_height)
	push.encode_s32(16, channel)
	push.encode_float(20, active_threshold)
	push.encode_float(24, 0.0)
	push.encode_float(28, 0.0)

	var groups := compute.dispatch_groups_2d(out_width, out_height, _VEGETATION_CHANNEL_MASK_LOCAL_SIZE, _VEGETATION_CHANNEL_MASK_LOCAL_SIZE)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return null

	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_bind_uniform_set(cl, set1, 1)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, groups.x, groups.y, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var data := rd.texture_get_data(out_tex, 0)
	compute.dispose()
	if data.is_empty():
		return null

	return Image.create_from_data(out_width, out_height, false, Image.FORMAT_RF, data)


static func count_mask_pixels_gpu(mask_img: Image, threshold: float = 0.01) -> int:
	# GPU-only helper: reads an R32F mask and returns the number of pixels above threshold.
	# Contract: returns -1 when the input is invalid, the shader fails, or no RenderingDevice exists.
	if mask_img == null or mask_img.is_empty():
		return -1
	var width := mask_img.get_width()
	var height := mask_img.get_height()
	if width <= 0 or height <= 0:
		return -1

	var compute := ComputeShaderBaseScript.new()
	compute.log_name = "VegetationScatterMaskCount"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return -1

	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader(_MASK_HAS_PIXELS_SHADER)
	var pipeline := compute.create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return -1

	var mask_tex := compute.upload_texture_2d(
		mask_img,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		Image.FORMAT_RF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"vegetation_mask_count_src_r32f"
	)
	var counter_buf := compute.storage_buffer_zero(
		4,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"vegetation_mask_count_u32"
	)
	var sampler := compute.create_linear_sampler(
		ComputeShaderBaseScript.SCOPE_FRAME,
		"vegetation_mask_count_sampler"
	)
	if not mask_tex.is_valid() or not counter_buf.is_valid() or not sampler.is_valid():
		compute.dispose()
		return -1

	var set0 := compute.create_uniform_set([
		compute.make_sampler_uniform(0, sampler, mask_tex),
	], shader, 0, ComputeShaderBaseScript.SCOPE_PASS, "vegetation_mask_count_set0")
	var set1 := compute.create_uniform_set([
		compute.make_storage_uniform(0, counter_buf),
	], shader, 1, ComputeShaderBaseScript.SCOPE_PASS, "vegetation_mask_count_set1")
	if not set0.is_valid() or not set1.is_valid():
		compute.dispose()
		return -1

	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, width)
	push.encode_s32(4, height)
	push.encode_float(8, threshold)
	push.encode_float(12, 0.0)

	var groups := compute.dispatch_groups_2d(width, height, _MASK_HAS_PIXELS_LOCAL_SIZE, _MASK_HAS_PIXELS_LOCAL_SIZE)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return -1

	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_bind_uniform_set(cl, set1, 1)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, groups.x, groups.y, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var counter_data := rd.buffer_get_data(counter_buf, 0, 4)
	var hit_count := _decode_u32(counter_data, -1)
	compute.dispose()
	return hit_count


static func make_vegetation_channel_mask_with_count_gpu(
	occupancy: Image,
	channel: int,
	active_threshold: float = 0.01,
	output_size: Vector2i = Vector2i.ZERO
) -> Dictionary:
	# Two-pass GPU helper: channel mask image pass -> barrier -> active-pixel count pass.
	# Returns {"mask": Image, "active_count": int}; returns {} when setup or execution fails.
	if occupancy == null or occupancy.is_empty():
		return {}
	if channel < 0 or channel >= 4:
		return {}

	var src_width := occupancy.get_width()
	var src_height := occupancy.get_height()
	var out_width := output_size.x if output_size.x > 0 else src_width
	var out_height := output_size.y if output_size.y > 0 else src_height
	if src_width <= 0 or src_height <= 0 or out_width <= 0 or out_height <= 0:
		return {}

	var compute := ComputeShaderBaseScript.new()
	compute.log_name = "VegetationScatterChannelMaskWithCount"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return {}

	var rd: RenderingDevice = compute.get_rendering_device()
	var mask_shader := compute.load_compute_shader(_VEGETATION_CHANNEL_MASK_SHADER)
	var mask_pipeline := compute.create_compute_pipeline(mask_shader)
	var count_shader := compute.load_compute_shader(_MASK_HAS_PIXELS_SHADER)
	var count_pipeline := compute.create_compute_pipeline(count_shader)
	if (
		not mask_shader.is_valid()
		or not mask_pipeline.is_valid()
		or not count_shader.is_valid()
		or not count_pipeline.is_valid()
	):
		compute.dispose()
		return {}

	var sampler := compute.create_linear_sampler(
		ComputeShaderBaseScript.SCOPE_FRAME,
		"vegetation_mask_with_count_sampler"
	)
	var occupancy_tex := compute.upload_texture_2d(
		occupancy,
		RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
		Image.FORMAT_RGBAH,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"vegetation_occupancy_rgba16f"
	)
	var mask_tex := compute.create_rw_texture_2d(
		out_width,
		out_height,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		(
			RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
			RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |
			RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		),
		ComputeShaderBaseScript.SCOPE_FRAME,
		"vegetation_channel_mask_r32f"
	)
	var counter_buf := compute.storage_buffer_zero(
		4,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"vegetation_mask_count_u32"
	)
	if (
		not sampler.is_valid()
		or not occupancy_tex.is_valid()
		or not mask_tex.is_valid()
		or not counter_buf.is_valid()
	):
		compute.dispose()
		return {}

	var mask_set0 := compute.create_uniform_set([
		compute.make_sampler_uniform(0, sampler, occupancy_tex),
	], mask_shader, 0, ComputeShaderBaseScript.SCOPE_PASS, "vegetation_channel_mask_set0")
	var mask_set1 := compute.create_uniform_set([
		compute.make_image_uniform(0, mask_tex),
	], mask_shader, 1, ComputeShaderBaseScript.SCOPE_PASS, "vegetation_channel_mask_set1")
	var count_set0 := compute.create_uniform_set([
		compute.make_sampler_uniform(0, sampler, mask_tex),
	], count_shader, 0, ComputeShaderBaseScript.SCOPE_PASS, "vegetation_mask_count_set0")
	var count_set1 := compute.create_uniform_set([
		compute.make_storage_uniform(0, counter_buf),
	], count_shader, 1, ComputeShaderBaseScript.SCOPE_PASS, "vegetation_mask_count_set1")
	if not mask_set0.is_valid() or not mask_set1.is_valid() or not count_set0.is_valid() or not count_set1.is_valid():
		compute.dispose()
		return {}

	var mask_push := PackedByteArray()
	mask_push.resize(32)
	mask_push.encode_s32(0, out_width)
	mask_push.encode_s32(4, out_height)
	mask_push.encode_s32(8, src_width)
	mask_push.encode_s32(12, src_height)
	mask_push.encode_s32(16, channel)
	mask_push.encode_float(20, active_threshold)
	mask_push.encode_float(24, 0.0)
	mask_push.encode_float(28, 0.0)

	var count_push := PackedByteArray()
	count_push.resize(16)
	count_push.encode_s32(0, out_width)
	count_push.encode_s32(4, out_height)
	count_push.encode_float(8, active_threshold)
	count_push.encode_float(12, 0.0)

	var mask_groups := compute.dispatch_groups_2d(out_width, out_height, _VEGETATION_CHANNEL_MASK_LOCAL_SIZE, _VEGETATION_CHANNEL_MASK_LOCAL_SIZE)
	var count_groups := compute.dispatch_groups_2d(out_width, out_height, _MASK_HAS_PIXELS_LOCAL_SIZE, _MASK_HAS_PIXELS_LOCAL_SIZE)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return {}

	rd.compute_list_bind_compute_pipeline(cl, mask_pipeline)
	rd.compute_list_bind_uniform_set(cl, mask_set0, 0)
	rd.compute_list_bind_uniform_set(cl, mask_set1, 1)
	rd.compute_list_set_push_constant(cl, mask_push, mask_push.size())
	rd.compute_list_dispatch(cl, mask_groups.x, mask_groups.y, 1)
	rd.compute_list_add_barrier(cl)
	rd.compute_list_bind_compute_pipeline(cl, count_pipeline)
	rd.compute_list_bind_uniform_set(cl, count_set0, 0)
	rd.compute_list_bind_uniform_set(cl, count_set1, 1)
	rd.compute_list_set_push_constant(cl, count_push, count_push.size())
	rd.compute_list_dispatch(cl, count_groups.x, count_groups.y, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var mask_data := rd.texture_get_data(mask_tex, 0)
	var counter_data := rd.buffer_get_data(counter_buf, 0, 4)
	var active_count := _decode_u32(counter_data, -1)
	compute.dispose()
	if mask_data.is_empty() or active_count < 0:
		return {}

	return {
		"mask": Image.create_from_data(out_width, out_height, false, Image.FORMAT_RF, mask_data),
		"active_count": active_count,
	}


static func count_vegetation_channels_gpu(occupancy: Image, active_threshold: float = 0.01) -> PackedInt32Array:
	# GPU-only helper: reads RGBA16F occupancy and returns 4 u32 active counts.
	# Contract: returns an empty array when setup or execution fails.
	if occupancy == null or occupancy.is_empty():
		return PackedInt32Array()
	var width := occupancy.get_width()
	var height := occupancy.get_height()
	if width <= 0 or height <= 0:
		return PackedInt32Array()

	var compute := ComputeShaderBaseScript.new()
	compute.log_name = "VegetationScatterChannelCounts"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return PackedInt32Array()

	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader(_VEGETATION_CHANNEL_COUNTS_SHADER)
	var pipeline := compute.create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return PackedInt32Array()

	var sampler := compute.create_linear_sampler(
		ComputeShaderBaseScript.SCOPE_FRAME,
		"vegetation_channel_counts_sampler"
	)
	var occupancy_tex := compute.upload_texture_2d(
		occupancy,
		RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
		Image.FORMAT_RGBAH,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"vegetation_occupancy_rgba16f"
	)
	var counts_buf := compute.storage_buffer_zero(
		16,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"vegetation_channel_counts_u32x4"
	)
	if not sampler.is_valid() or not occupancy_tex.is_valid() or not counts_buf.is_valid():
		compute.dispose()
		return PackedInt32Array()

	var set0 := compute.create_uniform_set([
		compute.make_sampler_uniform(0, sampler, occupancy_tex),
	], shader, 0, ComputeShaderBaseScript.SCOPE_PASS, "vegetation_channel_counts_set0")
	var set1 := compute.create_uniform_set([
		compute.make_storage_uniform(0, counts_buf),
	], shader, 1, ComputeShaderBaseScript.SCOPE_PASS, "vegetation_channel_counts_set1")
	if not set0.is_valid() or not set1.is_valid():
		compute.dispose()
		return PackedInt32Array()

	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, width)
	push.encode_s32(4, height)
	push.encode_float(8, active_threshold)
	push.encode_float(12, 0.0)

	var groups := compute.dispatch_groups_2d(width, height, _VEGETATION_CHANNEL_COUNTS_LOCAL_SIZE, _VEGETATION_CHANNEL_COUNTS_LOCAL_SIZE)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return PackedInt32Array()

	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_bind_uniform_set(cl, set1, 1)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, groups.x, groups.y, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var counts_bytes := rd.buffer_get_data(counts_buf, 0, 16)
	compute.dispose()
	if counts_bytes.size() < 16:
		return PackedInt32Array()

	return PackedInt32Array([
		_decode_u32(counts_bytes.slice(0, 4), 0),
		_decode_u32(counts_bytes.slice(4, 8), 0),
		_decode_u32(counts_bytes.slice(8, 12), 0),
		_decode_u32(counts_bytes.slice(12, 16), 0),
	])


static func make_vegetation_all_channel_mask_gpu(
	occupancy: Image,
	active_threshold: float = 0.01,
	output_size: Vector2i = Vector2i.ZERO
) -> Image:
	# GPU-only helper: reads RGBA16F occupancy and writes a thresholded RGBA16F mask.
	# Contract: returns null when setup or execution fails.
	if occupancy == null or occupancy.is_empty():
		return null

	var src_width := occupancy.get_width()
	var src_height := occupancy.get_height()
	var out_width := output_size.x if output_size.x > 0 else src_width
	var out_height := output_size.y if output_size.y > 0 else src_height
	if src_width <= 0 or src_height <= 0 or out_width <= 0 or out_height <= 0:
		return null

	var compute := ComputeShaderBaseScript.new()
	compute.log_name = "VegetationScatterAllChannelMask"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return null

	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader(_VEGETATION_ALL_CHANNEL_MASK_SHADER)
	var pipeline := compute.create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return null

	var sampler := compute.create_linear_sampler(
		ComputeShaderBaseScript.SCOPE_FRAME,
		"vegetation_all_channel_mask_sampler"
	)
	var occupancy_tex := compute.upload_texture_2d(
		occupancy,
		RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
		Image.FORMAT_RGBAH,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"vegetation_occupancy_rgba16f"
	)
	var out_tex := compute.create_rw_texture_2d(
		out_width,
		out_height,
		RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"vegetation_all_channel_mask_rgba16f"
	)
	if not sampler.is_valid() or not occupancy_tex.is_valid() or not out_tex.is_valid():
		compute.dispose()
		return null

	var set0 := compute.create_uniform_set([
		compute.make_sampler_uniform(0, sampler, occupancy_tex),
	], shader, 0, ComputeShaderBaseScript.SCOPE_PASS, "vegetation_all_channel_mask_set0")
	var set1 := compute.create_uniform_set([
		compute.make_image_uniform(0, out_tex),
	], shader, 1, ComputeShaderBaseScript.SCOPE_PASS, "vegetation_all_channel_mask_set1")
	if not set0.is_valid() or not set1.is_valid():
		compute.dispose()
		return null

	var push := PackedByteArray()
	push.resize(32)
	push.encode_s32(0, out_width)
	push.encode_s32(4, out_height)
	push.encode_s32(8, src_width)
	push.encode_s32(12, src_height)
	push.encode_float(16, active_threshold)
	push.encode_float(20, 0.0)
	push.encode_float(24, 0.0)
	push.encode_float(28, 0.0)

	var groups := compute.dispatch_groups_2d(out_width, out_height, _VEGETATION_ALL_CHANNEL_MASK_LOCAL_SIZE, _VEGETATION_ALL_CHANNEL_MASK_LOCAL_SIZE)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return null

	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_bind_uniform_set(cl, set1, 1)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, groups.x, groups.y, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var data := rd.texture_get_data(out_tex, 0)
	compute.dispose()
	if data.is_empty():
		return null

	return Image.create_from_data(out_width, out_height, false, Image.FORMAT_RGBAH, data)


static func make_vegetation_all_channel_mask_with_counts_gpu(
	occupancy: Image,
	active_threshold: float = 0.01,
	output_size: Vector2i = Vector2i.ZERO
) -> Dictionary:
	# Two-pass GPU helper: all-channel RGBAH mask pass -> barrier -> 4-channel count pass.
	# Returns {"mask": Image, "channel_counts": PackedInt32Array}; returns {} on failure.
	if occupancy == null or occupancy.is_empty():
		return {}

	var src_width := occupancy.get_width()
	var src_height := occupancy.get_height()
	var out_width := output_size.x if output_size.x > 0 else src_width
	var out_height := output_size.y if output_size.y > 0 else src_height
	if src_width <= 0 or src_height <= 0 or out_width <= 0 or out_height <= 0:
		return {}

	var compute := ComputeShaderBaseScript.new()
	compute.log_name = "VegetationScatterAllChannelMaskWithCounts"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return {}

	var rd: RenderingDevice = compute.get_rendering_device()
	var mask_shader := compute.load_compute_shader(_VEGETATION_ALL_CHANNEL_MASK_SHADER)
	var mask_pipeline := compute.create_compute_pipeline(mask_shader)
	var counts_shader := compute.load_compute_shader(_VEGETATION_CHANNEL_COUNTS_SHADER)
	var counts_pipeline := compute.create_compute_pipeline(counts_shader)
	if (
		not mask_shader.is_valid()
		or not mask_pipeline.is_valid()
		or not counts_shader.is_valid()
		or not counts_pipeline.is_valid()
	):
		compute.dispose()
		return {}

	var sampler := compute.create_linear_sampler(
		ComputeShaderBaseScript.SCOPE_FRAME,
		"vegetation_all_channel_mask_with_counts_sampler"
	)
	var occupancy_tex := compute.upload_texture_2d(
		occupancy,
		RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
		Image.FORMAT_RGBAH,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"vegetation_occupancy_rgba16f"
	)
	var mask_tex := compute.create_rw_texture_2d(
		out_width,
		out_height,
		RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
		(
			RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
			RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |
			RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		),
		ComputeShaderBaseScript.SCOPE_FRAME,
		"vegetation_all_channel_mask_rgba16f"
	)
	var counts_buf := compute.storage_buffer_zero(
		16,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"vegetation_channel_counts_u32x4"
	)
	if not sampler.is_valid() or not occupancy_tex.is_valid() or not mask_tex.is_valid() or not counts_buf.is_valid():
		compute.dispose()
		return {}

	var mask_set0 := compute.create_uniform_set([
		compute.make_sampler_uniform(0, sampler, occupancy_tex),
	], mask_shader, 0, ComputeShaderBaseScript.SCOPE_PASS, "vegetation_all_channel_mask_set0")
	var mask_set1 := compute.create_uniform_set([
		compute.make_image_uniform(0, mask_tex),
	], mask_shader, 1, ComputeShaderBaseScript.SCOPE_PASS, "vegetation_all_channel_mask_set1")
	var counts_set0 := compute.create_uniform_set([
		compute.make_sampler_uniform(0, sampler, mask_tex),
	], counts_shader, 0, ComputeShaderBaseScript.SCOPE_PASS, "vegetation_channel_counts_set0")
	var counts_set1 := compute.create_uniform_set([
		compute.make_storage_uniform(0, counts_buf),
	], counts_shader, 1, ComputeShaderBaseScript.SCOPE_PASS, "vegetation_channel_counts_set1")
	if not mask_set0.is_valid() or not mask_set1.is_valid() or not counts_set0.is_valid() or not counts_set1.is_valid():
		compute.dispose()
		return {}

	var mask_push := PackedByteArray()
	mask_push.resize(32)
	mask_push.encode_s32(0, out_width)
	mask_push.encode_s32(4, out_height)
	mask_push.encode_s32(8, src_width)
	mask_push.encode_s32(12, src_height)
	mask_push.encode_float(16, active_threshold)
	mask_push.encode_float(20, 0.0)
	mask_push.encode_float(24, 0.0)
	mask_push.encode_float(28, 0.0)

	var counts_push := PackedByteArray()
	counts_push.resize(16)
	counts_push.encode_s32(0, out_width)
	counts_push.encode_s32(4, out_height)
	counts_push.encode_float(8, active_threshold)
	counts_push.encode_float(12, 0.0)

	var mask_groups := compute.dispatch_groups_2d(out_width, out_height, _VEGETATION_ALL_CHANNEL_MASK_LOCAL_SIZE, _VEGETATION_ALL_CHANNEL_MASK_LOCAL_SIZE)
	var counts_groups := compute.dispatch_groups_2d(out_width, out_height, _VEGETATION_CHANNEL_COUNTS_LOCAL_SIZE, _VEGETATION_CHANNEL_COUNTS_LOCAL_SIZE)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return {}

	rd.compute_list_bind_compute_pipeline(cl, mask_pipeline)
	rd.compute_list_bind_uniform_set(cl, mask_set0, 0)
	rd.compute_list_bind_uniform_set(cl, mask_set1, 1)
	rd.compute_list_set_push_constant(cl, mask_push, mask_push.size())
	rd.compute_list_dispatch(cl, mask_groups.x, mask_groups.y, 1)
	rd.compute_list_add_barrier(cl)
	rd.compute_list_bind_compute_pipeline(cl, counts_pipeline)
	rd.compute_list_bind_uniform_set(cl, counts_set0, 0)
	rd.compute_list_bind_uniform_set(cl, counts_set1, 1)
	rd.compute_list_set_push_constant(cl, counts_push, counts_push.size())
	rd.compute_list_dispatch(cl, counts_groups.x, counts_groups.y, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var mask_data := rd.texture_get_data(mask_tex, 0)
	var counts_bytes := rd.buffer_get_data(counts_buf, 0, 16)
	compute.dispose()
	if mask_data.is_empty() or counts_bytes.size() < 16:
		return {}

	return {
		"mask": Image.create_from_data(out_width, out_height, false, Image.FORMAT_RGBAH, mask_data),
		"channel_counts": PackedInt32Array([
			_decode_u32(counts_bytes.slice(0, 4), 0),
			_decode_u32(counts_bytes.slice(4, 8), 0),
			_decode_u32(counts_bytes.slice(8, 12), 0),
			_decode_u32(counts_bytes.slice(12, 16), 0),
		]),
	}


static func make_vegetation_split_channel_masks_gpu(
	occupancy: Image,
	active_threshold: float = 0.01,
	output_size: Vector2i = Vector2i.ZERO
) -> Array[Image]:
	# GPU-only helper: reads RGBA16F occupancy and writes four R32F masks in RGBA order.
	# Contract: returns an empty array when setup or execution fails.
	if occupancy == null or occupancy.is_empty():
		return []

	var src_width := occupancy.get_width()
	var src_height := occupancy.get_height()
	var out_width := output_size.x if output_size.x > 0 else src_width
	var out_height := output_size.y if output_size.y > 0 else src_height
	if src_width <= 0 or src_height <= 0 or out_width <= 0 or out_height <= 0:
		return []

	var compute := ComputeShaderBaseScript.new()
	compute.log_name = "VegetationScatterSplitChannelMasks"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return []

	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader(_VEGETATION_SPLIT_CHANNEL_MASKS_SHADER)
	var pipeline := compute.create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return []

	var sampler := compute.create_linear_sampler(
		ComputeShaderBaseScript.SCOPE_FRAME,
		"vegetation_split_channel_masks_sampler"
	)
	var occupancy_tex := compute.upload_texture_2d(
		occupancy,
		RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
		Image.FORMAT_RGBAH,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"vegetation_occupancy_rgba16f"
	)
	var out_textures: Array[RID] = []
	for i in range(4):
		out_textures.append(compute.create_rw_texture_2d(
			out_width,
			out_height,
			RenderingDevice.DATA_FORMAT_R32_SFLOAT,
			RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT,
			ComputeShaderBaseScript.SCOPE_FRAME,
			"vegetation_split_channel_mask_%d_r32f" % i
		))
	if not sampler.is_valid() or not occupancy_tex.is_valid():
		compute.dispose()
		return []
	for tex in out_textures:
		if not tex.is_valid():
			compute.dispose()
			return []

	var set0 := compute.create_uniform_set([
		compute.make_sampler_uniform(0, sampler, occupancy_tex),
	], shader, 0, ComputeShaderBaseScript.SCOPE_PASS, "vegetation_split_channel_masks_set0")
	var set1_uniforms := []
	for i in range(4):
		set1_uniforms.append(compute.make_image_uniform(i, out_textures[i]))
	var set1 := compute.create_uniform_set(
		set1_uniforms,
		shader,
		1,
		ComputeShaderBaseScript.SCOPE_PASS,
		"vegetation_split_channel_masks_set1"
	)
	if not set0.is_valid() or not set1.is_valid():
		compute.dispose()
		return []

	var push := PackedByteArray()
	push.resize(32)
	push.encode_s32(0, out_width)
	push.encode_s32(4, out_height)
	push.encode_s32(8, src_width)
	push.encode_s32(12, src_height)
	push.encode_float(16, active_threshold)
	push.encode_float(20, 0.0)
	push.encode_float(24, 0.0)
	push.encode_float(28, 0.0)

	var groups := compute.dispatch_groups_2d(out_width, out_height, _VEGETATION_SPLIT_CHANNEL_MASKS_LOCAL_SIZE, _VEGETATION_SPLIT_CHANNEL_MASKS_LOCAL_SIZE)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return []

	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_bind_uniform_set(cl, set1, 1)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, groups.x, groups.y, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var result: Array[Image] = []
	for tex in out_textures:
		var data := rd.texture_get_data(tex, 0)
		if data.is_empty():
			compute.dispose()
			return []
		result.append(Image.create_from_data(out_width, out_height, false, Image.FORMAT_RF, data))
	compute.dispose()
	return result


static func make_vegetation_split_channel_masks_with_counts_gpu(
	occupancy: Image,
	active_threshold: float = 0.01,
	output_size: Vector2i = Vector2i.ZERO
) -> Dictionary:
	# GPU-only helper: writes four R32F masks and 4 u32 active counts in one dispatch.
	# Returns {"masks": Array[Image], "channel_counts": PackedInt32Array}; returns {} on failure.
	if occupancy == null or occupancy.is_empty():
		return {}

	var src_width := occupancy.get_width()
	var src_height := occupancy.get_height()
	var out_width := output_size.x if output_size.x > 0 else src_width
	var out_height := output_size.y if output_size.y > 0 else src_height
	if src_width <= 0 or src_height <= 0 or out_width <= 0 or out_height <= 0:
		return {}

	var compute := ComputeShaderBaseScript.new()
	compute.log_name = "VegetationScatterSplitChannelMasksWithCounts"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return {}

	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader(_VEGETATION_SPLIT_CHANNEL_MASKS_WITH_COUNTS_SHADER)
	var pipeline := compute.create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return {}

	var sampler := compute.create_linear_sampler(
		ComputeShaderBaseScript.SCOPE_FRAME,
		"vegetation_split_channel_masks_with_counts_sampler"
	)
	var occupancy_tex := compute.upload_texture_2d(
		occupancy,
		RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
		Image.FORMAT_RGBAH,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"vegetation_occupancy_rgba16f"
	)
	var out_textures: Array[RID] = []
	for i in range(4):
		out_textures.append(compute.create_rw_texture_2d(
			out_width,
			out_height,
			RenderingDevice.DATA_FORMAT_R32_SFLOAT,
			RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT,
			ComputeShaderBaseScript.SCOPE_FRAME,
			"vegetation_split_channel_mask_%d_r32f" % i
		))
	var counts_buf := compute.storage_buffer_zero(
		16,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"vegetation_split_channel_counts_u32x4"
	)
	if not sampler.is_valid() or not occupancy_tex.is_valid() or not counts_buf.is_valid():
		compute.dispose()
		return {}
	for tex in out_textures:
		if not tex.is_valid():
			compute.dispose()
			return {}

	var set0 := compute.create_uniform_set([
		compute.make_sampler_uniform(0, sampler, occupancy_tex),
	], shader, 0, ComputeShaderBaseScript.SCOPE_PASS, "vegetation_split_channel_masks_with_counts_set0")
	var set1_uniforms := []
	for i in range(4):
		set1_uniforms.append(compute.make_image_uniform(i, out_textures[i]))
	var set1 := compute.create_uniform_set(
		set1_uniforms,
		shader,
		1,
		ComputeShaderBaseScript.SCOPE_PASS,
		"vegetation_split_channel_masks_with_counts_set1"
	)
	var set2 := compute.create_uniform_set([
		compute.make_storage_uniform(0, counts_buf),
	], shader, 2, ComputeShaderBaseScript.SCOPE_PASS, "vegetation_split_channel_masks_with_counts_set2")
	if not set0.is_valid() or not set1.is_valid() or not set2.is_valid():
		compute.dispose()
		return {}

	var push := PackedByteArray()
	push.resize(32)
	push.encode_s32(0, out_width)
	push.encode_s32(4, out_height)
	push.encode_s32(8, src_width)
	push.encode_s32(12, src_height)
	push.encode_float(16, active_threshold)
	push.encode_float(20, 0.0)
	push.encode_float(24, 0.0)
	push.encode_float(28, 0.0)

	var groups := compute.dispatch_groups_2d(out_width, out_height, _VEGETATION_SPLIT_CHANNEL_MASKS_WITH_COUNTS_LOCAL_SIZE, _VEGETATION_SPLIT_CHANNEL_MASKS_WITH_COUNTS_LOCAL_SIZE)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return {}

	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_bind_uniform_set(cl, set1, 1)
	rd.compute_list_bind_uniform_set(cl, set2, 2)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, groups.x, groups.y, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var masks: Array[Image] = []
	for tex in out_textures:
		var data := rd.texture_get_data(tex, 0)
		if data.is_empty():
			compute.dispose()
			return {}
		masks.append(Image.create_from_data(out_width, out_height, false, Image.FORMAT_RF, data))
	var counts_bytes := rd.buffer_get_data(counts_buf, 0, 16)
	compute.dispose()
	if counts_bytes.size() < 16:
		return {}

	return {
		"masks": masks,
		"channel_counts": PackedInt32Array([
			_decode_u32(counts_bytes.slice(0, 4), 0),
			_decode_u32(counts_bytes.slice(4, 8), 0),
			_decode_u32(counts_bytes.slice(8, 12), 0),
			_decode_u32(counts_bytes.slice(12, 16), 0),
		]),
	}


static func _decode_u32(bytes: PackedByteArray, fallback: int = 0) -> int:
	if bytes.size() < 4:
		return fallback
	return (
		int(bytes[0]) |
		(int(bytes[1]) << 8) |
		(int(bytes[2]) << 16) |
		(int(bytes[3]) << 24)
	)
