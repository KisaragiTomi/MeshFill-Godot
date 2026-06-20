#[compute]
#version 450

// Pass A: 3D object volume scoring — per-subtile partial accumulation.
//
// One workgroup owns one 8^3 subtile of the 50^3 sampling volume centered on
// an anchor. Scene/target voxels are loaded into shared memory once, then
// reused across all 12 rotation slots.
//
// Dispatch: (SUBTILE_COUNT, anchor_count, 1)
//   gl_WorkGroupID.x  = subtile linear id  0..subtile_count-1
//   gl_WorkGroupID.y  = anchor id
//   gl_LocalInvocationID.xyz = subtile-local voxel (8,8,8)
//
// Output: partial_scores buffer, one float per (anchor, subtile, rotation_slot).

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer ComplexityField {
    vec4 complexity_field[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer CollisionField {
    float collision_field[];
};

layout(set = 0, binding = 2, std430) restrict readonly buffer TargetField {
    vec4 target_field[];
};

layout(set = 0, binding = 3, std430) restrict readonly buffer FootprintOccupancy {
    int footprint_occupancy[];
};

layout(set = 0, binding = 4, std430) restrict readonly buffer FootprintProps {
    vec4 footprint_props[];
};

layout(set = 0, binding = 5, std430) restrict readonly buffer AnchorPositions {
    ivec4 anchor_positions[];
};

layout(set = 0, binding = 6, std430) restrict writeonly buffer PartialScores {
    float partial_scores[];
};

layout(push_constant, std430) uniform Params {
    ivec4 scene_grid;
    ivec4 fp_grid;
    ivec4 fp_pivot_extent;
    ivec4 config;
    vec4 asset_color;
};

shared vec2 s_scene[512];
shared vec4 s_target[512];
shared float s_reduce[512];

int sv_idx(ivec3 p) {
    return p.x + scene_grid.x * (p.z + scene_grid.z * p.y);
}

bool sv_valid(ivec3 p) {
    return all(greaterThanEqual(p, ivec3(0))) && all(lessThan(p, scene_grid.xyz));
}

int fp_idx(ivec3 p) {
    return p.x + fp_grid.x * (p.z + fp_grid.z * p.y);
}

bool fp_valid(ivec3 p) {
    return all(greaterThanEqual(p, ivec3(0))) && all(lessThan(p, fp_grid.xyz));
}

void main() {
    uint lid = gl_LocalInvocationIndex;
    uint subtile_id = gl_WorkGroupID.x;
    uint anchor_id = gl_WorkGroupID.y;

    int spa = config.y;
    int stc = config.z;
    int rot = config.x;
    int extent = fp_pivot_extent.w;
    int half_ext = extent / 2;

    if (subtile_id >= uint(stc)) return;

    int sx = int(subtile_id) % spa;
    int sy = (int(subtile_id) / spa) % spa;
    int sz = int(subtile_id) / (spa * spa);

    ivec3 anchor = anchor_positions[anchor_id].xyz;
    ivec3 local_pos = ivec3(gl_LocalInvocationID.xyz);
    ivec3 sample_pos = ivec3(sx, sy, sz) * 8 + local_pos;
    ivec3 world_pos = anchor - ivec3(half_ext) + sample_pos;

    bool in_extent = all(lessThan(sample_pos, ivec3(extent)));

    if (in_extent && sv_valid(world_pos)) {
        int si = sv_idx(world_pos);
        s_scene[lid] = vec2(complexity_field[si].a, collision_field[si]);
        s_target[lid] = target_field[si];
    } else {
        s_scene[lid] = vec2(0.0);
        s_target[lid] = vec4(0.0);
    }
    barrier();

    float PI = 3.14159265358979;
    float angle_step = 2.0 * PI / float(rot);

    for (int slot = 0; slot < rot; slot++) {
        float angle = float(slot) * angle_step;
        float ca = cos(angle);
        float sa = sin(angle);

        float contrib = 0.0;

        if (in_extent) {
            vec3 rel = vec3(world_pos - anchor);
            float fx = ca * rel.x - sa * rel.z;
            float fz = sa * rel.x + ca * rel.z;
            ivec3 fp = fp_pivot_extent.xyz + ivec3(int(round(fx)), int(rel.y), int(round(fz)));

            if (fp_valid(fp)) {
                int fi = fp_idx(fp);
                if (footprint_occupancy[fi] != 0) {
                    vec4 fpp = footprint_props[fi];
                    vec2 scene = s_scene[lid];
                    vec4 target = s_target[lid];

                    float target_cx = target.a;
                    float coverage = step(0.01, target_cx);
                    float cx_fit = 1.0 - abs(target_cx - fpp.a);
                    float col_dist = distance(target.rgb, asset_color.rgb);
                    float col_fit = clamp(1.0 - col_dist / 1.732, 0.0, 1.0);
                    float collision_pen = scene.y * fpp.a;

                    contrib = coverage * (cx_fit * 0.4 + col_fit * 0.3 + 0.3)
                            - collision_pen * 0.5;
                }
            }
        }

        s_reduce[lid] = contrib;
        barrier();

        if (lid == 0u) {
            float sum = 0.0;
            for (uint i = 0u; i < 512u; i++) {
                sum += s_reduce[i];
            }
            uint out_idx = anchor_id * uint(stc) * uint(rot)
                         + subtile_id * uint(rot) + uint(slot);
            partial_scores[out_idx] = sum;
        }
        barrier();
    }
}
