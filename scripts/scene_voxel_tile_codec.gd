extends RefCounted

const BufferUtils := preload("res://scripts/utils/buffer_utils.gd")

const RECORD_STRIDE_BYTES := 128
const SUMMARY_STRIDE_BYTES := 32
## 碰撞场双口径显式化：R8 紧凑（1B/体素）只作磁盘/回读边界格式；常驻/上传口径是
## unorm8-in-u32（每体素 1 个 uint32，量化值存低字节，见 u32_bytes_from_r8_bytes）。
const COMPLEXITY_FIELD_FORMAT_RGBA8 := "rgba8_unorm"
const COLLISION_FIELD_FORMAT_R8 := "r8_unorm"
const COLLISION_FIELD_FORMAT_UNORM8_U32 := "unorm8_u32"
const COMPLEXITY_FIELD_STRIDE_BYTES := 4
const COLLISION_FIELD_STRIDE_BYTES := 1
const COLLISION_FIELD_U32_STRIDE_BYTES := 4
const FIELD_STRIDE_BYTES := COMPLEXITY_FIELD_STRIDE_BYTES

# --- scene voxel tile GPU buffer schema（SSOT；committer/tile_store 以同名单层 re-export 引用） ---
const SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER := "scene_voxel_tile_complexity_field"
const SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER := "scene_voxel_tile_collision_field"
const SCENE_VOXEL_TILE_COMPLEXITY_FIELD_FORMAT := COMPLEXITY_FIELD_FORMAT_RGBA8
const SCENE_VOXEL_TILE_COLLISION_FIELD_FORMAT := COLLISION_FIELD_FORMAT_UNORM8_U32
const SCENE_VOXEL_TILE_COMPLEXITY_FIELD_STRIDE_BYTES := COMPLEXITY_FIELD_STRIDE_BYTES
const SCENE_VOXEL_TILE_COLLISION_FIELD_STRIDE_BYTES := COLLISION_FIELD_U32_STRIDE_BYTES
## 每个 tile 记录「哪些对象占了我」的固定槽位数。
##
## ⚠ 8 太小，实测会静默丢引用：1511 个对象铺在 3072 个 tile 上时
## `object_ref_overflow_count = 444`，`object_ref_update_reason = "object_ref_overflow"`，
## 于是 tile 的对象引用表残缺——症状是「放了几千个 autoobject，SVTile 热力图 0 occupied tile」
## （scene_placement_actor.gd 的逐批报告里也会把 pass 标成 blocked）。
##
## 抬到 32 的代价可以忽略：缓冲是 `tile_count * refs_per_tile * 4 B`，
## 3072 tile 下 98 KB → 393 KB。shader 侧不需要跟着改——
## `scene_voxel_tile_object_ref_update.glsl` 经 push constant `tile_size.w` 收这个值，
## 没有硬编码；GD 侧其余位置全部派生自本常量。
##
## 还溢出就继续抬（先看 get_svtile_gpu_status() 的 object_ref_overflow_count）。
const SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT := 32

const FLAG_SCENE := 1
const FLAG_COLLISION := 2
const FLAG_AUTO := 4
const FLAG_BRUSH := 8
const FLAG_TARGET := 16
const FLAG_ROUTING := 32
const FLAG_SCORING := 64
const FLAG_FEEDBACK := 128
const FLAG_OBJECT_REFS := 256

## 若项目设置中尚无该项，则以 default_size 注册一个 Vector3i 类型的项目设置并登记其属性信息。
static func register_project_settings(setting_name: String, default_size: Vector3i) -> void:
	if not ProjectSettings.has_setting(setting_name):
		ProjectSettings.set_setting(setting_name, default_size)

	ProjectSettings.add_property_info({
		"name": setting_name,
		"type": TYPE_VECTOR3I,
		"hint": PROPERTY_HINT_NONE,
	})

## 读取项目设置中的尺寸值（缺省用 default_size），并把每个分量下限钳到 1，返回合法的 Vector3i。
static func configured_size(setting_name: String, default_size: Vector3i) -> Vector3i:
	var value = ProjectSettings.get_setting(setting_name, default_size)
	var size := vector3i_from_value(value, default_size)
	return Vector3i(maxi(size.x, 1), maxi(size.y, 1), maxi(size.z, 1))

## 由体素网格尺寸和瓦片尺寸计算瓦片网格尺寸（每维向上取整、下限 1），即各维度上瓦片的数量。
static func tile_grid_size(grid_size: Vector3i, tile_size: Vector3i) -> Vector3i:
	return Vector3i(
		maxi(ceili(float(maxi(grid_size.x, 1)) / float(tile_size.x)), 1),
		maxi(ceili(float(maxi(grid_size.y, 1)) / float(tile_size.y)), 1),
		maxi(ceili(float(maxi(grid_size.z, 1)) / float(tile_size.z)), 1)
	)

## 把某个体素坐标映射到它所属的瓦片坐标（整除 tile_size 后钳到瓦片网格范围内）。
static func tile_coord_from_voxel(voxel_coord: Vector3i, grid_size: Vector3i, tile_size: Vector3i) -> Vector3i:
	var tile_grid := tile_grid_size(grid_size, tile_size)
	return Vector3i(
		clampi(int(voxel_coord.x / tile_size.x), 0, tile_grid.x - 1),
		clampi(int(voxel_coord.y / tile_size.y), 0, tile_grid.y - 1),
		clampi(int(voxel_coord.z / tile_size.z), 0, tile_grid.z - 1)
	)

