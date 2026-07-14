@tool
class_name PlacementSharedGLSL
extends RefCounted

## SSOT (single source of truth) for placement-pipeline GLSL blocks shared
## VERBATIM across shaders. This project compiles shaders from raw source via
## shader_compile_spirv_from_source() (no preprocessor), so `#include` is NOT
## honoured — shared code is copied into each consumer between @@GEN markers.
##
## Shared code is COPIED into each consumer .glsl between
##   // @@GEN <name>
##   ...
##   // @@END <name>
## markers; tools/verify_glsl_gen_blocks.gd asserts each copy equals block(<name>).
##
## Currently shared:
##   yaw_rotation_y   — the canonical Y-yaw rotation family (2026-07-10 audit:
##     four shaders each hand-rolled the same "rx = ca*x + sa*z" convention).
##   ad_voxel_compose — the AD-voxel write values + monotonic-max compose rule.
##     The fine scorer predicts compose(CurrentSV, AD) with the EXACT rule the
##     stamp later applies; any drift between the two breaks the residual-gain
##     model (score-time prediction != stamped outcome).

const BLOCKS := {
	"ad_voxel_compose":
"""// Stamp-equivalent AD voxel write values + monotonic-max compose.
// Ties keep the current value, matching the stamp CAS loops which return
// without writing when current >= new (both complexity-alpha and collision).
float ad_complexity_write_value(float ad_complexity, float complexity_write_scale) {
    return clamp(ad_complexity * complexity_write_scale, 0.0, 1.0);
}

float ad_collision_write_value(float ad_collision, float solid_threshold, float collision_write_scale) {
    return ad_collision >= solid_threshold ? clamp(ad_collision * collision_write_scale, 0.0, 1.0) : 0.0;
}

// Complexity/color merge is max-by-alpha over the WHOLE rgba value: the higher
// complexity wins and brings its color along; equal alpha keeps the current rgba.
vec4 ad_compose_rgba(vec4 current_rgba, vec3 ad_rgb, float ad_complexity_value) {
    return ad_complexity_value > current_rgba.a ? vec4(ad_rgb, ad_complexity_value) : current_rgba;
}

float ad_compose_collision(float current_collision, float ad_collision_value) {
    return max(current_collision, ad_collision_value);
}""",
	"yaw_rotation_y":
"""// Canonical Y-yaw rotation, matching Basis(Vector3.UP, yaw):
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
}""",
}

## Shaders that carry each block, for the verify tool to scan.
const CONSUMERS := {
	"yaw_rotation_y": [
		"res://shaders/score_anchor_asset_residual.glsl",
		"res://shaders/stamp_asset_voxels.glsl",
		"res://shaders/placement_results_to_world.glsl",
		"res://shaders/autoobject_apply_accepted_placements_resident.glsl",
	],
	"ad_voxel_compose": [
		"res://shaders/score_anchor_asset_residual.glsl",
		"res://shaders/stamp_asset_voxels.glsl",
	],
}


static func block(name: String) -> String:
	return String(BLOCKS.get(name, "")).strip_edges()


static func block_names() -> Array:
	return BLOCKS.keys()
