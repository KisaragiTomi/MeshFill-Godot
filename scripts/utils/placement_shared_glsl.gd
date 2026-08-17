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
## markers; scripts/checks/glsl_gen_block_checks.gd asserts each copy equals block(<name>).
##
## Currently shared:
##   yaw_rotation_y   — the canonical Y-yaw rotation family (2026-07-10 audit:
##     four shaders each hand-rolled the same "rx = ca*x + sa*z" convention).
##   ad_voxel_compose — the AD-voxel write values + monotonic-max compose rule.
##     The fine scorer predicts compose(CurrentSV, AD) with the EXACT rule the
##     stamp later applies; any drift between the two breaks the residual-gain
##     model (score-time prediction != stamped outcome).

const BLOCKS := {
	"profile_sample_runtime":
"""// Canonical 32-byte ProfileSample GPU record and decoded runtime values.
struct ProfileSampleRecord {
    vec4 offset_weight;
    uvec4 payload;
};

struct ProfileSample {
    vec3 local_offset_world;
    float sample_weight;
    vec4 color;
    float collision;
    vec3 semantic_weights;
    uint flags;
};

struct ProfileSampleFields {
    vec4 current_rgba;
    vec4 target_rgba;
    vec4 predicted_rgba;
    float current_collision;
    float target_collision;
    float predicted_collision;
};

struct ProfileSampleEvaluation {
    vec4 loss_before;
    vec4 loss_after;
    vec4 fits;
    float contribution;
};

const uint PROFILE_SAMPLE_FLAG_COARSE = 1u;
const uint PROFILE_SAMPLE_FLAG_FINE = 2u;
const uint PROFILE_SAMPLE_FLAG_CLEARANCE = 4u;
const uint PROFILE_SAMPLE_FLAG_STAMP_WRITE = 8u;
const uint PROFILE_SAMPLE_FLAG_SCORE_ONLY = 16u;
const uint PROFILE_SAMPLE_POLICY_COARSE_MATCH = 0u;
const uint PROFILE_SAMPLE_POLICY_FINE_RESIDUAL = 1u;
const float PROFILE_SAMPLE_SQRT3 = 1.73205080757;

float unpack_profile_sample_snorm8(uint bits) {
    int value = int(bits & 0xFFu);
    if (value >= 128) value -= 256;
    return clamp(float(value) / 127.0, -1.0, 1.0);
}

vec4 unpack_profile_sample_rgba8(uint packed) {
    return vec4(
        float((packed >> 24u) & 0xFFu),
        float((packed >> 16u) & 0xFFu),
        float((packed >> 8u) & 0xFFu),
        float(packed & 0xFFu)
    ) * (1.0 / 255.0);
}

vec4 unpack_profile_sample_metrics(uint packed) {
    return vec4(
        float(packed & 0xFFu) * (1.0 / 255.0),
        unpack_profile_sample_snorm8(packed >> 8u),
        unpack_profile_sample_snorm8(packed >> 16u),
        unpack_profile_sample_snorm8(packed >> 24u)
    );
}

ProfileSample decode_profile_sample(ProfileSampleRecord record) {
    vec4 metrics = unpack_profile_sample_metrics(record.payload.y);
    ProfileSample decoded;
    decoded.local_offset_world = record.offset_weight.xyz;
    decoded.sample_weight = max(record.offset_weight.w, 0.0);
    decoded.color = unpack_profile_sample_rgba8(record.payload.x);
    decoded.collision = metrics.x;
    decoded.semantic_weights = metrics.yzw;
    decoded.flags = record.payload.z;
    return decoded;
}

ivec3 resolve_profile_sample_voxel(ProfileSample profile_sample, ivec3 anchor_voxel,
        vec3 pivot_world, float yaw_cos, float yaw_sin, vec3 voxel_size) {
    vec3 local_world = profile_sample.local_offset_world - pivot_world;
    vec3 rotated_world = vec3(
        yaw_cos * local_world.x + yaw_sin * local_world.z,
        local_world.y,
        -yaw_sin * local_world.x + yaw_cos * local_world.z
    );
    vec3 safe_voxel_size = max(abs(voxel_size), vec3(1.0e-6));
    return anchor_voxel + ivec3(round(rotated_world / safe_voxel_size));
}

bool profile_sample_in_bounds(ivec3 voxel, ivec3 grid_size) {
    return all(greaterThanEqual(voxel, ivec3(0))) && all(lessThan(voxel, grid_size));
}

ProfileSampleFields load_profile_sample_fields(vec4 current_rgba, float current_collision,
        vec4 target_rgba, float target_collision, vec4 predicted_rgba, float predicted_collision) {
    ProfileSampleFields fields;
    fields.current_rgba = current_rgba;
    fields.target_rgba = target_rgba;
    fields.predicted_rgba = predicted_rgba;
    fields.current_collision = current_collision;
    fields.target_collision = target_collision;
    fields.predicted_collision = predicted_collision;
    return fields;
}

ProfileSampleEvaluation evaluate_profile_sample(ProfileSample profile_sample,
        ProfileSampleFields fields, uint policy) {
    ProfileSampleEvaluation result;
    result.loss_before = vec4(
        abs(fields.current_collision - fields.target_collision),
        abs(fields.current_rgba.a - fields.target_rgba.a),
        dot(abs(fields.current_rgba.rgb - fields.target_rgba.rgb), vec3(1.0)),
        0.0
    );
    result.loss_after = vec4(
        abs(fields.predicted_collision - fields.target_collision),
        abs(fields.predicted_rgba.a - fields.target_rgba.a),
        dot(abs(fields.predicted_rgba.rgb - fields.target_rgba.rgb), vec3(1.0)),
        0.0
    );
    float color_fit = 2.0 * (1.0 - distance(fields.target_rgba.rgb, profile_sample.color.rgb)
        / PROFILE_SAMPLE_SQRT3) - 1.0;
    float complexity_fit = 2.0 * (1.0 - abs(fields.target_rgba.a - profile_sample.color.a)) - 1.0;
    float collision_fit = 1.0 - abs(
        max(fields.target_collision, fields.current_collision) - profile_sample.collision);
    result.fits = vec4(color_fit, complexity_fit, collision_fit, 0.0);
    result.contribution = policy == PROFILE_SAMPLE_POLICY_COARSE_MATCH
        ? profile_sample.sample_weight * dot(profile_sample.semantic_weights, result.fits.xyz)
        : 0.0;
    return result;
}

float profile_sample_weighted_loss(vec4 loss, ProfileSample profile_sample, vec3 dimension_weights) {
    return dimension_weights.x * profile_sample.semantic_weights.z * loss.x
        + dimension_weights.y * profile_sample.semantic_weights.y * loss.y
        + dimension_weights.z * profile_sample.semantic_weights.x * loss.z;
}""",
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
	"profile_sample_runtime": [
		"res://shaders/score_anchor_asset_probes.glsl",
		"res://shaders/score_anchor_asset_residual.glsl",
		"res://shaders/stamp_asset_voxels.glsl",
	],
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
	# 返回空串会让 glsl_gen_block_checks 把「区块名写错」误判成「区块正文恰好为空」。
	# 同形 SSOT 的另外三处（AutoObjectInstanceRenderer.block / ProfileArenaLayout.block /
	# ProfileRecordSchema.layout_anchor_block）都已有这道守卫，本处是唯一的漏网（2026-08-17 补）。
	if not BLOCKS.has(name):
		push_error("PlacementSharedGLSL.block: 未知的生成块名 '%s'（已知: %s）" % [name, str(BLOCKS.keys())])
		assert(false, "PlacementSharedGLSL.block: unknown block name")
		return ""
	return String(BLOCKS[name]).strip_edges()


static func block_names() -> Array:
	return BLOCKS.keys()
