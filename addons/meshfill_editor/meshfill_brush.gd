@tool
class_name MeshFillBrush
extends Node3D

const TargetSVLoaderScript := preload("res://scripts/target_sv_loader.gd")
const TargetSceneVoxelGeneratorScript := preload("res://scripts/target_scene_voxel_generator.gd")
const TerrainInitializerScript := preload("res://scripts/terrain_initializer.gd")
const VoxelDisplay := preload("res://scripts/utils/voxel_display.gd")
const DisplayChannelUtils := preload("res://scripts/utils/display_channel_utils.gd")
const HEIGHT_PATH := "res://textures/scene_height_0_1.png"
const GUIDANCE_NODE := "GuidanceVoxels"
const BRUSH_NODE := "BrushTetraVoxels"
const GENERATED_GROUP := "meshfill_brush_generated"

enum DisplayChannel { COLOR, COMPLEXITY, COLLISION }
const CHANNEL_NAMES := ["Color", "Complexity", "Collision"]

@export_group("Brush")
@export_range(1, 128) var brush_width: int = 5
@export_range(1, 128) var brush_length: int = 5
@export_range(1, 32) var brush_height: int = 3
@export var brush_paint_color := Color(0.8, 0.4, 0.1)
@export_range(0.0, 1.0) var brush_paint_complexity: float = 0.5
@export_range(0.0, 1.0) var brush_paint_collision: float = 0.5

@export_group("Display")
@export var display_scale: float = 1.0
@export_range(0.0, 1.0) var occupancy_threshold: float = 0.001
@export var brush_visible: bool = true
@export var guidance_visible: bool = false
@export var fresnel_enabled: bool = true

var display_channel: int = DisplayChannel.COLOR

var _metadata: Dictionary = {}
var _visual_bytes := PackedByteArray()
var _collision_bytes := PackedByteArray()
var _height_image: Image
var _height_luma_bytes := PackedByteArray()
var _height_width := 0
var _height_height := 0

var _texture_size := 0
var _slice_count := 0
var _capture_size := 0.0
var _vertical_span := 0.0
var _height_span := 0.0
var _terrain_height_world := PackedFloat32Array()

var _decoded_occupancy := PackedFloat32Array()
var _decoded_color := PackedColorArray()
var _decoded_collision := PackedFloat32Array()

var _brush_voxel_keys := {}
var _brush_voxels := PackedInt32Array()
var _brush_voxel_colors := PackedFloat32Array()
var _brush_voxel_paint_colors := PackedColorArray()
var _brush_voxel_paint_complexity := PackedFloat32Array()
var _brush_voxel_paint_collision := PackedFloat32Array()

var _data_loaded := false


func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	_rebuild.call_deferred()


func rebuild(force: bool = false) -> void:
	_rebuild(force)


func _rebuild(force: bool = false) -> void:
	if not force and not Engine.is_editor_hint():
		return
	var terrain_contract := TerrainInitializerScript.ensure_shared_terrain(self, {"visible": true})
	if not bool(terrain_contract.get("ok", false)):
		push_warning("[MeshFillBrush] Terrain init: %s" % str(terrain_contract.get("reason", "unknown")))
	_scale_terrain_to_display()
	_clear_generated()
	_clear_brush_state()
	_load_target_sv_data()
	if _metadata.is_empty():
		return
	if guidance_visible:
		_decode_channels()
		build_guidance_voxels()
	_rebuild_brush_voxels()


func _scale_terrain_to_display() -> void:
	var terrain := find_child("Terrain", true, false) as MeshInstance3D
	if terrain != null:
		terrain.scale = Vector3.ONE * display_scale
		terrain.visible = true
		terrain.layers = 1
		terrain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _clear_generated() -> void:
	for child in get_children():
		if child.is_in_group(GENERATED_GROUP):
			remove_child(child)
			child.free()


func _add_generated(node: Node) -> void:
	node.add_to_group(GENERATED_GROUP)
	add_child(node)


# ---- TargetSV data loading (independent of demo scripts) -------------------

func _load_target_sv_data() -> void:
	TargetSVLoaderScript.reload()
	_metadata = TargetSVLoaderScript.metadata()
	_visual_bytes = TargetSVLoaderScript.visual_bytes()
	_collision_bytes = TargetSVLoaderScript.collision_bytes()
	if _metadata.is_empty():
		push_warning("[MeshFillBrush] TargetSVLoader returned empty metadata")
		_data_loaded = false
		return

	_texture_size = int(_metadata.get("texture_size", 1))
	_slice_count = int(_metadata.get("slice_count", 1))
	_capture_size = float(_metadata.get("capture_size", 1.0))
	_vertical_span = float(_metadata.get("vertical_span", 16.0))
	_height_span = float(_metadata.get("max_height", 120.0))

	var tex := load(HEIGHT_PATH) as Texture2D
	_height_image = tex.get_image() if tex != null else Image.load_from_file(HEIGHT_PATH)
	if _height_image != null and _height_image.get_format() != Image.FORMAT_L8:
		_height_image.convert(Image.FORMAT_L8)
	if _height_image != null and not _height_image.is_empty():
		_height_width = _height_image.get_width()
		_height_height = _height_image.get_height()
		_height_luma_bytes = _height_image.get_data()
	_build_terrain_height_world()
	_data_loaded = true