## 将瓦片坐标（先钳到网格范围内）转换为一维线性索引；越界坐标会被夹到边界。
static func tile_index(tile_coord: Vector3i, tile_grid: Vector3i) -> int:
	var grid := Vector3i(maxi(tile_grid.x, 1), maxi(tile_grid.y, 1), maxi(tile_grid.z, 1))
	var coord := Vector3i(
		clampi(tile_coord.x, 0, grid.x - 1),
		clampi(tile_coord.y, 0, grid.y - 1),
		clampi(tile_coord.z, 0, grid.z - 1)
	)
	return tile_index_unclamped(coord, grid)

## 不做范围钳制、直接按 x + gx*(z + gz*y) 的布局把瓦片坐标线性化为索引（供已知坐标合法时使用）。
static func tile_index_unclamped(tile_coord: Vector3i, tile_grid: Vector3i) -> int:
	var grid := Vector3i(maxi(tile_grid.x, 1), maxi(tile_grid.y, 1), maxi(tile_grid.z, 1))
	return tile_coord.x + grid.x * (tile_coord.z + grid.z * tile_coord.y)

## 返回瓦片网格的瓦片总数（三个维度相乘，负数按 0 处理）。
static func tile_count(tile_grid: Vector3i) -> int:
	return maxi(tile_grid.x, 0) * maxi(tile_grid.y, 0) * maxi(tile_grid.z, 0)

## tile_index 的逆运算：把一维线性索引（先钳到合法范围）还原为瓦片坐标 (tx, ty, tz)。
static func tile_coord_from_index(tile_index: int, tile_grid: Vector3i) -> Vector3i:
	var grid := Vector3i(maxi(tile_grid.x, 1), maxi(tile_grid.y, 1), maxi(tile_grid.z, 1))
	var safe_index := clampi(tile_index, 0, maxi(tile_count(grid) - 1, 0))
	var plane := maxi(grid.x * grid.z, 1)
	var ty := int(floor(float(safe_index) / float(plane)))
	var rem := safe_index % plane
	var tz := int(floor(float(rem) / float(grid.x)))
	var tx := rem % grid.x
	return Vector3i(tx, ty, tz)

## 便捷组合：由体素坐标一步得到其所属瓦片的线性索引（= tile_coord_from_voxel 再 tile_index）。
static func tile_index_from_voxel(voxel_coord: Vector3i, grid_size: Vector3i, tile_size: Vector3i) -> int:
	var grid := tile_grid_size(grid_size, tile_size)
	return tile_index(tile_coord_from_voxel(voxel_coord, grid_size, tile_size), grid)

## 汇总某体素坐标对应瓦片的完整信息，返回 {size, grid, index, coord} 字典，便于一次取全。
static func tile_info_for_voxel(voxel_coord: Vector3i, grid_size: Vector3i, tile_size: Vector3i) -> Dictionary:
	var grid := tile_grid_size(grid_size, tile_size)
	var coord := tile_coord_from_voxel(voxel_coord, grid_size, tile_size)
	return {
		"size": tile_size,
		"grid": grid,
		"index": tile_index(coord, grid),
		"coord": coord,
	}

## 由瓦片坐标生成字符串键 "x:y:z"，用作 scene_voxel_tiles 字典的键。
static func tile_key(tile_coord: Vector3i) -> String:
	return "%d:%d:%d" % [tile_coord.x, tile_coord.y, tile_coord.z]

## 统计一条瓦片**记录**里关联的对象引用数量：有 debug id 数组就用它的长度，否则取
## debug/正式 range_count 的较大值。
##
## ⚠ 这条路只对**CPU 侧构造**的记录有意义。GPU 常驻路径的真相在
## `scene_voxel_tile_object_refs` 槽位缓冲里（每 tile 8 个固定槽，0 = 空），
## 而 `scene_voxel_tile_object_ref_update.glsl` **只写那个缓冲**，不回填 tile record 的
## `object_range_count`（record buffer 偏移 84）—— 所以对一条 GPU 回读的 record 调用本函数
## 恒得 0。要按 GPU 实况计数请用 `object_ref_counts_from_slot_bytes()`。
##
## ⚠ 曾经的坑：默认值写成 `get("auto_object_ids_debug", [])` 时，键缺席也会返回一个
## **Array**（`[]`），`ids is Array` 因此恒真 ⇒ 无条件 `return 0`，后面两个 range_count
## 分支是死码。全仓从没有人写过 `auto_object_ids_debug` 这个键，所以本函数一直恒返回 0。
static func object_ref_count(tile_record: Dictionary) -> int:
	if tile_record.is_empty():
		return 0
	if tile_record.has("auto_object_ids_debug"):
		var ids = tile_record["auto_object_ids_debug"]
		if ids is Array:
			return (ids as Array).size()
	return maxi(int(tile_record.get("object_debug_range_count", 0)), int(tile_record.get("object_range_count", 0)))


## 由 `scene_voxel_tile_object_refs` 槽位缓冲字节直接数出**逐 tile** 的非空引用数。
##
## 布局（与 `scene_voxel_tile_object_ref_update.glsl` 的 binding 1 同一契约）：
##   `object_refs[tile_index * refs_per_tile + slot]`，u32，0 = 空槽，
##   数值 ref_key = GPU AutoObject `object_id + 1`。
##
## 这是 GPU 常驻路径下**唯一**可信的 object-ref 计数源：tile record 的 `object_range_count`
## 没有任何 GPU pass 会去写。缓冲短于期望时按可用槽位截断计数（不补零伪造满格）。
static func object_ref_counts_from_slot_bytes(
	slot_bytes: PackedByteArray,
	tile_count: int,
	refs_per_tile: int = SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT
) -> PackedInt32Array:
	var counts := PackedInt32Array()
	var safe_tile_count := maxi(tile_count, 0)
	counts.resize(safe_tile_count)
	var safe_refs_per_tile := maxi(refs_per_tile, 1)
	var available_slots := int(slot_bytes.size() / 4)
	for tile_index in range(safe_tile_count):
		var slot_base := tile_index * safe_refs_per_tile
		if slot_base >= available_slots:
			break
		var slot_limit := mini(slot_base + safe_refs_per_tile, available_slots)
		var used := 0
		for slot_index in range(slot_base, slot_limit):
			if slot_bytes.decode_u32(slot_index * 4) != 0:
				used += 1
		counts[tile_index] = used
	return counts

