@tool
class_name PlacementStageEnv
extends RefCounted

## ScenePlacementActor 的 test/demo 借用适配器。
## 它只缓存阶段产物，不创建或释放 SPA、RenderingDevice、committer 或 Volume。
## 阶段映射：
##   make                = 借用场景树中已 READY 的 SPA 与其 SceneSV 组件
##   ensure_sv_committed = S4 commit → 真实 SV dict + 常驻 complexity/collision 场（地形种子在创建时播入）
##   ensure_target_ready = S1 TargetSVLoader 烘焙字节 → S5 SPA.prepare_target_read_buffers_from_common_gpu
##   ensure_prefilter    = S6 SPA.run_autoobject_prefilter → 真实 resident anchor handoff（TOPK=16）
##   run_pipeline_once   = S5→S9 SPA.run_placement_pipeline 全链一轮（S8 GPU 直连 writeback + S9 commit）
##   dispose             = 只清理适配器 cache/session；所有借用 owner 均不释放
##
## ⚠ 生命周期契约：
## - 地形碰撞种子与网格配置由 SPA 在 _ready 中完成，本适配器不得覆盖。
## - run_pipeline_once 内部会重跑 S5（释放旧常驻 target 缓冲）与 S6，并 commit 推进 SV：
##   调用后 ensure_target_ready / ensure_prefilter 的缓存自动失效并在下次调用时重建。
## - 返回字典里的 RID / rendering_device 均为借用（owner=SPA / committer），调用方不得 free。
##
## 批 1 迁移映射（历史记录）：spa_test._run(fn) → suite.run(fn)；_pass/_fail →
## DemoCheckSuite.pass_result/fail_result；_cleanup_spa_and_nodes(spa, nodes) →
## DemoCheckSuite.cleanup_disposables([spa], nodes)。
## ⚠ `DemoCheckSuite` 与它的两个消费者已于 2026-08-07 删除（都只能经 `--script` 启动，
## 本仓禁跑 = 从来没跑过）。本文件**不是**检查代码：它是生产的
## `class_name PlacementStageEnv`，被 `scene_placement_actor` 与 `volume_score_demo`
## preload，只是住错了目录。

const TerrainInitializerScript := preload("res://scripts/terrain_initializer.gd")
const TerrainConfigScript := preload("res://scripts/terrain_config.gd")
const TargetSVLoaderScript := preload("res://scripts/target_sv_loader.gd")
const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")
const SceneVoxelTileStoreScript := preload("res://scripts/scene_voxel_tile_store.gd")
const ProfileRecordSchemaScript := preload("res://scripts/utils/profile_record_schema.gd")
const VariantUtilsScript := preload("res://scripts/utils/variant_utils.gd")

const SCORE_CACHE_KEY_FIELDS := [
	"current_sv_revision",
	"brush_revision",
	"target_revision",
	"profile_sample_revision",
	"asset_order_revision",
	"grid",
	"regions",
	"config",
	"rendering_device",
]

## 地形碰撞种子归一化默认上限：把种子拍平成 ~0.001 量级的"地面记号"。高度信息由
## height-relative 体素空间本身承载；旧默认（MAX_HEIGHT=120，种子=h/120）把高度写成
## 碰撞密度，collision_limit=0.5 硬门会拒掉全部高地候选（"只有盆地能长"的根因之一）。
## 已放置盖章（collision=1.0）的地上排斥不依赖种子量级，不受影响；批间互斥即靠此地上
## cur_col 路径维持。（地下不再判死：细筛已改为"地下一律不打分"，p.y<0 体素纯跳过、不计
## 物理门——见 score_anchor_asset_residual，故放置可能落到地表以下。）
const FLAT_SEED_NORMALIZE_MAX := 100000.0

var _host: Node = null
var _terrain: MeshInstance3D = null
var _terrain_height_field := PackedFloat32Array()
var _committer: SceneVoxelCommitter = null
var _spa: ScenePlacementActor = null
var _descriptors: Array[AssetDescriptor] = []
var _profile_ids: Array[int] = []

var _grid_size := Vector3i.ZERO
var _voxel_size := Vector3.ONE
var _grid_origin := Vector3.ZERO
var _capture_size := 0.0
var _prefilter_settings: Dictionary = {}

var _ready := false
var _fail_reason := ""
var _make_phases_ms := {}

## 阶段产物缓存（run_pipeline_once 后 target/prefilter 缓存失效，见类头契约）
var _sv_cache: Dictionary = {}
var _commit_summary: Dictionary = {}
var _target_common_cache: Dictionary = {}
var _target_cache: Dictionary = {}
var _prefilter_cache: Dictionary = {}
var _prefilter_cache_key: Dictionary = {}
var _place_session_common: Dictionary = {}
var _place_session_active := false
var _place_session_batch_index := 0


# ---------------------------------------------------------------------------
# S0 + S3 + S4 底座
# ---------------------------------------------------------------------------

