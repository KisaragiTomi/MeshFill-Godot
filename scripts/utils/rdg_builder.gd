@tool
class_name RDGBuilder
extends RefCounted

## UE FRDGBuilder 的移植：声明一堆虚拟资源和 pass，[method execute] 负责编译（建依赖 → 剔除 →
## 算生命周期 → 规划切段 → 池化分配 → 建 uniform set）并录制执行。
##
## owner 须为 [GodotComputeShaderBase]（或子类）实例：设备、shader/pipeline 缓存、uniform set
## 的建立与 GC、RID 跟踪全部复用它。本类完全通过 owner 的公开方法组合，既不修改也不继承
## base class（与 [ComputeKernel] / [ComputePassChain] 同规）。owner 以 weakref 持有。
##
## 典型用法（每帧新建一个 builder，共用同一个跨帧的 [RDGPool]）。
## push 值的键必须与 kernel 的 push schema 一致：
##
##     var g := RDGBuilder.new(self, pool)
##     var a := g.create_buffer_of_floats("A", n)
##     var c := g.create_buffer_of_floats("C", n)
##     var push := {counts = Vector4i(n, 0, 0, 0), params = Vector4(0.0, 1.0, 0, 0)}
##     g.add_pass("FillA", k_fill, [RDG.write(a)], push, k_fill.groups_1d(n, 64))
##     g.add_pass("Scale", k_scale, [RDG.read(a), RDG.write(c)], push, k_scale.groups_1d(n, 64))
##     g.extract(c)
##     g.execute()
##     var out := read_buffer_bytes(c.rid, 0, c.logical_size).to_float32_array()
##     g.dispose()   # extracted 资源在此还池，务必先读走数据
##
## **必须理解的一条语义**：[method RDG.write] 表示"我整块覆盖"，会取代此前所有写者
## （它们若无别的下游即被剔除）。只写一部分、或累加/原子写，必须用 [method RDG.read_write]，
## 否则上游填充 pass 被静默剔除，累加落在池里的残留上。
##
## uniform set 的生命周期归 owner：本类按 [constant GodotComputeShaderBase.SCOPE_PASS] 登记，
## 随宿主的 gc_frame() 回收（与 [ComputeKernel] 的 make_pass 一致），[method dispose] 不再自己收。

# 内部交叉引用走 preload 常量（理由见 [RDGResource] 顶部注释）。
const RDGScript := preload("res://scripts/utils/rdg.gd")
const RDGResourceScript := preload("res://scripts/utils/rdg_resource.gd")
const RDGPassScript := preload("res://scripts/utils/rdg_pass.gd")
const RDGPoolScript := preload("res://scripts/utils/rdg_pool.gd")
const ComputeKernelScript := preload("res://scripts/utils/compute_kernel.gd")
const BaseScript := preload("res://scripts/godot_compute_shader_base.gd")

const CLEAR_SHADER := "res://shaders/rdg_clear_buffer.glsl"
const CLEAR_PUSH_SCHEMA := [["counts", "uvec4"], ["params", "vec4"]]
const CLEAR_LOCAL_SIZE_X := 64

var _owner_ref: WeakRef = null
var _pool: RDGPoolScript = null

var _resources: Array[RDGResourceScript] = []
var _passes: Array[RDGPassScript] = []
var _live_order: Array[RDGPassScript] = []   ## 存活 pass，按 exec_order

var _errors: PackedStringArray = []
var _warnings: PackedStringArray = []
var _stats := {}
var _executed := false
var _disposed := false


func _init(owner_base: BaseScript, pool: RDGPoolScript) -> void:
	if owner_base == null:
		_errors.append("RDGBuilder: owner 为空")
	else:
		_owner_ref = weakref(owner_base)
	_pool = pool
	if pool == null:
		_errors.append("RDGBuilder: pool 为空 —— 瞬态资源无处分配")


## 解析 owner（weakref）。owner 已释放时返回 null。
func owner() -> BaseScript:
	return _owner_ref.get_ref() as BaseScript if _owner_ref != null else null


