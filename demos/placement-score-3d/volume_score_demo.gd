@tool
extends "res://scripts/core_demo_contract_fixture.gd"

## placement-score-3d — Volume-Score Provider
##
## Generates surface anchors on the REAL terrain (over the standard terrain grid), and
## registers itself with the sibling CoreSPADemo (ScenePlacementActor) so the editor toolbar
## "Anchors"/"Score" buttons and Anchor-mode click-select delegate here.
##
## Scoring: GPU fine-selection (细筛选) — per asset, one full-grid score_voxel_tile pass
## (data-driven per-dimension MATCH over the TargetSV env field) via
## VoxelPlacementGenerator.run_minimal; the per-voxel score at each anchor ranks the assets
## and the winner's REAL mesh is placed. See scoring-dimensions-design.md (Phase 2).
##
## Placed winners are the REAL descriptor mesh (never proxy boxes) — see the project
## CLAUDE.md rule "Placement / Score Demos: Render Real AssetDescriptor Assets".

const VolumeScore3D := preload("res://scripts/utils/volume_score_3d.gd")
const DemoUI := preload("res://scripts/utils/demo_ui.gd")
const TerrainConfigScript := preload("res://scripts/terrain_config.gd")
const TargetSVLoaderScript := preload("res://scripts/target_sv_loader.gd")
const SPAEditorContract := preload("res://scripts/spa_editor_contract.gd")
const VoxelPlacementGenerator := preload("res://scripts/voxel_placement_generator.gd")
const AssetDescriptorScript := preload("res://scripts/asset_descriptor.gd")

const VOXEL_DISPLAY_ANCHOR := SPAEditorContract.VOXEL_DISPLAY_ANCHOR
const VOLUME_SCORE_DISPLAY_OWNER := "volume_score"
const SELECTION_DOMAIN_ANCHOR := SPAEditorContract.SELECTION_DOMAIN_ANCHOR
const SELECTION_GEOMETRY_VOLUME_SCORE_ANCHOR := SPAEditorContract.SELECTION_GEOMETRY_VOLUME_SCORE_ANCHOR
const ANCHOR_RADIUS_MIN := 0.06

# ---- Exported Tunables -----------------------------------------------------
@export_range(8, 64, 1) var anchor_spacing: int = 32           # 锚点体素间距（在标准地形网格上）
@export_range(1, 8, 1) var selected_anchor_top_k: int = 4      # 选中锚点显示的 Top-K 资产数
@export_range(1, 24, 1) var rotation_slots: int = 12           # 每候选原点扫描的 yaw 档数
@export_range(1, 8, 1) var asset_footprint_voxels: int = 4     # 资产 footprint 最长轴的体素跨度
## 要评分/放置的真实资产（AssetDescriptor `.tres`）。场景显式声明为首选来源。
@export var placement_assets: Array[AssetDescriptor] = []
@export_dir var asset_descriptor_dir: String = "res://assets"  # 回退扫描目录
@export var auto_run_on_start := true

# ---- State -----------------------------------------------------------------
## 每资产：{descriptor, name, mesh, color, footprint_shape, aabb, material}
var _assets: Array[Dictionary] = []
var _anchors := PackedVector3Array()             # 锚点体素坐标
var _anchor_world_positions := PackedVector3Array()
var _scene_fields: Dictionary = {}
var _terrain_height := PackedFloat32Array()
## 每资产一条：{ok, asset_index, anchor_results:[{score, valid, rotation_slot, voxel}]}
var _results: Array[Dictionary] = []
var _winner_per_anchor := PackedInt32Array()     # 每锚点最佳资产索引（-1 = 无）
var _selected_anchor_idx := -1
var _selected_anchor_topk_index := 0
var _scored := false
var _elapsed_score_ms := 0.0
var _total_anchors := 0

# ---- Fine-selection (细筛选) GPU scoring state (Phase 2) --------------------
var _env_ready := false
var _env_channel_floats := PackedFloat32Array()   # voxel_count * 5: [collision, complexity, r, g, b]
var _target_field_bytes := PackedFloat32Array()    # voxel_count * 4: [r, g, b, completeness]
var _complexity_field := PackedFloat32Array()      # voxel_count(=completeness): bounds/coverage
var _collision_field := PackedFloat32Array()       # voxel_count(=collision)

# ---- Display Nodes ---------------------------------------------------------
var _hud_label: Label
var _display_root: Node3D


func _ready() -> void:
	super._ready()
	if is_scene_startup_blocked():
		return
	_setup_hud()
	_display_root = Node3D.new()
	_display_root.name = "VolumeScoreDisplay"
	# SPA 绑定需重复：编辑器刚打开组合场景时子场景可能未同步完成
	_sync_spa_bindings()
	_sync_spa_bindings.call_deferred()
	if auto_run_on_start:
		run_volume_score_pipeline.call_deferred()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_unregister_spa_volume_score_provider()


