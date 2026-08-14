@tool
extends "res://scripts/core_demo_contract_fixture.gd"

const SemanticProbeGeneratorScript := preload("res://scripts/semantic_probe_generator.gd")
const AssetDescriptorBaker := preload("res://scripts/asset_descriptor_baker.gd")
const GeoAssetScanService := preload("res://scripts/geo_asset_scan_service.gd")
const FbxTransformBakeService := preload("res://scripts/fbx_transform_bake_service.gd")
const VoxelDisplay := preload("res://scripts/utils/voxel_display.gd")
const VoxelDebugLabel := preload("res://scripts/utils/voxel_debug_label.gd")
const DemoDebugVisuals := preload("res://scripts/utils/demo_debug_visuals.gd")
const FbxVoxelImportService := preload("res://scripts/fbx_voxel_import_service.gd")

const VOXEL_DEBUG_NODE := "VoxelDebugGroup"

# ---- Bake AssetDescriptor per displayed mesh (editor tool) ----------------
# Output folder for descriptors baked from the meshes shown in the scene. Kept
# under the demo (not the curated res://assets/vegetation) so a bake never
# clobbers hand-authored assets.
#
# ⚠ 路径的单一真值来源是 BakedAssetLoader.BAKED_DESCRIPTOR_DIR（固定槽位Profile共享
# Buffer实施计划 §6「Bake 输出目录必须有单一真值来源」）：SPA 的 Reload 只扫
# 那一个目录，这里必须写同一个值，否则烘出来的产物加载器根本看不见。此处只转发。
const BakedAssetLoaderScript := preload("res://scripts/baked_asset_loader.gd")
const BAKED_DESCRIPTOR_DIR := BakedAssetLoaderScript.BAKED_DESCRIPTOR_DIR

# Per-asset fine-score override rows for the Asset Info popup. Each maps 1:1 to an
# AssetDescriptor @export (see get_score_param_overrides): checkbox off = inherit
# global config (-1), on = the SpinBox value. complexity is a percent; rest are raw.
const SCORE_PARAM_ROWS: Array[Dictionary] = [
	{"prop": "score_min_match_fraction", "label": "min match fraction", "min": 0.0, "max": 1.0, "step": 0.01},
	{"prop": "score_dim_weight_collision", "label": "weight · collision", "min": 0.0, "max": 8.0, "step": 0.01},
	{"prop": "score_dim_weight_complexity", "label": "weight · complexity", "min": 0.0, "max": 8.0, "step": 0.01},
	{"prop": "score_dim_weight_color", "label": "weight · color", "min": 0.0, "max": 8.0, "step": 0.01},
	{"prop": "score_color_match_max_l1", "label": "color budget L1", "min": 0.0, "max": 3.0, "step": 0.01},
	{"prop": "score_collision_match_max", "label": "collision budget", "min": 0.0, "max": 1.0, "step": 0.01},
	{"prop": "score_complexity_overfill_percent", "label": "complexity overfill %", "min": 0.0, "max": 500.0, "step": 1.0},
]

# 互斥半径乘数在 descriptor 上的属性名与面板行定义。与 SCORE_PARAM_ROWS 同形，但**没有**
# 「继承全局」语义（没有对应的全局配置项），所以面板上不带 override 勾选框，默认 1.0。
const SPACING_SCALE_PROP := "spacing_radius_scale"
const SPACING_SCALE_ROW := {
	"prop": SPACING_SCALE_PROP,
	"label": "exclusion radius ×",
	"min": 0.0,
	"max": 8.0,
	"step": 0.05,
}

var _bake_status_label: Label
var _bake_info_label: Label
var _bake_dialog: ConfirmationDialog
var _bake_output_dialog: AcceptDialog
var _bake_scale_check: CheckBox
var _bake_rotation_check: CheckBox
var _bake_target: Node3D

# Voxel channel display modes (one shortcut each).
const VOXEL_CHANNEL_NONE := ""
const VOXEL_CHANNEL_COLOR := "color"
const VOXEL_CHANNEL_COMPLEXITY := "complexity"
const VOXEL_CHANNEL_COLLISION := "collision"

const PROBE_DEBUG_NODE := "ProbeDebugGroup"
const PIVOT_DEBUG_NODE := "PivotDebugGroup"
const EXCLUSION_DEBUG_NODE := "ExclusionDebugGroup"

const EDITOR_ACTION_PROBES := &"probes"
const EDITOR_ACTION_VOXEL_COLOR := &"voxel_color"
const EDITOR_ACTION_VOXEL_COMPLEXITY := &"voxel_complexity"
const EDITOR_ACTION_VOXEL_COLLISION := &"voxel_collision"
const EDITOR_ACTION_PIVOTS := &"pivots"
const EDITOR_ACTION_EXCLUSION := &"exclusion"
const EDITOR_ACTION_TOGGLE_ASSETS := &"toggle_assets"
const EDITOR_ACTION_CLEAR_DEBUG := &"clear_debug"

const PIVOT_MARKER_COLORS := {
	"bottom": Color(0.3, 1.0, 0.4, 0.95),
	"middle": Color(1.0, 0.85, 0.2, 0.95),
	"upper": Color(1.0, 0.45, 0.15, 0.95),
}

@export_range(0.1, 8.0, 0.1) var probe_density: float = 1.0
@export var max_probe_markers: int = 96
# ⚠ 曾经这里有 auto_generate_vertical_pivots + middle/upper 阈值三个导出，烘焙时按碰撞
# 高度派生 bottom/middle/upper 三个挂接点。三变体已于 2026-08-05 整体删除（算错了：
# 它按碰撞体素下标推 pivot，不知道网格原点在哪，给 cliff 类资产产出 +56~+60.8 m 的偏移，
# 放置结果整体沉到 anchor 下方 80 m 以上）。烘焙现在恒写单条零偏移 bottom pivot。

var _asset_nodes: Array[Node3D] = []
# Visualization is single-target: probes / voxels apply only to the editor-selected asset.
var _probes: Array[Dictionary] = []
var _probes_visible := false
var _probe_target_node: Node3D = null
var _probe_source := ""

# Vertical pivot 覆盖显示状态 + 面板控件引用（控件在 _ensure_pivot_ui 里程序化构建）。
var _pivots_visible := false
var _pivot_target_node: Node3D = null
var _pivot_last_count := 0

# 资产互斥球：与上面几档「选中才画」的覆盖显示不同，这一档**默认开**且覆盖全部资产，
# 场景一加载就建（见 _ready）——互斥半径是资产的固有属性，用户要求每次打开场景就能看见。
var _exclusion_visible := true
var _exclusion_last_count := 0

# Import FBX file dialog. It is parented to the editor base control because this
# @tool scene lives in the 3D SubViewport and cannot host native editor popups.
const FBX_DIALOG_NAME := "MeshFillFbxImportDialog"
var _fbx_import_dialog: EditorFileDialog

# Voxelization cache: the structured result for the currently baked (selected) node only.
var _voxel_results: Array[Dictionary] = []
var _voxel_baked_node: Node3D = null
var _voxel_channel := VOXEL_CHANNEL_NONE

# The editor plugin polls this scene's selection overlay every frame. Keep the FBX
# inspection result cached until the selected source file or its timestamp changes.
var _fbx_channel_overlay_cache_key := ""
var _fbx_channel_overlay_cache_text := ""

# G toggles every displayed asset container hidden so the probe / voxel overlays read
# clearly (overlays live under the demo's own debug roots, so they stay visible).
#
# ⚠ 这是**唯一**会隐藏资产的地方，且必须由用户按 G 触发。本场景以前还会「只显示选中的那个、
# 其余全隐藏」，而驱动它的 `_sync_selected_asset_visibility()` 挂在插件每帧轮询的
# `get_selection_overlay_text()` 上 ⇒ 选中一个资产别的就凭空消失，在场景面板手动点回可见
# 也会被下一帧改回去。用户裁定去掉（2026-08-11）：选中不再影响可见性。
var _assets_hidden := false


func _ready() -> void:
	super._ready()
	if is_scene_startup_blocked():
		return
	_connect_geo_scan_buttons()
	_ensure_bake_ui()
	_ensure_pivot_ui()
	_ensure_exclusion_ui()
	_collect_static_assets()
	_apply_asset_visibility(false)
	_rebuild_exclusion_display()


# Debug shortcuts are driven by the editor 3D viewport, not runtime input. The
# MeshFill editor plugin forwards viewport key events here via _forward_3d_gui_input,
# so the 1..6 / C / B overlays respond while the cursor is over the editor viewport.
# Returning true tells the plugin to consume the event (AFTER_GUI_INPUT_STOP).
func _editor_viewport_input(_viewport_camera: Camera3D, event: InputEvent) -> bool:
	if not event is InputEventKey:
		return false
	var ke := event as InputEventKey
	if not ke.pressed or ke.echo:
		return false
	# Bare digit / letter triggers — no modifier. Any modifier combo (Ctrl+C copy,
	# Ctrl+S save, …) is left to the editor. Digit view-snapping no longer collides
	# because these rely on the editor setting "editors/3d/navigation/emulate_numpad"
	# being off; the KP fold below still keeps the digits working if it is re-enabled.
	if ke.ctrl_pressed or ke.alt_pressed or ke.shift_pressed or ke.meta_pressed:
		return false

	# When "emulate_numpad" is on it rewrites number-row 1..9 to keypad codes before
	# the event reaches here, so fold KP_0..KP_9 back to 0..9.
	var keycode := ke.keycode
	if keycode >= KEY_KP_0 and keycode <= KEY_KP_9:
		keycode = KEY_0 + (keycode - KEY_KP_0)

	match keycode:
		KEY_1:
			asset_descriptor_editor_action(EDITOR_ACTION_PROBES)
			return true
		KEY_2:
			asset_descriptor_editor_action(EDITOR_ACTION_VOXEL_COLOR)
			return true
		KEY_3:
			asset_descriptor_editor_action(EDITOR_ACTION_VOXEL_COMPLEXITY)
			return true
		KEY_4:
			asset_descriptor_editor_action(EDITOR_ACTION_VOXEL_COLLISION)
			return true
		KEY_5:
			asset_descriptor_editor_action(EDITOR_ACTION_PIVOTS)
			return true
		KEY_6:
			asset_descriptor_editor_action(EDITOR_ACTION_EXCLUSION)
			return true
		KEY_G:
			asset_descriptor_editor_action(EDITOR_ACTION_TOGGLE_ASSETS)
			return true
		KEY_C:
			asset_descriptor_editor_action(EDITOR_ACTION_CLEAR_DEBUG)
			return true
	return false


