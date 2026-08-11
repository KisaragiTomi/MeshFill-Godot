extends SceneTree

## Drives the running Vulkan editor through the MeshFill bridge. The score,
## fine-selection, and stamp passes therefore use the editor-owned device and
## the same @tool-only production scene as interactive placement.

const HOST := "127.0.0.1"
const PORT := 6800
## 2026-08-03 demo 场景清理：专用的 tools/anchor-timing-benchmark.tscn 已删除，
## 基准改跑 placement-score-3d（SPA/Volumes/VolumeScore 节点路径一致）。
const SCENE_PATH := "res://demos/placement-score-3d/placement-score-3d.tscn"
const SCORE_NODE_PATH := "SPA/Volumes/VolumeScore"
const BENCHMARK_TIMEOUT_MS := 600000

var _warmup_count := 2
var _sample_count := 7
var _settle_msec := 750
var _include_profile := false
var _include_golden := false
var _include_place := false
var _include_cache := false
var _include_place_ready := false
var _include_scene_bootstrap := false
var _place_max_batches := 3
var _next_id := 0


func _initialize() -> void:
	_parse_args()
	_run()


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--warmups="):
			_warmup_count = maxi(int(arg.get_slice("=", 1)), 0)
		elif arg.begins_with("--samples="):
			_sample_count = maxi(int(arg.get_slice("=", 1)), 1)
		elif arg.begins_with("--settle-ms="):
			_settle_msec = maxi(int(arg.get_slice("=", 1)), 0)
		elif arg == "--profile":
			_include_profile = true
		elif arg == "--golden":
			_include_golden = true
		elif arg == "--place":
			_include_place = true
		elif arg == "--cache":
			_include_cache = true
		elif arg == "--place-ready":
			_include_place_ready = true
		elif arg == "--scene-bootstrap":
			_include_scene_bootstrap = true
		elif arg.begins_with("--place-batches="):
			_place_max_batches = clampi(int(arg.get_slice("=", 1)), 1, 16)


