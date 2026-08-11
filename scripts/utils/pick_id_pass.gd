@tool
class_name PickIdPass
extends Node

## 三角形 ID 拾取的渲染半边：把「正在画的那份几何 + 那份实例变换」再画一遍到一张 ID 目标，
## 片元写 `pick_id`，回读点击处一个像素，读到谁就选中谁。
## 上位设计见《点选重构-可视化即拾取几何.md》。
##
## ── 为什么是「镜像节点 + own_world_3d 的 SubViewport」，而不是换 material_override ──
##
## 换 `material_override` 要在同一帧内改材质 → 逼一次绘制 → 改回来，而绘制在帧尾异步发生，
## 中间任何一帧被用户看到就是满屏乱码。镜像节点**共享同一个 `MultiMesh` 资源**
## （因而共享同一块 RD 实例缓冲：三个 writer 都走 `multimesh_get_buffer_rd_rid` 直写），
## 所以「再画一遍」画的确实是同一份实例变换，且原节点全程不动。
##
## `own_world_3d = true` 而不是 cull_mask 隔离：镜像若与真节点同处一个 World3D，编辑器相机
## 的 cull_mask 默认是全 20 层，会把 ID 材质的镜像叠画在视口里。独立 World3D 是物理隔离，
## 不依赖任何一方的 cull_mask 设置正确。
##
## ⚠ **本类不做增量重绘。** `begin_pass()` 每趟把 `_next_pick_id` 归 1、清空解码表，
## 区间当场重分配。ID 因此**不跨趟存活**，也就不需要空闲链表/代际号
## （理由见《pick_id载体方案对比.md》§5.1：笔刷每次落笔都重建显示节点——今天是
## `BrushSVVolume.rebuild_display()`，2026-08-10 前是 addon 的 `flush_brush()`——
## 单调递增计数器在一个作画会话内就能撞穿 24 位）。

## 24 位上限。`transparent_bg` 保持关闭（已定案）⇒ 回读 Image 是 RGB8，没有 alpha 通道。
const PICK_ID_MAX := 0xFFFFFF
## 0 保留为「无命中」：ID 目标清成黑色即空，故分配从 1 起。
const PICK_ID_NONE := 0
const SHADER_PATH := "res://shaders/pick_id.gdshader"
const VIEWPORT_NODE_NAME := "PickIdViewport"
const CAMERA_NODE_NAME := "PickIdCamera"
const MIRROR_ROOT_NAME := "PickIdMirrors"
## prepare() 之后至少要画过这么多帧，回读到的才保证是本次位姿画出来的。
## 少于它就回读 = 读到上一次位姿的图，解出来是一组「看着合法、实际全错」的 ID。
##
## 为什么是 1 而不是更大：`Main::iteration()` 是「先跑 idle（prepare 在这里改完相机与
## 材质并采样 `_prepared_frame`）→ 再 `RenderingServer::draw()` → 才
## `increment_frames_drawn()`」。所以计数一旦 +1，那次绘制就必定已经包含本次 prepare 的
## 全部改动。⚠ 也**不能**要求更大：编辑器只在有变更时才绘制
## （`Main::iteration` 的 `RenderingServer::has_changed()` 门），空闲时计数就停在 1，
## 要求 2 会把「已经画好了」误判成「还没画」，然后一直等下去。
const MIN_FRAMES_BEFORE_READBACK := 1

var _next_pick_id := 1
## 解码表：每项 {base, count, domain, source, resolve_method, key, node_path}。
## 与分配同生共死（begin_pass 一起清）。
var _ranges: Array[Dictionary] = []

var _viewport: SubViewport = null
var _camera: Camera3D = null
var _mirror_root: Node3D = null
var _mirrors: Array[MultiMeshInstance3D] = []
var _shader: Shader = null

var _prepared := false
var _prepared_frame := -1
var _image: Image = null
var _last_prepare: Dictionary = {}
## 只服务 measure_readback_shape()：由**渲染线程**写入、主线程在 force_draw 之后读
## （force_draw 是同步 push，返回时那条回调必已跑完 ⇒ 读得到）。不参与任何生产判定。
var _rt_sync_us: Array[int] = []
var _rt_async_us: Array[int] = []
var _rt_bytes := 0
var _rt_error := ""
## 只服务 measure_async_latency()。⚠ `_async_fired` 由**渲染线程**置位、主线程轮询读；
## 这是本文件唯一的跨线程握手，别把它推广到生产路径（见该方法的线程约束说明）。
var _async_fired := false
var _async_arrive_us := 0
var _async_arrive_frame := -1
var _async_issue_us := 0
var _async_issue_err := 0
var _async_thread_id := 0
var _async_data := PackedByteArray()
var _async_sync_data := PackedByteArray()


## @tool 软重载会保留旧成员的值，但**新增成员回来是 nil**（CLAUDE.md / 项目记忆）。
## 每个公开入口先过一遍，避免在 nil 上做算术或调方法。
func _repair_members() -> void:
	if not (_next_pick_id is int): _next_pick_id = 1
	if not (_ranges is Array): _ranges = []
	if not (_mirrors is Array): _mirrors = []
	if not (_prepared is bool): _prepared = false
	if not (_prepared_frame is int): _prepared_frame = -1
	if not (_last_prepare is Dictionary): _last_prepare = {}
	if not (_rt_sync_us is Array): _rt_sync_us = []
	if not (_rt_async_us is Array): _rt_async_us = []
	if not (_rt_bytes is int): _rt_bytes = 0
	if not (_rt_error is String): _rt_error = ""
	if not (_async_fired is bool): _async_fired = false
	if not (_async_arrive_us is int): _async_arrive_us = 0
	if not (_async_arrive_frame is int): _async_arrive_frame = -1
	if not (_async_issue_us is int): _async_issue_us = 0
	if not (_async_issue_err is int): _async_issue_err = 0
	if not (_async_thread_id is int): _async_thread_id = 0
	if not (_async_data is PackedByteArray): _async_data = PackedByteArray()
	if not (_async_sync_data is PackedByteArray): _async_sync_data = PackedByteArray()


# ---- ID 区间分配 -------------------------------------------------------------

## 每趟 ID pass 开始时调用。ID 只在本趟内有意义：回读紧跟在同一趟之后。
##
## `base_offset` 只服务编解码实测：把整趟 ID 抬到高位（如 0xAB0000）后重跑同一批样本，
## 若 24 位里任何一个字节在 GPU 往返中被改写，解出的对象就会与偏移前不同。
## 生产路径恒传 0。
func begin_pass(base_offset: int = 0) -> void:
	_repair_members()
	_next_pick_id = 1 + maxi(base_offset, 0)
	_ranges.clear()


## 为一个 drawable 申请一段连续 ID 区间，返回基址；溢出 **硬失败**（返回 -1）。
##
## ⚠ 绝不截断。截断后的 ID 会指向另一个合法对象，表现为「点 A 选中 B」——
## 本项目最难查的那类缺陷。上限是设计容量，撞上就必须当场知道。
func allocate_pick_id_range(count: int) -> int:
	_repair_members()
	if count <= 0:
		push_error("[PickId] allocate_pick_id_range: count=%d 非正 —— 空 drawable 不该进 ID pass。" % count)
		assert(false, "PickIdPass.allocate_pick_id_range: non-positive count")
		return -1
	var base := _next_pick_id
	if base + count > PICK_ID_MAX:
		push_error("[PickId] pick_id 溢出 24 位预算：base=%d count=%d 上限=%d —— 拒绝截断。" % [
			base, count, PICK_ID_MAX])
		assert(false, "pick_id range exceeds 24-bit budget")
		return -1
	_next_pick_id += count
	return base


## 下一个待分配的 ID（诊断用）。带 base_offset 时它不等于"已分配个数"，
## 所以按"游标"而不是"计数"命名——把两者混为一谈正是解码表对不上时最难查的那一步。
func next_pick_id() -> int:
	_repair_members()
	return _next_pick_id


# ---- 编解码（静态，可单测） ---------------------------------------------------

## 24 位 → 三个 8 位码值。与 `shaders/pick_id.gdshader` 的 vertex() 同规则。
static func encode_rgb8(pick_id: int) -> Vector3i:
	return Vector3i((pick_id >> 16) & 0xFF, (pick_id >> 8) & 0xFF, pick_id & 0xFF)


