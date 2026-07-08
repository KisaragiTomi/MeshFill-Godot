extends SceneTree

# Repro + regression guard for the editor-launch Shader/RID leak. Covers both
# teardown paths of a VoxelFieldDisplayGPU writer:
#   * orphan node  -- never added to the tree, so tree_exiting never fires and the
#                     writer reaches NOTIFICATION_PREDELETE undisposed (the bug).
#   * in-tree node -- freed while in the tree, so tree_exiting drives dispose()
#                     while everything is still alive (the intended path).
# After the fix BOTH must show NO dispose error, NO invalid-ID free, NO leaked RIDs.

const VoxelDisplayScript := preload("res://scripts/utils/voxel_display.gd")

var _orphan = null
var _alive = null
var _frame := 0


func _init() -> void:
	if RenderingServer.get_rendering_device() == null:
		print("[WriterDispose] SKIP: no MAIN RenderingDevice (run with --rendering-driver vulkan)")
		quit(0)
		return
	print("[WriterDispose] === writer dispose repro (orphan + in-tree) ===")
	_orphan = _build("OrphanVoxels")
	_alive = _build("AliveVoxels")
	if _alive != null:
		# In the tree: freeing it later drives tree_exiting -> writer.dispose().
		get_root().add_child(_alive)
	print("[WriterDispose] built orphan + in-tree writers")
	process_frame.connect(_on_frame)


func _build(node_name: String):
	var xz_res := 4
	var slice_count := 2
	var voxel_count := xz_res * xz_res * slice_count
	var occ := PackedFloat32Array()
	occ.resize(voxel_count)
	for i in range(voxel_count):
		occ[i] = 1.0
	var color := PackedFloat32Array()
	color.resize(voxel_count * 4)
	for i in range(color.size()):
		color[i] = 1.0
	var fields := {"occupancy": occ, "color_rgba": color}
	var params := {
		"xz_res": xz_res, "slice_count": slice_count, "view_mode": 0,
		"capture_size": 10.0, "display_scale": 1.0, "vertical_span": 4.0,
		"height_span": 10.0, "threshold": 0.0,
	}
	var aabb := AABB(Vector3(-5, -1, -5), Vector3(10, 6, 10))
	var node = VoxelDisplayScript.build_field_gpu(
		voxel_count, Vector3.ONE, aabb, fields, params, {"name": node_name}
	)
	if node == null:
		push_error("[WriterDispose] build_field_gpu returned null for %s" % node_name)
		quit(1)
	return node


func _on_frame() -> void:
	_frame += 1
	# Let the render-thread write run first (its self-bound callable keeps the
	# writer alive); only after that does freeing the node trigger cleanup.
	if _frame == 3:
		if _orphan != null and is_instance_valid(_orphan):
			_orphan.free()  # orphan: no tree_exiting -> writer PREDELETE
		_orphan = null
		if _alive != null and is_instance_valid(_alive):
			_alive.free()  # in tree: tree_exiting -> writer.dispose()
		_alive = null
		print("[WriterDispose] freed orphan (PREDELETE) + in-tree (tree_exiting)")
	# Run frames after the free so any render-thread RID frees actually execute.
	if _frame >= 8:
		print("[WriterDispose] done (check stderr for dispose errors / leaked RIDs)")
		quit(0)
