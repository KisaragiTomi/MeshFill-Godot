@tool
extends EditorPlugin

const AssetInfoInspector := preload("res://addons/meshfill_editor/asset_info_inspector.gd")
const SPAInspector := preload("res://addons/meshfill_editor/spa_inspector.gd")

var _last_viewport_camera: Camera3D

var _brush_btn: Button
var _import_all_fbx_btn: Button
var _bake_descriptor_btn: Button
var _import_fbx_btn: Button
var _reimport_targetsv_btn: Button
var _targetsv_import_dialog: EditorFileDialog
var _asset_info_inspector: EditorInspectorPlugin
var _spa_inspector: EditorInspectorPlugin
const GEO_SCAN_METHOD := &"_scan_geo_assets"
const GEO_SCAN_FORMAT_METHOD := &"_format_geo_scan_result"
const ASSET_DESCRIPTOR_BAKE_METHOD := &"bake_scene_descriptors"
const IMPORT_FBX_METHOD := &"import_single_fbx"
const TARGETSV_DIALOG_NAME := "MeshFillTargetSVImportDialog"

# ---- MCP TCP Server ----
var _tcp_server: TCPServer
var _tcp_peers: Array = []
var _peer_buffers: Dictionary = {}
const MCP_PORT := 6800

# ---- Single-instance guard ----
var _instance_server: TCPServer
const LOCK_FILE := "user://editor_instance.lock"
const SINGLE_INSTANCE_PORT := 6799
const HEARTBEAT_INTERVAL_SEC := 5.0
const HEARTBEAT_STALE_SEC := 15.0
var _lock_held := false
var _duplicate_instance := false
var _duplicate_reason := ""
var _heartbeat_timer: float = 0.0
var _instance_token := ""
var _project_key := ""
var _score_benchmark_mode := false

# ---- RDG self-test (opt-in, off by default) ----
# 只有 `-e ... -- --rdg-selftest` 才跑；日常开编辑器一行都不跑、一个字都不打印。
# 脚本用运行时 load() 取，不用 preload/class_name —— 后两者会让套件在每次编辑器启动时
# 都被解析编译，而这里在意的正是默认启动路径的零成本。
const RDG_SELFTEST_FLAG := "--rdg-selftest"
const RDG_SELFTEST_SCRIPT := "res://scripts/checks/rdg_selftest.gd"

# ---- GLSL 生成区块去同步守卫（opt-in，默认关）----
# 只有 `-e ... -- --glsl-gen-check` 才跑。同样用运行时 load()，理由同上。
# 本套件纯读文件、不碰 RenderingDevice，但仍只给 `-e` 入口：CLAUDE.md 禁止一切
# runtime 启动，`-e` + 插件 flag 是本仓唯一合规的自检形式。
const GLSL_GEN_CHECK_FLAG := "--glsl-gen-check"
const GLSL_GEN_CHECK_SCRIPT := "res://scripts/checks/glsl_gen_block_checks.gd"

# ---- Selection info viewport overlay ----
# 编辑态下场景自己的 CanvasLayer HUD 不渲染进编辑器 3D 视口,故场景选中信息经本插件的
# _forward_3d_draw_over_viewport 直接画在编辑器 3D 视口左上。文本每帧从 overlay host 轮询,
# 变化时 update_overlays() 触发重绘(相机 orbit/pan 会自动触发重绘)。
var _selection_overlay_text := ""


func _enter_tree() -> void:
	if OS.get_cmdline_user_args().has("--score-benchmark"):
		_score_benchmark_mode = true
		set_process(false)
		print("[MeshFill Editor] Score benchmark mode — plugin services disabled")
		return
	_ensure_instance_identity()
	if not _acquire_single_instance_lock():
		_mark_duplicate_and_quit(_duplicate_reason)
		return
	if not _try_bind_single_instance_port():
		_mark_duplicate_and_quit("Single-instance port %d is already in use." % SINGLE_INSTANCE_PORT)
		return
	if not _try_bind_tcp():
		_mark_duplicate_and_quit("MCP TCP port %d is already in use." % MCP_PORT)
		return
	set_input_event_forwarding_always_enabled()
	set_force_draw_over_forwarding_enabled()  # ensure _forward_3d_draw_over_viewport always fires (selection overlay)
	set_process(true)
	_cleanup_doc_import_files()
	EditorInterface.get_resource_filesystem().filesystem_changed.connect(_cleanup_doc_import_files)
	_connect_scene_signals()
	_validate_current_scene.call_deferred()
	_create_brush_toolbar_button()
	_create_geo_scan_toolbar()
	_create_asset_descriptor_bake_toolbar()
	_create_targetsv_toolbar()
	_asset_info_inspector = AssetInfoInspector.new()
	add_inspector_plugin(_asset_info_inspector)
	_spa_inspector = SPAInspector.new()
	add_inspector_plugin(_spa_inspector)
	print("[MeshFill Editor] Activated — MCP bridge on 127.0.0.1:%d" % MCP_PORT)
	if OS.get_cmdline_user_args().has(RDG_SELFTEST_FLAG):
		_run_rdg_selftest.call_deferred()
	if OS.get_cmdline_user_args().has(GLSL_GEN_CHECK_FLAG):
		_run_glsl_gen_check.call_deferred()


## RDG 自检套件的唯一触发点（见 RDG_SELFTEST_FLAG）。延后一帧执行，让插件先完成挂载。
func _run_rdg_selftest() -> void:
	var script: GDScript = load(RDG_SELFTEST_SCRIPT)
	if script == null:
		printerr("[RDG selftest] 无法加载 %s" % RDG_SELFTEST_SCRIPT)
		return
	var result: Dictionary = script.new().run({"self_check": true})
	for line in result.get("report", []):
		print(line)
	if bool(result.get("ok", false)):
		print("[RDG selftest] PASS（%d 项断言）" % int(result.get("passed", 0)))
	else:
		printerr("[RDG selftest] FAIL（%d 通过 / %d 失败）" % [
			int(result.get("passed", 0)), int(result.get("failed", 0))])


## GLSL 生成区块守卫的唯一触发点（见 GLSL_GEN_CHECK_FLAG）。
func _run_glsl_gen_check() -> void:
	var script: GDScript = load(GLSL_GEN_CHECK_SCRIPT)
	if script == null:
		printerr("[glsl-gen] 无法加载 %s" % GLSL_GEN_CHECK_SCRIPT)
		return
	var result: Dictionary = script.new().run()
	for line in result.get("report", []):
		print(line)
	if bool(result.get("ok", false)):
		print("[glsl-gen] PASS（%d 个区块比对一致）" % int(result.get("passed", 0)))
	else:
		printerr("[glsl-gen] FAIL（%d 通过 / %d 失败）" % [
			int(result.get("passed", 0)), int(result.get("failed", 0))])


func _exit_tree() -> void:
	if _score_benchmark_mode:
		return
	if _asset_info_inspector != null:
		remove_inspector_plugin(_asset_info_inspector)
		_asset_info_inspector = null
	if _spa_inspector != null:
		remove_inspector_plugin(_spa_inspector)
		_spa_inspector = null
	_remove_targetsv_toolbar()
	_remove_asset_descriptor_bake_toolbar()
	_remove_geo_scan_toolbar()
	_remove_brush_toolbar_button()
	_stop_tcp_server()
	_stop_single_instance_port()
	_release_lock()
	var fs := EditorInterface.get_resource_filesystem()
	if fs.filesystem_changed.is_connected(_cleanup_doc_import_files):
		fs.filesystem_changed.disconnect(_cleanup_doc_import_files)
	_disconnect_scene_signals()
	print("[MeshFill Editor] Deactivated")


func _process(delta: float) -> void:
	if _duplicate_instance:
		return
	_poll_single_instance_port()
	_poll_tcp()
	_sync_brush_btn_visibility()
	_sync_geo_scan_toolbar_from_scene()
	_sync_asset_descriptor_bake_toolbar_from_scene()
	_sync_targetsv_toolbar_from_scene()
	_sync_selection_overlay()
	_heartbeat_timer += delta
	if _heartbeat_timer >= HEARTBEAT_INTERVAL_SEC:
		_heartbeat_timer = 0.0
		_write_heartbeat()


