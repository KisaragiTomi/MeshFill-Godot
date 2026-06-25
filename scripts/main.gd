extends Node3D

const TerrainConfigScript := preload("res://scripts/terrain_config.gd")
const NonHeadlessSceneGuardScript := preload("res://scripts/non_headless_scene_guard.gd")
const CommonVoxelSpaceScript := preload("res://scripts/common_voxel_space.gd")

@export var num_iterations: int = 10
@export var capture_size: float = TerrainConfigScript.CAPTURE_SIZE
@export var max_height: float = TerrainConfigScript.MAX_HEIGHT
@export var generate_threshold: float = 0.5
@export var un_generate_threshold: float = 0.3
@export var fbx_unit_scale: float = 1.0
@export var mesh_height_scale: float = 0.5
@export var cliff_base_rotation: Vector3 = Vector3(-90.0, 0.0, 0.0)
@export var object_mask_path: String = ""
@export var object_overlap: float = 0.0
@export var use_surface_3d_cliff_placement: bool = false
@export var object_asset_dir: String = "res://assets/rocks"
@export var object_asset_paths: Array[String] = []
@export var vegetation_asset_dir: String = "res://assets/vegetation"
@export var vegetation_asset_paths: Array[String] = []
@export var landscape_cliff_slope_start: float = 0.35
@export var landscape_cliff_slope_full: float = 0.8
@export_range(0.1, 8.0, 0.1) var semantic_probe_density: float = 1.0
@export var enable_manual_generation_tools: bool = true

const TEX_RES := TerrainConfigScript.TEXTURE_SIZE
const OBJECT_VISUAL_LAYER := 10
const OBJECT_VOXEL_COLOR := Color(0.55, 0.50, 0.45, 1.0)
const TERRAIN_VOXEL_COLOR := Color(0.45, 0.42, 0.35, 1.0)
const MANUAL_GENERATED_GROUP := "manual_generated"
const MANUAL_OBJECT_GROUP := "manual_objects"
const PlacementFittingGeneratorScript := preload("res://scripts/placement_fitting_generator.gd")
const TerrainInitializerScript := preload("res://scripts/terrain_initializer.gd")
const ComputeShaderBaseScript := preload("res://scripts/godot_compute_shader_base.gd")
const MANUAL_VEGETATION_GROUP := "manual_vegetation"
const TARGET_SV_SLICE_COUNT := 8
const TARGET_SV_VERTICAL_SPAN := 16.0
const TARGET_SV_DIR_NAME := "target_scene_voxel"
const SemanticProbeProfileScript := preload("res://scripts/semantic_probe_profile.gd")
const SceneVoxelCommitterScript := preload("res://scripts/scene_voxel_committer.gd")
const ScenePlacementActorScript := preload("res://scripts/scene_placement_actor.gd")
const SceneVoxelBrushScript := preload("res://scripts/scene_voxel_brush.gd")
const SceneVoxelTargetScript := preload("res://scripts/scene_voxel_target.gd")
const TARGET_SV_GENERATOR_PATH := "res://scripts/target_scene_voxel_generator.gd"

var _raw_target_height_image: Image
var _raw_current_height_image: Image
var _debug_terrain: MeshInstance3D
var _debug_diff_terrain: MeshInstance3D
var _debug_showing: bool = false
var _debug_diff_showing: bool = false
var _overlap_label: Label
var _probe_density_label: Label
var _probe_debug_label: Label
var _debounce_timer: Timer
var _step_count: int = 0
var _cached_textures: Dictionary = {}
var _cached_cliff_meshes: Array[Mesh] = []
var _cached_assets: Array[AutoObject] = []

var _override_delta: Image
var _override_mask: Image
var _dep_terrain: Image
var _dep_object: Image
var _current_object_mask_img: Image
var _object_override_delta: Image
var _object_override_mask: Image
var _tile_refresh_mode: bool = false
const TILE_SIZE := 32
var _undo_stack: Array[Dictionary] = []
const UNDO_MAX_STEPS := 3
const BRUSH_TARGET_HEIGHT := 0
const BRUSH_TARGET_OBJECT := 1
var _brush_target: int = BRUSH_TARGET_HEIGHT
var _brush_active: bool = false
var _brush_radius: int = 10
var _brush_width: int = 21
var _brush_length: int = 21
var _brush_height: int = 1
var _brush_strength: float = 3.0
var _painting: bool = false
var _paint_positive: bool = true
var _brush_dirty_rect: Rect2i = Rect2i()
var _brush_stroke_changed: bool = false
var _brush_voxel_commit_pending: bool = false
var _terrain_hit_y: float = 10.0
var _debug_delta_showing: bool = false
var _delta_panel: PanelContainer
var _delta_overlay: TextureRect
var _brush_label: Label
var _brush_width_spin: SpinBox
var _brush_length_spin: SpinBox
var _brush_height_spin: SpinBox

var _autoobject_mask_image: Image
var _vegetation_generated: bool = false
var _debug_mask_terrain: MeshInstance3D
var _debug_probe_root: Node3D
var _scene_voxel_committer
var _scene_placement_actor: ScenePlacementActor
var _autoobject_asset_profile_ids: Array[int] = []
var _voxel_write_specs: Dictionary = {}
var _target_sv_preview_image: Image
var _target_sv_visual_bytes: PackedByteArray
var _target_sv_collision_bytes: PackedByteArray
var _target_sv_target_completely_bytes: PackedByteArray
var _target_sv_target_color_rgba8_bytes: PackedByteArray
var _target_sv_metadata: Dictionary = {}
var _target_sv_b_preview_image: Image
var _target_sv_b_visual_bytes: PackedByteArray
var _target_sv_b_collision_bytes: PackedByteArray
var _target_sv_b_target_completely_bytes: PackedByteArray
var _target_sv_b_target_color_rgba8_bytes: PackedByteArray
var _target_sv_b_metadata: Dictionary = {}
var _target_sv_debug_terrain: MeshInstance3D
var _target_sv_debug_showing: bool = false
var _probe_inspect_mode: bool = false


func _get_level_root() -> Node:
	var parent := get_parent()
	return parent if parent != null else self


func _get_level_children() -> Array[Node]:
	var children: Array[Node] = []
	for child in _get_level_root().get_children():
		children.append(child)
	return children


func _exit_tree() -> void:
	_dispose_scene_placement_actor(false)


func _ensure_scene_placement_actor() -> bool:
	if _scene_placement_actor != null and _scene_placement_actor.is_initialized():
		if _scene_voxel_committer != null and _scene_placement_actor.get_sv_committer() != _scene_voxel_committer:
			_scene_placement_actor.attach_sv_committer(_scene_voxel_committer)
		return true
	if _scene_voxel_committer == null:
		_ensure_scene_voxel_committer()
	if _scene_placement_actor == null:
		_scene_placement_actor = ScenePlacementActorScript.new()
	if not _scene_placement_actor.initialize(true, true, _scene_voxel_committer):
		push_warning("[MeshFill] ScenePlacementActor unavailable; AutoObject registry sync skipped")
		return false
	return true


func _dispose_scene_placement_actor(sync_before_free: bool = false) -> void:
	if _scene_placement_actor != null:
		_scene_placement_actor.dispose(sync_before_free)
		_scene_placement_actor = null
	_autoobject_asset_profile_ids.clear()


func _sync_autoobject_assets_with_spa(assets: Array[AutoObject]) -> bool:
	_autoobject_asset_profile_ids.clear()
	if assets.is_empty():
		return false
	if not _ensure_scene_placement_actor():
		return false
	if not _scene_placement_actor.replace_all_autoobject_assets(assets):
		_autoobject_asset_profile_ids = _scene_placement_actor.get_registered_profile_ids()
		push_warning("[MeshFill] ScenePlacementActor AutoObject asset sync was incomplete")
		return false
	_autoobject_asset_profile_ids = _scene_placement_actor.get_registered_profile_ids()
	return _autoobject_asset_profile_ids.size() == assets.size()


func _ensure_autoobject_assets_registered() -> bool:
	if _cached_assets.is_empty():
		return false
	if _scene_placement_actor == null or not _scene_placement_actor.is_initialized():
		return _sync_autoobject_assets_with_spa(_cached_assets)
	if _scene_placement_actor.get_asset_count() != _cached_assets.size():
		return _sync_autoobject_assets_with_spa(_cached_assets)
	return true


func _own_autoobject_with_spa(autoobject_ref: AutoObject, asset_id: int = -1) -> void:
	if autoobject_ref == null:
		return
	if _ensure_scene_placement_actor():
		_scene_placement_actor.own_autoobject(autoobject_ref, asset_id)


func _ready() -> void:
	if NonHeadlessSceneGuardScript.reject_scene_launch_if_headless(get_tree()):
		return
	call_deferred("_initialize_scene")


func _initialize_scene() -> void:
	_cached_textures = _load_terrain_textures()
	if _cached_textures.is_empty():
		push_error("[MeshFill] Fatal: failed to obtain terrain textures")
		return
	_load_cliff_data(_cached_cliff_meshes, _cached_assets)
	if _cached_assets.is_empty():
		push_error("[MeshFill] Fatal: no cliff assets available")
		return
	_apply_semantic_probe_density_to_assets()
	_sync_autoobject_assets_with_spa(_cached_assets)

	_terrain_hit_y = _compute_terrain_avg_height(_cached_textures["target_height"])
	_init_override_images()
	_setup_delta_overlay_ui()

	_clear_object_mask()
	_reuse_or_create_terrain_mesh(_cached_textures["target_height"])
	_load_persisted_target_scene_voxel()
	print("[MeshFill] Ready. Tools: C=object step G/H=debug J=TargetSV_B Ctrl+J=recompute TargetSV/TargetSV_B V=delta B=brush N=target T=tile M=mask Ctrl+Z=undo")


func _save_viewport_screenshot() -> void:
	var img := get_viewport().get_texture().get_image()
	var path := "%s/screenshot_%d.png" % [OS.get_user_data_dir(), Time.get_unix_time_from_system()]
	img.save_png(path)
	print("[MeshFill] Screenshot saved: %s" % path)


func _input(event: InputEvent) -> void:
	if _probe_inspect_mode:
		if event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
				_probe_inspect_at_screen(mb.position)
				get_viewport().set_input_as_handled()
		return
	if _tile_refresh_mode:
		if event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
				_tile_refresh_at_screen(mb.position)
				get_viewport().set_input_as_handled()
		return
	if not _brush_active:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_paint_positive = true
			if mb.pressed:
				_begin_brush_stroke()
				_painting = true
				_push_undo_snapshot()
				_paint_at_screen(mb.position)
			elif _painting:
				_painting = false
				_finish_brush_stroke()
			else:
				_painting = false
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			_paint_positive = false
			if mb.pressed:
				_begin_brush_stroke()
				_painting = true
				_push_undo_snapshot()
				_paint_at_screen(mb.position)
			elif _painting:
				_painting = false
				_finish_brush_stroke()
			else:
				_painting = false
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			if mb.shift_pressed:
				_nudge_brush_footprint(4)
			else:
				_brush_strength = minf(_brush_strength + 0.5, 20.0)
			_update_brush_label()
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			if mb.shift_pressed:
				_nudge_brush_footprint(-4)
			else:
				_brush_strength = maxf(0.5, _brush_strength - 0.5)
			_update_brush_label()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _painting:
		_paint_at_screen((event as InputEventMouseMotion).position)
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var ke := event as InputEventKey
		if ke.pressed and enable_manual_generation_tools and ke.keycode == KEY_C:
			_step_generate()
		elif ke.pressed and ke.keycode == KEY_J and ke.ctrl_pressed:
			_recompute_and_save_target_scene_voxel()
			get_viewport().set_input_as_handled()
		elif ke.pressed and ke.keycode == KEY_J:
			_toggle_target_scene_voxel_overlay()
			get_viewport().set_input_as_handled()
		elif ke.pressed and ke.keycode == KEY_G:
			_toggle_debug_overlay()
		elif ke.pressed and ke.keycode == KEY_H:
			_toggle_diff_overlay()
		elif ke.pressed and ke.keycode == KEY_V:
			_toggle_delta_overlay()
		elif ke.pressed and ke.keycode == KEY_B:
			_toggle_brush_mode()
		elif ke.pressed and ke.keycode == KEY_T:
			_toggle_tile_refresh_mode()
		elif ke.pressed and ke.keycode == KEY_I:
			_toggle_probe_inspect_mode()
		elif ke.pressed and ke.keycode == KEY_N:
			_cycle_brush_target()
		elif ke.pressed and ke.keycode == KEY_Z and ke.ctrl_pressed:
			_undo_override()
		elif ke.pressed and ke.keycode == KEY_M:
			_toggle_mask_overlay()
		elif ke.pressed and ke.keycode == KEY_F12:
			_save_viewport_screenshot()


func _world_to_texture_pixel(world_pos: Vector3, resolution: int = TEX_RES) -> Vector2i:
	return CommonVoxelSpaceScript.world_to_texture_pixel(world_pos, capture_size, resolution)


func _vector3_from_record_value(value, fallback: Vector3) -> Vector3:
	if value is Vector3:
		return value as Vector3
	if value is Array:
		var arr := value as Array
		if arr.size() >= 3:
			return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
	if value is Dictionary:
		var dict := value as Dictionary
		return Vector3(
			float(dict.get("x", fallback.x)),
			float(dict.get("y", fallback.y)),
			float(dict.get("z", fallback.z))
		)
	return fallback


func _normalize_rotation_record(mi: MeshInstance3D, rec: Dictionary) -> void:
	var mode := str(rec.get("rotation_mode", ""))
	if mode.is_empty():
		mode = "XYZ" if rec.has("rotation_degrees") else "Y"
	mode = mode.to_upper()
	if mode != "XYZ":
		mode = "Y"

	var rotation_value := mi.rotation_degrees
	if rec.has("rotation_degrees"):
		rotation_value = _vector3_from_record_value(rec.rotation_degrees, rotation_value)

	if mode == "Y":
		rotation_value = Vector3(0.0, rotation_value.y, 0.0)

	rec["rotation_mode"] = mode
	rec["rotation_degrees"] = rotation_value


func _mark_manual_generation_record(record: Dictionary, kind: String) -> Dictionary:
	var next_record := record.duplicate(true)
	next_record["generated_by_tool"] = true
	next_record["generation_tool_kind"] = kind
	next_record["generation_tool_reason"] = "manual_generation_tool"
	return next_record


func _mark_manual_generated(node: Node, kind: String) -> void:
	if node == null:
		return
	node.set_meta("generated_by_tool", true)
	node.set_meta("generation_tool_kind", kind)
	node.set_meta("generation_tool_reason", "manual_generation_tool")
	node.add_to_group(MANUAL_GENERATED_GROUP)
	if kind == "rock":
		node.add_to_group(MANUAL_OBJECT_GROUP)
	elif kind == "vegetation":
		node.add_to_group(MANUAL_VEGETATION_GROUP)


func _instantiate_object_asset(asset: AutoObject) -> AutoObject:
	if asset == null:
		return AutoObject.new()
	var duplicate_node := asset.duplicate()
	if duplicate_node is AutoObject:
		var duplicated_rock := duplicate_node as AutoObject
		duplicated_rock.name = ""
		duplicated_rock.auto_id = ""
		duplicated_rock.voxel_write_spec = {}
		duplicated_rock.instance_id = 0
		return duplicated_rock
	if duplicate_node != null:
		duplicate_node.free()

	var script = asset.get_script()
	if script != null:
		var scripted = script.new()
		if scripted is AutoObject:
			return scripted as AutoObject
	return AutoObject.new()


func _mesh_bound_min_length(mi: MeshInstance3D) -> float:
	if mi == null or mi.mesh == null:
		return 0.0
	var aabb := mi.mesh.get_aabb()
	var world_size := Vector3(
		absf(aabb.size.x * mi.scale.x),
		absf(aabb.size.y * mi.scale.y),
		absf(aabb.size.z * mi.scale.z)
	)
	var result := INF
	for axis_length in [world_size.x, world_size.y, world_size.z]:
		var length_value := float(axis_length)
		if length_value > 0.0001:
			result = minf(result, length_value)
	return 0.0 if result == INF else result


func _get_voxel_write_spec_from_meta(node: Node) -> Dictionary:
	for key in AutoObject.voxel_write_spec_meta_keys():
		if not node.has_meta(key):
			continue
		var raw_record = node.get_meta(key)
		if raw_record is Dictionary:
			return (raw_record as Dictionary).duplicate(true)
	return {}


func _get_voxel_write_spec_from_config(config: Dictionary) -> Dictionary:
	for key in AutoObject.voxel_write_spec_meta_keys():
		var raw_record = config.get(key, {})
		if raw_record is Dictionary:
			var record := raw_record as Dictionary
			if not record.is_empty():
				return record.duplicate(true)
	return {}


func _attach_voxel_write_spec(mi: MeshInstance3D, record: Dictionary) -> Dictionary:
	var rec: Dictionary = record.duplicate(true)
	var record_id := str(rec.get("id", mi.name))
	var color: Color = rec.get("color", Color.WHITE)
	var complexity := clampf(float(rec.get("complexity", color.a)), 0.0, 1.0)
	color.a = complexity
	var mesh_instance_id := int(mi.get_instance_id())
	var bound_min_length := _mesh_bound_min_length(mi)
	var min_spacing_auto := bool(rec.get("min_spacing_auto", true))
	var min_spacing := maxf(float(rec.get("min_spacing", 0.0)), 0.0)
	var source_voxel_type := str(rec.get("source_voxel_type", "AutoSceneVoxel"))

	rec["id"] = record_id
	rec["mesh_name"] = mi.name
	rec["position"] = mi.position
	rec["scale"] = mi.scale
	_normalize_rotation_record(mi, rec)
	rec["color"] = color
	rec["complexity"] = complexity
	rec["source_voxel_type"] = source_voxel_type
	if SceneVoxelBrushScript.is_brush_type(source_voxel_type) and not rec.has("auto_mix"):
		rec["auto_mix"] = 0.0
	if SceneVoxelTargetScript.is_target_type(source_voxel_type):
		if not rec.has("target_mix"):
			rec["target_mix"] = 1.0
		if not rec.has("target_pipeline"):
			rec["target_pipeline"] = "guidance"
		rec["target_guidance_only"] = true
		rec["height_buffer_applied"] = false
		rec["collision_buffer_applied"] = false
	if mi is AutoObject:
		var auto_object := mi as AutoObject
		auto_object.refresh_bound_spacing()
		bound_min_length = auto_object.bound_min_length
		if min_spacing <= 0.0:
			min_spacing = auto_object.min_spacing
			min_spacing_auto = auto_object.min_spacing_auto
		var auto_instance_id := auto_object.refresh_instance_id()
		var auto_id := auto_object.auto_id if not auto_object.auto_id.is_empty() else record_id
		rec["instance_id"] = auto_instance_id
		rec["auto_instance_id"] = auto_instance_id
		rec["auto_id"] = auto_id
		rec["auto_object_id"] = auto_id
		if not rec.has("auto_source"):
			rec["auto_source"] = auto_object.get_record_auto_source("generated")
		var auto_collision := auto_object.get_collision(bound_min_length)
		if not rec.has("collision") and not auto_collision.is_empty():
			rec["collision"] = auto_collision.duplicate(true)
		if not rec.has("semantic_probe_density"):
			rec["semantic_probe_density"] = auto_object.semantic_probe_density
		var semantic_probes := auto_object.get_semantic_probes(auto_object.semantic_probe_density)
		if not rec.has("semantic_probes") and not semantic_probes.is_empty():
			rec["semantic_probes"] = semantic_probes
	else:
		rec["instance_id"] = mesh_instance_id
		rec["auto_instance_id"] = int(rec.get("auto_instance_id", 0))
		rec["auto_id"] = str(rec.get("auto_id", rec.get("auto_object_id", "")))
		rec["auto_object_id"] = str(rec.get("auto_object_id", rec.get("auto_id", "")))
	rec["instance_mesh_id"] = mesh_instance_id
	rec["mesh_instance_id"] = mesh_instance_id
	if min_spacing <= 0.0:
		min_spacing = bound_min_length * 0.5
	rec["bound_min_length"] = bound_min_length
	rec["min_spacing"] = min_spacing
	rec["min_spacing_auto"] = min_spacing_auto
	if not rec.has("base_pixel"):
		rec["base_pixel"] = _world_to_texture_pixel(mi.position)
	if not rec.has("voxel_xz"):
		rec["voxel_xz"] = rec.base_pixel
	if not rec.has("volume_xz_resolution"):
		rec["volume_xz_resolution"] = TEX_RES
	if mi.is_inside_tree():
		rec["node_path"] = str(mi.get_path())

	if mi is AutoObject:
		(mi as AutoObject).set_voxel_write_spec(rec)
	else:
		mi.set_meta(AutoObject.VOXEL_WRITE_SPEC_META_KEY, rec)
		mi.set_meta("instance_id", rec.instance_id)
		mi.set_meta("instance_mesh_id", rec.instance_mesh_id)
	_voxel_write_specs[record_id] = rec
	return rec


func get_voxel_write_specs() -> Dictionary:
	return _voxel_write_specs.duplicate(true)


func get_voxel_write_spec(record_id: String) -> Dictionary:
	var record = _voxel_write_specs.get(record_id, {})
	if record is Dictionary:
		var typed_record := record as Dictionary
		return typed_record.duplicate(true)
	return {}


func _remove_voxel_write_spec(node: Node) -> void:
	var record := _get_voxel_write_spec_from_meta(node)
	if record.has("id"):
		_voxel_write_specs.erase(str(record.id))


func _generate_cliff_placements(generator: Node, num_iters: int) -> Array[Dictionary]:
	if generator == null:
		return []
	if use_surface_3d_cliff_placement:
		return generator.generate_surface_placement(num_iters)
	return generator.generate_heightfield_fit(num_iters)


func _try_generate_cliff_placements_with_spa(name_prefix: String) -> bool:
	if not _ensure_autoobject_assets_registered():
		return false
	if not _ensure_scene_placement_actor():
		return false
	if _scene_voxel_committer == null:
		_ensure_scene_voxel_committer()
	if _scene_voxel_committer == null:
		return false

	_rebuild_scene_voxel_committer_from_scene_records()
	var sv: Dictionary = _scene_voxel_committer.get_sv()
	if sv.is_empty():
		push_warning("[MeshFill] SPA placement skipped: SceneVoxel data is empty")
		return false

	if _target_sv_b_target_color_rgba8_bytes.is_empty():
		_load_persisted_target_scene_voxel()
	var common := _spa_placement_common_settings(name_prefix, sv)
	var t0 := Time.get_ticks_msec()
	var result := _scene_placement_actor.run_placement_pipeline(sv, [], 4, common)
	var elapsed := Time.get_ticks_msec() - t0
	if not bool(result.get("ok", false)):
		push_warning("[MeshFill] SPA placement blocked during %s: %s" % [
			str(result.get("phase", "pipeline")),
			str(result.get("reason", "unknown")),
		])
		return false

	var placement_result: Dictionary = result.get("placement_result", {})
	var placed_count := int(placement_result.get("total_placed", 0))
	var visual_count := _instantiate_spa_placement_visuals(placement_result, name_prefix)
	_sync_scene_voxel_write_specs_from_committer()
	_sync_autoobject_mask_from_committer()
	if _debug_mask_terrain != null:
		var was_visible := _debug_mask_terrain.visible
		_build_debug_mask_terrain()
		if _debug_mask_terrain != null:
			_debug_mask_terrain.visible = was_visible
	_save_combined_mask_debug()
	print("[MeshFill] SPA placement: %d accepted, %d visual nodes in %dms" % [placed_count, visual_count, elapsed])
	return true


func _spa_placement_common_settings(name_prefix: String, sv: Dictionary) -> Dictionary:
	var target_color := _target_sv_b_target_color_rgba8_bytes
	if target_color.is_empty():
		target_color = _target_sv_target_color_rgba8_bytes
	var target_completely := _target_sv_b_target_completely_bytes
	if target_completely.is_empty():
		target_completely = _target_sv_target_completely_bytes
	var grid_size: Vector3i = sv.get("grid_size", Vector3i(TEX_RES, 1, TEX_RES))
	return {
		"global_quota": maxi(num_iterations, 0),
		"result_capacity": maxi(num_iterations, 1),
		"target_color_rgba8_bytes": target_color,
		"target_completely_bytes": target_completely,
		"use_resident_target_read_buffer_handoff": true,
		"use_resident_candidate_route_handoff": true,
		"use_gpu_candidate_route_pack": true,
		"write_accepted_placements_to_gpu_runtime": true,
		"read_full_field_outputs": false,
		"debug_read_target_read_buffer_bytes": false,
		"debug_read_candidate_route_cpu_expansion": false,
		"type": "rock",
		"auto_source": "meshfill_spa",
		"source_voxel_type": "AutoSceneVoxel",
		"id_prefix": name_prefix,
		"capture_size": capture_size,
		"volume_xz_resolution": grid_size.x,
	}


func _instantiate_spa_placement_visuals(placement_result: Dictionary, name_prefix: String) -> int:
	var visual_count := 0
	var raw_asset_results: Array = placement_result.get("asset_results", [])
	for raw_asset_result in raw_asset_results:
		if not raw_asset_result is Dictionary:
			continue
		var asset_result := raw_asset_result as Dictionary
		var asset_index := int(asset_result.get("asset_index", -1))
		if asset_index < 0 or asset_index >= _cached_assets.size():
			continue
		var asset := _cached_assets[asset_index]
		var world_results: Array = asset_result.get("world_results", [])
		var result_indices := _spa_visual_result_indices(asset_result, world_results.size())
		for raw_index in result_indices:
			var result_index := int(raw_index)
			if result_index < 0 or result_index >= world_results.size():
				continue
			var raw_world = world_results[result_index]
			if not raw_world is Dictionary:
				continue
			var world_result := raw_world as Dictionary
			var mi := _instantiate_object_asset(asset)
			var result_scale := _vector3_from_record_value(world_result.get("scale", Vector3.ONE), Vector3.ONE)
			var visual_scale := result_scale * fbx_unit_scale * mesh_height_scale
			mi.configure_from_asset(asset, {
				"name": "%s_%d_m%d" % [name_prefix, visual_count, asset_index],
				"position": world_result.get("position", Vector3.ZERO),
				"rotation_mode": str(world_result.get("rotation_mode", "Y")),
				"rotation_degrees": world_result.get("rotation_degrees", Vector3.ZERO),
				"scale": visual_scale,
				"visual_layer": OBJECT_VISUAL_LAYER,
				"mesh_index": asset_index,
				"auto_source": "meshfill_spa",
				"groups": [MANUAL_GENERATED_GROUP, MANUAL_OBJECT_GROUP],
			})
			_get_level_root().add_child(mi)
			_mark_manual_generated(mi, "rock")
			_own_autoobject_with_spa(mi, asset_index)
			var record := _mark_manual_generation_record(
				_make_spa_cliff_voxel_write_spec(mi.name, world_result, mi, asset_index, asset),
				"rock"
			)
			_attach_voxel_write_spec(mi, record)
			if visual_count < 3:
				print("  [SPA %d] pos=%s score=%.3f mesh=%d" % [
					visual_count,
					world_result.get("position", Vector3.ZERO),
					float(world_result.get("score", 0.0)),
					asset_index,
				])
			visual_count += 1
	return visual_count


