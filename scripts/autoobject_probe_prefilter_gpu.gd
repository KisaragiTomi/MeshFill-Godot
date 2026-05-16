class_name AutoObjectProbePrefilterGPU
extends RefCounted

## GPU-accelerated AutoObject probe prefilter.
## This is the only supported prefilter path. The CPU fallback was removed
## because anchor_count * asset_count * probe_count is too expensive for
## GDScript and can stall large scenes.
##
## Uses 4 compute-shader dispatches:
##   1. collect_sv_anchors        — find ground + target_top anchor voxels
##   2. score_anchor_asset_probes — score each anchor×asset probe set (Pass A)
##   3. select_anchor_topk        — per-anchor top-K asset selection   (Pass B)
##   4. reduce_anchor_topk_to_voxel_regions — aggregate to per-asset voxel-region votes

const SemanticProbeProfileScript := preload("res://scripts/semantic_probe_profile.gd")

const TILE_SIZE := 8
const MAX_ASSETS := 256
const TOPK := 4
const ANCHOR_KIND_GROUND := 0
const ANCHOR_KIND_TARGET_TOP := 1
const ANCHOR_CAPACITY := 65536

var anchor_topk: int = 4
var max_scene_occupancy: float = 0.15
var max_collision_occupancy: float = 0.05
var min_support: float = 0.25
var min_target_interest: float = 0.01
var min_prefilter_score: float = 0.35

# RenderingDevice handles
var _rd: RenderingDevice
var _is_local_rd: bool = false

# Shaders & pipelines
var _shader_collect: RID
var _shader_score: RID
var _shader_topk: RID
var _shader_reduce: RID
var _pipeline_collect: RID
var _pipeline_score: RID
var _pipeline_topk: RID
var _pipeline_reduce: RID


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func run_probe_prefilter(
	gvf: GlobalVoxelField,
	target_occupancy: PackedFloat32Array,
	target_color: PackedColorArray,
	autoobjects: Array,
	dirty_tile_ids: Array[int] = []
) -> Dictionary:
	if gvf == null:
		return _empty_result()
	var voxel_region_ids := dirty_tile_ids.duplicate()
	if voxel_region_ids.is_empty():
		voxel_region_ids = gvf.get_dirty_voxel_region_ids() if gvf.has_method("get_dirty_voxel_region_ids") else gvf.get_dirty_tile_ids()
	if voxel_region_ids.is_empty():
		voxel_region_ids = _all_tile_ids(gvf)
	if voxel_region_ids.is_empty():
		return _empty_result()

	# Init GPU
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		push_warning("AutoObjectProbePrefilterGPU: local RD failed, trying global")
		_rd = RenderingServer.get_rendering_device()
		_is_local_rd = false
	else:
		_is_local_rd = true
	if _rd == null:
		push_error("AutoObjectProbePrefilterGPU: no RenderingDevice available")
		return _empty_result()

	_load_shaders()
	if not _shader_collect.is_valid() or not _shader_score.is_valid() \
	   or not _shader_topk.is_valid() or not _shader_reduce.is_valid():
		_free_gpu()
		return _empty_result()

	var result := _run_gpu_pipeline(gvf, target_occupancy, target_color, autoobjects, voxel_region_ids)
	_free_gpu()
	return result


# ---------------------------------------------------------------------------
# GPU pipeline
# ---------------------------------------------------------------------------

