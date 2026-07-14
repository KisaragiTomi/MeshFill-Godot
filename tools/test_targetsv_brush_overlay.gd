extends SceneTree

const VoxelDisplayScript := preload("res://scripts/utils/voxel_display.gd")

const SCENE_PATH := "res://demos/target-sv-point-cloud-conversion-c/target-sv-point-cloud-conversion.tscn"
const FLOATS_PER_INSTANCE := 16

# Nodes (and the GPU writers they own) kept alive until the frame loop tears them
# down. Holding the writer reference here prevents it from being collected mid
# tree_exiting, and running frames after dispose() lets the render-thread RID
# frees actually execute before the process quits.
var _result_ok := true
var _pending: Array = []
var _phase := 0
var _frame := 0


func _init() -> void:
	if RenderingServer.get_rendering_device() == null:
		print("[TargetSVBrushOverlay] SKIP: no MAIN RenderingDevice (run with --rendering-driver vulkan, no --headless)")
		quit(0)
		return

	_result_ok = _test_scene_builds_guidance() and _result_ok
	_result_ok = _test_brush_tetra_gpu_direct_write() and _result_ok
	process_frame.connect(_on_frame)


func _on_frame() -> void:
	_frame += 1
	if _phase == 0:
		# Dispose each writer explicitly (still strongly referenced here), then
		# free its node. The render-thread RID frees are queued now.
		for entry in _pending:
			var writer = entry.get("writer", null)
			if writer != null:
				writer.dispose()
			var node = entry.get("node", null)
			if node != null and is_instance_valid(node):
				node.free()
		_phase = 1
		_frame = 0
		return
	# Let the queued render-thread frees run for a few frames before quitting.
	if _frame < 4:
		return
	_pending.clear()
	if _result_ok:
		print("[TargetSVBrushOverlay] ALL TESTS PASSED")
		quit(0)
	else:
		push_error("[TargetSVBrushOverlay] SOME TESTS FAILED")
		quit(1)


func _track(node: Node, meta_key: String) -> void:
	var writer = node.get_meta(meta_key) if node.has_meta(meta_key) else null
	_pending.append({"node": node, "writer": writer})


func _test_scene_builds_guidance() -> bool:
	print("[TargetSVBrushOverlay] test_scene_builds_guidance...")
	var scene := load(SCENE_PATH)
	if scene == null or not scene is PackedScene:
		push_error("  FAIL: scene does not load: %s" % SCENE_PATH)
		return false
	var instance = (scene as PackedScene).instantiate()
	if instance == null:
		push_error("  FAIL: scene does not instantiate")
		return false
	get_root().add_child(instance)
	instance.call("rebuild", true)

	var ok := true
	var target_setup := instance.get_node_or_null("DemoSetup/TargetSVSetup")
	var guidance := target_setup.get_node_or_null("TargetSVVoxels") as MultiMeshInstance3D if target_setup != null else null
	if guidance == null or guidance.multimesh == null or guidance.multimesh.instance_count <= 0:
		push_error("  FAIL: guidance box voxels were not built")
		ok = false
	elif not (guidance.multimesh.mesh is BoxMesh):
		push_error("  FAIL: guidance mesh is not a BoxMesh")
		ok = false

	# Paint a brush extent, then confirm a tetra MultiMesh appears with a
	# matching instance count, built through the GPU direct-write path.
	var initial_state: Dictionary = instance.call("get_brush_state")
	var texture_size := int(initial_state.get("texture_size", 0))
	var center := Vector2i(texture_size / 2, texture_size / 2)
	var added: bool = instance.call("paint_voxel_brush_extent_for_test", center)
	if not added:
		push_error("  FAIL: brush extent accumulation added no voxels")
		ok = false
	instance.call("_rebuild_brush_voxels")

	var brush_state: Dictionary = instance.call("get_brush_state")
	var brush_count := int(brush_state.get("brush_voxel_count", 0))
	if brush_count <= 0:
		push_error("  FAIL: brush voxel state is empty after paint")
		ok = false

	var brush := instance.get_node_or_null("BrushTetraVoxels") as MultiMeshInstance3D
	if brush == null or brush.multimesh == null:
		push_error("  FAIL: brush tetra MultiMesh was not built")
		ok = false
	else:
		if brush.multimesh.instance_count != brush_count:
			push_error("  FAIL: brush instance_count %d != painted voxel count %d" % [
				brush.multimesh.instance_count, brush_count,
			])
			ok = false
		if not (brush.multimesh.mesh is ArrayMesh):
			push_error("  FAIL: brush mesh is not an ArrayMesh (tetra)")
			ok = false
		if guidance != null and brush.multimesh.mesh == guidance.multimesh.mesh:
			push_error("  FAIL: brush and guidance share the same mesh (no visual distinction)")
			ok = false
		if not brush.multimesh.use_colors:
			push_error("  FAIL: brush MultiMesh does not use per-instance colors")
			ok = false
		if brush.multimesh.custom_aabb.size == Vector3.ZERO:
			push_error("  FAIL: brush MultiMesh has no custom AABB (would be frustum-culled)")
			ok = false
		if not brush.has_meta("voxel_brush_writer"):
			push_error("  FAIL: brush node does not retain its GPU writer")
			ok = false

	if brush != null:
		_track(brush, "voxel_brush_writer")
	if ok:
		print("  OK: guidance box + brush tetra (GPU direct-write) overlays build with matching counts")
	return ok


