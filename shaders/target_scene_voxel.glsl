#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 4, local_size_z = 8) in;

layout(set = 0, binding = 0) uniform sampler2D t_scene_depth;
layout(set = 0, binding = 1) uniform sampler2D t_target_height;
layout(set = 0, binding = 2) uniform sampler2D t_object_mask;

layout(set = 1, binding = 0, std430) restrict buffer TargetVisual {
    uint target_visual_rgba8[];
};

layout(set = 1, binding = 1, std430) restrict buffer TargetCollision {
    uint target_collision_r8_words[];
};

layout(set = 1, binding = 2, std430) restrict buffer TargetCompletely {
    uint target_completely_r8_words[];
};

layout(set = 1, binding = 3, std430) restrict buffer TargetColorRgba8 {
    uint target_color_rgba8[];
};

layout(set = 1, binding = 4, std430) restrict buffer TargetStats {
    uint target_stats[];
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

layout(rgba16f, set = 2, binding = 0) uniform image2D rw_preview;

layout(push_constant, std430) uniform Params {
    float max_height;
    float capture_size;
    float vertical_span;
    float slope_start;
    float slope_full;
    int texture_size;
    int slice_count;
    int dirty_x;
    int dirty_y;
    int dirty_w;
    int dirty_h;
    int _pad0;
};

struct TargetVoxel {
    vec3 color;
    float value;
    float collision;
};

int voxel_index(ivec2 p, int slice_index) {
    return p.x + texture_size * (p.y + texture_size * slice_index);
}

float terrain_height(ivec2 p) {
    return max_height - texelFetch(t_scene_depth, p, 0).r;
}

float surface_slope(ivec2 p) {
    ivec2 tex_size = textureSize(t_scene_depth, 0);
    ivec2 max_cell = tex_size - ivec2(1);
    ivec2 left_p = clamp(p + ivec2(-1, 0), ivec2(0), max_cell);
    ivec2 right_p = clamp(p + ivec2(1, 0), ivec2(0), max_cell);
    ivec2 down_p = clamp(p + ivec2(0, 1), ivec2(0), max_cell);
    ivec2 up_p = clamp(p + ivec2(0, -1), ivec2(0), max_cell);
    float left_h = terrain_height(left_p);
    float right_h = terrain_height(right_p);
    float down_h = terrain_height(down_p);
    float up_h = terrain_height(up_p);
    float pixel_size = capture_size / max(float(texture_size - 1), 1.0);
    vec3 dx = vec3(pixel_size * 2.0, 0.0, right_h - left_h);
    vec3 dz = vec3(0.0, pixel_size * 2.0, down_h - up_h);
    vec3 n = normalize(cross(dx, dz));
    return clamp(length(n.xy), 0.0, 1.0);
}

TargetVoxel evaluate_voxel(ivec2 p, int slice_index) {
    float terrain_h = terrain_height(p);
    float target_h = texelFetch(t_target_height, p, 0).r;
    float object_mask = clamp(texelFetch(t_object_mask, p, 0).r, 0.0, 1.0);
    float slope = surface_slope(p);
    float slope_signal = smoothstep(slope_start, slope_full, slope);
    float height_delta = max(target_h - terrain_h, 0.0);
    float fill_signal = smoothstep(0.25, max(vertical_span * 0.35, 0.5), height_delta);
    float solid_signal = clamp(max(max(slope_signal, fill_signal), object_mask), 0.0, 1.0);
    float local_y = (float(slice_index) + 0.5) / max(float(slice_count), 1.0) * vertical_span;

    float solid_top = clamp(max(1.5, height_delta + 3.0), 1.5, vertical_span);
    float solid_vertical = 1.0 - smoothstep(solid_top, min(solid_top + 1.5, vertical_span + 0.01), local_y);
    float solid_value = clamp(solid_signal * solid_vertical, 0.0, 1.0);

    float flat_signal = 1.0 - smoothstep(slope_start, slope_full, slope);
    float surface_vertical = 1.0 - smoothstep(0.15, 1.1, local_y);
    float surface_value = clamp(flat_signal * surface_vertical * (1.0 - solid_signal) * 0.45, 0.0, 1.0);

    vec3 solid_color = vec3(0.56, 0.52, 0.46);
    vec3 surface_color = vec3(0.20, 0.48, 0.18);
    float visual_weight = solid_value + surface_value;
    vec3 color = visual_weight > 0.0001
        ? (solid_color * solid_value + surface_color * surface_value) / visual_weight
        : vec3(0.0);
    float value = clamp(max(solid_value, surface_value), 0.0, 1.0);
    float collision = clamp(max(solid_value * 0.95, surface_value * 0.08), 0.0, 1.0);

    TargetVoxel voxel;
    voxel.color = color;
    voxel.value = value;
    voxel.collision = collision;
    return voxel;
}

vec4 evaluate_preview(ivec2 p) {
    vec3 color_sum = vec3(0.0);
    float weight_sum = 0.0;
    float peak_value = 0.0;
    float peak_collision = 0.0;
    for (int s = 0; s < slice_count; s++) {
        TargetVoxel v = evaluate_voxel(p, s);
        float w = v.value * v.value;
        color_sum += v.color * w;
        weight_sum += w;
        peak_value = max(peak_value, v.value);
        peak_collision = max(peak_collision, v.collision);
    }
    vec3 color = weight_sum > 0.0001 ? color_sum / weight_sum : vec3(0.0);
    color = mix(color, vec3(0.72, 0.68, 0.60), peak_collision * 0.35);
    return vec4(color, max(peak_value, peak_collision));
}

uint pack_rgba8(vec4 color) {
    uvec4 bytes = uvec4(clamp(round(color * 255.0), vec4(0.0), vec4(255.0)));
    return (bytes.r << 24u) | (bytes.g << 16u) | (bytes.b << 8u) | bytes.a;
}

uint pack_r8(float value) {
    return uint(clamp(round(value * 255.0), 0.0, 255.0));
}

void store_collision_r8(uint idx, float value) {
    uint word_index = idx >> 2u;
    uint shift = (idx & 3u) * 8u;
    atomicOr(target_collision_r8_words[word_index], pack_r8(value) << shift);
}

void store_completely_r8(uint idx, float value) {
    uint word_index = idx >> 2u;
    uint shift = (idx & 3u) * 8u;
    atomicOr(target_completely_r8_words[word_index], pack_r8(value) << shift);
}

uint quantize_unit(float value) {
    return uint(clamp(round(value * 1000000.0), 0.0, 1000000.0));
}

void main() {
    ivec3 id = ivec3(gl_GlobalInvocationID.xyz);
    if (id.x >= dirty_w || id.z >= dirty_h || id.y >= slice_count) {
        return;
    }

    ivec2 p = ivec2(dirty_x + id.x, dirty_y + id.z);
    ivec2 tex_size = textureSize(t_scene_depth, 0);
    if (p.x < 0 || p.y < 0 || p.x >= tex_size.x || p.y >= tex_size.y || p.x >= texture_size || p.y >= texture_size) {
        return;
    }

    TargetVoxel voxel = evaluate_voxel(p, id.y);
    int idx = voxel_index(p, id.y);
    uint idx_u = uint(idx);
    float completely = max(voxel.value, voxel.collision);
    uint rgba8 = pack_rgba8(vec4(voxel.color, voxel.value));

    target_visual_rgba8[idx] = rgba8;
    store_collision_r8(idx_u, voxel.collision);
    store_completely_r8(idx_u, completely);
    target_color_rgba8[idx] = rgba8;

    atomicMax(target_stats[TARGET_STATS_MAX_OCCUPANCY], quantize_unit(completely));
    atomicMax(target_stats[TARGET_STATS_MAX_COLLISION], quantize_unit(voxel.collision));
    if (completely > TARGET_STATS_ACTIVE_THRESHOLD) {
        atomicAdd(target_stats[TARGET_STATS_ACTIVE_COUNT], 1u);
        atomicMax(target_stats[TARGET_STATS_MIN_ACTIVE_PACKED], TARGET_STATS_MIN_PACK_BASE - quantize_unit(completely));
    }
    if (voxel.collision > TARGET_STATS_ACTIVE_THRESHOLD) {
        atomicAdd(target_stats[TARGET_STATS_COLLISION_COUNT], 1u);
    }
    if (voxel.value > TARGET_STATS_ACTIVE_THRESHOLD) {
        atomicAdd(target_stats[TARGET_STATS_VISUAL_COUNT], 1u);
    }
    atomicMax(target_stats[TARGET_STATS_MAX_VISUAL], quantize_unit(voxel.value));

    if (id.y == 0) {
        imageStore(rw_preview, p, evaluate_preview(p));
    }
}
