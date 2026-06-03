#[compute]
#version 450

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D height_tex;

layout(set = 1, binding = 0, std430) coherent buffer MinMaxBuffer {
	uint min_key;
	uint max_key;
};

layout(push_constant, std430) uniform Params {
	int width;
	int height;
	int channel;
	int _pad0;
} params;

float selected_channel(vec4 value) {
	if (params.channel == 1) {
		return value.g;
	}
	if (params.channel == 2) {
		return value.b;
	}
	if (params.channel == 3) {
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

	float value = selected_channel(texelFetch(height_tex, p, 0));
	if (isnan(value)) {
		return;
	}
	uint key = float_to_ordered(value);
	atomicMin(min_key, key);
	atomicMax(max_key, key);
}
