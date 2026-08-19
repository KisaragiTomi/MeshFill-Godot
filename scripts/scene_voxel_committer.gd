class_name SceneVoxelCommitter

extends "res://scripts/godot_compute_shader_base.gd"

const SV_RESIDENT_TILE_SIZE := 8
const SCENE_VOXEL_TILE_SIZE_SETTING := "meshfill/scene_voxel_tile/size_voxels"
const DEFAULT_SCENE_VOXEL_TILE_SIZE := Vector3i(8, 8, 8)
const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")
## scene voxel tile buffer schema：定义单源在 codec（SSOT），此处为单层 re-export
## （SPA/state_chain 等外部读点经本面引用，引用面不变）。
const SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER := SceneVoxelTileCodecScript.SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER
const SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER := SceneVoxelTileCodecScript.SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER
const SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT := SceneVoxelTileCodecScript.SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT
const SCENE_VOXEL_TILE_COMPLEXITY_FIELD_FORMAT := SceneVoxelTileCodecScript.SCENE_VOXEL_TILE_COMPLEXITY_FIELD_FORMAT
const SCENE_VOXEL_TILE_COLLISION_FIELD_FORMAT := SceneVoxelTileCodecScript.SCENE_VOXEL_TILE_COLLISION_FIELD_FORMAT
const SCENE_VOXEL_TILE_COMPLEXITY_FIELD_STRIDE_BYTES := SceneVoxelTileCodecScript.SCENE_VOXEL_TILE_COMPLEXITY_FIELD_STRIDE_BYTES
const SCENE_VOXEL_TILE_COLLISION_FIELD_STRIDE_BYTES := SceneVoxelTileCodecScript.SCENE_VOXEL_TILE_COLLISION_FIELD_STRIDE_BYTES
const SceneVoxelSourceRecordScript := preload("res://scripts/scene_voxel_source_record.gd")
const SceneVoxelScript := preload("res://scripts/scene_voxel.gd")
const VoxelGeneralScript := preload("res://scripts/utils/voxel_general.gd")

var _base_res: int  ## Base resolution for world↔pixel coordinate mapping
var _capture_size: float
var grid_size: Vector3i  ## SV grid dimensions in voxels
var voxel_size: Vector3  ## World-space size of one voxel
var grid_origin: Vector3  ## World-space origin for voxel index conversion

## Packed RGBA completeness field: one value per explicit channel, representing how completely filled each voxel is.
## When max(complexity, collision) == 0, the voxel is empty (nothing there).
## Source collision scalar field generated through the shared max-stamp path.
## Terrain base remains a separate input; both are published as one resident collision field.
## Authoritative terrain/base collision input layer.
## Resident collision read field: max(TerrainBaseCollision, source collision field).
## GPU resources
var _sampler: RID
var _gpu_ready: bool = false

## 场景体素瓦片 GPU 缓冲存储子系统(Stage 1 抽出)
const SceneVoxelTileStoreScript := preload("res://scripts/scene_voxel_tile_store.gd")
var _tile_store: SceneVoxelTileStoreScript = null

## 碰撞/占据场与盖章子系统(Stage 3 抽出)
const SceneVoxelFieldBuilderScript := preload("res://scripts/scene_voxel_field_builder.gd")
var _field_builder: SceneVoxelFieldBuilderScript = null

## --- terrain-base collision field 转发属性(真实存储在 _field_builder) ---
var _terrain_base_collision_field: Image:
	get:
		return _field_builder._terrain_base_collision_field if _field_builder else null
	set(value):
		if _field_builder:
			_field_builder._terrain_base_collision_field = value

