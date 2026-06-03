#[compute]
#version 450

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D delta_tex;

layout(set = 1, binding = 0, std430) coherent buffer AbsMaxBuffer {
	uint max_abs_bits;
};

layout(push_constant, std430) uniform Params {
	int width;
	int height;
	float _pad0;
	float _pad1;
} params;

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= params.width || p.y >= params.height) {
		return;
	}

	float value = abs(texelFetch(delta_tex, p, 0).r);
	if (isnan(value)) {
		return;
	}
	atomicMax(max_abs_bits, floatBitsToUint(value));
}
