@tool
class_name VolumeFieldBuffers
extends RefCounted

## 一个体积域的**场对 Buffer 生命周期**：分配 / 命中复用 / 尺寸变更重建 / 就地清零 / 释放。
## 《AutoVolume 公用体积基类计划》§2.5-7 的落点。
##
## ── 为什么是 RefCounted 助手而不是基类方法 ──────────────────────────────────
## `PickableDomain extends Node3D`，而 `GodotComputeShaderBase extends RefCounted` ——
## 一个 GDScript 类不可能同时继承两者。本仓「Node 想用 RD 能力」的既有做法是**持有**
## （ScenePlacementActor 持有 ScenePlacementRuntime、SPASelectionHost 持有 VoxelPickGPU），
## 本类就是那个被持有的东西。它不自己 acquire 设备：设备获取策略是宿主的
## （SceneSV 用 ensure_device(true, **false**) 不许回退全局设备，TargetSV 用 (true, true)），
## 本类只断言宿主已经有设备。
##
## ── 收编了哪几处 ────────────────────────────────────────────────────────────
## 计划 §1.5 说「约 25 行 × 4 处」。实测只有 2 处是逐字同款、能整段吃掉：
##   * BrushSV  `scene_placement_runtime.gd  ensure_brush_sv_fields()`
##   * BlendSV  `scene_placement_runtime.gd  compose_blend_sv_fields()` 里的分配段
## 另两处形状不同，不在本轮：
##   * SceneSV（`scene_voxel_tile_store.gd`）的场对状态不在成员变量里，而是散在 7 张并列
##     Dictionary（buffers / byte_sizes / upload_byte_sizes / init_sources / record_counts /
##     strides / hashes），且碰撞场要用地形基底做**种子**而非零填充，还内嵌 5 段耗时打点。
##     接它需要「状态存放位置」与「初值来源」两个钩子，随 V3 劈开 tile store 时一起做。
##   * TargetSV（`target_scene_voxel_generator.gd`）**根本不同构**：那是一次性 pass 的入参
##     打包（SCOPE_FRAME、无复用、无独立释放、靠 _free_gpu→dispose 整体回收），且
##     「缺失通道只分配 4 字节」与 push constant 的门控 flag 强绑定。硬塞进来会把 pass 级
##     语义污染进域级 API。
##
## ── 顺手修掉的两个洞（不是无害重构，diff 里要显式说明）────────────────────
## 1. BlendSV 的旧守卫只检查 complexity RID、**不检查 collision RID**
##    （`scene_placement_runtime.gd` 原 :1410）。collision 失效而 complexity 仍有效且体素数
##    没变时，它会跳过重建并把无效 RID 送进 uniform set。本类按「**所有**场的 RID 都有效
##    且字节数都匹配」判命中，该情况改为重建。
## 2. BlendSV 与 TargetSV 都没有 `element_count > 0` 的前置校验。
##    `u32_field_byte_count(负数)` 返回 0，再经 `storage_buffer_zero` clamp 成 4 字节，
##    **全程不报任何错**——最后得到一对 4 字节的"场"。本类自带这道硬门。

## 计算基类：本类要 SCOPE_* 常量与三个分配口的类型。与 BufferDescriptor 不同，本类**就是**
## GPU 侧助手，preload 它不违反那边"不把 RenderingDevice 拖进来"的约束。
const ComputeBaseScript := preload("res://scripts/godot_compute_shader_base.gd")

## 初值来源。
##   ZERO          —— storage_buffer_zero：整块零填充。计数器 / 原子目标 / 部分写入必须用它。
##   UNINITIALIZED —— storage_buffer_uninitialized：不带 CPU 载荷，**仅**用于后续 GPU pass
##                    会在任何读取前完整覆盖的工作缓冲。用错的表现是读到上一次分配的残留。
const INIT_ZERO := "zero"
const INIT_UNINITIALIZED := "uninitialized"
const INITS := [INIT_ZERO, INIT_UNINITIALIZED]

## codec 是场 stride 的唯一事实源；这里只 re-export，不另写数值。
const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")

