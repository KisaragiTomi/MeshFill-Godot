class_name SceneVoxelCommitter

extends "res://scripts/godot_compute_shader_base.gd"

const VOXEL_OCCUPIED_EPSILON := VoxelGeneral.VOXEL_OCCUPIED_EPSILON
const SV_RESIDENT_TILE_SIZE := 8
const SCENE_VOXEL_TILE_SIZE_SETTING := "meshfill/scene_voxel_tile/size_voxels"
const DEFAULT_SCENE_VOXEL_TILE_SIZE := Vector3i(4, 4, 4)
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
## Stamp-only commit：CPU 入口盖章的 field 写入记录 (x, z, slice, complexity, r, g, b, collision)
## stride/路径/键/展平契约已抽取到 utils/sv_field_scatter.gd（与 SPA BrushSV 散射共享）。
const SvFieldScatter := preload("res://scripts/utils/sv_field_scatter.gd")
const SV_FIELD_RECORD_FLOAT_STRIDE := SvFieldScatter.RECORD_FLOAT_STRIDE

## ISWS 记录显式 3D bounds 的键名集（与 tile_store._scene_voxel_tile_bounds_from_record 的
## 显式分支一致：min 含端点、max 不含端点，经 normalized_bounds 钳到网格）。
const EXPLICIT_BOUNDS_MIN_KEYS: Array[String] = ["voxel_min", "bounds_min", "new_voxel_min", "new_bounds_min"]
const EXPLICIT_BOUNDS_MAX_KEYS: Array[String] = ["voxel_max", "bounds_max", "new_voxel_max", "new_bounds_max"]

const SceneVoxelSourceRecordScript := preload("res://scripts/scene_voxel_source_record.gd")
const SceneVoxelScript := preload("res://scripts/scene_voxel.gd")
const SceneVoxelTargetScript := preload("res://scripts/scene_voxel_target.gd")
const VariantUtils := preload("res://scripts/utils/variant_utils.gd")
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
func _init(base_resolution: int, capture_size: float, _enable_gpu: bool = true) -> void:
	_base_res = base_resolution
	_capture_size = capture_size
	_tile_store = SceneVoxelTileStoreScript.new()
	_tile_store._committer = self
	_field_builder = SceneVoxelFieldBuilderScript.new()
	_field_builder._committer = self
	_tile_store._register_scene_voxel_tile_project_settings()
	grid_origin = VoxelGeneralScript.default_grid_origin(_capture_size)
	voxel_size = _voxel_size_for_resolution(_base_res, 1.0)
	grid_size = Vector3i(_base_res, 1, _base_res)
	_terrain_base_collision_field = _field_builder._create_collision_image(_base_res)
	_init_gpu()
	_tile_store.attach_rendering_device(_rd, false)
	_tile_store.setup(self)
	_field_builder.attach_rendering_device(_rd, false)
	_field_builder.setup(self, _base_res)

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

## 释放前回调，清理场景体素 tile 与碰撞场子系统的常驻 GPU 缓冲
func _on_before_dispose() -> void:
	if _field_builder != null:
		_field_builder.teardown()
		_field_builder = null
	if _tile_store != null:
		_tile_store.teardown()
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
		_mark_scene_voxel_full_rebuild_dirty("grid_configured")
	else:
		_tile_store._mark_scene_voxel_tile_staging_dirty("grid_configured")

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

## 判断通道索引是否在有效范围内
func _is_valid_channel(channel: int) -> bool:
	return VoxelGeneralScript.is_valid_channel(channel)

## 将世界半径（米）换算为基础分辨率下的像素半径；委托 VoxelGeneralScript；由 _record_radius_px 和 apply_instance_stamp_write_spec 调用
func _radius_to_px(radius_m: float) -> int:
	return VoxelGeneralScript.world_radius_to_texture_radius(radius_m, _capture_size, _base_res)

## 返回全部已注册体素写入规格的深度副本；由 ScenePlacementActor、调试工具、_rebuild_scene_voxels_from_records 调用
func get_instance_stamp_write_specs() -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	for record in _instance_stamp_write_specs:
		var typed_record := record as Dictionary
		records.append(typed_record.duplicate(true))
	return records

## 从记录中读取有效通道索引，无效返回 -1
func _record_channel(record: Dictionary) -> int:
	var ch := int(record.get("channel", -1))
	if not _is_valid_channel(ch):
		return -1
	return ch

## 从记录中读取或换算像素半径，至少为 1
func _record_radius_px(record: Dictionary) -> int:
	if record.has("radius_px"):
		return maxi(int(record.radius_px), 1)
	if record.has("radius"):
		return _radius_to_px(float(record.radius))
	return 1

