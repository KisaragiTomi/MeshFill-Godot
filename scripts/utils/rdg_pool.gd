@tool
class_name RDGPool
extends RefCounted

## 瞬态物理资源池（UE: FRDGPooledBuffer / IPooledRenderTarget 背后的 render target pool）。
##
## 图里的中间量绝大多数生命周期只跨几个 pass，逐帧 create/free 是纯浪费。池按描述符分桶持有
## 物理 RID，图执行时 acquire、生命周期结束立刻 release，跨图、跨帧持续复用。
##
## **池必须活得比单个 [RDGBuilder] 长** —— 它是复用的载体。每帧新建一个 builder、共用同一个池。
##
## owner 须为 [GodotComputeShaderBase]（或子类）实例：物理资源全部经 owner 的
## create_rw_texture_* / RenderingDevice 建出、并按 [constant POOL_SCOPE] 登记进 owner 的
## RID 跟踪器。本类完全通过 owner 的公开方法组合，既不修改也不继承 base class（与
## [ComputeKernel] / [ComputePassChain] 同规）。owner 以 weakref 持有，避免
## "owner → pool → owner" 的 RefCounted 循环引用泄漏（池通常是 owner 的成员）。
##
## ⚠ 生命周期耦合：池内资源登记在 [constant POOL_SCOPE] 这个专属 scope 下，gc_frame()
## （只收 SCOPE_PASS / SCOPE_FRAME）碰不到它们；但 owner 的 gc_all() / dispose() 会把它们一起
## 释放。owner 一旦 gc_all/dispose，本池必须随之 dispose() 或丢弃 —— 否则空闲表里留着的是
## 已失效的 RID（RID.is_valid() 只看 id 非零，查不出来）。
##
## 安全约束（对应 UE 的 aliasing barrier）：一块物理资源被 A 用完还池后，只有当中间隔了一次
## 切段（compute_list_add_barrier）才允许被 B 取走。否则 A 的写和 B 的写落在同一段里，GPU 可以
## 任意交错 —— 这是资源别名最经典的静默数据竞争。为此 [method release] 先进 _pending，只有
## [method commit_barrier] 被调用（= 图真的切了一段）时 _pending 才并入 _free。

# 内部交叉引用走 preload 常量（理由见 [RDGResource] 顶部注释）。
const RDGScript := preload("res://scripts/utils/rdg.gd")
const BaseScript := preload("res://scripts/godot_compute_shader_base.gd")

## 池内物理资源在 owner RID 跟踪器里的专属 scope。刻意不用 SCOPE_FRAME/SCOPE_PASS：
## 那两个会被 owner 的 gc_frame() 在池毫不知情的情况下收走，空闲表随即全是失效 RID。
const POOL_SCOPE := "rdg_pool"

var _owner_ref: WeakRef = null
var _free := {}          ## pool_key -> Array[RID]，可安全复用
var _pending := {}       ## pool_key -> Array[RID]，已还但尚未跨过切段，暂不可复用
var _key_of := {}        ## rid 的 int id -> pool_key，release 时反查

## 内建 kernel 的缓存（"clear" 等），由 [RDGBuilder] 懒填。放在池上是取它"与 owner 同寿、
## 跨图存活"的生命周期；值刻意不加类型标注 —— 池不需要认识 [ComputeKernel]。
var builtins := {}

## —— 统计（跨图累计）——
var total_created := 0   ## 池实际向设备申请过的物理资源数
var total_acquired := 0  ## 图请求分配的次数
var total_reused := 0    ## 其中命中复用的次数


func _init(owner_base: BaseScript) -> void:
	if owner_base == null:
		push_error("RDGPool: owner 为空 —— 池无法建立任何物理资源")
		return
	_owner_ref = weakref(owner_base)


## 解析 owner（weakref）。owner 已释放时返回 null。
func owner() -> BaseScript:
	return _owner_ref.get_ref() as BaseScript if _owner_ref != null else null


func is_valid() -> bool:
	var o := owner()
	return o != null and o.get_rendering_device() != null