## 场对 schema v1（《AutoVolume 公用体积基类计划》§0）：complexity 与 collision 同一索引并列，
## 各占 4 字节。四个卷（SceneSV / TargetSV / BrushSV / BlendSV）共用这一份规格。
##
## ⚠ collision 的 stride 取 **u32 常驻/上传口径的 4**，不是 R8 磁盘/回读口径的 1。
## codec 里两个常量同名前缀（`COLLISION_FIELD_STRIDE_BYTES = 1` /
## `COLLISION_FIELD_U32_STRIDE_BYTES = 4`），拿错的表现是 buffer 小 4 倍且不报错。
const FIELD_COMPLEXITY := "complexity"
const FIELD_COLLISION := "collision"
const COMPLEXITY_STRIDE_BYTES := SceneVoxelTileCodecScript.SCENE_VOXEL_TILE_COMPLEXITY_FIELD_STRIDE_BYTES
const COLLISION_STRIDE_BYTES := SceneVoxelTileCodecScript.SCENE_VOXEL_TILE_COLLISION_FIELD_STRIDE_BYTES


## schema v1 场对的规格表。`label_prefix` 只影响 GPU 标签（进 track_rid 审计与错误信息），
## 不影响布局——四个卷的布局逐字相同，差别只有标签。
static func schema_v1_field_specs(label_prefix: String) -> Array:
	return [
		{
			"name": FIELD_COMPLEXITY,
			"stride_bytes": COMPLEXITY_STRIDE_BYTES,
			"label": "%s_complexity_rgba8" % label_prefix,
			"init": INIT_ZERO,
		},
		{
			"name": FIELD_COLLISION,
			"stride_bytes": COLLISION_STRIDE_BYTES,
			"label": "%s_collision_u32" % label_prefix,
			"init": INIT_ZERO,
		},
	]

var _owner: ComputeBaseScript = null
var _specs: Array[Dictionary] = []
var _scope := ComputeBaseScript.SCOPE_PERSISTENT
var _log_name := "VolumeFieldBuffers"

## name → RID / name → 已分配字节数。两张表的键集恒等于 _specs 的 name 集合。
var _rids: Dictionary = {}
var _byte_sizes: Dictionary = {}
var _element_count := 0

## 重建前（release 之前）的回调，允许宿主挂载自己的失效语义。
## BrushSV 就靠它：旧代码的重建前置是 `clear_brush_sv(true)`，那一句除释放外还会把
## `_brush_sv_has_content` 置 false 并在有内容时递增修订号——纯 free_rid 顶不掉这半段。
var _on_before_realloc := Callable()


## `field_specs` 每项：
##   name         : String  场名（"complexity" / "collision"），本域内唯一
##   stride_bytes : int     每元素字节数。⚠ collision 必须用 u32 口径的 4，不是 R8 口径的 1
##                          （codec 里 `COLLISION_FIELD_STRIDE_BYTES = 1` 是磁盘/回读口径，
##                          `COLLISION_FIELD_U32_STRIDE_BYTES = 4` 才是常驻/上传口径；
##                          两个同名前缀常量拿错的表现是 buffer 小 4 倍）
##   label        : String  GPU 标签（进 track_rid 的审计与错误信息）
##   init         : String  INIT_*，缺省 INIT_ZERO
func configure(
	owner: ComputeBaseScript,
	field_specs: Array,
	scope: String = ComputeBaseScript.SCOPE_PERSISTENT,
	log_name: String = "VolumeFieldBuffers"
) -> bool:
	_log_name = log_name
	_owner = owner
	_scope = scope
	var normalized: Array[Dictionary] = []
	var seen := {}
	for raw in field_specs:
		if not (raw is Dictionary):
			push_error("[%s] configure: field_specs 含非 Dictionary 条目（%s）—— 拒绝按半份规格分配。" % [
				_log_name, type_string(typeof(raw))])
			assert(false, "VolumeFieldBuffers.configure: spec entry is not a Dictionary")
			return false
		var spec: Dictionary = raw
		var field_name := str(spec.get("name", ""))
		var stride := int(spec.get("stride_bytes", 0))
		var init_mode := str(spec.get("init", INIT_ZERO))
		if field_name.is_empty() or seen.has(field_name):
			push_error("[%s] configure: 场名非法或重复（\"%s\"，已有 %s）—— 场名是 RID 表的键，重复即互相覆盖。" % [
				_log_name, field_name, str(seen.keys())])
			assert(false, "VolumeFieldBuffers.configure: empty or duplicate field name")
			return false
		if stride <= 0:
			push_error("[%s] configure: 场 \"%s\" 的 stride_bytes=%d 非正 —— 拒绝推一个默认值。" % [
				_log_name, field_name, stride])
			assert(false, "VolumeFieldBuffers.configure: non-positive stride")
			return false
		if not INITS.has(init_mode):
			push_error("[%s] configure: 场 \"%s\" 的 init=\"%s\" 不在 %s 内。" % [
				_log_name, field_name, init_mode, str(INITS)])
			assert(false, "VolumeFieldBuffers.configure: unknown init mode")
			return false
		seen[field_name] = true
		normalized.append({
			"name": field_name,
			"stride_bytes": stride,
			"label": str(spec.get("label", field_name)),
			"init": init_mode,
		})
	_specs = normalized
	return true


