#[compute]
#version 450

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D scene_depth_tex;
layout(set = 0, binding = 1) uniform sampler2D override_mask_tex;
layout(set = 0, binding = 2) uniform sampler2D override_delta_tex;
layout(set = 0, binding = 3) uniform sampler2D dep_terrain_tex;
layout(set = 0, binding = 4) uniform sampler2D dep_rock_tex;
layout(set = 0, binding = 5) uniform sampler2D current_rock_tex;

layout(r32f, set = 1, binding = 0) restrict writeonly uniform image2D out_override_mask_img;
layout(r32f, set = 1, binding = 1) restrict writeonly uniform image2D out_override_delta_img;
layout(r32f, set = 1, binding = 2) restrict writeonly uniform image2D out_dep_terrain_img;
layout(r32f, set = 1, binding = 3) restrict writeonly uniform image2D out_dep_rock_img;

layout(set = 1, binding = 4, std430) coherent buffer InvalidatedCounter {
	uint invalidated_count;
};

layout(push_constant, std430) uniform Params {
	int width;
	int height;
	float max_height;
	float mask_threshold;
	float terrain_epsilon;
	float rock_threshold;
	float _pad0;
	float _pad1;
} params;

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= params.width || p.y >= params.height) {
		return;
	}

	float mask_val = texelFetch(override_mask_tex, p, 0).r;
	float delta_val = texelFetch(override_delta_tex, p, 0).r;
	float dep_terrain = texelFetch(dep_terrain_tex, p, 0).r;
	float dep_rock = texelFetch(dep_rock_tex, p, 0).r;

	bool invalidated = false;
	if (mask_val >= params.mask_threshold) {
		float cur_h = params.max_height - texelFetch(scene_depth_tex, p, 0).r;
		float cur_rock = texelFetch(current_rock_tex, p, 0).r;
		bool terrain_changed = abs(cur_h - dep_terrain) > params.terrain_epsilon;
		bool rock_overlap = cur_rock > params.rock_threshold && dep_rock < params.rock_threshold;
		invalidated = terrain_changed || rock_overlap;
	}

	if (invalidated) {
		imageStore(out_override_mask_img, p, vec4(0.0));
		imageStore(out_override_delta_img, p, vec4(0.0));
		imageStore(out_dep_terrain_img, p, vec4(0.0));
		imageStore(out_dep_rock_img, p, vec4(0.0));
		atomicAdd(invalidated_count, 1u);
	} else {
		imageStore(out_override_mask_img, p, vec4(mask_val, 0.0, 0.0, 0.0));
		imageStore(out_override_delta_img, p, vec4(delta_val, 0.0, 0.0, 0.0));
		imageStore(out_dep_terrain_img, p, vec4(dep_terrain, 0.0, 0.0, 0.0));
		imageStore(out_dep_rock_img, p, vec4(dep_rock, 0.0, 0.0, 0.0));
	}
}
