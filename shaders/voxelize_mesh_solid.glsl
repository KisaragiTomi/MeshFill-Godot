#[compute]
#version 450

// Solid mesh voxelization.
// Dispatch one invocation per voxel. For each voxel center, run an axis-aligned
// parity ray test against every mesh triangle along the +X, +Y and +Z axes, then
// majority-vote the three results so near-watertight (imported) meshes still fill
// as a solid volume instead of leaking through small gaps.
//
// Triangle buffer layout: 3 consecutive vec4 (xyz = local-space vertex) per
// triangle, vertices in mesh-local space.
//
// Output occupancy_buf: uint per voxel.
//   bit0 = solid (inside the volume)
//   bit1 = interior core (set later by voxel_shell_classify pass)
// Output color_buf: uint per voxel, RGBA8 packed asset color (only meaningful
// where bit0 is set).

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer Triangles {
    vec4 triangle_verts[];
};

layout(set = 0, binding = 1, std430) restrict buffer Occupancy {
    uint occupancy_buf[];
};

layout(set = 0, binding = 2, std430) restrict buffer ColorField {
    uint color_buf[];
};

layout(push_constant, std430) uniform Params {
    ivec4 grid_size;        // grid x, y, z, triangle_count
    vec4 aabb_min_cell;     // aabb_min.xyz, cell_size
    vec4 asset_color;       // rgb = color, a = complexity
};

int voxel_index(ivec3 p) {
    return p.x + grid_size.x * (p.z + grid_size.z * p.y);
}

uint pack_rgba8(vec4 c) {
    uint r = uint(clamp(c.r, 0.0, 1.0) * 255.0 + 0.5);
    uint g = uint(clamp(c.g, 0.0, 1.0) * 255.0 + 0.5);
    uint b = uint(clamp(c.b, 0.0, 1.0) * 255.0 + 0.5);
    uint a = uint(clamp(c.a, 0.0, 1.0) * 255.0 + 0.5);
    return r | (g << 8u) | (b << 16u) | (a << 24u);
}

// Parity test for a ray starting at world-space point `center` and travelling
// along +axis (0=x, 1=y, 2=z). Counts triangle crossings strictly ahead of the
// origin. Returns true when the crossing count is odd (inside the volume).
bool inside_along_axis(vec3 center, int axis, int tri_count) {
    // u/v are the two plane axes perpendicular to the ray axis.
    int u_axis = (axis + 1) % 3;
    int v_axis = (axis + 2) % 3;
    float pu = center[u_axis];
    float pv = center[v_axis];
    float pw = center[axis];

    uint crossings = 0u;
    for (int t = 0; t < tri_count; t++) {
        vec3 a = triangle_verts[t * 3 + 0].xyz;
        vec3 b = triangle_verts[t * 3 + 1].xyz;
        vec3 c = triangle_verts[t * 3 + 2].xyz;

        vec2 a2 = vec2(a[u_axis], a[v_axis]);
        vec2 b2 = vec2(b[u_axis], b[v_axis]);
        vec2 c2 = vec2(c[u_axis], c[v_axis]);

        // Barycentric point-in-triangle test in the projection plane.
        vec2 v0 = b2 - a2;
        vec2 v1 = c2 - a2;
        vec2 v2 = vec2(pu, pv) - a2;
        float den = v0.x * v1.y - v1.x * v0.y;
        if (abs(den) < 1e-12) {
            continue;
        }
        float inv = 1.0 / den;
        float w1 = (v2.x * v1.y - v1.x * v2.y) * inv;
        float w2 = (v0.x * v2.y - v2.x * v0.y) * inv;
        float w0 = 1.0 - w1 - w2;
        if (w0 < 0.0 || w1 < 0.0 || w2 < 0.0) {
            continue;
        }

        // Interpolate the ray-axis coordinate at the hit point.
        float hit_w = w0 * a[axis] + w1 * b[axis] + w2 * c[axis];
        if (hit_w > pw) {
            crossings++;
        }
    }
    return (crossings & 1u) == 1u;
}

void main() {
    ivec3 p = ivec3(gl_GlobalInvocationID.xyz);
    if (p.x >= grid_size.x || p.y >= grid_size.y || p.z >= grid_size.z) {
        return;
    }

    int tri_count = grid_size.w;
    int index = voxel_index(p);
    occupancy_buf[index] = 0u;
    color_buf[index] = 0u;
    if (tri_count <= 0) {
        return;
    }

    float cell = aabb_min_cell.w;
    vec3 center = aabb_min_cell.xyz + (vec3(p) + vec3(0.5)) * cell;

    int votes = 0;
    votes += inside_along_axis(center, 0, tri_count) ? 1 : 0;
    votes += inside_along_axis(center, 1, tri_count) ? 1 : 0;
    votes += inside_along_axis(center, 2, tri_count) ? 1 : 0;

    if (votes >= 2) {
        occupancy_buf[index] = 1u;
        color_buf[index] = pack_rgba8(asset_color);
    }
}