func _run() -> void:
	var ping := _result(_request("ping", {}, 5000))
	if str(ping.get("status", "")) != "ok":
		_fail("editor_bridge_unreachable:%s:%d" % [HOST, PORT])
		return
	var original_scene := _result(_request("get_open_scene", {}, 10000))
	var original_scene_path := str(original_scene.get("scene", ""))
	if not _ensure_scene_open():
		_restore_scene(original_scene_path)
		_fail("scene_open_failed:%s" % SCENE_PATH)
		return

	var warmups := PackedFloat64Array()
	for _i in range(_warmup_count):
		var sample := _run_sample(false)
		if not bool(sample.get("ok", false)):
			_restore_scene(original_scene_path)
			_fail("warmup_failed:%s" % str(sample.get("reason", "unknown")))
			return
		warmups.append(float(sample.get("wall_ms", 0.0)))
		_settle()

	var samples := PackedFloat64Array()
	var anchor_counts := PackedInt32Array()
	for _i in range(_sample_count):
		var sample := _run_sample(false)
		if not bool(sample.get("ok", false)):
			_restore_scene(original_scene_path)
			_fail("sample_failed:%s" % str(sample.get("reason", "unknown")))
			return
		samples.append(float(sample.get("wall_ms", 0.0)))
		anchor_counts.append(int(sample.get("anchor_count", 0)))
		_settle()

	var report := _stats_report(warmups, samples, anchor_counts)
	if _include_cache:
		var cache_samples: Array[Dictionary] = []
		for _i in range(_sample_count):
			var cache_sample := _run_cache_sample()
			if not bool(cache_sample.get("ok", false)):
				_restore_scene(original_scene_path)
				_fail("cache_sample_failed:%s" % str(cache_sample.get("reason", "unknown")))
				return
			cache_samples.append(cache_sample)
		report["score_cache_hit"] = _cache_report(cache_samples)
	if _include_place:
		var place_warmups: Array[Dictionary] = []
		for _i in range(_warmup_count):
			var place_warmup := _run_place_sample(false)
			if not bool(place_warmup.get("ok", false)):
				_restore_scene(original_scene_path)
				_fail("place_warmup_failed:%s" % str(place_warmup.get("reason", "unknown")))
				return
			place_warmups.append(place_warmup)
			_settle()
		var place_samples: Array[Dictionary] = []
		for _i in range(_sample_count):
			var place_sample := _run_place_sample(false)
			if not bool(place_sample.get("ok", false)):
				_restore_scene(original_scene_path)
				_fail("place_sample_failed:%s" % str(place_sample.get("reason", "unknown")))
				return
			place_samples.append(place_sample)
			_settle()
		report["place"] = _place_report(place_warmups, place_samples)
	if _include_scene_bootstrap:
		var bootstrap_warmups: Array[Dictionary] = []
		for _i in range(_warmup_count):
			var bootstrap_warmup := _run_scene_bootstrap_sample()
			if not bool(bootstrap_warmup.get("ok", false)):
				_restore_scene(original_scene_path)
				_fail("scene_bootstrap_warmup_failed:%s" % str(bootstrap_warmup.get("reason", "unknown")))
				return
			bootstrap_warmups.append(bootstrap_warmup)
			_settle()
		var bootstrap_samples: Array[Dictionary] = []
		for _i in range(_sample_count):
			var bootstrap_sample := _run_scene_bootstrap_sample()
			if not bool(bootstrap_sample.get("ok", false)):
				_restore_scene(original_scene_path)
				_fail("scene_bootstrap_sample_failed:%s" % str(bootstrap_sample.get("reason", "unknown")))
				return
			bootstrap_samples.append(bootstrap_sample)
			_settle()
		report["scene_bootstrap"] = _scene_bootstrap_report(bootstrap_warmups, bootstrap_samples)
		report["ok"] = bool(report.get("ok", false)) and bool(report["scene_bootstrap"].get("ok", false))
	if _include_place_ready:
		var ready_warmups: Array[Dictionary] = []
		for _i in range(_warmup_count):
			var ready_warmup := _run_ready_place_sample(false)
			if not bool(ready_warmup.get("ok", false)):
				_restore_scene(original_scene_path)
				_fail("place_ready_warmup_failed:%s" % str(ready_warmup.get("reason", "unknown")))
				return
			ready_warmups.append(ready_warmup)
			_settle()
		var ready_samples: Array[Dictionary] = []
		for _i in range(_sample_count):
			var ready_sample := _run_ready_place_sample(false)
			if not bool(ready_sample.get("ok", false)):
				_restore_scene(original_scene_path)
				_fail("place_ready_sample_failed:%s" % str(ready_sample.get("reason", "unknown")))
				return
			ready_samples.append(ready_sample)
			_settle()
		report["place_ready_state"] = _ready_place_report(ready_warmups, ready_samples)
		report["ok"] = bool(report.get("ok", false)) and bool(report["place_ready_state"].get("ok", false))
	if _include_profile:
		var profile := _profile_summary(_run_sample(true))
		var stamp_validation := _placement_profile_summary(_run_stamp_sample(true))
		report["profile"] = profile
		report["stamp_validation"] = stamp_validation
		report["ok"] = bool(report.get("ok", false)) \
			and bool(profile.get("ok", false)) \
			and bool(stamp_validation.get("ok", false))
		if _include_place:
			var place_profile := _run_place_sample(true)
			report["place_profile"] = place_profile
			report["ok"] = bool(report.get("ok", false)) and bool(place_profile.get("ok", false))
	if _include_golden:
		report["golden"] = _golden_report()
	print("[ScoreBenchmark] %s" % JSON.stringify(report))
	_restore_scene(original_scene_path)
	quit(0)


