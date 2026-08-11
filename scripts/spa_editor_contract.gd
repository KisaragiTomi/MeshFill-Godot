@tool
class_name SPAEditorContract
extends RefCounted

# ⚠ 这里曾有 `MODE_MIXED` / `MODE_AUTOOBJECT` / `MODE_SVTILE` / `MODE_ANCHOR` / `MODE_SV` /
# `MODE_TARGETSV` / `MODE_DISPLAY_ONLY` 七个模式号，外加一张 `SELECTION_MODE_NAMES`
# 「模式号 → 可读名」表。**用户 2026-08-10 裁定：选择模式概念整体退役，域标识只用域名字符串。**
#
# 状态机（"当前是哪个模式"）在 2026-08-07 就删了，模式号自那以后只兼着**数据域标识**：
# Callable 分派表的键、`binding_for_mode()` 的入参、`DATA_PICK_MODE_PREFERENCE` 的元素。
# 于是同一个域有**两个**身份——`MODE_ANCHOR`(3) 与 `SELECTION_DOMAIN_ANCHOR`("anchor")，
# 两张查表函数（`binding_for_mode` / `binding_for_domain`）指向同一行绑定。代价是实打实的：
# 加一个域要在两套编号里各排一次，而 `int` 键在 GDScript 里静默兼容任何整数，
# 传错域号（比如把显示键的下标当模式号）不会报错，只会静默点中另一个域。
#
# ⇒ 域的唯一标识是下面的 `SELECTION_DOMAIN_*` 字符串。可读名归绑定表的 `domain_label`。
# 「参不参与点选」由「有没有进 `SPASelectionHost.PICK_ID_DISPLAY_KEYS`」决定，不再需要哨兵模式号。

# ⚠ 这里曾有 `SELECTION_RETENTION_CLEAR` / `SELECTION_RETENTION_PRESERVE`：模式切换时
# 「清掉还是保留当前选中」的策略。选择模式退役后没有模式切换这件事，两个常量连同
# `normalize_selection_retention()` / `selection_retention_name()` /
# `make_selection_mode_transition()` 一起删除（全仓零剩余消费者）。

const SELECTION_DOMAIN_AUTOOBJECT := "autoobject"
const SELECTION_DOMAIN_SVTILE := "svtile"
const SELECTION_DOMAIN_ANCHOR := "anchor"
const SELECTION_DOMAIN_SV := "sv"
const SELECTION_DOMAIN_TARGETSV := "targetsv"
const SELECTION_DOMAIN_BRUSH := "brush"

const SELECTION_GEOMETRY_TRIANGLE := "triangle"
const SELECTION_GEOMETRY_VOXEL := "voxel"
const SELECTION_GEOMETRY_AUTOOBJECT := "autoobject"
const SELECTION_GEOMETRY_VOLUME_SCORE_ANCHOR := "volume_score_anchor"

const EXTERNAL_VOXEL_DISPLAY_ROOT_NAME := "ExternalVoxelDisplays"
const EXTERNAL_VOXEL_DISPLAY_GROUP_PREFIX := "meshfill_voxel_display_"
const VOXEL_DISPLAY_GPU_OBJECTS := "gpu_objects"
const VOXEL_DISPLAY_SVTILE := "svtile"
const VOXEL_DISPLAY_ANCHOR := "anchor"
const VOXEL_DISPLAY_SV := "sv"
const VOXEL_DISPLAY_TARGETSV := "targetsv"
const VOXEL_DISPLAY_BRUSH := "brush"

