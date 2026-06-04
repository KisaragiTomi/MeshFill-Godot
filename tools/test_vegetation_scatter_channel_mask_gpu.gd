extends SceneTree

const MainScript := preload("res://scripts/main.gd")


func _init() -> void:
	var main = MainScript.new()
	var occupancy := Image.create(4, 4, false, Image.FORMAT_RGBAH)
	occupancy.fill(Color(0.0, 0.0, 0.0, 0.0))
	occupancy.set_pixelv(Vector2i(1, 2), Color(0.1, 0.2, 0.75, 0.4))
	occupancy.set_pixelv(Vector2i(2, 1), Color(0.1, 0.2, 0.005, 0.4))

	var mask := main._make_vegetation_channel_mask_from_occupancy(occupancy, 2)
	if mask == null or mask.is_empty():
		print("[AutoObjectMaskGPU] SKIP: no RenderingDevice available for GPU channel mask")
		main.free()
		quit(0)
		return
	if mask.get_width() != 256 or mask.get_height() != 256 or mask.get_format() != Image.FORMAT_RF:
		push_error("[AutoObjectMaskGPU] R32F output size/format contract failed")
		main.free()
		quit(1)
		return
	if mask.get_pixelv(Vector2i(1, 2)).r <= 0.7:
		push_error("[AutoObjectMaskGPU] selected channel was not copied")
		main.free()
		quit(1)
		return
	if mask.get_pixelv(Vector2i(2, 1)).r > 0.001:
		push_error("[AutoObjectMaskGPU] below-threshold value was not zeroed")
		main.free()
		quit(1)
		return

	var activity := main._make_autoobject_activity_mask_from_occupancy(occupancy)
	if activity == null or activity.is_empty():
		push_error("[AutoObjectMaskGPU] all-channel AutoObject activity mask failed")
		main.free()
		quit(1)
		return
	if activity.get_width() != 256 or activity.get_height() != 256 or activity.get_format() != Image.FORMAT_RGBAH:
		push_error("[AutoObjectMaskGPU] all-channel activity output size/format contract failed")
		main.free()
		quit(1)
		return
	var active := activity.get_pixelv(Vector2i(1, 2))
	if active.r <= 0.09 or active.g <= 0.19 or active.b <= 0.7 or active.a <= 0.39:
		push_error("[AutoObjectMaskGPU] all-channel activity mask should preserve active channels")
		main.free()
		quit(1)
		return
	if activity.get_pixelv(Vector2i(2, 1)).b > 0.001:
		push_error("[AutoObjectMaskGPU] all-channel activity mask should zero below-threshold blue")
		main.free()
		quit(1)
		return

	print("[AutoObjectMaskGPU] OK: selected channel and all-channel AutoObject masks are copied, thresholded, bounded, and read back")
	main.free()
	quit(0)
