@tool
class_name TargetSVSetup
extends "res://scripts/auto_volume_field.gd"

## Preloads TargetSV data from res://assets/target_sv/ at scene init.
## Lives at SPA/Volumes/TargetSV. ScenePlacementActor is its lifecycle owner.
##
## ── V2：改 `extends AutoVolumeField`（《AutoVolume 公用体积基类计划》§4）─────────
## 交给基类、本文件**已删除**的东西（别照旧版本加回来）：
##   * 祖先 SPA 解析（`_cached_spa` / `_require_spa()` / `_resolve_scene_placement_actor()`
##     / `_enter_tree` / `_exit_tree`）—— 全仓 5 处逐字相同的那一份
##   * 内容修订号（`_content_revision` + 它的软重载播种修复）→ 基类 `revision()` / `bump_revision()`
##   * 显示节点清理（`_clear_display()`）、可见性开关（`set_display_visible` / `is_display_visible`）
##   * 显示 AABB 与 cell 尺寸的推导 —— 与 `meshfill_brush.gd` 逐字重复的那两段
##   * `GENERATED_GROUP` 常量 → 基类按域名派生 `generated_display_group()`
##   * `PICK_DRAWABLE_META` 的手写 `set_meta` → 基类 `register_pick_drawable()`（一次做完
##     meta + 显示组 + 三项校验）
##
## ⚠ 基类的 `_repair_soft_reloaded_members()` 是**模板方法，不要重写**；本类修自己的成员
## 走 `_repair_soft_reloaded_domain_members()`。
## ⚠ `_ready()` 保留但基类没有同名钩子，故不需要 `super._ready()`；进/出树的 SPA 缓存作废
## 在基类里走 `_notification`，本类**不要**再定义 `_enter_tree` / `_exit_tree`。

const TargetSVLoaderScript := preload("res://scripts/target_sv_loader.gd")
# ⚠ TerrainConfig / TerrainInitializer / VoxelDisplay / VoxelGeneral 由 PickableDomain
# 声明并继承下来，重新 preload 会报 "member already exists in parent class"。

const DisplayChannelUtils := preload("res://scripts/utils/display_channel_utils.gd")

## 显示节点名（外部专用收集口已删——TargetSV 并入通用组扫描，2026-08-10；
## 本常量只剩类内消费）。
const DISPLAY_NODE := "TargetSVVoxels"

## TargetSV 显示 cell 的填充比与高度下限。覆盖基类默认值——这两个数是 TargetSV 特有的
## （笔刷那边是 0.9 / 0.03），收进基类后仍按域覆盖，但算式只有一份。
const DISPLAY_FILL_RATIO := 0.72
const MIN_CELL_HEIGHT := 0.02

@export_group("Display")
@export_enum("Color", "Complexity", "Collision") var display_channel: int = DisplayChannelUtils.CHANNEL_COLOR
@export_range(0.0, 1.0, 0.001) var occupancy_threshold: float = 0.001
@export var display_scale: float = 1.0
@export var fresnel_enabled: bool = true

var _ready_ok := false
var _metadata: Dictionary = {}
# ⚠ 这里曾有 `_visual_bytes` / `_collision_bytes`（只写不读，2026-08-10 删）、
# `_grid_size`（框架成员副本，直接违反 PickableDomain.grid_frame() 的"不得抄三项"——
# 读处全部改为经 grid_frame() / get_grid_frame() 现取）、以及 `_terrain_height`
# （地形高度场收编时漏网的**第四份**——基类已从 SceneSV / SVTile / BrushSV 收编三份，
# 本域改读 display_terrain_height_field()，marker 与显示自此同一份缓存）。
var _voxel_count := 0
var _height_span := 0.0
var _occupancy := PackedFloat32Array()
var _collision := PackedFloat32Array()
var _color_rgba := PackedFloat32Array()
var _active_voxel_count := 0
var _last_display_reason := ""


func _ready() -> void:
	rebuild.call_deferred()


# ── 域身份与显示几何（基类钩子的实现）─────────────────────────────────────────

## ⚠ 刻意默认**不显示**（基类 READY 时应用，与 SceneSV / SVTile 同路）：TargetSV 是贴满
## 整片地形表面的靶场体素，默认开着会把其余五个域全遮在后面——ID pass 按深度取胜，
## 表现是「锚点/AutoObject 画得出却点不中」。由 Ctrl+Alt+5 或显示开关按需打开。
func default_display_visible() -> bool:
	return false


