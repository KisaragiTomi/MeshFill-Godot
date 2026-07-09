class_name ComputePassChain
extends RefCounted

## 把一串 pass 描述符在单条 compute list 里顺序调度，段间自动补 barrier，收尾 submit_and_sync。
## 替代各处手接 rd.compute_list_bind_* / compute_list_set_push_constant / compute_list_add_barrier
## 的样板，并消除“忘插 barrier → 静默数据竞争”这一脆弱点。
##
## pass 描述符契约（由 [ComputeKernel] 的 make_pass* 产出，也可手搓）：
##   {
##     "pipeline": RID,                 # 必填
##     "uniform_sets": Array[RID],      # 必填，按 set index 顺序放置（uniform_sets[i] 绑到 set i）
##     "push": PackedByteArray,         # 可空；空则不设 push constant
##     "groups": Vector3i,              # 直接 dispatch 的工作组数
##     "indirect_args": RID,            # 选填：有效则走 dispatch_indirect，忽略 groups
##     "indirect_offset": int,          # 选填：indirect 参数字节偏移，默认 0
##   }
##
## owner 须为 [GodotComputeShaderBase]（或子类）：本类只用其公开的 begin/end compute list、
## get_rendering_device、submit_and_sync，并自己内联 RD 的 bind/dispatch 序列（不依赖 base class
## 的私有 _gpu_dispatch_* 方法），因此对 base class 的并发改动免疫。
##
## 注意（与项目现状一致）：uniform_sets 为位置数组，uniform_sets[i] 绑定到 set index i，
## 从 0 起连续（现有多 set 用例均为 set 0 + set 1 连续，符合该约定）。

## 顺序调度所有 pass。barrier_between 为真时在相邻 pass 间插入 compute_list_add_barrier。
## sync 为真时结尾 submit_and_sync；sync_include_global 传给 submit_and_sync（借用/非自有设备须传 true，
## 否则在借用设备上 submit_and_sync() 是 no-op、dispatch 不会提交）。
## 任一 pass 描述符非法则中止、收尾 compute list 并返回 false。
static func run(owner: GodotComputeShaderBase, passes: Array, sync := true, barrier_between := true, sync_include_global := false) -> bool:
	if owner == null:
		push_error("ComputePassChain.run: owner 为空")
		return false
	var rd := owner.get_rendering_device()
	if rd == null:
		push_error("ComputePassChain.run: owner 无 RenderingDevice")
		return false
	if passes.is_empty():
		return true

	var cl := owner.begin_compute_list()
	if cl < 0:
		# 安全不变量：base class 的 begin_compute_list() 只在 _rd==null 时返回 <0，且该分支
		# 在置 _compute_list_active=true 之前 —— 故此处无需 end_compute_list()（无活动 list、
		# 无泄漏）。上方已先挡 rd==null，此分支实为防御性冗余。
		push_error("ComputePassChain.run: begin_compute_list 失败")
		return false

	var ok := true
	for i in range(passes.size()):
		if not _dispatch_one(rd, cl, passes[i]):
			ok = false
			break
		if barrier_between and i < passes.size() - 1:
			rd.compute_list_add_barrier(cl)

	owner.end_compute_list()
	if not ok:
		return false
	if sync:
		owner.submit_and_sync(sync_include_global)
	return true


static func _dispatch_one(rd: RenderingDevice, cl: int, pass_desc: Dictionary) -> bool:
	var pipeline: RID = pass_desc.get("pipeline", RID())
	if not pipeline.is_valid():
		push_error("ComputePassChain: pass 的 pipeline 非法")
		return false
	rd.compute_list_bind_compute_pipeline(cl, pipeline)

	var sets: Array = pass_desc.get("uniform_sets", [])
	for si in range(sets.size()):
		var s: RID = sets[si]
		if not s.is_valid():
			push_error("ComputePassChain: pass 的 uniform set[%d] 非法" % si)
			return false
		rd.compute_list_bind_uniform_set(cl, s, si)

	var push: PackedByteArray = pass_desc.get("push", PackedByteArray())
	if push.size() > 0:
		rd.compute_list_set_push_constant(cl, push, push.size())

	var indirect: RID = pass_desc.get("indirect_args", RID())
	if indirect.is_valid():
		rd.compute_list_dispatch_indirect(cl, indirect, int(pass_desc.get("indirect_offset", 0)))
	else:
		var g: Vector3i = pass_desc.get("groups", Vector3i.ONE)
		rd.compute_list_dispatch(cl, g.x, g.y, g.z)
	return true
