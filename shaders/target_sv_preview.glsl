#[compute]
#version 450

// Reduce a TargetSV volume to a preview image.
// Binding order must match TargetSVPreviewGPU:
//   set 0 binding 0: readonly RGBA32F visual volume, vec4 per voxel, stride 16 bytes.
//   set 0 binding 1: readonly R32F collision volume, float per voxel, stride 4 bytes.
//   set 0 binding 2: writeonly RGBA32F preview pixels, vec4 per x/z cell, stride 16 bytes.
//   set 0 binding 3: uint32 stats buffer, active preview pixel count.
//
// Volume layout: slice-major then row-major x/z:
//   voxel_index = slice * width * height + z * width + x.
// Valid ranges: visual.rgb, visual.a, and collision are clamped to [0, 1].

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer VisualIn {
	vec4 visual_volume[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer CollisionIn {
	float collision_volume[];
};

layout(set = 0, binding = 2, std430) restrict writeonly buffer PreviewOut {
	vec4 preview_pixels[];
};

layout(set = 0, binding = 3, std430) coherent buffer StatsOut {
	uint active_pixel_count;
};

layout(push_constant, std430) uniform Params {
	int width;
	int height;
	int slice_count;
	float occupancy_epsilon;
	float collision_tint_strength;
	float collision_tint_r;
	float collision_tint_g;
	float collision_tint_b;
} params;

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= params.width || p.y >= params.height) {
		return;
	}

	int pixel_index = p.y * params.width + p.x;
	int slice_stride = params.width * params.height;

	float peak_visual = 0.0;
	float peak_collision = 0.0;
	float preview_weight = 0.0;
	vec3 weighted_color = vec3(0.0);

	for (int slice_index = 0; slice_index < params.slice_count; slice_index++) {
		int voxel_index = slice_index * slice_stride + pixel_index;
		vec4 visual = visual_volume[voxel_index];
		float complexity = clamp(visual.a, 0.0, 1.0);
		float collision = clamp(collision_volume[voxel_index], 0.0, 1.0);
		float voxel_weight = pow(max(complexity, collision), 2.0);

		peak_visual = max(peak_visual, complexity);
		peak_collision = max(peak_collision, collision);
		preview_weight += voxel_weight;
		weighted_color += clamp(visual.rgb, 0.0, 1.0) * voxel_weight;
	}

	vec3 preview_color = vec3(0.0);
	if (preview_weight > params.occupancy_epsilon) {
		preview_color = weighted_color / preview_weight;
	}

	vec3 collision_tint = vec3(params.collision_tint_r, params.collision_tint_g, params.collision_tint_b);
	float tint_amount = clamp(peak_collision * params.collision_tint_strength, 0.0, 1.0);
	preview_color = mix(preview_color, collision_tint, tint_amount);

	float alpha = max(peak_visual, peak_collision);
	if (alpha > params.occupancy_epsilon) {
		atomicAdd(active_pixel_count, 1u);
	}

	preview_pixels[pixel_index] = vec4(clamp(preview_color, 0.0, 1.0), alpha);
}
