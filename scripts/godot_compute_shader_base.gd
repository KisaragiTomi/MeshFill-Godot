class_name GodotComputeShaderBase
extends RefCounted

const SCOPE_PERSISTENT := "persistent"
const SCOPE_FRAME := "frame"
const SCOPE_PASS := "pass"

const KIND_BUFFER := "buffer"
const KIND_TEXTURE := "texture"
const KIND_SAMPLER := "sampler"
const KIND_SHADER := "shader"
const KIND_PIPELINE := "pipeline"
const KIND_UNIFORM_SET := "uniform_set"
const KIND_OTHER := "other"

const OWNED := true
const BORROWED := false
const _BUFFER_ZERO_UPDATE_CHUNK_BYTES := 1048576

const _DEFAULT_GC_ORDER := {
	KIND_UNIFORM_SET: 10,
	KIND_PIPELINE: 20,
	KIND_SHADER: 30,
	KIND_SAMPLER: 40,
	KIND_TEXTURE: 50,
	KIND_BUFFER: 60,
	KIND_OTHER: 100,
}

var log_name := "GodotComputeShaderBase"
var sync_global_device := false

var _rd: RenderingDevice
var _owns_rendering_device := false
var _disposed := true
var _compute_list_active := false
var _buffer_zero_scratch := PackedByteArray()

var _resources: Array[Dictionary] = []
## ensure_shader_kernel() 的常驻 shader/pipeline 注册表：path → {"shader","pipeline","mtime"}。
## 只是命中索引——RID 本身仍登记在下面的 _resources 里（SCOPE_PERSISTENT、本宿主自有），
## 所有权与 GC 审计语义不变。设备是 per-host 的，所以注册表也必须是成员而非 static。
var _kernel_registry: Dictionary = {}
## shader RID id → 源路径，只服务于编译计时探针：create_compute_pipeline() 只拿得到 shader RID
## 与自由格式 label，靠这张表把 pipeline 段的耗时归到与 shader 段同一个 path 键下。
var _shader_stat_paths: Dictionary = {}
var _deferred_gc_scopes: Array[String] = []
var _kind_orders: Dictionary = _DEFAULT_GC_ORDER.duplicate()
var _next_resource_id := 1

## GLSL→SPIR-V 前端编译结果的进程级缓存：键为 shader 路径，值 {"spirv": RDShaderSPIRV, "mtime": int}，
## 按源文件修改时间失效。SPIR-V 字节码与具体 RenderingDevice 无关，可跨本地/全局设备与
## 短生命周期实例（如每次 Place 新建的 runner）复用；只缓存 CPU 侧字节码、不缓存任何 RID，
## 因此不改变 scope GC 与资源审计的生命周期语义。编译失败的结果不入缓存。
## 无锁：load_compute_shader 的全部调用方都在主线程（display writer 一族不经过本 loader）；
## 且 Object 型 static（如 Mutex）会在编辑器脚本重载时被重置为 null，不可依赖。
## 类型化 Dictionary 的零值是 {}，不受 static 初始化器失效影响。
static var _spirv_source_cache: Dictionary = {}

## shader 编译计时探针：键为 shader 路径，值为
## {"spirv_usec","module_usec","pipeline_usec","spirv_calls","module_calls","pipeline_calls"}。
## 三段分别对应 glslang 前端（仅 SPIR-V 缓存未命中时计入）、shader_create_from_spirv
## （SPIR-V 反射 + zstd 压缩/解压 + shader module 创建）与 compute_pipeline_create
## （驱动 SPIR-V→ISA 编译）。local RenderingDevice 拿不到驱动的 VkPipelineCache
## （rendering_device.cpp 里 pipeline cache 只给 is_main_instance 建），后两段每次调用都是
## 冷成本，所以要能分别量出来。与 _spirv_source_cache 同为类型化 static Dictionary。
static var _compile_stats: Dictionary = {}


## 返回编译计时统计的深拷贝（path → 三段耗时/次数）。供编辑器 bridge 读数与诊断报告使用。
static func get_shader_compile_stats() -> Dictionary:
	var snapshot: Dictionary = {}
	for path in _compile_stats:
		snapshot[path] = (_compile_stats[path] as Dictionary).duplicate()
	return snapshot


static func reset_shader_compile_stats() -> void:
	_compile_stats.clear()


static func _record_compile_usec(path: String, phase: String, usec: int) -> void:
	var entry: Dictionary = _compile_stats.get(path, {})
	entry[phase + "_usec"] = int(entry.get(phase + "_usec", 0)) + usec
	entry[phase + "_calls"] = int(entry.get(phase + "_calls", 0)) + 1
	_compile_stats[path] = entry


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if not _disposed:
			dispose()


## 共有的 RenderingDevice 获取逻辑：优先创建本地 device（owns=true），否则回退到
## 全局 device（owns=false）；两者都失败时 rd 为 null。以静态形式暴露，供本基类的
## ensure_device() 与不继承本基类的 GPU 持有者（如 AutoVoxelRuntimeProfileContainer）
## 共用，避免各处重复实现 create_local + global-fallback 的获取代码。
static func acquire_rendering_device(prefer_local_device: bool = true, allow_global_fallback: bool = true) -> Dictionary:
	var rd: RenderingDevice = null
	if prefer_local_device:
		rd = RenderingServer.create_local_rendering_device()
	if rd != null:
		return {"rd": rd, "owns": true}
	if allow_global_fallback:
		rd = RenderingServer.get_rendering_device()
	return {"rd": rd, "owns": false}


func ensure_device(prefer_local_device: bool = true, allow_global_fallback: bool = true) -> bool:
	if _rd != null:
		return true

	var acquired := acquire_rendering_device(prefer_local_device, allow_global_fallback)
	_rd = acquired["rd"]
	_owns_rendering_device = acquired["owns"]

	if _rd == null:
		if DisplayServer.get_name() == "headless":
			push_error("%s: no RenderingDevice — 当前以 --headless 启动，GPU 路径不可用。请改用 --rendering-driver vulkan 运行（编辑器启动命令见 CLAUDE.md）。" % log_name)
		else:
			push_error("%s.ensure_device(): 无法获取 RenderingDevice（prefer_local=%s, allow_global_fallback=%s）—— GPU 路径不可恢复，不降级到 CPU。" % [
				log_name, prefer_local_device, allow_global_fallback])
		assert(false, "GodotComputeShaderBase.ensure_device: no RenderingDevice")
		return false

	_disposed = false
	_on_device_ready()
	return true


