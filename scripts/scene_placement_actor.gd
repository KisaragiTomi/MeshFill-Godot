class_name ScenePlacementActor
extends "res://scripts/godot_compute_shader_base.gd"

## Central orchestrator for the MeshFill placement pipeline.
##
## Owns the descriptor → GPU profile buffer lifecycle so that AutoVoxelDescriptor
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
const GPUAutoObjectRuntimeScript := preload("res://scripts/gpu_autoobject_runtime.gd")

const MESH_DESCRIPTION_BUFFER := "mesh_description"
const MESH_DESCRIPTION_STRIDE_BYTES := 128
const MESH_DESCRIPTION_FLAG_HAS_MESH := 1
const MESH_DESCRIPTION_FLAG_HAS_SOURCE_MESH := 2
const MESH_DESCRIPTION_FLAG_SOURCE_DIFFERS := 4
const MESH_DESCRIPTION_FLAG_HAS_SOURCE_PATH := 8
const TARGET_READ_BUFFER_PREP_SHADER := "res://shaders/prepare_target_read_buffers.glsl"
const TARGET_READ_BUFFER_PREP_LOCAL_SIZE := 64
const RESIDENT_CANDIDATE_ROUTE_OPT_IN_KEY := "use_resident_candidate_route_handoff"
const CANDIDATE_ROUTE_SCHEMA_VERSION := 1
const CANDIDATE_ROUTE_RECORD_STRIDE_BYTES := 16
const CANDIDATE_ROUTE_RANGE_STRIDE_BYTES := 16
const CANDIDATE_ROUTE_CPU_PACK_SOURCE_LABEL := "gpu_vote_buffer_readback_cpu_pack"

# ---------------------------------------------------------------------------
# Fields
# ---------------------------------------------------------------------------

## Owned profile container — all registered descriptors live here, GPU-resident.
var _runtime_profile_container: AutoVoxelRuntimeProfileContainer

## External references (borrowed, not owned).
var _sv_committer: SceneVoxelCommitter
var _gpu_runtime: GPUAutoObjectRuntime

## Asset registry — parallel arrays mapping asset_id → descriptor + profile_id.
var _registered_descriptors: Array[AutoVoxelDescriptor] = []
var _registered_profile_ids: Array[int] = []
var _registered_mesh: Array[Mesh] = []
var _registered_autoobject_refs: Array[AutoObject] = []
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
var _last_resident_candidate_route_handoff: Dictionary = {}

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

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func initialize(
	prefer_local_device: bool = true,
	allow_global_fallback: bool = true,
	sv_committer: SceneVoxelCommitter = null,
	gpu_runtime: GPUAutoObjectRuntime = null
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

	if sv_committer != null:
		attach_sv_committer(sv_committer)
	if gpu_runtime != null:
		attach_gpu_runtime(gpu_runtime)

	_prepare_gpu_runtime_for_scene_voxel_committer()
	_initialized = true
	return true


func dispose(sync_before_free: bool = true) -> void:
	_dispose_internal(sync_before_free)
	super.dispose()


func _dispose_internal(sync_before_free: bool = true) -> void:
	_free_cached_wrappers()
	_release_resident_candidate_route_handoff()
	_release_mesh_description_buffer()

	if _runtime_profile_container != null:
		_runtime_profile_container.dispose(sync_before_free)
		_runtime_profile_container = null

	if _prefilter != null:
		_prefilter.dispose()
		_prefilter = null

	if _placer != null:
		_placer.dispose()
		_placer = null

	_registered_descriptors.clear()
	_registered_profile_ids.clear()
	_registered_mesh.clear()
	_registered_autoobject_refs.clear()
	_last_pipeline_result.clear()
	_brush_sv_control_metadata.clear()
	_gpu_runtime_scene_voxel_setup_result.clear()

	_initialized = false
	_sv_committer = null
	_gpu_runtime = null


func is_initialized() -> bool:
	return _initialized and _rd != null and _runtime_profile_container != null


# ---------------------------------------------------------------------------
# External reference attachment
# ---------------------------------------------------------------------------

func attach_sv_committer(sv_committer: SceneVoxelCommitter) -> void:
	_sv_committer = sv_committer
	_prepare_gpu_runtime_for_scene_voxel_committer()


func attach_gpu_runtime(gpu_runtime: GPUAutoObjectRuntime) -> void:
	_gpu_runtime = gpu_runtime
	_prepare_gpu_runtime_for_scene_voxel_committer()


func get_sv_committer() -> SceneVoxelCommitter:
	return _sv_committer


func get_gpu_runtime() -> GPUAutoObjectRuntime:
	return _gpu_runtime


func get_runtime_profile_container() -> AutoVoxelRuntimeProfileContainer:
	return _runtime_profile_container


func release_resident_candidate_route_handoff() -> void:
	_release_resident_candidate_route_handoff()


func get_resident_candidate_route_handoff_summary() -> Dictionary:
	return _last_resident_candidate_route_handoff.duplicate(true)


# ---------------------------------------------------------------------------
# Asset registration — descriptors go GPU-resident immediately
# ---------------------------------------------------------------------------

## Register a single AutoVoxelDescriptor.  Returns its profile_id (>=0) or -1
## on failure.  The descriptor's probes, collision, and pivots are immediately
## uploaded to GPU via the owned profile container.
func register_asset(descriptor: AutoVoxelDescriptor, mesh_ref: Mesh = null, autoobject_ref: AutoObject = null) -> int:
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
	_mark_mesh_description_changed()

	if not _upload_mesh_description_buffer():
		push_error("ScenePlacementActor: failed to upload mesh descriptions to GPU.")
		return -1

	return profile_id


## Register multiple descriptors at once.  Returns an Array of profile_ids
## (parallel to the input array).  -1 means registration failed for that entry.
func register_assets(descriptors: Array[AutoVoxelDescriptor]) -> Array[int]:
	var result: Array[int] = []
	for d in descriptors:
		result.append(register_asset(d))
	return result


## Replace the entire asset registry with a new list.  Old GPU data is
## invalidated and re-uploaded.
func replace_all_assets(
	descriptors: Array[AutoVoxelDescriptor],
	meshes: Array = [],
	autoobjects: Array = []
) -> bool:
	clear_assets()

	for i in range(descriptors.size()):
		var d := descriptors[i] as AutoVoxelDescriptor
		var m: Mesh = meshes[i] as Mesh if i < meshes.size() else null
		var ao: AutoObject = autoobjects[i] as AutoObject if i < autoobjects.size() else null
		if register_asset(d, m, ao) < 0:
			return false
	return true


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
	_mark_mesh_description_changed()
	_release_mesh_description_buffer()


func get_asset_count() -> int:
	return _registered_descriptors.size()


func is_asset_registry_empty() -> bool:
	return _registered_descriptors.is_empty()


func get_registered_descriptors() -> Array[AutoVoxelDescriptor]:
	return _registered_descriptors.duplicate()


func get_registered_profile_ids() -> Array[int]:
	return _registered_profile_ids.duplicate()


func get_profile_id_for_asset(asset_id: int) -> int:
	if asset_id < 0 or asset_id >= _registered_profile_ids.size():
		return -1
	return _registered_profile_ids[asset_id]


func get_registered_meshes() -> Array[Mesh]:
	return _registered_mesh.duplicate()


func get_mesh_description_for_asset(asset_id: int) -> Dictionary:
	if asset_id < 0 or asset_id >= _registered_descriptors.size():
		return {}
	var descriptor := _registered_descriptors[asset_id] as AutoVoxelDescriptor
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
		"object_subtype": descriptor.object_subtype if descriptor != null else "",
		"mesh": mesh_ref,
		"mesh_aabb": mesh_aabb,
		"mesh_surface_count": mesh_surface_count,
		"source_mesh": source_mesh_ref,
		"source_mesh_path": descriptor.source_mesh_path if descriptor != null else "",
		"source_mesh_aabb": source_mesh_aabb,
		"source_mesh_surface_count": source_mesh_surface_count,
	}


