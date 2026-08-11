@tool
class_name RDGSelfTest
extends RefCounted

## [RDGBuilder] 家族的验证套件（非生产层，住 scripts/checks/）。每个用例既断言**图编译的结论**
## （切了几段、剔了几个 pass、物理资源复用了几块），也断言**GPU 真跑出来的数值** ——
## 只验前者的话，一个把所有 pass 都剔掉的实现也能满分。
##
## **只在编辑器带 `--rdg-selftest` 启动时才跑**，由 meshfill_editor_plugin 触发：
##
##     & '<godot>' --path '<repo>' -e --rendering-driver vulkan -- --rdg-selftest
##
## 日常开编辑器一行都不跑、一个字都不打印。也不提供 runtime 启动路径：编译期的图结论与运行期的
## 数值都要在**真的有 RenderingDevice** 的环境里验，--headless 拿不到设备，那种 "PASS"
## 只证明没崩（见 CLAUDE.md 的启动策略）。
##
## 自带一个 [GodotComputeShaderBase] 实例当 owner（自有 local device，dispose 时连设备一起收）。

const RDGScript := preload("res://scripts/utils/rdg.gd")
const RDGBuilderScript := preload("res://scripts/utils/rdg_builder.gd")
const RDGPoolScript := preload("res://scripts/utils/rdg_pool.gd")
const RDGResourceScript := preload("res://scripts/utils/rdg_resource.gd")
const ComputeKernelScript := preload("res://scripts/utils/compute_kernel.gd")
const PushConstantLayoutScript := preload("res://scripts/utils/push_constant_layout.gd")
const BaseScript := preload("res://scripts/godot_compute_shader_base.gd")

const SHADER_FILL := "res://shaders/rdg_fill_ramp.glsl"
const SHADER_ADD := "res://shaders/rdg_add.glsl"
const SHADER_SCALE := "res://shaders/rdg_scale.glsl"
const SHADER_ACCUM := "res://shaders/rdg_accum.glsl"
const SHADER_INDIRECT := "res://shaders/rdg_write_indirect_args.glsl"
const SHADER_FILL_TEX := "res://shaders/rdg_fill_texture.glsl"
const SHADER_TEX2BUF := "res://shaders/rdg_texture_to_buffer.glsl"
const SHADER_ADD2SETS := "res://shaders/rdg_add_two_sets.glsl"
const SHADER_FILL_TEX3 := "res://shaders/rdg_fill_texture_3d.glsl"
const SHADER_ATOMIC := "res://shaders/rdg_atomic_accum.glsl"
const SHADER_SAMPLE_TEX := "res://shaders/rdg_sample_texture.glsl"

## 全部 shader 共用同一套 push 布局：counts.x = 元素个数，params.xy = 各自的标量参数。
const PUSH_SCHEMA := [["counts", "uvec4"], ["params", "vec4"]]
## [ComputeKernel] 不记 local_size（组数由调用方按 shader 声明传），故这里各留一份常量。
const LOCAL_X := 64
const LOCAL_2D := 8
const LOCAL_3D := 4
const N := 256

## 基准的两个形状。全是互不相干的 pass，RDG 判零切点、朴素做法要切 passes-1 次。
## 两个形状的意义：切段成本若与 pass 大小无关，那它就是**每次切段的固定边际成本**，
## 于是"值不值得在意"只取决于你的 pass 有多小、有多少个。一个形状给不出这个结论。
const BENCH_SHAPES := [
	{"passes": 24, "floats": 65536, "label": "大 pass（24 个 × 64Ki 浮点）"},
	{"passes": 64, "floats": 256, "label": "小 pass（64 个 × 256 浮点）"},
]
const BENCH_ITERS := 13

## 随机图差分。参数刻意取小整数：仿射参考模型的量级因此稳在 2^24 以内，
## float32 对该范围的整数运算精确，逐元素严格比对不需要放宽阈值。
const FUZZ_SEEDS := 24
const FUZZ_NODES := 14
const FUZZ_N := 128

## 采样用例的纹理尺寸。刻意不与纹理用例的 16×16 撞上：本用例要断言"池里发回来的正好是
## 上一张图还回去的那一块"，同尺寸的纹理被别的用例塞进池会让这条断言测到套件的执行史。
const SAMP_W := 32
const SAMP_H := 32

## 一组不含 SAMPLING 位的 usage。T20 拿它当"不能被采样的纹理"，
## 同时也是"usage 位必须进 pool_key"的反例来源。
const USAGE_STORAGE_ONLY := (
	RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
)

var owner_base: BaseScript = null
var pool: RDGPoolScript = null
var k_fill: ComputeKernelScript = null
var k_add: ComputeKernelScript = null
var k_scale: ComputeKernelScript = null
var k_accum: ComputeKernelScript = null
var k_indirect: ComputeKernelScript = null
var k_fill_tex: ComputeKernelScript = null
var k_tex2buf: ComputeKernelScript = null
var k_add2sets: ComputeKernelScript = null
var k_fill_tex3: ComputeKernelScript = null
var k_atomic: ComputeKernelScript = null
var k_sample_tex: ComputeKernelScript = null

var lines: PackedStringArray = []
var passed := 0
var failed := 0


static func run_all() -> Dictionary:
	return RDGSelfTest.new().run({"self_check": true})


## 用例清单。抽成数组是为了能换顺序跑 —— 见 [method _order_independence_check]。
func _suite() -> Array:
	return [
		["T6", _t6_push_layout], ["T1", _t1_diamond], ["T2", _t2_cull],
		["T3", _t3_pool_reuse], ["T4", _t4_read_write], ["T4b", _t4b_write_supersedes],
		["T5", _t5_external], ["T7", _t7_indirect], ["T8", _t8_texture],
		["T9", _t9_multi_set], ["T10", _t10_clear], ["T12", _t12_double_release_regression],
		["T13", _t13_texture_3d], ["T14", _t14_never_cull], ["T15", _t15_external_texture],
		["T16", _t16_declaration_errors],
		["T19", _t19_empty_dispatch], ["T20", _t20_sampler], ["T21", _t21_atomic_read_write],
		["T22", _t22_prefilter_declaration_equivalence], ["T18", _t18_random_graphs], ["T11", _t11_barrier_benchmark],
	]


## opts:
##   "self_check": bool          —— 跑完后再做一次顺序独立性自检（只有顶层调用传）
##   "order": "reverse"          —— 逆序执行用例
##   "fresh_pool_per_case": bool —— 每个用例换一个空池，消掉跨用例的池状态累积
##   "skip_bench": bool          —— 跳过 T11（纯计时，重复跑没意义且慢）
func run(opts := {}) -> Dictionary:
	lines.append("═══ RDG 自检套件 ═══")

	# 刻意不走 ensure_device()：它在拿不到设备时 push_error + assert，而"当前环境没有
	# RenderingDevice"对本套件是**跳过**而不是失败。静态探测拿到再 attach，路径完全等价。
	# allow_global_fallback=false：全局设备不支持 submit/sync，图执行完立刻回读会读到旧数据。
	var acquired := BaseScript.acquire_rendering_device(true, false)
	var rd: RenderingDevice = acquired.get("rd")
	if rd == null:
		lines.append("  跳过：当前环境没有 local RenderingDevice（headless？）")
		return _result(true)
	owner_base = BaseScript.new()
	owner_base.log_name = "RDGSelfTest"
	if not owner_base.attach_rendering_device(rd, bool(acquired.get("owns", false))):
		lines.append("  中止：attach_rendering_device 失败")
		return _result(false)

	k_fill = _kernel(SHADER_FILL, "rdg_fill_ramp")
	k_add = _kernel(SHADER_ADD, "rdg_add")
	k_scale = _kernel(SHADER_SCALE, "rdg_scale")
	k_accum = _kernel(SHADER_ACCUM, "rdg_accum")
	k_indirect = _kernel(SHADER_INDIRECT, "rdg_write_indirect_args")
	k_fill_tex = _kernel(SHADER_FILL_TEX, "rdg_fill_texture")
	k_tex2buf = _kernel(SHADER_TEX2BUF, "rdg_texture_to_buffer")
	k_add2sets = _kernel(SHADER_ADD2SETS, "rdg_add_two_sets")
	k_fill_tex3 = _kernel(SHADER_FILL_TEX3, "rdg_fill_texture_3d")
	k_sample_tex = _kernel(SHADER_SAMPLE_TEX, "rdg_sample_texture")
	k_atomic = _kernel(SHADER_ATOMIC, "rdg_atomic_accum")
	for k in [k_fill, k_add, k_scale, k_accum, k_indirect, k_fill_tex, k_tex2buf, k_add2sets,
			k_fill_tex3, k_sample_tex, k_atomic]:
		if not k.is_valid():
			lines.append("  中止：kernel '%s' 编译失败" % k.label)
			_teardown()
			return _result(false)

	pool = RDGPoolScript.new(owner_base)

	var cases := _suite()
	if bool(opts.get("skip_bench", false)):
		cases = cases.filter(func(c): return str(c[0]) != "T11")
	if str(opts.get("order", "forward")) == "reverse":
		cases.reverse()
	var fresh_pool := bool(opts.get("fresh_pool_per_case", false))

	for c in cases:
		if fresh_pool:
			pool.dispose()
			pool = RDGPoolScript.new(owner_base)
		(c[1] as Callable).call()
		# uniform set 登记在 owner 的 SCOPE_PASS 下：不定期回收的话，base class 的 RID 跟踪表
		# （线性查重）会涨到几千条，track_rid 退化成 O(n²)，套件会莫名其妙地变慢。
		owner_base.gc_frame()

	lines.append("── 池的跨图累计 ──")
	lines.append("  %s" % str(pool.stats()))
	_teardown()

	if bool(opts.get("self_check", false)):
		_order_independence_check()
	return _result(failed == 0)


func _kernel(path: String, label: String) -> ComputeKernelScript:
	return ComputeKernelScript.create(owner_base, path, PUSH_SCHEMA, label)


