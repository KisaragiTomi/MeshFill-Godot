@tool
class_name SceneSVFieldStore
extends "res://scripts/godot_compute_shader_base.gd"

## **SceneSV 场对的 GPU 侧所有者**：complexity（rgba8）+ collision（unorm8_u32）两块常驻缓冲，
## 连同它们的分配、地形基底播种、重置、释放与状态元数据。
## 《AutoVolume 公用体积基类计划》§1.2 / V3 的后半。
##
## ── 它从哪来 ────────────────────────────────────────────────────────────────
## 此前场对与瓦片 6 buffer 同住在 `SceneVoxelTileStore` 里——计划 §1.2 的原话是
## 「`SV` 与 `SVTile` 今天是同一个对象的两半」。劈开后：
##   * 场对 → 本类（`SceneSVVolume` 的事实源）
##   * 瓦片 6 buffer → 仍在 `SceneVoxelTileStore`（`SVTileVolume` 的事实源）
##   * `SceneVoxelTileStore` 退化为**归约算子**：reduce / compact / object-ref / dirty 那几趟，
##     对场对只剩转发。
##
## ── 为什么不是 `VolumeFieldBuffers` ─────────────────────────────────────────
## `VolumeFieldBuffers`（§2.5-7）吃掉的是 BrushSV / BlendSV 那两处**逐字同款**的分配段。
## SceneSV 有它们没有的三样东西，硬套会把这三样挤掉：
##   1. **碰撞场不是零填充**，而是以地形基底做种子（GPU 直写优先、CPU 字节兜底）。
##      「没有地形基底」是合法状态、返回全零；「有基底但没烘进去」是硬失败、绝不用全零顶上
##      ——那会把整张地形报告成可通行。
##   2. **逐阶段耗时打点**，经 `initialization_phases_ms()` 对外暴露。
##   3. **7 项状态元数据**（rid / byte_size / upload_byte_size / init_source / record_count /
##      stride / hash）要按既有报告形状原样交回给 store 合并。
## 本类因此自己实现分配，但状态存放收敛成**一张按场名索引的表**，不再是 7 张并列 Dictionary。
##
## ── ⚠ 设备必须与 committer / field_builder 同一个 ────────────────────────────
## 地形种子的 GPU 直写路径是「本类建 RID → `field_builder` 的 pass 往里写」。
## 两者不同设备时，`storage_buffer_uninitialized` 出来的 RID 会被另一个设备的 pass 绑定。
## 所以本类**不自己 acquire 设备**，由 `SceneVoxelTileStore` 把它那一份 `_rd` 借进来
## （`attach_rendering_device(rd, false)`，owns=false）。

const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")

const COMPLEXITY_FIELD_BUFFER := SceneVoxelTileCodecScript.SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER
const COLLISION_FIELD_BUFFER := SceneVoxelTileCodecScript.SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER
const FIELD_BUFFER_NAMES := [COMPLEXITY_FIELD_BUFFER, COLLISION_FIELD_BUFFER]

const COMPLEXITY_STRIDE_BYTES := SceneVoxelTileCodecScript.SCENE_VOXEL_TILE_COMPLEXITY_FIELD_STRIDE_BYTES
const COLLISION_STRIDE_BYTES := SceneVoxelTileCodecScript.SCENE_VOXEL_TILE_COLLISION_FIELD_STRIDE_BYTES
const COMPLEXITY_FIELD_FORMAT := SceneVoxelTileCodecScript.SCENE_VOXEL_TILE_COMPLEXITY_FIELD_FORMAT
const COLLISION_FIELD_FORMAT := SceneVoxelTileCodecScript.SCENE_VOXEL_TILE_COLLISION_FIELD_FORMAT
const COLLISION_FIELD_UPLOAD_STRIDE_BYTES := SceneVoxelTileCodecScript.COLLISION_FIELD_U32_STRIDE_BYTES

## ⚠ committer 与 grid_owner 都是**借用**，本类不管它们的生命周期。
## committer 只用来取地形基底图与 field_builder（种子路径）；grid_owner 只用来取 grid_size。
var _committer: Object = null
var _grid_owner: Object = null