func get_registered_mesh_descriptions() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for asset_id in range(_registered_descriptors.size()):
		result.append(get_mesh_description_for_asset(asset_id))
	return result


func get_mesh_description_buffer() -> RID:
	if not is_mesh_description_gpu_ready():
		return RID()
	return _mesh_description_buffer


func is_mesh_description_gpu_ready() -> bool:
	return _rd != null \
		and _mesh_description_buffer.is_valid() \
		and _mesh_description_uploaded_revision == _mesh_description_revision \
		and _mesh_description_record_count == _registered_descriptors.size()


func refresh_mesh_description_gpu_buffer() -> bool:
	if not is_initialized():
		_last_mesh_description_upload_error = "not_initialized"
		return false
	_mark_mesh_description_changed()
	return _upload_mesh_description_buffer()


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
# BrushSV persistence metadata — control plane only
# ---------------------------------------------------------------------------

func set_brush_sv_persistence_metadata(metadata: Dictionary) -> Dictionary:
	var clean := _brush_sv_control_metadata_from(metadata)
	clean["owner"] = "ScenePlacementActor"
	clean["control_plane_only"] = true
	clean["content_mirror"] = false
	_brush_sv_control_metadata = clean
	return get_brush_sv_persistence_metadata()


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


func get_brush_sv_persistence_metadata() -> Dictionary:
	return _brush_sv_control_metadata.duplicate(true)


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
		or lowered == "scene_field" \
		or lowered == "collision_field" \
		or lowered == "target_occupancy" \
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

func is_gpu_ready() -> bool:
	if not is_initialized():
		return false
	if _runtime_profile_container == null:
		return false
	return _runtime_profile_container.is_runtime_ready() and is_mesh_description_gpu_ready()


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
func get_probe_records_buffer() -> RID:
	if not is_gpu_ready():
		return RID()
	return _runtime_profile_container.get_probe_buffer()


func get_profile_table_buffer() -> RID:
	if not is_gpu_ready():
		return RID()
	return _runtime_profile_container.get_profile_table_buffer()


func get_collision_records_buffer() -> RID:
	if not is_gpu_ready():
		return RID()
	return _runtime_profile_container.get_collision_buffer()


func get_pivot_records_buffer() -> RID:
	if not is_gpu_ready():
		return RID()
	return _runtime_profile_container.get_pivot_buffer()


