class_name AutoVoxelRuntimeProfileContainer
extends RefCounted

const AssetDescriptorScript := preload("res://scripts/asset_descriptor.gd")
const AutoVoxelProfile := preload("res://scripts/auto_voxel_profile.gd")
const SemanticProbeGeneratorScript := preload("res://scripts/semantic_probe_generator.gd")
const SharedPropertyTypeScript := preload("res://scripts/shared_property_type.gd")
const BufferUtils := preload("res://scripts/utils/buffer_utils.gd")
const HashUtils := preload("res://scripts/utils/hash_utils.gd")
const ProfileRecordSchemaScript := preload("res://scripts/utils/profile_record_schema.gd")
const ProfileArenaLayoutScript := preload("res://scripts/utils/profile_arena_layout.gd")
const VariantUtils := preload("res://scripts/utils/variant_utils.gd")
const CanonicalHash := preload("res://scripts/utils/canonical_hash.gd")

# ══ 固定槽位 Profile 单一 Arena（固定槽位Profile共享Buffer实施计划）════════════
# Header/Samples/Pivots/MeshDescription 全部住进一个定长 slot，一个 RID、一个
# Binding、一个 Revision。布局与地址算术全部取自 ProfileArenaLayout，本文件不写
# 任何偏移字面量（计划 §3 末段）。
#
# 旧的三件套（profile_table / profile_sample_records / pivot_records）已在阶段 B 退役：
# 内容全部搬进每个 slot，寻址从"全局累计基址"变成"槽内局部下标"，多 Buffer 的 RID /
# 容量 / revision / 生命周期路径随之全部删除（计划 §13.10）。
const PROFILE_ARENA_BUFFER := "profile_arena"
const ALL_GPU_BUFFER_NAMES := [PROFILE_ARENA_BUFFER]

static var _normalized_descriptor_cache: Dictionary = {}
static var _profile_registration_cache: Dictionary = {}

# stride 单源：ProfileRecordSchema.RECORD_LAYOUTS（数据契约收紧计划 T2）；
# slot header / sample / pivot 的字段偏移以该 LAYOUT 表为准。
const PROFILE_TABLE_STRIDE_BYTES := ProfileRecordSchemaScript.PROFILE_TABLE_STRIDE_BYTES
const PROFILE_SAMPLE_RECORD_STRIDE_BYTES := ProfileRecordSchemaScript.PROFILE_SAMPLE_RECORD_STRIDE_BYTES
const PIVOT_RECORD_STRIDE_BYTES := ProfileRecordSchemaScript.PIVOT_RECORD_STRIDE_BYTES

var descriptor_hash_to_profile_id: Dictionary = {}
var dirty_profile_ids: Array[int] = []

var _profile_hash_to_id: Dictionary = {}
var _profile_id_to_hash: Dictionary = {}
var _profile_id_to_table_entry: Dictionary = {}
var _profile_id_to_normalized_data: Dictionary = {}
var _source_key_to_profile_id: Dictionary = {}
var _profile_order: Array[int] = []
var _staging_profile_table: Array[Dictionary] = []
var _staging_profile_sample_groups: Array = []
var _staging_profile_sample_record_count := 0
var _staging_profile_sample_bytes := PackedByteArray()
var _staging_pivot_records: Array[Dictionary] = []
var _staging_coarse_sample_ranges: Array[Dictionary] = []
var _staging_fine_sample_ranges: Array[Dictionary] = []
var _staging_pivot_ranges: Array[Dictionary] = []
# slot 的 Mesh 区没有 staging：mesh 是每资产的、slot 是每 profile 的，基数不同，
# 该区保留占位但恒为零（详见本文件 pack_pivot_records 之后那段说明）。

var _rd: RenderingDevice
var _owns_rendering_device := false
var _gpu_runtime_ready := false
var _gpu_revision := 0
var _staging_revision := 0
var _uploaded_revision := -1
# 上传整份 Arena 时的 profile 数。单槽增量更新要靠它判断"这期间有没有新增/删除
# profile"——增删会改动全局 Arena Header 的 loaded_profile_count，那就不是单槽的事了。
var _uploaded_profile_count := -1
var _last_upload_error := ""
var _gpu_buffers: Dictionary = {}
var _gpu_buffer_byte_sizes: Dictionary = {}
var _gpu_logical_byte_sizes: Dictionary = {}
var _gpu_record_counts: Dictionary = {}
var _gpu_strides: Dictionary = {}
var _descriptor_cache_connections: Dictionary = {}
var _registration_diagnostics := {}


# ⚠ 编辑器软重载（@tool 脚本重新解析）后的成员修复，别当成冗余判空删掉。
#
# 事实依据（gdscript.cpp GDScriptInstance::reload_members）：软重载只把**重载前已存在**
# 的成员按名字搬进新槽位（值原样保留，不回初始值）；本次重载**新增**的成员槽是默认构造
# 的 Variant = nil，声明里的初始化器**不会**重跑。带静态类型也拦不住——实例槽本身是
# Variant。本容器被编辑器里的 @tool 节点长期持有，重载后第一次注册就会炸在
# `_registration_diagnostics.is_empty()`、`_descriptor_cache_connections.has(...)`、
# `_staging_profile_sample_bytes.append_array(...)` 这些"在 Nil 上找方法"的位置，
# 以及 `var start := _staging_profile_sample_record_count`（把 nil 赋给 int 局部）。
#
# ⚠ 必须用 `is` 而不是 `== null`：对静态类型已知的操作数 GDScript 会挑验证求值器，而
# Variant 给 (INT, NIL)、(DICTIONARY, NIL) 这类组合注册的是 OperatorEvaluatorAlwaysFalse
# （variant_op.cpp），`x == null` 会被编成恒 false，判空形同虚设。
# `is` 编成 OPCODE_TYPE_TEST_BUILTIN，查的是运行时真实类型，nil 一定为假。
#
# 语义：只回填 nil 槽，正常路径一个值都不动。staging 各段回到空 = 与 clear() 后等价，
# 由随后的 register/_mark_staging_changed 重新填并重传（_uploaded_revision 是**旧**成员、
# 软重载会保留，因此这里连带把它推回 -1，避免"staging 空了但版本号说已上传"）。
func _repair_soft_reloaded_members() -> void:
	var staging_lost := not (_staging_profile_sample_groups is Array) \
			or not (_staging_profile_sample_record_count is int) \
			or not (_staging_profile_sample_bytes is PackedByteArray) \
			or not (_staging_coarse_sample_ranges is Array) \
			or not (_staging_fine_sample_ranges is Array)
	if not (_staging_profile_sample_groups is Array): _staging_profile_sample_groups = []
	if not (_staging_profile_sample_record_count is int): _staging_profile_sample_record_count = 0
	if not (_staging_profile_sample_bytes is PackedByteArray): _staging_profile_sample_bytes = PackedByteArray()
	if not (_staging_coarse_sample_ranges is Array): _staging_coarse_sample_ranges = []
	if not (_staging_fine_sample_ranges is Array): _staging_fine_sample_ranges = []
	if not (_descriptor_cache_connections is Dictionary): _descriptor_cache_connections = {}
	if not (_registration_diagnostics is Dictionary): reset_registration_diagnostics()
	if not (_uploaded_profile_count is int): _uploaded_profile_count = -1
	if staging_lost:
		# staging 内容已丢，绝不能让 upload_profiles 按旧 _uploaded_revision 判定"无需重传"。
		_uploaded_revision = -1
		_uploaded_profile_count = -1


## 释放 GPU buffer 并清空所有 staging/profile 映射与 dirty 状态，重置容器到空状态。
func clear() -> void:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	_release_gpu_buffers()
	descriptor_hash_to_profile_id.clear()
	dirty_profile_ids.clear()
	_profile_hash_to_id.clear()
	_profile_id_to_hash.clear()
	_profile_id_to_table_entry.clear()
	_profile_id_to_normalized_data.clear()
	_source_key_to_profile_id.clear()
	_profile_order.clear()
	_staging_profile_table.clear()
	_staging_profile_sample_groups.clear()
	_staging_profile_sample_record_count = 0
	_staging_profile_sample_bytes = PackedByteArray()
	_staging_pivot_records.clear()
	_staging_coarse_sample_ranges.clear()
	_staging_fine_sample_ranges.clear()
	_staging_pivot_ranges.clear()
	_last_upload_error = ""
	reset_registration_diagnostics()
	_mark_staging_changed()


func reset_registration_diagnostics() -> void:
	_registration_diagnostics = {
		"normalized_descriptor_cache_hits": 0,
		"normalized_descriptor_cache_misses": 0,
		"profile_registration_cache_hits": 0,
		"profile_registration_cache_misses": 0,
		"raw_profile_normalizations": 0,
		"descriptor_normalize_ms": 0.0,
		"profile_stage_ms": 0.0,
	}


func get_registration_diagnostics() -> Dictionary:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	return _registration_diagnostics.duplicate(true)


## 释放 GPU buffer 并销毁容器；sync_before_free 为 true 时先 submit/sync，仅在拥有 rendering device 时才 free 该设备。
func dispose(sync_before_free: bool = false) -> void:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	_disconnect_descriptor_cache_signals()
	_submit_and_sync_before_dispose(sync_before_free)
	_release_gpu_buffers()
	if _rd != null and _owns_rendering_device:
		_rd.free()
	_rd = null
	_owns_rendering_device = false


## 确保存在可用的 RenderingDevice：优先创建本地 device（owns_rendering_device=true），否则回退到全局 device；都失败则记录 last_upload_error 并返回 false。
## 获取逻辑复用共有静态方法 GodotComputeShaderBase.acquire_rendering_device()，本容器仅额外维护 last_upload_error / gpu_runtime_ready 状态。
func ensure_device(prefer_local_device: bool = true, allow_global_fallback: bool = true) -> bool:
	if _rd != null:
		return true

	var acquired := GodotComputeShaderBase.acquire_rendering_device(prefer_local_device, allow_global_fallback)
	_rd = acquired["rd"]
	_owns_rendering_device = acquired["owns"]

	if _rd == null:
		_last_upload_error = "no_rendering_device"
		_gpu_runtime_ready = false
		push_error("[AutoVoxelRuntimeProfileContainer] ensure_device(): 无法获取 RenderingDevice（prefer_local=%s, allow_global_fallback=%s）—— profile GPU 缓冲不可创建，不降级到 CPU。" % [
			prefer_local_device, allow_global_fallback])
		assert(false, "AutoVoxelRuntimeProfileContainer.ensure_device: no RenderingDevice")
		return false

	_last_upload_error = ""
	return true