# ---- MeshFillBrush EditorPlugin integration --------------------------------

func _handles(object: Object) -> bool:
	return object is Node3D


func _edit(_object: Object) -> void:
	pass


func _forward_3d_gui_input(viewport_camera: Camera3D, event: InputEvent) -> int:
	_last_viewport_camera = viewport_camera
	return _forward_to_scene_viewport_input(viewport_camera, event)


func _forward_to_scene_viewport_input(viewport_camera: Camera3D, event: InputEvent) -> int:
	var host := _scene_viewport_input_host()
	if host == null:
		return AFTER_GUI_INPUT_PASS
	var consumed: bool = host.handle_editor_input(viewport_camera, event) \
		if host is ScenePlacementActor \
		else bool(host.call(&"_editor_viewport_input", viewport_camera, event))
	if consumed:
		return AFTER_GUI_INPUT_STOP
	return AFTER_GUI_INPUT_PASS


# Any edited scene implementing the editor viewport input contract receives
# forwarded 3D viewport events. The SPA host takes priority (it owns selection
# mode), otherwise the edited scene root (e.g. AssetOverview) is used so
# its debug shortcuts cover the editor viewport instead of relying on runtime
# _unhandled_input.
func _scene_viewport_input_host() -> Node:
	var spa := _scene_spa_host()
	if spa != null and spa.has_method(&"handle_editor_input"):
		return spa
	var root := get_editor_interface().get_edited_scene_root()
	if root != null and root.has_method(&"_editor_viewport_input"):
		return root
	return null


# ---- Selection info viewport overlay --------------------------------------
# Edit-time CanvasLayer HUDs don't composite into the 3D editor viewport, so scene
# selection info is drawn straight onto the viewport here instead. Text is polled from
# the active overlay host each frame; a change triggers update_overlays() (camera moves
# already trigger a viewport redraw on their own).

# ⚠ 编辑器软重载后的成员修复，别当成冗余判空删掉。EditorPlugin 是全项目最容易吃到软重载
# 的脚本：改动 addons/ 下任何脚本都会让它就地重载。事实依据（gdscript.cpp
# GDScriptInstance::reload_members）：软重载只把**重载前已存在**的成员按名字搬进新槽位；
# 本次重载**新增**的成员槽是默认构造的 Variant = nil，声明里的初始化器不会重跑，静态类型
# 也拦不住（实例槽本身是 Variant）。_selection_overlay_text 是本轮新增的，重载后
# _forward_3d_draw_over_viewport() 每帧都会调 `nil.is_empty()`，而 `text != nil` 这一句
# 会走 String≠String 的验证求值器、把 nil 的内存当 String 读。
# ⚠ 必须用 `is` 而不是 `== null`：Variant 给 (STRING, NIL) 注册的是
# OperatorEvaluatorAlwaysFalse（variant_op.cpp），静态类型已知时 `== null` 恒 false。
# 语义：回到空串 = "当前没有覆盖层文本"，下一次 _sync_selection_overlay 立刻重新填。
func _repair_soft_reloaded_members() -> void:
	if not (_selection_overlay_text is String): _selection_overlay_text = ""
	if not (_score_benchmark_mode is bool): _score_benchmark_mode = false
	# 语义：回到 null = "本插件不再持有那个按钮"。控件本身还挂在工具栏容器里（重载不动
	# 场景树），只是引用丢了；下次 _exit_tree 收不走它，与另外几个按钮成员同样的既有行为。
	if not (_reimport_targetsv_btn is Button): _reimport_targetsv_btn = null
	# 同上；置空后 _ensure_targetsv_import_dialog() 会按结点名把既有对话框认领回来。
	if not (_targetsv_import_dialog is EditorFileDialog): _targetsv_import_dialog = null


func _sync_selection_overlay() -> void:
	_repair_soft_reloaded_members()
	var text := ""
	var host := _scene_selection_overlay_host()
	if host != null and host.has_method(&"get_selection_overlay_text"):
		text = str(host.call(&"get_selection_overlay_text"))
	if text != _selection_overlay_text:
		_selection_overlay_text = text
		update_overlays()


func _scene_selection_overlay_host() -> Node:
	var spa := _scene_spa_host()
	if spa != null and spa.has_method(&"get_selection_overlay_text"):
		return spa
	return _scene_root_host(&"get_selection_overlay_text")


## Godot calls this to let the plugin paint 2D over the 3D editor viewport.
func _forward_3d_draw_over_viewport(overlay: Control) -> void:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	if overlay == null or _selection_overlay_text.is_empty():
		return
	_draw_selection_overlay(overlay, _selection_overlay_text)


func _draw_selection_overlay(overlay: Control, text: String) -> void:
	var font := overlay.get_theme_default_font()
	if font == null:
		return
	var font_size := 15
	var lines := text.split("\n")
	var pad := 8.0
	var line_h := font.get_height(font_size) + 2.0
	var max_w := 0.0
	for line in lines:
		max_w = maxf(max_w, font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x)
	# 下移让开视口左上角编辑器自带的 "[Perspective]" 视图菜单/信息角标,留出间隔。
	var origin := Vector2(14.0, 48.0)
	var box := Rect2(origin, Vector2(max_w + pad * 2.0, line_h * float(lines.size()) + pad * 2.0))
	overlay.draw_rect(box, Color(0.06, 0.07, 0.09, 0.82))
	overlay.draw_rect(box, Color(1.0, 1.0, 1.0, 0.12), false, 1.0)
	var y := origin.y + pad + font.get_ascent(font_size)
	for line in lines:
		overlay.draw_string(font, Vector2(origin.x + pad, y), line, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.93, 0.95, 0.99))
		y += line_h


# ---- Brush toolbar button --------------------------------------------------

func _create_brush_toolbar_button() -> void:
	_brush_btn = Button.new()
	_brush_btn.flat = true
	_brush_btn.toggle_mode = true
	_brush_btn.button_pressed = true
	_brush_btn.text = " Brush "
	_brush_btn.tooltip_text = "Toggle brush painting (Shift+B)"
	_brush_btn.add_theme_font_size_override("font_size", 13)
	_brush_btn.toggled.connect(_on_brush_btn_toggled)
	_sync_brush_btn(true)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _brush_btn)
	_sync_brush_btn_visibility()


func _remove_brush_toolbar_button() -> void:
	if _brush_btn != null:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _brush_btn)
		_brush_btn.queue_free()
		_brush_btn = null


func _on_brush_btn_toggled(pressed: bool) -> void:
	_sync_brush_btn(pressed)
	var spa := _scene_spa_host()
	if spa != null:
		spa.set_volume_display(&"BrushSV", pressed)


func _sync_brush_btn(active: bool) -> void:
	if _brush_btn == null:
		return
	if _brush_btn.button_pressed != active:
		_brush_btn.set_pressed_no_signal(active)
	var bg := Color(0.15, 0.55, 0.25, 0.9) if active else Color(0.35, 0.15, 0.1, 0.9)
	var style := _make_flat_stylebox(bg, 4, 8.0, 4.0)
	_brush_btn.add_theme_color_override("font_color", Color(0.95, 0.95, 0.95) if active else Color(0.85, 0.7, 0.65))
	_brush_btn.add_theme_stylebox_override("normal", style)
	var hover := style.duplicate() as StyleBoxFlat
	hover.bg_color = style.bg_color.lightened(0.15)
	_brush_btn.add_theme_stylebox_override("hover", hover)
	var pressed_style := style.duplicate() as StyleBoxFlat
	pressed_style.bg_color = style.bg_color.darkened(0.1)
	_brush_btn.add_theme_stylebox_override("pressed", pressed_style)