func _run_gpu_pipeline(
	gvf: GlobalVoxelField,
	target_occupancy: PackedFloat32Array,
	target_color: PackedColorArray,
	autoobjects: Array,
	tile_ids: Array[int]
) -> Dictionary:
	var grid_size := gvf.grid_size
	var voxel_size := gvf.voxel_size
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	var tile_grid := Vector3i(
		ceili(float(grid_size.x) / float(TILE_SIZE)),
		ceili(float(grid_size.y) / float(TILE_SIZE)),
		ceili(float(grid_size.z) / float(TILE_SIZE))
	)
	var tile_count := tile_grid.x * tile_grid.y * tile_grid.z

	# ---- Pack CPU data into byte arrays ----

	var scene_data := _ensure_float_array(gvf.scene_occupancy, voxel_count)
	var collision_data := _ensure_float_array(gvf.collision_occupancy, voxel_count)
	var target_occ_data := _ensure_float_array(target_occupancy, voxel_count)
	var target_color_data := _pack_color_array_rgba8(target_color, voxel_count)

	var asset_count := mini(autoobjects.size(), MAX_ASSETS)
	var probe_pack := _pack_all_probes(autoobjects, asset_count, voxel_size)

	# ---- Create GPU buffers ----

	var scene_buf := _buf_floats(scene_data)
	var collision_buf := _buf_floats(collision_data)
	var target_occ_buf := _buf_floats(target_occ_data)
	var target_color_buf := _buf_bytes(target_color_data)
	var dirty_tile_buf := _buf_bytes(_pack_u32_array_from_int(tile_ids))
	var anchor_buf := _buf_zero(ANCHOR_CAPACITY * 16)  # uvec4 per anchor
	var anchor_count_buf := _buf_zero(4)

	var probe_data_buf := _buf_bytes(probe_pack.probe_bytes)
	var probe_range_buf := _buf_bytes(probe_pack.range_bytes)
	var anchor_mask_buf := _buf_bytes(probe_pack.mask_bytes)

	var score_buf_size := ANCHOR_CAPACITY * MAX_ASSETS * 4
	var asset_scores_buf := _buf_zero(score_buf_size)
	var topk_buf := _buf_zero(ANCHOR_CAPACITY * TOPK * 8)  # uvec2 per entry
	var voxel_region_votes_buf := _buf_zero(asset_count * tile_count * 4)

	# ---- Dispatch 1: Collect anchors ----

	_dispatch_collect(
		scene_buf, collision_buf, target_occ_buf, dirty_tile_buf,
		anchor_buf, anchor_count_buf,
		grid_size, tile_grid, tile_ids.size()
	)
	_rd.submit()
	_rd.sync()

	# Read anchor count
	var anchor_count_bytes := _rd.buffer_get_data(anchor_count_buf, 0, 4)
	var actual_anchor_count := mini(int(anchor_count_bytes.decode_u32(0)), ANCHOR_CAPACITY)
	if actual_anchor_count == 0:
		_free_buffers([scene_buf, collision_buf, target_occ_buf, target_color_buf,
			dirty_tile_buf, anchor_buf, anchor_count_buf, probe_data_buf,
			probe_range_buf, anchor_mask_buf, asset_scores_buf, topk_buf, voxel_region_votes_buf])
		return _empty_result()

	# ---- Dispatch 2: Score probes (Pass A) ----

	var anchor_grid_x := ceili(sqrt(float(actual_anchor_count)))
	var anchor_grid_y := ceili(float(actual_anchor_count) / float(anchor_grid_x))
	var asset_blocks := ceili(float(asset_count) / 16.0)

	_dispatch_score(
		anchor_buf, probe_range_buf, anchor_mask_buf, probe_data_buf,
		scene_buf, collision_buf, target_occ_buf, target_color_buf,
		asset_scores_buf,
		grid_size, voxel_size, asset_count, actual_anchor_count,
		anchor_grid_x, anchor_grid_y, asset_blocks
	)
	_rd.submit()
	_rd.sync()

	# ---- Dispatch 3: Top-K selection (Pass B) ----

	_dispatch_topk(
		asset_scores_buf, topk_buf,
		actual_anchor_count, asset_count, anchor_grid_x, anchor_grid_y
	)
	_rd.submit()
	_rd.sync()

	# ---- Dispatch 4: Voxel-region reduction ----

	_dispatch_reduce(
		anchor_buf, topk_buf, voxel_region_votes_buf,
		tile_grid, tile_count, actual_anchor_count, asset_count
	)
	_rd.submit()
	_rd.sync()

	# ---- Read back results ----

	var anchors_bytes := _rd.buffer_get_data(anchor_buf, 0, actual_anchor_count * 16)
	var votes_bytes := _rd.buffer_get_data(voxel_region_votes_buf, 0, asset_count * tile_count * 4)

	_free_buffers([scene_buf, collision_buf, target_occ_buf, target_color_buf,
		dirty_tile_buf, anchor_buf, anchor_count_buf, probe_data_buf,
		probe_range_buf, anchor_mask_buf, asset_scores_buf, topk_buf, voxel_region_votes_buf])

	return _decode_results(anchors_bytes, votes_bytes, actual_anchor_count, asset_count, tile_count, gvf)


# ---------------------------------------------------------------------------
# Dispatch helpers
# ---------------------------------------------------------------------------

