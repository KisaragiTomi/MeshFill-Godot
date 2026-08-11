@tool
class_name PlacedInstanceDisplay
extends Node3D

## 放置实例的场景侧显示器：把 `AutoObjectInstanceRenderer.instance_render[]` 的 GPU 字节
## 送进每批一个的 `MultiMeshInstance3D`。契约见《AutoObject实例GPU直提与点选交接计划.md》§5。
##
## **GDScript 在这条路径上永不解码 mat4、永不打包 float、永不按 profile_id 分组。**
## 它只做一次不透明的整块字节搬运——GPU 已经产出了最终的 MultiMesh 字节。
##
## 两条传输模式（R3 §6.1 的决策）：
##   b  emit 设备 == 主设备 ⇒ 直接绑 `multimesh_get_buffer_rd_rid`，零拷贝
##   a  否则一次 `PackedByteArray` 搬运（本仓当前必然走这条：SPA 的 RD 是
##      `ensure_device(prefer_local_device=true)` 拿到的**本地设备**，不是主设备）
## **(a) 是本设计的一种传输模式，不是本设计。**
##
## ⚠ 三个静默失败陷阱，每一个都不报错：
##
## 1. **`custom_aabb` 是强制的。** `_multimesh_allocate_data` 会重置 `aabb = AABB()`，
##    而 `_multimesh_get_aabb` 只从 CPU `data_cache` 重建——GPU/set_buffer 写入的 MultiMesh
##    从来没有那个缓存。没有 `custom_aabb` ⇒ 空 AABB ⇒ 全部被剔除，且无任何报错。
## 2. **一次误调 `set_instance_transform()` 会静默清零全部实例。** `_multimesh_make_local`
##    仅在 `buffer_set` 为真时从 `buffer_get_data` 重建 CPU 缓存，走 `memset` 归零分支之后
##    每帧把零覆盖到写入之上。本类因此**没有任何** `set_instance_*` 调用点，也不提供包装。
##    距离剔除由 emit kernel 的零基向量承担，不由 CPU 逐实例改写。
## 3. **`mm.instance_count = N` 会释放并重建底层 RD buffer**，使任何缓存的
##    `multimesh_get_buffer_rd_rid` 与引用它的 uniform set 失效。故容量按 `next_power_of_2`
##    增长、只增不减，容量变化时整批重建。
##
## CLAUDE.md 规则落点：放置物体必须渲染真实 `AssetDescriptor` 网格。
## `descriptor.get_mesh()` 为 null 时 `push_warning` 并**丢弃该批**——路径上不存在任何
## `BoxMesh` 回退。

const RENDER_FLOATS := 20        # 与 AutoObjectInstanceRenderer.RENDER_FLOATS 同源
const RENDER_STRIDE_BYTES := RENDER_FLOATS * 4

## batch_index → {node: MultiMeshInstance3D, multimesh: MultiMesh, capacity: int}
var _batches: Dictionary = {}
var _last_revision := -1
var _last_instances := 0
var _last_reason := "never_synced"
## batch_index → instance_start（emit 的 prefix 趟算出的批起点，见 batch_header）。
## 三角形 ID 拾取要把「第几个 MultiMesh 实例」映射回 `object_id`，而那条映射只能经
## `instance_pick[instance_start + local]` 走——MultiMesh 实例序与 object 序无对应关系
## （scatter 用 atomicAdd 抢槽位）。
var _batch_starts: Dictionary = {}
## 最近一次搬运用的 renderer（`AutoObjectInstanceRenderer`）。只用于点选解码时回读
## 单条 `instance_pick` 记录；显示路径不经过它。
var _renderer: RefCounted = null


func last_reason() -> String:
	if not (_last_reason is String):
		_last_reason = ""
	return _last_reason


## @tool 软重载保留旧成员、**新增成员回来是 nil**（CLAUDE.md / 项目记忆）。
## 点选侧的两个成员是后加的，每个公开入口先过一遍。
func _repair_pick_members() -> void:
	if not (_batch_starts is Dictionary):
		_batch_starts = {}
	if _renderer != null and not is_instance_valid(_renderer):
		_renderer = null