func _run_sample(profile: bool) -> Dictionary:
	var response := _result(_request("call_method", {
		"path": SCORE_NODE_PATH,
		"method": "benchmark_score_once_json",
		"args": [profile],
	}, BENCHMARK_TIMEOUT_MS))
	if not bool(response.get("ok", false)):
		return {
			"ok": false,
			"reason": "benchmark_call_failed:%s" % str(response),
		}
	var parsed = JSON.parse_string(str(response.get("return", "")))
	return parsed if parsed is Dictionary else {"ok": false, "reason": "invalid_benchmark_json"}


func _run_stamp_sample(profile: bool) -> Dictionary:
	var response := _result(_request("call_method", {
		"path": SCORE_NODE_PATH,
		"method": "benchmark_score_stamp_once_json",
		"args": [profile, 64],
	}, BENCHMARK_TIMEOUT_MS))
	if not bool(response.get("ok", false)):
		return {
			"ok": false,
			"reason": "stamp_benchmark_call_failed:%s" % str(response),
		}
	var parsed = JSON.parse_string(str(response.get("return", "")))
	return parsed if parsed is Dictionary else {"ok": false, "reason": "invalid_stamp_benchmark_json"}


func _run_cache_sample() -> Dictionary:
	var response := _result(_request("call_method", {
		"path": SCORE_NODE_PATH,
		"method": "benchmark_score_cache_once_json",
		"args": [],
	}, BENCHMARK_TIMEOUT_MS))
	if not bool(response.get("ok", false)):
		return {"ok": false, "reason": "cache_benchmark_call_failed:%s" % str(response)}
	var parsed = JSON.parse_string(str(response.get("return", "")))
	return parsed if parsed is Dictionary else {"ok": false, "reason": "invalid_cache_benchmark_json"}


func _run_place_sample(profile: bool) -> Dictionary:
	var response := _result(_request("call_method", {
		"path": SCORE_NODE_PATH,
		"method": "benchmark_place_once_json",
		"args": [profile, _place_max_batches],
	}, BENCHMARK_TIMEOUT_MS))
	if not bool(response.get("ok", false)):
		return {"ok": false, "reason": "place_benchmark_call_failed:%s" % str(response)}
	var parsed = JSON.parse_string(str(response.get("return", "")))
	return parsed if parsed is Dictionary else {"ok": false, "reason": "invalid_place_benchmark_json"}


func _run_scene_bootstrap_sample() -> Dictionary:
	var response := _result(_request("call_method", {
		"path": SCORE_NODE_PATH,
		"method": "benchmark_scene_bootstrap_once_json",
		"args": [_place_max_batches],
	}, BENCHMARK_TIMEOUT_MS))
	if not bool(response.get("ok", false)):
		return {"ok": false, "reason": "scene_bootstrap_call_failed:%s" % str(response)}
	var parsed = JSON.parse_string(str(response.get("return", "")))
	return parsed if parsed is Dictionary else {"ok": false, "reason": "invalid_scene_bootstrap_json"}


func _run_ready_place_sample(profile: bool) -> Dictionary:
	var response := _result(_request("call_method", {
		"path": SCORE_NODE_PATH,
		"method": "benchmark_place_ready_once_json",
		"args": [profile, _place_max_batches],
	}, BENCHMARK_TIMEOUT_MS))
	if not bool(response.get("ok", false)):
		return {"ok": false, "reason": "place_ready_call_failed:%s" % str(response)}
	var parsed = JSON.parse_string(str(response.get("return", "")))
	return parsed if parsed is Dictionary else {"ok": false, "reason": "invalid_place_ready_json"}


func _settle() -> void:
	if _settle_msec > 0:
		OS.delay_msec(_settle_msec)


