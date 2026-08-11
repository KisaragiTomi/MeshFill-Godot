class_name ComputeKernel
extends RefCounted

## 单个 compute shader 的封装：shader + pipeline 只编译一次（挂 owner 的 SCOPE_PERSISTENT，
## 走 owner 的 track/GC 系统释放），push-constant 布局用 [PushConstantLayout] 声明一次。每次
## dispatch 只传数据，产出一个 pass 描述符（交给 [ComputePassChain] 调度）。
##
## owner 须为 [GodotComputeShaderBase]（或子类）实例——本类完全通过 owner 的公开方法组合，
## 既不修改也不继承 base class，因此对 base class 的并发改动免疫。owner 以 weakref 持有，
## 避免 “子系统 → kernel → owner” 的 RefCounted 循环引用泄漏（kernel 通常是 owner 的成员）。
##
## 简单场景（顺序 storage buffer、单 set 0）：
##   var k := ComputeKernel.create(self, "res://shaders/example_pass.glsl",
##       [["grid", "ivec4"], ["tri_count", "int"], ["_pad0", "int"], ["_pad1", "int"], ["_pad2", "int"]])
##   var p := k.make_pass([tri_buf, occupancy_buf, color_buf], {grid = g4, tri_count = n},
##       k.groups_3d(grid.x, grid.y, grid.z, 4, 4, 4))
##   ComputePassChain.run(self, [p])
##
## 复杂场景（image/sampler/多 set）：调用方自行用 owner.make_image_uniform / make_sampler_uniform
##   + owner.create_uniform_set 构建各 set（按 set index 顺序放数组），交给 make_pass_sets(...)。

# 内部交叉引用走 preload 常量（而非 class_name 全局），避免依赖“新 class_name 注册顺序”，
# 使本模块可独立编译/验证。三个模块各自仍声明 class_name 供下游按全局名引用。
const PushConstantLayoutScript := preload("res://scripts/utils/push_constant_layout.gd")
const ComputePassChainScript := preload("res://scripts/utils/compute_pass_chain.gd")

var shader: RID
var pipeline: RID
var layout: PushConstantLayoutScript = null
var label := ""

## 源码里是否出现原子操作。原子天生是**就地读改写**，在 [RDGBuilder] 里对应的绑定必须声明成
## [method RDG.read_write]；误声明成 write，图会认为它整块覆盖，把上游的初始化 pass 剔掉 ——
## 而 GPU 不报错，原子累加就落在一块没初始化的池内存上。图用这个标记逮那种漏声明。
## 现有 [ComputePassChain] 路径不读它（那条路没有依赖推导），故为纯附加信息。
var uses_atomics := false

var _owner_ref: WeakRef = null


## 创建并编译一个 kernel。push_schema 为空表示该 shader 无 push constant。
## 失败（owner 为空 / shader 编译失败）时返回的 kernel is_valid() == false。
## scope 控制 shader+pipeline 的生命周期作用域（默认 SCOPE_PERSISTENT 跨帧缓存）。对于原本
## 每次调用 SCOPE_FRAME 加载、随 gc_frame 释放的瞬态 dispatch，传 SCOPE_FRAME 并每次调用重新
## create()（kernel 不跨帧复用，与既有瞬态 shader 语义一致）。
static func create(owner_base: GodotComputeShaderBase, shader_path: String, push_schema: Array = [], label := "", scope := GodotComputeShaderBase.SCOPE_PERSISTENT) -> ComputeKernel:
	var k := ComputeKernel.new()
	k.label = label if not label.is_empty() else shader_path.get_file()
	if owner_base == null:
		push_error("ComputeKernel.create: owner 为空（%s）" % k.label)
		return k
	k._owner_ref = weakref(owner_base)
	k.shader = owner_base.load_compute_shader(shader_path, scope, k.label)
	if not k.shader.is_valid():
		push_error("ComputeKernel.create: shader 加载失败: %s" % shader_path)
		return k
	k.pipeline = owner_base.create_compute_pipeline(k.shader, scope, k.label)
	k.uses_atomics = _source_uses_atomics(owner_base.read_compute_shader_source(shader_path))
	if not push_schema.is_empty():
		k.layout = PushConstantLayoutScript.new(push_schema)
	return k


## 扫一遍 GLSL 源码找原子调用。Godot 没有把「哪个绑定是读改写」这类信息反射出来，
## 而这恰恰是 [RDGBuilder] 唯一无法自己推出、只能靠调用方声明的东西 —— 扫源码是唯一能把
## 「漏声明 read_write」从静默失败变成响亮失败的办法。
##
## 只剥行注释、不解析块注释：宁可偶尔多报一次（那只是一条警告），也不漏掉真的漏声明。
## 源文本由 owner 的 read_compute_shader_source() 提供（已处理 res:// 与绝对路径两条读法）。
static func _source_uses_atomics(source: String) -> bool:
	if source.is_empty():
		return false
	var stripped := ""
	for line in source.split("\n"):
		var c := line.find("//")
		stripped += (line if c < 0 else line.substr(0, c)) + "\n"
	var re := RegEx.new()
	re.compile("atomic(Add|Min|Max|And|Or|Xor|Exchange|CompSwap)\\s*\\(")
	return re.search(stripped) != null


func is_valid() -> bool:
	return shader.is_valid() and pipeline.is_valid()


