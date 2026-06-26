@tool
extends "res://scripts/core_demo_contract_fixture.gd"

## 3D Object Volume Score Demo
##
## Loads all geo meshes, voxelizes them, generates a scene field from terrain,
## distributes anchors across the surface, then scores every asset at every
## anchor with 12 rotation slots via GPU compute.
##
## Every anchor evaluates all assets so their scores can be compared
## head-to-head.

const ObjectVolumeScoreGpuScript := preload("res://scripts/object_volume_score_gpu.gd")
const TerrainConfigScript := preload("res://scripts/terrain_config.gd")
const VoxelPlacementGeneratorScript := preload("res://scripts/voxel_placement_generator.gd")
const CommonDemoAssets := preload("res://scripts/common_demo_assets.gd")
const CommonDemoUI := preload("res://scripts/common_demo_ui.gd")
const CommonVolumeScore3D := preload("res://scripts/common_volume_score_3d.gd")
const SPAEditorContract := preload("res://scripts/spa_editor_contract.gd")

const VOXEL_DISPLAY_GPU_OBJECTS := SPAEditorContract.VOXEL_DISPLAY_GPU_OBJECTS
const VOXEL_DISPLAY_ANCHOR := SPAEditorContract.VOXEL_DISPLAY_ANCHOR
const VOLUME_SCORE_DISPLAY_OWNER := "volume_score"
const VOLUME_SCORE_WINNER_GROUP := "volume_score_winner"
const SELECTION_DOMAIN_ANCHOR := SPAEditorContract.SELECTION_DOMAIN_ANCHOR
const SELECTION_GEOMETRY_VOLUME_SCORE_ANCHOR := SPAEditorContract.SELECTION_GEOMETRY_VOLUME_SCORE_ANCHOR
const ANCHOR_RADIUS_PX_BASE := 18.0
const ANCHOR_RADIUS_VOXEL_SCALE := 0.10
const ANCHOR_RADIUS_MIN := 0.06

# ---- Exported Tunables -----------------------------------------------------
# 以下参数均可在编辑器中直接调整，无需重新编译

@export_range(16, 128, 1) var grid_resolution: int = 64       # 场景场 XZ 分辨率（每个方向上的体素数量）
@export_range(4, 32, 1) var grid_height_slices: int = 16      # 场景场 Y 层数（垂直方向切片数）
@export_range(2, 16, 1) var anchor_spacing: int = 4           # 锚点之间的体素间距（步长）
@export_range(1, 16, 1) var selected_anchor_top_k: int = 4    # 选中锚点时显示的 Top-K 资产数
@export_range(4, 64, 1) var anchor_pick_radius_px: int = 18   # 锚点显示/点选半径缩放；18 为默认尺寸
@export_range(8, 48, 1) var voxel_grid_count: int = 24        # 资产体素化时的网格分辨率（资产侧）
@export_range(0.0, 1.0, 0.05) var target_min_height_frac: float = 0.0    # 目标放置区的最小高度比例（相对 grid_height_slices）
@export_range(0.0, 1.0, 0.05) var target_max_height_frac: float = 0.25   # 目标放置区的最大高度比例
@export var auto_run_on_start := true                          # 场景加载后是否自动执行完整管线

# ---- State -----------------------------------------------------------------
# 数据流：资产加载 → 体素化 → 场景场 → 锚点 → GPU评分 → 可视化

## 资产元数据：每项包含 name/mesh/volume/aabb/color/sample_variant_count 等
var _assets: Array[Dictionary] = []
## 资产体素足迹：ObjectVolumeScoreGpuScript.footprint_from_voxelizer_result() 的产物
var _footprints: Array[Dictionary] = []
## 锚点体素坐标（场景场网格坐标系）
var _anchors := PackedVector3Array()
## 锚点世界坐标（由体素坐标 + 地形高度换算）
var _anchor_world_positions := PackedVector3Array()
## 场景场：grid/voxel_size/grid_origin/complexity_bytes/collision_bytes/target_bytes
var _scene_fields: Dictionary = {}
## GPU评分结果：每个资产一个字典，包含 anchor_results 数组
var _results: Array[Dictionary] = []
## 每个锚点的最佳资产索引（-1 表示无胜者）
var _winner_per_anchor: PackedInt32Array = PackedInt32Array()
## 地形高度采样：每 XZ 格一个值，用于锚点 Y 坐标计算
var _terrain_height := PackedFloat32Array()
## 当前选中的锚点索引（-1 = 无选中）
var _selected_anchor_idx := -1
var _selected_anchor_topk_index := 0

# ---- Display Nodes ---------------------------------------------------------
# 所有可视化内容挂在 _display_root 下，通过 SPA 注册到 CoreSPADemo 的可见性管理

var _hud_label: Label                        # 左上角统计面板
var _display_root: Node3D                    # 所有可视化节点的父节点
var _anchor_point_display: MultiMeshInstance3D   # 所有锚点的球体标记（GPU实例化）
var _selected_anchor_marker: Node3D          # 当前选中锚点的高亮球体
var _anchor_detail_label: Label3D            # 选中锚点上方浮动的评分详情
var _voxelized := false                      # 是否已完成资产体素化
var _scored := false                         # 是否已完成 GPU 评分
var _elapsed_voxelize_ms := 0.0
var _elapsed_score_ms := 0.0
var _total_anchors := 0
var _total_dispatches := 0                  # GPU dispatch 次数（footprints.size() × 2）
var _placement_generator                     # VoxelPlacementGenerator 惰性实例


