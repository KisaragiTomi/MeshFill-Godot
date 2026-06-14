extends SceneTree

const CORE_DOC_DIR := "res://docs/core"
const DEMO_ROOTS := [
	"res://demos/core-",
	"res://demos/modules/",
]


func _init() -> void:
	var ok := true
	var entries := []
	ok = _collect_core_demo_entries(entries) and ok
	ok = _test_demo_links_and_metadata(entries) and ok
	ok = _test_demo_scene_scripts(entries) and ok
	ok = _test_gpu_first_fixture_wording(entries) and ok
	ok = _test_gpu_fixture_vulkan_validation() and ok
	ok = _test_gpu_runtime_and_tile_deep_contracts() and ok
	ok = _test_core_fixture_boundaries() and ok

	if ok:
		print("[CoreDemoContracts] ALL TESTS PASSED")
		quit(0)
	else:
		push_error("[CoreDemoContracts] SOME TESTS FAILED")
		quit(1)


func _collect_core_demo_entries(entries: Array) -> bool:
	print("[CoreDemoContracts] collect_core_demo_entries...")
	var docs := _list_core_docs()
	if docs.is_empty():
		push_error("  FAIL: no docs/core markdown files found")
		return false

	var ok := true
	for doc_path in docs:
		var doc_text := _read_text(doc_path)
		if doc_text.is_empty():
			push_error("  FAIL: cannot read %s" % doc_path)
			ok = false
			continue
		var doc_entries := _parse_test_scene_entries(doc_path, doc_text)
		if doc_entries.is_empty():
			push_error("  FAIL: %s has no '测试场景' demo entries" % doc_path)
			ok = false
			continue
		entries.append_array(doc_entries)

	if ok:
		print("  OK: collected %d demo contract rows from %d core docs" % [entries.size(), docs.size()])
	return ok


func _test_demo_links_and_metadata(entries: Array) -> bool:
	print("[CoreDemoContracts] test_demo_links_and_metadata...")
	var ok := true
	for entry in entries:
		var source_doc: String = entry.get("source_doc", "")
		var demo_doc: String = entry.get("demo_doc", "")
		var scene_path: String = entry.get("scene_path", "")
		var label := "%s -> %s" % [source_doc, scene_path]

		ok = _assert_demo_path(demo_doc, ".md", label) and ok
		ok = _assert_demo_path(scene_path, ".tscn", label) and ok
		if not FileAccess.file_exists(demo_doc) or not FileAccess.file_exists(scene_path):
			continue

		var demo_text := _read_text(demo_doc)
		if demo_text.find(source_doc) < 0:
			push_error("  FAIL: %s does not mention source doc %s" % [demo_doc, source_doc])
			ok = false
		if demo_text.find(scene_path) < 0:
			push_error("  FAIL: %s does not mention scene %s" % [demo_doc, scene_path])
			ok = false

		var metadata := _parse_tscn_metadata(_read_text(scene_path))
		var metadata_sources := _metadata_source_docs(metadata)
		if not metadata_sources.has(source_doc):
			push_error("  FAIL: %s metadata source docs do not include %s: %s" % [scene_path, source_doc, str(metadata_sources)])
			ok = false
		if str(metadata.get("test_doc", "")) != demo_doc:
			push_error("  FAIL: %s metadata/test_doc is %s, expected %s" % [scene_path, str(metadata.get("test_doc", "")), demo_doc])
			ok = false
		if str(metadata.get("focus", "")).strip_edges().is_empty():
			push_error("  FAIL: %s metadata/focus is empty" % scene_path)
			ok = false
		if not _is_allowed_demo_path(demo_doc) or not _is_allowed_demo_path(scene_path):
			push_error("  FAIL: %s uses a demo path outside core/module demo scope" % label)
			ok = false

	if ok:
		print("  OK: demo files exist and scene metadata matches docs/core contracts")
	return ok


