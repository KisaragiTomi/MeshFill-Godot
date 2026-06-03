#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D PreviousField;

layout(set = 0, binding = 1, std430) restrict buffer PixelRecords {
    uvec4 records[]; // x, z, previous_value_quant, unused
};

layout(set = 0, binding = 2, std430) restrict buffer Counter {
    uint count;
};

layout(push_constant, std430) uniform Params {
    ivec4 dims; // width, height, max_records, compare_mode
    ivec4 disc; // center_x, center_z, radius, disc_size
    vec4 params; // value, occupied_epsilon, compare_slop, quant_scale
};

uint quantize_unit(float value) {
    return uint(round(clamp(value, 0.0, 1.0) * max(params.w, 1.0)));
}

void main() {
    ivec2 local_p = ivec2(gl_GlobalInvocationID.xy);
    int disc_size = max(disc.w, 0);
    if (local_p.x >= disc_size || local_p.y >= disc_size) {
        return;
    }

    int radius = max(disc.z, 0);
    int dx = local_p.x - radius;
    int dz = local_p.y - radius;
    if (dx * dx + dz * dz > radius * radius) {
        return;
    }

    int x = clamp(disc.x + dx, 0, max(dims.x - 1, 0));
    int z = clamp(disc.y + dz, 0, max(dims.y - 1, 0));
    float previous_value = texelFetch(PreviousField, ivec2(x, z), 0).r;
    bool should_write = false;
    if (dims.w == 1) {
        should_write = true;
    } else if (dims.w == 2) {
        should_write = params.x > params.y && params.x + params.z >= previous_value;
    } else {
        should_write = params.x > previous_value;
    }
    if (!should_write) {
        return;
    }

    uint record_index = atomicAdd(count, 1u);
    if (record_index >= uint(max(dims.z, 0))) {
        return;
    }

    records[record_index] = uvec4(uint(x), uint(z), quantize_unit(previous_value), 0u);
}
