#[compute]
#version 450

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D height_tex;

layout(set = 0, binding = 1, std430) readonly buffer MinMaxBuffer {
	uint min_key;
	uint max_key;
};

layout(rgba8, set = 1, binding = 0) restrict writeonly uniform image2D out_gray_img;

layout(push_constant, std430) uniform Params {
	int width;
	int height;
	int channel;
	float min_range;
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

	float h_min = ordered_to_float(min_key);
	float h_max = ordered_to_float(max_key);
	float range_value = max(h_max - h_min, params.min_range);
	float value = selected_channel(texelFetch(height_tex, p, 0));
	float t = clamp((value - h_min) / range_value, 0.0, 1.0);
	imageStore(out_gray_img, p, vec4(t, t, t, 1.0));
}
