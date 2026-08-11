@tool
class_name MeshFillBrush
extends Node3D

## 笔刷的 addon 侧：**输入捕获 + 笔刷参数 + 共享地形环境托管**，仅此三件（§1.4）。
##
## ── 2026-08-10 切换：内容 / 显示 / 落笔定位全部移交 `BrushSVVolume` ────────────
## 本文件曾持有笔刷的 CPU 体素列表、`BrushTetraVoxels` 显示构建、`set_brush_visible`
## 可见性开关、`screen_to_voxel_xz` 落笔定位，以及三个框架副本
## （`_grid_size` / `_grid_origin` / `_voxel_size`，《AutoVolume 计划》§2.3 点名的违例）。
## 这些现在都在 `SPA/Volumes/BrushSV`（`BrushSVVolume`）——内容与显示随卷节点走基类
## （rebuild 模板 / 显示几何 / 地形高度场 / ID pass 登记），本文件不再知道体素怎么存、
## 怎么画、怎么被点中。
##
## ⚠ 别把任何"数据"加回来：这里能立足的只有（1）编辑器输入事件的捕获与转发
## （由 SPA.handle_editor_input 分发，笔刷参数在本节点的 @export 上），
## （2）共享编辑期地形的 reuse 与缩放（TerrainInitializer 的宿主约定），
## （3）TargetSV 绑定的**身份跟踪**——换靶即通知 SPA 清空 BrushSV 两半。

const TerrainInitializerScript := preload("res://scripts/terrain_initializer.gd")

@export_group("Brush")
@export_range(1, 128) var brush_width: int = 5
@export_range(1, 128) var brush_length: int = 5
@export_range(1, 32) var brush_height: int = 3
@export var brush_paint_color := Color(0.8, 0.4, 0.1)
@export_range(0.0, 1.0) var brush_paint_complexity: float = 0.5
@export_range(0.0, 1.0) var brush_paint_collision: float = 0.5

@export_group("Display")
## 共享地形网格的显示缩放。⚠ 只作用于地形环境节点；笔刷体素的显示在 `BrushSVVolume`，
## 那边的缩放恒为基类默认 1.0（与 SceneSV 同口径）。
@export var display_scale: float = 1.0

## TargetSV 绑定的身份跟踪（只存引用，不读它的任何数据）。
var _target_sv_setup: TargetSVSetup = null


func _ready() -> void:
	if not Engine.is_editor_hint():
		return
	_rebuild.call_deferred()


func rebuild(force: bool = false) -> void:
	_rebuild(force)


## 绑定 SPA 的 TargetSV，返回「靶是否**换了**」。
##
## 返回 true 时调用方（`ScenePlacementActor._ensure_owned_tree`）必须清空 BrushSV 两半
## （卷节点的 CPU 列表 + GPU 场，走 `clear_brush_sv()`）：笔迹是画在旧靶网格上的，
## 换靶后既不可见也不可编辑、却仍在喂 BlendSV 合成与评分。
##
## 首次绑定（null → 靶）返回 false：那时还没有任何笔迹可清，而 GPU 侧未必就绪。
## 同靶重复绑定返回 false——本函数被只读路径高频间接调用（get_volume →
## _ensure_owned_tree，每次桥 select_node 都会跑），返回 true 就等于让一次只读查询
## 清空用户画好的笔刷。
func attach_target_sv(target_sv: TargetSVSetup) -> bool:
	if _target_sv_setup == target_sv:
		return false
	var changed := _target_sv_setup != null and target_sv != null
	_target_sv_setup = target_sv
	return changed


func _rebuild(force: bool = false) -> void:
	if not force and not Engine.is_editor_hint():
		return
	var terrain_contract := TerrainInitializerScript.reuse_shared_terrain(self, {"visible": true})
	if not bool(terrain_contract.get("ok", false)):
		push_warning("[MeshFillBrush] Terrain init: %s" % str(terrain_contract.get("reason", "unknown")))
	_scale_terrain_to_display()


func _scale_terrain_to_display() -> void:
	var terrain := find_child("Terrain", true, false) as MeshInstance3D
	if terrain != null:
		terrain.scale = Vector3.ONE * display_scale
		terrain.visible = true
		terrain.layers = 1
		terrain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
