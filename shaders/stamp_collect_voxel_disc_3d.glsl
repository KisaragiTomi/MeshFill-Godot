#[compute]
#version 450

// Stamp a disc value across a set of R32 volume slices and collect changed
// voxels in a single 3D dispatch. The volume is a flattened R32 buffer:
//   idx = slice * xz_res * xz_res + z * xz_res + x
// One invocation processes one voxel of the cylinder (disc extruded along the
// gathered slices). It applies the same max-write stamp rule as
// stamp_r32_disc.glsl, then records changed voxels by compare_mode.
//
// Input and output are separate buffers (both seeded with the previous volume)
// so previous_value is always the clean pre-stamp value. This matters at image
// edges where the disc clamp maps several cells to the same index; an in-place
// buffer would let one invocation read another's written value.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer InVolume {
    float in_voxels[];
};

layout(set = 0, binding = 1, std430) restrict writeonly buffer OutVolume {
    float out_voxels[];
};

layout(set = 0, binding = 2, std430) restrict buffer PixelRecords {
    uvec4 records[]; // x, z, slice_local, previous_value_quant
};

layout(set = 0, binding = 3, std430) restrict buffer Counter {
    uint count;
};

layout(push_constant, std430) uniform Params {
    ivec4 dims;  // xz_res, depth, max_records, compare_mode
    ivec4 disc;  // center_x, center_z, radius, disc_size
    vec4 params; // value, occupied_epsilon, compare_slop, quant_scale
};

uint quantize_unit(float value) {
    return uint(round(clamp(value, 0.0, 1.0) * max(params.w, 1.0)));
}

void main() {
    int xz_res = dims.x;
    int depth = dims.y;
    int disc_size = max(disc.w, 0);

    ivec3 g = ivec3(gl_GlobalInvocationID);
    if (g.x >= disc_size || g.y >= disc_size || g.z >= depth) {
        return;
    }

    int radius = max(disc.z, 0);
    int dx = g.x - radius;
    int dz = g.y - radius;
    if (dx * dx + dz * dz > radius * radius) {
        return;
    }

    int x = clamp(disc.x + dx, 0, max(xz_res - 1, 0));
    int z = clamp(disc.y + dz, 0, max(xz_res - 1, 0));
    int slice = g.z;

    int idx = slice * xz_res * xz_res + z * xz_res + x;
    float previous_value = in_voxels[idx];

    // Stamp rule mirrors stamp_r32_disc.glsl: monotonic max-write inside the disc.
    float value = clamp(params.x, 0.0, 1.0);
    out_voxels[idx] = max(previous_value, value);

    // Record condition by compare_mode: 0 = grew, 1 = always, 2 = source compare.
    bool should_record = false;
    if (dims.w == 1) {
        should_record = true;
    } else if (dims.w == 2) {
        should_record = params.x > params.y && params.x + params.z >= previous_value;
    } else {
        should_record = params.x > previous_value;
    }
    if (!should_record) {
        return;
    }

    uint record_index = atomicAdd(count, 1u);
    if (record_index >= uint(max(dims.z, 0))) {
        return;
    }

    records[record_index] = uvec4(uint(x), uint(z), uint(slice), quantize_unit(previous_value));
}