func asset_descriptor_editor_action(action: StringName) -> Dictionary:
	match action:
		EDITOR_ACTION_PROBES:
			_toggle_probes()
		EDITOR_ACTION_VOXEL_COLOR:
			_show_voxel_channel(VOXEL_CHANNEL_COLOR)
		EDITOR_ACTION_VOXEL_COMPLEXITY:
			_show_voxel_channel(VOXEL_CHANNEL_COMPLEXITY)
		EDITOR_ACTION_VOXEL_COLLISION:
			_show_voxel_channel(VOXEL_CHANNEL_COLLISION)
		EDITOR_ACTION_PIVOTS:
			_toggle_pivots()
		EDITOR_ACTION_EXCLUSION:
			_toggle_exclusion_spheres()
		EDITOR_ACTION_TOGGLE_ASSETS:
			_toggle_asset_visibility()
		EDITOR_ACTION_CLEAR_DEBUG:
			_clear_all_debug()
		_:
			return {"ok": false, "reason": "unknown_action", "action": str(action)}
	return _asset_descriptor_debug_state(action)


func _asset_descriptor_debug_state(action: StringName = &"") -> Dictionary:
	var target := _probe_target_node if _probe_target_node != null else _resolve_selected_asset_node()
	return {
		"ok": true,
		"action": str(action),
		"selected": target.name if target != null else "none",
		"probes_visible": _probes_visible,
		"probe_source": _probe_source,
		"voxel_channel": _voxel_channel,
		"probe_count": _probes.size(),
		"voxel_result_count": _voxel_results.size(),
		"has_probe_debug": get_node_or_null(PROBE_DEBUG_NODE) != null,
		"has_voxel_debug": get_node_or_null(VOXEL_DEBUG_NODE) != null,
		"pivots_visible": _pivots_visible,
		"pivot_count": _pivot_last_count,
		"has_pivot_debug": get_node_or_null(PIVOT_DEBUG_NODE) != null,
		"exclusion_visible": _exclusion_visible,
		"exclusion_count": _exclusion_last_count,
		"has_exclusion_debug": get_node_or_null(EXCLUSION_DEBUG_NODE) != null,
		"assets_hidden": _assets_hidden,
	}


# G hides or restores **所有**已显示的处理网格（不分选中与否）。这是显式动作，
# 所以这里可以直接覆写 visible；被动路径一律不写（见 `_assets_hidden` 的注释）。
func _toggle_asset_visibility() -> void:
	_assets_hidden = not _assets_hidden
	_apply_asset_visibility()


# Collect the persisted processing nodes that feed probe, sample-channel and bake tools.
func _collect_static_assets() -> void:
	_asset_nodes.clear()
	for root_path in ["Assets/Trees", "Assets/Rocks", GeoAssetScanService.GEO_ASSET_ROOT]:
		var root := get_node_or_null(root_path)
		if root == null:
			continue
		for child in root.get_children():
			if child is Node3D:
				_asset_nodes.append(child)


# 把 G 的当前状态铺到全部资产节点上。
#
# ⚠ `force` 为 false 时**只在 G 处于隐藏态才写**：没按 G 的时候本场景不该碰任何
# `visible`——否则会把用户在场景面板里手动设的可见性、以及 .tscn 里存的状态一并冲掉。
# 只有 G 自己（`force = true`）需要把资产从隐藏态恢复回来。
func _apply_asset_visibility(force: bool = true) -> void:
	if not Engine.is_editor_hint():
		return
	if not force and not _assets_hidden:
		return
	for node in _asset_nodes:
		if node != null:
			node.visible = not _assets_hidden


# --- Geo scan tools --------------------------------------------------------

func _connect_geo_scan_buttons() -> void:
	var scan_button := get_node_or_null("GeoTools/Panel/VBox/ScanUpdatedGeo") as Button
	if scan_button != null:
		var scan_callable := Callable(self, "_on_scan_updated_geo_pressed")
		if not scan_button.pressed.is_connected(scan_callable):
			scan_button.pressed.connect(scan_callable)
	var rescan_button := get_node_or_null("GeoTools/Panel/VBox/FullRescanGeo") as Button
	if rescan_button != null:
		var rescan_callable := Callable(self, "_on_full_rescan_geo_pressed")
		if not rescan_button.pressed.is_connected(rescan_callable):
			rescan_button.pressed.connect(rescan_callable)


# 「扫描更新」= 增量扫描 + 烘焙，而 bake_scene_descriptors(ensure_fresh = true) 的第一步
# 就是增量扫描 —— 两者是同一个操作，不必先扫一遍再叫一个「刚扫过所以别再扫」的包装。
func _on_scan_updated_geo_pressed() -> void:
	bake_scene_descriptors()


# 全量重扫是另一种语义（先 free 掉所有节点再重建），没有对应的 ensure_fresh 形态，
# 所以仍显式扫一次，再以 ensure_fresh = false 烘焙，避免紧接着又跑一遍增量扫描。
func _on_full_rescan_geo_pressed() -> void:
	_scan_geo_assets(true)
	bake_scene_descriptors(false)


# 冻结名（插件 GEO_SCAN_METHOD 字符串调用）：扫描本体已下沉 GeoAssetScanService，
# 这里只保留 demo 本地缓存失效（探针/体素缓存跟着场景节点走，服务不可见）。
func _scan_geo_assets(full_rescan: bool) -> Dictionary:
	var result := GeoAssetScanService.scan(self, full_rescan)
	return _finish_geo_import(result)


func _finish_geo_import(result: Dictionary) -> Dictionary:
	_collect_static_assets()
	# ⚠ 导入的结果必须看得见 ⇒ 导入**取消** G 隐藏态。
	# 这里以前是「G 隐藏态就把新节点也压下去」，于是在 G 隐藏态下点 Import All：
	# 全量重扫刚重建好的五个节点被立刻写回 visible=false，界面上就是"点了导入什么都没出现"。
	# ⚠ 只清状态、**不**批量写 visible：具体哪些节点该显出来由 GeoAssetScanService 保证
	# （它只动本次导入碰过的那些），这样单文件导入不会顺手把你手动隐藏的其它资产也翻出来。
	_assets_hidden = false
	_reset_voxel_cache()
	# 互斥球同理：导入结果必须**连带互斥现况**一起看得见。这条收口的是两个工具栏入口
	# （Import All → `_scan_geo_assets(true)`、Import FBX → `_import_geo_files()`）和
	# 面板的 Scan / Full Rescan——四条路都在这里汇合。
	# 与上面 `_assets_hidden` 同一条理由，所以也一并**清掉关闭态**：新导入的资产必须
	# 带球出现，而不是"上次按过 6 关掉了，于是这次导入完什么都没画"。
	# 重建本身也是必需的：节点是新建 / 重排过的，旧球还钉在旧位置上。
	_exclusion_visible = true
	_rebuild_exclusion_display()
	return result


func _reset_voxel_cache() -> void:
	_voxel_results.clear()
	_voxel_baked_node = null
	if _voxel_channel != VOXEL_CHANNEL_NONE:
		_clear_node(VOXEL_DEBUG_NODE)
		_voxel_channel = VOXEL_CHANNEL_NONE


# 冻结名（插件 GEO_FORMAT_METHOD 字符串调用）：格式化本体已下沉 GeoAssetScanService。
func _format_geo_scan_result(result: Dictionary) -> String:
	return GeoAssetScanService.format_scan_result(result)


# --- Bake transform -> source FBX ------------------------------------------
#
# 冻结本体（C⁻¹·T·C 基变换 + python 调用 + 强制备份）已下沉 FbxTransformBakeService；
# demo 只保留 UI 编排：按钮/确认对话框/输出对话框/状态标签 + reimport 收尾。

func _ensure_bake_ui() -> void:
	if not Engine.is_editor_hint():
		return
	FbxTransformBakeService.ensure_editor_setting()
	var vbox := get_node_or_null("GeoTools/Panel/VBox") as VBoxContainer
	if vbox == null:
		return
	var btn := vbox.get_node_or_null("BakeSelectedFbx") as Button
	if btn == null:
		btn = Button.new()
		btn.name = "BakeSelectedFbx"
		btn.text = "Bake → FBX (selected)"
		btn.tooltip_text = "Freeze the selected geo asset's scale + rotation into its source .FBX. Overwrites the file (original copied to res://backup/geo). Requires the Autodesk FBX Python SDK — set the path in Project Settings: meshfill_editor/bake_fbx_python."
		vbox.add_child(btn)
		var rescan := vbox.get_node_or_null("FullRescanGeo")
		if rescan != null:
			vbox.move_child(btn, rescan.get_index() + 1)
		btn.pressed.connect(_on_bake_selected_to_fbx_pressed)
	var status := vbox.get_node_or_null("BakeStatus") as Label
	if status == null:
		status = Label.new()
		status.name = "BakeStatus"
		status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		status.custom_minimum_size = Vector2(240, 0)
		status.add_theme_font_size_override("font_size", 12)
		status.text = ""
		vbox.add_child(status)
	_bake_status_label = status
	var panel := get_node_or_null("GeoTools/Panel") as Control
	if panel != null:
		panel.reset_size()


