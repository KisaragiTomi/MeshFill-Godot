class_name ScenePlacementActor
extends "res://scripts/godot_compute_shader_base.gd"

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
const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")
const GPUAutoObjectRuntimeScript := preload("res://scripts/gpu_autoobject_runtime.gd")
const AssetDescriptor := preload("res://scripts/asset_descriptor.gd")
const AutoObject := preload("res://scripts/auto_object.gd")
const AutoObjectProbePrefilterGPU := preload("res://scripts/autoobject_probe_prefilter_gpu.gd")
const AutoVoxelRuntimeProfileContainer := preload("res://scripts/auto_voxel_runtime_profile_container.gd")
const GPUAutoObjectRuntime := preload("res://scripts/gpu_autoobject_runtime.gd")
const SceneVoxelCommitter := preload("res://scripts/scene_voxel_committer.gd")
const VoxelPlacementGenerator := preload("res://scripts/voxel_placement_generator.gd")
const BufferUtils := preload("res://scripts/utils/buffer_utils.gd")
const HashUtils := preload("res://scripts/utils/hash_utils.gd")

const MESH_DESCRIPTION_BUFFER := "mesh_description"
const MESH_DESCRIPTION_STRIDE_BYTES := 128
const MESH_DESCRIPTION_FLAG_HAS_MESH := 1
const MESH_DESCRIPTION_FLAG_HAS_SOURCE_MESH := 2
const MESH_DESCRIPTION_FLAG_SOURCE_DIFFERS := 4
const MESH_DESCRIPTION_FLAG_HAS_SOURCE_PATH := 8
const TARGET_READ_BUFFER_PREP_SHADER := "res://shaders/prepare_target_read_buffers.glsl"
const TARGET_READ_BUFFER_PREP_LOCAL_SIZE := 64
const TARGET_FIELD_STRIDE_BYTES := 16  # vec4 = 16 bytes per voxel
const RESIDENT_TARGET_READ_BUFFERS_OPT_IN_KEY := "use_resident_target_read_buffer_handoff"
const TARGET_READ_BUFFERS_DEBUG_READBACK_KEY := "debug_read_target_read_buffer_bytes"
const RESIDENT_CANDIDATE_ROUTE_OPT_IN_KEY := "use_resident_candidate_route_handoff"
const CandidateRouteSchemaScript := preload("res://scripts/candidate_route_schema.gd")
const CANDIDATE_ROUTE_SCHEMA_VERSION := CandidateRouteSchemaScript.SCHEMA_VERSION
const CANDIDATE_ROUTE_RECORD_STRIDE_BYTES := CandidateRouteSchemaScript.RECORD_STRIDE_BYTES
const CANDIDATE_ROUTE_RANGE_STRIDE_BYTES := CandidateRouteSchemaScript.RANGE_STRIDE_BYTES
const CANDIDATE_ROUTE_CPU_PACK_SOURCE_LABEL := "gpu_vote_buffer_readback_cpu_pack"
## BrushSV 常驻旁路层 + BlendSV 按需合成（方案A：committed SV 纯 auto，brush 不进提交）
## 散射 stride/路径/键/展平契约已抽取到 utils/sv_field_scatter.gd（与 committer stamp-only 提交共享）。
const SvFieldScatter := preload("res://scripts/utils/sv_field_scatter.gd")
const SV_FIELD_SCATTER_SHADER := SvFieldScatter.SHADER_PATH
const COMPOSE_BLEND_SV_SHADER := "res://shaders/compose_blend_sv_fields.glsl"
const BLENDSV_FEEDBACK_SHADER := "res://shaders/score_blendsv_feedback.glsl"
const SV_FIELD_RECORD_FLOAT_STRIDE := SvFieldScatter.RECORD_FLOAT_STRIDE
const BLENDSV_FEEDBACK_QUANT_SCALE := 1000.0
const BLENDSV_FEEDBACK_OCCUPIED_EPSILON := 0.001

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

## Asset registry — parallel arrays mapping asset_id → descriptor + profile_id.
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
var _last_mesh_description_upload_error := ""
var _resident_candidate_route_record_buffer: RID
var _resident_candidate_route_range_buffer: RID
var _resident_candidate_route_record_count := 0
var _resident_candidate_route_range_count := 0
var _resident_candidate_route_revision := 0
var _resident_candidate_route_buffers_borrowed := false
var _last_resident_candidate_route_handoff: Dictionary = {}
var _resident_target_color_rgba8_buffer: RID
var _resident_target_read_buffer_voxel_count := 0
var _resident_target_read_buffer_byte_count := 0
var _resident_target_read_buffer_revision := 0
var _last_resident_target_read_buffer_handoff: Dictionary = {}

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
var _brush_sv_complexity_buffer: RID
var _brush_sv_collision_buffer: RID
var _brush_sv_voxel_count := 0
var _brush_sv_has_content := false

## BlendSV 临时合成对（SV + BrushSV；对比 TargetSV / 3D score 用，用完即删）
var _blend_sv_complexity_buffer: RID
var _blend_sv_collision_buffer: RID
var _blend_sv_voxel_count := 0

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------


# --------------------------------------------------------------------------
# 初始化与生命周期
# --------------------------------------------------------------------------

