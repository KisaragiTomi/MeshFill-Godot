#[compute]
#version 450

// Convert an 8-bit normalized terrain height image into a pixel-major RGBA32F raw buffer.
// Binding order must match HeightImageToRawGPU:
//   set 0 binding 0: readonly sampler2D height_tex, uploaded as RGBA8 UNORM.
//   set 0 binding 1: writeonly float raw_values[], RGBA32F, 4 floats per pixel, stride 16 bytes.
//   set 0 binding 2: coherent uint stats: min_height_key, max_height_key, valid_pixel_count.
//
// Input channel values are normalized [0, 1]. Output R is channel * height_scale,
// GBA are 0.0. Dispatch uses local_size 32x32 and guards p outside width/height.

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D height_tex;

layout(set = 0, binding = 1, std430) restrict writeonly buffer HeightRawOut {
	float raw_values[];
};

layout(set = 0, binding = 2, std430) coherent buffer StatsOut {
	uint min_height_key;
	uint max_height_key;
	uint valid_pixel_count;
};

layout(push_constant, std430) uniform Params {
	int width;
	int height;
	float height_scale;
	int source_channel;
} params;

float selected_channel(vec4 value) {
	if (params.source_channel == 1) {
		return value.g;
	}
	if (params.source_channel == 2) {
		return value.b;
	}
	if (params.source_channel == 3) {
		return value.a;
	}
	return value.r;
}

uint float_to_ordered(float value) {
	uint bits = floatBitsToUint(value);
	if ((bits & 0x80000000u) != 0u) {
		return ~bits;
	}
	return bits ^ 0x80000000u;
}

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= params.width || p.y >= params.height) {
		return;
	}

	float normalized_height = clamp(selected_channel(texelFetch(height_tex, p, 0)), 0.0, 1.0);
	float terrain_height = normalized_height * params.height_scale;
	uint idx = uint(p.y * params.width + p.x);
	uint out_index = idx * 4u;
	raw_values[out_index + 0u] = terrain_height;
	raw_values[out_index + 1u] = 0.0;
	raw_values[out_index + 2u] = 0.0;
	raw_values[out_index + 3u] = 0.0;

	uint height_key = float_to_ordered(terrain_height);
	atomicMin(min_height_key, height_key);
	atomicMax(max_height_key, height_key);
	atomicAdd(valid_pixel_count, 1u);
}