func get_merged_gpu_buffer_summary() -> Dictionary:
	var report := get_gpu_readiness_report()
	if _gpu_runtime != null:
		report["gpu_runtime"] = {
			"ready": _gpu_runtime.is_ready(),
			"max_objects": _gpu_runtime.max_objects,
		}
		report["gpu_runtime_scene_voxel_setup"] = _gpu_runtime_scene_voxel_setup_result.duplicate(true)
	if _sv_committer != null:
		report["sv_committer_attached"] = true
	if not _brush_sv_control_metadata.is_empty():
		report["brush_sv"] = get_brush_sv_persistence_metadata()
	return report


# ---------------------------------------------------------------------------
# Pipeline — the main orchestration entry point
# ---------------------------------------------------------------------------

## Run the full placement pipeline for one frame.
##
## Parameters:
##   sv: Dictionary       — SceneVoxel metadata (grid_size, voxel_size,
##                           scene_field, collision_field, tile_grid_size, ...)
##   dirty_tile_ids: Array[int]            — dirty tile indices for this frame
##   prefilter_topk: int = 4               — per-anchor top-K
##   placement_common: Dictionary = {}     — must include packed TargetSV_B bytes
##
## Returns a Dictionary with:
##   prefilter_result, placement_result, commit_result, profile_probe_pack_summary
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

	# ---- Phase 0: Prefilter (SV → candidate voxel regions) ----

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
		return _last_pipeline_result
	var target_color_rgba8: PackedByteArray = target_buffers.get("target_color_rgba8_bytes", PackedByteArray())
	var target_occupancy_bytes: PackedByteArray = target_buffers.get("target_occupancy_bytes", PackedByteArray())
	var mesh_description_summary := get_mesh_description_gpu_buffer_summary()

	var prefilter := _get_prefilter()
	prefilter.anchor_topk = prefilter_topk

	var prefilter_result := prefilter.run_probe_prefilter(
		sv,
		autoobjects,
		dirty_tile_ids,
		_runtime_profile_container,  # ← borrowed GPU probes
		target_color_rgba8,
		target_occupancy_bytes
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
		return _last_pipeline_result

	var candidate_regions: Dictionary = prefilter_result.get("candidate_voxel_regions_by_asset", {})
	var use_resident_candidate_route_handoff := _resident_candidate_route_handoff_opt_in(placement_common)
	var resident_candidate_route_handoff := {}
	if use_resident_candidate_route_handoff:
		resident_candidate_route_handoff = _build_resident_candidate_route_handoff(prefilter_result, prefilter, sv)
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
			return _last_pipeline_result
	else:
		_release_resident_candidate_route_handoff()

	# ---- Phase 1: Placement (candidate regions → placed instances) ----

	var scene_field := _ensure_float_array(sv.get("scene_field", PackedFloat32Array()),
		sv.get("grid_size", Vector3i.ZERO))
	var collision_field := _ensure_float_array(sv.get("collision_field", PackedFloat32Array()),
		sv.get("grid_size", Vector3i.ZERO))

	var asset_defs := _build_placement_asset_defs()

	var placement_settings := placement_common.duplicate(true)
	placement_settings.erase("target_occupancy")
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
		placement_settings["candidate_voxel_regions_by_asset"] = candidate_regions
		placement_settings["candidate_route_readback_source"] = str(prefilter_result.get("candidate_route_readback_source", "none"))
		placement_settings["candidate_route_runtime_read_source"] = str(prefilter_result.get("candidate_route_runtime_read_source", "none"))
		placement_settings["candidate_route_input_contract"] = prefilter_result.get("candidate_route_input_contract", {})
	placement_settings["target_color_rgba8_bytes"] = target_color_rgba8
	placement_settings["target_occupancy_bytes"] = target_occupancy_bytes
	placement_settings["auto_voxel_runtime_profile_container"] = _runtime_profile_container
	placement_settings["mesh_description_buffer"] = get_mesh_description_buffer()
	placement_settings["mesh_description_buffer_summary"] = mesh_description_summary.duplicate(true)
	if _gpu_runtime != null:
		placement_settings["gpu_autoobject_runtime"] = _gpu_runtime
		placement_settings["write_accepted_placements_to_gpu_runtime"] = true

	var placer := _get_placer()
	var previous_resident_accepted_placement_writeback := false
	var scoped_resident_accepted_placement_writeback := _gpu_runtime != null \
		and _gpu_runtime.has_method("set_use_resident_accepted_placement_writeback") \
		and _gpu_runtime.has_method("get_use_resident_accepted_placement_writeback")
	if scoped_resident_accepted_placement_writeback:
		previous_resident_accepted_placement_writeback = bool(_gpu_runtime.call("get_use_resident_accepted_placement_writeback"))
		_gpu_runtime.call("set_use_resident_accepted_placement_writeback", true)
	var placement_result := placer.run_multi_asset(
		scene_field,
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
		"resident_candidate_route_handoff": resident_candidate_route_handoff_summary,
		"gpu_runtime_scene_voxel_setup": _gpu_runtime_scene_voxel_setup_result.duplicate(true),
		"profile_probe_pack": prefilter_result.get("profile_probe_pack", {}),
		"mesh_description": mesh_description_summary,
		"candidate_regions": candidate_regions,
		"candidate_route_readback_source": placement_result.get("candidate_route_readback_source", "none"),
		"candidate_route_runtime_read_source": placement_result.get("candidate_route_runtime_read_source", "none"),
		"candidate_route_input_contract": placement_result.get("candidate_route_input_contract", {}),
		"asset_count": _registered_descriptors.size(),
	}
	return _last_pipeline_result


func get_last_pipeline_result() -> Dictionary:
	return _last_pipeline_result.duplicate(true)


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

func _get_prefilter() -> AutoObjectProbePrefilterGPU:
	if _prefilter == null:
		_prefilter = PrefilterScript.new()
		_prefilter.attach_rendering_device(_rd, false)
	return _prefilter


func _get_placer() -> VoxelPlacementGenerator:
	if _placer == null:
		_placer = VPGScript.new()
		_placer.attach_rendering_device(_rd, false)
	return _placer


func _resident_candidate_route_handoff_opt_in(placement_common: Dictionary) -> bool:
	return bool(placement_common.get(RESIDENT_CANDIDATE_ROUTE_OPT_IN_KEY, false))


func _release_resident_candidate_route_handoff() -> void:
	if _resident_candidate_route_record_buffer.is_valid():
		release_rid(_resident_candidate_route_record_buffer)
	if _resident_candidate_route_range_buffer.is_valid():
		release_rid(_resident_candidate_route_range_buffer)
	_resident_candidate_route_record_buffer = RID()
	_resident_candidate_route_range_buffer = RID()
	_resident_candidate_route_record_count = 0
	_resident_candidate_route_range_count = 0
	_resident_candidate_route_revision += 1
	_last_resident_candidate_route_handoff = {
		"ok": false,
		"resident_candidate_route_handoff": false,
		"resident_candidate_route_handoff_opt_in": false,
		"reason": "released",
		"record_count": 0,
		"range_count": 0,
		"source_label": "none",
	}


func _build_resident_candidate_route_handoff(
	prefilter_result: Dictionary,
	prefilter: AutoObjectProbePrefilterGPU,
	sv: Dictionary
) -> Dictionary:
	_release_resident_candidate_route_handoff()
	if _rd == null:
		return _resident_candidate_route_handoff_blocked("no_rendering_device", {})

	var grid_size: Vector3i = sv.get("grid_size", Vector3i.ZERO)
	var tile_grid := Vector3i(
		ceili(float(grid_size.x) / float(PrefilterScript.TILE_SIZE)),
		ceili(float(grid_size.y) / float(PrefilterScript.TILE_SIZE)),
		ceili(float(grid_size.z) / float(PrefilterScript.TILE_SIZE))
	)
	var tile_count := tile_grid.x * tile_grid.y * tile_grid.z
	var payload: Dictionary = prefilter_result.get("candidate_route_handoff_payload", {})
	if payload.is_empty():
		var candidate_regions: Dictionary = prefilter_result.get("candidate_voxel_regions_by_asset", {})
		payload = prefilter.build_candidate_route_handoff_payload(
			candidate_regions,
			_registered_descriptors.size(),
			tile_grid,
			tile_count
		)
	if not bool(payload.get("ok", false)):
		return _resident_candidate_route_handoff_blocked(str(payload.get("reason", "payload_not_ready")), payload)

	var record_bytes: PackedByteArray = payload.get("record_bytes", PackedByteArray())
	var range_bytes: PackedByteArray = payload.get("range_bytes", PackedByteArray())
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
		return _resident_candidate_route_handoff_blocked("record_buffer_create_failed", payload)

	var range_rid := track_rid(
		_rd.storage_buffer_create(range_upload_bytes.size(), range_upload_bytes),
		KIND_BUFFER,
		SCOPE_PERSISTENT,
		"spa_resident_candidate_route_ranges"
	)
	if not range_rid.is_valid():
		release_rid(record_rid)
		return _resident_candidate_route_handoff_blocked("range_buffer_create_failed", payload)

	_resident_candidate_route_record_buffer = record_rid
	_resident_candidate_route_range_buffer = range_rid
	_resident_candidate_route_record_count = int(payload.get("record_count", 0))
	_resident_candidate_route_range_count = int(payload.get("range_count", 0))
	_resident_candidate_route_revision += 1

	var contract := _resident_candidate_route_contract_from_payload(payload)
	var summary := _resident_candidate_route_handoff_summary_from_payload(payload, true, "ok")
	summary["contract"] = _resident_candidate_route_contract_summary(contract)
	_last_resident_candidate_route_handoff = summary
	return {
		"ok": true,
		"resident_candidate_route_handoff": true,
		"resident_candidate_route_handoff_opt_in": true,
		"reason": "ok",
		"payload": payload,
		"contract": contract,
		"summary": summary,
	}


func _resident_candidate_route_handoff_blocked(reason: String, payload: Dictionary) -> Dictionary:
	_release_resident_candidate_route_handoff()
	var summary := _resident_candidate_route_handoff_summary_from_payload(payload, false, reason)
	_last_resident_candidate_route_handoff = summary
	return {
		"ok": false,
		"resident_candidate_route_handoff": false,
		"resident_candidate_route_handoff_opt_in": true,
		"reason": reason,
		"payload": payload,
		"contract": {},
		"summary": summary,
	}


func _resident_candidate_route_contract_from_payload(payload: Dictionary) -> Dictionary:
	return {
		"owner": "ScenePlacementActor",
		"resident_route_owner": "ScenePlacementActor",
		"producer": "AutoObjectProbePrefilterGPU",
		"resident_route_producer": "AutoObjectProbePrefilterGPU",
		"source": "AutoObjectProbePrefilterGPU",
		"source_label": CANDIDATE_ROUTE_CPU_PACK_SOURCE_LABEL,
		"resident_route_source_label": CANDIDATE_ROUTE_CPU_PACK_SOURCE_LABEL,
		"resident_route_readback_source_label": CANDIDATE_ROUTE_CPU_PACK_SOURCE_LABEL,
		"schema_version": CANDIDATE_ROUTE_SCHEMA_VERSION,
		"resident_route_schema_version": CANDIDATE_ROUTE_SCHEMA_VERSION,
		"resident_route_record_rid": _resident_candidate_route_record_buffer,
		"resident_route_range_rid": _resident_candidate_route_range_buffer,
		"resident_route_record_rid_valid": _resident_candidate_route_record_buffer.is_valid(),
		"resident_route_range_rid_valid": _resident_candidate_route_range_buffer.is_valid(),
		"same_rendering_device_as_vpg": true,
		"rendering_device_matches_vpg": true,
		"resident_route_record_stride": CANDIDATE_ROUTE_RECORD_STRIDE_BYTES,
		"resident_route_record_stride_bytes": CANDIDATE_ROUTE_RECORD_STRIDE_BYTES,
		"resident_route_range_stride": CANDIDATE_ROUTE_RANGE_STRIDE_BYTES,
		"resident_route_range_stride_bytes": CANDIDATE_ROUTE_RANGE_STRIDE_BYTES,
		"resident_route_record_capacity": _resident_candidate_route_record_count,
		"resident_route_record_count": _resident_candidate_route_record_count,
		"resident_route_range_count": _resident_candidate_route_range_count,
		"asset_count": _registered_descriptors.size(),
		"profile_count": _registered_profile_ids.size(),
		"resident_route_buffer_lifetime": "ScenePlacementActor owned until next route build, asset registry mutation, dispose, or explicit release",
		"resident_route_buffer_owner": "ScenePlacementActor",
		"resident_route_debug_status": str(payload.get("debug_status", "")),
		"resident_route_payload_status": str(payload.get("status", "")),
		"resident_route_readback_derived": bool(payload.get("readback_derived", true)),
		"cpu_expanded_route_input": false,
		"direct_all_tiles": false,
	}


func _resident_candidate_route_contract_summary(contract: Dictionary) -> Dictionary:
	var summary := contract.duplicate(true)
	if summary.has("resident_route_record_rid"):
		summary["resident_route_record_rid"] = "valid" if _resident_candidate_route_record_buffer.is_valid() else "none"
	if summary.has("resident_route_range_rid"):
		summary["resident_route_range_rid"] = "valid" if _resident_candidate_route_range_buffer.is_valid() else "none"
	return summary


func _resident_candidate_route_handoff_summary_from_payload(payload: Dictionary, ok: bool, reason: String) -> Dictionary:
	return {
		"ok": ok,
		"resident_candidate_route_handoff": ok,
		"resident_candidate_route_handoff_opt_in": true,
		"reason": reason,
		"schema_version": int(payload.get("schema_version", CANDIDATE_ROUTE_SCHEMA_VERSION)),
		"record_stride_bytes": int(payload.get("record_stride_bytes", CANDIDATE_ROUTE_RECORD_STRIDE_BYTES)),
		"range_stride_bytes": int(payload.get("range_stride_bytes", CANDIDATE_ROUTE_RANGE_STRIDE_BYTES)),
		"record_count": int(payload.get("record_count", 0)),
		"range_count": int(payload.get("range_count", 0)),
		"asset_count": int(payload.get("asset_count", _registered_descriptors.size())),
		"source_label": str(payload.get("source_label", CANDIDATE_ROUTE_CPU_PACK_SOURCE_LABEL)),
		"producer": str(payload.get("producer", "AutoObjectProbePrefilterGPU")),
		"owner": "ScenePlacementActor" if ok else "none",
		"record_rid": "valid" if ok and _resident_candidate_route_record_buffer.is_valid() else "none",
		"range_rid": "valid" if ok and _resident_candidate_route_range_buffer.is_valid() else "none",
		"readback_derived": bool(payload.get("readback_derived", true)),
		"debug_status": str(payload.get("debug_status", "")),
		"status": str(payload.get("status", "")),
		"duplicate_tile_id_count": int(payload.get("duplicate_tile_id_count", 0)),
		"invalid_tile_id_count": int(payload.get("invalid_tile_id_count", 0)),
		"empty_range_count": int(payload.get("empty_range_count", 0)),
	}


func _prepare_gpu_runtime_for_scene_voxel_committer() -> Dictionary:
	if _gpu_runtime == null:
		_gpu_runtime_scene_voxel_setup_result = _gpu_runtime_scene_voxel_setup_blocked("missing_gpu_autoobject_runtime")
		return _gpu_runtime_scene_voxel_setup_result
	if _sv_committer == null:
		_gpu_runtime_scene_voxel_setup_result = _gpu_runtime_scene_voxel_setup_blocked("missing_scene_voxel_committer")
		return _gpu_runtime_scene_voxel_setup_result
	if not _gpu_runtime.has_method("setup_for_scene_voxel_committer"):
		_gpu_runtime_scene_voxel_setup_result = _gpu_runtime_scene_voxel_setup_blocked("missing_runtime_scene_voxel_setup_helper")
		return _gpu_runtime_scene_voxel_setup_result

	if _gpu_runtime.has_method("get_rendering_device") and _sv_committer.has_method("get_rendering_device"):
		var runtime_rd = _gpu_runtime.call("get_rendering_device")
		var committer_rd = _sv_committer.call("get_rendering_device")
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
			_gpu_runtime_scene_voxel_setup_result["runtime_setup_api"] = "GPUAutoObjectRuntime.setup_for_scene_voxel_committer"
			return _gpu_runtime_scene_voxel_setup_result

	var setup_result: Dictionary = _gpu_runtime.setup_for_scene_voxel_committer(
		_sv_committer,
		_gpu_runtime.max_objects,
		true
	)
	setup_result["source"] = "ScenePlacementActor"
	setup_result["owner"] = "ScenePlacementActor"
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


func _gpu_runtime_scene_voxel_setup_blocked(reason: String) -> Dictionary:
	return {
		"ok": false,
		"reason": reason,
		"blocked": true,
		"blocked_reason": reason,
		"source": "ScenePlacementActor",
		"owner": "ScenePlacementActor",
		"runtime_setup_api": "GPUAutoObjectRuntime.setup_for_scene_voxel_committer",
		"runtime_ready": false,
		"gpu_first": true,
		"cpu_fallback": false,
		"readback_source": "none",
		"rendering_device_source": "none",
		"same_rendering_device": false,
		"resident_gpu_dirty_delta_update_pass_opt_in_ready": false,
	}


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
		"resident_gpu_dirty_delta_update_pass_opt_in": true,
		"resident_gpu_dirty_delta_update_pass_blocked_reason": "not_attempted",
	}
	if _gpu_runtime == null:
		result["reason"] = "missing_gpu_autoobject_runtime"
		result["blocked_reason"] = "missing_gpu_autoobject_runtime"
		result["resident_gpu_dirty_delta_update_pass_blocked_reason"] = "missing_gpu_autoobject_runtime"
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

	var flush_result: Dictionary = _gpu_runtime.flush_to_scene_voxel_committer(_sv_committer, {
		"use_resident_gpu_dirty_delta_update_pass": true,
	})
	flush_result["source"] = "ScenePlacementActor"
	flush_result["owner"] = "ScenePlacementActor"
	flush_result["runtime_flush_api"] = "GPUAutoObjectRuntime.flush_to_scene_voxel_committer"
	flush_result["runtime_setup"] = setup_result.duplicate(true)
	flush_result["resident_gpu_dirty_delta_update_pass_opt_in"] = true
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


