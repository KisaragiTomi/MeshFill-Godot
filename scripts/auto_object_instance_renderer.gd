class_name AutoObjectInstanceRenderer
extends "res://scripts/godot_compute_shader_base.gd"

## AutoObject 实例 emit 宿主：把 `GPUAutoObjectRuntime` 的常驻对象池编译成
## 「绘制载荷 `instance_render[]` + 点选 OBB `instance_pick[]`」两块紧凑表。
## 契约全文见《AutoObject实例GPU直提与点选交接计划.md》，字节布局 SSOT 在本文件的
## `GLSL_CONSTANTS`（经 `layout_block()` 发射进 shader 的 `@@GEN` 区块）。
##
## 三点结构约束，每一条都对应一个具体的失败模式：
##
## 1. **渲染与点选的包围盒是同一轮 scatter 写出的两块。** 不是"渲染一套、点选另一套"——
##    后者正是今天 AutoObject 点不中树冠的成因（CPU 侧按物体**原点**在屏幕上找最近者，
##    而原点对一棵树是树干基部）。
## 2. **消费者只被允许按 `instance_dispatch` 派发。** 按 `max_objects` 或按批容量派发，
##    空场景每次点击也要发 1024 个工作组。
## 3. **`revision` 守卫 + 内容 key 守卫，永不整块回读。** `GPUAutoObjectRuntime.get_live_count()`
##    是 O(max_objects) 的阻塞往返，绝不能进渲染或点选路径。
##
## 所有权：由 `GPUAutoObjectRuntime` 惰性自持（`get_instance_renderer()`），
## 与 R3 §6.3 写的 `ScenePlacementRuntime` 归属不同，理由见交接计划 §5.1。
## 本类**不持有** RenderingDevice——它 attach 到 runtime 的 RD 上，`_owns_rendering_device`
## 保持 false，dispose 时不会把别人的设备关掉。

const SHADER_PATH := "res://shaders/autoobject_emit_instances.glsl"
const LOCAL_SIZE_X := 64

# ── 记录 stride（GLSL_CONSTANTS 的 GDScript 侧对应物）────────────────────────
const RENDER_FLOATS := 20
const RENDER_STRIDE_BYTES := RENDER_FLOATS * 4        # 80
const PICK_WORDS := 32
const PICK_STRIDE_BYTES := PICK_WORDS * 4             # 128
const BATCH_WORDS := 16
const BATCH_STRIDE_BYTES := BATCH_WORDS * 4           # 64
const DISPATCH_WORDS := 4
const DISPATCH_BYTES := DISPATCH_WORDS * 4            # 16
const MESH_DESCRIPTION_STRIDE_BYTES := 128

# instance_pick 字下标（消费者解码用；与 GLSL_CONSTANTS 的 AOI_P_* 一一对应）
const P_ROW0 := 0
const P_ROW1 := 4
const P_ROW2 := 8
const P_COLOR := 12
const P_OBB_CENTER := 16
const P_OBB_YAW := 19
const P_OBB_HALF := 20
const P_OBB_RADIUS := 23
const P_OBJECT_ID := 24
const P_PROFILE_ID := 25
const P_BATCH_INDEX := 26
const P_FLAGS := 27
const P_VOXEL_MIN_X := 28
const P_ASSET_INDEX := 31

# batch_header 字下标
const B_INSTANCE_START := 0
const B_INSTANCE_COUNT := 1
const B_PROFILE_ID := 2
const B_ASSET_INDEX := 3
const B_CAPACITY := 4
const B_REVISION := 5
const B_CURSOR := 6
const B_FLAGS := 7

# instance_dispatch 字下标
const D_LIVE_COUNT := 3

# instance_pick flags 位
const FLAG_ALIVE := 1
const FLAG_SELECTED := 2
const FLAG_CULLED := 4
const FLAG_TERRAIN_REBASED := 8

# pass 下标与 option 位
const PASS_COUNT := 0
const PASS_PREFIX := 1
const PASS_SCATTER := 2
const PASS_WG_SCAN := 3
const OPT_TERRAIN := 1
const OPT_CULL := 2
## 槽位用保序流压缩而不是 `atomicAdd` 抢。**本类永远置位**，不提供关掉它的入口 ——
## 关掉等于让拾取 ID 每次 emit 重新洗牌（见 `_ensure_buffers` 上方的说明）。
const OPT_STABLE_SLOTS := 4