## 初始化体素提交器，设置基础分辨率、捕获范围并按需启用 GPU
func _init(
	base_resolution: int,
	capture_size: float,
	tile_store: SceneVoxelTileStoreScript,
	field_builder: SceneVoxelFieldBuilderScript,
	grid_owner: Object = null
) -> void:
	assert(tile_store != null, "SceneVoxelCommitter requires an owner-provided SceneVoxelTileStore")
	assert(field_builder != null, "SceneVoxelCommitter requires an owner-provided SceneVoxelFieldBuilder")
	_base_res = base_resolution
	_capture_size = capture_size
	_tile_store = tile_store
	_tile_store._committer = self
	_field_builder = field_builder
	_field_builder._committer = self
	_tile_store._register_scene_voxel_tile_project_settings()
	grid_origin = VoxelGeneralScript.default_grid_origin(_capture_size)
	voxel_size = _voxel_size_for_resolution(_base_res, 1.0)
	grid_size = Vector3i(_base_res, 1, _base_res)
	_terrain_base_collision_field = VoxelGeneralScript.create_r32_image(_base_res)
	_init_gpu()
	_tile_store.attach_rendering_device(_rd, false)
	_tile_store.setup(self, grid_owner)
	_field_builder.attach_rendering_device(_rd, false)
	_field_builder.setup(self, grid_owner)

## 初始化 GPU 资源(仅创建 sampler；compute shader 已下沉至 tile/source/collision 三子系统)，校验资源完整性
func _init_gpu() -> void:
	log_name = "SceneVoxelCommitter"
	if not ensure_device(true, false):
		_gpu_fatal("Failed to create RenderingDevice — GPU compute required")
		return
	_sampler = create_linear_sampler()
	var missing_gpu_rids: Array[String] = []
	if not _sampler.is_valid():
		missing_gpu_rids.append("sampler")
	_gpu_ready = missing_gpu_rids.is_empty()
	if _gpu_ready:
		print("[SceneVoxelCommitter] GPU ready (coordinator: sampler only; tile/source/collision → 3 subsystems)")
	else:
		_gpu_fatal("Scene voxel compute resources are not ready: %s" % ", ".join(missing_gpu_rids))

## 报告 GPU 致命错误，弹出提示并标记 GPU 未就绪
func _gpu_fatal(msg: String) -> void:
	var full := "[SceneVoxelCommitter] GPU ERROR: %s" % msg
	push_error(full)
	OS.alert(full, "SceneVoxelCommitter — GPU Required")
	_gpu_ready = false

## The committer borrows both subcomponents. Their owner must tear them down
## before disposing the committer so their shared RenderingDevice is still alive.
func _on_before_dispose() -> void:
	if _field_builder != null:
		_field_builder._committer = null
		_field_builder = null
	if _tile_store != null:
		_tile_store._committer = null
		_tile_store = null

## 根据分辨率计算单个体素的世界空间尺寸
func _voxel_size_for_resolution(resolution: int, y_size: float = 1.0) -> Vector3:
	return VoxelGeneralScript.voxel_size_for_resolution(_capture_size, resolution, y_size)

## 配置场景体素网格的尺寸、体素大小与原点，并按需标记重建脏标记
func configure_scene_voxel_grid(
	p_grid_size: Vector3i,
	p_voxel_size: Vector3,
	p_grid_origin: Vector3 = Vector3.ZERO
) -> void:
	var previous_grid_size := grid_size
	var previous_voxel_size := voxel_size
	var previous_grid_origin := grid_origin
	grid_size = Vector3i(maxi(p_grid_size.x, 1), maxi(p_grid_size.y, 1), maxi(p_grid_size.z, 1))
	voxel_size = Vector3(
		maxf(p_voxel_size.x, 0.0001),
		maxf(p_voxel_size.y, 0.0001),
		maxf(p_voxel_size.z, 0.0001)
	)
	grid_origin = p_grid_origin
	_capture_size = voxel_size.x * float(grid_size.x)
	if previous_grid_size != grid_size or previous_voxel_size != voxel_size or previous_grid_origin != grid_origin:
		var initial_empty_grid := _committed_tick == 0 and _sv.is_empty()
		if initial_empty_grid:
			_tile_store.reset_empty_scene_voxel_grid()
			_sv_dirty = true
		else:
			_mark_scene_voxel_full_rebuild_dirty("grid_configured")

## V1：2D _volume 已退役——各门以 grid_size 有效为准（各维>0；_init 即有效，
## 网格配置经 canonical API configure_scene_voxel_grid）。
func _grid_ready() -> bool:
	return grid_size.x > 0 and grid_size.y > 0 and grid_size.z > 0