## 将基础像素坐标转换为体积分辨率下的像素坐标
func _volume_px_from_base(base_px: Vector2i, xz_res: int) -> Vector2i:
	return VoxelGeneralScript.base_pixel_to_volume_pixel(base_px, _base_res, xz_res)

## 将基础分辨率像素半径转换为体积分辨率像素半径
func _volume_radius_from_base_radius(radius_px: int, xz_res: int) -> int:
	return VoxelGeneralScript.base_radius_to_volume_radius(radius_px, _base_res, xz_res)

## 计算下一个写入 tick，取生成 tick 或已提交 tick+1
func _next_write_tick() -> int:
	return _generation_tick if _generation_tick > _committed_tick else _committed_tick + 1

## 开始一个生成 tick，标记场景体素为脏并返回该 tick
func begin_generation_tick(tick: int = -1) -> int:
	var write_tick := tick if tick >= 0 else _next_write_tick()
	_generation_tick = write_tick
	_sv_dirty = true
	return write_tick

## 根据记录返回切片索引列表（3D：记录自带 slice_indices，回退单值 slice_index；
## slice_meta 通道→切片映射已随 2D volume 退役，与 tile_store 旧键 bounds 换算的 Y 轴口径一致）
func _record_slice_indices(entry: Dictionary) -> Array[int]:
	var indices: Array[int] = []
	if not _grid_ready():
		return indices
	if entry.has("slice_indices"):
		var raw_indices: Array = entry.slice_indices
		for idx in raw_indices:
			var si := int(idx)
			if si >= 0 and si < grid_size.y:
				indices.append(si)
	if indices.is_empty() and entry.has("slice_index"):
		indices.append(clampi(int(entry.get("slice_index", 0)), 0, maxi(grid_size.y - 1, 0)))
	return indices

## _gc_frame_preserving_rids 已上移到计算基类 godot_compute_shader_base.gd（供本类与 SceneVoxelTileStore 共享）。
## 在GPU上对复杂度与碰撞场做体素瓦片摘要归约与紧凑化
func _rebuild_sv(tile_size: int = SV_RESIDENT_TILE_SIZE) -> Dictionary:
	if not _grid_ready():
		_sv = {}
		return {}
	var xz_res := grid_size.x
	var total_slices := grid_size.y
	var collision := _collect_instance_stamp_collision_cells()
	var expected_complexity_field_count := xz_res * xz_res * total_slices
	# Stamp-only commit：常驻 field buffer 即 committed SV 主状态（stamp/散射直写，不再从源流重建）。
	# Explicit Dictionary type: the committer<->tile_store preload cycle prevents GDScript from
	# inferring the return type of _tile_store methods with :=.
	var field_buffers: Dictionary = _tile_store.ensure_resident_field_buffers()
	var complexity_field_buffer: RID = field_buffers.get("complexity_field_buffer", RID())
	if not complexity_field_buffer.is_valid():
		push_error("[SceneVoxelCommitter] SV resident complexity field buffer unavailable")
	var collision_summary_buffer_scope := "_rebuild_sv_collision_summary_buffer"
	# 该临时摘要 buffer 由 _field_builder 创建并登记在它自己的 tracker 上；gc 必须落在同一实例
	_field_builder.gc_scope(collision_summary_buffer_scope)
	# 摘要口径：collision 侧刻意用"仅 CPU 碰撞记录"的临时摘要场（不含 terrain base，避免地面 tile 全部
	# 报告 collision 占用；也不含 VPG 双写进常驻场的碰撞——VPG 放置物的 tile 占用由 complexity 侧体现）。
	var collision_summary_buffer_result := _field_builder._make_sv_collision_record_summary_gpu_buffer(
		collision,
		xz_res,
		total_slices,
		collision_summary_buffer_scope
	)
	var collision_summary_buffer: RID = collision_summary_buffer_result.get("collision_field_buffer", RID())
	var collision_summary_field := PackedFloat32Array()
	if not collision_summary_buffer.is_valid():
		push_error("[SceneVoxelCommitter] SV resident collision-summary field buffer unavailable; recomputing on CPU")
		collision_summary_field = _field_builder._make_sv_collision_record_summary_field(collision, xz_res, total_slices)
	var tile_grid_size := Vector3i(
		ceili(float(grid_size.x) / float(tile_size)),
		ceili(float(grid_size.y) / float(tile_size)),
		ceili(float(grid_size.z) / float(tile_size))
	)
	var total_tiles := tile_grid_size.x * tile_grid_size.y * tile_grid_size.z
	var dirty_scene_voxel_tiles_snapshot := {}
	_tile_store._reset_scene_voxel_tile_summaries()
	var summary_buffer_contract := {
		"voxel_count": expected_complexity_field_count,
	}
	if complexity_field_buffer.is_valid():
		summary_buffer_contract["complexity_field_buffer"] = complexity_field_buffer
	if collision_summary_buffer.is_valid():
		summary_buffer_contract["collision_field_buffer"] = collision_summary_buffer
	var scene_voxel_tile_summary := _tile_store._reduce_scene_voxel_tile_summaries_gpu(
		PackedFloat32Array(),
		collision_summary_field,
		xz_res,
		total_slices,
		_scene_voxel_tile_size(),
		summary_buffer_contract
	)
	if scene_voxel_tile_summary.is_empty():
		push_error("[SceneVoxelCommitter] SceneVoxelTile summary reduce compute failed")
	else:
		_tile_store._apply_scene_voxel_tile_reduce_summaries(scene_voxel_tile_summary)
	_field_builder.gc_scope(collision_summary_buffer_scope)
	_tile_store._rebuild_scene_voxel_tile_source_refs()
	dirty_scene_voxel_tiles_snapshot = _tile_store._copy_scene_voxel_tile()
	# V1：恒空的 complexity_field/collision_field CPU 投影键与无读者的
	# scene_voxel_tile_summary_gpu_rid 发布已退役（summary RID 走 get_scene_voxel_tile_summary_gpu_buffer()）。
	_sv = {
		"type": "SV",
		"grid_size": grid_size,
		"voxel_size": voxel_size,
		"grid_origin": grid_origin,
		"commit_tick": _committed_tick,
		"generation_tick": _generation_tick,
		"tile_grid_size": tile_grid_size,
		"total_tiles": total_tiles,
		"dirty_scene_voxel_tiles": dirty_scene_voxel_tiles_snapshot,
	}
	_tile_store.clear_all_dirty()
	_tile_store._maybe_auto_upload_scene_voxel_tile_buffers("sv_publish")
	_sv_dirty = false
	return _sv.duplicate(true)