## 三个 8 位码值 → 24 位。encode_rgb8 的逆。
static func decode_rgb8(r: int, g: int, b: int) -> int:
	return ((r & 0xFF) << 16) | ((g & 0xFF) << 8) | (b & 0xFF)


## 回读像素 → 8 位码值。RGB8 的 get_pixel() 返回 byte/255.0，故乘回去再取整是精确的。
static func color_to_rgb8(c: Color) -> Vector3i:
	return Vector3i(
		int(round(clampf(c.r, 0.0, 1.0) * 255.0)),
		int(round(clampf(c.g, 0.0, 1.0) * 255.0)),
		int(round(clampf(c.b, 0.0, 1.0) * 255.0)))


# ---- pass 建立 ---------------------------------------------------------------

## 按给定相机位姿建立一趟 ID pass。
##
## `drawables` 每项：
##   node            : MultiMeshInstance3D  正在被画的那个节点（几何与实例缓冲的来源）
##   domain          : String               SPAEditorContract.SELECTION_DOMAIN_*
##   source          : Object               能把 (key, local_index) 解成载荷的对象
##   resolve_method  : String               source 上的方法名，签名 (key, local_index) -> Dictionary
##   key             : Variant              原样回传给 resolve_method 的不透明键
##
## **画不出来的不进 pass**：`is_visible_in_tree()` 为假的一律跳过——这就是
## 「看不到就不会被选中」的物理保证，不再需要任何一层准入判定。
func prepare(cam: Camera3D, viewport_size: Vector2i, drawables: Array,
		id_base_offset: int = 0) -> Dictionary:
	_repair_members()
	if cam == null:
		return {"ok": false, "reason": "missing_camera"}
	if not _ensure_nodes():
		return {"ok": false, "reason": "pick_id_nodes_unavailable"}

	begin_pass(id_base_offset)
	_image = null
	_prepared = false

	var size := Vector2i(maxi(viewport_size.x, 1), maxi(viewport_size.y, 1))
	_viewport.size = size
	_copy_camera(cam)

	var used := 0
	var skipped: Array[String] = []
	for entry in drawables:
		if not (entry is Dictionary):
			push_error("[PickId] drawable 描述必须是 Dictionary，实得 %s。" % type_string(typeof(entry)))
			assert(false, "PickIdPass.prepare: drawable entry is not a Dictionary")
			return {"ok": false, "reason": "bad_drawable_entry"}
		var desc: Dictionary = entry
		var node = desc.get("node", null)
		if node == null or not is_instance_valid(node) or not (node is MultiMeshInstance3D):
			skipped.append("not_multimesh_instance")
			continue
		var mmi := node as MultiMeshInstance3D
		if not mmi.is_inside_tree() or not mmi.is_visible_in_tree():
			skipped.append("%s:invisible" % mmi.name)
			continue
		var mm := mmi.multimesh
		if mm == null or mm.mesh == null or mm.instance_count <= 0:
			skipped.append("%s:no_geometry" % mmi.name)
			continue
		var count := mm.instance_count
		var base := allocate_pick_id_range(count)
		if base < 0:
			return {"ok": false, "reason": "pick_id_overflow"}
		var mirror := _ensure_mirror(used)
		if mirror == null:
			return {"ok": false, "reason": "mirror_unavailable"}
		_bind_mirror(mirror, mmi, mm, base)
		_ranges.append({
			"base": base,
			"count": count,
			"domain": str(desc.get("domain", "")),
			"source": desc.get("source", null),
			"resolve_method": str(desc.get("resolve_method", "")),
			"key": desc.get("key", null),
			"node_path": str(mmi.get_path()) if mmi.is_inside_tree() else str(mmi.name),
		})
		used += 1

	_park_unused_mirrors(used)
	# UPDATE_ALWAYS 而不是 UPDATE_ONCE：ONCE 会在下一次绘制后自动回到 DISABLED，
	# 而「下一次绘制」发生在哪一帧不由这里决定，帧计数守卫就没有可等的目标了。
	# resolve() 取到图之后立刻停更（见 _fetch_image），不会长期占着 GPU。
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_prepared = true
	_prepared_frame = Engine.get_frames_drawn()
	_last_prepare = {
		"ok": true,
		"drawables": used,
		"skipped": skipped,
		"next_pick_id": next_pick_id(),
		"viewport": [size.x, size.y],
		"prepared_frame": _prepared_frame,
	}
	return _last_prepare.duplicate(true)


func last_prepare() -> Dictionary:
	_repair_members()
	return _last_prepare.duplicate(true)


## prepare() 以来画过的帧数。**不报错的就绪查询**：调用方（桥探针 / 生产路径）用它等到
## ID 目标真被画出来再回读，而不是撞上 _fetch_image 的硬失败——那条守卫是安全网，
## 不是正常流程里的等待手段。-1 = 还没 prepare 过。
func frames_since_prepare() -> int:
	_repair_members()
	if not _prepared:
		return -1
	return Engine.get_frames_drawn() - _prepared_frame


## 回读一个像素并解码。prepare() 之后帧数不够就**判死**，绝不返回一个陈旧帧的结果。
##
## 这条走的是「等主循环把 ID 目标画出来」——桥探针用它（两次桥调用之间自然经过若干帧）。
## 生产点击路径用 [method draw_and_resolve]：那里由本进程当场逼出那一帧。
func resolve(screen: Vector2) -> Dictionary:
	_repair_members()
	if not _prepared:
		return {"ok": false, "reason": "not_prepared"}
	var img := _fetch_image()
	if img == null:
		return {"ok": false, "reason": "no_image"}
	return _decode_pixel(img, screen)


## 生产点击路径（**方案 c**，用户裁决）：当场 `force_draw` 逼出这一趟 ID 图，紧接着同步回读。
##
## ⚠ **不能**复用 [method resolve] 的帧数守卫：`RenderingServer.force_draw()` 不递增
## `Engine.get_frames_drawn()` —— 全引擎唯一的递增点是 `Main::iteration()` 里紧跟
## `RenderingServer::draw()` 的那一句（`main.cpp:4956` / `:4962`，本机 4.6.1 实读）。
## 所以在这条路上 `frames_since_prepare()` 恒为 0，`_fetch_image()` 的守卫必然把
## 「刚画完」误判成「还没画」并硬失败。那条守卫要防的是「读到上一次位姿的图」，
## 而这里那次绘制是本函数自己发出的、就在同一个调用栈里没有返回过主循环
## ⇒ 同一个安全性质由调用顺序直接保证，不需要帧计数当代理。
##
## 实测代价（《点选重构-可视化即拾取几何.md》§3.5.6 / §3.5.7）：主线程同步阻塞 ≈27.4 ms，
## 其中 ≈10.7 ms 是编辑器那一帧本来就要跑的 GPU 时间、≈10.0 ms 是 ID pass 自己的、
## ≈1.9 ms 是像素传输、≈0.1 ms 固定往返。用户已裁决用这个阻塞换「点下去当帧就高亮」。
##
## 返回值是 [method resolve] 的超集，另带 `force_draw_us` / `readback_us` / `click_us`
## 三个墙钟（微秒）——生产路径上留着它们，是为了「变慢了」这件事能被当场看见，
## 而不是靠事后重新搭一套仪器。
func draw_and_resolve(screen: Vector2) -> Dictionary:
	_repair_members()
	if not _prepared:
		return {"ok": false, "reason": "not_prepared"}
	if _viewport == null or not is_instance_valid(_viewport):
		return {"ok": false, "reason": "no_viewport"}
	# 这一趟的图必须是新画的：留着上一次点击的缓存就是「点 A 选中上一次的 B」。
	_image = null
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var t0 := Time.get_ticks_usec()
	RenderingServer.force_draw(false)
	var t_drawn := Time.get_ticks_usec()
	var tex := _viewport.get_texture()
	var img := tex.get_image() if tex != null else null
	var t_read := Time.get_ticks_usec()
	# 画完就停更：常驻 pass 每帧要 ≈10 ms GPU（§3.5.6），方案 c 的前提就是不付这笔。
	stop_updating()
	if img == null:
		push_error("[PickId] force_draw 之后 SubViewport 仍拿不到图像 —— ID pass 的渲染目标没有建立。")
		assert(false, "PickIdPass.draw_and_resolve: no image after force_draw")
		return {"ok": false, "reason": "no_image", "force_draw_us": t_drawn - t0}
	_image = img
	var out := _decode_pixel(img, screen)
	out["force_draw_us"] = t_drawn - t0
	out["readback_us"] = t_read - t_drawn
	out["click_us"] = Time.get_ticks_usec() - t0
	return out


