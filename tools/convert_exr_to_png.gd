extends SceneTree

const RAW_PATH := "res://textures/scene_depth.raw"
const TEX_RES := 256
const MAX_HEIGHT := 50.0

const OUTPUT_PATH := "res://textures/scene_height_0_1.png"


func _init() -> void:
	var raw_img := _load_raw_rgba32f(RAW_PATH, TEX_RES, TEX_RES)
	if raw_img == null:
		quit(1)
		return

	_save_height_png(raw_img, OUTPUT_PATH)
	quit(0)

func _load_raw_rgba32f(path: String, width: int, height: int) -> Image:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("Failed to open raw file: %s" % path)
		return null

	var data := f.get_buffer(f.get_length())
	var expected_size := width * height * 4 * 4
	if data.size() != expected_size:
		push_warning("Raw size mismatch for %s: got %d, expected %d" % [path, data.size(), expected_size])
		return null

	return Image.create_from_data(width, height, false, Image.FORMAT_RGBAF, data)

func _height_min_max(img: Image) -> Vector2:
	var min_val := 9999.0
	var max_val := -9999.0
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			var depth := img.get_pixel(x, y).r
			var v := MAX_HEIGHT - depth
			min_val = minf(min_val, v)
			max_val = maxf(max_val, v)
	return Vector2(min_val, max_val)

func _save_height_png(img: Image, output_path: String) -> void:
	var mm := _height_min_max(img)
	print("height range: %.6f - %.6f" % [mm.x, mm.y])

	var out := Image.create(img.get_width(), img.get_height(), false, Image.FORMAT_L8)
	var range_val := maxf(mm.y - mm.x, 0.0001)
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			var depth := img.get_pixel(x, y).r
			var v := MAX_HEIGHT - depth
			var t := clampf((v - mm.x) / range_val, 0.0, 1.0)
			out.set_pixel(x, y, Color(t, t, t, 1.0))

	var err := out.save_png(output_path)
	if err != OK:
		push_error("Failed to save PNG: %s (error %d)" % [output_path, err])
	else:
		print("Saved height PNG to: %s" % output_path)
