extends SceneTree

const SCENE_PATH := "res://demos/core-sv-anchor-collection/core-sv-anchor-collection.tscn"
const SHOT_DIR := "res://tools/_shots"
const SHOT_NAME := "sv_anchor_collection_anchor_arrows.png"
const UtilsShotUtils := preload("res://scripts/utils_shot_utils.gd")


func _initialize() -> void:
	_run()


func _run() -> void:
	var packed: PackedScene = load(SCENE_PATH)
	if packed == null:
		print("[ANCHOR_SHOT] FAIL load scene: ", SCENE_PATH)
		quit(1)
		return

	var inst := packed.instantiate()
	root.add_child(inst)
	print("[ANCHOR_SHOT] scene instanced: ", inst.name)

	for i in range(30):
		await process_frame

	var ok := await _verify_and_capture(inst)
	print("[ANCHOR_SHOT] RESULT ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)


func _verify_and_capture(inst: Node) -> bool:
	var ok := true
	UtilsShotUtils.ensure_dir(SHOT_DIR)

	var terrain := inst.find_child("Terrain", true, false)
	if terrain is MeshInstance3D:
		print("[ANCHOR_SHOT] terrain visible=", (terrain as MeshInstance3D).visible)
		if not (terrain as MeshInstance3D).visible:
			print("[ANCHOR_SHOT] FAIL terrain should be visible")
			ok = false
	else:
		print("[ANCHOR_SHOT] FAIL terrain node missing")
		ok = false

	var before_count := int(inst.get("_anchor_count"))
	var before_collected := bool(inst.get("_collected"))
	print("[ANCHOR_SHOT] before Shift+G collected=", before_collected, " anchors=", before_count)
	if before_collected or before_count != 0:
		print("[ANCHOR_SHOT] FAIL anchors should not be computed before Shift+G")
		ok = false

	var shift_g := InputEventKey.new()
	shift_g.keycode = KEY_G
	shift_g.physical_keycode = KEY_G
	shift_g.pressed = true
	shift_g.shift_pressed = true
	inst.call("_unhandled_input", shift_g)

	for i in range(8):
		await process_frame

	var key_4 := InputEventKey.new()
	key_4.keycode = KEY_4
	key_4.physical_keycode = KEY_4
	key_4.pressed = true
	inst.call("_unhandled_input", key_4)

	for i in range(8):
		await process_frame

	var anchor_count := int(inst.get("_anchor_count"))
	var collected := bool(inst.get("_collected"))
	var current_layer := str(inst.get("_current_layer"))
	print("[ANCHOR_SHOT] after Shift+G collected=", collected, " anchors=", anchor_count, " layer=", current_layer)
	if not collected:
		print("[ANCHOR_SHOT] FAIL anchors were not computed")
		ok = false
	if anchor_count != 1:
		print("[ANCHOR_SHOT] FAIL expected exactly 1 collected anchor, got ", anchor_count)
		ok = false
	if current_layer != "anchor":
		print("[ANCHOR_SHOT] FAIL expected anchor layer, got ", current_layer)
		ok = false

	var display := inst.get_node_or_null("AnchorDisplay")
	if display == null:
		print("[ANCHOR_SHOT] FAIL AnchorDisplay missing")
		ok = false
	else:
		var arrows := 0
		var child_names: Array[String] = []
		for child in display.get_children():
			child_names.append(str(child.name))
			if child.get_node_or_null("Shaft") != null and child.get_node_or_null("Head") != null:
				arrows += 1
		print("[ANCHOR_SHOT] anchor display children=", child_names)
		print("[ANCHOR_SHOT] anchor arrow nodes=", arrows)
		if arrows != 4:
			print("[ANCHOR_SHOT] FAIL expected 4 anchor arrows")
			ok = false

	var cam := inst.get_node_or_null("DemoSetup/FlyCamera") as Camera3D
	if cam != null:
		cam.global_position = Vector3(14.0, 12.0, 18.0)
		cam.look_at(Vector3(0.0, 1.2, 0.0), Vector3.UP)
		cam.fov = 50.0
		print("[ANCHOR_SHOT] camera framed")
	else:
		print("[ANCHOR_SHOT] FAIL camera missing")
		ok = false

	RenderingServer.force_draw(true)
	for i in range(4):
		await process_frame

	var result := UtilsShotUtils.save_viewport_png(root, "%s/%s" % [SHOT_DIR, SHOT_NAME])
	if not bool(result.get("ok", false)):
		var err := int(result.get("error", FAILED))
		print("[ANCHOR_SHOT] FAIL save screenshot err=", error_string(err))
		return false
	var img := result.get("image", null) as Image
	var path := str(result.get("path", ""))
	print("[ANCHOR_SHOT] saved ", path, " (", img.get_width(), "x", img.get_height(), ")")
	return ok
