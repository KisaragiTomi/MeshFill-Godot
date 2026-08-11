class_name ScoreTimingProfiler
extends RefCounted

## GPU 打分管线(score→reduce→stamp)分阶段计时器 —— 用来定位 [VoxelPlacementGenerator]
## run_multi_asset 的性能瓶颈:到底是 CPU 端 setup(缓冲分配/上传)、各 GPU pass
## (score / reduce / stamp / score_sum),还是回读(buffer_get_data)阶段吃掉了时间。
##
## 为什么不能简单地在各 _dispatch_* 外面套墙钟:VPG 平时把 score/reduce/stamp 全部录进
## 各自的 compute list、只在收尾做一次 submit_and_sync(见 run_multi_asset 的收尾同步),GPU 是异步执行的,
## 故 dispatch 调用返回时 GPU 还没跑 —— 在 dispatch 外套墙钟只量到“录命令”的 CPU 开销,量不到
## 任一 pass 的真实 GPU 耗时。
##
## 本 profiler 的做法:开启后,VPG 在 profile 模式下于每个 pass 之后额外插一次 submit_and_sync ——
## sync 会阻塞到该 pass 的 GPU 执行完成,于是相邻两个 [method mark] 之间的墙钟差,就是该 pass 的
## GPU 耗时(外加一次 submit 开销;对个位数微秒的极小 pass 该开销会占主导,正好说明其真实成本低于
## 提交噪声)。这是可靠、无需依赖 GPU timestamp query 帧延迟语义的标准分段计时法。
## 额外插入的 submit_and_sync 仅在 profile 开启时发生,关闭时 run_multi_asset 逐字节等价、零开销。
##
## 用法(调用方 = run_multi_asset):
##   var prof := ScoreTimingProfiler.new(bool(settings.get("score_timing_profile", false)), "leaf")
##   prof.mark("run_start")
##   ... setup ...
##   prof.mark("setup")
##   _dispatch_score(...); if prof.enabled: submit_and_sync(true); prof.mark("score")
##   ... reduce / stamp ...
##   ... readbacks ...; prof.mark("readback")
##   prof.mark("done")
##   output["score_timing_profile"] = prof.build_report()   # 同时累加进静态聚合
## 多次调用后:print(ScoreTimingProfiler.format_aggregate()); ScoreTimingProfiler.reset_aggregate()

var enabled := false
var label := ""
var _marks: Array = []   # 顺序录入的 [{name:String, usec:int}];相邻差即“到该 mark 为止的阶段”耗时

# ---- 跨调用聚合(静态):把每次 build_report 的各阶段耗时累加,供多资产循环后汇总 ----
static var _agg: Dictionary = {}     # phase_name(String) -> usec_total(int)
static var _agg_order: Array = []    # 首次出现顺序,保证汇总按管线顺序打印
static var _agg_calls := 0
static var _agg_total_usec := 0


func _init(is_enabled: bool, run_label := "score") -> void:
	enabled = is_enabled
	label = run_label


## 记录一个墙钟时间戳(阶段边界)。name 即“在此结束的阶段”的名字。关闭时为空操作。
func mark(name: String) -> void:
	if not enabled:
		return
	_marks.append({"name": name, "usec": Time.get_ticks_usec()})


## 由相邻 mark 差算出各阶段耗时,并累加进静态聚合。返回:
##   { label, total_usec, phases: [{name, usec}], phases_by_name: {name: usec} }
## 首个 mark(通常 "run_start")无前驱,不产出阶段,仅作为总时长起点。
func build_report(accumulate := true) -> Dictionary:
	var phases: Array = []
	var by_name: Dictionary = {}
	var total := 0
	for i in range(1, _marks.size()):
		var name: String = _marks[i]["name"]
		var dt: int = int(_marks[i]["usec"]) - int(_marks[i - 1]["usec"])
		phases.append({"name": name, "usec": dt})
		by_name[name] = int(by_name.get(name, 0)) + dt
		total += dt
	# 累加进静态聚合
	if enabled and accumulate and not _marks.is_empty():
		for p in phases:
			var pname: String = p["name"]
			if not _agg.has(pname):
				_agg[pname] = 0
				_agg_order.append(pname)
			_agg[pname] = int(_agg[pname]) + int(p["usec"])
		_agg_calls += 1
		_agg_total_usec += total
	return {
		"label": label,
		"total_usec": total,
		"phases": phases,
		"phases_by_name": by_name,
	}


## 单次调用的人类可读分解(每阶段 ms + 占比)。
func format_report() -> String:
	var rep := {
		"label": label,
		"total_usec": _report_total(),
		"phases": _report_phases(),
	}
	return _format_block("[score-timing] %s" % label, rep["phases"], int(rep["total_usec"]))


func _report_phases() -> Array:
	var phases: Array = []
	for i in range(1, _marks.size()):
		phases.append({
			"name": _marks[i]["name"],
			"usec": int(_marks[i]["usec"]) - int(_marks[i - 1]["usec"]),
		})
	return phases


func _report_total() -> int:
	if _marks.size() < 2:
		return 0
	return int(_marks[_marks.size() - 1]["usec"]) - int(_marks[0]["usec"])


static func _format_block(title: String, phases: Array, total_usec: int) -> String:
	var lines: Array = [title]
	for p in phases:
		var usec := int(p["usec"])
		var pct := 100.0 * float(usec) / float(maxi(total_usec, 1))
		lines.append("  %-12s %8.3f ms  %5.1f%%  %s" % [
			str(p["name"]), float(usec) / 1000.0, pct, _bar(pct)])
	lines.append("  %-12s %8.3f ms  100.0%%" % ["TOTAL", float(total_usec) / 1000.0])
	return "\n".join(lines)


static func _bar(pct: float) -> String:
	var n := int(round(pct / 5.0))   # 每格 5%
	return "#".repeat(clampi(n, 0, 20))


# ---- 静态聚合 API ----------------------------------------------------------

## 多次 build_report 后的汇总(各阶段合计 ms + 占比 + 调用次数)。
static func format_aggregate(title := "aggregate") -> String:
	if _agg_calls == 0:
		return "[score-timing] %s: 无采样(profiler 未启用或未调用)" % title
	var phases: Array = []
	for name in _agg_order:
		phases.append({"name": name, "usec": int(_agg[name])})
	var block := _format_block(
		"[score-timing] %s — %d 次 run_multi_asset 合计:" % [title, _agg_calls],
		phases, _agg_total_usec)
	return block + "\n  (平均每次 %.3f ms)" % [float(_agg_total_usec) / 1000.0 / float(_agg_calls)]


static func reset_aggregate() -> void:
	_agg = {}
	_agg_order = []
	_agg_calls = 0
	_agg_total_usec = 0