## 绑定外部传入的 RenderingDevice（owns_device 标记是否由本容器负责释放）；若已绑定其它设备则先 dispose，传入 null 返回 false。
func attach_rendering_device(rendering_device: RenderingDevice, owns_device: bool = false) -> bool:
	if rendering_device == null:
		_last_upload_error = "external_rendering_device_is_null"
		push_error("[AutoVoxelRuntimeProfileContainer] attach_rendering_device(): 外部传入的 RenderingDevice 为 null —— 拒绝绑定。")
		assert(false, "AutoVoxelRuntimeProfileContainer.attach_rendering_device: null RenderingDevice")
		return false
	if _rd != null and _rd != rendering_device:
		dispose()
	_rd = rendering_device
	_owns_rendering_device = owns_device
	_last_upload_error = ""
	return true


## 返回当前绑定的 RenderingDevice（可能为 null）。
func get_rendering_device() -> RenderingDevice:
	return _rd


## 返回本容器是否拥有（负责释放）当前 rendering device。
func owns_rendering_device() -> bool:
	return _owns_rendering_device


## 判断 dispose 前是否需要 submit/sync：仅当请求同步且拥有有效的 rendering device 时返回 true。
func _should_sync_before_dispose(sync_before_free: bool) -> bool:
	return sync_before_free and _rd != null and _owns_rendering_device


## 在 dispose 前对自有 device 执行 submit() 与 sync()，确保挂起的 GPU 命令完成后再释放资源。
func _submit_and_sync_before_dispose(sync_before_free: bool) -> void:
	if not _should_sync_before_dispose(sync_before_free):
		return
	_rd.submit()
	_rd.sync()


## 将 staging 的 profile table / profile sample / pivot 记录打包并创建为三个 GPU storage buffer（profile_table / profile_sample_records / pivot_records）；force=false 且 runtime 已就绪时直接返回，成功后推进 gpu_revision 并清空 dirty。
func upload_profiles(force: bool = false) -> bool:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	var layout_errors := ProfileRecordSchemaScript.verify_record_layouts()
	if not layout_errors.is_empty():
		_last_upload_error = "record_layout_contract_violation: %s" % "; ".join(layout_errors)
		push_error("[AutoVoxelRuntimeProfileContainer] upload_profiles(): %s —— GPU 记录布局契约被破坏，拒绝上传。" % _last_upload_error)
		assert(false, "AutoVoxelRuntimeProfileContainer.upload_profiles: record layout contract violation")
		return false
	if not ensure_device():
		return false
	if not force and is_runtime_ready():
		return true

	var arena_layout_errors := ProfileArenaLayoutScript.verify_layout()
	if not arena_layout_errors.is_empty():
		_last_upload_error = "profile_arena_layout_contract_violation: %s" % "; ".join(arena_layout_errors)
		push_error("[AutoVoxelRuntimeProfileContainer] upload_profiles(): %s —— Arena 布局契约被破坏，拒绝上传。" % _last_upload_error)
		assert(false, "AutoVoxelRuntimeProfileContainer.upload_profiles: arena layout contract violation")
		return false

	# 固定容量超限必须在**任何**状态被改动前拦下（计划 §4 末段 / §7「任一 Descriptor
	# 失败时保留原有运行时状态」）：此处返回时旧 buffer、RID 与 revision 一律没动过。
	var capacity_errors := validate_arena_capacity()
	if not capacity_errors.is_empty():
		_last_upload_error = "profile_arena_capacity_exceeded: %s" % "; ".join(capacity_errors)
		push_error("[AutoVoxelRuntimeProfileContainer] upload_profiles(): 固定 Slot 容量超限，拒绝上传（旧 Arena 保持有效）：\n  %s" % "\n  ".join(capacity_errors))
		assert(false, "AutoVoxelRuntimeProfileContainer.upload_profiles: fixed slot capacity exceeded")
		return false

	var packed_arena := _pack_arena_bytes()
	if packed_arena.size() != ProfileArenaLayoutScript.ARENA_BYTE_COUNT:
		_last_upload_error = "profile_arena_pack_failed:%d" % packed_arena.size()
		push_error("[AutoVoxelRuntimeProfileContainer] upload_profiles(): Arena CPU 打包失败（%d 字节，应为 %d）—— 旧 Arena 保持有效。" % [
			packed_arena.size(), ProfileArenaLayoutScript.ARENA_BYTE_COUNT])
		assert(false, "AutoVoxelRuntimeProfileContainer.upload_profiles: arena pack failed")
		return false

	# 事务式替换（计划 §7）：先把全部新 buffer 建出来，**全部**成功之后才释放旧的。
	# 旧行为是先 _release_gpu_buffers() 再逐个创建，中途失败就只剩一堆无效 RID，
	# 运行时既没有新 Arena 也没有旧 Arena。
	var pending := {}
	var ok := true
	# Arena 是定长的：record_count 恒为 PROFILE_CAPACITY，与已加载 profile 数无关。
	ok = ok and _stage_storage_buffer(
		pending,
		PROFILE_ARENA_BUFFER,
		packed_arena,
		ProfileArenaLayoutScript.PROFILE_CAPACITY,
		ProfileArenaLayoutScript.PROFILE_SLOT_STRIDE_BYTES,
		ProfileArenaLayoutScript.PROFILE_SLOTS_OFFSET_BYTES
	)
	if not ok:
		_discard_staged_buffers(pending)
		return false

	_release_gpu_buffers()
	_commit_staged_buffers(pending)

	_gpu_runtime_ready = true
	_uploaded_revision = _staging_revision
	_uploaded_profile_count = _staging_profile_table.size()
	_gpu_revision += 1
	_last_upload_error = ""
	dirty_profile_ids.clear()
	return true


## 判断 GPU runtime 是否就绪：需有 device、已上传、uploaded_revision 与 staging_revision 一致、无 dirty profile、且三个 buffer RID 均有效。
func is_runtime_ready() -> bool:
	if _rd == null or not _gpu_runtime_ready:
		return false
	if _uploaded_revision != _staging_revision:
		return false
	if not dirty_profile_ids.is_empty():
		return false
	for buffer_name in ALL_GPU_BUFFER_NAMES:
		var rid: RID = _gpu_buffers.get(buffer_name, RID())
		if not rid.is_valid():
			return false
	return true


## 按名称返回对应 GPU buffer 的 RID，不存在时返回无效 RID。
func get_gpu_buffer(buffer_name: String) -> RID:
	return _gpu_buffers.get(buffer_name, RID())


## 返回指定 GPU buffer 已上传的 record 数（= shader 侧该缓冲的元素容量；未创建/空时为 0）。
## 供 dispatch 端把容量作为显式 push/config 值传给 shader 的容量守卫使用。
func get_gpu_record_count(buffer_name: String) -> int:
	return int(_gpu_record_counts.get(buffer_name, 0))


## 返回固定槽位 Profile Arena 的唯一 GPU buffer RID（Header/Samples/Pivots/Mesh 全在内）。
func get_profile_arena_buffer() -> RID:
	return get_gpu_buffer(PROFILE_ARENA_BUFFER)


## Arena 的唯一 Revision（计划 §14「Arena 只有一个 RID、一个 Binding 和一个 Revision」）。
## 与旧三 Buffer 同源同步推进——它们由同一次 upload_profiles() 事务一起换掉。
func get_arena_revision() -> int:
	return _gpu_revision


## 接过上一代容器的 Revision 基线，使 Arena Revision 跨"事务式换容器实例"保持单调递增。
##
## ⚠ 没有这一步，ScenePlacementRuntime.replace_all_assets() 每次都新建容器、Revision
## 从 0 重新开始，Reload 之后消费方看到的 revision 反而回退到 1 —— "Arena 只有一个
## Revision"就成了空话（分不清"换了新 Arena"和"还是那个 Arena"）。
func adopt_revision_baseline(previous_revision: int) -> void:
	_gpu_revision = maxi(_gpu_revision, previous_revision)


## 显式回读整个 Arena（32 MiB，仅供校验/调试；不进常规 debug 快照）。
func readback_arena_bytes() -> PackedByteArray:
	if not is_runtime_ready():
		push_error("[AutoVoxelRuntimeProfileContainer] readback_arena_bytes(): runtime 未就绪。")
		assert(false, "AutoVoxelRuntimeProfileContainer.readback_arena_bytes: runtime not ready")
		return PackedByteArray()
	return _readback_arena_prefix(ProfileArenaLayoutScript.ARENA_BYTE_COUNT)


## Arena 状态与内存预算摘要（计划 §5 / §11.3 的数据来源）。
func get_profile_arena_summary() -> Dictionary:
	var rid: RID = _gpu_buffers.get(PROFILE_ARENA_BUFFER, RID())
	var valid_sample_count := 0
	var valid_pivot_count := 0
	for entry in _staging_profile_table:
		valid_sample_count += int((entry.get("coarse_sample_range", {}) as Dictionary).get("count", 0))
		valid_sample_count += int((entry.get("fine_sample_range", {}) as Dictionary).get("count", 0))
		valid_pivot_count += int((entry.get("pivot_range", {}) as Dictionary).get("count", 0))
	var report := ProfileArenaLayoutScript.budget_report(
		_staging_profile_table.size(), valid_sample_count, valid_pivot_count)
	report["rid_valid"] = rid.is_valid()
	report["gpu_byte_count"] = int(_gpu_buffer_byte_sizes.get(PROFILE_ARENA_BUFFER, 0))
	report["revision"] = _gpu_revision
	report["runtime_ready"] = is_runtime_ready()
	report["last_upload_error"] = _last_upload_error
	report["layout_errors"] = ProfileArenaLayoutScript.verify_layout()
	report["capacity_errors"] = validate_arena_capacity()
	return report


