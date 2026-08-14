class_name ScenePlacementRuntime
extends "res://scripts/godot_compute_shader_base.gd"

## RefCounted GPU implementation owned exclusively by ScenePlacementActor.
## Scene/demo/plugin callers must use the Node3D facade instead of constructing this type.

## Central orchestrator for the MeshFill placement pipeline.
##
## Owns the descriptor → GPU profile buffer lifecycle so that AssetDescriptor
## data (probes, collision, pivots) is always GPU-readable.  SV (SceneVoxel)
## and AutoObject data flow through a single orchestrated pipeline:
##
##   register assets → prefilter (SV→candidates) → placement (candidates→instances) → commit
##
## Lifecycle contract:
##   1. initialize()         — acquire RenderingDevice, share with profile container
##   2. register_asset()     — descriptor → profile_id, immediately GPU-resident
##   3. run_pipeline()       — prefilter + placement + optional commit
##   4. dispose()            — release GPU buffers

const PrefilterScript := preload("res://scripts/autoobject_probe_prefilter_gpu.gd")
const VPGScript := preload("res://scripts/voxel_placement_generator.gd")
const RuntimeProfileContainerScript := preload("res://scripts/auto_voxel_runtime_profile_container.gd")
const SceneVoxelCommitterScript := preload("res://scripts/scene_voxel_committer.gd")
const SceneVoxelTileStoreScript := preload("res://scripts/scene_voxel_tile_store.gd")
const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")
const GPUAutoObjectRuntimeScript := preload("res://scripts/gpu_autoobject_runtime.gd")
const AssetDescriptor := preload("res://scripts/asset_descriptor.gd")
const AutoObject := preload("res://scripts/auto_object.gd")
const AutoObjectProbePrefilterGPU := preload("res://scripts/autoobject_probe_prefilter_gpu.gd")
const AutoVoxelRuntimeProfileContainer := preload("res://scripts/auto_voxel_runtime_profile_container.gd")
const GPUAutoObjectRuntime := preload("res://scripts/gpu_autoobject_runtime.gd")
const SceneVoxelCommitter := preload("res://scripts/scene_voxel_committer.gd")
const SceneVoxelTileStore := preload("res://scripts/scene_voxel_tile_store.gd")
const VoxelPlacementGenerator := preload("res://scripts/voxel_placement_generator.gd")
const BufferUtils := preload("res://scripts/utils/buffer_utils.gd")
const HashUtils := preload("res://scripts/utils/hash_utils.gd")
const ReportSchema := preload("res://scripts/utils/report_schema.gd")

const MESH_DESCRIPTION_BUFFER := "mesh_description"
const MESH_DESCRIPTION_STRIDE_BYTES := 128
const MESH_DESCRIPTION_FLAG_HAS_MESH := 1
const MESH_DESCRIPTION_FLAG_HAS_SOURCE_MESH := 2
const MESH_DESCRIPTION_FLAG_SOURCE_DIFFERS := 4
const MESH_DESCRIPTION_FLAG_HAS_SOURCE_PATH := 8
const RESIDENT_TARGET_READ_BUFFERS_OPT_IN_KEY := "use_resident_target_read_buffer_handoff"
const TARGET_READ_BUFFERS_DEBUG_READBACK_KEY := "debug_read_target_read_buffer_bytes"
## BrushSV 常驻旁路层 + BlendSV 按需合成（方案A：committed SV 纯 auto，brush 不进提交）
## 散射 stride/路径/键/展平/dispatch 半边已抽取到 utils/sv_field_scatter.gd（与 committer stamp-only 提交共享）。
const SvFieldScatter := preload("res://scripts/utils/sv_field_scatter.gd")
## 场对 Buffer 生命周期的统一实现（《AutoVolume 公用体积基类计划》§2.5-7）。
## BrushSV 与 BlendSV 两处分配段收敛到它；同一个类也被 AutoVolumeField 持有，
## 所以卷侧与 runtime 侧从此走的是同一段分配/复用/重建/释放逻辑。
const VolumeFieldBuffersScript := preload("res://scripts/utils/volume_field_buffers.gd")
const COMPOSE_BLEND_SV_SHADER := "res://shaders/compose_blend_sv_fields.glsl"
const BLENDSV_FEEDBACK_SHADER := "res://shaders/score_blendsv_feedback.glsl"
const SV_FIELD_RECORD_FLOAT_STRIDE := SvFieldScatter.RECORD_FLOAT_STRIDE
const BLENDSV_FEEDBACK_QUANT_SCALE := 1000.0
const BLENDSV_FEEDBACK_OCCUPIED_EPSILON := 0.001

# std430 push-constant 布局（迁移自手写 push.encode_* 序列；字节布局逐字保持）。
const COMPOSE_BLEND_SV_PUSH := [
	["voxel_count", "int"], ["collision_word_count", "int"], ["_pad0", "int"], ["_pad1", "int"],
]
const BLENDSV_FEEDBACK_PUSH := [
	["voxel_count", "int"], ["has_target_collision", "int"],
	["occupied_epsilon", "float"], ["quant_scale", "float"],
]
# ---------------------------------------------------------------------------
# Fields
# ---------------------------------------------------------------------------

## Owned profile container — all registered descriptors live here, GPU-resident.
var _runtime_profile_container: AutoVoxelRuntimeProfileContainer

## SPA-owned AutoObject GPU state component; lifecycle is always owned by SPA.
var _gpu_runtime: GPUAutoObjectRuntime
var _autoobject_runtime_capacity := 1024

## External references (borrowed, not owned).
var _sv_committer: SceneVoxelCommitter
var _tile_store: SceneVoxelTileStore
var _grid_owner: Object

## Asset registry — parallel arrays mapping asset_index → descriptor + profile_id.
var _registered_descriptors: Array[AssetDescriptor] = []
var _registered_profile_ids: Array[int] = []
var _registered_mesh: Array[Mesh] = []
var _registered_autoobject_refs: Array[AutoObject] = []
var _owned_autoobjects: Array[AutoObject] = []
var _mesh_description_buffer: RID
var _mesh_description_record_count := 0
var _mesh_description_logical_byte_size := 0
var _mesh_description_gpu_byte_size := 0
var _mesh_description_revision := 0
var _mesh_description_uploaded_revision := -1
var _last_asset_batch_phases_ms := {}
var _last_mesh_description_upload_error := ""
var _resident_target_field_buffer: RID
var _resident_target_collision_buffer: RID
var _resident_target_collision_byte_count := 0
var _resident_target_read_buffer_cache_key: Dictionary = {}
var _resident_target_read_buffer_revision := 0

## Pipeline workers (created lazily, share the same RenderingDevice).
var _prefilter: AutoObjectProbePrefilterGPU
var _placer: VoxelPlacementGenerator

## Cached lightweight AutoObject wrappers (invalidated on registry change).
## Maps asset_index → lightweight AutoObject.  Only stores wrappers we created,
## never live scene nodes.
var _cached_lightweight_wrappers: Dictionary = {}

## State.
var _initialized := false
var _last_pipeline_result: Dictionary = {}
var _brush_sv_control_metadata: Dictionary = {}
var _gpu_runtime_scene_voxel_setup_result: Dictionary = {}

## BrushSV 常驻旁路层（SPA 生命周期内持有；不进 committed SV）
##
## ⚠ 场对的 RID 与体素数**不再**是三个裸成员，统一交给 VolumeFieldBuffers
## （《AutoVolume 公用体积基类计划》§2.5-7）。BrushSV 与 BlendSV 的分配段此前逐字重复，
## 且 BlendSV 那份漏检 collision RID —— 收敛顺带修掉，见 volume_field_buffers.gd 的类注释。
## `has_content` / `revision` 留在这里：它们是 BrushSV 的**内容语义**，不属于 Buffer 层。
var _brush_sv_fields: VolumeFieldBuffersScript = null
var _brush_sv_has_content := false
var _brush_sv_revision := 0

## BlendSV 临时合成对（SV + BrushSV；对比 TargetSV / 3D score 用，用完即删）
var _blend_sv_fields: VolumeFieldBuffersScript = null
## BlendSV 内容修订号：合成成功即递增（与 _brush_sv_revision 同款——事实源在 runtime，
## `BlendSVVolume.revision()` 转发）。⚠ 递增点必须在这里而不是 SPA 门面：生产管线的合成
## 是 runtime 内部自调（见 :2242 附近），不经过门面——2026-08-10 前挂在门面上的计数
## 正因如此从未接到生产事件。单调递增、release 不清零：报告里 resident = revision > 0
## 的语义是「合成发生过」，不是「场对此刻在 GPU 上」。
var _blend_sv_revision := 0

# --------------------------------------------------------------------------
# 初始化与生命周期
# --------------------------------------------------------------------------

## 获取 RenderingDevice、初始化 profile 容器与 GPU runtime，可选挂载 sv_committer；SPA 使用前必须调用，失败返回 false
func initialize(
	prefer_local_device: bool = true,
	allow_global_fallback: bool = true,
	sv_committer: SceneVoxelCommitter = null,
	tile_store: SceneVoxelTileStore = null,
	grid_owner: Object = null
) -> bool:
	if _initialized:
		push_warning("ScenePlacementActor: already initialized; call dispose() first.")
		return true

	log_name = "ScenePlacementActor"

	if not ensure_device(prefer_local_device, allow_global_fallback):
		push_error("ScenePlacementActor: no RenderingDevice available.")
		return false

	_runtime_profile_container = RuntimeProfileContainerScript.new()
	if not _runtime_profile_container.attach_rendering_device(_rd, false):
		push_error("ScenePlacementActor: failed to attach RD to profile container.")
		_dispose_internal()
		return false

	_ensure_owned_gpu_runtime()
	if sv_committer != null:
		attach_sv_committer(sv_committer)
	_tile_store = tile_store
	_grid_owner = grid_owner

	_ensure_gpu_runtime_for_scene_voxel_committer()
	_initialized = true
	return true


## 释放所有 GPU 资源并调用父类 dispose；由外部生命周期管理者（插件/测试）调用
func dispose(sync_before_free: bool = true) -> void:
	_dispose_internal(sync_before_free)
	super.dispose()


## 内部清理：释放 cached wrappers、handoff 缓冲、mesh description、profile 容器、prefilter、placer 及自有 gpu_runtime；由 dispose 和初始化失败路径调用
func _dispose_internal(sync_before_free: bool = true) -> void:
	_free_cached_wrappers()
	_release_resident_target_read_buffer_handoff()
	_release_mesh_description_buffer()
	clear_brush_sv(true)
	release_blend_sv_fields()

	if _runtime_profile_container != null:
		_runtime_profile_container.dispose(sync_before_free)
		_runtime_profile_container = null

	if _prefilter != null:
		_prefilter.dispose()
		_prefilter = null

	if _placer != null:
		_placer.dispose()
		_placer = null

	if _gpu_runtime != null:
		_gpu_runtime.dispose(sync_before_free)

	_registered_descriptors.clear()
	_registered_profile_ids.clear()
	_registered_mesh.clear()
	_registered_autoobject_refs.clear()
	_clear_owned_autoobjects()
	_last_pipeline_result.clear()
	_brush_sv_control_metadata.clear()
	_gpu_runtime_scene_voxel_setup_result.clear()

	_initialized = false
	_sv_committer = null
	_tile_store = null
	_grid_owner = null
	_gpu_runtime = null


## 返回 SPA 是否已成功初始化（RD 与 profile 容器均有效）；由 run_placement_pipeline 等各 API 入口前置检查调用
func is_initialized() -> bool:
	return _initialized and _rd != null and _runtime_profile_container != null


# --------------------------------------------------------------------------
# 外部引用挂载
# --------------------------------------------------------------------------

## 注入外部 SceneVoxelCommitter 引用，并同步到 gpu_runtime；由外部在 SV 就绪后调用
func attach_sv_committer(sv_committer: SceneVoxelCommitter) -> void:
	_sv_committer = sv_committer
	_ensure_gpu_runtime_for_scene_voxel_committer()


## 返回当前挂载的 SceneVoxelCommitter（可能为 null）；由外部查询使用
## （2026-08-02 别名收敛：原名 get_sv_committer，统一为 get_scene_voxel_committer）
func get_scene_voxel_committer() -> SceneVoxelCommitter:
	return _sv_committer


## 返回 GPU autoobject runtime（不存在时自动创建自有 runtime）；由外部及 pipeline 路径调用
func get_gpu_runtime() -> GPUAutoObjectRuntime:
	_ensure_owned_gpu_runtime()
	return _gpu_runtime


## 返回 SPA 是否拥有 gpu_runtime 的生命周期所有权（恒为 true，SPA 始终自持）；由 dispose 路径判断是否负责释放
func owns_gpu_runtime() -> bool:
	return true


## 设置 autoobject runtime 最大对象数量，可选重建自有 runtime；由外部在 initialize 前后均可调用
func set_autoobject_runtime_capacity(max_objects: int, recreate_owned_runtime: bool = false) -> void:
	_autoobject_runtime_capacity = maxi(max_objects, 1)
	if recreate_owned_runtime and _gpu_runtime != null:
		_gpu_runtime.dispose(false)
		_gpu_runtime = null
		_ensure_owned_gpu_runtime()
		_ensure_gpu_runtime_for_scene_voxel_committer()


## 返回当前设定的 autoobject runtime 最大对象容量
func get_autoobject_runtime_capacity() -> int:
	return _autoobject_runtime_capacity


## 若尚无 gpu_runtime 则创建自有实例（容量 = _autoobject_runtime_capacity）；由 get_gpu_runtime 与 pipeline 入口懒初始化调用
func _ensure_owned_gpu_runtime() -> GPUAutoObjectRuntime:
	if _gpu_runtime != null:
		return _gpu_runtime
	_gpu_runtime = GPUAutoObjectRuntimeScript.new(_autoobject_runtime_capacity, false)
	return _gpu_runtime


## 返回 GPU-resident 的 profile 容器；由外部直接访问 profile 缓冲时调用
func get_runtime_profile_container() -> AutoVoxelRuntimeProfileContainer:
	return _runtime_profile_container



# --------------------------------------------------------------------------
# GPU 就绪与缓冲查询
# --------------------------------------------------------------------------

## 返回 SPA 的 GPU 综合就绪状态（RD、profile container、prefilter shader 均有效）；由 pipeline 前置检查调用
func is_gpu_ready() -> bool:
	if not is_initialized():
		return false
	if _runtime_profile_container == null:
		return false
	return _runtime_profile_container.is_runtime_ready() and is_mesh_description_gpu_ready()


## 返回各 GPU 子系统就绪状态的详细诊断字典；供调试工具检查哪个组件未就绪
func get_gpu_readiness_report() -> Dictionary:
	if not is_initialized():
		return {"ok": false, "reason": "not_initialized"}
	if _runtime_profile_container == null:
		return {"ok": false, "reason": "no_profile_container"}

	var summary := _runtime_profile_container.get_gpu_buffer_summary()
	summary["ok"] = _runtime_profile_container.is_runtime_ready() and is_mesh_description_gpu_ready()
	summary["asset_count"] = _registered_descriptors.size()
	summary["profile_ids"] = _registered_profile_ids.duplicate()
	summary["mesh_description"] = get_mesh_description_gpu_buffer_summary()
	return summary


# profile_table / profile_sample_records / pivot_records 三个 RID 访问器已随扁平 buffer
# 在阶段 B 退役：coarse/fine/stamp 与 results→world 现在统一绑 get_profile_arena_buffer()。


## 返回固定槽位 Profile Arena 的唯一 GPU buffer RID（Header/Samples/Pivots/Mesh 全在内）；
## 由已迁移到单 binding 的 GPU pass 绑定 uniform 时调用。
func get_profile_arena_buffer() -> RID:
	if not is_gpu_ready():
		return RID()
	return _runtime_profile_container.get_profile_arena_buffer()


## Arena 状态与内存预算摘要（Inspector 状态面板与诊断的数据来源）。
func get_profile_arena_summary() -> Dictionary:
	if _runtime_profile_container == null:
		return {}
	return _runtime_profile_container.get_profile_arena_summary()


## 合并 profile container 与 mesh description 的 GPU buffer 状态摘要；供外部整体诊断
func get_merged_gpu_buffer_summary() -> Dictionary:
	var report := get_gpu_readiness_report()
	if _gpu_runtime != null:
		report["gpu_runtime"] = {
			"ready": _gpu_runtime.is_ready(),
			"max_objects": _gpu_runtime.max_objects,
			"lifecycle_owner": "ScenePlacementActor",
		}
		report["gpu_runtime_scene_voxel_setup"] = _gpu_runtime_scene_voxel_setup_result.duplicate(true)
	if _sv_committer != null:
		report["sv_committer_attached"] = true
	if not _brush_sv_control_metadata.is_empty():
		report["brush_sv"] = get_brush_sv_persistence_metadata()
	return report


## 返回 gpu_runtime 是否就绪；由 pipeline 判断能否执行 spawn/flush 时调用
func is_autoobject_runtime_ready() -> bool:
	return _gpu_runtime != null and _gpu_runtime.is_ready()


## Compiles the complete Place shader family without dispatching placement.
## The actor, profile buffers, target buffers, and runtime remain unchanged.
func prepare_place_pipeline() -> Dictionary:
	if not is_initialized():
		return {"ok": false, "reason": "actor_not_initialized"}
	if _registered_descriptors.is_empty():
		return {"ok": false, "reason": "no_registered_assets"}
	return _get_placer().prepare_placement_pipeline()


## Prefilter + Place 两族 shader 的统一预热入口，由 register_asset_batch() 在注册收尾时调用。
## 二者的 _load_shaders() 原本都长在各自的 run 路径里：有复用守卫，但"编译那一次"落在用户的
## 第一次 Score/Place 交互上（local RenderingDevice 拿不到驱动的 VkPipelineCache，这一次是
## 十几个 pipeline 的冷编译）。注册资产本就是重的 setup 步骤，把编译并到这里。
## 已就绪时两侧都是廉价的 readiness 检查，重复调用无副作用。
func prepare_pipelines() -> Dictionary:
	if not is_initialized():
		return {"ok": false, "reason": "actor_not_initialized"}
	if _registered_descriptors.is_empty():
		return {"ok": false, "reason": "no_registered_assets"}
	var prefilter_report: Dictionary = _get_prefilter().prepare_prefilter_pipeline(_runtime_profile_container)
	var place_report: Dictionary = _get_placer().prepare_placement_pipeline()
	return {
		"ok": bool(prefilter_report.get("ok", false)) and bool(place_report.get("ok", false)),
		"prefilter": prefilter_report,
		"place": place_report,
	}


func get_place_pipeline_readiness() -> Dictionary:
	if _placer == null:
		return {
			"ok": false,
			"reason": "placer_not_created",
			"fine_pipeline_ready": false,
			"placement_pipeline_ready": false,
		}
	var readiness: Dictionary = _placer.get_placement_pipeline_readiness()
	readiness["reason"] = "ok" if bool(readiness.get("ok", false)) else "placement_shader_pipeline_not_ready"
	return readiness


func get_place_resource_lifecycle_summary() -> Dictionary:
	if _placer == null:
		return {
			"ready": false,
			"reason": "placer_not_created",
		}
	var summary := _placer.get_resource_lifecycle_summary()
	summary["ready"] = true
	return summary



# --------------------------------------------------------------------------
# 资产注册
# --------------------------------------------------------------------------

## Register a single AssetDescriptor.  Returns its profile_id (>=0) or -1
## on failure.  The owned profile container immediately uploads its three
## resident GPU buffers (profile_table / profile_sample_records /
## pivot_records), then the runtime re-uploads the mesh description buffer.
## Descriptor collision is normalized and baked once at registration (with
## clearance flags) into fine-stage records of the shared
## profile_sample_records buffer, and score/stamp shaders read that slice
## directly via the profile table's fine_sample_start/count — there is no
## per-run asset shape packing step anymore.
func register_asset(descriptor: AssetDescriptor, mesh_ref: Mesh = null, autoobject_ref: AutoObject = null) -> int:
	if not is_initialized():
		push_error("ScenePlacementActor: not initialized.")
		return -1
	if descriptor == null:
		push_error("ScenePlacementActor: null descriptor.")
		return -1

	var profile_id := _runtime_profile_container.register_descriptor(descriptor)
	if profile_id < 0:
		push_error("ScenePlacementActor: failed to register descriptor.")
		return -1

	if not _runtime_profile_container.upload_profiles(false):
		push_error("ScenePlacementActor: failed to upload profiles to GPU.")
		return -1

	_free_cached_wrappers()

	_registered_descriptors.append(descriptor)
	_registered_profile_ids.append(profile_id)
	_registered_mesh.append(mesh_ref)
	_registered_autoobject_refs.append(autoobject_ref)
	if autoobject_ref != null:
		own_autoobject(autoobject_ref, _registered_autoobject_refs.size() - 1)
	_mark_mesh_description_changed()

	if not _upload_mesh_description_buffer():
		push_error("ScenePlacementActor: failed to upload mesh descriptions to GPU.")
		return -1

	return profile_id


