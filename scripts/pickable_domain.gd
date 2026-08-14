@tool
class_name PickableDomain
extends Node3D

## SPA 下**所有可点选元素**的共同根（《AutoVolume 公用体积基类计划》§2.1）。
##
## 它回答的是「一个可点选元素，不管装的是体素、瓦片、稀疏槽还是实例，都必然要做的那几件事」：
## 归属哪个 SPA、自己是哪个域、内容变没变、显示节点叫什么、怎么进 ID pass。
## 体积语义**不在这里**——元素空间、Buffer、坐标换算全在 AutoVolumeField / AutoVolumeTile /
## AutoVolumeAnchor 三个体积抽象层，`AutoObject` 作为实例域直接继承本类而不实现它们（§1.7、§3）。
##
## ── 本类不做什么（边界，见 §2.6）────────────────────────────────────────────
## * 不持有坐标框架。grid_size / voxel_size / grid_origin 的事实源是 ScenePlacementActor
##   的三个 @export；本类只经 `grid_frame()` 转发（§2.3）。把框架复制进卷 = 又养出第二份推导式。
## * 不实现 ID pass。镜像 SubViewport、own_world_3d 隔离、tonemap 逆变换补偿、MSAA/TAA 关闭、
##   回读帧守卫，全部是 `PickIdPass` 的内部实现。本类只负责**登记** drawable。
## * 不做视距剔除。CPU `set_instance_transform` 与 GPU 直写互斥（见 volume_score_demo.gd:2762），
##   剔除方案归《GPU直提渲染》。
##
## ── 为什么 extends Node3D 而不是 Node ─────────────────────────────────────
## 消费侧已经有 5 处对卷节点做 `is Node3D` 判型并调 `to_global()` / `global_transform`
## （spa_selection_host.gd:663 / :1002 / :1007 / :1999 / :2017）。改成 Node 这 5 处一起崩。
##
## ── 为什么必须 @tool ──────────────────────────────────────────────────────
## 本类在编辑器里被实例化。非 @tool 的 GDScript 在编辑器里被加载成 PlaceHolderScriptInstance：
## 导出属性还读得到，**方法一律不执行且不报错**——表现只是「什么都没发生」。
## 同一个坑 CLAUDE.md 已就 AssetDescriptor 记录过一次。
## ⚠ 基类带了 @tool，**所有子类也必须带**，否则触发引擎的 MISSING_TOOL 警告。

const SPAEditorContractScript := preload("res://scripts/spa_editor_contract.gd")
## 显示几何 / 地形高度场 / 显示构建共用的工具（2026-08-10 自各子类上提）。
## ⚠ 基类声明的 preload 常量沿脚本链继承；子类**不要**重新声明同名 preload——
## 会报 "member already exists in parent class"。
const VoxelGeneralScript := preload("res://scripts/utils/voxel_general.gd")
const TerrainInitializerScript := preload("res://scripts/terrain_initializer.gd")
const TerrainConfigScript := preload("res://scripts/terrain_config.gd")
const VoxelDisplayScript := preload("res://scripts/utils/voxel_display.gd")


# ── 归属：祖先 SPA ────────────────────────────────────────────────────────────

@export_group("Display")
## 本域显示节点的手动开关。刻意做成 @export 且**不带 setter**：
## 场景加载期属性写入发生在入树与 _ready 之前，带 setter 会在那时触发一次显示重建
## （拿不到 SPA、拿不到 RenderingDevice），失败信息还会被当成真实错误报出来。
## 写它一律走 `set_display_visible()`。这与 TargetSVSetup 既有的 display_visible 同形，
## V2 接进来时删掉子类那一份即可。
@export var display_visible: bool = true


## 祖先 SPA 缓存。**不做构造注入**：本类按构造就长在 SPA/Volumes 下，宿主由父链自解析得到。
## 这与 SPASelectionHost 是同一条约定（scene_placement_actor.gd:773-775 明确禁止再加
## attach_spa 之类的注入口——那会变成"两套绑定机制、不清楚谁赢"）。
var _cached_spa: ScenePlacementActor = null

# ── 内容修订号 ───────────────────────────────────────────────────────────────

## 本域的**内容**修订号。语义严格限定为「这个域装的东西变了」，消费方拿它做缓存键。
##
## ⚠ 别把另外两类计数器搬进来（§2.1 的边界）：
##   * RID 失效/交接号（ScenePlacementActor._anchor_revision / _score_revision）——
##     它的语义是"释放或替换 RID 之前必须先递增"，时序约束在 SPA 侧，不在域里。
##   * 消费侧水位（_brush_flushed_sv_revision / AutoObjectInstanceRenderer._emitted_revision）——
##     那是**消费方**记的"我上次读到第几版"，不属于任何域。
## 三者混成一个数之后，谁该在什么时候递增就再也说不清了。
var _revision := 0


# ── 生命周期：进/出树即作废 SPA 缓存 ─────────────────────────────────────────
#
# ⚠ 刻意走 _notification 而不是 _enter_tree / _exit_tree 覆写。
# 依据（gdscript.cpp GDScriptInstance::notification，源码注释原文
# "notification is not virtual, it gets called at ALL levels just like in C."）：
# _notification 沿脚本继承链**每一层都会被调**，而 _enter_tree / _exit_tree 是普通覆写
# —— 子类定义了同名函数又忘了写 `super._enter_tree()`，基类这半段就静默不跑。
# 本仓全部 super 调用只有 3 处且全是 super._ready()，_enter_tree / _exit_tree 一个先例都没有；
# 而 V2 要接进来的 TargetSVSetup 恰好三个钩子全有。用 _notification 让"忘记 super"这个
# 失败模式从结构上不存在。
#
# ⚠ 同理，子类的 _notification 里**不要**写 super._notification(what)——那会让基类逻辑跑两遍。
func _notification(what: int) -> void:
	match what:
		NOTIFICATION_ENTER_TREE:
			_cached_spa = _resolve_scene_placement_actor()
		NOTIFICATION_EXIT_TREE:
			_cached_spa = null
		NOTIFICATION_READY:
			# 默认可见性在 READY 应用而不是改 @export 默认值：场景加载期的属性写入发生在
			# 入树与 _ready 之前，那时拿不到 SPA 与 RenderingDevice。此前 SceneSV / SVTile
			# 各自在 _ready() 里写 display_visible = false（连理由注释都互相引用），
			# 收成钩子后两个 _ready 一起删除。引擎对脚本 _notification 沿链每层都调，
			# 本分支只在根类存在，不会跑两遍。
			display_visible = default_display_visible()


