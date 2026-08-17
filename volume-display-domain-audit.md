# 体素显示域的自有实现审计

2026-08-10 对 Inspector「Voxel Display」5 个开关背后的 5 个域（外加同族的 BrushSV / BlendSV）
做的只读结构审计：分清每个域**继承自基类链的共用实现**与**只为自己服务的那一份**，并标出
哪些「自有」其实是基类设施缺位造成的平行实现。

与同期那份全仓冗余审计的分工：那份查的是**死代码与冗余文件**（该删什么），本份查的是**活代码
的归属**（该由谁实现）。本文不引入新概念，词汇沿用
[`auto-volume-base-class-plan.md`](doc/auto-volume-base-class-plan.md) 的域 / 卷 / 钩子 / 元素空间。

## 审计前提与风险

- **以磁盘工作区为准**。分支 `refactor/compute-pass-toolkit` 上 `spa_selection_host.gd` 与
  `scene_placement_actor.gd` 正被并发会话编辑，行号锚点可能漂移；结论以**符号名**为准。
- 审计期间旧点选路径（`unified_pick_gpu.gd` 等）被并发会话删除，本文的死码判定按删除后的状态。
- 「零调用」结论均为静态 grep（含 `.gd` / `.tscn` / `tools/*.js`）；编辑器 bridge 的即席表达式
  无法静态证伪，涉及诊断口的条目已标注。
- 本文一条结论**与初审相反**，见「一处需要修正的初审结论」——不要按初审那版理解。

## 落地状态（2026-08-10 晚，用户裁定后执行）

本审计的建议已大部分落地（同日的「链路死码清除 + 审计收紧」轮，验证：parse gate 16 文件、
`-e` 门禁零错误零警告、报告/落笔/BlendSV 电池 ALL PASS、点击类型门禁 **10/10 全绿零未覆盖**）。
逐条状态标注在各表的「状态」列/行内标记；速览：

| 类别 | 状态 |
| --- | --- |
| 「顺带查出的死码」表 | ✅ **全部删除**（含 host 必需名单同步、loader 侧连带、两个 ComputeShaderBase preload） |
| TargetSV 两处结构债（`_grid_size` / `_terrain_height` 第四份地形） | ✅ 已清，改经 `grid_frame()` / 基类地形缓存 |
| 跨域重复 #1（部分）/#2/#4/#6/#8/#9 | ✅ 已收（#1 落的是"越界守卫收敛 + `resolve_pick` 基类虚函数化"，未做全模板钩子化） |
| SVTile 映射表整套（缺基类设施） | ✅ 紧凑表机制上提 `PickableDomain`，叶子上的 `_instance_tile_index` + 双钩子 + 软重载连带**塌缩** |
| TargetSV 专用 drawable 收集入口 | ✅ 已删，并入通用组扫描（双重收集已证伪，见「待核实」） |
| SceneSV 守卫不对称（修正后的窄暴露面） | ✅ 「表丢了 → `_built_revision` 一并推回」闭进基类软重载修复，对全域一致 |
| 跨域重复 #3/#5/#7 | ○ 未做（#3/#5 牵动并发会话活跃的 store/committer；#7 两份 5 行转发保留） |
| **Anchor 域能力回收** | ✅ **已做**（2026-08-10 晚，用户裁定）：三档互斥 + 显示归属迁进 `AnchorVolume`，见下方「Anchors」节的落地标注。本文原判"不建议顺手做"的三个障碍全部化解——见那里 |
| AutoObject 域能力回收、SVTile 两套可视化取舍 | ○ 按本文建议**不顺手做**（路线决策） |

行数变化（审计时 → 落地后）：`pickable_domain` 604→707、`auto_volume_field` 191→164、
`svtile_volume` 355→359（收编映射表的同时接了报告 `_extend` 钩子）、`scene_sv_volume` 291→253、
`target_sv_setup` 498→457、`anchor_volume` 65→62、`brush_sv_volume` 317→395（Brush 切换轮
迁入落笔定位与 pick 载荷）、`blend_sv_volume` 40→56（revision 转发 + resident 覆写）。

## 结论速览

