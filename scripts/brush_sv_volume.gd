@tool
class_name BrushSVVolume
extends "res://scripts/auto_volume_field.gd"

## `SPA/Volumes/BrushSV` 的节点脚本（《AutoVolume 公用体积基类计划》V1、§1.4）。
##
## ── 与 addon 侧 `MeshFillBrush` 的分工（§1.4）────────────────────────────────
## **输入侧**（`MeshFillBrush`，addon）：只做点击捕获，把"哪些体素变了、变成什么"
## 以 instance change 的形式喂过来。不持有 Buffer、不知道体素怎么存。
## **数据与显示侧**（本类，SPA）：域身份、内容修订号、可视化。
##
## ── 场对 Buffer 归 ScenePlacementRuntime（刻意）────────────────────────────
## BrushSV 是**纯 GPU 卷**：场对由 `ScenePlacementRuntime` 全权持有，因为写入路径
## （散射 shader）与合成路径（BlendSV）都在 runtime 里，且 runtime 才是 RenderingDevice
## 的持有者。分配逻辑与 BlendSV 一起收敛在 `VolumeFieldBuffers`（§2.5-7）。
## 节点侧曾有 `field_rid()` / `has_resident_fields()` 转发读口——**全仓零调用点**，
## 已删除（2026-08-10，成因见 AutoVolumeField 类注释）；管线读场对走 runtime 自己的通路。
##
## ── 显示与点选（2026-08-10 切换完成）─────────────────────────────────────
## 「内容 + 显示 + 落笔定位」全部在本类：addon 的 `MeshFillBrush` 只剩输入捕获、
## 笔刷参数（@export）与共享地形环境托管；它此前的内容列表 / 显示构建 /
## `set_brush_visible` / 三个框架副本（§2.3 违例）已删除。
## 点选走基类 `register_pick_drawable()` + ID pass（`PICK_ID_DISPLAY_KEYS` 含 "brush"），
## 与其余五域同路——深度即仲裁，`resolve_pick` 的载荷额外带绘制属性供记录构建。

# ⚠ SPAEditorContract / BufferDescriptor / VoxelGeneral / TerrainInitializer /
# TerrainConfig / VoxelDisplay 由基类声明并继承下来，这里重新 preload 会报
# "member already exists in parent class"。直接用。


## ⚠ 刻意默认**不显示**（基类 READY 时应用，与 SceneSV / SVTile / TargetSV 同路）：
## 笔刷是按需工具，空场景里它没有内容可画，默认开着只是白占一个 ID pass 的可选域——
## 而"可见即可选"是 ID pass 的物理规则，一个空可选域会把点击从底下的域上抢走。
## ⚠ 这只关**显示**：`apply_brush_extent()` 的落笔记录与修订号不受它影响，
## 关着照样能画进 BrushSV（只是看不见）。要看笔迹按 Ctrl+Alt+6。
func default_display_visible() -> bool:
	return false


func domain_key() -> String:
	return SPAEditorContractScript.SELECTION_DOMAIN_BRUSH


## 笔刷是稀疏输入：整网格分配、只有画过的格子非零。
## ⚠ 这里返回 SPARSE 是对**内容**的描述；存储今天仍是稠密场对（§7.4 要改而未改）。
## 两者不一致时以 BufferDescriptor 的语义为准：DENSITY 描述"有效数据的覆盖范围"，
## 不是"分配方式"。
func element_density() -> String:
	return BufferDescriptorScript.DENSITY_SPARSE


## 笔刷内容修订号的事实源是 runtime（`_brush_sv_revision`）：递增点在散射写入与清空两处，
## 都在 runtime 里。本类转发。
##
## ⚠ 不要改成基类的 `_revision`：那样会出现两个都叫"BrushSV 修订号"的数，
## 而下游（`_brush_flushed_sv_revision` 水位、GPU 点选缓存键）认的是 runtime 那一个。
func revision() -> int:
	var spa := scene_placement_actor()
	return spa.get_brush_sv_revision() if spa != null else 0


## 笔刷画过的体素数。runtime 只记"有没有内容"这一个布尔，没有计数——
## 如实返回 -1（"没人告诉我"），不拿容量或 0 顶上。
func live_element_count() -> int:
	return -1


