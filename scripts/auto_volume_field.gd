@tool
class_name AutoVolumeField
extends "res://scripts/pickable_domain.gd"

## 元素空间 = **体素 `grid`** 的体积抽象层（《AutoVolume 公用体积基类计划》§2.2 / §2.5）。
## 子类：`SceneSV` / `TargetSV` / `BrushSV` / `BlendSV`（后者无可视化，§1.6）。
##
## 体积抽象层与点选根（`PickableDomain`）的分工：根管「是谁、归谁、变没变、怎么进 ID pass、
## 显示几何与地形高度场怎么推」（后两项 2026-08-10 上提，Field/Tile 两支共用），
## 本层管「一格是什么、有多少格、格子怎么寻址、紧凑实例表怎么来」。
## 三个体积抽象层（Field / Tile / Anchor）**并列**，差异只有元素空间一根轴——
## 直接复用 `BufferDescriptor` 的 `KIND_*` × `DENSITY_*` 二元组，不新增枚举。
##
## ── 场对 Buffer 归 GPU 宿主，本层不再提供节点侧包装（2026-08-10 裁定）────────────
## 分配/复用/重建/释放的唯一实现是 `utils/volume_field_buffers.gd`，由真正的
## RenderingDevice 持有方（`ScenePlacementRuntime` / `SceneSVFieldStore`）直接使用。
## 本层曾有一套 configure/ensure/release/clear 包装与 field_rid/has_resident_fields
## 读口——**全仓零调用点**（连同三个子类的转发覆写一起），已删除。
## 没人读的读口不可能被可靠地保持同步，它本身就是那个"看起来像事实源"的误导物
## （同款裁定见 V5 清场的 `VOXEL_DISPLAY_KEYS`）。将来某卷真的要在节点侧暴露场对，
## 照 runtime 的形状（持有 `VolumeFieldBuffers` 实例）重建，别恢复转发链。
##
## ── 本层保证的三件事（无代码，只是保证；写在这里免得下一个人以为要补实现）──────
## 1. **背面照样命中。** 体素显示材质是 `CULL_DISABLED`（voxel_display.gd 的
##    `_apply_voxel_material`），ID pass 与它保持一致，不加正面过滤。
## 2. **透明度不参与点选。** ID pass 按全不透明处理，alpha 只影响显示。
##    `shaders/pick_id.gdshader` 本就不做 alpha test，所以这条是零代码的。
## 3. **`no_depth_test` 不泄漏进 ID pass。** 镜像节点用自己的 `ShaderMaterial`，
##    显示材质上的 `no_depth_test` 覆盖不到它。这是 `PickIdPass` 的机制，本层不得重实现。
##
## ── 不属于本层的（§2.6，别顺手塞进来）────────────────────────────────────────
## 镜像 SubViewport / own_world_3d 隔离、tonemap 逆变换补偿、MSAA·TAA·SSAA·debanding 关闭、
## 回读帧守卫、回读路线选型 —— 全是 `PickIdPass` 内部实现。
## 逐实例视距剔除 —— CPU `set_instance_transform` 与 GPU 直写互斥，归《GPU直提渲染》。

const BufferDescriptorScript := preload("res://scripts/utils/buffer_descriptor.gd")
## 子类（SceneSVVolume）经继承使用；瓦片支在 AutoVolumeTile 另有一份同名 preload。
const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")

# ⚠ 紧凑实例表缓存（_cached_instance_list / _display_cache_revision / get_instance_list）
# 已上提 PickableDomain（2026-08-10）——Tile 支同样需要，SVTile 曾为此在叶子上自建一套。
# 本层只保留体素支的 build_compact_instance_list 回退实现（见下）。


# ── 元素空间（构造期常量，不随内容变）────────────────────────────────────────

## 本域的 Buffer 排布。体素场恒为 VOXEL_FIELD。
func element_kind() -> String:
	return BufferDescriptorScript.KIND_VOXEL_FIELD


## 本域的覆盖范围。稠密场对恒为 DENSE；BrushSV 改稀疏存储后返回 SPARSE（§7.4）。
func element_density() -> String:
	return BufferDescriptorScript.DENSITY_DENSE


## Buffer 槽位数。DENSE 时等于元素数，即整网格的体素总数。
func element_capacity() -> int:
	var frame := grid_frame()
	if frame.is_empty():
		return 0
	return VoxelGeneralScript.voxel_count(frame["grid_size"])


## 活跃元素数。稠密场恒等于容量；稀疏卷需回读原子计数，由子类重写。
func live_element_count() -> int:
	return element_capacity()


