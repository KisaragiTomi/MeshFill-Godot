extends SceneTree

const SHADER_DIR := "res://shaders"
const TestUtils := preload("res://scripts/utils/test_utils.gd")


func _init() -> void:
	print("[ShaderCompile] === compute shader compile smoke ===")
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		rd = RenderingServer.get_rendering_device()
	if rd == null:
		push_error("[ShaderCompile] RenderingDevice unavailable; run with --rendering-driver vulkan.")
		quit(1)
		return

	var owns_rd := rd != RenderingServer.get_rendering_device()
	var paths := _collect_shader_paths()
	var ok := true
	print("[ShaderCompile] shaders: %d" % paths.size())
	for path in paths:
		ok = _compile_shader(rd, path) and ok

	if owns_rd:
		rd.free()

	if ok:
		print("[ShaderCompile] ALL SHADERS COMPILED")
		quit(0)
	else:
		push_error("[ShaderCompile] SOME SHADERS FAILED")
		quit(1)


func _collect_shader_paths() -> PackedStringArray:
	return TestUtils.collect_files(SHADER_DIR, ".glsl", [], "[ShaderCompile] missing shader dir")


func _compile_shader(rd: RenderingDevice, path: String) -> bool:
	var source_text := _read_compute_shader_source(path)
	if source_text.is_empty():
		push_error("[ShaderCompile] empty shader source: %s" % path)
		return false

	var source := RDShaderSource.new()
	source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, source_text)
	var spirv := rd.shader_compile_spirv_from_source(source)
	if spirv == null:
		push_error("[ShaderCompile] failed to compile source: %s" % path)
		return false

	var err_msg := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not err_msg.is_empty():
		push_error("[ShaderCompile] GLSL compile error [%s]: %s" % [path, err_msg])
		return false

	var shader := rd.shader_create_from_spirv(spirv)
	if not shader.is_valid():
		push_error("[ShaderCompile] SPIR-V create failed: %s" % path)
		return false

	var pipeline := rd.compute_pipeline_create(shader)
	var pipeline_ok := pipeline.is_valid()
	if pipeline_ok:
		rd.free_rid(pipeline)
	else:
		push_error("[ShaderCompile] compute pipeline create failed: %s" % path)
	rd.free_rid(shader)
	return pipeline_ok


func _read_compute_shader_source(path: String) -> String:
	var source_text := FileAccess.get_file_as_string(ProjectSettings.globalize_path(path))
	if source_text.is_empty():
		source_text = FileAccess.get_file_as_string(path)
	if source_text.is_empty():
		return ""

	var lines := source_text.split("\n")
	var filtered: Array[String] = []
	for line in lines:
		if line.strip_edges() == "#[compute]":
			continue
		filtered.append(line)
	return "\n".join(filtered)
