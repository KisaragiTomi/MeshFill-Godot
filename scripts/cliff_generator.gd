class_name CliffGenerator
extends Node3D

const ComputeShaderBaseScript := preload("res://scripts/godot_compute_shader_base.gd")

@export var texture_size: int = 256
@export var capture_size: float = 1000.0
@export var max_height: float = 10000.0
@export var generate_threshold: float = 0.5
@export var un_generate_threshold: float = 0.3
@export var target_height_extension: float = 2.0
@export var rock_overlap: float = 0.0

@export var scene_depth_texture: Texture2D
@export var scene_normal_texture: Texture2D
@export var object_depth_texture: Texture2D
@export var object_normal_texture: Texture2D
@export var height_normal_texture: Texture2D
@export var target_height_texture: Texture2D
@export var mesh_height_array_texture: Texture2D
@export var rock_mask_texture: Texture2D
@export var rock_override_mask_texture: Texture2D
@export var rock_override_delta_texture: Texture2D

@export var rock_assets: Array[AutoRock]
@export var placement_assets: Array[AutoRock] = []
@export var mesh_data_assets: Array[MeshDataAsset]

var rd: RenderingDevice
var _compute
var _is_local_rd: bool = false
var _debug_target_height_image: Image
var _debug_current_height_image: Image
var _active_rock_assets: Array[AutoRock] = []

var _shader_init: RID
var _shader_target_height: RID
var _shader_blur: RID
var _shader_extent: RID
var _shader_fill: RID
var _shader_find: RID
var _shader_update: RID

var _pipeline_init: RID
var _pipeline_target_height: RID
var _pipeline_blur: RID
var _pipeline_extent: RID
var _pipeline_fill: RID
var _pipeline_find: RID
var _pipeline_update: RID

var _sampler: RID


func _submit_and_sync() -> void:
	if _compute != null:
		_compute.submit_and_sync()


func _resolve_rock_assets() -> Array[AutoRock]:
	var result: Array[AutoRock] = []
	for asset in rock_assets:
		if asset != null and asset.is_valid_rock_asset():
			result.append(asset)
	if not result.is_empty():
		return result

	for legacy_asset in mesh_data_assets:
		if legacy_asset == null:
			continue
		var converted := AutoAssetFactory.rock_from_mesh_data_asset(legacy_asset)
		if converted.is_valid_rock_asset():
			result.append(converted)
	return result


func generate_placement(
	num_iteration: int,
	spawn_size: float = 1.0,
	dirty_rect: Rect2i = Rect2i(),
	settings: Dictionary = {}
) -> Array[Dictionary]:
	var restore_rock_assets := rock_assets
	if not placement_assets.is_empty():
		rock_assets = placement_assets

	var results := generate_cliff_vertical(num_iteration, spawn_size, dirty_rect)

	rock_assets = restore_rock_assets
	if results.is_empty():
		return results

	var align_to_surface_normal := bool(settings.get("align_to_surface_normal", true))
	var use_xyz_rotation := str(settings.get("rotation_mode", "XYZ")).to_upper() == "XYZ"
	if not align_to_surface_normal and not use_xyz_rotation:
		return results

	var normal_texture: Texture2D = settings.get("surface_normal_texture", scene_normal_texture)
	var normal_image: Image = null
	if normal_texture != null:
		normal_image = normal_texture.get_image()

	var twist_scale := float(settings.get("twist_scale", 1.0))
	var output: Array[Dictionary] = []
	output.resize(results.size())
	for i in range(results.size()):
		var decorated := results[i].duplicate(true)
		var twist_y := float(decorated.get("rotation_y", 0.0))
		var surface_normal := _sample_surface_normal_from_result(decorated, normal_image)
		var rotation_degrees := _rotation_degrees_from_surface_normal(surface_normal, deg_to_rad(twist_y) * twist_scale)
		decorated["placement_mode"] = str(settings.get("placement_mode", "surface_3d"))
		decorated["surface_normal"] = surface_normal
		decorated["rotation_mode"] = "XYZ"
		decorated["rotation_degrees"] = rotation_degrees
		decorated["rotation_y"] = twist_y
		output[i] = decorated
	return output


