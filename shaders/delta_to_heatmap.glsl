#[compute]
#version 450

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D delta_tex;

layout(set = 0, binding = 1, std430) readonly buffer AbsMaxBuffer {
	uint max_abs_bits;
};

layout(rgba8, set = 1, binding = 0) restrict writeonly uniform image2D out_heatmap_img;

layout(push_constant, std430) uniform Params {
	int width;
	int height;
	float epsilon;
	float _pad0;
} params;

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= params.width || p.y >= params.height) {
		return;
	}

	float max_abs = max(uintBitsToFloat(max_abs_bits), params.epsilon);
	float value = texelFetch(delta_tex, p, 0).r;
	float t = clamp(abs(value) / max_abs, 0.0, 1.0);
	if (value > params.epsilon) {
		imageStore(out_heatmap_img, p, vec4(1.0, 0.15, 0.0, 0.3 + 0.7 * t));
	} else if (value < -params.epsilon) {
		imageStore(out_heatmap_img, p, vec4(0.0, 0.3, 1.0, 0.3 + 0.7 * t));
	} else {
		imageStore(out_heatmap_img, p, vec4(0.15, 0.15, 0.15, 0.2));
	}
}
