@tool
class_name RDGResource
extends RefCounted

## 图中的**虚拟资源句柄**（UE: FRDGBuffer / FRDGTexture）。
##
## 关键性质：create_buffer/create_texture 返回它的时候**还没有任何 GPU 资源**。物理 RID 直到
## [method RDGBuilder.execute] 的分配阶段才从瞬态池里取，并在生命周期结束后立刻还池。这正是 RDG
## 相对"手动 create 一堆 buffer 再手动 free"的核心价值：调用方按数据流写代码，物理分配由图负责。
##
## external 资源（register_external_*）例外：RID 一开始就有，永不入池、永不被释放。

# 内部交叉引用走 preload 常量（而非 class_name 全局），避免依赖"新 class_name 注册顺序"，
# 使本模块可独立编译/验证（`--check-only --script` 单文件 parse gate）。与 [ComputeKernel] 同规。
const RDGScript := preload("res://scripts/utils/rdg.gd")

var index := -1                       ## 在 builder 资源表中的下标，也是依赖跟踪的 key
var name := ""
var kind := RDGScript.Kind.BUFFER
var origin := RDGScript.Origin.TRANSIENT
var desc = null                       ## RDG.BufferDesc / RDG.TextureDesc；external 资源可为 null

var rid := RID()                      ## 物理 RID：external 立即有效；transient 仅在执行期间有效
var logical_size := 0                 ## buffer 的逻辑字节数。物理 RID 可能更大（池按 2 的幂分桶），
                                      ## 回读时必须按逻辑尺寸截取，否则会读到桶里的尾部垃圾。

## 图的输出根：执行后要把物理 RID 交还给调用方（UE: QueueBufferExtraction）。
## 被 extract 的资源不入池 —— 还池了 RID 立刻会被下一个 pass 抢走。
var extracted := false

## —— 编译期产物（每次 execute 重算）——————————————————————————
var producers := PackedInt32Array()   ## 写过它的全部 pass 下标（声明序），仅供 dump 观测

## 建边结束时**仍未被取代**的写者。剔除的根用这个，不能用 producers：
## 若 p0 填了它、p2 又整块覆盖了它，p0 的产出已经没人要，拿 producers 当根会把 p0 永久判活。
var final_writers := PackedInt32Array()

var consumers := PackedInt32Array()   ## 读它的 pass 下标（声明序）
var first_pass := -1                  ## 存活 pass 中首次触及的 exec_order
var last_pass := -1                   ## 存活 pass 中最后触及的 exec_order
var initialized := false              ## 建边过程中是否已被写过 —— 用于"读未初始化资源"校验
var pooled := false                   ## 本次执行中是否真的从池里取了物理资源

## 是否已经还过池。**必须有这个标记**：归还是遍历 pass 的全部访问做的，而同一个资源在一个
## pass 里完全可能出现多次（同一 buffer 绑到两个 binding、跨两个 set、或既当参数又当 indirect
## args）。不去重的话同一个 RID 会被塞进空闲表两次，后续两个不同的资源拿到同一块物理内存，
## 互相踩踏且毫无报错。它同时兜住错误返回路径：execute 中途失败时，已分配未归还的资源
## 由 dispose() 按这个标记补还，不会从池里永久漏掉。
var released := false


func is_external() -> bool:
	return origin == RDGScript.Origin.EXTERNAL


## 是否参与瞬态池：图内创建、且不是图的输出。
func is_poolable() -> bool:
	return origin == RDGScript.Origin.TRANSIENT and not extracted


## external 或 extracted 的资源是图的"可观测输出"，其生产者是剔除的根。
func is_output_root() -> bool:
	return is_external() or extracted


func reset_compile_state() -> void:
	producers = PackedInt32Array()
	final_writers = PackedInt32Array()
	consumers = PackedInt32Array()
	first_pass = -1
	last_pass = -1
	# external 资源的内容来自图外，视为一开始就已初始化，读它不该报"未初始化"。
	initialized = is_external()
	pooled = false
	released = false


func describe() -> String:
	var tag := "ext" if is_external() else "transient"
	if extracted:
		tag += "+extracted"
	var d: String = desc.describe() if desc != null else "?"
	return "#%d %s [%s %s]" % [index, name, d, tag]
