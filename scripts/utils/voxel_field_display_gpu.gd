class_name VoxelFieldDisplayGPU
extends "res://scripts/utils/voxel_multimesh_writer_gpu.gd"

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
# resources on the render thread. Shared device/pipeline/scratch lifecycle lives
# in VoxelMultiMeshWriterGPU.

const SHADER_PATH := "res://shaders/voxel_field_instances.glsl"
const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")

const VIEW_TARGET_COLOR := 0
const VIEW_PROJECT_COLOR := 1
const VIEW_COMPLEXITY := 2
const VIEW_COLLISION := 3


func _shader_path() -> String:
	return SHADER_PATH


# fields: { occupancy, collision, color_rgba (float CPU views; uploaded as
#           R8/R8/RGBA8), terrain_height }. params: { xz_res, slice_count, view_mode,
#           capture_size, display_scale, vertical_span, height_span, threshold }.
# Dispatches the field->instance compute write on the render thread. Zero readback.
func write_field(fields: Dictionary, params: Dictionary) -> bool:
	if not _ready:
		_last_reason = "writer_not_bound"
		return false
	if not _buffer_rid.is_valid():
		_last_reason = "writer_not_bound"
		return false

	var occupancy: PackedFloat32Array = fields.get("occupancy", PackedFloat32Array())
	var collision: PackedFloat32Array = fields.get("collision", PackedFloat32Array())
	var color_rgba: PackedFloat32Array = fields.get("color_rgba", PackedFloat32Array())
	var terrain_height: PackedFloat32Array = fields.get("terrain_height", PackedFloat32Array())

	if occupancy.size() != _instance_count:
		_last_reason = "occupancy_size_mismatch"
		return false
	if collision.size() != _instance_count:
		collision = PackedFloat32Array()
		collision.resize(_instance_count)
	if color_rgba.size() != _instance_count * 4:
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

	var occ_buf := _make_buffer(SceneVoxelTileCodecScript.pack_collision_field_u32_bytes(occupancy, _instance_count))
	var coll_buf := _make_buffer(SceneVoxelTileCodecScript.pack_collision_field_u32_bytes(collision, _instance_count))
	var color_buf := _make_buffer(SceneVoxelTileCodecScript.pack_complexity_field_rgba8_bytes(color_rgba, _instance_count))
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
	var groups := int(ceil(float(_instance_count) / float(LOCAL_SIZE)))

	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_end()
	_last_reason = "ok"


func _pack_push(params: Dictionary) -> PackedByteArray:
	var push := PackedByteArray()
	push.resize(48)
	push.encode_s32(0, _instance_count)
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
