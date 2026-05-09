extends Node3D

@export var num_iterations: int = 10
@export var capture_size: float = 120.0
@export var max_height: float = 50.0
@export var generate_threshold: float = 0.5
@export var un_generate_threshold: float = 0.3
@export var fbx_unit_scale: float = 1.0
@export var mesh_height_scale: float = 0.5
@export var cliff_base_rotation: Vector3 = Vector3(-90.0, 0.0, 0.0)
@export var rock_mask_path: String = ""
@export var target_height_extension: float = 2.0
@export var rock_overlap: float = 0.0
@export var use_surface_3d_cliff_placement: bool = false
@export var batch_test_mode: bool = false
@export var batch_test_values: Array[float] = [0.5, 1.0, 2.0, 4.0, 8.0, 12.0, 16.0, 20.0]
@export var rock_asset_dir: String = "res://assets/rocks"
@export var rock_asset_paths: Array[String] = []
@export var vegetation_asset_dir: String = "res://assets/vegetation"
@export var vegetation_asset_paths: Array[String] = []
@export var cliff_tree_stamp_radius: float = 8.0
@export var cliff_tree_stamp_inner_radius: float = 1.0
@export var tree_grass_stamp_radius: float = 5.0
@export var landscape_cliff_slope_start: float = 0.35
@export var landscape_cliff_slope_full: float = 0.8
@export_range(0.1, 8.0, 0.1) var semantic_probe_density: float = 1.0
@export var enable_test_generation_tools: bool = true
@export var run_startup_generation_tests: bool = false

const TEX_RES := 256
const ROCK_VISUAL_LAYER := 10
const ROCK_VOXEL_COLOR := Color(0.55, 0.50, 0.45, 1.0)
const TERRAIN_VOXEL_COLOR := Color(0.45, 0.42, 0.35, 1.0)
const TEST_ONLY_GROUP := "test_only_generated"
const TEST_ONLY_ROCK_GROUP := "test_only_rocks"
const TEST_ONLY_VEGETATION_GROUP := "test_only_vegetation"
const TARGET_SV_SLICE_COUNT := 8
const TARGET_SV_VERTICAL_SPAN := 16.0
const TARGET_SV_DIR_NAME := "target_scene_voxel"
const SemanticProbeProfileScript := preload("res://scripts/semantic_probe_profile.gd")

var _raw_target_height_image: Image
var _raw_current_height_image: Image
var _debug_terrain: MeshInstance3D
var _debug_diff_terrain: MeshInstance3D
var _debug_showing: bool = false
var _debug_diff_showing: bool = false
var _slider_label: Label
var _overlap_label: Label
var _probe_density_label: Label
var _probe_debug_label: Label
var _debounce_timer: Timer
var _batch_results: Array[Dictionary] = []
var _step_count: int = 0
var _cached_textures: Dictionary = {}
var _cached_cliff_meshes: Array[Mesh] = []
var _cached_assets: Array[AutoRock] = []

var _override_delta: Image
var _override_mask: Image
var _dep_terrain: Image
var _dep_rock: Image
var _current_rock_mask_img: Image
var _rock_override_delta: Image
var _rock_override_mask: Image
var _tile_refresh_mode: bool = false
const TILE_SIZE := 32
var _undo_stack: Array[Dictionary] = []
const UNDO_MAX_STEPS := 3
const BRUSH_TARGET_HEIGHT := 0
const BRUSH_TARGET_ROCK := 1
var _brush_target: int = BRUSH_TARGET_HEIGHT
var _brush_active: bool = false
var _brush_radius: int = 10
var _brush_strength: float = 3.0
var _painting: bool = false
var _paint_positive: bool = true
var _brush_dirty_rect: Rect2i = Rect2i()
var _brush_stroke_changed: bool = false
var _brush_voxel_commit_pending: bool = false
var _terrain_hit_y: float = 10.0
var _debug_delta_showing: bool = false
var _delta_panel: PanelContainer
var _delta_overlay: TextureRect
var _brush_label: Label

var _tree_mesh: Mesh
var _midstory_mesh: Mesh
var _bush_mesh: Mesh
var _grass_mesh: Mesh
var _vegetation_assets: Array[AutoVegetationAsset] = []
var _tree_mask_image: Image
var _midstory_mask_image: Image
var _bush_mask_image: Image
var _grass_mask_image: Image
var _vegetation_generated: bool = false
var _debug_mask_terrain: MeshInstance3D
var _debug_probe_root: Node3D
var _veg_exclusion: VegetationExclusion
var _mesh_voxel_records: Dictionary = {}
var _auto_object_manager: AutoObjectManager
var _target_sv_preview_image: Image
var _target_sv_visual_bytes: PackedByteArray
var _target_sv_collision_bytes: PackedByteArray
var _target_sv_metadata: Dictionary = {}
var _target_sv_debug_terrain: MeshInstance3D
var _target_sv_debug_showing: bool = false


func _get_level_root() -> Node:
	var parent := get_parent()
	return parent if parent != null else self


func _get_level_child(node_name: String) -> Node:
	return _get_level_root().get_node_or_null(NodePath(node_name))


func _add_level_child(node: Node) -> void:
	_get_level_root().add_child(node)


func _get_level_children() -> Array[Node]:
	var children: Array[Node] = []
	for child in _get_level_root().get_children():
		children.append(child)
	return children


func _ready() -> void:
	call_deferred("_initialize_scene")


func _initialize_scene() -> void:
	if batch_test_mode:
		_run_batch_test()
		return

	_cached_textures = _load_terrain_textures()
	if _cached_textures.is_empty():
		push_error("[MeshFill] Fatal: failed to obtain terrain textures")
		return
	_load_cliff_data(_cached_cliff_meshes, _cached_assets)
	if _cached_assets.is_empty():
		push_error("[MeshFill] Fatal: no cliff assets available")
		return
	_vegetation_assets = _load_vegetation_assets()
	_apply_semantic_probe_density_to_assets()

	_terrain_hit_y = _compute_terrain_avg_height(_cached_textures["target_height"])
	_init_override_images()
	_setup_delta_overlay_ui()

	_clear_rock_mask()
	_create_terrain_mesh(_cached_textures["target_height"])
	_load_persisted_target_scene_voxel()
	_setup_slider_ui()
	_tree_mesh = VegetationScatter.create_tree_mesh()
	_bush_mesh = VegetationScatter.create_bush_mesh()
	print("[MeshFill] Ready. Test tools: C=rock step P=vegetation. G/H=debug J=TargetSV Ctrl+J=recompute TargetSV V=delta B=brush N=layer T=tile M=mask Ctrl+Z=undo")
	if run_startup_generation_tests:
		call_deferred("_test_target_height_logic")


func _test_target_height_logic() -> void:
	var test_values := [0.5, 2.0, 4.0, 8.0, 12.0]
	var out_dir := OS.get_user_data_dir() + "/target_height_analysis"
	DirAccess.make_dir_recursive_absolute(out_dir)

	for ext_val in test_values:
		target_height_extension = ext_val

		for child in _get_level_children():
			if child.name == "DebugTargetHeight" or child.name == "DebugDiffHeight":
				child.queue_free()
		_debug_terrain = null
		_debug_diff_terrain = null

		var generator := CliffGenerator.new()
		generator.texture_size = TEX_RES
		generator.capture_size = capture_size
		generator.max_height = max_height
		generator.generate_threshold = generate_threshold
		generator.un_generate_threshold = un_generate_threshold
		generator.scene_depth_texture = _cached_textures["scene_depth"]
		generator.scene_normal_texture = _cached_textures["scene_normal"]
		generator.object_depth_texture = _cached_textures["object_depth"]
		generator.object_normal_texture = _cached_textures["object_normal"]
		generator.height_normal_texture = _cached_textures["height_normal"]
		generator.target_height_texture = _cached_textures["target_height"]
		generator.rock_mask_texture = null
		generator.target_height_extension = ext_val
		generator.rock_overlap = rock_overlap
		generator.rock_assets = _cached_assets
		add_child(generator)

		var _results := _generate_cliff_placements(generator, 0)
		_raw_target_height_image = generator._debug_target_height_image
		_raw_current_height_image = generator._debug_current_height_image
		generator.queue_free()

		var gen_count := 0
		var h_min := 9999.0
		var h_max := -9999.0
		if _raw_current_height_image != null and _raw_target_height_image != null:
			var res := _raw_current_height_image.get_width()
			for y in range(res):
				for x in range(res):
					var px_mask := _raw_current_height_image.get_pixelv(Vector2i(x, y)).b
					if px_mask > 0.5:
						gen_count += 1
					var th := _raw_target_height_image.get_pixelv(Vector2i(x, y)).r
					h_min = minf(h_min, th)
					h_max = maxf(h_max, th)

		print("[TargetH] ext=%.1fm 鈫?mask=%d/%d (%.1f%%) target_h=[%.1f, %.1f]" % [
			ext_val, gen_count, TEX_RES * TEX_RES,
			float(gen_count) / float(TEX_RES * TEX_RES) * 100.0, h_min, h_max])

		if _raw_target_height_image != null:
			var vis := _height_to_grayscale(_raw_target_height_image, 0)
			vis.save_png("%s/target_h_ext%.1f.png" % [out_dir, ext_val])
		if _raw_current_height_image != null:
			var mask_vis := Image.create(TEX_RES, TEX_RES, false, Image.FORMAT_RGBA8)
			for y in range(TEX_RES):
				for x in range(TEX_RES):
					var gen := _raw_current_height_image.get_pixelv(Vector2i(x, y)).b
					var un_gen := _raw_current_height_image.get_pixelv(Vector2i(x, y)).g
					if gen > 0.5 and un_gen < 0.5:
						mask_vis.set_pixelv(Vector2i(x, y), Color(0.2, 0.6, 1.0, 1.0))
					elif gen > 0.5 and un_gen > 0.5:
						mask_vis.set_pixelv(Vector2i(x, y), Color(1.0, 0.3, 0.0, 1.0))
					else:
						mask_vis.set_pixelv(Vector2i(x, y), Color(0.15, 0.15, 0.15, 1.0))
			mask_vis.save_png("%s/mask_ext%.1f.png" % [out_dir, ext_val])

		await get_tree().process_frame
		_setup_debug_terrain()
		if _debug_terrain != null:
			_debug_terrain.visible = true
		await get_tree().create_timer(0.3).timeout
		RenderingServer.force_draw(true)
		await get_tree().process_frame
		await get_tree().process_frame
		var img := get_viewport().get_texture().get_image()
		img.save_png("%s/scene_ext%.1f.png" % [out_dir, ext_val])

	print("[TargetH] Analysis complete. Files at: %s" % out_dir)

	print("[MeshFill] Auto-testing vegetation generation...")
	_step_generate()
	await get_tree().process_frame
	_generate_vegetation()

	print("[MeshFill] Brush override test")
	_test_brush_override()


func _auto_screenshot() -> void:
	await get_tree().create_timer(2.0).timeout
	RenderingServer.force_draw(true)
	await get_tree().process_frame
	await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	img.save_png(OS.get_user_data_dir() + "/screenshot.png")
	print("[MeshFill] Screenshot saved")


func _save_viewport_screenshot() -> void:
	var img := get_viewport().get_texture().get_image()
	var path := "%s/screenshot_%d.png" % [OS.get_user_data_dir(), Time.get_unix_time_from_system()]
	img.save_png(path)
	print("[MeshFill] Screenshot saved: %s" % path)




func _test_brush_override() -> void:
	if _override_delta == null or _override_mask == null:
		print("[MeshFill] No override images initialized, skip brush test")
		return

	var pre_mask_count := 0
	for y in range(TEX_RES):
		for x in range(TEX_RES):
			if _override_mask.get_pixelv(Vector2i(x, y)).r > 0.01:
				pre_mask_count += 1
	print("[MeshFill]   Before: %d override pixels" % pre_mask_count)

	_brush_target = BRUSH_TARGET_HEIGHT
	var centers := [Vector2i(128, 128), Vector2i(64, 64), Vector2i(192, 192)]
	for center in centers:
		for stroke in range(5):
			_paint_brush_circle(center, 15, 5.0)

	var post_mask_count := 0
	var d_min := 0.0
	var d_max := 0.0
	for y in range(TEX_RES):
		for x in range(TEX_RES):
			var px := Vector2i(x, y)
			if _override_mask.get_pixelv(px).r > 0.01:
				post_mask_count += 1
			var dv := _override_delta.get_pixelv(px).r
			d_min = minf(d_min, dv)
			d_max = maxf(d_max, dv)
	print("[MeshFill]   After: %d override pixels, delta=[%.2f, %.2f]" % [post_mask_count, d_min, d_max])

	var composited_th := _composite_target_height()
	var base_th: Image = (_cached_textures["target_height"] as ImageTexture).get_image()
	var comp_img: Image = composited_th.get_image()
	var modified := 0
	for y in range(TEX_RES):
		for x in range(TEX_RES):
			var base_v := base_th.get_pixelv(Vector2i(x, y)).r
			var comp_v := comp_img.get_pixelv(Vector2i(x, y)).r
			if absf(base_v - comp_v) > 0.001:
				modified += 1
	print("[MeshFill]   Composited target_height: %d pixels modified" % modified)

	_regenerate()
	print("[MeshFill]   Regenerating with overrides...")
	await get_tree().process_frame
	await get_tree().process_frame

	_generate_vegetation()
	print("[MeshFill] Brush override test complete")


func _run_batch_test() -> void:
	print("[MeshFill] 鈺斺晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晽")
	print("[MeshFill] BATCH TEST: target_height_extension")
	print("[MeshFill] 鈺氣晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨暆")
	print("[MeshFill] Testing %d values: %s" % [batch_test_values.size(), str(batch_test_values)])
	print("")

	var textures := _load_terrain_textures()
	if textures.is_empty():
		push_error("[MeshFill] Fatal: failed to obtain terrain textures")
		return

	var cliff_meshes: Array[Mesh] = []
	var assets: Array[AutoRock] = []
	_load_cliff_data(cliff_meshes, assets)
	if assets.is_empty():
		push_error("[MeshFill] Fatal: no cliff assets available")
		return

	_batch_results.clear()

	for ext_val in batch_test_values:
		print("[MeshFill] 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€")
		print("[MeshFill] Testing extension = %.1fm" % ext_val)
		print("[MeshFill] 鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€鈹€")

		var generator := CliffGenerator.new()
		generator.texture_size = TEX_RES
		generator.capture_size = capture_size
		generator.max_height = max_height
		generator.generate_threshold = generate_threshold
		generator.un_generate_threshold = un_generate_threshold
		generator.scene_depth_texture = textures["scene_depth"]
		generator.scene_normal_texture = textures["scene_normal"]
		generator.object_depth_texture = textures["object_depth"]
		generator.object_normal_texture = textures["object_normal"]
		generator.height_normal_texture = textures["height_normal"]
		generator.target_height_texture = textures["target_height"]
		generator.rock_mask_texture = null
		generator.target_height_extension = ext_val
		generator.rock_overlap = rock_overlap
		generator.rock_assets = assets
		add_child(generator)

		var t0 := Time.get_ticks_msec()
		var results := _generate_cliff_placements(generator, num_iterations)
		var elapsed := Time.get_ticks_msec() - t0

		_raw_target_height_image = generator._debug_target_height_image
		_raw_current_height_image = generator._debug_current_height_image

		var pixel_size := capture_size / float(TEX_RES)
		var flood_iters := maxi(1, ceili(ext_val / pixel_size))

		var stats := _collect_batch_stats(textures["scene_depth"], ext_val, results.size(), elapsed, flood_iters)
		_batch_results.append(stats)

		var out_dir := OS.get_user_data_dir() + "/batch_test"
		DirAccess.make_dir_recursive_absolute(out_dir)
		if _raw_target_height_image != null:
			var vis := _height_to_grayscale(_raw_target_height_image, 0)
			vis.save_png(out_dir + "/target_height_ext%.1f.png" % ext_val)
		if _raw_current_height_image != null:
			var vis := _height_to_grayscale(_raw_current_height_image, 0)
			vis.save_png(out_dir + "/current_height_ext%.1f.png" % ext_val)
		if _raw_target_height_image != null and _raw_current_height_image != null:
			var diff_vis := _height_diff_to_color(_raw_target_height_image, _raw_current_height_image)
			diff_vis.save_png(out_dir + "/height_diff_ext%.1f.png" % ext_val)

		generator.queue_free()

	_print_batch_summary()

	target_height_extension = batch_test_values[-1]
	_generate()
	_setup_debug_terrain()
	_setup_slider_ui()
	_auto_screenshot()
	print("[MeshFill] Batch test complete. Slider available for interactive testing.")


func _collect_batch_stats(scene_depth_tex: ImageTexture, ext_val: float, placement_count: int, elapsed_ms: int, flood_iters: int) -> Dictionary:
	var stats := {
		"extension": ext_val,
		"placements": placement_count,
		"elapsed_ms": elapsed_ms,
		"flood_iterations": flood_iters,
		"rmse": 0.0,
		"mae": 0.0,
		"max_err": 0.0,
		"total_gen": 0,
		"filled_ok_pct": 0.0,
		"under_filled_pct": 0.0,
		"overshoot_pct": 0.0,
		"target_h_min": 0.0,
		"target_h_max": 0.0,
		"fillable_rmse": 0.0,
		"fillable_mae": 0.0,
		"avg_rock_height": 0.0,
	}

	if _raw_target_height_image == null or _raw_current_height_image == null:
		return stats

	var scene_depth_img := scene_depth_tex.get_image()
	var res := _raw_target_height_image.get_width()
	var h_min := 9999.0
	var h_max := -9999.0

	for y in range(res):
		for x in range(res):
			var v := _raw_target_height_image.get_pixelv(Vector2i(x, y)).r
			h_min = minf(h_min, v)
			h_max = maxf(h_max, v)
	stats.target_h_min = h_min
	stats.target_h_max = h_max

	var total_gen := 0
	var filled_ok := 0
	var still_under := 0
	var rock_overshoot := 0
	var sum_sq_err := 0.0
	var sum_abs_err := 0.0
	var max_err := 0.0
	var sum_sq_fillable := 0.0
	var sum_abs_fillable := 0.0
	var fillable_count := 0
	var sum_rock_added := 0.0
	var rock_added_count := 0

	for y in range(res):
		for x in range(res):
			var gen_mask := _raw_current_height_image.get_pixelv(Vector2i(x, y)).b
			if gen_mask < 0.5:
				continue
			total_gen += 1

			var target_h := _raw_target_height_image.get_pixelv(Vector2i(x, y)).r
			var current_h := _raw_current_height_image.get_pixelv(Vector2i(x, y)).r
			var initial_h := max_height - scene_depth_img.get_pixelv(Vector2i(x, y)).r
			var diff := current_h - target_h

			sum_sq_err += diff * diff
			sum_abs_err += absf(diff)
			max_err = maxf(max_err, absf(diff))

			if initial_h <= target_h + 0.5:
				fillable_count += 1
				var fillable_diff := current_h - target_h
				sum_sq_fillable += fillable_diff * fillable_diff
				sum_abs_fillable += absf(fillable_diff)
				if absf(fillable_diff) < 0.5:
					filled_ok += 1
				elif fillable_diff < -0.5:
					still_under += 1
				else:
					rock_overshoot += 1

			var rock_h := current_h - initial_h
			if rock_h > 0.1:
				sum_rock_added += rock_h
				rock_added_count += 1

	stats.total_gen = total_gen
	stats.max_err = max_err
	if total_gen > 0:
		stats.rmse = sqrt(sum_sq_err / float(total_gen))
		stats.mae = sum_abs_err / float(total_gen)
	if fillable_count > 0:
		stats.fillable_rmse = sqrt(sum_sq_fillable / float(fillable_count))
		stats.fillable_mae = sum_abs_fillable / float(fillable_count)
		stats.filled_ok_pct = float(filled_ok) / float(fillable_count) * 100.0
		stats.under_filled_pct = float(still_under) / float(fillable_count) * 100.0
		stats.overshoot_pct = float(rock_overshoot) / float(fillable_count) * 100.0
	if rock_added_count > 0:
		stats.avg_rock_height = sum_rock_added / float(rock_added_count)

	print("[MeshFill]   Placements: %d | Time: %dms | Flood iters: %d" % [placement_count, elapsed_ms, flood_iters])
	print("[MeshFill]   Target H range: %.1f - %.1f" % [h_min, h_max])
	print("[MeshFill]   RMSE: %.3f | MAE: %.3f | MaxErr: %.3f" % [stats.rmse, stats.mae, max_err])
	print("[MeshFill]   Filled OK: %.1f%% | Under: %.1f%% | Over: %.1f%%" % [stats.filled_ok_pct, stats.under_filled_pct, stats.overshoot_pct])
	return stats


