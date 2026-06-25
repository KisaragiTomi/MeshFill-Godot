#[compute]
#version 450

// Pass B: Reduce per-sample-group partial scores into per-anchor best rotation.
//
// One workgroup per anchor. First ROTATION_SLOTS threads each sum sample groups
// partial scores for their rotation slot, then thread 0 picks the best.
//
// Dispatch: (anchor_count, 1, 1)
//
// Output: result_buffer with RESULT_STRIDE vec4 records per anchor.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer PartialScores {
    float partial_scores[];
};

layout(set = 0, binding = 1, std430) restrict writeonly buffer ResultBuffer {
    vec4 result_buffer[];
};

layout(push_constant, std430) uniform Params {
    ivec4 config;
};

const uint RESULT_STRIDE = 2u;

shared float s_slot_scores[64];

void main() {
    uint lid = gl_LocalInvocationIndex;
    uint anchor_id = gl_WorkGroupID.x;

    int sample_group_count = config.y;
    int rot = config.z;

    float slot_score = 0.0;

    if (lid < uint(rot)) {
        for (int group_id = 0; group_id < sample_group_count; group_id++) {
            uint idx = anchor_id * uint(sample_group_count) * uint(rot)
                     + uint(group_id) * uint(rot) + lid;
            slot_score += partial_scores[idx];
        }
    }

    s_slot_scores[lid] = slot_score;
    barrier();

    if (lid == 0u) {
        float best_score = -1.0;
        int best_slot = 0;
        for (int s = 0; s < rot; s++) {
            if (s_slot_scores[s] > best_score) {
                best_score = s_slot_scores[s];
                best_slot = s;
            }
        }

        float yaw_step = 360.0 / float(rot);
        float valid = best_score > 0.0 ? 1.0 : 0.0;

        uint rb = anchor_id * RESULT_STRIDE;
        result_buffer[rb]      = vec4(best_score, float(best_slot),
                                      float(best_slot) * yaw_step, valid);
        result_buffer[rb + 1u] = vec4(s_slot_scores[0], s_slot_scores[1],
                                      s_slot_scores[2], s_slot_scores[3]);
    }
}
