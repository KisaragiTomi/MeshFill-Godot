@tool
class_name SPASelectionHost
extends Node3D


## SPA 的点选路由、选中状态和反馈可视化宿主。

const SPAEditorContract := preload("res://scripts/spa_editor_contract.gd")
const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")
const SceneVoxelTileStoreScript := preload("res://scripts/scene_voxel_tile_store.gd")
const TerrainConfigScript := preload("res://scripts/terrain_config.gd")
const TerrainInitializerScript := preload("res://scripts/terrain_initializer.gd")
# ⚠ 别名刻意**不叫** `TerrainRaycast`：那个文件里已经没有任何射线了（`ray_to_height_field()`
# 与两个迭代常量随旧点选一并删除，2026-08-10），只剩一个高度场双线性查表 `sample_height()`。
# 顶着旧名字会让读者以为本类还有一条 CPU 地形射线，文件本体已随之改名（2026-08-12）。
const TerrainHeightFieldScript := preload("res://scripts/utils/terrain_height_field.gd")
# ⚠ 这里曾有 `TargetSVLoaderScript` 的 preload：唯一消费方是已删除的 `_targetsv_content_key()`
# （旧 VoxelPickGPU 的常驻缓冲内容代号）。2026-08-11 随它一并去掉。
const DemoDebugVisuals := preload("res://scripts/utils/demo_debug_visuals.gd")
# ⚠ 这里曾有 `DemoUI` 与 `VoxelDebugLabel` 两个 preload：
#   * `DemoUI` 的唯一消费方是已删除的 `_get_camera()`（见文件末尾那条墓碑）；
#   * `VoxelDebugLabel` 在本类里从来没有被引用过——标签由 `DemoDebugVisuals` 建，
#     它自己去 preload，本类不经手。
# 两者在别处仍有消费者，删的只是本文件这两条无人使用的引入（2026-08-12）。
const PickIdPassScript := preload("res://scripts/utils/pick_id_pass.gd")
## 选中框与域显示共用相同的中心坐标换算。
const SceneSVVolumeScript := preload("res://scripts/scene_sv_volume.gd")
const SVTileVolumeScript := preload("res://scripts/svtile_volume.gd")
const BrushSVVolumeScript := preload("res://scripts/brush_sv_volume.gd")

# 域只使用 SELECTION_DOMAIN_* 字符串标识；可见性同时决定点选准入。

const SELECT_COLOR := Color(1.0, 0.85, 0.0, 1.0)
const SELECTION_DOMAIN_AUTOOBJECT := SPAEditorContract.SELECTION_DOMAIN_AUTOOBJECT
const SELECTION_DOMAIN_SVTILE := SPAEditorContract.SELECTION_DOMAIN_SVTILE
const SELECTION_DOMAIN_ANCHOR := SPAEditorContract.SELECTION_DOMAIN_ANCHOR
const SELECTION_DOMAIN_SV := SPAEditorContract.SELECTION_DOMAIN_SV
const SELECTION_DOMAIN_TARGETSV := SPAEditorContract.SELECTION_DOMAIN_TARGETSV
const SELECTION_DOMAIN_BRUSH := SPAEditorContract.SELECTION_DOMAIN_BRUSH
const SELECTION_GEOMETRY_VOXEL := SPAEditorContract.SELECTION_GEOMETRY_VOXEL
const SELECTION_GEOMETRY_AUTOOBJECT := SPAEditorContract.SELECTION_GEOMETRY_AUTOOBJECT
const SELECTION_GEOMETRY_VOLUME_SCORE_ANCHOR := SPAEditorContract.SELECTION_GEOMETRY_VOLUME_SCORE_ANCHOR
# ⚠ 这里曾有 `SELECTION_FADED_TRANSPARENCY := 0.76`：「非聚焦域淡化」的透明度。唯一读者是
# `_apply_targetsv_visuals()` 里那句三元表达式，而它的 `target_focus` 形参**唯一调用点恒传
# true** —— 淡化分支自选择模式退役（2026-08-10）起就是死代码。随该函数一并删除（2026-08-14）。
const ANCHOR_SAMPLE_BOUNDS_COLOR := Color(1.0, 0.08, 0.04, 0.95)
const EXTERNAL_VOXEL_DISPLAY_ROOT_NAME := SPAEditorContract.EXTERNAL_VOXEL_DISPLAY_ROOT_NAME
const PICK_ID_PASS_NODE_NAME := "PickIdPass"
## 进入 ID pass 的显示组；TargetSV 由专用入口收集。
const PICK_ID_DISPLAY_KEYS := [
	SPAEditorContract.VOXEL_DISPLAY_GPU_OBJECTS,
	SPAEditorContract.VOXEL_DISPLAY_ANCHOR,
	SPAEditorContract.VOXEL_DISPLAY_SV,
	SPAEditorContract.VOXEL_DISPLAY_SVTILE,
	# 2026-08-10：BrushSV 切进 ID 路（此前是"画得出、点不中"的纯显示域）。
	# drawable 由 BrushSVVolume 经基类 register_pick_drawable() 登记。
	SPAEditorContract.VOXEL_DISPLAY_BRUSH,
	# 2026-08-10：TargetSV 并入通用组扫描。此前它被本表刻意排除、由
	# `_collect_targetsv_pick_drawable()` 按节点名硬取——那是它还不走基类登记时的通路；
	# V2 起 `register_pick_drawable()` 已把 TargetSVVoxels 加进 "targetsv" 显示组，
	# 专用入口只是同一节点的第二条收集路（单独存在时不重复，但每次改收集逻辑要同步两处）。
	SPAEditorContract.VOXEL_DISPLAY_TARGETSV,
]
const PICK_DRAWABLE_META := SPAEditorContract.PICK_DRAWABLE_META

# ---- ID 点选配置 ------------------------------------------------------------
#
# ⚠ 这里曾有三项，全部随旧路退役删除（三角形 ID 唯一路，用户裁定 2026-08-10）：
#   `PICK_ID_SELECTION_DEFAULT` / `pick_id_selection_enabled`  一键回退开关。它是 SV / SVTile
#       两个**无逐样本对比证据**域出问题时的唯一 A/B 判据 —— 删掉的代价写在这里，别当它没发生过。
#   `PICK_ID_SWITCHED_DOMAINS`      "哪些域已切到 ID 路"。没有第二条路了，五个域就是全部。
#   `PICK_ID_SWITCHED_DATA_DOMAINS` "ID 路开着时要从旧序列摘掉哪些域"。旧序列已不存在。

# ---- 运行时上下文 ----------------------------------------------------------
var _sv_committer: Object = null            ## SceneVoxelCommitter（可为 null=host-only 展示模式）
var autoobject_grid_resolution := 512       ## 无 committer 时的网格回退分辨率
# ⚠ 这里曾有 `select_gpu_autoobjects`（AutoObject 域可不可选）与
# `gpu_autoobject_pick_radius_px`（旧路"屏幕 28px 内最近中心"的接受半径）。
# 前者是显示开关之外的**第二个准入来源**；后者所属的屏幕距离判定随旧路一起删了（深度即仲裁）。
# 两者连同唯一读它们的 `_selection_allows_gpu_autoobjects()` 一并删除。
#
# ⚠ 2026-08-11 更正：这段原先写"准入现在只由 `_domain_pick_allowed()` 即显示开关决定"。
# 那个函数当天已随最后一个调用方删除 —— **准入不是任何一处代码检查出来的**，而是 ID pass 的
# 物理保证：域画不出像素就没有 pick_id，物理上就选不中。别再为此加回一条"各处记得检查"的规矩。
var show_anchor_sample_bounds := true

# ---- 回调 ------------------------------------------------------------------
var _hud_update_callback := Callable()      ## 搬移代码中所有 _update_hud() → _notify_hud()
var _extra_visuals_refresh := Callable()    ## demo overlay（heatmap/总览标签）淡化钩子

# ---- AutoObject 点选数据 ---------------------------------------------------
var _autoobject_runtime_ready := false
var _autoobject_positions: Array[Vector3] = []
var _autoobject_asset_indices: Array[int] = []
var _autoobject_ids: Array[int] = []
var _autoobject_voxel_mins: Array[Vector3i] = []   ## 真实链模式：逐对象 voxel_min（网格模式为空，用 side_count 反算）
var _autoobject_side_count := 0
var _autoobject_spacing_voxels := 1
var _profile_ids: Array[int] = []
var _asset_names: Array[String] = []

# ---- 选择状态 --------------------------------------------------------------
## 六个域**共用**的唯一选中态。各域的身份下标存在记录里（anchor 用 `anchor_index`、
## AutoObject 用 `object_index`、体素域用 `voxel_coord`…），没有任何域另开专用槽。
## ⚠ 这里曾并列一个 `_selected_anchor_idx`——两份表示直接制造过一次缺陷
## （`set_active_selection()` 会清那个槽 ⇒ anchor 只能绕开它 ⇒ 绕的时候把显示 marker 丢了）。
var _active_selection: Dictionary = {}
var _voxel_display_visible := SPAEditorContract.default_voxel_display_state()
## ⚠ 2026-08-11 起本成员**只写不读**：唯一读它的 `_volume_score_provider_node()` 已随射线校验
## 与 anchor 准入链一并删除。register / unregister 两个口本身仍有副作用（注册时刷新 anchor 选中、
## 注销时清掉 anchor 选中态），靠它做「注销的是不是当前这个 provider」的身份比对，所以没有跟着删。
## 待办二选一：要么给它接回一个真实读者，要么让 register/unregister 停止假装在跟踪身份。
var _volume_score_provider: Node
var _selection_marker: MeshInstance3D
# ⚠ 这里曾有 `_anchor_selection_label`（3D 视口里跟随选中框的 Label3D，节点名
# `SelectedAnchorLabel`）。它把锚点编号 / 体素坐标 / top-4 资产评分整块糊在视口中央，
# 遮住被选中的几何本身。用户裁定删除（2026-08-10）。
# ⚠ **同样的信息仍在**：编辑器插件的 2D overlay（`_forward_3d_draw_over_viewport`
# → `get_selection_overlay_text()`）画在视口边角，不挡几何——所以
# `_format_active_selection_overlay()` 保留，它是那条通路的文本源。
var _anchor_sample_bounds_marker: MeshInstance3D
var _external_voxel_display_root: Node3D
# ⚠ 这里曾有 `_mode_visual_bindings`（外部节点的"按显示键下发 visible"绑定表）。
# 唯一注册方是 demo 的 SVTile object-ref 热力图，热力图随「一个可视化」裁定删除后
# （2026-08-10）本机制零调用方：域族的显示节点由 `PickableDomain.set_display_visible()`
# 管，族外容器（PlacedInstanceDisplay）走 `register_voxel_display_node` 的组下发。
# ⚠ 这里曾有 `var _voxel_pick_gpu`（VoxelPickGPU，旧 GPU 射线拾取器）与
# `_anchor_positions_cache`（锚点世界坐标快照，只服务旧路的域间屏幕距离仲裁）。
# 三角形 ID 成为唯一命中方式后（2026-08-10）两者都没有消费者：命中来自 ID 图的一个像素，
# 不再有射线、不再有"谁离鼠标更近"这一层。整条 `scripts/voxel_pick_gpu.gd` 依赖随之从本类脱钩。
var _terrain_field: PackedFloat32Array
var _terrain_field_res := 0
## 高度场修订号，用于复用 GPU 常驻缓冲。
var _terrain_field_revision := 0
# ⚠ 这里曾有四个只服务旧路的成员，随旧路一起删除（三角形 ID 唯一路，2026-08-10）：
#   `_pick_ray_memo` / `_pick_ray_memo_key`  单次点击内的地形射线记忆化（没有射线了）
#   `_last_pick_anchors` / `_last_pick_autoobjects`  一次 dispatch 顺带算出的未仲裁两层命中
#   `_anchor_positions_cache`  锚点世界坐标快照，只用于域间屏幕距离仲裁（深度即仲裁）
var _editor_camera: Camera3D
var _consume_editor_mouse_release := false
# ---- ID 拾取状态 -----------------------------------------------------------
var _pick_id_pass: Node = null
## 诊断用一次性视口和相机。
var _pick_id_probe_viewport: SubViewport = null
var _pick_id_probe_camera: Camera3D = null
# ⚠ 这里曾有 `_pick_id_anchor_bounds`（anchor_index → 世界 AABB 缓存）：唯一读者是射线校验
# `_anchor_winner_aabb_hit()`，随射线辨别退役一并删除（2026-08-11）。
## 最近一次 ID 点击的诊断快照。
var _last_pick_id_click: Dictionary = {}
# ⚠ 这里曾有 `_data_pick_callables`（数据域 → **拾取**构建器）：它是旧路"每个域各带一条
# 命中算法、由偏好顺序仲裁"的派发表。三角形 ID 成为唯一命中方式后没有可派发的拾取器了
# （命中由 ID pass 一次算出，深度即仲裁），此表自那时起就是空字典 —— 全仓零读零写，
# 只剩声明还立在这里让人以为拾取仍有第二条路。已删除（2026-08-12）。
## 数据域 → **记录**构建器（命中之后拿域坐标去取那一格的内容，与"怎么命中"无关，故保留）。
var _data_record_callables: Dictionary = {}
var _target_sv: TargetSVSetup = null
## 祖先 SPA 缓存，不表示所有权。
var _cached_spa: ScenePlacementActor = null


# ---- 接线 ------------------------------------------------------------------

## 注入配置和回调，并校验域合同。
func configure(options: Dictionary) -> void:
	autoobject_grid_resolution = int(options.get("grid_resolution", autoobject_grid_resolution))
	show_anchor_sample_bounds = bool(options.get("show_anchor_sample_bounds", show_anchor_sample_bounds))
	_hud_update_callback = options.get("hud_update", Callable())
	_extra_visuals_refresh = options.get("visuals_refresh", Callable())
	SPAEditorContract.validate_domain_bindings(self)


## `null` 表示仅展示、不读取数据域。
func attach_runtime_context(sv_committer: Object) -> void:
	_sv_committer = sv_committer


## 注入 TargetSV 数据源。
func attach_target_sv(target_sv: TargetSVSetup) -> void:
	_target_sv = target_sv


## 树结构变化时刷新祖先 SPA 缓存。
func _enter_tree() -> void:
	_cached_spa = _resolve_scene_placement_actor()


## 离开场景树时清除祖先 SPA 缓存。
func _exit_tree() -> void:
	_cached_spa = null


## 缓存失效时重新沿父链查找 SPA。
func _scene_placement_actor() -> ScenePlacementActor:
	if _cached_spa != null:
		if is_instance_valid(_cached_spa) and _cached_spa.is_inside_tree():
			return _cached_spa
		_cached_spa = null
	_cached_spa = _resolve_scene_placement_actor()
	return _cached_spa


## 沿父链查找所属的 ScenePlacementActor。
func _resolve_scene_placement_actor() -> ScenePlacementActor:
	var cursor: Node = self
	while cursor != null:
		if cursor is ScenePlacementActor:
			return cursor as ScenePlacementActor
		cursor = cursor.get_parent()
	return null