func _profile_summary(sample: Dictionary) -> Dictionary:
	var timing: Dictionary = sample.get("timing", {})
	var core: Dictionary = timing.get("score_core_detail", {})
	var regions: Array = core.get("regions", [])
	var region: Dictionary = regions[0] if not regions.is_empty() else {}
	var vpg: Dictionary = region.get("vpg", {})
	var visualization: Dictionary = timing.get("visualization_detail", {})
	return {
		"ok": bool(sample.get("ok", false)),
		"wall_ms": float(sample.get("wall_ms", 0.0)),
		"anchor_count": int(sample.get("anchor_count", 0)),
		"wall_phases_us": timing.get("phases_by_name", {}),
		"core_phases_us": core.get("phases_by_name", {}),
		"fine_phases_us": region.get("phases_by_name", {}),
		"resident_field_mode": str(region.get("resident_field_mode", "unknown")),
		"fine_gpu_us": int((vpg.get("phases_by_name", {}) as Dictionary).get("fine_score", 0)),
		"visualization_us": int(visualization.get("total_usec", 0)),
		"visualization_cache_mode": str(visualization.get("cache_mode", "unknown")),
	}


func _placement_profile_summary(sample: Dictionary) -> Dictionary:
	var timing: Dictionary = sample.get("timing", {})
	var phases: Dictionary = timing.get("phases_by_name", {})
	return {
		"ok": bool(sample.get("ok", false)),
		"reason": str(sample.get("reason", "ok")),
		"wall_ms": float(sample.get("wall_ms", 0.0)),
		"anchor_count": int(sample.get("anchor_count", 0)),
		"placed_count": int(sample.get("placed_count", 0)),
		"stamp_dispatched": bool(sample.get("stamp_dispatched", false)),
		"stamp_writeback_reason": str(sample.get("stamp_writeback_reason", "missing")),
		"profile_contract_ok": bool(sample.get("profile_contract_ok", false)),
		"profile_contract_reason": str(sample.get("profile_contract_reason", "missing")),
		"fine_gpu_us": int(phases.get("fine_score", 0)),
		"reduce_gpu_us": int(phases.get("reduce", 0)),
		"stamp_gpu_us": int(phases.get("stamp", 0)),
		"phases_us": phases,
	}


func _stats_report(
		warmups: PackedFloat64Array,
		samples: PackedFloat64Array,
		anchor_counts: PackedInt32Array) -> Dictionary:
	var sorted := Array(samples)
	sorted.sort()
	var total := 0.0
	for value in samples:
		total += value
	var p50_index := int(floor(float(sorted.size() - 1) * 0.5))
	var p95_index := mini(int(ceil(float(sorted.size()) * 0.95)) - 1, sorted.size() - 1)
	return {
		"ok": true,
		"warmups_ms": Array(warmups),
		"samples_ms": Array(samples),
		"p50_ms": float(sorted[p50_index]),
		"p95_ms": float(sorted[p95_index]),
		"mean_ms": total / float(samples.size()),
		"anchor_counts": Array(anchor_counts),
		"settle_ms": _settle_msec,
	}


func _cache_report(samples: Array[Dictionary]) -> Dictionary:
	var wall := PackedFloat64Array()
	var hit_count := 0
	var fine_dispatches := 0
	for sample in samples:
		wall.append(float(sample.get("wall_ms", 0.0)))
		hit_count += 1 if bool(sample.get("score_cache_hit", false)) else 0
		fine_dispatches += int(sample.get("fine_dispatch_count", 0))
	return {
		"sample_count": samples.size(),
		"wall_ms": _float_stats(wall),
		"cache_hits": hit_count,
		"fine_dispatch_count": fine_dispatches,
		"timing_last_ms": samples[-1].get("timing", {}) if not samples.is_empty() else {},
	}


