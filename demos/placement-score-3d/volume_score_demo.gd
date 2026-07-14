@tool
extends "res://scripts/core_demo_contract_fixture.gd"

## placement-score-3d — Volume-Score Provider
##
## Generates surface anchors on the REAL terrain (over the standard terrain grid), and
## registers itself with the sibling CoreSPADemo (ScenePlacementActor) so the editor toolbar
## "Anchors"/"Score" buttons and Anchor-mode click-select delegate here.
##
## Scoring: GPU fine-selection (细筛选) — ONE anchor-origin residual-gain pass over
## all assets (score_anchor_asset_residual via VoxelPlacementGenerator.run_multi_asset
## with a CPU-built anchor handoff + debug_read_fine_candidates readback); the per
## (anchor x asset) residual gain ranks the assets and the winner's REAL mesh is placed.
##
## Placed winners are the REAL descriptor mesh (never proxy boxes) — see the project
## CLAUDE.md rule "Placement / Score Demos: Render Real AssetDescriptor Assets".

const VolumeScore3D := preload("res://scripts/utils/volume_score_3d.gd")
const DebugBufferSetScript := preload("res://scripts/utils/debug_buffer_set.gd")
const DemoUI := preload("res://scripts/utils/demo_ui.gd")
const DemoAssets := preload("res://scripts/utils/demo_assets.gd")
const DemoDebugVisuals := preload("res://scripts/utils/demo_debug_visuals.gd")
const TerrainConfigScript := preload("res://scripts/terrain_config.gd")
const TargetSVLoaderScript := preload("res://scripts/target_sv_loader.gd")
const SPAEditorContract := preload("res://scripts/spa_editor_contract.gd")
const VoxelPlacementGenerator := preload("res://scripts/voxel_placement_generator.gd")
const AssetDescriptorScript := preload("res://scripts/asset_descriptor.gd")
const SceneVoxelTileCodec := preload("res://scripts/scene_voxel_tile_codec.gd")
const ScoreTimingProfilerScript := preload("res://scripts/utils/score_timing_profiler.gd")
const VolumeScoreProviderRegistry := preload("res://scripts/volume_score_provider_registry.gd")

const VOXEL_DISPLAY_ANCHOR := SPAEditorContract.VOXEL_DISPLAY_ANCHOR
const VOLUME_SCORE_DISPLAY_OWNER := "volume_score"
const SELECTION_DOMAIN_ANCHOR := SPAEditorContract.SELECTION_DOMAIN_ANCHOR
const SELECTION_GEOMETRY_VOLUME_SCORE_ANCHOR := SPAEditorContract.SELECTION_GEOMETRY_VOLUME_SCORE_ANCHOR
const ANCHOR_RADIUS_MIN := 0.06

# ---- Exported Tunables -----------------------------------------------------
@export_range(8, 64, 1) var anchor_spacing: int = 32           # 锚点体素间距（在标准地形网格上）
@export_range(1, 8, 1) var selected_anchor_top_k: int = 4      # 选中锚点显示的 Top-K 资产数
@export_range(1, 24, 1) var rotation_slots: int = 12           # 每候选原点扫描的 yaw 档数
@export_range(1, 8, 1) var asset_collision_span_voxels: int = 4  # 无 collision 资产按 mesh AABB 合成采样的最长轴体素跨度
## 要评分/放置的真实资产（AssetDescriptor `.tres`）。场景显式声明为首选来源。
@export var placement_assets: Array[AssetDescriptor] = []
@export_dir var asset_descriptor_dir: String = "res://assets"  # 回退扫描目录
@export var auto_run_on_start := true
## 开:每次 run_minimal 打印 score→reduce→stamp→readback 分阶段耗时,循环后打印合计——
## 用于定位 GPU 打分管线性能瓶颈。见 [ScoreTimingProfiler]。默认关(零开销)。
@export var profile_score_timing := false

# ---- State -----------------------------------------------------------------
## 每资产：{descriptor, name, mesh, color, collision_span, aabb, material}
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

# ---- Fine-selection (细筛选) GPU scoring state --------------------------------
var _env_ready := false
var _target_field_bytes := PackedFloat32Array()    # voxel_count * 4: [r, g, b, target complexity]
var _target_collision_r8_bytes := PackedByteArray() # r8-packed target collision words
var _complexity_field := PackedFloat32Array()      # voxel_count: CurrentSV complexity (starts empty scene)
var _collision_field := PackedFloat32Array()       # voxel_count: CurrentSV collision