## 祖先 SPA。**返回值可能为 null**——调用方据此分支的场景（"有真实宿主"vs"裸节点展示"）
## 是合法的；需要网格参数的地方走 `_require_spa()`，那条缺宿主即判死。
func scene_placement_actor() -> ScenePlacementActor:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	if _cached_spa != null:
		if is_instance_valid(_cached_spa) and _cached_spa.is_inside_tree():
			return _cached_spa
		_cached_spa = null
	_cached_spa = _resolve_scene_placement_actor()
	return _cached_spa


## 网格与坐标框架的唯一来源 = 祖先 SPA。本类按构造就长在 SPA/Volumes 下，
## 父链上找不到 SPA 说明装配已经坏了，属于错误而不是一种可支持的形态。
##
## 旧写法（各子类各自那份）在缺宿主时回落到自己的元数据换算或一套默认网格：
## 每一步都"成功"，只是坐标静默偏在错误的体素上，事后查不出是从哪一步歪的。
func _require_spa() -> ScenePlacementActor:
	var spa := scene_placement_actor()
	if spa == null:
		push_error("[%s] 父链上找不到 ScenePlacementActor（self=%s）—— 可点选域必须挂在 SPA 子树下，网格与坐标框架无来源。" % [
			_log_name(), str(get_path()) if is_inside_tree() else name])
		assert(false, "PickableDomain._require_spa: missing ancestor ScenePlacementActor")
	return spa


func _resolve_scene_placement_actor() -> ScenePlacementActor:
	var cursor: Node = self
	while cursor != null:
		if cursor is ScenePlacementActor:
			return cursor as ScenePlacementActor
		cursor = cursor.get_parent()
	return null


# ⚠ 这里曾有静态版父链解析 `resolve_spa_from()`（给非 PickableDomain 调用方复用）。
# 当初的消费者（scripts/checks/ 的两个静态套件）已不再引用，全仓零调用，
# 已删除（2026-08-10，链路死码清除）。


# ── 坐标框架：转发，不复制 ───────────────────────────────────────────────────

## 规范坐标框架 `{grid_size, voxel_size, grid_origin}`，转发自祖先 SPA（§2.3）。
##
## ⚠ 返回的是 SPA 的那一份，不是副本语义上的"本域的框架"。任何子类都**不得**把这三项
## 存成自己的成员——《体素格式统一》R1c 刚把框架收敛到 SPA，存一份就是把它再拆开。
##
## ⚠ 别按字典顺序展开喂给 `VoxelGeneral.scaled_grid_frame()`：那个函数形参序是
## (grid_size, grid_origin, voxel_size, scale)，与本字典键序把后两项对调，且两者同为 Vector3
## —— 传反了不报错、不崩，只有整套坐标静默错位。要按键名取。
func grid_frame() -> Dictionary:
	var spa := _require_spa()
	return spa.get_grid_frame() if spa != null else {}


# ── 域身份 ───────────────────────────────────────────────────────────────────

## 本域在 `SPAEditorContract.VOXEL_DOMAIN_BINDINGS` 里的域名。
## 子类必须重写，返回 `SPAEditorContract.SELECTION_DOMAIN_*` 之一。
func domain_key() -> String:
	return ""


## 本卷参不参与点选。
##
## 绝大多数子类是 true（本类叫 PickableDomain 就是这个意思）。**显式退出**这一档目前只有
## `BlendSV`：它是一次性混合暂存卷，内容恒等于 `SV ⊕ BrushSV`，画它就是画重复，
## 因此没有可视化节点、也就没有 drawable、也就进不了 ID pass（《计划》§1.6）。
## 它继承本族是为了共享 Buffer 生命周期与节点归属，不是为了被点中。
##
## ⚠ 这是**显式 opt-out**，不是"domain_key 为空就当作不参与"。后者会把"子类忘了声明域名"
## 和"这个卷本来就不该被点"混成同一种表现——而前者正是必须当场报错的那一种。
func participates_in_picking() -> bool:
	return true


## 本域的合同条目（domain / mode / display_key / label / …）。
##
## 空 domain_key 或查不到条目一律判死：那意味着这个域没有显示开关、没有 display_key，
## "看不见就选不中"对它不成立，而界面上完全看不出原因。
## 显式声明不参与点选的卷（`participates_in_picking() == false`）返回空字典，不报错。
func domain_binding() -> Dictionary:
	if not participates_in_picking():
		return {}
	var key := domain_key()
	if key.is_empty():
		push_error("[%s] domain_key() 返回空 —— 每个 PickableDomain 子类都必须声明自己的域名（SPAEditorContract.SELECTION_DOMAIN_*），否则它既进不了显示开关也进不了 ID pass。若本卷本来就不该被点中，请重写 participates_in_picking() 返回 false。" % _log_name())
		assert(false, "PickableDomain.domain_binding: subclass did not declare domain_key()")
		return {}
	var binding: Dictionary = SPAEditorContractScript.binding_for_domain(key)
	if binding.is_empty():
		push_error("[%s] 域名 \"%s\" 不在 VOXEL_DOMAIN_BINDINGS 里 —— 该域没有显示键，无法被显示开关关掉。" % [_log_name(), key])
		assert(false, "PickableDomain.domain_binding: domain not registered in contract")
	return binding


