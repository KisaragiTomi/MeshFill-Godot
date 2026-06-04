extends SceneTree

const MainScript := preload("res://scripts/main.gd")
const SNAPSHOT_DIR := "res://docs/graphs/qa"
const SNAPSHOT_PATH := SNAPSHOT_DIR + "/brush_dimension_ui.png"


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var ok := true
	ok = _test_brush_dimensions_drive_footprint_and_slices() and ok
	ok = _test_landscape_cliff_mask_contract() and ok
	ok = _test_vegetation_channel_mask_contract() and ok
	ok = _test_has_mask_pixels_contract() and ok
	ok = _test_target_height_override_composite_contract() and ok
	ok = _test_rock_mask_override_composite_contract() and ok
	ok = _test_override_invalidation_contract() and ok
	ok = _test_combined_mask_debug_contract() and ok
	ok = _test_debug_mask_terrain_uses_combined_mask_contract() and ok
	ok = _test_height_diff_to_color_contract() and ok
	ok = _test_debug_target_height_terrain_uses_packed_values_contract() and ok
	ok = _test_diff_terrain_uses_packed_values_contract() and ok
	ok = _test_target_sv_overlay_uses_packed_values_contract() and ok
	ok = _test_current_height_mask_to_color_contract() and ok
	ok = _test_height_to_grayscale_contract() and ok
	ok = _test_scale_height_image_contract() and ok
	ok = _test_delta_to_heatmap_contract() and ok
	ok = _test_delta_stats_contract() and ok
	ok = _test_terrain_avg_height_contract() and ok
	ok = _test_height_difference_stats_contract() and ok
	ok = _test_height_stats_contract() and ok
	ok = _test_capture_rock_mask_contract() and ok
	ok = _test_create_cliff_height_image_contract() and ok
	ok = _test_clear_override_tile_contract() and ok
	ok = _test_paint_brush_footprint_contract() and ok
	ok = await _capture_brush_dimension_ui_snapshot() and ok
	if ok:
		print("[BrushDimensionUI] ALL TESTS PASSED")
		quit(0)
	else:
		quit(1)


func _test_brush_dimensions_drive_footprint_and_slices() -> bool:
	print("[BrushDimensionUI] test_brush_dimensions_drive_footprint_and_slices...")
	var main = MainScript.new()
	main._init_override_images()
	main._set_brush_dimensions(7, 3, 4)

	var rect: Rect2i = main._brush_footprint_rect(Vector2i(10, 10))
	if rect != Rect2i(Vector2i(7, 9), Vector2i(7, 3)):
		push_error("  FAIL: unexpected footprint rect %s" % str(rect))
		main.free()
		return false

	var slices: Array[int] = main._brush_slice_indices()
	if slices.size() != 4 or slices != [0, 1, 2, 3]:
		push_error("  FAIL: unexpected brush slice indices %s" % str(slices))
		main.free()
		return false

	var bounds: Dictionary = main._base_rect_to_scene_voxel_bounds(rect, slices)
	if bounds.get("voxel_min", Vector3i.ZERO) != Vector3i(7, 0, 9) \
			or bounds.get("voxel_max", Vector3i.ZERO) != Vector3i(14, 4, 12):
		push_error("  FAIL: unexpected brush voxel bounds %s" % str(bounds))
		main.free()
		return false

	main._paint_brush_footprint(Vector2i(10, 10), 2.0)
	var mask = main._override_mask
	var marked := main._has_mask_pixels_gpu(mask, 0.01)
	if marked < 0:
		push_error("  FAIL: GPU mask count failed")
		main.free()
		return false
	if marked != 21:
		push_error("  FAIL: expected 7x3 footprint to mark 21 pixels, got %d" % marked)
		main.free()
		return false

	main.free()
	print("  OK: footprint=7x3 slices=4 marked=21")
	return true


func _test_landscape_cliff_mask_contract() -> bool:
	print("[BrushDimensionUI] test_landscape_cliff_mask_contract...")
	var main = MainScript.new()
	main.capture_size = 8.0
	main.landscape_cliff_slope_start = 0.1
	main.landscape_cliff_slope_full = 0.2

	var flat := Image.create(8, 8, false, Image.FORMAT_RF)
	flat.fill(Color(0.0, 0.0, 0.0, 0.0))
	var flat_mask: Image = main._make_landscape_cliff_mask(flat)
	if flat_mask.get_pixelv(Vector2i(128, 128)).r > 0.001:
		push_error("  FAIL: flat height image should not produce cliff mask")
		main.free()
		return false

	var slope := Image.create(8, 8, false, Image.FORMAT_RF)
	for y in range(8):
		for x in range(8):
			slope.set_pixelv(Vector2i(x, y), Color(float(x), 0.0, 0.0, 0.0))
	var slope_mask: Image = main._make_landscape_cliff_mask(slope)
	if slope_mask.get_pixelv(Vector2i(128, 128)).r <= 0.01:
		push_error("  FAIL: sloped height image should produce cliff mask")
		main.free()
		return false

	main.free()
	print("  OK: flat mask stays empty and sloped mask activates")
	return true


func _test_vegetation_channel_mask_contract() -> bool:
	print("[BrushDimensionUI] test_vegetation_channel_mask_contract...")
	var main = MainScript.new()
	var occupancy := Image.create(4, 4, false, Image.FORMAT_RGBAH)
	occupancy.fill(Color(0.0, 0.0, 0.0, 0.0))
	occupancy.set_pixelv(Vector2i(1, 2), Color(0.1, 0.2, 0.75, 0.4))
	occupancy.set_pixelv(Vector2i(2, 1), Color(0.1, 0.2, 0.005, 0.4))

	var mask: Image = main._make_vegetation_channel_mask_from_occupancy(occupancy, 2)
	if mask.get_pixelv(Vector2i(1, 2)).r <= 0.7:
		push_error("  FAIL: vegetation channel mask should copy selected channel")
		main.free()
		return false
	if mask.get_pixelv(Vector2i(2, 1)).r > 0.001:
		push_error("  FAIL: vegetation channel mask should zero values below threshold")
		main.free()
		return false
	if mask.get_pixelv(Vector2i(8, 8)).r > 0.001:
		push_error("  FAIL: vegetation channel mask should keep pixels outside source bounds empty")
		main.free()
		return false

	main.free()
	print("  OK: selected channel copied, thresholded, and bounded")
	return true