# ---- Public API — SPA Integration -----------------------------------------
# CoreSPADemo 通过 register_volume_score_provider 获取此脚本的引用，然后
# 调用以下方法驱动整个体积评分管线。所有返回值均为 Dictionary {\"ok\": bool, ...}

func _ready() -> void:
	super._ready()
	if is_scene_startup_blocked():
		return
	_setup_hud()
	_display_root = Node3D.new()
	_display_root.name = "VolumeScoreDisplay"
	## SPA 绑定需要重复调用：编辑器刚打开组合场景时子场景可能未同步完成
	_sync_spa_bindings()
	_sync_spa_bindings.call_deferred()
	if auto_run_on_start:
		run_volume_score_pipeline.call_deferred()


## 完整管线：加载 → 体素化 → 场景场 → 锚点 → GPU评分 → 可视化
func run_volume_score_pipeline() -> Dictionary:
	if not Engine.is_editor_hint():
		return {"ok": false, "reason": "not_editor_hint"}
	_sync_spa_bindings()
	_load_and_voxelize()
	_build_scene_fields()
	_generate_anchors()
	_run_gpu_scoring()
	_build_visualization()
	_sync_spa_bindings()
	_frame_camera()
	_update_hud()
	return _volume_score_status(true)


## 仅生成锚点（不重新评分），调用后锚点可视化即显示
func generate_anchors() -> Dictionary:
	if not Engine.is_editor_hint():
		return {"ok": false, "reason": "not_editor_hint"}
	if not _ensure_scene_fields_ready():
		return {"ok": false, "reason": "scene_fields_not_ready"}
	_generate_anchors()
	_clear_score_results()
	_build_visualization()
	_update_hud()
	return _volume_score_status(false)


## 仅运行 GPU 评分（需已有锚点），不重新体素化
func calculate_voxel_scores() -> Dictionary:
	if not Engine.is_editor_hint():
		return {"ok": false, "reason": "not_editor_hint"}
	if not _ensure_scoring_inputs_ready():
		return {"ok": false, "reason": "scoring_inputs_not_ready"}
	if _anchors.is_empty():
		_generate_anchors()
	_run_gpu_scoring()
	_build_visualization()
	_update_hud()
	return _volume_score_status(true)


## 获取指定锚点的 Top-K 评分条目（按分数降序）
func get_anchor_topk_entries(anchor_index: int, top_k: int = -1) -> Array[Dictionary]:
	var limit := selected_anchor_top_k if top_k <= 0 else top_k
	return ObjectVolumeScoreGpuScript.build_anchor_asset_topk(
		_results, _assets, anchor_index, limit)


func get_selected_anchor_topk_entries() -> Array[Dictionary]:
	var entries := get_anchor_topk_entries(_selected_anchor_idx, selected_anchor_top_k)
	if not entries.is_empty():
		_selected_anchor_topk_index = clampi(_selected_anchor_topk_index, 0, entries.size() - 1)
	for i in range(entries.size()):
		entries[i]["selected_bounds"] = i == _selected_anchor_topk_index
	return entries


func get_selected_anchor_topk_index() -> int:
	return _selected_anchor_topk_index


func cycle_selected_anchor_topk(delta: int) -> Dictionary:
	if _selected_anchor_idx < 0:
		return {"ok": false, "reason": "no_selected_anchor"}
	var entries := get_anchor_topk_entries(_selected_anchor_idx, selected_anchor_top_k)
	if entries.is_empty():
		return {"ok": false, "reason": "no_topk_entries"}
	var count := entries.size()
	var next_index := (_selected_anchor_topk_index + int(delta)) % count
	if next_index < 0:
		next_index += count
	_selected_anchor_topk_index = next_index
	_refresh_selected_anchor_overlay()
	_update_hud()
	_notify_spa_selected_anchor_changed()
	return {
		"ok": true,
		"anchor_index": _selected_anchor_idx,
		"selected_topk_index": _selected_anchor_topk_index,
		"selected_topk_entry": _selected_anchor_topk_entry(),
		"topk": get_selected_anchor_topk_entries(),
	}


func _selected_anchor_topk_entry() -> Dictionary:
	var entries := get_anchor_topk_entries(_selected_anchor_idx, selected_anchor_top_k)
	if entries.is_empty():
		return {}
	_selected_anchor_topk_index = clampi(_selected_anchor_topk_index, 0, entries.size() - 1)
	var entry := entries[_selected_anchor_topk_index].duplicate(true)
	entry["selected_bounds"] = true
	return entry


func _refresh_selected_anchor_overlay() -> void:
	if _selected_anchor_idx < 0:
		return
	_build_selected_anchor_overlay()


func get_selected_anchor_summary_text() -> String:
	if not _scored:
		return "Anchor scores: run Score"
	if _selected_anchor_idx < 0:
		return "Anchor scores: select an anchor"
	var parts: Array[String] = ["Anchor #%d" % _selected_anchor_idx]
	for entry in get_selected_anchor_topk_entries():
		var name := str(entry.get("asset_name", "?"))
		var score := float(entry.get("score", -INF))
		var score_text := "n/a"
		if score > -1.0e20:
			score_text = "%.2f" % score
		var valid_suffix := "" if bool(entry.get("valid", false)) else " invalid"
		parts.append("%s %s%s" % [name, score_text, valid_suffix])
	return " | ".join(parts)


