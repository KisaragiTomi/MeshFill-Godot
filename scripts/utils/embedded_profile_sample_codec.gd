@tool
class_name EmbeddedProfileSampleCodec
extends RefCounted

const ProfileRecordSchemaScript := preload("res://scripts/utils/profile_record_schema.gd")

const VALUE_EPSILON := 0.0001
const FINE_GATE_VALUE := 1.0
const PROBE_GATE_VALUE := 1.0


static func decode_fine_triangle(
	colors: PackedColorArray,
	uv8_x: PackedFloat32Array,
	uv0: PackedVector2Array = PackedVector2Array(),
	uv1: PackedVector2Array = PackedVector2Array(),
	local_offset_world: Vector3 = Vector3.ZERO,
	provenance: Dictionary = {}
) -> Dictionary:
	var array_error := _triangle_array_error([colors, uv8_x, uv0, uv1])
	if not array_error.is_empty():
		return _failure(array_error)
	if not _all_float_equal(uv8_x, FINE_GATE_VALUE):
		return _failure("fine_gate_disabled")
	var disagreement := fine_corner_disagreement(colors, uv0, uv1, 0, 1, 2)
	if not disagreement.is_empty():
		return _failure(disagreement)
	var color := colors[0]
	var complexity := uv1[0].x
	color.a = complexity
	var sample := ProfileRecordSchemaScript.make_profile_sample(
		local_offset_world,
		color,
		uv0[0].x,
		ProfileRecordSchemaScript.SAMPLE_FLAG_FINE
			| ProfileRecordSchemaScript.SAMPLE_FLAG_STAMP_WRITE,
		1.0,
		1.0,
		1.0,
		1.0,
		&"fbx_color",
		provenance
	)
	return validate_decoded_sample(sample)


static func decode_probe_triangle(
	normals: PackedVector3Array,
	fbx_uv8_y: PackedFloat32Array,
	uv0: PackedVector2Array = PackedVector2Array(),
	uv1: PackedVector2Array = PackedVector2Array(),
	local_offset_world: Vector3 = Vector3.ZERO,
	provenance: Dictionary = {}
) -> Dictionary:
	var array_error := _triangle_array_error([normals, fbx_uv8_y, uv0, uv1])
	if not array_error.is_empty():
		return _failure(array_error)
	if not _all_float_equal(fbx_uv8_y, PROBE_GATE_VALUE):
		return _failure("probe_gate_disabled")
	if not _all_vectors_equal(normals):
		return _failure("probe_normal_corners_disagree")
	if not _all_vector2_component_equal(uv0, 1):
		return _failure("probe_collision_corners_disagree")
	if not _all_vector2_component_equal(uv1, 1):
		return _failure("probe_complexity_corners_disagree")
	var payload := normals[0]
	if payload.x < -VALUE_EPSILON or payload.y < -VALUE_EPSILON or payload.z < -VALUE_EPSILON:
		return _failure("probe_normal_color_has_negative_component")
	var complexity := uv1[0].y
	var color := Color(
		clampf(payload.x, 0.0, 1.0),
		clampf(payload.y, 0.0, 1.0),
		clampf(payload.z, 0.0, 1.0),
		complexity)
	var sample := ProfileRecordSchemaScript.make_profile_sample(
		local_offset_world,
		color,
		uv0[0].y,
		ProfileRecordSchemaScript.SAMPLE_FLAG_COARSE
			| ProfileRecordSchemaScript.SAMPLE_FLAG_SCORE_ONLY,
		1.0,
		1.0,
		1.0,
		1.0,
		&"fbx_normal",
		provenance
	)
	return validate_decoded_sample(sample)


## fine 三角形"三个角在 Cd / uv0.x / uv1.x 上必须同值"的判据，按下标就地比对。
##
## 逐三角形的 decode_fine_triangle 与批量列式读取
## （FbxVoxelImportService.fine_columns_from_fbx）共用这一处 —— 判废规则只此一份，
## 不因读取形态不同而复制出第二份。下标形式是为了让批量那条路能直接对整份 surface
## 数组比对，不必先为每个三角形切出三元 Packed 数组（那正是它原来的开销所在）。
##
## 返回空串表示三个角同值；否则返回失败原因，与 decode_fine_triangle 用的是同一套原因串。
static func fine_corner_disagreement(
	colors: PackedColorArray,
	uv0: PackedVector2Array,
	uv1: PackedVector2Array,
	i0: int,
	i1: int,
	i2: int
) -> String:
	var color := colors[i0]
	if not (color.is_equal_approx(colors[i1]) and color.is_equal_approx(colors[i2])):
		return "fine_color_corners_disagree"
	var collision := uv0[i0].x
	if absf(uv0[i1].x - collision) > VALUE_EPSILON or absf(uv0[i2].x - collision) > VALUE_EPSILON:
		return "fine_collision_corners_disagree"
	var complexity := uv1[i0].x
	if absf(uv1[i1].x - complexity) > VALUE_EPSILON or absf(uv1[i2].x - complexity) > VALUE_EPSILON:
		return "fine_complexity_corners_disagree"
	return ""


static func validate_decoded_sample(sample: Dictionary) -> Dictionary:
	var reason := ProfileRecordSchemaScript.profile_sample_validation_error(sample)
	if not reason.is_empty():
		return _failure(reason)
	return {"ok": true, "reason": "", "sample": sample}


static func _triangle_array_error(arrays: Array) -> String:
	for values in arrays:
		if values == null or values.size() != 3:
			return "triangle_payload_requires_three_corners"
	return ""


static func _all_float_equal(values: PackedFloat32Array, expected: float) -> bool:
	for value in values:
		if absf(value - expected) > VALUE_EPSILON:
			return false
	return true


static func _all_vectors_equal(values: PackedVector3Array) -> bool:
	return values[0].is_equal_approx(values[1]) and values[0].is_equal_approx(values[2])


static func _all_vector2_component_equal(values: PackedVector2Array, component: int) -> bool:
	var expected := values[0][component]
	return (
		absf(values[1][component] - expected) <= VALUE_EPSILON
		and absf(values[2][component] - expected) <= VALUE_EPSILON
	)


static func _failure(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason, "sample": {}}
