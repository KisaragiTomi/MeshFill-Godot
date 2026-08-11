#[compute]
#version 450

// Sparse scatter of committed stamp records into the persistent SV resident
// field buffers (stamp-only commit path). One thread per record. The CPU side
// dedupes records per voxel before upload, so no two threads write the same
// index; collision always merges via atomic max like stamp_voxel_field.glsl.
//
// write_mode 0 (overwrite): last write wins — brush overlay semantics.
// write_mode 1 (max-by-complexity): CAS keeps the higher packed alpha — the
// committed SV field may already hold VPG state-chain stamps the CPU compare
// gate never saw, so a monotonic merge protects them from downgrades.
//
// Record stride: 8 floats
//   0: voxel_x   1: voxel_z   2: slice_index   3: complexity (< 0 skips the complexity write)
//   4: color_r   5: color_g   6: color_b       7: collision_strength

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer ComplexityField {
    uint complexity_field_rgba8[];
};

layout(set = 0, binding = 1, std430) restrict buffer CollisionField {
    uint collision_field_u32[];
};

layout(set = 0, binding = 2, std430) restrict readonly buffer FieldRecords {
    float field_records[];
};

// 规范网格词汇（grid_x/y/z），与 SceneSV / BrushSV / BlendSV / TargetSV 其余通路同一套。
// 迁移前是 (xz_res, total_slices) 二元组 + `x + xz_res*(z + xz_res*slice)` 方形式：它把
// 「XZ 必须方形」编进了寻址，gx != gz 时写入的体素与 pick/score 读出的不是同一个。
layout(push_constant, std430) uniform Params {
    int grid_x;
    int grid_y;      // = slice 数
    int grid_z;
    int record_count;
    int write_mode;  // 0 = overwrite (brush overlay), 1 = max-by-complexity (committed SV)
};

const uint RECORD_FLOAT_STRIDE = 8u;

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

// Collision stores one quantized 0..255 value per uint32; unorm8 quantization
// preserves ordering, so a plain atomicMax is the monotonic merge.
void atomic_max_collision_r8(uint index, float value) {
    atomicMax(collision_field_u32[index], quantize_unorm8(value));
}

// pack_rgba8 keeps complexity in the low byte; a plain atomicMax would order
// by the red channel, so compare the alpha explicitly and CAS the whole word.
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

void main() {
    uint record_index = gl_GlobalInvocationID.x;
    if (record_index >= uint(max(record_count, 0))) {
        return;
    }
    uint base = record_index * RECORD_FLOAT_STRIDE;
    int x = int(field_records[base + 0u]);
    int z = int(field_records[base + 1u]);
    int slice_index = int(field_records[base + 2u]);
    if (x < 0 || x >= grid_x || z < 0 || z >= grid_z || slice_index < 0 || slice_index >= grid_y) {
        return;
    }
    float complexity_raw = field_records[base + 3u];
    vec3 color = vec3(
        field_records[base + 4u],
        field_records[base + 5u],
        field_records[base + 6u]
    );
    float collision_strength = clamp(field_records[base + 7u], 0.0, 1.0);

    // 规范索引式 x + gx * (z + gz * y)（= VoxelGeneral.voxel_index）。
    int index = x + grid_x * (z + grid_z * slice_index);
    if (complexity_raw >= 0.0) {
        uint packed_complexity = pack_rgba8(vec4(color, clamp(complexity_raw, 0.0, 1.0)));
        if (write_mode == 1) {
            atomic_max_complexity_rgba8(uint(index), packed_complexity);
        } else {
            complexity_field_rgba8[index] = packed_complexity;
        }
    }
    if (collision_strength > 0.0) {
        atomic_max_collision_r8(uint(index), collision_strength);
    }
}