func domain_key() -> String:
	return SPAEditorContractScript.SELECTION_DOMAIN_TARGETSV


func display_node_name() -> String:
	return DISPLAY_NODE


func display_fill_ratio() -> float:
	return DISPLAY_FILL_RATIO


func min_cell_height() -> float:
	return MIN_CELL_HEIGHT


## 地形相对带的高度跨度。基类的 `display_aabb()` 用它算 Y 上界——贴在高处地形上的体素
## 靠这一段才不会被视锥剔除。
func display_height_span() -> float:
	_ensure_loaded()
	return _height_span


## TargetSV 显示侧的缩放。**不是**卷自己的坐标框架（框架恒为 SPA 那一份，§2.3），
## 只用于显示铺开。
func display_scale_value() -> float:
	return display_scale


## 元素数取已解码的 voxel_count。它与基类按网格算出来的容量恒等
## （`spa_checks.test_grid_target_alignment` 守的就是这条：烘焙资产的 texture_size/slice_count
## 与场景网格同源），但资产没加载完时 `_voxel_count` 才是如实的 0。
func element_capacity() -> int:
	_ensure_loaded()
	return _voxel_count


func rebuild() -> void:
	_ensure_loaded()
	rebuild_display()


## 从 res://assets/target_sv/ 重新读取 TargetSV（外部烘焙器重新导出后用）。
##
## _ready_ok 必须先落回 false：_ensure_loaded() 第一句就是 `if _ready_ok: return`，
## 不清它则整块重读与修订号自增（基类 bump_revision）都不会发生——按钮点了等于没点。
## 落回 false 之后 _ensure_loaded() 内部本来就会调 TargetSVLoader.reload()，把**进程级**
## 静态字节 / _decoded / content_generation 一并换新，这里不必也不该再调一次。
##
## 只负责本节点自己那一份：笔刷等下游持有各自的解码缓存，由调用方（SPA.reimport_target_sv）
## 配对刷新。GPU 点选缓存不用管——它按 content_revision + content_generation 做键。
func reimport() -> Dictionary:
	_ready_ok = false
	rebuild()
	if not _ready_ok:
		return {"ok": false, "reason": "targetsv_load_failed"}
	return {
		"ok": true,
		"reason": "ok",
		"grid_size": grid_frame().get("grid_size", Vector3i.ZERO),
		"voxel_count": _voxel_count,
		"content_revision": get_content_revision(),
		# display_visible=false 时不会跑显示字段准备，此项保持上一次的取值。
		"display_reason": _last_display_reason,
	}


# ⚠ 这里曾有 `get_display_snapshot()`（解码字段快照，含 base_* 未缩放框架两键）。
# 唯一下游 CPU 消费方是 MeshFillBrush（画在 TargetSV 网格上）——笔刷切进卷节点、
# 改读基类 `grid_frame()` 后（2026-08-10），快照连同 SPA 侧的 `get_target_sv_snapshot()`
# 门面一起成为零调用，已删除。显示路径直接用本类成员，不经快照。


func _ensure_loaded() -> void:
	if _ready_ok:
		return
	TargetSVLoaderScript.reload()
	_metadata = TargetSVLoaderScript.metadata()
	if _metadata.is_empty():
		push_error("[TargetSVSetup] TargetSV metadata not found —— TargetSV 资产未烘焙或路径错误")
		assert(false, "[TargetSVSetup] missing TargetSV metadata")
		return
	# 必需字段清单归 TargetSVLoader（`DATASET_FRAME_KEYS`，理由见那里）——这里曾抄了一份
	# 同样的字面量，与 loader 的两处一共三份，没有任何东西保证它们同步。
	for required_key in TargetSVLoaderScript.DATASET_FRAME_KEYS:
		if not _metadata.has(required_key):
			push_error("[TargetSVSetup] TargetSV metadata 缺少必需字段 '%s'（已有键: %s）—— 拒绝按默认值解码" % [required_key, str(_metadata.keys())])
			assert(false, "[TargetSVSetup] missing TargetSV metadata field")
			return
	# 网格事实源 = 祖先 SPA 的导出网格，与 SceneSV / BrushSV / BlendSV 是同一份。
	# 烘焙资产与场景网格不同源时字节数对不上，由 SPA 侧那道硬门
	# （ScenePlacementActor._prepare_target_read_buffers）统一拦，这里不再重复校验。
	# 网格不再抄成员（§2.3：框架三项一律经基类 grid_frame() 现取）；这里只确认宿主在。
	var spa := _require_spa()
	if spa == null:
		return
	_assert_target_frame_matches_bake(spa)
	_voxel_count = int(_metadata["voxel_count"])
	_height_span = float(_metadata["max_height"])
	_ready_ok = true
	bump_revision()