| 域（Inspector 开关） | 卷类 | 类内行数（审计→现在） | 真正独有 | 名义自有实为缺基类设施 | 实现外置程度 |
| --- | --- | --- | --- | --- | --- |
| GPU Objects | [`auto_object_domain.gd`](scripts/auto_object_domain.gd) | 103 → 103（0 个自有成员） | 2 处守卫 | — | **极重**：约 20 处外部分叉（未动） |
| SV Tiles | [`svtile_volume.gd`](scripts/svtile_volume.gd) | 355 → 336 | 3 处瓦片尺度裁决 + 摘要回读 | ~~实例映射表整套~~ ✅ 已塌缩进根类紧凑表 | 中：9 个专属门面；~~demo 第二套可视化~~ ✅ 热力图已删（见下方成因节） |
| Anchors | [`anchor_volume.gd`](scripts/anchor_volume.gd) | 65 → 272（3 成员：档位 / 资产 / pick key） | **三档状态机 + provider 契约**（新增，是本域的核心） | — | ✅ 显示归属已回收；选中态那一半仍在 host |
| Scene Voxels | [`scene_sv_volume.gd`](scripts/scene_sv_volume.gd) | 291 → 252（0 个成员变量） | 1 处过期探测器 | ~~格心换算~~ ✅ 已上提；~~瓦片解析五件事~~ ✅ 已改问瓦片域要 | 轻 |
| Target SV | [`target_sv_setup.gd`](scripts/utils/target_sv_setup.gd) | 498 → 461 | 资产装载解码层等 | ~~2 处结构债~~ ✅ 已清（另删 4 个死读口与快照链） | 中：编辑器插件 165 行导入栏 |

同族但不在 Inspector 开关里的两卷：`brush_sv_volume.gd`（317 → 395 行——Brush 切换轮迁入
落笔定位、pick 载荷与绘制属性反查，唯一装用户内容的卷）、`blend_sv_volume.gd`（40 → 56 行，
revision 转发 + resident 覆写，全仓唯一显式 `participates_in_picking() == false`）。

根类 `pickable_domain.gd` 604 → 804 行：收编了所有权自报、显示几何、地形高度场、
rebuild 模板、紧凑表缓存、`resolve_pick` 唯一实现、READY 默认可见性——
子类因此只剩**声明**与**真正的域差异**。

### 逐域「只为自己服务」的现存清单（2026-08-10 复审）

⚠ 判据分两档：**声明**（每域一份是设计：`domain_key` / 显示系数 / `revision` 转发 /
`element_density`）不算重复；**实现**才需要问"能不能收"。下表只列实现。

| 域 | 现存自有实现 | 判定 |
| --- | --- | --- |
| Scene Voxels | `_build_display_node`（回读两块常驻场 → 打包直传）、`_warn_if_summaries_are_stale`（抽样分辨"真空 vs 摘要过期"，要再回读 4 MiB 复杂度场） | **不可收**：数据源与诊断能力都只有本域够得着 |
| SV Tiles | `_build_display_node`（摘要 → CPU 建色 → `build_colored`）、`_read_tile_summaries`、`tile_center_world` / `terrain_lift`（瓦片尺度的**有损**代表列裁决）、`_tile_color`（按占用密度而非极值）、`report_resident` / `_extend_ownership_report_entry`（GPU 真值） | **不可收**：都是瓦片元素空间的语义 |
| Brush | 内容管理六件（`apply_brush_extent` / `clear_painted_voxels` / `painted_*` / `paint_attributes_for_element`）、`screen_to_voxel_xz` + `_inside_grid_xz`（落笔定位）、`_render_colors`、三个显示快照钩子 | **不可收**：唯一装**用户内容**的卷，也是唯一有"输入"的域 |
| Target SV | 资产装载解码层（`_ensure_loaded` / `_prepare_display_fields` / 三个解码数组 / `reimport`）、`display_channel` + `switch_display_channel`、`fresnel_enabled`、`get_grid_frame`（自己的 display_scale 缩放框架） | **不可收**：唯一有"盘上烘焙资产"这一层的域 |
| Anchors | 三档状态机（`set_display_mode` / `cycle_display_mode` / `cycle_asset` / `current_asset_index`）、`_anchor_provider` 契约、`force_rebuild_display` | **不可收**：唯一显示由 provider 供数的域 |
| GPU Objects | `is_display_visible` 覆写（无自己的显示节点）、`revision` 的 `is_ready()` 门（挡惰性构造副作用） | **不可收**：两处都是本域独有的失败模式 |
| BlendSV | 无（全是声明） | — |

**结论：域内已无"名义自有实为缺基类设施"的项。** 上一轮列出的可收敛面
（#1/#2/#4/#6/#8/#9 + 紧凑表整套 + #3/#5）已全部落地，剩下的都是真实的域差异。