func get_selected_anchor_tooltip_text() -> String:
	return "\n".join(_build_selected_anchor_hud_lines())


func get_selected_anchor_record() -> Dictionary:
	if _selected_anchor_idx < 0 or _selected_anchor_idx >= _anchor_world_positions.size():
		return {}
	var record := {
		"domain": SELECTION_DOMAIN_ANCHOR,
		"geometry": SELECTION_GEOMETRY_VOLUME_SCORE_ANCHOR,
		"id": "volume_score_anchor:%d" % _selected_anchor_idx,
		"anchor_index": _selected_anchor_idx,
		"voxel_coord": _selected_anchor_voxel(),
		"world_position": _anchor_world_positions[_selected_anchor_idx],
		"topk": get_selected_anchor_topk_entries(),
		"selected_topk_index": _selected_anchor_topk_index,
		"selected_topk_entry": _selected_anchor_topk_entry(),
		"summary": get_selected_anchor_summary_text(),
		"tooltip": get_selected_anchor_tooltip_text(),
	}
	var sample_bounds := _selected_anchor_sample_bounds_info()
	if not sample_bounds.is_empty():
		record["sample_bounds"] = sample_bounds
	return record


## 选中指定锚点并高亮显示，返回 Top-K 评分条目
func select_anchor(anchor_index: int) -> Dictionary:
	if not _scored:
		return {"ok": false, "reason": "scoring_not_complete"}
	if anchor_index < 0 or anchor_index >= _anchor_world_positions.size():
		return {"ok": false, "reason": "anchor_index_out_of_range"}
	_sync_spa_bindings()
	_selected_anchor_idx = anchor_index
	_selected_anchor_topk_index = 0
	_build_selected_anchor_overlay()
	_update_hud()
	_notify_spa_selected_anchor_changed()
	return {
		"ok": true,
		"anchor_index": _selected_anchor_idx,
		"selected_topk_index": _selected_anchor_topk_index,
		"selected_topk_entry": _selected_anchor_topk_entry(),
		"topk": get_selected_anchor_topk_entries(),
	}


func clear_selected_anchor() -> Dictionary:
	_selected_anchor_idx = -1
	_selected_anchor_topk_index = 0
	_remove_selected_anchor_overlay()
	_update_hud()
	_notify_spa_selected_anchor_changed()
	return {"ok": true}


func has_selected_anchor() -> bool:
	return _selected_anchor_idx >= 0


func has_volume_score_anchors() -> bool:
	return not _anchor_world_positions.is_empty()


## 通过相机射线 + 屏幕坐标点选最近的锚点
func select_anchor_at_viewport_position(viewport_camera: Camera3D, screen_pos: Vector2) -> Dictionary:
	var anchor_index := _pick_anchor_index_from_camera(viewport_camera, screen_pos)
	if anchor_index < 0:
		return {"ok": false, "reason": "no_anchor_hit"}
	return select_anchor(anchor_index)


func _pick_anchor_index_from_camera(camera: Camera3D, screen_pos: Vector2) -> int:
	if not _scored or camera == null or _anchor_world_positions.is_empty():
		return -1
	var best_idx := -1
	var best_score := INF
	var best_ray_t := INF
	var ray_origin := camera.project_ray_origin(screen_pos)
	var ray_dir := camera.project_ray_normal(screen_pos).normalized()
	var hit_radius := _anchor_marker_radius()
	var hit_radius_sq := hit_radius * hit_radius
	for i in range(_anchor_world_positions.size()):
		var world_pos := _anchor_world_positions[i]
		if camera.is_position_behind(world_pos):
			continue
		var to_anchor := world_pos - ray_origin
		var ray_t := to_anchor.dot(ray_dir)
		if ray_t < 0.0:
			continue
		var closest := ray_origin + ray_dir * ray_t
		var score := closest.distance_squared_to(world_pos)
		if score <= hit_radius_sq and (score < best_score or (is_equal_approx(score, best_score) and ray_t < best_ray_t)):
			best_score = score
			best_ray_t = ray_t
			best_idx = i
	return best_idx


func _ensure_scene_fields_ready() -> bool:
	if _scene_fields.is_empty() or _terrain_height.is_empty():
		_build_scene_fields()
	return not _scene_fields.is_empty()


func _ensure_scoring_inputs_ready() -> bool:
	if not _voxelized or _footprints.is_empty():
		_load_and_voxelize()
	if not _ensure_scene_fields_ready():
		return false
	return not _footprints.is_empty()


func _clear_score_results() -> void:
	_results.clear()
	_winner_per_anchor = PackedInt32Array()
	_scored = false
	_elapsed_score_ms = 0.0
	_total_dispatches = 0
	_selected_anchor_topk_index = 0
	_remove_selected_anchor_overlay()


func _volume_score_status(require_scored: bool) -> Dictionary:
	var ok := _total_anchors > 0
	if require_scored:
		ok = ok and _scored
	return {
		"ok": ok,
		"anchors": _total_anchors,
		"scored": _scored,
		"asset_count": _assets.size(),
		"score_ms": _elapsed_score_ms,
	}


func _placement_generator_instance():
	if _placement_generator == null:
		_placement_generator = VoxelPlacementGeneratorScript.new()
	return _placement_generator