func _place_report(warmups: Array[Dictionary], samples: Array[Dictionary]) -> Dictionary:
	var warmup_wall := PackedFloat64Array()
	for sample in warmups:
		warmup_wall.append(float(sample.get("wall_ms", 0.0)))
	var fresh_wall := PackedFloat64Array()
	var resident_wall := PackedFloat64Array()
	var placed_counts := PackedInt32Array()
	var batch_counts := PackedInt32Array()
	var target_cache_hits := 0
	var resident_sample_count := 0
	for sample in samples:
		fresh_wall.append(float(sample.get("wall_ms", 0.0)))
		placed_counts.append(int(sample.get("spawned", 0)))
		batch_counts.append(int(sample.get("batches", 0)))
		for raw_batch in sample.get("batch_reports", []):
			var batch: Dictionary = raw_batch
			resident_wall.append(float(batch.get("wall_ms", 0.0)))
			resident_sample_count += 1
			target_cache_hits += 1 if bool(batch.get("target_cache_hit", false)) else 0
	return {
		"cold_bootstrap_plus_place_compat": {
			"sample_count": samples.size(),
			"warmups_ms": Array(warmup_wall),
			"wall_ms": _float_stats(fresh_wall),
			"placed_counts": Array(placed_counts),
			"batch_counts": Array(batch_counts),
		},
		"resident_session_batches": {
			"sample_count": resident_sample_count,
			"wall_ms": _float_stats(resident_wall),
			"target_cache_hits": target_cache_hits,
		},
		"max_batches": _place_max_batches,
	}


func _scene_bootstrap_report(warmups: Array[Dictionary], samples: Array[Dictionary]) -> Dictionary:
	var warmup_wall := PackedFloat64Array()
	var wall := PackedFloat64Array()
	var ready_count := 0
	for sample in warmups:
		warmup_wall.append(float(sample.get("wall_ms", 0.0)))
	for sample in samples:
		wall.append(float(sample.get("wall_ms", 0.0)))
		ready_count += 1 if bool((sample.get("identity", {}) as Dictionary).get("ready", false)) else 0
	return {
		"ok": ready_count == samples.size(),
		"sample_count": samples.size(),
		"warmups_ms": Array(warmup_wall),
		"wall_ms": _float_stats(wall),
		"ready_identity_count": ready_count,
		"last_env_phases_ms": samples[-1].get("env_phases_ms", {}) if not samples.is_empty() else {},
		"last_prepare": samples[-1].get("prepare", {}) if not samples.is_empty() else {},
	}