func _dispatch_collect(
	scene_buf: RID, collision_buf: RID, target_occ_buf: RID,
	dirty_tile_buf: RID, anchor_buf: RID, anchor_count_buf: RID,
	grid_size: Vector3i, tile_grid: Vector3i, dirty_count: int
) -> void:
	var set0 := _rd.uniform_set_create([
		_make_uniform(0, scene_buf),
		_make_uniform(1, collision_buf),
		_make_uniform(2, target_occ_buf),
		_make_uniform(3, dirty_tile_buf),
		_make_uniform(4, anchor_buf),
		_make_uniform(5, anchor_count_buf),
	], _shader_collect, 0)

	var push := PackedByteArray()
	push.resize(48)
	push.encode_s32(0, grid_size.x)
	push.encode_s32(4, grid_size.y)
	push.encode_s32(8, grid_size.z)
	push.encode_s32(12, dirty_count)
	push.encode_s32(16, tile_grid.x)
	push.encode_s32(20, tile_grid.y)
	push.encode_s32(24, tile_grid.z)
	push.encode_s32(28, ANCHOR_CAPACITY)
	push.encode_float(32, max_scene_occupancy)
	push.encode_float(36, max_collision_occupancy)
	push.encode_float(40, min_support)
	push.encode_float(44, min_target_interest)

	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline_collect)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, dirty_count, 1, 1)
	_rd.compute_list_end()


func _dispatch_score(
	anchor_buf: RID, probe_range_buf: RID, anchor_mask_buf: RID,
	probe_data_buf: RID, scene_buf: RID, collision_buf: RID,
	target_occ_buf: RID, target_color_buf: RID, asset_scores_buf: RID,
	grid_size: Vector3i, voxel_size: Vector3, asset_count: int,
	anchor_count: int, anchor_grid_x: int, anchor_grid_y: int,
	asset_blocks: int
) -> void:
	var set0 := _rd.uniform_set_create([
		_make_uniform(0, anchor_buf),
		_make_uniform(1, probe_range_buf),
		_make_uniform(2, anchor_mask_buf),
		_make_uniform(3, probe_data_buf),
		_make_uniform(4, scene_buf),
		_make_uniform(5, collision_buf),
		_make_uniform(6, target_occ_buf),
		_make_uniform(7, target_color_buf),
		_make_uniform(8, asset_scores_buf),
	], _shader_score, 0)

	var push := PackedByteArray()
	push.resize(32)
	push.encode_s32(0, grid_size.x)
	push.encode_s32(4, grid_size.y)
	push.encode_s32(8, grid_size.z)
	push.encode_s32(12, asset_count)
	push.encode_float(16, 1.0 / maxf(voxel_size.x, 0.0001))
	push.encode_float(20, 1.0 / maxf(voxel_size.y, 0.0001))
	push.encode_float(24, 1.0 / maxf(voxel_size.z, 0.0001))
	push.encode_float(28, 0.0)  # pad
	# Second 16 bytes
	push.resize(48)
	push.encode_u32(32, anchor_count)
	push.encode_u32(36, anchor_grid_x)
	push.encode_float(40, min_prefilter_score)
	push.encode_float(44, 0.0)  # pad

	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline_score)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, anchor_grid_x, anchor_grid_y, asset_blocks)
	_rd.compute_list_end()


func _dispatch_topk(
	asset_scores_buf: RID, topk_buf: RID,
	anchor_count: int, asset_count: int,
	anchor_grid_x: int, anchor_grid_y: int
) -> void:
	var set0 := _rd.uniform_set_create([
		_make_uniform(0, asset_scores_buf),
		_make_uniform(1, topk_buf),
	], _shader_topk, 0)

	var push := PackedByteArray()
	push.resize(16)
	push.encode_u32(0, anchor_count)
	push.encode_u32(4, asset_count)
	push.encode_u32(8, anchor_grid_x)
	push.encode_float(12, min_prefilter_score)

	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline_topk)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, anchor_grid_x, anchor_grid_y, 1)
	_rd.compute_list_end()


func _dispatch_reduce(
	anchor_buf: RID, topk_buf: RID, voxel_region_votes_buf: RID,
	tile_grid: Vector3i, tile_count: int,
	anchor_count: int, asset_count: int
) -> void:
	var set0 := _rd.uniform_set_create([
		_make_uniform(0, anchor_buf),
		_make_uniform(1, topk_buf),
		_make_uniform(2, voxel_region_votes_buf),
	], _shader_reduce, 0)

	var push := PackedByteArray()
	push.resize(32)
	push.encode_s32(0, tile_grid.x)
	push.encode_s32(4, tile_grid.y)
	push.encode_s32(8, tile_grid.z)
	push.encode_s32(12, tile_count)
	push.encode_u32(16, anchor_count)
	push.encode_u32(20, asset_count)
	push.encode_u32(24, TOPK)
	push.encode_u32(28, 0)

	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline_reduce)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, 1, 1, 1)
	_rd.compute_list_end()


