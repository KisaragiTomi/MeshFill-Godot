class_name BrushVoxelDisplayGPU
extends RefCounted

# All-GPU brush voxel renderer. Takes a sparse list of painted brush voxels
# (voxel_x, slice, voxel_z) plus the terrain height field, and drives a tetra
# MultiMesh whose instance transforms + colors are written DIRECTLY into the
# MultiMesh buffer by a compute pass on the MAIN RenderingDevice. There is no
# GPU->CPU readback: the brush coords are uploaded once, the instance buffer is
# filled GPU-side, and the renderer draws it via a known custom AABB.
#
# One instance per painted voxel (instance_count == brush voxel count). Hold the
# returned writer alive for as long as the MultiMesh is shown; freeing it
# releases the scratch GPU resources on the render thread.

const SHADER_PATH := "res://shaders/brush_voxel_instances.glsl"
const LOCAL_SIZE := 64
const FLOATS_PER_INSTANCE := 16

var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _multimesh := RID()
var _buffer_rid := RID()

var _scratch: Array[RID] = []
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
# with TRANSFORM_3D + use_colors and instance_count == brush voxel count.
func bind_multimesh(multimesh_rid: RID, instance_count: int) -> bool:
	if not _ready:
		return false
	if not multimesh_rid.is_valid() or instance_count <= 0:
		_last_reason = "invalid_multimesh_binding"
		return false
	_multimesh = multimesh_rid
	_instance_count = instance_count
	_buffer_rid = RenderingServer.multimesh_get_buffer_rd_rid(_multimesh)
	if not _buffer_rid.is_valid():
		_last_reason = "multimesh_buffer_rid_invalid"
		return false
	return true


# brush_voxels: PackedInt32Array laid out as (voxel_x, slice, voxel_z, 0) per
# voxel. params: { xz_res, slice_count, capture_size, display_scale,
# vertical_span, height_span, brush_color, terrain_height }.
# Dispatches the brush->instance compute write on the render thread. Zero readback.
func write_brush(brush_voxels: PackedInt32Array, params: Dictionary) -> bool:
	if not _ready or not _buffer_rid.is_valid():
		_last_reason = "writer_not_bound"
		return false
	if brush_voxels.size() != _instance_count * 4:
		_last_reason = "brush_voxels_size_mismatch"
		return false

	var terrain_height: PackedFloat32Array = params.get("terrain_height", PackedFloat32Array())
	if terrain_height.is_empty():
		terrain_height = PackedFloat32Array()
		terrain_height.resize(1)

	var brush_colors: PackedFloat32Array = params.get("brush_colors", PackedFloat32Array())
	if brush_colors.size() != _instance_count * 4:
		var fallback_color: Color = params.get("brush_color", Color.WHITE)
		brush_colors = PackedFloat32Array()
		brush_colors.resize(_instance_count * 4)
		for i in range(_instance_count):
			brush_colors[i * 4 + 0] = fallback_color.r
			brush_colors[i * 4 + 1] = fallback_color.g
			brush_colors[i * 4 + 2] = fallback_color.b
			brush_colors[i * 4 + 3] = fallback_color.a

	RenderingServer.call_on_render_thread(
		_render_thread_write.bind(brush_voxels, terrain_height, brush_colors, params.duplicate(true))
	)
	_last_reason = "dispatched"
	return true


func _render_thread_write(
	brush_voxels: PackedInt32Array,
	terrain_height: PackedFloat32Array,
	brush_colors: PackedFloat32Array,
	params: Dictionary
) -> void:
	_free_scratch()
	if not _ensure_pipeline():
		return

	var voxel_buf := _make_buffer(brush_voxels.to_byte_array())
	var height_buf := _make_buffer(terrain_height.to_byte_array())
	var color_buf := _make_buffer(brush_colors.to_byte_array())
	if not voxel_buf.is_valid() or not height_buf.is_valid() or not color_buf.is_valid():
		_last_reason = "scratch_buffer_create_failed"
		return

	var uniforms: Array[RDUniform] = [
		_storage_uniform(0, voxel_buf),
		_storage_uniform(1, height_buf),
		_storage_uniform(2, _buffer_rid),
		_storage_uniform(3, color_buf),
	]
	var set0 := _rd.uniform_set_create(uniforms, _shader, 0)
	if not set0.is_valid():
		_last_reason = "uniform_set_create_failed"
		return
	_scratch.append(set0)

	var push := _pack_push(terrain_height.size(), params)
	var groups := int(ceil(float(_instance_count) / float(LOCAL_SIZE)))

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


func _pack_push(height_count: int, params: Dictionary) -> PackedByteArray:
	var brush_color: Color = params.get("brush_color", Color.WHITE)
	var push := PackedByteArray()
	push.resize(48)
	push.encode_s32(0, _instance_count)
	push.encode_s32(4, int(params.get("xz_res", 1)))
	push.encode_s32(8, int(params.get("slice_count", 1)))
	push.encode_s32(12, height_count)
	push.encode_float(16, float(params.get("capture_size", 1.0)))
	push.encode_float(20, float(params.get("display_scale", 1.0)))
	push.encode_float(24, float(params.get("vertical_span", 1.0)))
	push.encode_float(28, float(params.get("height_span", 1.0)))
	push.encode_float(32, brush_color.r)
	push.encode_float(36, brush_color.g)
	push.encode_float(40, brush_color.b)
	push.encode_float(44, brush_color.a)
	return push


func _free_scratch() -> void:
	if _rd == null:
		return
	# Free in reverse creation order: the uniform set is created last and depends
	# on the storage buffers, so it must be released before them.
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
	if what == NOTIFICATION_PREDELETE and not _disposed:
		dispose()