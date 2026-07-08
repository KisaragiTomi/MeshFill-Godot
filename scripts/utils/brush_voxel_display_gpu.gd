class_name BrushVoxelDisplayGPU
extends "res://scripts/utils/voxel_multimesh_writer_gpu.gd"

# All-GPU brush voxel renderer. Takes a sparse list of painted brush voxels
# (voxel_x, slice, voxel_z) plus the terrain height field, and drives a tetra
# MultiMesh whose instance transforms + colors are written DIRECTLY into the
# MultiMesh buffer by a compute pass on the MAIN RenderingDevice. There is no
# GPU->CPU readback: the brush coords are uploaded once, the instance buffer is
# filled GPU-side, and the renderer draws it via a known custom AABB.
#
# One instance per painted voxel (instance_count == brush voxel count). Hold the
# returned writer alive for as long as the MultiMesh is shown; freeing it
# releases the scratch GPU resources on the render thread. Shared device/pipeline/
# scratch lifecycle lives in VoxelMultiMeshWriterGPU.

const SHADER_PATH := "res://shaders/brush_voxel_instances.glsl"


func _shader_path() -> String:
	return SHADER_PATH


# brush_voxels: PackedInt32Array laid out as (voxel_x, slice, voxel_z, 0) per
# voxel. params: { xz_res, slice_count, capture_size, display_scale,
# vertical_span, height_span, brush_color, terrain_height }.
# Dispatches the brush->instance compute write on the render thread. Zero readback.
func write_brush(brush_voxels: PackedInt32Array, params: Dictionary) -> bool:
	if not _ready:
		_last_reason = "writer_not_bound"
		return false
	if not _buffer_rid.is_valid():
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
	_uniform_set = set0

	var push := _pack_push(terrain_height.size(), params)
	var groups := int(ceil(float(_instance_count) / float(LOCAL_SIZE)))

	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_end()
	_last_reason = "ok"


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
