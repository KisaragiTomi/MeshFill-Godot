#[compute]
#version 450

// Build a uint32 mask from an RGBA32F height image.
// Binding order must match HeightThresholdMaskGPU:
//   set 0 binding 0: sampled RGBA32F height texture, R channel is height
//   set 0 binding 1: uint32 mask output, one word per pixel
//   set 0 binding 2: uint32 stats output: active_count, min_height_key, max_height_key

layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D height_tex;

layout(set = 0, binding = 1, std430) restrict writeonly buffer MaskOut {
	uint mask_words[];
};

layout(set = 0, binding = 2, std430) coherent buffer StatsOut {
	uint active_count;
	uint min_height_key;
	uint max_height_key;
};

layout(push_constant, std430) uniform Params {
	int width;
	int height;
	float min_height;
	float max_height;
	float sentinel;
	float _pad0;
	float _pad1;
	float _pad2;
} params;

uint float_to_ordered(float value) {
	uint bits = floatBitsToUint(value);
	if ((bits & 0x80000000u) != 0u) {
		return ~bits;
	}
	return bits ^ 0x80000000u;
}

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= params.width || p.y >= params.height) {
		return;
	}

	uint idx = uint(p.y * params.width + p.x);
	float value = texelFetch(height_tex, p, 0).r;
	bool is_active = !isnan(value)
		&& value > params.sentinel
		&& value >= params.min_height
		&& value <= params.max_height;

	mask_words[idx] = is_active ? 1u : 0u;
	if (!is_active) {
		return;
	}

	uint key = float_to_ordered(value);
	atomicAdd(active_count, 1u);
	atomicMin(min_height_key, key);
	atomicMax(max_height_key, key);
}
