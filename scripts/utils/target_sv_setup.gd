@tool
class_name TargetSVSetup
extends Node3D

## Preloads TargetSV data from res://assets/target_sv/ at scene init.
## Lives in utils_demo_setup.tscn so all demos get TargetSV without
## redundant loader calls or per-scene configuration.

const TargetSVLoaderScript := preload("res://scripts/target_sv_loader.gd")
const TerrainConfigScript := preload("res://scripts/terrain_config.gd")
const TerrainInitializerScript := preload("res://scripts/terrain_initializer.gd")
const ComputeShaderBaseScript := preload("res://scripts/godot_compute_shader_base.gd")
const VoxelDisplayScript := preload("res://scripts/utils/voxel_display.gd")

const DisplayChannelUtils := preload("res://scripts/utils/display_channel_utils.gd")

const DISPLAY_NODE := "TargetSVVoxels"
const GENERATED_GROUP := "meshfill_targetsv_generated"

@export_group("Display")
@export var display_visible: bool = true
@export_enum("Color", "Complexity", "Collision") var display_channel: int = DisplayChannelUtils.CHANNEL_COLOR
@export_range(0.0, 1.0, 0.001) var occupancy_threshold: float = 0.001
@export var display_scale: float = 1.0
@export var fresnel_enabled: bool = true

var _ready_ok := false
var _metadata: Dictionary = {}
var _visual_bytes := PackedByteArray()
var _collision_bytes := PackedByteArray()
var _texture_size := 0
var _slice_count := 0
var _voxel_count := 0
var _capture_size := 0.0
var _vertical_span := 0.0
var _height_span := 0.0
var _occupancy := PackedFloat32Array()
var _collision := PackedFloat32Array()
var _color_rgba := PackedFloat32Array()
var _terrain_height := PackedFloat32Array()
var _active_voxel_count := 0
var _last_display_reason := ""


func _ready() -> void:
	rebuild.call_deferred()


func rebuild() -> void:
	_ensure_loaded()
	rebuild_display()


func _ensure_loaded() -> void:
	if _ready_ok:
		return
	TargetSVLoaderScript.reload()
	_metadata = TargetSVLoaderScript.metadata()
	_visual_bytes = TargetSVLoaderScript.visual_bytes()
	_collision_bytes = TargetSVLoaderScript.collision_bytes()
	if _metadata.is_empty():
		push_warning("[TargetSVSetup] TargetSV metadata not found")
		return
	_texture_size = int(_metadata.get("texture_size", 256))
	_slice_count = int(_metadata.get("slice_count", 16))
	_voxel_count = int(_metadata.get("voxel_count", _texture_size * _texture_size * _slice_count))
	_capture_size = float(_metadata.get("capture_size", TerrainConfigScript.CAPTURE_SIZE))
	_vertical_span = float(_metadata.get("vertical_span", 32.0))
	_height_span = float(_metadata.get("max_height", TerrainConfigScript.MAX_HEIGHT))
	_ready_ok = true
	set_meta("targetsv_texture_size", _texture_size)
	set_meta("targetsv_slice_count", _slice_count)
	set_meta("targetsv_voxel_count", _voxel_count)
	set_meta("targetsv_max_height", _height_span)
	set_meta("targetsv_capture_size", _capture_size)
	set_meta("targetsv_vertical_span", _vertical_span)
	set_meta("targetsv_valid", true)


func rebuild_display() -> void:
	_ensure_loaded()
	_clear_display()
	if not _ready_ok or not display_visible:
		return
	if not _prepare_display_fields():
		push_warning("[TargetSVSetup] TargetSV display skipped: %s" % _last_display_reason)
		return

	var node := _build_field_display()
	if node == null:
		push_warning("[TargetSVSetup] TargetSV display skipped: %s" % _last_display_reason)
		return
	node.visible = display_visible
	node.add_to_group(GENERATED_GROUP)
	add_child(node)


func _clear_display() -> void:
	for child in get_children():
		if child.is_in_group(GENERATED_GROUP) or child.name == DISPLAY_NODE:
			remove_child(child)
			child.free()


func _prepare_display_fields() -> bool:
	if _voxel_count <= 0:
		_last_display_reason = "empty_voxel_count"
		return false
	var decoded := TargetSVLoaderScript.decode()
	if not bool(decoded.get("valid", false)):
		_last_display_reason = str(decoded.get("reason", "target_decode_failed"))
		return false

	var target_color: PackedColorArray = decoded.get("target_color", PackedColorArray())
	var target_collision: PackedFloat32Array = decoded.get("target_collision", PackedFloat32Array())
	var target_completely: PackedFloat32Array = decoded.get("target_completely", PackedFloat32Array())
	if target_color.size() < _voxel_count or target_completely.size() < _voxel_count:
		_last_display_reason = "target_decode_size_mismatch"
		return false

	_color_rgba = PackedFloat32Array()
	_color_rgba.resize(_voxel_count * 4)
	for i in range(_voxel_count):
		var c := target_color[i] if i < target_color.size() else Color(0.0, 0.0, 0.0, 0.0)
		var color_base := i * 4
		_color_rgba[color_base + 0] = clampf(c.r, 0.0, 1.0)
		_color_rgba[color_base + 1] = clampf(c.g, 0.0, 1.0)
		_color_rgba[color_base + 2] = clampf(c.b, 0.0, 1.0)
		_color_rgba[color_base + 3] = clampf(c.a, 0.0, 1.0)

	_collision = PackedFloat32Array()
	_collision.resize(_voxel_count)
	for i in range(_voxel_count):
		_collision[i] = clampf(target_collision[i], 0.0, 1.0) if i < target_collision.size() else 0.0

	_occupancy = PackedFloat32Array()
	_occupancy.resize(_voxel_count)
	_active_voxel_count = 0
	for i in range(_voxel_count):
		var color_base := i * 4
		var complexity := clampf(_color_rgba[color_base + 3], 0.0, 1.0)
		var collision := clampf(_collision[i], 0.0, 1.0)
		_color_rgba[color_base + 3] = complexity
		_collision[i] = collision
		_occupancy[i] = clampf(target_completely[i], 0.0, 1.0) if i < target_completely.size() else maxf(complexity, collision)
		if _occupancy[i] > occupancy_threshold:
			_active_voxel_count += 1

	var terrain := TerrainInitializerScript.find_edit_time_terrain(self) as MeshInstance3D
	_terrain_height = TerrainInitializerScript.terrain_height_field_from_mesh(terrain, _texture_size, _height_span)
	_last_display_reason = "ok"
	return true