func attach_rendering_device(rendering_device: RenderingDevice, owns_device: bool = false) -> bool:
	if rendering_device == null:
		push_error("%s.attach_rendering_device(): 外部传入的 RenderingDevice 为 null —— 拒绝绑定。" % log_name)
		assert(false, "GodotComputeShaderBase.attach_rendering_device: null RenderingDevice")
		return false

	if _rd != null and _rd != rendering_device:
		# 旧设备上登记的 RID 换设备后会在错误的设备上被绑定/释放，必须显式 dispose() 而非静默替换。
		push_error("%s.attach_rendering_device(): 试图替换正在使用的 RenderingDevice（已登记 %d 条资源）—— 必须先 dispose()。" % [
			log_name, _resources.size()])
		assert(false, "GodotComputeShaderBase.attach_rendering_device: replacing an active RenderingDevice")
		return false

	_rd = rendering_device
	_owns_rendering_device = owns_device
	_disposed = false
	_on_device_ready()
	return true


func get_rendering_device() -> RenderingDevice:
	return _rd


func owns_rendering_device() -> bool:
	return _owns_rendering_device


## 从任意协作对象读取其 RenderingDevice：对象非 null 且暴露 get_rendering_device() 时返回该设备，
## 否则返回 null。共有静态形式，供各处以鸭子类型方式借用 committer/runtime/profile 容器的设备，
## 收敛重复的 has_method("get_rendering_device") + call(...) 样板。
## 注意：返回 null 无法区分“对象无此方法”与“方法返回 null”；需要区分二者的调用点
## （如 GPUAutoObjectRuntime 里带专属 reason 的契约校验）应保留各自独立的 has_method() 判断。
static func rendering_device_of(object: Object) -> RenderingDevice:
	if object != null and object.has_method("get_rendering_device"):
		return object.call("get_rendering_device")
	return null


func dispose(sync_before_free: bool = false) -> void:
	if _disposed:
		return
	_disposed = true

	_on_before_dispose()
	if sync_before_free:
		submit_and_sync(sync_global_device)
	gc_all(false)

	if _rd != null and _owns_rendering_device:
		_rd.free()

	_repair_kernel_members()
	_kernel_registry.clear()
	_shader_stat_paths.clear()
	_rd = null
	_owns_rendering_device = false
	_compute_list_active = false
	_deferred_gc_scopes.clear()
	_on_after_dispose()


func submit_and_sync(include_global_device: bool = false) -> void:
	if _rd == null:
		return
	if _owns_rendering_device or include_global_device:
		_rd.submit()
		_rd.sync()


func track_rid(
	rid: RID,
	kind: String = KIND_OTHER,
	scope: String = "",
	label: String = "",
	disposer: Callable = Callable(),
	owned: bool = OWNED
) -> RID:
	if not rid.is_valid():
		return rid

	var resolved_scope: String = scope
	if resolved_scope.is_empty():
		resolved_scope = SCOPE_PERSISTENT

	for entry in _resources:
		if bool(entry.get("alive", false)) and entry.get("rid", RID()) == rid:
			entry["kind"] = kind
			entry["scope"] = resolved_scope
			entry["label"] = label
			entry["disposer"] = disposer
			entry["owned"] = owned
			return rid

	_resources.append({
		"id": _next_resource_id,
		"rid": rid,
		"kind": kind,
		"scope": resolved_scope,
		"label": label,
		"disposer": disposer,
		"owned": owned,
		"alive": true,
	})
	_next_resource_id += 1
	return rid


func track_borrowed_rid(
	rid: RID,
	kind: String = KIND_OTHER,
	scope: String = SCOPE_PERSISTENT,
	label: String = ""
) -> RID:
	return track_rid(rid, kind, scope, label, Callable(), BORROWED)


func untrack_rid(rid: RID) -> RID:
	for entry in _resources:
		if bool(entry.get("alive", false)) and entry.get("rid", RID()) == rid:
			entry["alive"] = false
			break
	_compact_dead_resources()
	return rid


func release_rid(rid: RID, defer_if_busy: bool = true) -> void:
	if not rid.is_valid():
		return
	if _compute_list_active and defer_if_busy:
		var scope: String = "_rid_%d" % _next_resource_id
		for entry in _resources:
			if bool(entry.get("alive", false)) and entry.get("rid", RID()) == rid:
				entry["scope"] = scope
				_queue_gc_scope(scope)
				return
		track_rid(rid, KIND_OTHER, scope, "deferred_untracked")
		_queue_gc_scope(scope)
		return

	for entry in _resources:
		if bool(entry.get("alive", false)) and entry.get("rid", RID()) == rid:
			_free_entry(entry)
			_compact_dead_resources()
			return
	if _rd != null:
		_rd.free_rid(rid)


func gc_scope(scope: String, defer_if_busy: bool = true) -> void:
	if scope.is_empty():
		return
	if _compute_list_active and defer_if_busy:
		_queue_gc_scope(scope)
		return
	_collect_entries(func(entry: Dictionary) -> bool:
		return str(entry.get("scope", "")) == scope
	)


func gc_frame() -> void:
	gc_scope(SCOPE_PASS)
	gc_scope(SCOPE_FRAME)