## 解码半边：一张已经到手的 ID 图 + 一个屏幕坐标 → `{pick_id, domain, local_index, payload}`。
## [method resolve]（等主循环画）与 [method draw_and_resolve]（当场逼一帧）共用它——
## 两处各写一遍解码就是又一份"第二表示"，而它错开的表现同样是"点 A 选中 B"。
func _decode_pixel(img: Image, screen: Vector2) -> Dictionary:
	var x := int(floor(screen.x))
	var y := int(floor(screen.y))
	if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
		return {"ok": false, "reason": "screen_out_of_bounds",
			"screen": [screen.x, screen.y], "image": [img.get_width(), img.get_height()]}
	var rgb := color_to_rgb8(img.get_pixel(x, y))
	var pick_id := decode_rgb8(rgb.x, rgb.y, rgb.z)
	var out := {
		"ok": true,
		"pick_id": pick_id,
		"rgb8": [rgb.x, rgb.y, rgb.z],
		"screen": [x, y],
	}
	if pick_id == PICK_ID_NONE:
		out["hit"] = false
		out["reason"] = "no_hit"
		return out
	var range_entry := _range_for(pick_id)
	if range_entry.is_empty():
		# 解不出区间 = 分配表与画出来的东西对不上，是本管线自身坏了。
		# 静默当成未命中会把一个坏掉的 pass 伪装成「这里没东西」。
		push_error("[PickId] pick_id=%d 落在任何已分配区间之外（本趟游标到 %d，区间数 %d）—— ID pass 与分配表不同步。" % [
			pick_id, next_pick_id(), _ranges.size()])
		assert(false, "PickIdPass.resolve: pick_id outside every allocated range")
		out["hit"] = false
		out["reason"] = "pick_id_unmapped"
		return out
	out["hit"] = true
	out["domain"] = str(range_entry.get("domain", ""))
	out["local_index"] = pick_id - int(range_entry.get("base", 0))
	out["range_base"] = int(range_entry.get("base", 0))
	out["node_path"] = str(range_entry.get("node_path", ""))
	var source = range_entry.get("source", null)
	var method := str(range_entry.get("resolve_method", ""))
	if source == null or not is_instance_valid(source) or method.is_empty() \
			or not source.has_method(method):
		push_error("[PickId] 区间 base=%d 没有可用的载荷解码口（source=%s method=\"%s\"）—— 命中无法映射回选择记录。" % [
			int(range_entry.get("base", 0)), str(source), method])
		assert(false, "PickIdPass.resolve: range has no payload resolver")
		out["reason"] = "no_payload_resolver"
		return out
	# 载荷生产者一并带出：载荷只回答「哪个域的哪个元素」（PickableDomain.resolve_pick 的
	# 统一形状），坐标 / 覆盖范围 / 绘制属性由消费方**问这个节点自己的成员**要
	# （`element_to_voxel()` / `voxel_range_of()` / …）。不带它，消费方就得按域名再查一遍节点。
	out["source"] = source
	var payload = source.call(method, range_entry.get("key", null), out["local_index"])
	out["payload"] = payload if payload is Dictionary else {}
	return out


## 整张 ID 目标的统计（诊断）。**这是「逐位核对」的全局那一半**：
## 若三个通道里任何一个在 GPU 往返中被改写（sRGB 没抵消干净、被 MSAA 插值、被 debanding
## 加噪），绝大多数非零像素解出的 pick_id 就会落到已分配区间之外 —— `unmapped` 会立刻变大。
## 逐样本那一半由 resolve() 的真实命中 + 与旧路同解承担。
##
## `stride` 为采样步长（1 = 全扫）。默认 3：1440×900 全扫是 130 万次 get_pixel，
## GDScript 上要好几秒，而统计量对步长不敏感。
func image_stats(stride: int = 3) -> Dictionary:
	_repair_members()
	var img := _fetch_image()
	if img == null:
		return {"ok": false, "reason": "no_image"}
	var step := maxi(stride, 1)
	var seen := {}
	var non_zero := 0
	var unmapped := 0
	var sampled := 0
	var min_id := PICK_ID_MAX + 1
	var max_id := 0
	for y in range(0, img.get_height(), step):
		for x in range(0, img.get_width(), step):
			sampled += 1
			var rgb := color_to_rgb8(img.get_pixel(x, y))
			var pick_id := decode_rgb8(rgb.x, rgb.y, rgb.z)
			if pick_id == PICK_ID_NONE:
				continue
			non_zero += 1
			min_id = mini(min_id, pick_id)
			max_id = maxi(max_id, pick_id)
			if not seen.has(pick_id):
				seen[pick_id] = 0
				if _range_for(pick_id).is_empty():
					unmapped += 1
			seen[pick_id] += 1
	return {
		"ok": true,
		"stride": step,
		"sampled": sampled,
		"non_zero": non_zero,
		"distinct_ids": seen.size(),
		"unmapped_ids": unmapped,
		"min_id": min_id if non_zero > 0 else 0,
		"max_id": max_id,
		"image": [img.get_width(), img.get_height()],
	}


## 在 ID 目标里挑出若干**确有命中**的屏幕坐标（诊断/验收用）。
##
## 为什么需要它：均匀网格采样在这个场景里 160 个点只落到 8 个物体像素上——不是管线不对，
## 是 2000 多个物体在这个视距下每个只占几个像素。用真实命中点做对比样本，
## 比"加密网格碰运气"更能构成证据，也避免把「点在空隙上」的刻意差异混进一致性统计。
##
## 返回 `[[x, y], ...]`，每个 pick_id 最多取一个点（尽量覆盖不同对象）。
func sample_hit_pixels(max_samples: int = 64, stride: int = 3) -> Array:
	_repair_members()
	var img := _fetch_image()
	if img == null:
		return []
	var step := maxi(stride, 1)
	var seen := {}
	var out: Array = []
	for y in range(0, img.get_height(), step):
		for x in range(0, img.get_width(), step):
			var rgb := color_to_rgb8(img.get_pixel(x, y))
			var pick_id := decode_rgb8(rgb.x, rgb.y, rgb.z)
			if pick_id == PICK_ID_NONE or seen.has(pick_id):
				continue
			seen[pick_id] = true
			out.append([x, y])
			if out.size() >= max_samples:
				return out
	return out


## 把 ID 目标原样存成 PNG（诊断）。**存的是原始码值**，不做任何可读性增强——
## 加了增强就看不出"这张图到底是不是解码依据"了。ID 都很小，所以肉眼看几乎是纯黑，
## 用途是核对**轮廓**：ID pass 画出来的形状/位置必须和编辑器视口里看到的一致。
func save_image(path: String) -> Dictionary:
	_repair_members()
	var img := _fetch_image()
	if img == null:
		return {"ok": false, "reason": "no_image"}
	var err := img.save_png(path)
	if err != OK:
		return {"ok": false, "reason": "save_png_failed", "error": int(err), "path": path}
	return {"ok": true, "path": path, "size": [img.get_width(), img.get_height()]}


## 同上，但把 pick_id 映射成人眼可分辨的伪彩（诊断**看图**用，绝不参与解码）。
## 三个通道各取 id 的不同位段再散列，相邻 id 也会明显不同色。
func save_image_false_color(path: String) -> Dictionary:
	_repair_members()
	var img := _fetch_image()
	if img == null:
		return {"ok": false, "reason": "no_image"}
	var out := Image.create_empty(img.get_width(), img.get_height(), false, Image.FORMAT_RGB8)
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			var rgb := color_to_rgb8(img.get_pixel(x, y))
			var pick_id := decode_rgb8(rgb.x, rgb.y, rgb.z)
			if pick_id == PICK_ID_NONE:
				out.set_pixel(x, y, Color.BLACK)
				continue
			var h := hash(pick_id)
			out.set_pixel(x, y, Color(
				float((h >> 16) & 0xFF) / 255.0,
				float((h >> 8) & 0xFF) / 255.0,
				float(h & 0xFF) / 255.0))
	var err := out.save_png(path)
	if err != OK:
		return {"ok": false, "reason": "save_png_failed", "error": int(err), "path": path}
	return {"ok": true, "path": path, "size": [out.get_width(), out.get_height()]}