## 一步驱动：SPA 常驻对象池 → GPU emit → MultiMesh 字节。消费方只需调这一个入口，
## "怎么驱动 emit" 的知识不在两个宿主里各抄一份。
##
## `options` 除下列本层键外原样透传给 `AutoObjectInstanceRenderer.sync()`
## （`camera_position` / `cull_distance` / `camera_move_epsilon` / `default_color` / `force`）：
##   terrain_heights : PackedFloat32Array  给了就注入并要求 emit 在 kernel 内做地形 rebase
##   terrain_key     : String              内容 key；同 key 即空转不重传（缺省按内容自算）
##
## ⚠ 上传的 force 取自 emit 的 `emitted`，不能只看 `revision`：相机移动触发的重 emit
## 不改 `_object_revision`（对象集合没变），只看 revision 会让显示器空转，画面停在上一轮
## 的剔除结果上。
##
## 返回 `{ok, reason, emitted, revision, batches, instances}`。
func sync_from_spa(spa, options: Dictionary = {}) -> Dictionary:
	if spa == null or not spa.has_method("get_gpu_runtime"):
		_last_reason = "spa_unavailable"
		return {"ok": false, "reason": _last_reason, "emitted": false}
	var runtime = spa.get_gpu_runtime()
	if runtime == null or not runtime.has_method("get_instance_renderer"):
		_last_reason = "gpu_runtime_unavailable"
		return {"ok": false, "reason": _last_reason, "emitted": false}
	var renderer = runtime.get_instance_renderer()
	if renderer == null:
		_last_reason = "instance_renderer_unavailable"
		return {"ok": false, "reason": _last_reason, "emitted": false}

	var heights: PackedFloat32Array = options.get("terrain_heights", PackedFloat32Array())
	if not heights.is_empty():
		var resolution := int(round(sqrt(float(heights.size()))))
		var key := str(options.get("terrain_key", "auto:%d:%d" % [heights.size(), hash(heights)]))
		if not renderer.set_terrain_height_field(heights, resolution, key):
			# 注入失败就停手：继续 emit 会画出一批平 Y 的实例，与地形上的选择 marker
			# 差整个高度场——那是"看着合法、实际错位"的静默失败。
			_last_reason = "terrain_height_injection_failed"
			return {"ok": false, "reason": _last_reason, "emitted": false}

	var emit_options := options.duplicate()
	emit_options.erase("terrain_heights")
	emit_options.erase("terrain_key")
	emit_options["mesh_description_buffer"] = spa.get_mesh_description_buffer()
	emit_options["batch_count"] = spa.get_asset_count()
	emit_options["grid_origin"] = spa.grid_origin
	emit_options["voxel_size"] = spa.voxel_size
	var emit: Dictionary = renderer.sync(emit_options)
	if not bool(emit.get("ok", false)):
		_last_reason = "emit:%s" % str(emit.get("reason", "unknown"))
		return {"ok": false, "reason": _last_reason, "emitted": false}

	var force := bool(emit.get("emitted", false)) or bool(options.get("force", false))
	var uploaded: Dictionary = sync_from_renderer(renderer, spa.get_registered_descriptors(), force)
	uploaded["emitted"] = bool(emit.get("emitted", false))
	return uploaded


