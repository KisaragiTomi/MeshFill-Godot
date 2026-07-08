#[compute]
#version 450

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer SourceTransforms {
	float src_transforms[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer SourceColors {
	float src_colors[];
};

layout(set = 0, binding = 2, std430) restrict writeonly buffer InstanceBuffer {
	float instances[];
};

layout(push_constant, std430) uniform Params {
	int instance_count;
	int use_colors;
	int pad0;
	int pad1;
};

const int TRANSFORM_FLOATS = 12;
const int COLOR_FLOATS = 4;
const int INSTANCE_FLOATS = 16;

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= uint(instance_count)) {
		return;
	}

	uint transform_base = idx * uint(TRANSFORM_FLOATS);
	uint color_base = idx * uint(COLOR_FLOATS);
	uint instance_base = idx * uint(INSTANCE_FLOATS);

	for (uint i = 0u; i < uint(TRANSFORM_FLOATS); i++) {
		instances[instance_base + i] = src_transforms[transform_base + i];
	}

	if (use_colors != 0) {
		for (uint i = 0u; i < uint(COLOR_FLOATS); i++) {
			instances[instance_base + uint(TRANSFORM_FLOATS) + i] = src_colors[color_base + i];
		}
	} else {
		instances[instance_base + 12u] = 1.0;
		instances[instance_base + 13u] = 1.0;
		instances[instance_base + 14u] = 1.0;
		instances[instance_base + 15u] = 1.0;
	}
}
