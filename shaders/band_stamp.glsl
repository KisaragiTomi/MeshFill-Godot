#[compute]
#version 450

// Stamps circular footprints into packed RGBA band occupancy.
// Each stamp position is read from an SSBO; one dispatch covers all stamps.
//
// Work strategy: each workgroup handles one stamp, threads tile the bounding box.
// local_size = 16×16 covers up to radius 8px per stamp without looping.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D rw_occupancy;

struct StampData {
    int px;           // center X in occupancy coords
    int py;           // center Y in occupancy coords
    int radius_px;    // stamp radius in pixels
    int _pad;
};

layout(std430, set = 1, binding = 0) readonly buffer StampBuffer {
    StampData stamps[];
};

layout(push_constant, std430) uniform Params {
    int band_channel;    // which RGBA channel to stamp into
    float complexity;    // value to write (color.a of the target band)
    int occ_res;         // occupancy texture resolution
    int stamp_count;     // total stamps in buffer
};

void main() {
    int stamp_idx = int(gl_WorkGroupID.z);
    if (stamp_idx >= stamp_count) return;

    StampData s = stamps[stamp_idx];
    ivec2 local = ivec2(gl_LocalInvocationID.xy);

    // Map local thread to offset within the stamp bounding box
    int dx = local.x - s.radius_px;
    int dy = local.y - s.radius_px;

    // If radius > 8, loop over the full bounding box
    int diameter = s.radius_px * 2 + 1;
    for (int oy = local.y; oy < diameter; oy += 16) {
        for (int ox = local.x; ox < diameter; ox += 16) {
            int ddx = ox - s.radius_px;
            int ddy = oy - s.radius_px;
            if (ddx * ddx + ddy * ddy > s.radius_px * s.radius_px) continue;

            int tx = clamp(s.px + ddx, 0, occ_res - 1);
            int ty = clamp(s.py + ddy, 0, occ_res - 1);

            vec4 cur = imageLoad(rw_occupancy, ivec2(tx, ty));
            cur[band_channel] = max(cur[band_channel], complexity);
            imageStore(rw_occupancy, ivec2(tx, ty), cur);
        }
    }
}
