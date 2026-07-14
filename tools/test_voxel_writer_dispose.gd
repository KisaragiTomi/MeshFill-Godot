extends SceneTree

# Repro + regression guard for the editor-launch Shader/RID leak. Covers both
# teardown paths of a VoxelFieldDisplayGPU writer:
#   * orphan node  -- never added to the tree, so tree_exiting never fires and the
#                     writer reaches NOTIFICATION_PREDELETE undisposed (the bug).
#   * in-tree node -- freed while in the tree, so tree_exiting drives dispose()
#                     while everything is still alive (the intended path).
#
# PASS is asserted quantitatively (no "check stderr" honor system):
#   1. precondition: after the render-thread write ran, each writer's uniform set
#      is live on the main RenderingDevice (proves the test exercised real GPU
#      resources instead of passing vacuously);
#   2. after freeing the nodes, each writer instance itself is gone (weakref dead
#      -- the render-thread free path must not retain/leak the RefCounted);
#   3. each captured uniform set reports uniform_set_is_valid == false (the
#      dispose()/PREDELETE release chain actually freed the GPU-side resources).
# Any failed assertion exits 1. Missing main RenderingDevice still SKIPs (exit 0);
# run with --rendering-driver vulkan for the real check.

const VoxelDisplayScript := preload("res://scripts/utils/voxel_display.gd")

const WRITE_WAIT_LIMIT_FRAMES := 120
const POST_FREE_WAIT_FRAMES := 5

var _rd: RenderingDevice
var _orphan = null
var _alive = null
var _tracked: Array[Dictionary] = []  # {label: String, weak: WeakRef, uniform_set: RID}
var _frame := 0
var _phase := "wait_write"
var _freed_at_frame := 0
var _failures: Array[String] = []


func _init() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
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


func _writer_uniform_set(node) -> RID:
	if node == null or not is_instance_valid(node):
		return RID()
	var writer = node.get_meta("voxel_field_writer") if node.has_meta("voxel_field_writer") else null
	if writer == null:
		return RID()
	var us = writer.get("_uniform_set")
	return us if us is RID else RID()


func _write_completed() -> bool:
	# The compute write is deferred to the render thread; its uniform set becoming
	# live on the device marks completion (the original free-at-frame-3 heuristic
	# raced this).
	for node in [_orphan, _alive]:
		var us := _writer_uniform_set(node)
		if not us.is_valid() or not _rd.uniform_set_is_valid(us):
			return false
	return true


func _capture(label: String, node) -> void:
	if node == null or not is_instance_valid(node):
		_failures.append("%s: display node missing before capture" % label)
		return
	if not node.has_meta("voxel_field_writer"):
		_failures.append("%s: node has no voxel_field_writer meta" % label)
		return
	var writer = node.get_meta("voxel_field_writer")
	var us := _writer_uniform_set(node)
	if not us.is_valid() or not _rd.uniform_set_is_valid(us):
		_failures.append("%s: uniform set not live after write (vacuous test precondition)" % label)
	# Hold only a weakref + RID values: a strong writer ref here would keep the
	# orphan alive and suppress the PREDELETE path under test.
	_tracked.append({"label": label, "weak": weakref(writer), "uniform_set": us})


func _assert_disposed() -> void:
	if _tracked.size() != 2:
		_failures.append("expected 2 tracked writers, got %d" % _tracked.size())
	for t in _tracked:
		var label: String = t["label"]
		var weak: WeakRef = t["weak"]
		if weak.get_ref() != null:
			_failures.append("%s: writer instance still alive after node free (leaked ref)" % label)
		var us: RID = t["uniform_set"]
		if _rd.uniform_set_is_valid(us):
			_failures.append("%s: uniform set still valid after teardown (GPU resource leak)" % label)
		else:
			print("[WriterDispose] %s: writer freed, uniform set invalidated" % label)


func _finish() -> void:
	for f in _failures:
		print("[WriterDispose] FAIL ", f)
	var ok := _failures.is_empty()
	print("[WriterDispose] RESULT ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)


func _on_frame() -> void:
	_frame += 1
	match _phase:
		"wait_write":
			if _write_completed():
				_capture("orphan", _orphan)
				_capture("in_tree", _alive)
				_phase = "free"
			elif _frame > WRITE_WAIT_LIMIT_FRAMES:
				_failures.append(
					"timeout: render-thread write never produced live uniform sets (%d frames)"
					% WRITE_WAIT_LIMIT_FRAMES)
				_finish()
		"free":
			if _orphan != null and is_instance_valid(_orphan):
				_orphan.free()  # orphan: no tree_exiting -> writer PREDELETE
			_orphan = null
			if _alive != null and is_instance_valid(_alive):
				_alive.free()  # in tree: tree_exiting -> writer.dispose()
			_alive = null
			_freed_at_frame = _frame
			_phase = "wait_free"
			print("[WriterDispose] freed orphan (PREDELETE) + in-tree (tree_exiting)")
		"wait_free":
			# Run frames after the free so the render-thread RID frees execute,
			# then sync the render thread before asserting.
			if _frame >= _freed_at_frame + POST_FREE_WAIT_FRAMES:
				RenderingServer.force_sync()
				_assert_disposed()
				_finish()