func _test_brush_tetra_gpu_direct_write() -> bool:
	print("[TargetSVBrushOverlay] test_brush_tetra_gpu_direct_write...")
	var xz_res := 8
	var slice_count := 4
	var brush_voxels := PackedInt32Array([
		0, 0, 0, 0,
		3, 1, 5, 0,
		7, 3, 7, 0,
	])
	var height_field := PackedFloat32Array()
	height_field.resize(xz_res * xz_res)
	for i in range(height_field.size()):
		height_field[i] = float(i % 5)

	var instance_count := brush_voxels.size() / 4
	var cell := Vector3(0.5, 0.5, 0.5)
	var aabb := AABB(Vector3(-2.0, -1.0, -2.0), Vector3(4.0, 6.0, 4.0))
	var node := VoxelDisplayScript.build_brush_tetra_gpu(
		brush_voxels,
		cell,
		aabb,
		{
			"xz_res": xz_res,
			"slice_count": slice_count,
			"capture_size": 120.0,
			"display_scale": 1.0,
			"vertical_span": 32.0,
			"height_span": 120.0,
			"brush_color": Color(1.0, 0.35, 0.08, 0.95),
			"terrain_height": height_field,
		},
		{"name": "BrushTetraVoxels", "fill": 1.0}
	)

	var ok := true
	if node == null:
		push_error("  FAIL: build_brush_tetra_gpu returned null (GPU path blocked)")
		return false
	# Parent into the tree so freeing drives tree_exiting -> writer.dispose().
	get_root().add_child(node)
	if node.multimesh == null:
		push_error("  FAIL: built node has no MultiMesh")
		ok = false
	else:
		if node.multimesh.instance_count != instance_count:
			push_error("  FAIL: instance_count %d != %d" % [node.multimesh.instance_count, instance_count])
			ok = false
		if node.multimesh.transform_format != MultiMesh.TRANSFORM_3D:
			push_error("  FAIL: MultiMesh is not TRANSFORM_3D")
			ok = false
		if not node.multimesh.use_colors:
			push_error("  FAIL: MultiMesh does not use per-instance colors")
			ok = false
		if not (node.multimesh.mesh is ArrayMesh):
			push_error("  FAIL: instance mesh is not an ArrayMesh (tetra)")
			ok = false
		if node.multimesh.custom_aabb != aabb:
			push_error("  FAIL: MultiMesh custom AABB was not applied from grid bounds")
			ok = false
	if not node.has_meta("voxel_brush_writer"):
		push_error("  FAIL: node does not retain its GPU writer (resources would be freed early)")
		ok = false

	_track(node, "voxel_brush_writer")
	if ok:
		print("  OK: %d brush instances driven by GPU direct-write tetra MultiMesh (zero readback)" % instance_count)
	return ok