## 将世界坐标转换为体素索引坐标
func world_to_voxel(world_pos: Vector3, resolution: int = -1) -> Vector3i:
	var res := maxi(resolution if resolution > 0 else _base_res, 1)
	var size := _voxel_size_for_resolution(res, voxel_size.y)
	return VoxelGeneralScript.world_to_voxel(
		world_pos,
		grid_origin,
		size,
		Vector3i(res, maxi(grid_size.y, 1), res),
		false
	)

## 将体素索引坐标转换为世界坐标
func voxel_to_world(voxel_pos: Vector3i, resolution: int = -1) -> Vector3:
	var res := maxi(resolution if resolution > 0 else _base_res, 1)
	var size := _voxel_size_for_resolution(res, voxel_size.y)
	return VoxelGeneralScript.voxel_to_world(voxel_pos, grid_origin, size)

## _gc_frame_preserving_rids 已上移到计算基类 godot_compute_shader_base.gd（供本类与 SceneVoxelTileStore 共享）。
## 在GPU上对复杂度与碰撞场做体素瓦片摘要归约与紧凑化
func _rebuild_sv(tile_size: int = SV_RESIDENT_TILE_SIZE) -> Dictionary:
	if not _grid_ready():
		_sv = {}
		return {}
	var xz_res := grid_size.x
	var total_slices := grid_size.y
	if _sv.is_empty() and _committed_tick <= 1 \
			and _tile_store.is_empty_scene_voxel_tile_staging():
		return _publish_initial_empty_sv(tile_size)
	# CPU 入口盖章链已退役：碰撞摘要输入恒空（保留 reduce 契约的摘要缓冲形状；
	# VPG 直写放置物的 tile 占用由 complexity 侧体现，terrain base 刻意不进摘要）。
	var collision := {}
	var expected_complexity_field_count := xz_res * xz_res * total_slices
	# Stamp-only commit：常驻 field buffer 即 committed SV 主状态（stamp/散射直写，不再从源流重建）。
	# Explicit Dictionary type: the committer<->tile_store preload cycle prevents GDScript from
	# inferring the return type of _tile_store methods with :=.
	var field_buffers: Dictionary = _tile_store.ensure_resident_field_buffers()
	var complexity_field_buffer: RID = field_buffers.get("complexity_field_buffer", RID())
	if not complexity_field_buffer.is_valid():
		# 以前只 push_error 就继续跑：summary contract 少了 complexity buffer，
		# reduce 会静默产出全零 tile 摘要，SV 却照常发布成"提交成功"。
		push_error("[SceneVoxelCommitter] _rebuild_sv: 常驻复杂度 field buffer 不可用（grid_size=%s，期望体素数=%d）—— 拒绝用空摘要继续发布 SV" % [str(grid_size), expected_complexity_field_count])
		assert(false, "SceneVoxelCommitter: resident complexity field buffer unavailable")
		return {}
	var collision_summary_buffer_scope := "_rebuild_sv_collision_summary_buffer"
	# 该临时摘要 buffer 由 _field_builder 创建并登记在它自己的 tracker 上；gc 必须落在同一实例
	_field_builder.gc_scope(collision_summary_buffer_scope)
	var collision_summary_buffer_result := _field_builder._make_sv_collision_record_summary_gpu_buffer(
		collision,
		xz_res,
		total_slices,
		collision_summary_buffer_scope
	)
	var collision_summary_buffer: RID = collision_summary_buffer_result.get("collision_field_buffer", RID())
	# 碰撞摘要缓冲不可用曾走 "push_error + CPU 重算" 的降级路径：CPU 场与 GPU 常驻场
	# 口径不同（不含 VPG 直写），一旦降级 tile 摘要就静默变成另一套数据。
	if not collision_summary_buffer.is_valid():
		push_error("[SceneVoxelCommitter] _rebuild_sv: 碰撞摘要 GPU 缓冲不可用（xz_res=%d total_slices=%d 碰撞记录数=%d）—— 拒绝回退 CPU 重算" % [xz_res, total_slices, collision.size()])
		assert(false, "SceneVoxelCommitter: collision summary GPU buffer unavailable")
		_field_builder.gc_scope(collision_summary_buffer_scope)
		return {}
	var collision_summary_field := PackedFloat32Array()
	# 两个 buffer 到这里都已断言有效，contract 恒完整（缺键会让 reduce 走已删除的兜底路径）。
	var summary_buffer_contract := {
		"voxel_count": expected_complexity_field_count,
		"complexity_field_buffer": complexity_field_buffer,
		"collision_field_buffer": collision_summary_buffer,
	}
	var scene_voxel_tile_summary := _tile_store._reduce_scene_voxel_tile_summaries_gpu(
		collision_summary_field,
		xz_res,
		total_slices,
		_scene_voxel_tile_size(),
		summary_buffer_contract
	)
	if scene_voxel_tile_summary.is_empty():
		# 以前只 push_error 就继续发布 _sv：tile 摘要没更新，SV 却被标记为已提交/不脏。
		push_error("[SceneVoxelCommitter] _rebuild_sv: SceneVoxelTile 摘要归约失败（xz_res=%d total_slices=%d tile_size=%s）—— 拒绝发布未更新摘要的 SV" % [xz_res, total_slices, str(_scene_voxel_tile_size())])
		assert(false, "SceneVoxelCommitter: scene voxel tile summary reduce failed")
		_field_builder.gc_scope(collision_summary_buffer_scope)
		return {}
	_field_builder.gc_scope(collision_summary_buffer_scope)
	return _publish_sv(tile_size)