## GLSL 侧常量表的唯一真值源。行形如 [glsl_type, name, literal]；单元素行原样输出
## （空行/注释）。`shaders/autoobject_emit_instances.glsl` 的
## `// @@GEN autoobject_instance_layout` 区块由 `layout_block()` 发射，
## `scripts/checks/glsl_gen_block_checks.gd` 守卫两侧不漂移。
const GLSL_CONSTANTS := [
	["// 实例表字节布局 SSOT：AutoObjectInstanceRenderer.GLSL_CONSTANTS"],
	["// CPU 用这些下标解码、GLSL 用它们写入；任一侧单边改动的症状是\"某字段读出隔壁字段的值\"，"],
	["// 不崩、只静默错。scripts/checks/glsl_gen_block_checks.gd 守卫两侧不漂移。"],
	[""],
	["// instance_render[]：MultiMesh 形状，20 float / 实例"],
	["int", "AOI_RENDER_FLOATS", "20"],
	["int", "AOI_R_ROW0", "0"],
	["int", "AOI_R_ROW1", "4"],
	["int", "AOI_R_ROW2", "8"],
	["int", "AOI_R_COLOR", "12"],
	["int", "AOI_R_CUSTOM", "16"],
	[""],
	["// instance_pick[]：128 B / 实例 = 32 word"],
	["int", "AOI_PICK_WORDS", "32"],
	["int", "AOI_P_ROW0", "0"],
	["int", "AOI_P_ROW1", "4"],
	["int", "AOI_P_ROW2", "8"],
	["int", "AOI_P_COLOR", "12"],
	["int", "AOI_P_OBB_CENTER", "16"],
	["int", "AOI_P_OBB_YAW", "19"],
	["int", "AOI_P_OBB_HALF", "20"],
	["int", "AOI_P_OBB_RADIUS", "23"],
	["int", "AOI_P_OBJECT_ID", "24"],
	["int", "AOI_P_PROFILE_ID", "25"],
	["int", "AOI_P_BATCH_INDEX", "26"],
	["int", "AOI_P_FLAGS", "27"],
	["int", "AOI_P_VOXEL_MIN_X", "28"],
	["int", "AOI_P_VOXEL_MIN_Y", "29"],
	["int", "AOI_P_VOXEL_MIN_Z", "30"],
	["int", "AOI_P_ASSET_INDEX", "31"],
	[""],
	["// instance_pick flags（AOI_P_FLAGS 的位）"],
	["uint", "AOI_FLAG_ALIVE", "1u"],
	["uint", "AOI_FLAG_SELECTED", "2u"],
	["uint", "AOI_FLAG_CULLED", "4u"],
	["uint", "AOI_FLAG_TERRAIN_REBASED", "8u"],
	[""],
	["// batch_header[]：64 B / 批 = 16 word"],
	["int", "AOI_BATCH_WORDS", "16"],
	["int", "AOI_B_INSTANCE_START", "0"],
	["int", "AOI_B_INSTANCE_COUNT", "1"],
	["int", "AOI_B_PROFILE_ID", "2"],
	["int", "AOI_B_ASSET_INDEX", "3"],
	["int", "AOI_B_CAPACITY", "4"],
	["int", "AOI_B_REVISION", "5"],
	["int", "AOI_B_CURSOR", "6"],
	["int", "AOI_B_FLAGS", "7"],
	[""],
	["// instance_dispatch[4]：间接派发参数 + 存活计数"],
	["int", "AOI_D_GROUPS_X", "0"],
	["int", "AOI_D_GROUPS_Y", "1"],
	["int", "AOI_D_GROUPS_Z", "2"],
	["int", "AOI_D_LIVE_COUNT", "3"],
	["int", "AOI_DISPATCH_LOCAL_SIZE_X", "64"],
	[""],
	["// mesh_description（ScenePlacementRuntime 拥有，stride 128 B = 8 vec4）"],
	["int", "AOI_MESH_DESC_VEC4", "8"],
	["int", "AOI_MESH_AABB_POSITION_VEC4", "2"],
	["int", "AOI_MESH_AABB_SIZE_VEC4", "3"],
	[""],
	["// pass 下标"],
	["int", "AOI_PASS_COUNT", "0"],
	["int", "AOI_PASS_PREFIX", "1"],
	["int", "AOI_PASS_SCATTER", "2"],
	["int", "AOI_PASS_WG_SCAN", "3"],
	[""],
	["// option_bits"],
	["int", "AOI_OPT_TERRAIN", "1"],
	["int", "AOI_OPT_CULL", "2"],
	["int", "AOI_OPT_STABLE_SLOTS", "4"],
]

## 携带上述常量表的着色器，供 glsl_gen_block_checks.gd 扫描。
const CONSUMERS := {
	"autoobject_instance_layout": [
		"res://shaders/autoobject_emit_instances.glsl",
	],
}

## std430 push 布局。全部用标量字段而非 vec3/vec4：向量字段的对齐规则在 std430 下有
## 16 字节对齐要求，写成标量列表后偏移一目了然，也免得 pack() 的 Variant 分量推断出错。
const EMIT_PUSH := [
	["object_capacity", "int"], ["batch_count", "int"], ["instance_capacity", "int"], ["pass_index", "int"],
	["option_bits", "int"], ["terrain_res", "int"], ["object_revision", "int"], ["_pad0", "int"],
	["camera_x", "float"], ["camera_y", "float"], ["camera_z", "float"], ["cull_distance", "float"],
	["grid_origin_x", "float"], ["grid_origin_y", "float"], ["grid_origin_z", "float"], ["_pad1", "float"],
	["voxel_size_x", "float"], ["voxel_size_y", "float"], ["voxel_size_z", "float"], ["_pad2", "float"],
	["color_r", "float"], ["color_g", "float"], ["color_b", "float"], ["color_a", "float"],
]

# ---------------------------------------------------------------------------
# 状态
# ---------------------------------------------------------------------------

var _runtime: RefCounted            # 借用的 GPUAutoObjectRuntime（永不释放）
var _kernel: RefCounted             # ComputeKernel

var _instance_render_buffer: RID
var _instance_pick_buffer: RID
var _batch_header_buffer: RID
var _instance_dispatch_buffer: RID
var _terrain_buffer: RID
## 保序流压缩的中间量，下标都是 `workgroup * batch_count + batch`。
var _wg_counts_buffer: RID
var _wg_offsets_buffer: RID
var _wg_capacity := 0

var _instance_capacity := 0
var _batch_capacity := 0
var _terrain_resolution := 0
var _terrain_content_key := ""
var _terrain_revision := 0

