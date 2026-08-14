# 快捷键参考

编辑器 3D 视口内的键鼠绑定汇总。全部快捷键都是**编辑期**（`Engine.is_editor_hint()`）生效，
由 `meshfill_editor` 插件的 `_forward_3d_gui_input()` 转发——**鼠标必须在 3D 视口内**，
焦点在 Inspector / 文件系统等 dock 上时不会触发。

本文只登记按键绑定。域 / 卷 / 显示键这些词的定义见
[`auto-volume-base-class-plan.md`](doc/auto-volume-base-class-plan.md)。

## 派发顺序

插件先选宿主（`_scene_viewport_input_host()`）：编辑中的场景带 `ScenePlacementActor` 就交给
SPA，否则交给实现了 `_editor_viewport_input()` 的场景根（如 `asset-overview.tscn`）。
**两条链互斥**——同一时刻只有一个场景在编辑。

SPA 链内部按下面的顺序派发，先认领的先赢；这是键位冲突的唯一裁决依据：

```text
ScenePlacementActor.handle_editor_input()
  1. _handle_domain_visibility_editor_input()   # Ctrl+Alt+1..6，跨域显示开关
  2. SPASelectionHost.handle_viewport_input()   # 左键点选 / Esc
  3. VolumeScore.forward_editor_viewport_input()# Ctrl+H / G / Space（无修饰键才认）
  4. _handle_brush_editor_input()               # Shift+字母 / 左键落笔
```

两条容易踩的后果：

- **`G` 与 `Shift+G` 是两件事。** 第 3 跳只在无任何修饰键时认领，所以带 Shift 的 `G` 会漏到
  第 4 跳的笔刷表里。
- **左键的归属由第 2 跳决定。** 点中了任一可见域就是"点选"；没点中且当前无选中，才漏到第 4 跳
  变成"落笔"。域关掉了就点不中——「可见即可选」是 ID pass 的物理规则，不是一条额外检查。

## 域可见性：Ctrl+Alt+1..6

逐个翻转六个体素域的显示。槽位顺序直接取自 `SPAEditorContract.VOXEL_DOMAIN_BINDINGS` 的下标，
**没有第二张键表**——域增删改序时只改那张合同表，键位跟着走。

| 快捷键 | 域 | 卷节点 | 默认 | 默认值来源 |
| --- | --- | --- | --- | --- |
| `Ctrl+Alt+1` | AutoObject | `SPA/Volumes/AutoObject` | 开 | 基类默认 |
| `Ctrl+Alt+2` | SVTile | `SPA/Volumes/SVTile` | 关 | `svtile_volume.gd` |
| `Ctrl+Alt+3` | Anchor | `SPA/Volumes/Anchor` | 开 | 基类默认 |
| `Ctrl+Alt+4` | SV | `SPA/Volumes/SceneSV` | 关 | `scene_sv_volume.gd` |
| `Ctrl+Alt+5` | TargetSV | `SPA/Volumes/TargetSV` | 关 | `target_sv_setup.gd` |
| `Ctrl+Alt+6` | Brush | `SPA/Volumes/BrushSV` | 关 | `brush_sv_volume.gd` |

默认关的四个域各有理由，都写在各自的 `default_display_visible()` 上：SVTile 的瓦片罩会遮住
内部体素让它们静默选不中；SceneSV 是 10^6 实例 + 每次重建 2 × 4 MiB 回读；TargetSV 贴满整片
地形表面，会把其余五域全遮在后面；BrushSV 空场景里没内容可画，开着只是白占一个可选域。

默认关的域**连显示节点都不建**（`set_display_visible(false)` 遇到空节点列表直接返回，不触发
`rebuild_display()`），不是"建出来再藏起来"。

⚠ 表里的"默认"是**卷节点**的真值（`PickableDomain.is_display_visible()`）。
`SPASelectionHost` 那份显示开关记账位在开场景时一律播种为 `true`，与卷节点的默认值**不同步**
——`default_display_visible()` 在 `NOTIFICATION_READY` 里是直接赋值，不经 `set_volume_display()`。
所以 Inspector 的 Voxel Display 复选框可能显示"开着"而域实际没画（TargetSV 例外，它的 getter
读卷节点）。这不影响点选：域画不出像素就没有 pick_id，物理上就选不中。首次按 `Ctrl+Alt+N`
会把两边一次性对齐（本快捷键读卷节点取真值，写走 `set_volume_display()` 两边同写）。

修饰键判定是全等匹配：Ctrl+Alt 按下、Shift/Meta 未按。`Ctrl+Shift+Alt+数字` 不会被吃掉。

## 笔刷与显示档：Shift + 键

第 4 跳，要求按住 Shift。

| 快捷键 | 作用 |
| --- | --- |
| `Shift+B` | BrushSV 显示开关（等价 `Ctrl+Alt+6`） |
| `Shift+G` | TargetSV 显示开关（等价 `Ctrl+Alt+5`） |
| `Shift+R` | TargetSV 显示通道 → `Color` |
| `Shift+T` | TargetSV 显示通道 → `Complexity` |
| `Shift+Y` | TargetSV 显示通道 → `Collision` |
| `Shift+A` | Anchor 胜出**排名**循环：全场每个锚点显示自己的第 N 名候选 |
| `Shift+S` | Anchor 显示**档**循环：胜出实体 → 锚点小球 → 观察态 profile（三档互斥） |
| `Shift+C` | 清空 BrushSV（CPU 列表 + GPU 场对） |
| `Shift+=` / `Shift+小键盘 +` | 笔刷宽 / 长 +2（clamp 1..128） |
| `Shift+-` / `Shift+小键盘 -` | 笔刷宽 / 长 −2（clamp 1..128） |

