#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(rgba32f, set = 0, binding = 0) uniform writeonly image2D target_height_out;
layout(rgba32f, set = 0, binding = 1) uniform writeonly image2D scene_depth_out;

layout(push_constant, std430) uniform Params {
	int width;
	int height;
	float max_height;
	float _pad0;
} params;

const float PI_VALUE = 3.14159265358979323846;

float procedural_height(float u, float v) {
	float h = 10.0;
	h += sin(u * PI_VALUE * 2.5 + 0.3) * cos(v * PI_VALUE * 1.8) * 5.0;
	h += cos(u * PI_VALUE * 5.2 + 1.1) * sin(v * PI_VALUE * 4.3 + 0.7) * 2.5;
	h += sin(u * PI_VALUE * 11.0 + 2.5) * cos(v * PI_VALUE * 8.7 + 1.3) * 1.0;
	h += sin((u + v) * PI_VALUE * 3.0) * 3.0;
	return clamp(h, 1.0, params.max_height * 0.6);
}

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= params.width || p.y >= params.height) {
		return;
	}

	float denom_x = max(float(params.width - 1), 1.0);
	float denom_y = max(float(params.height - 1), 1.0);
	float u = float(p.x) / denom_x;
	float v = float(p.y) / denom_y;
	float h = procedural_height(u, v);

	imageStore(target_height_out, p, vec4(h, 0.0, 0.0, 1.0));
	imageStore(scene_depth_out, p, vec4(params.max_height - h, 0.0, 0.0, 1.0));
}