## 网格参数的唯一来源 = 祖先 SPA。
func _require_spa() -> ScenePlacementActor:
	var spa := _scene_placement_actor()
	if spa != null:
		return spa
	push_error("[SPASelectionHost] 父链上找不到 ScenePlacementActor（self=%s）——本组件必须挂在 SPA 子树下，网格参数无来源。" % [
		str(get_path()) if is_inside_tree() else name])
	assert(false, "[SPASelectionHost] no ancestor ScenePlacementActor")
	return null

## 返回 SPA 网格尺寸。
func _spa_grid_size() -> Vector3i:
	var spa := _require_spa()
	return spa.grid_size if spa != null else Vector3i.ZERO

## 返回 SPA 体素尺寸。
func _spa_voxel_size() -> Vector3:
	var spa := _require_spa()
	return spa.voxel_size if spa != null else Vector3.ONE

## 返回 SPA 网格世界原点。
func _spa_grid_origin() -> Vector3:
	var spa := _require_spa()
	return spa.grid_origin if spa != null else Vector3.ZERO


## 注入 AutoObject 点选数据；传 `{}` 清空。
func set_autoobject_pick_data(data: Dictionary) -> void:
	_autoobject_runtime_ready = bool(data.get("runtime_ready", false))
	_autoobject_positions.assign(data.get("positions", []))
	_autoobject_asset_indices.assign(data.get("asset_indices", []))
	_autoobject_ids.assign(data.get("object_ids", []))
	_autoobject_voxel_mins.assign(data.get("voxel_mins", []))
	_autoobject_side_count = int(data.get("side_count", 0))
	_autoobject_spacing_voxels = maxi(int(data.get("spacing_voxels", 1)), 1)
	_profile_ids.assign(data.get("profile_ids", []))
	_asset_names.assign(data.get("asset_names", []))


## 通知 HUD 刷新。
func _notify_hud() -> void:
	if _hud_update_callback.is_valid():
		_hud_update_callback.call()


## 选择层的视口输入入口。
func handle_viewport_input(viewport_camera: Camera3D, event: InputEvent) -> bool:
	_editor_camera = viewport_camera
	if event is InputEventMouseButton:
		if _handle_editor_mouse_button(viewport_camera, event as InputEventMouseButton):
			return true
	elif event is InputEventKey:
		if _handle_editor_key(event as InputEventKey):
			return true
	return false


## 释放点选 GPU 资源。
##
## ⚠ 本函数曾 dispose 旧的 `VoxelPickGPU`（射线拾取器）。旧路退役后本类**不再持有任何
## RenderingDevice 资源**：ID pass 的 SubViewport / 镜像节点归 `PickIdPass` 自己，
## 随节点释放。签名与两个调用点（demo 的 PREDELETE 显式先调 + 本类 PREDELETE 兜底）保留，
## 是为了将来本类若再持有 GPU 资源时有现成的释放口，而不是让调用方去猜该不该调。
func release_gpu_resources(_sync_before_free := false) -> void:
	pass


## 处理资源释放及失焦时的输入状态复位。
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		release_gpu_resources(true)
	elif what == NOTIFICATION_EXIT_TREE or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		# 切标签页/失焦时配对 release 可能永不到达，主动复位防"点击被吃"。
		_consume_editor_mouse_release = false


## 重建地形高度场缓存。
func refresh_terrain_cache() -> void:
	_repair_soft_reloaded_terrain_revision()
	_terrain_field_revision += 1
	var terrain := TerrainInitializerScript.find_edit_time_terrain(self) as MeshInstance3D
	if terrain == null or terrain.mesh == null:
		_terrain_field_res = 0
		_terrain_field = PackedFloat32Array()
		return
	_terrain_field_res = 128
	_terrain_field = TerrainInitializerScript.terrain_height_field_from_mesh(
		terrain, _terrain_field_res, TerrainConfigScript.MAX_HEIGHT)


## 采样世界 XZ 位置的地形高度。
func sample_height(wx: float, wz: float) -> float:
	return TerrainHeightFieldScript.sample_height(
		_terrain_field, _terrain_field_res, TerrainConfigScript.CAPTURE_SIZE, wx, wz)


## AutoObject 标记的基础尺寸。
func autoobject_marker_size() -> float:
	var size := _spa_voxel_size()
	return maxf(minf(size.x, size.z) * 0.52, 0.35)


## 把 SVTile dirty flags 压成选择标签里的一行内联片段（`flags=[scene,collision]`），空集为 `clean`。
## ⚠ 不是 CSV：没有表头/引号/转义，也没有任何反向解析方——键名是 flags_from_bits 的固定
## ASCII 标识符，永远不含逗号。分隔符与括号纯粹服务于标签那三行的显示预算，可随标签改。
static func format_tile_dirty_flags(tile_record: Dictionary) -> String:
	var flags: Dictionary = tile_record.get("dirty_flags", {})
	var names := PackedStringArray()
	for key in flags.keys():
		if bool(flags[key]):
			names.append(str(key))
	return ",".join(names) if names.size() > 0 else "clean"


# ---- 公开查询 --------------------------------------------------------------

# ⚠ 这里曾有 `voxel_display_effective_visible()` 与 `apply_selection_mode_visuals()` 两个薄包装。
# 前者转发给 `_voxel_display_effective_visible()`，而那一层同样只是转发（一并删除，见下）；
# 后者转发给 `_apply_selection_mode_visuals()`（今 `_refresh_selection_markers()`）且**全仓零调用点**。
#
# 「effective」这个名字曾经有意义：它是「显示开关 AND 模式聚焦」的与值。选择模式整体退役
# （2026-08-10）后与值塌成单边，于是三个名字指向同一个 `_voxel_display_is_visible()`。
# 公开查询口统一为 `is_voxel_display_visible()` —— 桥与 `tools/pick_id_click_types.js` 用的就是它。


## 为诊断创建一次性相机和 SubViewport。
func _make_probe_camera(spec: Dictionary, viewport_size: Vector2i, name_prefix: String) -> Dictionary:
	var cam_pos := _spec_vector3(spec.get("pos", []), Vector3(0.0, 400.0, 0.0))
	var look_at := _spec_vector3(spec.get("look_at", []), Vector3.ZERO)

	var probe_viewport := SubViewport.new()
	probe_viewport.name = "%sProbeViewport" % name_prefix
	probe_viewport.size = Vector2i(maxi(viewport_size.x, 1), maxi(viewport_size.y, 1))
	# 只需要投影数学，不需要出图。
	probe_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(probe_viewport)

	var cam := Camera3D.new()
	cam.name = "%sProbeCamera" % name_prefix
	cam.fov = float(spec.get("fov", 60.0))
	cam.far = 8000.0
	probe_viewport.add_child(cam)
	cam.current = true
	var look_dir := look_at - cam_pos
	if look_dir.length_squared() <= 0.000001:
		look_dir = Vector3(0.0, -1.0, 0.0)
	var look_up := Vector3.UP
	if absf(look_dir.normalized().dot(look_up)) > 0.999:
		look_up = Vector3.FORWARD
	cam.global_transform = Transform3D(Basis.looking_at(look_dir, look_up), cam_pos)
	return {"viewport": probe_viewport, "camera": cam}


# ---- ID pass 与诊断 --------------------------------------------------------

## 惰性创建 ID pass。
func _ensure_pick_id_pass() -> Node:
	if _pick_id_pass != null and is_instance_valid(_pick_id_pass) and _pick_id_pass.is_inside_tree():
		return _pick_id_pass
	var old := get_node_or_null(NodePath(PICK_ID_PASS_NODE_NAME))
	if old != null:
		# 先摘下再 free：queue_free 挂起期内旧节点仍占名，同帧新建同名节点会被自动改名。
		remove_child(old)
		old.queue_free()
	var pass_node: Node = PickIdPassScript.new()
	pass_node.name = PICK_ID_PASS_NODE_NAME
	add_child(pass_node)
	_pick_id_pass = pass_node
	return _pick_id_pass


## 收集当前可见的可点选 drawable。
func collect_pick_drawables() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var tree := get_tree()
	if tree == null:
		return out
	for display_key in PICK_ID_DISPLAY_KEYS:
		var domain := str(SPAEditorContract.binding_for_display_key(display_key).get("domain", ""))
		if domain.is_empty():
			push_error("[SPA Selection] ID pass 的显示键 \"%s\" 在合同表里没有 domain —— 命中无法映射回选择记录。" % display_key)
			assert(false, "SPASelectionHost.collect_pick_drawables: display key without domain")
			continue
		for node in tree.get_nodes_in_group(SPAEditorContract.voxel_display_group(display_key)):
			if node == null or not is_instance_valid(node) or not (node is Node3D):
				continue
			if not (node as Node3D).is_visible_in_tree():
				continue
			var entries: Array = []
			if node.has_method("get_pick_drawables"):
				entries = node.call("get_pick_drawables")
			elif node is MultiMeshInstance3D and node.has_meta(PICK_DRAWABLE_META):
				var meta = node.get_meta(PICK_DRAWABLE_META)
				if meta is Dictionary:
					var one: Dictionary = (meta as Dictionary).duplicate()
					one["node"] = node
					entries = [one]
			if entries.is_empty() and not node.has_method("get_pick_drawables") \
					and not node.has_meta(PICK_DRAWABLE_META):
				push_error("[SPA Selection] 显示键 \"%s\" 下的节点 %s 既没有 get_pick_drawables() 也没有 %s 元数据 —— 该域在 ID pass 里静默缺席。" % [
					display_key, node.name, PICK_DRAWABLE_META])
				assert(false, "SPASelectionHost.collect_pick_drawables: display node exposes no pick drawable")
				continue
			for entry in entries:
				if not (entry is Dictionary):
					continue
				var desc: Dictionary = (entry as Dictionary).duplicate()
				desc["domain"] = domain
				desc["display_key"] = display_key
				out.append(desc)
	return out

# ⚠ 这里曾有 `_collect_targetsv_pick_drawable()`（按 `TargetSVSetup.DISPLAY_NODE` 节点名
# 硬取的专用收集口）。TargetSV 并入 PICK_ID_DISPLAY_KEYS 的通用组扫描后删除
# （2026-08-10）——节点经基类 register_pick_drawable() 已在 "targetsv" 显示组里，
# 两条收集路收同一个节点，删专用留通用。


## object_id → `_autoobject_positions` 的下标。
func _autoobject_index_for_object_id(object_id: int) -> int:
	if object_id < 0:
		return -1
	for i in range(_autoobject_ids.size()):
		if int(_autoobject_ids[i]) == object_id:
			return i
	return -1


## 按指定相机位姿准备诊断 ID pass。
func pick_id_prepare_at_camera_pose(spec_json: String) -> String:
	var parsed = JSON.parse_string(spec_json)
	if not (parsed is Dictionary):
		return JSON.stringify({"ok": false, "reason": "bad_spec_json"})
	var spec: Dictionary = parsed
	var viewport_size := _spec_vector2i(spec.get("viewport", [1440, 900]), Vector2i(1440, 900))

	_free_pick_id_probe_camera()
	var probe := _make_probe_camera(spec, viewport_size, "PickId")
	_pick_id_probe_viewport = probe["viewport"]
	_pick_id_probe_camera = probe["camera"]

	var pass_node := _ensure_pick_id_pass()
	if pass_node == null:
		return JSON.stringify({"ok": false, "reason": "pick_id_pass_unavailable"})
	var drawables := collect_pick_drawables()
	var result: Dictionary = pass_node.call(
		"prepare", _pick_id_probe_camera, viewport_size, drawables,
		int(spec.get("id_base_offset", 0)))
	result["autoobject_positions"] = _autoobject_positions.size()
	result["autoobject_runtime_ready"] = _autoobject_runtime_ready
	return JSON.stringify(result)


## 返回 prepare 后已经绘制的帧数。
func pick_id_frames_since_prepare() -> int:
	if _pick_id_pass == null or not is_instance_valid(_pick_id_pass):
		return -1
	return int(_pick_id_pass.call("frames_since_prepare"))


## 按 drawable 采样命中像素和 ID 区间。
func pick_id_sample_hit_pixels_per_drawable(max_per_drawable: int = 12, stride: int = 2) -> String:
	if _pick_id_pass == null or not is_instance_valid(_pick_id_pass):
		return JSON.stringify({"ok": false, "reason": "pick_id_pass_missing"})
	return JSON.stringify({
		"ok": true,
		"points": _pick_id_pass.call("sample_hit_pixels_per_drawable", max_per_drawable, stride),
		"ranges": _pick_id_pass.call("range_report"),
	})


