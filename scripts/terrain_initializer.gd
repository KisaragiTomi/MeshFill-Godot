class_name TerrainInitializer
extends RefCounted

const TerrainConfigScript := preload("res://scripts/terrain_config.gd")
const DEFAULT_TEXTURE_SIZE := TerrainConfigScript.TEXTURE_SIZE
const DEFAULT_CAPTURE_SIZE := TerrainConfigScript.CAPTURE_SIZE
const DEFAULT_MAX_HEIGHT := TerrainConfigScript.MAX_HEIGHT
const DEFAULT_TERRAIN_NAME := TerrainConfigScript.TERRAIN_NAME
const TERRAIN_GROUP := "meshfill_utils_terrain"
const TERRAIN_VOXEL_COLOR := Color(0.45, 0.42, 0.35, 1.0)
const ComputeShaderBaseScript := preload("res://scripts/godot_compute_shader_base.gd")
const FsUtils := preload("res://scripts/utils/fs_utils.gd")
const BufferUtils := preload("res://scripts/utils/buffer_utils.gd")
const HEIGHT_NORMAL_SHADER_PATH := "res://shaders/height_normal_from_height.glsl"
const HEIGHT_NORMAL_LOCAL_SIZE := 16
const HEIGHT_NORMAL_STATS_BUFFER_BYTES := 12
const HEIGHT_NORMAL_STATS_STEEP_COUNT_OFFSET := 0
const HEIGHT_NORMAL_STATS_MIN_NZ_KEY_OFFSET := 4
const HEIGHT_NORMAL_STATS_MAX_NZ_KEY_OFFSET := 8
const HEIGHT_NORMAL_POSITIVE_INF_ORDERED_KEY := 0xFF800000
const HEIGHT_NORMAL_NEGATIVE_INF_ORDERED_KEY := 0x007FFFFF
# push_constant 布局（std430；与各处原手工 encode 逐字节一致）。
const HEIGHT_NORMAL_PUSH := [
	["width", "int"], ["height", "int"], ["cell_size", "float"], ["steep_nz_threshold", "float"],
	["input_stride", "int"], ["_pad0", "int"], ["_pad1", "int"], ["_pad2", "int"],
]
const PROCEDURAL_HEIGHT_PUSH := [
	["res_x", "int"], ["res_y", "int"], ["max_height", "float"], ["_pad0", "float"],
]
const HEIGHT_STATS_PUSH := [
	["width", "int"], ["height", "int"], ["min_seed", "float"], ["_pad0", "float"],
]
const TEXTURE_NAMES := [
	"scene_depth",
	"scene_normal",
	"object_depth",
	"object_normal",
	"height_normal",
	"target_height",
]


static func reuse_shared_terrain(host: Node, overrides := {}) -> Dictionary:
	if host == null:
		return {"ok": false, "reason": "missing_host"}
	var options := TerrainConfigScript.terrain_options(overrides)
	var terrain_name := str(options.get("terrain_name", DEFAULT_TERRAIN_NAME))
	var existing := find_edit_time_terrain(host, terrain_name)
	if existing is MeshInstance3D and (existing as MeshInstance3D).mesh != null:
		return _terrain_result(existing as MeshInstance3D, false, terrain_name)
	if existing != null:
		return {
			"ok": false,
			"reason": "terrain_node_is_not_mesh_instance",
			"terrain_name": terrain_name,
			"node_type": existing.get_class(),
		}
	return {
		"ok": false,
		"reason": "missing_edit_time_terrain",
		"terrain_name": terrain_name,
	}


static func find_edit_time_terrain(host: Node, terrain_name: String = DEFAULT_TERRAIN_NAME) -> Node:
	if host == null:
		return null

	var candidates: Array[Node] = []
	_add_unique_node(candidates, host)

	if host.is_inside_tree():
		var tree := host.get_tree()
		if tree != null:
			_add_unique_node(candidates, tree.current_scene)

	var owner := host.owner
	while owner != null:
		_add_unique_node(candidates, owner)
		owner = owner.owner

	var parent := host.get_parent()
	while parent != null:
		_add_unique_node(candidates, parent)
		parent = parent.get_parent()

	for root in candidates:
		var direct := root.get_node_or_null(NodePath(terrain_name))
		if direct != null:
			return direct

	for root in candidates:
		var by_group := _find_terrain_in_group(root)
		if by_group != null:
			return by_group

	for root in candidates:
		var recursive := _find_child_by_name(root, terrain_name)
		if recursive != null:
			return recursive

	return null