# ——————————————————————————————————————————————————————————————
#  声明期 API
# ——————————————————————————————————————————————————————————————

## 图内瞬态缓冲。返回的句柄此刻还没有任何 GPU 资源。
## usage 为 RenderingDevice.StorageBufferUsage 位，会进池的分桶 key（usage 不同不能互换复用）。
func create_buffer(name: String, size_bytes: int, usage := 0) -> RDGResourceScript:
	var r := _new_resource(name, RDGScript.Kind.BUFFER, RDGScript.Origin.TRANSIENT)
	r.desc = RDGScript.buffer(size_bytes, usage)
	r.logical_size = size_bytes
	return r


func create_buffer_of_floats(name: String, count: int) -> RDGResourceScript:
	return create_buffer(name, count * 4)


## dispatch_indirect 的参数缓冲（3 个 uint32 = groups x/y/z）。
## 必须走这个入口而不是 create_buffer：少了 DISPATCH_INDIRECT usage 位，建出来的 buffer
## 没有 BUFFER_USAGE_INDIRECT_BIT，喂给 compute_list_dispatch_indirect 会直接失败。
func create_indirect_args_buffer(name: String) -> RDGResourceScript:
	var r := _new_resource(name, RDGScript.Kind.BUFFER, RDGScript.Origin.TRANSIENT)
	r.desc = RDGScript.indirect_args_buffer()
	r.logical_size = r.desc.size_bytes
	return r


func create_texture(name: String, desc: RDGScript.TextureDesc) -> RDGResourceScript:
	var r := _new_resource(name, RDGScript.Kind.TEXTURE, RDGScript.Origin.TRANSIENT)
	r.desc = desc
	return r


## 注册一个图外既有的缓冲（UE: RegisterExternalBuffer）。写它是可观测副作用，
## 因此它的生产者永远不会被剔除；它也永远不进池。
func register_external_buffer(name: String, rid: RID, size_bytes: int) -> RDGResourceScript:
	var r := _new_resource(name, RDGScript.Kind.BUFFER, RDGScript.Origin.EXTERNAL)
	r.rid = rid
	r.logical_size = size_bytes
	r.desc = RDGScript.buffer(size_bytes)
	if not rid.is_valid():
		_errors.append("register_external_buffer('%s'): RID 非法" % name)
	return r


func register_external_texture(name: String, rid: RID, desc: RDGScript.TextureDesc) -> RDGResourceScript:
	var r := _new_resource(name, RDGScript.Kind.TEXTURE, RDGScript.Origin.EXTERNAL)
	r.rid = rid
	r.desc = desc
	if not rid.is_valid():
		_errors.append("register_external_texture('%s'): RID 非法" % name)
	return r


## 把资源标记为图的输出（UE: QueueBufferExtraction）。它的物理 RID 在 execute() 之后依然有效，
## 直到 dispose() 才还池；它的生产者不会被剔除。
func extract(res: RDGResourceScript) -> RDGResourceScript:
	if res == null:
		_errors.append("extract(): 传入 null")
		return res
	res.extracted = true
	return res


## 加一个 compute pass。
##
## params 两种写法：
##   单 set —— 扁平数组，位置即 set 0 的 binding：[RDG.read(a), RDG.write(b)]
##   多 set —— 嵌套数组，params[s][i] 绑到 set s 的 binding i：[[RDG.read(a)], [RDG.write(b)]]
## opts 支持 {"never_cull": bool}。
func add_pass(name: String, kernel: ComputeKernelScript, params: Array, push_values: Dictionary,
		groups: Vector3i, opts := {}) -> RDGPassScript:
	var p := _new_pass(name, kernel, params, push_values, opts)
	p.groups = groups
	return p


