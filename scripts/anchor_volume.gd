@tool
class_name AnchorVolume
extends "res://scripts/auto_volume_anchor.gd"

## `SPA/Volumes/Anchor` 的节点脚本（《AutoVolume 公用体积基类计划》V4）。
##
## ── 三档可视化，**互斥**（2026-08-10 落地；计划 §1.3 的设计意图此前只实现了一半）───
## | 档 | 画什么 | 说明 |
## | MARKER | 锚点小球 | 评分阶段的定位标记，一个 MultiMesh 罩全部锚点 |
## | WINNER | 胜出实体 | 每个资产一组，用**资产自己的真实 mesh**（CLAUDE.md 明令不得用代理形状） |
## | PROFILE | 观察态体素盒 | 选中锚点的胜出者 voxel profile（原 Ctrl+H） |
##
## ⚠ 切换前的实况是「小球 + 胜出实体**同时**显示」，Ctrl+H 只额外隐藏胜出实体、
## 并刻意保留小球做定位上下文（`_set_winner_meshes_visible` 的注释）。所以从来没有
## 「只有一种」的状态，三个 `visible` 写入方也因此互相覆盖。现在当前档是**单一状态**，
## 切档 = 丢弃旧档全部节点 + 建新档 ⇒ 可见性只剩基类一个写入方。
##
## ── 显示归属在本节点，数据与建造仍在 demo（provider 契约）─────────────────────
## 三条 drawable 的**生命周期与登记**由基类模板管（`rebuild_display()` /
## `clear_display_nodes()` 按组清 / `register_pick_drawable()` 三项校验），
## 而"怎么算胜出变换、怎么按资产分组、怎么做视距剔除"仍住在 `volume_score_demo.gd`
## ——那些依赖评分模型（`_model` / `_assets` / `FineSelection`），搬进 SPA 是另一件事
## （审计标的"路线决策"档）。本类经三个 provider 方法取用：
##   * `build_anchor_drawables(mode, rank) -> Array[{node, key}]`（**不** add_child，由本类挂载）
##   * `anchor_element_for_drawable(key, local_index) -> int`（实例序 → anchor_index，
##     winner 档含视距剔除的压缩表）
##   * `anchor_winner_rank_count() -> int`（winner 档可切的排名档数）
##
## ── ⚠ 修订号是**读**不是**持有** ────────────────────────────────────────────
## `revision()` 转发 SPA 的 `_anchor_revision`，语义是「RID 失效/交接」——时序约束的
## 执行者是同时持有借出方与借入方的 SPA，不是本域。读它是对的，搬进来是错的。
## ⚠ 因此**档位切换不能靠修订号驱动重建**：切档不改交接号，基类早退守卫会跳过重建。
## `set_display_mode()` 显式走 `_discard_display()` + `rebuild_display()`。

## 三档。⚠ 顺序即 Shift+S 的循环顺序。
enum DisplayMode { WINNER, MARKER, PROFILE }

## provider 契约的方法名（`SPA/Volumes/VolumeScore`）。缺任一即本域无可视化，如实报错。
const PROVIDER_BUILD_METHOD := "build_anchor_drawables"
const PROVIDER_ELEMENT_METHOD := "anchor_element_for_drawable"
## winner 档可切的排名档数（= 全场任一锚点拥有的最多有效候选数，上限 topk）。
const PROVIDER_RANKS_METHOD := "anchor_winner_rank_count"
## 按需补齐逐锚点 top-K（交互 Score 只回读 winner 一份，见 cycle_winner_rank 的说明）。
const PROVIDER_ENSURE_RANKS_METHOD := "ensure_winner_rank_data"

## 档位 → provider 认的字符串（跨脚本传枚举要两边同步常量，传字符串只需一份契约）。
const MODE_NAMES := {
	DisplayMode.WINNER: "winner",
	DisplayMode.MARKER: "marker",
	DisplayMode.PROFILE: "profile",
}

## 当前档。默认 WINNER = 与切换前的观感最接近（胜出实体可见），只是不再叠加小球。
var _display_mode: int = DisplayMode.WINNER
## winner 档当前画的是**第几名**候选（0 起）。全场每个锚点都显示它自己的第 N 名，
## 因此同一档下往往是多种资产同时在画（每种一个 MultiMesh 节点）。
var _winner_rank: int = 0


func domain_key() -> String:
	return SPAEditorContractScript.SELECTION_DOMAIN_ANCHOR


## 多 drawable 域没有单一节点名：winner 档的节点名是内容派生的
## （`Winner_<资产序>_<资产名>`）。生命周期一律按 `generated_display_group()` 走。
func display_node_name() -> String:
	return ""


# ── 档位 ─────────────────────────────────────────────────────────────────────

func display_mode() -> int:
	_repair_soft_reloaded_members()
	return _display_mode


