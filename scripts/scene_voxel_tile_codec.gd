extends RefCounted

const BufferUtils := preload("res://scripts/utils/buffer_utils.gd")
const HashUtils := preload("res://scripts/utils/hash_utils.gd")

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
const SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT := 8

const FLAG_SCENE := 1
const FLAG_COLLISION := 2
const FLAG_AUTO := 4
const FLAG_BRUSH := 8
const FLAG_TARGET := 16
const FLAG_ROUTING := 32
const FLAG_SCORING := 64
const FLAG_FEEDBACK := 128
const FLAG_OBJECT_REFS := 256
const FLAG_MASK := 512

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

## 统计一条瓦片记录里关联的对象引用数量：优先用 debug id 数组长度，否则取 debug/正式 range_count 的较大值。
static func object_ref_count(tile_record: Dictionary) -> int:
	if tile_record.is_empty():
		return 0
	var ids = tile_record.get("auto_object_ids_debug", [])
	if ids is Array:
		return (ids as Array).size()
	return maxi(int(tile_record.get("object_debug_range_count", 0)), int(tile_record.get("object_range_count", 0)))

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

## 把多种形态的输入（字典/数组/字符串/整数掩码）归一化为标志字典；纯 guidance 标志(target/routing/scoring/feedback)
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
	elif value is int:
		if int(value) != 0:
			flags["mask"] = int(value)

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

## 判断记录中是否至少存在 keys 里的任意一个键。
static func has_any_key(record: Dictionary, keys: Array[String]) -> bool:
	for key in keys:
		if record.has(key):
			return true
	return false


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

## 把 RGBA8 复杂度场字节解码为每体素 4 个 float（r,g,b,a 依次展开），越界部分保持 0。
static func decode_complexity_field_rgba8_vec4_bytes(bytes: PackedByteArray, voxel_count: int) -> PackedFloat32Array:
	var safe_count := maxi(voxel_count, 0)
	var out := PackedFloat32Array()
	out.resize(safe_count * 4)
	var available := mini(safe_count, int(bytes.size() / COMPLEXITY_FIELD_STRIDE_BYTES))
	for i in range(available):
		var color := BufferUtils.shader_rgba8_word_to_color(bytes.decode_u32(i * COMPLEXITY_FIELD_STRIDE_BYTES))
		var base := i * 4
		out[base + 0] = color.r
		out[base + 1] = color.g
		out[base + 2] = color.b
		out[base + 3] = color.a
	return out

## 只取 RGBA8 复杂度场每体素的 alpha 通道，解为标量 float 数组（与标量打包路径对应）。
static func decode_complexity_field_rgba8_alpha_bytes(bytes: PackedByteArray, voxel_count: int) -> PackedFloat32Array:
	var safe_count := maxi(voxel_count, 0)
	var out := PackedFloat32Array()
	out.resize(safe_count)
	var available := mini(safe_count, int(bytes.size() / COMPLEXITY_FIELD_STRIDE_BYTES))
	for i in range(available):
		out[i] = BufferUtils.shader_rgba8_word_to_color(bytes.decode_u32(i * COMPLEXITY_FIELD_STRIDE_BYTES)).a
	return out

## 把碰撞标量场量化打包为 R8 字节（每体素 1 字节，unorm8 量化），未紧凑到 4 字节对齐。
static func pack_collision_field_r8_bytes(values: PackedFloat32Array, voxel_count: int = -1) -> PackedByteArray:
	var safe_count := infer_scalar_voxel_count(values, voxel_count)
	var out := PackedByteArray()
	out.resize(r8_byte_count(safe_count))
	for i in range(mini(safe_count, values.size())):
		out[i] = BufferUtils.quantize_unorm8(values[i])
	return out

## 打包碰撞场为 R8 后展开成 GPU u32 上传格式（每体素 1 个 uint32，量化值存低字节）。
static func pack_collision_field_u32_bytes(values: PackedFloat32Array, voxel_count: int = -1) -> PackedByteArray:
	var safe_count := infer_scalar_voxel_count(values, voxel_count)
	return u32_bytes_from_r8_bytes(pack_collision_field_r8_bytes(values, safe_count), safe_count)