## 共用面：基类链提供了什么

```text
PickableDomain (pickable_domain.gd, 审计时 604 行 → 落地后 707 行：新增所有权自报 / resolve_pick 虚签名 / 紧凑表缓存 / READY 默认可见性钩子)
  ├─ AutoVolumeField (auto_volume_field.gd)  → SceneSV / TargetSV / BrushSV / BlendSV
  ├─ AutoVolumeTile  (auto_volume_tile.gd)   → SVTile
  └─ AutoVolumeAnchor(auto_volume_anchor.gd) → Anchor
                                             → AutoObject 直连 PickableDomain（不走中间层）
```

`PickableDomain` 已收编：SPA 解析、内容修订号、显示节点生命周期（`rebuild_display()` 模板）、
显示几何推导（AABB / cell 尺寸 / 填充比）、地形高度场、pick drawable 登记、软重载修复模板。
三个中间基类各自补**元素语义**（`element_kind` / `element_capacity` / `element_to_voxel` 等）。

外层三处也已完全通用，**加一个域不需要动它们**：

- Inspector 的 5 个 `@export` 只是代理，经 `_set_voxel_display_proxy(display_key, …)`
  下沉到 `SPASelectionHost.set_voxel_display_visible()`，再按显示组统一下发可见性。
- 域元数据集中在 [`spa_editor_contract.gd`](scripts/spa_editor_contract.gd) 的
  `VOXEL_DOMAIN_BINDINGS`（6 条，键集完全一致）。
- 点选统一走 ID pass + `resolve_pick()`。

## 逐域：还剩什么只为自己服务

### GPU Objects

类内 4 个方法全是钩子覆写，**零 BESPOKE 成员**（103 行里 51 行是类注释）。只有两处有真实行为价值：

| 成员 | 为什么只有它需要 |
| --- | --- |
| `is_display_visible()` 覆写 | 全仓唯一。本域没有自己的显示节点，基类那份显示真值会退化成「只读一个没人写的 @export」 |
| `revision()` 里的 `spa.is_ready()` 门 | 挡 `get_gpu_runtime()` 的**惰性构造**副作用；另三个转发型 `revision()` 都无构造副作用，不需要这道门 |

代价是它绕过 `AutoVolume*` 中间层直连 `PickableDomain`，`element_*` 语义、体素寻址、实例列表
一概没有，域能力散在三个文件：

| 能力 | 实际所在 |
| --- | --- |
| `resolve_pick`（容器形态，一次返回 N 个批） | [`placed_instance_display.gd`](scripts/utils/placed_instance_display.gd) `:257` |
| 体素寻址 `_autoobject_voxel_min_from_index()` | `spa_selection_host.gd`（注入式，非基类的 `element_to_voxel`） |
| 显示节点 | 由 demo 建，再注册进显示组 |
| 点选数据 | host 上 9 个专属成员 + `set_autoobject_pick_data()` 外部推送 |

附带：~~`display_visible` @export 是**死的**——唯一写入口 `set_volume_display(&"AutoObject", …)`
全仓零调用，`get_volume(&"AutoObject")` 同样零调用~~ ——已被 VOLUME_KEYS 退役部分反超：
所有权报告逐域自报后 `is_display_visible()`（覆写读 host 记账位）每次报告被消费；
@export 本身是根类成员非本域私产。保持观察，不按域删。

### SV Tiles

真正只有瓦片需要的三件：

| 成员 | 为什么不可下放 |
| --- | --- |
| `tile_center_world()` / `terrain_lift()` | 「一块砖用哪一列地形高度做代表」的**有损裁决**。体素域逐格精确、锚点域无解析式，只有瓦片域要做这个取舍。公开是为了让 SelectionHost 的选中框走同一条映射 |
| `_tile_color()` | 瓦片摘要**不是场**（stride 32、字段是计数与 min/max），颜色必须 CPU 现算；其余域直接把场字节喂 shader |
| `_warn_no_live_tiles()` | 刻意退化版：把「真空 vs 摘要过期」的确证让给 SceneSV，避免重复一次 4 MiB 回读。这是**有意分工**不是遗漏 |

