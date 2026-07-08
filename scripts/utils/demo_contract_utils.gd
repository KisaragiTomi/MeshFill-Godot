@tool
extends RefCounted


static func extract_markdown_link_targets(line: String, allowed_extensions: Array = []) -> Array:
	var targets := []
	var search_from := 0
	while search_from < line.length():
		var open_index := line.find("(", search_from)
		if open_index < 0:
			break
		var close_index := line.find(")", open_index + 1)
		if close_index < 0:
			break
		var target := line.substr(open_index + 1, close_index - open_index - 1).strip_edges()
		if allowed_extensions.is_empty() or _target_has_extension(target, allowed_extensions):
			targets.append(target)
		search_from = close_index + 1
	return targets


static func resolve_relative(base_file: String, target: String) -> String:
	if target.begins_with("res://"):
		return target.simplify_path()
	return base_file.get_base_dir().path_join(target).simplify_path()


static func parse_tscn_metadata(scene_text: String) -> Dictionary:
	var metadata := {}
	for raw_line in scene_text.split("\n"):
		var line := String(raw_line).strip_edges()
		if not line.begins_with("metadata/"):
			continue
		var equals_index := line.find("=")
		if equals_index < 0:
			continue
		var key := line.substr("metadata/".length(), equals_index - "metadata/".length()).strip_edges()
		var value := line.substr(equals_index + 1).strip_edges()
		metadata[key] = parse_tscn_string(value)
	return metadata


static func parse_tscn_string(value: String) -> String:
	if value.begins_with("\"") and value.ends_with("\"") and value.length() >= 2:
		return value.substr(1, value.length() - 2)
	return value


static func source_docs_from_metadata(metadata: Dictionary) -> Array:
	return source_docs_from_values(metadata.get("source_doc", ""), metadata.get("source_docs", ""))


static func source_docs_from_values(source_doc, source_docs) -> Array:
	var values := []
	append_unique(values, str(source_doc).strip_edges())
	for part in str(source_docs).split(";"):
		append_unique(values, String(part).strip_edges())
	return values


static func extract_section(text: String, heading: String) -> String:
	var in_section := false
	var lines := []
	for raw_line in text.split("\n"):
		var line := String(raw_line)
		var stripped := line.strip_edges()
		if stripped.begins_with("## "):
			if in_section:
				break
			in_section = stripped == heading
			continue
		if in_section:
			lines.append(line)
	return "\n".join(lines)


static func find_missing_terms(text: String, required_terms: Array, case_sensitive: bool = true) -> Array:
	var haystack := text
	if not case_sensitive:
		haystack = haystack.to_lower()
	var missing := []
	for term in required_terms:
		var needle := str(term)
		if not case_sensitive:
			needle = needle.to_lower()
		if haystack.find(needle) < 0:
			missing.append(str(term))
	return missing


static func find_present_terms(text: String, forbidden_terms: Array, case_sensitive: bool = true) -> Array:
	var haystack := text
	if not case_sensitive:
		haystack = haystack.to_lower()
	var present := []
	for term in forbidden_terms:
		var needle := str(term)
		if not case_sensitive:
			needle = needle.to_lower()
		if haystack.find(needle) >= 0:
			present.append(str(term))
	return present


static func _target_has_extension(target: String, allowed_extensions: Array) -> bool:
	for extension in allowed_extensions:
		if target.ends_with(str(extension)):
			return true
	return false


static func append_unique(values: Array, value: String) -> void:
	if value.is_empty() or values.has(value):
		return
	values.append(value)