## 往缓冲里写一个常量（UE: AddClearUAVPass）。
##
## **瞬态资源在被 read_write 之前基本都需要先 clear。** 池发回来的物理内存带着上一张图的残留，
## 累加/原子语义直接落上去就是在垃圾上累加 —— GPU 不报错，只出错数。图内 clear 是一个正常 pass，
## 因此照样参与剔除、依赖与切段（后续若有全量 WRITE 取代它，它会被正确地剔掉）。
func add_clear_pass(name: String, res: RDGResourceScript, value := 0.0) -> RDGPassScript:
	if res == null:
		_errors.append("add_clear_pass('%s'): 资源为 null" % name)
		return null
	if res.kind != RDGScript.Kind.BUFFER:
		_errors.append("add_clear_pass('%s'): 目前只支持 buffer，资源 '%s' 是纹理" % [name, res.name])
		return null
	var k := _builtin_clear_kernel()
	if k == null:
		_errors.append("add_clear_pass('%s'): 内建 clear kernel 不可用" % name)
		return null
	var count := int(res.logical_size / 4)
	return add_pass(name, k, [RDGScript.write(res)],
			{"counts": Vector4i(count, 0, 0, 0), "params": Vector4(value, 0.0, 0.0, 0.0)},
			k.groups_1d(count, CLEAR_LOCAL_SIZE_X))


## 内建清零 kernel，懒建后挂在池上（与 owner 同寿，跨图复用，只编译一次）。
func _builtin_clear_kernel() -> ComputeKernelScript:
	if _pool == null:
		return null
	var cached = _pool.builtins.get("clear")
	if cached != null and (cached as ComputeKernelScript).is_valid():
		return cached
	var o := owner()
	if o == null:
		return null
	var k := ComputeKernelScript.create(o, CLEAR_SHADER, CLEAR_PUSH_SCHEMA, "rdg_builtin_clear",
			BaseScript.SCOPE_PERSISTENT)
	_pool.builtins["clear"] = k
	return k


## indirect 变体：工作组数由 indirect_res 里的 GPU 数据决定。
## indirect_res 会作为一条 INDIRECT 访问参与建边 —— "写 indirect args 的 pass 必须先执行、
## 且中间必须切段"这条依赖由图自动保证，不用手接。
func add_pass_indirect(name: String, kernel: ComputeKernelScript, params: Array, push_values: Dictionary,
		indirect_res: RDGResourceScript, indirect_offset := 0, opts := {}) -> RDGPassScript:
	var p := _new_pass(name, kernel, params, push_values, opts)
	p.indirect_res = indirect_res
	p.indirect_offset = indirect_offset
	return p


func _new_resource(name: String, kind: int, origin: int) -> RDGResourceScript:
	var r := RDGResourceScript.new()
	r.index = _resources.size()
	r.name = name
	r.kind = kind
	r.origin = origin
	_resources.append(r)
	return r


func _new_pass(name: String, kernel: ComputeKernelScript, params: Array, push_values: Dictionary, opts: Dictionary) -> RDGPassScript:
	var p := RDGPassScript.new()
	p.index = _passes.size()
	p.name = name
	p.kernel = kernel
	p.param_sets = _normalize_param_sets(name, params)
	p.push_values = push_values
	p.never_cull = bool(opts.get("never_cull", false))
	_passes.append(p)
	if kernel == null or not kernel.is_valid():
		_errors.append("add_pass('%s'): kernel 无效" % name)
	elif kernel.uses_atomics and not _has_read_write(p):
		# 原子是就地读改写：声明成 write 的话图会认定它整块覆盖，把上游初始化 pass 剔掉，
		# 于是原子累加落在没初始化的池内存上 —— GPU 不报错，只出错数。
		# 这是本层唯一能主动发现「漏声明 read_write」的手段（Godot 不反射绑定的读写属性）。
		_warnings.append("pass '%s' 的 shader（%s）里有原子操作，却没有任何参数声明成 read_write —— 漏声明会让上游的初始化 pass 被静默剔除" % [name, kernel.label])
	for si in range(p.param_sets.size()):
		var group: Array = p.param_sets[si]
		for i in range(group.size()):
			var a = group[i]
			if typeof(a) != TYPE_DICTIONARY or not a.has("res") or not a.has("access"):
				_errors.append("add_pass('%s'): set %d 的参数 %d 不是 RDG.read/write/read_write 的产物" % [name, si, i])
			elif a["res"] == null:
				_errors.append("add_pass('%s'): set %d 的参数 %d 的资源为 null" % [name, si, i])
			elif a.has("sampler"):
				_validate_sample(name, si, i, a)
	return p