## **接收端门禁**：烘焙用的世界网格必须与 SPA 的显示框架逐项吻合（XZ + Y）。
##
## ⚠ 这道门禁是「导入不经过 SPA」这条设计的配套（2026-08-12 用户裁定）。导入服务按
## `TerrainConfig` 自己推网格、不问 SPA 要参数，所以两边一致**不能靠注入去保证**，
## 只能在结果交到 TargetSV 手里时逐项验。验不过就硬失败，而不是画出一份错位的资产。
##
## 它拦的是一类**无声**错位：落格在导入服务、摆放在 SPA 框架，两套数各自合法、谁也不
## 检查谁。2026-08-12 之前竖直方向就是 span=40/16=2.5 对 voxel_size.y=2.0 —— 整份
## TargetSV 恒定压扁到 0.8×，零报错，只能靠肉眼比对源模型才看得出来。
##
## 老资产缺 vertical_floor / capture_size 时按各自的旧口径（0.0 / 元数据值）读，
## 判据因此对新旧资产都成立。
func _assert_target_frame_matches_bake(spa: Node) -> void:
	var frame: Dictionary = spa.call("get_grid_frame")
	if frame.is_empty():
		return
	var grid: Vector3i = frame["grid_size"]
	var origin: Vector3 = frame["grid_origin"]
	var cell: Vector3 = frame["voxel_size"]
	if grid.x <= 0 or grid.y <= 0:
		return

	var baked_columns := int(_metadata["texture_size"])
	var baked_slices := int(_metadata["slice_count"])
	var baked_capture := float(_metadata["capture_size"])
	var baked_floor := float(_metadata.get("vertical_floor", 0.0))
	var baked_span := float(_metadata["vertical_span"])

	# 烘焙口径推出来的「SPA 应该长什么样」。XZ 由 capture 居中铺开，Y 由量程切片。
	var want_cell_xz := baked_capture / float(maxi(baked_columns, 1))
	var want_origin_xz := -0.5 * baked_capture
	var want_cell_y := (baked_span - baked_floor) / float(maxi(baked_slices, 1))

	var problems := PackedStringArray()
	# 容差取各自量纲的千分之一：两边本是同一串浮点运算，正常差值在 1e-6 量级，
	# 放宽只为躲开 json 的十进制往返截断，仍远小于"少一格/少一层"这类真实错配。
	if grid.x != baked_columns or grid.z != baked_columns:
		problems.append("网格列数 %d×%d ≠ 烘焙 texture_size %d" % [grid.x, grid.z, baked_columns])
	if grid.y != baked_slices:
		problems.append("网格层数 %d ≠ 烘焙 slice_count %d" % [grid.y, baked_slices])
	if absf(cell.x - want_cell_xz) > maxf(want_cell_xz * 0.001, 1e-5) \
			or absf(cell.z - want_cell_xz) > maxf(want_cell_xz * 0.001, 1e-5):
		problems.append("voxel_size.xz (%.4f, %.4f) 应为 %.4f（capture %.3f / %d 列）" % [
			cell.x, cell.z, want_cell_xz, baked_capture, baked_columns])
	if absf(origin.x - want_origin_xz) > maxf(absf(want_origin_xz) * 0.001, 1e-5) \
			or absf(origin.z - want_origin_xz) > maxf(absf(want_origin_xz) * 0.001, 1e-5):
		problems.append("grid_origin.xz (%.4f, %.4f) 应为 %.4f（capture 居中）" % [
			origin.x, origin.z, want_origin_xz])
	if absf(origin.y - baked_floor) > maxf(absf(want_cell_y) * 0.001, 1e-5):
		problems.append("grid_origin.y %.4f 应为烘焙 vertical_floor %.4f" % [origin.y, baked_floor])
	if absf(cell.y - want_cell_y) > maxf(absf(want_cell_y) * 0.001, 1e-5):
		problems.append("voxel_size.y %.4f 应为 %.4f（量程 [%.2f, %.2f) / %d 层）" % [
			cell.y, want_cell_y, baked_floor, baked_span, baked_slices])
	if problems.is_empty():
		return

	push_error(("[TargetSVSetup] 烘焙网格与 SPA 显示框架不一致 —— 整份 TargetSV 会**静默错位**。\n  "
		+ "\n  ".join(problems)
		+ "\n  修法：改 ScenePlacementActor 的 grid_size / voxel_size / grid_origin 对齐上面的「应为」，"
		+ "或按当前框架重烘 TargetSV。"))
	assert(false, "[TargetSVSetup] baked grid / SPA frame mismatch")


