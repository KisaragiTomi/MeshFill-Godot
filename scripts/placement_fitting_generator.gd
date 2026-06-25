class_name PlacementFittingGenerator
extends Node3D

const ComputeShaderBaseScript := preload("res://scripts/godot_compute_shader_base.gd")

@export var texture_size: int = 256                         # 输入 / 工作纹理分辨率
@export var capture_size: float = 1000.0                    # 俯视捕获场景范围
@export var max_height: float = 10000.0                     # 场景高度上限
@export var generate_threshold: float = 0.5                 # generate_mask 最低覆盖比例
@export var un_generate_threshold: float = 0.3              # un_generate_mask 最高遮挡比例
@export var stamp_overlap: float = 0.0                      # 高度印章与当前高度混合比例

@export var scene_depth_texture: Texture2D                  # 场景俯视深度
@export var scene_normal_texture: Texture2D                 # 场景法线
@export var object_depth_texture: Texture2D                 # 已有物体俯视深度
@export var object_normal_texture: Texture2D                # 已有物体法线
@export var height_normal_texture: Texture2D                # ExtentMask 用高度法线
@export var target_height_texture: Texture2D                # 每像素目标高度
@export var mesh_height_array_texture: Texture2D
@export var placed_mask_texture: Texture2D
@export var placement_override_mask_texture: Texture2D
@export var placement_override_delta_texture: Texture2D

@export var fitting_assets: Array = []                      # 带高度图 / 尺寸的 fitted 资产
@export var override_assets: Array = []                     # 非空时替代 fitting_assets

var rd: RenderingDevice
var _compute
var _is_local_rd: bool = false
var _debug_target_height_image: Image
var _debug_current_height_image: Image
var _active_fitting_assets: Array = []
var _dispatch_failed: bool = false

var _shader_init: RID
var _shader_fill: RID
var _shader_find: RID
var _shader_update: RID

var _pipeline_init: RID
var _pipeline_fill: RID
var _pipeline_find: RID
var _pipeline_update: RID

var _sampler: RID


func _begin_dispatch(pass_name: String) -> int:
	var cl: int = _compute.begin_compute_list()
	if cl < 0:
		_dispatch_failed = true
		push_error("PlacementFittingGenerator: compute list begin failed during %s" % pass_name)
	return cl


func _resolve_fitting_assets() -> Array:
	var source_assets := override_assets if not override_assets.is_empty() else fitting_assets
	var result: Array = []
	for asset in source_assets:
		if _is_valid_fitting_asset(asset):
			result.append(asset)
	return result


func _is_valid_fitting_asset(asset) -> bool:
	if asset == null:
		return false
	if asset is Object and asset.has_method("is_valid_fitting_asset"):
		return bool(asset.call("is_valid_fitting_asset"))
	return _get_asset_height_texture(asset) != null and _get_asset_size(asset) > 0.0


func _asset_value(asset, key: String, fallback = null):
	if asset == null:
		return fallback
	if asset is Dictionary:
		return (asset as Dictionary).get(key, fallback)
	if asset is Object:
		var value = asset.get(key)
		return fallback if value == null else value
	return fallback


func _texture_from_value(value) -> Texture2D:
	if value is Texture2D:
		return value as Texture2D
	if value is String:
		var path := str(value)
		if not path.is_empty() and ResourceLoader.exists(path):
			var loaded := load(path)
			if loaded is Texture2D:
				return loaded as Texture2D
	return null


func _vector2_from_value(value, fallback: Vector2) -> Vector2:
	if value is Vector2:
		return value as Vector2
	if value is Vector2i:
		var v := value as Vector2i
		return Vector2(v.x, v.y)
	if value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	return fallback


func _get_asset_height_texture(asset) -> Texture2D:
	if asset == null:
		return null
	for key in ["fitting_height_texture", "mesh_height_texture"]:  # mesh_height_texture: 俯视资产高度图
		var texture := _texture_from_value(_asset_value(asset, key))
		if texture != null:
			return texture
	return null