## 计算某瓦片在体素空间的边界范围（min/max 均钳到网格内），并附带 XZ 平面的 base_rect，返回边界字典。
static func tile_bounds(tile_coord: Vector3i, grid_size: Vector3i, tile_size: Vector3i) -> Dictionary:
	var voxel_min := Vector3i(
		clampi(tile_coord.x * tile_size.x, 0, maxi(grid_size.x - 1, 0)),
		clampi(tile_coord.y * tile_size.y, 0, maxi(grid_size.y - 1, 0)),
		clampi(tile_coord.z * tile_size.z, 0, maxi(grid_size.z - 1, 0))
	)
	var voxel_max := Vector3i(
		clampi(voxel_min.x + tile_size.x, voxel_min.x + 1, maxi(grid_size.x, 1)),
		clampi(voxel_min.y + tile_size.y, voxel_min.y + 1, maxi(grid_size.y, 1)),
		clampi(voxel_min.z + tile_size.z, voxel_min.z + 1, maxi(grid_size.z, 1))
	)

	return {
		"tile_size": tile_size,
		"voxel_min": voxel_min,
		"voxel_max": voxel_max,
		"base_rect": Rect2i(
			Vector2i(voxel_min.x, voxel_min.z),
			Vector2i(maxi(voxel_max.x - voxel_min.x, 1), maxi(voxel_max.z - voxel_min.z, 1))
		),
	}

## 把多种形态的输入（字典/数组/字符串）归一化为标志字典。⚠ 不再接受整数位掩码：
## 传 int 会得到空字典并落到调用方的 default_layer 兜底，而不是按位解读。
## 纯 guidance 标志(target/routing/scoring/feedback)
## 不补默认层，否则在既无 scene 又无 collision 时补上 default_layer。
static func flags_from_value(value, default_layer: String = "scene") -> Dictionary:
	var flags := {}

	if value is Dictionary:
		for key in (value as Dictionary).keys():
			if bool((value as Dictionary).get(key, false)):
				flags[str(key)] = true
	elif value is Array:
		for item in value as Array:
			var flag_name := str(item)
			if not flag_name.is_empty():
				flags[flag_name] = true
	elif value is String:
		var flag := str(value)
		if not flag.is_empty():
			flags[flag] = true
	else:
		# 整数位掩码/null/其他类型不再被解读：过去这里静默落到 default_layer，
		# 调用方以为标记了 collision/target，实际只标了 scene —— 脏范围错位且无从追查。
		push_error("SceneVoxelTileCodec.flags_from_value: 不支持的标志值类型 typeof=%d 值=%s（仅接受 Dictionary/Array/String；整数位掩码请先经 flags_from_bits 转换）—— 继续会静默降级为 default_layer='%s'" % [typeof(value), str(value), default_layer])
		assert(false, "SceneVoxelTileCodec.flags_from_value: unsupported flag value type")
		return {}

	var guidance_only := (
		bool(flags.get("target", false))
		or bool(flags.get("routing", false))
		or bool(flags.get("scoring", false))
		or bool(flags.get("feedback", false))
	) and not flags.has("scene") and not flags.has("collision")

	if not flags.has("scene") and not flags.has("collision") and not guidance_only and not default_layer.is_empty():
		flags[default_layer] = true

	return flags

## 委托到 VoxelGeneral.vector3i_from_value（该版本已并入本函数原有的超集行为）。
static func vector3i_from_value(value, fallback: Vector3i = Vector3i.ZERO) -> Vector3i:
	return VoxelGeneral.vector3i_from_value(value, fallback)

## 按 keys 顺序在记录中查找第一个存在的键并解析为 Vector3i；全部缺失则返回 fallback。
static func first_vector3i(record: Dictionary, keys: Array[String], fallback: Vector3i = Vector3i.ZERO) -> Vector3i:
	for key in keys:
		if record.has(key):
			return vector3i_from_value(record.get(key), fallback)
	return fallback


# ============================================================
# GPU-autoobject dirty delta 解读契约(候选键表 + removed 规则 + 新旧边界解析)。
# 原 SceneVoxelTileStore._pack_gpu_autoobject_dirty_delta_words 与
# apply_gpu_autoobject_dirty_delta 各持一份逐字副本,集中于此避免漂移。
# ============================================================

const DELTA_CURRENT_MIN_KEYS: Array[String] = ["new_voxel_min", "voxel_min", "bounds_min", "new_bounds_min"]
const DELTA_CURRENT_MAX_KEYS: Array[String] = ["new_voxel_max", "voxel_max", "bounds_max", "new_bounds_max"]
const DELTA_PREVIOUS_MIN_KEYS: Array[String] = ["old_voxel_min", "previous_voxel_min", "old_bounds_min", "previous_bounds_min"]
const DELTA_PREVIOUS_MAX_KEYS: Array[String] = ["old_voxel_max", "previous_voxel_max", "old_bounds_max", "previous_bounds_max"]


## delta 是否表示对象移除:removed/freed/killed 任一为真,或显式 alive=false。
static func delta_removed(delta: Dictionary) -> bool:
	return bool(delta.get("removed", delta.get("freed", delta.get("killed", false)))) \
		or bool(delta.has("alive") and not bool(delta.get("alive", true)))


