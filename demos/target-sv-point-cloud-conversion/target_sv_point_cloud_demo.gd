@tool
extends Node3D

const TargetSceneVoxelGeneratorScript := preload("res://scripts/target_scene_voxel_generator.gd")
const TerrainInitializerScript := preload("res://scripts/terrain_initializer.gd")

const META_PATH := "res://demos/target-sv-point-cloud-conversion/target_sv_point_cloud.json"
const HEIGHT_PATH := "res://textures/scene_height_0_1.png"
const GENERATED_GROUP := "target_sv_point_cloud_generated"

@export var display_scale := 0.03
@export var terrain_stride := 4
@export var max_voxel_instances := 14000
@export var occupancy_threshold := 0.001

var _metadata: Dictionary = {}
var _visual_bytes := PackedByteArray()
var _collision_bytes := PackedByteArray()
var _height_image: Image
var _height_luma_bytes := PackedByteArray()
var _height_width := 0
var _height_height := 0


func _ready() -> void:
	_rebuild_visualization()


func ensure_test_terrain_initialized() -> Dictionary:
	return TerrainInitializerScript.ensure_terrain_initialized(self, {
		"terrain_name": "Terrain",
		"capture_size": 120.0,
		"max_height": 120.0,
		"visible": false,
	})


func _rebuild_visualization() -> void:
	var terrain_contract := ensure_test_terrain_initialized()
	if not bool(terrain_contract.get("ok", false)):
		push_error("[TargetSVPointCloudDemo] Terrain initialization failed: %s" % str(terrain_contract.get("reason", "unknown")))
	_clear_generated_visuals()
	_load_fixture()
	if _metadata.is_empty():
		return
	_build_terrain()
	_build_preview_overlay()
	_build_target_voxels()
	_build_labels()


func _clear_generated_visuals() -> void:
	for child in get_children():
		if child.is_in_group(GENERATED_GROUP):
			remove_child(child)
			child.free()


func _add_generated_child(node: Node) -> void:
	node.add_to_group(GENERATED_GROUP)
	add_child(node)


func _load_fixture() -> void:
	var meta_file := FileAccess.open(META_PATH, FileAccess.READ)
	if meta_file == null:
		push_error("[TargetSVPointCloudDemo] Missing metadata: %s" % META_PATH)
		return
	var parsed = JSON.parse_string(meta_file.get_as_text())
	if parsed is Dictionary:
		_metadata = parsed
	else:
		push_error("[TargetSVPointCloudDemo] Invalid metadata JSON")
		return

	_visual_bytes = _read_bytes(str(_metadata.get("visual_path", "")))
	_collision_bytes = _read_bytes(str(_metadata.get("collision_path", "")))
	var height_texture := load(HEIGHT_PATH) as Texture2D
	_height_image = height_texture.get_image() if height_texture != null else Image.load_from_file(HEIGHT_PATH)
	if _height_image != null and _height_image.get_format() != Image.FORMAT_L8:
		_height_image.convert(Image.FORMAT_L8)
	if _height_image != null and not _height_image.is_empty():
		_height_width = _height_image.get_width()
		_height_height = _height_image.get_height()
		_height_luma_bytes = _height_image.get_data()


func _read_bytes(path: String) -> PackedByteArray:
	if path.is_empty():
		return PackedByteArray()
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("[TargetSVPointCloudDemo] Missing buffer: %s" % path)
		return PackedByteArray()
	return file.get_buffer(file.get_length())


func _build_terrain() -> void:
	if _height_image == null or _metadata.is_empty():
		return
	var texture_size := int(_metadata.get("texture_size", _height_image.get_width()))
	var capture_size := float(_metadata.get("capture_size", 1.0))
	var max_height := float(_metadata.get("max_height", 120.0))
	var stride := maxi(terrain_stride, 1)
	var steps := int(ceil(float(texture_size - 1) / float(stride)))

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for z_step in range(steps):
		for x_step in range(steps):
			var x0 := mini(x_step * stride, texture_size - 1)
			var z0 := mini(z_step * stride, texture_size - 1)
			var x1 := mini((x_step + 1) * stride, texture_size - 1)
			var z1 := mini((z_step + 1) * stride, texture_size - 1)
			_add_terrain_triangle(st, x0, z0, x1, z0, x1, z1, texture_size, capture_size, max_height)
			_add_terrain_triangle(st, x0, z0, x1, z1, x0, z1, texture_size, capture_size, max_height)
	st.generate_normals()

	var terrain := MeshInstance3D.new()
	terrain.name = "HeightTextureTerrain"
	terrain.mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.28, 0.34, 0.28, 1.0)
	mat.roughness = 0.9
	terrain.material_override = mat
	_add_generated_child(terrain)


