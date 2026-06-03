#[compute]
#version 450

// Extract one float debug channel from a dense debug voxel buffer.
//
// Input layout:
//   set 0 binding 0: debug_voxel, r32f values laid out as
//     voxel_count * channel_stride floats. The current caller uses
//     channel_stride = VoxelPlacementGenerator.NUM_DEBUG_CHANNELS.
//
// Output layout:
//   set 0 binding 1: channel_out, one r32f value per voxel.
//
// Valid ranges:
//   voxel_count >= 0
//   channel_index in [0, channel_stride)
//   channel_stride > 0
//
// Dispatch:
//   local_size_x = 64, groups_x = ceil(voxel_count / 64).
//   Invocations with idx >= voxel_count are edge-guarded.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer DebugVoxelInput {
	float debug_voxel[];
};

layout(set = 0, binding = 1, std430) restrict writeonly buffer ChannelOutput {
	float channel_out[];
};

layout(push_constant, std430) uniform Params {
	int voxel_count;     // byte 0
	int channel_index;   // byte 4
	int channel_stride;  // byte 8
	int pad0;            // byte 12
};

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= uint(max(voxel_count, 0))) {
		return;
	}
	if (channel_index < 0 || channel_stride <= 0 || channel_index >= channel_stride) {
		channel_out[idx] = 0.0;
		return;
	}

	uint src_idx = idx * uint(channel_stride) + uint(channel_index);
	channel_out[idx] = debug_voxel[src_idx];
}