func _sync_brush_btn_visibility() -> void:
	if _brush_btn == null:
		return
	var show_btn := _scene_spa_host() != null
	if _brush_btn.visible != show_btn:
		_brush_btn.visible = show_btn


func _scene_spa_host() -> ScenePlacementActor:
	var root := get_editor_interface().get_edited_scene_root()
	if root == null:
		return null
	var matches: Array[ScenePlacementActor] = []
	_collect_scene_placement_actors(root, matches)
	if matches.size() == 1:
		return matches[0]
	if matches.size() > 1:
		push_error("[MeshFill Plugin] placement scene must contain exactly one ScenePlacementActor")
	return null


func _collect_scene_placement_actors(node: Node, result: Array[ScenePlacementActor]) -> void:
	if node is ScenePlacementActor:
		result.append(node as ScenePlacementActor)
	for child in node.get_children():
		_collect_scene_placement_actors(child, result)


# ---- Asset descriptor geo scan toolbar ------------------------------------

func _create_geo_scan_toolbar() -> void:
	_import_all_fbx_btn = _make_toolbar_action_button(
		" Import All ",
		"Full rescan res://geo FBX files into the AssetOverview processing workbench"
	)
	_import_all_fbx_btn.name = "MeshFillImportAllFbxButton"
	_import_all_fbx_btn.custom_minimum_size = Vector2(96, 0)
	_import_all_fbx_btn.pressed.connect(_on_import_all_fbx_pressed)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _import_all_fbx_btn)

	_sync_geo_scan_toolbar_from_scene()


func _remove_geo_scan_toolbar() -> void:
	if _import_all_fbx_btn != null:
		_free_toolbar_control(_import_all_fbx_btn)
		_import_all_fbx_btn = null


func _on_import_all_fbx_pressed() -> void:
	var host := _scene_geo_scan_host()
	if host == null:
		push_warning("[MeshFill Editor] Current scene has no AssetOverview geo scan entry.")
		_sync_geo_scan_toolbar_from_scene()
		return
	var result = host.call(GEO_SCAN_METHOD, true)
	if result is Dictionary:
		var scene_summary := _format_geo_scan_toolbar_result(result)
		if host.has_method(GEO_SCAN_FORMAT_METHOD):
			scene_summary = str(host.call(GEO_SCAN_FORMAT_METHOD, result))
		print("[MeshFill Editor] Import All -> %s" % scene_summary)


func _sync_geo_scan_toolbar_from_scene() -> void:
	var host := _scene_geo_scan_host()
	var has_geo_scan := host != null
	if _import_all_fbx_btn != null:
		_import_all_fbx_btn.visible = has_geo_scan
		_import_all_fbx_btn.disabled = not has_geo_scan


func _format_geo_scan_toolbar_result(result: Dictionary) -> String:
	return "Geo: +%d upd%d skip%d total%d" % [
		int(result.get("added", 0)),
		int(result.get("updated", 0)),
		int(result.get("skipped", 0)),
		int(result.get("total", 0)),
	]


func _scene_geo_scan_host() -> Node:
	return _scene_root_host(GEO_SCAN_METHOD)


# ---- Asset descriptor debug toolbar ---------------------------------------

# ---- Asset descriptor bake toolbar ----------------------------------------
#
# One-click bake of the AssetDescriptor data for every mesh shown in the
# AssetOverview scene. Only visible when the edited scene exposes the
# bake entry (bake_scene_descriptors).

func _create_asset_descriptor_bake_toolbar() -> void:
	_bake_descriptor_btn = _make_toolbar_action_button(
		" Bake AD ",
		"Bake an AssetDescriptor (.tres) for every mesh displayed in the scene"
	)
	_bake_descriptor_btn.name = "MeshFillAssetDescriptorBakeButton"
	_bake_descriptor_btn.custom_minimum_size = Vector2(84, 0)
	_bake_descriptor_btn.pressed.connect(_on_bake_descriptor_pressed)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _bake_descriptor_btn)

	# Single-file FBX import uses the same Asset Overview service path as Import All.
	_import_fbx_btn = _make_toolbar_action_button(
		" Import FBX ",
		"Import one project FBX into the AssetOverview processing workbench"
	)
	_import_fbx_btn.name = "MeshFillImportFbxButton"
	_import_fbx_btn.custom_minimum_size = Vector2(96, 0)
	_import_fbx_btn.pressed.connect(_on_import_fbx_pressed)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _import_fbx_btn)

	_sync_asset_descriptor_bake_toolbar_from_scene()


func _remove_asset_descriptor_bake_toolbar() -> void:
	if _bake_descriptor_btn != null:
		_free_toolbar_control(_bake_descriptor_btn)
		_bake_descriptor_btn = null
	if _import_fbx_btn != null:
		_free_toolbar_control(_import_fbx_btn)
		_import_fbx_btn = null


func _on_bake_descriptor_pressed() -> void:
	var host := _scene_asset_descriptor_bake_host()
	if host == null:
		push_warning("[MeshFill Editor] Current scene has no AssetDescriptor bake entry.")
		_sync_asset_descriptor_bake_toolbar_from_scene()
		return
	var result = host.call(ASSET_DESCRIPTOR_BAKE_METHOD)
	if result is Dictionary:
		if not bool(result.get("ok", false)):
			push_warning("[MeshFill Editor] Bake AD: %s" % str(result.get("reason", "no descriptors baked")))
		print("[MeshFill Editor] Bake AD -> %s" % _format_asset_descriptor_bake_result(result))
	_refresh_volume_score_after_bake(result)


## Bake 之后刷新**所有已打开场景**里的 SPA，让新 descriptor 立刻进 registry / Arena。
##
## ⚠ 这推翻了原先「Bake 只产出 Authoring 产物，新版本一律由用户点 Reload 显式提交」的策略
## （用户 2026-08-13 决定）。范围仍然收得住：用组而不是全局注册表——组成员随节点进出树
## 自动增删，所以「组里有谁」恒等于「现在开着谁」。没打开的场景不碰，它下次打开时 SPA init
## 会自己从 Bake 目录加载。
##
## 之前这里只看 `_scene_spa_host()`（**当前编辑场景**里的 SPA），而 Bake AD 是在 Asset
## Overview 里点的，那个场景按项目规则不能挂 SPA ⇒ 这条刷新一直在空转。
func _refresh_volume_score_after_bake(result) -> void:
	if result is Dictionary and not bool(result.get("ok", false)):
		return
	var actors: Array = get_tree().get_nodes_in_group(SPAEditorContract.SPA_GROUP)
	# 兜底：当前编辑场景的 SPA 若因故不在组里（如尚未进树），显式并入，避免漏刷最相关的那个。
	var edited := _scene_spa_host()
	if edited != null and not actors.has(edited):
		actors.append(edited)
	if actors.is_empty():
		return
	var refreshed := 0
	for actor in actors:
		if actor == null or not is_instance_valid(actor) or not actor.has_method("refresh_volume_provider"):
			continue
		if bool(actor.call("refresh_volume_provider", &"VolumeScore").get("ok", false)):
			refreshed += 1
	if refreshed > 0:
		print("[MeshFill Editor] Bake AD -> refreshed %d open SPA volume-score provider(s)" % refreshed)


func _sync_asset_descriptor_bake_toolbar_from_scene() -> void:
	var host := _scene_asset_descriptor_bake_host()
	var has_host := host != null
	if _bake_descriptor_btn != null:
		_bake_descriptor_btn.visible = has_host
		_bake_descriptor_btn.disabled = not has_host
	if _import_fbx_btn != null:
		var fbx_host := _scene_import_fbx_host()
		_import_fbx_btn.visible = fbx_host != null
		_import_fbx_btn.disabled = fbx_host == null


func _scene_asset_descriptor_bake_host() -> Node:
	return _scene_root_host(ASSET_DESCRIPTOR_BAKE_METHOD)


func _scene_import_fbx_host() -> Node:
	return _scene_root_host(IMPORT_FBX_METHOD)


