extends SceneTree

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
	var img := root.get_texture().get_image()
	if img == null or img.is_empty():
		push_error("viewport image empty")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_shots"))
	img.save_png(ProjectSettings.globalize_path("res://_shots/brush_overlay_test.png"))
	print("Screenshot saved to _shots/brush_overlay_test.png")
	quit(0)