## 执行 gc_frame，但临时把 preserved_rids 中的 frame/pass 作用域 RID 移入私有保留作用域，
## 使其不被本帧回收，帧结束后再恢复原作用域。供需要跨帧持有中间 GPU 缓冲的 pass 调用。
## 原 SceneVoxelCommitter / SceneVoxelTileStore 各自复制了一份，现上移到计算基类共享。
func _gc_frame_preserving_rids(preserved_rids: Array) -> void:
	if preserved_rids.is_empty():
		gc_frame()
		return

	var preserved_entries: Array[Dictionary] = []
	var preserve_scope := "_scene_voxel_summary_prebound_preserve"
	for entry in _resources:
		if not bool(entry.get("alive", false)):
			continue
		var rid: RID = entry.get("rid", RID())
		if not rid.is_valid() or not preserved_rids.has(rid):
			continue
		var scope := str(entry.get("scope", ""))
		if scope != SCOPE_FRAME and scope != SCOPE_PASS:
			continue
		preserved_entries.append({
			"entry": entry,
			"scope": scope,
		})
		entry["scope"] = preserve_scope

	gc_frame()

	for preserved in preserved_entries:
		var entry: Dictionary = preserved.get("entry", {})
		if not bool(entry.get("alive", false)):
			continue
		if str(entry.get("scope", "")) == preserve_scope:
			entry["scope"] = str(preserved.get("scope", SCOPE_FRAME))


func gc_all(defer_if_busy: bool = true) -> void:
	if _compute_list_active and defer_if_busy:
		for entry in _resources:
			if bool(entry.get("alive", false)):
				_queue_gc_scope(str(entry.get("scope", "")))
		return
	_collect_entries(func(_entry: Dictionary) -> bool:
		return true
	)


func flush_deferred_gc() -> void:
	if _compute_list_active:
		return
	var scopes: Array[String] = _deferred_gc_scopes.duplicate()
	_deferred_gc_scopes.clear()
	for scope in scopes:
		gc_scope(scope, false)


func begin_compute_list() -> int:
	if _rd == null:
		push_error("%s.begin_compute_list(): RenderingDevice 为 null —— 无法开启 compute list。" % log_name)
		assert(false, "GodotComputeShaderBase.begin_compute_list: no RenderingDevice")
		return -1
	_compute_list_active = true
	return _rd.compute_list_begin()


func end_compute_list() -> void:
	if _rd == null:
		push_error("%s.end_compute_list(): RenderingDevice 为 null —— compute list 无法正常结束，已录入的 dispatch 全部丢失。" % log_name)
		assert(false, "GodotComputeShaderBase.end_compute_list: no RenderingDevice")
		_compute_list_active = false
		return
	_rd.compute_list_end()
	_compute_list_active = false
	flush_deferred_gc()


func _gpu_dispatch_and_sync(pipeline: RID, uniform_sets: Array, push: PackedByteArray, groups: Vector3i) -> bool:
	var cl := begin_compute_list()
	if cl < 0:
		return false
	_gpu_dispatch_pipeline_sets(cl, pipeline, uniform_sets, push, groups)
	end_compute_list()
	submit_and_sync()
	return true


func _gpu_dispatch_pipeline_sets(cl: int, pipeline: RID, uniform_sets: Array, push: PackedByteArray, groups: Vector3i) -> void:
	if not _dispatch_preconditions_valid("_gpu_dispatch_pipeline_sets", cl, pipeline, uniform_sets):
		return
	# groups 全 0 是稀疏调度的正常空批次，不报错；负值只可能来自计算错误。
	if groups.x < 0 or groups.y < 0 or groups.z < 0:
		push_error("%s._gpu_dispatch_pipeline_sets(): dispatch 组数为负 groups=(%d, %d, %d) —— 不 clamp、不发起 dispatch。" % [
			log_name, groups.x, groups.y, groups.z])
		assert(false, "GodotComputeShaderBase._gpu_dispatch_pipeline_sets: negative dispatch groups")
		return
	_rd.compute_list_bind_compute_pipeline(cl, pipeline)
	for set_index in range(uniform_sets.size()):
		_rd.compute_list_bind_uniform_set(cl, uniform_sets[set_index], set_index)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, groups.x, groups.y, groups.z)


## dispatch 前的硬性前置校验（device / compute list / pipeline / 每个 uniform set 的 RID）。
## 任一不满足即 push_error + assert 并返回 false —— 绝不静默跳过绑定或用占位 RID 顶替，
## 否则错误的 buffer 会悄悄进 dispatch，脏数据要到很后面才暴露。
func _dispatch_preconditions_valid(context: String, cl: int, pipeline: RID, uniform_sets: Array) -> bool:
	if _rd == null:
		push_error("%s.%s(): RenderingDevice 为 null —— 无法 dispatch。" % [log_name, context])
		assert(false, "GodotComputeShaderBase: dispatch without RenderingDevice")
		return false
	if cl < 0:
		push_error("%s.%s(): compute list 句柄非法 (cl=%d) —— 无法 dispatch。" % [log_name, context, cl])
		assert(false, "GodotComputeShaderBase: dispatch with invalid compute list")
		return false
	if not pipeline.is_valid():
		push_error("%s.%s(): compute pipeline RID 无效 —— shader/pipeline 创建失败后不得继续 dispatch。" % [log_name, context])
		assert(false, "GodotComputeShaderBase: dispatch with invalid pipeline RID")
		return false
	for set_index in range(uniform_sets.size()):
		var uniform_set: RID = uniform_sets[set_index]
		if not uniform_set.is_valid():
			push_error("%s.%s(): uniform set RID 无效 (set=%d, 共 %d 个) —— 不绑定占位 RID，终止 dispatch。" % [
				log_name, context, set_index, uniform_sets.size()])
			assert(false, "GodotComputeShaderBase: dispatch with invalid uniform set RID")
			return false
	return true


## _gpu_dispatch_pipeline_sets 的 indirect 变体:组数由 indirect_args 缓冲(GPU 写入)决定。
## 多段链中的 barrier 仍由调用方显式插入(compute_list_add_barrier)。
func _gpu_dispatch_pipeline_sets_indirect(cl: int, pipeline: RID, uniform_sets: Array, push: PackedByteArray, indirect_args: RID, args_offset: int = 0) -> void:
	if not _dispatch_preconditions_valid("_gpu_dispatch_pipeline_sets_indirect", cl, pipeline, uniform_sets):
		return
	if not indirect_args.is_valid():
		push_error("%s._gpu_dispatch_pipeline_sets_indirect(): indirect args buffer RID 无效 —— 终止 dispatch。" % log_name)
		assert(false, "GodotComputeShaderBase._gpu_dispatch_pipeline_sets_indirect: invalid indirect args RID")
		return
	_rd.compute_list_bind_compute_pipeline(cl, pipeline)
	for set_index in range(uniform_sets.size()):
		_rd.compute_list_bind_uniform_set(cl, uniform_sets[set_index], set_index)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch_indirect(cl, indirect_args, args_offset)


