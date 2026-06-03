#[compute]
#version 450

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer AutoScene {
    float auto_source[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer BrushScene {
    float brush_source[];
};

layout(set = 0, binding = 2, std430) restrict buffer OutputScene {
    float out_scene[];
};

layout(push_constant, std430) uniform Params {
    int key_count;
    int source_stride;
    int xz_res;
    int total_slices;
};

const int SRC_COMPLEXITY = 0;
const int SRC_HAS_SOURCE = 5;
const int SRC_AUTO_MIX = 6;
const int SRC_SLICE_INDEX = 8;
const int SRC_VOXEL_X = 9;
const int SRC_VOXEL_Z = 10;

void main() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= uint(key_count)) {
        return;
    }

    uint auto_base = idx * uint(source_stride);
    uint brush_base = idx * uint(source_stride);
    bool has_auto = auto_source[auto_base + SRC_HAS_SOURCE] > 0.5;
    bool has_brush = brush_source[brush_base + SRC_HAS_SOURCE] > 0.5;
    if (!has_auto && !has_brush) {
        return;
    }

    int slice_index = 0;
    int voxel_x = 0;
    int voxel_z = 0;
    if (has_brush) {
        slice_index = int(brush_source[brush_base + SRC_SLICE_INDEX] + 0.5);
        voxel_x = int(brush_source[brush_base + SRC_VOXEL_X] + 0.5);
        voxel_z = int(brush_source[brush_base + SRC_VOXEL_Z] + 0.5);
    } else {
        slice_index = int(auto_source[auto_base + SRC_SLICE_INDEX] + 0.5);
        voxel_x = int(auto_source[auto_base + SRC_VOXEL_X] + 0.5);
        voxel_z = int(auto_source[auto_base + SRC_VOXEL_Z] + 0.5);
    }

    if (
        voxel_x < 0 || voxel_x >= xz_res ||
        voxel_z < 0 || voxel_z >= xz_res ||
        slice_index < 0 || slice_index >= total_slices
    ) {
        return;
    }

    float auto_value = has_auto ? clamp(auto_source[auto_base + SRC_COMPLEXITY], 0.0, 1.0) : 0.0;
    float brush_value = has_brush ? clamp(brush_source[brush_base + SRC_COMPLEXITY], 0.0, 1.0) : 0.0;
    float out_value = auto_value;
    if (has_brush) {
        out_value = has_auto
            ? mix(brush_value, auto_value, clamp(brush_source[brush_base + SRC_AUTO_MIX], 0.0, 1.0))
            : brush_value;
    }

    uint out_idx = uint(voxel_x + xz_res * (voxel_z + xz_res * slice_index));
    out_scene[out_idx] = out_value;
}