## 本域的显示键（显示开关 + 显示组 + ID pass 收集都按它索引）。
func display_key() -> String:
	var binding := domain_binding()
	return str(binding.get("display_key", binding.get("key", "")))


# ── 所有权报告：每个域自报一行 ───────────────────────────────────────────────

## 本域在 `ScenePlacementActor.get_volume_ownership_report()` 里的一行（基础形状）。
##
## 2026-08-10 起报告按「SPA/Volumes 下每个 PickableDomain 自报」生成。此前 SPA 维护一张
## `VOLUME_KEYS` 键表 + `_volume_revisions` 修订号字典：SVTile / Anchor / AutoObject 因
## "行形状不同"被键表排除（SVTile 靠一条手工合成行顶着），而字典自四个卷改为
## PickableDomain 后就是纯写死状态——报告一律用 `node.revision()` 覆盖读数，
## BlendSV 的 compose 递增写进字典却再没人读。键表、字典、合成行已一并删除。
##
## SPA 侧只补它自己才知道的键：`lifecycle_owner_path` / `rd_instance_id`，
## 以及 `ready` 的默认值（**缺席才补**——子类可在 _extend 钩子里按 GPU 真值先写）。
func ownership_report_entry() -> Dictionary:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	var entry := {
		"name": String(name),
		"owner_path": get_path() if is_inside_tree() else NodePath(),
		"revision": revision(),
		"resident": report_resident(),
		"direct_component_instance_id": get_instance_id(),
	}
	_extend_ownership_report_entry(entry)
	return entry


## 报告的 resident 位。默认「节点在即在场」（常驻卷的既有语义）；
## 一次性暂存卷（BlendSV：有内容才算在场）与状态由 GPU 侧回答的域（SVTile）覆写。
func report_resident() -> bool:
	return true


## 子类在这里追加域专属字段（SVTile 的 buffers 明细 / dirty_epoch / capacity），
## 也可先写 "ready" 这类基础键——SPA 侧只在缺席时补默认值，不覆盖。
func _extend_ownership_report_entry(_entry: Dictionary) -> void:
	pass


# ── 内容修订号 ───────────────────────────────────────────────────────────────

## 本域的内容修订号。消费方拿它做缓存键（GPU 缓冲复用、显示实例表失效等）。
func revision() -> int:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	return _revision


## 内容变了就调它。**只有内容真的变了才调**——空转递增会让所有消费方白重建一次缓存。
func bump_revision() -> int:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	_revision += 1
	return _revision


# ── 显示节点 ─────────────────────────────────────────────────────────────────

## 本域生成的显示节点叫什么。子类重写；返回空串 = 本域没有可视化
## （BlendSV 就是这一档：它是一次性混合暂存卷，画它等于画 SV ⊕ BrushSV 的重复，§1.6）。
func display_node_name() -> String:
	return ""


## 本域自建显示节点所属的分组名。清理时按组扫，所以每个域必须各自一份，
## 否则一个域的重建会把另一个域的节点一起 free 掉。
func generated_display_group() -> StringName:
	return StringName("meshfill_generated_display_%s" % domain_key())


## 清掉本域自建的显示节点。
##
## ⚠ 用 remove_child + free 而不是 queue_free：queue_free 要等帧尾才真正释放，
## 而节点在那之前**仍然占着名字**，紧接着重建的同名节点会拿到 "TargetSVVoxels2" 之类的
## 自动改名，于是所有按名字找节点的地方（缓存判定、可见性下发、ID pass 收集）全部错位。
## remove_child 立刻让出名字。同款写法见 target_sv_setup.gd 与 volume_score_demo.gd 的显示清理。
func clear_display_nodes() -> void:
	var group := generated_display_group()
	var node_name := display_node_name()
	for child in get_children():
		if child.is_in_group(group) or (not node_name.is_empty() and child.name == node_name):
			remove_child(child)
			child.free()


## 本域显示的默认开关值（NOTIFICATION_READY 时应用一次）。
## 高开销 / 高遮挡的域覆写为 false（SceneSV：10^6 实例 + 2×4 MiB 回读；
## SVTile：一个八面体罩 512 个体素，ID pass 按深度取胜 ⇒ 默认可见会让体素静默选不中）。
func default_display_visible() -> bool:
	return true


## 本域显示节点的可见性开关。
##
## ⚠ 名字刻意不是 `set_visible` / `is_visible`：那两个是 Node3D 的原生方法，GDScript 的
## NATIVE_METHOD_OVERRIDE 警告**默认就是 ERROR 级**（gdscript_warning.h:148），
## 重名会直接把 parse gate 与 -e 门禁打红。
##
## 语义：本方法只写"本域自己那份显示节点"的 visible。域**能不能被点中**不由它单独决定——
## 「可见性即准入」是 ID pass 的物理保证（画不出像素就没有 pick_id），不是一条要各处
## 记得检查的规矩（《点选统一》§5.2）。
func set_display_visible(value: bool) -> void:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	display_visible = value
	var nodes := display_nodes()
	if nodes.is_empty():
		if value:
			rebuild_display()
		return
	for node in nodes:
		node.visible = value


func is_display_visible() -> bool:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	var nodes := display_nodes()
	if nodes.is_empty():
		return display_visible
	# 多 drawable 域（anchor 的胜出实体按资产分 N 组）任一可见即算可见——
	# 它们由同一次 rebuild 一起建、一起翻，不会出现半可见状态。
	for node in nodes:
		if node.visible:
			return display_visible
	return false


## 本域已建显示对应的内容修订号；-1 = 还没建过 / 已作废。
var _built_revision := -1
## 建显示时喂给 shader 的**那一份**地形高度场。选中框摆位必须读同一份（见 getter）。
var _display_terrain_height := PackedFloat32Array()
## 紧凑实例表缓存 + 它对应的内容修订号（缓存键就是 `revision()`，§7.5）。
var _cached_instance_list := PackedInt32Array()
var _display_cache_revision := -1


