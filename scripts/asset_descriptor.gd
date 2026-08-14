@tool
class_name AssetDescriptor
extends Resource
# @tool: descriptor accessor methods (get_mesh/get_collision/get_color/…) must run in
# the editor. @tool demos (placement-score-3d 等) load descriptors and call these at
# edit time; without @tool the editor gives a placeholder script instance whose methods
# don't execute, so get_mesh() 等在编辑器里返回空/失败。运行时行为不变。

const SemanticProbeGeneratorScript := preload("res://scripts/semantic_probe_generator.gd")
const AutoVoxelProfile := preload("res://scripts/auto_voxel_profile.gd")
const ProfileRecordSchemaScript := preload("res://scripts/utils/profile_record_schema.gd")
const SharedPropertyTypeScript := preload("res://scripts/shared_property_type.gd")
const VariantUtils := preload("res://scripts/utils/variant_utils.gd")
const VoxelGeneralScript := preload("res://scripts/utils/voxel_general.gd")

# 值 1 保留（原 FLAG_SUPPORT；支撑已在 anchor 阶段判定，不再生成 support 探针）
# collision sample 的 flags 位语义；clearance 探针由 AutoVoxelRuntimeProfileContainer
# Canonical ProfileSamples carry the same values consumed by fine score and stamp.
const FLAG_CLEARANCE := ProfileRecordSchemaScript.SAMPLE_FLAG_CLEARANCE

# ══ get_profile_samples() 归一化缓存 ═════════════════════════════════════════
# 缓存两段**纯数据、与调用参数无关**的产物，避免每次调用重跑全量 normalize
# （其中 make_profile_sample 对每条样本做 provenance 深拷贝）：
#   "stored"      = profile_samples 存量记录的归一化结果；
#   "legacy_fine" = asset_voxels / collision 派生的 FINE 兜底采样（baked
#                   descriptor 的大头：五个 FBX 合计约 5 万条）。
# COARSE（probe）兜底分支**不缓存**：get_semantic_probes() 自带 density memo，
# 且它会写回 semantic_probe_generator.probes/density（有副作用），跳过会让该
# 子资源状态与旧行为分叉；probe 只有几十条，重算成本可忽略。
#
# 失效条件（谁在什么时候失效）：
#  1. set_profile_samples() / set_collision() —— 方法内显式清空（两者都是
#     clear+append，长度可能不变，光靠令牌看不出来）；
#  2. profile_samples 整体赋值（.tres 反序列化、Inspector、代码直接赋值）——
#     property setter 清空；
#  3. 其余影响产物的状态（asset_voxels/collision 长度、get_color()、
#     get_complexity()、collision_voxel_size）—— 每次调用重算 O(1) 状态令牌
#     比对，不一致即整体作废（见 _profile_sample_cache_token）；
#  4. Resource.changed 信号 —— _init() 接上 invalidate_profile_sample_cache()。
#     这条覆盖 O(1) 令牌看不见的情形：Inspector 里就地改写 asset_voxels/collision
#     中某条记录的字段（长度不变），以及整份**等长**重新赋值（这两个字段没有
#     setter）。容器的 _invalidate_normalized_descriptor_cache 连的就是同一个信号，
#     两级缓存因此在同一时刻失效，不会出现"容器重算、descriptor 仍还旧采样"。
#  5. descriptor 资源重载 / CACHE_MODE_REPLACE —— ⚠ 该模式**复用同一实例**、经
#     Resource::copy_from 逐 STORAGE 属性 set() 就地覆盖（instance_id 不变），并非
#     得到新实例；失效实际由 profile_samples 的 property setter（条件 2）与本条
#     的 changed 信号共同保证。缓存变量无 @export，不参与序列化，也不进
#     Resource.duplicate()。
#     ⚠ 编辑器脚本**软重载**并不会让实例变量"按初始化器复位"（旧注释这么写是错的）：
#     GDScriptInstance::reload_members() 只按名字把**重载前已存在**的成员搬进新槽位，
#     值原样保留；而本次重载**新增**的成员槽是默认构造的 Variant = nil，初始化器同样
#     不会重跑。也就是说旧成员保留旧值、新成员是 nil —— 两种情况都不是"复位成空
#     Dictionary"。_sample_cache 因此在 _refresh_profile_sample_cache() 里显式修复
#     （见该函数注释），失效入口一律用整体赋值而非 .clear()（nil 上没有 .clear()）。
#     ⚠ 另有一条独立结论：**static var 的 Object 型初始化器会在脚本重载时被重置为
#     null**（与上面的实例成员规则无关，别混为一谈）。因此这里只用**实例级**的
#     类型化容器，不用 static、不放 Object。
#
# 可变性契约：缓存数组本身**从不外泄**——get_profile_samples() 仍然每次返回新
# 建的顶层 Array（append_array 复制引用），调用方对返回数组的增删不会污染缓存；
# 共享的只是 sample Dictionary 实例，全部调用方均为只读（见 P4 交付说明）。
var _sample_cache: Dictionary = {}


