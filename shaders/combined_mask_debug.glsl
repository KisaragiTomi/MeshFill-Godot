#[compute]
#version 450

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D rock_mask_tex;
layout(set = 0, binding = 1) uniform sampler2D tree_mask_tex;
layout(set = 0, binding = 2) uniform sampler2D bush_mask_tex;

layout(rgba8, set = 1, binding = 0) restrict writeonly uniform image2D out_debug_img;

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

	float rock_v = clamp(texelFetch(rock_mask_tex, p, 0).r, 0.0, 1.0);
	float tree_v = clamp(texelFetch(tree_mask_tex, p, 0).r, 0.0, 1.0);
	float bush_v = clamp(texelFetch(bush_mask_tex, p, 0).r, 0.0, 1.0);
	imageStore(out_debug_img, p, vec4(rock_v, tree_v, bush_v, 1.0));
}