func _test_has_mask_pixels_contract() -> bool:
	print("[BrushDimensionUI] test_has_mask_pixels_contract...")
	var main = MainScript.new()
	var mask := Image.create(256, 256, false, Image.FORMAT_RF)
	mask.fill(Color(0.0, 0.0, 0.0, 0.0))
	if main._has_mask_pixels(mask, 0.01):
		push_error("  FAIL: empty mask should not report active pixels")
		main.free()
		return false
	mask.set_pixelv(Vector2i(64, 96), Color(0.02, 0.0, 0.0, 0.0))
	mask.set_pixelv(Vector2i(65, 96), Color(0.005, 0.0, 0.0, 0.0))
	if not main._has_mask_pixels(mask, 0.01):
		push_error("  FAIL: mask should report pixels above threshold")
		main.free()
		return false
	if main._has_mask_pixels(mask, 0.05):
		push_error("  FAIL: mask should respect the requested threshold")
		main.free()
		return false
	main.free()
	print("  OK: GPU mask scan detects active pixels and respects threshold")
	return true


func _test_target_height_override_composite_contract() -> bool:
	print("[BrushDimensionUI] test_target_height_override_composite_contract...")
	var main = MainScript.new()
	main._cached_textures = {}
	var base := Image.create(256, 256, false, Image.FORMAT_RGBAF)
	base.fill(Color(10.0, 0.25, 0.5, 1.0))
	main._cached_textures["target_height"] = ImageTexture.create_from_image(base)
	main._override_mask = Image.create(256, 256, false, Image.FORMAT_RF)
	main._override_mask.fill(Color(0.0, 0.0, 0.0, 0.0))
	main._override_delta = Image.create(256, 256, false, Image.FORMAT_RF)
	main._override_delta.fill(Color(0.0, 0.0, 0.0, 0.0))
	var changed_px := Vector2i(20, 30)
	var unchanged_px := Vector2i(21, 30)
	main._override_mask.set_pixelv(changed_px, Color(0.5, 0.0, 0.0, 0.0))
	main._override_delta.set_pixelv(changed_px, Color(4.0, 0.0, 0.0, 0.0))
	main._override_mask.set_pixelv(unchanged_px, Color(0.005, 0.0, 0.0, 0.0))
	main._override_delta.set_pixelv(unchanged_px, Color(9.0, 0.0, 0.0, 0.0))

	var tex := main._composite_target_height()
	var img := tex.get_image()
	var changed := img.get_pixelv(changed_px)
	if absf(changed.r - 12.0) > 0.001 or absf(changed.g - 0.25) > 0.001 or absf(changed.a - 1.0) > 0.001:
		push_error("  FAIL: target height GPU composite did not apply weighted delta, got %s" % str(changed))
		main.free()
		return false
	var unchanged := img.get_pixelv(unchanged_px)
	if absf(unchanged.r - 10.0) > 0.001:
		push_error("  FAIL: target height GPU composite should ignore values below threshold, got %s" % str(unchanged))
		main.free()
		return false

	main.free()
	print("  OK: weighted delta applied on GPU and below-threshold mask ignored")
	return true


func _test_rock_mask_override_composite_contract() -> bool:
	print("[BrushDimensionUI] test_rock_mask_override_composite_contract...")
	var main = MainScript.new()
	main._current_rock_mask_img = Image.create(256, 256, false, Image.FORMAT_RF)
	main._current_rock_mask_img.fill(Color(0.2, 0.0, 0.0, 0.0))
	main._rock_override_mask = Image.create(256, 256, false, Image.FORMAT_RF)
	main._rock_override_mask.fill(Color(0.0, 0.0, 0.0, 0.0))
	main._rock_override_delta = Image.create(256, 256, false, Image.FORMAT_RF)
	main._rock_override_delta.fill(Color(0.0, 0.0, 0.0, 0.0))
	var raised_px := Vector2i(40, 50)
	var clamped_px := Vector2i(41, 50)
	var unchanged_px := Vector2i(42, 50)
	main._rock_override_mask.set_pixelv(raised_px, Color(0.5, 0.0, 0.0, 0.0))
	main._rock_override_delta.set_pixelv(raised_px, Color(0.4, 0.0, 0.0, 0.0))
	main._rock_override_mask.set_pixelv(clamped_px, Color(1.0, 0.0, 0.0, 0.0))
	main._rock_override_delta.set_pixelv(clamped_px, Color(2.0, 0.0, 0.0, 0.0))
	main._rock_override_mask.set_pixelv(unchanged_px, Color(0.005, 0.0, 0.0, 0.0))
	main._rock_override_delta.set_pixelv(unchanged_px, Color(0.7, 0.0, 0.0, 0.0))

	var img := main._composite_rock_mask()
	var raised := img.get_pixelv(raised_px).r
	if absf(raised - 0.4) > 0.001:
		push_error("  FAIL: rock mask GPU composite did not apply weighted delta, got %.4f" % raised)
		main.free()
		return false
	var clamped := img.get_pixelv(clamped_px).r
	if absf(clamped - 1.0) > 0.001:
		push_error("  FAIL: rock mask GPU composite should clamp to one, got %.4f" % clamped)
		main.free()
		return false
	var unchanged := img.get_pixelv(unchanged_px).r
	if absf(unchanged - 0.2) > 0.001:
		push_error("  FAIL: rock mask GPU composite should ignore values below threshold, got %.4f" % unchanged)
		main.free()
		return false

	main.free()
	print("  OK: weighted delta applied on GPU, clamped, and below-threshold mask ignored")
	return true