## 把紧凑的 R8 字节展开为 u32 布局缓冲：源第 i 字节写入 out[i*4]（小端低字节），其余 3 字节留 0。
static func u32_bytes_from_r8_bytes(r8_bytes: PackedByteArray, voxel_count: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(u32_field_byte_count(voxel_count))
	var byte_count := mini(r8_bytes.size(), r8_byte_count(voxel_count))
	for i in range(byte_count):
		out[i * 4] = r8_bytes[i]
	return out

## 逆操作：从 u32 布局缓冲取回紧凑的 R8 字节（每体素取 word 的低字节 word_bytes[i*4]）。
static func r8_bytes_from_u32_bytes(word_bytes: PackedByteArray, voxel_count: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(r8_byte_count(voxel_count))
	var byte_count := mini(out.size(), int(word_bytes.size() / 4))
	for i in range(byte_count):
		out[i] = word_bytes[i * 4]
	return out

## 把 R8 碰撞场字节解码为 [0,1] 归一化 float 数组（每字节 /255）。
static func decode_collision_field_r8_bytes(bytes: PackedByteArray, voxel_count: int) -> PackedFloat32Array:
	var safe_count := maxi(voxel_count, 0)
	var out := PackedFloat32Array()
	out.resize(safe_count)
	var available := mini(safe_count, bytes.size())
	for i in range(available):
		out[i] = float(bytes[i] & 0xFF) / 255.0
	return out

## 从 u32 布局缓冲直接解码碰撞场为归一化 float（= 先压缩回紧凑 R8 再按 R8 解码）。
static func decode_collision_field_u32_bytes(word_bytes: PackedByteArray, voxel_count: int) -> PackedFloat32Array:
	return decode_collision_field_r8_bytes(r8_bytes_from_u32_bytes(word_bytes, voxel_count), voxel_count)

## 取瓦片字典的所有键转为字符串并排序，得到确定性的瓦片 id 列表（保证打包/解包顺序一致）。
static func sorted_tile_ids(scene_voxel_tiles: Dictionary) -> Array[String]:
	var ids: Array[String] = []
	for raw_id in scene_voxel_tiles.keys():
		ids.append(str(raw_id))
	ids.sort()
	return ids

## 把每个瓦片记录序列化为 128 字节定长结构（坐标/尺寸/边界/脏标志/各类 tick/计数/哈希等），供 GPU SSBO 读取。
static func pack_record_bytes(tile_ids: Array[String], scene_voxel_tiles: Dictionary, default_tile_size: Vector3i) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(tile_ids.size() * RECORD_STRIDE_BYTES)

	for i in range(tile_ids.size()):
		var tile_key := tile_ids[i]
		var tile: Dictionary = scene_voxel_tiles.get(tile_key, {})
		var base := i * RECORD_STRIDE_BYTES
		var tile_coord: Vector3i = tile.get("tile_coord", Vector3i.ZERO)
		var tile_size: Vector3i = tile.get("tile_size", default_tile_size)
		var voxel_min: Vector3i = tile.get("voxel_min", Vector3i.ZERO)
		var voxel_max: Vector3i = tile.get("voxel_max", voxel_min + Vector3i.ONE)
		var base_rect: Rect2i = tile.get("base_rect", Rect2i())
		var dirty_flags: Dictionary = tile.get("dirty_flags", {})

		BufferUtils.encode_vec3i4_with_w(bytes, base + 0, tile_coord, flags_to_bits(dirty_flags))
		BufferUtils.encode_vec3i4_with_w(bytes, base + 16, tile_size, int(tile.get("epoch", 0)))
		BufferUtils.encode_vec3i4_with_w(bytes, base + 32, voxel_min, int(tile.get("last_commit_tick", 0)))
		BufferUtils.encode_vec3i4_with_w(bytes, base + 48, voxel_max, int(tile.get("write_tick", 0)))
		bytes.encode_s32(base + 64, base_rect.position.x)
		bytes.encode_s32(base + 68, base_rect.position.y)
		bytes.encode_s32(base + 72, base_rect.size.x)
		bytes.encode_s32(base + 76, base_rect.size.y)
		bytes.encode_s32(base + 80, int(tile.get("object_range_start", 0)))
		bytes.encode_s32(base + 84, int(tile.get("object_range_count", 0)))
		bytes.encode_s32(base + 88, 0)
		bytes.encode_s32(base + 92, 0)
		bytes.encode_s32(base + 96, int(tile.get("scene_voxel_count", 0)))
		bytes.encode_s32(base + 100, int(tile.get("collision_voxel_count", 0)))
		bytes.encode_s32(base + 104, 0)  # was non_empty
		bytes.encode_s32(base + 108, 1 if bool(tile.get("updated_this_commit", false)) else 0)
		bytes.encode_u32(base + 112, HashUtils.stable_u32_from_string(tile_key))
		bytes.encode_s32(base + 116, 1 if bool(tile.get("dirty", false)) else 0)
		bytes.encode_s32(base + 120, 0)
		bytes.encode_s32(base + 124, 0)

	return bytes

## 把每个瓦片的摘要序列化为 32 字节定长结构（复杂度/碰撞的 min-max 与场景/碰撞体素计数）。
static func pack_summary_bytes(tile_ids: Array[String], scene_voxel_tiles: Dictionary) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(tile_ids.size() * SUMMARY_STRIDE_BYTES)

	for i in range(tile_ids.size()):
		var tile: Dictionary = scene_voxel_tiles.get(tile_ids[i], {})
		var complexity_minmax: Vector2 = tile.get("complexity_minmax", Vector2.ZERO)
		var collision_minmax: Vector2 = tile.get("collision_minmax", Vector2.ZERO)
		var base := i * SUMMARY_STRIDE_BYTES

		bytes.encode_float(base + 0, complexity_minmax.x)
		bytes.encode_float(base + 4, complexity_minmax.y)
		bytes.encode_float(base + 8, collision_minmax.x)
		bytes.encode_float(base + 12, collision_minmax.y)
		bytes.encode_s32(base + 16, int(tile.get("scene_voxel_count", 0)))
		bytes.encode_s32(base + 20, int(tile.get("collision_voxel_count", 0)))
		bytes.encode_s32(base + 24, 0)  # was non_empty
		bytes.encode_s32(base + 28, 0)

	return bytes

## 从瓦片 id 列表中筛出被标记为 dirty（需重新提交）的瓦片 id 子集。
static func dirty_tile_ids(tile_ids: Array[String], scene_voxel_tiles: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for i in range(tile_ids.size()):
		var tile: Dictionary = scene_voxel_tiles.get(tile_ids[i], {})
		if bool(tile.get("dirty", false)):
			result.append(tile_ids[i])
	return result

## pack_record_bytes 的逆操作：把 128 字节定长记录缓冲解回瓦片字典数组，与 tile_ids 按序配对。
static func decode_records(bytes: PackedByteArray, tile_ids: Array[String]) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	var available_bytes := mini(bytes.size(), tile_ids.size() * RECORD_STRIDE_BYTES)
	available_bytes -= available_bytes % RECORD_STRIDE_BYTES
	var count := mini(tile_ids.size(), int(available_bytes / RECORD_STRIDE_BYTES))

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

## pack_summary_bytes 的逆操作：把 32 字节定长摘要缓冲解回摘要字典数组，与 tile_ids 按序配对。
static func decode_summaries(bytes: PackedByteArray, tile_ids: Array[String]) -> Array[Dictionary]:
	var summaries: Array[Dictionary] = []
	var available_bytes := mini(bytes.size(), tile_ids.size() * SUMMARY_STRIDE_BYTES)
	available_bytes -= available_bytes % SUMMARY_STRIDE_BYTES
	var count := mini(tile_ids.size(), int(available_bytes / SUMMARY_STRIDE_BYTES))

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

## 把脏标志字典编码为整数位掩码（scene/collision/auto/brush/target/routing/scoring/feedback/object_refs/mask 各占一位）。
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
	if int(dirty_flags.get("mask", 0)) != 0:
		bits |= FLAG_MASK
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
	if (bits & FLAG_MASK) != 0:
		flags["mask"] = true
	return flags

## 把有符号整数按位重解释为无符号 32 位数值（负数加 2^32），用于以 u32 语义处理 word。
static func _u32_word(value: int) -> int:
	return value if value >= 0 else value + 4294967296
