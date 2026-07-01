extends SceneTree

const SCENE_PATH := "res://demos/target-sv-point-cloud-conversion-c/target-sv-point-cloud-conversion.tscn"
const SHOT_DIR := "res://tools/_shots"
const VP_SIZE := Vector2i(1152, 648)
const MIN_PAINT_DIFF := 0.002
const MIN_MODE_DIFF := 0.0005
const UtilsShotUtils := preload("res://scripts/utils_shot_utils.gd")

var _vp: SubViewport
var _demo: Node
var _camera: Camera3D


func _initialize() -> void:
	_run()


func _run() -> void:
	if RenderingServer.get_rendering_device() == null:
		print("[BRUSH_SHOT] FAIL no MAIN RenderingDevice; run with --rendering-driver vulkan and without --headless")
		quit(1)
		return

	UtilsShotUtils.ensure_dir(SHOT_DIR)

	var packed := load(SCENE_PATH) as PackedScene
	if packed == null:
		print("[BRUSH_SHOT] FAIL load scene: ", SCENE_PATH)
		quit(1)
		return

	_vp = SubViewport.new()
	_vp.size = VP_SIZE
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.handle_input_locally = true
	root.add_child(_vp)

	_demo = packed.instantiate()
	_vp.add_child(_demo)
	print("[BRUSH_SHOT] scene instanced: ", _demo.name)

	await _settle(50)
	_camera = UtilsShotUtils.find_camera_recursive(_demo)
	if _camera == null:
		print("[BRUSH_SHOT] FAIL camera missing")
		quit(1)
		return

	_configure_visual_probe()
	await _settle(12)

	var before := await _shot("brush_overlay_00_before")
	var paint_ok := await _trigger_brush_paint()
	await _settle(14)
	var rgb := await _shot("brush_overlay_01_rgb")

	var ok := paint_ok
	var paint_diff := UtilsShotUtils.image_diff_ratio(before.get("image", null), rgb.get("image", null))
	print("[BRUSH_SHOT] diff before->rgb=", "%.5f" % paint_diff)
	if paint_diff < MIN_PAINT_DIFF:
		print("[BRUSH_SHOT] FAIL painted screenshot is too close to baseline")
		ok = false

	ok = await _switch_mode(KEY_T, 1, "complexity") and ok
	var complexity := await _shot("brush_overlay_02_complexity")
	var complexity_diff := UtilsShotUtils.image_diff_ratio(rgb.get("image", null), complexity.get("image", null))
	print("[BRUSH_SHOT] diff rgb->complexity=", "%.5f" % complexity_diff)
	if complexity_diff < MIN_MODE_DIFF:
		print("[BRUSH_SHOT] FAIL complexity mode screenshot did not visibly change")
		ok = false

	ok = await _switch_mode(KEY_Y, 2, "collision") and ok
	var collision := await _shot("brush_overlay_03_collision")
	var collision_diff := UtilsShotUtils.image_diff_ratio(complexity.get("image", null), collision.get("image", null))
	print("[BRUSH_SHOT] diff complexity->collision=", "%.5f" % collision_diff)
	if collision_diff < MIN_MODE_DIFF:
		print("[BRUSH_SHOT] FAIL collision mode screenshot did not visibly change")
		ok = false

	ok = await _switch_mode(KEY_R, 0, "rgb") and ok
	var rgb_again := await _shot("brush_overlay_04_rgb_again")
	var rgb_return_diff := UtilsShotUtils.image_diff_ratio(rgb.get("image", null), rgb_again.get("image", null))
	print("[BRUSH_SHOT] diff rgb->rgb_again=", "%.5f" % rgb_return_diff)

	print("[BRUSH_SHOT] RESULT ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)


func _configure_visual_probe() -> void:
	_demo.set("_brush_width", 56)
	_demo.set("_brush_length", 56)
	_demo.set("_brush_height", mini(maxi(int(_demo.get("_slice_count")), 1), 8))
	_demo.set("_brush_color_r", 1.0)
	_demo.set("_brush_color_g", 0.0)
	_demo.set("_brush_color_b", 1.0)
	_demo.set("_brush_complexity", 0.85)
	_demo.set("_brush_collision", 0.25)
	_demo.call("_clear_brush")

	var guidance := _demo.get_node_or_null("GuidanceVoxels") as Node3D
	if guidance != null:
		guidance.visible = false
	var terrain := _demo.find_child("Terrain", true, false) as Node3D
	if terrain != null:
		terrain.visible = false

	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = 360.0
	_camera.near = 0.05
	_camera.far = 2000.0
	_camera.current = true
	_camera.global_position = Vector3(0.0, 260.0, 260.0)
	_camera.look_at(Vector3(0.0, 45.0, 0.0), Vector3.UP)
	print("[BRUSH_SHOT] visual probe configured")


func _trigger_brush_paint() -> bool:
	var texture_size := int(_demo.get("_texture_size"))
	var center := Vector2i(texture_size / 2, texture_size / 2)
	var world := _demo.call("_voxel_to_world", center.x, 0, center.y) as Vector3
	var screen_pos := _camera.unproject_position(world)
	print("[BRUSH_SHOT] projected paint center voxel=", center, " screen=", screen_pos)

	var before_count := int((_demo.call("get_brush_state") as Dictionary).get("brush_voxel_count", 0))
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = screen_pos
	down.global_position = screen_pos
	_demo.call("_unhandled_input", down)
	await _settle(6)

	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = screen_pos
	up.global_position = screen_pos
	_demo.call("_unhandled_input", up)
	await _settle(10)

	var after_count := int((_demo.call("get_brush_state") as Dictionary).get("brush_voxel_count", 0))
	var brush := _demo.get_node_or_null("BrushTetraVoxels") as MultiMeshInstance3D
	var rendered_count := brush.multimesh.instance_count if brush != null and brush.multimesh != null else 0
	print("[BRUSH_SHOT] brush count before=", before_count, " after=", after_count, " rendered=", rendered_count)
	if after_count <= before_count:
		print("[BRUSH_SHOT] FAIL brush input path added no voxels")
		return false
	if rendered_count != after_count:
		print("[BRUSH_SHOT] FAIL rendered instance count does not match brush state")
		return false
	return true


func _switch_mode(keycode: Key, expected_mode: int, label: String) -> bool:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.physical_keycode = keycode
	ev.shift_pressed = true
	ev.pressed = true
	_demo.call("_unhandled_input", ev)
	await _settle(12)
	var actual := int(_demo.get("_brush_display_mode"))
	if actual != expected_mode:
		print("[BRUSH_SHOT] FAIL mode switch ", label, " expected=", expected_mode, " actual=", actual)
		return false
	print("[BRUSH_SHOT] mode ok ", label, " = ", actual)
	return true


func _settle(frames: int = 8) -> void:
	for i in range(frames):
		await process_frame
	RenderingServer.force_draw(true)
	await process_frame


func _shot(tag: String) -> Dictionary:
	await _settle(3)
	var result := UtilsShotUtils.save_viewport_png(_vp, "%s/%s.png" % [SHOT_DIR, tag], false, true)
	var img := result.get("image", null) as Image
	if img == null:
		print("[BRUSH_SHOT] FAIL empty image: ", tag, " reason=", result.get("reason", "image unavailable"))
		return {"ok": false, "image": null, "hash": ""}
	if not bool(result.get("ok", false)):
		var err := int(result.get("error", FAILED))
		print("[BRUSH_SHOT] FAIL save ", tag, " err=", error_string(err))
		return {"ok": false, "image": img, "hash": ""}
	var hash := str(result.get("hash", ""))
	var path := str(result.get("path", ""))
	print("[BRUSH_SHOT] saved ", tag, " size=", img.get_width(), "x", img.get_height(), " hash=", hash.substr(0, 8), " path=", path)
	return {"ok": true, "image": img, "hash": hash}