# ---- Public API — SPA provider interface -----------------------------------

## 完整管线：场景场 → 资产 footprint → 锚点 → VPG 评分 → 可视化
func run_volume_score_pipeline() -> Dictionary:
	if not Engine.is_editor_hint():
		return {"ok": false, "reason": "not_editor_hint"}
	_sync_spa_bindings()
	_ensure_scene_fields_ready()
	_ensure_assets_ready()
	_generate_anchors()
	_run_scoring()
	_build_visualization()
	_sync_spa_bindings()
	_update_hud()
	return _status(true)


## 仅生成锚点（不评分）
func generate_anchors() -> Dictionary:
	if not Engine.is_editor_hint():
		return {"ok": false, "reason": "not_editor_hint"}
	if not _ensure_scene_fields_ready():
		return {"ok": false, "reason": "scene_fields_not_ready"}
	_generate_anchors()
	_clear_scores()
	_build_visualization()
	_update_hud()
	return _status(false)


## 评分（需锚点，缺则先生成）；名字对齐 SPA 的 _call_volume_score_provider("calculate_voxel_scores")
func calculate_voxel_scores() -> Dictionary:
	if not Engine.is_editor_hint():
		return {"ok": false, "reason": "not_editor_hint"}
	if not _ensure_scene_fields_ready():
		return {"ok": false, "reason": "scene_fields_not_ready"}
	_ensure_assets_ready()
	if _anchors.is_empty():
		_generate_anchors()
	_run_scoring()
	_build_visualization()
	_update_hud()
	_notify_spa_selected_anchor_changed()
	return _status(true)


func has_volume_score_anchors() -> bool:
	return not _anchor_world_positions.is_empty()


func has_selected_anchor() -> bool:
	return _selected_anchor_idx >= 0


func get_selected_anchor_summary_text() -> String:
	if not _scored:
		return "Anchor scores: run Score"
	if _selected_anchor_idx < 0:
		return "Anchor scores: select an anchor"
	var parts: Array[String] = ["Anchor #%d" % _selected_anchor_idx]
	for entry in _selected_anchor_topk_entries():
		var score := float(entry.get("score", -INF))
		var score_text := "%.2f" % score if score > -1.0e20 else "n/a"
		var suffix := "" if bool(entry.get("valid", false)) else " invalid"
		parts.append("%s %s%s" % [str(entry.get("asset_name", "?")), score_text, suffix])
	return " | ".join(parts)


func get_selected_anchor_tooltip_text() -> String:
	return "\n".join(_selected_anchor_hud_lines())


func get_selected_anchor_record() -> Dictionary:
	if _selected_anchor_idx < 0 or _selected_anchor_idx >= _anchor_world_positions.size():
		return {}
	var record := {
		"domain": SELECTION_DOMAIN_ANCHOR,
		"geometry": SELECTION_GEOMETRY_VOLUME_SCORE_ANCHOR,
		"id": "volume_score_anchor:%d" % _selected_anchor_idx,
		"anchor_index": _selected_anchor_idx,
		"voxel_coord": _anchor_voxel(_selected_anchor_idx),
		"world_position": _anchor_world_positions[_selected_anchor_idx],
		"marker_size": _scene_fields.get("voxel_size", Vector3.ONE),
		"topk": _selected_anchor_topk_entries(),
		"selected_topk_index": _selected_anchor_topk_index,
		"summary": get_selected_anchor_summary_text(),
		"tooltip": get_selected_anchor_tooltip_text(),
	}
	# 胜出物体的红色定向包围盒（SPA 据此画 ANCHOR_SAMPLE_BOUNDS 红框）
	var sample_bounds := _selected_anchor_sample_bounds()
	if not sample_bounds.is_empty():
		record["sample_bounds"] = sample_bounds
	return record


## 选中锚点（仅置状态，不自绘）。点选与反馈由 SPA 拥有（CoreSPADemo._select_volume_score_anchor_at_position），
## provider 只出数据；SPA 拿到 record 后经其 canonical selection visual 画高亮/标签/红框。
func select_anchor(anchor_index: int) -> Dictionary:
	if not _scored:
		return {"ok": false, "reason": "scoring_not_complete"}
	if anchor_index < 0 or anchor_index >= _anchor_world_positions.size():
		return {"ok": false, "reason": "anchor_index_out_of_range"}
	_sync_spa_bindings()
	_selected_anchor_idx = anchor_index
	_selected_anchor_topk_index = 0
	_update_hud()
	_notify_spa_selected_anchor_changed()
	return {
		"ok": true,
		"anchor_index": _selected_anchor_idx,
		"selected_topk_index": _selected_anchor_topk_index,
		"topk": _selected_anchor_topk_entries(),
	}


