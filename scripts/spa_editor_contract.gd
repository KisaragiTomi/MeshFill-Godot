@tool
class_name SPAEditorContract
extends RefCounted

const MODE_MIXED := 0
const MODE_AUTOOBJECT := 1
const MODE_SVTILE := 2
const MODE_ANCHOR := 3
const MODE_SV := 4
const MODE_TARGETSV := 5
const SELECTION_MODE_NAMES := ["Mixed", "AutoObject", "SVTile", "Anchor", "SV", "TargetSV"]

const SELECTION_DOMAIN_AUTOOBJECT := "autoobject"
const SELECTION_DOMAIN_SVTILE := "svtile"
const SELECTION_DOMAIN_ANCHOR := "anchor"
const SELECTION_DOMAIN_SV := "sv"
const SELECTION_DOMAIN_TARGETSV := "targetsv"

const SELECTION_GEOMETRY_TRIANGLE := "triangle"
const SELECTION_GEOMETRY_VOXEL := "voxel"
const SELECTION_GEOMETRY_AUTOOBJECT := "autoobject"
const SELECTION_GEOMETRY_VOLUME_SCORE_ANCHOR := "volume_score_anchor"

const EXTERNAL_VOXEL_DISPLAY_ROOT_NAME := "ExternalVoxelDisplays"
const EXTERNAL_VOXEL_DISPLAY_GROUP_PREFIX := "meshfill_voxel_display_"
const VOXEL_DISPLAY_GPU_OBJECTS := "gpu_objects"
const VOXEL_DISPLAY_SVTILE := "svtile"
const VOXEL_DISPLAY_ANCHOR := "anchor"
const VOXEL_DISPLAY_SV := "sv"
const VOXEL_DISPLAY_TARGETSV := "targetsv"
const VOXEL_DISPLAY_KEYS := [
	VOXEL_DISPLAY_GPU_OBJECTS,
	VOXEL_DISPLAY_SVTILE,
	VOXEL_DISPLAY_ANCHOR,
	VOXEL_DISPLAY_SV,
	VOXEL_DISPLAY_TARGETSV,
]
const VOXEL_DOMAIN_BINDINGS := [
	{
		"domain": SELECTION_DOMAIN_AUTOOBJECT,
		"mode": MODE_AUTOOBJECT,
		"key": VOXEL_DISPLAY_GPU_OBJECTS,
		"display_key": VOXEL_DISPLAY_GPU_OBJECTS,
		"label": "GO",
		"mode_label": "AutoObject",
		"tooltip": "GPU Objects: enable AutoObject inspection and selection markers",
		"pick_method": "_pick_autoobject_with_camera",
		"record_method": "",
		"requires_sv_committer": false,
	},
	{
		"domain": SELECTION_DOMAIN_SVTILE,
		"mode": MODE_SVTILE,
		"key": VOXEL_DISPLAY_SVTILE,
		"display_key": VOXEL_DISPLAY_SVTILE,
		"label": "ST",
		"mode_label": "SVTile",
		"tooltip": "SV Tiles: show SceneVoxelTile heatmap blocks",
		"pick_method": "_pick_svtile_record_with_camera",
		"record_method": "_svtile_record_for_voxel",
		"requires_sv_committer": true,
	},
	{
		"domain": SELECTION_DOMAIN_ANCHOR,
		"mode": MODE_ANCHOR,
		"key": VOXEL_DISPLAY_ANCHOR,
		"display_key": VOXEL_DISPLAY_ANCHOR,
		"label": "A",
		"mode_label": "Anchor",
		"tooltip": "Anchors: show Anchor selection markers and labels",
		"pick_method": "_pick_anchor_record_with_camera",
		"record_method": "_anchor_record_for_voxel",
		"requires_sv_committer": true,
	},
	{
		"domain": SELECTION_DOMAIN_SV,
		"mode": MODE_SV,
		"key": VOXEL_DISPLAY_SV,
		"display_key": VOXEL_DISPLAY_SV,
		"label": "SV",
		"mode_label": "SV",
		"tooltip": "Scene Voxels: show SceneVoxel selection markers and labels",
		"pick_method": "_pick_sv_record_with_camera",
		"record_method": "_sv_record_for_voxel",
		"requires_sv_committer": true,
	},
	{
		"domain": SELECTION_DOMAIN_TARGETSV,
		"mode": MODE_TARGETSV,
		"key": VOXEL_DISPLAY_TARGETSV,
		"display_key": VOXEL_DISPLAY_TARGETSV,
		"label": "TSV",
		"mode_label": "TargetSV",
		"tooltip": "Target SV: show TargetSV voxel display and selection markers",
		"pick_method": "_pick_targetsv_record_with_camera",
		"record_method": "_targetsv_record_for_selection_voxel",
		"requires_sv_committer": false,
	},
]
const VOXEL_DISPLAY_DEFINITIONS := VOXEL_DOMAIN_BINDINGS
const MIXED_DATA_PICK_MODES := [MODE_TARGETSV, MODE_SVTILE]
const SVTILE_OVERLAY_FOCUS_MODES := [MODE_SVTILE, MODE_ANCHOR, MODE_SV]

