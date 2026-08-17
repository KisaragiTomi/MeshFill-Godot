class_name SceneVoxelTileStore

## 场景体素瓦片(scene voxel tile)GPU 缓冲存储与归约子系统。
## SPA 持有的场景体素 GPU 状态：拥有瓦片记录/摘要/object-ref/dirty worklist/field
## 常驻缓冲，以及它们的创建、归约、更新和只读 GPU handoff。
## committer 只借用本对象执行提交；tile 拓扑与脏状态不存在 CPU 镜像。
extends "res://scripts/godot_compute_shader_base.gd"

const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")

const SCENE_VOXEL_TILE_SIZE_SETTING := "meshfill/scene_voxel_tile/size_voxels"

const DEFAULT_SCENE_VOXEL_TILE_SIZE := Vector3i(8, 8, 8)

## field buffer 名/格式/stride 的定义单源在 codec（SSOT），此处为单层 re-export。
const SCENE_VOXEL_TILE_RECORD_BUFFER := "scene_voxel_tile_records"
const SCENE_VOXEL_TILE_SUMMARY_BUFFER := "scene_voxel_tile_summaries"
const SCENE_VOXEL_TILE_OBJECT_REF_BUFFER := "scene_voxel_tile_object_refs"
const SCENE_VOXEL_TILE_DIRTY_FLAG_BUFFER := "scene_voxel_tile_dirty_flags"
const SCENE_VOXEL_TILE_DIRTY_WORKLIST_BUFFER := "scene_voxel_tile_dirty_worklist"
const SCENE_VOXEL_TILE_DIRTY_COUNT_BUFFER := "scene_voxel_tile_dirty_count"
const SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER := SceneVoxelTileCodecScript.SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER
const SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER := SceneVoxelTileCodecScript.SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER
const SCENE_VOXEL_TILE_GPU_BUFFER_NAMES := [
	SCENE_VOXEL_TILE_RECORD_BUFFER,
	SCENE_VOXEL_TILE_SUMMARY_BUFFER,
	SCENE_VOXEL_TILE_OBJECT_REF_BUFFER,
	SCENE_VOXEL_TILE_DIRTY_FLAG_BUFFER,
	SCENE_VOXEL_TILE_DIRTY_WORKLIST_BUFFER,
	SCENE_VOXEL_TILE_DIRTY_COUNT_BUFFER,
	SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER,
	SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER,
]
const SCENE_VOXEL_TILE_RECORD_STRIDE_BYTES := SceneVoxelTileCodecScript.RECORD_STRIDE_BYTES
const SCENE_VOXEL_TILE_SUMMARY_STRIDE_BYTES := SceneVoxelTileCodecScript.SUMMARY_STRIDE_BYTES
const SCENE_VOXEL_TILE_INDEX_STRIDE_BYTES := 4
const SCENE_VOXEL_TILE_REF_STRIDE_BYTES := 4
const SCENE_VOXEL_TILE_DIRTY_COUNT_WORDS := 2
const DIRTY_CONTROL_INITIALIZE := 0
const DIRTY_CONTROL_CLEAR := 1
const DIRTY_CONTROL_FULL := 2
const SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT := SceneVoxelTileCodecScript.SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT
const SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_PATH := "res://shaders/scene_voxel_tile_object_ref_update.glsl"
const SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_NAME := "scene_voxel_tile_object_ref_update.glsl"
const SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_STATS_CAPACITY := 10
const SCENE_VOXEL_TILE_OBJECT_REF_DIRTY_DELTA_STRIDE_BYTES := 80
const SCENE_VOXEL_TILE_OBJECT_REF_DIRTY_FLAG_SCHEMA_SCENE_VOXEL_TILE := 0
const SCENE_VOXEL_TILE_OBJECT_REF_DIRTY_FLAG_SCHEMA_GPU_AUTOOBJECT_RUNTIME := 1
const SCENE_VOXEL_TILE_OBJECT_REF_SCHEMA_NUMERIC := "u32_numeric_ref_key_v1"
const SCENE_VOXEL_TILE_OBJECT_REF_SCHEMA_LEGACY_HASH := "legacy_stable_hash_debug"
const SCENE_VOXEL_TILE_COMPLEXITY_FIELD_FORMAT := SceneVoxelTileCodecScript.SCENE_VOXEL_TILE_COMPLEXITY_FIELD_FORMAT
const SCENE_VOXEL_TILE_COLLISION_FIELD_FORMAT := SceneVoxelTileCodecScript.SCENE_VOXEL_TILE_COLLISION_FIELD_FORMAT
const SCENE_VOXEL_TILE_COMPLEXITY_FIELD_STRIDE_BYTES := SceneVoxelTileCodecScript.SCENE_VOXEL_TILE_COMPLEXITY_FIELD_STRIDE_BYTES
const SCENE_VOXEL_TILE_COLLISION_FIELD_STRIDE_BYTES := SceneVoxelTileCodecScript.SCENE_VOXEL_TILE_COLLISION_FIELD_STRIDE_BYTES
const SCENE_VOXEL_TILE_COLLISION_FIELD_UPLOAD_STRIDE_BYTES := SceneVoxelTileCodecScript.COLLISION_FIELD_U32_STRIDE_BYTES
const SCENE_VOXEL_TILE_REDUCE_SUMMARY_UINT_STRIDE := 6
const SCENE_VOXEL_TILE_COMPACT_SUMMARY_UINT_STRIDE := 8
const SCENE_VOXEL_TILE_REDUCE_QUANT_SCALE := 1000000.0

# --- push-constant schemas (std430; all-scalar blocks pack to sequential 4-byte offsets) ---
# object-ref update push (80 bytes; offsets 56 & 64 were literal 0 -> _pad)
const OBJECT_REF_UPDATE_PUSH := [
	["grid_x", "int"], ["grid_y", "int"], ["grid_z", "int"], ["dirty_delta_count", "int"],
	["tile_size_x", "int"], ["tile_size_y", "int"], ["tile_size_z", "int"], ["refs_per_tile", "int"],
	["tile_grid_x", "int"], ["tile_grid_y", "int"], ["tile_grid_z", "int"], ["total_tile_count", "int"],
	["dirty_delta_capacity", "int"], ["object_ref_capacity", "int"], ["_pad0", "int"], ["stats_capacity", "int"],
	["_pad1", "int"], ["dirty_tile_flag_capacity", "int"], ["dirty_tile_worklist_capacity", "int"], ["dirty_flag_schema", "int"],
]
# init summaries push (16 bytes; offset 12 was literal 0 -> _pad)
const REDUCE_INIT_PUSH := [
	["tile_count", "int"], ["summary_uint_stride", "int"], ["init_value", "int"], ["_pad0", "int"],
]
# reduce summaries push (64 bytes; offset 44 int-0 and offsets 56/60 float-0 -> _pad)
## dims 用规范网格三元组（grid_x/y/z），与 scatter/merge/pick/score 同一套索引式；
## voxel_count 在着色器里由 gx*gy*gz 导出（CPU 侧本来就是这么算的）。
const REDUCE_PUSH := [
	["grid_x", "int"], ["grid_y", "int"], ["grid_z", "int"], ["tile_count", "int"],
	["tile_size_x", "int"], ["tile_size_y", "int"], ["tile_size_z", "int"], ["summary_uint_stride", "int"],
	["tile_grid_x", "int"], ["tile_grid_y", "int"], ["tile_grid_z", "int"], ["_pad0", "int"],
	["occupied_epsilon", "float"], ["quant_scale", "float"], ["_pad1", "float"], ["_pad2", "float"],
]
# compact summaries push (16 bytes; offset 12 was literal 0 -> _pad)
const REDUCE_COMPACT_PUSH := [
	["tile_count", "int"], ["summary_uint_stride", "int"], ["compact_summary_uint_stride", "int"], ["_pad0", "int"],
]
# Initializes the fixed tile record, summary, and object-ref buffers without CPU staging.
const INITIALIZE_EMPTY_TILE_BUFFERS_PUSH := [
	["grid_x", "int"], ["grid_y", "int"], ["grid_z", "int"], ["tile_count", "int"],
	["tile_size_x", "int"], ["tile_size_y", "int"], ["tile_size_z", "int"], ["record_uint_stride", "int"],
	["tile_grid_x", "int"], ["tile_grid_y", "int"], ["tile_grid_z", "int"], ["summary_uint_stride", "int"],
	["refs_per_tile", "int"], ["committed_tick", "int"], ["operation", "int"], ["dirty_flags", "int"],
]
const HashUtils := preload("res://scripts/utils/hash_utils.gd")
const VariantUtils := preload("res://scripts/utils/variant_utils.gd")
const BufferUtils := preload("res://scripts/utils/buffer_utils.gd")
const SceneVoxelDebugScript := preload("res://scripts/scene_voxel_debug.gd")
## SceneSV 场对的所有者（V3 从本类劈出，见 §1.2）。本类只借设备给它并转发。
const SceneSVFieldStoreScript := preload("res://scripts/scene_sv_field_store.gd")

## committer 反向引用：读取 grid_size/_generation_tick/_committed_tick，
## 并回调 _field_builder._make_terrain_base_collision_volume_field / 写 _sv_dirty。
## 由 committer 在 setup() 中设置，teardown() 中置空以打破引用环。
var _committer: SceneVoxelCommitter = null
var _grid_owner: Object = null

## 瓦片 compute shader 就绪标志。
var _gpu_ready: bool = false

## --- tile compute kernel(本组件拥有；shader+pipeline 走基类 track/GC) ---
## setup() 之前为 null（kernel 需要已 attach 的 RenderingDevice 才能编译）。
var _kernel_reduce_summaries: ComputeKernel = null
var _kernel_init_summaries: ComputeKernel = null
var _kernel_compact_summaries: ComputeKernel = null
var _kernel_object_ref_update: ComputeKernel = null
var _kernel_initialize_empty_tile_buffers: ComputeKernel = null

## --- tile 运行时状态 ---
var _scene_voxel_tile_dirty_epoch: int = 0
var _pending_scene_voxel_tile_dirty_commands: Array[Dictionary] = []
var _pending_scene_voxel_tile_full_dirty_flags := 0
var _scene_voxel_tile_gpu_ready := false
var _scene_voxel_tile_gpu_revision := 0
var _scene_voxel_tile_last_upload_error := ""
var _scene_voxel_tile_gpu_buffers: Dictionary = {}
var _scene_voxel_tile_gpu_buffer_byte_sizes: Dictionary = {}
var _scene_voxel_tile_gpu_buffer_upload_byte_sizes: Dictionary = {}
var _scene_voxel_tile_gpu_buffer_initialization_sources: Dictionary = {}
var _scene_voxel_tile_gpu_record_counts: Dictionary = {}
var _scene_voxel_tile_gpu_strides: Dictionary = {}
var _scene_voxel_tile_gpu_buffer_hashes: Dictionary = {}
var _scene_voxel_tile_gpu_stale_reason := "never_uploaded"
var _scene_voxel_tile_gpu_last_upload_tick := -1
var _scene_voxel_tile_gpu_last_reused_buffers: Array[String] = []
var _scene_voxel_tile_last_upload_mode := "none"
var _scene_voxel_tile_last_upload_resident_voxel_count := 0
var _scene_voxel_tile_last_upload_range_count := 0
## SceneSV 场对的所有者。⚠ 它自己持有 complexity / collision 两块 RID 与它们的全部元数据；
## 本类**不再**在那 7 张字典里给场对留条目——报告与回读入口按场名分派到它。
var _field_store: SceneSVFieldStoreScript = null
var _last_tile_upload_phases_ms := {}
var _scene_voxel_tile_last_summary_dirty_range_update_source := "none"
var _scene_voxel_tile_object_ref_last_update_stats: Dictionary = {}
var _scene_voxel_tile_object_ref_key_schema := SCENE_VOXEL_TILE_OBJECT_REF_SCHEMA_LEGACY_HASH
var _scene_voxel_tile_object_ref_numeric_schema_confirmed := false
var _scene_voxel_tile_fixed_object_ref_tile_count := 0
var _scene_voxel_tile_fixed_object_ref_slot_count := 0
var _scene_voxel_tile_object_ref_rebuild_required := false
var _scene_voxel_tile_object_ref_overflow_count := 0
## Opt-in only: CPU readback of the transient dirty worklist + flag buffers after the
## object-ref update pass. These are pure diagnostic projections of the resident
## worklist/flag RIDs; the overflow control signal lives in the (always-read) stats
## buffer, so this stays off on the production path. Enable for debugging/visualization.
var debug_object_ref_dirty_cpu_readback := false

## 绑定借用的 committer 上下文并加载 tile compute shader。
func setup(committer, grid_owner: Object = null) -> void:
	_committer = committer
	_grid_owner = grid_owner
	log_name = "SceneVoxelTileStore"
	_init_tile_gpu()

## 加载本组件负责的 tile compute kernel（shader+pipeline+push 布局），置 _gpu_ready。
func _init_tile_gpu() -> void:
	_kernel_reduce_summaries = ComputeKernel.create(
		self, "res://shaders/reduce_scene_voxel_tile_summaries.glsl",
		REDUCE_PUSH, "reduce_scene_voxel_tile_summaries")
	_kernel_init_summaries = ComputeKernel.create(
		self, "res://shaders/init_scene_voxel_tile_summaries.glsl",
		REDUCE_INIT_PUSH, "init_scene_voxel_tile_summaries")
	_kernel_compact_summaries = ComputeKernel.create(
		self, "res://shaders/compact_scene_voxel_tile_summaries.glsl",
		REDUCE_COMPACT_PUSH, "compact_scene_voxel_tile_summaries")
	_kernel_object_ref_update = ComputeKernel.create(
		self, SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_PATH,
		OBJECT_REF_UPDATE_PUSH, "scene_voxel_tile_object_ref_update")
	_kernel_initialize_empty_tile_buffers = ComputeKernel.create(
		self, "res://shaders/initialize_empty_scene_voxel_tile_buffers.glsl",
		INITIALIZE_EMPTY_TILE_BUFFERS_PUSH, "initialize_empty_scene_voxel_tile_buffers")
	_gpu_ready = (ComputeKernel.ready(_kernel_reduce_summaries)
		and ComputeKernel.ready(_kernel_init_summaries)
		and ComputeKernel.ready(_kernel_compact_summaries)
		and ComputeKernel.ready(_kernel_object_ref_update)
		and ComputeKernel.ready(_kernel_initialize_empty_tile_buffers))