## 用例顺序独立性自检。
##
## 主跑用的是「固定顺序 + 全程共享同一个池」，于是存在一类看不见的风险：某条断言其实是靠
## 前面的用例把池填好了才过的。那样的断言测到的是套件自己的执行史，不是被测代码。
##
## 这里把整套用例换两种跑法各跑一遍（各自开独立的 owner 与设备，结果只取通过/失败计数）：
##   逆序 + 共享池     —— 打乱池的填充历史
##   正序 + 每例独立池 —— 直接消掉跨用例的池状态累积（每个用例都面对冷池）
## 两者都必须零失败、且断言条数完全一致（用例本身是确定性的，随机图也是定种子的）。
## T11 是纯计时基准，重复跑没有意义且慢，跳过。
func _order_independence_check() -> void:
	var rev := RDGSelfTest.new().run({"order": "reverse", "skip_bench": true})
	var fresh := RDGSelfTest.new().run({"fresh_pool_per_case": true, "skip_bench": true})

	lines.append("── 用例顺序独立性自检（各自独立 owner/设备，仅取计数）──")
	lines.append("  逆序 + 共享池      ：%d 通过 / %d 失败" % [int(rev["passed"]), int(rev["failed"])])
	lines.append("  正序 + 每例独立池  ：%d 通过 / %d 失败" % [int(fresh["passed"]), int(fresh["failed"])])
	_check(int(rev["failed"]) == 0, "逆序执行后结论不变")
	_check(int(fresh["failed"]) == 0, "每个用例面对冷池时结论不变")
	_check(int(rev["passed"]) == int(fresh["passed"]),
			"两种跑法的断言条数一致（%d / %d）—— 不一致说明有用例的分支受了执行史影响"
					% [int(rev["passed"]), int(fresh["passed"])])


func _teardown() -> void:
	if pool != null:
		pool.dispose()
		pool = null
	if owner_base != null:
		# owner 自有 local device：dispose 顺带 free 掉全部 RID 与设备本身。
		owner_base.dispose()
		owner_base = null


func _result(ok: bool) -> Dictionary:
	lines.append("═══ 结果：%d 通过 / %d 失败 ═══" % [passed, failed])
	return {"ok": ok and failed == 0, "passed": passed, "failed": failed, "report": lines}


# ——————————————————————————————————————————————————————————————
#  用例
# ——————————————————————————————————————————————————————————————

## 菱形依赖。两个填充 pass 互不相干，应当合进同一段（零切）；只有汇聚的 Add 和它下游的
## Scale 各切一次。朴素的"相邻 pass 之间无条件切"要切 3 次。
func _t1_diamond() -> void:
	lines.append("── [T1] 菱形依赖：独立 pass 合段，只在真实汇聚点切 ──")
	var g := _builder()
	var a := g.create_buffer_of_floats("A", N)
	var b := g.create_buffer_of_floats("B", N)
	var c := g.create_buffer_of_floats("C", N)
	var d := g.create_buffer_of_floats("D", N)

	g.add_pass("FillA", k_fill, [RDGScript.write(a)], _push(N, 0.0, 1.0), _g1(k_fill, N))
	g.add_pass("FillB", k_fill, [RDGScript.write(b)], _push(N, 100.0, 2.0), _g1(k_fill, N))
	g.add_pass("Add", k_add, [RDGScript.read(a), RDGScript.read(b), RDGScript.write(c)], _push(N, 0.0, 0.0), _g1(k_add, N))
	g.add_pass("Scale", k_scale, [RDGScript.read(c), RDGScript.write(d)], _push(N, 2.0, 0.0), _g1(k_scale, N))
	g.extract(d)

	_check(g.execute(), "execute 成功")
	var st := g.get_stats()
	_check_eq(st.get("passes_executed"), 4, "执行 pass 数")
	_check_eq(st.get("passes_culled"), 0, "剔除 pass 数")
	_check_eq(st.get("barriers"), 2, "RDG 切段次数")
	_check_eq(st.get("barriers_naive"), 3, "朴素链式切段次数（对照）")

	var expect := func(i: int) -> float: return (float(i) + (100.0 + 2.0 * float(i))) * 2.0
	_check_floats(_read_floats(d.rid, d.logical_size), expect, "D = (A+B)*2")
	lines.append(_indent(g.dump()))
	g.dispose()


## 剔除。插入两个"输出没人读、也没被 extract"的 pass —— 一个源头型、一个消费型，
## 且刻意穿插在有用 pass 中间，证明剔除看的是数据流而不是声明位置。
func _t2_cull() -> void:
	lines.append("── [T2] 剔除：输出无人需要的 pass 不会被派发 ──")
	var g := _builder()
	var a := g.create_buffer_of_floats("A", N)
	var b := g.create_buffer_of_floats("B", N)
	var c := g.create_buffer_of_floats("C", N)
	var d := g.create_buffer_of_floats("D", N)
	var dead_src := g.create_buffer_of_floats("DeadSrc", N)
	var dead_out := g.create_buffer_of_floats("DeadOut", N)

	g.add_pass("FillA", k_fill, [RDGScript.write(a)], _push(N, 0.0, 1.0), _g1(k_fill, N))
	g.add_pass("DeadFill", k_fill, [RDGScript.write(dead_src)], _push(N, 9.0, 9.0), _g1(k_fill, N))
	g.add_pass("FillB", k_fill, [RDGScript.write(b)], _push(N, 100.0, 2.0), _g1(k_fill, N))
	g.add_pass("Add", k_add, [RDGScript.read(a), RDGScript.read(b), RDGScript.write(c)], _push(N, 0.0, 0.0), _g1(k_add, N))
	g.add_pass("DeadScale", k_scale, [RDGScript.read(dead_src), RDGScript.write(dead_out)], _push(N, 3.0, 0.0), _g1(k_scale, N))
	g.add_pass("Scale", k_scale, [RDGScript.read(c), RDGScript.write(d)], _push(N, 2.0, 0.0), _g1(k_scale, N))
	g.extract(d)

	_check(g.execute(), "execute 成功")
	var st := g.get_stats()
	_check_eq(st.get("passes_declared"), 6, "声明 pass 数")
	_check_eq(st.get("passes_culled"), 2, "剔除 pass 数（DeadFill + DeadScale）")
	_check_eq(st.get("passes_executed"), 4, "执行 pass 数")
	_check_eq(st.get("barriers"), 2, "切段次数（与 T1 相同，死 pass 不产生切点）")

	var expect := func(i: int) -> float: return (float(i) + (100.0 + 2.0 * float(i))) * 2.0
	_check_floats(_read_floats(d.rid, d.logical_size), expect, "剔除后数值与 T1 一致")
	lines.append(_indent(g.dump()))
	g.dispose()


## 瞬态池复用。一条 8 环的 scale 链有 9 个虚拟中间量，但任一时刻只有 2 个活着，
## 所以物理内存应当塌到 2 块。纯链式结构下切段次数与朴素做法相同 —— RDG 在这里赢的是内存不是 barrier。
func _t3_pool_reuse() -> void:
	lines.append("── [T3] 瞬态池：9 个虚拟中间量塌成 2 块物理内存 ──")
	var chain := 8
	var g := _builder()
	var cur := g.create_buffer_of_floats("v0", N)
	g.add_pass("Fill", k_fill, [RDGScript.write(cur)], _push(N, 1.0, 0.0), _g1(k_fill, N))
	for i in range(chain):
		var nxt := g.create_buffer_of_floats("v%d" % (i + 1), N)
		g.add_pass("Scale%d" % i, k_scale, [RDGScript.read(cur), RDGScript.write(nxt)],
				_push(N, 2.0, 0.0), _g1(k_scale, N))
		cur = nxt
	g.extract(cur)

	_check(g.execute(), "execute 成功")
	var st := g.get_stats()
	_check_eq(st.get("transient_virtual"), chain + 1, "虚拟瞬态资源数")
	_check_eq(st.get("peak_live_physical"), 2, "峰值同时占用的物理资源")
	# 断言写成 <= 2 而不是 == 某个定值：这条必须对冷池（新建 2 块）与热池（复用、新建 0 块）
	# 同时成立，否则它测的是套件的执行史而不是被测代码 —— 顺序独立性自检正是为此存在。
	_check(int(st.get("physical_created", 99)) <= 2, "本次向设备新建的物理资源 <= 2（实际 %d）" % int(st.get("physical_created", -1)))
	_check_eq(st.get("barriers"), chain, "纯链式：切段次数与朴素做法相同")

	var want := pow(2.0, float(chain))
	var expect := func(_i: int) -> float: return want
	_check_floats(_read_floats(cur.rid, cur.logical_size), expect, "v%d = 1 * 2^%d = %d" % [chain, chain, int(want)])
	lines.append(_indent(g.dump()))
	g.dispose()


## read_write 语义：累加 pass 不取代前面的填充 pass，两者都必须存活。
func _t4_read_write() -> void:
	lines.append("── [T4] read_write：累加不取代上游，填充 pass 存活 ──")
	var g := _builder()
	var acc := g.create_buffer_of_floats("Acc", N)
	var src := g.create_buffer_of_floats("Src", N)

	g.add_pass("FillAcc", k_fill, [RDGScript.write(acc)], _push(N, 10.0, 0.0), _g1(k_fill, N))
	g.add_pass("FillSrc", k_fill, [RDGScript.write(src)], _push(N, 1.0, 0.0), _g1(k_fill, N))
	g.add_pass("Accum1", k_accum, [RDGScript.read(src), RDGScript.read_write(acc)], _push(N, 3.0, 0.0), _g1(k_accum, N))
	g.add_pass("Accum2", k_accum, [RDGScript.read(src), RDGScript.read_write(acc)], _push(N, 5.0, 0.0), _g1(k_accum, N))
	g.extract(acc)

	_check(g.execute(), "execute 成功")
	var st := g.get_stats()
	_check_eq(st.get("passes_culled"), 0, "剔除 pass 数（FillAcc 必须存活）")
	_check_eq(st.get("passes_executed"), 4, "执行 pass 数")

	var expect := func(_i: int) -> float: return 18.0
	_check_floats(_read_floats(acc.rid, acc.logical_size), expect, "Acc = 10 + 1*3 + 1*5 = 18")
	lines.append(_indent(g.dump()))
	g.dispose()


