#[compute]
#version 450

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer AutoSource {
    float auto_source[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer BrushSource {
    float brush_source[];
};

layout(set = 0, binding = 2, std430) restrict writeonly buffer OutputPayload {
    float out_payload[];
};

layout(push_constant, std430) uniform Params {
    int key_count;
    int source_stride;
    int output_stride;
    int _pad0;
};

const int SRC_COMPLEXITY = 0;
const int SRC_COLOR_R = 1;
const int SRC_COLOR_G = 2;
const int SRC_COLOR_B = 3;
const int SRC_HAS_SOURCE = 5;
const int SRC_AUTO_MIX = 6;

const int OUT_COMPLEXITY = 0;
const int OUT_COLOR_R = 1;
const int OUT_COLOR_G = 2;
const int OUT_COLOR_B = 3;
const int OUT_COLOR_A = 4;
const int OUT_SOURCE_SELECTOR = 5;
const int OUT_AUTO_MIX = 6;
const int OUT_VALID = 7;

const float SOURCE_NONE = 0.0;
const float SOURCE_AUTO = 1.0;
const float SOURCE_BRUSH = 2.0;

void write_empty(uint out_base) {
    out_payload[out_base + OUT_COMPLEXITY] = 0.0;
    out_payload[out_base + OUT_COLOR_R] = 0.0;
    out_payload[out_base + OUT_COLOR_G] = 0.0;
    out_payload[out_base + OUT_COLOR_B] = 0.0;
    out_payload[out_base + OUT_COLOR_A] = 0.0;
    out_payload[out_base + OUT_SOURCE_SELECTOR] = SOURCE_NONE;
    out_payload[out_base + OUT_AUTO_MIX] = 0.0;
    out_payload[out_base + OUT_VALID] = 0.0;
}

void write_from_auto(uint auto_base, uint out_base) {
    float complexity = clamp(auto_source[auto_base + SRC_COMPLEXITY], 0.0, 1.0);
    out_payload[out_base + OUT_COMPLEXITY] = complexity;
    out_payload[out_base + OUT_COLOR_R] = clamp(auto_source[auto_base + SRC_COLOR_R], 0.0, 1.0);
    out_payload[out_base + OUT_COLOR_G] = clamp(auto_source[auto_base + SRC_COLOR_G], 0.0, 1.0);
    out_payload[out_base + OUT_COLOR_B] = clamp(auto_source[auto_base + SRC_COLOR_B], 0.0, 1.0);
    out_payload[out_base + OUT_COLOR_A] = complexity;
    out_payload[out_base + OUT_SOURCE_SELECTOR] = SOURCE_AUTO;
    out_payload[out_base + OUT_AUTO_MIX] = 1.0;
    out_payload[out_base + OUT_VALID] = 1.0;
}

void write_from_brush(uint brush_base, uint out_base, float auto_mix_out) {
    float complexity = clamp(brush_source[brush_base + SRC_COMPLEXITY], 0.0, 1.0);
    out_payload[out_base + OUT_COMPLEXITY] = complexity;
    out_payload[out_base + OUT_COLOR_R] = clamp(brush_source[brush_base + SRC_COLOR_R], 0.0, 1.0);
    out_payload[out_base + OUT_COLOR_G] = clamp(brush_source[brush_base + SRC_COLOR_G], 0.0, 1.0);
    out_payload[out_base + OUT_COLOR_B] = clamp(brush_source[brush_base + SRC_COLOR_B], 0.0, 1.0);
    out_payload[out_base + OUT_COLOR_A] = complexity;
    out_payload[out_base + OUT_SOURCE_SELECTOR] = SOURCE_BRUSH;
    out_payload[out_base + OUT_AUTO_MIX] = clamp(auto_mix_out, 0.0, 1.0);
    out_payload[out_base + OUT_VALID] = 1.0;
}

void write_mixed(uint auto_base, uint brush_base, uint out_base, float auto_mix) {
    float mix_ratio = clamp(auto_mix, 0.0, 1.0);
    float brush_complexity = clamp(brush_source[brush_base + SRC_COMPLEXITY], 0.0, 1.0);
    float auto_complexity = clamp(auto_source[auto_base + SRC_COMPLEXITY], 0.0, 1.0);
    float final_complexity = mix(brush_complexity, auto_complexity, mix_ratio);

    out_payload[out_base + OUT_COMPLEXITY] = final_complexity;
    out_payload[out_base + OUT_COLOR_R] = mix(
        clamp(brush_source[brush_base + SRC_COLOR_R], 0.0, 1.0),
        clamp(auto_source[auto_base + SRC_COLOR_R], 0.0, 1.0),
        mix_ratio
    );
    out_payload[out_base + OUT_COLOR_G] = mix(
        clamp(brush_source[brush_base + SRC_COLOR_G], 0.0, 1.0),
        clamp(auto_source[auto_base + SRC_COLOR_G], 0.0, 1.0),
        mix_ratio
    );
    out_payload[out_base + OUT_COLOR_B] = mix(
        clamp(brush_source[brush_base + SRC_COLOR_B], 0.0, 1.0),
        clamp(auto_source[auto_base + SRC_COLOR_B], 0.0, 1.0),
        mix_ratio
    );
    out_payload[out_base + OUT_COLOR_A] = final_complexity;
    out_payload[out_base + OUT_SOURCE_SELECTOR] = SOURCE_BRUSH;
    out_payload[out_base + OUT_AUTO_MIX] = mix_ratio;
    out_payload[out_base + OUT_VALID] = 1.0;
}

void main() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= uint(key_count)) {
        return;
    }

    uint auto_base = idx * uint(source_stride);
    uint brush_base = idx * uint(source_stride);
    uint out_base = idx * uint(output_stride);
    bool has_auto = auto_source[auto_base + SRC_HAS_SOURCE] > 0.5;
    bool has_brush = brush_source[brush_base + SRC_HAS_SOURCE] > 0.5;

    if (!has_auto && !has_brush) {
        write_empty(out_base);
        return;
    }
    if (!has_auto) {
        write_from_brush(brush_base, out_base, 0.0);
        return;
    }
    if (!has_brush) {
        write_from_auto(auto_base, out_base);
        return;
    }

    float auto_mix = clamp(brush_source[brush_base + SRC_AUTO_MIX], 0.0, 1.0);
    if (auto_mix <= 0.0) {
        write_from_brush(brush_base, out_base, 0.0);
        return;
    }
    if (auto_mix >= 1.0) {
        write_from_auto(auto_base, out_base);
        return;
    }

    write_mixed(auto_base, brush_base, out_base, auto_mix);
}
