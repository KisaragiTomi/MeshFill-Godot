#[compute]
#version 450

layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer SceneField {
    float scene_field[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer TargetField {
    float target_field[];
};

layout(set = 0, binding = 2, std430) restrict buffer FeedbackStats {
    vec4 stats[];
};

layout(push_constant, std430) uniform Params {
    ivec4 counts; // sample_count, unused, unused, unused
    vec4 params;  // threshold, unused, unused, unused
};

void main() {
    int sample_count = max(counts.x, 0);
    float threshold = max(params.x, 0.0);

    float error_sum = 0.0;
    float scene_occupied_count = 0.0;
    float target_occupied_count = 0.0;
    float overlap_occupied_count = 0.0;

    for (int idx = 0; idx < sample_count; idx++) {
        float scene_complexity = clamp(scene_field[idx], 0.0, 1.0);
        float target_complexity = clamp(target_field[idx], 0.0, 1.0);
        error_sum += abs(scene_complexity - target_complexity);

        bool scene_occupied = scene_complexity > threshold;
        bool target_occupied = target_complexity > threshold;
        if (scene_occupied) {
            scene_occupied_count += 1.0;
        }
        if (target_occupied) {
            target_occupied_count += 1.0;
        }
        if (scene_occupied && target_occupied) {
            overlap_occupied_count += 1.0;
        }
    }

    stats[0] = vec4(error_sum, scene_occupied_count, target_occupied_count, overlap_occupied_count);
    stats[1] = vec4(float(sample_count), 0.0, 0.0, 1.0);
}
