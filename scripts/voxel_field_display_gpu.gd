class_name VoxelFieldDisplayGPU
extends RefCounted

# All-GPU voxel field renderer. Takes per-voxel field arrays (occupancy /
# collision / color / terrain height) plus grid params, and drives a MultiMesh
# whose instance transforms + colors are written DIRECTLY into the MultiMesh
# buffer by a compute pass on the MAIN RenderingDevice. There is no GPU->CPU
# readback: the field is uploaded once, the instance buffer is filled GPU-side,
# and the renderer draws it via a known custom AABB (empty cells collapse to a
# zero basis on the GPU and rasterize to nothing).
#
# One instance per grid cell (full grid). Hold the returned instance alive for
# as long as the MultiMesh is shown; freeing it releases the scratch GPU
# resources on the render thread.

const SHADER_PATH := "res://shaders/voxel_field_instances.glsl"
const LOCAL_SIZE := 64
const FLOATS_PER_INSTANCE := 16

const VIEW_TARGET_COLOR := 0
const VIEW_PROJECT_COLOR := 1
const VIEW_COMPLEXITY := 2
const VIEW_COLLISION := 3

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
var _voxel_count := 0
var _ready := false
var _disposed := false
var _last_reason := "uninitialized"

# Readback fallback for engines without RenderingServer.multimesh_get_buffer_rd_rid
# (added in Godot 4.4). When true, _rd is a *local* RenderingDevice: the same
# compute fills a scratch output buffer that is read back and pushed into the
# MultiMesh via multimesh_set_buffer(). Per-voxel math stays on the GPU.
var _use_readback := false


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
# with TRANSFORM_3D + use_colors and instance_count == voxel_count.
func bind_multimesh(multimesh_rid: RID, voxel_count: int) -> bool:
	if not _ready:
		return false
	if not multimesh_rid.is_valid() or voxel_count <= 0:
		_last_reason = "invalid_multimesh_binding"
		return false
	_multimesh = multimesh_rid
	_voxel_count = voxel_count
	if RenderingServer.has_method("multimesh_get_buffer_rd_rid"):
		_buffer_rid = RenderingServer.call("multimesh_get_buffer_rd_rid", _multimesh)
		if not _buffer_rid.is_valid():
			_last_reason = "multimesh_buffer_rid_invalid"
			return false
		return true
	# Godot < 4.4: no direct RD handle on the MultiMesh buffer. Fall back to a
	# local RenderingDevice + readback path (see _use_readback). _rd is swapped to
	# the local device; the main device is not needed past this point.
	var local := RenderingServer.create_local_rendering_device()
	if local == null:
		_last_reason = "local_rendering_device_unavailable"
		return false
	_rd = local
	_use_readback = true
	_last_reason = "readback_fallback"
	return true


# fields: { occupancy, collision, color_rgba (PackedFloat32Array, 4/voxel),
#           terrain_height }. params: { xz_res, slice_count, view_mode,
#           capture_size, display_scale, vertical_span, height_span, threshold }.
# Dispatches the field->instance compute write on the render thread. Zero readback.
func write_field(fields: Dictionary, params: Dictionary) -> bool:
	if not _ready:
		_last_reason = "writer_not_bound"
		return false
	if not _use_readback and not _buffer_rid.is_valid():
		_last_reason = "writer_not_bound"
		return false

	var occupancy: PackedFloat32Array = fields.get("occupancy", PackedFloat32Array())
	var collision: PackedFloat32Array = fields.get("collision", PackedFloat32Array())
	var color_rgba: PackedFloat32Array = fields.get("color_rgba", PackedFloat32Array())
	var terrain_height: PackedFloat32Array = fields.get("terrain_height", PackedFloat32Array())

	if occupancy.size() != _voxel_count:
		_last_reason = "occupancy_size_mismatch"
		return false
	if collision.size() != _voxel_count:
		collision = PackedFloat32Array()
		collision.resize(_voxel_count)
	if color_rgba.size() != _voxel_count * 4:
		_last_reason = "color_rgba_size_mismatch"
		return false
	if terrain_height.is_empty():
		terrain_height = PackedFloat32Array()
		terrain_height.resize(1)

	if _use_readback:
		# Local-device path: synchronous compute + readback + multimesh_set_buffer.
		return _readback_write(occupancy, collision, color_rgba, terrain_height, params.duplicate(true))

	# Everything that touches the rendering device must run on the render thread,
	# where the MultiMesh buffer RID is usable as a storage buffer.
	RenderingServer.call_on_render_thread(
		_render_thread_write.bind(occupancy, collision, color_rgba, terrain_height, params.duplicate(true))
	)
	_last_reason = "dispatched"
	return true