## 反向对照：把同一张图里的累加 pass 误声明成 RDG.write（"我整块覆盖"）。
## 图会据此认定 FillAcc 的产出已被取代并剔除它 —— 这正是 write / read_write 的分界线，
## 也是移植这套东西时最容易踩、且踩了之后 GPU 不报错只出错数的地方。
## 本用例只断言剔除行为，不断言数值（此图的数值本就是错的）。
func _t4b_write_supersedes() -> void:
	lines.append("── [T4b] 反向对照：误用 write 会让上游填充 pass 被剔除 ──")
	var g := _builder()
	var acc := g.create_buffer_of_floats("Acc", N)
	var src := g.create_buffer_of_floats("Src", N)

	g.add_pass("FillAcc", k_fill, [RDGScript.write(acc)], _push(N, 10.0, 0.0), _g1(k_fill, N))
	g.add_pass("FillSrc", k_fill, [RDGScript.write(src)], _push(N, 1.0, 0.0), _g1(k_fill, N))
	g.add_pass("Accum1", k_accum, [RDGScript.read(src), RDGScript.write(acc)], _push(N, 3.0, 0.0), _g1(k_accum, N))
	g.add_pass("Accum2", k_accum, [RDGScript.read(src), RDGScript.write(acc)], _push(N, 5.0, 0.0), _g1(k_accum, N))
	g.extract(acc)

	_check(g.execute(), "execute 成功")
	var st := g.get_stats()
	_check(int(st.get("passes_culled", 0)) >= 1, "误用 write 后 FillAcc 被剔除（剔除数 %d）" % int(st.get("passes_culled", 0)))
	lines.append(_indent(g.dump()))
	g.dispose()


## external 资源：写它是图外可观测的副作用，即使没有 extract 也不能被剔除。
func _t5_external() -> void:
	lines.append("── [T5] external：写外部资源的 pass 永不被剔除 ──")
	var ext_rid := owner_base.storage_buffer_zero(N * 4, BaseScript.SCOPE_PERSISTENT, "rdg_selftest_t5_ext")
	_check(ext_rid.is_valid(), "外部 buffer 创建成功")

	var g := _builder()
	var ext := g.register_external_buffer("Ext", ext_rid, N * 4)
	g.add_pass("FillExt", k_fill, [RDGScript.write(ext)], _push(N, 7.0, 0.5), _g1(k_fill, N))
	# 刻意不调 extract：external 本身就是输出根。

	_check(g.execute(), "execute 成功")
	var st := g.get_stats()
	_check_eq(st.get("passes_culled"), 0, "剔除 pass 数")
	_check_eq(st.get("physical_acquired"), 0, "external 不向池申请物理资源")

	var expect := func(i: int) -> float: return 7.0 + 0.5 * float(i)
	_check_floats(_read_floats(ext_rid, N * 4), expect, "Ext = 7 + 0.5i")
	lines.append(_indent(g.dump()))
	g.dispose()
	owner_base.release_rid(ext_rid)


## indirect dispatch：工作组数由上一个 pass 在 GPU 上算出来。
## 验两件事：(1) INDIRECT 访问确实参与建边，写 args 到读 args 之间自动切了段；
## (2) 参数缓冲带上了 DISPATCH_INDIRECT usage 位 —— 少了它 compute_list_dispatch_indirect
## 拿到的 buffer 没有 BUFFER_USAGE_INDIRECT_BIT，会直接失败。
func _t7_indirect() -> void:
	lines.append("── [T7] indirect dispatch：GPU 算出的工作组数，依赖由图自动接上 ──")
	var g := _builder()
	var args := g.create_indirect_args_buffer("Args")
	var out := g.create_buffer_of_floats("Out", N)

	g.add_pass("WriteArgs", k_indirect, [RDGScript.write(args)], _push(N, 0.0, 0.0, LOCAL_X), Vector3i(1, 1, 1))
	g.add_pass_indirect("FillIndirect", k_fill, [RDGScript.write(out)], _push(N, 3.0, 0.25), args)
	g.extract(out)

	_check(g.execute(), "execute 成功")
	var st := g.get_stats()
	_check_eq(st.get("passes_executed"), 2, "执行 pass 数")
	_check_eq(st.get("passes_culled"), 0, "剔除 pass 数（写 args 的 pass 必须存活）")
	_check_eq(st.get("barriers"), 1, "indirect 依赖强制切段（写 args → 读 args）")

	var expect := func(i: int) -> float: return 3.0 + 0.25 * float(i)
	_check_floats(_read_floats(out.rid, out.logical_size), expect, "Out = 3 + 0.25i（组数由 GPU 写入）")
	lines.append(_indent(g.dump()))
	g.dispose()


## 纹理：storage image 走完整条链路 —— 池化分配、UNIFORM_TYPE_IMAGE 绑定、
## 跨纹理的 RAW 依赖、以及同形状纹理的池复用。
func _t8_texture() -> void:
	lines.append("── [T8] 纹理：storage image 的分配 / 绑定 / 依赖 / 池复用 ──")
	var w := 16
	var h := 16
	var g := _builder()
	var tex := g.create_texture("Tex", RDGScript.texture_2d(w, h))
	var out := g.create_buffer_of_floats("Out", w * h)

	g.add_pass("FillTex", k_fill_tex, [RDGScript.write(tex)], _push(w, 1.0, 2.0, h), _g2(k_fill_tex, w, h))
	g.add_pass("TexToBuf", k_tex2buf, [RDGScript.read(tex), RDGScript.write(out)], _push(w, 0.5, 0.0, h), _g2(k_tex2buf, w, h))
	g.extract(out)

	_check(g.execute(), "execute 成功")
	var st := g.get_stats()
	_check_eq(st.get("passes_executed"), 2, "执行 pass 数")
	_check_eq(st.get("barriers"), 1, "纹理上的 RAW 依赖强制切段")
	_check_eq(st.get("physical_acquired"), 2, "纹理与 buffer 各向池取一块")

	var expect := func(i: int) -> float: return (1.0 + float(i) * 2.0) * 0.5
	_check_floats(_read_floats(out.rid, out.logical_size), expect, "Out = (1 + 2i) * 0.5", w * h)
	lines.append(_indent(g.dump()))
	g.dispose()

	# 同形状的第二张图应当完全命中池：纹理不再向设备新建。
	var g2 := _builder()
	var tex2 := g2.create_texture("Tex2", RDGScript.texture_2d(w, h))
	var out2 := g2.create_buffer_of_floats("Out2", w * h)
	g2.add_pass("FillTex", k_fill_tex, [RDGScript.write(tex2)], _push(w, 0.0, 1.0, h), _g2(k_fill_tex, w, h))
	g2.add_pass("TexToBuf", k_tex2buf, [RDGScript.read(tex2), RDGScript.write(out2)], _push(w, 1.0, 0.0, h), _g2(k_tex2buf, w, h))
	g2.extract(out2)
	_check(g2.execute(), "第二张同形状图 execute 成功")
	_check_eq(g2.get_stats().get("physical_created"), 0, "同形状纹理命中池，零新建")
	g2.dispose()


## 多 uniform set：输入在 set 0、输出在 set 1。
## 错位一个 set 的话 uniform_set_create 未必失败，shader 却会读到别的资源 —— 所以要验数值。
func _t9_multi_set() -> void:
	lines.append("── [T9] 多 uniform set：set 0 收输入、set 1 收输出 ──")
	var g := _builder()
	var a := g.create_buffer_of_floats("A", N)
	var b := g.create_buffer_of_floats("B", N)
	var c := g.create_buffer_of_floats("C", N)

	g.add_pass("FillA", k_fill, [RDGScript.write(a)], _push(N, 4.0, 1.0), _g1(k_fill, N))
	g.add_pass("FillB", k_fill, [RDGScript.write(b)], _push(N, 10.0, 3.0), _g1(k_fill, N))
	g.add_pass("AddTwoSets", k_add2sets,
			[[RDGScript.read(a), RDGScript.read(b)], [RDGScript.write(c)]],
			_push(N, 0.0, 0.0), _g1(k_add2sets, N))
	g.extract(c)

	_check(g.execute(), "execute 成功")
	var st := g.get_stats()
	_check_eq(st.get("passes_executed"), 3, "执行 pass 数")
	_check_eq(st.get("barriers"), 1, "两个填充 pass 合段，汇聚点切一次")

	var expect := func(i: int) -> float: return (4.0 + float(i)) + (10.0 + 3.0 * float(i))
	_check_floats(_read_floats(c.rid, c.logical_size), expect, "C = A + B（输入输出跨两个 set）")
	lines.append(_indent(g.dump()))
	g.dispose()