const SPA_VOLUME_SCORE_ANCHOR_METHOD := "generate_volume_score_anchors"
const SPA_VOLUME_SCORE_METHOD := "calculate_volume_score"
const SPA_VOLUME_SCORE_PROVIDER_METHOD := "has_volume_score_provider"
const VOLUME_SCORE_SUMMARY_METHOD := "get_selected_anchor_summary_text"
const VOLUME_SCORE_TOOLTIP_METHOD := "get_selected_anchor_tooltip_text"
const VOLUME_SCORE_STATUS_METHODS := [VOLUME_SCORE_SUMMARY_METHOD, VOLUME_SCORE_TOOLTIP_METHOD]


static func selection_mode_name(mode: int) -> String:
	if mode >= 0 and mode < SELECTION_MODE_NAMES.size():
		return SELECTION_MODE_NAMES[mode]
	return "Unknown"


static func binding_for_mode(mode: int) -> Dictionary:
	for raw_binding in VOXEL_DOMAIN_BINDINGS:
		var binding: Dictionary = raw_binding
		if int(binding.get("mode", -1)) == mode:
			return binding.duplicate(true)
	return {}


static func binding_for_domain(domain: String) -> Dictionary:
	for raw_binding in VOXEL_DOMAIN_BINDINGS:
		var binding: Dictionary = raw_binding
		if str(binding.get("domain", "")) == domain:
			return binding.duplicate(true)
	return {}


static func binding_for_display_key(display_key: String) -> Dictionary:
	for raw_binding in VOXEL_DOMAIN_BINDINGS:
		var binding: Dictionary = raw_binding
		if str(binding.get("display_key", binding.get("key", ""))) == display_key:
			return binding.duplicate(true)
	return {}


static func default_voxel_display_state() -> Dictionary:
	var state := {}
	for raw_binding in VOXEL_DOMAIN_BINDINGS:
		var binding: Dictionary = raw_binding
		var display_key := str(binding.get("display_key", binding.get("key", "")))
		if not display_key.is_empty():
			state[display_key] = true
	return state


static func selection_domain_for_mode(mode: int) -> String:
	var binding := binding_for_mode(mode)
	return str(binding.get("domain", ""))


static func selection_mode_for_domain(domain: String) -> int:
	var binding := binding_for_domain(domain)
	return int(binding.get("mode", -1))


static func voxel_display_key_for_mode(mode: int) -> String:
	var binding := binding_for_mode(mode)
	return str(binding.get("display_key", binding.get("key", "")))


static func voxel_display_key_for_domain(domain: String) -> String:
	var binding := binding_for_domain(domain)
	return str(binding.get("display_key", binding.get("key", "")))


static func data_pick_method_for_mode(mode: int) -> String:
	var binding := binding_for_mode(mode)
	return str(binding.get("pick_method", ""))


static func data_record_method_for_mode(mode: int) -> String:
	var binding := binding_for_mode(mode)
	return str(binding.get("record_method", ""))


