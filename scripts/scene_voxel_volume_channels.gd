extends RefCounted

const SceneVoxelProfileScript := preload("res://scripts/scene_voxel_profile.gd")

static func descriptor_from_entry(entry: Dictionary, default_subdivisions: int = 1) -> Dictionary:
	var ch := int(entry.get("channel", -1))
	var color := SceneVoxelProfileScript.profile_entry_color(entry)
	var complexity := SceneVoxelProfileScript.profile_entry_complexity(entry, color.a)
	color.a = complexity

	var y_min := float(entry.get("y_min", entry.get("min_height", 0.0)))
	var y_max := float(entry.get("y_max", entry.get("max_height", y_min + 1.0)))
	if y_max <= y_min:
		y_max = y_min + 1.0

	return {
		"channel": ch,
		"y_min": y_min,
		"y_max": y_max,
		"color": color,
		"complexity": complexity,
		"subdivisions": maxi(int(entry.get("subdivisions", default_subdivisions)), 1),
	}

static func collect_descriptors(channel_profiles, voxel_write_specs: Array[Dictionary], channel_count: int) -> Array[Dictionary]:
	var descriptors_by_channel: Dictionary = {}

	if channel_profiles is int:
		var subs := maxi(int(channel_profiles), 1)
		for ch in range(channel_count):
			descriptors_by_channel[ch] = descriptor_from_entry({"channel": ch}, subs)
	elif channel_profiles is Array:
		var raw_profiles := channel_profiles as Array
		var has_explicit_descriptors := false
		for raw_profile in raw_profiles:
			if raw_profile is Dictionary:
				has_explicit_descriptors = true
				var descriptor := descriptor_from_entry(raw_profile as Dictionary, 1)
				var ch := int(descriptor.channel)
				if ch >= 0 and ch < channel_count:
					descriptors_by_channel[ch] = descriptor
		if not has_explicit_descriptors:
			for ch in range(mini(raw_profiles.size(), channel_count)):
				descriptors_by_channel[ch] = descriptor_from_entry({"channel": ch}, maxi(int(raw_profiles[ch]), 1))

	for record in voxel_write_specs:
		if not record is Dictionary:
			continue
		var rec := record as Dictionary
		var ch := int(rec.get("channel", -1))
		if not (ch >= 0 and ch < channel_count) or descriptors_by_channel.has(ch):
			continue
		descriptors_by_channel[ch] = descriptor_from_entry(rec, maxi(int(rec.get("subdivisions", 1)), 1))

	if descriptors_by_channel.is_empty():
		for ch in range(channel_count):
			descriptors_by_channel[ch] = descriptor_from_entry({"channel": ch}, 1)

	var descriptors: Array[Dictionary] = []
	for ch in range(channel_count):
		if descriptors_by_channel.has(ch):
			descriptors.append((descriptors_by_channel[ch] as Dictionary).duplicate(true))
	return descriptors