func get_fine_sample_range_for_profile_id(profile_id: int) -> Dictionary:
	if not _profile_id_to_table_entry.has(profile_id):
		# 不再用 start=0/count=0 的空 record 顶替：那会让调用方以为该 profile 合法且没有 fine 样本。
		push_error("[AutoVoxelRuntimeProfileContainer] get_fine_sample_range_for_profile_id(): profile_id=%d 未注册（已注册 %d 条）—— 不返回空 record。" % [
			profile_id, _profile_order.size()])
		assert(false, "AutoVoxelRuntimeProfileContainer.get_fine_sample_range_for_profile_id: unregistered profile_id")
		return {}
	var entry: Dictionary = _profile_id_to_table_entry[profile_id]
	var fine_sample_range: Dictionary = entry.get("fine_sample_range", {})
	return {
		"start": int(fine_sample_range.get("start", 0)),
		"count": int(fine_sample_range.get("count", 0)),
	}


## 返回 GPU buffer 与 runtime 状态的诊断摘要（各 buffer 的 RID 有效性/record_count/stride/逻辑与实际字节数，以及 revision、dirty、last_upload_error 等控制面信息）。
func get_gpu_buffer_summary() -> Dictionary:
	var buffers := {}
	for buffer_name in ALL_GPU_BUFFER_NAMES:
		var rid: RID = _gpu_buffers.get(buffer_name, RID())
		buffers[buffer_name] = {
			"rid_valid": rid.is_valid(),
			"record_count": int(_gpu_record_counts.get(buffer_name, 0)),
			"stride_bytes": int(_gpu_strides.get(buffer_name, _stride_for_buffer(buffer_name))),
			"logical_byte_count": int(_gpu_logical_byte_sizes.get(buffer_name, 0)),
			"gpu_byte_count": int(_gpu_buffer_byte_sizes.get(buffer_name, 0)),
		}
	return {
		"read_source": "gpu_buffers",
		"runtime_read_source": "gpu_buffers" if is_runtime_ready() else "none",
		"readback_source": "gpu_buffers" if is_runtime_ready() else "none",
		"staging_source": "descriptor_profile_staging",
		"control_plane": "runtime_profile_container",
		"runtime_payload": "gpu_profile_buffers",
		"gpu_first": true,
		"cpu_fallback": false,
		"per_object_runtime_manager": false,
		"owns_object_lifecycle": false,
		"has_rendering_device": _rd != null,
		"runtime_ready": is_runtime_ready(),
		"staging_profile_count": get_profile_count(),
		"gpu_revision": _gpu_revision,
		"staging_revision": _staging_revision,
		"uploaded_revision": _uploaded_revision,
		"last_upload_error": _last_upload_error,
		"dirty_profile_ids": dirty_profile_ids.duplicate(),
		"buffers": buffers,
		"profile_arena": get_profile_arena_summary(),
	}


## 回读（readback）三个 GPU buffer 的原始字节并做字节数校验，返回含解码后 profile table 的完整调试快照；runtime 未就绪时返回精简的未就绪快照。
func readback_debug_snapshot() -> Dictionary:
	var summary := get_gpu_buffer_summary()
	if not is_runtime_ready():
		return {
			"read_source": "gpu_buffers",
			"runtime_read_source": "none",
			"readback_source": "none",
			"staging_source": "descriptor_profile_staging",
			"control_plane": "runtime_profile_container",
			"runtime_payload": "gpu_profile_buffers",
			"gpu_first": true,
			"cpu_fallback": false,
			"readback_snapshot": false,
			"per_object_runtime_manager": false,
			"owns_object_lifecycle": false,
			"runtime_ready": false,
			"staging_profile_count": get_profile_count(),
			"dirty_profile_ids": dirty_profile_ids.duplicate(),
			"gpu_buffer_summary": summary,
		}

	# 只回读"已加载 slot"那一段（header + loaded × slot_stride），不是整份 32 MiB Arena：
	# 未使用槽位恒为零，拖回 CPU 没有信息量，只有代价。
	var loaded_count := _staging_profile_table.size()
	var used_byte_count := ProfileArenaLayoutScript.PROFILE_SLOTS_OFFSET_BYTES \
		+ loaded_count * ProfileArenaLayoutScript.PROFILE_SLOT_STRIDE_BYTES
	var arena_bytes := _readback_arena_prefix(used_byte_count)
	var readback_ok := arena_bytes.size() == used_byte_count

	var decoded_slots: Array[Dictionary] = []
	var decoded_samples: Array[Dictionary] = []
	if readback_ok:
		for slot_index in range(loaded_count):
			var slot := decode_arena_slot(arena_bytes, slot_index)
			if slot.is_empty():
				readback_ok = false
				break
			decoded_slots.append(slot)
			decoded_samples.append_array(slot.get("decoded_samples", []) as Array[Dictionary])

	return {
		"read_source": "gpu_buffers",
		"runtime_read_source": "gpu_buffers",
		"readback_source": "gpu_buffers" if readback_ok else "none",
		"failed_readback_source": "none" if readback_ok else "gpu_buffers",
		"control_plane": "runtime_profile_container",
		"runtime_payload": "gpu_profile_arena",
		"gpu_first": true,
		"cpu_fallback": false,
		"readback_snapshot": readback_ok,
		"readback_validation": {
			"ok": readback_ok,
			"reason": "ok" if readback_ok else "arena_readback_byte_count_mismatch",
			"expected_byte_count": used_byte_count,
			"actual_byte_count": arena_bytes.size(),
			"gpu_first": true,
			"cpu_fallback": false,
		},
		"readback_error": "" if readback_ok else "arena_readback_byte_count_mismatch",
		"per_object_runtime_manager": false,
		"owns_object_lifecycle": false,
		"runtime_ready": true,
		"profile_count": loaded_count,
		"dirty_profile_ids": dirty_profile_ids.duplicate(),
		"gpu_buffer_summary": summary,
		"arena_header": decode_arena_header(arena_bytes),
		"arena_bytes": arena_bytes,
		"decoded_arena_slots": decoded_slots,
		# 保留旧键名：调试/检查侧按 profile 顺序读 header 与样本的用法不变，只是数据
		# 现在来自 Arena 的各 slot 而不是两个独立扁平 buffer。
		"decoded_profile_table": decoded_slots,
		"decoded_profile_samples": decoded_samples,
	}


## 回读 Arena 的前 byte_count 字节（调试用；未使用槽位恒零，不必整块拉回）。
func _readback_arena_prefix(byte_count: int) -> PackedByteArray:
	if _rd == null or byte_count <= 0:
		return PackedByteArray()
	var rid: RID = _gpu_buffers.get(PROFILE_ARENA_BUFFER, RID())
	if not rid.is_valid():
		push_error("[AutoVoxelRuntimeProfileContainer] _readback_arena_prefix(): Arena RID 无效（runtime 声称就绪）。")
		assert(false, "AutoVoxelRuntimeProfileContainer._readback_arena_prefix: invalid arena RID")
		return PackedByteArray()
	return _rd.buffer_get_data(rid, 0, mini(byte_count, ProfileArenaLayoutScript.ARENA_BYTE_COUNT))


## 归一化 descriptor 并注册为 profile，返回 profile_id；同时按 descriptor 的 source_key 建立到 profile_id 的映射，descriptor 为 null 时返回 -1。
func register_descriptor(
	descriptor: Resource,
	default_radius: float = 0.0,
	density_override: float = -1.0,
	world_scale: Vector3 = Vector3.ONE,
	mesh: Mesh = null
) -> int:
	if descriptor == null:
		return -1
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	if _registration_diagnostics.is_empty():
		reset_registration_diagnostics()
	_observe_descriptor_cache_changes(descriptor)
	var cache_key := _descriptor_normalization_cache_key(
		descriptor, default_radius, density_override, world_scale, mesh)
	var cache_entry: Dictionary = _normalized_descriptor_cache.get(cache_key, {})
	var cached_descriptor: Resource = (cache_entry.get("descriptor_ref") as WeakRef).get_ref() \
		if cache_entry.get("descriptor_ref") is WeakRef else null
	var normalized: Dictionary
	if cached_descriptor == descriptor and cache_entry.get("normalized") is Dictionary:
		_registration_diagnostics["normalized_descriptor_cache_hits"] = \
			int(_registration_diagnostics.get("normalized_descriptor_cache_hits", 0)) + 1
		normalized = cache_entry.get("normalized") as Dictionary
	else:
		_registration_diagnostics["normalized_descriptor_cache_misses"] = \
			int(_registration_diagnostics.get("normalized_descriptor_cache_misses", 0)) + 1
		var normalize_t0_usec := Time.get_ticks_usec()
		normalized = normalize_descriptor(descriptor, default_radius, density_override, world_scale, mesh)
		_registration_diagnostics["descriptor_normalize_ms"] = \
			float(_registration_diagnostics.get("descriptor_normalize_ms", 0.0)) \
			+ float(Time.get_ticks_usec() - normalize_t0_usec) / 1000.0
		_normalized_descriptor_cache[cache_key] = {
			"descriptor_ref": weakref(descriptor),
			"normalized": normalized,
		}
	var profile_id := _register_pre_normalized_profile(normalized)
	var source_key := _descriptor_source_key(descriptor)
	if not source_key.is_empty() and profile_id >= 0:
		_source_key_to_profile_id[source_key] = profile_id
	return profile_id


func _observe_descriptor_cache_changes(descriptor: Resource) -> void:
	var instance_id := descriptor.get_instance_id()
	if _descriptor_cache_connections.has(instance_id):
		return
	var callback := _on_cached_descriptor_changed.bind(instance_id)
	descriptor.changed.connect(callback)
	_descriptor_cache_connections[instance_id] = {
		"descriptor_ref": weakref(descriptor),
		"callback": callback,
	}


func _on_cached_descriptor_changed(instance_id: int) -> void:
	_invalidate_normalized_descriptor_cache(instance_id)


func _disconnect_descriptor_cache_signals() -> void:
	for entry in _descriptor_cache_connections.values():
		if not (entry is Dictionary):
			continue
		var descriptor_ref = (entry as Dictionary).get("descriptor_ref")
		var descriptor: Resource = descriptor_ref.get_ref() if descriptor_ref is WeakRef else null
		var callback: Callable = (entry as Dictionary).get("callback", Callable())
		if descriptor != null and callback.is_valid() and descriptor.changed.is_connected(callback):
			descriptor.changed.disconnect(callback)
	_descriptor_cache_connections.clear()