func _spa_visual_result_indices(asset_result: Dictionary, world_result_count: int) -> Array[int]:
	var indices: Array[int] = []
	var writeback: Dictionary = asset_result.get("gpu_autoobject_runtime_writeback", {})
	var spawned_indices: Array = writeback.get("spawned_result_indices", [])
	if not spawned_indices.is_empty():
		for raw_i in spawned_indices:
			var i := int(raw_i)
			if i >= 0 and i < world_result_count:
				indices.append(i)
		return indices
	var spawned_count := clampi(int(writeback.get("spawned_count", world_result_count)), 0, world_result_count)
	for i in range(spawned_count):
		indices.append(i)
	return indices


func _make_spa_cliff_voxel_write_spec(
	record_id: String,
	world_result: Dictionary,
	mi: MeshInstance3D,
	mesh_index: int,
	asset: AutoObject
) -> Dictionary:
	var mesh_aabb := asset.mesh.get_aabb() if asset != null and asset.mesh != null else AABB()
	var record := _make_cliff_voxel_write_spec(
		record_id,
		{
			"mesh_index": mesh_index,
			"rotation_mode": world_result.get("rotation_mode", "Y"),
			"rotation_degrees": world_result.get("rotation_degrees", Vector3.ZERO),
			"score": float(world_result.get("score", 0.0)),
			"channel": 0,
		},
		mi,
		mesh_aabb,
		asset
	)
	record["auto_source"] = "meshfill_spa"
	record["asset_index"] = mesh_index
	record["score"] = float(world_result.get("score", 0.0))
	record["voxel_origin"] = world_result.get("voxel_origin", Vector3i.ZERO)
	record["rotation_index"] = int(world_result.get("rotation_index", 0))
	record["scale_index"] = int(world_result.get("scale_index", 0))
	for debug_key in ["support_ratio", "solid_collision", "complexity_overlap", "clearance_overlap", "ignored_sample"]:
		if world_result.has(debug_key):
			record[debug_key] = world_result[debug_key]
	return record


func _make_cliff_voxel_write_spec(
	record_id: String,
	r: Dictionary,
	mi: MeshInstance3D,
	mesh_aabb: AABB,
	asset: AutoObject = null
) -> Dictionary:
	var color: Color = asset.get_voxel_color() if asset != null else r.get("color", OBJECT_VOXEL_COLOR)
	var complexity := asset.get_voxel_complexity() if asset != null else clampf(float(r.get("complexity", color.a)), 0.0, 1.0)
	color.a = complexity
	var base_px := _world_to_texture_pixel(mi.position)
	var y_min := mi.position.y + mesh_aabb.position.y * mi.scale.y
	var y_max := mi.position.y + (mesh_aabb.position.y + mesh_aabb.size.y) * mi.scale.y
	if y_max < y_min:
		var tmp := y_min
		y_min = y_max
		y_max = tmp
	var radius := maxf(mesh_aabb.size.x * absf(mi.scale.x), mesh_aabb.size.z * absf(mi.scale.z)) * 0.5
	radius = maxf(radius, CommonVoxelSpaceScript.texture_pixel_size(capture_size, TEX_RES))
	var collision := asset.get_collision(radius) if asset != null else []
	var channel := int(r.get("channel", 0))

	var record := {
		"id": record_id,
		"type": "rock",
		"source_voxel_type": "AutoSceneVoxel",
		"mesh_index": int(r.mesh_index),
		"position": mi.position,
		"rotation_mode": str(r.get("rotation_mode", "Y")),
		"rotation_degrees": r.get("rotation_degrees", Vector3.ZERO),
		"scale": mi.scale,
		"base_pixel": base_px,
		"voxel_xz": base_px,
		"volume_xz_resolution": TEX_RES,
		"color": color,
		"complexity": complexity,
		"collision": collision,
		"channel": channel,
		"radius": radius,
		"y_min": y_min,
		"y_max": y_max,
	}
	return record


func _make_terrain_voxel_write_spec(mi: MeshInstance3D, resolution: int) -> Dictionary:
	var color := TERRAIN_VOXEL_COLOR
	var height_stats := Vector2.ZERO
	if mi.has_meta("terrain_height_stats"):
		height_stats = mi.get_meta("terrain_height_stats")
	var record := {
		"id": "Terrain",
		"type": "terrain",
		"position": mi.position,
		"scale": mi.scale,
		"base_pixel": Vector2i.ZERO,
		"voxel_xz": Vector2i.ZERO,
		"volume_xz_resolution": resolution,
		"color": color,
		"complexity": 1.0,
		"height_min": height_stats.x,
		"height_max": height_stats.y,
		"height_resolution": Vector2i(resolution, resolution),
	}
	return record


func _attach_autoobject_voxel_write_spec(mi: MeshInstance3D, r: Dictionary, apply_to_buffers: bool = true) -> void:
	var record_id := str(r.get("id", mi.name))
	var voxel_write_spec: Dictionary = {}
	if _scene_voxel_committer != null:
		voxel_write_spec = _scene_voxel_committer.get_voxel_write_spec(record_id)
	if voxel_write_spec.is_empty():
		voxel_write_spec = _get_voxel_write_spec_from_config(r)
	if voxel_write_spec.is_empty():
		var color: Color = r.get("color", Color.WHITE)
		var complexity := clampf(float(r.get("complexity", color.a)), 0.0, 1.0)
		color.a = complexity
		var base_px := _world_to_texture_pixel(mi.position)
		var auto_source := str(r.get("auto_source", r.get("placement_source", "scatter"))).to_lower()
		voxel_write_spec = {
			"id": record_id,
			"type": r.get("type", "vegetation"),
			"auto_source": auto_source,
			"source_voxel_type": "BrushSceneVoxel" if auto_source == "brush" else "AutoSceneVoxel",
			"position": mi.position,
			"scale": mi.scale,
			"base_pixel": base_px,
			"voxel_xz": base_px,
			"volume_xz_resolution": TEX_RES,
			"color": color,
			"complexity": complexity,
			"collision": r.get("collision", []),
		}
		if r.has("channel"):
			voxel_write_spec["channel"] = int(r.channel)
			voxel_write_spec["radius"] = float(r.get("radius", 0.0))
			if r.has("y_min"):
				voxel_write_spec["y_min"] = float(r.y_min)
			if r.has("y_max"):
				voxel_write_spec["y_max"] = float(r.y_max)
	var attached := _attach_voxel_write_spec(mi, voxel_write_spec)
	if apply_to_buffers and _scene_voxel_committer != null and _record_should_write_scene_voxel_buffers(attached):
		attached = _scene_voxel_committer.apply_voxel_write_spec(attached)
		attached = _attach_voxel_write_spec(mi, attached)


func register_brush_autoobject(mi: AutoObject, placement_data: Dictionary = {}) -> void:
	if mi == null:
		return
	var data := placement_data.duplicate(true)
	var raw_profile = data.get("voxel_profile", null)
	if raw_profile is AutoVoxelProfile and mi.voxel_descriptor != null:
		mi.voxel_descriptor.set("voxel_profile", raw_profile)
	if not data.has("id"):
		data["id"] = mi.name
	if not data.has("type"):
		data["type"] = "vegetation"
	data["auto_source"] = "brush"
	data["source_voxel_type"] = "BrushSceneVoxel"
	if not data.has("auto_mix"):
		data["auto_mix"] = 0.0
	data["position"] = mi.position
	data["scale"] = mi.scale
	if not data.has("color"):
		data["color"] = mi.get_voxel_color()
	if not data.has("complexity"):
		data["complexity"] = mi.get_voxel_complexity()
	if not data.has("collision") or not data["collision"] is Array:
		data["collision"] = mi.get_collision()
	if not data.has("channel"):
		data["channel"] = 0
	if not data.has("radius"):
		data["radius"] = 0.2
	if not data.has("brush_size_voxels"):
		data["brush_size_voxels"] = Vector3i(_brush_width, _brush_height, _brush_length)
	if not data.has("slice_indices"):
		data["slice_indices"] = _brush_slice_indices()

	mi.add_to_group("placed_brush_autoobjects")
	if mi.get_parent() == null:
		_get_level_root().add_child(mi)
	_own_autoobject_with_spa(mi, int(data.get("asset_index", -1)))
	var defer_buffer_update := bool(data.get("defer_voxel_update", _painting))
	_attach_autoobject_voxel_write_spec(mi, data, not defer_buffer_update)
	if defer_buffer_update:
		_brush_voxel_commit_pending = true
		var brush_px := _world_to_texture_pixel(mi.position)
		var brush_radius_px := 1
		var pixel_size := CommonVoxelSpaceScript.texture_pixel_size(capture_size, TEX_RES)
		brush_radius_px = maxi(brush_radius_px, ceili(float(maxi(_brush_width, _brush_length)) * 0.5))
		brush_radius_px = maxi(brush_radius_px, ceili(float(data.get("radius", pixel_size)) / pixel_size))
		for collision_raw in data["collision"]:
			if collision_raw is Dictionary:
				var collision := collision_raw as Dictionary
				var radius := maxf(float(collision.get("radius", pixel_size)), 0.0)
				var erosion := maxf(float(collision.get("erosion_radius", 0.0)), 0.0)
				var dilation := maxf(float(collision.get("dilation_radius", 0.0)), 0.0)
				var effective_radius := 0.0 if erosion > 0.0 and radius <= erosion else maxf(radius - erosion, 0.0) + dilation
				brush_radius_px = maxi(brush_radius_px, ceili(effective_radius / pixel_size))
		_merge_dirty_rect(Rect2i(
			Vector2i(brush_px.x - brush_radius_px, brush_px.y - brush_radius_px),
			Vector2i(brush_radius_px * 2 + 1, brush_radius_px * 2 + 1)
		))


func commit_brush_autoobject_edits(dirty_rect: Rect2i = Rect2i()) -> void:
	if dirty_rect.size.x > 0 and dirty_rect.size.y > 0:
		_merge_dirty_rect(dirty_rect)
	_brush_voxel_commit_pending = true
	_finish_brush_stroke()


func _meters_to_pixels(radius_m: float, resolution: int = TEX_RES) -> int:
	return CommonVoxelSpaceScript.world_radius_to_texture_radius(radius_m, capture_size, resolution)


func _make_landscape_cliff_mask(height_img: Image) -> Image:
	var mask := Image.create(TEX_RES, TEX_RES, false, Image.FORMAT_RF)
	mask.fill(Color(0.0, 0.0, 0.0, 0.0))
	if height_img == null:
		return mask
	var gpu_mask := _make_landscape_cliff_mask_gpu(height_img)
	if gpu_mask != null and not gpu_mask.is_empty():
		return gpu_mask
	push_error("[MeshFill] Landscape cliff mask GPU compute failed")
	return mask


func _make_landscape_cliff_mask_gpu(height_img: Image) -> Image:
	if height_img == null or height_img.is_empty():
		return null
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		return null
	probe_rd.free()

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "LandscapeCliffMask"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return null
	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader("res://shaders/landscape_cliff_mask.glsl")
	var pipeline := compute.create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return null

	var sampler := compute.create_linear_sampler()
	var height_tex := compute.upload_texture_2d(
		height_img,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		Image.FORMAT_RF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"landscape_height_r32f"
	)
	var out_tex := compute.create_rw_texture_2d(
		TEX_RES,
		TEX_RES,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"landscape_cliff_mask_r32f"
	)
	if not sampler.is_valid() or not height_tex.is_valid() or not out_tex.is_valid():
		compute.dispose()
		return null

	var set0 := compute.create_uniform_set([
		compute.make_sampler_uniform(0, sampler, height_tex),
	], shader, 0)
	var set1 := compute.create_uniform_set([
		compute.make_image_uniform(0, out_tex),
	], shader, 1)

	var push := PackedByteArray()
	push.resize(32)
	push.encode_s32(0, TEX_RES)
	push.encode_s32(4, TEX_RES)
	push.encode_s32(8, height_img.get_width())
	push.encode_s32(12, height_img.get_height())
	push.encode_float(16, capture_size)
	push.encode_float(20, maxf(landscape_cliff_slope_start, 0.0001))
	push.encode_float(24, maxf(landscape_cliff_slope_full - maxf(landscape_cliff_slope_start, 0.0001), 0.0001))
	push.encode_float(28, 0.0)

	var groups := ceili(float(TEX_RES) / 32.0)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return null
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_bind_uniform_set(cl, set1, 1)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, groups, groups, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var data := rd.texture_get_data(out_tex, 0)
	var result := Image.create_from_data(TEX_RES, TEX_RES, false, Image.FORMAT_RF, data)
	compute.dispose()
	return result


func _sync_scene_voxel_write_specs_from_committer() -> void:
	if _scene_voxel_committer == null:
		return
	for record in _scene_voxel_committer.get_voxel_write_specs():
		var record_id := str(record.get("id", ""))
		if record_id.is_empty() or not _voxel_write_specs.has(record_id):
			continue
		var node_path := str(record.get("node_path", ""))
		var node := get_node_or_null(NodePath(node_path)) if not node_path.is_empty() else null
		if node is MeshInstance3D:
			var mesh_node := node as MeshInstance3D
			_attach_voxel_write_spec(mesh_node, record)
		else:
			_voxel_write_specs[record_id] = record


func _sync_autoobject_mask_from_committer() -> void:
	if _scene_voxel_committer == null:
		return
	var occupancy: Image = _scene_voxel_committer.occupancy
	_autoobject_mask_image = _make_autoobject_activity_mask_from_occupancy(occupancy)


func _make_blank_autoobject_activity_mask() -> Image:
	var mask := Image.create(TEX_RES, TEX_RES, false, Image.FORMAT_RGBAH)
	mask.fill(Color(0.0, 0.0, 0.0, 0.0))
	return mask


func _make_autoobject_activity_mask_from_occupancy(occupancy: Image) -> Image:
	if occupancy == null or occupancy.is_empty():
		return _make_blank_autoobject_activity_mask()
	var gpu_mask := _make_autoobject_activity_mask_gpu(occupancy)
	if gpu_mask != null and not gpu_mask.is_empty():
		return gpu_mask
	push_error("[MeshFill] AutoObject activity mask GPU compute failed")
	return _make_blank_autoobject_activity_mask()


func _make_autoobject_activity_mask_gpu(occupancy: Image) -> Image:
	if occupancy == null or occupancy.is_empty():
		return null
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		return null
	probe_rd.free()

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "AutoObjectActivityMask"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return null
	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader("res://shaders/autoobject_occupancy_mask.glsl")
	var pipeline := compute.create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return null

	var sampler := compute.create_linear_sampler()
	var occupancy_tex := compute.upload_texture_2d(
		occupancy,
		RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
		Image.FORMAT_RGBAH,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"autoobject_occupancy_rgba16f"
	)
	var out_tex := compute.create_rw_texture_2d(
		TEX_RES,
		TEX_RES,
		RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"autoobject_activity_mask_rgba16f"
	)
	if not sampler.is_valid() or not occupancy_tex.is_valid() or not out_tex.is_valid():
		compute.dispose()
		return null

	var set0 := compute.create_uniform_set([
		compute.make_sampler_uniform(0, sampler, occupancy_tex),
	], shader, 0)
	var set1 := compute.create_uniform_set([
		compute.make_image_uniform(0, out_tex),
	], shader, 1)
	if not set0.is_valid() or not set1.is_valid():
		compute.dispose()
		return null

	var push := PackedByteArray()
	push.resize(32)
	push.encode_s32(0, TEX_RES)
	push.encode_s32(4, TEX_RES)
	push.encode_s32(8, occupancy.get_width())
	push.encode_s32(12, occupancy.get_height())
	push.encode_float(16, 0.01)
	push.encode_float(20, 0.0)
	push.encode_float(24, 0.0)
	push.encode_float(28, 0.0)

	var groups := ceili(float(TEX_RES) / 32.0)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return null
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_bind_uniform_set(cl, set1, 1)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, groups, groups, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var data := rd.texture_get_data(out_tex, 0)
	var result := Image.create_from_data(TEX_RES, TEX_RES, false, Image.FORMAT_RGBAH, data)
	compute.dispose()
	return result



func _import_object_mask_to_scene_voxel_committer() -> void:
	if _scene_voxel_committer == null:
		return
	var object_mask_img: Image = null
	if _current_object_mask_img != null:
		object_mask_img = _current_object_mask_img
	else:
		object_mask_img = Image.create(TEX_RES, TEX_RES, false, Image.FORMAT_RF)
		object_mask_img.fill(Color(0.0, 0.0, 0.0, 0.0))

	for channel in range(4):
		_scene_voxel_committer.import_mask_channel(channel, object_mask_img)


func _record_should_write_scene_voxel_buffers(record: Dictionary) -> bool:
	var record_type := str(record.get("type", ""))
	if record_type == "terrain":
		return false
	var source_type := str(record.get("source_voxel_type", ""))
	if SceneVoxelTargetScript.is_target_type(source_type):
		return false
	var ch := int(record.get("channel", -1))
	return ch >= 0 and ch < 4


func _rebuild_scene_voxel_committer_from_scene_records(_dirty_rect: Rect2i = Rect2i()) -> int:
	if _scene_voxel_committer == null:
		_ensure_scene_voxel_committer()
	if _scene_voxel_committer == null:
		return 0

	_scene_voxel_committer.reset_occupancy()
	_import_object_mask_to_scene_voxel_committer()

	var applied := 0
	for record_id in _voxel_write_specs.keys():
		var raw_record = _voxel_write_specs[record_id]
		if not raw_record is Dictionary:
			continue
		var record := raw_record as Dictionary
		if not _record_should_write_scene_voxel_buffers(record):
			continue

		var updated: Dictionary = _scene_voxel_committer.apply_voxel_write_spec(record)
		if updated.is_empty():
			continue
		applied += 1
		var node_path := str(updated.get("node_path", ""))
		var node := get_node_or_null(NodePath(node_path)) if not node_path.is_empty() else null
		if node is MeshInstance3D:
			_attach_voxel_write_spec(node as MeshInstance3D, updated)
		else:
			_voxel_write_specs[record_id] = updated

	_scene_voxel_committer.build_voxel_volume(TEX_RES / 2, _autoobject_channel_profiles())
	_sync_scene_voxel_write_specs_from_committer()
	_sync_autoobject_mask_from_committer()

	if _debug_mask_terrain != null:
		var was_visible := _debug_mask_terrain.visible
		_build_debug_mask_terrain()
		if _debug_mask_terrain != null:
			_debug_mask_terrain.visible = was_visible
	_save_combined_mask_debug()

	return applied


func _step_generate() -> void:
	if _cached_textures.is_empty() or _cached_assets.is_empty():
		push_error("[MeshFill] Cannot step: textures or assets not loaded")
		return
	_ensure_autoobject_assets_registered()

	_step_count += 1
	print("[MeshFill] Step %d" % _step_count)

	_invalidate_overrides()
	var composited_th := _composite_target_height()

	var prev_object_mask := _load_previous_object_mask()
	if _try_generate_cliff_placements_with_spa("Cliff_s%d" % _step_count):
		print("[MeshFill] Step %d complete through ScenePlacementActor. Total cliff meshes: %d." % [
			_step_count,
			get_tree().get_nodes_in_group("placed_objects").size(),
		])
		return

	var generator := PlacementFittingGeneratorScript.new()
	generator.texture_size = TEX_RES
	generator.capture_size = capture_size
	generator.max_height = max_height
	generator.generate_threshold = generate_threshold
	generator.un_generate_threshold = un_generate_threshold
	generator.scene_depth_texture = _cached_textures["scene_depth"]
	generator.scene_normal_texture = _cached_textures["scene_normal"]
	generator.object_depth_texture = _cached_textures["object_depth"]
	generator.object_normal_texture = _cached_textures["object_normal"]
	generator.height_normal_texture = _cached_textures["height_normal"]
	generator.target_height_texture = composited_th
	generator.placed_mask_texture = prev_object_mask
	if _object_override_mask != null:
		generator.placement_override_mask_texture = ImageTexture.create_from_image(_object_override_mask)
	if _object_override_delta != null:
		generator.placement_override_delta_texture = ImageTexture.create_from_image(_object_override_delta)
	generator.stamp_overlap = object_overlap
	generator.fitting_assets = _cached_assets
	add_child(generator)

	var t0 := Time.get_ticks_msec()
	var results := _generate_cliff_placements(generator, num_iterations)
	var elapsed := Time.get_ticks_msec() - t0
	print("[MeshFill] Step %d: %d placements in %dms" % [_step_count, results.size(), elapsed])

	_raw_target_height_image = generator._debug_target_height_image
	_raw_current_height_image = generator._debug_current_height_image

	for i in range(results.size()):
		var r: Dictionary = results[i]
		var mesh_index := int(r.mesh_index)
		var asset := _cached_assets[mesh_index]
		var mi := _instantiate_object_asset(asset)
		var visual_scale: Vector3 = Vector3.ONE * r.scale * fbx_unit_scale * mesh_height_scale
		var mesh_aabb := asset.mesh.get_aabb()
		var mesh_top_y := (mesh_aabb.position.y + mesh_aabb.size.y) * visual_scale.y
		var rock_position: Vector3 = r.position
		rock_position.y -= mesh_top_y
		mi.configure_from_asset(asset, {
			"name": "Cliff_s%d_%d_m%d" % [_step_count, i, mesh_index],
			"position": rock_position,
			"rotation_mode": str(r.get("rotation_mode", "Y")),
			"rotation_degrees": r.get("rotation_degrees", Vector3.ZERO),
			"scale": visual_scale,
			"visual_layer": OBJECT_VISUAL_LAYER,
			"mesh_index": mesh_index,
			"auto_source": "meshfill",
			"groups": [MANUAL_GENERATED_GROUP, MANUAL_OBJECT_GROUP],
		})
		_get_level_root().add_child(mi)
		_mark_manual_generated(mi, "rock")
		_own_autoobject_with_spa(mi, mesh_index)
		var rock_record := _mark_manual_generation_record(_make_cliff_voxel_write_spec(mi.name, r, mi, mesh_aabb, asset), "rock")
		_attach_voxel_write_spec(mi, rock_record)
		if i < 3:
			print("  [%d] pos=%s aabb_top=%.2f offset_y=%.2f" % [i, r.position, mesh_aabb.position.y + mesh_aabb.size.y, mesh_top_y])

	_capture_and_save_object_mask()
	_analyze_height_difference(_cached_textures["scene_depth"])
	_save_height_maps()

	if _debug_terrain != null:
		_debug_terrain.queue_free()
		_debug_terrain = null
	if _debug_diff_terrain != null:
		_debug_diff_terrain.queue_free()
		_debug_diff_terrain = null
	_setup_debug_terrain()

	generator.queue_free()
	print("[MeshFill] Step %d complete. Total cliff meshes: %d. Use C or the UI object button for next step." % [
		_step_count, get_tree().get_nodes_in_group("placed_objects").size()])


func _clear_object_mask() -> void:
	var mask_path := OS.get_user_data_dir() + "/object_placement_mask.png"
	if FileAccess.file_exists(mask_path):
		DirAccess.remove_absolute(mask_path)
		print("[MeshFill] Cleared previous object mask")


func _setup_debug_terrain() -> void:
	if _raw_target_height_image == null or _raw_current_height_image == null:
		return

	var img := _raw_target_height_image
	var mask_img := _raw_current_height_image
	var res := img.get_width()
	var cell_size := capture_size / float(res)
	var half := capture_size / 2.0
	var height_values := _image_rgba32f_values(img)
	var mask_values := _image_rgba32f_values(mask_img)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	for y in range(res):
		for x in range(res):
			var value_index := (y * res + x) * 4
			var h := (height_values[value_index] if value_index < height_values.size() else 0.0) + 0.15
			var gen_mask := mask_values[value_index + 2] if value_index + 2 < mask_values.size() else 0.0
			var alpha := 0.4 if gen_mask > 0.5 else 0.02
			var px := float(x) * cell_size - half
			var pz := float(y) * cell_size - half
			st.set_color(Color(0.2, 0.6, 1.0, alpha))
			st.set_uv(Vector2(float(x) / float(res - 1), float(y) / float(res - 1)))
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
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true

	_debug_terrain = MeshInstance3D.new()
	_debug_terrain.mesh = st.commit()
	_debug_terrain.material_override = mat
	_debug_terrain.name = "DebugTargetHeight"
	_debug_terrain.visible = false
	_get_level_root().add_child(_debug_terrain)
	print("[MeshFill] Debug target height terrain ready [G to toggle]")


