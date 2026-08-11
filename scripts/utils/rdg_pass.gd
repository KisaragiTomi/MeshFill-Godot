@tool
class_name RDGPass
extends RefCounted

## 图中的一个 compute pass（UE: FRDGPass）。
##
## 与现有 [ComputePassChain] 的 pass 描述符最大的区别：这里存的是**虚拟资源 + 访问语义**，
## 而不是已经建好的 uniform set RID。uniform set 要等到 [method RDGBuilder.execute] 的分配阶段、
## 物理 RID 落定之后才建 —— 因为在那之前根本不知道这个 pass 会拿到池里的哪块内存。

# 内部交叉引用走 preload 常量（理由见 [RDGResource] 顶部注释）。
const RDGScript := preload("res://scripts/utils/rdg.gd")
const RDGResourceScript := preload("res://scripts/utils/rdg_resource.gd")
const ComputeKernelScript := preload("res://scripts/utils/compute_kernel.gd")

var index := -1                       ## 声明序下标
var name := ""
var kernel: ComputeKernelScript = null

## Array[Array[Dictionary]]：param_sets[s][i] 绑到 **set s 的 binding i**，
## 每项是 {res: RDGResource, access: RDG.Access}。
## 调用方传扁平数组（单 set）或嵌套数组（多 set）都行，builder 会归一化成嵌套形式。
var param_sets: Array = []

var push_values := {}
var groups := Vector3i.ZERO

## indirect dispatch：非 null 时忽略 groups，从该资源读取工作组数。
## 它同时会作为一条 INDIRECT 访问参与依赖建边（写它的 pass 必须排在本 pass 之前）—— 这是
## 手写 dispatch 链最容易漏掉的一条依赖：GPU 写完 indirect args 到 GPU 读它之间必须切段。
var indirect_res: RDGResourceScript = null
var indirect_offset := 0

## UE 的 ERDGPassFlags::NeverCull。用于"输出只有副作用、图看不见"的 pass。
var never_cull := false

## —— 编译期产物（每次 execute 重算）——————————————————————————

## 全部排序边：RAW（读后于写）+ WAR（写后于读）+ WAW（写后于写）。barrier 规划用这一套。
var deps := PackedInt32Array()

## 仅 RAW 边（"我需要你写出来的数据"）。**剔除**只沿这套边反向传播。
## 不能用 deps 做剔除：WAR/WAW 只是执行顺序约束，不代表被依赖的 pass 有存在必要——
## 沿 WAR 边反向传播会把"只读了一下、输出没人要"的死 pass 一起判成存活。
var raw_deps := PackedInt32Array()

var culled := false
var exec_order := -1                  ## 存活 pass 中的执行序；被剔除的保持 -1
var needs_barrier := false            ## 执行前是否要 compute_list_add_barrier（= 切段）
var uniform_sets: Array[RID] = []     ## 分配阶段建好的 set，按 set index 顺序


func reset_compile_state() -> void:
	deps = PackedInt32Array()
	raw_deps = PackedInt32Array()
	culled = false
	exec_order = -1
	needs_barrier = false
	uniform_sets = []


## 加一条排序边。is_raw 为真时同时计入剔除用的 RAW 边集。
func add_dep(other_index: int, is_raw := false) -> void:
	if other_index < 0 or other_index == index:
		return
	if not deps.has(other_index):
		deps.append(other_index)
	if is_raw and not raw_deps.has(other_index):
		raw_deps.append(other_index)


## 本 pass 触及的全部访问，含 indirect args。建边、生命周期、校验都走这一个入口，
## 避免 indirect 依赖在某一处被漏算。
func all_accesses() -> Array:
	var out: Array = []
	for group in param_sets:
		out.append_array(group)
	if indirect_res != null:
		out.append(RDGScript.indirect(indirect_res))
	return out


func describe() -> String:
	var parts: PackedStringArray = []
	var multi := param_sets.size() > 1
	for si in range(param_sets.size()):
		for a in param_sets[si]:
			var r: RDGResourceScript = a["res"]
			# 采样读在依赖上等同普通读（同一个 Access.READ），但绑定方式完全不同 ——
			# dump 里区分开，省得对着一条 "R:Tex" 猜它到底绑成了 image 还是 sampler2D。
			var tag := "%s:%s" % ["SMP" if a.has("sampler") else RDGScript.access_name(a["access"]), r.name]
			parts.append("s%d/%s" % [si, tag] if multi else tag)
	if indirect_res != null:
		parts.append("IND:%s" % indirect_res.name)
	return "#%d %s (%s)" % [index, name, ", ".join(parts)]
