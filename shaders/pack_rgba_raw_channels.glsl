#[compute]
#version 450

// Pack scalar terrain channels into one pixel-major RGBA32F raw buffer.
// Binding order must match TerrainRawPackGPU:
//   set 0 binding 0: readonly R32F channel R, one float per pixel.
//   set 0 binding 1: readonly R32F channel G, one float per pixel, valid only when g_valid != 0.
//   set 0 binding 2: readonly R32F channel B, one float per pixel, valid only when b_valid != 0.
//   set 0 binding 3: readonly R32F channel A, one float per pixel, valid only when a_valid != 0.
//   set 0 binding 4: writeonly RGBA32F output, 4 floats per pixel, stride 16 bytes.
//   set 0 binding 5: uint32 stats: min_r_key, max_r_key, valid_pixel_count.
//
// Valid ranges are caller-defined scalar terrain values; missing optional channels
// are filled with 0.0. Dispatch uses local_size_x = 256 and guards idx >= pixel_count.

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer ChannelRIn {
	float r_values[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer ChannelGIn {
	float g_values[];
};

layout(set = 0, binding = 2, std430) restrict readonly buffer ChannelBIn {
	float b_values[];
};

layout(set = 0, binding = 3, std430) restrict readonly buffer ChannelAIn {
	float a_values[];
};

layout(set = 0, binding = 4, std430) restrict writeonly buffer RgbaRawOut {
	float rgba_values[];
};

layout(set = 0, binding = 5, std430) coherent buffer StatsOut {
	uint min_r_key;
	uint max_r_key;
	uint valid_pixel_count;
};

layout(push_constant, std430) uniform Params {
	int pixel_count;
	int g_valid;
	int b_valid;
	int a_valid;
} params;

uint float_to_ordered(float value) {
	uint bits = floatBitsToUint(value);
	if ((bits & 0x80000000u) != 0u) {
		return ~bits;
	}
	return bits ^ 0x80000000u;
}

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= uint(max(params.pixel_count, 0))) {
		return;
	}

	float r = r_values[idx];
	float g = params.g_valid != 0 ? g_values[idx] : 0.0;
	float b = params.b_valid != 0 ? b_values[idx] : 0.0;
	float a = params.a_valid != 0 ? a_values[idx] : 0.0;

	uint out_index = idx * 4u;
	rgba_values[out_index + 0u] = r;
	rgba_values[out_index + 1u] = g;
	rgba_values[out_index + 2u] = b;
	rgba_values[out_index + 3u] = a;

	if (!isnan(r)) {
		uint r_key = float_to_ordered(r);
		atomicMin(min_r_key, r_key);
		atomicMax(max_r_key, r_key);
		atomicAdd(valid_pixel_count, 1u);
	}
}