## 解码命中，并可用同一相机与旧路对比。
func pick_id_resolve_at_camera_pose(spec_json: String) -> String:
	var parsed = JSON.parse_string(spec_json)
	if not (parsed is Dictionary):
		return JSON.stringify({"ok": false, "reason": "bad_spec_json"})
	var spec: Dictionary = parsed
	if _pick_id_pass == null or not is_instance_valid(_pick_id_pass):
		return JSON.stringify({"ok": false, "reason": "pick_id_pass_missing"})
	if _pick_id_probe_camera == null or not is_instance_valid(_pick_id_probe_camera):
		return JSON.stringify({"ok": false, "reason": "probe_camera_missing"})
	var viewport_size := _spec_vector2i(spec.get("viewport", [1440, 900]), Vector2i(1440, 900))
	var screen := _spec_vector2(spec.get("screen", []), Vector2(viewport_size) * 0.5)

	var hit: Dictionary = _pick_id_pass.call("resolve", screen)
	var out := {
		"ok": bool(hit.get("ok", false)),
		"reason": str(hit.get("reason", "")),
		"pick_id": int(hit.get("pick_id", 0)),
		"rgb8": hit.get("rgb8", []),
		"domain": str(hit.get("domain", "")),
		"local_index": int(hit.get("local_index", -1)),
		"range_base": int(hit.get("range_base", 0)),
		# 命中落在哪个 drawable 节点上。
		"node_path": str(hit.get("node_path", "")),
		"screen": [screen.x, screen.y],
	}
	var domain := str(hit.get("domain", ""))
	var id_index := -1
	var id_object_id := -1
	var id_voxel := Vector3i(-1, -1, -1)
	if bool(hit.get("hit", false)):
		var payload: Dictionary = hit.get("payload", {})
		out["payload_ok"] = bool(payload.get("ok", false))
		out["payload_reason"] = str(payload.get("reason", ""))
		if bool(payload.get("ok", false)):
			# ⚠ 这里曾按域分六个分支各取各的字段（voxel_index / tile_index / anchor_index /
			# object_id）。点选载荷瘦身为「域 + element_index」后（2026-08-10），域族的四个域
			# 走同一条：下标就是 element_index，坐标问域自己的寻址口。
			# 剩下两个特例是**族外** drawable（anchor 的 demo 手搓节点、autoobject 的容器形态），
			# 它们的载荷不由 PickableDomain 生产，形状因此不同。
			if payload.has("element_index"):
				id_index = int(payload.get("element_index", -1))
				# 瓦片域刻意没有"代表体素"：element_to_voxel 给的是瓦片原点，
				# 只作为覆盖范围的下界带出（与记录构建口同一条）。
				id_voxel = _domain_element_voxel(hit, id_index)
			elif domain == SELECTION_DOMAIN_AUTOOBJECT:
				# 唯一仍不由 PickableDomain 生产载荷的域：`PlacedInstanceDisplay` 的容器形态
				# 自己 set_meta 挂解码口，给的是 object_id 而不是 element_index。
				id_object_id = int(payload.get("object_id", -1))
				id_index = _autoobject_index_for_object_id(id_object_id)
			else:
				push_error("[SPA Selection] ID pass 命中了没有载荷解释规则的域 \"%s\"（payload 键=%s）—— 命中无法映射回选择记录。" % [
					domain, str(payload.keys())])
				assert(false, "SPASelectionHost: pick id hit in an unhandled domain")
	out["id_object_id"] = id_object_id
	out["id_index"] = id_index
	# ⚠ 这里曾有 `id_kind`（载荷里的 "sv_cell" / "svtile_tile" 这类字符串）。它是 domain 的
	# 派生物、而 `out["domain"]` 就在上面几行——载荷瘦身时一并去掉，不留第二份类型表示。
	if (domain == SELECTION_DOMAIN_SV or domain == SELECTION_DOMAIN_BRUSH) and id_voxel.x >= 0:
		# SV / Brush 只如实带出坐标。
		out["id_voxel"] = _vec3i_to_array(id_voxel)
	if domain == SELECTION_DOMAIN_TARGETSV and id_voxel.x >= 0:
		out["id_voxel"] = _vec3i_to_array(id_voxel)
		# 格子在屏幕上有多大（`unproject_position` 投影，不是射线）。
		out["id_cell_screen_radius_px"] = _targetsv_cell_screen_radius(_pick_id_probe_camera, id_voxel)

	# ⚠ 这里曾有整套「同一域、同一相机、同一屏幕点再跑一遍旧路」的对照，输出
	# `legacy_index` / `legacy_object_id` / `legacy_voxel` / `same_column` / `agree` /
	# `id_center_dist_px` / `legacy_center_dist_px` 七个键。旧路已整体退役（三角形 ID 唯一路，
	# 2026-08-10）⇒ **没有对照物了**，这些键随之删除。
	#
	# 读旧报告时注意：`agree == false` 在历史数据里可能只是"两路语义本就不同"（§10 的刻意变更），
	# 不是缺陷。新报告不再有这个字段。
	#
	# ⚠ 2026-08-11：`id_ray_in_winner_aabb` / `id_ray_in_cell` 两个键连同它们背后的
	# `_anchor_winner_aabb_hit()` / `_targetsv_ray_in_cell()` 一并删除——**本仓不再有任何射线
	# 辨别逻辑**（用户裁定：辨别完全走 ID）。这两个键此前是"点击射线是否穿过命中体"的独立几何
	# 校验，全仓无外部消费方。代价要认：ID pass 的命中结果现在没有第二种几何手段可交叉验证了，
	# 要查"选中的东西对不对"只能看 `domain` / `id_index` / `id_voxel` 本身。
	return JSON.stringify(out)


# ⚠ 这里曾有 `_anchor_winner_aabb_hit()`：`project_ray_origin/normal` 造点击射线，再问它是否
# 穿过锚点胜出物的世界 AABB。2026-08-11 随「辨别完全走 ID」一并删除（全仓最后一处射线辨别）。


## TargetSV 体素坐标 → 线性下标（比对用；与显示写入用的是同一条规范索引式）。
func _targetsv_voxel_index(voxel: Vector3i) -> int:
	if voxel.x < 0:
		return -1
	var targetsv := _find_targetsv_setup()
	if targetsv == null:
		return -1
	var geometry := _targetsv_geometry_metadata(targetsv)
	if geometry.is_empty():
		return -1
	return VoxelGeneral.voxel_index(voxel, geometry["grid_size"])


# ⚠ 这里曾有 `_targetsv_ray_in_cell()`：造点击射线再问它是否穿过 TargetSV 体素盒。
# 与 `_anchor_winner_aabb_hit()` 同批删除（2026-08-11，辨别完全走 ID）。
# ⚠ 下面的 `_targetsv_cell_screen_radius()` **不是**射线：它走 `unproject_position()` 投影，
# 量的是格子在屏幕上占多少像素，与命中判定无关，故保留。


## 某个 TargetSV 格子在屏幕上的半径（像素）：把半格沿相机右/上两个方向的偏移各投影一次， 取较大者。
func _targetsv_cell_screen_radius(cam: Camera3D, voxel: Vector3i) -> float:
	if cam == null or not is_instance_valid(cam):
		return -1.0
	var center := _targetsv_voxel_world_center(voxel)
	if center.x == INF or cam.is_position_behind(center):
		return -1.0
	var targetsv := _find_targetsv_setup()
	var geometry := _targetsv_geometry_metadata(targetsv) if targetsv != null else {}
	if geometry.is_empty():
		return -1.0
	var cell: Vector3 = geometry["voxel_size"]
	var basis := cam.global_transform.basis
	var at_center := cam.unproject_position(center)
	var radius := 0.0
	var offsets: Array[Vector3] = [basis.x * cell.x * 0.5, basis.y * cell.y * 0.5]
	for offset in offsets:
		var probe := center + offset
		if cam.is_position_behind(probe):
			continue
		radius = maxf(radius, cam.unproject_position(probe).distance_to(at_center))
	return radius


## TargetSV 体素的世界格心。
func _targetsv_voxel_world_center(voxel: Vector3i) -> Vector3:
	var targetsv := _find_targetsv_setup()
	if targetsv == null or not (targetsv is Node3D):
		return Vector3(INF, INF, INF)
	if not _require_targetsv_api(targetsv, ["voxel_to_world"]):
		return Vector3(INF, INF, INF)
	var local: Vector3 = targetsv.voxel_to_world(voxel.x, voxel.y, voxel.z)
	return (targetsv as Node3D).to_global(local)


# ⚠ 这里曾有 `_rebuild_pick_id_anchor_bounds()`：每趟 prepare 向 VolumeScore 拉一遍
# `get_selectable_anchor_bounds()`，建 anchor_index → AABB 索引存进 `_pick_id_anchor_bounds`。
# 那份索引的**唯一读者**是已删除的 `_anchor_winner_aabb_hit()`（射线校验），随它一并删除：
# 成员、重建函数、以及 `pick_id_prepare` 里的那次调用。留着就是每趟 prepare 白拉一次锚点包围盒。


func _free_pick_id_probe_camera() -> void:
	if _pick_id_probe_camera != null and is_instance_valid(_pick_id_probe_camera):
		_pick_id_probe_camera.current = false
	if _pick_id_probe_viewport != null and is_instance_valid(_pick_id_probe_viewport):
		_pick_id_probe_viewport.queue_free()
	_pick_id_probe_viewport = null
	_pick_id_probe_camera = null


# ⚠ 这里曾有 `_pick_probe_payload(result)`：把一次命中拍平成可 JSON 序列化的探针载荷
# （domain / geometry / id / pick_backend / voxel_coord / … 12 个键）。它的调用方是旧路
# 那条"点一下、把两条命中算法的结果并排导出来对照"的探针出口；旧路退役后对照物没有了，
# 探针改为直接导 ID pass 的结果 + 独立几何校验，本函数自此零调用方。已删除（2026-08-12）。
# ⚠ 它读的 `record["pick_backend"]` 也是旧路遗留（值域是"GPU 求交 / CPU 遍历"二选一），
# 想恢复导出请从当前 record 的真实键集重写，别照这份键表取回。


## 将 Vector3 转为可 JSON 序列化的数组。
static func _vec3_to_array(value) -> Array:
	var v: Vector3 = value if value is Vector3 else Vector3.ZERO
	return [v.x, v.y, v.z]


## 将 Vector3i 转为可 JSON 序列化的数组。
static func _vec3i_to_array(value) -> Array:
	var v: Vector3i = value if value is Vector3i else Vector3i.ZERO
	return [v.x, v.y, v.z]


## 从数组读取 Vector3，格式无效时返回 fallback。
static func _spec_vector3(value, fallback: Vector3) -> Vector3:
	if value is Array and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return fallback


## 从数组读取 Vector2，格式无效时返回 fallback。
static func _spec_vector2(value, fallback: Vector2) -> Vector2:
	if value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	return fallback


## 从数组读取 Vector2i，格式无效时返回 fallback。
static func _spec_vector2i(value, fallback: Vector2i) -> Vector2i:
	if value is Array and value.size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	return fallback


## 按体素坐标选择数据域元素。
## `domain` 使用 SELECTION_DOMAIN_* 字符串。
func select_data_voxel(domain: String, x: int, y: int, z: int) -> Dictionary:
	if SPAEditorContract.domain_requires_scene_voxel_committer(domain) and _sv_committer == null:
		return {"ok": false, "reason": "scene_voxel_committer_unavailable", "domain": domain}
	var record := _data_record_for_voxel(domain, Vector3i(int(x), int(y), int(z)))
	if record.is_empty():
		return {"ok": false, "reason": "no_data_record", "domain": domain}
	set_active_selection(record)
	return {"ok": true, "domain": str(record.get("domain", "")), "geometry": str(record.get("geometry", "")), "record": record}


## 注册 volume-score anchor provider。
func register_volume_score_provider(provider: Node) -> void:
	if provider == null or not is_instance_valid(provider) or not provider.is_inside_tree():
		return
	if _volume_score_provider == provider:
		return
	_volume_score_provider = provider
	print("[SPA VolumeScore] Provider registered: %s" % str(provider.get_path()))
	refresh_volume_score_anchor_selection()


## 注销 volume-score anchor provider。
func unregister_volume_score_provider(provider: Node) -> void:
	if provider != null and _volume_score_provider == provider:
		_volume_score_provider = null
		if _active_selection_is_volume_score_anchor():
			_active_selection.clear()
			_hide_node_if_valid(_selection_marker)
			_update_anchor_sample_bounds_marker()
			_notify_hud()


# ---- Anchor 选中态 ----------------------------------------------------------
#
# ⚠ 这里曾有一个 `_selected_anchor_idx` 专用槽，与 `_active_selection` 并列成**两份**
# 选中态表示。它是 anchor 与其余五域之间最后的结构性差异，也是一次真实缺陷的根源：
# `set_active_selection()` 会清掉那个下标，anchor 因此只能绕开它，绕的时候把"显示 marker"
# 一起丢了（点击命中、选中态更新，框却停在上一个锚点）。
#
# 现在 anchor 的选中态与其余五域**同一份**：就是 `_active_selection`，下标存在记录的
# `anchor_index` 字段里。六个域的选择路径因此完全对称，没有任何派生。

## 当前选中的 anchor 下标（-1 = 当前没选中 anchor）。从统一选中态里读，不另存。
func get_selected_anchor_index() -> int:
	if not _active_selection_is_volume_score_anchor():
		return -1
	return int(_active_selection.get("anchor_index", -1))


## 选中锚点：建记录 + 走**统一**入口写入选中态（与其余五域同一条路）。
## 不做命中——命中在调用方（ID pass 或 demo 的 UI）。
func select_anchor(anchor_index: int) -> Dictionary:
	var spa := _scene_placement_actor()
	if spa == null:
		return {"ok": false, "reason": "scene_placement_actor_unavailable"}
	if anchor_index < 0 or anchor_index >= spa.get_anchor_count():
		return {"ok": false, "reason": "anchor_index_out_of_range"}
	var record := _volume_score_selection_record(anchor_index)
	if record.is_empty():
		return {"ok": false, "reason": "anchor_record_unavailable"}
	set_active_selection(record)
	return {"ok": true, "anchor_index": anchor_index}


## 清除当前 anchor 选择。⚠ 只在当前选中确实是 anchor 时清——选中态是共用的，
## 无条件清会把别的域的选中一起抹掉。
func clear_selected_anchor() -> Dictionary:
	if _active_selection_is_volume_score_anchor():
		clear_active_selection()
	return {"ok": true}


## 返回 Inspector 使用的 anchor 评分摘要。
func get_selected_anchor_summary_text() -> String:
	var spa := _scene_placement_actor()
	if spa == null:
		return ""
	return spa.get_anchor_summary_text(get_selected_anchor_index(), _anchor_topk_limit())


## Top-K 展示条数。
func _anchor_topk_limit() -> int:
	var spa := _scene_placement_actor()
	if spa == null:
		return 4
	var handoff: Dictionary = spa.get_anchor_candidate_handoff()
	return maxi(int(handoff.get("topk", 4)), 1)



## 重建当前选中锚点的记录（评分/放置改了数据之后刷新详情）。
##
## ⚠ 这里曾叫"把 provider 的 anchor 选择镜像到 SPA 选中态"——那是 anchor 的选中态还
## 另存在 `_selected_anchor_idx` 时的说法。现在选中态与其余五域同一份，本函数只是
## **按当前选中的下标重取一遍记录**，写入仍走统一入口。
func refresh_volume_score_anchor_selection() -> Dictionary:
	var anchor_index := get_selected_anchor_index()
	if anchor_index < 0:
		return {"ok": false, "reason": "no_selected_anchor"}
	var record := _volume_score_selection_record(anchor_index)
	if record.is_empty():
		# 锚点没了（重新生成/评分把它冲掉）：清掉本域的选中态，不动别的域。
		clear_selected_anchor()
		return {"ok": false, "reason": "no_selected_anchor"}
	set_active_selection(record)
	return {"ok": true, "record": record}


## 设置指定体素调试域是否显示
func set_voxel_display_visible(display_key: String, visible: bool) -> void:
	_normalize_voxel_display_state()
	# 未知键必须报错。
	if not _voxel_display_visible.has(display_key):
		push_error("[SPA Selection] 未知体素显示键 \"%s\"，开关无效。合法键：%s" % [
			display_key, str(_voxel_display_visible.keys())])
		assert(false, "SPASelectionHost: unknown voxel display key")
		return
	_voxel_display_visible[display_key] = visible
	# ⚠ 只推**被改的这一个键**。别在这里补一发全量重推：那正是「翻 Anchors 连带重驱
	# TargetSV」的老路（见 `_refresh_selection_markers()` 的注释）。
	_apply_external_voxel_display_visibility(display_key)
	_refresh_selection_markers()
	_notify_hud()


## 返回指定体素调试域是否显示
func is_voxel_display_visible(display_key: String) -> bool:
	return _voxel_display_is_visible(display_key)


## 返回当前所有体素显示开关状态
func get_voxel_display_state() -> Dictionary:
	_normalize_voxel_display_state()
	return _voxel_display_visible.duplicate(true)


## 重建体素显示开关，供编辑器MCP/热重载后刷新。
## 这里**才是**全量重推的语义所在：六个键各自把自己的记账位推给自己那一组节点。
func refresh_voxel_display_controls() -> void:
	_apply_all_external_voxel_display_visibility()
	_refresh_selection_markers()


