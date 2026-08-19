class_name VoxelPlacementGenerator


extends "res://scripts/godot_compute_shader_base.gd"
## Anchor-origin residual-gain GPU placement.
##
## Consumes the probe prefilter's resident anchor handoff (anchor_buf +
## anchor_count_buf + per-anchor asset top-K) and the profile container's
## resident profile_sample_records, then runs one GPU chain over ALL assets:
##   fine_score_dispatch_finalize -> score_anchor_asset_residual (indirect)
##   -> init/map Anchor candidates -> atomic conflict invalidation -> compact
##   -> init_stamp_bounds
##   -> stamp_asset_voxels (mixed-asset).
## origin_count == anchor_count (origin_contract "one_origin_per_anchor");
## the candidate score is the five-dimension residual gain
## D(CurrentSV, TargetSV) - D(compose(CurrentSV, AD), TargetSV), with no-op as
## the implicit baseline (valid requires score_gain > gain threshold).
## The old Candidate route / tile / 512-origin machinery is gone.

const VoxelPlacementWritebackScript := preload("res://scripts/voxel_placement_writeback.gd")
const BufferUtils := preload("res://scripts/utils/buffer_utils.gd")
const VariantUtils := preload("res://scripts/utils/variant_utils.gd")
const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")
const VoxelPlacementTargetReaderScript := preload("res://scripts/voxel_placement_target_reader.gd")
const VoxelPlacementStateChainScript := preload("res://scripts/voxel_placement_state_chain.gd")
const VoxelPlacementOutputScript := preload("res://scripts/voxel_placement_output.gd")
const DebugBufferSetScript := preload("res://scripts/utils/debug_buffer_set.gd")
const ScoreTimingProfilerScript := preload("res://scripts/utils/score_timing_profiler.gd")
const ReportSchema := preload("res://scripts/utils/report_schema.gd")
const PlacementResultCodec := preload("res://scripts/utils/placement_result_codec.gd")
const ProfileArenaLayoutScript := preload("res://scripts/utils/profile_arena_layout.gd")

var _placement_writeback = null

## Lazily creates the delegated placement writeback helper.
func _ensure_placement_writeback():
	if _placement_writeback == null:
		_placement_writeback = VoxelPlacementWritebackScript.new()
		_placement_writeback._generator = self
	if not _placement_writeback._rd and _rd:
		_placement_writeback.attach_rendering_device(_rd, false)
	return _placement_writeback


func _on_before_dispose() -> void:
	if _placement_writeback == null:
		return
	_placement_writeback._generator = null
	_placement_writeback.dispose()
	_placement_writeback = null


const RECORD_STRIDE := 4
const DELTA_STRIDE := 2
const STAMP_BOUNDS_STRIDE := 2
## _decode_score_contract_debug 读到的最高槽位下标 22（profile_pivot_count）+ 1；
## 回读字数低于此值即为截断，硬失败而非逐槽补 0。
const SCORE_CONTRACT_DEBUG_MIN_WORDS := 23
# Fixed fine-score dispatch width; must match the prefilter's anchor grid so
# anchor_id decodes identically on both sides (see prefilter ANCHOR_GRID_X).
const ANCHOR_GRID_X := 256
const MAX_ASSETS := 256
const SCORE_SUM_SHADER_PATH := "res://shaders/placement_result_score_sum.glsl"
const GPU_RUNTIME_PROVIDER_CONFIG_KEY := "gpu_autoobject_runtime"
const GPU_PROFILE_CONTAINER_CONFIG_KEY := "auto_voxel_runtime_profile_container"
const REQUIRED_GPU_RUNTIME_BUFFERS := [
	"alive",
	"generation",
	"object_type",
	"profile",
	"bounds_min",
	"bounds_max",
	"previous_bounds_min",
	"previous_bounds_max",
	"transform",
]
# 固定槽位 Arena 化后只剩一个：Header/Samples/Pivots/MeshDescription 同住一个 buffer。
const REQUIRED_GPU_PROFILE_BUFFERS := [
	"profile_arena",
]

# Push-constant schemas (std430, sequential scalars). See PushConstantLayout.
const FINE_FINALIZE_PUSH := [
	["anchor_grid_x", "uint"],    # 0
	["topk", "uint"],             # 4
	["anchor_capacity", "uint"],  # 8
	["_pad0", "uint"],            # 12
]
const FINE_WINNER_PUSH := [
	["topk", "uint"],             # 0
	["anchor_capacity", "uint"],  # 4
	["_pad0", "uint"],            # 8
	["_pad1", "uint"],            # 12
]
const FINE_SCORE_PUSH := [
	["grid_x", "int"],                  # 0
	["grid_y", "int"],                  # 4
	["grid_z", "int"],                  # 8
	["has_target", "int"],              # 12
	["voxel_size_x", "float"],          # 16
	["voxel_size_y", "float"],          # 20
	["voxel_size_z", "float"],          # 24
	["min_match_fraction", "float"],    # 28
	["rotation_slots", "int"],          # 32
	["topk", "int"],                    # 36
	["asset_count", "int"],             # 40
	["anchor_capacity", "int"],         # 44
	["solid_threshold", "float"],       # 48
	["collision_limit", "float"],       # 52
	["clearance_limit", "float"],       # 56
	["complexity_write_scale", "float"], # 60
	["collision_write_scale", "float"], # 64
	["dim_w_collision", "float"],       # 68
	["dim_w_complexity", "float"],      # 72
	["dim_w_color", "float"],           # 76
	["contract_enabled", "int"],        # 80
	["profile_count", "int"],           # 84
	["debug_write_mask", "int"],        # 88
	["_pad_meta", "int"],               # 92  (meta.w reserved)
	# capacities ivec4: host-passed buffer element counts for the shader's
	# capacity gates (replaces GLSL .length()/OpArrayLength, unsupported by
	# Godot's SPIR-V path).
	["asset_lookup_capacity", "int"],         # 96
	["profile_table_capacity", "int"],        # 100
	["profile_sample_record_capacity", "int"], # 104
	["pivot_records_capacity", "int"],        # 108
	# match_limits vec4: per-dimension strict-match budgets
	# (score_match_config.cfg; exceeding ANY one disqualifies the voxel).
	["color_match_max_l1", "float"],    # 112  (post-compose rgb vs target, L1 0..3)
	["collision_match_max", "float"],   # 116  (|pred_col - tgt_col| 0..1)
	["complexity_overfill_ratio", "float"], # 120  (1 + N/100; overfill-only asymmetric)
	["_pad_match", "float"],            # 124
]
const REDUCE_INIT_PUSH := [
	["topk", "int"],             # 0
	["anchor_capacity", "int"],  # 4
	["asset_count", "int"],      # 8   (was retired seed_count; init now needs it for clearance radii)
	["grid_x", "int"],           # 12
	["grid_z", "int"],           # 16
	["anchor_interval", "int"],  # 20  格点门间隔（体素）；<=0 关闭
	["anchor_phase_x", "int"],   # 24  本轮相位，[0, interval)
	["anchor_phase_z", "int"],   # 28
	["min_distance_voxels", "float"],   # 32  clearance query needs the pair-spacing knobs
	["asset_spacing_factor", "float"],  # 36
	["_padf0", "float"],         # 40
	["_padf1", "float"],         # 44
]
const REDUCE_NMS_PUSH := [
	["anchor_capacity", "int"],         # 0
	["asset_count", "int"],             # 4
	["grid_x", "int"],                  # 8
	["grid_z", "int"],                  # 12
	["min_distance_voxels", "float"],   # 16
	["asset_spacing_factor", "float"],  # 20
	["max_spacing_radius", "float"],    # 24
	["_padf0", "float"],                # 28
	# 格点步进：仲裁的邻居扫描按 interval 跨步只访问参赛者所在列。
	# ⚠ 必须与 REDUCE_INIT_PUSH 传给 init 的那组**逐位相同**——init 的格点门决定了
	# 哪些像素有参赛者，扫描按同一组相位跨步才不会漏掉任何一个。
	["anchor_interval", "int"],         # 32
	["anchor_phase_x", "int"],          # 36
	["anchor_phase_z", "int"],          # 40
	["_pad0", "int"],                   # 44
]
const REDUCE_COMPACT_PUSH := [
	["anchor_capacity", "int"],  # 0
	["result_capacity", "int"],  # 4
	["asset_count", "int"],      # 8   已退役（逐资产配额去掉后 shader 不再读），槽位保留
	["_pad0", "int"],            # 12
]
## 有符号余隙场的定点编码常量。⚠ 必须与 shaders/paint_placement_clearance.glsl 与
## shaders/init_anchor_atomic_reduce.glsl 里的同名 GLSL 常量逐位一致（那两处是画/查
## 两侧，这里只用于宿主侧的量程守卫）。
const CLEARANCE_FIXED_SCALE := 256.0
const CLEARANCE_BIAS_VOXELS := 64.0
## 有符号余隙场的**画**侧 push（shaders/paint_placement_clearance.glsl）。
## 记录源只剩 compact 出的 placement_results（stride=4，资产号在 [base+1].y，条数来自
## GPU 的 result_count）。曾有第二个源：CPU 种子表（stride=1，资产号在 .w，条数由 push
## 直接给）——跨轮互斥实为 fine score × 上轮盖章 SV 的职责（2026-08-19 用户裁决），
## 种子链已删；shader 侧模式位仍是有效契约、只是无人再用。
const PAINT_CLEARANCE_PUSH := [
	["record_capacity", "int"],         # 0
	["record_stride", "int"],           # 4   以 vec4 为单位
	["grid_x", "int"],                  # 8
	["grid_z", "int"],                  # 12
	["asset_count", "int"],             # 16
	["count_source", "int"],            # 20  0 = 读 count 缓冲；1 = 用 push_count
	["push_count", "int"],              # 24
	["asset_field", "int"],             # 28  0 = records[base+1].y；1 = records[base].w
	["min_distance_voxels", "float"],   # 32
	["asset_spacing_factor", "float"],  # 36
	["max_spacing_radius", "float"],    # 40
	["_padf0", "float"],                # 44
]
const STAMP_PUSH := [
	["grid_x", "int"],                  # 0
	["grid_y", "int"],                  # 4
	["grid_z", "int"],                  # 8
	["rotation_slots", "int"],          # 12
	["write_min_x", "int"],             # 16
	["write_min_y", "int"],             # 20
	["write_min_z", "int"],             # 24
	["profile_count", "int"],           # 28
	["write_max_x", "int"],             # 32
	["write_max_y", "int"],             # 36
	["write_max_z", "int"],             # 40
	["stamp_delta_capacity", "int"],    # 44
	["solid_threshold", "float"],       # 48
	["complexity_write_scale", "float"], # 52
	["collision_write_scale", "float"], # 56
	["dual_commit", "float"],           # 60
	["voxel_size_x", "float"],          # 64
	["voxel_size_y", "float"],          # 68
	["voxel_size_z", "float"],          # 72
	["_padf0", "float"],                # 76
	# capacities ivec4: host-passed buffer element counts for the shader's
	# capacity gates (replaces GLSL .length()/OpArrayLength, unsupported by
	# Godot's SPIR-V path).
	["profile_table_capacity", "int"],        # 80
	["profile_sample_record_capacity", "int"], # 84
	["pivot_records_capacity", "int"],        # 88
	["_pad0", "int"],                         # 92
]
const STAMP_INIT_PUSH := [
	["result_capacity", "int"],   # 0
	["stamp_bounds_stride", "int"], # 4
	["_pad0", "int"],             # 8
	["_pad1", "int"],             # 12
]
const PACK_TARGET_FIELD_PUSH := [
	["voxel_count", "int"],       # 0
	["_pad0", "int"],             # 4
	["_pad1", "int"],             # 8
	["_pad2", "int"],             # 12
]
const PACK_FIELD_PAIR_PUSH := [
	["voxel_count", "int"],       # 0
	["_pad0", "int"],             # 4
	["_pad1", "int"],             # 8
	["_pad2", "int"],             # 12
]
const PACK_SAMPLE_PAIRS_PUSH := [
	["voxel_count", "int"],       # 0
	["_pad0", "int"],             # 4
	["_pad1", "int"],             # 8
	["_pad2", "int"],             # 12
]
const SCORE_SUM_PUSH := [
	["result_capacity", "int"],   # 0
	["record_stride", "int"],     # 4
	["_pad0", "int"],             # 8
	["_pad1", "int"],             # 12
]

var result_capacity: int = 8
var solid_threshold: float = 192.0 / 255.0
# < 0 disables the physical feasibility gate in score_anchor_asset_residual: a
# candidate is no longer rejected for overlapping existing scene collision /
# clearance. Default off so placement (e.g. grass) is not blocked by prior scene
# occupancy; pass a non-negative collision_limit / clearance_limit in settings to
# re-enable the hard gate for cases that need it.
var collision_limit: float = -1.0
var clearance_limit: float = -1.0
var min_distance_voxels: float = 2.0
## Lattice gate: only anchors on the (phase + k*interval) lattice compete in a
## batch. The exact greedy score-NMS reduce no longer needs it for correctness
## (0 = off, every candidate competes in one batch); it survives as an optional
## batch-thinning aid.
var anchor_interval_voxels: int = 0
var anchor_phase_x: int = 0
var anchor_phase_z: int = 0
# Pairwise asset-size-aware spacing: reduce rejects a candidate when its
# distance to any seed/selected placement is below
# max(min_distance_voxels, (r_a + r_b) * asset_spacing_factor), r_* being the
# per-asset spacing radii (asset_def.spacing_radius_world / voxel xz size).
# 0 disables the pairwise term (flat min_distance only).
var asset_spacing_factor: float = 1.0
# Iteration budget for the greedy score-NMS reduce
# (arbitrate_anchor_conflicts.glsl). Converged rounds launch zero workgroups
# (the GPU zeroes its own indirect args), so over-provisioning is near free
# (~0.1-0.3 us per extra barrier cut).
# 预算耗尽 = **丢弃**（用户口径 2026-08-19，刻意语义而非兜底）：仍 UNDECIDED 的
# anchor 不被 compact 收走，既不放置也不参与后续裁决；由 reduce_nms_telemetry 的
# budget_exhausted + push_warning 报出，不是静默的。
# 实测轮数（2026-08-19）：全量 38009 锚点 → 59~62 轮（64 只剩个位数余量，且逐次会漂，
# 因为无序 atomicAdd 分配的 anchor id 正是同分决胜键）；Place 批 interval=12 → 21 轮。
# 轮数由冲突图里最长的优先级依赖链决定，与密度无关（ObjectReduce 实测：同分量化到
# 8 级 13→131 轮，单调得分梯度 13→136 轮，选中数 ×2.7 反而 13→12 轮）。
var reduce_nms_iter_budget: int = 64
var scene_write_scale: float = 1.0
var collision_write_scale: float = 1.0
var rotation_slots: int = 12
# Strict-match gate: a candidate is valid only when its signed full-footprint score
# exceeds this value. Occupied-target voxels passing the conjunctive test
# (color_ok && collision_ok && complexity_ok && improved) vote +weight; voxels
# landing on empty target vote -stamp_collision*weight. The sum is divided by the
# full in-grid footprint weight, so collision-free overshoot is neutral while
# off-target collision is penalized proportionally. Targetless runs
# (has_target == 0) reuse this slot as the legacy mean-gain threshold.
var min_match_fraction: float = 0.35
# Five-dimension weights [collision, complexity, color-per-channel] for the
# residual-gain term (the "improved" half of the match test + the tiebreak);
# the three color channels share one weight.
var dim_weight_collision: float = 1.0
var dim_weight_complexity: float = 1.0
var dim_weight_color: float = 0.34
# Per-dimension strict-match budgets: a footprint voxel only counts as matched
# when EVERY post-compose value stays within its budget vs TargetSV — exceeding
# any one of color / collision / complexity disqualifies the voxel. Defaults
# below are code fallbacks; the tunable source of truth is
# res://score_match_config.cfg (loaded each run, see _load_score_match_config),
# and a per-call settings dict still overrides both.
# color: L1 distance over rgb (0..3). 0.6 separates same-hue variation (~0.3)
# from cross-class writes (green foliage vs 0.33-grey cliff is ~1.33) — the
# hard "no green, no tree" gate that additive dim weights could never provide.
var color_match_max_l1: float = 0.6
# collision: |pred - target| (0..1). Target collision is near-binary, so 0.5
# permits half-step drift but rejects writing solid into no-collision target.
var collision_match_max: float = 0.5
# complexity: overfill-only asymmetric — allow post-compose complexity up to
# tgt.a * (1 + N/100). N is a percent (0 = exact/underfill only, no overfill); packed
# as the ratio 1 + N/100 into match_limits.z. Replaced the old absolute budget.
var complexity_overfill_percent: float = 20.0

## 上面那批评分/放置旋钮成员的**单一真相源**：成员名 → 声明初值。
## 拆成两张表不是为了分类好看，而是因为两者的消费方不同：
##   - FINE_SCORE_TUNING_DEFAULTS：进 FINE_SCORE_PUSH、决定细筛候选内容的旋钮。
##     既被 `_repair_soft_reloaded_members()` 用于软重载归位，也被 `_tuning_snapshot()`
##     整表快照进常驻候选缓冲的 cache key。
##   - REDUCE_TUNING_DEFAULTS：只作用于细筛**之后**的仲裁/压缩/盖章段的旋钮。
##     只被软重载归位消费，**刻意不进** cache key。
## ⚠ 为什么第二张表不能并进 cache key：`anchor_phase_x/z` 由 PlacementStageEnv 逐批改写
## （placement_stage_env.gd 的 `settings["anchor_phase_x"] = idx % anchor_interval`）。把
## 逐批变动的相位写进键 ⇒ `_ensure_resident_place_candidate_buffer` 每批都 key 不匹配 ⇒
## 每批 free + realloc 一次 SCOPE_PERSISTENT 候选缓冲（一次 Place 点击 144 批）。
## ⚠ 新增任何**影响细筛评分结果**的成员，必须登记进 FINE_SCORE_TUNING_DEFAULTS，否则
## 改该参数后 cache key 不变 → 静默复用上一批候选。新增只作用于仲裁段的旋钮登记进
## REDUCE_TUNING_DEFAULTS。两张表里同一个名字只应出现一次。
const FINE_SCORE_TUNING_DEFAULTS := {
	"solid_threshold": 192.0 / 255.0,
	"collision_limit": -1.0,
	"clearance_limit": -1.0,
	"scene_write_scale": 1.0,
	"collision_write_scale": 1.0,
	"rotation_slots": 12,
	"min_match_fraction": 0.35,
	"dim_weight_collision": 1.0,
	"dim_weight_complexity": 1.0,
	"dim_weight_color": 0.34,
	"color_match_max_l1": 0.6,
	"collision_match_max": 0.5,
	"complexity_overfill_percent": 20.0,
}
## ⚠ `reduce_nms_iter_budget` 刻意**不在**这张表里：它的声明初值是 64，而
## `_repair_soft_reloaded_members()` 的软重载归位值是 256（两者的分歧早于本次重构，
## 见该函数里保留的手写行）。表里只能放一个值，放哪个都会悄悄改掉另一处的行为，
## 所以留在手写行上，把分歧摆在明面而不是折进表里。
const REDUCE_TUNING_DEFAULTS := {
	"result_capacity": 8,
	"min_distance_voxels": 2.0,
	"anchor_interval_voxels": 0,
	"anchor_phase_x": 0,
	"anchor_phase_z": 0,
	"asset_spacing_factor": 1.0,
}

var _shader_fine_finalize: RID
var _shader_fine_score: RID
var _shader_fine_winner: RID
var _shader_reduce_init: RID
var _shader_reduce_arbitrate: RID
var _shader_reduce_compact: RID
var _shader_init_stamp_bounds: RID
var _shader_stamp: RID
var _shader_pack_field_pair: RID
var _shader_pack_sample_pairs: RID
var _shader_paint_clearance: RID
var _shader_score_sum: RID
var _pipeline_fine_finalize: RID
var _pipeline_fine_score: RID
var _pipeline_fine_winner: RID
var _pipeline_reduce_init: RID
var _pipeline_reduce_arbitrate: RID
var _pipeline_reduce_compact: RID
var _pipeline_init_stamp_bounds: RID
var _pipeline_stamp: RID
var _pipeline_pack_field_pair: RID
var _pipeline_pack_sample_pairs: RID
var _pipeline_paint_clearance: RID
var _pipeline_score_sum: RID
## 有符号余隙场（signed clearance field）：grid_x * grid_z 个 uint 的常驻 XZ 场。
## 每个被接受的放置在自己周围画一个圆锥（paint_placement_clearance.glsl），后续 anchor
## 只读自己那一格即可 O(1) 判跨批互斥（init_anchor_atomic_reduce.glsl 的 clearance 段）。
## 编码 0 = 未画 = 无约束 ⇒ 零填充即合法初值，重新分配零缓冲就等于清场，无需 clear pass。
## 生命周期：place session 作用域——`clearance_field_reset`（会话首批 / 未声明会话的
## 单发调用）重建零场，批间累积不清；跨轮互斥不靠它（fine score × 上轮盖章 SV）。
var _resident_clearance_field_buffer: RID
var _resident_clearance_field_bytes := 0
var _resident_place_candidate_buffer: RID
var _resident_place_candidate_buffer_bytes := 0
var _resident_place_candidate_cache_key: Dictionary = {}
var _resident_place_candidate_initialized := false
# Score（execution_mode=fine_candidates_only）的候选/胜出缓冲常驻交接：Score 只发布
# 借用 RID，点选与显示之后按需借用，热路径回读降到 anchor_count(4B) + contract counter。
# ⚠ 内容不跨 Score 复用（每轮整批重写），所以 cache key 只描述**形状**；形状不变就复用
# 同两块显存。释放点恰好三处：形状变化的下一次 Score、release_resident_score_handoff()、
# dispose。
var _resident_score_candidate_buffer: RID
var _resident_score_candidate_bytes := 0
var _resident_score_winner_buffer: RID
var _resident_score_winner_bytes := 0
var _resident_score_shape_key: Dictionary = {}


