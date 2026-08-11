#[compute]
#version 450

// Fine-scorer private read-pair fusion pre-pass (batch T6): fuses the four
// heterogeneous per-voxel sample buffers score_anchor_asset_residual.glsl used
// to scatter-read (cur complexity rgba8-u32 + cur collision u32 + target vec4
// + target collision u32) into two scorer-private uvec2 pairs — one read per
// side instead of two. One thread per voxel, single dispatch fuses both sides:
//   cur_sample[i] = uvec2(cur_rgba8_word, cur_collision_word)
//   tgt_sample[i] = uvec2(tgt_rgba8_word, tgt_collision_word)
//
// Fidelity contract:
//   cur side: both words are copied VERBATIM (zero conversion, bit-for-bit) —
//     the resident/packed CurrentSV encoding never changes.
//   target side: target_field vec4 is quantized per channel with the same
//     formula as pack_placement_field_pair.glsl —
//     uint(floor(clamp(v,0,1)*255.0+0.5)) — packed r<<24|g<<16|b<<8|a
//     (a = complexity channel = vec4 .a, matching the scorer's unpack_rgba8).
//     f32 quantization tolerance: when the demo target env values are not
//     k/255 round-trips, the residual gain shifts by an expected <= ~2 q1000.
//     target_collision word is copied verbatim.
//
// The fused buffers are a scorer-private read-only derivation: the resident
// fields, stamp_asset_voxels.glsl, and every other consumer keep reading the
// original format pair — nothing else moves.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer CurComplexityField {
    uint complexity_field_rgba8[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer CurCollisionField {
    uint collision_field_u32[];  // one uint per voxel, quantized 0..255 in the low byte
};

layout(set = 0, binding = 2, std430) restrict readonly buffer TargetField {
    uint target_field_rgba8[];  // packed rgba8；与 SceneSV/BrushSV/BlendSV 同格式
};

layout(set = 0, binding = 3, std430) restrict readonly buffer TargetCollision {
    uint target_collision_u32[];  // one uint per voxel, quantized 0..255 in the low byte
};

layout(set = 0, binding = 4, std430) restrict writeonly buffer CurSamplePair {
    uvec2 cur_sample[];  // x = rgba8 word (verbatim), y = collision word (verbatim)
};

layout(set = 0, binding = 5, std430) restrict writeonly buffer TgtSamplePair {
    uvec2 tgt_sample[];  // x = quantized rgba8 word, y = collision word (verbatim)
};

layout(push_constant, std430) uniform Params {
    int voxel_count;
    int reserved0;
    int reserved1;
    int reserved2;
};


void main() {
    uint index = gl_GlobalInvocationID.x;
    if (index >= uint(max(voxel_count, 0))) {
        return;
    }
    cur_sample[index] = uvec2(complexity_field_rgba8[index], collision_field_u32[index]);
    // 目标场已是 packed rgba8：原先 unpack→re-quantize 的一来一回恒等（256 个字节值全部还原），
    // 现在退化为逐字复制。
    tgt_sample[index] = uvec2(target_field_rgba8[index], target_collision_u32[index]);
}