static func terrain_height_field_from_mesh(terrain: MeshInstance3D, texture_size: int = DEFAULT_TEXTURE_SIZE, fallback_max_height: float = DEFAULT_MAX_HEIGHT) -> PackedFloat32Array:
	var res := maxi(texture_size, 1)
	var field := PackedFloat32Array()
	field.resize(res * res)
	if terrain == null or terrain.mesh == null:
		return field

	var capture_size := float(terrain.get_meta("terrain_capture_size", DEFAULT_CAPTURE_SIZE))
	var height_stats = terrain.get_meta("terrain_height_stats", Vector2(0.0, fallback_max_height))
	var min_height := 0.0
	var max_height := fallback_max_height
	if typeof(height_stats) == TYPE_VECTOR2:
		min_height = float((height_stats as Vector2).x)
		max_height = float((height_stats as Vector2).y)
	var y_fallback := maxf(absf(min_height), absf(max_height))

	var source_res := int(terrain.get_meta("terrain_resolution", 0))
	if source_res <= 0:
		source_res = _infer_square_vertex_resolution(terrain.mesh)
	if source_res <= 0:
		source_res = res

	var source := PackedFloat32Array()
	source.resize(source_res * source_res)
	var source_hit := PackedByteArray()
	source_hit.resize(source_res * source_res)

	for surface_index in range(terrain.mesh.get_surface_count()):
		var arrays := terrain.mesh.surface_get_arrays(surface_index)
		if arrays.is_empty():
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for v in vertices:
			var local := v
			var px := clampi(int(round(((local.x / maxf(capture_size, 0.0001)) + 0.5) * float(source_res - 1))), 0, source_res - 1)
			var pz := clampi(int(round(((local.z / maxf(capture_size, 0.0001)) + 0.5) * float(source_res - 1))), 0, source_res - 1)
			var idx := pz * source_res + px
			if source_hit[idx] == 0:
				source[idx] = local.y
				source_hit[idx] = 1
			else:
				source[idx] = maxf(source[idx], local.y)

	for z in range(res):
		var src_z := int(round(float(z) / maxf(float(res - 1), 1.0) * float(source_res - 1)))
		for x in range(res):
			var src_x := int(round(float(x) / maxf(float(res - 1), 1.0) * float(source_res - 1)))
			var idx := src_z * source_res + src_x
			field[z * res + x] = source[idx] if source_hit[idx] != 0 else 0.0

	if y_fallback > 0.0 and _field_max_abs(field) > y_fallback * 4.0:
		for i in range(field.size()):
			field[i] /= maxf(terrain.scale.y, 0.0001)

	return field


static func _add_unique_node(nodes: Array[Node], node: Node) -> void:
	if node == null:
		return
	if nodes.has(node):
		return
	nodes.append(node)


static func _find_terrain_in_group(root: Node) -> Node:
	if root == null:
		return null
	if root.is_in_group(TERRAIN_GROUP):
		return root
	for child in root.get_children():
		var found := _find_terrain_in_group(child)
		if found != null:
			return found
	return null


static func _find_child_by_name(root: Node, terrain_name: String) -> Node:
	if root == null:
		return null
	if root.name == terrain_name:
		return root
	for child in root.get_children():
		var found := _find_child_by_name(child, terrain_name)
		if found != null:
			return found
	return null


static func _infer_square_vertex_resolution(mesh: Mesh) -> int:
	if mesh == null:
		return 0
	var max_vertices := 0
	for surface_index in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(surface_index)
		if arrays.is_empty():
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		max_vertices = maxi(max_vertices, vertices.size())
	var res := int(round(sqrt(float(max_vertices))))
	return res if res * res == max_vertices else 0


static func _field_max_abs(field: PackedFloat32Array) -> float:
	var max_value := 0.0
	for value in field:
		max_value = maxf(max_value, absf(value))
	return max_value


static func ensure_shared_terrain(host: Node, overrides := {}) -> Dictionary:
	return reuse_shared_terrain(host, overrides)