# ⚠ 编辑器软重载（@tool 脚本重新解析）后的成员修复，别当成冗余判空删掉。
# 事实依据（gdscript.cpp GDScriptInstance::reload_members）：软重载只把**重载前已存在**
# 的成员按名搬进新槽位（值原样保留）；本次重载**新增**的成员槽是 Variant = nil，声明里的
# 初始化器不会重跑，静态类型也拦不住。重载后第一次 Place 会炸在 `.is_valid()` /
# `.is_empty()` 这类"在 Nil 上找方法"的位置，阈值成员则以 nil 身份进 push constant。
# ⚠ 必须用 `is` 而不是 `== null`：Variant 给 (RID, NIL)、(FLOAT, NIL) 注册的是
# OperatorEvaluatorAlwaysFalse（variant_op.cpp），`x == null` 被编成恒 false。
# 语义：全部回到声明初值。归零的 shader/pipeline 句柄走既有"无效就重建"路径重编（不会
# free 假句柄）；常驻候选缓冲连同 bytes/cache_key/initialized 一起归零 ⇒ 下次 Place 重算
# （缓存只认"键相等才复用"，清空只多算一次，不会误命中旧内容）。
func _repair_soft_reloaded_members() -> void:
	# 旋钮成员整批按声明表归位。判据用 `typeof(...) != typeof(默认值)` 而不是 `== null`：
	# 与上面那条说明同因——(FLOAT, NIL) 的 == 被编成恒 false，判不出 nil。typeof() 读的是
	# Variant 的实际类型标签，nil 槽位返回 TYPE_NIL，与 TYPE_FLOAT/TYPE_INT 必不相等。
	# 覆盖面即两张表的并集；从前这里是手写清单，漏了 solid_threshold / rotation_slots /
	# 三个 dim_weight_* / 两个 write_scale / result_capacity / min_distance_voxels /
	# 格点门三件套等 12 个成员——登记表制之后不会再漏。
	for tuning_table in [FINE_SCORE_TUNING_DEFAULTS, REDUCE_TUNING_DEFAULTS]:
		for member_name in tuning_table:
			var declared_default = tuning_table[member_name]
			if typeof(get(member_name)) != typeof(declared_default):
				set(member_name, declared_default)
	# ⚠ 归位值 256 与声明初值 64 的分歧是既有状态，原样保留（见 REDUCE_TUNING_DEFAULTS
	# 上方说明）。要统一先决定哪个才是对的，不要顺手对齐。
	if not (reduce_nms_iter_budget is int): reduce_nms_iter_budget = 256
	if not (_shader_fine_winner is RID): _shader_fine_winner = RID()
	if not (_shader_reduce_init is RID): _shader_reduce_init = RID()
	if not (_shader_reduce_arbitrate is RID): _shader_reduce_arbitrate = RID()
	if not (_shader_reduce_compact is RID): _shader_reduce_compact = RID()
	if not (_shader_pack_field_pair is RID): _shader_pack_field_pair = RID()
	if not (_shader_pack_sample_pairs is RID): _shader_pack_sample_pairs = RID()
	if not (_shader_paint_clearance is RID): _shader_paint_clearance = RID()
	if not (_shader_score_sum is RID): _shader_score_sum = RID()
	if not (_pipeline_fine_winner is RID): _pipeline_fine_winner = RID()
	if not (_pipeline_reduce_init is RID): _pipeline_reduce_init = RID()
	if not (_pipeline_reduce_arbitrate is RID): _pipeline_reduce_arbitrate = RID()
	if not (_pipeline_reduce_compact is RID): _pipeline_reduce_compact = RID()
	if not (_pipeline_pack_field_pair is RID): _pipeline_pack_field_pair = RID()
	if not (_pipeline_pack_sample_pairs is RID): _pipeline_pack_sample_pairs = RID()
	if not (_pipeline_paint_clearance is RID): _pipeline_paint_clearance = RID()
	if not (_pipeline_score_sum is RID): _pipeline_score_sum = RID()
	# 场句柄归零 ⇒ _ensure_resident_clearance_field_buffer 重建一块零缓冲 = 一次清场。
	# 语义上等于"重载后这一批当会话首批"，不会读到半张旧场。
	if not (_resident_clearance_field_buffer is RID): _resident_clearance_field_buffer = RID()
	if not (_resident_clearance_field_bytes is int): _resident_clearance_field_bytes = 0
	if not (_resident_place_candidate_buffer is RID): _resident_place_candidate_buffer = RID()
	if not (_resident_place_candidate_buffer_bytes is int): _resident_place_candidate_buffer_bytes = 0
	if not (_resident_place_candidate_cache_key is Dictionary): _resident_place_candidate_cache_key = {}
	if not (_resident_place_candidate_initialized is bool): _resident_place_candidate_initialized = false
	if not (_resident_score_candidate_buffer is RID): _resident_score_candidate_buffer = RID()
	if not (_resident_score_candidate_bytes is int): _resident_score_candidate_bytes = 0
	if not (_resident_score_winner_buffer is RID): _resident_score_winner_buffer = RID()
	if not (_resident_score_winner_bytes is int): _resident_score_winner_bytes = 0
	if not (_resident_score_shape_key is Dictionary): _resident_score_shape_key = {}


## 细筛评分旋钮的当前值快照，供常驻候选缓冲的 cache key 使用。
## 键名逐字沿用成员名（历史 cache key 就是把这些成员摊平写的），登记表变化时快照自动跟随，
## 不需要再同步维护第二份清单。只读快照，不做任何钳制。
func _tuning_snapshot() -> Dictionary:
	var snapshot := {}
	for member_name in FINE_SCORE_TUNING_DEFAULTS:
		snapshot[member_name] = get(member_name)
	return snapshot


## Compiles the complete Place shader family without allocating per-run buffers
## or dispatching placement work. Scene bootstrap uses this before interaction
## timing so the first Place click does not own pipeline creation.
func prepare_placement_pipeline() -> Dictionary:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	log_name = "VoxelPlacementGenerator"
	if not ensure_device(true, false):
		return {
			"ok": false,
			"reason": "missing_rendering_device",
			"fine_pipeline_ready": false,
			"placement_pipeline_ready": false,
		}
	_load_shaders()
	var ready := _placement_pipeline_ready()
	return {
		"ok": ready,
		"reason": "ok" if ready else "placement_shader_pipeline_not_ready",
		"fine_pipeline_ready": _fine_pipeline_ready(),
		"placement_pipeline_ready": ready,
	}


func get_placement_pipeline_readiness() -> Dictionary:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	return {
		"ok": _placement_pipeline_ready(),
		"fine_pipeline_ready": _fine_pipeline_ready(),
		"placement_pipeline_ready": _placement_pipeline_ready(),
	}


func get_resource_lifecycle_summary() -> Dictionary:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	var scope_counts := {}
	var owned_count := 0
	var borrowed_count := 0
	var total_count := 0
	for entry in _resources:
		if not bool(entry.get("alive", false)):
			continue
		var scope := str(entry.get("scope", ""))
		scope_counts[scope] = int(scope_counts.get(scope, 0)) + 1
		total_count += 1
		if bool(entry.get("owned", OWNED)):
			owned_count += 1
		else:
			borrowed_count += 1
	return {
		"tracked_total": total_count,
		"tracked_owned": owned_count,
		"tracked_borrowed": borrowed_count,
		"scope_counts": scope_counts,
		"frame_count": int(scope_counts.get(SCOPE_FRAME, 0)),
		"pass_count": int(scope_counts.get(SCOPE_PASS, 0)),
		"persistent_count": int(scope_counts.get(SCOPE_PERSISTENT, 0)),
		"resident_candidate_valid": _resident_place_candidate_buffer.is_valid(),
		"resident_candidate_bytes": _resident_place_candidate_buffer_bytes,
		"resident_candidate_initialized": _resident_place_candidate_initialized,
		"resident_score_candidate_valid": _resident_score_candidate_buffer.is_valid(),
		"resident_score_candidate_bytes": _resident_score_candidate_bytes,
		"resident_score_winner_valid": _resident_score_winner_buffer.is_valid(),
		"resident_score_winner_bytes": _resident_score_winner_bytes,
	}


## Multi-asset placement over the anchor fine pipeline. All assets enter one
## common candidate pool (anchor x top-K asset x pivot x yaw). Fine Score picks
## one record per Anchor; cross-Anchor conflicts use stable random priority.
func run_multi_asset(
	complexity_field: PackedFloat32Array,
	collision_field: PackedFloat32Array,
	asset_defs: Array,
	grid_size: Vector3i,
	voxel_size: Vector3,
	grid_origin: Vector3 = Vector3.ZERO,
	common_settings: Dictionary = {}
) -> Dictionary:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	var run_result := _run_anchor_fine_pipeline(
		complexity_field, collision_field, asset_defs, grid_size, voxel_size, grid_origin, common_settings)
	# 只回收本 run 的 FRAME/PASS 资源；shader/pipeline（PERSISTENT）跨 run 常驻，下次
	# _load_shaders 的 ready 守卫直接命中（省 ~18ms/run 的 8-shader 重编）。全清走
	# dispose()——SPA/demo 的显式生命周期终点，之后成员 RID 由 _on_after_dispose 清空。
	gc_frame()
	return run_result


