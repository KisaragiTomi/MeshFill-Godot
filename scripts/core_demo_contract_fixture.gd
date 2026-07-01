@tool
extends Node3D

const TerrainInitializerScript := preload("res://scripts/terrain_initializer.gd")
const NonHeadlessSceneGuardScript := preload("res://scripts/non_headless_scene_guard.gd")
const TestUtilsScript := preload("res://scripts/utils/test_utils.gd")
const DemoContractUtils := preload("res://scripts/utils/demo_contract_utils.gd")

const STATUS_PASS := "PASS"
const STATUS_SKIP := "SKIP"
const NO_RD_POLICY_SKIP := "skip_gpu_subitems"

const GPU_CONTRACT_TERMS := [
	"gpu",
	"vulkan",
	"renderingdevice",
	"storage buffer",
	"readback",
	" rd ",
	" rd",
]

const CPU_FALLBACK_FORBIDDEN_TERMS := [
	"cpu-only",
	"cpu only",
	"cpu fallback",
	"cpu-only transitional",
	"cpu transitional",
	"cpu bridge",
	"gpu_resident=false",
	"gpu_resident = false",
]

@export var initialize_test_terrain := true

var _scene_startup_blocked := false


func _ready() -> void:
	if not Engine.is_editor_hint():
		var msg := "[DemoContract] FATAL: F6/F5 runtime launch is prohibited. All demos must run in @tool editor mode. Scene: %s" % scene_file_path
		push_error(msg)
		printerr(msg)
		_scene_startup_blocked = true
		assert(false, msg)
		return
	_scene_startup_blocked = NonHeadlessSceneGuardScript.reject_scene_launch_if_headless(get_tree())
	if _scene_startup_blocked:
		return
	if initialize_test_terrain:
		ensure_test_terrain_initialized.call_deferred()


func is_scene_startup_blocked() -> bool:
	return _scene_startup_blocked or not Engine.is_editor_hint()


func run_demo_contract_checks(expectations := {}) -> Dictionary:
	var failures := []
	var terrain_contract := ensure_test_terrain_initialized()
	var source_docs := get_contract_source_docs()
	var test_doc := str(get_meta("test_doc", ""))
	var focus := str(get_meta("focus", ""))
	var contract_text := _contract_text()
	var gpu_required := _meta_bool("gpu_required", _has_gpu_contract_text(contract_text))
	var rd_available := RenderingServer.get_rendering_device() != null
	var gpu_subitems := _gpu_subitems(contract_text, gpu_required, rd_available)

	var expected_source_doc := str(expectations.get("expected_source_doc", "")).strip_edges()
	if not expected_source_doc.is_empty() and not source_docs.has(expected_source_doc):
		failures.append("source_docs missing %s" % expected_source_doc)

	var expected_test_doc := str(expectations.get("expected_test_doc", "")).strip_edges()
	if not expected_test_doc.is_empty() and test_doc != expected_test_doc:
		failures.append("test_doc is %s, expected %s" % [test_doc, expected_test_doc])

	if source_docs.is_empty():
		failures.append("source_docs is empty")
	if test_doc.is_empty():
		failures.append("test_doc is empty")
	if focus.strip_edges().is_empty():
		failures.append("focus is empty")
	if not bool(terrain_contract.get("ok", false)):
		failures.append("terrain initialization failed: %s" % str(terrain_contract.get("reason", "unknown")))

	failures.append_array(_cpu_fallback_failures(contract_text))

	if gpu_required and not rd_available:
		for subitem in gpu_subitems:
			if str(subitem.get("status", "")) != STATUS_SKIP:
				failures.append("GPU subitem %s did not SKIP without RenderingDevice" % str(subitem.get("name", "")))

	return {
		"ok": failures.is_empty(),
		"failures": failures,
		"scene_path": scene_file_path,
		"source_docs": source_docs,
		"test_doc": test_doc,
		"focus": focus,
		"scene_script": get_script().resource_path if get_script() != null else "",
		"gpu_required": gpu_required,
		"gpu_first": gpu_required,
		"rendering_device_available": rd_available,
		"no_rd_policy": NO_RD_POLICY_SKIP,
		"gpu_subitems": gpu_subitems,
		"cpu_fallback": false,
		"terrain_initialized": bool(terrain_contract.get("ok", false)),
		"terrain_name": str(terrain_contract.get("terrain_name", "")),
		"terrain_resolution": int(terrain_contract.get("resolution", 0)),
	}


