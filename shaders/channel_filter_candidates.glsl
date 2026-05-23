#[compute]
#version 450

// Per-pixel candidate filtering for vegetation scatter.
// Reads packed RGBA channel occupancy → outputs candidate mask.
//
// A pixel is a valid candidate if:
//   For each channel in the profile mask, occupancy[channel] <= block_threshold
//
// Output: R = 1.0 if candidate, 0.0 if blocked.

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D t_occupancy;  // packed RGBA channel occupancy

layout(rgba16f, set = 1, binding = 0) uniform image2D rw_candidates;

layout(push_constant, std430) uniform Params {
    vec4 profile_mask;       // 1.0 in channels this profile checks, 0.0 otherwise
    float block_threshold;   // typically 0.01
    int base_res;
    int _pad0;
    int _pad1;
};

void main() {
    ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
    if (pos.x >= base_res || pos.y >= base_res) return;

    vec2 uv = (vec2(pos) + 0.5) / float(base_res);

    // Check occupancy: any profiled channel occupied → blocked
    vec4 occ = texture(t_occupancy, uv);
    // Dot product: if any channel where profile_mask=1 has occ > threshold → blocked
    vec4 blocked = step(vec4(block_threshold), occ) * profile_mask;
    float any_blocked = dot(blocked, vec4(1.0));

    if (any_blocked > 0.0) {
        imageStore(rw_candidates, pos, vec4(0.0));
        return;
    }

    // Valid candidate
    imageStore(rw_candidates, pos, vec4(1.0, 0.0, 0.0, 0.0));
}
