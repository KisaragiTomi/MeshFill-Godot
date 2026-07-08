#[compute]
#version 450

// Composes the on-demand BlendSV field pair from the committed (auto-only) SV
// resident fields and the SPA-resident BrushSV overlay fields.
// One thread per voxel:
//   complexity: brush overrides where painted (brush alpha > 0), else auto.
//   collision:  max(auto, brush) — physical sampling must see both.
// BlendSV is a transient read product (placement 3D score / TargetSV compare);
// it is never committed back.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer AutoComplexityField {
    uint auto_complexity_rgba8[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer AutoCollisionField {
    uint auto_collision_r8_words[];
};

layout(set = 0, binding = 2, std430) restrict readonly buffer BrushComplexityField {
    uint brush_complexity_rgba8[];
};

layout(set = 0, binding = 3, std430) restrict readonly buffer BrushCollisionField {
    uint brush_collision_r8_words[];
};

layout(set = 0, binding = 4, std430) restrict writeonly buffer BlendComplexityField {
    uint blend_complexity_rgba8[];
};

layout(set = 0, binding = 5, std430) restrict writeonly buffer BlendCollisionField {
    uint blend_collision_r8_words[];
};

layout(push_constant, std430) uniform Params {
    int voxel_count;
    int collision_word_count;
    int reserved0;
    int reserved1;
};

void main() {
    uint index = gl_GlobalInvocationID.x;

    if (index < uint(max(voxel_count, 0))) {
        uint auto_packed = auto_complexity_rgba8[index];
        uint brush_packed = brush_complexity_rgba8[index];
        uint brush_alpha = brush_packed & 0xFFu;
        blend_complexity_rgba8[index] = brush_alpha > 0u ? brush_packed : auto_packed;
    }

    // Collision packs 4 R8 voxels per word; a per-word pass covers all lanes.
    if (index < uint(max(collision_word_count, 0))) {
        uint auto_word = auto_collision_r8_words[index];
        uint brush_word = brush_collision_r8_words[index];
        uint merged = 0u;
        for (uint lane = 0u; lane < 4u; lane++) {
            uint shift = lane * 8u;
            uint a = (auto_word >> shift) & 0xFFu;
            uint b = (brush_word >> shift) & 0xFFu;
            merged |= max(a, b) << shift;
        }
        blend_collision_r8_words[index] = merged;
    }
}