func load_compute_shader(path: String, scope: String = SCOPE_PERSISTENT, label: String = "") -> RID:
	if _rd == null:
		push_error("%s.load_compute_shader(): 在 ensure_device 之前调用，shader='%s' —— 无法编译。" % [log_name, path])
		assert(false, "GodotComputeShaderBase.load_compute_shader: no RenderingDevice")
		return RID()

	var spirv: RDShaderSPIRV = _compile_spirv_cached(path)
	if spirv == null:
		var shader_file: RDShaderFile = load(path) as RDShaderFile
		if shader_file != null:
			spirv = shader_file.get_spirv()

	if spirv == null:
		push_error("%s.load_compute_shader(): shader '%s' 无法取得 SPIR-V（源文本不可读且 RDShaderFile 导入失败）—— 不返回占位 shader。" % [
			log_name, path])
		assert(false, "GodotComputeShaderBase.load_compute_shader: no SPIR-V")
		return RID()

	var err_msg: String = spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not err_msg.is_empty():
		push_error("%s.load_compute_shader(): shader '%s' GLSL 编译失败 —— 无法继续 dispatch：%s" % [log_name, path, err_msg])
		assert(false, "GodotComputeShaderBase.load_compute_shader: GLSL compile error")
		return RID()

	var module_start := Time.get_ticks_usec()
	var shader: RID = _rd.shader_create_from_spirv(spirv)
	_record_compile_usec(path, "module", Time.get_ticks_usec() - module_start)
	if not shader.is_valid():
		push_error("%s.load_compute_shader(): shader '%s' 的 shader_create_from_spirv 返回无效 RID —— 无法继续 dispatch。" % [
			log_name, path])
		assert(false, "GodotComputeShaderBase.load_compute_shader: invalid shader RID")
		return RID()

	var resolved_label: String = label if not label.is_empty() else path.get_file()
	_repair_kernel_members()
	_shader_stat_paths[shader.get_id()] = path
	return track_rid(shader, KIND_SHADER, scope, resolved_label)


func create_compute_pipeline(shader: RID, scope: String = SCOPE_PERSISTENT, label: String = "") -> RID:
	if _rd == null:
		push_error("%s.create_compute_pipeline(): RenderingDevice 为 null（label='%s'）。" % [log_name, label])
		assert(false, "GodotComputeShaderBase.create_compute_pipeline: no RenderingDevice")
		return RID()
	if not shader.is_valid():
		push_error("%s.create_compute_pipeline(): shader RID 无效（label='%s'）—— shader 编译失败后不得创建 pipeline。" % [
			log_name, label])
		assert(false, "GodotComputeShaderBase.create_compute_pipeline: invalid shader RID")
		return RID()
	_repair_kernel_members()
	var pipeline_start := Time.get_ticks_usec()
	var pipeline: RID = _rd.compute_pipeline_create(shader)
	_record_compile_usec(
		str(_shader_stat_paths.get(shader.get_id(), label if not label.is_empty() else "<unknown>")),
		"pipeline",
		Time.get_ticks_usec() - pipeline_start
	)
	if not pipeline.is_valid():
		push_error("%s.create_compute_pipeline(): compute_pipeline_create 返回无效 RID（label='%s'）。" % [log_name, label])
		assert(false, "GodotComputeShaderBase.create_compute_pipeline: invalid pipeline RID")
		return RID()
	return track_rid(pipeline, KIND_PIPELINE, scope, label)


## 取得 path 对应的常驻 shader + pipeline，首次调用编译、之后直接命中；返回
## {"shader": RID, "pipeline": RID}，任一无效表示编译失败（调用方沿用各自既有的报错/reason 路径）。
##
## 用于取代“每次 dispatch 都 load_compute_shader(..., SCOPE_FRAME) + create_compute_pipeline
## 再随 gc_frame 释放”的写法。基类的 SPIR-V 缓存只去重 glslang 前端；shader_create_from_spirv
## （反射 + zstd 压缩/解压 + shader module）与 compute_pipeline_create（驱动 SPIR-V→ISA）
## 在每次调用里都是全额重做，而 local RenderingDevice 拿不到驱动的 VkPipelineCache，
## 这两段没有任何底层缓存兜底，只能靠本注册表在宿主生命周期内前移一次。
##
## RID 按 SCOPE_PERSISTENT 登记进宿主自己的追踪器，所有权与 GC 审计语义不变（dispose/gc_all
## 照常回收）；注册表只是命中索引。源文件 mtime 变化时释放旧 RID 并重建，保留改 .glsl
## 后无需重启即时生效的调试行为——原 SCOPE_FRAME 写法靠“每次重编译”白拿到这一点。
func ensure_shader_kernel(path: String, label: String = "") -> Dictionary:
	_repair_kernel_members()
	var mtime: int = shader_source_mtime(path)
	var cached: Dictionary = _kernel_registry.get(path, {})
	if not cached.is_empty():
		var cached_shader: RID = cached.get("shader", RID())
		var cached_pipeline: RID = cached.get("pipeline", RID())
		var fresh: bool = mtime == 0 or int(cached.get("mtime", -1)) == mtime
		if cached_shader.is_valid() and cached_pipeline.is_valid() and fresh:
			return cached
		# 源文件已改动（或常驻 RID 意外失效）：先退掉旧的常驻 RID 再重建，避免注册表
		# 换新后旧 shader/pipeline 变成无人引用、只能等 dispose 才回收的悬挂常驻资源。
		if cached_pipeline.is_valid():
			release_rid(cached_pipeline)
		if cached_shader.is_valid():
			release_rid(cached_shader)
		_kernel_registry.erase(path)

	var resolved_label: String = label if not label.is_empty() else path.get_file()
	var shader: RID = load_compute_shader(path, SCOPE_PERSISTENT, resolved_label)
	if not shader.is_valid():
		return {"shader": RID(), "pipeline": RID()}
	var pipeline: RID = create_compute_pipeline(shader, SCOPE_PERSISTENT, resolved_label)
	if not pipeline.is_valid():
		release_rid(shader)
		return {"shader": RID(), "pipeline": RID()}

	var entry: Dictionary = {"shader": shader, "pipeline": pipeline, "mtime": mtime}
	_kernel_registry[path] = entry
	return entry


