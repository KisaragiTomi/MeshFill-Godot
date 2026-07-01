extends SceneTree

## 3D Object Volume Score — GPU acceptance harness.
##
## Drives the same core pipeline as the editor-mode volume score demo
## (demos/placement-score-3d) without the viewport:
##   load+voxelize geo -> build scene field -> generate anchors ->
##   GPU two-pass score (Pass A subtile + Pass B reduce) -> readback decode.
##
## GPU subitems SKIP cleanly when no RenderingDevice (headless smoke);
## real acceptance requires --rendering-driver vulkan.

const ObjectVolumeScoreGpuScript := preload("res://scripts/object_volume_score_gpu.gd")
const DemoAssets := preload("res://scripts/utils/demo_assets.gd")
const VolumeScore3D := preload("res://scripts/utils/volume_score_3d.gd")
const AutoVoxelProfileScript := preload("res://scripts/auto_voxel_profile.gd")

const GRID_RES := 64
const GRID_HEIGHT := 16
const VOXEL_GRID_COUNT := 24
const ANCHOR_SPACING := 4


func _init() -> void:
	print("[VolumeScore3D] === GPU acceptance harness ===")
	var rd_available := RenderingServer.get_rendering_device() != null
	print("[VolumeScore3D] RenderingDevice available: %s" % str(rd_available))

	var ok := true
	ok = _test_extent_tiers() and ok
	ok = _test_rotation_sample_profile() and ok
	ok = _test_scene_voxel_scaled_sample_profile() and ok

	if not rd_available:
		print("[VolumeScore3D] GPU subitems SKIP (no RenderingDevice — headless smoke).")
		_finish(ok)
		return

	ok = _test_full_gpu_pipeline() and ok
	_finish(ok)


func _finish(ok: bool) -> void:
	if ok:
		print("[VolumeScore3D] ALL TESTS PASSED")
		quit(0)
	else:
		push_error("[VolumeScore3D] SOME TESTS FAILED")
		quit(1)


func _test_extent_tiers() -> bool:
	print("[VolumeScore3D] test_extent_tiers...")
	var cases := [
		[0.05, 0, 1, 1, 1],
		[0.30, 1, 4, 1, 64],
		[1.00, 3, 12, 8, 1728],
		[2.00, 5, 20, 27, 8000],
		[3.00, 7, 28, 64, 21952],
		[10.0, 8, 32, 64, ObjectVolumeScoreGpuScript.MAX_VARIANTS_PER_ROTATION],
	]
	for c in cases:
		var ext: Dictionary = ObjectVolumeScoreGpuScript.compute_extent_params(c[0])
		if int(ext["tier"]) != int(c[1]) or int(ext["sample_extent"]) != int(c[2]) \
				or int(ext["subtile_count"]) != int(c[3]) \
				or int(ext["max_variant_count"]) != int(c[4]):
			push_error("  FAIL: size=%.2f -> %s, expected tier=%d ext=%d groups=%d variants=%d" % [
				c[0], str(ext), c[1], c[2], c[3], c[4]])
			return false
	print("  PASS: 6 extent tiers cap sample variants at 32^3")
	return true


func _test_rotation_sample_profile() -> bool:
	print("[VolumeScore3D] test_rotation_sample_profile...")
	var coords: Array[Vector3i] = []
	for z in range(5):
		for x in range(2, 5):
			coords.append(Vector3i(x, 0, z))
	var footprint := _make_test_footprint(Vector3i(7, 1, 5), Vector3i(3, 0, 2), coords)
	# 场景单位剖面：令 cell_size == 场景 voxel == 1，使采样偏移保持整数对齐，
	# 这样随 yaw 变化的 span 仍然精确可断言。
	footprint["cell_size"] = 1.0
	footprint["aabb_min"] = Vector3.ZERO
	footprint["aabb_size"] = Vector3(7.0, 1.0, 5.0)
	footprint["pivot_local"] = Vector3(3.5, 0.0, 2.5)
	var profile := ObjectVolumeScoreGpuScript.build_rotation_sample_profile(footprint, Vector3.ONE)
	if not bool(profile.get("ok", false)):
		push_error("  FAIL: sample profile not ok: %s" % str(profile))
		return false
	var counts: PackedInt32Array = profile.get("sample_counts", PackedInt32Array())
	if counts.size() < ObjectVolumeScoreGpuScript.ROTATION_SLOTS:
		push_error("  FAIL: sample counts missing rotation slots")
		return false
	if counts[0] != coords.size() or counts[3] != coords.size():
		push_error("  FAIL: expected exact valid sample counts, got slot0=%d slot3=%d" % [
			counts[0], counts[3]])
		return false
	if int(profile.get("max_sample_count", 0)) > ObjectVolumeScoreGpuScript.MAX_VARIANTS_PER_ROTATION:
		push_error("  FAIL: profile exceeded 32^3 variant cap")
		return false
	var bounds: Array = profile.get("bounds_by_slot", [])
	if bounds.size() < 4 or not bounds[0] is Dictionary or not bounds[3] is Dictionary:
		push_error("  FAIL: rotation bounds missing")
		return false
	var span0: Vector3i = (bounds[0] as Dictionary).get("span", Vector3i.ZERO)
	var span3: Vector3i = (bounds[3] as Dictionary).get("span", Vector3i.ZERO)
	if span0 != Vector3i(3, 1, 5) or span3 != Vector3i(5, 1, 3):
		push_error("  FAIL: rotation bounds should follow yaw, got slot0=%s slot3=%s" % [
			str(span0), str(span3)])
		return false
	print("  PASS: rotation-dependent sample bounds use valid footprint samples only")
	return true