func clear_selected_anchor() -> Dictionary:
	_selected_anchor_idx = -1
	_selected_anchor_topk_index = 0
	_update_hud()
	_notify_spa_selected_anchor_changed()
	return {"ok": true}


# ---- Data source for SPA-owned pick ---------------------------------------
# SPA 用这些数据做射线点选（胜出物体 AABB 优先，锚点小球回退），点中后调 select_anchor。

func get_anchor_world_positions() -> PackedVector3Array:
	return _anchor_world_positions


func get_anchor_marker_radius() -> float:
	return _anchor_marker_radius()


## [{anchor_index, aabb}]：每个有有效胜出物体的锚点及其世界 AABB（SPA 射线点选目标）。
func get_selectable_anchor_bounds() -> Array:
	var out: Array = []
	for i in range(_anchor_world_positions.size()):
		var aabb := _winner_world_aabb(i)
		if aabb.size.length_squared() > 0.000001:
			out.append({"anchor_index": i, "aabb": aabb})
	return out


func cycle_selected_anchor_topk(delta: int) -> Dictionary:
	if _selected_anchor_idx < 0:
		return {"ok": false, "reason": "no_selected_anchor"}
	var entries := _selected_anchor_topk_entries()
	if entries.is_empty():
		return {"ok": false, "reason": "no_topk_entries"}
	var count := entries.size()
	_selected_anchor_topk_index = ((_selected_anchor_topk_index + int(delta)) % count + count) % count
	_update_hud()
	_notify_spa_selected_anchor_changed()
	return {
		"ok": true,
		"anchor_index": _selected_anchor_idx,
		"selected_topk_index": _selected_anchor_topk_index,
		"topk": entries,
	}


# ---- Scene field / assets / anchors ----------------------------------------

func _ensure_scene_fields_ready() -> bool:
	if _scene_fields.is_empty() or _terrain_height.is_empty():
		_build_scene_fields()
	return not _scene_fields.is_empty()


## 场帧 = 标准地形网格(TerrainConfig)+ 真实地形高度(采样真实 Terrain mesh);不再自建合成场。
func _build_scene_fields() -> void:
	var tsz := TerrainConfigScript.TEXTURE_SIZE
	var slices := 16
	var capture := TerrainConfigScript.CAPTURE_SIZE
	var max_h := TerrainConfigScript.MAX_HEIGHT
	_terrain_height = VolumeScore3D.sample_terrain_height_for_node(self, tsz, tsz)
	_scene_fields = {
		"grid": Vector3i(tsz, slices, tsz),
		"voxel_size": VoxelGeneral.voxel_size_for_resolution(capture, tsz, max_h / float(slices)),
		"grid_origin": VoxelGeneral.default_grid_origin(capture),
	}


func _ensure_assets_ready() -> void:
	if not _assets.is_empty():
		return
	_assets.clear()
	for d in _load_descriptors():
		var mesh: Mesh = d.get_mesh()
		if mesh == null:
			continue
		_assets.append({
			"descriptor": d,
			"name": str(d.asset_id) if str(d.asset_id) != "" else "Asset%d" % _assets.size(),
			"mesh": mesh,
			"color": d.get_color(),
			"footprint_shape": _footprint_shape_for(mesh),
			"aabb": mesh.get_aabb(),
			"material": d.material,
		})


func _generate_anchors() -> void:
	_anchors = VolumeScore3D.generate_anchors(_scene_fields, _terrain_height, anchor_spacing)
	_anchor_world_positions = VolumeScore3D.anchor_world_positions(_scene_fields, _terrain_height, _anchors)
	_total_anchors = _anchors.size()


# ---- 细筛选 (Fine-Selection) GPU scoring -----------------------------------