## 返回外部 voxel 显示节点的 SPA 容器。
func get_voxel_display_root(owner_key: String = "external") -> Node3D:
	var external_root := _ensure_external_voxel_display_root()
	if external_root == null:
		return null
	var owner_name := SPAEditorContract.external_voxel_display_owner_name(owner_key)
	var owner_root := external_root.get_node_or_null(NodePath(owner_name)) as Node3D
	if owner_root == null:
		owner_root = Node3D.new()
		owner_root.name = owner_name
		external_root.add_child(owner_root, true)
	return owner_root


## 将外部显示根节点挂到 SPA。
func attach_voxel_display_root(display_root: Node3D, owner_key: String = "external") -> Node3D:
	if display_root == null:
		return null
	var owner_root := get_voxel_display_root(owner_key)
	if owner_root == null:
		return null
	if display_root.get_parent() != owner_root:
		var keep_global := display_root.is_inside_tree()
		var global_before := display_root.global_transform if keep_global else Transform3D.IDENTITY
		var parent := display_root.get_parent()
		if parent != null:
			parent.remove_child(display_root)
		owner_root.add_child(display_root, true)
		if keep_global and display_root.is_inside_tree():
			display_root.global_transform = global_before
	return owner_root


## 注册一个外部 voxel 显示节点。
func register_voxel_display_node(display_key: String, node: Node3D, owner_key: String = "external") -> void:
	_normalize_voxel_display_state()
	if node == null or not _voxel_display_visible.has(display_key):
		return
	_ensure_external_voxel_display_root()
	node.add_to_group(SPAEditorContract.voxel_display_group(display_key))
	node.visible = _voxel_display_is_visible(display_key)


## 查询体素显示开关。
func _voxel_display_is_visible(display_key: String) -> bool:
	_normalize_voxel_display_state()
	# 未知键按不可见处理。
	if not _voxel_display_visible.has(display_key):
		push_error("[SPA Selection] 未知体素显示键 \"%s\" —— 按不可见处理。合法键：%s" % [
			display_key, str(_voxel_display_visible.keys())])
		assert(false, "SPASelectionHost: unknown voxel display key on visibility query")
		return false
	return bool(_voxel_display_visible[display_key])


# ⚠ 这里曾有 `_voxel_display_effective_visible()`：只转发给上面的 `_voxel_display_is_visible()`。
# 它存在的前提是「渲染可见性 = 显示开关 AND 模式聚焦」，而模式聚焦已随选择模式退役
# （`spa_editor_contract.gd` 里 `mode_focuses_display_key` 那条注释记的就是这段历史）。
# 前提没了就只剩一次转发，已删除；调用点直接问 `_voxel_display_is_visible()`。


## 确保运行时显示状态覆盖合同表里的所有体素域
func _normalize_voxel_display_state() -> void:
	for display_key in SPAEditorContract.default_voxel_display_state().keys():
		if not _voxel_display_visible.has(display_key):
			_voxel_display_visible[display_key] = true


# ⚠ 这里曾有 `_volume_score_anchor_display_active()`（"有没有可选 anchor"）与它上面那层
# `_volume_score_anchor_selection_allowed()`（只是给 `_domain_pick_allowed(ANCHOR)` 换名）。
# 两者是一条**只剩自己在用的链**：外层零调用点，内层只被外层调。ID 路不需要"先问域里有没有
# 东西"——点到什么就是什么，域是空的自然什么都点不中。2026-08-11 一并删除。


## 把已经选定的锚点落成选中态与选择记录。
func _commit_volume_score_anchor(anchor_index: int) -> Dictionary:
	if anchor_index < 0:
		return {}
	# 与其余五域**完全同构**：建记录 → 打 pick_backend → set_active_selection。
	var record := _volume_score_selection_record(anchor_index)
	if record.is_empty():
		return {}
	# 本函数的唯一调用方是 `_pick_id_commit_hit` 的 anchor 分支 ⇒ 这次选中必然来自 ID pass。
	record["pick_backend"] = "pick_id"
	set_active_selection(record)
	return {
		"ok": true,
		"domain": SELECTION_DOMAIN_ANCHOR,
		"geometry": SELECTION_GEOMETRY_VOLUME_SCORE_ANCHOR,
		"record": record,
		"anchor_index": anchor_index,
		"topk": record.get("topk", []),
	}
## 建一条 anchor 选择记录。⚠ 下标**显式传入**，不再从成员槽读——
## 记录是选中态的唯一载体，建它的时候还没有"当前选中"可言。
func _volume_score_selection_record(anchor_index: int, selection_result: Dictionary = {}) -> Dictionary:
	if anchor_index < 0:
		return {}
	var spa := _scene_placement_actor()
	if spa != null:
		var built: Dictionary = spa.get_anchor_selection_record(
			anchor_index, _anchor_topk_limit())
		if not built.is_empty():
			# ⚠ 补齐 anchor_index：它是本域在统一选中态里的身份，`get_selected_anchor_index()`
			# 与 `_selection_state_identity()` 都从这里读。provider 建的记录一般已带，
			# 缺了就补，不能让身份落到 -1。
			if not built.has("anchor_index"):
				built["anchor_index"] = anchor_index
			return built
	var record := selection_result.duplicate(true)
	if record.is_empty():
		record["summary"] = spa.get_anchor_summary_text(anchor_index, _anchor_topk_limit()) if spa != null else ""
		record["tooltip"] = spa.get_anchor_tooltip_text(anchor_index, _anchor_topk_limit()) if spa != null else ""
	record["domain"] = SELECTION_DOMAIN_ANCHOR
	record["geometry"] = SELECTION_GEOMETRY_VOLUME_SCORE_ANCHOR
	record["anchor_index"] = anchor_index
	if not record.has("id"):
		record["id"] = "volume_score_anchor:%d" % anchor_index
	return record


## 获取或创建外部 voxel 显示根节点。
func _ensure_external_voxel_display_root() -> Node3D:
	if _external_voxel_display_root != null and is_instance_valid(_external_voxel_display_root):
		return _external_voxel_display_root
	var existing := get_node_or_null(NodePath(EXTERNAL_VOXEL_DISPLAY_ROOT_NAME)) as Node3D
	if existing != null:
		_external_voxel_display_root = existing
		return _external_voxel_display_root
	_external_voxel_display_root = Node3D.new()
	_external_voxel_display_root.name = EXTERNAL_VOXEL_DISPLAY_ROOT_NAME
	add_child(_external_voxel_display_root, true)
	return _external_voxel_display_root


## 刷新所有外部 voxel 显示组的可见性。
func _apply_all_external_voxel_display_visibility() -> void:
	for display_key in _voxel_display_visible.keys():
		_apply_external_voxel_display_visibility(str(display_key))


## 按组下发可见性，而不是遍历 _external_voxel_display_root 子树。
func _apply_external_voxel_display_visibility(display_key: String) -> void:
	if not is_inside_tree():
		return
	var tree := get_tree()
	if tree == null:
		return
	var spa := _scene_placement_actor()
	var group := SPAEditorContract.voxel_display_group(display_key)
	var visible_now := _voxel_display_is_visible(display_key)
	for node in tree.get_nodes_in_group(group):
		if not (node is Node3D):
			continue
		if spa != null and not spa.is_ancestor_of(node):
			continue
		(node as Node3D).visible = visible_now




## 当前选择是否为 volume-score anchor。
func _active_selection_is_volume_score_anchor() -> bool:
	return str(_active_selection.get("geometry", "")) == SELECTION_GEOMETRY_VOLUME_SCORE_ANCHOR


## 当前活动选中的 box marker / label 是否应显示。SPA 统一出 box（含 volume-score anchor）。
func _active_selection_box_visible() -> bool:
	if _active_selection.is_empty():
		return false
	var key := SPAEditorContract.voxel_display_key_for_domain(str(_active_selection.get("domain", "")))
	return key.is_empty() or _voxel_display_is_visible(key)


## Anchor 采样范围标记需要 provider 提供 sample_bounds。
func _anchor_sample_bounds_visible(record: Dictionary) -> bool:
	if not show_anchor_sample_bounds:
		return false
	if not _voxel_display_is_visible(SPAEditorContract.voxel_display_key_for_domain(
			SELECTION_DOMAIN_ANCHOR)):
		return false
	return str(record.get("domain", "")) == SELECTION_DOMAIN_ANCHOR and record.has("sample_bounds")


## 刷新评分阶段的采样包围盒 marker。
func _update_anchor_sample_bounds_marker(record: Dictionary = {}) -> void:
	var source := record
	if source.is_empty() or str(source.get("geometry", "")) == SELECTION_GEOMETRY_VOLUME_SCORE_ANCHOR:
		# 按当前选中的锚点重取一份最新记录；没有选中锚点时退回统一选中态里的那一份。
		var selected_anchor := get_selected_anchor_index()
		var fresh_source := _volume_score_selection_record(selected_anchor) if selected_anchor >= 0 else {}
		if not fresh_source.is_empty():
			source = fresh_source
		elif source.is_empty() and _active_selection_is_volume_score_anchor():
			source = _active_selection
	if not _anchor_sample_bounds_visible(source):
		_hide_node_if_valid(_anchor_sample_bounds_marker)
		return
	var raw_bounds = source.get("sample_bounds", {})
	var aabb := _sample_bounds_aabb(raw_bounds)
	if aabb.size.length_squared() <= 0.000001:
		_hide_node_if_valid(_anchor_sample_bounds_marker)
		return
	_ensure_anchor_sample_bounds_marker()
	if _anchor_sample_bounds_marker == null:
		return
	_anchor_sample_bounds_marker.transform = _sample_bounds_transform(raw_bounds, aabb)
	_anchor_sample_bounds_marker.visible = true


## 优先使用 provider 的 OBB，否则使用轴对齐 AABB。
func _sample_bounds_transform(raw_bounds, aabb: AABB) -> Transform3D:
	if raw_bounds is Dictionary:
		var b := raw_bounds as Dictionary
		var obb_size: Vector3 = b.get("obb_size", Vector3.ZERO)
		if bool(b.get("has_obb", false)) and obb_size.length_squared() > 0.000001:
			var obb_center: Vector3 = b.get("obb_center", aabb.position + aabb.size * 0.5)
			var obb_yaw := float(b.get("obb_yaw", 0.0))
			var basis := Basis.from_euler(Vector3(0.0, obb_yaw, 0.0)) * Basis.from_scale(obb_size)
			return Transform3D(basis, obb_center)
	return Transform3D(Basis.from_scale(aabb.size), aabb.position + aabb.size * 0.5)


## 接受 AABB 或包含 position/size 的字典。
func _sample_bounds_aabb(raw_bounds) -> AABB:
	if raw_bounds is AABB:
		return raw_bounds
	if not (raw_bounds is Dictionary):
		return AABB()
	var bounds := raw_bounds as Dictionary
	if bounds.has("aabb") and bounds["aabb"] is AABB:
		return bounds["aabb"]
	var position: Vector3 = bounds.get("position", Vector3.ZERO)
	var size: Vector3 = bounds.get("size", Vector3.ZERO)
	return AABB(position, size)


## 创建红色线框范围标记。
func _ensure_anchor_sample_bounds_marker() -> void:
	var parent := self
	if _anchor_sample_bounds_marker == null or not is_instance_valid(_anchor_sample_bounds_marker):
		_anchor_sample_bounds_marker = _make_selection_marker("SelectedAnchorSampleBounds")
		parent.add_child(_anchor_sample_bounds_marker)
	_configure_selection_marker(_anchor_sample_bounds_marker)
	_anchor_sample_bounds_marker.material_override = DemoDebugVisuals.make_unshaded_material(
		ANCHOR_SAMPLE_BOUNDS_COLOR,
		false,
		true,
		true
	)




## 建立「域名 → 记录构建器」派发表。用直接方法引用而不是按字符串名 callv：
## 构建器改名/手误在这里就是解析期 "Identifier not found"，不是运行时静默落空。
##
## ⚠ 这里曾有一张并列的 `_data_pick_callables`（域名 → **命中算法**：地形射线 + 邻域搜索）。
## 三角形 ID 成为唯一命中方式后（2026-08-10）没有第二套命中算法可派发，整张表连同
## 四个 `_pick_*_record_with_camera` 一起删除。剩下的这张只做「已经定了是哪个体素 → 建记录」，
## 唯一消费者是 `select_data_voxel()`（按坐标的数据入口，不是屏幕拾取）。
func _ensure_selection_callables() -> void:
	if not _data_record_callables.is_empty():
		return
	_data_record_callables = {
		SELECTION_DOMAIN_SVTILE: _svtile_record_for_voxel,
		SELECTION_DOMAIN_ANCHOR: _anchor_record_for_voxel,
		SELECTION_DOMAIN_SV: _sv_record_for_voxel,
		SELECTION_DOMAIN_TARGETSV: _targetsv_record_for_selection_voxel,
	}


## 按域将体素坐标转为对应数据记录；AutoObject 通过 runtime 索引拾取，不走体素直选记录
func _data_record_for_voxel(domain: String, raw_voxel: Vector3i) -> Dictionary:
	_ensure_selection_callables()
	var cb: Callable = _data_record_callables.get(domain, Callable())
	if not cb.is_valid():
		return {}
	var voxel := _clamp_selection_voxel(raw_voxel) if SPAEditorContract.domain_requires_scene_voxel_committer(domain) else raw_voxel
	var result = cb.call(voxel)
	return result if result is Dictionary else {}


## 将体素坐标限制在合法范围内
func _clamp_selection_voxel(voxel: Vector3i) -> Vector3i:
	if _sv_committer == null:
		var res := maxi(autoobject_grid_resolution, 1)
		return Vector3i(clampi(voxel.x, 0, res - 1), maxi(voxel.y, 0), clampi(voxel.z, 0, res - 1))
	var grid := _spa_grid_size()
	return Vector3i(
		clampi(voxel.x, 0, maxi(grid.x - 1, 0)),
		clampi(voxel.y, 0, maxi(grid.y - 1, 0)),
		clampi(voxel.z, 0, maxi(grid.z - 1, 0))
	)


## 确保统一选中 marker 存在。（曾经还建一个 anchor 世界空间信息标签，见文件头 §选中可视化。）
func _ensure_selection_visual() -> void:
	var parent := self
	if _selection_marker == null or not is_instance_valid(_selection_marker):
		_selection_marker = _make_selection_marker("SelectedVoxelMarker")
		parent.add_child(_selection_marker)
	_configure_selection_marker(_selection_marker)


## 创建一个选中标记用的线框 Box 节点
func _make_selection_marker(node_name: String) -> MeshInstance3D:
	var marker := MeshInstance3D.new()
	marker.name = node_name
	_configure_selection_marker(marker)
	marker.visible = false
	return marker


## 配置选中标记材质。
func _configure_selection_marker(marker: MeshInstance3D) -> void:
	if marker == null:
		return
	if not (marker.mesh is ImmediateMesh):
		marker.mesh = DemoDebugVisuals.make_unit_wire_box_mesh()
	if marker.material_override == null:
		marker.material_override = DemoDebugVisuals.make_unshaded_material(Color(1.0, 0.9, 0.08, 0.92), false, true, true)
	marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## 若节点有效则隐藏它