## 3D 散射半边：把复杂度圆盘直接排队为常驻 field 散射记录（旧 GPU stamp+collect
## kernel 的 CPU 等价盘形：圆判定 dx²+dz²≤r²、盘心/边缘钳到网格内、v≤epsilon 不写；
## 旧 compare 门（value+slop≥previous）由散射 shader write_mode=1 的 max-by-complexity
## 合并等价承担）。返回盘心的体积像素坐标。
func _queue_stamp_disc_records(
	base_px: Vector2i,
	radius_px: int,
	complexity: float,
	color: Color,
	slice_indices: Array[int]
) -> Vector2i:
	var xz_res := grid_size.x
	var voxel_px := _volume_px_from_base(base_px, xz_res)
	if slice_indices.is_empty():
		return voxel_px
	var v := clampf(complexity, 0.0, 1.0)
	if v <= VOXEL_OCCUPIED_EPSILON:
		return voxel_px
	var radius_vol := _volume_radius_from_base_radius(radius_px, xz_res)
	var center := Vector2i(clampi(voxel_px.x, 0, xz_res - 1), clampi(voxel_px.y, 0, xz_res - 1))
	for dz in range(-radius_vol, radius_vol + 1):
		for dx in range(-radius_vol, radius_vol + 1):
			if dx * dx + dz * dz > radius_vol * radius_vol:
				continue
			var stamp_px := Vector2i(
				clampi(center.x + dx, 0, xz_res - 1),
				clampi(center.y + dz, 0, xz_res - 1)
			)
			for si in slice_indices:
				_queue_sv_field_record(stamp_px, si, v, color, 0.0)
	return voxel_px

## 从 ISWS 记录的 collision 层按需重建 merge 记录 cell map（供 _rebuild_sv 碰撞摘要；
## 口径与旧 _volume["collision"] cell map 一致：仅 CPU 入口记录、排除 terrain 基底与
## VPG 直写、同体素取 max）。键/值形态与 field_builder._pack_sv_collision_records 消费契约对齐。
func _collect_instance_stamp_collision_cells() -> Dictionary:
	var cells := {}
	for raw_record in _instance_stamp_write_specs:
		var record := raw_record as Dictionary
		var collision_layers: Array = record.get("collision", [])
		for raw_layer in collision_layers:
			if not raw_layer is Dictionary:
				continue
			var layer := raw_layer as Dictionary
			var collision_strength := clampf(float(layer.get("collision_strength", 0.0)), 0.0, 1.0)
			if collision_strength <= VOXEL_OCCUPIED_EPSILON:
				continue
			var raw_voxel_xz = layer.get("voxel_xz", null)
			if not raw_voxel_xz is Vector2i:
				continue
			var voxel_xz: Vector2i = raw_voxel_xz
			var slice_index := int(layer.get("slice_index", 0))
			var cell_key := SceneVoxelSourceRecordScript.scene_voxel_key(slice_index, voxel_xz)
			var previous = cells.get(cell_key, null)
			if previous is Dictionary and clampf(float((previous as Dictionary).get("collision_strength", 0.0)), 0.0, 1.0) >= collision_strength:
				continue
			cells[cell_key] = {
				"collision_strength": collision_strength,
				"voxel_xz": voxel_xz,
				"slice_index": slice_index,
			}
	return cells