static func mode_requires_scene_voxel_committer(mode: int) -> bool:
	var binding := binding_for_mode(mode)
	return bool(binding.get("requires_sv_committer", false))


static func mode_is_active(selection_mode: int, mode: int) -> bool:
	return selection_mode == MODE_MIXED or selection_mode == mode


static func mode_focuses_display_key(selection_mode: int, display_key: String) -> bool:
	var binding := binding_for_display_key(display_key)
	if binding.is_empty():
		return selection_mode == MODE_MIXED
	return mode_is_active(selection_mode, int(binding.get("mode", -1)))


static func mode_in_list(selection_mode: int, modes: Array) -> bool:
	if selection_mode == MODE_MIXED:
		return true
	return modes.has(selection_mode)


static func data_pick_modes_for_selection_mode(mode: int) -> Array:
	if mode == MODE_MIXED:
		return MIXED_DATA_PICK_MODES.duplicate()
	if mode == MODE_AUTOOBJECT:
		return []
	var method_name := data_pick_method_for_mode(mode)
	if method_name.is_empty():
		return []
	return [mode]


static func selection_mode_from_keycode(keycode: int) -> int:
	match keycode:
		KEY_0:
			return MODE_MIXED
		KEY_1:
			return MODE_AUTOOBJECT
		KEY_2:
			return MODE_SVTILE
		KEY_3:
			return MODE_ANCHOR
		KEY_4:
			return MODE_SV
		KEY_5:
			return MODE_TARGETSV
	return -1


static func external_voxel_display_owner_name(owner_key: String) -> String:
	var key := owner_key.strip_edges()
	if key.is_empty():
		key = "external"
	key = key.replace("/", "_")
	key = key.replace("\\", "_")
	key = key.replace(":", "_")
	key = key.replace(" ", "_")
	return "%s_%s" % [EXTERNAL_VOXEL_DISPLAY_ROOT_NAME, key]


static func voxel_display_group(display_key: String) -> String:
	return "%s%s" % [EXTERNAL_VOXEL_DISPLAY_GROUP_PREFIX, display_key]


static func pick_volume_score_anchor(provider: Node, camera: Camera3D, screen_pos: Vector2) -> int:
	if provider == null or camera == null:
		return -1
	var ray_origin := camera.project_ray_origin(screen_pos)
	var ray_dir := camera.project_ray_normal(screen_pos).normalized()
	var best_index := -1
	var best_t := INF
	if provider.has_method("get_selectable_anchor_bounds"):
		for value in provider.call("get_selectable_anchor_bounds"):
			if not (value is Dictionary):
				continue
			var bound := value as Dictionary
			var raw_aabb = bound.get("aabb", null)
			if not (raw_aabb is AABB):
				continue
			var hit = (raw_aabb as AABB).intersects_ray(ray_origin, ray_dir)
			if hit is Vector3:
				var hit_position: Vector3 = hit
				var ray_t := (hit_position - ray_origin).dot(ray_dir)
				if ray_t >= 0.0 and ray_t < best_t:
					best_t = ray_t
					best_index = int(bound.get("anchor_index", -1))
	if best_index >= 0:
		return best_index
	if not provider.has_method("get_anchor_world_positions"):
		return -1
	var positions: PackedVector3Array = provider.call("get_anchor_world_positions")
	var radius := 4.0
	if provider.has_method("get_anchor_marker_radius"):
		radius = maxf(float(provider.call("get_anchor_marker_radius")) * 2.5, 0.1)
	var radius_squared := radius * radius
	var best_distance := INF
	for index in range(positions.size()):
		var world_position := positions[index]
		if camera.is_position_behind(world_position):
			continue
		var ray_t := (world_position - ray_origin).dot(ray_dir)
		if ray_t < 0.0:
			continue
		var closest := ray_origin + ray_dir * ray_t
		var distance := closest.distance_squared_to(world_position)
		if distance <= radius_squared and distance < best_distance:
			best_distance = distance
			best_index = index
	return best_index