## 获取 RenderingDevice、初始化 profile 容器与 GPU runtime，可选挂载 sv_committer；SPA 使用前必须调用，失败返回 false
func initialize(
	prefer_local_device: bool = true,
	allow_global_fallback: bool = true,
	sv_committer: SceneVoxelCommitter = null
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

	_prepare_gpu_runtime_for_scene_voxel_committer()
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
	_release_resident_candidate_route_handoff()
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
	_gpu_runtime = null


## 返回 SPA 是否已成功初始化（RD 与 profile 容器均有效）；由 run_placement_pipeline 等各 API 入口前置检查调用
func is_initialized() -> bool:
	return _initialized and _rd != null and _runtime_profile_container != null


# ---------------------------------------------------------------------------
# External reference attachment
# ---------------------------------------------------------------------------


# --------------------------------------------------------------------------
# 外部引用挂载
# --------------------------------------------------------------------------

## 注入外部 SceneVoxelCommitter 引用，并同步到 gpu_runtime；由外部在 SV 就绪后调用
func attach_sv_committer(sv_committer: SceneVoxelCommitter) -> void:
	_sv_committer = sv_committer
	_prepare_gpu_runtime_for_scene_voxel_committer()


## 返回当前挂载的 SceneVoxelCommitter（可能为 null）；由外部查询使用
func get_sv_committer() -> SceneVoxelCommitter:
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
		_prepare_gpu_runtime_for_scene_voxel_committer()


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


## Direct access to GPU buffers for external consumers (e.g. prefilter borrowing).
## 返回 probe records GPU buffer RID；由 prefilter GPU pass 绑定 uniform 时调用
func get_probe_records_buffer() -> RID:
	if not is_gpu_ready():
		return RID()
	return _runtime_profile_container.get_probe_buffer()


## 返回 profile table GPU buffer RID；由 prefilter GPU pass 绑定 uniform 时调用
func get_profile_table_buffer() -> RID:
	if not is_gpu_ready():
		return RID()
	return _runtime_profile_container.get_profile_table_buffer()


## 返回 pivot records GPU buffer RID；由 prefilter GPU pass 绑定 uniform 时调用
func get_pivot_records_buffer() -> RID:
	if not is_gpu_ready():
		return RID()
	return _runtime_profile_container.get_pivot_buffer()


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



# --------------------------------------------------------------------------
# 资产注册
# --------------------------------------------------------------------------

## Register a single AssetDescriptor.  Returns its profile_id (>=0) or -1
## on failure.  The owned profile container immediately uploads profile table,
## probe records, and pivot records to GPU. Descriptor collision is normalized
## and indexed in the profile table, then baked/packed into placement footprint
## buffers by downstream runtime steps instead of being exposed as a direct
## shader-readable descriptor array.
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
	_release_resident_candidate_route_handoff()

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


## 批量注册 AutoObject 数组，返回各自 profile_id 列表；由外部一次性注册多个 autoobject 时调用
func register_autoobject_assets(autoobjects: Array) -> Array[int]:
	var result: Array[int] = []
	for raw in autoobjects:
		var autoobject_ref := raw as AutoObject
		result.append(register_autoobject_asset(autoobject_ref))
	return result


## 批量注册 AssetDescriptor 数组，返回各自 profile_id 列表；由外部传入 descriptor 列表时调用
## Register multiple descriptors at once.  Returns an Array of profile_ids
## (parallel to the input array).  -1 means registration failed for that entry.
func register_assets(descriptors: Array[AssetDescriptor]) -> Array[int]:
	var result: Array[int] = []
	for d in descriptors:
		result.append(register_asset(d))
	return result


## 清空已有资产并批量注册新 descriptor 数组（可选带 mesh/autoobject），返回是否全部成功；由场景重置或换组时调用
## Replace the entire asset registry with a new list.  Old GPU data is
## invalidated and re-uploaded.
func replace_all_assets(
	descriptors: Array[AssetDescriptor],
	meshes: Array = [],
	autoobjects: Array = []
) -> bool:
	clear_assets()

	for i in range(descriptors.size()):
		var d := descriptors[i] as AssetDescriptor
		var m: Mesh = meshes[i] as Mesh if i < meshes.size() else null
		var ao: AutoObject = autoobjects[i] as AutoObject if i < autoobjects.size() else null
		if register_asset(d, m, ao) < 0:
			return false
	return true


## 清空资产后批量注册 AutoObject 数组，返回是否全部成功；由 autoobject 集合更换时调用
func replace_all_autoobject_assets(autoobjects: Array) -> bool:
	clear_assets()
	for raw in autoobjects:
		var autoobject_ref := raw as AutoObject
		if register_autoobject_asset(autoobject_ref) < 0:
			return false
	return true


## 清空所有已注册资产、profile、mesh 及 autoobject 引用并重置 mesh description 缓冲；由 replace 路径或外部重置调用
## Clear the asset registry and re-upload an empty profile set.
func clear_assets() -> void:
	_free_cached_wrappers()
	_release_resident_candidate_route_handoff()
	if _runtime_profile_container != null:
		_runtime_profile_container.clear()
		_runtime_profile_container.upload_profiles(true)
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


## 返回资产注册表是否为空；由 pipeline 入口前置检查调用
func is_asset_registry_empty() -> bool:
	return _registered_descriptors.is_empty()


## 返回已注册 AssetDescriptor 数组的引用；供外部查询与调试
func get_registered_descriptors() -> Array[AssetDescriptor]:
	return _registered_descriptors.duplicate()


## 返回已注册 profile_id 数组；供外部查询与调试
func get_registered_profile_ids() -> Array[int]:
	return _registered_profile_ids.duplicate()


## 根据 asset_id 返回对应 profile_id；越界或无效时返回 -1
func get_profile_id_for_asset(asset_id: int) -> int:
	if asset_id < 0 or asset_id >= _registered_profile_ids.size():
		return -1
	return _registered_profile_ids[asset_id]


## 返回已注册 Mesh 数组；供 mesh description 上传与外部查询
func get_registered_meshes() -> Array[Mesh]:
	return _registered_mesh.duplicate()



# --------------------------------------------------------------------------
# AutoObject 管理
# --------------------------------------------------------------------------

## 返回已注册 AutoObject 引用数组；供 pipeline 构建 autoobject 数组
func get_registered_autoobject_refs() -> Array[AutoObject]:
	_prune_owned_autoobjects()
	return _registered_autoobject_refs.duplicate()


## 更新指定 asset_id 的 AutoObject 引用；由 own_autoobject 或外部在创建实例后调用
func set_registered_autoobject_ref(asset_id: int, autoobject_ref: AutoObject) -> bool:
	if asset_id < 0 or asset_id >= _registered_autoobject_refs.size():
		return false
	_registered_autoobject_refs[asset_id] = autoobject_ref
	_free_cached_wrappers()
	_mark_mesh_description_changed()
	if is_initialized():
		return _upload_mesh_description_buffer()
	return true


## 接管 AutoObject 的生命周期所有权，可选绑定 asset_id；同时注册到 autoobject_ref 表；由 SPA 负责创建 autoobject 场景时调用
func own_autoobject(autoobject_ref: AutoObject, asset_id: int = -1) -> bool:
	if autoobject_ref == null:
		return false
	_prune_owned_autoobjects()
	if not _owned_autoobjects.has(autoobject_ref):
		_owned_autoobjects.append(autoobject_ref)
	autoobject_ref.set_meta("spa_owned", true)
	autoobject_ref.set_meta("spa_owner", "ScenePlacementActor")
	if asset_id >= 0:
		autoobject_ref.set_meta("spa_asset_id", asset_id)
		if asset_id < _registered_autoobject_refs.size():
			var registered_ref: AutoObject = _registered_autoobject_refs[asset_id]
			if registered_ref == null or registered_ref.is_queued_for_deletion():
				set_registered_autoobject_ref(asset_id, autoobject_ref)
	return true


## 取消对 AutoObject 的所有权并清理元数据；由外部移除单个 autoobject 时调用
func release_autoobject(autoobject_ref: AutoObject) -> bool:
	if autoobject_ref == null:
		return false
	var removed := _owned_autoobjects.has(autoobject_ref)
	if removed:
		_owned_autoobjects.erase(autoobject_ref)
	var released_asset_id := int(autoobject_ref.get_meta("spa_asset_id", -1))
	_clear_autoobject_owner_metadata(autoobject_ref)
	if released_asset_id >= 0 and released_asset_id < _registered_autoobject_refs.size():
		if _registered_autoobject_refs[released_asset_id] == autoobject_ref:
			set_registered_autoobject_ref(released_asset_id, _find_owned_autoobject_for_asset(released_asset_id))
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


## 查找 AutoObject 在注册表中的 asset_id；未找到返回 -1
func get_asset_id_for_autoobject(autoobject_ref: AutoObject) -> int:
	if autoobject_ref == null:
		return -1
	for i in range(_registered_autoobject_refs.size()):
		if _registered_autoobject_refs[i] == autoobject_ref:
			return i
	var meta_asset_id := int(autoobject_ref.get_meta("spa_asset_id", -1))
	if meta_asset_id >= 0 and meta_asset_id < _registered_descriptors.size():
		return meta_asset_id
	return -1


## 在自有 AutoObject 中查找绑定了指定 asset_id 的实例；由 pipeline 分配 autoobject 时调用
func _find_owned_autoobject_for_asset(asset_id: int) -> AutoObject:
	_prune_owned_autoobjects()
	for obj in _owned_autoobjects:
		if obj != null and int(obj.get_meta("spa_asset_id", -1)) == asset_id:
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
	var descriptor := autoobject_ref.voxel_descriptor as AssetDescriptor
	if descriptor == null:
		autoobject_ref.get_voxel_color()
		descriptor = autoobject_ref.voxel_descriptor as AssetDescriptor
	if descriptor == null:
		descriptor = AutoObject.create_voxel_descriptor(
			autoobject_ref.voxel_color,
			autoobject_ref.voxel_complexity,
			autoobject_ref.mesh_size * 0.5,
			autoobject_ref.collision,
			autoobject_ref.pivot_variants,
			autoobject_ref.semantic_probe_profile,
			autoobject_ref.semantic_probe_density,
			autoobject_ref.context_sensing_radius
		) as AssetDescriptor
		autoobject_ref.voxel_descriptor = descriptor
	if descriptor == null:
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

## 返回指定 asset_id 的 mesh description 字典（含 mesh 路径、source 路径、标志位等）；由调试与 mesh description buffer 上传路径调用
func get_mesh_description_for_asset(asset_id: int) -> Dictionary:
	if asset_id < 0 or asset_id >= _registered_descriptors.size():
		return {}
	var descriptor := _registered_descriptors[asset_id] as AssetDescriptor
	var mesh_ref: Mesh = _registered_mesh[asset_id] if asset_id < _registered_mesh.size() else null
	var autoobject_ref: AutoObject = _registered_autoobject_refs[asset_id] if asset_id < _registered_autoobject_refs.size() else null
	if mesh_ref == null and descriptor != null:
		mesh_ref = descriptor.get_mesh()

	var source_mesh_ref: Mesh = null
	if descriptor != null:
		source_mesh_ref = descriptor.get_source_mesh()
	if source_mesh_ref == null and autoobject_ref != null:
		source_mesh_ref = autoobject_ref.get_source_mesh()
	if source_mesh_ref == null:
		source_mesh_ref = mesh_ref

	var mesh_aabb := AABB()
	var mesh_surface_count := 0
	if mesh_ref != null:
		mesh_aabb = mesh_ref.get_aabb()
		mesh_surface_count = mesh_ref.get_surface_count()

	var source_mesh_aabb := AABB()
	var source_mesh_surface_count := 0
	if source_mesh_ref != null:
		source_mesh_aabb = source_mesh_ref.get_aabb()
		source_mesh_surface_count = source_mesh_ref.get_surface_count()

	return {
		"asset_id": asset_id,
		"profile_id": _registered_profile_ids[asset_id],
		"descriptor": descriptor,
		"autoobject_ref": autoobject_ref,
		"asset_name": descriptor.asset_id if descriptor != null else "",
		"object_type": descriptor.object_type if descriptor != null else "",
		"object_subtype": "",
		"mesh": mesh_ref,
		"mesh_aabb": mesh_aabb,
		"mesh_surface_count": mesh_surface_count,
		"source_mesh": source_mesh_ref,
		"source_mesh_path": descriptor.source_mesh_path if descriptor != null else "",
		"source_mesh_aabb": source_mesh_aabb,
		"source_mesh_surface_count": source_mesh_surface_count,
	}


## 返回所有已注册资产的 mesh description 字典列表；由调试与外部查询调用
func get_registered_mesh_descriptions() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for asset_id in range(_registered_descriptors.size()):
		result.append(get_mesh_description_for_asset(asset_id))
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


## 强制重新打包并上传 mesh description buffer；由外部在 mesh 变更后主动调用
func refresh_mesh_description_gpu_buffer() -> bool:
	if not is_initialized():
		_last_mesh_description_upload_error = "not_initialized"
		return false
	_mark_mesh_description_changed()
	return _upload_mesh_description_buffer()


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
func ensure_brush_sv_fields() -> Dictionary:
	if _rd == null:
		return {}
	var voxel_count := _sv_field_voxel_count()
	if voxel_count <= 0:
		return {}
	var complexity_byte_count := voxel_count * 4
	var collision_byte_count := SceneVoxelTileCodecScript.r8_word_byte_count(voxel_count)
	if _brush_sv_complexity_buffer.is_valid() and _brush_sv_collision_buffer.is_valid() and _brush_sv_voxel_count == voxel_count:
		return _brush_sv_field_summary(voxel_count, false)
	clear_brush_sv(true)
	_brush_sv_complexity_buffer = storage_buffer_zero(complexity_byte_count, SCOPE_PERSISTENT, "spa_brush_sv_complexity_rgba8")
	_brush_sv_collision_buffer = storage_buffer_zero(collision_byte_count, SCOPE_PERSISTENT, "spa_brush_sv_collision_r8_words")
	if not _brush_sv_complexity_buffer.is_valid() or not _brush_sv_collision_buffer.is_valid():
		clear_brush_sv(true)
		return {}
	_brush_sv_voxel_count = voxel_count
	_brush_sv_has_content = false
	return _brush_sv_field_summary(voxel_count, true)


## 将笔刷体素记录散射进 BrushSV 常驻层（复用 stamp-only 散射 shader；不触碰 committed SV）。
## 记录字段：voxel_xz: Vector2i、slice_index: int、complexity: float、color: Color、collision_strength: float
func stamp_brush_sv_records(records: Array) -> Dictionary:
	if records.is_empty():
		return {"ok": true, "record_count": 0, "gpu_dispatched": false}
	var fields := ensure_brush_sv_fields()
	if fields.is_empty():
		return {"ok": false, "reason": "brush_sv_fields_not_ready", "record_count": records.size(), "gpu_dispatched": false}

	# 按体素去重（后笔胜），保证单次散射 dispatch 内无同体素写竞态
	var deduped: Dictionary = {}
	for raw_record in records:
		if not raw_record is Dictionary:
			continue
		var record := raw_record as Dictionary
		var voxel_xz_value = record.get("voxel_xz", Vector2i(-1, -1))
		if not voxel_xz_value is Vector2i:
			continue
		var voxel_xz: Vector2i = voxel_xz_value
		var slice_index := int(record.get("slice_index", 0))
		var color: Color = record.get("color", Color.WHITE) if record.get("color", Color.WHITE) is Color else Color.WHITE
		var slot := PackedFloat32Array()
		slot.resize(SV_FIELD_RECORD_FLOAT_STRIDE)
		slot[0] = float(voxel_xz.x)
		slot[1] = float(voxel_xz.y)
		slot[2] = float(slice_index)
		slot[3] = clampf(float(record.get("complexity", 1.0)), 0.0, 1.0)
		slot[4] = color.r
		slot[5] = color.g
		slot[6] = color.b
		slot[7] = clampf(float(record.get("collision_strength", 0.0)), 0.0, 1.0)
		deduped[SvFieldScatter.record_key(voxel_xz, slice_index)] = slot
	var record_count := deduped.size()
	if record_count <= 0:
		return {"ok": true, "record_count": 0, "gpu_dispatched": false}
	var floats := SvFieldScatter.flatten_record_slots(deduped)

	var shader := load_compute_shader(SV_FIELD_SCATTER_SHADER, SCOPE_FRAME, "spa_brush_sv_scatter")
	var pipeline := create_compute_pipeline(shader, SCOPE_FRAME, "spa_brush_sv_scatter")
	var record_buffer := storage_buffer_from_floats(floats, SCOPE_FRAME, "spa_brush_sv_scatter_records")
	if not shader.is_valid() or not pipeline.is_valid() or not record_buffer.is_valid():
		gc_frame()
		return {"ok": false, "reason": "brush_sv_scatter_resources_not_ready", "record_count": record_count, "gpu_dispatched": false}
	var set0 := create_uniform_set([
		make_storage_uniform(0, _brush_sv_complexity_buffer),
		make_storage_uniform(1, _brush_sv_collision_buffer),
		make_storage_uniform(2, record_buffer),
	], shader, 0, SCOPE_PASS, "spa_brush_sv_scatter")
	if not set0.is_valid():
		gc_frame()
		return {"ok": false, "reason": "brush_sv_scatter_uniform_set_failed", "record_count": record_count, "gpu_dispatched": false}

	var grid := _sv_field_grid_size()
	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, grid.x)
	push.encode_s32(4, grid.y)
	push.encode_s32(8, record_count)
	push.encode_s32(12, 0)  # write_mode 0：brush 层 overwrite（后笔胜，允许降低/擦除）
	if not _gpu_dispatch_and_sync(pipeline, [set0], push, dispatch_groups_1d(record_count, 64)):
		gc_frame()
		return {"ok": false, "reason": "brush_sv_scatter_dispatch_failed", "record_count": record_count, "gpu_dispatched": false}
	gc_frame()
	_brush_sv_has_content = true
	if _sv_committer != null:
		for raw_record in records:
			if raw_record is Dictionary:
				var record := raw_record as Dictionary
				var voxel_xz_value = record.get("voxel_xz", Vector2i(-1, -1))
				if voxel_xz_value is Vector2i:
					var voxel_min := Vector3i((voxel_xz_value as Vector2i).x, int(record.get("slice_index", 0)), (voxel_xz_value as Vector2i).y)
					_sv_committer.mark_scene_voxel_tile_bounds_dirty(voxel_min, voxel_min + Vector3i.ONE, {"brush": true, "scoring": true}, {"id": "brush_sv_stamp"})
	return {"ok": true, "record_count": record_count, "gpu_dispatched": true}


