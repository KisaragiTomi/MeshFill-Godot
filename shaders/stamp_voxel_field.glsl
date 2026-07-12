#[compute]
#version 450

// Stamps accepted placement results into complexity/collision field buffers.
// Output VoxelStampDeltaBuffer uses 2 vec4 records per collision sample:
//   0: vec4(voxel.xyz, complexity)
//   1: vec4(collision_strength, result_index, sample_index, wrote)
// Output VoxelStampBounds uses 2 uvec4 records per accepted placement:
//   0: uvec4(min_xyz, written_count)
//   1: uvec4(max_xyz_exclusive, reserved)
//
// Dual-commit mode (params.w > 0.5): bindings 0/1 are a transient BlendSV
// working pair (read by same-batch scoring), bindings 9/10 are the committed
// auto-only SV resident pair. The stamp IS the SV commit, so every write also
// lands in the commit pair. With the flag off, 9/10 alias 0/1 and are skipped.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer ComplexityField {
    uint complexity_field_rgba8[];
};

layout(set = 0, binding = 1, std430) restrict buffer CollisionField {
    uint collision_field_r8_words[];
};

layout(set = 0, binding = 2, std430) restrict readonly buffer PlacementResults {
    vec4 placement_results[];
};

layout(set = 0, binding = 3, std430) restrict readonly buffer ResultCount {
    uint result_count;
};

// Asset shape source: the SPA runtime-profile container's resident collision_records
// buffer (same records the scorer read; layout must match score_voxel_tile.glsl).
// This dispatch's slice is sample_pivot_pad.w (start) + grid_size_counts.w (count).
struct CollisionSampleRecord {
    ivec4 pos_strength;   // xyz = local voxel offset, w = collision_strength_q8 (0..255)
    vec4 weight_flags;    // x = weight, y = flags (FLAG_CLEARANCE bit), z/w = reserved
};
layout(set = 0, binding = 4, std430) restrict readonly buffer CollisionSampleRecords {
    CollisionSampleRecord collision_records[];
};
// binding = 5 retired (the old per-run weight/flags half; both halves now live in
// the single CollisionSampleRecord stream above).

layout(set = 0, binding = 6, std430) restrict buffer VoxelStampDelta {
    vec4 stamp_delta[];
};

layout(set = 0, binding = 7, std430) restrict buffer VoxelStampDeltaCount {
    uint stamp_delta_count;
};

layout(set = 0, binding = 8, std430) restrict buffer VoxelStampBounds {
    uvec4 stamp_bounds[];
};

layout(set = 0, binding = 9, std430) restrict buffer CommitComplexityField {
    uint commit_complexity_rgba8[];
};

layout(set = 0, binding = 10, std430) restrict buffer CommitCollisionField {
    uint commit_collision_r8_words[];
};

layout(push_constant, std430) uniform Params {
    ivec4 grid_size_counts;  // grid x, y, z, sample_count
    ivec4 write_min_pad;     // write min xyz (w = rotation_count)
    ivec4 write_max_pad;     // write max xyz, exclusive
    vec4 params;             // solid_threshold, complexity_write_scale, collision_write_scale, dual_commit flag
    vec4 stamp_color;        // RGB = asset color, A = unused
    ivec4 sample_pivot_pad;  // xyz = pivot voxels (subtracted before yaw), w = collision_records start offset
};

const uint RECORD_STRIDE = 4u;
const uint DELTA_STRIDE = 2u;

uint quantize_unorm8(float value) {
    return uint(round(clamp(value, 0.0, 1.0) * 255.0));
}

uint pack_rgba8(vec4 value) {
    uvec4 q = uvec4(
        quantize_unorm8(value.r),
        quantize_unorm8(value.g),
        quantize_unorm8(value.b),
        quantize_unorm8(value.a)
    );
    return (q.r << 24u) | (q.g << 16u) | (q.b << 8u) | q.a;
}

bool in_grid_bounds(ivec3 p) {
    return p.x >= 0 && p.y >= 0 && p.z >= 0
        && p.x < grid_size_counts.x
        && p.y < grid_size_counts.y
        && p.z < grid_size_counts.z;
}

bool in_write_bounds(ivec3 p) {
    return p.x >= write_min_pad.x && p.y >= write_min_pad.y && p.z >= write_min_pad.z
        && p.x < write_max_pad.x && p.y < write_max_pad.y && p.z < write_max_pad.z;
}

