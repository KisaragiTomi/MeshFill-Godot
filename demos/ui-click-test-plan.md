# Core SPA UI 点击测试方案

本文描述 `core-SPA-scene-placement-actor` demo 的 UI 点击测试方案，覆盖 Godot 编辑器工具栏、编辑器视口点击、Inspector 暴露参数，以及可脚本化断言入口。本文只补充已有 `ScenePlacementActor` demo 的交互测试说明，不新增运行时概念。

相关文件：

- [`core-scene-placement-actor.tscn`](core-scene-placement-actor.tscn)：测试场景，根节点下的 `CoreSPADemo` 挂载 `spa_interactive_demo.gd`。
- [`spa_interactive_demo.gd`](spa_interactive_demo.gd)：SPA demo 交互、HUD、拾取和公开测试入口。
- [`core-scene-placement-actor.md`](core-scene-placement-actor.md)：当前 demo 的运行方式和 GPU 验收标准。
- [`scene-placement-actor.md`](scene-placement-actor.md)：SPA 编排契约。
- `res://addons/meshfill_editor/meshfill_editor_plugin.gd`：编辑器工具栏、视口事件转发、MCP 命令入口。

## 前置条件

- 在 Godot 编辑器中打开 `res://demos/core-SPA-scene-placement-actor/core-scene-placement-actor.tscn`。
- 使用编辑器 `@tool` 模式验证；禁止用 F5、F6、`--script` 或 `--headless` 作为 UI 点击测试入口。
- 确认 MeshFill 编辑器插件已启用，编辑器 3D 视口顶部能看到 SPA 相关工具栏。
- HUD 初始显示 `RD: ready`、`SPA: OK`、`GPU ready: YES`、资产注册数量和 `AutoObjects: PASS`。
- 当前场景根中应存在 `CoreSPADemo`，并能通过编辑器选择或 MCP 调用访问其公开方法。

## UI 入口总览

| UI 入口 | 触发方式 | 源码入口 | 主要验证 |
| --- | --- | --- | --- |
| 选择模式下拉框 | 点击工具栏 `SPA selection mode` 选项 | `set_spa_selection_mode()` | 模式切换、旧选中清理、HUD 同步 |
| 视口左键 | 在 3D 视口 LMB 点击 | `_editor_viewport_input()` → `_handle_editor_mouse_button()` | AutoObject / SVTile / Anchor / SV / TargetSV 拾取 |
| 视口滚轮 | Anchor 选中后滚轮上下 | `_cycle_volume_score_anchor_topk()` | 选中 anchor 的 top-k asset score 切换 |
| `VD` 显示按钮 | 点击 `GO` / `ST` / `A` / `SV` / `TSV` | `set_voxel_display_visible()` | 可视层显示、拾取开关、按钮状态同步 |
| `Anchors` | 点击工具栏按钮 | `generate_volume_score_anchors()` | 生成 volume-score anchors |
| `Score` | 点击工具栏按钮 | `calculate_volume_score()` | 计算已生成 anchor 的 voxel score |
| `Brush` | 点击工具栏按钮 | `_on_brush_btn_toggled()` | 插件通用 brush 可见性开关，不改变 SPA 选中记录 |
| Inspector 参数 | 点击或输入 `CoreSPADemo` export 属性 | export setter / `_apply_selection_mode_visuals()` | 拾取半径、AutoObject 可选、anchor bounds 等状态 |

`Geo FBX` 工具栏属于 AssetDescriptor demo；在当前 SPA 场景中应不可见或禁用，不作为 SPA 点击功能。

## 基础启动用例

| ID | 操作 | 期望结果 |
| --- | --- | --- |
| UI-BOOT-01 | 打开 `core-scene-placement-actor.tscn`，等待 `@tool` 初始化完成 | HUD 出现，`SPA: OK`、`GPU ready: YES`、`AutoObjects: PASS` |
| UI-BOOT-02 | 查看 3D 视口 | 可见地形、GPU AutoObject 点云、SVTile 热力块和 legend |
| UI-BOOT-03 | 查看工具栏 | 选择模式下拉框可见；`VD` 按钮组可见；`Anchors` / `Score` 在有 provider 时可用 |
| UI-BOOT-04 | 点击空白区域且当前无选中 | 不报错，不产生选中记录，事件可继续交给编辑器 |

