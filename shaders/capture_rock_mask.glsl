#[compute]
#version 450

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D current_height_tex;

layout(rgba8, set = 1, binding = 0) restrict writeonly uniform image2D out_png_mask_img;
layout(r32f, set = 1, binding = 1) restrict writeonly uniform image2D out_rock_mask_img;

layout(set = 1, binding = 2, std430) coherent buffer MaskCounter {
	uint nonzero_count;
};

layout(push_constant, std430) uniform Params {
	int width;
	int height;
	float threshold;
	float _pad0;
} params;

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= params.width || p.y >= params.height) {
		return;
	}

	float rock_placed = texelFetch(current_height_tex, p, 0).g;
	if (rock_placed > params.threshold) {
		imageStore(out_png_mask_img, p, vec4(1.0));
		imageStore(out_rock_mask_img, p, vec4(1.0, 0.0, 0.0, 0.0));
		atomicAdd(nonzero_count, 1u);
	} else {
		imageStore(out_png_mask_img, p, vec4(0.0));
		imageStore(out_rock_mask_img, p, vec4(0.0));
	}
}
