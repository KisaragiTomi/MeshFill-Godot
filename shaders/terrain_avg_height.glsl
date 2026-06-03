#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D height_tex;

layout(set = 1, binding = 0, std430) coherent buffer AvgBuffer {
	int sum_scaled;
	uint count;
};

layout(push_constant, std430) uniform Params {
	int width;
	int height;
	int sample_step;
	float scale;
} params;

void main() {
	ivec2 sample_p = ivec2(gl_GlobalInvocationID.xy);
	ivec2 p = sample_p * params.sample_step;
	if (p.x >= params.width || p.y >= params.height) {
		return;
	}

	float value = texelFetch(height_tex, p, 0).r;
	if (isnan(value)) {
		return;
	}
	atomicAdd(sum_scaled, int(round(value * params.scale)));
	atomicAdd(count, 1u);
}