`_instance_tile_index` 映射表 + `_display_cache_intact()` / `_on_display_discarded()` 两个守卫
+ 软重载连带修复**不是本域需求**：`AutoVolumeField` 已有功能同构的基类版本
（`_cached_instance_list` / `_display_cache_revision` / `get_instance_list()`），SceneSV 因此
不必覆写；只是 `AutoVolumeTile` 支缺了它，SVTile 只好在叶子上自建一份。
**✅ 已落地**：紧凑表缓存上提 `PickableDomain`（两支共用），SVTile 的整套叶子机制塌缩为
`build_compact_instance_list()` 覆写 + 根类 `get_instance_list()`；点击门禁 10/10 复验通过。

另有两处结构现象：全仓唯一拥有专属 GPU 访问面的域（9 个 `*_svtile_*` 门面）；以及
**两套并存可视化**——卷节点的八面体读摘要计数，demo 的 object-ref 热力图读槽位缓冲，
深度测试设置还相反。

### Anchors

65 行里唯一的自有实现是 `slot_handoff()`，且它是基类**明令否决过的形态**：
`AutoVolumeField` 类注释记载节点侧 `field_rid()` / `has_resident_fields()` 转发读口因
「没人读的读口不可能被可靠地保持同步」被整批删除，`slot_handoff()` 恰是该形态在 Anchor 支的
复活，同样零调用。**✅ 已删除**（2026-08-10 落地轮，留墓碑指路 V4 后半）。

另两个方法~~**实际不可达**：Anchor 不在 `VOLUME_KEYS`（所有权报告走另一种行形状），
也没有任何路径对本节点调 `rebuild_display()` / `set_display_visible()`~~ ——
**已被同日的 VOLUME_KEYS 退役反超**：所有权报告改为逐域自报后，`revision()` /
`report_resident()` 每次报告都被消费（Anchor 首次入列报告）；`set_volume_display(&"Anchor", …)`
经通用 PickableDomain 分支也已可达（本域无显示节点，落到记账位为止）。

域的真实实现全在别处：

| 位置 | 内容 | 状态 |
| --- | --- | --- |
| `spa_selection_host.gd` | 独立的 `_selected_anchor_idx` 状态槽 + 7 个配套方法（其余域的选中态只在通用 `_active_selection` 字典里）；整套 provider 注入机制；采样范围 marker + 5 个支持函数；专属 `Label3D` | ○ 未动（选中态那一半是另一件事） |
| `volume_score_demo.gd` | 三条 drawable（`AnchorPoints` / `Winner_*` / `WinnerVoxelProfile`），各自手写 `set_meta(PICK_DRAWABLE_META, …)` **绕开** `register_pick_drawable()` 的三项校验 | ✅ **已回收**（2026-08-10）：三处 `set_meta` 与三个 `resolve_*` 全删，节点改由 `AnchorVolume` 挂载并经基类登记；demo 只剩「算数据 + 建节点」的工厂 |

### ✅ Anchor 域能力回收的落地（2026-08-10，用户裁定）

本文原判"不建议顺手做"，理由是三个障碍。它们的化解方式：

| 原障碍 | 化解 |
| --- | --- |
| `Winner_*` 的 `visible` 有三个写入方，显示开关刷新会覆盖 Ctrl+H 观察态 | **三档互斥**后"当前画哪一种"是单一状态，可见性只剩基类 `set_display_visible()` 一个写入方；按名字前缀扫的 `_set_winner_meshes_visible` 删除，Ctrl+H 变成一次切档 |
| `resolve_cull_group_pick` 必须读 `visible_payload_indices`（剔除压缩实例序） | 寻址口留在 demo（`anchor_element_for_drawable`），由 `AnchorVolume.element_index_for_instance()` 经 provider 转发——压缩表随相机逐帧变，只有 demo 维护得起，卷节点不复制它 |
| 对 GPU 直写型 MultiMesh 调 `set_instance_*` 会静默清零 | 未触碰：剔除逻辑整体留在 demo，卷节点只管挂载与登记 |

⚠ **winner 档一次只画一种资产**（用户裁定）：一个 `MultiMesh` 只能绑一个 mesh 资源，
"同时画 N 种真实资产"必然是 N 个节点——那条路（基类多 drawable 泛化）做完后被回退。
现在 **Shift+A** 在有胜出实例的资产间循环、**Shift+S** 切三档。
代价是视口里一次只出现一类放置物；收益是基类不必引入多 drawable 能力。

### Scene Voxels

7 个卷里唯一**零成员变量**的（TargetSV 13 个、BrushSV 6 个、SVTile 1 个），也因此不需要覆写
软重载修复。真正独有只有一处：

