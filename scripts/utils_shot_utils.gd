@tool
extends RefCounted

const UtilsDemoUI := preload("res://scripts/utils_demo_ui.gd")


static func ensure_dir(path: String) -> void:
	if path.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path))


static func capture_viewport_image(viewport: Viewport) -> Image:
	if viewport == null:
		return null
	var texture := viewport.get_texture()
	if texture == null:
		return null
	return texture.get_image()


static func save_viewport_png(
	viewport: Viewport,
	output_path: String,
	empty_ok: bool = false,
	include_hash: bool = false
) -> Dictionary:
	var result := {
		"ok": false,
		"skipped": false,
		"image": null,
		"path": ProjectSettings.globalize_path(output_path),
		"hash": "",
		"error": OK,
		"reason": "",
	}
	if output_path.is_empty():
		result["error"] = ERR_INVALID_PARAMETER
		result["reason"] = "empty output path"
		return result
	if viewport == null:
		result["error"] = ERR_INVALID_PARAMETER
		result["reason"] = "viewport unavailable"
		return result
	var texture := viewport.get_texture()
	if texture == null:
		result["ok"] = empty_ok
		result["skipped"] = empty_ok
		result["error"] = ERR_UNAVAILABLE
		result["reason"] = "viewport texture unavailable"
		return result
	var img := texture.get_image()
	if img == null or img.is_empty():
		result["ok"] = empty_ok
		result["skipped"] = empty_ok
		result["error"] = ERR_UNAVAILABLE
		result["reason"] = "image empty"
		return result
	result["image"] = img
	ensure_dir(output_path.get_base_dir())
	var err := img.save_png(result["path"])
	result["error"] = err
	if err != OK:
		result["reason"] = "save failed"
		return result
	result["ok"] = true
	if include_hash:
		result["hash"] = FileAccess.get_md5(result["path"])
	return result


static func find_camera_recursive(root_node: Node) -> Camera3D:
	return UtilsDemoUI.find_any_camera(root_node, false, false)


static func image_diff_ratio(a, b, step: int = 2, threshold: float = 0.08) -> float:
	if a == null or b == null:
		return 0.0
	if not (a is Image) or not (b is Image):
		return 0.0
	var img_a := a as Image
	var img_b := b as Image
	var w := mini(img_a.get_width(), img_b.get_width())
	var h := mini(img_a.get_height(), img_b.get_height())
	if w <= 0 or h <= 0:
		return 0.0
	var changed := 0
	var sampled := 0
	var sample_step := maxi(step, 1)
	for y in range(0, h, sample_step):
		for x in range(0, w, sample_step):
			var ca := img_a.get_pixel(x, y)
			var cb := img_b.get_pixel(x, y)
			var d := absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b) + absf(ca.a - cb.a)
			if d > threshold:
				changed += 1
			sampled += 1
	return float(changed) / float(maxi(sampled, 1))