func _free_cached_wrappers() -> void:
	for asset_index in _cached_lightweight_wrappers:
		var wrapper: AutoObject = _cached_lightweight_wrappers[asset_index]
		if wrapper != null and not wrapper.is_queued_for_deletion():
			wrapper.queue_free()
	_cached_lightweight_wrappers.clear()


func _mark_mesh_description_changed() -> void:
	_mesh_description_revision += 1
	_mesh_description_uploaded_revision = -1


func _release_mesh_description_buffer() -> void:
	if _mesh_description_buffer.is_valid():
		release_rid(_mesh_description_buffer)
	_mesh_description_buffer = RID()
	_mesh_description_record_count = 0
	_mesh_description_logical_byte_size = 0
	_mesh_description_gpu_byte_size = 0
	_mesh_description_uploaded_revision = -1


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
		bytes.encode_u32(base + 96, _stable_u32_hash(str(description.get("asset_name", ""))))
		bytes.encode_u32(base + 100, _stable_u32_hash(str(description.get("object_type", ""))))
		bytes.encode_u32(base + 104, _stable_u32_hash(str(description.get("object_subtype", ""))))
		bytes.encode_u32(base + 108, _stable_u32_hash(source_path))
		bytes.encode_float(base + 112, mesh_aabb.size.length())
		bytes.encode_float(base + 116, maxf(mesh_aabb.size.x, maxf(mesh_aabb.size.y, mesh_aabb.size.z)))
		bytes.encode_float(base + 120, source_mesh_aabb.size.length())
		bytes.encode_float(base + 124, maxf(source_mesh_aabb.size.x, maxf(source_mesh_aabb.size.y, source_mesh_aabb.size.z)))
	return bytes