func _test_override_invalidation_contract() -> bool:
	print("[BrushDimensionUI] test_override_invalidation_contract...")
	var main = MainScript.new()
	main.max_height = 10.0
	main._cached_textures = {}
	var scene_depth := Image.create(256, 256, false, Image.FORMAT_RGBAF)
	scene_depth.fill(Color(5.0, 0.0, 0.0, 1.0))
	main._cached_textures["scene_depth"] = ImageTexture.create_from_image(scene_depth)
	main._override_mask = Image.create(256, 256, false, Image.FORMAT_RF)
	main._override_mask.fill(Color(0.0, 0.0, 0.0, 0.0))
	main._override_delta = Image.create(256, 256, false, Image.FORMAT_RF)
	main._override_delta.fill(Color(0.0, 0.0, 0.0, 0.0))
	main._dep_terrain = Image.create(256, 256, false, Image.FORMAT_RF)
	main._dep_terrain.fill(Color(5.0, 0.0, 0.0, 0.0))
	main._dep_rock = Image.create(256, 256, false, Image.FORMAT_RF)
	main._dep_rock.fill(Color(0.0, 0.0, 0.0, 0.0))
	main._current_rock_mask_img = Image.create(256, 256, false, Image.FORMAT_RF)
	main._current_rock_mask_img.fill(Color(0.0, 0.0, 0.0, 0.0))

	var terrain_px := Vector2i(12, 13)
	var rock_px := Vector2i(14, 13)
	var stable_px := Vector2i(16, 13)
	main._override_mask.set_pixelv(terrain_px, Color(1.0, 0.0, 0.0, 0.0))
	main._override_delta.set_pixelv(terrain_px, Color(2.0, 0.0, 0.0, 0.0))
	main._dep_terrain.set_pixelv(terrain_px, Color(3.0, 0.0, 0.0, 0.0))
	main._override_mask.set_pixelv(rock_px, Color(1.0, 0.0, 0.0, 0.0))
	main._override_delta.set_pixelv(rock_px, Color(3.0, 0.0, 0.0, 0.0))
	main._current_rock_mask_img.set_pixelv(rock_px, Color(0.8, 0.0, 0.0, 0.0))
	main._override_mask.set_pixelv(stable_px, Color(1.0, 0.0, 0.0, 0.0))
	main._override_delta.set_pixelv(stable_px, Color(4.0, 0.0, 0.0, 0.0))

	main._invalidate_overrides()
	if main._override_mask.get_pixelv(terrain_px).r > 0.001 or main._override_delta.get_pixelv(terrain_px).r > 0.001:
		push_error("  FAIL: terrain-changed override pixel was not invalidated")
		main.free()
		return false
	if main._override_mask.get_pixelv(rock_px).r > 0.001 or main._override_delta.get_pixelv(rock_px).r > 0.001:
		push_error("  FAIL: rock-overlap override pixel was not invalidated")
		main.free()
		return false
	if absf(main._override_mask.get_pixelv(stable_px).r - 1.0) > 0.001 or absf(main._override_delta.get_pixelv(stable_px).r - 4.0) > 0.001:
		push_error("  FAIL: stable override pixel should remain intact")
		main.free()
		return false

	main.free()
	print("  OK: terrain and rock changes invalidate on GPU while stable pixels remain")
	return true


func _test_combined_mask_debug_contract() -> bool:
	print("[BrushDimensionUI] test_combined_mask_debug_contract...")
	var main = MainScript.new()
	main._current_rock_mask_img = Image.create(256, 256, false, Image.FORMAT_RF)
	main._current_rock_mask_img.fill(Color(0.0, 0.0, 0.0, 0.0))
	main._autoobject_mask_image = Image.create(256, 256, false, Image.FORMAT_RGBAH)
	main._autoobject_mask_image.fill(Color(0.0, 0.0, 0.0, 0.0))
	var px := Vector2i(32, 48)
	main._current_rock_mask_img.set_pixelv(px, Color(0.25, 0.0, 0.0, 0.0))
	main._autoobject_mask_image.set_pixelv(px, Color(0.0, 0.5, 0.75, 0.0))

	var img := main._make_combined_mask_debug_image()
	var c := img.get_pixelv(px)
	if absf(c.r - 0.25) > 0.01 or absf(c.g - 0.75) > 0.01 or c.b > 0.01 or absf(c.a - 1.0) > 0.01:
		push_error("  FAIL: combined mask debug image packed unexpected color %s" % str(c))
		main.free()
		return false
	var empty := img.get_pixelv(Vector2i(0, 0))
	if empty.r > 0.01 or empty.g > 0.01 or empty.b > 0.01 or absf(empty.a - 1.0) > 0.01:
		push_error("  FAIL: combined mask debug image should keep empty pixels black, got %s" % str(empty))
		main.free()
		return false

	main.free()
	print("  OK: rock and AutoObject activity channels packed into RGBA8 on GPU")
	return true


func _test_debug_mask_terrain_uses_combined_mask_contract() -> bool:
	print("[BrushDimensionUI] test_debug_mask_terrain_uses_combined_mask_contract...")
	var main = MainScript.new()
	var depth := Image.create(256, 256, false, Image.FORMAT_RGBAF)
	depth.fill(Color(main.max_height, 0.0, 0.0, 1.0))
	main._cached_textures = {"scene_depth": ImageTexture.create_from_image(depth)}
	main._current_rock_mask_img = Image.create(256, 256, false, Image.FORMAT_RF)
	main._current_rock_mask_img.fill(Color(0.0, 0.0, 0.0, 0.0))
	main._autoobject_mask_image = Image.create(256, 256, false, Image.FORMAT_RGBAH)
	main._autoobject_mask_image.fill(Color(0.0, 0.0, 0.0, 0.0))

	var px := Vector2i(32, 48)
	main._current_rock_mask_img.set_pixelv(px, Color(0.25, 0.0, 0.0, 0.0))
	main._autoobject_mask_image.set_pixelv(px, Color(0.0, 0.5, 0.75, 0.0))
	main._build_debug_mask_terrain()

	if main._debug_mask_terrain == null or main._debug_mask_terrain.mesh == null:
		push_error("  FAIL: debug mask terrain was not built")
		main.free()
		return false
	var arrays: Array = main._debug_mask_terrain.mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var active := colors[px.y * 256 + px.x]
	if absf(active.r - 0.25) > 0.01 or absf(active.g - 0.75) > 0.01 or active.b > 0.01:
		push_error("  FAIL: debug terrain did not use packed GPU mask channels: %s" % str(active))
		main.free()
		return false
	if absf(active.a - 0.45) > 0.02:
		push_error("  FAIL: debug terrain alpha should come from packed mask intensity: %s" % str(active))
		main.free()
		return false
	if absf(vertices[px.y * 256 + px.x].y - 0.2) > 0.001:
		push_error("  FAIL: debug terrain height should come from packed depth data: %s" % str(vertices[px.y * 256 + px.x]))
		main.free()
		return false
	var empty := colors[0]
	if empty.r > 0.01 or empty.g > 0.01 or empty.b > 0.01 or absf(empty.a - 0.02) > 0.01:
		push_error("  FAIL: empty debug terrain vertex should remain dim black: %s" % str(empty))
		main.free()
		return false

	main.free()
	print("  OK: debug mask terrain consumes GPU-packed mask channels")
	return true


