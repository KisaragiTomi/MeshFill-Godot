#[compute]
#version 450

// Mixed-asset stamp (replaces the per-asset stamp_voxel_field.glsl).
//
// One workgroup = one accepted placement record; the 64 threads stride over
// that record's asset_voxel_records slice. Per-record asset metadata comes
// from the record itself (no per-asset dispatch, no per-asset push constants):
//   profile_index      = record[3].x  -> profile table row (asset_voxel + pivot ranges)
//   yaw_slot           = record[1].z
//   global_pivot_index = record[1].w  (-1 = zero pivot; else pivot_records index)
// Voxel color/complexity/collision come from each AssetVoxelRecord — the write
// values and the monotonic-max compose are the shared @@GEN ad_voxel_compose
// rules, i.e. exactly what score_anchor_asset_residual.glsl predicted.
// Clearance records (FLAG_CLEARANCE) are constraint probes and write nothing.
//
// Output VoxelStampDeltaBuffer uses 2 vec4 records per written voxel:
//   0: vec4(voxel.xyz, complexity)
//   1: vec4(collision_strength, result_index, sample_index, wrote)
// Output VoxelStampBounds uses 2 uvec4 records per accepted placement:
//   0: uvec4(min_xyz, written_count)
//   1: uvec4(max_xyz_exclusive, reserved)
//
// Dual-commit mode (params.w > 0.5): bindings 0/1 are a transient BlendSV
// working pair (read by same-batch scoring), bindings 10/11 are the committed
// auto-only SV resident pair. The stamp IS the SV commit, so every write also
// lands in the commit pair. With the flag off, 10/11 alias 0/1 and are skipped.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer ComplexityField {
    uint complexity_field_rgba8[];
};

layout(set = 0, binding = 1, std430) restrict buffer CollisionField {
    uint collision_field_u32[];
};

layout(set = 0, binding = 2, std430) restrict readonly buffer PlacementResults {
    vec4 placement_results[];
};

layout(set = 0, binding = 3, std430) restrict readonly buffer ResultCount {
    uint result_count;
};

struct RuntimeProfileTableRecord {
    uvec4 ids;                    // x=profile_id, y=profile_index, z=probe_start, w=probe_count
    uvec4 ranges;                 // x=asset_voxel_start, y=asset_voxel_count, z=pivot_start, w=pivot_count
    vec4 color_complexity;
    vec4 density_radius_hash_pad;
};

struct RuntimePivotRecord {
    vec4 offset_bias;             // xyz = descriptor-local WORLD offset, w = score_bias
    uvec4 ids_pad;
};

struct AssetVoxelRecord {
    ivec4 pos_strength;           // xyz = local voxel offset, w = collision_strength_q8 (0..255)
    uint color_rgba8;             // shader rgba8 word, alpha = complexity
    float weight;
    uint flags;                   // FLAG_CLEARANCE bit
    uint reserved;
};

layout(set = 0, binding = 4, std430) restrict readonly buffer RuntimeProfileTable {
    RuntimeProfileTableRecord runtime_profile_table[];
};

layout(set = 0, binding = 5, std430) restrict readonly buffer RuntimePivotRecords {
    RuntimePivotRecord runtime_pivot_records[];
};

layout(set = 0, binding = 6, std430) restrict readonly buffer AssetVoxelRecords {
    AssetVoxelRecord asset_voxel_records[];
};

layout(set = 0, binding = 7, std430) restrict buffer VoxelStampDelta {
    vec4 stamp_delta[];
};

layout(set = 0, binding = 8, std430) restrict buffer VoxelStampDeltaCount {
    uint stamp_delta_count;
};

layout(set = 0, binding = 9, std430) restrict buffer VoxelStampBounds {
    uvec4 stamp_bounds[];
};

layout(set = 0, binding = 10, std430) restrict buffer CommitComplexityField {
    uint commit_complexity_rgba8[];
};

layout(set = 0, binding = 11, std430) restrict buffer CommitCollisionField {
    uint commit_collision_u32[];
};

