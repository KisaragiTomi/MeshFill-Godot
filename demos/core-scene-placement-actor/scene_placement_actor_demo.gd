@tool
extends "res://demos/core_demo_contract_fixture.gd"

## ScenePlacementActor (SPA) — Interactive Demo
##
## Demonstrates the full SPA lifecycle:
##   1. initialize → RenderingDevice + profile container
##   2. register_asset × N → descriptors GPU-resident
##   3. wireframe bounds visualization
##   4. GPU readiness HUD
##
## Controls:
##   1-4     — toggle asset visibility
##   G       — show GPU readiness report
##   Space   — re-register all assets (refresh)

const AutoAssetFactory := preload("res://scripts/auto_asset_factory.gd")
const TerrainConfigScript := preload("res://scripts/terrain_config.gd")
const AssetDescriptorScript := preload("res://scripts/auto_voxel_descriptor.gd")

const GEO_PATHS := [
	"res://geo/SM_TestLeaf_Test2.FBX",
	"res://geo/cliff_01.FBX",
	"res://geo/cliff_02.FBX",
	"res://geo/SM_Cliff_06.FBX",
]

const ASSET_NAMES := ["Leaf", "Cliff01", "Cliff02", "Cliff06"]

const ASSET_COLORS := [
	Color(0.35, 0.58, 0.24, 0.45),
	Color(0.48, 0.42, 0.35, 0.75),
	Color(0.52, 0.46, 0.38, 0.70),
	Color(0.55, 0.50, 0.44, 0.80),
]

const WIRE_COLORS := [
	Color(0.2, 0.9, 0.3, 0.7),
	Color(0.9, 0.4, 0.2, 0.7),
	Color(0.2, 0.5, 1.0, 0.7),
	Color(1.0, 0.85, 0.1, 0.7),
]

var _spa: ScenePlacementActor
var _meshes: Array[Mesh] = []
var _descriptors: Array[AssetDescriptor] = []
var _autoobjects: Array[AutoObject] = []
var _profile_ids: Array[int] = []
var _display_root: Node3D
var _wireframes: Array[Node3D] = []
var _hud_label: Label
var _initialized := false
var _init_time_ms := 0.0
var _register_time_ms := 0.0


func _ready() -> void:
	super._ready()
	if not Engine.is_editor_hint():
		return
	if is_scene_startup_blocked():
		return
	_display_root = Node3D.new()
	_display_root.name = "SPADisplay"
	add_child(_display_root)
	_setup_hud()
	_load_and_init.call_deferred()


func _load_and_init() -> void:
	if not Engine.is_editor_hint():
		return
	_load_meshes()
	_init_spa()
	_register_all_assets()
	_place_autoobjects()
	_build_wireframes()
	_frame_camera()
	_update_hud()


func _load_meshes() -> void:
	for path in GEO_PATHS:
		var m := AutoAssetFactory.load_mesh(path)
		if m == null:
			m = BoxMesh.new()
		_meshes.append(m)


func _init_spa() -> void:
	var t0 := Time.get_ticks_msec()
	_spa = ScenePlacementActor.new()
	_spa.initialize(true, true)
	_initialized = _spa.is_initialized()
	_init_time_ms = float(Time.get_ticks_msec() - t0)
	if _initialized:
		print("[SPA Demo] Initialized, RD ready")
	else:
		push_warning("[SPA Demo] SPA init failed — no RenderingDevice?")


func _register_all_assets() -> void:
	_descriptors.clear()
	_profile_ids.clear()
	if not _initialized:
		return
	var t0 := Time.get_ticks_msec()
	for i in range(_meshes.size()):
		var color: Color = ASSET_COLORS[i] if i < ASSET_COLORS.size() else Color.WHITE
		var descriptor := AutoObject.create_voxel_descriptor(
			color, color.a, 1.0,
			[{"shape": "cylinder", "radius": 1.0, "y_min": 0.0, "y_max": 2.0}])
		_descriptors.append(descriptor)
		var pid := _spa.register_asset(descriptor, _meshes[i])
		_profile_ids.append(pid)
		print("[SPA Demo] Registered [%d] %s → profile_id=%d" % [
			i, ASSET_NAMES[i] if i < ASSET_NAMES.size() else "?", pid])
	_register_time_ms = float(Time.get_ticks_msec() - t0)