func _test_height_diff_to_color_contract() -> bool:
	print("[BrushDimensionUI] test_height_diff_to_color_contract...")
	var main = MainScript.new()
	var target := Image.create(8, 8, false, Image.FORMAT_RGBAF)
	target.fill(Color(10.0, 0.0, 0.0, 1.0))
	var current := Image.create(8, 8, false, Image.FORMAT_RGBAF)
	current.fill(Color(10.0, 0.0, 1.0, 1.0))
	var red_px := Vector2i(1, 1)
	var blue_px := Vector2i(2, 1)
	var gray_px := Vector2i(3, 1)
	current.set_pixelv(red_px, Color(15.0, 0.0, 1.0, 1.0))
	current.set_pixelv(blue_px, Color(7.5, 0.0, 1.0, 1.0))
	current.set_pixelv(gray_px, Color(20.0, 0.0, 0.0, 1.0))

	var img := main._height_diff_to_color(target, current)
	var red := img.get_pixelv(red_px)
	if red.r < 0.99 or red.g > 0.01 or red.b > 0.01:
		push_error("  FAIL: positive height diff should map to red, got %s" % str(red))
		main.free()
		return false
	var blue := img.get_pixelv(blue_px)
	if blue.b < 0.49 or blue.r > 0.01 or blue.g > 0.01:
		push_error("  FAIL: negative height diff should map to blue, got %s" % str(blue))
		main.free()
		return false
	var gray := img.get_pixelv(gray_px)
	if absf(gray.r - 0.2) > 0.01 or absf(gray.g - 0.2) > 0.01 or absf(gray.b - 0.2) > 0.01:
		push_error("  FAIL: missing generated mask should map to gray, got %s" % str(gray))
		main.free()
		return false

	main.free()
	print("  OK: height diff GPU color map handles red, blue, and inactive gray")
	return true


func _test_height_to_grayscale_contract() -> bool:
	print("[BrushDimensionUI] test_height_to_grayscale_contract...")
	var main = MainScript.new()
	var img := Image.create(8, 8, false, Image.FORMAT_RGBAF)
	img.fill(Color(0.0, 0.0, 0.0, 1.0))
	var min_px := Vector2i(1, 1)
	var mid_px := Vector2i(2, 1)
	var max_px := Vector2i(3, 1)
	img.set_pixelv(min_px, Color(-2.0, 0.0, 0.0, 1.0))
	img.set_pixelv(mid_px, Color(0.5, 0.0, 0.0, 1.0))
	img.set_pixelv(max_px, Color(3.0, 0.0, 0.0, 1.0))

	var out := main._height_to_grayscale(img, 0)
	var min_c := out.get_pixelv(min_px)
	if min_c.r > 0.01 or min_c.g > 0.01 or min_c.b > 0.01:
		push_error("  FAIL: grayscale min should be black, got %s" % str(min_c))
		main.free()
		return false
	var mid_c := out.get_pixelv(mid_px)
	if absf(mid_c.r - 0.5) > 0.02 or absf(mid_c.g - 0.5) > 0.02 or absf(mid_c.b - 0.5) > 0.02:
		push_error("  FAIL: grayscale midpoint should be mid gray, got %s" % str(mid_c))
		main.free()
		return false
	var max_c := out.get_pixelv(max_px)
	if max_c.r < 0.99 or max_c.g < 0.99 or max_c.b < 0.99:
		push_error("  FAIL: grayscale max should be white, got %s" % str(max_c))
		main.free()
		return false

	main.free()
	print("  OK: GPU min/max reduction maps height channel to grayscale")
	return true


func _test_scale_height_image_contract() -> bool:
	print("[BrushDimensionUI] test_scale_height_image_contract...")
	var main = MainScript.new()
	var img := Image.create(8, 8, false, Image.FORMAT_RGBAF)
	img.fill(Color(-20000.0, 0.25, 0.5, 1.0))
	var scaled_px := Vector2i(1, 1)
	var clamped_px := Vector2i(2, 1)
	var sentinel_px := Vector2i(3, 1)
	img.set_pixelv(scaled_px, Color(-2.0, 0.25, 0.5, 1.0))
	img.set_pixelv(clamped_px, Color(-0.001, 0.25, 0.5, 1.0))
	img.set_pixelv(sentinel_px, Color(-20000.0, 0.25, 0.5, 1.0))

	main._scale_height_image(img, 2.0)
	var scaled := img.get_pixelv(scaled_px)
	if absf(scaled.r + 4.0) > 0.001 or absf(scaled.g - 0.25) > 0.001 or absf(scaled.a - 1.0) > 0.001:
		push_error("  FAIL: height scale GPU pass did not scale active height, got %s" % str(scaled))
		main.free()
		return false
	var clamped := img.get_pixelv(clamped_px)
	if absf(clamped.r + 0.01) > 0.001:
		push_error("  FAIL: height scale GPU pass should clamp shallow heights to -0.01, got %s" % str(clamped))
		main.free()
		return false
	var sentinel := img.get_pixelv(sentinel_px)
	if absf(sentinel.r + 20000.0) > 0.001:
		push_error("  FAIL: height scale GPU pass should preserve sentinel heights, got %s" % str(sentinel))
		main.free()
		return false

	main.free()
	print("  OK: active heights scaled, shallow heights clamped, sentinel preserved")
	return true