# ══════════════════════════════════════════════════════════════════════════════
# 内容 + 显示 + 落笔定位（《点选统一》§6.5；2026-08-10 起 addon 那一份已删除，本类是唯一实现）
#
# ── 为什么显示继续走 CPU 稀疏列表，而不是照 SceneSV 那样回读场对 ────────────
# ① **设备**：BrushSV 的 GPU 数据在 SPA 的**本地 RenderingDevice** 上；而
#    `VoxelMultiMeshWriterGPU` 绑的是主设备。RID 不能跨设备 ⇒ 要么回读。
# ② **代价**：回读是 2×4 MiB，且 BrushSV **没有瓦片摘要**那种白送的非空识别，
#    找非空要逐体素扫 10^6 格。而笔刷显示是**每次落笔都重建**的热路径。
# ⇒ 稀疏 CPU 列表全程零回读、零跨设备，是这条路唯一合理的形态。
# ⚠ 代价是「显示 = CPU 已知内容」：旁路直写（`apply_brush_input` / `write_brush_sv_records`
#    两个门面）写进 GPU 的体素**不在** `_brush_voxels` 里，因而画不出来。这个分叉今天
#    就存在，迁移只是让它更容易被误读成"BrushSV 的全部内容"。
# ══════════════════════════════════════════════════════════════════════════════

const DISPLAY_NODE := "BrushTetraVoxels"
## 迁移前这两个系数写在 `meshfill_brush.gd` 里（0.9 / 0.03），与 TargetSV 的 0.72 / 0.02
## 互不知情——**算式在基类，系数按域覆盖**正是为此。
const DISPLAY_FILL_RATIO := 0.9
const DISPLAY_MIN_CELL_HEIGHT := 0.03
## 渲染色的 alpha 下限。complexity 很低的笔迹也要看得见，否则"画了却看不见"。
const RENDER_ALPHA_FLOOR := 0.35

# ── 内容：画过的体素（append-only 稀疏列表）────────────────────────────────
#
# ⚠ **append-only 语义是硬约束**：`ScenePlacementActor._flush_owned_brush()` 的增量水位
# 整个建立在「已在 `_brush_voxel_keys` 里的体素直接跳过、绝不回改属性」之上。
# 改成"可覆盖"会让水位之前那一段与 GPU 内容不一致，且静默。
#
# ⚠ 列表放在**本节点**而不是 runtime（用户 2026-08-07 裁定）：SPA 关停时 GPU 半边被
# `clear_brush_sv(true)` 清空，而 CPU 列表随节点存活 ⇒ 下一笔画时水位失配触发整批重放，
# 自愈。放 runtime 的话用户画好的笔刷会随 runtime 一起消失。
var _brush_voxels := PackedInt32Array()              ## (x, slice, z, 0) 四元组
## `voxel_index → 实例序`：既做落笔去重，也给 `paint_attributes_for_element()` 做 O(1) 反查。
## ⚠ 值是**下标不是布尔**——反查绘制属性要它；改回布尔集合会让那条反查退化成线性扫。
var _brush_voxel_keys := {}
var _brush_voxel_paint_colors := PackedColorArray()
var _brush_voxel_paint_complexity := PackedFloat32Array()
var _brush_voxel_paint_collision := PackedFloat32Array()

## 已建显示对应的实例数（基类 `_built_revision` 之外的第三道守卫，见 _display_cache_intact）。
var _display_instance_count := -1


## 落一笔：把 `center` 处 `extent` 范围内的体素并进列表。返回**本次是否真的新增了体素**。
##
## ⚠ 越界过滤与 Y 上界夹紧都在这里做（迁移前在 addon 的 `_accumulate_brush_extent`）：
## 它们要的是 `grid_size`，而框架的事实源是 SPA —— addon 侧那三个框架副本
## （`_grid_size` / `_grid_origin` / `_voxel_size`）正是靠这一步搬过来才能删掉（§2.3 违例）。
func apply_brush_extent(center: Vector2i, extent: Vector3i, paint: Dictionary) -> bool:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_domain_members()
	var frame := grid_frame()
	if frame.is_empty():
		return false
	var grid: Vector3i = frame["grid_size"]
	var half_w := int((maxi(extent.x, 1) - 1) / 2)
	var half_l := int((maxi(extent.z, 1) - 1) / 2)
	var slice_max := clampi(extent.y, 1, grid.y)
	var paint_color: Color = paint.get("color", Color.WHITE)
	var paint_complexity := float(paint.get("complexity", 0.0))
	var paint_collision := float(paint.get("collision", 0.0))
	var changed := false
	for dz in range(-half_l, half_l + 1):
		for dx in range(-half_w, half_w + 1):
			var x := center.x + dx
			var z := center.y + dz
			if x < 0 or x >= grid.x or z < 0 or z >= grid.z:
				continue
			for s in range(slice_max):
				# 规范索引式（VoxelGeneral.voxel_index）；旧式 s*ts*ts + z*ts + x
				# 只在 XZ 方形时才与之相等。
				var key := VoxelGeneralScript.voxel_index(Vector3i(x, s, z), grid)
				if _brush_voxel_keys.has(key):
					continue
				# 值 = 本格在属性表里的实例序（append-only ⇒ 就是当前长度）。
				_brush_voxel_keys[key] = _brush_voxel_paint_colors.size()
				_brush_voxels.append(x)
				_brush_voxels.append(s)
				_brush_voxels.append(z)
				_brush_voxels.append(0)
				_brush_voxel_paint_colors.append(paint_color)
				_brush_voxel_paint_complexity.append(paint_complexity)
				_brush_voxel_paint_collision.append(paint_collision)
				changed = true
	return changed