## 早退守卫（基类 `rebuild_display()` 模板的钩子）恒 false = 每次调用都重建。
##
## ⚠ 本域**不能**按修订号早退：显示频道（switch_display_channel）与 display_scale 这类
## **显示参数**变更不推进内容修订号，按修订号早退会把频道切换静默吞掉——
## 这也是切换前旧 rebuild_display 一直无条件重建的原因，行为保持不变。
func _display_cache_intact() -> bool:
	return false


## 建 TargetSV 方盒显示（基类 `rebuild_display()` 模板的钩子；清理 / add_child /
## drawable 登记 / 可见性写入全在基类模板里）。
func _build_display_node() -> MultiMeshInstance3D:
	_ensure_loaded()
	if not _ready_ok:
		return null
	if not _prepare_display_fields():
		push_warning("[TargetSVSetup] TargetSV display skipped: %s" % _last_display_reason)
		return null
	var node := _build_field_display()
	if node == null:
		push_warning("[TargetSVSetup] TargetSV display skipped: %s" % _last_display_reason)
	return node


## 本域的显示是**全量铺开**的，不是紧凑的（基类点选据此走恒等映射）。
##
## 依据在 `shaders/voxel_field_instances.glsl`：一实例一格、全网格
## （`idx = gl_GlobalInvocationID.x`，写 `instances[idx * 16 + …]`），且格序就是规范索引式
## `index = x + gx * (z + gz * y)`（= `VoxelGeneral.voxel_index`）。空格塌成零基向量、
## 画不出像素，所以只有真占据的格子会被点中——不需要也不能在 ID 区间上把空格排除掉
## （排除了 INSTANCE_ID 就对不上格序了）。
##
## ⚠ 这一行同时挡住一个性能陷阱：全量域若走基类的紧凑表，
## `AutoVolumeField.build_compact_instance_list()` 会物化一张 10^6 项的恒等映射表
## （GDScript 循环，几百毫秒 + 4 MiB），每次点击一遍。
func display_is_compact() -> bool:
	return false


## 全量显示的实例数 = 已解码的体素总数（资产没加载完时如实为 0，基类越界守卫据此判死）。
func displayed_instance_count(_key = null) -> int:
	_ensure_loaded()
	return _voxel_count if _ready_ok else 0


