#[compute]
#version 450

// GPUAutoObjectRuntime accepted-placement writeback pass fed directly from the
// VPG resident placement buffers. Replaces the CPU record-dictionary bridge:
// no result/world/bounds readback, no CPU spawn-record packing. Object IDs are
// pre-reserved on the CPU (block reservation, count known from result_capacity)
// and consumed positionally via reserved_object_ids[record_index].
//
// Binding contract, set 0 (VPG-owned resident inputs):
//   0  readonly  placement_result_vec4x4 records (reduce output; origin_score.xyz = voxel origin)
//   1  readonly  world_result_vec4x4 records (placement_results_to_world output)
//   2  readonly  uvec4 stamp_bounds[]; 2 rows per record: (min.xyz, written_count), (max.xyz, pad)
//   3  readonly  int reserved_object_ids[]
//
// Binding contract, set 1 (runtime-owned state, mirrors autoobject_apply_accepted_placements.glsl):
//   0  int alive[]
//   1  readonly int generation[]
//   2  int object_type[]
//   3  int profile[]
//   4  int object_flags[]
//   5  ivec4 bounds_min[]
//   6  ivec4 bounds_max[]
//   7  ivec4 previous_bounds_min[]
//   8  ivec4 previous_bounds_max[]
//   9  mat4 transform[]
//   10 int dirty_delta_words[]; 20 s32 words per row, 80-byte stride
//   11 int dirty_count[1]
//   12 uint stats[]
//
// Push constants:
//   counts.x = record_count
//   counts.y = runtime_capacity
//   counts.z = dirty_delta_capacity
//   counts.w = dirty_base
//   asset_params.x = profile_id
//   asset_params.y = object_type
//   asset_params.z = object_flags
//   asset_params.w = dirty_flag_bits
//   meta.x = asset_index (report bookkeeping only)
//   meta.y = flush_epoch
//   meta.z = stats_capacity in u32 counters
//   meta.w = reserved
//   grid.xyz = grid_size (voxel bounds clamp), grid.w = reserved

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer PlacementResults {
    vec4 placement_results[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer WorldResults {
    vec4 world_results[];
};

layout(set = 0, binding = 2, std430) restrict readonly buffer StampBounds {
    uvec4 stamp_bounds[];
};

layout(set = 0, binding = 3, std430) restrict readonly buffer ReservedObjectIds {
    int reserved_object_ids[];
};

layout(set = 1, binding = 0, std430) restrict buffer Alive {
    int alive[];
};

layout(set = 1, binding = 1, std430) restrict readonly buffer Generation {
    int generation[];
};

layout(set = 1, binding = 2, std430) restrict buffer ObjectType {
    int object_type[];
};

layout(set = 1, binding = 3, std430) restrict buffer Profile {
    int profile[];
};

layout(set = 1, binding = 4, std430) restrict buffer ObjectFlags {
    int object_flags[];
};

layout(set = 1, binding = 5, std430) restrict buffer BoundsMin {
    ivec4 bounds_min[];
};

layout(set = 1, binding = 6, std430) restrict buffer BoundsMax {
    ivec4 bounds_max[];
};

layout(set = 1, binding = 7, std430) restrict buffer PreviousBoundsMin {
    ivec4 previous_bounds_min[];
};

layout(set = 1, binding = 8, std430) restrict buffer PreviousBoundsMax {
    ivec4 previous_bounds_max[];
};

layout(set = 1, binding = 9, std430) restrict buffer TransformBuffer {
    mat4 transforms[];
};

layout(set = 1, binding = 10, std430) restrict buffer DirtyDelta {
    int dirty_delta_words[];
};

layout(set = 1, binding = 11, std430) restrict buffer DirtyCount {
    int dirty_count[];
};

layout(set = 1, binding = 12, std430) restrict buffer Stats {
    uint stats[];
};

layout(push_constant, std430) uniform Params {
    ivec4 counts;
    ivec4 asset_params;
    ivec4 meta;
    ivec4 grid;
};

const uint RECORD_STRIDE_VEC4 = 4u;
const uint STAMP_BOUNDS_STRIDE_UVEC4 = 2u;
const uint DIRTY_DELTA_WORD_STRIDE = 20u;

const uint STAT_APPLIED = 0u;
const uint STAT_INVALID_OBJECT_ID = 1u;
const uint STAT_DIRTY_OVERFLOW = 2u;
const uint STAT_ALREADY_ALIVE = 3u;
const uint STAT_SKIPPED = 4u;
const uint STAT_RECORD_COUNT = 5u;
const uint STAT_DIRTY_BASE = 6u;
const uint STAT_DISPATCHED = 7u;

void stat_add(uint stat_index, uint amount) {
    if (amount == 0u || stat_index >= uint(max(meta.z, 0))) {
        return;
    }
    atomicAdd(stats[stat_index], amount);
}

void stat_store(uint stat_index, uint value) {
    if (stat_index >= uint(max(meta.z, 0))) {
        return;
    }
    stats[stat_index] = value;
}

void write_dirty_delta(uint dirty_index, int object_id, int object_generation, ivec3 voxel_min, ivec3 voxel_max) {
    uint base = dirty_index * DIRTY_DELTA_WORD_STRIDE;
    dirty_delta_words[base + 0u] = object_id;
    dirty_delta_words[base + 1u] = asset_params.y;
    dirty_delta_words[base + 2u] = asset_params.x;
    dirty_delta_words[base + 3u] = object_generation;
    dirty_delta_words[base + 4u] = voxel_min.x;
    dirty_delta_words[base + 5u] = voxel_min.y;
    dirty_delta_words[base + 6u] = voxel_min.z;
    dirty_delta_words[base + 7u] = 0;
    dirty_delta_words[base + 8u] = voxel_max.x;
    dirty_delta_words[base + 9u] = voxel_max.y;
    dirty_delta_words[base + 10u] = voxel_max.z;
    dirty_delta_words[base + 11u] = 1;
    dirty_delta_words[base + 12u] = voxel_min.x;
    dirty_delta_words[base + 13u] = voxel_min.y;
    dirty_delta_words[base + 14u] = voxel_min.z;
    dirty_delta_words[base + 15u] = asset_params.w;
    dirty_delta_words[base + 16u] = voxel_max.x;
    dirty_delta_words[base + 17u] = voxel_max.y;
    dirty_delta_words[base + 18u] = voxel_max.z;
    dirty_delta_words[base + 19u] = meta.y;
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
    uint record_index = gl_GlobalInvocationID.x;
    uint record_count = uint(max(counts.x, 0));
    if (record_index >= record_count) {
        return;
    }

    if (record_index == 0u) {
        stat_store(STAT_RECORD_COUNT, record_count);
        stat_store(STAT_DIRTY_BASE, uint(max(counts.w, 0)));
        stat_store(STAT_DISPATCHED, 1u);
    }

    int object_id = reserved_object_ids[record_index];
    if (object_id < 0 || object_id >= counts.y) {
        stat_add(STAT_INVALID_OBJECT_ID, 1u);
        stat_add(STAT_SKIPPED, 1u);
        return;
    }

    int dirty_index_i = counts.w + int(record_index);
    if (dirty_index_i < 0 || dirty_index_i >= counts.z) {
        stat_add(STAT_DIRTY_OVERFLOW, 1u);
        stat_add(STAT_SKIPPED, 1u);
        return;
    }

    if (alive[object_id] != 0) {
        stat_add(STAT_ALREADY_ALIVE, 1u);
        stat_add(STAT_SKIPPED, 1u);
        return;
    }

    uint result_base = record_index * RECORD_STRIDE_VEC4;
    vec4 world_origin_score = world_results[result_base + 0u];
    vec4 world_anchor = world_results[result_base + 1u];
    vec4 world_meta = world_results[result_base + 3u];
    if (world_meta.y <= 0.5) {
        stat_add(STAT_SKIPPED, 1u);
        return;
    }

    // Voxel bounds from the stamp pass, with the same fallback as the retired
    // CPU bridge: degenerate/empty bounds collapse to a single voxel at the
    // placement's voxel origin.
    ivec3 grid_size = max(grid.xyz, ivec3(1));
    uint bounds_base = record_index * STAMP_BOUNDS_STRIDE_UVEC4;
    uvec4 bounds_row0 = stamp_bounds[bounds_base + 0u];
    uvec4 bounds_row1 = stamp_bounds[bounds_base + 1u];
    ivec3 voxel_min = clamp(ivec3(bounds_row0.xyz), ivec3(0), grid_size);
    ivec3 voxel_max = clamp(ivec3(bounds_row1.xyz), ivec3(0), grid_size);
    bool bounds_valid = bounds_row0.w > 0u
        && voxel_max.x > voxel_min.x
        && voxel_max.y > voxel_min.y
        && voxel_max.z > voxel_min.z;
    if (!bounds_valid) {
        vec4 result_origin_score = placement_results[result_base + 0u];
        ivec3 voxel_origin = clamp(ivec3(round(result_origin_score.xyz)), ivec3(0), grid_size - ivec3(1));
        voxel_min = voxel_origin;
        voxel_max = voxel_origin + ivec3(1);
    }

    // Yaw-only transform via the shared canonical yaw block (yaw degrees in world_anchor.w).
    float yaw = radians(world_anchor.w);
    mat4 transform = yaw_transform_y(cos(yaw), sin(yaw), world_origin_score.xyz);

    int object_generation = generation[object_id];
    object_type[object_id] = asset_params.y;
    profile[object_id] = asset_params.x;
    object_flags[object_id] = asset_params.z;
    bounds_min[object_id] = ivec4(voxel_min, 0);
    bounds_max[object_id] = ivec4(voxel_max, 0);
    previous_bounds_min[object_id] = ivec4(voxel_min, 0);
    previous_bounds_max[object_id] = ivec4(voxel_max, 0);
    transforms[object_id] = transform;
    write_dirty_delta(uint(dirty_index_i), object_id, object_generation, voxel_min, voxel_max);
    alive[object_id] = 1;
    atomicAdd(dirty_count[0], 1);
    stat_add(STAT_APPLIED, 1u);
}