## 清空画过的体素。
## ⚠ **必须与 GPU 侧的 `clear_brush_sv()` 配对**：只清一边的表现是
## "屏幕上留着一批看得见、却不在 BrushSV 里、不参与合成与评分的体素"，零提示。
func clear_painted_voxels() -> void:
	_repair_soft_reloaded_members()
	_brush_voxels = PackedInt32Array()
	_brush_voxel_keys = {}
	_brush_voxel_paint_colors = PackedColorArray()
	_brush_voxel_paint_complexity = PackedFloat32Array()
	_brush_voxel_paint_collision = PackedFloat32Array()
	# 显示快照一并作废：留着旧的会让 rebuild_display() 早退，画面停在清空前那一批上。
	_display_instance_count = -1
	_built_revision = -1


func painted_voxel_count() -> int:
	_repair_soft_reloaded_members()
	return _brush_voxels.size() / 4


## 画过的体素四元组（给 SPA 的增量水位比对用）。调用方只读。
func painted_voxels() -> PackedInt32Array:
	_repair_soft_reloaded_members()
	return _brush_voxels


## 逐体素的绘制属性（给 SPA 组装散射 records 用）。
func painted_paint_attributes() -> Dictionary:
	_repair_soft_reloaded_members()
	return {
		"colors": _brush_voxel_paint_colors,
		"complexity": _brush_voxel_paint_complexity,
		"collision": _brush_voxel_paint_collision,
	}


# ── 落笔定位：屏幕射线 → XZ 体素列（迁自 addon，改喂基类设施）────────────────

## 屏幕射线 → 本卷网格的 XZ 体素坐标。找不到返回 (-1, -1)。
##
## 框架来自基类 `grid_frame()`（SPA 唯一事实源），地形来自
## `display_terrain_height_field()`（与显示 shader 同一份缓存）——迁移前 addon 持有的
## 三个框架副本与 TargetSV 快照地形正是被这两个读口取代的（§2.3 违例清除）。
##
## 反解走 VoxelGeneral.world_to_voxel，它按构造是 voxel_center_to_world 的精确逆。
## 旧实现自带一套 `int(u * N)` 分桶，与按 `(N-1)` 展开的正向铺开式差一个纹素：
## 屏幕右下角附近画出来的笔刷整体偏一格，越靠边越明显（计划 §4.4 / §6.2 的 off-by-one）。
##
## 迭代式求交：先按半高试一发，拿命中列的地形高度修正估计再来，至多三轮。
## 地形项乘 `display_scale_value()`（本卷恒 1.0），与显示 shader 的抬升口径一致。
func screen_to_voxel_xz(camera: Camera3D, screen_pos: Vector2) -> Vector2i:
	_repair_soft_reloaded_members()
	if camera == null:
		return Vector2i(-1, -1)
	var frame := grid_frame()
	if frame.is_empty():
		return Vector2i(-1, -1)
	var grid: Vector3i = frame["grid_size"]
	var grid_origin: Vector3 = frame["grid_origin"]
	var voxel_size: Vector3 = frame["voxel_size"]
	var from := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	if absf(dir.y) < 1e-6:
		return Vector2i(-1, -1)

	var terrain := display_terrain_height_field()
	var scale := display_scale_value()
	var best_px := -1
	var best_pz := -1

	var est_y := display_height_span() * 0.5 * scale
	for _iter in range(3):
		var t := (est_y - from.y) / dir.y
		if t <= 0.0:
			break
		var hit := from + dir * t
		if not _inside_grid_xz(hit, grid, grid_origin, voxel_size):
			break
		var voxel := VoxelGeneralScript.world_to_voxel(hit, grid_origin, voxel_size, grid)
		best_px = voxel.x
		best_pz = voxel.z
		var height_index := voxel.z * grid.x + voxel.x
		var terrain_y := terrain[height_index] if height_index < terrain.size() else 0.0
		est_y = terrain_y * scale

	if best_px < 0 or best_pz < 0:
		var t := -from.y / dir.y
		if t <= 0.0:
			return Vector2i(-1, -1)
		var hit := from + dir * t
		if not _inside_grid_xz(hit, grid, grid_origin, voxel_size):
			return Vector2i(-1, -1)
		# world_to_voxel 自带逐轴 clamp，故这里不再重复钳制。
		var voxel := VoxelGeneralScript.world_to_voxel(hit, grid_origin, voxel_size, grid)
		best_px = voxel.x
		best_pz = voxel.z

	return Vector2i(best_px, best_pz)


