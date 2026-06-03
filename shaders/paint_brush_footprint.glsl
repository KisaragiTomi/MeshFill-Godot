#[compute]
#version 450

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D delta_tex;
layout(set = 0, binding = 1) uniform sampler2D mask_tex;
layout(set = 0, binding = 2) uniform sampler2D dep_terrain_tex;
layout(set = 0, binding = 3) uniform sampler2D dep_rock_tex;
layout(set = 0, binding = 4) uniform sampler2D scene_depth_tex;
layout(set = 0, binding = 5) uniform sampler2D current_rock_tex;

layout(r32f, set = 1, binding = 0) restrict writeonly uniform image2D out_delta_img;
layout(r32f, set = 1, binding = 1) restrict writeonly uniform image2D out_mask_img;
layout(r32f, set = 1, binding = 2) restrict writeonly uniform image2D out_dep_terrain_img;
layout(r32f, set = 1, binding = 3) restrict writeonly uniform image2D out_dep_rock_img;

layout(push_constant, std430) uniform Params {
	int width;
	int height;
	int center_x;
	int center_y;
	int rect_x;
	int rect_y;
	int rect_w;
	int rect_h;
	int brush_width;
	int brush_length;
	int target_mode;
	int has_scene_depth;
	int has_current_rock;
	float strength;
	float max_height;
	float _pad0;
} params;

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= params.width || p.y >= params.height) {
		return;
	}

	float delta_value = texelFetch(delta_tex, p, 0).r;
	float mask_value = texelFetch(mask_tex, p, 0).r;
	float dep_terrain = texelFetch(dep_terrain_tex, p, 0).r;
	float dep_rock = texelFetch(dep_rock_tex, p, 0).r;

	bool in_rect = p.x >= params.rect_x && p.y >= params.rect_y &&
		p.x < params.rect_x + params.rect_w && p.y < params.rect_y + params.rect_h;
	if (in_rect) {
		float half_x = max(float(params.brush_width - 1) * 0.5, 1.0);
		float half_z = max(float(params.brush_length - 1) * 0.5, 1.0);
		float nx = abs(float(p.x - params.center_x)) / half_x;
		float nz = abs(float(p.y - params.center_y)) / half_z;
		float falloff = clamp(1.0 - max(nx, nz), 0.2, 1.0);
		delta_value += params.strength * falloff * 0.02;
		mask_value = 1.0;
		if (params.target_mode == 0) {
			if (params.has_scene_depth != 0) {
				dep_terrain = params.max_height - texelFetch(scene_depth_tex, p, 0).r;
			}
			if (params.has_current_rock != 0) {
				dep_rock = texelFetch(current_rock_tex, p, 0).r;
			}
		}
	}

	imageStore(out_delta_img, p, vec4(delta_value, 0.0, 0.0, 0.0));
	imageStore(out_mask_img, p, vec4(mask_value, 0.0, 0.0, 0.0));
	imageStore(out_dep_terrain_img, p, vec4(dep_terrain, 0.0, 0.0, 0.0));
	imageStore(out_dep_rock_img, p, vec4(dep_rock, 0.0, 0.0, 0.0));
}
