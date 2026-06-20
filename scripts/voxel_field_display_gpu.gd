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

# Scratch input buffers + uniform set, recreated per write, freed on the render
# thread before the next write or on dispose.
var _scratch: Array[RID] = []
var _voxel_count := 0
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
# with TRANSFORM_3D + use_colors and instance_count == voxel_count.
func bind_multimesh(multimesh_rid: RID, voxel_count: int) -> bool:
	if not _ready:
		return false
	if not multimesh_rid.is_valid() or voxel_count <= 0:
		_last_reason = "invalid_multimesh_binding"
		return false
	_multimesh = multimesh_rid
	_voxel_count = voxel_count
	_buffer_rid = RenderingServer.multimesh_get_buffer_rd_rid(_multimesh)
	if not _buffer_rid.is_valid():
		_last_reason = "multimesh_buffer_rid_invalid"
		return false
	return true


# fields: { occupancy, collision, color_rgba (PackedFloat32Array, 4/voxel),
#           terrain_height }. params: { xz_res, slice_count, view_mode,
#           capture_size, display_scale, vertical_span, height_span, threshold }.
# Dispatches the field->instance compute write on the render thread. Zero readback.
func write_field(fields: Dictionary, params: Dictionary) -> bool:
	if not _ready or not _buffer_rid.is_valid():
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

	# Everything that touches the rendering device must run on the render thread,
	# where the MultiMesh buffer RID is usable as a storage buffer.
	RenderingServer.call_on_render_thread(
		_render_thread_write.bind(occupancy, collision, color_rgba, terrain_height, params.duplicate(true))
	)
	_last_reason = "dispatched"
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
	_scratch.append(set0)

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
	# Free in reverse creation order: the uniform set is created last and depends
	# on the storage buffers, so it must be released before them. Freeing a buffer
	# first auto-invalidates the dependent uniform set and makes its free fail.
	for i in range(_scratch.size() - 1, -1, -1):
		var rid: RID = _scratch[i]
		if rid.is_valid():
			_rd.free_rid(rid)
	_scratch.clear()


func dispose() -> void:
	if _rd == null or _disposed:
		return
	_disposed = true
	RenderingServer.call_on_render_thread(_render_thread_dispose)


func _render_thread_dispose() -> void:
	_free_scratch()
	if _pipeline.is_valid():
		_rd.free_rid(_pipeline)
		_pipeline = RID()
	if _shader.is_valid():
		_rd.free_rid(_shader)
		_shader = RID()


func _notification(what: int) -> void:
	# tree_exiting on the owning node drives dispose() while everything is alive;
	# PREDELETE is only a last-resort guard and is a no-op once disposed.
	if what == NOTIFICATION_PREDELETE and not _disposed:
		dispose()