## 清空 BrushSV 常驻层；release_buffers=true 时连同缓冲一起释放
func clear_brush_sv(release_buffers: bool = false) -> void:
	if release_buffers:
		if _brush_sv_complexity_buffer.is_valid():
			release_rid(_brush_sv_complexity_buffer, false)
		if _brush_sv_collision_buffer.is_valid():
			release_rid(_brush_sv_collision_buffer, false)
		_brush_sv_complexity_buffer = RID()
		_brush_sv_collision_buffer = RID()
		_brush_sv_voxel_count = 0
	else:
		if _brush_sv_complexity_buffer.is_valid():
			buffer_zero(_brush_sv_complexity_buffer, _brush_sv_voxel_count * 4)
		if _brush_sv_collision_buffer.is_valid():
			buffer_zero(_brush_sv_collision_buffer, SceneVoxelTileCodecScript.r8_word_byte_count(_brush_sv_voxel_count))
	_brush_sv_has_content = false


## BrushSV 是否有已写入内容
func has_brush_sv_content() -> bool:
	return _brush_sv_has_content and _brush_sv_complexity_buffer.is_valid()


## BrushSV 常驻层摘要（RID/体素数/内容标志）
func get_brush_sv_field_summary() -> Dictionary:
	return _brush_sv_field_summary(_brush_sv_voxel_count, false)


func _brush_sv_field_summary(voxel_count: int, created: bool) -> Dictionary:
	return {
		"complexity_field_buffer": _brush_sv_complexity_buffer,
		"collision_field_buffer": _brush_sv_collision_buffer,
		"voxel_count": voxel_count,
		"has_content": _brush_sv_has_content,
		"created": created,
	}


## SV field 网格（xz_res, total_slices）：从 committer 网格元数据推导
func _sv_field_grid_size() -> Vector2i:
	if _sv_committer == null:
		return Vector2i.ZERO
	var grid: Vector3i = _sv_committer.grid_size
	return Vector2i(maxi(grid.x, 0), maxi(grid.y, 0))


func _sv_field_voxel_count() -> int:
	if _sv_committer == null:
		return 0
	return VoxelGeneral.voxel_count(_sv_committer.grid_size)


## 按需合成 BlendSV 临时对（committed SV + BrushSV）；对比 TargetSV / 3D score 读取用。
## 返回空字典表示合成失败；无 brush 内容时调用方应直接使用 SV RID（零开销直通）。
func compose_blend_sv_fields(sv_complexity_rid: RID, sv_collision_rid: RID) -> Dictionary:
	if _rd == null or not sv_complexity_rid.is_valid() or not sv_collision_rid.is_valid():
		return {}
	var fields := ensure_brush_sv_fields()
	if fields.is_empty():
		return {}
	var voxel_count := _brush_sv_voxel_count
	var collision_word_count := int(SceneVoxelTileCodecScript.r8_word_byte_count(voxel_count) / 4)
	var complexity_byte_count := voxel_count * 4
	var collision_byte_count := collision_word_count * 4

	if not _blend_sv_complexity_buffer.is_valid() or _blend_sv_voxel_count != voxel_count:
		release_blend_sv_fields()
		_blend_sv_complexity_buffer = storage_buffer_zero(complexity_byte_count, SCOPE_PERSISTENT, "spa_blend_sv_complexity_rgba8")
		_blend_sv_collision_buffer = storage_buffer_zero(collision_byte_count, SCOPE_PERSISTENT, "spa_blend_sv_collision_r8_words")
		if not _blend_sv_complexity_buffer.is_valid() or not _blend_sv_collision_buffer.is_valid():
			release_blend_sv_fields()
			return {}
		_blend_sv_voxel_count = voxel_count

	var shader := load_compute_shader(COMPOSE_BLEND_SV_SHADER, SCOPE_FRAME, "spa_compose_blend_sv")
	var pipeline := create_compute_pipeline(shader, SCOPE_FRAME, "spa_compose_blend_sv")
	if not shader.is_valid() or not pipeline.is_valid():
		gc_frame()
		release_blend_sv_fields()
		return {}
	var set0 := create_uniform_set([
		make_storage_uniform(0, sv_complexity_rid),
		make_storage_uniform(1, sv_collision_rid),
		make_storage_uniform(2, _brush_sv_complexity_buffer),
		make_storage_uniform(3, _brush_sv_collision_buffer),
		make_storage_uniform(4, _blend_sv_complexity_buffer),
		make_storage_uniform(5, _blend_sv_collision_buffer),
	], shader, 0, SCOPE_PASS, "spa_compose_blend_sv")
	if not set0.is_valid():
		gc_frame()
		release_blend_sv_fields()
		return {}
	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, voxel_count)
	push.encode_s32(4, collision_word_count)
	push.encode_s32(8, 0)
	push.encode_s32(12, 0)
	var thread_count := maxi(voxel_count, collision_word_count)
	if not _gpu_dispatch_and_sync(pipeline, [set0], push, dispatch_groups_1d(thread_count, 64)):
		gc_frame()
		release_blend_sv_fields()
		return {}
	gc_frame()
	return {
		"complexity_field_buffer": _blend_sv_complexity_buffer,
		"collision_field_buffer": _blend_sv_collision_buffer,
		"voxel_count": voxel_count,
	}


## 释放 BlendSV 临时合成对（用完即删）
func release_blend_sv_fields() -> void:
	if _blend_sv_complexity_buffer.is_valid():
		release_rid(_blend_sv_complexity_buffer, false)
	if _blend_sv_collision_buffer.is_valid():
		release_rid(_blend_sv_collision_buffer, false)
	_blend_sv_complexity_buffer = RID()
	_blend_sv_collision_buffer = RID()
	_blend_sv_voxel_count = 0


## 结果级 feedback：临时合成 BlendSV，与 TargetSV_B 读取缓冲对比 completely/color 重合度，
## 读回统计后立即删除临时体素。target_visual_rgba8_bytes 的 alpha 即 target completeness。
func score_blendsv_feedback_against_target(
	target_visual_rgba8_bytes: PackedByteArray,
	target_collision_r8_bytes: PackedByteArray = PackedByteArray()
) -> Dictionary:
	if not is_initialized() or _sv_committer == null:
		return {"ok": false, "reason": "actor_or_committer_not_ready"}
	var committed_sv := _sv_committer.get_sv()
	_sv_committer.ensure_scene_voxel_tile_buffers_uploaded(false)
	var handoff := _build_resident_complexity_field_handoff(committed_sv)
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

	var shader := load_compute_shader(BLENDSV_FEEDBACK_SHADER, SCOPE_FRAME, "spa_blendsv_feedback")
	var pipeline := create_compute_pipeline(shader, SCOPE_FRAME, "spa_blendsv_feedback")
	var target_visual_buffer := storage_buffer_from_bytes(target_visual_rgba8_bytes, SCOPE_FRAME, "spa_blendsv_feedback_target_visual")
	var has_target_collision := target_collision_r8_bytes.size() >= SceneVoxelTileCodecScript.r8_word_byte_count(voxel_count)
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
	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, voxel_count)
	push.encode_s32(4, 1 if has_target_collision else 0)
	push.encode_float(8, BLENDSV_FEEDBACK_OCCUPIED_EPSILON)
	push.encode_float(12, BLENDSV_FEEDBACK_QUANT_SCALE)
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
	var completely_diff_sum := float(stats_bytes.decode_u32(12)) / BLENDSV_FEEDBACK_QUANT_SCALE
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
		"completely_diff_mean": completely_diff_sum / float(maxi(int(processed), 1)),
		"color_distance_mean": color_distance_sum / float(maxi(int(overlap), 1)),
	}


# ---------------------------------------------------------------------------
# BrushSV persistence metadata — control plane only
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
	for asset_id in range(_registered_descriptors.size()):
		var description := get_mesh_description_for_asset(asset_id)
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

		var base := asset_id * MESH_DESCRIPTION_STRIDE_BYTES
		bytes.encode_s32(base + 0, asset_id)
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
	return bytes


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
			"asset_id": bytes.decode_s32(base + 0),
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


# ---------------------------------------------------------------------------
# GPU buffer readiness — "always GPU-readable" contract
# ---------------------------------------------------------------------------


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
		_prepare_gpu_runtime_for_scene_voxel_committer()
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
	var setup_result := _prepare_gpu_runtime_for_scene_voxel_committer()
	if _gpu_runtime == null or not _gpu_runtime.is_ready():
		return _autoobject_runtime_action_error("gpu_autoobject_runtime_not_ready", "flush_to_scene_voxel_committer")
	if bool(setup_result.get("blocked", false)):
		return _autoobject_runtime_action_error(
			str(setup_result.get("blocked_reason", setup_result.get("reason", "runtime_scene_voxel_setup_blocked"))),
			"flush_to_scene_voxel_committer"
		)
	var result: Dictionary = _gpu_runtime.flush_to_scene_voxel_committer(_sv_committer, options.duplicate(true))
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
func _prepare_gpu_runtime_for_scene_voxel_committer() -> Dictionary:
	if _gpu_runtime == null:
		_ensure_owned_gpu_runtime()
	if _gpu_runtime == null:
		_gpu_runtime_scene_voxel_setup_result = _gpu_runtime_scene_voxel_setup_blocked("missing_autoobject_gpu_state")
		return _gpu_runtime_scene_voxel_setup_result
	if _sv_committer == null:
		_gpu_runtime_scene_voxel_setup_result = _gpu_runtime_scene_voxel_setup_blocked("missing_scene_voxel_committer")
		return _gpu_runtime_scene_voxel_setup_result
	if not _gpu_runtime.has_method("setup_for_scene_voxel_committer"):
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