func _init() -> void:
	# 复用容器已在用的失效通道（AutoVoxelRuntimeProfileContainer 把 descriptor.changed
	# 连到自己的归一化缓存失效）：等长的就地内容改写不会改变 O(1) 令牌，只有 changed
	# 能捕获，两级缓存必须同时作废。
	if not changed.is_connected(invalidate_profile_sample_cache):
		changed.connect(invalidate_profile_sample_cache)

@export var color: Color = Color.WHITE                         # canonical 默认颜色；alpha 同步 complexity
@export_range(0.0, 1.0) var complexity: float = 1.0             # canonical 默认强度
@export var collision: Array[Dictionary] = []                   # canonical 局部 collision sample 列表
# canonical coarse/fine/stamp ProfileSample records；整体赋值（.tres 反序列化 /
# Inspector / 代码直接赋值）经 setter 让归一化缓存失效
@export var profile_samples: Array[Dictionary] = []:
	set(value):
		profile_samples = value
		# 整体赋值而非 .clear()：软重载新增的成员是 nil，nil 上没有 .clear()（见类首条件 5）
		_sample_cache = {}
@export var asset_voxels: Array[Dictionary] = []                # legacy serialized Fine source; read only at migration boundary
@export var pivot_variants: Array[Dictionary] = []              # 显式 pivot 列表；空 = 单条零偏移 bottom pivot
@export_range(0.001, 8.0, 0.001, "or_greater") var collision_voxel_size: float = 1.0 # 烘焙时碰撞体素的世界尺寸（米/格），baker 从 voxelizer cell_size 写入
@export var semantic_probe_generator: Resource                    # 保存或生成 semantic_probes 的 profile
@export_range(0.1, 8.0, 0.1) var semantic_probe_density: float = 1.0 # 自动 probe 生成密度
@export_range(0.0, 8.0, 0.1) var context_sensing_radius: float = 0.0 # 外围 context probes 半径；0 禁用
## 互斥半径乘数（放置期成对间距）。reduce（`shaders/invalidate_anchor_conflicts.glsl`）按
## `dist < max(min_distance_voxels, (r_a + r_b) * asset_spacing_factor)` 淘汰低优先级一端，
## 其中 `r = mesh AABB 的 XZ 半长 × 本乘数`（`ScenePlacementActor._build_placement_asset_defs()`）。
## 1.0 = 恰好外接网格；<1 让同类挨得更密，>1 拉开；0 = 取消该资产的成对项，只剩全局
## `min_distance_voxels` 下界。Asset Overview 的「exclusion radius ×」写的就是它，
## 同一个值同时驱动那里的互斥球可视化 —— 可视化与 SPA 放置是同一个数，不存在两套。
## ⚠ 旧 .tres 没有本字段 → 加载后取默认 1.0 → 行为与引入前一致（迁移安全）。
@export_range(0.0, 8.0, 0.05, "or_greater") var spacing_radius_scale: float = 1.0
@export var asset_id: String = ""                               # 植被资产 id / debug metadata
@export var object_type: String = ""                            # runtime grouping，不替代 descriptor 语义
@export var voxel_profile: AutoVoxelProfile                     # import-time profile source
@export var mesh: Mesh                                          # 显示 mesh
## ⚠ 刻意**不导出**：这是 `get_source_mesh()` 的运行期解析缓存，不是持久化字段。
## 持久化的真相只有下面的 `source_mesh_path`。
##
## 导出过一次的代价（实测）：`resolve_cached_source_mesh()` 命中路径后会把加载到的 Mesh
## 写回本字段，而 FBX 里的 ArrayMesh 是被导入场景的子资源、存不成 ext_resource 引用
## ⇒ `ResourceSaver.save()` 只能把整份网格**内嵌**进 .tres。于是同一份 descriptor 的体积
## 在「有没有人调过 get_source_mesh()」之间摇摆：0.92 MB ↔ 2.22 MB，每次烘焙都弄脏 git，
## 而几何一个字节没变。
var source_mesh: Mesh                                           # 运行期缓存，见上
@export var source_mesh_path: String = ""                       # source mesh 资源路径（持久化真相）
@export var mesh_create_method: String = ""                     # 程序化 mesh 创建方法名
@export var visual_layer: int = 0                               # 实例化时启用的显示层
@export var group: String = ""                                  # 实例化时加入的分组
@export var material: Material                                  # 实例化时应用的材质