func display_mode_name() -> String:
	return str(MODE_NAMES.get(display_mode(), "winner"))


## 切档。三档**互斥**：旧档的节点全部丢弃，再建新档的。
##
## ⚠ 必须显式 `_discard_display()`：本域的 `revision()` 转发的是 anchor 交接号，
## 切档不改它，基类模板的「修订号没变就早退」会让切换静默失效。
func set_display_mode(mode: int) -> void:
	_repair_soft_reloaded_members()
	var next := mode if MODE_NAMES.has(mode) else DisplayMode.WINNER
	if next == _display_mode and not display_nodes().is_empty():
		return
	_display_mode = next
	_discard_display()
	rebuild_display()


## 按档名切换（跨脚本调用一律走这条：传字符串只需一份契约，传枚举要两边同步常量）。
func set_display_mode_name(mode_name: String) -> void:
	for mode in MODE_NAMES:
		if MODE_NAMES[mode] == mode_name:
			set_display_mode(mode)
			return
	push_error("[AnchorVolume] set_display_mode_name: 未知档名 \"%s\"（合法值 %s）。" % [
		mode_name, str(MODE_NAMES.values())])
	assert(false, "AnchorVolume.set_display_mode_name: unknown mode name")


## Shift+S：按 enum 顺序循环 WINNER → MARKER → PROFILE → WINNER。返回切到的档名。
func cycle_display_mode() -> String:
	set_display_mode((display_mode() + 1) % MODE_NAMES.size())
	return display_mode_name()


# ── winner 档：当前画第几名 ──────────────────────────────────────────────────

## 可切的排名档数（由 provider 现算：全场任一锚点拥有的最多有效候选数，上限 topk）。
## 0 = 还没评分或一个有效候选都没有。
func winner_rank_count() -> int:
	var provider := _anchor_provider()
	if provider == null:
		return 0
	return int(provider.call(PROVIDER_RANKS_METHOD))


## 当前排名（0 起）。越界时钳回——评分重算后有效候选数会变，钉死一个排名会让 winner 档
## 指向一个所有锚点都没有的名次（表现是"切过去一个节点都没有"）。
func current_winner_rank() -> int:
	_repair_soft_reloaded_members()
	var count := winner_rank_count()
	if count <= 0:
		return 0
	_winner_rank = clampi(_winner_rank, 0, count - 1)
	return _winner_rank


## Shift+A：在排名档之间循环（第 1 名 → 第 2 名 → … → 回到第 1 名）。返回切到的排名（0 起）。
##
## ⚠ 只在 winner 档有意义；其余两档不画候选 mesh，切了也不会变化——
## 这时顺带把档切到 winner，让按键有可见的反馈（"按了没反应"是最难查的一种）。
func cycle_winner_rank() -> int:
	_repair_soft_reloaded_members()
	if display_mode() != DisplayMode.WINNER:
		set_display_mode(DisplayMode.WINNER)
		return current_winner_rank()
	# ⚠ 交互 Score 只回读 winner 一份 ⇒ 名次数据默认只有第 1 名（`winner_rank_count()` 恒 1）。
	# 第一次真要往后切时让 provider 补齐候选池（它会重评一次带诊断），否则这个键永远是空操作。
	var count := winner_rank_count()
	if count <= 1:
		var provider := _anchor_provider()
		if provider != null and provider.has_method(PROVIDER_ENSURE_RANKS_METHOD):
			provider.call(PROVIDER_ENSURE_RANKS_METHOD)
			count = winner_rank_count()
	if count <= 0:
		return -1
	_winner_rank = (current_winner_rank() + 1) % count
	_discard_display()
	rebuild_display()
	return _winner_rank


## 数据源（评分模型 / 胜出结果 / 选中锚点）变了之后强制重建当前档。
##
## ⚠ 必须是**推送式**：本域的 `revision()` 转发的是 anchor **交接号**，而 demo 重算胜出模型
## 并不推进它——基类模板的「修订号没变就早退」会让重算后的显示停在旧内容上，且零提示。
## 数据的所有者知道自己什么时候变了，由它来推。
func force_rebuild_display() -> void:
	_repair_soft_reloaded_members()
	_discard_display()
	rebuild_display()


# ── 显示：三档各自的 drawable 由 provider 建，本类只挂载与登记 ─────────────────