func _voxel_display_is_visible(display_key: String) -> bool:
	var spa := _spa_display_host()
	if spa != null and spa.has_method("is_voxel_display_visible"):
		return bool(spa.call("is_voxel_display_visible", display_key))
	return true


func _attach_display_root_to_spa() -> void:
	var spa := _spa_display_host()
	if spa != null and spa.has_method("attach_voxel_display_root"):
		spa.call("attach_voxel_display_root", _display_root, VOLUME_SCORE_DISPLAY_OWNER)
		return
	push_warning("[VolumeScore] Missing CoreSPADemo; voxel display root was not attached.")


## 编辑器刚打开组合场景时 edited_scene_root/子场景可能还没同步完成；
## 这些 SPA 绑定都是幂等的，所以 _ready() 会立即执行一次并延迟补一次。
func _sync_spa_bindings() -> void:
	_attach_display_root_to_spa()
	_register_spa_volume_score_provider()


func _register_spa_voxel_display_node(display_key: String, node: Node3D) -> void:
	if node == null:
		return
	var spa := _spa_display_host()
	if spa != null and spa.has_method("register_voxel_display_node"):
		spa.call("register_voxel_display_node", display_key, node, VOLUME_SCORE_DISPLAY_OWNER)
	node.visible = _voxel_display_is_visible(display_key)


func _register_spa_volume_score_provider() -> void:
	var spa := _spa_display_host()
	if spa != null and spa.has_method("register_volume_score_provider"):
		spa.call("register_volume_score_provider", self)


func _notify_spa_selected_anchor_changed() -> void:
	var spa := _spa_display_host()
	if spa != null and spa.has_method("refresh_volume_score_anchor_selection"):
		spa.call("refresh_volume_score_anchor_selection")


func _unregister_spa_volume_score_provider() -> void:
	var spa := _spa_display_host()
	if spa != null and spa.has_method("unregister_volume_score_provider"):
		spa.call("unregister_volume_score_provider", self)


func _spa_display_host() -> Node:
	if not is_inside_tree():
		return null
	var tree := get_tree()
	var root := tree.edited_scene_root if tree != null else null
	# @tool 场景脚本里 edited_scene_root 可能暂时为空；组合场景 root 自身也能找到 CoreSPADemo。
	if root == null:
		root = self
	if root.name == "CoreSPADemo" and root.has_method("set_voxel_display_visible"):
		return root
	var core := root.find_child("CoreSPADemo", true, false)
	if core != null and core.has_method("set_voxel_display_visible"):
		return core
	return null


func _exit_tree() -> void:
	_unregister_spa_volume_score_provider()


# --- Asset Loading & Voxelization -----------------------------------------
# 遍历 CommonDemoAssets 中的每个 FBX 网格，通过 GPU 体素化生成 footprint，
# 同时预烘每个旋转槽的有效 sample records，用于后续评分。

func _load_and_voxelize() -> void:
	_assets.clear()
	_footprints.clear()
	var loaded := CommonVolumeScore3D.voxelize_common_assets(voxel_grid_count)
	for asset in loaded.get("assets", []):
		if asset is Dictionary:
			_assets.append(asset)
	for footprint in loaded.get("footprints", []):
		if footprint is Dictionary:
			_footprints.append(footprint)

	for i in range(_assets.size()):
		print("[VolumeScore] Asset %d [%s] aabb=%.2fm tier=%d variants=%d groups=%d ext=%d voxels=%d fp_grid=%s" % [
			i, _assets[i].name, _assets[i].get("world_longest", 0.0), _assets[i].get("tier", -1),
			_assets[i].sample_variant_count, _assets[i].sample_group_count,
			_assets[i].sample_extent, _assets[i].voxel_count, str(_assets[i].fp_grid)])

	_voxelized = true
	_elapsed_voxelize_ms = float(loaded.get("elapsed_ms", 0.0))
	print("[VolumeScore] Voxelized %d assets in %.0f ms" % [
		_assets.size(), _elapsed_voxelize_ms])


# --- Scene Field Construction ---------------------------------------------
# 构建三层体素场（complexity / collision / target），作为 GPU 评分的场景输入。
#
# 每层语义：
#   complexity (RGBA32)  — R=地形类型 G=坡度 B=曲率 A=复杂度强度
#   collision  (float)   — 0.0=空气 >0=地下（资产不能穿透）
#   target     (RGBA32)  — 目标放置区色彩 + 权重（资产倾向放置于此）
#
# Y 轴分层逻辑：
#   地面以下 (y <= ground_slice)       → complexity.a=0.8  collision=0.9
#   紧贴地面 (y <= ground_slice+1)     → complexity.a=0.3  collision=0.1
#   地面以上                            → complexity.a=0.0  collision=0.0
#   target 带内 (min_above..max_above) → 有淡绿色目标权重，离地面越近权重越高

func _build_scene_fields() -> void:
	_terrain_height = CommonVolumeScore3D.sample_terrain_height_for_node(
		self, grid_resolution, grid_resolution)
	_scene_fields = CommonVolumeScore3D.build_scene_fields(
		grid_resolution,
		grid_height_slices,
		_terrain_height,
		target_min_height_frac,
		target_max_height_frac
	)
	_terrain_height = _scene_fields.get("terrain_height", _terrain_height)
	var grid: Vector3i = _scene_fields.get("grid", Vector3i.ZERO)
	var voxel_count := VoxelGeneral.voxel_count(grid)
	print("[VolumeScore] Scene field: grid=%s voxels=%d" % [
		str(_scene_fields.grid), voxel_count])