## 解析 delta 的新旧体素边界:current 键缺失时回退 previous;previous 缺失时回退 current。
## 返回 {new_min, new_max, old_min, old_max}(与原内联解析逐字段等价)。
static func delta_bounds(delta: Dictionary) -> Dictionary:
	var new_min := first_vector3i(delta, DELTA_CURRENT_MIN_KEYS, first_vector3i(delta, DELTA_PREVIOUS_MIN_KEYS, Vector3i.ZERO))
	var new_max := first_vector3i(delta, DELTA_CURRENT_MAX_KEYS, first_vector3i(delta, DELTA_PREVIOUS_MAX_KEYS, new_min + Vector3i.ONE))
	var old_min := first_vector3i(delta, DELTA_PREVIOUS_MIN_KEYS, new_min)
	var old_max := first_vector3i(delta, DELTA_PREVIOUS_MAX_KEYS, new_max)
	return {
		"new_min": new_min,
		"new_max": new_max,
		"old_min": old_min,
		"old_max": old_max,
	}

## 规整体素边界：保证 min<max、每维至少 1 体素厚，且整体钳到网格范围内，返回 {voxel_min, voxel_max}。
static func normalized_bounds(voxel_min: Vector3i, voxel_max: Vector3i, grid_size: Vector3i) -> Dictionary:
	var min_v := Vector3i(
		clampi(mini(voxel_min.x, voxel_max.x - 1), 0, maxi(grid_size.x - 1, 0)),
		clampi(mini(voxel_min.y, voxel_max.y - 1), 0, maxi(grid_size.y - 1, 0)),
		clampi(mini(voxel_min.z, voxel_max.z - 1), 0, maxi(grid_size.z - 1, 0))
	)
	var max_v := Vector3i(
		clampi(maxi(voxel_min.x + 1, voxel_max.x), min_v.x + 1, maxi(grid_size.x, 1)),
		clampi(maxi(voxel_min.y + 1, voxel_max.y), min_v.y + 1, maxi(grid_size.y, 1)),
		clampi(maxi(voxel_min.z + 1, voxel_max.z), min_v.z + 1, maxi(grid_size.z, 1))
	)
	return {
		"voxel_min": min_v,
		"voxel_max": max_v,
	}

## TargetSV 元数据（texture_size / slice_count）→ 规范 grid_size。
##
## **全仓唯一允许把 texture_size/slice_count 换成 Vector3i 的地方**（计划 §6.3）。
## 其余层的 grid_size 是 ScenePlacementActor 导出的 SSOT，不经过这里。
## 换算式 (ts, slices, ts) 顺带把「XZ 必须方形」这条隐含假设变成显式的一行：
## 磁盘布局 (slice * ts + z) * ts + x 与 VoxelGeneral.voxel_index(v, grid) 在此换算下
## 逐值相同，索引口径因此不再有第二式。
##
## 缺字段/尺寸非正一律判死并返回 fallback：旧调用方各自 get(key, 1) 兜底，
## 缺 texture_size 就按 1 建索引，后续所有缓冲尺寸校验都按错误量级通过。
static func grid_from_target_metadata(metadata: Dictionary, fallback: Vector3i = Vector3i.ZERO) -> Vector3i:
	for required_key in ["texture_size", "slice_count"]:
		if not metadata.has(required_key):
			push_error("SceneVoxelTileCodec.grid_from_target_metadata: TargetSV 元数据缺少 '%s'（现有 keys=%s）—— 拒绝按默认尺寸建索引" % [required_key, str(metadata.keys())])
			assert(false, "SceneVoxelTileCodec.grid_from_target_metadata: metadata missing dimension key")
			return fallback
	var texture_size := int(metadata["texture_size"])
	var slice_count := int(metadata["slice_count"])
	if texture_size <= 0 or slice_count <= 0:
		push_error("SceneVoxelTileCodec.grid_from_target_metadata: TargetSV 尺寸非法 texture_size=%d slice_count=%d" % [texture_size, slice_count])
		assert(false, "SceneVoxelTileCodec.grid_from_target_metadata: non-positive target dimensions")
		return fallback
	return Vector3i(texture_size, slice_count, texture_size)

## 计算存放 voxel_count 个 RGBA8 复杂度体素所需的字节数（每体素 4 字节）。
static func rgba8_byte_count(voxel_count: int) -> int:
	return maxi(voxel_count, 0) * COMPLEXITY_FIELD_STRIDE_BYTES

## 计算存放 voxel_count 个 R8 碰撞体素所需的字节数（每体素 1 字节）。
static func r8_byte_count(voxel_count: int) -> int:
	return maxi(voxel_count, 0) * COLLISION_FIELD_STRIDE_BYTES

## 计算 R8 场展开为 GPU u32 布局（每体素 1 个 uint32，即每体素恰 4 字节）后的字节数。
static func u32_field_byte_count(voxel_count: int) -> int:
	return maxi(voxel_count, 0) * 4

## 推断标量场（每体素 1 值）的体素数：给了期望值就用期望值，否则等于数组长度。
static func infer_scalar_voxel_count(values: PackedFloat32Array, expected_voxel_count: int = -1) -> int:
	if expected_voxel_count > 0:
		return expected_voxel_count
	return values.size()

## 推断复杂度场的体素数：优先用期望值；否则若长度是 4 的倍数按 vec4/体素折算，再不然按标量长度。
static func infer_complexity_voxel_count(values: PackedFloat32Array, expected_voxel_count: int = -1) -> int:
	if expected_voxel_count > 0:
		return expected_voxel_count
	if values.size() > 0 and values.size() % 4 == 0:
		return int(values.size() / 4)
	return values.size()

