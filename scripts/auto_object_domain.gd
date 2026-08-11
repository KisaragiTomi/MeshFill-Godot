@tool
class_name AutoObjectDomain
extends "res://scripts/pickable_domain.gd"

## `SPA/Volumes/AutoObject` 的节点脚本（《AutoVolume 公用体积基类计划》V5）。
##
## ── ⚠ 它为什么不叫 `AutoObject` ────────────────────────────────────────────
## 计划 §3 的类型结构图写的是 `AutoObject`，但那个 class_name 已经被
## `scripts/auto_object.gd`（`@tool class_name AutoObject extends MeshInstance3D`）占了，
## 而占它的那个类是**单个资产 / 单个放置实例**的节点（descriptor 持有、pivot 解析、
## ISWS 记录构建），被 `scene_placement_runtime.gd:29` 与 `voxel_placement_writeback.gd:11`
## preload 成常量、被 `scene_placement_runtime.gd` 里 `AutoObject.new()` 造成轻量 wrapper。
## **它不是域。** 节点名仍叫 `AutoObject`（节点名与 class_name 是两个命名空间）。
## 同款处置见 §3 的 `Anchor` → `AutoVolumeAnchor`：不占已经被占满的词。
##
## ── 本类是**实例域**，不是体积域（计划 §1.7 / §3）─────────────────────────
## 事实源是 `GPUAutoObjectRuntime` 的常驻对象池（SoA + `alive[]`，13 块 buffer）。
## 它**不实现**体积抽象层的 `element_kind` / `element_density` / `element_capacity` /
## `element_to_voxel` / `voxel_to_element` / `live_element_count` —— 那六个方法在
## `AutoVolumeField` / `AutoVolumeTile` / `AutoVolumeAnchor` 上，`PickableDomain` 之上
## 没有体积假设。
##
## ⚠ 别为了"看起来对称"给它接 `AutoVolumeAnchor`：锚点槽是 atomicAdd 追加序，
## 本域是 `OPT_STABLE_SLOTS` 保序流压缩（`auto_object_instance_renderer.gd`），
## 两者的"槽位"根本不是一回事，硬套会得到一套看起来对称的假寻址。
##
## ── ⚠ 本类**不碰显示**（V5 第一批刻意留空）────────────────────────────────
## 显示节点 `PlacedAutoObjects`（`PlacedInstanceDisplay`）今天由
## `volume_score_demo.gd` 建、挂在 demo 自己的 `VolumeScoreDisplay` 下，点选走的是
## **容器形态**（`PlacedInstanceDisplay.get_pick_drawables()` 一次返回 N 个 `PlacedBatch*`）。
## 因此 `display_node_name()` 返回空串：基类的 `_display_node()` 是 `get_node_or_null()`
## **on self**，节点不在本节点下就查不到，硬填一个名字只会得到一个永远为 null 的显示
## 节点，而 `set_display_visible()` 会静默什么都不做。
## 迁移显示节点归属是 V5 的第二批。
##
## ⚠ **绝对不要**在本类上调 `register_pick_drawable()`。它会把节点加进
## `voxel_display_group("gpu_objects")`，而 `PlacedAutoObjects` **已经在那个组里**
## （`spa_selection_host.gd` 的 `register_voxel_display_node`）——
## `collect_pick_drawables()` 会同时经容器和经组各收一遍同一批 MultiMesh，
## 同一个 MultiMesh 分到两段 pick_id 区间。这正是 `PICK_ID_DISPLAY_KEYS` 上方
## 为 TargetSV 明写过的那个坑，表现是「点中另一个合法对象」。
##
## ── ⚠ 软重载：本类**没有**自己的成员，因此不重写任何自愈钩子 ───────────────
## 将来若要加，重写的是 `_repair_soft_reloaded_domain_members()`，**不是**
## `_repair_soft_reloaded_members()`（后者是 `PickableDomain` 的模板方法，重写它会把
## 基类那半段整个顶掉且不报错）。
## ⚠ 这条在本域格外容易踩：`AutoObjectInstanceRenderer` 与 `GPUAutoObjectRuntime` 上的
## 函数**恰好就叫** `_repair_soft_reloaded_members()`（它们是 RefCounted，没有模板方法
## 这回事）。从那两处复制粘贴过来就是静默失效。


func domain_key() -> String:
	return SPAEditorContractScript.SELECTION_DOMAIN_AUTOOBJECT


## 无显示节点（见类注释）。V5 第二批迁移 `PlacedAutoObjects` 之后改成节点名。
func display_node_name() -> String:
	return ""


## 本域的内容修订号 = 常驻对象池的 `_object_revision`（**转发**，不持有）。
##
## 为什么只能转发：递增点在 spawn 成功 / `reset_state` / `configure_capacity` 三处，
## 全在 GPU 池那一侧；把它搬进节点会让 GPU 管线反过来依赖场景树。
## 同款转发见 `AnchorVolume.revision()` 与 `SceneSVVolume.revision()`。
##
## ⚠ 基类的 `_revision` 在本域**不用**：它没有独立递增点，用它会得到恒 0，
## 而消费方会把恒 0 读成"内容从没变过"。
##
## 返回 0 = 没有 runtime（SPA 未 READY / 已关停）。这与"有 runtime 但没变过"可区分：
## `_init → configure_capacity → _bump_object_revision()` 保证新建 runtime 的起点是 **1**。
##
## ⚠ 必须先过 `spa.is_ready()`：`get_gpu_runtime()` 一路转发到
## `ScenePlacementRuntime._ensure_owned_gpu_runtime()`，那一句会**惰性构造**一个
## `GPUAutoObjectRuntime`。本方法是状态读口，不该有构造副作用。
func revision() -> int:
	var spa := scene_placement_actor()
	if spa == null or not spa.is_ready():
		return 0
	# ⚠ 用 `var x =` 而不是 `:=`：`get_gpu_runtime()` 没有返回类型标注，
	# `:=` 会触发 INFERENCE_ON_VARIANT —— 引擎默认表里是 ERROR 级，
	# 直接把 parse gate 与 `-e` 门禁打红。
	var runtime = spa.get_gpu_runtime()
	if runtime == null:
		return 0
	return int(runtime.get_object_revision())


## 显示真值统一问 SelectionHost 的记账位。
##
## ⚠ 为什么要覆写：本域**没有自己的显示节点**（见类注释），基类那份
## `display_visible and (node == null or node.visible)` 会退化成"只读 @export"，
## 而 @export 只有 `set_volume_display(&"AutoObject", …)` 这一个入口会写它。
## 另一个入口 `set_voxel_display_visible("gpu_objects", …)`（两个桥侧门禁都走这条）
## 根本不经过本节点 ⇒ 两个入口交替使用时 @export 会静默陈旧，
## 变成一个"看起来是事实源"的假数。
##
## 显示节点迁进本节点之后（V5 第二批）这条覆写要连同 `display_node_name()` 一起重审。
func is_display_visible() -> bool:
	var spa := scene_placement_actor()
	if spa == null:
		return false
	return spa.is_voxel_display_visible(display_key())
