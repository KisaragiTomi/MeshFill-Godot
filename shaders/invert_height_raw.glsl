#[compute]
#version 450

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict buffer HeightRawBuffer {
	float values[];
};

layout(set = 0, binding = 1, std430) coherent buffer PeakBuffer {
	uint peak_key;
	uint valid_count;
	uint min_key;
	uint max_key;
};

layout(push_constant, std430) uniform Params {
	int pixel_count;
	int mode;
	float valid_sentinel;
	float _pad0;
} params;

uint float_to_ordered(float value) {
	uint bits = floatBitsToUint(value);
	if ((bits & 0x80000000u) != 0u) {
		return ~bits;
	}
	return bits ^ 0x80000000u;
}

float ordered_to_float(uint key) {
	uint bits;
	if ((key & 0x80000000u) != 0u) {
		bits = key ^ 0x80000000u;
	} else {
		bits = ~key;
	}
	return uintBitsToFloat(bits);
}

void main() {
	uint pixel = gl_GlobalInvocationID.x;
	if (pixel >= uint(params.pixel_count)) {
		return;
	}

	uint value_index = pixel * 4u;
	float value = values[value_index];
	if (isnan(value) || value <= params.valid_sentinel) {
		return;
	}

	if (params.mode == 0) {
		atomicMax(peak_key, float_to_ordered(value));
		atomicAdd(valid_count, 1u);
		return;
	}

	float peak = ordered_to_float(peak_key);
	float inverted = value - peak;
	values[value_index] = inverted;
	if (inverted <= params.valid_sentinel) {
		return;
	}
	uint inverted_key = float_to_ordered(inverted);
	atomicMin(min_key, inverted_key);
	atomicMax(max_key, inverted_key);
}
