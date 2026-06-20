@tool
class_name CommonTargetSVSetup
extends Node

## Preloads TargetSV data from res://assets/target_sv/ at scene init.
## Lives in common_demo_setup.tscn so all demos get TargetSV without
## redundant loader calls or per-scene configuration.

const TargetSVLoaderScript := preload("res://scripts/target_sv_loader.gd")
const TerrainConfigScript := preload("res://scripts/terrain_config.gd")
const ComputeShaderBaseScript := preload("res://scripts/godot_compute_shader_base.gd")

var _ready_ok := false


func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	_ensure_loaded()


func _ensure_loaded() -> void:
	if not Engine.is_editor_hint():
		return
	if _ready_ok:
		return
	var meta := TargetSVLoaderScript.metadata()
	if meta.is_empty():
		push_warning("[CommonTargetSVSetup] TargetSV metadata not found")
		return
	_ready_ok = true
	set_meta("targetsv_texture_size", int(meta.get("texture_size", 256)))
	set_meta("targetsv_slice_count", int(meta.get("slice_count", 16)))
	set_meta("targetsv_voxel_count", int(meta.get("voxel_count", 0)))
	set_meta("targetsv_max_height", float(meta.get("max_height", TerrainConfigScript.MAX_HEIGHT)))
	set_meta("targetsv_capture_size", float(meta.get("capture_size", TerrainConfigScript.CAPTURE_SIZE)))
	set_meta("targetsv_vertical_span", float(meta.get("vertical_span", 32.0)))
	set_meta("targetsv_valid", true)


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