func _add_terrain_triangle(st: SurfaceTool, ax: int, az: int, bx: int, bz: int, cx: int, cz: int, texture_size: int, capture_size: float, max_height: float) -> void:
	for p in [Vector2i(ax, az), Vector2i(bx, bz), Vector2i(cx, cz)]:
		var uv := Vector2(float(p.x) / float(texture_size - 1), float(p.y) / float(texture_size - 1))
		st.set_uv(uv)
		st.add_vertex(_pixel_to_world(p.x, p.y, texture_size, capture_size, _height_at_pixel(p.x, p.y) * max_height))


func _build_preview_overlay() -> void:
	if _metadata.is_empty():
		return
	var preview_path := str(_metadata.get("preview_path", ""))
	var preview_img := _load_png_image(preview_path)
	if preview_img == null:
		push_warning("[TargetSVPointCloudDemo] Missing preview image: %s" % preview_path)
		return

	var texture_size := int(_metadata.get("texture_size", preview_img.get_width()))
	var capture_size := float(_metadata.get("capture_size", 1.0))
	var y := 0.08
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var corners := [
		[0, 0, Vector2(0, 0)],
		[texture_size - 1, 0, Vector2(1, 0)],
		[texture_size - 1, texture_size - 1, Vector2(1, 1)],
		[0, 0, Vector2(0, 0)],
		[texture_size - 1, texture_size - 1, Vector2(1, 1)],
		[0, texture_size - 1, Vector2(0, 1)],
	]
	for corner in corners:
		st.set_uv(corner[2])
		st.add_vertex(_pixel_to_world(int(corner[0]), int(corner[1]), texture_size, capture_size, y / display_scale))

	var overlay := MeshInstance3D.new()
	overlay.name = "TargetSVPreviewOverlay"
	overlay.mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = ImageTexture.create_from_image(preview_img)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1, 1, 1, 0.82)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = true
	overlay.material_override = mat
	_add_generated_child(overlay)