var _emitted_revision := -1
var _emitted_camera := Vector3.ZERO
var _emitted_ok := false
var _last_reason := "never_emitted"

const ComputeKernelScript := preload("res://scripts/utils/compute_kernel.gd")
const ComputePassChainScript := preload("res://scripts/utils/compute_pass_chain.gd")


func _init() -> void:
	log_name = "AutoObjectInstanceRenderer"


## ⚠ 编辑器软重载后的成员修复，别当成冗余判空删掉：软重载只搬运重载前已存在的成员，
## 本次重载新增的槽是 nil；且静态类型已知时 `== null` 会被编成恒 false（variant_op.cpp
## 给 (RID, NIL) 注册的是 OperatorEvaluatorAlwaysFalse），必须用 `is`。
func _repair_soft_reloaded_members() -> void:
	if not (_instance_render_buffer is RID): _instance_render_buffer = RID()
	if not (_instance_pick_buffer is RID): _instance_pick_buffer = RID()
	if not (_batch_header_buffer is RID): _batch_header_buffer = RID()
	if not (_instance_dispatch_buffer is RID): _instance_dispatch_buffer = RID()
	if not (_terrain_buffer is RID): _terrain_buffer = RID()
	if not (_wg_counts_buffer is RID): _wg_counts_buffer = RID()
	if not (_wg_offsets_buffer is RID): _wg_offsets_buffer = RID()
	if not (_terrain_content_key is String): _terrain_content_key = ""
	if not (_last_reason is String): _last_reason = "never_emitted"


## 挂到 runtime 的 RenderingDevice 上（借用，不接管所有权）。
func attach_to_runtime(runtime: RefCounted) -> bool:
	_repair_soft_reloaded_members()
	if runtime == null:
		_last_reason = "runtime_null"
		return false
	var rd: RenderingDevice = runtime.get_rendering_device()
	if rd == null:
		_last_reason = "no_rendering_device"
		return false
	if not attach_rendering_device(rd, false):
		_last_reason = "attach_rendering_device_failed"
		return false
	_runtime = runtime
	_last_reason = "never_emitted"
	return true


func last_reason() -> String:
	if not (_last_reason is String):
		_last_reason = ""
	return _last_reason


# ---------------------------------------------------------------------------
# 地形高度场（常驻，内容 key 守卫）
# ---------------------------------------------------------------------------

## 注入地形高度场并常驻。与 VoxelPickGPU._ensure_terrain_buffer 同形：内容 key 相同即空转，
## 不同才重传。存在的理由：emit kernel 要做地形 rebase，而放置管线今天没有 GPU 常驻的
## 高度场（SPA 在 _seed_terrain_collision_field 里算完就丢），补那条 plumbing 要改 SPA。
## 未注入时 emit 不猜——直接用常驻 transform 的平 Y，并把每行的 TERRAIN_REBASED 位置 0，
## 让消费者知道"这行的 Y 与画面可能不一致"，而不是拿到一个看着合法、实际差上百单位的 OBB。
func set_terrain_height_field(values: PackedFloat32Array, resolution: int, content_key: String) -> bool:
	_repair_soft_reloaded_members()
	if _rd == null:
		return false
	if resolution <= 0 or values.size() < resolution * resolution:
		push_error("[AutoObjectInstanceRenderer] set_terrain_height_field(): 高度场与分辨率不匹配（res=%d，需要 %d 个采样，实得 %d）—— 不截断、不补零。" % [
			resolution, resolution * resolution, values.size()])
		assert(false, "AutoObjectInstanceRenderer.set_terrain_height_field: size/resolution mismatch")
		return false
	if _terrain_buffer.is_valid() and _terrain_content_key == content_key and _terrain_resolution == resolution:
		return true
	if _terrain_buffer.is_valid():
		release_rid(_terrain_buffer)
		_terrain_buffer = RID()
	_terrain_buffer = storage_buffer_from_floats(values, SCOPE_PERSISTENT, "autoobject_emit_terrain_height")
	if not _terrain_buffer.is_valid():
		_terrain_content_key = ""
		_terrain_resolution = 0
		return false
	_terrain_content_key = content_key
	_terrain_resolution = resolution
	_terrain_revision += 1
	# 高度场变了 ⇒ 已 emit 的行的 Y 全部过期，下一次 sync 必须重跑而不是按 revision 空转。
	_emitted_revision = -1
	return true


func has_terrain_height_field() -> bool:
	_repair_soft_reloaded_members()
	return _terrain_buffer.is_valid() and _terrain_resolution > 0


# ---------------------------------------------------------------------------
# emit
# ---------------------------------------------------------------------------