func _test_demo_scene_scripts(entries: Array) -> bool:
	print("[CoreDemoContracts] test_demo_scene_scripts...")
	var ok := true
	for entry in entries:
		var source_doc: String = entry.get("source_doc", "")
		var demo_doc: String = entry.get("demo_doc", "")
		var scene_path: String = entry.get("scene_path", "")
		if scene_path.is_empty() or not FileAccess.file_exists(scene_path):
			continue

		var packed = load(scene_path)
		if not packed is PackedScene:
			push_error("  FAIL: %s is not a loadable PackedScene" % scene_path)
			ok = false
			continue

		var root: Node = (packed as PackedScene).instantiate()
		if root == null:
			push_error("  FAIL: %s could not instantiate" % scene_path)
			ok = false
			continue

		if not root.has_method("run_demo_contract_checks"):
			push_error("  FAIL: %s root scene script does not expose run_demo_contract_checks()" % scene_path)
			root.free()
			ok = false
			continue

		var contract: Dictionary = root.call("run_demo_contract_checks", {
			"expected_source_doc": source_doc,
			"expected_test_doc": demo_doc,
		})
		root.free()

		if not bool(contract.get("ok", false)):
			push_error("  FAIL: %s scene contract failed: %s" % [scene_path, str(contract.get("failures", []))])
			ok = false
		if bool(contract.get("cpu_fallback", true)):
			push_error("  FAIL: %s scene contract reports cpu_fallback=true" % scene_path)
			ok = false

		var gpu_required := bool(contract.get("gpu_required", false))
		var rd_available := bool(contract.get("rendering_device_available", false))
		var gpu_subitems: Array = contract.get("gpu_subitems", [])
		if gpu_required and gpu_subitems.is_empty():
			push_error("  FAIL: %s GPU scene contract has no GPU subitems" % scene_path)
			ok = false
		if gpu_required and not rd_available:
			if str(contract.get("no_rd_policy", "")) != "skip_gpu_subitems":
				push_error("  FAIL: %s no-RD policy is not skip_gpu_subitems" % scene_path)
				ok = false
			for subitem in gpu_subitems:
				var typed_subitem: Dictionary = subitem
				if str(typed_subitem.get("status", "")) != "SKIP":
					push_error("  FAIL: %s GPU subitem %s did not SKIP without RD" % [
						scene_path,
						str(typed_subitem.get("name", "")),
					])
					ok = false
				if str(typed_subitem.get("reason", "")) != "missing_rendering_device":
					push_error("  FAIL: %s GPU subitem %s has unexpected no-RD reason %s" % [
						scene_path,
						str(typed_subitem.get("name", "")),
						str(typed_subitem.get("reason", "")),
					])
					ok = false

	if ok:
		print("  OK: docs/core demo scenes expose executable metadata/GPU skip contracts")
	return ok


func _test_core_fixture_boundaries() -> bool:
	print("[CoreDemoContracts] test_core_fixture_boundaries...")
	var ok := true
	ok = _assert_fixture_acceptance(
		"SceneVoxelTile",
		"res://demos/core-scenevoxeltile/core-scenevoxeltile.md",
		"res://demos/core-scenevoxeltile/core-scenevoxeltile.tscn",
		["SceneVoxelTile", "sidecar", "committed", "payload", "GPU", "readback"]
	) and ok
	ok = _assert_fixture_acceptance(
		"GPU AutoObject runtime plan",
		"res://demos/modules/gpu-autoobject-runtime-plan/gpu-autoobject-runtime-plan.md",
		"res://demos/modules/gpu-autoobject-runtime-plan/gpu-autoobject-runtime-plan.tscn",
		["GPUAutoObjectRuntime", "AutoVoxelRuntimeProfileContainer", "SV", "dirty"]
	) and ok
	ok = _assert_runtime_plan_gpu_first_boundaries() and ok

	if ok:
		print("  OK: key fixtures preserve asset, tile, and runtime-plan boundaries")
	return ok


func _test_gpu_first_fixture_wording(entries: Array) -> bool:
	print("[CoreDemoContracts] test_gpu_first_fixture_wording...")
	var ok := true
	for entry in entries:
		var demo_doc: String = entry.get("demo_doc", "")
		var scene_path: String = entry.get("scene_path", "")
		var label := "%s -> %s" % [demo_doc, scene_path]
		if FileAccess.file_exists(demo_doc):
			ok = _assert_no_cpu_fallback_acceptance(label, _extract_section(_read_text(demo_doc), "## 验收标准"), demo_doc) and ok
		if FileAccess.file_exists(scene_path):
			ok = _assert_no_cpu_fallback_acceptance(label, _read_text(scene_path), scene_path) and ok
	if ok:
		print("  OK: demo fixtures do not accept CPU-only or no-RD CPU fallback paths")
	return ok