# ---- 逐资产评分参数覆盖（fine 评分，score_anchor_asset_residual.glsl）----
# 每项 -1 = 继承全局 score_match_config.cfg；>=0 = 覆盖该资产。generator 按 asset_id
# 打 per-asset SSBO，shader 用 (per_asset >= 0 ? per_asset : 全局push) 解析——旧 .tres
# 无这些字段 → 默认 -1 → 全部继承 → 行为不变（迁移安全）。顺序与 get_score_param_overrides 一致。
@export_group("Score Params (per-asset; -1 = inherit global)")
@export var score_min_match_fraction: float = -1.0        # 候选有效最低 signed score(0..1)
@export var score_dim_weight_collision: float = -1.0      # 残差 gain：collision 维权重(>=0)
@export var score_dim_weight_complexity: float = -1.0     # 残差 gain：complexity 维权重(>=0)
@export var score_dim_weight_color: float = -1.0          # 残差 gain：color 每通道权重(>=0)
@export var score_color_match_max_l1: float = -1.0        # color 预算：post-compose rgb L1(0..3)
@export var score_collision_match_max: float = -1.0       # collision 预算：|pred-tgt|(0..1)
@export var score_complexity_overfill_percent: float = -1.0  # complexity 过填容差 N%(>=0)
@export_group("")


## 逐资产评分参数覆盖，固定顺序（-1=继承全局）。generator 打 per-asset score SSBO 用；
## 直接读属性也可（编辑器 placeholder 下属性可读、方法不执行——本方法仅供运行期便捷）。
func get_score_param_overrides() -> PackedFloat32Array:
	return PackedFloat32Array([
		score_min_match_fraction,
		score_dim_weight_collision,
		score_dim_weight_complexity,
		score_dim_weight_color,
		score_color_match_max_l1,
		score_collision_match_max,
		score_complexity_overfill_percent,
	])


func get_color() -> Color:
	if _should_read_profile_average():
		return voxel_profile.get_color()
	var result := color
	result.a = get_complexity()
	return result


func get_complexity() -> float:
	if _should_read_profile_average():
		return voxel_profile.get_complexity()
	return clampf(complexity, 0.0, 1.0)


func set_color_and_complexity(next_color: Color, next_complexity: float) -> void:
	complexity = clampf(next_complexity, 0.0, 1.0)
	color = next_color
	color.a = complexity


func get_collision(default_radius: float = 0.0) -> Array[Dictionary]:
	var radius := default_radius
	if not collision.is_empty():
		return VoxelGeneralScript.normalize_collision_samples(collision, radius)
	return []


func set_collision(source: Array) -> void:
	# 整体赋值而非 .clear()：clear+append 后长度可能不变、状态令牌看不出来，需显式失效；
	# 且软重载新增的成员是 nil，nil 上没有 .clear()（见类首条件 5）
	_sample_cache = {}
	collision.clear()
	for raw in source:
		if raw is Dictionary:
			var entry := (raw as Dictionary).duplicate(true)
			collision.append(entry)