## 元素下标 → 体素坐标。体素域是恒等映射，直接走全仓规范索引式的反解。
## 越界返回 Vector3i(-1, -1, -1)（不可能是合法体素坐标），不钳到末体素。
func element_to_voxel(index: int) -> Vector3i:
	var frame := grid_frame()
	if frame.is_empty():
		return Vector3i(-1, -1, -1)
	return VoxelGeneralScript.voxel_from_index(index, frame["grid_size"])


## 体素坐标 → 元素下标。`VoxelGeneral.voxel_index` 是全仓唯一的规范索引式
## （`x + gx * (z + gz * y)`），`BufferDescriptor.voxel_index` 的 xzy 分支也转发到它。
func voxel_to_element(voxel: Vector3i) -> int:
	var frame := grid_frame()
	if frame.is_empty():
		return -1
	return VoxelGeneralScript.voxel_index(voxel, frame["grid_size"])


## 一格体素的**显示中心**（节点局部空间），与 `voxel_field_instances.glsl` /
## `brush_voxel_instances.glsl` 的摆位逐项对应：`grid_origin + (voxel + 0.5) * voxel_size`，
## Y 再加本卷显示用的地形抬升（`display_terrain_height_field()`——与建显示喂 shader 的是
## 同一份缓存，见基类）。选中框摆位读它，两侧不可能漂移。
##
## ⚠ 2026-08-10 自 SceneSVVolume 上提：SceneSV 与 BrushSV 的 marker 同式（display_scale
## 都恒为 1.0）。**TargetSV 不适用本方法**——它的显示按自己的 `display_scale` 铺开
## （`get_grid_frame()` 已缩放），marker 走它自己的 `voxel_to_world()`。
##
## ⚠ 越界按 shader 的宽容处理（不加抬升 + 只 `push_error`），**不走**
## `VoxelGeneral.terrain_relative_voxel_center_to_world` —— 那条在越界时 `assert(false)`，
## 而 XZ 非方形是**配置**状态不是调用方违约，在编辑器里断言就是当场打死。
## 让 marker 与显示**一起错**，比 marker 对、显示错更好查。
##
## 取不到框架时返回 `Vector3(INF, …)`：零点是合法坐标，拿它当"取不到"会把一次失败
## 伪装成"体素在世界原点"。
func voxel_center_world(voxel: Vector3i) -> Vector3:
	var frame := grid_frame()
	if frame.is_empty():
		return Vector3(INF, INF, INF)
	var grid: Vector3i = frame["grid_size"]
	var origin: Vector3 = frame["grid_origin"]
	var cell: Vector3 = frame["voxel_size"]
	var world := origin + Vector3(
		(float(voxel.x) + 0.5) * cell.x,
		(float(voxel.y) + 0.5) * cell.y,
		(float(voxel.z) + 0.5) * cell.z)
	var height := display_terrain_height_field()
	if height.is_empty():
		return world
	var height_index := voxel.z * grid.x + voxel.x
	if height_index < 0 or height_index >= height.size():
		push_error("[%s] voxel_center_world: 高度场索引 %d 越界（长度 %d，voxel=%s，grid=%s）—— 高度场按 grid.x 边长的方形重采样，XZ 不等长时 z*grid.x+x 会整体错位。本格不加地形抬升，与 shader 的越界分支一致。" % [
			_log_name(), height_index, height.size(), str(voxel), str(grid)])
		return world
	world.y += height[height_index]
	return world


# ⚠ 这里曾有 `_voxel_pick_payload()`（体素载荷字典的统一构造：kind / voxel_index /
# voxel_coord）。点选载荷瘦身为「域 + 元素下标」后（2026-08-10）不再需要——
# 消费方拿到 element_index 自己调 `element_to_voxel()`，那是本层早就定义好的多态寻址口。


# ── 紧凑显示（§2.5-5）：体素支的回退实现 ─────────────────────────────────────
# 缓存与 get_instance_list() 在 PickableDomain；本层只定义"体素域怎么扫"。

## 扫出非空格（覆写根类的空表默认）。子类按数据源特化（SceneSV 读瓦片摘要白送的
## 非空砖计数、Brush 直接列画过的格子）；漏特化时退化为全量显示，不会静默少画。
func build_compact_instance_list() -> PackedInt32Array:
	var out := PackedInt32Array()
	var capacity := element_capacity()
	for index in range(capacity):
		if not _is_voxel_empty(index):
			out.append(index)
	return out


## 第 index 格是不是空的。子类重写；基类默认"全都不空"（= 退化回全量显示，
## 与今天的行为一致，不会因为漏重写就静默少画）。
func _is_voxel_empty(_index: int) -> bool:
	return false
