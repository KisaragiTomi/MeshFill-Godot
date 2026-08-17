@tool
class_name SVTileVolume
extends "res://scripts/auto_volume_tile.gd"

## `SPA/Volumes/SVTile` 的节点脚本（《AutoVolume 公用体积基类计划》V3 的前半）。
##
## ── 它补的是「SVTile 今天**没有节点**」这个缺口（§1.1 表格）──────────────────
## 瓦片域此前既不在 `SPA/Volumes` 下、也没有内容修订号，叠加层挂在
## `SPA/Interaction/DemoHost/SVTileOverlay`（而那个 DemoHost 已从场景里移除）。
## 本类让瓦片域第一次有了节点归属、域身份与寻址入口。
##
## ── ⚠ 本类**不持有**任何 buffer，V3 的后半才动所有权 ────────────────────────
## 瓦片 6 buffer 与 SV 场对今天同在 `SceneVoxelTileStore` 里（§1.2：它俩是同一个对象的两半）。
## 真正的劈开——场对归 SV 卷、瓦片 6 buffer 归本卷、store 退化为归约算子——需要重新穿线
## committer 的提交路径，**验收是 golden 快照**。本类先把 golden 中性的那一半就位：
## 域身份、元素空间、瓦片寻址、状态读口，全部走转发。
##
## ── ⚠ 并列 ≠ 参赛 ──────────────────────────────────────────────────────────
## 见基类 `AutoVolumeTile` 的类注释：继承 `PickableDomain` **不改**
## `unified_pick_gpu.gd` 的 `COMPETING_DOMAIN_MASK`（该文件 2026-08-10 已随旧点选路径删除）。SVTile 是 SV 的一个视图，
## 同一次命中、同一个 `ray_t`，两个都参赛只会制造一次必然的平局。
##
## ── 显示几何 / 地形高度场 / rebuild 外壳在基类（2026-08-10 上提）──────────────
## `display_cell_size()` / `display_aabb()` 曾在本文件整段重复（理由是
## "AutoVolumeTile 拿不到 AutoVolumeField 的那两个方法"）——现在算式在 PickableDomain，
## 瓦片尺度经 `AutoVolumeTile.display_cell_span()` 进入，本类只声明两个系数。

## 只取摘要 buffer 名。⚠ 不要在这里另写一个 "scene_voxel_tile_summaries" 字面量：
## 全仓已经有三份，再加一份就是第四个漂移点。
const SceneVoxelTileStoreScript := preload("res://scripts/scene_voxel_tile_store.gd")
const SUMMARY_BUFFER := SceneVoxelTileStoreScript.SCENE_VOXEL_TILE_SUMMARY_BUFFER

const DISPLAY_NODE := "SVTileOctas"

## 瓦片 cell 的填充比。八面体体积只有同 cell 方盒的 1/6，再收就看不见了；
## 留 10% 的缝让相邻瓦片的尖端不相撞，瓦片边界因此仍可辨。
const DISPLAY_FILL_RATIO := 0.9

## cell 高度下限（米）。瓦片尺度上几乎不会触发（一块瓦片 Y 跨 16 米）。
## ⚠ **不能**用它反过来撑高 X/Z——那会让 cell 不再贴合瓦片包围盒，形状即域标识这条就废了。
const DISPLAY_MIN_CELL_HEIGHT := 0.05


func domain_key() -> String:
	return SPAEditorContractScript.SELECTION_DOMAIN_SVTILE


## ⚠ 刻意默认**不显示**（基类 READY 时应用），理由**不是开销**：64 KiB 摘要回读 +
## 2048 个实例确实很轻，比 SceneSV（2 × 4 MiB + 10^6 实例）轻三个量级。
## 真正的理由是**遮挡**与规格：
##   * 一个瓦片八面体罩着 tile_size 立方个（当前 512 个）SV / TargetSV 体素，而 ID pass
##     按**深度**取胜者、且把一切当作不透明 ⇒ 默认可见会让瓦片内部大半体素静默选不中。
##     表现是"点体素选中了一块砖"，界面上看不出原因。
##   * 《点选统一》§10-6 明写「SVTile 默认不显示 ⇒ 默认不可选」。
func default_display_visible() -> bool:
	return false