func generate_surface_placement(
	num_iteration: int,
	spawn_size: float = 1.0,
	dirty_rect: Rect2i = Rect2i()
) -> Array[Dictionary]:
	return generate_placement(num_iteration, spawn_size, dirty_rect, {
		"placement_mode": "surface_3d",
		"align_to_surface_normal": true,
		"rotation_mode": "XYZ",
	})


func generate_cliff_vertical(num_iteration: int, spawn_size: float = 1.0, dirty_rect: Rect2i = Rect2i()) -> Array[Dictionary]:
	_active_rock_assets = _resolve_rock_assets()
	if _active_rock_assets.is_empty():
		push_error("CliffGenerator: no AutoRock assets available")
		return []

	_compute = ComputeShaderBaseScript.new()
	_compute.log_name = "CliffGenerator"
	if not _compute.ensure_device():
		return []
	rd = _compute.get_rendering_device()
	_is_local_rd = _compute.owns_rendering_device()

	var dr := dirty_rect
	if dr.size.x <= 0 or dr.size.y <= 0:
		dr = Rect2i(0, 0, texture_size, texture_size)

	_load_shaders()
	_create_sampler()

	var input_textures := _upload_input_textures()
	var working := _create_working_textures()

	var generate_datas: Array[Dictionary] = []
	for i in range(num_iteration):
		var idx := randi_range(0, _active_rock_assets.size() - 1)
		var asset := _active_rock_assets[idx]
		generate_datas.append({
			"select_index": idx,
			"random_rotate": asset.random_rotate,
			"random_scale": asset.random_scale,
			"random_height_offset": asset.random_height_offset,
			"mesh_size": asset.mesh_size,
		})

	var mesh_tex_rids: Array[RID] = []
	for asset in _active_rock_assets:
		mesh_tex_rids.append(_upload_texture(asset.mesh_height_texture.get_image()))

	# === Pass 1: Init ===
	_dispatch_init(input_textures, working, dr)

	# === Pass 1.5: Generate Target Height (flood-fill propagation) ===
	var target_height_read := _create_image_texture(texture_size, texture_size)
	var pixel_size := capture_size / float(texture_size)
	var flood_iterations := maxi(1, ceili(target_height_extension / pixel_size))
	for i in range(flood_iterations):
		rd.texture_copy(
			working.target_height, target_height_read,
			Vector3.ZERO, Vector3.ZERO, Vector3(texture_size, texture_size, 1),
			0, 0, 0, 0
		)
		_submit_and_sync()
		_dispatch_target_height(target_height_read, working, dr)

	# === Pass 1.6: Blur target height ===
	rd.texture_copy(
		working.target_height, target_height_read,
		Vector3.ZERO, Vector3.ZERO, Vector3(texture_size, texture_size, 1),
		0, 0, 0, 0
	)
	_submit_and_sync()
	_dispatch_blur(target_height_read, working, dr)

	rd.texture_copy(
		working.current_scene_depth, working.current_scene_depth_read,
		Vector3.ZERO, Vector3.ZERO, Vector3(texture_size, texture_size, 1),
		0, 0, 0, 0
	)

	# === Pass 2: ExtentGenerateMask (1-pixel dilation per dispatch) ===
	var extent_pixels := ceili(target_height_extension / pixel_size)
	extent_pixels = clampi(extent_pixels, 0, 128)
	print("[CliffGen] Extent: ext=%.1f pixel_size=%.3f extent_px=%d dirty=%s" % [
		target_height_extension, pixel_size, extent_pixels, str(dr)])
	for ei in range(extent_pixels):
		_dispatch_extent_mask(input_textures, working, dr)
		_submit_and_sync()
		rd.texture_copy(
			working.current_scene_depth, working.current_scene_depth_read,
			Vector3.ZERO, Vector3.ZERO, Vector3(texture_size, texture_size, 1),
			0, 0, 0, 0
		)
		_submit_and_sync()

	# Copy current_scene_depth -> current_scene_depth_a
	rd.texture_copy(
		working.current_scene_depth, working.current_scene_depth_a,
		Vector3.ZERO, Vector3.ZERO, Vector3(texture_size, texture_size, 1),
		0, 0, 0, 0
	)

	# === Iterative Passes 3-5 ===
	for i in range(generate_datas.size()):
		var gd: Dictionary = generate_datas[i]
		var mesh_tex: RID = mesh_tex_rids[gd.select_index]

		# Pass 3: FillVerticalRock (full dispatch, dirty_rect guard inside shader)
		_dispatch_fill(working, mesh_tex, gd, spawn_size, dr)

		# Pass 4: FindBestPixelRW (single workgroup, no dirty_rect needed)
		_dispatch_find(working, input_textures, gd.select_index)

		# Pass 5: UpdateCurrentHeight (full dispatch, dirty_rect guard inside shader)
		_dispatch_update(working, mesh_tex, input_textures, gd.select_index, dr)

		# Ping-pong swap
		var swap_cs: RID = working.current_scene_depth_a
		working.current_scene_depth_a = working.current_scene_depth_b
		working.current_scene_depth_b = swap_cs

		var swap_r: RID = working.result_a
		working.result_a = working.result_b
		working.result_b = swap_r

	_submit_and_sync()
	var th_data := rd.texture_get_data(working.target_height, 0)
	_debug_target_height_image = Image.create_from_data(texture_size, texture_size, false, Image.FORMAT_RGBAH, th_data)

	var ch_data := rd.texture_get_data(working.current_scene_depth_a, 0)
	_debug_current_height_image = Image.create_from_data(texture_size, texture_size, false, Image.FORMAT_RGBAH, ch_data)

	# Read back results
	var results := _read_results(working)

	# Cleanup
	_cleanup(input_textures, working, mesh_tex_rids)

	return results