func _print_batch_summary() -> void:
	print("")
	print("[MeshFill] 鈺斺晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晽")
	print("[MeshFill] BATCH TEST SUMMARY")
	print("[MeshFill] 鈺犫晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨暎")
	print("[MeshFill] Extension | FloodItr | Placements | Time(ms) | RMSE | MAE | MaxErr | Filled%% | Under%% | Over%% | TgtRange")
	print("[MeshFill] 鈺犫晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨暎")
	for s in _batch_results:
		print("[MeshFill] %7.1fm | %4d | %4d | %5d | %6.3f | %6.3f | %6.3f | %5.1f | %5.1f | %5.1f | %.1f-%.1f" % [
			s.extension, s.flood_iterations, s.placements, s.elapsed_ms,
			s.rmse, s.mae, s.max_err,
			s.filled_ok_pct, s.under_filled_pct, s.overshoot_pct,
			s.target_h_min, s.target_h_max])
	print("[MeshFill] 鈺氣晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨晲鈺愨暆")
	print("")

	var best_rmse_idx := 0
	var best_filled_idx := 0
	for i in range(_batch_results.size()):
		if _batch_results[i].rmse < _batch_results[best_rmse_idx].rmse and _batch_results[i].rmse > 0.0:
			best_rmse_idx = i
		if _batch_results[i].filled_ok_pct > _batch_results[best_filled_idx].filled_ok_pct:
			best_filled_idx = i

	print("[MeshFill] KEY FINDINGS")
	print("[MeshFill]   Best RMSE:    extension=%.1fm (RMSE=%.3f)" % [_batch_results[best_rmse_idx].extension, _batch_results[best_rmse_idx].rmse])
	print("[MeshFill]   Best Fill%%:   extension=%.1fm (%.1f%% filled OK)" % [_batch_results[best_filled_idx].extension, _batch_results[best_filled_idx].filled_ok_pct])
	print("[MeshFill]   Images saved to: %s/batch_test/" % OS.get_user_data_dir())


func _input(event: InputEvent) -> void:
	if _tile_refresh_mode:
		if event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
				_tile_refresh_at_screen(mb.position)
				get_viewport().set_input_as_handled()
		return
	if not _brush_active:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_paint_positive = true
			if mb.pressed:
				_begin_brush_stroke()
				_painting = true
				_push_undo_snapshot()
				_paint_at_screen(mb.position)
			elif _painting:
				_painting = false
				_finish_brush_stroke()
			else:
				_painting = false
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			_paint_positive = false
			if mb.pressed:
				_begin_brush_stroke()
				_painting = true
				_push_undo_snapshot()
				_paint_at_screen(mb.position)
			elif _painting:
				_painting = false
				_finish_brush_stroke()
			else:
				_painting = false
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			if mb.shift_pressed:
				_brush_radius = mini(_brush_radius + 2, 50)
			else:
				_brush_strength = minf(_brush_strength + 0.5, 20.0)
			_update_brush_label()
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			if mb.shift_pressed:
				_brush_radius = maxi(_brush_radius - 2, 2)
			else:
				_brush_strength = maxf(0.5, _brush_strength - 0.5)
			_update_brush_label()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _painting:
		_paint_at_screen((event as InputEventMouseMotion).position)
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var ke := event as InputEventKey
		if ke.pressed and enable_test_generation_tools and ke.keycode == KEY_C:
			_step_generate()
		elif ke.pressed and ke.keycode == KEY_J and ke.ctrl_pressed:
			_recompute_and_save_target_scene_voxel()
			get_viewport().set_input_as_handled()
		elif ke.pressed and ke.keycode == KEY_J:
			_toggle_target_scene_voxel_overlay()
			get_viewport().set_input_as_handled()
		elif ke.pressed and ke.keycode == KEY_G:
			_toggle_debug_overlay()
		elif ke.pressed and ke.keycode == KEY_H:
			_toggle_diff_overlay()
		elif ke.pressed and ke.keycode == KEY_V:
			_toggle_delta_overlay()
		elif ke.pressed and ke.keycode == KEY_B:
			_toggle_brush_mode()
		elif ke.pressed and ke.keycode == KEY_T:
			_toggle_tile_refresh_mode()
		elif ke.pressed and ke.keycode == KEY_N:
			_cycle_brush_target()
		elif ke.pressed and ke.keycode == KEY_Z and ke.ctrl_pressed:
			_undo_override()
		elif ke.pressed and enable_test_generation_tools and ke.keycode == KEY_P:
			_generate_vegetation()
		elif ke.pressed and ke.keycode == KEY_M:
			_toggle_mask_overlay()
		elif ke.pressed and ke.keycode == KEY_F12:
			_save_viewport_screenshot()


func _world_to_texture_pixel(world_pos: Vector3, resolution: int = TEX_RES) -> Vector2i:
	var half := capture_size / 2.0
	var px := clampi(floori((world_pos.x + half) / capture_size * float(resolution)), 0, resolution - 1)
	var pz := clampi(floori((world_pos.z + half) / capture_size * float(resolution)), 0, resolution - 1)
	return Vector2i(px, pz)


func _vector3_from_record_value(value, fallback: Vector3) -> Vector3:
	if value is Vector3:
		return value as Vector3
	if value is Array:
		var arr := value as Array
		if arr.size() >= 3:
			return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
	if value is Dictionary:
		var dict := value as Dictionary
		return Vector3(
			float(dict.get("x", fallback.x)),
			float(dict.get("y", fallback.y)),
			float(dict.get("z", fallback.z))
		)
	return fallback


func _normalize_rotation_record(mi: MeshInstance3D, rec: Dictionary) -> void:
	var mode := str(rec.get("rotation_mode", ""))
	if mode.is_empty():
		mode = "XYZ" if (rec.has("rotation_degrees") or rec.has("rotation_xyz")) and not rec.has("rotation_y") else "Y"
	mode = mode.to_upper()
	if mode != "XYZ":
		mode = "Y"

	var rotation_value := mi.rotation_degrees
	if rec.has("rotation_degrees"):
		rotation_value = _vector3_from_record_value(rec.rotation_degrees, rotation_value)
	elif rec.has("rotation_xyz"):
		rotation_value = _vector3_from_record_value(rec.rotation_xyz, rotation_value)

	if mode == "Y":
		var y_rotation := rotation_value.y
		if rec.has("rotation_y"):
			y_rotation = float(rec.rotation_y)
		rotation_value = Vector3(0.0, y_rotation, 0.0)

	rec["rotation_mode"] = mode
	rec["rotation_degrees"] = rotation_value
	rec.erase("rotation_y")
	rec.erase("rotation_xyz")


func _ensure_auto_object_manager() -> AutoObjectManager:
	if _auto_object_manager != null and is_instance_valid(_auto_object_manager):
		return _auto_object_manager

	var existing := get_node_or_null("AutoObjectManager")
	if existing is AutoObjectManager:
		_auto_object_manager = existing as AutoObjectManager
		return _auto_object_manager

	_auto_object_manager = AutoObjectManager.new()
	_auto_object_manager.name = "AutoObjectManager"
	add_child(_auto_object_manager)
	return _auto_object_manager


func get_auto_object_manager() -> AutoObjectManager:
	return _ensure_auto_object_manager()


func _register_auto_object(mi: MeshInstance3D, record: Dictionary) -> void:
	if not mi is AutoObject:
		return
	var manager := _ensure_auto_object_manager()
	manager.register_object(mi as AutoObject, record)


func _mark_test_only_record(record: Dictionary, kind: String) -> Dictionary:
	var next_record := record.duplicate(true)
	next_record["test_only"] = true
	next_record["test_only_kind"] = kind
	next_record["test_only_reason"] = "auto_generation_tool"
	return next_record


func _mark_test_only_generated(node: Node, kind: String) -> void:
	if node == null:
		return
	node.set_meta("test_only", true)
	node.set_meta("test_only_kind", kind)
	node.set_meta("test_only_reason", "auto_generation_tool")
	node.add_to_group(TEST_ONLY_GROUP)
	if kind == "rock":
		node.add_to_group(TEST_ONLY_ROCK_GROUP)
	elif kind == "vegetation":
		node.add_to_group(TEST_ONLY_VEGETATION_GROUP)


func _instantiate_rock_asset(asset: AutoRock) -> AutoRock:
	if asset == null:
		return AutoCliffRock.new()
	var duplicate_node := asset.duplicate()
	if duplicate_node is AutoRock:
		var duplicated_rock := duplicate_node as AutoRock
		duplicated_rock.name = ""
		duplicated_rock.auto_id = ""
		duplicated_rock.voxel_record = {}
		duplicated_rock.instance_id = 0
		return duplicated_rock
	if duplicate_node != null:
		duplicate_node.free()

	var script = asset.get_script()
	if script != null:
		var scripted = script.new()
		if scripted is AutoRock:
			return scripted as AutoRock
	return AutoCliffRock.new()


func _mesh_bound_min_length(mi: MeshInstance3D) -> float:
	if mi == null or mi.mesh == null:
		return 0.0
	var aabb := mi.mesh.get_aabb()
	var world_size := Vector3(
		absf(aabb.size.x * mi.scale.x),
		absf(aabb.size.y * mi.scale.y),
		absf(aabb.size.z * mi.scale.z)
	)
	var result := INF
	for axis_length in [world_size.x, world_size.y, world_size.z]:
		var length_value := float(axis_length)
		if length_value > 0.0001:
			result = minf(result, length_value)
	return 0.0 if result == INF else result


func _attach_mesh_voxel_record(mi: MeshInstance3D, record: Dictionary) -> Dictionary:
	var rec: Dictionary = record.duplicate(true)
	if rec.has("voxel_layers") and not rec.has("SenceLayerVoxel"):
		rec["SenceLayerVoxel"] = rec.voxel_layers
	rec.erase("voxel_layers")
	var record_id := str(rec.get("id", mi.name))
	var color: Color = rec.get("color", Color.WHITE)
	var complexity := clampf(float(rec.get("complexity", color.a)), 0.0, 1.0)
	color.a = complexity
	var mesh_instance_id := int(mi.get_instance_id())
	var bound_min_length := _mesh_bound_min_length(mi)
	var min_spacing_auto := bool(rec.get("min_spacing_auto", true))
	var min_spacing := maxf(float(rec.get("min_spacing", 0.0)), 0.0)
	var source_kind := str(rec.get("source_kind", rec.get("auto_source", rec.get("placement_source", "")))).to_lower()
	if source_kind.is_empty():
		var record_type_hint := str(rec.get("type", ""))
		match record_type_hint:
			"rock":
				source_kind = "rock_placement"
			"vegetation", "grass", "bush", "tree", "midstory_tree", "canopy_tree":
				source_kind = "scatter"
			_:
				source_kind = "auto"
	var source_voxel_type := str(rec.get("source_voxel_type", ""))
	if source_voxel_type != "AutoSceneVoxel" and source_voxel_type != "BrushSceneVoxel" and source_voxel_type != "TargetSceneVoxel":
		if ["brush", "manual_edit", "erase", "lock"].has(source_kind):
			source_voxel_type = "BrushSceneVoxel"
		elif ["target", "heightfield_target", "flood_target", "guidance"].has(source_kind):
			source_voxel_type = "TargetSceneVoxel"
		else:
			source_voxel_type = "AutoSceneVoxel"

	rec["id"] = record_id
	rec["mesh_name"] = mi.name
	rec["position"] = mi.position
	rec["scale"] = mi.scale
	_normalize_rotation_record(mi, rec)
	rec["color"] = color
	rec["complexity"] = complexity
	rec["source_voxel_type"] = source_voxel_type
	rec["source_kind"] = source_kind
	if not rec.has("producer_stage"):
		if source_voxel_type == "BrushSceneVoxel":
			rec["producer_stage"] = "brush_edit"
		elif source_voxel_type == "TargetSceneVoxel":
			rec["producer_stage"] = "target_pipeline"
		else:
			rec["producer_stage"] = source_kind
	if source_voxel_type == "BrushSceneVoxel" and not rec.has("auto_mix"):
		rec["auto_mix"] = 0.0
	if source_voxel_type == "TargetSceneVoxel":
		if not rec.has("target_mix"):
			rec["target_mix"] = 1.0
		if not rec.has("target_pipeline"):
			rec["target_pipeline"] = source_kind
	if mi is AutoObject:
		var auto_object := mi as AutoObject
		auto_object.refresh_bound_spacing()
		bound_min_length = auto_object.bound_min_length
		if min_spacing <= 0.0:
			min_spacing = auto_object.min_spacing
			min_spacing_auto = auto_object.min_spacing_auto
		var auto_instance_id := auto_object.refresh_instance_id()
		var auto_id := auto_object.auto_id if not auto_object.auto_id.is_empty() else record_id
		rec["instance_id"] = auto_instance_id
		rec["auto_instance_id"] = auto_instance_id
		rec["auto_id"] = auto_id
		rec["auto_object_id"] = auto_id
		rec["auto_source"] = auto_object.auto_source
		if not rec.has("affected_bands") and not auto_object.affected_bands.is_empty():
			rec["affected_bands"] = auto_object.affected_bands.duplicate(true)
		if not rec.has("collision_voxels") and not auto_object.collision_voxels.is_empty():
			rec["collision_voxels"] = auto_object.collision_voxels.duplicate(true)
		if not rec.has("semantic_probe_density"):
			rec["semantic_probe_density"] = auto_object.semantic_probe_density
		var semantic_probes := auto_object.get_semantic_probes(auto_object.semantic_probe_density)
		if not rec.has("semantic_probes") and not semantic_probes.is_empty():
			rec["semantic_probes"] = semantic_probes
	else:
		rec["instance_id"] = mesh_instance_id
		rec["auto_instance_id"] = int(rec.get("auto_instance_id", 0))
		rec["auto_id"] = str(rec.get("auto_id", rec.get("auto_object_id", "")))
		rec["auto_object_id"] = str(rec.get("auto_object_id", rec.get("auto_id", "")))
	rec["instance_mesh_id"] = mesh_instance_id
	rec["mesh_instance_id"] = mesh_instance_id
	if min_spacing <= 0.0:
		min_spacing = bound_min_length * 0.5
	rec["bound_min_length"] = bound_min_length
	rec["min_spacing"] = min_spacing
	rec["min_spacing_auto"] = min_spacing_auto
	if not rec.has("base_pixel"):
		rec["base_pixel"] = _world_to_texture_pixel(mi.position)
	if not rec.has("voxel_xz"):
		rec["voxel_xz"] = rec.base_pixel
	if not rec.has("volume_xz_resolution"):
		rec["volume_xz_resolution"] = TEX_RES
	if mi.is_inside_tree():
		rec["node_path"] = str(mi.get_path())

	if mi is AutoObject:
		(mi as AutoObject).set_voxel_record(rec)
	else:
		mi.set_meta("voxel_record", rec)
		mi.set_meta("instance_id", rec.instance_id)
		mi.set_meta("instance_mesh_id", rec.instance_mesh_id)
	_mesh_voxel_records[record_id] = rec
	_register_auto_object(mi, rec)
	return rec


func get_mesh_voxel_records() -> Dictionary:
	return _mesh_voxel_records.duplicate(true)


func get_mesh_voxel_record(record_id: String) -> Dictionary:
	var record = _mesh_voxel_records.get(record_id, {})
	if record is Dictionary:
		var typed_record := record as Dictionary
		return typed_record.duplicate(true)
	return {}


func _remove_mesh_voxel_record(node: Node) -> void:
	if node is AutoObject:
		var manager := _ensure_auto_object_manager()
		manager.unregister_object(node as AutoObject)
	if not node.has_meta("voxel_record"):
		return
	var rec = node.get_meta("voxel_record")
	if rec is Dictionary:
		var record := rec as Dictionary
		if record.has("id"):
			_mesh_voxel_records.erase(str(record.id))


func _generate_cliff_placements(generator: CliffGenerator, num_iters: int) -> Array[Dictionary]:
	if generator == null:
		return []
	if use_surface_3d_cliff_placement:
		return generator.generate_surface_placement(num_iters)
	return generator.generate_cliff_vertical(num_iters)


func _make_rock_affected_bands(color: Color, complexity: float, radius: float) -> Array[Dictionary]:
	return [
		{"band": "ground", "channel": 0, "radius": radius, "color": color, "complexity": complexity},
		{"band": "understory", "channel": 1, "radius": radius, "color": color, "complexity": complexity},
		{"band": "midstory", "channel": 2, "radius": radius, "color": color, "complexity": complexity},
		{"band": "canopy", "channel": 3, "radius": radius, "color": color, "complexity": complexity},
	]


func _make_cliff_voxel_record(
	record_id: String,
	r: Dictionary,
	mi: MeshInstance3D,
	mesh_aabb: AABB,
	asset: AutoRock = null
) -> Dictionary:
	var color: Color = asset.get_voxel_color() if asset != null else r.get("color", ROCK_VOXEL_COLOR)
	var complexity := asset.get_voxel_complexity() if asset != null else clampf(float(r.get("complexity", color.a)), 0.0, 1.0)
	color.a = complexity
	var base_px := _world_to_texture_pixel(mi.position)
	var y_min := mi.position.y + mesh_aabb.position.y * mi.scale.y
	var y_max := mi.position.y + (mesh_aabb.position.y + mesh_aabb.size.y) * mi.scale.y
	if y_max < y_min:
		var tmp := y_min
		y_min = y_max
		y_max = tmp
	var radius := maxf(mesh_aabb.size.x * absf(mi.scale.x), mesh_aabb.size.z * absf(mi.scale.z)) * 0.5
	radius = maxf(radius, capture_size / float(TEX_RES))
	var affected_bands := asset.get_affected_bands(radius) if asset != null else _make_rock_affected_bands(color, complexity, radius)
	var collision_voxels := asset.get_collision_voxels(radius) if asset != null else []
	var sence_layer_voxels: Array[Dictionary] = []
	for band in affected_bands:
		var layer := band.duplicate(true)
		layer["base_pixel"] = base_px
		layer["voxel_xz"] = base_px
		layer["y_min"] = y_min
		layer["y_max"] = y_max
		layer["slice_indices"] = []
		sence_layer_voxels.append(layer)

	return {
		"id": record_id,
		"type": "rock",
		"source_voxel_type": "AutoSceneVoxel",
		"source_kind": "rock_placement",
		"producer_stage": "rock_placement",
		"mesh_index": int(r.mesh_index),
		"position": mi.position,
		"rotation_mode": str(r.get("rotation_mode", "Y")),
		"rotation_degrees": r.get("rotation_degrees", Vector3(0.0, float(r.get("rotation_y", 0.0)), 0.0)),
		"scale": mi.scale,
		"base_pixel": base_px,
		"voxel_xz": base_px,
		"volume_xz_resolution": TEX_RES,
		"color": color,
		"complexity": complexity,
		"affected_bands": affected_bands,
		"collision_voxels": collision_voxels,
		"SenceLayerVoxel": sence_layer_voxels,
	}


func _make_terrain_voxel_record(mi: MeshInstance3D, resolution: int) -> Dictionary:
	var color := TERRAIN_VOXEL_COLOR
	var height_stats := Vector2.ZERO
	if mi.has_meta("terrain_height_stats"):
		height_stats = mi.get_meta("terrain_height_stats")
	return {
		"id": "Terrain",
		"type": "terrain",
		"position": mi.position,
		"scale": mi.scale,
		"base_pixel": Vector2i.ZERO,
		"voxel_xz": Vector2i.ZERO,
		"volume_xz_resolution": resolution,
		"color": color,
		"complexity": 1.0,
		"height_min": height_stats.x,
		"height_max": height_stats.y,
		"height_resolution": Vector2i(resolution, resolution),
		"SenceLayerVoxel": [{
			"band": "terrain_surface",
			"channel": -1,
			"base_pixel": Vector2i.ZERO,
			"voxel_xz": Vector2i.ZERO,
			"y_min": 0.0,
			"y_max": 0.0,
			"color": color,
			"complexity": 1.0,
			"slice_indices": [],
		}],
	}