## 从 renderer 的 render handoff 拉一次实例字节。
##
## `descriptors` 下标 = `asset_index`（与 emit 的批下标同一套；SPA 的
## `get_registered_descriptors()` 就是这个序）。`renderer` 是 AutoObjectInstanceRenderer。
##
## 返回 `{ok, reason, revision, batches, instances}`。
## `ok=true 且 batches=0` 表示"没有可显示的批"，与失败区分开。
func sync_from_renderer(renderer: RefCounted, descriptors: Array, force: bool = false) -> Dictionary:
	if renderer == null:
		_last_reason = "renderer_null"
		return {"ok": false, "reason": _last_reason}
	var handoff: Dictionary = renderer.get_instance_render_handoff()
	if not bool(handoff.get("resident", false)):
		_last_reason = str(handoff.get("reason", "not_resident"))
		return {"ok": false, "reason": _last_reason}
	var revision := int(handoff.get("revision", -1))
	if not force and revision == _last_revision:
		# 空转也要如实报当前上传量：调用方（HUD / 报告）按 `instances` 读数，这里省略
		# 该键会让"没变化"看起来像"一个都没画"。
		return {
			"ok": true, "reason": "unchanged", "revision": revision,
			"batches": _batches.size(), "instances": _last_instances,
		}

	var headers: Array[Dictionary] = renderer.readback_batch_headers()
	if headers.is_empty():
		_last_reason = "no_batch_headers"
		return {"ok": false, "reason": _last_reason}
	_repair_pick_members()
	_renderer = renderer
	_batch_starts.clear()

	var rd: RenderingDevice = renderer.get_rendering_device()
	var render_rid: RID = handoff.get("instance_render_buffer", RID())
	if rd == null or not render_rid.is_valid():
		_last_reason = "render_buffer_unavailable"
		return {"ok": false, "reason": _last_reason}

	var total_instances := 0
	var live_batches := 0
	for batch_index in range(headers.size()):
		var header: Dictionary = headers[batch_index]
		var count := int(header.get("instance_count", 0))
		var start := int(header.get("instance_start", 0))
		if count <= 0:
			_release_batch(batch_index)
			continue
		var mesh := _mesh_for(descriptors, batch_index)
		if mesh == null:
			# CLAUDE.md：网格缺失即丢批，绝不用代理盒顶替。
			push_warning("[PlacedInstanceDisplay] asset_index=%d 没有可用 mesh —— 丢弃该批 %d 个实例，不使用代理盒回退。" % [
				batch_index, count])
			_release_batch(batch_index)
			continue
		var entry := _ensure_batch(batch_index, mesh, _material_for(descriptors, batch_index), count)
		if entry.is_empty():
			continue
		_batch_starts[batch_index] = start
		# 一次不透明的整块搬运：GPU 已产出最终 MultiMesh 字节，这里不解码任何一个 float。
		var bytes := rd.buffer_get_data(render_rid, start * RENDER_STRIDE_BYTES, count * RENDER_STRIDE_BYTES)
		if bytes.size() < count * RENDER_STRIDE_BYTES:
			push_error("[PlacedInstanceDisplay] asset_index=%d 的实例字节回读不足（期望 %d，实得 %d）—— 不部分写入。" % [
				batch_index, count * RENDER_STRIDE_BYTES, bytes.size()])
			assert(false, "PlacedInstanceDisplay.sync_from_renderer: short instance byte readback")
			continue
		var multimesh: MultiMesh = entry["multimesh"]
		# 容量大于本批实例数时，尾部槽位必须是零基向量（不可见）；emit 的 count pass
		# 已经把整块清过，但这里的搬运只覆盖 [start, start+count)，故尾部补零。
		var capacity := int(entry["capacity"])
		if capacity > count:
			var padded := bytes
			padded.resize(capacity * RENDER_STRIDE_BYTES)
			multimesh.set_buffer(padded.to_float32_array())
		else:
			multimesh.set_buffer(bytes.to_float32_array())
		# 可见数的**唯一权威赋值点**（R3 §7.8）。容量按 next_power_of_2 增长，尾部空槽的
		# 零基向量只塌掉片元、顶点着色器照付（实测 ~32 ns/可见实例/帧）——留 -1 等于每帧
		# 白跑 capacity-count 次顶点着色。`count` 正是刚搬进 [0, count) 的那一段。
		#
		# ⚠ 不影响拾取 ID：PickIdPass.prepare() 按 `instance_count`（= 容量）分配区间，是
		# 本段的超集；被截掉的尾部本就是画不出像素的零基向量（ID pass 的镜像共享同一个
		# MultiMesh，故那边也一并少光栅化这批 padding）。
		# ⚠ 必须每轮都赋、且在 set_buffer 之后：`instance_count` 一变就把它复位成 -1，
		# 而批复用路径（_ensure_batch 的早返回）根本不碰 multimesh。
		multimesh.visible_instance_count = count
		total_instances += count
		live_batches += 1

	_last_revision = revision
	_last_instances = total_instances
	_last_reason = "ok"
	return {
		"ok": true, "reason": "ok",
		"revision": revision,
		"batches": live_batches,
		"instances": total_instances,
	}


## 三角形 ID 拾取的 drawable 清单：每批一个 `MultiMeshInstance3D`。
##
## 契约见 `PickIdPass.prepare()`。`key` 就是 batch_index，`resolve_pick` 拿它反查
## `instance_start` —— 不把 `instance_start` 直接写进描述里，是因为两次 prepare 之间
## 可能夹着一次 emit（批起点随之变），描述里的快照会静默陈旧。
##
## ⚠ 这里报的实例数是 `multimesh.instance_count`（= 容量），不是本批存活数：
## `INSTANCE_ID` 的取值范围就是 `[0, instance_count)`，容量尾部的死槽位由 emit 写的
## 零基向量塌成退化三角形，本来就画不出像素，不需要也不能在 ID 区间上把它们排除掉。
## （ID 区间因此是**超集**：`visible_instance_count = 本批存活数` 让尾部连光栅化都不进，
## 但区间分配仍按容量走 —— 见 sync_from_renderer 里那条赋值。）
func get_pick_drawables() -> Array[Dictionary]:
	_repair_pick_members()
	var out: Array[Dictionary] = []
	for batch_index in _batches.keys():
		var entry: Dictionary = _batches[batch_index]
		var node: MultiMeshInstance3D = entry.get("node", null)
		if node == null or not is_instance_valid(node):
			continue
		out.append({
			"node": node,
			"source": self,
			"resolve_method": "resolve_pick",
			"key": int(batch_index),
		})
	return out


