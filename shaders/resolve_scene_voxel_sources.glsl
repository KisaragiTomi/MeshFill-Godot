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

layout(push_constant, std430) uniform Params {
    int group_count;
    int _pad0;
    int _pad1;
    int _pad2;
};

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
}