## 构造 gpu_runtime SV 配置被阻断的错误报告字典；由 _prepare_gpu_runtime_for_scene_voxel_committer 发现缺失 buffer 时调用
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
	if not bool(placement_result.get("ok", false)):
		result["reason"] = "placement_not_ok"
		result["blocked_reason"] = "placement_not_ok"
		result["resident_gpu_dirty_delta_update_pass_blocked_reason"] = "placement_not_ok"
		result["runtime_ready"] = _gpu_runtime.is_ready()
		return result

	var setup_result := _prepare_gpu_runtime_for_scene_voxel_committer()
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
	var flush_result: Dictionary = _gpu_runtime.flush_to_scene_voxel_committer(_sv_committer, {})
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

## 单独执行 prefilter 阶段（SV→candidate anchors）并返回结果；由外部拆分 pipeline 阶段时调用
func run_autoobject_prefilter(
	sv: Dictionary,
	dirty_tile_ids: Array[int] = [],
	target_read_buffers: Dictionary = {},
	tile_summaries_rid: RID = RID(),
	prefilter_settings: Dictionary = {}
) -> Dictionary:
	if not is_initialized():
		return _pipeline_error("actor_not_initialized")
	if _registered_descriptors.is_empty():
		return _pipeline_error("no_registered_assets")
	var prefilter := _get_prefilter()
	_apply_prefilter_settings(prefilter, prefilter_settings)
	var autoobjects := _build_autoobject_array_for_pipeline()
	var result := prefilter.run_probe_prefilter(
		sv,
		autoobjects,
		dirty_tile_ids,
		_runtime_profile_container,
		target_read_buffers.duplicate(true),
		tile_summaries_rid
	)
	result["control_plane"] = "ScenePlacementActor"
	result["asset_registry_owner"] = "ScenePlacementActor"
	result["runtime_profile_container_owner"] = "ScenePlacementActor"
	result["asset_count"] = _registered_descriptors.size()
	return result


## 将 settings 字典的参数写入 prefilter 实例（anchor_topk 等）；由 run_autoobject_prefilter 与 run_placement_pipeline 调用
func _apply_prefilter_settings(prefilter: AutoObjectProbePrefilterGPU, settings: Dictionary) -> void:
	if prefilter == null:
		return
	if settings.has("anchor_topk"):
		prefilter.anchor_topk = maxi(int(settings.get("anchor_topk", prefilter.anchor_topk)), 1)
	if settings.has("max_complexity_field"):
		prefilter.max_complexity_field = clampf(float(settings.get("max_complexity_field", prefilter.max_complexity_field)), 0.0, 1.0)
	if settings.has("max_collision_field"):
		prefilter.max_collision_field = clampf(float(settings.get("max_collision_field", prefilter.max_collision_field)), 0.0, 1.0)
	if settings.has("min_support"):
		prefilter.min_support = clampf(float(settings.get("min_support", prefilter.min_support)), 0.0, 1.0)
	if settings.has("min_target_interest"):
		prefilter.min_target_interest = clampf(float(settings.get("min_target_interest", prefilter.min_target_interest)), 0.0, 1.0)
	if settings.has("min_prefilter_score"):
		prefilter.min_prefilter_score = clampf(float(settings.get("min_prefilter_score", prefilter.min_prefilter_score)), 0.0, 1.0)
	if settings.has("debug_read_anchors"):
		prefilter.debug_read_anchors = bool(settings.get("debug_read_anchors", prefilter.debug_read_anchors))


# ---------------------------------------------------------------------------
# Pipeline — the main orchestration entry point
# ---------------------------------------------------------------------------

## Run the full placement pipeline for one frame.
##
## Parameters:
##   sv: Dictionary       — SceneVoxel metadata (grid_size, voxel_size,
##                           complexity_field, collision_field, tile_grid_size, ...)
##   dirty_tile_ids: Array[int]            — dirty tile indices for this frame
##   prefilter_topk: int = 4               — per-anchor top-K
##   placement_common: Dictionary = {}     — must include packed TargetSV_B bytes
##
## Returns a Dictionary with:
##   prefilter_result, placement_result, commit_result, profile_probe_pack_summary
## 执行完整 placement pipeline（prefilter→placement→可选 commit）并返回详细结果；SPA 的核心入口，由外部 cook 路径调用
func run_placement_pipeline(
	sv: Dictionary,
	dirty_tile_ids: Array[int] = [],
	prefilter_topk: int = 4,
	placement_common: Dictionary = {}
) -> Dictionary:
	if not is_initialized():
		return _pipeline_error("actor_not_initialized")
	if _registered_descriptors.is_empty():
		return _pipeline_error("no_registered_assets")

	# ---- Phase 0: resident field handoff + BlendSV 合成（SV 纯 auto；读取场按需叠加 brush） ----

	# _rebuild_sv 收尾的 clear_all_dirty 会把 tile staging 重新标脏；handoff 前幂等确保上传就绪
	if _sv_committer != null:
		_sv_committer.ensure_scene_voxel_tile_buffers_uploaded(false)
	var resident_field_handoff := _build_resident_complexity_field_handoff(sv)
	var resident_complexity_field_rid: RID = resident_field_handoff.get("complexity_field_buffer_rid", RID())
	var resident_collision_field_rid: RID = resident_field_handoff.get("collision_field_buffer_rid", RID())

	# 读取场（prefilter / target prep / 3D score 采样）：有 brush 内容时为 BlendSV 临时对，
	# 否则直通 committed SV 常驻对；commit 目标恒为 SV 对（stamp 双写由 VPG flag 控制）。
	var field_read_complexity_rid := resident_complexity_field_rid
	var field_read_collision_rid := resident_collision_field_rid
	var blend_sv_active := false
	if bool(resident_field_handoff.get("ok", false)) and has_brush_sv_content():
		var blend := compose_blend_sv_fields(resident_complexity_field_rid, resident_collision_field_rid)
		if not blend.is_empty():
			field_read_complexity_rid = blend.get("complexity_field_buffer", RID())
			field_read_collision_rid = blend.get("collision_field_buffer", RID())
			blend_sv_active = true

	sv = sv.duplicate()
	if field_read_complexity_rid.is_valid() and field_read_collision_rid.is_valid():
		sv["resident_complexity_field_read_rid"] = field_read_complexity_rid
		sv["resident_collision_field_read_rid"] = field_read_collision_rid

	# ---- Prefilter (SV → candidate voxel regions) ----

	var autoobjects := _build_autoobject_array_for_pipeline()
	var target_buffers := prepare_target_read_buffers_from_common_gpu(placement_common, sv)
	if not bool(target_buffers.get("ok", false)):
		_last_pipeline_result = {
			"ok": false,
			"phase": "target_read_buffers",
			"target_read_buffers": target_buffers,
			"profile_probe_pack": {},
			"mesh_description": get_mesh_description_gpu_buffer_summary(),
			"accepted_placement_writeback_summary": _accepted_placement_writeback_summary_from_placement({}, false),
		}
		if blend_sv_active:
			release_blend_sv_fields()
		return _last_pipeline_result
	var target_field_bytes: PackedFloat32Array = target_buffers.get("target_field_bytes", PackedFloat32Array())
	var mesh_description_summary := get_mesh_description_gpu_buffer_summary()

	var prefilter := _get_prefilter()
	prefilter.anchor_topk = prefilter_topk

	var prefilter_result := prefilter.run_probe_prefilter(
		sv,
		autoobjects,
		dirty_tile_ids,
		_runtime_profile_container,  # ← borrowed GPU probes
		target_buffers,
		sv.get("scene_voxel_tile_summary_gpu_rid", RID())  # ← GPU-first: resident tile summaries RID
	)

	if not bool(prefilter_result.get("ok", false)):
		_last_pipeline_result = {
			"ok": false,
			"phase": "prefilter",
			"prefilter_result": prefilter_result,
			"profile_probe_pack": prefilter_result.get("profile_probe_pack", {}),
			"mesh_description": mesh_description_summary,
			"accepted_placement_writeback_summary": _accepted_placement_writeback_summary_from_placement({}, false),
		}
		if blend_sv_active:
			release_blend_sv_fields()
		return _last_pipeline_result

	var resident_candidate_route_opt_in_requested := _resident_candidate_route_handoff_opt_in_requested(placement_common)
	var use_resident_candidate_route_handoff := _should_use_resident_candidate_route_handoff(
		placement_common,
		prefilter_result
	)
	var resident_candidate_route_handoff := {}
	if use_resident_candidate_route_handoff:
		resident_candidate_route_handoff = _build_resident_candidate_route_handoff(
			prefilter_result,
			prefilter,
			resident_candidate_route_opt_in_requested
		)
		if not bool(resident_candidate_route_handoff.get("ok", false)):
			_last_pipeline_result = {
				"ok": false,
				"phase": "resident_candidate_route_handoff",
				"prefilter_result": prefilter_result,
				"resident_candidate_route_handoff": resident_candidate_route_handoff.get("summary", {}),
				"profile_probe_pack": prefilter_result.get("profile_probe_pack", {}),
				"mesh_description": mesh_description_summary,
				"accepted_placement_writeback_summary": _accepted_placement_writeback_summary_from_placement({}, false),
				"candidate_route_readback_source": "none",
				"candidate_route_runtime_read_source": "none",
				"candidate_route_input_contract": VPGScript._candidate_route_input_contract_from_settings({}),
			}
			if blend_sv_active:
				release_blend_sv_fields()
			return _last_pipeline_result
	else:
		_release_resident_candidate_route_handoff()

	# ---- Phase 1: Placement (candidate regions → placed instances) ----

	var placer := _get_placer()

	var complexity_field := _ensure_float_array(sv.get("complexity_field", PackedFloat32Array()),
		sv.get("grid_size", Vector3i.ZERO))
	var collision_field := _ensure_float_array(sv.get("collision_field", PackedFloat32Array()),
		sv.get("grid_size", Vector3i.ZERO))
	if bool(resident_field_handoff.get("ok", false)):
		complexity_field = PackedFloat32Array()
		collision_field = PackedFloat32Array()

	var asset_defs := _build_placement_asset_defs()

	var placement_settings := placement_common.duplicate(true)
	placement_settings.erase("target_color")
	for route_key in [
		"candidate_voxel_regions_by_asset",
		"candidate_voxel_sparses_by_asset",
		"candidate_voxel_regions",
		"candidate_voxel_sparses",
	]:
		placement_settings.erase(route_key)
	if use_resident_candidate_route_handoff:
		var resident_contract: Dictionary = resident_candidate_route_handoff.get("contract", {})
		placement_settings["candidate_route_readback_source"] = "resident_route_snapshot"
		placement_settings["candidate_route_runtime_read_source"] = "resident"
		placement_settings["candidate_route_input_contract"] = resident_contract
		placement_settings["resident_candidate_route_contract"] = resident_contract
	else:
		# CPU 候选区域回退已移除：无 resident handoff 时不再注入 candidate_voxel_regions_by_asset，
		# 只透传 prefilter 的（none）路由标签，由 VPG 走 all-tiles。
		placement_settings["candidate_route_readback_source"] = str(prefilter_result.get("candidate_route_readback_source", "none"))
		placement_settings["candidate_route_runtime_read_source"] = str(prefilter_result.get("candidate_route_runtime_read_source", "none"))
		placement_settings["candidate_route_input_contract"] = prefilter_result.get("candidate_route_input_contract", {})
	placement_settings["target_color_rgba8_bytes"] = placement_common.get("target_color_rgba8_bytes", PackedByteArray())
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

	var previous_resident_accepted_placement_writeback := false
	var scoped_resident_accepted_placement_writeback := _gpu_runtime != null \
		and _gpu_runtime.is_ready() \
		and _gpu_runtime.has_method("set_use_resident_accepted_placement_writeback") \
		and _gpu_runtime.has_method("get_use_resident_accepted_placement_writeback")
	if scoped_resident_accepted_placement_writeback:
		previous_resident_accepted_placement_writeback = bool(_gpu_runtime.call("get_use_resident_accepted_placement_writeback"))
		_gpu_runtime.call("set_use_resident_accepted_placement_writeback", true)
	var placement_result := placer.run_multi_asset(
		complexity_field,
		collision_field,
		asset_defs,
		sv.get("grid_size", Vector3i.ZERO),
		sv.get("voxel_size", Vector3.ONE),
		sv.get("grid_origin", Vector3.ZERO),
		placement_settings
	)
	if scoped_resident_accepted_placement_writeback:
		_gpu_runtime.call("set_use_resident_accepted_placement_writeback", previous_resident_accepted_placement_writeback)

	# ---- Phase 2: Commit (write accepted placements to SceneVoxel) ----

	var commit_result := {}
	if _sv_committer != null and bool(placement_result.get("ok", false)):
		commit_result = _commit_accepted_placements(placement_result, sv)
	var runtime_dirty_delta_flush_result := _flush_gpu_runtime_dirty_delta_to_scene_voxel_committer(placement_result)
	var accepted_writeback_summary := _accepted_placement_writeback_summary_from_placement(
		placement_result,
		scoped_resident_accepted_placement_writeback
	)
	var compact_state_chain_summary := _compact_state_chain_summary_from_placement(
		placement_result,
		resident_runtime_dirty_delta_ready
	)
	var resident_candidate_route_handoff_summary := _last_resident_candidate_route_handoff.duplicate(true)
	if use_resident_candidate_route_handoff:
		resident_candidate_route_handoff_summary = resident_candidate_route_handoff.get("summary", {}).duplicate(true)
		var placement_route_contract: Dictionary = placement_result.get("candidate_route_input_contract", {})
		var resident_route_ready := bool(placement_route_contract.get("resident_route_input_ready", false))
		resident_candidate_route_handoff_summary["upload_ok"] = bool(resident_candidate_route_handoff_summary.get("ok", false))
		resident_candidate_route_handoff_summary["ok"] = resident_route_ready
		resident_candidate_route_handoff_summary["resident_candidate_route_success"] = resident_route_ready
		resident_candidate_route_handoff_summary["vpg_resident_route_input_ready"] = resident_route_ready
		resident_candidate_route_handoff_summary["vpg_binds_route_buffers"] = bool(placement_route_contract.get("vpg_binds_route_buffers", false))
		resident_candidate_route_handoff_summary["vpg_resident_route_sparse_adapter"] = bool(placement_route_contract.get("resident_route_sparse_adapter", false))
		resident_candidate_route_handoff_summary["vpg_rejection_reason"] = str(placement_route_contract.get("rejection_reason", "none"))
		resident_candidate_route_handoff_summary["vpg_normalized_readback_source"] = str(placement_result.get("candidate_route_readback_source", "none"))
		resident_candidate_route_handoff_summary["vpg_normalized_runtime_read_source"] = str(placement_result.get("candidate_route_runtime_read_source", "none"))
		resident_candidate_route_handoff_summary["vpg_route_buffer_binding_source"] = str(placement_route_contract.get("vpg_route_buffer_binding_source", "none"))
		resident_candidate_route_handoff_summary["vpg_route_buffer_binding_record_reads"] = int(placement_route_contract.get("vpg_route_buffer_binding_record_reads", 0))
		resident_candidate_route_handoff_summary["vpg_route_buffer_binding_range_reads"] = int(placement_route_contract.get("vpg_route_buffer_binding_range_reads", 0))
		resident_candidate_route_handoff_summary["reason"] = "none" if resident_route_ready else str(placement_route_contract.get("rejection_reason", "vpg_route_not_consumed"))

	# ---- Assemble result ----

	_last_pipeline_result = {
		"ok": true,
		"prefilter_result": prefilter_result,
		"placement_result": placement_result,
		"commit_result": commit_result,
		"runtime_dirty_delta_flush_result": runtime_dirty_delta_flush_result,
		"accepted_placement_writeback_summary": accepted_writeback_summary,
		"compact_state_chain_summary": compact_state_chain_summary,
		"resident_candidate_route_handoff": resident_candidate_route_handoff_summary,
		"resident_complexity_field_handoff": resident_field_handoff,
		"scene_voxel_tile_resident_field_handoff": resident_field_handoff,
		"gpu_runtime_scene_voxel_setup": _gpu_runtime_scene_voxel_setup_result.duplicate(true),
		"profile_probe_pack": prefilter_result.get("profile_probe_pack", {}),
		"mesh_description": mesh_description_summary,
		"candidate_regions": {},
		"target_read_buffers": target_buffers,
		"target_read_buffer_summary": placement_result.get("target_read_buffer_summary", prefilter_result.get("target_read_buffer_summary", {})),
		"candidate_route_readback_source": placement_result.get("candidate_route_readback_source", "none"),
		"candidate_route_runtime_read_source": placement_result.get("candidate_route_runtime_read_source", "none"),
		"candidate_route_input_contract": placement_result.get("candidate_route_input_contract", {}),
		"asset_count": _registered_descriptors.size(),
		"blend_sv_active": blend_sv_active,
		"brush_sv_has_content": has_brush_sv_content(),
	}
	if blend_sv_active:
		release_blend_sv_fields()  # BlendSV 临时体素用完即删；BrushSV 常驻保留
	return _last_pipeline_result


