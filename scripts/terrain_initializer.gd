class_name TerrainInitializer
extends RefCounted

const DEFAULT_TEXTURE_SIZE := 256
const DEFAULT_CAPTURE_SIZE := 120.0
const DEFAULT_MAX_HEIGHT := 120.0
const DEFAULT_TERRAIN_NAME := "Terrain"
const TERRAIN_GROUP := "meshfill_common_terrain"
const TERRAIN_VOXEL_COLOR := Color(0.45, 0.42, 0.35, 1.0)
const ComputeShaderBaseScript := preload("res://scripts/godot_compute_shader_base.gd")
const HEIGHT_NORMAL_SHADER_PATH := "res://shaders/height_normal_from_height.glsl"
const HEIGHT_NORMAL_LOCAL_SIZE := 16
const HEIGHT_NORMAL_STATS_BUFFER_BYTES := 12
const HEIGHT_NORMAL_STATS_STEEP_COUNT_OFFSET := 0
const HEIGHT_NORMAL_STATS_MIN_NZ_KEY_OFFSET := 4
const HEIGHT_NORMAL_STATS_MAX_NZ_KEY_OFFSET := 8
const HEIGHT_NORMAL_POSITIVE_INF_ORDERED_KEY := 0xFF800000
const HEIGHT_NORMAL_NEGATIVE_INF_ORDERED_KEY := 0x007FFFFF
const TEXTURE_NAMES := [
	"scene_depth",
	"scene_normal",
	"object_depth",
	"object_normal",
	"height_normal",
	"target_height",
]


static func ensure_terrain_initialized(root: Node, options := {}) -> Dictionary:
	if root == null:
		return {"ok": false, "reason": "missing_root"}

	var terrain_name := str(options.get("terrain_name", DEFAULT_TERRAIN_NAME))
	var replace_existing := bool(options.get("replace_existing", false))
	var existing := root.get_node_or_null(NodePath(terrain_name))
	if existing != null and not replace_existing:
		if existing is MeshInstance3D:
			return _terrain_result(existing as MeshInstance3D, false, terrain_name)
		return {
			"ok": false,
			"reason": "terrain_node_is_not_mesh_instance",
			"terrain_name": terrain_name,
			"node_type": existing.get_class(),
		}

	if existing != null:
		var existing_parent := existing.get_parent()
		if existing_parent != null:
			existing_parent.remove_child(existing)
		existing.free()

	var height_texture := _target_height_texture_from_options(options)
	if height_texture == null:
		return {
			"ok": false,
			"reason": "missing_target_height_texture",
			"terrain_name": terrain_name,
		}

	var terrain := create_terrain_mesh_instance(height_texture, options)
	if terrain == null:
		return {
			"ok": false,
			"reason": "terrain_mesh_creation_failed",
			"terrain_name": terrain_name,
		}

	terrain.name = terrain_name
	root.add_child(terrain)
	return _terrain_result(terrain, true, terrain_name)


static func create_terrain_mesh_instance(height_texture: Texture2D, options := {}) -> MeshInstance3D:
	if height_texture == null:
		return null

	var img := height_texture.get_image()
	if img == null or img.is_empty():
		return null

	var capture_size := float(options.get("capture_size", DEFAULT_CAPTURE_SIZE))
	var res := img.get_width()
	var cell_size := capture_size / maxf(float(res), 1.0)
	var half := capture_size * 0.5
	var height_stats := get_height_stats(img)
	var height_values := img.get_data().to_float32_array()

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	for y in range(res):
		for x in range(res):
			var value_index := (y * res + x) * 4
			var h := height_values[value_index] if value_index < height_values.size() else 0.0
			var px := float(x) * cell_size - half
			var pz := float(y) * cell_size - half
			st.set_uv(Vector2(float(x) / maxf(float(res - 1), 1.0), float(y) / maxf(float(res - 1), 1.0)))
			st.add_vertex(Vector3(px, h, pz))

	for y in range(res - 1):
		for x in range(res - 1):
			var i := y * res + x
			st.add_index(i)
			st.add_index(i + res)
			st.add_index(i + 1)
			st.add_index(i + 1)
			st.add_index(i + res)
			st.add_index(i + res + 1)

	st.generate_normals()

	var mat := StandardMaterial3D.new()
	mat.albedo_color = TERRAIN_VOXEL_COLOR
	mat.roughness = 0.9
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var terrain := MeshInstance3D.new()
	terrain.mesh = st.commit()
	terrain.material_override = mat
	terrain.visible = bool(options.get("visible", true))
	terrain.add_to_group(TERRAIN_GROUP)
	terrain.set_meta("meshfill_common_terrain_initialized", true)
	terrain.set_meta("terrain_height_stats", height_stats)
	terrain.set_meta("terrain_capture_size", capture_size)
	terrain.set_meta("terrain_resolution", res)
	return terrain