## 把复杂度场打包为 RGBA8 字节：源是 vec4 则逐通道编码，源是标量则存为 (1,1,1,value)，每体素输出一个 u32。
static func pack_complexity_field_rgba8_bytes(values: PackedFloat32Array, voxel_count: int = -1) -> PackedByteArray:
	var safe_count := infer_complexity_voxel_count(values, voxel_count)
	var out := PackedByteArray()
	out.resize(rgba8_byte_count(safe_count))
	var is_vec4 := values.size() >= safe_count * 4
	for i in range(safe_count):
		var color := Color(0.0, 0.0, 0.0, 0.0)
		if is_vec4:
			var base := i * 4
			color = Color(values[base + 0], values[base + 1], values[base + 2], values[base + 3])
		elif i < values.size():
			var value := values[i]
			color = Color(1.0, 1.0, 1.0, value)
		out.encode_u32(i * COMPLEXITY_FIELD_STRIDE_BYTES, BufferUtils.pack_shader_rgba8_word(color))
	return out

## 把 RGBA8 复杂度场字节解码为每体素 4 个 float（r,g,b,a 依次展开）。
## 字节数不足 voxel_count 时硬失败：以前尾部体素被静默补 0，读到的是"空体素"假象。
static func decode_complexity_field_rgba8_vec4_bytes(bytes: PackedByteArray, voxel_count: int) -> PackedFloat32Array:
	var safe_count := maxi(voxel_count, 0)
	var required := safe_count * COMPLEXITY_FIELD_STRIDE_BYTES
	if bytes.size() < required:
		push_error("SceneVoxelTileCodec.decode_complexity_field_rgba8_vec4_bytes: 复杂度场字节数不足 —— voxel_count=%d 期望 >= %d 字节，实际 %d 字节；继续解码会把尾部 %d 个体素静默补零" % [safe_count, required, bytes.size(), safe_count - int(bytes.size() / COMPLEXITY_FIELD_STRIDE_BYTES)])
		assert(false, "SceneVoxelTileCodec: complexity field byte buffer shorter than voxel_count")
		return PackedFloat32Array()
	var out := PackedFloat32Array()
	out.resize(safe_count * 4)
	var available := safe_count
	for i in range(available):
		var color := BufferUtils.shader_rgba8_word_to_color(bytes.decode_u32(i * COMPLEXITY_FIELD_STRIDE_BYTES))
		var base := i * 4
		out[base + 0] = color.r
		out[base + 1] = color.g
		out[base + 2] = color.b
		out[base + 3] = color.a
	return out

## 只取 RGBA8 复杂度场每体素的 alpha 通道，解为标量 float 数组（与标量打包路径对应）。
## 字节数不足 voxel_count 时硬失败（同 vec4 版本：静默补零会伪造空体素）。
static func decode_complexity_field_rgba8_alpha_bytes(bytes: PackedByteArray, voxel_count: int) -> PackedFloat32Array:
	var safe_count := maxi(voxel_count, 0)
	var required := safe_count * COMPLEXITY_FIELD_STRIDE_BYTES
	if bytes.size() < required:
		push_error("SceneVoxelTileCodec.decode_complexity_field_rgba8_alpha_bytes: 复杂度场字节数不足 —— voxel_count=%d 期望 >= %d 字节，实际 %d 字节；继续解码会把尾部体素静默补零" % [safe_count, required, bytes.size()])
		assert(false, "SceneVoxelTileCodec: complexity field byte buffer shorter than voxel_count")
		return PackedFloat32Array()
	var out := PackedFloat32Array()
	out.resize(safe_count)
	var available := safe_count
	for i in range(available):
		out[i] = BufferUtils.shader_rgba8_word_to_color(bytes.decode_u32(i * COMPLEXITY_FIELD_STRIDE_BYTES)).a
	return out

## RGBA8 复杂度场逐体素解码：取第 idx 个体素的整个 Color（rgb = 颜色，a = complexity）。
## 单点查询热路径（TargetSV 直选/解码/回归测试用）：按 offset 直解，不解整场。
## 越界/坏输入返回透明黑，与整场解码路径对尾部体素的语义一致。
static func decode_complexity_field_rgba8_color_at(bytes: PackedByteArray, idx: int) -> Color:
	var offset := idx * COMPLEXITY_FIELD_STRIDE_BYTES
	if idx < 0 or offset + COMPLEXITY_FIELD_STRIDE_BYTES > bytes.size():
		return Color(0.0, 0.0, 0.0, 0.0)
	return BufferUtils.shader_rgba8_word_to_color(bytes.decode_u32(offset))


## 同上，只要 alpha（complexity）。
static func decode_complexity_field_rgba8_alpha_at(bytes: PackedByteArray, idx: int) -> float:
	return clampf(decode_complexity_field_rgba8_color_at(bytes, idx).a, 0.0, 1.0)


## 把碰撞标量场量化打包为 R8 字节（每体素 1 字节，unorm8 量化），未紧凑到 4 字节对齐。
static func pack_collision_field_r8_bytes(values: PackedFloat32Array, voxel_count: int = -1) -> PackedByteArray:
	var safe_count := infer_scalar_voxel_count(values, voxel_count)
	var out := PackedByteArray()
	out.resize(r8_byte_count(safe_count))
	for i in range(mini(safe_count, values.size())):
		out[i] = BufferUtils.quantize_unorm8(values[i])
	return out

## 打包碰撞场为 GPU u32 上传格式（每体素 1 个 uint32，量化值存低字节，其余 3 字节为 0）。
## 与「pack_collision_field_r8_bytes(...) 再 u32_bytes_from_r8_bytes(...)」逐字节等价：
## 两者都只在 i < mini(safe_count, values.size()) 处写入 quantize_unorm8(values[i])，
## 其余字节由 resize 补 0。融合后省掉一次 voxel_count 级遍历与一份 R8 中间缓冲。
static func pack_collision_field_u32_bytes(values: PackedFloat32Array, voxel_count: int = -1) -> PackedByteArray:
	var safe_count := infer_scalar_voxel_count(values, voxel_count)
	var out := PackedByteArray()
	out.resize(u32_field_byte_count(safe_count))
	for i in range(mini(safe_count, values.size())):
		out[i * 4] = BufferUtils.quantize_unorm8(values[i])
	return out