## 释放本组件的 tile GPU 缓冲与 shader，断开反向引用。committer 须在自身 dispose 之前调用。
func teardown() -> void:
	_release_scene_voxel_tile_gpu_buffers()
	dispose()
	_committer = null
	_grid_owner = null

func _register_scene_voxel_tile_project_settings() -> void:
	SceneVoxelTileCodecScript.register_project_settings(SCENE_VOXEL_TILE_SIZE_SETTING, DEFAULT_SCENE_VOXEL_TILE_SIZE)

## 读取配置的场景体素 tile 尺寸（全仓单源：committer/SPA/demo 均经此读取，勿再复制公式）
static func scene_voxel_tile_size() -> Vector3i:
	return SceneVoxelTileCodecScript.configured_size(SCENE_VOXEL_TILE_SIZE_SETTING, DEFAULT_SCENE_VOXEL_TILE_SIZE)

func _grid_size() -> Vector3i:
	return VoxelGeneral.grid_size_from_owner(_grid_owner, _committer, "SceneVoxelTileStore")

## 根据网格尺寸与 tile 尺寸计算 tile 网格尺寸
func _scene_voxel_tile_grid_size(tile_size: Vector3i = Vector3i.ZERO) -> Vector3i:
	var size := tile_size if tile_size.x > 0 and tile_size.y > 0 and tile_size.z > 0 else scene_voxel_tile_size()
	return SceneVoxelTileCodecScript.tile_grid_size(_grid_size(), size)


# ⚠ 编辑器软重载（@tool 脚本重新解析）后的成员修复，别当成冗余判空删掉。
#
# 事实依据（gdscript.cpp GDScriptInstance::reload_members）：软重载只把**重载前已存在**
# 的成员按名字搬进新槽位（值原样保留，不回初始值）；本次重载**新增**的成员槽是默认构造
# 的 Variant = nil，声明里的初始化器**不会**重跑。带静态类型也拦不住——实例槽本身是
# Variant。本 store 由编辑器里的 SPA 长期持有，重载后第一次上传会炸在
# `_pending_scene_voxel_tile_dirty_commands.is_empty()`、
# `_last_tile_upload_phases_ms["..."] = ...`（在 Nil 上下标写）这类位置。
#
# ⚠ 必须用 `is` 而不是 `== null`：对静态类型已知的操作数 GDScript 会挑验证求值器，而
# Variant 给 (INT, NIL)、(DICTIONARY, NIL) 这类组合注册的是 OperatorEvaluatorAlwaysFalse
# （variant_op.cpp），`x == null` 会被编成恒 false，判空形同虚设。
#
# 语义（刻意选"过脏"而不是"漏脏"）：
#  - 待提交的脏命令/全脏位一旦丢失，无法知道原本欠了哪些 tile，故一律补成
#    FLAG_SCENE|FLAG_COLLISION 全脏（与 reset_empty_scene_voxel_grid 同一取值），
#    下次上传整场重刷。多刷一次只是慢，漏刷会留下错的 GPU 场。
#  - dirty_epoch 刻意**不**回 0：它进 AutoObjectProbePrefilterGPU 的 collect 缓存键
#    （见 run_probe_prefilter 里 _make_collect_cache_key 的 dirty_epoch 参数），而对端
#    可能没跟着一起重载、仍缓存着重载前发出的小整数 epoch。从 0 重数会重新发出用过的
#    值，让对端误判缓存命中、拿旧 anchor。用 ticks_usec 播种即可跳出旧计数区间，
#    之后照旧单调 +1。
func _repair_soft_reloaded_members() -> void:
	if not (_scene_voxel_tile_dirty_epoch is int): _scene_voxel_tile_dirty_epoch = Time.get_ticks_usec()
	var dirty_state_lost := not (_pending_scene_voxel_tile_dirty_commands is Array) \
			or not (_pending_scene_voxel_tile_full_dirty_flags is int)
	if not (_pending_scene_voxel_tile_dirty_commands is Array): _pending_scene_voxel_tile_dirty_commands = []
	if not (_pending_scene_voxel_tile_full_dirty_flags is int): _pending_scene_voxel_tile_full_dirty_flags = 0
	if dirty_state_lost:
		_pending_scene_voxel_tile_full_dirty_flags |= (
			SceneVoxelTileCodecScript.FLAG_SCENE | SceneVoxelTileCodecScript.FLAG_COLLISION)
	if not (_scene_voxel_tile_gpu_buffer_initialization_sources is Dictionary):
		_scene_voxel_tile_gpu_buffer_initialization_sources = {}
	if not (_field_store is SceneSVFieldStoreScript): _field_store = null
	if not (_last_tile_upload_phases_ms is Dictionary): _last_tile_upload_phases_ms = {}


## Reset a never-committed grid without materializing one Dictionary per tile.
## Fixed topology is reconstructed directly in GPU buffers on the first upload.
func reset_empty_scene_voxel_grid() -> void:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	_scene_voxel_tile_dirty_epoch = 0
	_pending_scene_voxel_tile_dirty_commands.clear()
	_pending_scene_voxel_tile_full_dirty_flags = (
		SceneVoxelTileCodecScript.FLAG_SCENE | SceneVoxelTileCodecScript.FLAG_COLLISION)
	_release_scene_voxel_tile_gpu_buffers()
	_scene_voxel_tile_gpu_ready = false
	_scene_voxel_tile_gpu_stale_reason = "empty_grid_reset"


func is_empty_scene_voxel_tile_staging() -> bool:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	return _pending_scene_voxel_tile_dirty_commands.is_empty()