func _attach_vegetation_voxel_record(mi: MeshInstance3D, r: Dictionary, apply_to_buffers: bool = true) -> void:
	var record_id := str(r.get("id", mi.name))
	var voxel_record: Dictionary = {}
	if _veg_exclusion != null:
		voxel_record = _veg_exclusion.get_mesh_voxel_record(record_id)
	if voxel_record.is_empty():
		voxel_record = r.get("voxel_record", {})
	if voxel_record.is_empty():
		var color: Color = r.get("color", Color.WHITE)
		var complexity := clampf(float(r.get("complexity", color.a)), 0.0, 1.0)
		color.a = complexity
		var base_px := _world_to_texture_pixel(mi.position)
		voxel_record = {
			"id": record_id,
			"type": r.get("type", "vegetation"),
			"auto_source": r.get("auto_source", r.get("placement_source", "scatter")),
			"source_voxel_type": "BrushSceneVoxel" if str(r.get("auto_source", r.get("placement_source", "scatter"))).to_lower() == "brush" else "AutoSceneVoxel",
			"source_kind": str(r.get("source_kind", r.get("auto_source", r.get("placement_source", "scatter")))).to_lower(),
			"producer_stage": "brush_edit" if str(r.get("auto_source", r.get("placement_source", "scatter"))).to_lower() == "brush" else "vegetation_scatter",
			"position": mi.position,
			"scale": mi.scale,
			"base_pixel": base_px,
			"voxel_xz": base_px,
			"volume_xz_resolution": TEX_RES,
			"color": color,
			"complexity": complexity,
			"affected_bands": r.get("affected_bands", []),
			"collision_voxels": r.get("collision_voxels", []),
			"SenceLayerVoxel": [],
		}
	var attached := _attach_mesh_voxel_record(mi, voxel_record)
	if apply_to_buffers and _veg_exclusion != null:
		attached = _veg_exclusion.apply_mesh_voxel_record(attached)
		attached = _attach_mesh_voxel_record(mi, attached)


func register_brush_vegetation(mi: AutoVegetation, placement_data: Dictionary = {}) -> void:
	if mi == null:
		return
	_ensure_auto_object_manager()
	var data := placement_data.duplicate(true)
	var raw_profile = data.get("voxel_profile", null)
	if raw_profile is AutoVoxelProfile:
		mi.voxel_profile = raw_profile as AutoVoxelProfile
	if not data.has("id"):
		data["id"] = mi.name
	if not data.has("type"):
		data["type"] = mi.object_subtype if not mi.object_subtype.is_empty() else "vegetation"
	data["auto_source"] = "brush"
	data["source_voxel_type"] = "BrushSceneVoxel"
	data["source_kind"] = "brush"
	data["producer_stage"] = "brush_edit"
	if not data.has("auto_mix"):
		data["auto_mix"] = 0.0
	data["position"] = mi.position
	data["scale"] = mi.scale
	if not data.has("color"):
		data["color"] = mi.get_voxel_color()
	if not data.has("complexity"):
		data["complexity"] = mi.get_voxel_complexity()
	if not data.has("affected_bands") or not data["affected_bands"] is Array:
		data["affected_bands"] = mi.get_affected_bands()
	if not data.has("collision_voxels") or not data["collision_voxels"] is Array:
		data["collision_voxels"] = mi.get_collision_voxels()
	var data_bands: Array = data["affected_bands"]
	if data_bands.is_empty() and not mi.vegetation_band.is_empty():
		var color: Color = data.get("color", Color.WHITE)
		var complexity := clampf(float(data.get("complexity", color.a)), 0.0, 1.0)
		color.a = complexity
		data["affected_bands"] = [_make_vegetation_band_entry(mi.vegetation_band, color, complexity)]

	mi.auto_source = "brush"
	mi.add_to_group("placed_brush_vegetation")
	if mi.get_parent() == null:
		_add_level_child(mi)
	var defer_buffer_update := bool(data.get("defer_voxel_update", _painting))
	_attach_vegetation_voxel_record(mi, data, not defer_buffer_update)
	if defer_buffer_update:
		_brush_voxel_commit_pending = true
		var brush_px := _world_to_texture_pixel(mi.position)
		var brush_radius_px := 1
		var pixel_size := capture_size / float(TEX_RES)
		for band_raw in data["affected_bands"]:
			if band_raw is Dictionary:
				var band := band_raw as Dictionary
				brush_radius_px = maxi(brush_radius_px, ceili(float(band.get("radius", pixel_size)) / pixel_size))
		for collision_raw in data["collision_voxels"]:
			if collision_raw is Dictionary:
				var collision := collision_raw as Dictionary
				var radius := maxf(float(collision.get("radius", pixel_size)), 0.0)
				var erosion := maxf(float(collision.get("erosion_radius", 0.0)), 0.0)
				var dilation := maxf(float(collision.get("dilation_radius", 0.0)), 0.0)
				var effective_radius := 0.0 if erosion > 0.0 and radius <= erosion else maxf(radius - erosion, 0.0) + dilation
				brush_radius_px = maxi(brush_radius_px, ceili(effective_radius / pixel_size))
		_merge_dirty_rect(Rect2i(
			Vector2i(brush_px.x - brush_radius_px, brush_px.y - brush_radius_px),
			Vector2i(brush_radius_px * 2 + 1, brush_radius_px * 2 + 1)
		))


func commit_brush_vegetation_edits(dirty_rect: Rect2i = Rect2i()) -> void:
	if dirty_rect.size.x > 0 and dirty_rect.size.y > 0:
		_merge_dirty_rect(dirty_rect)
	_brush_voxel_commit_pending = true
	_finish_brush_stroke()


func _make_vegetation_band_entry(band_name: String, color: Color, complexity: float) -> Dictionary:
	var channel := 0
	var radius := 0.2
	match band_name:
		"understory":
			channel = 1
			radius = 1.0
		"midstory":
			channel = 2
			radius = 2.0
		"canopy":
			channel = 3
			radius = 3.0
		_:
			channel = 0
			radius = 0.2
	return {
		"band": band_name,
		"channel": channel,
		"radius": radius,
		"color": color,
		"complexity": complexity,
	}


func _meters_to_pixels(radius_m: float, resolution: int = TEX_RES) -> int:
	var pixel_size := capture_size / float(maxi(resolution, 1))
	return maxi(1, ceili(maxf(radius_m, 0.0) / pixel_size))


func _stamp_mask_disc(mask: Image, center: Vector2i, outer_radius_px: int, value: float = 1.0, inner_radius_px: int = 0) -> void:
	if mask == null:
		return
	var w := mask.get_width()
	var h := mask.get_height()
	var outer_sq := outer_radius_px * outer_radius_px
	var inner_sq := inner_radius_px * inner_radius_px
	for dy in range(-outer_radius_px, outer_radius_px + 1):
		for dx in range(-outer_radius_px, outer_radius_px + 1):
			var dist_sq := dx * dx + dy * dy
			if dist_sq > outer_sq or (inner_radius_px > 0 and dist_sq <= inner_sq):
				continue
			var px := Vector2i(center.x + dx, center.y + dy)
			if px.x < 0 or px.x >= w or px.y < 0 or px.y >= h:
				continue
			var cur := mask.get_pixelv(px).r
			mask.set_pixelv(px, Color(maxf(cur, value), 0.0, 0.0, 0.0))


func _make_landscape_cliff_mask(height_img: Image) -> Image:
	var mask := Image.create(TEX_RES, TEX_RES, false, Image.FORMAT_RF)
	mask.fill(Color(0.0, 0.0, 0.0, 0.0))
	if height_img == null:
		return mask
	var w := height_img.get_width()
	var h := height_img.get_height()
	var pixel_size := capture_size / float(maxi(w, 1))
	var slope_start := maxf(landscape_cliff_slope_start, 0.0001)
	var slope_range := maxf(landscape_cliff_slope_full - slope_start, 0.0001)
	for y in range(TEX_RES):
		for x in range(TEX_RES):
			var sx := clampi(floori(float(x) / float(TEX_RES) * float(w)), 0, w - 1)
			var sy := clampi(floori(float(y) / float(TEX_RES) * float(h)), 0, h - 1)
			var sx0 := maxi(sx - 1, 0)
			var sx1 := mini(sx + 1, w - 1)
			var sy0 := maxi(sy - 1, 0)
			var sy1 := mini(sy + 1, h - 1)
			var dhdx := (height_img.get_pixelv(Vector2i(sx1, sy)).r - height_img.get_pixelv(Vector2i(sx0, sy)).r) / maxf(float(sx1 - sx0) * pixel_size, 0.0001)
			var dhdz := (height_img.get_pixelv(Vector2i(sx, sy1)).r - height_img.get_pixelv(Vector2i(sx, sy0)).r) / maxf(float(sy1 - sy0) * pixel_size, 0.0001)
			var slope := sqrt(dhdx * dhdx + dhdz * dhdz)
			var value := clampf((slope - slope_start) / slope_range, 0.0, 1.0)
			if value > 0.0:
				mask.set_pixelv(Vector2i(x, y), Color(value, 0.0, 0.0, 0.0))
	return mask


func _make_cliff_tree_mask(rock_mask_img: Image, height_img: Image) -> Image:
	var mask := Image.create(TEX_RES, TEX_RES, false, Image.FORMAT_RF)
	mask.fill(Color(0.0, 0.0, 0.0, 0.0))
	var cliff_mask := _make_landscape_cliff_mask(height_img)
	var outer_radius_px := _meters_to_pixels(cliff_tree_stamp_radius)
	var inner_radius_px := _meters_to_pixels(cliff_tree_stamp_inner_radius)
	for y in range(TEX_RES):
		for x in range(TEX_RES):
			var px := Vector2i(x, y)
			var cliff_value := cliff_mask.get_pixelv(px).r
			if rock_mask_img != null:
				cliff_value = maxf(cliff_value, rock_mask_img.get_pixelv(px).r)
			if cliff_value <= 0.01:
				continue
			_stamp_mask_disc(mask, px, outer_radius_px, cliff_value, inner_radius_px)
	for y in range(TEX_RES):
		for x in range(TEX_RES):
			var px := Vector2i(x, y)
			var block_value := cliff_mask.get_pixelv(px).r
			if rock_mask_img != null:
				block_value = maxf(block_value, rock_mask_img.get_pixelv(px).r)
			if block_value > 0.01:
				mask.set_pixelv(px, Color(0.0, 0.0, 0.0, 0.0))
	return mask


func _make_tree_grass_mask(tree_results: Array[Dictionary]) -> Image:
	var mask := Image.create(TEX_RES, TEX_RES, false, Image.FORMAT_RF)
	mask.fill(Color(0.0, 0.0, 0.0, 0.0))
	var radius_px := _meters_to_pixels(tree_grass_stamp_radius)
	for result in tree_results:
		var pos: Vector3 = result.get("position", Vector3.ZERO)
		_stamp_mask_disc(mask, _world_to_texture_pixel(pos), radius_px, 1.0)
	return mask


func _apply_scene_mesh_voxels_to_vegetation_buffers() -> int:
	if _veg_exclusion == null:
		return 0
	var applied := 0
	for record_id in _mesh_voxel_records.keys():
		var raw_record = _mesh_voxel_records[record_id]
		if not raw_record is Dictionary:
			continue
		var record := raw_record as Dictionary
		var record_type := str(record.get("type", ""))
		var record_source := str(record.get("auto_source", record.get("placement_source", "")))
		var should_apply := record_type == "rock" or record_source == "brush"
		if not should_apply:
			continue
		var updated := _veg_exclusion.apply_mesh_voxel_record(record)
		if bool(updated.get("height_buffer_applied", false)):
			applied += 1
			var node_path := str(updated.get("node_path", ""))
			var node := get_node_or_null(NodePath(node_path)) if not node_path.is_empty() else null
			if node is MeshInstance3D:
				var mesh_node := node as MeshInstance3D
				_attach_mesh_voxel_record(mesh_node, updated)
			else:
				_mesh_voxel_records[record_id] = updated
	return applied


func _sync_scene_mesh_voxel_records_from_exclusion() -> void:
	if _veg_exclusion == null:
		return
	for record in _veg_exclusion.get_mesh_voxel_records():
		var record_id := str(record.get("id", ""))
		if record_id.is_empty() or not _mesh_voxel_records.has(record_id):
			continue
		var node_path := str(record.get("node_path", ""))
		var node := get_node_or_null(NodePath(node_path)) if not node_path.is_empty() else null
		if node is MeshInstance3D:
			var mesh_node := node as MeshInstance3D
			_attach_mesh_voxel_record(mesh_node, record)
		else:
			_mesh_voxel_records[record_id] = record


func _sync_vegetation_masks_from_exclusion() -> void:
	if _veg_exclusion == null:
		return
	_tree_mask_image = _veg_exclusion.get_band_mask_at_base_res("canopy")
	_midstory_mask_image = _veg_exclusion.get_band_mask_at_base_res("midstory")
	_bush_mask_image = _veg_exclusion.get_band_mask_at_base_res("understory")
	_grass_mask_image = _veg_exclusion.get_band_mask_at_base_res("ground")


func _import_rock_mask_to_vegetation_buffers() -> void:
	if _veg_exclusion == null:
		return
	var rock_mask_img: Image = null
	if _current_rock_mask_img != null:
		rock_mask_img = _current_rock_mask_img
	else:
		rock_mask_img = Image.create(TEX_RES, TEX_RES, false, Image.FORMAT_RF)
		rock_mask_img.fill(Color(0.0, 0.0, 0.0, 0.0))

	for band_name in ["ground", "understory", "midstory", "canopy"]:
		_veg_exclusion.import_mask(band_name, rock_mask_img)


func _record_should_write_vegetation_buffers(record: Dictionary) -> bool:
	var record_type := str(record.get("type", ""))
	if record_type == "terrain":
		return false
	var layers: Array = record.get("SenceLayerVoxel", record.get("voxel_layers", []))
	var affected: Array = record.get("affected_bands", [])
	return not layers.is_empty() or not affected.is_empty()


func _rebuild_vegetation_buffers_from_scene_records(_dirty_rect: Rect2i = Rect2i()) -> int:
	if _veg_exclusion == null:
		_ensure_vegetation_exclusion()
	if _veg_exclusion == null:
		return 0

	_veg_exclusion.reset_occupancy()
	_import_rock_mask_to_vegetation_buffers()

	var applied := 0
	for record_id in _mesh_voxel_records.keys():
		var raw_record = _mesh_voxel_records[record_id]
		if not raw_record is Dictionary:
			continue
		var record := raw_record as Dictionary
		if not _record_should_write_vegetation_buffers(record):
			continue

		var updated := _veg_exclusion.apply_mesh_voxel_record(record)
		if updated.is_empty():
			continue
		applied += 1
		var node_path := str(updated.get("node_path", ""))
		var node := get_node_or_null(NodePath(node_path)) if not node_path.is_empty() else null
		if node is MeshInstance3D:
			_attach_mesh_voxel_record(node as MeshInstance3D, updated)
		else:
			_mesh_voxel_records[record_id] = updated

	_veg_exclusion.build_voxel_volume(TEX_RES / 2, [1, 2, 2, 1])
	_sync_scene_mesh_voxel_records_from_exclusion()
	_sync_vegetation_masks_from_exclusion()

	if _debug_mask_terrain != null:
		var was_visible := _debug_mask_terrain.visible
		_build_debug_mask_terrain()
		if _debug_mask_terrain != null:
			_debug_mask_terrain.visible = was_visible
	_save_combined_mask_debug()

	return applied


func _step_generate() -> void:
	if _cached_textures.is_empty() or _cached_assets.is_empty():
		push_error("[MeshFill] Cannot step: textures or assets not loaded")
		return

	_step_count += 1
	print("[MeshFill] Step %d" % _step_count)

	_invalidate_overrides()
	var composited_th := _composite_target_height()

	var prev_rock_mask := _load_previous_rock_mask()

	var generator := CliffGenerator.new()
	generator.texture_size = TEX_RES
	generator.capture_size = capture_size
	generator.max_height = max_height
	generator.generate_threshold = generate_threshold
	generator.un_generate_threshold = un_generate_threshold
	generator.scene_depth_texture = _cached_textures["scene_depth"]
	generator.scene_normal_texture = _cached_textures["scene_normal"]
	generator.object_depth_texture = _cached_textures["object_depth"]
	generator.object_normal_texture = _cached_textures["object_normal"]
	generator.height_normal_texture = _cached_textures["height_normal"]
	generator.target_height_texture = composited_th
	generator.rock_mask_texture = prev_rock_mask
	if _rock_override_mask != null:
		generator.rock_override_mask_texture = ImageTexture.create_from_image(_rock_override_mask)
	if _rock_override_delta != null:
		generator.rock_override_delta_texture = ImageTexture.create_from_image(_rock_override_delta)
	generator.target_height_extension = target_height_extension
	generator.rock_overlap = rock_overlap
	generator.rock_assets = _cached_assets
	add_child(generator)

	var t0 := Time.get_ticks_msec()
	var results := _generate_cliff_placements(generator, num_iterations)
	var elapsed := Time.get_ticks_msec() - t0
	print("[MeshFill] Step %d: %d placements in %dms" % [_step_count, results.size(), elapsed])

	_raw_target_height_image = generator._debug_target_height_image
	_raw_current_height_image = generator._debug_current_height_image

	for i in range(results.size()):
		var r: Dictionary = results[i]
		var mesh_index := int(r.mesh_index)
		var asset := _cached_assets[mesh_index]
		var mi := _instantiate_rock_asset(asset)
		var visual_scale: Vector3 = Vector3.ONE * r.scale * fbx_unit_scale * mesh_height_scale
		var mesh_aabb := asset.mesh.get_aabb()
		var mesh_top_y := (mesh_aabb.position.y + mesh_aabb.size.y) * visual_scale.y
		var rock_position: Vector3 = r.position
		rock_position.y -= mesh_top_y
		AutoAssetFactory.configure_rock_instance(mi, asset, {
			"name": "Cliff_s%d_%d_m%d" % [_step_count, i, mesh_index],
			"position": rock_position,
			"rotation_mode": str(r.get("rotation_mode", "Y")),
			"rotation_degrees": r.get("rotation_degrees", Vector3(0.0, float(r.get("rotation_y", 0.0)), 0.0)),
			"scale": visual_scale,
			"visual_layer": ROCK_VISUAL_LAYER,
			"mesh_index": mesh_index,
			"auto_source": "meshfill",
			"groups": [TEST_ONLY_GROUP, TEST_ONLY_ROCK_GROUP],
		})
		_add_level_child(mi)
		_mark_test_only_generated(mi, "rock")
		var rock_record := _mark_test_only_record(_make_cliff_voxel_record(mi.name, r, mi, mesh_aabb, asset), "rock")
		_attach_mesh_voxel_record(mi, rock_record)
		if i < 3:
			print("  [%d] pos=%s aabb_top=%.2f offset_y=%.2f" % [i, r.position, mesh_aabb.position.y + mesh_aabb.size.y, mesh_top_y])

	_capture_and_save_rock_mask()
	_analyze_height_difference(_cached_textures["scene_depth"])
	_save_height_maps()

	if _debug_terrain != null:
		_debug_terrain.queue_free()
		_debug_terrain = null
	if _debug_diff_terrain != null:
		_debug_diff_terrain.queue_free()
		_debug_diff_terrain = null
	_setup_debug_terrain()

	generator.queue_free()
	print("[MeshFill] Step %d complete. Total cliff meshes: %d. Use TEST ONLY C or the UI rock button for next step." % [
		_step_count, get_tree().get_nodes_in_group("placed_rocks").size()])


func _clear_rock_mask() -> void:
	var mask_path := OS.get_user_data_dir() + "/rock_placement_mask.png"
	if FileAccess.file_exists(mask_path):
		DirAccess.remove_absolute(mask_path)
		print("[MeshFill] Cleared previous rock mask")


func _setup_debug_terrain() -> void:
	if _raw_target_height_image == null or _raw_current_height_image == null:
		return

	var img := _raw_target_height_image
	var mask_img := _raw_current_height_image
	var res := img.get_width()
	var cell_size := capture_size / float(res)
	var half := capture_size / 2.0

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	for y in range(res):
		for x in range(res):
			var h := img.get_pixelv(Vector2i(x, y)).r + 0.15
			var gen_mask := mask_img.get_pixelv(Vector2i(x, y)).b
			var alpha := 0.4 if gen_mask > 0.5 else 0.02
			var px := float(x) * cell_size - half
			var pz := float(y) * cell_size - half
			st.set_color(Color(0.2, 0.6, 1.0, alpha))
			st.set_uv(Vector2(float(x) / float(res - 1), float(y) / float(res - 1)))
			st.add_vertex(Vector3(px, h, pz))

	for y in range(res - 1):
		for x in range(res - 1):
			var i := y * res + x
			st.add_index(i)
			st.add_index(i + res)
			st.add_index(i + 1)
			st.add_index(i + 1)
			st.add_index(i + res)
			st.add_index(i + res + 1)

	st.generate_normals()

	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true

	_debug_terrain = MeshInstance3D.new()
	_debug_terrain.mesh = st.commit()
	_debug_terrain.material_override = mat
	_debug_terrain.name = "DebugTargetHeight"
	_debug_terrain.visible = false
	_add_level_child(_debug_terrain)
	print("[MeshFill] Debug target height terrain ready [G to toggle]")


