#[compute]
#version 450

// Converts compact voxel placement records to world-space placement records.
// Binding order must match VoxelPlacementOutput._results_to_world_gpu:
//   set 0 binding 0: readonly placement_result_vec4x4 records.
//   set 0 binding 1: writeonly world_result_vec4x4 records.
// Output layout:
//   0: vec4(instance_position.xyz, score)
//   1: vec4(anchor_position.xyz, yaw_degrees)
//   2: vec4(support_ratio, solid_collision, complexity_overlap, clearance_overlap)
//   3: vec4(ignored_sample, valid, asset_index, scale_index)

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer PlacementResults {
	vec4 placement_results[];
};

layout(set = 0, binding = 1, std430) restrict writeonly buffer WorldResults {
	vec4 world_results[];
};

layout(push_constant, std430) uniform Params {
	ivec4 counts;       // record_count, rotation_count, input_stride, output_stride
	vec4 grid_origin;   // xyz, pad
	vec4 voxel_size;    // xyz, pad
	vec4 pivot_offset;  // xyz, pad
} params;

const float MIN_VOXEL_SIZE = 0.0001;

void main() {
	uint idx = gl_GlobalInvocationID.x;
	uint record_count = uint(max(params.counts.x, 0));
	if (idx >= record_count) {
		return;
	}

	uint input_stride = uint(max(params.counts.z, 1));
	uint output_stride = uint(max(params.counts.w, 1));
	uint input_base = idx * input_stride;
	uint output_base = idx * output_stride;

	vec4 pose = placement_results[input_base + 0u];
	vec4 ids = placement_results[input_base + 1u];
	vec4 debug0 = placement_results[input_base + 2u];
	vec4 debug1 = placement_results[input_base + 3u];

	float rotation_count = float(max(params.counts.y, 1));
	float rotation_index = round(ids.z);
	float yaw_degrees = rotation_index * 360.0 / rotation_count;
	float yaw = radians(yaw_degrees);
	float cos_y = cos(yaw);
	float sin_y = sin(yaw);

	vec3 safe_voxel_size = max(params.voxel_size.xyz, vec3(MIN_VOXEL_SIZE));
	vec3 anchor_position = params.grid_origin.xyz + pose.xyz * safe_voxel_size;
	vec3 pivot = params.pivot_offset.xyz;
	vec3 pivot_world_offset = vec3(
		pivot.x * cos_y + pivot.z * sin_y,
		pivot.y,
		-pivot.x * sin_y + pivot.z * cos_y
	);
	vec3 instance_position = anchor_position - pivot_world_offset;
	float valid = debug1.y > 0.5 ? 1.0 : 0.0;

	world_results[output_base + 0u] = vec4(instance_position, pose.w);
	world_results[output_base + 1u] = vec4(anchor_position, yaw_degrees);
	world_results[output_base + 2u] = debug0;
	world_results[output_base + 3u] = vec4(debug1.x, valid, ids.y, ids.w);
}
