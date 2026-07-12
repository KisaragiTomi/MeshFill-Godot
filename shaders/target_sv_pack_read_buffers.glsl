#[compute]
#version 450

// Derive TargetSV packed placement buffers from canonical 8bit read buffers.
// Inputs:
//   binding 0: rgba8 visual buffer packed as uint, high-to-low bytes RGBA
//   binding 1: r8 collision buffer packed four voxels per uint
//   binding 2: optional r8 completeness input buffer packed four voxels per uint
// Outputs:
//   binding 3: r8 completeness buffer packed four voxels per uint
//   binding 4: rgba8 packed as uint, high-to-low bytes RGBA
//   binding 5: u32 stats buffer (DebugBufferSet TARGET_STATS: magic + schema_version header, then named stat slots)

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer TargetVisual {
    uint target_visual_rgba8[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer TargetCollision {
    uint target_collision_r8_words[];
};

layout(set = 0, binding = 2, std430) restrict readonly buffer TargetCompletenessInput {
    uint target_completeness_input_r8_words[];
};

layout(set = 0, binding = 3, std430) restrict buffer TargetCompletenessOut {
    uint target_completeness_out_r8_words[];
};

layout(set = 0, binding = 4, std430) restrict writeonly buffer TargetVisualRgba8Out {
    uint target_visual_rgba8_out[];
};

// @@GEN debug_set target_stats
layout(set = 0, binding = 5, std430) restrict buffer TargetStats {
    uint target_stats[];
};
const uint TARGET_STATS_MAGIC = 0x4D465453u;
const uint TARGET_STATS_MAX_COMPLETENESS = 2u;
const uint TARGET_STATS_MAX_COLLISION = 3u;
const uint TARGET_STATS_ACTIVE_COUNT = 4u;
const uint TARGET_STATS_COLLISION_COUNT = 5u;
const uint TARGET_STATS_VISUAL_COUNT = 6u;
const uint TARGET_STATS_MIN_ACTIVE_PACKED = 7u;
const uint TARGET_STATS_MAX_VISUAL = 8u;
const uint TARGET_STATS_MIN_PACK_BASE = 1000001u;
const float TARGET_STATS_ACTIVE_THRESHOLD = 0.001;
// @@END debug_set target_stats

layout(push_constant, std430) uniform Params {
    int voxel_count;                 // byte 0: total voxels to scan
    int use_collision_as_completeness; // byte 4: use max(complexity, collision) as completeness when no completeness input exists
    int completeness_input_valid;      // byte 8: binding 2 has one r8 value per voxel
    int write_packed_buffers;        // byte 12: write bindings 3/4, disabled for stats-only dispatch
};

vec4 unpack_rgba8(uint packed) {
    return vec4(
        float((packed >> 24u) & 0xFFu) / 255.0,
        float((packed >> 16u) & 0xFFu) / 255.0,
        float((packed >>  8u) & 0xFFu) / 255.0,
        float((packed >>  0u) & 0xFFu) / 255.0
    );
}

float unpack_r8(uint packed_word, uint idx) {
    uint shift = (idx & 3u) * 8u;
    return float((packed_word >> shift) & 0xFFu) / 255.0;
}

float load_collision_r8(uint idx) {
    return unpack_r8(target_collision_r8_words[idx >> 2u], idx);
}

float load_completeness_input_r8(uint idx) {
    return unpack_r8(target_completeness_input_r8_words[idx >> 2u], idx);
}

uint pack_r8(float value) {
    return uint(clamp(round(value * 255.0), 0.0, 255.0));
}

void store_completeness_r8(uint idx, float value) {
    uint word_index = idx >> 2u;
    uint shift = (idx & 3u) * 8u;
    atomicOr(target_completeness_out_r8_words[word_index], pack_r8(value) << shift);
}

uint quantize_unit(float value) {
    return uint(clamp(round(value * 1000000.0), 0.0, 1000000.0));
}

void main() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= uint(voxel_count)) {
        return;
    }

    uint visual_word = target_visual_rgba8[idx];
    vec4 visual = unpack_rgba8(visual_word);
    float complexity = clamp(visual.a, 0.0, 1.0);
    float collision = clamp(load_collision_r8(idx), 0.0, 1.0);

    float completeness = complexity;
    if (completeness_input_valid != 0) {
        completeness = clamp(load_completeness_input_r8(idx), 0.0, 1.0);
    } else if (use_collision_as_completeness != 0) {
        completeness = max(complexity, collision);
    }

    if (write_packed_buffers != 0) {
        store_completeness_r8(idx, completeness);
        target_visual_rgba8_out[idx] = visual_word;
    }
    atomicMax(target_stats[TARGET_STATS_MAX_COMPLETENESS], quantize_unit(completeness));
    atomicMax(target_stats[TARGET_STATS_MAX_COLLISION], quantize_unit(collision));
    if (completeness > TARGET_STATS_ACTIVE_THRESHOLD) {
        atomicAdd(target_stats[TARGET_STATS_ACTIVE_COUNT], 1u);
        atomicMax(target_stats[TARGET_STATS_MIN_ACTIVE_PACKED], TARGET_STATS_MIN_PACK_BASE - quantize_unit(completeness));
    }
    if (collision > TARGET_STATS_ACTIVE_THRESHOLD) {
        atomicAdd(target_stats[TARGET_STATS_COLLISION_COUNT], 1u);
    }
    if (complexity > TARGET_STATS_ACTIVE_THRESHOLD) {
        atomicAdd(target_stats[TARGET_STATS_VISUAL_COUNT], 1u);
    }
    atomicMax(target_stats[TARGET_STATS_MAX_VISUAL], quantize_unit(complexity));
}
