extends SceneTree

const MainScript := preload("res://scripts/main.gd")
const PlacementFittingGeneratorScript := preload("res://scripts/placement_fitting_generator.gd")

var _started := false
var _finished := false
var _exit_code := OK


func _process(_delta: float) -> bool:
	if _finished:
		quit(_exit_code)
		return true
	if _started:
		return false
	_started = true
	_exit_code = _run()
	_finished = true
	return false


func _run() -> int:
	if not _has_rendering_device():
		print("[PlacementFittingTest] SKIP: no RenderingDevice available for GPU-only heightfield fitting")
		return OK

	randomize()

	var main = MainScript.new()
	var textures: Dictionary = main._load_terrain_textures()
	if textures.is_empty():
		push_error("[PlacementFittingTest] Failed to load terrain textures")
		main.free()
		return FAILED

	var fitting_meshes: Array[Mesh] = []
	var assets: Array[AutoObject] = []
	main._load_cliff_data(fitting_meshes, assets)
	if assets.is_empty():
		push_error("[PlacementFittingTest] No fitting assets loaded")
		main.free()
		return FAILED

	var generator := PlacementFittingGeneratorScript.new()
	root.add_child(generator)
	generator.texture_size = main.TEX_RES
	generator.capture_size = main.capture_size
	generator.max_height = main.max_height
	generator.generate_threshold = main.generate_threshold
	generator.un_generate_threshold = main.un_generate_threshold
	generator.scene_depth_texture = textures["scene_depth"]
	generator.scene_normal_texture = textures["scene_normal"]
	generator.object_depth_texture = textures["object_depth"]
	generator.object_normal_texture = textures["object_normal"]
	generator.height_normal_texture = textures["height_normal"]
	generator.target_height_texture = textures["target_height"]
	generator.target_height_extension = main.target_height_extension
	generator.stamp_overlap = main.rock_overlap
	generator.fitting_assets = assets

	var results := generator.generate_heightfield_fit(3)
	if generator._debug_target_height_image == null or generator._debug_current_height_image == null:
		push_error("[PlacementFittingTest] Missing debug readback images")
		generator.free()
		main.free()
		return FAILED

	var min_seen_scale := INF
	var max_seen_scale := 0.0
	for result in results:
		var mesh_index := int(result.get("mesh_index", -1))
		if mesh_index < 0 or mesh_index >= assets.size():
			push_error("[PlacementFittingTest] Invalid mesh_index in result: %d" % mesh_index)
			generator.free()
			main.free()
			return FAILED
		var scale: Vector3 = result.get("scale", Vector3.ZERO)
		if scale.x <= 0.0 or scale.y <= 0.0 or scale.z <= 0.0:
			push_error("[PlacementFittingTest] Non-positive result scale: %s" % [scale])
			generator.free()
			main.free()
			return FAILED
		var asset := assets[mesh_index]
		var expected_min := minf(asset.random_scale.x, asset.random_scale.y) - 0.03
		var expected_max := maxf(asset.random_scale.x, asset.random_scale.y) + 0.03
		if scale.x < expected_min or scale.x > expected_max:
			push_error("[PlacementFittingTest] Result scale %.3f outside asset random_scale %s" % [scale.x, asset.random_scale])
			generator.free()
			main.free()
			return FAILED
		min_seen_scale = minf(min_seen_scale, scale.x)
		max_seen_scale = maxf(max_seen_scale, scale.x)

	if results.size() > 1 and max_seen_scale - min_seen_scale < 0.02:
		push_error("[PlacementFittingTest] Result scales did not vary enough: %.3f..%.3f" % [min_seen_scale, max_seen_scale])
		generator.free()
		main.free()
		return FAILED

	print("[PlacementFittingTest] assets=%d placements=%d scale=%.3f..%.3f target=%dx%d current=%dx%d" % [
		assets.size(),
		results.size(),
		min_seen_scale if results.size() > 0 else 0.0,
		max_seen_scale if results.size() > 0 else 0.0,
		generator._debug_target_height_image.get_width(),
		generator._debug_target_height_image.get_height(),
		generator._debug_current_height_image.get_width(),
		generator._debug_current_height_image.get_height(),
	])

	generator.scene_depth_texture = null
	generator.scene_normal_texture = null
	generator.object_depth_texture = null
	generator.object_normal_texture = null
	generator.height_normal_texture = null
	generator.target_height_texture = null
	generator.fitting_assets.clear()
	generator._active_fitting_assets.clear()
	generator.free()
	for asset in assets:
		if is_instance_valid(asset):
			asset.mesh = null
			asset.mesh_height_texture = null
			asset.voxel_profile = null
			asset.material_override = null
			asset.free()
	assets.clear()
	fitting_meshes.clear()
	textures.clear()
	main.free()
	return OK


func _has_rendering_device() -> bool:
	if RenderingServer.get_rendering_device() != null:
		return true
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		return false
	rd.free()
	return true