## 返回最近一次 run_placement_pipeline 结果的深度副本；供外部在 pipeline 结束后查询详情
func get_last_pipeline_result() -> Dictionary:
	return _last_pipeline_result.duplicate(true)


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


static func _accepted_placement_writeback_summary_from_placement(
	placement_result: Dictionary,
	production_opt_in_enabled: bool
) -> Dictionary:
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
		"production_opt_in_enabled": production_opt_in_enabled,
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
			if d != null:
				var mesh_ref: Mesh = _registered_mesh[i]
				var profile_id := _registered_profile_ids[i]
				wrapper = _make_lightweight_autoobject(d, mesh_ref, i, profile_id)
				_cached_lightweight_wrappers[i] = wrapper
		result.append(wrapper if wrapper != null else null)
	return result.duplicate()


## 构建每个已注册资产的 placement 定义字典（profile_id、descriptor、mesh）；由 run_placement_pipeline 传入 placer 时调用
func _build_placement_asset_defs() -> Array:
	var asset_defs: Array = []
	for asset_id in range(_registered_descriptors.size()):
		var d := _registered_descriptors[asset_id] as AssetDescriptor
		var entry: Dictionary = {
			"descriptor": d,
			"asset_index": asset_id,
			"profile_id": _registered_profile_ids[asset_id],
			"collision": d.get_collision() if d != null else [],
		}
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
	## Only exposes get_semantic_probes() and get_collision() — enough for prefilter.
	## profile_id is the actual GPU profile ID from the actor's registry.
	var obj := AutoObject.new()
	obj.voxel_descriptor = descriptor
	obj.mesh = mesh_ref if mesh_ref != null else descriptor.mesh
	obj.voxel_color = descriptor.get_color()
	obj.voxel_complexity = descriptor.get_complexity()
	obj.semantic_probe_density = descriptor.semantic_probe_density
	obj.context_sensing_radius = descriptor.context_sensing_radius
	obj.collision = descriptor.collision.duplicate(true)
	obj.set_meta("profile_id", profile_id)
	obj.set_meta("asset_id", asset_index)
	return obj


static func _pipeline_error(reason: String) -> Dictionary:
	return {
		"ok": false,
		"phase": "init",
		"reason": reason,
		"prefilter_result": {},
		"placement_result": {},
		"commit_result": {},
		"accepted_placement_writeback_summary": _accepted_placement_writeback_summary_from_placement({}, false),
		"profile_probe_pack": {},
		"candidate_regions": {},
		"asset_count": 0,
	}


static func _ensure_float_array(arr: PackedFloat32Array, grid_size: Vector3i) -> PackedFloat32Array:
	var expected := VoxelGeneral.voxel_count(grid_size)
	if arr.size() >= expected:
		return arr
	var result := arr.duplicate()
	result.resize(maxi(expected, 1))
	return result


static func _expected_target_byte_count(sv: Dictionary) -> int:
	var grid_size: Vector3i = sv.get("grid_size", Vector3i.ZERO)
	return maxi(VoxelGeneral.voxel_count(grid_size), 1) * 4


static func _prepacked_target_bytes(settings: Dictionary, key: String, expected_bytes: int) -> PackedByteArray:
	var raw = settings.get(key, PackedByteArray())
	if not raw is PackedByteArray:
		return PackedByteArray()
	var bytes := raw as PackedByteArray
	if bytes.size() < expected_bytes:
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