## 运行 Anchor 级细粒度候选评分 GPU 流程。
func _run_anchor_fine_pipeline(
	complexity_field: PackedFloat32Array,
	collision_field: PackedFloat32Array,
	asset_defs: Array,
	grid_size: Vector3i,
	voxel_size: Vector3,
	grid_origin: Vector3,
	common_settings: Dictionary
) -> Dictionary:
	_apply_settings(common_settings)
	var include_diagnostics := bool(common_settings.get("include_diagnostics", false))
	var fine_candidates_only := str(common_settings.get("execution_mode", "")) == "fine_candidates_only"
	var _prof := ScoreTimingProfilerScript.new(
		bool(common_settings.get("score_timing_profile", false)),
		str(common_settings.get("score_timing_label", "anchor_fine")))
	_prof.mark("run_start")

	var voxel_count := VoxelGeneral.voxel_count(grid_size)
	if voxel_count <= 0:
		push_error("VoxelPlacementGenerator: grid_size must be positive")
		return _gpu_contract_blocked_multi_asset_output(
			complexity_field, collision_field, asset_defs,
			_gpu_contract_result(false, "invalid_grid_size"), common_settings)

	if int(common_settings.get("global_quota", -1)) == 0:
		return _empty_placement_output(
			complexity_field, collision_field, asset_defs, "global_quota_zero", common_settings)

	var runtime_provider := _config_object(common_settings, GPU_RUNTIME_PROVIDER_CONFIG_KEY)
	var profile_container := _config_object(common_settings, GPU_PROFILE_CONTAINER_CONFIG_KEY)
	var write_accepted_placements_to_gpu_runtime := bool(common_settings.get("write_accepted_placements_to_gpu_runtime", false))
	var gpu_direct_runtime_writeback := write_accepted_placements_to_gpu_runtime \
		and runtime_provider != null \
		and runtime_provider.has_method("spawn_batch_from_accepted_placement_gpu_buffers")
	var gpu_contract_settings := common_settings.duplicate(true)
	if write_accepted_placements_to_gpu_runtime:
		gpu_contract_settings["require_gpu_runtime_profile_contract"] = true
	var gpu_contract := _validate_gpu_runtime_profile_contract(gpu_contract_settings)
	if not bool(gpu_contract.get("ok", true)):
		return _gpu_contract_blocked_multi_asset_output(
			complexity_field, collision_field, asset_defs, gpu_contract, common_settings)

	# Anchor handoff is the ONLY candidate source (resident-or-error, no
	# all-tiles fallback): origin_count == anchor_count by contract.
	var anchor_handoff := _resolve_anchor_candidate_handoff(common_settings)
	if not bool(anchor_handoff.get("ok", false)):
		var handoff_reason := "anchor_candidate_handoff_unavailable:%s" % str(anchor_handoff.get("reason", "missing"))
		push_error("VoxelPlacementGenerator: %s" % handoff_reason)
		return _gpu_contract_blocked_multi_asset_output(
			complexity_field, collision_field, asset_defs,
			_gpu_contract_result(false, handoff_reason), common_settings)

	var container_binding := _resolve_profile_container_buffers(common_settings)
	if not bool(container_binding.get("ok", false)):
		return _gpu_contract_blocked_multi_asset_output(
			complexity_field, collision_field, asset_defs,
			_gpu_contract_result(false, str(container_binding.get("reason", "profile_container_unavailable"))),
			common_settings)

	log_name = "VoxelPlacementGenerator"
	sync_global_device = true
	if get_rendering_device() == null and not ensure_device():
		return _gpu_contract_blocked_multi_asset_output(
			complexity_field, collision_field, asset_defs,
			_gpu_contract_result(false, "missing_rendering_device"), common_settings)

	_prof.mark("contracts_device")
	_load_shaders()
	var pipeline_ready := _fine_pipeline_ready() if fine_candidates_only else _placement_pipeline_ready()
	if not pipeline_ready:
		return _gpu_contract_blocked_multi_asset_output(
			complexity_field, collision_field, asset_defs,
			_gpu_contract_result(false,
				"fine_shader_pipeline_not_ready" if fine_candidates_only else "placement_shader_pipeline_not_ready"),
			common_settings)
	_prof.mark("shaders")

	var anchor_capacity := int(anchor_handoff.get("anchor_capacity", 0))
	var topk := int(anchor_handoff.get("topk", 0))
	var anchor_buffer: RID = anchor_handoff.get("anchor_buffer_rid", RID())
	var anchor_count_buffer: RID = anchor_handoff.get("anchor_count_buffer_rid", RID())
	var topk_buffer: RID = anchor_handoff.get("topk_buffer_rid", RID())
	# _resolve_anchor_candidate_handoff 已保证这些键在场且合法；此处不再用
	# topk=4 / capacity=0 之类的默认值兜底——一旦缺失，派发尺寸、候选池步长与
	# 回读解码会整体错位，必须在第一现场炸掉。
	if anchor_capacity <= 0 or topk <= 0 \
			or not anchor_buffer.is_valid() \
			or not anchor_count_buffer.is_valid() \
			or not topk_buffer.is_valid():
		push_error("VoxelPlacementGenerator: anchor handoff 字段非法 anchor_capacity=%d topk=%d anchor_buffer_valid=%s anchor_count_buffer_valid=%s topk_buffer_valid=%s —— 候选池尺寸/解码会整体错位" % [
			anchor_capacity, topk, anchor_buffer.is_valid(), anchor_count_buffer.is_valid(), topk_buffer.is_valid()])
		assert(false, "VoxelPlacementGenerator: anchor handoff fields invalid")
		return _gpu_contract_blocked_multi_asset_output(
			complexity_field, collision_field, asset_defs,
			_gpu_contract_result(false, "anchor_handoff_fields_invalid"), common_settings)
	track_borrowed_rid(anchor_buffer, KIND_BUFFER, SCOPE_FRAME, "prefilter:anchor_records")
	track_borrowed_rid(anchor_count_buffer, KIND_BUFFER, SCOPE_FRAME, "prefilter:anchor_count")
	track_borrowed_rid(topk_buffer, KIND_BUFFER, SCOPE_FRAME, "prefilter:anchor_topk")

	var profile_arena_buffer: RID = container_binding.get("profile_arena_buffer", RID())
	var profile_count := int(container_binding.get("profile_count", 0))
	# Explicit element capacities for the shader capacity gates (see the
	# capacities push members in score_anchor_asset_residual/stamp_asset_voxels).
	# ⚠ 扁平 buffer 时代的容量门参数：Arena 化后 shader 侧改用编译期常量守卫、已不读它们。
	# push 布局的字节位置是冻结 ABI，故保留字段，只把值换成 Arena 语义下的等价上限。
	var profile_table_capacity := ProfileArenaLayoutScript.PROFILE_CAPACITY
	var profile_sample_record_capacity := ProfileArenaLayoutScript.MAX_SAMPLES_PER_PROFILE
	var pivot_records_capacity := ProfileArenaLayoutScript.MAX_PIVOTS_PER_PROFILE
	track_borrowed_rid(profile_arena_buffer, KIND_BUFFER, SCOPE_FRAME, "auto_voxel_runtime_profile_container:profile_arena")

	var asset_lookup := _build_asset_lookup(asset_defs, container_binding.get("container"), common_settings, voxel_size)
	var asset_lookup_bytes: PackedByteArray = asset_lookup.get("bytes", PackedByteArray())
	var asset_score_params_bytes: PackedByteArray = asset_lookup.get("score_params_bytes", PackedByteArray())
	# Element capacity (ivec4 stride 16 B) — explicit capacity for the shader gates.
	var asset_lookup_capacity := asset_lookup_bytes.size() / 16
	var asset_lookup_buffer := storage_buffer_from_bytes(
		asset_lookup_bytes, SCOPE_FRAME, "placement_asset_lookup")
	# Per-asset fine-score param overrides (8 floats/asset; -1 = inherit). fine shader
	# set1 binding15; indexed by asset_id (same order/count as asset_lookup).
	var asset_score_params_buffer := storage_buffer_from_bytes(
		asset_score_params_bytes, SCOPE_FRAME, "placement_asset_score_params")
	var max_ad_count := int(asset_lookup.get("max_ad_count", 0))
	if max_ad_count <= 0:
		return _empty_placement_output(
			complexity_field, collision_field, asset_defs,
			"no_registered_fine_profile_samples", common_settings)

	# CurrentSV read pair: resident (BlendSV or committed SV) or packed from the
	# caller's CPU arrays.
	var complexity_field_gpu_rid: RID = VariantUtils.rid_from_value(common_settings.get("complexity_field_buffer_rid", RID()))
	var collision_field_gpu_rid: RID = VariantUtils.rid_from_value(common_settings.get("collision_field_buffer_rid", RID()))
	var gpu_resident_fields := complexity_field_gpu_rid.is_valid() and collision_field_gpu_rid.is_valid()
	var gpu_state_chain_active := gpu_resident_fields and VoxelPlacementStateChainScript._gpu_state_chain_enabled(common_settings)
	var gpu_state_chain_owner := str(common_settings.get("complexity_field_buffer_owner", "external"))
	var gpu_state_chain_source := str(common_settings.get("gpu_state_chain_source", "caller_provided_complexity_collision_field_rids"))
	var complexity_data := PackedFloat32Array() if gpu_resident_fields else VoxelGeneral.fit_float_array(complexity_field, voxel_count)
	var collision_data := PackedFloat32Array() if gpu_resident_fields else VoxelGeneral.fit_float_array(collision_field, voxel_count)
	var complexity_buffer: RID = complexity_field_gpu_rid
	var collision_buffer: RID = collision_field_gpu_rid
	if gpu_resident_fields:
		track_borrowed_rid(complexity_buffer, KIND_BUFFER, SCOPE_FRAME, "%s:complexity_field" % gpu_state_chain_owner)
		track_borrowed_rid(collision_buffer, KIND_BUFFER, SCOPE_FRAME, "%s:collision_field" % gpu_state_chain_owner)
	else:
		var packed_pair := _dispatch_pack_field_pair(complexity_data, collision_data, voxel_count)
		complexity_buffer = packed_pair.get("complexity_buffer", RID())
		collision_buffer = packed_pair.get("collision_buffer", RID())
		# pack 失败已在 _dispatch_pack_field_pair 内 push_error/assert；此处不得
		# 带着无效读对继续（CPU codec 回退已撤除）。
		if not complexity_buffer.is_valid() or not collision_buffer.is_valid():
			return _gpu_contract_blocked_multi_asset_output(
				complexity_field, collision_field, asset_defs,
				_gpu_contract_result(false, "current_field_pair_pack_failed"), common_settings)
	_prof.mark("field_pack")

	# TargetSV: independent field + collision pair (borrowed resident or uploaded).
	var target_buffer_pack := _target_read_buffer_pack(common_settings, voxel_count)
	if not bool(target_buffer_pack.get("ready", false)):
		var blocked_reason := str(target_buffer_pack.get("reason", "target_read_buffer_not_ready"))
		return _gpu_contract_blocked_multi_asset_output(
			complexity_field, collision_field, asset_defs,
			_gpu_contract_result(false, blocked_reason), common_settings,
			{"target_read_buffer_summary": _target_read_buffer_summary(target_buffer_pack)})
	var has_target := 1 if bool(target_buffer_pack.get("has_target", false)) else 0
	var target_buffers := _resolve_target_buffers(target_buffer_pack, common_settings, voxel_count)
	var target_field_buffer: RID = target_buffers.get("target_field_buffer", RID())
	var target_collision_buffer: RID = target_buffers.get("target_collision_buffer", RID())
	if not target_field_buffer.is_valid() or not target_collision_buffer.is_valid():
		return _gpu_contract_blocked_multi_asset_output(
			complexity_field, collision_field, asset_defs,
			_gpu_contract_result(false, "target_field_buffer_not_ready"), common_settings,
			{"target_read_buffer_summary": _target_read_buffer_summary(target_buffer_pack)})
	_prof.mark("target_resolve")

	# 细筛 scorer 私有读对融合（pack_fine_sample_pairs.glsl）：cur/target 各融成一条 uvec2
	# pair，scorer 内层每体素 4 次散射读 → 2 次。cur 侧两 word 原样拷贝（逐位保真）；
	# target 侧 vec4 → rgba8 量化（target env 非 k/255 时 gain 有 ≤~2 q1000 微变）。融合
	# buffer 是 scorer 私有只读派生，常驻场与 stamp 读写不动；pack 不可用即契约阻断。
	if not _pipeline_pack_sample_pairs.is_valid() or not _shader_pack_sample_pairs.is_valid():
		push_error("[VoxelPlacementGenerator] pack_fine_sample_pairs pipeline not ready")
		return _gpu_contract_blocked_multi_asset_output(
			complexity_field, collision_field, asset_defs,
			_gpu_contract_result(false, "sample_pair_pack_pipeline_not_ready"), common_settings)
	var cur_sample_pair_buffer := storage_buffer_uninitialized(voxel_count * 8, SCOPE_FRAME, "fine_cur_sample_pair")
	var tgt_sample_pair_buffer := storage_buffer_uninitialized(voxel_count * 8, SCOPE_FRAME, "fine_tgt_sample_pair")
	var pack_sample_set0 := create_uniform_set([
		make_storage_uniform(0, complexity_buffer),
		make_storage_uniform(1, collision_buffer),
		make_storage_uniform(2, target_field_buffer),
		make_storage_uniform(3, target_collision_buffer),
		make_storage_uniform(4, cur_sample_pair_buffer),
		make_storage_uniform(5, tgt_sample_pair_buffer),
	], _shader_pack_sample_pairs, 0)
	var pack_sample_push := PushConstantLayout.new(PACK_SAMPLE_PAIRS_PUSH).pack({
		voxel_count = voxel_count,
	})
	var pack_sample_dispatched := pack_sample_set0.is_valid() and ComputePassChain.run(self, [
		{pipeline = _pipeline_pack_sample_pairs, uniform_sets = [pack_sample_set0], push = pack_sample_push, groups = Vector3i(ceil_div(maxi(voxel_count, 1), 64), 1, 1)},
	], false)
	if not pack_sample_dispatched:
		push_error("[VoxelPlacementGenerator] pack_fine_sample_pairs dispatch failed")
		return _gpu_contract_blocked_multi_asset_output(
			complexity_field, collision_field, asset_defs,
			_gpu_contract_result(false, "sample_pair_pack_dispatch_failed"), common_settings)
	if _prof.enabled:
		submit_and_sync(true)
		_prof.mark("sample_pair_pack")

	# Place sessions retain Fine records across batches. The key intentionally
	# includes immutable buffer identities and every score-affecting scalar, while
	# CurrentSV contents may advance in-place under the dirty-tile contract.
	var candidate_buffer_bytes := maxi(anchor_capacity * topk, 1) * RECORD_STRIDE * 16
	var incremental_fine_requested := not fine_candidates_only \
		and common_settings.has("incremental_fine_reset")
	var incremental_fine_cache_key := {
		"anchor_buffer": anchor_buffer,
		"anchor_count_buffer": anchor_count_buffer,
		"topk_buffer": topk_buffer,
		"current_field_buffer": complexity_buffer,
		"current_collision_buffer": collision_buffer,
		"target_field_buffer": target_field_buffer,
		"target_collision_buffer": target_collision_buffer,
		"target_revision": int(target_buffer_pack.get("target_revision", -1)),
		"profile_arena_buffer": profile_arena_buffer,
		"grid_size": grid_size,
		"voxel_size": voxel_size,
		"anchor_capacity": anchor_capacity,
		"topk": topk,
		"asset_count": mini(asset_defs.size(), MAX_ASSETS),
		"asset_lookup_bytes": asset_lookup_bytes,
		"asset_score_params_bytes": asset_score_params_bytes,
		# 评分旋钮成员从 FINE_SCORE_TUNING_DEFAULTS 整表快照（单一真相源），取代从前
		# 摊在这里的 13 条手抄。Dictionary 的 == 会递归进子字典逐值比较
		# （dictionary.cpp recursive_equal → Variant::hash_compare 的 DICTIONARY 分支），
		# 嵌一层与摊平等价：任一旋钮变化仍让整个键不等。
		# 其余键是每轮派生的局部量（RID / 尺寸 / 容量 / 字节数组），不是成员，逐条列在这里。
		"tuning": _tuning_snapshot(),
		"has_target": has_target,
		"profile_count": profile_count,
		"profile_table_capacity": profile_table_capacity,
		"profile_sample_record_capacity": profile_sample_record_capacity,
		"pivot_records_capacity": pivot_records_capacity,
	}
	var winner_buffer_bytes := maxi(anchor_capacity, 1) * RECORD_STRIDE * 16
	var incremental_fine_cache_hit := false
	var candidate_buffer := RID()
	var resident_score_ready := false
	if fine_candidates_only:
		# Score 侧常驻：调用方要在 run_multi_asset 返回**之后**借这两块做点选与显示，
		# 所以它们不能随 SCOPE_FRAME 一起被 GC。见成员声明处的释放点契约。
		resident_score_ready = _ensure_resident_score_buffers(
			candidate_buffer_bytes, winner_buffer_bytes)
		candidate_buffer = _resident_score_candidate_buffer
	elif incremental_fine_requested:
		var resident_candidate := _ensure_resident_place_candidate_buffer(
			candidate_buffer_bytes, incremental_fine_cache_key)
		candidate_buffer = resident_candidate.get("buffer", RID())
		incremental_fine_cache_hit = bool(resident_candidate.get("cache_hit", false))
	else:
		candidate_buffer = storage_buffer_uninitialized(
			candidate_buffer_bytes, SCOPE_FRAME, "fine_candidates")
	var incremental_fine_force_full := bool(common_settings.get("incremental_fine_reset", false)) \
		or bool(common_settings.get("force_full_place_recompute", false)) \
		or bool(common_settings.get("debug_read_voxel_channels", false))
	# Fine consumes only the resident Anchor candidate handoff. The retired
	# fine dirty-mask pipeline has been removed; each changed handoff rewrites
	# every candidate (always-dirty semantics).
	if not candidate_buffer.is_valid():
		return _gpu_contract_blocked_multi_asset_output(
			complexity_field, collision_field, asset_defs,
			_gpu_contract_result(false, "incremental_fine_buffer_allocation_failed"), common_settings)
	# 常驻对必须成对可用：只拿到候选就往下走，winner pass 会朝一个空 RID 建 uniform set，
	# 报出来的却是含糊的 dispatch 失败。分配失败在这里就地判死，并把半块常驻还回去。
	if fine_candidates_only and not resident_score_ready:
		_release_resident_score_buffers()
		return _gpu_contract_blocked_multi_asset_output(
			complexity_field, collision_field, asset_defs,
			_gpu_contract_result(false, "resident_score_buffer_allocation_failed"), common_settings)
	var validate_incremental_fine_candidates := bool(
		common_settings.get("validate_incremental_fine_candidates", false))
	# Score 走常驻胜出缓冲（与候选同批分配/释放）；Place 的增量自检仍只要一块帧内缓冲。
	var winner_buffer := RID()
	if fine_candidates_only:
		winner_buffer = _resident_score_winner_buffer
	elif validate_incremental_fine_candidates:
		winner_buffer = storage_buffer_uninitialized(
			winner_buffer_bytes, SCOPE_FRAME, "fine_winners")
	var compact_state_chain := VoxelPlacementStateChainScript._compact_delta_state_chain_requested(common_settings) \
		and not gpu_state_chain_active
	var read_stamp_deltas := bool(common_settings.get("read_stamp_deltas", false)) or compact_state_chain
	var stamp_capacity := result_capacity * max_ad_count if read_stamp_deltas else 0
	var stamp_delta_binding_bytes := maxi(stamp_capacity, 1) * DELTA_STRIDE * 16
	var result_buffer := RID()
	var result_count_buffer := RID()
	var stamp_delta_buffer := RID()
	var stamp_delta_count_buffer := RID()
	var stamp_bounds_buffer := RID()
	if not fine_candidates_only:
		result_buffer = storage_buffer_uninitialized(result_capacity * RECORD_STRIDE * 16, SCOPE_FRAME, "placement_results")
		result_count_buffer = storage_buffer_zero(4, SCOPE_FRAME, "placement_result_count")
		# Binding 7 must remain a valid RID even when the resident path disables
		# delta capture. In that mode this is a fixed 32-byte sentinel and the
		# shader receives a logical capacity of zero.
		stamp_delta_buffer = storage_buffer_uninitialized(stamp_delta_binding_bytes, SCOPE_FRAME, "stamp_delta")
		stamp_delta_count_buffer = storage_buffer_zero(4, SCOPE_FRAME, "stamp_delta_count")
		stamp_bounds_buffer = storage_buffer_uninitialized(maxi(result_capacity, 1) * STAMP_BOUNDS_STRIDE * 16, SCOPE_FRAME, "stamp_bounds")
	var fine_indirect_args_buffer := dispatch_indirect_args_buffer_zero(SCOPE_FRAME, "fine_score_indirect_args")

	var debug_read_voxel := bool(common_settings.get("debug_read_voxel_channels", false))
	var voxel_debug_set := DebugBufferSetScript.new(DebugBufferSetScript.VOXEL_DEBUG_CHANNELS)
	var debug_voxel_buffer := voxel_debug_set.allocate(self, voxel_count if debug_read_voxel else 1, {}, SCOPE_FRAME)
	var debug_write_mask := 1 if debug_read_voxel else 0
	var score_contract_debug_reset := _pack_score_contract_debug_reset()
	var score_contract_debug_buffer := storage_buffer_from_bytes(score_contract_debug_reset)
	var score_resource_profile := {
		"execution_mode": "fine_candidates_only" if fine_candidates_only else "placement",
		"voxel_count": voxel_count,
		"anchor_capacity": anchor_capacity,
		"topk": topk,
		"buffer_bytes": {
			"sample_pair_current": voxel_count * 8,
			"sample_pair_target": voxel_count * 8,
			"fine_candidates": maxi(anchor_capacity * topk, 1) * RECORD_STRIDE * 16,
			"fine_winners": maxi(anchor_capacity, 1) * RECORD_STRIDE * 16 \
				if fine_candidates_only or validate_incremental_fine_candidates else 0,
			"fine_indirect_args": 12,
			"score_contract_debug": score_contract_debug_reset.size(),
		},
		"zero_initialized_bytes": 12,
		"uploaded_bytes": asset_lookup_bytes.size()
			+ asset_score_params_bytes.size()
			+ score_contract_debug_reset.size(),
		"readback_bytes": 0,
		"dispatch_count": 4 if fine_candidates_only else 3,
		"sync_count": 3 if _prof.enabled else 1,
	}
	if not fine_candidates_only:
		var resource_buffer_bytes: Dictionary = score_resource_profile["buffer_bytes"]
		resource_buffer_bytes["placement_results"] = result_capacity * RECORD_STRIDE * 16
		resource_buffer_bytes["placement_result_count"] = 4
		resource_buffer_bytes["stamp_delta"] = stamp_capacity * DELTA_STRIDE * 16
		resource_buffer_bytes["stamp_delta_binding_sentinel"] = \
			stamp_delta_binding_bytes if stamp_capacity == 0 else 0
		resource_buffer_bytes["stamp_delta_count"] = 4
		resource_buffer_bytes["stamp_bounds"] = maxi(result_capacity, 1) * STAMP_BOUNDS_STRIDE * 16
		score_resource_profile["zero_initialized_bytes"] = 20
		score_resource_profile["dispatch_count"] = 8 + (1 if validate_incremental_fine_candidates else 0)
		# profile 关闭时整条 placement 管线只有收尾一次提交；开启时每段后各加一次
		# （sample_pair / finalize / fine_score / reduce / init_bounds / stamp + 收尾）。
		score_resource_profile["sync_count"] = 7 if _prof.enabled else 1

	var contract_enabled := 1 if str(gpu_contract.get("reason", "")) == "gpu_runtime_profile_buffers_ready" else 0
	_prof.mark("setup")

	# Pass 1: finalize the indirect args in its own compute list (same pattern
	# as the prefilter: end the list before the indirect consumer reads args).
	var finalize_set0 := create_uniform_set([
		make_storage_uniform(0, anchor_count_buffer),
		make_storage_uniform(1, fine_indirect_args_buffer),
	], _shader_fine_finalize, 0, SCOPE_PASS, "fine_finalize_set0")
	var finalize_push := PushConstantLayout.new(FINE_FINALIZE_PUSH).pack({
		anchor_grid_x = ANCHOR_GRID_X,
		topk = topk,
		anchor_capacity = anchor_capacity,
	})
	# 派发失败必须硬失败：fine_score 紧接着以 dispatch_indirect 读这份 args，
	# args 没写成就继续 = 用未初始化/陈旧的间接参数跑细筛。
	if not ComputePassChain.run(self, [
		{pipeline = _pipeline_fine_finalize, uniform_sets = [finalize_set0], push = finalize_push, groups = Vector3i(1, 1, 1)},
	], false):
		push_error("VoxelPlacementGenerator: fine_score_dispatch_finalize 派发失败 anchor_grid_x=%d topk=%d anchor_capacity=%d —— 间接派发参数未写入" % [
			ANCHOR_GRID_X, topk, anchor_capacity])
		assert(false, "VoxelPlacementGenerator: fine finalize dispatch failed")
		return _gpu_contract_blocked_multi_asset_output(
			complexity_field, collision_field, asset_defs,
			_gpu_contract_result(false, "fine_finalize_dispatch_failed"), common_settings)
	if _prof.enabled:
		submit_and_sync(true)
		_prof.mark("fine_finalize")

	# Pass 2..5: fine score (indirect) -> reduce -> init bounds -> stamp.
	var score_set0 := create_uniform_set([
		make_storage_uniform(0, cur_sample_pair_buffer),
		make_storage_uniform(1, tgt_sample_pair_buffer),
		make_storage_uniform(4, anchor_buffer),
		make_storage_uniform(5, anchor_count_buffer),
		make_storage_uniform(6, topk_buffer),
		make_storage_uniform(7, debug_voxel_buffer),
		make_storage_uniform(8, candidate_buffer),
	], _shader_fine_score, 0)
	# binding 6 = 固定槽位 Profile Arena（Header/Samples/Pivots/Mesh 单一 binding）。
	# 迁移前是 6=profile_table / 11=pivot_records / 13=profile_sample_records 三件套。
	var score_set1 := create_uniform_set([
		make_storage_uniform(6, profile_arena_buffer),
		make_storage_uniform(8, score_contract_debug_buffer),
		make_storage_uniform(14, asset_lookup_buffer),
		make_storage_uniform(15, asset_score_params_buffer),
	], _shader_fine_score, 1)
	var score_push := PushConstantLayout.new(FINE_SCORE_PUSH).pack({
		grid_x = grid_size.x, grid_y = grid_size.y, grid_z = grid_size.z,
		has_target = has_target,
		voxel_size_x = voxel_size.x, voxel_size_y = voxel_size.y, voxel_size_z = voxel_size.z,
		min_match_fraction = min_match_fraction,
		rotation_slots = rotation_slots,
		topk = topk,
		asset_count = mini(asset_defs.size(), MAX_ASSETS),
		anchor_capacity = anchor_capacity,
		solid_threshold = solid_threshold,
		collision_limit = collision_limit,
		clearance_limit = clearance_limit,
		complexity_write_scale = scene_write_scale,
		collision_write_scale = collision_write_scale,
		dim_w_collision = dim_weight_collision,
		dim_w_complexity = dim_weight_complexity,
		dim_w_color = dim_weight_color,
		contract_enabled = contract_enabled,
		profile_count = profile_count,
		debug_write_mask = debug_write_mask,
		asset_lookup_capacity = asset_lookup_capacity,
		profile_table_capacity = profile_table_capacity,
		profile_sample_record_capacity = profile_sample_record_capacity,
		pivot_records_capacity = pivot_records_capacity,
		color_match_max_l1 = color_match_max_l1,
		collision_match_max = collision_match_max,
		complexity_overfill_ratio = 1.0 + complexity_overfill_percent * 0.01,
	})
	var fine_pass := {
		pipeline = _pipeline_fine_score,
		uniform_sets = [score_set0, score_set1],
		push = score_push,
		indirect_args = fine_indirect_args_buffer,
	}
	if fine_candidates_only:
		var winner_set0 := create_uniform_set([
			make_storage_uniform(0, candidate_buffer),
			make_storage_uniform(1, anchor_count_buffer),
			make_storage_uniform(2, winner_buffer),
		], _shader_fine_winner, 0)
		var winner_push := PushConstantLayout.new(FINE_WINNER_PUSH).pack({
			topk = topk,
			anchor_capacity = anchor_capacity,
		})
		var winner_pass := {
			pipeline = _pipeline_fine_winner,
			uniform_sets = [winner_set0],
			push = winner_push,
			groups = Vector3i(ceil_div(maxi(anchor_capacity, 1), 256), 1, 1),
		}
		# winner_buffer 是 storage_buffer_uninitialized：派发失败时不得继续回读，
		# 否则观察模式会把未初始化显存当成有效结果报出去。
		if not ComputePassChain.run(self, [fine_pass, winner_pass], false, true):
			return _gpu_contract_blocked_multi_asset_output(
				complexity_field, collision_field, asset_defs,
				_gpu_contract_result(false, "fine_score_dispatch_failed"), common_settings)
		submit_and_sync(true)
		if _prof.enabled:
			_prof.mark("fine_score")
		return _finish_fine_candidates_only(
			complexity_field, collision_field, asset_defs, common_settings, include_diagnostics,
			anchor_count_buffer, candidate_buffer, winner_buffer, anchor_capacity, topk,
			score_contract_debug_buffer, gpu_contract, target_buffer_pack,
			_prof, score_resource_profile)

	# Greedy score-NMS Reduce working buffers. Fine Score keeps top-K records;
	# init chooses one per Anchor, seeds the three-state machine in anchor_valid
	# (0 = out, 1 = selected, 2 = undecided) and writes the direct XZ map; the
	# arbitrate pass iterates that machine to its fixed point; compact accepts
	# state 1 up to the result buffer's capacity.
	# 跨轮互斥不在余隙场：fine score 每批都在**上一轮盖章后的 SceneSV** 上重算
	# solid_collision / clearance_overlap（资产 profile 的 CLEARANCE 探针直采 CurSample）
	# 与 residual gain，上一轮的放置天然被排斥（2026-08-19 用户裁决：互斥逻辑在
	# fine score × 上轮 SV，与 autoobject 无关）。故 CPU 种子表及其首批重画已整个删除
	#（2026-08-18 裁决：下一轮依赖项与上一轮一致，host 不留副本）。
	var spacing_floats: PackedFloat32Array = asset_lookup.get("spacing_floats", PackedFloat32Array())
	if spacing_floats.is_empty():
		spacing_floats.resize(1)
	var asset_spacing_buffer := storage_buffer_from_floats(spacing_floats, SCOPE_FRAME, "asset_spacing_radius")
	var anchor_candidate_ref_buffer := storage_buffer_zero(maxi(anchor_capacity, 1) * 4, SCOPE_FRAME, "reduce_anchor_candidate_ref")
	var anchor_valid_buffer := storage_buffer_zero(maxi(anchor_capacity, 1) * 4, SCOPE_FRAME, "reduce_anchor_valid")
	var pixel_count := maxi(grid_size.x * grid_size.z, 1)
	# 仲裁的按像素索引紧凑表（init 写、arbitrate 读）。meta = ((anchor+1) << 8) | asset，
	# record = 胜出 Fine 候选的 (origin.xyz, score)。把 NMS 邻居扫描（全链最热的读，每锚
	# 每轮上百次探测）从「三层间接 + 对 100+ MB fine_candidates 随机 gather」压成两次连续
	# 读；两张表在 256×256 网格上共 1.3 MB。
	var arb_meta_buffer := storage_buffer_zero(pixel_count * 4, SCOPE_FRAME, "reduce_arb_meta_at_pixel")
	var arb_record_buffer := storage_buffer_zero(pixel_count * 16, SCOPE_FRAME, "reduce_arb_record_at_pixel")
	# 参赛者紧凑列表（槽位 -> 像素下标）。NMS 的间接派发规模由它决定，而不再由整个锚点池
	# 决定：格点门开着时一批只有几十~几百个参赛者，按整池派发会让 99.3% 的线程一读状态
	# 就退出（实测 38144 线程/轮 vs 最多 253 个真正参赛）。
	var participant_list_buffer := storage_buffer_zero(maxi(anchor_capacity, 1) * 4, SCOPE_FRAME, "reduce_participant_pixels")
	# NMS bookkeeping: meta = {decided, valid, iteration, finished_groups}
	# (zero-filled is the correct initial state; init accumulates valid), and
	# the indirect args the arbitrate pass reads each round and zeroes on
	# convergence. init sizes the args from the live anchor count on the GPU.
	var nms_meta_buffer := storage_buffer_zero(16, SCOPE_FRAME, "reduce_nms_meta")
	var nms_dispatch_args_buffer := dispatch_indirect_args_buffer_zero(SCOPE_FRAME, "reduce_nms_dispatch_args")

	# ── 有符号余隙场：**会话作用域**的批间互斥载体 ──────────────────────────────
	# 会话首批重建零场，之后各批沿用；内容全部来自 GPU 侧 paint pass 的原位累积，没有
	# 任何 CPU 回传/重放。跨轮互斥不靠它（见上：fine score × 上轮 SV）。
	# 缺省 true = 未声明会话的单发调用自成一个新会话。
	var clearance_field_reset := bool(common_settings.get("clearance_field_reset", true))
	var clearance_field_buffer := _ensure_resident_clearance_field_buffer(
		pixel_count, clearance_field_reset)
	if not clearance_field_buffer.is_valid():
		push_error("VoxelPlacementGenerator: 余隙场分配失败 pixel_count=%d —— 跨批互斥会整条失效（每批都会把物件叠在上一批头上）" % pixel_count)
		assert(false, "VoxelPlacementGenerator: clearance field allocation failed")
		return _gpu_contract_blocked_multi_asset_output(
			complexity_field, collision_field, asset_defs,
			_gpu_contract_result(false, "clearance_field_allocation_failed"), common_settings)
	var max_spacing_radius_voxels := float(asset_lookup.get("max_spacing_radius_voxels", 0.0))
	# 偏置量程守卫：场把 clearance 存成 (clearance + 64) * 256 的 uint，查询方最大的半边
	# 半径超过偏置就会有格子被"截成无约束"，表现是间距在大资产附近静默失效。
	var max_half_radius := maxf(
		max_spacing_radius_voxels * asset_spacing_factor,
		maxf(min_distance_voxels * 0.5, 0.25))
	if max_half_radius >= CLEARANCE_BIAS_VOXELS:
		push_error("VoxelPlacementGenerator: 半边间距半径 %.3f 体素超出余隙场偏置量程 %.1f —— 大资产附近的跨批间距会静默失效" % [
			max_half_radius, CLEARANCE_BIAS_VOXELS])
		assert(false, "VoxelPlacementGenerator: clearance field bias exceeded")

	var reduce_init_set0 := create_uniform_set([
		make_storage_uniform(0, candidate_buffer),
		make_storage_uniform(1, anchor_count_buffer),
		make_storage_uniform(2, anchor_candidate_ref_buffer),
		make_storage_uniform(3, anchor_valid_buffer),
		make_storage_uniform(4, arb_meta_buffer),
		make_storage_uniform(5, nms_meta_buffer),
		make_storage_uniform(6, nms_dispatch_args_buffer),
		make_storage_uniform(7, asset_spacing_buffer),
		make_storage_uniform(8, clearance_field_buffer),
		make_storage_uniform(9, arb_record_buffer),
		make_storage_uniform(10, participant_list_buffer),
	], _shader_reduce_init, 0)
	# ⚠ binding 0/1/2 刻意不绑：仲裁改由 meta/record 取自身数据后，不再需要
	# fine_candidates / anchor_count / anchor_candidate_ref（shader 侧同样留空洞）。
	var reduce_arbitrate_set0 := create_uniform_set([
		make_storage_uniform(3, anchor_valid_buffer),
		make_storage_uniform(4, arb_meta_buffer),
		make_storage_uniform(5, nms_meta_buffer),
		make_storage_uniform(6, nms_dispatch_args_buffer),
		make_storage_uniform(7, asset_spacing_buffer),
		make_storage_uniform(8, arb_record_buffer),
		make_storage_uniform(9, participant_list_buffer),
	], _shader_reduce_arbitrate, 0)
	# ⚠ binding 4 曾是 asset_lookup_buffer（逐资产配额），配额退役后 compact 不再读它，
	# 这里也不再绑；shader 侧刻意留空洞不重排编号（本仓已有先例，退役的 invalidate 就是
	# 0..4 + 7/8）。asset_lookup_buffer 本身仍被评分与 runtime writeback 用着，别顺手删。
	var reduce_compact_set0 := create_uniform_set([
		make_storage_uniform(0, candidate_buffer),
		make_storage_uniform(1, anchor_count_buffer),
		make_storage_uniform(2, anchor_candidate_ref_buffer),
		make_storage_uniform(3, anchor_valid_buffer),
		make_storage_uniform(5, result_buffer),
		make_storage_uniform(6, result_count_buffer),
	], _shader_reduce_compact, 0)
	# 画侧唯一的记录源：compact 刚写完的本批 survivor（条数在 GPU 的 result_count 里）。
	# 曾有第二个记录源 seeds（CPU 种子表跨轮重放）——跨轮互斥实为 fine score × 上轮 SV
	# 的职责（2026-08-19 用户裁决），种子链已删；shader 侧 stride=1/count_source=1/
	# asset_field=1 的模式位仍是有效契约、只是无人再用。
	var paint_results_set0 := create_uniform_set([
		make_storage_uniform(0, result_buffer),
		make_storage_uniform(1, result_count_buffer),
		make_storage_uniform(2, clearance_field_buffer),
		make_storage_uniform(3, asset_spacing_buffer),
	], _shader_paint_clearance, 0)

	var init_set0 := create_uniform_set([
		make_storage_uniform(0, stamp_bounds_buffer),
	], _shader_init_stamp_bounds, 0)
	var init_push := PushConstantLayout.new(STAMP_INIT_PUSH).pack({
		result_capacity = maxi(result_capacity, 1),
		stamp_bounds_stride = STAMP_BOUNDS_STRIDE,
	})

	# Stamp-only commit: when the read pair is a BlendSV working pair the stamp
	# double-writes the committed SV resident pair (dual_commit); otherwise the
	# commit bindings alias the read pair and the second write is skipped.
	var commit_complexity_buffer: RID = VariantUtils.rid_from_value(common_settings.get("commit_complexity_field_buffer_rid", RID()))
	var commit_collision_buffer: RID = VariantUtils.rid_from_value(common_settings.get("commit_collision_field_buffer_rid", RID()))
	var dual_commit := commit_complexity_buffer.is_valid() \
		and commit_collision_buffer.is_valid() \
		and (commit_complexity_buffer != complexity_buffer or commit_collision_buffer != collision_buffer)
	# 只给了一半 commit 对 = 调用方配置错误：另一半会静默别名到读对，stamp 的
	# 双写只落一个通道，committed SV 从此与 BlendSV 不一致。两个都缺是合法的
	# "不做双写"配置（见上方注释），两个都在才是双写。
	if commit_complexity_buffer.is_valid() != commit_collision_buffer.is_valid():
		push_error("VoxelPlacementGenerator: commit 场缓冲只提供了一半 commit_complexity_valid=%s commit_collision_valid=%s —— stamp 双写会只落一个通道" % [
			commit_complexity_buffer.is_valid(), commit_collision_buffer.is_valid()])
		assert(false, "VoxelPlacementGenerator: commit field buffer pair incomplete")
		return _gpu_contract_blocked_multi_asset_output(
			complexity_field, collision_field, asset_defs,
			_gpu_contract_result(false, "commit_field_buffer_pair_incomplete"), common_settings)
	if not commit_complexity_buffer.is_valid():
		commit_complexity_buffer = complexity_buffer
		commit_collision_buffer = collision_buffer
	if dual_commit:
		track_borrowed_rid(commit_complexity_buffer, KIND_BUFFER, SCOPE_FRAME, "commit:complexity_field")
		track_borrowed_rid(commit_collision_buffer, KIND_BUFFER, SCOPE_FRAME, "commit:collision_field")
	var stamp_set0 := create_uniform_set([
		make_storage_uniform(0, complexity_buffer),
		make_storage_uniform(1, collision_buffer),
		make_storage_uniform(2, result_buffer),
		make_storage_uniform(3, result_count_buffer),
		# binding 4 = 固定槽位 Profile Arena（迁移前是 4=profile_table /
		# 5=pivot_records / 6=profile_sample_records 三件套）。
		make_storage_uniform(4, profile_arena_buffer),
		make_storage_uniform(7, stamp_delta_buffer),
		make_storage_uniform(8, stamp_delta_count_buffer),
		make_storage_uniform(9, stamp_bounds_buffer),
		make_storage_uniform(10, commit_complexity_buffer),
		make_storage_uniform(11, commit_collision_buffer),
	], _shader_stamp, 0)
	var write_min: Vector3i = common_settings.get("write_min", Vector3i.ZERO)
	var write_max: Vector3i = common_settings.get("write_max", grid_size)
	var stamp_push := PushConstantLayout.new(STAMP_PUSH).pack({
		grid_x = grid_size.x, grid_y = grid_size.y, grid_z = grid_size.z,
		rotation_slots = rotation_slots,
		write_min_x = write_min.x, write_min_y = write_min.y, write_min_z = write_min.z,
		profile_count = profile_count,
		write_max_x = write_max.x, write_max_y = write_max.y, write_max_z = write_max.z,
		stamp_delta_capacity = maxi(stamp_capacity, 0),
		solid_threshold = solid_threshold,
		complexity_write_scale = scene_write_scale,
		collision_write_scale = collision_write_scale,
		dual_commit = 1.0 if dual_commit else 0.0,
		voxel_size_x = voxel_size.x, voxel_size_y = voxel_size.y, voxel_size_z = voxel_size.z,
		profile_table_capacity = profile_table_capacity,
		profile_sample_record_capacity = profile_sample_record_capacity,
		pivot_records_capacity = pivot_records_capacity,
	})

	var init_pass := {pipeline = _pipeline_init_stamp_bounds, uniform_sets = [init_set0], push = init_push, groups = Vector3i(ceil_div(maxi(result_capacity, 1), 64), 1, 1)}
	var stamp_pass := {pipeline = _pipeline_stamp, uniform_sets = [stamp_set0], push = stamp_push, groups = Vector3i(maxi(result_capacity, 1), 1, 1)}

	# 生产路径（profile 关闭）整条管线只在收尾 submit_and_sync 一次：pack -> finalize ->
	# fine_score -> reduce -> init_bounds -> stamp -> score_sum 各录进独立 compute list，
	# 段间依赖由 list 边界表达（compute_list_end/begin 即 compute_list_add_barrier 的实现），
	# RenderingDevice 按资源追踪自动插屏障。⚠ 段间不得插入回读、GPU 结果驱动的 CPU 分支或
	# buffer_zero/buffer_update；新增此类操作必须先在其前恢复一次 submit_and_sync。
	# profile 模式在每段后额外 sync 再 mark，相邻 mark 差即该 pass 的真实 GPU 耗时。
	var fine_dispatched := ComputePassChain.run(self, [fine_pass], false)
	if not fine_dispatched:
		return _gpu_contract_blocked_multi_asset_output(
			complexity_field, collision_field, asset_defs,
			_gpu_contract_result(false, "fine_score_dispatch_failed"), common_settings)
	if _prof.enabled:
		submit_and_sync(true)
		_prof.mark("fine_score")
	if incremental_fine_requested and candidate_buffer == _resident_place_candidate_buffer:
		_resident_place_candidate_initialized = true
	if validate_incremental_fine_candidates:
		var validation_winner_set0 := create_uniform_set([
			make_storage_uniform(0, candidate_buffer),
			make_storage_uniform(1, anchor_count_buffer),
			make_storage_uniform(2, winner_buffer),
		], _shader_fine_winner, 0)
		var validation_winner_push := PushConstantLayout.new(FINE_WINNER_PUSH).pack({
			topk = topk,
			anchor_capacity = anchor_capacity,
		})
		var validation_winner_dispatched := ComputePassChain.run(self, [{
			pipeline = _pipeline_fine_winner,
			uniform_sets = [validation_winner_set0],
			push = validation_winner_push,
			groups = Vector3i(ceil_div(maxi(anchor_capacity, 1), 256), 1, 1),
		}], false)
		if not validation_winner_dispatched:
			return _gpu_contract_blocked_multi_asset_output(
				complexity_field, collision_field, asset_defs,
				_gpu_contract_result(false, "incremental_fine_winner_validation_dispatch_failed"),
				common_settings)

	# Reduce chain: init (pick one Fine candidate per anchor, run lattice/clearance
	# gates, seed the NMS states, size the indirect args) → iterate the greedy
	# score-NMS until the GPU zeroes its own indirect args (the host blindly
	# enqueues reduce_nms_iter_budget rounds; converged rounds launch zero
	# workgroups) → compact survivors into result slots → paint this batch's
	# survivors into the clearance field for the next batch's O(1) lookup.
	# No relationship buffer, no sort, no convergence readback.
	# ⚠ 选择策略只有一处：仲裁的得分优先。逐资产配额已退役（asset_lookup[].z 零消费方）。
	# ⚠ result_capacity 是纯缓冲上界、不是选择口径：胜出者多于它时 compact 按 anchor id
	# 走序填满就停。anchor id 来自 collect_sv_anchors 的无序 atomicAdd ⇒ 顶到上界那批
	# 「谁先落地」是任意的（按用户要求不做得分排名裁剪）。要避免就把 result_capacity 开够大。
	var asset_count_push := mini(asset_defs.size(), MAX_ASSETS)
	var paint_clearance_common := {
		grid_x = grid_size.x,
		grid_z = grid_size.z,
		asset_count = asset_count_push,
		min_distance_voxels = min_distance_voxels,
		asset_spacing_factor = asset_spacing_factor,
		max_spacing_radius = max_spacing_radius_voxels,
	}
	var reduce_passes: Array = []
	reduce_passes.append({
		pipeline = _pipeline_reduce_init,
		uniform_sets = [reduce_init_set0],
		push = PushConstantLayout.new(REDUCE_INIT_PUSH).pack({
			topk = topk,
			anchor_capacity = anchor_capacity,
			asset_count = asset_count_push,
			grid_x = grid_size.x,
			grid_z = grid_size.z,
			anchor_interval = anchor_interval_voxels,
			anchor_phase_x = posmod(anchor_phase_x, maxi(anchor_interval_voxels, 1)),
			anchor_phase_z = posmod(anchor_phase_z, maxi(anchor_interval_voxels, 1)),
			min_distance_voxels = min_distance_voxels,
			asset_spacing_factor = asset_spacing_factor,
		}),
		groups = Vector3i(ceil_div(maxi(anchor_capacity, 1), 256), 1, 1),
	})
	# The same arbitrate descriptor is enqueued budget times: each round reads
	# its group count from the indirect args (sized by init to the live anchor
	# count) and the last finishing workgroup zeroes the args on convergence,
	# so trailing rounds are zero-workgroup no-ops. The chain's barriers keep
	# the write -> indirect-read ordering between rounds.
	var reduce_nms_push := PushConstantLayout.new(REDUCE_NMS_PUSH).pack({
		anchor_capacity = anchor_capacity,
		asset_count = asset_count_push,
		grid_x = grid_size.x,
		grid_z = grid_size.z,
		min_distance_voxels = min_distance_voxels,
		asset_spacing_factor = asset_spacing_factor,
		max_spacing_radius = max_spacing_radius_voxels,
		anchor_interval = anchor_interval_voxels,
		anchor_phase_x = posmod(anchor_phase_x, maxi(anchor_interval_voxels, 1)),
		anchor_phase_z = posmod(anchor_phase_z, maxi(anchor_interval_voxels, 1)),
	})
	for _nms_round in range(maxi(reduce_nms_iter_budget, 1)):
		reduce_passes.append({
			pipeline = _pipeline_reduce_arbitrate,
			uniform_sets = [reduce_arbitrate_set0],
			push = reduce_nms_push,
			indirect_args = nms_dispatch_args_buffer,
		})
	reduce_passes.append({
		pipeline = _pipeline_reduce_compact,
		uniform_sets = [reduce_compact_set0],
		push = PushConstantLayout.new(REDUCE_COMPACT_PUSH).pack({
			anchor_capacity = anchor_capacity,
			result_capacity = result_capacity,
			asset_count = asset_count_push,   # 已退役，shader 不读
		}),
		groups = Vector3i(1, 1, 1),
	})
	# 画侧必须排在 compact **之后**：本批 survivor 只有在配额/容量裁决完成后才算被接受，
	# 提前画会把被 compact 砍掉的候选也算进互斥关系。同批内部的互斥仍归上面那趟逐对仲裁，
	# 本 pass 服务的是**下一批**。
	var paint_results_push := paint_clearance_common.duplicate()
	paint_results_push["record_capacity"] = maxi(result_capacity, 1)
	paint_results_push["record_stride"] = RECORD_STRIDE   # placement_results 一条 = 4 个 vec4
	paint_results_push["count_source"] = 0                # 条数读 GPU 的 result_count
	paint_results_push["push_count"] = 0
	paint_results_push["asset_field"] = 0                 # 资产号在 [base+1].y
	reduce_passes.append({
		pipeline = _pipeline_paint_clearance,
		uniform_sets = [paint_results_set0],
		push = PushConstantLayout.new(PAINT_CLEARANCE_PUSH).pack(paint_results_push),
		groups = _record_group_layout(result_capacity),
	})
	# The chain length is dynamic (clearance paints + NMS budget), so patch the
	# actual count into score_resource_profile's dispatch_count. Converged NMS
	# rounds are zero-workgroup dispatches but still enqueued commands, so they count.
	score_resource_profile["dispatch_count"] = int(
		score_resource_profile.get("dispatch_count", 0)) + reduce_passes.size() - 3
	# Keep the storage-buffer barrier contract explicit even though the helper's
	# default is true: init -> invalidate -> compact must never be fused without it.
	# 三段 reduce / init_bounds / stamp 的派发返回值不得吞掉：任一段没派发，后面的回读
	# 拿到的都是未初始化显存（result/bounds 均 uninitialized），会被当成"有效放置"写进场。
	if not ComputePassChain.run(self, reduce_passes, false, true):
		push_error("VoxelPlacementGenerator: reduce 链派发失败 passes=%d anchor_capacity=%d asset_count=%d —— 结果缓冲仍是未初始化显存" % [
			reduce_passes.size(), anchor_capacity, asset_count_push])
		assert(false, "VoxelPlacementGenerator: reduce dispatch failed")
		return _gpu_contract_blocked_multi_asset_output(
			complexity_field, collision_field, asset_defs,
			_gpu_contract_result(false, "reduce_dispatch_failed"), common_settings)
	var stamp_dispatched := true
	if _prof.enabled:
		submit_and_sync(true)
		_prof.mark("reduce")
		stamp_dispatched = ComputePassChain.run(self, [init_pass], false)
		submit_and_sync(true)
		_prof.mark("init_bounds")
		if stamp_dispatched:
			stamp_dispatched = ComputePassChain.run(self, [stamp_pass], false)
		submit_and_sync(true)
		_prof.mark("stamp")
	else:
		stamp_dispatched = ComputePassChain.run(self, [init_pass, stamp_pass], false)
	if not stamp_dispatched:
		push_error("VoxelPlacementGenerator: init_stamp_bounds/stamp_asset_voxels 派发失败 result_capacity=%d stamp_capacity=%d —— stamp bounds 与结果缓冲仍是未初始化显存" % [
			result_capacity, stamp_capacity])
		assert(false, "VoxelPlacementGenerator: stamp dispatch failed")
		return _gpu_contract_blocked_multi_asset_output(
			complexity_field, collision_field, asset_defs,
			_gpu_contract_result(false, "stamp_dispatch_failed"), common_settings)

	var retain_placement_result_buffers := gpu_direct_runtime_writeback \
		or bool(common_settings.get("retain_placement_result_buffers", false))
	var score_sum_buffer := RID()
	if retain_placement_result_buffers:
		score_sum_buffer = _dispatch_placement_score_sum(result_buffer, result_count_buffer, result_capacity)

	submit_and_sync(true)

	# Readbacks: the result records are tiny (result_capacity * 64 B), so they
	# are always read — per-asset grouping and reports need them even when the
	# resident buffers are also retained for the GPU-direct writeback.
	var score_readback_bytes := 0
	# NMS 遥测（16 B）。收敛控制整条在 GPU 上、宿主只盲目入队 budget 轮 ⇒ 没有这份遥测时
	# **预算耗尽是完全静默的**（残留 UNDECIDED 被 compact 丢弃，只表现为"这批少放了几个"）。
	# 同时暴露实际轮数 = 冲突图里最长的优先级依赖链，是调整 reduce_nms_iter_budget 的唯一依据。
	var nms_meta_bytes := _rd.buffer_get_data(nms_meta_buffer, 0, 16)
	score_readback_bytes += nms_meta_bytes.size()
	var nms_telemetry := {}
	if nms_meta_bytes.size() >= 16:
		var nms_decided := nms_meta_bytes.decode_u32(0)
		var nms_valid := nms_meta_bytes.decode_u32(4)
		var nms_iterations := nms_meta_bytes.decode_u32(8)
		var nms_undecided := maxi(nms_valid - nms_decided, 0)
		nms_telemetry = {
			"iterations": nms_iterations,
			"valid": nms_valid,
			"decided": nms_decided,
			"undecided": nms_undecided,
			"budget": reduce_nms_iter_budget,
			"budget_exhausted": nms_undecided > 0,
		}
		if nms_undecided > 0:
			push_warning("[VoxelPlacementGenerator] NMS 预算耗尽：%d 轮跑完仍有 %d/%d 个 anchor 未定型 —— 这些候选被 compact 直接丢弃（本批少放了这么多）。调大 reduce_nms_iter_budget（当前 %d）。" % [
				nms_iterations, nms_undecided, nms_valid, reduce_nms_iter_budget])
	var result_readback := BufferUtils.read_records_by_count(
		_rd, result_count_buffer, result_buffer, RECORD_STRIDE * 16, result_capacity)
	score_readback_bytes += int(result_readback["readback_bytes"])
	var result_count := int(result_readback["count"])
	var result_data: PackedByteArray = result_readback["record_bytes"]
	var results := _decode_records(result_data, result_count)
	var placement_score_sum := 0.0
	var placement_valid_count := 0
	if score_sum_buffer.is_valid():
		var score_sum_bytes := _rd.buffer_get_data(score_sum_buffer, 0, 8)
		score_readback_bytes += score_sum_bytes.size()
		# 回读短了不再静默留 0/0：调用方会把 0 分当成"这批放置一分没赚"上报。
		if score_sum_bytes.size() < 8:
			push_error("VoxelPlacementGenerator: placement_score_sum 回读字节不足 期望 8 实际 %d —— 分数汇总会被当成 0 上报" % score_sum_bytes.size())
			assert(false, "VoxelPlacementGenerator: placement score sum readback short")
			return _gpu_contract_blocked_multi_asset_output(
				complexity_field, collision_field, asset_defs,
				_gpu_contract_result(false, "placement_score_sum_readback_short"), common_settings)
		placement_score_sum = score_sum_bytes.decode_float(0)
		placement_valid_count = int(score_sum_bytes.decode_u32(4))

	var stamp_delta_count := 0
	var decoded_stamp_deltas: Array[Dictionary] = []
	if read_stamp_deltas:
		var stamp_readback := BufferUtils.read_records_by_count(
			_rd, stamp_delta_count_buffer, stamp_delta_buffer, DELTA_STRIDE * 16, stamp_capacity)
		score_readback_bytes += int(stamp_readback["readback_bytes"])
		stamp_delta_count = int(stamp_readback["count"])
		var stamp_delta_data: PackedByteArray = stamp_readback["record_bytes"]
		decoded_stamp_deltas = _decode_stamp_deltas(stamp_delta_data, stamp_delta_count)
	var stamp_bounds_data := _rd.buffer_get_data(stamp_bounds_buffer, 0, result_count * STAMP_BOUNDS_STRIDE * 16)
	score_readback_bytes += stamp_bounds_data.size()
	var stamp_bounds := _decode_stamp_bounds(stamp_bounds_data, result_count, grid_size)
	var debug_voxel_data := _rd.buffer_get_data(debug_voxel_buffer) if debug_read_voxel else PackedByteArray()
	score_readback_bytes += debug_voxel_data.size()
	# Observability opt-in: read the whole fine candidate pool back (one record
	# per anchor x topk slot) — demo/debug ranking data, never a production path.
	var fine_candidates: Array[Dictionary] = []
	var incremental_fine_validation := {}
	if bool(common_settings.get("debug_read_fine_candidates", false)) \
			or validate_incremental_fine_candidates:
		var candidate_readback := BufferUtils.read_records_by_count(
			_rd, anchor_count_buffer, candidate_buffer, RECORD_STRIDE * 16, anchor_capacity, topk, 4)
		score_readback_bytes += int(candidate_readback["readback_bytes"])
		var live_anchor_count := int(candidate_readback["count"])
		var candidate_record_count := int(candidate_readback["record_count"])
		var candidate_bytes: PackedByteArray = candidate_readback["record_bytes"]
		if bool(common_settings.get("debug_read_fine_candidates", false)):
			fine_candidates = _decode_records(candidate_bytes, candidate_record_count)
		if validate_incremental_fine_candidates:
			var winner_bytes := _rd.buffer_get_data(
				winner_buffer, 0, live_anchor_count * RECORD_STRIDE * 16)
			score_readback_bytes += winner_bytes.size()
			incremental_fine_validation = {
				"anchor_count": live_anchor_count,
				"candidate_record_count": candidate_record_count,
				"candidate_sha256": _sha256_bytes(candidate_bytes),
				"winner_record_count": live_anchor_count,
				"winner_sha256": _sha256_bytes(winner_bytes),
				"workload": _fine_workload_report(
					candidate_bytes, candidate_record_count, asset_lookup, rotation_slots),
			}
	var score_contract_debug_data := _rd.buffer_get_data(score_contract_debug_buffer)
	score_readback_bytes += score_contract_debug_data.size()
	var score_contract_debug := _decode_score_contract_debug(score_contract_debug_data)
	gpu_contract = _annotate_score_contract_debug(gpu_contract, score_contract_debug)
	_prof.mark("readback")
	if not bool(gpu_contract.get("ok", true)):
		return _gpu_contract_blocked_multi_asset_output(
			complexity_field, collision_field, asset_defs, gpu_contract, common_settings)

	# CPU state update (no GPU state chain): apply the mixed stamp deltas once.
	var current_complexity := PackedFloat32Array()
	var current_collision := PackedFloat32Array()
	var compact_state_chain_report := {}
	if not gpu_resident_fields:
		current_complexity = complexity_data.duplicate()
		current_collision = collision_data.duplicate()
		if compact_state_chain:
			compact_state_chain_report = VoxelPlacementStateChainScript._apply_stamp_deltas_to_cpu_state(
				current_complexity, current_collision, decoded_stamp_deltas, grid_size)

	# World conversion. GPU-direct writeback converts on the resident buffers
	# inside the writeback dispatch; the CPU dict path serves everything else.
	var world_results: Array = []
	var world_gpu_report := {}
	if not gpu_direct_runtime_writeback and result_count > 0:
		var world_gpu := VoxelPlacementOutputScript.results_to_world_gpu(
			results, voxel_size, grid_origin, rotation_slots, {}, get_rendering_device(), profile_arena_buffer, self)
		# 世界坐标转换失败不再静默给空 world_results：报告会同时出现
		# total_placed=N 与 world_results=[]，下游按空数组当"没放置"处理。
		if not bool(world_gpu.get("ok", false)):
			push_error("VoxelPlacementGenerator: placement 结果转世界坐标失败 reason=%s result_count=%d —— 已 stamp 进场但拿不到世界结果" % [
				str(world_gpu.get("reason", "unknown")), result_count])
			assert(false, "VoxelPlacementGenerator: placement world conversion failed")
			return _gpu_contract_blocked_multi_asset_output(
				complexity_field, collision_field, asset_defs,
				_gpu_contract_result(false, "placement_world_conversion_failed:%s" % str(world_gpu.get("reason", "unknown"))),
				common_settings)
		world_results = world_gpu.get("world_results", [])
		world_gpu_report = world_gpu.duplicate(true)
		world_gpu_report.erase("world_results")
		world_gpu_report.erase("world_result_bytes")
	elif gpu_direct_runtime_writeback:
		world_gpu_report = {
			"ok": true,
			"reason": "resident_gpu_direct_no_cpu_world_results",
			"record_count": result_count,
			"readback_source": "none",
		}

	# Per-asset grouping for the report contract.
	var asset_results: Array[Dictionary] = []
	var per_asset_results: Array = []
	var per_asset_world: Array = []
	for _i in range(asset_defs.size()):
		per_asset_results.append([])
		per_asset_world.append([])
	for record in results:
		var record_asset := int(record.get("asset_index", -1))
		if record_asset >= 0 and record_asset < asset_defs.size():
			(per_asset_results[record_asset] as Array).append(record)
	for world_record in world_results:
		var world_asset := int(world_record.get("asset_index", -1))
		if world_asset >= 0 and world_asset < asset_defs.size():
			(per_asset_world[world_asset] as Array).append(world_record)
	var total_placed := result_count
	for i in range(asset_defs.size()):
		var asset_records: Array = per_asset_results[i]
		var asset_result := {
			"asset_index": i,
			"results": asset_records,
			"world_results": per_asset_world[i],
			"result_count": asset_records.size(),
			"rotation_slots_used": rotation_slots,
			"placement_output_gpu": world_gpu_report,
			"placement_output_readback_source": str(world_gpu_report.get("readback_source", "none")),
		}
		if gpu_contract.has("reason") and str(gpu_contract.get("reason", "")) != "not_requested":
			asset_result["cpu_fallback"] = false
		asset_results.append(_emit_multi_asset_result(asset_result, include_diagnostics))

	# GPU-direct mixed-asset runtime writeback: one dispatch for the whole pool.
	var runtime_writeback_report: Dictionary = _ensure_placement_writeback()._new_gpu_autoobject_runtime_writeback_report(
		runtime_provider, profile_container, gpu_contract,
		write_accepted_placements_to_gpu_runtime, include_diagnostics)
	if gpu_direct_runtime_writeback and result_count > 0:
		var writeback: Dictionary = _ensure_placement_writeback()._write_mixed_accepted_placements_to_gpu_runtime(
			runtime_provider,
			{
				"placement_results_rid": result_buffer,
				"stamp_bounds_rid": stamp_bounds_buffer,
				"result_count": result_count,
				"asset_lookup_capacity": asset_lookup_capacity,
			},
			asset_lookup_buffer,
			profile_arena_buffer,
			rotation_slots,
			common_settings,
			{
				"grid_size": grid_size,
				"voxel_size": voxel_size,
				"grid_origin": grid_origin,
			}
		)
		_ensure_placement_writeback()._merge_gpu_autoobject_runtime_writeback_report(runtime_writeback_report, writeback)

	# Optional resident handoff for callers that keep consuming the buffers
	# after this run (untracked RIDs survive the end-of-run gc_frame; caller
	# frees them via _release_placement_result_buffers).
	var placement_result_buffers := {}
	if bool(common_settings.get("retain_placement_result_buffers", false)):
		placement_result_buffers = {
			"placement_results_rid": untrack_rid(result_buffer),
			"result_count_rid": untrack_rid(result_count_buffer),
			"stamp_bounds_rid": untrack_rid(stamp_bounds_buffer),
			"result_capacity": result_capacity,
			"result_count": result_count,
			"owner": "VoxelPlacementGenerator",
			"rendering_device": _rd,
		}

	var output := {
		"asset_results": asset_results,
		"complexity_field_out": current_complexity,
		"collision_field_out": current_collision,
		"total_placed": total_placed,
		"processing_order": range(asset_defs.size()),
		"gpu_runtime_profile_contract": gpu_contract,
		"anchor_fine_contract": {
			"origin_contract": "one_origin_per_anchor",
			"origin_count_source": "anchor_count_buffer",
			"anchor_capacity": anchor_capacity,
			"topk": topk,
			"asset_count": mini(asset_defs.size(), MAX_ASSETS),
			"candidate_pool": "anchor_x_topk_asset_x_pivot_x_yaw",
			"reduce_model": "iterative_greedy_score_nms",
			"reduce_priority": "score_desc_anchor_id_ascending",
			"reduce_capacity_cut": "none_buffer_bound_only",
			"reduce_per_asset_quota": false,
			"reduce_nms_iter_budget": reduce_nms_iter_budget,
			# 实测轮数/未定型残留。空 = 回读短了；budget_exhausted 为 true 表示本批
			# 有候选被静默丢弃（同时已 push_warning）。
			"reduce_nms_telemetry": nms_telemetry,
			"reduce_relationship_buffer": false,
			"score_model": "match_fraction",
			"min_match_fraction": min_match_fraction,
			"color_match_max_l1": color_match_max_l1,
			"collision_match_max": collision_match_max,
			"complexity_overfill_percent": complexity_overfill_percent,
			"incremental_fine_requested": incremental_fine_requested,
			"incremental_fine_active": false,
			"incremental_fine_cache_hit": incremental_fine_cache_hit,
			"incremental_fine_force_full": incremental_fine_force_full,
			"incremental_fine_validation": incremental_fine_validation \
				if validate_incremental_fine_candidates else {},
			"consumed_by_vpg": true,
		},
		"target_read_buffer_summary": _target_read_buffer_summary(target_buffer_pack),
	}
	if not placement_result_buffers.is_empty():
		output["placement_result_buffers"] = placement_result_buffers
		output["placement_score_sum"] = placement_score_sum
		output["placement_valid_count"] = placement_valid_count
	elif retain_placement_result_buffers:
		output["placement_score_sum"] = placement_score_sum
		output["placement_valid_count"] = placement_valid_count
	if read_stamp_deltas:
		output["stamp_delta_count"] = stamp_delta_count
	if not stamp_bounds.is_empty():
		output["stamp_bounds"] = stamp_bounds
	if debug_read_voxel:
		output["debug_voxel"] = voxel_debug_set.readback(self, debug_voxel_data).get("data", PackedFloat32Array())
	if bool(common_settings.get("debug_read_fine_candidates", false)):
		output["fine_candidates"] = fine_candidates
	if validate_incremental_fine_candidates:
		output["incremental_fine_validation"] = incremental_fine_validation
	if gpu_state_chain_active:
		output["gpu_state_chain"] = {
			"mode": "gpu_resident",
			"source": gpu_state_chain_source,
			"gpu_state_chaining": true,
			"cpu_state_chaining": false,
			"full_field_readback_required": false,
			"stamp_delta_cpu_state_chaining": false,
			"read_full_field_outputs": false,
			"complexity_field_buffer_rid": complexity_field_gpu_rid,
			"collision_field_buffer_rid": collision_field_gpu_rid,
			"complexity_field_buffer_borrowed": true,
			"collision_field_buffer_borrowed": true,
			"owner": gpu_state_chain_owner,
			"borrowed_from": gpu_state_chain_owner,
			"blocked_reason": "none",
		}
		output["instance_stamp_writeback"] = {
			"ok": true,
			"reason": "gpu_state_chain_stamp_committed",
			"gpu_first": true,
			"cpu_fallback": false,
			"accepted_placement_writeback_mode": "gpu_state_chain_stamp",
			"applied_count": total_placed,
			"failed_count": 0,
			"commit_owner": gpu_state_chain_owner,
		}
		if bool(common_settings.get("read_full_field_outputs", false)):
			submit_and_sync(true)
			var scene_out := _rd.buffer_get_data(complexity_field_gpu_rid)
			var collision_out := _rd.buffer_get_data(collision_field_gpu_rid)
			output["complexity_field_out"] = SceneVoxelTileCodecScript.decode_complexity_field_rgba8_alpha_bytes(scene_out, voxel_count)
			output["collision_field_out"] = SceneVoxelTileCodecScript.decode_collision_field_u32_bytes(collision_out, voxel_count)
	elif compact_state_chain:
		compact_state_chain_report["asset_index"] = -1
		compact_state_chain_report["result_count"] = result_count
		output["cpu_state_chain"] = {
			"mode": "compact_stamp_deltas",
			"source": "stamp_shader_storage_buffer",
			"cpu_state_chaining": true,
			"full_field_readback_required": false,
			"stamp_delta_cpu_state_chaining": true,
			"read_stamp_deltas": true,
			"asset_reports": [compact_state_chain_report],
			"applied_delta_count": int(compact_state_chain_report.get("applied_delta_count", 0)),
		}
	if write_accepted_placements_to_gpu_runtime:
		output["gpu_autoobject_runtime_writeback"] = ReportSchema.validate_report(
			ReportSchema.WRITEBACK_REPORT, runtime_writeback_report, include_diagnostics)
	if str(gpu_contract.get("reason", "")) != "not_requested":
		output["cpu_fallback"] = false
	_prof.mark("done")
	if _prof.enabled:
		score_resource_profile["readback_bytes"] = score_readback_bytes
		var allocated_bytes := 0
		for byte_count in (score_resource_profile.get("buffer_bytes", {}) as Dictionary).values():
			allocated_bytes += int(byte_count)
		score_resource_profile["allocated_bytes"] = allocated_bytes
		var timing_report: Dictionary = _prof.build_report()
		timing_report["resources"] = score_resource_profile
		output["score_timing_profile"] = timing_report
		print(_prof.format_report())
	return _emit_multi_asset_report(output, include_diagnostics)


