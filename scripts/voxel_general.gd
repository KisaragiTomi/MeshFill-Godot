@tool
class_name VoxelGeneral
extends RefCounted

## 通用体素工具集合（与场景体素 SV 系统无关的纯体素原语）。
## 包含：
##   - 坐标空间换算（原 common_voxel_space.gd 内容，已合并于此）
##   - 通用体素常量与无状态原语（自 scene_voxel_committer.gd 抽取）
## 注：旧 common_voxel_space.gd 兼容垫片（曾 extends 本类）已删除，全项目体素索引/坐标映射统一直接使用 VoxelGeneral。

const MIN_VOXEL_SIZE := 0.0001

## 体素被视为“已占用”的阈值（complexity/collision 超过该值即非空）。
const VOXEL_OCCUPIED_EPSILON := 0.01

## 每个体素单元承载的 RGBA 通道数。
const CHANNEL_COUNT := 4


# ============================================================
# 坐标空间换算（原 common_voxel_space.gd）
# ============================================================

static func safe_voxel_size(voxel_size: Vector3) -> Vector3:
	return Vector3(
		maxf(voxel_size.x, MIN_VOXEL_SIZE),
		maxf(voxel_size.y, MIN_VOXEL_SIZE),
		maxf(voxel_size.z, MIN_VOXEL_SIZE)
	)


static func default_grid_origin(capture_size: float) -> Vector3:
	var half := capture_size * 0.5
	return Vector3(-half, 0.0, -half)


static func voxel_size_for_resolution(capture_size: float, resolution: int, y_size: float = 1.0) -> Vector3:
	var res := maxi(resolution, 1)
	var xz_size := capture_size / float(res)
	return Vector3(xz_size, maxf(y_size, MIN_VOXEL_SIZE), xz_size)


static func voxel_count(grid_size: Vector3i) -> int:
	return maxi(grid_size.x, 0) * maxi(grid_size.y, 0) * maxi(grid_size.z, 0)


static func voxel_index(voxel_pos: Vector3i, grid_size: Vector3i) -> int:
	return voxel_pos.x + grid_size.x * (voxel_pos.z + grid_size.z * voxel_pos.y)


static func voxel_from_index(index: int, grid_size: Vector3i) -> Vector3i:
	var grid := Vector3i(maxi(grid_size.x, 1), maxi(grid_size.y, 1), maxi(grid_size.z, 1))
	var safe_index := clampi(index, 0, maxi(voxel_count(grid) - 1, 0))
	var plane := maxi(grid.x * grid.z, 1)
	var y := int(floor(float(safe_index) / float(plane)))
	var rem := safe_index % plane
	var z := int(floor(float(rem) / float(grid.x)))
	var x := rem % grid.x
	return Vector3i(x, y, z)


static func world_to_voxel(
	world_pos: Vector3,
	grid_origin: Vector3,
	voxel_size: Vector3,
	grid_size: Vector3i,
	clamp_y: bool = true
) -> Vector3i:
	var size := safe_voxel_size(voxel_size)
	var grid := Vector3i(maxi(grid_size.x, 1), maxi(grid_size.y, 1), maxi(grid_size.z, 1))
	var local := world_pos - grid_origin
	var y := floori(local.y / size.y)
	if clamp_y:
		y = clampi(y, 0, grid.y - 1)
	else:
		y = maxi(y, 0)
	return Vector3i(
		clampi(floori(local.x / size.x), 0, grid.x - 1),
		y,
		clampi(floori(local.z / size.z), 0, grid.z - 1)
	)


static func voxel_to_world(voxel_pos: Vector3i, grid_origin: Vector3, voxel_size: Vector3) -> Vector3:
	var size := safe_voxel_size(voxel_size)
	return grid_origin + Vector3(
		float(voxel_pos.x) * size.x,
		float(voxel_pos.y) * size.y,
		float(voxel_pos.z) * size.z
	)


static func voxel_center_to_world(voxel_pos: Vector3i, grid_origin: Vector3, voxel_size: Vector3) -> Vector3:
	return voxel_float_center_to_world(
		Vector3(float(voxel_pos.x) + 0.5, float(voxel_pos.y) + 0.5, float(voxel_pos.z) + 0.5),
		grid_origin,
		voxel_size
	)


static func voxel_float_center_to_world(voxel_center: Vector3, grid_origin: Vector3, voxel_size: Vector3) -> Vector3:
	var size := safe_voxel_size(voxel_size)
	return grid_origin + Vector3(
		voxel_center.x * size.x,
		voxel_center.y * size.y,
		voxel_center.z * size.z
	)