func get_asset_voxels() -> Array[Dictionary]:
	return SharedPropertyTypeScript.duplicate_dictionary_array(asset_voxels)


func set_profile_samples(source: Array) -> void:
	# 整体赋值而非 .clear()：clear+append 后长度可能不变、状态令牌看不出来，需显式失效；
	# 且软重载新增的成员是 nil，nil 上没有 .clear()（见类首条件 5）
	_sample_cache = {}
	profile_samples.clear()
	for index in range(source.size()):
		var raw = source[index]
		if not raw is Dictionary:
			push_error("[AssetDescriptor] %s: set_profile_samples() 第 %d 条不是 Dictionary（typeof=%d）—— 输入 ProfileSample 列表损坏，整批拒绝" % [resource_path, index, typeof(raw)])
			assert(false, "AssetDescriptor.set_profile_samples: non-Dictionary sample")
			profile_samples.clear()
			return
		var sample := ProfileRecordSchemaScript.normalize_profile_sample(raw as Dictionary)
		var reason := ProfileRecordSchemaScript.profile_sample_validation_error(sample)
		if not reason.is_empty():
			push_error("[AssetDescriptor] %s: set_profile_samples() 第 %d 条 ProfileSample 非法（%s）—— 整批拒绝，不写入任何采样" % [resource_path, index, reason])
			assert(false, "AssetDescriptor.set_profile_samples: invalid ProfileSample")
			profile_samples.clear()
			return
		profile_samples.append(sample)


func get_profile_samples(
	mesh_override: Mesh = null,
	density_override: float = -1.0,
	world_scale: Vector3 = Vector3.ONE,
	fallback_collision: Array = []
) -> Array[Dictionary]:
	_refresh_profile_sample_cache()
	# 顶层数组每次新建：存量段与 FINE 兜底段来自缓存时也只复制引用，调用方对返回
	# 数组的增删改不会回写缓存（sample Dictionary 本身按只读契约共享）。
	var result: Array[Dictionary] = []
	result.append_array(_normalized_stored_profile_samples())
	var has_coarse := _profile_samples_have_stage(
		result, ProfileRecordSchemaScript.SAMPLE_FLAG_COARSE)
	var has_fine := _profile_samples_have_stage(
		result, ProfileRecordSchemaScript.SAMPLE_FLAG_FINE)
	# ⚠ 下面两个分支是 **legacy 数据格式兼容路径**，不是错误兜底：全部存量烘焙
	# descriptor（scenes/asset-overview/baked_descriptors/*.tres、assets/vegetation/*.tres）
	# 都还是旧格式——只有 semantic_probe_generator.probes + asset_voxels/collision，
	# profile_samples 整个字段都不存在。把它们改成报错崩溃会让存量 .tres 直接打不开。
	# 缺 COARSE/FINE 是老格式的合法形态，派生结果由 probe/legacy voxel 真实数据决定，
	# 不是"造一个假值顶上"。（快速失败重构 2026-08-03 复核：保留）
	if not has_coarse:
		var probe_mesh := mesh_override if mesh_override != null else get_mesh()
		var probes := get_semantic_probes(
			probe_mesh, density_override, world_scale, fallback_collision)
		result.append_array(ProfileRecordSchemaScript.profile_samples_from_legacy_probes(probes))
	if not has_fine:
		result.append_array(_legacy_fine_profile_samples(fallback_collision))
	return result