## Score observation mode: Fine is the terminal GPU pass. It returns the same
## debug candidate dictionaries consumed by VolumeScoreFineSelection, while
## deliberately omitting every Reduce/Stamp/placement allocation and dispatch.
func _finish_fine_candidates_only(
	complexity_field: PackedFloat32Array,
	collision_field: PackedFloat32Array,
	asset_defs: Array,
	common_settings: Dictionary,
	include_diagnostics: bool,
	anchor_count_buffer: RID,
	candidate_buffer: RID,
	winner_buffer: RID,
	anchor_capacity: int,
	topk: int,
	score_contract_debug_buffer: RID,
	gpu_contract: Dictionary,
	target_buffer_pack: Dictionary,
	profiler,
	resource_profile: Dictionary
) -> Dictionary:
	var anchor_count_bytes := _rd.buffer_get_data(anchor_count_buffer, 0, 4)
	# 计数回读短了或超过容量都是契约破裂：原来的 clampi 会把越界计数悄悄压回
	# 容量，后续按错误条数解码整片记录（观察模式会把它当成真实分数报出去）。
	if anchor_count_bytes.size() < 4:
		push_error("VoxelPlacementGenerator: anchor_count 回读字节不足 期望 4 实际 %d" % anchor_count_bytes.size())
		assert(false, "VoxelPlacementGenerator: anchor count readback short")
		return _gpu_contract_blocked_multi_asset_output(
			complexity_field, collision_field, asset_defs,
			_gpu_contract_result(false, "fine_anchor_count_readback_short"), common_settings)
	var live_anchor_count := BufferUtils.decode_u32_count(anchor_count_bytes)
	if live_anchor_count < 0 or live_anchor_count > anchor_capacity:
		push_error("VoxelPlacementGenerator: anchor_count 越界 实际 %d 容量 %d —— 候选池解码条数会错位" % [
			live_anchor_count, anchor_capacity])
		assert(false, "VoxelPlacementGenerator: anchor count exceeds capacity")
		return _gpu_contract_blocked_multi_asset_output(
			complexity_field, collision_field, asset_defs,
			_gpu_contract_result(false, "fine_anchor_count_exceeds_capacity"), common_settings)
	profiler.mark("candidate_count_readback")
	# 胜出记录默认**不**回读：Score 只发布常驻 winner buffer 的借用 RID（见下方
	# fine_score_handoff），消费方按需自取。仍要 CPU 副本的显式消费方（当前是
	# VolumeScoreFineSelection 的 _build_model、Golden 与诊断命令）自己开这个键。
	var read_winner_bytes := bool(common_settings.get("read_fine_winner_bytes", false))
	var winner_record_count := live_anchor_count
	var winner_bytes := PackedByteArray()
	if read_winner_bytes:
		winner_bytes = _rd.buffer_get_data(
			winner_buffer, 0, winner_record_count * RECORD_STRIDE * 16)
		if winner_bytes.size() != winner_record_count * RECORD_STRIDE * 16:
			push_error("VoxelPlacementGenerator: fine winner 回读字节数不匹配 期望 %d 实际 %d（record_count=%d）—— 消费方会按锚点下标读到错位记录" % [
				winner_record_count * RECORD_STRIDE * 16, winner_bytes.size(), winner_record_count])
			assert(false, "VoxelPlacementGenerator: fine winner readback size mismatch")
			return _gpu_contract_blocked_multi_asset_output(
				complexity_field, collision_field, asset_defs,
				_gpu_contract_result(false, "fine_winner_readback_size_mismatch"), common_settings)
	profiler.mark("winner_readback")
	var read_full_candidates := bool(common_settings.get("read_fine_candidate_bytes", false)) \
		or bool(common_settings.get("debug_read_fine_candidates", false))
	var candidate_record_count := live_anchor_count * topk
	var candidate_bytes := PackedByteArray()
	if read_full_candidates:
		candidate_bytes = _rd.buffer_get_data(
			candidate_buffer, 0, candidate_record_count * RECORD_STRIDE * 16)
		if candidate_bytes.size() != candidate_record_count * RECORD_STRIDE * 16:
			push_error("VoxelPlacementGenerator: fine candidate 回读字节数不匹配 期望 %d 实际 %d（record_count=%d topk=%d）" % [
				candidate_record_count * RECORD_STRIDE * 16, candidate_bytes.size(), candidate_record_count, topk])
			assert(false, "VoxelPlacementGenerator: fine candidate readback size mismatch")
			return _gpu_contract_blocked_multi_asset_output(
				complexity_field, collision_field, asset_defs,
				_gpu_contract_result(false, "fine_candidate_readback_size_mismatch"), common_settings)
	profiler.mark("candidate_readback")
	var fine_candidates: Array[Dictionary] = []
	if bool(common_settings.get("debug_read_fine_candidates", false)):
		fine_candidates = _decode_records(candidate_bytes, candidate_record_count)
	profiler.mark("candidate_decode")
	var score_contract_debug_data := _rd.buffer_get_data(score_contract_debug_buffer)
	var score_contract_debug := _decode_score_contract_debug(score_contract_debug_data)
	gpu_contract = _annotate_score_contract_debug(gpu_contract, score_contract_debug)
	profiler.mark("contract_readback")
	if not bool(gpu_contract.get("ok", true)):
		return _gpu_contract_blocked_multi_asset_output(
			complexity_field, collision_field, asset_defs, gpu_contract, common_settings)

	var asset_results: Array[Dictionary] = []
	for i in range(asset_defs.size()):
		asset_results.append(_emit_multi_asset_result({
			"asset_index": i,
			"results": [],
			"world_results": [],
			"result_count": 0,
			"rotation_slots_used": rotation_slots,
		}, include_diagnostics))
	var output := {
		"asset_results": asset_results,
		# 输入字段原样回传（借用引用，不再 duplicate：256^2x16 下各 4MB 深拷贝；
		# 全仓无消费方读取这两个键，消费方也不得通过共享引用写入）。
		"complexity_field_out": complexity_field,
		"collision_field_out": collision_field,
		"total_placed": 0,
		"processing_order": range(asset_defs.size()),
		"gpu_runtime_profile_contract": gpu_contract,
		"anchor_fine_contract": {
			"origin_contract": "one_origin_per_anchor",
			"origin_count_source": "anchor_count_buffer",
			"anchor_capacity": anchor_capacity,
			"live_anchor_count": live_anchor_count,
			"topk": topk,
			"asset_count": mini(asset_defs.size(), MAX_ASSETS),
			"candidate_pool": "anchor_x_topk_asset_x_pivot_x_yaw",
			"score_model": "match_fraction",
			"execution_mode": "fine_candidates_only",
			"readback_mode": _fine_readback_mode(read_winner_bytes, read_full_candidates),
			"reduce_dispatched": false,
			"stamp_dispatched": false,
			"consumed_by_vpg": true,
		},
		# 常驻交接：候选/胜出记录留在显存里，消费方借 RID 自取。RID 归 VPG 所有，
		# 借方不得 free_rid——释放点见 _resident_score_candidate_buffer 的声明注释。
		"fine_score_handoff": {
			"ok": true,
			"owner": "VoxelPlacementGenerator",
			"borrowed": true,
			"fine_candidate_buffer_rid": candidate_buffer,
			"fine_winner_buffer_rid": winner_buffer,
			"anchor_count_buffer_rid": anchor_count_buffer,
			"fine_record_stride_bytes": RECORD_STRIDE * 16,
			"anchor_capacity": anchor_capacity,
			"live_anchor_count": live_anchor_count,
			"live_count_source": "anchor_count_buffer",
			"topk": topk,
			"candidate_capacity": anchor_capacity * topk,
			"candidate_buffer_bytes": _resident_score_candidate_bytes,
			"winner_buffer_bytes": _resident_score_winner_bytes,
			"rendering_device": _rd,
		},
		"target_read_buffer_summary": _target_read_buffer_summary(target_buffer_pack),
	}
	if read_winner_bytes:
		output["fine_winner_bytes"] = winner_bytes
	if bool(common_settings.get("debug_read_fine_candidates", false)):
		output["fine_candidates"] = fine_candidates
	if bool(common_settings.get("read_fine_candidate_bytes", false)):
		output["fine_candidate_bytes"] = candidate_bytes
	# anchor_count 与 contract counter 是允许的定量小回读（各 4B/一小片），winner 与
	# candidate 只有显式 opt-in 时才计入——热路径下这两项恒为 0。
	resource_profile["readback_bytes"] = anchor_count_bytes.size() \
		+ winner_bytes.size() + candidate_bytes.size() + score_contract_debug_data.size()
	resource_profile["fine_result_readback_bytes"] = winner_bytes.size() + candidate_bytes.size()
	var allocated_bytes := 0
	for byte_count in (resource_profile.get("buffer_bytes", {}) as Dictionary).values():
		allocated_bytes += int(byte_count)
	resource_profile["allocated_bytes"] = allocated_bytes
	profiler.mark("report_build")
	profiler.mark("done")
	if profiler.enabled:
		var timing_report: Dictionary = profiler.build_report()
		timing_report["resources"] = resource_profile
		output["score_timing_profile"] = timing_report
		print(profiler.format_report())
	return _emit_multi_asset_report(output, include_diagnostics)