## `_sv` 的唯一发布点。两条路径（增量重建 / 初始空场）此前各手写一份同形状的八键字典
## 与同一套 tile 网格 ceili 公式；键集漂移不会报错，只会让消费方读到缺省值。
##
## Tile records, summaries and dirty state remain GPU-resident. The public SV
## dictionary carries topology only and never mirrors writable tile state.
func _publish_sv(tile_size: int) -> Dictionary:
	var tile_grid_size := Vector3i(
		ceili(float(grid_size.x) / float(tile_size)),
		ceili(float(grid_size.y) / float(tile_size)),
		ceili(float(grid_size.z) / float(tile_size))
	)
	_sv = {
		"type": "SV",
		"grid_size": grid_size,
		"voxel_size": voxel_size,
		"grid_origin": grid_origin,
		"commit_tick": _committed_tick,
		"generation_tick": _generation_tick,
		"tile_grid_size": tile_grid_size,
		"total_tiles": tile_grid_size.x * tile_grid_size.y * tile_grid_size.z,
	}
	_sv_dirty = false
	return _sv.duplicate(true)


func _publish_initial_empty_sv(tile_size: int) -> Dictionary:
	var field_buffers: Dictionary = _tile_store.ensure_resident_field_buffers()
	var complexity_field_buffer: RID = field_buffers.get("complexity_field_buffer", RID())
	var collision_field_buffer: RID = field_buffers.get("collision_field_buffer", RID())
	if not complexity_field_buffer.is_valid() or not collision_field_buffer.is_valid():
		push_error("[SceneVoxelCommitter] _publish_initial_empty_sv: 初始常驻 field buffer 不可用（grid_size=%s complexity_valid=%s collision_valid=%s）" % [str(grid_size), str(complexity_field_buffer.is_valid()), str(collision_field_buffer.is_valid())])
		assert(false, "SceneVoxelCommitter: initial resident field buffers unavailable")
		_sv = {}
		return {}
	return _publish_sv(tile_size)

var _sv: Dictionary = {}

## 最近一次 commit_scene_voxels 的提交摘要
var _last_commit_summary: Dictionary = {}

var _generation_tick: int = 1
var _committed_tick: int = 0
var _sv_dirty: bool = true