func _setup_slider_ui() -> void:
	if not enable_manual_generation_tools:
		return

	var layer := CanvasLayer.new()
	layer.layer = 100
	add_child(layer)

	var panel := PanelContainer.new()
	panel.position = Vector2(10, 10)
	layer.add_child(panel)

	var vbox := VBoxContainer.new()
	panel.add_child(vbox)

	_overlap_label = Label.new()
	_overlap_label.text = "Object Overlap: %.0f%%" % (object_overlap * 100.0)
	vbox.add_child(_overlap_label)

	var overlap_slider := HSlider.new()
	overlap_slider.min_value = 0.0
	overlap_slider.max_value = 1.0
	overlap_slider.step = 0.05
	overlap_slider.value = object_overlap
	overlap_slider.custom_minimum_size = Vector2(300, 20)
	overlap_slider.value_changed.connect(_on_overlap_changed)
	vbox.add_child(overlap_slider)

	_probe_density_label = Label.new()
	_probe_density_label.text = "Semantic Probe Density: %.1fx" % semantic_probe_density
	vbox.add_child(_probe_density_label)

	var probe_slider := HSlider.new()
	probe_slider.min_value = 0.1
	probe_slider.max_value = 8.0
	probe_slider.step = 0.1
	probe_slider.value = semantic_probe_density
	probe_slider.custom_minimum_size = Vector2(300, 20)
	probe_slider.value_changed.connect(_on_probe_density_changed)
	vbox.add_child(probe_slider)

	_probe_debug_label = Label.new()
	_probe_debug_label.text = "Semantic Probes: not shown"
	vbox.add_child(_probe_debug_label)

	var probe_button := Button.new()
	probe_button.text = "Toggle Probe Debug"
	probe_button.pressed.connect(_toggle_semantic_probe_debug)
	vbox.add_child(probe_button)

	var separator := HSeparator.new()
	vbox.add_child(separator)

	# ── Shortcuts Panel ──
	var shortcuts_panel := PanelContainer.new()
	shortcuts_panel.custom_minimum_size = Vector2(320, 0)
	var shortcuts_vbox := VBoxContainer.new()
	shortcuts_vbox.add_theme_constant_override("separation", 0)
	shortcuts_panel.add_child(shortcuts_vbox)

	# Helper to add a shortcut line (key, desc, target_vbox)
	var _sh := func add_shortcut(target_vbox: VBoxContainer, key: String, desc: String):
		var line := HBoxContainer.new()
		var key_label := Label.new()
		key_label.text = "  " + key
		key_label.custom_minimum_size = Vector2(110, 0)
		key_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
		key_label.add_theme_font_size_override("font_size", 12)
		line.add_child(key_label)
		var desc_label := Label.new()
		desc_label.text = desc
		desc_label.add_theme_font_size_override("font_size", 12)
		line.add_child(desc_label)
		target_vbox.add_child(line)

	var section_header := Label.new()
	section_header.text = "-- Overlays --"
	section_header.add_theme_color_override("font_color", Color(0.7, 0.7, 0.9))
	section_header.add_theme_font_size_override("font_size", 13)
	shortcuts_vbox.add_child(section_header)
	_sh.call(shortcuts_vbox, "J", "TargetSV overlay")
	_sh.call(shortcuts_vbox, "M", "Mask overlay")

	section_header = Label.new()
	section_header.text = "-- Editing --"
	section_header.add_theme_color_override("font_color", Color(0.7, 0.7, 0.9))
	section_header.add_theme_font_size_override("font_size", 13)
	shortcuts_vbox.add_child(section_header)
	_sh.call(shortcuts_vbox, "B", "Toggle brush mode")
	_sh.call(shortcuts_vbox, "N", "Cycle brush target")
	_sh.call(shortcuts_vbox, "T", "Toggle tile refresh")
	_sh.call(shortcuts_vbox, "Ctrl+Z", "Undo override")
	_sh.call(shortcuts_vbox, "I", "Probe inspect mode")

	section_header = Label.new()
	section_header.text = "-- Generation --"
	section_header.add_theme_color_override("font_color", Color(0.7, 0.7, 0.9))
	section_header.add_theme_font_size_override("font_size", 13)
	shortcuts_vbox.add_child(section_header)
	_sh.call(shortcuts_vbox, "C", "Object step")

	vbox.add_child(shortcuts_panel)

	var rock_button := Button.new()
	rock_button.text = "C  Generate Object Step"
	rock_button.pressed.connect(_run_manual_object_generation)
	vbox.add_child(rock_button)


func _run_manual_object_generation() -> void:
	if not enable_manual_generation_tools:
		return
	_step_generate()



func _on_overlap_changed(new_val: float) -> void:
	object_overlap = new_val
	_overlap_label.text = "Object Overlap: %.0f%%" % (new_val * 100.0)
	_start_debounce_regen()


func _on_probe_density_changed(new_val: float) -> void:
	semantic_probe_density = clampf(new_val, 0.1, 8.0)
	if _probe_density_label != null:
		_probe_density_label.text = "Semantic Probe Density: %.1fx" % semantic_probe_density
	_apply_semantic_probe_density_to_assets()
	if _debug_probe_root != null and is_instance_valid(_debug_probe_root):
		_refresh_semantic_probe_debug()


func _apply_semantic_probe_density_to_assets() -> void:
	for asset in _cached_assets:
		if asset == null:
			continue
		asset.semantic_probe_density = semantic_probe_density
		asset.rebuild_semantic_probes(semantic_probe_density)
	_update_probe_debug_label()
	if _scene_placement_actor != null:
		_sync_autoobject_assets_with_spa(_cached_assets)


func _toggle_semantic_probe_debug() -> void:
	if _debug_probe_root != null and is_instance_valid(_debug_probe_root):
		_debug_probe_root.queue_free()
		_debug_probe_root = null
		if _probe_debug_label != null:
			_probe_debug_label.text = "Semantic Probes: hidden"
		print("[MeshFill] Semantic probe debug: OFF")
		return
	_debug_probe_root = Node3D.new()
	_debug_probe_root.name = "DebugSemanticProbes"
	_get_level_root().add_child(_debug_probe_root)
	_refresh_semantic_probe_debug()
	print("[MeshFill] Semantic probe debug: ON")


func _refresh_semantic_probe_debug() -> void:
	if _debug_probe_root == null or not is_instance_valid(_debug_probe_root):
		return
	for child in _debug_probe_root.get_children():
		child.queue_free()
	var samples := _collect_semantic_probe_debug_assets(6)
	var total := 0
	var camera := get_viewport().get_camera_3d()
	var center := Vector3(0.0, _terrain_hit_y + 7.0, -4.0)
	var right := Vector3.RIGHT
	if camera != null:
		var camera_basis := camera.global_transform.basis
		center = camera.global_position + (-camera_basis.z.normalized() * 16.0) - (camera_basis.y.normalized() * 1.0)
		right = camera_basis.x.normalized()
	var spacing := 4.0
	var half_width := float(maxi(samples.size() - 1, 0)) * spacing * 0.5
	for i in range(samples.size()):
		var sample: Dictionary = samples[i]
		var probes: Array = sample.get("probes", [])
		var origin := center + right * (float(i) * spacing - half_width)
		var anchor := _make_probe_debug_anchor(origin, sample)
		_debug_probe_root.add_child(anchor)
		var limit := mini(probes.size(), 160)
		var probe_scale := _vector3_from_record_value(sample.get("mesh_scale", Vector3.ONE), Vector3.ONE)
		for j in range(limit):
			var probe: Dictionary = probes[j]
			anchor.add_child(_make_probe_debug_marker(probe, probe_scale))
		total += probes.size()
	if _probe_debug_label != null:
		_probe_debug_label.text = "Semantic Probes: %.1fx, %d assets, %d probes" % [semantic_probe_density, samples.size(), total]
	print("[MeshFill] Semantic probes debug: density=%.1fx assets=%d probes=%d" % [semantic_probe_density, samples.size(), total])


func _collect_semantic_probe_debug_assets(max_assets: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for i in range(_cached_assets.size()):
		if result.size() >= max_assets:
			break
		var asset := _cached_assets[i]
		if asset == null:
			continue
		var probes := asset.rebuild_semantic_probes(semantic_probe_density)
		var probe_mesh := asset.mesh
		var source_mesh := asset.get_source_mesh()
		var debug_scale := _semantic_probe_debug_mesh_scale(probe_mesh, asset.mesh_size)
		var source_mesh_scale := _semantic_probe_debug_mesh_scale(source_mesh, asset.mesh_size)
		result.append({
			"name": asset.asset_id if not asset.asset_id.is_empty() else "rock_%d" % i,
			"mesh": probe_mesh,
			"source_mesh": source_mesh,
			"mesh_scale": Vector3.ONE * debug_scale,
			"source_mesh_scale": Vector3.ONE * source_mesh_scale,
			"color": asset.get_voxel_color(),
			"probes": probes,
		})
	return result


func _semantic_probe_debug_mesh_max_axis(mesh: Mesh) -> float:
	if mesh == null:
		return 0.0
	var aabb := mesh.get_aabb()
	return maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))


func _semantic_probe_debug_mesh_scale(mesh: Mesh, target_size: float) -> float:
	var max_axis := _semantic_probe_debug_mesh_max_axis(mesh)
	if max_axis <= 0.001 or target_size <= 0.001:
		return 1.0
	return target_size / max_axis


func _make_probe_debug_anchor(origin: Vector3, sample: Dictionary) -> Node3D:
	var label_text := str(sample.get("name", "asset"))
	var root := Node3D.new()
	root.name = "ProbeAsset_%s" % label_text
	root.position = origin
	var box := BoxMesh.new()
	box.size = Vector3(0.6, 0.16, 0.6)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 1.0, 0.2, 0.9)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	var marker := MeshInstance3D.new()
	marker.mesh = box
	marker.material_override = mat
	root.add_child(marker)

	var mesh = sample.get("source_mesh", sample.get("mesh", null))
	if mesh is Mesh:
		var mesh_marker := MeshInstance3D.new()
		mesh_marker.name = "SourceMesh"
		mesh_marker.mesh = mesh as Mesh
		mesh_marker.scale = _vector3_from_record_value(sample.get("source_mesh_scale", sample.get("mesh_scale", Vector3.ONE)), Vector3.ONE)
		mesh_marker.material_override = _make_probe_debug_source_mesh_material(sample.get("color", Color(0.55, 0.8, 0.45, 0.45)))
		root.add_child(mesh_marker)

		var convex_shape := (mesh as Mesh).create_convex_shape(true, false)
		if convex_shape != null:
			var convex_wireframe := _make_convex_wireframe_mesh(convex_shape)
			if convex_wireframe != null:
				var convex_marker := MeshInstance3D.new()
				convex_marker.name = "ConvexWireframe"
				convex_marker.mesh = convex_wireframe
				convex_marker.scale = mesh_marker.scale
				convex_marker.material_override = _make_probe_debug_convex_material()
				root.add_child(convex_marker)
	return root


func _make_probe_debug_source_mesh_material(color_value) -> StandardMaterial3D:
	var color := Color(0.55, 0.8, 0.45, 0.45)
	if color_value is Color:
		color = color_value as Color
	color.a = 0.58
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = false
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.emission_enabled = true
	mat.emission = Color(color.r, color.g, color.b, 1.0)
	mat.emission_energy_multiplier = 0.35
	return mat


func _make_probe_debug_convex_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.6, 0.0, 1.0)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = false
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.6, 0.0, 1.0)
	mat.emission_energy_multiplier = 1.5
	return mat


func _make_convex_wireframe_mesh(convex_shape: ConvexPolygonShape3D) -> ImmediateMesh:
	var debug_mesh := convex_shape.get_debug_mesh()
	if debug_mesh == null:
		return null
	var edges := {}
	for si in range(debug_mesh.get_surface_count()):
		var arrays := debug_mesh.surface_get_arrays(si)
		if arrays.is_empty() or arrays[Mesh.ARRAY_VERTEX] == null:
			continue
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		if indices.is_empty():
			for i in range(0, verts.size(), 3):
				if i + 2 >= verts.size():
					break
				_add_edge(edges, verts[i], verts[i + 1])
				_add_edge(edges, verts[i + 1], verts[i + 2])
				_add_edge(edges, verts[i + 2], verts[i])
		else:
			for i in range(0, indices.size(), 3):
				if i + 2 >= indices.size():
					break
				_add_edge(edges, verts[indices[i]], verts[indices[i + 1]])
				_add_edge(edges, verts[indices[i + 1]], verts[indices[i + 2]])
				_add_edge(edges, verts[indices[i + 2]], verts[indices[i]])
	if edges.is_empty():
		return null
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for edge_key in edges:
		var edge: Array = edges[edge_key]
		im.surface_add_vertex(edge[0])
		im.surface_add_vertex(edge[1])
	im.surface_end()
	return im


func _add_edge(edges: Dictionary, a: Vector3, b: Vector3) -> void:
	var ka := "%d,%d,%d" % [roundi(a.x * 100.0), roundi(a.y * 100.0), roundi(a.z * 100.0)]
	var kb := "%d,%d,%d" % [roundi(b.x * 100.0), roundi(b.y * 100.0), roundi(b.z * 100.0)]
	var key := ka + "|" + kb if ka < kb else kb + "|" + ka
	if not edges.has(key):
		edges[key] = [a, b]


func _make_probe_debug_marker(probe: Dictionary, offset_scale: Vector3 = Vector3.ONE) -> MeshInstance3D:
	var color: Color = probe.get("expected_color", Color.WHITE)
	var shape_source := str(probe.get("shape_source", ""))
	var wc := float(probe.get("w_collision", 0.0))
	var wcol := float(probe.get("w_color", 0.0))
	if wc > wcol and wc > float(probe.get("w_complexity", 0.0)):
		color = Color(1.0, 0.35, 0.2, 1.0)
	color.a = 0.95
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 1.5
	var marker_mesh: Mesh
	if shape_source == "convex":
		marker_mesh = _make_probe_debug_wire_sphere_mesh(0.28)
		mat.albedo_color = Color(1.0, 0.85, 0.1, 1.0)
		mat.emission = mat.albedo_color
		mat.emission_energy_multiplier = 2.4
	elif shape_source == "voxel_interior":
		marker_mesh = _make_probe_debug_wire_sphere_mesh(0.2)
		mat.albedo_color = Color(0.2, 0.8, 1.0, 1.0)
		mat.emission = mat.albedo_color
		mat.emission_energy_multiplier = 2.0
	elif shape_source == "surface":
		var mesh := SphereMesh.new()
		mesh.radius = 0.16
		mesh.height = 0.32
		marker_mesh = mesh
		mat.albedo_color = Color(0.4, 1.0, 0.4, 0.8)
		mat.emission = mat.albedo_color
		mat.emission_energy_multiplier = 1.0
	else:
		var mesh := SphereMesh.new()
		mesh.radius = 0.22
		mesh.height = 0.44
		marker_mesh = mesh
	var marker := MeshInstance3D.new()
	if shape_source == "convex" or shape_source == "voxel_interior":
		marker.name = "WireProbe_%s" % shape_source
		marker.set_meta("semantic_probe_wireframe", true)
	marker.mesh = marker_mesh
	marker.material_override = mat
	marker.position = SemanticProbeProfileScript.vector3_from_value(probe.get("offset", Vector3.ZERO), Vector3.ZERO) * offset_scale
	return marker


func _make_probe_debug_wire_sphere_mesh(radius: float) -> ImmediateMesh:
	var mesh := ImmediateMesh.new()
	var segments := 24
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in range(segments):
		var a0 := TAU * float(i) / float(segments)
		var a1 := TAU * float(i + 1) / float(segments)
		mesh.surface_add_vertex(Vector3(cos(a0) * radius, sin(a0) * radius, 0.0))
		mesh.surface_add_vertex(Vector3(cos(a1) * radius, sin(a1) * radius, 0.0))
		mesh.surface_add_vertex(Vector3(cos(a0) * radius, 0.0, sin(a0) * radius))
		mesh.surface_add_vertex(Vector3(cos(a1) * radius, 0.0, sin(a1) * radius))
		mesh.surface_add_vertex(Vector3(0.0, cos(a0) * radius, sin(a0) * radius))
		mesh.surface_add_vertex(Vector3(0.0, cos(a1) * radius, sin(a1) * radius))
	mesh.surface_end()
	return mesh


func _update_probe_debug_label() -> void:
	if _probe_debug_label == null:
		return
	var total := 0
	for asset in _cached_assets:
		if asset != null:
			total += asset.get_semantic_probes(semantic_probe_density).size()
	_probe_debug_label.text = "Semantic Probes: %.1fx, %d assets, %d probes" % [
		semantic_probe_density,
		_cached_assets.size(),
		total,
	]


func _start_debounce_regen() -> void:
	if _debounce_timer == null:
		_debounce_timer = Timer.new()
		_debounce_timer.one_shot = true
		_debounce_timer.wait_time = 0.5
		_debounce_timer.timeout.connect(_regenerate)
		add_child(_debounce_timer)
	_debounce_timer.start()


func _regenerate() -> void:
	for child in _get_level_children():
		if child.name.begins_with("Cliff_") or child.name == "DebugTargetHeight" or child.name == "DebugDiffHeight" or child.name == "DebugCombinedMask" or child.name == "DebugSemanticProbes" or child.name == "DebugTargetSceneVoxel" or child.name == "Terrain":
			_remove_voxel_write_spec(child)
			child.queue_free()
	for node in _get_level_children():
		if node is AutoObject and not node.is_queued_for_deletion():
			if node.get_record_auto_source("") == "scatter":
				_remove_voxel_write_spec(node)
				node.queue_free()
	_dispose_scene_placement_actor(false)
	if _scene_voxel_committer != null:
		_scene_voxel_committer._free_gpu()
		_scene_voxel_committer = null
	_debug_terrain = null
	_debug_diff_terrain = null
	if _debug_mask_terrain != null:
		_debug_mask_terrain.queue_free()
	_debug_mask_terrain = null
	_debug_probe_root = null
	_target_sv_debug_terrain = null
	_debug_showing = false
	_debug_diff_showing = false
	_target_sv_debug_showing = false
	_step_count = 0
	_raw_target_height_image = null
	_raw_current_height_image = null
	_autoobject_mask_image = null
	_vegetation_generated = false
	_clear_object_mask()
	_invalidate_overrides()
	var final_terrain_tex := _composite_target_height()
	_terrain_hit_y = _compute_terrain_avg_height(final_terrain_tex)
	_create_terrain_mesh(final_terrain_tex)
	print("[MeshFill] Regenerating with overlap=%.0f%%..." % [object_overlap * 100.0])
	_step_generate()


func _toggle_debug_overlay() -> void:
	if _debug_terrain != null:
		_debug_terrain.queue_free()
		_debug_terrain = null
		_debug_showing = false
		print("[MeshFill] Target height debug: OFF (removed)")
		return
	if _raw_target_height_image != null and _raw_current_height_image != null:
		_setup_debug_terrain()
		if _debug_terrain != null:
			_debug_terrain.visible = true
			_debug_showing = true
			print("[MeshFill] Target height debug: ON")
	else:
		print("[MeshFill] No height data available. Use C or the UI rock button first.")


func _toggle_diff_overlay() -> void:
	if _debug_diff_terrain != null:
		_debug_diff_terrain.queue_free()
		_debug_diff_terrain = null
		_debug_diff_showing = false
		print("[MeshFill] Height diff debug: OFF (removed)")
		return
	if _raw_target_height_image != null and _raw_current_height_image != null:
		_setup_diff_terrain(_raw_target_height_image, _raw_current_height_image)
		if _debug_diff_terrain != null:
			_debug_diff_terrain.visible = true
			_debug_diff_showing = true
			print("[MeshFill] Height diff debug: ON")
	else:
		print("[MeshFill] No height data available. Use C or the UI rock button first.")


func _generate() -> void:
	print("[MeshFill] Starting generation...")

	var textures := _load_terrain_textures()
	if textures.is_empty():
		push_error("[MeshFill] Fatal: failed to obtain terrain textures")
		return

	var cliff_meshes: Array[Mesh] = []
	var assets: Array[AutoObject] = []
	_load_cliff_data(cliff_meshes, assets)
	if assets.is_empty():
		push_error("[MeshFill] Fatal: no cliff assets available")
		return
	_cached_textures = textures
	_cached_cliff_meshes = cliff_meshes
	_cached_assets = assets
	_apply_semantic_probe_density_to_assets()
	_sync_autoobject_assets_with_spa(assets)
	for mi_idx in range(cliff_meshes.size()):
		var aabb := cliff_meshes[mi_idx].get_aabb()
		print("[MeshFill] Mesh %d AABB: pos=%s size=%s (Y-up: %.2f ~ %.2f)" % [
			mi_idx, aabb.position, aabb.size,
			aabb.position.y, aabb.position.y + aabb.size.y])

	if _try_generate_cliff_placements_with_spa("Cliff"):
		_create_terrain_mesh(textures["target_height"])
		print("[MeshFill] Done through ScenePlacementActor. Total cliff meshes: %d." % get_tree().get_nodes_in_group("placed_objects").size())
		return

	var prev_object_mask := _load_previous_object_mask()

	print("[MeshFill] Creating generator (iter=%d, capture=%.0fm)..." % [
		num_iterations, capture_size])
	var generator := PlacementFittingGeneratorScript.new()
	generator.texture_size = TEX_RES
	generator.capture_size = capture_size
	generator.max_height = max_height
	generator.generate_threshold = generate_threshold
	generator.un_generate_threshold = un_generate_threshold
	generator.scene_depth_texture = textures["scene_depth"]
	generator.scene_normal_texture = textures["scene_normal"]
	generator.object_depth_texture = textures["object_depth"]
	generator.object_normal_texture = textures["object_normal"]
	generator.height_normal_texture = textures["height_normal"]
	generator.target_height_texture = textures["target_height"]
	generator.placed_mask_texture = prev_object_mask
	generator.stamp_overlap = object_overlap
	generator.fitting_assets = assets
	add_child(generator)

	print("[MeshFill] Running compute shaders...")
	var t0 := Time.get_ticks_msec()
	var results := _generate_cliff_placements(generator, num_iterations)
	var elapsed := Time.get_ticks_msec() - t0
	print("[MeshFill] Generated %d placements in %dms" % [results.size(), elapsed])

	_raw_target_height_image = generator._debug_target_height_image
	_raw_current_height_image = generator._debug_current_height_image

	for i in range(results.size()):
		var r: Dictionary = results[i]
		var mesh_index := int(r.mesh_index)
		var asset := assets[mesh_index]
		var mi := _instantiate_object_asset(asset)
		var visual_scale: Vector3 = Vector3.ONE * r.scale * fbx_unit_scale * mesh_height_scale
		var mesh_aabb := asset.mesh.get_aabb()
		var mesh_top_y := (mesh_aabb.position.y + mesh_aabb.size.y) * visual_scale.y
		var rock_position: Vector3 = r.position
		rock_position.y -= mesh_top_y
		mi.configure_from_asset(asset, {
			"name": "Cliff_%d_m%d" % [i, mesh_index],
			"position": rock_position,
			"rotation_mode": str(r.get("rotation_mode", "Y")),
			"rotation_degrees": r.get("rotation_degrees", Vector3.ZERO),
			"scale": visual_scale,
			"visual_layer": OBJECT_VISUAL_LAYER,
			"mesh_index": mesh_index,
			"auto_source": "meshfill",
			"groups": [MANUAL_GENERATED_GROUP, MANUAL_OBJECT_GROUP],
		})
		_get_level_root().add_child(mi)
		_mark_manual_generated(mi, "rock")
		_own_autoobject_with_spa(mi, mesh_index)
		var rock_record := _mark_manual_generation_record(_make_cliff_voxel_write_spec(mi.name, r, mi, mesh_aabb, asset), "rock")
		_attach_voxel_write_spec(mi, rock_record)
		if i < 5:
			print("  [%d] pos=%s rot=%.1f掳 scale=%.3f mesh=%d top_offset=%.2f" % [
				i, r.position, Vector3(r.get("rotation_degrees", Vector3.ZERO)).y, mi.scale.x, r.mesh_index, mesh_top_y])

	if _raw_target_height_image != null:
		var height_stats := _get_height_stats(_raw_target_height_image)
		var h_min := height_stats.x
		var h_max := height_stats.y
		print("[MeshFill] Target height range: %.1f - %.1f" % [h_min, h_max])

	_analyze_height_difference(textures["scene_depth"])
	_save_height_maps()

	generator.queue_free()
	print("[MeshFill] Done! Placed %d cliff meshes." % results.size())

	_capture_and_save_object_mask()
	_create_terrain_mesh(textures["target_height"])


# --- Height analysis & export ---

func _analyze_height_difference(scene_depth_tex: ImageTexture) -> void:
	if _raw_target_height_image == null or _raw_current_height_image == null:
		print("[MeshFill] Cannot analyze: missing height images")
		return

	var scene_depth_img := scene_depth_tex.get_image()
	var res := _raw_target_height_image.get_width()
	var stats := _compute_height_difference_stats_gpu(_raw_target_height_image, _raw_current_height_image, scene_depth_img)
	if not bool(stats.get("valid", false)):
		push_error("[MeshFill] Height difference stats GPU compute failed")
		return

	var total_gen := int(stats.get("total_gen", 0))
	if total_gen == 0:
		print("[MeshFill] No generate-mask pixels to analyze")
		return

	var already_above := int(stats.get("already_above", 0))
	var fillable_count := int(stats.get("fillable_count", 0))
	var filled_ok := int(stats.get("filled_ok", 0))
	var still_under := int(stats.get("still_under", 0))
	var object_overshoot := int(stats.get("object_overshoot", 0))
	var object_added_count := int(stats.get("object_added_count", 0))

	print("[MeshFill] Height Difference Analysis")
	print("[MeshFill]   Generate-mask pixels: %d / %d" % [total_gen, res * res])
	print("[MeshFill]   Overall RMSE: %.3f m | MAE: %.3f m | Max: %.3f m" % [
		float(stats.get("rmse", 0.0)),
		float(stats.get("mae", 0.0)),
		float(stats.get("max_err", 0.0)),
	])
	print("[MeshFill] --- Breakdown ---")
	print("[MeshFill]   Terrain already above target: %d (%.1f%%)" % [already_above, float(already_above) / float(total_gen) * 100.0])

	if fillable_count > 0:
		print("[MeshFill]   Fillable pixels: %d (%.1f%%)" % [fillable_count, float(fillable_count) / float(total_gen) * 100.0])
		print("[MeshFill]     Fillable RMSE: %.3f m | MAE: %.3f m" % [
			float(stats.get("fillable_rmse", 0.0)),
			float(stats.get("fillable_mae", 0.0)),
		])
		print("[MeshFill]     Filled OK (|diff| < 0.5m): %d (%.1f%%)" % [filled_ok, float(filled_ok) / float(fillable_count) * 100.0])
		print("[MeshFill]     Still under-filled:        %d (%.1f%%)" % [still_under, float(still_under) / float(fillable_count) * 100.0])
		print("[MeshFill]     Rock overshoot:            %d (%.1f%%)" % [object_overshoot, float(object_overshoot) / float(fillable_count) * 100.0])

	if object_added_count > 0:
		print("[MeshFill]   Avg rock height added: %.3f m (%d pixels with rocks)" % [
			float(stats.get("avg_object_height", 0.0)),
			object_added_count,
		])