## 按需重跑 emit。`options` 键：
##   mesh_description_buffer : RID   （必填，ScenePlacementRuntime 拥有，借用）
##   batch_count             : int   （必填，= 已注册资产数）
##   grid_origin / voxel_size: Vector3
##   camera_position         : Vector3
##   cull_distance           : float （<= 0 关闭距离剔除）
##   camera_move_epsilon     : float （相机位移小于它即视作没动，默认 1.0）
##   default_color           : Color
##   force                   : bool  （无视 revision 守卫强制重跑）
##
## 返回 `{ok, reason, emitted, revision, instance_capacity, batch_count}`。
## `emitted=false` 且 `ok=true` 表示"没变化，空转"——这是正常且期望的多数路径。
func sync(options: Dictionary = {}) -> Dictionary:
	_repair_soft_reloaded_members()
	if _runtime == null or _rd == null:
		_last_reason = "not_attached"
		return {"ok": false, "reason": _last_reason, "emitted": false}
	if not _runtime.is_ready():
		_last_reason = "runtime_not_ready"
		return {"ok": false, "reason": _last_reason, "emitted": false}

	var mesh_description_buffer: RID = options.get("mesh_description_buffer", RID())
	var batch_count := int(options.get("batch_count", 0))
	if not mesh_description_buffer.is_valid() or batch_count <= 0:
		# 没有资产就没有批：这是"还没注册资产"的正常状态，不是错误，但也绝不能当成
		# "emit 成功、只是没实例"——后者会让点选把该域报成"测了没命中"。
		_last_reason = "no_registered_assets"
		_emitted_ok = false
		return {"ok": false, "reason": _last_reason, "emitted": false}

	var camera_position: Vector3 = options.get("camera_position", Vector3.ZERO)
	var cull_distance := float(options.get("cull_distance", 0.0))
	var camera_epsilon := float(options.get("camera_move_epsilon", 1.0))
	var revision := int(_runtime.get_object_revision())
	var force := bool(options.get("force", false))

	var camera_moved := cull_distance > 0.0 \
		and _emitted_camera.distance_to(camera_position) > maxf(camera_epsilon, 0.0)
	if not force and _emitted_ok and _emitted_revision == revision \
		and _batch_capacity >= batch_count and not camera_moved:
		return {
			"ok": true, "reason": "unchanged", "emitted": false,
			"revision": revision, "instance_capacity": _instance_capacity, "batch_count": batch_count,
		}

	var object_capacity := int(_runtime.max_objects)
	if not _ensure_buffers(object_capacity, batch_count):
		_emitted_ok = false
		return {"ok": false, "reason": _last_reason, "emitted": false}
	if not _ensure_kernel():
		_emitted_ok = false
		return {"ok": false, "reason": _last_reason, "emitted": false}

	# batch_header 与 instance_dispatch 必须在 compute list 之外清零：它们在 pass 0 里是
	# atomicAdd 的目标，同趟清零会与计数竞争。instance_render / instance_pick 则由 pass 0
	# 自己清（在 GPU 上清 5 MB 比从 CPU 上传 5 MB 的零便宜得多）。
	if not buffer_zero(_batch_header_buffer, _batch_capacity * BATCH_STRIDE_BYTES):
		_last_reason = "batch_header_clear_failed"
		_emitted_ok = false
		return {"ok": false, "reason": _last_reason, "emitted": false}
	if not buffer_zero(_instance_dispatch_buffer, DISPATCH_BYTES):
		_last_reason = "instance_dispatch_clear_failed"
		_emitted_ok = false
		return {"ok": false, "reason": _last_reason, "emitted": false}

	var terrain_enabled := has_terrain_height_field()
	# 保序槽位永远开：关掉它就是让拾取 ID 每次 emit 重新洗牌（见 shader 文件头「槽位即身份」）。
	# 这里不做成可配置项——一个"能把点选悄悄弄错"的开关不该存在于生产路径上。
	var option_bits := OPT_STABLE_SLOTS
	if terrain_enabled:
		option_bits |= OPT_TERRAIN
	if cull_distance > 0.0:
		option_bits |= OPT_CULL

	var set0 := _make_runtime_set()
	var set1 := _make_output_set(mesh_description_buffer)
	if not set0.is_valid() or not set1.is_valid():
		gc_scope(SCOPE_PASS)
		_last_reason = "uniform_set_failed"
		_emitted_ok = false
		push_error("[AutoObjectInstanceRenderer] sync(): uniform set 创建失败（set0=%s, set1=%s）—— 不继续 dispatch。" % [
			set0.is_valid(), set1.is_valid()])
		assert(false, "AutoObjectInstanceRenderer.sync: uniform set create failed")
		return {"ok": false, "reason": _last_reason, "emitted": false}

	var grid_origin: Vector3 = options.get("grid_origin", Vector3.ZERO)
	var voxel_size: Vector3 = options.get("voxel_size", Vector3.ONE)
	var default_color: Color = options.get("default_color", Color(1.0, 1.0, 1.0, 1.0))
	var shared_push := {
		object_capacity = object_capacity,
		batch_count = batch_count,
		instance_capacity = _instance_capacity,
		pass_index = PASS_COUNT,
		option_bits = option_bits,
		terrain_res = _terrain_resolution if terrain_enabled else 0,
		object_revision = revision,
		_pad0 = 0,
		camera_x = camera_position.x, camera_y = camera_position.y, camera_z = camera_position.z,
		cull_distance = cull_distance,
		grid_origin_x = grid_origin.x, grid_origin_y = grid_origin.y, grid_origin_z = grid_origin.z,
		_pad1 = 0.0,
		voxel_size_x = voxel_size.x, voxel_size_y = voxel_size.y, voxel_size_z = voxel_size.z,
		_pad2 = 0.0,
		color_r = default_color.r, color_g = default_color.g, color_b = default_color.b,
		color_a = default_color.a,
	}

	# count 的线程数要同时盖住 object_capacity（计数）与 instance_capacity（清行）。
	var count_groups := dispatch_groups_1d(maxi(object_capacity, _instance_capacity), LOCAL_SIZE_X)
	var scatter_groups := dispatch_groups_1d(object_capacity, LOCAL_SIZE_X)

	var count_push: Dictionary = shared_push.duplicate()
	var prefix_push: Dictionary = shared_push.duplicate()
	prefix_push["pass_index"] = PASS_PREFIX
	var wg_scan_push: Dictionary = shared_push.duplicate()
	wg_scan_push["pass_index"] = PASS_WG_SCAN
	var scatter_push: Dictionary = shared_push.duplicate()
	scatter_push["pass_index"] = PASS_SCATTER

	var passes := [
		_kernel.make_pass_sets([set0, set1], count_push, count_groups),
		_kernel.make_pass_sets([set0, set1], prefix_push, Vector3i(1, 1, 1)),
		# wg_scan：把 count 写的 wg_counts 逐批独占扫描成 wg_offsets。单工作组。
		_kernel.make_pass_sets([set0, set1], wg_scan_push, Vector3i(1, 1, 1)),
		_kernel.make_pass_sets([set0, set1], scatter_push, scatter_groups),
	]
	# barrier_between=true：prefix 读的是 count 的 atomicAdd 结果，wg_scan 读的是 count 写的
	# wg_counts，scatter 读的是 prefix 写的 instance_start 与 wg_scan 写的 wg_offsets。
	# 少一道屏障的症状是批次起点或批内名次是上一轮的值——静默错位。
	var ok: bool = ComputePassChainScript.run(self, passes, true, true, true)
	gc_scope(SCOPE_PASS)
	if not ok:
		_last_reason = "dispatch_failed"
		_emitted_ok = false
		return {"ok": false, "reason": _last_reason, "emitted": false}

	_emitted_revision = revision
	_emitted_camera = camera_position
	_emitted_ok = true
	_last_reason = "ok"
	return {
		"ok": true, "reason": "ok", "emitted": true,
		"revision": revision, "instance_capacity": _instance_capacity, "batch_count": batch_count,
	}