# ---- Golden-master capture（统一Debug承载方案 步骤6 消费链）------------------
var _capture_golden_sections := false
var _golden_sections: Array[String] = []

# ---- Display Nodes ---------------------------------------------------------
var _hud_label: Label
var _display_root: Node3D

## Register this scene-owned provider with the scripts-level registry so descriptor bakes can
## refresh background scene tabs without making the editor plugin depend on this demo script.
func _ready() -> void:
	super._ready()
	if is_scene_startup_blocked():
		return
	VolumeScoreProviderRegistry.register(self)
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
		VolumeScoreProviderRegistry.unregister(self)
		_unregister_spa_volume_score_provider()


# ---- Public API — SPA provider interface -----------------------------------

## 每次 AD bake 之后刷新锚点候选：meshfill 插件的 "Bake AD" 按钮在烘焙成功后经
## VolumeScoreProviderRegistry 调到这里。从磁盘按 resource_path 重载 placement_assets 的 .tres
## (烘焙覆盖了同名文件)、清 _assets 缓存、再 calculate_voxel_scores() 重打分。锚点(地形派生)
## 与 TargetSV env 不受描述符烘焙影响,故保留不重建(_env_ready 不复位)。
func reload_and_rescore() -> Dictionary:
	if not Engine.is_editor_hint():
		return {"ok": false, "reason": "not_editor_hint"}
	_reload_placement_descriptors()
	_assets.clear()   # 让 _ensure_assets_ready 用重载后的描述符重建 mesh/color/collision/span
	return calculate_voxel_scores()


## 从磁盘按各自 resource_path 重载 placement_assets 描述符(CACHE_MODE_REPLACE 就地刷新已缓存
## 实例),使烘焙覆盖的 .tres 生效。无路径的内联资源跳过。
func _reload_placement_descriptors() -> void:
	for i in range(placement_assets.size()):
		var d = placement_assets[i]
		if d == null:
			continue
		var path := str(d.resource_path)
		if path.is_empty():
			continue
		var fresh = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)
		if _is_asset_descriptor(fresh):
			placement_assets[i] = fresh

## 完整管线：场景场 → 资产 collision 采样注册（profile 容器）→ 锚点 → VPG 评分 → 可视化
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


## Golden-master 消费链入口（统一Debug承载方案 步骤6）：跑固定评分管线并把
## per (asset × anchor) residual-gain 结果（q1000 量化）作为稳定文本快照返回
## （meta 只含固定配置/计数，刻意不含耗时等非确定值）。residual-gain 迁移后
## 版本号升 v2——旧 v1 基线作废，需重录 goldens/。
## 桥调用：call_method path=VolumeScore method=run_golden_snapshot —— 见 tools/golden_snapshot_check.js。
func run_golden_snapshot() -> String:
	if not Engine.is_editor_hint():
		return "ERROR not_editor_hint"
	_capture_golden_sections = true
	_golden_sections.clear()
	var status := run_volume_score_pipeline()
	_capture_golden_sections = false
	if not bool(status.get("ok", false)):
		return "ERROR pipeline_not_ok anchors=%d scored=%s" % [
			int(status.get("anchors", 0)), str(status.get("scored", false))]
	if _golden_sections.is_empty():
		return "ERROR golden_snapshot_empty"
	var grid: Vector3i = _scene_fields.get("grid", Vector3i.ZERO)
	var lines: Array[String] = [
		"golden volume_score v2",
		"meta asset_count=%d anchor_count=%d grid=%dx%dx%d rotation_slots=%d anchor_spacing=%d" % [
			_assets.size(), _total_anchors, grid.x, grid.y, grid.z, rotation_slots, anchor_spacing],
	]
	lines.append_array(_golden_sections)
	return "\n".join(lines)


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
			"collision_span": _collision_span_for(mesh),
			"aabb": mesh.get_aabb(),
			"material": d.material,
		})


func _generate_anchors() -> void:
	_anchors = VolumeScore3D.generate_anchors(_scene_fields, _terrain_height, anchor_spacing)
	_anchor_world_positions = VolumeScore3D.anchor_world_positions(_scene_fields, _terrain_height, _anchors)
	_total_anchors = _anchors.size()


# ---- 细筛选 (Fine-Selection) GPU scoring -----------------------------------