## 建当前档的全部 drawable（基类 `_build_display_drawables()` 钩子；本域是多 drawable 域）。
##
## winner 档画全场每个锚点的**第 `current_winner_rank()` 名**候选。同一排名下不同锚点的候选
## 资产往往不同，而一个 `MultiMesh` 只能绑一个 mesh 资源 ⇒ provider 按资产分组、每组一个节点，
## 本类一次全部挂上。Shift+A 切排名（`cycle_winner_rank`）。
##
## ⚠ 每条自带 `key`（winner 档是节点 instance_id，profile 档是锚点下标，marker 档为 null）：
## 实例序只在本条内有意义，寻址口靠 key 才能解回 anchor_index。
##
## ⚠ provider 返回的节点**不得**已经 add_child：挂载与 pick 登记是基类模板的事，
## provider 自己挂就会绕开 `register_pick_drawable()` 的三项校验（几何非空 /
## custom_aabb 非空 / 参与点选），而那三种失败在界面上都表现为"这个域点不中"且零提示。
func _build_display_drawables() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var provider := _anchor_provider()
	if provider == null:
		return out
	var entries = provider.call(PROVIDER_BUILD_METHOD, display_mode_name(), current_winner_rank())
	if not (entries is Array):
		push_error("[AnchorVolume] provider.%s(\"%s\", %d) 没有返回 Array（实得 %s）—— 本档画不出任何东西。" % [
			PROVIDER_BUILD_METHOD, display_mode_name(), current_winner_rank(), type_string(typeof(entries))])
		assert(false, "AnchorVolume._build_display_drawables: provider returned non-Array")
		return out
	for raw_entry in entries as Array:
		if not (raw_entry is Dictionary):
			continue
		var entry := raw_entry as Dictionary
		if entry.get("node", null) == null:
			continue
		out.append(entry)
	return out


## 实例序 → `anchor_index`（基类点选的寻址钩子）。
##
## ⚠ **必须转发给 provider**，不能用基类的紧凑表：winner 档的实例序由视距剔除
## 逐帧压缩（`_apply_model_cull` 把幸存实例搬到 0..visible-1），那张 `visible_payload_indices`
## 随相机变化、只有 demo 侧维护得起。用本域的静态表解会在开着剔除时静默选中另一个锚点。
func element_index_for_instance(key, local_index: int) -> int:
	_repair_soft_reloaded_members()
	var provider := _anchor_provider()
	if provider == null:
		return -1
	return int(provider.call(PROVIDER_ELEMENT_METHOD, key, local_index))


## 本档已画出的实例数。⚠ 交给 provider 的寻址口自己判越界（它按 key 查对应那一组的
## 压缩表），这里给出一个不设限的上界即可——基类的越界守卫因此退化为
## 「寻址返回 -1 即判死」，与剔除的逐帧变化不会打架。
func displayed_instance_count(_key = null) -> int:
	return 0x7FFFFFFF


## anchor 域的可视化 provider（`SPA/Volumes/VolumeScore`，即 volume_score_demo）。
## 拿不到 = 本场景没挂 demo（合法：SPA 可以只跑管线不显示），如实返回 null 不报错。
func _anchor_provider() -> Node:
	var spa := scene_placement_actor()
	if spa == null:
		return null
	var provider := spa.get_volume_provider(&"VolumeScore")
	if provider == null or not is_instance_valid(provider):
		return null
	for required in [PROVIDER_BUILD_METHOD, PROVIDER_ELEMENT_METHOD, PROVIDER_RANKS_METHOD]:
		if not provider.has_method(required):
			push_error("[AnchorVolume] provider '%s' 缺少 anchor 显示契约方法 \"%s\" —— 三档可视化整块不可用。" % [
				provider.name, required])
			assert(false, "AnchorVolume: provider does not implement the anchor display contract")
			return null
	return provider


# ── 状态读口 ─────────────────────────────────────────────────────────────────

## 活跃锚点数。事实源是 SPA 已发布的交接记录（`get_anchor_count()`），
## 不回读 GPU —— 那是 prefilter 的事。
func live_element_count() -> int:
	var spa := scene_placement_actor()
	return spa.get_anchor_count() if spa != null else -1


## 交接修订号（**转发**，见类注释）。消费方拿它判断手上的 anchor RID 快照是否还新鲜。
func revision() -> int:
	var spa := scene_placement_actor()
	if spa == null:
		return 0
	var handoff: Dictionary = spa.get_anchor_candidate_handoff()
	return int(handoff.get("revision", 0))


## 报告行里带上当前档与当前排名：三档互斥 + winner 档按排名切之后，
## 「现在画的是第几名」是这个域最要紧的状态。
func _extend_ownership_report_entry(entry: Dictionary) -> void:
	entry["display_mode"] = display_mode_name()
	entry["display_winner_rank"] = _winner_rank
	entry["display_nodes"] = display_nodes().size()


func _repair_soft_reloaded_domain_members() -> void:
	if not (_display_mode is int) or not MODE_NAMES.has(_display_mode):
		_display_mode = DisplayMode.WINNER
	# 0 是合法起点；越界由 current_winner_rank() 按 provider 现算的档数钳回。
	if not (_winner_rank is int) or _winner_rank < 0:
		_winner_rank = 0