func set_before_realloc_hook(hook: Callable) -> void:
	_on_before_realloc = hook


## 确保场对存在且尺寸匹配 `element_count`。命中即直接返回（created=false），
## 否则先走重建前置钩子 + 释放，再逐场分配。
##
## 返回 `{ok, reason, created, element_count, buffers:{name: RID}, byte_sizes:{name: int}}`。
## 失败一律返回 `ok=false` **且已把本次分配出来的半份 RID 释放干净**——留半份比没有更糟：
## 后续 is_resident() 会说"在"，而实际只有一个场能读。
func ensure(element_count: int) -> Dictionary:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	if _owner == null:
		push_error("[%s] ensure: 未 configure（_owner 为 null）—— 场对无处分配。" % _log_name)
		assert(false, "VolumeFieldBuffers.ensure: not configured")
		return {"ok": false, "reason": "not_configured"}
	if _owner.get_rendering_device() == null:
		push_error("[%s] ensure: 宿主没有 RenderingDevice —— 场对无法创建，内容会被静默丢弃。" % _log_name)
		assert(false, "VolumeFieldBuffers.ensure: owner has no RenderingDevice")
		return {"ok": false, "reason": "no_rendering_device"}
	# ⚠ 这道门是新增的。旧的 BlendSV / TargetSV 路径没有它，而 u32_field_byte_count(负数)
	# 返回 0、storage_buffer_zero 再把 0 clamp 成 4 字节——全程零报错，最后拿到一对 4 字节的"场"。
	if element_count <= 0:
		push_error("[%s] ensure: element_count=%d 非正 —— 场对无法定尺寸，拒绝分配占位缓冲。" % [
			_log_name, element_count])
		assert(false, "VolumeFieldBuffers.ensure: non-positive element count")
		return {"ok": false, "reason": "non_positive_element_count"}
	if _specs.is_empty():
		push_error("[%s] ensure: 没有声明任何场（configure 的 field_specs 为空）。" % _log_name)
		assert(false, "VolumeFieldBuffers.ensure: no field specs")
		return {"ok": false, "reason": "no_field_specs"}

	if _is_current(element_count):
		return _summary(false, "ok")

	if _on_before_realloc.is_valid():
		_on_before_realloc.call()
	release()

	for spec in _specs:
		var field_name := str(spec["name"])
		var byte_count := element_count * int(spec["stride_bytes"])
		var label := str(spec["label"])
		var rid: RID = (
			_owner.storage_buffer_uninitialized(byte_count, _scope, label)
			if str(spec["init"]) == INIT_UNINITIALIZED
			else _owner.storage_buffer_zero(byte_count, _scope, label)
		)
		if not rid.is_valid():
			push_error("[%s] ensure: 场 \"%s\" 缓冲创建失败（element_count=%d, stride=%d, bytes=%d, label=%s, init=%s）—— 已释放本次分配出的其余场，不留半份。" % [
				_log_name, field_name, element_count, int(spec["stride_bytes"]),
				byte_count, label, str(spec["init"])])
			assert(false, "VolumeFieldBuffers.ensure: storage buffer creation failed")
			release()
			return {"ok": false, "reason": "storage_buffer_create_failed", "failed_field": field_name}
		_rids[field_name] = rid
		_byte_sizes[field_name] = byte_count
	_element_count = element_count
	return _summary(true, "ok")


## 命中判据：**所有**场的 RID 都有效、字节数都与目标匹配。
##
## ⚠ 旧的 BlendSV 守卫只看 complexity 一个 RID（collision 失效时会误命中并把无效 RID
## 送进 uniform set）。这里逐场检查是刻意的行为变更，不是顺手统一。
func _is_current(element_count: int) -> bool:
	if _element_count != element_count:
		return false
	for spec in _specs:
		var field_name := str(spec["name"])
		var rid: RID = _rids.get(field_name, RID())
		if not rid.is_valid():
			return false
		if int(_byte_sizes.get(field_name, -1)) != element_count * int(spec["stride_bytes"]):
			return false
	return true