## 逐 drawable 采样：保证 pass 里**每一个** drawable 都被真实命中样本覆盖到。
##
## ⚠ 为什么不能只用 sample_hit_pixels：它按扫描序全局去重，实例最多的那个 drawable
## 会把名额占满（45,598 个锚点小球一扫就满），于是像"胜出 mesh 的实例序 → anchor_index"
## 这种**最容易写错**的映射一次都没被采到——而"没验到"与"验过了"在统计口径上长得一模一样。
## 这正是本项目那条"空对空被误当成通过"教训的另一种形态。
##
## 返回 `[[x, y], ...]`，每个 drawable 最多 `max_per_drawable` 个点（各自 pick_id 不同）。
func sample_hit_pixels_per_drawable(max_per_drawable: int = 12, stride: int = 2) -> Array:
	_repair_members()
	var img := _fetch_image()
	if img == null:
		return []
	var step := maxi(stride, 1)
	var seen := {}
	var per_range := {}
	var out: Array = []
	for y in range(0, img.get_height(), step):
		for x in range(0, img.get_width(), step):
			var rgb := color_to_rgb8(img.get_pixel(x, y))
			var pick_id := decode_rgb8(rgb.x, rgb.y, rgb.z)
			if pick_id == PICK_ID_NONE or seen.has(pick_id):
				continue
			var entry := _range_for(pick_id)
			if entry.is_empty():
				continue
			var base := int(entry.get("base", 0))
			var taken := int(per_range.get(base, 0))
			if taken >= max_per_drawable:
				continue
			seen[pick_id] = true
			per_range[base] = taken + 1
			out.append([x, y])
	return out


## 本趟每个 drawable 的区间概览（诊断）：让"哪个 drawable 一个样本都没采到"看得见。
func range_report() -> Array:
	_repair_members()
	var out: Array = []
	for entry in _ranges:
		out.append({
			"base": int(entry.get("base", 0)),
			"count": int(entry.get("count", 0)),
			"domain": str(entry.get("domain", "")),
			"node": str(entry.get("node_path", "")).get_file(),
		})
	return out


## 实测「生产切换」三条路线的墙钟代价（诊断，不参与任何判定）。
##
## 背景：ID pass 的回读天然晚一帧（prepare → 绘制 → 回读），而生产点击路径是同步返回的。
## 三条候选路线里有两条可以当场量出来：
##   c 点击时强制绘制再回读 —— `RenderingServer.force_draw()` + 一次 get_image()。
##     UE 的 hit proxy 就是这条：`FViewport::GetHitProxy` 在 `bHitProxiesCached` 为假时
##     当场渲染再回读（`UnrealClient.cpp`）。
##   b 常驻 ID pass —— 每帧多画一遍，点击时读上一帧。代价 = 开着 pass 与关掉 pass
##     的每帧绘制耗时之差。
## a（延后一帧交付选中）不在这里量：它的代价是交互语义，不是时间。
##
## ⚠ `force_draw` 从 idle 回调里调用是引擎自己也在用的形态（编辑器进度条即如此），
## 但它会**同步跑完整帧**；这里默认 `swap_buffers = false`，不去动屏幕缓冲。
##
## ⚠ **本方法量到的 `force_draw_us` 与 `readback_us` 不是两笔独立开销。**
## `force_draw` 只是录制并提交（CPU 侧 1.0–1.5 ms），它触发的 GPU 执行是在随后
## `readback_us` 的 stall 里付掉的。要看真正的成分分解，用 `measure_readback_shape()`
## ——它把那 21 ms 拆成"等编辑器那一帧 / 等 ID pass 那一帧 / 像素传输 / 固定往返"四份。
##
## 返回各阶段的 min/median/max（微秒）。样本少于 3 时中位数没有意义，故下限 3。
func measure_click_cost(samples: int = 7, screen: Vector2 = Vector2(720.0, 450.0)) -> Dictionary:
	_repair_members()
	if not _prepared or _viewport == null or not is_instance_valid(_viewport):
		return {"ok": false, "reason": "not_prepared"}
	var n := maxi(samples, 3)
	var draw_us: Array[int] = []
	var readback_us: Array[int] = []
	var total_us: Array[int] = []
	# ── 路线 c：强制绘制 + 当场回读一个像素 ──────────────────────────────
	for i in range(n):
		_image = null
		_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		var t0 := Time.get_ticks_usec()
		RenderingServer.force_draw(false)
		var t1 := Time.get_ticks_usec()
		var tex := _viewport.get_texture()
		var img := tex.get_image() if tex != null else null
		if img != null:
			# 真的读那一个像素，别只测 get_image：解码也在点击的关键路径上。
			var _rgb := color_to_rgb8(img.get_pixel(
				clampi(int(screen.x), 0, img.get_width() - 1),
				clampi(int(screen.y), 0, img.get_height() - 1)))
		var t2 := Time.get_ticks_usec()
		draw_us.append(t1 - t0)
		readback_us.append(t2 - t1)
		total_us.append(t2 - t0)
	# ── 路线 b：常驻 pass 的每帧增量 = 开着画 vs 关掉画 ────────────────────
	#
	# ⚠ 不能把两种状态**交替**测：连续两次 force_draw 里，后一次会吸掉前一次的
	#   GPU 同步等待，量出来的差值符号都可能是反的（实测就出现过"关掉反而更慢"）。
	#   所以分成整块、每块先空跑几次热身，并把**两种块序各跑一遍**——
	#   若两个顺序给出的结论相反，那就是这套测法本身不成立，必须如实说，而不是挑一个好看的。
	var on_first := _measure_frame_block(true, n)
	var off_after := _measure_frame_block(false, n)
	var off_first := _measure_frame_block(false, n)
	var on_after := _measure_frame_block(true, n)
	_image = null
	stop_updating()
	return {
		"ok": true,
		"samples": n,
		"drawables": _ranges.size(),
		"viewport": [_viewport.size.x, _viewport.size.y],
		"force_draw_us": _stats(draw_us),
		"readback_us": _stats(readback_us),
		"click_total_us": _stats(total_us),
		# 两种块序各一组；结论只有在两组同号且量级相近时才成立。
		"order_on_first": {"with_pass_us": _stats(on_first), "without_pass_us": _stats(off_after)},
		"order_off_first": {"with_pass_us": _stats(on_after), "without_pass_us": _stats(off_first)},
	}


