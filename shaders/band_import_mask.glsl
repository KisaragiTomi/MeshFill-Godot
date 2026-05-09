#[compute]
#version 450

// Imports a source mask into a specific channel of the packed RGBA band occupancy.
// Each RGBA channel represents one height band; pixel value = complexity when occupied.

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D t_source_mask;

layout(rgba16f, set = 1, binding = 0) uniform image2D rw_occupancy;

layout(push_constant, std430) uniform Params {
    int band_channel;      // 0=R(ground), 1=G(understory), 2=B(midstory), 3=A(canopy)
    float complexity;      // color.a — value to write when source > threshold
    float threshold;       // import threshold (default 0.01)
    int out_res;           // output (band) resolution
};

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    if (pos.x >= out_res || pos.y >= out_res) return;

    // Resample source mask to output resolution via normalized UV
    vec2 uv = (vec2(pos) + 0.5) / float(out_res);
    float src_val = texture(t_source_mask, uv).r;

    if (src_val <= threshold) return;

    // Read current occupancy, write complexity into the target channel
    vec4 cur = imageLoad(rw_occupancy, pos);
    cur[band_channel] = max(cur[band_channel], complexity);
    imageStore(rw_occupancy, pos, cur);
}