# --- R8 ↔ u32 布局的整块字节重排（避开百万级逐字节 GDScript 循环） ---
#
# 借 Image 的通道转换在 C++ 侧做定步长搬运，全程不经过 Variant。等价性依据
# （Godot 源码 core/io/image.cpp::Image::convert 的 switch 分派 + _convert 模板）：
#   * FORMAT_R8 → FORMAT_RG8 走 _convert<1, false, 2, false, false, false>：
#     max_bytes = 2，rgba[0] = rofs[0]、rgba[1] = 0（i >= read_bytes 一律填 0），
#     write_alpha 为 false 故不写 255；每像素写入 wofs[0] = rofs[0]; wofs[1] = 0。
#     ⇒ 语义正好是「每字节后补 1 个 0」。做两次即「每字节后补 3 个 0」，
#       亦即小端 u32 的低字节布局（与原 out[i*4] = r8[i] 逐位相同）。
#   * FORMAT_RG8 → FORMAT_R8 走 _convert<2, false, 1, false, false, false>：
#     每像素写入 wofs[0] = rofs[0] ⇒「每 2 字节取第 0 字节」。做两次即
#     「每 4 字节取第 0 字节」（与原 out[i] = word_bytes[i*4] 逐位相同）。
#   * R8/RG8 同属 <= FORMAT_RGBA8 的字节格式组，_are_formats_compatible 为真，
#     走的是上述整块通道转换分支，不会退化到逐像素 Color 路径。
# 这条路径只做字节搬运，不做任何数值量化/归一化，因此与小端/大端无关：
# 补零位置由 _convert 显式写死，不依赖宿主字节序。
#
## Image 宽度上限（core/io/image.h：MAX_WIDTH = 1 << 24）。展开路径的中间图宽度是
## 2 * byte_count，故 byte_count 需满足 byte_count * 2 <= MAX_WIDTH；越界即回退循环。
const _STRIDE_IMAGE_MAX_WIDTH := 1 << 24
## 小缓冲走 Image 会被两次 Image 分配吃掉收益，低于该字节数直接用逐元素循环。
const _STRIDE_IMAGE_MIN_BYTES := 4096

## 把 N 字节展开为 4N 字节（每字节后补 3 个 0）。失败时返回空数组，由调用方回退循环。
static func _expand_bytes_x4(src: PackedByteArray) -> PackedByteArray:
	var n := src.size()
	if n <= 0 or n * 2 > _STRIDE_IMAGE_MAX_WIDTH:
		return PackedByteArray()
	var img := Image.create_from_data(n, 1, false, Image.FORMAT_R8, src)
	if img == null:
		return PackedByteArray()
	img.convert(Image.FORMAT_RG8)
	var half := img.get_data()
	if half.size() != n * 2:
		return PackedByteArray()
	var img2 := Image.create_from_data(half.size(), 1, false, Image.FORMAT_R8, half)
	if img2 == null:
		return PackedByteArray()
	img2.convert(Image.FORMAT_RG8)
	var full := img2.get_data()
	return full if full.size() == n * 4 else PackedByteArray()

## 从 4 * count 字节里取每 4 字节的第 0 字节，得到 count 字节。失败时返回空数组。
static func _gather_bytes_x4(src: PackedByteArray, count: int) -> PackedByteArray:
	if count <= 0 or src.size() < count * 4 or count * 2 > _STRIDE_IMAGE_MAX_WIDTH:
		return PackedByteArray()
	var quad := src if src.size() == count * 4 else src.slice(0, count * 4)
	var img := Image.create_from_data(count * 2, 1, false, Image.FORMAT_RG8, quad)
	if img == null:
		return PackedByteArray()
	img.convert(Image.FORMAT_R8)
	var half := img.get_data()
	if half.size() != count * 2:
		return PackedByteArray()
	var img2 := Image.create_from_data(count, 1, false, Image.FORMAT_RG8, half)
	if img2 == null:
		return PackedByteArray()
	img2.convert(Image.FORMAT_R8)
	var out := img2.get_data()
	return out if out.size() == count else PackedByteArray()

## 把紧凑的 R8 字节展开为 u32 布局缓冲：源第 i 字节写入 out[i*4]（小端低字节），其余 3 字节留 0。
## 源字节数不足 voxel_count 时硬失败：以前尾部体素被静默补 0（碰撞消失）。
static func u32_bytes_from_r8_bytes(r8_bytes: PackedByteArray, voxel_count: int) -> PackedByteArray:
	var out_size := u32_field_byte_count(voxel_count)
	var required := r8_byte_count(voxel_count)
	if r8_bytes.size() < required:
		push_error("SceneVoxelTileCodec.u32_bytes_from_r8_bytes: R8 源字节数不足 —— voxel_count=%d 期望 >= %d 字节，实际 %d 字节；继续展开会把尾部体素静默补零" % [voxel_count, required, r8_bytes.size()])
		assert(false, "SceneVoxelTileCodec: r8 source buffer shorter than voxel_count")
		return PackedByteArray()
	var byte_count := required
	if byte_count >= _STRIDE_IMAGE_MIN_BYTES:
		var src := r8_bytes if r8_bytes.size() == byte_count else r8_bytes.slice(0, byte_count)
		var expanded := _expand_bytes_x4(src)
		if expanded.size() == byte_count * 4:
			# byte_count <= max(voxel_count, 0) ⇒ byte_count * 4 <= out_size；
			# resize 走 resize_initialized（core/variant/variant_call.cpp 的 bind_methodv），尾部补 0。
			if expanded.size() != out_size:
				expanded.resize(out_size)
			return expanded
	var out := PackedByteArray()
	out.resize(out_size)
	for i in range(byte_count):
		out[i * 4] = r8_bytes[i]
	return out

