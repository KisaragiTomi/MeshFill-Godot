#[compute]
#version 450

// GPUAutoObjectRuntime accepted-placement record writeback pass.
//
// Binding contract, set 0:
//   0  readonly AcceptedPlacementRecord records[]; 128-byte stride
//   1  int alive[]
//   2  readonly int generation[]
//   3  int object_type[]
//   4  int profile[]
//   5  int object_flags[]
//   6  ivec4 bounds_min[]
//   7  ivec4 bounds_max[]
//   8  ivec4 previous_bounds_min[]
//   9  ivec4 previous_bounds_max[]
//   10 mat4 transform[]
//   11 int dirty_delta_words[]; 20 s32 words per row, 80-byte stride
//   12 int dirty_count[1]
//   13 uint stats[]
//   14 int asset_index[]                # 渲染批次的分批键；profile_id 一对多，顶替不了
//
// Push constants:
//   counts.x = record_count
//   counts.y = runtime_capacity
//   counts.z = dirty_delta_capacity
//   counts.w = dirty_base
//   options.x = flush_epoch
//   options.y = option bits, currently reserved
//   options.z = stats_capacity in u32 counters
//   options.w = reserved

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

struct AcceptedPlacementRecord {
    int object_id;
    int profile_id;
    int object_type;
    int object_flags;
    ivec4 voxel_min;
    ivec4 voxel_max;
    mat4 transform;
    int dirty_flags;
    int asset_index;
    int result_index;
    int reserved;
};

layout(set = 0, binding = 0, std430) restrict readonly buffer AcceptedRecords {
    AcceptedPlacementRecord records[];
};

layout(set = 0, binding = 1, std430) restrict buffer Alive {
    int alive[];
};

layout(set = 0, binding = 2, std430) restrict readonly buffer Generation {
    int generation[];
};

layout(set = 0, binding = 3, std430) restrict buffer ObjectType {
    int object_type[];
};

layout(set = 0, binding = 4, std430) restrict buffer Profile {
    int profile[];
};

layout(set = 0, binding = 5, std430) restrict buffer ObjectFlags {
    int object_flags[];
};

layout(set = 0, binding = 6, std430) restrict buffer BoundsMin {
    ivec4 bounds_min[];
};

layout(set = 0, binding = 7, std430) restrict buffer BoundsMax {
    ivec4 bounds_max[];
};

layout(set = 0, binding = 8, std430) restrict buffer PreviousBoundsMin {
    ivec4 previous_bounds_min[];
};

layout(set = 0, binding = 9, std430) restrict buffer PreviousBoundsMax {
    ivec4 previous_bounds_max[];
};

layout(set = 0, binding = 10, std430) restrict buffer TransformBuffer {
    mat4 transforms[];
};

layout(set = 0, binding = 11, std430) restrict buffer DirtyDelta {
    int dirty_delta_words[];
};

layout(set = 0, binding = 12, std430) restrict buffer DirtyCount {
    int dirty_count[];
};

layout(set = 0, binding = 13, std430) restrict buffer Stats {
    uint stats[];
};

layout(set = 0, binding = 14, std430) restrict buffer AssetIndexBuffer {
    int object_asset_index[];
};

layout(push_constant, std430) uniform Params {
    ivec4 counts;
    ivec4 options;
};

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
    if (amount == 0u || stat_index >= uint(max(options.z, 0))) {
        return;
    }
    atomicAdd(stats[stat_index], amount);
}

void stat_store(uint stat_index, uint value) {
    if (stat_index >= uint(max(options.z, 0))) {
        return;
    }
    stats[stat_index] = value;
}

void write_dirty_delta(uint dirty_index, AcceptedPlacementRecord record, int object_generation) {
    uint base = dirty_index * DIRTY_DELTA_WORD_STRIDE;
    dirty_delta_words[base + 0u] = record.object_id;
    dirty_delta_words[base + 1u] = record.object_type;
    dirty_delta_words[base + 2u] = record.profile_id;
    dirty_delta_words[base + 3u] = object_generation;
    dirty_delta_words[base + 4u] = record.voxel_min.x;
    dirty_delta_words[base + 5u] = record.voxel_min.y;
    dirty_delta_words[base + 6u] = record.voxel_min.z;
    dirty_delta_words[base + 7u] = 0;
    dirty_delta_words[base + 8u] = record.voxel_max.x;
    dirty_delta_words[base + 9u] = record.voxel_max.y;
    dirty_delta_words[base + 10u] = record.voxel_max.z;
    dirty_delta_words[base + 11u] = 1;
    dirty_delta_words[base + 12u] = record.voxel_min.x;
    dirty_delta_words[base + 13u] = record.voxel_min.y;
    dirty_delta_words[base + 14u] = record.voxel_min.z;
    dirty_delta_words[base + 15u] = record.dirty_flags;
    dirty_delta_words[base + 16u] = record.voxel_max.x;
    dirty_delta_words[base + 17u] = record.voxel_max.y;
    dirty_delta_words[base + 18u] = record.voxel_max.z;
    dirty_delta_words[base + 19u] = options.x;
}

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

    AcceptedPlacementRecord record = records[record_index];
    int object_id = record.object_id;
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

    int object_generation = generation[object_id];
    object_type[object_id] = record.object_type;
    profile[object_id] = record.profile_id;
    object_flags[object_id] = record.object_flags;
    object_asset_index[object_id] = record.asset_index;
    bounds_min[object_id] = record.voxel_min;
    bounds_max[object_id] = record.voxel_max;
    previous_bounds_min[object_id] = record.voxel_min;
    previous_bounds_max[object_id] = record.voxel_max;
    transforms[object_id] = record.transform;
    write_dirty_delta(uint(dirty_index_i), record, object_generation);
    alive[object_id] = 1;
    atomicAdd(dirty_count[0], 1);
    stat_add(STAT_APPLIED, 1u);
}