func _prepare_display_fields() -> bool:
	if _voxel_count <= 0:
		_last_display_reason = "empty_voxel_count"
		return false
	var decoded := TargetSVLoaderScript.decode()
	if not bool(decoded.get("valid", false)):
		_last_display_reason = str(decoded.get("reason", "target_decode_failed"))
		return false

	var target_color: PackedColorArray = decoded.get("target_color", PackedColorArray())
	var target_collision: PackedFloat32Array = decoded.get("target_collision", PackedFloat32Array())
	var target_completeness: PackedFloat32Array = decoded.get("target_completeness", PackedFloat32Array())
	if target_color.size() < _voxel_count or target_completeness.size() < _voxel_count:
		_last_display_reason = "target_decode_size_mismatch"
		return false
	# collision 原先短于 voxel_count 时被静默 resize 补零（= 全场判无碰撞），与上面 color /
	# completeness 的尺寸硬门不一致；同样按尺寸不符处理，不再零填充。
	if target_collision.size() < _voxel_count:
		push_error("[TargetSVSetup] target_collision 长度 %d 短于 voxel_count %d —— 拒绝零填充为「无碰撞」" % [target_collision.size(), _voxel_count])
		assert(false, "[TargetSVSetup] target_collision size mismatch")
		_last_display_reason = "target_decode_size_mismatch"
		return false

	# --- 三个显示字段的整块构建（原为三个 voxel_count 级逐元素循环，各约 105 万次迭代） ---
	#
	# 省略逐元素 clampf(x, 0.0, 1.0) 的等价性依据：这三个数组的唯一生产者是
	# TargetSceneVoxelGenerator.decode_target_read_buffers / decode_target_read_buffers_gpu，
	# 两条路径写入的值只有两种来源——
	#   * SceneVoxelTileCodec 的 decode_collision_field_r8_at / decode_complexity_field_rgba8_color_at，
	#     都是 unorm8 反量化，取值域恒为 [0, 1] 且不可能是 NaN；
	#   * CPU 路径里已显式 clampf(..., 0.0, 1.0)（或对两个已 clamp 值取 maxf）的结果。
	# 因此原先的 clampf 对每个元素都是恒等映射，去掉后逐位不变。
	# 上一段的尺寸门（target_color / target_completeness 短于 _voxel_count 即返回 false）
	# 同时意味着原循环里 `i < ....size()` 的 else 分支对这两者不可达，一并消除。
	var color_source := target_color
	if color_source.size() > _voxel_count:
		color_source = color_source.slice(0, _voxel_count)
	# PackedColorArray 底层是 Vector<Color>，Color 是 16 字节紧凑结构
	# （core/math/color.h：union { struct { float r, g, b, a; }; float components[4]; }，无 padding）；
	# Vector<T>::to_byte_array() 是整块 memcpy（core/templates/vector.h），
	# PackedByteArray.to_float32_array() 同样是整块 memcpy 重解释
	# （core/variant/variant_call.cpp::func_PackedByteArray_decode_float_array）。
	# 两步合起来正好得到 [r0, g0, b0, a0, r1, ...] 的展开结果，且是一份全新数组
	# （不与 TargetSVLoader.decode() 的常驻缓存共享存储）。
	_color_rgba = color_source.to_byte_array().to_float32_array()

	# slice() 返回新数组；上面的尺寸硬门已保证两者长度 >= _voxel_count，
	# 故这里只做截断，不再有「不足则 resize 补 0」的静默补齐。
	_collision = target_collision.slice(0, _voxel_count)
	_occupancy = target_completeness.slice(0, _voxel_count)

	_active_voxel_count = 0
	for value in _occupancy:
		if value > occupancy_threshold:
			_active_voxel_count += 1

	var terrain := TerrainInitializerScript.find_edit_time_terrain(self) as MeshInstance3D
	if terrain == null or terrain.mesh == null:
		# 无地形时旧行为是拿一整块 0 高度场继续显示（体素全贴在 y=0）；如实报失败，不造假地形。
		_last_display_reason = "missing_edit_time_terrain"
		return false
	# 高度场走基类缓存（分辨率 = 规范网格 XZ 边、跨度 = display_height_span() 即资产
	# max_height——与此前本地那份逐参数相同）。先显式查地形是为保住上面那条独立失败原因。
	if display_terrain_height_field().is_empty():
		_last_display_reason = "terrain_height_field_unavailable"
		return false
	_last_display_reason = "ok"
	return true