func _on_bake_selected_to_fbx_pressed() -> void:
	if not Engine.is_editor_hint():
		return
	var node := _resolve_selected_geo_node()
	if node == null:
		_set_bake_status("Select a geo asset (under Assets/Geo) first.")
		return
	_bake_target = node
	_show_bake_dialog(node)


func _resolve_selected_geo_node() -> Node3D:
	return GeoAssetScanService.selected_node_matching(
		func(n: Node) -> bool: return n.has_meta(GeoAssetScanService.GEO_SOURCE_META))


func _show_bake_dialog(node: Node3D) -> void:
	var src := str(node.get_meta(GeoAssetScanService.GEO_SOURCE_META, ""))
	var basis := node.transform.basis
	var rot_deg := basis.get_euler() * 57.2957795
	var scl := basis.get_scale()
	if _bake_dialog == null:
		_bake_dialog = ConfirmationDialog.new()
		_bake_dialog.title = "Bake transform → FBX"
		_bake_dialog.ok_button_text = "Bake"
		var vb := VBoxContainer.new()
		vb.add_theme_constant_override("separation", 8)
		_bake_info_label = Label.new()
		_bake_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_bake_info_label.custom_minimum_size = Vector2(420, 0)
		vb.add_child(_bake_info_label)
		_bake_rotation_check = CheckBox.new()
		_bake_rotation_check.text = "Bake rotation"
		_bake_rotation_check.button_pressed = true
		vb.add_child(_bake_rotation_check)
		_bake_scale_check = CheckBox.new()
		_bake_scale_check.text = "Bake scale (off = rotation only)"
		_bake_scale_check.button_pressed = true
		vb.add_child(_bake_scale_check)
		_bake_dialog.add_child(vb)
		_bake_dialog.confirmed.connect(_on_bake_confirmed)
		add_child(_bake_dialog)
	_bake_info_label.text = (
		"Source: %s\nScale: (%.3f, %.3f, %.3f)\nRotation°: (%.2f, %.2f, %.2f)\n\n"
		+ "This OVERWRITES the source .FBX. The original is copied to\nres://backup/geo first."
	) % [src, scl.x, scl.y, scl.z, rot_deg.x, rot_deg.y, rot_deg.z]
	_bake_dialog.popup_centered()


func _on_bake_confirmed() -> void:
	var bake_rotation := _bake_rotation_check != null and _bake_rotation_check.button_pressed
	var bake_scale := _bake_scale_check != null and _bake_scale_check.button_pressed
	_do_bake(_bake_target, bake_rotation, bake_scale)


# 薄编排：数学/python/备份全在 FbxTransformBakeService（失败 push_error 由服务发出），
# demo 只做状态标签/输出对话框反馈与 reimport 收尾。
func _do_bake(node: Node3D, bake_rotation: bool, bake_scale: bool) -> void:
	if node == null:
		return
	var src_res := str(node.get_meta(GeoAssetScanService.GEO_SOURCE_META, ""))
	_set_bake_status("Baking %s …" % src_res.get_file())
	var result := FbxTransformBakeService.bake_node_transform(node, bake_rotation, bake_scale)
	match str(result.get("reason", "")):
		"ok":
			GeoAssetScanService.mark_scene_unsaved()
			_set_bake_status("Baked → %s. Reimporting…" % src_res.get_file())
			print("[AssetOverview] Bake OK:\n%s" % str(result.get("log", "")))
			_reimport_after_bake(src_res)
		"nothing_to_bake":
			_set_bake_status("Nothing selected to bake (check rotation and/or scale).")
		"no_source_meta":
			_set_bake_status("Selected node has no geo_source_path.")
		"script_missing":
			_set_bake_status("Bake script missing: %s" % FbxTransformBakeService.BAKE_SCRIPT_PATH)
		"backup_failed":
			_set_bake_status("Bake refused — backup failed (see console). Source untouched.")
		_:
			_set_bake_status("Bake FAILED (exit %d) — see dialog." % int(result.get("exit_code", -1)))
			_show_bake_output("Command:\n%s\n\n--- output ---\n%s" % [
				str(result.get("command", "")), str(result.get("log", ""))])


func _reimport_after_bake(src_res: String) -> void:
	if not Engine.is_editor_hint():
		return
	var fs = EditorInterface.get_resource_filesystem()
	if fs == null:
		return
	fs.update_file(src_res)
	fs.reimport_files(PackedStringArray([src_res]))
	await get_tree().process_frame
	await get_tree().process_frame
	_scan_geo_assets(false)
	_set_bake_status("Baked → %s (reimported)." % src_res.get_file())


func _show_bake_output(text: String) -> void:
	if _bake_output_dialog == null:
		_bake_output_dialog = AcceptDialog.new()
		_bake_output_dialog.title = "Bake → FBX output"
		_bake_output_dialog.min_size = Vector2(680, 380)
		var edit := TextEdit.new()
		edit.name = "Output"
		edit.editable = false
		edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
		edit.custom_minimum_size = Vector2(660, 340)
		_bake_output_dialog.add_child(edit)
		add_child(_bake_output_dialog)
	(_bake_output_dialog.get_node("Output") as TextEdit).text = text
	_bake_output_dialog.popup_centered()


func _set_bake_status(text: String) -> void:
	if _bake_status_label != null:
		_bake_status_label.text = text
	print("[AssetOverview] %s" % text)


# ─── Vertical pivot 面板（GeoTools 面板追加区；程序化构建、不落 .tscn） ──

func _ensure_pivot_ui() -> void:
	if not Engine.is_editor_hint():
		return
	var vbox := get_node_or_null("GeoTools/Panel/VBox") as VBoxContainer
	if vbox == null:
		return
	var header := vbox.get_node_or_null("PivotHeader") as Label
	if header == null:
		header = Label.new()
		header.name = "PivotHeader"
		header.text = "Vertical pivots"
		header.add_theme_font_size_override("font_size", 12)
		vbox.add_child(header)
	# 三变体的开关与两个阈值控件已随三变体一并删除；旧场景可能残留这三个子节点，
	# 一并清掉，否则面板上会留下三个点了没反应的控件。
	for stale_name in ["PivotAutoCheck", "PivotMiddleRow", "PivotUpperRow"]:
		var stale := vbox.get_node_or_null(NodePath(stale_name))
		if stale != null:
			vbox.remove_child(stale)
			stale.queue_free()
	var show_btn := vbox.get_node_or_null("PivotShowButton") as Button
	if show_btn == null:
		show_btn = Button.new()
		show_btn.name = "PivotShowButton"
		show_btn.text = "Pivots (selected)  [5]"
		show_btn.tooltip_text = "对编辑器选中的资产显示 pivot 标记（走生产生成函数，恒为单条零偏移 bottom）；再按一次清除。"
		vbox.add_child(show_btn)
		show_btn.pressed.connect(_toggle_pivots)
	var panel := get_node_or_null("GeoTools/Panel") as Control
	if panel != null:
		panel.reset_size()


## 互斥球开关按钮（同 GeoTools 面板；与视口 `6` 同一个动作）。
func _ensure_exclusion_ui() -> void:
	if not Engine.is_editor_hint():
		return
	var vbox := get_node_or_null("GeoTools/Panel/VBox") as VBoxContainer
	if vbox == null:
		return
	var btn := vbox.get_node_or_null("ExclusionShowButton") as Button
	if btn == null:
		btn = Button.new()
		btn.name = "ExclusionShowButton"
		btn.text = "Exclusion spheres  [6]"
		btn.tooltip_text = "全部资产的互斥球开关（默认开，场景一加载就画）。半径 = 网格 AABB 的 XZ 半长，与放置 reduce 的成对间距同口径：两球相交即这一对互斥。移动过资产或重新导入后按两次即按当前位置重建。"
		vbox.add_child(btn)
		btn.pressed.connect(_toggle_exclusion_spheres)
	var panel := get_node_or_null("GeoTools/Panel") as Control
	if panel != null:
		panel.reset_size()


## 参数变化时若覆盖显示开着，就地重建（保持所见即当前参数）。
func _refresh_pivot_overlay() -> void:
	if _pivots_visible and _pivot_target_node != null:
		_build_pivots_for_node(_pivot_target_node)


# ─── Single FBX import ────────────────────────────────────────

# Plugin host-gated entry point. The dialog only exposes FBX resources already
# inside the project; Godot must import external source files before they can be loaded.
func import_single_fbx() -> Dictionary:
	if not Engine.is_editor_hint():
		return {"ok": false, "reason": "editor_only"}
	_ensure_fbx_import_dialog()
	if _fbx_import_dialog == null:
		push_warning("[AssetOverview] Import FBX: editor file dialog unavailable")
		return {"ok": false, "reason": "no_dialog"}
	_fbx_import_dialog.current_dir = GeoAssetScanService.DEFAULT_GEO_LIBRARY_PATH
	_fbx_import_dialog.popup_file_dialog()
	return {"ok": true, "reason": "dialog_open"}


func _ensure_fbx_import_dialog() -> void:
	if _fbx_import_dialog != null and is_instance_valid(_fbx_import_dialog):
		return
	var base := EditorInterface.get_base_control()
	if base == null:
		_fbx_import_dialog = null
		return
	var existing := base.get_node_or_null(NodePath(FBX_DIALOG_NAME)) as EditorFileDialog
	if existing != null:
		_fbx_import_dialog = existing
		if not _fbx_import_dialog.file_selected.is_connected(_on_fbx_file_selected):
			_fbx_import_dialog.file_selected.connect(_on_fbx_file_selected)
		return
	var dialog := EditorFileDialog.new()
	dialog.name = FBX_DIALOG_NAME
	dialog.title = "Import one FBX"
	dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	dialog.access = EditorFileDialog.ACCESS_RESOURCES
	dialog.clear_filters()
	dialog.add_filter("*.fbx, *.FBX", "FBX scene")
	dialog.file_selected.connect(_on_fbx_file_selected)
	base.add_child(dialog)
	_fbx_import_dialog = dialog


