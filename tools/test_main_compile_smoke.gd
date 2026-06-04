extends SceneTree

const MainScript := preload("res://scripts/main.gd")
const MAIN_SOURCE_PATH := "res://scripts/main.gd"


func _init() -> void:
	var ok := true
	if MainScript == null:
		push_error("[MainCompileSmoke] Failed to preload main.gd")
		ok = false
	ok = _test_main_source_has_no_retired_cpu_runtime_paths() and ok
	if not ok:
		quit(1)
		return
	print("[MainCompileSmoke] main.gd preloaded")
	print("[MainCompileSmoke] retired CPU runtime paths are blocked")
	quit(0)


func _test_main_source_has_no_retired_cpu_runtime_paths() -> bool:
	var source := _read_text(MAIN_SOURCE_PATH)
	if source.is_empty():
		push_error("[MainCompileSmoke] Failed to read %s" % MAIN_SOURCE_PATH)
		return false

	var ok := true
	for forbidden in [
		"res://scripts/scene_voxel_runtime.gd",
		"SceneVoxelRuntime",
		"res://scripts/auto_object_manager.gd",
		"AutoObjectManager",
		"scatter_from_mask(",
		"Generating vegetation (self-loop)",
		"VEG_MAX_ITERATIONS",
		"while iteration <",
		"Phase 2: Placing meshes",
	]:
		if source.find(forbidden) >= 0:
			push_error("[MainCompileSmoke] main.gd still contains retired CPU runtime term: %s" % forbidden)
			ok = false

	for required in [
		"AutoObject generation skipped",
		"legacy CPU scatter was removed",
		"AutoObjectProbePrefilterGPU + VoxelPlacementGenerator",
		"No CPU placements",
		"Runtime placement is GPU-only now",
	]:
		if source.find(required) < 0:
			push_error("[MainCompileSmoke] main.gd missing GPU-only vegetation blocked log term: %s" % required)
			ok = false

	return ok


func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	return file.get_as_text()