## 场名 → {rid, byte_size, upload_byte_size, init_source, record_count, stride, hash}。
## 取代了此前 7 张并列 Dictionary —— 两块 buffer 的元数据本来就该是一条记录。
var _fields: Dictionary = {}
var _last_error := ""
var _last_creation_phases_ms: Dictionary = {}


func _init() -> void:
	log_name = "SceneSVFieldStore"


## 借入 committer 与 grid_owner。设备由 `attach_rendering_device()` 单独借入。
func configure(committer: Object, grid_owner: Object) -> void:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	_committer = committer
	_grid_owner = grid_owner


func last_error() -> String:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	return _last_error


func initialization_phases_ms() -> Dictionary:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	return _last_creation_phases_ms.duplicate(true)


static func is_field_buffer(buffer_name: String) -> bool:
	return FIELD_BUFFER_NAMES.has(buffer_name)


func rid_of(buffer_name: String) -> RID:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	var entry: Dictionary = _fields.get(buffer_name, {})
	return entry.get("rid", RID())


func byte_size_of(buffer_name: String) -> int:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	var entry: Dictionary = _fields.get(buffer_name, {})
	return int(entry.get("byte_size", 0))


## 回读一整块场。⚠ 百万级体素时是多兆字节的同步回读，只该出现在显式诊断路径上。
func read_field_bytes(buffer_name: String) -> PackedByteArray:
	return read_buffer_bytes(rid_of(buffer_name), 0, byte_size_of(buffer_name))


## 两块场的状态条目，**形状与 SceneVoxelTileStore 报告里的其余 6 项逐字一致**——
## store 直接把它 merge 进 `buffers`，报告的外观因此完全不变。
##
## ⚠ `reused_names` 必须由 store 传进来：「上一次上传有没有复用这块 buffer」是**上传时序**的
## 事实，事实源是 store 的 `_scene_voxel_tile_gpu_last_reused_buffers`（它按
## `ensure_resident_field_buffers()` 返回的 `created` 标志填）。本类只持有 buffer 本身，
## 不知道 store 那一趟上传是复用还是重建——在这里硬写 false 会让报告里
## `reused_last_upload` 与 `resident_field_buffers_reused` 静默变成恒假。
func status_entries(reused_names: Array = []) -> Dictionary:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	var out := {}
	for buffer_name in FIELD_BUFFER_NAMES:
		var entry: Dictionary = _fields.get(buffer_name, {})
		var rid: RID = entry.get("rid", RID())
		var byte_size := int(entry.get("byte_size", 0))
		out[buffer_name] = {
			"rid_valid": rid.is_valid(),
			"record_count": int(entry.get("record_count", 0)),
			"stride_bytes": int(entry.get("stride", 0)),
			"byte_size": byte_size,
			"logical_byte_size": byte_size,
			"upload_byte_size": int(entry.get("upload_byte_size", 0)),
			"initialization_source": str(entry.get("init_source", "unknown")),
			"content_hash": int(entry.get("hash", 0)),
			"reused_last_upload": reused_names.has(buffer_name),
			"format": COMPLEXITY_FIELD_FORMAT if buffer_name == COMPLEXITY_FIELD_BUFFER else COLLISION_FIELD_FORMAT,
			"upload_stride_bytes": COMPLEXITY_STRIDE_BYTES if buffer_name == COMPLEXITY_FIELD_BUFFER else COLLISION_FIELD_UPLOAD_STRIDE_BYTES,
		}
	return out


## 常驻场对的目标体素数（= grid_owner 网格的体素总数）。
func resident_voxel_count() -> int:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	var grid := _grid_size()
	return maxi(grid.x, 0) * maxi(grid.y, 0) * maxi(grid.z, 0)


func _grid_size() -> Vector3i:
	if _grid_owner == null:
		push_error("[SceneSVFieldStore] _grid_size: _grid_owner 为 null —— 调用点在 configure() 之后，出现即装配已断。")
		assert(false, "SceneSVFieldStore._grid_size: _grid_owner == null")
		return Vector3i.ZERO
	return _grid_owner.grid_size


