@tool
extends "res://demos/core_demo_contract_fixture.gd"

# Probe prefilter demo: loads all geo meshes, generates semantic probes,
# and displays them with visual markers for inspection.

const ProbeProfile := preload("res://scripts/semantic_probe_profile.gd")

var _entries: Array[Dictionary] = []
var _selected_idx := -1
var _hud_label: Label
var _display_root: Node3D
var _marker_root: Node3D
var _probe_sphere: SphereMesh
var _mat_color: StandardMaterial3D
var _mat_collision: StandardMaterial3D
var _mat_support: StandardMaterial3D
var _mat_exclusion: StandardMaterial3D


func _ready() -> void:
	super._ready()
	if is_scene_startup_blocked():
		return
	_setup_materials()
	_setup_hud()
	_display_root = Node3D.new()
	_display_root.name = "MeshDisplay"
	add_child(_display_root)
	_marker_root = Node3D.new()
	_marker_root.name = "ProbeMarkers"
	add_child(_marker_root)
	_load_and_display.call_deferred()


func _setup_materials() -> void:
	_probe_sphere = SphereMesh.new()
	_probe_sphere.radius = 0.12
	_probe_sphere.height = 0.24
	_probe_sphere.radial_segments = 8
	_probe_sphere.rings = 4

	_mat_color = StandardMaterial3D.new()
	_mat_color.albedo_color = Color(0.2, 0.8, 0.3, 0.8)
	_mat_color.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_color.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	_mat_collision = StandardMaterial3D.new()
	_mat_collision.albedo_color = Color(1.0, 0.3, 0.2, 0.8)
	_mat_collision.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_collision.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	_mat_support = StandardMaterial3D.new()
	_mat_support.albedo_color = Color(0.3, 0.3, 1.0, 0.8)
	_mat_support.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_support.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	_mat_exclusion = StandardMaterial3D.new()
	_mat_exclusion.albedo_color = Color(1.0, 1.0, 0.0, 0.7)
	_mat_exclusion.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_exclusion.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED


func _setup_hud() -> void:
	var hud := CanvasLayer.new()
	hud.name = "HUD"
	add_child(hud)
	_hud_label = Label.new()
	_hud_label.name = "Info"
	_hud_label.position = Vector2(24, 24)
	_hud_label.add_theme_font_size_override("font_size", 16)
	hud.add_child(_hud_label)


func _load_and_display() -> void:
	_entries = _load_geo_meshes()
	_entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.volume) < float(b.volume))

	var x_offset := 0.0
	for i in range(_entries.size()):
		var entry: Dictionary = _entries[i]
		var m: Mesh = entry.mesh
		var aabb: AABB = m.get_aabb()
		var probes := ProbeProfile.generate_from_mesh(m, [], Color(0.5, 0.5, 0.5), 0.5, 1.0, 32)
		entry["probes"] = probes
		entry["x_offset"] = x_offset

		var mi := MeshInstance3D.new()
		mi.mesh = m
		mi.name = str(entry.name) + "_mesh"
		mi.position = Vector3(x_offset - aabb.position.x, -aabb.position.y, -aabb.position.z)
		_display_root.add_child(mi)
		entry["world_origin"] = mi.position

		x_offset += aabb.size.x + 2.0
		print("[ProbeDemo] %s  vol=%.2f  probes=%d  aabb=%s" % [
			entry.name, entry.volume, probes.size(), str(aabb)])

	if _entries.size() > 0:
		_selected_idx = 0
		_show_probes(_selected_idx)

	_frame_camera(x_offset)
	_update_hud()


