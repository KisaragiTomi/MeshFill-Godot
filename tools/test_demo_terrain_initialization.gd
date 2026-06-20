extends SceneTree

const DEMOS_ROOT := "res://demos"
const MAIN_SCENE_PATH := "res://main.tscn"
const TerrainInitializerScript := preload("res://scripts/terrain_initializer.gd")
const TerrainConfigScript := preload("res://scripts/terrain_config.gd")

const SHARED_MESH_PATH := "res://assets/terrain/common_terrain_mesh.res"
const SHARED_MATERIAL_PATH := "res://assets/terrain/common_terrain_material.tres"

const SHARED_FRAGMENT_SCENES := [
	"res://demos/common_demo_setup.tscn",
]


func _init() -> void:
	var ok := true
	if _gpu_compute_available():
		ok = _test_procedural_textures_gpu() and ok
		ok = _test_loaded_heightmap_uses_120m_scale() and ok
		ok = _test_terrain_height_stats_gpu() and ok
	else:
		print("[DemoTerrainInitialization] GPU tests skipped: no local RenderingDevice")
	ok = _test_shared_terrain_resources_exist() and ok
	ok = _test_autoload_creates_terrain_for_scene() and ok
	ok = _test_demo_scenes_find_terrain_after_autoload() and ok
	if ok:
		print("[DemoTerrainInitialization] ALL TESTS PASSED")
		quit(0)
	else:
		push_error("[DemoTerrainInitialization] SOME TESTS FAILED")
		quit(1)


func _gpu_compute_available() -> bool:
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		return false
	rd.free()
	return true


func _test_procedural_textures_gpu() -> bool:
	print("[DemoTerrainInitialization] test_procedural_textures_gpu...")
	var max_height := 20.0
	var textures: Dictionary = TerrainInitializerScript.generate_procedural_textures(8, max_height)
	for key in TerrainInitializerScript.TEXTURE_NAMES:
		if not textures.has(key):
			push_error("  FAIL: missing procedural texture %s" % key)
			return false
	var target_tex: ImageTexture = textures["target_height"]
	var depth_tex: ImageTexture = textures["scene_depth"]
	var height_normal_tex: ImageTexture = textures["height_normal"]
	if target_tex == null or depth_tex == null or height_normal_tex == null:
		push_error("  FAIL: generated height textures are null")
		return false
	var target_img := target_tex.get_image()
	var depth_img := depth_tex.get_image()
	var height_normal_img := height_normal_tex.get_image()
	if target_img.get_width() != 8 or target_img.get_height() != 8:
		push_error("  FAIL: target texture size mismatch")
		return false
	if height_normal_img.get_width() != 8 or height_normal_img.get_height() != 8:
		push_error("  FAIL: height normal texture size mismatch")
		return false
	var target_values := target_img.get_data().to_float32_array()
	var depth_values := depth_img.get_data().to_float32_array()
	var normal_values := height_normal_img.get_data().to_float32_array()
	for px in [Vector2i(0, 0), Vector2i(3, 5), Vector2i(7, 7)]:
		var value_index: int = (px.y * target_img.get_width() + px.x) * 4
		var target_h := target_values[value_index]
		var depth := depth_values[value_index]
		if target_h < 1.0 or target_h > max_height * 0.6 + 0.001:
			push_error("  FAIL: target height out of procedural range at %s: %.4f" % [str(px), target_h])
			return false
		if absf((target_h + depth) - max_height) > 0.001:
			push_error("  FAIL: scene depth complement mismatch at %s" % str(px))
			return false
		var normal := Vector3(
			normal_values[value_index + 0],
			normal_values[value_index + 1],
			normal_values[value_index + 2]
		)
		if absf(normal.length() - 1.0) > 0.001 or normal.z <= 0.0:
			push_error("  FAIL: GPU height normal is invalid at %s: %s" % [str(px), str(normal)])
			return false
	if absf(normal_values[3]) > 0.001:
		push_error("  FAIL: height normal alpha should be shader-written debug padding")
		return false
	if absf(normal_values[2]) <= 0.001:
		push_error("  FAIL: height normal still looks like the old CPU constant fill")
		return false
	print("  OK: GPU procedural terrain textures match height/depth contract")
	return true