func _test_scene_voxel_scaled_sample_profile() -> bool:
	print("[VolumeScore3D] test_scene_voxel_scaled_sample_profile...")
	var coords: Array[Vector3i] = []
	for y in range(2):
		for z in range(5):
			for x in range(10):
				coords.append(Vector3i(x, y, z))
	var footprint := _make_test_footprint(Vector3i(10, 2, 5), Vector3i(5, 0, 2), coords)
	footprint["cell_size"] = 0.1
	footprint["aabb_min"] = Vector3.ZERO
	footprint["aabb_size"] = Vector3(1.0, 0.2, 0.5)
	footprint["pivot_local"] = Vector3(0.5, 0.0, 0.25)
	var scene_profile := ObjectVolumeScoreGpuScript.build_rotation_sample_profile(
		footprint,
		Vector3(0.5, 0.5, 0.5)
	)
	if not bool(scene_profile.get("ok", false)):
		push_error("  FAIL: scene profile not ok: %s" % str(scene_profile))
		return false
	var scene_bounds: Array = scene_profile.get("bounds_by_slot", [])
	if scene_bounds.is_empty():
		push_error("  FAIL: missing profile bounds")
		return false
	var scene_span: Vector3i = (scene_bounds[0] as Dictionary).get("span", Vector3i.ZERO)
	if scene_span != Vector3i(3, 1, 1):
		push_error("  FAIL: scene-scaled profile should follow asset bounds, got %s" % str(scene_span))
		return false
	if int(scene_profile.get("max_sample_count", 0)) >= coords.size():
		push_error("  FAIL: scene-scaled profile did not compact high-res asset samples")
		return false
	print("  PASS: scene voxel sample profile follows asset bounds instead of asset voxel count")
	return true


func _make_test_footprint(grid: Vector3i, pivot: Vector3i, coords: Array[Vector3i]) -> Dictionary:
	var voxel_count := grid.x * grid.y * grid.z
	var props := PackedFloat32Array()
	props.resize(voxel_count * 4)
	# 采样来源为 descriptor voxel_profile.collision；每个 coord 烘成一条 point collision sample。
	var collision_samples: Array[Dictionary] = []
	for coord in coords:
		var idx := coord.x + grid.x * (coord.z + grid.z * coord.y)
		if idx < 0 or idx >= voxel_count:
			continue
		props[idx * 4] = 1.0
		props[idx * 4 + 1] = 1.0
		props[idx * 4 + 2] = 1.0
		props[idx * 4 + 3] = 1.0
		collision_samples.append(AutoVoxelProfileScript.make_collision_sample(coord, 1.0, 1.0))
	var voxel_profile := AutoVoxelProfileScript.new()
	voxel_profile.color = Color.WHITE
	voxel_profile.complexity = 1.0
	voxel_profile.collision = collision_samples
	return {
		"grid": grid,
		"pivot": pivot,
		"props_bytes": props.to_byte_array(),
		"color": Color.WHITE,
		"world_aabb_longest": 1.0,
		"voxel_profile": voxel_profile,
	}


