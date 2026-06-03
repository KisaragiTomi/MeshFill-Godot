#[compute]
#version 450

// Bake one box/cube collision record into placement footprint buffers.
// Output layout matches VoxelPlacementGenerator._pack_footprint:
//   set 0 binding 0: ivec4 pos_strength[] = (local_x, local_y, local_z, collision_q8)
//   set 0 binding 1: vec4 weight_flags[] = (weight, flags, radius, pad)
// Dispatch is 1D with local_size_x=64. Invocation IDs >= write_count are ignored.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict writeonly buffer FootprintPos {
	ivec4 pos_strength[];
};

layout(set = 0, binding = 1, std430) restrict writeonly buffer FootprintWeight {
	vec4 weight_flags[];
};

layout(push_constant, std430) uniform Params {
	ivec4 solid_min_count;          // min x/y/z, full solid voxel count
	ivec4 solid_dims_support;       // dims x/y/z, add_support
	ivec4 clearance_min_count;      // min x/y/z, full clearance voxel count
	ivec4 clearance_dims_capacity;  // dims x/y/z, write_count capped to footprint capacity
	vec4 strength_weight;           // collision_strength, solid_weight, clearance_weight, pad
} params;

const int FLAG_SUPPORT = 1;
const int FLAG_CLEARANCE = 2;

ivec3 decode_local(int linear_index, ivec3 dims) {
	int safe_x = max(dims.x, 1);
	int safe_z = max(dims.z, 1);
	int x = linear_index % safe_x;
	int z = (linear_index / safe_x) % safe_z;
	int y = linear_index / (safe_x * safe_z);
	return ivec3(x, y, z);
}

void main() {
	uint global_index = gl_GlobalInvocationID.x;
	uint write_count = uint(max(params.clearance_dims_capacity.w, 0));
	if (global_index >= write_count) {
		return;
	}

	int solid_count = max(params.solid_min_count.w, 0);
	int index = int(global_index);
	ivec3 local_pos;
	ivec3 voxel_pos;
	int flags = 0;
	float collision_strength = clamp(params.strength_weight.x, 0.0, 1.0);
	float weight = params.strength_weight.y;

	if (index < solid_count) {
		local_pos = decode_local(index, params.solid_dims_support.xyz);
		voxel_pos = params.solid_min_count.xyz + local_pos;
		if (params.solid_dims_support.w != 0 && voxel_pos.y == params.solid_min_count.y) {
			flags |= FLAG_SUPPORT;
		}
	} else {
		int clearance_index = index - solid_count;
		local_pos = decode_local(clearance_index, params.clearance_dims_capacity.xyz);
		voxel_pos = params.clearance_min_count.xyz + local_pos;
		flags = FLAG_CLEARANCE;
		collision_strength = 0.0;
		weight = params.strength_weight.z;
	}

	int collision_q8 = int(round(collision_strength * 255.0));
	pos_strength[global_index] = ivec4(voxel_pos, clamp(collision_q8, 0, 255));
	weight_flags[global_index] = vec4(max(weight, 0.0), float(flags), 0.0, 0.0);
}