## 旧 2D 键 → 显式 3D bounds 兼容换算命中计数（V1e 迁移期观测；每 32 次告警一次）
static var _legacy_stamp_bounds_conversion_count := 0

## 记录一次旧键换算命中并按节流告警
func _note_legacy_stamp_bounds_conversion(record_id: String) -> void:
	_legacy_stamp_bounds_conversion_count += 1
	if _legacy_stamp_bounds_conversion_count % 32 == 1:
		push_warning(
			"[SceneVoxelCommitter] instance stamp record '%s' lacks explicit voxel_min/voxel_max; converted from legacy 2D keys (base_pixel/voxel_xz/radius_px/slice_indices), hit #%d"
			% [record_id, _legacy_stamp_bounds_conversion_count]
		)

## 排队一条 stamp-only 提交的 field 散射记录；complexity < 0 表示仅写碰撞。
## 同体素记录合并：复杂度/颜色后写者胜（与公共投影语义一致），碰撞取 max（与 GPU atomic 一致）。
func _queue_sv_field_record(voxel_xz: Vector2i, slice_index: int, complexity: float, color: Color, collision_strength: float) -> void:
	var record_key := SvFieldScatter.record_key(voxel_xz, slice_index)
	var slot: PackedFloat32Array = _pending_sv_field_records.get(record_key, PackedFloat32Array())
	if slot.is_empty():
		slot.resize(SV_FIELD_RECORD_FLOAT_STRIDE)
		slot[0] = float(voxel_xz.x)
		slot[1] = float(voxel_xz.y)
		slot[2] = float(slice_index)
		slot[3] = -1.0
	if complexity >= 0.0:
		slot[3] = complexity
		slot[4] = color.r
		slot[5] = color.g
		slot[6] = color.b
	slot[7] = maxf(slot[7], clampf(collision_strength, 0.0, 1.0))
	_pending_sv_field_records[record_key] = slot

## 将 pending field 记录一次稀疏散射进常驻 field buffer（stamp-only commit 的 CPU 入口半边）
func _flush_pending_sv_field_records() -> Dictionary:
	var record_count := _pending_sv_field_records.size()
	if record_count <= 0:
		return {"ok": true, "record_count": 0, "gpu_dispatched": false}
	if not _grid_ready() or not _gpu_ready or _rd == null:
		return {"ok": false, "reason": "gpu_or_grid_not_ready", "record_count": record_count, "gpu_dispatched": false}
	var field_buffers: Dictionary = _tile_store.ensure_resident_field_buffers()
	var complexity_buffer: RID = field_buffers.get("complexity_field_buffer", RID())
	var collision_buffer: RID = field_buffers.get("collision_field_buffer", RID())
	if not complexity_buffer.is_valid() or not collision_buffer.is_valid():
		return {"ok": false, "reason": "resident_field_buffers_missing", "record_count": record_count, "gpu_dispatched": false}
	# committed SV 用 max-by-complexity 合并：常驻 field 可能已含 VPG state-chain stamp 内容，
	# CPU compare 门（基于 slices）看不到它们，单调合并防止低值覆写（write_mode=1）。
	# 散射维度 = 常驻 field 网格（shader 寻址 x + xz_res*(z + xz_res*slice)：XZ=grid_size.x、slice=grid_size.y）
	var scatter_result := SvFieldScatter.dispatch_scatter(
		self,
		complexity_buffer,
		collision_buffer,
		_pending_sv_field_records,
		grid_size.x,
		grid_size.y,
		1
	)
	if bool(scatter_result.get("ok", false)):
		_pending_sv_field_records.clear()
	return scatter_result