func _build_field_display() -> MultiMeshInstance3D:
	if RenderingServer.get_rendering_device() == null:
		_last_display_reason = "missing_rendering_device"
		return null
	var cell_size := _capture_size / maxf(float(_texture_size - 1), 1.0) * display_scale * 0.72
	var slice_height := _vertical_span / maxf(float(_slice_count), 1.0) * display_scale * 0.72
	var cell := Vector3(cell_size, maxf(slice_height, 0.02), cell_size)
	var half := _capture_size * display_scale * 0.5 + cell_size
	var y_max := (_height_span + _vertical_span) * display_scale + cell_size
	var aabb := AABB(Vector3(-half, -cell_size, -half), Vector3(2.0 * half, y_max + 2.0 * cell_size, 2.0 * half))
	var instance := VoxelDisplayScript.build_field_gpu(
		_voxel_count,
		cell,
		aabb,
		{
			"occupancy": _occupancy,
			"collision": _collision,
			"color_rgba": _color_rgba,
			"terrain_height": _terrain_height,
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
		{
			"name": DISPLAY_NODE,
			"fill": 1.0,
		}
	)
	if instance != null and fresnel_enabled:
		_apply_fresnel_material(instance)
	if instance != null:
		_last_display_reason = str(instance.get_meta("voxel_display_reason", "ok"))
	else:
		_last_display_reason = "field_display_build_failed" if _active_voxel_count > 0 else "no_visible_voxels"
	return instance


func _apply_fresnel_material(instance: MultiMeshInstance3D) -> void:
	if instance == null:
		return
	instance.material_override = DisplayChannelUtils.create_fresnel_rim_material()


func set_display_visible(val: bool) -> void:
	display_visible = val
	var node := get_node_or_null(DISPLAY_NODE)
	if node != null:
		node.visible = val
	elif val:
		rebuild_display()


func is_display_visible() -> bool:
	var node := get_node_or_null(DISPLAY_NODE)
	return display_visible and (node == null or node.visible)


func switch_display_channel(channel: int) -> void:
	var next := clampi(channel, DisplayChannelUtils.CHANNEL_COLOR, DisplayChannelUtils.CHANNEL_COLLISION)
	if display_channel == next and get_node_or_null(DISPLAY_NODE) != null:
		return
	display_channel = next
	rebuild_display()


func switch_channel(channel: int) -> void:
	switch_display_channel(channel)


func get_display_voxel_count() -> int:
	return _active_voxel_count


func get_last_display_reason() -> String:
	return _last_display_reason


func voxel_to_world(x: int, slice_index: int, z: int) -> Vector3:
	var local_y := (float(slice_index) + 0.5) / maxf(float(_slice_count), 1.0) * _vertical_span
	var height_idx := z * _texture_size + x
	var terrain_y := _terrain_height[height_idx] if height_idx >= 0 and height_idx < _terrain_height.size() else 0.0
	var fx := (float(x) / maxf(float(_texture_size - 1), 1.0) - 0.5) * _capture_size * display_scale
	var fz := (float(z) / maxf(float(_texture_size - 1), 1.0) - 0.5) * _capture_size * display_scale
	return Vector3(fx, (terrain_y + local_y) * display_scale, fz)


func is_targetsv_ready() -> bool:
	_ensure_loaded()
	return _ready_ok


func get_visual_bytes() -> PackedByteArray:
	_ensure_loaded()
	return TargetSVLoaderScript.visual_bytes()


func get_collision_bytes() -> PackedByteArray:
	_ensure_loaded()
	return TargetSVLoaderScript.collision_bytes()


func get_metadata() -> Dictionary:
	_ensure_loaded()
	return TargetSVLoaderScript.metadata()


func get_preview_image() -> Image:
	_ensure_loaded()
	return TargetSVLoaderScript.preview_image()


func decode_gpu() -> Dictionary:
	_ensure_loaded()
	return TargetSVLoaderScript.decode()


func upload_to_gpu(compute_base, scope: String = ComputeShaderBaseScript.SCOPE_FRAME) -> Dictionary:
	_ensure_loaded()
	return TargetSVLoaderScript.upload_to_gpu(compute_base, scope)