## profile_samples 存量记录的归一化结果（缓存段一）。
func _normalized_stored_profile_samples() -> Array[Dictionary]:
	if _sample_cache.has("stored"):
		return _sample_cache["stored"]
	var normalized: Array[Dictionary] = []
	for index in range(profile_samples.size()):
		var raw = profile_samples[index]
		if not raw is Dictionary:
			push_error("[AssetDescriptor] %s: 存量 profile_samples[%d] 不是 Dictionary（typeof=%d）—— 存量记录损坏，本 descriptor 不再提供任何存量 ProfileSample" % [resource_path, index, typeof(raw)])
			assert(false, "AssetDescriptor: non-Dictionary stored ProfileSample")
			normalized.clear()
			_sample_cache["stored"] = normalized
			return normalized
		var sample := ProfileRecordSchemaScript.normalize_profile_sample(raw as Dictionary)
		var reason := ProfileRecordSchemaScript.profile_sample_validation_error(sample)
		if not reason.is_empty():
			push_error("[AssetDescriptor] %s: 存量 profile_samples[%d] 非法（%s）—— 存量记录损坏，本 descriptor 不再提供任何存量 ProfileSample" % [resource_path, index, reason])
			assert(false, "AssetDescriptor: invalid stored ProfileSample")
			normalized.clear()
			_sample_cache["stored"] = normalized
			return normalized
		normalized.append(sample)
	_sample_cache["stored"] = normalized
	return normalized


## legacy asset_voxels / collision 派生的 FINE 兜底采样（缓存段二）。
## fallback_collision 只在 asset_voxels 为空时被 profile_samples_from_legacy_voxels
## 当作 source 读（该参数在函数内的唯一用处），因此：
##  - asset_voxels 非空 → 产物与入参无关，可缓存；
##  - fallback_collision 为空 → 走 get_collision()，同样只依赖自身状态，可缓存；
##  - 两者皆不满足（外部传入非空 collision 且自身无 asset_voxels）→ 产物随入参变化，
##    每次现算且不写缓存，避免跨调用串味。
## 兜底体本身仍按原逻辑逐字构造（含 asset_voxels 非空时那次"用不上"的
## get_collision()——它会对 legacy 非点采样 push_warning，保留以免改动日志行为）。
func _legacy_fine_profile_samples(fallback_collision: Array) -> Array[Dictionary]:
	var cacheable := not asset_voxels.is_empty() or fallback_collision.is_empty()
	if cacheable and _sample_cache.has("legacy_fine"):
		return _sample_cache["legacy_fine"]
	var collision_fallback := fallback_collision
	if collision_fallback.is_empty():
		collision_fallback = get_collision()
	var derived := ProfileRecordSchemaScript.profile_samples_from_legacy_voxels(
		asset_voxels,
		collision_fallback,
		get_color(),
		get_complexity(),
		Vector3.ONE * maxf(collision_voxel_size, 1.0e-6),
		ProfileRecordSchemaScript.LEGACY_CLEARANCE_FLAG
	)
	if cacheable:
		_sample_cache["legacy_fine"] = derived
	return derived


## 归一化缓存的强制失效入口（就地改写 asset_voxels/collision 条目内容后手动调用）。
func invalidate_profile_sample_cache() -> void:
	# 整体赋值而非 .clear()：软重载新增的成员是 nil，nil 上没有 .clear()（见类首条件 5）
	_sample_cache = {}


## O(1) 状态令牌：覆盖两段缓存产物的全部自身输入（长度 + 解析后的标量）。
## 与上次不一致即整体作废——见类首「失效条件」注释。
func _profile_sample_cache_token() -> Array:
	return [
		profile_samples.size(),
		asset_voxels.size(),
		collision.size(),
		get_color(),
		get_complexity(),
		collision_voxel_size,
	]


## 本函数是 _sample_cache 全部**读**路径的唯一前置（get_profile_samples 先调它，
## _normalized_stored_profile_samples / _legacy_fine_profile_samples 只在其后被调用），
## 故软重载修复只需收口在这里。
##
## ⚠ 别把下面这行当成冗余判空删掉。事实依据（gdscript.cpp
## GDScriptInstance::reload_members）：编辑器软重载只把**重载前已存在**的成员按名字搬进
## 新槽位；本次重载**新增**的成员槽是默认构造的 Variant = nil，声明里的
## `var _sample_cache: Dictionary = {}` 初始化器**不会**重跑。带静态类型也拦不住——实例槽
## 本身是 Variant。于是重载后第一次取采样会当场炸在 `nil.get("token", null)` 上。
## ⚠ 必须用 `is` 而不是 `== null`：对静态类型已知的操作数 GDScript 会挑验证求值器，而
## Variant 给 (DICTIONARY, NIL) 注册的是 OperatorEvaluatorAlwaysFalse（variant_op.cpp），
## `_sample_cache == null` 会被编成恒 false，判空形同虚设。
## 语义：修复成空字典 = 缓存未命中，下面照常按 token 重算重填，与冷启动首次调用等价。
func _refresh_profile_sample_cache() -> void:
	if not (_sample_cache is Dictionary): _sample_cache = {}
	var token := _profile_sample_cache_token()
	if _sample_cache.get("token", null) != token:
		_sample_cache = {"token": token}