## 重建本域的显示节点（**模板方法**，2026-08-10 收敛自四个子类的同款外壳）。
## 内容没变（`revision()` 未推进、节点还在、子类快照自检通过）就直接返回——
## SV 一次重建是 2 × 4 MiB 回读，不能白跑。
##
## ⚠ 子类**不要**重写本方法——重写会把外壳整个顶掉且不报错。要重写的是四个钩子：
##   * `_build_display_node()`：建出本域的 drawable（null = 本轮没东西可画）。
##     基类默认 null（无可视化域：BlendSV / 显示尚未迁入的 AutoObject）。
##   * `_display_cache_intact()`：修订号与节点之外的第三道早退守卫。SVTile 落地时实测过
##     「节点在、修订号没变、映射表却空了」的不一致——少这一道，强制重建都修不好。
##   * `_on_display_discarded()`：显示被丢弃时作废子类自己的快照（映射表 / 实例数）。
##   * `_on_display_built()`：建成后记录子类自己的快照。
##
## 登记 drawable 必须在 add_child **之后**：登记要校验 custom_aabb 与几何，
## 并把节点加进显示键组——组成员身份对不在树里的节点没有意义。
func rebuild_display() -> void:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	if not display_visible:
		_discard_display()
		# 隐藏是地形缓存的**唯一**批量失效点（重开显示时重采一份新的）。
		# ⚠ 刻意不放进 _discard_display()：重建路径也走它，而笔刷是**每笔一次重建**的
		# 热路径——放进去等于每笔落下都重采一遍地形网格。地形重烘焙不推进内容修订号，
		# 「隐藏时作废」是不引入热路径开销的最紧失效点；显示常开期间地形重烘焙的，
		# 关一次显示即取新（旧实现是**从不**失效，这仍是严格改进）。
		_display_terrain_height = PackedFloat32Array()
		return
	var current := revision()
	if _built_revision == current and not display_nodes().is_empty() and _display_cache_intact():
		return
	_discard_display()
	# 双守卫收进模板（曾在三个子类逐字重复 + 一处近似）：没有主设备就没有任何域建得出
	# MultiMesh 显示；不挂在 SPA 下（孤儿节点）则框架与数据源全部无从谈起。
	if RenderingServer.get_rendering_device() == null or scene_placement_actor() == null:
		return
	var drawables := _build_display_drawables()
	if drawables.is_empty():
		return
	for entry in drawables:
		var node = entry.get("node", null)
		if node == null or not is_instance_valid(node) or not (node is MultiMeshInstance3D):
			continue
		node.visible = display_visible
		add_child(node)
		# ⚠ 登记失败（几何为空 / custom_aabb 为空）已由登记口报明原因，节点**仍留在树上**：
		# 它要画出来，只是这一轮进不了 ID pass。
		register_pick_drawable(node, entry.get("key", null))
	_built_revision = current
	_on_display_built()


## 建本轮显示的全部 drawable，形状 `[{node: MultiMeshInstance3D, key: Variant}]`。
##
## 单内容域不必覆写：默认把 `_build_display_node()` + `_display_drawable_key()` 包成一条。
## **多 drawable 域**覆写本钩子——一个 `MultiMesh` 只能绑一个 mesh 资源，所以"同时画多种
## 资产"必然是多节点（anchor 的 winner 档：一个排名档下每种资产各一组）。
##
## ⚠ 每条自带 `key`：多 drawable 域的实例序只在**本条**内有意义，解码要靠 key 才能把
## `local_index` 还原成 anchor_index（见 `resolve_pick`）。共用一个 key 会串批。
func _build_display_drawables() -> Array[Dictionary]:
	var node := _build_display_node()
	if node == null or not is_instance_valid(node):
		return []
	return [{"node": node, "key": _display_drawable_key()}]


## 丢弃当前显示与它的配套快照（内建修订号、子类快照）。
##
## ⚠ **不清地形高度场**——那份缓存跨重建存活（惰性建一次，隐藏时作废，见 rebuild_display
## 的隐藏分支）。marker 与显示恒读同一份缓存，一致性不依赖失效时机。
func _discard_display() -> void:
	clear_display_nodes()
	_built_revision = -1
	_on_display_discarded()


## 建出本域这一轮的 drawable。子类重写；基类默认无可视化。
##
## ⚠ 每个域**只画一个** MultiMesh：一个 `MultiMesh` 只能绑一个 mesh 资源（Godot 硬约束），
## 所以"同时画多种 mesh"在本族里不成立——要看另一组就切过去（`AnchorVolume` 的 Shift+A
## 在胜出资产之间循环）。别为此让域自己 add_child 多个节点：那会绕开
## `register_pick_drawable()` 的三项校验与基类的显示生命周期管理，
## 而三种失败在界面上都表现为"这个域点不中"且零提示。
func _build_display_node() -> MultiMeshInstance3D:
	return null


## 登记本轮 drawable 时挂上的 `key`，原样透传给 `element_index_for_instance()`。
##
## 供**按内容分组**的域说明「现在画的是哪一组」——anchor 的胜出实体按资产分组，
## 一次画一组，靠这个 key 才能把实例序解回 anchor_index。
## 单一内容的域用不到（默认 null）。
func _display_drawable_key():
	return null


## 修订号与节点之外的第三道早退守卫（子类的显示快照是否仍然自洽）。
func _display_cache_intact() -> bool:
	return true


func _on_display_discarded() -> void:
	pass


## 显示建成后的钩子（子类在这里记自己的快照）。
## ⚠ 刻意无参：多 drawable 域一次建 N 个，传"那个节点"没有意义；
## 子类需要的是自己刚喂进去的数据，那本来就在成员上。
func _on_display_built() -> void:
	pass