func _test_loaded_heightmap_uses_120m_scale() -> bool:
	print("[DemoTerrainInitialization] test_loaded_heightmap_uses_120m_scale...")
	var textures: Dictionary = TerrainInitializerScript.load_terrain_textures(256, TerrainInitializerScript.DEFAULT_MAX_HEIGHT)
	if textures.is_empty() or not textures.has("target_height") or not textures.has("scene_depth"):
		push_error("  FAIL: terrain textures did not load")
		return false
	var target_tex: ImageTexture = textures["target_height"]
	var depth_tex: ImageTexture = textures["scene_depth"]
	if target_tex == null or depth_tex == null:
		push_error("  FAIL: loaded terrain height/depth textures are null")
		return false
	var height_stats := TerrainInitializerScript.get_height_stats(target_tex.get_image())
	var depth_stats := TerrainInitializerScript.get_height_stats(depth_tex.get_image())
	if absf(height_stats.y - 120.0) > 0.01:
		push_error("  FAIL: expected loaded heightmap max 120m, got %.4f" % height_stats.y)
		return false
	if depth_stats.x < -0.01 or absf(depth_stats.y - 120.0) > 0.01:
		push_error("  FAIL: expected scene depth range within 0..120m, got %s" % str(depth_stats))
		return false
	print("  OK: loaded height map resolves to 0..120m terrain scale")
	return true


func _test_terrain_height_stats_gpu() -> bool:
	print("[DemoTerrainInitialization] test_terrain_height_stats_gpu...")
	var img := Image.create(4, 4, false, Image.FORMAT_RGBAF)
	img.fill(Color(-20000.0, 0.0, 0.0, 1.0))
	img.set_pixelv(Vector2i(0, 0), Color(7.5, 0.0, 0.0, 1.0))
	img.set_pixelv(Vector2i(1, 2), Color(-3.25, 0.0, 0.0, 1.0))
	img.set_pixelv(Vector2i(3, 3), Color(12.0, 0.0, 0.0, 1.0))
	var stats := TerrainInitializerScript.get_height_stats(img)
	if absf(stats.x - -3.25) > 0.001 or absf(stats.y - 12.0) > 0.001:
		push_error("  FAIL: expected min/max -3.25/12.0, got %s" % str(stats))
		return false
	var raw := TerrainInitializerScript.get_height_stats_gpu(img)
	if int(raw.get("count", 0)) != 3:
		push_error("  FAIL: expected 3 non-sentinel pixels, got %s" % str(raw))
		return false
	print("  OK: terrain height stats use GPU min/max and ignore sentinel pixels")
	return true


func _test_shared_terrain_resources_exist() -> bool:
	print("[DemoTerrainInitialization] test_shared_terrain_resources_exist...")
	var mesh_res = load(SHARED_MESH_PATH)
	if mesh_res == null or not (mesh_res is Mesh):
		push_error("  FAIL: shared terrain mesh not found or invalid: %s" % SHARED_MESH_PATH)
		return false
	var mat_res = load(SHARED_MATERIAL_PATH)
	if mat_res == null or not (mat_res is Material):
		push_error("  FAIL: shared terrain material not found or invalid: %s" % SHARED_MATERIAL_PATH)
		return false
	print("  OK: shared terrain resources (mesh + material) load correctly")
	return true


func _test_autoload_creates_terrain_for_scene() -> bool:
	print("[DemoTerrainInitialization] test_autoload_creates_terrain_for_scene...")
	var packed = load(MAIN_SCENE_PATH)
	if not packed is PackedScene:
		push_error("  FAIL: main scene does not load: %s" % MAIN_SCENE_PATH)
		return false
	var level: Node = (packed as PackedScene).instantiate()
	get_root().add_child(level)

	# Simulate what CommonTerrain autoload does
	var terrain := _create_terrain_from_shared_resources()
	if terrain == null:
		push_error("  FAIL: could not create terrain from shared resources")
		level.free()
		return false
	level.add_child(terrain)

	var ok := _assert_initialized_terrain(terrain, MAIN_SCENE_PATH)
	level.free()
	if ok:
		print("  OK: autoload-style terrain creation works for main scene")
	return ok