static func _invalidate_normalized_descriptor_cache(instance_id: int) -> void:
	var prefix := "%d|" % instance_id
	for key in _normalized_descriptor_cache.keys():
		if str(key).begins_with(prefix):
			_normalized_descriptor_cache.erase(key)


static func _descriptor_normalization_cache_key(
		descriptor: Resource,
		default_radius: float,
		density_override: float,
		world_scale: Vector3,
		mesh: Mesh
) -> String:
	return "%d|%.9f|%.9f|%.9f,%.9f,%.9f|%d" % [
		descriptor.get_instance_id(),
		default_radius,
		density_override,
		world_scale.x,
		world_scale.y,
		world_scale.z,
		mesh.get_instance_id() if mesh != null else 0,
	]


## Registers data already normalized by normalize_descriptor().
func _register_pre_normalized_profile(normalized: Dictionary) -> int:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	if _registration_diagnostics.is_empty():
		reset_registration_diagnostics()
	var stage_t0_usec := Time.get_ticks_usec()
	var profile_hash := str(normalized.get("profile_hash", ""))
	if profile_hash.is_empty():
		return -1
	if _profile_hash_to_id.has(profile_hash):
		return int(_profile_hash_to_id[profile_hash])

	var profile_id := _profile_id_from_hash(profile_hash)
	var profile_index := _profile_order.size()
	var registration: Dictionary = _profile_registration_cache.get(profile_hash, {})
	if registration.is_empty():
		_registration_diagnostics["profile_registration_cache_misses"] = \
			int(_registration_diagnostics.get("profile_registration_cache_misses", 0)) + 1
		var coarse_samples: Array[Dictionary] = []
		var fine_samples: Array[Dictionary] = []
		for raw_sample in normalized.get("profile_samples", []):
			if not raw_sample is Dictionary:
				continue
			var sample := raw_sample as Dictionary
			var flags := int(sample.get("flags", 0))
			if (flags & ProfileRecordSchemaScript.SAMPLE_FLAG_COARSE) != 0:
				coarse_samples.append(sample)
			if (flags & ProfileRecordSchemaScript.SAMPLE_FLAG_FINE) != 0:
				fine_samples.append(sample)
		var ordered_samples: Array = []
		ordered_samples.append_array(coarse_samples)
		ordered_samples.append_array(fine_samples)
		registration = {
			"coarse_samples": coarse_samples,
			"fine_samples": fine_samples,
			"packed_samples": ProfileRecordSchemaScript.pack_profile_sample_records(ordered_samples),
		}
		_profile_registration_cache[profile_hash] = registration
	else:
		_registration_diagnostics["profile_registration_cache_hits"] = \
			int(_registration_diagnostics.get("profile_registration_cache_hits", 0)) + 1
	var coarse_samples: Array = registration.get("coarse_samples", [])
	var fine_samples: Array = registration.get("fine_samples", [])
	var coarse_sample_range := _append_profile_sample_group(coarse_samples)
	var fine_sample_range := _append_profile_sample_group(fine_samples)
	_staging_profile_sample_bytes.append_array(
		registration.get("packed_samples", PackedByteArray()) as PackedByteArray)
	var pivot_range := _append_range(_staging_pivot_records, normalized.get("pivot_variants", []))

	var coarse_sample_range_entry := _make_range_entry(profile_id, profile_index, coarse_sample_range)
	var fine_sample_range_entry := _make_range_entry(profile_id, profile_index, fine_sample_range)
	var pivot_range_entry := _make_range_entry(profile_id, profile_index, pivot_range)
	_staging_coarse_sample_ranges.append(coarse_sample_range_entry)
	_staging_fine_sample_ranges.append(fine_sample_range_entry)
	_staging_pivot_ranges.append(pivot_range_entry)

	var table_entry := {
		"profile_id": profile_id,
		"profile_index": profile_index,
		"profile_hash": profile_hash,
		"color": normalized.get("color", Color.WHITE),
		"complexity": float(normalized.get("complexity", 1.0)),
		"semantic_probe_density": float(normalized.get("semantic_probe_density", 1.0)),
		"context_sensing_radius": float(normalized.get("context_sensing_radius", 0.0)),
		"coarse_sample_range": coarse_sample_range_entry.duplicate(true),
		"fine_sample_range": fine_sample_range_entry.duplicate(true),
		"pivot_range": pivot_range_entry.duplicate(true),
		"source_kind": str(normalized.get("source_kind", "")),
		"source_path": str(normalized.get("source_path", "")),
		"asset_id": str(normalized.get("asset_id", "")),
		"object_type": str(normalized.get("object_type", "")),
	}

	_profile_hash_to_id[profile_hash] = profile_id
	descriptor_hash_to_profile_id[profile_hash] = profile_id
	_profile_id_to_hash[profile_id] = profile_hash
	_profile_id_to_table_entry[profile_id] = table_entry
	_profile_id_to_normalized_data[profile_id] = normalized
	_profile_order.append(profile_id)
	_staging_profile_table.append(table_entry)
	_mark_staging_changed()
	_registration_diagnostics["profile_stage_ms"] = \
		float(_registration_diagnostics.get("profile_stage_ms", 0.0)) \
		+ float(Time.get_ticks_usec() - stage_t0_usec) / 1000.0
	return profile_id


## 将指定 profile_id 标记为 dirty（去重加入 dirty 列表），并使 uploaded_revision 失效、runtime 标记为未就绪以触发重新上传。
func mark_profile_dirty(profile_id: int) -> void:
	if profile_id < 0:
		return
	if dirty_profile_ids.find(profile_id) < 0:
		dirty_profile_ids.append(profile_id)
	_uploaded_revision = -1
	_gpu_runtime_ready = false




## 返回已注册的 profile 数量（按注册顺序计数）。
func get_profile_count() -> int:
	return _profile_order.size()


## 返回 profile_id 对应的稠密 profile_index —— 即 Arena 的 slot 索引（见
## ProfileArenaLayout 类首「slot 寻址索引」说明）；未注册返回 -1。
func get_profile_index_for_profile_id(profile_id: int) -> int:
	if not _profile_id_to_table_entry.has(profile_id):
		return -1
	return int((_profile_id_to_table_entry[profile_id] as Dictionary).get("profile_index", -1))


## 按 profile_hash 反查 profile_id，未注册时返回 -1。
func get_profile_id_for_hash(profile_hash: String) -> int:
	return int(descriptor_hash_to_profile_id.get(profile_hash, -1))


## 归一化 descriptor 计算其 profile_hash 并反查 profile_id（只查询不注册），descriptor 为 null 或 hash 为空时返回 -1。
func get_profile_id_for_descriptor(
	descriptor: Resource,
	default_radius: float = 0.0,
	density_override: float = -1.0,
	world_scale: Vector3 = Vector3.ONE,
	mesh: Mesh = null
) -> int:
	if descriptor == null:
		return -1
	var normalized := normalize_descriptor(descriptor, default_radius, density_override, world_scale, mesh)
	var profile_hash := str(normalized.get("profile_hash", ""))
	if profile_hash.is_empty():
		return -1
	return get_profile_id_for_hash(profile_hash)


func get_coarse_sample_range_for_profile_id(profile_id: int) -> Dictionary:
	if not _profile_id_to_table_entry.has(profile_id):
		push_error("[AutoVoxelRuntimeProfileContainer] get_coarse_sample_range_for_profile_id(): profile_id=%d 未注册（已注册 %d 条）。" % [
			profile_id, _profile_order.size()])
		assert(false, "AutoVoxelRuntimeProfileContainer.get_coarse_sample_range_for_profile_id: unregistered profile_id")
		return {}
	var entry: Dictionary = _profile_id_to_table_entry[profile_id]
	var coarse_sample_range: Dictionary = entry.get("coarse_sample_range", {})
	return coarse_sample_range.duplicate(true)


## 返回 staging profile table 的深拷贝数组。
func export_profile_table() -> Array[Dictionary]:
	return SharedPropertyTypeScript.duplicate_dictionary_array(_staging_profile_table)


## 推进 staging_revision 并使 uploaded_revision 失效、runtime 标记为未就绪，表示 staging 数据已变更需重新上传。
func _mark_staging_changed() -> void:
	_staging_revision += 1
	_uploaded_revision = -1
	_gpu_runtime_ready = false


## 释放所有已创建的 GPU buffer RID 并清空其字节数/record_count/stride 元数据，将 runtime 标记为未就绪、uploaded_revision 置 -1。
func _release_gpu_buffers() -> void:
	if _rd != null:
		for raw_rid in _gpu_buffers.values():
			if raw_rid is RID:
				var rid := raw_rid as RID
				if rid.is_valid():
					_rd.free_rid(rid)
	_gpu_buffers.clear()
	_gpu_buffer_byte_sizes.clear()
	_gpu_logical_byte_sizes.clear()
	_gpu_record_counts.clear()
	_gpu_strides.clear()
	_gpu_runtime_ready = false
	_uploaded_revision = -1
	_uploaded_profile_count = -1