func _get_asset_size(asset) -> float:
	if asset == null:
		return 0.0
	for key in ["fitting_size", "asset_size", "mesh_size"]:  # mesh_size: 纹理空间资产尺寸
		var value = _asset_value(asset, key)
		if value != null:
			return maxf(float(value), 0.0)
	return 0.0


func _get_asset_id(asset, index: int) -> String:
	var value := str(_asset_value(asset, "asset_id", ""))
	if not value.is_empty():
		return value
	return "fitting_asset_%d" % index


func _get_asset_color(asset) -> Color:
	if asset is Object and asset.has_method("get_voxel_color"):
		return asset.call("get_voxel_color")
	var value = _asset_value(asset, "color")
	if value is Color:
		return value as Color
	return Color.WHITE


func _get_asset_complexity(asset) -> float:
	if asset is Object and asset.has_method("get_voxel_complexity"):
		return float(asset.call("get_voxel_complexity"))
	return float(_asset_value(asset, "complexity", 1.0))


func generate_placement(
	num_iteration: int,
	spawn_size: float = 1.0,
	dirty_rect: Rect2i = Rect2i(),
	settings: Dictionary = {}
) -> Array[Dictionary]:
	var results := generate_heightfield_fit(num_iteration, spawn_size, dirty_rect)
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
	var normal_values := _image_rgba32f_values(normal_image)

	var twist_scale := float(settings.get("twist_scale", 1.0))
	var output: Array[Dictionary] = []
	output.resize(results.size())
	for i in range(results.size()):
		var decorated := results[i].duplicate(true)
		var base_rotation: Vector3 = decorated.get("rotation_degrees", Vector3.ZERO)
		var twist_y := base_rotation.y
		var surface_normal := _sample_surface_normal_from_result(decorated, normal_image, normal_values)
		var rotation_degrees := _rotation_degrees_from_surface_normal(surface_normal, deg_to_rad(twist_y) * twist_scale)
		decorated["placement_mode"] = str(settings.get("placement_mode", "surface_3d"))
		decorated["surface_normal"] = surface_normal
		decorated["rotation_mode"] = "XYZ"
		decorated["rotation_degrees"] = rotation_degrees
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