## 数据驱动维度打分(design Phase 2):在 TargetSV 网格上 per asset 跑一次全网格
## score_voxel_tile(dims-mode),footprint 3D 逐体素采样环境场,读 debug_voxel 的 per-voxel
## 分并取每锚点体素分。维度=collision/complexity/color(全 MATCH)。见 scoring-dimensions-design.md。
func _run_scoring() -> void:
	_clear_scores()
	if not _ensure_target_env_ready():
		return
	if _assets.is_empty() or _anchors.is_empty():
		return
	var t0 := Time.get_ticks_msec()
	var grid: Vector3i = _scene_fields.get("grid", Vector3i.ZERO)
	var dims := _scoring_dimensions()
	var vpg = VoxelPlacementGenerator.new()
	for a in range(_assets.size()):
		var d = _assets[a].get("descriptor")
		var col: Color = _assets[a].get("color", Color.WHITE)
		var fp: Array = AssetDescriptorScript.bake_footprint(d.get_collision(), false, 1)
		if fp.is_empty():
			fp = _footprint_from_shape(_assets[a].get("footprint_shape", Vector3i.ONE))
		var profile := PackedFloat32Array([
			_mean_collision_strength(d), clampf(d.get_complexity(), 0.0, 1.0), col.r, col.g, col.b])
		var settings := {
			"asset_index": a, "asset_color": col, "rotation_slots": rotation_slots, "top_k": 1,
			"scoring_dimensions": dims, "asset_dimension_profile": profile,
			"env_channel_field_floats": _env_channel_floats, "env_channel_count": 5,
			"target_field_bytes": _target_field_bytes, "read_debug_voxel": true,
		}
		var out: Dictionary = vpg.run_minimal(_complexity_field, _collision_field, fp, grid, settings)
		var dbg: PackedFloat32Array = out.get("debug_voxel", PackedFloat32Array())
		var anchor_results: Array[Dictionary] = []
		for ai in range(_anchors.size()):
			var av := _anchor_voxel(ai)
			var vidx := av.x + grid.x * (av.z + grid.z * av.y)   # shader voxel_index order
			var score := -INF
			var base := vidx * 8 + 4                              # DEBUG_CH_PLACEMENT_SCORE
			if base >= 0 and base < dbg.size():
				score = dbg[base]
			anchor_results.append({
				"score": score, "valid": score > -1.0e17, "rotation_slot": 0, "voxel": av})
		_results.append({"ok": true, "asset_index": a, "anchor_results": anchor_results})
	if vpg.has_method("dispose"):
		vpg.dispose()
	_elapsed_score_ms = float(Time.get_ticks_msec() - t0)
	_winner_per_anchor = _compute_winners()
	_scored = true
	print("[VolumeScore] Fine-selection scored %d assets × %d anchors in %.0f ms" % [
		_assets.size(), _total_anchors, _elapsed_score_ms])


## 环境场(TargetSV)缓存:解码 TargetSV,按 voxel_index 打包 5 通道 env + 4 通道 target。
## 网格与 TargetSV(256×16×256)一致则无需重建锚点。无 TargetSV → place nothing。
func _ensure_target_env_ready() -> bool:
	if _env_ready:
		return true
	if not _ensure_scene_fields_ready():
		return false
	var meta := TargetSVLoaderScript.metadata()
	if meta.is_empty():
		push_warning("[VolumeScore] 无 TargetSV(assets/target_sv/)—— 不打分")
		return false
	var tsv_grid := Vector3i(int(meta.get("texture_size", 256)), int(meta.get("slice_count", 16)), int(meta.get("texture_size", 256)))
	var grid: Vector3i = _scene_fields.get("grid", Vector3i.ZERO)
	if grid != tsv_grid:
		push_warning("[VolumeScore] 场网格 %s != TargetSV 网格 %s;在 TargetSV 网格上重建锚点" % [grid, tsv_grid])
		_scene_fields["grid"] = tsv_grid
		grid = tsv_grid
		_generate_anchors()
	var decoded := TargetSVLoaderScript.decode()
	if not bool(decoded.get("valid", false)):
		push_warning("[VolumeScore] TargetSV 解码失败 —— 不打分")
		return false
	var voxel_count := grid.x * grid.y * grid.z
	var t_coll: PackedFloat32Array = decoded.get("target_collision", PackedFloat32Array())
	var t_comp: PackedFloat32Array = decoded.get("target_completely", PackedFloat32Array())
	var t_color: PackedColorArray = decoded.get("target_color", PackedColorArray())
	_env_channel_floats = PackedFloat32Array(); _env_channel_floats.resize(voxel_count * 5)
	_target_field_bytes = PackedFloat32Array(); _target_field_bytes.resize(voxel_count * 4)
	_complexity_field = PackedFloat32Array(); _complexity_field.resize(voxel_count)
	_collision_field = PackedFloat32Array(); _collision_field.resize(voxel_count)
	for i in range(voxel_count):
		var coll := t_coll[i] if i < t_coll.size() else 0.0
		var comp := t_comp[i] if i < t_comp.size() else 0.0
		var c: Color = t_color[i] if i < t_color.size() else Color(0, 0, 0, 0)
		var e := i * 5
		_env_channel_floats[e + 0] = coll
		_env_channel_floats[e + 1] = comp
		_env_channel_floats[e + 2] = c.r
		_env_channel_floats[e + 3] = c.g
		_env_channel_floats[e + 4] = c.b
		var f := i * 4
		_target_field_bytes[f + 0] = c.r
		_target_field_bytes[f + 1] = c.g
		_target_field_bytes[f + 2] = c.b
		# target.a gates dims-mode validity (target_coverage). Use presence = max(completeness,
		# collision) so anchors over any TargetSV content are valid (completeness alone is sparse).
		_target_field_bytes[f + 3] = maxf(comp, coll)
		_complexity_field[i] = comp
		_collision_field[i] = coll
	_env_ready = true
	return true