- `_warn_if_summaries_are_stale()`：摘要说「一块非空砖都没有」时，抽样扫复杂度场（每 64 格）
  分辨这是事实还是摘要过期。判据要**再回读一次 4 MiB 场**，只有同时够得着摘要与场对的域做得到。
  它的类注释记录了成因（placement 的 state-chain stamp 原位写场、摘要 reduce 另跑一趟）与
  正确修复挂点，是本域最有价值的一段。

`voxel_center_world()` 名义自有、实则**只用基类 API**（`grid_frame()` + `display_terrain_height_field()`），
零 SceneSV 状态，且被 host 当成**全体素域**的 marker 事实源——严格说它本该在 `AutoVolumeField` 上。
同语义在别处还有两个名字：`TargetSVSetup.voxel_to_world()`、`SVTileVolume.tile_center_world()`。
**✅ 已上提 `AutoVolumeField`**（Brush 切换轮，BrushSV 的选中框与之同式共用）；
TargetSV / SVTile 的两个同语义名保留（前者带 display_scale，后者是瓦片尺度的有损裁决）。

### Target SV

自有实现最多，且大多货真价实：

| 成员簇 | 为什么只有它需要 |
| --- | --- |
| 资产装载解码层（`_ensure_loaded` / `_prepare_display_fields` / `_ready_ok` / `_metadata` / 三个解码数组，约 130 行） | **唯一有「盘上烘焙资产」这一层的域**。其余域内容来自 GPU 常驻场 / 瓦片摘要 / 笔刷 CPU 表，没有「加载」这个状态。它衍生出 `reimport()` / `is_targetsv_ready()` / `get_visual_bytes()` 一串读口与编辑器插件的 165 行导入工具栏 |
| `display_channel` + `switch_display_channel()` | 唯一有显示频道的域，也是 `_display_cache_intact()` 必须恒 `false`（每次重建）的直接原因——显示参数变更不推进内容修订号 |
| `fresnel_enabled` + `_apply_fresnel_material()` | 只有它有 |
| `get_display_snapshot()` | **唯一有下游 CPU 消费方**（`MeshFillBrush` 画在 TargetSV 网格上） |

两处是结构债而非需求——**✅ 均已清除**（2026-08-10 落地轮）：

- `_grid_size` 成员直接违反 `PickableDomain.grid_frame()` 的「任何子类都不得把框架三项存成
  自己的成员」；全类 6 处读它，均可换成 `grid_frame()["grid_size"]`。**已删，读处改现取。**
- `_terrain_height` 是地形高度场收编时**漏网的第四份**（基类已从 SceneSV / SVTile / BrushSV
  收编三份，算式逐参数相同），且本域喂 shader 用自己那份，基类缓存从头到尾没人读 ⇒
  「marker 与显示读同一份」的失效机制在本域是两套并行。**已删，改读基类缓存**
  （地形缺失 / 场空两条独立失败原因保留）。

另有一处**已无技术必要的专用通路**：`PICK_ID_DISPLAY_KEYS` 刻意排除 targetsv、改由
`_collect_targetsv_pick_drawable()` 按 `TargetSVSetup.DISPLAY_NODE` 常量硬取节点。但
`_build_display_node()` 走的是基类模板，模板已调 `register_pick_drawable()` 把节点加进了
`voxel_display_group("targetsv")`——通用组扫描本来就能收到它。
**✅ 专用入口已删、targetsv 进通用键表**；双重收集已在运行编辑器里证伪（见「待核实」）。

## 跨域重复：应收编基类

按逐字程度排序。~~每条都给了落点建议，但**未执行**~~ → 状态列为 2026-08-10 落地轮回写。