## clear pass：证明池发回来的内存是脏的，以及 clear 能修好它。
## 分三步：污染池 → 不 clear 直接累加（读到残留）→ 加 clear（结果精确）。
func _t10_clear() -> void:
	lines.append("── [T10] clear pass：池发回来的内存带着上一张图的残留 ──")

	# (1) 污染池：两块填满 999 的 buffer，dispose 后还池。
	var gd := _builder()
	var d1 := gd.create_buffer_of_floats("Dirty1", N)
	var d2 := gd.create_buffer_of_floats("Dirty2", N)
	gd.add_pass("Dirty1", k_fill, [RDGScript.write(d1)], _push(N, 999.0, 0.0), _g1(k_fill, N))
	gd.add_pass("Dirty2", k_fill, [RDGScript.write(d2)], _push(N, 999.0, 0.0), _g1(k_fill, N))
	gd.extract(d1)
	gd.extract(d2)
	_check(gd.execute(), "污染图 execute 成功")
	var dirty_expect := func(_i: int) -> float: return 999.0
	_check_floats(_read_floats(d1.rid, d1.logical_size), dirty_expect, "污染图确实写入了 999")
	gd.dispose()

	# (2) 对照：不 clear 直接 read_write。
	var gc := _builder()
	var src_c := gc.create_buffer_of_floats("Src", N)
	var acc_c := gc.create_buffer_of_floats("Acc", N)
	gc.add_pass("FillSrc", k_fill, [RDGScript.write(src_c)], _push(N, 1.0, 0.0), _g1(k_fill, N))
	gc.add_pass("Accum", k_accum, [RDGScript.read(src_c), RDGScript.read_write(acc_c)], _push(N, 3.0, 0.0), _g1(k_accum, N))
	gc.extract(acc_c)
	# quiet_warnings：这是刻意构造的坏图，别把警告抛进控制台污染门禁输出；
	# 警告本身仍然从 get_warnings() 断言得到。正常路径不该开这个开关。
	_check(gc.execute({"quiet_warnings": true}), "对照图 execute 成功")
	_check(gc.get_warnings().size() >= 1, "图对「读未初始化资源」发出了警告")
	var got_c := _read_floats(acc_c.rid, acc_c.logical_size)
	_check(got_c.size() > 0 and absf(got_c[0] - 3.0) > 0.5,
			"未 clear 时读到池内残留（got[0]=%.1f，干净起点本应是 3）" % (got_c[0] if got_c.size() > 0 else NAN))
	gc.dispose()

	# (3) 加 clear：结果精确，且警告消失。
	var gk := _builder()
	var src_k := gk.create_buffer_of_floats("Src", N)
	var acc_k := gk.create_buffer_of_floats("Acc", N)
	gk.add_pass("FillSrc", k_fill, [RDGScript.write(src_k)], _push(N, 1.0, 0.0), _g1(k_fill, N))
	gk.add_clear_pass("ClearAcc", acc_k, 0.0)
	gk.add_pass("Accum", k_accum, [RDGScript.read(src_k), RDGScript.read_write(acc_k)], _push(N, 3.0, 0.0), _g1(k_accum, N))
	gk.extract(acc_k)
	_check(gk.execute(), "clear 图 execute 成功")
	_check_eq(gk.get_stats().get("passes_executed"), 3, "执行 pass 数（clear 是图里的正常 pass）")
	_check_eq(gk.get_warnings().size(), 0, "有 clear 之后不再有未初始化警告")
	var expect := func(_i: int) -> float: return 3.0
	_check_floats(_read_floats(acc_k.rid, acc_k.logical_size), expect, "Acc = 0 + 1*3 = 3")
	lines.append(_indent(gk.dump()))
	gk.dispose()


## A/B 基准：同一张图，一次按依赖切段、一次每个 pass 前都切（= [ComputePassChain] 现有行为）。
## 24 个互不相干的 pass：RDG 判零切点，朴素做法要切 23 次。
## 只报测量结果，不断言快慢 —— 这是一次真实测量，不是我想要的结论。
func _t11_barrier_benchmark() -> void:
	lines.append("── [T11] 基准：RDG 按依赖切段 vs 朴素全切（同图 A/B 对照）──")
	lines.append("      切段的开销分两块：**录制阶段的 CPU 重绑**（compute_list_add_barrier 内部是")
	lines.append("      end+begin+重绑 pipeline/全部 set/push），与 **submit 之后等 GPU** 的时间。")
	lines.append("      两者混在一起测，切段成本会掉进提交/栅栏的固定开销与调度噪声里 —— 那样能测出")
	lines.append("      负的边际成本，显然不是真实效应。所以分开报。")
	lines.append("      CPU 录制取 %d 次的**最小值**（延迟测量惯例：最小值受 OS 干扰最少）；" % BENCH_ITERS)
	lines.append("      等 GPU 那段取中位数。")

	for shape in BENCH_SHAPES:
		var passes := int(shape["passes"])
		var floats := int(shape["floats"])
		var label := str(shape["label"])
		var cuts := passes - 1

		var a := _bench(false, passes, floats)
		var b := _bench(true, passes, floats)
		_check(int(a["ok"]) == 1 and int(b["ok"]) == 1, "%s：两个变体都 execute 成功" % label)
		_check_eq(a["barriers"], 0, "%s：RDG 切段次数（全独立）" % label)
		_check_eq(b["barriers"], cuts, "%s：朴素全切的切段次数" % label)
		_check(float(a["record_min"]) > 0.0, "%s：录制耗时可测" % label)

		var d_rec := float(b["record_min"]) - float(a["record_min"])
		var d_sync := float(b["sync_med"]) - float(a["sync_med"])
		lines.append("      %s：" % label)
		lines.append("        CPU 录制     切 0 次 %8.1f µs | 切 %2d 次 %8.1f µs → 差 %+7.1f µs（每切一次 %+.2f µs）" % [
				float(a["record_min"]), cuts, float(b["record_min"]), d_rec, d_rec / float(maxi(cuts, 1))])
		lines.append("        submit+等GPU 切 0 次 %8.1f µs | 切 %2d 次 %8.1f µs → 差 %+7.1f µs（噪声主导，勿当结论）" % [
				float(a["sync_med"]), cuts, float(b["sync_med"]), d_sync])


## 跑 BENCH_ITERS 次，返回 {ok, barriers, record_min, sync_med}。
func _bench(force_all: bool, passes: int, floats: int) -> Dictionary:
	var records: Array[float] = []
	var syncs: Array[float] = []
	var ok := 1
	var barriers := -1
	for _i in range(BENCH_ITERS):
		var r := _run_bench_graph(force_all, passes, floats)
		if int(r["ok"]) != 1:
			ok = 0
		barriers = r["barriers"]
		records.append(float(r["record_usec"]))
		syncs.append(float(r["sync_usec"]))
	records.sort()
	syncs.sort()
	return {
		"ok": ok, "barriers": barriers,
		"record_min": records[0],
		"sync_med": syncs[int(syncs.size() / 2)],
	}


func _run_bench_graph(force_all: bool, passes: int, floats: int) -> Dictionary:
	var g := _builder()
	for i in range(passes):
		var buf := g.create_buffer_of_floats("bench%d" % i, floats)
		g.add_pass("Fill%d" % i, k_fill, [RDGScript.write(buf)],
				_push(floats, float(i), 1.0), _g1(k_fill, floats))
		g.extract(buf)   # 全部 extract，保证一个都不会被剔除，两个变体跑的是同样的活
	var ok := g.execute({"force_all_barriers": force_all})
	var st := g.get_stats()
	g.dispose()
	# 每图几十个 uniform set：不当场回收的话，owner 的 RID 跟踪表会涨到几千条，
	# 而 track_rid 是线性查重 —— 基准本身就会被这条 O(n²) 淹掉，测出来的是套件的膨胀速度。
	owner_base.gc_frame()
	return {
		"ok": 1 if ok else 0,
		"barriers": st.get("barriers", -1),
		"record_usec": st.get("record_usec", 0.0),
		"sync_usec": st.get("submit_sync_usec", 0.0),
	}


## 回归测试：同一个资源在一个 pass 里被访问多次时，只能还池一次。
##
## 曾经的 bug：归还循环遍历 pass 的全部访问，x 绑在 binding 0 和 binding 1 上就被归还两次，
## 空闲表里于是有两份同一个 RID，接下来两个不同的资源拿到同一块物理内存互相踩踏 ——
## 全程无报错，只是数值错。这个图的形状刚好能把它逼出来：
##   p1 里 x 出现两次（Add(x, x) -> y），且 p1 就是 x 的生命周期终点；
##   p2 / p3 在同一段内各取一块新资源，坏掉的话两块会是同一个 RID。
func _t12_double_release_regression() -> void:
	lines.append("── [T12] 回归：一个 pass 里重复访问同一资源，只能还池一次 ──")
	var g := _builder()
	var x := g.create_buffer_of_floats("X", N)
	var y := g.create_buffer_of_floats("Y", N)
	var z1 := g.create_buffer_of_floats("Z1", N)
	var z2 := g.create_buffer_of_floats("Z2", N)

	g.add_pass("FillX", k_fill, [RDGScript.write(x)], _push(N, 100.0, 0.0), _g1(k_fill, N))
	# 同一个 buffer 同时绑到 binding 0 与 binding 1 —— 合法且常见的写法。
	g.add_pass("AddXX", k_add, [RDGScript.read(x), RDGScript.read(x), RDGScript.write(y)], _push(N, 0.0, 0.0), _g1(k_add, N))
	g.add_pass("ScaleA", k_scale, [RDGScript.read(y), RDGScript.write(z1)], _push(N, 1.0, 0.0), _g1(k_scale, N))
	g.add_pass("ScaleB", k_scale, [RDGScript.read(y), RDGScript.write(z2)], _push(N, 2.0, 0.0), _g1(k_scale, N))
	g.extract(z1)
	g.extract(z2)

	_check(g.execute(), "execute 成功")
	# 最锋利的一条断言：两个同时存活的资源绝不能拿到同一个物理 RID。
	_check(z1.rid != z2.rid, "同段内并存的 Z1 / Z2 拿到了不同的物理资源")
	var e1 := func(_i: int) -> float: return 200.0
	var e2 := func(_i: int) -> float: return 400.0
	_check_floats(_read_floats(z1.rid, z1.logical_size), e1, "Z1 = (X+X)*1 = 200")
	_check_floats(_read_floats(z2.rid, z2.logical_size), e2, "Z2 = (X+X)*2 = 400")
	lines.append(_indent(g.dump()))
	g.dispose()


## 3D 纹理：MeshFill 的体素场用的就是这条路径，只验 2D 不能假定 depth>1 也能跑。
## 写完直接回读纹理本身（不需要额外的读 shader）。
func _t13_texture_3d() -> void:
	lines.append("── [T13] 3D 纹理：image3D 的分配 / 绑定 / 回读 ──")
	var s := 8
	var voxels := s * s * s
	var g := _builder()
	var vol := g.create_texture("Vol", RDGScript.texture_3d(s, s, s))
	g.add_pass("FillVol", k_fill_tex3, [RDGScript.write(vol)], _push(s, 5.0, 1.0, s, s), _g3(k_fill_tex3, s, s, s))
	g.extract(vol)

	_check(g.execute(), "execute 成功")
	var got := _read_texture_floats(vol.rid, 0)
	_check_eq(got.size(), voxels, "3D 纹理回读的浮点数量")
	var expect := func(i: int) -> float: return 5.0 + float(i)
	_check_floats(got, expect, "Vol = 5 + i（%d 体素）" % voxels, voxels)
	lines.append(_indent(g.dump()))
	g.dispose()