func _test_delta_to_heatmap_contract() -> bool:
	print("[BrushDimensionUI] test_delta_to_heatmap_contract...")
	var main = MainScript.new()
	var delta := Image.create(8, 8, false, Image.FORMAT_RF)
	delta.fill(Color(0.0, 0.0, 0.0, 0.0))
	var pos_px := Vector2i(1, 1)
	var neg_px := Vector2i(2, 1)
	var zero_px := Vector2i(3, 1)
	delta.set_pixelv(pos_px, Color(2.0, 0.0, 0.0, 0.0))
	delta.set_pixelv(neg_px, Color(-1.0, 0.0, 0.0, 0.0))

	var img := main._delta_to_heatmap(delta)
	var pos := img.get_pixelv(pos_px)
	if pos.r < 0.99 or absf(pos.g - 0.15) > 0.02 or pos.b > 0.01 or pos.a < 0.99:
		push_error("  FAIL: positive delta should map to hot red, got %s" % str(pos))
		main.free()
		return false
	var neg := img.get_pixelv(neg_px)
	if neg.r > 0.01 or absf(neg.g - 0.3) > 0.02 or neg.b < 0.99 or absf(neg.a - 0.65) > 0.03:
		push_error("  FAIL: negative delta should map to blue with scaled alpha, got %s" % str(neg))
		main.free()
		return false
	var zero := img.get_pixelv(zero_px)
	if absf(zero.r - 0.15) > 0.02 or absf(zero.g - 0.15) > 0.02 or absf(zero.b - 0.15) > 0.02 or absf(zero.a - 0.2) > 0.02:
		push_error("  FAIL: zero delta should map to neutral gray, got %s" % str(zero))
		main.free()
		return false

	main.free()
	print("  OK: delta heatmap GPU pass handles positive, negative, and neutral pixels")
	return true


func _test_delta_stats_contract() -> bool:
	print("[BrushDimensionUI] test_delta_stats_contract...")
	var main = MainScript.new()
	main._brush_target = main.BRUSH_TARGET_HEIGHT
	main._override_delta = Image.create(8, 8, false, Image.FORMAT_RF)
	main._override_delta.fill(Color(0.0, 0.0, 0.0, 0.0))
	main._override_delta.set_pixelv(Vector2i(1, 1), Color(-2.5, 0.0, 0.0, 0.0))
	main._override_delta.set_pixelv(Vector2i(2, 1), Color(3.25, 0.0, 0.0, 0.0))
	var stats := main._get_delta_stats()
	if absf(stats.x + 2.5) > 0.001 or absf(stats.y - 3.25) > 0.001:
		push_error("  FAIL: GPU delta stats expected -2.5..3.25, got %s" % str(stats))
		main.free()
		return false

	main.free()
	print("  OK: GPU delta stats reports min and max")
	return true


func _test_terrain_avg_height_contract() -> bool:
	print("[BrushDimensionUI] test_terrain_avg_height_contract...")
	var main = MainScript.new()
	var img := Image.create(8, 8, false, Image.FORMAT_RGBAF)
	img.fill(Color(0.0, 0.0, 0.0, 1.0))
	img.set_pixelv(Vector2i(0, 0), Color(2.0, 0.0, 0.0, 1.0))
	img.set_pixelv(Vector2i(4, 0), Color(4.0, 0.0, 0.0, 1.0))
	img.set_pixelv(Vector2i(0, 4), Color(6.0, 0.0, 0.0, 1.0))
	img.set_pixelv(Vector2i(4, 4), Color(8.0, 0.0, 0.0, 1.0))
	var avg := main._compute_terrain_avg_height(ImageTexture.create_from_image(img))
	if absf(avg - 5.0) > 0.001:
		push_error("  FAIL: GPU terrain average expected 5.0, got %.4f" % avg)
		main.free()
		return false

	main.free()
	print("  OK: GPU terrain average samples every four pixels")
	return true


func _test_height_difference_stats_contract() -> bool:
	print("[BrushDimensionUI] test_height_difference_stats_contract...")
	var main = MainScript.new()
	main.max_height = 10.0
	var target_img := Image.create(4, 4, false, Image.FORMAT_RGBAF)
	target_img.fill(Color(5.0, 0.0, 0.0, 1.0))
	target_img.set_pixelv(Vector2i(0, 1), Color(1.0, 0.0, 0.0, 1.0))
	target_img.set_pixelv(Vector2i(1, 1), Color(8.0, 0.0, 0.0, 1.0))

	var current_img := Image.create(4, 4, false, Image.FORMAT_RGBAF)
	current_img.fill(Color(5.0, 0.0, 0.0, 0.0))
	current_img.set_pixelv(Vector2i(0, 0), Color(5.2, 0.0, 1.0, 1.0))
	current_img.set_pixelv(Vector2i(1, 0), Color(4.0, 0.0, 1.0, 1.0))
	current_img.set_pixelv(Vector2i(2, 0), Color(7.0, 0.0, 1.0, 1.0))
	current_img.set_pixelv(Vector2i(3, 0), Color(6.0, 0.0, 1.0, 1.0))

	var depth_img := Image.create(4, 4, false, Image.FORMAT_RGBAF)
	depth_img.fill(Color(5.0, 0.0, 0.0, 1.0))
	depth_img.set_pixelv(Vector2i(0, 0), Color(6.0, 0.0, 0.0, 1.0))
	depth_img.set_pixelv(Vector2i(1, 0), Color(7.0, 0.0, 0.0, 1.0))
	depth_img.set_pixelv(Vector2i(2, 0), Color(6.0, 0.0, 0.0, 1.0))
	depth_img.set_pixelv(Vector2i(3, 0), Color(4.0, 0.0, 0.0, 1.0))

	var stats := main._compute_height_difference_stats_gpu(target_img, current_img, depth_img)
	if not bool(stats.get("valid", false)):
		push_error("  FAIL: GPU height difference stats did not return valid output")
		main.free()
		return false
	if int(stats.total_gen) != 4 or int(stats.already_above) != 1 or int(stats.fillable_count) != 3:
		push_error("  FAIL: unexpected counts %s" % str(stats))
		main.free()
		return false
	if int(stats.filled_ok) != 1 or int(stats.still_under) != 1 or int(stats.rock_overshoot) != 1:
		push_error("  FAIL: unexpected fill categories %s" % str(stats))
		main.free()
		return false
	if absf(float(stats.rmse) - sqrt(6.04 / 4.0)) > 0.001:
		push_error("  FAIL: unexpected RMSE %.4f" % float(stats.rmse))
		main.free()
		return false
	if absf(float(stats.mae) - 1.05) > 0.001 or absf(float(stats.max_err) - 2.0) > 0.001:
		push_error("  FAIL: unexpected MAE/max stats %s" % str(stats))
		main.free()
		return false
	if absf(float(stats.target_h_min) - 1.0) > 0.001 or absf(float(stats.target_h_max) - 8.0) > 0.001:
		push_error("  FAIL: unexpected target range %s" % str(stats))
		main.free()
		return false
	if absf(float(stats.filled_ok_pct) - (100.0 / 3.0)) > 0.001:
		push_error("  FAIL: unexpected fill percentages %s" % str(stats))
		main.free()
		return false
	if absf(float(stats.avg_rock_height) - (5.2 / 3.0)) > 0.001:
		push_error("  FAIL: unexpected average rock height %.4f" % float(stats.avg_rock_height))
		main.free()
		return false

	main.free()
	print("  OK: GPU height difference stats reduce counts, errors, and target range")
	return true