func _place_autoobjects() -> void:
	for obj in _autoobjects:
		if is_instance_valid(obj):
			obj.queue_free()
	_autoobjects.clear()

	var spacing := 60.0
	var row_count := 2
	var col_count := ceili(float(_meshes.size()) / float(row_count))
	var start_x := -float(col_count - 1) * spacing * 0.5
	var start_z := -float(row_count - 1) * spacing * 0.5

	for i in range(_meshes.size()):
		var col := i % col_count
		var row := i / col_count
		var obj := AutoObject.new()
		obj.name = "SPA_%s" % (ASSET_NAMES[i] if i < ASSET_NAMES.size() else str(i))
		obj.mesh = _meshes[i]
		var world_x := start_x + float(col) * spacing
		var world_z := start_z + float(row) * spacing
		var height := _sample_terrain_height_at(world_x, world_z)
		obj.position = Vector3(world_x, height, world_z)
		var color: Color = ASSET_COLORS[i] if i < ASSET_COLORS.size() else Color.WHITE
		obj.configure_auto_object({
			"color": color,
			"complexity": color.a,
			"object_type": "object",
			"asset_id": ASSET_NAMES[i] if i < ASSET_NAMES.size() else str(i),
		})
		_display_root.add_child(obj)
		_autoobjects.append(obj)


func _sample_terrain_height_at(wx: float, wz: float) -> float:
	var terrain := TerrainInitializerScript.find_edit_time_terrain(self) as MeshInstance3D
	if terrain != null and terrain.mesh != null:
		var field := TerrainInitializerScript.terrain_height_field_from_mesh(
			terrain, 64, TerrainConfigScript.MAX_HEIGHT)
		var gx := 64
		var capture := TerrainConfigScript.CAPTURE_SIZE
		var u := clampf((wx / capture) + 0.5, 0.0, 1.0)
		var v := clampf((wz / capture) + 0.5, 0.0, 1.0)
		var px := clampi(int(u * float(gx - 1)), 0, gx - 1)
		var pz := clampi(int(v * float(gx - 1)), 0, gx - 1)
		var idx := pz * gx + px
		if idx < field.size():
			return field[idx]
	return 0.0


# --- Wireframe Bounds -------------------------------------------------------

func _build_wireframes() -> void:
	for w in _wireframes:
		if is_instance_valid(w):
			w.queue_free()
	_wireframes.clear()

	for i in range(_autoobjects.size()):
		var obj := _autoobjects[i]
		if obj.mesh == null:
			continue
		var aabb := obj.mesh.get_aabb()
		var wire_color: Color = WIRE_COLORS[i] if i < WIRE_COLORS.size() else Color.WHITE
		var wire := _build_wire_box(aabb, wire_color)
		wire.position = obj.position + aabb.get_center()
		_display_root.add_child(wire)
		_wireframes.append(wire)

		var label := Label3D.new()
		label.name = "Label_%d" % i
		label.text = "%s\nAABB: %.1f × %.1f × %.1f" % [
			ASSET_NAMES[i] if i < ASSET_NAMES.size() else str(i),
			aabb.size.x, aabb.size.y, aabb.size.z]
		if i < _profile_ids.size():
			label.text += "\nprofile_id: %d" % _profile_ids[i]
		label.position = obj.position + Vector3(0, aabb.size.y + 3.0, 0)
		label.font_size = 28
		label.pixel_size = 0.04
		label.outline_size = 6
		label.modulate = wire_color
		_display_root.add_child(label)