## kernel 就绪判定（null 安全壳）：setup() 之前引用为 null，shader 编译失败时 shader/pipeline 非法。
static func ready(kernel: ComputeKernel) -> bool:
	return kernel != null and kernel.is_valid()


## 解析 owner（weakref）。owner 已释放时返回 null。
func owner() -> GodotComputeShaderBase:
	return _owner_ref.get_ref() as GodotComputeShaderBase if _owner_ref != null else null


func pack(push_values: Dictionary) -> PackedByteArray:
	if layout == null:
		# 无 push schema 却传了 push 值 —— 这些值会被整段丢弃，shader 拿到的是上一次残留/全零。
		if not push_values.is_empty():
			push_error("ComputeKernel.pack: kernel '%s' 未声明 push schema，却收到 %d 个 push 值 %s —— 这些值会被静默丢弃" % [label, push_values.size(), str(push_values.keys())])
			assert(false, "ComputeKernel.pack: push values without schema")
		return PackedByteArray()
	return layout.pack(push_values)


## 顺序 storage buffer 绑定成一个 uniform set：buffers[i] -> binding i。返回 uniform set RID
## （由 owner 按 scope 跟踪回收，默认 SCOPE_PASS）。
func bind_storage(buffers: Array, set_index := 0, scope := GodotComputeShaderBase.SCOPE_PASS) -> RID:
	var o := owner()
	if o == null:
		push_error("ComputeKernel.bind_storage: owner 已释放（%s）" % label)
		return RID()
	var uniforms: Array = []
	for i in range(buffers.size()):
		uniforms.append(o.make_storage_uniform(i, buffers[i]))
	return o.create_uniform_set(uniforms, shader, set_index, scope, label)


## 常见场景：顺序 storage buffer + 单 set 0。产出一个直接 dispatch 的 pass 描述符。
func make_pass(buffers: Array, push_values: Dictionary, groups: Vector3i, scope := GodotComputeShaderBase.SCOPE_PASS) -> Dictionary:
	return _pass([bind_storage(buffers, 0, scope)], push_values, groups, RID(), 0)


## 通用场景：调用方预构建好各 uniform set（按 set index 顺序），支持 image/sampler/多 set。
func make_pass_sets(uniform_sets: Array, push_values: Dictionary, groups: Vector3i) -> Dictionary:
	return _pass(uniform_sets, push_values, groups, RID(), 0)


## indirect 变体：dispatch 组数由 indirect_args 缓冲（GPU 写入）决定，groups 被忽略。
func make_pass_indirect(buffers: Array, push_values: Dictionary, indirect_args: RID, args_offset := 0, scope := GodotComputeShaderBase.SCOPE_PASS) -> Dictionary:
	return _pass([bind_storage(buffers, 0, scope)], push_values, Vector3i.ONE, indirect_args, args_offset)


## 便捷：单 pass 独立调度并 submit_and_sync（一次性单段 kernel）。多段链请用 ComputePassChain.run。
## sync_include_global：借用（非自有）设备时须传 true，否则 submit_and_sync 在借用设备上是 no-op。
func run(buffers: Array, push_values: Dictionary, groups: Vector3i, sync := true, sync_include_global := false) -> bool:
	var o := owner()
	if o == null:
		push_error("ComputeKernel.run: owner 已释放（%s）" % label)
		return false
	return ComputePassChainScript.run(o, [make_pass(buffers, push_values, groups)], sync, true, sync_include_global)


## 组数计算：委托 owner 的 dispatch_groups_*（保持与既有 dispatch 现场一致的 ceil_div 语义）。
## owner 已释放时返回 Vector3i.ZERO（0 组 = 不派发），并报错中断。
## 原先返回 Vector3i.ONE —— 那会以 1 个工作组真的跑一遍 shader，只处理前 local_size 个元素，
## 结果是「有输出但绝大部分数据没算」，比不跑更难发现。
func _groups_owner_lost(which: String) -> Vector3i:
	push_error("ComputeKernel.%s: owner 已释放（%s）—— 无法计算工作组数，拒绝返回 1 组假派发" % [which, label])
	assert(false, "ComputeKernel: owner released while computing dispatch groups")
	return Vector3i.ZERO


func groups_1d(count: int, local_x: int) -> Vector3i:
	var o := owner()
	return o.dispatch_groups_1d(count, local_x) if o != null else _groups_owner_lost("groups_1d")


func groups_2d(w: int, h: int, local_x: int, local_y: int) -> Vector3i:
	var o := owner()
	return o.dispatch_groups_2d(w, h, local_x, local_y) if o != null else _groups_owner_lost("groups_2d")


func groups_3d(w: int, h: int, d: int, local_x: int, local_y: int, local_z: int) -> Vector3i:
	var o := owner()
	return o.dispatch_groups_3d(w, h, d, local_x, local_y, local_z) if o != null else _groups_owner_lost("groups_3d")


func _pass(uniform_sets: Array, push_values: Dictionary, groups: Vector3i, indirect_args: RID, args_offset: int) -> Dictionary:
	var desc := {
		"pipeline": pipeline,
		"uniform_sets": uniform_sets,
		"push": pack(push_values),
		"groups": groups,
	}
	if indirect_args.is_valid():
		desc["indirect_args"] = indirect_args
		desc["indirect_offset"] = args_offset
	return desc