func _build_field_display() -> MultiMeshInstance3D:
	if RenderingServer.get_rendering_device() == null:
		_last_display_reason = "missing_rendering_device"
		return null
	var frame := get_grid_frame()
	if frame.is_empty():
		_last_display_reason = "target_grid_frame_unavailable"
		return null
	var voxel_size: Vector3 = frame["voxel_size"]
	# ⚠ cell 尺寸与可见性盒的推导已上交基类（§2.5-9 / §2.5-10）——此前这两段与
	# meshfill_brush.gd 逐字重复、连注释都一样，且两处系数不同却谁也不知道对方存在。
	# 本类只声明系数（DISPLAY_FILL_RATIO / MIN_CELL_HEIGHT）与高度跨度
	# （display_height_span / display_scale_value），算式在 AutoVolumeField。
	var cell := display_cell_size()
	var aabb := display_aabb()
	var instance := VoxelDisplayScript.build_field_gpu(
		_voxel_count,
		cell,
		aabb,
		{
			"occupancy": _occupancy,
			"collision": _collision,
			"color_rgba": _color_rgba,
			# 基类缓存（与 marker 的 voxel_to_world 恒同一份，见成员注释）。
			"terrain_height": display_terrain_height_field(),
		},
		{
			# 网格维度不随 display_scale 变，缩放框架里的 grid_size 就是规范值。
			"grid_size": frame["grid_size"],
			"grid_origin": frame["grid_origin"],
			"voxel_size": voxel_size,
			"view_mode": DisplayChannelUtils.channel_to_view_mode(display_channel),
			"display_scale": display_scale,
			"height_span": _height_span,
			"threshold": occupancy_threshold,
		},
		{
			"name": DISPLAY_NODE,
			"fill": 1.0,
		}
	)
	if instance != null and fresnel_enabled:
		_apply_fresnel_material(instance)
	if instance != null:
		_last_display_reason = str(instance.get_meta("voxel_display_reason", "ok"))
	else:
		_last_display_reason = "field_display_build_failed" if _active_voxel_count > 0 else "no_visible_voxels"
	return instance


func _apply_fresnel_material(instance: MultiMeshInstance3D) -> void:
	if instance == null:
		return
	instance.material_override = DisplayChannelUtils.create_fresnel_rim_material()


## ⚠ `set_display_visible()` / `is_display_visible()` 已上交基类（形状逐字相同）。
## 名字必须保持不变：`ScenePlacementActor` 的 `@export var target_sv_visible` 的 getter 直接调
## `is_display_visible()`，改名会让 Inspector 每帧 getter 报错。
## ⚠ 也**不能**改叫 `set_visible` / `is_visible` —— 那是 Node3D 的原生方法，
## GDScript 的 NATIVE_METHOD_OVERRIDE 警告默认就是 ERROR 级，会直接打红门禁。


func switch_display_channel(channel: int) -> void:
	var next := clampi(channel, DisplayChannelUtils.CHANNEL_COLOR, DisplayChannelUtils.CHANNEL_COLLISION)
	if display_channel == next and get_node_or_null(DISPLAY_NODE) != null:
		return
	display_channel = next
	rebuild_display()


## TargetSV 未缩放的规范框架 = **祖先 SPA 的那一份**，与 SceneSV / BrushSV / BlendSV 逐字段相同。
##
## 给需要按**自己的** display_scale 铺开的消费方用（MeshFillBrush 的 display_scale 是它自己的
## @export）。要 TargetSV 这一份已缩放的框架用 get_grid_frame()。
## ⚠ 与基类的 `grid_frame()` 是同一份数据的两个名字：基类那个是**未缩放**的 SPA 框架
## （所有卷共用），本函数是它加上"资产已加载"这道门之后的同一份。TargetSV 自己那份
## **已缩放**的框架叫 `get_grid_frame()`（下一个函数），三者别混。
func get_base_grid_frame() -> Dictionary:
	_ensure_loaded()
	if not _ready_ok:
		return {}
	# 转发基类，不再自己从 spa.grid_origin / spa.voxel_size 拼一遍（§2.3）。
	return grid_frame()


## TargetSV 的规范坐标框架（**节点局部空间**；世界坐标由调用方乘 global_transform）。
##
## 这是 TargetSV 与其余 volume 共用同一套词汇的接入点：网格 = grid_size、格距 = voxel_size、
## 原点 = grid_origin，换算走 VoxelGeneral.voxel_center_to_world / world_to_voxel（互为精确逆）。
## 三项都来自 SPA（get_base_grid_frame），本节点只按 display_scale 缩放——TargetSV 不再从
## capture_size/vertical_span 自行推导一套框架（旧式与 SPA 那套只在 capture 恰好差一格时相等）。
## texture_size / slice_count / capture_size / vertical_span 保留为派生别名，仅供元数据回显。
##
## Y 的地形相对段不在框架里：它逐列变化，由 terrain_height + height_scale 承担
## （world.y = terrain[z*gx + x] * display_scale + (slice + 0.5) * voxel_size.y）。
func get_grid_frame() -> Dictionary:
	var base := get_base_grid_frame()
	if base.is_empty():
		return {}
	# ⚠ 按**键名**取，别按字典顺序展开：scaled_grid_frame 的形参序是
	# (grid_size, grid_origin, voxel_size, scale)，与 grid_frame() 的键序把后两项对调，
	# 且两者同为 Vector3 —— 传反了不报错、不崩，只有整套坐标静默错位。
	var frame := VoxelGeneralScript.scaled_grid_frame(
		base["grid_size"], base["grid_origin"], base["voxel_size"], display_scale)
	# 地形高度场本身不进框架（消费方各自持有自己那一份，分辨率可能不同）；
	# 这里只声明"地形偏移要乘多少"，即 world.y += terrain * height_scale。
	frame["height_scale"] = display_scale
	return frame


