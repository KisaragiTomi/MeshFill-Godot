#[compute]
#version 450

// Stamps accepted placement results into complexity/collision field buffers.
// Output VoxelStampDeltaBuffer uses 2 vec4 records per footprint sample:
//   0: vec4(voxel.xyz, complexity)
//   1: vec4(collision_strength, result_index, footprint_index, wrote)
// Output VoxelStampBounds uses 2 uvec4 records per accepted placement:
//   0: uvec4(min_xyz, written_count)
//   1: uvec4(max_xyz_exclusive, reserved)

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer ComplexityField {
    vec4 complexity_field[];
};

layout(set = 0, binding = 1, std430) restrict buffer CollisionField {
    uint collision_field[];
};

layout(set = 0, binding = 2, std430) restrict readonly buffer PlacementResults {
    vec4 placement_results[];
};

layout(set = 0, binding = 3, std430) restrict readonly buffer ResultCount {
    uint result_count;
};

layout(set = 0, binding = 4, std430) restrict readonly buffer FootprintPos {
    ivec4 footprint_pos_strength[];
};

layout(set = 0, binding = 5, std430) restrict readonly buffer FootprintWeight {
    vec4 footprint_weight_flags[];
};

layout(set = 0, binding = 6, std430) restrict buffer VoxelStampDelta {
    vec4 stamp_delta[];
};

layout(set = 0, binding = 7, std430) restrict buffer VoxelStampDeltaCount {
    uint stamp_delta_count;
};

layout(set = 0, binding = 8, std430) restrict buffer VoxelStampBounds {
    uvec4 stamp_bounds[];
};

layout(push_constant, std430) uniform Params {
    ivec4 grid_size_counts;  // grid x, y, z, footprint_count
    ivec4 write_min_pad;     // write min xyz
    ivec4 write_max_pad;     // write max xyz, exclusive
    vec4 params;             // solid_threshold, complexity_write_scale, collision_write_scale, _pad
    vec4 stamp_color;        // RGB = asset color, A = unused
};

const uint RECORD_STRIDE = 4u;
const uint DELTA_STRIDE = 2u;

bool in_grid_bounds(ivec3 p) {
    return p.x >= 0 && p.y >= 0 && p.z >= 0
        && p.x < grid_size_counts.x
        && p.y < grid_size_counts.y
        && p.z < grid_size_counts.z;
}

bool in_write_bounds(ivec3 p) {
    return p.x >= write_min_pad.x && p.y >= write_min_pad.y && p.z >= write_min_pad.z
        && p.x < write_max_pad.x && p.y < write_max_pad.y && p.z < write_max_pad.z;
}

int voxel_index(ivec3 p) {
    return p.x + grid_size_counts.x * (p.z + grid_size_counts.z * p.y);
}

void atomic_max_float_nonnegative_collision(int index, float value) {
    uint new_bits = floatBitsToUint(max(value, 0.0));
    uint old_bits = collision_field[index];
    while (uintBitsToFloat(old_bits) < value) {
        uint previous_bits = atomicCompSwap(collision_field[index], old_bits, new_bits);
        if (previous_bits == old_bits) {
            return;
        }
        old_bits = previous_bits;
    }
}

void write_stamp_bounds(uint result_index, ivec3 p) {
    uint base = result_index * 2u;
    atomicMin(stamp_bounds[base + 0u].x, uint(p.x));
    atomicMin(stamp_bounds[base + 0u].y, uint(p.y));
    atomicMin(stamp_bounds[base + 0u].z, uint(p.z));
    atomicAdd(stamp_bounds[base + 0u].w, 1u);
    atomicMax(stamp_bounds[base + 1u].x, uint(p.x + 1));
    atomicMax(stamp_bounds[base + 1u].y, uint(p.y + 1));
    atomicMax(stamp_bounds[base + 1u].z, uint(p.z + 1));
}

void main() {
    uint footprint_count = uint(max(grid_size_counts.w, 0));
    if (footprint_count == 0u) {
        return;
    }

    uint global_index = gl_GlobalInvocationID.x;
    uint result_index = global_index / footprint_count;
    uint footprint_index = global_index - result_index * footprint_count;

    if (result_index >= result_count) {
        return;
    }

    vec4 pose = placement_results[result_index * RECORD_STRIDE + 0u];
    if (pose.w < 0.0) {
        return;
    }

    ivec3 origin = ivec3(round(pose.xyz));
    ivec4 fp = footprint_pos_strength[footprint_index];
    vec4 wf = footprint_weight_flags[footprint_index];
    ivec3 p = origin + fp.xyz;

    if (!in_grid_bounds(p) || !in_write_bounds(p)) {
        return;
    }

    float weight = max(wf.x, 0.0);
    float footprint_collision_strength = clamp(float(fp.w) / 255.0, 0.0, 1.0);
    float complexity = clamp(weight * params.y, 0.0, 1.0);
    float collision_strength = footprint_collision_strength >= params.x ? clamp(footprint_collision_strength * params.z, 0.0, 1.0) : 0.0;

    int index = voxel_index(p);
    complexity_field[index] = vec4(stamp_color.rgb, complexity);
    if (collision_strength > 0.0) {
        atomic_max_float_nonnegative_collision(index, collision_strength);
    }

    uint compact_index = atomicAdd(stamp_delta_count, 1u);
    uint delta_base = compact_index * DELTA_STRIDE;
    stamp_delta[delta_base + 0u] = vec4(vec3(p), complexity);
    stamp_delta[delta_base + 1u] = vec4(collision_strength, float(result_index), float(footprint_index), 1.0);
    write_stamp_bounds(result_index, p);
}