## RDG.sample 的声明期校验。这三条全属于「不拦就在别处静默出错或事后才炸」：
## 采样一个 buffer 是笔误；非法 sampler 要到 uniform_set_create 才报一句没有上下文的失败；
## 而**纹理少了 SAMPLING usage 位**最隐蔽 —— 池按 desc 建纹理，desc 说了不能采样，
## 建出来的就真不能采样，错误发生在分配之后、离写错的那一行已经很远了。
func _validate_sample(pass_name: String, si: int, i: int, access: Dictionary) -> void:
	var res: RDGResourceScript = access["res"]
	var sampler = access["sampler"]
	if res.kind != RDGScript.Kind.TEXTURE:
		_errors.append("add_pass('%s'): set %d 的参数 %d 用 RDG.sample 声明，但资源 '%s' 是 buffer —— 采样绑定只对纹理成立" % [pass_name, si, i, res.name])
	elif typeof(sampler) != TYPE_RID or not (sampler as RID).is_valid():
		_errors.append("add_pass('%s'): set %d 的参数 %d 的 sampler 非法 —— 用 owner 的 create_linear_sampler() 或 RenderingDevice.sampler_create() 建一个" % [pass_name, si, i])
	elif res.desc != null and (int(res.desc.usage) & RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT) == 0:
		_errors.append("add_pass('%s'): 纹理 '%s' 的 usage 不含 TEXTURE_USAGE_SAMPLING_BIT，绑不上采样器（建它的时候就要给这个位，绑定阶段补不了）" % [pass_name, res.name])


static func _has_read_write(p: RDGPassScript) -> bool:
	for group in p.param_sets:
		for a in group:
			if typeof(a) == TYPE_DICTIONARY and int(a.get("access", -1)) == RDGScript.Access.READ_WRITE:
				return true
	return false


## 把 params 归一化成 [[set0 的参数...], [set1 的参数...], ...]。
## 扁平数组（全是 Dictionary）视为单 set 0；嵌套数组（全是 Array）按位置对应 set index。
## 两种混着传是笔误，直接报错而不是猜 —— 猜错的话绑定会整体错位一个 set，
## uniform_set_create 未必失败，但 shader 读到的全是别的资源。
func _normalize_param_sets(pass_name: String, params: Array) -> Array:
	if params.is_empty():
		return []
	var arrays := 0
	var others := 0
	for e in params:
		if typeof(e) == TYPE_ARRAY:
			arrays += 1
		else:
			others += 1
	if arrays > 0 and others > 0:
		_errors.append("add_pass('%s'): params 混用了扁平项与嵌套数组；单 set 传 [a, b]，多 set 传 [[a, b], [c]]" % pass_name)
		return []
	if arrays > 0:
		var out: Array = []
		for e in params:
			out.append((e as Array).duplicate())
		return out
	return [params.duplicate()]


# ——————————————————————————————————————————————————————————————
#  编译 + 执行
# ——————————————————————————————————————————————————————————————