## 逆操作：从 u32 布局缓冲取回紧凑的 R8 字节（每体素取 word 的低字节 word_bytes[i*4]）。
## 源 word 数不足 voxel_count 时硬失败（同 u32_bytes_from_r8_bytes 的理由）。
static func r8_bytes_from_u32_bytes(word_bytes: PackedByteArray, voxel_count: int) -> PackedByteArray:
	var out_size := r8_byte_count(voxel_count)
	var required := u32_field_byte_count(voxel_count)
	if word_bytes.size() < required:
		push_error("SceneVoxelTileCodec.r8_bytes_from_u32_bytes: u32 源字节数不足 —— voxel_count=%d 期望 >= %d 字节（每体素 1 个 u32），实际 %d 字节；继续压缩会把尾部体素静默补零" % [voxel_count, required, word_bytes.size()])
		assert(false, "SceneVoxelTileCodec: u32 source buffer shorter than voxel_count")
		return PackedByteArray()
	var byte_count := out_size
	if byte_count >= _STRIDE_IMAGE_MIN_BYTES:
		var gathered := _gather_bytes_x4(word_bytes, byte_count)
		if gathered.size() == byte_count:
			if gathered.size() != out_size:
				gathered.resize(out_size)
			return gathered
	var out := PackedByteArray()
	out.resize(out_size)
	for i in range(byte_count):
		out[i] = word_bytes[i * 4]
	return out

## 把 R8 碰撞场字节解码为 [0,1] 归一化 float 数组（每字节 /255）。
## 字节数不足 voxel_count 时硬失败：静默补零会把"有碰撞"的尾部体素报告成可通行。
static func decode_collision_field_r8_bytes(bytes: PackedByteArray, voxel_count: int) -> PackedFloat32Array:
	var safe_count := maxi(voxel_count, 0)
	if bytes.size() < safe_count:
		push_error("SceneVoxelTileCodec.decode_collision_field_r8_bytes: 碰撞场字节数不足 —— voxel_count=%d 期望 >= %d 字节（R8 每体素 1 字节），实际 %d 字节；继续解码会把尾部 %d 个体素静默报告为无碰撞" % [safe_count, safe_count, bytes.size(), safe_count - bytes.size()])
		assert(false, "SceneVoxelTileCodec: collision field byte buffer shorter than voxel_count")
		return PackedFloat32Array()
	var out := PackedFloat32Array()
	out.resize(safe_count)
	var available := safe_count
	for i in range(available):
		out[i] = float(bytes[i] & 0xFF) / 255.0
	return out

## R8 碰撞场逐体素解码：第 idx 字节 unorm8 → [0,1]。磁盘/回读边界口径
## （TargetSVSetup.get_collision_bytes 的 .r8 布局）；常驻/上传口径见 u32 家族。
## 与 decode_collision_field_r8_bytes 逐体素语义一致。越界/坏输入返回 0.0。
static func decode_collision_field_r8_at(bytes: PackedByteArray, idx: int) -> float:
	if idx < 0 or idx >= bytes.size():
		return 0.0
	return clampf(float(bytes[idx] & 0xFF) / 255.0, 0.0, 1.0)


## 从 u32 布局缓冲直接解码碰撞场为归一化 float（= 先压缩回紧凑 R8 再按 R8 解码）。
static func decode_collision_field_u32_bytes(word_bytes: PackedByteArray, voxel_count: int) -> PackedFloat32Array:
	var r8 := r8_bytes_from_u32_bytes(word_bytes, voxel_count)
	if r8.is_empty() and voxel_count > 0:
		# r8_bytes_from_u32_bytes 已 push_error/assert；此处只做硬失败传播，不再补零。
		return PackedFloat32Array()
	return decode_collision_field_r8_bytes(r8, voxel_count)

## 把 128 字节定长记录缓冲（GPU 常驻 tile record buffer 回读）解回瓦片字典数组，与 tile_ids 按序配对。
## 字节数与 tile_ids 不匹配时硬失败：以前会静默只解出前 N 个 tile，后面的 tile 凭空消失。
static func decode_records(bytes: PackedByteArray, tile_ids: Array[String]) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	var required := tile_ids.size() * RECORD_STRIDE_BYTES
	if bytes.size() < required or bytes.size() % RECORD_STRIDE_BYTES != 0:
		push_error("SceneVoxelTileCodec.decode_records: tile record 缓冲长度不合法 —— tile_ids=%d 期望 %d 字节（stride=%d 的整数倍），实际 %d 字节；继续解码只会得到前 %d 个 tile，其余静默丢失" % [tile_ids.size(), required, RECORD_STRIDE_BYTES, bytes.size(), int(bytes.size() / RECORD_STRIDE_BYTES)])
		assert(false, "SceneVoxelTileCodec: tile record buffer size mismatch")
		return records
	var count := tile_ids.size()

	for i in range(count):
		var base := i * RECORD_STRIDE_BYTES
		records.append({
			"scene_voxel_tile_id": tile_ids[i],
			"tile_coord": BufferUtils.decode_vec3i4(bytes, base + 0),
			"dirty_flags": flags_from_bits(bytes.decode_s32(base + 12)),
			"tile_size": BufferUtils.decode_vec3i4(bytes, base + 16),
			"epoch": bytes.decode_s32(base + 28),
			"voxel_min": BufferUtils.decode_vec3i4(bytes, base + 32),
			"last_commit_tick": bytes.decode_s32(base + 44),
			"voxel_max": BufferUtils.decode_vec3i4(bytes, base + 48),
			"write_tick": bytes.decode_s32(base + 60),
			"base_rect": Rect2i(
				Vector2i(bytes.decode_s32(base + 64), bytes.decode_s32(base + 68)),
				Vector2i(bytes.decode_s32(base + 72), bytes.decode_s32(base + 76))
			),
			"object_range_start": bytes.decode_s32(base + 80),
			"object_range_count": bytes.decode_s32(base + 84),
			"scene_voxel_count": bytes.decode_s32(base + 96),
			"collision_voxel_count": bytes.decode_s32(base + 100),
			"updated_this_commit": bytes.decode_s32(base + 108) != 0,
			"tile_hash": int(bytes.decode_u32(base + 112)),
			"dirty": bytes.decode_s32(base + 116) != 0,
		})

	return records