func display_node_name() -> String:
	return DISPLAY_NODE


func display_fill_ratio() -> float:
	return DISPLAY_FILL_RATIO


func min_cell_height() -> float:
	return DISPLAY_MIN_CELL_HEIGHT


## 活跃（已 stamp 过）瓦片数。
##
## 瓦片是稀疏的：固定分配全部瓦片，只有被 stamp 过的才非零。store 的状态报告里
## `tile_count` 是**容量**不是活跃数，所以这里按摘要现算：`scene_voxel_count` 或
## `collision_voxel_count` 任一 > 0 即算活跃（与显示的非空砖判据、与
## `SceneSVVolume.build_compact_instance_list()` 是同一条判据，三处不会各说各话）。
##
## ⚠ 每次调用一次 `tile_count × 32 B` 的**同步 GPU 回读**（当前 64 KiB）。够便宜，
## 但别放进每帧路径。回读不到时仍如实返回 -1（"没人告诉我"），不拿容量顶上。
func live_element_count() -> int:
	var count := element_capacity()
	if count <= 0:
		return -1
	# warn_on_short = false：本方法是状态读口，可能被反复调用，短读不该刷屏。
	var summary_bytes := _read_tile_summaries(count, false)
	if summary_bytes.is_empty():
		return -1
	var live := 0
	for tile_index in range(count):
		if SceneVoxelTileCodecScript.summary_counts_live(
				SceneVoxelTileCodecScript.decode_summary_counts(summary_bytes, tile_index)):
			live += 1
	return live


## 瓦片域的内容修订号 = store 的 GPU 修订号（V3 劈开前的现状，与 `SceneSVVolume` 同源）。
## 取法收在基类的 `_svtile_gpu_revision()`（含完整理由，包括为何不能改用 `_revision`）。
func revision() -> int:
	return _svtile_gpu_revision()


## 报告的 resident 位由 GPU 侧回答（store 的 runtime_ready），不是"节点在即在场"。
func report_resident() -> bool:
	var spa := scene_placement_actor()
	return spa != null and bool(spa.get_svtile_gpu_status().get("runtime_ready", false))


## 报告行的域专属明细（取代 SPA 里那条手工合成的 SVTile 行，2026-08-10）。
##
## "ready" 在这里按 GPU 真值先写——SPA 侧只在缺席时补 `is_ready()` 默认值。
## buffers 明细 / dirty_epoch / capacity 的事实源是 store 的状态口
## （`get_svtile_gpu_status()` == `get_scene_voxel_tile_gpu_buffer_status()`），
## 本域只是把它带进自己的行；V3 后半迁移瓦片 buffer 所有权后这里就是第一手了。
func _extend_ownership_report_entry(entry: Dictionary) -> void:
	var spa := scene_placement_actor()
	var status: Dictionary = spa.get_svtile_gpu_status() if spa != null else {}
	entry["ready"] = bool(status.get("runtime_ready", false))
	entry["dirty_epoch"] = int(status.get("dirty_epoch", 0))
	entry["capacity"] = int(status.get("tile_count", 0))
	entry["buffers"] = status.get("buffers", {}).duplicate(true)


# ── 显示：瓦片八面体（《点选统一》§5.4 第 3 行）───────────────────────────────
#
# ⚠ **必须先回读**：SPA 的 GPU 栈跑在**本地 RenderingDevice**（committer 的
# `ensure_device(true, false)`），而 `VoxelDisplay` 的三个 writer 绑的是主设备。RID 不能跨设备。
# 代价：一次 `tile_count × 32 B` 回读（当前 64 KiB），比 SceneSV 的 2 × 4 MiB 小三个量级；
# 且由 `revision()` 门控，内容没变不重建。
#
# ⚠ 走 `build_colored` 而不是 `build_field_gpu`：2048 个实例在 CPU 上算中心点+颜色就是
# 2048 次循环，与 SceneSV 的 10^6 全网格是另一个量级；而 `build_field_gpu*` 要的是
# 「场 → shader 逐体素解包」，瓦片摘要**不是场**（stride 32、字段是计数与 min/max）。
#
# ⚠ **只画非空砖**：全画 = 2048 个瓦片尺度（32×16×32 米）的实体铺满世界，既看不出信息
# 也会在 ID pass 里罩住一切。因此实例序**不是** tile_index，必须经映射表解回去。