## 维度表(全 MATCH,通道 0..4 对应 env 5 通道):collision/complexity/color r/g/b。
## 颜色 3 通道各 ~0.34(合计 ~1.0,避免颜色相对 collision/complexity 三倍加权)。
func _scoring_dimensions() -> Array:
	return [
		{"channel": 0, "mode": 0, "weight": 1.0, "min": 0.0, "max": 1.0},
		{"channel": 1, "mode": 0, "weight": 1.0, "min": 0.0, "max": 1.0},
		{"channel": 2, "mode": 0, "weight": 0.34, "min": 0.0, "max": 1.0},
		{"channel": 3, "mode": 0, "weight": 0.34, "min": 0.0, "max": 1.0},
		{"channel": 4, "mode": 0, "weight": 0.34, "min": 0.0, "max": 1.0},
	]


## 资产 collision 画像:descriptor collision 样本 strength 均值;无剖面回退 complexity。
func _mean_collision_strength(d) -> float:
	var samples: Array = d.get_collision() if d != null and d.has_method("get_collision") else []
	if samples.is_empty():
		return clampf(d.get_complexity(), 0.0, 1.0) if d != null else 0.0
	var s := 0.0
	for e in samples:
		if e is Dictionary:
			s += clampf(float((e as Dictionary).get("collision_strength", 0.0)), 0.0, 1.0)
	return clampf(s / float(samples.size()), 0.0, 1.0)


## 无 collision 剖面时用体素跨度建一个实心 footprint(每格 strength/weight 1)。
func _footprint_from_shape(span: Vector3i) -> Array:
	var sx := maxi(span.x, 1); var sy := maxi(span.y, 1); var sz := maxi(span.z, 1)
	var fp: Array = []
	for x in range(sx):
		for y in range(sy):
			for z in range(sz):
				fp.append({
					"local_pos": Vector3i(x - int(sx / 2), y, z - int(sz / 2)),
					"collision_strength": 1.0, "flags": 0, "weight": 1.0})
	return fp


func _anchor_voxel(anchor_index: int) -> Vector3i:
	if anchor_index < 0 or anchor_index >= _anchors.size():
		return Vector3i(-1, -1, -1)
	var v := _anchors[anchor_index]
	return Vector3i(int(roundf(v.x)), int(roundf(v.y)), int(roundf(v.z)))


func _compute_winners() -> PackedInt32Array:
	var winners := PackedInt32Array()
	winners.resize(_total_anchors)
	for anchor_index in range(_total_anchors):
		var best_asset := -1
		var best_score := -INF
		for asset_index in range(_results.size()):
			var ar := _anchor_result(asset_index, anchor_index)
			if bool(ar.get("valid", false)) and float(ar.get("score", -INF)) > best_score:
				best_score = float(ar.get("score", -INF))
				best_asset = asset_index
		winners[anchor_index] = best_asset
	return winners


func _anchor_result(asset_index: int, anchor_index: int) -> Dictionary:
	if asset_index < 0 or asset_index >= _results.size():
		return {}
	var ars: Array = _results[asset_index].get("anchor_results", [])
	if anchor_index < 0 or anchor_index >= ars.size():
		return {}
	return ars[anchor_index]


## 某锚点上所有资产按分数降序（valid 优先）的 Top-K 条目
func _anchor_topk_entries(anchor_index: int, limit: int) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for asset_index in range(_results.size()):
		var ar := _anchor_result(asset_index, anchor_index)
		if ar.is_empty():
			continue
		var slot := int(ar.get("rotation_slot", 0))
		entries.append({
			"asset_index": asset_index,
			"asset_name": str(_assets[asset_index].get("name", "Asset%d" % asset_index)) if asset_index < _assets.size() else "Asset%d" % asset_index,
			"score": float(ar.get("score", -INF)),
			"valid": bool(ar.get("valid", false)),
			"rotation_slot": slot,
			"yaw": float(slot) * (360.0 / float(maxi(rotation_slots, 1))),
		})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if bool(a.valid) != bool(b.valid):
			return bool(a.valid)
		return float(a.score) > float(b.score))
	var out: Array[Dictionary] = []
	for i in range(mini(limit, entries.size())):
		var e := entries[i].duplicate()
		e["rank"] = i + 1
		out.append(e)
	return out