## 选择模式点击矩阵

工具栏下拉框和 `Shift+0..5` 共用同一个入口。UI 点击测试以工具栏下拉框为主，快捷键只作为辅助验证。

| 模式 | 下拉框值 | 视口 LMB 命中规则 | 期望选中记录 |
| --- | --- | --- | --- |
| `Mixed` | `0` | 优先 GPU AutoObject，其次 volume-score anchor，最后 TargetSV → SVTile | `autoobject` / `anchor` / `targetsv` / `svtile` |
| `AutoObject` | `1` | 只选择 GPU AutoObject 点云 | `domain=autoobject`、`geometry=gpu_point` |
| `SVTile` | `2` | 点击地形体素所在 tile | `domain=svtile`、`geometry=voxel` |
| `Anchor` | `3` | 有 volume-score anchors 时选 anchor；没有 active anchors 时选 voxel candidate | `domain=anchor` |
| `SV` | `4` | 点击已提交 SceneVoxel cell | `domain=sv`、含 `complexity` / `collision` |
| `TargetSV` | `5` | 点击 TargetSVSetup guidance cell | `domain=targetsv`、含 `occupancy` |

每个模式都执行以下通用检查：

- 下拉框选择后，HUD 的 `Selection mode` 立即更新。
- 切换到新模式时，旧 AutoObject、data voxel、volume-score anchor 选中状态被清掉。
- 除 `Mixed` 外，编辑器 Selection 锚定回 `CoreSPADemo` 或当前 selection marker，避免视口失焦。
- LMB 成功命中后，HUD 追加 `Selected ...` 信息，3D 视口出现黄色或域颜色 marker / label。

## 视口点击用例

| ID | 前置 | 操作 | 期望结果 |
| --- | --- | --- | --- |
| UI-PICK-01 | 模式 `AutoObject`，`GO` 可见，`select_gpu_autoobjects=true` | 点击一个 GPU AutoObject 点 | 出现 `Selected GPU AutoObject`，记录含 `object_id`、`asset_name`、`profile_id`、`tile_coord`、`voxel_min`、`voxel_max` |
| UI-PICK-02 | 模式 `Mixed`，点击 GPU AutoObject 点 | 同 UI-PICK-01 | Mixed 优先命中 AutoObject，不误选底层 SVTile / TargetSV |
| UI-PICK-03 | 模式 `SVTile`，点击地形或热力块 | 出现 `SVTile ... refs=...` label | 记录含 `tile_coord`、`tile_index`、`object_ref_count`、`tile_record` |
| UI-PICK-04 | 模式 `SV`，点击地形 | 出现 `SceneVoxel ...` label | 记录含 `voxel_coord`、`tile_coord`、`complexity`、`collision` |
| UI-PICK-05 | 模式 `TargetSV`，点击 TargetSV 点云或投影位置 | 出现 `TargetSV ...` label | 记录含 `voxel_coord`、`complexity`、`collision`、`occupancy`、`buffer_index` |
| UI-PICK-06 | 模式 `Anchor`，未生成 volume-score anchors | 点击地形 | 选中 voxel anchor candidate，记录含 `anchor_kind` 和 `complexity` |
| UI-PICK-07 | 模式 `Anchor`，已生成 volume-score anchors | 点击 anchor marker | 选中 volume-score anchor，记录 `geometry=volume_score_anchor` |
| UI-PICK-08 | 有任意选中 | 点击空白处 | 当前选中被清除，HUD 不再显示 `Selected ...` |
| UI-PICK-09 | 刚完成一次命中或清除 | 松开鼠标左键 | release 事件被消费，不触发第二次选择或编辑器误选 |

## 体素显示开关用例

`VD` 面板的按钮来自 `SPAEditorContract.VOXEL_DISPLAY_DEFINITIONS`。每个按钮都要验证“显示状态”和“拾取状态”两件事。