## 本域的显示节点（可能为 null：还没建、或本域无可视化）。
##
## 公开是为了让消费方**不再按字面量节点名去查**。此前 `SPASelectionHost._apply_targetsv_visuals()`
## 就是硬编码 `"TargetSVVoxels"` 拿节点再写 `visible`，于是同一个 `visible` 有三个写入方
## （`rebuild_display()` / `set_display_visible()` / 那一处），谁最后写谁赢。
## ⚠ 拿到节点后**只该写显示态属性**（如 `transparency`）；`visible` 一律走
## `set_display_visible()`，否则又变回多写入方。
## 2026-08-14：`_apply_targetsv_visuals()` 已整个删除（grep 不到是正常的）。它改走
## `set_display_visible()` 之后仍是个**跨域**写入方——翻任意一个别的域的开关都会顺带把
## host 的记账位推给 TargetSV，而隐藏域没有显示节点、`set_display_visible(true)` 会走进
## `rebuild_display()`，于是「点 Anchors 显示 → TargetSV 自己冒出来」。域的显示只由
## `ScenePlacementActor.set_volume_display()` 一处驱动。
func display_node() -> Node3D:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	return _display_node()


func _display_node() -> Node3D:
	var node_name := display_node_name()
	if node_name.is_empty():
		return null
	return get_node_or_null(NodePath(node_name)) as Node3D


## 本域当前建出来的全部显示节点（按自建组扫，单 / 多 drawable 统一）。
##
## ⚠ 按**组**而不是按名字：多 drawable 域的节点名是内容派生的
## （anchor 的 `Winner_<资产序>_<资产名>`），没有一个固定名字可查；
## 而组名由 `generated_display_group()` 按域名派生，一个域的重建不会扫到另一个域。
func display_nodes() -> Array[Node3D]:
	var out: Array[Node3D] = []
	var group := generated_display_group()
	for child in get_children():
		if child is Node3D and child.is_in_group(group):
			out.append(child as Node3D)
	return out


# ── 显示几何推导（《计划》§2.5-9 / §2.5-10；2026-08-10 自 AutoVolumeField 上提）────
#
# 为什么在根而不是体积层：Field 与 Tile 两支的推导算式逐字相同（SVTileVolume 曾因
# 「AutoVolumeTile 拿不到 AutoVolumeField 的这两个方法」整段抄了一份），差异只有
# cell 的基准跨度（一格体素 vs 一块瓦片）。算式收在根、基准跨度做成钩子，两支共用。
# 元素空间寻址（element_*）仍然只在体积抽象层——本段是显示支持，不是体积语义。

## 显示 cell 相对一格元素的填充比，以及 cell 高度的下限（米）。
##
## ⚠ 这两个数此前散在三处、取值不同却谁也不知道对方存在（TargetSV 0.72/0.02、
## 笔刷 0.9/0.03、SVTile 0.9/0.05），且调用方都给 `VoxelDisplay` 传 `"fill": 1.0`
## 再各自在 cell 里乘系数——`VoxelDisplay.DEFAULT_FILL` 事实上被架空。
## 收进来之后系数仍按域覆盖，但算式只有一处。
##
## 下限存在的理由：网格 Y 方向的格距可以很薄，乘完填充比后会薄到看不见；
## 但**不能**用它反过来撑高 X/Z——那会让 cell 不再贴合元素包围盒，形状即域标识这条就废了。
const DEFAULT_DISPLAY_FILL_RATIO := 0.72
const DEFAULT_MIN_CELL_HEIGHT := 0.02


## 显示 cell 的基准跨度 = 一格元素的世界尺寸（未乘填充比）。
## 默认是一格体素；瓦片域覆写成一块瓦片的世界跨度（AutoVolumeTile）。
func display_cell_span() -> Vector3:
	var frame := grid_frame()
	if frame.is_empty():
		return Vector3.ZERO
	return frame["voxel_size"]


## 显示 cell 的尺寸。
## ⚠ 填充比乘在这里，喂给 `VoxelDisplay` 的 `options.fill` 必须是 1.0，否则乘两次。
func display_cell_size() -> Vector3:
	var span := display_cell_span()
	if span == Vector3.ZERO:
		return Vector3.ZERO
	var ratio := display_fill_ratio()
	return Vector3(
		span.x * ratio,
		maxf(span.y * ratio, min_cell_height()),
		span.z * ratio)


func display_fill_ratio() -> float:
	return DEFAULT_DISPLAY_FILL_RATIO


func min_cell_height() -> float:
	return DEFAULT_MIN_CELL_HEIGHT


## 地形相对带的高度跨度（米）。
##
## 网格 Y 自地形表面起算（《点选统一》§7.1 的 P0-A 裁决）⇒ 凡有显示的域，可见性盒都要
## 罩住这段抬升，否则贴在高处地形上的元素会被视锥剔除——表现是"高地上画不出也点不中"。
## 默认即全仓统一的地形带上限；按资产元数据声明跨度的域（TargetSV）覆写。
func display_height_span() -> float:
	return TerrainConfigScript.MAX_HEIGHT


## 本域显示侧的缩放。**不是**卷自己的坐标框架——框架恒为 SPA 那一份（§2.3），
## 这个数只用于显示铺开（TargetSV 的 display_scale 是它自己的 @export）。
func display_scale_value() -> float:
	return 1.0


## 本域显示的可见性盒（节点局部空间）。
##
## ⚠ 这段推导曾在 target_sv_setup.gd / meshfill_brush.gd / svtile_volume.gd 逐字重复，
## 连"不用端点式 capture_size——它少一格"这句注释都一样。它同时是 §2.5-3 那条
## `custom_aabb` 非空校验的配套：断言之外，这个盒子本身也该由基类算。
## 跨度按规范框架的 `grid * voxel_size` 算，**不用** capture_size：后者是端点式，
## 少一格，拿它当跨度会把盒子按 (N-1) 格铺开。
func display_aabb() -> AABB:
	var frame := grid_frame()
	if frame.is_empty():
		return AABB()
	var cell := display_cell_size()
	var extent := cell.x
	var span := VoxelGeneralScript.voxel_span_to_world_size(frame["grid_size"], frame["voxel_size"])
	var half := maxf(span.x, span.z) * 0.5 + extent
	# ⚠ Y 下界必须跟着 `grid_origin.y` 走，**不能**写死 -extent。
	# 实例位置是 `terrain + grid_origin.y + (slice+0.5)*voxel_size.y`（三个显示 shader 同式），
	# 地形最低处 terrain≈0 时最深的实例就落在 grid_origin.y 附近。2026-08-12 竖直量程
	# 带上地下段（grid_origin.y: 0 → -8）之后，写死的 -extent 已经装不下最底下两层，
	# 而 custom_aabb 装不下实例**不报错**——只在盒子被视锥剔除时整批实例跟着消失。
	# grid_origin.y ≥ 0 时 minf 取 0，与本行引入前逐位相同。
	var origin_y := minf(float((frame["grid_origin"] as Vector3).y), 0.0)
	var y_min := origin_y - extent
	var y_max := display_height_span() * display_scale_value() + span.y + extent
	return AABB(
		Vector3(-half, y_min, -half),
		Vector3(2.0 * half, (y_max + extent) - y_min, 2.0 * half))


