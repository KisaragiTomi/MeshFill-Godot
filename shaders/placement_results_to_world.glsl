#[compute]
#version 450

// Converts compact voxel placement records to world-space placement records.
// Binding order must match PlacementResultCodec.dispatch_results_to_world:
//   set 0 binding 0: readonly placement_result_vec4x4 records.
//   set 0 binding 1: writeonly world_result_vec4x4 records.
//   set 0 binding 2: readonly pivot_records (container-resident; dummy when
//                    pivot_offset.w == 0 and the push pivot is used instead).
// Pivot source (pivot_offset.w > 0.5 = per-record mode): each record carries
// global_pivot_index in record[1].w (-1 = zero pivot); the pivot world offset
// is read from the runtime pivot records instead of one shared push value.
// Output layout:
//   0: vec4(instance_position.xyz, score)
//   1: vec4(anchor_position.xyz, yaw_degrees)
//   2: vec4 record[2] verbatim (solid_collision, loss_before, loss_after, clearance)
//   3: vec4(record[3].x, valid, asset_index, global_pivot_index)

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer PlacementResults {
	vec4 placement_results[];
};

layout(set = 0, binding = 1, std430) restrict writeonly buffer WorldResults {
	vec4 world_results[];
};

struct RuntimePivotRecord {
	vec4 offset_bias;             // xyz = descriptor-local WORLD offset, w = score_bias
	uvec4 ids_pad;
};

layout(set = 0, binding = 2, std430) restrict readonly buffer RuntimePivotRecords {
	RuntimePivotRecord runtime_pivot_records[];
};

layout(push_constant, std430) uniform Params {
	ivec4 counts;       // record_count, rotation_count, input_stride, output_stride
	vec4 grid_origin;   // xyz, pad
	vec4 voxel_size;    // xyz, pad
	vec4 pivot_offset;  // xyz = shared push pivot, w = use per-record pivot_records (0/1)
} params;

const float MIN_VOXEL_SIZE = 0.0001;

// @@GEN yaw_rotation_y — generated from scripts/utils/placement_shared_glsl.gd, do not edit
// Canonical Y-yaw rotation, matching Basis(Vector3.UP, yaw):
//   rx =  ca*x + sa*z ;  rz = -sa*x + ca*z ;  y unchanged.
vec3 rotate_yaw_y(vec3 v, float ca, float sa) {
    return vec3(ca * v.x + sa * v.z, v.y, -sa * v.x + ca * v.z);
}

// Float variant for collision-sample offsets: rigid yaw (NO round, NO scale) so
// the sample position stays a genuine float for trilinear sampling.
vec3 rotate_sample_offset_y_f(ivec3 sample_offset, float ca, float sa) {
    return rotate_yaw_y(vec3(sample_offset), ca, sa);
}

// Voxel-snapped variant for integer collision-sample offsets (round x/z, keep y).
ivec3 rotate_sample_offset_y(ivec3 sample_offset, float ca, float sa) {
    vec3 r = rotate_yaw_y(vec3(sample_offset), ca, sa);
    return ivec3(int(round(r.x)), sample_offset.y, int(round(r.z)));
}

// Yaw-only world transform: Basis(Vector3.UP, yaw) columns + instance origin
// (column x = (cos, 0, -sin), column z = (sin, 0, cos)).
mat4 yaw_transform_y(float ca, float sa, vec3 origin) {
    return mat4(
        vec4(ca, 0.0, -sa, 0.0),
        vec4(0.0, 1.0, 0.0, 0.0),
        vec4(sa, 0.0, ca, 0.0),
        vec4(origin, 1.0)
    );
}
// @@END yaw_rotation_y

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

	vec4 origin_score = placement_results[input_base + 0u];
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
	vec3 anchor_position = params.grid_origin.xyz + origin_score.xyz * safe_voxel_size;
	vec3 pivot = params.pivot_offset.xyz;
	if (params.pivot_offset.w > 0.5) {
		int global_pivot_index = int(round(ids.w));
		pivot = global_pivot_index >= 0
			? runtime_pivot_records[global_pivot_index].offset_bias.xyz
			: vec3(0.0);
	}
	vec3 pivot_world_offset = rotate_yaw_y(pivot, cos_y, sin_y);
	vec3 instance_position = anchor_position - pivot_world_offset;
	float valid = debug1.y > 0.5 ? 1.0 : 0.0;

	world_results[output_base + 0u] = vec4(instance_position, origin_score.w);
	world_results[output_base + 1u] = vec4(anchor_position, yaw_degrees);
	world_results[output_base + 2u] = debug0;
	world_results[output_base + 3u] = vec4(debug1.x, valid, ids.y, ids.w);
}