static func world_to_voxel_center(world_pos: Vector3, grid_origin: Vector3, voxel_size: Vector3) -> Vector3:
	var size := safe_voxel_size(voxel_size)
	var local := world_pos - grid_origin
	return Vector3(
		local.x / size.x - 0.5,
		local.y / size.y - 0.5,
		local.z / size.z - 0.5
	)


static func voxel_span_to_world_size(span: Vector3i, voxel_size: Vector3) -> Vector3:
	var size := safe_voxel_size(voxel_size)
	return Vector3(
		float(span.x) * size.x,
		float(span.y) * size.y,
		float(span.z) * size.z
	)


static func voxel_center_to_world_xz(
	voxel_pos: Vector3i,
	grid_origin: Vector3,
	voxel_size: Vector3,
	y: float = 0.0
) -> Vector3:
	return voxel_float_center_to_world_xz(
		Vector3(float(voxel_pos.x) + 0.5, float(voxel_pos.y) + 0.5, float(voxel_pos.z) + 0.5),
		grid_origin,
		voxel_size,
		y
	)


static func voxel_float_center_to_world_xz(
	voxel_center: Vector3,
	grid_origin: Vector3,
	voxel_size: Vector3,
	y: float = 0.0
) -> Vector3:
	var size := safe_voxel_size(voxel_size)
	return Vector3(
		grid_origin.x + voxel_center.x * size.x,
		y,
		grid_origin.z + voxel_center.z * size.z
	)


static func world_to_volume_pixel(
	world_pos: Vector3,
	resolution: int,
	grid_origin: Vector3,
	voxel_size: Vector3
) -> Vector2i:
	var res := maxi(resolution, 1)
	var voxel := world_to_voxel(
		world_pos,
		grid_origin,
		voxel_size,
		Vector3i(res, 1, res),
		false
	)
	return Vector2i(voxel.x, voxel.z)


static func volume_pixel_to_world(
	voxel_xz: Vector2i,
	grid_origin: Vector3,
	voxel_size: Vector3,
	y: float = 0.0
) -> Vector3:
	var size := safe_voxel_size(voxel_size)
	return grid_origin + Vector3(
		float(voxel_xz.x) * size.x,
		y,
		float(voxel_xz.y) * size.z
	)


static func world_to_texture_pixel(world_pos: Vector3, capture_size: float, resolution: int) -> Vector2i:
	var res := maxi(resolution, 1)
	var size := maxf(capture_size, MIN_VOXEL_SIZE)
	var half := size * 0.5
	return Vector2i(
		clampi(floori((world_pos.x + half) / size * float(res)), 0, res - 1),
		clampi(floori((world_pos.z + half) / size * float(res)), 0, res - 1)
	)


static func texture_pixel_size(capture_size: float, resolution: int) -> float:
	return maxf(capture_size, MIN_VOXEL_SIZE) / float(maxi(resolution, 1))


static func world_radius_to_texture_radius(radius_m: float, capture_size: float, resolution: int, minimum: int = 1) -> int:
	var pixel_size := texture_pixel_size(capture_size, resolution)
	return maxi(minimum, ceili(maxf(radius_m, 0.0) / pixel_size))


static func world_offset_to_voxels(offset: Vector3, voxel_size: Vector3) -> Vector3i:
	var size := safe_voxel_size(voxel_size)
	return Vector3i(
		roundi(offset.x / size.x),
		roundi(offset.y / size.y),
		roundi(offset.z / size.z)
	)


static func radius_to_voxels(radius: float, voxel_size: Vector3) -> Vector3i:
	var r := maxf(radius, 0.0)
	if r <= 0.0:
		return Vector3i.ZERO
	var size := safe_voxel_size(voxel_size)
	return Vector3i(
		ceili(r / size.x),
		ceili(r / size.y),
		ceili(r / size.z)
	)


static func base_pixel_to_volume_pixel(base_px: Vector2i, base_resolution: int, xz_resolution: int) -> Vector2i:
	var base_res := maxi(base_resolution, 1)
	var xz_res := maxi(xz_resolution, 1)
	return Vector2i(
		clampi(int(float(base_px.x) / float(base_res) * float(xz_res)), 0, xz_res - 1),
		clampi(int(float(base_px.y) / float(base_res) * float(xz_res)), 0, xz_res - 1)
	)


static func base_radius_to_volume_radius(radius_px: int, base_resolution: int, xz_resolution: int) -> int:
	if radius_px <= 0:
		return 0
	return maxi(1, ceili(float(radius_px) / float(maxi(base_resolution, 1)) * float(maxi(xz_resolution, 1))))