# Import FBX asks Asset Overview to open its project-resource file dialog. The
# selected file is processed by the same GeoAssetScanService path as Import All.
func _on_import_fbx_pressed() -> void:
	var host := _scene_import_fbx_host()
	if host == null:
		push_warning("[MeshFill Editor] Current scene has no single FBX import entry.")
		_sync_asset_descriptor_bake_toolbar_from_scene()
		return
	var result = host.call(IMPORT_FBX_METHOD)
	if result is Dictionary and not bool(result.get("ok", false)):
		push_warning("[MeshFill Editor] Import FBX: %s" % str(result.get("reason", "unavailable")))
	print("[MeshFill Editor] Import FBX -> %s" % host.name)


func _format_asset_descriptor_bake_result(result: Dictionary) -> String:
	return "Bake AD: baked=%d failed=%d total=%d" % [
		int(result.get("baked", 0)),
		int(result.get("failed", 0)),
		int(result.get("total", 0)),
	]


# ---- TargetSV reimport toolbar --------------------------------------------
#
# 外部烘焙器（Houdini）重新导出 res://assets/target_sv/ 之后，让当前场景的 SPA 把
# TargetSV 整块重读。按钮而不是 Inspector 项，是因为 Volumes/TargetSV 是 SPA 在
# _ensure_owned_tree() 里 add_child 出来的、没设 owner——场景面板里选不中它。
# 可见性因此跟 Brush 按钮一样挂在 _scene_spa_host() 上，而不是 _scene_root_host()。

func _create_targetsv_toolbar() -> void:
	_reimport_targetsv_btn = _make_toolbar_action_button(
		" Reimport TargetSV ",
		"Reload TargetSV from res://assets/target_sv/ (after an external re-export).\nRebuilds the brush and clears BrushSV."
	)
	_reimport_targetsv_btn.name = "MeshFillReimportTargetSVButton"
	_reimport_targetsv_btn.custom_minimum_size = Vector2(132, 0)
	_reimport_targetsv_btn.pressed.connect(_on_reimport_targetsv_pressed)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _reimport_targetsv_btn)

	_sync_targetsv_toolbar_from_scene()


func _remove_targetsv_toolbar() -> void:
	if _reimport_targetsv_btn != null:
		_free_toolbar_control(_reimport_targetsv_btn)
		_reimport_targetsv_btn = null
	if _targetsv_import_dialog != null and is_instance_valid(_targetsv_import_dialog):
		_targetsv_import_dialog.queue_free()
	_targetsv_import_dialog = null


## 弹文件对话框选一份 TargetSV 元数据 json。选中当前这一份（assets/target_sv 里的那个）
## 等价于"就地重新加载"——import_dataset 的 same_dataset 分支会跳过自我复制。
func _on_reimport_targetsv_pressed() -> void:
	if _scene_spa_host() == null:
		push_warning("[MeshFill Editor] Current scene has no ScenePlacementActor.")
		_sync_targetsv_toolbar_from_scene()
		return
	_ensure_targetsv_import_dialog()
	if _targetsv_import_dialog == null:
		push_warning("[MeshFill Editor] Reimport TargetSV: editor file dialog unavailable")
		return
	_targetsv_import_dialog.current_dir = TargetSVLoader.SHARED_DIR
	_targetsv_import_dialog.popup_file_dialog()


func _ensure_targetsv_import_dialog() -> void:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	if _targetsv_import_dialog != null and is_instance_valid(_targetsv_import_dialog):
		return
	var base := EditorInterface.get_base_control()
	if base == null:
		_targetsv_import_dialog = null
		return
	# 软重载会丢引用但对话框结点还挂在 base 下，按名字先认领回来，别越堆越多。
	var existing := base.get_node_or_null(NodePath(TARGETSV_DIALOG_NAME)) as EditorFileDialog
	if existing != null:
		_targetsv_import_dialog = existing
		if not existing.file_selected.is_connected(_on_targetsv_metadata_selected):
			existing.file_selected.connect(_on_targetsv_metadata_selected)
		return
	var dialog := EditorFileDialog.new()
	dialog.name = TARGETSV_DIALOG_NAME
	# 标题与确认按钮就是这次导入的"确认关"——它会覆盖 assets/target_sv 里现有的数据集。
	dialog.title = "Import TargetSV — overwrites %s" % TargetSVLoader.SHARED_DIR
	dialog.ok_button_text = "Import & Overwrite"
	dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	dialog.access = EditorFileDialog.ACCESS_RESOURCES
	dialog.clear_filters()
	dialog.add_filter("*.fbx, *.FBX", "TargetSV voxel FBX (one triangle per voxel)")
	dialog.add_filter("*.json", "TargetSV metadata (already-converted dataset)")
	dialog.file_selected.connect(_on_targetsv_metadata_selected)
	base.add_child(dialog)
	_targetsv_import_dialog = dialog


## 按扩展名分路：FBX 走三角形体素化（每个三角形一个体素，通道规则同 asset overview），
## json 走"换一份已经转换好的数据集"。两条最后都汇到同一次 TargetSV 重导入。
func _on_targetsv_metadata_selected(metadata_path: String) -> void:
	# 对话框是非模态的，选文件期间场景可能已经换掉，宿主要重新解析一次。
	var spa := _scene_spa_host()
	if spa == null:
		push_warning("[MeshFill Editor] Reimport TargetSV: scene no longer has a ScenePlacementActor.")
		return
	var extension := metadata_path.get_extension().to_lower()
	var result: Dictionary
	if extension == "fbx":
		result = spa.import_target_sv_from_fbx(metadata_path)
		# written 是 FBX 那条路自己写出的四个文件，与 json 路的 copied 同样要交还资源系统。
		_reimport_copied_resources(result.get("written", PackedStringArray()))
	else:
		result = spa.import_target_sv_dataset(metadata_path)
	# copied 只有搬运真的发生过才有：失败在搬运之前时它是 null，这里照样要报警不要静默。
	_reimport_copied_resources(result.get("copied", PackedStringArray()))
	if not bool(result.get("ok", false)):
		push_warning("[MeshFill Editor] Reimport TargetSV: %s (%s)" % [
			str(result.get("reason", "unknown")), metadata_path])
		return
	var route_summary := _format_targetsv_bake_result(result) if extension == "fbx" \
		else "replaced: %s" % _format_replaced_dataset(result.get("replaced", []))
	print("[MeshFill Editor] Reimport TargetSV <- %s%s\n  %s\n  %s" % [
		metadata_path,
		"  (same dataset, reloaded in place)" if bool(result.get("same_dataset", false)) else "",
		route_summary,
		_format_targetsv_reimport_result(result),
	])


## FBX 那条路的验收数字。第一行是**三角形去哪了**这条链：读到多少 → 落格多少 → 占了多少个
## **不同**体素。源是"一面一格"，所以 binned 与 distinct 的差就是被合并掉的量，网格分辨率够
## 不够只看这一个比值。第二行那几道原来的门禁现在只计数不丢弃，留着是给"这份 FBX 烘对没有"
## 当第一现场。第三行的 capture/span/flip_z 判尺度与轴向。
func _format_targetsv_bake_result(result: Dictionary) -> String:
	var timings: Dictionary = result.get("timings_ms", {})
	var binned := int(result.get("used_triangle_count", 0))
	var distinct := int(result.get("distinct_voxel_count", 0))
	var merge_ratio := float(binned) / float(distinct) if distinct > 0 else 0.0
	return "baked: read %d tris -> %d binned -> %d distinct voxels (%.2f tris/voxel merged), non-empty %d\n  counted (not filtered): fine-gate %d, degenerate %d, no-Cd %d, uv-uncovered %d, below-terrain %d, height-clipped %d | dropped (unbinnable): %d\n  frame: capture %.3f, vertical_span %.3f, flip_z %s, source_bounds %s\n  time: read %d ms + bin %d ms + write %d ms" % [
		int(result.get("read_triangle_count", 0)),
		binned,
		distinct,
		merge_ratio,
		int(result.get("non_empty_voxel_count", 0)),
		int(result.get("triangle_count", 0)),
		int(result.get("degenerate_triangle_count", 0)),
		int(result.get("missing_payload_count", 0)),
		int(result.get("rejected_triangle_count", 0)),
		int(result.get("below_terrain_count", 0)),
		int(result.get("clipped_height_count", 0)),
		int(result.get("dropped_out_of_bounds", 0)),
		float(result.get("capture_size", 0.0)),
		float(result.get("vertical_span", 0.0)),
		str(result.get("flip_z", true)),
		str(result.get("source_bounds", [])),
		int(timings.get("read", 0)),
		int(timings.get("bin", 0)),
		int(timings.get("write", 0)),
	]


