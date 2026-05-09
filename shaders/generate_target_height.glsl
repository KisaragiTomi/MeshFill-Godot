#[compute]
#version 450

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D t_target_height;

layout(rgba16f, set = 1, binding = 0) uniform image2D rw_target_height;

layout(push_constant, std430) uniform Params {
    int dirty_x;
    int dirty_y;
    int dirty_w;
    int dirty_h;
};

const ivec2 neighbour_offset[4] = ivec2[4](
    ivec2(0, 1), ivec2(0, -1), ivec2(-1, 0), ivec2(1, 0)
);

shared vec2 share_m[32 + 2][32 + 2];

void main() {
    ivec2 dispatch_id = ivec2(gl_GlobalInvocationID.xy);
    ivec2 pos = ivec2(dirty_x + dispatch_id.x, dirty_y + dispatch_id.y);
    ivec2 local = ivec2(gl_LocalInvocationID.xy);

    ivec2 tex_size = textureSize(t_target_height, 0);
    int max_cell = tex_size.x - 1;
    ivec2 safe_pos = clamp(pos, ivec2(0), ivec2(max_cell));
    bool valid = dispatch_id.x < dirty_w && dispatch_id.y < dirty_h
                 && pos.x < tex_size.x && pos.y < tex_size.y;

    int pbs = 1;

    vec4 full_pixel = texelFetch(t_target_height, safe_pos, 0);
    share_m[local.x + pbs][local.y + pbs] = full_pixel.xy;

    if (local.x < pbs) {
        ivec2 fp = clamp(pos - ivec2(pbs, 0), ivec2(0), ivec2(max_cell));
        share_m[local.x][local.y + pbs] = texelFetch(t_target_height, fp, 0).xy;
    }
    if (local.x >= 32 - pbs) {
        ivec2 fp = clamp(pos + ivec2(pbs, 0), ivec2(0), ivec2(max_cell));
        share_m[local.x + pbs * 2][local.y + pbs] = texelFetch(t_target_height, fp, 0).xy;
    }
    if (local.y < pbs) {
        ivec2 fp = clamp(pos - ivec2(0, pbs), ivec2(0), ivec2(max_cell));
        share_m[local.x + pbs][local.y] = texelFetch(t_target_height, fp, 0).xy;
    }
    if (local.y >= 32 - pbs) {
        ivec2 fp = clamp(pos + ivec2(0, pbs), ivec2(0), ivec2(max_cell));
        share_m[local.x + pbs][local.y + pbs * 2] = texelFetch(t_target_height, fp, 0).xy;
    }

    barrier();

    for (int i = 0; i < 32 * 2; i++) {
        vec2 cur = share_m[local.x + pbs][local.y + pbs];
        if (cur.y >= 1.0) {
            for (int n = 0; n < 4; n++) {
                ivec2 off = local.xy + pbs + neighbour_offset[n];
                vec2 nb = share_m[off.x][off.y];
                if (nb.y < 1.0 && nb.x > cur.x) {
                    share_m[local.x + pbs][local.y + pbs] = vec2(nb.x, 0.0);
                }
            }
        }
        barrier();
    }

    if (!valid) return;

    vec2 result = share_m[local.x + pbs][local.y + pbs];
    imageStore(rw_target_height, pos, vec4(result.x, result.y, full_pixel.z, full_pixel.w));
}