int voxel_index(ivec3 p) {
    return p.x + grid_size_counts.x * (p.z + grid_size_counts.z * p.y);
}

void atomic_max_collision_r8(uint index, float value) {
    uint word_index = index >> 2u;
    uint shift = (index & 3u) * 8u;
    uint mask = 0xFFu << shift;
    uint q = quantize_unorm8(value);
    uint old_word = collision_field_r8_words[word_index];
    for (int attempt = 0; attempt < 32; attempt++) {
        uint current = (old_word & mask) >> shift;
        if (current >= q) {
            return;
        }
        uint new_word = (old_word & ~mask) | (q << shift);
        uint previous = atomicCompSwap(collision_field_r8_words[word_index], old_word, new_word);
        if (previous == old_word) {
            return;
        }
        old_word = previous;
    }
}

void atomic_max_commit_collision_r8(uint index, float value) {
    uint word_index = index >> 2u;
    uint shift = (index & 3u) * 8u;
    uint mask = 0xFFu << shift;
    uint q = quantize_unorm8(value);
    uint old_word = commit_collision_r8_words[word_index];
    for (int attempt = 0; attempt < 32; attempt++) {
        uint current = (old_word & mask) >> shift;
        if (current >= q) {
            return;
        }
        uint new_word = (old_word & ~mask) | (q << shift);
        uint previous = atomicCompSwap(commit_collision_r8_words[word_index], old_word, new_word);
        if (previous == old_word) {
            return;
        }
        old_word = previous;
    }
}

// Complexity merges are monotonic max-by-alpha: overlapping samples (e.g. a
// clearance sample landing on an already-stamped solid) and same-dispatch
// races must never downgrade a committed voxel. pack_rgba8 keeps alpha in the
// low byte, so a plain atomicMax would order by red — CAS the whole word.
void atomic_max_complexity_rgba8(uint index, uint packed_value) {
    uint q = packed_value & 0xFFu;
    uint old_word = complexity_field_rgba8[index];
    for (int attempt = 0; attempt < 32; attempt++) {
        if ((old_word & 0xFFu) >= q) {
            return;
        }
        uint previous = atomicCompSwap(complexity_field_rgba8[index], old_word, packed_value);
        if (previous == old_word) {
            return;
        }
        old_word = previous;
    }
}

void atomic_max_commit_complexity_rgba8(uint index, uint packed_value) {
    uint q = packed_value & 0xFFu;
    uint old_word = commit_complexity_rgba8[index];
    for (int attempt = 0; attempt < 32; attempt++) {
        if ((old_word & 0xFFu) >= q) {
            return;
        }
        uint previous = atomicCompSwap(commit_complexity_rgba8[index], old_word, packed_value);
        if (previous == old_word) {
            return;
        }
        old_word = previous;
    }
}

void write_stamp_bounds(uint result_index, ivec3 p) {
    uint base = result_index * 2u;
    atomicMin(stamp_bounds[base + 0u].x, uint(p.x));
    atomicMin(stamp_bounds[base + 0u].y, uint(p.y));
    atomicMin(stamp_bounds[base + 0u].z, uint(p.z));
    atomicAdd(stamp_bounds[base + 0u].w, 1u);
    atomicMax(stamp_bounds[base + 1u].x, uint(p.x + 1));
    atomicMax(stamp_bounds[base + 1u].y, uint(p.y + 1));
    atomicMax(stamp_bounds[base + 1u].z, uint(p.z + 1));
}

// @@GEN yaw_rotation_y — generated from scripts/utils/placement_shared_glsl.gd, do not edit
// Canonical Y-yaw rotation, matching Basis(Vector3.UP, yaw):
//   rx =  ca*x + sa*z ;  rz = -sa*x + ca*z ;  y unchanged.
vec3 rotate_yaw_y(vec3 v, float ca, float sa) {
    return vec3(ca * v.x + sa * v.z, v.y, -sa * v.x + ca * v.z);
}

// Float variant for collision-sample offsets: rigid yaw (NO round, NO scale) so
// the sample position stays a genuine float for trilinear sampling.
vec3 rotate_sample_offset_y_f(ivec3 sample_offset, float ca, float sa) {
    return rotate_yaw_y(vec3(sample_offset), ca, sa);
}