## Stamp-only 提交发布点：推进 tick 并重建 tile 摘要。
## VPG 的 GPU state-chain stamp 与笔刷散射均原位写入常驻 field，不经本入口；
## CPU 入口盖章链（ISWS 簿记 + pending 散射）已退役删除。
func commit_scene_voxels(tick: int = -1) -> Dictionary:
	if not _grid_ready():
		return {}
	var commit_tick := tick if tick >= 0 else _generation_tick
	_last_commit_summary = {
		"ok": true,
		"mode": "stamp_only_commit",
		"commit_tick": commit_tick,
	}
	_committed_tick = max(_committed_tick, commit_tick)
	_generation_tick = max(_generation_tick, commit_tick + 1)
	_sv_dirty = true
	_rebuild_sv()
	# V1：scene_voxels 公共投影 dict 已退役（查询走常驻 field 回读）；返回提交摘要副本。
	return get_last_scene_voxel_commit_summary()

## 外部**直写**常驻场对之后重跑瓦片摘要 reduce。
##
## 为什么需要它：VPG 的 GPU state-chain stamp 是**原位**改写 complexity/collision 常驻场的，
## 不经本类任何入口；而瓦片摘要要靠单独一趟 reduce（在 `_rebuild_sv()` 里）。
##
## ⚠ placement 路径上本来**有**一个触发点 —— `scene_placement_runtime.gd` 的
## `_commit_accepted_placements()` 会调 `commit_scene_voxels()` —— 但它的门写的是
## `bool(placement_result.get("ok", false))`，而 VPG 的成功变体按
## `ReportSchema.VPG_MULTI_ASSET_REPORT` 的约定**刻意不发 `ok` 键**
##（那条注释原话：「成功变体故意不发 ok——SPA 的 ok 门现状即靠缺席走 false 分支，勿补发」）。
## ⇒ 每一次成功放置这道门都是 false，commit 分支恒不执行。
## **不要靠补发 `ok` 来解决**：那会同时打开一条从未验证过的 GPU 写路径
##（`_flush_gpu_runtime_dirty_delta_to_scene_voxel_committer` 被同一道门挡着）。
##
## ⚠ 与 `commit_scene_voxels()` 的分工：本入口**不**散射 pending 的 CPU 入口盖章记录、
## **不**推进 commit/generation tick —— 那两件是「提交」的语义，而这里的前提是内容**已经**
## 在场里了，只是摘要没跟上。误用 commit_scene_voxels() 来刷摘要会白推一次 tick，
## 并把 `_last_commit_summary` 覆盖成一条 record_count=0 的假提交记录。
##
## ⚠ 只 push_error 不 assert：网格未就绪 / 常驻缓冲缺失属于「在别处修好之前每次都会发生」
## 的既有状态，不是调用方违约；对它断言会当场打死编辑器（已踩过）。
func refresh_scene_voxel_tile_summaries(reason: String = "resident_field_external_write") -> Dictionary:
	if not _grid_ready():
		push_error("[SceneVoxelCommitter] refresh_scene_voxel_tile_summaries: 网格未配置（grid_size=%s, reason=%s）—— 瓦片摘要保持 stamp 之前的旧值，SceneSV 显示与点选会按空场渲染" % [
			str(grid_size), reason])
		return {"ok": false, "reason": "grid_not_ready", "refresh_reason": reason}
	# ⚠ 显式 Dictionary 标注：不标注则 `:=` 从可能为 Variant 的返回值推导，
	# 触发 INFERENCE_ON_VARIANT（引擎默认表里是 ERROR 级，直接打红门禁）。
	var rebuilt: Dictionary = _rebuild_sv()
	if rebuilt.is_empty():
		push_error("[SceneVoxelCommitter] refresh_scene_voxel_tile_summaries: 摘要归约失败（grid_size=%s tile_size=%s commit_tick=%d reason=%s）—— 全部瓦片仍报 scene_voxel_count == 0，SceneSV/SVTile 的显示与点选会继续按空场渲染（具体成因已由 _rebuild_sv 内部报出）" % [
			str(grid_size), str(_scene_voxel_tile_size()), _committed_tick, reason])
		return {"ok": false, "reason": "rebuild_sv_failed", "refresh_reason": reason}
	return {
		"ok": true,
		"reason": "ok",
		"refresh_reason": reason,
		"commit_tick": _committed_tick,
	}


## 返回最近一次 stamp-only 提交摘要的副本
func get_last_scene_voxel_commit_summary() -> Dictionary:
	return _last_commit_summary.duplicate(true)

