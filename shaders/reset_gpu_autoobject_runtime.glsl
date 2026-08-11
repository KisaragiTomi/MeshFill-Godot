#[compute]
#version 450

// Resets the fixed-capacity GPU AutoObject state in place.
// Inputs: object capacity and dirty-delta capacity.
// Outputs: zeroed object records, transforms, dirty deltas, and dirty count.
// The owner submits and synchronizes before the empty benchmark fixture is used.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict writeonly buffer AliveBuffer { uint alive[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer GenerationBuffer { uint generation[]; };
layout(set = 0, binding = 2, std430) restrict writeonly buffer TypeBuffer { uint object_type[]; };
layout(set = 0, binding = 3, std430) restrict writeonly buffer ProfileBuffer { uint profile[]; };
layout(set = 0, binding = 4, std430) restrict writeonly buffer FlagsBuffer { uint flags[]; };
layout(set = 0, binding = 5, std430) restrict writeonly buffer BoundsMinBuffer { uint bounds_min[]; };
layout(set = 0, binding = 6, std430) restrict writeonly buffer BoundsMaxBuffer { uint bounds_max[]; };
layout(set = 0, binding = 7, std430) restrict writeonly buffer PreviousBoundsMinBuffer { uint previous_bounds_min[]; };
layout(set = 0, binding = 8, std430) restrict writeonly buffer PreviousBoundsMaxBuffer { uint previous_bounds_max[]; };
layout(set = 0, binding = 9, std430) restrict writeonly buffer TransformBuffer { uint transforms[]; };
layout(set = 0, binding = 10, std430) restrict writeonly buffer DirtyDeltaBuffer { uint dirty_deltas[]; };
layout(set = 0, binding = 11, std430) restrict writeonly buffer DirtyCountBuffer { uint dirty_count[]; };
// asset_index 常驻 SoA：渲染批次的分批键（每个 asset 一个 descriptor.get_mesh()）。
// 显式归零而不是依赖分配期的隐式零值——reset 之后 alive 也是 0，但让两者由同一趟 pass
// 写出，避免"重置过的槽位 asset_index 还留着上一轮的值"这类只在回读诊断里才现形的脏状态。
layout(set = 0, binding = 12, std430) restrict writeonly buffer AssetIndexBuffer { uint asset_index[]; };

layout(push_constant, std430) uniform Params {
    int object_capacity;
    int dirty_delta_capacity;
    int transform_uint_stride;
    int dirty_delta_uint_stride;
};

void main() {
    uint index = gl_GlobalInvocationID.x;
    if (index < uint(max(object_capacity, 0))) {
        alive[index] = 0u;
        generation[index] = 0u;
        object_type[index] = 0u;
        profile[index] = 0u;
        flags[index] = 0u;
        asset_index[index] = 0u;

        uint bounds_base = index * 4u;
        for (uint word = 0u; word < 4u; word++) {
            bounds_min[bounds_base + word] = 0u;
            bounds_max[bounds_base + word] = 0u;
            previous_bounds_min[bounds_base + word] = 0u;
            previous_bounds_max[bounds_base + word] = 0u;
        }

        uint transform_base = index * uint(max(transform_uint_stride, 1));
        for (uint word = 0u; word < uint(max(transform_uint_stride, 1)); word++) {
            transforms[transform_base + word] = 0u;
        }
    }

    if (index < uint(max(dirty_delta_capacity, 0))) {
        uint dirty_base = index * uint(max(dirty_delta_uint_stride, 1));
        for (uint word = 0u; word < uint(max(dirty_delta_uint_stride, 1)); word++) {
            dirty_deltas[dirty_base + word] = 0u;
        }
    }

    if (index == 0u) {
        dirty_count[0] = 0u;
    }
}
