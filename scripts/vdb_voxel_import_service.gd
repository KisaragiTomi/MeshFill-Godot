@tool
class_name VdbVoxelImportService
extends RefCounted
## Imports an OpenVDB (.vdb) volume into a dense voxel_result — i.e. a per-voxel list of the
## 5-dim values (collision / complexity / RGB) — the asset's voxel source (baked into its
## AssetDescriptor; there is no mesh-voxelizer fallback).
##
## Godot cannot read .vdb natively, so conversion shells out to a converter that writes a
## JSON intermediate. PRIMARY backend = the self-contained native reader
## tools/vdb_native/vdb_to_voxels.exe (OpenVDB DLLs bundled beside it; no Houdini needed).
## FALLBACK = tools/convert_vdb_to_voxels.py (pyopenvdb / Houdini hython) if the exe is
## absent. load_voxel_result() reconstructs the typed voxel_result dict the baker consumes.
##
## The .vdb must be authored in the asset's local space (voxel world positions = mesh-local),
## with a uniform, axis-aligned voxel size. Grid names are configurable via ProjectSettings
## (defaults: collision←"collision", complexity←"complexity", color←"Cd").

const CONVERT_SCRIPT_PATH := "res://tools/convert_vdb_to_voxels.py"
const VDB_PYTHON_SETTING := "meshfill_editor/vdb_python"
const VDB_GRID_COLLISION_SETTING := "meshfill_editor/vdb_grid_collision"
const VDB_GRID_COMPLEXITY_SETTING := "meshfill_editor/vdb_grid_complexity"
const VDB_GRID_COLOR_SETTING := "meshfill_editor/vdb_grid_color"
## Uniform multiplier applied by the converter to cell_size / aabb / local_center
## (not to voxel indices or the 5-dim values). Reconciles a units mismatch — e.g.
## a .vdb authored in Houdini cm feeding a Godot mesh imported in m needs 0.01.
const VDB_SCALE_SETTING := "meshfill_editor/vdb_import_scale"

## Max wall-clock (ms) for the external convert before it's killed. The convert runs
## detached (OS.create_process) and is polled — NOT via OS.execute's captured pipe,
## because Houdini hython spawns a persistent daemon (hserver) that inherits the pipe
## and never closes it, hanging the editor's blocking read. hython cold-starts slowly.
const VDB_CONVERT_TIMEOUT_MS := 180000
const VDB_CONVERT_POLL_MS := 150
## The native exe finishes in ~tens of ms, so poll it much finer to keep total import
## latency low (the hython path stays on the coarse 150ms poll — its floor is seconds).
const VDB_CONVERT_POLL_NATIVE_MS := 10

## Optional path to the native OpenVDB reader (tools/vdb_native/vdb_to_voxels.exe). When it
## exists it is PREFERRED over the Python/hython converter: it reads a .vdb in ~tens of ms
## with no Houdini engine init / license checkout (hython cold-starts in ~5s). Build it with
## tools/vdb_native/build.ps1. Empty / missing ⇒ fall back to the Python backend.
const VDB_NATIVE_EXE_SETTING := "meshfill_editor/vdb_native_exe"
const _NATIVE_EXE_DEFAULT := "res://tools/vdb_native/vdb_to_voxels.exe"

const _GRID_DEFAULTS := {
	VDB_GRID_COLLISION_SETTING: "collision",
	VDB_GRID_COMPLEXITY_SETTING: "complexity",
	VDB_GRID_COLOR_SETTING: "Cd",
}


## Register the python-path + grid-name ProjectSettings (editor only). Mirrors
## FbxTransformBakeService.ensure_editor_setting; safe to call repeatedly.
static func ensure_editor_settings() -> void:
	if not Engine.is_editor_hint():
		return
	if not ProjectSettings.has_setting(VDB_PYTHON_SETTING):
		ProjectSettings.set_setting(VDB_PYTHON_SETTING, "python")
	ProjectSettings.set_initial_value(VDB_PYTHON_SETTING, "python")
	ProjectSettings.add_property_info({
		"name": VDB_PYTHON_SETTING,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_GLOBAL_FILE,
		"hint_string": "*.exe,*",
	})
	for setting in _GRID_DEFAULTS:
		var default_name: String = _GRID_DEFAULTS[setting]
		if not ProjectSettings.has_setting(setting):
			ProjectSettings.set_setting(setting, default_name)
		ProjectSettings.set_initial_value(setting, default_name)
		ProjectSettings.add_property_info({
			"name": setting,
			"type": TYPE_STRING,
		})
	if not ProjectSettings.has_setting(VDB_SCALE_SETTING):
		ProjectSettings.set_setting(VDB_SCALE_SETTING, 1.0)
	ProjectSettings.set_initial_value(VDB_SCALE_SETTING, 1.0)
	ProjectSettings.add_property_info({
		"name": VDB_SCALE_SETTING,
		"type": TYPE_FLOAT,
		"hint": PROPERTY_HINT_RANGE,
		"hint_string": "0.0001,1000.0,0.0001,or_greater",
	})
	if not ProjectSettings.has_setting(VDB_NATIVE_EXE_SETTING):
		ProjectSettings.set_setting(VDB_NATIVE_EXE_SETTING, _NATIVE_EXE_DEFAULT)
	ProjectSettings.set_initial_value(VDB_NATIVE_EXE_SETTING, _NATIVE_EXE_DEFAULT)
	ProjectSettings.add_property_info({
		"name": VDB_NATIVE_EXE_SETTING,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_GLOBAL_FILE,
		"hint_string": "*.exe,*",
	})


