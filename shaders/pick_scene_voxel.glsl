#[compute]
#version 450

layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer TerrainHeight {
    float terrain_height[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer TargetVisual {
    uint target_visual_rgba8[];
};

layout(set = 0, binding = 2, std430) restrict readonly buffer TargetCollision {
    uint target_collision_r8_words[];
};

layout(set = 0, binding = 3, std430) restrict writeonly buffer PickOutput {
    uint out_words[];
};

layout(push_constant, std430) uniform Params {
    int mode;
    int grid_x;
    int grid_y;
    int grid_z;
    int terrain_res;
    int target_size;
    int target_slices;
    int search_radius;
    int base_x;
    int base_z;
    int _pad_i0;
    int _pad_i1;
    float ray_ox;
    float ray_oy;
    float ray_oz;
    float ray_dx;
    float ray_dy;
    float ray_dz;
    float grid_ox;
    float grid_oy;
    float grid_oz;
    float voxel_sx;
    float voxel_sy;
    float voxel_sz;
    float capture_size;
    float max_height;
    float surface_offset;
    float vertical_span;
    float display_scale;
    float occupancy_threshold;
    float max_t;
    float _pad_f0;
};

const int MODE_SCENE_VOXEL = 0;
const int MODE_TARGETSV = 1;
const float INF = 3.402823466e+38;

vec4 unpack_rgba8(uint packed) {
    return vec4(
        float((packed >> 24u) & 0xFFu) / 255.0,
        float((packed >> 16u) & 0xFFu) / 255.0,
        float((packed >>  8u) & 0xFFu) / 255.0,
        float((packed >>  0u) & 0xFFu) / 255.0
    );
}

float load_target_collision_r8(uint index) {
    uint word = target_collision_r8_words[index >> 2u];
    uint shift = (index & 3u) * 8u;
    return float((word >> shift) & 0xFFu) / 255.0;
}

vec3 ray_origin() {
    return vec3(ray_ox, ray_oy, ray_oz);
}

vec3 ray_dir() {
    return normalize(vec3(ray_dx, ray_dy, ray_dz));
}

void write_hit(ivec3 voxel, vec3 world_pos, float score, float complexity, float collision, uint mode_id, uint buffer_index) {
    out_words[0] = 1u;
    out_words[1] = uint(max(voxel.x, 0));
    out_words[2] = uint(max(voxel.y, 0));
    out_words[3] = uint(max(voxel.z, 0));
    out_words[4] = floatBitsToUint(world_pos.x);
    out_words[5] = floatBitsToUint(world_pos.y);
    out_words[6] = floatBitsToUint(world_pos.z);
    out_words[7] = floatBitsToUint(score);
    out_words[8] = floatBitsToUint(complexity);
    out_words[9] = floatBitsToUint(collision);
    out_words[10] = mode_id;
    out_words[11] = buffer_index;
}

bool in_capture_xz(vec3 pos) {
    float half_capture = capture_size * 0.5;
    return pos.x >= -half_capture && pos.x <= half_capture && pos.z >= -half_capture && pos.z <= half_capture;
}

float sample_height_uv(float u, float v) {
    int res = max(terrain_res, 1);
    float cu = clamp(u, 0.0, 1.0);
    float cv = clamp(v, 0.0, 1.0);
    int px = clamp(int(cu * float(res - 1)), 0, res - 1);
    int pz = clamp(int(cv * float(res - 1)), 0, res - 1);
    return terrain_height[pz * res + px];
}

float sample_height_world(float wx, float wz) {
    float u = wx / max(capture_size, 0.0001) + 0.5;
    float v = wz / max(capture_size, 0.0001) + 0.5;
    return sample_height_uv(u, v);
}

bool axis_interval(float origin, float dir, float lo, float hi, inout float t_min, inout float t_max) {
    if (abs(dir) < 0.00001) {
        return origin >= lo && origin <= hi;
    }
    float t1 = (lo - origin) / dir;
    float t2 = (hi - origin) / dir;
    t_min = max(t_min, min(t1, t2));
    t_max = min(t_max, max(t1, t2));
    return t_max >= t_min && t_max >= 0.0;
}

bool ray_capture_interval(vec3 origin, vec3 dir, out float t_min, out float t_max) {
    float half_capture = capture_size * 0.5;
    t_min = 0.0;
    t_max = max(max_t, 1.0);
    if (!axis_interval(origin.x, dir.x, -half_capture, half_capture, t_min, t_max)) return false;
    if (!axis_interval(origin.z, dir.z, -half_capture, half_capture, t_min, t_max)) return false;
    if (t_max < t_min || t_max < 0.0) return false;
    t_min = max(t_min, 0.0);
    return true;
}

ivec3 scene_voxel_from_world(vec3 world_pos) {
    int gx = max(grid_x, 1);
    int gy = max(grid_y, 1);
    int gz = max(grid_z, 1);
    vec3 origin = vec3(grid_ox, grid_oy, grid_oz);
    vec3 size = max(vec3(voxel_sx, voxel_sy, voxel_sz), vec3(0.0001));
    vec3 local = (world_pos - origin) / size;
    return ivec3(
        clamp(int(floor(local.x)), 0, gx - 1),
        clamp(int(floor(local.y)), 0, gy - 1),
        clamp(int(floor(local.z)), 0, gz - 1)
    );
}

void pick_scene_voxel() {
    vec3 origin = ray_origin();
    vec3 dir = ray_dir();
    float t0;
    float t1;
    if (!ray_capture_interval(origin, dir, t0, t1)) {
        if (abs(dir.y) > 0.00001) {
            float t_plane = -origin.y / dir.y;
            vec3 plane_pos = origin + dir * t_plane;
            if (t_plane >= 0.0 && in_capture_xz(plane_pos)) {
                write_hit(scene_voxel_from_world(plane_pos), plane_pos, t_plane, 0.0, 0.0, uint(MODE_SCENE_VOXEL), 0u);
            }
        }
        return;
    }

    if (t1 <= t0) return;

    const int STEPS = 48;
    const int BISECT_STEPS = 8;
    float prev_t = t0;
    vec3 prev_pos = origin + dir * prev_t;
    float prev_delta = prev_pos.y - (sample_height_world(prev_pos.x, prev_pos.z) + surface_offset);
    vec3 best_pos = prev_pos;
    float best_abs = abs(prev_delta);

    for (int step = 1; step <= STEPS; step++) {
        float t = mix(t0, t1, float(step) / float(STEPS));
        vec3 pos = origin + dir * t;
        float delta = pos.y - (sample_height_world(pos.x, pos.z) + surface_offset);
        float delta_abs = abs(delta);
        if (delta_abs < best_abs) {
            best_abs = delta_abs;
            best_pos = pos;
        }
        if ((prev_delta >= 0.0 && delta <= 0.0) || (prev_delta <= 0.0 && delta >= 0.0)) {
            float lo = prev_t;
            float hi = t;
            for (int i = 0; i < BISECT_STEPS; i++) {
                float mid = (lo + hi) * 0.5;
                vec3 mid_pos = origin + dir * mid;
                float mid_delta = mid_pos.y - (sample_height_world(mid_pos.x, mid_pos.z) + surface_offset);
                if ((prev_delta >= 0.0 && mid_delta >= 0.0) || (prev_delta <= 0.0 && mid_delta <= 0.0)) {
                    lo = mid;
                } else {
                    hi = mid;
                }
            }
            float hit_t = (lo + hi) * 0.5;
            vec3 hit_pos = origin + dir * hit_t;
            write_hit(scene_voxel_from_world(hit_pos), hit_pos, hit_t, 0.0, 0.0, uint(MODE_SCENE_VOXEL), 0u);
            return;
        }
        prev_t = t;
        prev_delta = delta;
    }

    if (best_abs <= max_height + 64.0 && in_capture_xz(best_pos)) {
        write_hit(scene_voxel_from_world(best_pos), best_pos, best_abs, 0.0, 0.0, uint(MODE_SCENE_VOXEL), 0u);
    }
}

vec3 target_voxel_world(int x, int slice_index, int z) {
    int ts = max(target_size, 1);
    int slices = max(target_slices, 1);
    float denom = max(float(ts - 1), 1.0);
    float fx = (float(x) / denom - 0.5) * capture_size * display_scale;
    float fz = (float(z) / denom - 0.5) * capture_size * display_scale;
    float terrain_y = sample_height_uv(float(x) / denom, float(z) / denom);
    float local_y = (float(slice_index) + 0.5) / max(float(slices), 1.0) * vertical_span;
    return vec3(grid_ox + fx, grid_oy + (terrain_y + local_y) * display_scale, grid_oz + fz);
}

void pick_targetsv() {
    vec3 origin = ray_origin();
    vec3 dir = ray_dir();
    int ts = max(target_size, 1);
    int slices = max(target_slices, 1);
    int radius = max(search_radius, 0);

    float best_score = INF;
    int best_x = -1;
    int best_slice = 0;
    int best_z = 0;
    uint best_idx = 0u;
    float best_complexity = 0.0;
    float best_collision = 0.0;
    vec3 best_world = vec3(0.0);

    for (int dz = -radius; dz <= radius; dz++) {
        int z = clamp(base_z + dz, 0, ts - 1);
        for (int dx = -radius; dx <= radius; dx++) {
            int x = clamp(base_x + dx, 0, ts - 1);
            for (int slice_index = 0; slice_index < slices; slice_index++) {
                uint idx = uint((slice_index * ts + z) * ts + x);
                float complexity = unpack_rgba8(target_visual_rgba8[idx]).a;
                float collision = load_target_collision_r8(idx);
                float occupancy = max(complexity, collision);
                if (occupancy <= occupancy_threshold) continue;

                vec3 center = target_voxel_world(x, slice_index, z);
                float t = dot(center - origin, dir);
                if (t < 0.0 || t > max(max_t, 1.0)) continue;
                vec3 closest = origin + dir * t;
                float dist2 = dot(center - closest, center - closest);
                float score = dist2 / max(occupancy, 0.001);
                if (score < best_score) {
                    best_score = score;
                    best_x = x;
                    best_slice = slice_index;
                    best_z = z;
                    best_idx = idx;
                    best_complexity = complexity;
                    best_collision = collision;
                    best_world = center;
                }
            }
        }
    }

    if (best_x >= 0) {
        write_hit(
            ivec3(best_x, best_slice, best_z),
            best_world,
            best_score,
            best_complexity,
            best_collision,
            uint(MODE_TARGETSV),
            best_idx
        );
    }
}

void main() {
    if (mode == MODE_TARGETSV) {
        pick_targetsv();
    } else {
        pick_scene_voxel();
    }
}