## 复制进来的 preview png 是**已导入资源**：不告诉资源系统，它的 .import 仍指向旧 .ctex。
## .json/.rgba8/.r8 是 FileAccess 直读、不经导入，update_file 只为让文件系统面板同步。
func _reimport_copied_resources(copied) -> void:
	var fs := EditorInterface.get_resource_filesystem()
	if fs == null or not (copied is PackedStringArray or copied is Array):
		return
	var needs_reimport := PackedStringArray()
	for path in copied:
		fs.update_file(str(path))
		if str(path).get_extension().to_lower() == "png":
			needs_reimport.append(str(path))
	if not needs_reimport.is_empty():
		fs.reimport_files(needs_reimport)


func _format_replaced_dataset(replaced) -> String:
	if not (replaced is Array) or (replaced as Array).is_empty():
		return "(nothing — target folder was empty)"
	var parts := PackedStringArray()
	for entry in replaced:
		parts.append("%s %d B" % [str(entry.get("path", "?")).get_file(), int(entry.get("bytes", 0))])
	return ", ".join(parts)


func _format_targetsv_reimport_result(result: Dictionary) -> String:
	return "grid=%s voxels=%d rev=%d display=%s brush_sv_cleared=%s" % [
		str(result.get("grid_size", Vector3i.ZERO)),
		int(result.get("voxel_count", 0)),
		int(result.get("content_revision", 0)),
		str(result.get("display_reason", "?")),
		str(result.get("brush_sv_cleared", false)),
	]


func _sync_targetsv_toolbar_from_scene() -> void:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	if _reimport_targetsv_btn == null:
		return
	var has_spa := _scene_spa_host() != null
	_reimport_targetsv_btn.visible = has_spa
	_reimport_targetsv_btn.disabled = not has_spa


func _make_toolbar_action_button(label: String, tooltip: String) -> Button:
	var btn := Button.new()
	btn.flat = true
	btn.text = label
	btn.tooltip_text = tooltip
	btn.add_theme_font_size_override("font_size", 13)
	btn.custom_minimum_size = Vector2(78, 0)
	return btn


# Shared toolbar teardown: detach the control from the spatial-editor menu and
# free it. Callers null out their own member reference afterward.
func _free_toolbar_control(control: Control) -> void:
	remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, control)
	control.queue_free()


# Shared StyleBoxFlat factory for the brush toggle.
func _make_flat_stylebox(bg: Color, corner: int, margin_h: float, margin_v: float, border_color := Color(), border_width := 0) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	if border_width > 0:
		style.border_color = border_color
		style.set_border_width_all(border_width)
	style.set_corner_radius_all(corner)
	style.content_margin_left = margin_h
	style.content_margin_right = margin_h
	style.content_margin_top = margin_v
	style.content_margin_bottom = margin_v
	return style


# Shared edited-scene-root host lookup: the root is the host iff it exposes the
# requested entry method. _scene_spa_host (find_child variant) is intentionally
# different — do not fold it in.
func _scene_root_host(method_name: StringName) -> Node:
	var root := get_editor_interface().get_edited_scene_root()
	if root != null and root.has_method(method_name):
		return root
	return null


# ---- TCP Server ------------------------------------------------------------

func _try_bind_tcp() -> bool:
	_tcp_server = TCPServer.new()
	var err := _tcp_server.listen(MCP_PORT, "127.0.0.1")
	if err == OK:
		print("[MeshFill MCP] TCP listening on 127.0.0.1:%d" % MCP_PORT)
		return true
	_tcp_server.stop()
	_tcp_server = null
	return false


func _stop_tcp_server() -> void:
	if _tcp_server:
		_tcp_server.stop()
		_tcp_server = null
	for p in _tcp_peers:
		(p as StreamPeerTCP).disconnect_from_host()
	_tcp_peers.clear()
	_peer_buffers.clear()


func _try_bind_single_instance_port() -> bool:
	_instance_server = TCPServer.new()
	var err := _instance_server.listen(SINGLE_INSTANCE_PORT, "127.0.0.1")
	if err == OK:
		print("[SingleInstance] Guard listening on 127.0.0.1:%d" % SINGLE_INSTANCE_PORT)
		return true
	_instance_server.stop()
	_instance_server = null
	return false


func _stop_single_instance_port() -> void:
	if _instance_server:
		_instance_server.stop()
		_instance_server = null


func _poll_single_instance_port() -> void:
	if _instance_server == null:
		return
	while _instance_server.is_connection_available():
		var peer := _instance_server.take_connection()
		if peer != null:
			peer.put_data((JSON.stringify({
				"status": "owned",
				"pid": OS.get_process_id(),
				"project": _project_key,
				"mcp_port": MCP_PORT
			}) + "\n").to_utf8_buffer())
			peer.disconnect_from_host()


func _poll_tcp() -> void:
	if _tcp_server == null:
		return
	while _tcp_server.is_connection_available():
		var peer := _tcp_server.take_connection()
		_tcp_peers.append(peer)
		_peer_buffers[peer.get_instance_id()] = ""
		print("[MeshFill MCP] Client connected")

	var to_remove: Array[int] = []
	for i in range(_tcp_peers.size()):
		var peer: StreamPeerTCP = _tcp_peers[i]
		peer.poll()
		match peer.get_status():
			StreamPeerTCP.STATUS_CONNECTED:
				var avail := peer.get_available_bytes()
				if avail > 0:
					var data := peer.get_utf8_string(avail)
					var pid := peer.get_instance_id()
					_peer_buffers[pid] = _peer_buffers.get(pid, "") + data
					_drain_buffer(peer)
			StreamPeerTCP.STATUS_NONE, StreamPeerTCP.STATUS_ERROR:
				to_remove.append(i)

	for idx in range(to_remove.size() - 1, -1, -1):
		var peer: StreamPeerTCP = _tcp_peers[to_remove[idx]]
		_peer_buffers.erase(peer.get_instance_id())
		_tcp_peers.remove_at(to_remove[idx])


func _drain_buffer(peer: StreamPeerTCP) -> void:
	var pid := peer.get_instance_id()
	var buf: String = _peer_buffers.get(pid, "")
	while true:
		var nl := buf.find("\n")
		if nl < 0:
			break
		var line := buf.substr(0, nl).strip_edges()
		buf = buf.substr(nl + 1)
		if line.is_empty():
			continue
		var json := JSON.new()
		if json.parse(line) == OK:
			var resp := _dispatch(json.data as Dictionary)
			peer.put_data((JSON.stringify(resp) + "\n").to_utf8_buffer())
		else:
			peer.put_data((JSON.stringify({
				"id": null, "error": json.get_error_message()}) + "\n").to_utf8_buffer())
	_peer_buffers[pid] = buf


# ---- Command dispatch ------------------------------------------------------

