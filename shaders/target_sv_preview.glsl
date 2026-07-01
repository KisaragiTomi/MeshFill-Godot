#[compute]
#version 450

// Reduce a TargetSV volume to a preview image.
// Binding order must match TargetSVPreviewGPU:
//   set 0 binding 0: readonly RGBA8 visual volume, uint per voxel, stride 4 bytes.
//   set 0 binding 1: readonly R8 collision volume, four voxels packed per uint.
//   set 0 binding 2: writeonly RGBA32F preview pixels, vec4 per x/z cell, stride 16 bytes.
//   set 0 binding 3: uint32 stats buffer, active preview pixel count.
//
// Volume layout: slice-major then row-major x/z:
//   voxel_index = slice * width * height + z * width + x.
// Valid ranges: visual.rgb, visual.a, and collision are clamped to [0, 1].

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer VisualIn {
	uint visual_volume_rgba8[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer CollisionIn {
	uint collision_volume_r8_words[];
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

vec4 unpack_rgba8(uint packed) {
	return vec4(
		float((packed >> 24u) & 0xFFu) / 255.0,
		float((packed >> 16u) & 0xFFu) / 255.0,
		float((packed >>  8u) & 0xFFu) / 255.0,
		float((packed >>  0u) & 0xFFu) / 255.0
	);
}

float load_collision_r8(uint idx) {
	uint word = collision_volume_r8_words[idx >> 2u];
	uint shift = (idx & 3u) * 8u;
	return float((word >> shift) & 0xFFu) / 255.0;
}

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
		uint voxel_index = uint(slice_index * slice_stride + pixel_index);
		vec4 visual = unpack_rgba8(visual_volume_rgba8[voxel_index]);
		float complexity = clamp(visual.a, 0.0, 1.0);
		float collision = load_collision_r8(voxel_index);
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
