#[compute]
#version 450

// Prepare placement-facing TargetSV read buffers from optional prepacked bytes.
//
// Layout and formats:
//   set 0 binding 0: optional source target_visual_rgba8 words, one u32 per voxel.
//   set 0 binding 1: optional source target_occupancy bytes reinterpreted as u32,
//                    one R32F byte word per voxel. The shader copies the word
//                    verbatim and never interprets it as a float.
//   set 0 binding 2: output target_visual_rgba8 words, one u32 per voxel.
//   set 0 binding 3: output target_occupancy bytes as u32 words, one R32F word per voxel.
//
// Valid range:
//   voxel_count >= 1. Source buffers are valid only when their valid flag is 1;
//   otherwise outputs are zero-filled.
//
// Dispatch:
//   local_size_x = 64, groups_x = ceil(voxel_count / 64). Invocations with
//   idx >= voxel_count are edge-guarded.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer ColorInput {
	uint color_in[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer OccupancyInput {
	uint occupancy_in[];
};

layout(set = 0, binding = 2, std430) restrict writeonly buffer ColorOutput {
	uint color_out[];
};

layout(set = 0, binding = 3, std430) restrict writeonly buffer OccupancyOutput {
	uint occupancy_out[];
};

layout(push_constant, std430) uniform Params {
	int voxel_count;       // byte 0
	int color_valid;       // byte 4
	int occupancy_valid;   // byte 8
	int pad0;              // byte 12
};

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= uint(max(voxel_count, 0))) {
		return;
	}

	color_out[idx] = color_valid != 0 ? color_in[idx] : 0u;
	occupancy_out[idx] = occupancy_valid != 0 ? occupancy_in[idx] : 0u;
}