## opts:
##   "force_all_barriers": bool —— 关掉依赖推导，每个 pass 前都切一刀。
##       这就是 [ComputePassChain] 的现有行为，留作 A/B 对照基准用，正常路径别开。
##   "quiet_warnings": bool —— 不把图的警告 push 到控制台（仍可从 get_warnings() 取）。
##       只给「刻意构造坏图」的用例用，正常路径别开：那些警告（比如读了从没被写过的资源）
##       正是这层唯一能主动告诉你出事的地方。
##   "sync": bool（默认 true）—— 录制完是否 submit_and_sync。要回读结果就必须同步。
##   "sync_include_global": bool（默认 false）—— 透传给 owner.submit_and_sync；owner 借用
##       （非自有）设备时须传 true，否则 submit_and_sync 在借用设备上是 no-op。
func execute(opts := {}) -> bool:
	if _executed:
		push_error("RDGBuilder.execute: 同一个 builder 只能执行一次；每帧新建一个（池是跨帧复用的那个）")
		return false
	var o := owner()
	if o == null or o.get_rendering_device() == null:
		push_error("RDGBuilder.execute: owner 已释放或无 RenderingDevice")
		return false
	_executed = true

	for r in _resources:
		r.reset_compile_state()
	for p in _passes:
		p.reset_compile_state()

	_build_dependencies()
	_cull()
	_assign_exec_order_and_lifetimes()
	_plan_barriers(bool(opts.get("force_all_barriers", false)))

	if not bool(opts.get("quiet_warnings", false)):
		for w in _warnings:
			push_warning("RDG: %s" % w)

	if not _errors.is_empty():
		for e in _errors:
			push_error("RDG: %s" % e)
		return false

	if not _allocate_and_bind(o):
		return false
	_record_and_submit(o, bool(opts.get("sync", true)), bool(opts.get("sync_include_global", false)))
	_pool.flush()
	_finalize_stats()
	return true


## 建依赖边。逐 pass、按声明序推进，每个资源维护"当前未被取代的写者集"与"上次全量写之后的读者集"。
func _build_dependencies() -> void:
	var writers := {}    ## res_index -> Array[int]
	var readers := {}    ## res_index -> Array[int]

	for p in _passes:
		for a in p.all_accesses():
			var r: RDGResourceScript = a["res"]
			if r == null:
				continue
			var acc: int = a["access"]
			var w: Array = writers.get(r.index, [])
			var rd_: Array = readers.get(r.index, [])

			if RDGScript.is_read(acc):
				if not r.initialized:
					_warnings.append("pass '%s' 读了从未被写过的资源 '%s' —— 读到的是池里的残留数据" % [p.name, r.name])
				# RAW：依赖当前全部未被取代的写者。这是唯一会让被依赖 pass 存活的边。
				for wi in w:
					p.add_dep(wi, true)
				r.consumers.append(p.index)

			if RDGScript.is_write(acc):
				for wi in w:
					p.add_dep(wi, false)     # WAW
				for ri in rd_:
					p.add_dep(ri, false)     # WAR
				r.producers.append(p.index)
				r.initialized = true
				if acc == RDGScript.Access.WRITE:
					# 全量覆盖：取代此前所有写者（它们若无别的下游即可剔除），读者集清空。
					writers[r.index] = [p.index]
					readers[r.index] = []
				else:
					# READ_WRITE（累加/原子/部分写）：追加而不取代，前面的写者依然被需要。
					w.append(p.index)
					writers[r.index] = w
			elif RDGScript.is_read(acc):
				rd_.append(p.index)
				readers[r.index] = rd_

	# 落定"最终未被取代的写者"，供剔除取根。
	for r in _resources:
		for wi in writers.get(r.index, []):
			r.final_writers.append(wi)
		# extract 了却没人写它 —— 它不会成为任何剔除根，也就永远拿不到物理资源，
		# 调用方拿到的是个无效 RID，回读得到空数组。安静地返回空最难查，这里必须出声。
		if r.extracted and not r.is_external() and r.final_writers.is_empty():
			_warnings.append("extract 了资源 '%s'，但图里没有任何 pass 写它 —— 它拿不到物理资源，rid 无效" % r.name)


## 剔除：从"输出根"沿 RAW 边反向传播，传不到的 pass 全部剔除（UE: pass culling）。
func _cull() -> void:
	var live := {}
	var stack: Array[int] = []

	for p in _passes:
		if p.never_cull:
			stack.append(p.index)
	for r in _resources:
		if r.is_output_root():
			for prod in r.final_writers:
				stack.append(prod)

	while not stack.is_empty():
		var i: int = stack.pop_back()
		if live.has(i):
			continue
		live[i] = true
		for d in _passes[i].raw_deps:
			if not live.has(d):
				stack.append(d)

	for p in _passes:
		p.culled = not live.has(p.index)