## 用给定字节创建一个 storage buffer（空数据时至少分配 4 字节占位）并把 RID 与
## 实际/逻辑字节数、record_count、stride 暂存进 pending，**不动**任何已生效的
## _gpu_* 状态；失败时设置 last_upload_error 并返回 false。
##
## header_byte_count：buffer 头部不属于任何 record 的固定前缀字节数（Arena 的全局
## header）。字节数契约因此是 header + record_count × stride，而不是纯 record 乘积。
func _stage_storage_buffer(
	pending: Dictionary,
	buffer_name: String,
	bytes: PackedByteArray,
	record_count: int,
	stride_bytes: int,
	header_byte_count: int = 0
) -> bool:
	if _rd == null:
		_last_upload_error = "no_rendering_device"
		push_error("[AutoVoxelRuntimeProfileContainer] _stage_storage_buffer('%s'): RenderingDevice 为 null。" % buffer_name)
		assert(false, "AutoVoxelRuntimeProfileContainer._stage_storage_buffer: no RenderingDevice")
		return false
	if record_count < 0 or stride_bytes <= 0 or header_byte_count < 0:
		_last_upload_error = "invalid_record_layout:%s" % buffer_name
		push_error("[AutoVoxelRuntimeProfileContainer] _stage_storage_buffer('%s'): record_count=%d / stride_bytes=%d / header_byte_count=%d 非法。" % [
			buffer_name, record_count, stride_bytes, header_byte_count])
		assert(false, "AutoVoxelRuntimeProfileContainer._stage_storage_buffer: invalid record layout")
		return false
	var expected_byte_count := header_byte_count + record_count * stride_bytes
	if bytes.size() != expected_byte_count:
		_last_upload_error = "packed_byte_count_mismatch:%s" % buffer_name
		push_error("[AutoVoxelRuntimeProfileContainer] _stage_storage_buffer('%s'): 打包字节数与记录布局不符（期望 %d = %d 头部 + %d 条 × %d 字节，实得 %d）—— 不截断、不补零。" % [
			buffer_name, expected_byte_count, header_byte_count, record_count, stride_bytes, bytes.size()])
		assert(false, "AutoVoxelRuntimeProfileContainer._stage_storage_buffer: packed byte count mismatch")
		return false
	var upload_bytes := bytes
	var logical_size := upload_bytes.size()
	# RenderingDevice 不接受 0 字节缓冲：空表补到 4 字节占位，逻辑字节数/记录数仍记为 0。
	if upload_bytes.is_empty():
		upload_bytes.resize(4)
	var rid := _rd.storage_buffer_create(upload_bytes.size(), upload_bytes)
	if not rid.is_valid():
		_last_upload_error = "storage_buffer_create_failed:%s" % buffer_name
		push_error("[AutoVoxelRuntimeProfileContainer] _stage_storage_buffer('%s'): storage_buffer_create 失败（%d 字节）。" % [
			buffer_name, upload_bytes.size()])
		assert(false, "AutoVoxelRuntimeProfileContainer._stage_storage_buffer: invalid buffer RID")
		return false
	pending[buffer_name] = {
		"rid": rid,
		"gpu_byte_count": upload_bytes.size(),
		"logical_byte_count": logical_size,
		"record_count": record_count,
		"stride_bytes": stride_bytes,
		"header_byte_count": header_byte_count,
	}
	return true


## 把暂存的新 buffer 元数据落为生效状态（调用前必须已 _release_gpu_buffers()）。
func _commit_staged_buffers(pending: Dictionary) -> void:
	for buffer_name in pending:
		var record: Dictionary = pending[buffer_name]
		_gpu_buffers[buffer_name] = record["rid"]
		_gpu_buffer_byte_sizes[buffer_name] = int(record["gpu_byte_count"])
		_gpu_logical_byte_sizes[buffer_name] = int(record["logical_byte_count"])
		_gpu_record_counts[buffer_name] = int(record["record_count"])
		_gpu_strides[buffer_name] = int(record["stride_bytes"])


## 释放尚未生效的暂存 buffer（事务中途失败时调用；已生效的旧 buffer 原样保留）。
func _discard_staged_buffers(pending: Dictionary) -> void:
	if _rd == null:
		return
	for buffer_name in pending:
		var rid: RID = (pending[buffer_name] as Dictionary).get("rid", RID())
		if rid.is_valid():
			_rd.free_rid(rid)


## Arena slot header 的唯一编码器（布局 = ProfileRecordSchema.RECORD_LAYOUTS["profile_table"]）。
## range 三项从参数传入而不是从 entry 里读：slot header 存的是**槽内局部**下标
## （coarse 从 0 起、fine 紧随其后、pivot 从 0 起），与 entry 里记录的全局 staging
## range 不是同一套坐标。
static func _encode_profile_table_record(
	bytes: PackedByteArray,
	base: int,
	entry: Dictionary,
	fallback_profile_index: int,
	coarse_sample_range: Dictionary,
	fine_sample_range: Dictionary,
	pivot_range: Dictionary
) -> void:
	var color := VariantUtils.color_from_value(entry.get("color", Color.WHITE), Color.WHITE)
	var complexity := clampf(float(entry.get("complexity", color.a)), 0.0, 1.0)
	color.a = complexity

	bytes.encode_u32(base + 0, int(entry.get("profile_id", 0)))
	bytes.encode_u32(base + 4, int(entry.get("profile_index", fallback_profile_index)))
	bytes.encode_u32(base + 8, int(coarse_sample_range.get("start", 0)))
	bytes.encode_u32(base + 12, int(coarse_sample_range.get("count", 0)))
	bytes.encode_u32(base + 16, int(fine_sample_range.get("start", 0)))
	bytes.encode_u32(base + 20, int(fine_sample_range.get("count", 0)))
	bytes.encode_u32(base + 24, int(pivot_range.get("start", 0)))
	bytes.encode_u32(base + 28, int(pivot_range.get("count", 0)))
	bytes.encode_float(base + 32, color.r)
	bytes.encode_float(base + 36, color.g)
	bytes.encode_float(base + 40, color.b)
	bytes.encode_float(base + 44, complexity)
	bytes.encode_float(base + 48, float(entry.get("semantic_probe_density", 1.0)))
	bytes.encode_float(base + 52, float(entry.get("context_sensing_radius", 0.0)))
	bytes.encode_u32(base + 56, HashUtils.u32_from_hex(str(entry.get("profile_hash", ""))))
	bytes.encode_u32(base + 60, 0)


## pivot 记录编码器：Arena slot 只打自己那一段切片（布局 = RECORD_LAYOUTS["pivot"]）。
static func pack_pivot_records(records: Array) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(records.size() * PIVOT_RECORD_STRIDE_BYTES)
	for i in range(records.size()):
		var pivot: Dictionary = records[i]
		var offset := VariantUtils.vector3_from_value(pivot.get("offset", Vector3.ZERO), Vector3.ZERO)
		var base := i * PIVOT_RECORD_STRIDE_BYTES
		BufferUtils.encode_vec4(bytes, base + 0, offset, float(pivot.get("score_bias", 0.0)))
		bytes.encode_u32(base + 16, HashUtils.stable_u32_from_string(str(pivot.get("name", ""))))
		bytes.encode_u32(base + 20, 0)
		bytes.encode_u32(base + 24, 0)
		bytes.encode_u32(base + 28, 0)
	return bytes


# slot 的 Mesh 区**保留但恒为零**，没有写入 API —— 这是 mesh 与 profile 基数不同的直接
# 后果（见 ScenePlacementRuntime.refresh_slot_mesh_description 的说明）：
#   profile 身份 = 内容 hash，而 mesh **不参与**该 hash（这是对的：同 profile = 同评分
#   行为），于是 profile → asset 天然一对多，两个 mesh 不同、评分行为相同的资产会共享
#   同一个 slot，定长 Mesh 区装不下两份。
# 逐资产 mesh 元数据的唯一权威是扁平的 per-asset MESH_DESCRIPTION_BUFFER
# （`autoobject_emit_instances.glsl` 按 asset_index 取 mesh AABB 算 OBB；
# GPUAutoObjectRuntime 也为同一理由常驻 asset_index 而非用 profile_id 顶替）。
# 区域本身按计划 §2 的 slot 形状保留，占位不写，读到的恒是零。


## 固定容量校验（计划 §4 末段 / §6）：任何 bake 产物超过固定上限都必须明确失败，
## 报出具体资产、实际数量与允许上限，绝不静默裁剪。返回错误行列表（空 = 通过）。
func validate_arena_capacity() -> PackedStringArray:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	var errors := PackedStringArray()
	var profile_count := _staging_profile_table.size()
	if profile_count > ProfileArenaLayoutScript.PROFILE_CAPACITY:
		errors.append("profile 总数 %d 超过 PROFILE_CAPACITY %d" % [
			profile_count, ProfileArenaLayoutScript.PROFILE_CAPACITY])
	for i in range(profile_count):
		var entry: Dictionary = _staging_profile_table[i]
		var label := _profile_label(entry, i)
		var coarse_count := int((entry.get("coarse_sample_range", {}) as Dictionary).get("count", 0))
		var fine_count := int((entry.get("fine_sample_range", {}) as Dictionary).get("count", 0))
		var pivot_count := int((entry.get("pivot_range", {}) as Dictionary).get("count", 0))
		var sample_total := coarse_count + fine_count
		if sample_total > ProfileArenaLayoutScript.MAX_SAMPLES_PER_PROFILE:
			errors.append("%s: sample 数 %d（coarse %d + fine %d）超过 MAX_SAMPLES_PER_PROFILE %d" % [
				label, sample_total, coarse_count, fine_count,
				ProfileArenaLayoutScript.MAX_SAMPLES_PER_PROFILE])
		if pivot_count > ProfileArenaLayoutScript.MAX_PIVOTS_PER_PROFILE:
			errors.append("%s: pivot 数 %d 超过 MAX_PIVOTS_PER_PROFILE %d" % [
				label, pivot_count, ProfileArenaLayoutScript.MAX_PIVOTS_PER_PROFILE])
	return errors


## 诊断用的 profile 标识：优先 asset_id，其次资源路径，最后退到 profile_index。
static func _profile_label(entry: Dictionary, profile_index: int) -> String:
	var asset_id := str(entry.get("asset_id", ""))
	if not asset_id.is_empty():
		return asset_id
	var source_path := str(entry.get("source_path", ""))
	if not source_path.is_empty():
		return source_path
	return "profile_index=%d" % profile_index


