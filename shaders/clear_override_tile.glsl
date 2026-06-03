#[compute]
#version 450

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D override_mask_tex;
layout(set = 0, binding = 1) uniform sampler2D override_delta_tex;
layout(set = 0, binding = 2) uniform sampler2D dep_terrain_tex;
layout(set = 0, binding = 3) uniform sampler2D dep_rock_tex;
layout(set = 0, binding = 4) uniform sampler2D rock_override_mask_tex;
layout(set = 0, binding = 5) uniform sampler2D rock_override_delta_tex;

layout(r32f, set = 1, binding = 0) restrict writeonly uniform image2D out_override_mask_img;
layout(r32f, set = 1, binding = 1) restrict writeonly uniform image2D out_override_delta_img;
layout(r32f, set = 1, binding = 2) restrict writeonly uniform image2D out_dep_terrain_img;
layout(r32f, set = 1, binding = 3) restrict writeonly uniform image2D out_dep_rock_img;
layout(r32f, set = 1, binding = 4) restrict writeonly uniform image2D out_rock_override_mask_img;
layout(r32f, set = 1, binding = 5) restrict writeonly uniform image2D out_rock_override_delta_img;

layout(set = 1, binding = 6, std430) coherent buffer ClearCounter {
	uint cleared_count;
};

layout(push_constant, std430) uniform Params {
	int width;
	int height;
	int rect_x;
	int rect_y;
	int rect_w;
	int rect_h;
	float threshold;
	float _pad0;
} params;

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= params.width || p.y >= params.height) {
		return;
	}

	float override_mask = texelFetch(override_mask_tex, p, 0).r;
	float override_delta = texelFetch(override_delta_tex, p, 0).r;
	float dep_terrain = texelFetch(dep_terrain_tex, p, 0).r;
	float dep_rock = texelFetch(dep_rock_tex, p, 0).r;
	float rock_override_mask = texelFetch(rock_override_mask_tex, p, 0).r;
	float rock_override_delta = texelFetch(rock_override_delta_tex, p, 0).r;

	bool in_rect = p.x >= params.rect_x && p.y >= params.rect_y &&
		p.x < params.rect_x + params.rect_w && p.y < params.rect_y + params.rect_h;
	bool should_clear = in_rect && (override_mask > params.threshold || rock_override_mask > params.threshold);
	if (should_clear) {
		override_mask = 0.0;
		override_delta = 0.0;
		dep_terrain = 0.0;
		dep_rock = 0.0;
		rock_override_mask = 0.0;
		rock_override_delta = 0.0;
		atomicAdd(cleared_count, 1u);
	}

	imageStore(out_override_mask_img, p, vec4(override_mask, 0.0, 0.0, 0.0));
	imageStore(out_override_delta_img, p, vec4(override_delta, 0.0, 0.0, 0.0));
	imageStore(out_dep_terrain_img, p, vec4(dep_terrain, 0.0, 0.0, 0.0));
	imageStore(out_dep_rock_img, p, vec4(dep_rock, 0.0, 0.0, 0.0));
	imageStore(out_rock_override_mask_img, p, vec4(rock_override_mask, 0.0, 0.0, 0.0));
	imageStore(out_rock_override_delta_img, p, vec4(rock_override_delta, 0.0, 0.0, 0.0));
}