func _dispatch(req: Dictionary) -> Dictionary:
	var rid = req.get("id")
	var method: String = str(req.get("method", ""))
	var params: Dictionary = req.get("params", {}) if req.has("params") else {}

	var result: Dictionary
	match method:
		"ping":
			result = {"status": "ok", "engine": "godot",
				"version": Engine.get_version_info().get("string", "?")}
		"get_scene_tree":
			result = _cmd_get_scene_tree(params)
		"select_node":
			result = _cmd_select_node(params)
		"deselect_all":
			result = _cmd_deselect_all()
		"get_selection":
			result = _cmd_get_selection()
		"get_node_info":
			result = _cmd_get_node_info(params)
		"set_node_property":
			result = _cmd_set_node_property(params)
		"move_node":
			result = _cmd_move_node(params)
		"get_children":
			result = _cmd_get_children(params)
		"call_method":
			result = _cmd_call_method(params)
		"get_open_scene":
			result = _cmd_get_open_scene()
		"open_scene":
			result = _cmd_open_scene(params)
		"screenshot":
			result = _cmd_screenshot(params)
		"capture_camera":
			result = _cmd_capture_camera(params)
		_:
			return {"id": rid, "error": "unknown method: %s" % method}

	return {"id": rid, "result": result}


# ---- Commands --------------------------------------------------------------

func _cmd_get_scene_tree(params: Dictionary) -> Dictionary:
	var root := get_editor_interface().get_edited_scene_root()
	if root == null:
		return {"error": "no scene open"}
	var max_depth: int = int(params.get("max_depth", 4))
	return {"tree": _node_tree(root, 0, max_depth)}


func _node_tree(node: Node, depth: int, max_depth: int) -> Dictionary:
	var d: Dictionary = {
		"name": node.name,
		"type": node.get_class(),
		"path": str(node.get_path()),
	}
	if node is Node3D:
		var p: Vector3 = (node as Node3D).position
		d["pos"] = [roundf(p.x * 100.0) * 0.01, roundf(p.y * 100.0) * 0.01, roundf(p.z * 100.0) * 0.01]
	if node.get_script():
		d["script"] = str(node.get_script().resource_path)
	if depth < max_depth:
		var ch: Array = []
		for c in node.get_children():
			ch.append(_node_tree(c, depth + 1, max_depth))
		if ch.size() > 0:
			d["children"] = ch
	return d


func _resolve_edited_scene_node(path: String) -> Node:
	var root := get_editor_interface().get_edited_scene_root()
	if root == null:
		return null
	var root_name := str(root.name)
	var normalized := path.strip_edges()
	if normalized.is_empty() or normalized == ".":
		return root
	if normalized == root_name:
		return root
	if normalized.begins_with("%s/" % root_name):
		normalized = normalized.substr(root_name.length() + 1)
		if normalized.is_empty():
			return root
	if normalized.begins_with("./"):
		normalized = normalized.substr(2)
		if normalized.is_empty():
			return root
	var node: Node
	if normalized.begins_with("/"):
		node = root.get_tree().root.get_node_or_null(NodePath(normalized))
	else:
		node = root.get_node_or_null(NodePath(normalized))
	if node == root:
		return node
	if node != null and root.is_ancestor_of(node):
		return node
	return null


func _cmd_select_node(params: Dictionary) -> Dictionary:
	var path: String = str(params.get("path", ""))
	if path.is_empty():
		return {"error": "missing 'path'"}
	var root := get_editor_interface().get_edited_scene_root()
	if root == null:
		return {"error": "no scene open"}
	# An editor scene root becomes observable one frame before every @tool child
	# has necessarily finished its deferred setup. The validation is idempotent
	# and guarantees bridge-driven placement commands see the resident SPA.
	_validate_scene(root)
	var node := _resolve_edited_scene_node(path)
	if node == null:
		return {"error": "node not found: %s" % path}
	var sel := get_editor_interface().get_selection()
	sel.clear()
	sel.add_node(node)
	return {"ok": true, "selected": str(node.get_path())}


func _cmd_deselect_all() -> Dictionary:
	get_editor_interface().get_selection().clear()
	return {"ok": true}


func _cmd_get_selection() -> Dictionary:
	var nodes := get_editor_interface().get_selection().get_selected_nodes()
	var paths: Array = []
	for n in nodes:
		paths.append(str(n.get_path()))
	return {"selected": paths, "count": paths.size()}


func _cmd_get_node_info(params: Dictionary) -> Dictionary:
	var path: String = str(params.get("path", ""))
	var root := get_editor_interface().get_edited_scene_root()
	if root == null:
		return {"error": "no scene open"}
	var node := _resolve_edited_scene_node(path)
	if node == null:
		return {"error": "node not found"}
	var info: Dictionary = {
		"name": node.name, "type": node.get_class(),
		"path": str(node.get_path()),
		"child_count": node.get_child_count(),
	}
	if node is Node3D:
		var n3 := node as Node3D
		info["position"] = [n3.position.x, n3.position.y, n3.position.z]
		info["rotation_deg"] = [rad_to_deg(n3.rotation.x),
			rad_to_deg(n3.rotation.y), rad_to_deg(n3.rotation.z)]
		info["scale"] = [n3.scale.x, n3.scale.y, n3.scale.z]
	if node is MeshInstance3D:
		info["has_mesh"] = (node as MeshInstance3D).mesh != null
	if node.get_script():
		info["script"] = str(node.get_script().resource_path)
	var meta_keys := node.get_meta_list()
	if meta_keys.size() > 0:
		var md: Dictionary = {}
		for k in meta_keys:
			md[k] = str(node.get_meta(k))
		info["metadata"] = md
	return info


func _cmd_set_node_property(params: Dictionary) -> Dictionary:
	var path: String = str(params.get("path", ""))
	var prop: String = str(params.get("property", ""))
	var value = params.get("value")
	if prop.is_empty():
		return {"error": "missing 'property'"}
	var root := get_editor_interface().get_edited_scene_root()
	if root == null:
		return {"error": "no scene open"}
	var node := _resolve_edited_scene_node(path)
	if node == null:
		return {"error": "node not found"}
	if prop == "position" and node is Node3D and value is Array:
		(node as Node3D).position = Vector3(value[0], value[1], value[2])
	elif prop == "rotation" and node is Node3D and value is Array:
		(node as Node3D).rotation = Vector3(value[0], value[1], value[2])
	elif prop == "scale" and node is Node3D and value is Array:
		(node as Node3D).scale = Vector3(value[0], value[1], value[2])
	else:
		node.set(prop, value)
	return {"ok": true}


func _cmd_move_node(params: Dictionary) -> Dictionary:
	var path: String = str(params.get("path", ""))
	var pos: Array = params.get("position", []) if params.has("position") else []
	if pos.size() < 3:
		return {"error": "missing 'position' [x,y,z]"}
	var root := get_editor_interface().get_edited_scene_root()
	if root == null:
		return {"error": "no scene open"}
	var node := _resolve_edited_scene_node(path)
	if node == null or not node is Node3D:
		return {"error": "node not found or not Node3D"}
	(node as Node3D).position = Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
	return {"ok": true, "position": pos}


func _cmd_get_children(params: Dictionary) -> Dictionary:
	var path: String = str(params.get("path", ""))
	var root := get_editor_interface().get_edited_scene_root()
	if root == null:
		return {"error": "no scene open"}
	var node := _resolve_edited_scene_node(path)
	if node == null:
		return {"error": "node not found"}
	var ch: Array = []
	for c in node.get_children():
		var info: Dictionary = {"name": c.name, "type": c.get_class()}
		if c is Node3D:
			var p: Vector3 = (c as Node3D).position
			info["pos"] = [roundf(p.x * 100.0) * 0.01, roundf(p.y * 100.0) * 0.01, roundf(p.z * 100.0) * 0.01]
		ch.append(info)
	return {"children": ch, "count": ch.size()}


func _cmd_call_method(params: Dictionary) -> Dictionary:
	var path: String = str(params.get("path", ""))
	var method_name: String = str(params.get("method", ""))
	var args: Array = params.get("args", []) if params.has("args") else []
	if method_name.is_empty():
		return {"error": "missing 'method'"}
	var root := get_editor_interface().get_edited_scene_root()
	if root == null:
		return {"error": "no scene open"}
	var node := _resolve_edited_scene_node(path)
	if node == null:
		return {"error": "node not found"}
	if not node.has_method(method_name):
		return {"error": "method not found: %s" % method_name}
	var result = node.callv(method_name, args)
	return {"ok": true, "return": str(result) if result != null else null}