## 把全部 staging 打包成一份完整的 CPU Arena（计划 §8.2）。
##
## 逐段 append 而不是"先 resize 再逐字节写"：GDScript 里按字节循环 3300 万次不可接受，
## 而 append_array / resize+fill 都是 C++ 侧的整块操作。每个区段边界都断言当前长度
## 等于 ProfileArenaLayout 算出的偏移——这就是字节级自检本身（计划 §12 数据正确性）。
## 未使用的 slot 与 slot 内未使用记录全部为零。
func _pack_arena_bytes() -> PackedByteArray:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	var out := PackedByteArray()

	# ── 全局 Arena Header（§10）──
	var header := PackedByteArray()
	header.resize(ProfileArenaLayoutScript.ARENA_HEADER_STRIDE_BYTES)
	header.fill(0)
	header.encode_u32(0, ProfileArenaLayoutScript.ARENA_MAGIC)
	header.encode_u32(4, ProfileArenaLayoutScript.ARENA_LAYOUT_VERSION)
	header.encode_u32(8, ProfileArenaLayoutScript.PROFILE_SLOT_STRIDE_BYTES)
	header.encode_u32(12, _staging_profile_table.size())
	header.encode_u32(16, ProfileArenaLayoutScript.ARENA_BYTE_COUNT)
	header.encode_u32(20, ProfileArenaLayoutScript.PROFILE_CAPACITY)
	header.encode_u32(24, ProfileArenaLayoutScript.MAX_SAMPLES_PER_PROFILE)
	header.encode_u32(28, ProfileArenaLayoutScript.MAX_PIVOTS_PER_PROFILE)
	out.append_array(header)
	_pad_to(out, ProfileArenaLayoutScript.PROFILE_SLOTS_OFFSET_BYTES)

	for slot_index in range(ProfileArenaLayoutScript.PROFILE_CAPACITY):
		var slot_base := ProfileArenaLayoutScript.slot_base_bytes(slot_index)
		if out.size() != slot_base:
			push_error("[AutoVoxelRuntimeProfileContainer] _pack_arena_bytes(): slot %d 起点错位（实得 %d，应为 %d）。" % [
				slot_index, out.size(), slot_base])
			assert(false, "AutoVoxelRuntimeProfileContainer._pack_arena_bytes: slot base misaligned")
			return PackedByteArray()
		if slot_index >= _staging_profile_table.size():
			# 未使用 slot：整槽保持零（§8.2 末段）。
			_pad_to(out, slot_base + ProfileArenaLayoutScript.PROFILE_SLOT_STRIDE_BYTES)
			continue
		if not _append_profile_slot(out, slot_index, slot_base):
			return PackedByteArray()

	if out.size() != ProfileArenaLayoutScript.ARENA_BYTE_COUNT:
		push_error("[AutoVoxelRuntimeProfileContainer] _pack_arena_bytes(): Arena 字节数不符（实得 %d，应为 %d）。" % [
			out.size(), ProfileArenaLayoutScript.ARENA_BYTE_COUNT])
		assert(false, "AutoVoxelRuntimeProfileContainer._pack_arena_bytes: arena byte count mismatch")
		return PackedByteArray()
	return out


## 追加一个已加载 profile 的完整 slot（Header → Samples → Pivots → MeshDescription）。
## slot_origin = 该 slot 在 out 里的起始偏移：整份 Arena 打包时传绝对 slot 基址，
## 单槽增量更新（§8.3）时传 0，两条路径因此共用同一个编码器。
func _append_profile_slot(out: PackedByteArray, slot_index: int, slot_origin: int) -> bool:
	var entry: Dictionary = _staging_profile_table[slot_index]
	var slot_base := slot_origin
	var label := _profile_label(entry, slot_index)

	var coarse_range: Dictionary = entry.get("coarse_sample_range", {})
	var fine_range: Dictionary = entry.get("fine_sample_range", {})
	var pivot_range: Dictionary = entry.get("pivot_range", {})
	var coarse_start := int(coarse_range.get("start", 0))
	var coarse_count := int(coarse_range.get("count", 0))
	var fine_start := int(fine_range.get("start", 0))
	var fine_count := int(fine_range.get("count", 0))
	var pivot_start := int(pivot_range.get("start", 0))
	var pivot_count := int(pivot_range.get("count", 0))

	# staging 契约：同一 profile 的 coarse 段与 fine 段在全局样本缓冲里紧邻（先 coarse
	# 后 fine，见 _register_pre_normalized_profile），slot 打包按这一点整段切片。
	if fine_count > 0 and fine_start != coarse_start + coarse_count:
		push_error("[AutoVoxelRuntimeProfileContainer] _append_profile_slot(): %s 的 coarse/fine 样本段不相邻（coarse=[%d,+%d) fine 起于 %d）—— staging 契约被破坏。" % [
			label, coarse_start, coarse_count, fine_start])
		assert(false, "AutoVoxelRuntimeProfileContainer._append_profile_slot: non-contiguous sample groups")
		return false

	var sample_count := coarse_count + fine_count
	if sample_count > ProfileArenaLayoutScript.MAX_SAMPLES_PER_PROFILE or pivot_count > ProfileArenaLayoutScript.MAX_PIVOTS_PER_PROFILE:
		push_error("[AutoVoxelRuntimeProfileContainer] _append_profile_slot(): %s 超出固定 slot 上限（sample %d/%d, pivot %d/%d）—— 应在 validate_arena_capacity() 阶段就被拦下。" % [
			label, sample_count, ProfileArenaLayoutScript.MAX_SAMPLES_PER_PROFILE,
			pivot_count, ProfileArenaLayoutScript.MAX_PIVOTS_PER_PROFILE])
		assert(false, "AutoVoxelRuntimeProfileContainer._append_profile_slot: slot capacity exceeded")
		return false

	# ── Header：range 改写为**槽内局部**下标（coarse 从 0 起，fine 紧随其后）──
	var header := PackedByteArray()
	header.resize(ProfileArenaLayoutScript.PROFILE_HEADER_STRIDE_BYTES)
	header.fill(0)
	_encode_profile_table_record(
		header, 0, entry, slot_index,
		{"start": 0, "count": coarse_count},
		{"start": coarse_count, "count": fine_count},
		{"start": 0, "count": pivot_count}
	)
	out.append_array(header)
	_pad_to(out, slot_base + ProfileArenaLayoutScript.PROFILE_SAMPLE_OFFSET_BYTES)

	# ── Samples ──
	if sample_count > 0:
		var src_begin := coarse_start * ProfileArenaLayoutScript.PROFILE_SAMPLE_STRIDE_BYTES
		var src_end := src_begin + sample_count * ProfileArenaLayoutScript.PROFILE_SAMPLE_STRIDE_BYTES
		if src_end > _staging_profile_sample_bytes.size():
			push_error("[AutoVoxelRuntimeProfileContainer] _append_profile_slot(): %s 的样本切片越过 staging 字节流（需 [%d,%d)，实有 %d）。" % [
				label, src_begin, src_end, _staging_profile_sample_bytes.size()])
			assert(false, "AutoVoxelRuntimeProfileContainer._append_profile_slot: sample slice out of range")
			return false
		out.append_array(_staging_profile_sample_bytes.slice(src_begin, src_end))
	_pad_to(out, slot_base + ProfileArenaLayoutScript.PROFILE_PIVOT_OFFSET_BYTES)

	# ── Pivots ──
	if pivot_count > 0:
		if pivot_start + pivot_count > _staging_pivot_records.size():
			push_error("[AutoVoxelRuntimeProfileContainer] _append_profile_slot(): %s 的 pivot 切片越过 staging（需 [%d,%d)，实有 %d）。" % [
				label, pivot_start, pivot_start + pivot_count, _staging_pivot_records.size()])
			assert(false, "AutoVoxelRuntimeProfileContainer._append_profile_slot: pivot slice out of range")
			return false
		out.append_array(pack_pivot_records(
			_staging_pivot_records.slice(pivot_start, pivot_start + pivot_count)))
	_pad_to(out, slot_base + ProfileArenaLayoutScript.PROFILE_MESH_OFFSET_BYTES)

	# ── MeshDescription：保留占位、恒为零（mesh 与 profile 基数不同，见上文说明）──
	_pad_to(out, slot_base + ProfileArenaLayoutScript.PROFILE_SLOT_STRIDE_BYTES)
	return true


## 构建单个 slot 的完整字节（零初始化 + Header/Samples/Pivots/Mesh），长度恒为
## PROFILE_SLOT_STRIDE_BYTES。失败返回空数组。
func build_slot_bytes(slot_index: int) -> PackedByteArray:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	if slot_index < 0 or slot_index >= _staging_profile_table.size():
		push_error("[AutoVoxelRuntimeProfileContainer] build_slot_bytes(): slot_index=%d 未注册（已注册 %d 个）。" % [
			slot_index, _staging_profile_table.size()])
		assert(false, "AutoVoxelRuntimeProfileContainer.build_slot_bytes: slot_index not registered")
		return PackedByteArray()
	var slot := PackedByteArray()
	if not _append_profile_slot(slot, slot_index, 0):
		return PackedByteArray()
	if slot.size() != ProfileArenaLayoutScript.PROFILE_SLOT_STRIDE_BYTES:
		push_error("[AutoVoxelRuntimeProfileContainer] build_slot_bytes(): slot %d 字节数 %d ≠ stride %d。" % [
			slot_index, slot.size(), ProfileArenaLayoutScript.PROFILE_SLOT_STRIDE_BYTES])
		assert(false, "AutoVoxelRuntimeProfileContainer.build_slot_bytes: slot byte count mismatch")
		return PackedByteArray()
	return slot