# ---------------------------------------------------------------------------
# 交接口
# ---------------------------------------------------------------------------

## 统一点选 pass 的 AutoObject 域只读借用（契约见交接计划 §4.5）。
##
## 借用语义：调用方**只读**，永不 free、永不 buffer_update；这些 RID 的生命周期归本类。
## 缓存必须连 `revision` 一起比对，**不能只看 RID 数值**——容量按 next_power_of_2 增长时
## RID 会换，而"内容变了但容量没变"只有 revision 表达得出来。
##
## `resident=false` 与 `resident=true 但 live_count==0` 是两回事，调用方必须分开处理：
## 前者是"AutoObject 域压根没测"（还没 emit 过 / 无已注册资产 / RD 不可用），
## 后者是"测了，场景里没有实例"。把前者读成后者会让点选谎报该域为空。
func get_instance_pick_handoff() -> Dictionary:
	_repair_soft_reloaded_members()
	var resident := _emitted_ok \
		and _instance_pick_buffer.is_valid() \
		and _instance_dispatch_buffer.is_valid() \
		and _batch_header_buffer.is_valid()
	if not resident:
		return {"ok": true, "resident": false, "reason": last_reason()}
	return {
		"ok": true,
		"resident": true,
		"reason": "ok",
		"rd_instance_id": _rd.get_instance_id() if _rd != null else 0,
		"revision": _emitted_revision,
		"instance_pick_buffer": _instance_pick_buffer,
		"instance_dispatch_buffer": _instance_dispatch_buffer,
		"batch_header_buffer": _batch_header_buffer,
		"record_stride_bytes": PICK_STRIDE_BYTES,
		"batch_header_stride_bytes": BATCH_STRIDE_BYTES,
		"batch_count": _batch_capacity,
		"instance_capacity": _instance_capacity,
		"dispatch_local_size_x": LOCAL_SIZE_X,
		"live_count_word_index": D_LIVE_COUNT,
		"terrain_rebased": has_terrain_height_field(),
		"flags": {
			"alive": FLAG_ALIVE,
			"selected": FLAG_SELECTED,
			"culled": FLAG_CULLED,
			"terrain_rebased": FLAG_TERRAIN_REBASED,
		},
	}


## 绘制载荷借用：`PlacedInstanceDisplay` 用它把 GPU 字节送进 MultiMesh。
## 与 pick handoff 分开是因为消费者不同、设备约束也不同（模式 b 要求主设备）。
func get_instance_render_handoff() -> Dictionary:
	_repair_soft_reloaded_members()
	if not _emitted_ok or not _instance_render_buffer.is_valid():
		return {"ok": true, "resident": false, "reason": last_reason()}
	return {
		"ok": true,
		"resident": true,
		"reason": "ok",
		"rd_instance_id": _rd.get_instance_id() if _rd != null else 0,
		"revision": _emitted_revision,
		"instance_render_buffer": _instance_render_buffer,
		"batch_header_buffer": _batch_header_buffer,
		"record_stride_bytes": RENDER_STRIDE_BYTES,
		"batch_header_stride_bytes": BATCH_STRIDE_BYTES,
		"batch_count": _batch_capacity,
		"instance_capacity": _instance_capacity,
	}


