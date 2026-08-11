@tool
class_name VoxelGeneral
extends RefCounted

## 通用体素工具集合（与场景体素 SV 系统无关的纯体素原语）。
## 包含：
##   - 坐标空间换算（原 voxel space helper 内容，已合并于此）
##   - 通用体素常量与无状态原语（自 scene_voxel_committer.gd 抽取）
## 注：旧 voxel space helper 兼容垫片（曾 extends 本类）已删除，全项目体素索引/坐标映射统一直接使用 VoxelGeneral。

const ProfileRecordSchemaScript := preload("res://scripts/utils/profile_record_schema.gd")

const MIN_VOXEL_SIZE := 0.0001

## 体素被视为“已占用”的阈值（complexity/collision 超过该值即非空）。
const VOXEL_OCCUPIED_EPSILON := 0.01

## 每个体素单元承载的 RGBA 通道数。
const CHANNEL_COUNT := 4

const DEFAULT_TILE_SIZE := 8


# ============================================================
# 坐标空间换算（原 voxel space helper）
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


static func tile_grid_size_for_grid(grid_size: Vector3i, tile_size: int = DEFAULT_TILE_SIZE) -> Vector3i:
	var safe_tile_size := maxi(tile_size, 1)
	return Vector3i(
		ceili(float(maxi(grid_size.x, 0)) / float(safe_tile_size)),
		ceili(float(maxi(grid_size.y, 0)) / float(safe_tile_size)),
		ceili(float(maxi(grid_size.z, 0)) / float(safe_tile_size))
	)


static func voxel_index(voxel_pos: Vector3i, grid_size: Vector3i) -> int:
	return voxel_pos.x + grid_size.x * (voxel_pos.z + grid_size.z * voxel_pos.y)


## 索引越界返回 Vector3i(-1, -1, -1)（不可能是合法体素坐标）。
## 原先 clampi 到末体素——越界索引会静默指向网格里一个真实存在的体素，脏数据无从分辨。
static func voxel_from_index(index: int, grid_size: Vector3i) -> Vector3i:
	if grid_size.x <= 0 or grid_size.y <= 0 or grid_size.z <= 0:
		push_error("VoxelGeneral.voxel_from_index: grid_size 含非正分量 %s —— 无法反解索引 %d" % [str(grid_size), index])
		assert(false, "VoxelGeneral.voxel_from_index: non-positive grid size")
		return Vector3i(-1, -1, -1)
	var grid := grid_size
	var total := voxel_count(grid)
	if index < 0 or index >= total:
		push_error("VoxelGeneral.voxel_from_index: 索引越界 index=%d 网格 %s 共 %d 体素 —— 拒绝钳到末体素" % [index, str(grid), total])
		assert(false, "VoxelGeneral.voxel_from_index: index out of range")
		return Vector3i(-1, -1, -1)
	var safe_index := index
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


## height_scale：高度场是世界单位的原始地形高度，而消费方（TargetSV 显示/拾取）整条链
## 按 display_scale 缩放，故偏移量是 terrain * height_scale。缺省 1.0 = 不缩放，
## 与既有调用方（volume_score_fine_selection）逐位不变。
static func terrain_relative_voxel_center_to_world(
	voxel_pos: Vector3i,
	grid_size: Vector3i,
	grid_origin: Vector3,
	voxel_size: Vector3,
	terrain_height: PackedFloat32Array,
	height_scale: float = 1.0
) -> Vector3:
	var world := voxel_center_to_world(voxel_pos, grid_origin, voxel_size)
	# terrain_height 为空 = 该场景本就没有地形（调用方合法状态），不加偏移即可。
	if terrain_height.is_empty():
		return world
	# 有地形却索引不到 ⟹ 高度场长度与 grid_size 不匹配；原先静默跳过加高，
	# 结果是「一部分体素贴地、另一部分悬在 y=0」这种半对半错的位置。
	var height_index := voxel_pos.z * grid_size.x + voxel_pos.x
	if height_index < 0 or height_index >= terrain_height.size():
		push_error("VoxelGeneral.terrain_relative_voxel_center_to_world: 高度场索引越界 index=%d 长度 %d（voxel=%s, grid_size=%s）—— 高度场与网格尺寸不匹配" % [height_index, terrain_height.size(), str(voxel_pos), str(grid_size)])
		assert(false, "VoxelGeneral.terrain_relative_voxel_center_to_world: terrain height index out of range")
		return world
	world.y += terrain_height[height_index] * height_scale
	return world