func _test_gpu_fixture_vulkan_validation() -> bool:
	print("[CoreDemoContracts] test_gpu_fixture_vulkan_validation...")
	var ok := true
	ok = _assert_gpu_validation_fixture(
		"core GPU runtime",
		"res://demos/core-autoobject-gpu-runtime-architecture/core-autoobject-gpu-runtime-architecture.md",
		"res://demos/core-autoobject-gpu-runtime-architecture/core-autoobject-gpu-runtime-architecture.tscn"
	) and ok
	ok = _assert_gpu_validation_fixture(
		"module GPU runtime",
		"res://demos/modules/gpu-autoobject-runtime-plan/gpu-autoobject-runtime-plan.md",
		"res://demos/modules/gpu-autoobject-runtime-plan/gpu-autoobject-runtime-plan.tscn"
	) and ok
	if ok:
		print("  OK: GPU fixtures document headless smoke plus Vulkan RD validation")
	return ok


func _test_gpu_runtime_and_tile_deep_contracts() -> bool:
	print("[CoreDemoContracts] test_gpu_runtime_and_tile_deep_contracts...")
	var ok := true
	var runtime_contract := "\n".join([
		_read_text("res://docs/core/autoobject-gpu-runtime-architecture.md"),
		_read_text("res://demos/core-autoobject-gpu-runtime-architecture/core-autoobject-gpu-runtime-architecture.md"),
		_read_text("res://demos/core-autoobject-gpu-runtime-architecture/core-autoobject-gpu-runtime-architecture.tscn"),
		_read_text("res://demos/modules/gpu-autoobject-runtime-plan/gpu-autoobject-runtime-plan.md"),
		_read_text("res://demos/modules/gpu-autoobject-runtime-plan/gpu-autoobject-runtime-plan.tscn"),
	])
	for required in [
		"VPG",
		"contract validation",
		"bound",
		"consumed",
		"AutoVoxelRuntimeProfileContainer",
		"profile_table",
		"probe_records",
		"runtime_ready",
		"`contract_blocked=true`",
		"`cpu_fallback=false`",
		"tools/test_voxel_multi_asset.gd",
	]:
		if runtime_contract.find(required) < 0:
			push_error("  FAIL: GPU runtime fixture contract is missing '%s'" % required)
			ok = false

	var tile_contract := "\n".join([
		_read_text("res://docs/core/scenevoxeltile.md"),
		_read_text("res://demos/core-scenevoxeltile/core-scenevoxeltile.md"),
		_read_text("res://demos/core-scenevoxeltile/core-scenevoxeltile.tscn"),
		_read_text("res://demos/modules/scenevoxel-tile-dirty/scenevoxel-tile-dirty.md"),
		_read_text("res://demos/modules/scenevoxel-tile-dirty/scenevoxel-tile-dirty.tscn"),
	])
	for required in [
		"ensure_scene_voxel_tile_buffers_uploaded()",
		"get_scene_voxel_tile_gpu_buffer_summary()",
		"readback_scene_voxel_tile_debug_snapshot()",
		"runtime resident success",
		"GPU storage buffers",
		"runtime_read_source",
		"buffers_stale",
		"readback_snapshot",
		"不能把 CPU staging",
	]:
		if tile_contract.find(required) < 0:
			push_error("  FAIL: SceneVoxelTile GPU resident contract is missing '%s'" % required)
			ok = false

	for source in [
		"res://docs/core/autoobject-gpu-runtime-architecture.md",
		"res://docs/core/asset-semantic-probes.md",
		"res://docs/core/meshfill-framework.md",
		"res://docs/core/scenevoxeltile.md",
		"res://demos/core-scenevoxeltile/core-scenevoxeltile.md",
		"res://demos/core-scenevoxeltile/core-scenevoxeltile.tscn",
		"res://demos/core-autoobject-gpu-runtime-architecture/core-autoobject-gpu-runtime-architecture.md",
		"res://demos/core-autoobject-gpu-runtime-architecture/core-autoobject-gpu-runtime-architecture.tscn",
		"res://demos/modules/gpu-autoobject-runtime-plan/gpu-autoobject-runtime-plan.md",
		"res://demos/modules/gpu-autoobject-runtime-plan/gpu-autoobject-runtime-plan.tscn",
		"res://demos/modules/scenevoxel-tile-dirty/scenevoxel-tile-dirty.md",
		"res://demos/modules/scenevoxel-tile-dirty/scenevoxel-tile-dirty.tscn",
	]:
		ok = _assert_no_deep_stale_contract_wording(source, _read_text(source)) and ok

	if ok:
		print("  OK: VPG buffer binding and SceneVoxelTile resident contracts are explicit")
	return ok


func _assert_demo_path(path: String, extension: String, label: String) -> bool:
	if path.is_empty():
		push_error("  FAIL: missing %s link in %s" % [extension, label])
		return false
	if not path.ends_with(extension):
		push_error("  FAIL: expected %s link, got %s in %s" % [extension, path, label])
		return false
	if not FileAccess.file_exists(path):
		push_error("  FAIL: linked demo file does not exist: %s" % path)
		return false
	return true


