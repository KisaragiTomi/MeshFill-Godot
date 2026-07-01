#[compute]
#version 450

// Pass A: 3D object volume scoring — per-rotation valid sample accumulation.
//
// CPU side pre-bakes footprint voxels into one sample record list per rotation
// slot; each record carries the sample's continuous scene-voxel offset, sampled
// here via 8-neighbor trilinear interpolation instead of snapping to a voxel
// center. Each workgroup handles 512 valid samples for one anchor and writes one
// partial score per rotation slot.
//
// Dispatch: (sample_group_count, anchor_count, 1)
//   gl_WorkGroupID.x  = sample group id
//   gl_WorkGroupID.y  = anchor id
//   gl_LocalInvocationIndex = sample lane inside the 512-record group
//
// Output: partial_scores buffer, one float per (anchor, sample_group, rotation).

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

// Scene fields as 3D textures sampled with a hardware trilinear CLAMP_TO_EDGE
// sampler (see ObjectVolumeScoreGpu._dispatch_pass_a). Texture dims are (gx, gz, gy),
// so the sample UVW is (x, z, y) — matching the old sv_idx byte order x + gx*(z + gz*y).
layout(set = 0, binding = 0) uniform sampler3D complexity_field;  // rgba8: a = complexity/coverage
layout(set = 0, binding = 1) uniform sampler3D collision_field;   // r8: r = collision strength
layout(set = 0, binding = 2) uniform sampler3D target_field;      // rgba8: rgb = color, a = coverage

layout(set = 0, binding = 3, std430) restrict readonly buffer FootprintSampleRecords {
    // xyz = continuous scene-voxel offset from the anchor (not snapped to a voxel
    // center); w = float(footprint props index). Sampled via 8-neighbor trilinear.
    vec4 sample_records[];
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

// Hardware trilinear sample of (complexity.a, collision.r, target.rgba) at a
// continuous scene-voxel position. The CLAMP_TO_EDGE linear sampler performs the
// 8-neighbor blend; texture dims are (gx, gz, gy) so UVW = (x, z, y). Samples whose
// whole 8-neighborhood is outside the grid return wsum = 0 so the caller skips them
// (matching the old per-corner sv_valid gate); in-grid samples keep wsum = 1.0, so
// the caller's 1/wsum normalization is a no-op.
void sample_fields_trilinear(vec3 p, out float cx, out float coll, out vec4 target, out float wsum) {
    cx = 0.0;
    coll = 0.0;
    target = vec4(0.0);
    wsum = 0.0;
    if (any(lessThanEqual(p, vec3(-1.0))) || any(greaterThanEqual(p, vec3(scene_grid.xyz)))) {
        return;
    }
    vec3 uvw = (vec3(p.x, p.z, p.y) + 0.5) / vec3(scene_grid.x, scene_grid.z, scene_grid.y);
    cx = texture(complexity_field, uvw).a;
    coll = texture(collision_field, uvw).r;
    target = texture(target_field, uvw);
    wsum = 1.0;
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
            vec4 sample_record = sample_records[record_index];
            int fp_index = int(sample_record.w);
            vec3 sample_pos = vec3(anchor) + sample_record.xyz;

            float cx_a;
            float coll;
            vec4 target;
            float wsum;
            sample_fields_trilinear(sample_pos, cx_a, coll, target, wsum);

            if (fp_index >= 0 && wsum > 0.0) {
                float inv_w = 1.0 / wsum;
                cx_a *= inv_w;
                coll *= inv_w;
                target *= inv_w;
                vec4 fpp = footprint_props[fp_index];

                float target_cx = target.a;
                float coverage = step(0.01, target_cx);
                float cx_fit = 1.0 - abs(target_cx - fpp.a);
                float col_dist = distance(target.rgb, asset_color.rgb);
                float col_fit = clamp(1.0 - col_dist / 1.732, 0.0, 1.0);
                float collision_pen = coll * fpp.a;

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
