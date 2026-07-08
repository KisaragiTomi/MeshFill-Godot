#[compute]
#version 450

// Result-level feedback pass: compares a transient BlendSV field pair against
// the TargetSV_B read buffers. One thread per voxel; accumulates quantized
// stats via atomicAdd. completely = max(complexity alpha, collision).
//
// Stats layout (uint):
//   0: blend occupied voxel count
//   1: target occupied voxel count
//   2: overlap voxel count (both occupied)
//   3: sum |blend_completely - target_completely| * QUANT
//   4: sum color distance (rgb, overlap voxels only) * QUANT
//   5: processed voxel count

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer BlendComplexityField {
    uint blend_complexity_rgba8[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer BlendCollisionField {
    uint blend_collision_r8_words[];
};

layout(set = 0, binding = 2, std430) restrict readonly buffer TargetVisualField {
    uint target_visual_rgba8[];
};

layout(set = 0, binding = 3, std430) restrict readonly buffer TargetCollisionField {
    uint target_collision_r8_words[];
};

layout(set = 0, binding = 4, std430) restrict buffer FeedbackStats {
    uint feedback_stats[];
};

layout(push_constant, std430) uniform Params {
    int voxel_count;
    int has_target_collision;
    float occupied_epsilon;
    float quant_scale;
};

vec4 unpack_rgba8(uint packed_value) {
    return vec4(
        float((packed_value >> 24u) & 0xFFu),
        float((packed_value >> 16u) & 0xFFu),
        float((packed_value >> 8u) & 0xFFu),
        float(packed_value & 0xFFu)
    ) / 255.0;
}

float read_collision_r8(uint index, bool from_target) {
    uint word_index = index >> 2u;
    uint shift = (index & 3u) * 8u;
    uint word = from_target ? target_collision_r8_words[word_index] : blend_collision_r8_words[word_index];
    return float((word >> shift) & 0xFFu) / 255.0;
}

void main() {
    uint index = gl_GlobalInvocationID.x;
    if (index >= uint(max(voxel_count, 0))) {
        return;
    }

    vec4 blend_rgba = unpack_rgba8(blend_complexity_rgba8[index]);
    float blend_completely = max(blend_rgba.a, read_collision_r8(index, false));

    vec4 target_rgba = unpack_rgba8(target_visual_rgba8[index]);
    float target_completely = target_rgba.a;
    if (has_target_collision != 0) {
        target_completely = max(target_completely, read_collision_r8(index, true));
    }

    bool blend_occupied = blend_completely > occupied_epsilon;
    bool target_occupied = target_completely > occupied_epsilon;

    if (blend_occupied) {
        atomicAdd(feedback_stats[0], 1u);
    }
    if (target_occupied) {
        atomicAdd(feedback_stats[1], 1u);
    }
    atomicAdd(feedback_stats[3], uint(round(abs(blend_completely - target_completely) * quant_scale)));
    if (blend_occupied && target_occupied) {
        atomicAdd(feedback_stats[2], 1u);
        float color_distance = distance(blend_rgba.rgb, target_rgba.rgb) / sqrt(3.0);
        atomicAdd(feedback_stats[4], uint(round(color_distance * quant_scale)));
    }
    atomicAdd(feedback_stats[5], 1u);
}
