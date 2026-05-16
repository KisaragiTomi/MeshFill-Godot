extends SceneTree

const GVF := preload("res://scripts/global_voxel_field.gd")
const Prefilter := preload("res://scripts/autoobject_probe_prefilter_gpu.gd")
const ProbeProfile := preload("res://scripts/semantic_probe_profile.gd")


func _init() -> void:
	var ok := true
	ok = ok and _test_dual_anchor_layers()
	if ok:
		print("[AutoObjectProbePrefilter] ALL TESTS PASSED")
		quit(0)
	else:
		push_error("[AutoObjectProbePrefilter] SOME TESTS FAILED")
		quit(1)


func _test_dual_anchor_layers() -> bool:
	print("[AutoObjectProbePrefilter] test_dual_anchor_layers...")
	var grid_size := Vector3i(16, 8, 16)
	var voxel_size := Vector3.ONE
	var field := GVF.new(grid_size, voxel_size, Vector3.ZERO)
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
	ground_asset.set_allowed_anchor_kinds([AutoObject.ANCHOR_KIND_GROUND])
	ground_asset.set_semantic_probes([
		ProbeProfile.make_probe(Vector3.ZERO, Color.WHITE, 1.0, 1.0, ProbeProfile.FLAG_COLLISION, "positive", "test")
	])

	var upper_asset := AutoObject.new()
	upper_asset.name = "upper_asset"
	upper_asset.set_pivot_variants([{"name": "middle", "offset": Vector3(0.0, 3.0, 0.0), "score_bias": 0.0}])
	upper_asset.set_semantic_probes([
		ProbeProfile.make_probe(Vector3(0.0, 3.0, 0.0), Color.WHITE, 1.0, 1.0, ProbeProfile.FLAG_COLLISION, "positive", "test")
	])

	if not upper_asset.accepts_anchor_kind(AutoObject.ANCHOR_KIND_TARGET_TOP):
		push_error("  FAIL: middle pivot asset should accept target_top anchors")
		return false
	if upper_asset.accepts_anchor_kind(AutoObject.ANCHOR_KIND_GROUND):
		push_error("  FAIL: middle pivot asset should not accept ground anchors by default")
		return false

	var prefilter := Prefilter.new()
	prefilter.min_prefilter_score = 0.9
	var result: Dictionary = prefilter.run_probe_prefilter(field, target, target_color, [ground_asset, upper_asset], field.get_dirty_tile_ids())
	var anchors: Array = result.get("anchors", [])
	var candidate_voxel_sparses: Dictionary = result.get("autoobject_candidate_voxel_sparses", {})
	if int(result.get("ground_anchor_count", 0)) <= 0:
		push_error("  FAIL: expected ground anchors")
		return false
	if int(result.get("target_top_anchor_count", 0)) <= 0:
		push_error("  FAIL: expected target_top anchors")
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
	print("  OK: anchors=%d ground=%d target_top=%d" % [
		anchors.size(),
		int(result.get("ground_anchor_count", 0)),
		int(result.get("target_top_anchor_count", 0)),
	])
	return true
