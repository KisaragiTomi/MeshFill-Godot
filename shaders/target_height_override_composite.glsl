#[compute]
#version 450

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D base_height_tex;
layout(set = 0, binding = 1) uniform sampler2D override_mask_tex;
layout(set = 0, binding = 2) uniform sampler2D override_delta_tex;

layout(rgba32f, set = 1, binding = 0) restrict writeonly uniform image2D out_height_img;

layout(push_constant, std430) uniform Params {
	int width;
	int height;
	int mask_width;
	int mask_height;
	float threshold;
	float _pad0;
	float _pad1;
	float _pad2;
} params;

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= params.width || p.y >= params.height) {
		return;
	}

	vec4 base_px = texelFetch(base_height_tex, p, 0);
	int mx = clamp(int(floor(float(p.x) / float(max(params.width, 1)) * float(params.mask_width))), 0, params.mask_width - 1);
	int my = clamp(int(floor(float(p.y) / float(max(params.height, 1)) * float(params.mask_height))), 0, params.mask_height - 1);
	ivec2 mp = ivec2(mx, my);
	float mask_val = texelFetch(override_mask_tex, mp, 0).r;
	if (mask_val >= params.threshold) {
		base_px.r += texelFetch(override_delta_tex, mp, 0).r * mask_val;
	}
	imageStore(out_height_img, p, base_px);
}