# ─── Shader loading ───

func _load_shaders() -> void:
	_shader_init = _compute.load_compute_shader("res://shaders/init_vertical_rock.glsl")
	_shader_target_height = _compute.load_compute_shader("res://shaders/generate_target_height.glsl")
	_shader_blur = _compute.load_compute_shader("res://shaders/blur_texture.glsl")
	_shader_extent = _compute.load_compute_shader("res://shaders/extent_generate_mask.glsl")
	_shader_fill = _compute.load_compute_shader("res://shaders/fill_vertical_rock.glsl")
	_shader_find = _compute.load_compute_shader("res://shaders/find_best_pixel.glsl")
	_shader_update = _compute.load_compute_shader("res://shaders/update_current_height.glsl")

	_pipeline_init = _compute.create_compute_pipeline(_shader_init)
	_pipeline_target_height = _compute.create_compute_pipeline(_shader_target_height)
	_pipeline_blur = _compute.create_compute_pipeline(_shader_blur)
	_pipeline_extent = _compute.create_compute_pipeline(_shader_extent)
	_pipeline_fill = _compute.create_compute_pipeline(_shader_fill)
	_pipeline_find = _compute.create_compute_pipeline(_shader_find)
	_pipeline_update = _compute.create_compute_pipeline(_shader_update)


# ─── Texture creation and upload ───

func _create_image_texture(width: int, height: int, format := RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT) -> RID:
	var usage_bits := (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	)
	return _compute.create_rw_texture_2d(width, height, format, usage_bits)


func _upload_texture(image: Image) -> RID:
	var usage_bits := (
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT |
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	)
	return _compute.upload_texture_2d(image, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, Image.FORMAT_RGBAH, usage_bits)


func _upload_input_textures() -> Dictionary:
	var rock_mask_img: Image
	if rock_mask_texture != null:
		rock_mask_img = rock_mask_texture.get_image()
	else:
		rock_mask_img = Image.create(texture_size, texture_size, false, Image.FORMAT_RGBAF)
		rock_mask_img.fill(Color(0.0, 0.0, 0.0, 0.0))

	var rock_ovr_mask_img: Image
	if rock_override_mask_texture != null:
		rock_ovr_mask_img = rock_override_mask_texture.get_image()
	else:
		rock_ovr_mask_img = Image.create(texture_size, texture_size, false, Image.FORMAT_RGBAF)
		rock_ovr_mask_img.fill(Color(0.0, 0.0, 0.0, 0.0))

	var rock_ovr_delta_img: Image
	if rock_override_delta_texture != null:
		rock_ovr_delta_img = rock_override_delta_texture.get_image()
	else:
		rock_ovr_delta_img = Image.create(texture_size, texture_size, false, Image.FORMAT_RGBAF)
		rock_ovr_delta_img.fill(Color(0.0, 0.0, 0.0, 0.0))

	return {
		"scene_depth": _upload_texture(scene_depth_texture.get_image()),
		"scene_normal": _upload_texture(scene_normal_texture.get_image()),
		"object_depth": _upload_texture(object_depth_texture.get_image()),
		"object_normal": _upload_texture(object_normal_texture.get_image()),
		"height_normal": _upload_texture(height_normal_texture.get_image()),
		"target_height": _upload_texture(target_height_texture.get_image()),
		"rock_mask": _upload_texture(rock_mask_img),
		"rock_override_mask": _upload_texture(rock_ovr_mask_img),
		"rock_override_delta": _upload_texture(rock_ovr_delta_img),
	}


