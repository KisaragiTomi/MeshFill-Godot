@tool
extends SceneTree

## Compile gate for every compute shader under res://shaders/.
##
## GDScript --check-only never touches GLSL, and the editor only compiles a
## compute shader when its pipeline first runs — so a syntax error in a .glsl
## ships silently until a demo dispatches it. This tool compiles each shader
## from source on a local RenderingDevice (the same
## shader_compile_spirv_from_source path GodotComputeShaderBase uses, with the
## #[compute] marker stripped) and exits non-zero on any compile error.
##
## Run: needs a real (non-headless) rendering backend, and the only launch form
## that provides one — `godot --path . --rendering-driver vulkan --script
## tools/verify_shader_compile.gd` — is a runtime launch banned by CLAUDE.md.
## Start it only after the user explicitly permits that one runtime run; the
## routine gate is the `-e` editor launch plus the meshfill bridge.

func _init() -> void:
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		push_error("[shader-compile] no local RenderingDevice (run with --rendering-driver vulkan, not --headless)")
		quit(2)
		return
	var dir := DirAccess.open("res://shaders")
	if dir == null:
		push_error("[shader-compile] res://shaders not found")
		quit(2)
		return
	var failures := 0
	var checked := 0
	var names := dir.get_files()
	names.sort()
	for file_name in names:
		if not file_name.ends_with(".glsl"):
			continue
		checked += 1
		var path := "res://shaders/" + file_name
		var source := FileAccess.get_file_as_string(path)
		source = source.replace("#[compute]", "")
		var shader_source := RDShaderSource.new()
		shader_source.source_compute = source
		var spirv := rd.shader_compile_spirv_from_source(shader_source)
		var err := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
		if not err.is_empty():
			failures += 1
			push_error("[shader-compile] FAIL %s\n%s" % [file_name, err])
		else:
			print("[shader-compile] OK   %s" % file_name)
	rd.free()
	print("[shader-compile] checked=%d failures=%d" % [checked, failures])
	quit(1 if failures > 0 else 0)