## 诊断回读：batch_header 全表。**只用于调试与检查套件**，不在渲染或点选路径上。
func readback_batch_headers() -> Array[Dictionary]:
	_repair_soft_reloaded_members()
	var out: Array[Dictionary] = []
	if not _batch_header_buffer.is_valid() or _batch_capacity <= 0:
		return out
	var bytes := read_buffer_bytes(_batch_header_buffer, 0, _batch_capacity * BATCH_STRIDE_BYTES)
	if bytes.size() < _batch_capacity * BATCH_STRIDE_BYTES:
		return out
	for b in range(_batch_capacity):
		var base := b * BATCH_STRIDE_BYTES
		out.append({
			"instance_start": bytes.decode_u32(base + B_INSTANCE_START * 4),
			"instance_count": bytes.decode_u32(base + B_INSTANCE_COUNT * 4),
			"profile_id": bytes.decode_u32(base + B_PROFILE_ID * 4),
			"asset_index": bytes.decode_u32(base + B_ASSET_INDEX * 4),
			"capacity": bytes.decode_u32(base + B_CAPACITY * 4),
			"revision": bytes.decode_u32(base + B_REVISION * 4),
			"cursor": bytes.decode_u32(base + B_CURSOR * 4),
			"flags": bytes.decode_u32(base + B_FLAGS * 4),
		})
	return out


## 诊断回读：单条 instance_pick 记录。**只用于调试与检查套件**——生产路径上消费者
## 直接在 GPU 上读这块 buffer，绝不回读。
## 用于验证契约本身（字段解码是否落在正确的字上），因此按 GLSL_CONSTANTS 的字下标解码，
## 而不是重新写一套偏移——重写一套正是"某字段读出隔壁字段的值"那类错位的来源。
func readback_pick_record(slot: int) -> Dictionary:
	_repair_soft_reloaded_members()
	if not _instance_pick_buffer.is_valid() or slot < 0 or slot >= _instance_capacity:
		return {}
	var bytes := read_buffer_bytes(_instance_pick_buffer, slot * PICK_STRIDE_BYTES, PICK_STRIDE_BYTES)
	if bytes.size() < PICK_STRIDE_BYTES:
		return {}
	var f := func(word: int) -> float: return bytes.decode_float(word * 4)
	var u := func(word: int) -> int: return int(bytes.decode_u32(word * 4))
	return {
		"row0": [f.call(P_ROW0 + 0), f.call(P_ROW0 + 1), f.call(P_ROW0 + 2), f.call(P_ROW0 + 3)],
		"row1": [f.call(P_ROW1 + 0), f.call(P_ROW1 + 1), f.call(P_ROW1 + 2), f.call(P_ROW1 + 3)],
		"row2": [f.call(P_ROW2 + 0), f.call(P_ROW2 + 1), f.call(P_ROW2 + 2), f.call(P_ROW2 + 3)],
		"color": [f.call(P_COLOR + 0), f.call(P_COLOR + 1), f.call(P_COLOR + 2), f.call(P_COLOR + 3)],
		"obb_center": Vector3(f.call(P_OBB_CENTER + 0), f.call(P_OBB_CENTER + 1), f.call(P_OBB_CENTER + 2)),
		"yaw": f.call(P_OBB_YAW),
		"obb_half_extent": Vector3(f.call(P_OBB_HALF + 0), f.call(P_OBB_HALF + 1), f.call(P_OBB_HALF + 2)),
		"bounding_radius": f.call(P_OBB_RADIUS),
		"object_id": u.call(P_OBJECT_ID),
		"profile_id": u.call(P_PROFILE_ID),
		"batch_index": u.call(P_BATCH_INDEX),
		"flags": u.call(P_FLAGS),
		"voxel_min": Vector3i(u.call(P_VOXEL_MIN_X + 0), u.call(P_VOXEL_MIN_X + 1), u.call(P_VOXEL_MIN_X + 2)),
		"asset_index": u.call(P_ASSET_INDEX),
	}


## 诊断回读：槽位身份表（slot → object_id / batch_index / flags）。
## **只用于调试与检查套件**，不在渲染或点选路径上。
##
## ⚠ 别用 `readback_pick_record(slot)` 循环代替本函数：那个访问器每次调用都是一趟
## 独立的阻塞 `buffer_get_data`，几千个槽位就是几千趟同步往返（编辑器表现为分钟级假死）。
## 这里整块读一次再在 CPU 上切片，一趟解决。
##
## 返回 `{ok, slot_count, object_ids, batch_indices, flags}`；三个数组同长同序，
## 下标即槽位下标 —— 而槽位下标就是拾取 ID（`pick_id = pick_id_base + INSTANCE_ID`），
## 所以这张表就是「谁在哪个槽」的全量快照，是核验「槽位即身份」不变量的原始素材。
func readback_slot_identity(slot_count: int = -1) -> Dictionary:
	_repair_soft_reloaded_members()
	var empty := {
		"ok": false, "slot_count": 0,
		"object_ids": PackedInt32Array(), "batch_indices": PackedInt32Array(),
		"flags": PackedInt32Array(),
	}
	if not _instance_pick_buffer.is_valid() or _instance_capacity <= 0:
		return empty
	var wanted := _instance_capacity if slot_count < 0 else mini(slot_count, _instance_capacity)
	if wanted <= 0:
		return empty
	var bytes := read_buffer_bytes(_instance_pick_buffer, 0, wanted * PICK_STRIDE_BYTES)
	if bytes.size() < wanted * PICK_STRIDE_BYTES:
		return empty
	var object_ids := PackedInt32Array()
	var batch_indices := PackedInt32Array()
	var flags := PackedInt32Array()
	object_ids.resize(wanted)
	batch_indices.resize(wanted)
	flags.resize(wanted)
	for slot in range(wanted):
		var base := slot * PICK_STRIDE_BYTES
		object_ids[slot] = int(bytes.decode_u32(base + P_OBJECT_ID * 4))
		batch_indices[slot] = int(bytes.decode_u32(base + P_BATCH_INDEX * 4))
		flags[slot] = int(bytes.decode_u32(base + P_FLAGS * 4))
	return {
		"ok": true, "slot_count": wanted,
		"object_ids": object_ids, "batch_indices": batch_indices, "flags": flags,
	}