## 单 Profile Slot 局部更新（计划 §8.3）。
##
##     构建一个完整的零初始化 Slot → 写 Header/Samples/Pivots/Mesh
##       → 更新 Arena 对应字节范围 → 推进 Arena Revision
##
## **整槽覆盖**：即使只改了一个 Sample 也重写整个 slot，保证 slot 内部始终自洽，
## 不会出现 Header 说有 N 条而 Sample 区还是上一版的中间态。
## 其它 slot 的字节一个都不碰（这正是固定槽位换来的性质）。
##
## 前置：Arena 必须已存在（先跑过一次 upload_profiles）。staging 侧的该 profile 必须
## 已经是新内容——本函数只负责把它刷到 GPU，不负责重新归一化 descriptor。
##
## ⚠ 身份约束：profile 的身份是**内容 hash**（_profile_id_from_hash）。改了 descriptor 的
## color/complexity/collision/samples/pivots 会得到**另一个** profile_hash ⇒ 另一个
## profile_id 与另一个 slot，那属于"注册新 profile"，走全量路径，不是本函数的场景。
## 本函数适用的是 **hash 不变、slot 内容需要重刷**的情形——典型是 Mesh Description
## 变了（mesh 不参与 profile_hash），见 ScenePlacementRuntime.refresh_slot_mesh_description()。
func update_profile_slot(slot_index: int) -> bool:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	if _rd == null:
		_last_upload_error = "no_rendering_device"
		push_error("[AutoVoxelRuntimeProfileContainer] update_profile_slot(): RenderingDevice 为 null。")
		assert(false, "AutoVoxelRuntimeProfileContainer.update_profile_slot: no RenderingDevice")
		return false
	var arena_rid: RID = _gpu_buffers.get(PROFILE_ARENA_BUFFER, RID())
	if not arena_rid.is_valid():
		_last_upload_error = "profile_arena_not_uploaded"
		push_error("[AutoVoxelRuntimeProfileContainer] update_profile_slot(): Arena 尚未上传，无法做局部更新（先跑一次 upload_profiles）。")
		assert(false, "AutoVoxelRuntimeProfileContainer.update_profile_slot: arena not uploaded")
		return false

	# 单槽也要过容量校验：超限的 slot 必须明确失败，不能只把前 N 条塞进去。
	var capacity_errors := validate_arena_capacity()
	if not capacity_errors.is_empty():
		_last_upload_error = "profile_arena_capacity_exceeded: %s" % "; ".join(capacity_errors)
		push_error("[AutoVoxelRuntimeProfileContainer] update_profile_slot(): 固定 Slot 容量超限，拒绝局部更新：\n  %s" % "\n  ".join(capacity_errors))
		assert(false, "AutoVoxelRuntimeProfileContainer.update_profile_slot: fixed slot capacity exceeded")
		return false

	var slot_bytes := build_slot_bytes(slot_index)
	if slot_bytes.is_empty():
		_last_upload_error = "profile_arena_slot_pack_failed:%d" % slot_index
		return false

	var update_range := ProfileArenaLayoutScript.slot_update_range(slot_index)
	var offset_bytes := int(update_range["offset_bytes"])
	var size_bytes := int(update_range["size_bytes"])
	if offset_bytes + size_bytes > ProfileArenaLayoutScript.ARENA_BYTE_COUNT:
		_last_upload_error = "profile_arena_slot_range_out_of_bounds:%d" % slot_index
		push_error("[AutoVoxelRuntimeProfileContainer] update_profile_slot(): slot %d 的更新范围 [%d,%d) 越过 Arena 字节数 %d。" % [
			slot_index, offset_bytes, offset_bytes + size_bytes,
			ProfileArenaLayoutScript.ARENA_BYTE_COUNT])
		assert(false, "AutoVoxelRuntimeProfileContainer.update_profile_slot: slot range out of bounds")
		return false

	var err := _rd.buffer_update(arena_rid, offset_bytes, size_bytes, slot_bytes)
	if err != OK:
		_last_upload_error = "profile_arena_buffer_update_failed:%d:%d" % [slot_index, err]
		push_error("[AutoVoxelRuntimeProfileContainer] update_profile_slot(): buffer_update 失败（slot %d, err %d）。" % [slot_index, err])
		assert(false, "AutoVoxelRuntimeProfileContainer.update_profile_slot: buffer_update failed")
		return false

	# 局部更新也推进同一个 Arena Revision——消费方只认这一个版本号（§14）。
	# ⚠ 只更新了一个 slot，**不能**把 uploaded_revision 对齐到 staging_revision：
	# 其它 slot 若也脏着，整份 Arena 仍需一次全量重传，is_runtime_ready() 必须继续
	# 反映这一点。故这里只推 gpu_revision 并清掉该 profile 的 dirty 标记。
	_gpu_revision += 1
	_last_upload_error = ""
	var profile_id := int((_staging_profile_table[slot_index] as Dictionary).get("profile_id", -1))
	if profile_id >= 0:
		dirty_profile_ids.erase(profile_id)

	# 该 slot 已与 staging 一致。若同时满足：没有别的脏 profile、且 profile 数与上次
	# 全量上传时相同（没新增/删除 ⇒ 全局 Arena Header 仍然正确），那么整份 Arena 就
	# 重新等价于 staging，runtime 可直接恢复就绪，不必再拖一次 32 MiB 全量重传。
	# 否则保持 not-ready，由调用方走 upload_profiles() 全量路径。
	if dirty_profile_ids.is_empty() and _uploaded_profile_count == _staging_profile_table.size():
		_uploaded_revision = _staging_revision
		_gpu_runtime_ready = true
	return true


## 用零把 out 补到 target_size（区段间对齐填充与未使用槽位）。
static func _pad_to(out: PackedByteArray, target_size: int) -> void:
	var missing := target_size - out.size()
	if missing <= 0:
		return
	var pad := PackedByteArray()
	pad.resize(missing)
	pad.fill(0)
	out.append_array(pad)


## Arena 字节流 → 单个 slot 的可读快照（计划 §12「Arena 解码后…与 Descriptor 一致」）。
## 纯静态、不碰 GPU：CPU staging 与 GPU 回读都能用同一个解码器验证。
static func decode_arena_slot(bytes: PackedByteArray, slot_index: int) -> Dictionary:
	if slot_index < 0 or slot_index >= ProfileArenaLayoutScript.PROFILE_CAPACITY:
		push_error("[AutoVoxelRuntimeProfileContainer] decode_arena_slot(): slot_index=%d 越界（PROFILE_CAPACITY=%d）。" % [
			slot_index, ProfileArenaLayoutScript.PROFILE_CAPACITY])
		assert(false, "AutoVoxelRuntimeProfileContainer.decode_arena_slot: slot_index out of range")
		return {}
	# 只要求覆盖到本 slot 末尾：调试回读通常只拉"已加载 slot"那一段，而不是整份
	# 32 MiB Arena，用整份长度做门槛会把合法的部分回读判成损坏。
	var slot_end := ProfileArenaLayoutScript.mesh_address(slot_index) \
		+ ProfileArenaLayoutScript.PROFILE_MESH_STRIDE_BYTES
	if bytes.size() < slot_end:
		push_error("[AutoVoxelRuntimeProfileContainer] decode_arena_slot(): 字节数 %d 不足以覆盖 slot %d（需 %d）。" % [
			bytes.size(), slot_index, slot_end])
		assert(false, "AutoVoxelRuntimeProfileContainer.decode_arena_slot: bytes shorter than slot end")
		return {}
	var base := ProfileArenaLayoutScript.slot_base_bytes(slot_index) + ProfileArenaLayoutScript.PROFILE_HEADER_OFFSET_BYTES
	var coarse_count := int(bytes.decode_u32(base + 12))
	var fine_count := int(bytes.decode_u32(base + 20))
	var pivot_count := int(bytes.decode_u32(base + 28))
	var sample_begin := ProfileArenaLayoutScript.sample_address(slot_index, 0)
	var sample_end := ProfileArenaLayoutScript.sample_address(slot_index, coarse_count + fine_count)
	var pivot_begin := ProfileArenaLayoutScript.pivot_address(slot_index, 0)
	var pivot_end := ProfileArenaLayoutScript.pivot_address(slot_index, pivot_count)
	var mesh_begin := ProfileArenaLayoutScript.mesh_address(slot_index)
	return {
		"slot_index": slot_index,
		"profile_id": int(bytes.decode_u32(base + 0)),
		"profile_index": int(bytes.decode_u32(base + 4)),
		"coarse_sample_start": int(bytes.decode_u32(base + 8)),
		"coarse_sample_count": coarse_count,
		"fine_sample_start": int(bytes.decode_u32(base + 16)),
		"fine_sample_count": fine_count,
		"pivot_start": int(bytes.decode_u32(base + 24)),
		"pivot_count": pivot_count,
		"color": Color(
			bytes.decode_float(base + 32),
			bytes.decode_float(base + 36),
			bytes.decode_float(base + 40),
			bytes.decode_float(base + 44)
		),
		"semantic_probe_density": bytes.decode_float(base + 48),
		"context_sensing_radius": bytes.decode_float(base + 52),
		"profile_hash_u32": int(bytes.decode_u32(base + 56)),
		"decoded_samples": ProfileRecordSchemaScript.decode_profile_sample_records(
			bytes.slice(sample_begin, sample_end)),
		"pivot_bytes": bytes.slice(pivot_begin, pivot_end),
		# 保留占位区的原样切片：当前恒为零（mesh 与 profile 基数不同，Mesh 区不写），
		# 解出来供"未使用区必须为零"这条验证项（计划 §12）直接断言。
		"mesh_reserved_bytes": bytes.slice(
			mesh_begin, mesh_begin + ProfileArenaLayoutScript.PROFILE_MESH_STRIDE_BYTES),
	}


