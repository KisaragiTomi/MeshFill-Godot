extends SceneTree

const SCENE_PATH := "res://demos/asset-descriptor-demo/asset-descriptor-demo.tscn"
const SHOT_DIR := "res://tools/_shots"
const UtilsShotUtils := preload("res://scripts/utils_shot_utils.gd")


func _initialize() -> void:
	_run()


func _run() -> void:
	var packed: PackedScene = load(SCENE_PATH)
	if packed == null:
		print("[SHOT] FAIL load scene")
		quit(1)
		return
	var inst := packed.instantiate()
	root.add_child(inst)
	print("[SHOT] scene instanced: ", inst.name)

	# Wait for deferred terrain setup and viewport frames to settle.
	for i in range(40):
		await process_frame
	RenderingServer.force_draw(true)
	await process_frame

	var checks := await _capture_and_check(inst)
	quit(0 if checks else 1)


func _capture_and_check(inst: Node) -> bool:
	var ok := true

	UtilsShotUtils.ensure_dir(SHOT_DIR)

	# Force camera to look at the scene from above
	var cam := root.get_node_or_null("AssetDescriptorDemo/DemoSetup/FlyCamera") as Camera3D
	if cam == null:
		for child in root.get_children():
			var found := child.find_child("FlyCamera", true, false)
			if found is Camera3D:
				cam = found as Camera3D
				break
	if cam != null:
		cam.position = Vector3(0.0, 9.0, 15.0)
		cam.look_at(Vector3(0.0, 0.5, 2.0), Vector3.UP)
		cam.fov = 65.0
		var t := cam.global_transform
		print("[SHOT] cam pos=", t.origin, " fwd=", -t.basis.z, " up=", t.basis.y)

	var terrain_node := inst.find_child("Terrain", true, false) as Node3D
	if terrain_node != null:
		terrain_node.visible = false
		print("[SHOT] terrain hidden for framing")
	RenderingServer.force_draw(true)
	await process_frame
	await process_frame

	# 截图 1: 默认俯视（无调试）
	ok = _shot("01_default") and ok

	# Debug: print asset world positions
	var children := inst.get_children()
	for ch in children:
		if ch is Node3D and not ch.name.begins_with("Demo") and not ch.name.begins_with("Rim") \
				and not ch.name.begins_with("Title") and not ch.name.begins_with("Test") \
				and not ch.name.begins_with("Accept") and not ch.name.begins_with("Ground") \
				and not ch.name.begins_with("Buffer") and not ch.name.begins_with("Probe") \
				and not ch.name.begins_with("Collision"):
			print("[SHOT] asset pos: ", ch.name, " -> ", (ch as Node3D).global_position)

	var terrain := inst.find_child("Terrain", true, false)
	if terrain is MeshInstance3D:
		var mi := terrain as MeshInstance3D
		print("[SHOT] terrain present aabb=", mi.get_aabb())

	# 功能点: 标签节点文本
	for label_name in ["Title", "TestMethod", "Acceptance"]:
		var n := inst.get_node_or_null(NodePath(label_name))
		if n != null:
			print("[SHOT] label ", label_name, " ok")
		else:
			print("[SHOT] FAIL label missing: ", label_name)
			ok = false

	# 功能点: 契约自检
	if inst.has_method("run_demo_contract_checks"):
		var report: Dictionary = inst.run_demo_contract_checks({})
		print("[SHOT] contract ok=", report.get("ok", false),
			" rd_available=", report.get("rendering_device_available", false),
			" terrain_res=", report.get("terrain_resolution", 0))
		var failures: Array = report.get("failures", [])
		for f in failures:
			print("[SHOT]   contract_failure: ", f)
		if not bool(report.get("ok", false)):
			ok = false
	else:
		print("[SHOT] FAIL no run_demo_contract_checks")
		ok = false

	var terrain2 := inst.find_child("Terrain", true, false) as Node3D
	if terrain2 != null:
		terrain2.visible = false
	RenderingServer.force_draw(true)
	await process_frame
	ok = _shot("02_after_contract") and ok

	# 激活全部 mesh debug 显示：探针 + buffer info
	if inst.has_method("_toggle_all_probes"):
		inst._toggle_all_probes()
		print("[SHOT] activated all probes")
	if inst.has_method("_toggle_buffer_info"):
		inst._toggle_buffer_info()
		print("[SHOT] activated buffer info")

	var terrain3 := inst.find_child("Terrain", true, false) as Node3D
	if terrain3 != null:
		terrain3.visible = false
	for i in range(10):
		await process_frame
	RenderingServer.force_draw(true)
	await process_frame

	# 截图 3: mesh debug 全显示
	ok = _shot("03_mesh_debug_all") and ok

	print("[SHOT] RESULT ", "PASS" if ok else "FAIL")
	return ok


func _shot(tag: String) -> bool:
	var result := UtilsShotUtils.save_viewport_png(root, "%s/%s.png" % [SHOT_DIR, tag], true)
	if bool(result.get("skipped", false)):
		print("[SHOT] SKIP ", tag, " ", result.get("reason", "image unavailable"))
		return true
	if not bool(result.get("ok", false)):
		var err := int(result.get("error", FAILED))
		print("[SHOT] FAIL save ", tag, " err=", error_string(err))
		return false
	var img := result.get("image", null) as Image
	var path := str(result.get("path", ""))
	print("[SHOT] saved ", path, " (", img.get_width(), "x", img.get_height(), ")")
	return true