func _test_height_stats_contract() -> bool:
	print("[BrushDimensionUI] test_height_stats_contract...")
	var main = MainScript.new()
	var img := Image.create(8, 8, false, Image.FORMAT_RGBAF)
	img.fill(Color(-20000.0, 0.0, 0.0, 1.0))
	img.set_pixelv(Vector2i(1, 1), Color(-2.0, 0.0, 0.0, 1.0))
	img.set_pixelv(Vector2i(2, 1), Color(3.5, 0.0, 0.0, 1.0))
	img.set_pixelv(Vector2i(3, 1), Color(-10000.0, 0.0, 0.0, 1.0))
	var stats := main._get_height_stats(img)
	if absf(stats.x + 2.0) > 0.001 or absf(stats.y - 3.5) > 0.001:
		push_error("  FAIL: GPU height stats expected -2.0..3.5 ignoring sentinel, got %s" % str(stats))
		main.free()
		return false

	main.free()
	print("  OK: GPU height stats ignores sentinel and reports min/max")
	return true


func _test_capture_rock_mask_contract() -> bool:
	print("[BrushDimensionUI] test_capture_rock_mask_contract...")
	var main = MainScript.new()
	var current := Image.create(256, 256, false, Image.FORMAT_RGBAF)
	current.fill(Color(0.0, 0.0, 0.0, 1.0))
	var active_px := Vector2i(10, 11)
	var inactive_px := Vector2i(12, 11)
	current.set_pixelv(active_px, Color(0.0, 0.75, 0.0, 1.0))
	current.set_pixelv(inactive_px, Color(0.0, 0.25, 0.0, 1.0))
	var result := main._capture_rock_mask_gpu(current)
	if result.is_empty() or int(result.get("nonzero", 0)) != 1:
		push_error("  FAIL: GPU rock mask capture expected one active pixel, got %s" % str(result))
		main.free()
		return false
	var png: Image = result.get("png_mask")
	var rock: Image = result.get("rock_mask")
	if png.get_pixelv(active_px).r < 0.99 or png.get_pixelv(inactive_px).a > 0.01:
		push_error("  FAIL: PNG rock mask capture did not threshold active/inactive pixels")
		main.free()
		return false
	if rock.get_pixelv(active_px).r < 0.99 or rock.get_pixelv(inactive_px).r > 0.01:
		push_error("  FAIL: RF rock mask capture did not threshold active/inactive pixels")
		main.free()
		return false

	main.free()
	print("  OK: GPU rock mask capture writes PNG/RF masks and count")
	return true


func _test_current_height_mask_to_color_contract() -> bool:
	print("[BrushDimensionUI] test_current_height_mask_to_color_contract...")
	var main = MainScript.new()
	var current := Image.create(8, 8, false, Image.FORMAT_RGBAF)
	current.fill(Color(0.0, 0.0, 0.0, 1.0))
	var generated_px := Vector2i(1, 1)
	var blocked_px := Vector2i(2, 1)
	var empty_px := Vector2i(3, 1)
	current.set_pixelv(generated_px, Color(0.0, 0.0, 0.75, 1.0))
	current.set_pixelv(blocked_px, Color(0.0, 0.75, 0.75, 1.0))
	current.set_pixelv(empty_px, Color(0.0, 0.0, 0.25, 1.0))

	var out := main._current_height_mask_to_color_gpu(current)
	if out == null or out.is_empty():
		push_error("  FAIL: current height mask GPU color pass returned no image")
		main.free()
		return false

	var generated := out.get_pixelv(generated_px)
	var blocked := out.get_pixelv(blocked_px)
	var empty := out.get_pixelv(empty_px)
	if absf(generated.r - 0.2) > 0.02 or absf(generated.g - 0.6) > 0.02 or generated.b < 0.98:
		push_error("  FAIL: generated mask pixel should be blue, got %s" % str(generated))
		main.free()
		return false
	if blocked.r < 0.98 or absf(blocked.g - 0.3) > 0.02 or blocked.b > 0.02:
		push_error("  FAIL: blocked generated mask pixel should be orange, got %s" % str(blocked))
		main.free()
		return false
	if absf(empty.r - 0.15) > 0.02 or absf(empty.g - 0.15) > 0.02 or absf(empty.b - 0.15) > 0.02:
		push_error("  FAIL: empty mask pixel should be gray, got %s" % str(empty))
		main.free()
		return false

	main.free()
	print("  OK: GPU current-height mask color pass preserves blue/orange/gray contract")
	return true


func _test_diff_terrain_uses_packed_values_contract() -> bool:
	print("[BrushDimensionUI] test_diff_terrain_uses_packed_values_contract...")
	var main = MainScript.new()
	var target := Image.create(4, 4, false, Image.FORMAT_RGBAF)
	target.fill(Color(1.0, 0.0, 0.0, 1.0))
	var current := Image.create(4, 4, false, Image.FORMAT_RGBAF)
	current.fill(Color(1.0, 0.0, 1.0, 1.0))
	current.set_pixelv(Vector2i(0, 0), Color(2.0, 0.0, 1.0, 1.0))
	current.set_pixelv(Vector2i(1, 0), Color(0.0, 0.0, 1.0, 1.0))
	current.set_pixelv(Vector2i(2, 0), Color(1.1, 0.0, 0.0, 1.0))

	main._setup_diff_terrain(target, current)
	var terrain: MeshInstance3D = main._debug_diff_terrain
	if terrain == null or terrain.mesh == null:
		push_error("  FAIL: diff terrain was not built")
		main.free()
		return false

	var arrays: Array = terrain.mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	if vertices.size() < 3 or colors.size() < 3:
		push_error("  FAIL: diff terrain arrays missing vertices/colors")
		main.free()
		return false
	var found_height := false
	var found_red := false
	var found_blue := false
	var found_gray := false
	for v in vertices:
		if absf(v.y - 2.3) <= 0.001:
			found_height = true
			break
	for c in colors:
		if c.r > 0.99 and c.b < 0.01 and c.a >= 0.39:
			found_red = true
		if c.b > 0.99 and c.r < 0.01:
			found_blue = true
		if absf(c.r - 0.3) <= 0.01 and c.a <= 0.2:
			found_gray = true
	if not found_height or not found_red or not found_blue or not found_gray:
		push_error("  FAIL: diff terrain missing expected packed height/color states: height=%s red=%s blue=%s gray=%s" % [
			str(found_height), str(found_red), str(found_blue), str(found_gray)
		])
		main.free()
		return false

	main.free()
	print("  OK: diff terrain samples packed RGBAF values for height and color")
	return true