# ---------------------------------------------------------------------------
# Probe packing
# ---------------------------------------------------------------------------

func _pack_all_probes(autoobjects: Array, asset_count: int, voxel_size: Vector3) -> Dictionary:
	# Build flat probe buffer and per-asset probe ranges.
	# probe_range[asset_id * 2 + anchor_kind] = (start_index, probe_count)
	# anchor_kind: 0 = ground, 1 = target_top
	# mask[asset_id] = bitmask of accepted anchor kinds

	var all_probes: Array[Dictionary] = []
	var range_entries: Array = []  # array of uvec2 as [start, count]
	var masks := PackedInt32Array()
	masks.resize(asset_count)

	# Pre-allocate range_entries: asset_count * 2 slots
	range_entries.resize(asset_count * 2)
	for i in range(range_entries.size()):
		range_entries[i] = Vector2i(0, 0)

	for obj_idx in range(asset_count):
		var autoobject := autoobjects[obj_idx] as AutoObject
		if autoobject == null:
			continue

		var mask := 0
		var allowed := autoobject.get_allowed_anchor_kinds()
		for kind_str in allowed:
			if kind_str == AutoObject.ANCHOR_KIND_GROUND:
				mask |= (1 << ANCHOR_KIND_GROUND)
			elif kind_str == AutoObject.ANCHOR_KIND_TARGET_TOP:
				mask |= (1 << ANCHOR_KIND_TARGET_TOP)
		masks[obj_idx] = mask

		for anchor_kind in [ANCHOR_KIND_GROUND, ANCHOR_KIND_TARGET_TOP]:
			var kind_str := AutoObject.ANCHOR_KIND_GROUND if anchor_kind == ANCHOR_KIND_GROUND else AutoObject.ANCHOR_KIND_TARGET_TOP
			if not autoobject.accepts_anchor_kind(kind_str):
				range_entries[obj_idx * 2 + anchor_kind] = Vector2i(all_probes.size(), 0)
				continue
			var probes: Array = autoobject.get_semantic_probes(autoobject.semantic_probe_density, kind_str)
			var start := all_probes.size()
			for probe in probes:
				if probe is Dictionary:
					all_probes.append(probe)
			range_entries[obj_idx * 2 + anchor_kind] = Vector2i(start, all_probes.size() - start)

	# Pack probe data: 2 vec4 per probe = 32 bytes
	var probe_bytes := PackedByteArray()
	probe_bytes.resize(maxi(all_probes.size(), 1) * 32)
	for i in range(all_probes.size()):
		var p: Dictionary = all_probes[i]
		var offset := _vec3_from(p.get("offset", Vector3.ZERO))
		var weight := maxf(float(p.get("weight", 1.0)), 0.0)
		var rgba8 := int(p.get("expected_rgba8", 0))
		var e_coll := clampf(float(p.get("expected_collision", 0.0)), 0.0, 1.0)
		var flags := int(p.get("flags", SemanticProbeProfileScript.FLAG_COLOR | SemanticProbeProfileScript.FLAG_COMPLEXITY))
		var kind := _kind_to_uint(str(p.get("kind", "positive")))

		var base := i * 32
		probe_bytes.encode_float(base + 0, offset.x)
		probe_bytes.encode_float(base + 4, offset.y)
		probe_bytes.encode_float(base + 8, offset.z)
		probe_bytes.encode_float(base + 12, weight)
		# Second vec4: pack as float-bits
		probe_bytes.encode_u32(base + 16, rgba8)       # floatBitsToUint on GPU side
		probe_bytes.encode_float(base + 20, e_coll)
		probe_bytes.encode_u32(base + 24, flags)
		probe_bytes.encode_u32(base + 28, kind)

	# Pack range: uvec2 per entry = 8 bytes
	var range_bytes := PackedByteArray()
	range_bytes.resize(maxi(range_entries.size(), 1) * 8)
	for i in range(range_entries.size()):
		var entry: Vector2i = range_entries[i]
		range_bytes.encode_u32(i * 8 + 0, entry.x)
		range_bytes.encode_u32(i * 8 + 4, entry.y)

	# Pack masks: uint per asset = 4 bytes
	var mask_bytes := PackedByteArray()
	mask_bytes.resize(maxi(asset_count, 1) * 4)
	for i in range(asset_count):
		mask_bytes.encode_u32(i * 4, masks[i])

	return {
		"probe_bytes": probe_bytes,
		"range_bytes": range_bytes,
		"mask_bytes": mask_bytes,
		"total_probes": all_probes.size(),
	}