| 按钮 | display key | 关闭后期望 | 打开后期望 |
| --- | --- | --- | --- |
| `GO` | `gpu_objects` | GPU AutoObject 点云和 AutoObject 选中 marker 隐藏；`AutoObject` / `Mixed` 不再命中 AutoObject | AutoObject 点云恢复，LMB 可再次选中 GPU object |
| `ST` | `svtile` | SVTile 热力块隐藏；`SVTile` 模式点击返回 no hit；Mixed 不再 fallback 到 SVTile | 热力块恢复，SVTile 点击可选 |
| `A` | `anchor` | Anchor marker / bounds 隐藏；Anchor 模式不能通过 provider 或 voxel candidate 选中 | Anchor 选择恢复 |
| `SV` | `sv` | 已选 SceneVoxel marker 隐藏；`SV` 模式点击返回 no hit | SceneVoxel 选择恢复 |
| `TSV` | `targetsv` | TargetSV 显示隐藏；TargetSV 模式点击返回 no hit；Mixed 不再优先 TargetSV fallback | TargetSV 显示与选择恢复 |

自动化断言建议：

```gdscript
core.set_voxel_display_visible("gpu_objects", false)  # 关闭 GO
assert(core.get_voxel_display_state()["gpu_objects"] == false)
assert(core.select_at_viewport_position(640, 360, 1).get("ok") == false)

core.set_voxel_display_visible("gpu_objects", true)   # 恢复 GO
assert(core.get_voxel_display_state()["gpu_objects"] == true)
```

## Volume Score 点击用例

| ID | 前置 | 操作 | 期望结果 |
| --- | --- | --- | --- |
| UI-VS-01 | 当前场景有 volume-score provider | 点击 `Anchors` | 控制台打印 `Generate Anchors`，视口出现 anchors，状态 label 可见 |
| UI-VS-02 | 已生成 anchors | 点击 `Score` | 控制台打印 `Voxel Score`，状态 label / tooltip 可显示 top-k score 摘要 |
| UI-VS-03 | 模式 `Anchor` 或 `Mixed`，anchors 已生成 | LMB 点击 anchor | 选中 anchor，HUD 显示 anchor summary，若记录含 `sample_bounds` 则显示 bounds marker |
| UI-VS-04 | 已选中 volume-score anchor | 鼠标滚轮上 / 下 | selected anchor 的 top-k asset score 切换，状态 label、tooltip、HUD 同步刷新 |
| UI-VS-05 | 无 provider 或 provider 未注册 | 查看 `Anchors` / `Score` | 按钮隐藏或 disabled；点击不会产生成功状态 |

注意：当 provider 已有 active anchors 时，`Anchor` 模式不会 fallback 到普通 voxel candidate；点击未命中 anchor 时应返回 no hit。

## Inspector 参数用例

| 参数 | 操作 | 期望结果 |
| --- | --- | --- |
| `selection_mode` | 在 Inspector 下拉切换 `Mixed` / `AutoObject` / `SVTile` / `Anchor` / `SV` / `TargetSV` | 与工具栏下拉框一致，HUD 与可视焦点同步 |
| `select_gpu_autoobjects` | 取消勾选后点击 GPU 点 | AutoObject 不再被选择；Mixed 进入后续 data fallback |
| `gpu_autoobject_pick_radius_px` | 改小后点击点云边缘，再改大重复点击 | 小半径更难命中，大半径更容易命中；不应误选明显远离光标的点 |
| `show_anchor_sample_bounds` | 取消勾选后选中 volume-score anchor | Anchor 仍可选，但 sample bounds marker 不显示 |
| `show_svtile_autoobject_overlay` | 重新加载场景时关闭 | SVTile / AutoObject overlay 不创建；HUD 和 SPA 初始化仍应成功 |
| `autoobject_count` | 使用较小值重新加载场景 | HUD 的 spawned 数量随配置变化；选择记录仍稳定 |
| `autoobject_grid_resolution` | 调整后重新加载场景 | 体素坐标和 marker 尺寸随 grid 更新，不越界 |

## 边界和负向用例

