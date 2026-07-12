extends SceneTree

const CommitterScript := preload("res://scripts/scene_voxel_committer.gd")

# Functional test for SceneVoxelFieldBuilder._stamp_collect_voxel_disc_gpu (the 3D
# voxel stamp+collect pass, reached via committer._field_builder; it replaced the
# per-slice 2D _collect_disc_pixels_gpu).
# Validates the stamped volume and the collected records against a CPU reference
# for all three compare modes. Run non-headless Vulkan:
#   godot --path . --rendering-driver vulkan --script tools/test_stamp_collect_voxel_disc.gd

const XZ := 16
const DEPTH := 3
const CX := 8
const CZ := 8
const RADIUS := 3
const VALUE := 0.5

var _failures := 0


func _init() -> void:
	print("[StampCollect] === 3D voxel stamp+collect test ===")
	var committer = CommitterScript.new(64, 10.0, true)
	if not committer._gpu_ready:
		push_error("[StampCollect] GPU not ready; run with --rendering-driver vulkan.")
		quit(1)
		return

	# Slice prior values: empty, occupied-above, occupied-below the stamp value.
	var prior := [0.0, 0.6, 0.3]

	_run_case(committer, 0, prior, [true, false, true])  # grew: value > prev
	_run_case(committer, 1, prior, [true, true, true])   # always
	_run_case(committer, 2, prior, [true, false, true])  # source compare

	if _failures == 0:
		print("[StampCollect] ALL CHECKS PASSED")
		quit(0)
	else:
		push_error("[StampCollect] %d CHECK(S) FAILED" % _failures)
		quit(1)


func _make_slices(prior: Array) -> Array:
	var slices: Array = []
	for s in range(DEPTH):
		var img := Image.create(XZ, XZ, false, Image.FORMAT_RF)
		img.fill(Color(float(prior[s]), 0.0, 0.0, 0.0))
		slices.append(img)
	return slices


# Returns { "slices_should_record": Array[bool] per slice, "stamped": expected
# stamped value per slice for disc cells, "disc_cells": Array of Vector2i (x,z) }.
func _disc_cells() -> Array:
	var cells: Array = []
	for dz in range(-RADIUS, RADIUS + 1):
		for dx in range(-RADIUS, RADIUS + 1):
			if dx * dx + dz * dz > RADIUS * RADIUS:
				continue
			cells.append(Vector2i(CX + dx, CZ + dz))  # disc fully inside image
	return cells


func _run_case(committer, compare_mode: int, prior: Array, expect_record: Array) -> void:
	var slices := _make_slices(prior)
	var result: Dictionary = committer._field_builder._stamp_collect_voxel_disc_gpu(slices, Vector2i(CX, CZ), RADIUS, VALUE, compare_mode)
	var updated: Array = result.get("slices", [])
	var records: Array = result.get("records", [])
	var disc_cells := _disc_cells()

	# 1. Stamped volume: disc cells = max(prev, value); others unchanged.
	for s in range(DEPTH):
		var img: Image = updated[s]
		var expect_disc := maxf(float(prior[s]), VALUE)
		for cell in disc_cells:
			var got: float = img.get_pixel(cell.x, cell.y).r
			if absf(got - expect_disc) > 0.001:
				_fail("mode %d slice %d disc (%d,%d): got %.3f expected %.3f" % [compare_mode, s, cell.x, cell.y, got, expect_disc])
		# A known out-of-disc corner must keep the prior value.
		var corner: float = img.get_pixel(0, 0).r
		if absf(corner - float(prior[s])) > 0.001:
			_fail("mode %d slice %d corner changed: got %.3f expected %.3f" % [compare_mode, s, corner, float(prior[s])])

	# 2. Records: unique (x,z,slice) set must match expected slices' disc cells.
	var got_keys := {}
	for rec in records:
		got_keys["%d_%d_%d" % [int(rec.slice_local), int(rec.x), int(rec.z)]] = true
	var expect_keys := {}
	for s in range(DEPTH):
		if not bool(expect_record[s]):
			continue
		for cell in disc_cells:
			expect_keys["%d_%d_%d" % [s, cell.x, cell.y]] = true

	for k in expect_keys:
		if not got_keys.has(k):
			_fail("mode %d missing record %s" % [compare_mode, k])
	for k in got_keys:
		if not expect_keys.has(k):
			_fail("mode %d unexpected record %s" % [compare_mode, k])

	print("[StampCollect] mode %d: %d records, %d unique (expected %d)" % [compare_mode, records.size(), got_keys.size(), expect_keys.size()])


func _fail(msg: String) -> void:
	_failures += 1
	push_error("[StampCollect] FAIL: " + msg)