## Convert a .vdb into a voxel-cache JSON at cache_res_path. Prefers the native OpenVDB
## reader exe (fast; see VDB_NATIVE_EXE_SETTING) and falls back to the Python/hython
## converter when it is absent — both take the same CLI and write the same JSON.
## Returns {ok, reason, voxel_count, cache_path, command, log, exit_code}.
## reason ∈ ok / no_vdb_path / vdb_missing / script_missing / convert_failed /
##          convert_timeout / cache_invalid
static func import_vdb(vdb_path: String, cache_res_path: String) -> Dictionary:
	var result := {
		"ok": false, "reason": "", "voxel_count": 0,
		"cache_path": cache_res_path, "command": "", "log": "", "exit_code": -1,
	}
	if vdb_path.strip_edges().is_empty():
		result["reason"] = "no_vdb_path"
		return result
	var vdb_abs := ProjectSettings.globalize_path(vdb_path) if vdb_path.begins_with("res://") else vdb_path
	if not FileAccess.file_exists(vdb_abs):
		result["reason"] = "vdb_missing"
		return result
	var cache_abs := ProjectSettings.globalize_path(cache_res_path)
	DirAccess.make_dir_recursive_absolute(cache_abs.get_base_dir())
	var scale := float(ProjectSettings.get_setting(VDB_SCALE_SETTING, 1.0))
	# Shared converter arguments — identical CLI for the native exe and the Python script.
	var conv_args := PackedStringArray([
		"--input", vdb_abs,
		"--output", cache_abs,
		"--grid-collision", _grid_name(VDB_GRID_COLLISION_SETTING),
		"--grid-complexity", _grid_name(VDB_GRID_COMPLEXITY_SETTING),
		"--grid-color", _grid_name(VDB_GRID_COLOR_SETTING),
		"--scale", String.num(scale, 6),
	])

	# Prefer the native OpenVDB reader (~tens of ms, no Houdini engine/license); fall back
	# to the Python/hython converter (~5s cold-start) when the exe is absent.
	var native_exe := _resolve_native_exe()
	var use_native := not native_exe.is_empty()
	var program: String
	var args: PackedStringArray
	if use_native:
		# The exe is self-contained: OpenVDB's runtime DLLs (openvdb_sesi/tbb/blosc/zlib1)
		# sit next to it, so Windows resolves them from the exe's own directory — no Houdini
		# install and no PATH setup required.
		program = native_exe
		args = conv_args
	else:
		var script_abs := ProjectSettings.globalize_path(CONVERT_SCRIPT_PATH)
		if not FileAccess.file_exists(script_abs):
			result["reason"] = "script_missing"
			push_error("[VdbVoxelImportService] No native exe and convert script missing: %s" % CONVERT_SCRIPT_PATH)
			return result
		program = str(ProjectSettings.get_setting(VDB_PYTHON_SETTING, "python"))
		args = PackedStringArray([script_abs])
		args.append_array(conv_args)
		# Python fallback only (needs Houdini hython): the user's Houdini auto-loads a
		# fxhoudini-MCP startup (456.py) in EVERY hython that starts a blocking server and
		# hijacks the interpreter — the script never runs and the convert "hangs". Disable
		# it for the child via the env var its 456.py checks (ignored by other pythons).
		OS.set_environment("FXHOUDINIMCP_AUTOSTART", "0")
	var poll_ms := VDB_CONVERT_POLL_NATIVE_MS if use_native else VDB_CONVERT_POLL_MS
	result["command"] = "%s %s" % [program, " ".join(args)]

	# Clear any prior sidecar log so we never read a stale run's diagnostics.
	var sidecar_log := cache_abs + ".log"
	if FileAccess.file_exists(sidecar_log):
		DirAccess.remove_absolute(sidecar_log)
	# Run DETACHED (create_process), not OS.execute + captured pipe: it gives us a hard
	# timeout below, so a wedged external process can never freeze the editor. Each backend
	# writes its own stdout/stderr to the sidecar .log (read below).
	var pid := OS.create_process(program, args, false)
	if pid <= 0:
		result["reason"] = "convert_failed"
		result["log"] = "OS.create_process failed for: %s" % program
		push_error("[VdbVoxelImportService] create_process failed: %s" % program)
		return result
	var waited := 0
	while waited < VDB_CONVERT_TIMEOUT_MS and OS.is_process_running(pid):
		OS.delay_msec(poll_ms)
		waited += poll_ms
	var timed_out := OS.is_process_running(pid)
	if timed_out:
		OS.kill(pid)
	var code := -1 if timed_out else OS.get_process_exit_code(pid)
	var log_text := ""
	if FileAccess.file_exists(sidecar_log):
		log_text = FileAccess.get_file_as_string(sidecar_log)
	result["exit_code"] = code
	result["log"] = log_text
	if timed_out:
		result["reason"] = "convert_timeout"
		push_error("[VdbVoxelImportService] VDB convert timed out after %dms: %s\n%s" % [
			VDB_CONVERT_TIMEOUT_MS, program, log_text])
		return result
	if code > 0:
		result["reason"] = "convert_failed"
		push_error("[VdbVoxelImportService] VDB convert failed (exit %d): %s" % [code, log_text])
		return result

	# Validate + count WITHOUT decoding all voxels: for a large asset (~108k voxels) an
	# eager full decode here just to count would add ~150ms the import doesn't need — the
	# display / bake decode happens later (and is cached). peek reads the binary header's
	# count (or parses the JSON fallback).
	var count := peek_voxel_count(cache_res_path)
	if count <= 0:
		result["reason"] = "cache_invalid"
		push_error("[VdbVoxelImportService] Converted cache invalid/empty: %s" % cache_res_path)
		return result
	result["ok"] = true
	result["reason"] = "ok"
	result["voxel_count"] = count
	return result