func _create_working_textures() -> Dictionary:
	var s := texture_size
	return {
		"current_scene_depth": _create_image_texture(s, s),
		"current_scene_depth_read": _create_image_texture(s, s),
		"current_scene_depth_a": _create_image_texture(s, s),
		"current_scene_depth_b": _create_image_texture(s, s),
		"target_height": _create_image_texture(s, s),
		"debug_view": _create_image_texture(s, s),
		"result_a": _create_image_texture(1024, 2),
		"result_b": _create_image_texture(1024, 2),
		"filter_result": _create_image_texture(ceili(float(s) / 16.0), ceili(float(s) / 16.0)),
		"save_rotate_scale": _create_image_texture(s, s),
		"deduplication": _create_image_texture(s, s),
		"filter_result_mult": _create_image_texture(s, s),
	}


# ─── Uniform set helpers ───

func _create_sampler() -> void:
	_sampler = _compute.create_linear_sampler()


func _make_sampler_uniform(binding: int, tex: RID) -> RDUniform:
	return _compute.make_sampler_uniform(binding, _sampler, tex)


func _make_image_uniform(binding: int, tex: RID) -> RDUniform:
	return _compute.make_image_uniform(binding, tex)


# ─── Pass 1: Init ───

func _dispatch_init(inputs: Dictionary, working: Dictionary, dr: Rect2i) -> void:
	var set0: RID = _compute.create_uniform_set([
		_make_sampler_uniform(0, inputs.scene_depth),
		_make_sampler_uniform(1, inputs.object_depth),
		_make_sampler_uniform(2, inputs.object_normal),
		_make_sampler_uniform(3, inputs.target_height),
		_make_sampler_uniform(4, inputs.rock_mask),
		_make_sampler_uniform(5, inputs.rock_override_mask),
		_make_sampler_uniform(6, inputs.rock_override_delta),
	], _shader_init, 0)

	var set1: RID = _compute.create_uniform_set([
		_make_image_uniform(0, working.current_scene_depth),
		_make_image_uniform(1, working.target_height),
		_make_image_uniform(2, working.debug_view),
	], _shader_init, 1)

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
	rd.compute_list_bind_compute_pipeline(cl, _pipeline_init)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_bind_uniform_set(cl, set1, 1)
	rd.compute_list_set_push_constant(cl, push_buf, push_buf.size())
	rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	_compute.end_compute_list()
	_submit_and_sync()


# ─── Pass 1.5: Generate Target Height (flood-fill) ───

func _dispatch_target_height(target_read: RID, working: Dictionary, dr: Rect2i) -> void:
	var set0: RID = _compute.create_uniform_set([
		_make_sampler_uniform(0, target_read),
	], _shader_target_height, 0)

	var set1: RID = _compute.create_uniform_set([
		_make_image_uniform(0, working.target_height),
	], _shader_target_height, 1)

	var push_buf := PackedByteArray()
	push_buf.resize(16)
	push_buf.encode_s32(0, dr.position.x)
	push_buf.encode_s32(4, dr.position.y)
	push_buf.encode_s32(8, dr.size.x)
	push_buf.encode_s32(12, dr.size.y)

	var groups_x := ceili(float(dr.size.x) / 32.0)
	var groups_y := ceili(float(dr.size.y) / 32.0)

	var cl: int = _compute.begin_compute_list()
	rd.compute_list_bind_compute_pipeline(cl, _pipeline_target_height)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_bind_uniform_set(cl, set1, 1)
	rd.compute_list_set_push_constant(cl, push_buf, push_buf.size())
	rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	_compute.end_compute_list()
	_submit_and_sync()


# ─── Pass 1.6: Blur ───