func _selected_anchor_topk_entries() -> Array[Dictionary]:
	var entries := _anchor_topk_entries(_selected_anchor_idx, selected_anchor_top_k)
	if not entries.is_empty():
		_selected_anchor_topk_index = clampi(_selected_anchor_topk_index, 0, entries.size() - 1)
	for i in range(entries.size()):
		entries[i]["selected"] = i == _selected_anchor_topk_index
	return entries


func _clear_scores() -> void:
	_results.clear()
	_winner_per_anchor = PackedInt32Array()
	_scored = false
	_elapsed_score_ms = 0.0
	_selected_anchor_topk_index = 0


func _status(require_scored: bool) -> Dictionary:
	var ok := _total_anchors > 0
	if require_scored:
		ok = ok and _scored
	return {"ok": ok, "anchors": _total_anchors, "scored": _scored, "asset_count": _assets.size(), "score_ms": _elapsed_score_ms}


# ---- Visualization ---------------------------------------------------------

func _build_visualization() -> void:
	if _display_root == null:
		return
	if _display_root.get_parent() == null:
		_attach_display_root_to_spa()
	for child in _display_root.get_children():
		child.queue_free()
	if _anchor_world_positions.is_empty():
		return
	if _selected_anchor_idx >= _anchor_world_positions.size():
		_selected_anchor_idx = -1
	_build_anchor_point_display()
	_build_winning_anchor_content()


func _build_anchor_point_display() -> void:
	var radius := _anchor_marker_radius()
	var marker_mesh := SphereMesh.new()
	marker_mesh.radius = radius
	marker_mesh.height = radius * 2.0
	marker_mesh.radial_segments = 8
	marker_mesh.rings = 4
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.20, 0.85, 1.0, 0.82)
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = marker_mesh
	mm.instance_count = _anchor_world_positions.size()
	for i in range(_anchor_world_positions.size()):
		mm.set_instance_transform(i, Transform3D(Basis(), _anchor_world_positions[i]))
	var points := MultiMeshInstance3D.new()
	points.name = "AnchorPoints"
	points.multimesh = mm
	points.material_override = mat
	_display_root.add_child(points)
	_register_spa_voxel_display_node(VOXEL_DISPLAY_ANCHOR, points)


## 某锚点胜出资产的放置信息（transform/winner/yaw/aabb/fit_scale）——渲染、红框 bound、
## 点选三处共用同一变换，保证「红框恰好包住放置的树」且「点树身即选中该锚点」。
## 缩放贴合 footprint box、按最优 yaw 旋转、原生 FBX 轴心贴地（cliff 半埋、植物立于地面）。无有效胜者返回空字典。
func _winner_placement(anchor_index: int) -> Dictionary:
	var winner := _winner_per_anchor[anchor_index] if anchor_index >= 0 and anchor_index < _winner_per_anchor.size() else -1
	if winner < 0 or winner >= _assets.size():
		return {}
	var ar := _anchor_result(winner, anchor_index)
	if not bool(ar.get("valid", false)):
		return {}
	var mesh: Mesh = _assets[winner].get("mesh", null)
	if mesh == null:
		return {}
	var aabb: AABB = _assets[winner].get("aabb", mesh.get_aabb())
	# 真实 1:1 FBX 缩放，与 asset-descriptor-demo 一致（node.scale = Vector3.ONE）：不再按
	# footprint box 归一化每个资产——那会把小资产（叶）放大得比大资产（崖）更多，丢失资产间
	# 真实相对比例。资产按其 get_mesh() 原生尺寸渲染，footprint 仅用于评分。
	var fit_scale := 1.0
	# 垂直对齐 mesh 的原生 FBX 轴心（local y=0）而非 AABB 底面：每个资产按作者轴心就位——
	# cliff 轴心在几何中心 → 一半埋入地面；叶片/植物轴心在底部 → 立于地面。与
	# asset-descriptor-demo 摆放一致（容器原点=FBX 轴心，置于地面基线）。水平仍取 AABB 中心，
	# 使 footprint 居中于锚点体素。
	var pivot_local := Vector3(aabb.position.x + aabb.size.x * 0.5, 0.0, aabb.position.z + aabb.size.z * 0.5)
	var yaw := deg_to_rad(float(int(ar.get("rotation_slot", 0))) * (360.0 / float(maxi(rotation_slots, 1))))
	var basis := Basis(Vector3.UP, yaw) * Basis.IDENTITY.scaled(Vector3(fit_scale, fit_scale, fit_scale))
	var origin := _anchor_world_positions[anchor_index] - basis * pivot_local
	return {
		"ok": true, "winner": winner, "mesh": mesh, "yaw": yaw,
		"transform": Transform3D(basis, origin), "aabb": aabb, "fit_scale": fit_scale,
	}