## 诊断回读：存活实例数。**只用于调试与检查套件**——生产路径上消费者应绑
## instance_dispatch 做间接派发，绝不回读它。
func readback_live_count() -> int:
	_repair_soft_reloaded_members()
	if not _instance_dispatch_buffer.is_valid():
		return -1
	var bytes := read_buffer_bytes(_instance_dispatch_buffer, 0, DISPATCH_BYTES)
	if bytes.size() < DISPATCH_BYTES:
		return -1
	return int(bytes.decode_u32(D_LIVE_COUNT * 4))


func get_status_report() -> Dictionary:
	_repair_soft_reloaded_members()
	return {
		"attached": _runtime != null and _rd != null,
		"emitted_ok": _emitted_ok,
		"reason": last_reason(),
		"revision": _emitted_revision,
		"instance_capacity": _instance_capacity,
		"batch_count": _batch_capacity,
		"terrain_resident": has_terrain_height_field(),
		"terrain_resolution": _terrain_resolution,
		"terrain_revision": _terrain_revision,
		"render_stride_bytes": RENDER_STRIDE_BYTES,
		"pick_stride_bytes": PICK_STRIDE_BYTES,
		"batch_header_stride_bytes": BATCH_STRIDE_BYTES,
	}


# ---------------------------------------------------------------------------
# 内部
# ---------------------------------------------------------------------------

func _ensure_kernel() -> bool:
	if not (_kernel is RefCounted):
		_kernel = null
	if _kernel != null and _kernel.is_valid():
		return true
	_kernel = ComputeKernelScript.create(self, SHADER_PATH, EMIT_PUSH, "autoobject_emit_instances", SCOPE_PERSISTENT)
	if _kernel == null or not _kernel.is_valid():
		_kernel = null
		_last_reason = "shader_unavailable"
		push_error("[AutoObjectInstanceRenderer] _ensure_kernel(): shader/pipeline 创建失败（%s）—— 不继续 dispatch。" % SHADER_PATH)
		assert(false, "AutoObjectInstanceRenderer._ensure_kernel: kernel create failed")
		return false
	return true


## 容量按 next_power_of_2 增长。⚠ 只增不减：缩容会让消费者缓存的 RID 失效而它们只在
## revision 变化时才重建 uniform set，缩容带来的收益抵不上那类偶发悬挂。
func _ensure_buffers(object_capacity: int, batch_count: int) -> bool:
	var wanted_instances := maxi(nearest_po2(maxi(object_capacity, 1)), 64)
	var wanted_batches := maxi(batch_count, 1)
	# ⚠ 工作组数按 **object_capacity** 算，不是按 instance_capacity：wg_counts / wg_offsets
	# 的下标来自 scatter 的派发（覆盖 object_capacity），而 count 趟为了顺带清 instance 行
	# 派发得更大。shader 里的 object_workgroup_count() 守住这条，两侧必须一致。
	var wanted_workgroups := maxi((maxi(object_capacity, 1) + LOCAL_SIZE_X - 1) / LOCAL_SIZE_X, 1)
	if _instance_render_buffer.is_valid() and _instance_pick_buffer.is_valid() \
		and _batch_header_buffer.is_valid() and _instance_dispatch_buffer.is_valid() \
		and _wg_counts_buffer.is_valid() and _wg_offsets_buffer.is_valid() \
		and _instance_capacity >= wanted_instances and _batch_capacity >= wanted_batches \
		and _wg_capacity >= wanted_workgroups:
		return true

	_release_output_buffers()
	_instance_capacity = wanted_instances
	_batch_capacity = wanted_batches
	_wg_capacity = wanted_workgroups
	# instance_render / instance_pick 每轮由 pass 0 整块覆写，故用 uninitialized；
	# batch_header 与 instance_dispatch 是 atomic 目标与部分写入，必须零初始化。
	_instance_render_buffer = storage_buffer_uninitialized(
		_instance_capacity * RENDER_STRIDE_BYTES, SCOPE_PERSISTENT, "autoobject_instance_render")
	_instance_pick_buffer = storage_buffer_uninitialized(
		_instance_capacity * PICK_STRIDE_BYTES, SCOPE_PERSISTENT, "autoobject_instance_pick")
	_batch_header_buffer = storage_buffer_zero(
		_batch_capacity * BATCH_STRIDE_BYTES, SCOPE_PERSISTENT, "autoobject_batch_header")
	_instance_dispatch_buffer = _create_dispatch_buffer()
	# wg_counts / wg_offsets 每轮由 count 与 wg_scan 对每个 (工作组, 批) 全覆写，故 uninitialized。
	_wg_counts_buffer = storage_buffer_uninitialized(
		_wg_capacity * _batch_capacity * 4, SCOPE_PERSISTENT, "autoobject_wg_counts")
	_wg_offsets_buffer = storage_buffer_uninitialized(
		_wg_capacity * _batch_capacity * 4, SCOPE_PERSISTENT, "autoobject_wg_offsets")
	if not _instance_render_buffer.is_valid() or not _instance_pick_buffer.is_valid() \
		or not _batch_header_buffer.is_valid() or not _instance_dispatch_buffer.is_valid() \
		or not _wg_counts_buffer.is_valid() or not _wg_offsets_buffer.is_valid():
		_release_output_buffers()
		_instance_capacity = 0
		_batch_capacity = 0
		_wg_capacity = 0
		_last_reason = "buffer_create_failed"
		push_error("[AutoObjectInstanceRenderer] _ensure_buffers(): 输出缓冲分配失败（instances=%d, batches=%d, workgroups=%d）。" % [
			wanted_instances, wanted_batches, wanted_workgroups])
		assert(false, "AutoObjectInstanceRenderer._ensure_buffers: buffer create failed")
		return false
	# 容量变了 ⇒ 旧内容全部作废，下一次 sync 必须真跑。
	_emitted_revision = -1
	_emitted_ok = false
	return true