## anchor-origin residual-gain 打分：ONE run — 全部资产进同一公共候选池。
## 锚点经 VoxelPlacementGenerator.build_cpu_anchor_handoff 构建与 prefilter 同构的
## resident anchor handoff（每锚点的 top-K 槽 = 全部资产，观测口径），
## debug_read_fine_candidates 回读整个候选池：每 (anchor × asset) 一条 residual-gain
## 记录（最佳 pivot/yaw）。资产形状与 SPA 同源:注册进 profile 容器,score/stamp 直接读
## 容器常驻 asset_voxel_records。
func _run_scoring() -> void:
	_clear_scores()
	if not _ensure_target_env_ready():
		return
	if _assets.is_empty() or _anchors.is_empty():
		return
	var t0 := Time.get_ticks_msec()
	var grid: Vector3i = _scene_fields.get("grid", Vector3i.ZERO)
	var vpg = VoxelPlacementGenerator.new()
	var profile_container := AutoVoxelRuntimeProfileContainer.new()
	if not profile_container.ensure_device():
		push_warning("[VolumeScore] profile 容器拿不到 RenderingDevice —— 不打分")
		return
	var profile_ids: Array[int] = []
	for a in range(_assets.size()):
		var d = _assets[a].get("descriptor")
		var pid := profile_container.register_descriptor(d)
		if pid < 0 or int(profile_container.get_asset_voxel_range_for_profile_id(pid).get("count", 0)) <= 0:
			# 无 collision 剖面:按 mesh AABB 跨度合成实心采样注册(CLAUDE.md 规则——
			# 从 mesh AABB 派生,不回退通用盒资产)。
			pid = profile_container.register_normalized_profile({
				"source_kind": "volume_score_demo_span_fallback",
				"asset_id": str(_assets[a].get("name", "asset_%d" % a)),
				"color": _assets[a].get("color", Color.WHITE),
				"complexity": clampf(d.get_complexity(), 0.0, 1.0) if d != null else 1.0,
				"collision": _collision_samples_from_span(_assets[a].get("collision_span", Vector3i.ONE)),
			})
		profile_ids.append(pid)
	if not profile_container.upload_profiles(true):
		push_warning("[VolumeScore] profile 容器上传失败 —— 不打分")
		profile_container.dispose()
		return
	var container_rd: RenderingDevice = profile_container.get_rendering_device()
	var anchor_voxels: Array = []
	for ai in range(_anchors.size()):
		anchor_voxels.append(_anchor_voxel(ai))
	var handoff: Dictionary = VoxelPlacementGenerator.build_cpu_anchor_handoff(
		container_rd, anchor_voxels, _assets.size())
	if not bool(handoff.get("ok", false)):
		push_warning("[VolumeScore] anchor handoff 构建失败: %s —— 不打分" % str(handoff.get("reason", "?")))
		profile_container.dispose()
		return
	var asset_defs: Array = []
	for a in range(_assets.size()):
		asset_defs.append({
			"descriptor": _assets[a].get("descriptor"),
			"asset_index": a,
			"profile_id": profile_ids[a],
		})
	if profile_score_timing:
		ScoreTimingProfilerScript.reset_aggregate()
	# TargetSV 目标场以【常驻 GPU buffer】交接给 VPG——reader 已改为 resident-GPU-only，
	# 不再接受 CPU 字节上传（settings.target_field_bytes 那条路已删）。buffer 建在
	# container_rd 上：VPG 会 attach 到 profile 容器的同一设备（见 VPG
	# _resolve_profile_container_buffers），borrow 的设备一致校验才过；与 anchor handoff 同源同设备。
	var target_field_byte_data := _target_field_bytes.to_byte_array()
	var target_field_buf := container_rd.storage_buffer_create(target_field_byte_data.size(), target_field_byte_data)
	var target_collision_buf := container_rd.storage_buffer_create(_target_collision_r8_bytes.size(), _target_collision_r8_bytes)
	if not target_field_buf.is_valid() or not target_collision_buf.is_valid():
		push_warning("[VolumeScore] 目标场常驻 buffer 创建失败 —— 不打分")
		if target_field_buf.is_valid(): container_rd.free_rid(target_field_buf)
		if target_collision_buf.is_valid(): container_rd.free_rid(target_collision_buf)
		VoxelPlacementGenerator.release_cpu_anchor_handoff(container_rd, handoff)
		profile_container.dispose()
		return
	var settings := {
		"rotation_slots": rotation_slots,
		"target_read_buffers": {
			"target_field_buffer": target_field_buf,
			"target_collision_buffer": target_collision_buf,
			"rendering_device": container_rd,
			"target_field_byte_count": target_field_byte_data.size(),
			"target_collision_byte_count": _target_collision_r8_bytes.size(),
			"target_field_format": "vec4",
			"target_field_stride_bytes": 16,
			"target_collision_format": "unorm8_u32",
			"resident_target_read_buffer_handoff": true,
			"resident_target_read_buffer_owner": "VolumeScoreDemo",
			"resident_target_read_buffer_lifetime": "VolumeScoreDemo scored-run scope",
		},
		"anchor_candidate_handoff": handoff,
		"auto_voxel_runtime_profile_container": profile_container,
		"debug_read_fine_candidates": true,
		"score_timing_profile": profile_score_timing,
		"score_timing_label": "volume_score",
	}
	var out: Dictionary = vpg.run_multi_asset(
		_complexity_field, _collision_field, asset_defs, grid,
		_scene_fields.get("voxel_size", Vector3.ONE),
		_scene_fields.get("grid_origin", Vector3.ZERO),
		settings)
	var topk := int(handoff.get("topk", _assets.size()))
	var candidates: Array = out.get("fine_candidates", [])
	# 候选池槽位 = anchor_id * topk + slot；本 demo 的 handoff 令 slot == asset_index。
	for a in range(_assets.size()):
		var anchor_results: Array[Dictionary] = []
		for ai in range(_anchors.size()):
			var slot := ai * topk + a
			var score := -INF
			var rotation_slot := 0
			var valid := false
			if slot < candidates.size():
				var record: Dictionary = candidates[slot]
				score = float(record.get("score", -INF))
				rotation_slot = int(record.get("rotation_index", 0))
				valid = bool(record.get("valid", false))
			anchor_results.append({
				"score": score, "valid": valid, "rotation_slot": rotation_slot, "voxel": _anchor_voxel(ai)})
		_results.append({"ok": true, "asset_index": a, "anchor_results": anchor_results})
	if _capture_golden_sections:
		_golden_sections.append_array(_golden_sections_from_results())
	if profile_score_timing:
		print(ScoreTimingProfilerScript.format_aggregate("volume-score fine-selection"))
	VoxelPlacementGenerator.release_cpu_anchor_handoff(container_rd, handoff)
	# 常驻目标场 buffer 由本 demo 持有（VPG 只借用不释放）；须在 profile 容器 dispose
	# （它拥有并会销毁 container_rd）之前释放。
	container_rd.free_rid(target_field_buf)
	container_rd.free_rid(target_collision_buf)
	if vpg.has_method("dispose"):
		vpg.dispose()
	profile_container.dispose()
	_elapsed_score_ms = float(Time.get_ticks_msec() - t0)
	_winner_per_anchor = _compute_winners()
	_scored = true
	print("[VolumeScore] Fine-selection scored %d assets × %d anchors in %.0f ms" % [
		_assets.size(), _total_anchors, _elapsed_score_ms])