## 实测「那 21 ms 到底是像素传输还是渲染线程同步」——把回读代价拆开，逐条给出正面证据。
##
## 背景：`measure_click_cost` 量到回读约 21–24 ms，且 1440×900 / 720×450 / 360×225
## （面积差 16 倍）几乎不变。面积不敏感**提示**代价不在传输，但那是反证；本方法给正证。
##
## Godot 侧的调用链（4.6.1 源码实读，不是推断）：
##   `Viewport.get_texture().get_image()`
##     → `RS::texture_2d_get`（`scene/main/viewport.cpp:185`）
##     → `FUNC1RC` 宏 ⇒ 主线程 `command_queue.push_and_ret` **阻塞**等渲染线程排到这条命令
##       （`servers/rendering/rendering_server_default.h:211`、`servers/server_wrap_mt_common.h:151`）
##     → 渲染线程 `TextureStorage::texture_2d_get`（`texture_storage.cpp:1494`）
##       ⚠ 那里的 `image_cache_2d` 缓存对 `is_render_target` 显式不生效（`:1499`）⇒ 每次都真读
##     → `RD::texture_get_data`（`rendering_device.cpp:2023`）
##     → **`_flush_and_stall_for_all_frames()`**（`:2087`）
##       = `_stall_for_previous_frames()`（等**每一个**在飞帧的 fence，`:6922`）
##       + `_end_frame()` + `_execute_frame()`（把当前帧就地切断并提交）
##       + `_stall_for_frame(frame)`（再等这一次提交的 fence，`:6936`）
##
## ⇒ 源码上它是一次**整机流水线排空**（等价 device idle），与要读多少像素无关。
## 本方法测的就是这个结论的四个可证伪面，**每个样本的前置状态完全相同**
## （`_prime_frame()` 提交一帧、该帧仍在飞），只换"读谁 / 怎么读"：
##   ① `tiny_*`：改读一个 **1×1** 的空 SubViewport。像素量从 130 万降到 1，
##      若耗时不塌 ⇒ 传输不是代价。
##   ② `*_second`：紧接着**再读一次**，中间不绘制。第一次已经把流水线排空了，
##      第二次没有在飞工作可等 ⇒ 剩下的是"固定往返 + 传输"。
##      `first - second` = "等在飞 GPU 工作"那一半。
##   ③ `nopass_*`：前置那一帧**不画 ID pass**（只有编辑器自己的画面）。
##      用来分清那笔等待是"本 pass 的 GPU 时间"还是"一帧本来就要等的时间"
##      —— 这条直接决定路线 a 到底额外付不付费。
##   ④ `rd.*`：绕开 `get_image()`，在**渲染线程上**直接调
##      `RenderingDevice.texture_get_data()`（同一个函数，预期同样付 stall）与
##      `texture_get_data_async()`（`rendering_device.cpp:2142`，只登记拷贝区域 + 回调，
##      **不 stall**；回调在 `_stall_for_frame` 的正常帧循环里触发，`:6868`）。
##      ⚠ 这两条必须**在同样 primed 的状态下**实测：任务口径明确要求不许假设"绕不开"，
##      而把它们放在已排空的流水线上量出来的"很快"是假的（第一版就踩了这个坑：
##      量到 1.1 ms，只因为前面那趟 tiny 读已经把 GPU 排空了）。
##
## 全部只做测量，不改任何生产行为。
func measure_readback_shape(samples: int = 7) -> Dictionary:
	_repair_members()
	if not _prepared or _viewport == null or not is_instance_valid(_viewport):
		return {"ok": false, "reason": "not_prepared"}
	var n := maxi(samples, 3)

	# 1×1 的空 SubViewport：own_world_3d 里什么都没有，render target 仍然真实存在。
	# 它与 _viewport 的唯一差别就是**要搬多少字节**。
	var tiny := SubViewport.new()
	tiny.name = "PickIdReadbackProbe"
	tiny.own_world_3d = true
	tiny.transparent_bg = false
	tiny.size = Vector2i(1, 1)
	tiny.msaa_3d = Viewport.MSAA_DISABLED
	tiny.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	tiny.use_taa = false
	tiny.use_debanding = false
	tiny.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(tiny)
	# 先画一次，保证它的 render target 已经被真正分配与写过。
	RenderingServer.force_draw(false)
	tiny.render_target_update_mode = SubViewport.UPDATE_DISABLED

	var full_first: Array[int] = []
	var full_second: Array[int] = []
	var tiny_first: Array[int] = []
	var tiny_second: Array[int] = []
	var nopass_first: Array[int] = []
	var nopass_second: Array[int] = []
	var full_px := _viewport.size.x * _viewport.size.y

	for _i in range(n):
		_prime_frame(true)
		var t0 := Time.get_ticks_usec()
		var _a := _read_once(_viewport)
		var t1 := Time.get_ticks_usec()
		var _b := _read_once(_viewport)
		var t2 := Time.get_ticks_usec()
		full_first.append(t1 - t0)
		full_second.append(t2 - t1)

	for _i in range(n):
		_prime_frame(true)
		var t0 := Time.get_ticks_usec()
		var _a := _read_once(tiny)
		var t1 := Time.get_ticks_usec()
		var _b := _read_once(tiny)
		var t2 := Time.get_ticks_usec()
		tiny_first.append(t1 - t0)
		tiny_second.append(t2 - t1)

	for _i in range(n):
		_prime_frame(false)
		var t0 := Time.get_ticks_usec()
		var _a := _read_once(tiny)
		var t1 := Time.get_ticks_usec()
		var _b := _read_once(tiny)
		var t2 := Time.get_ticks_usec()
		nopass_first.append(t1 - t0)
		nopass_second.append(t2 - t1)

	var rd_probe := _measure_rd_paths(n)

	tiny.render_target_update_mode = SubViewport.UPDATE_DISABLED
	remove_child(tiny)
	tiny.queue_free()
	_image = null
	stop_updating()
	return {
		"ok": true,
		"samples": n,
		"full_viewport": [_viewport.size.x, _viewport.size.y],
		"full_pixels": full_px,
		"tiny_pixels": 1,
		# ① 像素量差 full_px 倍；若两行数值同量级 ⇒ 代价与传输无关。
		"full_first_us": _stats(full_first),
		"tiny_first_us": _stats(tiny_first),
		# ② 第二次读（流水线已被第一次排空）。first - second = 等在飞 GPU 工作的那一半。
		"full_second_us": _stats(full_second),
		"tiny_second_us": _stats(tiny_second),
		# ③ 前置帧不含 ID pass 的对照。与 tiny_first 之差 = 本 pass 自己的 GPU 时间。
		"nopass_first_us": _stats(nopass_first),
		"nopass_second_us": _stats(nopass_second),
		# ④ 绕开 get_image() 的两条 RD 路（在渲染线程上计时，前置状态与 ① 相同）。
		"rd": rd_probe,
	}


## 让一个样本的前置状态等于"真实点击那一刻"：提交一帧、随后立刻回读。
## `with_pass = false` 时该帧不画 ID pass，只有编辑器自己的画面——用作 ③ 的对照。
func _prime_frame(with_pass: bool) -> void:
	_viewport.render_target_update_mode = \
		SubViewport.UPDATE_ALWAYS if with_pass else SubViewport.UPDATE_DISABLED
	RenderingServer.force_draw(false)
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED


## 一次不走本类缓存的整图回读（`_image` 那层缓存会让第二次量到 0）。
static func _read_once(vp: SubViewport) -> int:
	var tex := vp.get_texture()
	if tex == null:
		return 0
	var img := tex.get_image()
	return 0 if img == null else img.get_width() * img.get_height()


## 渲染线程上的 RD 直读实测。**必须在渲染线程上跑**：`RenderingDevice` 的每个入口都有
## `ERR_RENDER_THREAD_GUARD`（`rendering_device.cpp:53-54`），主线程直接调只会报错返回空，
## 那样量到的"很快"是假的。`RenderingServer.call_on_render_thread` 是引擎给的正规入口
## （`rendering_server_default.h:1177` ⇒ `command_queue.push`，主线程不阻塞）。
##
## ⚠ 每个样本都必须重新 `_prime_frame()`：一次 `texture_get_data` 就把流水线排空了，
## 在同一个渲染线程回调里连测 n 次，第 2 次起量到的是"空转成本"而不是点击时的真实代价。
## 顺序保证：`call_on_render_thread` 与 `force_draw` 都进同一条命令队列，FIFO ⇒
## 渲染线程先跑回调（此时 prime 那一帧仍在飞），再跑那次 draw。
func _measure_rd_paths(n: int) -> Dictionary:
	var vp_rid := _viewport.get_viewport_rid()
	if not vp_rid.is_valid():
		return {"ok": false, "reason": "no_viewport_rid"}
	_rt_sync_us = []
	_rt_async_us = []
	_rt_bytes = 0
	_rt_error = ""
	for _i in range(n):
		_prime_frame(true)
		RenderingServer.call_on_render_thread(Callable(self, "_rt_read_sync").bind(vp_rid))
		RenderingServer.force_draw(false)
	for _i in range(n):
		_prime_frame(true)
		RenderingServer.call_on_render_thread(Callable(self, "_rt_read_async").bind(vp_rid))
		RenderingServer.force_draw(false)
	if not _rt_error.is_empty():
		return {"ok": false, "reason": _rt_error}
	if _rt_sync_us.is_empty():
		return {"ok": false, "reason": "render_thread_probe_did_not_run"}
	return {
		"ok": true,
		# 同一个 RD 函数、同一张纹理，只是不经 get_image()。若与 full_first_us 同量级
		# ⇒ "换条路读"绕不开这笔代价，代价确实在 stall 上。
		"rd_sync_us": _stats(_rt_sync_us),
		"rd_sync_bytes": _rt_bytes,
		# 只登记拷贝 + 回调、不 stall 的那条。若它在同样 primed 的状态下仍然很小
		# ⇒ 确实存在一条不阻塞调用方的回读路（延迟没消失，只是不再阻塞）。
		"rd_async_enqueue_us": _stats(_rt_async_us),
	}