| # | 项 | 重复份数 | 建议落点 | 状态 |
| --- | --- | --- | --- | --- |
| 1 | `resolve_pick` 的越界守卫 2 行 | 4 份逐字（只有元素总数取法不同） | `PickableDomain` 声明 `resolve_pick()` 模板 + `_pick_instance_count()` / `_pick_element_at()` 钩子；顺带把 `"resolve_pick"` 这个**字符串契约**变成有静态签名的虚函数 | ✅ **超额完成**（用户 2026-08-10 裁定"点选不再派生"）：不止收守卫——`resolve_pick` 成为基类**唯一实现**、四个域的覆写全删；钩子只剩 `display_is_compact()` / `displayed_instance_count()` 两个**声明**；字符串契约连 `register_pick_drawable` 的参数一起消失 |
| 2 | `_build_display_node()` 的 RenderingDevice + `grid_frame` 双守卫 | 3 份逐字 + 1 近似 | 提进基类模板 `rebuild_display()`，钩子只收「本域怎么建」 | ✅ |
| 3 | 瓦片摘要回读 + 短读判空 | 2 份（同 buffer 同 stride 同语义，SceneSV 为此横向 preload SVTileVolume 只为拿 buffer 名） | 收进 `SceneVoxelTileCodec` 的静态读口，顺带消掉横向 preload | ✅ **已做，但落法不同**：不是挪进 codec（buffer 名的事实源在 store，会撞并发会话），而是让 **SceneSV 问瓦片域要**非空砖表——`SVTileVolume.get_instance_list()` 本来就是那张表。一次消掉五处重复（瓦片尺寸换算 / 摘要回读 / 短读判空 / 逐砖判非空 / 末排夹紧），横向 preload 降级为纯类型判定 |
| 4 | 非空砖判据 `counts.x<=0 and counts.y<=0` | 3 份（注释自承「三处不会各说各话」，靠注释维持不靠代码） | `SceneVoxelTileCodec.is_tile_non_empty()` | ✅ 落名 `summary_counts_live()` |
| 5 | 瓦片夹紧算式 | 3 份 | 提成 codec 静态函数。SceneSV 够不着 `AutoVolumeTile.voxel_range_of()` 是两支基类割裂的直接后果 | ✅ **已做，随 #3 一并**：SceneSV 现在直接调 `SVTileVolume.voxel_range_of()`——"够不着"的前提是"不能跨域调用"，而两个域本就是同一份数据的两个视图，跨域**问**比各算一遍更正确 |
| 6 | `_ready()` 里的 `display_visible = false` | 2 份逐字（连「为什么写在 `_ready` 而不是 @export 默认值」的理由都互相引用） | 基类加 `default_display_visible()` 钩子，两个 `_ready()` 一起删 | ✅ 应用点在根类 NOTIFICATION_READY |
| 7 | `revision()` 转发 `get_svtile_gpu_status().gpu_revision` | 2 份逐字 | 两支基类都够不着 ⇒ 放 `PickableDomain` 的钩子，或在 SPA 侧收成一个命名读口 | ○ 保留：两份 5 行、语义各自成立（SV 内容 / 瓦片内容），收成钩子省的行数抵不过间接层 |
| 8 | 地形高度场构建 | 基类已收 3 份，**TargetSV 是漏网第四份** | 删 `_terrain_height`，改读 `display_terrain_height_field()` | ✅ |
| 9 | `SceneSVVolume.voxel_center_world()` | 与 `VoxelGeneral` 算式逐项相同；被当成全体素域 marker 源 | 上提到 `AutoVolumeField`；TargetSV 的同语义版只多一个 `display_scale`，而基类已有 `display_scale_value()` | ✅ 已上提（Brush 切换轮，BrushSV 共用）；TargetSV 版保留 |

## 跨域重复：判定不能收

| 项 | 为什么是多态契约而非重复 |
| --- | --- |
| `_build_display_node()` 的**主体** | 四条不同的 VoxelDisplay 通路：字节直传 / CPU 循环 2048 / float 数组 / 稀疏四元组。输入格式与量级差三个数量级，各自有裁决记录 |
| ~~`resolve_pick()` 的**映射与载荷**~~ | ~~紧凑表 / 恒等 / 四元组 / 瓦片表。SVTile 刻意不发 `voxel_coord`~~ —— **本条判定被推翻**（用户 2026-08-10）：点选只需回答「哪个域的哪个元素」，"映射"其实只有紧凑/恒等两种（一个 `display_is_compact()` 声明即可表达，Brush 的四元组序**就是**它的紧凑表），"载荷"则整个不该存在——坐标与范围问域的既有成员即可。⇒ 四份实现全删，见计划文档「点选零派生」行。SVTile 那条语义反而更硬：从"克制不发"变成"结构上没有" |
| `revision()` 的**数据源** | 5 个不同事实源（瓦片 gpu_revision / anchor 交接 / brush runtime / object pool / 基类 `_revision`）；搬进基类会打散释放时序 |
| `_repair_soft_reloaded_domain_members()` | 三份成员集互不相交，共享的是写法惯例不是代码 |
| `live_element_count()` | 三种「活跃」定义不同：摘要现算 / SPA 交接记录 / 如实 -1 |
| `display_fill_ratio()` / `min_cell_height()` | 算式已在基类，系数按域覆盖正是设计意图 |
| TargetSV 的 `_ensure_loaded()` 等前置门 | 唯一从磁盘资产加载的域 |

