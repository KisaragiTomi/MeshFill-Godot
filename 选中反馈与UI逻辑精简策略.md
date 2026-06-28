# 选中反馈与 UI 逻辑精简策略

针对 [spa_interactive_demo.gd](demos/core-SPA-scene-placement-actor/spa_interactive_demo.gd) 中点击反馈（selection feedback）与 HUD 显示逻辑的重构策略。目标是把"三套并行实现"收敛成"一条数据驱动的管线"，在不改变交互行为的前提下减少重复代码与状态分叉。

## 1. 现状问题

当前选中链路按"域（domain）"被切成了三套互相平行的实现，每套都重复同样的步骤。

### 1.1 三套并行的选中状态

- GPU AutoObject：`_selected_autoobject_index` + `_selected_autoobject_record`
- 数据体素：`_selected_data_record`（SVTile / SV / Anchor / TargetSV 共用）
- Volume-score anchor：状态存在外部 provider 里，本体只持有 `_volume_score_provider`

判断"是否有选中"要同时查三处，见 [`_has_active_selection()`](demos/core-SPA-scene-placement-actor/spa_interactive_demo.gd#L2196-L2199)。

### 1.2 三套并行的可视节点

- `_autoobject_selection_marker` / `_autoobject_selection_label`
- `_data_selection_marker` / `_data_selection_label`
- `_anchor_sample_bounds_marker`

每套都各自 `_ensure_*`、各自定位、各自设材质，逻辑高度雷同。

### 1.3 三条 select / clear 路径重复同一套动作

[`_select_autoobject()`](demos/core-SPA-scene-placement-actor/spa_interactive_demo.gd#L1126-L1167)、[`_select_data_record()`](demos/core-SPA-scene-placement-actor/spa_interactive_demo.gd#L1171-L1205)、[`_select_volume_score_anchor_at_position()`](demos/core-SPA-scene-placement-actor/spa_interactive_demo.gd#L438-L459) 三者都按同一顺序做：

1. 清除另外两个域的选中
2. 存记录
3. `_ensure_*` 可视节点 + 定位 marker + 写 label 文本
4. `EditorInterface.get_selection()` 同步编辑器选中
5. `print(...)`
6. `_apply_selection_mode_visuals()`
7. `_update_hud()`

清除侧同理：[`_clear_autoobject_selection()`](demos/core-SPA-scene-placement-actor/spa_interactive_demo.gd#L1104-L1112) / [`_clear_data_selection()`](demos/core-SPA-scene-placement-actor/spa_interactive_demo.gd#L1116-L1122) / [`_clear_volume_score_selection()`](demos/core-SPA-scene-placement-actor/spa_interactive_demo.gd#L477-L482) 三份。

### 1.4 大分支的可见性与 HUD

- [`_apply_selection_mode_visuals()`](demos/core-SPA-scene-placement-actor/spa_interactive_demo.gd#L1338-L1372)：5 个 `*_focus` 布尔 + 一堆 `if node != null` 手工开关。
- [`_update_hud()`](demos/core-SPA-scene-placement-actor/spa_interactive_demo.gd#L2349-L2437)：按域 if/elif 拼字符串，和 marker label 里的信息重复维护。

## 2. 核心思路：统一选中记录 + 单一活动选中

所有域已经都返回结构相同的 `record: Dictionary`（带 `domain` / `geometry` / `id` / `world_position` / `marker_size` 等）。这是现成的统一抽象，只是还没被当作单一真相来源使用。

策略：把"当前选中"收敛成**一个** `_active_selection: Dictionary`，所有可视反馈和 HUD 都从它派生。

```
点击 → 各域 picker 产出 record（保持不变）
        ↓
   set_active_selection(record)   ← 唯一写入口
        ↓
   ┌──────────────┬──────────────┬─────────────┐
   marker 定位     label 文本      编辑器选中同步   HUD 刷新
   （数据驱动）     （数据驱动）     （统一）        （从 record 读）
```

- `_active_selection` 为空即"无选中"，`_has_active_selection()` 退化成一次 `is_empty()` 判断。
- AutoObject 的 `object_index`、anchor 的 `anchor_index` 等域特有字段仍存在 record 里，需要时按 key 读，不再需要独立成员变量。
- Volume-score anchor 的权威数据仍在 provider，但选中态的"镜像 record"也进 `_active_selection`，让下游统一。

## 3. 分步重构（每步可独立验证，互不阻塞）

### 步骤 A：合并可视节点为一个 SelectionVisual

把三套 marker/label 合并成一个轻量内部结构（或一个小节点），只保留：

- 一个线框 box marker（颜色按 domain 取，见 [`_selection_domain_color()`](demos/core-SPA-scene-placement-actor/spa_interactive_demo.gd#L1232-L1242)）
- 一个 Label3D
- anchor 的 sample-bounds marker 作为可选附加层（它语义不同，是范围框而非点选标记，保留独立但走同一 ensure 工厂）

`_ensure_autoobject_selection_visuals` / `_ensure_data_selection_visuals` 合并为单个 `_ensure_selection_visual()`。

### 步骤 B：抽出 `set_active_selection(record)` 唯一写入口

把三个 `_select_*` 里重复的"清旧 → 存 → 定位 → label → 编辑器同步 → print → 刷新"收敛进来。各域只负责产出 record，调用 `set_active_selection(record)` 收尾。

```gdscript
func set_active_selection(record: Dictionary) -> void:
    clear_active_selection(false)          # 一次清除替代三处
    _active_selection = record.duplicate(true)
    _apply_selection_visual(record)        # marker + label，按 domain 取色/取尺寸
    _sync_editor_selection()               # EditorInterface 同步，单份实现
    _apply_selection_mode_visuals()
    _update_hud()
```

domain 特有的副作用（AutoObject 给点云实例染色、anchor 刷新 sample-bounds）用一个小 `match record.domain` 收口，而不是各开一条函数链。

### 步骤 C：label 文本表驱动

[`_format_data_selection_label()`](demos/core-SPA-scene-placement-actor/spa_interactive_demo.gd#L1246-L1274) 已是 match 结构，把 AutoObject 的 label 拼装（现在内联在 `_select_autoobject`）也并进来，形成单一 `_format_selection_label(record)`，marker label 与 HUD 选中段共用同一函数，消除重复维护。

## 4. 实现状态（已落地）

本策略已实现于 [spa_interactive_demo.gd](demos/core-SPA-scene-placement-actor/spa_interactive_demo.gd)，公开 API 与拾取优先级保持不变。关键映射：

| 策略 | 落地结果 |
| --- | --- |
| 单一真相来源 | `_active_selection: Dictionary` 取代 `_selected_autoobject_index/_record` 与 `_selected_data_record`；`_has_active_selection()` 退化为 `is_empty()` 判断 |
| 步骤 A：统一可视节点 | 单个 `_selection_marker` + `_selection_label`，由 `_ensure_selection_visual()` 创建；anchor 的 `_anchor_sample_bounds_marker` 作为可选附加层保留 |
| 步骤 B：唯一写入口 | `set_active_selection(record)`（点选域）/ `clear_active_selection(update_hud, clear_provider)`（统一清除）；可视摆位收口于 `_apply_selection_visual(record)`，按 `geometry` 分派 |
| 步骤 C：表驱动文本 | marker label → `_format_selection_label(record)`；HUD 选中段 → `_append_active_selection_hud_lines(lines)` |
| selection-mode 可见性 | `_apply_selection_mode_visuals()` 只做调度；节点显示/淡化由 `_selection_mode_visual_bindings()` 与 `_apply_selection_mode_visual_binding(binding)` 数据驱动 |
| volume-score anchor | 权威态仍在 provider，`refresh_volume_score_anchor_selection()` 作为回调把镜像写入 `_active_selection`；SPA 不为其出 box marker（provider 自绘高亮），HUD 改为显示其 `summary` 行（此前为空） |

验证：`<godot> --headless --path . --import` 可用于确认脚本扫描/类注册阶段无 `Parse Error`；当前项目会在 editor layout 阶段由 `non_headless_scene_guard.gd` 拦截并返回非零。视口点击矩阵仍需按 [ui-click-test-plan.md](demos/ui-click-test-plan.md) 在编辑器 `@tool` 模式人工或经 MCP `call_method` 验收。