func _setup_slider_ui() -> void:
	if not enable_test_generation_tools:
		return

	var layer := CanvasLayer.new()
	layer.layer = 100
	add_child(layer)

	var panel := PanelContainer.new()
	panel.position = Vector2(10, 10)
	layer.add_child(panel)

	var vbox := VBoxContainer.new()
	panel.add_child(vbox)

	_slider_label = Label.new()
	_slider_label.text = "Target Height Extension: %.1fm" % target_height_extension
	vbox.add_child(_slider_label)

	var slider := HSlider.new()
	slider.min_value = 0.5
	slider.max_value = 20.0
	slider.step = 0.5
	slider.value = target_height_extension
	slider.custom_minimum_size = Vector2(300, 20)
	slider.value_changed.connect(_on_extension_changed)
	vbox.add_child(slider)

	_overlap_label = Label.new()
	_overlap_label.text = "Rock Overlap: %.0f%%" % (rock_overlap * 100.0)
	vbox.add_child(_overlap_label)

	var overlap_slider := HSlider.new()
	overlap_slider.min_value = 0.0
	overlap_slider.max_value = 1.0
	overlap_slider.step = 0.05
	overlap_slider.value = rock_overlap
	overlap_slider.custom_minimum_size = Vector2(300, 20)
	overlap_slider.value_changed.connect(_on_overlap_changed)
	vbox.add_child(overlap_slider)

	_probe_density_label = Label.new()
	_probe_density_label.text = "Semantic Probe Density: %.1fx" % semantic_probe_density
	vbox.add_child(_probe_density_label)

	var probe_slider := HSlider.new()
	probe_slider.min_value = 0.1
	probe_slider.max_value = 8.0
	probe_slider.step = 0.1
	probe_slider.value = semantic_probe_density
	probe_slider.custom_minimum_size = Vector2(300, 20)
	probe_slider.value_changed.connect(_on_probe_density_changed)
	vbox.add_child(probe_slider)

	_probe_debug_label = Label.new()
	_probe_debug_label.text = "Semantic Probes: not shown"
	vbox.add_child(_probe_debug_label)

	var probe_button := Button.new()
	probe_button.text = "Toggle Probe Debug"
	probe_button.pressed.connect(_toggle_semantic_probe_debug)
	vbox.add_child(probe_button)

	var separator := HSeparator.new()
	vbox.add_child(separator)

	var test_label := Label.new()
	test_label.text = "TEST ONLY generation shortcuts"
	vbox.add_child(test_label)

	var shortcut_label := Label.new()
	shortcut_label.text = "C: rock step    P: vegetation"
	vbox.add_child(shortcut_label)

	var rock_button := Button.new()
	rock_button.text = "C  Generate Rock Step"
	rock_button.pressed.connect(_run_test_rock_generation)
	vbox.add_child(rock_button)

	var vegetation_button := Button.new()
	vegetation_button.text = "P  Generate Vegetation"
	vegetation_button.pressed.connect(_run_test_vegetation_generation)
	vbox.add_child(vegetation_button)


func _run_test_rock_generation() -> void:
	if not enable_test_generation_tools:
		return
	_step_generate()


func _run_test_vegetation_generation() -> void:
	if not enable_test_generation_tools:
		return
	_generate_vegetation()


func _on_extension_changed(new_val: float) -> void:
	target_height_extension = new_val
	_slider_label.text = "Target Height Extension: %.1fm" % new_val
	_start_debounce_regen()


func _on_overlap_changed(new_val: float) -> void:
	rock_overlap = new_val
	_overlap_label.text = "Rock Overlap: %.0f%%" % (new_val * 100.0)
	_start_debounce_regen()


func _on_probe_density_changed(new_val: float) -> void:
	semantic_probe_density = clampf(new_val, 0.1, 8.0)
	if _probe_density_label != null:
		_probe_density_label.text = "Semantic Probe Density: %.1fx" % semantic_probe_density
	_apply_semantic_probe_density_to_assets()
	if _debug_probe_root != null and is_instance_valid(_debug_probe_root):
		_refresh_semantic_probe_debug()


func _apply_semantic_probe_density_to_assets() -> void:
	for asset in _cached_assets:
		if asset == null:
			continue
		asset.semantic_probe_density = semantic_probe_density
		asset.rebuild_semantic_probes(semantic_probe_density)
	for asset in _vegetation_assets:
		if asset == null:
			continue
		asset.semantic_probe_density = semantic_probe_density
		asset.get_semantic_probes(semantic_probe_density)
	_update_probe_debug_label()


func _toggle_semantic_probe_debug() -> void:
	if _debug_probe_root != null and is_instance_valid(_debug_probe_root):
		_debug_probe_root.queue_free()
		_debug_probe_root = null
		if _probe_debug_label != null:
			_probe_debug_label.text = "Semantic Probes: hidden"
		print("[MeshFill] Semantic probe debug: OFF")
		return
	_debug_probe_root = Node3D.new()
	_debug_probe_root.name = "DebugSemanticProbes"
	_add_level_child(_debug_probe_root)
	_refresh_semantic_probe_debug()
	print("[MeshFill] Semantic probe debug: ON")


func _refresh_semantic_probe_debug() -> void:
	if _debug_probe_root == null or not is_instance_valid(_debug_probe_root):
		return
	for child in _debug_probe_root.get_children():
		child.queue_free()
	var samples := _collect_semantic_probe_debug_assets(6)
	var total := 0
	var camera := get_viewport().get_camera_3d()
	var center := Vector3(0.0, _terrain_hit_y + 7.0, -4.0)
	var right := Vector3.RIGHT
	if camera != null:
		var camera_basis := camera.global_transform.basis
		center = camera.global_position + (-camera_basis.z.normalized() * 16.0) - (camera_basis.y.normalized() * 1.0)
		right = camera_basis.x.normalized()
	var spacing := 4.0
	var half_width := float(maxi(samples.size() - 1, 0)) * spacing * 0.5
	for i in range(samples.size()):
		var sample: Dictionary = samples[i]
		var probes: Array = sample.get("probes", [])
		var origin := center + right * (float(i) * spacing - half_width)
		var anchor := _make_probe_debug_anchor(origin, sample)
		_debug_probe_root.add_child(anchor)
		var limit := mini(probes.size(), 160)
		var probe_scale := _vector3_from_record_value(sample.get("mesh_scale", Vector3.ONE), Vector3.ONE)
		for j in range(limit):
			var probe: Dictionary = probes[j]
			anchor.add_child(_make_probe_debug_marker(probe, probe_scale))
		total += probes.size()
	if _probe_debug_label != null:
		_probe_debug_label.text = "Semantic Probes: %.1fx, %d assets, %d probes" % [semantic_probe_density, samples.size(), total]
	print("[MeshFill] Semantic probes debug: density=%.1fx assets=%d probes=%d" % [semantic_probe_density, samples.size(), total])


func _collect_semantic_probe_debug_assets(max_assets: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for i in range(_cached_assets.size()):
		if result.size() >= max_assets:
			break
		var asset := _cached_assets[i]
		if asset == null:
			continue
		var probes := asset.rebuild_semantic_probes(semantic_probe_density)
		var probe_mesh := asset.mesh
		var source_mesh := asset.get_source_mesh()
		var debug_scale := _semantic_probe_debug_mesh_scale(probe_mesh, asset.mesh_size)
		var source_mesh_scale := _semantic_probe_debug_mesh_scale(source_mesh, asset.mesh_size)
		result.append({
			"name": asset.asset_id if not asset.asset_id.is_empty() else "rock_%d" % i,
			"mesh": probe_mesh,
			"source_mesh": source_mesh,
			"mesh_scale": Vector3.ONE * debug_scale,
			"source_mesh_scale": Vector3.ONE * source_mesh_scale,
			"color": asset.get_voxel_color(),
			"probes": probes,
		})
	for i in range(_vegetation_assets.size()):
		if result.size() >= max_assets:
			break
		var asset := _vegetation_assets[i]
		if asset == null:
			continue
		var probes := asset.get_semantic_probes(semantic_probe_density)
		var mesh := asset.get_mesh()
		var source_mesh := asset.get_source_mesh()
		var max_axis := _semantic_probe_debug_mesh_max_axis(mesh)
		var target_size := maxf(asset.scatter_max_scale * max_axis, 1.0)
		var mesh_scale := Vector3.ONE * _semantic_probe_debug_mesh_scale(mesh, target_size)
		var source_mesh_scale := Vector3.ONE * _semantic_probe_debug_mesh_scale(source_mesh, target_size)
		result.append({
			"name": asset.asset_id if not asset.asset_id.is_empty() else "vegetation_%d" % i,
			"mesh": mesh,
			"source_mesh": source_mesh,
			"mesh_scale": mesh_scale,
			"source_mesh_scale": source_mesh_scale,
			"color": asset.get_voxel_color(),
			"probes": probes,
		})
	return result


func _semantic_probe_debug_mesh_max_axis(mesh: Mesh) -> float:
	if mesh == null:
		return 0.0
	var aabb := mesh.get_aabb()
	return maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))


func _semantic_probe_debug_mesh_scale(mesh: Mesh, target_size: float) -> float:
	var max_axis := _semantic_probe_debug_mesh_max_axis(mesh)
	if max_axis <= 0.001 or target_size <= 0.001:
		return 1.0
	return target_size / max_axis


func _make_probe_debug_anchor(origin: Vector3, sample: Dictionary) -> Node3D:
	var label_text := str(sample.get("name", "asset"))
	var root := Node3D.new()
	root.name = "ProbeAsset_%s" % label_text
	root.position = origin
	var box := BoxMesh.new()
	box.size = Vector3(0.6, 0.16, 0.6)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 1.0, 0.2, 0.9)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	var marker := MeshInstance3D.new()
	marker.mesh = box
	marker.material_override = mat
	root.add_child(marker)

	var mesh = sample.get("source_mesh", sample.get("mesh", null))
	if mesh is Mesh:
		var mesh_marker := MeshInstance3D.new()
		mesh_marker.name = "SourceMesh"
		mesh_marker.mesh = mesh as Mesh
		mesh_marker.scale = _vector3_from_record_value(sample.get("source_mesh_scale", sample.get("mesh_scale", Vector3.ONE)), Vector3.ONE)
		mesh_marker.material_override = _make_probe_debug_source_mesh_material(sample.get("color", Color(0.55, 0.8, 0.45, 0.45)))
		root.add_child(mesh_marker)

		var convex_shape := (mesh as Mesh).create_convex_shape(true, false)
		if convex_shape != null:
			var convex_wireframe := _make_convex_wireframe_mesh(convex_shape)
			if convex_wireframe != null:
				var convex_marker := MeshInstance3D.new()
				convex_marker.name = "ConvexWireframe"
				convex_marker.mesh = convex_wireframe
				convex_marker.scale = mesh_marker.scale
				convex_marker.material_override = _make_probe_debug_convex_material()
				root.add_child(convex_marker)
	return root


func _make_probe_debug_source_mesh_material(color_value) -> StandardMaterial3D:
	var color := Color(0.55, 0.8, 0.45, 0.45)
	if color_value is Color:
		color = color_value as Color
	color.a = 0.58
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = false
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.emission_enabled = true
	mat.emission = Color(color.r, color.g, color.b, 1.0)
	mat.emission_energy_multiplier = 0.35
	return mat


func _make_probe_debug_convex_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.6, 0.0, 1.0)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = false
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.6, 0.0, 1.0)
	mat.emission_energy_multiplier = 1.5
	return mat


func _make_convex_wireframe_mesh(convex_shape: ConvexPolygonShape3D) -> ImmediateMesh:
	var debug_mesh := convex_shape.get_debug_mesh()
	if debug_mesh == null:
		return null
	var edges := {}
	for si in range(debug_mesh.get_surface_count()):
		var arrays := debug_mesh.surface_get_arrays(si)
		if arrays.is_empty() or arrays[Mesh.ARRAY_VERTEX] == null:
			continue
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		if indices.is_empty():
			for i in range(0, verts.size(), 3):
				if i + 2 >= verts.size():
					break
				_add_edge(edges, verts[i], verts[i + 1])
				_add_edge(edges, verts[i + 1], verts[i + 2])
				_add_edge(edges, verts[i + 2], verts[i])
		else:
			for i in range(0, indices.size(), 3):
				if i + 2 >= indices.size():
					break
				_add_edge(edges, verts[indices[i]], verts[indices[i + 1]])
				_add_edge(edges, verts[indices[i + 1]], verts[indices[i + 2]])
				_add_edge(edges, verts[indices[i + 2]], verts[indices[i]])
	if edges.is_empty():
		return null
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for edge_key in edges:
		var edge: Array = edges[edge_key]
		im.surface_add_vertex(edge[0])
		im.surface_add_vertex(edge[1])
	im.surface_end()
	return im


func _add_edge(edges: Dictionary, a: Vector3, b: Vector3) -> void:
	var ka := "%d,%d,%d" % [roundi(a.x * 100.0), roundi(a.y * 100.0), roundi(a.z * 100.0)]
	var kb := "%d,%d,%d" % [roundi(b.x * 100.0), roundi(b.y * 100.0), roundi(b.z * 100.0)]
	var key := ka + "|" + kb if ka < kb else kb + "|" + ka
	if not edges.has(key):
		edges[key] = [a, b]


func _make_probe_debug_marker(probe: Dictionary, offset_scale: Vector3 = Vector3.ONE) -> MeshInstance3D:
	var color: Color = probe.get("expected_color", Color.WHITE)
	var flags := int(probe.get("flags", 0))
	var shape_source := str(probe.get("shape_source", ""))
	if (flags & SemanticProbeProfileScript.FLAG_COLLISION) != 0:
		color = Color(1.0, 0.35, 0.2, 1.0)
	elif (flags & SemanticProbeProfileScript.FLAG_EMPTY) != 0:
		color = Color(0.2, 0.4, 1.0, 1.0)
	color.a = 0.95
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 1.5
	var marker_mesh: Mesh
	if shape_source == "convex":
		marker_mesh = _make_probe_debug_wire_sphere_mesh(0.28)
		mat.albedo_color = Color(1.0, 0.85, 0.1, 1.0)
		mat.emission = mat.albedo_color
		mat.emission_energy_multiplier = 2.4
	elif shape_source == "voxel_interior":
		marker_mesh = _make_probe_debug_wire_sphere_mesh(0.2)
		mat.albedo_color = Color(0.2, 0.8, 1.0, 1.0)
		mat.emission = mat.albedo_color
		mat.emission_energy_multiplier = 2.0
	elif shape_source == "surface":
		var mesh := SphereMesh.new()
		mesh.radius = 0.16
		mesh.height = 0.32
		marker_mesh = mesh
		mat.albedo_color = Color(0.4, 1.0, 0.4, 0.8)
		mat.emission = mat.albedo_color
		mat.emission_energy_multiplier = 1.0
	else:
		var mesh := SphereMesh.new()
		mesh.radius = 0.22
		mesh.height = 0.44
		marker_mesh = mesh
	var marker := MeshInstance3D.new()
	if shape_source == "convex" or shape_source == "voxel_interior":
		marker.name = "WireProbe_%s" % shape_source
		marker.set_meta("semantic_probe_wireframe", true)
	marker.mesh = marker_mesh
	marker.material_override = mat
	marker.position = SemanticProbeProfileScript.vector3_from_value(probe.get("offset", Vector3.ZERO), Vector3.ZERO) * offset_scale
	return marker


func _make_probe_debug_wire_sphere_mesh(radius: float) -> ImmediateMesh:
	var mesh := ImmediateMesh.new()
	var segments := 24
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in range(segments):
		var a0 := TAU * float(i) / float(segments)
		var a1 := TAU * float(i + 1) / float(segments)
		mesh.surface_add_vertex(Vector3(cos(a0) * radius, sin(a0) * radius, 0.0))
		mesh.surface_add_vertex(Vector3(cos(a1) * radius, sin(a1) * radius, 0.0))
		mesh.surface_add_vertex(Vector3(cos(a0) * radius, 0.0, sin(a0) * radius))
		mesh.surface_add_vertex(Vector3(cos(a1) * radius, 0.0, sin(a1) * radius))
		mesh.surface_add_vertex(Vector3(0.0, cos(a0) * radius, sin(a0) * radius))
		mesh.surface_add_vertex(Vector3(0.0, cos(a1) * radius, sin(a1) * radius))
	mesh.surface_end()
	return mesh


func _update_probe_debug_label() -> void:
	if _probe_debug_label == null:
		return
	var total := 0
	for asset in _cached_assets:
		if asset != null:
			total += asset.get_semantic_probes(semantic_probe_density).size()
	for asset in _vegetation_assets:
		if asset != null:
			total += asset.get_semantic_probes(semantic_probe_density).size()
	_probe_debug_label.text = "Semantic Probes: %.1fx, %d assets, %d probes" % [
		semantic_probe_density,
		_cached_assets.size() + _vegetation_assets.size(),
		total,
	]


func _start_debounce_regen() -> void:
	if _debounce_timer == null:
		_debounce_timer = Timer.new()
		_debounce_timer.one_shot = true
		_debounce_timer.wait_time = 0.5
		_debounce_timer.timeout.connect(_regenerate)
		add_child(_debounce_timer)
	_debounce_timer.start()


func _regenerate() -> void:
	for child in _get_level_children():
		if child.name.begins_with("Cliff_") or child.name == "DebugTargetHeight" or child.name == "DebugDiffHeight" or child.name == "DebugCombinedMask" or child.name == "DebugSemanticProbes" or child.name == "DebugTargetSceneVoxel" or child.name == "Terrain":
			_remove_mesh_voxel_record(child)
			child.queue_free()
	_debug_terrain = null
	_debug_diff_terrain = null
	_debug_mask_terrain = null
	_debug_probe_root = null
	_target_sv_debug_terrain = null
	_debug_showing = false
	_debug_diff_showing = false
	_target_sv_debug_showing = false
	_step_count = 0
	_raw_target_height_image = null
	_raw_current_height_image = null
	_clear_rock_mask()
	_invalidate_overrides()
	var final_terrain_tex := _composite_target_height()
	_terrain_hit_y = _compute_terrain_avg_height(final_terrain_tex)
	_create_terrain_mesh(final_terrain_tex)
	print("[MeshFill] Regenerating with extension=%.1fm overlap=%.0f%%..." % [target_height_extension, rock_overlap * 100.0])
	_step_generate()


func _toggle_debug_overlay() -> void:
	if _debug_terrain != null:
		_debug_terrain.queue_free()
		_debug_terrain = null
		_debug_showing = false
		print("[MeshFill] Target height debug: OFF (removed)")
		return
	if _raw_target_height_image != null and _raw_current_height_image != null:
		_setup_debug_terrain()
		if _debug_terrain != null:
			_debug_terrain.visible = true
			_debug_showing = true
			print("[MeshFill] Target height debug: ON")
	else:
		print("[MeshFill] No height data available. Use TEST ONLY C or the UI rock button first.")


func _toggle_diff_overlay() -> void:
	if _debug_diff_terrain != null:
		_debug_diff_terrain.queue_free()
		_debug_diff_terrain = null
		_debug_diff_showing = false
		print("[MeshFill] Height diff debug: OFF (removed)")
		return
	if _raw_target_height_image != null and _raw_current_height_image != null:
		_setup_diff_terrain(_raw_target_height_image, _raw_current_height_image)
		if _debug_diff_terrain != null:
			_debug_diff_terrain.visible = true
			_debug_diff_showing = true
			print("[MeshFill] Height diff debug: ON")
	else:
		print("[MeshFill] No height data available. Use TEST ONLY C or the UI rock button first.")