func _test_debug_target_height_terrain_uses_packed_values_contract() -> bool:
	print("[BrushDimensionUI] test_debug_target_height_terrain_uses_packed_values_contract...")
	var main = MainScript.new()
	var target := Image.create(4, 4, false, Image.FORMAT_RGBAF)
	target.fill(Color(1.0, 0.0, 0.0, 1.0))
	target.set_pixelv(Vector2i(0, 0), Color(2.0, 0.0, 0.0, 1.0))
	var current := Image.create(4, 4, false, Image.FORMAT_RGBAF)
	current.fill(Color(0.0, 0.0, 0.0, 1.0))
	current.set_pixelv(Vector2i(0, 0), Color(0.0, 0.0, 0.75, 1.0))
	main._raw_target_height_image = target
	main._raw_current_height_image = current

	main._setup_debug_terrain()
	var terrain: MeshInstance3D = main._debug_terrain
	if terrain == null or terrain.mesh == null:
		push_error("  FAIL: target height debug terrain was not built")
		main.free()
		return false

	var arrays: Array = terrain.mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var found_height := false
	var found_active_alpha := false
	var found_inactive_alpha := false
	for v in vertices:
		if absf(v.y - 2.15) <= 0.001:
			found_height = true
			break
	for c in colors:
		if absf(c.a - 0.4) <= 0.02:
			found_active_alpha = true
		if absf(c.a - 0.02) <= 0.02:
			found_inactive_alpha = true
	if not found_height or not found_active_alpha or not found_inactive_alpha:
		push_error("  FAIL: target height terrain missing packed height/alpha states: height=%s active=%s inactive=%s" % [
			str(found_height), str(found_active_alpha), str(found_inactive_alpha)
		])
		main.free()
		return false

	main.free()
	print("  OK: target height debug terrain samples packed RGBAF height and mask values")
	return true


func _test_target_sv_overlay_uses_packed_values_contract() -> bool:
	print("[BrushDimensionUI] test_target_sv_overlay_uses_packed_values_contract...")
	var main = MainScript.new()
	main.max_height = 10.0
	main.capture_size = 4.0
	var depth := Image.create(4, 4, false, Image.FORMAT_RGBAF)
	depth.fill(Color(4.0, 0.0, 0.0, 1.0))
	depth.set_pixelv(Vector2i(0, 0), Color(3.0, 0.0, 0.0, 1.0))
	var preview := Image.create(4, 4, false, Image.FORMAT_RGBAF)
	preview.fill(Color(0.0, 0.0, 0.0, 0.0))
	preview.set_pixelv(Vector2i(0, 0), Color(0.2, 0.4, 0.6, 0.8))
	main._cached_textures = {"scene_depth": ImageTexture.create_from_image(depth)}
	main._target_sv_b_preview_image = preview

	main._build_target_scene_voxel_overlay()
	var overlay: MeshInstance3D = main._target_sv_debug_terrain
	if overlay == null or overlay.mesh == null:
		push_error("  FAIL: TargetSV overlay was not built")
		main.free()
		return false

	var arrays: Array = overlay.mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var found_height := false
	var found_color := false
	for v in vertices:
		if absf(v.y - 7.45) <= 0.001:
			found_height = true
			break
	for c in colors:
		if absf(c.r - 0.2) <= 0.02 and absf(c.g - 0.4) <= 0.02 and absf(c.b - 0.6) <= 0.02 and absf(c.a - 0.56) <= 0.03:
			found_color = true
			break
	if not found_height or not found_color:
		push_error("  FAIL: TargetSV overlay missing packed height/color states: height=%s color=%s" % [
			str(found_height), str(found_color)
		])
		main.free()
		return false

	main.free()
	print("  OK: TargetSV overlay samples packed depth and preview values")
	return true


func _test_create_cliff_height_image_contract() -> bool:
	print("[BrushDimensionUI] test_create_cliff_height_image_contract...")
	var main = MainScript.new()
	var img := main._create_cliff_height_image(Vector3(4.0, 6.0, 4.0))
	var outside := img.get_pixelv(Vector2i(0, 0))
	if absf(outside.r + 20000.0) > 0.001 or absf(outside.a - 1.0) > 0.001:
		push_error("  FAIL: cliff height outside margin should be sentinel, got %s" % str(outside))
		main.free()
		return false
	var center := img.get_pixelv(Vector2i(128, 128))
	if center.r > -0.009 or center.r < -0.1:
		push_error("  FAIL: cliff height center should clamp near -0.01, got %s" % str(center))
		main.free()
		return false
	var side := img.get_pixelv(Vector2i(64, 128))
	if side.r >= center.r or side.r <= -4.0:
		push_error("  FAIL: cliff height side should be lower than center but active, got %s" % str(side))
		main.free()
		return false

	main.free()
	print("  OK: GPU cliff height image generates sentinel border and active profile")
	return true