## golden-master 素材：从 per (asset × anchor) 结果生成确定性文本快照（q1000 反量化，
## 稳定键序）。评分模型迁移到 residual-gain 后旧基线作废——用本口径重录 goldens/。
func _golden_sections_from_results() -> Array[String]:
	var sections: Array[String] = []
	for result in _results:
		var a := int((result as Dictionary).get("asset_index", -1))
		sections.append("asset %d name=%s" % [a, str(_assets[a].get("name", "asset_%d" % a)) if a >= 0 and a < _assets.size() else "?"])
		var anchor_results: Array = (result as Dictionary).get("anchor_results", [])
		for ai in range(anchor_results.size()):
			var entry: Dictionary = anchor_results[ai]
			sections.append("anchor %d voxel=%s valid=%d yaw=%d gain_q1000=%d" % [
				ai,
				str(entry.get("voxel", Vector3i.ZERO)),
				1 if bool(entry.get("valid", false)) else 0,
				int(entry.get("rotation_slot", 0)),
				int(round(clampf(float(entry.get("score", 0.0)), -1000.0, 1000.0) * 1000.0)),
			])
	return sections


## TargetSV 缓存:解码 TargetSV,打包 vec4 target field（rgb + complexity）与
## r8-packed target collision（独立双缓冲输入——细筛按 before/after 残差比较）。
## CurrentSV 起始为空场（零 complexity/collision）:residual gain = 放入资产后
## 对 TargetSV 残差的改善。网格与 TargetSV(256×16×256)一致则无需重建锚点。
## 无 TargetSV → place nothing。
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
	var t_comp: PackedFloat32Array = decoded.get("target_completeness", PackedFloat32Array())
	var t_color: PackedColorArray = decoded.get("target_color", PackedColorArray())
	_target_field_bytes = PackedFloat32Array(); _target_field_bytes.resize(voxel_count * 4)
	var target_collision_floats := PackedFloat32Array(); target_collision_floats.resize(voxel_count)
	_complexity_field = PackedFloat32Array(); _complexity_field.resize(voxel_count)
	_collision_field = PackedFloat32Array(); _collision_field.resize(voxel_count)
	for i in range(voxel_count):
		var coll := t_coll[i] if i < t_coll.size() else 0.0
		var comp := t_comp[i] if i < t_comp.size() else 0.0
		var c: Color = t_color[i] if i < t_color.size() else Color(0, 0, 0, 0)
		var f := i * 4
		_target_field_bytes[f + 0] = c.r
		_target_field_bytes[f + 1] = c.g
		_target_field_bytes[f + 2] = c.b
		_target_field_bytes[f + 3] = comp
		target_collision_floats[i] = coll
	_target_collision_r8_bytes = SceneVoxelTileCodec.pack_collision_field_u32_bytes(
		target_collision_floats, voxel_count)
	_env_ready = true
	return true