func _exit_tree() -> void:
	if _fbx_import_dialog != null and is_instance_valid(_fbx_import_dialog):
		_fbx_import_dialog.queue_free()
	_fbx_import_dialog = null


func _on_fbx_file_selected(path: String) -> void:
	if not path.begins_with("res://") or path.get_extension().to_lower() != "fbx":
		push_warning("[AssetOverview] Import FBX: choose a project .fbx resource")
		return
	var result := _import_geo_files([path], false)
	print("[AssetOverview] Import FBX -> %s" % _format_geo_scan_result(result))


# Shared scene-side post-processing for single and all imports. File processing
# itself is centralized in GeoAssetScanService.import_files().
func _import_geo_files(paths: Array, full_rescan: bool) -> Dictionary:
	var result := GeoAssetScanService.import_files(self, paths, full_rescan)
	return _finish_geo_import(result)


# ─── Probe Debug ──────────────────────────────────────────────

func _toggle_probes() -> void:
	var node := _resolve_selected_asset_node()
	if _probes_visible:
		if node != null and node != _probe_target_node:
			if _build_probes_for_node(node):
				_probe_target_node = node
			else:
				_probes_visible = false
				_probe_target_node = null
			return
		_clear_probe_group("Probes")
		_probes.clear()
		_probes_visible = false
		_probe_target_node = null
		_probe_source = ""
		return
	if node == null:
		push_warning("[AssetOverview] Select a tree/rock asset first — probes apply to the selection only.")
		return
	if not _build_probes_for_node(node):
		return
	_probes_visible = true
	_probe_target_node = node


# Walk up from the editor selection to the owning asset container (a node tracked
# in _asset_nodes). Returns null when nothing relevant is selected.
# 顶部 editor_hint 守卫保留：跳过 _collect_static_assets 的无谓工作（游走守卫在服务侧）。
func _resolve_selected_asset_node() -> Node3D:
	if not Engine.is_editor_hint():
		return null
	_collect_static_assets()
	var asset_set := {}
	for n in _asset_nodes:
		asset_set[n] = true
	return GeoAssetScanService.selected_node_matching(
		func(n: Node) -> bool: return asset_set.has(n))


func _profile_samples_for_node(node: Node3D) -> Array[Dictionary]:
	var samples: Array[Dictionary] = []
	if node == null:
		return samples
	var source := str(node.get_meta(GeoAssetScanService.GEO_SOURCE_META, ""))
	if source.is_empty() or source.get_extension().to_lower() != "fbx":
		return samples
	var channels := FbxVoxelImportService.embedded_channels_from_fbx(source)
	if not bool(channels.get("ok", false)):
		push_warning("[AssetOverview] FBX ProfileSample decode failed for %s: %s" % [
			source, str(channels.get("reason", "unknown"))])
		return samples
	for raw in channels.get("profile_samples", []):
		if raw is Dictionary:
			samples.append((raw as Dictionary).duplicate(true))
	return samples


## Descriptor scalar color/complexity is the weighted average of embedded fine
## samples. Assets without fine samples fall back to all embedded samples, then neutral gray.
func _profile_sample_average(samples: Array[Dictionary]) -> Dictionary:
	var source: Array[Dictionary] = []
	for sample in samples:
		if (int(sample.get("flags", 0)) & ProfileRecordSchema.SAMPLE_FLAG_FINE) != 0:
			source.append(sample)
	if source.is_empty():
		source = samples
	var r := 0.0
	var g := 0.0
	var b := 0.0
	var cplx := 0.0
	var total_weight := 0.0
	for sample in source:
		var weight := maxf(float(sample.get("sample_weight", 1.0)), 0.0)
		if weight <= 0.0:
			continue
		var color: Color = sample.get("color", Color.WHITE)
		r += color.r * weight
		g += color.g * weight
		b += color.b * weight
		cplx += float(sample.get("complexity", color.a)) * weight
		total_weight += weight
	if total_weight <= 0.0:
		return {"color": Color(0.5, 0.5, 0.5, 0.5), "complexity": 0.5}
	var avg_cplx := clampf(cplx / total_weight, 0.0, 1.0)
	return {
		"color": Color(r / total_weight, g / total_weight, b / total_weight, avg_cplx),
		"complexity": avg_cplx,
	}


func _profile_sample_stage_count(samples: Array[Dictionary], stage_flag: int) -> int:
	var count := 0
	for sample in samples:
		if (int(sample.get("flags", 0)) & stage_flag) != 0:
			count += 1
	return count


static func fbx_probe_debug_records(fbx_path: String) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	if fbx_path.is_empty():
		return records
	for raw_record in FbxVoxelImportService.probe_records_from_fbx(fbx_path):
		if not raw_record is Dictionary:
			continue
		var record := (raw_record as Dictionary).duplicate(true)
		var position: Variant = record.get("position", null)
		if not position is Vector3:
			continue
		record["offset"] = position
		record["source"] = "fbx_embedded"
		record["shape_source"] = "fbx_embedded"
		records.append(record)
	return records


func _build_probes_for_node(node: Node3D) -> bool:
	_clear_probe_group("Probes")
	_probes.clear()
	_probe_source = ""

	var geo_source_path := str(node.get_meta(GeoAssetScanService.GEO_SOURCE_META, ""))
	var mi := node.get_node_or_null("Mesh") as MeshInstance3D
	if not geo_source_path.is_empty():
		_probes = fbx_probe_debug_records(geo_source_path)
		_probe_source = "fbx_embedded"
	else:
		if mi == null or mi.mesh == null:
			return false
		# Non-FBX assets retain a mesh-only semantic generator fallback.
		var avg := {"color": Color(0.5, 0.5, 0.5, 0.5), "complexity": 0.5}
		_probes = SemanticProbeGeneratorScript.generate_from_mesh(
			mi.mesh, [], avg.color, avg.complexity, probe_density, max_probe_markers
		)
		_probe_source = "semantic_generated"

	var debug_root := _get_or_create_debug_root()
	var group := Node3D.new()
	group.name = "Probes"
	debug_root.add_child(group)

	for j in range(mini(_probes.size(), max_probe_markers)):
		var marker := _make_probe_marker(_probes[j], j)
		var local_offset := VariantUtils.vector3_from_value(
			_probes[j].get("offset", Vector3.ZERO), Vector3.ZERO
		)
		if _probe_source == "fbx_embedded":
			# FBX record.position is scene-root local and matches the transform baked into Geo meshes.
			marker.position = (
				node.to_global(local_offset)
				if node.is_inside_tree()
				else node.transform * local_offset
			)
		else:
			# Generated offsets remain mesh-local.
			marker.position = mi.to_global(local_offset)
		group.add_child(marker)

	# Summary label above the selected asset in world space
	var sum_label := VoxelDebugLabel.make(
		"%s\nprobes=%d  source=%s" % [
			node.name, mini(_probes.size(), max_probe_markers), _probe_source],
		Color.WHITE, 20, 0.0, 0.01, 4, false
	)
	sum_label.name = "ProbeCount"
	sum_label.position = node.position + Vector3(0.0, 2.5, 0.0)
	group.add_child(sum_label)
	return true


# ─── Vertical pivot 覆盖显示（发现 3 复活的可视化；走生产生成函数） ──

func _toggle_pivots() -> void:
	var node := _resolve_selected_asset_node()
	if _pivots_visible:
		if node != null and node != _pivot_target_node:
			_build_pivots_for_node(node)
			_pivot_target_node = node
			return
		_clear_node(PIVOT_DEBUG_NODE)
		_pivots_visible = false
		_pivot_target_node = null
		return
	if node == null:
		push_warning("[AssetOverview] Select a tree/rock asset first — pivots apply to the selection only.")
		return
	_build_pivots_for_node(node)
	_pivots_visible = true
	_pivot_target_node = node


func _build_pivots_for_node(node: Node3D) -> void:
	var mi := node.get_node_or_null("Mesh") as MeshInstance3D
	if mi == null or mi.mesh == null:
		return
	var samples := _profile_samples_for_node(node)
	if samples.is_empty():
		push_warning("[AssetOverview] No embedded FBX ProfileSamples for %s — cannot derive pivots." % node.name)
		return
	var variants: Array[Dictionary] = [ProfileRecordSchema.default_bottom_pivot()]
	var vertical_range := _profile_sample_vertical_range(samples)

	_clear_node(PIVOT_DEBUG_NODE)
	var root := Node3D.new()
	root.name = PIVOT_DEBUG_NODE
	add_child(root)

	for i in range(variants.size()):
		var variant := variants[i]
		var pivot_name := str(variant.get("name", "pivot_%d" % i))
		var offset := VariantUtils.vector3_from_value(variant.get("offset", Vector3.ZERO), Vector3.ZERO)
		var marker := _make_pivot_marker(pivot_name, i)
		marker.position = node.to_global(offset) if node.is_inside_tree() else node.transform * offset
		root.add_child(marker)
		var tag := VoxelDebugLabel.make(
			"%s  y=%.2fm  bias=%+.2f" % [pivot_name, offset.y, float(variant.get("score_bias", 0.0))],
			Color.WHITE, 16, 0.0, 0.01, 3)
		tag.name = "PivotLabel_%d" % i
		tag.position = marker.position + Vector3(0.35, 0.12, 0.0)
		root.add_child(tag)
	_pivot_last_count = variants.size()

	var summary := VoxelDebugLabel.make(
		"%s\npivots=%d (bottom only)\ncollision sample h=%.2fm" % [
			node.name, variants.size(), float(vertical_range.get("height", 0.0))],
		Color.WHITE, 20, 0.0, 0.01, 4, false)
	summary.name = "PivotSummary"
	summary.position = node.position + Vector3(0.0, 3.0, 0.0)
	root.add_child(summary)