func _ready_place_report(warmups: Array[Dictionary], samples: Array[Dictionary]) -> Dictionary:
	var warmup_wall := PackedFloat64Array()
	var wall := PackedFloat64Array()
	var batch_1 := PackedFloat64Array()
	var batch_2_plus := PackedFloat64Array()
	var batch_1_pipeline := PackedFloat64Array()
	var batch_2_plus_pipeline := PackedFloat64Array()
	var tile_cache_hits := PackedFloat64Array()
	var ready_guards := PackedFloat64Array()
	var fixture_resets := PackedFloat64Array()
	var preparations := PackedFloat64Array()
	var unattributed_ratio := PackedFloat64Array()
	var identity_stable_count := 0
	var ready_guard_hit_count := 0
	var scene_owned_spa_count := 0
	var lifecycle_stable_count := 0
	var target_cache_hits := 0
	var resident_phase_values := {}
	var environment_phase_values := {}
	var demo_phase_values := {}
	for sample in warmups:
		warmup_wall.append(float(sample.get("wall_ms", 0.0)))
	for sample in samples:
		var sample_wall := float(sample.get("wall_ms", 0.0))
		wall.append(sample_wall)
		ready_guards.append(float(sample.get("ready_guard_ms", 0.0)))
		fixture_resets.append(float((sample.get("fixture_reset", {}) as Dictionary).get("wall_ms", 0.0)))
		preparations.append(float((sample.get("prepare", {}) as Dictionary).get("wall_ms", 0.0)))
		identity_stable_count += 1 if bool(sample.get("identity_stable", false)) else 0
		ready_guard_hit_count += 1 if bool(sample.get("ready_guard_cached", false)) else 0
		var identity_before: Dictionary = sample.get("identity_before", {})
		var identity_after: Dictionary = sample.get("identity_after", {})
		scene_owned_spa_count += 1 if bool(identity_before.get("scene_owned_spa", false)) else 0
		var lifecycle_stable := (
			int(identity_before.get("scene_owned_environment_make_count", -1))
				== int(identity_after.get("scene_owned_environment_make_count", -2))
			and int(identity_before.get("scene_owned_environment_dispose_count", -1))
				== int(identity_after.get("scene_owned_environment_dispose_count", -2))
		)
		lifecycle_stable_count += 1 if lifecycle_stable else 0
		var known_ms := _place_known_phase_ms(sample)
		unattributed_ratio.append(maxf(sample_wall - known_ms, 0.0) / maxf(sample_wall, 0.001))
		for raw_batch in sample.get("batch_reports", []):
			var batch: Dictionary = raw_batch
			var pipeline_wall := float(batch.get("wall_ms", 0.0))
			var batch_wall := float(batch.get("total_wall_ms", pipeline_wall))
			if int(batch.get("batch_index", 0)) == 0:
				batch_1.append(batch_wall)
				batch_1_pipeline.append(pipeline_wall)
			else:
				batch_2_plus.append(batch_wall)
				batch_2_plus_pipeline.append(pipeline_wall)
			target_cache_hits += 1 if bool(batch.get("target_cache_hit", false)) else 0
			var resident_phases: Dictionary = batch.get("resident_pipeline_phases_ms", {})
			tile_cache_hits.append(float(resident_phases.get("tile_ensure", 0.0)))
			_append_phase_values(resident_phase_values, resident_phases)
			_append_phase_values(environment_phase_values, batch.get("environment_phases_ms", {}))
			_append_phase_values(demo_phase_values, batch.get("demo_phases_ms", {}))
	return {
		"ok": identity_stable_count == samples.size() \
			and ready_guard_hit_count == samples.size() \
			and scene_owned_spa_count == samples.size() \
			and lifecycle_stable_count == samples.size(),
		"sample_count": samples.size(),
		"warmups_ms": Array(warmup_wall),
		"wall_ms": _float_stats(wall),
		"batch_1_ms": _float_stats(batch_1),
		"batch_2_plus_ms": _float_stats(batch_2_plus),
		"batch_1_pipeline_ms": _float_stats(batch_1_pipeline),
		"batch_2_plus_pipeline_ms": _float_stats(batch_2_plus_pipeline),
		"tile_cache_hit_ms": _float_stats(tile_cache_hits),
		"resident_pipeline_phases_ms": _phase_stats(resident_phase_values),
		"environment_phases_ms": _phase_stats(environment_phase_values),
		"demo_phases_ms": _phase_stats(demo_phase_values),
		"ready_guard_ms": _float_stats(ready_guards),
		"fixture_reset_ms_outside_timing": _float_stats(fixture_resets),
		"prepare_ms_outside_timing": _float_stats(preparations),
		"unattributed_ratio": _float_stats(unattributed_ratio),
		"identity_stable_count": identity_stable_count,
		"ready_guard_cache_hits": ready_guard_hit_count,
		"scene_owned_spa_count": scene_owned_spa_count,
		"lifecycle_stable_count": lifecycle_stable_count,
		"target_cache_hits": target_cache_hits,
		"max_batches": _place_max_batches,
	}


func _place_known_phase_ms(sample: Dictionary) -> float:
	var known := 0.0
	var phases: Dictionary = sample.get("place_phases_ms", {})
	for value in phases.values():
		if value is float or value is int:
			known += float(value)
	for raw_batch in sample.get("batch_reports", []):
		if raw_batch is Dictionary:
			known += float((raw_batch as Dictionary).get(
				"total_wall_ms", (raw_batch as Dictionary).get("wall_ms", 0.0)))
	return known


func _append_phase_values(target: Dictionary, phases: Dictionary) -> void:
	for key in phases:
		var value = phases[key]
		if not (value is float or value is int):
			continue
		var values: PackedFloat64Array = target.get(key, PackedFloat64Array())
		values.append(float(value))
		target[key] = values


func _phase_stats(values_by_phase: Dictionary) -> Dictionary:
	var report := {}
	for key in values_by_phase:
		var values: PackedFloat64Array = values_by_phase[key]
		report[key] = _float_stats(values)
	return report