func is_data_loaded() -> bool:
	return _data_loaded


func _build_terrain_height_world() -> void:
	_terrain_height_world = PackedFloat32Array()
	_terrain_height_world.resize(_texture_size * _texture_size)
	for z in range(_texture_size):
		for x in range(_texture_size):
			_terrain_height_world[z * _texture_size + x] = _height_at_pixel(x, z) * _height_span


func _decode_channels() -> void:
	_decoded_occupancy = PackedFloat32Array()
	_decoded_color = PackedColorArray()
	_decoded_collision = PackedFloat32Array()
	if _visual_bytes.is_empty() or _collision_bytes.is_empty():
		return
	var decoded := TargetSceneVoxelGeneratorScript.decode_target_read_buffers_gpu(
		_visual_bytes, _collision_bytes, _texture_size, _slice_count
	)
	if not bool(decoded.get("valid", false)):
		decoded = TargetSceneVoxelGeneratorScript.decode_target_read_buffers(
			_visual_bytes, _collision_bytes, _texture_size, _slice_count
		)
	_decoded_occupancy = decoded.get("target_completely", PackedFloat32Array())
	_decoded_color = decoded.get("target_color", PackedColorArray())
	var decoded_collision: PackedFloat32Array = decoded.get("target_collision", PackedFloat32Array())
	if _decoded_occupancy.is_empty() or _decoded_color.is_empty():
		push_error("[MeshFillBrush] TargetSV decode failed")
		return
	var voxel_count := _texture_size * _texture_size * _slice_count
	_decoded_collision.resize(voxel_count)
	for i in range(voxel_count):
		_decoded_collision[i] = clampf(decoded_collision[i], 0.0, 1.0) if i < decoded_collision.size() else 0.0


# ---- Guidance voxels -------------------------------------------------------

func build_guidance_voxels() -> void:
	var existing := get_node_or_null(GUIDANCE_NODE)
	if existing != null:
		existing.free()
	if _decoded_occupancy.is_empty():
		return

	var cell_size := _capture_size / maxf(float(_texture_size - 1), 1.0) * display_scale * 0.72
	var slice_height := _vertical_span / maxf(float(_slice_count), 1.0) * display_scale * 0.72
	var cell := Vector3(cell_size, maxf(slice_height, 0.02), cell_size)
	var voxel_count := _texture_size * _texture_size * _slice_count
	var color_rgba := _decoded_color_rgba(voxel_count)
	var visible_count := 0
	for idx in range(mini(_decoded_occupancy.size(), voxel_count)):
		if _decoded_occupancy[idx] > occupancy_threshold:
			visible_count += 1
	var instance := VoxelDisplay.build_field_gpu(
		voxel_count,
		cell,
		_brush_grid_aabb(cell_size),
		{
			"occupancy": _decoded_occupancy,
			"collision": _decoded_collision,
			"color_rgba": color_rgba,
			"terrain_height": _terrain_height_world,
		},
		{
			"xz_res": _texture_size,
			"slice_count": _slice_count,
			"view_mode": DisplayChannelUtils.channel_to_view_mode(display_channel),
			"capture_size": _capture_size,
			"display_scale": display_scale,
			"vertical_span": _vertical_span,
			"height_span": _height_span,
			"threshold": occupancy_threshold,
		},
		{"name": GUIDANCE_NODE, "fill": 1.0}
	)
	if instance != null:
		instance.visible = guidance_visible
		instance.set_meta("visible_voxel_count", visible_count)
		if fresnel_enabled:
			_apply_fresnel_material(instance)
		_add_generated(instance)


func _decoded_color_rgba(voxel_count: int) -> PackedFloat32Array:
	var color_rgba := PackedFloat32Array()
	color_rgba.resize(voxel_count * 4)
	for idx in range(voxel_count):
		var c := _decoded_color[idx] if idx < _decoded_color.size() else Color.TRANSPARENT
		var base := idx * 4
		color_rgba[base + 0] = clampf(c.r, 0.0, 1.0)
		color_rgba[base + 1] = clampf(c.g, 0.0, 1.0)
		color_rgba[base + 2] = clampf(c.b, 0.0, 1.0)
		color_rgba[base + 3] = clampf(c.a, 0.0, 1.0)
	return color_rgba