# ── 显示用地形高度场（2026-08-10 收敛自 SceneSV / SVTile / BrushSV 三份逐字重复）────

## 建显示时喂给 shader 的**那一份**地形高度场（世界单位，索引 `z * grid.x + x`）。
## 选中框摆位必须读它，不许自己再采一次。
##
## ⚠ 别拿 `SPASelectionHost.sample_height()` 顶：那张表是 **128 分辨率、端点式**索引
## （`px = int(((wx/capture)+0.5)*(res-1))`），而本场是 **grid.x 分辨率、格序式**。
## 两张表在斜坡上会差一整个高度场格子的起伏——表现是选中框与显示错位，
## 而两个数都合法、都不报错。
##
## 空 = 本场景确实没有地形（合法），或显示还没建过（此处惰性补算一次——
## `select_data_voxel()` 这类桥入口可以在显示从未建过时问坐标，返回空场会让 marker
## 少掉整段地形抬升且零提示）。失效点是**隐藏显示**（rebuild_display 的隐藏分支）：
## 重建路径刻意不清它——笔刷每笔一次重建，清了就是每笔重采一遍地形网格。
## 「marker 与显示读同一份」由缓存本身保证，不依赖失效时机。
func display_terrain_height_field() -> PackedFloat32Array:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	if _display_terrain_height.is_empty():
		_display_terrain_height = _build_terrain_height_field()
	return _display_terrain_height


## 地形高度场的唯一算式。分辨率取规范网格的 X 边（消费侧 shader 与 marker 都按
## `z * grid.x + x` 索引），跨度取 `display_height_span()`。
##
## 长度对不上（XZ 非方形：高度场按 grid.x 边长的方形重采样）⇒ 整体当作无地形：
## **不能半用**——那会让一部分元素贴地、另一部分悬在 y=0。
## ⚠ 只 push_error 不 assert：XZ 非方形是**配置**状态，不是调用方违约，
## 在编辑器里断言就是当场打死（SVTileVolume 落地时实测过）。
func _build_terrain_height_field() -> PackedFloat32Array:
	var terrain := TerrainInitializerScript.find_edit_time_terrain(self) as MeshInstance3D
	if terrain == null or terrain.mesh == null:
		return PackedFloat32Array()
	var frame := grid_frame()
	if frame.is_empty():
		return PackedFloat32Array()
	var grid: Vector3i = frame["grid_size"]
	var field := TerrainInitializerScript.terrain_height_field_from_mesh(
		terrain, grid.x, display_height_span())
	if field.size() != grid.x * grid.z:
		push_error("[%s] 地形高度场长度 %d 与网格 XZ 体素数 %d（%d × %d）不符 —— 高度场按 grid.x 边长的方形重采样，XZ 不等长时索引式 z*grid.x+x 会整体错位。本轮按无地形处理，而不是一半贴地一半悬空。" % [
			_log_name(), field.size(), grid.x * grid.z, grid.x, grid.z])
		return PackedFloat32Array()
	return field


# ── 点选：drawable 登记 ──────────────────────────────────────────────────────