## 应用单条体素写入规格并返回提交报告(占位/实例盖章写入的统一入口)。
## V1 后职责 = ISWS 簿记 + _queue_sv_field_record 3D 散射半边（2D slices 镜像/occupancy/
## scene_voxels 投影已退役）；记录以显式 voxel_min/voxel_max(Vector3i) 为 canonical bounds，
## 缺失时由旧 2D 键换算一次（tile_store 回退分支同款语义）并计数告警。
func apply_instance_stamp_write_spec(record: Dictionary, defer_blend: bool = false, generation_tick: int = -1) -> Dictionary:
	if record.is_empty():
		return {}
	var write_tick := generation_tick if generation_tick >= 0 else _next_write_tick()
	var rec := SceneVoxelSourceRecordScript.prepare_source_record(record, write_tick)
	var record_id := str(rec.get("id", "mesh_%d" % _instance_stamp_write_specs.size()))
	rec["id"] = record_id
	if SceneVoxelTargetScript.is_target_type(str(rec.get("source_voxel_type", ""))):
		rec["target_guidance_only"] = true
		rec["height_buffer_applied"] = false
		rec["height_buffer_channels"] = []
		rec["collision_source_attached"] = false
		rec["collision_buffer_applied"] = false
		var bounds := _tile_store._scene_voxel_tile_bounds_from_record(rec)
		mark_scene_voxel_tile_bounds_dirty(
			bounds.voxel_min,
			bounds.voxel_max,
			SceneVoxelTargetScript.target_dirty_flags(),
			{}
		)
		return rec
	# 旧键兼容换算：无显式 3D bounds 时按 tile_store 回退分支（base_pixel/voxel_xz/
	# radius_px/slice_indices → min 含端点、max 不含端点）换算并回写显式键。
	var has_explicit_bounds := SceneVoxelTileCodecScript.has_any_key(rec, EXPLICIT_BOUNDS_MIN_KEYS) \
		and SceneVoxelTileCodecScript.has_any_key(rec, EXPLICIT_BOUNDS_MAX_KEYS)
	if not has_explicit_bounds:
		_note_legacy_stamp_bounds_conversion(record_id)
	var stamp_bounds := _tile_store._scene_voxel_tile_bounds_from_record(rec)
	rec["voxel_min"] = stamp_bounds.voxel_min
	rec["voxel_max"] = stamp_bounds.voxel_max
	var applied_channels: Array[int] = []
	var rec_base_px: Vector2i = rec.get("base_pixel", Vector2i.ZERO)
	var collision_layers: Array = rec.get("collision", [])
	var stamped_collision_layers: Array = _field_builder._stamp_shared_field_layers(rec_base_px, collision_layers, rec)
	var collision_buffer_applied := not stamped_collision_layers.is_empty()
	var collision_source_layers: Array = stamped_collision_layers if not stamped_collision_layers.is_empty() else collision_layers
	var updated_collision_layers := _field_builder._make_source_collision(rec_base_px, collision_source_layers, rec)
	rec["collision"] = updated_collision_layers
	# 碰撞为逐体素点采样：排队 collision-only field 散射记录（complexity < 0 跳过颜色写入），
	# 并按体素直调 3D tile 脏 API（旧 per-cell "collision" 层脏标记的等价物）
	for collision_layer in updated_collision_layers:
		if not collision_layer is Dictionary:
			continue
		var layer_dict := collision_layer as Dictionary
		var layer_strength := clampf(float(layer_dict.get("collision_strength", 0.0)), 0.0, 1.0)
		if layer_strength <= VOXEL_OCCUPIED_EPSILON:
			continue
		var layer_voxel_xz = layer_dict.get("voxel_xz", Vector2i(-1, -1))
		if not layer_voxel_xz is Vector2i:
			continue
		var layer_slice := int(layer_dict.get("slice_index", 0))
		_queue_sv_field_record(layer_voxel_xz, layer_slice, -1.0, Color.BLACK, layer_strength)
		var cell_voxel := Vector3i((layer_voxel_xz as Vector2i).x, layer_slice, (layer_voxel_xz as Vector2i).y)
		mark_scene_voxel_tile_bounds_dirty(cell_voxel, cell_voxel + Vector3i.ONE, {"collision": true}, layer_dict)
	var ch := _record_channel(rec)
	if ch >= 0:
		var channel_record := rec.duplicate(true)
		channel_record["channel"] = ch
		channel_record["base_pixel"] = rec_base_px
		var radius_px := _record_radius_px(channel_record)
		var complexity := clampf(float(channel_record.get("complexity", rec.get("complexity", 1.0))), 0.0, 1.0)
		var color := VariantUtils.color_from_value(channel_record.get("color", rec.get("color", Color.WHITE)), Color.WHITE)
		color.a = complexity
		var slice_indices := _record_slice_indices(channel_record)
		var voxel_px := _queue_stamp_disc_records(rec_base_px, radius_px, complexity, color, slice_indices)
		if not slice_indices.is_empty() and complexity > VOXEL_OCCUPIED_EPSILON:
			mark_scene_voxel_tile_bounds_dirty(stamp_bounds.voxel_min, stamp_bounds.voxel_max, {"scene": true}, rec)
		rec["channel"] = ch
		rec["base_pixel"] = rec_base_px
		rec["voxel_xz"] = voxel_px
		rec["radius_px"] = radius_px
		rec["complexity"] = complexity
		rec["color"] = color
		rec["slice_indices"] = slice_indices
		if not applied_channels.has(ch):
			applied_channels.append(ch)
	else:
		rec["base_pixel"] = rec_base_px
		rec["voxel_xz"] = _volume_px_from_base(rec_base_px, grid_size.x)
	rec["volume_xz_resolution"] = grid_size.x
	rec["height_buffer_applied"] = not applied_channels.is_empty()
	rec["height_buffer_channels"] = applied_channels
	rec["collision_source_attached"] = not updated_collision_layers.is_empty()
	rec["collision_buffer_applied"] = collision_buffer_applied
	if _instance_stamp_write_spec_index.has(record_id):
		var idx: int = _instance_stamp_write_spec_index[record_id]
		_instance_stamp_write_specs[idx] = rec
	else:
		_instance_stamp_write_spec_index[record_id] = _instance_stamp_write_specs.size()
		_instance_stamp_write_specs.append(rec)
	if not defer_blend and _grid_ready():
		commit_scene_voxels(write_tick)
	return rec