func _apply_fresnel_material(instance: MultiMeshInstance3D) -> void:
	if instance == null or instance.multimesh == null:
		return
	var mesh := instance.multimesh.mesh
	if mesh == null:
		return
	instance.material_override = DisplayChannelUtils.create_fresnel_rim_material()


# ---- Brush painting --------------------------------------------------------

func _clear_brush_state() -> void:
	_brush_voxel_keys = {}
	_brush_voxels = PackedInt32Array()
	_brush_voxel_colors = PackedFloat32Array()
	_brush_voxel_paint_colors = PackedColorArray()
	_brush_voxel_paint_complexity = PackedFloat32Array()
	_brush_voxel_paint_collision = PackedFloat32Array()


func clear_brush() -> void:
	_clear_brush_state()
	_rebuild_brush_voxels()


func paint_at_voxel(center: Vector2i) -> bool:
	return _accumulate_brush_extent(center)


func paint_voxel_footprint_for_test(center: Vector2i) -> bool:
	return paint_at_voxel(center)


func flush_brush() -> void:
	_rebuild_brush_voxels()


func screen_to_voxel_xz(camera: Camera3D, screen_pos: Vector2) -> Vector2i:
	if camera == null:
		return Vector2i(-1, -1)
	var from := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	if absf(dir.y) < 1e-6:
		return Vector2i(-1, -1)

	var half := _capture_size * display_scale * 0.5
	var best_px := -1
	var best_pz := -1

	var est_y := _height_span * 0.5 * display_scale
	for _iter in range(3):
		var t := (est_y - from.y) / dir.y
		if t <= 0.0:
			break
		var hit := from + dir * t
		var u := (hit.x + half) / (_capture_size * display_scale)
		var v := (hit.z + half) / (_capture_size * display_scale)
		var px := int(u * float(_texture_size))
		var pz := int(v * float(_texture_size))
		if px < 0 or px >= _texture_size or pz < 0 or pz >= _texture_size:
			break
		best_px = px
		best_pz = pz
		est_y = _height_at_pixel(px, pz) * _height_span * display_scale

	if best_px < 0 or best_pz < 0:
		var t := -from.y / dir.y
		if t <= 0.0:
			return Vector2i(-1, -1)
		var hit := from + dir * t
		var u := (hit.x + half) / (_capture_size * display_scale)
		var v := (hit.z + half) / (_capture_size * display_scale)
		best_px = clampi(int(u * float(_texture_size)), 0, _texture_size - 1)
		best_pz = clampi(int(v * float(_texture_size)), 0, _texture_size - 1)
		if best_px < 0 or best_px >= _texture_size or best_pz < 0 or best_pz >= _texture_size:
			return Vector2i(-1, -1)

	return Vector2i(best_px, best_pz)


func _accumulate_brush_extent(center: Vector2i) -> bool:
	var half_w := int((maxi(brush_width, 1) - 1) / 2)
	var half_l := int((maxi(brush_length, 1) - 1) / 2)
	var slice_max := clampi(brush_height, 1, _slice_count)
	var changed := false
	for dz in range(-half_l, half_l + 1):
		for dx in range(-half_w, half_w + 1):
			var x := center.x + dx
			var z := center.y + dz
			if x < 0 or x >= _texture_size or z < 0 or z >= _texture_size:
				continue
			for s in range(slice_max):
				var key := s * _texture_size * _texture_size + z * _texture_size + x
				if _brush_voxel_keys.has(key):
					continue
				_brush_voxel_keys[key] = true
				_brush_voxels.append(x)
				_brush_voxels.append(s)
				_brush_voxels.append(z)
				_brush_voxels.append(0)
				_brush_voxel_paint_colors.append(brush_paint_color)
				_brush_voxel_paint_complexity.append(brush_paint_complexity)
				_brush_voxel_paint_collision.append(brush_paint_collision)
				changed = true
	return changed


func _rebuild_brush_voxels() -> void:
	var existing := get_node_or_null(BRUSH_NODE)
	if existing != null:
		existing.free()
	var instance_count := _brush_voxels.size() / 4
	if instance_count <= 0:
		return

	_compute_brush_render_colors()

	var cell_size := _capture_size / maxf(float(_texture_size - 1), 1.0) * display_scale * 0.9
	var slice_height := _vertical_span / maxf(float(_slice_count), 1.0) * display_scale * 0.9
	var cell := Vector3(cell_size, maxf(slice_height, 0.03), cell_size)

	var node := VoxelDisplay.build_brush_tetra_gpu(
		_brush_voxels,
		cell,
		_brush_grid_aabb(cell_size),
		{
			"xz_res": _texture_size,
			"slice_count": _slice_count,
			"capture_size": _capture_size,
			"display_scale": display_scale,
			"vertical_span": _vertical_span,
			"height_span": _height_span,
			"brush_color": brush_paint_color,
			"brush_colors": _brush_voxel_colors,
			"terrain_height": _terrain_height_world,
		},
		{"name": BRUSH_NODE, "fill": 1.0}
	)
	if node == null:
		return
	node.visible = brush_visible
	_add_generated(node)