## Debug 回读：把常驻 field buffer 解码为 CPU float 投影（显式调试/契约测试路径，不进运行时）
func readback_sv_field_debug_snapshot() -> Dictionary:
	if _rd == null or not _grid_ready():
		return {}
	var field_buffers := _tile_store.ensure_resident_field_buffers()
	var voxel_count := int(field_buffers.get("voxel_count", 0))
	var complexity_rid: RID = field_buffers.get("complexity_field_buffer", RID())
	var collision_rid: RID = field_buffers.get("collision_field_buffer", RID())
	if voxel_count <= 0 or not complexity_rid.is_valid() or not collision_rid.is_valid():
		return {}
	var complexity_bytes := _rd.buffer_get_data(complexity_rid, 0, voxel_count * SCENE_VOXEL_TILE_COMPLEXITY_FIELD_STRIDE_BYTES)
	var collision_bytes := _rd.buffer_get_data(collision_rid, 0, SceneVoxelTileCodecScript.u32_field_byte_count(voxel_count))
	return {
		"voxel_count": voxel_count,
		"readback_source": "resident_stamped_field_buffer_debug_readback",
		"complexity_field": SceneVoxelTileCodecScript.decode_complexity_field_rgba8_alpha_bytes(complexity_bytes, voxel_count),
		"collision_field": SceneVoxelTileCodecScript.decode_collision_field_u32_bytes(collision_bytes, voxel_count),
	}

## ─── 3D 查询面（常驻 field 回读；2D slices/scene_voxels 投影已退役） ───

## 常驻 field 的线性体素索引 = 规范索引式（VoxelGeneral.voxel_index，与
## scatter_sv_field_records.glsl 寻址逐值一致）；越界返回 -1。
## 迁移前这里写的是 `x + gx*(z + gx*y)`——两处都用 gx，只在 XZ 方形网格下才对。
func _resident_field_voxel_index(voxel: Vector3i) -> int:
	if voxel.x < 0 or voxel.x >= grid_size.x \
		or voxel.y < 0 or voxel.y >= grid_size.y \
		or voxel.z < 0 or voxel.z >= grid_size.z:
		return -1
	return VoxelGeneralScript.voxel_index(voxel, grid_size)

## 单体素常驻 field 对回读：offset buffer_get_data(idx*4, 4)，
## 复杂度取 RGBA8 packed word（alpha=低字节，颜色 r/g/b=高三字节）、碰撞取 u32 低字节。
## 越界/缓冲缺失返回 {}。
func _sample_resident_field_voxel(voxel: Vector3i) -> Dictionary:
	if _rd == null or not _grid_ready():
		return {}
	var idx := _resident_field_voxel_index(voxel)
	if idx < 0:
		return {}
	var field_buffers: Dictionary = _tile_store.ensure_resident_field_buffers()
	var complexity_rid: RID = field_buffers.get("complexity_field_buffer", RID())
	var collision_rid: RID = field_buffers.get("collision_field_buffer", RID())
	if not complexity_rid.is_valid() or not collision_rid.is_valid():
		# 越界体素返回 {} 是合法 miss（上面 idx<0 分支）；到这里说明常驻缓冲本身没了，
		# 以前同样静默返回 {}，调用方会把它读成"这个体素是空的"。
		push_error("[SceneVoxelCommitter] _sample_resident_field_voxel: 常驻 field buffer 不可用（voxel=%s idx=%d complexity_valid=%s collision_valid=%s）" % [str(voxel), idx, str(complexity_rid.is_valid()), str(collision_rid.is_valid())])
		assert(false, "SceneVoxelCommitter: resident field buffers unavailable for voxel sample")
		return {}
	var complexity_bytes := _rd.buffer_get_data(complexity_rid, idx * SCENE_VOXEL_TILE_COMPLEXITY_FIELD_STRIDE_BYTES, SCENE_VOXEL_TILE_COMPLEXITY_FIELD_STRIDE_BYTES)
	var collision_bytes := _rd.buffer_get_data(collision_rid, idx * SCENE_VOXEL_TILE_COLLISION_FIELD_STRIDE_BYTES, SCENE_VOXEL_TILE_COLLISION_FIELD_STRIDE_BYTES)
	if complexity_bytes.size() < SCENE_VOXEL_TILE_COMPLEXITY_FIELD_STRIDE_BYTES or collision_bytes.size() < SCENE_VOXEL_TILE_COLLISION_FIELD_STRIDE_BYTES:
		push_error("[SceneVoxelCommitter] _sample_resident_field_voxel: 单体素回读长度不足（voxel=%s idx=%d complexity=%d/%d 字节 collision=%d/%d 字节）" % [str(voxel), idx, complexity_bytes.size(), SCENE_VOXEL_TILE_COMPLEXITY_FIELD_STRIDE_BYTES, collision_bytes.size(), SCENE_VOXEL_TILE_COLLISION_FIELD_STRIDE_BYTES])
		assert(false, "SceneVoxelCommitter: resident field voxel readback too short")
		return {}
	var packed := complexity_bytes.decode_u32(0)
	var complexity := float(packed & 0xFF) / 255.0
	var color := Color(
		float((packed >> 24) & 0xFF) / 255.0,
		float((packed >> 16) & 0xFF) / 255.0,
		float((packed >> 8) & 0xFF) / 255.0,
		complexity
	)
	return {
		"complexity": complexity,
		"color": color,
		"collision_strength": float(collision_bytes.decode_u32(0) & 0xFF) / 255.0,
	}