func _assert_fixture_acceptance(label: String, demo_doc: String, scene_path: String, required_terms: Array) -> bool:
	var ok := true
	var demo_acceptance := _extract_section(_read_text(demo_doc), "## 验收标准")
	var scene_text := _read_text(scene_path)
	var demo_acceptance_lower := demo_acceptance.to_lower()
	var scene_text_lower := scene_text.to_lower()
	for term in required_terms:
		var term_text := str(term)
		var term_lower := term_text.to_lower()
		if demo_acceptance_lower.find(term_lower) < 0:
			push_error("  FAIL: %s demo acceptance is missing '%s'" % [label, str(term)])
			ok = false
		if scene_text_lower.find(term_lower) < 0:
			push_error("  FAIL: %s scene fixture text is missing '%s'" % [label, str(term)])
			ok = false
	return ok


func _assert_gpu_validation_fixture(label: String, demo_doc: String, scene_path: String) -> bool:
	var ok := true
	var demo_text := _read_text(demo_doc)
	var scene_text := _read_text(scene_path)
	for required in [
		"--headless",
		"--rendering-driver vulkan",
		"非 headless Vulkan",
		"RenderingDevice",
		"tools/test_voxel_multi_asset.gd",
	]:
		if demo_text.find(required) < 0:
			push_error("  FAIL: %s demo doc is missing GPU validation wording '%s'" % [label, required])
			ok = false
	for required in ["Vulkan", "RD", "readback"]:
		if scene_text.find(required) < 0:
			push_error("  FAIL: %s scene fixture is missing GPU validation label '%s'" % [label, required])
			ok = false
	return ok


func _assert_no_cpu_fallback_acceptance(label: String, text: String, source_path: String) -> bool:
	var ok := true
	var lower := text.to_lower()
	for forbidden in [
		"cpu-only",
		"cpu only",
		"cpu fallback",
		"cpu-only transitional",
		"cpu transitional",
		"cpu bridge",
		"gpu_resident=false",
		"gpu_resident = false",
	]:
		if lower.find(forbidden) >= 0:
			push_error("  FAIL: %s contains forbidden GPU-first fixture wording '%s' in %s" % [label, forbidden, source_path])
			ok = false
	if _mentions_no_rd_cpu_success(lower):
		push_error("  FAIL: %s treats missing RenderingDevice as a CPU fallback success in %s" % [label, source_path])
		ok = false
	return ok


func _assert_no_deep_stale_contract_wording(source_path: String, text: String) -> bool:
	var ok := true
	var lower := text.to_lower()
	for forbidden in [
		"cpu-only implementation landed",
		"cpu fallback pass",
		"`AutoVoxelRuntimeProfileContainer` 尚未实现",
		"AutoVoxelRuntimeProfileContainer 尚未实现",
		"后者仍未实现",
		"probe buffer 未来是否迁入",
		"目标 `AutoVoxelRuntimeProfileContainer`",
		"当前仍由 descriptor-backed getters 和 prefilter probe packing 提供",
		"contract validates but not bound",
		"contract validates but not consumed",
		"contract validates but not bound/consumed",
		"contract validation only",
		"合同校验但未绑定",
		"合同校验但未消费",
		"仅合同校验",
	]:
		var forbidden_lower := str(forbidden).to_lower()
		if lower.find(forbidden_lower) >= 0:
			push_error("  FAIL: %s contains stale GPU resident contract wording '%s'" % [source_path, forbidden])
			ok = false
	return ok


func _mentions_no_rd_cpu_success(lower_text: String) -> bool:
	var anchors := ["renderingdevice", "no rd", "without rd", "无 rd", "无 renderingdevice"]
	var success_terms := ["pass", "passes", "success", "succeed", "通过", "成功"]
	for anchor in anchors:
		var search_from := 0
		while search_from < lower_text.length():
			var index := lower_text.find(anchor, search_from)
			if index < 0:
				break
			var start := maxi(index - 96, 0)
			var length := mini(192, lower_text.length() - start)
			var window := lower_text.substr(start, length)
			if window.find("cpu") >= 0 and (window.find("fallback") >= 0 or window.find("替代") >= 0 or window.find("回退") >= 0):
				for success in success_terms:
					if window.find(success) >= 0:
						return true
			search_from = index + anchor.length()
	return false


