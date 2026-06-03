#[compute]
#version 450

// Convert terrain height samples into scene_depth.raw RGBA32F layout.
// Binding order must match HeightToSceneDepthGPU:
//   set 0 binding 0: readonly float height_values[]; R32F stride=1 or RGBA32F stride=4.
//   set 0 binding 1: writeonly float scene_depth_values[]; RGBA32F, 4 floats per pixel.
//   set 0 binding 2: coherent uint stats; min/max ordered float keys for depth and height.
//
// Valid input range is project terrain height in meters, normally [0, max_height].
// Output layout is pixel-major RGBA32F: R=max_height-height, G=0, B=0, A=1.
// Dispatch uses 256 threads per group and guards idx >= pixel_count.

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer HeightIn {
	float height_values[];
};

layout(set = 0, binding = 1, std430) restrict writeonly buffer SceneDepthOut {
	float scene_depth_values[];
};

layout(set = 0, binding = 2, std430) coherent buffer StatsOut {
	uint min_depth_key;
	uint max_depth_key;
	uint min_height_key;
	uint max_height_key;
};

layout(push_constant, std430) uniform Params {
	int pixel_count;
	int input_stride;
	int height_channel;
	int _pad0;
	float max_height;
	float _pad1;
	float _pad2;
	float _pad3;
} params;

uint float_to_ordered(float value) {
	uint bits = floatBitsToUint(value);
	if ((bits & 0x80000000u) != 0u) {
		return ~bits;
	}
	return bits ^ 0x80000000u;
}

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= uint(params.pixel_count)) {
		return;
	}

	int safe_stride = max(params.input_stride, 1);
	int safe_channel = clamp(params.height_channel, 0, safe_stride - 1);
	float terrain_height = height_values[idx * uint(safe_stride) + uint(safe_channel)];
	float scene_depth = params.max_height - terrain_height;

	uint out_index = idx * 4u;
	scene_depth_values[out_index + 0u] = scene_depth;
	scene_depth_values[out_index + 1u] = 0.0;
	scene_depth_values[out_index + 2u] = 0.0;
	scene_depth_values[out_index + 3u] = 1.0;

	uint depth_key = float_to_ordered(scene_depth);
	uint height_key = float_to_ordered(terrain_height);
	atomicMin(min_depth_key, depth_key);
	atomicMax(max_depth_key, depth_key);
	atomicMin(min_height_key, height_key);
	atomicMax(max_height_key, height_key);
}