## Validates and unpacks the prefilter's resident anchor handoff. This is the
## ONLY candidate source: missing/invalid handoff hard-fails (no all-tiles or
## CPU fallback).
func _resolve_anchor_candidate_handoff(settings: Dictionary) -> Dictionary:
	var raw = settings.get("anchor_candidate_handoff", null)
	if not (raw is Dictionary) or (raw as Dictionary).is_empty():
		return {"ok": false, "reason": "missing_anchor_candidate_handoff"}
	var handoff := raw as Dictionary
	if not bool(handoff.get("ok", false)):
		return {"ok": false, "reason": str(handoff.get("reason", "handoff_not_ok"))}
	var origin_contract := str(handoff.get("origin_contract", ""))
	if origin_contract != "one_origin_per_anchor":
		return {"ok": false, "reason": "origin_contract_mismatch:%s" % origin_contract}
	var anchor_buffer: RID = VariantUtils.rid_from_value(handoff.get("anchor_buffer_rid", RID()))
	var anchor_count_buffer: RID = VariantUtils.rid_from_value(handoff.get("anchor_count_buffer_rid", RID()))
	var topk_buffer: RID = VariantUtils.rid_from_value(handoff.get("topk_buffer_rid", RID()))
	if not anchor_buffer.is_valid() or not anchor_count_buffer.is_valid() or not topk_buffer.is_valid():
		return {"ok": false, "reason": "anchor_handoff_rid_invalid"}
	var anchor_capacity := int(handoff.get("anchor_capacity", 0))
	var topk := int(handoff.get("topk", 0))
	if anchor_capacity <= 0 or topk <= 0:
		return {"ok": false, "reason": "anchor_handoff_capacity_invalid"}
	return {
		"ok": true,
		"reason": "ok",
		"anchor_buffer_rid": anchor_buffer,
		"anchor_count_buffer_rid": anchor_count_buffer,
		"topk_buffer_rid": topk_buffer,
		"anchor_capacity": anchor_capacity,
		"topk": topk,
		"asset_count": int(handoff.get("asset_count", 0)),
	}


