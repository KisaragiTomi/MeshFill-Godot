#[compute]
#version 450

// Pack TargetSV color/complexity values into placement-facing RGBA8 words.
//
// Binding order must match TargetColorRgba8PackGPU:
//   set 0 binding 0: readonly RGBA32F color input, vec4 per voxel, stride 16 bytes.
//   set 0 binding 1: writeonly RGBA8 words, one uint per voxel, stride 4 bytes.
//   set 0 binding 2: stats u32[4]:
//     [0] active alpha count where clamped alpha > active_epsilon
//     [1] max clamped alpha quantized to 0..1,000,000
//     [2] component clamp count for debug/verification
//     [3] reserved
//
// Valid ranges: input color components are caller-defined floats and are clamped
// to [0, 1] before packing. Output layout is high-to-low RGBA bytes:
// (r << 24) | (g << 16) | (b << 8) | a.
//
// Dispatch: local_size_x = 64, groups_x = ceil(voxel_count / 64). Invocations
// with idx >= voxel_count are edge-guarded.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer ColorIn {
	vec4 color_rgba32f[];
};

layout(set = 0, binding = 1, std430) restrict writeonly buffer ColorOut {
	uint color_rgba8[];
};

layout(set = 0, binding = 2, std430) coherent buffer StatsOut {
	uint active_alpha_count;
	uint max_alpha_q;
	uint component_clamp_count;
	uint reserved0;
};

layout(push_constant, std430) uniform Params {
	int voxel_count;
	float active_epsilon;
	int _pad0;
	int _pad1;
} params;

uint quantize_unit(float value) {
	return uint(clamp(round(value * 1000000.0), 0.0, 1000000.0));
}

uint pack_rgba8(vec4 color) {
	uvec4 bytes = uvec4(clamp(round(color * 255.0), vec4(0.0), vec4(255.0)));
	return (bytes.r << 24u) | (bytes.g << 16u) | (bytes.b << 8u) | bytes.a;
}

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= uint(max(params.voxel_count, 0))) {
		return;
	}

	vec4 raw_color = color_rgba32f[idx];
	vec4 clamped_color = clamp(raw_color, vec4(0.0), vec4(1.0));
	color_rgba8[idx] = pack_rgba8(clamped_color);

	if (clamped_color.a > params.active_epsilon) {
		atomicAdd(active_alpha_count, 1u);
	}
	atomicMax(max_alpha_q, quantize_unit(clamped_color.a));

	bvec4 was_clamped = notEqual(raw_color, clamped_color);
	uint clamp_count = (was_clamped.r ? 1u : 0u)
		+ (was_clamped.g ? 1u : 0u)
		+ (was_clamped.b ? 1u : 0u)
		+ (was_clamped.a ? 1u : 0u);
	if (clamp_count > 0u) {
		atomicAdd(component_clamp_count, clamp_count);
	}
}
