#[compute]
#version 450

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D height_tex;

layout(set = 1, binding = 0, std430) coherent buffer HeightStatsBuffer {
	uint min_key;
	uint max_key;
	uint count;
};

layout(push_constant, std430) uniform Params {
	int width;
	int height;
	float sentinel;
	float _pad0;
} params;

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

	float value = texelFetch(height_tex, p, 0).r;
	if (isnan(value) || value <= params.sentinel) {
		return;
	}
	uint key = float_to_ordered(value);
	atomicMin(min_key, key);
	atomicMax(max_key, key);
	atomicAdd(count, 1u);
}