func _profile_sample_vertical_range(samples: Array[Dictionary]) -> Dictionary:
	var y_min := INF
	var y_max := -INF
	var count := 0
	for sample in samples:
		if float(sample.get("collision", 0.0)) <= 0.0:
			continue
		var offset := VariantUtils.vector3_from_value(
			sample.get("local_offset_world", Vector3.ZERO), Vector3.ZERO)
		y_min = minf(y_min, offset.y)
		y_max = maxf(y_max, offset.y)
		count += 1
	if count == 0:
		return {"ok": false, "min_y": 0.0, "max_y": 0.0, "height": 0.0, "count": 0}
	return {"ok": true, "min_y": y_min, "max_y": y_max, "height": y_max - y_min, "count": count}


func _make_pivot_marker(pivot_name: String, index: int) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = 0.09
	mesh.height = 0.18
	var color: Color = PIVOT_MARKER_COLORS.get(pivot_name, Color(0.7, 0.7, 1.0, 0.95))
	var mat := DemoDebugVisuals.make_unshaded_material(color, false, true)
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 1.8
	var marker := MeshInstance3D.new()
	marker.name = "Pivot_%d_%s" % [index, pivot_name]
	marker.mesh = mesh
	marker.material_override = mat
	return marker


# ─── 资产互斥球（放置期成对间距的现况可视化；场景一加载就画） ──
#
# 生产口径来自 `ScenePlacementActor._build_placement_asset_defs()`：
#   spacing_radius_world = max(mesh_aabb.size.x, mesh_aabb.size.z) * 0.5
# reduce（`shaders/invalidate_anchor_conflicts.glsl`）据此做成对判定——
#   dist(a, b) < max(min_distance_voxels, (r_a + r_b) * asset_spacing_factor)
# 时淘汰低优先级的一端。两端各画一个半径 r 的球 ⇒ **两球相交即这一对互斥**
# （`asset_spacing_factor` 默认 1.0；下界 `min_distance_voxels` 是 SPA 侧的全局
# 兜底，与资产无关，本场景没有 SV 网格也就没有体素尺寸可换算，故不画）。
#
# 球心取资产节点原点：判定比的是候选**原点**间距，而烘焙恒写单条零偏移 bottom pivot，
# 所以放置原点就是节点原点——网格 AABB 在 XZ 上不居中时球会看着偏，那正是现况。
#
# ⚠ 半径按 mesh AABB 算且**不乘节点 scale**：放置端读的是烘进 descriptor 的那份原始
# mesh（`AssetDescriptor.get_mesh()`），节点 scale 不参与。geo 资产的 scale 由
# 「Bake → FBX」冻结进源文件，本场景里两者本就一致。

## 网格给出的基础互斥半径（米，世界单位，**未乘**逐资产乘数）；无 Mesh 子节点或
## 无网格时返回 0（不画球）。
static func exclusion_base_radius_for_node(node: Node3D) -> float:
	if node == null:
		return 0.0
	var mi := node.get_node_or_null("Mesh") as MeshInstance3D
	if mi == null or mi.mesh == null:
		return 0.0
	var aabb_size := mi.mesh.get_aabb().size
	return maxf(aabb_size.x, aabb_size.z) * 0.5


## 逐资产互斥半径乘数，取自**已烘焙 descriptor**（`spacing_radius_scale`）——那正是
## SPA 放置读的同一份资源，所以面板改完存盘，球和 reduce 的间距一起变。
## 没烘过 descriptor 的资产没有可调值，返回 1.0。
static func exclusion_radius_scale_for_node(node: Node3D) -> float:
	if node == null:
		return 1.0
	var path := "%s/%s_descriptor.tres" % [BAKED_DESCRIPTOR_DIR, node.name]
	if not ResourceLoader.exists(path):
		return 1.0
	var descriptor: Resource = load(path)
	if descriptor == null:
		return 1.0
	# 属性直读：编辑器把资源脚本当 placeholder 时方法不执行、属性照样可读。
	var raw = descriptor.get("spacing_radius_scale")
	if raw == null:
		return 1.0
	return maxf(float(raw), 0.0)


## 生效互斥半径 = 网格基础半径 × 逐资产乘数。球画的是它，reduce 用的也是它。
static func exclusion_radius_for_node(node: Node3D) -> float:
	return exclusion_base_radius_for_node(node) * exclusion_radius_scale_for_node(node)


func _toggle_exclusion_spheres() -> void:
	_exclusion_visible = not _exclusion_visible
	_rebuild_exclusion_display()


## 全量重建：整组丢弃再按当前资产表重画（球不跟随节点，手动挪过资产后按两次 6 即刷新）。
func _rebuild_exclusion_display() -> void:
	_clear_node(EXCLUSION_DEBUG_NODE)
	_exclusion_last_count = 0
	if not Engine.is_editor_hint() or not _exclusion_visible:
		return
	_collect_static_assets()
	if _asset_nodes.is_empty():
		return
	var root := Node3D.new()
	root.name = EXCLUSION_DEBUG_NODE
	add_child(root)
	for i in range(_asset_nodes.size()):
		var node := _asset_nodes[i]
		if node == null:
			continue
		var radius := exclusion_radius_for_node(node)
		if radius <= 0.0:
			continue
		# 逐资产换色：总览里球体尺寸差一个量级（cliff ~10 m vs grass ~1 m），
		# 相交时同色会糊成一团，看不出是哪两个在互斥。
		var color := Color.from_hsv(fmod(float(i) * 0.137, 1.0), 0.55, 1.0)
		var center := node.global_position if node.is_inside_tree() else node.position
		_watch_descriptor_changes(node)
		root.add_child(_make_exclusion_sphere(str(node.name), center, radius, color))
		# 贴标随半径缩放：本场景的球差一个量级（grass 0.85 m ↔ cliff 23 m），
		# 固定 pixel_size 的话不是大球边上小得看不见，就是小球被字糊住。
		var tag := VoxelDebugLabel.make(
			"%s\nexclusion r=%.2f m" % [node.name, radius],
			color, 16, 0.0, clampf(radius * 0.012, 0.01, 0.06), 3)
		tag.name = "ExclusionLabel_%s" % node.name
		tag.position = center + Vector3(0.0, radius + 0.35, 0.0)
		root.add_child(tag)
		_exclusion_last_count += 1


## Godot 里没有 UE ConstructionScript 那种「任何属性一改就整体重跑」的单一钩子，最接近的
## 是 `@tool` + 属性 setter / `Resource.changed`：Resource 在 Inspector 里被改动会发
## `changed`，挂上去重建就等价于 construction script 的即时反馈。
##
## 挂在 descriptor 上（而不是场景节点）是因为半径乘数存在 descriptor 里：无论改动来自
## Asset Info 面板的 SpinBox（走 preview_exclusion_radius_scale）还是直接在 Inspector
## 里选中 .tres 改 `spacing_radius_scale`，都会经过这里 ⇒ 球立刻跟着变。
## 连接幂等（重建会重复调用本函数），descriptor 是常驻缓存资源、本场景被释放时 Godot
## 自动断开。
func _watch_descriptor_changes(node: Node3D) -> void:
	var path := "%s/%s_descriptor.tres" % [BAKED_DESCRIPTOR_DIR, node.name]
	if not ResourceLoader.exists(path):
		return
	var descriptor: Resource = load(path)
	if descriptor == null:
		return
	var callable := Callable(self, "_on_descriptor_changed")
	if not descriptor.changed.is_connected(callable):
		descriptor.changed.connect(callable)


func _on_descriptor_changed() -> void:
	if not _exclusion_visible:
		return
	# 延后一帧：`changed` 可能在 Inspector 写属性的中途发出，此刻直接 free 掉整组显示节点
	# 不安全；而且一次编辑可能连发多下，合并成一次重建。
	_rebuild_exclusion_display.call_deferred()


## 面板 SpinBox 拖动时的即时预览：只改**内存里**那份 descriptor，不写盘（Save 才落 .tres）。
## SPA 读的是同一个常驻实例 ⇒ 本编辑器会话内的放置也会用这个新值；重开编辑器则回到盘上的值。
## 改完发 `changed`，重建交给上面那条统一路径。
func preview_exclusion_radius_scale(descriptor_path: String, scale: float) -> Dictionary:
	if not ResourceLoader.exists(descriptor_path):
		return {"ok": false, "reason": "no_descriptor"}
	var descriptor: Resource = load(descriptor_path)
	if descriptor == null:
		return {"ok": false, "reason": "load_failed"}
	var clamped := maxf(scale, 0.0)
	descriptor.set(SPACING_SCALE_PROP, clamped)
	descriptor.emit_changed()
	return {"ok": true, "scale": clamped}