## shader 源文件的修改时间；0 表示两种路径形式都取不到（打包运行等），调用方按“无法失效”处理。
func shader_source_mtime(path: String) -> int:
	var mtime: int = FileAccess.get_modified_time(ProjectSettings.globalize_path(path))
	if mtime == 0:
		mtime = FileAccess.get_modified_time(path)
	return mtime


## @tool 软重载后新增成员回来是 nil（见 gpu_autoobject_runtime.reset_state 的同类守卫）：
## 归零成空字典，注册表随之失效、下次调用照常重新编译，不会朝设备 free 假句柄。
func _repair_kernel_members() -> void:
	if not (_kernel_registry is Dictionary): _kernel_registry = {}
	if not (_shader_stat_paths is Dictionary): _shader_stat_paths = {}


## 文本源路径的 GLSL→SPIR-V 编译，带进程级 path→SPIR-V 缓存（mtime 失效）。
## 返回 null 表示源文本不可读（调用方回退到 RDShaderFile 路径）；编译失败时返回带
## stage error 的 SPIR-V，由调用方沿用原有报错路径，失败结果不写入缓存。
func _compile_spirv_cached(path: String) -> RDShaderSPIRV:
	var mtime: int = shader_source_mtime(path)

	if mtime != 0:
		var cached: Dictionary = _spirv_source_cache.get(path, {})
		if int(cached.get("mtime", -1)) == mtime:
			return cached.get("spirv")

	var source_text: String = read_compute_shader_source(path)
	if source_text.is_empty():
		return null

	var source: RDShaderSource = RDShaderSource.new()
	source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, source_text)
	var spirv_start := Time.get_ticks_usec()
	var spirv: RDShaderSPIRV = _rd.shader_compile_spirv_from_source(source)
	_record_compile_usec(path, "spirv", Time.get_ticks_usec() - spirv_start)
	if spirv == null:
		return null
	if mtime != 0 and spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE).is_empty():
		_spirv_source_cache[path] = {"spirv": spirv, "mtime": mtime}
	return spirv


func read_compute_shader_source(path: String) -> String:
	var absolute_path: String = ProjectSettings.globalize_path(path)
	var source_text: String = FileAccess.get_file_as_string(absolute_path)
	if source_text.is_empty():
		source_text = FileAccess.get_file_as_string(path)
	if source_text.is_empty():
		return ""

	var lines: PackedStringArray = source_text.split("\n")
	var filtered: Array[String] = []
	for line in lines:
		if line.strip_edges() == "#[compute]":
			continue
		filtered.append(line)
	return "\n".join(filtered)


func create_uniform_set(
	uniforms: Array,
	shader: RID,
	set_index: int,
	scope: String = SCOPE_PASS,
	label: String = ""
) -> RID:
	if _rd == null:
		push_error("%s.create_uniform_set(): RenderingDevice 为 null（set=%d, label='%s'）。" % [log_name, set_index, label])
		assert(false, "GodotComputeShaderBase.create_uniform_set: no RenderingDevice")
		return RID()
	if not shader.is_valid():
		push_error("%s.create_uniform_set(): shader RID 无效（set=%d, label='%s'）—— 不创建 uniform set。" % [
			log_name, set_index, label])
		assert(false, "GodotComputeShaderBase.create_uniform_set: invalid shader RID")
		return RID()
	var uniform_set: RID = _rd.uniform_set_create(uniforms, shader, set_index)
	if not uniform_set.is_valid():
		push_error("%s.create_uniform_set(): uniform_set_create 失败（set=%d, label='%s', uniform 数=%d）—— 绑定的 buffer/texture RID 或 binding 序号与 shader 布局不符。" % [
			log_name, set_index, label, uniforms.size()])
		assert(false, "GodotComputeShaderBase.create_uniform_set: invalid uniform set RID")
		return RID()
	return track_rid(uniform_set, KIND_UNIFORM_SET, scope, label)


func make_storage_uniform(binding: int, buffer: RID) -> RDUniform:
	var uniform: RDUniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform


func make_image_uniform(binding: int, texture: RID) -> RDUniform:
	var uniform: RDUniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = binding
	uniform.add_id(texture)
	return uniform


func make_sampler_uniform(binding: int, sampler: RID, texture: RID) -> RDUniform:
	var uniform: RDUniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = binding
	uniform.add_id(sampler)
	uniform.add_id(texture)
	return uniform


func storage_buffer_from_bytes(bytes: PackedByteArray, scope: String = SCOPE_FRAME, label: String = "") -> RID:
	if _rd == null:
		push_error("%s.storage_buffer_from_bytes(): RenderingDevice 为 null（label='%s', %d 字节）。" % [
			log_name, label, bytes.size()])
		assert(false, "GodotComputeShaderBase.storage_buffer_from_bytes: no RenderingDevice")
		return RID()
	var safe: PackedByteArray = bytes
	# RenderingDevice 不接受 0 字节缓冲，空载荷补到 4 字节占位（容量仍由调用方的 count 传给 shader）。
	if safe.size() <= 0:
		safe = PackedByteArray()
		safe.resize(4)
	var buffer: RID = _rd.storage_buffer_create(safe.size(), safe)
	if not buffer.is_valid():
		push_error("%s.storage_buffer_from_bytes(): storage_buffer_create 失败（label='%s', %d 字节）。" % [
			log_name, label, safe.size()])
		assert(false, "GodotComputeShaderBase.storage_buffer_from_bytes: invalid buffer RID")
		return RID()
	return track_rid(buffer, KIND_BUFFER, scope, label)


func storage_buffer_from_floats(values: PackedFloat32Array, scope: String = SCOPE_FRAME, label: String = "") -> RID:
	return storage_buffer_from_bytes(values.to_byte_array(), scope, label)