## 从 SV 字典构建 GPU-resident complexity field handoff 合约（含 RID 与元数据）；由 run_placement_pipeline 在 prefilter 前调用
func _build_resident_complexity_field_handoff(sv: Dictionary) -> Dictionary:
	var grid_size: Vector3i = sv.get("grid_size", Vector3i.ZERO)
	var expected_voxel_count := VoxelGeneral.voxel_count(grid_size)
	var complexity_buffer_name := SceneVoxelCommitterScript.SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER
	var collision_buffer_name := SceneVoxelCommitterScript.SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER
	var complexity_stride_bytes := SceneVoxelCommitterScript.SCENE_VOXEL_TILE_COMPLEXITY_FIELD_STRIDE_BYTES
	var collision_stride_bytes := SceneVoxelCommitterScript.SCENE_VOXEL_TILE_COLLISION_FIELD_STRIDE_BYTES
	var complexity_expected_byte_count := maxi(expected_voxel_count, 0) * complexity_stride_bytes
	var collision_expected_byte_count := maxi(expected_voxel_count, 0) * collision_stride_bytes
	var collision_expected_upload_byte_count := SceneVoxelTileCodecScript.r8_word_byte_count(expected_voxel_count)
	var summary := {}
	var complexity_rid := RID()
	var collision_rid := RID()

	if expected_voxel_count <= 0:
		return _resident_complexity_field_handoff_summary(false, "invalid_grid_size", expected_voxel_count, summary, complexity_rid, collision_rid)
	if _rd == null:
		return _resident_complexity_field_handoff_summary(false, "no_rendering_device", expected_voxel_count, summary, complexity_rid, collision_rid)
	if _sv_committer == null:
		return _resident_complexity_field_handoff_summary(false, "no_scene_voxel_committer", expected_voxel_count, summary, complexity_rid, collision_rid)
	if not _sv_committer.has_method("get_scene_voxel_tile_gpu_buffer"):
		return _resident_complexity_field_handoff_summary(false, "committer_buffer_api_missing", expected_voxel_count, summary, complexity_rid, collision_rid)
	if not _sv_committer.has_method("get_scene_voxel_tile_gpu_buffer_summary"):
		return _resident_complexity_field_handoff_summary(false, "committer_buffer_summary_api_missing", expected_voxel_count, summary, complexity_rid, collision_rid)

	var committer_rd := GodotComputeShaderBase.rendering_device_of(_sv_committer)
	if committer_rd == null:
		return _resident_complexity_field_handoff_summary(false, "committer_rendering_device_missing", expected_voxel_count, summary, complexity_rid, collision_rid)
	if committer_rd != _rd:
		return _resident_complexity_field_handoff_summary(false, "committer_rendering_device_mismatch", expected_voxel_count, summary, complexity_rid, collision_rid)

	var raw_summary = _sv_committer.call("get_scene_voxel_tile_gpu_buffer_summary")
	if not raw_summary is Dictionary:
		return _resident_complexity_field_handoff_summary(false, "committer_buffer_summary_invalid", expected_voxel_count, summary, complexity_rid, collision_rid)
	summary = raw_summary as Dictionary
	complexity_rid = _sv_committer.call("get_scene_voxel_tile_gpu_buffer", complexity_buffer_name)
	collision_rid = _sv_committer.call("get_scene_voxel_tile_gpu_buffer", collision_buffer_name)

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
	if bool(summary.get("cpu_fallback", false)):
		return _resident_complexity_field_handoff_summary(false, "committer_resident_field_summary_reports_cpu_fallback", expected_voxel_count, summary, complexity_rid, collision_rid)
	if str(summary.get("resident_field_read_source", "none")) != "gpu_storage_buffers":
		return _resident_complexity_field_handoff_summary(false, "committer_resident_field_source_not_gpu_storage_buffers", expected_voxel_count, summary, complexity_rid, collision_rid)
	if bool(summary.get("buffers_stale", false)):
		return _resident_complexity_field_handoff_summary(false, "committer_resident_field_buffers_stale", expected_voxel_count, summary, complexity_rid, collision_rid)
	if not complexity_rid.is_valid() or not collision_rid.is_valid():
		return _resident_complexity_field_handoff_summary(false, "committer_resident_field_rid_invalid", expected_voxel_count, summary, complexity_rid, collision_rid)
	if not bool(complexity_buffer_summary.get("rid_valid", false)) or not bool(collision_buffer_summary.get("rid_valid", false)):
		return _resident_complexity_field_handoff_summary(false, "committer_resident_field_summary_rid_invalid", expected_voxel_count, summary, complexity_rid, collision_rid)
	if complexity_stride != complexity_stride_bytes or collision_stride != collision_stride_bytes:
		return _resident_complexity_field_handoff_summary(false, "committer_resident_field_stride_mismatch", expected_voxel_count, summary, complexity_rid, collision_rid)
	if complexity_format != SceneVoxelCommitterScript.SCENE_VOXEL_TILE_COMPLEXITY_FIELD_FORMAT or collision_format != SceneVoxelCommitterScript.SCENE_VOXEL_TILE_COLLISION_FIELD_FORMAT:
		return _resident_complexity_field_handoff_summary(false, "committer_resident_field_format_mismatch", expected_voxel_count, summary, complexity_rid, collision_rid)
	if complexity_count != expected_voxel_count or collision_count != expected_voxel_count:
		return _resident_complexity_field_handoff_summary(false, "committer_resident_field_record_count_mismatch", expected_voxel_count, summary, complexity_rid, collision_rid)
	if int(complexity_buffer_summary.get("logical_byte_size", complexity_expected_byte_count)) != complexity_expected_byte_count \
			or int(collision_buffer_summary.get("logical_byte_size", collision_expected_byte_count)) != collision_expected_byte_count:
		return _resident_complexity_field_handoff_summary(false, "committer_resident_field_byte_count_mismatch", expected_voxel_count, summary, complexity_rid, collision_rid)
	if int(complexity_buffer_summary.get("upload_byte_size", complexity_expected_byte_count)) < complexity_expected_byte_count \
			or int(collision_buffer_summary.get("upload_byte_size", collision_expected_upload_byte_count)) < collision_expected_upload_byte_count:
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
	var complexity_buffer_name := SceneVoxelCommitterScript.SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER
	var collision_buffer_name := SceneVoxelCommitterScript.SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER
	var buffers: Dictionary = summary.get("buffers", {})
	var complexity_buffer_summary: Dictionary = buffers.get(complexity_buffer_name, {})
	var collision_buffer_summary: Dictionary = buffers.get(collision_buffer_name, {})
	var complexity_count := int(complexity_buffer_summary.get("record_count", summary.get("complexity_field_voxel_count", 0)))
	var collision_count := int(collision_buffer_summary.get("record_count", summary.get("collision_field_voxel_count", 0)))
	return {
		"ok": ok,
		"resident_complexity_field_handoff": ok,
		"reason": reason,
		"source": "SceneVoxelCommitter.get_scene_voxel_tile_gpu_buffer_summary" if not summary.is_empty() else "none",
		"producer": "SceneVoxelCommitter",
		"owner": "SceneVoxelCommitter" if ok else "none",
		"borrowed_from": "SceneVoxelCommitter" if ok else "none",
		"complexity_field_buffer_rid": complexity_rid if ok else RID(),
		"collision_field_buffer_rid": collision_rid if ok else RID(),
		"runtime_ready": bool(summary.get("runtime_ready", false)),
		"resident_field_read_source": str(summary.get("resident_field_read_source", "none")),
		"runtime_read_source": str(summary.get("runtime_read_source", "none")),
		"buffers_stale": bool(summary.get("buffers_stale", false)),
		"uploaded_revision_matches_staging": bool(summary.get("uploaded_revision_matches_staging", false)),
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
# Candidate Route Handoff
# --------------------------------------------------------------------------

## 检查 placement_common 字典中是否请求使用 resident candidate route handoff；由 pipeline 决策路径调用
func _resident_candidate_route_handoff_opt_in_requested(placement_common: Dictionary) -> bool:
	return placement_common.has(RESIDENT_CANDIDATE_ROUTE_OPT_IN_KEY) \
		and bool(placement_common.get(RESIDENT_CANDIDATE_ROUTE_OPT_IN_KEY, false))


## 综合判断当前条件下是否应启用 resident candidate route GPU handoff；由 pipeline 调用
func _should_use_resident_candidate_route_handoff(
	placement_common: Dictionary,
	prefilter_result: Dictionary
) -> bool:
	if placement_common.has(RESIDENT_CANDIDATE_ROUTE_OPT_IN_KEY):
		return bool(placement_common.get(RESIDENT_CANDIDATE_ROUTE_OPT_IN_KEY, false))
	return _prefilter_result_has_candidate_route_records(prefilter_result)


## 检查 prefilter 结果中是否包含有效的 candidate route records 与 ranges；由 handoff 决策路径调用
func _prefilter_result_has_candidate_route_records(prefilter_result: Dictionary) -> bool:
	var raw_payload = prefilter_result.get("candidate_route_handoff_payload", {})
	if raw_payload is Dictionary:
		var payload := raw_payload as Dictionary
		if not payload.is_empty():
			if bool(payload.get("ok", false)) \
				and (bool(payload.get("has_records", false)) or int(payload.get("record_count", 0)) > 0):
				return true
	for route_key in [
		"candidate_voxel_regions_by_asset",
		"candidate_voxel_sparses_by_asset",
	]:
		if _candidate_route_regions_have_entries(prefilter_result.get(route_key, {})):
			return true
	return false


## 检查 regions_by_asset 中是否存在至少一条非空 region 条目；由 _prefilter_result_has_candidate_route_records 调用
func _candidate_route_regions_have_entries(raw_regions_by_asset: Variant) -> bool:
	if not raw_regions_by_asset is Dictionary:
		return false
	var regions_by_asset := raw_regions_by_asset as Dictionary
	for asset_key in regions_by_asset.keys():
		var regions = regions_by_asset.get(asset_key)
		if regions is Array and not (regions as Array).is_empty():
			return true
		if regions is PackedInt32Array and (regions as PackedInt32Array).size() > 0:
			return true
		if regions is PackedVector3Array and (regions as PackedVector3Array).size() > 0:
			return true
	return false


## 释放 resident candidate route GPU 缓冲（records/ranges）并重置计数与摘要；由 dispose、pipeline 开始和公开 release 入口调用
func _release_resident_candidate_route_handoff() -> void:
	if _resident_candidate_route_record_buffer.is_valid():
		if _resident_candidate_route_buffers_borrowed:
			untrack_rid(_resident_candidate_route_record_buffer)
		else:
			release_rid(_resident_candidate_route_record_buffer)
	if _resident_candidate_route_range_buffer.is_valid():
		if _resident_candidate_route_buffers_borrowed:
			untrack_rid(_resident_candidate_route_range_buffer)
		else:
			release_rid(_resident_candidate_route_range_buffer)
	_resident_candidate_route_record_buffer = RID()
	_resident_candidate_route_range_buffer = RID()
	_resident_candidate_route_record_count = 0
	_resident_candidate_route_range_count = 0
	_resident_candidate_route_buffers_borrowed = false
	_resident_candidate_route_revision += 1
	_last_resident_candidate_route_handoff = {
		"ok": false,
		"resident_candidate_route_handoff": false,
		"resident_candidate_route_handoff_opt_in": false,
		"resident_candidate_route_handoff_defaulted": false,
		"reason": "released",
		"record_count": 0,
		"range_count": 0,
		"source_label": "none",
	}


## 将 prefilter 结果的 candidate route 打包上传为 GPU storage buffer 并保存 RID；由 run_placement_pipeline 在 placement 阶段前调用
func _build_resident_candidate_route_handoff(
	prefilter_result: Dictionary,
	prefilter: AutoObjectProbePrefilterGPU,
	opt_in_requested: bool = false
) -> Dictionary:
	_release_resident_candidate_route_handoff()
	if _rd == null:
		return _resident_candidate_route_handoff_blocked("no_rendering_device", {}, opt_in_requested)

	# GPU-first：路由 payload 只来自 prefilter 的 GPU pack pass。
	# CPU 区域回退已随重构移除（candidate_voxel_regions_by_asset 恒为空），
	# payload 为空时下面的 ok 校验会直接走 blocked 分支。
	var payload: Dictionary = prefilter_result.get("candidate_route_handoff_payload", {})
	if not bool(payload.get("ok", false)):
		return _resident_candidate_route_handoff_blocked(str(payload.get("reason", "payload_not_ready")), payload, opt_in_requested)

	if _payload_has_borrowable_resident_candidate_route(payload, prefilter):
		_resident_candidate_route_record_buffer = track_borrowed_rid(
			payload.get("resident_route_record_rid", RID()),
			KIND_BUFFER,
			SCOPE_PERSISTENT,
			"prefilter_resident_candidate_route_records"
		)
		_resident_candidate_route_range_buffer = track_borrowed_rid(
			payload.get("resident_route_range_rid", RID()),
			KIND_BUFFER,
			SCOPE_PERSISTENT,
			"prefilter_resident_candidate_route_ranges"
		)
		_resident_candidate_route_buffers_borrowed = true
	else:
		var record_bytes: PackedByteArray = payload.get("record_bytes", PackedByteArray())
		var range_bytes: PackedByteArray = payload.get("range_bytes", PackedByteArray())
		if record_bytes.is_empty() and int(payload.get("record_count", 0)) > 0:
			return _resident_candidate_route_handoff_blocked("record_bytes_missing_for_upload", payload, opt_in_requested)
		if range_bytes.is_empty() and int(payload.get("range_count", 0)) > 0:
			return _resident_candidate_route_handoff_blocked("range_bytes_missing_for_upload", payload, opt_in_requested)
		var record_upload_bytes := record_bytes
		if record_upload_bytes.is_empty():
			record_upload_bytes.resize(4)
		var range_upload_bytes := range_bytes
		if range_upload_bytes.is_empty():
			range_upload_bytes.resize(4)

		var record_rid := track_rid(
			_rd.storage_buffer_create(record_upload_bytes.size(), record_upload_bytes),
			KIND_BUFFER,
			SCOPE_PERSISTENT,
			"spa_resident_candidate_route_records"
		)
		if not record_rid.is_valid():
			return _resident_candidate_route_handoff_blocked("record_buffer_create_failed", payload, opt_in_requested)

		var range_rid := track_rid(
			_rd.storage_buffer_create(range_upload_bytes.size(), range_upload_bytes),
			KIND_BUFFER,
			SCOPE_PERSISTENT,
			"spa_resident_candidate_route_ranges"
		)
		if not range_rid.is_valid():
			release_rid(record_rid)
			return _resident_candidate_route_handoff_blocked("range_buffer_create_failed", payload, opt_in_requested)

		_resident_candidate_route_record_buffer = record_rid
		_resident_candidate_route_range_buffer = range_rid
		_resident_candidate_route_buffers_borrowed = false
	_resident_candidate_route_record_count = int(payload.get("record_count", 0))
	_resident_candidate_route_range_count = int(payload.get("range_count", 0))
	_resident_candidate_route_revision += 1

	var contract := _resident_candidate_route_contract_from_payload(payload)
	var summary := _resident_candidate_route_handoff_summary_from_payload(payload, true, "ok", opt_in_requested)
	summary["contract"] = _resident_candidate_route_contract_summary(contract)
	_last_resident_candidate_route_handoff = summary
	return {
		"ok": true,
		"resident_candidate_route_handoff": true,
		"resident_candidate_route_handoff_opt_in": opt_in_requested,
		"resident_candidate_route_handoff_defaulted": not opt_in_requested,
		"reason": "ok",
		"payload": payload,
		"contract": contract,
		"summary": summary,
	}


## 判断 payload 中是否携带可复用的 resident candidate route GPU 缓冲；由 placement 阶段跳过重上传时调用
func _payload_has_borrowable_resident_candidate_route(payload: Dictionary, prefilter: AutoObjectProbePrefilterGPU) -> bool:
	if int(payload.get("schema_version", CANDIDATE_ROUTE_SCHEMA_VERSION)) != CANDIDATE_ROUTE_SCHEMA_VERSION:
		return false
	if int(payload.get("record_stride_bytes", CANDIDATE_ROUTE_RECORD_STRIDE_BYTES)) != CANDIDATE_ROUTE_RECORD_STRIDE_BYTES:
		return false
	if int(payload.get("range_stride_bytes", CANDIDATE_ROUTE_RANGE_STRIDE_BYTES)) != CANDIDATE_ROUTE_RANGE_STRIDE_BYTES:
		return false
	var record_rid: RID = payload.get("resident_route_record_rid", RID())
	var range_rid: RID = payload.get("resident_route_range_rid", RID())
	if not record_rid.is_valid() or not range_rid.is_valid():
		return false
	if not bool(payload.get("resident_route_record_rid_valid", true)) \
	   or not bool(payload.get("resident_route_range_rid_valid", true)):
		return false
	if not bool(payload.get("same_rendering_device_as_vpg", false)):
		return false
	return prefilter != null and prefilter.get_rendering_device() == _rd


## 检查 candidate route handoff 是否因缺少必要缓冲而被阻断；返回阻断原因字典或空字典；由 placement pass 前调用
func _resident_candidate_route_handoff_blocked(
	reason: String,
	payload: Dictionary,
	opt_in_requested: bool = false
) -> Dictionary:
	_release_resident_candidate_route_handoff()
	var summary := _resident_candidate_route_handoff_summary_from_payload(payload, false, reason, opt_in_requested)
	_last_resident_candidate_route_handoff = summary
	return {
		"ok": false,
		"resident_candidate_route_handoff": false,
		"resident_candidate_route_handoff_opt_in": opt_in_requested,
		"resident_candidate_route_handoff_defaulted": not opt_in_requested,
		"reason": reason,
		"payload": payload,
		"contract": {},
		"summary": summary,
	}


## 从 payload 字典提取 resident candidate route 合约（RID/count/schema）；由 pipeline 组装 placer 输入时调用
func _resident_candidate_route_contract_from_payload(payload: Dictionary) -> Dictionary:
	var payload_owner := str(payload.get("resident_route_buffer_owner", "AutoObjectProbePrefilterGPU"))
	var route_owner := payload_owner if _resident_candidate_route_buffers_borrowed else "ScenePlacementActor"
	var route_lifetime := "ScenePlacementActor owned until next route build, asset registry mutation, dispose, or explicit release"
	if _resident_candidate_route_buffers_borrowed:
		route_lifetime = str(payload.get(
			"resident_route_buffer_lifetime",
			"AutoObjectProbePrefilterGPU owned until next route pack, dispose, or explicit release"
		))
	# 仅保留 VPG 实际读取的键（_candidate_route_input_contract_from_settings +
	# _prepare_candidate_route_binding）。重复的 *_bytes / *_count fallback 与纯 provenance
	# 镜像字段已删——VPG 都按主键优先读取。
	return {
		"resident_route_record_rid": _resident_candidate_route_record_buffer,
		"resident_route_range_rid": _resident_candidate_route_range_buffer,
		"resident_route_record_stride": CANDIDATE_ROUTE_RECORD_STRIDE_BYTES,
		"resident_route_range_stride": CANDIDATE_ROUTE_RANGE_STRIDE_BYTES,
		"resident_route_record_capacity": _resident_candidate_route_record_count,
		"resident_route_range_count": _resident_candidate_route_range_count,
		"schema_version": CANDIDATE_ROUTE_SCHEMA_VERSION,
		"same_rendering_device_as_vpg": true,
		"cpu_expanded_route_input": bool(payload.get("cpu_expanded_route_input", false)),
		"direct_all_tiles": false,
		"owner": route_owner,
		"resident_route_buffer_lifetime": route_lifetime,
		"asset_count": _registered_descriptors.size(),
		"profile_count": _registered_profile_ids.size(),
	}


## 将 candidate route 合约转换为可序列化摘要字典；由 pipeline result 组装时调用
func _resident_candidate_route_contract_summary(contract: Dictionary) -> Dictionary:
	var summary := contract.duplicate(true)
	if summary.has("resident_route_record_rid"):
		summary["resident_route_record_rid"] = "valid" if _resident_candidate_route_record_buffer.is_valid() else "none"
	if summary.has("resident_route_range_rid"):
		summary["resident_route_range_rid"] = "valid" if _resident_candidate_route_range_buffer.is_valid() else "none"
	return summary


## 从 payload 提取完整 candidate route handoff 摘要（含 resident buffer 状态）；由 pipeline result 组装时调用
func _resident_candidate_route_handoff_summary_from_payload(
	payload: Dictionary,
	ok: bool,
	reason: String,
	opt_in_requested: bool = false
) -> Dictionary:
	# 诊断摘要：下游仅读取 ok（run_placement_pipeline 的 upload_ok），其余为透出到
	# pipeline 结果的可观测字段。常量(schema/stride)、重复(owner/producer)、占位计数已删。
	return {
		"ok": ok,
		"resident_candidate_route_handoff": ok,
		"resident_candidate_route_handoff_opt_in": opt_in_requested,
		"resident_candidate_route_handoff_defaulted": not opt_in_requested,
		"reason": reason,
		"record_count": int(payload.get("record_count", 0)),
		"range_count": int(payload.get("range_count", 0)),
		"asset_count": int(payload.get("asset_count", _registered_descriptors.size())),
		"source_label": str(payload.get("source_label", CANDIDATE_ROUTE_CPU_PACK_SOURCE_LABEL)),
		"record_rid": "valid" if ok and _resident_candidate_route_record_buffer.is_valid() else "none",
		"range_rid": "valid" if ok and _resident_candidate_route_range_buffer.is_valid() else "none",
		"resident_route_buffer_borrowed": ok and _resident_candidate_route_buffers_borrowed,
		"resident_route_buffer_owner": str(payload.get("resident_route_buffer_owner", "ScenePlacementActor")) if ok and _resident_candidate_route_buffers_borrowed else "ScenePlacementActor" if ok else "none",
		"status": str(payload.get("status", "")),
	}



# --------------------------------------------------------------------------
# Target Read Buffer Handoff
# --------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Asset registration — descriptors go GPU-resident immediately
# ---------------------------------------------------------------------------

## 释放 resident target read GPU 缓冲并重置摘要；由 _dispose_internal 和 pipeline 开始时调用
func _release_resident_target_read_buffer_handoff() -> void:
	if _resident_target_color_rgba8_buffer.is_valid():
		release_rid(_resident_target_color_rgba8_buffer)
	_resident_target_color_rgba8_buffer = RID()
	_resident_target_read_buffer_voxel_count = 0
	_resident_target_read_buffer_byte_count = 0
	_resident_target_read_buffer_revision += 1
	_last_resident_target_read_buffer_handoff = _resident_target_read_buffer_handoff_summary(false, "released", 0, 0, "", Vector3i.ZERO)


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
		safe_target_field_byte_count = maxi(voxel_count, 0) * 16
	return {
		"ok": ok,
		"resident_target_read_buffer_handoff": ok,
		"reason": reason,
		"owner": "ScenePlacementActor" if ok else "none",
		"producer": "ScenePlacementActorTargetReadBuffers",
		"rendering_device": _rd if ok else null,
		"target_color_rgba8_buffer": _resident_target_color_rgba8_buffer if ok else RID(),
		"target_color_rgba8_byte_count": expected_bytes if ok else 0,
		"target_field_buffer": _resident_target_color_rgba8_buffer if ok else RID(),
		"resident_target_field_buffer": _resident_target_color_rgba8_buffer if ok else RID(),
		"target_field_buffer_rid": "valid" if ok and _resident_target_color_rgba8_buffer.is_valid() else "none",
		"target_field_byte_count": safe_target_field_byte_count if ok else 0,
		"target_field_stride_bytes": 16 if ok else 0,
		"target_field_format": "vec4" if ok else "none",
		"voxel_count": voxel_count if ok else 0,
		"expected_byte_count": expected_bytes,
		"target_color_source": color_source,
		"target_color_format": "rgba8_u32" if ok else "none",
		"target_read_buffer_lifetime": "ScenePlacementActor owned until next target read-buffer prep, dispose, or explicit release" if ok else "none",
		"dispatch_groups": dispatch_groups if ok else Vector3i.ZERO,
		"cpu_fallback": false,
		"gpu_first": true,
	}


## 从 SV 字典按 key 取出 PackedFloat32Array 并校验长度；长度不符时返回空数组；由 prepare_target_read_buffers_from_common_gpu 调用
func _sv_float_field(sv: Dictionary, key: String, target_length: int) -> PackedFloat32Array:
	var field: PackedFloat32Array = PackedFloat32Array(sv.get(key, PackedFloat32Array()))
	if field.size() >= target_length:
		return field.slice(0, target_length)
	var result := PackedFloat32Array()
	result.resize(target_length)
	for i in range(mini(field.size(), target_length)):
		result[i] = field[i]
	return result


## 从 SV complexity/collision field 构建 GPU-resident target read buffer 合约（用于 prefilter 目标评分）；由 run_placement_pipeline 与外部拆分 pipeline 时调用
func prepare_target_read_buffers_from_common_gpu(settings: Dictionary, sv: Dictionary) -> Dictionary:
	# GPU-specialized: combines target color + completely (max(complexity_field, collision_field)) into a single vec4 target_field buffer.
	# completely == 0 means the voxel is empty (nothing there).
	log_name = "ScenePlacementActorTargetReadBuffers"
	_release_resident_target_read_buffer_handoff()
	var expected_bytes := _expected_target_byte_count(sv)
	var voxel_count := maxi(int(expected_bytes / 4), 1)
	var target_field_byte_count := voxel_count * 16  # vec4 = 16 bytes per voxel
	var resident_handoff_enabled := bool(settings.get(RESIDENT_TARGET_READ_BUFFERS_OPT_IN_KEY, true))
	var debug_readback_requested := _target_read_buffer_debug_readback_requested(settings)
	var source_color := _prepacked_target_bytes(settings, "target_color_rgba8_bytes", expected_bytes)
	var color_valid := not source_color.is_empty()
	var color_source := "target_color_rgba8_bytes" if color_valid else "zero_filled"

	if not ensure_device(true, false):
		return {
			"ok": false,
			"reason": "missing_rendering_device",
			"gpu_first": true,
			"cpu_fallback": false,
			"expected_byte_count": expected_bytes,
			"voxel_count": voxel_count,
			"resident_target_read_buffer_handoff": false,
			"resident_target_read_buffer_handoff_summary": _resident_target_read_buffer_handoff_summary(
				false,
				"missing_rendering_device",
				expected_bytes,
				voxel_count,
				color_source,
				Vector3i.ZERO
			),
		}

	var shader := load_compute_shader("res://shaders/pack_target_field.glsl", SCOPE_FRAME, "prepare_target_read_buffers")
	var pipeline := create_compute_pipeline(shader, SCOPE_FRAME, "prepare_target_read_buffers")
	if not shader.is_valid() or not pipeline.is_valid():
		gc_frame()
		return {
			"ok": false,
			"reason": "target_read_buffer_prep_shader_not_ready",
			"gpu_first": true,
			"cpu_fallback": false,
			"expected_byte_count": expected_bytes,
			"voxel_count": voxel_count,
			"resident_target_read_buffer_handoff": false,
			"resident_target_read_buffer_handoff_summary": _resident_target_read_buffer_handoff_summary(
				false,
				"target_read_buffer_prep_shader_not_ready",
				expected_bytes,
				voxel_count,
				color_source,
				Vector3i.ZERO
			),
		}

	var zero_bytes := PackedByteArray()
	zero_bytes.resize(expected_bytes)
	var color_input_buffer := storage_buffer_from_bytes(
		source_color if color_valid else zero_bytes,
		SCOPE_FRAME,
		"target_read_color_input_rgba8_u32"
	)

	# 场景 completely 输入：优先绑定 sv 携带的常驻 8-bit field 读取对（BlendSV 或 committed SV，
	# 格式与本 shader 输入契约一致，零拷贝）；无常驻 RID 时回退 CPU debug 投影打包。
	var raw_resident_complexity = sv.get("resident_complexity_field_read_rid", RID())
	var raw_resident_collision = sv.get("resident_collision_field_read_rid", RID())
	var resident_complexity_input: RID = raw_resident_complexity if raw_resident_complexity is RID else RID()
	var resident_collision_input: RID = raw_resident_collision if raw_resident_collision is RID else RID()
	var use_resident_field_inputs := resident_complexity_input.is_valid() and resident_collision_input.is_valid()
	var complexity_input_buffer := resident_complexity_input
	var collision_input_buffer := resident_collision_input
	if not use_resident_field_inputs:
		var complexity_field := _sv_float_field(sv, "complexity_field", voxel_count * 4)  # vec4 = 4 floats per voxel
		var collision_field := _sv_float_field(sv, "collision_field", voxel_count)
		complexity_input_buffer = storage_buffer_from_bytes(
			SceneVoxelTileCodecScript.pack_complexity_field_rgba8_bytes(complexity_field, voxel_count),
			SCOPE_FRAME,
			"target_read_complexity_input_rgba8"
		)
		collision_input_buffer = storage_buffer_from_bytes(
			SceneVoxelTileCodecScript.pack_collision_field_r8_word_bytes(collision_field, voxel_count),
			SCOPE_FRAME,
			"target_read_collision_input_r8_words"
		)

	var output_scope := SCOPE_PERSISTENT if resident_handoff_enabled else SCOPE_FRAME
	var target_field_output_buffer := storage_buffer_zero(target_field_byte_count, output_scope, "target_field_out_vec4")
	if (
		not color_input_buffer.is_valid()
		or not complexity_input_buffer.is_valid()
		or not collision_input_buffer.is_valid()
		or not target_field_output_buffer.is_valid()
	):
		if resident_handoff_enabled:
			release_rid(target_field_output_buffer)
		gc_frame()
		return {
			"ok": false,
			"reason": "target_read_buffer_prep_storage_buffer_failed",
			"gpu_first": true,
			"cpu_fallback": false,
			"expected_byte_count": expected_bytes,
			"voxel_count": voxel_count,
			"resident_target_read_buffer_handoff": false,
			"resident_target_read_buffer_handoff_summary": _resident_target_read_buffer_handoff_summary(
				false,
				"target_read_buffer_prep_storage_buffer_failed",
				expected_bytes,
				voxel_count,
				color_source,
				Vector3i.ZERO
			),
		}

	var set0 := create_uniform_set([
		make_storage_uniform(0, color_input_buffer),
		make_storage_uniform(1, complexity_input_buffer),
		make_storage_uniform(2, collision_input_buffer),
		make_storage_uniform(3, target_field_output_buffer),
	], shader, 0, SCOPE_PASS, "prepare_target_read_buffers")
	if not set0.is_valid():
		if resident_handoff_enabled:
			release_rid(target_field_output_buffer)
		gc_frame()
		return {
			"ok": false,
			"reason": "target_read_buffer_prep_uniform_set_failed",
			"gpu_first": true,
			"cpu_fallback": false,
			"expected_byte_count": expected_bytes,
			"voxel_count": voxel_count,
			"resident_target_read_buffer_handoff": false,
			"resident_target_read_buffer_handoff_summary": _resident_target_read_buffer_handoff_summary(
				false,
				"target_read_buffer_prep_uniform_set_failed",
				expected_bytes,
				voxel_count,
				color_source,
				Vector3i.ZERO
			),
		}

	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, voxel_count)
	push.encode_s32(4, 0)
	push.encode_s32(8, 0)
	push.encode_s32(12, 0)

	var groups := dispatch_groups_1d(voxel_count, 64)
	var cl := begin_compute_list()
	if cl < 0:
		if resident_handoff_enabled:
			release_rid(target_field_output_buffer)
		gc_frame()
		return {
			"ok": false,
			"reason": "target_read_buffer_prep_compute_list_begin_failed",
			"gpu_first": true,
			"cpu_fallback": false,
			"expected_byte_count": expected_bytes,
			"voxel_count": voxel_count,
			"resident_target_read_buffer_handoff": false,
			"resident_target_read_buffer_handoff_summary": _resident_target_read_buffer_handoff_summary(
				false,
				"target_read_buffer_prep_compute_list_begin_failed",
				expected_bytes,
				voxel_count,
				color_source,
				Vector3i.ZERO
			),
		}
	_gpu_dispatch_pipeline_sets(cl, pipeline, [set0], push, groups)
	end_compute_list()
	submit_and_sync()

	if resident_handoff_enabled:
		var rid_ok := target_field_output_buffer.is_valid()
		var target_field_bytes := PackedFloat32Array()
		if rid_ok and debug_readback_requested:
			target_field_bytes = _rd.buffer_get_data(target_field_output_buffer, 0, target_field_byte_count).to_float32_array()
			if target_field_bytes.size() != voxel_count * 4:
				release_rid(target_field_output_buffer)
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

		_resident_target_color_rgba8_buffer = target_field_output_buffer
		_resident_target_read_buffer_voxel_count = voxel_count
		_resident_target_read_buffer_byte_count = target_field_byte_count
		_resident_target_read_buffer_revision += 1
		var resident_summary := _resident_target_read_buffer_handoff_summary(
			_resident_target_color_rgba8_buffer.is_valid(),
			"ok" if _resident_target_color_rgba8_buffer.is_valid() else "resident_target_read_buffer_rid_invalid",
			expected_bytes,
			voxel_count,
			color_source,
			groups,
			target_field_byte_count
		)
		_last_resident_target_read_buffer_handoff = resident_summary
		rid_ok = _resident_target_color_rgba8_buffer.is_valid()
		gc_frame()
		return {
			"ok": rid_ok,
			"reason": "ok" if rid_ok else "resident_target_read_buffer_rid_invalid",
			"gpu_first": true,
			"cpu_fallback": false,
			"target_field_bytes": target_field_bytes,
			"expected_byte_count": expected_bytes,
			"target_field_byte_count": target_field_byte_count,
			"voxel_count": voxel_count,
			"target_color_source": color_source,
			"target_field_format": "vec4",
			"target_field_stride_bytes": 16,
			"dispatch_groups": groups,
			"resident_target_read_buffer_handoff": rid_ok,
			"resident_target_read_buffer_handoff_summary": resident_summary,
			"rendering_device": _rd if rid_ok else null,
			"target_field_buffer": _resident_target_color_rgba8_buffer,
			"resident_target_field_buffer": _resident_target_color_rgba8_buffer,
			"resident_target_read_buffer_owner": "ScenePlacementActor" if rid_ok else "none",
			"resident_target_read_buffer_lifetime": str(resident_summary.get("target_read_buffer_lifetime", "ScenePlacementActor owned until next target read-buffer prep, dispose, or explicit release")),
		}

	# Non-resident path: read back bytes for debug/legacy consumers.
	var target_field_buf := _rd.buffer_get_data(target_field_output_buffer, 0, target_field_byte_count)
	var target_field_bytes := target_field_buf.to_float32_array()
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
	_last_resident_target_read_buffer_handoff = resident_summary

	return {
		"ok": true,
		"reason": "ok",
		"gpu_first": true,
		"cpu_fallback": false,
		"target_field_bytes": target_field_bytes,
		"expected_byte_count": expected_bytes,
		"target_field_byte_count": target_field_byte_count,
		"voxel_count": voxel_count,
		"target_color_source": color_source,
		"target_field_format": "vec4",
		"target_field_stride_bytes": 16,
		"dispatch_groups": groups,
		"resident_target_read_buffer_handoff": false,
		"resident_target_read_buffer_handoff_summary": resident_summary,
		"rendering_device": null,
		"target_field_buffer": RID(),
		"resident_target_field_buffer": RID(),
		"resident_target_read_buffer_owner": "none",
		"resident_target_read_buffer_lifetime": "none",
	}


## Use prepare_target_read_buffers_from_common_gpu() for all target read paths.
## The deprecated static helper target_read_buffers_from_common() has been removed.