func _make_exclusion_sphere(asset_name: String, center: Vector3, radius: float, color: Color) -> Node3D:
	var group := Node3D.new()
	group.name = "Exclusion_%s" % asset_name
	group.position = center

	# 极淡的实心壳给出体积感，双面 + 透明（不写深度）⇒ 资产本体不会被它糊住，
	# 相机进到球里也还看得见边界。
	# ⚠ alpha 取到 0.045 这么低是因为双面：前后两个半球各画一次，屏幕上是叠加后的
	# 约 0.09。再高一档（实测 0.07 → 叠出 0.14）就会给资产本体染色，和 [2] 的
	# color 通道检查打架——这个场景就是用来看资产原色的。
	var shell_mesh := SphereMesh.new()
	shell_mesh.radius = radius
	shell_mesh.height = radius * 2.0
	shell_mesh.radial_segments = 32
	shell_mesh.rings = 16
	var shell := MeshInstance3D.new()
	shell.name = "Shell"
	shell.mesh = shell_mesh
	shell.material_override = DemoDebugVisuals.make_unshaded_material(
		Color(color.r, color.g, color.b, 0.045), false, false, true)
	group.add_child(shell)

	# 三个大圆是"球有多大"的实际读数来源（单位线框球半径 0.5 ⇒ scale = 直径）。
	var wire := MeshInstance3D.new()
	wire.name = "Wire"
	wire.mesh = DemoDebugVisuals.make_unit_wire_sphere_mesh()
	wire.scale = Vector3.ONE * (radius * 2.0)
	wire.material_override = DemoDebugVisuals.make_unshaded_material(
		Color(color.r, color.g, color.b, 0.75), false, false, true)
	group.add_child(wire)
	return group


# ─── Embedded FBX ProfileSample channel display ───────────────

func _show_voxel_channel(channel: String) -> void:
	var node := _resolve_selected_asset_node()
	# Re-pressing the active channel on the same node toggles it off.
	if node != null and _voxel_channel == channel and _voxel_baked_node == node:
		_clear_node(VOXEL_DEBUG_NODE)
		_voxel_channel = VOXEL_CHANNEL_NONE
		return
	if node == null:
		push_warning("[AssetOverview] Select an FBX asset first — sample channels apply to the selection only.")
		return
	_ensure_voxels_baked_for_node(node)
	_clear_node(VOXEL_DEBUG_NODE)
	_voxel_channel = channel
	_build_voxel_channel_display(channel)


# Cache decoded ProfileSamples only for the selected node.
func _ensure_voxels_baked_for_node(node: Node3D) -> void:
	if _voxel_baked_node == node and not _voxel_results.is_empty():
		return
	_voxel_results.clear()
	_voxel_baked_node = node
	var samples := _profile_samples_for_node(node)
	if samples.is_empty():
		push_warning("[AssetOverview] No embedded FBX ProfileSamples for %s." % node.name)
		return
	_voxel_results.append({"ok": true, "node": node, "samples": samples})


func _voxel_result_for_node(node: Node3D) -> Dictionary:
	for result in _voxel_results:
		if result.get("node") == node:
			return result
	return {}


func _build_voxel_channel_display(channel: String) -> void:
	var root := Node3D.new()
	root.name = VOXEL_DEBUG_NODE
	add_child(root)

	var total_samples := 0
	var shown_samples := 0
	for result in _voxel_results:
		var node: Node3D = result["node"]
		var samples: Array = result.get("samples", [])
		total_samples += samples.size()

		var centers := PackedVector3Array()
		var colors := PackedColorArray()
		for raw_sample in samples:
			if not raw_sample is Dictionary:
				continue
			var sample := raw_sample as Dictionary
			if (int(sample.get("flags", 0)) & ProfileRecordSchema.SAMPLE_FLAG_FINE) == 0:
				continue
			var channel_color := _voxel_channel_color(sample, channel)
			if channel_color.a <= 0.0:
				continue
			var local_offset := VariantUtils.vector3_from_value(
				sample.get("local_offset_world", Vector3.ZERO), Vector3.ZERO)
			centers.append(node.to_global(local_offset) if node.is_inside_tree() else node.transform * local_offset)
			colors.append(channel_color)
		shown_samples += centers.size()

		var marker_size := clampf(
			float(node.get_meta(GeoAssetScanService.GEO_BOUND_LONGEST_META, 1.0)) * 0.004,
			0.01,
			0.12
		)
		var cell := Vector3.ONE * marker_size
		var display := VoxelDisplay.build_colored(centers, cell, colors, {
			"name": "%s_%s" % [node.name, channel],
			"unshaded": true,
		})
		if display != null:
			root.add_child(display)

	var label := VoxelDebugLabel.make(
		"FBX sample channel: %s\nfine shown=%d / all=%d" % [
			channel, shown_samples, total_samples
		],
		Color.WHITE, 28, 0.0, 0.01, 5, false
	)
	label.name = "VoxelChannelLabel"
	label.position = Vector3(0.0, 3.2, 2.0)
	root.add_child(label)


# Map a canonical ProfileSample to a display color for the requested channel.
#  - color:      raw RGBA8 color, alpha forced opaque so the cell is visible.
#  - complexity: grayscale ramp of the visual-strength channel.
#  - collision:  red ramp of the rigid-occupancy channel; black where 0 (still shown).
func _voxel_channel_color(sample: Dictionary, channel: String) -> Color:
	match channel:
		VOXEL_CHANNEL_COLOR:
			var c: Color = sample.get("color", Color.WHITE)
			return Color(c.r, c.g, c.b, 0.92)
		VOXEL_CHANNEL_COMPLEXITY:
			var x := clampf(float(sample.get("complexity", 0.0)), 0.0, 1.0)
			return Color(x, x, x, 0.92)
		VOXEL_CHANNEL_COLLISION:
			var s := clampf(float(sample.get("collision", 0.0)), 0.0, 1.0)
			# collision == 0 renders BLACK (still visible), NOT hidden — so a soft asset
			# whose collision is legitimately 0 everywhere (e.g. grass) still shows its
			# samples instead of appearing empty.
			if s <= 0.0:
				return Color(0, 0, 0, 0.92)
			return Color(1.0, 1.0 - s * 0.7, 0.15, 0.92)
		_:
			return Color(0, 0, 0, 0.0)


# ─── Bake AssetDescriptor per displayed mesh ──────────────────
#
# Toolbar entry point: decode each FBX asset's embedded canonical ProfileSamples
# and save one AssetDescriptor .tres per mesh under BAKED_DESCRIPTOR_DIR.

## `ensure_fresh` = 烘焙前先跑一次增量扫描，把源 FBX 已变而节点没跟上的那些重建。
##
## ⚠ 为什么必须有这一步：`_bake_request_for_node()` 取的是场景节点的 `Mesh.mesh`。FBX 改了
## 而没重扫时，那份几何还是上一版，于是 Bake 会**烘出一个过期 descriptor 且全程不报错**。
## 实测事故（2026-08-13 stone_01）：场景停在 16:26 那版、FBX 16:59 换成 1/3 尺寸，
## 两边差出精确 3.0 倍，只能靠比对 AABB 才发现。
## 增量扫描自身按 `GEO_MTIME_META` 比对，未变的节点原样跳过，代价接近零。
##
## 只有 Scan/FullRescan 之后的自动烘焙传 false —— 那条路刚扫过，再扫是白跑一趟。
func bake_scene_descriptors(ensure_fresh: bool = true) -> Dictionary:
	if not Engine.is_editor_hint():
		return {"ok": false, "reason": "editor_only", "baked": 0, "failed": 0, "total": 0}
	if ensure_fresh:
		_scan_geo_assets(false)
	_collect_static_assets()
	var nodes: Array[Node3D] = []
	nodes.append_array(_asset_nodes)
	if nodes.is_empty():
		push_warning("[AssetOverview] No displayed asset meshes to bake — scan geo or add tree/rock assets first.")
		return {"ok": false, "reason": "no_assets", "baked": 0, "failed": 0, "total": 0}
	var requests: Array = []
	for node in nodes:
		requests.append(_bake_request_for_node(node))
	var summary := AssetDescriptorBaker.bake_and_save_batch(requests, BAKED_DESCRIPTOR_DIR)
	GeoAssetScanService.refresh_editor_filesystem()
	# ⚠ 原策略（计划 §11.5）是「Bake 只产出 Authoring 产物，不隐式改写 SPA 的 GPU Arena，
	# 新版本一律由用户点 Reload 显式提交」。用户 2026-08-13 决定改为自动提交：
	# 插件的 `_refresh_volume_score_after_bake()` 会刷新**所有已打开场景**里的 SPA。
	# 本方法自身仍然只落盘、不碰 Arena——推送归插件那一侧，保持 authoring 与 runtime 分层。
	summary["output_dir"] = BAKED_DESCRIPTOR_DIR
	summary["spa_arena_status"] = "Auto-refreshed (open SPA scenes)"
	var bake_report := "Baked descriptors: %d\nOutput directory: %s\nSPA Arena: auto-refreshed in open scenes" % [
		int(summary.get("baked", 0)), BAKED_DESCRIPTOR_DIR]
	summary["report_text"] = bake_report
	print("[AssetOverview] Baked %d/%d descriptors (failed %d) -> %s" % [
		int(summary.get("baked", 0)), nodes.size(), int(summary.get("failed", 0)), BAKED_DESCRIPTOR_DIR])
	# 走非阻塞的状态位而不是 AcceptDialog：Bake 是常规操作，不该每次都要人点确认。
	_set_bake_status(bake_report)
	_autosave_after_bake()
	return summary