func _generate() -> void:
	print("[MeshFill] Starting generation...")

	var textures := _load_terrain_textures()
	if textures.is_empty():
		push_error("[MeshFill] Fatal: failed to obtain terrain textures")
		return

	var cliff_meshes: Array[Mesh] = []
	var assets: Array[AutoRock] = []
	_load_cliff_data(cliff_meshes, assets)
	if assets.is_empty():
		push_error("[MeshFill] Fatal: no cliff assets available")
		return
	for mi_idx in range(cliff_meshes.size()):
		var aabb := cliff_meshes[mi_idx].get_aabb()
		print("[MeshFill] Mesh %d AABB: pos=%s size=%s (Y-up: %.2f ~ %.2f)" % [
			mi_idx, aabb.position, aabb.size,
			aabb.position.y, aabb.position.y + aabb.size.y])

	var prev_rock_mask := _load_previous_rock_mask()

	print("[MeshFill] Creating generator (iter=%d, capture=%.0fm)..." % [
		num_iterations, capture_size])
	var generator := CliffGenerator.new()
	generator.texture_size = TEX_RES
	generator.capture_size = capture_size
	generator.max_height = max_height
	generator.generate_threshold = generate_threshold
	generator.un_generate_threshold = un_generate_threshold
	generator.scene_depth_texture = textures["scene_depth"]
	generator.scene_normal_texture = textures["scene_normal"]
	generator.object_depth_texture = textures["object_depth"]
	generator.object_normal_texture = textures["object_normal"]
	generator.height_normal_texture = textures["height_normal"]
	generator.target_height_texture = textures["target_height"]
	generator.rock_mask_texture = prev_rock_mask
	generator.target_height_extension = target_height_extension
	generator.rock_overlap = rock_overlap
	generator.rock_assets = assets
	add_child(generator)

	print("[MeshFill] Running compute shaders...")
	var t0 := Time.get_ticks_msec()
	var results := _generate_cliff_placements(generator, num_iterations)
	var elapsed := Time.get_ticks_msec() - t0
	print("[MeshFill] Generated %d placements in %dms" % [results.size(), elapsed])

	_raw_target_height_image = generator._debug_target_height_image
	_raw_current_height_image = generator._debug_current_height_image

	for i in range(results.size()):
		var r: Dictionary = results[i]
		var mesh_index := int(r.mesh_index)
		var asset := assets[mesh_index]
		var mi := _instantiate_rock_asset(asset)
		var visual_scale: Vector3 = Vector3.ONE * r.scale * fbx_unit_scale * mesh_height_scale
		var mesh_aabb := asset.mesh.get_aabb()
		var mesh_top_y := (mesh_aabb.position.y + mesh_aabb.size.y) * visual_scale.y
		var rock_position: Vector3 = r.position
		rock_position.y -= mesh_top_y
		AutoAssetFactory.configure_rock_instance(mi, asset, {
			"name": "Cliff_%d_m%d" % [i, mesh_index],
			"position": rock_position,
			"rotation_mode": str(r.get("rotation_mode", "Y")),
			"rotation_degrees": r.get("rotation_degrees", Vector3(0.0, float(r.get("rotation_y", 0.0)), 0.0)),
			"scale": visual_scale,
			"visual_layer": ROCK_VISUAL_LAYER,
			"mesh_index": mesh_index,
			"auto_source": "meshfill",
			"groups": [TEST_ONLY_GROUP, TEST_ONLY_ROCK_GROUP],
		})
		_add_level_child(mi)
		_mark_test_only_generated(mi, "rock")
		var rock_record := _mark_test_only_record(_make_cliff_voxel_record(mi.name, r, mi, mesh_aabb, asset), "rock")
		_attach_mesh_voxel_record(mi, rock_record)
		if i < 5:
			print("  [%d] pos=%s rot=%.1f掳 scale=%.3f mesh=%d top_offset=%.2f" % [
				i, r.position, r.rotation_y, mi.scale.x, r.mesh_index, mesh_top_y])

	if _raw_target_height_image != null:
		var h_min := 9999.0
		var h_max := -9999.0
		for y in range(_raw_target_height_image.get_height()):
			for x in range(_raw_target_height_image.get_width()):
				var v := _raw_target_height_image.get_pixelv(Vector2i(x, y)).r
				h_min = minf(h_min, v)
				h_max = maxf(h_max, v)
		print("[MeshFill] Target height range: %.1f - %.1f" % [h_min, h_max])

	_analyze_height_difference(textures["scene_depth"])
	_save_height_maps()

	generator.queue_free()
	print("[MeshFill] Done! Placed %d cliff meshes." % results.size())

	_capture_and_save_rock_mask()
	_create_terrain_mesh(textures["target_height"])


func _clamp_rock_visual_height(mi: MeshInstance3D) -> void:
	if _raw_target_height_image == null:
		return
	var aabb := mi.mesh.get_aabb()
	# After -90掳 X rotation + Y rotation, local Z maps to world Y
	# mi.scale.z controls the vertical extent in world space
	var mesh_top_z := aabb.position.z + aabb.size.z
	if mesh_top_z < 0.001:
		return
	var peak_world_y := mi.position.y + mesh_top_z * mi.scale.z

	var uv_x := clampf((mi.position.x + capture_size * 0.5) / capture_size, 0.0, 1.0)
	var uv_z := clampf((mi.position.z + capture_size * 0.5) / capture_size, 0.0, 1.0)
	var px := Vector2i(
		clampi(int(uv_x * float(TEX_RES)), 0, TEX_RES - 1),
		clampi(int(uv_z * float(TEX_RES)), 0, TEX_RES - 1))
	var target_h := _raw_target_height_image.get_pixelv(px).r

	if target_h > 0.01 and peak_world_y > target_h:
		var allowed := maxf(target_h - mi.position.y, 0.01)
		mi.scale.z = allowed / mesh_top_z


# 鈹€鈹€鈹€ Height analysis & export 鈹€鈹€鈹€

func _analyze_height_difference(scene_depth_tex: ImageTexture) -> void:
	if _raw_target_height_image == null or _raw_current_height_image == null:
		print("[MeshFill] Cannot analyze: missing height images")
		return

	var scene_depth_img := scene_depth_tex.get_image()
	var res := _raw_target_height_image.get_width()

	var total_gen := 0
	var already_above := 0
	var filled_ok := 0
	var still_under := 0
	var rock_overshoot := 0
	var sum_sq_err := 0.0
	var sum_abs_err := 0.0
	var max_err := 0.0
	var sum_sq_fillable := 0.0
	var sum_abs_fillable := 0.0
	var fillable_count := 0
	var sum_rock_added := 0.0
	var rock_added_count := 0

	for y in range(res):
		for x in range(res):
			var gen_mask := _raw_current_height_image.get_pixelv(Vector2i(x, y)).b
			if gen_mask < 0.5:
				continue
			total_gen += 1

			var target_h := _raw_target_height_image.get_pixelv(Vector2i(x, y)).r
			var current_h := _raw_current_height_image.get_pixelv(Vector2i(x, y)).r
			var initial_h := max_height - scene_depth_img.get_pixelv(Vector2i(x, y)).r
			var diff := current_h - target_h

			sum_sq_err += diff * diff
			sum_abs_err += absf(diff)
			max_err = maxf(max_err, absf(diff))

			if initial_h > target_h + 0.5:
				already_above += 1
			else:
				fillable_count += 1
				var fillable_diff := current_h - target_h
				sum_sq_fillable += fillable_diff * fillable_diff
				sum_abs_fillable += absf(fillable_diff)
				if absf(fillable_diff) < 0.5:
					filled_ok += 1
				elif fillable_diff < -0.5:
					still_under += 1
				else:
					rock_overshoot += 1

			var rock_h := current_h - initial_h
			if rock_h > 0.1:
				sum_rock_added += rock_h
				rock_added_count += 1

	if total_gen == 0:
		print("[MeshFill] No generate-mask pixels to analyze")
		return

	var rmse := sqrt(sum_sq_err / float(total_gen))
	var mae := sum_abs_err / float(total_gen)

	print("[MeshFill] Height Difference Analysis")
	print("[MeshFill]   Generate-mask pixels: %d / %d" % [total_gen, res * res])
	print("[MeshFill]   Overall RMSE: %.3f m | MAE: %.3f m | Max: %.3f m" % [rmse, mae, max_err])
	print("[MeshFill] 鈹€鈹€鈹€ Breakdown 鈹€鈹€鈹€")
	print("[MeshFill]   Terrain already above target: %d (%.1f%%)" % [already_above, float(already_above) / float(total_gen) * 100.0])

	if fillable_count > 0:
		var fill_rmse := sqrt(sum_sq_fillable / float(fillable_count))
		var fill_mae := sum_abs_fillable / float(fillable_count)
		print("[MeshFill]   Fillable pixels: %d (%.1f%%)" % [fillable_count, float(fillable_count) / float(total_gen) * 100.0])
		print("[MeshFill]     Fillable RMSE: %.3f m | MAE: %.3f m" % [fill_rmse, fill_mae])
		print("[MeshFill]     Filled OK (|diff| < 0.5m): %d (%.1f%%)" % [filled_ok, float(filled_ok) / float(fillable_count) * 100.0])
		print("[MeshFill]     Still under-filled:        %d (%.1f%%)" % [still_under, float(still_under) / float(fillable_count) * 100.0])
		print("[MeshFill]     Rock overshoot:            %d (%.1f%%)" % [rock_overshoot, float(rock_overshoot) / float(fillable_count) * 100.0])

	if rock_added_count > 0:
		print("[MeshFill]   Avg rock height added: %.3f m (%d pixels with rocks)" % [sum_rock_added / float(rock_added_count), rock_added_count])


func _save_height_maps() -> void:
	var out_dir := OS.get_user_data_dir()

	if _raw_target_height_image != null:
		var target_vis := _height_to_grayscale(_raw_target_height_image, 0)
		target_vis.save_png(out_dir + "/target_height.png")
		print("[MeshFill] Saved: %s/target_height.png" % out_dir)

	if _raw_current_height_image != null:
		var current_vis := _height_to_grayscale(_raw_current_height_image, 0)
		current_vis.save_png(out_dir + "/current_height.png")
		print("[MeshFill] Saved: %s/current_height.png" % out_dir)

	if _raw_target_height_image != null and _raw_current_height_image != null:
		var diff_vis := _height_diff_to_color(_raw_target_height_image, _raw_current_height_image)
		diff_vis.save_png(out_dir + "/height_diff.png")
		print("[MeshFill] Saved: %s/height_diff.png" % out_dir)
		_setup_diff_terrain(_raw_target_height_image, _raw_current_height_image)


func _target_sv_dir_absolute() -> String:
	return OS.get_user_data_dir() + "/" + TARGET_SV_DIR_NAME


func _target_sv_meta_path() -> String:
	return _target_sv_dir_absolute() + "/target_scene_voxel.json"


func _target_sv_preview_path() -> String:
	return _target_sv_dir_absolute() + "/target_scene_voxel_preview.png"


func _target_sv_visual_path() -> String:
	return _target_sv_dir_absolute() + "/target_scene_voxel_visual.rgba32f"


func _target_sv_collision_path() -> String:
	return _target_sv_dir_absolute() + "/target_scene_voxel_collision.r32f"


func _write_target_sv_buffer(path: String, bytes: PackedByteArray) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("[TargetSV] Failed to open for write: %s" % path)
		return false
	file.store_buffer(bytes)
	file.close()
	return true


func _read_target_sv_buffer(path: String) -> PackedByteArray:
	var bytes := PackedByteArray()
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("[TargetSV] Failed to open persistent buffer: %s" % path)
		return bytes
	bytes = file.get_buffer(file.get_length())
	file.close()
	return bytes


func _save_target_scene_voxel(result: Dictionary) -> bool:
	var out_dir := _target_sv_dir_absolute()
	DirAccess.make_dir_recursive_absolute(out_dir)
	var visual_bytes: PackedByteArray = result.get("visual_bytes", PackedByteArray())
	var collision_bytes: PackedByteArray = result.get("collision_bytes", PackedByteArray())
	var preview_img: Image = result.get("preview_image", null)
	if preview_img == null or visual_bytes.is_empty() or collision_bytes.is_empty():
		push_error("[TargetSV] Save failed: incomplete TargetSV result")
		return false
	if not _write_target_sv_buffer(_target_sv_visual_path(), visual_bytes):
		return false
	if not _write_target_sv_buffer(_target_sv_collision_path(), collision_bytes):
		return false
	_target_sv_visual_bytes = visual_bytes
	_target_sv_collision_bytes = collision_bytes
	var preview_png := preview_img.duplicate()
	if preview_png.get_format() != Image.FORMAT_RGBA8:
		preview_png.convert(Image.FORMAT_RGBA8)
	preview_png.save_png(_target_sv_preview_path())
	_target_sv_metadata = {
		"version": 1,
		"created_unix": Time.get_unix_time_from_system(),
		"texture_size": int(result.get("texture_size", TEX_RES)),
		"slice_count": int(result.get("slice_count", TARGET_SV_SLICE_COUNT)),
		"voxel_count": int(result.get("voxel_count", TEX_RES * TEX_RES * TARGET_SV_SLICE_COUNT)),
		"max_height": float(result.get("max_height", max_height)),
		"capture_size": float(result.get("capture_size", capture_size)),
		"vertical_span": float(result.get("vertical_span", TARGET_SV_VERTICAL_SPAN)),
		"visual_format": str(result.get("visual_format", "rgba32f")),
		"collision_format": str(result.get("collision_format", "r32f")),
		"visual_path": _target_sv_visual_path(),
		"collision_path": _target_sv_collision_path(),
		"preview_path": _target_sv_preview_path(),
		"generator": "TargetSceneVoxelGenerator",
		"gpu_only_generation": true,
	}
	var meta_file := FileAccess.open(_target_sv_meta_path(), FileAccess.WRITE)
	if meta_file == null:
		push_error("[TargetSV] Failed to write metadata: %s" % _target_sv_meta_path())
		return false
	meta_file.store_string(JSON.stringify(_target_sv_metadata, "\t"))
	meta_file.close()
	print("[TargetSV] Saved persistent TargetSV: %s" % out_dir)
	return true


func _load_persisted_target_scene_voxel() -> bool:
	var preview_path := _target_sv_preview_path()
	if not FileAccess.file_exists(preview_path):
		return false
	var preview_img := Image.load_from_file(preview_path)
	if preview_img == null:
		push_warning("[TargetSV] Failed to load preview: %s" % preview_path)
		return false
	_target_sv_preview_image = preview_img
	_target_sv_metadata = {}
	var meta_path := _target_sv_meta_path()
	if FileAccess.file_exists(meta_path):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(meta_path))
		if parsed is Dictionary:
			_target_sv_metadata = parsed as Dictionary
	_target_sv_visual_bytes = _read_target_sv_buffer(_target_sv_visual_path())
	_target_sv_collision_bytes = _read_target_sv_buffer(_target_sv_collision_path())
	var tex_size := int(_target_sv_metadata.get("texture_size", preview_img.get_width()))
	var slice_count := int(_target_sv_metadata.get("slice_count", TARGET_SV_SLICE_COUNT))
	var voxel_count := tex_size * tex_size * slice_count
	if _target_sv_visual_bytes.size() != voxel_count * 16:
		push_warning("[TargetSV] Persistent visual buffer size mismatch: got %d expected %d" % [_target_sv_visual_bytes.size(), voxel_count * 16])
	if _target_sv_collision_bytes.size() != voxel_count * 4:
		push_warning("[TargetSV] Persistent collision buffer size mismatch: got %d expected %d" % [_target_sv_collision_bytes.size(), voxel_count * 4])
	print("[TargetSV] Loaded persistent TargetSV: %s" % preview_path)
	return true


func _recompute_and_save_target_scene_voxel() -> void:
	if _cached_textures.is_empty():
		push_error("[TargetSV] Cannot recompute: terrain textures are not loaded")
		return
	var scene_depth_tex := _cached_textures.get("scene_depth", null) as ImageTexture
	var target_height_base := _cached_textures.get("target_height", null) as ImageTexture
	if scene_depth_tex == null or target_height_base == null:
		push_error("[TargetSV] Cannot recompute: missing scene_depth or target_height texture")
		return
	var target_height_tex := _composite_target_height()
	var rock_mask_img: Image = _current_rock_mask_img
	if rock_mask_img == null:
		rock_mask_img = Image.create(TEX_RES, TEX_RES, false, Image.FORMAT_RF)
		rock_mask_img.fill(Color(0.0, 0.0, 0.0, 0.0))
	var generator := TargetSceneVoxelGenerator.new()
	generator.texture_size = TEX_RES
	generator.slice_count = TARGET_SV_SLICE_COUNT
	generator.max_height = max_height
	generator.capture_size = capture_size
	generator.vertical_span = TARGET_SV_VERTICAL_SPAN
	generator.slope_start = landscape_cliff_slope_start
	generator.slope_full = landscape_cliff_slope_full
	print("[TargetSV] Recomputing full TargetSV on GPU...")
	var t0 := Time.get_ticks_msec()
	var result := generator.generate(
		scene_depth_tex.get_image(),
		target_height_tex.get_image(),
		rock_mask_img,
		Rect2i(0, 0, TEX_RES, TEX_RES)
	)
	if result.is_empty():
		push_error("[TargetSV] GPU recompute failed")
		return
	_target_sv_preview_image = result.get("preview_image", null)
	var saved := _save_target_scene_voxel(result)
	var elapsed := Time.get_ticks_msec() - t0
	if saved:
		print("[TargetSV] Full GPU recompute + save complete in %dms" % elapsed)
	if _target_sv_debug_showing:
		_build_target_scene_voxel_overlay()
		if _target_sv_debug_terrain != null:
			_target_sv_debug_terrain.visible = true
			_target_sv_debug_showing = true


func _build_target_scene_voxel_overlay() -> void:
	if _target_sv_debug_terrain != null:
		_target_sv_debug_terrain.queue_free()
		_target_sv_debug_terrain = null
	if _target_sv_preview_image == null:
		return
	if _cached_textures.is_empty():
		return
	var depth_img: Image = (_cached_textures["scene_depth"] as ImageTexture).get_image()
	var img := _target_sv_preview_image
	var res := img.get_width()
	var cell_size := capture_size / float(res)
	var half := capture_size / 2.0
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for y in range(res):
		for x in range(res):
			var px := Vector2i(x, y)
			var depth_px := Vector2i(
				clampi(int(float(x) / float(maxi(res - 1, 1)) * float(depth_img.get_width() - 1)), 0, depth_img.get_width() - 1),
				clampi(int(float(y) / float(maxi(res - 1, 1)) * float(depth_img.get_height() - 1)), 0, depth_img.get_height() - 1)
			)
			var h := max_height - depth_img.get_pixelv(depth_px).r + 0.45
			var c := img.get_pixelv(px)
			var signal := clampf(maxf(c.a, maxf(c.r, maxf(c.g, c.b))), 0.0, 1.0)
			var alpha := 0.7 * signal if signal > 0.01 else 0.0
			st.set_color(Color(c.r, c.g, c.b, alpha))
			st.set_uv(Vector2(float(x) / float(maxi(res - 1, 1)), float(y) / float(maxi(res - 1, 1))))
			st.add_vertex(Vector3(float(x) * cell_size - half, h, float(y) * cell_size - half))
	for y in range(res - 1):
		for x in range(res - 1):
			var i := y * res + x
			st.add_index(i)
			st.add_index(i + res)
			st.add_index(i + 1)
			st.add_index(i + 1)
			st.add_index(i + res)
			st.add_index(i + res + 1)
	st.generate_normals()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	_target_sv_debug_terrain = MeshInstance3D.new()
	_target_sv_debug_terrain.mesh = st.commit()
	_target_sv_debug_terrain.material_override = mat
	_target_sv_debug_terrain.name = "DebugTargetSceneVoxel"
	_target_sv_debug_terrain.visible = false
	_add_level_child(_target_sv_debug_terrain)
	print("[TargetSV] TargetSV overlay ready [J to toggle]")


func _toggle_target_scene_voxel_overlay() -> void:
	if _target_sv_debug_terrain != null:
		_target_sv_debug_terrain.queue_free()
		_target_sv_debug_terrain = null
		_target_sv_debug_showing = false
		print("[TargetSV] TargetSV overlay: OFF")
		return
	if _target_sv_preview_image == null:
		_load_persisted_target_scene_voxel()
	if _target_sv_preview_image == null:
		print("[TargetSV] No persisted TargetSV found. Press Ctrl+J to recompute and save it.")
		return
	_build_target_scene_voxel_overlay()
	if _target_sv_debug_terrain != null:
		_target_sv_debug_terrain.visible = true
		_target_sv_debug_showing = true
		print("[TargetSV] TargetSV overlay: ON")


func _height_to_grayscale(img: Image, channel: int) -> Image:
	var res := img.get_width()
	var h_min := 9999.0
	var h_max := -9999.0
	for y in range(res):
		for x in range(res):
			var px := img.get_pixelv(Vector2i(x, y))
			var v: float = px[channel]
			h_min = minf(h_min, v)
			h_max = maxf(h_max, v)

	var out := Image.create(res, res, false, Image.FORMAT_RGBA8)
	var range_val := maxf(h_max - h_min, 0.001)
	for y in range(res):
		for x in range(res):
			var px := img.get_pixelv(Vector2i(x, y))
			var v: float = px[channel]
			var t := clampf((v - h_min) / range_val, 0.0, 1.0)
			out.set_pixelv(Vector2i(x, y), Color(t, t, t, 1.0))
	return out


