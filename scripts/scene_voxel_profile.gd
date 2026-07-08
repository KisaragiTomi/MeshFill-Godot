extends RefCounted

const CHANNEL_COUNT := 4
const VariantUtils := preload("res://scripts/utils/variant_utils.gd")

static func profile_channel(
	channel: int,
	radius: float = 0.2,
	color: Color = Color.WHITE,
	complexity: float = 1.0,
	y_min: float = 0.0,
	y_max: float = 1.0,
	subdivisions: int = 1
) -> Array[Dictionary]:
	var c := color
	var v := clampf(complexity, 0.0, 1.0)
	c.a = v
	return [{
		"channel": clampi(channel, 0, CHANNEL_COUNT - 1),
		"radius": radius,
		"color": c,
		"complexity": v,
		"y_min": y_min,
		"y_max": y_max,
		"subdivisions": maxi(subdivisions, 1),
	}]

static func profile_custom(entries: Array[Dictionary]) -> Array[Dictionary]:
	return entries

static func profile_entry_color(entry: Dictionary, fallback: Color = Color.WHITE) -> Color:
	var color := VariantUtils.color_from_value(entry.get("color", fallback), fallback)
	var complexity := clampf(float(entry.get("complexity", color.a)), 0.0, 1.0)
	color.a = complexity
	return color

static func profile_entry_complexity(entry: Dictionary, fallback: float = 1.0) -> float:
	if entry.has("complexity"):
		return clampf(float(entry.complexity), 0.0, 1.0)
	if entry.has("color"):
		return clampf(profile_entry_color(entry, Color(1.0, 1.0, 1.0, fallback)).a, 0.0, 1.0)
	return clampf(fallback, 0.0, 1.0)

static func profile_to_mask(profile: Array[Dictionary]) -> Color:
	var mask := Color(0.0, 0.0, 0.0, 0.0)
	for entry in profile:
		var ch := int(entry.get("channel", -1))
		if ch >= 0 and ch < CHANNEL_COUNT:
			mask[ch] = 1.0
	return mask