func _test_clear_override_tile_contract() -> bool:
	print("[BrushDimensionUI] test_clear_override_tile_contract...")
	var main = MainScript.new()
	main._init_override_images()
	var height_px := Vector2i(8, 8)
	var rock_px := Vector2i(9, 8)
	var outside_px := Vector2i(40, 40)
	main._override_mask.set_pixelv(height_px, Color(1.0, 0.0, 0.0, 0.0))
	main._override_delta.set_pixelv(height_px, Color(2.0, 0.0, 0.0, 0.0))
	main._dep_terrain.set_pixelv(height_px, Color(3.0, 0.0, 0.0, 0.0))
	main._rock_override_mask.set_pixelv(rock_px, Color(1.0, 0.0, 0.0, 0.0))
	main._rock_override_delta.set_pixelv(rock_px, Color(4.0, 0.0, 0.0, 0.0))
	main._dep_rock.set_pixelv(rock_px, Color(5.0, 0.0, 0.0, 0.0))
	main._override_mask.set_pixelv(outside_px, Color(1.0, 0.0, 0.0, 0.0))
	main._override_delta.set_pixelv(outside_px, Color(6.0, 0.0, 0.0, 0.0))

	var result := main._clear_override_tile_gpu(Rect2i(Vector2i(0, 0), Vector2i(16, 16)))
	if result.is_empty() or int(result.get("cleared", 0)) != 2:
		push_error("  FAIL: GPU tile clear expected two cleared pixels, got %s" % str(result))
		main.free()
		return false
	main._override_mask = result["override_mask"]
	main._override_delta = result["override_delta"]
	main._dep_terrain = result["dep_terrain"]
	main._dep_rock = result["dep_rock"]
	main._rock_override_mask = result["rock_override_mask"]
	main._rock_override_delta = result["rock_override_delta"]
	if main._override_mask.get_pixelv(height_px).r > 0.01 or main._override_delta.get_pixelv(height_px).r > 0.01 or main._dep_terrain.get_pixelv(height_px).r > 0.01:
		push_error("  FAIL: height override pixel was not cleared")
		main.free()
		return false
	if main._rock_override_mask.get_pixelv(rock_px).r > 0.01 or main._rock_override_delta.get_pixelv(rock_px).r > 0.01 or main._dep_rock.get_pixelv(rock_px).r > 0.01:
		push_error("  FAIL: rock override pixel was not cleared")
		main.free()
		return false
	if absf(main._override_mask.get_pixelv(outside_px).r - 1.0) > 0.001 or absf(main._override_delta.get_pixelv(outside_px).r - 6.0) > 0.001:
		push_error("  FAIL: outside tile override should remain intact")
		main.free()
		return false

	main.free()
	print("  OK: GPU tile clear zeros in-rect overrides and preserves outside pixels")
	return true


func _test_paint_brush_footprint_contract() -> bool:
	print("[BrushDimensionUI] test_paint_brush_footprint_contract...")
	var main = MainScript.new()
	main.max_height = 10.0
	main._init_override_images()
	main._set_brush_dimensions(5, 5, 1)
	main._brush_target = main.BRUSH_TARGET_HEIGHT
	var scene_depth := Image.create(256, 256, false, Image.FORMAT_RGBAF)
	scene_depth.fill(Color(7.0, 0.0, 0.0, 1.0))
	main._cached_textures = {"scene_depth": ImageTexture.create_from_image(scene_depth)}
	main._current_rock_mask_img.fill(Color(0.4, 0.0, 0.0, 0.0))
	var center := Vector2i(20, 20)
	var edge := center + Vector2i(2, 0)
	var outside := center + Vector2i(4, 0)

	main._paint_brush_footprint(center, 5.0)
	var center_delta: float = main._override_delta.get_pixelv(center).r
	if absf(center_delta - 0.1) > 0.001 or main._override_mask.get_pixelv(center).r < 0.99:
		push_error("  FAIL: brush center delta/mask incorrect: %.4f %.4f" % [center_delta, main._override_mask.get_pixelv(center).r])
		main.free()
		return false
	var edge_delta: float = main._override_delta.get_pixelv(edge).r
	if absf(edge_delta - 0.02) > 0.001:
		push_error("  FAIL: brush edge falloff expected 0.02, got %.4f" % edge_delta)
		main.free()
		return false
	if main._override_mask.get_pixelv(outside).r > 0.01 or main._override_delta.get_pixelv(outside).r > 0.01:
		push_error("  FAIL: outside footprint should remain untouched")
		main.free()
		return false
	if absf(main._dep_terrain.get_pixelv(center).r - 3.0) > 0.001 or absf(main._dep_rock.get_pixelv(center).r - 0.4) > 0.001:
		push_error("  FAIL: brush dependency capture incorrect")
		main.free()
		return false

	main.free()
	print("  OK: GPU brush footprint updates delta, mask, and dependencies")
	return true


func _capture_brush_dimension_ui_snapshot() -> bool:
	print("[BrushDimensionUI] capture_brush_dimension_ui_snapshot...")
	var main = MainScript.new()
	main._setup_delta_overlay_ui()
	if main.get_child_count() <= 0:
		push_error("  FAIL: brush UI setup did not create a CanvasLayer")
		main.free()
		return false
	var layer := main.get_child(main.get_child_count() - 1)
	main.remove_child(layer)
	get_root().add_child(layer)
	main._set_brush_dimensions(33, 17, 5)
	main._brush_active = true
	main._brush_strength = 4.5
	main._debug_delta_showing = true
	if main._delta_panel != null:
		main._delta_panel.visible = true
		main._delta_panel.position = Vector2(560, 10)
	main._update_brush_label()
	await process_frame
	await process_frame
	RenderingServer.force_draw(true)
	await process_frame
	if DisplayServer.get_name().to_lower().contains("headless"):
		print("  SKIP: screenshot unavailable in headless display mode")
		layer.queue_free()
		main.free()
		return true
	var viewport_texture := get_root().get_texture()
	if viewport_texture == null:
		print("  SKIP: viewport texture unavailable in this display mode")
		layer.queue_free()
		main.free()
		return true
	var image := viewport_texture.get_image()
	if image == null or image.is_empty():
		print("  SKIP: viewport image unavailable in this display mode")
		layer.queue_free()
		main.free()
		return true
	var snapshot_dir := ProjectSettings.globalize_path(SNAPSHOT_DIR)
	var dir_err := DirAccess.make_dir_recursive_absolute(snapshot_dir)
	if dir_err != OK:
		layer.queue_free()
		main.free()
		push_error("  FAIL: failed to create snapshot directory: %s" % error_string(dir_err))
		return false
	var snapshot_path := ProjectSettings.globalize_path(SNAPSHOT_PATH)
	var err := image.save_png(snapshot_path)
	layer.queue_free()
	main.free()
	if err != OK:
		push_error("  FAIL: failed to save brush UI snapshot: %s" % error_string(err))
		return false
	print("  OK: snapshot=%s" % snapshot_path)
	return true