## Per placed runtime instance_stamp_write_spec entries. These connect runtime MeshInstance3D nodes back
## to the voxel channel data that was stamped for them.
var _instance_stamp_write_specs: Array[Dictionary] = []
var _instance_stamp_write_spec_index: Dictionary = {}
var _sv: Dictionary = {}

## Stamp-only commit：待散射进常驻 field buffer 的 CPU 入口盖章记录。
## 按体素线性 index 去重（复杂度后写者胜、碰撞取 max），保证单次散射 dispatch 内无同体素竞态；
## 值为 SV_FIELD_RECORD_FLOAT_STRIDE 长度的 PackedFloat32Array 槽。
var _pending_sv_field_records: Dictionary = {}

## 最近一次 commit_scene_voxels 的提交摘要
var _last_commit_summary: Dictionary = {}

var _generation_tick: int = 1
var _committed_tick: int = 0
var _sv_dirty: bool = true

## 从已有写入规格记录重建场景体素状态（清空常驻 field 后逐记录重放 stamp；
## ISWS 记录集即可重放输入，重放后由调用方 commit_scene_voxels 发布）
func _rebuild_scene_voxels_from_records() -> void:
	if not _grid_ready():
		return
	var write_tick := _next_write_tick()
	begin_generation_tick(write_tick)
	_pending_sv_field_records.clear()
	_tile_store.reset_resident_field_buffers()
	var records := get_instance_stamp_write_specs()
	for record in records:
		apply_instance_stamp_write_spec(record, true, write_tick)

## Stamp-only 提交发布点：散射 pending 盖章记录进常驻 field，推进 tick 并重建 tile 摘要。
## VPG 的 GPU state-chain stamp 已原位写入常驻 field；本函数只负责 CPU 入口盖章的散射与发布。
func commit_scene_voxels(tick: int = -1) -> Dictionary:
	if not _grid_ready():
		return {}
	var commit_tick := tick if tick >= 0 else _generation_tick
	var scatter_result := _flush_pending_sv_field_records()
	_last_commit_summary = {
		"ok": bool(scatter_result.get("ok", false)),
		"mode": "stamp_only_commit",
		"commit_tick": commit_tick,
		"scattered_field_record_count": int(scatter_result.get("record_count", 0)),
		"field_scatter_gpu_dispatched": bool(scatter_result.get("gpu_dispatched", false)),
		"field_scatter_reason": str(scatter_result.get("reason", "none")),
	}
	if not bool(scatter_result.get("ok", false)):
		push_error("[SceneVoxelCommitter] stamp-only commit field scatter failed: %s" % str(scatter_result.get("reason", "unknown")))
	_committed_tick = max(_committed_tick, commit_tick)
	_generation_tick = max(_generation_tick, commit_tick + 1)
	_sv_dirty = true
	_rebuild_sv()
	# V1：scene_voxels 公共投影 dict 已退役（查询走常驻 field 回读）；返回提交摘要副本。
	return get_last_scene_voxel_commit_summary()

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