func _frame_camera(total_width: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		cam = get_node_or_null("DemoSetup/FlyCamera") as Camera3D
	if cam == null:
		return
	var cx := total_width * 0.5
	var max_h := 0.0
	for entry in _entries:
		var m: Mesh = entry.mesh
		max_h = maxf(max_h, m.get_aabb().size.y)
	cam.global_position = Vector3(cx, max_h * 0.8, total_width * 0.4 + 5.0)
	cam.look_at(Vector3(cx, max_h * 0.3, 0.0), Vector3.UP)
	cam.fov = 55.0


func _show_probes(idx: int) -> void:
	for child in _marker_root.get_children():
		child.queue_free()
	if idx < 0 or idx >= _entries.size():
		return
	var entry: Dictionary = _entries[idx]
	var probes: Array = entry.get("probes", [])
	var origin: Vector3 = entry.get("world_origin", Vector3.ZERO)
	for probe in probes:
		if not probe is Dictionary:
			continue
		var p := probe as Dictionary
		var offset: Vector3 = p.get("offset", Vector3.ZERO)
		var mi := MeshInstance3D.new()
		mi.mesh = _probe_sphere
		mi.position = origin + offset
		mi.material_override = _pick_probe_material(p)
		_marker_root.add_child(mi)


func _pick_probe_material(probe: Dictionary) -> StandardMaterial3D:
	var wc := float(probe.get("w_collision", 1.0))
	var wcol := float(probe.get("w_color", 1.0))
	var wcx := float(probe.get("w_complexity", 1.0))
	if wc < 0.0:
		return _mat_exclusion
	if wcol < 0.1 and wcx < 0.1:
		return _mat_support
	if wc > wcol and wc > wcx:
		return _mat_collision
	return _mat_color


func _update_hud() -> void:
	if _hud_label == null:
		return
	var lines: Array[String] = [
		"Probe Prefilter Demo — geo mesh browser",
		"Left/Right: switch mesh   total=%d" % _entries.size(),
		"Green=color/complexity  Red=collision  Blue=support  Yellow=exclusion",
	]
	if _selected_idx >= 0 and _selected_idx < _entries.size():
		var entry: Dictionary = _entries[_selected_idx]
		var probes: Array = entry.get("probes", [])
		lines.append("[%d/%d] %s  vol=%.2f  probes=%d" % [
			_selected_idx + 1, _entries.size(), entry.name, entry.volume, probes.size()])
		for i in range(mini(probes.size(), 16)):
			var p: Dictionary = probes[i]
			lines.append("  #%d  off=%s  w_col=%.2f w_cx=%.2f w_coll=%.2f  src=%s" % [
				i,
				_v3_short(p.get("offset", Vector3.ZERO)),
				float(p.get("w_color", 1.0)),
				float(p.get("w_complexity", 1.0)),
				float(p.get("w_collision", 1.0)),
				str(p.get("source", "?"))])
		if probes.size() > 16:
			lines.append("  ... +%d more probes" % (probes.size() - 16))
	else:
		lines.append("No meshes found in res://geo/")
	_hud_label.text = "\n".join(lines)


static func _v3_short(v: Vector3) -> String:
	return "(%.1f, %.1f, %.1f)" % [v.x, v.y, v.z]


func _unhandled_input(event: InputEvent) -> void:
	if not Engine.is_editor_hint():
		return
	if not event is InputEventKey:
		return
	var ke := event as InputEventKey
	if not ke.pressed or ke.echo:
		return
	match ke.keycode:
		KEY_LEFT:
			_selected_idx = maxi(_selected_idx - 1, 0)
			_show_probes(_selected_idx)
			_update_hud()
		KEY_RIGHT:
			_selected_idx = mini(_selected_idx + 1, _entries.size() - 1)
			_show_probes(_selected_idx)
			_update_hud()
		_:
			return
	get_viewport().set_input_as_handled()


static func _load_geo_meshes() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var dir := DirAccess.open("res://geo")
	if dir == null:
		push_warning("[ProbeDemo] Cannot open res://geo")
		return result
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.to_lower().ends_with(".fbx"):
			var path := "res://geo/" + fname
			var res = load(path)
			if res is PackedScene:
				var mesh := _extract_mesh_from_scene(res as PackedScene)
				if mesh != null:
					var aabb := mesh.get_aabb()
					var vol := aabb.size.x * aabb.size.y * aabb.size.z
					result.append({"name": fname.get_basename(), "mesh": mesh, "volume": vol})
		fname = dir.get_next()
	dir.list_dir_end()
	return result


static func _extract_mesh_from_scene(scene: PackedScene) -> Mesh:
	var inst := scene.instantiate()
	if inst == null:
		return null
	var mesh: Mesh = null
	if inst is MeshInstance3D:
		mesh = (inst as MeshInstance3D).mesh
	else:
		for child in inst.get_children():
			if child is MeshInstance3D and (child as MeshInstance3D).mesh != null:
				mesh = (child as MeshInstance3D).mesh
				break
	inst.queue_free()
	return mesh