func _cmd_get_open_scene() -> Dictionary:
	var root := get_editor_interface().get_edited_scene_root()
	if root == null:
		return {"scene": null}
	return {
		"scene": root.scene_file_path,
		"root_name": root.name,
		"root_type": root.get_class(),
	}


func _cmd_open_scene(params: Dictionary) -> Dictionary:
	var scene_path: String = str(params.get("path", ""))
	if scene_path.is_empty():
		return {"error": "missing 'path' param"}
	get_editor_interface().open_scene_from_path(scene_path)
	var root := get_editor_interface().get_edited_scene_root()
	return {
		"ok": true,
		"scene": root.scene_file_path if root else null,
		"root_name": root.name if root else null,
	}


## Capture the editor 3D viewport (the edited scene's viewport) to a PNG file and
## return its absolute path so external tooling can read the image directly.
func _cmd_screenshot(params: Dictionary) -> Dictionary:
	var ei := get_editor_interface()
	# 必须用 3D 编辑器视口；edited_scene_root.get_viewport() 是 2x2 占位视口。
	ei.set_main_screen_editor("3D")
	var viewport: Viewport = ei.get_editor_viewport_3d(0)
	if viewport == null:
		var root := ei.get_edited_scene_root()
		viewport = root.get_viewport() if root != null else null
	if viewport == null or viewport.get_texture() == null:
		return {"error": "no viewport texture"}
	var img: Image = viewport.get_texture().get_image()
	if img == null:
		return {"error": "no viewport image"}
	var req_path: String = str(params.get("path", "res://_shots/mcp_screenshot.png"))
	var abs_path := req_path
	if req_path.begins_with("res://") or req_path.begins_with("user://"):
		abs_path = ProjectSettings.globalize_path(req_path)
	DirAccess.make_dir_recursive_absolute(abs_path.get_base_dir())
	var err := img.save_png(abs_path)
	if err != OK:
		return {"error": "save_png failed: %d" % err}
	return {
		"ok": true,
		"path": abs_path,
		"width": img.get_width(),
		"height": img.get_height(),
	}


## Render the edited scene from an arbitrary camera pose into an off-screen
## SubViewport (sharing the editor's World3D) and save a PNG. Lets external
## tooling frame a specific spot the editor viewport camera can't be aimed at.
## params: pos [x,y,z], look_at [x,y,z], fov, width, height, path.
func _cmd_capture_camera(params: Dictionary) -> Dictionary:
	var root := get_editor_interface().get_edited_scene_root()
	if root == null:
		return {"error": "no scene open"}
	# Prefer the EDITED SCENE's own world: the 3D editor viewport's world_3d can
	# belong to another scene tab (whichever last owned the 3D main screen), which
	# silently renders the wrong scene from a stale camera pose.
	var world: World3D = (root as Node3D).get_world_3d() if root is Node3D else null
	if world == null:
		var evp: Viewport = get_editor_interface().get_editor_viewport_3d(0)
		world = evp.world_3d if evp != null else null
	if world == null:
		return {"error": "no world3d"}
	var w: int = int(params.get("width", 1440))
	var h: int = int(params.get("height", 900))
	var sub := SubViewport.new()
	sub.size = Vector2i(w, h)
	sub.world_3d = world
	sub.own_world_3d = false
	sub.transparent_bg = false
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sub.msaa_3d = Viewport.MSAA_4X
	# Pose the camera with an explicit transform BEFORE it enters the tree:
	# post-add global_position + look_at proved unreliable here (captures came
	# back byte-identical from a stale/recycled render target regardless of the
	# requested pose), and look_at is a silent no-op for straight-down poses.
	var p: Array = params.get("pos", [0, 400, 600])
	var l: Array = params.get("look_at", [0, 40, 0])
	var cam_origin := Vector3(float(p[0]), float(p[1]), float(p[2]))
	var look_target := Vector3(float(l[0]), float(l[1]), float(l[2]))
	var look_dir := look_target - cam_origin
	if look_dir.length_squared() < 0.000001:
		look_dir = Vector3(0.0, 0.0, -1.0)
	var look_up := Vector3.UP if absf(look_dir.normalized().dot(Vector3.UP)) < 0.99 else Vector3.FORWARD
	var cam := Camera3D.new()
	cam.transform = Transform3D(Basis.looking_at(look_dir, look_up), cam_origin)
	cam.fov = float(params.get("fov", 60.0))
	cam.far = 8000.0
	sub.add_child(cam)
	get_editor_interface().get_base_control().add_child(sub)
	cam.make_current()
	# Synchronous render: force full draws so the fresh SubViewport rasterizes.
	for _i in range(4):
		RenderingServer.force_draw(false)
	var tex := sub.get_texture()
	var img: Image = tex.get_image() if tex != null else null
	var out: Dictionary
	if img == null:
		out = {"error": "no image from subviewport"}
	else:
		var req_path: String = str(params.get("path", "res://_shots/cam_capture.png"))
		var abs_path := ProjectSettings.globalize_path(req_path) if req_path.begins_with("res://") or req_path.begins_with("user://") else req_path
		DirAccess.make_dir_recursive_absolute(abs_path.get_base_dir())
		var err := img.save_png(abs_path)
		out = {"ok": true, "path": abs_path, "width": img.get_width(), "height": img.get_height()} if err == OK else {"error": "save_png failed: %d" % err}
	sub.queue_free()
	return out


# ---- Single-instance guard ----

func _mark_duplicate_and_quit(reason: String) -> void:
	_duplicate_instance = true
	_duplicate_reason = reason
	set_process(false)
	_stop_tcp_server()
	_stop_single_instance_port()
	_release_lock()
	push_error("[SingleInstance] Duplicate editor blocked: %s" % reason)
	call_deferred("_force_quit_duplicate", reason)


func _force_quit_duplicate(reason: String = "") -> void:
	var msg := "[SingleInstance] FATAL: Another Godot editor is already running this project. This instance will now terminate."
	if not reason.strip_edges().is_empty():
		msg += "\n\nReason: %s" % reason
	push_error(msg)
	printerr(msg)
	OS.alert(msg, "MeshFill: Duplicate Editor Blocked")
	get_tree().quit(1)


# ---- Documentation file import cleanup (.svg / .md) ----

const _JUNK_IMPORT_EXTENSIONS := [".svg.import", ".md.import", ".png.import"]
const _JUNK_IMPORT_DIRS := ["res://demos", "res://_shots"]

func _cleanup_doc_import_files() -> void:
	var removed := 0
	for scan_dir in _JUNK_IMPORT_DIRS:
		removed += _remove_junk_imports_in(scan_dir)
	if removed > 0:
		print("[MeshFill Editor] Removed %d junk .import files (.svg/.md/.png/screenshots)" % removed)


func _remove_junk_imports_in(scan_path: String) -> int:
	var removed := 0
	var dir := DirAccess.open(scan_path)
	if dir == null:
		return 0
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := scan_path.path_join(entry)
		if dir.current_is_dir():
			if entry != "." and entry != "..":
				removed += _remove_junk_imports_in(full)
		else:
			var dominated := false
			for ext in _JUNK_IMPORT_EXTENSIONS:
				if entry.ends_with(ext):
					dominated = true
					break
			if not dominated and scan_path == "res://_shots" and entry.ends_with(".import"):
				dominated = true
			if dominated:
				DirAccess.remove_absolute(ProjectSettings.globalize_path(full))
				removed += 1
		entry = dir.get_next()
	dir.list_dir_end()
	return removed


func _acquire_single_instance_lock() -> bool:
	var my_pid := OS.get_process_id()
	var existing := _read_lock()
	if _lock_represents_live_editor(existing):
		_duplicate_reason = _format_existing_lock_reason(existing)
		print("[SingleInstance] Blocked: %s" % _duplicate_reason)
		return false
	if not existing.is_empty():
		print("[SingleInstance] Reclaiming stale lock: %s" % _format_existing_lock_reason(existing))
	if not _write_lock(my_pid):
		_duplicate_reason = "Could not write lock file: %s" % LOCK_FILE
		return false
	var verify := _read_lock()
	if not _lock_matches_current_instance(verify):
		_duplicate_reason = "Lock ownership verification failed after write."
		return false
	_lock_held = true
	print("[SingleInstance] Lock acquired (PID %d, token %s)" % [my_pid, _instance_token])
	return true


