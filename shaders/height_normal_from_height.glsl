#[compute]
#version 450

// Build RGBA32F terrain normals from a scalar or RGBA height buffer.
// Binding order must match HeightNormalFromHeightGPU:
//   set 0 binding 0: float height_values, one R32F height per pixel, or RGBA32F with push-constant stride=4
//   set 0 binding 1: float normal_values, RGBA32F output (nx, ny, nz, 0)
//   set 0 binding 2: uint32 stats: steep_count, min_nz_key, max_nz_key

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer HeightIn {
	float height_values[];
};

layout(set = 0, binding = 1, std430) restrict writeonly buffer NormalOut {
	float normal_values[];
};

layout(set = 0, binding = 2, std430) coherent buffer StatsOut {
	uint steep_count;
	uint min_nz_key;
	uint max_nz_key;
};

layout(push_constant, std430) uniform Params {
	int width;
	int height;
	float cell_size;
	float steep_nz_threshold;
	int input_stride;
	int height_channel;
} params;

uint float_to_ordered(float value) {
	uint bits = floatBitsToUint(value);
	if ((bits & 0x80000000u) != 0u) {
		return ~bits;
	}
	return bits ^ 0x80000000u;
}

float height_at(int x, int y) {
	x = clamp(x, 0, params.width - 1);
	y = clamp(y, 0, params.height - 1);
	int safe_stride = max(params.input_stride, 1);
	int safe_channel = clamp(params.height_channel, 0, safe_stride - 1);
	return height_values[uint((y * params.width + x) * safe_stride + safe_channel)];
}

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= params.width || p.y >= params.height) {
		return;
	}

	float safe_cell = max(params.cell_size, 0.000001);
	float dx;
	if (params.width <= 1) {
		dx = 0.0;
	} else if (p.x == 0) {
		dx = (height_at(1, p.y) - height_at(0, p.y)) / safe_cell;
	} else if (p.x == params.width - 1) {
		dx = (height_at(p.x, p.y) - height_at(p.x - 1, p.y)) / safe_cell;
	} else {
		dx = (height_at(p.x + 1, p.y) - height_at(p.x - 1, p.y)) / (2.0 * safe_cell);
	}

	float dy;
	if (params.height <= 1) {
		dy = 0.0;
	} else if (p.y == 0) {
		dy = (height_at(p.x, 1) - height_at(p.x, 0)) / safe_cell;
	} else if (p.y == params.height - 1) {
		dy = (height_at(p.x, p.y) - height_at(p.x, p.y - 1)) / safe_cell;
	} else {
		dy = (height_at(p.x, p.y + 1) - height_at(p.x, p.y - 1)) / (2.0 * safe_cell);
	}

	vec3 normal = normalize(vec3(-dx, -dy, 1.0));
	uint idx = uint(p.y * params.width + p.x);
	uint out_index = idx * 4u;
	normal_values[out_index + 0u] = normal.x;
	normal_values[out_index + 1u] = normal.y;
	normal_values[out_index + 2u] = normal.z;
	normal_values[out_index + 3u] = 0.0;

	if (normal.z < params.steep_nz_threshold) {
		atomicAdd(steep_count, 1u);
	}
	uint nz_key = float_to_ordered(normal.z);
	atomicMin(min_nz_key, nz_key);
	atomicMax(max_nz_key, nz_key);
}
