@tool
extends RefCounted

# scatter_sv_field_records.glsl 的 CPU 侧共享契约:着色器路径、记录 stride、push 布局、
# 体素去重键、slot 字典 → 连续 float 缓冲的展平,以及 GPU dispatch 半边(dispatch_scatter)。
# 原 SceneVoxelCommitter(stamp-only 提交)与 ScenePlacementActor(BrushSV 散射)各持一份;
# slot 的填充语义两端不同(committer 合并写、SPA 后笔胜),保留在各自调用方。

const SHADER_PATH := "res://shaders/scatter_sv_field_records.glsl"
const RECORD_FLOAT_STRIDE := 8  # [x, z, slice, complexity, r, g, b, collision]

## std430 push-constant 布局(16B,4×int),字段名以 shader push 块为准;
## write_mode: 0=overwrite(BrushSV 后笔胜)、1=max-by-complexity(committed SV 单调合并)。
const SCATTER_PUSH := [
	["xz_res", "int"],
	["total_slices", "int"],
	["record_count", "int"],
	["write_mode", "int"],
]


## 体素去重键:slice/z/x 分段编码,保证单次散射 dispatch 内同体素只有一条记录。
static func record_key(voxel_xz: Vector2i, slice_index: int) -> int:
	return slice_index * 0x100000000 + voxel_xz.y * 0x10000 + voxel_xz.x


## 将 {record_key -> PackedFloat32Array(RECORD_FLOAT_STRIDE)} 的 slot 字典
## 按插入序展平为连续 float 缓冲,供 storage_buffer_from_floats 上传。
static func flatten_record_slots(slots_by_key: Dictionary) -> PackedFloat32Array:
	var floats := PackedFloat32Array()
	floats.resize(slots_by_key.size() * RECORD_FLOAT_STRIDE)
	var offset := 0
	for record_key_value in slots_by_key.keys():
		var slot: PackedFloat32Array = slots_by_key[record_key_value]
		for component_index in range(RECORD_FLOAT_STRIDE):
			floats[offset + component_index] = slot[component_index]
		offset += RECORD_FLOAT_STRIDE
	return floats


## GPU dispatch 半边:shader/pipeline → 展平上传 → 3-binding uniform set → push → dispatch。
## host 为 GodotComputeShaderBase 派生调用方;失败 reason = "<reason_prefix>_...",每个出口 gc_frame;
## 前置检查(记录数/目标缓冲有效性)与成功后的状态推进留在调用方。
static func dispatch_scatter(
	host: GodotComputeShaderBase,
	complexity_buffer: RID,
	collision_buffer: RID,
	slots_by_key: Dictionary,
	xz_res: int,
	total_slices: int,
	write_mode: int,
	reason_prefix: String = "scatter",
	debug_label: String = "sv_field_scatter"
) -> Dictionary:
	var record_count := slots_by_key.size()
	var shader: RID = host.load_compute_shader(SHADER_PATH, GodotComputeShaderBase.SCOPE_FRAME, debug_label)
	var pipeline: RID = host.create_compute_pipeline(shader, GodotComputeShaderBase.SCOPE_FRAME, debug_label)
	if not shader.is_valid() or not pipeline.is_valid():
		host.gc_frame()
		return {"ok": false, "reason": reason_prefix + "_shader_not_ready", "record_count": record_count, "gpu_dispatched": false}
	var record_buffer: RID = host.storage_buffer_from_floats(flatten_record_slots(slots_by_key), GodotComputeShaderBase.SCOPE_FRAME, debug_label + "_records")
	if not record_buffer.is_valid():
		host.gc_frame()
		return {"ok": false, "reason": reason_prefix + "_record_buffer_failed", "record_count": record_count, "gpu_dispatched": false}
	var set0: RID = host.create_uniform_set([
		host.make_storage_uniform(0, complexity_buffer),
		host.make_storage_uniform(1, collision_buffer),
		host.make_storage_uniform(2, record_buffer),
	], shader, 0, GodotComputeShaderBase.SCOPE_PASS, debug_label)
	if not set0.is_valid():
		host.gc_frame()
		return {"ok": false, "reason": reason_prefix + "_uniform_set_failed", "record_count": record_count, "gpu_dispatched": false}
	var push := PushConstantLayout.new(SCATTER_PUSH).pack({
		xz_res = xz_res,
		total_slices = total_slices,
		record_count = record_count,
		write_mode = write_mode,
	})
	if not host._gpu_dispatch_and_sync(pipeline, [set0], push, host.dispatch_groups_1d(record_count, 64)):
		host.gc_frame()
		return {"ok": false, "reason": reason_prefix + "_dispatch_failed", "record_count": record_count, "gpu_dispatched": false}
	host.gc_frame()
	return {"ok": true, "record_count": record_count, "gpu_dispatched": true}