layout(push_constant, std430) uniform Params {
    ivec4 grid_size_rotation;  // grid xyz, w = rotation_slots (yaw sweep width, matches the scorer)
    ivec4 write_min_pad;       // write-window min xyz, w = profile_count
    ivec4 write_max_pad;       // write-window max xyz exclusive, w = stamp_delta_capacity
    vec4 params;               // solid_threshold, complexity_write_scale, collision_write_scale, dual_commit flag
    vec4 voxel_size_pad;       // voxel size xyz (world units, pivot world->voxel), w reserved
    // Host-passed element capacities for the capacity gates below (the host
    // packs each bound buffer's element count at its allocation point; GLSL
    // .length()/OpArrayLength is unsupported by Godot's SPIR-V path).
    ivec4 capacities;          // x=runtime_profile_table, y=asset_voxel_records, z=runtime_pivot_records, w reserved
};

const uint RECORD_STRIDE = 4u;
const uint DELTA_STRIDE = 2u;
const uint FLAG_CLEARANCE = 2u;
const uint WORKGROUP_SIZE = 64u;

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
        && p.x < grid_size_rotation.x
        && p.y < grid_size_rotation.y
        && p.z < grid_size_rotation.z;
}

bool in_write_bounds(ivec3 p) {
    return p.x >= write_min_pad.x && p.y >= write_min_pad.y && p.z >= write_min_pad.z
        && p.x < write_max_pad.x && p.y < write_max_pad.y && p.z < write_max_pad.z;
}

int voxel_index(ivec3 p) {
    return p.x + grid_size_rotation.x * (p.z + grid_size_rotation.z * p.y);
}

// Collision stores one quantized 0..255 value per uint32; unorm8 quantization
// preserves ordering, so a plain atomicMax is the monotonic merge.
void atomic_max_collision_r8(uint index, float value) {
    atomicMax(collision_field_u32[index], quantize_unorm8(value));
}

void atomic_max_commit_collision_r8(uint index, float value) {
    atomicMax(commit_collision_u32[index], quantize_unorm8(value));
}

// Complexity merges are monotonic max-by-alpha: overlapping samples and
// same-dispatch races must never downgrade a committed voxel. pack_rgba8 keeps
// alpha in the low byte, so a plain atomicMax would order by red — CAS the
// whole word. Same tie rule as ad_compose_rgba: current >= new keeps current.
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

// @@GEN ad_voxel_compose — generated from scripts/utils/placement_shared_glsl.gd, do not edit
// Stamp-equivalent AD voxel write values + monotonic-max compose.
// Ties keep the current value, matching the stamp CAS loops which return
// without writing when current >= new (both complexity-alpha and collision).
float ad_complexity_write_value(float ad_complexity, float complexity_write_scale) {
    return clamp(ad_complexity * complexity_write_scale, 0.0, 1.0);
}

float ad_collision_write_value(float ad_collision, float solid_threshold, float collision_write_scale) {
    return ad_collision >= solid_threshold ? clamp(ad_collision * collision_write_scale, 0.0, 1.0) : 0.0;
}

// Complexity/color merge is max-by-alpha over the WHOLE rgba value: the higher
// complexity wins and brings its color along; equal alpha keeps the current rgba.
vec4 ad_compose_rgba(vec4 current_rgba, vec3 ad_rgb, float ad_complexity_value) {
    return ad_complexity_value > current_rgba.a ? vec4(ad_rgb, ad_complexity_value) : current_rgba;
}

float ad_compose_collision(float current_collision, float ad_collision_value) {
    return max(current_collision, ad_collision_value);
}
// @@END ad_voxel_compose

vec4 unpack_rgba8(uint packed_value) {
    return vec4(
        float((packed_value >> 24u) & 0xFFu),
        float((packed_value >> 16u) & 0xFFu),
        float((packed_value >> 8u) & 0xFFu),
        float(packed_value & 0xFFu)
    ) / 255.0;
}