# --- Anchor Generation ----------------------------------------------------
# 在场景场表面以 anchor_spacing 为步长生成锚点网格。
# 每个锚点的 Y 坐标 = 地形高度 + 1 层体素，即紧贴地面以上。

func _generate_anchors() -> void:
	_anchors = CommonVolumeScore3D.generate_anchors(_scene_fields, _terrain_height, anchor_spacing)
	_anchor_world_positions = CommonVolumeScore3D.anchor_world_positions(
		_scene_fields, _terrain_height, _anchors)
	if _anchors.is_empty():
		_total_anchors = 0
		return
	_total_anchors = _anchors.size()
	print("[VolumeScore] Generated %d anchors (spacing=%d)" % [_total_anchors, anchor_spacing])


# --- GPU Scoring -----------------------------------------------------------
# 核心压力测试：对所有锚点 × 所有资产 × 12 个旋转槽位同时评分。
# 每个资产触发两次 GPU dispatch（写入目标 + 读取得分），
# 总 dispatch 次数 = footprints.size() × 2。

func _run_gpu_scoring() -> bool:
	_clear_score_results()

	if _anchors.is_empty() or _footprints.is_empty():
		push_warning("[VolumeScore] Cannot score: anchors or footprints are empty")
		return false
	if RenderingServer.get_rendering_device() == null:
		push_warning("[VolumeScore] No RenderingDevice — GPU scoring skipped")
		return false

	var t0 := Time.get_ticks_msec()
	var scorer = ObjectVolumeScoreGpuScript.new()
	_results = scorer.score_all_assets(_scene_fields, _footprints, _anchors)
	scorer.dispose()
	_elapsed_score_ms = float(Time.get_ticks_msec() - t0)
	_total_dispatches = _footprints.size() * 2

	_winner_per_anchor = ObjectVolumeScoreGpuScript.best_asset_per_anchor(_results, _total_anchors)
	_scored = true
	print("[VolumeScore] GPU scoring: %d assets × %d anchors in %.0f ms (%d dispatches)" % [
		_footprints.size(), _total_anchors, _elapsed_score_ms, _total_dispatches])
	return true


func _selected_anchor_voxel() -> Vector3i:
	return ObjectVolumeScoreGpuScript.anchor_voxel_at(
		_anchors, _selected_anchor_idx, Vector3i(-1, -1, -1))


func _build_selected_anchor_hud_lines() -> Array[String]:
	var lines: Array[String] = []
	if not _scored:
		lines.append("Selected anchor: scoring not complete")
		return lines
	if _selected_anchor_idx < 0:
		lines.append("Selected anchor: none (click a placed winner)")
		return lines
	lines.append("Selected anchor #%d voxel=%s world=%s top-%d:" % [
		_selected_anchor_idx,
		str(_selected_anchor_voxel()),
		str(_anchor_world_positions[_selected_anchor_idx].snapped(Vector3(0.01, 0.01, 0.01))),
		selected_anchor_top_k,
	])
	var entries := get_selected_anchor_topk_entries()
	if entries.is_empty():
		lines.append("  (no score entries)")
		return lines
	for entry in entries:
		lines.append("  %s" % _format_topk_entry(entry))
	return lines


func _build_selected_anchor_label_lines() -> Array[String]:
	var lines: Array[String] = []
	if _selected_anchor_idx < 0:
		return lines
	lines.append("Anchor #%d  %s" % [_selected_anchor_idx, str(_selected_anchor_voxel())])
	var selected_entry := _selected_anchor_topk_entry()
	if not selected_entry.is_empty():
		lines.append("Bounds target: #%d %s" % [
			int(selected_entry.get("rank", _selected_anchor_topk_index + 1)),
			str(selected_entry.get("asset_name", "Asset")),
		])
	var sample_bounds := _selected_anchor_sample_bounds_info()
	if not sample_bounds.is_empty():
		var bounds_label := "Score bbox" if bool(sample_bounds.get("score_valid", false)) else "Asset bbox"
		lines.append("%s: %s  groups=%d  cap=%d  samples=%d  hit=%d  spanVol=%d  slot=%d" % [
			bounds_label,
			str(sample_bounds.get("asset_name", "Asset")),
			int(sample_bounds.get("sample_group_count", 0)),
			int(sample_bounds.get("sample_variant_capacity", 0)),
			int(sample_bounds.get("sample_variant_count", 0)),
			int(sample_bounds.get("contributing_voxel_count", 0)),
			int(sample_bounds.get("sample_bounds_volume", 0)),
			int(sample_bounds.get("rotation_slot", -1)),
		])
	for entry in get_selected_anchor_topk_entries():
		lines.append(_format_topk_entry(entry))
	return lines


func _format_topk_entry(entry: Dictionary) -> String:
	var rank := int(entry.get("rank", 0))
	var asset_index := int(entry.get("asset_index", -1))
	var asset_name := str(entry.get("asset_name", "Asset%d" % asset_index))
	var score := float(entry.get("score", -INF))
	var score_text := "n/a"
	if score > -1.0e20:
		score_text = "%.4f" % score
	var yaw := float(entry.get("yaw", 0.0))
	var slot := int(entry.get("rotation_slot", -1))
	var valid_text := "valid" if bool(entry.get("valid", false)) else "invalid"
	var marker := "*" if bool(entry.get("selected_bounds", false)) else " "
	return "%s#%d [%d] %s  score=%s  yaw=%.0f  slot=%d  %s" % [
		marker, rank, asset_index, asset_name, score_text, yaw, slot, valid_text]