## 取一块满足 desc 的物理资源。命中空闲则复用，否则新建。
func acquire(desc) -> RID:
	if not is_valid() or desc == null:
		return RID()
	var key: String = desc.pool_key()
	total_acquired += 1

	var bucket: Array = _free.get(key, [])
	if not bucket.is_empty():
		var rid: RID = bucket.pop_back()
		_free[key] = bucket
		total_reused += 1
		_key_of[rid.get_id()] = key
		return rid

	var fresh := _create(desc)
	if fresh.is_valid():
		total_created += 1
		_key_of[fresh.get_id()] = key
	return fresh


## 归还。进 _pending，跨过一次切段后才真正可复用（见类注释的别名约束）。
func release(rid: RID) -> void:
	if not rid.is_valid():
		return
	var key: String = _key_of.get(rid.get_id(), "")
	if key.is_empty():
		return
	var bucket: Array = _pending.get(key, [])
	bucket.append(rid)
	_pending[key] = bucket


## 图刚刚切了一段：此前归还的资源现在可以安全复用了。
func commit_barrier() -> void:
	for key in _pending.keys():
		var free_bucket: Array = _free.get(key, [])
		free_bucket.append_array(_pending[key])
		_free[key] = free_bucket
	_pending.clear()


## 图执行结束：剩余 _pending 全部转正（图外没有并发的 GPU 工作）。
func flush() -> void:
	commit_barrier()


func _create(desc) -> RID:
	var o := owner()
	if o == null:
		return RID()
	if desc is RDGScript.BufferDesc:
		return _create_buffer(o, desc)
	if desc is RDGScript.TextureDesc:
		return _create_texture(o, desc)
	push_error("RDGPool._create: 未知描述符类型 %s" % str(desc))
	return RID()


## 按**分桶尺寸**申请物理内存，而非逻辑尺寸 —— 复用率全靠这一步。
##
## 直接走 RenderingDevice.storage_buffer_create 而不是 base class 的 storage_buffer_zero /
## storage_buffer_uninitialized：那两个都不接受 usage 位，而 DISPATCH_INDIRECT 位必须在建
## buffer 时给（绑定阶段补不了），且它已经进了 pool_key（usage 不同的 buffer 不互换复用）。
## RID 仍按 [constant POOL_SCOPE] 登记进 owner 的跟踪器，所有权与 GC 审计语义不变。
func _create_buffer(o: BaseScript, desc) -> RID:
	var rd := o.get_rendering_device()
	if rd == null:
		return RID()
	var bytes: int = desc.pool_bucket()
	var rid: RID = rd.storage_buffer_create(bytes, PackedByteArray(), desc.usage)
	if not rid.is_valid():
		push_error("RDGPool: storage_buffer_create 失败（%d 字节, usage=%d）" % [bytes, desc.usage])
		return RID()
	return o.track_rid(rid, BaseScript.KIND_BUFFER, POOL_SCOPE, "rdg_pool_buffer")


## usage 位从 desc 来，不在这里写死：少一个 SAMPLING 位的纹理没法在绑定阶段补救，
## 只能在建纹理时给。desc.usage 同时进了 pool_key，usage 不同的纹理不会被互换复用。
func _create_texture(o: BaseScript, desc) -> RID:
	if int(desc.depth) > 1:
		return o.create_rw_texture_3d(desc.width, desc.height, desc.depth, desc.format,
				desc.usage, POOL_SCOPE, "rdg_pool_texture3d")
	return o.create_rw_texture_2d(desc.width, desc.height, desc.format,
			desc.usage, POOL_SCOPE, "rdg_pool_texture2d")


func free_count() -> int:
	var n := 0
	for k in _free.keys():
		n += (_free[k] as Array).size()
	return n


## 释放池内全部物理资源。设备本身归 owner（本类只借用，绝不 dispose 它）。
func dispose() -> void:
	flush()
	var o := owner()
	if o != null:
		for key in _free.keys():
			for rid in _free[key]:
				o.release_rid(rid)
	_free.clear()
	_pending.clear()
	_key_of.clear()
	# 内建 kernel 的 shader/pipeline RID 由 owner 按 SCOPE_PERSISTENT 跟踪并释放，这里只丢引用。
	builtins.clear()


func stats() -> Dictionary:
	return {
		"created": total_created,
		"acquired": total_acquired,
		"reused": total_reused,
		"free_now": free_count(),
	}
