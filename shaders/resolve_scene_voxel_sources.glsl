#[compute]
#version 450

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer CandidateRecords {
    // x: explicit priority, y: complexity, z: source type code, w: has explicit priority
    vec4 candidate_records[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer CandidateRanges {
    uvec2 candidate_ranges[];
};

layout(set = 0, binding = 2, std430) restrict writeonly buffer WinnerIndices {
    uint winner_indices[];
};

layout(set = 0, binding = 3, std430) restrict readonly buffer CandidatePayloads {
    float candidate_payloads[];
};

layout(set = 0, binding = 4, std430) restrict readonly buffer GroupSourceKeyIndices {
    uint group_source_key_indices[];
};

layout(set = 0, binding = 5, std430) restrict buffer AutoSourceOutput {
    float auto_source_output[];
};

layout(set = 0, binding = 6, std430) restrict buffer BrushSourceOutput {
    float brush_source_output[];
};

layout(push_constant, std430) uniform Params {
    int group_count;
    int source_stride;
    int source_key_count;
    int _pad2;
};

const float SOURCE_TYPE_AUTO = 1.0;
const float SOURCE_TYPE_BRUSH = 2.0;

float candidate_priority(vec4 candidate) {
    if (candidate.w > 0.5) {
        return candidate.x;
    }
    return int(candidate.z + 0.5) == int(SOURCE_TYPE_BRUSH) ? 100.0 : 10.0;
}

bool candidate_beats_current(vec4 candidate, vec4 current) {
    float candidate_p = candidate_priority(candidate);
    float current_p = candidate_priority(current);
    if (candidate_p > current_p) {
        return true;
    }
    if (candidate_p < current_p) {
        return false;
    }
    return candidate.y >= current.y;
}

void copy_winner_payload(uint winner_index, uint source_key_index, float source_type) {
    if (source_stride <= 0 || source_key_index >= uint(source_key_count)) {
        return;
    }

    uint stride = uint(source_stride);
    uint source_base = winner_index * stride;
    uint out_base = source_key_index * stride;
    if (int(source_type + 0.5) == int(SOURCE_TYPE_BRUSH)) {
        for (uint i = 0u; i < stride; i++) {
            brush_source_output[out_base + i] = candidate_payloads[source_base + i];
        }
    } else if (int(source_type + 0.5) == int(SOURCE_TYPE_AUTO)) {
        for (uint i = 0u; i < stride; i++) {
            auto_source_output[out_base + i] = candidate_payloads[source_base + i];
        }
    }
}

void main() {
    uint group_id = gl_GlobalInvocationID.x;
    if (group_id >= uint(group_count)) {
        return;
    }

    uvec2 range = candidate_ranges[group_id];
    if (range.y == 0u) {
        winner_indices[group_id] = 0xFFFFFFFFu;
        return;
    }

    uint winner_index = range.x;
    vec4 winner_record = candidate_records[winner_index];
    for (uint i = 1u; i < range.y; i++) {
        uint candidate_index = range.x + i;
        vec4 candidate_record = candidate_records[candidate_index];
        if (candidate_beats_current(candidate_record, winner_record)) {
            winner_index = candidate_index;
            winner_record = candidate_record;
        }
    }

    winner_indices[group_id] = winner_index;
    copy_winner_payload(winner_index, group_source_key_indices[group_id], winner_record.z);
}