## 把「第 batch 批的第 local_index 个 MultiMesh 实例」解成 AutoObject 载荷。
##
## 链路：`slot = instance_start[batch] + local_index` → `instance_pick[slot]` 的
## `object_id`。**不能**用 local_index 直接当 object 序：scatter 趟是
## `slot = instance_start[b] + atomicAdd(cursor[b], 1)`，批内次序不确定。
##
## 返回 `{ok, reason, object_id, alive, batch_index, slot, profile_id, asset_index, voxel_min}`。
## 死槽位（`FLAG_ALIVE` 未置）也如实返回 `ok=false`：它本该画不出像素，
## 真读到了说明 ID 区间与实例缓冲对不上，静默当成未命中会把这个错误藏起来。
func resolve_pick(key, local_index: int) -> Dictionary:
	_repair_pick_members()
	var batch_index := int(key)
	if _renderer == null:
		return {"ok": false, "reason": "renderer_unavailable"}
	if not _batch_starts.has(batch_index):
		return {"ok": false, "reason": "batch_start_unknown", "batch_index": batch_index}
	if local_index < 0:
		return {"ok": false, "reason": "negative_local_index"}
	var slot := int(_batch_starts[batch_index]) + local_index
	var record: Dictionary = _renderer.readback_pick_record(slot)
	if record.is_empty():
		return {"ok": false, "reason": "pick_record_unreadable", "slot": slot,
			"batch_index": batch_index}
	# 槽位算术的自检：emit 在同一个 slot 上写渲染与点选两块记录，所以
	# `instance_pick[slot].batch_index` 必须等于我们据以算出这个 slot 的那一批。
	# 不等 = instance_start 陈旧或算错，而那种错的表现正是「点 A 选中 B」——
	# 解出来的仍是一个合法 object_id，从结果上完全看不出错。
	var record_batch := int(record.get("batch_index", -1))
	if record_batch != batch_index:
		push_error("[PlacedInstanceDisplay] pick 槽位串批：按 batch=%d 算出 slot=%d，但该槽位的记录属于 batch=%d —— instance_start 与 emit 不同步。" % [
			batch_index, slot, record_batch])
		assert(false, "PlacedInstanceDisplay.resolve_pick: slot belongs to another batch")
		return {"ok": false, "reason": "slot_batch_mismatch", "slot": slot,
			"batch_index": batch_index, "record_batch_index": record_batch}
	var flags := int(record.get("flags", 0))
	var alive := (flags & AutoObjectInstanceRenderer.FLAG_ALIVE) != 0
	return {
		"ok": alive,
		"reason": "ok" if alive else "instance_not_alive",
		"object_id": int(record.get("object_id", -1)),
		"alive": alive,
		"flags": flags,
		"batch_index": batch_index,
		"slot": slot,
		"profile_id": int(record.get("profile_id", -1)),
		"asset_index": int(record.get("asset_index", -1)),
		"voxel_min": record.get("voxel_min", Vector3i.ZERO),
	}


func get_status_report() -> Dictionary:
	var batches: Array[Dictionary] = []
	for batch_index in _batches.keys():
		var entry: Dictionary = _batches[batch_index]
		var multimesh: MultiMesh = entry.get("multimesh", null)
		batches.append({
			"asset_index": batch_index,
			"capacity": int(entry.get("capacity", 0)),
			"instance_count": multimesh.instance_count if multimesh != null else -1,
			"visible_instance_count": multimesh.visible_instance_count if multimesh != null else -1,
			"use_colors": multimesh.use_colors if multimesh != null else false,
			"use_custom_data": multimesh.use_custom_data if multimesh != null else false,
			"custom_aabb_volume": (entry.get("node", null) as MultiMeshInstance3D).custom_aabb.get_volume() \
				if entry.get("node", null) != null else 0.0,
		})
	return {
		"revision": _last_revision,
		"reason": last_reason(),
		"batch_count": _batches.size(),
		"batches": batches,
	}