func generate_heightfield_fit(num_iteration: int, spawn_size: float = 1.0, dirty_rect: Rect2i = Rect2i()) -> Array[Dictionary]:
	_active_fitting_assets = _resolve_fitting_assets()
	if _active_fitting_assets.is_empty():
		push_error("PlacementFittingGenerator: no fitting assets available")
		return []

	_compute = ComputeShaderBaseScript.new()
	_compute.log_name = "PlacementFittingGenerator"
	if not _compute.ensure_device():
		return []
	rd = _compute.get_rendering_device()
	_is_local_rd = _compute.owns_rendering_device()
	_dispatch_failed = false

	var dr := dirty_rect
	if dr.size.x <= 0 or dr.size.y <= 0:
		dr = Rect2i(0, 0, texture_size, texture_size)

	_load_shaders()
	_sampler = _compute.create_linear_sampler()

	var input_textures := _upload_input_textures()
	var working := _create_working_textures()

	var generate_datas: Array[Dictionary] = []
	for i in range(num_iteration):
		var idx := randi_range(0, _active_fitting_assets.size() - 1)
		var asset = _active_fitting_assets[idx]
		generate_datas.append({
			"select_index": idx,                                            # 本轮选中的资产索引
			"random_rotate": _vector2_from_value(_asset_value(asset, "random_rotate"), Vector2.ZERO),               # 随机旋转范围
			"random_scale": _vector2_from_value(_asset_value(asset, "random_scale"), Vector2.ONE),                 # 随机缩放范围
			"random_height_offset": _vector2_from_value(_asset_value(asset, "random_height_offset"), Vector2.ZERO),  # 随机高度偏移范围
			"fitting_size": _get_asset_size(asset),                         # mesh_size-driven fitting size
		})

	var mesh_tex_rids: Array[RID] = []
	for asset in _active_fitting_assets:
		mesh_tex_rids.append(_upload_texture(_get_asset_height_texture(asset).get_image()))

	# === Pass 1: Init ===
	_dispatch_init(input_textures, working, dr)
	if _dispatch_failed:
		_cleanup(input_textures, working, mesh_tex_rids)
		return []

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

		# Pass 3: Fill heightfield asset (full dispatch, dirty_rect guard inside shader)
		_dispatch_fill(working, mesh_tex, gd, spawn_size, dr)
		if _dispatch_failed:
			_cleanup(input_textures, working, mesh_tex_rids)
			return []

		# Pass 4: FindBestPixelRW (single workgroup, no dirty_rect needed)
		_dispatch_find(working, input_textures, gd.select_index)
		if _dispatch_failed:
			_cleanup(input_textures, working, mesh_tex_rids)
			return []

		# Pass 5: UpdateCurrentHeight (full dispatch, dirty_rect guard inside shader)
		_dispatch_update(working, mesh_tex, input_textures, gd.select_index, dr)
		if _dispatch_failed:
			_cleanup(input_textures, working, mesh_tex_rids)
			return []

		# Ping-pong swap
		var swap_cs: RID = working.current_scene_depth_a
		working.current_scene_depth_a = working.current_scene_depth_b
		working.current_scene_depth_b = swap_cs

		var swap_r: RID = working.result_a
		working.result_a = working.result_b
		working.result_b = swap_r

	if _compute != null:
		_compute.submit_and_sync()
	var th_data := rd.texture_get_data(working.target_height, 0)
	_debug_target_height_image = Image.create_from_data(texture_size, texture_size, false, Image.FORMAT_RGBAH, th_data)

	var ch_data := rd.texture_get_data(working.current_scene_depth_a, 0)
	_debug_current_height_image = Image.create_from_data(texture_size, texture_size, false, Image.FORMAT_RGBAH, ch_data)

	# Read back results
	var results := _read_results(working)

	# Cleanup
	_cleanup(input_textures, working, mesh_tex_rids)

	return results


# Shader loading

func _load_shaders() -> void:
	_shader_init = _compute.load_compute_shader("res://shaders/init_heightfield_fitting.glsl")
	_shader_fill = _compute.load_compute_shader("res://shaders/fill_heightfield_asset.glsl")
	_shader_find = _compute.load_compute_shader("res://shaders/find_best_pixel.glsl")
	_shader_update = _compute.load_compute_shader("res://shaders/update_current_height.glsl")

	_pipeline_init = _compute.create_compute_pipeline(_shader_init)
	_pipeline_fill = _compute.create_compute_pipeline(_shader_fill)
	_pipeline_find = _compute.create_compute_pipeline(_shader_find)
	_pipeline_update = _compute.create_compute_pipeline(_shader_update)


# Texture creation and upload

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
	var placed_mask_img: Image
	if placed_mask_texture != null:
		placed_mask_img = placed_mask_texture.get_image()
	else:
		placed_mask_img = Image.create(texture_size, texture_size, false, Image.FORMAT_RGBAF)
		placed_mask_img.fill(Color(0.0, 0.0, 0.0, 0.0))

	var placement_override_mask_img: Image
	if placement_override_mask_texture != null:
		placement_override_mask_img = placement_override_mask_texture.get_image()
	else:
		placement_override_mask_img = Image.create(texture_size, texture_size, false, Image.FORMAT_RGBAF)
		placement_override_mask_img.fill(Color(0.0, 0.0, 0.0, 0.0))

	var placement_override_delta_img: Image
	if placement_override_delta_texture != null:
		placement_override_delta_img = placement_override_delta_texture.get_image()
	else:
		placement_override_delta_img = Image.create(texture_size, texture_size, false, Image.FORMAT_RGBAF)
		placement_override_delta_img.fill(Color(0.0, 0.0, 0.0, 0.0))

	return {
		"scene_depth": _upload_texture(scene_depth_texture.get_image()),                    # 场景俯视深度
		"scene_normal": _upload_texture(scene_normal_texture.get_image()),                  # 场景法线
		"object_depth": _upload_texture(object_depth_texture.get_image()),                  # 已有物体俯视深度
		"object_normal": _upload_texture(object_normal_texture.get_image()),                # 已有物体法线
		"height_normal": _upload_texture(height_normal_texture.get_image()),                # ExtentMask 用高度法线
		"target_height": _upload_texture(target_height_texture.get_image()),                # 每像素目标高度
		"placed_mask": _upload_texture(placed_mask_img),
		"placement_override_mask": _upload_texture(placement_override_mask_img),
		"placement_override_delta": _upload_texture(placement_override_delta_img),
	}


