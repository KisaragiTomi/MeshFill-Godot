#[compute]
#version 450

// Voxel field -> MultiMesh instance buffer, written directly into the buffer
// obtained from multimesh_get_buffer_rd_rid() on the MAIN RenderingDevice. One
// instance per grid cell (full grid); empty/below-threshold cells collapse to a
// zero basis so they render to nothing. No GPU->CPU readback anywhere.

layout(local_size_x = 64) in;

// Per-voxel occupancy / complexity, linear idx = slice*xz*xz + z*xz + x.
layout(set = 0, binding = 0, std430) restrict readonly buffer Occupancy {
	float occupancy[];
};

// Per-voxel collision strength, same indexing as occupancy.
layout(set = 0, binding = 1, std430) restrict readonly buffer Collision {
	float collision[];
};

// Per-voxel color, 4 floats (rgba) per voxel, same indexing.
layout(set = 0, binding = 2, std430) restrict readonly buffer ColorField {
	float color_rgba[];
};

// Terrain world height, row-major size = xz_res * xz_res.
layout(set = 0, binding = 3, std430) restrict readonly buffer TerrainHeight {
	float terrain_height[];
};

// MultiMesh instance buffer (TRANSFORM_3D + use_colors): 16 floats per instance,
// 12 transform (3 rows of basis+origin) then 4 color.
layout(set = 0, binding = 4, std430) restrict writeonly buffer InstanceBuffer {
	float instances[];
};

layout(push_constant, std430) uniform Params {
	int voxel_count;
	int xz_res;
	int slice_count;
	int view_mode;     // 0 target_color, 1 project_color, 2 complexity, 3 collision
	float capture_size;
	float display_scale;
	float vertical_span;
	float height_span;
	float threshold;
	int terrain_len;
	float pad1;
	float pad2;
};

const int FLOATS_PER_INSTANCE = 16;

const int VIEW_TARGET_COLOR = 0;
const int VIEW_PROJECT_COLOR = 1;
const int VIEW_COMPLEXITY = 2;
const int VIEW_COLLISION = 3;

void write_hidden(uint base) {
	// Zero basis collapses the instance to a point; nothing rasterizes.
	for (uint i = 0u; i < uint(FLOATS_PER_INSTANCE); i++) {
		instances[base + i] = 0.0;
	}
}

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= uint(voxel_count)) {
		return;
	}

	uint base = idx * uint(FLOATS_PER_INSTANCE);

	float occ = clamp(occupancy[idx], 0.0, 1.0);
	float coll = clamp(collision[idx], 0.0, 1.0);

	bool visible;
	if (view_mode == VIEW_TARGET_COLOR) {
		visible = occupancy[idx] > threshold;
	} else {
		visible = max(occ, coll) > threshold;
	}
	if (!visible) {
		write_hidden(base);
		return;
	}

	int xz = xz_res;
	int slice_voxel_count = xz * xz;
	int slice_index = int(idx) / slice_voxel_count;
	int rem = int(idx) % slice_voxel_count;
	int vz = rem / xz;
	int vx = rem % xz;

	float denom = max(float(xz - 1), 1.0);
	float fx = (float(vx) / denom - 0.5) * capture_size * display_scale;
	float fz = (float(vz) / denom - 0.5) * capture_size * display_scale;

	float terrain_y = 0.0;
	int height_idx = vz * xz + vx;
	if (vx >= 0 && vx < xz && vz >= 0 && vz < xz && height_idx < terrain_len) {
		terrain_y = terrain_height[height_idx];
	}
	float local_y = (float(slice_index) + 0.5) / max(float(slice_count), 1.0) * vertical_span;
	float wy = (terrain_y + local_y) * display_scale;

	uint color_base = idx * 4u;
	vec3 src_rgb = vec3(color_rgba[color_base + 0u], color_rgba[color_base + 1u], color_rgba[color_base + 2u]);

	vec4 out_color;
	if (view_mode == VIEW_TARGET_COLOR) {
		vec3 sand = vec3(0.82, 0.78, 0.68);
		vec3 rgb = mix(src_rgb, sand, clamp(coll * 0.45, 0.0, 1.0));
		out_color = vec4(rgb, clamp(max(occ, 0.35), 0.35, 1.0));
	} else if (view_mode == VIEW_COMPLEXITY) {
		out_color = vec4(occ, occ, occ, clamp(max(occ, 0.55), 0.55, 1.0));
	} else if (view_mode == VIEW_COLLISION) {
		vec3 rgb = mix(vec3(0.12, 0.12, 0.14), vec3(1.0, 0.18, 0.02), coll);
		out_color = vec4(rgb, clamp(max(coll, 0.22), 0.22, 1.0));
	} else {
		out_color = vec4(src_rgb, clamp(max(occ, 0.55), 0.55, 1.0));
	}

	instances[base + 0u] = 1.0;
	instances[base + 1u] = 0.0;
	instances[base + 2u] = 0.0;
	instances[base + 3u] = fx;

	instances[base + 4u] = 0.0;
	instances[base + 5u] = 1.0;
	instances[base + 6u] = 0.0;
	instances[base + 7u] = wy;

	instances[base + 8u] = 0.0;
	instances[base + 9u] = 0.0;
	instances[base + 10u] = 1.0;
	instances[base + 11u] = fz;

	instances[base + 12u] = out_color.r;
	instances[base + 13u] = out_color.g;
	instances[base + 14u] = out_color.b;
	instances[base + 15u] = out_color.a;
}