## 世界点是否落在网格的 XZ 跨度内。world_to_voxel 会把界外点钳进网格，单靠它无法区分
## "射线打在网格外"与"打在边缘体素上"。
func _inside_grid_xz(world_pos: Vector3, grid: Vector3i, grid_origin: Vector3, voxel_size: Vector3) -> bool:
	var local := world_pos - grid_origin
	return local.x >= 0.0 and local.x < float(grid.x) * voxel_size.x \
		and local.z >= 0.0 and local.z < float(grid.z) * voxel_size.z


# ── 显示（基类 rebuild_display() 模板的钩子）────────────────────────────────

func display_node_name() -> String:
	return DISPLAY_NODE


func display_fill_ratio() -> float:
	return DISPLAY_FILL_RATIO


func min_cell_height() -> float:
	return DISPLAY_MIN_CELL_HEIGHT


# ⚠ display_height_span() 不覆写：基类默认 = TerrainConfig.MAX_HEIGHT。
# 迁移前 addon 那份用的是 TargetSV 快照里的 `max_height`（资产 metadata），两者当前
# 逐位相同（资产 max_height = 120.0 = TerrainConfig.MAX_HEIGHT）——那是巧合不是保证：
# 将来资产的 max_height 若不是 120，笔刷体素与 TargetSV 体素会在 Y 上错开一整段抬升。
# 这条依据保留在此，别当成自明。


## 早退守卫的第三项（基类模板的钩子）：实例数必须与当前列表长度一致。
##
## ⚠ 为什么修订号不够：`revision()` 转发的是 runtime 的 `_brush_sv_revision`，它只在
## 散射写入成功与清空时递增 —— **散射失败时 CPU 列表已经变长而修订号没动**。
## 少这一项的表现是"显示还在、却每一次命中都报 instance_index_out_of_range"，
## 而且**强制重建也修不好**（SVTile 落地时踩过同款）。
func _display_cache_intact() -> bool:
	return _display_instance_count == _brush_voxels.size() / 4


func _on_display_discarded() -> void:
	_display_instance_count = -1


func _on_display_built() -> void:
	_display_instance_count = _brush_voxels.size() / 4


func _build_display_node() -> MultiMeshInstance3D:
	# RD / SPA 双守卫在基类模板；本域只剩"没有笔迹就没有显示"这一条自己的门。
	if _brush_voxels.is_empty():
		return null
	var frame := grid_frame()
	return VoxelDisplayScript.build_brush_tetra_gpu(
		_brush_voxels,
		display_cell_size(),
		display_aabb(),
		{
			"grid_size": frame["grid_size"],
			"grid_origin": frame["grid_origin"],
			"voxel_size": frame["voxel_size"],
			"display_scale": display_scale_value(),
			# 单色兜底键：`brush_voxel_display_gpu.gd` 在逐体素色长度对不上时用它铺满。
			# 本类的逐体素色恒等长 ⇒ 那条分支不可达，但键是必填的。
			"brush_color": Color.WHITE,
			"brush_colors": _render_colors(),
			# 与 SceneSV / SVTile 同一份基类缓存（每次重建时重采，marker 读同一份）。
			"terrain_height": display_terrain_height_field(),
		},
		{"name": DISPLAY_NODE, "fill": 1.0}
	)