func _height_diff_to_color(target_img: Image, current_img: Image) -> Image:
	var res := target_img.get_width()
	var out := Image.create(res, res, false, Image.FORMAT_RGBA8)
	for y in range(res):
		for x in range(res):
			var target_h := target_img.get_pixelv(Vector2i(x, y)).r
			var current_h := current_img.get_pixelv(Vector2i(x, y)).r
			var gen_mask := current_img.get_pixelv(Vector2i(x, y)).b
			if gen_mask < 0.5:
				out.set_pixelv(Vector2i(x, y), Color(0.2, 0.2, 0.2, 1.0))
				continue
			var diff := current_h - target_h
			var t := clampf(absf(diff) / 5.0, 0.0, 1.0)
			var c: Color
			if diff < 0.0:
				c = Color(0.0, 0.0, t, 1.0)
			else:
				c = Color(t, 0.0, 0.0, 1.0)
			out.set_pixelv(Vector2i(x, y), c)
	return out


func _setup_diff_terrain(target_img: Image, current_img: Image) -> void:
	var res := target_img.get_width()
	var cell_size := capture_size / float(res)
	var half := capture_size / 2.0

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	for y in range(res):
		for x in range(res):
			var target_h := target_img.get_pixelv(Vector2i(x, y)).r
			var current_h := current_img.get_pixelv(Vector2i(x, y)).r
			var gen_mask := current_img.get_pixelv(Vector2i(x, y)).b
			var display_h := maxf(target_h, current_h) + 0.3
			var diff := current_h - target_h
			var t := clampf(absf(diff) / 5.0, 0.0, 1.0)
			var c: Color
			if gen_mask < 0.5:
				c = Color(0.3, 0.3, 0.3, 0.15)
			elif diff < -0.5:
				c = Color(0.0, 0.2, 1.0, 0.3 + t * 0.5)
			elif diff > 0.5:
				c = Color(1.0, 0.1, 0.0, 0.3 + t * 0.5)
			else:
				c = Color(0.0, 1.0, 0.2, 0.25)

			var px := float(x) * cell_size - half
			var pz := float(y) * cell_size - half
			st.set_color(c)
			st.set_uv(Vector2(float(x) / float(res - 1), float(y) / float(res - 1)))
			st.add_vertex(Vector3(px, display_h, pz))

	for y in range(res - 1):
		for x in range(res - 1):
			var i := y * res + x
			st.add_index(i)
			st.add_index(i + res)
			st.add_index(i + 1)
			st.add_index(i + 1)
			st.add_index(i + res)
			st.add_index(i + res + 1)

	st.generate_normals()

	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	_debug_diff_terrain = MeshInstance3D.new()
	_debug_diff_terrain.mesh = st.commit()
	_debug_diff_terrain.material_override = mat
	_debug_diff_terrain.name = "DebugHeightDiff"
	_debug_diff_terrain.visible = false
	_add_level_child(_debug_diff_terrain)
	print("[MeshFill] Height diff overlay ready [H to toggle]")


# 鈹€鈹€鈹€ Override Delta / Brush / Visualization 鈹€鈹€鈹€

func _init_override_images() -> void:
	_override_delta = Image.create(TEX_RES, TEX_RES, false, Image.FORMAT_RF)
	_override_delta.fill(Color(0.0, 0.0, 0.0, 0.0))
	_override_mask = Image.create(TEX_RES, TEX_RES, false, Image.FORMAT_RF)
	_override_mask.fill(Color(0.0, 0.0, 0.0, 0.0))
	_dep_terrain = Image.create(TEX_RES, TEX_RES, false, Image.FORMAT_RF)
	_dep_terrain.fill(Color(0.0, 0.0, 0.0, 0.0))
	_dep_rock = Image.create(TEX_RES, TEX_RES, false, Image.FORMAT_RF)
	_dep_rock.fill(Color(0.0, 0.0, 0.0, 0.0))
	_current_rock_mask_img = Image.create(TEX_RES, TEX_RES, false, Image.FORMAT_RF)
	_current_rock_mask_img.fill(Color(0.0, 0.0, 0.0, 0.0))
	_rock_override_delta = Image.create(TEX_RES, TEX_RES, false, Image.FORMAT_RF)
	_rock_override_delta.fill(Color(0.0, 0.0, 0.0, 0.0))
	_rock_override_mask = Image.create(TEX_RES, TEX_RES, false, Image.FORMAT_RF)
	_rock_override_mask.fill(Color(0.0, 0.0, 0.0, 0.0))


func _compute_terrain_avg_height(height_tex: ImageTexture) -> float:
	var img := height_tex.get_image()
	var total := 0.0
	var res := img.get_width()
	for y in range(0, res, 4):
		for x in range(0, res, 4):
			total += img.get_pixelv(Vector2i(x, y)).r
	var sample_count := ceili(float(res) / 4.0)
	return total / float(sample_count * sample_count)


func _setup_delta_overlay_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 99
	add_child(layer)

	_delta_panel = PanelContainer.new()
	_delta_panel.visible = false
	layer.add_child(_delta_panel)

	var vbox := VBoxContainer.new()
	_delta_panel.add_child(vbox)

	var title := Label.new()
	title.text = "Override Delta [V]"
	vbox.add_child(title)

	_delta_overlay = TextureRect.new()
	_delta_overlay.custom_minimum_size = Vector2(200, 200)
	_delta_overlay.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	vbox.add_child(_delta_overlay)

	_brush_label = Label.new()
	_brush_label.text = "[B] Toggle Brush"
	vbox.add_child(_brush_label)

	call_deferred("_position_delta_panel")


func _position_delta_panel() -> void:
	if _delta_panel != null:
		var vp_size := get_viewport().get_visible_rect().size
		_delta_panel.position = Vector2(vp_size.x - 230, 10)


func _toggle_brush_mode() -> void:
	if _painting:
		_painting = false
		_finish_brush_stroke()
	_brush_active = not _brush_active
	if _brush_active:
		_tile_refresh_mode = false
	_update_brush_label()
	if _brush_active:
		if not _debug_delta_showing:
			_toggle_delta_overlay()
		var target_name := "Height" if _brush_target == BRUSH_TARGET_HEIGHT else "Rock"
		print("[MeshFill] Brush: ON [%s]  LMB=+  RMB=-  N=switch layer  Wheel=str  Shift+Wheel=rad" % target_name)
	else:
		print("[MeshFill] Brush: OFF")


func _cycle_brush_target() -> void:
	if _brush_target == BRUSH_TARGET_HEIGHT:
		_brush_target = BRUSH_TARGET_ROCK
	else:
		_brush_target = BRUSH_TARGET_HEIGHT
	_update_brush_label()
	if _debug_delta_showing:
		_update_delta_overlay()
	var target_name := "Height" if _brush_target == BRUSH_TARGET_HEIGHT else "Rock"
	print("[MeshFill] Brush target: %s" % target_name)


func _update_brush_label() -> void:
	if _brush_label == null:
		return
	var target_name := "Height" if _brush_target == BRUSH_TARGET_HEIGHT else "Rock"
	if _brush_active:
		_brush_label.text = "Brush ON [%s] | Str: %.1f | Rad: %d\nLMB: + | RMB: - | N: switch" % [target_name, _brush_strength, _brush_radius]
	elif _tile_refresh_mode:
		_brush_label.text = "Tile Refresh ON | Click to clear"
	else:
		_brush_label.text = "[B] Brush  [T] Tile  [N] Layer: %s" % target_name


func _toggle_delta_overlay() -> void:
	_debug_delta_showing = not _debug_delta_showing
	if _delta_panel != null:
		_delta_panel.visible = _debug_delta_showing
	if _debug_delta_showing:
		_update_delta_overlay()
		print("[MeshFill] Delta overlay: ON")
	else:
		print("[MeshFill] Delta overlay: OFF")


func _update_delta_overlay() -> void:
	if _delta_overlay == null:
		return
	var active_delta: Image = _override_delta if _brush_target == BRUSH_TARGET_HEIGHT else _rock_override_delta
	if active_delta == null:
		return
	var heatmap := _delta_to_heatmap(active_delta)
	_delta_overlay.texture = ImageTexture.create_from_image(heatmap)

	var stats := _get_delta_stats()
	if _brush_label != null and _debug_delta_showing:
		var base := _brush_label.text
		if not base.contains("Min"):
			_brush_label.text = base + "\nMin: %.2f  Max: %.2f" % [stats.x, stats.y]


func _get_delta_stats() -> Vector2:
	var active_delta: Image = _override_delta if _brush_target == BRUSH_TARGET_HEIGHT else _rock_override_delta
	var d_min := 0.0
	var d_max := 0.0
	if active_delta != null:
		for y in range(TEX_RES):
			for x in range(TEX_RES):
				var v := active_delta.get_pixelv(Vector2i(x, y)).r
				d_min = minf(d_min, v)
				d_max = maxf(d_max, v)
	return Vector2(d_min, d_max)


func _delta_to_heatmap(delta_img: Image) -> Image:
	var res := delta_img.get_width()
	var vis := Image.create(res, res, false, Image.FORMAT_RGBA8)
	var max_abs := 0.001
	for y in range(res):
		for x in range(res):
			max_abs = maxf(max_abs, absf(delta_img.get_pixelv(Vector2i(x, y)).r))
	for y in range(res):
		for x in range(res):
			var v := delta_img.get_pixelv(Vector2i(x, y)).r
			var t := clampf(absf(v) / max_abs, 0.0, 1.0)
			var c: Color
			if v > 0.001:
				c = Color(1.0, 0.15, 0.0, 0.3 + 0.7 * t)
			elif v < -0.001:
				c = Color(0.0, 0.3, 1.0, 0.3 + 0.7 * t)
			else:
				c = Color(0.15, 0.15, 0.15, 0.2)
			vis.set_pixelv(Vector2i(x, y), c)
	return vis


func _begin_brush_stroke() -> void:
	_brush_dirty_rect = Rect2i()
	_brush_stroke_changed = false


func _finish_brush_stroke() -> void:
	if not _brush_stroke_changed and not _brush_voxel_commit_pending:
		_begin_brush_stroke()
		return

	var dirty_rect := _brush_dirty_rect
	if dirty_rect.size.x <= 0 or dirty_rect.size.y <= 0:
		dirty_rect = Rect2i(0, 0, TEX_RES, TEX_RES)

	var has_layer_edit := _brush_stroke_changed
	var has_voxel_edit := _brush_voxel_commit_pending
	_brush_stroke_changed = false
	_brush_voxel_commit_pending = false
	_brush_dirty_rect = Rect2i()
	_commit_brush_edit(dirty_rect, has_layer_edit, has_voxel_edit)


func _merge_dirty_rect(rect: Rect2i) -> void:
	var clipped := rect.intersection(Rect2i(0, 0, TEX_RES, TEX_RES))
	if clipped.size.x <= 0 or clipped.size.y <= 0:
		return
	if _brush_dirty_rect.size.x <= 0 or _brush_dirty_rect.size.y <= 0:
		_brush_dirty_rect = clipped
		return
	var min_x := mini(_brush_dirty_rect.position.x, clipped.position.x)
	var min_y := mini(_brush_dirty_rect.position.y, clipped.position.y)
	var max_x := maxi(_brush_dirty_rect.position.x + _brush_dirty_rect.size.x, clipped.position.x + clipped.size.x)
	var max_y := maxi(_brush_dirty_rect.position.y + _brush_dirty_rect.size.y, clipped.position.y + clipped.size.y)
	_brush_dirty_rect = Rect2i(min_x, min_y, max_x - min_x, max_y - min_y)


func _mark_brush_dirty_circle(center: Vector2i, radius: int) -> void:
	var diameter := radius * 2 + 1
	_merge_dirty_rect(Rect2i(
		Vector2i(center.x - radius, center.y - radius),
		Vector2i(diameter, diameter)
	))
	_brush_stroke_changed = true


func _dirty_rect_with_margin(dirty_rect: Rect2i) -> Rect2i:
	if dirty_rect.size.x <= 0 or dirty_rect.size.y <= 0:
		return Rect2i(0, 0, TEX_RES, TEX_RES)
	var pixel_size := capture_size / float(TEX_RES)
	var margin := ceili(target_height_extension / pixel_size) + _brush_radius + 2
	return dirty_rect.grow(margin).intersection(Rect2i(0, 0, TEX_RES, TEX_RES))


func _commit_brush_edit(dirty_rect: Rect2i, update_generated_layers: bool = true, update_voxels: bool = true) -> void:
	var commit_rect := _dirty_rect_with_margin(dirty_rect)
	var had_vegetation := _vegetation_generated
	print("[MeshFill] Brush commit: dirty=%s target=%s" % [
		str(commit_rect),
		"Height" if _brush_target == BRUSH_TARGET_HEIGHT else "Rock"
	])

	if update_generated_layers:
		_regenerate()

	if update_generated_layers and had_vegetation:
		_generate_vegetation()
	elif update_voxels:
		var applied := _rebuild_vegetation_buffers_from_scene_records(commit_rect)
		if applied > 0:
			print("[MeshFill] Brush commit: refreshed %d scene voxel records" % applied)


func _paint_at_screen(screen_pos: Vector2) -> void:
	var pixel := _screen_to_terrain_pixel(screen_pos)
	if pixel.x < 0:
		return
	var sign_val := 1.0 if _paint_positive else -1.0
	_paint_brush_circle(pixel, _brush_radius, _brush_strength * sign_val)
	_mark_brush_dirty_circle(pixel, _brush_radius)
	if _debug_delta_showing:
		_update_delta_overlay()


func _screen_to_terrain_pixel(screen_pos: Vector2) -> Vector2i:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return Vector2i(-1, -1)
	var from := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	if absf(dir.y) < 0.001:
		return Vector2i(-1, -1)
	var t := (_terrain_hit_y - from.y) / dir.y
	if t < 0.0:
		return Vector2i(-1, -1)
	var hit := from + dir * t
	var half := capture_size / 2.0
	var px_x := int((hit.x + half) / capture_size * float(TEX_RES))
	var px_y := int((hit.z + half) / capture_size * float(TEX_RES))
	if px_x < 0 or px_x >= TEX_RES or px_y < 0 or px_y >= TEX_RES:
		return Vector2i(-1, -1)
	return Vector2i(px_x, px_y)


func _paint_brush_circle(center: Vector2i, radius: int, strength: float) -> void:
	var terrain_img: Image = null
	if not _cached_textures.is_empty() and _cached_textures.has("scene_depth"):
		terrain_img = _cached_textures["scene_depth"].get_image()
	var delta_img: Image = _override_delta if _brush_target == BRUSH_TARGET_HEIGHT else _rock_override_delta
	var mask_img: Image = _override_mask if _brush_target == BRUSH_TARGET_HEIGHT else _rock_override_mask
	var r_sq := radius * radius
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var dist_sq := dx * dx + dy * dy
			if dist_sq > r_sq:
				continue
			var px := Vector2i(center.x + dx, center.y + dy)
			if px.x < 0 or px.x >= TEX_RES or px.y < 0 or px.y >= TEX_RES:
				continue
			var falloff := 1.0 - sqrt(float(dist_sq)) / float(radius)
			var current_val := delta_img.get_pixelv(px).r
			delta_img.set_pixelv(px, Color(current_val + strength * falloff * 0.02, 0.0, 0.0, 0.0))
			mask_img.set_pixelv(px, Color(1.0, 0.0, 0.0, 0.0))
			if _brush_target == BRUSH_TARGET_HEIGHT:
				if terrain_img != null and _dep_terrain != null:
					_dep_terrain.set_pixelv(px, Color(max_height - terrain_img.get_pixelv(px).r, 0.0, 0.0, 0.0))
				if _current_rock_mask_img != null and _dep_rock != null:
					_dep_rock.set_pixelv(px, Color(_current_rock_mask_img.get_pixelv(px).r, 0.0, 0.0, 0.0))


# 鈹€鈹€鈹€ Tile Refresh Tool 鈹€鈹€鈹€

func _toggle_tile_refresh_mode() -> void:
	if _painting:
		_painting = false
		_finish_brush_stroke()
	_tile_refresh_mode = not _tile_refresh_mode
	if _tile_refresh_mode:
		_brush_active = false
		_update_brush_label()
		print("[MeshFill] Tile Refresh: ON 鈥?click a tile to clear its overrides and regenerate")
	else:
		print("[MeshFill] Tile Refresh: OFF")


func _tile_refresh_at_screen(screen_pos: Vector2) -> void:
	var pixel := _screen_to_terrain_pixel(screen_pos)
	if pixel.x < 0:
		return
	var tile_origin := Vector2i(
		(pixel.x / TILE_SIZE) * TILE_SIZE,
		(pixel.y / TILE_SIZE) * TILE_SIZE
	)
	var tile_rect := Rect2i(tile_origin, Vector2i(TILE_SIZE, TILE_SIZE))
	tile_rect = tile_rect.intersection(Rect2i(0, 0, TEX_RES, TEX_RES))
	if tile_rect.size.x <= 0 or tile_rect.size.y <= 0:
		return

	_push_undo_snapshot()

	var cleared := 0
	for y in range(tile_rect.position.y, tile_rect.position.y + tile_rect.size.y):
		for x in range(tile_rect.position.x, tile_rect.position.x + tile_rect.size.x):
			var px := Vector2i(x, y)
			var any := _override_mask.get_pixelv(px).r > 0.01 or _rock_override_mask.get_pixelv(px).r > 0.01
			if any:
				_override_mask.set_pixelv(px, Color(0.0, 0.0, 0.0, 0.0))
				_override_delta.set_pixelv(px, Color(0.0, 0.0, 0.0, 0.0))
				_dep_terrain.set_pixelv(px, Color(0.0, 0.0, 0.0, 0.0))
				_dep_rock.set_pixelv(px, Color(0.0, 0.0, 0.0, 0.0))
				_rock_override_mask.set_pixelv(px, Color(0.0, 0.0, 0.0, 0.0))
				_rock_override_delta.set_pixelv(px, Color(0.0, 0.0, 0.0, 0.0))
				cleared += 1

	print("[MeshFill] Tile [%d,%d]: cleared %d override pixels" % [
		tile_origin.x / TILE_SIZE, tile_origin.y / TILE_SIZE, cleared])

	if _debug_delta_showing:
		_update_delta_overlay()


# 鈹€鈹€鈹€ Undo System (3 steps) 鈹€鈹€鈹€

func _push_undo_snapshot() -> void:
	if _override_delta == null or _override_mask == null:
		return
	var snapshot := {
		"delta": _override_delta.duplicate(),
		"mask": _override_mask.duplicate(),
		"dep_terrain": _dep_terrain.duplicate(),
		"dep_rock": _dep_rock.duplicate(),
		"rock_delta": _rock_override_delta.duplicate(),
		"rock_mask": _rock_override_mask.duplicate(),
	}
	_undo_stack.append(snapshot)
	if _undo_stack.size() > UNDO_MAX_STEPS:
		_undo_stack.remove_at(0)


func _undo_override() -> void:
	if _undo_stack.is_empty():
		print("[MeshFill] Undo: nothing to undo")
		return
	var snapshot: Dictionary = _undo_stack.pop_back()
	_override_delta = snapshot["delta"]
	_override_mask = snapshot["mask"]
	_dep_terrain = snapshot["dep_terrain"]
	_dep_rock = snapshot["dep_rock"]
	_rock_override_delta = snapshot["rock_delta"]
	_rock_override_mask = snapshot["rock_mask"]
	print("[MeshFill] Undo: restored (%d steps remaining)" % _undo_stack.size())
	if _debug_delta_showing:
		_update_delta_overlay()
	_commit_brush_edit(Rect2i(0, 0, TEX_RES, TEX_RES), true, true)


# 鈹€鈹€鈹€ Override Invalidation & Composition 鈹€鈹€鈹€

func _invalidate_overrides() -> void:
	if _cached_textures.is_empty() or _override_mask == null:
		return
	var terrain_tex: ImageTexture = _cached_textures["scene_depth"]
	var terrain_img: Image = terrain_tex.get_image()
	var invalidated := 0
	for y in range(TEX_RES):
		for x in range(TEX_RES):
			var px := Vector2i(x, y)
			if _override_mask.get_pixelv(px).r < 0.5:
				continue
			var cur_h: float = max_height - terrain_img.get_pixelv(px).r
			var saved_h := _dep_terrain.get_pixelv(px).r
			var cur_rock := _current_rock_mask_img.get_pixelv(px).r
			var saved_rock := _dep_rock.get_pixelv(px).r

			var terrain_changed := absf(cur_h - saved_h) > 0.1
			var rock_overlap := cur_rock > 0.5 and saved_rock < 0.5

			if terrain_changed or rock_overlap:
				_override_mask.set_pixelv(px, Color(0.0, 0.0, 0.0, 0.0))
				_override_delta.set_pixelv(px, Color(0.0, 0.0, 0.0, 0.0))
				_dep_terrain.set_pixelv(px, Color(0.0, 0.0, 0.0, 0.0))
				_dep_rock.set_pixelv(px, Color(0.0, 0.0, 0.0, 0.0))
				invalidated += 1
	if invalidated > 0:
		print("[MeshFill] Override: invalidated %d pixels (terrain/rock change)" % invalidated)
		if _debug_delta_showing:
			_update_delta_overlay()