func _assign_exec_order_and_lifetimes() -> void:
	_live_order = []
	for p in _passes:
		if p.culled:
			continue
		p.exec_order = _live_order.size()
		_live_order.append(p)

	for p in _live_order:
		for a in p.all_accesses():
			var r: RDGResourceScript = a["res"]
			if r == null:
				continue
			if r.first_pass < 0:
				r.first_pass = p.exec_order
			r.last_pass = p.exec_order


## 规划切段。在 pass P 之前切一刀，当且仅当 P 依赖了**本段内已经派发过**的某个存活 pass。
## 相互独立的 pass 因此会被合进同一段，一次切都不用。
func _plan_barriers(force_all := false) -> void:
	var group_start := 0
	for p in _live_order:
		if p.exec_order == 0:
			continue
		if force_all:
			p.needs_barrier = true
			group_start = p.exec_order
			continue
		var hazard := false
		for d in p.deps:
			var dp: RDGPassScript = _passes[d]
			if dp.culled:
				continue    # 不执行的 pass 构不成冲突
			if dp.exec_order >= group_start:
				hazard = true
				break
		if hazard:
			p.needs_barrier = true
			group_start = p.exec_order


## 分配物理资源 + 建 uniform set。**必须在打开 compute list 之前完成**：uniform set 依赖
## 物理 RID，而物理 RID 来自池，池的复用又受切段位置约束 —— 三者只能按这个顺序落定。
func _allocate_and_bind(o: BaseScript) -> bool:
	var live_physical := 0
	var peak_physical := 0
	var pool_before := _pool.stats()

	for p in _live_order:
		# 切段点：此前归还的物理资源到这里才真正可复用（别名安全）。
		if p.needs_barrier:
			_pool.commit_barrier()

		for a in p.all_accesses():
			var r: RDGResourceScript = a["res"]
			if r == null or r.rid.is_valid():
				continue
			r.rid = _pool.acquire(r.desc)
			r.pooled = true
			live_physical += 1
			peak_physical = maxi(peak_physical, live_physical)
			if not r.rid.is_valid():
				push_error("RDG: 资源 '%s' 分配失败（%s）" % [r.name, r.describe()])
				return false

		var sets: Array[RID] = []
		for si in range(p.param_sets.size()):
			var group: Array = p.param_sets[si]
			var uniforms: Array = []
			for i in range(group.size()):
				uniforms.append(_make_uniform(o, i, group[i]))
			# uniform set 按 SCOPE_PASS 登记进 owner 的跟踪器，随宿主 gc_frame() 回收。
			var set_rid := o.create_uniform_set(uniforms, p.kernel.shader, si,
					BaseScript.SCOPE_PASS, "rdg:%s:set%d" % [p.name, si])
			if not set_rid.is_valid():
				push_error("RDG: pass '%s' 的 set %d 创建失败（%d 个绑定，检查 shader 里该 set 的 binding 序号是否 0..N-1 连续）" % [p.name, si, uniforms.size()])
				return false
			sets.append(set_rid)
		p.uniform_sets = sets

		# 生命周期到此为止的瞬态资源立刻还池（下一次切段后可被复用）。
		# r.released 去重不可省：同一资源在一个 pass 里可能被访问多次（同一 buffer 绑到两个
		# binding、跨两个 set、或既当参数又当 indirect args），重复归还会让同一个 RID 在空闲表里
		# 出现两次，后续两个资源拿到同一块内存互相踩踏。
		for a in p.all_accesses():
			var r: RDGResourceScript = a["res"]
			if r == null or not r.pooled or r.released:
				continue
			if r.last_pass == p.exec_order and r.is_poolable():
				r.released = true
				_pool.release(r.rid)
				live_physical -= 1

	var pool_after := _pool.stats()
	_stats["physical_acquired"] = int(pool_after["acquired"]) - int(pool_before["acquired"])
	_stats["physical_reused"] = int(pool_after["reused"]) - int(pool_before["reused"])
	_stats["physical_created"] = int(pool_after["created"]) - int(pool_before["created"])
	_stats["peak_live_physical"] = peak_physical
	return true