static func ensure_terrain_initialized(root: Node, options := {}) -> Dictionary:
	if root == null:
		return {"ok": false, "reason": "missing_root"}
	return reuse_shared_terrain(root, options)


static func create_terrain_mesh_instance(target_height_texture: Texture2D, options := {}) -> MeshInstance3D:
	if target_height_texture == null:
		return null

	var img := target_height_texture.get_image()
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
	terrain.set_meta("meshfill_utils_terrain_initialized", true)
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
		var tex := FsUtils.load_raw_rgbaf_texture("res://textures/%s.raw" % tname, texture_size, texture_size, "TerrainInit")
		if tex == null:
			all_loaded = false
			break
		textures[tname] = tex
		print("  Loaded: %s (%dx%d)" % [tname, tex.get_width(), tex.get_height()])

	if all_loaded:
		return textures

	print("[TerrainInit] .raw textures not found, generating procedural terrain data...")
	return generate_procedural_textures(texture_size, max_height)


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

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "TerrainInitializerHeightNormal"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return {}
	var rd: RenderingDevice = compute.get_rendering_device()
	var kernel := ComputeKernel.create(compute, HEIGHT_NORMAL_SHADER_PATH, HEIGHT_NORMAL_PUSH, "height_normal_from_height")
	if not kernel.is_valid():
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

	var groups := compute.dispatch_groups_2d(width, height, HEIGHT_NORMAL_LOCAL_SIZE, HEIGHT_NORMAL_LOCAL_SIZE)
	var chain_ok := ComputePassChain.run(compute, [
		kernel.make_pass([height_buf, normal_buf, stats_buf], {
			width = width, height = height, cell_size = maxf(cell_size, 0.000001),
			steep_nz_threshold = steep_nz_threshold, input_stride = 4,
		}, groups),
	])
	if not chain_ok:
		compute.dispose()
		return {}

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
	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "ProceduralTerrainHeight"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return {}
	var rd: RenderingDevice = compute.get_rendering_device()
	var kernel := ComputeKernel.create(compute, "res://shaders/procedural_terrain_height.glsl", PROCEDURAL_HEIGHT_PUSH, "procedural_terrain_height")
	if not kernel.is_valid():
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

	# image 绑定：用逃生口 make_pass_sets（调用方自建 uniform set）。
	var set0 := compute.create_uniform_set([
		compute.make_image_uniform(0, target_tex),
		compute.make_image_uniform(1, depth_tex),
	], kernel.shader, 0)
	if not set0.is_valid():
		compute.dispose()
		return {}

	var groups := ceili(float(res) / 16.0)
	var chain_ok := ComputePassChain.run(compute, [
		kernel.make_pass_sets([set0], {res_x = res, res_y = res, max_height = max_height}, Vector3i(groups, groups, 1)),
	])
	if not chain_ok:
		compute.dispose()
		return {}

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
	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "TerrainInitializerHeightStats"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return {}
	var rd: RenderingDevice = compute.get_rendering_device()
	var kernel := ComputeKernel.create(compute, "res://shaders/height_stats_minmax.glsl", HEIGHT_STATS_PUSH, "height_stats_minmax")
	if not kernel.is_valid():
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
	# 多 set：set0=sampler、set1=storage，位置数组顺序即 set index。
	var set0 := compute.create_uniform_set([
		compute.make_sampler_uniform(0, sampler, height_tex),
	], kernel.shader, 0)
	var set1 := compute.create_uniform_set([
		compute.make_storage_uniform(0, stats_buf),
	], kernel.shader, 1)
	if not set0.is_valid() or not set1.is_valid():
		compute.dispose()
		return {}

	var groups_x := ceili(float(img.get_width()) / 32.0)
	var groups_y := ceili(float(img.get_height()) / 32.0)
	var chain_ok := ComputePassChain.run(compute, [
		kernel.make_pass_sets([set0, set1], {
			width = img.get_width(), height = img.get_height(), min_seed = -10000.0,
		}, Vector3i(groups_x, groups_y, 1)),
	])
	if not chain_ok:
		compute.dispose()
		return {}

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
	return BufferUtils.float_from_ordered_u32(key)


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