## 顺带查出的死码与不对称

| 项 | 状态（审计时 → 2026-08-10 落地后） |
| --- | --- |
| `spa_editor_contract.gd` 的 `pick_volume_score_anchor()`（64 行含 6 处 assert） | **已核实零调用**，属旧路删除产生的新鲜死码 → ✅ **已删除** |
| TargetSV 的 `get_grid_size()` / `upload_to_gpu()` / `get_metadata()` | 零调用 → ✅ **已删除**（连带 loader 侧 `upload_to_gpu` 60 行、两个 `ComputeShaderBaseScript` preload；host 必需名单里挂着的 "get_metadata" 一并摘除——要求一个没人调的方法只会误拦删除者。⚠ 落地时另查出快照链也死了：`get_scene_sv_snapshot` / `get_target_sv_snapshot` / `get_display_snapshot` 零调用，一并删除） |
| Anchor 的 `slot_handoff()` / `revision()` / `live_element_count()` | `slot_handoff` → ✅ 已删；`revision()` → **已被 VOLUME_KEYS 退役救活**（所有权报告逐域自报，每次报告消费）；`live_element_count()` 保留（元素空间声明轴的实现，非转发读口） |
| AutoObject 的 `display_visible` @export 与 `get_volume(&"AutoObject")` | @export 是根类成员非本域私产，不可按域删；报告自报后 `is_display_visible()` 每次报告被读。保持观察 |
| `record_method` 被声明两遍 | → ✅ 字符串列**整列删除** + 自检循环删除；唯一事实源是 host 的直接方法引用表（解析期即验） |
| 卷节点实例化路径不一致 | 维持现状（TargetSV 的 `.tscn` 声明 + typed 成员有真实消费者，统一化收益不明） |
| `VOLUME_KEYS` 成员资格 | → ✅ **键表已整体退役**（同日）：报告逐域自报，SVTile 合成行由节点 `_extend` 钩子取代，Anchor / AutoObject 首次入列 |
| SceneSV 缺第三道显示守卫 | 见下节——**不对称属实，但故障面比初审窄** → ✅ 残余暴露面已闭（连带修复进根类） |

### 一处需要修正的初审结论

初审称「SceneSV 缺 `_display_cache_intact()` 覆写 ⇒ 摘要短读会让显示永久卡死、每次点选报越界」。
**这条被夸大了**，实读基类模板与建节点路径后修正如下：

- 短读时 `SceneSVVolume._build_display_node()` 在取到空紧凑表处即 `return null`，而
  `rebuild_display()` 在此之前已调 `_discard_display()` 把 `_built_revision` 推回 `-1`，
  下次调用会重试 ⇒ **不会卡住**。
- 残留暴露面窄得多：需要「软重载丢失实例表缓存 + 重算恰好返回空」这个组合，此时
  `_built_revision` 未被推回（基类只推 `_display_cache_revision`）、节点还在、守卫默认恒真
  ⇒ 早退成立而 pick 列表为空。
- 不对称属实：SVTile / BrushSV / TargetSV 三个域都覆写了这道守卫，SceneSV 没有；SVTile 还在
  软重载修复里显式把 `_built_revision` 一并推回。三种做法三种可靠性。
- **✅ 已闭合**（2026-08-10 落地轮）：紧凑表缓存上提根类后，「缓存丢失 ⇒ `_built_revision`
  一并推回 -1」写进 `PickableDomain._repair_soft_reloaded_members()`——对全体域一致成立，
  上述残留组合不再存在；SVTile 的叶子版连带修复随映射表塌缩一起删除。

## 收敛优先级建议（→ 落地状态）

1. **先补基类的 Tile 支设施**（重复 #1/#3/#4/#5）——它同时消掉 SVTile 叶子上的映射表整套与
   SceneSV 的横向 preload，是收益面最大的一步。→ ✅ **已全部落地**（紧凑表上提 + 映射表塌缩
   + #4 谓词 + #3/#5 改为"SceneSV 问瓦片域要"）。横向 preload 只剩类型判定一个用途。
2. **`resolve_pick` 变成有签名的虚函数**（重复 #1）→ ✅ 已落（基类判死默认 + 五个族内实现者
   转为重写；族外 `placed_instance_display.gd` 仍按方法名挂 meta，登记参数保留）。