## 取本 pass 的 render target 在主 RD 上的纹理。⚠ 只能在渲染线程上调。
func _rt_rd_texture(vp_rid: RID) -> RID:
	var tex_rid := RenderingServer.viewport_get_texture(vp_rid)
	if not tex_rid.is_valid():
		_rt_error = "no_viewport_texture"
		return RID()
	# srgb=false：要的是存储用的 UNORM view，不能拿 sRGB view（那会改写码值）。
	var rd_tex := RenderingServer.texture_get_rd_texture(tex_rid, false)
	if not rd_tex.is_valid():
		_rt_error = "no_rd_texture"
	return rd_tex


## ⚠ 运行在**渲染线程**上（`call_on_render_thread` 调度）。一次同步 RD 直读的计时。
func _rt_read_sync(vp_rid: RID) -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		_rt_error = "no_rendering_device"
		return
	var rd_tex := _rt_rd_texture(vp_rid)
	if not rd_tex.is_valid():
		return
	var t0 := Time.get_ticks_usec()
	var data := rd.texture_get_data(rd_tex, 0)
	var t1 := Time.get_ticks_usec()
	_rt_sync_us.append(t1 - t0)
	_rt_bytes = data.size()


## ⚠ 运行在**渲染线程**上。一次异步 RD 回读**登记**的计时（不等结果）。
func _rt_read_async(vp_rid: RID) -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		_rt_error = "no_rendering_device"
		return
	var rd_tex := _rt_rd_texture(vp_rid)
	if not rd_tex.is_valid():
		return
	var t0 := Time.get_ticks_usec()
	var err := rd.texture_get_data_async(rd_tex, 0, Callable(self, "_rt_async_sink"))
	var t1 := Time.get_ticks_usec()
	if err != OK:
		_rt_error = "async_error_%d" % int(err)
		return
	_rt_async_us.append(t1 - t0)


## `texture_get_data_async` 的回调落点。⚠ 它在渲染线程上、于 `_stall_for_frame` 里触发
## （`rendering_device.cpp:6868`），本实测只关心"登记要多久"，不消费数据。
func _rt_async_sink(_data: PackedByteArray) -> void:
	pass


# ---- async 回读的端到端延迟（诊断） -------------------------------------------

## 实测 `RD.texture_get_data_async` **从发起到数据抵达**的墙钟延迟、跨了几帧、
## 抵达的数据是否与同步读逐位一致，以及"编辑器只在有变化时才绘制"会不会把回调饿死。
##
## ⚠ `measure_readback_shape` 量到的"登记 19 µs"**不是**这个数——那只是把拷贝区域
## 记进 draw graph 的时间。真正的交付时刻由帧循环决定：
##   `texture_get_data_async` 把请求挂进 `frames[frame].download_texture_get_data_requests`
##   （`rendering_device.cpp:2251`）；拷贝随该帧的 `_end_frame` 提交；回调在
##   `_stall_for_frame(该帧槽)` 里触发（`:6868-6917`），而那**只发生在 `_begin_frame`
##   轮回到同一个帧槽时**（`swap_buffers`：`_end_frame` → `_execute_frame` →
##   `frame = (frame+1) % frames.size()` → `_begin_frame` → `_stall_for_frame(frame)`，
##   `:6533-6547` / `:6672-6675`）。主设备 `frames.size() = MAX(2, frame_queue_size)`
##   ⇒ **要等帧槽绕回来，也就是若干次绘制之后**。没有绘制就没有 `_begin_frame`，
##   也就没有回调 —— 这正是本方法第 ① 段要证的事。
##
## 三段各自独立、每个样本都重新 `_prime_frame()`（前一次测量会污染后一次，已有教训）：
##   ① **空等段**：发起之后**一次都不绘制**，阻塞主线程空转 `idle_wait_ms`，看回调来不来。
##      ⚠ 发起本身要让渲染线程排到那条命令，这里用 `RenderingServer.force_sync()`
##      （`rendering_server.cpp:3603` 绑定到 `RenderingServer::sync`，
##      `rendering_server_default.cpp:428` ⇒ 只 flush 命令队列，**不绘制**）。
##      用 `force_draw` 就说不清"是不是那次绘制把回调带出来的"。
##   ② **数绘制段**：逐次 `force_draw` 直到回调触发，记录**用了几次**。
##   ③ **一致性段**：回调拿到的字节 vs 同一张纹理的同步 `texture_get_data` 字节，
##      逐位比对；再把两者的某个像素解成 pick_id，与 `get_image()` 那条生产形状的路对齐。
##      ⚠ 前置帧之后 `_viewport` 一直是 UPDATE_DISABLED，ID 目标内容全程冻结，
##      比对才有意义。
##
## 另跑一组同场景同位姿的同步 `get_image()` 作**同一把尺子的对照**——
## 不拿上一轮的数字直接比。
func measure_async_latency(samples: int = 7, idle_wait_ms: int = 400,
		max_draws: int = 16) -> Dictionary:
	_repair_members()
	if not _prepared or _viewport == null or not is_instance_valid(_viewport):
		return {"ok": false, "reason": "not_prepared"}
	var vp_rid := _viewport.get_viewport_rid()
	if not vp_rid.is_valid():
		return {"ok": false, "reason": "no_viewport_rid"}
	var n := maxi(samples, 3)

	var latency_us: Array[int] = []          # 从主线程发起请求 → 回调携数据抵达
	var issue_to_arrive_us: Array[int] = []  # 从渲染线程真正登记完 → 抵达
	var frames_crossed: Array[int] = []      # 抵达时的 frames_drawn − 发起时的
	var draws_needed: Array[int] = []        # ② 段用了几次 force_draw
	var idle_waited_us: Array[int] = []      # ① 段实际空等了多久
	var fired_without_draw := 0
	var never_fired := 0
	var thread_ids := {}
	var bytes_equal := 0
	var bytes_checked := 0
	var byte_mismatch: Array = []
	var pixel_rows: Array = []
	var main_thread_id := OS.get_main_thread_id()

	for _i in range(n):
		_prime_frame(true)
		_async_reset()
		var t_request := Time.get_ticks_usec()
		var f_request := Engine.get_frames_drawn()
		RenderingServer.call_on_render_thread(Callable(self, "_rt_issue_async").bind(vp_rid))
		# ⚠ force_sync 而不是 force_draw：只 flush 命令队列，不绘制。
		RenderingServer.force_sync()
		if _async_issue_err != OK:
			return {"ok": false, "reason": "async_issue_failed",
				"error": _async_issue_err, "detail": _rt_error}

		# ① 空等：一次都不绘制。主线程阻塞 ⇒ Main::iteration 不跑 ⇒ 没有帧。
		var idle_t0 := Time.get_ticks_usec()
		while not _async_fired and (Time.get_ticks_usec() - idle_t0) < idle_wait_ms * 1000:
			OS.delay_msec(5)
		idle_waited_us.append(Time.get_ticks_usec() - idle_t0)
		if _async_fired:
			fired_without_draw += 1

		# ② 数绘制：还没来就逐次 force_draw，看要几次。
		var draws := 0
		while not _async_fired and draws < max_draws:
			RenderingServer.force_draw(false)
			draws += 1
		if not _async_fired:
			never_fired += 1
			continue
		draws_needed.append(draws)
		latency_us.append(_async_arrive_us - t_request)
		issue_to_arrive_us.append(_async_arrive_us - _async_issue_us)
		frames_crossed.append(_async_arrive_frame - f_request)
		thread_ids[_async_thread_id] = int(thread_ids.get(_async_thread_id, 0)) + 1

		# ③ 一致性：同一张纹理的同步读，逐位比对。
		var check := _compare_async_against_sync(vp_rid)
		bytes_checked += 1
		if bool(check.get("equal", false)):
			bytes_equal += 1
		else:
			byte_mismatch.append(check)
		if pixel_rows.size() < 3:
			pixel_rows.append(check.get("pixels", {}))

	# 同一把尺子的同步对照：同场景同位姿，每个样本重新预热。
	var sync_get_image_us: Array[int] = []
	for _i in range(n):
		_prime_frame(true)
		var t0 := Time.get_ticks_usec()
		var _px := _read_once(_viewport)
		sync_get_image_us.append(Time.get_ticks_usec() - t0)

	# ── 线程约束的正面证据（实测，不推断）────────────────────────────────
	# 编辑器**永远**在主线程渲染：`main.cpp:2697-2700` 对 editor / project_manager
	# 强制 `separate_thread_render = 0`（注释原文：分离线程会开机即崩）。
	# 所以"回调落在主线程"不是碰巧，是结构性的——但仍然要测出来。
	var on_render_thread := RenderingServer.is_on_render_thread()
	var direct_rd := _probe_direct_main_thread_rd(vp_rid)

	_async_reset()
	_image = null
	stop_updating()
	return {
		"ok": true,
		"samples": n,
		"idle_wait_ms": idle_wait_ms,
		"viewport": [_viewport.size.x, _viewport.size.y],
		# 主线程调用时 RS 就认为自己在"渲染线程"上 ⇒ 单线程渲染。
		"main_thread_is_render_thread": on_render_thread,
		# 主线程**直接**调 RD（不经 call_on_render_thread）能不能成。
		"direct_main_thread_rd": direct_rd,
		# ① 决定性的一条：不绘制时回调来不来。
		"fired_without_draw": fired_without_draw,
		"idle_waited_us": _stats(idle_waited_us),
		"never_fired": never_fired,
		# ② 要几次绘制才交付。
		"draws_needed": _stats(draws_needed),
		"frames_crossed": _stats(frames_crossed),
		# 端到端延迟。
		"latency_us": _stats(latency_us),
		"issue_to_arrive_us": _stats(issue_to_arrive_us),
		# 同一把尺子的同步对照（本次会话现测，不引用上一轮数字）。
		"sync_get_image_us": _stats(sync_get_image_us),
		# ③ 逐位一致性 + 线程约束。
		"bytes_checked": bytes_checked,
		"bytes_equal": bytes_equal,
		"byte_mismatch": byte_mismatch,
		"pixel_samples": pixel_rows,
		"callback_thread_ids": thread_ids,
		"main_thread_id": main_thread_id,
		"callback_on_main_thread": thread_ids.has(main_thread_id),
	}