## instance_dispatch 必须带 DISPATCH_INDIRECT 用途位，否则消费者无法 dispatch_indirect 它。
## 基类的 dispatch_indirect_args_buffer_zero() 只给 12 字节（3 个 group 数），这里要 16——
## 第 4 个字是 live_count，消费者在 shader 内做边界判定用，省掉一次回读。
func _create_dispatch_buffer() -> RID:
	if _rd == null:
		return RID()
	var bytes := PackedByteArray()
	bytes.resize(DISPATCH_BYTES)
	var rid: RID = _rd.storage_buffer_create(
		DISPATCH_BYTES, bytes, RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT)
	if not rid.is_valid():
		return RID()
	return track_rid(rid, KIND_BUFFER, SCOPE_PERSISTENT, "autoobject_instance_dispatch")


func _release_output_buffers() -> void:
	for rid in [_instance_render_buffer, _instance_pick_buffer, _batch_header_buffer,
			_instance_dispatch_buffer, _wg_counts_buffer, _wg_offsets_buffer]:
		if rid is RID and rid.is_valid():
			release_rid(rid)
	_instance_render_buffer = RID()
	_instance_pick_buffer = RID()
	_batch_header_buffer = RID()
	_instance_dispatch_buffer = RID()
	_wg_counts_buffer = RID()
	_wg_offsets_buffer = RID()
	_wg_capacity = 0


## set 0 = 借用的 runtime 常驻状态。每轮重建（SCOPE_PASS）而不是缓存：runtime 的
## configure_capacity 会重建全部 buffer，缓存的 set 会指向已释放的 RID，而那种悬挂
## 在驱动层不一定报错，可能直接读到垃圾变换。emit 不是每帧跑，重建成本可忽略。
func _make_runtime_set() -> RID:
	var shader: RID = _kernel.shader
	return create_uniform_set([
		make_storage_uniform(0, _runtime.get_gpu_buffer("alive")),
		make_storage_uniform(1, _runtime.get_gpu_buffer("profile")),
		make_storage_uniform(2, _runtime.get_gpu_buffer("object_flags")),
		make_storage_uniform(3, _runtime.get_gpu_buffer("asset_index")),
		make_storage_uniform(4, _runtime.get_gpu_buffer("bounds_min")),
		make_storage_uniform(5, _runtime.get_gpu_buffer("transform")),
	], shader, 0, SCOPE_PASS, "autoobject_emit_runtime_set")


func _make_output_set(mesh_description_buffer: RID) -> RID:
	var shader: RID = _kernel.shader
	var terrain_rid := _terrain_buffer
	if not terrain_rid.is_valid():
		# 未注入高度场时绑一个 1 元占位：GLSL 侧的 binding 是静态声明的，缺绑定会让
		# uniform set 创建直接失败。占位不会被读到（option_bits 的 TERRAIN 位为 0）。
		terrain_rid = storage_buffer_zero(4, SCOPE_PASS, "autoobject_emit_terrain_placeholder")
	track_borrowed_rid(mesh_description_buffer, KIND_BUFFER, SCOPE_PASS, "borrow:mesh_description")
	return create_uniform_set([
		make_storage_uniform(0, _instance_render_buffer),
		make_storage_uniform(1, _instance_pick_buffer),
		make_storage_uniform(2, _batch_header_buffer),
		make_storage_uniform(3, _instance_dispatch_buffer),
		make_storage_uniform(4, mesh_description_buffer),
		make_storage_uniform(5, terrain_rid),
		make_storage_uniform(6, _wg_counts_buffer),
		make_storage_uniform(7, _wg_offsets_buffer),
	], shader, 1, SCOPE_PASS, "autoobject_emit_output_set")


func _on_before_dispose() -> void:
	_runtime = null
	_kernel = null
	_emitted_ok = false


# ---------------------------------------------------------------------------
# GLSL 生成块 SSOT 接口（与 UnifiedPickGPU / PlacementSharedGLSL 同形）
# ---------------------------------------------------------------------------

static func block_names() -> Array:
	return CONSUMERS.keys()


static func block(name: String) -> String:
	# 返回空串会让 glsl_gen_block_checks 把「区块名写错」误判成「区块正文恰好为空」。
	if not CONSUMERS.has(name):
		push_error("AutoObjectInstanceRenderer.block: 未知的生成块名 '%s'（已知: %s）" % [name, str(CONSUMERS.keys())])
		assert(false, "AutoObjectInstanceRenderer.block: unknown block name")
		return ""
	return layout_block().strip_edges()


## 从 GLSL_CONSTANTS 发射 GLSL 常量表正文。
static func layout_block() -> String:
	var lines := PackedStringArray()
	for row in GLSL_CONSTANTS:
		if not (row is Array) or row.is_empty():
			lines.append("")
			continue
		if row.size() == 1:
			lines.append(str(row[0]))
			continue
		lines.append("const %s %s = %s;" % [str(row[0]), str(row[1]), str(row[2])])
	return "\n".join(lines)
