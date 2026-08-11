#[compute]
#version 450

// Voxel field -> MultiMesh instance buffer, written directly into the buffer
// obtained from multimesh_get_buffer_rd_rid() on the MAIN RenderingDevice. One
// instance per grid cell (full grid); empty/below-threshold cells collapse to a
// zero basis so they render to nothing. No GPU->CPU readback anywhere.

layout(local_size_x = 64) in;

// Per-voxel occupancy / complexity, one uint per voxel, quantized 0..255 in the low byte.
layout(set = 0, binding = 0, std430) restrict readonly buffer Occupancy {
	uint occupancy_u32[];
};

// Per-voxel collision strength, one uint per voxel, quantized 0..255 in the low byte.
layout(set = 0, binding = 1, std430) restrict readonly buffer Collision {
	uint collision_u32[];
};

// Per-voxel color, RGBA8 packed into one uint per voxel, same indexing.
layout(set = 0, binding = 2, std430) restrict readonly buffer ColorField {
	uint color_rgba8[];
};

// Terrain world height, row-major size = grid_x * grid_z.
layout(set = 0, binding = 3, std430) restrict readonly buffer TerrainHeight {
	float terrain_height[];
};

// MultiMesh instance buffer (TRANSFORM_3D + use_colors): 16 floats per instance,
// 12 transform (3 rows of basis+origin) then 4 color.
layout(set = 0, binding = 4, std430) restrict writeonly buffer InstanceBuffer {
	float instances[];
};

// 紧凑显示的实例序 → 体素下标映射。use_index_map == 0 时本缓冲不被读取，
// 但仍必须绑定一个合法 SSBO（Vulkan 要求已声明的 binding 都有绑定），
// CPU 侧在那种情况下绑一块 4 字节占位。
layout(set = 0, binding = 5, std430) restrict readonly buffer InstanceVoxelIndex {
	int instance_voxel_index[];
};

// 坐标词汇与其余 volume 同款：grid_size / grid_origin / voxel_size。
// 实例位置 = grid_origin + (voxel + 0.5) * voxel_size，Y 再加 terrain * display_scale
// （TargetSV 的 Y 是地形相对带）。旧的 xz_res / capture_size / vertical_span 三元组
// 编码了「XZ 必须方形」与「端点铺开式」两条隐含假设，已由 CPU 侧
// VoxelGeneral.grid_frame_from_capture_endpoints 一次性换算掉。
layout(push_constant, std430) uniform Params {
	int voxel_count;
	int grid_x;
	int grid_y;        // = slice 数
	int grid_z;
	int view_mode;     // 0 target_color, 1 project_color, 2 complexity, 3 collision
	int terrain_len;
	float display_scale;
	float threshold;
	float grid_origin_x;
	float grid_origin_y;
	float grid_origin_z;
	float voxel_size_x;
	float voxel_size_y;
	float voxel_size_z;
	// 紧凑显示开关（原 pad0）。0 = 全网格：实例序 == 体素下标（TargetSV 的既有行为，逐位不变）。
	// 非 0 = 紧凑：实例序经 instance_voxel_index[] 映射到体素下标，voxel_count 此时是
	// **实例数**而不是网格体素总数。
	// ⚠ 开了它，CPU 侧的 pick 载荷解码也必须跟着走同一张表——否则点中的实例会被解成别的体素。
	int use_index_map;
	float pad1;
};

const int FLOATS_PER_INSTANCE = 16;

const int VIEW_TARGET_COLOR = 0;
const int VIEW_PROJECT_COLOR = 1;
const int VIEW_COMPLEXITY = 2;
const int VIEW_COLLISION = 3;

vec4 unpack_rgba8(uint packed) {
	return vec4(
		float((packed >> 24u) & 0xFFu) / 255.0,
		float((packed >> 16u) & 0xFFu) / 255.0,
		float((packed >>  8u) & 0xFFu) / 255.0,
		float((packed >>  0u) & 0xFFu) / 255.0
	);
}

float unpack_r8(uint value) {
	return float(value & 0xFFu) * (1.0 / 255.0);
}

float load_occupancy_r8(uint idx) {
	return unpack_r8(occupancy_u32[idx]);
}

float load_collision_r8(uint idx) {
	return unpack_r8(collision_u32[idx]);
}

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

	// 实例槽位始终按 idx 算（MultiMesh 的第 idx 个实例）；
	// 而“这个实例画的是哪一格”在紧凑模式下要经映射表。两者必须分开，
	// 混用会让紧凑模式把体素画到错误的实例槽上。
	uint base = idx * uint(FLOATS_PER_INSTANCE);
	uint vidx = (use_index_map != 0) ? uint(instance_voxel_index[idx]) : idx;

	float occ = load_occupancy_r8(vidx);
	float coll = load_collision_r8(vidx);

	bool visible;
	if (view_mode == VIEW_TARGET_COLOR) {
		visible = occ > threshold;
	} else {
		visible = max(occ, coll) > threshold;
	}
	if (!visible) {
		write_hidden(base);
		return;
	}

	// 规范索引式 index = x + gx * (z + gz * y)（VoxelGeneral.voxel_index 的逆解），
	// 非方形 XZ 同样成立；旧式 slice*xz*xz + z*xz + x 只在 gx == gz 时才碰巧一致。
	int gx = max(grid_x, 1);
	int gz = max(grid_z, 1);
	int plane = gx * gz;
	int slice_index = int(vidx) / plane;
	int rem = int(vidx) % plane;
	int vz = rem / gx;
	int vx = rem % gx;

	float fx = grid_origin_x + (float(vx) + 0.5) * voxel_size_x;
	float fz = grid_origin_z + (float(vz) + 0.5) * voxel_size_z;

	float terrain_y = 0.0;
	int height_idx = vz * gx + vx;
	if (vx >= 0 && vx < gx && vz >= 0 && vz < gz && height_idx < terrain_len) {
		terrain_y = terrain_height[height_idx];
	}
	float wy = grid_origin_y + (float(slice_index) + 0.5) * voxel_size_y + terrain_y * display_scale;

	vec4 src_rgba = unpack_rgba8(color_rgba8[vidx]);
	vec3 src_rgb = src_rgba.rgb;

	vec4 out_color;
	if (view_mode == VIEW_TARGET_COLOR) {
		// Faithful target color: show the baked Cd directly. Previously this
		// washed collision-heavy voxels toward a pale "sand" tint (coll * 0.45),
		// which turned high-collision cliffs near-white — the "Color" view must
		// not tint the target's own color. Cliff -> true grey, grass -> green.
		out_color = vec4(src_rgb, clamp(max(occ, 0.35), 0.35, 1.0));
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