static func load_terrain_textures(texture_size: int = DEFAULT_TEXTURE_SIZE, max_height: float = DEFAULT_MAX_HEIGHT) -> Dictionary:
	var textures: Dictionary = {}
	var all_loaded := true
	print("[TerrainInit] Loading terrain textures...")
	for raw_name in TEXTURE_NAMES:
		var tname := str(raw_name)
		var tex := load_raw_texture("res://textures/%s.raw" % tname, texture_size, texture_size)
		if tex == null:
			all_loaded = false
			break
		textures[tname] = tex
		print("  Loaded: %s (%dx%d)" % [tname, tex.get_width(), tex.get_height()])

	if all_loaded:
		return textures

	print("[TerrainInit] .raw textures not found, generating procedural terrain data...")
	return generate_procedural_textures(texture_size, max_height)


static func load_raw_texture(path: String, width: int, height: int) -> ImageTexture:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var expected_size := width * height * 4 * 4
	var data := f.get_buffer(expected_size)
	f.close()
	if data.size() != expected_size:
		push_error("[TerrainInit] Size mismatch for %s: got %d, expected %d" % [path, data.size(), expected_size])
		return null
	var img := Image.create_from_data(width, height, false, Image.FORMAT_RGBAF, data)
	return ImageTexture.create_from_image(img)


static func generate_procedural_textures(texture_size: int = DEFAULT_TEXTURE_SIZE, max_height: float = DEFAULT_MAX_HEIGHT) -> Dictionary:
	var res := maxi(texture_size, 1)
	var height_images := generate_procedural_height_images_gpu(res, max_height)
	if not bool(height_images.get("valid", false)):
		push_error("[TerrainInit] Procedural terrain GPU compute failed")
		return {}
	var target_height_img: Image = height_images.get("target_height", null)
	var scene_depth_img: Image = height_images.get("scene_depth", null)
	if target_height_img == null or scene_depth_img == null:
		push_error("[TerrainInit] Procedural terrain GPU output images missing")
		return {}

	var scene_normal_img := Image.create(res, res, false, Image.FORMAT_RGBAF)
	scene_normal_img.fill(Color(0.0, 0.0, 1.0, 1.0))

	var object_depth_img := Image.create(res, res, false, Image.FORMAT_RGBAF)
	object_depth_img.fill(Color(max_height, 0.0, 0.0, 1.0))

	var object_normal_img := Image.create(res, res, false, Image.FORMAT_RGBAF)
	object_normal_img.fill(Color(0.0, 0.0, 0.0, 1.0))

	var height_normal_result := make_height_normal_image_gpu(target_height_img, DEFAULT_CAPTURE_SIZE / float(res))
	if not bool(height_normal_result.get("valid", false)):
		push_error("[TerrainInit] Procedural terrain height normal GPU compute failed")
		return {}
	var height_normal_img: Image = height_normal_result.get("height_normal", null)
	if height_normal_img == null:
		push_error("[TerrainInit] Procedural terrain height normal output image missing")
		return {}

	print("  Generated: procedural terrain (%dx%d, height ~1-%.0fm)" % [res, res, max_height * 0.6])
	return {
		"scene_depth": ImageTexture.create_from_image(scene_depth_img),
		"scene_normal": ImageTexture.create_from_image(scene_normal_img),
		"object_depth": ImageTexture.create_from_image(object_depth_img),
		"object_normal": ImageTexture.create_from_image(object_normal_img),
		"height_normal": ImageTexture.create_from_image(height_normal_img),
		"target_height": ImageTexture.create_from_image(target_height_img),
	}