## 烘焙后自动存盘。
##
## ⚠ 为什么必须自动：`ensure_fresh` 的重扫改的是**内存里的**场景节点，不存盘的话 `.tscn`
## 仍停在旧几何，下次打开编辑器又回到烘焙前的状态——磁盘上的 descriptor 是新的、场景是旧的，
## 两边再次脱节。实测事故（2026-08-13 stone_01）就是这么来的：场景停在 16:26 那版，
## 烘焙用的是重扫后的内存节点，编辑器一退出内存改动全丢。
##
## 只在本节点确实是当前编辑场景根时保存：`EditorInterface.save_scene()` 存的是**当前**场景，
## 若从别处（桥调用、其它场景为当前）触发烘焙，无条件调用就会把不相干的场景一起存了。
func _autosave_after_bake() -> void:
	if not Engine.is_editor_hint():
		return
	if EditorInterface.get_edited_scene_root() != self:
		push_warning("[AssetOverview] 烘焙后未自动存盘：当前编辑场景不是 Asset Overview。重扫改的是内存节点，请切回该场景手动保存。")
		return
	if scene_file_path.is_empty():
		push_warning("[AssetOverview] 烘焙后未自动存盘：场景还没有磁盘路径（未保存过的新场景）。")
		return
	var err := EditorInterface.save_scene()
	if err != OK:
		push_warning("[AssetOverview] 烘焙后自动存盘失败（err=%d）——请手动 Ctrl+S，否则重扫结果会丢。" % err)
		return
	print("[AssetOverview] 场景已自动保存：%s" % scene_file_path)


# 组装 canonical ProfileSample bake 请求；mesh 缺失时只带 name，由 baker 计 failed。
func _bake_request_for_node(node: Node3D) -> Dictionary:
	var mi := node.get_node_or_null("Mesh") as MeshInstance3D
	if mi == null or mi.mesh == null:
		return {"name": str(node.name)}
	var samples := _profile_samples_for_node(node)
	var avg := _profile_sample_average(samples)
	var pivots := [ProfileRecordSchema.default_bottom_pivot()]
	return {
		"name": str(node.name),
		"mesh": mi.mesh,
		"config": {
			"color": avg.color,
			"complexity": avg.complexity,
			"profile_samples": samples,
			"pivot_variants": pivots,
			"asset_id": str(node.name).to_lower(),
			"object_type": "asset",
			"source_mesh_path": str(node.get_meta(GeoAssetScanService.GEO_SOURCE_META, "")),
		},
	}


# ─── Asset info (Inspector-embedded data source) ──────────────
#
# The AssetInfoInspector (addons/meshfill_editor) renders this per-asset info
# inline in the Inspector when an asset node — or a child such as its Mesh — is
# selected. Its text and Bake AD both read the same embedded FBX ProfileSamples.

# Resolve any node (asset root OR a descendant like its Mesh) to the owning asset
# Node3D under Assets/*, or null when it is not one of this scene's assets.
func resolve_asset_node(node: Node) -> Node3D:
	if node == null:
		return null
	_collect_static_assets()
	var asset_set := {}
	for n in _asset_nodes:
		asset_set[n] = true
	var cur: Node = node
	while cur != null:
		if cur is Node3D and asset_set.has(cur):
			return cur as Node3D
		cur = cur.get_parent()
	return null


# Read-only text + per-asset editable state for the Inspector panel.
# params[*] = {prop,label,min,max,step,overridden,value}; unchecked rows carry the
# inherited global value so you can see what you'd inherit (Save still writes -1).
# spacing = 互斥半径乘数那一行（无 override 语义）+ 供面板算「× 后是多少米」的基础半径。
func get_asset_inspector_payload(asset_node: Node3D) -> Dictionary:
	if not Engine.is_editor_hint() or asset_node == null:
		return {"ok": false, "reason": "invalid"}
	var descriptor_path := "%s/%s_descriptor.tres" % [BAKED_DESCRIPTOR_DIR, asset_node.name]
	var descriptor: Resource = load(descriptor_path) if ResourceLoader.exists(descriptor_path) else null
	var defaults := _global_score_defaults()
	var params: Array = []
	for row in SCORE_PARAM_ROWS:
		var prop := str(row.get("prop", ""))
		var val := -1.0
		if descriptor != null:
			var raw = descriptor.get(prop)
			if raw != null:
				val = float(raw)
		var overridden := val >= 0.0
		params.append({
			"prop": prop,
			"label": row.get("label", prop),
			"min": row.get("min", 0.0),
			"max": row.get("max", 1.0),
			"step": row.get("step", 0.01),
			"overridden": overridden,
			"value": val if overridden else float(defaults.get(prop, 0.0)),
		})
	var spacing := SPACING_SCALE_ROW.duplicate()
	spacing["value"] = exclusion_radius_scale_for_node(asset_node)
	spacing["base_radius"] = exclusion_base_radius_for_node(asset_node)
	spacing["has_descriptor"] = descriptor != null
	return {
		"ok": true,
		"name": str(asset_node.name),
		"text": _build_asset_properties_text(asset_node),
		"descriptor_path": descriptor_path,
		"params": params,
		"spacing": spacing,
	}


# Write the per-asset authored overrides onto the descriptor .tres：
#   * SCORE_PARAM_ROWS —— values[prop] = 值，或 -1 表示继承全局；
#   * SPACING_SCALE_PROP —— 互斥半径乘数（clamp 到 >= 0）。
# Mutates the cached resource instance (shared with placement scenes) + writes disk:
# 打分在下一次 env 重建读到，reduce 的成对间距在下一次 run_placement_pipeline 读到
# （`_build_placement_asset_defs()` 每轮重建 def，读的就是这个常驻实例）。
func save_asset_params(descriptor_path: String, values: Dictionary) -> Dictionary:
	if not ResourceLoader.exists(descriptor_path):
		push_warning("[AssetOverview] No baked descriptor at %s — press Bake AD first." % descriptor_path)
		return {"ok": false, "reason": "no_descriptor"}
	var descriptor: Resource = load(descriptor_path)
	if descriptor == null:
		push_warning("[AssetOverview] Failed to load descriptor %s" % descriptor_path)
		return {"ok": false, "reason": "load_failed"}
	for row in SCORE_PARAM_ROWS:
		var prop := str(row.get("prop", ""))
		if values.has(prop):
			descriptor.set(prop, float(values[prop]))
	if values.has(SPACING_SCALE_PROP):
		descriptor.set(SPACING_SCALE_PROP, maxf(float(values[SPACING_SCALE_PROP]), 0.0))
	var err := ResourceSaver.save(descriptor, descriptor_path)
	if err != OK:
		push_warning("[AssetOverview] Save asset params failed (err=%d): %s" % [err, descriptor_path])
		return {"ok": false, "reason": "save_failed", "err": err}
	print("[AssetOverview] Saved per-asset params → %s" % descriptor_path)
	# 半径乘数改了就得立刻重画：面板上的数与视口里的球必须是同一个现况。
	_rebuild_exclusion_display()
	return {"ok": true}


## Debug: dump what Godot's FBX importer produced for an FBX (points survival,
## primitive type, surviving per-vertex arrays, sample values) — bridge entry to
## validate the FBX-embedded-voxel convention. Prints full JSON to the console.
func inspect_fbx_report(path: String) -> Dictionary:
	var report := FbxVoxelImportService.inspect_fbx(path)
	print("[FBX Inspect] ", JSON.stringify(report, "  "))
	var meshes: Array = report.get("meshes", [])
	return {"ok": bool(report.get("ok", false)), "mesh_count": meshes.size(), "path": path}


## Editor 3D viewport overlay: expose the selected asset's Houdini FBX channel
## contract and the values Godot actually imported. The editor plugin draws this
## text using the same compact dark 2D panel as SPA selection details.
func get_selection_overlay_text() -> String:
	if not Engine.is_editor_hint():
		return ""
	# ⚠ 这里被插件**每帧**轮询。以前它顺手改可见性，等于每帧把「只显示选中的」重新压一遍；
	# 现在只读选中节点，一个 visible 都不写。
	var node := _resolve_selected_asset_node()
	if node == null:
		return ""
	var source := str(node.get_meta(GeoAssetScanService.GEO_SOURCE_META, ""))
	if source.is_empty() or source.get_extension().to_lower() != "fbx":
		return ""
	var absolute_source := ProjectSettings.globalize_path(source)
	var modified_time := FileAccess.get_modified_time(absolute_source)
	var cache_key := "%d|%s|%s|%d" % [node.get_instance_id(), node.name, source, modified_time]
	if cache_key != _fbx_channel_overlay_cache_key:
		_fbx_channel_overlay_cache_key = cache_key
		_fbx_channel_overlay_cache_text = _build_fbx_channel_overlay_text(node, source)
	return _fbx_channel_overlay_cache_text


func _build_fbx_channel_overlay_text(node: Node3D, source: String) -> String:
	var report := FbxVoxelImportService.inspect_fbx(source)
	var lines := PackedStringArray(["FBX Fine Score / Probe | %s" % node.name])
	if not bool(report.get("ok", false)):
		lines.append("%s | load failed: %s" % [source.get_file(), str(report.get("reason", "unknown"))])
		return "\n".join(lines)

	var fine_count := int(report.get("fine_score_triangle_count", 0))
	var probe_count := int(report.get("probe_triangle_count", 0))
	lines.append("Fine  Color + FBX uv8.x=1  triangles=%d  missing=%d" % [
		fine_count, int(report.get("fine_score_missing_payload_count", 0))])
	lines.append("Probe Normal + FBX uv8.y=1  triangles=%d  missing=%d" % [
		probe_count, int(report.get("probe_missing_payload_count", 0))])
	lines.append("last valid UV set -> uv8  UV0/UV1 preserved  public V=FBX space")
	_append_fbx_surface_overlay_lines(report, lines)
	_append_fbx_channel_position_line(lines, "Fine", report.get("fine_score_position_samples", []), fine_count)
	_append_fbx_channel_position_line(lines, "Probe", report.get("probe_position_samples", []), probe_count)
	lines.append("payload=raw (decode schema pending)  position=triangle centroid")
	var removed_count := int(node.get_meta(GeoAssetScanService.GEO_EMBEDDED_DATA_TRIANGLES_META, 0))
	lines.append("production geometry removed=%d data triangles" % removed_count)
	return "\n".join(lines)