func storage_buffer_zero(byte_count: int, scope: String = SCOPE_FRAME, label: String = "") -> RID:
	if byte_count < 0:
		push_error("%s.storage_buffer_zero(): 请求的字节数为负 (%d, label='%s') —— 不 clamp，拒绝创建。" % [
			log_name, byte_count, label])
		assert(false, "GodotComputeShaderBase.storage_buffer_zero: negative byte_count")
		return RID()
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(maxi(byte_count, 4))
	return storage_buffer_from_bytes(bytes, scope, label)


## 创建不带 CPU 初始化载荷的 storage buffer。仅用于后续 GPU pass 会在任何读取前
## 完整覆盖的工作缓冲；计数器、原子目标和部分写入缓冲仍应使用 storage_buffer_zero()。
func storage_buffer_uninitialized(byte_count: int, scope: String = SCOPE_FRAME, label: String = "") -> RID:
	if _rd == null:
		push_error("%s.storage_buffer_uninitialized(): RenderingDevice 为 null（label='%s'）。" % [log_name, label])
		assert(false, "GodotComputeShaderBase.storage_buffer_uninitialized: no RenderingDevice")
		return RID()
	if byte_count < 0:
		push_error("%s.storage_buffer_uninitialized(): 请求的字节数为负 (%d, label='%s') —— 不 clamp，拒绝创建。" % [
			log_name, byte_count, label])
		assert(false, "GodotComputeShaderBase.storage_buffer_uninitialized: negative byte_count")
		return RID()
	var safe_byte_count := maxi(byte_count, 4)
	var buffer: RID = _rd.storage_buffer_create(safe_byte_count)
	if not buffer.is_valid():
		push_error("%s.storage_buffer_uninitialized(): storage_buffer_create 失败（label='%s', %d 字节）。" % [
			log_name, label, safe_byte_count])
		assert(false, "GodotComputeShaderBase.storage_buffer_uninitialized: invalid buffer RID")
		return RID()
	return track_rid(buffer, KIND_BUFFER, scope, label)


func buffer_zero(rid: RID, byte_count: int) -> bool:
	if _rd == null:
		push_error("%s.buffer_zero(): RenderingDevice 为 null。" % log_name)
		assert(false, "GodotComputeShaderBase.buffer_zero: no RenderingDevice")
		return false
	if not rid.is_valid():
		push_error("%s.buffer_zero(): 目标 buffer RID 无效（byte_count=%d）—— 不静默跳过清零。" % [log_name, byte_count])
		assert(false, "GodotComputeShaderBase.buffer_zero: invalid buffer RID")
		return false
	if byte_count < 0:
		push_error("%s.buffer_zero(): 字节数为负 (%d)。" % [log_name, byte_count])
		assert(false, "GodotComputeShaderBase.buffer_zero: negative byte_count")
		return false
	if byte_count == 0:
		return true
	if _compute_list_active:
		push_error("%s.buffer_zero(): compute list 处于活动状态时不能执行 buffer_update（byte_count=%d）。" % [log_name, byte_count])
		assert(false, "GodotComputeShaderBase.buffer_zero: compute list is active")
		return false

	var remaining := byte_count
	var offset := 0
	while remaining > 0:
		var chunk_size := mini(remaining, _BUFFER_ZERO_UPDATE_CHUNK_BYTES)
		var err := _rd.buffer_update(rid, offset, chunk_size, _buffer_zero_bytes(chunk_size))
		if err != OK:
			push_error("%s.buffer_zero(): buffer_update 失败 err=%d（offset=%d, chunk=%d, 总计=%d）—— 缓冲内容已处于半清零的脏状态。" % [
				log_name, err, offset, chunk_size, byte_count])
			assert(false, "GodotComputeShaderBase.buffer_zero: buffer_update failed")
			return false
		offset += chunk_size
		remaining -= chunk_size
	return true


func _buffer_zero_bytes(byte_count: int) -> PackedByteArray:
	if _buffer_zero_scratch.size() != byte_count:
		_buffer_zero_scratch.resize(byte_count)
	return _buffer_zero_scratch


func dispatch_indirect_args_buffer_zero(scope: String = SCOPE_FRAME, label: String = "dispatch_indirect_args") -> RID:
	if _rd == null:
		push_error("%s.dispatch_indirect_args_buffer_zero(): RenderingDevice 为 null（label='%s'）。" % [log_name, label])
		assert(false, "GodotComputeShaderBase.dispatch_indirect_args_buffer_zero: no RenderingDevice")
		return RID()
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(12)
	var buffer: RID = _rd.storage_buffer_create(
		bytes.size(),
		bytes,
		RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT
	)
	if not buffer.is_valid():
		push_error("%s.dispatch_indirect_args_buffer_zero(): indirect args buffer 创建失败（label='%s'）。" % [log_name, label])
		assert(false, "GodotComputeShaderBase.dispatch_indirect_args_buffer_zero: invalid buffer RID")
		return RID()
	return track_rid(buffer, KIND_BUFFER, scope, label)


func create_linear_sampler(scope: String = SCOPE_PERSISTENT, label: String = "linear_sampler") -> RID:
	if _rd == null:
		push_error("%s.create_linear_sampler(): RenderingDevice 为 null（label='%s'）。" % [log_name, label])
		assert(false, "GodotComputeShaderBase.create_linear_sampler: no RenderingDevice")
		return RID()
	var state: RDSamplerState = RDSamplerState.new()
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	return track_rid(_rd.sampler_create(state), KIND_SAMPLER, scope, label)


func upload_texture_2d(
	image: Image,
	format: int = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
	image_format: int = Image.FORMAT_RGBAH,
	usage_bits: int = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
	scope: String = SCOPE_FRAME,
	label: String = ""
) -> RID:
	if _rd == null:
		push_error("%s.upload_texture_2d(): RenderingDevice 为 null（label='%s'）。" % [log_name, label])
		assert(false, "GodotComputeShaderBase.upload_texture_2d: no RenderingDevice")
		return RID()
	if image == null:
		push_error("%s.upload_texture_2d(): 传入的 Image 为 null（label='%s'）—— 不返回占位纹理。" % [log_name, label])
		assert(false, "GodotComputeShaderBase.upload_texture_2d: null image")
		return RID()

	var img: Image = image
	if img.get_format() != image_format:
		img = img.duplicate()
		img.convert(image_format)

	var texture_format: RDTextureFormat = _texture_format_2d(img.get_width(), img.get_height(), format, usage_bits)
	var texture: RID = _rd.texture_create(texture_format, RDTextureView.new(), [img.get_data()])
	return track_rid(texture, KIND_TEXTURE, scope, label)