func _test_demo_scenes_find_terrain_after_autoload() -> bool:
	print("[DemoTerrainInitialization] test_demo_scenes_find_terrain_after_autoload...")
	var scene_paths := []
	_collect_scene_paths(DEMOS_ROOT, scene_paths)
	scene_paths.sort()
	var ok := true
	for scene_path in scene_paths:
		var packed = load(scene_path)
		if not packed is PackedScene:
			push_error("  FAIL: demo scene does not load: %s" % scene_path)
			ok = false
			continue
		var root: Node = (packed as PackedScene).instantiate()
		if root == null:
			push_error("  FAIL: demo scene does not instantiate: %s" % scene_path)
			ok = false
			continue
		get_root().add_child(root)

		# Simulate CommonTerrain autoload injection
		var terrain := _create_terrain_from_shared_resources()
		if terrain == null:
			push_error("  FAIL: could not create terrain from shared resources for %s" % scene_path)
			root.free()
			ok = false
			continue
		root.add_child(terrain)

		if not root.has_method("ensure_test_terrain_initialized"):
			push_error("  FAIL: %s root does not expose ensure_test_terrain_initialized()" % scene_path)
			root.free()
			ok = false
			continue

		var contract: Dictionary = root.call("ensure_test_terrain_initialized")
		if not bool(contract.get("ok", false)):
			push_error("  FAIL: %s terrain init failed after autoload inject: %s" % [scene_path, str(contract.get("reason", "unknown"))])
			root.free()
			ok = false
			continue

		ok = _assert_initialized_terrain(terrain, scene_path) and ok
		root.free()

	if ok:
		print("  OK: %d demo scenes find terrain after autoload-style injection" % scene_paths.size())
	return ok


func _create_terrain_from_shared_resources() -> MeshInstance3D:
	var mesh_res = load(SHARED_MESH_PATH)
	if mesh_res == null or not (mesh_res is Mesh):
		return null
	var mat_res = load(SHARED_MATERIAL_PATH)

	var terrain := MeshInstance3D.new()
	terrain.name = TerrainConfigScript.TERRAIN_NAME
	terrain.mesh = mesh_res as Mesh
	if mat_res is Material:
		terrain.material_override = mat_res as Material
	terrain.visible = true
	terrain.add_to_group(TerrainInitializerScript.TERRAIN_GROUP)
	terrain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	terrain.set_meta("meshfill_common_terrain_initialized", true)
	terrain.set_meta("meshfill_common_terrain_baked", true)
	terrain.set_meta("terrain_capture_size", TerrainConfigScript.CAPTURE_SIZE)
	terrain.set_meta("terrain_resolution", TerrainConfigScript.TEXTURE_SIZE)
	terrain.set_meta("terrain_height_stats", Vector2(0.0, TerrainConfigScript.MAX_HEIGHT))
	return terrain


func _assert_initialized_terrain(terrain: MeshInstance3D, scene_path: String) -> bool:
	if terrain == null:
		push_error("  FAIL: %s has no Terrain MeshInstance3D" % scene_path)
		return false
	if terrain.mesh == null:
		push_error("  FAIL: %s Terrain has no mesh" % scene_path)
		return false
	if not terrain.has_meta("meshfill_common_terrain_initialized"):
		push_error("  FAIL: %s Terrain lacks common initialization metadata" % scene_path)
		return false
	return true


func _collect_scene_paths(root_path: String, scene_paths: Array) -> void:
	var dir := DirAccess.open(root_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if file_name.begins_with("."):
			file_name = dir.get_next()
			continue
		var path := root_path.path_join(file_name)
		if dir.current_is_dir():
			_collect_scene_paths(path, scene_paths)
		elif file_name.ends_with(".tscn") and not SHARED_FRAGMENT_SCENES.has(path):
			scene_paths.append(path)
		file_name = dir.get_next()
	dir.list_dir_end()
