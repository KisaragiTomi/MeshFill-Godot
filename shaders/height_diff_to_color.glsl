#[compute]
#version 450

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D target_height_tex;
layout(set = 0, binding = 1) uniform sampler2D current_height_tex;

layout(rgba8, set = 1, binding = 0) restrict writeonly uniform image2D out_color_img;

layout(push_constant, std430) uniform Params {
	int width;
	int height;
	float diff_scale;
	float mask_threshold;
} params;

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= params.width || p.y >= params.height) {
		return;
	}

	vec4 target_px = texelFetch(target_height_tex, p, 0);
	vec4 current_px = texelFetch(current_height_tex, p, 0);
	if (current_px.b < params.mask_threshold) {
		imageStore(out_color_img, p, vec4(0.2, 0.2, 0.2, 1.0));
		return;
	}

	float diff = current_px.r - target_px.r;
	float t = clamp(abs(diff) / max(params.diff_scale, 0.0001), 0.0, 1.0);
	if (diff < 0.0) {
		imageStore(out_color_img, p, vec4(0.0, 0.0, t, 1.0));
	} else {
		imageStore(out_color_img, p, vec4(t, 0.0, 0.0, 1.0));
	}
}