func create_rw_texture_2d(
	width: int,
	height: int,
	format: int = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
	usage_bits: int = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	),
	scope: String = SCOPE_FRAME,
	label: String = ""
) -> RID:
	if _rd == null:
		push_error("%s.create_rw_texture_2d(): RenderingDevice 为 null（label='%s'）。" % [log_name, label])
		assert(false, "GodotComputeShaderBase.create_rw_texture_2d: no RenderingDevice")
		return RID()
	var texture_format: RDTextureFormat = _texture_format_2d(width, height, format, usage_bits)
	var texture: RID = _rd.texture_create(texture_format, RDTextureView.new())
	return track_rid(texture, KIND_TEXTURE, scope, label)


func upload_texture_3d(
	width: int,
	height: int,
	depth: int,
	bytes: PackedByteArray,
	format: int = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
	usage_bits: int = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
	scope: String = SCOPE_FRAME,
	label: String = ""
) -> RID:
	if _rd == null:
		push_error("%s.upload_texture_3d(): RenderingDevice 为 null（label='%s'）。" % [log_name, label])
		assert(false, "GodotComputeShaderBase.upload_texture_3d: no RenderingDevice")
		return RID()
	if width <= 0 or height <= 0 or depth <= 0 or bytes.is_empty():
		push_error("%s.upload_texture_3d(): 尺寸/载荷非法 (%d×%d×%d, %d 字节, label='%s') —— 不返回占位纹理。" % [
			log_name, width, height, depth, bytes.size(), label])
		assert(false, "GodotComputeShaderBase.upload_texture_3d: invalid dimensions or empty payload")
		return RID()
	var texture_format: RDTextureFormat = _texture_format_3d(width, height, depth, format, usage_bits)
	var texture: RID = _rd.texture_create(texture_format, RDTextureView.new(), [bytes])
	return track_rid(texture, KIND_TEXTURE, scope, label)


func upload_texture_3d_from_images(
	images: Array,
	format: int = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
	image_format: int = Image.FORMAT_RGBAH,
	usage_bits: int = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
	scope: String = SCOPE_FRAME,
	label: String = ""
) -> RID:
	if _rd == null:
		push_error("%s.upload_texture_3d_from_images(): RenderingDevice 为 null（label='%s'）。" % [log_name, label])
		assert(false, "GodotComputeShaderBase.upload_texture_3d_from_images: no RenderingDevice")
		return RID()
	if images.is_empty():
		push_error("%s.upload_texture_3d_from_images(): 切片数组为空（label='%s'）。" % [log_name, label])
		assert(false, "GodotComputeShaderBase.upload_texture_3d_from_images: empty image array")
		return RID()
	var first: Image = images[0] as Image
	if first == null:
		push_error("%s.upload_texture_3d_from_images(): 第 0 层切片不是 Image（label='%s'）。" % [log_name, label])
		assert(false, "GodotComputeShaderBase.upload_texture_3d_from_images: slice 0 is not an Image")
		return RID()
	var width: int = first.get_width()
	var height: int = first.get_height()
	var depth: int = images.size()
	var bytes: PackedByteArray = PackedByteArray()
	for raw_image in images:
		var img: Image = raw_image as Image
		if img == null:
			push_error("%s.upload_texture_3d_from_images(): 切片数组中存在非 Image 元素（label='%s'）。" % [log_name, label])
			assert(false, "GodotComputeShaderBase.upload_texture_3d_from_images: non-Image slice")
			return RID()
		if img.get_width() != width or img.get_height() != height:
			push_error("%s.upload_texture_3d_from_images(): 切片尺寸不一致（期望 %d×%d，实得 %d×%d, label='%s'）。" % [
				log_name, width, height, img.get_width(), img.get_height(), label])
			assert(false, "GodotComputeShaderBase.upload_texture_3d_from_images: slice dimension mismatch")
			return RID()
		if img.get_format() != image_format:
			img = img.duplicate()
			img.convert(image_format)
		bytes.append_array(img.get_data())
	return upload_texture_3d(width, height, depth, bytes, format, usage_bits, scope, label)


func create_rw_texture_3d(
	width: int,
	height: int,
	depth: int,
	format: int = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
	usage_bits: int = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	),
	scope: String = SCOPE_FRAME,
	label: String = ""
) -> RID:
	if _rd == null:
		push_error("%s.create_rw_texture_3d(): RenderingDevice 为 null（label='%s'）。" % [log_name, label])
		assert(false, "GodotComputeShaderBase.create_rw_texture_3d: no RenderingDevice")
		return RID()
	if width <= 0 or height <= 0 or depth <= 0:
		push_error("%s.create_rw_texture_3d(): 尺寸非法 (%d×%d×%d, label='%s')。" % [
			log_name, width, height, depth, label])
		assert(false, "GodotComputeShaderBase.create_rw_texture_3d: invalid dimensions")
		return RID()
	var texture_format: RDTextureFormat = _texture_format_3d(width, height, depth, format, usage_bits)
	var texture: RID = _rd.texture_create(texture_format, RDTextureView.new())
	return track_rid(texture, KIND_TEXTURE, scope, label)