func rid_of(field_name: String) -> RID:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	return _rids.get(field_name, RID())


func element_count() -> int:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	return _element_count


func is_resident() -> bool:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	return _element_count > 0 and _is_current(_element_count)


## 就地清零：内容归零但**保留 RID**（消费方缓存的 RID 不失效）。
##
## ⚠ 与 release() 是两件事。旧的 clear_brush_sv 把两者做成一个带 bool 参数的双模函数，
## 于是"清空笔刷"与"释放笔刷显存"共用一个入口、语义靠参数区分。这里拆开。
##
## ⚠ `buffer_zero` 返回 bool 且在 compute list 活动期间会硬失败。旧代码**吞掉**了这个返回值
## （scene_placement_runtime.gd 原 :1336-1339），表现是"清了但没清干净"且零提示。这里汇总上报。
func clear_in_place() -> Dictionary:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	if _owner == null:
		return {"ok": false, "reason": "not_configured", "cleared": 0}
	var cleared := 0
	var failed: Array[String] = []
	for spec in _specs:
		var field_name := str(spec["name"])
		var rid: RID = _rids.get(field_name, RID())
		if not rid.is_valid():
			continue
		if _owner.buffer_zero(rid, int(_byte_sizes.get(field_name, 0))):
			cleared += 1
		else:
			failed.append(field_name)
	if not failed.is_empty():
		push_error("[%s] clear_in_place: 场 %s 清零失败（其余 %d 个已清）—— 残留内容会继续参与合成与评分。" % [
			_log_name, str(failed), cleared])
		assert(false, "VolumeFieldBuffers.clear_in_place: buffer_zero failed")
		return {"ok": false, "reason": "buffer_zero_failed", "cleared": cleared, "failed_fields": failed}
	return {"ok": true, "reason": "ok", "cleared": cleared}


## 释放全部场并清空元数据。
##
## ⚠ `release_rid` 的第二参数传 `false`（禁用延迟）。四处旧释放路径全部这么写：
## 默认值 true 会在 compute list 活动期间把释放推迟到 end_compute_list()，改变既有时序。
func release() -> void:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	if _owner != null:
		for field_name in _rids.keys():
			var rid: RID = _rids[field_name]
			if rid.is_valid():
				_owner.release_rid(rid, false)
	_rids.clear()
	_byte_sizes.clear()
	_element_count = 0


func _summary(created: bool, reason: String) -> Dictionary:
	var buffers := {}
	var sizes := {}
	for spec in _specs:
		var field_name := str(spec["name"])
		buffers[field_name] = _rids.get(field_name, RID())
		sizes[field_name] = int(_byte_sizes.get(field_name, 0))
	return {
		"ok": true,
		"reason": reason,
		"created": created,
		"element_count": _element_count,
		"buffers": buffers,
		"byte_sizes": sizes,
	}


# ⚠ 编辑器软重载后的成员修复，别当成冗余判空删掉。依据与写法同 PickableDomain 的同名函数：
# 软重载只搬**重载前已存在**的成员，本次新增的槽是 nil；判空必须用 `is`（静态类型已知时
# `== null` 被编成恒 false）。
#
# ⚠ 语义连带：两张表任一丢失就意味着 RID 与字节数对不上了，**必须把 _element_count 一起清零**，
# 否则 _is_current() 会拿一个残缺的表判出"已就位"，宿主再也不会重建，而实际读到的是空 RID。
func _repair_soft_reloaded_members() -> void:
	var tables_lost := not (_rids is Dictionary) or not (_byte_sizes is Dictionary)
	if not (_rids is Dictionary): _rids = {}
	if not (_byte_sizes is Dictionary): _byte_sizes = {}
	if not (_element_count is int): _element_count = 0
	if not (_scope is String): _scope = ComputeBaseScript.SCOPE_PERSISTENT
	if not (_log_name is String): _log_name = "VolumeFieldBuffers"
	if not (_on_before_realloc is Callable): _on_before_realloc = Callable()
	if not (_specs is Array):
		var fresh: Array[Dictionary] = []
		_specs = fresh
	if tables_lost:
		_element_count = 0
