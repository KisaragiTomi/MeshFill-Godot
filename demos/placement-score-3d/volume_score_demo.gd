@tool
extends "res://scripts/core_demo_contract_fixture.gd"

## placement-score-3d — Volume-Score Provider (VPG-backed)
##
## Generates surface anchors over the scene field, then scores every prepared
## AssetDescriptor asset against every anchor via VoxelPlacementGenerator.score_dimensions
## (the CPU semantic-MATCH scorer), keeping per-anchor asset rankings. Registers itself with
## the sibling CoreSPADemo (ScenePlacementActor) so the editor toolbar "Anchors"/"Score"
## buttons and Anchor-mode click-select delegate here.
##
## Scoring backend note: this provider declares scoring dimensions, builds per-asset profiles
## from each AssetDescriptor and per-anchor features from the TargetSV, and reads the returned
## per-anchor `scores` array (one score per asset). It does NOT use the in-shader
## score_voxel_tile.glsl / run_minimal path. See scoring-dimensions-design.md.
##
## Placed winners are the REAL descriptor mesh (never proxy boxes) — see the project
## CLAUDE.md rule "Placement / Score Demos: Render Real AssetDescriptor Assets".

const VoxelPlacementGenerator := preload("res://scripts/voxel_placement_generator.gd")
const VolumeScore3D := preload("res://scripts/utils/volume_score_3d.gd")
const DemoUI := preload("res://scripts/utils/demo_ui.gd")
const TerrainConfigScript := preload("res://scripts/terrain_config.gd")
const TargetSVLoaderScript := preload("res://scripts/target_sv_loader.gd")
const SPAEditorContract := preload("res://scripts/spa_editor_contract.gd")

const VOXEL_DISPLAY_GPU_OBJECTS := SPAEditorContract.VOXEL_DISPLAY_GPU_OBJECTS
const VOXEL_DISPLAY_ANCHOR := SPAEditorContract.VOXEL_DISPLAY_ANCHOR
const VOLUME_SCORE_DISPLAY_OWNER := "volume_score"
const SELECTION_DOMAIN_ANCHOR := SPAEditorContract.SELECTION_DOMAIN_ANCHOR
const SELECTION_GEOMETRY_VOLUME_SCORE_ANCHOR := SPAEditorContract.SELECTION_GEOMETRY_VOLUME_SCORE_ANCHOR
const ANCHOR_RADIUS_MIN := 0.06
## 选中锚点高亮色，与 SPA canonical SELECTION_DOMAIN_ANCHOR 保持一致
const SELECTED_ANCHOR_COLOR := Color(1.0, 0.64, 0.1, 0.95)

# ---- Exported Tunables -----------------------------------------------------
@export_range(16, 128, 1) var grid_resolution: int = 64        # 场景场 XZ 分辨率
@export_range(4, 32, 1) var grid_height_slices: int = 16       # 场景场 Y 层数
@export_range(2, 16, 1) var anchor_spacing: int = 8            # 锚点体素间距
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

# ---- Display Nodes ---------------------------------------------------------
var _hud_label: Label
var _display_root: Node3D
var _anchor_point_display: MultiMeshInstance3D


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


func _build_scene_fields() -> void:
	_terrain_height = VolumeScore3D.sample_terrain_height_for_node(self, grid_resolution, grid_resolution)
	_scene_fields = VolumeScore3D.build_scene_fields(grid_resolution, grid_height_slices, _terrain_height)
	_terrain_height = _scene_fields.get("terrain_height", _terrain_height)


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


# ---- VPG scoring -----------------------------------------------------------

## 对每个资产用 VPG.score_dimensions 做语义 MATCH 打分：demo 声明维度 + 从 descriptor 建资产画像 +
## 从 TargetSV 建锚点特征，读取每锚点返回的 scores 数组（每资产一分）。见 scoring-dimensions-design.md。
func _run_scoring() -> void:
	_clear_scores()
	if _anchors.is_empty() or _assets.is_empty():
		push_warning("[VolumeScore] Cannot score: anchors or assets empty")
		return

	# 精细语义打分:逻辑在 VPG(score_dimensions),demo 只声明维度 + 从 descriptor 建资产画像 +
	# 从 TargetSV 建锚点特征 + 调用。见根目录 scoring-dimensions-design.md。
	var t0 := Time.get_ticks_msec()
	var dimensions := _scoring_dimensions()
	var asset_profiles := _build_asset_profiles()
	var anchor_features := _build_anchor_features()
	var scored: Array = VoxelPlacementGenerator.score_dimensions(dimensions, asset_profiles, anchor_features)

	for asset_index in range(_assets.size()):
		var anchor_results: Array[Dictionary] = []
		for anchor_index in range(_anchors.size()):
			var per: Dictionary = scored[anchor_index] if anchor_index < scored.size() else {}
			var scores: PackedFloat32Array = per.get("scores", PackedFloat32Array())
			anchor_results.append({
				"score": float(scores[asset_index]) if asset_index < scores.size() else -INF,
				"valid": true,
				"rotation_slot": 0,
				"voxel": _anchor_voxel(anchor_index),
			})
		_results.append({"ok": true, "asset_index": asset_index, "anchor_results": anchor_results})

	_elapsed_score_ms = float(Time.get_ticks_msec() - t0)
	_winner_per_anchor = _compute_winners()
	_scored = true
	print("[VolumeScore] Semantic-scored %d assets × %d anchors (%d dims) in %.0f ms" % [
		_assets.size(), _total_anchors, dimensions.size(), _elapsed_score_ms])


