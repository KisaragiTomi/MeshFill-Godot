class_name VoxelMultiMeshWriterGPU
extends RefCounted

# Shared GPU MultiMesh-writer lifecycle for the voxel display writers
# (VoxelFieldDisplayGPU / BrushVoxelDisplayGPU / VoxelInstanceDisplayGPU).
#
# All three upload their source data as storage buffers and dispatch a compute
# pass that writes instance transforms + colors DIRECTLY into a MultiMesh buffer
# on the MAIN RenderingDevice, with zero GPU->CPU readback. The device / shader /
# pipeline / scratch lifecycle, the MultiMesh binding, the buffer helpers, and
# the render-thread-safe free path were byte-for-byte identical across the three
# and live here. Subclasses supply only their shader path and their per-write
# dispatch (_shader_path + write_* + _render_thread_write + _pack_push).

const LOCAL_SIZE := 64

## 一个 MultiMesh 实例在 GPU 缓冲里占多少个 float。三条 writer 通路**共用**这一个值，
## 且必须与三个着色器里的字面量逐字一致：
##   shaders/voxel_field_instances.glsl:61   `const int FLOATS_PER_INSTANCE = 16;`
##   shaders/brush_voxel_instances.glsl:49   同名同值
##   shaders/voxel_instance_copy.glsl:25-27  TRANSFORM_FLOATS 12 + COLOR_FLOATS 4
## 布局：f[0..11] = 变换（三行，每行 3 个 basis 分量 + 1 个 origin 分量），f[12..15] = RGBA。
##
## 值 16 不是随便定的，它由引擎按 MultiMesh 的两个开关算出
## （servers/rendering/renderer_rd/storage_rd/mesh_storage.cpp:1573-1576）：
##   color_offset  = 12（TRANSFORM_3D；2D 是 8）
##   custom_offset = color_offset + (use_colors ? 4 : 0)
##   stride        = custom_offset + (use_custom_data ? 4 : 0)
## 本通路恒为 use_colors = true、use_custom_data = false ⇒ 12 + 4 + 0 = 16。
##
## ⚠ 别把它改成 20。20 是 AutoObject 那条通路的 stride（PlacedInstanceDisplay 开了
## use_custom_data，CUSTOM 落 [16..19] 装 object_id/profile_id/asset_index/flags），它走的是
## `multimesh.set_buffer()` 整块搬运，**不经过本类**。两条通路的 stride 本来就不同，
## 把 20 写进这里而不同步改三个 .glsl，结果是「compute 按 16 步进写、引擎按 20 步进读」的
## 整体错位——而且是纯静默的：compute 直写 multimesh_get_buffer_rd_rid，引擎侧无任何尺寸校验
## （set_buffer 那条反而有 ERR_FAIL_COND 会拦）。
##
## ⚠ 也别为了「给 pick_id 腾 CUSTOM_DATA 槽位」而改。pick_id 的载体已定案为
## `INSTANCE_ID + 逐 drawable 基址 uniform`（shaders/pick_id.gdshader:27/:43），全仓 .gdshader
## 对 INSTANCE_CUSTOM 的引用数为 0 —— 该方案对 MultiMesh 布局的改动面就是零。
const MULTIMESH_INSTANCE_FLOATS := 16

## 主设备上的 shader/pipeline 缓存：path → {"shader": RID, "pipeline": RID, "mtime": int}。
## 三个 writer 都是每次显示重建 new() 一个实例又 dispose()，实例成员缓存不了任何东西，
## 于是每次重建都要重跑 shader_create_from_spirv（SPIR-V 反射 + zstd 压缩/解压 + module）
## 与 compute_pipeline_create。这里的设备是**主** RenderingDevice，随进程存活，所以缓存
## 挂 static 是安全的；相应地 dispose() 不再释放 shader/pipeline（见 _release），它们的
## 生命周期改为进程级，总量固定为三个 writer shader。
## RID 不是 Object，类型化 static Dictionary 不受编辑器脚本重载把 static Object 置 null 的影响。
## 源文件 mtime 变化时重建，保留改 .glsl 后无需重启即时生效（原每次重编译白拿到的行为）。
static var _kernel_cache: Dictionary = {}

var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _multimesh := RID()
var _buffer_rid := RID()

# Scratch input buffers, recreated per write, freed before the next write or on
# dispose. The per-write uniform set is tracked separately (it depends on the
# externally-owned MultiMesh buffer, so freeing it needs a validity guard).
var _scratch: Array[RID] = []
var _uniform_set := RID()
var _instance_count := 0
var _ready := false
var _disposed := false
var _last_reason := "uninitialized"


func _init() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		_last_reason = "no_main_rendering_device"
		return
	_ready = true


func is_ready() -> bool:
	return _ready


func last_reason() -> String:
	return _last_reason


# Bind the MultiMesh this writer fills. multimesh_rid must already be allocated
# with TRANSFORM_3D + use_colors and instance_count == the writer's instance count.
func bind_multimesh(multimesh_rid: RID, instance_count: int) -> bool:
	if not _ready:
		return false
	if not multimesh_rid.is_valid() or instance_count <= 0:
		_last_reason = "invalid_multimesh_binding"
		return false
	_multimesh = multimesh_rid
	_instance_count = instance_count
	if RenderingServer.has_method("multimesh_get_buffer_rd_rid"):
		_buffer_rid = RenderingServer.call("multimesh_get_buffer_rd_rid", _multimesh)
		if not _buffer_rid.is_valid():
			_last_reason = "multimesh_buffer_rid_invalid"
			return false
		return true
	_last_reason = "multimesh_buffer_rd_rid_unavailable"
	return false