## Load a converted voxel-cache into the voxel_result Dictionary shape the baker consumes
## (keys: ok/grid/cell_size/aabb_min/aabb_size/voxels; each voxel has
## voxel/local_center/color/complexity/collision). The native exe writes a compact BINARY
## cache (magic "MFV1"), the Python fallback writes JSON — detected here by the leading
## bytes. Returns ok=false when missing/empty.
static func load_voxel_result(cache_res_path: String) -> Dictionary:
	if not FileAccess.file_exists(cache_res_path):
		return _empty_voxel_result("no_cache")
	var bytes := FileAccess.get_file_as_bytes(cache_res_path)
	if bytes.size() < 4:
		return _empty_voxel_result("no_cache")
	# "MFV1" = 77,70,86,49. Binary path bulk-decodes SoA arrays instead of JSON.parse +
	# per-voxel dict building (the import-time bottleneck for large assets).
	if bytes[0] == 77 and bytes[1] == 70 and bytes[2] == 86 and bytes[3] == 49:
		return _load_binary(bytes)
	return _load_json(bytes.get_string_from_utf8())


## Voxel count + validity WITHOUT decoding every voxel. Binary: read the header count and
## confirm the file is fully written (52 + 32N bytes). JSON fallback: full parse (rare).
## Returns the count, or -1 when missing/invalid.
static func peek_voxel_count(cache_res_path: String) -> int:
	if not FileAccess.file_exists(cache_res_path):
		return -1
	var bytes := FileAccess.get_file_as_bytes(cache_res_path)
	if bytes.size() >= 52 and bytes[0] == 77 and bytes[1] == 70 and bytes[2] == 86 and bytes[3] == 49:
		var n := int(bytes.decode_u32(48))
		return n if n > 0 and bytes.size() >= 52 + 32 * n else -1
	var vres := _load_json(bytes.get_string_from_utf8())
	return (vres.get("voxels", []) as Array).size() if bool(vres.get("ok", false)) else -1


static func _empty_voxel_result(reason: String) -> Dictionary:
	return {
		"ok": false, "reason": reason,
		"grid": Vector3i.ZERO, "cell_size": 0.0, "aabb_min": Vector3.ZERO, "voxels": [],
	}


static func _finish_voxel_result(grid: Vector3i, cell_size: float, aabb_min: Vector3,
		aabb_size: Vector3, voxels: Array[Dictionary]) -> Dictionary:
	if aabb_size == Vector3.ZERO:
		aabb_size = Vector3(grid) * cell_size
	return {
		"ok": not voxels.is_empty(),
		"reason": "ok" if not voxels.is_empty() else "empty",
		"grid": grid,
		"cell_size": cell_size,
		"aabb_min": aabb_min,
		"aabb_size": aabb_size,
		"voxels": voxels,
		"source": "vdb",
	}