func _hide_node_if_valid(node: Node) -> void:
	if node != null and is_instance_valid(node):
		node.visible = false


## 清除当前活动选中：隐藏 marker/anchor 标签，并可选清理 provider anchor。
## 清除当前活动选中：隐藏 marker / 标签 / 采样框。
## ⚠ 曾有第二个参数 `clear_anchor_selection`，用来跳过清 anchor 的专用下标槽——
## 那个槽已随「六域选中态统一」删除（2026-08-10），清 `_active_selection` 就是清全部。
func clear_active_selection(update_hud: bool = true) -> void:
	_active_selection.clear()
	_hide_node_if_valid(_selection_marker)
	_hide_node_if_valid(_anchor_sample_bounds_marker)
	if update_hud:
		_notify_hud()


## 统一写入选中态并刷新反馈。
func set_active_selection(record: Dictionary) -> void:
	if record.is_empty():
		return
	clear_active_selection(false)
	_active_selection = record.duplicate(true)
	_apply_selection_visual(_active_selection)
	_sync_editor_selection()
	_print_active_selection(_active_selection)
	_refresh_selection_markers()
	_notify_hud()


## 根据选择记录刷新 marker 和 anchor 反馈。
func _apply_selection_visual(record: Dictionary) -> void:
	var geometry := str(record.get("geometry", ""))
	_ensure_selection_visual()
	var color := _selection_domain_color(str(record.get("domain", "data")))
	var marker_pos: Vector3
	var marker_scale: Vector3
	if geometry == SELECTION_GEOMETRY_AUTOOBJECT:
		var base: Vector3 = record.get("position", Vector3.ZERO)
		var s := autoobject_marker_size() * 2.4
		marker_pos = base + Vector3(0.0, s * 0.45, 0.0)
		marker_scale = Vector3(s, s * 1.8, s)
	else:
		var base: Vector3 = record.get("world_position", Vector3.ZERO)
		var size: Vector3 = record.get("marker_size", _default_voxel_marker_size())
		marker_pos = base
		marker_scale = size
	if _selection_marker != null:
		_selection_marker.position = marker_pos
		_selection_marker.scale = marker_scale
		var mat := _selection_marker.material_override as StandardMaterial3D
		if mat != null:
			mat.albedo_color = color
		_selection_marker.visible = true
	_update_anchor_sample_bounds_marker(record)


## 把活动选中同步到编辑器 Selection（锚定到 marker，缺失时退回自身）
func _sync_editor_selection() -> void:
	if not Engine.is_editor_hint():
		return
	var sel := EditorInterface.get_selection()
	sel.clear()
	if _selection_marker != null and is_instance_valid(_selection_marker):
		sel.add_node(_selection_marker)
	else:
		sel.add_node(self)


## 打印活动选中（保留各域原有日志前缀）
func _print_active_selection(record: Dictionary) -> void:
	if str(record.get("geometry", "")) == SELECTION_GEOMETRY_AUTOOBJECT:
		print("[SPA SVTile] Selected GPU AutoObject: index=%d object_id=%d tile=%s profile_id=%d pos=%s" % [
			int(record.get("object_index", -1)),
			int(record.get("object_id", -1)),
			str(record.get("tile_coord", Vector3i.ZERO)),
			int(record.get("profile_id", -1)),
			str(record.get("position", Vector3.ZERO)),
		])
	else:
		print("[SPA Selection] Selected %s: %s" % [
			str(record.get("domain", "data")),
			str(record.get("id", "")),
		])


## 获取默认体素标记框尺寸
func _default_voxel_marker_size() -> Vector3:
	var size := _spa_voxel_size()
	return Vector3(
		maxf(size.x * 0.9, 0.25),
		maxf(size.y * 0.9, 0.5),
		maxf(size.z * 0.9, 0.25)
	)


## 根据选中域类型返回对应高亮颜色
func _selection_domain_color(domain: String) -> Color:
	match domain:
		SELECTION_DOMAIN_SVTILE:
			return Color(0.1, 0.65, 1.0, 0.92)
		SELECTION_DOMAIN_SV:
			return Color(0.1, 1.0, 0.62, 0.92)
		SELECTION_DOMAIN_TARGETSV:
			return Color(1.0, 0.28, 0.95, 0.92)
		SELECTION_DOMAIN_ANCHOR:
			return Color(1.0, 0.64, 0.1, 0.95)
	return SELECT_COLOR


## 返回编辑器视口覆盖层文本。
func get_selection_overlay_text() -> String:
	if _active_selection.is_empty() or not _active_selection_box_visible():
		return ""
	return _format_active_selection_overlay(_active_selection)


## 格式化当前选择信息。
func _format_active_selection_overlay(record: Dictionary) -> String:
	var domain := str(record.get("domain", "data"))
	var voxel: Vector3i = record.get("voxel_coord", Vector3i.ZERO)
	var tile: Vector3i = record.get("tile_coord", Vector3i.ZERO)
	if str(record.get("geometry", "")) == SELECTION_GEOMETRY_AUTOOBJECT:
		return "GPU AutoObject %d\nobject_id=%d  tile=%s" % [
			int(record.get("object_index", -1)),
			int(record.get("object_id", -1)),
			str(tile),
		]
	if str(record.get("geometry", "")) == SELECTION_GEOMETRY_VOLUME_SCORE_ANCHOR:
		var lines := PackedStringArray(["Anchor #%d  voxel=%s" % [int(record.get("anchor_index", -1)), str(voxel)]])
		for entry in record.get("topk", []):
			if not (entry is Dictionary):
				continue
			var e := entry as Dictionary
			var sc := float(e.get("score", -INF))
			var sc_text := ("%.2f" % sc) if sc > -1.0e20 else "n/a"
			var mark := "*" if bool(e.get("selected", false)) else " "
			var valid_suffix := "" if bool(e.get("valid", false)) else " invalid"
			lines.append("%s#%d %s  %s  yaw=%.0f%s" % [
				mark, int(e.get("rank", 0)), str(e.get("asset_name", "?")), sc_text, float(e.get("yaw", 0.0)), valid_suffix])
		return "\n".join(lines)
	match domain:
		SELECTION_DOMAIN_SVTILE:
			var svtile_record: Dictionary = record.get("tile_record", {})
			# -1 = object-ref 槽位缓冲取不到（记录构建时已 push_error）。
			var svtile_refs := int(record.get("object_ref_count", -1))
			return "SVTile %s\nrefs=%s  voxel=%s\nepoch=%d  flags=[%s]" % [
				str(tile),
				str(svtile_refs) if svtile_refs >= 0 else "n/a",
				str(voxel),
				int(svtile_record.get("epoch", 0)),
				format_tile_dirty_flags(svtile_record),
			]
		SELECTION_DOMAIN_SV:
			return "SceneVoxel %s\ncomplexity=%.3f collision=%.3f" % [
				str(voxel),
				float(record.get("complexity", 0.0)),
				float(record.get("collision", 0.0)),
			]
		SELECTION_DOMAIN_TARGETSV:
			return "TargetSV %s\ncomplexity=%.3f collision=%.3f" % [
				str(voxel),
				float(record.get("complexity", 0.0)),
				float(record.get("collision", 0.0)),
			]
		SELECTION_DOMAIN_ANCHOR:
			return "Anchor %s\nkind=%s" % [
				str(voxel),
				str(record.get("anchor_kind", "candidate")),
			]
	return "%s %s" % [domain, str(record.get("id", ""))]


## 获取 TargetSVSetup。
func _find_targetsv_setup() -> Node:
	return _target_sv if is_instance_valid(_target_sv) else null


## 校验 TargetSV 必需接口。
func _require_targetsv_api(targetsv: Node, method_names: Array) -> bool:
	for raw_name in method_names:
		var method_name := str(raw_name)
		if not targetsv.has_method(method_name):
			push_error("[SPA Selection] TargetSV 节点 '%s'(%s) 缺少契约方法 %s()。" % [
				str(targetsv.name), targetsv.get_class(), method_name])
			assert(false, "SPASelectionHost: TargetSV node missing contract method")
			return false
	return true


## 返回 TargetSV 的世界空间网格参数。
func _targetsv_geometry_metadata(targetsv: Node) -> Dictionary:
	if not _require_targetsv_api(targetsv, ["get_grid_frame"]):
		return {}
	if not (targetsv is Node3D):
		push_error("[SPA Selection] TargetSV 节点 '%s'(%s) 不是 Node3D，取不到世界原点。" % [
			str(targetsv.name), targetsv.get_class()])
		assert(false, "SPASelectionHost: TargetSV node is not a Node3D")
		return {}
	var frame: Dictionary = targetsv.get_grid_frame()
	if frame.is_empty():
		push_error("[SPA Selection] TargetSV '%s' 未给出规范网格框架（资产未就绪或元数据不完整）。" % str(targetsv.name))
		assert(false, "SPASelectionHost: TargetSV grid frame unavailable")
		return {}
	var grid_size: Vector3i = frame.get("grid_size", Vector3i.ZERO)
	if grid_size.x <= 0 or grid_size.y <= 0 or grid_size.z <= 0:
		push_error("[SPA Selection] TargetSV 网格尺寸非法：%s。" % str(grid_size))
		assert(false, "SPASelectionHost: TargetSV grid size has non-positive component")
		return {}
	var local_origin: Vector3 = frame.get("grid_origin", Vector3.ZERO)
	return {
		"grid_size": grid_size,
		"grid_origin": (targetsv as Node3D).global_transform.origin + local_origin,
		"voxel_size": frame.get("voxel_size", Vector3.ONE),
		"height_scale": float(frame.get("height_scale", 1.0)),
	}


## 按索引选择 GPU AutoObject。
func select_autoobject_by_index(object_index: int = -1) -> Dictionary:
	if not _autoobject_runtime_ready:
		return {"ok": false, "reason": "autoobject_runtime_not_ready"}
	if _autoobject_positions.is_empty():
		return {"ok": false, "reason": "no_autoobjects"}
	var idx := object_index
	if idx < 0:
		# object_index<0 = API 约定的"选一个代表对象"（不是兜底），取中间那个。
		idx = int(floor(float(_autoobject_positions.size()) * 0.5))
	elif idx >= _autoobject_positions.size():
		# 越界必须失败，不能夹紧到其他对象。
		push_error("[SPA Selection] select_autoobject_by_index 索引越界：object_index=%d positions.size=%d" % [
			object_index, _autoobject_positions.size()])
		assert(false, "SPASelectionHost: select_autoobject_by_index out of range")
		return {"ok": false, "reason": "object_index_out_of_range", "requested_index": object_index}
	var selection := _make_autoobject_selection_record(idx, 0.0)
	if selection.is_empty():
		return {"ok": false, "reason": "autoobject_record_unavailable", "requested_index": idx}
	set_active_selection(selection)
	return {
		"ok": true,
		"probe_index": idx,
		"selected_index": int(selection.get("object_index", -1)),
		"object_id": int(selection.get("object_id", -1)),
		"asset_index": int(selection.get("asset_index", -1)),
		"profile_id": int(selection.get("profile_id", -1)),
		"tile_coord": selection.get("tile_coord", Vector3i.ZERO),
		"position": selection.get("position", Vector3.ZERO),
	}


## 刷新**选中反馈**的可见性（选中框 + anchor 采样框 + demo overlay 钩子）。
##
## ⚠ 本函数**不碰任何域的显示开关**。这里曾额外做两件事，两件都是「翻一个域的开关会连带
## 重驱别的域」的来源——用户 2026-08-14 报的就是「点 Anchors 显示，TargetSV 跟着变」：
##
##   * `_apply_targetsv_visuals()`：无条件把记账位 `_voxel_display_visible["targetsv"]`
##     推给 TargetSV。而两边的默认值**从一开场就相反**——记账位由
##     `SPAEditorContract.default_voxel_display_state()` 播种成恒 true，TargetSV 自己的
##     `default_display_visible()` 却是 false。再加上隐藏域没有显示节点
##     （`rebuild_display()` 首句 `if not display_visible: _discard_display()`），
##     `set_display_visible(true)` 在节点为空时会**走进 `rebuild_display()`**：于是新场景里
##     第一次翻任意一个别的域开关，就把 TargetSV 整个建出来并点亮。
##     TargetSV（以及其余五个卷）的显示只有一个入口：
##     `ScenePlacementActor.set_volume_display()`——它同时写卷与记账位，两边不会分家。
##     `pickable_domain.gd` 的 `display_node()` 注释已经点名过这个多写入方，别再加回来。
##   * `_apply_all_external_voxel_display_visibility()`：把六个键的记账位全量重推一遍。
##     单键推送已经在 `set_voxel_display_visible()` 里按被改的那个键做过，这里是纯冗余的
##     全量扇出；新注册的外部节点也在 `register_voxel_display_node()` 里就取过当前值。
##     要显式全量重推走 `refresh_voxel_display_controls()`，那才是它的语义。
func _refresh_selection_markers() -> void:
	if _extra_visuals_refresh.is_valid():
		_extra_visuals_refresh.call()
	var box_visible := _active_selection_box_visible()
	if _selection_marker != null:
		_selection_marker.visible = box_visible
		_selection_marker.transparency = 0.0
	_update_anchor_sample_bounds_marker()


## 取对象的资产索引。
func _asset_index_for_object(object_index: int) -> int:
	if object_index < 0 or object_index >= _autoobject_asset_indices.size():
		push_error("[SPA Selection] AutoObject asset_indices 越界：object_index=%d asset_indices.size=%d —— pick 数据与 runtime 不同步。" % [
			object_index, _autoobject_asset_indices.size()])
		assert(false, "SPASelectionHost: autoobject asset index out of range")
		return -1
	return int(_autoobject_asset_indices[object_index])


## 由体素坐标一次性求出 tile 尺寸/网格/线性索引/坐标
## ⚠ 这里曾先过 `_svtile_tile_size()` / `_scene_voxel_grid_size()` 两层薄包装：前者只是
## 转发 `SceneVoxelTileStore.scene_voxel_tile_size()`（公共单源本来就在那边，多一层反而像
## 本类自己有一份公式），后者只是给 `_spa_grid_size()` 换名。两者都已删除，直接问单源。
func _tile_info_for_voxel(voxel: Vector3i) -> Dictionary:
	var tile_size := SceneVoxelTileStoreScript.scene_voxel_tile_size()
	return SceneVoxelTileCodecScript.tile_info_for_voxel(voxel, _spa_grid_size(), tile_size)


## 根据网格索引反算体素最小坐标（真实链模式优先走逐对象 voxel_min 数组）。
func _autoobject_voxel_min_from_index(object_index: int) -> Vector3i:
	if not _autoobject_voxel_mins.is_empty():
		return _autoobject_voxel_mins[object_index]
	var px := object_index % _autoobject_side_count
	var pz := int(floor(float(object_index) / float(_autoobject_side_count)))
	return Vector3i(
		clampi(px * _autoobject_spacing_voxels, 0, autoobject_grid_resolution - 1),
		0,
		clampi(pz * _autoobject_spacing_voxels, 0, autoobject_grid_resolution - 1)
	)