# ============================================================
# 通用体素原语（自 scene_voxel_committer.gd 抽取，无状态、非 SV 专用）
# ============================================================

## 判断通道索引是否在有效范围内 [0, CHANNEL_COUNT)。
static func is_valid_channel(channel: int) -> bool:
	return channel >= 0 and channel < CHANNEL_COUNT


## 创建指定分辨率的空白 R32 (FORMAT_RF) 图像并填 0。
## 原 scene_voxel_committer._create_collision_image，本质是通用单通道浮点图。
static func create_r32_image(resolution: int) -> Image:
	var safe_res := maxi(resolution, 1)
	var img := Image.create(safe_res, safe_res, false, Image.FORMAT_RF)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	return img


## 从任意类型值（Vector3i / Vector3 / Array / Dictionary）解析出 Vector3i，失败回退 fallback。
## 原 scene_voxel_committer._vector3i_from_value。
static func vector3i_from_value(value, fallback: Vector3i = Vector3i.ZERO) -> Vector3i:
	if value is Vector3i:
		return value as Vector3i

	if value is Vector3:
		var v := value as Vector3
		return Vector3i(roundi(v.x), roundi(v.y), roundi(v.z))

	if value is Array:
		var arr := value as Array
		if arr.size() >= 3:
			return Vector3i(int(arr[0]), int(arr[1]), int(arr[2]))

	if value is Dictionary:
		var dict := value as Dictionary
		return Vector3i(
			int(dict.get("x", fallback.x)),
			int(dict.get("y", fallback.y)),
			int(dict.get("z", fallback.z))
		)

	return fallback


# ============================================================
# 碰撞记录几何原语（自 scene_voxel_committer.gd 抽取，无状态、按显式参数传入网格信息）
# ============================================================

## 计算碰撞记录的有效半径（半径减腐蚀加膨胀）。原 scene_voxel_committer._collision_effective_radius。
static func collision_effective_radius(collision: Dictionary) -> float:
	var radius := maxf(float(collision.get("radius", 0.0)), 0.0)
	var erosion := maxf(float(collision.get("erosion_radius", 0.0)), 0.0)
	var dilation := maxf(float(collision.get("dilation_radius", 0.0)), 0.0)
	if erosion > 0.0 and radius <= erosion:
		return 0.0
	return maxf(radius - erosion, 0.0) + dilation


## 判断碰撞记录是否为点采样类型（含 voxel/local_pos/voxel_offset 字段）。
static func is_point_collision_sample(collision: Dictionary) -> bool:
	return collision.has("voxel") or collision.has("local_pos") or collision.has("voxel_offset")


## 从碰撞记录中提取本地体素坐标（voxel / local_pos / voxel_offset）。
static func collision_local_voxel(collision: Dictionary) -> Vector3i:
	return vector3i_from_value(collision.get("voxel", collision.get("local_pos", collision.get("voxel_offset", Vector3i.ZERO))), Vector3i.ZERO)


## 计算碰撞层在底图上的基础像素坐标：点采样类型叠加本地偏移并按 base_res 裁剪。
static func collision_layer_base_px(base_px: Vector2i, collision: Dictionary, base_res: int) -> Vector2i:
	if not is_point_collision_sample(collision):
		return base_px
	var local := collision_local_voxel(collision)
	return Vector2i(
		clampi(base_px.x + local.x, 0, base_res - 1),
		clampi(base_px.y + local.z, 0, base_res - 1)
	)


## 计算碰撞记录的像素半径：点采样优先用 radius_px 字段，否则按有效半径换算。
static func collision_radius_px(collision: Dictionary, capture_size: float, base_res: int) -> int:
	if is_point_collision_sample(collision):
		return maxi(int(collision.get("radius_px", 0)), 0)
	if collision.has("radius_px"):
		return maxi(int(collision.radius_px), 1)
	return maxi(1, world_radius_to_texture_radius(collision_effective_radius(collision), capture_size, base_res))


## 将单通道标量字段扩展为 vec4(rgba) 交错格式：RGB 填白、标量作为 alpha。
## 原 scene_voxel_committer._expand_complexity_field_to_vec4（旧浮点复杂度场兼容路径）。
static func expand_scalar_field_to_vec4(field: PackedFloat32Array) -> PackedFloat32Array:
	var voxel_count := field.size()
	var result := PackedFloat32Array()
	result.resize(voxel_count * 4)
	for i in range(voxel_count):
		var base := i * 4
		result[base + 0] = 1.0
		result[base + 1] = 1.0
		result[base + 2] = 1.0
		result[base + 3] = clampf(field[i], 0.0, 1.0)
	return result