## ⚠ 这里曾有一张 `VOXEL_DISPLAY_KEYS` 键表，注释自承「零消费者」，理由是
## 「一份漏项的键表比没有键表更误导：它看起来像事实源」。
##
## 那条理由是自相矛盾的：**没人读的表不可能被可靠地保持同步**——它本身就是那个"看起来像
## 事实源"的误导物。显示键的唯一事实源是下面的 `VOXEL_DOMAIN_BINDINGS`
## （`default_voxel_display_state()` 迭代的就是它）。已删除。
const VOXEL_DOMAIN_BINDINGS := [
	{
		"domain": SELECTION_DOMAIN_AUTOOBJECT,
		"key": VOXEL_DISPLAY_GPU_OBJECTS,
		"display_key": VOXEL_DISPLAY_GPU_OBJECTS,
		"label": "GO",
		"domain_label": "AutoObject",
		"tooltip": "GPU Objects: enable AutoObject inspection and selection markers",
		"requires_sv_committer": false,
	},
	{
		"domain": SELECTION_DOMAIN_SVTILE,
		"key": VOXEL_DISPLAY_SVTILE,
		"display_key": VOXEL_DISPLAY_SVTILE,
		"label": "ST",
		"domain_label": "SVTile",
		"tooltip": "SV Tiles: show SceneVoxelTile heatmap blocks",
		"requires_sv_committer": true,
	},
	{
		"domain": SELECTION_DOMAIN_ANCHOR,
		"key": VOXEL_DISPLAY_ANCHOR,
		"display_key": VOXEL_DISPLAY_ANCHOR,
		"label": "A",
		"domain_label": "Anchor",
		"tooltip": "Anchors: show Anchor selection markers and labels",
		"requires_sv_committer": true,
	},
	{
		"domain": SELECTION_DOMAIN_SV,
		"key": VOXEL_DISPLAY_SV,
		"display_key": VOXEL_DISPLAY_SV,
		"label": "SV",
		"domain_label": "SV",
		"tooltip": "Scene Voxels: show SceneVoxel selection markers and labels",
		"requires_sv_committer": true,
	},
	{
		"domain": SELECTION_DOMAIN_TARGETSV,
		"key": VOXEL_DISPLAY_TARGETSV,
		"display_key": VOXEL_DISPLAY_TARGETSV,
		"label": "TSV",
		"domain_label": "TargetSV",
		"tooltip": "Target SV: show TargetSV voxel display and selection markers",
		"requires_sv_committer": false,
	},
	{
		# BrushSV：与其余五域同路的完整可点选域（2026-08-10 切 ID 路，此前是
		# "画得出、点不中"的纯显示域）。内容 / 显示 / 落笔定位在 `BrushSVVolume`
		# （SPA/Volumes/BrushSV），drawable 经基类 `register_pick_drawable()` 登记，
		# 在 `SPASelectionHost.PICK_ID_DISPLAY_KEYS` 里被收集；记录构建走
		# `_pick_id_commit_hit` 的 brush 分支（`_brush_record_for_voxel`），
		# 故 `record_method` 保持空串——ID 路不经这张表派发。
		# ⚠ 这条此前另带一个 `mode: MODE_DISPLAY_ONLY` 哨兵，专为绕开模式号校验而存在；
		# 模式号整体退役（2026-08-10）后哨兵一起删除。
		"domain": SELECTION_DOMAIN_BRUSH,
		"key": VOXEL_DISPLAY_BRUSH,
		"display_key": VOXEL_DISPLAY_BRUSH,
		"label": "BR",
		"domain_label": "Brush",
		"tooltip": "Brush SV: show painted brush voxels",
		"requires_sv_committer": false,
	},
]
## ⚠ 这里曾有 `VOXEL_DISPLAY_DEFINITIONS := VOXEL_DOMAIN_BINDINGS` —— 一个零消费者的别名。
## 同一张表两个名字，只会让读者以为它们是两样东西。已删除，一律用 VOXEL_DOMAIN_BINDINGS。
# ⚠ 这里曾有 `DATA_PICK_DOMAIN_PREFERENCE`（旧名 `DATA_PICK_MODE_PREFERENCE` /
# `MIXED_DATA_PICK_MODES`）：TargetSV → SVTile → SV 的**偏好顺序**。它存在的前提是
# 「这三个域都从同一条地形射线取值、屏幕距离恒等，无法按距离互比，只能定一个偏好」。
# 三角形 ID 成为唯一命中方式后（2026-08-10）没有那条射线了 —— 三个域各自画在自己的位置上，
# **深度测试即仲裁**，谁挡在前面选谁。偏好顺序连同 `data_pick_domains()` 一起删除。
# ⚠ 这里曾有 `SVTILE_OVERLAY_FOCUS_MODES`：demo 的 SVTile 叠加层在哪几个模式下**不淡化**。
# 淡化随选择模式一起退役（恒不淡化），此表零消费者，已删除。

