@tool
class_name PlacementSharedGLSL
extends RefCounted

## SSOT (single source of truth) for placement-pipeline GLSL blocks shared
## VERBATIM across shaders (same mechanism as RouteTileSharedGLSL — see that
## file for why `#include` is not an option in this project).
##
## Shared code is COPIED into each consumer .glsl between
##   // @@GEN <name>
##   ...
##   // @@END <name>
## markers; tools/verify_glsl_gen_blocks.gd asserts each copy equals block(<name>).
##
## Currently shared: the canonical Y-yaw rotation family. The 2026-07-10 audit
## flagged this as the last cross-shader consistency hazard: four shaders each
## hand-rolled the same "rx = ca*x + sa*z ; rz = -sa*x + ca*z" convention with
## "must match" comments pointing at each other.

const BLOCKS := {
	"yaw_rotation_y":
"""// Canonical Y-yaw rotation, matching Basis(Vector3.UP, yaw):
//   rx =  ca*x + sa*z ;  rz = -sa*x + ca*z ;  y unchanged.
vec3 rotate_yaw_y(vec3 v, float ca, float sa) {
    return vec3(ca * v.x + sa * v.z, v.y, -sa * v.x + ca * v.z);
}

// Float variant for footprint offsets: rigid yaw (NO round, NO scale) so the
// sample position stays a genuine float for trilinear sampling.
vec3 rotate_footprint_offset_y_f(ivec3 fp, float ca, float sa) {
    return rotate_yaw_y(vec3(fp), ca, sa);
}

// Voxel-snapped variant for integer footprint offsets (round x/z, keep y).
ivec3 rotate_footprint_offset_y(ivec3 fp, float ca, float sa) {
    vec3 r = rotate_yaw_y(vec3(fp), ca, sa);
    return ivec3(int(round(r.x)), fp.y, int(round(r.z)));
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
		"res://shaders/score_voxel_tile.glsl",
		"res://shaders/stamp_voxel_field.glsl",
		"res://shaders/placement_results_to_world.glsl",
		"res://shaders/autoobject_apply_accepted_placements_resident.glsl",
	],
}


static func block(name: String) -> String:
	return String(BLOCKS.get(name, "")).strip_edges()


static func block_names() -> Array:
	return BLOCKS.keys()