func _append_fbx_channel_position_line(
	lines: PackedStringArray, label: String, position_samples: Array, total_count: int
) -> void:
	if position_samples.is_empty() or not position_samples[0] is Array:
		return
	var p := position_samples[0] as Array
	if p.size() < 3:
		return
	var remaining := maxi(total_count - 1, 0)
	var suffix := "  (+%d)" % remaining if remaining > 0 else ""
	lines.append("%s[0]=(%.3f, %.3f, %.3f)%s" % [
		label, float(p[0]), float(p[1]), float(p[2]), suffix])


func _append_fbx_surface_overlay_lines(report: Dictionary, lines: PackedStringArray) -> void:
	var meshes: Array = report.get("meshes", [])
	var surface_line_count := 0
	for raw_mesh in meshes:
		if not raw_mesh is Dictionary:
			continue
		var mesh := raw_mesh as Dictionary
		for raw_surface in mesh.get("surfaces", []):
			if not raw_surface is Dictionary:
				continue
			var surface := raw_surface as Dictionary
			if not bool(surface.get("has_uv8", false)):
				continue
			if surface_line_count >= 4:
				lines.append("... more uv8 surfaces")
				return
			var uv8_range: Variant = surface.get("uv8_fbx_range", null)
			var x_text := "n/a"
			var y_text := "n/a"
			if uv8_range is Array and (uv8_range as Array).size() >= 4:
				var values := uv8_range as Array
				var x_min := float(values[0])
				var y_min := float(values[1])
				var x_max := float(values[2])
				var y_max := float(values[3])
				x_text = "%.3f" % x_min if is_equal_approx(x_min, x_max) else "%.3f..%.3f" % [x_min, x_max]
				y_text = "%.3f" % y_min if is_equal_approx(y_min, y_max) else "%.3f..%.3f" % [y_min, y_max]
			var surface_name := "surface %d" % int(surface.get("index", -1))
			if meshes.size() > 1:
				surface_name = "%s / %s" % [str(mesh.get("node", "mesh")), surface_name]
			lines.append("%s  uv8[%d]=(%s, %s)  F=%d P=%d  C=%s N=%s" % [
				surface_name,
				int(surface.get("uv8_set_index", -1)),
				x_text,
				y_text,
				int(surface.get("fine_score_triangle_count", 0)),
				int(surface.get("probe_triangle_count", 0)),
				("Y" if bool(surface.get("has_color", false)) else "N"),
				("Y" if bool(surface.get("has_normal", false)) else "N"),
			])
			surface_line_count += 1


func _build_asset_properties_text(node: Node3D) -> String:
	var lines := PackedStringArray()
	lines.append("Node: %s" % node.name)
	var src := str(node.get_meta(GeoAssetScanService.GEO_SOURCE_META, ""))
	if not src.is_empty():
		lines.append("Source FBX: %s" % src)

	var mi := node.get_node_or_null("Mesh") as MeshInstance3D
	if mi != null and mi.mesh != null:
		var aabb := mi.mesh.get_aabb()
		lines.append("Mesh AABB size: (%.3f, %.3f, %.3f) m" % [aabb.size.x, aabb.size.y, aabb.size.z])
		lines.append("Mesh surfaces: %d" % mi.mesh.get_surface_count())
		# 互斥半径：与视口里那个球、与 reduce 的成对间距同一个值（见 exclusion_radius_for_node）。
		var base_radius := exclusion_base_radius_for_node(node)
		var radius_scale := exclusion_radius_scale_for_node(node)
		lines.append("Exclusion radius: %.3f m = %.3f m (XZ half-extent) × %.2f" % [
			base_radius * radius_scale, base_radius, radius_scale])
		lines.append("  pair rejected when spheres cross (same value drives SPA spacing)")
	else:
		lines.append("Mesh: (missing)")

	var basis := node.transform.basis
	var rot_deg := basis.get_euler() * 57.2957795
	var scl := basis.get_scale()
	lines.append("Transform pos: (%.2f, %.2f, %.2f)" % [node.position.x, node.position.y, node.position.z])
	lines.append("Transform rot°: (%.1f, %.1f, %.1f)" % [rot_deg.x, rot_deg.y, rot_deg.z])
	lines.append("Transform scale: (%.3f, %.3f, %.3f)" % [scl.x, scl.y, scl.z])

	lines.append("")
	_append_profile_sample_property_lines(node, lines)

	lines.append("")
	var descriptor_path := "%s/%s_descriptor.tres" % [BAKED_DESCRIPTOR_DIR, node.name]
	lines.append("Baked descriptor: %s" % (
		descriptor_path if ResourceLoader.exists(descriptor_path) else "none — press Bake AD"))
	return "\n".join(lines)


func _append_profile_sample_property_lines(node: Node3D, lines: PackedStringArray) -> void:
	var samples := _profile_samples_for_node(node)
	if samples.is_empty():
		lines.append("ProfileSamples: none embedded in source FBX")
		return
	var avg := _profile_sample_average(samples)
	var col: Color = avg.color
	lines.append("ProfileSamples: %d total, %d coarse, %d fine" % [
		samples.size(),
		_profile_sample_stage_count(samples, ProfileRecordSchema.SAMPLE_FLAG_COARSE),
		_profile_sample_stage_count(samples, ProfileRecordSchema.SAMPLE_FLAG_FINE),
	])
	lines.append("Avg color: (%.2f, %.2f, %.2f)" % [col.r, col.g, col.b])
	lines.append("Avg complexity: %.3f" % float(avg.complexity))

	var vertical_range := _profile_sample_vertical_range(samples)
	lines.append("Collision sample height: %.2f m (%d samples)" % [
		float(vertical_range.get("height", 0.0)), int(vertical_range.get("count", 0))])
	var variants := [ProfileRecordSchema.default_bottom_pivot()]
	var pivot_parts := PackedStringArray()
	for variant in variants:
		var offset := VariantUtils.vector3_from_value(variant.get("offset", Vector3.ZERO), Vector3.ZERO)
		pivot_parts.append("%s@y=%.2f" % [str(variant.get("name", "pivot")), offset.y])
	lines.append("Pivots (%d): %s" % [variants.size(), ", ".join(pivot_parts)])


## Resolved global default per descriptor prop = what an un-overridden row inherits.
## The 4 match budgets read live from score_match_config.cfg (fallback = the
## VoxelPlacementGenerator code defaults, mirrored here); the 3 dim weights are code-only
## (not in the cfg). Display-only — the shader still inherits via the -1 sentinel.
func _global_score_defaults() -> Dictionary:
	var d := {
		"score_min_match_fraction": 0.35,
		"score_dim_weight_collision": 1.0,
		"score_dim_weight_complexity": 1.0,
		"score_dim_weight_color": 0.34,
		"score_color_match_max_l1": 0.6,
		"score_collision_match_max": 0.5,
		"score_complexity_overfill_percent": 20.0,
	}
	var cfg := ConfigFile.new()
	if cfg.load("res://score_match_config.cfg") == OK:
		d["score_min_match_fraction"] = float(cfg.get_value("score_match", "min_match_fraction", d["score_min_match_fraction"]))
		d["score_color_match_max_l1"] = float(cfg.get_value("score_match", "color_match_max_l1", d["score_color_match_max_l1"]))
		d["score_collision_match_max"] = float(cfg.get_value("score_match", "collision_match_max", d["score_collision_match_max"]))
		d["score_complexity_overfill_percent"] = float(cfg.get_value("score_match", "complexity_overfill_percent", d["score_complexity_overfill_percent"]))
	return d


# ─── Clear ────────────────────────────────────────────────────

func _clear_all_debug() -> void:
	_clear_node(PROBE_DEBUG_NODE)
	_clear_node(VOXEL_DEBUG_NODE)
	_clear_node(PIVOT_DEBUG_NODE)
	# C 是「清空全部调试显示」，互斥球虽然默认开也一并关掉——按 6 或重开场景即回来。
	_clear_node(EXCLUSION_DEBUG_NODE)
	_exclusion_visible = false
	_exclusion_last_count = 0
	_probes.clear()
	_probes_visible = false
	_probe_target_node = null
	_probe_source = ""
	_pivots_visible = false
	_pivot_target_node = null
	_pivot_last_count = 0
	_voxel_channel = VOXEL_CHANNEL_NONE
	_voxel_baked_node = null
	_voxel_results.clear()


func _clear_probe_group(group_name: String) -> void:
	var debug_root := get_node_or_null(PROBE_DEBUG_NODE)
	if debug_root == null:
		return
	var group := debug_root.get_node_or_null(group_name)
	if group != null:
		group.free()


# ─── Helpers ──────────────────────────────────────────────────

func _get_or_create_debug_root() -> Node3D:
	var existing := get_node_or_null(PROBE_DEBUG_NODE) as Node3D
	if existing != null:
		return existing
	var root := Node3D.new()
	root.name = PROBE_DEBUG_NODE
	add_child(root)
	return root


func _clear_node(node_name: String) -> void:
	var existing := get_node_or_null(node_name)
	if existing != null:
		existing.free()


func _make_probe_marker(probe: Dictionary, index: int) -> MeshInstance3D:
	var shape_source := str(probe.get("shape_source", "unknown"))
	var color := Color(0.4, 1.0, 0.4, 0.9)
	if shape_source == "convex":
		color = Color(1.0, 0.85, 0.1, 0.9)
	elif shape_source == "voxel_interior":
		color = Color(0.15, 0.75, 1.0, 0.9)
	elif shape_source == "fbx_embedded":
		color = Color(1.0, 0.25, 0.85, 0.95)
	var marker := DemoDebugVisuals.make_probe_marker(probe, color, 0.06)
	marker.name = "Probe_%03d_%s" % [index, shape_source]
	var mat := marker.material_override as StandardMaterial3D
	mat.no_depth_test = true
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 1.5
	return marker
