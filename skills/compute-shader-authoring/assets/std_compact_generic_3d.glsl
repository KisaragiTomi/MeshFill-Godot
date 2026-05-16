#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Generic sparse tile compaction for 3D voxel grids.
// Activity and mask buffers are flattened as:
//   index = z * gw * gh + y * gw + x
// Binding 3 emits one uvec4 per active tile: (tile_x, tile_y, tile_z, 0).

layout(set = 0, binding = 0, std430) restrict readonly  buffer B0 { float activity[]; };
layout(set = 0, binding = 1, std430) restrict readonly  buffer B1 { float mask_buf[]; };
layout(set = 0, binding = 2, std430) restrict           buffer B2 { uint compact_counter; };
layout(set = 0, binding = 3, std430) restrict writeonly buffer B3 { uvec4 compact_tile_coords[]; };

layout(push_constant, std430) uniform Params {
	int gw;
	int gh;
	int gd;
	int tile_size;
	int expand_voxels;
	int activity_mode;
	int use_mask;
	int _pad0;
	float threshold;
	float mask_threshold;
	float _pad1;
	float _pad2;
};

shared uint gs_tile_active;

bool is_active(float v) {
	if (activity_mode == 1) {
		return v > threshold;
	}
	if (activity_mode == 2) {
		return v < threshold;
	}
	if (activity_mode == 3) {
		return v != 0.0;
	}
	return abs(v) > threshold;
}

void main() {
	uint li = gl_LocalInvocationIndex;
	ivec3 tile_coord = ivec3(gl_WorkGroupID.xyz);
	ivec3 tile_origin = tile_coord * ivec3(tile_size);
	ivec3 max_cell = ivec3(gw, gh, gd);

	if (any(greaterThanEqual(tile_origin, max_cell))) {
		return;
	}

	if (li == 0u) {
		gs_tile_active = 0u;
	}
	barrier();

	ivec3 scan_min = max(tile_origin - ivec3(expand_voxels), ivec3(0));
	ivec3 scan_max = min(tile_origin + ivec3(tile_size) + ivec3(expand_voxels) - ivec3(1), max_cell - ivec3(1));
	ivec3 scan_size = scan_max - scan_min + ivec3(1);
	uint slice_size = uint(scan_size.x) * uint(scan_size.y);
	uint total = slice_size * uint(scan_size.z);
	uint scan_threads = gl_WorkGroupSize.x * gl_WorkGroupSize.y * gl_WorkGroupSize.z;

	for (uint i = li; i < total; i += scan_threads) {
		if (gs_tile_active != 0u) {
			break;
		}

		int lz = int(i / slice_size);
		uint rem = i - uint(lz) * slice_size;
		int ly = int(rem / uint(scan_size.x));
		int lx = int(rem % uint(scan_size.x));

		int px = scan_min.x + lx;
		int py = scan_min.y + ly;
		int pz = scan_min.z + lz;
		int idx = pz * gw * gh + py * gw + px;

		bool masked = use_mask != 0 && mask_buf[idx] >= mask_threshold;
		if (!masked && is_active(activity[idx])) {
			atomicOr(gs_tile_active, 1u);
		}
	}

	barrier();

	if (li == 0u && gs_tile_active != 0u) {
		uint slot = atomicAdd(compact_counter, 1u);
		compact_tile_coords[slot] = uvec4(tile_coord, 0);
	}
}