## 上传（或按需重建）全部 tile GPU 缓冲；常驻 field 对只保证存在，绝不用 CPU 内容覆盖
func ensure_scene_voxel_tile_buffers_uploaded(force: bool = false) -> bool:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	var total_t0_usec := Time.get_ticks_usec()
	var phase_t0_usec := total_t0_usec
	_last_tile_upload_phases_ms = {}
	_scene_voxel_tile_last_upload_error = ""
	if not ensure_device(true, false):
		_scene_voxel_tile_gpu_ready = false
		_scene_voxel_tile_last_upload_error = "no_rendering_device"
		_scene_voxel_tile_gpu_stale_reason = "no_rendering_device"
		return false
	if not force and is_scene_voxel_tile_gpu_ready():
		if _pending_scene_voxel_tile_full_dirty_flags != 0:
			_dispatch_scene_voxel_tile_dirty_control(
				DIRTY_CONTROL_FULL, _pending_scene_voxel_tile_full_dirty_flags)
			_pending_scene_voxel_tile_full_dirty_flags = 0
		if not _pending_scene_voxel_tile_dirty_commands.is_empty():
			_flush_pending_scene_voxel_tile_dirty_commands()
		_last_tile_upload_phases_ms["cached"] = true
		_last_tile_upload_phases_ms["total"] = float(Time.get_ticks_usec() - total_t0_usec) / 1000.0
		return true
	_scene_voxel_tile_gpu_last_reused_buffers.clear()
	# Stamp-only commit：常驻 field buffer 是持久 stamp 目标（VPG state-chain stamp /
	# CPU 入口散射直写），上传路径只保证其存在，绝不用 CPU 内容覆盖。
	phase_t0_usec = Time.get_ticks_usec()
	var field_buffers := ensure_resident_field_buffers()
	_last_tile_upload_phases_ms["ensure_resident_fields"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	if field_buffers.is_empty():
		_scene_voxel_tile_gpu_ready = false
		if _scene_voxel_tile_last_upload_error.is_empty():
			_scene_voxel_tile_last_upload_error = "resident_field_buffer_create_failed"
		return false
	var resident_voxel_count := int(field_buffers.get("voxel_count", 0))
	var preserved_field_buffers: Array[String] = [
		SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER,
		SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER,
	]
	var topology_created := false
	if not _fixed_scene_voxel_tile_gpu_buffers_current():
		phase_t0_usec = Time.get_ticks_usec()
		_release_scene_voxel_tile_gpu_buffers(preserved_field_buffers)
		_last_tile_upload_phases_ms["release_old_buffers"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
		phase_t0_usec = Time.get_ticks_usec()
		if not _initialize_empty_scene_voxel_tile_gpu_buffers():
			_release_scene_voxel_tile_gpu_buffers(preserved_field_buffers)
			_scene_voxel_tile_gpu_ready = false
			if _scene_voxel_tile_last_upload_error.is_empty():
				_scene_voxel_tile_last_upload_error = "gpu_empty_tile_buffer_initialize_failed"
			return false
		_last_tile_upload_phases_ms["gpu_initialize_fixed_buffers"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
		topology_created = true
	_scene_voxel_tile_gpu_ready = true
	if not topology_created and _pending_scene_voxel_tile_full_dirty_flags != 0:
		_dispatch_scene_voxel_tile_dirty_control(
			DIRTY_CONTROL_FULL, _pending_scene_voxel_tile_full_dirty_flags)
		_pending_scene_voxel_tile_full_dirty_flags = 0
	_scene_voxel_tile_gpu_revision += 1
	_scene_voxel_tile_gpu_last_upload_tick = _committer._generation_tick
	_scene_voxel_tile_gpu_stale_reason = ""
	_scene_voxel_tile_last_upload_error = ""
	_scene_voxel_tile_last_upload_mode = "gpu_initialized_resident_topology" if topology_created else "resident_buffers_reused"
	_scene_voxel_tile_last_summary_dirty_range_update_source = "gpu_resident_summary"
	_scene_voxel_tile_last_upload_resident_voxel_count = resident_voxel_count
	_scene_voxel_tile_last_upload_range_count = 1 if resident_voxel_count > 0 else 0
	_scene_voxel_tile_gpu_last_reused_buffers.clear()
	if not bool(field_buffers.get("created", false)):
		for buf_name in preserved_field_buffers:
			_scene_voxel_tile_gpu_last_reused_buffers.append(buf_name)
	_last_tile_upload_phases_ms["cached"] = false
	if not _pending_scene_voxel_tile_dirty_commands.is_empty():
		_flush_pending_scene_voxel_tile_dirty_commands()
	_last_tile_upload_phases_ms["total"] = float(Time.get_ticks_usec() - total_t0_usec) / 1000.0
	return true


func _fixed_scene_voxel_tile_gpu_buffers_current() -> bool:
	var tile_count := _scene_voxel_tile_total_tile_count()
	var expected_sizes := {
		SCENE_VOXEL_TILE_RECORD_BUFFER: tile_count * SCENE_VOXEL_TILE_RECORD_STRIDE_BYTES,
		SCENE_VOXEL_TILE_SUMMARY_BUFFER: tile_count * SCENE_VOXEL_TILE_SUMMARY_STRIDE_BYTES,
		SCENE_VOXEL_TILE_OBJECT_REF_BUFFER: tile_count * SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT * SCENE_VOXEL_TILE_REF_STRIDE_BYTES,
		SCENE_VOXEL_TILE_DIRTY_FLAG_BUFFER: tile_count * SCENE_VOXEL_TILE_REF_STRIDE_BYTES,
		SCENE_VOXEL_TILE_DIRTY_WORKLIST_BUFFER: tile_count * SCENE_VOXEL_TILE_INDEX_STRIDE_BYTES,
		SCENE_VOXEL_TILE_DIRTY_COUNT_BUFFER: SCENE_VOXEL_TILE_DIRTY_COUNT_WORDS * SCENE_VOXEL_TILE_REF_STRIDE_BYTES,
	}
	for buffer_name in expected_sizes:
		var rid: RID = _scene_voxel_tile_gpu_buffers.get(buffer_name, RID())
		if not rid.is_valid() or int(_scene_voxel_tile_gpu_buffer_byte_sizes.get(buffer_name, 0)) != int(expected_sizes[buffer_name]):
			return false
	return true


## initialize_empty_scene_voxel_tile_buffers kernel 的共用派发：固定 6 个瓦片缓冲按
## record/summary/object_ref/dirty_flag/dirty_worklist/dirty_count 顺序绑到 set 0 的 binding 0..5，
## 单段 dispatch。committed_tick 恒取 committer 当前值，operation/dirty_flags 由调用方给定
## （初始化通道与 dirty-control 通道取值不同，故不在此处合并）。
func _dispatch_initialize_empty_tile_buffers_kernel(
	buffers: Array,
	tile_size: Vector3i,
	tile_grid: Vector3i,
	tile_count: int,
	operation: int,
	dirty_flags: int
) -> bool:
	var set0 := _kernel_initialize_empty_tile_buffers.bind_storage(buffers)
	if not set0.is_valid():
		return false
	var grid := _grid_size()
	var pass_desc := _kernel_initialize_empty_tile_buffers.make_pass_sets([set0], {
		grid_x = grid.x,
		grid_y = grid.y,
		grid_z = grid.z,
		tile_count = tile_count,
		tile_size_x = tile_size.x,
		tile_size_y = tile_size.y,
		tile_size_z = tile_size.z,
		record_uint_stride = int(SCENE_VOXEL_TILE_RECORD_STRIDE_BYTES / 4),
		tile_grid_x = tile_grid.x,
		tile_grid_y = tile_grid.y,
		tile_grid_z = tile_grid.z,
		summary_uint_stride = int(SCENE_VOXEL_TILE_SUMMARY_STRIDE_BYTES / 4),
		refs_per_tile = SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT,
		committed_tick = _committer._committed_tick,
		operation = operation,
		dirty_flags = dirty_flags,
	}, _kernel_initialize_empty_tile_buffers.groups_1d(tile_count, 64))
	# 本 store 用的是 committer 借出的 RenderingDevice：sync_include_global 必须留 false，
	# 提交由设备所有者（committer）统一完成，此处提前全局同步会破坏其批次语义。
	return ComputePassChain.run(self, [pass_desc])


## Creates the fixed empty tile topology and fully writes all three buffers on the GPU.
## Input: grid/tile dimensions and commit tick. Output: records, summaries, object refs.
## Synchronization: submit_and_sync completes initialization before any consumer can bind them.
func _initialize_empty_scene_voxel_tile_gpu_buffers() -> bool:
	if _rd == null or not ComputeKernel.ready(_kernel_initialize_empty_tile_buffers):
		return false
	var tile_size := scene_voxel_tile_size()
	var tile_grid := _scene_voxel_tile_grid_size(tile_size)
	var tile_count := _scene_voxel_tile_total_tile_count(tile_grid)
	if tile_count <= 0:
		return false
	var record_byte_count := tile_count * SCENE_VOXEL_TILE_RECORD_STRIDE_BYTES
	var summary_byte_count := tile_count * SCENE_VOXEL_TILE_SUMMARY_STRIDE_BYTES
	var object_ref_count := tile_count * SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT
	var object_ref_byte_count := object_ref_count * SCENE_VOXEL_TILE_REF_STRIDE_BYTES
	var dirty_flag_byte_count := tile_count * SCENE_VOXEL_TILE_REF_STRIDE_BYTES
	var dirty_worklist_byte_count := tile_count * SCENE_VOXEL_TILE_INDEX_STRIDE_BYTES
	var dirty_count_byte_count := SCENE_VOXEL_TILE_DIRTY_COUNT_WORDS * SCENE_VOXEL_TILE_REF_STRIDE_BYTES
	var record_buffer := storage_buffer_uninitialized(
		record_byte_count, SCOPE_PERSISTENT, "scene_voxel_tile:%s" % SCENE_VOXEL_TILE_RECORD_BUFFER)
	var summary_buffer := storage_buffer_uninitialized(
		summary_byte_count, SCOPE_PERSISTENT, "scene_voxel_tile:%s" % SCENE_VOXEL_TILE_SUMMARY_BUFFER)
	var object_ref_buffer := storage_buffer_uninitialized(
		object_ref_byte_count, SCOPE_PERSISTENT, "scene_voxel_tile:%s" % SCENE_VOXEL_TILE_OBJECT_REF_BUFFER)
	var dirty_flag_buffer := storage_buffer_uninitialized(
		dirty_flag_byte_count, SCOPE_PERSISTENT, "scene_voxel_tile:%s" % SCENE_VOXEL_TILE_DIRTY_FLAG_BUFFER)
	var dirty_worklist_buffer := storage_buffer_uninitialized(
		dirty_worklist_byte_count, SCOPE_PERSISTENT, "scene_voxel_tile:%s" % SCENE_VOXEL_TILE_DIRTY_WORKLIST_BUFFER)
	var dirty_count_buffer := storage_buffer_uninitialized(
		dirty_count_byte_count, SCOPE_PERSISTENT, "scene_voxel_tile:%s" % SCENE_VOXEL_TILE_DIRTY_COUNT_BUFFER)
	var initialized_buffers: Array[RID] = [
		record_buffer,
		summary_buffer,
		object_ref_buffer,
		dirty_flag_buffer,
		dirty_worklist_buffer,
		dirty_count_buffer,
	]
	for rid in initialized_buffers:
		if rid.is_valid():
			continue
		for allocated_rid in initialized_buffers:
			if allocated_rid.is_valid():
				release_rid(allocated_rid, false)
		return false
	var initial_dirty_flags := _pending_scene_voxel_tile_full_dirty_flags \
		if _pending_scene_voxel_tile_full_dirty_flags != 0 \
		else SceneVoxelTileCodecScript.FLAG_SCENE | SceneVoxelTileCodecScript.FLAG_COLLISION
	var initialized := _dispatch_initialize_empty_tile_buffers_kernel(
		initialized_buffers, tile_size, tile_grid, tile_count,
		DIRTY_CONTROL_INITIALIZE, initial_dirty_flags)
	gc_scope(SCOPE_PASS)
	if not initialized:
		for rid in initialized_buffers:
			release_rid(rid, false)
		return false
	_register_gpu_initialized_tile_buffer(
		SCENE_VOXEL_TILE_RECORD_BUFFER, record_buffer, record_byte_count,
		tile_count, SCENE_VOXEL_TILE_RECORD_STRIDE_BYTES)
	_register_gpu_initialized_tile_buffer(
		SCENE_VOXEL_TILE_SUMMARY_BUFFER, summary_buffer, summary_byte_count,
		tile_count, SCENE_VOXEL_TILE_SUMMARY_STRIDE_BYTES)
	_register_gpu_initialized_tile_buffer(
		SCENE_VOXEL_TILE_OBJECT_REF_BUFFER, object_ref_buffer, object_ref_byte_count,
		object_ref_count, SCENE_VOXEL_TILE_REF_STRIDE_BYTES)
	_register_gpu_initialized_tile_buffer(
		SCENE_VOXEL_TILE_DIRTY_FLAG_BUFFER, dirty_flag_buffer, dirty_flag_byte_count,
		tile_count, SCENE_VOXEL_TILE_REF_STRIDE_BYTES)
	_register_gpu_initialized_tile_buffer(
		SCENE_VOXEL_TILE_DIRTY_WORKLIST_BUFFER, dirty_worklist_buffer, dirty_worklist_byte_count,
		tile_count, SCENE_VOXEL_TILE_INDEX_STRIDE_BYTES)
	_register_gpu_initialized_tile_buffer(
		SCENE_VOXEL_TILE_DIRTY_COUNT_BUFFER, dirty_count_buffer, dirty_count_byte_count,
		SCENE_VOXEL_TILE_DIRTY_COUNT_WORDS, SCENE_VOXEL_TILE_REF_STRIDE_BYTES)
	_scene_voxel_tile_fixed_object_ref_tile_count = tile_count
	_scene_voxel_tile_fixed_object_ref_slot_count = object_ref_count
	_scene_voxel_tile_dirty_epoch += 1
	_pending_scene_voxel_tile_full_dirty_flags = 0
	return true


func _register_gpu_initialized_tile_buffer(
	buffer_name: String,
	rid: RID,
	byte_count: int,
	record_count: int,
	stride_bytes: int
) -> void:
	_scene_voxel_tile_gpu_buffers[buffer_name] = rid
	_scene_voxel_tile_gpu_buffer_byte_sizes[buffer_name] = byte_count
	_scene_voxel_tile_gpu_buffer_upload_byte_sizes[buffer_name] = 0
	_scene_voxel_tile_gpu_buffer_initialization_sources[buffer_name] = "gpu_full_write"
	_scene_voxel_tile_gpu_record_counts[buffer_name] = record_count
	_scene_voxel_tile_gpu_strides[buffer_name] = stride_bytes
	_scene_voxel_tile_gpu_buffer_hashes[buffer_name] = 0

## Stamp-only commit：确保常驻 field buffer 存在（仅缺失/体素数变化时重建）。
##
## ⚠ **场对本身已不归本类**（《AutoVolume 公用体积基类计划》§1.2 / V3）。
## 分配、地形基底播种、逐阶段打点、7 项状态元数据全部搬进 `SceneSVFieldStore`；
## 本类只剩「借设备 + 转发」，以及在报告/回读入口按场名分派。
## 本类因此退化为计划要的**归约算子**：reduce / compact / object-ref / dirty 那几趟。
func ensure_resident_field_buffers() -> Dictionary:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	if not ensure_device(true, false):
		push_error("[SceneVoxelTileStore] ensure_resident_field_buffers: 无可用 RenderingDevice —— 常驻 field buffer 无法创建")
		assert(false, "SceneVoxelTileStore: no RenderingDevice for resident field buffers")
		return {}
	var store := _ensure_field_store()
	if store == null:
		return {}
	var result := store.ensure_fields()
	if result.is_empty():
		# 成因已由 SceneSVFieldStore 报出；把它的错误串接到本类既有的上传错误通道，
		# 这样 get_scene_voxel_tile_gpu_buffer_status() 的 reason 口径不变。
		_scene_voxel_tile_last_upload_error = store.last_error()
	return result


## 场对所有者。惰性建，并把**本类的**设备借给它。
##
## ⚠ 必须同设备：地形种子的 GPU 直写是「field store 建 RID → committer 的 field_builder
## 往里写」，而 field_builder 用的是 committer 灌进来的那一个 `_rd`（与本类同源）。
## 不同设备的表现是 RID 在错误的设备上被绑定。
func _ensure_field_store() -> SceneSVFieldStoreScript:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	if _field_store == null:
		_field_store = SceneSVFieldStoreScript.new()
	_field_store.configure(_committer, _grid_owner)
	if _field_store.get_rendering_device() != _rd:
		if _field_store.get_rendering_device() != null:
			# attach_rendering_device 拒绝替换正在使用的设备，必须先 dispose 再重建。
			_field_store.dispose(false)
			_field_store = SceneSVFieldStoreScript.new()
			_field_store.configure(_committer, _grid_owner)
		if _rd != null and not _field_store.attach_rendering_device(_rd, false):
			push_error("[SceneVoxelTileStore] _ensure_field_store: 场对所有者绑定 RenderingDevice 失败 —— SceneSV 场对无法创建。")
			assert(false, "SceneVoxelTileStore: field store device attach failed")
			return null
	return _field_store



func get_initialization_phases_ms() -> Dictionary:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	return {
		# 场对那半段的打点已随场对搬进 SceneSVFieldStore；键名与形状不变。
		"resident_field_creation": _field_store.initialization_phases_ms() if _field_store != null else {},
		"tile_upload": _last_tile_upload_phases_ms.duplicate(true),
	}

## 重置常驻 field buffer（复杂度清零、碰撞重播地形基底）；供全量重放 stamp 记录前调用
func reset_resident_field_buffers() -> Dictionary:
	var store := _ensure_field_store()
	return store.reset_fields() if store != null else {}

## ⚠ 场对所有者的拆卸必须挂在这里，且必须**先于** `dispose()` 的其余步骤。
##
## 落地时踩过的坑：不接这一段的表现是
##   1. `WARNING: 2 RIDs of type "StorageBuffer" were leaked.` —— 正是两块场对；
##   2. `SCRIPT ERROR: Attempt to call function 'dispose' in base 'null instance'`
##      —— field store 作为 RefCounted 被 GC 时才走 `NOTIFICATION_PREDELETE → dispose()`，
##      那时它借用的设备与 committer 都已经拆完，只剩一个半死的实例。
## 显式在这里释放 + 断引用，把回收挪回「所有人都还活着」的时刻。
## 同款理由见 `VoxelMultiMeshWriterGPU` 关于 PREDELETE 的注释。
##
## `release_fields()` 还两块 buffer 并清元数据，`dispose(false)` 把它标记为已拆
## —— 后者是必须的：不标记的话 PREDELETE 仍会再进一次 `dispose()`，而那时它已是个半死实例。
## 设备是**借来的**（`attach_rendering_device(rd, false)`，owns=false），
## 所以 dispose 走不到基类的设备释放分支，不会误伤 committer 的 `_rd`。
func _on_before_dispose() -> void:
	if _field_store != null:
		_field_store.release_fields()
		_field_store.dispose(false)
		_field_store = null


## 将GPU自动对象脏增量打包为字节序列
func _pack_gpu_autoobject_dirty_delta_words(deltas: Array) -> PackedByteArray:
	var bytes := PackedByteArray()
	for delta_index in range(deltas.size()):
		var raw_delta = deltas[delta_index]
		if not raw_delta is Dictionary:
			# 以前静默跳过：该对象的 object-ref/脏标记整条丢失，tile 索引与实际放置永久错位。
			push_error("[SceneVoxelTileStore] _pack_gpu_autoobject_dirty_delta_words: deltas[%d] 不是 Dictionary（typeof=%d 值=%s，批大小=%d）—— 拒绝丢弃该条并继续打包" % [delta_index, typeof(raw_delta), str(raw_delta), deltas.size()])
			assert(false, "SceneVoxelTileStore: non-Dictionary entry in dirty delta batch")
			return PackedByteArray()
		var delta: Dictionary = raw_delta
		var base := bytes.size()
		bytes.resize(base + SCENE_VOXEL_TILE_OBJECT_REF_DIRTY_DELTA_STRIDE_BYTES)

		var object_id := _scene_voxel_tile_numeric_object_id(delta)
		var object_type := int(delta.get("object_type", 0))
		var profile_id := int(delta.get("profile_id", delta.get("runtime_profile_id", 0)))
		var generation := int(delta.get("generation", 0))
		var removed := SceneVoxelTileCodecScript.delta_removed(delta)
		var alive_after := bool(delta.get("alive", not removed))
		var delta_bounds := SceneVoxelTileCodecScript.delta_bounds(delta)
		var new_min: Vector3i = delta_bounds.get("new_min", Vector3i.ZERO)
		var new_max: Vector3i = delta_bounds.get("new_max", Vector3i.ONE)
		var old_min: Vector3i = delta_bounds.get("old_min", Vector3i.ZERO)
		var old_max: Vector3i = delta_bounds.get("old_max", Vector3i.ONE)
		var dirty_flags := SceneVoxelTileCodecScript.flags_from_value(delta.get("dirty_flags", {"auto": true, "object_refs": true}), "")

		bytes.encode_s32(base + 0, object_id)
		bytes.encode_s32(base + 4, object_type)
		bytes.encode_s32(base + 8, profile_id)
		bytes.encode_s32(base + 12, generation)
		BufferUtils.encode_vec3i4_with_w(bytes, base + 16, old_min, 1 if removed else 0)
		BufferUtils.encode_vec3i4_with_w(bytes, base + 32, old_max, 1 if alive_after else 0)
		BufferUtils.encode_vec3i4_with_w(bytes, base + 48, new_min, SceneVoxelTileCodecScript.flags_to_bits(dirty_flags))
		BufferUtils.encode_vec3i4_with_w(bytes, base + 64, new_max, int(delta.get("flush_epoch", 0)))
	return bytes

## 组装对象引用更新 kernel 的 push 字段值（打包由 kernel 的 OBJECT_REF_UPDATE_PUSH 布局完成）
func _scene_voxel_tile_object_ref_update_push_values(
	dirty_delta_count: int,
	dirty_delta_capacity: int,
	object_ref_capacity: int,
	stats_capacity: int,
	dirty_tile_flag_capacity: int = 0,
	dirty_tile_worklist_capacity: int = 0,
	dirty_flag_schema: int = SCENE_VOXEL_TILE_OBJECT_REF_DIRTY_FLAG_SCHEMA_SCENE_VOXEL_TILE
) -> Dictionary:
	var tile_size := scene_voxel_tile_size()
	var tile_grid := _scene_voxel_tile_grid_size(tile_size)
	return {
		grid_x = _grid_size().x,
		grid_y = _grid_size().y,
		grid_z = _grid_size().z,
		dirty_delta_count = dirty_delta_count,
		tile_size_x = tile_size.x,
		tile_size_y = tile_size.y,
		tile_size_z = tile_size.z,
		refs_per_tile = SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT,
		tile_grid_x = tile_grid.x,
		tile_grid_y = tile_grid.y,
		tile_grid_z = tile_grid.z,
		total_tile_count = _scene_voxel_tile_total_tile_count(tile_grid),
		dirty_delta_capacity = dirty_delta_capacity,
		object_ref_capacity = object_ref_capacity,
		stats_capacity = stats_capacity,
		dirty_tile_flag_capacity = dirty_tile_flag_capacity,
		dirty_tile_worklist_capacity = dirty_tile_worklist_capacity,
		dirty_flag_schema = dirty_flag_schema,
	}

## 构造空的对象引用更新统计结果
func _empty_scene_voxel_tile_object_ref_update_stats(reason: String) -> Dictionary:
	return {
		"ok": false,
		"reason": reason,
		"gpu_dispatched": false,
		"stats_available": false,
		"source": "none",
		"shader": SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_NAME,
		"overflow": 0,
		"non_numeric": 0,
		"duplicate": 0,
		"touched": 0,
		"removed_slots": 0,
		"inserted_slots": 0,
		"invalid_bounds": 0,
		"skipped": 0,
		"transient_dirty_scene_voxel_tile_gpu_emitted": false,
		"transient_dirty_scene_voxel_tile_count": 0,
		"transient_dirty_scene_voxel_tile_worklist_count": 0,
		"transient_dirty_scene_voxel_tile_flagged_count": 0,
		"transient_dirty_scene_voxel_tile_ids": [],
		"transient_dirty_scene_voxel_tile_indices": [],
		"transient_dirty_scene_voxel_tile_flags": {},
		"transient_dirty_scene_voxel_tile_flag_bits": {},
		"transient_dirty_scene_voxel_tile_flag_schema": "none",
		"transient_dirty_scene_voxel_tile_source": "none",
		"transient_dirty_scene_voxel_tile_flag_capacity": 0,
		"transient_dirty_scene_voxel_tile_worklist_capacity": 0,
		"transient_dirty_scene_voxel_tile_worklist_overflow_count": 0,
		"transient_dirty_scene_voxel_tile_cpu_metadata_bridge": "none",
	}

## 记录失败原因到 last_update_stats 并返回其深拷贝；对象引用更新各失败出口共用
func _fail_object_ref_update_stats(reason: String) -> Dictionary:
	_scene_voxel_tile_object_ref_last_update_stats = _empty_scene_voxel_tile_object_ref_update_stats(reason)
	return _scene_voxel_tile_object_ref_last_update_stats.duplicate(true)

## 安全读取统计字数组的指定索引值
func _scene_voxel_tile_object_ref_update_stat(words: PackedInt32Array, index: int) -> int:
	if index < 0 or index >= words.size():
		return 0
	return maxi(int(words[index]), 0)

## 根据脏增量来源返回对应的脏标记schema枚举
func _scene_voxel_tile_object_ref_dirty_flag_schema(dirty_delta_source: String) -> int:
	if dirty_delta_source.contains("gpu_autoobject_runtime"):
		return SCENE_VOXEL_TILE_OBJECT_REF_DIRTY_FLAG_SCHEMA_GPU_AUTOOBJECT_RUNTIME
	return SCENE_VOXEL_TILE_OBJECT_REF_DIRTY_FLAG_SCHEMA_SCENE_VOXEL_TILE

## 将脏标记schema枚举转为可读名称
func _scene_voxel_tile_object_ref_dirty_flag_schema_name(schema: int) -> String:
	if schema == SCENE_VOXEL_TILE_OBJECT_REF_DIRTY_FLAG_SCHEMA_GPU_AUTOOBJECT_RUNTIME:
		return "gpu_autoobject_runtime_dirty_flags"
	return "scene_voxel_tile_dirty_flags"

## 解码瞬态脏瓦片的标记位与工作清单
func _decode_scene_voxel_tile_object_ref_transient_dirty_tiles(
	dirty_flag_bytes: PackedByteArray,
	dirty_worklist_bytes: PackedByteArray,
	tile_grid: Vector3i,
	worklist_count: int
) -> Dictionary:
	var tile_count := _scene_voxel_tile_total_tile_count(tile_grid)
	var available_flag_count := mini(tile_count, int(dirty_flag_bytes.size() / SCENE_VOXEL_TILE_REF_STRIDE_BYTES))
	var flagged_tile_count := 0
	for tile_index in range(available_flag_count):
		if int(dirty_flag_bytes.decode_u32(tile_index * SCENE_VOXEL_TILE_REF_STRIDE_BYTES)) != 0:
			flagged_tile_count += 1

	var available_worklist_count := mini(
		maxi(worklist_count, 0),
		int(dirty_worklist_bytes.size() / SCENE_VOXEL_TILE_INDEX_STRIDE_BYTES)
	)
	var tile_ids: Array[String] = []
	var tile_indices: Array[int] = []
	var flags_by_tile_id := {}
	var flag_bits_by_tile_id := {}

	for slot in range(available_worklist_count):
		var tile_index := int(dirty_worklist_bytes.decode_u32(slot * SCENE_VOXEL_TILE_INDEX_STRIDE_BYTES))
		if tile_index < 0 or tile_index >= tile_count:
			continue
		var flag_offset := tile_index * SCENE_VOXEL_TILE_REF_STRIDE_BYTES
		var flag_bits := 0
		if flag_offset + SCENE_VOXEL_TILE_REF_STRIDE_BYTES <= dirty_flag_bytes.size():
			flag_bits = int(dirty_flag_bytes.decode_u32(flag_offset))
		if flag_bits == 0:
			continue
		var tile_coord := SceneVoxelTileCodecScript.tile_coord_from_index(tile_index, tile_grid)
		var tile_key := SceneVoxelTileCodecScript.tile_key(tile_coord)
		tile_ids.append(tile_key)
		tile_indices.append(tile_index)
		flag_bits_by_tile_id[tile_key] = flag_bits
		flags_by_tile_id[tile_key] = SceneVoxelTileCodecScript.flags_from_bits(flag_bits)

	return {
		"flagged_tile_count": flagged_tile_count,
		"worklist_read_count": available_worklist_count,
		"tile_ids": tile_ids,
		"tile_indices": tile_indices,
		"flag_bits_by_tile_id": flag_bits_by_tile_id,
		"flags_by_tile_id": flags_by_tile_id,
	}

## 将瞬态脏瓦片结果合并到返回字典
func _merge_scene_voxel_tile_object_ref_transient_dirty_result(result: Dictionary, update_stats: Dictionary) -> void:
	result["transient_dirty_scene_voxel_tile_gpu_emitted"] = bool(update_stats.get("transient_dirty_scene_voxel_tile_gpu_emitted", false))
	result["transient_dirty_scene_voxel_tile_count"] = int(update_stats.get("transient_dirty_scene_voxel_tile_count", 0))
	result["transient_dirty_scene_voxel_tile_worklist_count"] = int(update_stats.get("transient_dirty_scene_voxel_tile_worklist_count", 0))
	result["transient_dirty_scene_voxel_tile_flagged_count"] = int(update_stats.get("transient_dirty_scene_voxel_tile_flagged_count", 0))
	result["transient_dirty_scene_voxel_tile_ids"] = update_stats.get("transient_dirty_scene_voxel_tile_ids", [])
	result["transient_dirty_scene_voxel_tile_indices"] = update_stats.get("transient_dirty_scene_voxel_tile_indices", [])
	result["transient_dirty_scene_voxel_tile_flags"] = update_stats.get("transient_dirty_scene_voxel_tile_flags", {})
	result["transient_dirty_scene_voxel_tile_flag_bits"] = update_stats.get("transient_dirty_scene_voxel_tile_flag_bits", {})
	result["transient_dirty_scene_voxel_tile_flag_schema"] = str(update_stats.get("transient_dirty_scene_voxel_tile_flag_schema", "none"))
	result["transient_dirty_scene_voxel_tile_source"] = str(update_stats.get("transient_dirty_scene_voxel_tile_source", "none"))
	result["transient_dirty_scene_voxel_tile_flag_capacity"] = int(update_stats.get("transient_dirty_scene_voxel_tile_flag_capacity", 0))
	result["transient_dirty_scene_voxel_tile_worklist_capacity"] = int(update_stats.get("transient_dirty_scene_voxel_tile_worklist_capacity", 0))
	result["transient_dirty_scene_voxel_tile_worklist_overflow_count"] = int(update_stats.get("transient_dirty_scene_voxel_tile_worklist_overflow_count", 0))
	result["transient_dirty_scene_voxel_tile_cpu_metadata_bridge"] = str(update_stats.get("transient_dirty_scene_voxel_tile_cpu_metadata_bridge", "none"))

## 基于借用脏增量缓冲执行GPU对象引用更新
func _update_gpu_autoobject_object_refs_from_dirty_delta_buffer(
	dirty_delta_buffer: RID,
	dirty_delta_count: int,
	dirty_delta_capacity: int,
	dirty_delta_source: String = "borrowed_dirty_delta_buffer"
) -> Dictionary:
	if not _gpu_ready or _rd == null:
		return _fail_object_ref_update_stats("object_ref_update_gpu_not_ready")

	if not ComputeKernel.ready(_kernel_object_ref_update):
		return _fail_object_ref_update_stats("object_ref_update_pipeline_not_ready")

	if dirty_delta_count <= 0:
		return _fail_object_ref_update_stats("empty_dirty_delta_batch")

	if not dirty_delta_buffer.is_valid():
		return _fail_object_ref_update_stats("dirty_delta_buffer_not_ready")

	var object_ref_buffer: RID = _scene_voxel_tile_gpu_buffers.get(SCENE_VOXEL_TILE_OBJECT_REF_BUFFER, RID())
	if not object_ref_buffer.is_valid():
		return _fail_object_ref_update_stats("object_ref_buffer_not_uploaded")

	var tile_grid := _scene_voxel_tile_grid_size()
	var tile_count := _scene_voxel_tile_total_tile_count(tile_grid)
	var object_ref_capacity := tile_count * SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT
	var expected_byte_count := object_ref_capacity * SCENE_VOXEL_TILE_REF_STRIDE_BYTES
	if int(_scene_voxel_tile_gpu_buffer_byte_sizes.get(SCENE_VOXEL_TILE_OBJECT_REF_BUFFER, 0)) < expected_byte_count:
		return _fail_object_ref_update_stats("object_ref_buffer_capacity_mismatch")

	var dirty_tile_flag_capacity := tile_count
	var dirty_tile_worklist_capacity := tile_count
	var dirty_tile_flag_buffer: RID = _scene_voxel_tile_gpu_buffers.get(
		SCENE_VOXEL_TILE_DIRTY_FLAG_BUFFER, RID())
	var dirty_tile_worklist_buffer: RID = _scene_voxel_tile_gpu_buffers.get(
		SCENE_VOXEL_TILE_DIRTY_WORKLIST_BUFFER, RID())
	var dirty_tile_count_buffer: RID = _scene_voxel_tile_gpu_buffers.get(
		SCENE_VOXEL_TILE_DIRTY_COUNT_BUFFER, RID())
	var stats_buffer := storage_buffer_zero(
		SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_STATS_CAPACITY * SCENE_VOXEL_TILE_REF_STRIDE_BYTES,
		SCOPE_FRAME,
		"scene_voxel_tile_object_ref_update_stats"
	)
	if not stats_buffer.is_valid() or not dirty_tile_flag_buffer.is_valid() \
			or not dirty_tile_worklist_buffer.is_valid() or not dirty_tile_count_buffer.is_valid():
		gc_frame()
		return _fail_object_ref_update_stats("resident_dirty_buffer_not_ready")

	var set0 := _kernel_object_ref_update.bind_storage([
		dirty_delta_buffer,
		object_ref_buffer,
		stats_buffer,
		dirty_tile_flag_buffer,
		dirty_tile_worklist_buffer,
		dirty_tile_count_buffer,
	])
	if not set0.is_valid():
		gc_frame()
		return _fail_object_ref_update_stats("object_ref_update_uniform_set_create_failed")

	var dirty_flag_schema := _scene_voxel_tile_object_ref_dirty_flag_schema(dirty_delta_source)
	var dispatch_groups := Vector3i(1, 1, 1)
	var update_pass := _kernel_object_ref_update.make_pass_sets([set0], _scene_voxel_tile_object_ref_update_push_values(
		dirty_delta_count,
		maxi(dirty_delta_capacity, dirty_delta_count),
		object_ref_capacity,
		SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_STATS_CAPACITY,
		dirty_tile_flag_capacity,
		dirty_tile_worklist_capacity,
		dirty_flag_schema
	), dispatch_groups)
	if not ComputePassChain.run(self, [update_pass]):
		gc_frame()
		return _fail_object_ref_update_stats("object_ref_update_dispatch_failed")

	# Fixed-size stats readback is limited to fail-loud object-ref diagnostics.
	var stats_bytes := _rd.buffer_get_data(
		stats_buffer,
		0,
		SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_STATS_CAPACITY * SCENE_VOXEL_TILE_REF_STRIDE_BYTES
	)
	var stats_words := stats_bytes.to_int32_array()
	var transient_dirty_tile_count := _scene_voxel_tile_object_ref_update_stat(stats_words, 8)
	var dirty_worklist_read_count := mini(transient_dirty_tile_count, dirty_tile_worklist_capacity)
	# The dirty worklist + flag buffers are debug-only CPU projections (SCOPE_FRAME,
	# GC'd at the end of this pass). Skip both readbacks unless explicitly requested.
	var transient_dirty := {}
	var transient_dirty_readback_source := "disabled_debug_readback_off"
	if debug_object_ref_dirty_cpu_readback:
		var dirty_worklist_bytes := _rd.buffer_get_data(
			dirty_tile_worklist_buffer,
			0,
			dirty_worklist_read_count * SCENE_VOXEL_TILE_INDEX_STRIDE_BYTES
		)
		var dirty_flag_bytes := _rd.buffer_get_data(
			dirty_tile_flag_buffer,
			0,
			dirty_tile_flag_capacity * SCENE_VOXEL_TILE_REF_STRIDE_BYTES
		)
		transient_dirty = _decode_scene_voxel_tile_object_ref_transient_dirty_tiles(
			dirty_flag_bytes,
			dirty_worklist_bytes,
			tile_grid,
			dirty_worklist_read_count
		)
		transient_dirty_readback_source = "cpu_debug_readback"
	else:
		transient_dirty = {
			"flagged_tile_count": 0,
			"worklist_read_count": 0,
			"tile_ids": [],
			"tile_indices": [],
			"flag_bits_by_tile_id": {},
			"flags_by_tile_id": {},
		}
		dirty_worklist_read_count = 0
	var stats := {
		"ok": true,
		"reason": "ok",
		"gpu_dispatched": true,
		"stats_available": stats_words.size() >= SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_STATS_CAPACITY,
		"source": SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_NAME,
		"shader": SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_NAME,
		"dirty_delta_source": dirty_delta_source,
		"dirty_delta_count": dirty_delta_count,
		"dirty_delta_capacity": maxi(dirty_delta_capacity, dirty_delta_count),
		"dispatch_group_count": dispatch_groups.x,
		"object_ref_capacity": object_ref_capacity,
		"object_ref_tile_count": tile_count,
		"object_ref_tile_grid_size": tile_grid,
		"overflow": _scene_voxel_tile_object_ref_update_stat(stats_words, 0),
		"non_numeric": _scene_voxel_tile_object_ref_update_stat(stats_words, 1),
		"duplicate": _scene_voxel_tile_object_ref_update_stat(stats_words, 2),
		"touched": _scene_voxel_tile_object_ref_update_stat(stats_words, 3),
		"removed_slots": _scene_voxel_tile_object_ref_update_stat(stats_words, 4),
		"inserted_slots": _scene_voxel_tile_object_ref_update_stat(stats_words, 5),
		"invalid_bounds": _scene_voxel_tile_object_ref_update_stat(stats_words, 6),
		"skipped": _scene_voxel_tile_object_ref_update_stat(stats_words, 7),
		"transient_dirty_scene_voxel_tile_gpu_emitted": true,
		"transient_dirty_scene_voxel_tile_count": transient_dirty_tile_count,
		"transient_dirty_scene_voxel_tile_worklist_count": dirty_worklist_read_count,
		"transient_dirty_scene_voxel_tile_flagged_count": int(transient_dirty.get("flagged_tile_count", 0)),
		"transient_dirty_scene_voxel_tile_ids": transient_dirty.get("tile_ids", []),
		"transient_dirty_scene_voxel_tile_indices": transient_dirty.get("tile_indices", []),
		"transient_dirty_scene_voxel_tile_flags": transient_dirty.get("flags_by_tile_id", {}),
		"transient_dirty_scene_voxel_tile_flag_bits": transient_dirty.get("flag_bits_by_tile_id", {}),
		"transient_dirty_scene_voxel_tile_flag_schema": _scene_voxel_tile_object_ref_dirty_flag_schema_name(dirty_flag_schema),
		"transient_dirty_scene_voxel_tile_source": SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_NAME,
		"transient_dirty_scene_voxel_tile_readback_source": transient_dirty_readback_source,
		"transient_dirty_scene_voxel_tile_flag_capacity": dirty_tile_flag_capacity,
		"transient_dirty_scene_voxel_tile_worklist_capacity": dirty_tile_worklist_capacity,
		"transient_dirty_scene_voxel_tile_worklist_overflow_count": _scene_voxel_tile_object_ref_update_stat(stats_words, 9),
		"transient_dirty_scene_voxel_tile_cpu_metadata_bridge": "none",
		"cpu_readback_debug_only": true,
	}
	_scene_voxel_tile_gpu_buffer_hashes[SCENE_VOXEL_TILE_OBJECT_REF_BUFFER] = 0
	_scene_voxel_tile_object_ref_key_schema = SCENE_VOXEL_TILE_OBJECT_REF_SCHEMA_NUMERIC
	_scene_voxel_tile_object_ref_numeric_schema_confirmed = true
	if int(stats.get("invalid_bounds", 0)) > 0:
		stats["ok"] = false
		stats["reason"] = "invalid_bounds"
	elif int(stats.get("transient_dirty_scene_voxel_tile_worklist_overflow_count", 0)) > 0:
		stats["ok"] = false
		stats["reason"] = "dirty_worklist_overflow"
	elif int(stats.get("overflow", 0)) > 0:
		stats["ok"] = false
		stats["reason"] = "object_ref_overflow"
	_scene_voxel_tile_object_ref_last_update_stats = stats
	if transient_dirty_tile_count > 0:
		_scene_voxel_tile_dirty_epoch += 1
	gc_frame()
	return stats.duplicate(true)

## 由脏增量数组打包并派发GPU对象引用更新
func _update_gpu_autoobject_object_refs_from_dirty_deltas(deltas: Array) -> Dictionary:
	if deltas.is_empty():
		return _fail_object_ref_update_stats("empty_dirty_delta_batch")

	var dirty_delta_bytes := _pack_gpu_autoobject_dirty_delta_words(deltas)
	var dirty_delta_count := int(dirty_delta_bytes.size() / SCENE_VOXEL_TILE_OBJECT_REF_DIRTY_DELTA_STRIDE_BYTES)
	if dirty_delta_count <= 0:
		return _fail_object_ref_update_stats("empty_dirty_delta_words")

	var dirty_delta_buffer := storage_buffer_from_bytes(
		dirty_delta_bytes,
		SCOPE_FRAME,
		"scene_voxel_tile_object_ref_dirty_deltas"
	)
	if not dirty_delta_buffer.is_valid():
		gc_frame()
		return _fail_object_ref_update_stats("object_ref_update_buffer_create_failed")

	return _update_gpu_autoobject_object_refs_from_dirty_delta_buffer(
		dirty_delta_buffer,
		dirty_delta_count,
		dirty_delta_count,
		"staged_dirty_delta_buffer"
	)

## 判断场景体素瓦片GPU缓冲是否就绪
## ⚠ 必须按场名分派。V3 劈开后两块场对已不在 `_scene_voxel_tile_gpu_buffers` 里，
## 若仍拿整张 `SCENE_VOXEL_TILE_GPU_BUFFER_NAMES` 去查那张字典，场对那两项永远取到空 RID
## ⇒ 本函数恒返回 false ⇒ 报告里 `runtime_ready` / `resident` 全线变假，而**不报任何错**。
## 落地时踩过这个坑，别改回去。
func is_scene_voxel_tile_gpu_ready() -> bool:
	if _rd == null or not _scene_voxel_tile_gpu_ready:
		return false
	for buffer_name in SCENE_VOXEL_TILE_GPU_BUFFER_NAMES:
		if not get_scene_voxel_tile_gpu_buffer(buffer_name).is_valid():
			return false
	return true

## 获取指定名称的瓦片GPU缓冲RID
## ⚠ 按场名分派：两块 SceneSV 场对已归 `SceneSVFieldStore`（V3 劈开，§1.2），
## 其余 6 个瓦片 buffer 仍在本类。外部调用方**不需要**知道这条分界——名字不变、口径不变。
func get_scene_voxel_tile_gpu_buffer(buffer_name: String) -> RID:
	if SceneSVFieldStoreScript.is_field_buffer(buffer_name):
		return _field_store.rid_of(buffer_name) if _field_store != null else RID()
	return _scene_voxel_tile_gpu_buffers.get(buffer_name, RID())

## 返回场景体素瓦片GPU缓冲汇总信息
func get_scene_voxel_tile_gpu_buffer_status() -> Dictionary:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	var buffers := {}
	var runtime_ready := is_scene_voxel_tile_gpu_ready()
	var reason := _scene_voxel_tile_last_upload_error
	if reason.is_empty() and not runtime_ready:
		reason = _scene_voxel_tile_gpu_stale_reason
		if reason.is_empty():
			reason = "not_uploaded"
	var gpu_upload_status := "ready"
	if not runtime_ready:
		if reason == "no_rendering_device":
			gpu_upload_status = "skip"
		elif _scene_voxel_tile_gpu_buffers.is_empty():
			gpu_upload_status = "pending"
		else:
			gpu_upload_status = "blocked"
	var skip_reason := reason if gpu_upload_status == "skip" else ""
	var blocked_debug_reason := "" if runtime_ready else reason
	# 瓦片 6 buffer 仍在本类。
	for buffer_name in SCENE_VOXEL_TILE_GPU_BUFFER_NAMES:
		if SceneSVFieldStoreScript.is_field_buffer(buffer_name):
			continue
		var rid: RID = _scene_voxel_tile_gpu_buffers.get(buffer_name, RID())
		var byte_size := int(_scene_voxel_tile_gpu_buffer_byte_sizes.get(buffer_name, 0))
		var upload_byte_size := int(_scene_voxel_tile_gpu_buffer_upload_byte_sizes.get(buffer_name, 0))
		buffers[buffer_name] = {
			"rid_valid": rid.is_valid(),
			"record_count": int(_scene_voxel_tile_gpu_record_counts.get(buffer_name, 0)),
			"stride_bytes": int(_scene_voxel_tile_gpu_strides.get(buffer_name, 0)),
			"byte_size": byte_size,
			"logical_byte_size": byte_size,
			"upload_byte_size": upload_byte_size,
			"initialization_source": str(_scene_voxel_tile_gpu_buffer_initialization_sources.get(buffer_name, "unknown")),
			"content_hash": int(_scene_voxel_tile_gpu_buffer_hashes.get(buffer_name, 0)),
			"reused_last_upload": _scene_voxel_tile_gpu_last_reused_buffers.has(buffer_name),
		}
	# 两块场对来自它自己的所有者（V3 劈开）。`status_entries()` 产出的形状与上面逐字一致，
	# 所以报告的 `buffers` 字典外观完全不变——键序也保持「6 个瓦片在前、2 个场对在后」，
	# 与 SCENE_VOXEL_TILE_GPU_BUFFER_NAMES 的原顺序相同。
	if _field_store != null:
		buffers.merge(_field_store.status_entries(_scene_voxel_tile_gpu_last_reused_buffers), true)
	else:
		buffers.merge(SceneSVFieldStoreScript.new().status_entries(), true)
	var complexity_field_buffer: Dictionary = buffers.get(SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER, {})
	var collision_field_buffer: Dictionary = buffers.get(SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER, {})
	var resident_field_ready := (
		runtime_ready and
		bool(complexity_field_buffer.get("rid_valid", false)) and
		bool(collision_field_buffer.get("rid_valid", false))
	)
	var object_ref_last_stats := _scene_voxel_tile_object_ref_last_update_stats.duplicate(true)
	return {
		"runtime_ready": runtime_ready,
		"gpu_first": true,
		"cpu_fallback": false,
		"gpu_upload_status": gpu_upload_status,
		"skip_reason": skip_reason,
		"blocked_debug_reason": blocked_debug_reason,
		"rendering_device_available": _rd != null,
		"read_source": "gpu_storage_buffers" if runtime_ready else "none",
		"runtime_read_source": "gpu_storage_buffers" if runtime_ready else "none",
		"resident_field_read_source": "gpu_storage_buffers" if resident_field_ready else "none",
		"complexity_field_read_source": "gpu_storage_buffers" if resident_field_ready else "none",
		"collision_field_read_source": "gpu_storage_buffers" if resident_field_ready else "none",
		"staging_source": "gpu_dirty_command_buffer",
		"readback_source": "gpu_storage_buffers" if runtime_ready else "none",
		"reason": reason,
		"tile_count": _scene_voxel_tile_total_tile_count(),
		"dirty_tile_count": -1,
		"dirty_count_source": "gpu_resident_count_buffer_no_readback",
		"object_ref_capacity": _scene_voxel_tile_fixed_object_ref_slot_count,
		"object_ref_tile_count": _scene_voxel_tile_fixed_object_ref_tile_count,
		"object_ref_tile_size": scene_voxel_tile_size(),
		"object_ref_tile_grid_size": _scene_voxel_tile_grid_size(),
		"refs_per_tile": SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT,
		"object_ref_stride_bytes": SCENE_VOXEL_TILE_REF_STRIDE_BYTES,
		"object_ref_key_schema": _scene_voxel_tile_object_ref_key_schema,
		"object_ref_numeric_schema_confirmed": _scene_voxel_tile_object_ref_numeric_schema_confirmed,
		"gpu_autoobject_ref_key_schema": _scene_voxel_tile_object_ref_key_schema,
		"gpu_autoobject_ref_key_schema_numeric_confirmed": _scene_voxel_tile_object_ref_numeric_schema_confirmed,
		"gpu_autoobject_ref_key_schema_note": "Use u32 ref_key entries; 0 is empty, numeric GPU AutoObject object_id + 1 is the pending runtime key, and legacy CPU string hashes remain debug-only.",
		"object_ref_rebuild_required": _scene_voxel_tile_object_ref_rebuild_required,
		"object_ref_overflow_count": _scene_voxel_tile_object_ref_overflow_count,
		"object_ref_update_stats_available": bool(object_ref_last_stats.get("stats_available", false)),
		"object_ref_update_source": str(object_ref_last_stats.get("source", "none")),
		"object_ref_update_reason": str(object_ref_last_stats.get("reason", "not_dispatched")),
		"object_ref_update_gpu_dispatched": bool(object_ref_last_stats.get("gpu_dispatched", false)),
		"object_ref_non_numeric_count": int(object_ref_last_stats.get("non_numeric", 0)),
		"object_ref_duplicate_count": int(object_ref_last_stats.get("duplicate", 0)),
		"object_ref_touched_count": int(object_ref_last_stats.get("touched", 0)),
		"object_ref_removed_slot_count": int(object_ref_last_stats.get("removed_slots", 0)),
		"object_ref_inserted_slot_count": int(object_ref_last_stats.get("inserted_slots", 0)),
		"object_ref_invalid_bounds_count": int(object_ref_last_stats.get("invalid_bounds", 0)),
		"object_ref_skipped_count": int(object_ref_last_stats.get("skipped", 0)),
		"resident_field_voxel_count": int(complexity_field_buffer.get("record_count", 0)),
		"complexity_field_voxel_count": int(complexity_field_buffer.get("record_count", 0)),
		"collision_field_voxel_count": int(collision_field_buffer.get("record_count", 0)),
		"complexity_field_format": SCENE_VOXEL_TILE_COMPLEXITY_FIELD_FORMAT,
		"collision_field_format": SCENE_VOXEL_TILE_COLLISION_FIELD_FORMAT,
		"complexity_field_stride_bytes": SCENE_VOXEL_TILE_COMPLEXITY_FIELD_STRIDE_BYTES,
		"collision_field_stride_bytes": SCENE_VOXEL_TILE_COLLISION_FIELD_STRIDE_BYTES,
		"collision_field_upload_stride_bytes": SCENE_VOXEL_TILE_COLLISION_FIELD_UPLOAD_STRIDE_BYTES,
		"dirty_epoch": _scene_voxel_tile_dirty_epoch,
		"gpu_revision": _scene_voxel_tile_gpu_revision,
		"last_upload_tick": _scene_voxel_tile_gpu_last_upload_tick,
		"last_reused_buffers": _scene_voxel_tile_gpu_last_reused_buffers.duplicate(),
		"resident_field_buffers_reused": (
			_scene_voxel_tile_gpu_last_reused_buffers.has(SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER) and
			_scene_voxel_tile_gpu_last_reused_buffers.has(SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER)
		),
		"last_upload_mode": _scene_voxel_tile_last_upload_mode,
		"summary_dirty_range_update_source": _scene_voxel_tile_last_summary_dirty_range_update_source,
		"last_upload_resident_voxel_count": _scene_voxel_tile_last_upload_resident_voxel_count,
		"last_upload_range_count": _scene_voxel_tile_last_upload_range_count,
		"buffers": buffers,
	}

## 回读瓦片GPU缓冲的调试快照
func readback_scene_voxel_tile_debug_snapshot() -> Dictionary:
	return SceneVoxelDebugScript.readback_tile_snapshot(self)

## 释放瓦片GPU缓冲并可保留指定缓冲
func _release_scene_voxel_tile_gpu_buffers(preserve_buffer_names: Array = []) -> void:
	var preserve := {}
	for raw_name in preserve_buffer_names:
		preserve[str(raw_name)] = true
	for buffer_name in _scene_voxel_tile_gpu_buffers.keys():
		if preserve.has(str(buffer_name)):
			continue
		var rid_value = _scene_voxel_tile_gpu_buffers[buffer_name]
		if rid_value is RID:
			var rid: RID = rid_value
			if rid.is_valid():
				release_rid(rid, false)
		_scene_voxel_tile_gpu_buffers.erase(buffer_name)
		_scene_voxel_tile_gpu_buffer_byte_sizes.erase(buffer_name)
		_scene_voxel_tile_gpu_buffer_upload_byte_sizes.erase(buffer_name)
		_scene_voxel_tile_gpu_buffer_initialization_sources.erase(buffer_name)
		_scene_voxel_tile_gpu_record_counts.erase(buffer_name)
		_scene_voxel_tile_gpu_strides.erase(buffer_name)
		_scene_voxel_tile_gpu_buffer_hashes.erase(buffer_name)
	if not preserve.has(SCENE_VOXEL_TILE_OBJECT_REF_BUFFER):
		_scene_voxel_tile_object_ref_key_schema = SCENE_VOXEL_TILE_OBJECT_REF_SCHEMA_LEGACY_HASH
		_scene_voxel_tile_object_ref_numeric_schema_confirmed = false
	if preserve.is_empty():
		_scene_voxel_tile_gpu_last_reused_buffers.clear()
		_scene_voxel_tile_last_summary_dirty_range_update_source = "none"
	_scene_voxel_tile_gpu_ready = false
	if preserve.is_empty():
		_scene_voxel_tile_gpu_last_upload_tick = -1
	_scene_voxel_tile_gpu_stale_reason = "buffers_released" if preserve.is_empty() else "buffers_released_partial"

## 回读指定瓦片GPU缓冲的字节
## 公开回读口。⚠ 常驻场是多兆字节的同步回读，只该出现在**显式**路径上
## （SV 显示重建、调试快照），绝不能进每帧循环。
## SV 显示必须走它的理由：SPA 的 GPU 栈在本地 RenderingDevice 上，而显示 writer 绑主设备，
## RID 不能跨设备。
func read_scene_voxel_tile_buffer_bytes(buffer_name: String) -> PackedByteArray:
	return _read_scene_voxel_tile_buffer_bytes(buffer_name)


func _read_scene_voxel_tile_buffer_bytes(buffer_name: String) -> PackedByteArray:
	# 场对走它自己的所有者（V3 劈开）。SceneVoxelDebug 拿这两块做诊断回读，口径不变。
	if SceneSVFieldStoreScript.is_field_buffer(buffer_name):
		return _field_store.read_field_bytes(buffer_name) if _field_store != null else PackedByteArray()
	var rid: RID = _scene_voxel_tile_gpu_buffers.get(buffer_name, RID())
	var byte_size := int(_scene_voxel_tile_gpu_buffer_byte_sizes.get(buffer_name, 0))
	return read_buffer_bytes(rid, 0, byte_size)

## 计算瓦片网格的总瓦片数
func _scene_voxel_tile_total_tile_count(tile_grid: Vector3i = Vector3i.ZERO) -> int:
	var grid := tile_grid if tile_grid.x > 0 and tile_grid.y > 0 and tile_grid.z > 0 else _scene_voxel_tile_grid_size()
	return SceneVoxelTileCodecScript.tile_count(grid)

## 从记录字典中提取数值对象ID
func _scene_voxel_tile_numeric_object_id(record: Dictionary) -> int:
	for key in ["object_id", "auto_object_id", "auto_id", "id", "record_id"]:
		if record.has(key):
			var numeric_id := VariantUtils.int_id_from_value(record.get(key))
			if numeric_id >= 0:
				return numeric_id
	return -1

## GPU 三段归约（init→reduce→compact）出紧凑 tile 摘要。复杂度场只接受契约预绑定的
## 常驻 field buffer（committer 恒传，常驻场无 CPU 重灌来源）；碰撞场同样只接受预绑定
## buffer —— 旧的"无预绑定就按 CPU field 打包上传"兜底路径已删除，缺失即硬失败。
func _reduce_scene_voxel_tile_summaries_gpu(
	collision_field: PackedFloat32Array,
	xz_res: int,
	total_slices: int,
	tile_size: Vector3i,
	buffer_contract: Dictionary = {}
) -> Dictionary:
	var voxel_count := xz_res * xz_res * total_slices
	if voxel_count <= 0:
		return {}

	var contract_voxel_count := int(buffer_contract.get("voxel_count", 0))
	var prebound_complexity_buffer: RID = buffer_contract.get("complexity_field_buffer", RID())
	var prebound_collision_buffer: RID = buffer_contract.get("collision_field_buffer", RID())
	if not prebound_complexity_buffer.is_valid() or contract_voxel_count != voxel_count:
		push_error("[SceneVoxelTileStore] _reduce_scene_voxel_tile_summaries_gpu: buffer_contract 不合法 —— complexity_field_buffer 有效=%s，contract voxel_count=%d 期望 %d（xz_res=%d total_slices=%d）" % [str(prebound_complexity_buffer.is_valid()), contract_voxel_count, voxel_count, xz_res, total_slices])
		assert(false, "SceneVoxelTileStore: summary reduce buffer contract invalid")
		return {}
	# 碰撞摘要缓冲必须由 committer 预绑定：以前允许"无预绑定 → 按 CPU collision_field 打包上传"
	# 的兜底路径，CPU 场为空/长度不符时整层碰撞会被静默算成 0，且 summary 仍报告成功。
	if not prebound_collision_buffer.is_valid():
		push_error("[SceneVoxelTileStore] _reduce_scene_voxel_tile_summaries_gpu: buffer_contract 缺少有效的 collision_field_buffer（voxel_count=%d，CPU collision_field 长度=%d）—— 拒绝回退 CPU 打包兜底路径" % [voxel_count, collision_field.size()])
		assert(false, "SceneVoxelTileStore: summary reduce collision buffer not prebound")
		return {}
	if not _gpu_ready or _rd == null:
		return {}
	if not ComputeKernel.ready(_kernel_reduce_summaries):
		return {}
	if not ComputeKernel.ready(_kernel_init_summaries):
		return {}
	if not ComputeKernel.ready(_kernel_compact_summaries):
		return {}

	var safe_tile_size := Vector3i(maxi(tile_size.x, 1), maxi(tile_size.y, 1), maxi(tile_size.z, 1))
	var summary_grid_size := Vector3i(xz_res, total_slices, xz_res)
	var tile_grid := SceneVoxelTileCodecScript.tile_grid_size(summary_grid_size, safe_tile_size)
	var tile_count := tile_grid.x * tile_grid.y * tile_grid.z
	if tile_count <= 0:
		return {}

	var complexity_buffer := prebound_complexity_buffer
	var collision_buffer := prebound_collision_buffer
	var preserved_buffers: Array = [complexity_buffer, collision_buffer]

	if not ensure_scene_voxel_tile_buffers_uploaded(false):
		_gc_frame_preserving_rids(preserved_buffers)
		return {}
	var summary_buffer := storage_buffer_zero(tile_count * SCENE_VOXEL_TILE_REDUCE_SUMMARY_UINT_STRIDE * 4, SCOPE_FRAME, "scene_voxel_tile_summary_counts")
	var compact_buffer: RID = _scene_voxel_tile_gpu_buffers.get(SCENE_VOXEL_TILE_SUMMARY_BUFFER, RID())
	var compact_counter_buffer := storage_buffer_zero(4, SCOPE_FRAME, "scene_voxel_tile_summary_compact_counter")
	preserved_buffers.append(compact_buffer)
	if not complexity_buffer.is_valid() or not collision_buffer.is_valid() or not summary_buffer.is_valid() or not compact_buffer.is_valid() or not compact_counter_buffer.is_valid():
		_gc_frame_preserving_rids(preserved_buffers)
		return {}

	var init_set := _kernel_init_summaries.bind_storage([summary_buffer])
	if not init_set.is_valid():
		_gc_frame_preserving_rids(preserved_buffers)
		return {}

	var set0 := _kernel_reduce_summaries.bind_storage([complexity_buffer, collision_buffer, summary_buffer])
	if not set0.is_valid():
		_gc_frame_preserving_rids(preserved_buffers)
		return {}

	var compact_set := _kernel_compact_summaries.bind_storage([summary_buffer, compact_buffer, compact_counter_buffer])
	if not compact_set.is_valid():
		_gc_frame_preserving_rids(preserved_buffers)
		return {}

	var tile_groups := _kernel_init_summaries.groups_1d(tile_count, 64)
	var init_pass := _kernel_init_summaries.make_pass_sets([init_set], {
		tile_count = tile_count,
		summary_uint_stride = SCENE_VOXEL_TILE_REDUCE_SUMMARY_UINT_STRIDE,
		init_value = 0x7FFFFFFF,
	}, tile_groups)

	# (xz_res, total_slices) → 规范网格：XZ 方形是**调用方的** CPU 假设，在这里显式写出来，
	# 而不是编进着色器的寻址式里。
	var reduce_pass := _kernel_reduce_summaries.make_pass_sets([set0], {
		grid_x = xz_res,
		grid_y = total_slices,
		grid_z = xz_res,
		tile_count = tile_count,
		tile_size_x = safe_tile_size.x,
		tile_size_y = safe_tile_size.y,
		tile_size_z = safe_tile_size.z,
		summary_uint_stride = SCENE_VOXEL_TILE_REDUCE_SUMMARY_UINT_STRIDE,
		tile_grid_x = tile_grid.x,
		tile_grid_y = tile_grid.y,
		tile_grid_z = tile_grid.z,
		occupied_epsilon = VoxelGeneral.VOXEL_OCCUPIED_EPSILON,
		quant_scale = SCENE_VOXEL_TILE_REDUCE_QUANT_SCALE,
	}, _kernel_reduce_summaries.groups_1d(voxel_count, 64))

	# _pad0 在此 shader 里被当作有效标志位读取，故显式置 1（不是补零填充）。
	var compact_pass := _kernel_compact_summaries.make_pass_sets([compact_set], {
		tile_count = tile_count,
		summary_uint_stride = SCENE_VOXEL_TILE_REDUCE_SUMMARY_UINT_STRIDE,
		compact_summary_uint_stride = SCENE_VOXEL_TILE_COMPACT_SUMMARY_UINT_STRIDE,
		_pad0 = 1,
	}, tile_groups)

	var dispatched := ComputePassChain.run(self, [init_pass, reduce_pass, compact_pass])
	_gc_frame_preserving_rids(preserved_buffers)
	if not dispatched:
		return {}

	# 摘要缓冲的内容变了 ⇒ 推 GPU 修订号。
	#
	# ⚠ 这一步不能省。`SceneSVVolume.revision()` 与 `SVTileVolume.revision()` 都拿
	# `get_svtile_gpu_status().gpu_revision` 当「内容变没变」的门，而 `rebuild_display()`
	# 在 `_built_revision == current` 处直接 return。只刷摘要不推它 = 摘要是新的、显示照旧
	# 画旧的，**且零提示**。
	# ⚠ 放这里而不是放调用方：本函数是 summary 缓冲在本类里的唯一写入点，覆盖全部调用方
	#（bootstrap 的 commit_scene_voxels、以及 placement 之后的显式刷新）。
	_scene_voxel_tile_gpu_revision += 1

	return {
		"tile_grid": tile_grid,
		"tile_size": safe_tile_size,
		"tile_count": tile_count,
		"gpu_dispatched": true,
		"cpu_fallback": false,
		"gpu_revision": _scene_voxel_tile_gpu_revision,
		"summary_source": "resident_scene_voxel_tile_summary_buffer",
		"summary_compaction_source": "gpu_fixed_index_finalize_no_readback",
	}

## 标记体素包围盒范围内所有瓦片为脏；不构造 CPU tile 列表。
func mark_scene_voxel_tile_bounds_dirty(
	voxel_min: Vector3i,
	voxel_max: Vector3i,
	dirty_flags: Dictionary = {},
	source_record: Dictionary = {}
) -> void:
	mark_scene_voxel_tile_bounds_dirty_batch([{
		"voxel_min": voxel_min,
		"voxel_max": voxel_max,
		"dirty_flags": dirty_flags,
		"source_record": source_record,
	}])


## 批量标记多段体素包围盒为脏：全部 command 打进单个 delta buffer、一次 GPU 派发，
## 消除逐 command 的 buffer 创建 + submit/sync + stats 回读往返。dirty flag 在 GPU 端
## 为 OR 语义，批内顺序无关。entry 键：voxel_min/voxel_max(Vector3i)、可选 dirty_flags、
## 可选 source_record；缺 voxel_max 时按单体素（min+1）处理。
func mark_scene_voxel_tile_bounds_dirty_batch(entries: Array) -> void:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	var commands: Array[Dictionary] = []
	for entry_index in range(entries.size()):
		var raw_entry = entries[entry_index]
		if not raw_entry is Dictionary:
			# 以前静默跳过：该段包围盒的脏标记直接丢失，下游 anchor collect 读到过期 tile。
			push_error("[SceneVoxelTileStore] mark_scene_voxel_tile_bounds_dirty_batch: entries[%d] 不是 Dictionary（typeof=%d 值=%s，批大小=%d）" % [entry_index, typeof(raw_entry), str(raw_entry), entries.size()])
			assert(false, "SceneVoxelTileStore: non-Dictionary entry in bounds dirty batch")
			return
		var entry := raw_entry as Dictionary
		var voxel_min_value = entry.get("voxel_min", null)
		if not voxel_min_value is Vector3i:
			push_error("[SceneVoxelTileStore] mark_scene_voxel_tile_bounds_dirty_batch: entries[%d] 的 voxel_min 不是 Vector3i（typeof=%d 值=%s）—— 以前静默跳过该条，脏范围会缺一块" % [entry_index, typeof(voxel_min_value), str(voxel_min_value)])
			assert(false, "SceneVoxelTileStore: bounds dirty entry missing Vector3i voxel_min")
			return
		var voxel_min: Vector3i = voxel_min_value
		var voxel_max_value = entry.get("voxel_max", null)
		# voxel_max 缺省 = 单体素（min+1），这是文档化的 API 默认值，不是兜底；
		# 但显式给了一个非 Vector3i 的值属于调用方 schema 错误，必须暴露。
		if voxel_max_value != null and not voxel_max_value is Vector3i:
			push_error("[SceneVoxelTileStore] mark_scene_voxel_tile_bounds_dirty_batch: entries[%d] 的 voxel_max 不是 Vector3i（typeof=%d 值=%s，voxel_min=%s）—— 以前静默降级为单体素范围" % [entry_index, typeof(voxel_max_value), str(voxel_max_value), str(voxel_min)])
			assert(false, "SceneVoxelTileStore: bounds dirty entry has non-Vector3i voxel_max")
			return
		var voxel_max: Vector3i = voxel_max_value if voxel_max_value is Vector3i else voxel_min + Vector3i.ONE
		var flags := SceneVoxelTileCodecScript.flags_from_value(entry.get("dirty_flags", {}), "")
		if flags.is_empty():
			flags["scene"] = true
		var source_value = entry.get("source_record", {})
		var source_record: Dictionary = source_value if source_value is Dictionary else {}
		commands.append({
			"voxel_min": voxel_min,
			"voxel_max": voxel_max,
			"dirty_flag_bits": SceneVoxelTileCodecScript.flags_to_bits(flags),
			"source": str(source_record.get("source_id", source_record.get("id", "bounds_dirty"))),
		})
	if commands.is_empty():
		return
	if not is_scene_voxel_tile_gpu_ready():
		_pending_scene_voxel_tile_dirty_commands.append_array(commands)
	elif not _dispatch_scene_voxel_tile_bounds_dirty_commands(commands):
		push_error("[SceneVoxelTileStore] bounds dirty batch dispatch reported failure (%d commands)" % commands.size())
	_committer._sv_dirty = true


## 显式 GPU full-dirty command；禁止 CPU 三重循环。
func mark_all_scene_voxel_tiles_dirty(dirty_flags: Dictionary = {}, source_record: Dictionary = {}) -> Dictionary:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	var flags := SceneVoxelTileCodecScript.flags_from_value(dirty_flags, "")
	if flags.is_empty():
		flags["scene"] = true
		flags["collision"] = true
	var flag_bits := SceneVoxelTileCodecScript.flags_to_bits(flags)
	var tile_grid := _scene_voxel_tile_grid_size()
	var tile_count := _scene_voxel_tile_total_tile_count(tile_grid)
	var dispatched := false
	if is_scene_voxel_tile_gpu_ready():
		dispatched = _dispatch_scene_voxel_tile_dirty_control(DIRTY_CONTROL_FULL, flag_bits)
	else:
		_pending_scene_voxel_tile_full_dirty_flags |= flag_bits
	_committer._sv_dirty = true
	return {
		"ok": dispatched or _pending_scene_voxel_tile_full_dirty_flags != 0,
		"source": str(source_record.get("source_id", source_record.get("id", "full_dirty"))),
		"tile_grid_size": tile_grid,
		"tile_count": tile_count,
		"dirty_scene_voxel_tile_count": tile_count,
		"gpu_full_dirty": true,
	}


## Anchor collect 成功后的 GPU finalize/clear；不会回读或遍历 tile。
func finalize_consumed_dirty_tiles() -> bool:
	if not is_scene_voxel_tile_gpu_ready():
		return false
	return _dispatch_scene_voxel_tile_dirty_control(DIRTY_CONTROL_CLEAR, 0)


## 借出 Anchor collect 唯一合法的 dirty input。
func get_dirty_worklist_handoff() -> Dictionary:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	if not ensure_scene_voxel_tile_buffers_uploaded(false):
		return {"ok": false, "reason": _scene_voxel_tile_last_upload_error}
	var tile_count := _scene_voxel_tile_total_tile_count()
	var flags: RID = _scene_voxel_tile_gpu_buffers.get(SCENE_VOXEL_TILE_DIRTY_FLAG_BUFFER, RID())
	var worklist: RID = _scene_voxel_tile_gpu_buffers.get(SCENE_VOXEL_TILE_DIRTY_WORKLIST_BUFFER, RID())
	var count: RID = _scene_voxel_tile_gpu_buffers.get(SCENE_VOXEL_TILE_DIRTY_COUNT_BUFFER, RID())
	var ready := flags.is_valid() and worklist.is_valid() and count.is_valid()
	return {
		"ok": ready,
		"reason": "ok" if ready else "resident_dirty_buffers_unavailable",
		"dirty_tile_flag_buffer": flags,
		"dirty_tile_worklist_buffer": worklist,
		"dirty_tile_count_buffer": count,
		"dirty_tile_capacity": tile_count,
		"dirty_epoch": _scene_voxel_tile_dirty_epoch,
		"revision": _scene_voxel_tile_gpu_revision,
		"rendering_device": _rd,
		"owner": "ScenePlacementActor/SceneVoxelTileStore",
		"cpu_fallback": false,
	}


func _dispatch_scene_voxel_tile_dirty_control(operation: int, dirty_flags: int) -> bool:
	if _rd == null or not ComputeKernel.ready(_kernel_initialize_empty_tile_buffers):
		return false
	var required := [
		SCENE_VOXEL_TILE_RECORD_BUFFER,
		SCENE_VOXEL_TILE_SUMMARY_BUFFER,
		SCENE_VOXEL_TILE_OBJECT_REF_BUFFER,
		SCENE_VOXEL_TILE_DIRTY_FLAG_BUFFER,
		SCENE_VOXEL_TILE_DIRTY_WORKLIST_BUFFER,
		SCENE_VOXEL_TILE_DIRTY_COUNT_BUFFER,
	]
	var buffers: Array[RID] = []
	for buffer_name in required:
		var rid: RID = _scene_voxel_tile_gpu_buffers.get(buffer_name, RID())
		if not rid.is_valid():
			return false
		buffers.append(rid)
	var tile_size := scene_voxel_tile_size()
	var tile_grid := _scene_voxel_tile_grid_size(tile_size)
	var tile_count := _scene_voxel_tile_total_tile_count(tile_grid)
	var dispatched := _dispatch_initialize_empty_tile_buffers_kernel(
		buffers, tile_size, tile_grid, tile_count, operation, dirty_flags)
	gc_scope(SCOPE_PASS)
	if dispatched and operation == DIRTY_CONTROL_FULL:
		_scene_voxel_tile_dirty_epoch += 1
	return dispatched


func _dispatch_scene_voxel_tile_bounds_dirty_commands(commands: Array) -> bool:
	if commands.is_empty():
		return true
	var stride := SCENE_VOXEL_TILE_OBJECT_REF_DIRTY_DELTA_STRIDE_BYTES
	var bytes := PackedByteArray()
	bytes.resize(stride * commands.size())
	var base := 0
	for raw_command in commands:
		var command := raw_command as Dictionary
		# 这三个键由 mark_scene_voxel_tile_bounds_dirty_batch 恒写入；缺失说明 command
		# 结构被破坏，以前的 get(默认值) 会把它当成"原点单体素 + scene 脏"照常派发。
		if command == null or not command.has("voxel_min") or not command.has("voxel_max") \
				or not command.has("dirty_flag_bits"):
			push_error("[SceneVoxelTileStore] _dispatch_scene_voxel_tile_bounds_dirty_commands: dirty command 结构不完整（需要 voxel_min/voxel_max/dirty_flag_bits，实际=%s，批大小=%d）" % [str(raw_command), commands.size()])
			assert(false, "SceneVoxelTileStore: malformed bounds dirty command")
			return false
		var voxel_min: Vector3i = command["voxel_min"]
		var voxel_max: Vector3i = command["voxel_max"]
		bytes.encode_s32(base, -1)
		bytes.encode_s32(base + 4 * 4, voxel_min.x)
		bytes.encode_s32(base + 5 * 4, voxel_min.y)
		bytes.encode_s32(base + 6 * 4, voxel_min.z)
		bytes.encode_s32(base + 7 * 4, 1)
		bytes.encode_s32(base + 8 * 4, voxel_max.x)
		bytes.encode_s32(base + 9 * 4, voxel_max.y)
		bytes.encode_s32(base + 10 * 4, voxel_max.z)
		bytes.encode_s32(base + 11 * 4, 0)
		bytes.encode_s32(base + 12 * 4, voxel_min.x)
		bytes.encode_s32(base + 13 * 4, voxel_min.y)
		bytes.encode_s32(base + 14 * 4, voxel_min.z)
		bytes.encode_s32(base + 15 * 4, int(command["dirty_flag_bits"]))
		bytes.encode_s32(base + 16 * 4, voxel_max.x)
		bytes.encode_s32(base + 17 * 4, voxel_max.y)
		bytes.encode_s32(base + 18 * 4, voxel_max.z)
		base += stride
	var command_buffer := storage_buffer_from_bytes(bytes, SCOPE_FRAME, "scene_voxel_tile_bounds_dirty_command")
	if not command_buffer.is_valid():
		return false
	var result := _update_gpu_autoobject_object_refs_from_dirty_delta_buffer(
		command_buffer,
		commands.size(),
		commands.size(),
		"scene_voxel_tile_dirty_command"
	)
	gc_frame()
	return bool(result.get("ok", false))


func _flush_pending_scene_voxel_tile_dirty_commands() -> void:
	var commands := _pending_scene_voxel_tile_dirty_commands.duplicate(true)
	_pending_scene_voxel_tile_dirty_commands.clear()
	if commands.is_empty():
		return
	if not _dispatch_scene_voxel_tile_bounds_dirty_commands(commands):
		push_error("[SceneVoxelTileStore] queued dirty command batch dispatch failed (%d commands)" % commands.size())

## 返回GPU自动对象引用范围策略诊断信息
func get_gpu_autoobject_object_ref_range_policy_diagnostics(refs_per_tile: int = SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT) -> Dictionary:
	var safe_refs_per_tile := maxi(refs_per_tile, 1)
	var tile_count := maxi(_scene_voxel_tile_fixed_object_ref_tile_count, _scene_voxel_tile_total_tile_count())
	var shader_ready := ComputeKernel.ready(_kernel_object_ref_update)
	var last_stats := _scene_voxel_tile_object_ref_last_update_stats.duplicate(true)
	var last_dispatched := bool(last_stats.get("gpu_dispatched", false))

	return {
		"object_ref_range_policy": "fixed_per_tile_object_ref_update_pass" if shader_ready else "fixed_per_tile_pending_shader",
		"object_ref_range_owner": "SceneVoxelCommitter",
		"object_ref_range_shader": SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_NAME if shader_ready else "none",
		"object_ref_range_shader_path": SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_PATH if shader_ready else "none",
		"object_ref_range_shader_ready": shader_ready,
		"object_ref_range_stride_bytes": SCENE_VOXEL_TILE_REF_STRIDE_BYTES,
		"refs_per_tile": safe_refs_per_tile,
		"object_ref_capacity": tile_count * safe_refs_per_tile,
		"object_ref_tile_count": tile_count,
		"object_ref_tile_size": scene_voxel_tile_size(),
		"object_ref_tile_grid_size": _scene_voxel_tile_grid_size(),
		"object_ref_rebuild_required": _scene_voxel_tile_object_ref_rebuild_required,
		"object_ref_update_stats_available": bool(last_stats.get("stats_available", false)),
		"object_ref_update_source": str(last_stats.get("source", "none")),
		"object_ref_update_reason": str(last_stats.get("reason", "not_dispatched" if shader_ready else "resident_object_ref_update_pass_not_enabled")),
		"object_ref_update_gpu_dispatched": last_dispatched,
		"object_ref_update_dispatch_count": int(last_stats.get("dispatch_group_count", 0)) if last_dispatched else 0,
		"object_ref_overflow_count": _scene_voxel_tile_object_ref_overflow_count,
		"object_ref_non_numeric_count": int(last_stats.get("non_numeric", 0)),
		"object_ref_duplicate_count": int(last_stats.get("duplicate", 0)),
		"object_ref_touched_count": int(last_stats.get("touched", 0)),
		"object_ref_removed_slot_count": int(last_stats.get("removed_slots", 0)),
		"object_ref_inserted_slot_count": int(last_stats.get("inserted_slots", 0)),
		"object_ref_invalid_bounds_count": int(last_stats.get("invalid_bounds", 0)),
		"object_ref_skipped_count": int(last_stats.get("skipped", 0)),
		"gpu_autoobject_ref_key_schema": "u32_numeric_ref_key_v1",
		"gpu_autoobject_ref_key_schema_note": "Use u32 ref_key entries; 0 is empty, numeric GPU AutoObject object_id + 1 is the pending runtime key, and legacy CPU string hashes remain debug-only.",
	}

## 构造对象引用更新通道的初始结果字典：默认未派发态 + range 策略诊断合并 +
## shader 就绪实况覆盖。两条 try_apply 通道共用的公共前奏。
func _new_object_ref_update_pass_result(api: String, dirty_delta_count: int) -> Dictionary:
	var result := {
		"ok": false,
		"reason": "not_dispatched",
		"gpu_first": true,
		"cpu_fallback": false,
		"dirty_delta_bridge_mode": "explicit_scene_voxel_tile_object_ref_update_pass",
		"dirty_delta_apply_api": api,
		"dirty_delta_count": maxi(dirty_delta_count, 0),
		"resident_gpu_dirty_delta_update_pass": false,
		"resident_gpu_dirty_delta_update_pass_owner": "none",
		"resident_gpu_dirty_delta_update_pass_shader": "none",
		"resident_gpu_dirty_delta_update_pass_dispatch_count": 0,
		"object_ref_update_result": {},
	}
	result.merge(get_gpu_autoobject_object_ref_range_policy_diagnostics(), true)
	result["object_ref_range_policy"] = "fixed_per_tile_object_ref_update_pass"
	result["object_ref_range_shader"] = SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_NAME
	result["object_ref_range_shader_path"] = SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_PATH
	result["object_ref_range_shader_ready"] = ComputeKernel.ready(_kernel_object_ref_update)
	return result

## 确保 tile 缓冲已上传并把上传状态并入结果；失败时写入原因并返回 false（两条通道共用）
func _ensure_uploaded_for_object_ref_update(result: Dictionary) -> bool:
	if not ensure_scene_voxel_tile_buffers_uploaded(false):
		var skipped_summary := get_scene_voxel_tile_gpu_buffer_status()
		var upload_reason := str(skipped_summary.get("reason", "scene_voxel_tile_buffer_upload_failed"))
		if upload_reason.is_empty():
			upload_reason = "scene_voxel_tile_buffer_upload_failed"
		result["reason"] = upload_reason
		result["object_ref_update_reason"] = upload_reason
		result["scene_voxel_tile_gpu_ready"] = false
		result["scene_voxel_tile_gpu_upload_status"] = str(skipped_summary.get("gpu_upload_status", "blocked"))
		result["scene_voxel_tile_gpu_skip_reason"] = str(skipped_summary.get("skip_reason", ""))
		return false
	var uploaded_summary := get_scene_voxel_tile_gpu_buffer_status()
	result["scene_voxel_tile_gpu_ready"] = bool(uploaded_summary.get("runtime_ready", false))
	result["scene_voxel_tile_gpu_upload_status"] = str(uploaded_summary.get("gpu_upload_status", "ready"))
	result["object_ref_capacity"] = int(uploaded_summary.get("object_ref_capacity", result.get("object_ref_capacity", 0)))
	result["object_ref_tile_count"] = int(uploaded_summary.get("object_ref_tile_count", result.get("object_ref_tile_count", 0)))
	result["refs_per_tile"] = int(uploaded_summary.get("refs_per_tile", result.get("refs_per_tile", SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT)))
	return true

## 尝试基于脏增量数组派发GPU对象引用更新通道
func try_apply_gpu_autoobject_object_ref_update_pass(deltas: Array) -> Dictionary:
	var result := _new_object_ref_update_pass_result("try_apply_gpu_autoobject_object_ref_update_pass", deltas.size())
	if deltas.is_empty():
		result["reason"] = "empty_dirty_delta_batch"
		result["object_ref_update_reason"] = "empty_dirty_delta_batch"
		return result
	if not _ensure_uploaded_for_object_ref_update(result):
		return result
	return _assemble_object_ref_update_result(_update_gpu_autoobject_object_refs_from_dirty_deltas(deltas), result)

## 将对象引用更新统计合并进结果字典（含溢出处理），两条通道共用
func _assemble_object_ref_update_result(update_stats: Dictionary, result: Dictionary) -> Dictionary:
	var dispatched := bool(update_stats.get("gpu_dispatched", false))
	var dispatch_count := int(update_stats.get("dispatch_group_count", 0)) if dispatched else 0
	var ok := bool(update_stats.get("ok", false))
	var reason := str(update_stats.get("reason", "object_ref_update_failed"))

	result["ok"] = ok
	result["reason"] = reason
	result["object_ref_update_result"] = update_stats
	result["object_ref_update_stats_available"] = bool(update_stats.get("stats_available", false))
	result["object_ref_update_source"] = str(update_stats.get("source", "none"))
	result["object_ref_update_shader"] = str(update_stats.get("shader", SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_NAME))
	result["object_ref_update_reason"] = reason
	result["object_ref_update_gpu_dispatched"] = dispatched
	result["object_ref_update_dispatch_count"] = dispatch_count
	result["object_ref_update_dispatch_group_count"] = int(update_stats.get("dispatch_group_count", 0)) if dispatched else 0
	result["resident_gpu_dirty_delta_update_pass"] = ok and dispatched
	result["resident_gpu_dirty_delta_update_pass_owner"] = "ScenePlacementActor/SceneVoxelTileStore" if ok and dispatched else "none"
	result["resident_gpu_dirty_delta_update_pass_shader"] = SCENE_VOXEL_TILE_OBJECT_REF_UPDATE_SHADER_NAME if ok and dispatched else "none"
	result["resident_gpu_dirty_delta_update_pass_dispatch_count"] = dispatch_count
	result["object_ref_capacity"] = int(update_stats.get("object_ref_capacity", result.get("object_ref_capacity", 0)))
	result["object_ref_tile_count"] = int(update_stats.get("object_ref_tile_count", result.get("object_ref_tile_count", 0)))
	result["object_ref_tile_grid_size"] = update_stats.get("object_ref_tile_grid_size", result.get("object_ref_tile_grid_size", Vector3i.ZERO))
	result["object_ref_overflow_count"] = int(update_stats.get("overflow", 0))
	result["object_ref_non_numeric_count"] = int(update_stats.get("non_numeric", 0))
	result["object_ref_duplicate_count"] = int(update_stats.get("duplicate", 0))
	result["object_ref_touched_count"] = int(update_stats.get("touched", 0))
	result["object_ref_removed_slot_count"] = int(update_stats.get("removed_slots", 0))
	result["object_ref_inserted_slot_count"] = int(update_stats.get("inserted_slots", 0))
	result["object_ref_invalid_bounds_count"] = int(update_stats.get("invalid_bounds", 0))
	result["object_ref_skipped_count"] = int(update_stats.get("skipped", 0))
	_merge_scene_voxel_tile_object_ref_transient_dirty_result(result, update_stats)

	if int(result.get("object_ref_overflow_count", 0)) > 0:
		_scene_voxel_tile_object_ref_rebuild_required = true
		_scene_voxel_tile_object_ref_overflow_count += int(result.get("object_ref_overflow_count", 0))
		result["object_ref_rebuild_required"] = true

	return result

## 基于借用脏增量缓冲区派发GPU对象引用更新通道
func try_apply_gpu_autoobject_object_ref_update_pass_from_buffer(
	dirty_delta_buffer: RID,
	dirty_delta_count: int,
	dirty_delta_capacity: int = -1,
	dirty_delta_source: String = "borrowed_dirty_delta_buffer"
) -> Dictionary:
	var result := _new_object_ref_update_pass_result("try_apply_gpu_autoobject_object_ref_update_pass_from_buffer", dirty_delta_count)
	if dirty_delta_count <= 0:
		result["reason"] = "empty_dirty_delta_batch"
		result["object_ref_update_reason"] = "empty_dirty_delta_batch"
		return result
	if not dirty_delta_buffer.is_valid():
		result["reason"] = "dirty_delta_buffer_not_ready"
		result["object_ref_update_reason"] = "dirty_delta_buffer_not_ready"
		return result
	if not _ensure_uploaded_for_object_ref_update(result):
		return result
	var update_stats := _update_gpu_autoobject_object_refs_from_dirty_delta_buffer(
		dirty_delta_buffer,
		dirty_delta_count,
		dirty_delta_capacity,
		dirty_delta_source
	)
	return _assemble_object_ref_update_result(update_stats, result)

## 获取全部场景体素瓦片的副本
func get_scene_voxel_tiles() -> Dictionary:
	var snapshot := readback_scene_voxel_tile_debug_snapshot()
	var result := {}
	var summaries: Array = snapshot.get("summary_records", [])
	var records: Array = snapshot.get("tile_records", [])
	for index in range(records.size()):
		var tile: Dictionary = records[index].duplicate(true)
		if index < summaries.size():
			tile.merge(summaries[index], true)
		result[str(tile.get("scene_voxel_tile_id", ""))] = tile
	return result

## 获取指定坐标的场景体素瓦片记录
func get_scene_voxel_tile(tile_coord: Vector3i) -> Dictionary:
	var tile_key := SceneVoxelTileCodecScript.tile_key(tile_coord)
	var tile_grid := _scene_voxel_tile_grid_size()
	if tile_coord.x < 0 or tile_coord.y < 0 or tile_coord.z < 0 \
			or tile_coord.x >= tile_grid.x or tile_coord.y >= tile_grid.y or tile_coord.z >= tile_grid.z:
		return {}
	return get_scene_voxel_tiles().get(tile_key, {})

## 只回读**这一块** tile 的 object-ref 槽位（refs_per_tile × u32，默认 8 槽 = 32 B），
## 数出其中的非空槽数量。
##
## ⚠ 数据源必须是 `scene_voxel_tile_object_refs` 槽位缓冲：写槽位的
## `scene_voxel_tile_object_ref_update.glsl` **只碰这块缓冲**，从不回填 tile record 的
## `object_range_count`（record buffer 偏移 84）。所以对一条 GPU 回读的 record 调
## `SceneVoxelTileCodec.object_ref_count()` 恒得 0 —— 选中面板 refs 长期显示 0 就是这条路。
##
## ⚠ 本函数存在的**唯一**理由是逐次点选：`get_scene_voxel_tile()` 那条路要经
## `SceneVoxelDebug.readback_tile_snapshot()`，除瓦片记录外还会回读整块 complexity /
## collision 常驻场（各 4 MiB）并逐体素解码成 PackedFloat32Array，再深拷贝全部 2048 条
## 记录（实测 306–428 ms）。本函数只 `buffer_get_data` 32 B。
## 计数口径与整表版共用同一实现（`object_ref_counts_from_slot_bytes`），不会两边对不上。
##
## 返回 -1 = **取不到**（缓冲未上传 / 坐标越界），不是 0：0 的含义是"这块砖确实没有引用"，
## 两者混同正是本函数要修掉的谎报。
func get_scene_voxel_tile_object_ref_count(tile_coord: Vector3i) -> int:
	var tile_grid := _scene_voxel_tile_grid_size()
	if tile_coord.x < 0 or tile_coord.y < 0 or tile_coord.z < 0 \
			or tile_coord.x >= tile_grid.x or tile_coord.y >= tile_grid.y or tile_coord.z >= tile_grid.z:
		push_error("[SceneVoxelTileStore] get_scene_voxel_tile_object_ref_count: tile 坐标 %s 越出瓦片网格 %s —— 返回 -1（未知），不是 0。" % [
			str(tile_coord), str(tile_grid)])
		return -1
	var rid: RID = _scene_voxel_tile_gpu_buffers.get(SCENE_VOXEL_TILE_OBJECT_REF_BUFFER, RID())
	var buffer_byte_size := int(_scene_voxel_tile_gpu_buffer_byte_sizes.get(SCENE_VOXEL_TILE_OBJECT_REF_BUFFER, 0))
	var tile_slot_bytes := SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT * SCENE_VOXEL_TILE_REF_STRIDE_BYTES
	var byte_offset := SceneVoxelTileCodecScript.tile_index(tile_coord, tile_grid) * tile_slot_bytes
	if not rid.is_valid() or byte_offset + tile_slot_bytes > buffer_byte_size:
		push_error("[SceneVoxelTileStore] get_scene_voxel_tile_object_ref_count: %s 槽位缓冲不可读（tile=%s rid_valid=%s 需要 [%d, %d) 字节，实际容量 %d）—— 返回 -1（未知）。" % [
			SCENE_VOXEL_TILE_OBJECT_REF_BUFFER, str(tile_coord), str(rid.is_valid()),
			byte_offset, byte_offset + tile_slot_bytes, buffer_byte_size])
		return -1
	var counts := SceneVoxelTileCodecScript.object_ref_counts_from_slot_bytes(
		read_buffer_bytes(rid, byte_offset, tile_slot_bytes),
		1,
		SCENE_VOXEL_TILE_OBJECT_REFS_PER_TILE_DEFAULT
	)
	# 回读短于一格槽位时 counts 会是空数组（codec 按可用槽位截断，不补零伪造）。
	if counts.is_empty():
		push_error("[SceneVoxelTileStore] get_scene_voxel_tile_object_ref_count: tile=%s 的槽位回读为空（期望 %d 字节）—— 返回 -1（未知）。" % [
			str(tile_coord), tile_slot_bytes])
		return -1
	return int(counts[0])

