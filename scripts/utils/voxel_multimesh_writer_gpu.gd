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
	var shader_file := load(_shader_path()) as RDShaderFile
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
	_release(_rd, _shader, _pipeline, _uniform_set, _scratch)
	_rd = null
	_shader = RID()
	_pipeline = RID()
	_uniform_set = RID()
	_scratch = []


# Frees every GPU resource the writer owns. Static on purpose: it is also driven
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
		_release(_rd, _shader, _pipeline, _uniform_set, _scratch)
