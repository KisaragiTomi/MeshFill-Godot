#[compute]
#version 450

// Finalizes resident route adapter count into Vulkan indirect dispatch args.
// Count buffer words:
//   x = compact valid candidate count
//   y = bounded record reads
//   z = truncation/overflow diagnostics
//   w = magic/reserved
// Indirect args layout is 3 uints: group_count_x, group_count_y, group_count_z.

layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer CandidateRouteAdapterCount {
    uint candidate_route_adapter_count[];
};

layout(set = 0, binding = 1, std430) restrict buffer CandidateRouteIndirectArgs {
    uint candidate_route_indirect_args[];
};

layout(push_constant, std430) uniform Params {
    ivec4 route;
    int resident_route_record_capacity;
};

void main() {
    candidate_route_indirect_args[0] = candidate_route_adapter_count[0];
    candidate_route_indirect_args[1] = 1u;
    candidate_route_indirect_args[2] = 1u;
}
