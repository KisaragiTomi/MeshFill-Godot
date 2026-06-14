extends SceneTree

const SCENE_PATH := "res://demos/asset-descriptor-demo/asset-descriptor-demo.tscn"
const SHOT_DIR := "res://tools/_shots"


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

	# 等待 autoload 地形注入(call_deferred) + 多帧渲染稳定
	for i in range(40):
		await process_frame
	RenderingServer.force_draw(true)
	await process_frame

	var checks := await _capture_and_check(inst)
	quit(0 if checks else 1)


func _capture_and_check(inst: Node) -> bool:
	var ok := true

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))

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

	# Hide the autoloaded terrain so it doesn't occlude the demo assets
	var terrain_node := root.get_node_or_null("Terrain")
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

	# 功能点: 地形存在/可见 (note: hidden for framing but still present)
	var terrain := root.get_node_or_null("Terrain")
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

	# 截图 2: 契约执行后（重新隐藏地形）
	var terrain2 := root.get_node_or_null("Terrain")
	if terrain2 != null:
		terrain2.visible = false
	RenderingServer.force_draw(true)
	await process_frame
	ok = _shot("02_after_contract") and ok

	# 激活全部 mesh debug 显示：探针 + 碰撞体 + buffer info
	if inst.has_method("_toggle_all_probes"):
		inst._toggle_all_probes()
		print("[SHOT] activated all probes")
	if inst.has_method("_toggle_collision_volumes"):
		inst._toggle_collision_volumes()
		print("[SHOT] activated collision volumes")
	if inst.has_method("_toggle_buffer_info"):
		inst._toggle_buffer_info()
		print("[SHOT] activated buffer info")

	# 等待调试节点渲染，保持地形隐藏
	var terrain3 := root.get_node_or_null("Terrain")
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
	var vp_tex := root.get_texture()
	if vp_tex == null:
		print("[SHOT] SKIP ", tag, " viewport texture unavailable")
		return true
	var img := vp_tex.get_image()
	if img == null or img.is_empty():
		print("[SHOT] SKIP ", tag, " image empty")
		return true
	var path := ProjectSettings.globalize_path("%s/%s.png" % [SHOT_DIR, tag])
	var err := img.save_png(path)
	if err != OK:
		print("[SHOT] FAIL save ", tag, " err=", error_string(err))
		return false
	print("[SHOT] saved ", path, " (", img.get_width(), "x", img.get_height(), ")")
	return true
