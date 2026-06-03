#[compute]
#version 450

// Copies the selected resident route range into the score pass sparse candidate
// ID buffer. Records/ranges are schema v1 uvec4 entries (16 bytes each):
//   range.xy = record_start, record_count
//   record.x = sparse tile id

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer CandidateRouteRecords {
    uvec4 candidate_route_records[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer CandidateRouteRanges {
    uvec4 candidate_route_ranges[];
};

layout(set = 0, binding = 2, std430) restrict buffer CandidateVoxelRegions {
    uint candidate_voxel_sparse_ids[];
};

layout(set = 0, binding = 3, std430) restrict buffer CandidateRouteBindingDebug {
    uint candidate_route_binding_debug[];
};

layout(set = 0, binding = 4, std430) restrict buffer CandidateRouteAdapterCount {
    uint candidate_route_adapter_count[];
};

layout(push_constant, std430) uniform Params {
    ivec4 route; // asset_index, range_count, tile_count, output_capacity
    int resident_route_record_capacity;
};

void main() {
    uint record_index_in_range = gl_GlobalInvocationID.x;
    uint range_count = uint(max(route.y, 0));
    uint tile_count = uint(max(route.z, 0));
    uint output_capacity = uint(max(route.w, 0));
    uint record_capacity = uint(max(resident_route_record_capacity, 0));
    if (record_index_in_range >= output_capacity) return;

    if (range_count == 0u || tile_count == 0u || record_capacity == 0u) return;

    uint range_index = min(uint(max(route.x, 0)), range_count - 1u);
    uvec4 route_range = candidate_route_ranges[range_index];
    uint record_start = route_range.x;
    uint record_count = route_range.y;

    if (record_index_in_range == 0u) {
        candidate_route_binding_debug[10] = range_index;
        candidate_route_binding_debug[11] = output_capacity;
        candidate_route_binding_debug[12] = record_start;
        candidate_route_binding_debug[13] = record_count;
        candidate_route_binding_debug[14] = record_capacity;
        candidate_route_adapter_count[1] = min(record_count, output_capacity);
        candidate_route_adapter_count[2] = record_count > output_capacity ? record_count - output_capacity : 0u;
        candidate_route_adapter_count[3] = 0x52414341u; // "RACA"
    }

    if (record_index_in_range >= record_count) return;
    if (record_start >= record_capacity || record_index_in_range >= record_capacity - record_start) return;

    uvec4 route_record = candidate_route_records[record_start + record_index_in_range];
    atomicAdd(candidate_route_binding_debug[9], 1u);

    uint tile_id = route_record.x;
    if (tile_id >= tile_count) return;

    for (uint prior = 0u; prior < record_index_in_range; prior++) {
        uvec4 prior_record = candidate_route_records[record_start + prior];
        if (prior_record.x == tile_id) return;
    }

    uint write_index = atomicAdd(candidate_route_adapter_count[0], 1u);
    if (write_index >= output_capacity) {
        atomicAdd(candidate_route_adapter_count[2], 1u);
        return;
    }

    candidate_voxel_sparse_ids[write_index] = tile_id;
    atomicAdd(candidate_route_binding_debug[8], 1u);
}