## 域名 → 可读名（HUD / 诊断载荷 / 报告文案）。
## ⚠ 旧名 `selection_mode_name(mode: int)`，读的是那张已删除的 `SELECTION_MODE_NAMES`。
## 未登记的域名是调用方的 bug：旧行为返回 "Unknown"，把一次坏掉的域派发伪装成
## "名字没查到"，报告里看不出派发已经跑飞。这里照旧判死。
static func domain_label(domain: String) -> String:
	var binding := binding_for_domain(domain)
	if not binding.is_empty():
		return str(binding.get("domain_label", domain))
	push_error("[SPA Selection] domain_label: 域名 \"%s\" 不在 VOXEL_DOMAIN_BINDINGS 里。" % domain)
	assert(false, "[SPA Selection] domain_label: unknown domain")
	return "Unknown"



static func binding_for_domain(domain: String) -> Dictionary:
	for raw_binding in VOXEL_DOMAIN_BINDINGS:
		var binding: Dictionary = raw_binding
		if str(binding.get("domain", "")) == domain:
			return binding.duplicate(true)
	return {}


static func binding_for_display_key(display_key: String) -> Dictionary:
	for raw_binding in VOXEL_DOMAIN_BINDINGS:
		var binding: Dictionary = raw_binding
		if str(binding.get("display_key", binding.get("key", ""))) == display_key:
			return binding.duplicate(true)
	return {}


static func default_voxel_display_state() -> Dictionary:
	var state := {}
	for raw_binding in VOXEL_DOMAIN_BINDINGS:
		var binding: Dictionary = raw_binding
		var display_key := str(binding.get("display_key", binding.get("key", "")))
		if not display_key.is_empty():
			state[display_key] = true
	return state


static func voxel_display_key_for_domain(domain: String) -> String:
	var binding := binding_for_domain(domain)
	return str(binding.get("display_key", binding.get("key", "")))


static func domain_requires_scene_voxel_committer(domain: String) -> bool:
	var binding := binding_for_domain(domain)
	return bool(binding.get("requires_sv_committer", false))


# ⚠ 这里曾有 `mode_is_active()` / `mode_focuses_display_key()` / `mode_in_list()`。
# 用户 2026-08-07 裁定：**除 Mixed 外的选择模式整体退役，准入只看 `visible`**
# ⇒ 三者的第一参恒为 MODE_MIXED ⇒ 三者恒返回 true，全部删除。
#
# 它们此前的真实危害不是冗余，是**给同一个开关造了第二个来源**：
# `mode_focuses_display_key` 被当时的 `_voxel_display_effective_visible()` 与显示开关相与，
# 而「可视化即拾取几何」下隐藏 = 选不中 ⇒ "复选框开着却选不中"和"切个模式笔刷不见了"
# 两种反直觉都出现过，界面上都看不出原因。
# ⚠ 相与的那一端删掉后，`_voxel_display_effective_visible()` 只剩一次转发，已于 2026-08-11
# 与它的两个公开包装一起删除；显示开关的唯一读口是 `SPASelectionHost._voxel_display_is_visible()`。


# ⚠ 这里曾有 `selection_mode_from_keycode()`（Shift+0..5 切选择模式）。
# 选择模式退役后没有可切的状态，连同 `SPASelectionHost._handle_editor_key()` 里那段一起删。