## 获取指定网格索引的GPU对象ID。
func _autoobject_id_for_index(object_index: int) -> int:
	if object_index < 0 or object_index >= _autoobject_ids.size():
		push_error("[SPA Selection] AutoObject object_ids 越界：object_index=%d object_ids.size=%d —— pick 数据与 runtime 不同步。" % [
			object_index, _autoobject_ids.size()])
		assert(false, "SPASelectionHost: autoobject object_id out of range")
		return -1
	var object_id := int(_autoobject_ids[object_index])
	if object_id < 0:
		push_error("[SPA Selection] AutoObject object_id 非法：object_index=%d object_id=%d —— 注入方未给出真实 GPU object_id。" % [
			object_index, object_id])
		assert(false, "SPASelectionHost: autoobject object_id is negative")
		return -1
	return object_id


# ⚠ 这里曾有 `_anchor_index_as_float()` 与 `_terrain_pick_key()`，两个都是旧射线点选的遗留：
#   * 前者把 anchor_index 编成 float32 塞进「求交面」——求交面随射线一起没了；
#   * 后者拼 `"terrain:%d"` 内容代号，给已删除的 `VoxelPickGPU` 复用常驻地形缓冲用。
# 全仓零调用点，2026-08-11 删除。`_terrain_field_revision` 本身仍被地形缓存失效逻辑使用，
# 连带的 `_repair_soft_reloaded_terrain_revision()` 因此保留。


# @tool 软重载后修复新增成员的默认值。
func _repair_soft_reloaded_terrain_revision() -> void:
	if not (_terrain_field_revision is int): _terrain_field_revision = Time.get_ticks_usec()


# ⚠ 这里曾有 `_targetsv_content_key()` 与 `_world_to_selection_voxel()`，同属旧射线点选遗留：
#   * 前者拼 GPU 常驻 TargetSV 缓冲的内容代号，消费方是已删除的 `VoxelPickGPU`；
#   * 后者把**射线落点的世界坐标**换算成选择体素——ID 路直接从载荷拿体素坐标，不经世界坐标。
# 全仓零调用点，2026-08-11 删除。


func _svtile_record_for_voxel(voxel: Vector3i) -> Dictionary:
	var tile := _tile_info_for_voxel(voxel)
	var tile_size: Vector3i = tile.get("size", Vector3i.ONE)
	var tile_coord: Vector3i = tile.get("coord", Vector3i.ZERO)
	var tile_index := int(tile.get("index", -1))
	var spa := _scene_placement_actor()
	if spa == null:
		# 缺少 SPA 时不能伪造空 tile 记录。
		push_error("[SPA Selection] SVTile 记录构建找不到祖先 ScenePlacementActor，tile 数据无来源。voxel=%s tile=%s" % [
			str(voxel), str(tile_coord)])
		assert(false, "SPASelectionHost: svtile record without ScenePlacementActor")
		return {}
	var tile_record: Dictionary = spa.get_svtile_debug_record(tile_coord)
	# Object-ref 数量来自独立槽位缓冲，不在 tile record 中。
	var object_refs := spa.get_svtile_object_ref_count(tile_coord)
	var marker := _svtile_marker_transform(tile_coord, tile_size)
	if marker.is_empty():
		# `_svtile_marker_transform` 已经报过原因（拿不到 SVTile 卷）。
		return {}
	return {
		"domain": SELECTION_DOMAIN_SVTILE,
		"geometry": SELECTION_GEOMETRY_VOXEL,
		"id": "svtile:%s" % str(tile_coord),
		"world_position": marker["position"],
		"marker_size": marker["size"],
		"voxel_coord": voxel,
		"tile_coord": tile_coord,
		"tile_index": tile_index,
		"tile_record": tile_record,
		"object_ref_count": object_refs,
		"payload": tile_record,
	}


func _sv_record_for_voxel(voxel: Vector3i) -> Dictionary:
	# SV 域必须具备 SceneVoxelCommitter。
	if _sv_committer == null:
		push_error("[SPA Selection] SceneVoxel 记录构建缺少 SceneVoxelCommitter：voxel=%s" % str(voxel))
		assert(false, "SPASelectionHost: _sv_record_for_voxel without sv committer")
		return {}
	# 优先读取完整常驻体素，未命中才使用兼容查询。
	var complexity := 0.0
	var collision := 0.0
	var payload: Dictionary = {}
	var sampled := false
	if _sv_committer.has_method("sample_committed_voxel"):
		var sample: Dictionary = _sv_committer.sample_committed_voxel(voxel)
		if not sample.is_empty():
			complexity = float(sample.get("complexity", 0.0))
			collision = float(sample.get("collision_strength", 0.0))
			payload = sample
			sampled = true
	if not sampled:
		var hit_pos := _selection_voxel_marker_position(voxel, 0.0)
		var scene_voxel: Dictionary = _sv_committer.get_scene_voxel(voxel.y, Vector2i(voxel.x, voxel.z))
		var query: Dictionary = _sv_committer.query_voxel(hit_pos.x, hit_pos.z, 0.0)
		complexity = float(scene_voxel.get("complexity", query.get("complexity", 0.0))) if not scene_voxel.is_empty() else float(query.get("complexity", 0.0))
		collision = float(scene_voxel.get("collision", query.get("collision", 0.0))) if not scene_voxel.is_empty() else float(query.get("collision", 0.0))
		payload = scene_voxel if not scene_voxel.is_empty() else query
	var tile := _tile_info_for_voxel(voxel)
	var tile_coord: Vector3i = tile.get("coord", Vector3i.ZERO)
	var tile_index := int(tile.get("index", -1))
	return {
		"domain": SELECTION_DOMAIN_SV,
		"geometry": SELECTION_GEOMETRY_VOXEL,
		"id": "sv:%s" % str(voxel),
		# 选择框与体素格心同心。
		"world_position": _selection_voxel_marker_position(voxel, 0.0),
		"marker_size": _default_voxel_marker_size(),
		"voxel_coord": voxel,
		"tile_coord": tile_coord,
		"tile_index": tile_index,
		"complexity": complexity,
		"collision": collision,
		"payload": payload,
	}


func _anchor_record_for_voxel(voxel: Vector3i) -> Dictionary:
	# Anchor 域必须具备 SceneVoxelCommitter。
	if _sv_committer == null:
		push_error("[SPA Selection] Anchor 记录构建缺少 SceneVoxelCommitter：voxel=%s" % str(voxel))
		assert(false, "SPASelectionHost: _anchor_record_for_voxel without sv committer")
		return {}
	var hit_pos := _selection_voxel_marker_position(voxel, 0.0)
	var query: Dictionary = _sv_committer.query_voxel(hit_pos.x, hit_pos.z, 0.0)
	var tile := _tile_info_for_voxel(voxel)
	var tile_coord: Vector3i = tile.get("coord", Vector3i.ZERO)
	var tile_index := int(tile.get("index", -1))
	var complexity := float(query.get("complexity", 0.0))
	return {
		"domain": SELECTION_DOMAIN_ANCHOR,
		"geometry": SELECTION_GEOMETRY_VOXEL,
		"id": "anchor:%s" % str(voxel),
		# 选择框与 anchor 格心同心。
		"world_position": _selection_voxel_marker_position(voxel, 0.0),
		"marker_size": _default_voxel_marker_size() * 1.35,
		"voxel_coord": voxel,
		"tile_coord": tile_coord,
		"tile_index": tile_index,
		"anchor_kind": "candidate" if complexity <= 0.01 else "occupied_candidate",
		"complexity": complexity,
		"payload": query,
	}


func _targetsv_marker_size(geometry: Dictionary) -> Vector3:
	var voxel_size: Vector3 = geometry["voxel_size"]
	return Vector3(
		maxf(voxel_size.x * 0.9, 0.2),
		maxf(voxel_size.y * 0.9, 0.2),
		maxf(voxel_size.z * 0.9, 0.2))


## 按体素坐标构建 TargetSV 记录。
func _targetsv_record_for_selection_voxel(voxel: Vector3i) -> Dictionary:
	return _targetsv_record_for_indices(voxel.x, voxel.y, voxel.z)


## 按索引构建 TargetSV 记录。
func _targetsv_record_for_indices(x: int, slice_index: int, z: int) -> Dictionary:
	var targetsv := _find_targetsv_setup()
	if targetsv == null:
		return {}
	# ⚠ 名单里曾有 "get_metadata"——它在全仓零调用（几何一律走 get_grid_frame），
	# 方法连同这条要求已删（2026-08-10）。要求一个没人调的方法只会让删除它的人被误拦。
	if not _require_targetsv_api(targetsv, [
			"is_targetsv_ready", "get_visual_bytes", "get_collision_bytes"]):
		return {}
	if not targetsv.is_targetsv_ready():
		return {}
	var geometry := _targetsv_geometry_metadata(targetsv)
	if geometry.is_empty():
		return {}
	var grid_size: Vector3i = geometry["grid_size"]
	var visual: PackedByteArray = targetsv.get_visual_bytes()
	var collision: PackedByteArray = targetsv.get_collision_bytes()
	var clamped := Vector3i(
		clampi(x, 0, grid_size.x - 1),
		clampi(slice_index, 0, grid_size.y - 1),
		clampi(z, 0, grid_size.z - 1))
	var record := _targetsv_record_for_voxel(targetsv, null, Vector2.ZERO, clamped, geometry, visual, collision)
	# 不给失败记录追加 marker_size。
	if record.is_empty():
		return {}
	record["marker_size"] = _targetsv_marker_size(geometry)
	return record


func _targetsv_record_for_voxel(
	targetsv: Node,
	cam: Camera3D,
	screen_pos: Vector2,
	voxel: Vector3i,
	geometry: Dictionary,
	visual: PackedByteArray,
	collision: PackedByteArray
) -> Dictionary:
	var grid_size: Vector3i = geometry["grid_size"]
	# 使用全项目统一的线性索引式。
	var idx := VoxelGeneral.voxel_index(voxel, grid_size)
	var complexity := SceneVoxelTileCodecScript.decode_complexity_field_rgba8_alpha_at(visual, idx)
	var collision_value := SceneVoxelTileCodecScript.decode_collision_field_r8_at(collision, idx)
	var occupancy := maxf(complexity, collision_value)
	# 缺少世界坐标换算时必须失败。
	if not _require_targetsv_api(targetsv, ["voxel_to_world"]):
		return {}
	if not (targetsv is Node3D):
		push_error("[SPA Selection] TargetSV 节点 '%s'(%s) 不是 Node3D，体素世界坐标无从换算。" % [
			str(targetsv.name), targetsv.get_class()])
		assert(false, "SPASelectionHost: TargetSV node is not a Node3D")
		return {}
	var local_pos: Vector3 = targetsv.voxel_to_world(voxel.x, voxel.y, voxel.z)
	var world_pos: Vector3 = (targetsv as Node3D).to_global(local_pos)
	var score := INF
	if cam != null and not cam.is_position_behind(world_pos):
		score = cam.unproject_position(world_pos).distance_squared_to(screen_pos)
	return {
		"domain": SELECTION_DOMAIN_TARGETSV,
		"geometry": SELECTION_GEOMETRY_VOXEL,
		"id": "targetsv:%s" % str(voxel),
		"world_position": world_pos,
		"voxel_coord": voxel,
		"tile_coord": Vector3i.ZERO,
		"complexity": complexity,
		"collision": collision_value,
		"occupancy": occupancy,
		"screen_score": score,
		"payload": {
			# 保留 texture_size/slice_count 兼容别名。
			"grid_size": grid_size,
			"texture_size": grid_size.x,
			"slice_count": grid_size.y,
			"buffer_index": idx,
		},
	}


## 返回与 SVTile 显示一致的选择框变换。
func _svtile_marker_transform(tile_coord: Vector3i, tile_size: Vector3i) -> Dictionary:
	var volume = _svtile_volume()
	if volume == null:
		return {}
	var grid := _spa_grid_size()
	var voxel_size := _spa_voxel_size()
	var bounds := SceneVoxelTileCodecScript.tile_bounds(tile_coord, grid, tile_size)
	var voxel_min: Vector3i = bounds.get("voxel_min", Vector3i.ZERO)
	# voxel_max 是开区间上界。
	var voxel_max: Vector3i = bounds.get("voxel_max", voxel_min + Vector3i.ONE)
	var center: Vector3 = SVTileVolumeScript.tile_center_world(
		voxel_min, voxel_max, grid, _spa_grid_origin(), voxel_size,
		# 基类统一的无参签名（2026-08-10）：网格从卷自己的 grid_frame() 取，与显示同源。
		volume.display_terrain_height_field())
	var span_world := VoxelGeneral.voxel_span_to_world_size(voxel_max - voxel_min, voxel_size)
	# 0.96 使框略大于显示单元。
	var size := Vector3(
		maxf(span_world.x * 0.96, 0.2),
		maxf(span_world.y * 0.96, 0.5),
		maxf(span_world.z * 0.96, 0.2)
	)
	return {"position": center, "size": size}


## 返回 SceneSV 显示格心，可选增加 Y 偏移。
func _selection_voxel_marker_position(voxel: Vector3i, y_offset: float) -> Vector3:
	# 保持显式 Variant 赋值，避免 INFERENCE_ON_VARIANT。
	var volume = _scene_sv_volume()
	if volume == null:
		return Vector3(INF, INF, INF)
	var world: Vector3 = volume.voxel_center_world(voxel)
	if world.x == INF:
		return world
	world.y += y_offset
	return world


## `SPA/Volumes/SceneSV` 节点。
func _scene_sv_volume():
	var spa := _require_spa()
	if spa == null:
		return null
	var node := spa.get_volume(&"SceneSV")
	if node is SceneSVVolumeScript:
		return node
	push_error("[SPA Selection] SPA/Volumes/SceneSV 不是 SceneSVVolume（实得 %s）—— 体素显示中心无来源，选中框无法摆位。" % [
		node.get_class() if node != null else "<null>"])
	assert(false, "SPASelectionHost: SceneSV volume node missing or wrong type")
	return null


## ID 命中的元素下标 → 体素坐标，**问命中的那个域自己**（`PickIdPass` 随命中带出
## `source` 节点）。域族的 `element_to_voxel()` 是元素空间层的多态寻址口：
## 体素域恒等反解、瓦片域给原点、稀疏槽无解析式——让 host 按域名各写一份就是第二份寻址。
##
## 取不到域或解不出返回 (-1,-1,-1)，由调用分支判死。
func _domain_element_voxel(hit: Dictionary, element_index: int) -> Vector3i:
	if element_index < 0:
		return Vector3i(-1, -1, -1)
	var source = hit.get("source", null)
	if source == null or not is_instance_valid(source) or not source.has_method("element_to_voxel"):
		push_error("[SPA Selection] ID 命中没有带出可寻址的域节点（source=%s）—— 元素下标 %d 无法解成体素坐标。" % [
			str(source), element_index])
		assert(false, "SPASelectionHost._domain_element_voxel: hit source cannot address elements")
		return Vector3i(-1, -1, -1)
	return source.element_to_voxel(element_index)


