@tool
extends SceneTree

## Desync guard for codegen-shared GLSL blocks.
##
## For every block declared in RouteTileSharedGLSL, verifies that each consumer
## shader's `// @@GEN <name> ... // @@END <name>` region matches the SSOT
## (whitespace-trimmed). Exits non-zero if any region is missing or has drifted.
##
## Run:
##   godot --headless --script tools/verify_glsl_gen_blocks.gd

const RouteTileSharedGLSL := preload("res://scripts/utils/route_tile_shared_glsl.gd")


func _init() -> void:
	var checked := 0
	var failures := 0
	for block_name in RouteTileSharedGLSL.block_names():
		var expected: String = RouteTileSharedGLSL.block(block_name)
		var consumers: Array = RouteTileSharedGLSL.CONSUMERS.get(block_name, [])
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
