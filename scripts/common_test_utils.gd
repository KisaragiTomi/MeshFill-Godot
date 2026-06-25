@tool
extends RefCounted


static func has_rendering_device() -> bool:
	if RenderingServer.get_rendering_device() != null:
		return true
	var local_rd := RenderingServer.create_local_rendering_device()
	if local_rd == null:
		return false
	local_rd.free()
	return true


static func read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	return file.get_as_text()


static func collect_files(root_path: String, extension: String, excluded_paths: Array = [], error_prefix: String = "") -> PackedStringArray:
	var results := PackedStringArray()
	var excluded := {}
	for path in excluded_paths:
		excluded[str(path)] = true
	_collect_files_recursive(root_path, extension, excluded, results, error_prefix)
	results.sort()
	return results


static func _collect_files_recursive(root_path: String, extension: String, excluded_paths: Dictionary, results: PackedStringArray, error_prefix: String) -> void:
	var dir := DirAccess.open(root_path)
	if dir == null:
		if not error_prefix.is_empty():
			push_error("%s: %s" % [error_prefix, root_path])
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while not entry.is_empty():
		if entry.begins_with("."):
			entry = dir.get_next()
			continue
		var child := root_path.path_join(entry)
		if dir.current_is_dir():
			_collect_files_recursive(child, extension, excluded_paths, results, error_prefix)
		elif entry.ends_with(extension) and not excluded_paths.has(child):
			results.append(child)
		entry = dir.get_next()
	dir.list_dir_end()


static func mentions_no_rd_cpu_success(lower_text: String) -> bool:
	var anchors := ["renderingdevice", "no rd", "without rd", "鏃?rd", "鏃?renderingdevice"]
	var success_terms := ["pass", "passes", "success", "succeed", "閫氳繃", "鎴愬姛"]
	for anchor in anchors:
		var search_from := 0
		while search_from < lower_text.length():
			var index := lower_text.find(anchor, search_from)
			if index < 0:
				break
			var start := maxi(index - 96, 0)
			var length := mini(192, lower_text.length() - start)
			var window := lower_text.substr(start, length)
			if window.find("cpu") >= 0 and (window.find("fallback") >= 0 or window.find("鏇夸唬") >= 0 or window.find("鍥為€€") >= 0):
				for success in success_terms:
					if window.find(success) >= 0:
						return true
			search_from = index + anchor.length()
	return false