func _compute_brush_render_colors() -> void:
	var count := _brush_voxel_paint_colors.size()
	_brush_voxel_colors = PackedFloat32Array()
	_brush_voxel_colors.resize(count * 4)
	for i in range(count):
		var c := _brush_voxel_paint_colors[i]
		var complexity := _brush_voxel_paint_complexity[i] if i < _brush_voxel_paint_complexity.size() else 0.0
		var collision := _brush_voxel_paint_collision[i] if i < _brush_voxel_paint_collision.size() else 0.0
		var render_color := Color.WHITE
		match display_channel:
			DisplayChannel.COLOR:
				render_color = Color(c.r, c.g, c.b, clampf(maxf(complexity, 0.35), 0.35, 1.0))
			DisplayChannel.COMPLEXITY:
				render_color = Color(complexity, complexity * 0.7, 0.1, clampf(maxf(complexity, 0.35), 0.35, 1.0))
			DisplayChannel.COLLISION:
				render_color = Color(0.1, collision * 0.8, collision, clampf(maxf(collision, 0.35), 0.35, 1.0))
		_brush_voxel_colors[i * 4 + 0] = render_color.r
		_brush_voxel_colors[i * 4 + 1] = render_color.g
		_brush_voxel_colors[i * 4 + 2] = render_color.b
		_brush_voxel_colors[i * 4 + 3] = render_color.a


func _brush_grid_aabb(cell: float) -> AABB:
	var half := _capture_size * display_scale * 0.5 + cell
	var y_max := (_height_span + _vertical_span) * display_scale + cell
	return AABB(Vector3(-half, -cell, -half), Vector3(2.0 * half, y_max + 2.0 * cell, 2.0 * half))


# ---- Display toggles -------------------------------------------------------

func set_brush_visible(val: bool) -> void:
	brush_visible = val
	var node := get_node_or_null(BRUSH_NODE)
	if node != null:
		node.visible = val


func set_guidance_visible(val: bool) -> void:
	guidance_visible = val
	var node := get_node_or_null(GUIDANCE_NODE)
	if node != null:
		node.visible = val
	elif val:
		if _decoded_occupancy.is_empty():
			_decode_channels()
		build_guidance_voxels()


func switch_channel(channel: int) -> void:
	if display_channel == channel:
		return
	display_channel = channel
	if guidance_visible:
		if _decoded_occupancy.is_empty():
			_decode_channels()
		build_guidance_voxels()
	_rebuild_brush_voxels()


func get_brush_voxel_count() -> int:
	return _brush_voxels.size() / 4


func get_guidance_voxel_count() -> int:
	var g := get_node_or_null(GUIDANCE_NODE) as MultiMeshInstance3D
	if g != null and g.has_meta("visible_voxel_count"):
		return int(g.get_meta("visible_voxel_count", 0))
	if g != null and g.multimesh != null:
		return g.multimesh.instance_count
	return 0


# ---- Coordinate helpers ----------------------------------------------------

func voxel_to_world(x: int, slice_index: int, z: int) -> Vector3:
	var local_y := (float(slice_index) + 0.5) / maxf(float(_slice_count), 1.0) * _vertical_span
	var terrain_y := _height_at_pixel(x, z) * _height_span
	var fx := (float(x) / maxf(float(_texture_size - 1), 1.0) - 0.5) * _capture_size * display_scale
	var fz := (float(z) / maxf(float(_texture_size - 1), 1.0) - 0.5) * _capture_size * display_scale
	return Vector3(fx, (terrain_y + local_y) * display_scale, fz)


func _height_at_pixel(x: int, z: int) -> float:
	if _height_width <= 0 or _height_height <= 0 or _height_luma_bytes.is_empty():
		return 0.0
	var sx := clampi(roundi(float(x) / maxf(float(_texture_size - 1), 1.0) * float(_height_width - 1)), 0, _height_width - 1)
	var sz := clampi(roundi(float(z) / maxf(float(_texture_size - 1), 1.0) * float(_height_height - 1)), 0, _height_height - 1)
	var byte_index := sz * _height_width + sx
	return float(_height_luma_bytes[byte_index]) / 255.0 if byte_index < _height_luma_bytes.size() else 0.0


func paint_at_xy(x: int, z: int) -> bool:
	return _accumulate_brush_extent(Vector2i(x, z))


func get_brush_state() -> Dictionary:
	return {
		"brush_voxel_count": _brush_voxels.size() / 4,
		"texture_size": _texture_size,
		"slice_count": _slice_count,
	}
