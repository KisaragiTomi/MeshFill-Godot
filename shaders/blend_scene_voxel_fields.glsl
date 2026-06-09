#[compute]
#version 450

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer AutoComplexity {
    float auto_source[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer BrushComplexity {
    float brush_source[];
};

layout(set = 0, binding = 2, std430) restrict buffer OutputComplexity {
    vec4 out_complexity[];
};

layout(set = 0, binding = 3, std430) restrict readonly buffer CommittedSceneVoxelPayloads {
    float committed_payloads[];
};

layout(set = 0, binding = 4, std430) restrict readonly buffer CommittedSceneVoxelKeyCoords {
    ivec4 committed_key_coords[];
};

layout(push_constant, std430) uniform Params {
    int key_count;
    int source_stride;
    int xz_res;
    int total_slices;
    int projection_mode;
    int committed_payload_stride;
    int committed_key_coord_stride_bytes;
    int _pad0;
};

const int SRC_COMPLEXITY = 0;
const int SRC_COLOR_R = 1;
const int SRC_COLOR_G = 2;
const int SRC_COLOR_B = 3;
const int SRC_HAS_SOURCE = 5;
const int SRC_AUTO_MIX = 6;
const int SRC_SLICE_INDEX = 8;
const int SRC_VOXEL_X = 9;
const int SRC_VOXEL_Z = 10;

const int OUT_COMPLEXITY = 0;
const int OUT_COLOR_R = 1;
const int OUT_COLOR_G = 2;
const int OUT_COLOR_B = 3;
const int OUT_SOURCE_SELECTOR = 5;
const int OUT_VALID = 7;

const int PROJECTION_SOURCE_STREAMS = 0;
const int PROJECTION_COMMITTED_PAYLOADS = 1;
const int COMMITTED_KEY_COORD_STRIDE_BYTES = 16;

void scatter_committed_payload_slot(uint idx) {
    if (committed_payload_stride < 8 || committed_key_coord_stride_bytes != COMMITTED_KEY_COORD_STRIDE_BYTES) {
        return;
    }

    uint payload_base = idx * uint(committed_payload_stride);
    bool payload_valid = committed_payloads[payload_base + OUT_VALID] > 0.5
        && committed_payloads[payload_base + OUT_SOURCE_SELECTOR] > 0.5;
    if (!payload_valid) {
        return;
    }

    ivec4 coord = committed_key_coords[idx];
    int slice_index = coord.x;
    int voxel_x = coord.y;
    int voxel_z = coord.z;
    if (
        voxel_x < 0 || voxel_x >= xz_res ||
        voxel_z < 0 || voxel_z >= xz_res ||
        slice_index < 0 || slice_index >= total_slices
    ) {
        return;
    }

    uint out_idx = uint(voxel_x + xz_res * (voxel_z + xz_res * slice_index));
    vec4 out_color = vec4(
        clamp(committed_payloads[payload_base + OUT_COLOR_R], 0.0, 1.0),
        clamp(committed_payloads[payload_base + OUT_COLOR_G], 0.0, 1.0),
        clamp(committed_payloads[payload_base + OUT_COLOR_B], 0.0, 1.0),
        clamp(committed_payloads[payload_base + OUT_COMPLEXITY], 0.0, 1.0)
    );
    out_complexity[out_idx] = out_color;
}

void main() {
    if (key_count <= 0) {
        return;
    }

    uint idx = gl_GlobalInvocationID.x;
    if (idx >= uint(key_count)) {
        return;
    }

    if (projection_mode == PROJECTION_COMMITTED_PAYLOADS) {
        scatter_committed_payload_slot(idx);
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

    vec3 out_rgb = vec3(0.0);
    if (has_brush) {
        out_value = has_auto
            ? mix(brush_value, auto_value, clamp(brush_source[brush_base + SRC_AUTO_MIX], 0.0, 1.0))
            : brush_value;
        out_rgb = vec3(
            clamp(brush_source[brush_base + SRC_COLOR_R], 0.0, 1.0),
            clamp(brush_source[brush_base + SRC_COLOR_G], 0.0, 1.0),
            clamp(brush_source[brush_base + SRC_COLOR_B], 0.0, 1.0)
        );
        if (has_auto) {
            out_rgb = mix(out_rgb, vec3(
                clamp(auto_source[auto_base + SRC_COLOR_R], 0.0, 1.0),
                clamp(auto_source[auto_base + SRC_COLOR_G], 0.0, 1.0),
                clamp(auto_source[auto_base + SRC_COLOR_B], 0.0, 1.0)
            ), clamp(brush_source[brush_base + SRC_AUTO_MIX], 0.0, 1.0));
        }
    } else if (has_auto) {
        out_rgb = vec3(
            clamp(auto_source[auto_base + SRC_COLOR_R], 0.0, 1.0),
            clamp(auto_source[auto_base + SRC_COLOR_G], 0.0, 1.0),
            clamp(auto_source[auto_base + SRC_COLOR_B], 0.0, 1.0)
        );
    }

    uint out_idx = uint(voxel_x + xz_res * (voxel_z + xz_res * slice_index));
    out_complexity[out_idx] = vec4(out_rgb, out_value);
}