## 常驻 field 的线性体素索引（与 scatter_sv_field_records.glsl 寻址一致：
## index = x + xz_res*(z + xz_res*slice)，XZ 方形网格假设；越界返回 -1）
func _resident_field_voxel_index(voxel: Vector3i) -> int:
	if voxel.x < 0 or voxel.x >= grid_size.x \
		or voxel.y < 0 or voxel.y >= grid_size.y \
		or voxel.z < 0 or voxel.z >= grid_size.z:
		return -1
	return voxel.x + grid_size.x * (voxel.z + grid_size.x * voxel.y)

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
		return {}
	var complexity_bytes := _rd.buffer_get_data(complexity_rid, idx * SCENE_VOXEL_TILE_COMPLEXITY_FIELD_STRIDE_BYTES, SCENE_VOXEL_TILE_COMPLEXITY_FIELD_STRIDE_BYTES)
	var collision_bytes := _rd.buffer_get_data(collision_rid, idx * SCENE_VOXEL_TILE_COLLISION_FIELD_STRIDE_BYTES, SCENE_VOXEL_TILE_COLLISION_FIELD_STRIDE_BYTES)
	if complexity_bytes.size() < SCENE_VOXEL_TILE_COMPLEXITY_FIELD_STRIDE_BYTES or collision_bytes.size() < SCENE_VOXEL_TILE_COLLISION_FIELD_STRIDE_BYTES:
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
	var sample := _sample_resident_field_voxel(voxel)
	if sample.is_empty():
		push_error("[SceneVoxelCommitter] query_voxel resident field sample failed")
		return miss
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
	var bytes := _rd.buffer_get_data(complexity_rid, 0, voxel_count * SCENE_VOXEL_TILE_COMPLEXITY_FIELD_STRIDE_BYTES)
	var result := {}
	var xz_res := maxi(grid_size.x, 1)
	var plane := xz_res * xz_res
	var limit := mini(voxel_count, int(bytes.size() / SCENE_VOXEL_TILE_COMPLEXITY_FIELD_STRIDE_BYTES))
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
	elif not _sv.is_empty():
		_tile_store._maybe_auto_upload_scene_voxel_tile_buffers("get_sv")
	return _sv.duplicate(true)

## 标记指定场景体素瓦片为脏
func _mark_scene_voxel_full_rebuild_dirty(reason: String = "full_rebuild") -> Dictionary:
	return mark_all_scene_voxel_tiles_dirty(
		{"scene": true, "collision": true},
		{
			"id": reason,
			"source_id": reason,
		}
	)

## 标记全部场景体素瓦片为脏并返回快照
func clear_sv_dirty() -> void:
	_tile_store.clear_all_dirty()
	if not _sv.is_empty():
		_sv["dirty_scene_voxel_tiles"] = {}
	_tile_store._maybe_auto_upload_scene_voxel_tile_buffers("clear_sv_dirty")

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

## SceneVoxelTileStore compatibility delegates used outside the committer.
## 返回当前 SceneVoxelTile 的三维体素尺寸 Vector3i；由 _rebuild_sv 调用，委托 _tile_store
func _scene_voxel_tile_size() -> Vector3i:
	return _tile_store._scene_voxel_tile_size()
## 应用单条 GPU autoobject 脏增量到 tile object_ref 缓冲；由 GPUAutoObjectRuntime 调用，委托 _tile_store
func apply_gpu_autoobject_dirty_delta(delta: Dictionary) -> Dictionary:
	return _tile_store.apply_gpu_autoobject_dirty_delta(delta)
## 批量应用 GPU autoobject 脏增量；由 GPUAutoObjectRuntime 批量更新时调用，委托 _tile_store
func apply_gpu_autoobject_dirty_deltas(deltas: Array) -> Dictionary:
	return _tile_store.apply_gpu_autoobject_dirty_deltas(deltas)
## 确保 SceneVoxelTile GPU 缓冲已上传；由渲染前强制同步路径调用，委托 _tile_store
func ensure_scene_voxel_tile_buffers_uploaded(force: bool = false) -> bool:
	return _tile_store.ensure_scene_voxel_tile_buffers_uploaded(force)
## 返回当前脏 SceneVoxelTile 字典（外部查询）；由调试工具、ScenePlacementActor 调用，委托 _tile_store
func get_dirty_scene_voxel_tiles() -> Dictionary:
	return _tile_store.get_dirty_scene_voxel_tiles()
## 返回 GPU autoobject object_ref 分配策略诊断信息；由调试工具调用，委托 _tile_store
func get_gpu_autoobject_object_ref_range_policy_diagnostics(refs_per_tile: int = SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT) -> Dictionary:
	return _tile_store.get_gpu_autoobject_object_ref_range_policy_diagnostics(refs_per_tile)
## 返回指定 tile 坐标的 SceneVoxelTile 数据字典；由外部查询与调试工具调用，委托 _tile_store
func get_scene_voxel_tile(tile_coord: Vector3i) -> Dictionary:
	return _tile_store.get_scene_voxel_tile(tile_coord)
