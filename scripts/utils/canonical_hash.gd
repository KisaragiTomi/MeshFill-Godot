@tool
extends RefCounted

# 确定性 canonical 序列化:把任意 Variant 递归转为带类型前缀的稳定字符串,
# 供内容哈希使用(配合 hash_utils.stable_*_from_string)。
# 特性:Dictionary 按 key 排序、Array 保序、float 量化到 6 位小数且 ±0 归零,
# 保证同一逻辑值在不同构造顺序/浮点抖动下产生相同哈希输入。
# 原 AutoVoxelRuntimeProfileContainer._canonical_string / _sorted_canonical_entries / _format_float。


## 将数组中每个条目转为 canonical 字符串并排序返回，使哈希来源不受条目顺序影响。
static func sorted_canonical_entries(value) -> Array[String]:
	var result: Array[String] = []
	if value is Array:
		for raw_entry in value:
			result.append(canonical_string(raw_entry))
	result.sort()
	return result


## 将任意值递归序列化为带类型前缀的确定性 canonical 字符串。
static func canonical_string(value) -> String:
	match typeof(value):
		TYPE_NIL:
			return "nil"
		TYPE_BOOL:
			return "b:%s" % str(value)
		TYPE_INT:
			return "i:%d" % int(value)
		TYPE_FLOAT:
			return "f:%s" % format_float_stable(float(value))
		TYPE_STRING:
			var s := str(value)
			return "s:%d:%s" % [s.length(), s]
		TYPE_VECTOR2:
			var v2: Vector2 = value
			return "v2:%s,%s" % [format_float_stable(v2.x), format_float_stable(v2.y)]
		TYPE_VECTOR2I:
			var v2i: Vector2i = value
			return "v2i:%d,%d" % [v2i.x, v2i.y]
		TYPE_VECTOR3:
			var v3: Vector3 = value
			return "v3:%s,%s,%s" % [format_float_stable(v3.x), format_float_stable(v3.y), format_float_stable(v3.z)]
		TYPE_VECTOR3I:
			var v3i: Vector3i = value
			return "v3i:%d,%d,%d" % [v3i.x, v3i.y, v3i.z]
		TYPE_COLOR:
			var c: Color = value
			return "color:%s,%s,%s,%s" % [
				format_float_stable(c.r),
				format_float_stable(c.g),
				format_float_stable(c.b),
				format_float_stable(c.a),
			]
		TYPE_ARRAY:
			var parts: Array[String] = []
			for entry in value:
				parts.append(canonical_string(entry))
			return "a:[%s]" % ",".join(parts)
		TYPE_DICTIONARY:
			var keys := (value as Dictionary).keys()
			keys.sort()
			var dict_parts: Array[String] = []
			for key in keys:
				dict_parts.append("%s=%s" % [canonical_string(key), canonical_string((value as Dictionary)[key])])
			return "d:{%s}" % ",".join(dict_parts)
		_:
			return "v:%s" % str(value)


## 将 float 格式化为固定 6 位小数字符串，并把极小值（绝对值<=5e-7）归零以避免 ±0 等抖动影响哈希。
static func format_float_stable(value: float) -> String:
	var v := value
	if absf(v) <= 0.0000005:
		v = 0.0
	return "%.6f" % v