## 主线程**直接**调 `RenderingDevice` 能不能成。
##
## `ERR_RENDER_THREAD_GUARD`（`rendering_device.cpp:53-54`）比的是
## `render_thread_id != Thread::get_caller_id()`，而 `render_thread_id` 是 RD 初始化时
## 取的当时线程（`:8419` / `:8435`）。编辑器强制单线程渲染 ⇒ 那就是主线程 ⇒ 守卫放行。
## ⚠ 若守卫**不**放行，引擎会打一条 ERROR 并返回空数组——那条 ERROR 就是答案本身，
## 不要因为"怕日志变红"而不测。
func _probe_direct_main_thread_rd(vp_rid: RID) -> Dictionary:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		return {"ok": false, "reason": "no_rendering_device"}
	var tex_rid := RenderingServer.viewport_get_texture(vp_rid)
	if not tex_rid.is_valid():
		return {"ok": false, "reason": "no_viewport_texture"}
	var rd_tex := RenderingServer.texture_get_rd_texture(tex_rid, false)
	if not rd_tex.is_valid():
		return {"ok": false, "reason": "no_rd_texture"}
	var t0 := Time.get_ticks_usec()
	var data := rd.texture_get_data(rd_tex, 0)
	return {"ok": data.size() > 0, "bytes": data.size(),
		"us": Time.get_ticks_usec() - t0}


func _async_reset() -> void:
	_async_fired = false
	_async_arrive_us = 0
	_async_arrive_frame = -1
	_async_issue_us = 0
	_async_issue_err = OK
	_async_thread_id = 0
	_async_data = PackedByteArray()
	_async_sync_data = PackedByteArray()


## 把回调拿到的字节与同一张纹理的**同步** `texture_get_data` 字节逐位比对，
## 并把同一个像素分别解成 pick_id（含一条经 `get_image()` 的生产形状对照）。
func _compare_async_against_sync(vp_rid: RID) -> Dictionary:
	_async_sync_data = PackedByteArray()
	RenderingServer.call_on_render_thread(Callable(self, "_rt_read_for_compare").bind(vp_rid))
	RenderingServer.force_sync()
	var a := _async_data
	var b := _async_sync_data
	var out := {
		"async_bytes": a.size(),
		"sync_bytes": b.size(),
		"equal": a.size() > 0 and a.size() == b.size() and a == b,
	}
	if not bool(out["equal"]) and a.size() == b.size():
		for i in range(a.size()):
			if a[i] != b[i]:
				out["first_diff_offset"] = i
				out["first_diff"] = [a[i], b[i]]
				break
	# 取一个真有命中的像素来解 pick_id：整幅扫到第一个非零的。
	# 只比"同一个像素三条路解出的 id"——比"图里有没有东西"更有分辨力。
	var w := _viewport.size.x
	var h := _viewport.size.y
	var px := {"width": w, "height": h}
	if a.size() >= w * h * 4:
		var found := -1
		var step := 4 * 37  # 质数步长扫描，别只看规则网格
		var o := 0
		while o + 2 < a.size():
			if a[o] != 0 or a[o + 1] != 0 or a[o + 2] != 0:
				found = o
				break
			o += step
		if found >= 0:
			var pix := found / 4
			px["pixel"] = [pix % w, pix / w]
			px["async_pick_id"] = decode_rgb8(a[found], a[found + 1], a[found + 2])
			if b.size() > found + 2:
				px["rd_sync_pick_id"] = decode_rgb8(b[found], b[found + 1], b[found + 2])
			# 生产形状那条：get_image() 出来的 RGB8。三者相同才算真的对上。
			var tex := _viewport.get_texture()
			var img := tex.get_image() if tex != null else null
			if img != null:
				var rgb := color_to_rgb8(img.get_pixel(pix % w, pix / w))
				px["get_image_pick_id"] = decode_rgb8(rgb.x, rgb.y, rgb.z)
	out["pixels"] = px
	return out


## ⚠ 运行在**渲染线程**上。发起一次 async 回读并记录登记完成时刻。
func _rt_issue_async(vp_rid: RID) -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		_rt_error = "no_rendering_device"
		_async_issue_err = ERR_UNAVAILABLE
		return
	var rd_tex := _rt_rd_texture(vp_rid)
	if not rd_tex.is_valid():
		_async_issue_err = ERR_UNAVAILABLE
		return
	var err := rd.texture_get_data_async(rd_tex, 0, Callable(self, "_rt_async_arrive"))
	_async_issue_us = Time.get_ticks_usec()
	_async_issue_err = int(err)


## ⚠ 运行在**渲染线程**上。async 数据的抵达点。
##
## ⚠⚠ `_data` 必须 `duplicate()`：引擎那边是一个 **`thread_local` 复用缓冲**
## （`rendering_device.cpp:6835` `thread_local PackedByteArray packed_byte_array;`），
## 下一次请求会 `resize` 并覆写它。直接存引用 = 存了一块随时会变的内存。
func _rt_async_arrive(_data: PackedByteArray) -> void:
	_async_arrive_us = Time.get_ticks_usec()
	_async_arrive_frame = Engine.get_frames_drawn()
	_async_thread_id = OS.get_thread_caller_id()
	_async_data = _data.duplicate()
	_async_fired = true


## ⚠ 运行在**渲染线程**上。取同步基准字节（与 async 同一张纹理、同一时刻的内容）。
func _rt_read_for_compare(vp_rid: RID) -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		_rt_error = "no_rendering_device"
		return
	var rd_tex := _rt_rd_texture(vp_rid)
	if not rd_tex.is_valid():
		return
	_async_sync_data = rd.texture_get_data(rd_tex, 0)


## 一整块同状态的 force_draw 计时（前 3 次热身不计）。
func _measure_frame_block(pass_enabled: bool, n: int) -> Array[int]:
	_viewport.render_target_update_mode = \
		SubViewport.UPDATE_ALWAYS if pass_enabled else SubViewport.UPDATE_DISABLED
	for _w in range(3):
		RenderingServer.force_draw(false)
	var out: Array[int] = []
	for _i in range(n):
		var t := Time.get_ticks_usec()
		RenderingServer.force_draw(false)
		out.append(Time.get_ticks_usec() - t)
	return out