func ensure_test_terrain_initialized() -> Dictionary:
	if not initialize_test_terrain:
		return {"ok": true, "skipped": true, "reason": "disabled"}
	if not Engine.is_editor_hint():
		return {"ok": true, "skipped": true, "reason": "not_editor"}
	if not is_inside_tree():
		return {"ok": true, "skipped": true, "reason": "not_in_tree"}
	return TerrainInitializerScript.reuse_shared_terrain(self)


func get_contract_source_docs() -> Array:
	return DemoContractUtils.source_docs_from_values(
		get_meta("source_doc", ""),
		get_meta("source_docs", "")
	)


func _contract_text() -> String:
	var parts := []
	parts.append(str(get_meta("focus", "")))
	parts.append(str(get_meta("source_doc", "")))
	parts.append(str(get_meta("source_docs", "")))
	parts.append(str(get_meta("test_doc", "")))
	_collect_label_texts(self, parts)
	return "\n".join(parts)


func _collect_label_texts(node: Node, parts: Array) -> void:
	if node != self:
		if node is Label3D or node is Label or node is RichTextLabel:
			parts.append(str(node.get("text")))
	for child in node.get_children():
		_collect_label_texts(child, parts)


func _has_gpu_contract_text(text: String) -> bool:
	var lower := " %s " % text.to_lower()
	for term in GPU_CONTRACT_TERMS:
		if lower.find(term) >= 0:
			return true
	return false


func _gpu_subitems(text: String, gpu_required: bool, rd_available: bool) -> Array:
	if not gpu_required:
		return []

	var configured := str(get_meta("gpu_subitems", "")).strip_edges()
	var items := []
	if not configured.is_empty():
		for part in configured.split(";"):
			_append_unique(items, String(part).strip_edges())

	var lower := text.to_lower()
	if lower.find("profile") >= 0:
		_append_unique(items, "profile_buffers")
	if lower.find("runtime") >= 0:
		_append_unique(items, "runtime_buffers")
	if lower.find("upload") >= 0:
		_append_unique(items, "gpu_upload")
	if lower.find("placement") >= 0:
		_append_unique(items, "gpu_placement")
	if lower.find("readback") >= 0:
		_append_unique(items, "gpu_readback")
	if lower.find("scenevoxeltile") >= 0 or lower.find("scene voxel tile") >= 0:
		_append_unique(items, "scene_voxel_tile_buffers")
	if items.is_empty():
		items.append("gpu_contract")

	var status := STATUS_PASS if rd_available else STATUS_SKIP
	var reason := "rendering_device_available" if rd_available else "missing_rendering_device"
	var subitems := []
	for item in items:
		subitems.append({
			"name": item,
			"status": status,
			"reason": reason,
		})
	return subitems


func _cpu_fallback_failures(text: String) -> Array:
	var failures := []
	if _meta_bool("cpu_fallback", false):
		failures.append("metadata cpu_fallback must be false")

	var lower := text.to_lower()
	for forbidden in CPU_FALLBACK_FORBIDDEN_TERMS:
		if lower.find(forbidden) >= 0:
			failures.append("forbidden wording: %s" % forbidden)

	if TestUtilsScript.mentions_no_rd_cpu_success(lower):
		failures.append("missing RenderingDevice is described as CPU fallback success")

	return failures


static func mentions_no_rd_cpu_success(lower_text: String) -> bool:
	return TestUtilsScript.mentions_no_rd_cpu_success(lower_text)


func _meta_bool(key: String, fallback: bool) -> bool:
	if not has_meta(key):
		return fallback
	var raw = get_meta(key)
	if raw is bool:
		return raw
	var text := str(raw).strip_edges().to_lower()
	if text in ["true", "yes", "1", "on"]:
		return true
	if text in ["false", "no", "0", "off"]:
		return false
	return fallback


func _append_unique(values: Array, value: String) -> void:
	if value.is_empty() or values.has(value):
		return
	values.append(value)