## 返回指定名称的 SceneVoxelTile GPU 缓冲 RID；由 AutoObjectProbePrefilterGPU 等 GPU pass 调用，委托 _tile_store
func get_scene_voxel_tile_gpu_buffer(buffer_name: String) -> RID:
	return _tile_store.get_scene_voxel_tile_gpu_buffer(buffer_name)
## 返回 SceneVoxelTile GPU 缓冲状态摘要字典；供运行时 handoff 与诊断读取，委托 _tile_store
func get_scene_voxel_tile_gpu_buffer_status() -> Dictionary:
	return _tile_store.get_scene_voxel_tile_gpu_buffer_status()
## 返回 SceneVoxelTile summary GPU 缓冲 RID；placement/prefilter 直接消费，委托 _tile_store
func get_scene_voxel_tile_summary_gpu_buffer() -> RID:
	return _tile_store.get_scene_voxel_tile_summary_gpu_buffer()
## 返回所有 SceneVoxelTile 字典的副本；由外部查询与调试工具调用，委托 _tile_store
func get_scene_voxel_tiles() -> Dictionary:
	return _tile_store.get_scene_voxel_tiles()
## 查询 SceneVoxelTile GPU 自动上传开关状态；由调试工具调用，委托 _tile_store
func is_scene_voxel_tile_gpu_auto_upload_enabled() -> bool:
	return _tile_store.is_scene_voxel_tile_gpu_auto_upload_enabled()
## 返回 SceneVoxelTile GPU 缓冲是否就绪；由渲染路径前置检查调用，委托 _tile_store
func is_scene_voxel_tile_gpu_ready() -> bool:
	return _tile_store.is_scene_voxel_tile_gpu_ready()
## 将所有 SceneVoxelTile 标记为脏；由 _mark_scene_voxel_full_rebuild_dirty 调用，委托 _tile_store
func mark_all_scene_voxel_tiles_dirty(dirty_flags = {}, source_record: Dictionary = {}) -> Dictionary:
	return _tile_store.mark_all_scene_voxel_tiles_dirty(dirty_flags, source_record)
## 将指定体素包围盒内的 SceneVoxelTile 标记为脏；由 apply_instance_stamp_write_spec 调用，委托 _tile_store
func mark_scene_voxel_tile_bounds_dirty(voxel_min: Vector3i, voxel_max: Vector3i, dirty_flags = {}, source_record: Dictionary = {}) -> void:
	_tile_store.mark_scene_voxel_tile_bounds_dirty(voxel_min, voxel_max, dirty_flags, source_record)
## 标记指定 tile 坐标为脏；由外部直接调用路径使用，委托 _tile_store
func mark_scene_voxel_tile_dirty(tile_coord: Vector3i, dirty_flags = {}, source_record: Dictionary = {}) -> void:
	_tile_store.mark_scene_voxel_tile_dirty(tile_coord, dirty_flags, source_record)
## CPU 回读 SceneVoxelTile GPU 缓冲内容用于调试；由调试工具调用，委托 _tile_store
func readback_scene_voxel_tile_debug_snapshot() -> Dictionary:
	return _tile_store.readback_scene_voxel_tile_debug_snapshot()
## 设置 SceneVoxelTile GPU 自动上传开关并可选立即上传；由外部控制路径调用，委托 _tile_store
func set_scene_voxel_tile_gpu_auto_upload(enabled: bool, upload_now: bool = false) -> bool:
	return _tile_store.set_scene_voxel_tile_gpu_auto_upload(enabled, upload_now)
## 尝试对 CPU 增量列表执行 GPU object_ref update pass；由 GPUAutoObjectRuntime 调用，委托 _tile_store
func try_apply_gpu_autoobject_object_ref_update_pass(deltas: Array) -> Dictionary:
	return _tile_store.try_apply_gpu_autoobject_object_ref_update_pass(deltas)
## 尝试直接从 GPU 缓冲执行 object_ref update pass（零拷贝路径）；由 GPUAutoObjectRuntime 调用，委托 _tile_store
func try_apply_gpu_autoobject_object_ref_update_pass_from_buffer(dirty_delta_buffer: RID,
	dirty_delta_count: int,
	dirty_delta_capacity: int = -1,
	dirty_delta_source: String = "borrowed_dirty_delta_buffer") -> Dictionary:
	return _tile_store.try_apply_gpu_autoobject_object_ref_update_pass_from_buffer(dirty_delta_buffer, dirty_delta_count, dirty_delta_capacity, dirty_delta_source)

## Field-builder compatibility delegates used outside the committer.
## 设置地形基础碰撞场（TerrainBase 层）；由外部更新地形时调用，委托 _field_builder
func set_terrain_base_collision_field(base_collision: Image) -> void:
	_field_builder.set_terrain_base_collision_field(base_collision)
