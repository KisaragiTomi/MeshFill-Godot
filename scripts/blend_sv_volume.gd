@tool
class_name BlendSVVolume
extends "res://scripts/auto_volume_field.gd"

## `SPA/Volumes/BlendSV` 的节点脚本（《AutoVolume 公用体积基类计划》V1、§1.6）。
##
## BlendSV 是**一次性混合暂存卷**：把放置结果与现有 SceneSV 做场对混合，生命周期严格限定在
## 「混合开始 → 提交到 SceneSV 结束」。提交完即清空/释放，不参与后续帧的任何读取。
##
## ── 它为什么在这一族里，却不参与点选 ────────────────────────────────────────
## 与 BrushSV 同为 schema v1 场对、同在 `SPA/Volumes` 下、分配段此前逐字相同
## （两者的分配段正是 §2.5-7 收敛掉的那两处），所以它属于体积家族。
## 但它**没有任何可视化节点**：内容恒等于 `SV ⊕ BrushSV`，画它就是画重复。
## 在「可视化即拾取几何」前提下，没有 drawable 就进不了 ID pass，
## 因此 `participates_in_picking()` 显式返回 false。
##
## ── ⚠ 由此得出的一条待办（计划 §6 开放问题 3）──────────────────────────────
## ✅ **已随旧路一并解决（2026-08-10）**：`unified_pick_gpu.gd` 的 `COMPETING_DOMAIN_MASK` 里
## 曾含 `BIT_BLENDSV` 这个死项（BlendSV 没有 drawable ⇒ 进不了 ID pass ⇒ 参赛恒不可能命中）。
## 该文件连同 `pick_unified.glsl` 已整体删除，掩码不复存在，此项自动消失。
## 本卷「不参与点选」的唯一表达从此是 `participates_in_picking() == false`。

## BlendSV 不参与点选。见类注释——这是**显式 opt-out**，不是忘了声明域名。
func participates_in_picking() -> bool:
	return false


## 内容修订号 = runtime 的 `_blend_sv_revision`（合成成功即增；与 BrushSV 同款转发）。
##
## ⚠ 事实源必须在 runtime：生产管线的合成是 runtime **内部自调**、不经过 SPA 门面——
## 2026-08-10 前挂在门面上的计数（`_volume_revisions` 字典）正因如此从未接到生产事件，
## 报告里 BlendSV 合成后 resident 仍恒 false 且零提示。
func revision() -> int:
	var spa := scene_placement_actor()
	return spa.get_blend_sv_revision() if spa != null else 0


## 报告的 resident 位：一次性暂存卷按「合成发生过」（revision > 0）——
## 不是「场对此刻在 GPU 上」（release 不清计数，语义与旧报告口径一致）。
func report_resident() -> bool:
	return revision() > 0


## 它在 `VOXEL_DOMAIN_BINDINGS` 里没有条目（那张表只有 autoobject / svtile / anchor /
## sv / targetsv / brush 六条），如实返回空串。
func domain_key() -> String:
	return ""


## 无可视化。
func display_node_name() -> String:
	return ""

# ⚠ 这里曾有 `field_rid()` / `has_resident_fields()` 转发（→ SPA 的 blend_sv_*_rid）——
# **全仓零调用点**，已随基类同款包装一起删除（2026-08-10，成因见 AutoVolumeField 类注释）。
# 合成管线读 BlendSV 场对一直走 runtime 自己的 `blend_sv_*_rid()`，不经过本节点。