// Voxel-snapped variant for integer collision-sample offsets (round x/z, keep y).
ivec3 rotate_sample_offset_y(ivec3 sample_offset, float ca, float sa) {
    vec3 r = rotate_yaw_y(vec3(sample_offset), ca, sa);
    return ivec3(int(round(r.x)), sample_offset.y, int(round(r.z)));
}

// Yaw-only world transform: Basis(Vector3.UP, yaw) columns + instance origin
// (column x = (cos, 0, -sin), column z = (sin, 0, cos)).
mat4 yaw_transform_y(float ca, float sa, vec3 origin) {
    return mat4(
        vec4(ca, 0.0, -sa, 0.0),
        vec4(0.0, 1.0, 0.0, 0.0),
        vec4(sa, 0.0, ca, 0.0),
        vec4(origin, 1.0)
    );
}
// @@END yaw_rotation_y

void main() {
    uint sample_count = uint(max(grid_size_counts.w, 0));
    if (sample_count == 0u) {
        return;
    }

    uint global_index = gl_GlobalInvocationID.x;
    uint result_index = global_index / sample_count;
    uint sample_index = global_index - result_index * sample_count;

    if (result_index >= result_count) {
        return;
    }

    vec4 origin_score = placement_results[result_index * RECORD_STRIDE + 0u];
    // The placement score (origin_score.w) is penalty-only now (<= 0 for valid placements), so it
    // can no longer double as the skip marker. Empty/invalid result slots carry valid == 0
    // in record[3].y (reduce_voxel_tiles.glsl write_empty zeroes the record) — gate on that.
    if (placement_results[result_index * RECORD_STRIDE + 3u].y < 0.5) {
        return;
    }

    // Record vec4[1] = (tile_id, asset_index, best_rotation_slot, scale_index).
    // rotation_count rides in write_min_pad.w so slot -> yaw matches the scorer.
    vec4 record_ids = placement_results[result_index * RECORD_STRIDE + 1u];
    int rot_slot = int(record_ids.z);
    int rot_count = max(write_min_pad.w, 1);
    float rot_angle = rot_count > 1 ? float(rot_slot) * 6.28318530718 / float(rot_count) : 0.0;
    float rot_ca = cos(rot_angle);
    float rot_sa = sin(rot_angle);

    ivec3 origin = ivec3(round(origin_score.xyz));
    CollisionSampleRecord sample_record = collision_records[uint(max(sample_pivot_pad.w, 0)) + sample_index];
    ivec4 fp = sample_record.pos_strength;
    vec4 wf = sample_record.weight_flags;
    // Pivot subtracted before yaw to match the scorer (CPU shift-then-rotate order).
    ivec3 base_fp = fp.xyz - ivec3(sample_pivot_pad.xyz);
    ivec3 rotated_fp = rot_count > 1 ? rotate_sample_offset_y(base_fp, rot_ca, rot_sa) : base_fp;
    ivec3 p = origin + rotated_fp;

    if (!in_grid_bounds(p) || !in_write_bounds(p)) {
        return;
    }

    float weight = max(wf.x, 0.0);
    float sample_collision_strength = clamp(float(fp.w) / 255.0, 0.0, 1.0);
    // Support baking is retired (no FLAG_SUPPORT ground probes are emitted), so the
    // strength-0 support-probe skip guard that used to live here is gone. Clearance
    // probes were never affected by it.
    float complexity = clamp(weight * params.y, 0.0, 1.0);
    float collision_strength = sample_collision_strength >= params.x ? clamp(sample_collision_strength * params.z, 0.0, 1.0) : 0.0;

    int index = voxel_index(p);
    uint packed_complexity = pack_rgba8(vec4(stamp_color.rgb, complexity));
    atomic_max_complexity_rgba8(uint(index), packed_complexity);
    if (collision_strength > 0.0) {
        atomic_max_collision_r8(uint(index), collision_strength);
    }
    if (params.w > 0.5) {
        atomic_max_commit_complexity_rgba8(uint(index), packed_complexity);
        if (collision_strength > 0.0) {
            atomic_max_commit_collision_r8(uint(index), collision_strength);
        }
    }

    uint compact_index = atomicAdd(stamp_delta_count, 1u);
    uint delta_base = compact_index * DELTA_STRIDE;
    stamp_delta[delta_base + 0u] = vec4(vec3(p), complexity);
    stamp_delta[delta_base + 1u] = vec4(collision_strength, float(result_index), float(sample_index), 1.0);
    write_stamp_bounds(result_index, p);
}