## never_cull：产出图看不见（纯副作用）的 pass 强制存活。
## 正反对照，顺便覆盖"整张图被剔空"这个边界 —— 那时应当一条 dispatch 都不录、连 submit 都省掉。
func _t14_never_cull() -> void:
	lines.append("── [T14] never_cull：强制存活，兼验整图被剔空的边界 ──")

	var g1 := _builder()
	var x1 := g1.create_buffer_of_floats("X", N)
	var y1 := g1.create_buffer_of_floats("Y", N)
	g1.add_pass("Fill", k_fill, [RDGScript.write(x1)], _push(N, 1.0, 0.0), _g1(k_fill, N))
	g1.add_pass("Scale", k_scale, [RDGScript.read(x1), RDGScript.write(y1)], _push(N, 2.0, 0.0), _g1(k_scale, N))
	_check(g1.execute(), "对照图 execute 成功")
	var st1 := g1.get_stats()
	_check_eq(st1.get("passes_executed"), 0, "没有输出根时两个 pass 全被剔除")
	_check_eq(st1.get("physical_acquired"), 0, "空图不向池申请任何物理资源")
	_check_eq(st1.get("record_usec"), 0.0, "空图不录制、也不 submit+sync")
	g1.dispose()

	var g2 := _builder()
	var x2 := g2.create_buffer_of_floats("X", N)
	var y2 := g2.create_buffer_of_floats("Y", N)
	g2.add_pass("Fill", k_fill, [RDGScript.write(x2)], _push(N, 1.0, 0.0), _g1(k_fill, N))
	g2.add_pass("Scale", k_scale, [RDGScript.read(x2), RDGScript.write(y2)], _push(N, 2.0, 0.0),
			_g1(k_scale, N), {"never_cull": true})
	_check(g2.execute(), "never_cull 图 execute 成功")
	_check_eq(g2.get_stats().get("passes_executed"), 2, "never_cull 让 Scale 及其上游 Fill 都存活")
	lines.append(_indent(g2.dump()))
	g2.dispose()


## 外部纹理：register_external_texture 的覆盖。
func _t15_external_texture() -> void:
	lines.append("── [T15] 外部纹理：注册图外既有的 storage image ──")
	var w := 16
	var h := 16
	var desc := RDGScript.texture_2d(w, h)
	var ext_rid := owner_base.create_rw_texture_2d(w, h, desc.format, desc.usage,
			BaseScript.SCOPE_PERSISTENT, "rdg_selftest_t15_ext")
	_check(ext_rid.is_valid(), "外部纹理创建成功")

	var g := _builder()
	var ext := g.register_external_texture("ExtTex", ext_rid, desc)
	g.add_pass("FillExtTex", k_fill_tex, [RDGScript.write(ext)], _push(w, 3.0, 0.25, h), _g2(k_fill_tex, w, h))
	# 不 extract：external 本身就是输出根。

	_check(g.execute(), "execute 成功")
	var st := g.get_stats()
	_check_eq(st.get("passes_culled"), 0, "写外部纹理的 pass 不被剔除")
	_check_eq(st.get("physical_acquired"), 0, "external 纹理不向池申请物理资源")

	var expect := func(i: int) -> float: return 3.0 + 0.25 * float(i)
	_check_floats(_read_texture_floats(ext_rid, 0), expect, "ExtTex = 3 + 0.25i", w * h)
	lines.append(_indent(g.dump()))
	g.dispose()
	owner_base.release_rid(ext_rid)


## 声明期校验：坏图在 add_pass 当场就被记下来，不用 execute 就能查。
## 刻意**不调 execute()** —— 既证明拦截发生在声明期，也让本用例不往控制台抛任何 error。
func _t16_declaration_errors() -> void:
	lines.append("── [T16] 声明期校验：坏图不用 execute 就已被拦下 ──")

	var g1 := _builder()
	var a1 := g1.create_buffer_of_floats("A", N)
	var b1 := g1.create_buffer_of_floats("B", N)
	g1.add_pass("Mixed", k_add, [RDGScript.read(a1), [RDGScript.write(b1)]], _push(N, 0.0, 0.0), _g1(k_add, N))
	_check(_mentions(g1.get_errors(), "混用"), "扁平项与嵌套数组混用被拦下")

	var g2 := _builder()
	var a2 := g2.create_buffer_of_floats("A", N)
	var b2 := g2.create_buffer_of_floats("B", N)
	g2.add_pass("Raw", k_scale, [a2, b2], _push(N, 1.0, 0.0), _g1(k_scale, N))
	_check(_mentions(g2.get_errors(), "不是 RDG.read"), "漏写 RDG.read/write、直接传资源被拦下")

	var g3 := _builder()
	var t3 := g3.create_texture("Tex", RDGScript.texture_2d(8, 8))
	_check(g3.add_clear_pass("ClearTex", t3) == null, "add_clear_pass 对纹理返回 null")
	_check(_mentions(g3.get_errors(), "只支持 buffer"), "clear 纹理被拦下")

	# extract 了一个没人写的资源：拿不到物理资源，回读会安静地返回空。必须出声。
	# 这张图同时是"整图为空"的另一条路径（0 个 pass）。
	var g4 := _builder()
	var orphan := g4.create_buffer_of_floats("Orphan", N)
	g4.extract(orphan)
	_check(g4.execute({"quiet_warnings": true}), "无 pass 的图 execute 成功")
	_check(_mentions(g4.get_warnings(), "没有任何 pass 写它"), "extract 了从没被写过的资源 → 警告")
	_check(not orphan.rid.is_valid(), "该资源确实没拿到物理资源")
	g4.dispose()


## 零工作量 pass：「本帧候选数为 0」在真实管线里很常见，算出来就是 0 个工作组。
## Godot 在 DEBUG 下对 0 组 dispatch 会报错并跳过，不拦的话就是每帧刷一条错误日志。
## 同时验一条更要紧的：**跳过派发不能跟着跳过切段** —— 这里 FillX 与 ScaleZ 正是靠
## EmptyScale 前面那一刀隔开的，连它一起省掉就是静默数据竞争。
func _t19_empty_dispatch() -> void:
	lines.append("── [T19] 零工作量 pass：不派发，但切段照发 ──")
	var g := _builder()
	var x := g.create_buffer_of_floats("X", N)
	var y := g.create_buffer_of_floats("Y", N)
	var z := g.create_buffer_of_floats("Z", N)

	g.add_pass("FillX", k_fill, [RDGScript.write(x)], _push(N, 7.0, 0.0), _g1(k_fill, N))
	g.add_pass("EmptyScale", k_scale, [RDGScript.read(x), RDGScript.write(y)], _push(0, 1.0, 0.0), _g1(k_scale, 0))
	g.add_pass("ScaleZ", k_scale, [RDGScript.read(x), RDGScript.write(z)], _push(N, 2.0, 0.0), _g1(k_scale, N))
	g.extract(y)   # 让 EmptyScale 不被剔除，否则测不到零派发这条路径
	g.extract(z)

	_check(g.execute(), "execute 成功（0 组的 pass 不该刷错误日志）")
	var st := g.get_stats()
	_check_eq(st.get("empty_dispatches"), 1, "识别出 1 个零工作量 pass")
	_check_eq(st.get("passes_executed"), 3, "它仍是图里的正常 pass，照常参与依赖与生命周期")
	_check_eq(st.get("barriers"), 1, "切段照发（省掉它 FillX 与 ScaleZ 会落进同一段）")

	var expect := func(_i: int) -> float: return 14.0
	_check_floats(_read_floats(z.rid, z.logical_size), expect, "Z = 7 * 2 = 14")
	lines.append(_indent(g.dump()))
	g.dispose()


