#[compute]
#version 450

// Pass A: 3D object volume scoring — per-rotation valid sample accumulation.
//
// CPU side pre-bakes occupied footprint voxels into one sample record list per
// rotation slot. Each workgroup handles 512 valid samples for one anchor and
// writes one partial score per rotation slot.
//
// Dispatch: (sample_group_count, anchor_count, 1)
//   gl_WorkGroupID.x  = sample group id
//   gl_WorkGroupID.y  = anchor id
//   gl_LocalInvocationIndex = sample lane inside the 512-record group
//
// Output: partial_scores buffer, one float per (anchor, sample_group, rotation).

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

layout(set = 0, binding = 3, std430) restrict readonly buffer FootprintSampleRecords {
    ivec4 sample_records[];
};

layout(set = 0, binding = 4, std430) restrict readonly buffer FootprintProps {
    vec4 footprint_props[];
};

layout(set = 0, binding = 5, std430) restrict readonly buffer AnchorPositions {
    ivec4 anchor_positions[];
};

layout(set = 0, binding = 6, std430) restrict readonly buffer SampleCounts {
    int sample_counts[];
};

layout(set = 0, binding = 7, std430) restrict writeonly buffer PartialScores {
    float partial_scores[];
};

layout(push_constant, std430) uniform Params {
    ivec4 scene_grid;      // grid x/y/z, voxel_count
    ivec4 sample_config;   // variant_capacity, sample_group_count, rotation_count, max_sample_count
    ivec4 reserved0;
    ivec4 reserved1;
    vec4 asset_color;
};

shared float s_reduce[512];

int sv_idx(ivec3 p) {
    return p.x + scene_grid.x * (p.z + scene_grid.z * p.y);
}

bool sv_valid(ivec3 p) {
    return all(greaterThanEqual(p, ivec3(0))) && all(lessThan(p, scene_grid.xyz));
}

void main() {
    uint lid = gl_LocalInvocationIndex;
    uint sample_group_id = gl_WorkGroupID.x;
    uint anchor_id = gl_WorkGroupID.y;

    int variant_capacity = max(sample_config.x, 1);
    int sample_group_count = max(sample_config.y, 1);
    int rot = max(sample_config.z, 1);
    if (sample_group_id >= uint(sample_group_count)) return;

    ivec3 anchor = anchor_positions[anchor_id].xyz;
    uint sample_index = sample_group_id * 512u + lid;

    for (int slot = 0; slot < rot; slot++) {
        float contrib = 0.0;
        int sample_count = max(sample_counts[slot], 0);

        if (sample_index < uint(sample_count)) {
            uint record_index = uint(slot * variant_capacity) + sample_index;
            ivec4 sample_record = sample_records[record_index];
            int fp_index = sample_record.w;
            ivec3 world_pos = anchor + sample_record.xyz;

            if (fp_index >= 0 && sv_valid(world_pos)) {
                int si = sv_idx(world_pos);
                vec2 scene = vec2(complexity_field[si].a, collision_field[si]);
                vec4 target = target_field[si];
                vec4 fpp = footprint_props[fp_index];

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

        s_reduce[lid] = contrib;
        barrier();

        if (lid == 0u) {
            float sum = 0.0;
            for (uint i = 0u; i < 512u; i++) {
                sum += s_reduce[i];
            }
            uint out_idx = anchor_id * uint(sample_group_count) * uint(rot)
                         + sample_group_id * uint(rot) + uint(slot);
            partial_scores[out_idx] = sum;
        }
        barrier();
    }
}
