class_name VoxelInstanceDisplayGPU
extends "res://scripts/utils/voxel_multimesh_writer_gpu.gd"

# GPU-only sparse/explicit instance display writer. Source transforms/colors are
# uploaded as storage buffers, then a compute pass copies them into the real
# MultiMesh instance buffer on the MAIN RenderingDevice. No readback fallback.
# Shared device/pipeline/scratch lifecycle lives in VoxelMultiMeshWriterGPU.

const SHADER_PATH := "res://shaders/voxel_instance_copy.glsl"
const TRANSFORM_FLOATS := 12
const COLOR_FLOATS := 4


func _shader_path() -> String:
	return SHADER_PATH


func write_instances(transform_floats: PackedFloat32Array, color_floats: PackedFloat32Array) -> bool:
	if not _ready or not _buffer_rid.is_valid():
		_last_reason = "writer_not_bound"
		return false
	if transform_floats.size() != _instance_count * TRANSFORM_FLOATS:
		_last_reason = "transform_size_mismatch"
		return false
	var use_colors := color_floats.size() == _instance_count * COLOR_FLOATS
	if not use_colors:
		color_floats = PackedFloat32Array()
		color_floats.resize(COLOR_FLOATS)
		color_floats[0] = 1.0
		color_floats[1] = 1.0
		color_floats[2] = 1.0
		color_floats[3] = 1.0

	RenderingServer.call_on_render_thread(
		_render_thread_write.bind(transform_floats, color_floats, use_colors)
	)
	_last_reason = "dispatched"
	return true


func _render_thread_write(
	transform_floats: PackedFloat32Array,
	color_floats: PackedFloat32Array,
	use_colors: bool
) -> void:
	_free_scratch()
	if not _ensure_pipeline():
		return

	var transform_buf := _make_buffer(transform_floats.to_byte_array())
	var color_buf := _make_buffer(color_floats.to_byte_array())
	if not transform_buf.is_valid() or not color_buf.is_valid():
		_last_reason = "scratch_buffer_create_failed"
		return

	var uniforms: Array[RDUniform] = [
		_storage_uniform(0, transform_buf),
		_storage_uniform(1, color_buf),
		_storage_uniform(2, _buffer_rid),
	]
	var set0 := _rd.uniform_set_create(uniforms, _shader, 0)
	if not set0.is_valid():
		_last_reason = "uniform_set_create_failed"
		return
	_uniform_set = set0

	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, _instance_count)
	push.encode_s32(4, 1 if use_colors else 0)

	var groups := int(ceil(float(_instance_count) / float(LOCAL_SIZE)))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_end()
	_last_reason = "ok"