## 声明打分维度(数据驱动:加维度 = 在此加一行 + 对应通道 + 画像/特征一列)。
## 通道:0=collision 1=complexity 2=color.r 3=color.g 4=color.b。
func _scoring_dimensions() -> Array:
	var m := VoxelPlacementGenerator.FIT_MODE_MATCH
	return [
		{"name": "collision_fit", "channel": 0, "mode": m, "weight": 1.0},
		{"name": "complexity_fit", "channel": 1, "mode": m, "weight": 0.6},
		{"name": "color_fit_r", "channel": 2, "mode": m, "weight": 0.34},
		{"name": "color_fit_g", "channel": 3, "mode": m, "weight": 0.34},
		{"name": "color_fit_b", "channel": 4, "mode": m, "weight": 0.34},
	]


## 每资产画像 [collision, complexity, color.r, color.g, color.b],来源 AssetDescriptor。
func _build_asset_profiles() -> Array:
	var profiles: Array = []
	for a in _assets:
		var col: Color = a.get("color", Color.WHITE)   # descriptor.get_color(),.a = complexity
		var collision := _descriptor_collision(a.get("descriptor"))
		profiles.append(PackedFloat32Array([collision, clampf(col.a, 0.0, 1.0), col.r, col.g, col.b]))
	return profiles


## 资产 collision 画像(来自 descriptor):object_type 含 "rock" → 高,否则取 collision 样本均值。
func _descriptor_collision(d) -> float:
	if d == null:
		return 0.15
	if str(d.get("object_type")).to_lower().find("rock") >= 0:
		return 0.9
	var samples: Array = d.get_collision() if d.has_method("get_collision") else []
	if samples.is_empty():
		return 0.15
	var s := 0.0
	for e in samples:
		s += clampf(float((e as Dictionary).get("collision_strength", 0.0)), 0.0, 1.0)
	return clampf(s / float(samples.size()), 0.0, 1.0)


## 每锚点环境特征 [collision, complexity, color.rgb],来源 TargetSV(锚点 XZ 列按占据度聚合)。
func _build_anchor_features() -> Array:
	var features: Array = []
	var meta := TargetSVLoaderScript.metadata()
	var decoded: Dictionary = TargetSVLoaderScript.decode() if not meta.is_empty() else {}
	var ok := bool(decoded.get("valid", false))
	var tsz := int(meta.get("texture_size", 256))
	var slices := int(meta.get("slice_count", 16))
	var capture := float(meta.get("capture_size", TerrainConfigScript.CAPTURE_SIZE))
	var collision: PackedFloat32Array = decoded.get("target_collision", PackedFloat32Array())
	var color: PackedColorArray = decoded.get("target_color", PackedColorArray())
	var occ: PackedFloat32Array = decoded.get("target_completely", PackedFloat32Array())
	for i in range(_anchor_world_positions.size()):
		var feat := PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0])
		if ok:
			var wp := _anchor_world_positions[i]
			var tx := clampi(int(round((wp.x / capture + 0.5) * float(tsz - 1))), 0, tsz - 1)
			var tz := clampi(int(round((wp.z / capture + 0.5) * float(tsz - 1))), 0, tsz - 1)
			var wsum := 0.0
			var cc := 0.0; var cx := 0.0; var cr := 0.0; var cg := 0.0; var cb := 0.0
			for s in range(slices):
				var idx := tx + tsz * (tz + tsz * s)
				if idx < 0 or idx >= occ.size():
					continue
				var o := occ[idx]
				if o <= 0.01:
					continue
				var c: Color = color[idx] if idx < color.size() else Color(0, 0, 0, 0)
				cc += (collision[idx] if idx < collision.size() else 0.0) * o
				cx += c.a * o
				cr += c.r * o; cg += c.g * o; cb += c.b * o
				wsum += o
			if wsum > 0.0:
				feat[0] = clampf(cc / wsum, 0.0, 1.0)
				feat[1] = clampf(cx / wsum, 0.0, 1.0)
				feat[2] = clampf(cr / wsum, 0.0, 1.0)
				feat[3] = clampf(cg / wsum, 0.0, 1.0)
				feat[4] = clampf(cb / wsum, 0.0, 1.0)
		features.append(feat)
	return features


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
	_anchor_point_display = null
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
	_anchor_point_display = points
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
		"GPU: %s   grid=%dx%dx%d   assets=%d" % [rd_status, grid_resolution, grid_height_slices, grid_resolution, _assets.size()],
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