## 采样器 + 纹理绑定：texture(sampler2D, vec2) 这条路径。
##
## 与 T8 的 imageLoad 不是同一件事：uniform 类型不同（SAMPLER_WITH_TEXTURE vs IMAGE）、
## 绑法不同（两个 RID，先 sampler 后 texture）、对纹理 usage 位的要求也不同。
##
## 除数值之外还要钉住一条池的不变量：**usage 位不同的纹理绝不能互换复用**。
## pool_key 里漏掉 usage 的话，一块没有 SAMPLING 位的纹理会被发给采样 pass，
## 而图完全看不出这件事。(C)/(D) 是这条的正反对照。
func _t20_sampler() -> void:
	lines.append("── [T20] 采样器 + 纹理绑定：sampler2D 采样，usage 位进池 key ──")
	var w := SAMP_W
	var h := SAMP_H
	var texels := w * h

	# 语义自检：sample 复用 Access.READ，所以它必须被当成读 —— 否则 RAW 边不建，
	# 写纹理的上游 pass 会被剔除，采样 pass 采到的是池里的残留。
	var probe := RDGScript.sample(null, RID())
	_check(RDGScript.is_read(probe["access"]), "RDG.sample 构成读（is_read 为真 → 会建 RAW 边）")
	_check(not RDGScript.is_write(probe["access"]), "RDG.sample 不构成写")

	# NEAREST + CLAMP_TO_EDGE 才写得出确定的期望值。LINEAR 会把相邻纹素插进来，
	# 而且 R32_SFLOAT 的线性过滤在 Vulkan 里并非必备格式特性。
	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	ss.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	var samp := owner_base.track_rid(owner_base.get_rendering_device().sampler_create(ss),
			BaseScript.KIND_SAMPLER, BaseScript.SCOPE_PERSISTENT, "rdg_selftest_nearest_sampler")
	_check(samp.is_valid(), "NEAREST/CLAMP 采样器创建成功")
	# base class 自带的线性采样器工厂同样可以直接喂给 RDG.sample（采样器属于绑定、不是图资源）。
	var linear := owner_base.create_linear_sampler(BaseScript.SCOPE_PERSISTENT, "rdg_selftest_linear_sampler")
	_check(linear.is_valid(), "owner.create_linear_sampler() 可直接用作 RDG.sample 的采样器")
	owner_base.release_rid(linear)

	var key_sampling := RDGScript.texture_2d(w, h).pool_key()
	var key_storage := RDGScript.texture_2d(w, h, RenderingDevice.DATA_FORMAT_R32_SFLOAT, USAGE_STORAGE_ONLY).pool_key()
	_check(key_sampling != key_storage, "usage 位不同的纹理 pool_key 不同（%s vs %s）" % [key_sampling, key_storage])

	# (A) 写纹理 → 采样它 → 写进 buffer 回读，逐元素比对。
	var base := 2.0
	var stride := 3.0
	var kmul := 0.25
	var ga := _builder()
	var tex_a := ga.create_texture("SampTex", RDGScript.texture_2d(w, h))
	var out_a := ga.create_buffer_of_floats("Out", texels)
	ga.add_pass("FillTex", k_fill_tex, [RDGScript.write(tex_a)], _push(w, base, stride, h), _g2(k_fill_tex, w, h))
	ga.add_pass("SampleTex", k_sample_tex, [RDGScript.sample(tex_a, samp), RDGScript.write(out_a)],
			_push(w, kmul, 0.0, h), _g2(k_sample_tex, w, h))
	ga.extract(out_a)

	_check(ga.execute(), "execute 成功")
	var sta := ga.get_stats()
	_check_eq(sta.get("passes_executed"), 2, "执行 pass 数")
	_check_eq(sta.get("passes_culled"), 0, "剔除 pass 数（采样读必须让写纹理的 pass 存活）")
	_check_eq(sta.get("barriers"), 1, "纹理上的 RAW 依赖强制切段（imageStore 写 → sampler2D 读）")
	_check_eq(sta.get("physical_acquired"), 2, "纹理与 buffer 各向池取一块（采样器不是池资源）")
	var expect_a := func(i: int) -> float: return (base + float(i) * stride) * kmul
	_check_floats(_read_floats(out_a.rid, out_a.logical_size), expect_a,
			"Out = (2 + 3i) * 0.25（采样点对准像素中心）", texels)
	var recycled := tex_a.rid    # 记下来：(C)/(D) 要断言它被谁复用、又没被谁复用
	lines.append(_indent(ga.dump()))
	ga.dispose()

	# (B) 采样点右移一个纹素。这条区分「真的走了归一化 UV + 寻址模式」与「其实等价于 texelFetch」：
	# 右边界越界的那一列必须被 CLAMP_TO_EDGE 夹回最后一个纹素。
	# 期望值先在 CPU 上摊平成数组，lambda 里就不用做整数除法反算 x/y 了。
	var want_b := PackedFloat32Array()
	want_b.resize(texels)
	var at := 0
	for y in range(h):
		for x in range(w):
			var xs := mini(x + 1, w - 1)
			want_b[at] = (base + float(y * w + xs) * stride) * kmul
			at += 1

	var gb := _builder()
	var tex_b := gb.create_texture("SampTex", RDGScript.texture_2d(w, h))
	var out_b := gb.create_buffer_of_floats("Out", texels)
	gb.add_pass("FillTex", k_fill_tex, [RDGScript.write(tex_b)], _push(w, base, stride, h), _g2(k_fill_tex, w, h))
	gb.add_pass("SampleShifted", k_sample_tex, [RDGScript.sample(tex_b, samp), RDGScript.write(out_b)],
			_push(w, kmul, 1.0, h), _g2(k_sample_tex, w, h))
	gb.extract(out_b)
	_check(gb.execute(), "采样点右移一纹素的图 execute 成功")
	var expect_b := func(i: int) -> float: return want_b[i]
	_check_floats(_read_floats(out_b.rid, out_b.logical_size), expect_b,
			"右移一纹素，最后一列被 CLAMP_TO_EDGE 夹住", texels)
	gb.dispose()

	# (C) usage 位不同 → 不许复用池里那块。pool_key 少了 usage 的话这里会拿到 (A) 还回去的
	# 那块能采样的纹理，测试照样绿；而真实场景里方向是反的 —— 一块不能采样的纹理被发给采样 pass，
	# 报错发生在 uniform_set_create，离写错的那一行已经很远。
	var gc := _builder()
	var tex_c := gc.create_texture("StorageOnly",
			RDGScript.texture_2d(w, h, RenderingDevice.DATA_FORMAT_R32_SFLOAT, USAGE_STORAGE_ONLY))
	gc.add_pass("FillTex", k_fill_tex, [RDGScript.write(tex_c)], _push(w, 1.0, 1.0, h), _g2(k_fill_tex, w, h))
	gc.extract(tex_c)
	_check(gc.execute(), "storage-only usage 的图 execute 成功")
	_check_eq(gc.get_stats().get("physical_created"), 1, "usage 不同 → 不算命中，新建一块")
	_check(tex_c.rid != recycled, "确实没有复用 (A) 还回池的那块能采样的纹理")
	var expect_c := func(i: int) -> float: return 1.0 + float(i)
	_check_floats(_read_texture_floats(tex_c.rid, 0), expect_c, "storage-only 纹理照样能写能回读", texels)
	gc.dispose()

	# (D) 反向对照：usage 相同 → 必须命中池，而且拿到的就是 (A) 还回去的那一块。
	# 没有这条，(C) 的"没复用"也可能只是因为这个 key 从来就不会命中。
	var gd := _builder()
	var tex_d := gd.create_texture("SampTexAgain", RDGScript.texture_2d(w, h))
	gd.add_pass("FillTex", k_fill_tex, [RDGScript.write(tex_d)], _push(w, 0.0, 1.0, h), _g2(k_fill_tex, w, h))
	gd.extract(tex_d)
	_check(gd.execute(), "同 usage 的图 execute 成功")
	_check_eq(gd.get_stats().get("physical_created"), 0, "usage 相同 → 命中池，零新建")
	_check(tex_d.rid == recycled, "拿到的正是前面还回池的那一块")
	gd.dispose()

	# (E) 声明期校验，三条都刻意**不 execute** —— 这些图是坏的，跑它们会往控制台抛 error。
	var ge := _builder()
	var tex_e := ge.create_texture("NoSampling",
			RDGScript.texture_2d(w, h, RenderingDevice.DATA_FORMAT_R32_SFLOAT, USAGE_STORAGE_ONLY))
	var out_e := ge.create_buffer_of_floats("Out", texels)
	ge.add_pass("SampleNoSampling", k_sample_tex, [RDGScript.sample(tex_e, samp), RDGScript.write(out_e)],
			_push(w, 1.0, 0.0, h), _g2(k_sample_tex, w, h))
	_check(_mentions(ge.get_errors(), "SAMPLING_BIT"), "采样一张没有 SAMPLING usage 位的纹理被拦下")

	var gf := _builder()
	var buf_f := gf.create_buffer_of_floats("NotATexture", texels)
	var out_f := gf.create_buffer_of_floats("Out", texels)
	gf.add_pass("SampleBuffer", k_sample_tex, [RDGScript.sample(buf_f, samp), RDGScript.write(out_f)],
			_push(w, 1.0, 0.0, h), _g2(k_sample_tex, w, h))
	_check(_mentions(gf.get_errors(), "是 buffer"), "对 buffer 用 RDG.sample 被拦下")

	var gg := _builder()
	var tex_g := gg.create_texture("Tex", RDGScript.texture_2d(w, h))
	var out_g := gg.create_buffer_of_floats("Out", texels)
	gg.add_pass("BadSampler", k_sample_tex, [RDGScript.sample(tex_g, RID()), RDGScript.write(out_g)],
			_push(w, 1.0, 0.0, h), _g2(k_sample_tex, w, h))
	_check(_mentions(gg.get_errors(), "sampler 非法"), "非法 sampler RID 被拦下")

	owner_base.release_rid(samp)


## 原子累加：`read_write` 的正当用途，以及「漏声明」的机械检查。
##
## 规则：`read_write` 只用于**原子操作**与**部分写**；非原子的就地全量累加禁止 ——
## 那种写法总能改写成 ping-pong（读 A 写 B），而 ping-pong 只需 write 声明、不存在漏声明的风险。
## 原子不行：`atomicAdd` 天生就地读改写，拆不开，所以 `read_write` 必须留着。
##
## 正因为留着，就存在「本该 read_write 却写成 write」的漏声明。Godot 不反射绑定的读写属性，
## 图自己推不出来 —— 唯一的办法是扫 shader 源码找 `atomic*`，见 ComputeKernel.uses_atomics。
func _t21_atomic_read_write() -> void:
	lines.append("── [T21] 原子累加：read_write 的正当用途 + 漏声明的机械检查 ──")
	_check(k_atomic.uses_atomics, "扫源码认出了 shader 里的原子操作")
	_check(not k_fill.uses_atomics, "没有原子操作的 shader 不会被误判")

	# 外部 uint 源缓冲：每个元素都是 3。用外部注册而不是再加一个填充 shader。
	var src_bytes := PackedByteArray()
	src_bytes.resize(N * 4)
	for i in range(N):
		src_bytes.encode_u32(i * 4, 3)
	var src_rid := owner_base.storage_buffer_from_bytes(src_bytes, BaseScript.SCOPE_PERSISTENT, "rdg_selftest_t21_src")
	_check(src_rid.is_valid(), "外部 uint 源缓冲创建成功")

	# (A) 正确声明：两次原子累加，3 + 3 = 6
	var g := _builder()
	var src := g.register_external_buffer("Src", src_rid, N * 4)
	var acc := g.create_buffer("Acc", N * 4)
	# clear 写的是 float 0.0，位模式正好是 0x00000000，当 uint 读就是 0。
	g.add_clear_pass("ClearAcc", acc, 0.0)
	g.add_pass("Atomic1", k_atomic, [RDGScript.read(src), RDGScript.read_write(acc)], _push(N, 0.0, 0.0), _g1(k_atomic, N))
	g.add_pass("Atomic2", k_atomic, [RDGScript.read(src), RDGScript.read_write(acc)], _push(N, 0.0, 0.0), _g1(k_atomic, N))
	g.extract(acc)

	_check(g.execute(), "execute 成功")
	_check_eq(g.get_warnings().size(), 0, "正确声明 read_write 时没有警告")
	var st := g.get_stats()
	_check_eq(st.get("passes_culled"), 0, "剔除 pass 数（ClearAcc 必须存活）")
	_check_eq(st.get("passes_executed"), 3, "执行 pass 数")

	var got := _read_u32(acc.rid, acc.logical_size)
	var all_six := got.size() >= N
	for i in range(mini(N, got.size())):
		if got[i] != 6:
			all_six = false
			break
	_check(all_six, "Acc = 0 + 3 + 3 = 6（首元素 %d）" % (got[0] if got.size() > 0 else -1))
	lines.append(_indent(g.dump()))
	g.dispose()

	# (B) 漏声明：把原子目标写成 write。检查必须报警，且上游 ClearAcc 确实被剔除。
	# 用 quiet_warnings 是因为这是刻意构造的坏图，警告本身仍从 get_warnings() 断言。
	var gb := _builder()
	var src_b := gb.register_external_buffer("Src", src_rid, N * 4)
	var acc_b := gb.create_buffer("Acc", N * 4)
	gb.add_clear_pass("ClearAcc", acc_b, 0.0)
	gb.add_pass("Atomic1", k_atomic, [RDGScript.read(src_b), RDGScript.write(acc_b)], _push(N, 0.0, 0.0), _g1(k_atomic, N))
	gb.add_pass("Atomic2", k_atomic, [RDGScript.read(src_b), RDGScript.write(acc_b)], _push(N, 0.0, 0.0), _g1(k_atomic, N))
	gb.extract(acc_b)

	_check(gb.execute({"quiet_warnings": true}), "漏声明的图 execute 成功")
	_check(_mentions(gb.get_warnings(), "原子操作"), "漏声明 read_write 被机械检查逮住")
	_check(int(gb.get_stats().get("passes_culled", 0)) >= 1,
			"漏声明的后果：上游 ClearAcc 被静默剔除（剔除数 %d）" % int(gb.get_stats().get("passes_culled", 0)))
	gb.dispose()
	owner_base.release_rid(src_rid)


