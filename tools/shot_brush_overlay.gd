extends SceneTree

const CommonShotUtils := preload("res://scripts/common_shot_utils.gd")

func _initialize() -> void:
	var packed: PackedScene = load("res://demos/target-sv-point-cloud-conversion-c/target-sv-point-cloud-conversion.tscn")
	if packed == null:
		push_error("Failed to load brush overlay scene")
		quit(1)
		return
	root.add_child(packed.instantiate())
	for i in range(60):
		await process_frame
	RenderingServer.force_draw(true)
	await process_frame
	var result := CommonShotUtils.save_viewport_png(root, "res://_shots/brush_overlay_test.png")
	if not bool(result.get("ok", false)):
		push_error("screenshot failed: %s" % result.get("reason", "unknown"))
		quit(1)
		return
	print("Screenshot saved to _shots/brush_overlay_test.png")
	quit(0)
