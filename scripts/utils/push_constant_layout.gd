class_name PushConstantLayout
extends RefCounted

## std430 push-constant 打包器。用有序字段 schema 构造一次，偏移按 std430 对齐规则算好并缓存，
## 之后每次 dispatch 用 pack(values) 把一个 {字段名: 值} 字典打成 PackedByteArray。
##
## 目的：替代散落各处的手写 `push.encode_s32(offset, ...)`——消灭啰嗦，并根除“字节偏移与
## GLSL push_constant 块静默错位”这一类 bug。类型标签直接用 GLSL 名，和 shader 声明 1:1。
##
## 用法：
##   const L := PushConstantLayout.new([
##       ["grid", "ivec4"], ["tri_count", "int"],
##       ["aabb_min_x", "float"], ["aabb_min_y", "float"], ["aabb_min_z", "float"],
##       ["cell_size", "float"], ["color", "vec4"],
##   ])
##   var push := L.pack({grid = grid, tri_count = n, aabb_min_x = mn.x, aabb_min_y = mn.y,
##                       aabb_min_z = mn.z, cell_size = cs, color = col})
##
## std430 对齐规则（本项目所有 push_constant 块均声明 std430）：
##   - 标量 int/uint/float/bool：align 4、size 4
##   - vec2/ivec2/uvec2：align 8、size 8
##   - vec3/ivec3/uvec3：align 16、size 12（成员占 12 字节，后继成员对齐到 16）
##   - vec4/ivec4/uvec4：align 16、size 16
##   - 块总大小向上取整到 16 的倍数（Godot RenderingDevice push constant 要求）
##
## 注意：本项目 shader 刻意不在 push_constant 里用 vec3（改用 vec4/ivec4 + 显式 _pad 标量），
## 但本类同样正确支持 vec3。名字以 _pad / pad / reserved 开头的字段允许在 values 里缺省（补零，不告警）。

# glsl_type -> {align, size, enc, n}. enc: "s32" | "u32" | "f32"；n: 分量数。
const _TYPES := {
	"int": {"align": 4, "size": 4, "enc": "s32", "n": 1},
	"uint": {"align": 4, "size": 4, "enc": "u32", "n": 1},
	"bool": {"align": 4, "size": 4, "enc": "u32", "n": 1},
	"float": {"align": 4, "size": 4, "enc": "f32", "n": 1},
	"vec2": {"align": 8, "size": 8, "enc": "f32", "n": 2},
	"ivec2": {"align": 8, "size": 8, "enc": "s32", "n": 2},
	"uvec2": {"align": 8, "size": 8, "enc": "u32", "n": 2},
	"vec3": {"align": 16, "size": 12, "enc": "f32", "n": 3},
	"ivec3": {"align": 16, "size": 12, "enc": "s32", "n": 3},
	"uvec3": {"align": 16, "size": 12, "enc": "u32", "n": 3},
	"vec4": {"align": 16, "size": 16, "enc": "f32", "n": 4},
	"ivec4": {"align": 16, "size": 16, "enc": "s32", "n": 4},
	"uvec4": {"align": 16, "size": 16, "enc": "u32", "n": 4},
}

var _fields: Array = []  # [{name, enc, n, offset}]
var _total := 0


func _init(schema: Array = []) -> void:
	var cursor := 0
	for entry in schema:
		if not (entry is Array) or entry.size() < 2:
			push_error("PushConstantLayout: schema 条目须为 [name, glsl_type]，实得 %s" % [entry])
			continue
		var field_name := str(entry[0])
		var type_tag := str(entry[1])
		if not _TYPES.has(type_tag):
			push_error("PushConstantLayout: 字段 '%s' 使用了不支持的 glsl 类型 '%s'" % [field_name, type_tag])
			continue
		var t: Dictionary = _TYPES[type_tag]
		cursor = _round_up(cursor, int(t["align"]))
		_fields.append({"name": field_name, "enc": str(t["enc"]), "n": int(t["n"]), "offset": cursor})
		cursor += int(t["size"])
	_total = _round_up(cursor, 16)


## push constant 总字节数（已向上取整到 16 的倍数）。
func size() -> int:
	return _total


## 把 {字段名: 值} 打成 PackedByteArray。缺失的非 _pad 字段会报错，_pad/reserved 缺省补零。
func pack(values: Dictionary) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(_total)  # resize 后为全零，未写到的字节即为 0
	for f in _fields:
		var field_name: String = f["name"]
		if not values.has(field_name):
			if not _is_padding_name(field_name):
				push_error("PushConstantLayout.pack: 缺少字段 '%s'（布局: %s）" % [field_name, describe()])
			continue
		var off: int = f["offset"]
		var enc: String = f["enc"]
		var n: int = f["n"]
		var v: Variant = values[field_name]
		if n == 1:
			_write_scalar(bytes, off, enc, v)
		else:
			var comps := _components(v, n)
			for i in range(n):
				_write_scalar(bytes, off + i * 4, enc, comps[i] if i < comps.size() else 0)
	return bytes


## 返回字段名 -> 字节偏移（用于对照 shader 声明排错）。
func offset_of(field_name: String) -> int:
	for f in _fields:
		if str(f["name"]) == field_name:
			return int(f["offset"])
	return -1


## 人类可读的布局摘要（字段@偏移，末尾总大小），用于对照 GLSL push_constant 块。
func describe() -> String:
	var parts: Array[String] = []
	for f in _fields:
		parts.append("%s@%d" % [str(f["name"]), int(f["offset"])])
	return "{%s} size=%d" % [", ".join(parts), _total]


func _write_scalar(bytes: PackedByteArray, off: int, enc: String, v: Variant) -> void:
	match enc:
		"f32":
			bytes.encode_float(off, float(v))
		"u32":
			bytes.encode_u32(off, int(v))
		_:
			bytes.encode_s32(off, int(v))


func _components(v: Variant, n: int) -> Array:
	match typeof(v):
		TYPE_VECTOR2:
			return [v.x, v.y]
		TYPE_VECTOR2I:
			return [v.x, v.y]
		TYPE_VECTOR3:
			return [v.x, v.y, v.z]
		TYPE_VECTOR3I:
			return [v.x, v.y, v.z]
		TYPE_VECTOR4:
			return [v.x, v.y, v.z, v.w]
		TYPE_VECTOR4I:
			return [v.x, v.y, v.z, v.w]
		TYPE_COLOR:
			return [v.r, v.g, v.b, v.a]
		TYPE_QUATERNION:
			return [v.x, v.y, v.z, v.w]
		TYPE_PLANE:
			return [v.normal.x, v.normal.y, v.normal.z, v.d]
		TYPE_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_INT32_ARRAY:
			var out: Array = []
			for i in range(n):
				out.append(v[i] if i < v.size() else 0)
			return out
		_:
			push_error("PushConstantLayout: 字段需要 %d 分量向量，实得类型 %d" % [n, typeof(v)])
			var zeros: Array = []
			for i in range(n):
				zeros.append(0)
			return zeros


func _is_padding_name(field_name: String) -> bool:
	return field_name.begins_with("_pad") or field_name.begins_with("pad") or field_name.begins_with("reserved")


func _round_up(v: int, a: int) -> int:
	if a <= 0:
		return v
	var r := v % a
	return v if r == 0 else v + (a - r)