## 规范框架 × 显示尺度：原点与格距同乘，网格尺寸不变。
##
## display_scale 是显示侧的整体缩放（TargetSVSetup / MeshFillBrush 各有自己的 @export）。
## 位置类量必须同乘同一个因子，否则「体素中心」与「网格原点」会按不同尺度铺开。
## 地形相对的那一段不在这里：它逐列变化，由 terrain_relative_voxel_center_to_world 的
## height_scale 承担（与本函数取同一个 display_scale）。
static func scaled_grid_frame(
	grid_size: Vector3i,
	grid_origin: Vector3,
	voxel_size: Vector3,
	display_scale: float = 1.0
) -> Dictionary:
	var scale := display_scale
	return {
		"grid_size": Vector3i(maxi(grid_size.x, 1), maxi(grid_size.y, 1), maxi(grid_size.z, 1)),
		"voxel_size": safe_voxel_size(voxel_size * scale),
		"grid_origin": grid_origin * scale,
	}


## 「体素中心端点铺满 capture」的铺开式 → 规范坐标框架 (grid_origin, voxel_size)。
##
## ⚠ **仅测试夹具在用**：生产路径的框架一律来自 ScenePlacementActor 的导出网格
## （TargetSV 走 get_grid_frame → scaled_grid_frame）。端点式与 SPA 那套只在 capture
## 恰好差一格时才等价（当前资产 1020/255 == 1024/256 == 4.0 纯属参数凑巧），
## 让任何生产代码再从 capture 推框架都会把「两套推导式」养回来。
##   voxel_size  = (capture*s/(N-1), vertical_span*s/N_y, capture*s/(N-1))
##   grid_origin = -capture*s/2 - voxel_size/2   （XZ；Y 只给体素带自身，地形相对段由
##                 terrain_relative_voxel_center_to_world 的 height_scale 承担）
static func grid_frame_from_capture_endpoints(
	grid_size: Vector3i,
	capture_size: float,
	vertical_span: float,
	display_scale: float = 1.0
) -> Dictionary:
	var grid := Vector3i(maxi(grid_size.x, 1), maxi(grid_size.y, 1), maxi(grid_size.z, 1))
	var span_x := capture_size * display_scale
	var span_z := capture_size * display_scale
	var voxel_size := safe_voxel_size(Vector3(
		span_x / maxf(float(grid.x - 1), 1.0),
		vertical_span * display_scale / float(grid.y),
		span_z / maxf(float(grid.z - 1), 1.0)
	))
	return {
		"grid_size": grid,
		"voxel_size": voxel_size,
		"grid_origin": Vector3(
			-0.5 * span_x - 0.5 * voxel_size.x,
			0.0,
			-0.5 * span_z - 0.5 * voxel_size.z
		),
	}


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


static func texture_pixel_size(capture_size: float, resolution: int) -> float:
	return maxf(capture_size, MIN_VOXEL_SIZE) / float(maxi(resolution, 1))