# --- Visualization ---------------------------------------------------------
# 可视化分为三层：
#   1. _anchor_point_display   — MultiMeshInstance3D：所有锚点的小球体（GPU 实例化）
#   2. 胜出资产实例              — 每个锚点放置其得分最高的资产 mesh
#   3. _selected_anchor_marker  — 选中锚点的高亮球体 + 浮动 Label3D 详情

func _build_visualization() -> void:
	if _display_root == null:
		return
	if _display_root.get_parent() == null:
		_attach_display_root_to_spa()
	for child in _display_root.get_children():
		child.queue_free()
	_anchor_point_display = null
	_selected_anchor_marker = null
	_anchor_detail_label = null

	if _anchor_world_positions.is_empty():
		return
	if _selected_anchor_idx >= _anchor_world_positions.size():
		_selected_anchor_idx = -1

	_build_anchor_point_display()
	_build_winning_anchor_content()
	_build_selected_anchor_overlay()


func _build_anchor_point_display() -> void:
	if _display_root == null or _anchor_world_positions.is_empty():
		return
	var marker_radius := _anchor_marker_radius()
	var marker_mesh := SphereMesh.new()
	marker_mesh.radius = marker_radius
	marker_mesh.height = marker_radius * 2.0
	marker_mesh.radial_segments = 8
	marker_mesh.rings = 4

	var marker_mat := StandardMaterial3D.new()
	marker_mat.albedo_color = Color(0.20, 0.85, 1.0, 0.82)
	marker_mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	marker_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	marker_mat.no_depth_test = true

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = marker_mesh
	multimesh.instance_count = _anchor_world_positions.size()
	for i in range(_anchor_world_positions.size()):
		multimesh.set_instance_transform(i, Transform3D(Basis(), _anchor_world_positions[i]))

	var points := MultiMeshInstance3D.new()
	points.name = "AnchorPoints"
	points.multimesh = multimesh
	points.material_override = marker_mat
	_anchor_point_display = points
	_display_root.add_child(points)
	_register_spa_voxel_display_node(VOXEL_DISPLAY_ANCHOR, points)


## 为每个锚点生成得分最高的资产实例。
## 流程：获取胜出资产 → 查阅锚点评分结果 → 体素坐标→世界坐标变换 → 生成 AutoObject
func _build_winning_anchor_content() -> void:
	if not _scored:
		return
	for i in range(_anchor_world_positions.size()):
		var winner := _winner_per_anchor[i] if i < _winner_per_anchor.size() else -1
		if winner < 0 or winner >= _assets.size():
			continue
		var anchor_result := ObjectVolumeScoreGpuScript.anchor_result_for_asset(_results, winner, i)
		if anchor_result.is_empty() or not bool(anchor_result.get("valid", false)):
			continue
		var asset: Dictionary = _assets[winner]
		var mesh := asset.get("mesh", null) as Mesh
		if mesh == null:
			continue
		var asset_name := str(asset.get("name", "Asset%d" % winner))
		var pivot_variant := _anchor_pivot_variant_for_mesh(mesh)
		var world_result := _world_result_for_winning_anchor(anchor_result, winner, i, pivot_variant)
		if world_result.is_empty():
			continue
		var generator = _placement_generator_instance()
		var placed = generator.spawn_placement_autoobject(
			_display_root,
			world_result,
			"AutoObject",
			mesh,
			_autoobject_config_for_winner(asset, winner, i, asset_name, world_result, pivot_variant)
		)
		if not (placed is Node):
			continue
		var placed_node := placed as Node
		if placed_node is Node3D:
			_register_spa_voxel_display_node(VOXEL_DISPLAY_GPU_OBJECTS, placed_node as Node3D)


func _anchor_pivot_variant_for_mesh(mesh: Mesh) -> Dictionary:
	return {
		"name": "anchor",
		"offset": _anchor_pivot_for_mesh(mesh),
		"score_bias": 0.0,
	}


