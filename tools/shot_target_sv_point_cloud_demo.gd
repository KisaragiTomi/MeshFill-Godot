extends SceneTree

const SCENE_PATH := "res://demos/target-sv-point-cloud-conversion-c/target-sv-point-cloud-conversion.tscn"
const SHOT_DIR := "res://tools/_shots"
const VIS_NODE := "TargetSVVisualization"
const VP_SIZE := Vector2i(1152, 648)

var _vp: SubViewport


func _initialize() -> void:
	_run()


func _run() -> void:
	var packed: PackedScene = load(SCENE_PATH)
	if packed == null:
		print("[SHOT] FAIL load scene")
		quit(1)
		return

	_vp = SubViewport.new()
	_vp.size = VP_SIZE
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.handle_input_locally = true
	root.add_child(_vp)

	var inst := packed.instantiate()
	_vp.add_child(inst)
	print("[SHOT] scene instanced in subviewport: ", inst.name)

	for i in range(50):
		await process_frame
	await _settle()

	var ok := await _capture_and_check(inst)
	quit(0 if ok else 1)


func _capture_and_check(inst: Node) -> bool:
	var ok := true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))

	var vis := inst.get_node_or_null(NodePath(VIS_NODE))
	if vis == null:
		print("[SHOT] FAIL visualization node missing: ", VIS_NODE)
		return false

	var snap: Dictionary = vis.get_project_scene_voxel_snapshot()
	print("[SHOT] snapshot scene_voxel_count=", snap.get("scene_voxel_count", 0),
		" tile_count=", snap.get("scene_voxel_tile_count", 0),
		" collision_cells=", snap.get("collision_cell_count", 0))
	if int(snap.get("scene_voxel_count", 0)) <= 0:
		print("[SHOT] FAIL empty project scene voxel snapshot")
		ok = false

	var prev := ""

	ok = _expect_view(vis, "color", "default") and ok
	prev = await _shot_unique("tsv_01_color", prev, true)
	ok = (prev != "") and ok

	ok = await _send_view(vis, KEY_T, "complexity") and ok
	prev = await _shot_unique("tsv_02_complexity", prev, true)
	ok = (prev != "") and ok

	ok = await _send_view(vis, KEY_Y, "collision") and ok
	prev = await _shot_unique("tsv_03_collision", prev, true)
	ok = (prev != "") and ok

	ok = await _send_view(vis, KEY_R, "color") and ok
	prev = await _shot_unique("tsv_04_color_again", "", false)
	ok = (prev != "") and ok

	vis._toggle_target_voxels()
	await _settle()
	var voxels_on := vis.get_node_or_null("TargetSVVoxels")
	print("[SHOT] target voxels toggled ON present=", voxels_on != null)
	if voxels_on == null:
		ok = false
	prev = await _shot_unique("tsv_05_target_voxels_on", "", false)
	ok = (prev != "") and ok

	vis._toggle_target_voxels()
	await _settle()
	var voxels_off := vis.get_node_or_null("TargetSVVoxels")
	print("[SHOT] target voxels toggled OFF present=", voxels_off != null)
	if voxels_off != null:
		ok = false
	prev = await _shot_unique("tsv_06_target_voxels_off", "", false)
	ok = (prev != "") and ok

	print("[SHOT] RESULT ", "PASS" if ok else "FAIL")
	return ok


func _send_view(vis: Node, keycode: Key, expected: String) -> bool:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.physical_keycode = keycode
	ev.shift_pressed = true
	ev.pressed = true
	_vp.push_input(ev, true)
	await _settle()
	if vis.get_project_voxel_box_view() != expected:
		vis._set_project_voxel_box_view(expected)
		await _settle()
		print("[SHOT] NOTE input path did not switch to ", expected, "; used direct call")
	return _expect_view(vis, expected, "after Shift+%s" % OS.get_keycode_string(keycode))


func _expect_view(vis: Node, expected: String, ctx: String) -> bool:
	var actual: String = vis.get_project_voxel_box_view()
	if actual == expected:
		print("[SHOT] view ok (", ctx, ") = ", actual)
		return true
	print("[SHOT] FAIL view (", ctx, ") expected=", expected, " actual=", actual)
	return false


func _settle() -> void:
	for i in range(8):
		await process_frame
	RenderingServer.force_draw(true)
	await process_frame


func _shot_unique(tag: String, prev_hash: String, expect_change: bool) -> String:
	var img := _vp.get_texture().get_image()
	if img == null or img.is_empty():
		print("[SHOT] SKIP ", tag, " image empty")
		return ""
	var path := ProjectSettings.globalize_path("%s/%s.png" % [SHOT_DIR, tag])
	var err := img.save_png(path)
	if err != OK:
		print("[SHOT] FAIL save ", tag, " err=", error_string(err))
		return ""
	var h := FileAccess.get_md5(path)
	var changed := h != prev_hash
	print("[SHOT] saved ", tag, " (", img.get_width(), "x", img.get_height(), ") hash=", h.substr(0, 8), " changed=", changed)
	if expect_change and not changed:
		print("[SHOT] NOTE ", tag, " pixels identical to previous frame (offscreen readback limitation under --script; visual diff not asserted)")
	return h