## 访问声明 -> RDUniform。uniform 类型由「资源是什么 + 怎么读它」共同决定，所以这里收的是
## 整条访问声明而不只是资源：同一张纹理既可以当 storage image 绑（imageLoad/imageStore），
## 也可以配一个采样器当 sampler2D 绑（texture()），区别只在访问声明带没带 sampler。
func _make_uniform(o: BaseScript, binding: int, access: Dictionary) -> RDUniform:
	var res: RDGResourceScript = access["res"]
	if access.has("sampler"):
		# 顺序由 base class 的 make_sampler_uniform 保证（先 sampler 后 texture）：
		# 这类 uniform 的 ids 是成对的，Godot 按位置取、不按类型认。
		return o.make_sampler_uniform(binding, access["sampler"], res.rid)
	if res.kind == RDGScript.Kind.TEXTURE:
		return o.make_image_uniform(binding, res.rid)
	return o.make_storage_uniform(binding, res.rid)


## 录制与提交分开计时。切段的开销分两部分：录制阶段的 CPU 重绑（compute_list_add_barrier
## 内部是 end+begin+重绑 pipeline/全部 set/push），和 submit 之后等 GPU 的时间。
## 后者被提交与栅栏等待的固定开销、以及 OS 调度噪声整个淹没 —— 混在一起测，切段成本会掉进
## 噪声里（实测能测出负的边际成本，那显然不是真实效应）。分开记，才测得到东西。
func _record_and_submit(o: BaseScript, sync: bool, sync_include_global: bool) -> void:
	_stats["barriers"] = 0
	_stats["empty_dispatches"] = 0
	_stats["record_usec"] = 0.0
	_stats["submit_sync_usec"] = 0.0
	# 全被剔除（或本来就没 pass）：没有任何要录制的东西，别白付一趟 submit+sync ——
	# 实测那一趟本身就是上百 µs，而这里一条 dispatch 都没有。
	if _live_order.is_empty():
		return

	var rd := o.get_rendering_device()
	var t_record_begin := Time.get_ticks_usec()
	var cl := o.begin_compute_list()
	if cl < 0:
		push_error("RDGBuilder: begin_compute_list 失败")
		return
	var barriers := 0
	var empty_dispatches := 0

	for p in _live_order:
		if p.needs_barrier:
			rd.compute_list_add_barrier(cl)
			barriers += 1

		# groups 任一维为 0 = 这一帧没有工作。Godot 在 DEBUG 下对 0 组 dispatch 会报错并跳过
		# （rendering_device.cpp: ERR_FAIL_COND_MSG(p_x_groups == 0, "... is zero.")），而
		# "本帧候选数为 0"在真实管线里很常见 —— 不拦的话就是每帧刷一条错误日志。
		# 不派发与派发 0 组语义完全等价，所以直接跳过。
		#
		# **但 barrier 必须照发**（注意上面的 needs_barrier 在此判断之前）：切段位置是编译期
		# 按依赖算好的，这里若跟着省掉，后面的 pass 会掉回本该被切开的段里。
		# 例：A 写 X；P 读 X（0 组）；Q 读 X。切点只规划在 P 前面，Q 靠它与 A 隔开；
		# 连 P 的切点一起省掉，A 与 Q 就落进同一段 —— 静默数据竞争。
		if p.indirect_res == null and (p.groups.x <= 0 or p.groups.y <= 0 or p.groups.z <= 0):
			empty_dispatches += 1
			continue

		rd.compute_list_bind_compute_pipeline(cl, p.kernel.pipeline)
		for si in range(p.uniform_sets.size()):
			rd.compute_list_bind_uniform_set(cl, p.uniform_sets[si], si)
		var push := p.kernel.pack(p.push_values)
		if push.size() > 0:
			rd.compute_list_set_push_constant(cl, push, push.size())
		if p.indirect_res != null:
			rd.compute_list_dispatch_indirect(cl, p.indirect_res.rid, p.indirect_offset)
		else:
			rd.compute_list_dispatch(cl, p.groups.x, p.groups.y, p.groups.z)

	o.end_compute_list()
	var t_record_end := Time.get_ticks_usec()
	if sync:
		o.submit_and_sync(sync_include_global)
	var t_sync_end := Time.get_ticks_usec()
	_stats["barriers"] = barriers
	_stats["empty_dispatches"] = empty_dispatches
	_stats["record_usec"] = float(t_record_end - t_record_begin)
	_stats["submit_sync_usec"] = float(t_sync_end - t_record_end)