## Resolves the profile container's resident buffers (asset shape + pivot
## source of truth) and aligns this generator to the container's device.
func _resolve_profile_container_buffers(settings: Dictionary) -> Dictionary:
	var container = _config_object(settings, GPU_PROFILE_CONTAINER_CONFIG_KEY)
	if container == null:
		return {"ok": false, "reason": "missing_auto_voxel_runtime_profile_container"}
	if not _object_bool(container, "is_runtime_ready", "is_gpu_ready"):
		return {"ok": false, "reason": "auto_voxel_runtime_profile_container_not_ready"}
	var container_rd: RenderingDevice = rendering_device_of(container)
	if container_rd == null:
		return {"ok": false, "reason": "container_missing_rendering_device"}
	if get_rendering_device() == null:
		if not attach_rendering_device(container_rd, false):
			return {"ok": false, "reason": "vpg_attach_rendering_device_failed"}
	elif get_rendering_device() != container_rd:
		return {"ok": false, "reason": "rendering_device_mismatch"}
	# 固定槽位 Arena：Header/Samples/Pivots/Mesh 的**唯一** binding。
	var profile_arena_buffer: RID = container.call("get_gpu_buffer", "profile_arena")
	if not profile_arena_buffer.is_valid():
		return {"ok": false, "reason": "missing_auto_voxel_profile_buffers"}
	var profile_count := 0
	if container.has_method("get_profile_count"):
		profile_count = int(container.get_profile_count())
	# Arena slot 数（= PROFILE_CAPACITY）。sample/pivot 的每槽上限已是 shader 侧的编译期
	# 常量，不再需要 host 传元素数——那是扁平 buffer 时代的容量门参数。
	# _container_record_count 拿不到时返回 -1：向上阻断，不带无效容量继续。
	var profile_arena_capacity := _container_record_count(container, "profile_arena")
	if profile_arena_capacity < 0:
		return {"ok": false, "reason": "profile_container_record_count_unavailable"}
	return {
		"ok": true,
		"reason": "ok",
		"container": container,
		"profile_arena_buffer": profile_arena_buffer,
		"profile_count": profile_count,
		"profile_arena_capacity": profile_arena_capacity,
	}


## 容量守卫用的显式元素数：优先容器的 get_gpu_record_count，缺失时退回
## get_gpu_buffer_summary 的 record_count。两条都拿不到时返回 -1（硬失败信号，由
## _resolve_profile_container_buffers 向上阻断）——绝不兜底成 0：0 会让 shader 的容量门
## 丢弃所有采样/枢轴读，表现为"跑通了但一个都没放置"。
func _container_record_count(container, buffer_name: String) -> int:
	if container.has_method("get_gpu_record_count"):
		return maxi(int(container.get_gpu_record_count(buffer_name)), 0)
	if container.has_method("get_gpu_buffer_summary"):
		var raw_summary = container.get_gpu_buffer_summary()
		if raw_summary is Dictionary:
			var buffers: Dictionary = (raw_summary as Dictionary).get("buffers", {})
			var entry_value = buffers.get(buffer_name, {})
			if entry_value is Dictionary:
				return maxi(int((entry_value as Dictionary).get("record_count", 0)), 0)
	push_error("VoxelPlacementGenerator: profile 容器无法提供 '%s' 的记录数（缺 get_gpu_record_count，且 get_gpu_buffer_summary 未给出该 buffer 条目）—— shader 容量门会拿到无效容量" % buffer_name)
	assert(false, "VoxelPlacementGenerator: container record count unavailable")
	return -1


## Packs the asset_lookup ivec4 stream: asset_index -> (profile_id,
## profile_index, quota, object_type). Assets whose profile has no baked AD
## fine samples get profile_index -1 (the scorer writes invalid records for them).
## quota <= 0 means unlimited; per-asset quota comes from asset_def.quota or
## asset_def.result_capacity. Also derives the per-asset spacing radius stream
## (float voxels, from asset_def.spacing_radius_world) for the reduce's
## pairwise asset-size-aware conflict distance.
## AssetDescriptor 逐资产评分覆盖属性名（固定顺序；每项 -1=继承全局）。per-asset score
## SSBO 按 8 floats/asset 打包（7 值 + 1 pad），fine shader set1 binding15 按 asset_id 读、
## 用 (per_asset >= 0 ? per_asset : 全局push) 解析继承。
const SCORE_OVERRIDE_PROPS: Array[String] = [
	"score_min_match_fraction",
	"score_dim_weight_collision",
	"score_dim_weight_complexity",
	"score_dim_weight_color",
	"score_color_match_max_l1",
	"score_collision_match_max",
	"score_complexity_overfill_percent",
]


func _build_asset_lookup(asset_defs: Array, container, common_settings: Dictionary, voxel_size: Vector3 = Vector3.ONE) -> Dictionary:
	var profile_index_by_id := {}
	var profile_entry_by_id := {}
	if container != null and container.has_method("export_profile_table"):
		for entry in container.export_profile_table():
			if entry is Dictionary:
				var profile_id := int((entry as Dictionary).get("profile_id", -1))
				profile_index_by_id[profile_id] = int((entry as Dictionary).get("profile_index", -1))
				profile_entry_by_id[profile_id] = entry
	var count := mini(asset_defs.size(), MAX_ASSETS)
	var bytes := PackedByteArray()
	bytes.resize(maxi(count, 1) * 16)
	# Per-asset fine-score param overrides — 8 floats/asset (7 values + 1 pad); -1 = inherit.
	var score_bytes := PackedByteArray()
	score_bytes.resize(maxi(count, 1) * 32)
	var spacing_floats := PackedFloat32Array()
	spacing_floats.resize(maxi(count, 1))
	var voxel_xz := maxf(maxf(voxel_size.x, voxel_size.z), 0.0001)
	var max_ad_count := 0
	var max_spacing_radius := 0.0
	var profile_ids: Array[int] = []
	var fine_sample_counts: Array[int] = []
	var pivot_counts: Array[int] = []
	var asset_ids: Array[String] = []
	for i in range(count):
		var asset_def: Dictionary = asset_defs[i] if asset_defs[i] is Dictionary else {}
		var profile_id := int(asset_def.get("profile_id", -1))
		var ad_count := 0
		if container != null and container.has_method("get_fine_sample_range_for_profile_id"):
			ad_count = int((container.get_fine_sample_range_for_profile_id(profile_id) as Dictionary).get("count", 0))
		var profile_index := int(profile_index_by_id.get(profile_id, -1)) if ad_count > 0 else -1
		var profile_entry: Dictionary = profile_entry_by_id.get(profile_id, {})
		var pivot_range: Dictionary = profile_entry.get("pivot_range", {})
		var pivot_count := int(pivot_range.get("count", 0))
		var quota := int(asset_def.get("quota", asset_def.get("result_capacity", 0)))
		var object_type := VoxelPlacementWritebackScript._runtime_writeback_object_type(asset_def, {}, common_settings)
		max_ad_count = maxi(max_ad_count, ad_count)
		var spacing_radius_voxels := maxf(float(asset_def.get("spacing_radius_world", 0.0)), 0.0) / voxel_xz
		spacing_floats[i] = spacing_radius_voxels
		max_spacing_radius = maxf(max_spacing_radius, spacing_radius_voxels)
		profile_ids.append(profile_id)
		fine_sample_counts.append(ad_count)
		pivot_counts.append(pivot_count)
		asset_ids.append(str(asset_def.get("asset_id", "asset_%d" % i)))
		var base := i * 16
		bytes.encode_s32(base + 0, profile_id)
		bytes.encode_s32(base + 4, profile_index)
		bytes.encode_s32(base + 8, quota)
		bytes.encode_s32(base + 12, object_type)
		# Per-asset score overrides from the descriptor (-1 = inherit global). Read
		# properties directly (readable even on editor placeholder instances).
		var descriptor = asset_def.get("descriptor")
		var sbase := i * 32
		for k in range(SCORE_OVERRIDE_PROPS.size()):
			var ov := -1.0
			if descriptor is Object:
				var raw = (descriptor as Object).get(SCORE_OVERRIDE_PROPS[k])
				if raw != null:
					ov = float(raw)
			score_bytes.encode_float(sbase + k * 4, ov)
		score_bytes.encode_float(sbase + 28, 0.0)  # 8th float pad
	return {
		"bytes": bytes,
		"score_params_bytes": score_bytes,
		"max_ad_count": max_ad_count,
		"asset_count": count,
		"spacing_floats": spacing_floats,
		"max_spacing_radius_voxels": max_spacing_radius,
		"profile_ids": profile_ids,
		"fine_sample_counts": fine_sample_counts,
		"pivot_counts": pivot_counts,
		"asset_ids": asset_ids,
	}


## Resolves the TargetSV field + collision buffer pair from the target reader pack.
## **resident-GPU-only**：pack 只产出借用常驻对，故无 CPU 上传分支、缺 collision 也不补零
## ——零 target collision 会被评分链当成"无碰撞目标"的真值，静默评出一批错误放置。
## 任何不合规都硬失败（返回无效 RID 对，调用方据此阻断）。
func _resolve_target_buffers(target_buffer_pack: Dictionary, _settings: Dictionary, voxel_count: int) -> Dictionary:
	var target_field_buffer: RID = target_buffer_pack.get("target_field_buffer", RID())
	var target_collision_buffer: RID = target_buffer_pack.get("target_collision_buffer", RID())
	var borrowed := bool(target_buffer_pack.get("target_read_buffers_borrowed", false))
	if not borrowed or not target_field_buffer.is_valid() or not target_collision_buffer.is_valid():
		push_error("VoxelPlacementGenerator: TargetSV 读缓冲非常驻借用 borrowed=%s field_valid=%s collision_valid=%s voxel_count=%d —— 拒绝用上传/补零的替代目标场评分" % [
			borrowed, target_field_buffer.is_valid(), target_collision_buffer.is_valid(), voxel_count])
		assert(false, "VoxelPlacementGenerator: target read buffers not resident")
		return {
			"target_field_buffer": RID(),
			"target_collision_buffer": RID(),
		}
	track_borrowed_rid(target_field_buffer, KIND_BUFFER, SCOPE_FRAME, "scene_placement_actor:target_field")
	track_borrowed_rid(target_collision_buffer, KIND_BUFFER, SCOPE_FRAME, "scene_placement_actor:target_collision")
	return {
		"target_field_buffer": target_field_buffer,
		"target_collision_buffer": target_collision_buffer,
	}




## GPU 打包非常驻 CurrentSV 读对（pack_placement_field_pair.glsl）：fitted scalar 场原样
## memcpy 上传，一线程一体素量化写 complexity rgba8 + collision u32 读对。替代 codec 的
## CPU 逐体素循环（256³ 实测 1110ms → 上传 memcpy 量级）。量化语义同 codec scalar 分支，
## 容差 = 单向 1 LSB。pipeline / uniform set / dispatch 任一不可用即硬失败（返回空字典，
## 调用方阻断）——CPU codec 回退已撤除，否则编译/绑定故障会静默降级成 1110ms 的 CPU 路径。
func _dispatch_pack_field_pair(complexity_data: PackedFloat32Array, collision_data: PackedFloat32Array, voxel_count: int) -> Dictionary:
	if not _pipeline_pack_field_pair.is_valid() or not _shader_pack_field_pair.is_valid():
		push_error("VoxelPlacementGenerator: pack_placement_field_pair 管线未就绪 shader_valid=%s pipeline_valid=%s" % [
			_shader_pack_field_pair.is_valid(), _pipeline_pack_field_pair.is_valid()])
		assert(false, "VoxelPlacementGenerator: pack_placement_field_pair pipeline not ready")
		return {}
	if complexity_data.size() < voxel_count or collision_data.size() < voxel_count:
		push_error("VoxelPlacementGenerator: CurrentSV 输入场长度不足 complexity=%d collision=%d 期望 >= voxel_count=%d" % [
			complexity_data.size(), collision_data.size(), voxel_count])
		assert(false, "VoxelPlacementGenerator: current field array shorter than voxel_count")
		return {}
	var complexity_values_buffer := storage_buffer_from_bytes(
		complexity_data.to_byte_array(), SCOPE_FRAME, "placement_complexity_values")
	var collision_values_buffer := storage_buffer_from_bytes(
		collision_data.to_byte_array(), SCOPE_FRAME, "placement_collision_values")
	var complexity_buffer := storage_buffer_zero(voxel_count * 4, SCOPE_FRAME, "placement_complexity_field_rgba8")
	var collision_buffer := storage_buffer_zero(voxel_count * 4, SCOPE_FRAME, "placement_collision_field_u32")
	var set0 := create_uniform_set([
		make_storage_uniform(0, complexity_values_buffer),
		make_storage_uniform(1, collision_values_buffer),
		make_storage_uniform(2, complexity_buffer),
		make_storage_uniform(3, collision_buffer),
	], _shader_pack_field_pair, 0)
	if not set0.is_valid():
		# 上传/输出缓冲留给 SCOPE_FRAME GC；绝不带着全零场继续放置。
		push_error("VoxelPlacementGenerator: pack_placement_field_pair uniform set 创建失败 voxel_count=%d" % voxel_count)
		assert(false, "VoxelPlacementGenerator: pack_placement_field_pair uniform set failed")
		return {}
	var push := PushConstantLayout.new(PACK_FIELD_PAIR_PUSH).pack({
		voxel_count = voxel_count,
	})
	var dispatched := ComputePassChain.run(self, [
		{pipeline = _pipeline_pack_field_pair, uniform_sets = [set0], push = push, groups = Vector3i(ceil_div(maxi(voxel_count, 1), 64), 1, 1)},
	], false)
	if not dispatched:
		push_error("VoxelPlacementGenerator: pack_placement_field_pair 派发失败 voxel_count=%d —— 读对仍是全零" % voxel_count)
		assert(false, "VoxelPlacementGenerator: pack_placement_field_pair dispatch failed")
		return {}
	return {
		"complexity_buffer": complexity_buffer,
		"collision_buffer": collision_buffer,
	}