void main() {
    uint record_index = gl_WorkGroupID.x;
    if (record_index >= result_count) {
        return;
    }
    uint base = record_index * RECORD_STRIDE;
    // Valid-flag gate: empty slots carry valid == 0 in record[3].y.
    if (placement_results[base + 3u].y < 0.5) {
        return;
    }

    int profile_index = int(round(placement_results[base + 3u].x));
    if (profile_index < 0 || profile_index >= max(write_min_pad.w, 0)
            || profile_index >= max(capacities.x, 0)) {
        return;
    }
    RuntimeProfileTableRecord profile = runtime_profile_table[profile_index];
    uint ad_start = profile.ranges.x;
    uint ad_count = profile.ranges.y;
    // Capacity gate: refuse a corrupt profile range instead of reading past the
    // AD record buffer (capacity is the host-passed element count).
    uint ad_capacity = uint(max(capacities.y, 0));
    if (ad_start > ad_capacity || ad_count > ad_capacity - ad_start) {
        return;
    }

    vec4 origin_score = placement_results[base + 0u];
    vec4 record_ids = placement_results[base + 1u];
    ivec3 origin = ivec3(round(origin_score.xyz));

    int rot_slot = int(round(record_ids.z));
    int rot_count = max(grid_size_rotation.w, 1);
    float rot_angle = rot_count > 1 ? float(rot_slot) * 6.28318530718 / float(rot_count) : 0.0;
    float rot_ca = cos(rot_angle);
    float rot_sa = sin(rot_angle);

    int global_pivot_index = int(round(record_ids.w));
    ivec3 pivot_voxels = ivec3(0);
    if (global_pivot_index >= 0) {
        if (global_pivot_index >= max(capacities.z, 0)) {
            return; // out-of-range pivot record — refuse the whole placement
        }
        vec3 pivot_world = runtime_pivot_records[global_pivot_index].offset_bias.xyz;
        pivot_voxels = ivec3(round(pivot_world / max(voxel_size_pad.xyz, vec3(1.0e-6))));
    }

    for (uint sample_index = gl_LocalInvocationID.x; sample_index < ad_count; sample_index += WORKGROUP_SIZE) {
        AssetVoxelRecord rec = asset_voxel_records[ad_start + sample_index];
        if ((rec.flags & FLAG_CLEARANCE) != 0u) {
            continue; // constraint probe — never stamped
        }
        // Pivot subtracted before yaw; integer voxel snap — the exact mapping
        // the scorer predicted with.
        ivec3 base_fp = rec.pos_strength.xyz - pivot_voxels;
        ivec3 rotated_fp = rot_count > 1 ? rotate_sample_offset_y(base_fp, rot_ca, rot_sa) : base_fp;
        ivec3 p = origin + rotated_fp;
        if (!in_grid_bounds(p) || !in_write_bounds(p)) {
            continue;
        }

        vec4 ad_rgba = unpack_rgba8(rec.color_rgba8);
        float ad_col_raw = clamp(float(rec.pos_strength.w) / 255.0, 0.0, 1.0);
        float complexity = ad_complexity_write_value(ad_rgba.a, params.y);
        float collision_strength = ad_collision_write_value(ad_col_raw, params.x, params.z);
        if (complexity <= 0.0 && collision_strength <= 0.0) {
            continue;
        }

        int index = voxel_index(p);
        uint packed_complexity = pack_rgba8(vec4(ad_rgba.rgb, complexity));
        if (complexity > 0.0) {
            atomic_max_complexity_rgba8(uint(index), packed_complexity);
        }
        if (collision_strength > 0.0) {
            atomic_max_collision_r8(uint(index), collision_strength);
        }
        if (params.w > 0.5) {
            if (complexity > 0.0) {
                atomic_max_commit_complexity_rgba8(uint(index), packed_complexity);
            }
            if (collision_strength > 0.0) {
                atomic_max_commit_collision_r8(uint(index), collision_strength);
            }
        }

        uint compact_index = atomicAdd(stamp_delta_count, 1u);
        if (compact_index < uint(max(write_max_pad.w, 0))) {
            uint delta_base = compact_index * DELTA_STRIDE;
            stamp_delta[delta_base + 0u] = vec4(vec3(p), complexity);
            stamp_delta[delta_base + 1u] = vec4(collision_strength, float(record_index), float(sample_index), 1.0);
        }
        write_stamp_bounds(record_index, p);
    }
}