## 通过 buffer_get_data 从 GPU 缓冲区回读字节；无 device / RID 无效 / 字节数<=0 时返回空数组。
## 供各子类的调试/测试回读路径共用（生产路径用常驻 GPU→GPU 交接，不回读）。原多处 _read_buffer_bytes/_readback_buffer_bytes。
func read_buffer_bytes(buffer: RID, offset: int = 0, byte_count: int = -1) -> PackedByteArray:
	if _rd == null:
		push_error("%s.read_buffer_bytes(): RenderingDevice 为 null（offset=%d, byte_count=%d）。" % [
			log_name, offset, byte_count])
		assert(false, "GodotComputeShaderBase.read_buffer_bytes: no RenderingDevice")
		return PackedByteArray()
	if not buffer.is_valid():
		push_error("%s.read_buffer_bytes(): 源 buffer RID 无效（offset=%d, byte_count=%d）—— 不返回空数组顶替回读结果。" % [
			log_name, offset, byte_count])
		assert(false, "GodotComputeShaderBase.read_buffer_bytes: invalid buffer RID")
		return PackedByteArray()
	if byte_count < 0:
		push_error("%s.read_buffer_bytes(): 回读字节数为负 (%d, offset=%d)。" % [log_name, byte_count, offset])
		assert(false, "GodotComputeShaderBase.read_buffer_bytes: negative byte_count")
		return PackedByteArray()
	if byte_count == 0:
		return PackedByteArray()
	return _rd.buffer_get_data(buffer, offset, byte_count)


func ceil_div(value: int, divisor: int) -> int:
	if divisor <= 0:
		push_error("%s.ceil_div(): 除数非法 (value=%d, divisor=%d) —— 返回 0 组会让 dispatch 静默空跑。" % [
			log_name, value, divisor])
		assert(false, "GodotComputeShaderBase.ceil_div: non-positive divisor")
		return 0
	return int((value + divisor - 1) / divisor)


func dispatch_groups_1d(element_count: int, local_size_x: int) -> Vector3i:
	return Vector3i(ceil_div(element_count, local_size_x), 1, 1)


func dispatch_groups_2d(width: int, height: int, local_size_x: int, local_size_y: int) -> Vector3i:
	return Vector3i(ceil_div(width, local_size_x), ceil_div(height, local_size_y), 1)


func dispatch_groups_3d(width: int, height: int, depth: int, local_size_x: int, local_size_y: int, local_size_z: int) -> Vector3i:
	return Vector3i(ceil_div(width, local_size_x), ceil_div(height, local_size_y), ceil_div(depth, local_size_z))


## 缓存的 uniform set 是否仍然可用。只查 RID 非空是不够的：RD 在释放被绑定的缓冲时会连带
## 释放依赖它的 uniform set，而调用方手里的 RID 仍非空。
func uniform_set_alive(uniform_set: RID) -> bool:
	return _rd != null and uniform_set.is_valid() and _rd.uniform_set_is_valid(uniform_set)


func _texture_format_2d(width: int, height: int, format: int, usage_bits: int) -> RDTextureFormat:
	var texture_format: RDTextureFormat = RDTextureFormat.new()
	texture_format.width = width
	texture_format.height = height
	texture_format.depth = 1
	texture_format.array_layers = 1
	texture_format.mipmaps = 1
	texture_format.format = format
	texture_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	texture_format.usage_bits = usage_bits
	return texture_format


func _texture_format_3d(width: int, height: int, depth: int, format: int, usage_bits: int) -> RDTextureFormat:
	var texture_format: RDTextureFormat = RDTextureFormat.new()
	texture_format.width = width
	texture_format.height = height
	texture_format.depth = depth
	texture_format.array_layers = 1
	texture_format.mipmaps = 1
	texture_format.format = format
	texture_format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	texture_format.usage_bits = usage_bits
	return texture_format


func _collect_entries(predicate: Callable) -> void:
	var to_free: Array[Dictionary] = []
	for entry in _resources:
		if bool(entry.get("alive", false)) and bool(predicate.call(entry)):
			to_free.append(entry)

	to_free.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ao: int = int(_kind_orders.get(str(a.get("kind", KIND_OTHER)), 100))
		var bo: int = int(_kind_orders.get(str(b.get("kind", KIND_OTHER)), 100))
		if ao == bo:
			return int(a.get("id", 0)) > int(b.get("id", 0))
		return ao < bo
	)

	for entry in to_free:
		_free_entry(entry)
	_compact_dead_resources()


func _free_entry(entry: Dictionary) -> void:
	if not bool(entry.get("alive", false)):
		return

	var rid: RID = entry.get("rid", RID())
	entry["alive"] = false
	if _rd == null or not rid.is_valid():
		return
	if not _should_free_resource(entry):
		return
	_forget_kernel_rid(rid, str(entry.get("kind", KIND_OTHER)))

	_on_before_free_resource(entry)

	var disposer: Callable = entry.get("disposer", Callable())
	if disposer.is_valid():
		disposer.call(_rd, rid, entry)
	else:
		_rd.free_rid(rid)

	_on_after_free_resource(entry)


## 释放 shader/pipeline RID 时同步剔除注册表条目。RID.is_valid() 只看 id 非零，freed 之后
## 依然为 true，所以注册表不能靠 is_valid() 自愈：任何绕开 ensure_shader_kernel 的回收路径
## （gc_all()、显式 gc_scope(SCOPE_PERSISTENT)、release_rid()）都必须在这里把条目摘掉，
## 否则下次命中会把已释放的句柄交给 dispatch。
func _forget_kernel_rid(rid: RID, kind: String) -> void:
	if kind != KIND_SHADER and kind != KIND_PIPELINE:
		return
	_repair_kernel_members()
	if kind == KIND_SHADER:
		_shader_stat_paths.erase(rid.get_id())
	for path in _kernel_registry.keys():
		var entry: Dictionary = _kernel_registry[path]
		if entry.get("shader", RID()) == rid or entry.get("pipeline", RID()) == rid:
			_kernel_registry.erase(path)


func _queue_gc_scope(scope: String) -> void:
	if scope.is_empty() or _deferred_gc_scopes.has(scope):
		return
	_deferred_gc_scopes.append(scope)


func _compact_dead_resources() -> void:
	var alive: Array[Dictionary] = []
	for entry in _resources:
		if bool(entry.get("alive", false)):
			alive.append(entry)
	_resources = alive


func _on_device_ready() -> void:
	pass


func _on_before_dispose() -> void:
	pass


func _on_after_dispose() -> void:
	pass


func _should_free_resource(_entry: Dictionary) -> bool:
	return bool(_entry.get("owned", OWNED))


func _on_before_free_resource(_entry: Dictionary) -> void:
	pass


func _on_after_free_resource(_entry: Dictionary) -> void:
	pass
