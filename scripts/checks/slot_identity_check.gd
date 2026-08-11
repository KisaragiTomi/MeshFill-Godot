@tool
extends RefCounted

## 「槽位即身份」不变量的**在仓**核验（非生产层，住 scripts/checks/）。
##
## 被验的那条不变量（《GPU 直提渲染》§7.8）：
##
##   > slot 必须是 `(alive 集合, asset_index, object_id)` 的纯函数。
##   > 剔除只能改「这个槽画不画」，绝不能改「谁在哪个槽」。
##
## 它之所以是**正确性**而不是性能：`shaders/pick_id.gdshader` 写的是
## `pick_id = pick_id_base + INSTANCE_ID`，`PickIdPass` 按 `mm.instance_count` 分配 ID 区间
## —— MultiMesh 的槽位下标就是拾取 ID。ID 图渲染与 resolve 之间夹进一次 emit，
## 只要置换变了就是「点 A 选中 B」，而 `resolve_pick` 的批号自检抓不到同批内的置换。
##
## `autoobject_emit_instances.glsl` 的 scatter 用保序流压缩取代了 `atomicAdd` 抢槽位
## （`slot = instance_start[b] + wg_offsets[wg][b] + 组内名次`）。该改动此前**只过了编译门禁**，
## 行为证据来自仓外验收台 `GPUDirectEmitLab`。本文件补的就是那句「阻塞解除后应当在本仓复验一次」。
##
## 两条断言，第二条严格强于第一条：
##
##   A. **跨轮稳定**  同一对象集合连跑多轮 emit，slot → object_id 逐槽相同。
##      轮与轮之间**故意换相机位置**：剔除结果因此必然不同，而剔除不得改变槽位归属 ——
##      这正好压在"相机移动即可触发"那个最容易复现的窗口上。
##   B. **闭式可预言**  `wg_offsets` 是按工作组序的独占前缀，`stable_local_rank` 又按
##      lane 序计名次，而 `gid = wg * 64 + lid` ⇒ **批内槽位序 == object_id 升序**。
##      于是 CPU 不跑 GPU 也能算出每个对象该在哪个槽。`atomicAdd` 版本永远过不了这条。
##
## 本文件只读 GPU 输出、不改任何状态；emit 的驱动由调用方以 Callable 传入
## （它知道该用哪套 sync 选项 —— 选项不同即输入不同，那样的两轮本来就不该相同）。
## 调用入口是**桥**：核验要求场上真有放置对象，编辑器启动 flag 那种自检拿不到这个前提。

const RendererScript := preload("res://scripts/auto_object_instance_renderer.gd")

const FLAG_ALIVE := RendererScript.FLAG_ALIVE
const FLAG_CULLED := RendererScript.FLAG_CULLED


## 一轮 emit 之后的全量槽位快照。
## 返回 `{ok, reason, live, batches, object_ids, batch_indices, flags, culled}`。
static func snapshot(renderer) -> Dictionary:
	if renderer == null:
		return {"ok": false, "reason": "renderer_null"}
	var live := int(renderer.readback_live_count())
	if live < 0:
		return {"ok": false, "reason": "live_count_unavailable"}
	var identity: Dictionary = renderer.readback_slot_identity(live)
	if not bool(identity.get("ok", false)):
		# live == 0 时 readback_slot_identity 返回 ok=false（无槽位可读）。这不是失败，
		# 但也绝不能当成"稳定"通过 —— 0 个槽位的比对恒等于 0 处换主，是最典型的空洞绿。
		return {"ok": false, "reason": "slot_identity_unavailable(live=%d)" % live}
	var flags: PackedInt32Array = identity.get("flags", PackedInt32Array())
	var culled := 0
	for f in flags:
		if (f & FLAG_CULLED) != 0:
			culled += 1
	return {
		"ok": true,
		"reason": "ok",
		"live": live,
		"batches": renderer.readback_batch_headers(),
		"object_ids": identity.get("object_ids", PackedInt32Array()),
		"batch_indices": identity.get("batch_indices", PackedInt32Array()),
		"flags": flags,
		"culled": culled,
	}


## 断言 A：两份快照逐槽比对 slot → object_id。
## 返回 `{ok, compared, changed, first_changed_slot, live_a, live_b}`。
## live 数不同即判失败：对象集合本该在两轮之间保持不变，变了说明这次比对的前提就不成立。
static func compare(a: Dictionary, b: Dictionary) -> Dictionary:
	var ids_a: PackedInt32Array = a.get("object_ids", PackedInt32Array())
	var ids_b: PackedInt32Array = b.get("object_ids", PackedInt32Array())
	var live_a := int(a.get("live", -1))
	var live_b := int(b.get("live", -2))
	if live_a != live_b or ids_a.size() != ids_b.size():
		return {
			"ok": false, "compared": 0, "changed": -1, "first_changed_slot": -1,
			"live_a": live_a, "live_b": live_b,
			"reason": "live_count_changed_between_rounds",
		}
	var changed := 0
	var first := -1
	for slot in range(ids_a.size()):
		if ids_a[slot] != ids_b[slot]:
			changed += 1
			if first < 0:
				first = slot
	return {
		"ok": changed == 0, "compared": ids_a.size(), "changed": changed,
		"first_changed_slot": first, "live_a": live_a, "live_b": live_b,
		"reason": "ok" if changed == 0 else "slot_owner_changed",
	}