func voxel_to_world(x: int, slice_index: int, z: int) -> Vector3:
	var frame := get_grid_frame()
	if frame.is_empty():
		return Vector3.ZERO
	return VoxelGeneralScript.terrain_relative_voxel_center_to_world(
		Vector3i(x, slice_index, z),
		frame["grid_size"],
		frame["grid_origin"],
		frame["voxel_size"],
		display_terrain_height_field(),
		display_scale
	)


func is_targetsv_ready() -> bool:
	_ensure_loaded()
	return _ready_ok


func get_visual_bytes() -> PackedByteArray:
	_ensure_loaded()
	return TargetSVLoaderScript.visual_bytes()


func get_collision_bytes() -> PackedByteArray:
	_ensure_loaded()
	return TargetSVLoaderScript.collision_bytes()


# ⚠ 编辑器软重载后的成员修复，别当成冗余判空删掉。依据与写法见基类
# PickableDomain._repair_soft_reloaded_members()（软重载只搬重载前已存在的成员；
# 判空必须用 `is`，静态类型已知时 `== null` 被编成恒 false）。
#
# ⚠ 重写的是 `_repair_soft_reloaded_domain_members()` 而不是 `_repair_soft_reloaded_members()`：
# 后者是基类的模板方法，重写它会把基类那半段（修订号播种、display_visible、SPA 缓存）
# 整个顶掉且不报错。
#
# 语义连带：解码缓存与 `_ready_ok` 是一对。任一丢失就必须把 `_ready_ok` 推回 false，
# 否则会拿一组空数组配一个"已加载"的标志，表现是整块显示画不出来而不报错。
func _repair_soft_reloaded_domain_members() -> void:
	# 地形高度场与 _grid_size 已不在本类（前者走基类缓存并由基类修复，后者删除）。
	var decoded_lost := not (_occupancy is PackedFloat32Array) \
		or not (_collision is PackedFloat32Array) \
		or not (_color_rgba is PackedFloat32Array)
	if not (_occupancy is PackedFloat32Array): _occupancy = PackedFloat32Array()
	if not (_collision is PackedFloat32Array): _collision = PackedFloat32Array()
	if not (_color_rgba is PackedFloat32Array): _color_rgba = PackedFloat32Array()
	if not (_metadata is Dictionary): _metadata = {}
	if not (_voxel_count is int): _voxel_count = 0
	if not (_height_span is float): _height_span = 0.0
	if not (_active_voxel_count is int): _active_voxel_count = 0
	if not (_last_display_reason is String): _last_display_reason = ""
	if not (_ready_ok is bool) or decoded_lost: _ready_ok = false


## 内容修订号。⚠ 保留本名转发到基类 `revision()`：`get_content_revision` 这个字符串既在
## `SPASelectionHost` 的 TargetSV 契约方法清单里（`_require_targetsv_api(["get_content_revision"])`），
## 又被 `ScenePlacementActor.get_volume_ownership_report()` 按 `has_method` + `call()` 反射调用。
## 改名不会有任何静态信号，只会让两处静默降级。
func get_content_revision() -> int:
	_ensure_loaded()
	return revision()


# ⚠ 这里曾有 `get_grid_size()` / `get_metadata()` / `upload_to_gpu()` 三个零调用读口
# （2026-08-10 链路死码清除；grid 一律走 `grid_frame()`，metadata 内部自持，
# 上传走 SPA 的常驻通路）。loader 侧的同名 upload_to_gpu 一并删除。
