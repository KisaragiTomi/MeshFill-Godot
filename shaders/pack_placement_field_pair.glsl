#[compute]
#version 450

// GPU replacement for the CPU field-pack loops in run_multi_asset's
// non-resident path (SceneVoxelTileCodec.pack_complexity_field_rgba8_bytes +
// pack_collision_field_u32_bytes): the caller uploads the fitted scalar float
// fields raw (one memcpy each) and this pass quantizes them into the packed
// read-pair layout the scorer/stamp consume. One thread per voxel.
//
// Semantics replicate the CPU packers for the VPG call shape (fields
// pre-fitted to voxel_count scalars by VoxelGeneral.fit_float_array, so the
// codec's vec4 branch is unreachable there):
//   complexity: Color(1,1,1,v) -> rgba8 word (r=g=b=255, a=quantize(v))
//   collision:  quantize(v) in the u32 low byte, high bytes zero
// quantize(v) = clamp(round(clamp(v,0,1)*255), 0, 255) — written as
// floor(x+0.5) because GLSL round() halfway behavior is implementation-
// defined while GDScript round() is half-away-from-zero (equal on x >= 0).
// Precision caveat (deliberate 1-LSB tolerance, NOT bit-for-bit): GDScript
// multiplies in float64 while this shader is float32 — when the f32 product
// rounds up onto exactly k+0.5 the GPU lands 1/255 above the CPU (~9 ppm of
// uniform random inputs, one-sided). NaN inputs also diverge (clampf(NaN)
// yields 1.0 on the CPU, GLSL clamp(NaN) is undefined, typically 0). Both
// are accepted: golden snapshots are byte-identical on real field data.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer ComplexityValues {
    float complexity_values[];  // fitted scalar field, one float per voxel
};

layout(set = 0, binding = 1, std430) restrict readonly buffer CollisionValues {
    float collision_values[];   // fitted scalar field, one float per voxel
};

layout(set = 0, binding = 2, std430) restrict writeonly buffer ComplexityField {
    uint complexity_field_rgba8[];
};

layout(set = 0, binding = 3, std430) restrict writeonly buffer CollisionField {
    uint collision_field_u32[];  // quantized 0..255 in the low byte
};

layout(push_constant, std430) uniform Params {
    int voxel_count;
    int reserved0;
    int reserved1;
    int reserved2;
};

uint quantize_unorm8(float value) {
    return uint(floor(clamp(value, 0.0, 1.0) * 255.0 + 0.5));
}

void main() {
    uint index = gl_GlobalInvocationID.x;
    if (index >= uint(max(voxel_count, 0))) {
        return;
    }
    uint a = quantize_unorm8(complexity_values[index]);
    complexity_field_rgba8[index] = (255u << 24) | (255u << 16) | (255u << 8) | a;
    collision_field_u32[index] = quantize_unorm8(collision_values[index]);
}
