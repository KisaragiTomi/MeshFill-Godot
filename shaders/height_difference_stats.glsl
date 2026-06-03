#[compute]
#version 450

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D target_height_tex;
layout(set = 0, binding = 1) uniform sampler2D current_height_tex;
layout(set = 0, binding = 2) uniform sampler2D scene_depth_tex;

layout(set = 1, binding = 0, std430) restrict writeonly buffer GroupStats {
	vec4 stats[];
};

layout(push_constant, std430) uniform Params {
	int width;
	int height;
	float max_height;
	float _pad0;
} params;

shared vec4 s_counts0[256]; // total_gen, already_above, filled_ok, still_under
shared vec4 s_counts1[256]; // rock_overshoot, fillable_count, rock_added_count, reserved
shared vec4 s_sums0[256];   // sum_sq_err, sum_abs_err, max_err, sum_sq_fillable
shared vec4 s_sums1[256];   // sum_abs_fillable, sum_rock_added, target_min, target_max

void main() {
	uint local_index = gl_LocalInvocationIndex;
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);

	vec4 counts0 = vec4(0.0);
	vec4 counts1 = vec4(0.0);
	vec4 sums0 = vec4(0.0);
	vec4 sums1 = vec4(0.0, 0.0, 1.0e20, -1.0e20);

	if (p.x < params.width && p.y < params.height) {
		float target_h = texelFetch(target_height_tex, p, 0).r;
		float current_h = texelFetch(current_height_tex, p, 0).r;
		float gen_mask = texelFetch(current_height_tex, p, 0).b;
		float initial_h = params.max_height - texelFetch(scene_depth_tex, p, 0).r;
		sums1.z = target_h;
		sums1.w = target_h;

		if (gen_mask >= 0.5) {
			float diff = current_h - target_h;
			float abs_diff = abs(diff);
			counts0.x = 1.0;
			sums0.x = diff * diff;
			sums0.y = abs_diff;
			sums0.z = abs_diff;

			if (initial_h > target_h + 0.5) {
				counts0.y = 1.0;
			} else {
				counts1.y = 1.0;
				sums0.w = diff * diff;
				sums1.x = abs_diff;
				if (abs_diff < 0.5) {
					counts0.z = 1.0;
				} else if (diff < -0.5) {
					counts0.w = 1.0;
				} else {
					counts1.x = 1.0;
				}
			}

			float rock_h = current_h - initial_h;
			if (rock_h > 0.1) {
				counts1.z = 1.0;
				sums1.y = rock_h;
			}
		}
	}

	s_counts0[local_index] = counts0;
	s_counts1[local_index] = counts1;
	s_sums0[local_index] = sums0;
	s_sums1[local_index] = sums1;
	barrier();

	for (uint stride = 128u; stride > 0u; stride >>= 1u) {
		if (local_index < stride) {
			s_counts0[local_index] += s_counts0[local_index + stride];
			s_counts1[local_index] += s_counts1[local_index + stride];
			s_sums0[local_index].xyw += s_sums0[local_index + stride].xyw;
			s_sums0[local_index].z = max(s_sums0[local_index].z, s_sums0[local_index + stride].z);
			s_sums1[local_index].xy += s_sums1[local_index + stride].xy;
			s_sums1[local_index].z = min(s_sums1[local_index].z, s_sums1[local_index + stride].z);
			s_sums1[local_index].w = max(s_sums1[local_index].w, s_sums1[local_index + stride].w);
		}
		barrier();
	}

	if (local_index == 0u) {
		uint group_index = gl_WorkGroupID.y * gl_NumWorkGroups.x + gl_WorkGroupID.x;
		uint base = group_index * 4u;
		stats[base + 0u] = s_counts0[0];
		stats[base + 1u] = s_counts1[0];
		stats[base + 2u] = s_sums0[0];
		stats[base + 3u] = s_sums1[0];
	}
}
