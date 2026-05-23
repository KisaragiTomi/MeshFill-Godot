extends SceneTree

const SVR := preload("res://scripts/scene_voxel_runtime.gd")
const Prefilter := preload("res://scripts/autoobject_probe_prefilter_gpu.gd")
const ProbeProfile := preload("res://scripts/semantic_probe_profile.gd")


func _init() -> void:
	var ok := true
	ok = ok and _test_position_only_anchor_layers()
	if ok:
		print("[AutoObjectProbePrefilter] ALL TESTS PASSED")
		quit(0)
	else:
		push_error("[AutoObjectProbePrefilter] SOME TESTS FAILED")
		quit(1)


func _test_position_only_anchor_layers() -> bool:
	print("[AutoObjectProbePrefilter] test_position_only_anchor_layers...")
	var grid_size := Vector3i(16, 8, 16)
	var voxel_size := Vector3.ONE
	var field := SVR.new(grid_size, voxel_size, Vector3.ZERO)
	field.fill_ground_plane(0, 1.0)

	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var target := PackedFloat32Array()
	target.resize(voxel_count)
	var target_color := PackedColorArray()
	target_color.resize(voxel_count)
	for i in range(voxel_count):
		target_color[i] = Color(0.4, 0.4, 0.4, 1.0)

	for z in range(4, 8):
		for x in range(4, 8):
			target[field.voxel_index(Vector3i(x, 1, z))] = 1.0
			target[field.voxel_index(Vector3i(x, 4, z))] = 1.0

	var ground_asset := AutoObject.new()
	ground_asset.name = "ground_asset"
	ground_asset.set_semantic_probes([
		ProbeProfile.make_probe(Vector3.ZERO, Color.WHITE, 1.0, 1.0, ProbeProfile.FLAG_COLLISION, "positive", "test")
	])

	var upper_asset := AutoObject.new()
	upper_asset.name = "upper_asset"
	upper_asset.set_pivot_variants([{"name": "middle", "offset": Vector3(0.0, 3.0, 0.0), "score_bias": 0.0}])
	upper_asset.set_semantic_probes([
		ProbeProfile.make_probe(Vector3(0.0, 3.0, 0.0), Color.WHITE, 1.0, 1.0, ProbeProfile.FLAG_COLLISION, "positive", "test")
	])

	var prefilter := Prefilter.new()
	prefilter.min_prefilter_score = 0.9
	var result: Dictionary = prefilter.run_probe_prefilter(field, target, target_color, [ground_asset, upper_asset], field.get_dirty_tile_ids())
	var anchors: Array = result.get("anchors", [])
	var candidate_voxel_sparses: Dictionary = result.get("autoobject_candidate_voxel_sparses", {})
	if anchors.is_empty():
		push_error("  FAIL: expected position-only anchors")
		return false

	var has_ground_position := false
	var has_target_top_position := false
	for anchor in anchors:
		if not anchor is Dictionary:
			continue
		if (anchor as Dictionary).has("anchor_kind"):
			push_error("  FAIL: position-only anchor should not carry anchor_kind")
			return false
		var voxel_pos := (anchor as Dictionary).get("voxel_pos", Vector3i(-1, -1, -1)) as Vector3i
		if voxel_pos.y == 1:
			has_ground_position = true
		if voxel_pos.y == 4:
			has_target_top_position = true
	if not has_ground_position:
		push_error("  FAIL: expected supported ground-like anchor positions")
		return false
	if not has_target_top_position:
		push_error("  FAIL: expected target-top-like anchor positions")
		return false

	# GPU-only prefilter does not read back per-anchor topK. The supported
	# GDScript contract is per-asset routed voxel-region output.
	for obj_idx in [0, 1]:
		if not candidate_voxel_sparses.has(obj_idx):
			push_error("  FAIL: expected routed candidate voxel regions for asset %d" % obj_idx)
			return false
		var routed_regions: Array = candidate_voxel_sparses.get(obj_idx, [])
		if routed_regions.is_empty():
			push_error("  FAIL: empty routed candidate voxel regions for asset %d" % obj_idx)
			return false
		for voxel_sparse_pos in routed_regions:
			if not voxel_sparse_pos is Vector3i:
				push_error("  FAIL: routed candidate voxel regions must be Vector3i region positions")
				return false

	ground_asset.free()
	upper_asset.free()
	print("  OK: anchors=%d position-only ground_y=true target_top_y=true" % [
		anchors.size(),
	])
	return true
