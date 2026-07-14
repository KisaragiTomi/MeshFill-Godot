@tool
extends SceneTree

## Desync guard for codegen-shared GLSL blocks.
##
## Two SSOTs feed generated `// @@GEN <name> ... // @@END <name>` regions:
##   - PlacementSharedGLSL: verbatim shared blocks (block name = the SSOT key).
##   - DebugBufferSet: GPU debug carrier declarations generated per-schema, with
##     block name `debug_set <schema.name>` and per-consumer set/binding overrides.
## For every declared block, verifies each consumer shader's marked region matches
## the SSOT (whitespace-trimmed). Exits non-zero if any region is missing or drifted.
##
## Run:
##   godot --headless --script tools/verify_glsl_gen_blocks.gd

const PlacementSharedGLSL := preload("res://scripts/utils/placement_shared_glsl.gd")
const DebugBufferSet := preload("res://scripts/utils/debug_buffer_set.gd")


func _init() -> void:
	var checked := 0
	var failures := 0
	for ssot in [PlacementSharedGLSL]:
		for block_name in ssot.block_names():
			var expected: String = ssot.block(block_name)
			var consumers: Array = ssot.CONSUMERS.get(block_name, [])
			for shader_path in consumers:
				checked += 1
				var actual = _extract_block(shader_path, block_name)
				if actual == null:
					push_error("[glsl-gen] %s :: %s — @@GEN block not found" % [shader_path, block_name])
					failures += 1
				elif _norm(String(actual)) != _norm(expected):
					push_error("[glsl-gen] %s :: %s — block DIVERGED from SSOT" % [shader_path, block_name])
					failures += 1
				else:
					print("[glsl-gen] OK   %s :: %s" % [shader_path, block_name])

	# DebugBufferSet: one @@GEN block per (schema, shader, section); set/binding per consumer.
	for entry in DebugBufferSet.CONSUMERS:
		checked += 1
		var schema: Dictionary = entry.get("schema", {})
		var shader_path: String = str(entry.get("shader", ""))
		var section: String = str(entry.get("section", DebugBufferSet.SECTION_ALL))
		var block_name: String = DebugBufferSet.marker_name(schema, section)
		var overrides := {}
		if entry.has("set"):
			overrides["set"] = int(entry["set"])
		if entry.has("binding"):
			overrides["binding"] = int(entry["binding"])
		var expected: String = DebugBufferSet.emit_glsl_body(schema, overrides, section)
		var actual = _extract_block(shader_path, block_name)
		if actual == null:
			push_error("[glsl-gen] %s :: %s — @@GEN block not found" % [shader_path, block_name])
			failures += 1
		elif _norm(String(actual)) != _norm(expected):
			push_error("[glsl-gen] %s :: %s — block DIVERGED from SSOT" % [shader_path, block_name])
			failures += 1
		else:
			print("[glsl-gen] OK   %s :: %s" % [shader_path, block_name])

	print("[glsl-gen] checked=%d failures=%d" % [checked, failures])
	quit(1 if failures > 0 else 0)


## Line-ending-agnostic normalization (this repo mixes CRLF/LF via autocrlf).
func _norm(s: String) -> String:
	return s.replace("\r\n", "\n").replace("\r", "\n").strip_edges()


func _extract_block(shader_path: String, block_name: String):
	var f := FileAccess.open(shader_path, FileAccess.READ)
	if f == null:
		return null
	var text := f.get_as_text()
	f.close()
	var begin := "// @@GEN " + block_name
	var end := "// @@END " + block_name
	var collecting := false
	var out: Array = []
	for line in text.split("\n"):
		var stripped := String(line).strip_edges()
		if not collecting:
			if stripped.begins_with(begin):
				collecting = true
			continue
		if stripped.begins_with(end):
			return "\n".join(out)
		out.append(line)
	return null