func _build_target_voxels() -> void:
	if _metadata.is_empty() or _visual_bytes.is_empty() or _collision_bytes.is_empty():
		return
	var texture_size := int(_metadata.get("texture_size", 1))
	var slice_count := int(_metadata.get("slice_count", 1))
	var capture_size := float(_metadata.get("capture_size", 1.0))
	var vertical_span := float(_metadata.get("vertical_span", 16.0))
	var max_height := float(_metadata.get("max_height", 120.0))
	var decoded := TargetSceneVoxelGeneratorScript.decode_target_read_buffers(_visual_bytes, _collision_bytes, texture_size, slice_count)
	var occupancy: PackedFloat32Array = decoded.get("target_occupancy", PackedFloat32Array())
	var target_color: PackedColorArray = decoded.get("target_color", PackedColorArray())
	if occupancy.is_empty() or target_color.is_empty():
		push_error("[TargetSVPointCloudDemo] TargetSV decode failed: %s" % str(decoded))
		return
	var collision_values := _collision_float_values(texture_size * texture_size * slice_count)

	var non_empty := []
	for i in range(occupancy.size()):
		if occupancy[i] > occupancy_threshold:
			non_empty.append(i)
	var sample_every := maxi(ceili(float(non_empty.size()) / float(maxi(max_voxel_instances, 1))), 1)
	var instance_count := ceili(float(non_empty.size()) / float(sample_every))

	var box := BoxMesh.new()
	var cell_size := capture_size / maxf(float(texture_size - 1), 1.0) * display_scale * 0.72
	var slice_height := vertical_span / maxf(float(slice_count), 1.0) * display_scale * 0.72
	box.size = Vector3(cell_size, maxf(slice_height, 0.02), cell_size)

	var multi_mesh := MultiMesh.new()
	multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
	multi_mesh.use_colors = true
	multi_mesh.mesh = box
	multi_mesh.instance_count = instance_count

	var write_index := 0
	var slice_voxel_count := texture_size * texture_size
	for source_index in range(0, non_empty.size(), sample_every):
		if write_index >= instance_count:
			break
		var idx := int(non_empty[source_index])
		var slice_index := idx / slice_voxel_count
		var rem := idx % slice_voxel_count
		var z := rem / texture_size
		var x := rem % texture_size
		var local_y := (float(slice_index) + 0.5) / float(slice_count) * vertical_span
		var terrain_y := _height_at_pixel(x, z) * max_height
		var pos := _pixel_to_world(x, z, texture_size, capture_size, terrain_y + local_y)
		multi_mesh.set_instance_transform(write_index, Transform3D(Basis(), pos))
		var color := target_color[idx]
		var collision := collision_values[idx] if idx < collision_values.size() else 0.0
		color = color.lerp(Color(0.82, 0.78, 0.68, 1.0), clampf(collision * 0.45, 0.0, 1.0))
		color.a = clampf(maxf(occupancy[idx], 0.35), 0.35, 1.0)
		multi_mesh.set_instance_color(write_index, color)
		write_index += 1

	var instance := MultiMeshInstance3D.new()
	instance.name = "TargetSVVoxelSamples"
	instance.multimesh = multi_mesh
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.6
	instance.material_override = mat
	_add_generated_child(instance)


func _build_labels() -> void:
	var label := Label3D.new()
	label.name = "Summary"
	label.transform.origin = Vector3(-15.0, 4.5, -14.5)
	label.font_size = 26
	label.pixel_size = 0.018
	label.outline_size = 5
	label.text = "\n".join([
		"TargetSV Point Cloud Conversion",
		"source: TargetSV_PT.bgeo.sc + scene_height_0_1.png",
		"attrs: %s" % str(_metadata.get("attribute_map", {})),
		"points: %d / %d   voxels: %d" % [
			int(_metadata.get("used_point_count", 0)),
			int(_metadata.get("point_count", 0)),
			int(_metadata.get("non_empty_voxel_count", 0)),
		],
		"grid: %dx%dx%d   vertical_span: %.1f" % [
			int(_metadata.get("texture_size", 0)),
			int(_metadata.get("texture_size", 0)),
			int(_metadata.get("slice_count", 0)),
			float(_metadata.get("vertical_span", 0.0)),
		],
	])
	_add_generated_child(label)


func _height_at_pixel(x: int, z: int) -> float:
	if _height_width <= 0 or _height_height <= 0 or _height_luma_bytes.is_empty():
		return 0.0
	var sx := clampi(x, 0, _height_width - 1)
	var sz := clampi(z, 0, _height_height - 1)
	var byte_index := sz * _height_width + sx
	return float(_height_luma_bytes[byte_index]) / 255.0 if byte_index < _height_luma_bytes.size() else 0.0


func _collision_float_values(voxel_count: int) -> PackedFloat32Array:
	var expected_bytes := maxi(voxel_count, 1) * 4
	var available_bytes := mini(_collision_bytes.size(), expected_bytes)
	available_bytes -= available_bytes % 4
	var values := _collision_bytes.slice(0, available_bytes).to_float32_array()
	values.resize(voxel_count)
	return values


func _pixel_to_world(x: int, z: int, texture_size: int, capture_size: float, height: float) -> Vector3:
	var fx := (float(x) / maxf(float(texture_size - 1), 1.0) - 0.5) * capture_size * display_scale
	var fz := (float(z) / maxf(float(texture_size - 1), 1.0) - 0.5) * capture_size * display_scale
	return Vector3(fx, height * display_scale, fz)


func _load_png_image(path: String) -> Image:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var image := Image.new()
	var err := image.load_png_from_buffer(file.get_buffer(file.get_length()))
	return image if err == OK else null
