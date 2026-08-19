@tool
class_name ScenePlacementActor
extends Node3D

## Scene-resident placement facade. This node is the only lifecycle authority for
## the placement runtime, RenderingDevice, SceneSV components, and Volume nodes.

const BakedAssetLoaderScript := preload("res://scripts/baked_asset_loader.gd")
const ScenePlacementRuntimeScript := preload("res://scripts/scene_placement_runtime.gd")
const SceneVoxelCommitterScript := preload("res://scripts/scene_voxel_committer.gd")
const SceneVoxelTileStoreScript := preload("res://scripts/scene_voxel_tile_store.gd")
const SceneVoxelFieldBuilderScript := preload("res://scripts/scene_voxel_field_builder.gd")
const TargetSVSetupScript := preload("res://scripts/utils/target_sv_setup.gd")
const TargetSVFbxImportServiceScript := preload("res://scripts/target_sv_fbx_import_service.gd")
const SPASelectionHostScript := preload("res://scripts/spa_selection_host.gd")
const TerrainConfigScript := preload("res://scripts/terrain_config.gd")
const TerrainInitializerScript := preload("res://scripts/terrain_initializer.gd")
const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")

const MESH_DESCRIPTION_BUFFER := ScenePlacementRuntimeScript.MESH_DESCRIPTION_BUFFER
const MESH_DESCRIPTION_STRIDE_BYTES := ScenePlacementRuntimeScript.MESH_DESCRIPTION_STRIDE_BYTES
const MESH_DESCRIPTION_FLAG_HAS_MESH := ScenePlacementRuntimeScript.MESH_DESCRIPTION_FLAG_HAS_MESH
const MESH_DESCRIPTION_FLAG_HAS_SOURCE_MESH := ScenePlacementRuntimeScript.MESH_DESCRIPTION_FLAG_HAS_SOURCE_MESH
const MESH_DESCRIPTION_FLAG_SOURCE_DIFFERS := ScenePlacementRuntimeScript.MESH_DESCRIPTION_FLAG_SOURCE_DIFFERS
const MESH_DESCRIPTION_FLAG_HAS_SOURCE_PATH := ScenePlacementRuntimeScript.MESH_DESCRIPTION_FLAG_HAS_SOURCE_PATH

## 第二级广播：**注册表整体换代**（资产增删、profile_id 重排、Arena 重传）。
##
## 与第一级 `AssetDescriptor.changed` 分工明确，两者都需要、谁也替代不了谁：
##   - `changed`：**某一个** descriptor 的内容变了。持有该实例的缓存自愈。
##     表达不了「多了/少了一个资产」——新增的那个没人持有，删掉的那个没人再发信号。
##   - 本信号：注册表这一代整体作废。凡是按 asset_index / profile_id 建索引的下游
##     （stage env、评分模型、按资产分组的显示）都必须重建，否则会拿上一代的下标去查新容器。
##
## 只广播「作废」，不广播「重算」：重算入口会调回 `load_baked_assets()`，接在这里就是自递归。
signal baked_assets_reloaded(revision: int, asset_count: int)

const PlacementStageEnvScript := preload("res://scripts/checks/placement_stage_env.gd")
const VolumeScoreFineSelectionScript := preload("res://scripts/volume_score_fine_selection.gd")
## SPA/Volumes 下三个逻辑卷的节点脚本（《AutoVolume 公用体积基类计划》V1）。
const SceneSVVolumeScript := preload("res://scripts/scene_sv_volume.gd")
const BrushSVVolumeScript := preload("res://scripts/brush_sv_volume.gd")
const BlendSVVolumeScript := preload("res://scripts/blend_sv_volume.gd")
const SVTileVolumeScript := preload("res://scripts/svtile_volume.gd")
const AnchorVolumeScript := preload("res://scripts/anchor_volume.gd")
## 实例域（非体积域）的节点脚本，《AutoVolume 公用体积基类计划》V5。
## ⚠ class_name 是 `AutoObjectDomain` 不是 `AutoObject` —— 后者已被
## `scripts/auto_object.gd`（`extends MeshInstance3D`，单个放置实例）占用。
const AutoObjectDomainScript := preload("res://scripts/auto_object_domain.gd")

# ⚠ 这里曾有 `VOLUME_KEYS` 键表（TargetSV/SceneSV/BrushSV/BlendSV 四项）与配套的
# `_volume_revisions` 修订号字典。所有权报告改为「SPA/Volumes 下每个 PickableDomain 自报」
# （PickableDomain.ownership_report_entry()，2026-08-10）后两者一并删除：
# 键表的排除名单（SVTile/Anchor/AutoObject"行形状不同"）随统一行形状消失，
# 字典则是纯写死状态——报告读数一律被 node.revision() 覆盖，写进去的没人读。

## Place 的物理可行性门限。Score 与 Place 必须同门限：否则 Score 显示的胜者会在 Place
## 被门拒，预览失真。collision_limit 也是批间自然互斥的关键——上一批盖章的 collision
## 使下一批候选在已放置足迹上 invalid。
const PLACE_PIPELINE_COMMON := {
	"collision_limit": 0.5,
	"clearance_limit": 2.0,
}

enum LifecycleState {
	NEW,
	INITIALIZING,
	READY,
	UNAVAILABLE_NO_RD,
	FAILED,
	SHUTTING_DOWN,
	DISPOSED,
}

@export_group("Grid")
# ── 竖直框架（Y）是**地形相对**的，且必须与 TargetSV 烘焙的量程逐位一致 ──────────
# 空间口径：world.y = terrain_height * height_scale + grid_origin.y + (slice + 0.5) * voxel_size.y
# （`VoxelGeneral.terrain_relative_voxel_center_to_world`；三个显示 shader 从 push constant
# 读同一组数，不假设 grid_origin.y == 0）。SceneSV / TargetSV / BrushSV / BlendSV 共用这一套。
#
#   grid_origin.y == TargetSVFbxImportService 的 vertical_floor        （量程下界，地形以下）
#   voxel_size.y  == (vertical_span - vertical_floor) / grid_size.y    （每切片的世界高度）
#
# ⚠ 两边对不上**不会报错**，只会让整份 TargetSV 按一个常数比例竖直错位。
# 2026-08-12 之前这里就是错的：导入按 span=40 / 16 层 = 2.5 分箱，显示按 voxel_size.y=2.0
# 摆放 ⇒ 恒定 0.8×；同时 grid_origin.y=0 让量程从地表起算，地下内容（实测 66858 个面、
# 占 18.6%）全被压进 slice 0 再被地形网格挡住 —— 这就是"导入的东西在地下却看不见"。
# 现值 = 量程 [-36, 36)、带宽 72、24 层 ⇒ 3.0/层。改任一侧都要同步改另一侧并重烘 TargetSV。
#
# 2026-08-12 由 [-8, 40)/16 层改到这里：层高不变（恒 3.0），下界从 -8 挪到 -36。
# 起因是 targetsv0.fbx 的相对高度区间实测 [-34.45, +35.19]，旧量程把下面 26.4 个单位
# 漏在外面 ⇒ 更深的面全被夹进 slice 0（该层仅 1516 格），陡坡列触底率 18.4%（平地 0.01%）
# ⇒ 「陡坡边缘体素堆成一摞、地下的 TargetSV 不见了」。24 层是按层高 3.0 盖住 72 单位带宽
# 得出的，不是凑的；代价是 voxel_count 1048576 → 1572864（缓冲 5.0 → 7.5 MiB）。
@export var grid_size := Vector3i(256, 24, 256)
@export var voxel_size := Vector3(4.0, 3.0, 4.0)
@export var grid_origin := Vector3(-512.0, -36.0, -512.0)
@export var base_resolution := 256
@export var capture_size := TerrainConfigScript.CAPTURE_SIZE

@export_group("Runtime")
@export var autoobject_capacity := 65536
@export var initialize_in_editor := true
## ⚠ 这里曾有 `@export var placement_assets: Array[AssetDescriptor]`。已删除：它和 Reload
## 各自写同一份 registry 且互不写回——点 Reload 之后重开场景，init 会拿 `.tscn` 里存着的
## 旧数组把 Reload 的结果覆盖掉，且没有任何提示。现在**唯一**入口是 `load_baked_assets()`，
## init 自动跑一次（非 force，吃"目录未变即已加载"短路），Reload 手动强制重扫。
## 读取已注册资产一律走 `get_registered_descriptors()`。
@export_group("")

## 生产计算参数（Anchors / Score / Place 三条命令共用同一份门限）。
## ⚠ 这些值直接决定评分与放置结果，SSOT 在 SPA——不要在 demo/host 上再放一份同名导出，
## 两份默认值一致时的漂移只会在结果对不上时才暴露。
@export_group("Placement Tuning")
## 每候选原点扫描的 yaw 档数。
@export_range(1, 24, 1) var rotation_slots: int = 12
## ⚠ 曾经这里有 `use_original_pivot_only` 开关与 `_production_descriptors()` 副本层，
## 用来在注册进评分链时关掉 descriptor 的垂直 pivot 自动生成。三变体本身已删除
## （见 `AssetDescriptor.get_pivot_variants`），开关与副本层随之退役。
##
## 顺带记下它当年为什么没起作用（同类结构不要再造）：当时 `_register_exported_assets()`
## 在 SPA init 把**原件**（导出数组 `placement_assets`，已随本次收敛删除）交给
## `register_asset_batch()`，而做 pivot
## 剥离的 `_production_descriptors()` 只喂给 `ensure_placement_env()`；stage env 的注册
## 循环发现该资产已有 profile_id 就复用，`register_asset(剥离副本)` 从未执行。
## 于是开关显示 `true`、评分链用的却是带三变体的原件——**一个看得见却不生效的开关**。
## 教训：注册身份的去重键（identity / resource_path）不包含被改写的字段时，
## "只改副本"这种做法必然被去重悄悄吃掉。
## 真实 prefilter 门限（原样转发 _apply_prefilter_settings 支持的键）。
@export_range(0.0, 1.0, 0.001) var min_target_interest := 0.01
## 竖直方向锚点密度（单位 = 体素层，**越小越密**）：锚点自**地形切片**起算、每这么多层
## 采样一次，采到目标体积就发锚；地形以下永不发锚。
## `0`（默认）= 只采地形那一格，每列至多一个锚且一定站在地面上；
## `1` = 地表及以上每个 in-target 体素都出锚；`n > 1` = 地形切片 + 其上每 n 层一格。
## 完整语义与实测锚点数见 `AutoObjectProbePrefilterGPU.anchor_vertical_stride`。
@export_range(0, 32, 1) var anchor_vertical_stride := 0
## ⚠ **当前无效**：粗筛暂停淘汰（2026-08-10 裁决），`select_anchor_topk.glsl` 忽略这个门，
## 全部资产一律进候选池，由细筛独自决定。导出保留是为了恢复时不用改接线；
## 恢复方法见该 shader 文件头。
@export_range(0.0, 1.0, 0.001) var min_prefilter_score := 0.35
## Place 每批 Reduce 的输出上限。达到上限时只截断输出，不触发补放。
## ⚠ 这不是「最多放几个」的策略帽，而是**每批 GPU 结果缓冲的尺寸**：
## `placement_results = result_capacity * RECORD_STRIDE(4) * 16` 字节，
## 另有 `stamp_bounds = result_capacity * 2 * 16`、`stamp_capacity = result_capacity * 资产数`。
## 所以它没法「去掉」，只能抬——4096 时结果缓冲 256 KB + 边界缓冲 128 KB，可忽略。
## 批循环耗尽后自然收敛（判据见 run_place 循环末尾），它只决定**分批粒度**：
## 调大 = 每批装得下更多、批数更少、总墙钟更短；不影响最终放置总数。
@export_range(64, 16384, 64) var place_result_capacity := 4096
## Place 单次命令最多自动跑的批数（每批整链 S5→S9）。上一批盖章 collision 使下一批
## 自然避开已放置足迹；收敛判据见 run_place 循环末尾（格点门关 = 某批 spawned == 0 即
## 判定放满；格点门开 = 相位空间走完），正常情况下轮不到本上限。
## ⚠ 格点门开着时，run_place 会把**实际批预算抬到相位空间大小**（`place_anchor_interval_voxels²`，
## interval=12 即 144），本导出值只作为跑飞兜底的下界。原因是相位走法是批号的纯函数、
## Place 之间不留游标：预算低于相位空间 ⇒ 剩下的格位不是「下次再放」，而是**再点几次
## Place 也永远拿不到**（第二轮从同一个相位重走，吃的全是已填满的格位）。
## ⚠ 此处曾写「上限小于相位空间是刻意的（用户 2026-08-14 定 32）……单批产出足够大，
## 32 批已远超需要」。该前提与 2026-08-18 实测不符：同一场 32 批 = 2923 个，144 批 = 4713 个
## （后 112 批补了 1790，+61%），而第 32 批仍有产出。导出默认值保持 32 未动，改的是
## 门开着时的有效预算。
##
## ⚠ 保留它不是为了限流，是**跑飞兜底**：退出条件依赖管线单调收敛（每批盖章都缩小候选池），
## 而那是观测到的性质、不是被证明的不变量。去掉就等于 `while true`，管线一旦不收敛就把
## 编辑器挂死。真被顶到时会 push_warning，绝不静默截断。
@export_range(1, 1024, 1) var place_max_batches := 32
## 放置最小间距（体素；reduce min-distance 冲突门）。
@export_range(0.0, 16.0, 0.5) var place_min_distance_voxels := 2.0
## 格点门间隔（体素）：每轮只放落在 `phase + k * interval` 格点上的 anchor，
## 相位逐批推进。取得足够大时同轮候选在几何上不可能冲突，那趟保守仲裁就不会误杀。
##
## **下界怎么来的**：两个物体中心的最小安全距离 = `r_a + r_b`（各自 XZ 半长之和），
## 最坏情况是两个最大资产 cliff_02 相邻——XZ 足迹 46.15 世界单位、半长 23.08，
## 于是安全距离 = 46.15 世界单位 ÷ voxel_size.x(=4) = **11.5 体素 ⇒ 12 即安全**。
## 12 是贴着下界取的最小安全值：更小会让同轮两个 cliff_02 真的重叠。
##
## ⚠ 别再往上调「保险起见」：这里原本写 30，比下界保守 2.6 倍，而每轮格点数按面积
## 反比缩——interval=30 每轮只有 64 个格点，interval=12 有 455 个，**差 7 倍**。
## 每轮候选少 7 倍就意味着要多跑 7 倍的批才铺得满，代价直接落在 Place 的总墙钟上。
## 调大 ⇒ 每轮更稀疏、需要更多轮次覆盖。
## 0 = 关闭，退回「全体候选 + 一趟保守仲裁 + 盖章重判」的旧行为。
@export_range(0, 64, 1) var place_anchor_interval_voxels := 12
## 评分观察 tile 子区域（XZ tile 坐标，tile=8³；全 Y 层）。
## 空 rect（默认）= 单次全图；非空 rect = 只跑该单区域。
@export var prefilter_tile_rect := Rect2i()
@export_group("")

@export_group("Placement")
## 一键加载 Asset Overview 的全部 Bake 产物到固定槽位 Arena（事务式：失败保留旧 Arena）。
## 恒走 force 路径：强制重扫、不吃"目录未变即已加载"短路，因此重新烘焙后点它即可，
## 不需要区分首次加载与重载。
@export_tool_button("Reload", "Reload") var _reload_baked_assets_action: Callable = _reload_baked_assets_from_inspector
@export_tool_button("Anchors", "Add") var _generate_anchors_action: Callable = _generate_anchors_from_inspector
@export_tool_button("Score", "Play") var _score_action: Callable = _score_from_inspector
@export_tool_button("Place", "MeshInstance3D") var _place_action: Callable = _place_from_inspector
## 把场清回「刚 init 完」的状态：GPU AutoObject 记录、已盖章的 committed SceneSV、
## Place 的跨批累积、anchor/score 交接与下游派生缓存，一次全清。
## ⚠ 不动 BrushSV —— 那是你手绘的**输入**，不是放置产物；要清它用 Shift+C。
@export_tool_button("Clear All", "Clear") var _clear_all_action: Callable = _clear_all_from_inspector
## 只读的已加载资产列表（§11.2）：资产来源唯一是 Bake 目录，没有可手工维护的数组。
@export_multiline var placement_assets_summary: String:
	get:
		return _placement_assets_summary_text()
@export_multiline var placement_status: String:
	get:
		return _placement_status_text()
@export_group("")

@export_group("Voxel Display")
@export var gpu_objects_visible: bool = true:
	set(value):
		_set_voxel_display_proxy("gpu_objects", value)
	get:
		return _voxel_display_proxy("gpu_objects")
@export var sv_tiles_visible: bool = true:
	set(value):
		_set_voxel_display_proxy("svtile", value)
	get:
		return _voxel_display_proxy("svtile")
@export var anchors_visible: bool = true:
	set(value):
		_set_voxel_display_proxy("anchor", value)
	get:
		return _voxel_display_proxy("anchor")
@export var scene_voxels_visible: bool = true:
	set(value):
		_set_voxel_display_proxy("sv", value)
	get:
		return _voxel_display_proxy("sv")
## ⚠ 五个复选框走**同一对**读写口，`target_sv_visible` 不再是特例（它此前单独直连
## `set_volume_display` / `_target_sv.is_display_visible()`，也正因为如此，它曾是五个里
## 唯一真正生效的那个——成因见 `_set_voxel_display_proxy()` 的注释）。
@export var target_sv_visible: bool = true:
	set(value):
		_set_voxel_display_proxy("targetsv", value)
	get:
		return _voxel_display_proxy("targetsv")
@export_group("")

var _lifecycle_state := LifecycleState.NEW
var _failure_reason := ""

# ── 固定槽位 Arena 的加载状态（Inspector 面板与按钮门控，计划 §11.3）─────────────
# 纯控制面：Arena 的内容真值仍在容器里，这里只记"最近一次加载做到哪一步、结果如何"。
var _arena_load_state := "Not Loaded"
var _arena_load_error := ""
## BakedAssetLoader 的整份报告。逐资产摘要读 `.entries`——不再另存一份投影成员：
## 两份要各自赋值、各自写软重载修复，而它们只可能同时来自同一次 load。
var _arena_load_report: Dictionary = {}
var _arena_loaded_signature := ""         # 加载成功时的 Bake 目录指纹，用于 Stale 判定
var _runtime: ScenePlacementRuntime = null
var _sv_committer: SceneVoxelCommitter = null
var _tile_store: SceneVoxelTileStore = null
var _field_builder: SceneVoxelFieldBuilder = null
var _owns_committer := false
var _volumes: Node = null
var _interaction: Node3D = null
var _displays: Node3D = null
var _selection_host: SPASelectionHost = null
var _target_sv: TargetSVSetup = null
var _brush_input: MeshFillBrush = null
## `SPA/Volumes/BrushSV` 的类型化缓存（2026-08-10 起笔刷内容/显示/落笔定位都在卷节点）。
## 落笔是热路径（每个 mouse-motion 事件一次），不能每笔都走 get_volume() 的
## _ensure_owned_tree 链。由 _ensure_owned_tree 解析并自愈。
var _brush_volume: BrushSVVolume = null
var _providers: Dictionary = {}
var _target_read_buffers: Dictionary = {}
var _brush_sv_control_metadata: Dictionary = {}
var _last_anchor_result: Dictionary = {}
var _last_score_result: Dictionary = {}
var _last_place_result: Dictionary = {}
# 只读点选交接的换代号（契约见 get_placement_selection_handoff）。
# 借方（SelectionHost / 统一 GPU 点选）读取前后各核对一次：不一致 = 期间 RID 被换过，
# 结果必须丢弃。⚠ 释放或替换 Anchor/Fine RID 之前**必须**先递增对应 revision，
# 否则借方拿着已死 RID 却以为自己的快照还新鲜。
var _anchor_revision := 0
var _score_revision := 0
# ⚠ 交接与「上一次命令结果」是两份状态，别再合成一份。
# 真正产出交接的是内层（run_autoobject_prefilter / Fine runner），而外层命令
# （run_anchors / run_score）返回的往往只是一份薄状态字典；两者共用一个槽位时，
# 外层返回会把内层刚发布的交接原地抹掉——实测就是 Anchors 报 45598 个锚点、
# 交接却仍是 anchor_handoff_not_resident。
var _anchor_handoff: Dictionary = {}
var _fine_score_handoff: Dictionary = {}
# 生产流水线的阶段底座与细筛 runner，由 SPA 自己持有（不再向 provider 借）。
# env 只是"阶段缓存 + 顺序"层：每个阶段最终都回调 SPA 自己的方法
# （ensure_svtile_gpu_ready / prepare_target_read_buffers_from_common_gpu /
# run_autoobject_prefilter / run_placement_pipeline），所以 SPA 借用自己不构成所有权环。
# ⚠ 惰性构建：PlacementStageEnv.make() 要求 SPA 已 READY，不能在 initialize_runtime 里建。
var _placement_env: RefCounted = null
var _placement_env_error := ""
var _score_runner: RefCounted = null
## 最近一次 Score 的细筛结果模型（锚点/胜者/Top-K 的 CPU 视图）。
## demo/HUD/golden 从这里取数，而不是各自再跑一遍评分。
var _score_model: Dictionary = {}
var _score_cache_key: Dictionary = {}
var _make_count := 0
var _dispose_count := 0
var _ready_initialization_ms := 0.0
var _is_painting := false
var _brush_dirty := false
# 笔刷增量提交水位（详见 _flush_owned_brush 的失效条件注释）：
# _brush_flushed_count = 已散射进 BrushSV 的笔刷体素条数（MeshFillBrush._brush_voxels 前缀长度）
# _brush_flushed_tail  = 水位末条体素的 (x, slice, z)，用于识别笔刷状态被重置/重建
# _brush_flushed_paint_* = 取水位时的笔刷绘制参数，变化时保守整批重放
# _brush_flushed_sv_revision = 取水位时的 BrushSV 内容修订号，识别缓冲被清零/重建
var _brush_flushed_count := 0
var _brush_flushed_tail := Vector3i(-1, -1, -1)
var _brush_flushed_paint_color := Color(-1.0, -1.0, -1.0, -1.0)
var _brush_flushed_paint_levels := Vector2(-1.0, -1.0)
var _brush_flushed_sv_revision := -1