func _compute_height_difference_stats_gpu(target_img: Image, current_img: Image, scene_depth_img: Image) -> Dictionary:
	if target_img == null or current_img == null or scene_depth_img == null:
		return {}
	if target_img.is_empty() or current_img.is_empty() or scene_depth_img.is_empty():
		return {}
	var width := target_img.get_width()
	var height := target_img.get_height()
	if width <= 0 or height <= 0:
		return {}
	if current_img.get_width() != width or scene_depth_img.get_width() != width:
		return {}
	if current_img.get_height() != height or scene_depth_img.get_height() != height:
		return {}
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		return {}
	probe_rd.free()

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "HeightDifferenceStats"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return {}
	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader("res://shaders/height_difference_stats.glsl")
	var pipeline := compute.create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return {}

	var target_tex := compute.upload_texture_2d(
		target_img,
		RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
		Image.FORMAT_RGBAF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"height_diff_stats_target_rgba32f"
	)
	var current_tex := compute.upload_texture_2d(
		current_img,
		RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
		Image.FORMAT_RGBAF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"height_diff_stats_current_rgba32f"
	)
	var depth_tex := compute.upload_texture_2d(
		scene_depth_img,
		RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
		Image.FORMAT_RGBAF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"height_diff_stats_depth_rgba32f"
	)
	var groups_x := ceili(float(width) / 16.0)
	var groups_y := ceili(float(height) / 16.0)
	var group_count := groups_x * groups_y
	var stats_buf := compute.storage_buffer_zero(group_count * 64, ComputeShaderBaseScript.SCOPE_FRAME, "height_diff_stats_groups")
	if not target_tex.is_valid() or not current_tex.is_valid() or not depth_tex.is_valid() or not stats_buf.is_valid():
		compute.dispose()
		return {}

	var sampler := compute.create_linear_sampler()
	if not sampler.is_valid():
		compute.dispose()
		return {}
	var set0 := compute.create_uniform_set([
		compute.make_sampler_uniform(0, sampler, target_tex),
		compute.make_sampler_uniform(1, sampler, current_tex),
		compute.make_sampler_uniform(2, sampler, depth_tex),
	], shader, 0)
	var set1 := compute.create_uniform_set([
		compute.make_storage_uniform(0, stats_buf),
	], shader, 1)
	if not set0.is_valid() or not set1.is_valid():
		compute.dispose()
		return {}

	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, width)
	push.encode_s32(4, height)
	push.encode_float(8, max_height)
	push.encode_float(12, 0.0)

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

	var data := rd.buffer_get_data(stats_buf, 0, group_count * 64)
	compute.dispose()
	if data.size() < group_count * 64:
		return {}

	var total_gen := 0
	var already_above := 0
	var filled_ok := 0
	var still_under := 0
	var object_overshoot := 0
	var fillable_count := 0
	var object_added_count := 0
	var sum_sq_err := 0.0
	var sum_abs_err := 0.0
	var max_err := 0.0
	var sum_sq_fillable := 0.0
	var sum_abs_fillable := 0.0
	var sum_object_added := 0.0
	var target_h_min := INF
	var target_h_max := -INF
	for group_index in range(group_count):
		var off := group_index * 64
		total_gen += roundi(data.decode_float(off + 0))
		already_above += roundi(data.decode_float(off + 4))
		filled_ok += roundi(data.decode_float(off + 8))
		still_under += roundi(data.decode_float(off + 12))
		object_overshoot += roundi(data.decode_float(off + 16))
		fillable_count += roundi(data.decode_float(off + 20))
		object_added_count += roundi(data.decode_float(off + 24))
		sum_sq_err += data.decode_float(off + 32)
		sum_abs_err += data.decode_float(off + 36)
		max_err = maxf(max_err, data.decode_float(off + 40))
		sum_sq_fillable += data.decode_float(off + 44)
		sum_abs_fillable += data.decode_float(off + 48)
		sum_object_added += data.decode_float(off + 52)
		target_h_min = minf(target_h_min, data.decode_float(off + 56))
		target_h_max = maxf(target_h_max, data.decode_float(off + 60))

	var result := {
		"valid": true,
		"total_gen": total_gen,
		"already_above": already_above,
		"filled_ok": filled_ok,
		"still_under": still_under,
		"object_overshoot": object_overshoot,
		"fillable_count": fillable_count,
		"object_added_count": object_added_count,
		"target_h_min": 0.0 if target_h_min == INF else target_h_min,
		"target_h_max": 0.0 if target_h_max == -INF else target_h_max,
		"rmse": 0.0,
		"mae": 0.0,
		"max_err": max_err,
		"fillable_rmse": 0.0,
		"fillable_mae": 0.0,
		"filled_ok_pct": 0.0,
		"under_filled_pct": 0.0,
		"overshoot_pct": 0.0,
		"avg_object_height": 0.0,
	}
	if total_gen > 0:
		result["rmse"] = sqrt(sum_sq_err / float(total_gen))
		result["mae"] = sum_abs_err / float(total_gen)
	if fillable_count > 0:
		result["fillable_rmse"] = sqrt(sum_sq_fillable / float(fillable_count))
		result["fillable_mae"] = sum_abs_fillable / float(fillable_count)
		result["filled_ok_pct"] = float(filled_ok) / float(fillable_count) * 100.0
		result["under_filled_pct"] = float(still_under) / float(fillable_count) * 100.0
		result["overshoot_pct"] = float(object_overshoot) / float(fillable_count) * 100.0
	if object_added_count > 0:
		result["avg_object_height"] = sum_object_added / float(object_added_count)
	return result


func _save_height_maps() -> void:
	var out_dir := OS.get_user_data_dir()

	if _raw_target_height_image != null:
		var target_vis := _height_to_grayscale(_raw_target_height_image, 0)
		target_vis.save_png(out_dir + "/target_height.png")
		print("[MeshFill] Saved: %s/target_height.png" % out_dir)

	if _raw_current_height_image != null:
		var current_vis := _height_to_grayscale(_raw_current_height_image, 0)
		current_vis.save_png(out_dir + "/current_height.png")
		print("[MeshFill] Saved: %s/current_height.png" % out_dir)

	if _raw_target_height_image != null and _raw_current_height_image != null:
		var diff_vis := _height_diff_to_color(_raw_target_height_image, _raw_current_height_image)
		diff_vis.save_png(out_dir + "/height_diff.png")
		print("[MeshFill] Saved: %s/height_diff.png" % out_dir)
		_setup_diff_terrain(_raw_target_height_image, _raw_current_height_image)


func _target_sv_dir_absolute() -> String:
	return OS.get_user_data_dir() + "/" + TARGET_SV_DIR_NAME


func _target_sv_meta_path() -> String:
	return _target_sv_dir_absolute() + "/target_scene_voxel.json"


func _target_sv_b_meta_path() -> String:
	return _target_sv_dir_absolute() + "/target_scene_voxel_b.json"


func _target_sv_preview_path() -> String:
	return _target_sv_dir_absolute() + "/target_scene_voxel_preview.png"


func _target_sv_b_preview_path() -> String:
	return _target_sv_dir_absolute() + "/target_scene_voxel_b_preview.png"


func _target_sv_visual_path() -> String:
	return _target_sv_dir_absolute() + "/target_scene_voxel_visual.rgba32f"


func _target_sv_b_visual_path() -> String:
	return _target_sv_dir_absolute() + "/target_scene_voxel_b_visual.rgba32f"


func _target_sv_collision_path() -> String:
	return _target_sv_dir_absolute() + "/target_scene_voxel_collision.r32f"


func _target_sv_b_collision_path() -> String:
	return _target_sv_dir_absolute() + "/target_scene_voxel_b_collision.r32f"


func _target_sv_occupancy_path() -> String:
	return _target_sv_dir_absolute() + "/target_scene_voxel_occupancy.r32f"


func _target_sv_b_occupancy_path() -> String:
	return _target_sv_dir_absolute() + "/target_scene_voxel_b_occupancy.r32f"


func _target_sv_color_rgba8_path() -> String:
	return _target_sv_dir_absolute() + "/target_scene_voxel_color_rgba8.u32"


func _target_sv_b_color_rgba8_path() -> String:
	return _target_sv_dir_absolute() + "/target_scene_voxel_b_color_rgba8.u32"


func _write_target_sv_buffer(path: String, bytes: PackedByteArray) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("[TargetSV] Failed to open for write: %s" % path)
		return false
	file.store_buffer(bytes)
	file.close()
	return true


func _read_target_sv_buffer(path: String) -> PackedByteArray:
	var bytes := PackedByteArray()
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("[TargetSV] Failed to open persistent buffer: %s" % path)
		return bytes
	bytes = file.get_buffer(file.get_length())
	file.close()
	return bytes


func _save_target_scene_voxel(result: Dictionary, target_role: String = "TargetSV", brush_composited: bool = false) -> bool:
	var out_dir := _target_sv_dir_absolute()
	DirAccess.make_dir_recursive_absolute(out_dir)
	var is_target_b := target_role == "TargetSV_B"
	var visual_path := _target_sv_b_visual_path() if is_target_b else _target_sv_visual_path()
	var collision_path := _target_sv_b_collision_path() if is_target_b else _target_sv_collision_path()
	var occupancy_path := _target_sv_b_occupancy_path() if is_target_b else _target_sv_occupancy_path()
	var color_rgba8_path := _target_sv_b_color_rgba8_path() if is_target_b else _target_sv_color_rgba8_path()
	var preview_path := _target_sv_b_preview_path() if is_target_b else _target_sv_preview_path()
	var meta_path := _target_sv_b_meta_path() if is_target_b else _target_sv_meta_path()
	var visual_bytes: PackedByteArray = result.get("visual_bytes", PackedByteArray())
	var collision_bytes: PackedByteArray = result.get("collision_bytes", PackedByteArray())
	var occupancy_bytes: PackedByteArray = result.get("target_completely_bytes", PackedByteArray())
	var color_rgba8_bytes: PackedByteArray = result.get("target_color_rgba8_bytes", PackedByteArray())
	var preview_img: Image = result.get("preview_image", null)
	if preview_img == null or visual_bytes.is_empty() or collision_bytes.is_empty():
		push_error("[%s] Save failed: incomplete target result" % target_role)
		return false
	if not _write_target_sv_buffer(visual_path, visual_bytes):
		return false
	if not _write_target_sv_buffer(collision_path, collision_bytes):
		return false
	if not occupancy_bytes.is_empty() and not _write_target_sv_buffer(occupancy_path, occupancy_bytes):
		return false
	if not color_rgba8_bytes.is_empty() and not _write_target_sv_buffer(color_rgba8_path, color_rgba8_bytes):
		return false
	if is_target_b:
		_target_sv_b_visual_bytes = visual_bytes
		_target_sv_b_collision_bytes = collision_bytes
		_target_sv_b_target_completely_bytes = occupancy_bytes
		_target_sv_b_target_color_rgba8_bytes = color_rgba8_bytes
	else:
		_target_sv_visual_bytes = visual_bytes
		_target_sv_collision_bytes = collision_bytes
		_target_sv_target_completely_bytes = occupancy_bytes
		_target_sv_target_color_rgba8_bytes = color_rgba8_bytes
	var preview_png := preview_img.duplicate()
	if preview_png.get_format() != Image.FORMAT_RGBA8:
		preview_png.convert(Image.FORMAT_RGBA8)
	preview_png.save_png(preview_path)
	var metadata := {
		"version": 1,
		"created_unix": Time.get_unix_time_from_system(),
		"target_role": target_role,
		"brush_composited": brush_composited,
		"texture_size": int(result.get("texture_size", TEX_RES)),
		"slice_count": int(result.get("slice_count", TARGET_SV_SLICE_COUNT)),
		"voxel_count": int(result.get("voxel_count", TEX_RES * TEX_RES * TARGET_SV_SLICE_COUNT)),
		"max_height": float(result.get("max_height", max_height)),
		"capture_size": float(result.get("capture_size", capture_size)),
		"vertical_span": float(result.get("vertical_span", TARGET_SV_VERTICAL_SPAN)),
		"visual_format": str(result.get("visual_format", "rgba32f")),
		"collision_format": str(result.get("collision_format", "r32f")),
		"completely_format": str(result.get("completely_format", "r32f")),
		"target_color_format": str(result.get("target_color_format", "rgba8_u32")),
		"visual_path": visual_path,
		"collision_path": collision_path,
		"target_completely_path": occupancy_path,
		"target_color_rgba8_path": color_rgba8_path,
		"preview_path": preview_path,
		"generator": "TargetSceneVoxelGenerator",
		"gpu_only_generation": true,
	}
	if is_target_b:
		metadata["source_target_meta_path"] = _target_sv_meta_path()
		_target_sv_b_metadata = metadata
		_target_sv_b_preview_image = preview_img
	else:
		_target_sv_metadata = metadata
		_target_sv_preview_image = preview_img
	var meta_file := FileAccess.open(meta_path, FileAccess.WRITE)
	if meta_file == null:
		push_error("[%s] Failed to write metadata: %s" % [target_role, meta_path])
		return false
	meta_file.store_string(JSON.stringify(metadata, "\t"))
	meta_file.close()
	print("[%s] Saved persistent target: %s" % [target_role, out_dir])
	return true


func _load_persisted_target_scene_voxel_variant(target_role: String) -> bool:
	var is_target_b := target_role == "TargetSV_B"
	var preview_path := _target_sv_b_preview_path() if is_target_b else _target_sv_preview_path()
	if not FileAccess.file_exists(preview_path):
		return false
	var preview_img := Image.load_from_file(preview_path)
	if preview_img == null:
		push_warning("[%s] Failed to load preview: %s" % [target_role, preview_path])
		return false
	var metadata := {}
	var meta_path := _target_sv_b_meta_path() if is_target_b else _target_sv_meta_path()
	if FileAccess.file_exists(meta_path):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(meta_path))
		if parsed is Dictionary:
			metadata = parsed as Dictionary
	var visual_path := _target_sv_b_visual_path() if is_target_b else _target_sv_visual_path()
	var collision_path := _target_sv_b_collision_path() if is_target_b else _target_sv_collision_path()
	var occupancy_path := str(metadata.get(
		"target_completely_path",
		_target_sv_b_occupancy_path() if is_target_b else _target_sv_occupancy_path()
	))
	var color_rgba8_path := str(metadata.get(
		"target_color_rgba8_path",
		_target_sv_b_color_rgba8_path() if is_target_b else _target_sv_color_rgba8_path()
	))
	var visual_bytes := _read_target_sv_buffer(visual_path)
	var collision_bytes := _read_target_sv_buffer(collision_path)
	var occupancy_bytes := PackedByteArray()
	if FileAccess.file_exists(occupancy_path):
		occupancy_bytes = _read_target_sv_buffer(occupancy_path)
	var color_rgba8_bytes := PackedByteArray()
	if FileAccess.file_exists(color_rgba8_path):
		color_rgba8_bytes = _read_target_sv_buffer(color_rgba8_path)
	var tex_size := int(metadata.get("texture_size", preview_img.get_width()))
	var slice_count := int(metadata.get("slice_count", TARGET_SV_SLICE_COUNT))
	var voxel_count := tex_size * tex_size * slice_count
	if visual_bytes.size() != voxel_count * 16:
		push_warning("[%s] Persistent visual buffer size mismatch: got %d expected %d" % [target_role, visual_bytes.size(), voxel_count * 16])
	if collision_bytes.size() != voxel_count * 4:
		push_warning("[%s] Persistent collision buffer size mismatch: got %d expected %d" % [target_role, collision_bytes.size(), voxel_count * 4])
	if not occupancy_bytes.is_empty() and occupancy_bytes.size() != voxel_count * 4:
		push_warning("[%s] Persistent occupancy buffer size mismatch: got %d expected %d" % [target_role, occupancy_bytes.size(), voxel_count * 4])
		occupancy_bytes = PackedByteArray()
	if not color_rgba8_bytes.is_empty() and color_rgba8_bytes.size() != voxel_count * 4:
		push_warning("[%s] Persistent target color RGBA8 buffer size mismatch: got %d expected %d" % [target_role, color_rgba8_bytes.size(), voxel_count * 4])
		color_rgba8_bytes = PackedByteArray()
	var packed_buffers := _derive_target_sv_packed_buffers_if_needed(
		target_role,
		visual_bytes,
		collision_bytes,
		tex_size,
		slice_count,
		occupancy_bytes,
		color_rgba8_bytes,
		occupancy_path,
		color_rgba8_path
	)
	occupancy_bytes = packed_buffers.get("target_completely_bytes", occupancy_bytes)
	color_rgba8_bytes = packed_buffers.get("target_color_rgba8_bytes", color_rgba8_bytes)
	if is_target_b:
		_target_sv_b_preview_image = preview_img
		_target_sv_b_metadata = metadata
		_target_sv_b_visual_bytes = visual_bytes
		_target_sv_b_collision_bytes = collision_bytes
		_target_sv_b_target_color_rgba8_bytes = color_rgba8_bytes
		_target_sv_b_target_completely_bytes = occupancy_bytes
	else:
		_target_sv_preview_image = preview_img
		_target_sv_metadata = metadata
		_target_sv_visual_bytes = visual_bytes
		_target_sv_collision_bytes = collision_bytes
		_target_sv_target_completely_bytes = occupancy_bytes
		_target_sv_target_color_rgba8_bytes = color_rgba8_bytes
	print("[%s] Loaded persistent target: %s" % [target_role, preview_path])
	return true


func _safe_load_target_sv_generator() -> Object:
	if TARGET_SV_GENERATOR_PATH.is_empty():
		return null
	if not FileAccess.file_exists(TARGET_SV_GENERATOR_PATH):
		push_warning("[main] TargetSceneVoxelGenerator script not found at: %s" % TARGET_SV_GENERATOR_PATH)
		return null
	var generator_script: Resource = load(TARGET_SV_GENERATOR_PATH)
	if generator_script == null:
		push_warning("[main] Failed to load TargetSceneVoxelGenerator script")
		return null
	return generator_script.new()


func _default_derive_target_packed_buffers(
	visual_bytes: PackedByteArray,
	collision_bytes: PackedByteArray,
	tex_size: int,
	slice_count: int,
	use_collision_as_completely: bool,
	_occupancy_bytes: PackedByteArray
) -> Dictionary:
	var voxel_count := maxi(tex_size, 1) * maxi(slice_count, 1) * maxi(tex_size, 1)
	var expected_visual_bytes := voxel_count * 16
	var expected_scalar_bytes := voxel_count * 4
	var occupancy_out := PackedByteArray()
	var color_rgba8_out := PackedByteArray()
	occupancy_out.resize(expected_scalar_bytes)
	color_rgba8_out.resize(expected_scalar_bytes)
	var max_completely := 0.0
	var active_voxel_count := 0
	for i in range(voxel_count):
		var complexity := 0.0
		if visual_bytes.size() >= (i + 1) * 16:
			complexity = visual_bytes.decode_float(i * 16 + 12)
		var collision := 0.0
		if collision_bytes.size() >= (i + 1) * 4:
			collision = collision_bytes.decode_float(i * 4)
		var occupancy := maxf(clampf(complexity, 0.0, 1.0), clampf(collision, 0.0, 1.0))
		occupancy_out.encode_float(i * 4, occupancy)
		if occupancy > 0.001:
			active_voxel_count += 1
			max_completely = maxf(max_completely, occupancy)
		var r := 0.0
		var g := 0.0
		var b := 0.0
		if visual_bytes.size() >= (i + 1) * 16:
			r = clampf(visual_bytes.decode_float(i * 16 + 0), 0.0, 1.0)
			g = clampf(visual_bytes.decode_float(i * 16 + 4), 0.0, 1.0)
			b = clampf(visual_bytes.decode_float(i * 16 + 8), 0.0, 1.0)
		var rgba8_word := (int(r * 255.0) << 24) | (int(g * 255.0) << 16) | (int(b * 255.0) << 8) | int(complexity * 255.0)
		color_rgba8_out.encode_u32(i * 4, rgba8_word)
	return {
		"ok": true,
		"reason": "ok",
		"gpu_first": false,
		"cpu_fallback": true,
		"voxel_count": voxel_count,
		"texture_size": tex_size,
		"slice_count": slice_count,
		"completely_format": "r32f",
		"target_color_format": "rgba8_u32",
		"target_completely_bytes": occupancy_out,
		"target_color_rgba8_bytes": color_rgba8_out,
		"max_completely": max_completely,
		"active_voxel_count": active_voxel_count,
		"target_completely_source": "cpu_default_visual_collision",
	}


func _default_generate_target_sv(
	tex_size: int, slice_count: int, mh: float, cap_size: float, vert_span: float
) -> Dictionary:
	var voxel_count := maxi(tex_size, 1) * maxi(slice_count, 1) * maxi(tex_size, 1)
	var visual_bytes := PackedByteArray()
	var collision_bytes := PackedByteArray()
	var occupancy_bytes := PackedByteArray()
	var color_rgba8_bytes := PackedByteArray()
	visual_bytes.resize(voxel_count * 16)
	collision_bytes.resize(voxel_count * 4)
	occupancy_bytes.resize(voxel_count * 4)
	color_rgba8_bytes.resize(voxel_count * 4)
	for i in range(voxel_count):
		visual_bytes.encode_float(i * 16 + 0, 0.0)
		visual_bytes.encode_float(i * 16 + 4, 0.0)
		visual_bytes.encode_float(i * 16 + 8, 0.0)
		visual_bytes.encode_float(i * 16 + 12, 0.0)
		collision_bytes.encode_float(i * 4, 0.0)
		occupancy_bytes.encode_float(i * 4, 0.0)
		color_rgba8_bytes.encode_u32(i * 4, 0)
	var preview_img := Image.create(tex_size, tex_size, false, Image.FORMAT_RGBA8)
	preview_img.fill(Color(0.0, 0.0, 0.0, 0.0))
	print("[TargetSV] Generated default CPU TargetSV (empty): tex=%d slices=%d" % [tex_size, slice_count])
	return {
		"valid": true,
		"texture_size": tex_size,
		"slice_count": slice_count,
		"voxel_count": voxel_count,
		"max_height": mh,
		"capture_size": cap_size,
		"vertical_span": vert_span,
		"visual_format": "rgba32f",
		"collision_format": "r32f",
		"completely_format": "r32f",
		"target_color_format": "rgba8_u32",
		"visual_bytes": visual_bytes,
		"collision_bytes": collision_bytes,
		"target_completely_bytes": occupancy_bytes,
		"target_color_rgba8_bytes": color_rgba8_bytes,
		"max_completely": 0.0,
		"max_collision": 0.0,
		"active_voxel_count": 0,
		"collision_voxel_count": 0,
		"visual_voxel_count": 0,
		"min_active_completely": 0.0,
		"max_visual_complexity": 0.0,
		"target_stats_source": "cpu_default_empty",
		"preview_image": preview_img,
		"gpu_generated": false,
		"cpu_default": true,
	}


func _derive_target_sv_packed_buffers_if_needed(
	target_role: String,
	visual_bytes: PackedByteArray,
	collision_bytes: PackedByteArray,
	tex_size: int,
	slice_count: int,
	occupancy_bytes: PackedByteArray,
	color_rgba8_bytes: PackedByteArray,
	occupancy_path: String,
	color_rgba8_path: String
) -> Dictionary:
	var voxel_count := maxi(tex_size, 1) * maxi(slice_count, 1) * maxi(tex_size, 1)
	var expected_visual_bytes := voxel_count * 16
	var expected_scalar_bytes := voxel_count * 4
	var needs_occupancy := occupancy_bytes.size() != expected_scalar_bytes
	var needs_color := color_rgba8_bytes.size() != expected_scalar_bytes
	if not needs_occupancy and not needs_color:
		return {
			"target_completely_bytes": occupancy_bytes,
			"target_color_rgba8_bytes": color_rgba8_bytes,
		}
	if visual_bytes.size() < expected_visual_bytes or collision_bytes.size() < expected_scalar_bytes:
		return {
			"target_completely_bytes": occupancy_bytes,
			"target_color_rgba8_bytes": color_rgba8_bytes,
		}

	var generator: Object = _safe_load_target_sv_generator()
	var derived: Dictionary
	if generator != null:
		derived = generator.derive_target_packed_buffers(
			visual_bytes,
			collision_bytes,
			tex_size,
			slice_count,
			true,
			occupancy_bytes
		)
	else:
		derived = _default_derive_target_packed_buffers(
			visual_bytes,
			collision_bytes,
			tex_size,
			slice_count,
			true,
			occupancy_bytes
		)
	if not bool(derived.get("ok", false)):
		var reason := str(derived.get("reason", "unknown"))
		if reason != "missing_rendering_device":
			push_warning("[%s] GPU derivation of missing TargetSV packed buffers failed: %s" % [target_role, reason])
		return {
			"target_completely_bytes": occupancy_bytes,
			"target_color_rgba8_bytes": color_rgba8_bytes,
		}

	if needs_occupancy:
		var derived_occupancy: PackedByteArray = derived.get("target_completely_bytes", PackedByteArray())
		if derived_occupancy.size() == expected_scalar_bytes:
			occupancy_bytes = derived_occupancy
			_write_target_sv_buffer(occupancy_path, occupancy_bytes)
	if needs_color:
		var derived_color: PackedByteArray = derived.get("target_color_rgba8_bytes", PackedByteArray())
		if derived_color.size() == expected_scalar_bytes:
			color_rgba8_bytes = derived_color
			_write_target_sv_buffer(color_rgba8_path, color_rgba8_bytes)
	if needs_occupancy or needs_color:
		print("[%s] Derived missing TargetSV packed buffers on GPU: occupancy=%s color_rgba8=%s" % [
			target_role,
			str(occupancy_bytes.size() == expected_scalar_bytes),
			str(color_rgba8_bytes.size() == expected_scalar_bytes),
		])
	return {
		"target_completely_bytes": occupancy_bytes,
		"target_color_rgba8_bytes": color_rgba8_bytes,
	}