## 体素坐标 → 世界坐标变换链
## 1. 根据锚点世界坐标反推 synthetic_origin（场景网格原点在世界空间的位置）
## 2. 调用 VoxelPlacementGenerator.placement_results_to_world() 完成变换
## 3. 根据 yaw 旋转角度修正 pivot_offset 后的位置
func _world_result_for_winning_anchor(
	anchor_result: Dictionary,
	asset_index: int,
	anchor_index: int,
	pivot_variant: Dictionary
) -> Dictionary:
	if anchor_index < 0 or anchor_index >= _anchor_world_positions.size():
		return {}
	var anchor_voxel := ObjectVolumeScoreGpuScript.anchor_voxel_at(_anchors, anchor_index)
	var voxel_size: Vector3 = _scene_fields.get("voxel_size", Vector3.ONE)
	var anchor_world := _anchor_world_positions[anchor_index]
	var synthetic_origin := anchor_world - VoxelGeneral.voxel_to_world(anchor_voxel, Vector3.ZERO, voxel_size)
	var rotation_slot := clampi(
		int(anchor_result.get("rotation_slot", 0)),
		0,
		ObjectVolumeScoreGpuScript.ROTATION_SLOTS - 1
	)
	var raw_result := {
		"valid": true,
		"voxel_origin": anchor_voxel,
		"rotation_index": rotation_slot,
		"scale_index": 0,
		"score": float(anchor_result.get("score", 0.0)),
		"asset_index": asset_index,
	}
	var raw_results: Array[Dictionary] = [raw_result]
	var world_results = _placement_generator_instance().call(
		"placement_results_to_world",
		raw_results,
		voxel_size,
		synthetic_origin,
		ObjectVolumeScoreGpuScript.ROTATION_SLOTS,
		pivot_variant
	)
	if world_results.is_empty():
		return {}
	var world_result: Dictionary = world_results[0]
	world_result["anchor_index"] = anchor_index
	world_result["anchor_position"] = anchor_world
	world_result["rotation_slot"] = rotation_slot
	if anchor_result.has("yaw"):
		var current_rotation: Vector3 = world_result.get("rotation_degrees", Vector3.ZERO)
		var yaw := float(anchor_result.get("yaw", current_rotation.y))
		var pivot_offset: Vector3 = pivot_variant.get("offset", Vector3.ZERO)
		world_result["position"] = anchor_world - pivot_offset.rotated(Vector3.UP, deg_to_rad(yaw))
		world_result["rotation_degrees"] = Vector3(0.0, yaw, 0.0)
	return world_result


func _autoobject_config_for_winner(
	asset: Dictionary,
	asset_index: int,
	anchor_index: int,
	asset_name: String,
	world_result: Dictionary,
	pivot_variant: Dictionary
) -> Dictionary:
	var color: Color = asset.get("color", Color.WHITE)
	var record_id := "volume_score_%04d_%s" % [anchor_index, asset_name]
	var config := {
		"name": "Placed_%04d_%s" % [anchor_index, asset_name],
		"id": record_id,
		"record_id": record_id,
		"asset_id": asset_name,
		"mesh_index": asset_index,
		"object_type": "object",
		"auto_source": "volume_score_anchor_winner",
		"source_voxel_type": "AutoSceneVoxel",
		"source_mesh_path": CommonDemoAssets.geo_path(asset_index),
		"groups": [VOLUME_SCORE_WINNER_GROUP],
		"selectable": true,
		"color": color,
		"complexity": clampf(color.a, 0.0, 1.0),
		"pivot_variants": [pivot_variant],
		"auto_generate_vertical_pivots": false,
		"create_voxel_write_spec": true,
		"volume_xz_resolution": grid_resolution,
		"capture_size": TerrainConfigScript.CAPTURE_SIZE,
		"grid_origin": _scene_fields.get("grid_origin", Vector3.ZERO),
		"voxel_size": _scene_fields.get("voxel_size", Vector3.ONE),
		"base_pixel": _base_pixel_for_anchor(anchor_index),
		"anchor_index": anchor_index,
		"anchor_position": world_result.get("anchor_position", Vector3.ZERO),
		"pivot_variant": str(world_result.get("pivot_variant", "anchor")),
		"pivot_offset": world_result.get("pivot_offset", Vector3.ZERO),
	}
	var spa := _spa_display_host()
	if spa != null:
		config["scene_placement_actor"] = spa
	return config


func _base_pixel_for_anchor(anchor_index: int) -> Vector2i:
	if anchor_index < 0 or anchor_index >= _anchor_world_positions.size():
		return Vector2i.ZERO
	var pixel = _placement_generator_instance().call(
		"placement_world_to_volume_pixel",
		_anchor_world_positions[anchor_index],
		grid_resolution,
		_scene_fields.get("grid_origin", Vector3.ZERO),
		_scene_fields.get("voxel_size", Vector3.ONE)
	)
	if pixel is Vector2i:
		return pixel
	return Vector2i.ZERO


func _anchor_pivot_for_mesh(mesh: Mesh) -> Vector3:
	if mesh == null:
		return Vector3.ZERO
	var aabb := mesh.get_aabb()
	return Vector3(
		aabb.position.x + aabb.size.x * 0.5,
		aabb.position.y,
		aabb.position.z + aabb.size.z * 0.5
	)


func _build_selected_anchor_overlay() -> void:
	if _display_root == null:
		return
	_remove_selected_anchor_overlay()
	if not _scored or _selected_anchor_idx < 0 or _selected_anchor_idx >= _anchor_world_positions.size():
		return

	var voxel_size: Vector3 = _scene_fields.get("voxel_size", Vector3.ONE)
	var anchor_pos := _anchor_world_positions[_selected_anchor_idx]
	var marker_mesh := SphereMesh.new()
	var marker_radius := _anchor_marker_radius()
	marker_mesh.radius = marker_radius
	marker_mesh.height = marker_radius * 2.0
	var marker_mat := StandardMaterial3D.new()
	marker_mat.albedo_color = Color(1.0, 0.96, 0.20, 0.95)
	marker_mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	marker_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	marker_mat.no_depth_test = true
	var marker := MeshInstance3D.new()
	marker.name = "SelectedAnchorMarker"
	marker.mesh = marker_mesh
	marker.material_override = marker_mat
	marker.position = anchor_pos
	_selected_anchor_marker = marker
	_display_root.add_child(marker)
	_register_spa_voxel_display_node(VOXEL_DISPLAY_ANCHOR, marker)

	var label := Label3D.new()
	label.name = "SelectedAnchorScores"
	label.text = "\n".join(_build_selected_anchor_label_lines())
	label.position = anchor_pos + Vector3(voxel_size.x * 1.5, voxel_size.y * 3.0, voxel_size.z * 1.5)
	label.font_size = 24
	label.pixel_size = 0.035
	label.outline_size = 8
	label.modulate = Color(1.0, 0.96, 0.25, 1.0)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_anchor_detail_label = label
	_display_root.add_child(label)
	_register_spa_voxel_display_node(VOXEL_DISPLAY_ANCHOR, label)