# ---------------------------------------------------------------------------
# Result decoding
# ---------------------------------------------------------------------------

func _decode_results(
	anchors_bytes: PackedByteArray,
	votes_bytes: PackedByteArray,
	anchor_count: int,
	asset_count: int,
	tile_count: int,
	gvf: GlobalVoxelField
) -> Dictionary:
	# Decode anchors
	var anchors: Array[Dictionary] = []
	var ground_count := 0
	var target_top_count := 0
	for i in range(anchor_count):
		var base := i * 16
		var x := int(anchors_bytes.decode_u32(base + 0))
		var y := int(anchors_bytes.decode_u32(base + 4))
		var z := int(anchors_bytes.decode_u32(base + 8))
		var kind := int(anchors_bytes.decode_u32(base + 12))
		var kind_str := AutoObject.ANCHOR_KIND_TARGET_TOP if kind == ANCHOR_KIND_TARGET_TOP else AutoObject.ANCHOR_KIND_GROUND
		if kind == ANCHOR_KIND_GROUND:
			ground_count += 1
		else:
			target_top_count += 1
		anchors.append({
			"id": i,
			"voxel_pos": Vector3i(x, y, z),
			"anchor_kind": kind_str,
		})

	# Decode voxel-region votes → per-asset sorted voxel-region lists
	var autoobject_candidate_voxel_regions: Dictionary = {}

	for asset_id in range(asset_count):
		var entries: Array[Dictionary] = []
		for tid in range(tile_count):
			var vote := votes_bytes.decode_float((asset_id * tile_count + tid) * 4)
			if vote > 0.0001:
				entries.append({"tile_id": tid, "score": vote})
		if entries.is_empty():
			continue
		entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return float(a.get("score", 0.0)) > float(b.get("score", 0.0)))
		var voxel_regions: Array[Vector3i] = []
		for entry in entries:
			voxel_regions.append(gvf.tile_id_to_pos(int(entry.get("tile_id", 0))))
		autoobject_candidate_voxel_regions[asset_id] = voxel_regions

	return {
		"anchors": anchors,
		"anchor_autoobject_topk": {},  # Not read back (GPU internal)
		"autoobject_candidate_voxel_regions": autoobject_candidate_voxel_regions,

		"ground_anchor_count": ground_count,
		"target_top_anchor_count": target_top_count,
	}


func _load_shaders() -> void:
	_shader_collect = _load_shader("res://shaders/collect_sv_anchors.glsl")
	_shader_score = _load_shader("res://shaders/score_anchor_asset_probes.glsl")
	_shader_topk = _load_shader("res://shaders/select_anchor_topk.glsl")
	_shader_reduce = _load_shader("res://shaders/reduce_anchor_topk_to_voxel_regions.glsl")
	if _shader_collect.is_valid():
		_pipeline_collect = _rd.compute_pipeline_create(_shader_collect)
	if _shader_score.is_valid():
		_pipeline_score = _rd.compute_pipeline_create(_shader_score)
	if _shader_topk.is_valid():
		_pipeline_topk = _rd.compute_pipeline_create(_shader_topk)
	if _shader_reduce.is_valid():
		_pipeline_reduce = _rd.compute_pipeline_create(_shader_reduce)


func _load_shader(path: String) -> RID:
	var spirv: RDShaderSPIRV
	var source_text := _read_compute_shader_source(path)
	if not source_text.is_empty():
		var source := RDShaderSource.new()
		source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
		source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, source_text)
		spirv = _rd.shader_compile_spirv_from_source(source)
	else:
		var shader_file := load(path) as RDShaderFile
		if shader_file != null:
			spirv = shader_file.get_spirv()
	if spirv == null:
		push_error("AutoObjectProbePrefilterGPU: failed to compile shader: " + path)
		return RID()
	var err_msg := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if err_msg != "":
		push_error("AutoObjectProbePrefilterGPU GLSL compile error [%s]: %s" % [path, err_msg])
		return RID()
	var shader := _rd.shader_create_from_spirv(spirv)
	if not shader.is_valid():
		push_error("AutoObjectProbePrefilterGPU: SPIR-V create failed: " + path)
	return shader