## 随机图差分测试。此前所有用例都是**手写的特定形状** —— T12 那个双重归还的 bug 是靠推理
## 找出来的，随机化本该自动逮住它。
##
## 参考模型用仿射式 v(i) = base + stride·i：fill / scale / add 三种 pass 对它是封闭的
##   fill(b, s)  -> (b, s)
##   scale(a, k) -> (a.base·k, a.stride·k)
##   add(a, b)   -> (a.base+b.base, a.stride+b.stride)
## 且参数全取整数，量级控制在 2^24 以内 —— float32 对该范围内的整数运算是**精确**的，
## 所以可以逐元素严格比对，不用为浮点误差放宽阈值。
##
## add 的两个输入允许取到同一个资源，于是"同一 buffer 绑到两个 binding"这个 T12 的形状
## 会被随机覆盖到。
func _t18_random_graphs() -> void:
	lines.append("── [T18] 随机图差分：逐元素对 CPU 参考模型 + 全量别名不变量 ──")
	var tot_pass := 0
	var tot_culled := 0
	var tot_res := 0
	var tot_created := 0
	var tot_extracted := 0
	for s in range(FUZZ_SEEDS):
		var r := _run_random_graph(s)
		if not bool(r["ok"]):
			return
		tot_pass += int(r["declared"])
		tot_culled += int(r["culled"])
		tot_res += int(r["resources"])
		tot_created += int(r["created"])
		tot_extracted += int(r["extracted"])
	_check(tot_culled > 0, "随机图里确实出现过被剔除的 pass（共 %d 个）" % tot_culled)
	lines.append("      %d 张随机图 × %d pass：共声明 %d pass（剔除 %d）、%d 个虚拟资源、"
			% [FUZZ_SEEDS, FUZZ_NODES, tot_pass, tot_culled, tot_res])
	lines.append("      %d 个 extract 全部逐元素比对通过；期间向设备新建物理资源 %d 块。"
			% [tot_extracted, tot_created])


func _run_random_graph(seed_index: int) -> Dictionary:
	var fail := {"ok": false}
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260807 + seed_index

	var g := _builder()
	var res: Array[RDGResourceScript] = []
	var base := PackedFloat32Array()
	var stride := PackedFloat32Array()

	for n in range(FUZZ_NODES):
		var r := g.create_buffer_of_floats("n%d" % n, FUZZ_N)
		# 没有上游时只能造源头；否则三选一。
		var kind := 0 if res.is_empty() else rng.randi_range(0, 2)
		match kind:
			0:
				var b := float(rng.randi_range(-4, 4))
				var st := float(rng.randi_range(-1, 1))
				g.add_pass("fill%d" % n, k_fill, [RDGScript.write(r)],
						_push(FUZZ_N, b, st), _g1(k_fill, FUZZ_N))
				base.append(b)
				stride.append(st)
			1:
				var src := rng.randi_range(0, res.size() - 1)
				var kf := float(rng.randi_range(-1, 2))
				g.add_pass("scale%d" % n, k_scale, [RDGScript.read(res[src]), RDGScript.write(r)],
						_push(FUZZ_N, kf, 0.0), _g1(k_scale, FUZZ_N))
				base.append(base[src] * kf)
				stride.append(stride[src] * kf)
			_:
				var i1 := rng.randi_range(0, res.size() - 1)
				# 刻意加大"两个输入取到同一个资源"的比例。纯随机下这个形状太稀有 ——
				# 实测把归还去重去掉后，16 个纯随机种子一次都没撞出别名违规，只有手写的 T12 抓住了。
				# 已知有风险的形状要主动覆盖，而不是指望运气。
				var i2 := i1 if rng.randf() < 0.4 else rng.randi_range(0, res.size() - 1)
				g.add_pass("add%d" % n, k_add, [RDGScript.read(res[i1]), RDGScript.read(res[i2]), RDGScript.write(r)],
						_push(FUZZ_N, 0.0, 0.0), _g1(k_add, FUZZ_N))
				base.append(base[i1] + base[i2])
				stride.append(stride[i1] + stride[i2])
		res.append(r)

	var extracted: Array[int] = []
	for n in range(res.size()):
		if rng.randf() < 0.3:
			g.extract(res[n])
			extracted.append(n)
	if extracted.is_empty():
		g.extract(res[res.size() - 1])
		extracted.append(res.size() - 1)

	if not _check(g.execute(), "seed %d：execute 成功" % seed_index):
		return fail

	var st_g := g.get_stats()
	if not _check_no_aliasing(res, "seed %d" % seed_index):
		g.dispose()
		return fail

	for n in extracted:
		var r: RDGResourceScript = res[n]
		var b := base[n]
		var sd := stride[n]
		var expect := func(i: int) -> float: return b + sd * float(i)
		var got := _read_floats(r.rid, r.logical_size)
		if not _floats_match(got, expect, FUZZ_N):
			_check(false, "seed %d：'%s' 与参考模型不符（期望 %.1f + %.1f·i，got[0]=%.1f，got[1]=%.1f）"
					% [seed_index, r.name, b, sd, got[0] if got.size() > 0 else NAN,
					   got[1] if got.size() > 1 else NAN])
			g.dispose()
			return fail

	g.dispose()
	owner_base.gc_frame()
	return {
		"ok": true,
		"declared": int(st_g.get("passes_declared", 0)),
		"culled": int(st_g.get("passes_culled", 0)),
		"resources": res.size(),
		"created": int(st_g.get("physical_created", 0)),
		"extracted": extracted.size(),
	}


## 别名不变量：生命周期重叠的两个资源绝不能拿到同一块物理资源。
##
## **extracted 资源的生命周期要按无穷远算** —— 它们在图执行完之后依然有效（要等调用方读完
## 再 dispose 还池），所以只看 first_pass..last_pass 会漏判：T12 里 Z1 是 pass 2..2、
## Z2 是 pass 3..3，按区间根本不重叠，但两者都要活到图外，共用一块内存就是错的。
func _check_no_aliasing(res: Array, tag: String) -> bool:
	for i in range(res.size()):
		var a: RDGResourceScript = res[i]
		if not a.pooled or a.first_pass < 0 or not a.rid.is_valid():
			continue
		for j in range(i + 1, res.size()):
			var b: RDGResourceScript = res[j]
			if not b.pooled or b.first_pass < 0 or not b.rid.is_valid():
				continue
			if a.rid != b.rid:
				continue
			var a_last := _effective_last(a)
			var b_last := _effective_last(b)
			if a.first_pass <= b_last and b.first_pass <= a_last:
				_check(false, "%s：'%s'(pass %d..%s) 与 '%s'(pass %d..%s) 生命周期重叠却共用同一块物理资源"
						% [tag, a.name, a.first_pass, _span_end(a), b.name, b.first_pass, _span_end(b)])
				return false
	return true


func _effective_last(r: RDGResourceScript) -> int:
	return 0x7FFFFFFF if r.extracted else r.last_pass


func _span_end(r: RDGResourceScript) -> String:
	return "图外" if r.extracted else str(r.last_pass)


## 静默版：随机测试里失败才需要输出，逐张图报一行会把报告淹了。
func _floats_match(got: PackedFloat32Array, expected: Callable, count: int) -> bool:
	if got.size() < count:
		return false
	return float(_worst_deviation(got, expected, count)[0]) <= 1e-2


func _mentions(list: PackedStringArray, needle: String) -> bool:
	for s in list:
		if s.contains(needle):
			return true
	return false


## push constant 的 std430 布局（由既有的 [PushConstantLayout] 负责，RDG 不自带打包器）。
## 补齐规则错一格，shader 就会安静地读到偏移的垃圾值。
func _t6_push_layout() -> void:
	lines.append("── [T6] push constant 的 std430 布局（复用既有 PushConstantLayout）──")
	var l := PushConstantLayoutScript.new(PUSH_SCHEMA)
	_check_eq(l.size(), 32, "uvec4 + vec4 的总长")
	_check_eq(l.offset_of("params"), 16, "vec4 成员的偏移")

	# 注意与 lab 原型的差别：本工程的 PushConstantLayout 把块总长**无条件**补到 16 的倍数
	# （Godot RenderingDevice 的 push constant 要求），而不是补到"最大成员对齐"。
	var mixed := PushConstantLayoutScript.new([["a", "uint"], ["b", "float"], ["c", "float"]])
	_check_eq(mixed.size(), 16, "三个标量共 12 字节，块总长补到 16 的倍数")

	var vec3_case := PushConstantLayoutScript.new([["a", "float"], ["v", "vec3"]])
	_check_eq(vec3_case.offset_of("v"), 16, "vec3 成员按 16 对齐")
	_check_eq(vec3_case.size(), 32, "含 vec3 时总长补到 32")

	var bytes := l.pack({"counts": Vector4i(5, 0, 0, 0), "params": Vector4(1.5, 0, 0, 0)})
	_check_eq(bytes.size(), 32, "打包字节数")
	_check_eq(bytes.decode_u32(0), 5, "counts.x 落在偏移 0")
	_check(absf(bytes.decode_float(16) - 1.5) < 1e-6, "params.x 落在偏移 16")


