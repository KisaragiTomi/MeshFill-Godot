@tool
extends RefCounted


static func color_from_value(value, fallback: Color = Color.WHITE) -> Color:
	if value is Color:
		return value as Color
	if value is Array:
		var arr := value as Array
		if arr.size() >= 3:
			var alpha := float(arr[3]) if arr.size() >= 4 else fallback.a
			return Color(float(arr[0]), float(arr[1]), float(arr[2]), alpha)
	if value is Dictionary:
		var dict := value as Dictionary
		return Color(
			float(dict.get("r", fallback.r)),
			float(dict.get("g", fallback.g)),
			float(dict.get("b", fallback.b)),
			float(dict.get("a", fallback.a))
		)
	if value is String:
		return Color.from_string(str(value), fallback)
	return fallback


static func vector2_from_value(value, fallback: Vector2 = Vector2.ZERO) -> Vector2:
	if value is Vector2:
		return value as Vector2
	if value is Vector2i:
		var vi := value as Vector2i
		return Vector2(float(vi.x), float(vi.y))
	if value is Array:
		var arr := value as Array
		if arr.size() >= 2:
			return Vector2(float(arr[0]), float(arr[1]))
	if value is Dictionary:
		var dict := value as Dictionary
		return Vector2(
			float(dict.get("x", fallback.x)),
			float(dict.get("y", fallback.y))
		)
	return fallback


static func vector3_from_value(value, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	if value is Vector3:
		return value as Vector3
	if value is Vector3i:
		var vi := value as Vector3i
		return Vector3(float(vi.x), float(vi.y), float(vi.z))
	if value is Array:
		var arr := value as Array
		if arr.size() >= 3:
			return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
	if value is Dictionary:
		var dict := value as Dictionary
		return Vector3(
			float(dict.get("x", fallback.x)),
			float(dict.get("y", fallback.y)),
			float(dict.get("z", fallback.z))
		)
	return fallback


## 将 Variant 强制转为 RID：本身是 RID 直接返回，否则返回 fallback（默认无效 RID()）。
static func rid_from_value(value, fallback: RID = RID()) -> RID:
	if value is RID:
		return value as RID
	return fallback


# ============================================================
# 对象属性反射取值（自 object_utils.gd 合并）
# ============================================================

static func has_property(object: Object, property_name: String) -> bool:
	if object == null:
		return false
	for property in object.get_property_list():
		if str((property as Dictionary).get("name", "")) == property_name:
			return true
	return false


static func property_or_default(object: Object, property_name: String, fallback):
	if not has_property(object, property_name):
		return fallback
	return object.get(property_name)


static func float_property(object: Object, property_name: String, fallback: float) -> float:
	var value = property_or_default(object, property_name, fallback)
	if value == null:
		return fallback
	return float(value)


## 依序尝试候选键,返回首个非空字符串值;全部缺失或为空时返回 fallback。
## 原 SceneVoxelDebug.tile_object_id / tile_source_id 等键优先查找循环的通用形式。
static func first_non_empty_string(source: Dictionary, keys: Array, fallback: String = "") -> String:
	for key in keys:
		var value := str(source.get(key, ""))
		if not value.is_empty():
			return value
	return fallback


## 从混合 Variant 解析整数 ID:int 直接返回;float 仅当为整值时接受;字符串经 is_valid_int 解析;否则返回 fallback。
## 原 SceneVoxelTileStore._scene_voxel_tile_numeric_object_id_from_value。
static func int_id_from_value(value, fallback: int = -1) -> int:
	if value is int:
		return int(value)
	if value is float:
		var numeric := int(value)
		return numeric if is_equal_approx(float(numeric), float(value)) else fallback
	var text := str(value)
	if text.is_valid_int():
		return int(text)
	return fallback


## 将 Variant 强制转为 bool：bool 直接返回；字符串/数字按 true/yes/1/on 与 false/no/0/off 约定解析；无法识别时返回 fallback。
static func bool_from_value(value, fallback: bool = false) -> bool:
	if value is bool:
		return value
	var text := str(value).strip_edges().to_lower()
	if text in ["true", "yes", "1", "on"]:
		return true
	if text in ["false", "no", "0", "off"]:
		return false
	return fallback