static func _stats(values: Array[int]) -> Dictionary:
	if values.is_empty():
		return {"min": 0, "median": 0, "max": 0, "n": 0}
	var sorted := values.duplicate()
	sorted.sort()
	return {
		"min": sorted[0],
		"median": sorted[sorted.size() / 2],
		"max": sorted[sorted.size() - 1],
		"n": sorted.size(),
	}


## 关掉 ID 目标的持续更新。resolve() 拿到图之后自动调用；外部在放弃一趟 pass 时也可调。
func stop_updating() -> void:
	_repair_members()
	if _viewport != null and is_instance_valid(_viewport):
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED


# ---- 内部 --------------------------------------------------------------------

func _range_for(pick_id: int) -> Dictionary:
	for entry in _ranges:
		var base := int(entry.get("base", 0))
		var count := int(entry.get("count", 0))
		if pick_id >= base and pick_id < base + count:
			return entry
	return {}


## 回读 ID 目标。帧数守卫不满足就返回 null（调用方按失败处理，不是按「没命中」处理）。
func _fetch_image() -> Image:
	if _image != null:
		return _image
	if _viewport == null or not is_instance_valid(_viewport):
		return null
	var drawn := Engine.get_frames_drawn()
	if drawn - _prepared_frame < MIN_FRAMES_BEFORE_READBACK:
		push_error("[PickId] ID 目标还没画出本次位姿（prepare 于第 %d 帧，现在第 %d 帧，至少要 %d 帧）—— 拒绝回读上一次位姿的图。" % [
			_prepared_frame, drawn, MIN_FRAMES_BEFORE_READBACK])
		assert(false, "PickIdPass._fetch_image: readback before the pass was drawn")
		return null
	var tex := _viewport.get_texture()
	if tex == null:
		return null
	var img := tex.get_image()
	if img == null:
		return null
	_image = img
	stop_updating()
	return _image


func _ensure_nodes() -> bool:
	if _viewport != null and is_instance_valid(_viewport) and _viewport.is_inside_tree() \
			and _camera != null and is_instance_valid(_camera) \
			and _mirror_root != null and is_instance_valid(_mirror_root) \
			and _shader != null:
		return true

	_shader = load(SHADER_PATH) as Shader
	if _shader == null:
		push_error("[PickId] 加载 %s 失败 —— ID pass 没有着色器可用。" % SHADER_PATH)
		assert(false, "PickIdPass: pick id shader missing")
		return false

	var old := get_node_or_null(NodePath(VIEWPORT_NODE_NAME))
	if old != null:
		# 先摘下再 free：queue_free 挂起期内旧节点仍占名，同帧新建同名节点会被自动改名。
		remove_child(old)
		old.queue_free()
	_mirrors.clear()

	var viewport := SubViewport.new()
	viewport.name = VIEWPORT_NODE_NAME
	# 独立 World3D：镜像节点与真节点物理隔离，编辑器相机永远看不到 ID 材质（见类注释）。
	viewport.own_world_3d = true
	# 已定案：不开 transparent_bg ⇒ 回读为 RGB8，ID 位宽 24 位（上限已由分配器断言把守）。
	viewport.transparent_bg = false
	# 下面五项都是「会改写读回来的像素」的东西，必须全关：
	# MSAA / SSAA 会插值出不存在的中间 ID；TAA 会把上一帧的 ID 混进来；
	# debanding 会往量化前的值上加噪声；3D 缩放会让像素坐标与屏幕坐标不再一一对应。
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	viewport.use_taa = false
	viewport.use_debanding = false
	viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	viewport.scaling_3d_scale = 1.0
	viewport.use_occlusion_culling = false
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(viewport)
	_viewport = viewport

	# ⚠ 必须用 find_world_3d()，不能用 world_3d：后者返回的是**外部显式指派**的 World3D
	# （`Viewport::get_world_3d` 直接返回 `world_3d` 成员），而 own_world_3d 创建的那一份
	# 存在 `own_world_3d` 成员里，只有 `find_world_3d()` 会回退到它。用错了拿到的是 null。
	var world := viewport.find_world_3d()
	if world == null:
		push_error("[PickId] SubViewport.own_world_3d 已开但 find_world_3d() 为空 —— ID pass 无法建立独立场景。")
		assert(false, "PickIdPass: own world_3d missing")
		return false
	world.environment = _make_environment()

	var cam := Camera3D.new()
	cam.name = CAMERA_NODE_NAME
	viewport.add_child(cam)
	cam.current = true
	_camera = cam

	var root := Node3D.new()
	root.name = MIRROR_ROOT_NAME
	viewport.add_child(root)
	_mirror_root = root
	return true


## ID pass 专用环境：背景纯黑（= pick_id 0 = 无命中），且把所有会改写颜色的项关死。
## tonemap 保持 LINEAR + exposure 1 + white 1，使出口只剩一次 linear→sRGB，
## 恰好被着色器里的预补偿抵消（见 shaders/pick_id.gdshader 注释 3）。
static func _make_environment() -> Environment:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.0, 0.0, 0.0, 1.0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = 1.0
	env.tonemap_white = 1.0
	env.ssao_enabled = false
	env.ssil_enabled = false
	env.ssr_enabled = false
	env.sdfgi_enabled = false
	env.glow_enabled = false
	env.fog_enabled = false
	env.volumetric_fog_enabled = false
	env.adjustment_enabled = false
	return env


## 相机整套复制（不只是位姿）：视口缩放/DPI/投影任一项不同，像素坐标就与屏幕坐标错位，
## 而错位的表现是「点哪儿选中的都是旁边那个」，不是报错。
func _copy_camera(src: Camera3D) -> void:
	_camera.projection = src.projection
	_camera.fov = src.fov
	_camera.size = src.size
	_camera.near = src.near
	_camera.far = src.far
	_camera.keep_aspect = src.keep_aspect
	_camera.frustum_offset = src.frustum_offset
	_camera.h_offset = src.h_offset
	_camera.v_offset = src.v_offset
	# 独立 World3D 里只有镜像，cull_mask 不再承担隔离职责，全开即可。
	_camera.cull_mask = 0xFFFFF
	# 相机是 SubViewport 的直接子节点，父链上没有 Node3D ⇒ global == local，
	# 直接赋源相机的世界变换即得同一位姿。
	_camera.global_transform = src.global_transform
	_camera.current = true


func _ensure_mirror(index: int) -> MultiMeshInstance3D:
	while _mirrors.size() <= index:
		var mirror := MultiMeshInstance3D.new()
		mirror.name = "PickMirror%d" % _mirrors.size()
		mirror.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mirror.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		var mat := ShaderMaterial.new()
		mat.shader = _shader
		mirror.material_override = mat
		_mirror_root.add_child(mirror)
		_mirrors.append(mirror)
	var out := _mirrors[index]
	return out if is_instance_valid(out) else null


## 把一个真 drawable 绑到一个镜像上。**共享同一个 MultiMesh 资源**——不复制、不重建，
## 因而共享同一块 GPU 实例缓冲：ID pass 画的就是显示画的那一份变换。
func _bind_mirror(mirror: MultiMeshInstance3D, source: MultiMeshInstance3D, mm: MultiMesh, base: int) -> void:
	mirror.multimesh = mm
	# custom_aabb 缺失 ⇒ 空 AABB ⇒ 整批被剔除且无任何报错
	# （placed_instance_display.gd:19-22 记的静默陷阱）。镜像照抄源节点的那一份。
	mirror.custom_aabb = source.custom_aabb
	mirror.global_transform = source.global_transform
	mirror.visible = true
	var mat := mirror.material_override as ShaderMaterial
	if mat == null:
		mat = ShaderMaterial.new()
		mat.shader = _shader
		mirror.material_override = mat
	mat.set_shader_parameter("pick_id_base", base)
	mat.set_shader_parameter("encode_srgb", true)


func _park_unused_mirrors(used: int) -> void:
	for i in range(used, _mirrors.size()):
		var mirror := _mirrors[i]
		if mirror == null or not is_instance_valid(mirror):
			continue
		mirror.visible = false
		# 解绑 MultiMesh：留着会让本类持有一份早已被宿主释放的资源引用。
		mirror.multimesh = null