3. **TargetSV 的两处结构债** → ✅ 已清。
4. **删死码** → ✅ 全清（含落地时新查出的快照链三件）。
5. **Anchor 与 AutoObject 的域能力回收**属**路线决策**，不建议顺手做 → 遵此，未动。

## 待核实（→ 已核实）

- ~~TargetSV 专用 drawable 收集入口删除后是否会与通用组扫描双重收集~~ →
  **已在运行编辑器证伪**：仅 targetsv 可见时 `prepare` 报 `drawables=1`、
  `next_pick_id=1,048,577`（整网格恰好一段分配；双重收集会是 2 个 drawable、id 翻倍）。
  成因：专用入口与通用组扫描收的是**同一个节点**，删专用后只剩一条路。
- ~~Anchor / AutoObject 两域的读口面是否有仓外消费者~~ → `slot_handoff` 直接删除后
  `-e` 门禁 + 全套桥电池零报错；`revision()` / `is_display_visible()` 已由逐域自报的
  所有权报告转为**仓内消费**，不再依赖"可能有仓外调用"的假设。
- ~~SVTile 两套可视化（卷八面体 / demo 热力图）是否都要保留~~ → ✅ **已裁并落地**
  （2026-08-10，用户：「它们可以用一个可视化，点击后可以获得所有信息」），见下节。

### SVTile 两套可视化的成因与合并（2026-08-10）

**成因是一次抢救与一次新建各自发生、中间没有交接**：

1. 热力图原本挂在 `SPA/Interaction/DemoHost/SVTileOverlay`。DemoHost 因"无条件造第二份
   `PlacementStageEnv`、两份 env 互相释放对方常驻缓冲"被整个移除，热力图被搬进 demo，
   理由写在段头注释里：「热力图是全项目唯一的 SVTile 可视化，随宿主一起删等于让 SVTile 域
   永远不可见 ⇒ 按『看不见就选不中』它将永久不可选」。
2. 2026-08-07 `SVTileVolume` 建了八面体（计划文档「SVTile 八面体落地记」开头写"瓦片域此前
   **没有几何**"——指的是那个已随 DemoHost 移除的旧叠加层）。**没有人回头看 demo 还留着一份。**

⚠ **抢救时的理由本身不成立**：热力图从来没有 `PICK_DRAWABLE_META`、也没进
`voxel_display_group("svtile")`（只经 `set_mode_visual_bindings` 注册了**淡化**绑定），
它根本不在 ID pass 里——保住的只是"看得见"，不是"可选"。同一段里还有一条基于错误假设的
注释：「`no_depth_test` 只服务显示；ID pass **必须忽略它**，否则点哪都选中它」——
写的人以为它会进 pass。

两者的实际差异（**不是同一份数据的两次绘制**）：

| | demo 热力图 | 卷节点八面体 |
| --- | --- | --- |
| 数据 | object-ref 槽位缓冲：每砖引用了多少 AutoObject | 瓦片摘要：每砖有多少体素被占 |
| 重建时机 | Place 之后 | 摘要 `revision` 变化 |
| 形状 | 八面体，贴地、高 **0.35 m** | 八面体，瓦片中心、cell 高 **14.4 m** |
| 深度 | `no_depth_test: true` | 刻意不开 |
| 点选 | 不进 ID pass | 可点选 |
| 显示键 | **同一个 `svtile`** | **同一个 `svtile`** |

⇒ **合并**：热力图整套删除（overlay 根 / heatmap / 总览标签 / 四个统计成员 / 七个函数 /
place 路径的 `svtile_overlay` 阶段 / `visuals_refresh` 钩子），object-ref 计数**不丢失**——
`_svtile_record_for_voxel()` 本来就带 `object_ref_count` 与完整 `tile_record`，点中即得。
连带清掉 host 侧因此零调用方的 `set_mode_visual_bindings` / `_mode_visual_bindings` /
`_apply_selection_mode_visual_binding`（域族显示由 `PickableDomain.set_display_visible()` 管，
族外容器走 `register_voxel_display_node` 的组下发）。

**代价**：object-ref 密度的**视觉**编码消失（现在八面体的颜色是体素占用密度），要看某砖引用了
多少对象得点它。**实测**：`svtile-only prepare drawables = 1`（此前两套并存）、
生产点击落 `svtile:(3, 0, 5)`、记录含 `object_ref_count` / `tile_record` /
`scene_voxel_count` / `complexity` 全部字段；demo 评分+放置链零错误零警告。
demo −196 行、host −23 行。