func _remove_selected_anchor_overlay() -> void:
	if _selected_anchor_marker != null and is_instance_valid(_selected_anchor_marker):
		_selected_anchor_marker.queue_free()
	if _anchor_detail_label != null and is_instance_valid(_anchor_detail_label):
		_anchor_detail_label.queue_free()
	_selected_anchor_marker = null
	_anchor_detail_label = null


func _anchor_marker_radius() -> float:
	var voxel_size: Vector3 = _scene_fields.get("voxel_size", Vector3.ONE)
	var base_radius := maxf(minf(voxel_size.x, voxel_size.z) * ANCHOR_RADIUS_VOXEL_SCALE, ANCHOR_RADIUS_MIN)
	var radius_scale := clampf(float(anchor_pick_radius_px) / ANCHOR_RADIUS_PX_BASE, 0.25, 4.0)
	return base_radius * radius_scale


## Mirrors score_object_subtile.glsl and returns the scene-voxel cell bounds for
## the currently selected top-k asset. If that asset has no valid score at this
## anchor, the asset footprint sample profile still drives the bounds/variant info.
func _selected_anchor_sample_bounds_info() -> Dictionary:
	var selected_entry := _selected_anchor_topk_entry()
	var asset_index := int(selected_entry.get("asset_index", -1))
	return ObjectVolumeScoreGpuScript.anchor_sample_bounds_info(
		_results,
		_assets,
		_footprints,
		_scene_fields,
		_anchors,
		_selected_anchor_idx,
		asset_index
	)


func _frame_camera() -> void:
	var cam := CommonDemoUI.find_camera(self, "DemoSetup/FlyCamera", "", false, false)
	if cam == null:
		return
	if not cam.is_inside_tree():
		return
	var capture_size := TerrainConfigScript.CAPTURE_SIZE
	var cam_pos := Vector3(0.0, capture_size * 0.4, capture_size * 0.45)
	cam.look_at_from_position(cam_pos, Vector3.ZERO, Vector3.UP)
	cam.fov = 55.0


# --- HUD -------------------------------------------------------------------
# 左上角统计面板，显示 GPU 状态、管线耗时、每资产胜出数/平均分/最高分、
# 以及当前选中锚点的 Top-K 详情。由 _update_hud() 在每次管线步骤后刷新。

func _setup_hud() -> void:
	_hud_label = CommonDemoUI.setup_hud_label(self)


func _update_hud() -> void:
	if _hud_label == null:
		return
	var rd_status := "ready" if RenderingServer.get_rendering_device() != null else "NO GPU"
	var lines: Array[String] = [
		"3D Object Volume Score",
		"GPU: %s   grid=%dx%dx%d   voxel_grid_count=%d" % [
			rd_status, grid_resolution, grid_height_slices, grid_resolution, voxel_grid_count],
		"Assets: %d   Anchors: %d (spacing=%d)   Rotations: %d" % [
			_assets.size(), _total_anchors, anchor_spacing,
			ObjectVolumeScoreGpuScript.ROTATION_SLOTS],
		"Voxelize: %.0f ms   Score: %.0f ms   Dispatches: %d" % [
			_elapsed_voxelize_ms, _elapsed_score_ms, _total_dispatches],
		"",
		"SPA Anchor mode: click anchor to inspect top-%d; use toolbar Anchors/Score" % selected_anchor_top_k,
		"",
	]

	for i in range(_assets.size()):
		var a: Dictionary = _assets[i]
		var win_count := 0
		var max_score := -1.0
		var avg_score := 0.0
		var valid_count := 0
		if i < _results.size() and bool(_results[i].get("ok", false)):
			var per_anchor: Array = _results[i].get("anchor_results", [])
			for ar in per_anchor:
				if ar is Dictionary:
					var score: float = ar.get("score", -1.0)
					if score > max_score:
						max_score = score
					if bool(ar.get("valid", false)):
						avg_score += score
						valid_count += 1
			if valid_count > 0:
				avg_score /= float(valid_count)
		for w in _winner_per_anchor:
			if w == i:
				win_count += 1
		lines.append("[%d] %s  aabb=%.2fm  T%d variants=%d groups=%d  voxels=%d  wins=%d  avg=%.3f  max=%.3f" % [
			i, a.name, a.get("world_longest", 0.0),
			a.get("tier", -1), a.get("sample_variant_count", -1), a.get("sample_group_count", -1),
			a.voxel_count, win_count, avg_score, max_score])

	if not _scored:
		lines.append("")
		lines.append("(scoring not complete)")
	else:
		lines.append("")
		lines.append_array(_build_selected_anchor_hud_lines())

	_hud_label.text = "\n".join(lines)