func _dispatch_blur(blur_read: RID, working: Dictionary, dr: Rect2i) -> void:
	var set0: RID = _compute.create_uniform_set([
		_make_sampler_uniform(0, blur_read),
	], _shader_blur, 0)

	var set1: RID = _compute.create_uniform_set([
		_make_image_uniform(0, working.target_height),
	], _shader_blur, 1)

	var push_buf := PackedByteArray()
	push_buf.resize(32)
	push_buf.encode_float(0, 1.0)
	push_buf.encode_s32(4, dr.position.x)
	push_buf.encode_s32(8, dr.position.y)
	push_buf.encode_s32(12, dr.size.x)
	push_buf.encode_s32(16, dr.size.y)

	var groups_x := ceili(float(dr.size.x) / 32.0)
	var groups_y := ceili(float(dr.size.y) / 32.0)

	var cl: int = _compute.begin_compute_list()
	rd.compute_list_bind_compute_pipeline(cl, _pipeline_blur)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_bind_uniform_set(cl, set1, 1)
	rd.compute_list_set_push_constant(cl, push_buf, push_buf.size())
	rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	_compute.end_compute_list()
	_submit_and_sync()


# ─── Pass 2: Extent Generate Mask ───

func _dispatch_extent_mask(inputs: Dictionary, working: Dictionary, dr: Rect2i) -> void:
	var set0: RID = _compute.create_uniform_set([
		_make_sampler_uniform(0, working.current_scene_depth_read),
		_make_sampler_uniform(1, inputs.height_normal),
	], _shader_extent, 0)

	var set1: RID = _compute.create_uniform_set([
		_make_image_uniform(0, working.current_scene_depth),
	], _shader_extent, 1)

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
	rd.compute_list_bind_compute_pipeline(cl, _pipeline_extent)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_bind_uniform_set(cl, set1, 1)
	rd.compute_list_set_push_constant(cl, push_buf, push_buf.size())
	rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	_compute.end_compute_list()
	_submit_and_sync()


# ─── Pass 3: Fill Vertical Rock ───

func _dispatch_fill(working: Dictionary, mesh_tex: RID, gen_data: Dictionary, spawn_size_val: float, dr: Rect2i) -> void:
	var idx: int = gen_data.select_index
	var asset := _active_rock_assets[idx]
	var mesh_size_val: float = asset.mesh_size
	var draw_size: float = mesh_size_val / capture_size * spawn_size_val

	var set0: RID = _compute.create_uniform_set([
		_make_image_uniform(0, working.current_scene_depth_a),
		_make_image_uniform(1, working.current_scene_depth_b),
		_make_image_uniform(2, working.result_a),
		_make_image_uniform(3, working.result_b),
		_make_image_uniform(4, working.filter_result),
		_make_image_uniform(5, working.save_rotate_scale),
		_make_image_uniform(6, working.target_height),
		_make_image_uniform(7, working.debug_view),
	], _shader_fill, 0)

	var set1: RID = _compute.create_uniform_set([
		_make_sampler_uniform(0, mesh_tex),
	], _shader_fill, 1)

	var rr: Vector2 = gen_data.random_rotate
	var rs: Vector2 = gen_data.random_scale
	var rho: Vector2 = gen_data.random_height_offset
	var scale_min := maxf(minf(rs.x, rs.y), 0.001)
	var scale_max := maxf(maxf(rs.x, rs.y), scale_min)

	var push_buf := PackedByteArray()
	push_buf.resize(64)
	push_buf.encode_float(0, max_height)
	push_buf.encode_float(4, capture_size)
	push_buf.encode_float(8, draw_size)
	push_buf.encode_float(12, generate_threshold)
	push_buf.encode_float(16, un_generate_threshold)
	push_buf.encode_s32(20, idx)
	push_buf.encode_s32(24, dr.position.x)
	push_buf.encode_s32(28, dr.position.y)
	push_buf.encode_float(32, rr.x)
	push_buf.encode_float(36, rr.y)
	push_buf.encode_float(40, rho.x)
	push_buf.encode_float(44, rho.y)
	push_buf.encode_float(48, scale_min)
	push_buf.encode_float(52, scale_max)
	push_buf.encode_s32(56, dr.size.x)
	push_buf.encode_s32(60, dr.size.y)

	var groups := ceili(float(texture_size) / 16.0)

	var cl: int = _compute.begin_compute_list()
	rd.compute_list_bind_compute_pipeline(cl, _pipeline_fill)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_bind_uniform_set(cl, set1, 1)
	rd.compute_list_set_push_constant(cl, push_buf, push_buf.size())
	rd.compute_list_dispatch(cl, groups, groups, 1)
	_compute.end_compute_list()
	_submit_and_sync()