static func _mesh_for(descriptors: Array, batch_index: int) -> Mesh:
	if batch_index < 0 or batch_index >= descriptors.size():
		return null
	var descriptor = descriptors[batch_index]
	if descriptor == null or not descriptor.has_method("get_mesh"):
		return null
	return descriptor.get_mesh() as Mesh


## descriptor 自带的实例化材质（`AssetDescriptor.material`）。没有就返回 null ——
## 由网格自己的 surface 材质出面，这里不塞任何默认材质。
static func _material_for(descriptors: Array, batch_index: int) -> Material:
	if batch_index < 0 or batch_index >= descriptors.size():
		return null
	var descriptor = descriptors[batch_index]
	if descriptor == null or not (descriptor is Resource) or not ("material" in descriptor):
		return null
	return descriptor.material as Material


## 容量按 next_power_of_2 增长、只增不减：`instance_count` 的每一次变化都会释放并重建
## 底层 RD buffer（陷阱 3），缩容省下的显存抵不上那次重建与随之失效的句柄。
func _ensure_batch(batch_index: int, mesh: Mesh, material: Material, count: int) -> Dictionary:
	var wanted := maxi(nearest_po2(maxi(count, 1)), 16)
	var entry: Dictionary = _batches.get(batch_index, {})
	if not entry.is_empty() and int(entry.get("capacity", 0)) >= wanted \
		and (entry.get("multimesh", null) as MultiMesh).mesh == mesh:
		_apply_material(entry, material)
		_apply_custom_aabb(entry, mesh, wanted)
		return entry

	_release_batch(batch_index)
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	# ⚠ 两个开关都必须开：关掉任一个会把 stride 从 20 float 变成 16 或 12，
	# GPU 写出的 80 B 记录会整体错位——且不报错，只是画出一堆乱七八糟的变换。
	multimesh.use_colors = true
	multimesh.use_custom_data = true
	multimesh.mesh = mesh
	multimesh.instance_count = wanted
	# 建批时的保守初值：此刻还没搬过任何字节，缓冲整块是零，画什么都是空。真正的可见数
	# 由 sync_from_renderer 在每次 set_buffer 之后按本批 instance_count 赋（R3 §7.8）——
	# 「剔除靠零基向量隐藏所以可见数永远可以是 -1」对正确性成立、对开销不成立。
	multimesh.visible_instance_count = -1

	var node := MultiMeshInstance3D.new()
	node.name = "PlacedBatch%d" % batch_index
	node.multimesh = multimesh
	add_child(node)
	if Engine.is_editor_hint() and get_tree() != null and get_tree().edited_scene_root != null:
		node.owner = get_tree().edited_scene_root

	entry = {"node": node, "multimesh": multimesh, "capacity": wanted}
	_batches[batch_index] = entry
	_apply_material(entry, material)
	_apply_custom_aabb(entry, mesh, wanted)
	return entry


func _apply_material(entry: Dictionary, material: Material) -> void:
	var node: MultiMeshInstance3D = entry.get("node", null)
	if node != null:
		node.material_override = material


## `custom_aabb` 用**保守解析包围盒**，不做 GPU 归约、不回读实例位置：
## 放置实例都落在 SPA 网格里，故网格世界范围外扩一个最大 mesh AABB 尺寸即可覆盖。
## 保守过头只是少剔除一点；漏了它则是**全部**被剔除且无任何报错（陷阱 1）。
func _apply_custom_aabb(entry: Dictionary, mesh: Mesh, _capacity: int) -> void:
	var node: MultiMeshInstance3D = entry.get("node", null)
	var multimesh: MultiMesh = entry.get("multimesh", null)
	if node == null or mesh == null:
		return
	var mesh_aabb := mesh.get_aabb()
	var span := maxf(mesh_aabb.size.length(), 1.0)
	var world := AABB(Vector3(-2048.0, -512.0, -2048.0), Vector3(4096.0, 1024.0, 4096.0))
	var conservative := world.grow(span)
	node.custom_aabb = conservative
	if multimesh != null:
		multimesh.custom_aabb = conservative


func _release_batch(batch_index: int) -> void:
	_repair_pick_members()
	# 批起点与批同生共死：留着一个已释放批的 instance_start，下一次点选就会拿它去
	# 读一块与本批无关的 instance_pick 记录，解出另一个合法 object_id（点 A 选中 B）。
	_batch_starts.erase(batch_index)
	var entry: Dictionary = _batches.get(batch_index, {})
	if entry.is_empty():
		return
	var node: Node = entry.get("node", null)
	if node != null and is_instance_valid(node):
		node.queue_free()
	_batches.erase(batch_index)