func _read_compute_shader_source(path: String) -> String:
	var absolute_path := ProjectSettings.globalize_path(path)
	var source_text := FileAccess.get_file_as_string(absolute_path)
	if source_text.is_empty():
		source_text = FileAccess.get_file_as_string(path)
	if source_text.is_empty():
		return ""
	var lines := source_text.split("\n")
	var filtered: Array[String] = []
	for line in lines:
		if line.strip_edges() == "#[compute]":
			continue
		filtered.append(line)
	return "\n".join(filtered)


func _make_uniform(binding: int, buffer: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform


func _buf_floats(values: PackedFloat32Array) -> RID:
	var bytes := PackedByteArray()
	bytes.resize(maxi(values.size(), 1) * 4)
	for i in range(values.size()):
		bytes.encode_float(i * 4, values[i])
	return _rd.storage_buffer_create(bytes.size(), bytes)


func _buf_bytes(bytes: PackedByteArray) -> RID:
	var safe := bytes if bytes.size() > 0 else PackedByteArray([0, 0, 0, 0])
	return _rd.storage_buffer_create(safe.size(), safe)


func _buf_zero(byte_count: int) -> RID:
	var bytes := PackedByteArray()
	bytes.resize(maxi(byte_count, 4))
	return _rd.storage_buffer_create(bytes.size(), bytes)


func _free_buffers(buffers: Array) -> void:
	for buf in buffers:
		if buf is RID and buf.is_valid():
			_rd.free_rid(buf)


func _free_gpu() -> void:
	for rid in [_pipeline_collect, _pipeline_score, _pipeline_topk, _pipeline_reduce,
				_shader_collect, _shader_score, _shader_topk, _shader_reduce]:
		if rid is RID and rid.is_valid():
			_rd.free_rid(rid)
	_pipeline_collect = RID()
	_pipeline_score = RID()
	_pipeline_topk = RID()
	_pipeline_reduce = RID()
	_shader_collect = RID()
	_shader_score = RID()
	_shader_topk = RID()
	_shader_reduce = RID()
	if _is_local_rd and _rd != null:
		_rd.free()
	_rd = null


# ---------------------------------------------------------------------------
# Utility
# ---------------------------------------------------------------------------

func _empty_result() -> Dictionary:
	return {
		"anchors": [],
		"anchor_autoobject_topk": {},
		"autoobject_candidate_voxel_regions": {},

		"ground_anchor_count": 0,
		"target_top_anchor_count": 0,
	}


func _all_tile_ids(gvf: GlobalVoxelField) -> Array[int]:
	var total := int(gvf.get_stats().get("total_tiles", 0))
	var result: Array[int] = []
	for i in range(total):
		result.append(i)
	return result


func _ensure_float_array(arr: PackedFloat32Array, expected: int) -> PackedFloat32Array:
	if arr.size() >= expected:
		return arr
	var result := PackedFloat32Array()
	result.resize(expected)
	var n := mini(arr.size(), expected)
	for i in range(n):
		result[i] = arr[i]
	return result


func _pack_u32_array_from_int(values: Array[int]) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(maxi(values.size(), 1) * 4)
	for i in range(values.size()):
		bytes.encode_u32(i * 4, values[i])
	return bytes


func _pack_color_array_rgba8(colors: PackedColorArray, voxel_count: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(maxi(voxel_count, 1) * 4)
	var n := mini(colors.size(), voxel_count)
	for i in range(n):
		var c: Color = colors[i]
		bytes.encode_u32(i * 4, _pack_rgba8(c))
	return bytes


static func _pack_rgba8(c: Color) -> int:
	var r := clampi(int(roundf(c.r * 255.0)), 0, 255)
	var g := clampi(int(roundf(c.g * 255.0)), 0, 255)
	var b := clampi(int(roundf(c.b * 255.0)), 0, 255)
	var a := clampi(int(roundf(c.a * 255.0)), 0, 255)
	return (r << 24) | (g << 16) | (b << 8) | a


func _vec3_from(value) -> Vector3:
	if value is Vector3:
		return value as Vector3
	return Vector3.ZERO


func _kind_to_uint(kind: String) -> int:
	match kind:
		"negative": return 1
		"support":  return 2
		_:          return 0  # positive


func _kind_str_to_int(kind: String) -> int:
	if kind == AutoObject.ANCHOR_KIND_TARGET_TOP:
		return ANCHOR_KIND_TARGET_TOP
	return ANCHOR_KIND_GROUND
