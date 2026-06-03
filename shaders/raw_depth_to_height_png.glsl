#[compute]
#version 450

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D depth_tex;

layout(set = 0, binding = 1, std430) readonly buffer MinMaxBuffer {
	uint min_key;
	uint max_key;
};

layout(rgba8, set = 1, binding = 0) restrict writeonly uniform image2D out_height_img;

layout(push_constant, std430) uniform Params {
	int width;
	int height;
	float max_height;
	float min_range;
} params;

float ordered_to_float(uint key) {
	uint bits = 0u;
	if ((key & 0x80000000u) != 0u) {
		bits = key ^ 0x80000000u;
	} else {
		bits = ~key;
	}
	return uintBitsToFloat(bits);
}

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= params.width || p.y >= params.height) {
		return;
	}

	float depth_min = ordered_to_float(min_key);
	float depth_max = ordered_to_float(max_key);
	float range_value = max(depth_max - depth_min, params.min_range);
	float depth = texelFetch(depth_tex, p, 0).r;
	float t = clamp((depth_max - depth) / range_value, 0.0, 1.0);
	imageStore(out_height_img, p, vec4(t, t, t, 1.0));
}