## 查询指定世界坐标处的体素信息（签名与返回键不变；实现改读常驻 field 对）
func query_voxel(wx: float, wz: float, height_above_terrain: float) -> Dictionary:
	var miss := {"complexity": 0.0, "color": Color.BLACK}
	if not _grid_ready():
		return miss
	# 高度出网格（低于 grid_origin.y 或高于顶部）与旧 slice_meta y 区间门一致按 miss 处理
	if height_above_terrain < grid_origin.y:
		return miss
	var voxel := VoxelGeneralScript.world_to_voxel(
		Vector3(wx, height_above_terrain, wz),
		grid_origin,
		voxel_size,
		grid_size,
		false
	)
	if voxel.y >= grid_size.y:
		return miss
	# 到这里 voxel 已被 world_to_voxel 钳进网格且 y 门已过，采样失败只可能是缓冲不可信；
	# 以前 push_error 后仍返回 miss（complexity=0），调用方读不出区别，等于把错误洗成"空体素"。
	var sample := _sample_resident_field_voxel(voxel)
	if sample.is_empty():
		push_error("[SceneVoxelCommitter] query_voxel: 常驻 field 采样失败（world=(%.3f, %.3f) voxel=%s grid_size=%s）—— 不再降级为 miss" % [wx, wz, str(voxel), str(grid_size)])
		assert(false, "SceneVoxelCommitter: query_voxel resident field sample failed")
		return {}
	var source := {
		"complexity": float(sample.get("complexity", 0.0)),
		"color": sample.get("color", Color.BLACK),
	}
	return SceneVoxelScript.accepted_at(source, voxel.y, Vector2i(voxel.x, voxel.z))