| ID | 场景 | 期望结果 |
| --- | --- | --- |
| UI-NEG-01 | 当前模式对应的 `VD` 显示按钮关闭后点击视口 | 返回 no hit，不创建隐藏域的 selection marker |
| UI-NEG-02 | `select_gpu_autoobjects=false` 后在 `AutoObject` 模式点击 | 返回 no hit，不误选 data voxel |
| UI-NEG-03 | `SVTile` / `SV` / ordinary `Anchor` 模式下 `_sv_committer` 不可用 | 公开入口返回 `scene_voxel_committer_unavailable` 或 no hit |
| UI-NEG-04 | TargetSVSetup 未 ready | TargetSV 点击返回 no hit，不创建空记录 |
| UI-NEG-05 | 没有 active selection 时滚轮 | 不消费事件，不改变状态 |
| UI-NEG-06 | 模式不是 `Mixed` / `Anchor` 时滚轮 | 不切换 top-k，不改变 HUD |
| UI-NEG-07 | 点击空白处时已有 AutoObject / data / volume-score selection | 所有选中状态清空，HUD 和 editor selection 同步 |
| UI-NEG-08 | GPU picking 不可用但地形 raycast 可用 | 允许走点击定位 fallback；不能把缺 RenderingDevice 当作 GPU 成功 |

## 可自动化入口

这些入口可由 Godot MCP `call_method`、编辑器插件 TCP 命令或本地 GDScript 测试调用。它们不替代人工截图验收，但能把点击结果转成稳定断言。

| 方法 | 用途 | 推荐断言 |
| --- | --- | --- |
| `set_spa_selection_mode(mode)` | 模拟工具栏 / Inspector 模式切换 | `get_spa_selection_mode() == mode` |
| `select_at_viewport_position(x, y, mode)` | 模拟某屏幕坐标的视口点击 | `ok`、`domain`、`geometry`、`record.id` |
| `select_data_voxel(mode, x, y, z)` | 绕过屏幕坐标，直接验证数据域记录构建 | `domain`、`voxel_coord`、`tile_coord` |
| `get_current_selection_record()` | 读取当前选中 | 与上一次点击结果一致 |
| `set_voxel_display_visible(key, visible)` | 模拟 `VD` 按钮 | `get_voxel_display_state()[key]` |
| `generate_volume_score_anchors()` | 模拟 `Anchors` 点击 | 返回 `ok` 或 provider 结果 |
| `calculate_volume_score()` | 模拟 `Score` 点击 | 返回 `ok` 或 provider 结果 |
| `refresh_volume_score_anchor_selection()` | 刷新 selected anchor 可视状态 | 有选中时返回 `ok=true` |

示例断言：

```gdscript
var core := get_tree().edited_scene_root.find_child("CoreSPADemo", true, false)

core.set_spa_selection_mode(2)             # SVTile
assert(core.get_spa_selection_mode() == 2)

var svtile := core.select_data_voxel(2, 32, 0, 32)
assert(bool(svtile.get("ok", false)))
assert(str(svtile.get("domain", "")) == "svtile")

core.set_voxel_display_visible("svtile", false)
var hidden := core.select_data_voxel(2, 32, 0, 32)
assert(bool(hidden.get("ok", false)))      # 直接数据入口仍可构建记录
assert(core.get_voxel_display_state()["svtile"] == false)
```

直接数据入口用于验证记录构建，不等价于真实视口点击。真实点击仍必须通过 `select_at_viewport_position()` 或人工 LMB 验证显示开关对拾取的影响。

## 验收标准

- 所有选择模式都能通过工具栏下拉框切换，并在 HUD 中即时反映。
- 每个可见数据域都能通过 LMB 产生正确 `domain` / `geometry` / record 字段。
- `VD` 五个按钮同时控制可视显示和视口拾取，不出现“隐藏但还能被真实点击选中”的状态。
- Mixed 模式拾取优先级稳定：AutoObject → volume-score anchor → TargetSV → SVTile。
- 空白点击、释放事件、滚轮事件和 disabled 工具栏都不产生重复选择或错误状态。
- `Anchors`、`Score`、anchor LMB 和滚轮 top-k 能完成一条 volume-score 点击闭环。
- Inspector 参数改变后，视口点击行为与参数语义一致。
- 所有 UI 点击测试均保持 GPU-first 语义；缺少 RenderingDevice 时只能报告 SKIP / no hit，不能把 非 GPU 路径当作通过。