# ─── Pass 4: Find Best Pixel ───

func _dispatch_find(working: Dictionary, inputs: Dictionary, select_idx: int) -> void:
	var set0: RID = _compute.create_uniform_set([
		_make_image_uniform(0, working.filter_result),
		_make_image_uniform(1, working.save_rotate_scale),
		_make_image_uniform(2, working.current_scene_depth_a),
		_make_image_uniform(3, working.result_a),
		_make_image_uniform(4, working.result_b),
		_make_image_uniform(5, working.debug_view),
	], _shader_find, 0)

	var set1: RID = _compute.create_uniform_set([
		_make_sampler_uniform(0, inputs.scene_normal),
	], _shader_find, 1)

	var push_buf := PackedByteArray()
	push_buf.resize(16)
	push_buf.encode_s32(0, select_idx)
	push_buf.encode_float(4, 0.0)
	push_buf.encode_float(8, 0.0)
	push_buf.encode_float(12, 0.0)

	var cl: int = _compute.begin_compute_list()
	rd.compute_list_bind_compute_pipeline(cl, _pipeline_find)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_bind_uniform_set(cl, set1, 1)
	rd.compute_list_set_push_constant(cl, push_buf, push_buf.size())
	rd.compute_list_dispatch(cl, 1, 1, 1)
	_compute.end_compute_list()
	_submit_and_sync()


# ─── Pass 5: Update Current Height ───

func _dispatch_update(working: Dictionary, mesh_tex: RID, inputs: Dictionary, select_idx: int, dr: Rect2i) -> void:
	var set0: RID = _compute.create_uniform_set([
		_make_image_uniform(0, working.current_scene_depth_a),
		_make_image_uniform(1, working.current_scene_depth_b),
		_make_image_uniform(2, working.result_b),
		_make_image_uniform(3, working.result_a),
		_make_image_uniform(4, working.debug_view),
	], _shader_update, 0)

	var set1: RID = _compute.create_uniform_set([
		_make_sampler_uniform(0, mesh_tex),
		_make_sampler_uniform(1, inputs.scene_normal),
		_make_sampler_uniform(2, working.target_height),
	], _shader_update, 1)

	var push_buf := PackedByteArray()
	push_buf.resize(32)
	push_buf.encode_float(0, max_height)
	push_buf.encode_float(4, capture_size)
	push_buf.encode_s32(8, select_idx)
	push_buf.encode_float(12, rock_overlap)
	push_buf.encode_s32(16, dr.position.x)
	push_buf.encode_s32(20, dr.position.y)
	push_buf.encode_s32(24, dr.size.x)
	push_buf.encode_s32(28, dr.size.y)

	var groups := ceili(float(texture_size) / 32.0)

	var cl: int = _compute.begin_compute_list()
	rd.compute_list_bind_compute_pipeline(cl, _pipeline_update)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_bind_uniform_set(cl, set1, 1)
	rd.compute_list_set_push_constant(cl, push_buf, push_buf.size())
	rd.compute_list_dispatch(cl, groups, groups, 1)
	_compute.end_compute_list()
	_submit_and_sync()


# ─── Result readback ───

func _read_results(working: Dictionary) -> Array[Dictionary]:
	var tex_data := rd.texture_get_data(working.result_a, 0)
	var img := Image.create_from_data(1024, 2, false, Image.FORMAT_RGBAH, tex_data)

	var last_pixel := img.get_pixelv(Vector2i(1023, 1))
	var max_gen := int(round(last_pixel.r))
	if max_gen == 0:
		return []

	var results: Array[Dictionary] = []
	for i in range(max_gen):
		var pos_color := img.get_pixelv(Vector2i(i, 0))
		var rsi_color := img.get_pixelv(Vector2i(i, 1))

		var loc_x: float = pos_color.r
		var loc_y: float = pos_color.g
		var loc_z: float = pos_color.b
		var rot: float = rsi_color.r
		var scl: float = rsi_color.g
		var mesh_idx: int = int(round(rsi_color.b))

		if scl < 0.01:
			continue
		if mesh_idx < 0 or mesh_idx >= _active_rock_assets.size():
			push_warning("CliffGenerator: skipping result with invalid mesh index %d" % mesh_idx)
			continue

		var asset := _active_rock_assets[mesh_idx]
		var mesh_size_val: float = asset.mesh_size
		var world_scale: float = scl / mesh_size_val * capture_size
		var world_pos := Vector3(
			loc_x * capture_size - capture_size / 2.0 + global_position.x,
			loc_z,
			loc_y * capture_size - capture_size / 2.0 + global_position.z
		)

		results.append({
			"position": world_pos,
			"rotation_y": rad_to_deg(rot),
			"scale": Vector3.ONE * world_scale,
			"mesh_index": mesh_idx,
			"asset_id": asset.asset_id,
			"color": asset.get_voxel_color(),
			"complexity": asset.get_voxel_complexity(),
		})

	return results


