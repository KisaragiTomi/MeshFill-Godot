extends SceneTree

const SCENE_PATH := "res://demos/core-asset-semantic-probes/core-asset-semantic-probes.tscn"


func _init() -> void:
	var ok := _test_semantic_probe_scene_interaction()
	if ok:
		print("[SemanticProbeDemoInteraction] ALL TESTS PASSED")
		quit(0)
	else:
		push_error("[SemanticProbeDemoInteraction] SOME TESTS FAILED")
		quit(1)


func _test_semantic_probe_scene_interaction() -> bool:
	print("[SemanticProbeDemoInteraction] test_semantic_probe_scene_interaction...")
	var scene := load(SCENE_PATH)
	if scene == null or not scene is PackedScene:
		push_error("  FAIL: scene does not load: %s" % SCENE_PATH)
		return false
	var instance := (scene as PackedScene).instantiate()
	if instance == null:
		push_error("  FAIL: scene does not instantiate")
		return false
	instance.call("_ready")

	if instance.get_node_or_null("SemanticProbeTestModel") == null:
		push_error("  FAIL: scene did not create test model")
		instance.free()
		return false
	if not instance.has_method("get_semantic_probe_shortcuts"):
		push_error("  FAIL: scene does not expose semantic probe shortcuts")
		instance.free()
		return false
	var shortcuts: Dictionary = instance.call("get_semantic_probe_shortcuts")
	if str(shortcuts.get("build_debug", "")) != "Shift+P":
		push_error("  FAIL: build debug shortcut mismatch")
		instance.free()
		return false

	if instance.get_node_or_null("SemanticProbeDebug") != null:
		push_error("  FAIL: debug content should not exist before shortcut")
		instance.free()
		return false

	_send_shift_key(instance, KEY_P)
	var debug_root := instance.get_node_or_null("SemanticProbeDebug")
	if debug_root == null:
		push_error("  FAIL: Shift+P did not create SemanticProbeDebug")
		instance.free()
		return false
	var markers := debug_root.get_node_or_null("ProbeMarkers")
	if markers == null or markers.get_child_count() <= 0:
		push_error("  FAIL: Shift+P did not create probe markers")
		instance.free()
		return false
	var snapshot: Dictionary = instance.call("get_semantic_probe_debug_snapshot")
	if int(snapshot.get("probe_count", 0)) <= 0:
		push_error("  FAIL: debug snapshot has no probes")
		instance.free()
		return false
	var total_classified := (
		int(snapshot.get("convex_probe_count", 0)) +
		int(snapshot.get("surface_probe_count", 0)) +
		int(snapshot.get("collision_probe_count", 0))
	)
	if total_classified <= 0:
		push_error("  FAIL: debug snapshot has no classified probes")
		instance.free()
		return false
	if debug_root.get_node_or_null("DebugSummary") == null:
		push_error("  FAIL: debug summary label is missing")
		instance.free()
		return false

	_send_shift_key(instance, KEY_C)
	if instance.get_node_or_null("SemanticProbeDebug") != null:
		push_error("  FAIL: Shift+C did not clear SemanticProbeDebug")
		instance.free()
		return false

	print("  OK: test model exists, Shift+P creates debug probes, Shift+C clears them")
	instance.free()
	return true


func _send_shift_key(instance: Node, keycode: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	event.shift_pressed = true
	instance.call("_unhandled_input", event)