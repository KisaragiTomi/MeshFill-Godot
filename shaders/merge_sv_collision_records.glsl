#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer CollisionField {
    uint collision_field_u32[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer CollisionRecords {
    vec4 records[]; // x, z, slice, collision_strength
};

layout(push_constant, std430) uniform Params {
    ivec4 dims_counts; // xz_res, total_slices, voxel_count, record_count
};

uint quantize_unorm8(float value) {
    return uint(round(clamp(value, 0.0, 1.0) * 255.0));
}

// Collision stores one quantized 0..255 value per uint32; unorm8 quantization
// preserves ordering, so a plain atomicMax is the monotonic merge.
void atomic_max_r8(uint index, float value) {
    atomicMax(collision_field_u32[index], quantize_unorm8(value));
}

void main() {
    uint record_index = gl_GlobalInvocationID.x;
    if (record_index >= uint(max(dims_counts.w, 0))) {
        return;
    }

    vec4 record = records[record_index];
    int x = int(record.x + 0.5);
    int z = int(record.y + 0.5);
    int y = int(record.z + 0.5);
    if (
        x < 0 || x >= dims_counts.x ||
        z < 0 || z >= dims_counts.x ||
        y < 0 || y >= dims_counts.y
    ) {
        return;
    }

    int idx = x + dims_counts.x * (z + dims_counts.x * y);
    if (idx < 0 || idx >= dims_counts.z) {
        return;
    }

    atomic_max_r8(uint(idx), record.w);
}
