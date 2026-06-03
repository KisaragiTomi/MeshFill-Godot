#[compute]
#version 450

// Bake one cylinder collision record into placement footprint buffers.
// Binding order must match VoxelPlacementGenerator._bake_cylinder_footprint_gpu:
//   set 0 binding 0: ivec4 pos_strength[] = (local_x, local_y, local_z, collision_q8)
//   set 0 binding 1: vec4 weight_flags[] = (weight, flags, radius, pad)
//   set 0 binding 2: uint stats[1], total valid cylinder samples before capacity truncation
//
// Candidate layout is 1D over solid layers first, then clearance layers:
//   x is fastest, then z, then y. Edge guards skip dispatch IDs outside
//   candidate_count, samples outside radius_sq, and writes past output_capacity.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict writeonly buffer FootprintPos {
	ivec4 pos_strength[];
};

layout(set = 0, binding = 1, std430) restrict writeonly buffer FootprintWeight {
	vec4 weight_flags[];
};

layout(set = 0, binding = 2, std430) coherent buffer FootprintStats {
	uint valid_count;
};

layout(push_constant, std430) uniform Params {
	ivec4 center_radius;      // center_x, center_z, radius_vox_x, radius_vox_z
	ivec4 y_counts;           // y_min, solid_y_count, clearance_y_min, clearance_slices
	ivec4 candidate_counts;   // x_count, z_count, solid_candidate_count, candidate_count
	ivec4 options;            // output_capacity, add_support, pad, pad
	vec4 metrics;             // voxel_size_x, voxel_size_z, radius_sq, collision_strength
	vec4 weights;             // solid_weight, clearance_weight, pad, pad
} params;

const int FLAG_SUPPORT = 1;
const int FLAG_CLEARANCE = 2;

void main() {
	uint global_index = gl_GlobalInvocationID.x;
	uint candidate_count = uint(max(params.candidate_counts.w, 0));
	if (global_index >= candidate_count) {
		return;
	}

	int x_count = max(params.candidate_counts.x, 1);
	int z_count = max(params.candidate_counts.y, 1);
	int plane_count = x_count * z_count;
	int solid_candidate_count = max(params.candidate_counts.z, 0);
	int index = int(global_index);
	bool solid = index < solid_candidate_count;
	int local_index = solid ? index : index - solid_candidate_count;
	int y_offset = local_index / plane_count;
	int plane_index = local_index - y_offset * plane_count;
	int x = (plane_index % x_count) - params.center_radius.z;
	int z = (plane_index / x_count) - params.center_radius.w;

	float wx = float(x) * params.metrics.x;
	float wz = float(z) * params.metrics.y;
	if (wx * wx + wz * wz > params.metrics.z) {
		return;
	}

	uint slot = atomicAdd(valid_count, 1u);
	uint output_capacity = uint(max(params.options.x, 0));
	if (slot >= output_capacity) {
		return;
	}

	int y = solid ? params.y_counts.x + y_offset : params.y_counts.z + y_offset;
	ivec3 voxel_pos = ivec3(params.center_radius.x + x, y, params.center_radius.y + z);
	float collision_strength = solid ? clamp(params.metrics.w, 0.0, 1.0) : 0.0;
	float weight = solid ? params.weights.x : params.weights.y;
	int flags = 0;
	if (solid) {
		if (params.options.y != 0 && y_offset == 0) {
			flags |= FLAG_SUPPORT;
		}
	} else {
		flags = FLAG_CLEARANCE;
	}

	int collision_q8 = int(round(collision_strength * 255.0));
	pos_strength[slot] = ivec4(voxel_pos, clamp(collision_q8, 0, 255));
	weight_flags[slot] = vec4(max(weight, 0.0), float(flags), 0.0, 0.0);
}