## BrushSV 体素的选择记录（2026-08-10 切 ID 路）。
##
## 与 `_sv_record_for_voxel` 的差异：内容不在 committer 的常驻场里，绘制属性
## （颜色 / complexity / collision）只有 `BrushSVVolume` 有——**问它自己的成员**
## （`paint_attributes_for_element`），而不是让载荷替它复述一遍。
## marker 摆位走卷节点的 `voxel_center_world()`（基类实现，与笔刷显示 shader 同式、
## 读同一份地形缓存）——与 SV / SVTile 的「marker 问画它的那个节点要」是同一条纪律。
func _brush_record_for_voxel(voxel: Vector3i, element_index: int) -> Dictionary:
	if voxel.x < 0:
		return {}
	var volume = _brush_sv_volume()
	if volume == null:
		return {}
	var world: Vector3 = volume.voxel_center_world(voxel)
	if world.x == INF:
		return {}
	var paint: Dictionary = volume.paint_attributes_for_element(element_index)
	return {
		"domain": SELECTION_DOMAIN_BRUSH,
		"geometry": SELECTION_GEOMETRY_VOXEL,
		"id": "brush:%s" % str(voxel),
		# 选择框与体素格心同心（笔刷显示 scale 恒 1.0，与 SceneSV 同口径）。
		"world_position": world,
		"marker_size": _default_voxel_marker_size(),
		"voxel_coord": voxel,
		"voxel_index": element_index,
		"complexity": float(paint.get("complexity", 0.0)),
		"collision": float(paint.get("collision", 0.0)),
		"paint_color": paint.get("paint_color", Color.WHITE),
	}


## `SPA/Volumes/BrushSV` 节点。判死理由同 `_scene_sv_volume()`。
func _brush_sv_volume():
	var spa := _require_spa()
	if spa == null:
		return null
	var node := spa.get_volume(&"BrushSV")
	if node is BrushSVVolumeScript:
		return node
	push_error("[SPA Selection] SPA/Volumes/BrushSV 不是 BrushSVVolume（实得 %s）—— 笔刷体素中心无来源，选中框无法摆位。" % [
		node.get_class() if node != null else "<null>"])
	assert(false, "SPASelectionHost: BrushSV volume node missing or wrong type")
	return null


## `SPA/Volumes/SVTile` 节点。判死理由同 `_scene_sv_volume()`。
func _svtile_volume():
	var spa := _require_spa()
	if spa == null:
		return null
	var node := spa.get_volume(&"SVTile")
	if node is SVTileVolumeScript:
		return node
	push_error("[SPA Selection] SPA/Volumes/SVTile 不是 SVTileVolume（实得 %s）—— 瓦片显示中心无来源，选中框无法摆位。" % [
		node.get_class() if node != null else "<null>"])
	assert(false, "SPASelectionHost: SVTile volume node missing or wrong type")
	return null


## 由 GPU AutoObject 索引构建统一的选中记录字典。
func _make_autoobject_selection_record(object_index: int, screen_score: float) -> Dictionary:
	if object_index < 0 or object_index >= _autoobject_positions.size():
		push_error("[SPA Selection] AutoObject positions 越界：object_index=%d positions.size=%d —— pick 数据与 runtime 不同步。" % [
			object_index, _autoobject_positions.size()])
		assert(false, "SPASelectionHost: autoobject object_index out of range")
		return {}
	if _autoobject_voxel_mins.is_empty() and _autoobject_side_count <= 0:
		push_error("[SPA Selection] AutoObject voxel_min 无从求得：voxel_mins 为空且 side_count=%d —— 注入方必须给出逐对象 voxel_mins 或网格 side_count。" % _autoobject_side_count)
		assert(false, "SPASelectionHost: autoobject voxel_min source missing")
		return {}
	if not _autoobject_voxel_mins.is_empty() and object_index >= _autoobject_voxel_mins.size():
		push_error("[SPA Selection] AutoObject voxel_mins 越界：object_index=%d voxel_mins.size=%d —— pick 数据与 runtime 不同步。" % [
			object_index, _autoobject_voxel_mins.size()])
		assert(false, "SPASelectionHost: autoobject voxel_min out of range")
		return {}
	var asset_idx := _asset_index_for_object(object_index)
	if asset_idx < 0:
		return {}
	if asset_idx >= _asset_names.size() or asset_idx >= _profile_ids.size():
		push_error("[SPA Selection] AutoObject 资产表越界：asset_index=%d asset_names.size=%d profile_ids.size=%d —— 资产注册表与 pick 数据不同步。" % [
			asset_idx, _asset_names.size(), _profile_ids.size()])
		assert(false, "SPASelectionHost: autoobject asset table out of range")
		return {}
	var object_id := _autoobject_id_for_index(object_index)
	if object_id < 0:
		return {}
	var voxel_min := _autoobject_voxel_min_from_index(object_index)
	var tile := _tile_info_for_voxel(voxel_min)
	return {
		"domain": SELECTION_DOMAIN_AUTOOBJECT,
		"geometry": SELECTION_GEOMETRY_AUTOOBJECT,
		"id": "gpu_autoobject:%d" % object_id,
		"object_index": object_index,
		"object_id": object_id,
		"asset_index": asset_idx,
		"asset_name": _asset_names[asset_idx],
		"profile_id": _profile_ids[asset_idx],
		"position": _autoobject_positions[object_index],
		"voxel_min": voxel_min,
		"voxel_max": voxel_min + Vector3i.ONE,
		"tile_coord": tile.get("coord", Vector3i.ZERO),
		"tile_index": int(tile.get("index", -1)),
		"screen_score": screen_score,
	}


# ⚠ 这里曾有 `_voxel_float_center_to_world(voxel_center, y)`：把**浮点**体素中心换算到世界。
# 它服务的是旧路的屏幕距离仲裁——那条路要把候选体素的连续中心投影回屏幕比距离，才需要
# 亚格精度的换算。ID pass 直接给出被点中的**整数**格坐标，换算走
# `VoxelGeneral.voxel_center_to_world()` / 域自己的 `voxel_to_world()`，没有浮点中心这一步了，
# 本函数自此零调用方。已删除（2026-08-12）。


## 检查是否有任何类型的选中状态
func _has_active_selection() -> bool:
	return not _active_selection.is_empty()


# ---- 生产 ID 点击 ----------------------------------------------------------

## 使用点击相机的实际视口尺寸。
func _pick_id_viewport_size(cam: Camera3D) -> Vector2i:
	if cam == null:
		return Vector2i.ZERO
	var vp := cam.get_viewport()
	if vp == null:
		return Vector2i.ZERO
	var size := vp.get_visible_rect().size
	return Vector2i(int(round(size.x)), int(round(size.y)))


## 执行 ID 绘制、回读、解码和记录构建。
func _pick_id_select_at_screen_position(cam: Camera3D, screen_pos: Vector2) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	# ⚠ 快照里曾有 `enabled` 键（回退开关的状态）。开关已删（三角形 ID 唯一路），键恒 true 无信息量。
	_last_pick_id_click = {"status": "unavailable", "screen": [screen_pos.x, screen_pos.y]}
	if cam == null:
		_last_pick_id_click["reason"] = "missing_camera"
		return {"status": "unavailable", "reason": "missing_camera"}
	var viewport_size := _pick_id_viewport_size(cam)
	if viewport_size.x <= 0 or viewport_size.y <= 0:
		push_error("[SPA Selection] 点击相机拿不到视口尺寸（%s）—— ID 目标无从与屏幕坐标对齐。" % str(viewport_size))
		assert(false, "SPASelectionHost: pick id viewport size unavailable")
		_last_pick_id_click["reason"] = "viewport_size_unavailable"
		return {"status": "unavailable", "reason": "viewport_size_unavailable"}
	var pass_node := _ensure_pick_id_pass()
	if pass_node == null:
		push_error("[SPA Selection] ID pass 建不起来 —— 本次点击不作答（不回落旧算法，见函数注释）。")
		assert(false, "SPASelectionHost: pick id pass unavailable")
		_last_pick_id_click["reason"] = "pick_id_pass_unavailable"
		return {"status": "unavailable", "reason": "pick_id_pass_unavailable"}
	var drawables := collect_pick_drawables()
	if drawables.is_empty():
		# 没有 drawable 时无法判定命中。
		_last_pick_id_click["status"] = "unavailable"
		_last_pick_id_click["reason"] = "no_drawables"
		return {"status": "unavailable", "reason": "no_drawables"}
	var prep: Dictionary = pass_node.call("prepare", cam, viewport_size, drawables, 0)
	if not bool(prep.get("ok", false)):
		push_error("[SPA Selection] ID pass prepare 失败（%s）—— 本次点击不作答。" % str(prep.get("reason", "")))
		assert(false, "SPASelectionHost: pick id prepare failed")
		_last_pick_id_click["reason"] = "prepare_failed:%s" % str(prep.get("reason", ""))
		return {"status": "unavailable", "reason": "prepare_failed"}
	var hit: Dictionary = pass_node.call("draw_and_resolve", screen_pos)
	_last_pick_id_click["drawables"] = int(prep.get("drawables", 0))
	_last_pick_id_click["viewport"] = [viewport_size.x, viewport_size.y]
	_last_pick_id_click["pick_id"] = int(hit.get("pick_id", 0))
	_last_pick_id_click["domain"] = str(hit.get("domain", ""))
	_last_pick_id_click["force_draw_us"] = int(hit.get("force_draw_us", 0))
	_last_pick_id_click["readback_us"] = int(hit.get("readback_us", 0))
	if not bool(hit.get("ok", false)):
		push_error("[SPA Selection] ID 图回读失败（%s）—— 本次点击不作答。" % str(hit.get("reason", "")))
		assert(false, "SPASelectionHost: pick id readback failed")
		_last_pick_id_click["reason"] = "readback_failed:%s" % str(hit.get("reason", ""))
		return {"status": "unavailable", "reason": "readback_failed"}
	if not bool(hit.get("hit", false)):
		# PickIdPass 已报告未映射 ID，此处按未命中处理。
		_last_pick_id_click["status"] = "miss"
		_last_pick_id_click["reason"] = str(hit.get("reason", "no_hit"))
		_last_pick_id_click["total_us"] = Time.get_ticks_usec() - t0
		return {"status": "miss", "reason": str(hit.get("reason", "no_hit"))}
	var out := _pick_id_commit_hit(hit)
	_last_pick_id_click["status"] = str(out.get("status", "unavailable"))
	# 载荷类型即域名（"payload_kind" 那份派生字符串随载荷瘦身删除，2026-08-10）。
	_last_pick_id_click["domain"] = str(hit.get("domain", ""))
	_last_pick_id_click["payload_index"] = int(out.get("payload_index", -1))
	_last_pick_id_click["reason"] = str(out.get("reason", ""))
	_last_pick_id_click["total_us"] = Time.get_ticks_usec() - t0
	return out


## 将 ID 命中提交为选择记录。
func _pick_id_commit_hit(hit: Dictionary) -> Dictionary:
	var domain := str(hit.get("domain", ""))
	var payload: Dictionary = hit.get("payload", {}) if hit.get("payload", {}) is Dictionary else {}
	# ⚠ 这里曾先查一张 `PICK_ID_SWITCHED_DOMAINS` 白名单。白名单随旧路一起删了：
	# "没有记录构建分支"这件事由下面 match 的 `_:` 兜底判死（push_error + assert），
	# 与白名单是同一道门，不需要两处各记一份域名表（漏同步就是"点得中却建不出记录"）。
	if not bool(payload.get("ok", false)):
		# 无效载荷不能降级为普通未命中。
		return {"status": "unavailable", "reason": "payload_%s" % str(payload.get("reason", "unresolved"))}
	match domain:
		SELECTION_DOMAIN_AUTOOBJECT:
			var object_id := int(payload.get("object_id", -1))
			var object_index := _autoobject_index_for_object_id(object_id)
			if object_index < 0:
				push_error("[SPA Selection] ID 路解出的 object_id=%d 不在注入的 AutoObject 表里（%d 项）—— pick 数据与 runtime 不同步。" % [
					object_id, _autoobject_ids.size()])
				assert(false, "SPASelectionHost: pick id object_id not in injected table")
				return {"status": "unavailable", "reason": "object_id_unmapped", "payload_index": object_id}
			# ID 路由深度测试仲裁，不产生 screen_score。
			var record := _make_autoobject_selection_record(object_index, 0.0)
			if record.is_empty():
				return {"status": "unavailable", "reason": "autoobject_record_failed", "payload_index": object_index}
			record["pick_backend"] = "pick_id"
			set_active_selection(record)
			return {
				"status": "hit", "payload_index": object_index,
				"result": {
					"ok": true,
					"domain": SELECTION_DOMAIN_AUTOOBJECT,
					"geometry": SELECTION_GEOMETRY_AUTOOBJECT,
					"record": record,
				},
			}
		SELECTION_DOMAIN_ANCHOR:
			# 载荷已统一为 element_index（= anchor_index，AnchorVolume 经 provider 解出，
			# winner 档含视距剔除的压缩表）。三档共用同一条记录构建。
			var anchor_index := int(payload.get("element_index", -1))
			if anchor_index < 0:
				return {"status": "unavailable", "reason": "anchor_index_invalid"}
			var anchor_hit := _commit_volume_score_anchor(anchor_index)
			if anchor_hit.is_empty():
				return {"status": "unavailable", "reason": "anchor_commit_failed", "payload_index": anchor_index}
			return {"status": "hit", "payload_index": anchor_index, "result": anchor_hit}
		SELECTION_DOMAIN_TARGETSV:
			# 载荷只给 element_index（= 线性体素下标）；坐标问域自己的寻址口。
			var element_index := int(payload.get("element_index", -1))
			var voxel := _domain_element_voxel(hit, element_index)
			if voxel.x < 0:
				return {"status": "unavailable", "reason": "targetsv_voxel_invalid",
					"payload_index": element_index}
			var tsv_record := _targetsv_record_for_selection_voxel(voxel)
			if tsv_record.is_empty():
				return {"status": "unavailable", "reason": "targetsv_record_failed",
					"payload_index": element_index}
			tsv_record["pick_backend"] = "pick_id"
			set_active_selection(tsv_record)
			return {
				"status": "hit", "payload_index": element_index,
				"result": {
					"ok": true,
					"domain": SELECTION_DOMAIN_TARGETSV,
					"geometry": str(tsv_record.get("geometry", SELECTION_GEOMETRY_VOXEL)),
					"record": tsv_record,
				},
			}
		SELECTION_DOMAIN_SV:
			# 载荷只给 element_index（= 线性体素下标）；坐标问域自己的寻址口。
			var sv_element := int(payload.get("element_index", -1))
			var sv_voxel := _domain_element_voxel(hit, sv_element)
			if sv_voxel.x < 0:
				return {"status": "unavailable", "reason": "sv_voxel_invalid",
					"payload_index": sv_element}
			# 关闭过程可能出现 drawable 尚在但 committer 已释放。
			if _sv_committer == null:
				push_error("[SPA Selection] ID 路命中 SV 体素 %s，但 SelectionHost 没有 SceneVoxelCommitter —— SPA 未 READY 或已关停，本次点击不作答。" % str(sv_voxel))
				return {"status": "unavailable", "reason": "sv_committer_unavailable",
					"payload_index": sv_element}
			var sv_record := _sv_record_for_voxel(sv_voxel)
			if sv_record.is_empty():
				return {"status": "unavailable", "reason": "sv_record_failed",
					"payload_index": sv_element}
			sv_record["pick_backend"] = "pick_id"
			set_active_selection(sv_record)
			return {
				"status": "hit", "payload_index": sv_element,
				"result": {
					"ok": true,
					"domain": SELECTION_DOMAIN_SV,
					"geometry": str(sv_record.get("geometry", SELECTION_GEOMETRY_VOXEL)),
					"record": sv_record,
				},
			}
		SELECTION_DOMAIN_SVTILE:
			# 载荷只给 element_index（= tile_index）；覆盖范围问域的 voxel_range_of()。
			# ⚠ 瓦片域**没有**代表体素这回事（八面体是瓦片尺度的），记录构建按既有约定
			# 用瓦片原点起算，但那是**范围的下界**、不是"射线打中的那一格"。
			var svtile_index := int(payload.get("element_index", -1))
			var svtile_volume = _svtile_volume()
			var svtile_range: Dictionary = svtile_volume.voxel_range_of(svtile_index) \
				if svtile_volume != null and svtile_index >= 0 else {}
			var svtile_origin_voxel: Vector3i = svtile_range.get("min", Vector3i(-1, -1, -1))
			if svtile_index < 0 or svtile_origin_voxel.x < 0:
				push_error("[SPA Selection] SVTile 命中解不出覆盖范围（element_index=%d，volume=%s）—— 载荷契约或瓦片寻址与本分支不同步。" % [
					svtile_index, str(svtile_volume != null)])
				return {"status": "unavailable", "reason": "svtile_payload_invalid"}
			var svtile_record := _svtile_record_for_voxel(svtile_origin_voxel)
			if svtile_record.is_empty():
				return {"status": "unavailable", "reason": "svtile_record_failed",
					"payload_index": svtile_index}
			svtile_record["pick_backend"] = "pick_id"
			set_active_selection(svtile_record)
			return {
				"status": "hit", "payload_index": svtile_index,
				"result": {
					"ok": true,
					"domain": SELECTION_DOMAIN_SVTILE,
					"geometry": str(svtile_record.get("geometry", SELECTION_GEOMETRY_VOXEL)),
					"record": svtile_record,
				},
			}
		SELECTION_DOMAIN_BRUSH:
			# 载荷只给 element_index（= 线性体素下标）；坐标与绘制属性都问域自己要。
			var brush_element := int(payload.get("element_index", -1))
			var brush_voxel := _domain_element_voxel(hit, brush_element)
			if brush_voxel.x < 0:
				return {"status": "unavailable", "reason": "brush_voxel_invalid",
					"payload_index": brush_element}
			var brush_record := _brush_record_for_voxel(brush_voxel, brush_element)
			if brush_record.is_empty():
				return {"status": "unavailable", "reason": "brush_record_failed",
					"payload_index": brush_element}
			brush_record["pick_backend"] = "pick_id"
			set_active_selection(brush_record)
			return {
				"status": "hit", "payload_index": brush_element,
				"result": {
					"ok": true,
					"domain": SELECTION_DOMAIN_BRUSH,
					"geometry": str(brush_record.get("geometry", SELECTION_GEOMETRY_VOXEL)),
					"record": brush_record,
				},
			}
	# 新增接管域时必须同步本分派。
	push_error("[SPA Selection] 已切换域 \"%s\" 没有记录构建分支 —— 该域点得中却建不出记录。" % domain)
	assert(false, "SPASelectionHost: switched domain without a record branch")
	return {"status": "unavailable", "reason": "no_record_branch"}