static func _profile_samples_have_stage(samples: Array[Dictionary], stage_flag: int) -> bool:
	for sample in samples:
		if (int(sample.get("flags", 0)) & stage_flag) != 0:
			return true
	return false


func set_pivot_variants(variants: Array) -> void:
	pivot_variants = normalize_pivot_variants(variants)


## pivot 候选。作者显式写了 `pivot_variants` 就用它，否则是**单条零偏移 bottom pivot**。
##
## ⚠ 曾经这里还有一条「从 collision 高度自动派生 bottom/middle/upper 三变体」的分支
## （`auto_generate_vertical_pivots` + `make_vertical_pivot_variants_from_collision`），
## 已于 2026-08-05 整条删除。删除理由不是"用不上"，是它**算错了**：
## 那个生成器按碰撞体素**下标**（0 基）推 pivot，`y_min` 恒为 0，它无从知道网格原点在哪；
## 而 `placement_results_to_world.glsl` 算的是 `origin = anchor_world - basis * pivot`。
## 于是 upper 变体给 cliff 类资产产出 +56 ~ +60.8 m 的 pivot（比整个 32 m 网格还高），
## 放置结果整体沉到 anchor 下方 80 m 以上。实测与成因见
## 《AutoObject实例GPU直提与点选交接计划.md》§11 的 2026-08-05 记录。
func get_pivot_variants() -> Array[Dictionary]:
	if not pivot_variants.is_empty():
		return normalize_pivot_variants(pivot_variants)
	return [ProfileRecordSchemaScript.default_bottom_pivot()]


func ensure_semantic_probe_generator() -> Resource:
	if semantic_probe_generator == null:
		semantic_probe_generator = SemanticProbeGeneratorScript.new()
		semantic_probe_generator.density = semantic_probe_density
	return semantic_probe_generator


func set_semantic_probes(probes: Array) -> void:
	var profile := ensure_semantic_probe_generator()
	profile.probes = SemanticProbeGeneratorScript.duplicate_probe_array(probes)


func get_semantic_probes(
	mesh_or_density = null,
	density_override: float = -1.0,
	world_scale: Vector3 = Vector3.ONE,
	fallback_collision: Array = []
) -> Array[Dictionary]:
	var profile := ensure_semantic_probe_generator()
	var resolved_mesh: Mesh = null
	var resolved_density := density_override
	var resolved_world_scale := world_scale
	var resolved_fallback_collisions := fallback_collision
	if mesh_or_density is Mesh:
		resolved_mesh = mesh_or_density as Mesh
	elif mesh_or_density is float or mesh_or_density is int:
		resolved_mesh = get_mesh()
		resolved_density = float(mesh_or_density)
		resolved_world_scale = Vector3.ONE
	elif mesh_or_density != null:
		push_error("[AssetDescriptor] %s: get_semantic_probes() 首参类型非法（typeof=%d）—— 只接受 Mesh / float / int / null" % [resource_path, typeof(mesh_or_density)])
		assert(false, "AssetDescriptor.get_semantic_probes: unsupported mesh_or_density type")
		return []
	else:
		resolved_mesh = get_mesh()
		resolved_world_scale = Vector3.ONE
	if resolved_fallback_collisions.is_empty():
		resolved_fallback_collisions = get_collision()
	var d := semantic_probe_density if resolved_density <= 0.0 else resolved_density
	if not profile.probes.is_empty() and absf(float(profile.get("density")) - d) <= 0.001:
		return profile.get_probes()
	var collisions := get_collision()
	if collisions.is_empty():
		collisions = resolved_fallback_collisions
	return profile.rebuild_from_mesh(
		resolved_mesh,
		collisions,
		get_color(),
		get_complexity(),
		d,
		resolved_world_scale,
		context_sensing_radius
	)