# Godot < 4.4 fallback. Runs the same compute on the local _rd, writing into a
# scratch output buffer instead of the (inaccessible) MultiMesh RD buffer, then
# reads it back and uploads it with multimesh_set_buffer(). Synchronous: safe to
# call from the scene thread during build.
func _readback_write(
	occupancy: PackedFloat32Array,
	collision: PackedFloat32Array,
	color_rgba: PackedFloat32Array,
	terrain_height: PackedFloat32Array,
	params: Dictionary
) -> bool:
	_free_scratch()
	if not _ensure_pipeline():
		return false

	var occ_buf := _make_buffer(occupancy.to_byte_array())
	var coll_buf := _make_buffer(collision.to_byte_array())
	var color_buf := _make_buffer(color_rgba.to_byte_array())
	var height_buf := _make_buffer(terrain_height.to_byte_array())
	if not occ_buf.is_valid() or not coll_buf.is_valid() or not color_buf.is_valid() or not height_buf.is_valid():
		_last_reason = "scratch_buffer_create_failed"
		return false

	var out_bytes := PackedByteArray()
	out_bytes.resize(_voxel_count * FLOATS_PER_INSTANCE * 4)
	var out_buf := _rd.storage_buffer_create(out_bytes.size(), out_bytes)
	if not out_buf.is_valid():
		_last_reason = "output_buffer_create_failed"
		return false
	_scratch.append(out_buf)

	var uniforms: Array[RDUniform] = [
		_storage_uniform(0, occ_buf),
		_storage_uniform(1, coll_buf),
		_storage_uniform(2, color_buf),
		_storage_uniform(3, height_buf),
		_storage_uniform(4, out_buf),
	]
	var set0 := _rd.uniform_set_create(uniforms, _shader, 0)
	if not set0.is_valid():
		_last_reason = "uniform_set_create_failed"
		return false
	_uniform_set = set0

	params["terrain_len"] = terrain_height.size()
	var push := _pack_push(params)
	var groups := int(ceil(float(_voxel_count) / float(LOCAL_SIZE)))

	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_end()
	_rd.submit()
	_rd.sync()

	var data := _rd.buffer_get_data(out_buf)
	RenderingServer.multimesh_set_buffer(_multimesh, data.to_float32_array())
	_free_scratch()
	_last_reason = "ok_readback"
	return true


func _render_thread_write(
	occupancy: PackedFloat32Array,
	collision: PackedFloat32Array,
	color_rgba: PackedFloat32Array,
	terrain_height: PackedFloat32Array,
	params: Dictionary
) -> void:
	_free_scratch()
	if not _ensure_pipeline():
		return

	var occ_buf := _make_buffer(occupancy.to_byte_array())
	var coll_buf := _make_buffer(collision.to_byte_array())
	var color_buf := _make_buffer(color_rgba.to_byte_array())
	var height_buf := _make_buffer(terrain_height.to_byte_array())
	if not occ_buf.is_valid() or not coll_buf.is_valid() or not color_buf.is_valid() or not height_buf.is_valid():
		_last_reason = "scratch_buffer_create_failed"
		return

	var uniforms: Array[RDUniform] = [
		_storage_uniform(0, occ_buf),
		_storage_uniform(1, coll_buf),
		_storage_uniform(2, color_buf),
		_storage_uniform(3, height_buf),
		_storage_uniform(4, _buffer_rid),
	]
	var set0 := _rd.uniform_set_create(uniforms, _shader, 0)
	if not set0.is_valid():
		_last_reason = "uniform_set_create_failed"
		return
	_uniform_set = set0

	params["terrain_len"] = terrain_height.size()
	var push := _pack_push(params)
	var groups := int(ceil(float(_voxel_count) / float(LOCAL_SIZE)))

	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_end()
	_last_reason = "ok"


func _ensure_pipeline() -> bool:
	if _pipeline.is_valid():
		return true
	var shader_file := load(SHADER_PATH) as RDShaderFile
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


func _pack_push(params: Dictionary) -> PackedByteArray:
	var push := PackedByteArray()
	push.resize(48)
	push.encode_s32(0, _voxel_count)
	push.encode_s32(4, int(params.get("xz_res", 1)))
	push.encode_s32(8, int(params.get("slice_count", 1)))
	push.encode_s32(12, int(params.get("view_mode", VIEW_TARGET_COLOR)))
	push.encode_float(16, float(params.get("capture_size", 1.0)))
	push.encode_float(20, float(params.get("display_scale", 1.0)))
	push.encode_float(24, float(params.get("vertical_span", 1.0)))
	push.encode_float(28, float(params.get("height_span", 1.0)))
	push.encode_float(32, float(params.get("threshold", 0.0)))
	push.encode_s32(36, int(params.get("terrain_len", 1)))
	push.encode_float(40, 0.0)
	push.encode_float(44, 0.0)
	return push


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
	_release(_rd, _shader, _pipeline, _uniform_set, _scratch, _use_readback)
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
static func _release(rd: RenderingDevice, shader: RID, pipeline: RID, uniform_set: RID, buffers: Array, use_readback: bool) -> void:
	if rd == null:
		return
	if use_readback:
		# Local device: free synchronously on this thread, then destroy the device.
		_free_all(rd, shader, pipeline, uniform_set, buffers)
		rd.free()
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
		_release(_rd, _shader, _pipeline, _uniform_set, _scratch, _use_readback)