## 把一个 `MultiMeshInstance3D` 登记成本域的可拾取 drawable，一次完成三件事：
## 挂载载荷解码口（PICK_DRAWABLE_META）、加入本域的显示键组、校验它进得了 ID pass。
##
## 收编的是四处散点 `set_meta(PICK_DRAWABLE_META, …)`（target_sv_setup.gd:198、
## volume_score_demo.gd:2239 / :2483 / :2764）。那四处里有两处是**分两句**写 meta 与
## 显示键组的，漏一句的表现是"这个域怎么点都点不中"且零提示。
##
## 解码口固定为本类的 `resolve_pick(key, local_index)`；`key` 原样回传，是不透明值
## （族内恒为 null，族外 drawable 用它带 batch_index / anchor_index 之类的自有句柄）。
##
## ── 为什么这些校验必须在登记时做，而不是等 pass 侧报 ──────────────────────
## `PickIdPass.prepare()` 对不合格 drawable 全部是**静默跳过**（只记进 skipped 数组，
## 只有"entry 不是 Dictionary"才报错）。custom_aabb 为空、instance_count == 0、
## 解码口方法名写错——三种都表现为"这个域点不中"，界面上看不出任何原因。
func register_pick_drawable(node: MultiMeshInstance3D, key: Variant = null) -> bool:
	# 解码口固定是本类的 `resolve_pick`（零派生的唯一实现）。此前它是调用方传进来的
	# 字符串参数——四个域各传一份同样的 "resolve_pick"，属最后一点字符串契约残留。
	# ⚠ 族外 drawable（`PlacedInstanceDisplay` 的容器形态、demo 手搓的 anchor 节点）
	# 不走本函数，它们自己 `set_meta` 并挂各自的方法名，不受这条约束。
	var resolve_method := "resolve_pick"
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	if node == null or not is_instance_valid(node):
		push_error("[%s] register_pick_drawable: node 为空 —— 本域在 ID pass 里会静默缺席。" % _log_name())
		assert(false, "PickableDomain.register_pick_drawable: null node")
		return false
	if not has_method(resolve_method):
		push_error("[%s] register_pick_drawable: 载荷解码口 \"%s\" 在本域上不存在（node=%s）—— 命中后解不出载荷，PickIdPass 会报 no_payload_resolver。" % [
			_log_name(), resolve_method, node.name])
		assert(false, "PickableDomain.register_pick_drawable: resolve method missing on domain")
		return false
	var mm := node.multimesh
	if mm == null or mm.mesh == null or mm.instance_count <= 0:
		push_error("[%s] register_pick_drawable: \"%s\" 没有可画的几何（multimesh=%s, mesh=%s, instance_count=%d）—— PickIdPass 会静默跳过它。" % [
			_log_name(), node.name, str(mm != null),
			str(mm != null and mm.mesh != null), mm.instance_count if mm != null else -1])
		assert(false, "PickableDomain.register_pick_drawable: drawable has no geometry")
		return false
	# custom_aabb 为空 ⇒ 整批实例被视锥剔除；镜像节点照抄源节点的 custom_aabb，
	# 所以显示端与 ID 端会一起消失。这是《AutoVolume 公用体积基类计划》§2.5-3 那条校验的落点。
	if node.custom_aabb.size == Vector3.ZERO:
		push_error("[%s] register_pick_drawable: \"%s\" 的 custom_aabb 为空 —— 整批实例会被剔除，画不出也点不中。" % [
			_log_name(), node.name])
		assert(false, "PickableDomain.register_pick_drawable: empty custom_aabb")
		return false
	if not participates_in_picking():
		push_error("[%s] register_pick_drawable: 本卷声明了 participates_in_picking() == false 却仍在登记 drawable（node=%s）—— 两者必有一处是错的。" % [
			_log_name(), node.name])
		assert(false, "PickableDomain.register_pick_drawable: non-pickable domain registering a drawable")
		return false
	var key_name := display_key()
	if key_name.is_empty():
		# domain_binding() 已经报过具体原因，这里只拦住"接着往下走"。
		return false
	node.set_meta(SPAEditorContractScript.PICK_DRAWABLE_META, {
		"source": self, "resolve_method": resolve_method, "key": key,
	})
	node.add_to_group(SPAEditorContractScript.voxel_display_group(key_name))
	node.add_to_group(generated_display_group())
	return true


## 实例序越界的统一失败载荷（各域 `resolve_pick` 的共用分支，字段与 reason 一字不差）。
func _pick_index_error(local_index: int, instance_count: int) -> Dictionary:
	return {"ok": false, "reason": "instance_index_out_of_range",
		"local_index": local_index, "instance_count": instance_count}


## ID 拾取载荷解码的**唯一实现**（2026-08-10 起零派生）。
##
## 点选只回答一件事：**选中了哪个域的哪个元素**。坐标、覆盖范围、绘制属性一概不进载荷——
## 消费方拿 `source`（`PickIdPass` 随命中带出的域节点）去问该域自己的成员：
## `element_to_voxel()` / `voxel_range_of()` / `paint_attributes_for_element()`。
## 那些方法本来就是元素空间层的多态接口，让载荷再复述一遍就是第二份表示。
##
## ⚠ 此前四个域各写一份 `resolve_pick`（越界守卫逐字重复、载荷字段各不相同），
## 而它们的差异其实只有「实例序怎么变成元素下标」——紧凑显示走映射表、全量显示是恒等，
## 这一步已经由 `display_is_compact()` + `get_instance_list()` 表达。⇒ 全部删除。
##
## ⚠ 子类**不要**重写本方法。要改的是那两个声明钩子，或元素空间层的寻址方法。
## 族外 drawable（`PlacedInstanceDisplay` 的容器形态）自己 `set_meta` 挂各自的方法名，
## 不走本实现。
##
## `key` 是登记 drawable 时给的那一份，原样透传给寻址钩子——多 drawable 域靠它分辨
## 「命中的是哪一组」（anchor 的胜出实体按资产分 N 组，每组一张自己的元素表）。
func resolve_pick(key, local_index: int) -> Dictionary:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	var count := displayed_instance_count(key)
	if local_index < 0 or local_index >= count:
		return _pick_index_error(local_index, count)
	var element_index := element_index_for_instance(key, local_index)
	if element_index < 0:
		# 实例序在范围内却解不出元素 = 显示与映射表不同源，属本域自身坏了。
		return {"ok": false, "reason": "element_index_undecodable",
			"local_index": local_index, "instance_count": count}
	return {
		"ok": true, "reason": "ok",
		"domain": domain_key(),
		"element_index": element_index,
	}


## 本域的显示是不是**紧凑**的（只画非空元素，实例序经映射表解回元素下标）。
##
## 返回 false = 全量铺开、实例序**即**元素下标（TargetSV today：`build_field_gpu` 按
## `voxel_count` 整网格铺，空格在 shader 里塌成零基向量）。
## ⚠ 这个声明**不只是**优化开关：全量域上物化一张恒等映射表是 10^6 次 GDScript 循环
## （`AutoVolumeField.build_compact_instance_list` 的回退实现），每次点击跑一遍。
func display_is_compact() -> bool:
	return true


## 已画出的实例数 = pick 的合法 `local_index` 上界。
## 紧凑域即映射表长度；全量域覆写为元素总数。
## `key` = 登记该 drawable 时给的那一份（多 drawable 域按组各有各的实例数）。
func displayed_instance_count(_key = null) -> int:
	return get_instance_list().size()


## 实例序 → 元素下标。紧凑域查映射表，全量域是恒等。
## 越界或表不同源返回 -1（不钳到末元素——那会把一次坏掉的解码伪装成"选中了最后一个"）。
## `key` 同上：多 drawable 域按它选对应那一组的表。
func element_index_for_instance(_key, local_index: int) -> int:
	if not display_is_compact():
		return local_index
	var list := get_instance_list()
	return list[local_index] if local_index >= 0 and local_index < list.size() else -1