func _create_working_textures() -> Dictionary:
	var s := texture_size
	return {
		"current_scene_depth": _create_image_texture(s, s),  # R=当前高度,G=禁放,B=生成
		"current_scene_depth_read": _create_image_texture(s, s),
		"current_scene_depth_a": _create_image_texture(s, s),
		"current_scene_depth_b": _create_image_texture(s, s),
		"target_height": _create_image_texture(s, s),        # R=目标高度,G=mask,B=旋转角
		"debug_view": _create_image_texture(s, s),
		"result_a": _create_image_texture(1024, 2),          # row0=位置,row1=旋转/缩放/mesh
		"result_b": _create_image_texture(1024, 2),          # result ping-pong
		"filter_result": _create_image_texture(ceili(float(s) / 16.0), ceili(float(s) / 16.0)),  # group 最优候选
		"save_rotate_scale": _create_image_texture(s, s),   # 旋转/缩放/高度/mesh
		"deduplication": _create_image_texture(s, s),
		"filter_result_mult": _create_image_texture(s, s),
	}


# Uniform set helpers

# Pass 1: Init

func _dispatch_init(inputs: Dictionary, working: Dictionary, dr: Rect2i) -> void:
	var set0: RID = _compute.create_uniform_set([
		_compute.make_sampler_uniform(0, _sampler, inputs.scene_depth),
		_compute.make_sampler_uniform(1, _sampler, inputs.object_depth),
		_compute.make_sampler_uniform(2, _sampler, inputs.object_normal),
		_compute.make_sampler_uniform(3, _sampler, inputs.target_height),
		_compute.make_sampler_uniform(4, _sampler, inputs.placed_mask),
		_compute.make_sampler_uniform(5, _sampler, inputs.placement_override_mask),
		_compute.make_sampler_uniform(6, _sampler, inputs.placement_override_delta),
	], _shader_init, 0)

	var set1: RID = _compute.create_uniform_set([
		_compute.make_image_uniform(0, working.current_scene_depth),
		_compute.make_image_uniform(1, working.target_height),
		_compute.make_image_uniform(2, working.debug_view),
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

	var cl: int = _begin_dispatch("init")
	if cl < 0:
		return
	rd.compute_list_bind_compute_pipeline(cl, _pipeline_init)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_bind_uniform_set(cl, set1, 1)
	rd.compute_list_set_push_constant(cl, push_buf, push_buf.size())
	rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	_compute.end_compute_list()
	if _compute != null:
		_compute.submit_and_sync()


# Pass 3: Fill Heightfield Asset

func _dispatch_fill(working: Dictionary, mesh_tex: RID, gen_data: Dictionary, spawn_size_val: float, dr: Rect2i) -> void:
	var idx: int = gen_data.select_index
	var fitting_size := float(gen_data.get("fitting_size", 0.0))
	var draw_size: float = fitting_size / capture_size * spawn_size_val

	var set0: RID = _compute.create_uniform_set([
		_compute.make_image_uniform(0, working.current_scene_depth_a),
		_compute.make_image_uniform(1, working.current_scene_depth_b),
		_compute.make_image_uniform(2, working.result_a),
		_compute.make_image_uniform(3, working.result_b),
		_compute.make_image_uniform(4, working.filter_result),
		_compute.make_image_uniform(5, working.save_rotate_scale),
		_compute.make_image_uniform(6, working.target_height),
		_compute.make_image_uniform(7, working.debug_view),
	], _shader_fill, 0)

	var set1: RID = _compute.create_uniform_set([
		_compute.make_sampler_uniform(0, _sampler, mesh_tex),
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

	var cl: int = _begin_dispatch("fill")
	if cl < 0:
		return
	rd.compute_list_bind_compute_pipeline(cl, _pipeline_fill)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_bind_uniform_set(cl, set1, 1)
	rd.compute_list_set_push_constant(cl, push_buf, push_buf.size())
	rd.compute_list_dispatch(cl, groups, groups, 1)
	_compute.end_compute_list()
	if _compute != null:
		_compute.submit_and_sync()


# Pass 4: Find Best Pixel

func _dispatch_find(working: Dictionary, inputs: Dictionary, select_idx: int) -> void:
	var set0: RID = _compute.create_uniform_set([
		_compute.make_image_uniform(0, working.filter_result),
		_compute.make_image_uniform(1, working.save_rotate_scale),
		_compute.make_image_uniform(2, working.current_scene_depth_a),
		_compute.make_image_uniform(3, working.result_a),
		_compute.make_image_uniform(4, working.result_b),
		_compute.make_image_uniform(5, working.debug_view),
	], _shader_find, 0)

	var set1: RID = _compute.create_uniform_set([
		_compute.make_sampler_uniform(0, _sampler, inputs.scene_normal),
	], _shader_find, 1)

	var push_buf := PackedByteArray()
	push_buf.resize(16)
	push_buf.encode_s32(0, select_idx)
	push_buf.encode_float(4, 0.0)
	push_buf.encode_float(8, 0.0)
	push_buf.encode_float(12, 0.0)

	var cl: int = _begin_dispatch("find")
	if cl < 0:
		return
	rd.compute_list_bind_compute_pipeline(cl, _pipeline_find)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_bind_uniform_set(cl, set1, 1)
	rd.compute_list_set_push_constant(cl, push_buf, push_buf.size())
	rd.compute_list_dispatch(cl, 1, 1, 1)
	_compute.end_compute_list()
	if _compute != null:
		_compute.submit_and_sync()


# Pass 5: Update Current Height

func _dispatch_update(working: Dictionary, mesh_tex: RID, inputs: Dictionary, select_idx: int, dr: Rect2i) -> void:
	var set0: RID = _compute.create_uniform_set([
		_compute.make_image_uniform(0, working.current_scene_depth_a),
		_compute.make_image_uniform(1, working.current_scene_depth_b),
		_compute.make_image_uniform(2, working.result_b),
		_compute.make_image_uniform(3, working.result_a),
		_compute.make_image_uniform(4, working.debug_view),
	], _shader_update, 0)

	var set1: RID = _compute.create_uniform_set([
		_compute.make_sampler_uniform(0, _sampler, mesh_tex),
		_compute.make_sampler_uniform(1, _sampler, inputs.scene_normal),
		_compute.make_sampler_uniform(2, _sampler, working.target_height),
	], _shader_update, 1)

	var push_buf := PackedByteArray()
	push_buf.resize(32)
	push_buf.encode_float(0, max_height)
	push_buf.encode_float(4, capture_size)
	push_buf.encode_s32(8, select_idx)
	push_buf.encode_float(12, stamp_overlap)
	push_buf.encode_s32(16, dr.position.x)
	push_buf.encode_s32(20, dr.position.y)
	push_buf.encode_s32(24, dr.size.x)
	push_buf.encode_s32(28, dr.size.y)

	var groups := ceili(float(texture_size) / 32.0)

	var cl: int = _begin_dispatch("update")
	if cl < 0:
		return
	rd.compute_list_bind_compute_pipeline(cl, _pipeline_update)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_bind_uniform_set(cl, set1, 1)
	rd.compute_list_set_push_constant(cl, push_buf, push_buf.size())
	rd.compute_list_dispatch(cl, groups, groups, 1)
	_compute.end_compute_list()
	if _compute != null:
		_compute.submit_and_sync()


# Result readback

func _read_results(working: Dictionary) -> Array[Dictionary]:
	var tex_data := rd.texture_get_data(working.result_a, 0)
	var img := Image.create_from_data(1024, 2, false, Image.FORMAT_RGBAH, tex_data)
	if img == null or img.is_empty():
		return []
	img.convert(Image.FORMAT_RGBAF)
	var values := img.get_data().to_float32_array()
	if values.size() < 1024 * 2 * 4:
		return []

	var last_base := (1024 + 1023) * 4
	var max_gen := clampi(int(round(values[last_base])), 0, 1024)
	if max_gen == 0:
		return []

	var results: Array[Dictionary] = []
	for i in range(max_gen):
		var pos_base := i * 4
		var rsi_base := (1024 + i) * 4

		var loc_x: float = values[pos_base + 0]
		var loc_y: float = values[pos_base + 1]
		var loc_z: float = values[pos_base + 2]
		var rot: float = values[rsi_base + 0]
		var scl: float = values[rsi_base + 1]
		var mesh_idx: int = int(round(values[rsi_base + 2]))

		if scl < 0.01:
			continue
		if mesh_idx < 0 or mesh_idx >= _active_fitting_assets.size():
			push_warning("PlacementFittingGenerator: skipping result with invalid asset index %d" % mesh_idx)
			continue

		var asset = _active_fitting_assets[mesh_idx]
		var fitting_size := _get_asset_size(asset)
		var world_scale: float = scl / fitting_size * capture_size
		var world_pos := Vector3(
			loc_x * capture_size - capture_size / 2.0 + global_position.x,
			loc_z,
			loc_y * capture_size - capture_size / 2.0 + global_position.z
		)

		results.append({
			"position": world_pos,
			"rotation_mode": "Y",
			"rotation_degrees": Vector3(0.0, rad_to_deg(rot), 0.0),
			"scale": Vector3.ONE * world_scale,
			"mesh_index": mesh_idx,
			"asset_index": mesh_idx,
			"asset_id": _get_asset_id(asset, mesh_idx),
			"color": _get_asset_color(asset),
			"complexity": _get_asset_complexity(asset),
		})

	return results

# Surface rotation helpers

func _sample_surface_normal_from_result(result: Dictionary, normal_image: Image, normal_values: PackedFloat32Array = PackedFloat32Array()) -> Vector3:
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
	var value_index := (px.y * width + px.x) * 4
	var normal_color := Color(0.5, 1.0, 0.5, 1.0)
	if value_index + 2 < normal_values.size():
		normal_color = Color(normal_values[value_index], normal_values[value_index + 1], normal_values[value_index + 2], 1.0)
	else:
		normal_color = normal_image.get_pixelv(px)
	var normal := Vector3(
		normal_color.r * 2.0 - 1.0,
		normal_color.g * 2.0 - 1.0,
		normal_color.b * 2.0 - 1.0
	)
	if normal.length_squared() <= 0.000001:
		return Vector3.UP
	return normal.normalized()


func _image_rgba32f_values(img: Image) -> PackedFloat32Array:
	if img == null or img.is_empty():
		return PackedFloat32Array()
	var copy := img.duplicate()
	if copy.get_format() != Image.FORMAT_RGBAF:
		copy.convert(Image.FORMAT_RGBAF)
	return copy.get_data().to_float32_array()


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


# Cleanup

func _cleanup(_inputs: Dictionary, _working: Dictionary, _mesh_tex_rids: Array[RID]) -> void:
	if _compute != null:
		_compute.dispose()
	rd = null
	_compute = null
	_is_local_rd = false
	_shader_init = RID()
	_shader_fill = RID()
	_shader_find = RID()
	_shader_update = RID()
	_pipeline_init = RID()
	_pipeline_fill = RID()
	_pipeline_find = RID()
	_pipeline_update = RID()
	_sampler = RID()
	_dispatch_failed = false