func _load_persisted_target_scene_voxel() -> bool:
	var loaded_source := _load_persisted_target_scene_voxel_variant("TargetSV")
	var loaded_b := _load_persisted_target_scene_voxel_variant("TargetSV_B")
	if not loaded_b and loaded_source:
		_target_sv_b_preview_image = _target_sv_preview_image
		_target_sv_b_metadata = _target_sv_metadata.duplicate(true)
		_target_sv_b_visual_bytes = _target_sv_visual_bytes
		_target_sv_b_collision_bytes = _target_sv_collision_bytes
		_target_sv_b_target_completely_bytes = _target_sv_target_completely_bytes
		_target_sv_b_target_color_rgba8_bytes = _target_sv_target_color_rgba8_bytes
		_target_sv_b_metadata["target_role"] = "TargetSV_B"
		_target_sv_b_metadata["fallback_from_source_target"] = true
	return loaded_source or loaded_b


func _recompute_and_save_target_scene_voxel() -> void:
	if _cached_textures.is_empty():
		push_error("[TargetSV] Cannot recompute: terrain textures are not loaded")
		return
	var scene_depth_tex := _cached_textures.get("scene_depth", null) as ImageTexture
	var target_height_base := _cached_textures.get("target_height", null) as ImageTexture
	if scene_depth_tex == null or target_height_base == null:
		push_error("[TargetSV] Cannot recompute: missing scene_depth or target_height texture")
		return
	var object_mask_img: Image = _current_object_mask_img
	if object_mask_img == null:
		object_mask_img = Image.create(TEX_RES, TEX_RES, false, Image.FORMAT_RF)
		object_mask_img.fill(Color(0.0, 0.0, 0.0, 0.0))
	var has_height_override := _has_mask_pixels(_override_mask)
	var has_rock_override := _has_mask_pixels(_object_override_mask)
	var generator: Object = _safe_load_target_sv_generator()
	if generator != null:
		generator.texture_size = TEX_RES
		generator.slice_count = TARGET_SV_SLICE_COUNT
		generator.max_height = max_height
		generator.capture_size = capture_size
		generator.vertical_span = TARGET_SV_VERTICAL_SPAN
		generator.slope_start = landscape_cliff_slope_start
		generator.slope_full = landscape_cliff_slope_full
		print("[TargetSV] Recomputing source TargetSV on GPU...")
		var t0 := Time.get_ticks_msec()
		var source_result: Dictionary = generator.generate(
			scene_depth_tex.get_image(),
			target_height_base.get_image(),
			object_mask_img,
			Rect2i(0, 0, TEX_RES, TEX_RES)
		)
		if source_result.is_empty():
			push_error("[TargetSV] Source GPU recompute failed")
			return
		var saved_source := _save_target_scene_voxel(source_result, "TargetSV", false)
		var target_height_b_tex := _composite_target_height()
		var object_mask_b_img := _composite_object_mask()
		var b_result: Dictionary = source_result
		if has_height_override or has_rock_override:
			print("[TargetSV_B] Recomputing brush-composited TargetSV_B on GPU...")
			b_result = generator.generate(
				scene_depth_tex.get_image(),
				target_height_b_tex.get_image(),
				object_mask_b_img,
				Rect2i(0, 0, TEX_RES, TEX_RES)
			)
			if b_result.is_empty():
				push_error("[TargetSV_B] GPU recompute failed")
				return
		var saved_b := _save_target_scene_voxel(b_result, "TargetSV_B", has_height_override or has_rock_override)
		var elapsed := Time.get_ticks_msec() - t0
		if saved_source and saved_b:
			print("[TargetSV] Source + TargetSV_B recompute/save complete in %dms" % elapsed)
	else:
		var default_result := _default_generate_target_sv(TEX_RES, TARGET_SV_SLICE_COUNT, max_height, capture_size, TARGET_SV_VERTICAL_SPAN)
		var saved_source := _save_target_scene_voxel(default_result, "TargetSV", false)
		var saved_b := _save_target_scene_voxel(default_result, "TargetSV_B", false)
		if saved_source and saved_b:
			print("[TargetSV] Default CPU TargetSV saved (GPU generator unavailable)")
	if _target_sv_debug_showing:
		_build_target_scene_voxel_overlay()
		if _target_sv_debug_terrain != null:
			_target_sv_debug_terrain.visible = true
			_target_sv_debug_showing = true


func _build_target_scene_voxel_overlay() -> void:
	if _target_sv_debug_terrain != null:
		_target_sv_debug_terrain.queue_free()
		_target_sv_debug_terrain = null
	if _target_sv_b_preview_image == null:
		return
	if _cached_textures.is_empty():
		return
	var depth_img: Image = (_cached_textures["scene_depth"] as ImageTexture).get_image()
	var img := _target_sv_b_preview_image
	var res := img.get_width()
	var depth_width := depth_img.get_width()
	var depth_height := depth_img.get_height()
	var depth_values := _image_rgba32f_values(depth_img)
	var preview_values := _image_rgba32f_values(img)
	var cell_size := capture_size / float(res)
	var half := capture_size / 2.0
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for y in range(res):
		for x in range(res):
			var px := Vector2i(x, y)
			var depth_px := Vector2i(
				clampi(int(float(x) / float(maxi(res - 1, 1)) * float(depth_width - 1)), 0, depth_width - 1),
				clampi(int(float(y) / float(maxi(res - 1, 1)) * float(depth_height - 1)), 0, depth_height - 1)
			)
			var depth_index := (depth_px.y * depth_width + depth_px.x) * 4
			var preview_index := (px.y * res + px.x) * 4
			var depth_value := depth_values[depth_index] if depth_index < depth_values.size() else max_height
			var c := Color(
				preview_values[preview_index] if preview_index < preview_values.size() else 0.0,
				preview_values[preview_index + 1] if preview_index + 1 < preview_values.size() else 0.0,
				preview_values[preview_index + 2] if preview_index + 2 < preview_values.size() else 0.0,
				preview_values[preview_index + 3] if preview_index + 3 < preview_values.size() else 0.0
			)
			var h := max_height - depth_value + 0.45
			var voxel_signal := clampf(maxf(c.a, maxf(c.r, maxf(c.g, c.b))), 0.0, 1.0)
			var alpha := 0.7 * voxel_signal if voxel_signal > 0.01 else 0.0
			st.set_color(Color(c.r, c.g, c.b, alpha))
			st.set_uv(Vector2(float(x) / float(maxi(res - 1, 1)), float(y) / float(maxi(res - 1, 1))))
			st.add_vertex(Vector3(float(x) * cell_size - half, h, float(y) * cell_size - half))
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
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	_target_sv_debug_terrain = MeshInstance3D.new()
	_target_sv_debug_terrain.mesh = st.commit()
	_target_sv_debug_terrain.material_override = mat
	_target_sv_debug_terrain.name = "DebugTargetSceneVoxel"
	_target_sv_debug_terrain.visible = false
	_get_level_root().add_child(_target_sv_debug_terrain)
	print("[TargetSV_B] TargetSV_B overlay ready [J to toggle]")


func _toggle_target_scene_voxel_overlay() -> void:
	if _target_sv_debug_terrain != null:
		_target_sv_debug_terrain.queue_free()
		_target_sv_debug_terrain = null
		_target_sv_debug_showing = false
		print("[TargetSV_B] TargetSV_B overlay: OFF")
		return
	if _target_sv_b_preview_image == null:
		_load_persisted_target_scene_voxel()
	if _target_sv_b_preview_image == null:
		print("[TargetSV_B] No persisted TargetSV_B found. Press Ctrl+J to recompute and save it.")
		return
	_build_target_scene_voxel_overlay()
	if _target_sv_debug_terrain != null:
		_target_sv_debug_terrain.visible = true
		_target_sv_debug_showing = true
		print("[TargetSV_B] TargetSV_B overlay: ON")


func _height_to_grayscale(img: Image, channel: int) -> Image:
	var out := _height_to_grayscale_gpu(img, channel)
	if out == null or out.is_empty():
		push_error("[MeshFill] Height grayscale GPU compute failed")
		return Image.create(1, 1, false, Image.FORMAT_RGBA8)
	return out


func _height_to_grayscale_gpu(img: Image, channel: int) -> Image:
	if img == null or img.is_empty():
		return null
	var width := img.get_width()
	var height := img.get_height()
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		return null
	probe_rd.free()

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "HeightToGrayscale"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return null
	var rd: RenderingDevice = compute.get_rendering_device()
	var minmax_shader := compute.load_compute_shader("res://shaders/height_channel_minmax.glsl")
	var minmax_pipeline := compute.create_compute_pipeline(minmax_shader)
	var gray_shader := compute.load_compute_shader("res://shaders/height_to_grayscale.glsl")
	var gray_pipeline := compute.create_compute_pipeline(gray_shader)
	if not minmax_shader.is_valid() or not minmax_pipeline.is_valid() or not gray_shader.is_valid() or not gray_pipeline.is_valid():
		compute.dispose()
		return null

	var height_tex := compute.upload_texture_2d(
		img,
		RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
		Image.FORMAT_RGBAF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"height_grayscale_src_rgba32f"
	)
	var minmax_bytes := PackedByteArray()
	minmax_bytes.resize(8)
	minmax_bytes.encode_s32(0, -1)
	var minmax_buf := compute.storage_buffer_from_bytes(minmax_bytes, ComputeShaderBaseScript.SCOPE_FRAME, "height_grayscale_minmax_u32")
	var out_tex := compute.create_rw_texture_2d(
		width,
		height,
		RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM,
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"height_grayscale_out_rgba8"
	)
	if not height_tex.is_valid() or not minmax_buf.is_valid() or not out_tex.is_valid():
		compute.dispose()
		return null

	var sampler := compute.create_linear_sampler()
	if not sampler.is_valid():
		compute.dispose()
		return null
	var minmax_set0 := compute.create_uniform_set([
		compute.make_sampler_uniform(0, sampler, height_tex),
	], minmax_shader, 0)
	var minmax_set1 := compute.create_uniform_set([
		compute.make_storage_uniform(0, minmax_buf),
	], minmax_shader, 1)
	var gray_set0 := compute.create_uniform_set([
		compute.make_sampler_uniform(0, sampler, height_tex),
		compute.make_storage_uniform(1, minmax_buf),
	], gray_shader, 0)
	var gray_set1 := compute.create_uniform_set([
		compute.make_image_uniform(0, out_tex),
	], gray_shader, 1)
	if not minmax_set0.is_valid() or not minmax_set1.is_valid() or not gray_set0.is_valid() or not gray_set1.is_valid():
		compute.dispose()
		return null

	var reduce_push := PackedByteArray()
	reduce_push.resize(16)
	reduce_push.encode_s32(0, width)
	reduce_push.encode_s32(4, height)
	reduce_push.encode_s32(8, clampi(channel, 0, 3))
	reduce_push.encode_s32(12, 0)

	var groups_x := ceili(float(width) / 32.0)
	var groups_y := ceili(float(height) / 32.0)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return null
	rd.compute_list_bind_compute_pipeline(cl, minmax_pipeline)
	rd.compute_list_bind_uniform_set(cl, minmax_set0, 0)
	rd.compute_list_bind_uniform_set(cl, minmax_set1, 1)
	rd.compute_list_set_push_constant(cl, reduce_push, reduce_push.size())
	rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var gray_push := PackedByteArray()
	gray_push.resize(16)
	gray_push.encode_s32(0, width)
	gray_push.encode_s32(4, height)
	gray_push.encode_s32(8, clampi(channel, 0, 3))
	gray_push.encode_float(12, 0.001)

	cl = compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return null
	rd.compute_list_bind_compute_pipeline(cl, gray_pipeline)
	rd.compute_list_bind_uniform_set(cl, gray_set0, 0)
	rd.compute_list_bind_uniform_set(cl, gray_set1, 1)
	rd.compute_list_set_push_constant(cl, gray_push, gray_push.size())
	rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var data := rd.texture_get_data(out_tex, 0)
	var result := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, data)
	compute.dispose()
	return result


func _height_diff_to_color(target_img: Image, current_img: Image) -> Image:
	var out := _height_diff_to_color_gpu(target_img, current_img)
	if out == null or out.is_empty():
		push_error("[MeshFill] Height diff color GPU compute failed")
		return Image.create(1, 1, false, Image.FORMAT_RGBA8)
	return out


func _current_height_mask_to_color(current_img: Image) -> Image:
	var out := _current_height_mask_to_color_gpu(current_img)
	if out == null or out.is_empty():
		push_error("[MeshFill] Current height mask color GPU compute failed")
		return Image.create(1, 1, false, Image.FORMAT_RGBA8)
	return out


func _current_height_mask_to_color_gpu(current_img: Image) -> Image:
	if current_img == null or current_img.is_empty():
		return null
	var width := current_img.get_width()
	var height := current_img.get_height()
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		return null
	probe_rd.free()

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "CurrentHeightMaskToColor"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return null
	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader("res://shaders/current_height_mask_vis.glsl")
	var pipeline := compute.create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return null

	var current_tex := compute.upload_texture_2d(
		current_img,
		RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
		Image.FORMAT_RGBAF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"current_height_mask_src_rgba32f"
	)
	var out_tex := compute.create_rw_texture_2d(
		width,
		height,
		RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM,
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"current_height_mask_color_rgba8"
	)
	if not current_tex.is_valid() or not out_tex.is_valid():
		compute.dispose()
		return null

	var sampler := compute.create_linear_sampler()
	if not sampler.is_valid():
		compute.dispose()
		return null
	var set0 := compute.create_uniform_set([
		compute.make_sampler_uniform(0, sampler, current_tex),
	], shader, 0)
	var set1 := compute.create_uniform_set([
		compute.make_image_uniform(0, out_tex),
	], shader, 1)
	if not set0.is_valid() or not set1.is_valid():
		compute.dispose()
		return null

	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, width)
	push.encode_s32(4, height)
	push.encode_float(8, 0.5)
	push.encode_float(12, 0.5)

	var groups_x := ceili(float(width) / 32.0)
	var groups_y := ceili(float(height) / 32.0)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return null
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_bind_uniform_set(cl, set1, 1)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var data := rd.texture_get_data(out_tex, 0)
	var result := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, data)
	compute.dispose()
	return result


func _height_diff_to_color_gpu(target_img: Image, current_img: Image) -> Image:
	if target_img == null or target_img.is_empty() or current_img == null or current_img.is_empty():
		return null
	var width := target_img.get_width()
	var height := target_img.get_height()
	if current_img.get_width() != width or current_img.get_height() != height:
		return null
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		return null
	probe_rd.free()

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "HeightDiffToColor"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return null
	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader("res://shaders/height_diff_to_color.glsl")
	var pipeline := compute.create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return null

	var target_tex := compute.upload_texture_2d(
		target_img,
		RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
		Image.FORMAT_RGBAF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"height_diff_target_rgba32f"
	)
	var current_tex := compute.upload_texture_2d(
		current_img,
		RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
		Image.FORMAT_RGBAF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"height_diff_current_rgba32f"
	)
	var out_tex := compute.create_rw_texture_2d(
		width,
		height,
		RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM,
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"height_diff_color_rgba8"
	)
	if not target_tex.is_valid() or not current_tex.is_valid() or not out_tex.is_valid():
		compute.dispose()
		return null

	var sampler := compute.create_linear_sampler()
	if not sampler.is_valid():
		compute.dispose()
		return null
	var set0 := compute.create_uniform_set([
		compute.make_sampler_uniform(0, sampler, target_tex),
		compute.make_sampler_uniform(1, sampler, current_tex),
	], shader, 0)
	var set1 := compute.create_uniform_set([
		compute.make_image_uniform(0, out_tex),
	], shader, 1)
	if not set0.is_valid() or not set1.is_valid():
		compute.dispose()
		return null

	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, width)
	push.encode_s32(4, height)
	push.encode_float(8, 5.0)
	push.encode_float(12, 0.5)

	var groups_x := ceili(float(width) / 32.0)
	var groups_y := ceili(float(height) / 32.0)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return null
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_bind_uniform_set(cl, set1, 1)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var data := rd.texture_get_data(out_tex, 0)
	var result := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, data)
	compute.dispose()
	return result


func _setup_diff_terrain(target_img: Image, current_img: Image) -> void:
	var res := target_img.get_width()
	var cell_size := capture_size / float(res)
	var half := capture_size / 2.0
	var target_values := _image_rgba32f_values(target_img)
	var current_values := _image_rgba32f_values(current_img)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	for y in range(res):
		for x in range(res):
			var value_index := (y * res + x) * 4
			var target_h := target_values[value_index] if value_index < target_values.size() else 0.0
			var current_h := current_values[value_index] if value_index < current_values.size() else 0.0
			var gen_mask := current_values[value_index + 2] if value_index + 2 < current_values.size() else 0.0
			var display_h := maxf(target_h, current_h) + 0.3
			var diff := current_h - target_h
			var t := clampf(absf(diff) / 5.0, 0.0, 1.0)
			var c: Color
			if gen_mask < 0.5:
				c = Color(0.3, 0.3, 0.3, 0.15)
			elif diff < -0.5:
				c = Color(0.0, 0.2, 1.0, 0.3 + t * 0.5)
			elif diff > 0.5:
				c = Color(1.0, 0.1, 0.0, 0.3 + t * 0.5)
			else:
				c = Color(0.0, 1.0, 0.2, 0.25)

			var px := float(x) * cell_size - half
			var pz := float(y) * cell_size - half
			st.set_color(c)
			st.set_uv(Vector2(float(x) / float(res - 1), float(y) / float(res - 1)))
			st.add_vertex(Vector3(px, display_h, pz))

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
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	_debug_diff_terrain = MeshInstance3D.new()
	_debug_diff_terrain.mesh = st.commit()
	_debug_diff_terrain.material_override = mat
	_debug_diff_terrain.name = "DebugHeightDiff"
	_debug_diff_terrain.visible = false
	_get_level_root().add_child(_debug_diff_terrain)
	print("[MeshFill] Height diff overlay ready [H to toggle]")


func _image_rgba32f_values(img: Image) -> PackedFloat32Array:
	if img == null or img.is_empty():
		return PackedFloat32Array()
	var src := img
	if src.get_format() != Image.FORMAT_RGBAF:
		src = img.duplicate()
		src.convert(Image.FORMAT_RGBAF)
	return src.get_data().to_float32_array()


# --- Override Delta / Brush / Visualization ---

func _init_override_images() -> void:
	_override_delta = Image.create(TEX_RES, TEX_RES, false, Image.FORMAT_RF)
	_override_delta.fill(Color(0.0, 0.0, 0.0, 0.0))
	_override_mask = Image.create(TEX_RES, TEX_RES, false, Image.FORMAT_RF)
	_override_mask.fill(Color(0.0, 0.0, 0.0, 0.0))
	_dep_terrain = Image.create(TEX_RES, TEX_RES, false, Image.FORMAT_RF)
	_dep_terrain.fill(Color(0.0, 0.0, 0.0, 0.0))
	_dep_object = Image.create(TEX_RES, TEX_RES, false, Image.FORMAT_RF)
	_dep_object.fill(Color(0.0, 0.0, 0.0, 0.0))
	_current_object_mask_img = Image.create(TEX_RES, TEX_RES, false, Image.FORMAT_RF)
	_current_object_mask_img.fill(Color(0.0, 0.0, 0.0, 0.0))
	_object_override_delta = Image.create(TEX_RES, TEX_RES, false, Image.FORMAT_RF)
	_object_override_delta.fill(Color(0.0, 0.0, 0.0, 0.0))
	_object_override_mask = Image.create(TEX_RES, TEX_RES, false, Image.FORMAT_RF)
	_object_override_mask.fill(Color(0.0, 0.0, 0.0, 0.0))


func _compute_terrain_avg_height(height_tex: ImageTexture) -> float:
	var img := height_tex.get_image()
	var result := _compute_terrain_avg_height_gpu(img)
	if result == null or not bool(result.get("valid", false)):
		push_error("[MeshFill] Terrain average height GPU compute failed")
		return 0.0
	return float(result.get("average", 0.0))


func _compute_terrain_avg_height_gpu(img: Image) -> Dictionary:
	if img == null or img.is_empty():
		return {}
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		return {}
	probe_rd.free()

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "TerrainAvgHeight"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return {}
	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader("res://shaders/terrain_avg_height.glsl")
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
		"terrain_avg_height_rgba32f"
	)
	var avg_buffer := compute.storage_buffer_zero(8, ComputeShaderBaseScript.SCOPE_FRAME, "terrain_avg_height_sum_count")
	if not height_tex.is_valid() or not avg_buffer.is_valid():
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
		compute.make_storage_uniform(0, avg_buffer),
	], shader, 1)
	if not set0.is_valid() or not set1.is_valid():
		compute.dispose()
		return {}

	var sample_step := 4
	var scale := 1000.0
	var sample_count_x := ceili(float(img.get_width()) / float(sample_step))
	var sample_count_y := ceili(float(img.get_height()) / float(sample_step))
	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, img.get_width())
	push.encode_s32(4, img.get_height())
	push.encode_s32(8, sample_step)
	push.encode_float(12, scale)

	var groups_x := ceili(float(sample_count_x) / 16.0)
	var groups_y := ceili(float(sample_count_y) / 16.0)
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

	var data := rd.buffer_get_data(avg_buffer, 0, 8)
	compute.dispose()
	if data.size() < 8:
		return {}
	var sum_scaled := data.decode_s32(0)
	var count := data.decode_s32(4)
	if count <= 0:
		return {}
	return {
		"valid": true,
		"average": float(sum_scaled) / scale / float(count),
		"count": count,
	}


func _setup_delta_overlay_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 99
	add_child(layer)

	_delta_panel = PanelContainer.new()
	_delta_panel.visible = false
	layer.add_child(_delta_panel)

	var vbox := VBoxContainer.new()
	_delta_panel.add_child(vbox)

	var title := Label.new()
	title.text = "Override Delta [V]"
	vbox.add_child(title)

	_delta_overlay = TextureRect.new()
	_delta_overlay.custom_minimum_size = Vector2(200, 200)
	_delta_overlay.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	vbox.add_child(_delta_overlay)

	_brush_label = Label.new()
	_brush_label.text = "[B] Toggle Brush"
	_brush_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_brush_label.custom_minimum_size = Vector2(220, 0)
	vbox.add_child(_brush_label)

	_add_brush_dimension_controls(vbox)
	call_deferred("_position_delta_panel")


func _position_delta_panel() -> void:
	if _delta_panel != null:
		var viewport := get_viewport()
		if viewport == null:
			return
		var vp_size := viewport.get_visible_rect().size
		_delta_panel.position = Vector2(maxf(vp_size.x - 280.0, 10.0), 10)


func _add_brush_dimension_controls(parent: VBoxContainer) -> void:
	var separator := HSeparator.new()
	parent.add_child(separator)

	var title := Label.new()
	title.text = "Brush Size"
	parent.add_child(title)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.custom_minimum_size = Vector2(220, 0)
	parent.add_child(grid)

	_brush_width_spin = _make_brush_size_spin(_brush_width, TEX_RES)
	_add_brush_size_row(grid, "Width X", _brush_width_spin)
	_brush_width_spin.value_changed.connect(_on_brush_width_changed)

	_brush_length_spin = _make_brush_size_spin(_brush_length, TEX_RES)
	_add_brush_size_row(grid, "Length Z", _brush_length_spin)
	_brush_length_spin.value_changed.connect(_on_brush_length_changed)

	_brush_height_spin = _make_brush_size_spin(_brush_height, TARGET_SV_SLICE_COUNT)
	_add_brush_size_row(grid, "Height Y", _brush_height_spin)
	_brush_height_spin.value_changed.connect(_on_brush_height_changed)


func _make_brush_size_spin(value: int, max_value: int) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = 1
	spin.max_value = maxi(max_value, 1)
	spin.step = 1
	spin.value = value
	spin.allow_greater = true
	spin.allow_lesser = false
	spin.custom_minimum_size = Vector2(104, 28)
	return spin


func _add_brush_size_row(grid: GridContainer, label_text: String, spin: SpinBox) -> void:
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(88, 24)
	grid.add_child(label)
	grid.add_child(spin)


func _on_brush_width_changed(new_value: float) -> void:
	_set_brush_dimensions(roundi(new_value), _brush_length, _brush_height)


func _on_brush_length_changed(new_value: float) -> void:
	_set_brush_dimensions(_brush_width, roundi(new_value), _brush_height)


func _on_brush_height_changed(new_value: float) -> void:
	_set_brush_dimensions(_brush_width, _brush_length, roundi(new_value))


func _nudge_brush_footprint(delta: int) -> void:
	_set_brush_dimensions(_brush_width + delta, _brush_length + delta, _brush_height)


func _set_brush_dimensions(width: int, length: int, height: int) -> void:
	_brush_width = clampi(width, 1, TEX_RES)
	_brush_length = clampi(length, 1, TEX_RES)
	_brush_height = maxi(height, 1)
	_sync_brush_radius_from_dimensions()
	_refresh_brush_dimension_controls()
	_update_brush_label()


func _sync_brush_radius_from_dimensions() -> void:
	_brush_radius = maxi(ceili(float(maxi(_brush_width, _brush_length)) * 0.5), 1)


func _refresh_brush_dimension_controls() -> void:
	if _brush_width_spin != null:
		_brush_width_spin.value = _brush_width
	if _brush_length_spin != null:
		_brush_length_spin.value = _brush_length
	if _brush_height_spin != null:
		_brush_height_spin.value = _brush_height


func _toggle_brush_mode() -> void:
	if _painting:
		_painting = false
		_finish_brush_stroke()
	_brush_active = not _brush_active
	if _brush_active:
		_tile_refresh_mode = false
	_update_brush_label()
	if _brush_active:
		if not _debug_delta_showing:
			_toggle_delta_overlay()
		var target_name := "Height" if _brush_target == BRUSH_TARGET_HEIGHT else "Object"
		print("[MeshFill] Brush: ON [%s]  LMB=+  RMB=-  N=switch target  Wheel=str  Shift+Wheel=size" % target_name)
	else:
		print("[MeshFill] Brush: OFF")