## 断言 B：闭式可预言。逐批检查 `[instance_start, instance_start + instance_count)`：
##   - 槽位里的 batch_index 必须等于批号（写错批 = 拾取解到别的资产）
##   - ALIVE 位必须置位（紧凑段里不该有空洞）
##   - object_id 必须**严格升序**（保序流压缩的定义性质；`atomicAdd` 版本必然违反）
## 另外校验各批 `instance_count` 之和 == live_count，防止"每批内部有序但整体漏了一批"。
##
## 顺带算两个**反空洞**指标，因为"升序"这条断言的强度完全取决于数据长什么样：
##   - `interleaved`  各批的 object_id 区间是否互相交错。若每批各占一段连续 gid，
##     "批内升序"会被 gid 布局本身送上门，断言就没验到 scatter；交错才说明
##     升序是 scatter 真的排出来的。
##   - `contending_workgroups`  ceil((max_gid + 1) / 64)，即真正装着存活对象的工作组数。
##     《GPU 直提渲染》§7.8 明确警告小工作组数验不出置换（3 个工作组时两次运行给出
##     135 与 0 两个相反结果），所以报告必须自陈它跑在哪个量级上，别让读者默认它够大。
## 返回 `{ok, checked, violations, sum_instance_count, live, interleaved,
##       contending_workgroups, spans, details}`。
static func closed_form(snap: Dictionary) -> Dictionary:
	var ids: PackedInt32Array = snap.get("object_ids", PackedInt32Array())
	var batch_of_slot: PackedInt32Array = snap.get("batch_indices", PackedInt32Array())
	var flags: PackedInt32Array = snap.get("flags", PackedInt32Array())
	var batches: Array = snap.get("batches", [])
	var live := int(snap.get("live", 0))
	var details: Array[String] = []
	var checked := 0
	var sum_count := 0
	var max_gid := -1
	var spans: Array = []            # 逐批 [batch, id_min, id_max, count]
	for b in range(batches.size()):
		var header: Dictionary = batches[b]
		var start := int(header.get("instance_start", 0))
		var count := int(header.get("instance_count", 0))
		sum_count += count
		if count <= 0:
			continue
		if start < 0 or start + count > ids.size():
			details.append("batch %d: 区间 [%d,%d) 越出已读槽位数 %d" % [b, start, start + count, ids.size()])
			continue
		var previous := -1
		for slot in range(start, start + count):
			checked += 1
			if batch_of_slot[slot] != b:
				details.append("batch %d slot %d: batch_index=%d（应为 %d）" % [
					b, slot, batch_of_slot[slot], b])
			if (flags[slot] & FLAG_ALIVE) == 0:
				details.append("batch %d slot %d: ALIVE 未置位（flags=%d）" % [b, slot, flags[slot]])
			if ids[slot] <= previous:
				details.append("batch %d slot %d: object_id=%d 未严格升序（前一个 %d）" % [
					b, slot, ids[slot], previous])
			previous = ids[slot]
		# 升序已在上面逐槽验过 ⇒ 区间端点就是首末槽位。
		spans.append([b, ids[start], ids[start + count - 1], count])
		max_gid = maxi(max_gid, ids[start + count - 1])
	var ok := details.is_empty() and sum_count == live and checked > 0
	if sum_count != live:
		details.append("Σinstance_count=%d != live_count=%d" % [sum_count, live])
	if checked == 0:
		details.append("没有任何批带实例，断言 B 无内容可验")
	# 交错判定：任意两批的 [id_min, id_max] 区间相交即为交错。不相交（各批独占一段
	# 连续 gid）时"批内升序"由 gid 布局白送，断言 B 验不到 scatter —— 必须报出来。
	var interleaved := false
	for i in range(spans.size()):
		for j in range(i + 1, spans.size()):
			if int(spans[i][1]) <= int(spans[j][2]) and int(spans[j][1]) <= int(spans[i][2]):
				interleaved = true
	return {
		"ok": ok, "checked": checked, "violations": details.size(),
		"sum_instance_count": sum_count, "live": live,
		"interleaved": interleaved,
		"contending_workgroups": (max_gid + 64) / 64 if max_gid >= 0 else 0,
		"spans": spans,
		"details": details,
	}