`Shift+B` / `Shift+G` 与 `Ctrl+Alt+6` / `Ctrl+Alt+5` 是同一个开关的两个入口，都走
`set_volume_display()`，按哪个都一样。

`Shift+A` 只在候选池已回读时能切到第 2 名及以后（`ensure_winner_rank_data()`）；交互 Score
默认只回读 winner 一份。

## 评分与放置（`placement-score-3d`）

第 3 跳，由 `VolumeScore` 提供，**要求无任何修饰键**（`Ctrl+H` 除外）。

| 快捷键 | 作用 |
| --- | --- |
| `G` | 打印 SPA GPU 就绪报告到控制台 |
| `Space` | Place：`place_final_autoobjects()`，提交真实 AutoObject 并改写 SV |
| `Ctrl+H` | Anchor 的 PROFILE 档 / WINNER 档来回切 |
| `Esc` | 清除当前选中（第 2 跳） |

## 资产总览（`asset-overview`）

只在编辑 `scenes/asset-overview/asset-overview.tscn` 时生效，此时场景里没有 SPA，插件把输入
交给场景根。**要求无任何修饰键**——带修饰键的组合一律留给编辑器（`Ctrl+S` 保存等）。

| 快捷键 | 作用 |
| --- | --- |
| `1` | 语义探针显示开关 |
| `2` | 体素通道 → `color` |
| `3` | 体素通道 → `complexity` |
| `4` | 体素通道 → `collision` |
| `5` | pivot 显示开关 |
| `6` | 资产互斥球显示开关（**默认开**：开场景 / Import All / Import FBX 后自动重建） |
| `G` | 资产网格显示开关 |
| `C` | 清除全部调试显示（含互斥球） |

`6` 与前五个不同：它不看选中，一次画**全部**资产，且是这套里唯一默认开的一档——半径
（网格 AABB 的 XZ 半长）是资产固有属性，与放置 reduce 的成对间距同口径，两球相交即这一对
互斥。资产被挪过位置后按两次即按当前位置重建。

数字键依赖编辑器设置 `editors/3d/navigation/emulate_numpad` **关闭**。该项打开时编辑器会把
数字行 1..9 改写成小键盘码，脚本里的 `KP_0..KP_9` 折叠分支负责把它们折回来，两种设置下都能用。

## 飞行相机

`scripts/fly_camera.gd`，挂在各 demo 的 `DemoSetup/FlyCamera` 上。走 `_unhandled_input`，
不在上面那条插件转发链里。

| 键鼠 | 作用 |
| --- | --- |
| 右键按住 | 捕获鼠标，进入自由视角；松开即释放 |
| `W` / `S` | 前进 / 后退 |
| `A` / `D` | 左移 / 右移 |
| `E` 或 `Space` | 上升 |
| `Q` | 下降 |
| `Shift`（按住） | 加速，用 `fast_move_speed` 代替 `move_speed` |
| 滚轮（捕获中） | 调移动速度 ×1.2 / ÷1.2，clamp 5..600 |
| 滚轮（未捕获） | 沿视线前后推拉，步长 `scroll_speed` |
| `Esc` | 释放鼠标捕获 |

窗口失焦与出树时自动释放捕获（`NOTIFICATION_WM_WINDOW_FOCUS_OUT` / `NOTIFICATION_EXIT_TREE`），
不会出现"鼠标被吃掉找不回来"。

## 鼠标（SPA 场景）

| 操作 | 作用 |
| --- | --- |
| 左键单击 | 点选：命中任一可见域即选中；未命中且当前有选中则取消选中 |
| 左键按住拖动 | 未被点选消费时落笔画 BrushSV |

笔迹**关着显示也照样记录**（`apply_brush_extent()` 不看 `display_visible`），只是看不见——
要看按 `Ctrl+Alt+6`。

## 代码位置

| 绑定 | 实现 |
| --- | --- |
| 派发链入口 | `addons/meshfill_editor/meshfill_editor_plugin.gd` → `_forward_3d_gui_input()` |
| `Ctrl+Alt+1..6` | `scripts/scene_placement_actor.gd` → `_handle_domain_visibility_shortcut()` |
| `Shift+` 系列 | `scripts/scene_placement_actor.gd` → `_handle_brush_shortcut()` |
| 左键点选 / `Esc` | `scripts/spa_selection_host.gd` → `handle_viewport_input()` |
| `G` / `Space` / `Ctrl+H` | `demos/placement-score-3d/volume_score_demo.gd` → `forward_editor_viewport_input()` |
| 资产总览数字键 | `scenes/asset-overview/asset_overview.gd` → `_editor_viewport_input()` |
| 飞行相机 | `scripts/fly_camera.gd` → `_unhandled_input()` / `_process()` |
| 域槽位顺序 | `scripts/spa_editor_contract.gd` → `VOXEL_DOMAIN_BINDINGS` |