static func _encode_aabb(bytes: PackedByteArray, base: int, aabb: AABB) -> void:
	bytes.encode_float(base + 0, aabb.position.x)
	bytes.encode_float(base + 4, aabb.position.y)
	bytes.encode_float(base + 8, aabb.position.z)
	bytes.encode_float(base + 12, 0.0)
	bytes.encode_float(base + 16, aabb.size.x)
	bytes.encode_float(base + 20, aabb.size.y)
	bytes.encode_float(base + 24, aabb.size.z)
	bytes.encode_float(base + 28, 0.0)


static func _decode_mesh_description_bytes(bytes: PackedByteArray, record_count: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var available_bytes := mini(bytes.size(), record_count * MESH_DESCRIPTION_STRIDE_BYTES)
	available_bytes -= available_bytes % MESH_DESCRIPTION_STRIDE_BYTES
	var available := mini(record_count, int(available_bytes / MESH_DESCRIPTION_STRIDE_BYTES))
	for i in range(available):
		var base := i * MESH_DESCRIPTION_STRIDE_BYTES
		var mesh_aabb := AABB(
			Vector3(bytes.decode_float(base + 32), bytes.decode_float(base + 36), bytes.decode_float(base + 40)),
			Vector3(bytes.decode_float(base + 48), bytes.decode_float(base + 52), bytes.decode_float(base + 56))
		)
		var source_mesh_aabb := AABB(
			Vector3(bytes.decode_float(base + 64), bytes.decode_float(base + 68), bytes.decode_float(base + 72)),
			Vector3(bytes.decode_float(base + 80), bytes.decode_float(base + 84), bytes.decode_float(base + 88))
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


static func _stable_u32_hash(value: String) -> int:
	var h := 2166136261
	for i in range(value.length()):
		h = (h ^ value.unicode_at(i)) & 0xffffffff
		h = (h * 16777619) & 0xffffffff
	return h


## Build an array of AutoObject-like references for the prefilter.
## Uses live AutoObject refs when available; falls back to cached lightweight
## wrappers that are recreated when the registry changes.
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
			var d: AutoVoxelDescriptor = _registered_descriptors[i]
			if d != null:
				var mesh_ref: Mesh = _registered_mesh[i]
				var profile_id := _registered_profile_ids[i]
				wrapper = _make_lightweight_autoobject(d, mesh_ref, i, profile_id)
				_cached_lightweight_wrappers[i] = wrapper
		result.append(wrapper if wrapper != null else null)
	return result.duplicate()


## Build asset_defs for VoxelPlacementGenerator.run_multi_asset().
## Each entry carries asset identity/profile data; route data stays in common_settings.
func _build_placement_asset_defs() -> Array:
	var asset_defs: Array = []
	for asset_id in range(_registered_descriptors.size()):
		var d := _registered_descriptors[asset_id] as AutoVoxelDescriptor
		var entry: Dictionary = {
			"descriptor": d,
			"asset_index": asset_id,
			"profile_id": _registered_profile_ids[asset_id],
			"collision": d.get_collision() if d != null else [],
		}
		asset_defs.append(entry)
	return asset_defs


## Commit accepted placements to the SceneVoxelCommitter.
func _commit_accepted_placements(placement_result: Dictionary, sv: Dictionary) -> Dictionary:
	var committed := 0
	var committed_ids: Array[Dictionary] = []

	var accepted: Array = placement_result.get("accepted_placements", [])
	for raw in accepted:
		if not raw is Dictionary:
			continue
		var record: Dictionary = raw
		if _sv_committer != null:
			var commit := _sv_committer.apply_voxel_write_spec(record, false)
			if not commit.is_empty():
				committed += 1
				committed_ids.append({
					"id": str(commit.get("id", "")),
					"voxel_min": record.get("voxel_min", Vector3i.ZERO),
					"voxel_max": record.get("voxel_max", Vector3i.ZERO),
				})

	return {
		"ok": true,
		"committed": committed,
		"total_accepted": accepted.size(),
		"committed_ids": committed_ids,
	}


static func _make_lightweight_autoobject(descriptor: AutoVoxelDescriptor, mesh_ref: Mesh, asset_index: int, profile_id: int) -> AutoObject:
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
	var expected := grid_size.x * grid_size.y * grid_size.z
	if arr.size() >= expected:
		return arr
	var result := arr.duplicate()
	result.resize(maxi(expected, 1))
	return result


static func _expected_target_byte_count(sv: Dictionary) -> int:
	var grid_size: Vector3i = sv.get("grid_size", Vector3i.ZERO)
	return maxi(grid_size.x * grid_size.y * grid_size.z, 1) * 4


static func _prepacked_target_bytes(settings: Dictionary, key: String, expected_bytes: int) -> PackedByteArray:
	var raw = settings.get(key, PackedByteArray())
	if not raw is PackedByteArray:
		return PackedByteArray()
	var bytes := raw as PackedByteArray
	if bytes.size() < expected_bytes:
		return PackedByteArray()
	return bytes if bytes.size() == expected_bytes else bytes.slice(0, expected_bytes)


func prepare_target_read_buffers_from_common_gpu(settings: Dictionary, sv: Dictionary) -> Dictionary:
	# GPU-specialized variant of target_read_buffers_from_common().
	# Buffers are one u32 word per voxel: target_color_rgba8 is an RGBA8 word,
	# target_occupancy preserves the source R32F byte word without float decode.
	log_name = "ScenePlacementActorTargetReadBuffers"
	var expected_bytes := _expected_target_byte_count(sv)
	var voxel_count := maxi(int(expected_bytes / 4), 1)
	var source_color := _prepacked_target_bytes(settings, "target_color_rgba8_bytes", expected_bytes)
	var source_occupancy := _prepacked_target_bytes(settings, "target_occupancy_bytes", expected_bytes)
	var color_valid := not source_color.is_empty()
	var occupancy_valid := not source_occupancy.is_empty()
	var color_source := "target_color_rgba8_bytes" if color_valid else "zero_filled"
	var occupancy_source := "target_occupancy_bytes" if occupancy_valid else "zero_filled"

	if not ensure_device(true, false):
		return {
			"ok": false,
			"reason": "missing_rendering_device",
			"gpu_first": true,
			"cpu_fallback": false,
			"expected_byte_count": expected_bytes,
			"voxel_count": voxel_count,
		}

	var shader := load_compute_shader(TARGET_READ_BUFFER_PREP_SHADER, SCOPE_FRAME, "prepare_target_read_buffers")
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
		}

	var zero_bytes := PackedByteArray()
	zero_bytes.resize(expected_bytes)
	var color_input_buffer := storage_buffer_from_bytes(
		source_color if color_valid else zero_bytes,
		SCOPE_FRAME,
		"target_read_color_input_rgba8_u32"
	)
	var occupancy_input_buffer := storage_buffer_from_bytes(
		source_occupancy if occupancy_valid else zero_bytes,
		SCOPE_FRAME,
		"target_read_occupancy_input_r32f_words"
	)
	var color_output_buffer := storage_buffer_zero(expected_bytes, SCOPE_FRAME, "target_read_color_out_rgba8_u32")
	var occupancy_output_buffer := storage_buffer_zero(expected_bytes, SCOPE_FRAME, "target_read_occupancy_out_r32f_words")
	if (
		not color_input_buffer.is_valid()
		or not occupancy_input_buffer.is_valid()
		or not color_output_buffer.is_valid()
		or not occupancy_output_buffer.is_valid()
	):
		gc_frame()
		return {
			"ok": false,
			"reason": "target_read_buffer_prep_storage_buffer_failed",
			"gpu_first": true,
			"cpu_fallback": false,
			"expected_byte_count": expected_bytes,
			"voxel_count": voxel_count,
		}

	var set0 := create_uniform_set([
		make_storage_uniform(0, color_input_buffer),
		make_storage_uniform(1, occupancy_input_buffer),
		make_storage_uniform(2, color_output_buffer),
		make_storage_uniform(3, occupancy_output_buffer),
	], shader, 0, SCOPE_PASS, "prepare_target_read_buffers")
	if not set0.is_valid():
		gc_frame()
		return {
			"ok": false,
			"reason": "target_read_buffer_prep_uniform_set_failed",
			"gpu_first": true,
			"cpu_fallback": false,
			"expected_byte_count": expected_bytes,
			"voxel_count": voxel_count,
		}

	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, voxel_count)
	push.encode_s32(4, 1 if color_valid else 0)
	push.encode_s32(8, 1 if occupancy_valid else 0)
	push.encode_s32(12, 0)

	var groups := dispatch_groups_1d(voxel_count, TARGET_READ_BUFFER_PREP_LOCAL_SIZE)
	var cl := begin_compute_list()
	if cl < 0:
		gc_frame()
		return {
			"ok": false,
			"reason": "target_read_buffer_prep_compute_list_begin_failed",
			"gpu_first": true,
			"cpu_fallback": false,
			"expected_byte_count": expected_bytes,
			"voxel_count": voxel_count,
		}
	_rd.compute_list_bind_compute_pipeline(cl, pipeline)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, groups.x, groups.y, groups.z)
	end_compute_list()
	submit_and_sync()

	var target_color_rgba8 := _rd.buffer_get_data(color_output_buffer, 0, expected_bytes)
	var target_occupancy := _rd.buffer_get_data(occupancy_output_buffer, 0, expected_bytes)
	gc_frame()
	if target_color_rgba8.size() != expected_bytes or target_occupancy.size() != expected_bytes:
		return {
			"ok": false,
			"reason": "target_read_buffer_prep_readback_size_mismatch",
			"gpu_first": true,
			"cpu_fallback": false,
			"expected_byte_count": expected_bytes,
			"actual_color_byte_count": target_color_rgba8.size(),
			"actual_occupancy_byte_count": target_occupancy.size(),
			"voxel_count": voxel_count,
		}

	return {
		"ok": true,
		"reason": "ok",
		"gpu_first": true,
		"cpu_fallback": false,
		"target_color_rgba8_bytes": target_color_rgba8,
		"target_occupancy_bytes": target_occupancy,
		"expected_byte_count": expected_bytes,
		"voxel_count": voxel_count,
		"target_color_source": color_source,
		"target_occupancy_source": occupancy_source,
		"target_color_format": "rgba8_u32",
		"target_occupancy_format": "r32f_word_copy",
		"target_color_stride_bytes": 4,
		"target_occupancy_stride_bytes": 4,
		"dispatch_groups": groups,
		"stats_source": "prepare_target_read_buffers_compute",
	}


static func target_read_buffers_from_common(settings: Dictionary, sv: Dictionary) -> Dictionary:
	var expected_bytes := _expected_target_byte_count(sv)
	var target_color_rgba8 := _prepacked_target_bytes(settings, "target_color_rgba8_bytes", expected_bytes)
	var target_occupancy := _prepacked_target_bytes(settings, "target_occupancy_bytes", expected_bytes)
	var color_source := "target_color_rgba8_bytes"
	var occupancy_source := "target_occupancy_bytes"
	if target_color_rgba8.is_empty():
		target_color_rgba8.resize(expected_bytes)
		color_source = "zero_filled"
	if target_occupancy.is_empty():
		target_occupancy.resize(expected_bytes)
		occupancy_source = "zero_filled"
	return {
		"target_color_rgba8_bytes": target_color_rgba8,
		"target_occupancy_bytes": target_occupancy,
		"expected_byte_count": expected_bytes,
		"target_color_source": color_source,
		"target_occupancy_source": occupancy_source,
	}