func _assert_runtime_plan_gpu_first_boundaries() -> bool:
	var ok := true
	var combined := "\n".join([
		_read_text("res://docs/core/autoobject-gpu-runtime-architecture.md"),
		_read_text("res://demos/modules/gpu-autoobject-runtime-plan/gpu-autoobject-runtime-plan.md"),
		_read_text("res://demos/modules/gpu-autoobject-runtime-plan/gpu-autoobject-runtime-plan.tscn"),
	])
	for required in [
		"GPU-first",
		"CPU 只负责",
		"staging",
		"debug readback",
		"无 RenderingDevice 时",
		"只能 SKIP GPU upload / placement",
		"不能改走 CPU 替代路径",
		"AutoVoxelRuntimeProfileContainer",
		"profile_table",
		"probe_records",
		"readback_debug_snapshot",
		"runtime_ready",
	]:
		if combined.find(required) < 0:
			push_error("  FAIL: runtime plan boundary text is missing '%s'" % required)
			ok = false
	for forbidden in [
		"`AutoVoxelRuntimeProfileContainer` 尚未实现",
		"AutoVoxelRuntimeProfileContainer 尚未实现",
		"后者仍未实现",
		"probe buffer 未来是否迁入",
		"目标 `AutoVoxelRuntimeProfileContainer`",
		"GPU spatial index",
		"GPU spatial index 已实现",
		"GPU spatial index 已落地",
		"fully implemented GPUAutoObjectRuntime",
		"CPU-only",
		"CPU fallback",
		"gpu_resident=false",
		"gpu_resident = false",
		"not documented as landed",
	]:
		if combined.find(forbidden) >= 0:
			push_error("  FAIL: runtime plan keeps stale or fallback wording: %s" % forbidden)
			ok = false
	return ok


func _list_core_docs() -> Array:
	var docs := []
	var dir := DirAccess.open(CORE_DOC_DIR)
	if dir == null:
		return docs
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir() and file_name.ends_with(".md"):
			docs.append(CORE_DOC_DIR.path_join(file_name))
		file_name = dir.get_next()
	dir.list_dir_end()
	docs.sort()
	return docs


func _parse_test_scene_entries(source_doc: String, doc_text: String) -> Array:
	var entries := []
	var in_test_scene_section := false
	var line_number := 0
	for raw_line in doc_text.split("\n"):
		line_number += 1
		var line := String(raw_line).strip_edges()
		if line.begins_with("## "):
			in_test_scene_section = line == "## 测试场景"
			continue
		if not in_test_scene_section:
			continue
		if not line.begins_with("|") or line.find("demos/") < 0:
			continue

		var targets := _extract_markdown_link_targets(line)
		var demo_doc := ""
		var scene_path := ""
		for target in targets:
			var resolved := _resolve_relative(source_doc, target)
			if resolved.ends_with(".md") and resolved.find("/demos/") >= 0:
				demo_doc = resolved
			elif resolved.ends_with(".tscn") and resolved.find("/demos/") >= 0:
				scene_path = resolved
		entries.append({
			"source_doc": source_doc,
			"demo_doc": demo_doc,
			"scene_path": scene_path,
			"line": line_number,
		})
	return entries


func _extract_markdown_link_targets(line: String) -> Array:
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
		if target.ends_with(".md") or target.ends_with(".tscn"):
			targets.append(target)
		search_from = close_index + 1
	return targets


func _resolve_relative(base_file: String, target: String) -> String:
	if target.begins_with("res://"):
		return target.simplify_path()
	return base_file.get_base_dir().path_join(target).simplify_path()


func _parse_tscn_metadata(scene_text: String) -> Dictionary:
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
		metadata[key] = _parse_tscn_string(value)
	return metadata


func _parse_tscn_string(value: String) -> String:
	if value.begins_with("\"") and value.ends_with("\"") and value.length() >= 2:
		return value.substr(1, value.length() - 2)
	return value


func _metadata_source_docs(metadata: Dictionary) -> Array:
	var source_docs := []
	if metadata.has("source_doc"):
		source_docs.append(str(metadata["source_doc"]).strip_edges())
	if metadata.has("source_docs"):
		for part in str(metadata["source_docs"]).split(";"):
			var source := String(part).strip_edges()
			if not source.is_empty():
				source_docs.append(source)
	return source_docs


func _is_allowed_demo_path(path: String) -> bool:
	for root in DEMO_ROOTS:
		if path.begins_with(root):
			return true
	return false


func _extract_section(text: String, heading: String) -> String:
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


func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	return file.get_as_text()