## 当 GPU 运行时契约校验失败时，为 run_multi_asset 构造统一的"已阻断"空结果：
## 为每个资产生成占位失败结果，并原样返回输入的 complexity/collision 字段。
func _gpu_contract_blocked_multi_asset_output(
	complexity_field: PackedFloat32Array,
	collision_field: PackedFloat32Array,
	asset_defs: Array,
	contract: Dictionary,
	settings: Dictionary = {},
	extra: Dictionary = {}
) -> Dictionary:
	var include_diagnostics := bool(settings.get("include_diagnostics", false))
	var asset_results: Array[Dictionary] = []
	for i in range(asset_defs.size()):
		asset_results.append(_emit_multi_asset_result({
			"ok": false,
			"asset_index": i,
			"results": [],
			"world_results": [],
			"result_count": 0,
			"gpu_runtime_profile_contract": contract,
			"contract_blocked": true,
			"gpu_first": true,
			"cpu_fallback": false,
			"runtime_read_source": "none",
			"readback_source": "none",
		}, include_diagnostics))
	var values := {
		"ok": false,
		"asset_results": asset_results,
		"complexity_field_out": complexity_field.duplicate(),
		"collision_field_out": collision_field.duplicate(),
		"total_placed": 0,
		"processing_order": [],
		"gpu_runtime_profile_contract": contract,
		"contract_blocked": true,
		"skipped_gpu_runtime_profile_contract": true,
		"gpu_first": true,
		"cpu_fallback": false,
		"runtime_read_source": "none",
		"readback_source": "none",
	}
	for key in extra:
		values[key] = extra[key]
	return _emit_multi_asset_report(values, include_diagnostics)


## 空候选/空资产形状时的空结果（非契约阻断，正常空帧）。
func _empty_placement_output(
	complexity_field: PackedFloat32Array,
	collision_field: PackedFloat32Array,
	asset_defs: Array,
	reason: String,
	settings: Dictionary
) -> Dictionary:
	var include_diagnostics := bool(settings.get("include_diagnostics", false))
	var asset_results: Array[Dictionary] = []
	for i in range(asset_defs.size()):
		asset_results.append(_emit_multi_asset_result({
			"asset_index": i, "results": [], "world_results": [], "result_count": 0,
		}, include_diagnostics))
	return _emit_multi_asset_report({
		"asset_results": asset_results,
		"complexity_field_out": complexity_field.duplicate(),
		"collision_field_out": collision_field.duplicate(),
		"total_placed": 0,
		"processing_order": [],
		"anchor_fine_contract": {
			"origin_contract": "one_origin_per_anchor",
			"origin_count_source": "anchor_count_buffer",
			"consumed_by_vpg": false,
			"skipped_reason": reason,
		},
	}, include_diagnostics)


## 唯一发射口：run_multi_asset 顶层输出族一律经 ReportSchema.build 组装
##（键清单/分级/消费者名单见 ReportSchema.VPG_MULTI_ASSET_REPORT）。
func _emit_multi_asset_report(values: Dictionary, include_diagnostics: bool = false) -> Dictionary:
	return ReportSchema.build(ReportSchema.VPG_MULTI_ASSET_REPORT, values, include_diagnostics)


## 唯一发射口：per-asset asset_result 族一律经 ReportSchema.build 组装
##（键清单/分级/消费者名单见 ReportSchema.VPG_MULTI_ASSET_RESULT）。
func _emit_multi_asset_result(values: Dictionary, include_diagnostics: bool = false) -> Dictionary:
	return ReportSchema.build(ReportSchema.VPG_MULTI_ASSET_RESULT, values, include_diagnostics)


const SCORE_MATCH_CONFIG_PATH := "res://score_match_config.cfg"


## 从 score_match_config.cfg 读严格匹配阈值（[score_match] 段）。文件缺失 = 用代码默认值；
## 段/键缺失 = 保留当前值；每次 _apply_settings 都重读，改文件后重跑放置即生效（无需重启）。
func _load_score_match_config() -> void:
	if not FileAccess.file_exists(SCORE_MATCH_CONFIG_PATH):
		return
	var cfg := ConfigFile.new()
	var err := cfg.load(SCORE_MATCH_CONFIG_PATH)
	if err != OK:
		push_warning("VoxelPlacementGenerator: score_match_config.cfg 解析失败 (err=%d)，沿用当前阈值" % err)
		return
	min_match_fraction = clampf(float(cfg.get_value("score_match", "min_match_fraction", min_match_fraction)), 0.0, 1.0)
	color_match_max_l1 = clampf(float(cfg.get_value("score_match", "color_match_max_l1", color_match_max_l1)), 0.0, 3.0)
	collision_match_max = clampf(float(cfg.get_value("score_match", "collision_match_max", collision_match_max)), 0.0, 1.0)
	complexity_overfill_percent = clampf(float(cfg.get_value("score_match", "complexity_overfill_percent", complexity_overfill_percent)), 0.0, 1000.0)
	# 五维 residual-gain 权重（[residual_weights] 段；三个 color 通道共享一个权重 → 3 旋钮 = 5 维）。
	# score_match_config.cfg 可覆盖本段；缺段/缺键则沿用当前（代码默认）值。
	dim_weight_collision = maxf(float(cfg.get_value("residual_weights", "collision", dim_weight_collision)), 0.0)
	dim_weight_complexity = maxf(float(cfg.get_value("residual_weights", "complexity", dim_weight_complexity)), 0.0)
	dim_weight_color = maxf(float(cfg.get_value("residual_weights", "color", dim_weight_color)), 0.0)


## 将 settings 字典中的可选覆盖值应用到打分/放置相关成员变量，并做取值范围钳制。
## 严格匹配阈值先从 config 文件载入，settings 字典键在其上仍可逐调用覆盖。
func _apply_settings(settings: Dictionary) -> void:
	_load_score_match_config()
	result_capacity = maxi(int(settings.get("result_capacity", result_capacity)), 1)
	solid_threshold = float(settings.get("solid_threshold", solid_threshold))
	collision_limit = float(settings.get("collision_limit", collision_limit))
	clearance_limit = float(settings.get("clearance_limit", clearance_limit))
	min_distance_voxels = float(settings.get("min_distance_voxels", min_distance_voxels))
	anchor_interval_voxels = maxi(int(settings.get("anchor_interval_voxels", anchor_interval_voxels)), 0)
	anchor_phase_x = int(settings.get("anchor_phase_x", anchor_phase_x))
	anchor_phase_z = int(settings.get("anchor_phase_z", anchor_phase_z))
	asset_spacing_factor = maxf(float(settings.get("asset_spacing_factor", asset_spacing_factor)), 0.0)
	reduce_nms_iter_budget = maxi(int(settings.get("reduce_nms_iter_budget", reduce_nms_iter_budget)), 1)
	scene_write_scale = float(settings.get("scene_write_scale", scene_write_scale))
	collision_write_scale = float(settings.get("collision_write_scale", collision_write_scale))
	rotation_slots = maxi(int(settings.get("rotation_slots", rotation_slots)), 1)
	min_match_fraction = clampf(float(settings.get("min_match_fraction", min_match_fraction)), 0.0, 1.0)
	var dim_weights = settings.get("residual_dim_weights", null)
	if dim_weights is Array and (dim_weights as Array).size() >= 3:
		dim_weight_collision = maxf(float((dim_weights as Array)[0]), 0.0)
		dim_weight_complexity = maxf(float((dim_weights as Array)[1]), 0.0)
		dim_weight_color = maxf(float((dim_weights as Array)[2]), 0.0)
	color_match_max_l1 = clampf(float(settings.get("color_match_max_l1", color_match_max_l1)), 0.0, 3.0)
	collision_match_max = clampf(float(settings.get("collision_match_max", collision_match_max)), 0.0, 1.0)
	complexity_overfill_percent = clampf(float(settings.get("complexity_overfill_percent", complexity_overfill_percent)), 0.0, 1000.0)
	var global_quota := int(settings.get("global_quota", -1))
	if global_quota > 0:
		result_capacity = mini(result_capacity, global_quota)
## 校验 GPU 自动物体运行时与体素画像容器是否就绪、渲染设备是否一致、
## 所需 GPU 缓冲区是否齐全，构建并返回 gpu_runtime_profile_contract 校验结果。
func _validate_gpu_runtime_profile_contract(settings: Dictionary) -> Dictionary:
	var runtime_provider = _config_object(settings, GPU_RUNTIME_PROVIDER_CONFIG_KEY)
	var profile_container = _config_object(settings, GPU_PROFILE_CONTAINER_CONFIG_KEY)
	var require_contract := bool(settings.get("require_gpu_runtime_profile_contract", false))
	if runtime_provider == null and profile_container == null:
		if require_contract:
			return _gpu_contract_result(false, "missing_gpu_runtime_profile_contract")
		return _gpu_contract_result(true, "not_requested")
	if runtime_provider == null:
		# A standalone container is a valid shape source; profile_sample_records are
		# _resolve_profile_container_buffers 独立解析；只有显式 require（GPU 直写
		# 回写路径）才把缺 runtime 视为契约失败。
		if require_contract:
			return _gpu_contract_result(false, "missing_gpu_autoobject_runtime")
		return _gpu_contract_result(true, "not_requested")
	if profile_container == null:
		return _gpu_contract_result(false, "missing_auto_voxel_runtime_profile_container")

	var runtime_ready := _object_bool(runtime_provider, "is_gpu_ready", "is_ready")
	if not runtime_ready:
		return _gpu_contract_result(false, "gpu_autoobject_runtime_not_ready", runtime_provider, profile_container)
	var profile_ready := _object_bool(profile_container, "is_runtime_ready", "is_gpu_ready")
	if not profile_ready:
		return _gpu_contract_result(false, "auto_voxel_runtime_profile_container_not_ready", runtime_provider, profile_container)

	var runtime_rd: RenderingDevice = rendering_device_of(runtime_provider)
	var profile_rd: RenderingDevice = rendering_device_of(profile_container)
	if runtime_rd == null or profile_rd == null:
		return _gpu_contract_result(false, "missing_rendering_device", runtime_provider, profile_container)
	if runtime_rd != profile_rd:
		return _gpu_contract_result(false, "rendering_device_mismatch", runtime_provider, profile_container)

	if get_rendering_device() == null:
		if not attach_rendering_device(runtime_rd, false):
			return _gpu_contract_result(false, "vpg_attach_rendering_device_failed", runtime_provider, profile_container)
	elif get_rendering_device() != runtime_rd:
		return _gpu_contract_result(false, "vpg_rendering_device_mismatch", runtime_provider, profile_container)

	var runtime_buffers := _collect_gpu_buffers(runtime_provider, REQUIRED_GPU_RUNTIME_BUFFERS)
	var missing_runtime: Array[String] = runtime_buffers.get("missing", [])
	if not missing_runtime.is_empty():
		var result := _gpu_contract_result(false, "missing_gpu_autoobject_runtime_buffers", runtime_provider, profile_container)
		result["missing_runtime_buffers"] = missing_runtime
		return result

	var profile_buffers := _collect_gpu_buffers(profile_container, REQUIRED_GPU_PROFILE_BUFFERS)
	var missing_profiles: Array[String] = profile_buffers.get("missing", [])
	if not missing_profiles.is_empty():
		var result := _gpu_contract_result(false, "missing_auto_voxel_profile_buffers", runtime_provider, profile_container)
		result["missing_profile_buffers"] = missing_profiles
		return result

	_track_borrowed_gpu_buffers(runtime_buffers.get("buffers", {}), "gpu_autoobject_runtime")
	_track_borrowed_gpu_buffers(profile_buffers.get("buffers", {}), "auto_voxel_runtime_profile_container")

	var ok := _gpu_contract_result(true, "gpu_runtime_profile_buffers_ready", runtime_provider, profile_container)
	ok["runtime_buffers"] = runtime_buffers.get("buffers", {})
	ok["profile_buffers"] = profile_buffers.get("buffers", {})
	ok["runtime_buffer_count"] = (runtime_buffers.get("buffers", {}) as Dictionary).size()
	ok["profile_buffer_count"] = (profile_buffers.get("buffers", {}) as Dictionary).size()
	return ok


## 构造标准化的 GPU 契约结果字典（ok/reason/gpu_first 等字段），
## 可选附加运行时提供者与 profile 容器的调试摘要信息。
func _gpu_contract_result(
	ok: bool,
	reason: String,
	runtime_provider = null,
	profile_container = null
) -> Dictionary:
	var result := {
		"ok": ok,
		"reason": reason,
		"gpu_first": true,
		"cpu_fallback": false,
		"contract_blocked": not ok,
		"requires_rendering_device": reason != "not_requested",
		"runtime_read_source": "gpu_storage_buffers" if ok and reason == "gpu_runtime_profile_buffers_ready" else "none",
		"readback_source": "none",
	}
	if runtime_provider != null:
		result["runtime_summary"] = _object_summary(runtime_provider)
	if profile_container != null:
		result["profile_summary"] = _object_summary(profile_container)
	return result


## 从 settings 按 key 取出配置对象；不存在或类型不为 Object 时返回 null。
func _config_object(settings: Dictionary, key: String) -> Object:
	var value = settings.get(key)
	if value is Object:
		return value as Object
	return null


## 调用 object 上的 primary_method（缺失则尝试 secondary_method）并返回其布尔结果；object 为空时返回 false。
## object 非空但两个方法都没有 = 传进来的根本不是约定的 runtime/容器对象：不再兜底返回
## false（那会被上游翻译成"未就绪"，把接口不匹配伪装成时序问题）。
func _object_bool(object: Object, primary_method: String, secondary_method: String = "") -> bool:
	if object == null:
		return false
	if object.has_method(primary_method):
		return bool(object.call(primary_method))
	if not secondary_method.is_empty() and object.has_method(secondary_method):
		return bool(object.call(secondary_method))
	push_error("VoxelPlacementGenerator: 对象 %s 既没有 %s() 也没有 %s()，不符合约定接口" % [
		object.get_class(), primary_method, secondary_method if not secondary_method.is_empty() else "<none>"])
	assert(false, "VoxelPlacementGenerator: object missing required boolean accessors")
	return false


## 调用 object 的 get_gpu_buffer_summary，取得其调试摘要字典的副本。
func _object_summary(object: Object) -> Dictionary:
	if object == null:
		return {}
	if object.has_method("get_gpu_buffer_summary"):
		var summary = object.call("get_gpu_buffer_summary")
		if summary is Dictionary:
			return (summary as Dictionary).duplicate(true)
	return {}


## 从 provider 按名称批量获取 GPU 缓冲区 RID，返回已获取的缓冲区字典与缺失名称列表。
func _collect_gpu_buffers(provider: Object, buffer_names: Array) -> Dictionary:
	var buffers := {}
	var missing: Array[String] = []
	if provider == null or not provider.has_method("get_gpu_buffer"):
		for raw_name in buffer_names:
			missing.append(str(raw_name))
		return {"buffers": buffers, "missing": missing}
	for raw_name in buffer_names:
		var buffer_name := str(raw_name)
		var rid: RID = provider.call("get_gpu_buffer", buffer_name)
		if not rid.is_valid():
			missing.append(buffer_name)
			continue
		buffers[buffer_name] = rid
	return {"buffers": buffers, "missing": missing}


## 将 buffers 中每个有效 RID 登记为本帧借用的 GPU 缓冲区，用于生命周期追踪。
func _track_borrowed_gpu_buffers(buffers: Dictionary, label_prefix: String) -> void:
	for buffer_name in buffers.keys():
		var rid: RID = buffers[buffer_name]
		if rid.is_valid():
			track_borrowed_rid(rid, KIND_BUFFER, SCOPE_FRAME, "%s:%s" % [label_prefix, str(buffer_name)])


func _ensure_resident_place_candidate_buffer(byte_count: int, cache_key: Dictionary) -> Dictionary:
	var safe_byte_count := maxi(byte_count, 4)
	var key_matches := _resident_place_candidate_buffer.is_valid() \
		and _resident_place_candidate_buffer_bytes == safe_byte_count \
		and not _resident_place_candidate_cache_key.is_empty() \
		and _resident_place_candidate_cache_key == cache_key
	var cache_hit := key_matches and _resident_place_candidate_initialized
	if not key_matches:
		_release_resident_place_candidate_buffer()
		_resident_place_candidate_buffer = storage_buffer_uninitialized(
			safe_byte_count, SCOPE_PERSISTENT, "resident_place_fine_candidates")
		if _resident_place_candidate_buffer.is_valid():
			_resident_place_candidate_buffer_bytes = safe_byte_count
			_resident_place_candidate_cache_key = cache_key.duplicate(true)
	return {
		"buffer": _resident_place_candidate_buffer,
		"cache_hit": cache_hit,
	}


func _release_resident_place_candidate_buffer() -> void:
	if _resident_place_candidate_buffer.is_valid():
		release_rid(_resident_place_candidate_buffer)
	_resident_place_candidate_buffer = RID()
	_resident_place_candidate_buffer_bytes = 0
	_resident_place_candidate_cache_key = {}
	_resident_place_candidate_initialized = false


## 有符号余隙场的常驻缓冲（grid_x * grid_z 个 uint）。
## `reset` = true（会话首批 / 单发调用）或尺寸变化时**整块重建成零缓冲**——0 = 未画 =
## 无约束，新零缓冲本身就是合法初值，故刻意不用 buffer_clear / buffer_update。上一批的
## dispatch 已在 run_multi_asset 收尾的 submit_and_sync 后完成，重建无跨提交写后读冒险。
func _ensure_resident_clearance_field_buffer(pixel_count: int, reset: bool) -> RID:
	var safe_bytes := maxi(pixel_count, 1) * 4
	if _resident_clearance_field_buffer.is_valid() \
			and _resident_clearance_field_bytes == safe_bytes \
			and not reset:
		return _resident_clearance_field_buffer
	_release_resident_clearance_field_buffer()
	_resident_clearance_field_buffer = storage_buffer_zero(
		safe_bytes, SCOPE_PERSISTENT, "placement_clearance_field")
	_resident_clearance_field_bytes = safe_bytes if _resident_clearance_field_buffer.is_valid() else 0
	return _resident_clearance_field_buffer


## 「一条记录 = 一个工作组」的组数铺法。paint_placement_clearance 按
## `wg.x + wg.y * gl_NumWorkGroups.x` 还原记录下标，所以这里可以随意折行——折行只是为了
## 不撞单维组数上限（Vulkan 常见 65535），result_capacity 可以开得很大，迟早会超。
const RECORD_GROUP_ROW_LENGTH := 32768

func _record_group_layout(record_count: int) -> Vector3i:
	var count := maxi(record_count, 1)
	if count <= RECORD_GROUP_ROW_LENGTH:
		return Vector3i(count, 1, 1)
	return Vector3i(RECORD_GROUP_ROW_LENGTH, ceil_div(count, RECORD_GROUP_ROW_LENGTH), 1)


func _release_resident_clearance_field_buffer() -> void:
	if _resident_clearance_field_buffer.is_valid():
		release_rid(_resident_clearance_field_buffer)
	_resident_clearance_field_buffer = RID()
	_resident_clearance_field_bytes = 0


## Score 常驻候选/胜出对：形状一致就整对复用，形状变了就整对重建（不做半新半旧）。
## 返回是否两块都可用；false 时调用方必须判死本轮 Score，不得带着半块常驻继续派发。
## ⚠ 只按形状复用、不按内容复用：Score 每轮把全部候选整批重写，故无需内容级 cache key。
func _ensure_resident_score_buffers(candidate_bytes: int, winner_bytes: int) -> bool:
	var safe_candidate_bytes := maxi(candidate_bytes, 4)
	var safe_winner_bytes := maxi(winner_bytes, 4)
	var shape_key := {
		"candidate_bytes": safe_candidate_bytes,
		"winner_bytes": safe_winner_bytes,
	}
	if _resident_score_candidate_buffer.is_valid() \
			and _resident_score_winner_buffer.is_valid() \
			and _resident_score_shape_key == shape_key:
		return true
	_release_resident_score_buffers()
	_resident_score_candidate_buffer = storage_buffer_uninitialized(
		safe_candidate_bytes, SCOPE_PERSISTENT, "resident_score_fine_candidates")
	_resident_score_winner_buffer = storage_buffer_uninitialized(
		safe_winner_bytes, SCOPE_PERSISTENT, "resident_score_fine_winners")
	if not _resident_score_candidate_buffer.is_valid() or not _resident_score_winner_buffer.is_valid():
		return false
	_resident_score_candidate_bytes = safe_candidate_bytes
	_resident_score_winner_bytes = safe_winner_bytes
	_resident_score_shape_key = shape_key.duplicate(true)
	return true


func _release_resident_score_buffers() -> void:
	if _resident_score_candidate_buffer.is_valid():
		release_rid(_resident_score_candidate_buffer)
	if _resident_score_winner_buffer.is_valid():
		release_rid(_resident_score_winner_buffer)
	_resident_score_candidate_buffer = RID()
	_resident_score_candidate_bytes = 0
	_resident_score_winner_buffer = RID()
	_resident_score_winner_bytes = 0
	_resident_score_shape_key = {}


## 显式失效 Score 常驻交接。调用方（SPA）在 score cache 失效、Anchor handoff 换代或
## 场景卸载时调用；之后 fine_score_handoff 里的 RID 立即作废，不得再借。
func release_resident_score_handoff() -> void:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	_release_resident_score_buffers()


## Score 常驻交接的当前状态（借用方/审计用；不含 RID，取 RID 走 run 返回的 handoff）。
func get_resident_score_handoff_summary() -> Dictionary:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	return {
		"resident": _resident_score_candidate_buffer.is_valid() and _resident_score_winner_buffer.is_valid(),
		"candidate_bytes": _resident_score_candidate_bytes,
		"winner_bytes": _resident_score_winner_bytes,
		"owner": "VoxelPlacementGenerator",
	}