# ⚠ 这里曾有 `_instance_tile_index` 映射表 + `_display_cache_intact()` /
# `_on_display_discarded()` 两个守卫钩子 + 软重载连带修复——与 `AutoVolumeField` 的
# 紧凑表机制功能同构，只因 Tile 支够不着而在叶子上自建（审计点名）。
# 紧凑表缓存上提 `PickableDomain` 后（2026-08-10）整套塌缩：映射表就是
# `get_instance_list()`（按 `revision()` 确定性重建，"表丢了"由根类软重载连带修复兜住）。


## 紧凑实例表（覆写根类空表默认）= 非空砖的 tile_index 升序表。
## 与显示实例的对应靠「_build_display_node 按本表顺序绘制」保证；
## 非空判据走 codec 的唯一定义，与 SceneSV / live_element_count 同源。
func build_compact_instance_list() -> PackedInt32Array:
	var out := PackedInt32Array()
	var count := element_capacity()
	if count <= 0:
		return out
	var summary_bytes := _read_tile_summaries(count, false)
	if summary_bytes.is_empty():
		return out
	for tile_index in range(count):
		if SceneVoxelTileCodecScript.summary_counts_live(
				SceneVoxelTileCodecScript.decode_summary_counts(summary_bytes, tile_index)):
			out.append(tile_index)
	return out


## 建瓦片八面体显示（基类 `rebuild_display()` 模板的钩子；RD / SPA 双守卫在模板）。
func _build_display_node() -> MultiMeshInstance3D:
	var frame := grid_frame()
	var grid: Vector3i = frame["grid_size"]
	var voxel_size: Vector3 = frame["voxel_size"]
	var grid_origin: Vector3 = frame["grid_origin"]
	var size := tile_size()
	var tile_grid := tile_grid_size()
	var count := SceneVoxelTileCodecScript.tile_count(tile_grid)
	if count <= 0:
		return null
	# 实例序 == 本表序（第 n 个八面体画 live[n] 那块砖）；resolve_pick 读同一张缓存表。
	var live := get_instance_list()
	if live.is_empty():
		_warn_no_live_tiles(count)
		return null
	var summary_bytes := _read_tile_summaries(count)
	if summary_bytes.is_empty():
		return null
	var height := display_terrain_height_field()
	var centers := PackedVector3Array()
	var colors := PackedColorArray()
	for tile_index in live:
		# 摘要布局的偏移只在 codec；这里只要两个占用计数（理由见 _tile_color()）。
		var counts := SceneVoxelTileCodecScript.decode_summary_counts(summary_bytes, tile_index)
		var origin := SceneVoxelTileCodecScript.tile_coord_from_index(tile_index, tile_grid) * size
		# 末排瓦片可能不满一个 tile_size，上界按网格夹紧（与 voxel_range_of() 同式）。
		var end_voxel := Vector3i(
			mini(origin.x + size.x, grid.x),
			mini(origin.y + size.y, grid.y),
			mini(origin.z + size.z, grid.z))
		# 中心式住 tile_center_world()：选中框读的是同一条，两边不可能漂移。
		centers.append(tile_center_world(
			origin, end_voxel, grid, grid_origin, voxel_size, height))
		colors.append(_tile_color(counts.x, counts.y, end_voxel - origin))
	return VoxelDisplayScript.build_colored(
		centers,
		display_cell_size(),
		colors,
		{
			"name": DISPLAY_NODE,
			# 形状即域标识：瓦片 = 八面体。未知形状 VoxelDisplay 会判死而不是回落方盒。
			"shape": VoxelDisplayScript.SHAPE_OCTA,
			# 填充比已经乘进 display_cell_size()，这里必须是 1.0，否则乘两次。
			"fill": 1.0,
			# 聚合视图：颜色是数据不是光照。
			"unshaded": true,
			# ⚠ 刻意**不开** no_depth_test：八面体是立体的、悬在瓦片中心，不会被地形 z-fight
			# 吃掉；而开着的后果是它无条件盖住一切更近的几何。
		})


