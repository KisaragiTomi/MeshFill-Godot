@tool
class_name AutoVolumeTile
extends "res://scripts/pickable_domain.gd"

## 元素空间 = **瓦片 `grid / tile_size`** 的体积抽象层（《AutoVolume 公用体积基类计划》§2.2）。
## 对应元素 `SVTile`：一个瓦片一条记录，承载 记录/摘要/object-ref/dirty 等 6 个 buffer。
##
## ── ⚠ 并列 ≠ 参赛（计划 §5-2，落地时最容易踩反的一条）────────────────────────
## `AutoVolumeTile` 与 `AutoVolumeField` 在类型结构上**并列**，但这**不改**
## `unified_pick_gpu.gd` 的 `COMPETING_DOMAIN_MASK`（该文件 2026-08-10 已随旧点选路径删除）。那份裁定
## 说的是「`SVTILE` 是 `SV` 的一个视图，不是独立卷：同一次命中、同一个 `ray_t`」——
## 裁的是 **ray_t 参赛资格**，不是继承关系。两个都参赛只会制造一次必然的平局。
## 胜者是 SV 时，由 CPU 按当前模式决定呈现成 sv 还是 svtile。
## **不要**因为"它现在也是个 PickableDomain 了"就把 `BIT_SVTILE` 加进竞争掩码。
##
## ── 不持有对 SceneSV 的引用（计划 §1.2）────────────────────────────────────
## 劈开 `SceneVoxelTileStore` 之后，场对归 SV 卷、瓦片 6 buffer 归本卷。
## 本卷**不**存一个指向 SceneSV 的指针，需要知道"我覆盖了哪些 SV 体素"时，
## 按自身瓦片坐标现算（`voxel_range_of()`）。存指针等于把刚劈开的两半又粘回去。
##
## ── 瓦片尺寸是配置驱动的 ────────────────────────────────────────────────────
## 不是写死的 8。事实源是项目设置 `meshfill/scene_voxel_tile/size_voxels`
## （默认 (8,8,8)），经 `SceneVoxelTileCodec.configured_size()` 读。
## 硬编码 8 的后果是配置改了之后，本域算出的瓦片坐标与 store/shader 的对不上——
## 数值都合法，只是指向别的瓦片。

const BufferDescriptorScript := preload("res://scripts/utils/buffer_descriptor.gd")
const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")

## 与 SceneVoxelTileStore / SceneVoxelCommitter 逐字相同的一对：设置键 + 默认值。
## ⚠ 三处必须同步；本域自行读设置而不是问 store 要，是因为劈开后本域就是瓦片元数据的
## 所有者，反过来问 store 会重新建立那条刚被切断的依赖。
const SCENE_VOXEL_TILE_SIZE_SETTING := "meshfill/scene_voxel_tile/size_voxels"
const DEFAULT_SCENE_VOXEL_TILE_SIZE := Vector3i(8, 8, 8)


# ── 元素空间 ─────────────────────────────────────────────────────────────────

func element_kind() -> String:
	return BufferDescriptorScript.KIND_TILE_METADATA


## 瓦片元数据是稀疏的：固定分配全部瓦片，但只有被 stamp 过的瓦片才非零。
func element_density() -> String:
	return BufferDescriptorScript.DENSITY_SPARSE


## 瓦片总数（固定拓扑，全网格铺满）。
func element_capacity() -> int:
	return SceneVoxelTileCodecScript.tile_count(tile_grid_size())


## 瓦片下标 → 该瓦片**原点**体素的坐标。
##
## ⚠ 这是一个有损映射：一个瓦片罩着 tile_size 立方个体素，反解只能给出一个代表点。
## 需要整段范围的调用方走 `voxel_range_of()`，别拿这个点当"瓦片的位置"去做包含判定。
func element_to_voxel(index: int) -> Vector3i:
	var tile_coord := SceneVoxelTileCodecScript.tile_coord_from_index(index, tile_grid_size())
	return tile_coord * tile_size()


## 体素坐标 → 它所属瓦片的下标。
func voxel_to_element(voxel: Vector3i) -> int:
	var frame := grid_frame()
	if frame.is_empty():
		return -1
	return SceneVoxelTileCodecScript.tile_index_from_voxel(voxel, frame["grid_size"], tile_size())


## 活跃瓦片数需回读 GPU 计数，由持有 buffer 的子类重写；基类如实返回 -1
## （"没人告诉我"），而不是拿容量顶上——那会让"全部瓦片都活着"看起来是一个事实。
func live_element_count() -> int:
	return -1


# ── 瓦片几何 ─────────────────────────────────────────────────────────────────

## 一个瓦片罩多少体素。事实源是项目设置，不是常量 8。
func tile_size() -> Vector3i:
	return SceneVoxelTileCodecScript.configured_size(
		SCENE_VOXEL_TILE_SIZE_SETTING, DEFAULT_SCENE_VOXEL_TILE_SIZE)


## 显示 cell 的基准跨度 = **一块瓦片**的世界尺寸（覆写根类的"一格体素"）。
## 根类的 `display_cell_size()` / `display_aabb()` 拿它推导，瓦片支因此不必再抄一份算式
## （SVTileVolume 曾整段重复，理由是"AutoVolumeTile 拿不到 AutoVolumeField 的那两个方法"）。
##
## ⚠ 拿体素尺寸当 cell 会画出一批散落的小几何：位置在瓦片中心、大小是体素，
## 每个值都合法，只是根本不代表那块砖（SVTileVolume 落地记实测）。
func display_cell_span() -> Vector3:
	var frame := grid_frame()
	if frame.is_empty():
		return Vector3.ZERO
	return VoxelGeneralScript.voxel_span_to_world_size(tile_size(), frame["voxel_size"])


## 瓦片网格维度（= ceil(grid_size / tile_size)，逐轴至少 1）。
func tile_grid_size() -> Vector3i:
	var frame := grid_frame()
	if frame.is_empty():
		return Vector3i.ZERO
	return SceneVoxelTileCodecScript.tile_grid_size(frame["grid_size"], tile_size())


## 第 index 个瓦片覆盖的体素范围，返回 `{min, max_exclusive}`（体素坐标）。
##
## 这是「不持有 SceneSV 引用」那条约束的兑现方式：需要知道自己罩着哪些 SV 体素时现算，
## 而不是存一个指向场对的指针。上界按网格夹紧——末排瓦片可能不满一个 tile_size。
func voxel_range_of(index: int) -> Dictionary:
	var frame := grid_frame()
	if frame.is_empty():
		return {}
	var grid: Vector3i = frame["grid_size"]
	var size := tile_size()
	var origin := SceneVoxelTileCodecScript.tile_coord_from_index(index, tile_grid_size()) * size
	return {
		"min": origin,
		"max_exclusive": Vector3i(
			mini(origin.x + size.x, grid.x),
			mini(origin.y + size.y, grid.y),
			mini(origin.z + size.z, grid.z)),
	}