## 驱动多轮 emit 并汇总两条断言。
##   emit: Callable  形如 `func(camera_position: Vector3) -> void`，必须**强制**重跑 emit
##                   （renderer 的 revision + 相机位移守卫会让不强制的调用直接空转）
##   cameras: Array[Vector3]  逐轮相机位置；至少两个且**应当彼此拉开**，否则剔除集合不变，
##                            断言 A 就退化成"同输入同输出"这种弱得多的说法
## 返回 `{ok, reason, rounds, live, stability, closed_form, cull_counts, cull_varied}`。
static func run_rounds(renderer, emit: Callable, cameras: Array) -> Dictionary:
	if renderer == null:
		return {"ok": false, "reason": "renderer_null"}
	if cameras.size() < 2:
		return {"ok": false, "reason": "need_at_least_two_camera_rounds"}
	var snapshots: Array[Dictionary] = []
	for camera in cameras:
		emit.call(camera as Vector3)
		var snap := snapshot(renderer)
		if not bool(snap.get("ok", false)):
			return {"ok": false, "reason": "snapshot_failed:%s" % str(snap.get("reason", "unknown"))}
		snapshots.append(snap)
	var stability: Array[Dictionary] = []
	var stable := true
	for i in range(1, snapshots.size()):
		var result := compare(snapshots[0], snapshots[i])
		result["round"] = i
		stability.append(result)
		stable = stable and bool(result.get("ok", false))
	var form := closed_form(snapshots[0])
	var cull_counts: Array[int] = []
	for snap in snapshots:
		cull_counts.append(int(snap.get("culled", 0)))
	var cull_varied := false
	for c in cull_counts:
		if c != cull_counts[0]:
			cull_varied = true
	return {
		"ok": stable and bool(form.get("ok", false)),
		"reason": "ok" if (stable and bool(form.get("ok", false))) else "invariant_violated",
		"rounds": snapshots.size(),
		"live": int(snapshots[0].get("live", 0)),
		"batches": snapshots[0].get("batches", []),
		"stability": stability,
		"closed_form": form,
		"cull_counts": cull_counts,
		"cull_varied": cull_varied,
	}


## 桥友好的定长文本报告。`cull_varied=false` 会被显式标成 WEAK：
## 剔除集合在各轮之间没有变化时，断言 A 只证明了"同输入同输出"，没碰到真正的窗口。
static func format_report(result: Dictionary) -> String:
	if not result.has("rounds"):
		return "ERROR %s" % str(result.get("reason", "unknown"))
	var form: Dictionary = result.get("closed_form", {})
	var lines: Array[String] = [
		"verdict=%s" % ("SLOT_IDENTITY_STABLE" if bool(result.get("ok", false)) else "SLOT_IDENTITY_BROKEN"),
		"rounds=%d live=%d batches=%d" % [
			int(result.get("rounds", 0)), int(result.get("live", 0)),
			(result.get("batches", []) as Array).size()],
		"cull_counts=%s varied=%s%s" % [
			str(result.get("cull_counts", [])), str(result.get("cull_varied", false)),
			"" if bool(result.get("cull_varied", false)) else "  ⚠ WEAK: 各轮剔除集合相同，断言 A 未压到相机窗口"],
	]
	for entry in result.get("stability", []):
		var row: Dictionary = entry
		lines.append("A round0 vs round%d: compared=%d changed=%d first_changed_slot=%d (%s)" % [
			int(row.get("round", -1)), int(row.get("compared", 0)), int(row.get("changed", -1)),
			int(row.get("first_changed_slot", -1)), str(row.get("reason", ""))])
	lines.append("B closed_form: checked=%d violations=%d Σinstance_count=%d live=%d" % [
		int(form.get("checked", 0)), int(form.get("violations", 0)),
		int(form.get("sum_instance_count", 0)), int(form.get("live", 0))])
	lines.append("B non-vacuity: gid_interleaved=%s%s  contending_workgroups=%d%s" % [
		str(form.get("interleaved", false)),
		"" if bool(form.get("interleaved", false)) else "  ⚠ WEAK: 各批各占一段连续 gid，批内升序由布局白送",
		int(form.get("contending_workgroups", 0)),
		"" if int(form.get("contending_workgroups", 0)) >= 100 \
			else "  ⚠ 低于《GPU 直提渲染》§7.8 所述「上百个工作组才暴露」的量级"])
	for detail in (form.get("details", []) as Array).slice(0, 12):
		lines.append("  ! %s" % str(detail))
	var spans_by_batch := {}
	for span in (form.get("spans", []) as Array):
		spans_by_batch[int((span as Array)[0])] = span
	for header in (result.get("batches", []) as Array):
		var h: Dictionary = header
		if int(h.get("instance_count", 0)) <= 0:
			continue
		var index := int(h.get("asset_index", -1))
		var span: Array = spans_by_batch.get(index, [index, -1, -1, 0])
		lines.append("  batch %d: start=%d count=%d capacity=%d profile_id=%d object_id=[%d..%d]" % [
			index, int(h.get("instance_start", 0)), int(h.get("instance_count", 0)),
			int(h.get("capacity", 0)), int(h.get("profile_id", -1)),
			int(span[1]), int(span[2])])
	return "\n".join(lines)
