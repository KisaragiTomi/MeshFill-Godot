#[compute]
#version 450

// Derive TargetSV packed placement buffers from persisted readback buffers.
// Inputs:
//   binding 0: rgba32f visual buffer, vec4(color.rgb, complexity)
//   binding 1: r32f collision buffer
//   binding 2: optional r32f occupancy input buffer
// Outputs:
//   binding 3: r32f occupancy buffer
//   binding 4: rgba8 packed as uint, high-to-low bytes RGBA
//   binding 5: u32 stats buffer: max occupancy, max collision, active/collision/visual voxel counts, min active occupancy, max visual complexity
//   binding 6: rgba32f color decode buffer, vec4(color.rgb, complexity), stride 16 bytes

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer TargetVisual {
    vec4 target_visual[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer TargetCollision {
    float target_collision[];
};

layout(set = 0, binding = 2, std430) restrict readonly buffer TargetOccupancyInput {
    float target_occupancy_input[];
};

layout(set = 0, binding = 3, std430) restrict writeonly buffer TargetOccupancyOut {
    float target_occupancy_out[];
};

layout(set = 0, binding = 4, std430) restrict writeonly buffer TargetColorRgba8Out {
    uint target_color_rgba8_out[];
};

layout(set = 0, binding = 5, std430) restrict buffer TargetStatsOut {
    uint target_stats_out[];
};

layout(set = 0, binding = 6, std430) restrict writeonly buffer TargetColorRgba32fOut {
    vec4 target_color_rgba32f_out[];
};

const uint TARGET_STATS_MAX_OCCUPANCY = 0u;
const uint TARGET_STATS_MAX_COLLISION = 1u;
const uint TARGET_STATS_ACTIVE_COUNT = 2u;
const uint TARGET_STATS_COLLISION_COUNT = 3u;
const uint TARGET_STATS_VISUAL_COUNT = 4u;
const uint TARGET_STATS_MIN_ACTIVE_PACKED = 5u;
const uint TARGET_STATS_MAX_VISUAL = 6u;
const uint TARGET_STATS_MIN_PACK_BASE = 1000001u;
const float TARGET_STATS_ACTIVE_THRESHOLD = 0.001;

layout(push_constant, std430) uniform Params {
    int voxel_count;                 // byte 0: total voxels to scan
    int use_collision_as_occupancy;  // byte 4: max(complexity, collision) when no occupancy input exists
    int occupancy_input_valid;       // byte 8: binding 2 has one r32f per voxel
    int write_packed_buffers;        // byte 12: write bindings 3/4, disabled for stats-only dispatch
};

uint pack_rgba8(vec4 color) {
    uvec4 bytes = uvec4(clamp(round(color * 255.0), vec4(0.0), vec4(255.0)));
    return (bytes.r << 24u) | (bytes.g << 16u) | (bytes.b << 8u) | bytes.a;
}

uint quantize_unit(float value) {
    return uint(clamp(round(value * 1000000.0), 0.0, 1000000.0));
}

void main() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= uint(voxel_count)) {
        return;
    }

    vec4 visual = target_visual[idx];
    vec3 color = clamp(visual.rgb, vec3(0.0), vec3(1.0));
    float complexity = clamp(visual.a, 0.0, 1.0);
    float collision = clamp(target_collision[idx], 0.0, 1.0);

    float occupancy = complexity;
    if (occupancy_input_valid != 0) {
        occupancy = clamp(target_occupancy_input[idx], 0.0, 1.0);
    } else if (use_collision_as_occupancy != 0) {
        occupancy = max(complexity, collision);
    }

    if (write_packed_buffers != 0) {
        target_occupancy_out[idx] = occupancy;
        target_color_rgba8_out[idx] = pack_rgba8(vec4(color, complexity));
        target_color_rgba32f_out[idx] = vec4(color, complexity);
    }
    atomicMax(target_stats_out[TARGET_STATS_MAX_OCCUPANCY], quantize_unit(occupancy));
    atomicMax(target_stats_out[TARGET_STATS_MAX_COLLISION], quantize_unit(collision));
    if (occupancy > TARGET_STATS_ACTIVE_THRESHOLD) {
        atomicAdd(target_stats_out[TARGET_STATS_ACTIVE_COUNT], 1u);
        atomicMax(target_stats_out[TARGET_STATS_MIN_ACTIVE_PACKED], TARGET_STATS_MIN_PACK_BASE - quantize_unit(occupancy));
    }
    if (collision > TARGET_STATS_ACTIVE_THRESHOLD) {
        atomicAdd(target_stats_out[TARGET_STATS_COLLISION_COUNT], 1u);
    }
    if (complexity > TARGET_STATS_ACTIVE_THRESHOLD) {
        atomicAdd(target_stats_out[TARGET_STATS_VISUAL_COUNT], 1u);
    }
    atomicMax(target_stats_out[TARGET_STATS_MAX_VISUAL], quantize_unit(complexity));
}
