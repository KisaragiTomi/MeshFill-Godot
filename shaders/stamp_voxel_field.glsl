#[compute]
#version 450

// Stamps accepted placement results into scene/collision field buffers.
// Output VoxelStampDeltaBuffer uses 2 vec4 records per footprint sample:
//   0: vec4(voxel.xyz, scene_value)
//   1: vec4(collision_value, result_index, footprint_index, wrote)

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer SceneField {
    float scene_field[];
};

layout(set = 0, binding = 1, std430) restrict buffer CollisionField {
    float collision_field[];
};

layout(set = 0, binding = 2, std430) restrict readonly buffer PlacementResults {
    vec4 placement_results[];
};

layout(set = 0, binding = 3, std430) restrict readonly buffer ResultCount {
    uint result_count;
};

layout(set = 0, binding = 4, std430) restrict readonly buffer FootprintPos {
    ivec4 footprint_pos_degree[];
};

layout(set = 0, binding = 5, std430) restrict readonly buffer FootprintWeight {
    vec4 footprint_weight_flags[];
};

layout(set = 0, binding = 6, std430) restrict buffer VoxelStampDelta {
    vec4 stamp_delta[];
};

layout(push_constant, std430) uniform Params {
    ivec4 grid_size_counts;  // grid x, y, z, footprint_count
    ivec4 write_min_pad;     // write min xyz
    ivec4 write_max_pad;     // write max xyz, exclusive
    vec4 params;             // solid_threshold, scene_write_scale, collision_write_scale, _pad
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

void main() {
    uint footprint_count = uint(max(grid_size_counts.w, 0));
    if (footprint_count == 0u) {
        return;
    }

    uint global_index = gl_GlobalInvocationID.x;
    uint result_index = global_index / footprint_count;
    uint footprint_index = global_index - result_index * footprint_count;
    uint delta_base = global_index * DELTA_STRIDE;

    stamp_delta[delta_base + 0u] = vec4(0.0);
    stamp_delta[delta_base + 1u] = vec4(0.0);

    if (result_index >= result_count) {
        return;
    }

    vec4 pose = placement_results[result_index * RECORD_STRIDE + 0u];
    if (pose.w < 0.0) {
        return;
    }

    ivec3 origin = ivec3(round(pose.xyz));
    ivec4 fp = footprint_pos_degree[footprint_index];
    vec4 wf = footprint_weight_flags[footprint_index];
    ivec3 p = origin + fp.xyz;

    if (!in_grid_bounds(p) || !in_write_bounds(p)) {
        return;
    }

    float weight = max(wf.x, 0.0);
    float degree = clamp(float(fp.w) / 255.0, 0.0, 1.0);
    float scene_value = clamp(weight * params.y, 0.0, 1.0);
    float collision_value = degree >= params.x ? clamp(degree * params.z, 0.0, 1.0) : 0.0;

    int index = voxel_index(p);
    scene_field[index] = max(scene_field[index], scene_value);
    if (collision_value > 0.0) {
        collision_field[index] = max(collision_field[index], collision_value);
    }

    stamp_delta[delta_base + 0u] = vec4(vec3(p), scene_value);
    stamp_delta[delta_base + 1u] = vec4(collision_value, float(result_index), float(footprint_index), 1.0);
}