## 无 collision 剖面时用体素跨度建一组实心 canonical collision 采样(每格 strength/weight 1)，
## 供注册进 profile 容器(容器注册期负责 clearance/去重烘焙)。
func _collision_samples_from_span(span: Vector3i) -> Array:
	var sx := maxi(span.x, 1); var sy := maxi(span.y, 1); var sz := maxi(span.z, 1)
	var samples: Array = []
	for x in range(sx):
		for y in range(sy):
			for z in range(sz):
				samples.append({
					"local_pos": Vector3i(x - int(sx / 2), y, z - int(sz / 2)),
					"collision_strength": 1.0, "flags": 0, "weight": 1.0})
	return samples


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
	var mat := DemoDebugVisuals.make_unshaded_material(Color(0.20, 0.85, 1.0, 0.82), false, true)
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
## 按最优 yaw 旋转、原生 FBX 轴心贴地（cliff 半埋、植物立于地面）。无有效胜者返回空字典。
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
	# collision 采样包围盒归一化每个资产——那会把小资产（叶）放大得比大资产（崖）更多，丢失
	# 资产间真实相对比例。资产按其 get_mesh() 原生尺寸渲染，collision 采样仅用于评分。
	var fit_scale := 1.0
	# 垂直对齐 mesh 的原生 FBX 轴心（local y=0）而非 AABB 底面：每个资产按作者轴心就位——
	# cliff 轴心在几何中心 → 一半埋入地面；叶片/植物轴心在底部 → 立于地面。与
	# asset-descriptor-demo 摆放一致（容器原点=FBX 轴心，置于地面基线）。水平仍取 AABB 中心，
	# 使采样形状居中于锚点体素。
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
	for path in DemoAssets.discover_geo_files(root, ["tres"]):
		var res := load(path)
		if _is_asset_descriptor(res) and res.get_mesh() != null:
			result.append(res)
	return result


func _is_asset_descriptor(res) -> bool:
	return res != null and res is Resource and res.has_method("get_mesh") and res.has_method("get_collision")


## 无 collision 资产的采样跨度：从 mesh AABB 按最长轴归一到 asset_collision_span_voxels。
func _collision_span_for(mesh: Mesh) -> Vector3i:
	if mesh == null:
		return Vector3i.ONE
	var size := mesh.get_aabb().size
	var longest := maxf(maxf(size.x, size.y), maxf(size.z, 0.0001))
	var target := float(asset_collision_span_voxels)
	return Vector3i(
		clampi(int(round(size.x / longest * target)), 1, asset_collision_span_voxels),
		clampi(int(round(size.y / longest * target)), 1, asset_collision_span_voxels),
		clampi(int(round(size.z / longest * target)), 1, asset_collision_span_voxels))


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