func _write_lock(pid: int) -> bool:
	var file := FileAccess.open(LOCK_FILE, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(_make_lock_payload(pid), "\t"))
	file.close()
	return true


func _write_heartbeat() -> void:
	if not _lock_held:
		return
	var current := _read_lock()
	if not _lock_matches_current_instance(current):
		_lock_held = false
		_mark_duplicate_and_quit("Single-instance lock ownership was lost.")
		return
	if not _write_lock(OS.get_process_id()):
		_lock_held = false
		_mark_duplicate_and_quit("Could not update single-instance heartbeat.")


func _release_lock() -> void:
	if not _lock_held:
		return
	var lock_path := ProjectSettings.globalize_path(LOCK_FILE)
	var current := _read_lock()
	if FileAccess.file_exists(LOCK_FILE) and _lock_matches_current_instance(current):
		DirAccess.remove_absolute(lock_path)
		print("[SingleInstance] Lock released (PID %d)" % OS.get_process_id())
	elif FileAccess.file_exists(LOCK_FILE):
		print("[SingleInstance] Lock not released because ownership no longer matches this instance.")
	_lock_held = false


func _ensure_instance_identity() -> void:
	if not _project_key.is_empty() and not _instance_token.is_empty():
		return
	_project_key = ProjectSettings.globalize_path("res://").simplify_path()
	_instance_token = "%d:%d:%d" % [OS.get_process_id(), Time.get_ticks_msec(), _project_key.hash()]


func _make_lock_payload(pid: int) -> Dictionary:
	return {
		"format": 2,
		"pid": pid,
		"heartbeat": Time.get_unix_time_from_system(),
		"project": _project_key,
		"token": _instance_token,
		"single_instance_port": SINGLE_INSTANCE_PORT,
		"mcp_port": MCP_PORT,
		"engine": str(Engine.get_version_info().get("string", "?"))
	}


func _read_lock() -> Dictionary:
	if not FileAccess.file_exists(LOCK_FILE):
		return {}
	var file := FileAccess.open(LOCK_FILE, FileAccess.READ)
	if file == null:
		return {"read_error": true}
	var content := file.get_as_text().strip_edges()
	file.close()
	if content.is_empty():
		return {}
	var parsed = JSON.parse_string(content)
	if parsed is Dictionary:
		return parsed
	return _read_legacy_lock(content)


func _read_legacy_lock(content: String) -> Dictionary:
	var parts := content.split("\n")
	return {
		"format": 1,
		"pid": parts[0].to_int() if parts.size() > 0 else 0,
		"heartbeat": parts[1].to_float() if parts.size() > 1 else 0.0,
		"project": "",
		"token": "",
		"legacy": true
	}


func _lock_represents_live_editor(data: Dictionary) -> bool:
	if data.is_empty():
		return false
	if data.has("read_error"):
		return true
	var pid := int(data.get("pid", 0))
	var token := str(data.get("token", ""))
	if pid == OS.get_process_id():
		return false
	var heartbeat := float(data.get("heartbeat", 0.0))
	var age := Time.get_unix_time_from_system() - heartbeat
	if heartbeat > 0.0 and age >= 0.0 and age < HEARTBEAT_STALE_SEC and token != _instance_token:
		return true
	# Heartbeat is stale. The PID fallback exists for an editor whose main
	# thread is blocked >15s (long import/GPU work), but the OS recycles dead
	# PIDs onto unrelated processes — only a PID that is still a *Godot*
	# process may keep the lock, else launches stay blocked forever.
	if pid > 0 and _is_godot_pid_alive(pid):
		return true
	return false


func _lock_matches_current_instance(data: Dictionary) -> bool:
	if data.is_empty():
		return false
	return int(data.get("pid", 0)) == OS.get_process_id() \
		and str(data.get("token", "")) == _instance_token \
		and str(data.get("project", "")) == _project_key


func _format_existing_lock_reason(data: Dictionary) -> String:
	if data.is_empty():
		return "empty lock"
	if data.has("read_error"):
		return "existing lock file could not be read"
	var heartbeat := float(data.get("heartbeat", 0.0))
	var age := Time.get_unix_time_from_system() - heartbeat if heartbeat > 0.0 else -1.0
	var age_text := "%.1fs ago" % age if age >= 0.0 else "unknown age"
	var project := str(data.get("project", "unknown project"))
	if project.is_empty():
		project = "legacy lock"
	return "PID %d, heartbeat %s, project %s" % [int(data.get("pid", 0)), age_text, project]


func _is_godot_pid_alive(pid: int) -> bool:
	return _process_image_name(pid).to_lower().begins_with("godot")


## 返回 pid 对应进程的镜像名；进程不存在返回 ""。PID 必须整字段精确匹配，
## 避免旧版 find(str(pid)) 把内存数值/其他字段里的数字串误判为存活。
func _process_image_name(pid: int) -> String:
	var output: Array = []
	if OS.get_name() == "Windows":
		OS.execute("tasklist", PackedStringArray(["/FI", "PID eq %d" % pid, "/FO", "CSV", "/NH"]), output)
		if output.is_empty():
			return ""
		for raw_line in str(output[0]).split("\n"):
			var line := raw_line.strip_edges()
			# 匹配行形如 "image.exe","1234",...；无匹配时 tasklist 输出 INFO: 提示行
			if not line.begins_with("\""):
				continue
			var fields := line.split("\",\"")
			if fields.size() < 2:
				continue
			if fields[1].strip_edges() == str(pid):
				return fields[0].trim_prefix("\"")
		return ""
	OS.execute("ps", PackedStringArray(["-p", str(pid), "-o", "comm="]), output)
	if output.is_empty():
		return ""
	return str(output[0]).strip_edges().get_file()


# ---- Scene validation (terrain + TargetSV) ---------------------------------

func _connect_scene_signals() -> void:
	var es := EditorInterface.get_editor_settings()
	if es != null:
		scene_changed.connect(_on_scene_changed)


func _disconnect_scene_signals() -> void:
	if scene_changed.is_connected(_on_scene_changed):
		scene_changed.disconnect(_on_scene_changed)


func _on_scene_changed(scene_root: Node) -> void:
	_validate_scene(scene_root)


func _validate_current_scene() -> void:
	var root := get_editor_interface().get_edited_scene_root()
	if root != null:
		_validate_scene(root)


func _validate_scene(root: Node) -> void:
	if root == null:
		return
	var spa := _scene_spa_host()
	if spa != null and not spa.is_ready():
		spa.initialize_runtime()
	_validate_terrain(root)
	_validate_targetsv(root)
	_enforce_headless_guard()


func _validate_terrain(root: Node) -> void:
	var terrain := root.find_child("Terrain", true, false) as MeshInstance3D
	if terrain == null:
		return
	if terrain.mesh == null:
		push_warning("[MeshFill Plugin] Scene '%s' Terrain node has no mesh" % root.name)
		return
	var capture := float(terrain.get_meta("terrain_capture_size", 0))
	if capture <= 0.0:
		push_warning("[MeshFill Plugin] Scene '%s' Terrain missing capture_size metadata" % root.name)


func _validate_targetsv(root: Node) -> void:
	var spa := _scene_spa_host()
	var tsv := spa.get_volume(&"TargetSV") if spa != null else null
	if tsv == null:
		return
	if tsv.has_method("is_targetsv_ready"):
		if not tsv.is_targetsv_ready():
			push_warning("[MeshFill Plugin] Scene '%s' TargetSVSetup failed to load data" % root.name)


func _enforce_headless_guard() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("[MeshFill Plugin] Editor should not run in headless mode for this project")