func _test_full_gpu_pipeline() -> bool:
	print("[VolumeScore3D] test_full_gpu_pipeline...")

	var scene_fields := VolumeScore3D.build_scene_fields(
		GRID_RES,
		GRID_HEIGHT,
		VolumeScore3D.procedural_terrain(GRID_RES, GRID_RES)
	)
	var assets := _load_and_voxelize(scene_fields.get("voxel_size", Vector3.ZERO))
	if assets.is_empty():
		push_error("  FAIL: no assets voxelized")
		return false

	var footprints: Array[Dictionary] = []
	for a in assets:
		footprints.append(a["footprint"])

	var terrain_height: PackedFloat32Array = scene_fields.get("terrain_height", PackedFloat32Array())
	var anchors := VolumeScore3D.generate_anchors(scene_fields, terrain_height, ANCHOR_SPACING)
	print("[VolumeScore3D] anchors=%d spacing=%d" % [anchors.size(), ANCHOR_SPACING])
	if anchors.is_empty():
		push_error("  FAIL: no anchors generated")
		return false

	var t0 := Time.get_ticks_msec()
	var scorer = ObjectVolumeScoreGpuScript.new()
	var results := scorer.score_all_assets(scene_fields, footprints, anchors)
	scorer.dispose()
	var elapsed := Time.get_ticks_msec() - t0

	if results.size() != footprints.size():
		push_error("  FAIL: results=%d != assets=%d" % [results.size(), footprints.size()])
		return false

	var any_valid := false
	var total_valid := 0
	for r_idx in range(results.size()):
		var r: Dictionary = results[r_idx]
		if not bool(r.get("ok", false)):
			push_error("  FAIL: asset %d not ok: %s" % [r_idx, str(r.get("reason", "?"))])
			return false
		var per_anchor: Array = r.get("anchor_results", [])
		if per_anchor.size() != anchors.size():
			push_error("  FAIL: asset %d anchor_results=%d != %d" % [
				r_idx, per_anchor.size(), anchors.size()])
			return false
		var variant_count := int(r.get("sample_variant_count", -1))
		var group_count := int(r.get("sample_group_count", -1))
		if variant_count <= 0 or variant_count > ObjectVolumeScoreGpuScript.MAX_VARIANTS_PER_ROTATION:
			push_error("  FAIL: asset %d invalid variant count %d" % [r_idx, variant_count])
			return false
		if group_count <= 0 or group_count > ObjectVolumeScoreGpuScript.MAX_SAMPLE_GROUPS:
			push_error("  FAIL: asset %d invalid sample group count %d" % [r_idx, group_count])
			return false
		var valid_count := 0
		var max_score := -1.0
		for ar in per_anchor:
			if ar is Dictionary and bool(ar.get("valid", false)):
				valid_count += 1
				any_valid = true
				var s: float = ar.get("score", -1.0)
				if s > max_score:
					max_score = s
		total_valid += valid_count
		var name := DemoAssets.asset_name(r_idx, str(r_idx))
		print("  [%d] %-8s variants=%d groups=%d extent=%d valid=%d/%d max_score=%.4f" % [
			r_idx, name, variant_count, group_count, int(r.get("sample_extent", -1)),
			valid_count, per_anchor.size(), max_score])

	print("  GPU score: %d assets x %d anchors in %d ms (total valid samples=%d)" % [
		footprints.size(), anchors.size(), elapsed, total_valid])

	if not any_valid:
		push_error("  FAIL: no valid score samples produced (GPU pipeline produced empty output)")
		return false

	if not _test_anchor_topk(results, assets, anchors.size()):
		return false

	print("  PASS: full GPU pipeline dispatched Pass A + Pass B, scores read back")
	return true


func _load_and_voxelize(scene_voxel_size: Vector3 = Vector3.ZERO) -> Array[Dictionary]:
	var loaded := VolumeScore3D.voxelize_demo_assets(
		VOXEL_GRID_COUNT,
		true,
		scene_voxel_size
	)
	var assets: Array[Dictionary] = []
	for asset in loaded.get("assets", []):
		if not asset is Dictionary:
			continue
		var a: Dictionary = asset
		var idx := assets.size()
		print("[VolumeScore3D] asset %d [%s] aabb=%.2fm voxels=%d fp_grid=%s%s" % [
			idx,
			str(a.get("name", DemoAssets.asset_name(idx))),
			float(a.get("world_longest", 0.0)),
			int(a.get("voxel_count", 0)),
			str(a.get("fp_grid", Vector3i.ZERO)),
			" (fallback box)" if bool(a.get("fallback", false)) else ""
		])
		assets.append(a)
	return assets


func _test_anchor_topk(results: Array[Dictionary], assets: Array[Dictionary], anchor_count: int) -> bool:
	print("[VolumeScore3D] test_anchor_topk...")
	var inspect_anchor := ObjectVolumeScoreGpuScript.first_anchor_with_valid_score(results, anchor_count)
	if inspect_anchor < 0:
		push_error("  FAIL: cannot find an anchor with any valid asset score")
		return false
	var top_k := mini(4, assets.size())
	var topk := ObjectVolumeScoreGpuScript.build_anchor_asset_topk(
		results, assets, inspect_anchor, top_k)
	if topk.size() != top_k:
		push_error("  FAIL: topk size=%d expected=%d" % [topk.size(), top_k])
		return false
	var previous_valid := true
	var previous_score := INF
	for i in range(topk.size()):
		var entry: Dictionary = topk[i]
		var rank := int(entry.get("rank", -1))
		if rank != i + 1:
			push_error("  FAIL: topk rank mismatch at %d: %d" % [i, rank])
			return false
		var valid := bool(entry.get("valid", false))
		var score := float(entry.get("score", -INF))
		if not previous_valid and valid:
			push_error("  FAIL: valid entry sorted after invalid entry")
			return false
		if valid and previous_valid and score > previous_score + 0.0001:
			push_error("  FAIL: topk scores not descending")
			return false
		previous_valid = valid
		previous_score = score
		print("  anchor %d rank %d: [%d] %s score=%.4f valid=%s yaw=%.1f slot=%d" % [
			inspect_anchor,
			rank,
			int(entry.get("asset_index", -1)),
			str(entry.get("asset_name", "?")),
			score,
			str(valid),
			float(entry.get("yaw", 0.0)),
			int(entry.get("rotation_slot", -1)),
		])
	print("  PASS: anchor top-k entries expose per-asset score details")
	return true