## Decode the native exe's binary cache. Layout (little-endian): "MFV1" | u32 version |
## f32 cell_size | f32[3] aabb_min | f32[3] aabb_size | i32[3] grid | u32 count |
## i32[3N] ijk | f32[3N] rgb | f32[N] complexity | f32[N] collision. local_center is not
## stored — derived (identical to indexToWorld for the uniform axis-aligned grids here).
static func _load_binary(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 52:
		return _empty_voxel_result("binary_truncated")
	var cell_size := bytes.decode_float(8)
	var aabb_min := Vector3(bytes.decode_float(12), bytes.decode_float(16), bytes.decode_float(20))
	var aabb_size := Vector3(bytes.decode_float(24), bytes.decode_float(28), bytes.decode_float(32))
	var grid := Vector3i(bytes.decode_s32(36), bytes.decode_s32(40), bytes.decode_s32(44))
	var n := int(bytes.decode_u32(48))
	if n < 0 or bytes.size() < 52 + 32 * n:
		return _empty_voxel_result("binary_truncated")
	var off := 52
	var ijk := bytes.slice(off, off + 12 * n).to_int32_array(); off += 12 * n
	var rgb := bytes.slice(off, off + 12 * n).to_float32_array(); off += 12 * n
	var cplx := bytes.slice(off, off + 4 * n).to_float32_array(); off += 4 * n
	var coll := bytes.slice(off, off + 4 * n).to_float32_array()
	var voxels: Array[Dictionary] = []
	voxels.resize(n)
	var half := Vector3(0.5, 0.5, 0.5)
	for i in n:
		var gp := Vector3i(ijk[3 * i], ijk[3 * i + 1], ijk[3 * i + 2])
		var complexity := clampf(cplx[i], 0.0, 1.0)
		voxels[i] = {
			"voxel": gp,
			"local_center": aabb_min + (Vector3(gp) + half) * cell_size,
			"color": Color(rgb[3 * i], rgb[3 * i + 1], rgb[3 * i + 2], complexity),
			"complexity": complexity,
			"collision": clampf(coll[i], 0.0, 1.0),
		}
	return _finish_voxel_result(grid, cell_size, aabb_min, aabb_size, voxels)


## Decode the Python fallback's JSON cache (older/exe-less machines).
static func _load_json(text: String) -> Dictionary:
	if text.strip_edges().is_empty():
		return _empty_voxel_result("no_cache")
	var json := JSON.new()
	if json.parse(text) != OK or not (json.data is Dictionary):
		return _empty_voxel_result("parse_error")
	var data: Dictionary = json.data
	var cell_size := float(data.get("cell_size", 0.0))
	var aabb_min := _to_vec3(data.get("aabb_min", []))
	var grid := _to_vec3i(data.get("grid", []))
	var voxels: Array[Dictionary] = []
	for raw in data.get("voxels", []):
		if not raw is Dictionary:
			continue
		var v := raw as Dictionary
		var gpos := _to_vec3i(v.get("voxel", []))
		var complexity := clampf(float(v.get("complexity", 1.0)), 0.0, 1.0)
		var color := _to_color(v.get("color", []), complexity)
		var collision := clampf(float(v.get("collision", 0.0)), 0.0, 1.0)
		var local_center: Vector3
		if v.has("local_center"):
			local_center = _to_vec3(v.get("local_center", []))
		else:
			local_center = aabb_min + (Vector3(gpos) + Vector3(0.5, 0.5, 0.5)) * cell_size
		voxels.append({
			"voxel": gpos,
			"local_center": local_center,
			"color": color,
			"complexity": complexity,
			"collision": collision,
		})
	return _finish_voxel_result(grid, cell_size, aabb_min, _to_vec3(data.get("aabb_size", [])), voxels)


static func _grid_name(setting: String) -> String:
	return str(ProjectSettings.get_setting(setting, _GRID_DEFAULTS[setting]))


## Absolute path to the native OpenVDB reader exe if it exists, else "" (⇒ Python fallback).
static func _resolve_native_exe() -> String:
	var setting := str(ProjectSettings.get_setting(VDB_NATIVE_EXE_SETTING, _NATIVE_EXE_DEFAULT)).strip_edges()
	if setting.is_empty():
		return ""
	var abs := ProjectSettings.globalize_path(setting) if setting.begins_with("res://") else setting
	return abs if FileAccess.file_exists(abs) else ""


static func _to_vec3(value) -> Vector3:
	if value is Array and (value as Array).size() >= 3:
		var a := value as Array
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.ZERO


static func _to_vec3i(value) -> Vector3i:
	if value is Array and (value as Array).size() >= 3:
		var a := value as Array
		return Vector3i(int(round(float(a[0]))), int(round(float(a[1]))), int(round(float(a[2]))))
	return Vector3i.ZERO


static func _to_color(value, alpha: float) -> Color:
	if value is Array and (value as Array).size() >= 3:
		var a := value as Array
		return Color(float(a[0]), float(a[1]), float(a[2]), alpha)
	return Color(1.0, 1.0, 1.0, alpha)
