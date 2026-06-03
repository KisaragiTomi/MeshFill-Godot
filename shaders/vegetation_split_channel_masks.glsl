#[compute]
#version 450

// Split RGBA vegetation occupancy into four R32F masks in one dispatch.
// Input:
//   set0/binding0: RGBA16F occupancy texture.
// Outputs:
//   set1/binding0: R32F red/grass channel mask.
//   set1/binding1: R32F green/bush channel mask.
//   set1/binding2: R32F blue/midstory channel mask.
//   set1/binding3: R32F alpha/tree channel mask.

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D t_occupancy;

layout(r32f, set = 1, binding = 0) uniform writeonly image2D rw_channel_r;
layout(r32f, set = 1, binding = 1) uniform writeonly image2D rw_channel_g;
layout(r32f, set = 1, binding = 2) uniform writeonly image2D rw_channel_b;
layout(r32f, set = 1, binding = 3) uniform writeonly image2D rw_channel_a;

layout(push_constant, std430) uniform Params {
	int out_width;
	int out_height;
	int src_width;
	int src_height;
	float active_threshold;
	float _pad0;
	float _pad1;
	float _pad2;
} params;

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= params.out_width || p.y >= params.out_height) {
		return;
	}

	vec4 value = vec4(0.0);
	if (p.x < params.src_width && p.y < params.src_height) {
		vec4 occupancy = texelFetch(t_occupancy, p, 0);
		value = vec4(
			occupancy.r > params.active_threshold ? occupancy.r : 0.0,
			occupancy.g > params.active_threshold ? occupancy.g : 0.0,
			occupancy.b > params.active_threshold ? occupancy.b : 0.0,
			occupancy.a > params.active_threshold ? occupancy.a : 0.0
		);
	}

	imageStore(rw_channel_r, p, vec4(value.r, 0.0, 0.0, 0.0));
	imageStore(rw_channel_g, p, vec4(value.g, 0.0, 0.0, 0.0));
	imageStore(rw_channel_b, p, vec4(value.b, 0.0, 0.0, 0.0));
	imageStore(rw_channel_a, p, vec4(value.a, 0.0, 0.0, 0.0));
}