func _cycle_brush_target() -> void:
	if _brush_target == BRUSH_TARGET_HEIGHT:
		_brush_target = BRUSH_TARGET_OBJECT
	else:
		_brush_target = BRUSH_TARGET_HEIGHT
	_update_brush_label()
	if _debug_delta_showing:
		_update_delta_overlay()
	var target_name := "Height" if _brush_target == BRUSH_TARGET_HEIGHT else "Object"
	print("[MeshFill] Brush target: %s" % target_name)


func _update_brush_label() -> void:
	if _brush_label == null:
		return
	var target_name := "Height" if _brush_target == BRUSH_TARGET_HEIGHT else "Object"
	if _brush_active:
		_brush_label.text = "Brush ON [%s]\nStr %.1f | W %d L %d H %d\nLMB + / RMB - / N target" % [
			target_name,
			_brush_strength,
			_brush_width,
			_brush_length,
			_brush_height
		]
	elif _probe_inspect_mode:
		_brush_label.text = "Probe Inspect ON | Click terrain to sample TargetSV_B"
	elif _tile_refresh_mode:
		_brush_label.text = "Tile Refresh ON | Click to clear"
	else:
		_brush_label.text = "[B] Brush  [T] Tile  [I] Inspect\n[J] TargetSV_B  [Ctrl+J] Recompute\n[N] Target: %s" % target_name


func _toggle_delta_overlay() -> void:
	_debug_delta_showing = not _debug_delta_showing
	if _delta_panel != null:
		_delta_panel.visible = _debug_delta_showing
	if _debug_delta_showing:
		_update_delta_overlay()
		print("[MeshFill] Delta overlay: ON")
	else:
		print("[MeshFill] Delta overlay: OFF")


func _update_delta_overlay() -> void:
	if _delta_overlay == null:
		return
	var active_delta: Image = _override_delta if _brush_target == BRUSH_TARGET_HEIGHT else _object_override_delta
	if active_delta == null:
		return
	var heatmap := _delta_to_heatmap(active_delta)
	_delta_overlay.texture = ImageTexture.create_from_image(heatmap)

	var stats := _get_delta_stats()
	if _brush_label != null and _debug_delta_showing:
		var base := _brush_label.text
		if not base.contains("Min"):
			_brush_label.text = base + "\nMin: %.2f  Max: %.2f" % [stats.x, stats.y]


func _get_delta_stats() -> Vector2:
	var active_delta: Image = _override_delta if _brush_target == BRUSH_TARGET_HEIGHT else _object_override_delta
	if active_delta == null or active_delta.is_empty():
		return Vector2.ZERO
	var stats := _get_delta_stats_gpu(active_delta)
	if not bool(stats.get("valid", false)):
		push_error("[MeshFill] Delta stats GPU compute failed")
		return Vector2.ZERO
	return Vector2(float(stats.get("min", 0.0)), float(stats.get("max", 0.0)))


func _get_delta_stats_gpu(delta_img: Image) -> Dictionary:
	if delta_img == null or delta_img.is_empty():
		return {}
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		return {}
	probe_rd.free()

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "DeltaStats"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return {}
	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader("res://shaders/height_channel_minmax.glsl")
	var pipeline := compute.create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return {}

	var delta_tex := compute.upload_texture_2d(
		delta_img,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		Image.FORMAT_RF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"delta_stats_src_r32f"
	)
	var minmax_bytes := PackedByteArray()
	minmax_bytes.resize(8)
	minmax_bytes.encode_s32(0, -1)
	var minmax_buf := compute.storage_buffer_from_bytes(minmax_bytes, ComputeShaderBaseScript.SCOPE_FRAME, "delta_stats_minmax_u32")
	if not delta_tex.is_valid() or not minmax_buf.is_valid():
		compute.dispose()
		return {}

	var sampler := compute.create_linear_sampler()
	if not sampler.is_valid():
		compute.dispose()
		return {}
	var set0 := compute.create_uniform_set([
		compute.make_sampler_uniform(0, sampler, delta_tex),
	], shader, 0)
	var set1 := compute.create_uniform_set([
		compute.make_storage_uniform(0, minmax_buf),
	], shader, 1)
	if not set0.is_valid() or not set1.is_valid():
		compute.dispose()
		return {}

	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, delta_img.get_width())
	push.encode_s32(4, delta_img.get_height())
	push.encode_s32(8, 0)
	push.encode_s32(12, 0)

	var groups_x := ceili(float(delta_img.get_width()) / 32.0)
	var groups_y := ceili(float(delta_img.get_height()) / 32.0)
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

	var data := rd.buffer_get_data(minmax_buf, 0, 8)
	compute.dispose()
	if data.size() < 8:
		return {}
	return {
		"valid": true,
		"min": _ordered_uint_to_float(int(data.decode_u32(0))),
		"max": _ordered_uint_to_float(int(data.decode_u32(4))),
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


func _delta_to_heatmap(delta_img: Image) -> Image:
	var vis := _delta_to_heatmap_gpu(delta_img)
	if vis == null or vis.is_empty():
		push_error("[MeshFill] Delta heatmap GPU compute failed")
		return Image.create(1, 1, false, Image.FORMAT_RGBA8)
	return vis


func _delta_to_heatmap_gpu(delta_img: Image) -> Image:
	if delta_img == null or delta_img.is_empty():
		return null
	var width := delta_img.get_width()
	var height := delta_img.get_height()
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		return null
	probe_rd.free()

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "DeltaToHeatmap"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return null
	var rd: RenderingDevice = compute.get_rendering_device()
	var absmax_shader := compute.load_compute_shader("res://shaders/delta_absmax.glsl")
	var absmax_pipeline := compute.create_compute_pipeline(absmax_shader)
	var heatmap_shader := compute.load_compute_shader("res://shaders/delta_to_heatmap.glsl")
	var heatmap_pipeline := compute.create_compute_pipeline(heatmap_shader)
	if not absmax_shader.is_valid() or not absmax_pipeline.is_valid() or not heatmap_shader.is_valid() or not heatmap_pipeline.is_valid():
		compute.dispose()
		return null

	var delta_tex := compute.upload_texture_2d(
		delta_img,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		Image.FORMAT_RF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"delta_heatmap_src_r32f"
	)
	var absmax_bytes := PackedByteArray()
	absmax_bytes.resize(4)
	absmax_bytes.encode_float(0, 0.001)
	var absmax_buf := compute.storage_buffer_from_bytes(absmax_bytes, ComputeShaderBaseScript.SCOPE_FRAME, "delta_heatmap_absmax_bits")
	var out_tex := compute.create_rw_texture_2d(
		width,
		height,
		RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM,
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"delta_heatmap_out_rgba8"
	)
	if not delta_tex.is_valid() or not absmax_buf.is_valid() or not out_tex.is_valid():
		compute.dispose()
		return null

	var sampler := compute.create_linear_sampler()
	if not sampler.is_valid():
		compute.dispose()
		return null
	var absmax_set0 := compute.create_uniform_set([
		compute.make_sampler_uniform(0, sampler, delta_tex),
	], absmax_shader, 0)
	var absmax_set1 := compute.create_uniform_set([
		compute.make_storage_uniform(0, absmax_buf),
	], absmax_shader, 1)
	var heatmap_set0 := compute.create_uniform_set([
		compute.make_sampler_uniform(0, sampler, delta_tex),
		compute.make_storage_uniform(1, absmax_buf),
	], heatmap_shader, 0)
	var heatmap_set1 := compute.create_uniform_set([
		compute.make_image_uniform(0, out_tex),
	], heatmap_shader, 1)
	if not absmax_set0.is_valid() or not absmax_set1.is_valid() or not heatmap_set0.is_valid() or not heatmap_set1.is_valid():
		compute.dispose()
		return null

	var reduce_push := PackedByteArray()
	reduce_push.resize(16)
	reduce_push.encode_s32(0, width)
	reduce_push.encode_s32(4, height)
	reduce_push.encode_float(8, 0.0)
	reduce_push.encode_float(12, 0.0)

	var groups_x := ceili(float(width) / 32.0)
	var groups_y := ceili(float(height) / 32.0)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return null
	rd.compute_list_bind_compute_pipeline(cl, absmax_pipeline)
	rd.compute_list_bind_uniform_set(cl, absmax_set0, 0)
	rd.compute_list_bind_uniform_set(cl, absmax_set1, 1)
	rd.compute_list_set_push_constant(cl, reduce_push, reduce_push.size())
	rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var heatmap_push := PackedByteArray()
	heatmap_push.resize(16)
	heatmap_push.encode_s32(0, width)
	heatmap_push.encode_s32(4, height)
	heatmap_push.encode_float(8, 0.001)
	heatmap_push.encode_float(12, 0.0)

	cl = compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return null
	rd.compute_list_bind_compute_pipeline(cl, heatmap_pipeline)
	rd.compute_list_bind_uniform_set(cl, heatmap_set0, 0)
	rd.compute_list_bind_uniform_set(cl, heatmap_set1, 1)
	rd.compute_list_set_push_constant(cl, heatmap_push, heatmap_push.size())
	rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var data := rd.texture_get_data(out_tex, 0)
	var result := Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, data)
	compute.dispose()
	return result


func _begin_brush_stroke() -> void:
	_brush_dirty_rect = Rect2i()
	_brush_stroke_changed = false


func _finish_brush_stroke() -> void:
	if not _brush_stroke_changed and not _brush_voxel_commit_pending:
		_begin_brush_stroke()
		return

	var dirty_rect := _brush_dirty_rect
	if dirty_rect.size.x <= 0 or dirty_rect.size.y <= 0:
		dirty_rect = Rect2i(0, 0, TEX_RES, TEX_RES)

	var has_layer_edit := _brush_stroke_changed
	var has_voxel_edit := _brush_voxel_commit_pending
	_brush_stroke_changed = false
	_brush_voxel_commit_pending = false
	_brush_dirty_rect = Rect2i()
	_commit_brush_edit(dirty_rect, has_layer_edit, has_voxel_edit)


func _merge_dirty_rect(rect: Rect2i) -> void:
	var clipped := rect.intersection(Rect2i(0, 0, TEX_RES, TEX_RES))
	if clipped.size.x <= 0 or clipped.size.y <= 0:
		return
	if _brush_dirty_rect.size.x <= 0 or _brush_dirty_rect.size.y <= 0:
		_brush_dirty_rect = clipped
		return
	var min_x := mini(_brush_dirty_rect.position.x, clipped.position.x)
	var min_y := mini(_brush_dirty_rect.position.y, clipped.position.y)
	var max_x := maxi(_brush_dirty_rect.position.x + _brush_dirty_rect.size.x, clipped.position.x + clipped.size.x)
	var max_y := maxi(_brush_dirty_rect.position.y + _brush_dirty_rect.size.y, clipped.position.y + clipped.size.y)
	_brush_dirty_rect = Rect2i(min_x, min_y, max_x - min_x, max_y - min_y)


func _brush_footprint_rect(center: Vector2i, width: int = 0, length: int = 0) -> Rect2i:
	var safe_width := clampi(_brush_width if width <= 0 else width, 1, TEX_RES)
	var safe_length := clampi(_brush_length if length <= 0 else length, 1, TEX_RES)
	var left := int((safe_width - 1) / 2)
	var top := int((safe_length - 1) / 2)
	return Rect2i(
		Vector2i(center.x - left, center.y - top),
		Vector2i(safe_width, safe_length)
	)


func _mark_brush_dirty_footprint(center: Vector2i) -> void:
	_merge_dirty_rect(_brush_footprint_rect(center))
	_brush_stroke_changed = true


func _dirty_rect_with_margin(dirty_rect: Rect2i) -> Rect2i:
	if dirty_rect.size.x <= 0 or dirty_rect.size.y <= 0:
		return Rect2i(0, 0, TEX_RES, TEX_RES)
	var footprint_margin := ceili(float(maxi(_brush_width, _brush_length)) * 0.5)
	var margin := footprint_margin + 2
	return dirty_rect.grow(margin).intersection(Rect2i(0, 0, TEX_RES, TEX_RES))


func _get_scene_voxel_slice_count() -> int:
	if _scene_voxel_committer != null and _scene_voxel_committer.has_method("get_voxel_slice_count"):
		var count := int(_scene_voxel_committer.call("get_voxel_slice_count"))
		if count > 0:
			return count
	return TARGET_SV_SLICE_COUNT


func _brush_slice_indices() -> Array[int]:
	var total_slices := _get_scene_voxel_slice_count()
	var count := clampi(_brush_height, 1, total_slices)
	var indices: Array[int] = []
	for slice_index in range(count):
		indices.append(slice_index)
	return indices


func _base_rect_to_scene_voxel_bounds(base_rect: Rect2i, slice_indices: Array[int]) -> Dictionary:
	var grid := Vector3i(TEX_RES, maxi(slice_indices.size(), 1), TEX_RES)
	if _scene_voxel_committer != null:
		grid = _scene_voxel_committer.grid_size
	var clipped := base_rect.intersection(Rect2i(0, 0, TEX_RES, TEX_RES))
	if clipped.size.x <= 0 or clipped.size.y <= 0:
		return {}
	var min_x := clampi(floori(float(clipped.position.x) / float(TEX_RES) * float(grid.x)), 0, maxi(grid.x - 1, 0))
	var min_z := clampi(floori(float(clipped.position.y) / float(TEX_RES) * float(grid.z)), 0, maxi(grid.z - 1, 0))
	var max_x := clampi(ceili(float(clipped.position.x + clipped.size.x) / float(TEX_RES) * float(grid.x)), min_x + 1, maxi(grid.x, 1))
	var max_z := clampi(ceili(float(clipped.position.y + clipped.size.y) / float(TEX_RES) * float(grid.z)), min_z + 1, maxi(grid.z, 1))
	var min_y := 0
	var max_y := 1
	if not slice_indices.is_empty():
		min_y = grid.y
		max_y = 0
		for raw_slice in slice_indices:
			var slice_index := clampi(int(raw_slice), 0, maxi(grid.y - 1, 0))
			min_y = mini(min_y, slice_index)
			max_y = maxi(max_y, slice_index + 1)
		if max_y <= min_y:
			min_y = 0
			max_y = 1
	return {
		"voxel_min": Vector3i(min_x, min_y, min_z),
		"voxel_max": Vector3i(max_x, max_y, max_z),
	}


func _mark_brush_scene_voxel_bounds_dirty(base_rect: Rect2i) -> void:
	if _scene_voxel_committer == null:
		return
	var slice_indices := _brush_slice_indices()
	var source_record := {
		"id": "brush_ui_bounds",
		"source_voxel_type": "BrushSceneVoxel",
		"brush_size_voxels": Vector3i(_brush_width, _brush_height, _brush_length),
		"slice_indices": slice_indices.duplicate(),
	}
	if _scene_voxel_committer.has_method("mark_scene_voxel_tile_bounds_dirty"):
		var bounds := _base_rect_to_scene_voxel_bounds(base_rect, slice_indices)
		if not bounds.is_empty():
			_scene_voxel_committer.mark_scene_voxel_tile_bounds_dirty(
				bounds.voxel_min,
				bounds.voxel_max,
				{"brush": true, "scene": true, "collision": true},
				source_record
			)
	elif _scene_voxel_committer.has_method("invalidate_sv_rect"):
		_scene_voxel_committer.invalidate_sv_rect(base_rect, slice_indices, true)


func _commit_brush_edit(dirty_rect: Rect2i, update_generated_layers: bool = true, update_voxels: bool = true) -> void:
	var commit_rect := _dirty_rect_with_margin(dirty_rect)
	print("[MeshFill] Brush commit: dirty=%s target=%s size=%dx%dx%d" % [
		str(commit_rect),
		"Height" if _brush_target == BRUSH_TARGET_HEIGHT else "Object",
		_brush_width,
		_brush_length,
		_brush_height
	])

	if update_generated_layers:
		_regenerate()

	_mark_brush_scene_voxel_bounds_dirty(commit_rect)

	if update_voxels:
		var applied := _rebuild_scene_voxel_committer_from_scene_records(commit_rect)
		if applied > 0:
			print("[MeshFill] Brush commit: refreshed %d scene voxel_write_spec entries" % applied)


func _paint_at_screen(screen_pos: Vector2) -> void:
	var pixel := _screen_to_terrain_pixel(screen_pos)
	if pixel.x < 0:
		return
	var sign_val := 1.0 if _paint_positive else -1.0
	_paint_brush_footprint(pixel, _brush_strength * sign_val)
	_mark_brush_dirty_footprint(pixel)
	if _debug_delta_showing:
		_update_delta_overlay()


func _screen_to_terrain_pixel(screen_pos: Vector2) -> Vector2i:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return Vector2i(-1, -1)
	var from := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	if absf(dir.y) < 0.001:
		return Vector2i(-1, -1)
	var t := (_terrain_hit_y - from.y) / dir.y
	if t < 0.0:
		return Vector2i(-1, -1)
	var hit := from + dir * t
	var half := capture_size / 2.0
	var px_x := int((hit.x + half) / capture_size * float(TEX_RES))
	var px_y := int((hit.z + half) / capture_size * float(TEX_RES))
	if px_x < 0 or px_x >= TEX_RES or px_y < 0 or px_y >= TEX_RES:
		return Vector2i(-1, -1)
	return Vector2i(px_x, px_y)


func _paint_brush_footprint(center: Vector2i, strength: float) -> void:
	var terrain_img: Image = null
	if not _cached_textures.is_empty() and _cached_textures.has("scene_depth"):
		terrain_img = _cached_textures["scene_depth"].get_image()
	var delta_img: Image = _override_delta if _brush_target == BRUSH_TARGET_HEIGHT else _object_override_delta
	var mask_img: Image = _override_mask if _brush_target == BRUSH_TARGET_HEIGHT else _object_override_mask
	var footprint := _brush_footprint_rect(center).intersection(Rect2i(0, 0, TEX_RES, TEX_RES))
	if footprint.size.x <= 0 or footprint.size.y <= 0:
		return
	var half_x := maxf(float(_brush_width - 1) * 0.5, 1.0)
	var half_z := maxf(float(_brush_length - 1) * 0.5, 1.0)
	var paint_result := _paint_brush_footprint_gpu(center, footprint, strength, terrain_img, delta_img, mask_img, _brush_target)
	if paint_result.is_empty():
		push_error("[MeshFill] Brush footprint GPU compute failed")
		return
	if _brush_target == BRUSH_TARGET_HEIGHT:
		_override_delta = paint_result.get("delta", _override_delta)
		_override_mask = paint_result.get("mask", _override_mask)
	else:
		_object_override_delta = paint_result.get("delta", _object_override_delta)
		_object_override_mask = paint_result.get("mask", _object_override_mask)
	_dep_terrain = paint_result.get("dep_terrain", _dep_terrain)
	_dep_object = paint_result.get("dep_rock", _dep_object)


func _paint_brush_footprint_gpu(
	center: Vector2i,
	footprint: Rect2i,
	strength: float,
	terrain_img: Image,
	delta_img: Image,
	mask_img: Image,
	target_mode: int
) -> Dictionary:
	if delta_img == null or delta_img.is_empty() or mask_img == null or mask_img.is_empty() \
			or _dep_terrain == null or _dep_terrain.is_empty() or _dep_object == null or _dep_object.is_empty():
		return {}
	var scene_depth_img := terrain_img
	var has_scene_depth := scene_depth_img != null and not scene_depth_img.is_empty()
	if not has_scene_depth:
		scene_depth_img = Image.create(TEX_RES, TEX_RES, false, Image.FORMAT_RGBAF)
		scene_depth_img.fill(Color(max_height, 0.0, 0.0, 1.0))
	var current_rock_img := _current_object_mask_img
	var has_current_rock := current_rock_img != null and not current_rock_img.is_empty()
	if not has_current_rock:
		current_rock_img = Image.create(TEX_RES, TEX_RES, false, Image.FORMAT_RF)
		current_rock_img.fill(Color(0.0, 0.0, 0.0, 0.0))

	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		return {}
	probe_rd.free()

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "PaintBrushFootprint"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return {}
	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader("res://shaders/paint_brush_footprint.glsl")
	var pipeline := compute.create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return {}

	var input_specs := [
		{"image": delta_img, "format": RenderingDevice.DATA_FORMAT_R32_SFLOAT, "image_format": Image.FORMAT_RF, "label": "delta"},
		{"image": mask_img, "format": RenderingDevice.DATA_FORMAT_R32_SFLOAT, "image_format": Image.FORMAT_RF, "label": "mask"},
		{"image": _dep_terrain, "format": RenderingDevice.DATA_FORMAT_R32_SFLOAT, "image_format": Image.FORMAT_RF, "label": "dep_terrain"},
		{"image": _dep_object, "format": RenderingDevice.DATA_FORMAT_R32_SFLOAT, "image_format": Image.FORMAT_RF, "label": "dep_rock"},
		{"image": scene_depth_img, "format": RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, "image_format": Image.FORMAT_RGBAF, "label": "scene_depth"},
		{"image": current_rock_img, "format": RenderingDevice.DATA_FORMAT_R32_SFLOAT, "image_format": Image.FORMAT_RF, "label": "current_rock"},
	]
	var input_textures: Array[RID] = []
	for i in range(input_specs.size()):
		var spec: Dictionary = input_specs[i]
		var tex := compute.upload_texture_2d(
			spec.image,
			int(spec.format),
			int(spec.image_format),
			RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
			ComputeShaderBaseScript.SCOPE_FRAME,
			"paint_brush_%s" % str(spec.label)
		)
		if not tex.is_valid():
			compute.dispose()
			return {}
		input_textures.append(tex)

	var out_textures: Array[RID] = []
	for i in range(4):
		var tex := compute.create_rw_texture_2d(
			TEX_RES,
			TEX_RES,
			RenderingDevice.DATA_FORMAT_R32_SFLOAT,
			RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT,
			ComputeShaderBaseScript.SCOPE_FRAME,
			"paint_brush_out_%d_r32f" % i
		)
		if not tex.is_valid():
			compute.dispose()
			return {}
		out_textures.append(tex)

	var sampler := compute.create_linear_sampler()
	if not sampler.is_valid():
		compute.dispose()
		return {}
	var set0_uniforms: Array = []
	for i in range(input_textures.size()):
		set0_uniforms.append(compute.make_sampler_uniform(i, sampler, input_textures[i]))
	var set1_uniforms: Array = []
	for i in range(out_textures.size()):
		set1_uniforms.append(compute.make_image_uniform(i, out_textures[i]))
	var set0 := compute.create_uniform_set(set0_uniforms, shader, 0)
	var set1 := compute.create_uniform_set(set1_uniforms, shader, 1)
	if not set0.is_valid() or not set1.is_valid():
		compute.dispose()
		return {}

	var push := PackedByteArray()
	push.resize(64)
	push.encode_s32(0, TEX_RES)
	push.encode_s32(4, TEX_RES)
	push.encode_s32(8, center.x)
	push.encode_s32(12, center.y)
	push.encode_s32(16, footprint.position.x)
	push.encode_s32(20, footprint.position.y)
	push.encode_s32(24, footprint.size.x)
	push.encode_s32(28, footprint.size.y)
	push.encode_s32(32, _brush_width)
	push.encode_s32(36, _brush_length)
	push.encode_s32(40, target_mode)
	push.encode_s32(44, 1 if has_scene_depth else 0)
	push.encode_s32(48, 1 if has_current_rock else 0)
	push.encode_float(52, strength)
	push.encode_float(56, max_height)
	push.encode_float(60, 0.0)

	var groups := ceili(float(TEX_RES) / 32.0)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return {}
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_bind_uniform_set(cl, set1, 1)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, groups, groups, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var out_images: Array[Image] = []
	for tex in out_textures:
		var data := rd.texture_get_data(tex, 0)
		out_images.append(Image.create_from_data(TEX_RES, TEX_RES, false, Image.FORMAT_RF, data))
	compute.dispose()
	return {
		"delta": out_images[0],
		"mask": out_images[1],
		"dep_terrain": out_images[2],
		"dep_rock": out_images[3],
	}


# --- Tile Refresh Tool ---

func _toggle_tile_refresh_mode() -> void:
	if _painting:
		_painting = false
		_finish_brush_stroke()
	_tile_refresh_mode = not _tile_refresh_mode
	if _tile_refresh_mode:
		_brush_active = false
		_update_brush_label()
		print("[MeshFill] Tile Refresh: ON 鈥?click a tile to clear its overrides and regenerate")
	else:
		print("[MeshFill] Tile Refresh: OFF")


func _tile_refresh_at_screen(screen_pos: Vector2) -> void:
	var pixel := _screen_to_terrain_pixel(screen_pos)
	if pixel.x < 0:
		return
	var tile_origin := Vector2i(
		(pixel.x / TILE_SIZE) * TILE_SIZE,
		(pixel.y / TILE_SIZE) * TILE_SIZE
	)
	var tile_rect := Rect2i(tile_origin, Vector2i(TILE_SIZE, TILE_SIZE))
	tile_rect = tile_rect.intersection(Rect2i(0, 0, TEX_RES, TEX_RES))
	if tile_rect.size.x <= 0 or tile_rect.size.y <= 0:
		return

	_push_undo_snapshot()

	var clear_result := _clear_override_tile_gpu(tile_rect)
	if clear_result.is_empty():
		push_error("[MeshFill] Tile override clear GPU compute failed")
		return
	_override_mask = clear_result.get("override_mask", _override_mask)
	_override_delta = clear_result.get("override_delta", _override_delta)
	_dep_terrain = clear_result.get("dep_terrain", _dep_terrain)
	_dep_object = clear_result.get("dep_rock", _dep_object)
	_object_override_mask = clear_result.get("rock_override_mask", _object_override_mask)
	_object_override_delta = clear_result.get("rock_override_delta", _object_override_delta)
	var cleared := int(clear_result.get("cleared", 0))

	print("[MeshFill] Tile [%d,%d]: cleared %d override pixels" % [
		tile_origin.x / TILE_SIZE, tile_origin.y / TILE_SIZE, cleared])

	if _debug_delta_showing:
		_update_delta_overlay()


