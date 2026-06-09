#[compute]
#version 450

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer CandidateRecords {
    // x: explicit priority, y: complexity, z: source type code, w: has explicit priority
    vec4 candidate_records[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer CandidateRanges {
    // per source key: (auto_start, auto_count, brush_start, brush_count)
    uvec4 candidate_ranges[];
};

layout(set = 0, binding = 2, std430) restrict readonly buffer CandidatePayloads {
    float candidate_payloads[];
};

layout(set = 0, binding = 3, std430) restrict buffer CommittedPayloadOutput {
    // output stride = 12 floats per source key (committed payload format)
    float committed_payload[];
};

layout(push_constant, std430) uniform Params {
    int source_key_count;
    int source_stride;
    int output_stride;
    int _pad0;
};

const float SOURCE_TYPE_AUTO = 1.0;
const float SOURCE_TYPE_BRUSH = 2.0;

// ── Candidate payload offsets (same as source stream) ──
const int SRC_COMPLEXITY = 0;
const int SRC_COLOR_R = 1;
const int SRC_COLOR_G = 2;
const int SRC_COLOR_B = 3;
const int SRC_HAS_SOURCE = 5;
const int SRC_AUTO_MIX = 6;
const int SRC_HAS_COLLISION = 7;
const int SRC_COLLISION_STRENGTH = 13;
const int SRC_COLLISION_LAYER_COUNT = 14;

// ── Committed payload offsets (output format) ──
const int OUT_COMPLEXITY = 0;
const int OUT_COLOR_R = 1;
const int OUT_COLOR_G = 2;
const int OUT_COLOR_B = 3;
const int OUT_COLOR_A = 4;
const int OUT_SOURCE_SELECTOR = 5;
const int OUT_AUTO_MIX = 6;
const int OUT_VALID = 7;
const int OUT_COLLISION_STRENGTH = 8;
const int OUT_COLLISION_LAYER_COUNT = 9;
const int OUT_HAS_COLLISION = 10;
const int OUT_RESERVED = 11;

const float SOURCE_NONE = 0.0;
const float SOURCE_AUTO_F = 1.0;
const float SOURCE_BRUSH_F = 2.0;

// ── Priority helpers ──
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

// ── Winner resolution: iterate candidates in [start, start+count), return winner index or ~0u ──
uint resolve_winner(uint range_start, uint range_count) {
    if (range_count == 0u) {
        return 0xFFFFFFFFu;
    }
    uint winner_index = range_start;
    vec4 winner_record = candidate_records[winner_index];
    for (uint i = 1u; i < range_count; i++) {
        uint candidate_index = range_start + i;
        vec4 candidate_record = candidate_records[candidate_index];
        if (candidate_beats_current(candidate_record, winner_record)) {
            winner_index = candidate_index;
            winner_record = candidate_record;
        }
    }
    return winner_index;
}

// ── Write committed payload slots ──

void write_collision_empty(uint out_base) {
    committed_payload[out_base + OUT_COLLISION_STRENGTH] = 0.0;
    committed_payload[out_base + OUT_COLLISION_LAYER_COUNT] = 0.0;
    committed_payload[out_base + OUT_HAS_COLLISION] = 0.0;
    committed_payload[out_base + OUT_RESERVED] = 0.0;
}

void write_collision_from_payload(uint payload_base, uint out_base) {
    float has_collision = candidate_payloads[payload_base + SRC_HAS_COLLISION] > 0.5 ? 1.0 : 0.0;
    committed_payload[out_base + OUT_COLLISION_STRENGTH] = has_collision * clamp(candidate_payloads[payload_base + SRC_COLLISION_STRENGTH], 0.0, 1.0);
    committed_payload[out_base + OUT_COLLISION_LAYER_COUNT] = has_collision * max(candidate_payloads[payload_base + SRC_COLLISION_LAYER_COUNT], 0.0);
    committed_payload[out_base + OUT_HAS_COLLISION] = has_collision;
    committed_payload[out_base + OUT_RESERVED] = 0.0;
}

void write_empty(uint out_base) {
    committed_payload[out_base + OUT_COMPLEXITY] = 0.0;
    committed_payload[out_base + OUT_COLOR_R] = 0.0;
    committed_payload[out_base + OUT_COLOR_G] = 0.0;
    committed_payload[out_base + OUT_COLOR_B] = 0.0;
    committed_payload[out_base + OUT_COLOR_A] = 0.0;
    committed_payload[out_base + OUT_SOURCE_SELECTOR] = SOURCE_NONE;
    committed_payload[out_base + OUT_AUTO_MIX] = 0.0;
    committed_payload[out_base + OUT_VALID] = 0.0;
    write_collision_empty(out_base);
}

void write_from_payload(uint payload_base, float source_selector, float auto_mix, uint out_base) {
    float complexity = clamp(candidate_payloads[payload_base + SRC_COMPLEXITY], 0.0, 1.0);
    committed_payload[out_base + OUT_COMPLEXITY] = complexity;
    committed_payload[out_base + OUT_COLOR_R] = clamp(candidate_payloads[payload_base + SRC_COLOR_R], 0.0, 1.0);
    committed_payload[out_base + OUT_COLOR_G] = clamp(candidate_payloads[payload_base + SRC_COLOR_G], 0.0, 1.0);
    committed_payload[out_base + OUT_COLOR_B] = clamp(candidate_payloads[payload_base + SRC_COLOR_B], 0.0, 1.0);
    committed_payload[out_base + OUT_COLOR_A] = complexity;
    committed_payload[out_base + OUT_SOURCE_SELECTOR] = source_selector;
    committed_payload[out_base + OUT_AUTO_MIX] = clamp(auto_mix, 0.0, 1.0);
    committed_payload[out_base + OUT_VALID] = 1.0;
    write_collision_from_payload(payload_base, out_base);
}

void write_mixed(uint auto_payload_base, uint brush_payload_base, uint out_base, float mix_ratio) {
    float auto_complexity = clamp(candidate_payloads[auto_payload_base + SRC_COMPLEXITY], 0.0, 1.0);
    float brush_complexity = clamp(candidate_payloads[brush_payload_base + SRC_COMPLEXITY], 0.0, 1.0);
    float final_complexity = mix(brush_complexity, auto_complexity, mix_ratio);

    committed_payload[out_base + OUT_COMPLEXITY] = final_complexity;
    committed_payload[out_base + OUT_COLOR_R] = mix(
        clamp(candidate_payloads[brush_payload_base + SRC_COLOR_R], 0.0, 1.0),
        clamp(candidate_payloads[auto_payload_base + SRC_COLOR_R], 0.0, 1.0),
        mix_ratio
    );
    committed_payload[out_base + OUT_COLOR_G] = mix(
        clamp(candidate_payloads[brush_payload_base + SRC_COLOR_G], 0.0, 1.0),
        clamp(candidate_payloads[auto_payload_base + SRC_COLOR_G], 0.0, 1.0),
        mix_ratio
    );
    committed_payload[out_base + OUT_COLOR_B] = mix(
        clamp(candidate_payloads[brush_payload_base + SRC_COLOR_B], 0.0, 1.0),
        clamp(candidate_payloads[auto_payload_base + SRC_COLOR_B], 0.0, 1.0),
        mix_ratio
    );
    committed_payload[out_base + OUT_COLOR_A] = final_complexity;
    committed_payload[out_base + OUT_SOURCE_SELECTOR] = SOURCE_BRUSH_F;
    committed_payload[out_base + OUT_AUTO_MIX] = mix_ratio;
    committed_payload[out_base + OUT_VALID] = 1.0;
    // Collision from brush (brush wins for collision in mixed case)
    write_collision_from_payload(brush_payload_base, out_base);
}

// ── Main: per source key, resolve auto+brush winners and blend ──
void main() {
    if (source_key_count <= 0) {
        return;
    }

    uint key_idx = gl_GlobalInvocationID.x;
    if (key_idx >= uint(source_key_count)) {
        return;
    }

    uint out_base = key_idx * uint(output_stride);
    uvec4 range = candidate_ranges[key_idx];

    uint auto_start = range.x;
    uint auto_count = range.y;
    uint brush_start = range.z;
    uint brush_count = range.w;

    uint auto_winner = resolve_winner(auto_start, auto_count);
    uint brush_winner = resolve_winner(brush_start, brush_count);

    bool has_auto = (auto_winner != 0xFFFFFFFFu);
    bool has_brush = (brush_winner != 0xFFFFFFFFu);

    if (!has_auto && !has_brush) {
        write_empty(out_base);
        return;
    }

    uint src_stride = uint(source_stride);

    if (!has_auto) {
        uint brush_payload_base = brush_winner * src_stride;
        write_from_payload(brush_payload_base, SOURCE_BRUSH_F, 0.0, out_base);
        return;
    }

    if (!has_brush) {
        uint auto_payload_base = auto_winner * src_stride;
        write_from_payload(auto_payload_base, SOURCE_AUTO_F, 1.0, out_base);
        return;
    }

    // Both auto and brush exist: blend based on auto_mix from brush
    uint auto_payload_base = auto_winner * src_stride;
    uint brush_payload_base = brush_winner * src_stride;
    float auto_mix = clamp(candidate_payloads[brush_payload_base + SRC_AUTO_MIX], 0.0, 1.0);

    if (auto_mix <= 0.0) {
        write_from_payload(brush_payload_base, SOURCE_BRUSH_F, 0.0, out_base);
    } else if (auto_mix >= 1.0) {
        write_from_payload(auto_payload_base, SOURCE_AUTO_F, 1.0, out_base);
    } else {
        write_mixed(auto_payload_base, brush_payload_base, out_base, auto_mix);
    }
}