# ── 紧凑实例表 + 修订号驱动的缓存失效（§2.5-5 / §2.5-8；2026-08-10 自 AutoVolumeField 上提）──
#
# 上提理由：Tile 支同样需要「只画非空元素 + 实例序→元素下标映射表」（SVTile 曾因够不着
# Field 的这套而在叶子上自建 `_instance_tile_index` + 两个守卫钩子 + 软重载连带——功能同构、
# 写法三样）。缓存住根类后，映射表按 `revision()` 确定性重建，"表丢了"不再是一种要
# 单独防御的状态。

## 本域这一帧要画的实例列表（元素下标）。按内容修订号缓存，内容没变就不重算。
##
## ⚠ 紧凑显示不只是省显存。`PickIdPass` 按 `mm.instance_count`（**容量**，不是存活数）
## 整段分配 24 位 pick_id 区间——全量注册会一口吃掉 ID 空间的一大块。
func get_instance_list() -> PackedInt32Array:
	_repair_soft_reloaded_members()   # 软重载新增成员为 nil，见 _repair_soft_reloaded_members()
	var current := revision()
	if _display_cache_revision != current:
		_cached_instance_list = build_compact_instance_list()
		_display_cache_revision = current
	return _cached_instance_list


## 扫出要画的元素下标。根类默认**空表**（= 本域没有紧凑显示这回事）；
## 体素支在 `AutoVolumeField` 覆写为全网格回退，各域再按数据源特化
## （SceneSV 读瓦片摘要、SVTile 列非空砖、Brush 列画过的格子）。
func build_compact_instance_list() -> PackedInt32Array:
	return PackedInt32Array()


# ── 软重载自愈 ───────────────────────────────────────────────────────────────

# ⚠ 编辑器软重载（@tool 脚本重新解析）后的成员修复，别当成冗余判空删掉。
# 事实依据（gdscript.cpp GDScriptInstance::reload_members）：软重载只把**重载前已存在**的
# 成员按名字搬进新槽位；本次重载**新增**的成员槽是默认构造的 Variant = nil，声明里的
# 初始化器不会重跑，静态类型也拦不住（实例槽本身是 Variant）。
#
# ⚠ 必须用 `is` 而不是 `== null`：Variant 给 (INT, NIL) / (OBJECT, NIL) 这类组合注册的是
# OperatorEvaluatorAlwaysFalse（variant_op.cpp），静态类型已知时 `== null` 会被编成恒 false，
# 判空形同虚设。
#
# ⚠ `_revision` 的修复值刻意**不是** 0。本修订号会进消费方的缓存键，而那些消费方可能没跟着
# 一起重载、仍缓存着重载前发出的小整数。从 0 重数会重新发出用过的值，让对端误判"内容没变"
# 而复用旧 GPU 缓冲。用 ticks_usec 播种即可跳出旧计数区间，之后照旧单调 +1。
# 这条规则是从 target_sv_setup.gd 的 _repair_soft_reloaded_content_revision() 提上来的。
#
# ⚠ 子类**不要**重写本方法——重写会把基类这半段整个顶掉，而且不报错。
# 子类要修自己的成员就重写 `_repair_soft_reloaded_domain_members()`，本方法末尾会调它。
# 这个"模板方法"形状是刻意的：它让"忘了调 super"这个失败模式从结构上不存在。
func _repair_soft_reloaded_members() -> void:
	if not (_revision is int): _revision = Time.get_ticks_usec()
	if not (display_visible is bool): display_visible = true
	# _cached_spa 是 Object 槽：nil 与"还没解析过"本来就是同一个状态，回填 null 即可，
	# 下一次 scene_placement_actor() 会重解析。
	if not (_cached_spa is ScenePlacementActor): _cached_spa = null
	if not (_built_revision is int): _built_revision = -1
	# 语义连带：显示用的地形高度场丢了，marker 会惰性重采一份，而当前显示用的仍是
	# 重载前那一份——地形若被重烘焙，两者不同。把 _built_revision 一并推回 -1
	# 逼一次重建，保住「marker 与显示读同一份」这条不变量。
	if not (_display_terrain_height is PackedFloat32Array):
		_display_terrain_height = PackedFloat32Array()
		_built_revision = -1
	# 同款连带：紧凑实例表与它的修订号是一对；表丢了还把 _built_revision 一并推回 -1
	# 逼一次显示重建（此前 SVTile 在叶子上自修这条、SceneSV 漏了——审计点名的三域三种
	# 可靠性就是这里，收进根类后对全体域一致成立）。
	var cache_lost := not (_cached_instance_list is PackedInt32Array)
	if cache_lost: _cached_instance_list = PackedInt32Array()
	if not (_display_cache_revision is int) or cache_lost:
		_display_cache_revision = -1
		_built_revision = -1
	_repair_soft_reloaded_domain_members()


## 子类在这里修自己新增的成员。基类默认空实现。
##
## ⚠ 回填要处理**语义连带**，不是逐个塞空值就完事：若本域持有 GPU buffer RID 与对应的
## "已上传版本号"，RID 归零时必须把版本号一并作废，否则会出现"buffer 没了但版本号说已上传"。
## 范本见 auto_voxel_runtime_profile_container.gd 的 staging_lost 分支。
func _repair_soft_reloaded_domain_members() -> void:
	pass


## 日志前缀。子类不必重写——默认取脚本类名，已经足够定位。
func _log_name() -> String:
	# ⚠ 必须显式标注 Script：get_script() 的返回类型是 Variant，写成 `:=` 会触发
	# INFERENCE_ON_VARIANT ——这条警告在引擎默认表里是 **ERROR 级**
	# （gdscript_warning.h:147），直接把 parse gate 与 -e 门禁打红。
	var script_ref: Script = get_script()
	if script_ref != null:
		var global_name := str(script_ref.get_global_name())
		if not global_name.is_empty():
			return global_name
	return "PickableDomain"
