#[compute]
#version 450

// Count active pixels in all vegetation occupancy channels in one pass.
// Input:
//   set0/binding0: RGBA16F occupancy texture.
// Output:
//   set1/binding0: 4 u32 counters for RGBA channels.

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D t_occupancy;

layout(set = 1, binding = 0, std430) coherent buffer ChannelCounters {
	uint channel_counts[4];
};

layout(push_constant, std430) uniform Params {
	int width;
	int height;
	float active_threshold;
	float _pad0;
} params;

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= params.width || p.y >= params.height) {
		return;
	}

	vec4 occupancy = texelFetch(t_occupancy, p, 0);
	if (occupancy.r > params.active_threshold) {
		atomicAdd(channel_counts[0], 1u);
	}
	if (occupancy.g > params.active_threshold) {
		atomicAdd(channel_counts[1], 1u);
	}
	if (occupancy.b > params.active_threshold) {
		atomicAdd(channel_counts[2], 1u);
	}
	if (occupancy.a > params.active_threshold) {
		atomicAdd(channel_counts[3], 1u);
	}
}
