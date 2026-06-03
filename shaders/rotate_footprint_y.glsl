#[compute]
#version 450

// Rotate a packed CollisionVoxel placement footprint around the local Y axis.
// Binding order must match VoxelPlacementGenerator._rotate_footprint_y_gpu:
//   set 0 binding 0: readonly ivec4 pos_strength_in[] = (local_x, local_y, local_z, collision_q8), stride 16 bytes.
//   set 0 binding 1: readonly vec4 weight_flags_in[] = (weight, flags, radius, pad), stride 16 bytes.
//   set 0 binding 2: writeonly ivec4 pos_strength_out[] with the same layout.
//   set 0 binding 3: writeonly vec4 weight_flags_out[] with the same layout.
// Dispatch is 1D with local_size_x=64; invocation IDs >= footprint_count are ignored.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer FootprintPosIn {
	ivec4 pos_strength_in[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer FootprintWeightIn {
	vec4 weight_flags_in[];
};

layout(set = 0, binding = 2, std430) restrict writeonly buffer FootprintPosOut {
	ivec4 pos_strength_out[];
};

layout(set = 0, binding = 3, std430) restrict writeonly buffer FootprintWeightOut {
	vec4 weight_flags_out[];
};

layout(push_constant, std430) uniform Params {
	int footprint_count;
	float cos_y;
	float sin_y;
	float _pad0;
} params;

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= uint(max(params.footprint_count, 0))) {
		return;
	}

	ivec4 src = pos_strength_in[idx];
	float rx = float(src.x) * params.cos_y - float(src.z) * params.sin_y;
	float rz = float(src.x) * params.sin_y + float(src.z) * params.cos_y;
	int collision_q8 = clamp(src.w, 0, 255);

	pos_strength_out[idx] = ivec4(int(round(rx)), src.y, int(round(rz)), collision_q8);
	weight_flags_out[idx] = weight_flags_in[idx];
}