## 确保场对存在（仅缺失/体素数变化时重建）。复杂度场零填充，碰撞场以地形基底播种。
##
## 返回 `{complexity_field_buffer, collision_field_buffer, voxel_count, created}`；
## 失败返回空字典并把成因写进 `last_error()`（与旧实现的失败口径一致：
## 顶层不 assert，由 store 侧的调用方决定怎么报）。
func ensure_fields() -> Dictionary:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	if get_rendering_device() == null:
		_last_error = "no_rendering_device"
		push_error("[SceneSVFieldStore] ensure_fields: 无可用 RenderingDevice —— 常驻 field buffer 无法创建")
		assert(false, "SceneSVFieldStore: no RenderingDevice for resident field buffers")
		return {}
	var voxel_count := resident_voxel_count()
	if voxel_count <= 0:
		_last_error = "non_positive_voxel_count"
		push_error("[SceneSVFieldStore] ensure_fields: 体素总数非正（grid_size=%s → voxel_count=%d）—— 网格尺寸不可信" % [
			str(_grid_size()), voxel_count])
		assert(false, "SceneSVFieldStore: non-positive resident field voxel count")
		return {}

	var complexity_byte_count := voxel_count * COMPLEXITY_STRIDE_BYTES
	var collision_byte_count := SceneVoxelTileCodecScript.u32_field_byte_count(voxel_count)
	# 命中判据与旧实现一致：拿**登记的字节数**比对，而不是存下来的 voxel_count。
	if _is_current(COMPLEXITY_FIELD_BUFFER, complexity_byte_count) \
			and _is_current(COLLISION_FIELD_BUFFER, collision_byte_count):
		return _summary(voxel_count, false)

	var total_t0_usec := Time.get_ticks_usec()
	var phase_t0_usec := total_t0_usec
	_last_creation_phases_ms = {}
	release_fields()
	_last_creation_phases_ms["erase_old_buffers"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0

	phase_t0_usec = Time.get_ticks_usec()
	var complexity_bytes := PackedByteArray()
	complexity_bytes.resize(complexity_byte_count)
	_last_creation_phases_ms["allocate_complexity_bytes"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0

	phase_t0_usec = Time.get_ticks_usec()
	var ok := _create_from_bytes(
		COMPLEXITY_FIELD_BUFFER, complexity_bytes, voxel_count, COMPLEXITY_STRIDE_BYTES)
	_last_creation_phases_ms["create_complexity_buffer"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0

	phase_t0_usec = Time.get_ticks_usec()
	if not _create_collision_field(voxel_count, collision_byte_count):
		return {}
	_last_creation_phases_ms["create_and_seed_collision_buffer"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	if not ok:
		return {}
	_last_creation_phases_ms["total"] = float(Time.get_ticks_usec() - total_t0_usec) / 1000.0
	return _summary(voxel_count, true)


## 重置场对（复杂度清零、碰撞重播地形基底）；供全量重放 stamp 记录前调用。
func reset_fields() -> Dictionary:
	release_fields()
	return ensure_fields()


## 释放两块场并清除登记元数据。
##
## ⚠ `release_rid` 第二参数传 `false`（禁用延迟）——与旧实现一致。
## 默认值 true 会在 compute list 活动期间把释放推迟到 end_compute_list()，改变既有时序。
func release_fields() -> void:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	for buffer_name in FIELD_BUFFER_NAMES:
		var entry: Dictionary = _fields.get(buffer_name, {})
		var stale_rid: RID = entry.get("rid", RID())
		if stale_rid.is_valid():
			release_rid(stale_rid, false)
		_fields.erase(buffer_name)


func _is_current(buffer_name: String, expected_byte_count: int) -> bool:
	var entry: Dictionary = _fields.get(buffer_name, {})
	var rid: RID = entry.get("rid", RID())
	return rid.is_valid() and int(entry.get("byte_size", -1)) == expected_byte_count


func _summary(voxel_count: int, created: bool) -> Dictionary:
	return {
		"complexity_field_buffer": rid_of(COMPLEXITY_FIELD_BUFFER),
		"collision_field_buffer": rid_of(COLLISION_FIELD_BUFFER),
		"voxel_count": voxel_count,
		"created": created,
	}


func _create_from_bytes(buffer_name: String, bytes: PackedByteArray, record_count: int, stride_bytes: int) -> bool:
	var logical_byte_size := bytes.size()
	var upload_bytes := bytes
	if upload_bytes.is_empty():
		upload_bytes.resize(maxi(stride_bytes, 4))
	var rid := storage_buffer_from_bytes(upload_bytes, SCOPE_PERSISTENT, "scene_voxel_tile:%s" % buffer_name)
	if not rid.is_valid():
		_last_error = "storage_buffer_create_failed:%s" % buffer_name
		return false
	_fields[buffer_name] = {
		"rid": rid,
		"byte_size": logical_byte_size,
		"upload_byte_size": upload_bytes.size(),
		"init_source": "cpu_upload",
		"record_count": record_count,
		"stride": stride_bytes,
		# ⚠ 常驻场由 GPU stamp/scatter pass 就地改写，对它们的上传载荷做哈希既昂贵
		# 又立刻过期 —— 恒 0 是刻意的，不是忘了算。
		"hash": 0,
	}
	return true


## 碰撞场的创建 + 地形基底播种。双路径：
##   优先 GPU 直写（uninitialized buffer + field_builder 的 terrain_collision_volume pass）；
##   失败则回落 CPU 字节种子。
##
## ⚠ CPU 兜底拿不到种子时**整段硬失败**，绝不用「全零碰撞场」顶上——
## 那会把整张地形报告成可通行。「没有地形基底」是另一回事：那是合法状态，返回全零种子。
func _create_collision_field(voxel_count: int, collision_byte_count: int) -> bool:
	var terrain_base_img: Image = _terrain_base_collision_field()
	var seeded_on_gpu := terrain_base_img != null and not terrain_base_img.is_empty()
	if seeded_on_gpu:
		var collision_rid := storage_buffer_uninitialized(
			collision_byte_count, SCOPE_PERSISTENT, "scene_voxel_tile:%s" % COLLISION_FIELD_BUFFER)
		var builder := _field_builder()
		seeded_on_gpu = collision_rid.is_valid() and builder != null \
			and builder._write_terrain_base_collision_volume_buffer_gpu(
				terrain_base_img, maxi(_grid_size().x, 1), maxi(_grid_size().y, 1), collision_rid)
		if seeded_on_gpu:
			_fields[COLLISION_FIELD_BUFFER] = {
				"rid": collision_rid,
				"byte_size": collision_byte_count,
				"upload_byte_size": 0,
				"init_source": "gpu_full_write",
				"record_count": voxel_count,
				"stride": COLLISION_STRIDE_BYTES,
				"hash": 0,
			}
			return true
		if collision_rid.is_valid():
			release_rid(collision_rid, false)
	var seed_bytes := _seed_collision_field_base_bytes(voxel_count)
	if seed_bytes.is_empty():
		# _seed_collision_field_base_bytes 已 push_error/assert：种子不可信就不建缓冲。
		_last_error = "collision_field_seed_failed"
		return false
	return _create_from_bytes(
		COLLISION_FIELD_BUFFER, seed_bytes, voxel_count, COLLISION_STRIDE_BYTES)


## 碰撞常驻场的初始内容：committer 级地形基底图按 grid_size 分辨率经 3D 种子 pass
## 打包为每体素 u32 字节。
##
## 基底图为 null/空 = "本场景没有地形基底"，是**合法**状态，返回全零种子。
## 种子 shader（terrain_collision_volume.glsl）按 texelFetch 直取源纹理、不做缩放，
## 因此基底图分辨率 != grid xz 分辨率时先重采样。
## 重采样失败 / 种子 pass 输出长度不符 = 有地形基底但没能烘进去，**硬失败返回空数组**
## （以前静默返回全零种子，等于把地形碰撞整层丢掉还装作成功）。
##
## ⚠ 「返回全零」与「返回空数组」是两种截然不同的语义，别合并。
func _seed_collision_field_base_bytes(voxel_count: int) -> PackedByteArray:
	var expected_bytes := SceneVoxelTileCodecScript.u32_field_byte_count(voxel_count)
	var seed_bytes := PackedByteArray()
	seed_bytes.resize(expected_bytes)
	var terrain_base_img: Image = _terrain_base_collision_field()
	if terrain_base_img == null or terrain_base_img.is_empty():
		return seed_bytes
	var builder := _field_builder()
	if builder == null:
		push_error("[SceneSVFieldStore] _seed_collision_field_base_bytes: field_builder 为 null —— 有地形基底却无处烘焙。")
		assert(false, "SceneSVFieldStore: missing field builder for terrain seed")
		return PackedByteArray()
	var xz_res := maxi(_grid_size().x, 1)
	var total_slices := maxi(_grid_size().y, 1)
	if terrain_base_img.get_width() != xz_res or terrain_base_img.get_height() != xz_res:
		var source_size := Vector2i(terrain_base_img.get_width(), terrain_base_img.get_height())
		terrain_base_img = builder._resample_collision_field(terrain_base_img, xz_res)
		if terrain_base_img == null or terrain_base_img.is_empty():
			push_error("[SceneSVFieldStore] _seed_collision_field_base_bytes: 地形基底碰撞图重采样失败（源 %dx%d → 目标 %dx%d，voxel_count=%d）—— 以前会静默返回全零种子，把地形碰撞整层丢掉" % [source_size.x, source_size.y, xz_res, xz_res, voxel_count])
			assert(false, "SceneSVFieldStore: terrain base collision resample failed")
			return PackedByteArray()
	# ⚠ 必须显式标注：builder 是 Object，方法返回 Variant，`:=` 会触发
	# INFERENCE_ON_VARIANT（引擎默认表里是 ERROR 级，直接打红门禁）。
	var base_bytes: PackedByteArray = builder._make_terrain_base_collision_volume_bytes_gpu(
		terrain_base_img, xz_res, total_slices)
	if base_bytes.size() != expected_bytes:
		push_error("[SceneSVFieldStore] _seed_collision_field_base_bytes: 地形基底体积种子长度不符 —— xz_res=%d total_slices=%d voxel_count=%d 期望 %d 字节，实际 %d 字节；以前会静默返回全零种子" % [xz_res, total_slices, voxel_count, expected_bytes, base_bytes.size()])
		assert(false, "SceneSVFieldStore: terrain base collision volume seed size mismatch")
		return PackedByteArray()
	return base_bytes


# ⚠ 地形种子要穿两层 committer 私有成员（`_terrain_base_collision_field` / `_field_builder`）。
# 这层间接在劈开前就存在（旧代码在 SceneVoxelTileStore 里直写 `_committer._field_builder`），
# 本类只是把它收在两个有名字的访问器后面，好让「谁依赖 committer 的哪半边」一眼看得见。
# 真要断开这条依赖，得让 committer 显式把「地形基底提供者」注入进来——那是另一件事。
func _terrain_base_collision_field() -> Image:
	if _committer == null:
		return null
	return _committer._terrain_base_collision_field


func _field_builder() -> Object:
	if _committer == null:
		return null
	return _committer._field_builder


# ⚠ 编辑器软重载后的成员修复，别当成冗余判空删掉。依据与写法同其余各类
# （软重载只搬重载前已存在的成员；判空必须用 `is`，静态类型已知时 `== null` 被编成恒 false）。
#
# 语义连带：`_fields` 丢了就等于「两块场的 RID 与字节数全没了」，
# 必须把耗时打点与错误串一并清空，否则会拿一份空表配一段"上次创建用了多久"的数据。
func _repair_soft_reloaded_members() -> void:
	if not (_fields is Dictionary):
		_fields = {}
		_last_creation_phases_ms = {}
	if not (_last_creation_phases_ms is Dictionary): _last_creation_phases_ms = {}
	if not (_last_error is String): _last_error = ""
