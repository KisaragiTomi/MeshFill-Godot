extends SceneTree

const SETUP_PATH := "res://demos/utils_demo_setup.tscn"
const SHOT_DIR := "res://_shots"
const ShotUtils := preload("res://scripts/utils/shot_utils.gd")

func _initialize() -> void:
	_run()

func _run() -> void:
	var packed: PackedScene = load(SETUP_PATH)
	if packed == null:
		print("[SHOT] FAIL load common_demo_setup")
		quit(1)
		return
	var inst := packed.instantiate()
	root.add_child(inst)
	print("[SHOT] DemoSetup instanced: ", inst.name)

	var terrain := inst.find_child("Terrain", true, false)
	print("[SHOT] terrain found: ", terrain != null)
	if terrain is MeshInstance3D:
		var mi := terrain as MeshInstance3D
		print("[SHOT] terrain aabb=", mi.get_aabb(), " mesh=", mi.mesh != null)

	ShotUtils.ensure_dir(SHOT_DIR)
	var cam := inst.find_child("FlyCamera", true, false) as Camera3D

	for i in range(60):
		await process_frame

	if cam != null:
		cam.current = true
		cam.global_position = Vector3(0.0, 300.0, 400.0)
		cam.look_at(Vector3.ZERO, Vector3.UP)
		cam.fov = 55.0
		cam.far = 3000.0
	for i in range(10):
		await process_frame
	RenderingServer.force_draw(true)
	await process_frame
	await process_frame

	var shot1 := ShotUtils.save_viewport_png(root, SHOT_DIR + "/spa_cam_default.png", true)
	if bool(shot1.get("ok", false)) and not bool(shot1.get("skipped", false)):
		print("[SHOT] saved default view: cam=", cam.global_position if cam else "null")

	if cam != null:
		var half := 512.0
		cam.global_position = Vector3(-half * 0.3, half * 0.6, half * 0.8)
		cam.look_at(Vector3(0.0, 20.0, 0.0), Vector3.UP)
		cam.fov = 60.0
	for i in range(10):
		await process_frame
	RenderingServer.force_draw(true)
	await process_frame
	await process_frame

	var shot2 := ShotUtils.save_viewport_png(root, SHOT_DIR + "/spa_cam_spa.png", true)
	if bool(shot2.get("ok", false)) and not bool(shot2.get("skipped", false)):
		print("[SHOT] saved SPA view: cam=", cam.global_position if cam else "null")

	if cam != null:
		cam.global_position = Vector3(0.0, 600.0, 10.0)
		cam.look_at(Vector3.ZERO, Vector3.UP)
		cam.fov = 55.0
	for i in range(10):
		await process_frame
	RenderingServer.force_draw(true)
	await process_frame
	await process_frame

	var shot3 := ShotUtils.save_viewport_png(root, SHOT_DIR + "/spa_cam_topdown.png", true)
	if bool(shot3.get("ok", false)) and not bool(shot3.get("skipped", false)):
		print("[SHOT] saved top-down view")

	quit(0)