func _float_stats(values: PackedFloat64Array) -> Dictionary:
	if values.is_empty():
		return {}
	var sorted := Array(values)
	sorted.sort()
	var total := 0.0
	for value in sorted:
		total += float(value)
	var p50_index := clampi(int(ceil(float(sorted.size()) * 0.50)) - 1, 0, sorted.size() - 1)
	var p95_index := clampi(int(ceil(float(sorted.size()) * 0.95)) - 1, 0, sorted.size() - 1)
	return {
		"min": float(sorted[0]),
		"mean": total / float(sorted.size()),
		"p50": float(sorted[p50_index]),
		"p95": float(sorted[p95_index]),
		"max": float(sorted[sorted.size() - 1]),
		"samples": Array(values),
	}


func _golden_report() -> Dictionary:
	var response := _result(_request("call_method", {
		"path": SCORE_NODE_PATH,
		"method": "run_golden_snapshot",
		"args": [],
	}, BENCHMARK_TIMEOUT_MS))
	if not bool(response.get("ok", false)):
		return {"ok": false, "reason": "golden_call_failed:%s" % str(response)}
	var snapshot := str(response.get("return", ""))
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(snapshot.to_utf8_buffer())
	return {
		"ok": true,
		"lines": snapshot.count("\n") + (0 if snapshot.ends_with("\n") else 1),
		"characters": snapshot.length(),
		"sha256": context.finish().hex_encode(),
		"starts_error": snapshot.begins_with("ERROR"),
	}


func _ensure_scene_open() -> bool:
	var scene := _result(_request("get_open_scene", {}, 10000))
	if str(scene.get("scene", "")) == SCENE_PATH:
		return true
	_request("open_scene", {"path": SCENE_PATH}, 120000)
	for _attempt in range(120):
		OS.delay_msec(500)
		scene = _result(_request("get_open_scene", {}, 10000))
		if str(scene.get("scene", "")) == SCENE_PATH:
			return true
	return false


func _restore_scene(scene_path: String) -> void:
	if scene_path.is_empty() or scene_path == SCENE_PATH:
		return
	_request("open_scene", {"path": scene_path}, 120000)


func _result(response: Dictionary) -> Dictionary:
	var result = response.get("result")
	return result if result is Dictionary else {}


func _request(method: String, params: Dictionary, timeout_ms: int) -> Dictionary:
	_next_id += 1
	var peer := StreamPeerTCP.new()
	if peer.connect_to_host(HOST, PORT) != OK:
		return {}
	var deadline := Time.get_ticks_msec() + timeout_ms
	while true:
		peer.poll()
		var status := peer.get_status()
		if status == StreamPeerTCP.STATUS_CONNECTED:
			break
		if status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE:
			return {}
		if Time.get_ticks_msec() > deadline:
			peer.disconnect_from_host()
			return {}
		OS.delay_msec(20)
	var line := JSON.stringify({"id": _next_id, "method": method, "params": params}) + "\n"
	if peer.put_data(line.to_utf8_buffer()) != OK:
		peer.disconnect_from_host()
		return {}
	var bytes := PackedByteArray()
	while Time.get_ticks_msec() <= deadline:
		peer.poll()
		var available := peer.get_available_bytes()
		if available > 0:
			var chunk: Array = peer.get_partial_data(available)
			if int(chunk[0]) == OK:
				bytes.append_array(chunk[1])
			if bytes.has(0x0A):
				break
		elif peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			break
		else:
			OS.delay_msec(20)
	peer.disconnect_from_host()
	if bytes.is_empty():
		return {}
	var response_text := bytes.get_string_from_utf8()
	var newline := response_text.find("\n")
	var parsed = JSON.parse_string(response_text.substr(0, newline) if newline >= 0 else response_text)
	return parsed if parsed is Dictionary else {}


func _fail(reason: String) -> void:
	push_error("[ScoreBenchmark] %s" % reason)
	quit(1)