static func external_voxel_display_owner_name(owner_key: String) -> String:
	var key := owner_key.strip_edges()
	if key.is_empty():
		key = "external"
	key = key.replace("/", "_")
	key = key.replace("\\", "_")
	key = key.replace(":", "_")
	key = key.replace(" ", "_")
	return "%s_%s" % [EXTERNAL_VOXEL_DISPLAY_ROOT_NAME, key]


static func voxel_display_group(display_key: String) -> String:
	return "%s%s" % [EXTERNAL_VOXEL_DISPLAY_GROUP_PREFIX, display_key]


## 三角形 ID 拾取：单个 `MultiMeshInstance3D` 上挂载载荷解码口的元数据键。
##
## 值形如 `{source: Object, resolve_method: String, key: Variant}`，
## `source.call(resolve_method, key, local_index)` 把「第几个 MultiMesh 实例」解成域载荷。
##
## ⚠ 这是**临时最小形态**：drawable 模块合并（统一登记器）另案，见
## 《可视化drawable统一评估》§6。在那之前，没有脚本的裸 MultiMeshInstance3D
## （AnchorPoints / Winner_* 这类手搓建造点）靠这条元数据接入 ID pass。
const PICK_DRAWABLE_META := "meshfill_pick_drawable"


# ⚠ 这里曾有 `pick_volume_score_anchor()`（64 行：AABB 射线求交 + 小球半径回退两段命中算法）。
# 它是旧点选路的 anchor 命中器；旧路删除（2026-08-10，三角形 ID 唯一路）时调用点一并消失，
# 成为新鲜死码——anchor 命中现在由 ID pass + `AnchorPoints` / `Winner_*` drawable 完成。已删除。


## 启动自检：域名 / 显示键必须齐全且不重复。宿主（SPASelectionHost）加载时逐条校验，
## 缺失即 push_error，让 -e 加载立刻暴露断掉的绑定。
static func validate_domain_bindings(host: Object) -> void:
	if host == null:
		# 静默跳过自检 = 本函数存在的唯一目的落空：断掉的 pick/record 绑定会以
		# “静默死点击”的形式留到运行时。
		push_error("[SPA Selection] validate_domain_bindings: host 为 null —— 合同绑定自检被整体跳过。")
		assert(false, "[SPA Selection] validate_domain_bindings: host == null")
		return
	var registered_domains := {}
	var registered_display_keys := {}
	for raw_binding in VOXEL_DOMAIN_BINDINGS:
		var binding: Dictionary = raw_binding
		var domain := str(binding.get("domain", ""))
		var display_key := str(binding.get("display_key", binding.get("key", "")))
		if domain.is_empty() or display_key.is_empty():
			push_error("[SPA Selection] domain binding requires domain and display_key: %s" % str(binding))
		if registered_domains.has(domain):
			push_error("[SPA Selection] duplicate domain binding: %s" % domain)
		if registered_display_keys.has(display_key):
			push_error("[SPA Selection] duplicate display binding: %s" % display_key)
		registered_domains[domain] = true
		registered_display_keys[display_key] = true
		# ⚠ 这里曾先后校验 `pick_method`（旧路命中算法名，随三角形 ID 唯一路删除）与
		# `record_method`（载荷 → 选择记录）。后者的字符串已整列删除（2026-08-10）：
		# 真实派发是 `SPASelectionHost._ensure_selection_callables()` 的**直接方法引用**表
		# （改名/手误在解析期就是 "Identifier not found"），契约字符串只喂本自检——
		# 一份要手工同步、只为验证另一份的镜像，本身就是要清的第二份。


## ⚠ 上面曾有四个零消费者的静态访问器：`selection_domain_for_mode` /
## `selection_mode_for_domain` / `data_pick_method_for_mode` / `data_record_method_for_mode`。
## 它们都只是 `binding_for_domain()` 取一个键的一行包装，全仓无人调用。
## 真实的域派发走 `SPASelectionHost._ensure_selection_callables()` 的 Callable 表，
## 与契约表里的 `pick_method` / `record_method` 字符串是**两份**（后者只被
## `validate_domain_bindings()` 用来做 has_method 自检）。已删除。