# ─── Cleanup ───

func _sample_surface_normal_from_result(result: Dictionary, normal_image: Image) -> Vector3:
	if normal_image == null:
		return Vector3.UP

	var width := normal_image.get_width()
	var height := normal_image.get_height()
	if width <= 0 or height <= 0:
		return Vector3.UP

	var world_pos: Vector3 = result.get("position", Vector3.ZERO)
	var uv := _capture_uv_from_world_position(world_pos)
	var px := Vector2i(
		clampi(int(roundf(uv.x * float(width - 1))), 0, width - 1),
		clampi(int(roundf(uv.y * float(height - 1))), 0, height - 1)
	)
	var normal_color: Color = normal_image.get_pixelv(px)
	var normal := Vector3(
		normal_color.r * 2.0 - 1.0,
		normal_color.g * 2.0 - 1.0,
		normal_color.b * 2.0 - 1.0
	)
	if normal.length_squared() <= 0.000001:
		return Vector3.UP
	return normal.normalized()


func _capture_uv_from_world_position(world_pos: Vector3) -> Vector2:
	var safe_capture := maxf(capture_size, 0.0001)
	var local_x := world_pos.x - global_position.x
	var local_z := world_pos.z - global_position.z
	return Vector2(
		clampf((local_x + safe_capture * 0.5) / safe_capture, 0.0, 1.0),
		clampf((local_z + safe_capture * 0.5) / safe_capture, 0.0, 1.0)
	)


func _rotation_degrees_from_surface_normal(surface_normal: Vector3, twist_radians: float) -> Vector3:
	var safe_normal := surface_normal.normalized()
	if safe_normal.length_squared() <= 0.000001:
		safe_normal = Vector3.UP

	var basis := _basis_from_up_to_vector(safe_normal)
	if absf(twist_radians) > 0.000001:
		basis = basis.rotated(safe_normal, twist_radians)

	var euler := basis.get_euler()
	return Vector3(rad_to_deg(euler.x), rad_to_deg(euler.y), rad_to_deg(euler.z))


func _basis_from_up_to_vector(target: Vector3) -> Basis:
	var from := Vector3.UP
	var to := target.normalized()
	if to.length_squared() <= 0.000001:
		return Basis()

	var dot := clampf(from.dot(to), -1.0, 1.0)
	if dot > 0.999999:
		return Basis()
	if dot < -0.999999:
		var axis := from.cross(Vector3.RIGHT)
		if axis.length_squared() <= 0.000001:
			axis = from.cross(Vector3.FORWARD)
		return Basis(Quaternion(axis.normalized(), PI))

	var axis := from.cross(to)
	if axis.length_squared() <= 0.000001:
		return Basis()
	var angle := acos(dot)
	return Basis(Quaternion(axis.normalized(), angle))


# 鈹€鈹€鈹€ Cleanup 鈹€鈹€鈹€

func _cleanup(_inputs: Dictionary, _working: Dictionary, _mesh_tex_rids: Array[RID]) -> void:
	if _compute != null:
		_compute.dispose()
	rd = null
	_compute = null
	_is_local_rd = false
	_shader_init = RID()
	_shader_target_height = RID()
	_shader_blur = RID()
	_shader_extent = RID()
	_shader_fill = RID()
	_shader_find = RID()
	_shader_update = RID()
	_pipeline_init = RID()
	_pipeline_target_height = RID()
	_pipeline_blur = RID()
	_pipeline_extent = RID()
	_pipeline_fill = RID()
	_pipeline_find = RID()
	_pipeline_update = RID()
	_sampler = RID()
