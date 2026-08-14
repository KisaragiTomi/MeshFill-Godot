@tool
class_name AutoVolumeAnchor
extends "res://scripts/pickable_domain.gd"

## 元素空间 = **稀疏槽**的体积抽象层（《AutoVolume 公用体积基类计划》§1.3 / §2.2）。
## 对应元素 `Anchor`：定长槽位池 `uvec4[]`（每槽 16 B，存体素坐标 xyz + 标志位）
## 加一个原子计数，容量 `ANCHOR_CAPACITY`。
##
## ── ⚠ 名字为什么不是裸 `Anchor` ────────────────────────────────────────────
## 计划文档 §3 的类型结构图写的是 `Anchor`。语法上可行（Godot 4.6 没有同名 ClassDB 类，
## `Control.Anchor` 是类内嵌枚举、不占全局符号），但本仓 "anchor" 这个词已经被占满了：
## 域字符串 `SELECTION_DOMAIN_ANCHOR := "anchor"`、`anchor_index`、`anchor_revision`、
## 8 个 anchor 着色器。用它做全局 class_name 会让 `Anchor`（类）与 `"anchor"`（域）
## 在同一份代码里指两件事。前缀与 AutoVolumeField / AutoVolumeTile 对齐。
##
## ── 谁拥有 Buffer（计划 §1.3）───────────────────────────────────────────────
## **Anchor 自己**分配、自己释放。`AutoObjectProbePrefilterGPU` 退化为纯调度器：
## 收集活跃 Anchor 的 buffer 句柄 → 一次 dispatch 批处理 → 读结果。
## 管线不分配、不释放、不知道 buffer 的生命周期，只按 RID 引用。
## 这条约束来自批处理本身：N 个 Anchor 合并成一次 compute dispatch，
## 若 Anchor 持有管线所有权，单个 Anchor 消亡就会让整条管线失效。
##
## ── ⚠ 三个修订号里只有一个属于本域 ─────────────────────────────────────────
## `ScenePlacementActor._anchor_revision` / `_score_revision` **不要**搬进来。
## 它们的语义是 "RID 失效/交接"——scene_placement_actor.gd 的注释明写
## 「释放或替换 Anchor/Fine RID 之前**必须**先递增对应 revision」，这个时序约束的
## 执行者是 SPA（它同时持有借出方与借入方），不是域。搬进来会把释放时序打散成两半。
## 本域继承的 `revision()` 只表示"我这些槽位里装的东西变了"。
##
## ── 三种可视化互斥（计划 §1.3）─────────────────────────────────────────────
## 小球（评分阶段标记锚点位置）/ 胜出物体网格（放置后的真实资产 mesh）/
## profile 盒（Ctrl+H 观察态的体素轮廓）——每次只有一种出现，共用同一个 `anchor_index` 载荷。
##
## ── ⚠ 接管显示时要避开的互斥 ───────────────────────────────────────────────
## CPU `set_instance_transform` 会**静默清零** GPU 直写的实例
## （volume_score_demo.gd 的三处同款警告）。基类不接管逐实例视距剔除，
## 剔除方案归《GPU直提渲染》。

const BufferDescriptorScript := preload("res://scripts/utils/buffer_descriptor.gd")

## 槽位容量与记录 stride。与 `autoobject_probe_prefilter_gpu.gd` 的同名常量**必须同步**：
## 那边的 shader 用 `anchor_buf_capacity` push 常量做越界判定，两侧不一致的表现是
## 回读到的 anchor 数超出容量却仍被当成合法记录。
## 旧值 65536 是「每列至多一个锚」时代的列数上限；竖直采样
## （`AutoObjectProbePrefilterGPU.anchor_vertical_stride` > 0）让一列能出多个锚后已不成立。
const ANCHOR_CAPACITY := 131072
const ANCHOR_RECORD_STRIDE_BYTES := 16


# ── 元素空间 ─────────────────────────────────────────────────────────────────

## 稀疏槽是 AoS：一条记录一个 uvec4，不是分 buffer 的一维数组。
func element_kind() -> String:
	return BufferDescriptorScript.KIND_AOS_ARRAY


func element_density() -> String:
	return BufferDescriptorScript.DENSITY_SPARSE


func element_capacity() -> int:
	return ANCHOR_CAPACITY


## 活跃锚点数。需回读原子计数，由持有 buffer 的子类重写。
##
## 基类返回 -1（"没人告诉我"）而不是 0 或容量：0 会被当成"确实一个锚点都没有"，
## 容量会被当成"全满"，两种假答案都比"不知道"更难查。
func live_element_count() -> int:
	return -1


## 槽位下标 → 体素坐标。
##
## ⚠ 稀疏槽**没有解析式**：坐标是 `uvec4` 记录的 xyz 三个分量，只能从 buffer 里读出来。
## 这与体素域（恒等映射）和瓦片域（整除换算）根本不同——那两个能纯算，这个必须回读。
## 基类没有 buffer，如实返回非法坐标；持有 buffer 的子类重写。
##
## ⚠ 别为了"看起来对称"给它编一个 index → 体素的公式。锚点是 atomicAdd 追加序，
## 槽位下标与空间位置**无任何关系**（《点选统一》§7.3 的 P0-C 裁决记了三套并存的索引空间）。
func element_to_voxel(_index: int) -> Vector3i:
	return Vector3i(-1, -1, -1)


## 体素坐标 → 槽位下标。同样没有解析式，需要一次反查（线性扫或 GPU 侧索引）。
## 基类如实返回 -1（未命中），不猜。
func voxel_to_element(_voxel: Vector3i) -> int:
	return -1
