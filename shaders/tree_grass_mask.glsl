#[compute]
#version 450

// Build an RF grass placement mask around accepted tree pixels.
// Input:
//   set0/binding0: vec4 stamp records, xy = pixel center, z = value.
// Output:
//   set1/binding0: R32F mask, max stamp value inside radius.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer TreeStamps {
    vec4 stamps[];
};

layout(r32f, set = 1, binding = 0) uniform writeonly image2D rw_grass_mask;

layout(push_constant, std430) uniform Params {
    int width;
    int height;
    int stamp_count;
    int radius_px;
};

void main() {
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    if (p.x >= width || p.y >= height) {
        return;
    }

    int radius_sq = radius_px * radius_px;
    float best = 0.0;
    for (int i = 0; i < stamp_count; i++) {
        vec4 stamp = stamps[i];
        ivec2 center = ivec2(int(round(stamp.x)), int(round(stamp.y)));
        ivec2 delta = p - center;
        int dist_sq = delta.x * delta.x + delta.y * delta.y;
        if (dist_sq <= radius_sq) {
            best = max(best, stamp.z);
        }
    }

    imageStore(rw_grass_mask, p, vec4(best, 0.0, 0.0, 0.0));
}
