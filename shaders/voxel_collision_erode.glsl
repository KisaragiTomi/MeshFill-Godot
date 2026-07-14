#[compute]
#version 450

// Collision channel derivation from a solid occupancy volume.
// Dispatch one invocation per voxel. A solid voxel contributes to the collision
// channel when at least `min_neighbors` of its 6 face neighbours are solid
// (generalised morphological erosion).
//
//   min_neighbors = 6  -> classic full erosion: only fully-enclosed cores
//                         survive (large rock bodies). Thin sheets/branches drop.
//   min_neighbors < 6  -> looser: structures that are thin in one or two axes
//                         but stay connected along the remaining axis survive
//                         (e.g. a 1-voxel-thick but vertically continuous trunk).
//   min_neighbors = 1  -> any solid voxel touching at least one solid neighbour;
//                         only fully isolated single voxels (drifting leaves) drop.
//
// `min_neighbors` is read from grid_size.w; 0 is treated as the legacy default 6.
//
// Input occupancy_buf bit0 = solid.
// Output collision_buf: one uint32 per voxel, quantized unorm8 collision
// strength (0..255) in the low byte.

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer Occupancy {
    uint occupancy_buf[];
};

layout(set = 0, binding = 1, std430) restrict buffer CollisionField {
    uint collision_field_u32[];
};

layout(push_constant, std430) uniform Params {
    ivec4 grid_size;        // grid x, y, z, min_neighbors (0 -> 6)
    vec4 strength;          // collision strength, _pad, _pad, _pad
};

int voxel_index(ivec3 p) {
    return p.x + grid_size.x * (p.z + grid_size.z * p.y);
}

bool solid_at(ivec3 p) {
    if (p.x < 0 || p.y < 0 || p.z < 0
        || p.x >= grid_size.x || p.y >= grid_size.y || p.z >= grid_size.z) {
        return false;
    }
    return (occupancy_buf[voxel_index(p)] & 1u) == 1u;
}

uint quantize_unorm8(float value) {
    return uint(round(clamp(value, 0.0, 1.0) * 255.0));
}

// One uint32 per voxel; the output buffer is zero-initialised per dispatch, so
// atomicMax on the quantized value is equivalent to the old per-byte store.
void store_collision_r8(uint index, float value) {
    atomicMax(collision_field_u32[index], quantize_unorm8(value));
}

void main() {
    ivec3 p = ivec3(gl_GlobalInvocationID.xyz);
    if (p.x >= grid_size.x || p.y >= grid_size.y || p.z >= grid_size.z) {
        return;
    }

    int index = voxel_index(p);
    if (!solid_at(p)) {
        return;
    }

    bool core = solid_at(p + ivec3(1, 0, 0)) && solid_at(p + ivec3(-1, 0, 0))
        && solid_at(p + ivec3(0, 1, 0)) && solid_at(p + ivec3(0, -1, 0))
        && solid_at(p + ivec3(0, 0, 1)) && solid_at(p + ivec3(0, 0, -1));

    int min_neighbors = grid_size.w > 0 ? grid_size.w : 6;
    int neighbors = 0;
    neighbors += solid_at(p + ivec3(1, 0, 0)) ? 1 : 0;
    neighbors += solid_at(p + ivec3(-1, 0, 0)) ? 1 : 0;
    neighbors += solid_at(p + ivec3(0, 1, 0)) ? 1 : 0;
    neighbors += solid_at(p + ivec3(0, -1, 0)) ? 1 : 0;
    neighbors += solid_at(p + ivec3(0, 0, 1)) ? 1 : 0;
    neighbors += solid_at(p + ivec3(0, 0, -1)) ? 1 : 0;

    if (neighbors >= min_neighbors) {
        store_collision_r8(uint(index), strength.x);
    }
}