func get_mesh() -> Mesh:
	if mesh != null:
		return mesh
	var create_method := mesh_create_method.strip_edges()
	match create_method:
		"":
			# mesh 与 mesh_create_method 都没配 —— 合法的“无 mesh” descriptor 形态
			# （from_profile / AutoObject._ensure_asset_descriptor 造出来的就是这种），
			# 由调用方自行判空，不在这里报错。
			return null
		"create_sample_autoobject_mesh":
			return create_sample_autoobject_mesh()
		_:
			push_error("[AssetDescriptor] %s: mesh 为空且 mesh_create_method=\"%s\" 不是已知的程序化 mesh 生成方法 —— 无法取得 mesh" % [resource_path, create_method])
			assert(false, "AssetDescriptor.get_mesh: unknown mesh_create_method")
			return null


static func create_sample_autoobject_mesh() -> Mesh:
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.35, 0.6, 0.35)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.70, 0.45)
	mat.roughness = 0.85
	mesh.material = mat
	return mesh


func get_source_mesh() -> Mesh:
	var factory_script = load("res://scripts/auto_asset_factory.gd")
	if factory_script == null:
		push_error("[AssetDescriptor] %s: 无法加载 res://scripts/auto_asset_factory.gd —— source mesh 解析链不可用" % resource_path)
		assert(false, "AssetDescriptor.get_source_mesh: auto_asset_factory.gd load failed")
		return null
	return factory_script.resolve_cached_source_mesh(self, mesh, get_mesh())


func _should_read_profile_average() -> bool:
	return (
		voxel_profile != null
		and color == Color.WHITE
		and is_equal_approx(complexity, 1.0)
	)


static func from_profile(profile: AutoVoxelProfile, default_radius: float = 0.0) -> Resource:
	if profile == null:
		push_error("[AssetDescriptor] from_profile(): profile 为 null —— 无法构建 descriptor（原行为返回一份全默认空 descriptor，掩盖了缺失的 profile）")
		assert(false, "AssetDescriptor.from_profile: null profile")
		return null
	var descriptor = load("res://scripts/asset_descriptor.gd").new()
	descriptor.color = profile.get_color()
	descriptor.complexity = profile.get_complexity()
	descriptor.set_collision(profile.get_collision(default_radius))
	descriptor.set_profile_samples(ProfileRecordSchemaScript.profile_samples_from_legacy_voxels(
		[],
		descriptor.get_collision(),
		descriptor.get_color(),
		descriptor.get_complexity(),
		Vector3.ONE,
		ProfileRecordSchemaScript.LEGACY_CLEARANCE_FLAG
	))
	return descriptor


static func normalize_pivot_variants(raw_variants: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for i in range(raw_variants.size()):
		var raw = raw_variants[i]
		if raw is Dictionary:
			var d := (raw as Dictionary).duplicate(true)
			d["name"] = str(d.get("name", "pivot_%d" % i))
			d["offset"] = VariantUtils.vector3_from_value(d.get("offset", Vector3.ZERO), Vector3.ZERO)
			d["score_bias"] = float(d.get("score_bias", 0.0))
			result.append(d)
		elif raw is Vector3:
			result.append({"name": "pivot_%d" % i, "offset": raw as Vector3, "score_bias": 0.0})
	if result.is_empty():
		# 传入非空却一条都没解析出来 = pivot 数据损坏，不能拿默认 bottom pivot 顶上。
		if not raw_variants.is_empty():
			push_error("[AssetDescriptor] normalize_pivot_variants(): 传入 %d 条 pivot variant 但无一条可解析（仅接受 Dictionary / Vector3）—— pivot 数据损坏" % raw_variants.size())
			assert(false, "AssetDescriptor.normalize_pivot_variants: all pivot variants rejected")
			return result
		# 传入本来就是空 —— “未配置 pivot”的合法形态，默认 bottom pivot 是契约默认值。
		result.append(ProfileRecordSchemaScript.default_bottom_pivot())
	return result


