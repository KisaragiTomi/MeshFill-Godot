extends SceneTree

# 统一的 SceneTree 测试骨架:消除 tools/test_*.gd 中重复的
# `_init: ok 累积 → "[Tag] ALL TESTS PASSED" / "SOME TESTS FAILED" → quit(0/1)` 样板。
# 用法:
#   - 常规套件:extends 本脚本,_init 里 run_suite("Tag", [_test_a, _test_b, ...])。
#   - 需要前置检查(如 GPU 可用性)或自定义结语时,分开用 run_tests + finish_suite。
# 帧驱动状态机类测试(writer_dispose / brush_overlay)与数据驱动循环(shader_compile)
# 不属于此骨架,保持原状。


## 依次执行 tests(Callable 数组,每个返回 bool),返回是否全部通过。
## stop_on_failure=true 保留 `ok = ok and _test()` 的短路语义(首个失败后跳过其余);
## 默认 false 对应 `ok = _test() and ok`(失败后仍继续跑,便于一次看全所有失败)。
func run_tests(tests: Array[Callable], stop_on_failure: bool = false) -> bool:
	var ok := true
	for test in tests:
		if not ok and stop_on_failure:
			break
		ok = bool(test.call()) and ok
	return ok


## 按结果打印 "[tag] ALL TESTS PASSED" / "[tag] SOME TESTS FAILED" 并 quit(0/1)。
func finish_suite(tag: String, ok: bool) -> void:
	if ok:
		print("[%s] ALL TESTS PASSED" % tag)
		quit(0)
	else:
		push_error("[%s] SOME TESTS FAILED" % tag)
		quit(1)


## run_tests + finish_suite 一步到位。
func run_suite(tag: String, tests: Array[Callable], stop_on_failure: bool = false) -> void:
	finish_suite(tag, run_tests(tests, stop_on_failure))