## options 键（全部可选，缺省即 TargetSV/TerrainConfig 真实口径）：
##   descriptors: Array               — baked AssetDescriptor .tres（必传非空；场景 typed @export 来源）
##   grid_size / grid_origin / capture_size — 一律借 SPA 导出值（唯一事实源），传了不同值即
##                                      make 失败；TargetSV 的网格也收敛到同一份，
##                                      不再由 targetsv.texture_size/vertical_span 反推
##   voxel_y_size: float              — 默认 spa.voxel_size.y
##   autoobject_capacity: int         — 默认 1024（SPA gpu_runtime 容量）
##   require_terrain: bool            — 默认 true（找不到共享地形节点即 make 失败）
##   terrain_collision_normalize_max: float — 默认 FLAT_SEED_NORMALIZE_MAX（种子拍平成
##                                      ~0.001 地面记号；高度信息由 height-relative 空间承载，
##                                      不再冒充碰撞密度——旧 h/120 种子会让 collision_limit
##                                      硬门拒掉全部高地候选）
##   prefilter_settings: Dictionary   — 透传 SPA._apply_prefilter_settings（min_target_interest /
##                                      anchor_vertical_stride / min_prefilter_score / debug_read_anchors）
static func make(existing_spa: ScenePlacementActor, options := {}) -> RefCounted:
	var env := PlacementStageEnv.new()
	var make_t0_usec := Time.get_ticks_usec()
	var phase_t0_usec := make_t0_usec
	env._host = existing_spa
	env._spa = existing_spa
	if existing_spa == null:
		return env._make_fail("missing_scene_placement_actor")
	if not existing_spa.is_inside_tree():
		return env._make_fail("scene_placement_actor_not_in_tree")
	if not existing_spa.is_ready():
		return env._make_fail("scene_placement_actor_not_ready:%s" % existing_spa.lifecycle_state_name())

	env._committer = existing_spa.get_scene_voxel_committer()
	if env._committer == null:
		return env._make_fail("scene_placement_actor_committer_missing")
	if existing_spa.get_rendering_device() == null:
		return env._make_fail("scene_placement_actor_rendering_device_missing")

	# Grid metadata is borrowed from SPA, the single source of truth.
	env._grid_size = existing_spa.grid_size
	env._voxel_size = existing_spa.voxel_size
	env._grid_origin = existing_spa.grid_origin
	env._capture_size = existing_spa.capture_size
	if options.has("grid_size") and VoxelGeneral.vector3i_from_value(
			options.get("grid_size"), env._grid_size) != env._grid_size:
		return env._make_fail("grid_size_override_rejected")
	if options.has("grid_origin") and options.get("grid_origin") != env._grid_origin:
		return env._make_fail("grid_origin_override_rejected")
	if options.has("capture_size") and not is_equal_approx(
			float(options.get("capture_size")), env._capture_size):
		return env._make_fail("capture_size_override_rejected")
	env._prefilter_settings = (options.get("prefilter_settings", {}) as Dictionary).duplicate(true)
	env._make_phases_ms["grid_config"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	phase_t0_usec = Time.get_ticks_usec()

	# Terrain is borrowed only for demo diagnostics; SPA already seeded SceneSV.
	var require_terrain := bool(options.get("require_terrain", true))
	var terrain_result: Dictionary = TerrainInitializerScript.reuse_shared_terrain(existing_spa)
	if bool(terrain_result.get("ok", false)):
		env._terrain = terrain_result.get("terrain") as MeshInstance3D
		env._terrain_height_field = TerrainInitializerScript.terrain_height_field_from_mesh(
			env._terrain, env._grid_size.x, TerrainConfigScript.MAX_HEIGHT)
	elif require_terrain:
		return env._make_fail("terrain_unavailable:%s" % str(terrain_result.get("reason", "unknown")))
	else:
		push_warning("[PlacementStageEnv] no shared terrain (%s); terrain collision seed skipped" % str(terrain_result.get("reason", "unknown")))
	env._make_phases_ms["terrain_height_field"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	phase_t0_usec = Time.get_ticks_usec()

	# Descriptors are registered with the existing owner. Existing entries are
	# reused by identity/path so creating an adapter never duplicates the registry.
	var descriptors_to_register: Array = []
	var raw_descriptors: Array = options.get("descriptors", [])
	# descriptors 是 make 的必传项（见类头 options 契约"必传非空"）。旧代码缺省时悄悄
	# 改用 SPA 已注册表：调用方以为自己指定了资产集，实际跑的是别人注册剩下的那套。
	if raw_descriptors.is_empty():
		push_error("[PlacementStageEnv] make options.descriptors 为空 —— 资产集必须由调用方显式给出，不接受回退到 SPA 已注册表。")
		assert(false, "PlacementStageEnv: make() called without descriptors")
		return env._make_fail("no_descriptors_supplied")
	var existing_descriptors: Array[AssetDescriptor] = existing_spa.get_registered_descriptors()
	for raw_descriptor in raw_descriptors:
		var descriptor := raw_descriptor as AssetDescriptor
		if descriptor == null:
			# 旧实现 push_warning 后 continue：编辑器 placeholder（缺 @tool）导致的整份
			# 资产缺失会被吞掉，env 带着"少了几个资产"的注册表继续跑完整条链。
			push_error("[PlacementStageEnv] descriptors 含非 AssetDescriptor 条目（editor placeholder / 缺 @tool？）: %s" % str(raw_descriptor))
			assert(false, "PlacementStageEnv: non-AssetDescriptor entry in descriptors")
			return env._make_fail("non_asset_descriptor_entry")
		var mesh: Mesh = descriptor.get_mesh()
		if mesh == null:
			push_warning("[PlacementStageEnv] descriptor '%s' has no mesh; registered for scoring only" % str(descriptor.asset_id))
		# 描述符兜底的 canonical/单一入口：demo 层不得再自行替换或合成描述符（旧
		# volume_score_demo._registration_descriptors 的兜底会整份替换、丢掉真实采样，
		# 已删除并归一到此处）。只有注册后得 0 条 FINE 采样的描述符才需要兜底（细筛
		# ad_count==0 直接判 invalid → 永不过筛，且 0 记录资产可能触发放置管线坏
		# dispatch）——仅这种按 CLAUDE.md 规则从 mesh AABB 合成实心 collision 采样兜底。
		# ⚠ 关键：能产出 FINE 采样的资产**不**兜底，保留真实几何评分——既包括软地面
		# collision=0 但带真实 legacy 采样的草，也包括 Bake AD 只写 profile_samples
		# （collision 与 asset_voxels 皆空）的资产。幂等：合成后 collision 非空即跳过。
		if not _descriptor_has_fine_samples(descriptor) and mesh != null:
			descriptor.set_collision(_synthesize_aabb_collision_samples(mesh, env._voxel_size))
		# 走到这里说明连 mesh AABB 兜底都没能合成出采样（即无 mesh 又无任何采样）：
		# 该描述符注册后是 0 条可评分记录，细筛判 invalid、放置管线还可能被 0 记录资产
		# 带出坏 dispatch。旧实现只 push_warning 就照常注册，问题一路带到打分结果里。
		if not _descriptor_has_fine_samples(descriptor):
			push_error("[PlacementStageEnv] descriptor '%s' 产不出 FINE 采样（无 mesh 且无 collision/asset_voxels/profile_samples），0 条可评分记录。" % str(descriptor.asset_id))
			assert(false, "PlacementStageEnv: descriptor yields no FINE samples")
			return env._make_fail("descriptor_without_fine_samples:%s" % str(descriptor.asset_id))
		descriptors_to_register.append(descriptor)

	for descriptor in descriptors_to_register:
		var asset_index := existing_descriptors.find(descriptor)
		if asset_index < 0 and not descriptor.resource_path.is_empty():
			for i in range(existing_descriptors.size()):
				var registered := existing_descriptors[i]
				if registered != null and registered.resource_path == descriptor.resource_path:
					asset_index = i
					break
		var profile_id := existing_spa.get_profile_id_for_asset(asset_index) if asset_index >= 0 else -1
		if profile_id < 0:
			profile_id = existing_spa.register_asset(descriptor, descriptor.get_mesh())
			existing_descriptors = existing_spa.get_registered_descriptors()
		if profile_id < 0:
			return env._make_fail("register_asset_failed:%s" % str(descriptor.asset_id))
		env._descriptors.append(descriptor)
		env._profile_ids.append(profile_id)
	if env._descriptors.is_empty():
		return env._make_fail("no_descriptors_registered")
	env._make_phases_ms["register_assets"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	env._make_phases_ms["total"] = float(Time.get_ticks_usec() - make_t0_usec) / 1000.0

	env._ready = true
	return env


## 描述符能否产出 FINE（可评分）采样。collision 与 legacy asset_voxels 都会在
## get_profile_samples() 内派生出 FINE 采样，baked profile_samples 则直接带 FINE 标志；
## 三者皆无才是"注册后 0 条可评分记录"。按开销从低到高短路，避免对数万条采样的大资产
## 在此多跑一次全量 normalize（真正的归一化仍由注册链完成）。
static func _descriptor_has_fine_samples(descriptor: AssetDescriptor) -> bool:
	if descriptor == null:
		return false
	if not descriptor.get_collision().is_empty():
		return true
	if not descriptor.get_asset_voxels().is_empty():
		return true
	for raw_sample in descriptor.profile_samples:
		if not raw_sample is Dictionary:
			continue
		var flags := int((raw_sample as Dictionary).get("flags", 0))
		if (flags & ProfileRecordSchemaScript.SAMPLE_FLAG_FINE) != 0:
			return true
	return false


## 无可评分采样描述符的兜底足迹：按 mesh AABB 的**世界尺寸/体素尺寸**
## 逐轴求真实体素跨度（上限 4，防超大资产爆采样数），合成一组实心 canonical collision
## 采样（每格 strength/weight=1，容器注册期负责去重/clearance 烘焙）。⚠ 逐轴按世界尺度求跨度，
## 勿改回"最长轴归一 N 体素"——那会无视世界尺度把 1.7u 的草放大成 4×2×4 体素（16m）足迹、
## solid_collision 累加十几个 row-0 种子直接爆 collision_limit。本函数是描述符兜底足迹的唯一实现
## （demo 侧旧副本 _collision_span_for / _collision_samples_from_span 已删）。
static func _synthesize_aabb_collision_samples(mesh: Mesh, voxel_size: Vector3 = Vector3.ONE) -> Array:
	if mesh == null:
		return []
	var size := mesh.get_aabb().size
	var sx := clampi(int(ceil(size.x / maxf(voxel_size.x, 0.0001))), 1, 4)
	var sy := clampi(int(ceil(size.y / maxf(voxel_size.y, 0.0001))), 1, 4)
	var sz := clampi(int(ceil(size.z / maxf(voxel_size.z, 0.0001))), 1, 4)
	var samples: Array = []
	for x in range(sx):
		for y in range(sy):
			for z in range(sz):
				samples.append(ProfileRecordSchemaScript.make_collision_sample(
					Vector3i(x - int(sx / 2.0), y, z - int(sz / 2.0)), 1.0, 1.0))
	return samples


# ---------------------------------------------------------------------------
# S4：commit → 真实 SV dict + 常驻场
# ---------------------------------------------------------------------------

## 返回 {ok, sv, commit_summary, cached}；首次调用触发 commit_scene_voxels（零 pending
## 记录也是合法提交：发布 SV、创建常驻 field buffer 并播入地形种子）+ tile 缓冲上传
## （VPG same-type-exclusion / prefilter 契约要求 object-ref 缓冲常驻）。
func ensure_sv_committed() -> Dictionary:
	if not _ready:
		return _stage_fail("env_not_ready:%s" % _fail_reason)
	if not _sv_cache.is_empty():
		return {"ok": true, "sv": _sv_cache.duplicate(true), "commit_summary": _commit_summary.duplicate(true), "cached": true}
	var phases_ms := {}
	var phase_t0_usec := Time.get_ticks_usec()
	var commit_summary: Dictionary = _committer.commit_scene_voxels()
	phases_ms["commit_scene_voxels"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	if not bool(commit_summary.get("ok", false)):
		return _stage_fail("commit_scene_voxels_failed:%s" % str(commit_summary.get("field_scatter_reason", "unknown")))
	phase_t0_usec = Time.get_ticks_usec()
	if not _spa.ensure_svtile_gpu_ready(true):
		return _stage_fail("scene_voxel_tile_upload_failed")
	phases_ms["ensure_tile_buffers_uploaded"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	phases_ms["gpu_initialization_detail"] = _spa.get_svtile_initialization_phases_ms()
	phase_t0_usec = Time.get_ticks_usec()
	_sv_cache = _committer.get_sv()
	_commit_summary = commit_summary
	phases_ms["publish_cache"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	return {"ok": true, "sv": _sv_cache.duplicate(true), "commit_summary": commit_summary.duplicate(true), "cached": false, "phases_ms": phases_ms}


# ---------------------------------------------------------------------------
# S1：TargetSV 烘焙字节（placement_common 的 target 键对）
# ---------------------------------------------------------------------------

## 返回 {ok, target_visual_rgba8_bytes, target_collision_r8_bytes, voxel_count}。
## 键名为 prepare_target_read_buffers_from_common_gpu 的冻结契约键；
## "target_collision_r8_bytes" 是历史键名，内容按当前 u32 口径（unorm8-in-u32，
## 4 字节/体素，SceneVoxelTileCodec.u32_bytes_from_r8_bytes 转换）。
## Target 内容 = 盘上烘焙 TargetSV 点云（放置只在 target 标记处生成——2026-07-18
## 曾短暂改为全图合成 target，用户确认"没有 targetsv 的地方也生成了是问题"后回归；
## "全体量"的正解 = 铺满整个 target 体积，由拍平种子/足迹修复/并行选择达成）。
func target_common_bytes() -> Dictionary:
	if not _target_common_cache.is_empty():
		return _target_common_cache
	var voxel_count := VoxelGeneral.voxel_count(_grid_size)
	var visual_bytes: PackedByteArray = TargetSVLoaderScript.visual_bytes()
	var collision_r8: PackedByteArray = TargetSVLoaderScript.collision_bytes()
	if visual_bytes.size() != voxel_count * 4 or collision_r8.size() != voxel_count:
		return _stage_fail("target_sv_grid_mismatch:visual=%d collision=%d expected_voxels=%d" % [
			visual_bytes.size(), collision_r8.size(), voxel_count])
	var collision_u32 := SceneVoxelTileCodecScript.u32_bytes_from_r8_bytes(collision_r8, voxel_count)
	_target_common_cache = {
		"ok": true,
		"target_visual_rgba8_bytes": visual_bytes,
		"target_collision_r8_bytes": collision_u32,
		"voxel_count": voxel_count,
	}
	return _target_common_cache


# ---------------------------------------------------------------------------
# S1+S5：target 读缓冲准备（常驻 vec4 field + u32 collision，owner=SPA）
# ---------------------------------------------------------------------------

## 返回 SPA.prepare_target_read_buffers_from_common_gpu 的原始结果字典（含
## target_field_buffer / target_collision_buffer 常驻 RID，owner=ScenePlacementActor）。
## extra_settings 可透传 debug_read_target_read_buffer_bytes 等调试键。
func ensure_target_ready(extra_settings := {}) -> Dictionary:
	if not _target_cache.is_empty():
		return _target_cache
	var committed := ensure_sv_committed()
	if not bool(committed.get("ok", false)):
		return committed
	var common := target_common_bytes()
	if not bool(common.get("ok", false)):
		return common
	var settings: Dictionary = extra_settings.duplicate(true)
	settings["target_visual_rgba8_bytes"] = common.get("target_visual_rgba8_bytes", PackedByteArray())
	settings["target_collision_r8_bytes"] = common.get("target_collision_r8_bytes", PackedByteArray())
	var result: Dictionary = _spa.prepare_target_read_buffers_from_common_gpu(settings, _sv_cache)
	if not bool(result.get("ok", false)):
		return _stage_fail("target_read_buffers_failed:%s" % str(result.get("reason", "unknown")))
	_target_cache = result
	return result


# ---------------------------------------------------------------------------
# S6：probe prefilter → 真实 resident anchor handoff
# ---------------------------------------------------------------------------

## 返回 SPA.run_autoobject_prefilter 的原始结果字典（anchor_candidate_handoff 含
## anchor/count/topk 常驻 RID，owner=SPA._prefilter）。
## ⚠ 常驻场注入：run_autoobject_prefilter 不做 run_placement_pipeline Phase 0 的
## resident field handoff——committed sv 已无 CPU field，必须把 committer 常驻对
## 注入 sv（resident-or-error，与 SPA 私有 handoff 消费的是同一对 buffer）。
## 参数（批 3 扩参，向后兼容）：
##   prefilter_settings_override — 覆盖 make options 的 prefilter_settings（同键调用方优先；
##                                 debug_read_anchors 等诊断键由此透传）
## 增量范围由 SPA 的 GPU dirty worklist 唯一表达；adapter 不接受 CPU tile id。
## 缓存按**解析后**的 prefilter 有效设置键控（见 _prefilter_cache_key_from）。
func ensure_prefilter(prefilter_settings_override := {}) -> Dictionary:
	var effective_settings: Dictionary = _prefilter_settings.duplicate(true)
	for key in prefilter_settings_override:
		effective_settings[key] = prefilter_settings_override[key]
	var cache_key := _prefilter_cache_key_from(effective_settings)
	if not _prefilter_cache.is_empty() and _prefilter_cache_key == cache_key:
		return _prefilter_cache
	var target := ensure_target_ready()
	if not bool(target.get("ok", false)):
		return target
	# 幂等保证 SPA-owned persistent SVTile buffers 已就绪。
	_spa.ensure_svtile_gpu_ready(false)
	var complexity_rid: RID = _spa.get_svtile_gpu_buffer(
		SceneVoxelTileStoreScript.SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER)
	var collision_rid: RID = _spa.get_svtile_gpu_buffer(
		SceneVoxelTileStoreScript.SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER)
	if not complexity_rid.is_valid() or not collision_rid.is_valid():
		return _stage_fail("committer_resident_field_rid_invalid")
	var sv := _sv_cache.duplicate()
	sv["resident_complexity_field_read_rid"] = complexity_rid
	sv["resident_collision_field_read_rid"] = collision_rid
	var result: Dictionary = _spa.run_autoobject_prefilter(sv, _target_cache, effective_settings)
	if not bool(result.get("ok", false)):
		return _stage_fail("prefilter_failed:%s" % str(result.get("reason", "unknown")))
	_prefilter_cache = result
	_prefilter_cache_key = cache_key.duplicate(true)
	return result


## prefilter 缓存键：只由 prefilter **真正消费**的设置构成
## （ScenePlacementRuntime._apply_prefilter_settings 的全集）。
##
## ⚠ 别改回"直接拿调用方的 override 字典当键"。两个调用方传的形状本就不同：
## Score 传 {min_target_interest, min_prefilter_score, debug_read_anchors,
## decode_anchor_dictionaries}，Place 预热（prepare_place_ready）把整份 placement_common
## 转手传进来，多出 rotation_slots / result_capacity / min_distance_voxels /
## collision_limit / clearance_limit 这些 prefilter 根本不看的键。按原始字典比对两者
## 永远不等 ⇒ 每次 Score 之后的 Place 预热都白跑一整轮全图 prefilter，换出一批语义
## 完全相同的新 anchor 缓冲，还顺带把刚发布的 Fine 常驻交接判成过期。
static func _prefilter_cache_key_from(effective_settings: Dictionary) -> Dictionary:
	var key := {}
	for setting_key in ["min_target_interest", "anchor_vertical_stride", "min_prefilter_score"]:
		if effective_settings.has(setting_key):
			key[setting_key] = effective_settings[setting_key]
	# 这两个键缺席时 _apply_prefilter_settings 会强制写回默认值（而不是沿用实例旧值），
	# 所以键里必须补上解析后的默认，否则 {} 与显式传默认值会被当成两种设置。
	var debug_read_anchors := bool(effective_settings.get("debug_read_anchors", false))
	key["debug_read_anchors"] = debug_read_anchors
	key["profile_timing"] = bool(effective_settings.get("profile_timing", false))
	# decode_anchor_dictionaries 只决定"回读到的锚点字节要不要再解成 Dictionary"。
	# 没开 debug_read_anchors 时回读本身就是空的，这个开关对结果零影响——不进键，
	# 免得两条只差它的调用互相踢掉对方的缓存。
	if debug_read_anchors:
		key["decode_anchor_dictionaries"] = bool(
			effective_settings.get("decode_anchor_dictionaries", true))
	return key


# ---------------------------------------------------------------------------
# S5→S9：全链一轮
# ---------------------------------------------------------------------------

## placement_common 透传 SPA.run_placement_pipeline（rotation_slots / result_capacity /
## collision_limit / clearance_limit / min_distance_voxels 等 VPG 设置键由调用方给出，
## 缺省走 VPG 默认）；env 只补 target 字节对（调用方已给同名键则尊重调用方）。
## ⚠ 调用后 target/prefilter 缓存失效（pipeline 内部重跑 S5/S6 并释放旧常驻 target 缓冲），
## sv 缓存从 committer 刷新（S9 commit 推进了常驻场与 tick）。
func run_pipeline_once(placement_common := {}) -> Dictionary:
	var session := begin_place_session(placement_common)
	if not bool(session.get("ok", false)):
		return session
	var result := run_place_session_batch(
		placement_common.get("reduce_seed_placements", PackedFloat32Array()))
	end_place_session()
	return result


## Starts a persistent Place session over the existing stage environment. The
## target payload, target RIDs, registered profiles, and stable settings remain
## shared across batches; only seed placements and committed SV state advance.
func begin_place_session(placement_common := {}) -> Dictionary:
	if _place_session_active:
		end_place_session()
	var committed := ensure_sv_committed()
	if not bool(committed.get("ok", false)):
		return committed
	var common := target_common_bytes()
	if not bool(common.get("ok", false)):
		return common
	var settings: Dictionary = placement_common.duplicate()
	if not settings.has("target_visual_rgba8_bytes"):
		settings["target_visual_rgba8_bytes"] = common.get("target_visual_rgba8_bytes", PackedByteArray())
	if not settings.has("target_collision_r8_bytes"):
		settings["target_collision_r8_bytes"] = common.get("target_collision_r8_bytes", PackedByteArray())
	var target := ensure_target_ready()
	if not bool(target.get("ok", false)):
		return target
	_place_session_common = settings
	_place_session_active = true
	_place_session_batch_index = 0
	return {
		"ok": true,
		"target_revision": int(target.get("target_revision", -1)),
		"target_cached": bool(target.get("cached", false)),
		"stable_common_deep_copy_bytes": 0,
	}


func run_place_session_batch(reduce_seed_placements := PackedFloat32Array()) -> Dictionary:
	if not _place_session_active:
		return _stage_fail("place_session_not_active")
	var total_t0_usec := Time.get_ticks_usec()
	var phase_t0_usec := total_t0_usec
	var orchestration_phases_ms := {}
	var settings := _place_session_common.duplicate()
	settings["reduce_seed_placements"] = reduce_seed_placements
	settings["incremental_fine_reset"] = _place_session_batch_index == 0
	# ── 会话作用域的两个显式开关（都只在首批为「重来」，之后为「沿用」）──────────
	# 1. 余隙场：首批重建成零场并把传进来的种子（= 上一次 Place 留下的物件）烘进去；
	#    之后各批复用同一张场，本批被接受的放置由 GPU 侧的 paint pass 直接累积上去。
	settings["clearance_field_reset"] = _place_session_batch_index == 0
	# 2. 锚点池：首批正常采集，之后**显式复用常驻锚点缓冲**。
	#    ⚠ 别改成"把 dirty_epoch 从 collect 缓存键里删掉"。锚点缓冲本身是常驻的，逼它
	#    逐批重采的是缓存键：每批盖章推进 dirty_epoch ⇒ 键变 ⇒ collect 在**已被上一批
	#    消费清空**的脏清单上重跑 ⇒ 锚点池逐批塌缩（实测格点门开着时 3878/7 批塌到
	#    365/36 批）。而 Anchors/Score 路径要靠这个 epoch 在场景变化时刷新，不能删。
	#    所以复用做成会话作用域的显式开关：只有 Place 会话的非首批会带上它。
	settings["reuse_resident_anchors"] = _place_session_batch_index > 0
	# 格点门的相位逐批推进。相位空间是 interval² 个格位，走法必须同时满足两条：
	#   1. **相邻批次的相位要远** —— 否则本批格点落在上批物体的碰撞足迹内，整批被
	#      seed 冲突挡光。实测教训：光栅走位（phase_x 每批 +1）让批 1 只离批 0 一个体素，
	#      产出直接归零，还会被"零产出即收敛"误判成放满。
	#   2. **不重复、不遗漏** —— interval² 轮之内正好走完全部格位。
	# 用「与 interval² 互质的步长做模乘」即可：模乘是完全置换（保证 2），步长取黄金比例
	# 附近的互质数（保证 1）。比低差异序列简单，且覆盖性是可证的而不是统计的。
	var anchor_interval := maxi(int(settings.get("anchor_interval_voxels", 0)), 0)
	if anchor_interval > 0:
		var phase_space := anchor_interval * anchor_interval
		var idx := (_place_session_batch_index * _phase_stride(phase_space)) % phase_space
		settings["anchor_phase_x"] = idx % anchor_interval
		settings["anchor_phase_z"] = int(idx / anchor_interval)
	orchestration_phases_ms["settings"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	var t0_usec := Time.get_ticks_usec()
	var result: Dictionary = _spa.run_placement_pipeline(_sv_cache, settings)
	var wall_usec := Time.get_ticks_usec() - t0_usec
	phase_t0_usec = Time.get_ticks_usec()
	var target_buffers: Dictionary = result.get("target_read_buffers", {})
	result["place_session"] = {
		"active": true,
		"batch_index": _place_session_batch_index,
		"wall_usec": wall_usec,
		"target_revision": int(target_buffers.get("target_revision", -1)),
		"target_cache_hit": bool(target_buffers.get("cached", false)),
		"seed_count": int((reduce_seed_placements as PackedFloat32Array).size() / 4) \
			if reduce_seed_placements is PackedFloat32Array else 0,
		"stable_common_deep_copy_bytes": 0,
	}
	orchestration_phases_ms["session_result"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	phase_t0_usec = Time.get_ticks_usec()
	_place_session_batch_index += 1
	# TargetSV is immutable during the session. Placement commits only invalidate
	# CurrentSV-derived prefilter data; the target RID handoff stays resident.
	invalidate_prefilter_cache()
	_sv_cache = _committer.get_sv()
	orchestration_phases_ms["cache_advance"] = float(Time.get_ticks_usec() - phase_t0_usec) / 1000.0
	orchestration_phases_ms["total"] = float(Time.get_ticks_usec() - total_t0_usec) / 1000.0
	var session_detail: Dictionary = result["place_session"]
	session_detail["orchestration_phases_ms"] = orchestration_phases_ms
	session_detail["environment_wall_usec"] = Time.get_ticks_usec() - total_t0_usec
	return result


func end_place_session() -> void:
	_place_session_common = {}
	_place_session_active = false
	_place_session_batch_index = 0


## Prepares every persistent resource required by a ready-state Place sample.
## No placement is dispatched and no committed SceneVoxel state is changed.
func prepare_place_ready(placement_common := {}) -> Dictionary:
	var target := ensure_target_ready()
	if not bool(target.get("ok", false)):
		return target
	var prefilter := ensure_prefilter(placement_common)
	if not bool(prefilter.get("ok", false)):
		return prefilter
	var pipeline := _spa.prepare_place_pipeline()
	if not bool(pipeline.get("ok", false)):
		return _stage_fail("place_pipeline_prepare_failed:%s" % str(pipeline.get("reason", "unknown")))
	return {
		"ok": true,
		"reason": "ok",
		"target_revision": int(target.get("target_revision", -1)),
		"anchor_count": int(prefilter.get("anchor_count", 0)),
		"place_pipeline": pipeline,
	}


## Restores the empty placement fixture while preserving env/SPA/RD/profile,
## target buffers, compiled pipelines, and owner object identities.
func reset_place_fixture() -> Dictionary:
	if not _ready or _spa == null or _committer == null:
		return _stage_fail("environment_not_ready")
	end_place_session()
	var target_before := ensure_target_ready()
	var field_reset: Dictionary = _committer.reset_empty_fixture_state()
	if not bool(field_reset.get("ok", false)):
		return _stage_fail("committer_fixture_reset_failed:%s" % str(field_reset.get("reason", "unknown")))
	var runtime: GPUAutoObjectRuntime = _spa.get_gpu_runtime()
	var runtime_reset: Dictionary = runtime.reset_state() if runtime != null else {
		"ok": false,
		"reason": "gpu_runtime_missing",
	}
	if not bool(runtime_reset.get("ok", false)):
		return _stage_fail("gpu_runtime_fixture_reset_failed:%s" % str(runtime_reset.get("reason", "unknown")))
	_sv_cache = _committer.get_sv()
	_commit_summary = field_reset.get("commit", {})
	invalidate_prefilter_cache()
	var target_after := ensure_target_ready()
	var target_field_before: RID = target_before.get("target_field_buffer", RID())
	var target_field_after: RID = target_after.get("target_field_buffer", RID())
	var target_collision_before: RID = target_before.get("target_collision_buffer", RID())
	var target_collision_after: RID = target_after.get("target_collision_buffer", RID())
	var target_rids_preserved: bool = (
		target_field_before == target_field_after
		and target_collision_before == target_collision_after
	)
	return {
		"ok": target_rids_preserved,
		"reason": "ok" if target_rids_preserved else "target_rid_changed_during_fixture_reset",
		"field_reset": field_reset,
		"runtime_reset": runtime_reset,
		"target_rids_preserved": target_rids_preserved,
		"target_revision": int(target_after.get("target_revision", -1)),
	}


# ---------------------------------------------------------------------------
# 生命周期 / 访问器
# ---------------------------------------------------------------------------

## 手动使 S5/S6 缓存失效（真实操作按键反复触发的 demo——scenevoxeltile 批 4——用）。
## sv 缓存不清：调用方经 refresh_sv() 显式刷新。
func invalidate_stage_caches() -> void:
	_target_cache = {}
	invalidate_prefilter_cache()


## 仅失效 S6 prefilter，保留同一份 S5 resident target buffers。性能基准与真实
## dirty-region 重跑用它隔离 anchor 成本，避免把 target prepare 混进每个样本。
func invalidate_prefilter_cache() -> void:
	_prefilter_cache = {}
	_prefilter_cache_key = {}


## 从 committer 重新拉取已提交 SV（外部经 committer 直接做过 stamp/commit 后调用）。
func refresh_sv() -> Dictionary:
	# committer 缺失时旧代码返回 {} 且保留旧 _sv_cache：调用方拿到空字典当"没变化"，
	# 后续阶段继续吃陈旧 SV。env ready 即 committer 在位，缺了就是生命周期被破坏。
	if _committer == null:
		push_error("[PlacementStageEnv] refresh_sv 时 committer 缺失（env 已 dispose 或从未 ready？ready=%s reason=%s）。" % [
			str(_ready), _fail_reason])
		assert(false, "PlacementStageEnv: refresh_sv without committer")
		return {}
	_sv_cache = _committer.get_sv()
	return _sv_cache.duplicate(true)


## Only adapter-local caches are cleared. SPA and all GPU owners are borrowed.
func dispose() -> void:
	end_place_session()
	invalidate_stage_caches()
	_target_common_cache = {}
	_sv_cache = {}
	_commit_summary = {}
	_spa = null
	_committer = null
	_descriptors.clear()
	_profile_ids.clear()
	_terrain = null
	_host = null
	_ready = false


func is_ready() -> bool:
	return _ready


func fail_reason() -> String:
	return _fail_reason


func get_make_phases_ms() -> Dictionary:
	return _make_phases_ms.duplicate(true)


func get_spa() -> ScenePlacementActor:
	return _spa


func get_committer() -> SceneVoxelCommitter:
	return _committer


func get_terrain() -> MeshInstance3D:
	return _terrain


func get_terrain_height_field() -> PackedFloat32Array:
	return _terrain_height_field


func get_descriptors() -> Array[AssetDescriptor]:
	return _descriptors.duplicate()


func get_profile_ids() -> Array[int]:
	return _profile_ids.duplicate()


func get_grid_size() -> Vector3i:
	return _grid_size


func get_voxel_size() -> Vector3:
	return _voxel_size


func get_grid_origin() -> Vector3:
	return _grid_origin


## Score/anchor 热路径只需要网格元数据。不要为读取这四个标量对完整 SV 做
## duplicate(true)；_sv_cache 为空表示尚未提交，调用方应回退 ensure_sv_committed。
func get_committed_sv_metadata() -> Dictionary:
	if _sv_cache.is_empty():
		return {}
	return {
		"grid_size": _sv_cache.get("grid_size", _grid_size),
		"voxel_size": _sv_cache.get("voxel_size", _voxel_size),
		"grid_origin": _sv_cache.get("grid_origin", _grid_origin),
		"tile_grid_size": _sv_cache.get("tile_grid_size", Vector3i.ZERO),
		"commit_tick": int(_sv_cache.get("commit_tick", 0)),
		"generation_tick": int(_sv_cache.get("generation_tick", 0)),
	}


## Builds the complete Score model cache key from existing authorities. This is
## a control-plane snapshot only; no GPU payload or field bytes are copied.
func build_score_cache_key(region_rects: Array, settings: Dictionary) -> Dictionary:
	if not _ready:
		return {}
	var target := ensure_target_ready()
	if not bool(target.get("ok", false)):
		return {}
	var profile_summary: Dictionary = _spa.get_runtime_profile_container().get_gpu_buffer_summary()
	var descriptor_order: Array = []
	for descriptor in _descriptors:
		# 旧代码把 null 描述符编码成 ["",0]：两个不同的坏注册表会算出同一个 key，
		# Score 模型缓存于是命中错误的模型。注册期已拒 null，这里出现即状态被破坏。
		if descriptor == null:
			push_error("[PlacementStageEnv] build_score_cache_key 遇到 null 描述符（_descriptors.size=%d），缓存键无法唯一标识资产顺序。" % _descriptors.size())
			assert(false, "PlacementStageEnv: null descriptor in score cache key")
			return {}
		descriptor_order.append([descriptor.resource_path, descriptor.get_instance_id()])
	var regions: Array = []
	for raw_rect in region_rects:
		var rect: Rect2i = raw_rect
		regions.append([rect.position.x, rect.position.y, rect.size.x, rect.size.y])
	var rd: RenderingDevice = _spa.get_rendering_device()
	# rd 缺失时旧代码把 rendering_device 字段写 0：换了设备的两份 key 会互相"命中"，
	# 缓存里的 GPU 模型指向已消失的设备。make 时已校验 rd 非空。
	if rd == null:
		push_error("[PlacementStageEnv] build_score_cache_key 取不到 SPA RenderingDevice，缓存键无法标识 GPU 设备身份。")
		assert(false, "PlacementStageEnv: score cache key without rendering device")
		return {}
	return {
		"current_sv_revision": [
			int(_sv_cache.get("commit_tick", 0)),
			int(_sv_cache.get("generation_tick", 0)),
		],
		"brush_revision": _spa.get_brush_sv_revision(),
		"target_revision": int(target.get("target_revision", -1)),
		"profile_sample_revision": [
			int(profile_summary.get("gpu_revision", -1)),
			int(profile_summary.get("staging_revision", -1)),
			int(profile_summary.get("uploaded_revision", -1)),
		],
		"asset_order_revision": [descriptor_order, _profile_ids.duplicate()],
		"grid": [_grid_size, _voxel_size, _grid_origin],
		"regions": regions,
		"config": settings.duplicate(true),
		"rendering_device": rd.get_instance_id(),
	}


static func score_cache_key_matches(lhs: Dictionary, rhs: Dictionary) -> bool:
	for field in SCORE_CACHE_KEY_FIELDS:
		if not lhs.has(field) or not rhs.has(field):
			return false
		if typeof(lhs[field]) != typeof(rhs[field]) or lhs[field] != rhs[field]:
			return false
	return true


func get_committed_sv() -> Dictionary:
	return _sv_cache.duplicate(true)


# ---------------------------------------------------------------------------
# 内部
# ---------------------------------------------------------------------------

# ⚠ 这里曾有 `_terrain_base_collision_image(normalize_max)`：高度场 → 地形基底碰撞图
# （R32F）的测试夹具。种子语义本就全在生产侧（terrain_collision_volume.glsl /
# field_builder._resample_collision_field），它只是一层打包胶水，调用方已随重构消失，
# 全仓零调用（2026-08-17 删除）。要重建请从生产侧那两处取语义，别照这份胶水抄。


## make 半途失败：只记录原因；借用 owner 永不由适配器释放。
func _make_fail(reason: String) -> RefCounted:
	_fail_reason = reason
	_ready = false
	push_error("[PlacementStageEnv] make failed: %s" % reason)
	_spa = null
	_committer = null
	return self


## 阶段失败统一出口：push_error + 规范失败字典（不缓存失败结果）。
func _stage_fail(reason: String) -> Dictionary:
	push_error("[PlacementStageEnv] %s" % reason)
	return {"ok": false, "reason": reason, "gpu_first": true, "cpu_fallback": false}


## 相位置换的步长：取 ≈0.618 * phase_space 且与之互质的最大值。
## 互质 ⇒ 模乘是完全置换（interval² 轮走完全部相位，不重不漏）；
## 靠近黄金比例 ⇒ 连续几批的相位在空间上尽量分散（避免被上一批的足迹挡光）。
static func _phase_stride(phase_space: int) -> int:
	if phase_space <= 2:
		return 1
	var candidate := int(round(float(phase_space) * 0.6180339887498949))
	candidate = clampi(candidate, 1, phase_space - 1)
	while candidate > 1 and _gcd(candidate, phase_space) != 1:
		candidate -= 1
	return maxi(candidate, 1)


static func _gcd(a: int, b: int) -> int:
	while b != 0:
		var t := b
		b = a % b
		a = t
	return absi(a)