func _composite_target_height() -> ImageTexture:
	var has_override := false
	if _override_mask != null:
		for y in range(TEX_RES):
			for x in range(TEX_RES):
				if _override_mask.get_pixelv(Vector2i(x, y)).r > 0.01:
					has_override = true
					break
			if has_override:
				break

	if not has_override:
		return _cached_textures["target_height"] as ImageTexture

	var src_tex: ImageTexture = _cached_textures["target_height"]
	var base_img: Image = src_tex.get_image().duplicate()
	var modified := 0
	for y in range(TEX_RES):
		for x in range(TEX_RES):
			var px := Vector2i(x, y)
			var mask_val := _override_mask.get_pixelv(px).r
			if mask_val < 0.01:
				continue
			var base_px: Color = base_img.get_pixelv(px)
			base_px.r += _override_delta.get_pixelv(px).r * mask_val
			base_img.set_pixelv(px, base_px)
			modified += 1
	print("[MeshFill] Override: composited %d pixels onto target_height" % modified)
	return ImageTexture.create_from_image(base_img)


# 鈹€鈹€鈹€ Texture loading with procedural fallback 鈹€鈹€鈹€

func _load_terrain_textures() -> Dictionary:
	var tex_names := [
		"scene_depth", "scene_normal", "object_depth",
		"object_normal", "height_normal", "target_height"
	]
	var textures: Dictionary = {}

	print("[MeshFill] Loading terrain textures...")
	var all_loaded := true
	for tname in tex_names:
		var tex := _load_raw_texture("res://textures/%s.raw" % tname, TEX_RES, TEX_RES)
		if tex == null:
			all_loaded = false
			break
		textures[tname] = tex
		print("  Loaded: %s (%dx%d)" % [tname, tex.get_width(), tex.get_height()])

	if all_loaded:
		return textures

	print("[MeshFill] .raw textures not found, generating procedural terrain data...")
	return _generate_procedural_textures()


func _load_raw_texture(path: String, width: int, height: int) -> ImageTexture:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var expected_size := width * height * 4 * 4  # RGBAF = 4 channels 脳 4 bytes
	var data := f.get_buffer(expected_size)
	f.close()
	if data.size() != expected_size:
		push_error("Size mismatch for %s: got %d, expected %d" % [path, data.size(), expected_size])
		return null
	var img := Image.create_from_data(width, height, false, Image.FORMAT_RGBAF, data)
	return ImageTexture.create_from_image(img)


func _generate_procedural_textures() -> Dictionary:
	var res := TEX_RES

	var height_data: PackedFloat32Array = []
	height_data.resize(res * res)

	for y in range(res):
		for x in range(res):
			var u := float(x) / float(res - 1)
			var v := float(y) / float(res - 1)
			var h := 10.0
			h += sin(u * PI * 2.5 + 0.3) * cos(v * PI * 1.8) * 5.0
			h += cos(u * PI * 5.2 + 1.1) * sin(v * PI * 4.3 + 0.7) * 2.5
			h += sin(u * PI * 11.0 + 2.5) * cos(v * PI * 8.7 + 1.3) * 1.0
			h += sin((u + v) * PI * 3.0) * 3.0
			h = clampf(h, 1.0, max_height * 0.6)
			height_data[y * res + x] = h

	var target_height_img := Image.create(res, res, false, Image.FORMAT_RGBAF)
	for y in range(res):
		for x in range(res):
			var h := height_data[y * res + x]
			target_height_img.set_pixelv(Vector2i(x, y), Color(h, 0.0, 0.0, 1.0))

	var scene_depth_img := Image.create(res, res, false, Image.FORMAT_RGBAF)
	for y in range(res):
		for x in range(res):
			var h := height_data[y * res + x]
			scene_depth_img.set_pixelv(Vector2i(x, y), Color(max_height - h, 0.0, 0.0, 1.0))

	var scene_normal_img := Image.create(res, res, false, Image.FORMAT_RGBAF)
	scene_normal_img.fill(Color(0.0, 0.0, 1.0, 1.0))

	var object_depth_img := Image.create(res, res, false, Image.FORMAT_RGBAF)
	object_depth_img.fill(Color(max_height, 0.0, 0.0, 1.0))

	var object_normal_img := Image.create(res, res, false, Image.FORMAT_RGBAF)
	object_normal_img.fill(Color(0.0, 0.0, 0.0, 1.0))

	var height_normal_img := Image.create(res, res, false, Image.FORMAT_RGBAF)
	height_normal_img.fill(Color(0.0, 1.0, 0.0, 1.0))

	print("  Generated: procedural terrain (%dx%d, height ~1-%.0fm)" % [
		res, res, max_height * 0.6])

	return {
		"scene_depth": ImageTexture.create_from_image(scene_depth_img),
		"scene_normal": ImageTexture.create_from_image(scene_normal_img),
		"object_depth": ImageTexture.create_from_image(object_depth_img),
		"object_normal": ImageTexture.create_from_image(object_normal_img),
		"height_normal": ImageTexture.create_from_image(height_normal_img),
		"target_height": ImageTexture.create_from_image(target_height_img),
	}


# 鈹€鈹€鈹€ Rock mask capture (tag mechanism) 鈹€鈹€鈹€

func _load_previous_rock_mask() -> Texture2D:
	var path := rock_mask_path
	if path.is_empty():
		path = OS.get_user_data_dir() + "/rock_placement_mask.png"
	if not FileAccess.file_exists(path):
		print("[MeshFill] No previous rock mask found at: %s" % path)
		return null
	var img := Image.load_from_file(path)
	if img == null:
		push_warning("[MeshFill] Failed to load rock mask: %s" % path)
		return null
	if img.get_width() != TEX_RES or img.get_height() != TEX_RES:
		img.resize(TEX_RES, TEX_RES, Image.INTERPOLATE_BILINEAR)
	print("[MeshFill] Loaded previous rock mask: %s (%dx%d)" % [path, img.get_width(), img.get_height()])
	return ImageTexture.create_from_image(img)


func _capture_and_save_rock_mask() -> void:
	if _raw_current_height_image == null:
		print("[MeshFill] No current height data for mask")
		return

	var mask := Image.create(TEX_RES, TEX_RES, false, Image.FORMAT_RGBA8)
	var nonzero := 0

	for y in range(TEX_RES):
		for x in range(TEX_RES):
			var px := _raw_current_height_image.get_pixelv(Vector2i(x, y))
			var rock_placed := px.g
			if rock_placed > 0.5:
				mask.set_pixelv(Vector2i(x, y), Color(1.0, 1.0, 1.0, 1.0))
				nonzero += 1
				if _current_rock_mask_img != null:
					_current_rock_mask_img.set_pixelv(Vector2i(x, y), Color(1.0, 0.0, 0.0, 0.0))
			else:
				mask.set_pixelv(Vector2i(x, y), Color(0.0, 0.0, 0.0, 0.0))
				if _current_rock_mask_img != null:
					_current_rock_mask_img.set_pixelv(Vector2i(x, y), Color(0.0, 0.0, 0.0, 0.0))

	var out_path := OS.get_user_data_dir() + "/rock_placement_mask.png"
	mask.save_png(out_path)
	print("[MeshFill] Rock mask saved: %s (%d/%d mask pixels)" % [
		out_path, nonzero, TEX_RES * TEX_RES])


# 鈹€鈹€鈹€ Cliff data loading with procedural fallback 鈹€鈹€鈹€

func _join_asset_path(dir_path: String, file_name: String) -> String:
	return dir_path + file_name if dir_path.ends_with("/") else dir_path + "/" + file_name


func _collect_resource_paths(dir_path: String, out_paths: Array[String]) -> void:
	if dir_path.is_empty():
		return
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if file_name == "." or file_name == "..":
			file_name = dir.get_next()
			continue
		var child_path := _join_asset_path(dir_path, file_name)
		if dir.current_is_dir():
			_collect_resource_paths(child_path, out_paths)
		else:
			var ext := file_name.get_extension().to_lower()
			if ext in ["tres", "res", "tscn", "scn"] and not out_paths.has(child_path):
				out_paths.append(child_path)
		file_name = dir.get_next()
	dir.list_dir_end()


func _load_scripted_rock_assets(out_meshes: Array[Mesh], out_assets: Array[AutoRock]) -> int:
	var paths: Array[String] = []
	for path in rock_asset_paths:
		if not path.is_empty() and not paths.has(path):
			paths.append(path)
	_collect_resource_paths(rock_asset_dir, paths)

	var loaded := 0
	for path in paths:
		var resource = load(path)
		var asset: AutoRock = null
		if resource is PackedScene:
			var instance := (resource as PackedScene).instantiate()
			if instance is AutoRock:
				asset = instance as AutoRock
			elif instance != null:
				instance.free()
		elif resource is MeshDataAsset:
			asset = AutoAssetFactory.rock_from_mesh_data_asset(resource as MeshDataAsset)
		if asset == null:
			continue
		if asset.asset_id.is_empty():
			asset.asset_id = path.get_file().get_basename()
		if not asset.is_valid_rock_asset():
			push_warning("[MeshFill] Skipping rock asset without mesh/height texture: %s" % path)
			continue
		out_meshes.append(asset.mesh)
		out_assets.append(asset)
		loaded += 1
		print("  Scripted rock asset: %s (%s, size=%.2fm)" % [
			path, asset.object_subtype, asset.mesh_size])
	return loaded


func _load_vegetation_assets() -> Array[AutoVegetationAsset]:
	var paths: Array[String] = []
	for path in vegetation_asset_paths:
		if not path.is_empty() and not paths.has(path):
			paths.append(path)
	_collect_resource_paths(vegetation_asset_dir, paths)

	var assets: Array[AutoVegetationAsset] = []
	for path in paths:
		var resource = load(path)
		if not resource is AutoVegetationAsset:
			continue
		var asset := resource as AutoVegetationAsset
		if asset.get_scatter_profile().is_empty():
			push_warning("[MeshFill] Skipping vegetation asset without affected bands: %s" % path)
			continue
		if asset.get_mesh() == null:
			push_warning("[MeshFill] Skipping vegetation asset without mesh source: %s" % path)
			continue
		if asset.scatter_max_count <= 0:
			continue
		assets.append(asset)
		print("  Scripted vegetation asset: %s (%s/%s)" % [
			path, asset.object_subtype, asset.vegetation_band])
	if not assets.is_empty():
		print("[MeshFill] Loaded %d scripted vegetation assets" % assets.size())
	return assets


func _load_cliff_data(out_meshes: Array[Mesh], out_assets: Array[AutoRock]) -> void:
	print("[MeshFill] Loading cliff meshes...")
	var scripted_count := _load_scripted_rock_assets(out_meshes, out_assets)
	var fbx_configs := [
		{"fbx": "res://geo/cliff_01.FBX", "height": "res://geo/cliff_01_height.raw", "size": 2.3},
		{"fbx": "res://geo/cliff_02.FBX", "height": "res://geo/cliff_02_height.raw", "size": 5.3},
	]

	var loaded_all := true
	var fbx_meshes: Array[Mesh] = []
	var fbx_assets: Array[AutoRock] = []
	for cfg in fbx_configs:
		var mesh := _load_mesh_from_fbx(cfg.fbx)
		var raw_source_mesh := AutoAssetFactory.load_source_mesh(cfg.fbx)
		var source_mesh: Mesh = _bake_axis_rotation(raw_source_mesh) if raw_source_mesh != null else null
		if mesh == null:
			loaded_all = false
			break
		var htex := _load_raw_texture(cfg.height, TEX_RES, TEX_RES)
		if htex == null:
			loaded_all = false
			break

		if absf(mesh_height_scale - 1.0) > 0.001:
			var img := htex.get_image()
			_scale_height_image(img, mesh_height_scale)
			htex = ImageTexture.create_from_image(img)

		var h_stats := _get_height_stats(htex.get_image())
		fbx_meshes.append(mesh)
		var asset := AutoCliffRock.new()
		asset.configure_cliff({
			"asset_id": str(cfg.fbx).get_file().get_basename(),
			"name": str(cfg.fbx).get_file().get_basename(),
			"mesh": mesh,
			"source_mesh": source_mesh if source_mesh != null else mesh,
			"source_mesh_path": cfg.fbx,
			"mesh_height_texture": htex,
			"mesh_size": cfg.size,
			"color": ROCK_VOXEL_COLOR,
			"complexity": 1.0,
			"random_rotate": Vector2(0.0, 1.0),
			"random_scale": Vector2(0.8, 1.2),
			"random_height_offset": Vector2(-0.5, 0.5),
		})
		fbx_assets.append(asset)
		print("  Loaded: %s (size=%.1fm, height %.1f~%.1f, scale=%.3f)" % [
			cfg.fbx, cfg.size, h_stats.x, h_stats.y, mesh_height_scale])

	if loaded_all:
		out_meshes.append_array(fbx_meshes)
		out_assets.append_array(fbx_assets)
	elif scripted_count <= 0:
		print("[MeshFill] Cliff FBX/height not found, generating procedural cliffs...")
		_generate_procedural_cliffs(out_meshes, out_assets)
	else:
		print("[MeshFill] Cliff FBX/height not found; using %d scripted rock assets" % scripted_count)


func _generate_procedural_cliffs(out_meshes: Array[Mesh], out_assets: Array[AutoRock]) -> void:
	var configs := [
		{"name": "small_cliff", "size": 2.3, "box_size": Vector3(2.0, 4.0, 1.0)},
		{"name": "large_cliff", "size": 5.3, "box_size": Vector3(4.0, 8.0, 2.0)},
	]

	for cfg in configs:
		var box := BoxMesh.new()
		box.size = cfg.box_size

		var cliff_mat := StandardMaterial3D.new()
		cliff_mat.albedo_color = Color(0.55, 0.50, 0.45)
		cliff_mat.roughness = 0.95
		box.material = cliff_mat

		out_meshes.append(box)

		var htex_img := _create_cliff_height_image(cfg.box_size)
		var asset := AutoCliffRock.new()
		asset.configure_cliff({
			"asset_id": cfg.name,
			"name": cfg.name,
			"mesh": box,
			"mesh_height_texture": ImageTexture.create_from_image(htex_img),
			"mesh_size": cfg.size,
			"color": ROCK_VOXEL_COLOR,
			"complexity": 1.0,
			"random_rotate": Vector2(0.0, 1.0),
			"random_scale": Vector2(0.8, 1.2),
			"random_height_offset": Vector2(-0.5, 0.5),
		})
		out_assets.append(asset)
		print("  Generated: %s (size=%.1fm)" % [cfg.name, cfg.size])


func _create_cliff_height_image(box_size: Vector3) -> Image:
	var img := Image.create(TEX_RES, TEX_RES, false, Image.FORMAT_RGBAF)
	var margin := 0.15
	var peak := box_size.y
	for y in range(TEX_RES):
		for x in range(TEX_RES):
			var u := float(x) / float(TEX_RES - 1)
			var v := float(y) / float(TEX_RES - 1)
			var inside := u > margin and u < 1.0 - margin and v > margin and v < 1.0 - margin
			if inside:
				var h := minf(box_size.y * (1.0 - absf(u - 0.5) * 2.0) - peak, -0.01)
				img.set_pixelv(Vector2i(x, y), Color(h, 0.0, 0.0, 1.0))
			else:
				img.set_pixelv(Vector2i(x, y), Color(-20000.0, 0.0, 0.0, 1.0))
	return img


# 鈹€鈹€鈹€ Terrain mesh creation 鈹€鈹€鈹€

func _create_terrain_mesh(height_tex: ImageTexture) -> void:
	var existing := _get_level_child("Terrain")
	if existing != null:
		_remove_mesh_voxel_record(existing)
		existing.queue_free()

	var img := height_tex.get_image()
	var res := img.get_width()
	var cell_size := capture_size / float(res)
	var half := capture_size / 2.0
	var height_stats := _get_height_stats(img)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	for y in range(res):
		for x in range(res):
			var h := img.get_pixelv(Vector2i(x, y)).r
			var px := float(x) * cell_size - half
			var pz := float(y) * cell_size - half
			st.set_uv(Vector2(float(x) / float(res - 1), float(y) / float(res - 1)))
			st.add_vertex(Vector3(px, h, pz))

	for y in range(res - 1):
		for x in range(res - 1):
			var i := y * res + x
			st.add_index(i)
			st.add_index(i + res)
			st.add_index(i + 1)
			st.add_index(i + 1)
			st.add_index(i + res)
			st.add_index(i + res + 1)

	st.generate_normals()
	var terrain_mesh := st.commit()

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.42, 0.35)
	mat.roughness = 0.9
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var mi := MeshInstance3D.new()
	mi.mesh = terrain_mesh
	mi.material_override = mat
	mi.name = "Terrain"
	mi.set_meta("terrain_height_stats", height_stats)
	_add_level_child(mi)
	_attach_mesh_voxel_record(mi, _make_terrain_voxel_record(mi, res))

	print("[MeshFill] Terrain mesh created (%dx%d, %.0fm x %.0fm, h=%.2f..%.2f)" % [
		res, res, capture_size, capture_size, height_stats.x, height_stats.y])


func _scale_height_image(img: Image, scale: float) -> void:
	var w := img.get_width()
	var h := img.get_height()
	for y in range(h):
		for x in range(w):
			var px := img.get_pixelv(Vector2i(x, y))
			if px.r > -10000.0:
				px.r = minf(px.r * scale, -0.01)
			img.set_pixelv(Vector2i(x, y), px)



func _get_height_stats(img: Image) -> Vector2:
	var h_min := 99999.0
	var h_max := -99999.0
	var w := img.get_width()
	var h := img.get_height()
	for y in range(h):
		for x in range(w):
			var v := img.get_pixelv(Vector2i(x, y)).r
			if v > -10000.0:
				h_min = minf(h_min, v)
				h_max = maxf(h_max, v)
	return Vector2(h_min, h_max)


# 鈹€鈹€鈹€ FBX mesh loading 鈹€鈹€鈹€

func _load_mesh_from_fbx(path: String) -> Mesh:
	var r := load(path)
	if r == null:
		return null
	var raw_mesh: Mesh = null
	if r is PackedScene:
		var instance := (r as PackedScene).instantiate()
		raw_mesh = _find_mesh_in_tree(instance)
		instance.free()
	elif r is Mesh:
		raw_mesh = r as Mesh
	if raw_mesh == null:
		return null
	return _bake_axis_rotation(raw_mesh)


func _bake_axis_rotation(src_mesh: Mesh) -> ArrayMesh:
	var base_rot := Basis(Vector3(1, 0, 0), deg_to_rad(cliff_base_rotation.x))
	base_rot = base_rot * Basis(Vector3(0, 1, 0), deg_to_rad(cliff_base_rotation.y))
	base_rot = base_rot * Basis(Vector3(0, 0, 1), deg_to_rad(cliff_base_rotation.z))
	var xform := Transform3D(base_rot, Vector3.ZERO)

	var new_mesh := ArrayMesh.new()
	for si in range(src_mesh.get_surface_count()):
		var arrays := src_mesh.surface_get_arrays(si)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()

		var new_verts := PackedVector3Array()
		new_verts.resize(verts.size())
		for i in range(verts.size()):
			new_verts[i] = xform * verts[i]
		arrays[Mesh.ARRAY_VERTEX] = new_verts

		if normals.size() > 0:
			var new_normals := PackedVector3Array()
			new_normals.resize(normals.size())
			for i in range(normals.size()):
				new_normals[i] = (base_rot * normals[i]).normalized()
			arrays[Mesh.ARRAY_NORMAL] = new_normals

		new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mat := src_mesh.surface_get_material(si)
		if mat != null:
			new_mesh.surface_set_material(si, mat)
	return new_mesh


func _find_mesh_in_tree(node: Node) -> Mesh:
	if node is MeshInstance3D:
		return (node as MeshInstance3D).mesh
	if node is ImporterMeshInstance3D:
		var importer_mesh = node.get("mesh")
		if importer_mesh != null and importer_mesh.has_method("get_mesh"):
			return importer_mesh.get_mesh()
	for child in node.get_children():
		var m := _find_mesh_in_tree(child)
		if m != null:
			return m
	return null


# 鈹€鈹€鈹€ Vegetation Generation (P1/P2) 鈹€鈹€鈹€

## Maximum self-loop iterations before forcing placement.
const VEG_MAX_ITERATIONS := 4