## 逐体素渲染色 = 绘制色 + 由 complexity 抬起来的 alpha。
func _render_colors() -> PackedFloat32Array:
	var count := _brush_voxel_paint_colors.size()
	var out := PackedFloat32Array()
	out.resize(count * 4)
	for i in range(count):
		var c := _brush_voxel_paint_colors[i]
		var complexity := _brush_voxel_paint_complexity[i] \
			if i < _brush_voxel_paint_complexity.size() else 0.0
		out[i * 4 + 0] = c.r
		out[i * 4 + 1] = c.g
		out[i * 4 + 2] = c.b
		out[i * 4 + 3] = clampf(maxf(complexity, RENDER_ALPHA_FLOOR), RENDER_ALPHA_FLOOR, 1.0)
	return out


# ⚠ 这里曾有 `resolve_pick()`（实例序 → 四元组 → 体素下标 + 三个绘制属性字段）。
# 点选零派生后（2026-08-10）由基类统一实现：本域的紧凑表就是"画过的格子"列表
# （`build_compact_instance_list()`），实例序经它解回体素下标即可。
# 绘制属性不再随载荷带出，改由消费方问下面这个成员——载荷因此对全域同形。


## 某个体素下标上画的是什么（颜色 / complexity / collision）。未画过则返回空字典。
##
## ⚠ 属性表按**实例序**存（append-only，与 `_brush_voxels` 四元组同序），而点选给出的是
## **体素下标**——`_brush_voxel_keys` 因此存 `voxel_index → 实例序` 而不只是一个存在集合，
## 反查是 O(1)。别改回布尔集合：那样这里就得线性扫 `_brush_voxels`，
## 而它在密集笔迹下是十万量级。
func paint_attributes_for_element(voxel_index: int) -> Dictionary:
	_repair_soft_reloaded_members()
	if not _brush_voxel_keys.has(voxel_index):
		return {}
	var slot := int(_brush_voxel_keys[voxel_index])
	if slot < 0 or slot >= _brush_voxel_paint_colors.size():
		return {}
	return {
		"paint_color": _brush_voxel_paint_colors[slot],
		"complexity": _brush_voxel_paint_complexity[slot] \
			if slot < _brush_voxel_paint_complexity.size() else 0.0,
		"collision": _brush_voxel_paint_collision[slot] \
			if slot < _brush_voxel_paint_collision.size() else 0.0,
	}


## ⚠ 必须覆写：基类默认实现是 `for index in range(element_capacity())` —— 本域的
## capacity 是整网格（当前 1,048,576），一次调用就是几百毫秒的 GDScript 循环。
## 本域的"紧凑表"就是 `_brush_voxels` 本身，直接列出画过的格子。
func build_compact_instance_list() -> PackedInt32Array:
	_repair_soft_reloaded_members()
	var frame := grid_frame()
	if frame.is_empty():
		return PackedInt32Array()
	var grid: Vector3i = frame["grid_size"]
	var count := _brush_voxels.size() / 4
	var out := PackedInt32Array()
	out.resize(count)
	for i in range(count):
		var base := i * 4
		out[i] = VoxelGeneralScript.voxel_index(Vector3i(
			_brush_voxels[base], _brush_voxels[base + 1], _brush_voxels[base + 2]), grid)
	return out


# ⚠ 重写的是 `_repair_soft_reloaded_domain_members()` 而**不是**
# `_repair_soft_reloaded_members()`（后者是 PickableDomain 的模板方法，重写它会把基类
# 那半段整个顶掉且不报错）。判空必须用 `is` 不能用 `== null`。
#
# ⚠ 本域是唯一装**用户内容**的卷：这几个成员丢了 = 用户画的笔刷没了。所以修复只补空容器，
# 同时把显示快照一并作废，逼一次重建。（基类的 `_built_revision` 已在基类修复里回填。）
func _repair_soft_reloaded_domain_members() -> void:
	if not (_brush_voxels is PackedInt32Array): _brush_voxels = PackedInt32Array()
	if not (_brush_voxel_keys is Dictionary): _brush_voxel_keys = {}
	if not (_brush_voxel_paint_colors is PackedColorArray):
		_brush_voxel_paint_colors = PackedColorArray()
	if not (_brush_voxel_paint_complexity is PackedFloat32Array):
		_brush_voxel_paint_complexity = PackedFloat32Array()
	if not (_brush_voxel_paint_collision is PackedFloat32Array):
		_brush_voxel_paint_collision = PackedFloat32Array()
	if not (_display_instance_count is int): _display_instance_count = -1