# ——————————————————————————————————————————————————————————————
#  helper
# ——————————————————————————————————————————————————————————————

func _builder() -> RDGBuilderScript:
	return RDGBuilderScript.new(owner_base, pool)


## counts.y / counts.z 的含义按 shader 而定：rdg_write_indirect_args 用 y 作下游 pass 的
## local_size_x，rdg_fill_texture / rdg_texture_to_buffer 用 y 作纹理高度，rdg_fill_texture_3d
## 用 y/z 作高度与深度；其余 shader 不读它们。
func _push(count: int, p0: float, p1: float, count_y := 0, count_z := 0) -> Dictionary:
	return {"counts": Vector4i(count, count_y, count_z, 0), "params": Vector4(p0, p1, 0.0, 0.0)}


## [ComputeKernel] 不记 local_size，组数由调用方按 shader 的 layout 声明传。
func _g1(k: ComputeKernelScript, count: int) -> Vector3i:
	return k.groups_1d(count, LOCAL_X)


func _g2(k: ComputeKernelScript, w: int, h: int) -> Vector3i:
	return k.groups_2d(w, h, LOCAL_2D, LOCAL_2D)


func _g3(k: ComputeKernelScript, w: int, h: int, d: int) -> Vector3i:
	return k.groups_3d(w, h, d, LOCAL_3D, LOCAL_3D, LOCAL_3D)


## 按逻辑尺寸回读。必须传 size_bytes：池化的物理 buffer 通常比逻辑数据大（按 2 的幂分桶），
## 整块回读会把桶尾的垃圾一起读出来。
func _read_floats(rid: RID, size_bytes: int) -> PackedFloat32Array:
	return owner_base.read_buffer_bytes(rid, 0, size_bytes).to_float32_array()


## 同上，读成 32 位整数（原子计数器一类的 uint 缓冲用）。
func _read_u32(rid: RID, size_bytes: int) -> PackedInt32Array:
	return owner_base.read_buffer_bytes(rid, 0, size_bytes).to_int32_array()


## 回读一层纹理。texture_get_data 按纹理自身尺寸返回整层，不需要传长度。
func _read_texture_floats(rid: RID, layer := 0) -> PackedFloat32Array:
	var rd := owner_base.get_rendering_device()
	if rd == null or not rid.is_valid():
		return PackedFloat32Array()
	return rd.texture_get_data(rid, layer).to_float32_array()


## [T22] prefilter 转换的**声明等价性**。
##
## `AutoObjectProbePrefilterGPU` 的 3 处调度可走两条路径（`use_rdg_dispatch` 切换）。旧路径的
## 绑定契约是**位置数组**：`ComputeKernel.make_pass(buffers, ...)` 把 `buffers[i]` 绑到 binding i。
## 所以「RDG 路径声明的 binding i 就是 `buffers[i]`」这一条，等价于「两条路径绑了同一批东西」。
##
## ⚠ 证明力边界（别把它当行为等价）：
##   守得住 —— 绑定错位、access 声明与既定表不符、groups 传错、score→top-K 的 RAW 依赖没建起来。
##   守不住 —— 语义声明本身对不对（`anchor_out` 到底该 `write` 还是 `read_write`，
##             那要读 shader 正文判断，只能靠人复核 + `uses_atomics` 那条机械检查兜一部分）。
##
## 刻意**不做**逐字节的输出 A/B：`collect_sv_anchors` 用 `atomicAdd` 分配输出下标，
## 同输入重跑槽位顺序就会变，那种比对天然 flaky。
func _t22_prefilter_declaration_equivalence() -> void:
	lines.append("── [T22] prefilter 转换：声明等价性（不执行图，只核对声明）──")
	var pf := AutoObjectProbePrefilterGPU.new()
	if not pf.ensure_device(true, true):
		_check(false, "prefilter 取不到 RenderingDevice")
		return
	pf._load_shaders()
	if not _check(pf._kernel_collect != null and pf._kernel_collect.is_valid(), "prefilter 的 kernel 编译成功"):
		pf.dispose()
		return

	# 造一批互不相同的 buffer，只用来做身份比对，不会真的派发。
	var bufs: Array[RID] = []
	for i in range(12):
		bufs.append(pf.storage_buffer_zero(256, "frame", "t22_%d" % i))
	var pool = pf._ensure_rdg_pool()
	if not _check(pool != null, "RDG 池可用"):
		pf.dispose()
		return

	var R := RDG.Access.READ
	var W := RDG.Access.WRITE
	var RW := RDG.Access.READ_WRITE

	# ── collect：6 个绑定，b3/b4 是散射部分写与 atomicAdd 目标 ──
	var g1 := RDGBuilder.new(pf, pool)
	var collect_bufs: Array = [bufs[0], bufs[1], bufs[2], bufs[3], bufs[4], bufs[5]]
	pf._rdg_build_collect(g1, collect_bufs, {}, Vector3i(7, 1, 1))
	_check_binding_table(g1, 0, collect_bufs, [R, R, R, RW, RW, R], "collect")
	_check_eq(g1._passes[0].groups, Vector3i(7, 1, 1), "collect 的 groups 原样传下去")
	g1.dispose()

	# ── finalize：3 个绑定，全部有限定符 ──
	var g2 := RDGBuilder.new(pf, pool)
	var fin_bufs: Array = [bufs[0], bufs[6], bufs[7]]
	pf._rdg_build_finalize(g2, fin_bufs, {})
	_check_binding_table(g2, 0, fin_bufs, [R, W, W], "finalize")
	g2.dispose()

	# ── score → top-K：两个 indirect pass 同图 ──
	var g3 := RDGBuilder.new(pf, pool)
	var score_bufs: Array = [bufs[0], bufs[1], bufs[2], bufs[3], bufs[4], bufs[5], bufs[6], bufs[8], bufs[9]]
	var topk_bufs: Array = [bufs[8], bufs[10], bufs[9]]
	pf._rdg_build_score_topk(g3, score_bufs, {}, bufs[6], topk_bufs, {}, bufs[7])
	_check_eq(g3._passes.size(), 2, "score→top-K 是同一张图里的两个 pass")
	_check_binding_table(g3, 0, score_bufs, [R, R, R, R, R, R, R, W, R], "score")
	_check_binding_table(g3, 1, topk_bufs, [R, W, R], "top-K")
	_check(g3._passes[0].indirect_res != null and g3._passes[0].indirect_res.rid == bufs[6], "score 的 indirect args 绑对")
	_check(g3._passes[1].indirect_res != null and g3._passes[1].indirect_res.rid == bufs[7], "top-K 的 indirect args 绑对")
	# 这条是 top-K 前面那一刀的**唯一**依据：score 写的 asset_scores 与 top-K 读的必须是
	# 同一个 RDGResource 实例，否则图看不出 RAW 边、不会切段 —— 而 GPU 不会为此报错。
	_check(g3._passes[0].param_sets[0][7]["res"] == g3._passes[1].param_sets[0][0]["res"],
			"asset_scores 在两个 pass 里是同一个资源实例（RAW 边成立）")
	g3.dispose()

	for rid in bufs:
		pf.release_rid(rid)
	pf.dispose()


## 核对某个 pass 的 set 0：binding i 绑的必须是 expect_rids[i]，access 必须是 expect_access[i]。
func _check_binding_table(g, pass_index: int, expect_rids: Array, expect_access: Array, tag: String) -> void:
	if pass_index >= g._passes.size():
		_check(false, "%s：pass %d 不存在" % [tag, pass_index])
		return
	var p = g._passes[pass_index]
	if not _check(p.param_sets.size() == 1, "%s：单 uniform set" % tag):
		return
	var group: Array = p.param_sets[0]
	if not _check(group.size() == expect_rids.size(), "%s：绑定数 %d（期望 %d）" % [tag, group.size(), expect_rids.size()]):
		return
	var bad_bind := -1
	var bad_acc := -1
	for i in range(group.size()):
		if group[i]["res"].rid != expect_rids[i]:
			bad_bind = i
			break
		if int(group[i]["access"]) != int(expect_access[i]):
			bad_acc = i
			break
	_check(bad_bind < 0, "%s：binding i 绑的就是 buffers[i]（旧路径的位置契约）%s" % [
			tag, "" if bad_bind < 0 else "—— binding %d 错位" % bad_bind])
	_check(bad_acc < 0, "%s：access 与既定语义表一致%s" % [
			tag, "" if bad_acc < 0 else "—— binding %d 的 access 不符" % bad_acc])


## 返回 cond，方便随机测试里 `if not _check(...): return` 这种早退写法。
func _check(cond: bool, what: String) -> bool:
	if cond:
		passed += 1
		lines.append("    ✓ %s" % what)
	else:
		failed += 1
		lines.append("    ✗ %s" % what)
	return cond


func _check_eq(actual, expected, what: String) -> void:
	_check(actual == expected, "%s：期望 %s，实际 %s" % [what, str(expected), str(actual)])


## 逐元素比对的唯一实现，返回 [最大偏差, 最大偏差下标]；下标为 -1 表示完全一致。
func _worst_deviation(got: PackedFloat32Array, expected: Callable, count: int) -> Array:
	var worst := 0.0
	var worst_i := -1
	for i in range(count):
		var diff := absf(got[i] - float(expected.call(i)))
		if diff > worst:
			worst = diff
			worst_i = i
	return [worst, worst_i]


func _check_floats(got: PackedFloat32Array, expected: Callable, what: String, count := N) -> void:
	if got.size() < count:
		_check(false, "%s（回读长度 %d < %d）" % [what, got.size(), count])
		return
	var d := _worst_deviation(got, expected, count)
	var where := "完全一致" if int(d[1]) < 0 else "最大偏差 %.6f @ i=%d" % [d[0], d[1]]
	_check(float(d[0]) <= 1e-3, "%s（%s，got[0]=%.3f）" % [what, where, got[0]])


func _indent(block: String) -> String:
	var out: PackedStringArray = []
	for line in block.split("\n"):
		out.append("      %s" % line)
	return "\n".join(out)