func _ensure_vegetation_exclusion() -> void:
	if _veg_exclusion != null:
		return
	_veg_exclusion = VegetationExclusion.new(TEX_RES, capture_size)
	_veg_exclusion.add_band("ground",     0.0, 0.3, TEX_RES,      Color(0.2, 0.8, 0.2, 1.0))
	_veg_exclusion.add_band("understory", 0.3, 2.0, TEX_RES / 2,  Color(0.8, 0.6, 0.2, 0.7))
	_veg_exclusion.add_band("midstory",   2.0, 6.0, TEX_RES / 2,  Color(0.2, 0.5, 0.8, 0.4))
	_veg_exclusion.add_band("canopy",     6.0, 99.0, TEX_RES / 4, Color(0.8, 0.2, 0.2, 0.2))


func _generate_vegetation() -> void:
	if _cached_textures.is_empty():
		push_error("[MeshFill] Cannot generate vegetation: no textures loaded")
		return

	_clear_vegetation()

	var t0 := Time.get_ticks_msec()
	print("[MeshFill] Generating vegetation (self-loop)")

	var rock_mask_img: Image = null
	if _current_rock_mask_img != null:
		rock_mask_img = _current_rock_mask_img
	else:
		rock_mask_img = Image.create(TEX_RES, TEX_RES, false, Image.FORMAT_RF)
		rock_mask_img.fill(Color(0.0, 0.0, 0.0, 0.0))

	var scene_depth_img: Image = (_cached_textures["scene_depth"] as ImageTexture).get_image()
	var target_height_img: Image = (_cached_textures["target_height"] as ImageTexture).get_image()
	var cliff_tree_mask_img := _make_cliff_tree_mask(rock_mask_img, target_height_img)

	# --- Init exclusion system (once) ---
	_ensure_vegetation_exclusion()

	# --- Phase 1: Generate occupancy + validate (self-loop) ---
	# 4 vegetation types, each occupying one foliage band. Thick trunks also
	# write coarse collision voxels so cross-band trees cannot share a stem.
	#   grass        鈫?ground     (R)
	#   bush         鈫?understory (G)
	#   midstory_tree 鈫?midstory  (B)
	#   canopy_tree  鈫?canopy     (A)
	var grass_results: Array[Dictionary] = []
	var bush_results: Array[Dictionary] = []
	var midstory_results: Array[Dictionary] = []
	var canopy_results: Array[Dictionary] = []
	var scripted_vegetation_results: Array[Dictionary] = []
	var validation: Dictionary = {}
	var iteration := 0
	var density_scale := 1.0
	if _vegetation_assets.is_empty():
		_vegetation_assets = _load_vegetation_assets()

	while iteration < VEG_MAX_ITERATIONS:
		iteration += 1
		print("[MeshFill]   鈹€鈹€ Iteration %d (density_scale=%.2f) 鈹€鈹€" % [iteration, density_scale])

		_veg_exclusion.reset_occupancy()

		for band_name in ["ground", "understory", "midstory", "canopy"]:
			_veg_exclusion.import_mask(band_name, rock_mask_img)
		var applied_scene_meshes := _apply_scene_mesh_voxels_to_vegetation_buffers()
		if applied_scene_meshes > 0:
			print("[MeshFill]     Scene mesh voxel writes: %d" % applied_scene_meshes)

		# Layer 1: Canopy trees (canopy band, 6m+)
		var canopy_count := int(300 * density_scale)
		var canopy_profile := VegetationExclusion.profile_canopy_tree(3.0)
		var canopy_collision := VegetationExclusion.collision_trunk(0.45, 0.0, 2.2, 0.04, 0.08)
		canopy_results = _veg_exclusion.scatter_from_mask(
			canopy_profile, cliff_tree_mask_img, scene_depth_img, max_height, 3.0, 4.0, canopy_count, "canopy_tree", canopy_collision
		)
		print("[MeshFill]     Canopy trees near cliffs: %d" % canopy_results.size())

		# Layer 2: Midstory trees (midstory band, 2鈥?m)
		var midstory_count := int(400 * density_scale)
		var midstory_profile := VegetationExclusion.profile_midstory(2.0)
		var midstory_collision := VegetationExclusion.collision_trunk(0.30, 0.0, 1.6, 0.03, 0.06)
		midstory_results = _veg_exclusion.scatter_from_mask(
			midstory_profile, cliff_tree_mask_img, scene_depth_img, max_height, 2.0, 2.5, midstory_count, "midstory_tree", midstory_collision
		)
		print("[MeshFill]     Midstory trees near cliffs: %d" % midstory_results.size())

		# Layer 3: Bushes (understory band, 0.3鈥?m)
		bush_results = []
		print("[MeshFill]     Bushes: 0")

		var tree_results_for_grass: Array[Dictionary] = []
		tree_results_for_grass.append_array(canopy_results)
		tree_results_for_grass.append_array(midstory_results)
		var tree_grass_mask_img := _make_tree_grass_mask(tree_results_for_grass)

		scripted_vegetation_results.clear()
		for asset in _vegetation_assets:
			var scripted_profile := asset.get_scatter_profile()
			if scripted_profile.is_empty():
				continue
			var scripted_mask := cliff_tree_mask_img
			if asset.vegetation_band == "ground" or asset.object_subtype.find("grass") >= 0:
				scripted_mask = tree_grass_mask_img
			elif asset.vegetation_band == "understory" or asset.object_subtype.find("bush") >= 0:
				continue
			var scripted_count := int(asset.scatter_max_count * density_scale)
			var scripted_results := _veg_exclusion.scatter_from_mask(
				scripted_profile,
				scripted_mask,
				scene_depth_img,
				max_height,
				asset.scatter_min_distance,
				asset.scatter_max_scale,
				scripted_count,
				asset.object_subtype,
				asset.get_collision_voxels()
			)
			scripted_vegetation_results.append({
				"asset": asset,
				"results": scripted_results,
			})
			print("[MeshFill]     %s: %d" % [asset.object_subtype, scripted_results.size()])

		# Layer 4: Grass (ground band, 0鈥?.3m)
		var grass_count := int(2000 * density_scale)
		var grass_profile := VegetationExclusion.profile_grass(0.2)
		grass_results = _veg_exclusion.scatter_from_mask(
			grass_profile, tree_grass_mask_img, scene_depth_img, max_height, 0.5, 0.8, grass_count, "grass"
		)
		print("[MeshFill]     Grass around trees: %d" % grass_results.size())

		# Build voxel volume
		_veg_exclusion.build_voxel_volume(TEX_RES / 2, [1, 2, 2, 1])
		_sync_scene_mesh_voxel_records_from_exclusion()

		# Validate
		validation = _veg_exclusion.validate_voxel({
			"min_ground_occupancy": 5.0,
			"max_ground_occupancy": 85.0,
			"max_canopy_occupancy": 60.0,
			"min_diversity_score": 2,
		})

		var metrics: Dictionary = validation.metrics
		print("[MeshFill]     Validation: %s 鈥?%s" % [
			"PASS" if validation.passed else "FAIL", validation.reason])
		if metrics.has("band_occupancy_pct"):
			var names: Array = metrics.band_names
			var pcts: Array = metrics.band_occupancy_pct
			for bi in range(names.size()):
				print("[MeshFill]       %s: %.1f%%" % [names[bi], pcts[bi]])

		if validation.passed:
			break

		if "too high" in validation.reason:
			density_scale *= 0.7
		elif "too low" in validation.reason:
			density_scale *= 1.4
		else:
			density_scale *= 0.85
		print("[MeshFill]     鈫?Retrying with density_scale=%.2f" % density_scale)

	# --- Phase 2: Place meshes (one type per band) ---
	print("[MeshFill]   鈹€鈹€ Phase 2: Placing meshes 鈹€鈹€")

	_tree_mask_image = _veg_exclusion.get_band_mask_at_base_res("canopy")
	_midstory_mask_image = _veg_exclusion.get_band_mask_at_base_res("midstory")
	_bush_mask_image = _veg_exclusion.get_band_mask_at_base_res("understory")
	_grass_mask_image = _veg_exclusion.get_band_mask_at_base_res("ground")

	# Canopy trees
	if _tree_mesh == null:
		_tree_mesh = VegetationScatter.create_tree_mesh()
	for i in range(canopy_results.size()):
		var r: Dictionary = canopy_results[i]
		var mi := AutoCanopyTree.new()
		mi.configure_canopy_tree({
			"name": "CanopyTree_%d" % i,
			"mesh": _tree_mesh,
			"position": r.position,
			"rotation_mode": str(r.get("rotation_mode", "Y")),
			"rotation_degrees": r.get("rotation_degrees", Vector3(0.0, float(r.get("rotation_y", 0.0)), 0.0)),
			"scale": r.scale,
			"visual_layer": VegetationScatter.TREE_VISUAL_LAYER,
			"color": r.color,
			"complexity": r.complexity,
			"affected_bands": r.affected_bands,
			"collision_voxels": r.get("collision_voxels", []),
			"material": _make_veg_material(r.color, r.complexity),
			"auto_source": "scatter",
			"groups": [TEST_ONLY_GROUP, TEST_ONLY_VEGETATION_GROUP],
		})
		_add_level_child(mi)
		_mark_test_only_generated(mi, "vegetation")
		_attach_vegetation_voxel_record(mi, _mark_test_only_record(r, "vegetation"))

	# Midstory trees
	if _midstory_mesh == null:
		_midstory_mesh = VegetationScatter.create_midstory_mesh()
	for i in range(midstory_results.size()):
		var r: Dictionary = midstory_results[i]
		var mi := AutoMidstoryTree.new()
		mi.configure_midstory_tree({
			"name": "MidstoryTree_%d" % i,
			"mesh": _midstory_mesh,
			"position": r.position,
			"rotation_mode": str(r.get("rotation_mode", "Y")),
			"rotation_degrees": r.get("rotation_degrees", Vector3(0.0, float(r.get("rotation_y", 0.0)), 0.0)),
			"scale": r.scale,
			"visual_layer": VegetationScatter.MIDSTORY_VISUAL_LAYER,
			"color": r.color,
			"complexity": r.complexity,
			"affected_bands": r.affected_bands,
			"collision_voxels": r.get("collision_voxels", []),
			"material": _make_veg_material(r.color, r.complexity),
			"auto_source": "scatter",
			"groups": [TEST_ONLY_GROUP, TEST_ONLY_VEGETATION_GROUP],
		})
		_add_level_child(mi)
		_mark_test_only_generated(mi, "vegetation")
		_attach_vegetation_voxel_record(mi, _mark_test_only_record(r, "vegetation"))

	# Bushes
	if _bush_mesh == null:
		_bush_mesh = VegetationScatter.create_bush_mesh()
	for i in range(bush_results.size()):
		var r: Dictionary = bush_results[i]
		var mi := AutoBush.new()
		mi.configure_bush({
			"name": "Bush_%d" % i,
			"mesh": _bush_mesh,
			"position": r.position,
			"rotation_mode": str(r.get("rotation_mode", "Y")),
			"rotation_degrees": r.get("rotation_degrees", Vector3(0.0, float(r.get("rotation_y", 0.0)), 0.0)),
			"scale": r.scale,
			"visual_layer": VegetationScatter.BUSH_VISUAL_LAYER,
			"color": r.color,
			"complexity": r.complexity,
			"affected_bands": r.affected_bands,
			"collision_voxels": r.get("collision_voxels", []),
			"material": _make_veg_material(r.color, r.complexity),
			"auto_source": "scatter",
			"groups": [TEST_ONLY_GROUP, TEST_ONLY_VEGETATION_GROUP],
		})
		_add_level_child(mi)
		_mark_test_only_generated(mi, "vegetation")
		_attach_vegetation_voxel_record(mi, _mark_test_only_record(r, "vegetation"))

	# Scripted vegetation assets
	for entry in scripted_vegetation_results:
		var asset: AutoVegetationAsset = entry.asset
		var results: Array = entry.results
		for i in range(results.size()):
			var r: Dictionary = results[i]
			var placement_config := {
				"name": "%s_%d" % [asset.object_subtype, i],
				"position": r.position,
				"rotation_mode": str(r.get("rotation_mode", "Y")),
				"rotation_degrees": r.get("rotation_degrees", Vector3(0.0, float(r.get("rotation_y", 0.0)), 0.0)),
				"scale": r.scale,
				"color": r.color,
				"complexity": r.complexity,
				"affected_bands": r.affected_bands,
				"collision_voxels": r.get("collision_voxels", []),
				"auto_source": "scatter",
				"groups": [TEST_ONLY_GROUP, TEST_ONLY_VEGETATION_GROUP],
			}
			if asset.material == null:
				placement_config["material"] = _make_veg_material(r.color, r.complexity)
			var mi := asset.instantiate_vegetation(placement_config)
			_add_level_child(mi)
			_mark_test_only_generated(mi, "vegetation")
			_attach_vegetation_voxel_record(mi, _mark_test_only_record(r, "vegetation"))

	# Grass
	if _grass_mesh == null:
		_grass_mesh = VegetationScatter.create_bush_mesh()
	for i in range(grass_results.size()):
		var r: Dictionary = grass_results[i]
		var mi := AutoGrass.new()
		mi.configure_grass({
			"name": "Grass_%d" % i,
			"mesh": _grass_mesh,
			"position": r.position,
			"rotation_mode": str(r.get("rotation_mode", "Y")),
			"rotation_degrees": r.get("rotation_degrees", Vector3(0.0, float(r.get("rotation_y", 0.0)), 0.0)),
			"scale": r.scale * 0.3,
			"visual_layer": VegetationScatter.GRASS_VISUAL_LAYER,
			"color": r.color,
			"complexity": r.complexity,
			"affected_bands": r.affected_bands,
			"collision_voxels": r.get("collision_voxels", []),
			"material": _make_veg_material(r.color, r.complexity),
			"auto_source": "scatter",
			"groups": [TEST_ONLY_GROUP, TEST_ONLY_VEGETATION_GROUP],
		})
		_add_level_child(mi)
		_mark_test_only_generated(mi, "vegetation")
		_attach_vegetation_voxel_record(mi, _mark_test_only_record(r, "vegetation"))

	# Refresh debug masks after scene instances have written their voxel records
	# back into the height-band buffers.
	_tree_mask_image = _veg_exclusion.get_band_mask_at_base_res("canopy")
	_midstory_mask_image = _veg_exclusion.get_band_mask_at_base_res("midstory")
	_bush_mask_image = _veg_exclusion.get_band_mask_at_base_res("understory")
	_grass_mask_image = _veg_exclusion.get_band_mask_at_base_res("ground")

	# Print final stats
	for s in _veg_exclusion.get_band_stats():
		print("[MeshFill]   Band '%s' %s @%s (cplx=%.1f): %s" % [
			s.name, s.height_range, s.resolution, s.color.a, s.occupied])

	var vol_stats := _veg_exclusion.get_voxel_stats()
	print("[MeshFill]   Voxel volume: %dx%dx%d (xz=%.2fm), %s occupied" % [
		vol_stats.xz_resolution, vol_stats.xz_resolution, vol_stats.total_slices,
		_veg_exclusion._capture_size / float(vol_stats.xz_resolution),
		vol_stats.occupancy_pct])
	if vol_stats.has("collision_occupancy_pct"):
		print("[MeshFill]   Collision voxels: %s occupied" % [vol_stats.collision_occupancy_pct])
	print("[MeshFill]   Mesh voxel records: %d exclusion-buffer, %d runtime total" % [
		_veg_exclusion.get_mesh_voxel_record_count(), _mesh_voxel_records.size()])

	var elapsed := Time.get_ticks_msec() - t0
	_vegetation_generated = true
	var scripted_total := 0
	for entry in scripted_vegetation_results:
		var results: Array = entry.results
		scripted_total += results.size()
	print("[MeshFill] Vegetation complete: %d canopy + %d midstory + %d bush + %d scripted + %d grass in %dms (%d iter)" % [
		canopy_results.size(), midstory_results.size(), bush_results.size(),
		scripted_total, grass_results.size(), elapsed, iteration])

	_save_combined_mask_debug()


## Create a per-instance material tinted by band color + complexity.
## Color RGB 鈫?albedo tint, complexity 鈫?metallic/roughness hint.
func _make_veg_material(color: Color, complexity: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color.r, color.g, color.b, 1.0)
	mat.roughness = lerpf(0.9, 0.4, complexity)
	mat.metallic = complexity * 0.1
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


func _clear_vegetation() -> void:
	for group in ["placed_canopy_trees", "placed_midstory_trees", "placed_bushes", "placed_grass"]:
		for node in get_tree().get_nodes_in_group(group):
			_remove_mesh_voxel_record(node)
			node.queue_free()
	for node in _get_level_children():
		if node is AutoVegetation and not node.is_queued_for_deletion():
			var vegetation := node as AutoVegetation
			if vegetation.auto_source == "scatter":
				_remove_mesh_voxel_record(vegetation)
				vegetation.queue_free()
	if _veg_exclusion != null:
		_veg_exclusion._free_gpu()
		_veg_exclusion = null
	if _debug_mask_terrain != null:
		_debug_mask_terrain.queue_free()
		_debug_mask_terrain = null
	_vegetation_generated = false


func _save_combined_mask_debug() -> void:
	var out_dir := OS.get_user_data_dir()
	var vis := Image.create(TEX_RES, TEX_RES, false, Image.FORMAT_RGBA8)
	for y in range(TEX_RES):
		for x in range(TEX_RES):
			var px := Vector2i(x, y)
			var rock_v := 0.0
			var tree_v := 0.0
			var bush_v := 0.0
			if _current_rock_mask_img != null:
				rock_v = _current_rock_mask_img.get_pixelv(px).r
			if _tree_mask_image != null:
				tree_v = _tree_mask_image.get_pixelv(px).r
			if _bush_mask_image != null:
				bush_v = _bush_mask_image.get_pixelv(px).r
			vis.set_pixelv(px, Color(rock_v, tree_v, bush_v, 1.0))
	vis.save_png(out_dir + "/combined_mask.png")
	print("[MeshFill] Combined mask saved: %s/combined_mask.png" % out_dir)


func _build_debug_mask_terrain() -> void:
	if _debug_mask_terrain != null:
		_debug_mask_terrain.queue_free()
		_debug_mask_terrain = null

	if _cached_textures.is_empty():
		return
	var depth_img: Image = (_cached_textures["scene_depth"] as ImageTexture).get_image()
	var res := TEX_RES
	var cell_size := capture_size / float(res)
	var half := capture_size / 2.0

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	for y in range(res):
		for x in range(res):
			var px := Vector2i(x, y)
			var h := max_height - depth_img.get_pixelv(px).r + 0.2
			var rock_v := 0.0
			var tree_v := 0.0
			var bush_v := 0.0
			if _current_rock_mask_img != null:
				rock_v = clampf(_current_rock_mask_img.get_pixelv(px).r, 0.0, 1.0)
			if _tree_mask_image != null:
				tree_v = clampf(_tree_mask_image.get_pixelv(px).r, 0.0, 1.0)
			if _bush_mask_image != null:
				bush_v = clampf(_bush_mask_image.get_pixelv(px).r, 0.0, 1.0)
			var intensity := maxf(rock_v, maxf(tree_v, bush_v))
			var alpha := 0.6 * intensity if intensity > 0.01 else 0.02
			st.set_color(Color(rock_v, tree_v, bush_v, alpha))
			st.set_uv(Vector2(float(x) / float(res - 1), float(y) / float(res - 1)))
			st.add_vertex(Vector3(float(x) * cell_size - half, h, float(y) * cell_size - half))

	for y in range(res - 1):
		for x in range(res - 1):
			var i := y * res + x
			st.add_index(i)
			st.add_index(i + res)
			st.add_index(i + 1)
			st.add_index(i + 1)
			st.add_index(i + res)
			st.add_index(i + res + 1)

	st.generate_normals()

	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true

	_debug_mask_terrain = MeshInstance3D.new()
	_debug_mask_terrain.mesh = st.commit()
	_debug_mask_terrain.material_override = mat
	_debug_mask_terrain.name = "DebugCombinedMask"
	_debug_mask_terrain.visible = false
	_add_level_child(_debug_mask_terrain)
	print("[MeshFill] Combined mask debug terrain ready [M to toggle]")


func _toggle_mask_overlay() -> void:
	if _debug_mask_terrain != null:
		_debug_mask_terrain.queue_free()
		_debug_mask_terrain = null
		print("[MeshFill] Combined mask overlay: OFF")
		return
	if _vegetation_generated:
		_build_debug_mask_terrain()
		if _debug_mask_terrain != null:
			_debug_mask_terrain.visible = true
			print("[MeshFill] Combined mask overlay: ON (R=rock G=tree B=bush)")
	else:
		print("[MeshFill] No vegetation data. Use TEST ONLY P or the UI vegetation button first.")