## 胜出物体的世界 AABB（点选用：射线命中它 = 选中该锚点）。
func _winner_world_aabb(anchor_index: int) -> AABB:
	var pl := _winner_placement(anchor_index)
	if pl.is_empty():
		return AABB()
	return (pl.transform as Transform3D) * (pl.aabb as AABB)


## 每锚点放置其得分最高资产的真实 mesh，统一经 _winner_placement 变换。
func _build_winning_anchor_content() -> void:
	if not _scored:
		return
	# 按资产分组，每组一个 MultiMesh（同 mesh 批量实例化）
	var transforms_by_asset := {}
	for anchor_index in range(_anchor_world_positions.size()):
		var pl := _winner_placement(anchor_index)
		if pl.is_empty():
			continue
		var winner: int = pl.winner
		if not transforms_by_asset.has(winner):
			transforms_by_asset[winner] = []
		transforms_by_asset[winner].append(pl.transform)
	for winner in transforms_by_asset.keys():
		var node := _build_mesh_multimesh(
			_assets[winner].get("mesh", null),
			transforms_by_asset[winner],
			"Winner_%d_%s" % [winner, str(_assets[winner].get("name", ""))])
		if node == null:
			continue
		var mat: Material = _assets[winner].get("material", null)
		if mat != null:
			node.material_override = mat
		_display_root.add_child(node)
		# 胜出「结果 mesh」属 anchor 域内容：注册到 ANCHOR 显示组（Anchor 模式可见）。
		# 注册到 GPU_OBJECTS 会在 Anchor 模式被 mode-focus 隐藏 → 结果 mesh 不渲染。
		_register_spa_voxel_display_node(VOXEL_DISPLAY_ANCHOR, node)


## 选中锚点胜出物体的定向包围盒（供 SPA 画红色 sample-bounds 框）。
func _selected_anchor_sample_bounds() -> Dictionary:
	var pl := _winner_placement(_selected_anchor_idx)
	if pl.is_empty():
		return {}
	var aabb: AABB = pl.aabb
	var t: Transform3D = pl.transform
	var obb_size: Vector3 = aabb.size * float(pl.fit_scale)
	var obb_center: Vector3 = t * (aabb.position + aabb.size * 0.5)
	return {
		"has_obb": true,
		"obb_center": obb_center,
		"obb_size": obb_size,
		"obb_yaw": float(pl.yaw),
		"aabb": AABB(obb_center - obb_size * 0.5, obb_size),
	}


func _anchor_marker_radius() -> float:
	var voxel_size: Vector3 = _scene_fields.get("voxel_size", Vector3.ONE)
	return maxf(minf(voxel_size.x, voxel_size.z) * 0.12, ANCHOR_RADIUS_MIN)


func _build_mesh_multimesh(mesh: Mesh, transforms: Array, node_name: String) -> MultiMeshInstance3D:
	if mesh == null or transforms.is_empty():
		return null
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	for i in range(transforms.size()):
		mm.set_instance_transform(i, transforms[i])
	var node := MultiMeshInstance3D.new()
	node.name = node_name
	node.multimesh = mm
	return node


# ---- Descriptor loading ----------------------------------------------------

func _load_descriptors() -> Array:
	var result: Array = []
	for d in placement_assets:
		if _is_asset_descriptor(d) and d.get_mesh() != null:
			result.append(d)
	if not result.is_empty():
		return result
	var root := asset_descriptor_dir.strip_edges()
	if root.is_empty():
		root = "res://assets"
	for path in _scan_descriptor_paths(root):
		var res := load(path)
		if _is_asset_descriptor(res) and res.get_mesh() != null:
			result.append(res)
	return result


func _is_asset_descriptor(res) -> bool:
	return res != null and res is Resource and res.has_method("get_mesh") and res.has_method("get_collision")


func _scan_descriptor_paths(root: String) -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(root)
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir():
			if not entry.begins_with("."):
				out.append_array(_scan_descriptor_paths(root.path_join(entry)))
		elif entry.get_extension().to_lower() == "tres":
			out.append(root.path_join(entry))
		entry = dir.get_next()
	dir.list_dir_end()
	return out


func _footprint_shape_for(mesh: Mesh) -> Vector3i:
	if mesh == null:
		return Vector3i.ONE
	var size := mesh.get_aabb().size
	var longest := maxf(maxf(size.x, size.y), maxf(size.z, 0.0001))
	var target := float(asset_footprint_voxels)
	return Vector3i(
		clampi(int(round(size.x / longest * target)), 1, asset_footprint_voxels),
		clampi(int(round(size.y / longest * target)), 1, asset_footprint_voxels),
		clampi(int(round(size.z / longest * target)), 1, asset_footprint_voxels))