## Arena 全局 header 解码（magic/version/容量等，计划 §10）。
static func decode_arena_header(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < ProfileArenaLayoutScript.ARENA_HEADER_STRIDE_BYTES:
		return {}
	return {
		"magic": int(bytes.decode_u32(0)),
		"layout_version": int(bytes.decode_u32(4)),
		"slot_stride_bytes": int(bytes.decode_u32(8)),
		"loaded_profile_count": int(bytes.decode_u32(12)),
		"arena_byte_count": int(bytes.decode_u32(16)),
		"profile_capacity": int(bytes.decode_u32(20)),
		"max_samples_per_profile": int(bytes.decode_u32(24)),
		"max_pivots_per_profile": int(bytes.decode_u32(28)),
	}


## Converts legacy descriptor voxels to canonical fine samples and adds clearance.
static func _profile_samples_from_legacy_asset_voxels(
	asset_voxels: Array, voxel_size: Vector3
) -> Array[Dictionary]:
	return ProfileRecordSchemaScript.profile_samples_from_legacy_voxels(
		asset_voxels,
		[],
		Color.WHITE,
		1.0,
		voxel_size,
		ProfileRecordSchemaScript.LEGACY_CLEARANCE_FLAG)


## 按 buffer 名称返回其对应的 stride 字节数，未知名称返回 0。
func _stride_for_buffer(buffer_name: String) -> int:
	match buffer_name:
		PROFILE_ARENA_BUFFER:
			return ProfileArenaLayoutScript.PROFILE_SLOT_STRIDE_BYTES
		_:
			return 0


## 将 descriptor 资源归一化为统一的 profile 记录：提取共享字段（color/complexity/collision）、按 density（受 density_override 影响并 clamp 到 0.1-8.0）经 get_profile_samples 取 ProfileSample（有 mesh 时传 mesh/world_scale/collision）、取 pivot variants 与 context_sensing_radius；descriptor 为 null 时返回空记录。
static func normalize_descriptor(
	descriptor: Resource,
	default_radius: float = 0.0,
	density_override: float = -1.0,
	world_scale: Vector3 = Vector3.ONE,
	mesh: Mesh = null
) -> Dictionary:
	if descriptor == null:
		# 旧行为返回一条"空 normalized record"——它带着合法的 profile_hash，会被注册成一个
		# 无样本的幽灵 profile 并进入 GPU profile table。改为返回空字典硬失败。
		push_error("[AutoVoxelRuntimeProfileContainer] normalize_descriptor(): descriptor 为 null —— 不生成空 profile 记录。")
		assert(false, "AutoVoxelRuntimeProfileContainer.normalize_descriptor: null descriptor")
		return {}
	var shared_fields := SharedPropertyTypeScript.from_descriptor(descriptor, default_radius)
	var collision := SharedPropertyTypeScript.duplicate_dictionary_array(shared_fields.get("collision", []))
	var semantic_probe_density := clampf(
		density_override if density_override > 0.0 else VariantUtils.float_property(descriptor, "semantic_probe_density", 1.0),
		0.1,
		8.0
	)
	var profile_samples: Array = []
	if descriptor.has_method("get_profile_samples"):
		profile_samples = descriptor.call(
			"get_profile_samples", mesh, semantic_probe_density, world_scale, collision)

	var pivots: Array = []
	if descriptor.has_method("get_pivot_variants"):
		pivots = descriptor.call("get_pivot_variants")
	elif VariantUtils.has_property(descriptor, "pivot_variants"):
		var raw_pivots = descriptor.get("pivot_variants")
		if raw_pivots is Array:
			pivots = raw_pivots
	return _normalize_profile_record({
		"source_kind": "descriptor",
		"source_path": descriptor.resource_path,
		"asset_id": str(VariantUtils.property_or_default(descriptor, "asset_id", "")),
		"object_type": str(VariantUtils.property_or_default(descriptor, "object_type", "")),
		"color": shared_fields.get("color", Color.WHITE),
		"complexity": float(shared_fields.get("complexity", 1.0)),
		"collision": collision,
		"profile_samples": profile_samples,
		"pivot_variants": pivots,
		"collision_voxel_size": VariantUtils.float_property(descriptor, "collision_voxel_size", 1.0),
		"semantic_probe_density": semantic_probe_density,
		"context_sensing_radius": VariantUtils.float_property(descriptor, "context_sensing_radius", 0.0),
	})


static func _normalize_asset_voxels(
	raw_asset_voxels: Array,
	fallback_collision: Array,
	fallback_color: Color,
	fallback_complexity: float
) -> Array[Dictionary]:
	var source := raw_asset_voxels if not raw_asset_voxels.is_empty() else fallback_collision
	var result: Array[Dictionary] = []
	for raw_entry in source:
		if not raw_entry is Dictionary:
			continue
		var entry := raw_entry as Dictionary
		if not bool(entry.get("enabled", true)):
			continue
		var voxel := VoxelGeneral.collision_local_voxel(entry)
		var color := VariantUtils.color_from_value(entry.get("color", fallback_color), fallback_color)
		var complexity := clampf(float(entry.get("complexity", color.a if entry.has("color") else fallback_complexity)), 0.0, 1.0)
		color.a = complexity
		result.append({
			"voxel": voxel,
			"color": color,
			"complexity": complexity,
			"collision_strength": ProfileRecordSchemaScript.collision_strength(entry),
			"weight": maxf(float(entry.get("weight", 1.0)), 0.0),
			"flags": int(entry.get("flags", 0)),
		})
	return result


static func _normalized_profile_samples(raw_samples: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for raw_sample in raw_samples:
		if not raw_sample is Dictionary:
			continue
		var sample := ProfileRecordSchemaScript.normalize_profile_sample(raw_sample as Dictionary)
		if ProfileRecordSchemaScript.is_valid_profile_sample(sample):
			result.append(sample)
	return result


# ⚠ 这里曾有 `_has_sample_stage()`：与 asset_descriptor.gd 的
# `_profile_samples_have_stage()` 同体异名的逐字副本。判定式已收进 flags 语义的 SSOT
# 所在地 `utils/profile_record_schema.gd:samples_have_stage()`（2026-08-17）。


## 把任意 raw_profile 字典规整为标准 profile 记录：clamp complexity 并写入 color.a、归一化 collision/pivot/probes、clamp 密度与感知半径，并据规范字段计算稳定的 profile_hash。
static func _normalize_profile_record(raw_profile: Dictionary) -> Dictionary:
	var color := VariantUtils.color_from_value(raw_profile.get("color", Color.WHITE), Color.WHITE)
	var complexity := clampf(float(raw_profile.get("complexity", color.a)), 0.0, 1.0)
	color.a = complexity

	var collision := VoxelGeneral.normalize_collision_samples(_array_from_value(raw_profile.get("collision", [])), 0.0)
	var asset_voxels := _normalize_asset_voxels(
		_array_from_value(raw_profile.get("asset_voxels", [])),
		collision,
		color,
		complexity
	)
	var pivots := AssetDescriptorScript.normalize_pivot_variants(_array_from_value(raw_profile.get("pivot_variants", [])))
	var probes := SemanticProbeGeneratorScript.duplicate_probe_array(_array_from_value(raw_profile.get("semantic_probes", [])))
	var profile_samples := _normalized_profile_samples(_array_from_value(raw_profile.get("profile_samples", [])))
	if not ProfileRecordSchemaScript.samples_have_stage(profile_samples, ProfileRecordSchemaScript.SAMPLE_FLAG_COARSE):
		profile_samples.append_array(ProfileRecordSchemaScript.profile_samples_from_legacy_probes(probes))
	if not ProfileRecordSchemaScript.samples_have_stage(profile_samples, ProfileRecordSchemaScript.SAMPLE_FLAG_FINE):
		var legacy_voxel_size := maxf(float(raw_profile.get("collision_voxel_size", 1.0)), 1.0e-6)
		profile_samples.append_array(_profile_samples_from_legacy_asset_voxels(
			asset_voxels, Vector3.ONE * legacy_voxel_size))

	var normalized := {
		"source_kind": str(raw_profile.get("source_kind", "")),
		"source_path": str(raw_profile.get("source_path", "")),
		"asset_id": str(raw_profile.get("asset_id", "")),
		"object_type": str(raw_profile.get("object_type", "")),
		"color": color,
		"complexity": complexity,
		"collision": collision,
		"profile_samples": profile_samples,
		"pivot_variants": pivots,
		"semantic_probe_density": clampf(float(raw_profile.get("semantic_probe_density", 1.0)), 0.1, 8.0),
		"context_sensing_radius": maxf(float(raw_profile.get("context_sensing_radius", 0.0)), 0.0),
	}
	normalized["profile_hash"] = HashUtils.stable_hex_from_string(CanonicalHash.canonical_string(_profile_hash_source(normalized)))
	return normalized


## 从归一化记录提取用于计算 profile_hash 的来源字典（collision/pivot/probes 转为已排序的 canonical 字符串以保证哈希稳定）。
static func _profile_hash_source(normalized: Dictionary) -> Dictionary:
	return {
		"color": normalized.get("color", Color.WHITE),
		"complexity": float(normalized.get("complexity", 1.0)),
		"collision": CanonicalHash.sorted_canonical_entries(normalized.get("collision", [])),
		"profile_samples": CanonicalHash.sorted_canonical_entries(normalized.get("profile_samples", [])),
		"pivot_variants": CanonicalHash.sorted_canonical_entries(normalized.get("pivot_variants", [])),
		"semantic_probe_density": float(normalized.get("semantic_probe_density", 1.0)),
		"context_sensing_radius": float(normalized.get("context_sensing_radius", 0.0)),
	}


## 由 profile_hash 派生稳定正整数 profile_id（u31 hash，<=0 时取 1），并线性探测解决与不同 hash 的 id 冲突。
func _profile_id_from_hash(profile_hash: String) -> int:
	var profile_id := HashUtils.stable_u31_from_string("profile_id:" + profile_hash)
	if profile_id <= 0:
		profile_id = 1
	while _profile_id_to_hash.has(profile_id) and str(_profile_id_to_hash[profile_id]) != profile_hash:
		profile_id += 1
		if profile_id <= 0:
			profile_id = 1
	return profile_id


## Appends immutable normalized records to the staging array and returns their range.
func _append_range(target: Array[Dictionary], source) -> Dictionary:
	var start := target.size()
	if source is Array:
		target.append_array(source)
	return {
		"start": start,
		"count": target.size() - start,
		"end": target.size(),
	}


func _append_profile_sample_group(source: Array) -> Dictionary:
	var start := _staging_profile_sample_record_count
	_staging_profile_sample_groups.append(source)
	_staging_profile_sample_record_count += source.size()
	return {
		"start": start,
		"count": source.size(),
		"end": _staging_profile_sample_record_count,
	}


## 构建带 profile_id/profile_index 标识的 range 条目（start/count/end 来自 range_data）。
static func _make_range_entry(profile_id: int, profile_index: int, range_data: Dictionary) -> Dictionary:
	return {
		"profile_id": profile_id,
		"profile_index": profile_index,
		"start": int(range_data.get("start", 0)),
		"count": int(range_data.get("count", 0)),
		"end": int(range_data.get("end", 0)),
	}


## 若 value 是 Array 则返回其深拷贝，否则返回空数组。
static func _array_from_value(value) -> Array:
	if value is Array:
		return (value as Array).duplicate(true)
	return []


## 为 descriptor 生成稳定的 source_key：有 resource_path 用 "path:..."，否则用 "instance:实例id"；descriptor 为 null 返回空串。
static func _descriptor_source_key(descriptor: Resource) -> String:
	if descriptor == null:
		return ""
	if not descriptor.resource_path.is_empty():
		return "path:%s" % descriptor.resource_path
	return "instance:%d" % descriptor.get_instance_id()