func _build_wire_box(aabb: AABB, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	mi.mesh = im

	var s := aabb.size
	var corners: Array[Vector3] = []
	for y in [0.0, s.y]:
		for z in [0.0, s.z]:
			for x in [0.0, s.x]:
				corners.append(aabb.position + Vector3(x, y, z))

	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_set_color(color)
	var edges := [
		[0,1],[2,3],[4,5],[6,7],
		[0,2],[1,3],[4,6],[5,7],
		[0,4],[1,5],[2,6],[3,7],
	]
	for e in edges:
		im.surface_add_vertex(corners[e[0]])
		im.surface_add_vertex(corners[e[1]])
	im.surface_end()

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = false
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


# --- Input ------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not Engine.is_editor_hint():
		return
	if not event is InputEventKey:
		return
	var ke := event as InputEventKey
	if not ke.pressed or ke.echo:
		return
	match ke.keycode:
		KEY_1, KEY_2, KEY_3, KEY_4:
			var idx := ke.keycode - KEY_1
			if idx < _autoobjects.size():
				_autoobjects[idx].visible = not _autoobjects[idx].visible
				if idx < _wireframes.size():
					_wireframes[idx].visible = _autoobjects[idx].visible
				_update_hud()
		KEY_G:
			_print_gpu_report()
		KEY_SPACE:
			_register_all_assets()
			_update_hud()
		_:
			return
	get_viewport().set_input_as_handled()


func _print_gpu_report() -> void:
	if _spa == null:
		print("[SPA Demo] No SPA instance")
		return
	var report := _spa.get_gpu_readiness_report()
	print("[SPA Demo] GPU Readiness Report:")
	for key in report.keys():
		print("  %s: %s" % [key, str(report[key])])


# --- HUD --------------------------------------------------------------------

func _setup_hud() -> void:
	var hud := CanvasLayer.new()
	hud.name = "HUD"
	add_child(hud)
	_hud_label = Label.new()
	_hud_label.name = "Info"
	_hud_label.position = Vector2(24, 24)
	_hud_label.add_theme_font_size_override("font_size", 16)
	hud.add_child(_hud_label)


func _update_hud() -> void:
	if _hud_label == null:
		return
	var gpu_ready := _spa.is_gpu_ready() if _spa != null else false
	var rd_ok := RenderingServer.get_rendering_device() != null
	var lines: Array[String] = [
		"ScenePlacementActor (SPA) — Interactive Demo",
		"",
		"RenderingDevice: %s   SPA init: %s (%.0f ms)" % [
			"ready" if rd_ok else "NONE",
			"OK" if _initialized else "FAILED",
			_init_time_ms],
		"GPU ready: %s   Assets registered: %d (%.0f ms)" % [
			"YES" if gpu_ready else "NO",
			_descriptors.size(), _register_time_ms],
		"",
		"1-4: toggle asset visibility   G: GPU report   Space: re-register",
		"",
	]

	for i in range(_autoobjects.size()):
		var name_str: String = ASSET_NAMES[i] if i < ASSET_NAMES.size() else str(i)
		var visible_str := "visible" if _autoobjects[i].visible else "hidden"
		var pid := _profile_ids[i] if i < _profile_ids.size() else -1
		var aabb_str := ""
		if _autoobjects[i].mesh != null:
			var aabb := _autoobjects[i].mesh.get_aabb()
			aabb_str = "aabb=(%.1f, %.1f, %.1f)" % [aabb.size.x, aabb.size.y, aabb.size.z]
		lines.append("[%d] %s  profile_id=%d  %s  %s" % [
			i + 1, name_str, pid, aabb_str, visible_str])

	if _spa != null and gpu_ready:
		lines.append("")
		lines.append("Profile container: GPU-resident, all buffers valid")

	_hud_label.text = "\n".join(lines)


func _frame_camera() -> void:
	var cam := get_node_or_null("DemoSetup/FlyCamera") as Camera3D
	if cam == null:
		return
	cam.global_position = Vector3(0.0, 80.0, 150.0)
	cam.look_at(Vector3.ZERO, Vector3.UP)
	cam.fov = 55.0


func _exit_tree() -> void:
	if _spa != null:
		_spa.dispose()
		_spa = null