func _clear_override_tile_gpu(tile_rect: Rect2i) -> Dictionary:
	if tile_rect.size.x <= 0 or tile_rect.size.y <= 0:
		return {}
	if _override_mask == null or _override_delta == null or _dep_terrain == null or _dep_object == null \
			or _object_override_mask == null or _object_override_delta == null:
		return {}
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		return {}
	probe_rd.free()

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "ClearOverrideTile"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return {}
	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader("res://shaders/clear_override_tile.glsl")
	var pipeline := compute.create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return {}

	var src_images := [_override_mask, _override_delta, _dep_terrain, _dep_object, _object_override_mask, _object_override_delta]
	var src_textures: Array[RID] = []
	for i in range(src_images.size()):
		var img: Image = src_images[i]
		if img == null or img.is_empty():
			compute.dispose()
			return {}
		var tex := compute.upload_texture_2d(
			img,
			RenderingDevice.DATA_FORMAT_R32_SFLOAT,
			Image.FORMAT_RF,
			RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
			ComputeShaderBaseScript.SCOPE_FRAME,
			"clear_override_tile_src_%d_r32f" % i
		)
		if not tex.is_valid():
			compute.dispose()
			return {}
		src_textures.append(tex)

	var out_textures: Array[RID] = []
	for i in range(6):
		var tex := compute.create_rw_texture_2d(
			TEX_RES,
			TEX_RES,
			RenderingDevice.DATA_FORMAT_R32_SFLOAT,
			RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT,
			ComputeShaderBaseScript.SCOPE_FRAME,
			"clear_override_tile_out_%d_r32f" % i
		)
		if not tex.is_valid():
			compute.dispose()
			return {}
		out_textures.append(tex)
	var counter_buf := compute.storage_buffer_zero(4, ComputeShaderBaseScript.SCOPE_FRAME, "clear_override_tile_counter_u32")
	if not counter_buf.is_valid():
		compute.dispose()
		return {}

	var sampler := compute.create_linear_sampler()
	if not sampler.is_valid():
		compute.dispose()
		return {}
	var set0_uniforms: Array = []
	for i in range(src_textures.size()):
		set0_uniforms.append(compute.make_sampler_uniform(i, sampler, src_textures[i]))
	var set1_uniforms: Array = []
	for i in range(out_textures.size()):
		set1_uniforms.append(compute.make_image_uniform(i, out_textures[i]))
	set1_uniforms.append(compute.make_storage_uniform(6, counter_buf))
	var set0 := compute.create_uniform_set(set0_uniforms, shader, 0)
	var set1 := compute.create_uniform_set(set1_uniforms, shader, 1)
	if not set0.is_valid() or not set1.is_valid():
		compute.dispose()
		return {}

	var push := PackedByteArray()
	push.resize(32)
	push.encode_s32(0, TEX_RES)
	push.encode_s32(4, TEX_RES)
	push.encode_s32(8, tile_rect.position.x)
	push.encode_s32(12, tile_rect.position.y)
	push.encode_s32(16, tile_rect.size.x)
	push.encode_s32(20, tile_rect.size.y)
	push.encode_float(24, 0.01)
	push.encode_float(28, 0.0)

	var groups := ceili(float(TEX_RES) / 32.0)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return {}
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_bind_uniform_set(cl, set1, 1)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, groups, groups, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var out_images: Array[Image] = []
	for tex in out_textures:
		var data := rd.texture_get_data(tex, 0)
		out_images.append(Image.create_from_data(TEX_RES, TEX_RES, false, Image.FORMAT_RF, data))
	var counter_data := rd.buffer_get_data(counter_buf, 0, 4)
	compute.dispose()
	var cleared := (int(counter_data.decode_u32(0)) if counter_data.size() >= 4 else 0)
	return {
		"override_mask": out_images[0],
		"override_delta": out_images[1],
		"dep_terrain": out_images[2],
		"dep_rock": out_images[3],
		"rock_override_mask": out_images[4],
		"rock_override_delta": out_images[5],
		"cleared": cleared,
	}


# --- Undo System (3 steps) ---

func _push_undo_snapshot() -> void:
	if _override_delta == null or _override_mask == null:
		return
	var snapshot := {
		"delta": _override_delta.duplicate(),
		"mask": _override_mask.duplicate(),
		"dep_terrain": _dep_terrain.duplicate(),
		"dep_rock": _dep_object.duplicate(),
		"rock_delta": _object_override_delta.duplicate(),
		"object_mask": _object_override_mask.duplicate(),
	}
	_undo_stack.append(snapshot)
	if _undo_stack.size() > UNDO_MAX_STEPS:
		_undo_stack.remove_at(0)


func _undo_override() -> void:
	if _undo_stack.is_empty():
		print("[MeshFill] Undo: nothing to undo")
		return
	var snapshot: Dictionary = _undo_stack.pop_back()
	_override_delta = snapshot["delta"]
	_override_mask = snapshot["mask"]
	_dep_terrain = snapshot["dep_terrain"]
	_dep_object = snapshot["dep_rock"]
	_object_override_delta = snapshot["rock_delta"]
	_object_override_mask = snapshot["object_mask"]
	print("[MeshFill] Undo: restored (%d steps remaining)" % _undo_stack.size())
	if _debug_delta_showing:
		_update_delta_overlay()
	_commit_brush_edit(Rect2i(0, 0, TEX_RES, TEX_RES), true, true)


# --- Override Invalidation & Composition ---

func _invalidate_overrides() -> void:
	if _cached_textures.is_empty() or _override_mask == null:
		return
	var terrain_tex: ImageTexture = _cached_textures["scene_depth"]
	var terrain_img: Image = terrain_tex.get_image()
	var result := _invalidate_overrides_gpu(terrain_img)
	if result.is_empty():
		push_error("[MeshFill] Override invalidation GPU compute failed")
		return
	_override_mask = result.get("override_mask", _override_mask)
	_override_delta = result.get("override_delta", _override_delta)
	_dep_terrain = result.get("dep_terrain", _dep_terrain)
	_dep_object = result.get("dep_rock", _dep_object)
	var invalidated := int(result.get("invalidated", 0))
	if invalidated > 0:
		print("[MeshFill] Override: invalidated %d pixels (terrain/object change)" % invalidated)
		if _debug_delta_showing:
			_update_delta_overlay()


func _invalidate_overrides_gpu(terrain_img: Image) -> Dictionary:
	if terrain_img == null or terrain_img.is_empty() \
			or _override_mask == null or _override_mask.is_empty() \
			or _override_delta == null or _override_delta.is_empty() \
			or _dep_terrain == null or _dep_terrain.is_empty() \
			or _dep_object == null or _dep_object.is_empty() \
			or _current_object_mask_img == null or _current_object_mask_img.is_empty():
		return {}
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		return {}
	probe_rd.free()

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "OverrideInvalidation"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return {}
	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader("res://shaders/override_invalidation.glsl")
	var pipeline := compute.create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return {}

	var terrain_tex := compute.upload_texture_2d(
		terrain_img,
		RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
		Image.FORMAT_RGBAF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"override_invalidation_scene_depth_rgba32f"
	)
	var override_mask_tex := compute.upload_texture_2d(
		_override_mask,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		Image.FORMAT_RF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"override_invalidation_mask_r32f"
	)
	var override_delta_tex := compute.upload_texture_2d(
		_override_delta,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		Image.FORMAT_RF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"override_invalidation_delta_r32f"
	)
	var dep_terrain_tex := compute.upload_texture_2d(
		_dep_terrain,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		Image.FORMAT_RF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"override_invalidation_dep_terrain_r32f"
	)
	var dep_rock_tex := compute.upload_texture_2d(
		_dep_object,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		Image.FORMAT_RF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"override_invalidation_dep_object_r32f"
	)
	var current_rock_tex := compute.upload_texture_2d(
		_current_object_mask_img,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		Image.FORMAT_RF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"override_invalidation_current_rock_r32f"
	)
	var out_mask_tex := compute.create_rw_texture_2d(TEX_RES, TEX_RES, RenderingDevice.DATA_FORMAT_R32_SFLOAT, RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT, ComputeShaderBaseScript.SCOPE_FRAME, "override_invalidation_out_mask_r32f")
	var out_delta_tex := compute.create_rw_texture_2d(TEX_RES, TEX_RES, RenderingDevice.DATA_FORMAT_R32_SFLOAT, RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT, ComputeShaderBaseScript.SCOPE_FRAME, "override_invalidation_out_delta_r32f")
	var out_dep_terrain_tex := compute.create_rw_texture_2d(TEX_RES, TEX_RES, RenderingDevice.DATA_FORMAT_R32_SFLOAT, RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT, ComputeShaderBaseScript.SCOPE_FRAME, "override_invalidation_out_dep_terrain_r32f")
	var out_dep_object_tex := compute.create_rw_texture_2d(TEX_RES, TEX_RES, RenderingDevice.DATA_FORMAT_R32_SFLOAT, RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT, ComputeShaderBaseScript.SCOPE_FRAME, "override_invalidation_out_dep_object_r32f")
	var counter_buf := compute.storage_buffer_zero(4, ComputeShaderBaseScript.SCOPE_FRAME, "override_invalidation_counter_u32")
	if not terrain_tex.is_valid() or not override_mask_tex.is_valid() or not override_delta_tex.is_valid() \
			or not dep_terrain_tex.is_valid() or not dep_rock_tex.is_valid() or not current_rock_tex.is_valid() \
			or not out_mask_tex.is_valid() or not out_delta_tex.is_valid() or not out_dep_terrain_tex.is_valid() \
			or not out_dep_object_tex.is_valid() or not counter_buf.is_valid():
		compute.dispose()
		return {}

	var sampler := compute.create_linear_sampler()
	if not sampler.is_valid():
		compute.dispose()
		return {}
	var set0 := compute.create_uniform_set([
		compute.make_sampler_uniform(0, sampler, terrain_tex),
		compute.make_sampler_uniform(1, sampler, override_mask_tex),
		compute.make_sampler_uniform(2, sampler, override_delta_tex),
		compute.make_sampler_uniform(3, sampler, dep_terrain_tex),
		compute.make_sampler_uniform(4, sampler, dep_rock_tex),
		compute.make_sampler_uniform(5, sampler, current_rock_tex),
	], shader, 0)
	var set1 := compute.create_uniform_set([
		compute.make_image_uniform(0, out_mask_tex),
		compute.make_image_uniform(1, out_delta_tex),
		compute.make_image_uniform(2, out_dep_terrain_tex),
		compute.make_image_uniform(3, out_dep_object_tex),
		compute.make_storage_uniform(4, counter_buf),
	], shader, 1)
	if not set0.is_valid() or not set1.is_valid():
		compute.dispose()
		return {}

	var push := PackedByteArray()
	push.resize(32)
	push.encode_s32(0, TEX_RES)
	push.encode_s32(4, TEX_RES)
	push.encode_float(8, max_height)
	push.encode_float(12, 0.5)
	push.encode_float(16, 0.1)
	push.encode_float(20, 0.5)
	push.encode_float(24, 0.0)
	push.encode_float(28, 0.0)

	var groups := ceili(float(TEX_RES) / 32.0)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return {}
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_bind_uniform_set(cl, set1, 1)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, groups, groups, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var mask_data := rd.texture_get_data(out_mask_tex, 0)
	var delta_data := rd.texture_get_data(out_delta_tex, 0)
	var dep_terrain_data := rd.texture_get_data(out_dep_terrain_tex, 0)
	var dep_rock_data := rd.texture_get_data(out_dep_object_tex, 0)
	var counter_data := rd.buffer_get_data(counter_buf, 0, 4)
	var invalidated := (int(counter_data.decode_u32(0)) if counter_data.size() >= 4 else 0)
	compute.dispose()
	return {
		"override_mask": Image.create_from_data(TEX_RES, TEX_RES, false, Image.FORMAT_RF, mask_data),
		"override_delta": Image.create_from_data(TEX_RES, TEX_RES, false, Image.FORMAT_RF, delta_data),
		"dep_terrain": Image.create_from_data(TEX_RES, TEX_RES, false, Image.FORMAT_RF, dep_terrain_data),
		"dep_rock": Image.create_from_data(TEX_RES, TEX_RES, false, Image.FORMAT_RF, dep_rock_data),
		"invalidated": invalidated,
	}


func _has_mask_pixels(mask_img: Image, threshold: float = 0.01) -> bool:
	if mask_img == null or mask_img.is_empty():
		return false
	var result := _has_mask_pixels_gpu(mask_img, threshold)
	if result < 0:
		push_error("[MeshFill] Mask occupancy GPU compute failed")
		return false
	return result > 0


func _has_mask_pixels_gpu(mask_img: Image, threshold: float = 0.01) -> int:
	if mask_img == null or mask_img.is_empty():
		return 0
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		return -1
	probe_rd.free()

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "MaskHasPixels"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return -1
	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader("res://shaders/mask_has_pixels.glsl")
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
		"mask_has_pixels_src_r32f"
	)
	var counter_buf := compute.storage_buffer_zero(4, ComputeShaderBaseScript.SCOPE_FRAME, "mask_has_pixels_counter_u32")
	if not mask_tex.is_valid() or not counter_buf.is_valid():
		compute.dispose()
		return -1

	var sampler := compute.create_linear_sampler()
	if not sampler.is_valid():
		compute.dispose()
		return -1
	var set0 := compute.create_uniform_set([
		compute.make_sampler_uniform(0, sampler, mask_tex),
	], shader, 0)
	var set1 := compute.create_uniform_set([
		compute.make_storage_uniform(0, counter_buf),
	], shader, 1)
	if not set0.is_valid() or not set1.is_valid():
		compute.dispose()
		return -1

	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, mask_img.get_width())
	push.encode_s32(4, mask_img.get_height())
	push.encode_float(8, threshold)
	push.encode_float(12, 0.0)

	var groups_x := ceili(float(mask_img.get_width()) / 32.0)
	var groups_y := ceili(float(mask_img.get_height()) / 32.0)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return -1
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_bind_uniform_set(cl, set1, 1)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var counter_data := rd.buffer_get_data(counter_buf, 0, 4)
	var hit_count := (int(counter_data.decode_u32(0)) if counter_data.size() >= 4 else -1)
	compute.dispose()
	return hit_count


func _composite_target_height() -> ImageTexture:
	if not _has_mask_pixels(_override_mask):
		return _cached_textures["target_height"] as ImageTexture

	var src_tex: ImageTexture = _cached_textures["target_height"]
	var base_img: Image = src_tex.get_image()
	var composited_img := _composite_target_height_gpu(base_img, _override_mask, _override_delta)
	if composited_img == null or composited_img.is_empty():
		push_error("[MeshFill] Target height override GPU compute failed")
		return src_tex
	print("[MeshFill] Override: composited target_height on GPU")
	return ImageTexture.create_from_image(composited_img)


func _composite_target_height_gpu(base_img: Image, mask_img: Image, delta_img: Image) -> Image:
	if base_img == null or base_img.is_empty() or mask_img == null or mask_img.is_empty() or delta_img == null or delta_img.is_empty():
		return null
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		return null
	probe_rd.free()

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "TargetHeightOverrideComposite"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return null
	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader("res://shaders/target_height_override_composite.glsl")
	var pipeline := compute.create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return null

	var base_tex := compute.upload_texture_2d(
		base_img,
		RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
		Image.FORMAT_RGBAF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"target_height_base_rgba32f"
	)
	var mask_tex := compute.upload_texture_2d(
		mask_img,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		Image.FORMAT_RF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"target_height_override_mask_r32f"
	)
	var delta_tex := compute.upload_texture_2d(
		delta_img,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		Image.FORMAT_RF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"target_height_override_delta_r32f"
	)
	var out_tex := compute.create_rw_texture_2d(
		base_img.get_width(),
		base_img.get_height(),
		RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"target_height_override_out_rgba32f"
	)
	if not base_tex.is_valid() or not mask_tex.is_valid() or not delta_tex.is_valid() or not out_tex.is_valid():
		compute.dispose()
		return null

	var sampler := compute.create_linear_sampler()
	if not sampler.is_valid():
		compute.dispose()
		return null
	var set0 := compute.create_uniform_set([
		compute.make_sampler_uniform(0, sampler, base_tex),
		compute.make_sampler_uniform(1, sampler, mask_tex),
		compute.make_sampler_uniform(2, sampler, delta_tex),
	], shader, 0)
	var set1 := compute.create_uniform_set([
		compute.make_image_uniform(0, out_tex),
	], shader, 1)
	if not set0.is_valid() or not set1.is_valid():
		compute.dispose()
		return null

	var push := PackedByteArray()
	push.resize(32)
	push.encode_s32(0, base_img.get_width())
	push.encode_s32(4, base_img.get_height())
	push.encode_s32(8, mask_img.get_width())
	push.encode_s32(12, mask_img.get_height())
	push.encode_float(16, 0.01)
	push.encode_float(20, 0.0)
	push.encode_float(24, 0.0)
	push.encode_float(28, 0.0)

	var groups_x := ceili(float(base_img.get_width()) / 32.0)
	var groups_y := ceili(float(base_img.get_height()) / 32.0)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return null
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_bind_uniform_set(cl, set1, 1)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var data := rd.texture_get_data(out_tex, 0)
	var result := Image.create_from_data(base_img.get_width(), base_img.get_height(), false, Image.FORMAT_RGBAF, data)
	compute.dispose()
	return result


func _composite_object_mask() -> Image:
	var base_img: Image
	if _current_object_mask_img != null:
		base_img = _current_object_mask_img.duplicate()
	else:
		base_img = Image.create(TEX_RES, TEX_RES, false, Image.FORMAT_RF)
		base_img.fill(Color(0.0, 0.0, 0.0, 0.0))
	if not _has_mask_pixels(_object_override_mask):
		return base_img
	var composited_img := _composite_object_mask_gpu(base_img, _object_override_mask, _object_override_delta)
	if composited_img == null or composited_img.is_empty():
		push_error("[MeshFill] Object mask override GPU compute failed")
		return base_img
	print("[MeshFill] Override: composited object_mask on GPU")
	return composited_img


func _composite_object_mask_gpu(base_img: Image, mask_img: Image, delta_img: Image) -> Image:
	if base_img == null or base_img.is_empty() or mask_img == null or mask_img.is_empty() or delta_img == null or delta_img.is_empty():
		return null
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		return null
	probe_rd.free()

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "RockMaskOverrideComposite"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return null
	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader("res://shaders/rock_mask_override_composite.glsl")
	var pipeline := compute.create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return null

	var base_tex := compute.upload_texture_2d(
		base_img,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		Image.FORMAT_RF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"rock_mask_base_r32f"
	)
	var mask_tex := compute.upload_texture_2d(
		mask_img,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		Image.FORMAT_RF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"rock_mask_override_mask_r32f"
	)
	var delta_tex := compute.upload_texture_2d(
		delta_img,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		Image.FORMAT_RF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"rock_mask_override_delta_r32f"
	)
	var out_tex := compute.create_rw_texture_2d(
		base_img.get_width(),
		base_img.get_height(),
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"rock_mask_override_out_r32f"
	)
	if not base_tex.is_valid() or not mask_tex.is_valid() or not delta_tex.is_valid() or not out_tex.is_valid():
		compute.dispose()
		return null

	var sampler := compute.create_linear_sampler()
	if not sampler.is_valid():
		compute.dispose()
		return null
	var set0 := compute.create_uniform_set([
		compute.make_sampler_uniform(0, sampler, base_tex),
		compute.make_sampler_uniform(1, sampler, mask_tex),
		compute.make_sampler_uniform(2, sampler, delta_tex),
	], shader, 0)
	var set1 := compute.create_uniform_set([
		compute.make_image_uniform(0, out_tex),
	], shader, 1)
	if not set0.is_valid() or not set1.is_valid():
		compute.dispose()
		return null

	var push := PackedByteArray()
	push.resize(32)
	push.encode_s32(0, base_img.get_width())
	push.encode_s32(4, base_img.get_height())
	push.encode_s32(8, mask_img.get_width())
	push.encode_s32(12, mask_img.get_height())
	push.encode_float(16, 0.01)
	push.encode_float(20, 0.0)
	push.encode_float(24, 0.0)
	push.encode_float(28, 0.0)

	var groups_x := ceili(float(base_img.get_width()) / 32.0)
	var groups_y := ceili(float(base_img.get_height()) / 32.0)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return null
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_bind_uniform_set(cl, set1, 1)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var data := rd.texture_get_data(out_tex, 0)
	var result := Image.create_from_data(base_img.get_width(), base_img.get_height(), false, Image.FORMAT_RF, data)
	compute.dispose()
	return result


# --- Texture loading with procedural fallback ---

func _load_terrain_textures() -> Dictionary:
	return TerrainInitializerScript.load_terrain_textures(TEX_RES, max_height)


# --- Object mask capture (tag mechanism) ---

func _load_previous_object_mask() -> Texture2D:
	var path := object_mask_path
	if path.is_empty():
		path = OS.get_user_data_dir() + "/object_placement_mask.png"
	if not FileAccess.file_exists(path):
		print("[MeshFill] No previous object mask found at: %s" % path)
		return null
	var img := Image.load_from_file(path)
	if img == null:
		push_warning("[MeshFill] Failed to load object mask: %s" % path)
		return null
	if img.get_width() != TEX_RES or img.get_height() != TEX_RES:
		img.resize(TEX_RES, TEX_RES, Image.INTERPOLATE_BILINEAR)
	print("[MeshFill] Loaded previous rock mask: %s (%dx%d)" % [path, img.get_width(), img.get_height()])
	return ImageTexture.create_from_image(img)


func _capture_and_save_object_mask() -> void:
	if _raw_current_height_image == null:
		print("[MeshFill] No current height data for mask")
		return

	var result := _capture_object_mask_gpu(_raw_current_height_image)
	if result.is_empty():
		push_error("[MeshFill] Object mask capture GPU compute failed")
		return
	var mask: Image = result.get("png_mask", null)
	if mask == null or mask.is_empty():
		push_error("[MeshFill] Object mask capture returned no PNG mask")
		return
	_current_object_mask_img = result.get("object_mask", _current_object_mask_img)
	var nonzero := int(result.get("nonzero", 0))

	var out_path := OS.get_user_data_dir() + "/object_placement_mask.png"
	mask.save_png(out_path)
	print("[MeshFill] Object mask saved: %s (%d/%d mask pixels)" % [
		out_path, nonzero, TEX_RES * TEX_RES])


func _capture_object_mask_gpu(current_height_img: Image) -> Dictionary:
	if current_height_img == null or current_height_img.is_empty():
		return {}
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		return {}
	probe_rd.free()

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "CaptureRockMask"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return {}
	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader("res://shaders/capture_rock_mask.glsl")
	var pipeline := compute.create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return {}

	var current_tex := compute.upload_texture_2d(
		current_height_img,
		RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
		Image.FORMAT_RGBAF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"capture_rock_mask_current_rgba32f"
	)
	var png_mask_tex := compute.create_rw_texture_2d(
		TEX_RES,
		TEX_RES,
		RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM,
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"capture_rock_mask_png_rgba8"
	)
	var rock_mask_tex := compute.create_rw_texture_2d(
		TEX_RES,
		TEX_RES,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"capture_rock_mask_r32f"
	)
	var counter_buf := compute.storage_buffer_zero(4, ComputeShaderBaseScript.SCOPE_FRAME, "capture_rock_mask_counter_u32")
	if not current_tex.is_valid() or not png_mask_tex.is_valid() or not rock_mask_tex.is_valid() or not counter_buf.is_valid():
		compute.dispose()
		return {}

	var sampler := compute.create_linear_sampler()
	if not sampler.is_valid():
		compute.dispose()
		return {}
	var set0 := compute.create_uniform_set([
		compute.make_sampler_uniform(0, sampler, current_tex),
	], shader, 0)
	var set1 := compute.create_uniform_set([
		compute.make_image_uniform(0, png_mask_tex),
		compute.make_image_uniform(1, rock_mask_tex),
		compute.make_storage_uniform(2, counter_buf),
	], shader, 1)
	if not set0.is_valid() or not set1.is_valid():
		compute.dispose()
		return {}

	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, TEX_RES)
	push.encode_s32(4, TEX_RES)
	push.encode_float(8, 0.5)
	push.encode_float(12, 0.0)

	var groups := ceili(float(TEX_RES) / 32.0)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return {}
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_bind_uniform_set(cl, set1, 1)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, groups, groups, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var png_data := rd.texture_get_data(png_mask_tex, 0)
	var rock_data := rd.texture_get_data(rock_mask_tex, 0)
	var counter_data := rd.buffer_get_data(counter_buf, 0, 4)
	compute.dispose()
	var nonzero := (int(counter_data.decode_u32(0)) if counter_data.size() >= 4 else 0)
	return {
		"png_mask": Image.create_from_data(TEX_RES, TEX_RES, false, Image.FORMAT_RGBA8, png_data),
		"object_mask": Image.create_from_data(TEX_RES, TEX_RES, false, Image.FORMAT_RF, rock_data),
		"nonzero": nonzero,
	}


# --- Cliff data loading with procedural fallback ---

func _join_asset_path(dir_path: String, file_name: String) -> String:
	return dir_path + file_name if dir_path.ends_with("/") else dir_path + "/" + file_name


func _collect_resource_paths(dir_path: String, out_paths: Array[String]) -> void:
	if dir_path.is_empty():
		return
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if file_name == "." or file_name == "..":
			file_name = dir.get_next()
			continue
		var child_path := _join_asset_path(dir_path, file_name)
		if dir.current_is_dir():
			_collect_resource_paths(child_path, out_paths)
		else:
			var ext := file_name.get_extension().to_lower()
			if ext in ["tres", "res", "tscn", "scn"] and not out_paths.has(child_path):
				out_paths.append(child_path)
		file_name = dir.get_next()
	dir.list_dir_end()


