@tool
extends RefCounted

# scatter_sv_field_records.glsl 的 CPU 侧共享契约:着色器路径、记录 stride、
# 体素去重键与 slot 字典 → 连续 float 缓冲的展平。
# 原 SceneVoxelCommitter(stamp-only 提交)与 ScenePlacementActor(BrushSV 散射)各持一份;
# slot 的填充语义两端不同(committer 合并写、SPA 后笔胜),保留在各自调用方。

const SHADER_PATH := "res://shaders/scatter_sv_field_records.glsl"
const RECORD_FLOAT_STRIDE := 8  # [x, z, slice, complexity, r, g, b, collision]


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