# Compute shader resource path for this writer's dispatch. Overridden per subclass.
func _shader_path() -> String:
	return ""


func _ensure_pipeline() -> bool:
	if _pipeline.is_valid():
		return true

	var path := _shader_path()
	var mtime := FileAccess.get_modified_time(ProjectSettings.globalize_path(path))
	var cached: Dictionary = _kernel_cache.get(path, {})
	if not cached.is_empty():
		var cached_shader: RID = cached.get("shader", RID())
		var cached_pipeline: RID = cached.get("pipeline", RID())
		if cached_shader.is_valid() and cached_pipeline.is_valid() \
				and (mtime == 0 or int(cached.get("mtime", -1)) == mtime):
			_shader = cached_shader
			_pipeline = cached_pipeline
			return true
		# 源文件已改动：旧的进程级 RID 无人再引用，这里显式回收后重建。
		_release(_rd, cached_shader, cached_pipeline, RID(), [])
		_kernel_cache.erase(path)

	var shader_file := load(path) as RDShaderFile
	if shader_file == null:
		_last_reason = "shader_load_failed"
		return false
	_shader = _rd.shader_create_from_spirv(shader_file.get_spirv())
	if not _shader.is_valid():
		_last_reason = "shader_create_failed"
		return false
	_pipeline = _rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		_last_reason = "pipeline_create_failed"
		return false
	_kernel_cache[path] = {"shader": _shader, "pipeline": _pipeline, "mtime": mtime}
	return true


func _make_buffer(bytes: PackedByteArray) -> RID:
	if bytes.is_empty():
		bytes = PackedByteArray()
		bytes.resize(4)
	var rid := _rd.storage_buffer_create(bytes.size(), bytes)
	if rid.is_valid():
		_scratch.append(rid)
	return rid


func _storage_uniform(binding: int, buffer: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(buffer)
	return u


func _free_scratch() -> void:
	if _rd == null:
		return
	_free_resources(_rd, _uniform_set, _scratch)
	_uniform_set = RID()
	_scratch.clear()


func dispose() -> void:
	if _disposed:
		return
	_disposed = true
	# shader/pipeline 归 _kernel_cache 所有（进程级、跨 writer 实例复用），这里只回收
	# 本实例自有的 per-write 资源；传 RID() 占位而非 _shader/_pipeline。
	_release(_rd, RID(), RID(), _uniform_set, _scratch)
	_rd = null
	_shader = RID()
	_pipeline = RID()
	_uniform_set = RID()
	_scratch = []


# Frees the GPU resources handed to it. Callers pass RID() for shader/pipeline on the
# dispose path -- those live in the process-lifetime _kernel_cache and are only freed
# here when _ensure_pipeline invalidates a stale entry. Static on purpose: it is also driven
# from NOTIFICATION_PREDELETE, where the writer is an already-unreferenced
# RefCounted. Calling an instance method there -- or binding `self` into a
# render-thread callable -- fails with "call function on a null instance" and
# leaks the RIDs. Binding only the device + RID values keeps the deferred free
# valid even once the writer itself is gone.
static func _release(rd: RenderingDevice, shader: RID, pipeline: RID, uniform_set: RID, buffers: Array) -> void:
	if rd == null:
		return
	# Main device: RID frees must run on the render thread. Reference the static
	# helper by bare name (the class_name is not yet self-resolvable at compile).
	RenderingServer.call_on_render_thread(_free_all.bind(rd, shader, pipeline, uniform_set, buffers))


static func _free_all(rd: RenderingDevice, shader: RID, pipeline: RID, uniform_set: RID, buffers: Array) -> void:
	if rd == null:
		return
	_free_resources(rd, uniform_set, buffers)
	if pipeline.is_valid():
		rd.free_rid(pipeline)
	if shader.is_valid():
		rd.free_rid(shader)


# Frees the per-write scratch: the uniform set first (it depends on the buffers),
# then the owned storage buffers. The uniform set also references the externally
# owned MultiMesh buffer, so it can be auto-invalidated when that buffer is freed
# first (orphaned node) -- guard with uniform_set_is_valid to avoid an invalid-ID
# free.
static func _free_resources(rd: RenderingDevice, uniform_set: RID, buffers: Array) -> void:
	if rd == null:
		return
	if uniform_set.is_valid() and rd.uniform_set_is_valid(uniform_set):
		rd.free_rid(uniform_set)
	for i in range(buffers.size() - 1, -1, -1):
		var rid: RID = buffers[i]
		if rid.is_valid():
			rd.free_rid(rid)


func _notification(what: int) -> void:
	# tree_exiting on the owning node drives dispose() while everything is alive.
	# PREDELETE is the last-resort guard for an orphan writer that never left a
	# tree: free inline via the static release. Calling the dispose() instance
	# method here would fail with "null instance" on the dying RefCounted.
	if what == NOTIFICATION_PREDELETE and not _disposed:
		_disposed = true
		_release(_rd, RID(), RID(), _uniform_set, _scratch)