func simulate_viewport_click(spec_json: String) -> String:
	var parsed = JSON.parse_string(spec_json)
	if not (parsed is Dictionary):
		return JSON.stringify({"ok": false, "reason": "bad_spec_json"})
	var spec: Dictionary = parsed
	var entry := str(spec.get("entry", "spa"))
	if entry != "spa" and entry != "selection":
		return JSON.stringify({"ok": false, "reason": "unknown_entry:%s" % entry})
	var viewport_size := _spec_vector2i(spec.get("viewport", [1440, 900]), Vector2i(1440, 900))
	var screen := _spec_vector2(spec.get("screen", []), Vector2(viewport_size) * 0.5)

	var spa := _scene_placement_actor()
	if entry == "spa" and spa == null:
		return JSON.stringify({"ok": false, "reason": "spa_missing"})

	# ⚠ spec 的 `pick_id` 键已失效（曾用于本次调用内临时翻转回退开关做 A/B）：开关已删，
	# 只剩三角形 ID 一条路。传这个键不报错，也不再有任何作用。
	var restore_editor_camera := _editor_camera
	_last_pick_id_click = {"status": "not_run"}

	var probe := _make_probe_camera(spec, viewport_size, "SimClick")
	var probe_viewport: SubViewport = probe["viewport"]
	var cam: Camera3D = probe["camera"]

	# 清除旧选择，确保结果属于本次点击。
	clear_active_selection(false)

	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.button_mask = MOUSE_BUTTON_MASK_LEFT
	press.pressed = true
	press.position = screen
	press.global_position = screen
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = screen
	release.global_position = screen

	var consumed := false
	var release_consumed := false
	if entry == "spa":
		consumed = bool(spa.handle_editor_input(cam, press))
		release_consumed = bool(spa.handle_editor_input(cam, release))
	else:
		consumed = handle_viewport_input(cam, press)
		release_consumed = handle_viewport_input(cam, release)

	var selected := _selection_state_identity()
	var out := {
		"ok": true,
		"entry": entry,
		"screen": [screen.x, screen.y],
		"viewport": [viewport_size.x, viewport_size.y],
		"consumed": consumed,
		"release_consumed": release_consumed,
		"selected": selected,
		"evidence": _selection_click_evidence(cam, selected, screen),
		"pick_id_click": _last_pick_id_click.duplicate(true) if _last_pick_id_click is Dictionary else {},
	}

	cam.current = false
	probe_viewport.queue_free()
	_editor_camera = restore_editor_camera
	return JSON.stringify(out)


## 模拟一次生产视口键盘事件。
func simulate_viewport_key(spec_json: String) -> String:
	var parsed = JSON.parse_string(spec_json)
	if not (parsed is Dictionary):
		return JSON.stringify({"ok": false, "reason": "bad_spec_json"})
	var spec: Dictionary = parsed
	var spa := _scene_placement_actor()
	if spa == null:
		return JSON.stringify({"ok": false, "reason": "spa_missing"})
	var viewport_size := _spec_vector2i(spec.get("viewport", [1440, 900]), Vector2i(1440, 900))
	var probe := _make_probe_camera(spec, viewport_size, "SimKey")
	var probe_viewport: SubViewport = probe["viewport"]
	var cam: Camera3D = probe["camera"]
	var restore_editor_camera := _editor_camera

	var key := InputEventKey.new()
	key.keycode = int(spec.get("keycode", 0))
	key.physical_keycode = key.keycode
	key.pressed = true
	key.echo = false
	key.ctrl_pressed = bool(spec.get("ctrl", false))
	key.shift_pressed = bool(spec.get("shift", false))
	key.alt_pressed = bool(spec.get("alt", false))
	key.meta_pressed = bool(spec.get("meta", false))

	var consumed := bool(spa.handle_editor_input(cam, key))
	cam.current = false
	probe_viewport.queue_free()
	_editor_camera = restore_editor_camera
	return JSON.stringify({"ok": true, "consumed": consumed, "keycode": key.keycode})


## 返回已经落地的选择身份。
func _selection_state_identity() -> Dictionary:
	# ⚠ 这里曾有一个 anchor 优先短路（`if _selected_anchor_idx >= 0` 抢在读 `_active_selection`
	# 之前返回）。那个专用槽已删除，anchor 与其余五域走同一条：读统一选中态、按域取下标。
	var record: Dictionary = _active_selection if _active_selection is Dictionary else {}
	if record.is_empty():
		return {"domain": "", "id": "", "payload_index": -1}
	var domain := str(record.get("domain", ""))
	var out := {
		"domain": domain,
		"id": str(record.get("id", "")),
		"payload_index": -1,
		"pick_backend": str(record.get("pick_backend", "")),
	}
	match domain:
		SELECTION_DOMAIN_ANCHOR:
			# 锚点下标就是本域的身份，存在记录里（与其余域从记录取下标同构）。
			out["payload_index"] = int(record.get("anchor_index", -1))
		SELECTION_DOMAIN_AUTOOBJECT:
			out["payload_index"] = int(record.get("object_index", -1))
			out["object_id"] = int(record.get("object_id", -1))
		SELECTION_DOMAIN_TARGETSV:
			var voxel: Vector3i = record.get("voxel_coord", Vector3i(-1, -1, -1))
			out["voxel_coord"] = _vec3i_to_array(voxel)
			out["payload_index"] = _targetsv_voxel_index(voxel)
		SELECTION_DOMAIN_SV:
			# SV 身份使用稳定的线性体素下标。
			var sv_voxel: Vector3i = record.get("voxel_coord", Vector3i(-1, -1, -1))
			out["voxel_coord"] = _vec3i_to_array(sv_voxel)
			var sv_grid := _spa_grid_size()
			out["payload_index"] = VoxelGeneral.voxel_index(sv_voxel, sv_grid) \
				if sv_voxel.x >= 0 and sv_grid.x > 0 and sv_grid.z > 0 else -1
		SELECTION_DOMAIN_SVTILE:
			out["voxel_coord"] = _vec3i_to_array(record.get("voxel_coord", Vector3i(-1, -1, -1)))
			out["tile_coord"] = _vec3i_to_array(record.get("tile_coord", Vector3i(-1, -1, -1)))
			out["payload_index"] = int(record.get("tile_index", -1))
		SELECTION_DOMAIN_BRUSH:
			# 与 SV 同口径：身份是稳定的线性体素下标（不是笔刷列表的实例序——那个随清空重排）。
			var brush_voxel: Vector3i = record.get("voxel_coord", Vector3i(-1, -1, -1))
			out["voxel_coord"] = _vec3i_to_array(brush_voxel)
			var brush_grid := _spa_grid_size()
			out["payload_index"] = VoxelGeneral.voxel_index(brush_voxel, brush_grid) \
				if brush_voxel.x >= 0 and brush_grid.x > 0 and brush_grid.z > 0 else -1
		_:
			# 没有逐实例下标的域：身份就是记录 id。
			out["voxel_coord"] = _vec3i_to_array(record.get("voxel_coord", Vector3i(-1, -1, -1)))
	return out


## 返回当前相机下的独立几何校验结果。
func _selection_click_evidence(cam: Camera3D, selected: Dictionary, screen: Vector2) -> Dictionary:
	var domain := str(selected.get("domain", ""))
	# ⚠ 这里曾有 `center_dist_px`（被选中物中心到点击点的屏幕距离）。那是**旧路仲裁的产物**
	# ——"28px 内谁的中心更近"。ID 路没有这个概念（深度即仲裁），留着只会让读者以为
	# 距离参与了判定。已删除；剩下三个键全是**独立几何校验**，不依赖任何命中算法。
	# ⚠ 2026-08-11：`ray_in_winner_aabb` / `ray_in_cell` 两个键随射线辨别一并删除，本函数只剩
	# TargetSV 的屏幕半径一项（`unproject_position` 投影，不是射线）。anchor 域已无证据可出，
	# 连带 `_rebuild_pick_id_anchor_bounds()` 的这处触发点一并去掉。
	var out := {}
	if domain == SELECTION_DOMAIN_TARGETSV:
		var voxel: Vector3i = Vector3i(-1, -1, -1)
		var raw = selected.get("voxel_coord", [])
		if raw is Array and (raw as Array).size() == 3:
			voxel = Vector3i(int(raw[0]), int(raw[1]), int(raw[2]))
		if voxel.x >= 0:
			out["cell_screen_radius_px"] = _targetsv_cell_screen_radius(cam, voxel)
	return out


## 鼠标点击的统一选择入口 —— **只有三角形 ID 一条路**（用户裁定 2026-08-10）。
##
## 返回 `{}` 有三种含义，全部**不回落**任何别的命中算法：
##   * ID 图上那个像素是空的 ⇒ 这里确实什么都没画（点空地不选中任何东西）
##   * ID pass 建不起来 / 本趟零 drawable ⇒ 这次点击没有答案，已 push_error
##   * 载荷解不出来 ⇒ 同上
##
## ⚠ 这里曾有一个 `if pick_id_selection_enabled:` 分支与整条旧路（AutoObject/Anchor
## 按屏幕距离仲裁 → 地形射线数据域链）。旧路是"切 ID 路"期间的一键回退，也是 SV / SVTile
## 两个**无逐样本对比证据**域的唯一判据。用户 2026-08-10 裁定所有选择只走三角形 ID
## ⇒ 开关与旧路整体退役。**代价要写明**：这两个域此后出问题没有 A/B 可切，只能读代码定位。
##
## ⚠ 不要"为了保险"重新加一条兜底。回落会让一条坏掉的 ID pass 表现得跟正常一模一样，
## 谁也发现不了它坏了——本项目最难查的正是这类"看着对、实则是另一条路答的"。
func _select_current_mode_at_screen_position(cam: Camera3D, screen_pos: Vector2) -> Dictionary:
	var id_out := _pick_id_select_at_screen_position(cam, screen_pos)
	if str(id_out.get("status", "")) == "hit":
		return id_out.get("result", {})
	return {}


## 处理编辑器视口左键；其他鼠标事件交还视口。
func _handle_editor_mouse_button(cam: Camera3D, event: InputEventMouseButton) -> bool:
	if event.button_index != MOUSE_BUTTON_LEFT:
		return false
	if event.pressed:
		var selection_result := _select_current_mode_at_screen_position(cam, event.position)
		if not selection_result.is_empty():
			_consume_editor_mouse_release = true
			return true
		if _has_active_selection():
			_deselect()
			_consume_editor_mouse_release = true
			return true
	else:
		if _consume_editor_mouse_release:
			_consume_editor_mouse_release = false
			return true
	return false


## 处理选择相关键盘事件。
func _handle_editor_key(event: InputEventKey) -> bool:
	if not event.pressed or event.echo:
		return false
	match event.keycode:
		KEY_ESCAPE:
			_deselect()
			return true
	return false


## 清除所有选中状态
func _deselect() -> void:
	clear_active_selection(false)
	_notify_hud()

# ⚠ 这里曾有 `_get_camera()`：只转发一次 `DemoUI.find_camera(self, "", "FlyCamera", true, true)`，
# 唯一调用点是 `select_at_viewport_position()`，两者已于 2026-08-11 先后删除。