func _finalize_stats() -> void:
	var culled := 0
	for p in _passes:
		if p.culled:
			culled += 1
	var transient_count := 0
	for r in _resources:
		if not r.is_external():
			transient_count += 1
	_stats["passes_declared"] = _passes.size()
	_stats["passes_culled"] = culled
	_stats["passes_executed"] = _live_order.size()
	_stats["barriers_naive"] = maxi(0, _live_order.size() - 1)
	_stats["resources_declared"] = _resources.size()
	_stats["transient_virtual"] = transient_count
	_stats["warnings"] = _warnings.size()


# ——————————————————————————————————————————————————————————————
#  收尾 / 观测
# ——————————————————————————————————————————————————————————————

## 把 extracted 资源还池。调用之后 extracted 的 RID 不再有效，所以要先把数据读出来。
## uniform set 不在这里收：它们登记在 owner 的 SCOPE_PASS 下，随宿主的 gc_frame() 回收。
func dispose() -> void:
	if _disposed:
		return
	_disposed = true
	if _pool == null:
		return
	# 还掉所有「取了但还没还」的池化资源：正常路径下就是 extracted 的那些（它们的生命周期
	# 刻意延到图外）；execute 中途失败时，还包括已分配但没走到归还点的那些 —— 只认 extracted
	# 的话，这些资源会从池里永久漏掉。
	for r in _resources:
		if r.pooled and not r.released and r.rid.is_valid():
			r.released = true
			_pool.release(r.rid)
		if not r.is_external():
			r.rid = RID()
	_pool.flush()


func get_stats() -> Dictionary:
	return _stats.duplicate()


func get_warnings() -> PackedStringArray:
	return _warnings.duplicate()


## 声明期就收集到的错误（kernel 无效、params 形状不对、资源为 null 等）。
## 这些在 add_pass / add_clear_pass 当场就记下了，**不用 execute 也能查** ——
## 于是"坏图会不会被拦住"这件事可以在不往控制台抛 error 的前提下被测试。
func get_errors() -> PackedStringArray:
	return _errors.duplicate()


## 人读的图报告：每个 pass 的存活状态、切段点、访问；每个资源的生命周期区间。
func dump() -> String:
	var out: PackedStringArray = []
	out.append("=== RDG graph: %d pass 声明 / %d 执行 / %d 剔除 ===" % [
		_passes.size(), _live_order.size(), _passes.size() - _live_order.size()])
	for p in _passes:
		if p.culled:
			out.append("  [剔除]  %s" % p.describe())
			continue
		var cut := "──切──" if p.needs_barrier else "      "
		out.append("  %s %2d. %s" % [cut, p.exec_order, p.describe()])
	out.append("--- 资源 ---")
	for r in _resources:
		var span := "未使用" if r.first_pass < 0 else "pass %d..%d" % [r.first_pass, r.last_pass]
		out.append("  %s  生命周期=%s  写者%d/读者%d" % [
			r.describe(), span, r.producers.size(), r.consumers.size()])
	if not _warnings.is_empty():
		out.append("--- 警告 ---")
		for w in _warnings:
			out.append("  ! %s" % w)
	if not _stats.is_empty():
		out.append("--- 统计 ---")
		out.append("  切段 %d 次（朴素链式做法要 %d 次）" % [
			int(_stats.get("barriers", 0)), int(_stats.get("barriers_naive", 0))])
		out.append("  物理资源：请求 %d，其中复用 %d，新建 %d，峰值同时占用 %d" % [
			int(_stats.get("physical_acquired", 0)), int(_stats.get("physical_reused", 0)),
			int(_stats.get("physical_created", 0)), int(_stats.get("peak_live_physical", 0))])
	return "\n".join(out)