static func make_height_normal_image_gpu(height_img: Image, cell_size: float, steep_nz_threshold: float = 0.75) -> Dictionary:
	if height_img == null or height_img.is_empty():
		return {}
	var width := height_img.get_width()
	var height := height_img.get_height()
	if width <= 0 or height <= 0:
		return {}

	var source_img := height_img
	if source_img.get_format() != Image.FORMAT_RGBAF:
		source_img = height_img.duplicate()
		source_img.convert(Image.FORMAT_RGBAF)

	var pixel_count := width * height
	var height_bytes := source_img.get_data()
	if height_bytes.size() != pixel_count * 4 * 4:
		return {}

	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		return {}
	probe_rd.free()

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "TerrainInitializerHeightNormal"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return {}
	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader(HEIGHT_NORMAL_SHADER_PATH)
	var pipeline := compute.create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return {}

	var height_buf := compute.storage_buffer_from_bytes(
		height_bytes,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"terrain_init_height_normal_input_rgba32f"
	)
	var normal_buf := compute.storage_buffer_zero(
		pixel_count * 4 * 4,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"terrain_init_height_normal_output_rgba32f"
	)
	var stats_init := PackedByteArray()
	stats_init.resize(HEIGHT_NORMAL_STATS_BUFFER_BYTES)
	stats_init.encode_u32(HEIGHT_NORMAL_STATS_STEEP_COUNT_OFFSET, 0)
	stats_init.encode_u32(HEIGHT_NORMAL_STATS_MIN_NZ_KEY_OFFSET, HEIGHT_NORMAL_POSITIVE_INF_ORDERED_KEY)
	stats_init.encode_u32(HEIGHT_NORMAL_STATS_MAX_NZ_KEY_OFFSET, HEIGHT_NORMAL_NEGATIVE_INF_ORDERED_KEY)
	var stats_buf := compute.storage_buffer_from_bytes(
		stats_init,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"terrain_init_height_normal_stats_u32"
	)
	if not height_buf.is_valid() or not normal_buf.is_valid() or not stats_buf.is_valid():
		compute.dispose()
		return {}

	var set0 := compute.create_uniform_set([
		compute.make_storage_uniform(0, height_buf),
		compute.make_storage_uniform(1, normal_buf),
		compute.make_storage_uniform(2, stats_buf),
	], shader, 0)
	if not set0.is_valid():
		compute.dispose()
		return {}

	var push := PackedByteArray()
	push.resize(32)
	push.encode_s32(0, width)
	push.encode_s32(4, height)
	push.encode_float(8, maxf(cell_size, 0.000001))
	push.encode_float(12, steep_nz_threshold)
	push.encode_s32(16, 4)
	push.encode_s32(20, 0)

	var groups := compute.dispatch_groups_2d(width, height, HEIGHT_NORMAL_LOCAL_SIZE, HEIGHT_NORMAL_LOCAL_SIZE)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return {}
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, groups.x, groups.y, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var normal_bytes := rd.buffer_get_data(normal_buf, 0, pixel_count * 4 * 4)
	var stats_bytes := rd.buffer_get_data(stats_buf, 0, HEIGHT_NORMAL_STATS_BUFFER_BYTES)
	compute.dispose()
	if normal_bytes.size() != pixel_count * 4 * 4 or stats_bytes.size() < HEIGHT_NORMAL_STATS_BUFFER_BYTES:
		return {}
	return {
		"valid": true,
		"height_normal": Image.create_from_data(width, height, false, Image.FORMAT_RGBAF, normal_bytes),
		"normal_format": "rgba32f_storage_buffer",
		"height_format": "rgba32f_storage_buffer_r_channel",
		"dispatch_groups": groups,
		"steep_count": int(stats_bytes.decode_u32(HEIGHT_NORMAL_STATS_STEEP_COUNT_OFFSET)),
		"min_nz": _ordered_uint_to_float(int(stats_bytes.decode_u32(HEIGHT_NORMAL_STATS_MIN_NZ_KEY_OFFSET))),
		"max_nz": _ordered_uint_to_float(int(stats_bytes.decode_u32(HEIGHT_NORMAL_STATS_MAX_NZ_KEY_OFFSET))),
		"stats_source": "terrain_initializer_height_normal_compute",
	}


static func generate_procedural_height_images_gpu(texture_size: int = DEFAULT_TEXTURE_SIZE, max_height: float = DEFAULT_MAX_HEIGHT) -> Dictionary:
	var res := maxi(texture_size, 1)
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		return {}
	probe_rd.free()

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "ProceduralTerrainHeight"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return {}
	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader("res://shaders/procedural_terrain_height.glsl")
	var pipeline := compute.create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return {}

	var target_tex := compute.create_rw_texture_2d(
		res,
		res,
		RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"procedural_target_height_rgba32f"
	)
	var depth_tex := compute.create_rw_texture_2d(
		res,
		res,
		RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"procedural_scene_depth_rgba32f"
	)
	if not target_tex.is_valid() or not depth_tex.is_valid():
		compute.dispose()
		return {}

	var set0 := compute.create_uniform_set([
		compute.make_image_uniform(0, target_tex),
		compute.make_image_uniform(1, depth_tex),
	], shader, 0)
	if not set0.is_valid():
		compute.dispose()
		return {}

	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, res)
	push.encode_s32(4, res)
	push.encode_float(8, max_height)
	push.encode_float(12, 0.0)

	var groups := ceili(float(res) / 16.0)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return {}
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, groups, groups, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var target_data := rd.texture_get_data(target_tex, 0)
	var depth_data := rd.texture_get_data(depth_tex, 0)
	compute.dispose()
	if target_data.size() != res * res * 16 or depth_data.size() != res * res * 16:
		return {}
	return {
		"valid": true,
		"target_height": Image.create_from_data(res, res, false, Image.FORMAT_RGBAF, target_data),
		"scene_depth": Image.create_from_data(res, res, false, Image.FORMAT_RGBAF, depth_data),
	}