# ---- SPA binding -----------------------------------------------------------

func _sync_spa_bindings() -> void:
	_attach_display_root_to_spa()
	_register_spa_volume_score_provider()


func _spa_display_host() -> Node:
	if not is_inside_tree():
		return null
	var tree := get_tree()
	var root := tree.edited_scene_root if tree != null else null
	if root == null:
		root = self
	if root.name == "CoreSPADemo" and root.has_method("register_volume_score_provider"):
		return root
	var core := root.find_child("CoreSPADemo", true, false)
	if core != null and core.has_method("register_volume_score_provider"):
		return core
	return null


func _attach_display_root_to_spa() -> void:
	var spa := _spa_display_host()
	if spa != null and spa.has_method("attach_voxel_display_root"):
		spa.call("attach_voxel_display_root", _display_root, VOLUME_SCORE_DISPLAY_OWNER)
	elif _display_root != null and _display_root.get_parent() == null:
		add_child(_display_root)


func _register_spa_volume_score_provider() -> void:
	var spa := _spa_display_host()
	if spa != null and spa.has_method("register_volume_score_provider"):
		spa.call("register_volume_score_provider", self)


func _unregister_spa_volume_score_provider() -> void:
	var spa := _spa_display_host()
	if spa != null and spa.has_method("unregister_volume_score_provider"):
		spa.call("unregister_volume_score_provider", self)


func _notify_spa_selected_anchor_changed() -> void:
	var spa := _spa_display_host()
	if spa != null and spa.has_method("refresh_volume_score_anchor_selection"):
		spa.call("refresh_volume_score_anchor_selection")


func _register_spa_voxel_display_node(display_key: String, node: Node3D) -> void:
	if node == null:
		return
	var spa := _spa_display_host()
	if spa != null and spa.has_method("register_voxel_display_node"):
		spa.call("register_voxel_display_node", display_key, node, VOLUME_SCORE_DISPLAY_OWNER)
	if spa != null and spa.has_method("is_voxel_display_visible"):
		node.visible = bool(spa.call("is_voxel_display_visible", display_key))


# ---- HUD -------------------------------------------------------------------

func _setup_hud() -> void:
	_hud_label = DemoUI.setup_hud_label(self)


func _selected_anchor_hud_lines() -> Array[String]:
	var lines: Array[String] = []
	if not _scored:
		lines.append("Selected anchor: run Score first")
		return lines
	if _selected_anchor_idx < 0:
		lines.append("Selected anchor: click an anchor")
		return lines
	lines.append("Selected anchor #%d voxel=%s top-%d:" % [
		_selected_anchor_idx, str(_anchor_voxel(_selected_anchor_idx)), selected_anchor_top_k])
	var entries := _selected_anchor_topk_entries()
	if entries.is_empty():
		lines.append("  (no score entries)")
		return lines
	for entry in entries:
		lines.append("  %s" % _format_topk_entry(entry))
	return lines


func _format_topk_entry(entry: Dictionary) -> String:
	var score := float(entry.get("score", -INF))
	var score_text := "%.3f" % score if score > -1.0e20 else "n/a"
	var marker := "*" if bool(entry.get("selected", false)) else " "
	return "%s#%d %s score=%s yaw=%.0f %s" % [
		marker, int(entry.get("rank", 0)), str(entry.get("asset_name", "?")),
		score_text, float(entry.get("yaw", 0.0)),
		"valid" if bool(entry.get("valid", false)) else "invalid"]


func _update_hud() -> void:
	if _hud_label == null:
		return
	var rd_status := "ready" if RenderingServer.get_rendering_device() != null else "NO GPU"
	var lines: Array[String] = [
		"placement-score-3d (volume score / VPG)",
		"GPU: %s   grid=%s   assets=%d" % [rd_status, str(_scene_fields.get("grid", Vector3i.ZERO)), _assets.size()],
		"Anchors: %d (spacing=%d)   Rotations: %d   Score: %.0f ms" % [_total_anchors, anchor_spacing, rotation_slots, _elapsed_score_ms],
		"Toolbar: Anchors → generate, Score → rank assets; click an anchor to inspect top-%d" % selected_anchor_top_k,
		"",
	]
	for i in range(_assets.size()):
		var wins := 0
		for w in _winner_per_anchor:
			if w == i:
				wins += 1
		lines.append("[%d] %s  wins=%d" % [i, str(_assets[i].get("name", "?")), wins])
	if not _scored:
		lines.append("")
		lines.append("(scoring not complete — press Score)")
	else:
		lines.append("")
		lines.append_array(_selected_anchor_hud_lines())
	_hud_label.text = "\n".join(lines)