func _load_scripted_rock_assets(out_meshes: Array[Mesh], out_assets: Array[AutoObject]) -> int:
	var paths: Array[String] = []
	for path in object_asset_paths:
		if not path.is_empty() and not paths.has(path):
			paths.append(path)
	_collect_resource_paths(object_asset_dir, paths)

	var loaded := 0
	for path in paths:
		var resource = load(path)
		var asset: AutoObject = null
		if resource is PackedScene:
			var instance := (resource as PackedScene).instantiate()
			if instance is AutoObject:
				asset = instance as AutoObject
			elif instance != null:
				instance.free()
		if asset == null:
			continue
		if asset.asset_id.is_empty():
			asset.asset_id = path.get_file().get_basename()
		if not asset.is_valid_asset():
			push_warning("[MeshFill] Skipping rock asset without mesh/height texture: %s" % path)
			continue
		out_meshes.append(asset.mesh)
		out_assets.append(asset)
		loaded += 1
		print("  Scripted rock asset: %s (size=%.2fm)" % [
			path, asset.mesh_size])
	return loaded


func _load_cliff_data(out_meshes: Array[Mesh], out_assets: Array[AutoObject]) -> void:
	print("[MeshFill] Loading cliff meshes...")
	var scripted_count := _load_scripted_rock_assets(out_meshes, out_assets)
	var fbx_configs := [
		{"fbx": "res://geo/cliff_01.FBX", "height": "res://geo/cliff_01_height.raw", "size": 2.3},
		{"fbx": "res://geo/cliff_02.FBX", "height": "res://geo/cliff_02_height.raw", "size": 5.3},
	]

	var loaded_all := true
	var fbx_meshes: Array[Mesh] = []
	var fbx_assets: Array[AutoObject] = []
	for cfg in fbx_configs:
		var mesh := _load_mesh_from_fbx(cfg.fbx)
		var raw_source_mesh := AutoAssetFactory.load_source_mesh(cfg.fbx)
		var source_mesh: Mesh = _bake_axis_rotation(raw_source_mesh) if raw_source_mesh != null else null
		if mesh == null:
			loaded_all = false
			break
		var htex := TerrainInitializerScript.load_raw_texture(cfg.height, TEX_RES, TEX_RES)
		if htex == null:
			loaded_all = false
			break

		if absf(mesh_height_scale - 1.0) > 0.001:
			var img := htex.get_image()
			_scale_height_image(img, mesh_height_scale)
			htex = ImageTexture.create_from_image(img)

		var h_stats := _get_height_stats(htex.get_image())
		fbx_meshes.append(mesh)
		var asset := AutoObject.new()
		asset.configure_object({
			"asset_id": str(cfg.fbx).get_file().get_basename(),
			"name": str(cfg.fbx).get_file().get_basename(),
			"mesh": mesh,
			"source_mesh": source_mesh if source_mesh != null else mesh,
			"source_mesh_path": cfg.fbx,
			"mesh_height_texture": htex,
			"mesh_size": cfg.size,
			"color": OBJECT_VOXEL_COLOR,
			"complexity": 1.0,
			"random_rotate": Vector2(0.0, 1.0),
			"random_scale": Vector2(0.8, 1.2),
			"random_height_offset": Vector2(-0.5, 0.5),
		})
		fbx_assets.append(asset)
		print("  Loaded: %s (size=%.1fm, height %.1f~%.1f, scale=%.3f)" % [
			cfg.fbx, cfg.size, h_stats.x, h_stats.y, mesh_height_scale])

	if loaded_all:
		out_meshes.append_array(fbx_meshes)
		out_assets.append_array(fbx_assets)
	elif scripted_count <= 0:
		print("[MeshFill] Cliff FBX/height not found, generating procedural cliffs...")
		_generate_procedural_cliffs(out_meshes, out_assets)
	else:
		print("[MeshFill] Cliff FBX/height not found; using %d scripted rock assets" % scripted_count)


func _generate_procedural_cliffs(out_meshes: Array[Mesh], out_assets: Array[AutoObject]) -> void:
	var configs := [
		{"name": "small_cliff", "size": 2.3, "box_size": Vector3(2.0, 4.0, 1.0)},
		{"name": "large_cliff", "size": 5.3, "box_size": Vector3(4.0, 8.0, 2.0)},
	]

	for cfg in configs:
		var box := BoxMesh.new()
		box.size = cfg.box_size

		var cliff_mat := StandardMaterial3D.new()
		cliff_mat.albedo_color = Color(0.55, 0.50, 0.45)
		cliff_mat.roughness = 0.95
		box.material = cliff_mat

		out_meshes.append(box)

		var htex_img := _create_cliff_height_image(cfg.box_size)
		var asset := AutoObject.new()
		asset.configure_object({
			"asset_id": cfg.name,
			"name": cfg.name,
			"mesh": box,
			"mesh_height_texture": ImageTexture.create_from_image(htex_img),
			"mesh_size": cfg.size,
			"color": OBJECT_VOXEL_COLOR,
			"complexity": 1.0,
			"random_rotate": Vector2(0.0, 1.0),
			"random_scale": Vector2(0.8, 1.2),
			"random_height_offset": Vector2(-0.5, 0.5),
		})
		out_assets.append(asset)
		print("  Generated: %s (size=%.1fm)" % [cfg.name, cfg.size])


func _create_cliff_height_image(box_size: Vector3) -> Image:
	var img := _create_cliff_height_image_gpu(box_size)
	if img == null or img.is_empty():
		push_error("[MeshFill] Cliff height image GPU compute failed")
		return Image.create(1, 1, false, Image.FORMAT_RGBAF)
	return img


func _create_cliff_height_image_gpu(box_size: Vector3) -> Image:
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		return null
	probe_rd.free()

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "CreateCliffHeightImage"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return null
	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader("res://shaders/create_cliff_height_image.glsl")
	var pipeline := compute.create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return null

	var out_tex := compute.create_rw_texture_2d(
		TEX_RES,
		TEX_RES,
		RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"create_cliff_height_out_rgba32f"
	)
	if not out_tex.is_valid():
		compute.dispose()
		return null

	var set0 := compute.create_uniform_set([
		compute.make_image_uniform(0, out_tex),
	], shader, 0)
	if not set0.is_valid():
		compute.dispose()
		return null

	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, TEX_RES)
	push.encode_s32(4, TEX_RES)
	push.encode_float(8, box_size.y)
	push.encode_float(12, 0.15)

	var groups := ceili(float(TEX_RES) / 32.0)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return null
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, groups, groups, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var data := rd.texture_get_data(out_tex, 0)
	var result := Image.create_from_data(TEX_RES, TEX_RES, false, Image.FORMAT_RGBAF, data)
	compute.dispose()
	return result


# --- Terrain mesh creation ---

func _reuse_or_create_terrain_mesh(height_tex: ImageTexture) -> void:
	# 启动时只复用编辑时 Terrain；运行时不再生成或替换地形网格。
	var existing := _get_level_root().get_node_or_null(NodePath("Terrain"))
	if existing is MeshInstance3D and (existing as MeshInstance3D).mesh != null:
		var mi := existing as MeshInstance3D
		var res := int(mi.get_meta("terrain_resolution", height_tex.get_width()))
		_attach_voxel_write_spec(mi, _make_terrain_voxel_write_spec(mi, res))
		print("[MeshFill] Reusing baked terrain (%dx%d)" % [res, res])
		return
	push_error("[MeshFill] Missing edit-time Terrain; runtime creation is disabled")



func _create_terrain_mesh(_height_tex: ImageTexture) -> void:
	push_error("[MeshFill] Runtime Terrain creation is disabled; edit-time Terrain is required")


func _scale_height_image(img: Image, scale: float) -> void:
	var scaled := _scale_height_image_gpu(img, scale)
	if scaled == null or scaled.is_empty():
		push_error("[MeshFill] Height image scale GPU compute failed")
		return
	img.copy_from(scaled)


func _scale_height_image_gpu(img: Image, scale: float) -> Image:
	if img == null or img.is_empty():
		return null
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		return null
	probe_rd.free()

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "ScaleHeightImage"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return null
	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader("res://shaders/scale_height_image.glsl")
	var pipeline := compute.create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return null

	var src_tex := compute.upload_texture_2d(
		img,
		RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
		Image.FORMAT_RGBAF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"scale_height_src_rgba32f"
	)
	var out_tex := compute.create_rw_texture_2d(
		img.get_width(),
		img.get_height(),
		RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"scale_height_out_rgba32f"
	)
	if not src_tex.is_valid() or not out_tex.is_valid():
		compute.dispose()
		return null

	var sampler := compute.create_linear_sampler()
	if not sampler.is_valid():
		compute.dispose()
		return null
	var set0 := compute.create_uniform_set([
		compute.make_sampler_uniform(0, sampler, src_tex),
	], shader, 0)
	var set1 := compute.create_uniform_set([
		compute.make_image_uniform(0, out_tex),
	], shader, 1)
	if not set0.is_valid() or not set1.is_valid():
		compute.dispose()
		return null

	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, img.get_width())
	push.encode_s32(4, img.get_height())
	push.encode_float(8, scale)
	push.encode_float(12, -10000.0)

	var groups_x := ceili(float(img.get_width()) / 32.0)
	var groups_y := ceili(float(img.get_height()) / 32.0)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return null
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_bind_uniform_set(cl, set1, 1)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var data := rd.texture_get_data(out_tex, 0)
	var result := Image.create_from_data(img.get_width(), img.get_height(), false, Image.FORMAT_RGBAF, data)
	compute.dispose()
	return result


func _get_height_stats(img: Image) -> Vector2:
	var stats := _get_height_stats_gpu(img)
	if not bool(stats.get("valid", false)):
		push_error("[MeshFill] Height stats GPU compute failed")
		return Vector2.ZERO
	return Vector2(float(stats.get("min", 0.0)), float(stats.get("max", 0.0)))


func _get_height_stats_gpu(img: Image) -> Dictionary:
	if img == null or img.is_empty():
		return {}
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		return {}
	probe_rd.free()

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "HeightStats"
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
		"height_stats_src_rgba32f"
	)
	var stats_bytes := PackedByteArray()
	stats_bytes.resize(12)
	stats_bytes.encode_s32(0, -1)
	var stats_buf := compute.storage_buffer_from_bytes(stats_bytes, ComputeShaderBaseScript.SCOPE_FRAME, "height_stats_minmax_count_u32")
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


# --- FBX mesh loading ---

func _load_mesh_from_fbx(path: String) -> Mesh:
	var r := load(path)
	if r == null:
		return null
	var raw_mesh: Mesh = null
	if r is PackedScene:
		var instance := (r as PackedScene).instantiate()
		raw_mesh = _find_mesh_in_tree(instance)
		instance.free()
	elif r is Mesh:
		raw_mesh = r as Mesh
	if raw_mesh == null:
		return null
	return _bake_axis_rotation(raw_mesh)


func _bake_axis_rotation(src_mesh: Mesh) -> ArrayMesh:
	var base_rot := Basis(Vector3(1, 0, 0), deg_to_rad(cliff_base_rotation.x))
	base_rot = base_rot * Basis(Vector3(0, 1, 0), deg_to_rad(cliff_base_rotation.y))
	base_rot = base_rot * Basis(Vector3(0, 0, 1), deg_to_rad(cliff_base_rotation.z))
	var xform := Transform3D(base_rot, Vector3.ZERO)

	var new_mesh := ArrayMesh.new()
	for si in range(src_mesh.get_surface_count()):
		var arrays := src_mesh.surface_get_arrays(si)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()

		var new_verts := PackedVector3Array()
		new_verts.resize(verts.size())
		for i in range(verts.size()):
			new_verts[i] = xform * verts[i]
		arrays[Mesh.ARRAY_VERTEX] = new_verts

		if normals.size() > 0:
			var new_normals := PackedVector3Array()
			new_normals.resize(normals.size())
			for i in range(normals.size()):
				new_normals[i] = (base_rot * normals[i]).normalized()
			arrays[Mesh.ARRAY_NORMAL] = new_normals

		new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mat := src_mesh.surface_get_material(si)
		if mat != null:
			new_mesh.surface_set_material(si, mat)
	return new_mesh


func _find_mesh_in_tree(node: Node) -> Mesh:
	if node is MeshInstance3D:
		return (node as MeshInstance3D).mesh
	if node is ImporterMeshInstance3D:
		var importer_mesh = node.get("mesh")
		if importer_mesh != null and importer_mesh.has_method("get_mesh"):
			return importer_mesh.get_mesh()
	for child in node.get_children():
		var m := _find_mesh_in_tree(child)
		if m != null:
			return m
	return null


# --- Vegetation Generation (GPU-only runtime boundary) ---


func _autoobject_channel_profiles() -> Array[Dictionary]:
	return [
		{"channel": 0, "radius": 0.2, "color": Color(0.2, 0.8, 0.2, 1.0), "complexity": 1.0, "y_min": 0.0, "y_max": 0.3, "subdivisions": 1},
		{"channel": 1, "radius": 1.0, "color": Color(0.8, 0.6, 0.2, 0.7), "complexity": 0.7, "y_min": 0.3, "y_max": 2.0, "subdivisions": 2},
		{"channel": 2, "radius": 2.0, "color": Color(0.2, 0.5, 0.8, 0.4), "complexity": 0.4, "y_min": 2.0, "y_max": 6.0, "subdivisions": 2},
		{"channel": 3, "radius": 3.0, "color": Color(0.8, 0.2, 0.2, 0.2), "complexity": 0.2, "y_min": 6.0, "y_max": 99.0, "subdivisions": 1},
	]


func _ensure_scene_voxel_committer() -> void:
	if _scene_voxel_committer != null:
		return
	_scene_voxel_committer = SceneVoxelCommitterScript.new(TEX_RES, capture_size)
	if _scene_placement_actor != null and _scene_placement_actor.is_initialized():
		_scene_placement_actor.attach_sv_committer(_scene_voxel_committer)



func _save_combined_mask_debug() -> void:
	var out_dir := OS.get_user_data_dir()
	var vis := _make_combined_mask_debug_image()
	if vis == null or vis.is_empty():
		push_error("[MeshFill] Combined mask debug GPU compute failed")
		return
	vis.save_png(out_dir + "/combined_mask.png")
	print("[MeshFill] Combined mask saved: %s/combined_mask.png" % out_dir)


func _make_combined_mask_debug_image() -> Image:
	var rock_img := _current_object_mask_img
	if rock_img == null or rock_img.is_empty():
		rock_img = Image.create(TEX_RES, TEX_RES, false, Image.FORMAT_RF)
		rock_img.fill(Color(0.0, 0.0, 0.0, 0.0))
	var autoobject_img := _autoobject_mask_image
	if autoobject_img == null or autoobject_img.is_empty():
		autoobject_img = _make_blank_autoobject_activity_mask()
	return _make_combined_mask_debug_image_gpu(rock_img, autoobject_img)


func _make_combined_mask_debug_image_gpu(rock_img: Image, autoobject_img: Image) -> Image:
	if rock_img == null or rock_img.is_empty() or autoobject_img == null or autoobject_img.is_empty():
		return null
	var probe_rd := RenderingServer.create_local_rendering_device()
	if probe_rd == null:
		return null
	probe_rd.free()

	var compute = ComputeShaderBaseScript.new()
	compute.log_name = "CombinedMaskDebug"
	if not compute.ensure_device(true, false):
		compute.dispose()
		return null
	var rd: RenderingDevice = compute.get_rendering_device()
	var shader := compute.load_compute_shader("res://shaders/combined_mask_debug.glsl")
	var pipeline := compute.create_compute_pipeline(shader)
	if not shader.is_valid() or not pipeline.is_valid():
		compute.dispose()
		return null

	var rock_tex := compute.upload_texture_2d(
		rock_img,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		Image.FORMAT_RF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"combined_mask_debug_rock_r32f"
	)
	var autoobject_tex := compute.upload_texture_2d(
		autoobject_img,
		RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
		Image.FORMAT_RGBAH,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"combined_mask_debug_autoobject_rgba16f"
	)
	var out_tex := compute.create_rw_texture_2d(
		TEX_RES,
		TEX_RES,
		RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM,
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT,
		ComputeShaderBaseScript.SCOPE_FRAME,
		"combined_mask_debug_out_rgba8"
	)
	if not rock_tex.is_valid() or not autoobject_tex.is_valid() or not out_tex.is_valid():
		compute.dispose()
		return null

	var sampler := compute.create_linear_sampler()
	if not sampler.is_valid():
		compute.dispose()
		return null
	var set0 := compute.create_uniform_set([
		compute.make_sampler_uniform(0, sampler, rock_tex),
		compute.make_sampler_uniform(1, sampler, autoobject_tex),
	], shader, 0)
	var set1 := compute.create_uniform_set([
		compute.make_image_uniform(0, out_tex),
	], shader, 1)
	if not set0.is_valid() or not set1.is_valid():
		compute.dispose()
		return null

	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, TEX_RES)
	push.encode_s32(4, TEX_RES)
	push.encode_float(8, 0.0)
	push.encode_float(12, 0.0)

	var groups := ceili(float(TEX_RES) / 32.0)
	var cl := compute.begin_compute_list()
	if cl < 0:
		compute.dispose()
		return null
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, set0, 0)
	rd.compute_list_bind_uniform_set(cl, set1, 1)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, groups, groups, 1)
	compute.end_compute_list()
	compute.submit_and_sync()

	var data := rd.texture_get_data(out_tex, 0)
	var result := Image.create_from_data(TEX_RES, TEX_RES, false, Image.FORMAT_RGBA8, data)
	compute.dispose()
	return result


func _build_debug_mask_terrain() -> void:
	if _debug_mask_terrain != null:
		_debug_mask_terrain.queue_free()
		_debug_mask_terrain = null

	if _cached_textures.is_empty():
		return
	var depth_img: Image = (_cached_textures["scene_depth"] as ImageTexture).get_image()
	var mask_debug_img := _make_combined_mask_debug_image()
	if mask_debug_img == null or mask_debug_img.is_empty():
		push_error("[MeshFill] Combined mask debug terrain GPU mask pack failed")
		return
	var depth_values := depth_img.get_data().to_float32_array()
	var mask_bytes := mask_debug_img.get_data()
	var res := TEX_RES
	var cell_size := capture_size / float(res)
	var half := capture_size / 2.0

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	for y in range(res):
		for x in range(res):
			var value_index := (y * res + x) * 4
			var depth_v := depth_values[value_index] if value_index < depth_values.size() else max_height
			var h := max_height - depth_v + 0.2
			var byte_index := value_index
			var rock_v := float(mask_bytes[byte_index + 0]) / 255.0 if byte_index + 2 < mask_bytes.size() else 0.0
			var autoobject_v := float(mask_bytes[byte_index + 1]) / 255.0 if byte_index + 2 < mask_bytes.size() else 0.0
			var intensity := maxf(rock_v, autoobject_v)
			var alpha := 0.6 * intensity if intensity > 0.01 else 0.02
			st.set_color(Color(rock_v, autoobject_v, 0.0, alpha))
			st.set_uv(Vector2(float(x) / float(res - 1), float(y) / float(res - 1)))
			st.add_vertex(Vector3(float(x) * cell_size - half, h, float(y) * cell_size - half))

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
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true

	_debug_mask_terrain = MeshInstance3D.new()
	_debug_mask_terrain.mesh = st.commit()
	_debug_mask_terrain.material_override = mat
	_debug_mask_terrain.name = "DebugCombinedMask"
	_debug_mask_terrain.visible = false
	_get_level_root().add_child(_debug_mask_terrain)
	print("[MeshFill] Combined mask debug terrain ready [M to toggle]")


func _toggle_mask_overlay() -> void:
	if _debug_mask_terrain != null:
		_debug_mask_terrain.queue_free()
		_debug_mask_terrain = null
		print("[MeshFill] Combined mask overlay: OFF")
		return
	if _vegetation_generated:
		_build_debug_mask_terrain()
		if _debug_mask_terrain != null:
			_debug_mask_terrain.visible = true
			print("[MeshFill] Combined mask overlay: ON (R=rock G=autoobject)")
	else:
		print("[MeshFill] No main.gd vegetation data: legacy CPU scatter is removed and runtime vegetation must use the GPU path.")


# ---------------------------------------------------------------------------
# Probe Inspect Tool
# ---------------------------------------------------------------------------

func _toggle_probe_inspect_mode() -> void:
	if _painting:
		_painting = false
		_finish_brush_stroke()
	_probe_inspect_mode = not _probe_inspect_mode
	if _probe_inspect_mode:
		_brush_active = false
		_tile_refresh_mode = false
		_update_brush_label()
		print("[ProbeInspect] ON — click terrain to inspect TargetSV_B at that voxel")
	else:
		if _probe_debug_label != null:
			_probe_debug_label.text = ""
		print("[ProbeInspect] OFF")


func _probe_inspect_at_screen(screen_pos: Vector2) -> void:
	var pixel := _screen_to_terrain_pixel(screen_pos)
	if pixel.x < 0:
		return
	if _target_sv_b_visual_bytes.is_empty() or _target_sv_b_collision_bytes.is_empty():
		_load_persisted_target_scene_voxel()
	var tex_size := int(_target_sv_b_metadata.get("texture_size", TEX_RES))
	var slice_count := int(_target_sv_b_metadata.get("slice_count", TARGET_SV_SLICE_COUNT))
	var vertical_span := float(_target_sv_b_metadata.get("vertical_span", TARGET_SV_VERTICAL_SPAN))

	if _target_sv_b_visual_bytes.is_empty() or _target_sv_b_collision_bytes.is_empty():
		_show_probe_inspect("No TargetSV_B data. Press Ctrl+J to generate.")
		return

	var voxel_count := tex_size * tex_size * slice_count
	if _target_sv_b_visual_bytes.size() < voxel_count * 16 or _target_sv_b_collision_bytes.size() < voxel_count * 4:
		_show_probe_inspect("TargetSV_B buffer size mismatch")
		return
	if not _target_sv_b_packed_target_buffers_valid(voxel_count):
		_show_probe_inspect("TargetSV_B packed target buffers missing. Press Ctrl+J to regenerate.")
		return

	var lines: PackedStringArray = PackedStringArray()
	lines.append("Pixel (%d, %d)  slices=%d  vert_span=%.1fm" % [pixel.x, pixel.y, slice_count, vertical_span])
	lines.append("Slice | Y(m)  | R    G    B   | Value | Collision")
	lines.append("------+-------+---------------+-------+----------")

	var peak_value := 0.0
	var peak_collision := 0.0
	var color_sum := Vector3.ZERO
	var weight_sum := 0.0
	var collision_values := _target_sv_b_float_values(_target_sv_b_collision_bytes, voxel_count)
	var target_completely_values := _target_sv_b_float_values(_target_sv_b_target_completely_bytes, voxel_count)
	var target_color_words := _target_sv_b_int_words(_target_sv_b_target_color_rgba8_bytes, voxel_count)

	for s in range(slice_count):
		var idx := pixel.x + tex_size * (pixel.y + tex_size * s)
		var collision := clampf(collision_values[idx], 0.0, 1.0)
		var target := _target_sv_b_color_rgba8_from_word(target_color_words[idx])
		var r := target.r
		var g := target.g
		var b := target.b
		var value := target.a
		var y_mid := (float(s) + 0.5) / float(slice_count) * vertical_span
		lines.append("  %d   | %5.1f | %.2f %.2f %.2f | %.3f | %.3f" % [s, y_mid, r, g, b, value, collision])
		peak_value = maxf(peak_value, clampf(target_completely_values[idx], 0.0, 1.0))
		peak_collision = maxf(peak_collision, collision)
		var w := value * value
		color_sum += Vector3(r, g, b) * w
		weight_sum += w

	lines.append("------+-------+---------------+-------+----------")
	var avg_color := color_sum / maxf(weight_sum, 0.0001)
	lines.append("Peak: value=%.3f collision=%.3f  Weighted color=(%.2f,%.2f,%.2f)" % [
		peak_value, peak_collision, avg_color.x, avg_color.y, avg_color.z])

	lines.append("")
	lines.append("--- Candidate scoring: GPU-only (see prefilter top-K readback) ---")

	_show_probe_inspect("\n".join(lines))
	print("[ProbeInspect] %s" % lines[0])


func _target_sv_b_packed_target_buffers_valid(voxel_count: int) -> bool:
	var expected_bytes := maxi(voxel_count, 1) * 4
	return _target_sv_b_target_completely_bytes.size() >= expected_bytes \
		and _target_sv_b_target_color_rgba8_bytes.size() >= expected_bytes


func _target_sv_b_float_values(bytes: PackedByteArray, voxel_count: int) -> PackedFloat32Array:
	var value_count := maxi(voxel_count, 0)
	var expected_bytes := maxi(voxel_count, 1) * 4
	var available_bytes := mini(bytes.size(), expected_bytes)
	available_bytes -= available_bytes % 4
	var available_count := mini(value_count, int(available_bytes / 4))
	var values := PackedFloat32Array()
	values.resize(value_count)
	for i in range(available_count):
		values[i] = bytes.decode_float(i * 4)
	return values


func _target_sv_b_int_words(bytes: PackedByteArray, voxel_count: int) -> PackedInt32Array:
	var value_count := maxi(voxel_count, 0)
	var expected_bytes := maxi(voxel_count, 1) * 4
	var available_bytes := mini(bytes.size(), expected_bytes)
	available_bytes -= available_bytes % 4
	var available_count := mini(value_count, int(available_bytes / 4))
	var words := PackedInt32Array()
	words.resize(value_count)
	for i in range(available_count):
		words[i] = bytes.decode_s32(i * 4)
	return words


func _target_sv_b_color_rgba8_from_word(word: int) -> Color:
	var rgba8 := word if word >= 0 else word + 4294967296
	return Color(
		float((rgba8 >> 24) & 0xFF) / 255.0,
		float((rgba8 >> 16) & 0xFF) / 255.0,
		float((rgba8 >> 8) & 0xFF) / 255.0,
		float(rgba8 & 0xFF) / 255.0
	)




func _show_probe_inspect(text: String) -> void:
	if _probe_debug_label == null:
		_probe_debug_label = Label.new()
		_probe_debug_label.name = "ProbeInspectLabel"
		_probe_debug_label.add_theme_font_size_override("font_size", 13)
		_probe_debug_label.add_theme_color_override("font_color", Color.WHITE)
		_probe_debug_label.position = Vector2(10, 60)
		_probe_debug_label.z_index = 100
		var canvas := CanvasLayer.new()
		canvas.name = "ProbeInspectCanvas"
		canvas.layer = 100
		add_child(canvas)
		canvas.add_child(_probe_debug_label)
	_probe_debug_label.text = text