## Registers a descriptor group and uploads the shared profile and mesh buffers
## once after all staging records have been appended.
func register_asset_batch(
		descriptors: Array,
		mesh_refs: Array = [],
		autoobject_refs: Array = []
) -> Array[int]:
	var total_t0_usec := Time.get_ticks_usec()
	var phase_t0_usec := total_t0_usec
	_last_asset_batch_phases_ms = {}
	var result: Array[int] = []
	if not is_initialized():
		push_error("ScenePlacementActor: not initialized.")
		result.resize(descriptors.size())
		result.fill(-1)
		return result

	# 并行数组契约：mesh_refs / autoobject_refs 要么整体缺省（空），要么与 descriptors 等长。
	# 旧行为 `i < size() else null` 会把长度不足的部分静默补 null —— 资产悄悄丢 mesh /
	# autoobject 绑定，注册表里再也查不出是哪儿断的，故改为硬失败。
	for parallel_entry in [["mesh_refs", mesh_refs], ["autoobject_refs", autoobject_refs]]:
		var parallel_name := str(parallel_entry[0])
		var parallel_array: Array = parallel_entry[1]
		if not parallel_array.is_empty() and parallel_array.size() != descriptors.size():
			push_error("ScenePlacementActor.register_asset_batch: %s 与 descriptors 长度不匹配（descriptors=%d, %s=%d）——静默补 null 会让部分资产丢失绑定。" % [
				parallel_name, descriptors.size(), parallel_name, parallel_array.size()])
			assert(false, "ScenePlacementActor.register_asset_batch: parallel array size mismatch")
			result.resize(descriptors.size())
			result.fill(-1)
			return result

	var pending: Array[Dictionary] = []
	_runtime_profile_container.reset_registration_diagnostics()
	for i in range(descriptors.size()):
		var descriptor := descriptors[i] as AssetDescriptor
		if descriptor == null:
			push_error("ScenePlacementActor: null descriptor.")
			result.append(-1)
			continue
		var profile_id := _runtime_profile_container.register_descriptor(descriptor)
		if profile_id < 0:
			push_error("ScenePlacementActor: failed to register descriptor.")
			result.append(-1)
			continue
		result.append(profile_id)
		pending.append({
			"input_index": i,
			"descriptor": descriptor,
			"profile_id": profile_id,
			"mesh": mesh_refs[i] as Mesh if i < mesh_refs.size() else null,
			"autoobject": autoobject_refs[i] as AutoObject if i < autoobject_refs.size() else null,
		})
	_last_asset_batch_phases_ms["stage_descriptors"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	_last_asset_batch_phases_ms["stage_descriptors_detail"] = \
		_runtime_profile_container.get_registration_diagnostics()

	if pending.is_empty():
		return result

	phase_t0_usec = Time.get_ticks_usec()
	if not _runtime_profile_container.upload_profiles(false):
		push_error("ScenePlacementActor: failed to upload profiles to GPU.")
		for entry in pending:
			result[int(entry.get("input_index", -1))] = -1
		return result
	_last_asset_batch_phases_ms["upload_profiles"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0

	phase_t0_usec = Time.get_ticks_usec()
	_free_cached_wrappers()
	for entry in pending:
		var descriptor: AssetDescriptor = entry.get("descriptor") as AssetDescriptor
		var autoobject_ref: AutoObject = entry.get("autoobject") as AutoObject
		_registered_descriptors.append(descriptor)
		_registered_profile_ids.append(int(entry.get("profile_id", -1)))
		_registered_mesh.append(entry.get("mesh") as Mesh)
		_registered_autoobject_refs.append(autoobject_ref)
		if autoobject_ref != null:
			own_autoobject(autoobject_ref, _registered_autoobject_refs.size() - 1)
	_last_asset_batch_phases_ms["append_registry"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	phase_t0_usec = Time.get_ticks_usec()
	_mark_mesh_description_changed()
	if not _upload_mesh_description_buffer():
		push_error("ScenePlacementActor: failed to upload mesh descriptions to GPU.")
		for entry in pending:
			result[int(entry.get("input_index", -1))] = -1
	_last_asset_batch_phases_ms["upload_mesh_descriptions"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0

	# shader 预热：注册完资产就把 prefilter + Place 两族 pipeline 编出来，别让第一次
	# Score/Place 点击自己承担冷编译。失败不影响注册结果——run 路径仍有各自的编译与就绪检查。
	phase_t0_usec = Time.get_ticks_usec()
	var prewarm := prepare_pipelines()
	if not bool(prewarm.get("ok", false)):
		push_warning("ScenePlacementActor.register_asset_batch: pipeline 预热未完成（%s）—— 首次 Score/Place 会在交互内编译。" % str(prewarm))
	_last_asset_batch_phases_ms["prepare_pipelines"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	_last_asset_batch_phases_ms["total"] = float(Time.get_ticks_usec() - total_t0_usec) / 1000.0
	return result


## 构建一条 mesh description 并写进它所属 Arena slot 的 Mesh 区（upload 前的必经步骤）。
## 失败已在内部报出具体原因，调用方只需按整批失败处理。
## 单 Profile Slot 局部更新的实际调用面（固定槽位Profile共享Buffer实施计划 §8.3）。
##
## 重新构建 asset_index 对应资产的 mesh description 并刷新**扁平 per-asset**
## mesh description buffer（`MESH_DESCRIPTION_BUFFER`，全部 GPU 消费者读的就是它）。
##
## ⚠ 本函数原先还会把同一条记录写进 Arena 的 per-profile Mesh 区。该副本已移除：
## mesh 是**每资产**的，而 Arena slot 是**每 profile** 的，两者基数不同——
## `profile_hash` 不含 mesh（这是对的：同 profile = 同评分行为），于是两个 mesh 不同、
## 评分行为相同的资产会共享一个 slot，固定槽位装不下两份。原实现对此硬失败
## （`set_slot_mesh_description_bytes` 的同槽冲突守卫），实测被项目自有资产触发
## （`geo_sm_ground_grass`），导致 register_asset 整条路不可用。
##
## 解法是把 Mesh 区从 profile 槽位解耦，而不是把 mesh 塞进 profile_hash——后者会让
## 两个只是换了 mesh、评分完全一致的资产白占两份 profile 数据。
##
## 返回 false 时缓冲未被改动。
func refresh_slot_mesh_description(asset_index: int) -> bool:
	if not is_initialized():
		push_error("ScenePlacementActor.refresh_slot_mesh_description: not initialized.")
		return false
	if asset_index < 0 or asset_index >= _registered_descriptors.size():
		push_error("ScenePlacementActor.refresh_slot_mesh_description: asset_index=%d 越界（asset_count=%d）。" % [
			asset_index, _registered_descriptors.size()])
		assert(false, "ScenePlacementActor.refresh_slot_mesh_description: asset_index out of range")
		return false
	_mark_mesh_description_changed()
	return _upload_mesh_description_buffer()


## Canonical AutoObject asset entry point.  The actor owns registry/profile
## upload; callers may keep local arrays only as UI or authoring caches.
## 从 AutoObject 提取 descriptor 并注册为资产，返回 profile_id；由外部批量注册 autoobject 时调用
func register_autoobject_asset(autoobject_ref: AutoObject, mesh_ref: Mesh = null) -> int:
	if autoobject_ref == null:
		push_error("ScenePlacementActor: null AutoObject asset.")
		return -1
	var descriptor := _descriptor_from_autoobject_asset(autoobject_ref)
	if descriptor == null:
		push_error("ScenePlacementActor: AutoObject asset has no descriptor.")
		return -1
	var resolved_mesh := mesh_ref
	if resolved_mesh == null:
		resolved_mesh = autoobject_ref.mesh
	if resolved_mesh == null:
		resolved_mesh = descriptor.get_mesh()
	return register_asset(descriptor, resolved_mesh, autoobject_ref)


## 批量注册 AssetDescriptor 数组，返回各自 profile_id 列表；由外部传入 descriptor 列表时调用
## Register multiple descriptors at once.  Returns an Array of profile_ids
## (parallel to the input array).  -1 means registration failed for that entry.
func register_assets(descriptors: Array[AssetDescriptor]) -> Array[int]:
	return register_asset_batch(descriptors)


## 事务式整体替换资产注册表（固定槽位Profile共享Buffer实施计划 §7 / §8.1）。
##
##     校验全部输入 → 构建临时 Registry → 构建临时 CPU Arena
##       → 一次创建/上传 ProfileArenaBuffer → 原子替换运行时状态 → 释放旧 Arena
##
## 关键点：新 Arena 建在一个**临时容器**里，旧容器（RID / Registry / Revision）在
## 整个构建期原样有效；只有全部校验与上传都成功，才一次性换掉容器实例与注册表。
## 任一步失败即释放临时容器返回 false，运行时状态一字未动——不会出现"清空了但新
## 数据没上去"的中间态（旧实现先 clear_assets() 再逐条注册，失败就停在空注册表上）。
##
## 返回 false 时保证：容器实例、Arena RID、Arena 内容、Registry、Revision 全部不变。
func replace_all_assets(
	descriptors: Array[AssetDescriptor],
	meshes: Array = [],
	autoobjects: Array = []
) -> bool:
	if not is_initialized():
		push_error("ScenePlacementActor.replace_all_assets: not initialized.")
		return false

	# 并行数组契约与 register_asset_batch 一致：要么整体缺省，要么与 descriptors 等长。
	for parallel_entry in [["meshes", meshes], ["autoobjects", autoobjects]]:
		var parallel_name := str(parallel_entry[0])
		var parallel_array: Array = parallel_entry[1]
		if not parallel_array.is_empty() and parallel_array.size() != descriptors.size():
			push_error("ScenePlacementActor.replace_all_assets: %s 与 descriptors 长度不匹配（descriptors=%d, %s=%d）。" % [
				parallel_name, descriptors.size(), parallel_name, parallel_array.size()])
			assert(false, "ScenePlacementActor.replace_all_assets: parallel array size mismatch")
			return false

	# 空集是合法请求（"卸载全部资产"），走既有的清空路径。
	if descriptors.is_empty():
		clear_assets()
		return true

	# ── 1) 全量前置校验：任何一条不合法都整批拒绝，此时运行时状态还没被碰过 ──
	for i in range(descriptors.size()):
		if descriptors[i] == null:
			push_error("ScenePlacementActor.replace_all_assets: descriptors[%d] 为 null —— 整批拒绝，保留现有资产。" % i)
			assert(false, "ScenePlacementActor.replace_all_assets: null descriptor")
			return false

	# ── 2) 临时容器：新 Arena 在这里构建并上传，旧 Arena 全程仍可用 ──
	var staging_container: AutoVoxelRuntimeProfileContainer = RuntimeProfileContainerScript.new()
	if not staging_container.attach_rendering_device(_rd, false):
		push_error("ScenePlacementActor.replace_all_assets: 临时 profile 容器无法绑定 RenderingDevice —— 保留现有资产。")
		assert(false, "ScenePlacementActor.replace_all_assets: staging container attach failed")
		return false
	staging_container.reset_registration_diagnostics()

	var staged_profile_ids: Array[int] = []
	for i in range(descriptors.size()):
		var profile_id := staging_container.register_descriptor(descriptors[i])
		if profile_id < 0:
			push_error("ScenePlacementActor.replace_all_assets: descriptors[%d]（%s）注册失败 —— 整批回滚，保留现有资产。" % [
				i, descriptors[i].resource_path])
			staging_container.dispose()
			return false
		staged_profile_ids.append(profile_id)

	# ── 3) mesh description 构建预检（不写 Arena）──
	# Arena 的 per-profile Mesh 区已移除（mesh 是每资产的、slot 是每 profile 的，基数不同，
	# 见 refresh_slot_mesh_description 的说明）。真正的 mesh 数据走扁平 per-asset
	# MESH_DESCRIPTION_BUFFER。这一趟只做**提前失败**：任何一条构不出来就整批回滚，
	# 而不是等到上传完 Arena 再发现。
	for i in range(descriptors.size()):
		var mesh_ref: Mesh = meshes[i] as Mesh if i < meshes.size() else null
		var autoobject_ref: AutoObject = autoobjects[i] as AutoObject if i < autoobjects.size() else null
		var description := make_mesh_description(
			descriptors[i], mesh_ref, autoobject_ref, i, staged_profile_ids[i])
		if description.is_empty():
			push_error("ScenePlacementActor.replace_all_assets: descriptors[%d] 的 mesh description 构建失败 —— 整批回滚。" % i)
			staging_container.dispose()
			return false

	# ── 4) 固定容量校验 + 一次 Arena 创建/上传 ──
	var capacity_errors := staging_container.validate_arena_capacity()
	if not capacity_errors.is_empty():
		push_error("ScenePlacementActor.replace_all_assets: 固定 Slot 容量超限，整批拒绝（现有资产与旧 Arena 保持有效）：\n  %s" % "\n  ".join(capacity_errors))
		staging_container.dispose()
		return false
	# Revision 跨容器实例保持单调：新 Arena 的 revision = 旧 revision + 1，而不是从 1 重来。
	if _runtime_profile_container != null:
		staging_container.adopt_revision_baseline(_runtime_profile_container.get_arena_revision())
	if not staging_container.upload_profiles(true):
		push_error("ScenePlacementActor.replace_all_assets: 新 Arena 上传失败（%s）—— 整批回滚，保留现有资产。" % str(
			staging_container.get_gpu_buffer_summary().get("last_upload_error", "")))
		staging_container.dispose()
		return false

	# ── 5) 原子替换：RID / Registry / Revision 作为同一状态整体切换（§7 末段）──
	_free_cached_wrappers()
	var previous_container := _runtime_profile_container
	_runtime_profile_container = staging_container
	_registered_descriptors.clear()
	_registered_profile_ids.clear()
	_registered_mesh.clear()
	_registered_autoobject_refs.clear()
	_clear_owned_autoobjects()
	for i in range(descriptors.size()):
		_registered_descriptors.append(descriptors[i])
		_registered_profile_ids.append(staged_profile_ids[i])
		_registered_mesh.append(meshes[i] as Mesh if i < meshes.size() else null)
		var autoobject_ref: AutoObject = autoobjects[i] as AutoObject if i < autoobjects.size() else null
		_registered_autoobject_refs.append(autoobject_ref)
		if autoobject_ref != null:
			own_autoobject(autoobject_ref, i)

	# ── 6) 释放旧 Arena（此刻新状态已完全生效）──
	if previous_container != null and previous_container != staging_container:
		previous_container.dispose()

	# ── 7) 迁移期并存的扁平 mesh description buffer（阶段 B 随旧路径一并退役）──
	_mark_mesh_description_changed()
	if not _upload_mesh_description_buffer():
		push_error("ScenePlacementActor.replace_all_assets: mesh description buffer 上传失败 —— Arena 已切换，mesh 元数据缓冲落后。")
		return false

	# shader 预热：与 register_asset_batch 同理，别让首次 Score/Place 承担冷编译。
	var prewarm := prepare_pipelines()
	if not bool(prewarm.get("ok", false)):
		push_warning("ScenePlacementActor.replace_all_assets: pipeline 预热未完成（%s）—— 首次 Score/Place 会在交互内编译。" % str(prewarm))
	return true


## 清空资产后批量注册 AutoObject 数组，返回是否全部成功；由 autoobject 集合更换时调用。
## descriptor/mesh 解析链与 register_autoobject_asset 相同（入参 mesh 为空时依次取
## autoobject.mesh、descriptor.get_mesh()），解析完成后走 register_asset_batch 单次上传。
func replace_all_autoobject_assets(autoobjects: Array) -> bool:
	clear_assets()
	if autoobjects.is_empty():
		return true
	var descriptors: Array = []
	var meshes: Array = []
	var refs: Array = []
	var resolve_failed := false
	for raw in autoobjects:
		var autoobject_ref := raw as AutoObject
		if autoobject_ref == null:
			push_error("ScenePlacementActor: null AutoObject asset.")
			resolve_failed = true
			continue
		var descriptor := _descriptor_from_autoobject_asset(autoobject_ref)
		if descriptor == null:
			push_error("ScenePlacementActor: AutoObject asset has no descriptor.")
			resolve_failed = true
			continue
		var resolved_mesh: Mesh = autoobject_ref.mesh
		if resolved_mesh == null:
			resolved_mesh = descriptor.get_mesh()
		descriptors.append(descriptor)
		meshes.append(resolved_mesh)
		refs.append(autoobject_ref)
	if descriptors.is_empty():
		return not resolve_failed
	var profile_ids := register_asset_batch(descriptors, meshes, refs)
	return not resolve_failed and not profile_ids.has(-1)


## 清空所有已注册资产、profile、mesh 及 autoobject 引用并重置 mesh description 缓冲；由 replace 路径或外部重置调用
## Clear the asset registry and re-upload an empty profile set.
func clear_assets() -> void:
	_free_cached_wrappers()
	if _runtime_profile_container != null:
		_runtime_profile_container.clear()
		# 清空后的空 profile 集必须真的推到 GPU：吞掉失败会让 GPU 侧继续留着旧 profile，
		# 之后按新 profile_id 采样读到的是上一批资产的数据（静默脏数据）。
		if not _runtime_profile_container.upload_profiles(true):
			push_error("ScenePlacementActor.clear_assets: 清空后的 profile 上传失败 —— GPU 仍持有上一批资产的 profile 数据，无法恢复一致状态。")
			assert(false, "ScenePlacementActor.clear_assets: upload_profiles(true) failed")
	_registered_descriptors.clear()
	_registered_profile_ids.clear()
	_registered_mesh.clear()
	_registered_autoobject_refs.clear()
	_clear_owned_autoobjects()
	_mark_mesh_description_changed()
	_release_mesh_description_buffer()


## 返回已注册资产数量
func get_asset_count() -> int:
	return _registered_descriptors.size()


## 返回已注册 AssetDescriptor 数组的引用；供外部查询与调试
func get_registered_descriptors() -> Array[AssetDescriptor]:
	return _registered_descriptors.duplicate()


## 返回已注册 profile_id 数组；供外部查询与调试
func get_registered_profile_ids() -> Array[int]:
	return _registered_profile_ids.duplicate()


## 根据 asset_index 返回对应 profile_id；越界或无效时返回 -1
func get_profile_id_for_asset(asset_index: int) -> int:
	if asset_index < 0 or asset_index >= _registered_profile_ids.size():
		return -1
	return _registered_profile_ids[asset_index]


# --------------------------------------------------------------------------
# AutoObject 管理
# --------------------------------------------------------------------------

## 返回已注册 AutoObject 引用数组；供 pipeline 构建 autoobject 数组
func get_registered_autoobject_refs() -> Array[AutoObject]:
	_prune_owned_autoobjects()
	return _registered_autoobject_refs.duplicate()


## 更新指定 asset_index 的 AutoObject 引用；由 own_autoobject 或外部在创建实例后调用
func set_registered_autoobject_ref(asset_index: int, autoobject_ref: AutoObject) -> bool:
	if asset_index < 0 or asset_index >= _registered_autoobject_refs.size():
		return false
	_registered_autoobject_refs[asset_index] = autoobject_ref
	_free_cached_wrappers()
	_mark_mesh_description_changed()
	if is_initialized():
		return _upload_mesh_description_buffer()
	return true


## 接管 AutoObject 的生命周期所有权，可选绑定 asset_index；同时注册到 autoobject_ref 表；由 SPA 负责创建 autoobject 场景时调用
func own_autoobject(autoobject_ref: AutoObject, asset_index: int = -1) -> bool:
	if autoobject_ref == null:
		return false
	_prune_owned_autoobjects()
	if not _owned_autoobjects.has(autoobject_ref):
		_owned_autoobjects.append(autoobject_ref)
	autoobject_ref.set_meta("spa_owned", true)
	autoobject_ref.set_meta("spa_owner", "ScenePlacementActor")
	if asset_index >= 0:
		autoobject_ref.set_meta("spa_asset_id", asset_index)
		if asset_index < _registered_autoobject_refs.size():
			var registered_ref: AutoObject = _registered_autoobject_refs[asset_index]
			if registered_ref == null or registered_ref.is_queued_for_deletion():
				set_registered_autoobject_ref(asset_index, autoobject_ref)
	return true


## 取消对 AutoObject 的所有权并清理元数据；由外部移除单个 autoobject 时调用
func release_autoobject(autoobject_ref: AutoObject) -> bool:
	if autoobject_ref == null:
		return false
	var removed := _owned_autoobjects.has(autoobject_ref)
	if removed:
		_owned_autoobjects.erase(autoobject_ref)
	var released_asset_index := int(autoobject_ref.get_meta("spa_asset_id", -1))
	_clear_autoobject_owner_metadata(autoobject_ref)
	if released_asset_index >= 0 and released_asset_index < _registered_autoobject_refs.size():
		if _registered_autoobject_refs[released_asset_index] == autoobject_ref:
			set_registered_autoobject_ref(released_asset_index, _find_owned_autoobject_for_asset(released_asset_index))
	_prune_owned_autoobjects()
	return removed


## 返回 SPA 拥有的全部 AutoObject 数组（已过期条目自动剪除）
func get_owned_autoobjects() -> Array[AutoObject]:
	_prune_owned_autoobjects()
	return _owned_autoobjects.duplicate()


## 返回 SPA 当前持有的有效 AutoObject 数量
func get_owned_autoobject_count() -> int:
	_prune_owned_autoobjects()
	return _owned_autoobjects.size()


## 按索引返回指定自有 AutoObject；越界返回 null
func get_owned_autoobject(index: int) -> AutoObject:
	_prune_owned_autoobjects()
	if index < 0 or index >= _owned_autoobjects.size():
		return null
	return _owned_autoobjects[index]


## 判断指定 AutoObject 是否属于 SPA 自有；由归属检查路径调用
func has_owned_autoobject(autoobject_ref: AutoObject) -> bool:
	_prune_owned_autoobjects()
	return autoobject_ref != null and _owned_autoobjects.has(autoobject_ref)


## 查找 AutoObject 在注册表中的 asset_index；未找到返回 -1
func get_asset_id_for_autoobject(autoobject_ref: AutoObject) -> int:
	if autoobject_ref == null:
		return -1
	for i in range(_registered_autoobject_refs.size()):
		if _registered_autoobject_refs[i] == autoobject_ref:
			return i
	var meta_asset_index := int(autoobject_ref.get_meta("spa_asset_id", -1))
	if meta_asset_index >= 0 and meta_asset_index < _registered_descriptors.size():
		return meta_asset_index
	return -1


## 在自有 AutoObject 中查找绑定了指定 asset_index 的实例；由 pipeline 分配 autoobject 时调用
func _find_owned_autoobject_for_asset(asset_index: int) -> AutoObject:
	_prune_owned_autoobjects()
	for obj in _owned_autoobjects:
		if obj != null and int(obj.get_meta("spa_asset_id", -1)) == asset_index:
			return obj
	return null


## 移除 _owned_autoobjects 中已失效（WeakRef 为 null）的条目；由 get_owned_autoobjects 等调用
func _prune_owned_autoobjects() -> void:
	for i in range(_owned_autoobjects.size() - 1, -1, -1):
		var obj := _owned_autoobjects[i]
		if obj == null or obj.is_queued_for_deletion():
			_owned_autoobjects.remove_at(i)


## 清空自有 AutoObject 列表，可选清除各实例的元数据标记；由 clear_assets 和 _dispose_internal 调用
func _clear_owned_autoobjects(clear_metadata: bool = true) -> void:
	if clear_metadata:
		for obj in _owned_autoobjects:
			_clear_autoobject_owner_metadata(obj)
	_owned_autoobjects.clear()


## 清除单个 AutoObject 上 SPA 写入的 owner 元数据；由 release_autoobject 与 _clear_owned_autoobjects 调用
func _clear_autoobject_owner_metadata(autoobject_ref: AutoObject) -> void:
	if autoobject_ref == null:
		return
	for key in ["spa_owned", "spa_owner", "spa_asset_id"]:
		if autoobject_ref.has_meta(key):
			autoobject_ref.remove_meta(key)


## 从 AutoObject 的 voxel_profile 属性提取 AssetDescriptor；由 register_autoobject_asset 调用
func _descriptor_from_autoobject_asset(autoobject_ref: AutoObject) -> AssetDescriptor:
	if autoobject_ref == null:
		return null
	var descriptor := autoobject_ref.asset_descriptor as AssetDescriptor
	if descriptor == null:
		autoobject_ref.get_voxel_color()
		descriptor = autoobject_ref.asset_descriptor as AssetDescriptor
	if descriptor == null:
		descriptor = AutoObject.create_asset_descriptor(
			autoobject_ref.voxel_color,
			autoobject_ref.voxel_complexity,
			autoobject_ref.mesh_size * 0.5,
			autoobject_ref.collision,
			autoobject_ref.pivot_variants,
			autoobject_ref.semantic_probe_generator,
			autoobject_ref.semantic_probe_density,
			autoobject_ref.context_sensing_radius
		) as AssetDescriptor
		autoobject_ref.asset_descriptor = descriptor
	if descriptor == null:
		push_error("ScenePlacementActor._descriptor_from_autoobject_asset: AutoObject.create_asset_descriptor 返回 null（asset_id=\"%s\", mesh=%s）——没有 descriptor 就没有 GPU profile，注册无法继续。" % [
			autoobject_ref.asset_id, str(autoobject_ref.mesh)])
		assert(false, "ScenePlacementActor._descriptor_from_autoobject_asset: create_asset_descriptor returned null")
		return null
	if descriptor.asset_id.is_empty() and not autoobject_ref.asset_id.is_empty():
		descriptor.asset_id = autoobject_ref.asset_id
	if descriptor.object_type.is_empty():
		descriptor.object_type = autoobject_ref.get_record_object_type()
	if descriptor.mesh == null and autoobject_ref.mesh != null:
		descriptor.mesh = autoobject_ref.mesh
	var resolved_source_mesh := autoobject_ref.get_source_mesh()
	if descriptor.source_mesh == null and resolved_source_mesh != null:
		descriptor.source_mesh = resolved_source_mesh
	if descriptor.source_mesh_path.is_empty() and not autoobject_ref.source_mesh_path.is_empty():
		descriptor.source_mesh_path = autoobject_ref.source_mesh_path
	return descriptor



# --------------------------------------------------------------------------
# Mesh Description GPU 缓冲
# --------------------------------------------------------------------------

## 返回指定 asset_index 的 mesh description 字典（含 mesh 路径、source 路径、标志位等）；由调试与 mesh description buffer 上传路径调用
func get_mesh_description_for_asset(asset_index: int) -> Dictionary:
	if asset_index < 0 or asset_index >= _registered_descriptors.size():
		return {}
	# 并行注册表不变量：descriptors / profile_ids / mesh / autoobject_refs 逐条 append，长度必须一致。
	# 旧行为在越界时静默取 null，把“注册表已经不一致”伪装成“这个资产没有 mesh”。
	if _registered_profile_ids.size() != _registered_descriptors.size() \
			or _registered_mesh.size() != _registered_descriptors.size() \
			or _registered_autoobject_refs.size() != _registered_descriptors.size():
		push_error("ScenePlacementActor.get_mesh_description_for_asset: 注册表并行数组长度不一致（descriptors=%d, profile_ids=%d, mesh=%d, autoobject_refs=%d, asset_index=%d）——描述无法可信构建。" % [
			_registered_descriptors.size(), _registered_profile_ids.size(),
			_registered_mesh.size(), _registered_autoobject_refs.size(), asset_index])
		assert(false, "ScenePlacementActor.get_mesh_description_for_asset: registry parallel arrays out of sync")
		return {}
	var descriptor := _registered_descriptors[asset_index] as AssetDescriptor
	if descriptor == null:
		push_error("ScenePlacementActor.get_mesh_description_for_asset: asset_index=%d 的 descriptor 为 null（asset_count=%d）——register_asset 拒收 null descriptor，出现即注册表已损坏。" % [
			asset_index, _registered_descriptors.size()])
		assert(false, "ScenePlacementActor.get_mesh_description_for_asset: null descriptor in registry")
		return {}
	return make_mesh_description(
		descriptor,
		_registered_mesh[asset_index],
		_registered_autoobject_refs[asset_index],
		asset_index,
		_registered_profile_ids[asset_index]
	)


## 从一组显式入参构建 mesh description（不读成员注册表）。
## 生效注册表与**事务式替换的临时注册表**共用同一构建逻辑——后者在 registry 换上去
## 之前就得先算出 mesh description 灌进 Arena slot，那时成员数组还是旧的。
static func make_mesh_description(
	descriptor: AssetDescriptor,
	mesh_ref: Mesh,
	autoobject_ref: AutoObject,
	asset_index: int,
	profile_id: int
) -> Dictionary:
	var resolved_mesh := mesh_ref
	if resolved_mesh == null:
		resolved_mesh = descriptor.get_mesh()

	var source_mesh_ref: Mesh = descriptor.get_source_mesh()
	if source_mesh_ref == null and autoobject_ref != null:
		source_mesh_ref = autoobject_ref.get_source_mesh()
	if source_mesh_ref == null:
		source_mesh_ref = resolved_mesh

	var mesh_aabb := AABB()
	var mesh_surface_count := 0
	if resolved_mesh != null:
		mesh_aabb = resolved_mesh.get_aabb()
		mesh_surface_count = resolved_mesh.get_surface_count()

	var source_mesh_aabb := AABB()
	var source_mesh_surface_count := 0
	if source_mesh_ref != null:
		source_mesh_aabb = source_mesh_ref.get_aabb()
		source_mesh_surface_count = source_mesh_ref.get_surface_count()

	return {
		"asset_index": asset_index,
		"profile_id": profile_id,
		"descriptor": descriptor,
		"autoobject_ref": autoobject_ref,
		"asset_name": descriptor.asset_id,
		"object_type": descriptor.object_type,
		"object_subtype": "",
		"mesh": resolved_mesh,
		"mesh_aabb": mesh_aabb,
		"mesh_surface_count": mesh_surface_count,
		"source_mesh": source_mesh_ref,
		"source_mesh_path": descriptor.source_mesh_path,
		"source_mesh_aabb": source_mesh_aabb,
		"source_mesh_surface_count": source_mesh_surface_count,
	}


## 返回所有已注册资产的 mesh description 字典列表；由调试与外部查询调用
func get_registered_mesh_descriptions() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for asset_index in range(_registered_descriptors.size()):
		result.append(get_mesh_description_for_asset(asset_index))
	return result


## 返回 mesh description GPU storage buffer RID；由 GPU shader pass 需要 mesh 信息时调用
func get_mesh_description_buffer() -> RID:
	if not is_mesh_description_gpu_ready():
		return RID()
	return _mesh_description_buffer


## 返回 mesh description buffer 是否已上传且版本一致；由 pipeline 前置检查与外部调用
func is_mesh_description_gpu_ready() -> bool:
	return _rd != null \
		and _mesh_description_buffer.is_valid() \
		and _mesh_description_uploaded_revision == _mesh_description_revision \
		and _mesh_description_record_count == _registered_descriptors.size()


## 返回 mesh description buffer 状态摘要（RID、字节大小、版本、最近错误等）；供调试与外部诊断
func get_mesh_description_gpu_buffer_summary() -> Dictionary:
	return {
		"read_source": "gpu_buffers",
		"runtime_read_source": "gpu_buffers" if is_mesh_description_gpu_ready() else "none",
		"readback_source": "gpu_buffers" if is_mesh_description_gpu_ready() else "none",
		"staging_source": "spa_asset_registry",
		"control_plane": "ScenePlacementActor",
		"runtime_payload": "gpu_mesh_description_buffer",
		"gpu_first": true,
		"cpu_fallback": false,
		"runtime_ready": is_mesh_description_gpu_ready(),
		"rid_valid": _mesh_description_buffer.is_valid(),
		"buffer_name": MESH_DESCRIPTION_BUFFER,
		"record_count": _mesh_description_record_count,
		"asset_count": _registered_descriptors.size(),
		"stride_bytes": MESH_DESCRIPTION_STRIDE_BYTES,
		"logical_byte_count": _mesh_description_logical_byte_size,
		"gpu_byte_count": _mesh_description_gpu_byte_size,
		"gpu_revision": _mesh_description_uploaded_revision,
		"staging_revision": _mesh_description_revision,
		"last_upload_error": _last_mesh_description_upload_error,
	}


## CPU 回读 mesh description GPU buffer 并解码为可读字典列表；供调试工具验证 GPU 数据
func readback_mesh_description_debug_snapshot() -> Dictionary:
	var summary := get_mesh_description_gpu_buffer_summary()
	if not is_mesh_description_gpu_ready():
		return {
			"read_source": "gpu_buffers",
			"runtime_read_source": "none",
			"readback_source": "none",
			"staging_source": "spa_asset_registry",
			"control_plane": "ScenePlacementActor",
			"runtime_payload": "gpu_mesh_description_buffer",
			"gpu_first": true,
			"cpu_fallback": false,
			"readback_snapshot": false,
			"runtime_ready": false,
			"gpu_buffer_summary": summary,
		}
	var bytes := _rd.buffer_get_data(_mesh_description_buffer, 0, _mesh_description_logical_byte_size)
	var expected_byte_count := _mesh_description_record_count * MESH_DESCRIPTION_STRIDE_BYTES
	var readback_ok := bytes.size() == expected_byte_count
	return {
		"read_source": "gpu_buffers",
		"runtime_read_source": "gpu_buffers",
		"readback_source": "gpu_buffers" if readback_ok else "none",
		"failed_readback_source": "none" if readback_ok else "gpu_buffers",
		"staging_source": "spa_asset_registry",
		"control_plane": "ScenePlacementActor",
		"runtime_payload": "gpu_mesh_description_buffer",
		"gpu_first": true,
		"cpu_fallback": false,
		"readback_snapshot": readback_ok,
		"runtime_ready": true,
		"readback_validation": {
			"ok": readback_ok,
			"reason": "ok" if readback_ok else "readback_byte_count_mismatch",
			"expected_byte_count": expected_byte_count,
			"actual_byte_count": bytes.size(),
			"gpu_first": true,
			"cpu_fallback": false,
		},
		"gpu_buffer_summary": summary,
		"mesh_description_bytes": bytes,
		"decoded_mesh_descriptions": _decode_mesh_description_bytes(bytes, _mesh_description_record_count),
	}


# ---------------------------------------------------------------------------
# BrushSV 常驻旁路层（内容面）+ BlendSV 按需合成
# ---------------------------------------------------------------------------

## 确保 BrushSV 常驻 field 对存在（体素数取 committer SV 网格；变化时重建并清空内容）
##
## ⚠ 分配/复用/重建/释放这一整段已收敛到 VolumeFieldBuffers（§2.5-7），本函数只剩
## 「体素数从哪来」+「内容语义怎么变」两件 BrushSV 自己的事。别把分配细节写回来。
func ensure_brush_sv_fields() -> Dictionary:
	if _rd == null:
		push_error("ScenePlacementActor.ensure_brush_sv_fields: 无 RenderingDevice —— BrushSV 常驻层无法创建，笔刷内容会被静默丢弃。")
		assert(false, "ScenePlacementActor.ensure_brush_sv_fields: _rd == null")
		return {}
	var voxel_count := _sv_field_voxel_count()
	if voxel_count <= 0:
		push_error("ScenePlacementActor.ensure_brush_sv_fields: SV 网格体素数非法（voxel_count=%d, grid_owner=%s）——BrushSV 无法定尺寸。" % [
			voxel_count, str(_grid_owner)])
		assert(false, "ScenePlacementActor.ensure_brush_sv_fields: voxel_count <= 0")
		return {}
	var fields := _ensure_brush_sv_field_buffers()
	if fields == null:
		return {}
	var result := fields.ensure(voxel_count)
	if not bool(result.get("ok", false)):
		# 具体成因（无设备 / 体素数非正 / 某个场创建失败）已由 VolumeFieldBuffers 报出并断言，
		# 且它保证不留半份 RID。这里只负责把内容标志同步回"空"。
		_brush_sv_has_content = false
		return {}
	if bool(result.get("created", false)):
		# 新分配出来的场对是全零 —— 内容标志必须跟着回落，否则 has_brush_sv_content()
		# 会对一块空缓冲说"有内容"，下游合成与评分会白跑一趟。
		_brush_sv_has_content = false
	return _brush_sv_field_summary(voxel_count, bool(result.get("created", false)))


## 惰性建 BrushSV 的场对持有者，并挂上重建前置钩子。
##
## 钩子承接的是旧代码里 `clear_brush_sv(true)` 那半段**非释放**语义：内容标志归零 +
## 有状态时递增修订号。纯 free_rid 顶不掉它——消费方靠修订号判断"笔刷内容换了没有"。
func _ensure_brush_sv_field_buffers() -> VolumeFieldBuffersScript:
	if _brush_sv_fields != null:
		return _brush_sv_fields
	var fields := VolumeFieldBuffersScript.new()
	if not fields.configure(
			self,
			VolumeFieldBuffersScript.schema_v1_field_specs("spa_brush_sv"),
			SCOPE_PERSISTENT,
			"ScenePlacementRuntime/BrushSV"):
		return null
	fields.set_before_realloc_hook(_on_brush_sv_fields_realloc)
	_brush_sv_fields = fields
	return _brush_sv_fields


func _on_brush_sv_fields_realloc() -> void:
	var had_state := _brush_sv_has_content or (_brush_sv_fields != null and _brush_sv_fields.is_resident())
	_brush_sv_has_content = false
	if had_state:
		_brush_sv_revision += 1


## 将笔刷体素记录散射进 BrushSV 常驻层（复用 stamp-only 散射 shader；不触碰 committed SV）。
## 记录字段：voxel_xz: Vector2i、slice_index: int、complexity: float、color: Color、collision_strength: float
##
## 本函数无状态：只写它收到的这一批记录（write_mode=0 overwrite，后笔胜）。因此调用方
## 允许"增量提交"——只发本次新增/变更的体素，已提交且取值未变的体素不必重发，最终 GPU
## 状态与整批重放一致（overwrite 幂等）。判断"取值未变"的责任在调用方（见
## ScenePlacementActor._flush_owned_brush 的水位失效条件）。
func write_brush_sv_records(records: Array) -> Dictionary:
	if records.is_empty():
		return {"ok": true, "record_count": 0, "gpu_dispatched": false}
	var fields := ensure_brush_sv_fields()
	if fields.is_empty():
		return {"ok": false, "reason": "brush_sv_fields_not_ready", "record_count": records.size(), "gpu_dispatched": false}

	# 按体素去重（后笔胜），保证单次散射 dispatch 内无同体素写竞态
	var deduped: Dictionary = {}
	for record_index in range(records.size()):
		var raw_record = records[record_index]
		# 记录字段是文档化契约（voxel_xz / slice_index / complexity / color / collision_strength）。
		# 旧行为对坏记录 continue、对缺键取默认值（slice=0 / 白色 / complexity=1.0），笔刷会
		# 悄悄少写体素或写进错误的层与颜色，事后无法与“用户就这么画的”区分开。
		if not raw_record is Dictionary:
			push_error("ScenePlacementActor.write_brush_sv_records: records[%d] 不是 Dictionary（type=%s, record_count=%d）。" % [
				record_index, type_string(typeof(raw_record)), records.size()])
			assert(false, "ScenePlacementActor.write_brush_sv_records: record is not a Dictionary")
			return {"ok": false, "reason": "brush_record_not_dictionary", "record_index": record_index, "record_count": records.size(), "gpu_dispatched": false}
		var record := raw_record as Dictionary
		for required_key in ["voxel_xz", "slice_index", "complexity", "color", "collision_strength"]:
			if not record.has(required_key):
				push_error("ScenePlacementActor.write_brush_sv_records: records[%d] 缺少必备键 \"%s\"（keys=%s）——补默认值等于写出用户没画过的笔刷体素。" % [
					record_index, required_key, str(record.keys())])
				assert(false, "ScenePlacementActor.write_brush_sv_records: brush record missing required key")
				return {"ok": false, "reason": "brush_record_missing_%s" % required_key, "record_index": record_index, "record_count": records.size(), "gpu_dispatched": false}
		var voxel_xz_value = record["voxel_xz"]
		if not voxel_xz_value is Vector2i:
			push_error("ScenePlacementActor.write_brush_sv_records: records[%d].voxel_xz 类型错误（期望 Vector2i，实际 %s）。" % [
				record_index, type_string(typeof(voxel_xz_value))])
			assert(false, "ScenePlacementActor.write_brush_sv_records: voxel_xz is not Vector2i")
			return {"ok": false, "reason": "brush_record_voxel_xz_type", "record_index": record_index, "record_count": records.size(), "gpu_dispatched": false}
		var color_value = record["color"]
		if not color_value is Color:
			push_error("ScenePlacementActor.write_brush_sv_records: records[%d].color 类型错误（期望 Color，实际 %s）。" % [
				record_index, type_string(typeof(color_value))])
			assert(false, "ScenePlacementActor.write_brush_sv_records: color is not Color")
			return {"ok": false, "reason": "brush_record_color_type", "record_index": record_index, "record_count": records.size(), "gpu_dispatched": false}
		var voxel_xz: Vector2i = voxel_xz_value
		var slice_index := int(record["slice_index"])
		var color: Color = color_value
		var slot := PackedFloat32Array()
		slot.resize(SV_FIELD_RECORD_FLOAT_STRIDE)
		slot[0] = float(voxel_xz.x)
		slot[1] = float(voxel_xz.y)
		slot[2] = float(slice_index)
		slot[3] = clampf(float(record["complexity"]), 0.0, 1.0)
		slot[4] = color.r
		slot[5] = color.g
		slot[6] = color.b
		slot[7] = clampf(float(record["collision_strength"]), 0.0, 1.0)
		deduped[SvFieldScatter.record_key(voxel_xz, slice_index)] = slot
	var record_count := deduped.size()
	if record_count <= 0:
		return {"ok": true, "record_count": 0, "gpu_dispatched": false}
	# write_mode 0：brush 层 overwrite（后笔胜，允许降低/擦除）；散射维度 = 规范网格三元组
	var grid := _sv_field_grid_size()
	var scatter_result := SvFieldScatter.dispatch_scatter(
		self,
		brush_sv_complexity_rid(),
		brush_sv_collision_rid(),
		deduped,
		grid,
		0,
		"brush_sv_scatter",
		"spa_brush_sv_scatter"
	)
	if not bool(scatter_result.get("ok", false)):
		return scatter_result
	_brush_sv_has_content = true
	_brush_sv_revision += 1
	if _sv_committer != null and _tile_store != null:
		# 脏标记走去重集合而非 raw records：deduped 的键正是 records 中全部合法
		# (voxel_xz, slice_index) 的去重集合，与逐条 raw record 标记覆盖同一批体素
		# —— bounds dirty 是幂等的位或（见 SceneVoxelTileStore._dispatch_scene_voxel_tile_
		# bounds_dirty_commands），重复条目只是重复置同一位。slot 布局见 SvFieldScatter：
		# [x, z, slice, ...]，故 voxel_min = (slot[0], slot[2], slot[1])。
		# dirty_flags / source_record 在 batch 内只被读取（flags_from_value 另建新字典，
		# source 只取 str），可安全共用同一实例，省掉每体素两次字典分配。
		var brush_dirty_flags := {"brush": true, "scoring": true}
		var brush_dirty_source := {"id": "brush_sv_stamp"}
		var brush_dirty_entries: Array = []
		brush_dirty_entries.resize(record_count)
		var dirty_entry_index := 0
		for record_key_value in deduped:
			var dirty_slot: PackedFloat32Array = deduped[record_key_value]
			var voxel_min := Vector3i(int(dirty_slot[0]), int(dirty_slot[2]), int(dirty_slot[1]))
			brush_dirty_entries[dirty_entry_index] = {
				"voxel_min": voxel_min,
				"voxel_max": voxel_min + Vector3i.ONE,
				"dirty_flags": brush_dirty_flags,
				"source_record": brush_dirty_source,
			}
			dirty_entry_index += 1
		_tile_store.mark_scene_voxel_tile_bounds_dirty_batch(brush_dirty_entries)
	return scatter_result


## 清空 BrushSV 常驻层；release_buffers=true 时连同缓冲一起释放
##
## ⚠ 两种模式的语义差别是**消费方缓存的 RID 会不会失效**：
##   release_buffers=false → 就地清零，RID 保留（下游 uniform set 不必重建）
##   release_buffers=true  → 释放 RID（下游必须重建）
## 旧实现把两者做成一个 bool 参数下的两条分支，且非释放分支**吞掉**了 buffer_zero 的返回值
## ——清不干净时表现为"清了但残留内容继续参与合成与评分"，零提示。现在两条路都会上报。
func clear_brush_sv(release_buffers: bool = false) -> void:
	var had_state := _brush_sv_has_content or (_brush_sv_fields != null and _brush_sv_fields.is_resident())
	if _brush_sv_fields != null:
		if release_buffers:
			_brush_sv_fields.release()
		else:
			_brush_sv_fields.clear_in_place()
	_brush_sv_has_content = false
	if had_state:
		_brush_sv_revision += 1


## BrushSV 是否有已写入内容
func has_brush_sv_content() -> bool:
	return _brush_sv_has_content and brush_sv_complexity_rid().is_valid()


func get_brush_sv_revision() -> int:
	return _brush_sv_revision


## BrushSV 场对的 RID。消费方一律经这两个访问器取，别去摸 _brush_sv_fields。
func brush_sv_complexity_rid() -> RID:
	return _brush_sv_fields.rid_of(VolumeFieldBuffersScript.FIELD_COMPLEXITY) if _brush_sv_fields != null else RID()


func brush_sv_collision_rid() -> RID:
	return _brush_sv_fields.rid_of(VolumeFieldBuffersScript.FIELD_COLLISION) if _brush_sv_fields != null else RID()


## BrushSV 常驻层摘要（RID/体素数/内容标志）
func get_brush_sv_field_summary() -> Dictionary:
	return _brush_sv_field_summary(_brush_sv_voxel_count(), false)


func _brush_sv_voxel_count() -> int:
	return _brush_sv_fields.element_count() if _brush_sv_fields != null else 0


func _brush_sv_field_summary(voxel_count: int, created: bool) -> Dictionary:
	return {
		"complexity_field_buffer": brush_sv_complexity_rid(),
		"collision_field_buffer": brush_sv_collision_rid(),
		"voxel_count": voxel_count,
		"has_content": _brush_sv_has_content,
		"created": created,
	}


## SV field 网格（xz_res, total_slices）：从 committer 网格元数据推导
## SV field 网格 = grid_owner 的规范 grid_size 原样。
## 迁移前这里投影成 Vector2i(xz_res, total_slices) —— 那是 SceneSV 侧那套「XZ 必须方形」
## 词汇的入口，散射着色器换成规范索引式后不再需要它。
func _sv_field_grid_size() -> Vector3i:
	if _grid_owner == null:
		# grid_owner 由 initialize() 注入且是网格尺寸的唯一来源；缺它旧行为返回零网格，
		# 让 BrushSV/BlendSV 静默按 0 体素工作（等于笔刷内容全丢）。
		push_error("ScenePlacementActor._sv_field_grid_size: _grid_owner 为 null —— 无网格来源，SV field 尺寸不可推导（initialize() 必须注入 grid_owner）。")
		assert(false, "ScenePlacementActor._sv_field_grid_size: _grid_owner == null")
		return Vector3i.ZERO
	var grid: Vector3i = _grid_owner.grid_size
	return Vector3i(maxi(grid.x, 0), maxi(grid.y, 0), maxi(grid.z, 0))


func _sv_field_voxel_count() -> int:
	if _grid_owner == null:
		push_error("ScenePlacementActor._sv_field_voxel_count: _grid_owner 为 null —— 无网格来源，体素数不可推导（initialize() 必须注入 grid_owner）。")
		assert(false, "ScenePlacementActor._sv_field_voxel_count: _grid_owner == null")
		return 0
	return VoxelGeneral.voxel_count(_grid_owner.grid_size)


## 按需合成 BlendSV 临时对（committed SV + BrushSV）；对比 TargetSV / 3D score 读取用。
## 返回空字典表示合成失败；无 brush 内容时调用方应直接使用 SV RID（零开销直通）。
func compose_blend_sv_fields(sv_complexity_rid: RID, sv_collision_rid: RID) -> Dictionary:
	if _rd == null or not sv_complexity_rid.is_valid() or not sv_collision_rid.is_valid():
		push_error("ScenePlacementActor.compose_blend_sv_fields: 入参不满足契约（rd=%s, sv_complexity_valid=%s, sv_collision_valid=%s）——没有 SV 常驻场就没法合成 BlendSV。" % [
			str(_rd != null), str(sv_complexity_rid.is_valid()), str(sv_collision_rid.is_valid())])
		assert(false, "ScenePlacementActor.compose_blend_sv_fields: invalid rd or sv field rids")
		return {}
	var fields := ensure_brush_sv_fields()
	if fields.is_empty():
		push_error("ScenePlacementActor.compose_blend_sv_fields: BrushSV 常驻层不可用 —— BlendSV 无法合成（详见上一条 ensure_brush_sv_fields 错误）。")
		assert(false, "ScenePlacementActor.compose_blend_sv_fields: brush sv fields unavailable")
		return {}
	# BlendSV 的体素数**跟随 BrushSV**，不是自己从网格推 —— 上面那句 ensure_brush_sv_fields()
	# 成功是它的前提。统一入口因此按「注入的元素数」工作，而不是写死 grid_owner.grid_size。
	var voxel_count := _brush_sv_voxel_count()
	# collision_word_count 单独算是因为它要进 push constant；数值与字节数 / 4 恒等。
	var collision_word_count := int(SceneVoxelTileCodecScript.u32_field_byte_count(voxel_count) / 4)

	# ⚠ 旧守卫只检查 complexity RID、不检查 collision（原 :1410）：collision 失效而
	# complexity 仍有效且体素数没变时，会跳过重建并把无效 RID 送进下面的 uniform set。
	# 统一入口按「所有场 RID 都有效 + 字节数都匹配」判命中，该情况改为重建 —— 这是修 bug，
	# 不是无害重构。
	if _blend_sv_fields == null:
		_blend_sv_fields = VolumeFieldBuffersScript.new()
		if not _blend_sv_fields.configure(
				self,
				VolumeFieldBuffersScript.schema_v1_field_specs("spa_blend_sv"),
				SCOPE_PERSISTENT,
				"ScenePlacementRuntime/BlendSV"):
			_blend_sv_fields = null
			return {}
	if not bool(_blend_sv_fields.ensure(voxel_count).get("ok", false)):
		# 成因已由 VolumeFieldBuffers 报出并断言，且它保证不留半份 RID。
		# 这里保持与旧代码一致：只 release，不 gc_frame —— gc_frame 是 pass 级清理，
		# 属于本函数后续三条失败路径的事，分配失败这条不碰它。
		release_blend_sv_fields()
		return {}

	var kernel := ensure_shader_kernel(COMPOSE_BLEND_SV_SHADER, "spa_compose_blend_sv")
	var shader: RID = kernel.get("shader", RID())
	var pipeline: RID = kernel.get("pipeline", RID())
	if not shader.is_valid() or not pipeline.is_valid():
		push_error("ScenePlacementActor.compose_blend_sv_fields: 合成 shader/pipeline 未就绪（shader=%s, pipeline=%s, path=%s）。" % [
			str(shader.is_valid()), str(pipeline.is_valid()), COMPOSE_BLEND_SV_SHADER])
		assert(false, "ScenePlacementActor.compose_blend_sv_fields: shader or pipeline invalid")
		gc_frame()
		release_blend_sv_fields()
		return {}
	var set0 := create_uniform_set([
		make_storage_uniform(0, sv_complexity_rid),
		make_storage_uniform(1, sv_collision_rid),
		make_storage_uniform(2, brush_sv_complexity_rid()),
		make_storage_uniform(3, brush_sv_collision_rid()),
		make_storage_uniform(4, blend_sv_complexity_rid()),
		make_storage_uniform(5, blend_sv_collision_rid()),
	], shader, 0, SCOPE_PASS, "spa_compose_blend_sv")
	if not set0.is_valid():
		push_error("ScenePlacementActor.compose_blend_sv_fields: uniform set 创建失败（voxel_count=%d）。" % voxel_count)
		assert(false, "ScenePlacementActor.compose_blend_sv_fields: uniform set invalid")
		gc_frame()
		release_blend_sv_fields()
		return {}
	var push := PushConstantLayout.new(COMPOSE_BLEND_SV_PUSH).pack({
		voxel_count = voxel_count,
		collision_word_count = collision_word_count,
	})
	var thread_count := maxi(voxel_count, collision_word_count)
	if not _gpu_dispatch_and_sync(pipeline, [set0], push, dispatch_groups_1d(thread_count, 64)):
		push_error("ScenePlacementActor.compose_blend_sv_fields: 合成 dispatch 失败（voxel_count=%d, collision_word_count=%d, thread_count=%d）。" % [
			voxel_count, collision_word_count, thread_count])
		assert(false, "ScenePlacementActor.compose_blend_sv_fields: dispatch failed")
		gc_frame()
		release_blend_sv_fields()
		return {}
	gc_frame()
	_blend_sv_revision += 1
	return {
		"complexity_field_buffer": blend_sv_complexity_rid(),
		"collision_field_buffer": blend_sv_collision_rid(),
		"voxel_count": voxel_count,
	}


func get_blend_sv_revision() -> int:
	return _blend_sv_revision


## BlendSV 场对的 RID。消费方一律经这两个访问器取。
func blend_sv_complexity_rid() -> RID:
	return _blend_sv_fields.rid_of(VolumeFieldBuffersScript.FIELD_COMPLEXITY) if _blend_sv_fields != null else RID()


func blend_sv_collision_rid() -> RID:
	return _blend_sv_fields.rid_of(VolumeFieldBuffersScript.FIELD_COLLISION) if _blend_sv_fields != null else RID()


## 释放 BlendSV 临时合成对（用完即删）
func release_blend_sv_fields() -> void:
	if _blend_sv_fields != null:
		_blend_sv_fields.release()


## 结果级 feedback：临时合成 BlendSV，与 TargetSV_B 读取缓冲对比 completeness/color 重合度，
## 读回统计后立即删除临时体素。target_visual_rgba8_bytes 的 alpha 即 target completeness。
func score_blendsv_feedback_against_target(
	target_visual_rgba8_bytes: PackedByteArray,
	target_collision_r8_bytes: PackedByteArray = PackedByteArray()
) -> Dictionary:
	if not is_initialized() or _sv_committer == null:
		return {"ok": false, "reason": "actor_or_committer_not_ready"}
	var committed_sv := _sv_committer.get_sv()
	if _tile_store != null:
		_tile_store.ensure_scene_voxel_tile_buffers_uploaded(false)
	var handoff := build_resident_complexity_field_handoff(committed_sv)
	if not bool(handoff.get("ok", false)):
		return {"ok": false, "reason": str(handoff.get("reason", "resident_field_handoff_failed"))}
	var sv_complexity: RID = handoff.get("complexity_field_buffer_rid", RID())
	var sv_collision: RID = handoff.get("collision_field_buffer_rid", RID())
	var voxel_count := _sv_field_voxel_count()
	if voxel_count <= 0 or target_visual_rgba8_bytes.size() < voxel_count * 4:
		return {"ok": false, "reason": "target_visual_bytes_size_mismatch", "expected_bytes": voxel_count * 4}

	# BlendSV：有 brush 内容才临时合成，否则直接对比 committed SV
	var blend_complexity := sv_complexity
	var blend_collision := sv_collision
	var blend_composed := false
	if has_brush_sv_content():
		var blend := compose_blend_sv_fields(sv_complexity, sv_collision)
		if blend.is_empty():
			return {"ok": false, "reason": "blend_sv_compose_failed"}
		blend_complexity = blend.get("complexity_field_buffer", RID())
		blend_collision = blend.get("collision_field_buffer", RID())
		blend_composed = true

	var kernel := ensure_shader_kernel(BLENDSV_FEEDBACK_SHADER, "spa_blendsv_feedback")
	var shader: RID = kernel.get("shader", RID())
	var pipeline: RID = kernel.get("pipeline", RID())
	var target_visual_buffer := storage_buffer_from_bytes(target_visual_rgba8_bytes, SCOPE_FRAME, "spa_blendsv_feedback_target_visual")
	var has_target_collision := target_collision_r8_bytes.size() >= SceneVoxelTileCodecScript.u32_field_byte_count(voxel_count)
	var target_collision_buffer := storage_buffer_from_bytes(
		target_collision_r8_bytes if has_target_collision else PackedByteArray([0, 0, 0, 0]),
		SCOPE_FRAME,
		"spa_blendsv_feedback_target_collision"
	)
	var stats_buffer := storage_buffer_zero(6 * 4, SCOPE_FRAME, "spa_blendsv_feedback_stats")
	if not shader.is_valid() or not pipeline.is_valid() or not target_visual_buffer.is_valid() \
			or not target_collision_buffer.is_valid() or not stats_buffer.is_valid():
		gc_frame()
		if blend_composed:
			release_blend_sv_fields()
		return {"ok": false, "reason": "feedback_gpu_resources_not_ready"}
	var set0 := create_uniform_set([
		make_storage_uniform(0, blend_complexity),
		make_storage_uniform(1, blend_collision),
		make_storage_uniform(2, target_visual_buffer),
		make_storage_uniform(3, target_collision_buffer),
		make_storage_uniform(4, stats_buffer),
	], shader, 0, SCOPE_PASS, "spa_blendsv_feedback")
	if not set0.is_valid():
		gc_frame()
		if blend_composed:
			release_blend_sv_fields()
		return {"ok": false, "reason": "feedback_uniform_set_failed"}
	var push := PushConstantLayout.new(BLENDSV_FEEDBACK_PUSH).pack({
		voxel_count = voxel_count,
		has_target_collision = 1 if has_target_collision else 0,
		occupied_epsilon = BLENDSV_FEEDBACK_OCCUPIED_EPSILON,
		quant_scale = BLENDSV_FEEDBACK_QUANT_SCALE,
	})
	if not _gpu_dispatch_and_sync(pipeline, [set0], push, dispatch_groups_1d(voxel_count, 64)):
		gc_frame()
		if blend_composed:
			release_blend_sv_fields()
		return {"ok": false, "reason": "feedback_dispatch_failed"}
	var stats_bytes := _rd.buffer_get_data(stats_buffer, 0, 6 * 4)
	gc_frame()
	if blend_composed:
		release_blend_sv_fields()  # 用完立马删除临时体素，BrushSV 常驻保留

	var blend_occupied := stats_bytes.decode_u32(0)
	var target_occupied := stats_bytes.decode_u32(4)
	var overlap := stats_bytes.decode_u32(8)
	var completeness_diff_sum := float(stats_bytes.decode_u32(12)) / BLENDSV_FEEDBACK_QUANT_SCALE
	var color_distance_sum := float(stats_bytes.decode_u32(16)) / BLENDSV_FEEDBACK_QUANT_SCALE
	var processed := stats_bytes.decode_u32(20)
	var union_count := blend_occupied + target_occupied - overlap
	return {
		"ok": true,
		"gpu_first": true,
		"cpu_fallback": false,
		"blend_source": "blend_sv_composed" if blend_composed else "committed_sv_direct",
		"voxel_count": int(processed),
		"blend_occupied_count": int(blend_occupied),
		"target_occupied_count": int(target_occupied),
		"overlap_count": int(overlap),
		"overlap_score": float(overlap) / float(maxi(union_count, 1)),
		"completeness_diff_mean": completeness_diff_sum / float(maxi(int(processed), 1)),
		"color_distance_mean": color_distance_sum / float(maxi(int(overlap), 1)),
	}


# ---------------------------------------------------------------------------
# Mesh Description GPU 缓冲 — 打包 / 上传 / 回读内部实现
# ---------------------------------------------------------------------------

## 递增 mesh description revision 标记，使下次 pipeline 触发重新上传；由 clear_assets 和 register_asset 调用
func _mark_mesh_description_changed() -> void:
	_mesh_description_revision += 1
	_mesh_description_uploaded_revision = -1


## 释放 mesh description GPU buffer RID；由 _dispose_internal 和 clear_assets 调用
func _release_mesh_description_buffer() -> void:
	if _mesh_description_buffer.is_valid():
		release_rid(_mesh_description_buffer)
	_mesh_description_buffer = RID()
	_mesh_description_record_count = 0
	_mesh_description_logical_byte_size = 0
	_mesh_description_gpu_byte_size = 0
	_mesh_description_uploaded_revision = -1


## 打包所有已注册 mesh 的 description 并上传为 GPU storage buffer；由 run_placement_pipeline 在 mesh description 版本不一致时调用
func _upload_mesh_description_buffer() -> bool:
	if _rd == null:
		_last_mesh_description_upload_error = "no_rendering_device"
		return false
	var bytes := _pack_mesh_description_bytes()
	var expected_pack_size := _registered_descriptors.size() * MESH_DESCRIPTION_STRIDE_BYTES
	if bytes.size() != expected_pack_size:
		# 打包尺寸不符 = 某条 description 构建失败（注册表损坏）。继续上传只会把零记录
		# 当成合法 mesh description 送上 GPU，评分/放置读到的是全零 AABB。
		_last_mesh_description_upload_error = "pack_size_mismatch:expected=%d actual=%d" % [expected_pack_size, bytes.size()]
		push_error("ScenePlacementActor._upload_mesh_description_buffer: mesh description 打包字节数不符（expected=%d, actual=%d, asset_count=%d）——不可恢复，拒绝上传。" % [
			expected_pack_size, bytes.size(), _registered_descriptors.size()])
		assert(false, "ScenePlacementActor._upload_mesh_description_buffer: packed byte count mismatch")
		return false
	var logical_size := bytes.size()
	var upload_bytes := bytes
	if upload_bytes.is_empty():
		upload_bytes.resize(4)
	var rid := track_rid(
		_rd.storage_buffer_create(upload_bytes.size(), upload_bytes),
		KIND_BUFFER,
		SCOPE_PERSISTENT,
		"spa_mesh_description"
	)
	if not rid.is_valid():
		_last_mesh_description_upload_error = "storage_buffer_create_failed:%s" % MESH_DESCRIPTION_BUFFER
		return false
	if _mesh_description_buffer.is_valid():
		release_rid(_mesh_description_buffer)
	_mesh_description_buffer = rid
	_mesh_description_record_count = _registered_descriptors.size()
	_mesh_description_logical_byte_size = logical_size
	_mesh_description_gpu_byte_size = upload_bytes.size()
	_mesh_description_uploaded_revision = _mesh_description_revision
	_last_mesh_description_upload_error = ""
	return true


## 将所有已注册 mesh 的元数据（路径 hash、标志位、source 信息）序列化为 PackedByteArray；由 _upload_mesh_description_buffer 调用
func _pack_mesh_description_bytes() -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(_registered_descriptors.size() * MESH_DESCRIPTION_STRIDE_BYTES)
	for asset_index in range(_registered_descriptors.size()):
		var description := get_mesh_description_for_asset(asset_index)
		if description.is_empty():
			push_error("ScenePlacementActor._pack_mesh_description_bytes: asset_index=%d 的 mesh description 构建失败 —— 继续打包会写出全零记录。" % asset_index)
			assert(false, "ScenePlacementActor._pack_mesh_description_bytes: empty description")
			return PackedByteArray()
		_encode_mesh_description_record(bytes, asset_index * MESH_DESCRIPTION_STRIDE_BYTES, description)
	return bytes


## mesh description 记录的唯一编码器：扁平 per-asset buffer 专用
## （Arena slot 的 Mesh 区副本已移除；CPU 侧打包入口 pack_mesh_description_record 亦随之删除）。
static func _encode_mesh_description_record(
	bytes: PackedByteArray, base: int, description: Dictionary
) -> void:
	var mesh_ref: Mesh = description.get("mesh", null)
	var source_mesh_ref: Mesh = description.get("source_mesh", null)
	var mesh_aabb: AABB = description.get("mesh_aabb", AABB())
	var source_mesh_aabb: AABB = description.get("source_mesh_aabb", AABB())
	var source_path := str(description.get("source_mesh_path", ""))
	var flags := 0
	if mesh_ref != null:
		flags |= MESH_DESCRIPTION_FLAG_HAS_MESH
	if source_mesh_ref != null:
		flags |= MESH_DESCRIPTION_FLAG_HAS_SOURCE_MESH
	if mesh_ref != null and source_mesh_ref != null and source_mesh_ref != mesh_ref:
		flags |= MESH_DESCRIPTION_FLAG_SOURCE_DIFFERS
	if not source_path.is_empty():
		flags |= MESH_DESCRIPTION_FLAG_HAS_SOURCE_PATH

	bytes.encode_s32(base + 0, int(description.get("asset_index", 0)))
	bytes.encode_s32(base + 4, int(description.get("profile_id", -1)))
	bytes.encode_s32(base + 8, flags)
	bytes.encode_s32(base + 12, int(description.get("mesh_surface_count", 0)))
	bytes.encode_s32(base + 16, int(description.get("source_mesh_surface_count", 0)))
	bytes.encode_s32(base + 20, 0)
	bytes.encode_s32(base + 24, 0)
	bytes.encode_s32(base + 28, 0)
	_encode_aabb(bytes, base + 32, mesh_aabb)
	_encode_aabb(bytes, base + 64, source_mesh_aabb)
	bytes.encode_u32(base + 96, HashUtils.stable_u32_from_string(str(description.get("asset_name", ""))))
	bytes.encode_u32(base + 100, HashUtils.stable_u32_from_string(str(description.get("object_type", ""))))
	bytes.encode_u32(base + 104, HashUtils.stable_u32_from_string(str(description.get("object_subtype", ""))))
	bytes.encode_u32(base + 108, HashUtils.stable_u32_from_string(source_path))
	bytes.encode_float(base + 112, mesh_aabb.size.length())
	bytes.encode_float(base + 116, maxf(mesh_aabb.size.x, maxf(mesh_aabb.size.y, mesh_aabb.size.z)))
	bytes.encode_float(base + 120, source_mesh_aabb.size.length())
	bytes.encode_float(base + 124, maxf(source_mesh_aabb.size.x, maxf(source_mesh_aabb.size.y, source_mesh_aabb.size.z)))


static func _encode_aabb(bytes: PackedByteArray, base: int, aabb: AABB) -> void:
	BufferUtils.encode_vec4(bytes, base + 0, aabb.position, 0.0)
	BufferUtils.encode_vec4(bytes, base + 16, aabb.size, 0.0)


static func _decode_mesh_description_bytes(bytes: PackedByteArray, record_count: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var available_bytes := mini(bytes.size(), record_count * MESH_DESCRIPTION_STRIDE_BYTES)
	available_bytes -= available_bytes % MESH_DESCRIPTION_STRIDE_BYTES
	var available := mini(record_count, int(available_bytes / MESH_DESCRIPTION_STRIDE_BYTES))
	for i in range(available):
		var base := i * MESH_DESCRIPTION_STRIDE_BYTES
		var mesh_aabb := AABB(
			BufferUtils.decode_vec4_xyz(bytes, base + 32),
			BufferUtils.decode_vec4_xyz(bytes, base + 48)
		)
		var source_mesh_aabb := AABB(
			BufferUtils.decode_vec4_xyz(bytes, base + 64),
			BufferUtils.decode_vec4_xyz(bytes, base + 80)
		)
		result.append({
			"asset_index": bytes.decode_s32(base + 0),
			"profile_id": bytes.decode_s32(base + 4),
			"flags": bytes.decode_s32(base + 8),
			"mesh_surface_count": bytes.decode_s32(base + 12),
			"source_mesh_surface_count": bytes.decode_s32(base + 16),
			"mesh_aabb": mesh_aabb,
			"source_mesh_aabb": source_mesh_aabb,
			"asset_name_hash": int(bytes.decode_u32(base + 96)),
			"object_type_hash": int(bytes.decode_u32(base + 100)),
			"object_subtype_hash": int(bytes.decode_u32(base + 104)),
			"source_mesh_path_hash": int(bytes.decode_u32(base + 108)),
			"mesh_diagonal": bytes.decode_float(base + 112),
			"mesh_max_axis": bytes.decode_float(base + 116),
			"source_mesh_diagonal": bytes.decode_float(base + 120),
			"source_mesh_max_axis": bytes.decode_float(base + 124),
		})
	return result


# --------------------------------------------------------------------------
# 笔刷 SV 持久化元数据
# --------------------------------------------------------------------------

## 写入笔刷 SV 持久化控制元数据（commit_mode/auto_commit 等）；由笔刷工具在开始 paint 前调用
func set_brush_sv_persistence_metadata(metadata: Dictionary) -> Dictionary:
	var clean := _brush_sv_control_metadata_from(metadata)
	clean["owner"] = "ScenePlacementActor"
	clean["control_plane_only"] = true
	clean["content_mirror"] = false
	_brush_sv_control_metadata = clean
	return get_brush_sv_persistence_metadata()


## 更新笔刷 SV 生命周期状态字段（active/committed/idle 等）及可选脏键；由笔刷 paint/commit 流程各阶段调用
func update_brush_sv_lifecycle_state(state: String, dirty: bool = false, dirty_keys: Array = []) -> Dictionary:
	if _brush_sv_control_metadata.is_empty():
		_brush_sv_control_metadata = {
			"owner": "ScenePlacementActor",
			"control_plane_only": true,
			"content_mirror": false,
		}
	_brush_sv_control_metadata["lifecycle_state"] = state
	_brush_sv_control_metadata["dirty"] = dirty
	if not dirty_keys.is_empty():
		_brush_sv_control_metadata["dirty_keys"] = dirty_keys.duplicate()
	return get_brush_sv_persistence_metadata()


## 返回当前笔刷 SV 持久化控制元数据副本；由 run_placement_pipeline 读取 commit_mode 时调用
func get_brush_sv_persistence_metadata() -> Dictionary:
	return _brush_sv_control_metadata.duplicate(true)


## 清除笔刷 SV 元数据并重置生命周期状态；由笔刷工具结束或重置时调用
func clear_brush_sv_persistence_metadata() -> void:
	_brush_sv_control_metadata.clear()


static func _brush_sv_control_metadata_from(metadata: Dictionary) -> Dictionary:
	var result := {}
	for raw_key in metadata.keys():
		var key := str(raw_key)
		if _is_brush_sv_content_key(key):
			continue
		var value = metadata[raw_key]
		if _is_brush_sv_content_value(value):
			continue
		result[key] = _sanitize_brush_sv_control_value(value)
	return result


static func _sanitize_brush_sv_control_value(value):
	if value is Dictionary:
		return _brush_sv_control_metadata_from(value as Dictionary)
	if value is Array:
		return _sanitize_brush_sv_control_array(value as Array)
	return value


static func _sanitize_brush_sv_control_array(values: Array) -> Array:
	var result := []
	for value in values:
		if _is_brush_sv_content_value(value):
			continue
		result.append(_sanitize_brush_sv_control_value(value))
	return result


static func _is_brush_sv_content_key(key: String) -> bool:
	var lowered := key.to_lower()
	return lowered == "content" \
		or lowered == "payload" \
		or lowered == "image" \
		or lowered == "preview_image" \
		or lowered == "complexity_field" \
		or lowered == "collision_field" \
		or lowered == "target_color" \
		or lowered == "scene_voxels" \
		or lowered == "auto_scene_voxel_sources" \
		or lowered == "brush_scene_voxel_sources" \
		or lowered == "auto_sv" \
		or lowered == "brush_sv" \
		or lowered.ends_with("_bytes")


static func _is_brush_sv_content_value(value) -> bool:
	return value is PackedByteArray \
		or value is PackedFloat32Array \
		or value is PackedInt32Array \
		or value is PackedVector2Array \
		or value is PackedVector3Array \
		or value is PackedColorArray \
		or value is Image


# --------------------------------------------------------------------------
# AutoObject Runtime 动作
# --------------------------------------------------------------------------

## 将已接受放置记录批量生成 AutoObject GPU 状态（spawn pass）；由外部在 pipeline 外手动 spawn 时调用
func spawn_autoobject_batch_from_accepted_placement_records(
	spawn_records: Array[Dictionary],
	options: Dictionary = {}
) -> Dictionary:
	if not is_initialized():
		return _autoobject_runtime_action_error("actor_not_initialized", "spawn_batch_from_accepted_placement_records")
	if _gpu_runtime == null:
		_ensure_owned_gpu_runtime()
	if _sv_committer != null:
		_ensure_gpu_runtime_for_scene_voxel_committer()
	if _gpu_runtime == null or not _gpu_runtime.is_ready():
		return _autoobject_runtime_action_error("gpu_autoobject_runtime_not_ready", "spawn_batch_from_accepted_placement_records")
	var result: Dictionary = _gpu_runtime.spawn_batch_from_accepted_placement_records(
		spawn_records,
		options.duplicate(true)
	)
	_annotate_autoobject_runtime_action_result(result, "spawn_batch_from_accepted_placement_records")
	result["record_count"] = spawn_records.size()
	return result


## 将 gpu_runtime 当前对象状态 flush 写入 SceneVoxelCommitter；由外部或 pipeline 完成放置后同步 SV 时调用
func flush_autoobject_runtime_to_scene_voxel_committer(options: Dictionary = {}) -> Dictionary:
	if not is_initialized():
		return _autoobject_runtime_action_error("actor_not_initialized", "flush_to_scene_voxel_committer")
	if _gpu_runtime == null:
		_ensure_owned_gpu_runtime()
	if _sv_committer == null:
		return _autoobject_runtime_action_error("missing_scene_voxel_committer", "flush_to_scene_voxel_committer")
	var setup_result := _ensure_gpu_runtime_for_scene_voxel_committer()
	if _gpu_runtime == null or not _gpu_runtime.is_ready():
		return _autoobject_runtime_action_error("gpu_autoobject_runtime_not_ready", "flush_to_scene_voxel_committer")
	if bool(setup_result.get("blocked", false)):
		return _autoobject_runtime_action_error(
			str(setup_result.get("blocked_reason", setup_result.get("reason", "runtime_scene_voxel_setup_blocked"))),
			"flush_to_scene_voxel_committer"
		)
	var result: Dictionary = _gpu_runtime.flush_to_scene_voxel_committer(_tile_store, options.duplicate(true))
	_annotate_autoobject_runtime_action_result(result, "flush_to_scene_voxel_committer")
	result["runtime_setup"] = setup_result.duplicate(true)
	return result


## 构造标准化的 autoobject runtime 动作失败报告字典（含 reason/action/gpu_first 等）；由各 spawn/flush 入口的错误路径调用
func _autoobject_runtime_action_error(reason: String, action: String) -> Dictionary:
	return {
		"ok": false,
		"reason": reason,
		"blocked": true,
		"blocked_reason": reason,
		"source": "ScenePlacementActor",
		"owner": "ScenePlacementActor",
		"control_plane": "ScenePlacementActor",
		"runtime_action": action,
		"lifecycle_owner": "ScenePlacementActor",
		"runtime_ready": _gpu_runtime != null and _gpu_runtime.is_ready(),
		"runtime_setup": _gpu_runtime_scene_voxel_setup_result.duplicate(true),
		"gpu_first": true,
		"cpu_fallback": false,
	}


## 向 runtime 动作结果字典追加 SPA 元数据标注（action 名称、RD 状态、profile 状态等）；由 spawn/flush 成功路径调用
func _annotate_autoobject_runtime_action_result(result: Dictionary, action: String) -> Dictionary:
	result["source"] = "ScenePlacementActor"
	result["owner"] = "ScenePlacementActor"
	result["control_plane"] = "ScenePlacementActor"
	result["runtime_action"] = action
	result["lifecycle_owner"] = "ScenePlacementActor"
	result["runtime_ready"] = _gpu_runtime != null and _gpu_runtime.is_ready()
	if not result.has("runtime_setup"):
		result["runtime_setup"] = _gpu_runtime_scene_voxel_setup_result.duplicate(true)
	if not result.has("gpu_first"):
		result["gpu_first"] = true
	if not result.has("cpu_fallback"):
		result["cpu_fallback"] = false
	return result


## 向 gpu_runtime 传递 SV committer 的 GPU buffer RID（tile records/summaries/dirty_indices 等）；由 attach_sv_committer 和 pipeline 前调用
func _ensure_gpu_runtime_for_scene_voxel_committer() -> Dictionary:
	if _gpu_runtime == null:
		_ensure_owned_gpu_runtime()
	if _gpu_runtime == null:
		push_error("ScenePlacementActor._ensure_gpu_runtime_for_scene_voxel_committer: _ensure_owned_gpu_runtime 之后 gpu_runtime 仍为 null（capacity=%d）——AutoObject GPU 状态组件创建失败。" % _autoobject_runtime_capacity)
		assert(false, "ScenePlacementActor: owned GPUAutoObjectRuntime creation failed")
		_gpu_runtime_scene_voxel_setup_result = _gpu_runtime_scene_voxel_setup_blocked("missing_autoobject_gpu_state")
		return _gpu_runtime_scene_voxel_setup_result
	if _sv_committer == null:
		_gpu_runtime_scene_voxel_setup_result = _gpu_runtime_scene_voxel_setup_blocked("missing_scene_voxel_committer")
		return _gpu_runtime_scene_voxel_setup_result
	if not _gpu_runtime.has_method("setup_for_scene_voxel_committer"):
		push_error("ScenePlacementActor._ensure_gpu_runtime_for_scene_voxel_committer: gpu_runtime 缺少 setup_for_scene_voxel_committer()（type=%s）——SV 缓冲无法交接，dirty delta 通道整条断掉。" % str(_gpu_runtime.get_class()))
		assert(false, "ScenePlacementActor: gpu_runtime has no setup_for_scene_voxel_committer()")
		_gpu_runtime_scene_voxel_setup_result = _gpu_runtime_scene_voxel_setup_blocked("missing_runtime_scene_voxel_setup_helper")
		return _gpu_runtime_scene_voxel_setup_result

	var runtime_rd := GodotComputeShaderBase.rendering_device_of(_gpu_runtime)
	var committer_rd := GodotComputeShaderBase.rendering_device_of(_sv_committer)
	if runtime_rd != null \
			and committer_rd != null \
			and runtime_rd == committer_rd \
			and _gpu_runtime.is_ready() \
			and bool(_gpu_runtime_scene_voxel_setup_result.get("resident_gpu_dirty_delta_update_pass_opt_in_ready", false)):
		_gpu_runtime_scene_voxel_setup_result["ok"] = true
		_gpu_runtime_scene_voxel_setup_result["reason"] = "ok"
		_gpu_runtime_scene_voxel_setup_result["runtime_ready"] = true
		_gpu_runtime_scene_voxel_setup_result["same_rendering_device"] = true
		_gpu_runtime_scene_voxel_setup_result["blocked"] = false
		_gpu_runtime_scene_voxel_setup_result["blocked_reason"] = "none"
		_gpu_runtime_scene_voxel_setup_result["source"] = "ScenePlacementActor"
		_gpu_runtime_scene_voxel_setup_result["owner"] = "ScenePlacementActor"
		_gpu_runtime_scene_voxel_setup_result["lifecycle_owner"] = "ScenePlacementActor"
		_gpu_runtime_scene_voxel_setup_result["runtime_setup_api"] = "GPUAutoObjectRuntime.setup_for_scene_voxel_committer"
		return _gpu_runtime_scene_voxel_setup_result

	var setup_result: Dictionary = _gpu_runtime.setup_for_scene_voxel_committer(
		_sv_committer,
		_gpu_runtime.max_objects,
		true
	)
	setup_result["source"] = "ScenePlacementActor"
	setup_result["owner"] = "ScenePlacementActor"
	setup_result["lifecycle_owner"] = "ScenePlacementActor"
	setup_result["runtime_setup_api"] = "GPUAutoObjectRuntime.setup_for_scene_voxel_committer"
	setup_result["resident_gpu_dirty_delta_update_pass_opt_in_ready"] = bool(setup_result.get("ok", false)) \
		and bool(setup_result.get("same_rendering_device", false)) \
		and bool(setup_result.get("runtime_ready", false))
	if not bool(setup_result.get("ok", false)):
		setup_result["blocked"] = true
		setup_result["blocked_reason"] = str(setup_result.get("reason", "runtime_scene_voxel_setup_failed"))
	else:
		setup_result["blocked"] = false
		setup_result["blocked_reason"] = "none"
	_gpu_runtime_scene_voxel_setup_result = setup_result
	return _gpu_runtime_scene_voxel_setup_result


## 构造 gpu_runtime SV 配置被阻断的错误报告字典；由 _ensure_gpu_runtime_for_scene_voxel_committer 发现缺失 buffer 时调用
func _gpu_runtime_scene_voxel_setup_blocked(reason: String) -> Dictionary:
	return {
		"ok": false,
		"reason": reason,
		"blocked": true,
		"blocked_reason": reason,
		"source": "ScenePlacementActor",
		"owner": "ScenePlacementActor",
		"lifecycle_owner": "ScenePlacementActor",
		"runtime_setup_api": "GPUAutoObjectRuntime.setup_for_scene_voxel_committer",
		"runtime_ready": false,
		"gpu_first": true,
		"cpu_fallback": false,
		"readback_source": "none",
		"rendering_device_source": "none",
		"same_rendering_device": false,
		"resident_gpu_dirty_delta_update_pass_opt_in_ready": false,
	}


## 从 placement 结果读取 dirty delta 并调用 SV committer 更新 tile object_ref 缓冲；由 _commit_accepted_placements 调用
func _flush_gpu_runtime_dirty_delta_to_scene_voxel_committer(placement_result: Dictionary) -> Dictionary:
	var result := {
		"ok": false,
		"reason": "not_attempted",
		"blocked": true,
		"blocked_reason": "not_attempted",
		"source": "ScenePlacementActor",
		"owner": "ScenePlacementActor",
		"runtime_flush_api": "GPUAutoObjectRuntime.flush_to_scene_voxel_committer",
		"runtime_setup": _gpu_runtime_scene_voxel_setup_result.duplicate(true),
		"runtime_ready": false,
		"gpu_first": true,
		"cpu_fallback": false,
		"readback_source": "none",
		"failed_readback_source": "none",
		"dirty_delta_count": 0,
		"pending_dirty_delta_count": 0,
		"dirty_delta_bridge_mode": "none",
		"dirty_delta_apply_api": "none",
		"resident_gpu_dirty_delta_update_pass": false,
		"resident_gpu_dirty_delta_update_pass_owner": "none",
		"resident_gpu_dirty_delta_update_pass_shader": "none",
		"resident_gpu_dirty_delta_update_pass_dispatch_count": 0,
		"resident_gpu_dirty_delta_update_pass_blocked_reason": "not_attempted",
	}
	if _gpu_runtime == null:
		result["reason"] = "missing_autoobject_gpu_state"
		result["blocked_reason"] = "missing_autoobject_gpu_state"
		result["resident_gpu_dirty_delta_update_pass_blocked_reason"] = "missing_autoobject_gpu_state"
		return result
	if _sv_committer == null:
		result["reason"] = "missing_scene_voxel_committer"
		result["blocked_reason"] = "missing_scene_voxel_committer"
		result["resident_gpu_dirty_delta_update_pass_blocked_reason"] = "missing_scene_voxel_committer"
		return result
	# ⚠ 默认值必须是 true：`ok` **缺席即成功**。VPG 的成功变体按
	# `ReportSchema.VPG_MULTI_ASSET_REPORT` 的约定刻意不发 `ok`（只有 contract-blocked
	# 变体才显式发 `ok: false`），VPG 自己读契约时也是这个写法（`gpu_contract.get("ok", true)`）。
	# 这里原本写的是 `get("ok", false)`，于是**每一次成功放置**都判死 ⇒ tile object_ref 更新
	# pass（`scene_voxel_tile_object_ref_update.glsl`）在生产 Place 路径上从未跑过，
	# 表现是「放了 5410 个 autoobject，SVTile 热力图 0 occupied tile / 0 refs per tile」。
	# ⚠ 修的是**读侧默认值**，不是让 VPG 补发 `ok`：补发会连带打开 `_commit_accepted_placements`
	# 那道同款门（run_placement_pipeline 里 `_sv_committer != null and placement_result.ok`），
	# 那是语义更重的「提交」路径（推 tick、散射 pending CPU 记录），不在本次范围内。
	if not bool(placement_result.get("ok", true)):
		result["reason"] = "placement_not_ok"
		result["blocked_reason"] = "placement_not_ok"
		result["resident_gpu_dirty_delta_update_pass_blocked_reason"] = "placement_not_ok"
		result["runtime_ready"] = _gpu_runtime.is_ready()
		return result

	var setup_result := _ensure_gpu_runtime_for_scene_voxel_committer()
	result["runtime_setup"] = setup_result.duplicate(true)
	result["runtime_ready"] = _gpu_runtime.is_ready()
	if not bool(setup_result.get("resident_gpu_dirty_delta_update_pass_opt_in_ready", false)):
		var setup_reason := str(setup_result.get("blocked_reason", setup_result.get("reason", "runtime_scene_voxel_setup_blocked")))
		result["reason"] = setup_reason
		result["blocked_reason"] = setup_reason
		result["resident_gpu_dirty_delta_update_pass_blocked_reason"] = setup_reason
		if _gpu_runtime.has_method("get_pending_dirty_delta_count"):
			result["pending_dirty_delta_count"] = int(_gpu_runtime.get_pending_dirty_delta_count())
		return result

	# resident GPU dirty delta update pass 是唯一路径，无需显式 opt-in。
	var flush_result: Dictionary = _gpu_runtime.flush_to_scene_voxel_committer(_tile_store, {})
	flush_result["source"] = "ScenePlacementActor"
	flush_result["owner"] = "ScenePlacementActor"
	flush_result["runtime_flush_api"] = "GPUAutoObjectRuntime.flush_to_scene_voxel_committer"
	flush_result["runtime_setup"] = setup_result.duplicate(true)
	if bool(flush_result.get("resident_gpu_dirty_delta_update_pass", false)) \
			and bool(flush_result.get("ok", false)) \
			and int(flush_result.get("resident_gpu_dirty_delta_update_pass_dispatch_count", 0)) > 0:
		flush_result["blocked"] = false
		flush_result["blocked_reason"] = "none"
		flush_result["resident_gpu_dirty_delta_update_pass_blocked_reason"] = "none"
	else:
		var blocked_reason := str(flush_result.get(
			"resident_gpu_dirty_delta_update_pass_blocked_reason",
			flush_result.get("reason", "resident_dirty_delta_update_pass_not_dispatched")
		))
		flush_result["blocked"] = true
		flush_result["blocked_reason"] = blocked_reason
		flush_result["resident_gpu_dirty_delta_update_pass_blocked_reason"] = blocked_reason
	return flush_result



# --------------------------------------------------------------------------
# Placement Pipeline
# --------------------------------------------------------------------------

## 单独执行 prefilter 阶段（SV→resident anchor handoff）并返回结果；由外部拆分 pipeline 阶段时调用
func run_autoobject_prefilter(
	sv: Dictionary,
	target_read_buffers: Dictionary = {},
	prefilter_settings: Dictionary = {}
) -> Dictionary:
	if not is_initialized():
		return _pipeline_error("actor_not_initialized")
	if _registered_descriptors.is_empty():
		return _pipeline_error("no_registered_assets")
	var prefilter := _get_prefilter()
	_apply_prefilter_settings(prefilter, prefilter_settings)
	var autoobjects := _build_autoobject_array_for_pipeline()
	if autoobjects.size() != _registered_descriptors.size():
		push_error("ScenePlacementActor.run_autoobject_prefilter: AutoObject 视图数量与注册表不符（views=%d, assets=%d）——构建失败详情见上一条错误。" % [
			autoobjects.size(), _registered_descriptors.size()])
		assert(false, "ScenePlacementActor.run_autoobject_prefilter: autoobject view count mismatch")
		return _pipeline_error("autoobject_view_build_failed")
	var dirty_handoff := _tile_store.get_dirty_worklist_handoff() if _tile_store != null else {
		"ok": false,
		"reason": "scene_voxel_tile_store_unavailable",
	}
	var result := prefilter.run_probe_prefilter(
		sv,
		autoobjects,
		dirty_handoff,
		_runtime_profile_container,
		target_read_buffers.duplicate()
	)
	if bool(result.get("ok", false)) and _tile_store != null:
		result["dirty_finalize_ok"] = _tile_store.finalize_consumed_dirty_tiles()
	result["dirty_worklist_handoff"] = {
		"ok": bool(dirty_handoff.get("ok", false)),
		"dirty_epoch": int(dirty_handoff.get("dirty_epoch", -1)),
		"dirty_tile_capacity": int(dirty_handoff.get("dirty_tile_capacity", 0)),
		"cpu_fallback": false,
	}
	result["control_plane"] = "ScenePlacementActor"
	result["asset_registry_owner"] = "ScenePlacementActor"
	result["runtime_profile_container_owner"] = "ScenePlacementActor"
	result["asset_count"] = _registered_descriptors.size()
	return result


## 将 settings 字典的参数写入 prefilter 实例；由 run_autoobject_prefilter 调用。
## anchor top-K 是固定 GPU 契约（prefilter TOPK=16，端到端 stride 绑定），不在此配置。
## ⚠ `min_prefilter_score` 当前透传但 shader 忽略——粗筛暂停淘汰（2026-08-10 裁决，
## 说明见 `shaders/select_anchor_topk.glsl` 文件头）。
func _apply_prefilter_settings(prefilter: AutoObjectProbePrefilterGPU, settings: Dictionary) -> void:
	if prefilter == null:
		return
	if settings.has("min_target_interest"):
		prefilter.min_target_interest = clampf(float(settings.get("min_target_interest", prefilter.min_target_interest)), 0.0, 1.0)
	# 竖直采样步长：0 = 只采地形那一格（默认），负值按 0 处理；> 0 时在地表之上按步长加层，不设上限。
	if settings.has("anchor_vertical_stride"):
		prefilter.anchor_vertical_stride = maxi(int(settings.get("anchor_vertical_stride", prefilter.anchor_vertical_stride)), 0)
	if settings.has("min_prefilter_score"):
		prefilter.min_prefilter_score = clampf(float(settings.get("min_prefilter_score", prefilter.min_prefilter_score)), 0.0, 1.0)
	if settings.has("debug_read_anchors"):
		prefilter.debug_read_anchors = bool(settings.get("debug_read_anchors", prefilter.debug_read_anchors))
	# Dictionary 解码是兼容路径；未显式传参时恢复 true，避免实例复用导致调试调用继承
	# 上一次 Score 的 packed-only 设置。
	prefilter.decode_anchor_dictionaries = bool(settings.get("decode_anchor_dictionaries", true))
	# Profiling inserts submit+sync boundaries and must never leak into a later normal run.
	prefilter.profile_timing = bool(settings.get("profile_timing", false))


# ---------------------------------------------------------------------------
# Pipeline — the main orchestration entry point
# ---------------------------------------------------------------------------

## Run the full placement pipeline for one frame.
##
## Parameters:
##   sv: Dictionary       — SceneVoxel metadata (grid_size, voxel_size,
##                           complexity_field, collision_field, tile_grid_size, ...)
##   dirty_tile_ids: Array[int]            — dirty tile indices for this frame
##   placement_common: Dictionary = {}     — must include packed TargetSV_B bytes
##
## Per-anchor asset top-K is a fixed GPU contract (AutoObjectProbePrefilterGPU.TOPK
## = 16): buffer strides, the select shader and the fine-score dispatch are sized
## by it end-to-end, so it is intentionally not configurable.
##
## Returns a Dictionary with:
##   prefilter_result, placement_result, commit_result, profile_probe_pack_summary
## 执行完整 placement pipeline（prefilter→placement→可选 commit）并返回详细结果；SPA 的核心入口，由外部 cook 路径调用
func run_placement_pipeline(
	sv: Dictionary,
	placement_common: Dictionary = {}
) -> Dictionary:
	if not is_initialized():
		return _pipeline_error("actor_not_initialized")
	if _registered_descriptors.is_empty():
		return _pipeline_error("no_registered_assets")
	# SV 字典契约：committer 发布的 SV 必带 grid_size / voxel_size / grid_origin。旧行为
	# 在下游用 sv.get(key, 默认值) 兜底 → 缺键就等于在零网格 / 单位体素 / 原点为零的
	# 假坐标系上跑完整条放置管线，产出的实例位置全是脏数据。
	for required_sv_key in ["grid_size", "voxel_size", "grid_origin"]:
		if not sv.has(required_sv_key):
			push_error("ScenePlacementActor.run_placement_pipeline: sv 缺少必备键 \"%s\"（sv keys=%s）——补默认值会让整条管线在假网格上跑。" % [
				required_sv_key, str(sv.keys())])
			assert(false, "ScenePlacementActor.run_placement_pipeline: sv missing required key")
			return _pipeline_error("sv_missing_key_%s" % required_sv_key)
	var sv_grid_size: Vector3i = sv["grid_size"]
	if VoxelGeneral.voxel_count(sv_grid_size) <= 0:
		push_error("ScenePlacementActor.run_placement_pipeline: sv.grid_size 非法（grid_size=%s, voxel_count=%d）。" % [
			str(sv_grid_size), VoxelGeneral.voxel_count(sv_grid_size)])
		assert(false, "ScenePlacementActor.run_placement_pipeline: invalid sv grid_size")
		return _pipeline_error("sv_invalid_grid_size")
	var pipeline_t0_usec := Time.get_ticks_usec()
	var phase_t0_usec := pipeline_t0_usec
	var resident_pipeline_phases_ms := {}

	# ---- Phase 0: resident field handoff + BlendSV 合成（SV 纯 auto；读取场按需叠加 brush） ----

	# _rebuild_sv 收尾的 clear_all_dirty 会把 tile staging 重新标脏；handoff 前幂等确保上传就绪
	if _tile_store != null:
		_tile_store.ensure_scene_voxel_tile_buffers_uploaded(false)
	resident_pipeline_phases_ms["tile_ensure"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	phase_t0_usec = Time.get_ticks_usec()
	var resident_field_handoff := build_resident_complexity_field_handoff(sv)
	resident_pipeline_phases_ms["resident_handoff"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	phase_t0_usec = Time.get_ticks_usec()
	var resident_complexity_field_rid: RID = resident_field_handoff.get("complexity_field_buffer_rid", RID())
	var resident_collision_field_rid: RID = resident_field_handoff.get("collision_field_buffer_rid", RID())

	# resident-or-error：有 committer 时常驻 complexity/collision 场就是权威来源，拿不到它
	# （未就绪 / stride/format/device 失配 / 过期）是真·错误。旧行为静默退回 CPU 数组，而 committer
	# 路径下调用方并不往 sv 里喂 CPU 场 → 那实际是在“零场”上跑放置（静默垃圾）。这里改为硬失败。
	# 无 committer 时保留 CPU 数组接口（调用方自带 SV 场，见 scene-placement-actor.md）。
	if _sv_committer != null and not bool(resident_field_handoff.get("ok", false)):
		push_error("ScenePlacementActor: committer present but resident complexity/collision field handoff unavailable: %s" % str(resident_field_handoff.get("reason", "unknown")))
		_last_pipeline_result = {
			"ok": false,
			"phase": "resident_complexity_field_handoff",
			"resident_complexity_field_handoff": resident_field_handoff,
			"scene_voxel_tile_resident_field_handoff": resident_field_handoff,
			"profile_probe_pack": {},
			"mesh_description": get_mesh_description_gpu_buffer_summary(),
			"accepted_placement_writeback_summary": _accepted_placement_writeback_summary_from_placement({}),
		}
		return _last_pipeline_result

	# 读取场（prefilter / target prep / 3D score 采样）：有 brush 内容时为 BlendSV 临时对，
	# 否则直通 committed SV 常驻对；commit 目标恒为 SV 对（stamp 双写由 VPG flag 控制）。
	var field_read_complexity_rid := resident_complexity_field_rid
	var field_read_collision_rid := resident_collision_field_rid
	var blend_sv_active := false
	if bool(resident_field_handoff.get("ok", false)) and has_brush_sv_content():
		var blend := compose_blend_sv_fields(resident_complexity_field_rid, resident_collision_field_rid)
		if blend.is_empty():
			# 旧行为静默退回 committed SV 直通 —— 用户画过的 BrushSV 内容凭空消失，
			# 打分/放置照跑，结果与“没画过”无法区分。改为硬失败。
			push_error("ScenePlacementActor.run_placement_pipeline: BrushSV 有内容但 BlendSV 合成失败（brush_revision=%d, brush_voxel_count=%d）——继续跑等于静默丢掉笔刷内容。" % [
				_brush_sv_revision, _brush_sv_voxel_count()])
			assert(false, "ScenePlacementActor.run_placement_pipeline: blend sv compose failed")
			_last_pipeline_result = {
				"ok": false,
				"phase": "blend_sv_compose",
				"reason": "blend_sv_compose_failed",
				"resident_complexity_field_handoff": resident_field_handoff,
				"scene_voxel_tile_resident_field_handoff": resident_field_handoff,
				"profile_probe_pack": {},
				"mesh_description": get_mesh_description_gpu_buffer_summary(),
				"accepted_placement_writeback_summary": _accepted_placement_writeback_summary_from_placement({}),
			}
			return _last_pipeline_result
		field_read_complexity_rid = blend.get("complexity_field_buffer", RID())
		field_read_collision_rid = blend.get("collision_field_buffer", RID())
		blend_sv_active = true

	sv = sv.duplicate()
	if field_read_complexity_rid.is_valid() and field_read_collision_rid.is_valid():
		sv["resident_complexity_field_read_rid"] = field_read_complexity_rid
		sv["resident_collision_field_read_rid"] = field_read_collision_rid
	resident_pipeline_phases_ms["read_field_handoff"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	phase_t0_usec = Time.get_ticks_usec()

	# ---- Prefilter (SV → resident anchor handoff: anchors + per-anchor top-K) ----

	var autoobjects := _build_autoobject_array_for_pipeline()
	if autoobjects.size() != _registered_descriptors.size():
		# 视图构建已在内部报错并硬失败；这里不能揣着一份残缺的资产视图继续跑 prefilter。
		push_error("ScenePlacementActor.run_placement_pipeline: AutoObject 视图数量与注册表不符（views=%d, assets=%d）。" % [
			autoobjects.size(), _registered_descriptors.size()])
		assert(false, "ScenePlacementActor.run_placement_pipeline: autoobject view count mismatch")
		if blend_sv_active:
			release_blend_sv_fields()
		return _pipeline_error("autoobject_view_build_failed")
	resident_pipeline_phases_ms["autoobject_views"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	phase_t0_usec = Time.get_ticks_usec()
	var target_buffers := prepare_target_read_buffers_from_common_gpu(placement_common, sv)
	resident_pipeline_phases_ms["target_prepare"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	phase_t0_usec = Time.get_ticks_usec()
	if not bool(target_buffers.get("ok", false)):
		_last_pipeline_result = {
			"ok": false,
			"phase": "target_read_buffers",
			"target_read_buffers": target_buffers,
			"profile_probe_pack": {},
			"mesh_description": get_mesh_description_gpu_buffer_summary(),
			"accepted_placement_writeback_summary": _accepted_placement_writeback_summary_from_placement({}),
		}
		if blend_sv_active:
			release_blend_sv_fields()
		return _last_pipeline_result
	var target_field_bytes: PackedFloat32Array = target_buffers.get("target_field_bytes", PackedFloat32Array())
	var mesh_description_summary := get_mesh_description_gpu_buffer_summary()

	var prefilter := _get_prefilter()
	# 尊重调用方在 placement_common 里给出的 prefilter 门限（min_target_interest /
	# min_prefilter_score）——键缺省即 no-op（run_autoobject_prefilter 已在自己入口应用；
	# 生产 SPA demo/检查的 placement_common 不含这些键，行为不变）。
	_apply_prefilter_settings(prefilter, placement_common)
	resident_pipeline_phases_ms["prefilter_setup"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	phase_t0_usec = Time.get_ticks_usec()

	var dirty_handoff := _tile_store.get_dirty_worklist_handoff() if _tile_store != null else {
		"ok": false,
		"reason": "scene_voxel_tile_store_unavailable",
	}
	var prefilter_result := prefilter.run_probe_prefilter(
		sv,
		autoobjects,
		dirty_handoff,
		_runtime_profile_container,  # ← borrowed GPU probes
		target_buffers
	)
	if bool(prefilter_result.get("ok", false)) and _tile_store != null:
		prefilter_result["dirty_finalize_ok"] = _tile_store.finalize_consumed_dirty_tiles()
	resident_pipeline_phases_ms["prefilter"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	phase_t0_usec = Time.get_ticks_usec()

	if not bool(prefilter_result.get("ok", false)):
		_last_pipeline_result = {
			"ok": false,
			"phase": "prefilter",
			"prefilter_result": prefilter_result,
			"profile_probe_pack": prefilter_result.get("profile_probe_pack", {}),
			"mesh_description": mesh_description_summary,
			"accepted_placement_writeback_summary": _accepted_placement_writeback_summary_from_placement({}),
		}
		if blend_sv_active:
			release_blend_sv_fields()
		return _last_pipeline_result

	var anchor_candidate_handoff: Dictionary = prefilter_result.get("anchor_candidate_handoff", {})
	if not _anchor_candidate_handoff_ready(anchor_candidate_handoff, prefilter):
		_last_pipeline_result = {
			"ok": false,
			"phase": "anchor_candidate_handoff",
			"prefilter_result": prefilter_result,
			"anchor_candidate_handoff": _anchor_candidate_handoff_summary(anchor_candidate_handoff, false),
			"profile_probe_pack": prefilter_result.get("profile_probe_pack", {}),
			"mesh_description": mesh_description_summary,
			"accepted_placement_writeback_summary": _accepted_placement_writeback_summary_from_placement({}),
		}
		if blend_sv_active:
			release_blend_sv_fields()
		return _last_pipeline_result

	# ---- Phase 1: Placement (candidate regions → placed instances) ----

	var placer := _get_placer()

	var sv_voxel_count := VoxelGeneral.voxel_count(sv_grid_size)
	var complexity_field := PackedFloat32Array()
	var collision_field := PackedFloat32Array()
	if not bool(resident_field_handoff.get("ok", false)):
		# 无常驻场时（无 committer 的 CPU 数组接口）调用方必须自带整场；旧行为
		# pad_float_array 会把缺失/过短的场静默补零 —— 那是在“零场”上跑放置。
		var cpu_complexity_field: PackedFloat32Array = sv.get("complexity_field", PackedFloat32Array())
		var cpu_collision_field: PackedFloat32Array = sv.get("collision_field", PackedFloat32Array())
		if cpu_complexity_field.size() != sv_voxel_count or cpu_collision_field.size() != sv_voxel_count:
			push_error("ScenePlacementActor.run_placement_pipeline: 无常驻场且 CPU 场尺寸不符（expected=%d, complexity_field=%d, collision_field=%d, grid_size=%s）——补零等于在空场上放置。" % [
				sv_voxel_count, cpu_complexity_field.size(), cpu_collision_field.size(), str(sv_grid_size)])
			assert(false, "ScenePlacementActor.run_placement_pipeline: cpu field size mismatch")
			_last_pipeline_result = {
				"ok": false,
				"phase": "cpu_field_input",
				"reason": "cpu_field_size_mismatch",
				"expected_voxel_count": sv_voxel_count,
				"complexity_field_size": cpu_complexity_field.size(),
				"collision_field_size": cpu_collision_field.size(),
				"profile_probe_pack": prefilter_result.get("profile_probe_pack", {}),
				"mesh_description": mesh_description_summary,
				"accepted_placement_writeback_summary": _accepted_placement_writeback_summary_from_placement({}),
			}
			return _last_pipeline_result
		complexity_field = cpu_complexity_field
		collision_field = cpu_collision_field

	var asset_defs := _build_placement_asset_defs()
	if asset_defs.size() != _registered_descriptors.size():
		# def 构建已在内部报错并硬失败；带着残缺的 def 列表跑 VPG 会静默少放一批资产。
		push_error("ScenePlacementActor.run_placement_pipeline: placement asset def 数量与注册表不符（defs=%d, assets=%d）。" % [
			asset_defs.size(), _registered_descriptors.size()])
		assert(false, "ScenePlacementActor.run_placement_pipeline: asset def count mismatch")
		if blend_sv_active:
			release_blend_sv_fields()
		return _pipeline_error("placement_asset_def_build_failed")

	# The payload contains large immutable PackedByteArrays and borrowed RIDs.
	# A shallow copy isolates top-level mutations without cloning that data.
	var placement_settings := placement_common.duplicate()
	placement_settings.erase("target_color")
	placement_settings["anchor_candidate_handoff"] = anchor_candidate_handoff
	placement_settings["target_visual_rgba8_bytes"] = placement_common.get("target_visual_rgba8_bytes", PackedByteArray())
	placement_settings["target_field_bytes"] = target_field_bytes
	placement_settings["target_read_buffers"] = target_buffers
	placement_settings["auto_voxel_runtime_profile_container"] = _runtime_profile_container
	if _sv_committer != null:
		placement_settings["scene_voxel_committer"] = _sv_committer
	placement_settings["mesh_description_buffer"] = get_mesh_description_buffer()
	placement_settings["mesh_description_buffer_summary"] = mesh_description_summary.duplicate(true)
	placement_settings["scene_voxel_tile_resident_field_handoff"] = resident_field_handoff.duplicate(true)
	placement_settings["resident_complexity_field_handoff"] = resident_field_handoff.duplicate(true)
	if bool(resident_field_handoff.get("ok", false)):
		# 读取场 = BlendSV（含 brush）或 committed SV 直通；stamp 双写目标恒为 committed SV 对
		placement_settings["complexity_field_buffer_rid"] = field_read_complexity_rid
		placement_settings["collision_field_buffer_rid"] = field_read_collision_rid
		placement_settings["commit_complexity_field_buffer_rid"] = resident_complexity_field_rid
		placement_settings["commit_collision_field_buffer_rid"] = resident_collision_field_rid
		placement_settings["complexity_field_buffer_borrowed"] = true
		placement_settings["collision_field_buffer_borrowed"] = true
		placement_settings["complexity_field_buffer_owner"] = "ScenePlacementActor" if blend_sv_active else "SceneVoxelCommitter"
		placement_settings["collision_field_buffer_owner"] = "ScenePlacementActor" if blend_sv_active else "SceneVoxelCommitter"
		placement_settings["complexity_field_read_source"] = "spa_blend_sv_composed_field" if blend_sv_active else "scene_voxel_committer_scene_voxel_tile_resident_complexity_field"
		placement_settings["collision_field_read_source"] = "spa_blend_sv_composed_field" if blend_sv_active else "scene_voxel_committer_scene_voxel_tile_resident_collision_field"
		placement_settings["gpu_state_chain_source"] = str(resident_field_handoff.get("gpu_state_chain_source", "scene_voxel_committer_scene_voxel_tile_resident_fields"))
		placement_settings["resident_complexity_field_rendering_device"] = _rd
	# 紧凑 stamp-delta 状态链是 VPG 的 CPU 输入默认路径，无需 opt-in 设置；
	# resident_runtime_dirty_delta_ready 仅供下方 compact_state_chain_summary 报告。
	var resident_runtime_dirty_delta_ready := _gpu_runtime != null \
		and _gpu_runtime.is_ready() \
		and bool(_gpu_runtime_scene_voxel_setup_result.get("resident_gpu_dirty_delta_update_pass_opt_in_ready", false))
	if _gpu_runtime != null and _gpu_runtime.is_ready():
		placement_settings["gpu_autoobject_runtime"] = _gpu_runtime
		placement_settings["write_accepted_placements_to_gpu_runtime"] = true

	resident_pipeline_phases_ms["placement_setup"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	phase_t0_usec = Time.get_ticks_usec()
	var placement_result := placer.run_multi_asset(
		complexity_field,
		collision_field,
		asset_defs,
		sv_grid_size,
		sv["voxel_size"],
		sv["grid_origin"],
		placement_settings
	)
	resident_pipeline_phases_ms["vpg"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	phase_t0_usec = Time.get_ticks_usec()

	# ---- Phase 2: Commit (write accepted placements to SceneVoxel) ----

	var commit_result := {}
	if _sv_committer != null and bool(placement_result.get("ok", false)):
		commit_result = _commit_accepted_placements(placement_result, sv)
	resident_pipeline_phases_ms["commit"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	phase_t0_usec = Time.get_ticks_usec()
	var runtime_dirty_delta_flush_result := _flush_gpu_runtime_dirty_delta_to_scene_voxel_committer(placement_result)
	resident_pipeline_phases_ms["dirty_delta_flush"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	phase_t0_usec = Time.get_ticks_usec()
	var accepted_writeback_summary := _accepted_placement_writeback_summary_from_placement(placement_result)
	var compact_state_chain_summary := _compact_state_chain_summary_from_placement(
		placement_result,
		resident_runtime_dirty_delta_ready
	)
	resident_pipeline_phases_ms["summaries"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	phase_t0_usec = Time.get_ticks_usec()
	# ---- Assemble result ----

	_last_pipeline_result = {
		"ok": true,
		"prefilter_result": prefilter_result,
		"placement_result": placement_result,
		"commit_result": commit_result,
		"runtime_dirty_delta_flush_result": runtime_dirty_delta_flush_result,
		"accepted_placement_writeback_summary": accepted_writeback_summary,
		"compact_state_chain_summary": compact_state_chain_summary,
		"anchor_candidate_handoff": _anchor_candidate_handoff_summary(anchor_candidate_handoff, true),
		"resident_complexity_field_handoff": resident_field_handoff,
		"scene_voxel_tile_resident_field_handoff": resident_field_handoff,
		"gpu_runtime_scene_voxel_setup": _gpu_runtime_scene_voxel_setup_result.duplicate(true),
		"profile_probe_pack": prefilter_result.get("profile_probe_pack", {}),
		"mesh_description": mesh_description_summary,
		"target_read_buffers": target_buffers,
		"target_read_buffer_summary": placement_result.get("target_read_buffer_summary", prefilter_result.get("target_read_buffer_summary", {})),
		"asset_count": _registered_descriptors.size(),
		"blend_sv_active": blend_sv_active,
		"brush_sv_has_content": has_brush_sv_content(),
	}
	resident_pipeline_phases_ms["assemble"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	phase_t0_usec = Time.get_ticks_usec()
	if blend_sv_active:
		release_blend_sv_fields()  # BlendSV 临时体素用完即删；BrushSV 常驻保留
	resident_pipeline_phases_ms["blend_release"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	resident_pipeline_phases_ms["total"] = float(Time.get_ticks_usec() - pipeline_t0_usec) / 1000.0
	_last_pipeline_result["resident_pipeline_phases_ms"] = resident_pipeline_phases_ms
	return _last_pipeline_result


## 返回最近一次 run_placement_pipeline 结果的深度副本；供外部在 pipeline 结束后查询详情
func get_last_pipeline_result() -> Dictionary:
	return _last_pipeline_result.duplicate(true)


func _anchor_candidate_handoff_ready(handoff: Dictionary, prefilter: AutoObjectProbePrefilterGPU) -> bool:
	if not bool(handoff.get("ok", false)) or prefilter == null or prefilter.get_rendering_device() != _rd:
		return false
	var anchor_rid: RID = handoff.get("anchor_buffer_rid", RID())
	var count_rid: RID = handoff.get("anchor_count_buffer_rid", RID())
	var topk_rid: RID = handoff.get("topk_buffer_rid", RID())
	return anchor_rid.is_valid() and count_rid.is_valid() and topk_rid.is_valid()


func _anchor_candidate_handoff_summary(handoff: Dictionary, consumed: bool) -> Dictionary:
	return {
		"ok": bool(handoff.get("ok", false)),
		"consumed_by_vpg": consumed,
		"anchor_buffer_rid": "valid" if (handoff.get("anchor_buffer_rid", RID()) as RID).is_valid() else "none",
		"anchor_count_buffer_rid": "valid" if (handoff.get("anchor_count_buffer_rid", RID()) as RID).is_valid() else "none",
		"topk_buffer_rid": "valid" if (handoff.get("topk_buffer_rid", RID()) as RID).is_valid() else "none",
		"anchor_capacity": int(handoff.get("anchor_capacity", 0)),
		"topk": int(handoff.get("topk", 0)),
		"asset_count": int(handoff.get("asset_count", 0)),
		"origin_contract": str(handoff.get("origin_contract", "one_origin_per_anchor")),
		"gpu_first": true,
		"cpu_fallback": false,
	}


static func _compact_state_chain_summary_from_placement(
	placement_result: Dictionary,
	resident_runtime_dirty_delta_ready: bool
) -> Dictionary:
	var chain: Dictionary = placement_result.get("cpu_state_chain", {})
	var full_field: Dictionary = placement_result.get("full_field_readback", {})
	if full_field.is_empty() and chain.has("full_field_readback"):
		full_field = chain.get("full_field_readback", {})
	var mode := str(chain.get("mode", full_field.get("cpu_state_chain_mode", "none")))
	var using_compact := resident_runtime_dirty_delta_ready \
		and mode == "compact_stamp_deltas" \
		and bool(chain.get("stamp_delta_cpu_state_chaining", full_field.get("stamp_delta_cpu_state_chaining", false)))
	var avoids_full_field_readback := using_compact \
		and not bool(chain.get("full_field_readback_required", full_field.get("full_field_readback_required", true))) \
		and not bool(full_field.get("complexity_field_out_gpu_storage_buffer_readback", false)) \
		and not bool(full_field.get("collision_field_out_gpu_storage_buffer_readback", false))
	return {
		"source": "placement_result.cpu_state_chain" if not chain.is_empty() else "placement_result.full_field_readback" if not full_field.is_empty() else "none",
		"ok": using_compact and avoids_full_field_readback,
		"resident_runtime_dirty_delta_ready": resident_runtime_dirty_delta_ready,
		"cpu_state_chain_mode": mode,
		"stamp_delta_cpu_state_chaining": using_compact,
		"full_field_readback_required": not avoids_full_field_readback,
		"complexity_field_out_gpu_storage_buffer_readback": bool(full_field.get("complexity_field_out_gpu_storage_buffer_readback", false)),
		"collision_field_out_gpu_storage_buffer_readback": bool(full_field.get("collision_field_out_gpu_storage_buffer_readback", false)),
		"stamp_delta_readback_source": str(placement_result.get("stamp_delta_readback_source", chain.get("source", "none"))),
		"cpu_fallback": false,
	}


static func _accepted_placement_writeback_summary_from_placement(placement_result: Dictionary) -> Dictionary:
	var writeback: Dictionary = placement_result.get("gpu_autoobject_runtime_writeback", {})
	var shader_consumed := bool(writeback.get("accepted_placement_record_shader_consumed", false))
	var flush_mode := str(writeback.get("runtime_command_flush_mode", "none"))
	var writeback_mode := str(writeback.get("resident_gpu_allocator_writeback_mode", "none"))
	var shader_stats: Dictionary = writeback.get("accepted_placement_record_shader_stats", {})
	var blocked_reason := str(writeback.get(
		"resident_gpu_allocator_writeback_blocked_reason",
		"none" if shader_consumed else "no_resident_allocator_shader_dispatch"
	))
	if writeback.is_empty():
		blocked_reason = "missing_gpu_autoobject_runtime_writeback"
	elif not shader_consumed and blocked_reason == "none":
		blocked_reason = str(writeback.get("reason", "accepted_placement_record_shader_not_consumed"))

	return {
		"source": "placement_result.gpu_autoobject_runtime_writeback" if not writeback.is_empty() else "none",
		"ok": bool(writeback.get("ok", false)),
		"reason": str(writeback.get("reason", "missing_gpu_autoobject_runtime_writeback")),
		"runtime_command_flush_mode": flush_mode,
		"accepted_placement_record_schema_version": int(writeback.get(
			"accepted_placement_record_schema_version",
			GPUAutoObjectRuntimeScript.ACCEPTED_PLACEMENT_RECORD_SCHEMA_VERSION
		)),
		"accepted_placement_record_stride_bytes": int(writeback.get(
			"accepted_placement_record_stride_bytes",
			GPUAutoObjectRuntimeScript.ACCEPTED_PLACEMENT_RECORD_STRIDE_BYTES
		)),
		"accepted_placement_record_shader_consumed": shader_consumed,
		"accepted_placement_record_shader_name": str(writeback.get("accepted_placement_record_shader_name", "none")),
		"accepted_placement_record_shader_path": str(writeback.get("accepted_placement_record_shader_path", "none")),
		"accepted_placement_record_shader_dispatch_count": int(writeback.get("accepted_placement_record_shader_dispatch_count", 0)),
		"accepted_placement_record_shader_stats": shader_stats.duplicate(true),
		"resident_gpu_allocator_writeback": bool(writeback.get("resident_gpu_allocator_writeback", false)),
		"resident_gpu_allocator_writeback_mode": writeback_mode,
		"resident_gpu_allocator_writeback_blocked_reason": blocked_reason,
	}


# ---------------------------------------------------------------------------
# Internal: pipeline helpers
# ---------------------------------------------------------------------------

## 懒加载并返回 AutoObjectProbePrefilterGPU 实例（首次调用时创建）；由 run_autoobject_prefilter 与 run_placement_pipeline 调用
func _get_prefilter() -> AutoObjectProbePrefilterGPU:
	if _prefilter == null:
		_prefilter = PrefilterScript.new()
		_prefilter.attach_rendering_device(_rd, false)
	return _prefilter


## 逐 (anchor, asset) 探针分的调试回读（转发到 prefilter；入参是 source anchor index）。
## ⚠ 刻意**不**用 `_get_prefilter()`：那会在 prefilter 还没跑过时惰性建一个空实例，
## 回读出一片未初始化内存却报 ok。没跑过就如实说没跑过。
func debug_read_prefilter_asset_scores(source_anchor_index: int) -> Dictionary:
	if _prefilter == null:
		return {"ok": false, "reason": "prefilter_not_run"}
	return _prefilter.debug_read_asset_scores(source_anchor_index)


## 懒加载并返回 VoxelPlacementGenerator 实例（首次调用时创建）；由 run_placement_pipeline 调用
func _get_placer() -> VoxelPlacementGenerator:
	if _placer == null:
		_placer = VPGScript.new()
		_placer.attach_rendering_device(_rd, false)
	return _placer


## 构建供 prefilter 使用的 AutoObject 数组（优先自有、否则从注册表取）；由 run_autoobject_prefilter 与 run_placement_pipeline 调用
func _build_autoobject_array_for_pipeline() -> Array:
	var result: Array = []
	for i in range(_registered_descriptors.size()):
		var ao: AutoObject = _registered_autoobject_refs[i]
		if ao != null:
			result.append(ao)
			continue
		# Use or create a lightweight wrapper.
		var wrapper: AutoObject = _cached_lightweight_wrappers.get(i, null)
		if wrapper == null:
			var d: AssetDescriptor = _registered_descriptors[i]
			if d == null:
				# 旧行为 append null，prefilter 拿到一个空槽照跑 —— 该资产被静默跳过，
				# 打分结果里少了一整个资产却没有任何痕迹。
				push_error("ScenePlacementActor._build_autoobject_array_for_pipeline: asset_index=%d 的 descriptor 为 null（asset_count=%d）——无法为其构建 prefilter 视图。" % [
					i, _registered_descriptors.size()])
				assert(false, "ScenePlacementActor._build_autoobject_array_for_pipeline: null descriptor in registry")
				return []
			var mesh_ref: Mesh = _registered_mesh[i]
			var profile_id := _registered_profile_ids[i]
			wrapper = _make_lightweight_autoobject(d, mesh_ref, i, profile_id)
			_cached_lightweight_wrappers[i] = wrapper
		if wrapper == null:
			push_error("ScenePlacementActor._build_autoobject_array_for_pipeline: asset_index=%d 的轻量 AutoObject 包装创建失败。" % i)
			assert(false, "ScenePlacementActor._build_autoobject_array_for_pipeline: lightweight wrapper is null")
			return []
		result.append(wrapper)
	return result.duplicate()


## 构建每个已注册资产的 placement 定义字典（descriptor + profile_id + asset_index）；
## 由 run_placement_pipeline 传入 placer 时调用。形状不随 def 传递——descriptor 是唯一
## 权威，其 collision 已在注册期烘焙进 profile 容器常驻 profile_sample_records 的
## fine 段，VPG 按 profile_id 直读。
func _build_placement_asset_defs() -> Array:
	var asset_defs: Array = []
	for asset_index in range(_registered_descriptors.size()):
		var d := _registered_descriptors[asset_index] as AssetDescriptor
		if d == null:
			push_error("ScenePlacementActor._build_placement_asset_defs: asset_index=%d 的 descriptor 为 null（asset_count=%d）——VPG 会拿到一个没有形状来源的 def。" % [
				asset_index, _registered_descriptors.size()])
			assert(false, "ScenePlacementActor._build_placement_asset_defs: null descriptor in registry")
			return []
		if not d.has_method("get_mesh"):
			# 常见成因：资源脚本缺 @tool，编辑器把它作为占位实例加载 → 方法调用不执行。
			push_error("ScenePlacementActor._build_placement_asset_defs: asset_index=%d 的 descriptor 无 get_mesh()（asset_id=\"%s\"）——间距半径会静默退回默认值。" % [
				asset_index, str(d.get("asset_id"))])
			assert(false, "ScenePlacementActor._build_placement_asset_defs: descriptor has no get_mesh()")
			return []
		var entry: Dictionary = {
			"descriptor": d,
			"asset_index": asset_index,
			"profile_id": _registered_profile_ids[asset_index],
		}
		# Pairwise spacing radius for the reduce (world units, XZ half-extent of
		# the mesh AABB): trees keep crown distance while grass stays dense.
		var mesh: Mesh = d.get_mesh()
		if mesh != null:
			var aabb_size := mesh.get_aabb().size
			entry["spacing_radius_world"] = maxf(aabb_size.x, aabb_size.z) * 0.5
		asset_defs.append(entry)
	return asset_defs


## Stamp-only 提交定稿：GPU state-chain stamp 已原位写入 committed SV 常驻 field（stamp 即提交），
## 这里推进 committer 的提交发布（散射 CPU 入口记录 + tick + tile 摘要）；由 run_placement_pipeline 在放置成功后调用
func _commit_accepted_placements(placement_result: Dictionary, _sv: Dictionary) -> Dictionary:
	var instance_writeback: Dictionary = placement_result.get("instance_stamp_writeback", {})
	var writeback_mode := str(instance_writeback.get("accepted_placement_writeback_mode", ""))
	var total_accepted := int(placement_result.get("total_placed", 0))

	if writeback_mode == "gpu_state_chain_stamp":
		var commit_summary := {}
		if _sv_committer != null:
			_sv_committer.commit_scene_voxels()
			commit_summary = _sv_committer.get_last_scene_voxel_commit_summary()
		return {
			"ok": true,
			"committed": int(instance_writeback.get("applied_count", total_accepted)),
			"total_accepted": total_accepted,
			"commit_mode": "gpu_state_chain_stamp_commit",
			"gpu_first": true,
			"cpu_fallback": false,
			"gpu_commit_source": "vpg_state_chain_stamp",
			"committer_commit_summary": commit_summary,
		}

	return {
		"ok": false,
		"reason": "no_gpu_state_chain_stamp_commit",
		"committed": 0,
		"total_accepted": total_accepted,
		"commit_mode": "blocked_no_gpu_state_chain_stamp",
		"gpu_first": true,
		"cpu_fallback": false,
	}


static func _make_lightweight_autoobject(descriptor: AssetDescriptor, mesh_ref: Mesh, asset_index: int, profile_id: int) -> AutoObject:
	## Minimal AutoObject wrapper for pipeline consumption.
	## Exposes get_profile_samples() and get_collision(), which are sufficient for prefilter.
	## profile_id is the actual GPU profile ID from the actor's registry.
	var obj := AutoObject.new()
	obj.asset_descriptor = descriptor
	obj.mesh = mesh_ref if mesh_ref != null else descriptor.mesh
	obj.voxel_color = descriptor.get_color()
	obj.voxel_complexity = descriptor.get_complexity()
	obj.semantic_probe_density = descriptor.semantic_probe_density
	obj.context_sensing_radius = descriptor.context_sensing_radius
	obj.collision = descriptor.collision.duplicate(true)
	obj.set_meta("profile_id", profile_id)
	obj.set_meta("asset_index", asset_index)
	return obj


static func _pipeline_error(reason: String) -> Dictionary:
	return {
		"ok": false,
		"phase": "init",
		"reason": reason,
		"prefilter_result": {},
		"placement_result": {},
		"commit_result": {},
		"accepted_placement_writeback_summary": _accepted_placement_writeback_summary_from_placement({}),
		"profile_probe_pack": {},
		"asset_count": 0,
	}




static func _expected_target_byte_count(sv: Dictionary) -> int:
	var grid_size: Vector3i = sv.get("grid_size", Vector3i.ZERO)
	return maxi(VoxelGeneral.voxel_count(grid_size), 1) * 4


## 返回空 = 该键不满足契约（调用方必须硬失败，绝不可用零填充顶替）。
static func _prepacked_target_bytes(settings: Dictionary, key: String, expected_bytes: int) -> PackedByteArray:
	if not settings.has(key):
		push_error("ScenePlacementActorTargetReadBuffers: settings 缺少 target 字节键 \"%s\"（expected_bytes=%d, settings keys=%s）——零填充顶替等于对着空 target 打分。" % [
			key, expected_bytes, str(settings.keys())])
		assert(false, "ScenePlacementActorTargetReadBuffers: missing target bytes key")
		return PackedByteArray()
	var raw = settings[key]
	if not raw is PackedByteArray:
		push_error("ScenePlacementActorTargetReadBuffers: settings[\"%s\"] 类型错误（期望 PackedByteArray，实际 %s）。" % [
			key, type_string(typeof(raw))])
		assert(false, "ScenePlacementActorTargetReadBuffers: target bytes wrong type")
		return PackedByteArray()
	var bytes := raw as PackedByteArray
	if bytes.size() < expected_bytes:
		push_error("ScenePlacementActorTargetReadBuffers: settings[\"%s\"] 字节数不足（expected=%d, actual=%d）——缺的部分只能补零，target 会被静默削掉一块。" % [
			key, expected_bytes, bytes.size()])
		assert(false, "ScenePlacementActorTargetReadBuffers: target bytes too small")
		return PackedByteArray()
	return bytes if bytes.size() == expected_bytes else bytes.slice(0, expected_bytes)


static func _target_read_buffer_debug_readback_requested(settings: Dictionary) -> bool:
	return bool(settings.get(
		TARGET_READ_BUFFERS_DEBUG_READBACK_KEY,
		settings.get("read_target_read_buffer_bytes", settings.get("debug_target_read_buffer_readback", false))
	))


## 释放并置空缓存的 prefilter 与 placer 实例；由 _dispose_internal 调用
func _free_cached_wrappers() -> void:
	for asset_index in _cached_lightweight_wrappers:
		var wrapper: AutoObject = _cached_lightweight_wrappers[asset_index]
		if wrapper != null and not wrapper.is_queued_for_deletion():
			if wrapper.is_inside_tree():
				wrapper.queue_free()
			else:
				wrapper.free()
	_cached_lightweight_wrappers.clear()



# --------------------------------------------------------------------------
# Complexity Field Handoff
# --------------------------------------------------------------------------

## 从 SV 字典构建 GPU-resident complexity field handoff 合约（含 RID 与元数据）。
## 公有窄 seam（批 1）：run_placement_pipeline / score_blendsv_feedback_against_target 内部消费。
## ⚠ 唯一的外部消费方 `checks/spa_pipeline_checks.gd` 已于 2026-08-07 删除，
## 所以这个 seam 现在只有内部消费者 —— 若无新消费方出现，它可以收窄回 private。
func build_resident_complexity_field_handoff(sv: Dictionary) -> Dictionary:
	var grid_size: Vector3i = sv.get("grid_size", Vector3i.ZERO)
	var expected_voxel_count := VoxelGeneral.voxel_count(grid_size)
	var complexity_buffer_name := SceneVoxelTileStoreScript.SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER
	var collision_buffer_name := SceneVoxelTileStoreScript.SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER
	var complexity_stride_bytes := SceneVoxelTileStoreScript.SCENE_VOXEL_TILE_COMPLEXITY_FIELD_STRIDE_BYTES
	var collision_stride_bytes := SceneVoxelTileStoreScript.SCENE_VOXEL_TILE_COLLISION_FIELD_STRIDE_BYTES
	var complexity_expected_byte_count := maxi(expected_voxel_count, 0) * complexity_stride_bytes
	var collision_expected_byte_count := maxi(expected_voxel_count, 0) * collision_stride_bytes
	var collision_expected_upload_byte_count := SceneVoxelTileCodecScript.u32_field_byte_count(expected_voxel_count)
	var summary := {}
	var complexity_rid := RID()
	var collision_rid := RID()

	if expected_voxel_count <= 0:
		return _resident_complexity_field_handoff_summary(false, "invalid_grid_size", expected_voxel_count, summary, complexity_rid, collision_rid)
	if _rd == null:
		return _resident_complexity_field_handoff_summary(false, "no_rendering_device", expected_voxel_count, summary, complexity_rid, collision_rid)
	if _tile_store == null:
		return _resident_complexity_field_handoff_summary(false, "no_scene_voxel_tile_store", expected_voxel_count, summary, complexity_rid, collision_rid)

	var tile_store_rd := GodotComputeShaderBase.rendering_device_of(_tile_store)
	if tile_store_rd == null:
		return _resident_complexity_field_handoff_summary(false, "tile_store_rendering_device_missing", expected_voxel_count, summary, complexity_rid, collision_rid)
	if tile_store_rd != _rd:
		return _resident_complexity_field_handoff_summary(false, "tile_store_rendering_device_mismatch", expected_voxel_count, summary, complexity_rid, collision_rid)

	summary = _tile_store.get_scene_voxel_tile_gpu_buffer_status()
	complexity_rid = _tile_store.get_scene_voxel_tile_gpu_buffer(complexity_buffer_name)
	collision_rid = _tile_store.get_scene_voxel_tile_gpu_buffer(collision_buffer_name)

	var buffers: Dictionary = summary.get("buffers", {})
	var complexity_buffer_summary: Dictionary = buffers.get(complexity_buffer_name, {})
	var collision_buffer_summary: Dictionary = buffers.get(collision_buffer_name, {})
	var complexity_count := int(complexity_buffer_summary.get("record_count", summary.get("complexity_field_voxel_count", 0)))
	var collision_count := int(collision_buffer_summary.get("record_count", summary.get("collision_field_voxel_count", 0)))
	var complexity_stride := int(complexity_buffer_summary.get("stride_bytes", 0))
	var collision_stride := int(collision_buffer_summary.get("stride_bytes", 0))
	var complexity_format := str(complexity_buffer_summary.get("format", summary.get("complexity_field_format", "")))
	var collision_format := str(collision_buffer_summary.get("format", summary.get("collision_field_format", "")))

	if not bool(summary.get("runtime_ready", false)):
		var reason := str(summary.get("reason", "committer_resident_fields_not_runtime_ready"))
		if reason.is_empty():
			reason = "committer_resident_fields_not_runtime_ready"
		return _resident_complexity_field_handoff_summary(false, reason, expected_voxel_count, summary, complexity_rid, collision_rid)
	if str(summary.get("resident_field_read_source", "none")) != "gpu_storage_buffers":
		return _resident_complexity_field_handoff_summary(false, "committer_resident_field_source_not_gpu_storage_buffers", expected_voxel_count, summary, complexity_rid, collision_rid)
	if not complexity_rid.is_valid() or not collision_rid.is_valid():
		return _resident_complexity_field_handoff_summary(false, "committer_resident_field_rid_invalid", expected_voxel_count, summary, complexity_rid, collision_rid)
	if not bool(complexity_buffer_summary.get("rid_valid", false)) or not bool(collision_buffer_summary.get("rid_valid", false)):
		return _resident_complexity_field_handoff_summary(false, "committer_resident_field_summary_rid_invalid", expected_voxel_count, summary, complexity_rid, collision_rid)
	if complexity_stride != complexity_stride_bytes or collision_stride != collision_stride_bytes:
		return _resident_complexity_field_handoff_summary(false, "committer_resident_field_stride_mismatch", expected_voxel_count, summary, complexity_rid, collision_rid)
	if complexity_format != SceneVoxelTileStoreScript.SCENE_VOXEL_TILE_COMPLEXITY_FIELD_FORMAT or collision_format != SceneVoxelTileStoreScript.SCENE_VOXEL_TILE_COLLISION_FIELD_FORMAT:
		return _resident_complexity_field_handoff_summary(false, "committer_resident_field_format_mismatch", expected_voxel_count, summary, complexity_rid, collision_rid)
	if complexity_count != expected_voxel_count or collision_count != expected_voxel_count:
		return _resident_complexity_field_handoff_summary(false, "committer_resident_field_record_count_mismatch", expected_voxel_count, summary, complexity_rid, collision_rid)
	# 摘要键缺失时旧行为用“期望值”当默认值 → 下面两道尺寸校验凭空通过，把一个来路
	# 不明的缓冲当成合法常驻场借出去。缺键本身就是 tile store 契约破裂，直接硬失败。
	for required_summary_key in ["logical_byte_size", "upload_byte_size", "initialization_source"]:
		if not complexity_buffer_summary.has(required_summary_key) or not collision_buffer_summary.has(required_summary_key):
			push_error("ScenePlacementActor.build_resident_complexity_field_handoff: tile store 缓冲摘要缺少键 \"%s\"（complexity keys=%s, collision keys=%s）——用期望值兜底会让尺寸校验凭空通过。" % [
				required_summary_key, str(complexity_buffer_summary.keys()), str(collision_buffer_summary.keys())])
			assert(false, "ScenePlacementActor.build_resident_complexity_field_handoff: buffer summary missing required key")
			return _resident_complexity_field_handoff_summary(false, "committer_resident_field_summary_key_missing", expected_voxel_count, summary, complexity_rid, collision_rid)
	if int(complexity_buffer_summary["logical_byte_size"]) != complexity_expected_byte_count \
			or int(collision_buffer_summary["logical_byte_size"]) != collision_expected_byte_count:
		return _resident_complexity_field_handoff_summary(false, "committer_resident_field_byte_count_mismatch", expected_voxel_count, summary, complexity_rid, collision_rid)
	var complexity_initialized := int(complexity_buffer_summary["upload_byte_size"]) >= complexity_expected_byte_count \
		or str(complexity_buffer_summary["initialization_source"]) == "gpu_full_write"
	var collision_initialized := int(collision_buffer_summary["upload_byte_size"]) >= collision_expected_upload_byte_count \
		or str(collision_buffer_summary["initialization_source"]) == "gpu_full_write"
	if not complexity_initialized or not collision_initialized:
		return _resident_complexity_field_handoff_summary(false, "committer_resident_field_upload_byte_count_mismatch", expected_voxel_count, summary, complexity_rid, collision_rid)

	return _resident_complexity_field_handoff_summary(true, "ok", expected_voxel_count, summary, complexity_rid, collision_rid)


## 将 complexity field handoff 合约转换为可序列化摘要字典；由 pipeline result 组装时调用
func _resident_complexity_field_handoff_summary(
	ok: bool,
	reason: String,
	expected_voxel_count: int,
	summary: Dictionary,
	complexity_rid: RID,
	collision_rid: RID
) -> Dictionary:
	var complexity_buffer_name := SceneVoxelTileStoreScript.SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER
	var collision_buffer_name := SceneVoxelTileStoreScript.SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER
	var buffers: Dictionary = summary.get("buffers", {})
	var complexity_buffer_summary: Dictionary = buffers.get(complexity_buffer_name, {})
	var collision_buffer_summary: Dictionary = buffers.get(collision_buffer_name, {})
	var complexity_count := int(complexity_buffer_summary.get("record_count", summary.get("complexity_field_voxel_count", 0)))
	var collision_count := int(collision_buffer_summary.get("record_count", summary.get("collision_field_voxel_count", 0)))
	return {
		"ok": ok,
		"resident_complexity_field_handoff": ok,
		"reason": reason,
		"source": "SceneVoxelTileStore.get_scene_voxel_tile_gpu_buffer_status" if not summary.is_empty() else "none",
		"producer": "SceneVoxelTileStore",
		"owner": "ScenePlacementActor" if ok else "none",
		"borrowed_from": "ScenePlacementActor/SceneVoxelTileStore" if ok else "none",
		"complexity_field_buffer_rid": complexity_rid if ok else RID(),
		"collision_field_buffer_rid": collision_rid if ok else RID(),
		"runtime_ready": bool(summary.get("runtime_ready", false)),
		"resident_field_read_source": str(summary.get("resident_field_read_source", "none")),
		"runtime_read_source": str(summary.get("runtime_read_source", "none")),
		"rendering_device": _rd if ok else null,
		"complexity_field_stride_bytes": int(complexity_buffer_summary.get("stride_bytes", 0)),
		"collision_field_stride_bytes": int(collision_buffer_summary.get("stride_bytes", 0)),
		"complexity_field_format": str(complexity_buffer_summary.get("format", summary.get("complexity_field_format", ""))),
		"collision_field_format": str(collision_buffer_summary.get("format", summary.get("collision_field_format", ""))),
		"complexity_field_record_count": complexity_count,
		"collision_field_record_count": collision_count,
		"expected_voxel_count": expected_voxel_count,
		"resident_field_voxel_count": int(summary.get("resident_field_voxel_count", complexity_count)),
		"complexity_field_logical_byte_size": int(complexity_buffer_summary.get("logical_byte_size", 0)),
		"collision_field_logical_byte_size": int(collision_buffer_summary.get("logical_byte_size", 0)),
		"gpu_state_chain_source": "scene_voxel_committer_scene_voxel_tile_resident_fields" if ok else "none",
		"gpu_first": true,
		"cpu_fallback": false,
	}



# --------------------------------------------------------------------------
# Target Read Buffer Handoff
# --------------------------------------------------------------------------

## 释放 resident target read GPU 缓冲并重置摘要；由 _dispose_internal 和 pipeline 开始时调用
## debug 回读通道保形：常驻缓冲现在是 packed rgba8（每体素 1 个 u32），而既有消费方期望
## 每体素 4 个 float（vec4 展开）。这里在 CPU 上做与原 pack_target_field.glsl 相同的
## `/ 255.0` 反量化，使回读产物逐位不变——GPU 侧不再为调试通道付出 12 B/voxel 常驻代价。
func _target_field_floats_from_rgba8_bytes(packed_bytes: PackedByteArray, voxel_count: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var n := mini(voxel_count, packed_bytes.size() / 4)
	if n <= 0:
		return out
	out.resize(n * 4)
	for i in range(n):
		var word := packed_bytes.decode_u32(i * 4)
		out[i * 4 + 0] = float((word >> 24) & 0xFF) / 255.0
		out[i * 4 + 1] = float((word >> 16) & 0xFF) / 255.0
		out[i * 4 + 2] = float((word >> 8) & 0xFF) / 255.0
		out[i * 4 + 3] = float(word & 0xFF) / 255.0
	return out


func _release_resident_target_read_buffer_handoff() -> void:
	if _resident_target_field_buffer.is_valid():
		release_rid(_resident_target_field_buffer)
	if _resident_target_collision_buffer.is_valid():
		release_rid(_resident_target_collision_buffer)
	_resident_target_field_buffer = RID()
	_resident_target_collision_buffer = RID()
	_resident_target_collision_byte_count = 0
	_resident_target_read_buffer_cache_key = {}


## 将 target read buffer handoff 合约转换为可序列化摘要字典；由 pipeline result 组装时调用
func _resident_target_read_buffer_handoff_summary(
	ok: bool,
	reason: String,
	expected_bytes: int,
	voxel_count: int,
	color_source: String,
	dispatch_groups: Vector3i,
	target_field_byte_count: int = -1
) -> Dictionary:
	var safe_target_field_byte_count := target_field_byte_count
	if safe_target_field_byte_count < 0:
		safe_target_field_byte_count = maxi(voxel_count, 0) * 4
	return {
		"ok": ok,
		"resident_target_read_buffer_handoff": ok,
		"reason": reason,
		"owner": "ScenePlacementActor" if ok else "none",
		"producer": "ScenePlacementActorTargetReadBuffers",
		"rendering_device": _rd if ok else null,
		"target_field_buffer": _resident_target_field_buffer if ok else RID(),
		"target_field_buffer_rid": "valid" if ok and _resident_target_field_buffer.is_valid() else "none",
		"target_field_byte_count": safe_target_field_byte_count if ok else 0,
		"target_field_stride_bytes": 4 if ok else 0,
		"target_field_format": "rgba8_unorm" if ok else "none",
		"target_collision_buffer": _resident_target_collision_buffer if ok else RID(),
		"target_collision_buffer_rid": "valid" if ok and _resident_target_collision_buffer.is_valid() else "none",
		"target_collision_byte_count": _resident_target_collision_byte_count if ok else 0,
		"target_collision_format": "unorm8_u32" if ok else "none",
		"voxel_count": voxel_count if ok else 0,
		"expected_byte_count": expected_bytes,
		"target_color_source": color_source,
		"target_color_format": "rgba8_u32" if ok else "none",
		"target_read_buffer_lifetime": "ScenePlacementActor owned until next target read-buffer prep, dispose, or explicit release" if ok else "none",
		"dispatch_groups": dispatch_groups if ok else Vector3i.ZERO,
		"target_revision": _resident_target_read_buffer_revision if ok else -1,
		"cpu_fallback": false,
		"gpu_first": true,
	}


## 从独立 TargetSV visual/collision 输入构建 GPU-resident target read buffer 合约；由 run_placement_pipeline 与外部拆分 pipeline 时调用
func prepare_target_read_buffers_from_common_gpu(settings: Dictionary, sv: Dictionary) -> Dictionary:
	log_name = "ScenePlacementActorTargetReadBuffers"
	var expected_bytes := _expected_target_byte_count(sv)
	var voxel_count := maxi(int(expected_bytes / 4), 1)
	# 常驻 target 场与其余三层同格式：packed rgba8，每体素 4 B（原先是展开后的 vec4 16 B）。
	var target_field_byte_count := voxel_count * 4
	var target_collision_byte_count := SceneVoxelTileCodecScript.u32_field_byte_count(voxel_count)
	var resident_handoff_enabled := bool(settings.get(RESIDENT_TARGET_READ_BUFFERS_OPT_IN_KEY, true))
	var debug_readback_requested := _target_read_buffer_debug_readback_requested(settings)
	var source_color := _prepacked_target_bytes(settings, "target_visual_rgba8_bytes", expected_bytes)
	var color_valid := not source_color.is_empty()
	var color_source := "target_visual_rgba8_bytes" if color_valid else "invalid_target_visual_rgba8_bytes"
	var source_collision := _prepacked_target_bytes(
		settings, "target_collision_r8_bytes", target_collision_byte_count)
	var collision_valid := not source_collision.is_empty()
	var collision_source := "target_collision_r8_bytes" if collision_valid else "invalid_target_collision_r8_bytes"

	# 同族失败 dict（×6，仅 reason 不同）收敛为本地工厂：ReportSchema.fail 产出规范
	# {ok:false, reason, gpu_first, cpu_fallback} + 运行时 extra；reason 逐字透传（含喂给 summary）。
	var _fail := func(fail_reason: String) -> Dictionary:
		return ReportSchema.fail(ReportSchema.TARGET_READ_BUFFER_FAILURE, fail_reason, {
			"expected_byte_count": expected_bytes,
			"voxel_count": voxel_count,
			"target_collision_byte_count": target_collision_byte_count,
			"target_collision_source": collision_source,
			"resident_target_read_buffer_handoff": false,
			"resident_target_read_buffer_handoff_summary": _resident_target_read_buffer_handoff_summary(
				false, fail_reason, expected_bytes, voxel_count, color_source, Vector3i.ZERO),
		})

	# target 字节缺失/尺寸不符时旧行为零填充继续（color_source="zero_filled"）——那是在
	# 全空 target 上跑打分与放置，分数看上去完全正常却毫无意义。改为硬失败（详细成因
	# 已由 _prepacked_target_bytes 报出）。
	if not color_valid:
		return _fail.call("target_visual_rgba8_bytes_invalid")
	if not collision_valid:
		return _fail.call("target_collision_r8_bytes_invalid")

	if not ensure_device(true, false):
		return _fail.call("missing_rendering_device")

	# ⚠ 仅作为 handoff 报告字段保留：展开 dispatch 已随 vec4 一起删除，这里描述的是一个
	# 不再发生的 dispatch。四个发出 handoff 的字典仍读它，故不能直接删。
	var groups := dispatch_groups_1d(voxel_count, 64)
	var target_cache_key := {
		"voxel_count": voxel_count,
		"expected_bytes": expected_bytes,
		"target_field_byte_count": target_field_byte_count,
		"target_collision_byte_count": target_collision_byte_count,
		"color_valid": color_valid,
		"collision_valid": collision_valid,
		"color_hash": hash(source_color) if color_valid else 0,
		"collision_hash": hash(source_collision) if collision_valid else 0,
	}
	if resident_handoff_enabled \
			and _resident_target_field_buffer.is_valid() \
			and _resident_target_collision_buffer.is_valid() \
			and _resident_target_read_buffer_cache_key == target_cache_key:
		var cached_target_field_bytes := PackedFloat32Array()
		if debug_readback_requested:
			cached_target_field_bytes = _target_field_floats_from_rgba8_bytes(
				_rd.buffer_get_data(_resident_target_field_buffer, 0, target_field_byte_count), voxel_count)
			if cached_target_field_bytes.size() != voxel_count * 4:
				return _fail.call("target_read_buffer_cached_debug_readback_size_mismatch")
		var cached_summary := _resident_target_read_buffer_handoff_summary(
			true, "ok", expected_bytes, voxel_count, color_source, groups, target_field_byte_count)
		cached_summary["cached"] = true
		return {
			"ok": true,
			"reason": "ok",
			"gpu_first": true,
			"cpu_fallback": false,
			"cached": true,
			"target_revision": _resident_target_read_buffer_revision,
			"target_field_bytes": cached_target_field_bytes,
			"expected_byte_count": expected_bytes,
			"target_field_byte_count": target_field_byte_count,
			"target_collision_byte_count": target_collision_byte_count,
			"voxel_count": voxel_count,
			"target_color_source": color_source,
			"target_collision_source": collision_source,
			"target_field_format": "rgba8_unorm",
			"target_field_stride_bytes": 4,
			"target_collision_format": "unorm8_u32",
			"dispatch_groups": groups,
			"resident_target_read_buffer_handoff": true,
			"resident_target_read_buffer_handoff_summary": cached_summary,
			"rendering_device": _rd,
			"target_field_buffer": _resident_target_field_buffer,
			"target_collision_buffer": _resident_target_collision_buffer,
			"resident_target_read_buffer_owner": "ScenePlacementActor",
			"resident_target_read_buffer_lifetime": str(cached_summary.get("target_read_buffer_lifetime", "ScenePlacementActor owned until next target read-buffer prep, dispose, or explicit release")),
		}

	_release_resident_target_read_buffer_handoff()

	# 常驻 target 场 = 直接上传的 packed rgba8 字，与 SceneSV / BrushSV / BlendSV 同格式。
	# 原先这里 dispatch pack_target_field.glsl 把 rgba8 字展开成 fp32 vec4（16 B/voxel）再常驻，
	# 而 pack_fine_sample_pairs 又把它逐字重新量化回同一个 rgba8 字——一来一回恒等。
	# 去掉展开后：四层同格式、常驻省 12 B/voxel、每次 target 修订少一次 dispatch。
	#
	# ⚠ 这里连带移除了本函数唯一的 submit_and_sync()。两个 storage_buffer_from_bytes 的上传由 RD
	# 自行调度，且下方 debug 回读路径今天本来就没有前置 submit，故安全——但明确记下来，
	# 免得日后把问题归到"少了一次 submit"上。
	# 同时消失的三个失败原因：target_read_buffer_prep_shader_not_ready / _uniform_set_failed /
	# _compute_list_begin_failed。全仓无任何断言引用它们（ReportSchema.TARGET_READ_BUFFER_FAILURE
	# 只声明 failure_defaults，没有 reason 枚举）。
	var output_scope := SCOPE_PERSISTENT if resident_handoff_enabled else SCOPE_FRAME
	var target_field_output_buffer := storage_buffer_from_bytes(
		source_color,
		output_scope,
		"target_field_out_rgba8_u32"
	)
	var target_collision_output_buffer := storage_buffer_from_bytes(
		source_collision,
		output_scope,
		"target_collision_out_unorm8_u32"
	)
	if not target_field_output_buffer.is_valid() or not target_collision_output_buffer.is_valid():
		if resident_handoff_enabled:
			release_rid(target_field_output_buffer)
			release_rid(target_collision_output_buffer)
		gc_frame()
		return _fail.call("target_read_buffer_prep_storage_buffer_failed")

	if resident_handoff_enabled:
		var rid_ok := target_field_output_buffer.is_valid() and target_collision_output_buffer.is_valid()
		var target_field_bytes := PackedFloat32Array()
		if rid_ok and debug_readback_requested:
			target_field_bytes = _target_field_floats_from_rgba8_bytes(
				_rd.buffer_get_data(target_field_output_buffer, 0, target_field_byte_count), voxel_count)
			if target_field_bytes.size() != voxel_count * 4:
				release_rid(target_field_output_buffer)
				release_rid(target_collision_output_buffer)
				gc_frame()
				return {
					"ok": false,
					"reason": "target_read_buffer_prep_debug_readback_size_mismatch",
					"gpu_first": true,
					"cpu_fallback": false,
					"expected_target_field_floats": voxel_count * 4,
					"actual_target_field_floats": target_field_bytes.size(),
					"voxel_count": voxel_count,
					"resident_target_read_buffer_handoff": false,
					"resident_target_read_buffer_handoff_summary": _resident_target_read_buffer_handoff_summary(
						false,
						"target_read_buffer_prep_debug_readback_size_mismatch",
						expected_bytes,
						voxel_count,
						color_source,
						groups
					),
				}

		_resident_target_field_buffer = target_field_output_buffer
		_resident_target_collision_buffer = target_collision_output_buffer
		_resident_target_collision_byte_count = target_collision_byte_count
		_resident_target_read_buffer_revision += 1
		_resident_target_read_buffer_cache_key = target_cache_key.duplicate(true)
		var resident_summary := _resident_target_read_buffer_handoff_summary(
			_resident_target_field_buffer.is_valid() and _resident_target_collision_buffer.is_valid(),
			"ok" if _resident_target_field_buffer.is_valid() and _resident_target_collision_buffer.is_valid() else "resident_target_read_buffer_rid_invalid",
			expected_bytes,
			voxel_count,
			color_source,
			groups,
			target_field_byte_count
		)
		resident_summary["cached"] = false
		rid_ok = _resident_target_field_buffer.is_valid() and _resident_target_collision_buffer.is_valid()
		gc_frame()
		return {
			"ok": rid_ok,
			"reason": "ok" if rid_ok else "resident_target_read_buffer_rid_invalid",
			"gpu_first": true,
			"cpu_fallback": false,
			"cached": false,
			"target_revision": _resident_target_read_buffer_revision,
			"target_field_bytes": target_field_bytes,
			"expected_byte_count": expected_bytes,
			"target_field_byte_count": target_field_byte_count,
			"target_collision_byte_count": target_collision_byte_count,
			"voxel_count": voxel_count,
			"target_color_source": color_source,
			"target_collision_source": collision_source,
			"target_field_format": "rgba8_unorm",
			"target_field_stride_bytes": 4,
			"target_collision_format": "unorm8_u32",
			"dispatch_groups": groups,
			"resident_target_read_buffer_handoff": rid_ok,
			"resident_target_read_buffer_handoff_summary": resident_summary,
			"rendering_device": _rd if rid_ok else null,
			"target_field_buffer": _resident_target_field_buffer,
			"target_collision_buffer": _resident_target_collision_buffer,
			"resident_target_read_buffer_owner": "ScenePlacementActor" if rid_ok else "none",
			"resident_target_read_buffer_lifetime": str(resident_summary.get("target_read_buffer_lifetime", "ScenePlacementActor owned until next target read-buffer prep, dispose, or explicit release")),
		}

	# Non-resident path: read back bytes for debug/legacy consumers.
	var target_field_buf := _rd.buffer_get_data(target_field_output_buffer, 0, target_field_byte_count)
	var target_field_bytes := _target_field_floats_from_rgba8_bytes(target_field_buf, voxel_count)
	gc_frame()
	if target_field_bytes.size() != voxel_count * 4:
		return {
			"ok": false,
			"reason": "target_read_buffer_prep_readback_size_mismatch",
			"gpu_first": true,
			"cpu_fallback": false,
			"expected_target_field_floats": voxel_count * 4,
			"actual_target_field_floats": target_field_bytes.size(),
			"voxel_count": voxel_count,
			"resident_target_read_buffer_handoff": false,
			"resident_target_read_buffer_handoff_summary": _resident_target_read_buffer_handoff_summary(
				false,
				"target_read_buffer_prep_readback_size_mismatch",
				expected_bytes,
				voxel_count,
				color_source,
				groups
			),
		}

	var resident_summary := _resident_target_read_buffer_handoff_summary(
		false,
		"not_enabled",
		expected_bytes,
		voxel_count,
		color_source,
		groups
	)

	return {
		"ok": true,
		"reason": "ok",
		"gpu_first": true,
		"cpu_fallback": false,
		"target_field_bytes": target_field_bytes,
		"expected_byte_count": expected_bytes,
		"target_field_byte_count": target_field_byte_count,
		"target_collision_r8_bytes": source_collision,
		"target_collision_byte_count": target_collision_byte_count,
		"voxel_count": voxel_count,
		"target_color_source": color_source,
		"target_collision_source": collision_source,
		"target_field_format": "rgba8_unorm",
		"target_field_stride_bytes": 4,
		"target_collision_format": "unorm8_u32",
		"dispatch_groups": groups,
		"resident_target_read_buffer_handoff": false,
		"resident_target_read_buffer_handoff_summary": resident_summary,
		"rendering_device": null,
		"target_field_buffer": RID(),
		"target_collision_buffer": RID(),
		"resident_target_read_buffer_owner": "none",
		"resident_target_read_buffer_lifetime": "none",
	}
