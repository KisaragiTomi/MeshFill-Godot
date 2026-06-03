#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer SceneField {
    float scene_field[];
};

layout(set = 0, binding = 1) uniform sampler3D SceneVolume;

layout(set = 0, binding = 2) uniform sampler2D CollisionField;

layout(set = 0, binding = 3, std430) restrict buffer Counts {
    uint counts[];
};

layout(push_constant, std430) uniform Params {
    ivec4 dims;  // xz_res, total_slices, voxel_count, count_slots
    ivec4 modes; // use_scene_buffer, collision_width, collision_height, unused
    vec4 params; // occupied_threshold, unused, unused, unused
};

void main() {
    uint idx = gl_GlobalInvocationID.x;
    int voxel_count = max(dims.z, 0);
    if (idx >= uint(voxel_count)) {
        return;
    }

    int xz_res = max(dims.x, 0);
    int total_slices = max(dims.y, 0);
    int plane_voxels = xz_res * xz_res;
    if (xz_res <= 0 || total_slices <= 0 || plane_voxels <= 0) {
        return;
    }

    int slice_index = int(idx / uint(plane_voxels));
    if (slice_index < 0 || slice_index >= total_slices) {
        return;
    }

    int in_slice = int(idx - uint(slice_index * plane_voxels));
    int z = in_slice / xz_res;
    int x = in_slice - z * xz_res;
    float threshold = max(params.x, 0.0);

    float scene_value = 0.0;
    if (modes.x != 0) {
        scene_value = scene_field[idx];
    } else {
        scene_value = texelFetch(SceneVolume, ivec3(x, z, slice_index), 0).r;
    }

    if (scene_value > threshold && slice_index < dims.w) {
        atomicAdd(counts[slice_index], 1u);
    }

    int collision_slot = total_slices;
    if (
        slice_index == 0 &&
        collision_slot < dims.w &&
        x < modes.y &&
        z < modes.z &&
        texelFetch(CollisionField, ivec2(x, z), 0).r > threshold
    ) {
        atomicAdd(counts[collision_slot], 1u);
    }
}