static func world_radius_to_texture_radius(radius_m: float, capture_size: float, resolution: int, minimum: int = 1) -> int:
	var pixel_size := texture_pixel_size(capture_size, resolution)
	return maxi(minimum, ceili(maxf(radius_m, 0.0) / pixel_size))


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
## 从多种输入（Vector3i/Vector3/Vector2i/Vector2/Array/Dictionary）解析出 Vector3i；缺失分量用 fallback 补齐。
## Dictionary 支持 x/y/z 或 r/g/b 键；2 分量输入映射到 x、z（y 取 fallback.y）。原 SceneVoxelTileCodec 的超集版本已并入此处。
static func vector3i_from_value(value, fallback: Vector3i = Vector3i.ZERO) -> Vector3i:
	if value is Vector3i:
		return value as Vector3i
	if value is Vector3:
		var v := value as Vector3
		return Vector3i(roundi(v.x), roundi(v.y), roundi(v.z))
	if value is Vector2i:
		var v2i := value as Vector2i
		return Vector3i(v2i.x, fallback.y, v2i.y)
	if value is Vector2:
		var v2 := value as Vector2
		return Vector3i(roundi(v2.x), fallback.y, roundi(v2.y))
	if value is Array:
		var arr := value as Array
		if arr.size() >= 3:
			return Vector3i(int(arr[0]), int(arr[1]), int(arr[2]))
		if arr.size() >= 2:
			return Vector3i(int(arr[0]), fallback.y, int(arr[1]))
	if value is Dictionary:
		var dict := value as Dictionary
		return Vector3i(
			int(dict.get("x", dict.get("r", fallback.x))),
			int(dict.get("y", dict.get("g", fallback.y))),
			int(dict.get("z", dict.get("b", fallback.z)))
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


## 判断碰撞记录是否为点采样类型（含任一 ProfileRecordSchema.LOCAL_POSITION_KEYS 字段）。
static func is_point_collision_sample(collision: Dictionary) -> bool:
	return ProfileRecordSchemaScript.has_local_position(collision)


## 从碰撞记录中提取本地体素坐标（按 ProfileRecordSchema.LOCAL_POSITION_KEYS 兜底顺序）。
static func collision_local_voxel(collision: Dictionary) -> Vector3i:
	return vector3i_from_value(ProfileRecordSchemaScript.local_position_value(collision, Vector3i.ZERO), Vector3i.ZERO)


## 计算碰撞层在底图上的基础像素坐标：点采样类型叠加本地偏移并按 base_res 裁剪。
static func collision_layer_base_px(base_px: Vector2i, collision: Dictionary, base_res: int) -> Vector2i:
	if not is_point_collision_sample(collision):
		return base_px
	var local := collision_local_voxel(collision)
	return Vector2i(
		clampi(base_px.x + local.x, 0, base_res - 1),
		clampi(base_px.y + local.z, 0, base_res - 1)
	)


## 规范化碰撞采样数组：深拷贝后补齐 voxel / collision_strength / weight 字段。
## 任一条目不是字典、或不是点采样（box/cylinder 原语已停止支持）⟹ 整批作废并返回空数组
## （原为静默/告警跳过该条，剖面少几个点、资产照常参与摆放，碰撞判定偏松且无从察觉）。
## 原 AssetDescriptor.normalize_collision / AutoVoxelProfile.normalize_collision / SharedPropertyType._normalize_collision（三份逐字重复）。
static func normalize_collision_samples(source: Array, _default_radius: float = 0.0) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for index in range(source.size()):
		var raw_collision = source[index]
		if not raw_collision is Dictionary:
			push_error("VoxelGeneral.normalize_collision_samples: 条目 [%d] 不是 Dictionary（类型 %d），共 %d 条 —— 碰撞剖面整批作废" % [index, typeof(raw_collision), source.size()])
			assert(false, "VoxelGeneral.normalize_collision_samples: non-dictionary entry")
			result.clear()
			return result
		var collision := (raw_collision as Dictionary).duplicate(true)
		if not is_point_collision_sample(collision):
			push_error("VoxelGeneral.normalize_collision_samples: 条目 [%d] 不含局部坐标键 %s（box/cylinder 原语已停止支持），共 %d 条 —— 碰撞剖面整批作废；请重新 bake 该资产" % [index, str(ProfileRecordSchemaScript.LOCAL_POSITION_KEYS), source.size()])
			assert(false, "VoxelGeneral.normalize_collision_samples: non-point collision entry")
			result.clear()
			return result
		var voxel := collision_local_voxel(collision)
		collision["voxel"] = voxel              # local voxel coordinate
		# 必须走 ProfileRecordSchema.collision_strength 这个 SSOT 访问器：它的查找链是
		# collision_strength → legacy "collision" → DEFAULT_COLLISION_STRENGTH。
		# 原写法只查 collision_strength、缺键即回退 DEFAULT_COLLISION_STRENGTH(=1.0)，
		# 于是 voxelizer / FBX 导入产出的条目（fbx_voxel_import_service 写的是 "collision" 键，
		# 不写 collision_strength）里一个真实的 0 碰撞会被当成"缺省"而改写成满碰撞——
		# 无碰撞资产（草）被静默变成实心，且 0.3 这类中间值同样被抹成 1.0。
		collision[ProfileRecordSchemaScript.COLLISION_STRENGTH_KEY] = \
			ProfileRecordSchemaScript.collision_strength(collision)
		if not collision.has("weight"):
			collision["weight"] = ProfileRecordSchemaScript.DEFAULT_SAMPLE_WEIGHT           # placement sample weight
		result.append(collision)
	return result


## 只补不裁：数组不足 expected 时零填充到 expected；已够长原样返回（不拷贝）。
## 原 prefilter/_ensure_float_array 与 SPA._ensure_float_array（去掉死的 maxi 分支）合并。
static func pad_float_array(arr: PackedFloat32Array, expected: int) -> PackedFloat32Array:
	if arr.size() >= expected:
		return arr
	var result := arr.duplicate()
	result.resize(expected)
	return result


## 精确重设：拷贝后 resize 到 expected_size（不足补零、超出截断）。
## 原 VPG._normalize_float_array。
static func fit_float_array(values: PackedFloat32Array, expected_size: int) -> PackedFloat32Array:
	var result := values.duplicate()
	result.resize(expected_size)
	return result