## fine_candidates_only 的回读口径标签（进 anchor_fine_contract.readback_mode）。
static func _fine_readback_mode(read_winner: bool, read_candidates: bool) -> String:
	if read_candidates:
		return "winner_plus_full_diagnostics" if read_winner else "full_candidate_diagnostics_only"
	return "winner_only" if read_winner else "resident_handoff_no_result_readback"


## 加载各计算着色器并创建对应的计算管线（fine finalize/score、公共 reduce、
## stamp bounds 初始化、mixed-asset stamp、目标场解包）。
func _load_shaders() -> void:
	if _placement_pipeline_ready():
		return
	_shader_fine_finalize = load_compute_shader("res://shaders/fine_score_dispatch_finalize.glsl")
	_shader_fine_score = load_compute_shader("res://shaders/score_anchor_asset_residual.glsl")
	_shader_fine_winner = load_compute_shader("res://shaders/select_anchor_winners.glsl")
	_shader_reduce_init = load_compute_shader("res://shaders/init_anchor_atomic_reduce.glsl")
	_shader_reduce_arbitrate = load_compute_shader("res://shaders/arbitrate_anchor_conflicts.glsl")
	_shader_reduce_compact = load_compute_shader("res://shaders/compact_anchor_atomic_reduce.glsl")
	_shader_init_stamp_bounds = load_compute_shader("res://shaders/init_stamp_bounds.glsl")
	_shader_stamp = load_compute_shader("res://shaders/stamp_asset_voxels.glsl")
	_shader_pack_field_pair = load_compute_shader("res://shaders/pack_placement_field_pair.glsl")
	_shader_pack_sample_pairs = load_compute_shader("res://shaders/pack_fine_sample_pairs.glsl")
	_shader_paint_clearance = load_compute_shader("res://shaders/paint_placement_clearance.glsl")
	if _shader_fine_finalize.is_valid():
		_pipeline_fine_finalize = create_compute_pipeline(_shader_fine_finalize)
	if _shader_fine_score.is_valid():
		_pipeline_fine_score = create_compute_pipeline(_shader_fine_score)
	if _shader_fine_winner.is_valid():
		_pipeline_fine_winner = create_compute_pipeline(_shader_fine_winner)
	if _shader_reduce_init.is_valid():
		_pipeline_reduce_init = create_compute_pipeline(_shader_reduce_init)
	if _shader_reduce_arbitrate.is_valid():
		_pipeline_reduce_arbitrate = create_compute_pipeline(_shader_reduce_arbitrate)
	if _shader_reduce_compact.is_valid():
		_pipeline_reduce_compact = create_compute_pipeline(_shader_reduce_compact)
	if _shader_init_stamp_bounds.is_valid():
		_pipeline_init_stamp_bounds = create_compute_pipeline(_shader_init_stamp_bounds)
	if _shader_stamp.is_valid():
		_pipeline_stamp = create_compute_pipeline(_shader_stamp)
	if _shader_pack_field_pair.is_valid():
		_pipeline_pack_field_pair = create_compute_pipeline(_shader_pack_field_pair)
	if _shader_pack_sample_pairs.is_valid():
		_pipeline_pack_sample_pairs = create_compute_pipeline(_shader_pack_sample_pairs)
	if _shader_paint_clearance.is_valid():
		_pipeline_paint_clearance = create_compute_pipeline(_shader_paint_clearance)


## Score observation only needs the field/sample preparation and Fine family.
## Keeping this contract separate lets Score survive an unrelated Place shader
## import failure and documents that Reduce/Stamp are not part of this mode.
func _fine_pipeline_ready() -> bool:
	return _shader_fine_finalize.is_valid() \
		and _shader_fine_score.is_valid() \
		and _shader_fine_winner.is_valid() \
		and _shader_pack_sample_pairs.is_valid() \
		and _pipeline_fine_finalize.is_valid() \
		and _pipeline_fine_score.is_valid() \
		and _pipeline_fine_winner.is_valid() \
		and _pipeline_pack_sample_pairs.is_valid()


## 检查放置流程所需的全部着色器与计算管线是否均已有效创建。
func _placement_pipeline_ready() -> bool:
	return _shader_fine_finalize.is_valid() \
		and _shader_fine_score.is_valid() \
		and _shader_fine_winner.is_valid() \
		and _shader_reduce_init.is_valid() \
		and _shader_reduce_arbitrate.is_valid() \
		and _shader_reduce_compact.is_valid() \
		and _shader_init_stamp_bounds.is_valid() \
		and _shader_stamp.is_valid() \
		and _shader_pack_sample_pairs.is_valid() \
		and _shader_paint_clearance.is_valid() \
		and _pipeline_fine_finalize.is_valid() \
		and _pipeline_fine_score.is_valid() \
		and _pipeline_fine_winner.is_valid() \
		and _pipeline_reduce_init.is_valid() \
		and _pipeline_reduce_arbitrate.is_valid() \
		and _pipeline_reduce_compact.is_valid() \
		and _pipeline_init_stamp_bounds.is_valid() \
		and _pipeline_stamp.is_valid() \
		and _pipeline_pack_sample_pairs.is_valid() \
		and _pipeline_paint_clearance.is_valid()


## 在常驻 result 记录上调度分数求和 pass，输出 8 字节控制标量（residual gain
## 总和 + 有效数），供报告消费，免除额外回读。
func _dispatch_placement_score_sum(result_buffer: RID, result_count_buffer: RID, capacity: int) -> RID:
	# 惰性常驻（仅 retain 路径用到）：与主 shader 家族同为 PERSISTENT 跨 run 复用。
	# 基类的 SPIR-V 缓存只去重前端编译；每次 load_compute_shader 仍会新建常驻
	# shader/pipeline RID，成员守卫防的是常驻 RID 重复创建累积。
	if not _pipeline_score_sum.is_valid():
		_shader_score_sum = load_compute_shader(SCORE_SUM_SHADER_PATH, SCOPE_PERSISTENT, "placement_result_score_sum")
		if _shader_score_sum.is_valid():
			_pipeline_score_sum = create_compute_pipeline(_shader_score_sum, SCOPE_PERSISTENT, "placement_result_score_sum")
	if not _shader_score_sum.is_valid() or not _pipeline_score_sum.is_valid():
		return RID()
	var score_sum_buffer := storage_buffer_zero(8, SCOPE_FRAME, "placement_score_sum_out")
	if not score_sum_buffer.is_valid():
		return RID()
	var set0 := create_uniform_set([
		make_storage_uniform(0, result_buffer),
		make_storage_uniform(1, result_count_buffer),
		make_storage_uniform(2, score_sum_buffer),
	], _shader_score_sum, 0, SCOPE_PASS, "placement_result_score_sum_set0")
	if not set0.is_valid():
		return RID()
	var push := PushConstantLayout.new(SCORE_SUM_PUSH).pack({
		result_capacity = capacity,
		record_stride = RECORD_STRIDE,
	})
	ComputePassChain.run(self, [
		{pipeline = _pipeline_score_sum, uniform_sets = [set0], push = push, groups = Vector3i(1, 1, 1)},
	], false)
	return score_sum_buffer


## 释放 run_multi_asset 交接出的常驻 placement 缓冲区 RID（untrack 后由调用方负责生命周期），
## 幂等：释放后清空 handoff 字典。gpu_out 可为 run_multi_asset 输出或 asset_result。
func _release_placement_result_buffers(gpu_out: Dictionary) -> void:
	if gpu_out.is_empty():
		return
	var handoff: Dictionary = gpu_out.get("placement_result_buffers", {})
	if handoff.is_empty():
		return
	var raw_handoff_rd = handoff.get("rendering_device", null)
	var handoff_rd: RenderingDevice = raw_handoff_rd if raw_handoff_rd is RenderingDevice else _rd
	for key in ["placement_results_rid", "result_count_rid", "stamp_bounds_rid"]:
		var rid_value = handoff.get(key, RID())
		if rid_value is RID and (rid_value as RID).is_valid():
			if handoff_rd != null:
				handoff_rd.free_rid(rid_value)
			else:
				release_rid(rid_value, false)
	gpu_out["placement_result_buffers"] = {}


## 释放本生成器持有的 GPU 资源，并调用 dispose 清理其余借用资源。
## dispose 后必须清空 shader/pipeline 成员 RID（底层已被基类 gc_all 释放）——否则再次
## run 时 ready 守卫会拿非零旧句柄误判已就绪。
func _on_after_dispose() -> void:
	_resident_clearance_field_buffer = RID()
	_resident_clearance_field_bytes = 0
	_resident_place_candidate_buffer = RID()
	_resident_place_candidate_buffer_bytes = 0
	_resident_place_candidate_cache_key = {}
	_resident_place_candidate_initialized = false
	# 底层 RID 已被基类 gc_all 释放（SCOPE_PERSISTENT 也在其中），这里只同步清空成员，
	# 否则下一轮 Score 会拿着已死句柄命中形状缓存、朝它建 uniform set。
	_resident_score_candidate_buffer = RID()
	_resident_score_candidate_bytes = 0
	_resident_score_winner_buffer = RID()
	_resident_score_winner_bytes = 0
	_resident_score_shape_key = {}
	_pipeline_fine_finalize = RID()
	_pipeline_fine_score = RID()
	_pipeline_fine_winner = RID()
	_pipeline_reduce_init = RID()
	_pipeline_reduce_arbitrate = RID()
	_pipeline_reduce_compact = RID()
	_pipeline_init_stamp_bounds = RID()
	_pipeline_stamp = RID()
	_pipeline_pack_field_pair = RID()
	_pipeline_pack_sample_pairs = RID()
	_pipeline_paint_clearance = RID()
	_pipeline_score_sum = RID()
	_shader_fine_finalize = RID()
	_shader_fine_score = RID()
	_shader_fine_winner = RID()
	_shader_reduce_init = RID()
	_shader_reduce_arbitrate = RID()
	_shader_reduce_compact = RID()
	_shader_init_stamp_bounds = RID()
	_shader_stamp = RID()
	_shader_pack_field_pair = RID()
	_shader_pack_sample_pairs = RID()
	_shader_paint_clearance = RID()
	_shader_score_sum = RID()


## 将 score 着色器写回的原始调试计数缓冲区字节解码为带命名字段的字典，
## 字段名称对应 DebugBufferSet(SCORE_CONTRACT_STATS) 定义的 48 槽布局。
func _decode_score_contract_debug(bytes: PackedByteArray) -> Dictionary:
	var decoded := DebugBufferSetScript.new(DebugBufferSetScript.SCORE_CONTRACT_STATS).readback(self, bytes)
	var words: PackedInt32Array = decoded.get("words", PackedInt32Array())
	# 槽位布局由 DebugBufferSet(SCORE_CONTRACT_STATS) 固定，字数不足 = 回读被截断。
	# 原来的逐槽 `words.size() > N else 0` 会把截断静默填成 0，于是
	# _annotate_score_contract_debug 把"没读到"当成"shader 没消费 profile 缓冲"。
	if words.size() < SCORE_CONTRACT_DEBUG_MIN_WORDS:
		push_error("VoxelPlacementGenerator: score 契约调试缓冲回读字数不足 期望 >= %d 实际 %d（字节数 %d）—— 契约标注会读到错位计数" % [
			SCORE_CONTRACT_DEBUG_MIN_WORDS, words.size(), bytes.size()])
		assert(false, "VoxelPlacementGenerator: score contract debug readback truncated")
		return {
			"read_source": "score_shader_storage_buffer",
			"word_count": int(decoded.get("word_count", 0)),
			"words": words,
			"values": decoded.get("values", {}),
			# magic_ok 强制 false：_annotate_score_contract_debug 据此把契约置为
			# blocked，release 构建（assert 被剥离）同样不会带脏计数继续。
			"magic_ok": false,
			"readback_truncated": true,
		}
	return {
		"read_source": "score_shader_storage_buffer",
		"word_count": int(decoded.get("word_count", 0)),
		"words": words,
		"values": decoded.get("values", {}),
		"magic_ok": bool(decoded.get("magic_ok", false)),
		"contract_enabled": int(words[1]) != 0,
		"profile_count": int(words[3]),
		"profile_table_reads": int(words[8]),
		"asset_profile_id": int(words[9]),
		"candidate_invocations": int(words[10]),
		"pivot_record_reads": int(words[16]),
		"profile_pivot_count": int(words[22]),
	}


## 生成用于重置的 score 调试缓冲区字节数据，仅写入用于校验的魔数（magic）。
func _pack_score_contract_debug_reset() -> PackedByteArray:
	return DebugBufferSetScript.new(DebugBufferSetScript.SCORE_CONTRACT_STATS).reset_bytes()


## 结合 score 着色器实际写回的调试计数，对 gpu_contract 进行事后标注：
## 按 anchor-fine contract 校验着色器是否真正绑定并消费了 profile 侧缓冲区
##（profile table / pivot records / candidate 遍历）。runtime 侧缓冲区不再由
## score 着色器消费（旧 avoidance/spacing gate 已随 tile 细筛裁撤），仅保留
## 存在性校验（_validate_gpu_runtime_profile_contract）。
func _annotate_score_contract_debug(gpu_contract: Dictionary, score_contract_debug: Dictionary) -> Dictionary:
	var annotated := gpu_contract.duplicate(true)
	if str(annotated.get("reason", "")) == "gpu_runtime_profile_buffers_ready":
		annotated["score_shader_bound_runtime_profile_buffers"] = bool(score_contract_debug.get("magic_ok", false)) \
			and bool(score_contract_debug.get("contract_enabled", false))
		annotated["score_shader_consumed_profile_buffers"] = int(score_contract_debug.get("profile_table_reads", 0)) > 0
		annotated["score_shader_candidate_invocations"] = int(score_contract_debug.get("candidate_invocations", 0))
		annotated["score_shader_pivot_record_reads"] = int(score_contract_debug.get("pivot_record_reads", 0))
		if not bool(annotated.get("score_shader_bound_runtime_profile_buffers", false)):
			annotated["ok"] = false
			annotated["reason"] = "score_runtime_profile_binding_missing"
		elif int(score_contract_debug.get("candidate_invocations", 0)) > 0 \
				and not bool(annotated.get("score_shader_consumed_profile_buffers", false)):
			annotated["ok"] = false
			annotated["reason"] = "score_profile_buffers_not_consumed"
	if not bool(annotated.get("ok", true)):
		annotated["contract_blocked"] = true
		annotated["runtime_read_source"] = "none"
		annotated["readback_source"] = "none"
	elif str(annotated.get("reason", "")) == "gpu_runtime_profile_buffers_ready":
		annotated["runtime_read_source"] = "gpu_storage_buffers"
		annotated["readback_source"] = "score_shader_storage_buffer"
	annotated["score_shader_debug"] = score_contract_debug
	return annotated


func _sha256_bytes(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode()


func _fine_workload_report(
	candidate_bytes: PackedByteArray,
	record_count: int,
	asset_lookup: Dictionary,
	yaw_slots: int
) -> Dictionary:
	var asset_count := int(asset_lookup.get("asset_count", 0))
	var slot_counts := PackedInt64Array()
	slot_counts.resize(maxi(asset_count, 0))
	var available := mini(record_count, candidate_bytes.size() / (RECORD_STRIDE * 16))
	for record_index in range(available):
		var asset_index := int(roundf(candidate_bytes.decode_float(
			record_index * RECORD_STRIDE * 16 + 20)))
		if asset_index >= 0 and asset_index < asset_count:
			slot_counts[asset_index] += 1
	var profile_ids: Array = asset_lookup.get("profile_ids", [])
	var fine_sample_counts: Array = asset_lookup.get("fine_sample_counts", [])
	var pivot_counts: Array = asset_lookup.get("pivot_counts", [])
	var asset_ids: Array = asset_lookup.get("asset_ids", [])
	var assets: Array[Dictionary] = []
	var total_slots := 0
	var total_combos := 0
	var total_sample_visits := 0
	for asset_index in range(asset_count):
		var slot_count := int(slot_counts[asset_index])
		var sample_count := int(fine_sample_counts[asset_index]) \
			if asset_index < fine_sample_counts.size() else 0
		var pivot_count := int(pivot_counts[asset_index]) \
			if asset_index < pivot_counts.size() else 0
		var effective_pivot_count := maxi(pivot_count, 1)
		var combo_count := slot_count * effective_pivot_count * maxi(yaw_slots, 1)
		var sample_visit_count := combo_count * sample_count
		total_slots += slot_count
		total_combos += combo_count
		total_sample_visits += sample_visit_count
		assets.append({
			"asset_index": asset_index,
			"asset_id": str(asset_ids[asset_index]) if asset_index < asset_ids.size() else "asset_%d" % asset_index,
			"profile_id": int(profile_ids[asset_index]) if asset_index < profile_ids.size() else -1,
			"anchor_slot_count": slot_count,
			"fine_sample_count": sample_count,
			"pivot_count": pivot_count,
			"effective_pivot_count": effective_pivot_count,
			"rotation_slots": maxi(yaw_slots, 1),
			"combo_count": combo_count,
			"sample_visit_count": sample_visit_count,
		})
	for asset in assets:
		asset["sample_visit_share"] = float(asset.get("sample_visit_count", 0)) \
			/ float(maxi(total_sample_visits, 1))
	return {
		"asset_count": asset_count,
		"candidate_record_count": available,
		"total_anchor_slots": total_slots,
		"total_combo_count": total_combos,
		"total_sample_visit_count": total_sample_visits,
		"assets": assets,
	}


## 将 GPU 结果缓冲区中的原始字节解码为放置结果记录数组。
## 记录布局（4 × vec4 = 64 B）是 GPU ABI，字段偏移与键序的单一真值源是
## PlacementResultCodec；本处只负责"可用记录条数"的裁剪与遍历。
func _decode_records(bytes: PackedByteArray, record_count: int) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	var byte_stride := RECORD_STRIDE * 16
	var available := BufferUtils.decoded_record_count(bytes, record_count, byte_stride)
	for i in range(available):
		records.append(PlacementResultCodec.decode_placement_record(bytes, i * byte_stride))
	return records


## 将 GPU stamp 着色器输出的原始字节解码为体素增量（stamp delta）记录数组。
func _decode_stamp_deltas(bytes: PackedByteArray, delta_count: int) -> Array[Dictionary]:
	var deltas: Array[Dictionary] = []
	var byte_stride := DELTA_STRIDE * 16
	var available := BufferUtils.decoded_record_count(bytes, delta_count, byte_stride)
	for i in range(available):
		var base := i * byte_stride
		var pos_scene := BufferUtils.decode_vec4(bytes, base + 0)
		var collision_meta := BufferUtils.decode_vec4(bytes, base + 16)
		if collision_meta.w <= 0.5:
			continue
		deltas.append({
			"voxel": Vector3i(int(roundf(pos_scene.x)), int(roundf(pos_scene.y)), int(roundf(pos_scene.z))),
			"complexity": pos_scene.w,
			"collision_strength": collision_meta.x,
			"result_index": int(roundf(collision_meta.y)),
			"sample_index": int(roundf(collision_meta.z)),
		})
	return deltas


## 将 GPU stamp bounds 缓冲区的原始字节解码为每次 stamp 写入的包围盒记录。
func _decode_stamp_bounds(bytes: PackedByteArray, bound_count: int, grid_size: Vector3i) -> Array[Dictionary]:
	var bounds: Array[Dictionary] = []
	var byte_stride := STAMP_BOUNDS_STRIDE * 16
	var available := BufferUtils.decoded_record_count(bytes, bound_count, byte_stride)
	for i in range(available):
		var base := i * byte_stride
		var written_count := int(bytes.decode_u32(base + 12))
		if written_count <= 0:
			continue
		var voxel_min := _decode_grid_clamped_vec3i(bytes, base, grid_size)
		var voxel_max := _decode_grid_clamped_vec3i(bytes, base + 16, grid_size)
		if voxel_max.x <= voxel_min.x or voxel_max.y <= voxel_min.y or voxel_max.z <= voxel_min.z:
			continue
		bounds.append({
			"result_index": i,
			"voxel_min": voxel_min,
			"voxel_max": voxel_max,
			"written_count": written_count,
			"source": "stamp_shader_storage_buffer",
		})
	return bounds


## 从 stamp bounds 缓冲区中连续的 3 个 u32 字（word_offset 起）解码出体素坐标，并按 grid_size 逐轴裁剪。
static func _decode_grid_clamped_vec3i(bytes: PackedByteArray, word_offset: int, grid_size: Vector3i) -> Vector3i:
	return Vector3i(
		clampi(int(bytes.decode_u32(word_offset + 0)), 0, grid_size.x),
		clampi(int(bytes.decode_u32(word_offset + 4)), 0, grid_size.y),
		clampi(int(bytes.decode_u32(word_offset + 8)), 0, grid_size.z)
	)


## 从 settings 解析目标读取缓冲（borrow 常驻对 / 上传字节），委托 VoxelPlacementTargetReader。
func _target_read_buffer_pack(settings: Dictionary, voxel_count: int) -> Dictionary:
	return VoxelPlacementTargetReaderScript.pack(settings, voxel_count, _rd)


func _target_read_buffer_summary(pack_data: Dictionary) -> Dictionary:
	return VoxelPlacementTargetReaderScript.summary(pack_data)