## 回读瓦片摘要（`tile_count × 32` 字节）。
##
## 字节数不足一律返回空 = 本轮不建显示，而**不是**按现有长度画一部分——后者会画出
## 一批位置合法、内容属于别的瓦片的八面体。
func _read_tile_summaries(count: int, warn_on_short: bool = true) -> PackedByteArray:
	var spa := scene_placement_actor()
	if spa == null:
		return PackedByteArray()
	var bytes := spa.read_svtile_gpu_buffer_bytes(SUMMARY_BUFFER)
	var stride := SceneVoxelTileCodecScript.SUMMARY_STRIDE_BYTES
	var required := count * stride
	if bytes.size() < required:
		if warn_on_short:
			push_warning("[SVTileVolume] 瓦片摘要字节数 %d 少于 %d（tile_count=%d stride=%d）—— 本轮不建显示。" % [
				bytes.size(), required, count, stride])
		return PackedByteArray()
	return bytes


## 摘要说"一块非空砖都没有"。两个成因在摘要里长得一模一样而后果完全不同：
##   ① 场景确实是空的（合法）⇒ 本来就不该画；
##   ② 摘要**过期** ⇒ 场里有内容却一个八面体都画不出。
## 本域**不重复** SceneSV 那次抽样判别（它要再回读 4 MiB 复杂度场）：两个域读的是同一份摘要，
## SceneSV 会在同一轮里把确证过的那条 push_error 报出来。
## ⚠ 只 push_warning、**不 assert**：对既有状态断言会当场把编辑器打死（实测踩过）。
func _warn_no_live_tiles(count: int) -> void:
	push_warning("[SVTileVolume] %d 个瓦片全部报 scene_voxel_count == 0 且 collision_voxel_count == 0 —— 本轮不画任何八面体。可能是场景确实为空，也可能是瓦片摘要过期（成因详见 SceneSVVolume._warn_if_summaries_are_stale）。" % count)


## 一块砖的**显示中心**（节点局部空间）。建显示（`_build_display_node()`）与选中框
## （`SPASelectionHost._svtile_marker_transform()`）**必须**共用本函数。
##
## ⚠ 漏了会怎样：两边各算一遍中心式，任一处的 `+0.5` 口径或取列方式漂移，表现就是
## 八面体与选中框错开半块砖（当前 8 m），而两个数都合法、都不报错。
## 旧的 SelectionHost 那份把 `center_voxel.y` 硬写 0.0，于是框贴地、八面体在砖中心
## （y-tile 1 差 24 m）—— 那正是本函数存在的理由。**Y 不是特例，与 XZ 同式。**
##
## `end_voxel` 是**开区间上界**（= `tile_bounds().voxel_max`，也 = `voxel_range_of().max_exclusive`）。
## `voxel_float_center_to_world` 的口径是「体素 v 的中心是 v+0.5」，而 `(origin+end)*0.5`
## 正是这些中心的中点，两者一致，不要再另加 0.5。
static func tile_center_world(
	origin_voxel: Vector3i,
	end_voxel: Vector3i,
	grid: Vector3i,
	grid_origin: Vector3,
	voxel_size: Vector3,
	height: PackedFloat32Array
) -> Vector3:
	var center_voxel := Vector3(
		float(origin_voxel.x + end_voxel.x) * 0.5,
		float(origin_voxel.y + end_voxel.y) * 0.5,
		float(origin_voxel.z + end_voxel.z) * 0.5)
	var world := VoxelGeneralScript.voxel_float_center_to_world(center_voxel, grid_origin, voxel_size)
	world.y += terrain_lift(height, grid, center_voxel)
	return world