## 获取已提交的场景体素映射（键 = scene_voxel_key(slice, xz)，值 = accepted 记录；
## 实现改为常驻复杂度 field 全量回读组装，alpha>0 视为已盖章体素）
func get_scene_voxels() -> Dictionary:
	if _rd == null or not _grid_ready():
		return {}
	var field_buffers: Dictionary = _tile_store.ensure_resident_field_buffers()
	var voxel_count := int(field_buffers.get("voxel_count", 0))
	var complexity_rid: RID = field_buffers.get("complexity_field_buffer", RID())
	if voxel_count <= 0 or not complexity_rid.is_valid():
		return {}
	var expected_bytes := voxel_count * SCENE_VOXEL_TILE_COMPLEXITY_FIELD_STRIDE_BYTES
	var bytes := _rd.buffer_get_data(complexity_rid, 0, expected_bytes)
	if bytes.size() < expected_bytes:
		# 以前静默 mini() 截断：尾部体素整段从投影里消失，看起来就像那片区域没盖过章。
		push_error("[SceneVoxelCommitter] get_scene_voxels: 复杂度场回读长度不足（voxel_count=%d 期望 %d 字节，实际 %d 字节）—— 拒绝返回截断的投影" % [voxel_count, expected_bytes, bytes.size()])
		assert(false, "SceneVoxelCommitter: complexity field readback truncated")
		return {}
	var result := {}
	var xz_res := maxi(grid_size.x, 1)
	var plane := xz_res * xz_res
	var limit := voxel_count
	for i in range(limit):
		var packed := bytes.decode_u32(i * SCENE_VOXEL_TILE_COMPLEXITY_FIELD_STRIDE_BYTES)
		var alpha := packed & 0xFF
		if alpha == 0:
			continue
		var complexity := float(alpha) / 255.0
		var color := Color(
			float((packed >> 24) & 0xFF) / 255.0,
			float((packed >> 16) & 0xFF) / 255.0,
			float((packed >> 8) & 0xFF) / 255.0,
			complexity
		)
		var slice_index := int(i / plane)
		var rem := i % plane
		var voxel_xz := Vector2i(rem % xz_res, int(rem / xz_res))
		result[SceneVoxelSourceRecordScript.scene_voxel_key(slice_index, voxel_xz)] = SceneVoxelScript.accepted({
			"complexity": complexity,
			"color": color,
		})
	return result

## 获取场景体素状态字典并在需要时重建
func get_sv() -> Dictionary:
	if _sv_dirty and _grid_ready():
		_rebuild_sv()
	return _sv.duplicate(true)

## 标记指定场景体素瓦片为脏
func _mark_scene_voxel_full_rebuild_dirty(reason: String = "full_rebuild") -> Dictionary:
	return _tile_store.mark_all_scene_voxel_tiles_dirty(
		{"scene": true, "collision": true},
		{
			"id": reason,
			"source_id": reason,
		}
	)

## Restores the committed SceneVoxel fixture to its initial terrain-seeded
## state without replacing this committer or its RenderingDevice.
func reset_empty_fixture_state() -> Dictionary:
	if not _grid_ready():
		return {"ok": false, "reason": "grid_not_ready"}
	_last_commit_summary = {}
	_generation_tick = 1
	_committed_tick = 0
	_sv = {}
	_sv_dirty = true
	_tile_store.reset_empty_scene_voxel_grid()
	var commit_result := commit_scene_voxels(0)
	var uploaded := _tile_store.ensure_scene_voxel_tile_buffers_uploaded(false)
	var ready := bool(commit_result.get("ok", false)) and uploaded
	return {
		"ok": ready,
		"reason": "ok" if ready else "empty_fixture_reset_failed",
		"commit": commit_result,
		"tile_buffers_ready": uploaded,
		"commit_tick": _committed_tick,
		"generation_tick": _generation_tick,
	}


## 获取指定切片与XZ坐标的场景体素记录（签名与返回键不变；实现改为单体素常驻 field 回读，
## 未盖章体素（复杂度 0）与旧投影 miss 一致返回 {}）
func get_scene_voxel(slice_index: int, voxel_xz: Vector2i) -> Dictionary:
	var sample := _sample_resident_field_voxel(Vector3i(voxel_xz.x, slice_index, voxel_xz.y))
	if sample.is_empty():
		return {}
	var complexity := float(sample.get("complexity", 0.0))
	if complexity <= 0.0:
		return {}
	return SceneVoxelScript.accepted({
		"complexity": complexity,
		"color": sample.get("color", Color.BLACK),
	})

## 常驻 field 对的逐体素采样公开口（{complexity, color, collision_strength}；未就绪/越界返回 {}）。
## 选择层点验用——get_scene_voxel 在 complexity<=0 时隐藏体素，collision-only 盖章内容
## （如 AABB 兜底碰撞剖面资产的放置）只能经此读到。
func sample_committed_voxel(voxel: Vector3i) -> Dictionary:
	return _sample_resident_field_voxel(voxel)

## 返回当前 SceneVoxelTile 的三维体素尺寸 Vector3i；由 _rebuild_sv 调用，委托 store 的公共单源
func _scene_voxel_tile_size() -> Vector3i:
	return SceneVoxelTileStoreScript.scene_voxel_tile_size()