## 单块瓦片摘要里的两个占用计数 `(scene_voxel_count, collision_voxel_count)`。
##
## 摘要布局的事实源在本 codec（见 decode_summaries：+16 / +20）——此前三个消费方
## （SceneSVVolume 紧凑表、SVTileVolume 活跃数与显示构建）各写一份手写偏移，
## 布局一改就是三处静默错位。偏移只此一份。
## 调用方自己保证 bytes 长度足够（短读语义各家不同：跳过 / 报警 / 返回 -1）。
static func decode_summary_counts(bytes: PackedByteArray, tile_index: int) -> Vector2i:
	var base := tile_index * SUMMARY_STRIDE_BYTES
	return Vector2i(bytes.decode_s32(base + 16), bytes.decode_s32(base + 20))


## 非空砖判据的唯一定义：场景体素或碰撞体素任一 > 0。
## 三个消费方（SceneSV 紧凑表、SVTile 活跃数与显示）此前各写一份布尔式，
## 注释自承"三处不会各说各话"——靠注释维持的同源改由代码维持。
static func summary_counts_live(counts: Vector2i) -> bool:
	return counts.x > 0 or counts.y > 0


## 把 32 字节定长摘要缓冲（GPU 常驻 tile summary buffer 回读）解回摘要字典数组，与 tile_ids 按序配对。
## 字节数与 tile_ids 不匹配时硬失败（同 decode_records：静默截断会让尾部 tile 摘要凭空消失）。
static func decode_summaries(bytes: PackedByteArray, tile_ids: Array[String]) -> Array[Dictionary]:
	var summaries: Array[Dictionary] = []
	var required := tile_ids.size() * SUMMARY_STRIDE_BYTES
	if bytes.size() < required or bytes.size() % SUMMARY_STRIDE_BYTES != 0:
		push_error("SceneVoxelTileCodec.decode_summaries: tile summary 缓冲长度不合法 —— tile_ids=%d 期望 %d 字节（stride=%d 的整数倍），实际 %d 字节；继续解码只会得到前 %d 个 tile 摘要" % [tile_ids.size(), required, SUMMARY_STRIDE_BYTES, bytes.size(), int(bytes.size() / SUMMARY_STRIDE_BYTES)])
		assert(false, "SceneVoxelTileCodec: tile summary buffer size mismatch")
		return summaries
	var count := tile_ids.size()

	for i in range(count):
		var base := i * SUMMARY_STRIDE_BYTES
		summaries.append({
			"scene_voxel_tile_id": tile_ids[i],
			"complexity_minmax": Vector2(bytes.decode_float(base + 0), bytes.decode_float(base + 4)),
			"collision_minmax": Vector2(bytes.decode_float(base + 8), bytes.decode_float(base + 12)),
			"scene_voxel_count": bytes.decode_s32(base + 16),
			"collision_voxel_count": bytes.decode_s32(base + 20),
		})

	return summaries

## 把脏标志字典编码为整数位掩码（scene/collision/auto/brush/target/routing/scoring/feedback/object_refs 各占一位）。
static func flags_to_bits(dirty_flags: Dictionary) -> int:
	var bits := 0
	if bool(dirty_flags.get("scene", false)):
		bits |= FLAG_SCENE
	if bool(dirty_flags.get("collision", false)):
		bits |= FLAG_COLLISION
	if bool(dirty_flags.get("auto", false)):
		bits |= FLAG_AUTO
	if bool(dirty_flags.get("brush", false)):
		bits |= FLAG_BRUSH
	if bool(dirty_flags.get("target", false)):
		bits |= FLAG_TARGET
	if bool(dirty_flags.get("routing", false)):
		bits |= FLAG_ROUTING
	if bool(dirty_flags.get("scoring", false)):
		bits |= FLAG_SCORING
	if bool(dirty_flags.get("feedback", false)):
		bits |= FLAG_FEEDBACK
	if bool(dirty_flags.get("object_refs", false)):
		bits |= FLAG_OBJECT_REFS
	return bits

## flags_to_bits 的逆操作：把整数位掩码解回脏标志字典（每个置位对应一个标志键为 true）。
static func flags_from_bits(bits: int) -> Dictionary:
	var flags := {}
	if (bits & FLAG_SCENE) != 0:
		flags["scene"] = true
	if (bits & FLAG_COLLISION) != 0:
		flags["collision"] = true
	if (bits & FLAG_AUTO) != 0:
		flags["auto"] = true
	if (bits & FLAG_BRUSH) != 0:
		flags["brush"] = true
	if (bits & FLAG_TARGET) != 0:
		flags["target"] = true
	if (bits & FLAG_ROUTING) != 0:
		flags["routing"] = true
	if (bits & FLAG_SCORING) != 0:
		flags["scoring"] = true
	if (bits & FLAG_FEEDBACK) != 0:
		flags["feedback"] = true
	if (bits & FLAG_OBJECT_REFS) != 0:
		flags["object_refs"] = true
	return flags