func _enter_tree() -> void:
	# 自行入组而不是靠 .tscn 里写死 groups=[...]：老场景、代码 new 出来的 SPA 一样能被
	# Bake AD 的跨场景刷新找到。add_to_group 幂等，重复进出树不会累积。
	if not is_in_group(SPAEditorContract.SPA_GROUP):
		add_to_group(SPAEditorContract.SPA_GROUP)
	_ensure_owned_tree()


func _ready() -> void:
	if Engine.is_editor_hint() and not initialize_in_editor:
		return
	initialize_runtime()


## ⚠ 编辑器打开场景时这里会被调用一次「假」拆卸：Godot 的 EditorNode 在 scene 打开流程里
## 会把 edited scene root 从 scene_root 摘下再挂回（editor_node.cpp 的 set_edited_scene_root /
## _set_current_scene），整棵子树因此收到一轮 exit_tree + enter_tree，而 SPA 自身既没被
## reparent（无 UNPARENTED、parent 不变）也没被销毁。当前策略是照常 _shutdown()：RenderingDevice
## 与全部 GPU owner 被释放，随后插件的 scene_changed → _validate_scene() 看到 SPA 非 ready
## 会重新 initialize_runtime()，于是每次打开场景都多付一整轮 GPU bootstrap（实测 ~214 ms，
## make_count=2 / dispose_count=1）。行为正确、只是浪费；改成延迟拆卸前要先确认场景真关闭时
## 设备仍能被回收。
func _exit_tree() -> void:
	_shutdown(false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_shutdown(false)


func _validate_property(property: Dictionary) -> void:
	var property_name := StringName(str(property.get("name", "")))
	if property_name == &"placement_status":
		property["usage"] = (int(property.get("usage", PROPERTY_USAGE_EDITOR)) | PROPERTY_USAGE_READ_ONLY) \
			& ~PROPERTY_USAGE_STORAGE
	elif property_name in [
		&"gpu_objects_visible",
		&"sv_tiles_visible",
		&"anchors_visible",
		&"scene_voxels_visible",
		&"target_sv_visible",
	]:
		property["usage"] = int(property.get("usage", PROPERTY_USAGE_EDITOR)) & ~PROPERTY_USAGE_STORAGE


# ── 固定槽位 Arena 的 Bake 产物加载（计划 §7 / §11）─────────────────────────────
# 状态机（§11.3）：Not Loaded → Loading → Ready / Failed；Ready 之后 Bake 产物变化即 Stale。
const ARENA_STATE_NOT_LOADED := "Not Loaded"
const ARENA_STATE_LOADING := "Loading"
const ARENA_STATE_READY := "Ready"
const ARENA_STATE_STALE := "Stale"
const ARENA_STATE_FAILED := "Failed"


func _clear_all_from_inspector() -> void:
	_finish_inspector_action("Clear All", clear_placement_state())


func _reload_baked_assets_from_inspector() -> void:
	_finish_inspector_action("Reload", load_baked_assets())


## 扫描 Bake 输出目录 → 校验 → 事务式替换 Arena（计划 §7 的完整流程）。
##
##     Scanning → Validating → Packing → Uploading → Ready
##
## 全程事务式：任一 Descriptor 不合法就在替换**之前**整批拒绝，旧 Arena（RID / 内容 /
## Registry / Revision）一字不动，界面显示 `Previous Arena Still Active`。
## force=true 时即使目录未变也重跑（Reload 按钮）。
## 加载失败的统一出口：置 FAILED 状态 + 记可读原因 + 拼返回字典。
## 三个失败路径原本各写一遍，漏掉任何一半都是「Inspector 显示 Ready 但其实没加载成功」
## 这类难查的不一致；收成一处后，新增失败路径不可能忘记置状态。
func _fail_arena_load(reason: String, phase: String, error_text: String, extra: Dictionary = {}) -> Dictionary:
	_arena_load_state = ARENA_STATE_FAILED
	_arena_load_error = error_text
	var out := {"ok": false, "reason": reason, "phase": phase}
	out.merge(extra)
	return out


func load_baked_assets() -> Dictionary:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	if not is_initialized():
		return _fail_arena_load("not_initialized", "Scanning", "SPA 未初始化")

	var had_previous_arena := get_asset_count() > 0
	_arena_load_state = ARENA_STATE_LOADING
	_arena_load_error = ""

	# ── Scanning + Validating ──
	var report: Dictionary = BakedAssetLoaderScript.load_baked_descriptors()
	_arena_load_report = report
	var errors: PackedStringArray = report.get("errors", PackedStringArray())
	if not bool(report.get("ok", false)):
		# 每条失败都单独打印，用户能直接定位到 descriptor 与超限字段（§11.4）。
		for error_text in errors:
			push_error("[ScenePlacementActor] Reload: %s" % error_text)
		return _fail_arena_load(
			"validation_failed", "Validating",
			errors[0] if errors.size() > 0 else "unknown",
			{
				"dir": report.get("dir", ""),
				"errors": errors,
				"failed_count": errors.size(),
				"previous_arena_still_active": had_previous_arena,
			})

	var descriptors: Array[AssetDescriptor] = report.get("descriptors", [] as Array[AssetDescriptor])
	# 目录没变且已经是 Ready 就不重复上传（Reload 用 force 跳过这条短路）。
	#
	# ⚠ 这里曾有一条「目录未变即已加载」的短路（连同一个 `force` 参数用来跳过它）。已删除：
	# 它的判据 `_arena_load_state` / `_arena_loaded_signature` 是 **SPA 级**成员，而资产表活在
	# `_runtime` 里。编辑器摘挂 scene root 会 `_exit_tree → _shutdown → 再 initialize`，
	# `_runtime` 连同 registry 被整个换掉而这两个缓存原样留着 ⇒ 第二次 init 短路返回
	# `{ok: true, reason: "already_loaded"}` 而实际资产数是 0：报告成功、Arena 空着、无任何警告。
	# 补条件（再看一眼资产数）能救这一种，但目录签名只是「路径 + mtime」，同秒重写照样瞒过去。
	# 结论：这条路径本来就该恒等于「读盘」，省下的一次上传（实测 ~57 ms）不值得这类静默故障。
	# `_arena_loaded_signature` 仍然保留——它另有用途：Inspector 的 Stale 判定（见 :457）。
	var signature := _baked_dir_signature()

	# ── Packing + Uploading（replace_all_assets 内部就是事务式单次 Arena 上传）──
	var upload_t0_usec := Time.get_ticks_usec()
	if not replace_all_assets(descriptors):
		return _fail_arena_load(
			"arena_replace_failed", "Uploading", "Arena 替换失败（见编辑器输出）",
			{
				"dir": report.get("dir", ""),
				"previous_arena_still_active": had_previous_arena,
			})

	# ⚠ 资产表整体换代后，缓存的 stage env / 评分模型里存的全是**上一代** profile_id。
	# 下一次 Anchors/Score 会拿它们去查新容器：`_build_asset_lookup` →
	# `get_fine_sample_range_for_profile_id()` 查不到就硬失败（实测触发，报
	# "profile_id=… 未注册（已注册 5 条）"）。所以换代必须连带把这些缓存清掉，
	# 让下一次运行按新注册表重建 asset defs。
	if _placement_env != null:
		_placement_env.dispose()
		_placement_env = null
	_placement_env_error = ""
	_score_model = {}
	invalidate_score_cache(&"baked_assets_reloaded")
	# ⚠ 不动 _score_runner：它缓存着 VoxelPlacementGenerator 实例，在这里置 null 会丢掉
	# 最后一个引用、触发 GodotComputeShaderBase._notification(PREDELETE) → dispose()，
	# 而那条 GC 期路径本身有顺序依赖缺陷（实测报 "call 'dispose' on a null instance"）。
	# 换代要清的是 asset defs 的来源（stage env）与评分缓存，runner 本身每次 run 都会
	# 按当时的注册表重建输入，留着无害。

	_arena_loaded_signature = signature
	_arena_load_state = ARENA_STATE_READY
	var arena := get_profile_arena_summary()
	# 广播换代（见类首 baked_assets_reloaded 的分工说明）。放在状态位落定、arena 摘要取完
	# **之后**：订阅方回调里若反过来问 SPA 状态，读到的必须是新的一代。
	baked_assets_reloaded.emit(int(arena.get("revision", 0)), descriptors.size())
	return {
		"ok": true,
		"reason": "ok",
		"phase": "Ready",
		"dir": report.get("dir", ""),
		"loaded_count": descriptors.size(),
		"scanned_count": int(report.get("scanned_count", 0)),
		"upload_ms": float(Time.get_ticks_usec() - upload_t0_usec) / 1000.0,
		"arena": arena,
	}


## Bake 目录指纹（路径 + 修改时间）：用于 §11.3 的 Stale 判定——产物变了但还没 Reload。
func _baked_dir_signature() -> String:
	var parts := PackedStringArray()
	for path in BakedAssetLoaderScript.scan_descriptor_paths():
		parts.append("%s:%d" % [path, FileAccess.get_modified_time(path)])
	return "|".join(parts)


## 当前 Arena 状态（含 Stale 判定；Ready 态下每次读都比对目录指纹）。
func get_arena_load_state() -> String:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	if _arena_load_state == ARENA_STATE_READY:
		if not is_gpu_ready():
			return ARENA_STATE_NOT_LOADED
		if _baked_dir_signature() != _arena_loaded_signature:
			return ARENA_STATE_STALE
	return _arena_load_state


## 按钮禁用时的 Tooltip 原因（§11.1 要求说明原因；Inspector 的按钮禁用判定也读它——空串即可用）。
func get_placement_blocked_reason() -> String:
	if not is_initialized():
		return "SPA 未初始化"
	if get_asset_count() <= 0:
		return "Arena 未就绪：还没有已加载的资产 —— 先点 Reload"
	if not is_gpu_ready():
		return "Arena 未就绪：GPU profile/Arena 缓冲未上传"
	return ""


func _generate_anchors_from_inspector() -> void:
	_finish_inspector_action("Anchors", _run_placement_action(&"generate_anchors", run_anchors))


func _score_from_inspector() -> void:
	_finish_inspector_action("Score", _run_placement_action(&"calculate_voxel_scores", run_score))


func _place_from_inspector() -> void:
	_finish_inspector_action("Place", _run_placement_action(&"place_final_autoobjects", run_place))


## Inspector 动作的统一派发：**有 VolumeScore provider 就走 provider 的入口**，没有才直接
## 跑 SPA 的 `run_*`。流水线只跑一遍——provider 那三个入口内部调的正是本 SPA 的 `run_*`
## （`generate_anchors` → `run_anchors`、`run_volume_score_pipeline` → `run_score`、
## `place_final_autoobjects` → `run_place`），它们只是在后面接上了 demo 侧的显示重建。
##
## ⚠ 三个按钮此前直接调 `run_*()`，把 provider 那一跳整个跳过了：流水线跑完、模型换代、
## `run_anchors` 老老实实返回 `ok=true, anchors=10386`，但 `AnchorPoints` / 胜者 mesh /
## 放置实例**一个都不重建**。表现是「点了按钮什么都没发生」且控制台零提示，而且因为
## 「可视化即拾取几何」，没画出来的域连点都点不中（见 SPASelectionHost.collect_pick_drawables）。
## 三个按钮是同一个洞，所以修在这条公共派发上，而不是各修各的。
##
## ⚠ 不能把这一跳挪进 `run_*()` 里：provider 的入口自己就调 `run_*()`，那会变成无限递归。
func _run_placement_action(provider_method: StringName, fallback: Callable) -> Dictionary:
	var provider := get_volume_provider(&"VolumeScore")
	if provider != null and provider.has_method(provider_method):
		var result = provider.call(provider_method)
		return result if result is Dictionary else {"ok": false, "reason": "provider_action_returned_non_dictionary"}
	return fallback.call()


func _finish_inspector_action(action_name: String, result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		push_warning("[ScenePlacementActor] %s: %s" % [action_name, str(result.get("reason", "not ok"))])
	notify_property_list_changed()


func _placement_status_text() -> String:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	var lines: Array[String] = [_arena_status_text()]
	# 选中下标归 SelectionHost，摘要文案归 SPA——所以问 host（它再回头按下标问我），
	# 而不是问 provider。provider 上那份已随选中态一起退役。
	if _selection_host != null and is_instance_valid(_selection_host):
		var text := _selection_host.get_selected_anchor_summary_text()
		if not text.is_empty():
			lines.append("")
			lines.append(text)
			return "\n".join(lines)
	lines.append("")
	lines.append("SPA %s — %s" % [
		lifecycle_state_name(),
		_failure_reason if not _failure_reason.is_empty() else "ready for placement"])
	return "\n".join(lines)


## Arena 只读状态面板（计划 §11.3）。
func _arena_status_text() -> String:
	var state := get_arena_load_state()
	var arena := get_profile_arena_summary()
	if arena.is_empty():
		return "Profile Arena: %s (no runtime container)" % state

	var capacity := int(arena.get("profile_capacity", 0))
	var loaded := int(arena.get("loaded_profile_count", 0))
	var arena_bytes := int(arena.get("arena_byte_count", 0))
	var lines: Array[String] = [
		"Profile Arena: %s%s" % [state, _arena_state_suffix(state)],
		"Loaded profiles: %d / %d" % [loaded, capacity],
		"Arena: %s, %s" % [
			"ready" if bool(arena.get("runtime_ready", false)) else "not ready",
			_format_mib(arena_bytes)],
		"Slot stride: %d bytes" % int(arena.get("slot_stride_bytes", 0)),
		"Samples: %d valid / %d capacity (max %d per profile)" % [
			int(arena.get("valid_sample_count", 0)),
			int(arena.get("sample_capacity", 0)),
			int(arena.get("max_samples_per_profile", 0))],
		"Pivots: %d valid / %d capacity (max %d per profile)" % [
			int(arena.get("valid_pivot_count", 0)),
			int(arena.get("pivot_capacity", 0)),
			int(arena.get("max_pivots_per_profile", 0))],
		"Unused arena space: %.1f%% (%s free)" % [
			float(arena.get("wasted_ratio", 0.0)) * 100.0,
			_format_mib(int(arena.get("wasted_bytes", 0)))],
		"Revision: %d" % int(arena.get("revision", 0)),
	]

	var layout_errors: PackedStringArray = arena.get("layout_errors", PackedStringArray())
	var capacity_errors: PackedStringArray = arena.get("capacity_errors", PackedStringArray())
	for error_text in layout_errors:
		lines.append("! layout: %s" % error_text)
	for error_text in capacity_errors:
		lines.append("! capacity: %s" % error_text)
	var upload_error := str(arena.get("last_upload_error", ""))
	if not upload_error.is_empty():
		lines.append("! upload: %s" % upload_error)
	if state == ARENA_STATE_FAILED and not _arena_load_error.is_empty():
		lines.append("! %s" % _arena_load_error)
		# 失败时必须明确交代旧 Arena 还能不能用（§11.4 末条）。
		lines.append("Previous Arena Still Active" if loaded > 0 else "No Arena Loaded")
	return "\n".join(lines)


static func _arena_state_suffix(state: String) -> String:
	match state:
		ARENA_STATE_NOT_LOADED:
			return " — 点 Reload 加载 Bake 产物"
		ARENA_STATE_STALE:
			return " — Bake 产物已变化，当前仍在用上一版 Arena（点 Reload 提交新版本）"
		ARENA_STATE_FAILED:
			return " — 最近一次加载失败"
		_:
			return ""


static func _format_mib(byte_count: int) -> String:
	return "%.2f MiB" % (float(byte_count) / 1048576.0)


## 只读已加载资产列表（计划 §11.2）。优先显示最近一次扫描的逐资产摘要；
## 没扫描过就退回当前注册表，至少让人看见 Arena 里现在装着什么。
func _placement_assets_summary_text() -> String:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	var entries: Array = _arena_load_report.get("entries", [])
	if not entries.is_empty():
		return BakedAssetLoaderScript.format_asset_list(
			entries, "Loaded Assets — %s" % str(_arena_load_report.get("dir", "")))
	var descriptors := get_registered_descriptors()
	if descriptors.is_empty():
		return "Loaded Assets (0)\n  <点 Reload 从 Bake 目录一键加载>"
	var lines: Array[String] = ["Registered Assets (%d) — 未经 Reload 扫描" % descriptors.size()]
	for i in range(descriptors.size()):
		var descriptor := descriptors[i]
		var branch := "└─" if i == descriptors.size() - 1 else "├─"
		lines.append("%s %-24s Profile %-6d %s" % [
			branch,
			str(descriptor.asset_id) if not str(descriptor.asset_id).is_empty() else "<no asset_id>",
			get_profile_id_for_asset(i),
			descriptor.resource_path,
		])
	return "\n".join(lines)


## Inspector「Voxel Display」五个复选框的**统一写口**。
##
## ⚠ 必须走本类自己的 `set_voxel_display_visible()`（它带卷路由），**不能**直接扎进
## `_selection_host`。host 那一侧只有两样东西：记账位，以及「按显示组下发 node.visible」。
## 而域族的显示由卷自己的 `display_visible` 决定——`PickableDomain.rebuild_display()`
## 首句就是 `if not display_visible: _discard_display(); return`，于是**默认隐藏的域压根
## 没有显示节点**，组下发无对象可改 ⇒ 复选框是彻底的空操作。
##
## 实测（2026-08-14，placement-score-3d + 桥）：
##   * `set_node_property sv_tiles_visible = true` → `SPA/Volumes/SVTile.is_display_visible()` 仍 `false`
##   * `call_method set_voxel_display_visible ["svtile", true]` → 变 `true`
## SceneSV / SVTile 因此是「点了完全没反应」，Anchor / Brush / AutoObject 则是卷的
## `display_visible` 静默陈旧（下一次 `rebuild_display()` 会把开关悄悄弹回去）。
## `auto_object_domain.gd` 的 `is_display_visible()` 覆写记的就是这条陈旧的另一侧。
func _set_voxel_display_proxy(display_key: String, visible: bool) -> void:
	set_voxel_display_visible(display_key, visible)


## Inspector 五个复选框的**统一读口**。
##
## ⚠ 真值取**卷节点自己那份**，不读 host 的记账位：记账位由
## `SPAEditorContract.default_voxel_display_state()` 播种成恒 true，而 SceneSV / SVTile /
## BrushSV / TargetSV 的 `default_display_visible()` 都是 false —— 两者**开场就相反**，
## 读记账位会让复选框显示「已勾选」而域其实是隐藏的。取真值的方式与
## `_handle_domain_visibility_shortcut()` 一致（那里也明写了「不读 host 的记账位」）。
## 没有对应卷的显示键才退回记账位；族外容器域（AutoObject）的卷会自己转发回记账位。
func _voxel_display_proxy(display_key: String) -> bool:
	var volume_node := _volume_for_display_key(display_key)
	if volume_node != null:
		return volume_node.is_display_visible()
	return _selection_host.is_voxel_display_visible(display_key) if _selection_host != null else true


# ⚠ 编辑器软重载（@tool 脚本重新解析）后的成员修复，别当成冗余判空删掉。
#
# 事实依据（gdscript.cpp GDScriptInstance::reload_members）：软重载只把**重载前已存在**
# 的成员按名字搬进新槽位（值原样保留，不回初始值）；本次重载**新增**的成员槽是默认构造
# 的 Variant = nil，声明里的初始化器**不会**重跑。带静态类型也拦不住——实例槽本身是
# Variant，nil 就这么躺在一个声明为 int/String/Dictionary 的成员里。SPA 是常驻编辑器
# 场景里的 @tool 节点，是本项目里最容易吃到这一下的类：重载后第一次调用就会炸在
# `LifecycleState.keys()[nil]`（用 nil 下标数组）、`_failure_reason.is_empty()` 与
# `_providers.has(...)`（在 Nil 上找方法）这些位置。
#
# ⚠ 必须用 `is` 而不是 `== null`：对静态类型已知的操作数 GDScript 会挑验证求值器
# （gdscript_byte_codegen.cpp write_binary_operator），而 Variant 给 (INT, NIL)、
# (DICTIONARY, NIL) 这类组合注册的是 OperatorEvaluatorAlwaysFalse（variant_op.cpp），
# `_lifecycle_state == null` 会被编成恒 false，判空形同虚设。
# `is` 编成 OPCODE_TYPE_TEST_BUILTIN，查的是运行时真实类型，nil 一定为假。
#
# 语义：只在"槽里是 nil"时回填声明初始值，正常路径一个值都不动。
# _lifecycle_state 回到 NEW = 允许 initialize_runtime() 重新构建（DISPOSED 分支本就这么
# 走）；三个 _last_*_result 与 _target_read_buffers 回到空字典 = 报告里如实显示"还没跑过"；
# _providers 回到空 = 由 provider 注册重填。
func _repair_soft_reloaded_members() -> void:
	if not (_lifecycle_state is int): _lifecycle_state = LifecycleState.NEW
	if not (_failure_reason is String): _failure_reason = ""
	if not (_arena_load_state is String): _arena_load_state = ARENA_STATE_NOT_LOADED
	if not (_arena_load_error is String): _arena_load_error = ""
	if not (_arena_load_report is Dictionary): _arena_load_report = {}
	if not (_arena_loaded_signature is String): _arena_loaded_signature = ""
	if not (_owns_committer is bool): _owns_committer = false
	if not (_providers is Dictionary): _providers = {}
	if not (_target_read_buffers is Dictionary): _target_read_buffers = {}
	if not (_brush_sv_control_metadata is Dictionary): _brush_sv_control_metadata = {}
	if not (_last_anchor_result is Dictionary): _last_anchor_result = {}
	if not (_last_score_result is Dictionary): _last_score_result = {}
	if not (_last_place_result is Dictionary): _last_place_result = {}
	# revision 回到 0 与三个 _last_*_result 回到空是同一次失效：软重载后既没有结果也
	# 没有交接，借方核对时看到的 0 与空 handoff 一致，不会误认旧快照还新鲜。
	if not (_anchor_revision is int): _anchor_revision = 0
	if not (_score_revision is int): _score_revision = 0
	if not (_anchor_handoff is Dictionary): _anchor_handoff = {}
	if not (_fine_score_handoff is Dictionary): _fine_score_handoff = {}
	if not (_score_model is Dictionary): _score_model = {}
	if not (_score_cache_key is Dictionary): _score_cache_key = {}
	if not (_placement_env_error is String): _placement_env_error = ""
	if not (_make_count is int): _make_count = 0
	if not (_dispose_count is int): _dispose_count = 0
	if not (_ready_initialization_ms is float): _ready_initialization_ms = 0.0
	if not (_is_painting is bool): _is_painting = false
	if not (_brush_dirty is bool): _brush_dirty = false
	_repair_soft_reloaded_brush_watermark()


func lifecycle_state() -> int:
	_repair_soft_reloaded_members()
	return _lifecycle_state


func lifecycle_state_name() -> String:
	_repair_soft_reloaded_members()
	return LifecycleState.keys()[_lifecycle_state]


func is_ready() -> bool:
	_repair_soft_reloaded_members()
	return _lifecycle_state == LifecycleState.READY


func initialize_runtime() -> bool:
	_repair_soft_reloaded_members()
	if _lifecycle_state == LifecycleState.READY:
		return true
	if _lifecycle_state == LifecycleState.INITIALIZING:
		return false
	if _lifecycle_state == LifecycleState.SHUTTING_DOWN:
		return false
	if _lifecycle_state == LifecycleState.DISPOSED:
		_lifecycle_state = LifecycleState.NEW
	var started_usec := Time.get_ticks_usec()
	_lifecycle_state = LifecycleState.INITIALIZING
	_failure_reason = ""
	_ensure_owned_tree()

	_tile_store = SceneVoxelTileStoreScript.new()
	_field_builder = SceneVoxelFieldBuilderScript.new()
	_sv_committer = SceneVoxelCommitterScript.new(
		base_resolution,
		capture_size,
		_tile_store,
		_field_builder,
		self
	)
	_owns_committer = true
	var rd := _sv_committer.get_rendering_device() as RenderingDevice
	if rd == null:
		_release_gpu_owners(false)
		_lifecycle_state = LifecycleState.UNAVAILABLE_NO_RD
		_failure_reason = "rendering_device_unavailable"
		return false

	_sv_committer.configure_scene_voxel_grid(grid_size, voxel_size, grid_origin)
	_seed_terrain_collision_field()

	_runtime = ScenePlacementRuntimeScript.new()
	_runtime.set_autoobject_runtime_capacity(maxi(autoobject_capacity, 1))
	if not _runtime.attach_rendering_device(rd, false):
		return _fail_initialization("runtime_rendering_device_attach_failed")
	if not _runtime.initialize(false, false, _sv_committer, _tile_store, self):
		return _fail_initialization("runtime_initialize_failed")
	if not _brush_sv_control_metadata.is_empty():
		_runtime.set_brush_sv_persistence_metadata(_brush_sv_control_metadata)
	_make_count += 1

	# 资产注册的唯一入口：扫 Bake 目录。
	#
	# ⚠ 恒 force：init 必须拿到磁盘上的最新版本，不能被任何短路挡住。
	# 短路条件里的 `_arena_load_state` / `_arena_loaded_signature` 是 **SPA 级**成员，而
	# registry 活在 `_runtime` 里；编辑器摘挂 scene root 会 `_exit_tree → _shutdown` 换掉
	# `_runtime` 而这两个缓存留着，于是第二次 init 短路返回「成功」实则 0 资产（实测踩过）。
	# 目录签名也只是「路径 + mtime」，同秒内重写的产物它分辨不出来。
	# 代价是每次 init 多一次 Arena 上传（实测 ~57 ms），换的是「打开就是最新的」这个恒真前提。
	#
	# 加载失败不阻断 init：Arena 保持空，Anchors/Score/Place 会因 Arena 未就绪而置灰，
	# Inspector 上给出可读原因；把它升级成 init 失败只会让整个 SPA 起不来。
	var baked_load := load_baked_assets()
	if not bool(baked_load.get("ok", false)):
		push_warning("[ScenePlacementActor] init 期 Bake 资产加载未完成（%s）——点 Reload 重试。" % [
			str(baked_load.get("reason", "unknown"))])
	var commit_result := _sv_committer.commit_scene_voxels()
	if not bool(commit_result.get("ok", false)):
		return _fail_initialization("initial_scene_sv_commit_failed")
	if _tile_store == null or not _tile_store.ensure_scene_voxel_tile_buffers_uploaded(true):
		return _fail_initialization("initial_svtile_gpu_bootstrap_failed")
	_runtime.ensure_brush_sv_fields()
	_prepare_target_read_buffers()
	if _target_read_buffers.is_empty() or not bool(_target_read_buffers.get("ok", false)):
		return _fail_initialization("target_read_buffers_not_ready")

	if _selection_host != null:
		_selection_host.attach_runtime_context(_sv_committer)
		_sync_display_bookkeeping_from_volumes()
	_ready_initialization_ms = float(Time.get_ticks_usec() - started_usec) / 1000.0
	_lifecycle_state = LifecycleState.READY
	return true


## 把每个卷**自己那份** `display_visible` 播回 SelectionHost 的记账位。
##
## 记账位不是第二个真值源，它是两样东西：「按显示组下发 node.visible」的广播口，以及
## 族外容器域（AutoObject 的 `PlacedAutoObjects`）的**唯一**开关。问题出在它的**初值**——
## `SPAEditorContract.default_voxel_display_state()` 把六个键一律播种成 true，而
## SceneSV / SVTile / BrushSV / TargetSV 的 `default_display_visible()` 都是 false：
## 于是开场就有四个键在撒谎，`is_voxel_display_visible()`（桥、`tools/pick_id_click_types.js`
## 读的就是它）会把隐藏域报成可见。这条不一致正是「点 Anchors 显示、TargetSV 自己被建
## 出来」那个缺陷的根，成因详见 `spa_selection_host.gd` 的 `_refresh_selection_markers()`。
##
## ⚠ 方向恒为**卷 → 记账位**，绝不反向：卷才是真值（`rebuild_display()` 读的就是它）。
## ⚠ 时机取 init 末尾而不是 `_ensure_owned_tree()` 里：卷是在 `_enter_tree` 建的，
## 而写 `display_visible` 的是它们的 NOTIFICATION_READY，比建节点晚一步——在建的那一刻
## 同步会读到尚未应用默认值的槽位。
func _sync_display_bookkeeping_from_volumes() -> void:
	if _selection_host == null or _volumes == null:
		return
	for child in _volumes.get_children():
		if not (child is PickableDomain):
			continue
		var domain := child as PickableDomain
		# 无显示键的卷（BlendSV：participates_in_picking() == false）没有记账位可写。
		var domain_display_key := domain.display_key()
		if domain_display_key.is_empty():
			continue
		_selection_host.set_voxel_display_visible(domain_display_key, domain.is_display_visible())


func _shutdown(sync_before_free := true) -> void:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	if _lifecycle_state in [LifecycleState.SHUTTING_DOWN, LifecycleState.DISPOSED]:
		return
	_lifecycle_state = LifecycleState.SHUTTING_DOWN
	_is_painting = false
	_brush_dirty = false
	for provider in _providers.values():
		if is_instance_valid(provider) and _selection_host != null:
			_selection_host.unregister_volume_score_provider(provider)
	_providers.clear()
	# 交接必须先于 GPU owner 释放作废：借方核对 revision 时不能看到「还在发布中」的
	# 记录指向一批马上要被 free 的 RID。两侧 revision 都递增，旧快照一律判旧。
	_anchor_revision += 1
	_anchor_handoff = {}
	_last_anchor_result = {}
	_invalidate_score_handoff()
	_last_score_result = {}
	_last_place_result = {}
	# 阶段底座只缓存阶段产物、不拥有任何 GPU owner，dispose 后紧跟着的 _release_gpu_owners
	# 才是真正释放显存的一步；这里先断掉它，免得后续路径又经它借到已死 RID。
	if _placement_env != null:
		_placement_env.dispose()
		_placement_env = null
	_placement_env_error = ""
	_score_runner = null
	_score_model = {}
	_score_cache_key = {}
	if _selection_host != null:
		_selection_host.release_gpu_resources(sync_before_free)
	_target_read_buffers.clear()
	_release_gpu_owners(sync_before_free)
	_dispose_count += 1
	_lifecycle_state = LifecycleState.DISPOSED


func _release_gpu_owners(sync_before_free: bool) -> void:
	if _runtime != null:
		_runtime.dispose(sync_before_free)
		_runtime = null
	if _field_builder != null:
		_field_builder.teardown()
		_field_builder = null
	if _tile_store != null:
		_tile_store.teardown()
		_tile_store = null
	if _sv_committer != null and _owns_committer:
		_sv_committer.dispose(sync_before_free)
	_sv_committer = null
	_owns_committer = false


func _fail_initialization(reason: String) -> bool:
	_failure_reason = reason
	push_error("[ScenePlacementActor] initialization failed: %s" % reason)
	_release_gpu_owners(false)
	_lifecycle_state = LifecycleState.FAILED
	return false


func _ensure_owned_tree() -> void:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	_volumes = get_node_or_null("Volumes") as Node
	if _volumes == null:
		_volumes = Node.new()
		_volumes.name = "Volumes"
		add_child(_volumes)
	_target_sv = _volumes.get_node_or_null("TargetSV") as TargetSVSetup
	if _target_sv == null:
		_target_sv = TargetSVSetupScript.new()
		_target_sv.name = "TargetSV"
		_volumes.add_child(_target_sv)
	# 三个逻辑卷的节点。**V1 之前它们是裸 `Node`**：只为让当时的 `spa_checks.test_owned_tree`
	# （该套件已于 2026-08-07 删除）的 direct_component_instance_id != 0 通过而存在，
	# 全仓没有任何地方读它们。
	# 现在换成 AutoVolumeField 子类，它们才第一次真的代表各自的域——域身份、元素空间、
	# 场对读口、内容修订号都由节点自己回答（《AutoVolume 公用体积基类计划》V1）。
	#
	# ⚠ 场对 Buffer 的**所有权没有变**：SceneSV 仍归 SceneVoxelTileStore（V3 劈开前），
	# BrushSV / BlendSV 仍归 ScenePlacementRuntime（它才是 RenderingDevice 持有者）。
	# 三个节点都是转发口，不是新的所有者——搬所有权会让 GPU 管线反过来依赖场景树节点。
	#
	# ⚠ 已存场景里这三个节点是无脚本的 `Node`，类型对不上，必须**换掉**而不是复用：
	# 直接 set_script 到 Node 上会得到一个 Node3D 脚本挂在 Node 实例上（缺 transform，
	# 基类的 is Node3D 判型与 to_global 全废）。换的时候按名字先删旧的。
	#
	# 所有权报告按「每个 PickableDomain 自报」生成（2026-08-10）——本表只负责建节点，
	# 报告行的形状与内容由各域自己回答（含 SVTile 的 buffers 明细，见其 _extend 钩子）。
	for volume_spec in [
		[&"SceneSV", SceneSVVolumeScript],
		[&"BrushSV", BrushSVVolumeScript],
		[&"BlendSV", BlendSVVolumeScript],
		[&"SVTile", SVTileVolumeScript],
		[&"Anchor", AnchorVolumeScript],
		# 实例域（SoA + alive[]），**不是体积卷**——但同样是 PickableDomain，自报同形状的一行。
		[&"AutoObject", AutoObjectDomainScript],
	]:
		var volume_key: StringName = volume_spec[0]
		var volume_script: Script = volume_spec[1]
		var existing := _volumes.get_node_or_null(NodePath(String(volume_key)))
		if existing != null and existing.get_script() != volume_script:
			_volumes.remove_child(existing)
			existing.free()
			existing = null
		if existing == null:
			var volume_node: Node3D = volume_script.new()
			volume_node.name = String(volume_key)
			_volumes.add_child(volume_node)

	_brush_volume = _volumes.get_node_or_null("BrushSV") as BrushSVVolume

	_interaction = get_node_or_null("Interaction") as Node3D
	if _interaction == null:
		_interaction = Node3D.new()
		_interaction.name = "Interaction"
		add_child(_interaction)
	_selection_host = _interaction.get_node_or_null("SelectionHost") as SPASelectionHost
	if _selection_host == null:
		_selection_host = SPASelectionHostScript.new()
		_selection_host.name = "SelectionHost"
		_interaction.add_child(_selection_host)
		_selection_host.configure({})
	# ⚠ 这里不注入 SPA：SelectionHost 与 SPA 是结构性强绑定（host 按构造就长在本子树里），
	# 宿主由它自己的父链解析得到，父链上找不到即报错。别再加 attach_spa 之类的注入口——
	# 那会变成"两套绑定机制、不清楚谁赢"。
	_selection_host.attach_target_sv(_target_sv)
	_brush_input = _interaction.get_node_or_null("MeshFillBrush") as MeshFillBrush
	if _brush_input != null:
		# attach_target_sv 只在 TargetSV 真的**换了**时返回 true（addon 只做身份跟踪，
		# 2026-08-10 起不再持有任何笔刷数据）。换靶时笔迹画在旧靶网格上，必须两半一起清：
		# clear_brush_sv() 现在同时清 GPU 场与卷节点的 CPU 列表/显示，
		# 并包含 _invalidate_brush_flush_watermark()。
		if _brush_input.attach_target_sv(_target_sv):
			clear_brush_sv()

	_displays = get_node_or_null("Displays") as Node3D
	if _displays == null:
		_displays = Node3D.new()
		_displays.name = "Displays"
		add_child(_displays)


## 规范坐标框架的**权威读口**：网格 = grid_size、格距 = voxel_size、原点 = grid_origin。
##
## 事实源仍是上面那三个 @export，本方法只是把「这三项合起来才叫一个框架」这件事变成一个
## 有名字的东西。设立它的直接原因：卷侧（TargetSVSetup / MeshFillBrush / SPASelectionHost /
## PlacementStageEnv）此前各自拼同一个三键字典，《AutoVolume 公用体积基类计划》§2.3 要求
## 基类「通过 _spa 引用转发，不复制」——转发得有个转发目标。
##
## ⚠ 本方法**不取代**四个 GPU 组件的直读：SceneVoxelCommitter / SceneVoxelTileStore /
## SceneVoxelFieldBuilder / ScenePlacementRuntime 经注入的 `_grid_owner`（= 本节点）鸭子类型
## 直读 `_grid_owner.grid_size`（field builder 还读 base_resolution）。那四处 grep
## `spa.grid_size` 抓不到，且改名只会在跑管线时炸、parse gate 与 -e 门禁都放过。
## 三个 @export 因此必须保持原名可读，本方法是**增设**而非替换。
##
## ⚠ 别把返回值按字典顺序展开喂给 `VoxelGeneral.scaled_grid_frame()`：那个函数的形参序是
## (grid_size, **grid_origin**, **voxel_size**, display_scale)，与这里的键序正好把后两项对调。
## 两者都是 Vector3，传反了不报错、不崩，只是整套坐标静默错位。要按键名取。
func get_grid_frame() -> Dictionary:
	return {
		"grid_size": grid_size,
		"voxel_size": voxel_size,
		"grid_origin": grid_origin,
	}


func _seed_terrain_collision_field() -> void:
	if _field_builder == null:
		push_error("[ScenePlacementActor] _seed_terrain_collision_field: _field_builder 为 null —— 调用点在 initialize_runtime 中紧跟 field builder 构造，出现即生命周期已断。")
		assert(false, "[ScenePlacementActor] _seed_terrain_collision_field: _field_builder == null")
		return
	var terrain_result: Dictionary = TerrainInitializerScript.reuse_shared_terrain(self)
	if not bool(terrain_result.get("ok", false)):
		return
	var terrain := terrain_result.get("terrain") as MeshInstance3D
	var heights := TerrainInitializerScript.terrain_height_field_from_mesh(
		terrain, grid_size.x, TerrainConfigScript.MAX_HEIGHT)
	if heights.is_empty():
		# 地形节点存在却解不出高度场（成因已由 TerrainInitializer 报出）。旧行为直接
		# return —— SceneSV 的地形碰撞底噪整块缺失，放置会当成“地面平在 y=0”。
		push_error("[ScenePlacementActor] _seed_terrain_collision_field: 地形 '%s' 高度场解算失败（texture_size=%d）——地形碰撞底噪无法播种。" % [
			terrain.name if terrain != null else "<null>", grid_size.x])
		assert(false, "[ScenePlacementActor] _seed_terrain_collision_field: empty height field")
		return
	var values := PackedFloat32Array()
	values.resize(grid_size.x * grid_size.z)
	if heights.size() != values.size():
		# 旧行为按 mini() 截断/部分填充：多出来的体素列保持 0，得到一块“半张地形”。
		push_error("[ScenePlacementActor] _seed_terrain_collision_field: 高度场尺寸与网格 XZ 不符（heights=%d, expected=%d, grid_size=%s）——截断填充会留下半张地形。" % [
			heights.size(), values.size(), str(grid_size)])
		assert(false, "[ScenePlacementActor] _seed_terrain_collision_field: height field size mismatch")
		return
	for i in range(values.size()):
		values[i] = clampf(heights[i] / 100000.0, 0.0, 1.0)
	var image := Image.create_from_data(grid_size.x, grid_size.z, false, Image.FORMAT_RF, values.to_byte_array())
	_field_builder.set_terrain_base_collision_field(image)


func _prepare_target_read_buffers() -> void:
	_target_read_buffers.clear()
	if _runtime == null or _target_sv == null or _sv_committer == null or _tile_store == null:
		push_error("[ScenePlacementActor] _prepare_target_read_buffers: 组件缺失（runtime=%s, target_sv=%s, committer=%s, tile_store=%s）——调用点在 initialize_runtime 中它们均已构造。" % [
			str(_runtime != null), str(_target_sv != null), str(_sv_committer != null), str(_tile_store != null)])
		assert(false, "[ScenePlacementActor] _prepare_target_read_buffers: missing owned component")
		return
	var visual_bytes := _target_sv.get_visual_bytes()
	var collision_r8 := _target_sv.get_collision_bytes()
	var voxel_count := grid_size.x * grid_size.y * grid_size.z
	if visual_bytes.size() != voxel_count * 4 or collision_r8.size() != voxel_count:
		# 旧行为静默 return，只在上层留下一个笼统的 target_read_buffers_not_ready。
		push_error("[ScenePlacementActor] _prepare_target_read_buffers: TargetSV 字节数与网格不符（visual=%d 期望=%d, collision=%d 期望=%d, grid_size=%s）——TargetSV 烘焙数据与 grid_size 必须同源。" % [
			visual_bytes.size(), voxel_count * 4, collision_r8.size(), voxel_count, str(grid_size)])
		assert(false, "[ScenePlacementActor] _prepare_target_read_buffers: target sv byte count mismatch")
		return
	var settings := {
		"target_visual_rgba8_bytes": visual_bytes,
		"target_collision_r8_bytes": SceneVoxelTileCodecScript.u32_bytes_from_r8_bytes(collision_r8, voxel_count),
	}
	_target_read_buffers = _runtime.prepare_target_read_buffers_from_common_gpu(settings, _sv_committer.get_sv())
	if bool(_target_read_buffers.get("ok", false)):
		_tile_store.mark_all_scene_voxel_tiles_dirty(
			{"target": true, "scoring": true},
			{"id": "target_sv_revision", "source_id": "target_sv_revision"}
		)


func get_identity_report() -> Dictionary:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	var rd := get_rendering_device()
	# GPU AutoObject runtime 的就绪位单独报：它**不等于** SPA 的 ready。它没就绪时，
	# 放置的 write_accepted_placements_to_gpu_runtime 不会置位（scene_placement_runtime.gd
	# 的 `if _gpu_runtime != null and _gpu_runtime.is_ready()` 门），于是 alive/transform
	# 缓冲一个字节都不写——而 spawned 计的是放置结果，照样报几百个。
	# 表现是"放置成功但什么都没渲染、点选也拿不到对象"，且全程零报错。
	var gpu_runtime = get_gpu_runtime()   # 无静态类型（RefCounted 子类），故不用 :=
	var gpu_runtime_ready: bool = gpu_runtime != null and gpu_runtime.is_ready()
	var report := {
		"lifecycle_state": lifecycle_state_name(),
		"gpu_autoobject_runtime_ready": gpu_runtime_ready,
		"gpu_autoobject_runtime_not_ready_reason": 			"" if gpu_runtime_ready else (
				str(gpu_runtime.get_not_ready_reason()) if gpu_runtime != null 					and gpu_runtime.has_method("get_not_ready_reason") else "gpu_runtime_null"),
		"ready": is_ready(),
		"failure_reason": _failure_reason,
		"spa_instance_id": get_instance_id(),
		"runtime_instance_id": _instance_id(_runtime),
		"rendering_device_instance_id": _instance_id(rd),
		"committer_instance_id": _instance_id(_sv_committer),
		"tile_store_instance_id": _instance_id(_tile_store),
		"field_builder_instance_id": _instance_id(_field_builder),
		"make_count": _make_count,
		"dispose_count": _dispose_count,
		"ready_initialization_ms": _ready_initialization_ms,
	}
	# grid_size / voxel_size / grid_origin —— 走权威读口，不在这里第二次手拼那三键
	# （键名与 get_grid_frame() 同源；它的键集变了这里跟着变，这正是设立它的目的）。
	report.merge(get_grid_frame())
	return report


func get_volume_ownership_report() -> Array[Dictionary]:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	# 旧实现按 VOLUME_KEYS 逐键 get_volume()，树的存在性由那条链隐式保证；
	# 现在直接遍历 _volumes 的孩子，先显式把树建出来。
	_ensure_owned_tree()
	var report: Array[Dictionary] = []
	var rd_id := _instance_id(get_rendering_device())
	# 每个域自报一行（PickableDomain.ownership_report_entry，2026-08-10）：
	# 修订号 / resident / 域专属明细全部由节点回答——此前 SVTile 靠一条手工合成行、
	# Anchor / AutoObject 干脆缺席、BlendSV 的 resident 因字典读数被节点覆盖而恒 false。
	# SPA 只补它自己才知道的键；"ready" 缺席才补（SVTile 按 GPU 真值先写，不覆盖）。
	if _volumes != null:
		for child in _volumes.get_children():
			if not (child is PickableDomain):
				continue
			var entry := (child as PickableDomain).ownership_report_entry()
			entry["lifecycle_owner_path"] = get_path() if is_inside_tree() else NodePath()
			if not entry.has("ready"):
				entry["ready"] = is_ready()
			entry["rd_instance_id"] = rd_id
			report.append(entry)
	for provider_key in _providers:
		var provider := _providers[provider_key] as Node
		report.append({
			"name": String(provider_key),
			"owner_path": provider.get_path() if provider != null and provider.is_inside_tree() else NodePath(),
			"lifecycle_owner_path": get_path() if is_inside_tree() else NodePath(),
			"revision": 0,
			"resident": true,
			"ready": provider != null and is_ready(),
			"rd_instance_id": rd_id,
			"direct_component_instance_id": _instance_id(provider),
		})
	# revision 显式传入而不是从 state 字典里猜：现在它由 SPA 自己持有，
	# 也是借方核对快照新鲜度用的同一个数（见 get_placement_selection_handoff）。
	report.append(_pipeline_state_report(
		&"AnchorHandoff", get_anchor_candidate_handoff(), rd_id, _anchor_revision))
	report.append(_pipeline_state_report(
		&"FineCandidates", _last_score_result, rd_id, _score_revision))
	report.append(_pipeline_state_report(&"FineWinners", _last_place_result, rd_id))
	return report

## 当前 Anchor 常驻交接（AutoObjectProbePrefilterGPU 产出，owner=prefilter）。
func get_anchor_candidate_handoff() -> Dictionary:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	return _anchor_handoff


## 当前 Fine（Score）常驻交接（VoxelPlacementGenerator 产出，owner=VPG）。
func get_fine_score_handoff() -> Dictionary:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	return _fine_score_handoff


## 从任意一层结果里取 Anchor 交接。两种承载形态：run_autoobject_prefilter 的直返结果
## 把它放顶层，走完整流水线的结果把 prefilter 结果整份嵌在 prefilter_result 里——
## 两处都要认，否则换一条入口跑 Anchors 就取不到。
static func _anchor_handoff_in(result: Dictionary) -> Dictionary:
	var handoff: Dictionary = result.get("anchor_candidate_handoff", {})
	if handoff.is_empty():
		var nested_prefilter: Dictionary = result.get("prefilter_result", {})
		handoff = nested_prefilter.get("anchor_candidate_handoff", {})
	return handoff


func get_anchor_revision() -> int:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	return _anchor_revision


func get_score_revision() -> int:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	return _score_revision


## 点选/显示用的**只读**交接：把互相关联的 Anchor + Fine RID 与几何参数打成一条一致记录，
## 而不是让借方各自去翻 _last_*_result。
##
## 借用契约（借方 = SelectionHost / 统一 GPU 点选，不是所有者）：
## - 全部 RID 为借用，借方不得 free_rid / release_rid / buffer update / dispatch；
## - 只发布**当前常驻**且有效的 RID；任一必需 RID 失效即整条 ok=false，不发半条；
## - 禁止仅凭 RID 数值判断快照是否新鲜——RID 会被复用，必须核对 anchor_revision /
##   score_revision，读取前后各一次，不一致则丢弃结果并最多重试一次；
## - 无 RD 或交接不可用时明确返回 ok=false + reason，绝不伪造 CPU fallback 成功。
##
## scored=false 是合法状态（只跑过 Anchors 没跑过 Score）：此时 Anchor 侧 RID 有效、
## Fine 侧为空 RID，借方按 scored 分支决定能不能做 winner 命中。
func get_placement_selection_handoff() -> Dictionary:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	var rd := get_rendering_device()
	if rd == null:
		return {"ok": false, "reason": "selection_data_unavailable", "detail": "rendering_device_unavailable"}
	var anchor_handoff := get_anchor_candidate_handoff()
	if anchor_handoff.is_empty() or not bool(anchor_handoff.get("ok", false)):
		return {"ok": false, "reason": "selection_data_unavailable", "detail": "anchor_handoff_not_resident"}
	var anchor_rid: RID = anchor_handoff.get("anchor_buffer_rid", RID())
	var anchor_count_rid: RID = anchor_handoff.get("anchor_count_buffer_rid", RID())
	var topk_rid: RID = anchor_handoff.get("topk_buffer_rid", RID())
	if not anchor_rid.is_valid() or not anchor_count_rid.is_valid() or not topk_rid.is_valid():
		return {"ok": false, "reason": "selection_data_unavailable", "detail": "anchor_rid_invalid"}
	var fine_handoff := get_fine_score_handoff()
	var fine_candidate_rid: RID = fine_handoff.get("fine_candidate_buffer_rid", RID())
	var fine_winner_rid: RID = fine_handoff.get("fine_winner_buffer_rid", RID())
	# Fine 侧要么整对有效要么整对判空：只有候选没有胜出（或反过来）时，按「已评分」
	# 分支去点选会朝一个空 RID 建 uniform set。
	var scored := bool(fine_handoff.get("ok", false)) \
		and fine_candidate_rid.is_valid() and fine_winner_rid.is_valid()
	var handoff := {
		"ok": true,
		"scored": scored,
		"anchor_revision": _anchor_revision,
		"score_revision": _score_revision,
		"anchor_buffer_rid": anchor_rid,
		"anchor_count_buffer_rid": anchor_count_rid,
		"topk_buffer_rid": topk_rid,
		"fine_candidate_buffer_rid": fine_candidate_rid if scored else RID(),
		"fine_winner_buffer_rid": fine_winner_rid if scored else RID(),
		"anchor_capacity": int(anchor_handoff.get("anchor_capacity", 0)),
		"anchor_stride_bytes": int(anchor_handoff.get("anchor_stride_bytes", 16)),
		"topk": int(anchor_handoff.get("topk", 4)),
		"topk_stride_bytes": int(anchor_handoff.get("topk_stride_bytes", 8)),
		"fine_record_stride_bytes": int(fine_handoff.get("fine_record_stride_bytes", 0)) if scored else 0,
		"live_anchor_count": int(fine_handoff.get("live_anchor_count", -1)) if scored else -1,
		"asset_stride": int(anchor_handoff.get("asset_stride", 1)),
		"rendering_device": rd,
		"borrowed": true,
		"owner_path": get_path() if is_inside_tree() else NodePath(),
	}
	# grid_size / voxel_size / grid_origin —— 与 get_identity_report() 同理走权威读口，
	# 借方按键名取（本记录带 RID / RenderingDevice，本来就不可 JSON 序列化，无键序依赖）。
	handoff.merge(get_grid_frame())
	return handoff


## Anchors 结果落库；只有**真的带交接**的那一层才换代。
## 不带交接的薄状态字典（例如 demo 的 {ok, anchors, scored}）只更新 _last_anchor_result，
## 保留内层刚发布的交接——否则外层返回会把它抹掉。
func _publish_anchor_result(result: Dictionary) -> Dictionary:
	_last_anchor_result = result
	var handoff := _anchor_handoff_in(result)
	if handoff.is_empty():
		return _last_anchor_result
	_anchor_revision += 1
	_anchor_handoff = handoff
	# 新锚点 = 旧评分的输入没了。Score 交接必须同批作废，否则点选会拿上一代 winner
	# 去配这一代 anchor 下标。
	_invalidate_score_handoff()
	return _last_anchor_result


## Score 结果落库；同样只有带 fine_score_handoff 的那一层才换代。
func _publish_score_result(result: Dictionary) -> Dictionary:
	_last_score_result = result
	var handoff: Dictionary = result.get("fine_score_handoff", {})
	if handoff.is_empty():
		return _last_score_result
	_score_revision += 1
	_fine_score_handoff = handoff
	return _last_score_result


## Place 结果落库。两件事：
##
## 1. **接力发布 Anchor 交接**：整链（run_placement_pipeline）每批都在共享 prefilter 实例上
##    重跑 collect，缓存未命中时常驻 anchor/count 缓冲会被**释放重建**
##    （AutoObjectProbePrefilterGPU._release_resident_collect_cache → 新 RID），已发布交接里的
##    RID 随之变成死句柄；就算命中复用，atomicAdd 分配的槽位顺序也换了。所以带 prefilter
##    交接的结果必须像 _publish_anchor_result 一样换代接力，否则借方按旧 revision 核对，
##    读到的却是换代（甚至已释放）的缓冲——此前 Place 之后点选锚点就踩在这条上。
##    ⚠ 取**嵌套**的 prefilter_result.anchor_candidate_handoff，不能用 _anchor_handoff_in：
##    整链结果的顶层同名键是 RID-less 摘要（_anchor_candidate_handoff_summary），
##    _anchor_handoff_in 会优先拿到它，发布出去点选侧全是空 RID。
## 2. **作废评分状态**：Place 改写 SceneSV ⇒ score cache key、模型与 Score 交接同批作废。
##    模型不清会让 demo 侧 `_sync_model_from_spa()` 把放置前的旧评分继续喂给显示/HUD。
##    统一清在这里而不是 run_place 末尾：run_pipeline_once（bridge benchmark）等旁路
##    也改写 SceneSV，走的同样是本出口。
func _publish_place_result(result: Dictionary) -> Dictionary:
	_last_place_result = result
	var handoff: Dictionary = (result.get("prefilter_result", {}) as Dictionary).get("anchor_candidate_handoff", {})
	if bool(handoff.get("ok", false)):
		_anchor_revision += 1
		_anchor_handoff = handoff
		# 新锚点 = 旧评分的输入没了（与 _publish_anchor_result 同一理由）。
		_invalidate_score_handoff()
	if bool(result.get("ok", false)):
		_score_cache_key = {}
		_score_model = {}
		_invalidate_score_handoff()
	return _last_place_result


## 作废已发布的 Fine 交接：换代 + 丢掉 handoff 键。
## ⚠ 只解除**发布**，不释放显存——Fine candidate/winner 的 owner 是 VPG，释放点在
## VPG 那边（形状变化的下一次 Score / release_resident_score_handoff / dispose）。
## 这里先换代再丢键，借方核对 score_revision 时不会看到「新 revision + 旧 RID」。
func _invalidate_score_handoff() -> void:
	# 没发布过就没有可作废的东西：空转不递增，免得每次 Anchors/Place 都把 revision 推高，
	# 让借方为一次并不存在的换代重建 uniform set。
	if _fine_score_handoff.is_empty():
		return
	_score_revision += 1
	_fine_score_handoff = {}


## revision_override < 0 = 沿用 state 自述的 revision（Place 结果仍走这条）。
func _pipeline_state_report(
	state_key: StringName, state: Dictionary, rd_id: int, revision_override: int = -1
) -> Dictionary:
	return {
		"name": String(state_key),
		"owner_path": get_path(),
		"lifecycle_owner_path": get_path(),
		"revision": revision_override if revision_override >= 0 \
			else int(state.get("revision", state.get("handoff_revision", 0))),
		"capacity": int(state.get("capacity", state.get("anchor_capacity", state.get("record_count", 0)))),
		"resident": not state.is_empty(),
		"ready": bool(state.get("ok", false)),
		"rd_instance_id": int(state.get("rd_instance_id", rd_id)),
	}


static func _instance_id(value) -> int:
	return value.get_instance_id() if value != null and is_instance_valid(value) else 0


func get_volume(volume_key: StringName) -> Node:
	_ensure_owned_tree()
	if volume_key == &"VolumeScore":
		return get_volume_provider(volume_key)
	return _volumes.get_node_or_null(NodePath(String(volume_key)))


# ⚠ 这里曾有 `get_scene_sv_snapshot()` / `get_target_sv_snapshot()` 两个快照门面——
# 全仓（.gd/.js）零调用（2026-08-10 链路死码清除；TargetSV 侧的 get_display_snapshot
# 随唯一消费方 MeshFillBrush 切进卷节点而失去调用方，一并删除）。


## SPA-owned SVTile GPU access surface. Production consumers borrow RIDs; only
## explicit debug methods expose immutable CPU projections.
func ensure_svtile_gpu_ready(force: bool = false) -> bool:
	return _tile_store != null and _tile_store.ensure_scene_voxel_tile_buffers_uploaded(force)


func get_svtile_gpu_buffer(buffer_name: String) -> RID:
	return _tile_store.get_scene_voxel_tile_gpu_buffer(buffer_name) if _tile_store != null else RID()


## 回读一整块 SVTile / SceneSV 常驻缓冲。⚠ 多兆字节同步回读，只走显式路径。
func read_svtile_gpu_buffer_bytes(buffer_name: String) -> PackedByteArray:
	return _tile_store.read_scene_voxel_tile_buffer_bytes(buffer_name) if _tile_store != null else PackedByteArray()


func get_svtile_gpu_status() -> Dictionary:
	return _tile_store.get_scene_voxel_tile_gpu_buffer_status() if _tile_store != null else {
		"ready": false,
		"reason": "tile_store_unavailable",
	}


func get_svtile_initialization_phases_ms() -> Dictionary:
	return _tile_store.get_initialization_phases_ms() if _tile_store != null else {}


func mark_svtile_bounds_dirty(
	voxel_min: Vector3i,
	voxel_max: Vector3i,
	dirty_flags: Dictionary = {},
	source_record: Dictionary = {}
) -> void:
	if _tile_store != null:
		_tile_store.mark_scene_voxel_tile_bounds_dirty(voxel_min, voxel_max, dirty_flags, source_record)

func get_svtile_debug_record(tile_coord: Vector3i) -> Dictionary:
	return _tile_store.get_scene_voxel_tile(tile_coord).duplicate(true) if _tile_store != null else {}


## 单块 tile 的 object-ref 计数：只回读该 tile 的 32 B 槽位，不经整表调试快照。
## -1 = 取不到（缓冲未上传/坐标越界/无 tile store），**不是** 0。
## 见 SceneVoxelTileStore.get_scene_voxel_tile_object_ref_count() 的口径说明。
func get_svtile_object_ref_count(tile_coord: Vector3i) -> int:
	return _tile_store.get_scene_voxel_tile_object_ref_count(tile_coord) if _tile_store != null else -1


func get_svtile_debug_tiles() -> Dictionary:
	return _tile_store.get_scene_voxel_tiles().duplicate(true) if _tile_store != null else {}


func register_volume_provider(provider: Node) -> Dictionary:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	if provider == null or not is_ancestor_of(provider):
		return {"ok": false, "reason": "provider_must_be_owned_by_spa"}
	var key := StringName(str(provider.get_meta("volume_key", provider.name)))
	if key == StringName():
		# 旧行为把无名 provider 一律当成 VolumeScore 注册，之后 get_volume_provider
		# 拿到的是一个来路不明的节点，冲突要到用它打分时才暴露。
		push_error("[ScenePlacementActor] register_volume_provider: provider 的 volume_key 为空（node=%s, meta=%s）——不能默认当作 VolumeScore 注册。" % [
			str(provider.get_path()) if provider.is_inside_tree() else provider.name,
			str(provider.get_meta("volume_key", ""))])
		assert(false, "[ScenePlacementActor] register_volume_provider: empty volume_key")
		return {"ok": false, "reason": "provider_volume_key_empty"}
	if _providers.has(key):
		return {
			"ok": false,
			"reason": "provider_already_registered",
			"volume_key": key,
			"same_provider": _providers[key] == provider,
		}
	_providers[key] = provider
	# 注册即订阅：provider 只要实现了 invalidate_asset_caches() 就自动接上换代广播，
	# 不需要它自己去找 SPA、也不需要 SPA 反过来记住谁实现了什么再逐个轮询。
	if provider.has_method("invalidate_asset_caches"):
		var cb := Callable(provider, "invalidate_asset_caches")
		if not baked_assets_reloaded.is_connected(cb):
			# 信号带两个参数而 invalidate_asset_caches() 无参：unbind 掉，
			# 否则连接时就会因签名不匹配失败（且只在运行到 emit 时才报错）。
			baked_assets_reloaded.connect(cb.unbind(2))
	if _selection_host != null and key == &"VolumeScore":
		_selection_host.register_volume_score_provider(provider)
	return {"ok": true, "volume_key": key, "provider": provider}


func unregister_volume_provider(provider: Node) -> Dictionary:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	if provider == null:
		return {"ok": false, "reason": "missing_provider"}
	var removed := false
	for key in _providers.keys():
		if _providers[key] == provider:
			_providers.erase(key)
			removed = true
	# 与 register 对称断开：provider 被摘掉后仍挂在信号上，下次换代会打到一个已不属于本 SPA
	# 的节点（编辑器反复摘挂 scene root 时尤其容易攒出一串）。
	if provider.has_method("invalidate_asset_caches"):
		var cb := Callable(provider, "invalidate_asset_caches").unbind(2)
		if baked_assets_reloaded.is_connected(cb):
			baked_assets_reloaded.disconnect(cb)
	if _selection_host != null:
		_selection_host.unregister_volume_score_provider(provider)
	return {"ok": removed, "reason": "ok" if removed else "provider_not_registered"}


func get_volume_provider(volume_key: StringName) -> Node:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	if _providers.has(volume_key):
		return _providers[volume_key] as Node
	if volume_key == &"VolumeScore" and _volumes != null:
		var provider := _volumes.get_node_or_null("VolumeScore")
		if provider != null:
			register_volume_provider(provider)
		return provider
	return null

## Bake 之后的「换代 + 重算」一步入口。
##
## ⚠ 这里曾是 `provider.reload_and_rescore()` 一句转发，而那个方法内部又回头调
## `SPA.load_baked_assets()`——SPA 让 provider 去让 SPA 重新加载，绕成一个环，也正是
## 「广播只作废不重算」那条限制的由来（否则就自递归了）。现在拉直：
##
##   加载 → 广播作废（provider 在 register 时已订阅）→ 重算
##
## 两步都由 SPA 直接发起，provider 只被动收广播 + 被调重算，不再反向驱动 SPA。
func refresh_volume_provider(volume_key: StringName = &"VolumeScore") -> Dictionary:
	var provider := get_volume_provider(volume_key)
	if provider == null:
		return {"ok": false, "reason": "provider_not_registered", "volume_key": volume_key}
	var load_result := load_baked_assets()
	if not bool(load_result.get("ok", false)):
		return {
			"ok": false,
			"reason": "load_failed:%s" % str(load_result.get("reason", "unknown")),
			"volume_key": volume_key,
		}
	if not provider.has_method("calculate_voxel_scores"):
		# 加载已经成功且广播已发出，缓存该作废的都作废了；只是没人能重算。
		return {"ok": true, "volume_key": volume_key, "rescored": false}
	provider.call("calculate_voxel_scores")
	return {"ok": true, "volume_key": volume_key, "rescored": true}


## 重新导入 TargetSV：本 SPA 的 TargetSV 节点从磁盘重读，并把持有旧解码结果的下游一起刷新。
##
## ⚠ 笔刷不会自己跟着刷新：MeshFillBrush.attach_target_sv() 在"同一个节点且数据已加载"时
## 直接返回 false 不重建（那条短路是给只读路径用的，见该函数注释），而重导入前后节点没变，
## 所以必须在这里显式 rebuild(true) 让它重新拉快照——否则它会继续按旧网格尺寸换算坐标。
## rebuild(true) 清空的是笔刷的 CPU 与显示状态，按 _ensure_owned_tree 里那条同款配对，
## BrushSV 的 GPU 半边必须一起清，否则留下不可见、不可编辑却仍在喂 BlendSV 与评分的孤儿体素。
##
## SelectionHost 只持有 TargetSV 的节点引用（attach_target_sv 就是一句赋值），
## 其点选缓存按 content_revision + TargetSVLoader.content_generation() 做键，自动作废。
## 只读校验一份 TargetSV FBX，不写盘、不动当前数据集。opts.deep=true 时连逐三角形读取与
## 落格试算一起做（贵，几十万面的场景级 FBX 上是几百 MB 级开销）。
func validate_target_sv_fbx(fbx_path: String, opts: Dictionary = {}) -> Dictionary:
	return TargetSVFbxImportServiceScript.validate_fbx(fbx_path, opts)


## 从一份"每个三角形 = 一个体素"的 FBX 烘出 TargetSV（覆盖 assets/target_sv）后立刻重导入。
##
## ⚠ 本方法**不往导入里注入 SPA 的网格**（2026-08-12 用户裁定）：导入是一条离线数据转换，
## 它按 `TerrainConfig` 自己推世界网格，不该依赖场景里有没有活的 SPA、它当时配成什么样。
## SPA 在这条链上只剩两件事：触发烘焙，和烘完把结果交给 TargetSV（`reimport_target_sv`）。
## 两边的框架是否真的一致，由**接收端**校验——`TargetSVSetup._assert_target_frame_matches_bake()`
## 在加载元数据时逐项比对并硬失败，而不是靠注入去"保证"它们相等。
func import_target_sv_from_fbx(fbx_path: String, opts: Dictionary = {}) -> Dictionary:
	var import_result: Dictionary = TargetSVFbxImportServiceScript.import_fbx_as_target_sv(fbx_path, opts)
	if not bool(import_result.get("ok", false)):
		return import_result
	var result := reimport_target_sv()
	# 覆盖已经发生，烘焙详情无论重导入成败都要带出去。
	for carried_key in ["source_fbx", "triangle_count",
			"rejected_triangle_count", "used_triangle_count", "below_terrain_count",
			"distinct_voxel_count",
			"dropped_out_of_bounds", "clipped_height_count", "non_empty_voxel_count",
			"capture_size", "vertical_span", "flip_z", "source_bounds", "written",
			# 读取器整趟看到的三角形数 / 退化面 / 缺 Cd 面，与分段耗时：漏带这几个键，
			# 编辑器那行验收摘要只会印 0，看不出"读了多少面只有多少面过门"。
			"read_triangle_count", "degenerate_triangle_count", "missing_payload_count",
			"timings_ms"]:
		result[carried_key] = import_result.get(carried_key)
	# 一格都没落进去时服务层已 push_warning 并把 reason 改掉，别让 reimport 的 "ok" 盖过它。
	if str(import_result.get("reason", "")) == "no_samples_in_grid":
		result["reason"] = "no_samples_in_grid"
	return result


## 导入一份外部 TargetSV 数据集（覆盖 assets/target_sv）后立刻重导入。
##
## 文件搬运在 TargetSVLoader.import_dataset —— 那里才知道规范目录布局；本方法只负责
## "搬完就换新"这条配对，并把两段结果合成一份报告。编辑器那侧还要按 copied 把复制进来的
## 已导入资源（preview png）交还资源系统，那一步用编辑器 API，留在插件里。
func import_target_sv_dataset(metadata_path: String) -> Dictionary:
	var import_result: Dictionary = TargetSVLoader.import_dataset(metadata_path)
	if not bool(import_result.get("ok", false)):
		return import_result
	var result := reimport_target_sv()
	# 覆盖已经发生：即便重导入失败也要把搬运详情带出去，否则没人说得清盖掉了什么。
	for carried_key in ["source", "same_dataset", "copied", "replaced"]:
		result[carried_key] = import_result.get(carried_key)
	return result


func reimport_target_sv() -> Dictionary:
	_ensure_owned_tree()
	if _target_sv == null:
		return {"ok": false, "reason": "target_sv_missing"}
	var result: Dictionary = _target_sv.reimport()
	if not bool(result.get("ok", false)):
		return result
	# 修订号由 TargetSV 节点自己保管（报告经 ownership_report_entry 自报）。
	# ⚠ 这里曾调 _brush_input.rebuild(true)——那时它要重读 TargetSV 快照数据。
	# addon 侧已不持有任何笔刷数据（2026-08-10），重导入只需清空 BrushSV 两半：
	# 笔迹画在旧靶网格上，重导入后不可编辑却仍喂合成与评分。
	result["brush_sv_cleared"] = bool(clear_brush_sv().get("ok", false))
	return result


func handle_editor_input(viewport_camera: Camera3D, event: InputEvent) -> bool:
	if not is_ready():
		return false
	# ⚠ 排在所有域消费方之前：Ctrl+Alt+数字 是**跨域**的显示开关，不属于任何一个域，
	# 让它先认领可避免将来某个域加了带修饰键的数字快捷键后互相吃键。
	if _handle_domain_visibility_editor_input(event):
		return true
	if _selection_host != null and _selection_host.handle_viewport_input(viewport_camera, event):
		return true
	# Interaction/DemoHost 的那一跳已移除：DemoHost 在 _editor_init 里无条件造第二份
	# PlacementStageEnv，两份 env 挂同一个 SPA 会互相释放对方的常驻 target 缓冲。它的
	# G/Space 热键已并入 VolumeScore 的 forward_editor_viewport_input（就是上面这一跳）。
	var provider := get_volume_provider(&"VolumeScore")
	if provider != null and provider.has_method("forward_editor_viewport_input") \
			and bool(provider.call("forward_editor_viewport_input", viewport_camera, event)):
		return true
	return _handle_brush_editor_input(viewport_camera, event)


func _handle_brush_editor_input(viewport_camera: Camera3D, event: InputEvent) -> bool:
	# _brush_input 只剩输入参数与地形环境（2026-08-10）；内容/显示/落笔定位在 _brush_volume。
	if _brush_input == null:
		return false
	if event is InputEventKey and event.pressed and not event.echo and event.shift_pressed:
		return _handle_brush_shortcut(event.keycode)
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_is_painting = true
			_brush_dirty = _paint_brush_at(viewport_camera, event.position)
		else:
			_is_painting = false
			_flush_owned_brush()
		return true
	if event is InputEventMouseMotion and _is_painting:
		_brush_dirty = _paint_brush_at(viewport_camera, event.position) or _brush_dirty
		return true
	return false


func _paint_brush_at(viewport_camera: Camera3D, position: Vector2) -> bool:
	if _brush_volume == null or not is_instance_valid(_brush_volume):
		return false
	# 落笔定位与体素累积都在卷节点；笔刷形状与绘制参数仍是 addon 侧的 @export（输入侧职责）。
	var voxel := _brush_volume.screen_to_voxel_xz(viewport_camera, position)
	if voxel.x < 0:
		return false
	var painted := _brush_volume.apply_brush_extent(
		voxel,
		Vector3i(_brush_input.brush_width, _brush_input.brush_height, _brush_input.brush_length),
		{
			"color": _brush_input.brush_paint_color,
			"complexity": _brush_input.brush_paint_complexity,
			"collision": _brush_input.brush_paint_collision,
		})
	if not painted:
		return false
	_flush_owned_brush()
	return true


## 把笔刷累积体素提交进 BrushSV 常驻层（每个 mouse-motion 事件触发一次，热路径）。
##
## 增量语义：MeshFillBrush._accumulate_brush_extent 是 append-only —— 已在
## `_brush_voxel_keys` 里的体素直接 `continue`，绝不回改它的颜色/复杂度/碰撞。所以
## `[0, _brush_flushed_count)` 这段前缀记录的内容在后续事件里恒定不变；而 BrushSV 散射走
## write_mode=0（overwrite，后笔胜）是幂等写，重发取值相同的记录等价于不发。因此本函数
## 只提交 `[_brush_flushed_count, count)` 的新增体素，最终 GPU 状态与整批重放逐位一致。
## 脏标记同样只覆盖本次真实写入的体素（runtime 侧按去重集合下发），不漏标。
##
## 水位失效条件 / 由谁负责失效：
##  1. 体素数变少，或水位末条体素的 (x, slice, z) 变了 —— 说明 MeshFillBrush 侧状态被
##     clear_brush() / _rebuild() 重置过；本函数自查后回退整批重放。
##  2. 笔刷绘制参数（paint color / complexity / collision）变化 —— 本函数自查后回退整批
##     重放。前缀条目本就保留各自绘制时的参数、不受影响，这一条纯属保守兜底：防止
##     "清空后用新参数重新涂到相同长度且末条相同"这种极端序列绕过条件 1。
##  3. 显式清空 BrushSV（clear_brush_sv）、旁路直写 BrushSV（apply_brush_input /
##     write_brush_sv_records 门面）、笔刷数据重建（attach_target_sv）——
##     由这些入口调用 _invalidate_brush_flush_watermark() 归零。
##  4. 散射失败（runtime 未就绪或 GPU 出错）—— 水位不前进并立刻归零，下次整批重试，
##     与旧版"每次都整批重放"的最终收敛行为一致。
## 跨编辑器会话 / 脚本重载：水位是普通实例成员（非 static），随 SPA 节点重建归零。
## ⚠ 编辑器**软重载**是另一回事，别指望它把水位复位：GDScriptInstance::reload_members()
## 只按名字把重载前已存在的成员搬进新槽位（值原样保留），而本次重载**新增**的成员槽是
## 默认构造的 Variant = nil，声明里的初始化器不会重跑。水位五件套一旦是 nil，条件 1/2
## 也救不了——`var start := _brush_flushed_count` 直接把 nil 赋给 int 局部即报错。故函数
## 开头显式修复，见 _repair_soft_reloaded_brush_watermark()。
func _flush_owned_brush() -> void:
	_repair_soft_reloaded_brush_watermark()
	if _brush_input == null or _brush_volume == null or not is_instance_valid(_brush_volume):
		return
	# 内容读口在卷节点（painted_voxels 是只读引用，append-only 语义见 BrushSVVolume）。
	var voxels: PackedInt32Array = _brush_volume.painted_voxels()
	var paint_attrs: Dictionary = _brush_volume.painted_paint_attributes()
	var attr_complexity: PackedFloat32Array = paint_attrs["complexity"]
	var attr_colors: PackedColorArray = paint_attrs["colors"]
	var attr_collision: PackedFloat32Array = paint_attrs["collision"]
	var count := int(voxels.size() / 4)
	var paint_color: Color = _brush_input.brush_paint_color
	var paint_levels := Vector2(_brush_input.brush_paint_complexity, _brush_input.brush_paint_collision)
	var start := _brush_flushed_count
	# ⚠ 必须在决定 start 之前先让 ensure_brush_sv_fields 发生：网格体素数变化时它会
	# clear_brush_sv(true) 重建出**清零**缓冲，抹掉已提交前缀。若放任它在
	# write_brush_sv_records 内部发生，水位看不见、增量只写新增条目，前缀就永久丢了。
	# 前置触发后用 revision 比对识别该事件（clear_brush_sv 会递增 revision）。
	var brush_sv_revision := -1
	if _runtime != null:
		_runtime.ensure_brush_sv_fields()
		brush_sv_revision = _runtime.get_brush_sv_revision()
	if start > count \
			or brush_sv_revision != _brush_flushed_sv_revision \
			or paint_color != _brush_flushed_paint_color \
			or paint_levels != _brush_flushed_paint_levels \
			or (start > 0 and _brush_voxel_triple(voxels, start - 1) != _brush_flushed_tail):
		start = 0
	if start >= count:
		# 无新增体素：显示节点内容与 BrushSV 内容均已是最新，整批重放是纯重复功。
		_brush_dirty = false
		return
	# 显示重建走基类模板（守卫按 revision + 实例数对账，空转不白跑）。
	_brush_volume.rebuild_display()
	var records: Array = []
	records.resize(count - start)
	for i in range(start, count):
		var base := i * 4
		records[i - start] = {
			"voxel_xz": Vector2i(voxels[base], voxels[base + 2]),
			"slice_index": voxels[base + 1],
			"complexity": attr_complexity[i],
			"color": attr_colors[i],
			"collision_strength": attr_collision[i],
		}
	_brush_dirty = false
	if _runtime == null:
		push_error("[ScenePlacementActor] _flush_owned_brush: _runtime 为 null —— 笔刷输入只在 is_ready() 下分发，出现即生命周期已断；本批 %d 条笔刷体素无法提交。" % records.size())
		assert(false, "[ScenePlacementActor] _flush_owned_brush: _runtime == null")
		_invalidate_brush_flush_watermark()
		return
	var brush_write_result: Dictionary = _runtime.write_brush_sv_records(records)
	if not bool(brush_write_result.get("ok", false)):
		# 旧行为只把水位归零后静默返回：用户已经画在屏幕上的笔迹并没有进 BrushSV。
		push_error("[ScenePlacementActor] _flush_owned_brush: BrushSV 散射失败（reason=%s, records=%d, start=%d, count=%d）——这批笔迹没有落进 GPU。" % [
			str(brush_write_result.get("reason", "unknown")), records.size(), start, count])
		assert(false, "[ScenePlacementActor] _flush_owned_brush: write_brush_sv_records failed")
		_invalidate_brush_flush_watermark()
		return
	_brush_flushed_count = count
	_brush_flushed_tail = _brush_voxel_triple(voxels, count - 1)
	_brush_flushed_paint_color = paint_color
	_brush_flushed_paint_levels = paint_levels
	_brush_flushed_sv_revision = _runtime.get_brush_sv_revision()


func _brush_voxel_triple(voxels: PackedInt32Array, index: int) -> Vector3i:
	var base := index * 4
	return Vector3i(voxels[base], voxels[base + 1], voxels[base + 2])


## 编辑器软重载后的水位修复，⚠ 别当成冗余判空删掉。
##
## 事实依据（gdscript.cpp GDScriptInstance::reload_members）：软重载只把**重载前已存在**
## 的成员按名字搬进新槽位；本次重载**新增**的成员槽是默认构造的 Variant = nil，声明里的
## 初始化器**不会**重跑。带静态类型也拦不住——实例槽本身是 Variant，nil 就这么躺在一个
## 声明为 int/Vector3i/Color/Vector2 的成员里。重载后第一次 _flush_owned_brush() 会炸在
## `var start := _brush_flushed_count`（把 nil 赋给 int 局部）上；就算侥幸不炸，
## 后面几条比较也会把 nil 的内存当 int/Color 读出垃圾值，让水位失效判定失灵。
##
## ⚠ 必须用 `is` 而不是 `== null`：对静态类型已知的操作数 GDScript 会挑验证求值器
## （gdscript_byte_codegen.cpp write_binary_operator），而 Variant 给 (INT, NIL)、
## (COLOR, NIL) 这类组合注册的是 OperatorEvaluatorAlwaysFalse（variant_op.cpp），
## `_brush_flushed_count == null` 会被编成恒 false，判空形同虚设。
## `is` 编成 OPCODE_TYPE_TEST_BUILTIN，查的是运行时真实类型，nil 一定为假。
##
## 语义：任意一件损坏就整组归零（复用失效入口），等价于失效条件 3/4——下一次
## _flush_owned_brush 整批重放。水位只用于"能否跳过前缀"，整批重放永远是正确结果，
## 不会漏写也不会重复写（BrushSV 散射是 overwrite 幂等）。
func _repair_soft_reloaded_brush_watermark() -> void:
	if _brush_flushed_count is int \
			and _brush_flushed_tail is Vector3i \
			and _brush_flushed_paint_color is Color \
			and _brush_flushed_paint_levels is Vector2 \
			and _brush_flushed_sv_revision is int:
		return
	_invalidate_brush_flush_watermark()


## 让下一次 _flush_owned_brush 整批重放：BrushSV GPU 内容被本类以外的路径改动，
## 或笔刷 CPU 侧体素状态被重建时调用（失效条件 3/4，见 _flush_owned_brush）。
func _invalidate_brush_flush_watermark() -> void:
	_brush_flushed_count = 0
	_brush_flushed_tail = Vector3i(-1, -1, -1)
	_brush_flushed_paint_color = Color(-1.0, -1.0, -1.0, -1.0)
	_brush_flushed_paint_levels = Vector2(-1.0, -1.0)
	_brush_flushed_sv_revision = -1


func _handle_brush_shortcut(keycode: int) -> bool:
	match keycode:
		KEY_B:
			# ⚠ 走 set_volume_display 门面（对齐 KEY_G）；真值问卷节点（2026-08-10 起
			# 笔刷显示在 BrushSVVolume，addon 侧的 brush_visible 开关已删除）。
			if _brush_volume != null and is_instance_valid(_brush_volume):
				set_volume_display(&"BrushSV", not _brush_volume.is_display_visible())
		KEY_G:
			set_volume_display(&"TargetSV", not _target_sv.is_display_visible())
		KEY_R:
			set_volume_display_channel(&"TargetSV", 0)
		KEY_T:
			set_volume_display_channel(&"TargetSV", 1)
		KEY_Y:
			set_volume_display_channel(&"TargetSV", 2)
		KEY_A:
			# Shift+A：winner 档内循环**排名**——全场每个锚点都显示它自己的第 N 名候选。
			# 同一排名下资产往往不同，按资产分组为多个 MultiMesh 节点同时挂（AnchorVolume 裁）。
			# 不在 winner 档时先切回 winner，让按键有可见反馈。
			var rank_volume := get_volume(&"Anchor")
			if rank_volume != null and rank_volume.has_method("cycle_winner_rank"):
				var rank := int(rank_volume.call("cycle_winner_rank"))
				print("[SPA] Anchor 胜出排名 → 第 %s 名（档 %s）" % [
					str(rank + 1) if rank >= 0 else "—",
					str(rank_volume.call("display_mode_name"))])
		KEY_S:
			# Shift+S：anchor 域三档循环（胜出实体 → 锚点小球 → 观察态 profile）。
			# 三档**互斥**，切换即丢弃旧档节点重建（AnchorVolume 裁）。
			var mode_volume := get_volume(&"Anchor")
			if mode_volume != null and mode_volume.has_method("cycle_display_mode"):
				print("[SPA] Anchor 显示档 → %s" % str(mode_volume.call("cycle_display_mode")))
		KEY_C:
			clear_brush_sv()
		KEY_EQUAL, KEY_KP_ADD:
			_brush_input.brush_width = clampi(_brush_input.brush_width + 2, 1, 128)
			_brush_input.brush_length = clampi(_brush_input.brush_length + 2, 1, 128)
		KEY_MINUS, KEY_KP_SUBTRACT:
			_brush_input.brush_width = clampi(_brush_input.brush_width - 2, 1, 128)
			_brush_input.brush_length = clampi(_brush_input.brush_length - 2, 1, 128)
		_:
			return false
	return true


## Ctrl+Alt+1..6 的槽位键表。**只有键，没有域**——槽位到域的映射直接取
## `SPAEditorContract.VOXEL_DOMAIN_BINDINGS` 的下标，见 `_handle_domain_visibility_shortcut()`。
const DOMAIN_VISIBILITY_SHORTCUT_KEYS := [KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6]


## Ctrl+Alt+数字的入口。修饰键判定刻意写成**全等匹配**（Ctrl+Alt 按下、Shift/Meta 未按）：
## 只判 `ctrl_pressed and alt_pressed` 会把 Ctrl+Shift+Alt+数字 也吃掉，那是别人的组合。
func _handle_domain_visibility_editor_input(event: InputEvent) -> bool:
	if not (event is InputEventKey):
		return false
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return false
	if not (key.ctrl_pressed and key.alt_pressed) or key.shift_pressed or key.meta_pressed:
		return false
	return _handle_domain_visibility_shortcut(key.keycode)


## Ctrl+Alt+1..6：逐个翻转体素域的显示。
##   1 AutoObject   2 SVTile   3 Anchor   4 SV(SceneSV)   5 TargetSV   6 Brush
##
## ⚠ 槽位顺序**直接读** `VOXEL_DOMAIN_BINDINGS` 的下标，这里刻意不另立一张「键 → 域」表：
## 那张表一旦与合同表错位，表现是"按 3 却切了别的域"这种没有报错的错。域增删改序时
## 只改合同表，快捷键跟着走；槽位多于域时按下即无操作（下面的 size 判据）。
func _handle_domain_visibility_shortcut(keycode: int) -> bool:
	var slot: int = DOMAIN_VISIBILITY_SHORTCUT_KEYS.find(keycode)
	if slot < 0:
		return false
	var bindings: Array = SPAEditorContract.VOXEL_DOMAIN_BINDINGS
	if slot >= bindings.size():
		return false
	var binding: Dictionary = bindings[slot]
	var display_key := str(binding.get("display_key", ""))
	var domain_label := str(binding.get("domain_label", display_key))
	var volume_node := _volume_for_display_key(display_key)
	if volume_node == null:
		# 组合键**已被认领**（返回 true）：这里放行会让 Ctrl+Alt+数字 漏进编辑器，
		# 而成因是本域没建出来，不是"该键归别人"。
		push_warning("[ScenePlacementActor] Ctrl+Alt+%d：显示键 \"%s\"（%s）在 SPA/Volumes 下找不到对应域节点。" % [
			slot + 1, display_key, domain_label])
		return true
	# 真值取**节点自己那份**（`is_display_visible()` 读的是显示节点的 visible），
	# 不读 host 的记账位——两者不同步时按开关会出现"按一下没反应，按两下才动"。
	var next_visible := not volume_node.is_display_visible()
	set_volume_display(StringName(volume_node.name), next_visible)
	print("[SPA] Ctrl+Alt+%d  %s 显示 → %s" % [
		slot + 1, domain_label, "on" if next_visible else "off"])
	return true


## 按显示键取 SPA/Volumes 下的域节点。
## ⚠ 刻意不建第二张「显示键 → 卷名」映射表：每个 PickableDomain 自己回答 `display_key()`，
## 而节点名就是卷名（`set_volume_display()` 收的那个键），扫一遍孩子即可。
func _volume_for_display_key(display_key: String) -> PickableDomain:
	if display_key.is_empty():
		return null
	_ensure_owned_tree()
	if _volumes == null:
		return null
	for child in _volumes.get_children():
		if child is PickableDomain and (child as PickableDomain).display_key() == display_key:
			return child as PickableDomain
	return null


## 借用交互宿主（SPA 装配并拥有它；借方不得释放或 reparent）。
## demo/HUD 需要"当前选中了哪个 anchor"时经它取——选中态的 SSOT 在那边。
func get_selection_host() -> SPASelectionHost:
	_ensure_owned_tree()
	return _selection_host


## 当前选中的 anchor 下标（-1 = 无选中）。转发到 SelectionHost，不在 SPA 存第二份。
func get_selected_anchor_index() -> int:
	var host := get_selection_host()
	return host.get_selected_anchor_index() if host != null else -1


## 视口边角的选中信息叠层文本。插件按**本名**探测并调用
## （`meshfill_editor_plugin.gd:245/246/254/256` 四处）。
##
## ⚠ 这里原本是一对方向倒置的转发：实现体挂在 `get_editor_overlay_text()` 上，而
## `get_selection_overlay_text()`（插件唯一认的名字）只是转发给它。旧名全仓零调用，
## 于是「真正的入口」反而是那个没人叫的名字。2026-08-17 并成一个。
func get_selection_overlay_text() -> String:
	return _selection_host.get_selection_overlay_text() if _selection_host != null else ""


func set_autoobject_pick_data(data: Dictionary) -> void:
	if _selection_host != null:
		_selection_host.set_autoobject_pick_data(data)


func refresh_volume_score_anchor_selection() -> Dictionary:
	return _selection_host.refresh_volume_score_anchor_selection() if _selection_host != null else {
		"ok": false,
		"reason": "selection_host_unavailable",
	}


func get_voxel_display_root(owner_key: String = "external") -> Node3D:
	return _selection_host.get_voxel_display_root(owner_key) if _selection_host != null else null


func attach_voxel_display_root(display_root: Node3D, owner_key: String = "external") -> Node3D:
	return _selection_host.attach_voxel_display_root(display_root, owner_key) if _selection_host != null else null


func register_voxel_display_node(display_key: String, node: Node3D, owner_key: String = "external") -> void:
	if _selection_host != null:
		_selection_host.register_voxel_display_node(display_key, node, owner_key)


# ⚠ 这里曾有 `voxel_display_effective_visible()`：转发给 host 的同名口，而那一口在
# 2026-08-11 已随「effective = 开关 AND 模式聚焦」这个前提一起删除（选择模式退役后与值
# 塌成单边）。它与下面的 `is_voxel_display_visible()` 已是逐字同义的两个公开名字，留着
# 只会让调用方以为"有效可见"和"开关开着"是两件事。查显示开关一律用下面这个。


func is_voxel_display_visible(display_key: String) -> bool:
	return _selection_host.is_voxel_display_visible(display_key) if _selection_host != null else false


## 按**显示键**翻某个域的显示（桥 / Inspector 复选框 / 外部调用的统一入口）。
##
## ⚠ 有对应卷就必须转给 `set_volume_display()`：不走它的话只有 host 的记账位被翻，
## 卷节点收不到通知、`rebuild_display()` 永远不跑（它首句就看卷自己的 `display_visible`），
## 表现是「开关翻了但什么都没画」，而默认隐藏的域更是**点了完全没反应**。
##
## ⚠ 这里原本是一张手写的三分支表（targetsv→TargetSV / sv→SceneSV / svtile→SVTile），
## 剩下三个显示键掉进下面的兜底、只翻记账位。这正是本函数注释在警告的那个坑，只是表
## 漏了一半——而漏项无法被发现：卷的 `display_visible` 静默陈旧，界面上零提示。
## 改成问 `_volume_for_display_key()`（每个 `PickableDomain` 自报 `display_key()`）之后
## 六个域一视同仁，新增域也不必再记得来这里补一行。
func set_voxel_display_visible(display_key: String, visible: bool) -> Dictionary:
	if _selection_host == null:
		return {"ok": false, "reason": "selection_host_unavailable"}
	var volume_node := _volume_for_display_key(display_key)
	if volume_node != null:
		# 卷名就是 set_volume_display 收的键（同款取法见 _handle_domain_visibility_shortcut）。
		return set_volume_display(StringName(volume_node.name), visible)
	# 没有卷的显示键（纯族外容器）：只有记账位与组下发这一条路。
	_selection_host.set_voxel_display_visible(display_key, visible)
	return {"ok": true, "display_key": display_key, "visible": visible}


func get_voxel_display_state() -> Dictionary:
	return _selection_host.get_voxel_display_state() if _selection_host != null else {}


func refresh_voxel_display_controls() -> void:
	if _selection_host != null:
		_selection_host.refresh_voxel_display_controls()


# ⚠ 这里曾有 `set_selection_mode()` / `get_selection_mode()` 两个门面。
# 用户 2026-08-07 裁定：**除 Mixed 外的选择模式整体退役，准入只看 `visible`**
# ⇒ 没有可切的模式，两个门面连同 host 的状态机一起删除。
# 想只看/只选某一个域，用 `set_voxel_display_visible()` 关掉其余域。


## ⚠ 首参旧为 `mode: int`（模式号）。模式号整体退役后传域名字符串
## （`SPAEditorContract.SELECTION_DOMAIN_*`："svtile" / "sv" / "targetsv" / "anchor"）。
func select_data_voxel(domain: String, x: int, y: int, z: int) -> Dictionary:
	return _selection_host.select_data_voxel(domain, x, y, z) if _selection_host != null else {
		"ok": false,
		"reason": "selection_host_unavailable",
	}


func set_volume_display(display_key: StringName, visible: bool) -> Dictionary:
	if display_key == &"TargetSV" and _target_sv != null:
		_target_sv.set_display_visible(visible)
	# ⚠ 这里曾有 BrushSV 特例分支（转发 addon 的 set_brush_visible）。2026-08-10 起
	# 笔刷显示在 BrushSVVolume，与 SceneSV / SVTile 一样走下面的 PickableDomain 通用分支。
	if _selection_host != null:
		# 显示键**问卷节点自己要**（`PickableDomain.display_key()` → 合同表）。
		#
		# ⚠ 这里原先是一张手写映射表，只映射了 TargetSV→"targetsv" 与 SceneSV→"sv"，
		# 其余 volume key 落进兜底分支被**原样**当显示键传下去。于是
		# `set_volume_display(&"BrushSV", …)`（编辑器工具栏的 Brush 按钮）每按一次都把
		# "BrushSV" 喂给 SelectionHost，而合法键是小写 "brush" —— 撞上未知键判死，
		# `push_error` + `assert` 各一次。表现是"按钮能切显示（当时那半边走 addon 的
		# set_brush_visible，2026-08-10 已随切换删除），但每次都报一个错"，
		# 且新增一个卷就会重犯一次。
		#
		# 现在四个卷都是 PickableDomain 子类，各自回答自己的显示键；
		# 没有显示键的卷（BlendSV：participates_in_picking() == false）返回空串，跳过即可。
		var volume_node := get_volume(display_key)
		if volume_node is PickableDomain:
			# ⚠ 节点自己那份显示必须一起翻，否则 "sv" / "svtile" / "brush" 的开关只改了
			# host 的记账位，域节点从不重建显示 —— 表现是「开关显示已打开，但什么都没画」。
			# TargetSV 在上面的分支里已经翻过自己那半边，这里跳过：
			# V2 刚把 TargetSVVoxels.visible 收敛成单写入方，别再加回一个。
			if display_key != &"TargetSV":
				(volume_node as PickableDomain).set_display_visible(visible)
			var selection_key := (volume_node as PickableDomain).display_key()
			if not selection_key.is_empty():
				_selection_host.set_voxel_display_visible(selection_key, visible)
	return {"ok": true, "display_key": display_key, "visible": visible}


func set_volume_display_channel(display_key: StringName, channel: int) -> Dictionary:
	if display_key != &"TargetSV" or _target_sv == null:
		return {"ok": false, "reason": "display_not_found"}
	_target_sv.switch_display_channel(channel)
	return {"ok": true, "display_key": display_key, "channel": channel}


func apply_brush_input(command: Dictionary) -> Dictionary:
	if _runtime == null:
		return {"ok": false, "reason": "runtime_not_ready"}
	var action := StringName(str(command.get("action", "write")))
	if action == &"clear":
		return clear_brush_sv()
	if action == &"write":
		if not command.has("records"):
			push_error("[ScenePlacementActor] apply_brush_input: write 命令缺少 \"records\"（command keys=%s）——当成空批会静默返回 ok，调用方以为写进去了。" % str(command.keys()))
			assert(false, "[ScenePlacementActor] apply_brush_input: write command missing records")
			return {"ok": false, "reason": "brush_command_missing_records"}
		# 旁路直写 BrushSV：可能覆盖笔刷已提交体素的取值，增量水位必须作废（失效条件 3）
		_invalidate_brush_flush_watermark()
		return _runtime.write_brush_sv_records(command["records"])
	return {"ok": false, "reason": "unsupported_brush_action"}


func clear_brush_sv(release_buffers: bool = false) -> Dictionary:
	# BrushSV GPU 内容与笔刷 CPU 体素状态都被清空，增量水位必须归零（失效条件 3）
	_invalidate_brush_flush_watermark()
	if _brush_volume != null and is_instance_valid(_brush_volume):
		# CPU 列表与显示都在卷节点（2026-08-10）；rebuild 走模板，空内容 ⇒ 丢弃显示节点。
		_brush_volume.clear_painted_voxels()
		_brush_volume.rebuild_display()
	if _runtime == null:
		return {"ok": false, "reason": "runtime_not_ready"}
	_runtime.clear_brush_sv(release_buffers)
	return {"ok": true, "revision": _runtime.get_brush_sv_revision(), "resident": not release_buffers}


## 惰性构建阶段底座。失败原因留在 _placement_env_error，供命令返回与 Inspector 文案复用。
func ensure_placement_env() -> bool:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	if _placement_env != null and _placement_env.is_ready():
		return true
	if not is_ready():
		_placement_env_error = "scene_placement_actor_not_ready:%s" % lifecycle_state_name()
		return false
	var registered := get_registered_descriptors()
	if registered.is_empty():
		_placement_env_error = "no_placement_assets"
		return false
	var env := PlacementStageEnvScript.make(self, {
		# 直接交原件：pivot 剥离副本层已随三变体一并退役（见类头 Placement Tuning 处的说明）。
		"descriptors": registered.duplicate(),
		"autoobject_capacity": autoobject_capacity,
		"prefilter_settings": _prefilter_settings(),
	})
	if env == null or not env.is_ready():
		_placement_env_error = "stage_env_make_failed:%s" % (
			str(env.fail_reason()) if env != null else "null_env")
		return false
	var sv_result: Dictionary = env.ensure_sv_committed()
	if not bool(sv_result.get("ok", false)):
		_placement_env_error = "sv_commit_failed:%s" % str(sv_result.get("reason", "?"))
		env.dispose()
		return false
	var target_result: Dictionary = env.ensure_target_ready()
	if not bool(target_result.get("ok", false)):
		_placement_env_error = "target_read_buffers_failed:%s" % str(target_result.get("reason", "?"))
		env.dispose()
		return false
	_placement_env = env
	_placement_env_error = ""
	return true


## 借用阶段底座（demo/测试用；所有权仍在 SPA，借方不得 dispose）。
func get_placement_stage_env() -> RefCounted:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	return _placement_env


func get_placement_env_error() -> String:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	return _placement_env_error


## 最近一次 Score 的细筛结果模型（借用引用，调用方不得就地改写）。
func get_last_score_model() -> Dictionary:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	return _score_model


## 按需物化结果模型的 CPU 锚点数组——点选 / 显示 / HUD / golden / 诊断的统一触发口。
##
## prefilter 与细筛全程只跑 GPU：prefilter 不回读 anchor 位置，模型带
## cpu_anchor_model_pending=true，锚点坐标还留在 GPU 常驻缓冲里。第一次调用时回读一次
## 并把补全后的模型写回 _score_model（pending 清成 false）。
##
## 失效条件不另造平行状态：缓存就是 _score_model 本身。每次 Anchors/Score 都整份替换它，
## 新模型自带 pending=true ⇒「GPU 结果换代 ⇒ CPU 模型作废」是同一次赋值的必然结果；
## 同一批结果内的重复调用只做一次 O(1) 标记判断。
func ensure_score_model_cpu_anchors() -> Dictionary:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	if bool(_score_model.get("cpu_anchor_model_pending", false)):
		_score_model = VolumeScoreFineSelectionScript.materialize_cpu_anchor_model(_score_model)
	return _score_model


# ---- Anchor 选中记录（数据侧）------------------------------------------------
#
# ⚠ 职责边界：**记录内容归 SPA，交互态归 SPASelectionHost。**
# 下面这些全部由 _score_model + 已注册资产推导，与"当前选中了谁"无关——所以
# 一律以 anchor_index / topk_index 入参，SPA 自己不持选中态。Host 只需要知道
# "选中了哪个下标"和"怎么画"，不必懂 FineSelection 的结果模型结构。
#
# 计划 §9 原本要求把 get_selected_anchor_record / 摘要 / tooltip 迁进 Host，那是阶段 1
# 之前定的——当时评分模型还在 provider 手里。模型归 SPA 之后照做等于让一个展示组件
# 反过来去解析评分模型。（用户裁定，2026-08-04）

## 展示用资产视图：[{name, mesh}]，顺序与 registry / 模型的 asset_index 对齐。
## topk 文案要名字，胜出物体包围盒要 mesh AABB，两者共用这一份。
func _anchor_asset_views() -> Array:
	var views: Array = []
	for descriptor in get_registered_descriptors():
		if descriptor == null:
			views.append({"name": "Asset%d" % views.size(), "mesh": null})
			continue
		var asset_name := str(descriptor.asset_id)
		if asset_name.is_empty():
			asset_name = "Asset%d" % views.size()
		views.append({"name": asset_name, "mesh": descriptor.get_mesh()})
	return views


func _anchor_asset_names() -> Array:
	var names: Array = []
	for view in _anchor_asset_views():
		names.append(str((view as Dictionary).get("name", "?")))
	return names


## 是否已评分（有分数，不只是有锚点）。
func is_scored() -> bool:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	return bool(_score_model.get("ok", false))


## 当前可选锚点数（会按需物化 CPU 锚点数组——调用方是显示/点选，本就需要坐标）。
func get_anchor_count() -> int:
	ensure_score_model_cpu_anchors()
	return int(_score_model.get("anchor_count", 0))


## 指定锚点的 Top-K 条目（按分数序）。
## ⚠ 没有"当前第几条"的高亮：滚轮切 Top-K 已整体退役（实际没人用），
## 随之作废的还有 selected 标记与 §7.1/§7.3 的 `_topk_slice`。列表本身照常显示。
func get_anchor_topk_entries(anchor_index: int, limit: int = 4) -> Array[Dictionary]:
	ensure_score_model_cpu_anchors()
	return VolumeScoreFineSelectionScript.topk_entries(
		_score_model, anchor_index, maxi(limit, 1), _anchor_asset_names(), rotation_slots)


## 胜出物体的定向包围盒（SelectionHost 据此画 ANCHOR_SAMPLE_BOUNDS 红框）。
func get_anchor_sample_bounds(anchor_index: int) -> Dictionary:
	ensure_score_model_cpu_anchors()
	var placement := VolumeScoreFineSelectionScript.winner_placement_transform(
		_score_model, anchor_index, _anchor_asset_views(), rotation_slots)
	if placement.is_empty():
		return {}
	var aabb: AABB = placement.aabb
	var transform: Transform3D = placement.transform
	var obb_size: Vector3 = aabb.size * float(placement.fit_scale)
	var obb_center: Vector3 = transform * (aabb.position + aabb.size * 0.5)
	return {
		"has_obb": true,
		"obb_center": obb_center,
		"obb_size": obb_size,
		"obb_yaw": float(placement.yaw),
		"aabb": AABB(obb_center - obb_size * 0.5, obb_size),
	}


## Inspector 一行摘要。
func get_anchor_summary_text(anchor_index: int, limit: int = 4) -> String:
	if not is_scored():
		return "Anchor scores: run Score"
	if anchor_index < 0:
		return "Anchor scores: select an anchor"
	var parts: Array[String] = ["Anchor #%d" % anchor_index]
	for entry in get_anchor_topk_entries(anchor_index, limit):
		var score := float(entry.get("score", -INF))
		var score_text := "%.2f" % score if score > -1.0e20 else "n/a"
		var suffix := "" if bool(entry.get("valid", false)) else " invalid"
		parts.append("%s %s%s" % [str(entry.get("asset_name", "?")), score_text, suffix])
	return " | ".join(parts)


## 展开诊断文本（编辑器 tooltip / HUD）。
func get_anchor_tooltip_text(anchor_index: int, limit: int = 4) -> String:
	if not is_scored():
		return "Selected anchor: run Score first"
	if anchor_index < 0:
		return "Selected anchor: click an anchor"
	var voxels: Array = _score_model.get("anchor_voxels", [])
	var voxel: Vector3i = voxels[anchor_index] if anchor_index >= 0 and anchor_index < voxels.size() \
		else Vector3i(-1, -1, -1)
	var lines: Array[String] = ["Selected anchor #%d voxel=%s top-%d:" % [
		anchor_index, str(voxel), maxi(limit, 1)]]
	var entries := get_anchor_topk_entries(anchor_index, limit)
	if entries.is_empty():
		lines.append("  (no score entries)")
		return "\n".join(lines)
	for entry in entries:
		var score := float(entry.get("score", -INF))
		var score_text := "%.3f" % score if score > -1.0e20 else "n/a"
		lines.append("  %s %s" % [str(entry.get("asset_name", "?")), score_text])
	return "\n".join(lines)


## SelectionHost 消费的完整选中记录。未评分态（Anchors-only）也返回记录——
## 各场景统一为"有锚点即可点"：位置/体素坐标先给，Top-K 与红框在评分后自动补全。
func get_anchor_selection_record(anchor_index: int, limit: int = 4) -> Dictionary:
	ensure_score_model_cpu_anchors()
	var world_positions: PackedVector3Array = _score_model.get(
		"anchor_world_positions", PackedVector3Array())
	if anchor_index < 0 or anchor_index >= world_positions.size():
		return {}
	var voxels: Array = _score_model.get("anchor_voxels", [])
	var record := {
		"domain": SPAEditorContract.SELECTION_DOMAIN_ANCHOR,
		"geometry": SPAEditorContract.SELECTION_GEOMETRY_VOLUME_SCORE_ANCHOR,
		"id": "volume_score_anchor:%d" % anchor_index,
		"anchor_index": anchor_index,
		"voxel_coord": voxels[anchor_index] if anchor_index < voxels.size() else Vector3i(-1, -1, -1),
		"world_position": world_positions[anchor_index],
		"marker_size": _score_model.get("voxel_size", Vector3.ONE),
		"topk": get_anchor_topk_entries(anchor_index, limit),
		"summary": get_anchor_summary_text(anchor_index, limit),
		"tooltip": get_anchor_tooltip_text(anchor_index, limit),
	}
	var sample_bounds := get_anchor_sample_bounds(anchor_index)
	if not sample_bounds.is_empty():
		record["sample_bounds"] = sample_bounds
	return record


## prefilter 的五键设置。热路径不开 debug_read_anchors：GPU 细筛只吃 handoff 的常驻 RID，
## 需要 CPU 锚点坐标的消费方经 FineSelection.materialize_cpu_anchor_model 按需取一次。
func _prefilter_settings() -> Dictionary:
	return {
		"min_target_interest": min_target_interest,
		"anchor_vertical_stride": anchor_vertical_stride,
		"min_prefilter_score": min_prefilter_score,
		"debug_read_anchors": false,
		"decode_anchor_dictionaries": false,
	}


## 本轮评分的区域清单：prefilter_tile_rect 非空 = 单区域；空（默认）= 单次全图。
func _score_region_rects() -> Array:
	if prefilter_tile_rect.size.x > 0 and prefilter_tile_rect.size.y > 0:
		return [prefilter_tile_rect]
	return full_map_region_rects()


## 全图区域（golden 与交互空导出共用口径）。collect 在地形高度采样目标体积发锚，
## anchor_vertical_stride 决定地表之上再叠几层（步长 0 = 只采地形那一格，此时
## 256x256 网格上限恰为列数 65536）；步长 ≥ 1 时上限由列数 × 层数决定，
## 罩它的是 ANCHOR_CAPACITY=131072。
func full_map_region_rects() -> Array:
	if _placement_env == null:
		return []
	var sv: Dictionary = _placement_env.get_committed_sv_metadata()
	if sv.is_empty():
		sv = _placement_env.ensure_sv_committed().get("sv", {})
	var tile_grid: Vector3i = sv.get("tile_grid_size", Vector3i.ZERO)
	if tile_grid.x <= 0 or tile_grid.z <= 0:
		return []
	return [Rect2i(0, 0, tile_grid.x, tile_grid.z)]


## 把本轮评分区域标脏，保证 prefilter 重算时 collect 覆盖到它（XZ tile 坐标，全 Y 层）。
## prefilter 只消费 SVTile 脏工作清单；目标加载时的一次 mark_all 被首轮消费清空后，
## 不补标的重算只看得到最近被盖章的 tile —— 锚点覆盖会随轮次塌缩到已放置区
## （2026-08-10 实发：目标 81% 兴趣在 z≥64，锚点却全部收在 z<64）。
## benchmark 的同款语义住在 volume_score_demo._mark_prefilter_region_dirty。
## ensure_prefilter 缓存命中时标记只是滞留待消费，不强制重算。
func _mark_score_region_dirty(region_rect: Rect2i) -> void:
	if region_rect.size.x <= 0 or region_rect.size.y <= 0:
		return
	var tile_size := SceneVoxelTileStoreScript.scene_voxel_tile_size()
	mark_svtile_bounds_dirty(
		Vector3i(region_rect.position.x * tile_size.x, 0, region_rect.position.y * tile_size.z),
		Vector3i(
			mini((region_rect.position.x + region_rect.size.x) * tile_size.x, grid_size.x),
			grid_size.y,
			mini((region_rect.position.y + region_rect.size.y) * tile_size.z, grid_size.z)),
		{"routing": true, "scoring": true},
		{"id": "score_region", "source_id": "score_region"})


## 单区域 S6：标脏 + ensure_prefilter。Anchors 与 Score 的逐区域循环共用这一段（此前各写
## 一遍，且失败时把 env 的详细 reason 丢成字面量 "prefilter_failed"——现在原样透传）。
## env 缓存命中时标脏只是滞留待消费，语义见 _mark_score_region_dirty。
func _region_prefilter(region_rect: Rect2i) -> Dictionary:
	_mark_score_region_dirty(region_rect)
	var prefilter: Dictionary = _placement_env.ensure_prefilter(_prefilter_settings())
	if not bool(prefilter.get("ok", false)):
		return {"ok": false, "reason": str(prefilter.get("reason", "prefilter_failed"))}
	return prefilter


## Anchors：只推进到 S6 并发布常驻 anchor handoff，不评分。
## anchors-only 模型（有锚点无分数，ok=false）供显示消费；排序与 Score 同口径。
func run_anchors(_settings := {}) -> Dictionary:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	if not ensure_placement_env():
		return {"ok": false, "reason": _placement_env_error}
	var region_rects := _score_region_rects()
	if region_rects.is_empty():
		return {"ok": false, "reason": "no_score_regions"}
	var region_models: Array = []
	for _rect in region_rects:
		var prefilter := _region_prefilter(_rect)
		if not bool(prefilter.get("ok", false)):
			return prefilter
		var handoff: Dictionary = prefilter.get("anchor_candidate_handoff", {})
		# Anchors 命令本身就是"把锚点拿出来"，是真正需要 CPU 锚点坐标的消费方：
		# 在这里按需读一次常驻缓冲，而不是让 prefilter 热路径顺带回读。
		var anchors_packed := VolumeScoreFineSelectionScript.read_resident_anchors_packed(
			get_rendering_device(), handoff, -1)
		var sv: Dictionary = _placement_env.get_committed_sv_metadata()
		region_models.append(VolumeScoreFineSelectionScript.anchors_only_model(
			anchors_packed,
			int(handoff.get("topk", 4)),
			get_asset_count(),
			sv.get("grid_size", Vector3i.ZERO),
			sv.get("voxel_size", Vector3.ONE),
			sv.get("grid_origin", Vector3.ZERO),
			_placement_env.get_terrain_height_field()))
	var model: Dictionary = region_models[0] if region_models.size() == 1 \
		else VolumeScoreFineSelectionScript.merge_models(region_models)
	if region_models.size() > 1:
		model["ok"] = false
		model["reason"] = "anchors_only"
	_score_model = model
	var anchor_count := int(model.get("anchor_count", 0))
	# ⚠ 这里**不带** anchor_candidate_handoff：交接已经由内层 run_autoobject_prefilter
	# 发布过了，再塞一份回去只会让 _anchor_revision 为同一批锚点白涨一次。
	return _publish_anchor_result({
		"ok": anchor_count > 0,
		"anchors": anchor_count,
		"scored": false,
	})


## Score：S6 常驻 anchor handoff + BlendSV 工作对 → VolumeScoreFineSelection 细筛。
## settings 键（全部可选）：
##   region_rects: Array                  — 覆盖默认区域口径（golden 用它强制全图）
##   full_candidate_diagnostics: bool     — 额外回读整片候选（诊断/golden）
##   allow_model_cache: bool              — 命中 score cache key 时跳过重算（默认 true）
##   profile_timing: bool                 — 打开 pass 间 submit+sync 分段计时
func run_score(settings := {}) -> Dictionary:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	if not ensure_placement_env():
		return {"ok": false, "reason": _placement_env_error}
	var options: Dictionary = settings if settings is Dictionary else {}
	var full_diagnostics := bool(options.get("full_candidate_diagnostics", false))
	var allow_cache := bool(options.get("allow_model_cache", true))
	var profile_timing := bool(options.get("profile_timing", false))
	var requested_regions: Array = options.get("region_rects", [])
	var region_rects: Array = requested_regions if not requested_regions.is_empty() \
		else _score_region_rects()
	if region_rects.is_empty():
		return {"ok": false, "reason": "no_score_regions"}
	var cache_key: Dictionary = _placement_env.build_score_cache_key(
		region_rects, _score_cache_settings(full_diagnostics))
	var cache_hit := allow_cache \
		and not profile_timing \
		and bool(_score_model.get("ok", false)) \
		and not cache_key.is_empty() \
		and PlacementStageEnvScript.score_cache_key_matches(_score_cache_key, cache_key)
	if cache_hit:
		# 命中即复用上一轮的模型与仍然常驻的 Fine 交接；revision 不动。
		return _score_status(true, {"score_cache_hit": true, "fine_dispatch_count": 0})
	var scored := _run_fine_scoring(region_rects, full_diagnostics, profile_timing)
	if not bool(scored.get("ok", false)):
		_score_model = {}
		_score_cache_key = {}
		return scored
	_score_model = scored
	_score_cache_key = cache_key
	_publish_score_result({
		"ok": true,
		"fine_score_handoff": scored.get("fine_score_handoff", {}),
	})
	return _score_status(true, {"score_cache_hit": false, "fine_dispatch_count": 1})


## 逐区域 prefilter + 细筛；多区域经 merge_models 合并为全覆盖确定性模型。
func _run_fine_scoring(
	region_rects: Array, full_candidate_diagnostics: bool, profile_timing: bool
) -> Dictionary:
	if _score_runner == null:
		_score_runner = VolumeScoreFineSelectionScript.new()
	var sv: Dictionary = _placement_env.get_committed_sv_metadata()
	var descriptors: Array = _placement_env.get_descriptors()
	var profile_ids: Array = _placement_env.get_profile_ids()
	var committed_resident_fields := {
		"complexity": get_svtile_gpu_buffer(
			SceneVoxelTileStoreScript.SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER),
		"collision": get_svtile_gpu_buffer(
			SceneVoxelTileStoreScript.SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER),
	}
	var region_models: Array = []
	for _rect in region_rects:
		var prefilter := _region_prefilter(_rect)
		if not bool(prefilter.get("ok", false)):
			return prefilter
		var region_model: Dictionary = _score_runner.run({
			"spa": self,
			"committer": _sv_committer,
			"sv": sv,
			"target_read_buffers": _placement_env.ensure_target_ready(),
			"prefilter_result": prefilter,
			"committed_resident_fields": committed_resident_fields,
			"descriptors": descriptors,
			"profile_ids": profile_ids,
			"terrain_height": _placement_env.get_terrain_height_field(),
			"settings": {
				"rotation_slots": rotation_slots,
				"profile_score_timing": profile_timing,
				"full_candidate_diagnostics": full_candidate_diagnostics,
				# Place/Score 同门限契约：预览排名与提交裁决用同一套物理可行性门
				# （否则 Score 显示的胜者在 Place 被门拒，预览失真）。
				"collision_limit": PLACE_PIPELINE_COMMON["collision_limit"],
				"clearance_limit": PLACE_PIPELINE_COMMON["clearance_limit"],
			},
		})
		if not bool(region_model.get("ok", false)):
			return {
				"ok": false,
				"reason": "fine_selection_failed:%s" % str(region_model.get("reason", "?")),
			}
		region_models.append(region_model)
	if region_models.size() == 1:
		return region_models[0]
	return VolumeScoreFineSelectionScript.merge_models(region_models)


## score cache key 的设置分量（与 Place 门限同源，改任一项都必须让上一轮结果失效）。
func _score_cache_settings(full_candidate_diagnostics: bool) -> Dictionary:
	return {
		"rotation_slots": rotation_slots,
		"topk": 4,
		"min_target_interest": min_target_interest,
		"anchor_vertical_stride": anchor_vertical_stride,
		"min_prefilter_score": min_prefilter_score,
		"collision_limit": PLACE_PIPELINE_COMMON["collision_limit"],
		"clearance_limit": PLACE_PIPELINE_COMMON["clearance_limit"],
		"full_candidate_diagnostics": full_candidate_diagnostics,
		# 评分匹配参数是盘上文件：改了它必须重评，否则调参后点 Score 会静默命中旧结果。
		"score_match_config_mtime": FileAccess.get_modified_time("res://score_match_config.cfg"),
	}


func _score_status(require_scored: bool, extra: Dictionary = {}) -> Dictionary:
	# ⚠ 别直接用 _score_model.anchor_count：细筛全程只跑 GPU，模型的 CPU 锚点数组要等
	# ensure_score_model_cpu_anchors() 才物化，在那之前 anchor_count 恒为 0——Score 会
	# 报「45598 个锚点评分成功」却 anchors=0 / ok=false。
	# 活锚点数取 Fine 交接自述的 live_anchor_count：VPG 本来就读过那 4 字节 anchor_count
	# 缓冲，这里零额外回读，也不会为了报个数把整片锚点拉回 CPU。
	var anchor_count := int(_fine_score_handoff.get("live_anchor_count", -1))
	if anchor_count < 0:
		anchor_count = int(_score_model.get("anchor_count", 0))
	var scored := bool(_score_model.get("ok", false))
	var status := {
		"ok": anchor_count > 0 and (scored or not require_scored),
		"anchors": anchor_count,
		"scored": scored,
		"asset_count": get_asset_count(),
		"score_ms": float(_score_model.get("elapsed_ms", 0.0)),
	}
	for key in extra:
		status[key] = extra[key]
	return status


## Place：S5→S9 全链，多批直到放满。
## ⚠ Place 改写 committed SV：再次 Score 会在新场上重评（env 缓存已随会话失效）。
## 每批先保留各 Anchor 的最佳 Fine 候选，再经迭代贪心得分 NMS 仲裁 Anchor 间冲突（高分优先
## 存活，与串行贪心等价）并提交至多 place_result_capacity 个；上一批盖章的 collision 使下一批候选在已放置足迹上
## invalid（collision_limit 门）⇒ 批间自然互斥。收敛判据分「格点门开/关」两套，
## 写在循环末尾——⚠ 开着格点门时**单批零产出不等于放满**，别照搬旧判据。
func run_place(_settings := {}) -> Dictionary:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	if not ensure_placement_env():
		return _publish_place_result({"ok": false, "reason": _placement_env_error})
	var readiness := get_place_pipeline_readiness()
	if not bool(readiness.get("ok", false)):
		return _publish_place_result({
			"ok": false,
			"reason": "place_resources_not_ready:%s" % str(readiness.get("reason", "unknown")),
		})
	var common := PLACE_PIPELINE_COMMON.duplicate(true)
	common["rotation_slots"] = rotation_slots
	# prefilter 门限三键与 Anchors/Score 同一来源（_prefilter_settings），顺带显式带上
	# debug_read_anchors=false：_apply_prefilter_settings 对该键是「缺席即沿用实例旧值」，
	# 不带它，上一次诊断调用留在实例上的回读开关会悄悄漏进 Place。
	common.merge(_prefilter_settings())
	common["result_capacity"] = place_result_capacity
	common["min_distance_voxels"] = place_min_distance_voxels
	common["anchor_interval_voxels"] = place_anchor_interval_voxels
	# 会话首批的锚点池必须是全量的：collect 只在**脏 tile** 上发锚，而上一次 Anchors/Score
	# 已经把脏清单消费清空了（prefilter 成功即 finalize_consumed_dirty_tiles）。不在这里补
	# 一次全区标脏，首批就会在一份近乎空的脏清单上采集，整个会话都跑在残缺的池子上。
	# ⚠ 只标**一次**，不进批循环：批间复用常驻锚点池（PlacementStageEnv 的
	# reuse_resident_anchors），逐批标脏既没必要，还会白付一整轮全图 collect。
	for _rect in _score_region_rects():
		_mark_score_region_dirty(_rect)
	var session: Dictionary = _placement_env.begin_place_session(common)
	if not bool(session.get("ok", false)):
		return _publish_place_result({
			"ok": false,
			"reason": str(session.get("reason", "place_session_begin_failed")),
		})
	var spawned_total := 0
	var batches := 0
	var batch_reports: Array = []
	# 循环靠收敛判据自然退出（判据分两套，见循环末尾）；跑满批预算属于**没收敛**，
	# 必须报出来——静默截断正是「点一次 Place 只铺一部分」那类问题的温床。
	var converged := false
	# 批预算：格点门开着时**下界抬到相位空间大小**（interval²），因为相位走法是批号的
	# 纯函数（PlacementStageEnv 每次 begin_place_session 都把批号清 0），Place 之间不留
	# 任何游标 ⇒ 每一轮都从同一个相位重走。于是「本轮能覆盖多少格位」完全等于「本轮跑了
	# 多少批」：预算 32 < 144 就意味着有 112 个格位**永远**没机会参与评分，而且再点几次
	# Place 也拿不回来——第二轮吃的还是第一轮已经填满的那 12 个相位（实测：2923 + 0 + 0，
	# 同场把预算给到 144 是一次 4713）。
	# 这样每一轮都是同一个纯函数 (锚点, 当前 SceneSV) → 放置：本轮尽力填满，
	# 下一轮重跑得 0 才是「真的满了」而不是「没走到」。
	var batch_budget := maxi(place_max_batches, 1)
	if place_anchor_interval_voxels > 0:
		batch_budget = maxi(batch_budget, place_anchor_interval_voxels * place_anchor_interval_voxels)
	# 容量帽基数问 runtime 的 id 分配器（零 GPU 回读）。这是 autoobject 自己的记账域
	# （槽位用量 vs autoobject_capacity），与互斥逻辑无关；host 不再自记 id
	# （2026-08-18 用户裁决：依赖项一致，host 不留副本）。
	var placement_gpu_runtime = get_gpu_runtime()
	var placed_before_round := int(placement_gpu_runtime.get_allocated_object_count()) if placement_gpu_runtime != null else 0
	for batch in range(batch_budget):
		if placed_before_round + spawned_total + place_result_capacity > autoobject_capacity:
			push_warning("[ScenePlacementActor] Place 停在容量帽：累计 %d 接近 runtime 容量 %d" % [
				placed_before_round + spawned_total, autoobject_capacity])
			break
		var batch_total_t0_usec := Time.get_ticks_usec()
		# 轮内批间原点间距靠会话作用域的余隙场（上批接受结果已由 paint pass 画进去）；
		# 跨轮互斥由 fine score 在上一轮盖章后的 SV 上重算（与 autoobject 无关）
		var result: Dictionary = _placement_env.run_place_session_batch()
		if not bool(result.get("ok", false)):
			var phase := str(result.get("phase", result.get("reason", "pipeline_failed")))
			if batches == 0:
				_placement_env.end_place_session()
				push_warning("[ScenePlacementActor] Place 失败：phase=%s" % phase)
				return _publish_place_result({"ok": false, "reason": phase})
			push_warning("[ScenePlacementActor] Place 批 %d 失败（phase=%s）——保留已完成批次" % [batch, phase])
			break
		var host_phase_t0_usec := Time.get_ticks_usec()
		var host_batch_phases_ms := {}
		var placement_result: Dictionary = result.get("placement_result", {})
		var dirty_delta_flush: Dictionary = result.get("runtime_dirty_delta_flush_result", {})
		var session_detail: Dictionary = result.get("place_session", {})
		var fine_contract: Dictionary = placement_result.get("anchor_fine_contract", {})
		var writeback: Dictionary = placement_result.get("gpu_autoobject_runtime_writeback", {})
		var batch_spawned := int(writeback.get("spawned_count", 0))
		batches += 1
		spawned_total += batch_spawned
		host_batch_phases_ms["result_extract"] = float(Time.get_ticks_usec() - host_phase_t0_usec) / 1000.0
		host_phase_t0_usec = Time.get_ticks_usec()
		# VPG 的 GPU state-chain stamp 已经**原位**把本批盖章写进常驻场对了，但瓦片摘要要靠
		# 单独一趟 reduce。管线里唯一会触发它的 `_commit_accepted_placements()` 被
		# `placement_result.get("ok", false)` 挡着，而 VPG 成功变体按 ReportSchema 的约定
		# **刻意不发 ok**（report_schema.gd 原话：「成功变体故意不发 ok…勿补发」）⇒ 门恒 false。
		# 不在这里补一趟，所有瓦片恒报 scene_voxel_count == 0，SceneSV/SVTile 的显示与点选
		# 会一个体素都画不出来，**且零提示**。
		#
		# ⚠ 放**批内**而不是循环外：中途某批失败 break 时，前面成功的批次已经刷完；
		# 批间读场的调试/显示看到的也是当批之后的状态。
		# 代价是每批一次 submit+fence（ComputePassChain 默认 sync）——批数很大时可改挪到
		# 循环外，代价是批间看到旧摘要。
		var summary_refresh: Dictionary = {"ok": false, "reason": "scene_voxel_committer_unavailable"}
		if _sv_committer != null:
			summary_refresh = _sv_committer.refresh_scene_voxel_tile_summaries("place_batch_%d" % batch)
		if not bool(summary_refresh.get("ok", false)):
			# push_warning 而非 push_error：committer 已就具体成因报过错，这里只补「哪一批」。
			# Place 本身仍算成功——对象确实放下去了，只是这批在显示/点选里看不见。
			push_warning("[ScenePlacementActor] Place 批 %d 的瓦片摘要刷新失败（reason=%s）——本批盖章内容在 SceneSV/SVTile 的显示与点选里不可见" % [
				batch, str(summary_refresh.get("reason", "unknown"))])
		host_batch_phases_ms["sv_tile_summary_refresh"] = float(Time.get_ticks_usec() - host_phase_t0_usec) / 1000.0
		host_batch_phases_ms["total"] = float(host_batch_phases_ms.get("result_extract", 0.0)) + float(host_batch_phases_ms.get("sv_tile_summary_refresh", 0.0))
		# 逐批可观测性（benchmark_score_timing 聚合这几个键）。批循环随 Place 一起从 demo
		# 迁到这里，报告键名保持不变——键名一变，聚合侧读到的就是空。
		# demo_phases_ms 沿用旧名：它现在装的是 SPA 侧的编排分段，改名要同步改 benchmark。
		batch_reports.append({
			"batch_index": batch,
			"wall_ms": float(session_detail.get("wall_usec", 0)) / 1000.0,
			"environment_wall_ms": float(session_detail.get("environment_wall_usec", 0)) / 1000.0,
			"total_wall_ms": float(Time.get_ticks_usec() - batch_total_t0_usec) / 1000.0,
			"spawned": batch_spawned,
			# 本批被接受放置的总得分。GPU 侧早就算好也回读了（placement_result_score_sum.glsl），
			# 只是一直没转发出来。reduce 的容量天花板改成按得分裁剪之后，这是**唯一**能看出
			# 「留下的是不是高分那批」的量：条数相同而总分更高，就说明裁剪口径生效了。
			"score_sum": float(placement_result.get("placement_score_sum", 0.0)),
			"score_valid_count": int(placement_result.get("placement_valid_count", 0)),
			"anchor_count": int((result.get("prefilter_result", {}) as Dictionary).get("anchor_count", 0)),
			"target_cache_hit": bool(session_detail.get("target_cache_hit", false)),
			"target_revision": int(session_detail.get("target_revision", -1)),
			# NMS 实测轮数/未定型残留。预算耗尽 = 本批候选被 compact 静默丢弃，
			# 除了这里没有第二处能看出来。
			"nms_telemetry": fine_contract.get("reduce_nms_telemetry", {}),
			"incremental_fine_active": bool(fine_contract.get("incremental_fine_active", false)),
			"incremental_fine_cache_hit": bool(fine_contract.get("incremental_fine_cache_hit", false)),
			"incremental_fine_force_full": bool(fine_contract.get("incremental_fine_force_full", false)),
			"resident_pipeline_phases_ms": result.get("resident_pipeline_phases_ms", {}),
			"environment_phases_ms": session_detail.get("orchestration_phases_ms", {}),
			"demo_phases_ms": host_batch_phases_ms,
			# 摘要刷新的成败必须逐批可见：失败时 Place 仍报 ok，唯一的差别就是显示/点选
			# 看不到这批内容——没有这个键就只能靠翻控制台警告。
			"sv_tile_summary_refresh_ok": bool(summary_refresh.get("ok", false)),
			# tile object_ref 更新 pass（scene_voxel_tile_object_ref_update.glsl）的逐批实况。
			# 这条链此前被 run_placement_pipeline 里一道恒 false 的 `placement_result.ok` 门
			# 挡着、从未跑过（VPG 成功变体刻意不发 ok），症状是「放了几千个 autoobject，
			# SVTile 热力图 0 occupied tile」——不逐批报出来，下次坏掉照样零提示。
			# `placement_result_has_ok` 是那道门的直接证据：成功变体恒 false。
			"object_ref_update_pass_dispatched": bool(dirty_delta_flush.get(
				"resident_gpu_dirty_delta_update_pass", false)),
			"object_ref_update_pass_blocked_reason": str(dirty_delta_flush.get(
				"resident_gpu_dirty_delta_update_pass_blocked_reason", "unreported")),
			"object_ref_update_dirty_delta_count": int(dirty_delta_flush.get("dirty_delta_count", 0)),
			"object_ref_update_inserted_slot_count": int(dirty_delta_flush.get("object_ref_inserted_slot_count", 0)),
			"object_ref_update_overflow_count": int(dirty_delta_flush.get("object_ref_overflow_count", 0)),
			"placement_result_has_ok": placement_result.has("ok"),
			"timing": placement_result.get("score_timing_profile", {}),
		})
		# ⚠ 这里曾是 `batch_spawned < place_result_capacity`，即拿「这批少于容量」当
		# 「没东西可放了」的代理指标。它成立的前提是每批的产出只受容量限制——而实际每轮的
		# 候选供给受脏清单覆盖、间距种子、冲突消解共同限制，实测一批只出 82 个（容量 1024）。
		# 于是循环恒定跑一批就退出，`place_max_batches` 那个上限从来没机会生效，
		# 表现是「点一次 Place 只铺出一小片，得点很多次」。
		#
		# ⚠⚠ 格点门（place_anchor_interval_voxels > 0）把「这批一个都没产出」也一起毁了：
		# 每批只放落在 `phase + k*interval` 格点上的 anchor，某批产出 0 **只说明那一个相位
		# 的格点恰好被已放置物挡光了**，换个相位照样有得放，跟「放满」毫无关系。
		# 实测事故：批 1 产出 0 就退出，总数只有 42 个 / 2 批（同场关掉格点门是 3878 个 / 7 批）。
		# 所以判据必须按门的开关分两套：
		if place_anchor_interval_voxels <= 0:
			# 门关闭 = 旧行为（全体候选 + 一趟保守仲裁）：候选池是全量的，
			# 这批一个都没产出就是真被间距/占用耗尽了，可以立刻退出。
			if batch_spawned <= 0:
				converged = true
				break
		else:
			# 门开启：唯一的收敛判据是**相位空间走完**。
			# PlacementStageEnv.run_place_session_batch 用「与 interval² 互质的步长做模乘」
			# 推进相位，是完全置换 ⇒ interval² 批之内不重不漏地走完全部格位。走完就等于每个
			# 格点都试过了，再跑只是重复相位。
			#
			# ⚠ 这里曾并列着第二条「连续 maxi(4, interval) 批零产出即收敛」。它在多轮场景下
			# 是错的：一串零产出只证明**这几个相位**满了，证明不了其余相位也满——而 Place
			# 之间不留相位游标，第二次点 Place 必然从头重走那几个已经填满的相位，于是恒定
			# 12 批空转后「收敛」退出，剩下的 112 个格位一次都没被访问（实测 2923 + 0 + 0）。
			# 相位空间本来就是 interval² 的硬上界，删掉它不会变成 `while true`。
			if batches >= place_anchor_interval_voxels * place_anchor_interval_voxels:
				converged = true
				break
	if not converged and batches >= batch_budget:
		push_warning("[ScenePlacementActor] Place 跑满 %d 批仍未收敛（本次 spawned=%d）——还有候选没放完，调大 place_max_batches 再点一次。" % [
			batch_budget, spawned_total])
	_placement_env.end_place_session()
	# Place 改了 SceneSV ⇒ 评分 cache key/模型/交接作废——统一在 _publish_place_result
	# （本 return 与批循环里的逐批发布走同一出口，不在这里重复清）。
	return _publish_place_result({
		"ok": true,
		"spawned": spawned_total,
		"batches": batches,
		"total_placed": spawned_total,
		"placed_object_ids": get_placed_object_ids(),
		"batch_reports": batch_reports,
		"session": session,
	})


## 已放置对象 id 的只读视图（demo 渲染/回读用）。真相在 runtime 的 id 分配器
## （分配失败即归还，与旧 host 记账逐位同义）；host 不再留平行副本。
func get_placed_object_ids() -> Array[int]:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	var gpu_runtime = get_gpu_runtime()
	if gpu_runtime == null:
		return [] as Array[int]
	return gpu_runtime.get_allocated_object_ids()


## 复位 Place 关联的评分侧缓存（cache key、模型、Fine 交接）。
## 对象 id / 跨轮互斥不再有 host 累积表可清：id 真相在 runtime 分配器（reset_state 归还
## 全部 id），跨轮互斥在 fine score × 盖章后的 SV（清 SV 即清互斥），余隙场是会话作用域
## （首批自重建）。benchmark fixture 清场后仍要调它——剩下的职责是别让旧评分模型继续喂显示。
func reset_place_accumulation() -> void:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	_score_cache_key = {}
	_score_model = {}
	_invalidate_score_handoff()


## 把场清回「刚 init 完」的状态。四件事按依赖顺序做，任何一步失败都继续往下走并汇总
## 到返回值里——半清状态比全不清更难查，所以宁可尽力清完再报告哪一步没成。
##
## 1. GPU AutoObject 记录（reset_state：清光运行时记录，保留 buffer RID 与 RD）
## 2. 已盖章的 committed SceneSV（reset_empty_fixture_state：回到地形播种的初态）
## 3. Place 的跨批累积（对象 id / reduce 种子 / 评分 cache key）
## 4. anchor 与 score 交接换代 + 广播下游作废（provider 的 _assets / env / 显示）
##
## ⚠ **不动 BrushSV**：那是用户手绘的输入而非放置产物，一并清掉会是个意外。
## ⚠ 余隙场不需要单独清：它是 place session 作用域的，下一个会话首批重建零场；跨轮
##   互斥本就不靠它——fine score 在盖章后的 SV 上重算（清掉 SV 即清掉互斥来源）。
func clear_placement_state() -> Dictionary:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	var steps := {}

	var gpu_runtime = get_gpu_runtime()
	if gpu_runtime != null and gpu_runtime.has_method("reset_state"):
		steps["autoobject"] = gpu_runtime.call("reset_state")
	else:
		steps["autoobject"] = {"ok": false, "reason": "gpu_runtime_unavailable"}

	if _sv_committer != null:
		steps["scene_sv"] = _sv_committer.reset_empty_fixture_state()
	else:
		steps["scene_sv"] = {"ok": false, "reason": "committer_unavailable"}

	reset_place_accumulation()
	steps["accumulation"] = {"ok": true}

	# anchor 侧也要换代：只清累积而不推进 revision，下游会以为手里那份交接还有效。
	_anchor_revision += 1
	invalidate_score_cache(&"placement_state_cleared")
	# ⚠ 先走 get_volume_provider()：它带惰性注册兜底。只遍历 _providers 的话，provider 尚未
	# 注册时（用户还没跑过 Anchors/Score 就直接点清除）广播会一个都发不出去——数据清了、
	# 显示器没收到通知，表现就是"点了没反应"。
	var scored_provider := get_volume_provider(&"VolumeScore")
	var notified := 0
	for provider_key in _providers:
		var provider := _providers[provider_key] as Node
		if provider != null and is_instance_valid(provider) and provider.has_method("invalidate_asset_caches"):
			provider.call("invalidate_asset_caches")
			notified += 1
	if notified == 0 and scored_provider != null and scored_provider.has_method("invalidate_asset_caches"):
		scored_provider.call("invalidate_asset_caches")
		notified = 1
	steps["handoff"] = {"ok": true, "anchor_revision": _anchor_revision, "providers_notified": notified}

	var ok := bool(steps["autoobject"].get("ok", false)) and bool(steps["scene_sv"].get("ok", false))
	if not ok:
		push_warning("[ScenePlacementActor] Clear All 未完全成功：autoobject=%s scene_sv=%s" % [
			str(steps["autoobject"].get("reason", "ok")), str(steps["scene_sv"].get("reason", "ok"))])
	return {"ok": ok, "reason": "ok" if ok else "partial", "steps": steps}


## 评分状态失效的公开入口（资产表换代、grid 参数变化、rotation contract 变化、
## 外部改写 SceneSV 等）。评分 cache key 与 Fine 交接现在都归 SPA，一次清干净即可——
## 不再有需要转发的 provider 侧缓存。
func invalidate_score_cache(_reason: StringName, _dirty_tile_ids := []) -> void:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	_score_cache_key = {}
	_invalidate_score_handoff()


# Runtime query and command surface. Lifecycle and RenderingDevice attachment
# remain private to this scene node.
func is_initialized() -> bool: return _runtime != null and _runtime.is_initialized()
func get_rendering_device() -> RenderingDevice: return _runtime.get_rendering_device() if _runtime != null else (_sv_committer.get_rendering_device() if _sv_committer != null else null)
func get_scene_voxel_committer(): return _sv_committer
func get_gpu_runtime(): return _runtime.get_gpu_runtime() if _runtime != null else null
func owns_gpu_runtime() -> bool: return _runtime != null and _runtime.owns_gpu_runtime()
func set_autoobject_runtime_capacity(max_objects: int, recreate_owned_runtime: bool = false) -> void:
	autoobject_capacity = maxi(max_objects, 1)
	if _runtime != null: _runtime.set_autoobject_runtime_capacity(autoobject_capacity, recreate_owned_runtime)
func get_autoobject_runtime_capacity() -> int: return _runtime.get_autoobject_runtime_capacity() if _runtime != null else autoobject_capacity
func get_runtime_profile_container(): return _runtime.get_runtime_profile_container() if _runtime != null else null
func is_gpu_ready() -> bool: return is_ready() and _runtime != null and _runtime.is_gpu_ready()
func get_gpu_readiness_report() -> Dictionary:
	var result := _runtime.get_gpu_readiness_report() if _runtime != null else {"ready": false, "reason": _failure_reason}
	result["spa_identity"] = get_identity_report()
	return result
func get_profile_arena_buffer() -> RID: return _runtime.get_profile_arena_buffer() if _runtime != null else RID()
func refresh_slot_mesh_description(asset_index: int) -> bool: return _runtime.refresh_slot_mesh_description(asset_index) if _runtime != null else false
func get_profile_arena_summary() -> Dictionary: return _runtime.get_profile_arena_summary() if _runtime != null else {}
func get_merged_gpu_buffer_summary() -> Dictionary: return _runtime.get_merged_gpu_buffer_summary() if _runtime != null else {}
func is_autoobject_runtime_ready() -> bool: return _runtime != null and _runtime.is_autoobject_runtime_ready()
func prepare_place_pipeline() -> Dictionary: return _runtime.prepare_place_pipeline() if _runtime != null else {"ok": false, "reason": "runtime_not_ready"}
func prepare_pipelines() -> Dictionary: return _runtime.prepare_pipelines() if _runtime != null else {"ok": false, "reason": "runtime_not_ready"}
func get_place_pipeline_readiness() -> Dictionary: return _runtime.get_place_pipeline_readiness() if _runtime != null else {"ready": false}
## shader 编译计时探针读数（按 shader 路径分 glslang 前端 / shader module / pipeline 三段）。
## 进程级 static，与本节点无关，挂这里只是给编辑器 bridge 的 call_method 一个入口。
func get_shader_compile_stats() -> Dictionary: return GodotComputeShaderBase.get_shader_compile_stats()
func reset_shader_compile_stats() -> void: GodotComputeShaderBase.reset_shader_compile_stats()
func get_place_resource_lifecycle_summary() -> Dictionary: return _runtime.get_place_resource_lifecycle_summary() if _runtime != null else {}
func register_asset(descriptor, mesh_ref = null, autoobject_ref = null) -> int: return _runtime.register_asset(descriptor, mesh_ref, autoobject_ref) if _runtime != null else -1
func register_autoobject_asset(autoobject_ref, mesh_ref = null) -> int: return _runtime.register_autoobject_asset(autoobject_ref, mesh_ref) if _runtime != null else -1
func register_assets(descriptors: Array) -> Array[int]: return _runtime.register_asset_batch(descriptors) if _runtime != null else ([] as Array[int])
func replace_all_assets(descriptors: Array, meshes: Array = [], autoobjects: Array = []) -> bool: return _runtime.replace_all_assets(descriptors, meshes, autoobjects) if _runtime != null else false
func replace_all_autoobject_assets(autoobjects: Array) -> bool: return _runtime.replace_all_autoobject_assets(autoobjects) if _runtime != null else false
func clear_assets() -> void:
	if _runtime != null: _runtime.clear_assets()
func get_asset_count() -> int: return _runtime.get_asset_count() if _runtime != null else 0
func get_registered_descriptors() -> Array[AssetDescriptor]: return _runtime.get_registered_descriptors() if _runtime != null else ([] as Array[AssetDescriptor])
func get_registered_profile_ids() -> Array[int]: return _runtime.get_registered_profile_ids() if _runtime != null else ([] as Array[int])
func get_profile_id_for_asset(asset_index: int) -> int: return _runtime.get_profile_id_for_asset(asset_index) if _runtime != null else -1
func get_registered_autoobject_refs() -> Array[AutoObject]: return _runtime.get_registered_autoobject_refs() if _runtime != null else ([] as Array[AutoObject])
func own_autoobject(autoobject_ref, asset_index: int = -1) -> bool: return _runtime.own_autoobject(autoobject_ref, asset_index) if _runtime != null else false
func get_owned_autoobject_count() -> int: return _runtime.get_owned_autoobject_count() if _runtime != null else 0
func get_owned_autoobject(index: int): return _runtime.get_owned_autoobject(index) if _runtime != null else null
func has_owned_autoobject(autoobject_ref) -> bool: return _runtime != null and _runtime.has_owned_autoobject(autoobject_ref)
func get_asset_id_for_autoobject(autoobject_ref) -> int: return _runtime.get_asset_id_for_autoobject(autoobject_ref) if _runtime != null else -1
func get_mesh_description_for_asset(asset_index: int) -> Dictionary: return _runtime.get_mesh_description_for_asset(asset_index) if _runtime != null else {}
func get_registered_mesh_descriptions() -> Array[Dictionary]: return _runtime.get_registered_mesh_descriptions() if _runtime != null else ([] as Array[Dictionary])
func get_mesh_description_buffer() -> RID: return _runtime.get_mesh_description_buffer() if _runtime != null else RID()
func get_mesh_description_gpu_buffer_summary() -> Dictionary: return _runtime.get_mesh_description_gpu_buffer_summary() if _runtime != null else {}
func readback_mesh_description_debug_snapshot() -> Dictionary: return _runtime.readback_mesh_description_debug_snapshot() if _runtime != null else {}
## 外部直写 BrushSV 门面；旁路笔刷累积状态，故须作废增量水位（失效条件 3）
func write_brush_sv_records(records: Array) -> Dictionary:
	_invalidate_brush_flush_watermark()
	return _runtime.write_brush_sv_records(records) if _runtime != null else {"ok": false, "reason": "runtime_not_ready"}
func has_brush_sv_content() -> bool: return _runtime != null and _runtime.has_brush_sv_content()
func get_brush_sv_revision() -> int: return _runtime.get_brush_sv_revision() if _runtime != null else 0
func get_brush_sv_field_summary() -> Dictionary: return _runtime.get_brush_sv_field_summary() if _runtime != null else {}
# ⚠ compose 门面不再挂修订号递增：生产管线的合成是 runtime 内部自调、不经过门面，
# 挂在这里（2026-08-10 前是 _volume_revisions 字典）从来接不到生产事件。
# 计数器在 runtime（_blend_sv_revision，合成成功即增），BlendSVVolume.revision() 转发。
func compose_blend_sv_fields(sv_complexity_rid: RID, sv_collision_rid: RID) -> Dictionary:
	return _runtime.compose_blend_sv_fields(sv_complexity_rid, sv_collision_rid) if _runtime != null else {"ok": false, "reason": "runtime_not_ready"}
func get_blend_sv_revision() -> int: return _runtime.get_blend_sv_revision() if _runtime != null else 0
func release_blend_sv_fields() -> void:
	if _runtime != null: _runtime.release_blend_sv_fields()
## BlendSV 场对 RID 的门面转发。BlendSVVolume 经这两个口读，不去摸 runtime 私有成员。
func blend_sv_complexity_rid() -> RID: return _runtime.blend_sv_complexity_rid() if _runtime != null else RID()
func blend_sv_collision_rid() -> RID: return _runtime.blend_sv_collision_rid() if _runtime != null else RID()
func score_blendsv_feedback_against_target(target_visual_rgba8_bytes: PackedByteArray, target_collision_r8_bytes: PackedByteArray = PackedByteArray()) -> Dictionary: return _runtime.score_blendsv_feedback_against_target(target_visual_rgba8_bytes, target_collision_r8_bytes) if _runtime != null else {"ok": false, "reason": "runtime_not_ready"}
func set_brush_sv_persistence_metadata(metadata: Dictionary) -> Dictionary:
	_brush_sv_control_metadata = ScenePlacementRuntimeScript._brush_sv_control_metadata_from(metadata)
	_brush_sv_control_metadata["owner"] = "ScenePlacementActor"
	_brush_sv_control_metadata["control_plane_only"] = true
	_brush_sv_control_metadata["content_mirror"] = false
	if _runtime != null:
		_brush_sv_control_metadata = _runtime.set_brush_sv_persistence_metadata(_brush_sv_control_metadata)
	return _brush_sv_control_metadata.duplicate(true)
func update_brush_sv_lifecycle_state(state: String, dirty: bool = false, dirty_keys: Array = []) -> Dictionary:
	if _runtime != null:
		_brush_sv_control_metadata = _runtime.update_brush_sv_lifecycle_state(state, dirty, dirty_keys)
	else:
		_brush_sv_control_metadata["owner"] = "ScenePlacementActor"
		_brush_sv_control_metadata["control_plane_only"] = true
		_brush_sv_control_metadata["content_mirror"] = false
		_brush_sv_control_metadata["lifecycle_state"] = state
		_brush_sv_control_metadata["dirty"] = dirty
		if not dirty_keys.is_empty():
			_brush_sv_control_metadata["dirty_keys"] = dirty_keys.duplicate()
	return _brush_sv_control_metadata.duplicate(true)
func get_brush_sv_persistence_metadata() -> Dictionary:
	if _runtime != null:
		_brush_sv_control_metadata = _runtime.get_brush_sv_persistence_metadata()
	return _brush_sv_control_metadata.duplicate(true)
func clear_brush_sv_persistence_metadata() -> void:
	if _runtime != null: _runtime.clear_brush_sv_persistence_metadata()
	_brush_sv_control_metadata.clear()
func spawn_autoobject_batch_from_accepted_placement_records(spawn_records: Array[Dictionary], options: Dictionary = {}) -> Dictionary: return _runtime.spawn_autoobject_batch_from_accepted_placement_records(spawn_records, options) if _runtime != null else {"ok": false, "reason": "runtime_not_ready"}
func flush_autoobject_runtime_to_scene_voxel_committer(options: Dictionary = {}) -> Dictionary: return _runtime.flush_autoobject_runtime_to_scene_voxel_committer(options) if _runtime != null else {"ok": false, "reason": "runtime_not_ready"}
func run_autoobject_prefilter(sv: Dictionary, target_read_buffers: Dictionary = {}, prefilter_settings: Dictionary = {}) -> Dictionary:
	return _publish_anchor_result(
		_runtime.run_autoobject_prefilter(sv, target_read_buffers, prefilter_settings) if _runtime != null else {"ok": false, "reason": "runtime_not_ready"})
func run_placement_pipeline(sv: Dictionary, placement_common: Dictionary = {}) -> Dictionary:
	return _publish_place_result(
		_runtime.run_placement_pipeline(sv, placement_common) if _runtime != null else {"ok": false, "reason": "runtime_not_ready"})
func debug_read_prefilter_asset_scores(source_anchor_index: int) -> Dictionary:
	return _runtime.debug_read_prefilter_asset_scores(source_anchor_index) if _runtime != null else {"ok": false, "reason": "runtime_not_ready"}
func get_last_pipeline_result() -> Dictionary: return _runtime.get_last_pipeline_result() if _runtime != null else {}
func build_resident_complexity_field_handoff(sv: Dictionary) -> Dictionary: return _runtime.build_resident_complexity_field_handoff(sv) if _runtime != null else {"ok": false, "reason": "runtime_not_ready"}
func prepare_target_read_buffers_from_common_gpu(settings: Dictionary, sv: Dictionary) -> Dictionary:
	_target_read_buffers = _runtime.prepare_target_read_buffers_from_common_gpu(settings, sv) if _runtime != null else {"ok": false, "reason": "runtime_not_ready"}
	return _target_read_buffers