static func get_height_stats(img: Image) -> Vector2:
	var stats := get_height_stats_gpu(img)
	if not bool(stats.get("valid", false)):
		push_error("[TerrainInit] Height stats GPU compute failed")
		return Vector2.ZERO
	return Vector2(float(stats.get("min", 0.0)), float(stats.get("max", 0.0)))


static func get_height_stats_gpu(img: Image) -> Dictionary:
	if img == null or img.is_empty():
		return {}
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		return {}
	probe_rd.free()

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "TerrainInitializerHeightStats"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return {}
	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader("res://shaders/height_stats_minmax.glsl")
	var pipeline := compute.create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return {}

	var height_tex := compute.upload_texture_2d(
		img,
		RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
		Image.FORMAT_RGBAF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"terrain_init_height_stats_rgba32f"
	)
	var stats_bytes := PackedByteArray()
	stats_bytes.resize(12)
	stats_bytes.encode_s32(0, -1)
	var stats_buf := compute.storage_buffer_from_bytes(
		stats_bytes,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"terrain_init_height_stats_u32"
	)
	if not height_tex.is_valid() or not stats_buf.is_valid():
		compute.dispose()
		return {}

	var sampler := compute.create_linear_sampler()
	if not sampler.is_valid():
		compute.dispose()
		return {}
	var set0 := compute.create_uniform_set([
		compute.make_sampler_uniform(0, sampler, height_tex),
	], shader, 0)
	var set1 := compute.create_uniform_set([
		compute.make_storage_uniform(0, stats_buf),
	], shader, 1)
	if not set0.is_valid() or not set1.is_valid():
		compute.dispose()
		return {}

	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, img.get_width())
	push.encode_s32(4, img.get_height())
	push.encode_float(8, -10000.0)
	push.encode_float(12, 0.0)

	var groups_x := ceili(float(img.get_width()) / 32.0)
	var groups_y := ceili(float(img.get_height()) / 32.0)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return {}
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_bind_uniform_set(cl, set1, 1)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var data := rd.buffer_get_data(stats_buf, 0, 12)
	compute.dispose()
	if data.size() < 12:
		return {}
	var min_key := int(data.decode_u32(0))
	var max_key := int(data.decode_u32(4))
	var count := int(data.decode_u32(8))
	if count <= 0:
		return {
			"valid": true,
			"min": 99999.0,
			"max": -99999.0,
			"count": 0,
	}
	return {
		"valid": true,
		"min": _ordered_uint_to_float(min_key),
		"max": _ordered_uint_to_float(max_key),
		"count": count,
	}


static func _ordered_uint_to_float(key: int) -> float:
	var bits := 0
	if (key & 0x80000000) != 0:
		bits = key ^ 0x80000000
	else:
		bits = (~key) & 0xFFFFFFFF
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_u32(0, bits)
	return bytes.decode_float(0)


static func _target_height_texture_from_options(options: Dictionary) -> Texture2D:
	var raw_target = options.get("target_height", null)
	if raw_target is Texture2D:
		return raw_target as Texture2D
	if raw_target is Image:
		return ImageTexture.create_from_image(raw_target as Image)

	var raw_textures = options.get("textures", {})
	if raw_textures is Dictionary:
		var textures := raw_textures as Dictionary
		var raw_texture = textures.get("target_height", null)
		if raw_texture is Texture2D:
			return raw_texture as Texture2D
		if raw_texture is Image:
			return ImageTexture.create_from_image(raw_texture as Image)

	var texture_size := int(options.get("texture_size", DEFAULT_TEXTURE_SIZE))
	var max_height := float(options.get("max_height", DEFAULT_MAX_HEIGHT))
	var loaded := load_terrain_textures(texture_size, max_height)
	var loaded_target = loaded.get("target_height", null)
	if loaded_target is Texture2D:
		return loaded_target as Texture2D
	return null


static func _terrain_result(terrain: MeshInstance3D, created: bool, terrain_name: String) -> Dictionary:
	var height_stats := Vector2.ZERO
	if terrain.has_meta("terrain_height_stats"):
		height_stats = terrain.get_meta("terrain_height_stats")
	return {
		"ok": true,
		"created": created,
		"terrain": terrain,
		"terrain_name": terrain_name,
		"resolution": int(terrain.get_meta("terrain_resolution", 0)),
		"height_stats": height_stats,
		"visible": terrain.visible,
	}