## 瓦片中心那一列的地形抬升。
##
## ⚠ 一个瓦片罩着 `tile_size.x × tile_size.z` 列，各列高度不同；这里取的是**中心列**
## 这一个代表值，与 `element_to_voxel()` 是同一种有损映射。地形起伏大于瓦片尺度时，
## 八面体会与它罩住的体素有可见错位——看图时别据此判位。
##
## ⚠ 公开（去掉下划线）是因为选中框要走**同一条**有损映射。让 SelectionHost 自己抄
## 一份的表现是：地形起伏大的地方框和砖各偏各的，而两个数都合法。
static func terrain_lift(height: PackedFloat32Array, grid: Vector3i, center_voxel: Vector3) -> float:
	if height.is_empty():
		return 0.0
	var hx := clampi(int(center_voxel.x), 0, maxi(grid.x - 1, 0))
	var hz := clampi(int(center_voxel.z), 0, maxi(grid.z - 1, 0))
	var index := hz * grid.x + hx
	if index < 0 or index >= height.size():
		return 0.0
	return height[index]


## 瓦片颜色。**按占用密度**，不按 `complexity_minmax`。
##
## 为什么不用 complexity_minmax：它是一对**极值**——一块砖里只要有一格满复杂度，整块就顶到
## 最红，于是"装了 1 格"和"装了 500 格"在 2048 块砖上会迅速饱和成同一个色。而聚合视图
## 要回答的恰恰是后者。
##
## 为什么用计数：除以该砖**实际覆盖**的体素数就是占用率，天然落在 [0,1]；而且它与
## `SceneSVVolume.build_compact_instance_list()` 的非空砖判据**同源**——两个域用同一判据，
## 不会出现"SV 画了一片体素、SVTile 却说这砖是空的"。
##
## span 用夹紧后的实际覆盖范围而不是 `tile_size`：末排瓦片不满一整块，
## 拿固定的 512 当分母会让边缘瓦片永远显得比中间空。
static func _tile_color(scene_count: int, collision_count: int, span: Vector3i) -> Color:
	var capacity := maxi(span.x, 1) * maxi(span.y, 1) * maxi(span.z, 1)
	var denom := float(maxi(capacity, 1))
	var scene_ratio := clampf(float(scene_count) / denom, 0.0, 1.0)
	var collision_ratio := clampf(float(collision_count) / denom, 0.0, 1.0)
	var density := maxf(scene_ratio, collision_ratio)
	# 蓝（稀）→ 青绿（场景体素多）→ 橙红（碰撞多）；alpha 随密度增强。
	return Color(
		0.16 + 0.80 * collision_ratio,
		0.40 + 0.50 * scene_ratio,
		0.92 - 0.62 * density,
		0.20 + 0.55 * density)


# ── 点选 ─────────────────────────────────────────────────────────────────────
#
# ⚠ 这里曾有 `resolve_pick()`（实例序 → tile_index + tile_coord / tile_size /
# voxel_min / voxel_max_exclusive 的丰富载荷）。点选零派生后（2026-08-10）由基类统一
# 实现：载荷只回「域 + element_index（即 tile_index）」，覆盖范围由消费方调本域的
# `voxel_range_of()` 现取——那本来就是 `AutoVolumeTile` 定义好的多态口。
#
# ⚠ 「**不给代表体素**」这条语义**没有变**，只是换了保证方式：八面体是瓦片尺度的，
# 命中点不对应任何单格，塞一个代表体素会被下游按体素起算的记录构建口当成"射线真的
# 打中的那一格"。现在统一载荷里根本没有 voxel 字段，消费方必须显式调 `voxel_range_of()`
# 要范围 —— 从"靠本域克制不发"变成"结构上发不出"。


# ⚠ 本类不再有自有成员（映射表随紧凑表机制上提根类，2026-08-10）——软重载修复
# 由 PickableDomain 的模板方法全权处理，这里不重写任何自愈钩子。
