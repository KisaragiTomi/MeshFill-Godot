# MeshFill-Godot 项目检查报告

> 生成方式：6 个并行 subagent 分区扫描（scripts / shaders / tools / docs / demos / 根元文件与架构）。
> 范围：项目代码错误、可优化点、文档与代码一致性。已按用户要求跳过 mempalace 记忆对比。
> 日期：2026-06-10

---

## 0. 总体结论

项目整体结构清晰、文档与代码高度吻合，GPU-First 的体素放置管线设计自洽。本次检查未发现会让主管线崩溃的核心 bug，但存在以下需要优先处理的问题：

- 1 处**编译期阻断**：被改名脚本 `target_scene_voxel_generator(暂停开发).gd` 仍被 `preload` 旧路径引用，导致相关 demo 与测试无法加载。
- 2 处**运行时同步/资源隐患**（中）：prefilter dispatch 无 `ceil_div` 上限保护；profile container 的 `dispose()` 绕过借用设备 sync 守卫。
- 多处**文档/规则冲突**：demo 文档中的 GPU 测试命令已统一改为 Vulkan 非 headless；剩余 `--headless` 仅保留在 CPU-only 脚本示例中。
- 若干**失效引用**与**缺测试覆盖**。

---

## 1. 项目架构概述（人话版）

**核心理念**：把"想要什么效果"（目标画布 TargetSceneVoxel）和"怎么放"（生成管线）彻底解耦。目标画布只描述每个体素的颜色 / 强度(complexity) / 碰撞(collision)，不写"这里放岩石A"这类资产标签；管线负责读目标、匹配资产、物理评分、放置、再与目标比对反馈。该设计面向 AI 训练（AI 只需预测体素分布，不学资产选择）。

**关键数据角色**

- `TargetSV`（源目标画布）+ `BrushSV`（笔刷覆盖）→ 合成 `TargetSV_B`（实际采样目标）。三者都是 guidance，绝不进入提交结果。
- `SceneVoxel`：最终提交的"已放置场景"读模型，对外暴露 complexity / color / collision（+可选 auto_mix）。
- `SV[t-1]` / `SV[tick]`：上一轮稳定输入 / 本轮提交结果，逐 tick 推进。
- `SceneVoxelTile`：粗粒度 4×4×4 体素瓦片，负责 dirty 追踪、局部重建、对象引用索引（与 placement 用的 8×8×8 voxel region 是两回事，文档明确强调勿混淆）。

**模块归属**

- `ScenePlacementActor (SPA)`：运行时统一编排器，拥有 profile container，借用 committer / gpu_runtime，跑 prefilter→placement→commit 三阶段。
- `AssetDescriptor`：资产默认语义唯一权威；AutoObject 上的同名字段只是 Inspector 镜像。
- `AutoObjectProbePrefilterGPU`：GPU 语义探针粗筛，只收窄候选，不写最终结果。
- `VoxelPlacementGenerator (VPG)`：GPU 物理精筛（footprint / support / collision / clearance / overlap / target fit）+ stamp。
- `SceneVoxelCommitter`：源体素合成（AutoSV+BrushSV+LandscapeSV→BlendSV）、SV 常驻显存、tile dirty、反馈评分。
- `GPUAutoObjectRuntime` + `AutoVoxelRuntimeProfileContainer`：百万级 GPU 对象池 + profile/probe/collision/pivot 常驻 buffer。

**数据流 / 状态机**

```
TargetSV + BrushSV → TargetSV_B
  → prefilter（从 SV[t-1] 取 anchor 打分）
  → candidate_voxel_regions_by_asset
  → VPG 物理放置 → AutoSceneVoxel[tick]
  → blend_scene_voxels() → SceneVoxel[tick]
  → 反馈评分 → 下一 tick 提升为 SV[t-1]
```

全路径 GPU 优先；无 RenderingDevice 只能 SKIP，不允许 CPU 回退伪装通过。

**GPU buffer 生命周期**（`GPU_BUFFER_LIFECYCLE.md`，579 行）

- 三类作用域：`SCOPE_FRAME`（帧末 `gc_frame()` 自动回收）、`SCOPE_PERSISTENT`（跨帧常驻，手动 `release_rid()`/`dispose()`，`NOTIFICATION_PREDELETE` 兜底）、`SCOPE_PASS`（随 uniform set 销毁）。
- 基类工厂 `godot_compute_shader_base.gd` 区分 owned / borrowed RID（借用的不释放）。
- PERSISTENT buffer 约 25 个占 >90% 显存；FRAME buffer 约 20 个。

---

## 2. 阻断级问题（必须先修）

| # | 文件 | 问题 | 建议 |
|---|---|---|---|
| A1 | `demos/target-sv-point-cloud-conversion/target_sv_point_cloud_demo.gd:4` | `preload("res://scripts/target_scene_voxel_generator.gd")` 指向的脚本已改名为 `target_scene_voxel_generator(暂停开发).gd`，preload 在编译期解析必然失败，整个 demo 场景无法加载 | 修正 preload 路径为实际文件名，或将脚本改回 ASCII 原名 |
| A2 | `tools/test_target_sv_point_cloud_conversion.gd:3` | 同一失效 `preload`，测试无法启动 | 同上 |
| A3 | `scripts/main.gd:44` | `TARGET_SV_GENERATOR_PATH = "res://scripts/target_scene_voxel_generator.gd"` 指向不存在路径，运行时 `load()` 失败并 `push_warning`（L2494/2498） | 更新常量路径，或在文档标注该模块已暂停 |

> 根因统一：`scripts/target_scene_voxel_generator.gd` 被改名为带全角括号的 `…(暂停开发).gd`，但 3 处引用、README/多篇文档、以及孤立的 `target_scene_voxel_generator.gd.uid` 都未同步。**建议把文件重命名为 ASCII（如 `target_scene_voxel_generator.gd.disabled` 或移出 `scripts/`），并统一修正所有引用与清理孤立 uid。**

---

## 3. 代码错误 / 风险（中级）

### GDScript（scripts/）

| # | 位置 | 级别 | 问题 | 建议 |
|---|---|---|---|---|
| B1 | `autoobject_probe_prefilter_gpu.gd:299` | 中 | `_dispatch_collect` 用 `compute_list_dispatch(cl, dirty_count, 1, 1)`，把 dirty 瓦片数直接当 X 维 workgroup 数，无 `ceil_div`。dirty_count > 65535 时触发驱动错误/截断 | 改用基类 `dispatch_groups_1d`，shader 内做 local_size 划分；或拆 2D 网格 |
| B2 | `auto_voxel_runtime_profile_container.gd:90-96` | 中 | `dispose()` 直接 `_rd.submit()/_rd.sync()`，未判断 `_owns_rendering_device`。借用全局设备时会强制 submit/sync 干扰主渲染，绕过了基类 `submit_and_sync` 的 owns 守卫 | 复用基类 `submit_and_sync` 语义或加 owns 判断 |
| B3 | `autoobject_probe_prefilter_gpu.gd:213-229` | 中/低 | route_pack「resident 就绪」分支仅在 `not ok` 时 sync，ok 时直接对 `anchor_buf` 回读；pass 间顺序依赖一次 submit，存在 readback 早于 compute 完成的同步缺口 | readback 前无条件 `submit_and_sync` 一次，或确认 ok 路径内已 sync |

### GLSL（shaders/）

| # | 文件 | 级别 | 问题 | 建议 |
|---|---|---|---|---|
| C1 | `update_current_height.glsl` | 高 ✅已修复 | 首个 `imageStore(rw_result_b, pos, …)` 在顶部执行，`pos` 全程无 `imageSize` 边界判断（仅 `in_dirty` 守卫）。dispatch 向上取整超尺寸时越界写 | 已在 `main()` 开头加 `if (pos.x >= work_size.x \|\| pos.y >= work_size.y) return;`，并移除了无同步对象的无用 `barrier()`（该 barrier 此前阻止越界线程提前 return）。glslang 验证通过 |
| C2 | `stamp_voxel_field.glsl` | 高 ⚠需决策 | `complexity_field[index] = vec4(color, complexity)` 是非原子写，多 footprint/多 result 命中同体素时"最后写入者胜"，而 collision 走 CAS-max，语义不一致 | complexity 在 vec4 的 `.a` 分量，GLSL 无法对 vec4 子分量做 atomic；真正修复需改 buffer 布局（见第 9 节方案），属架构决策 |
| C3 | `collect_sv_anchors.glsl` | 中 | 越界时仍 `atomicAdd(anchor_count,1)`，返回的 `anchor_count` 会超 capacity，CPU 据此驱动后续 dispatch/读取会越界 | 溢出时回退计数或单独记 overflow 计数器 |
| C4 | `generate_target_height.glsl` | 中 | `max_cell = tex_size.x-1` 同时用于 x、y 两轴 clamp，隐含正方形假设，非方形纹理 y 向 clamp 错误 | 分别用 `tex_size.x-1` 与 `tex_size.y-1` |
| C5 | `score_anchor_asset_probes.glsl` | 中 | 正向分支把 `target_field[idx].a`（体素完全度 completeness）当作碰撞 `s_coll`，地下分支又用 `complexity_coll[idx].x`，同一物理量来源不一致，疑似语义错配 | 统一碰撞来源（`complexity_coll[idx].y`） |

---

## 4. 文档 / 规则一致性问题

### 4.1 GPU 测试命令是否违反规则（经实时核查：基本合规，原报告误报）

对全部 `demos/**/*.md` 重新逐条核查实际命令行，结论与初版扫描不同：

- **所有依赖 RenderingDevice 的 GPU 测试脚本，在 demo 文档中已统一使用 `<godot> --path . --rendering-driver vulkan --script tools/...`**（如 `test_scene_voxel_field`、`test_voxel_placement_generator`、`test_autoobject_probe_prefilter`、`test_gpu_autoobject_runtime_bridge`、`test_voxel_dirty_tile_upload`、`test_blendsv_feedback_score`、`test_markdown_contracts` 等）。
- 文档中仍使用 `--headless` 的脚本只有 8 个，且经核查**均为 CPU-only、不引用 RenderingDevice**：`test_voxel_placement_record_commit`、`test_target_guidance_source_boundary`、`test_asset_properties_descriptor_contract`、`test_auto_asset_scripting`、`test_semantic_probe_generation`、`test_semantic_probe_debug_mesh`、`validate_test_leaf_asset`、`test_target_sv_point_cloud_conversion`。按项目规则它们**就该用 `--headless`**。

> 结论：本项**无需修改**。初版"大量 demo 文档对 GPU 脚本写 headless"为误报。强行给 CPU-only 脚本加 `--rendering-driver vulkan` 反而不符合规则。
> 唯一可保留的后续建议：扩展 `test_markdown_contracts` 契约清单覆盖更多含 GPU 脚本的文档，防止未来命令示例回退到 `--headless`。

### 4.2 文档-代码差异

| 级别 | 位置 | 声称 | 实际 |
|---|---|---|---|
| 高 | README、`meshfill-framework.md`、`scene-voxel-field-system.md`、`target-scene-voxel-projection.md`、`asset-semantic-probes.md` | 脚本路径 `scripts/target_scene_voxel_generator.gd`，TargetSV "当前支持 GPU 生成/持久化/解码" | 文件已改名为 `…(暂停开发).gd`，文档未标注暂停，路径加载断链（见第 2 节） |
| 低 | `docs/bugs/double-rid-committed-payload-buffer.md` 顶部 | 引用 `GPU_BUFFER_LIFECYCLE.md L603 风险条目 3` | 该文件仅 579 行，无 L603，全文无"风险条目"章节，悬空引用 |
| 低 | README、`scene-voxel-field-system.md` 等 | "84+ 个 GLSL compute shader" | 实际 81 个 `.glsl` + 1 个 `.gdshader`，略夸大 |
| 低 | README 文档导航 | 将 `scene-voxel-field-system.md` 标为 "SceneVoxel 字段契约" | 该文件 H1 实为 `# Complexity Field System`，标题与导航描述不一致 |

> 已逐一核实：所有核心类名、关键函数、`SharedPropertyType.SHARED_FIELD_KEYS`（color/complexity/collision）、文档提及的全部 shader 文件、docs/graphs 的 13 个 SVG 与文档引用**均一致**。`double-rid` bug 已在 `scene_voxel_committer.gd`（committed_payload_reused 原地复用逻辑）确认修复、未复现。

### 4.3 失效资源引用汇总

| 引用方 | 引用路径 | 状态 | 级别 |
|---|---|---|---|
| `target_sv_point_cloud_demo.gd:4` | `res://scripts/target_scene_voxel_generator.gd` | 缺失（已改名） | 严重 |
| `tools/test_target_sv_point_cloud_conversion.gd:3` | `res://scripts/target_scene_voxel_generator.gd` | 缺失（已改名） | 严重 |
| demo `.gd`/`.json`/`.md` | `res://textures/scene_height_0_1.png` | 缺失（仅存 `.import`） | 中 |
| demo `.json`/`.md` | `res://landscape/TargetSV_PT.bgeo.sc` | 缺失（仅元数据，运行期不加载） | 低 |
| `scripts/` | `target_scene_voxel_generator.gd.uid` | 对应 .gd 已改名，孤立 uid | 低 |

> 所有 `.tscn` 的 `ext_resource` 实体均存在且有效；失效引用全部来自 `.gd` 内部 preload 与外部数据/贴图。

---

## 5. 可优化点

### 5.1 GPU 性能热点

| # | 文件 | 级别 | 问题 | 建议 |
|---|---|---|---|---|
| D1 | `score_voxel_tile.glsl` | 高 | `evaluate_best_near` 半径最大时遍历 729 候选，每候选内 `runtime_bounds_overlap`/`min_spacing_full_scan` 又全量扫描 ≤4096 运行时对象，512×729×4096 量级密集嵌套，是全 shader 最大热点 | runtime 排斥检查提到搜索循环外只对 base 候选做一次，或强制走 object-ref 稀疏路径 |
| D2 | `score_voxel_tile.glsl` | 中 | `write_debug_voxel` 对 base 候选额外再做一次完整 `evaluate_candidate`（best_near 中已算过），重复计算 | 缓存复用 |
| D3 | `reduce_voxel_tiles` / `reduce_anchor_topk_to_voxel_regions` / `pack_candidate_route_records_from_votes` / `expand_scene_voxel_tile_routes` / `score_scene_voxel_feedback` 等 | 中 | 均 `local_size=1` 单线程串行全扫描（reduce_voxel_tiles 为三重 O），规模增大成瓶颈 | 改并行规约或分块 |
| D4 | `expand_…` 与 `pack_…_from_votes` | 中 | 两文件逻辑高度重复（tile_pos/in_bounds/半径膨胀/去重/range 写出），仅 expand 多空 tile 跳过 | 合并为带开关的单 pass |
| D5 | 多个统计/展开 pass | 低 | `reduce_scene_voxel_stats` / `terrain_collision_volume` / `target_scene_voxel` 对整卷密集遍历，多数体素空 | 接入已有稀疏 tile 列表做线程重映射 |

### 5.2 GDScript 优化

| # | 位置 | 级别 | 问题 | 建议 |
|---|---|---|---|---|
| E1 | `voxel_placement_generator.gd run_multi_asset` | 中 | 循环内反复 `common_settings.duplicate(true)`（每 asset、每 pivot 各一次深拷贝），settings 键多，开销显著 | 不变部分提到循环外，循环内只覆盖差异键 |
| E2 | `voxel_placement_generator.gd` | 低 | GPU-resident 链路下仍 `complexity_field.duplicate()/collision_field.duplicate()`，但该分支这两份 CPU 数组不被使用 | 按分支跳过拷贝 |
| E3 | `auto_voxel_runtime_profile_container.gd:380-520` | 低 | 大量两层别名单语句函数（`get_*→export_*→_duplicate_*` 互相转发） | 合并为单层，减少调用栈 |
| E4 | `voxel_placement_generator.gd` debug readback | 低 | debug 分支对 256³≈67MB voxel field 全量回读，`read_full_field_outputs` 误置 true 会造成大额 PCIe 回读 | 保留 size 限定参数并文档化为 debug-only |
| E5 | `scene_voxel_committer.gd`（约 30 处 `buffer_get_data`） | 低 | 散落的同步式回读点，生产路径若误触发拖慢主流程 | 统一用 `readback_stats` 类开关门控 |

### 5.3 命名 / 风格

- `scripts/target_scene_voxel_generator(暂停开发).gd`：文件名含中文全角括号，作为资源路径在跨平台/导出/preload 时易出问题 → 重命名为 ASCII 并加 `.disabled` 或移出 `scripts/`。
- `pack_candidate_route_records_from_votes.glsl` 与 `expand_scene_voxel_tile_routes.glsl` 输出契约相同但 debug magic 不同（"GPRP" vs "ESVR"），下游按 magic 分支易混用 → 文档化或合并。
- `score_voxel_tile.glsl` set=1 binding 跳号（…9, 11, 12，缺 10）：稀疏绑定合法但须与 GDScript uniform set 精确对齐 → GDScript 侧注释保留 binding 10 占位说明。
- 注释拼写：多处 `completely = max(...)` 用词不准（应为 completeness/occupancy）；`collect_sv_anchors.glsl` 有空逻辑块 `if (ly==0u && lz==0u) { // Not needed }` 可删。
- 新旧命名并存：`voxel_write_spec`（legacy 别名）vs `instance_stamp_write_spec`/`ISWS`（新名）→ 收敛 legacy 别名。

---

## 6. 测试覆盖缺口

| 文件 | 级别 | 状态 |
|---|---|---|
| `scripts/scene_voxel_brush.gd` | 中 | 零专项测试覆盖 |
| `scripts/scene_voxel_volume_channels.gd` | 中 | 零覆盖 |
| `scripts/scene_voxel_tile_codec.gd` | 中 | 无往返编解码测试（编解码逻辑最需要） |
| `scripts/terrain_initializer.gd` | 低-中 | 仅 1 处引用，覆盖薄弱 |
| `scripts/scene_voxel_commit_payload.gd`、`shared_property_type.gd` | 低 | 数据/类型契约，建议补轻量测试 |

> 测试自身缺陷（✅已修复）：`tools/test_autoobject_probe_prefilter.gd` 的 `_has_rendering_device()` 此前创建 local RenderingDevice 后从不 `free()`，被 13 个子测试反复调用导致设备泄漏。已改为 probe 成功后立即 `local_rd.free()` 再返回 true。

---

## 7. 工程配置 / 工具脚本

| # | 文件 | 级别 | 问题 | 建议 |
|---|---|---|---|---|
| F1 | `project.godot` | 中 | 未配置 `rendering/rendering_device/driver`，仅 `config/features` 含 "Forward Plus"，驱动完全依赖命令行 `--rendering-driver vulkan` | 显式写入 rendering driver，避免 editor 默认与测试约定不一致 |
| F2 | `.gitignore` | 中 | 未忽略 `*.raw`/`*.exr`/`*.r32f`/`*.rgba32f` 等 GPU 中间产物，存在误提交临时产物风险 | 确认这些是源资产还是可再生产物，对后者补忽略规则 |
| F3 | `tools/terrain/gen_textures.py` | 中 | 顶部无条件 `import cv2`，但默认路径（`USE_EXR_SOURCES=False`）不需要它，缺 opencv 时整脚本 import 失败；末尾 cliff 处理 `img[:,:,2]` 未校验通道数 | cv2 import 延迟到使用分支；cliff 分支加通道校验 |
| F4 | `tools/verify_svg_render.py` | 低 | width/height 含单位（如 "256px"）时退回默认 1480×1120，可能截图裁切 | 解析时剥离单位 |
| F5 | `tools/validate_glslang.ps1` | 低 | 用 `$args` 覆盖 PowerShell 自动变量；验证器路径硬编码特定版本目录 | 重命名为 `$validatorArgs` |
| F6 | `skills/compute-shader-authoring/SKILL.md` | 低 | 多处给出外部绝对路径 `D:\.aidata\skills\...`，与项目内置 `skills/compute-shader-authoring/scripts/` 不一致 | 统一为项目内相对路径 |

---

## 8. C2 决策：stamp_voxel_field 的 complexity 竞争

C2 无法像 C1 那样直接修掉，需要架构决策，原因如下：

- `complexity_field` 是 `vec4[]` buffer，complexity 存在 `.a` 分量、color 存在 `.rgb` 分量。**GLSL 的 atomic 操作只能作用于整型 buffer 成员，无法对 vec4 的单个 float 子分量做原子化**，所以不能照搬 collision 的 `atomicMax`。
- 实测下游消费者（`score_voxel_tile` / `score_scene_voxel_feedback` / `reduce_scene_voxel_stats` / `pack_target_field` / `reduce_scene_voxel_tile_summaries` / `update_scene_voxel_tile_summary_ranges`）**全部只读 `.a`**；`.rgb`（color）当前无 shader 读取，但会被 GDScript 作为 SceneVoxel 提交 color 回读，属有效数据，不能丢弃。
- 无法静态证明被接受的 placement 之间 footprint 一定不共享体素（multi-asset、多 pivot 共写同一 field buffer），所以竞争客观存在。

可选方案（需用户拍板，均超出"直接改 bug"范围）：

1. **拆分 buffer 布局**：complexity 独立成 `float`/`uint` buffer 用 CAS-float-max（与 collision 同款），color 单独存。最干净，但要同步改 6 个读端 shader + GDScript 上传/回读契约，改动面大。
2. **CPU 端不重叠分桶 dispatch**：保证每次 stamp dispatch 内被接受的 result 不写同一体素（或按体素分桶串行），shader 不变。改动集中在 `voxel_placement_generator._dispatch_stamp` 调度侧。
3. **接受"color 跟随最后写入者、complexity 取并集语义弱保证"**：维持现状，在 shader 注释中明确该竞争为已知可接受行为（若上层逻辑本就保证同体素只被一个 result 命中）。

> 建议先确认实际是否存在"多 result 命中同体素"的运行路径；若 overlap 拒绝已在 score/reduce 阶段保证互斥，则 C2 可降级为方案 3 + 注释说明。

---

## 9. 优先级建议（修复顺序）

1. **立即**：统一处理 `target_scene_voxel_generator(暂停开发).gd` 改名 —— 重命名为 ASCII + 修正 A1/A2/A3 三处引用 + 清理孤立 uid + 文档标注暂停。（解决阻断 + 高级文档差异 + 严重失效引用）
2. **高**：~~C1 越界~~（✅已修，glslang 通过）；~~测试设备泄漏~~（✅已修）；C2 需按第 8 节决策推进。
3. **中**：B1（注：实时核查发现 `autoobject_probe_prefilter_gpu.gd` 已引入 `PREFILTER_DISPATCH_AXIS_LIMIT` + `_linear_dispatch_groups` 2D 网格分解，B1 看起来已在工作区被修复，但 `test_autoobject_probe_prefilter.gd` 第 228-242 行对这些成员的访问仍报 lint 错误，需核实测试与脚本接口是否对齐）、B2（dispose owns 守卫）、C3/C4/C5 语义与边界、`project.godot` 驱动配置、`.gitignore` 产物规则、`gen_textures.py` cv2 依赖。
4. **优化**：D1 评分热点、E1 深拷贝、补 scene_voxel_brush/volume_channels/tile_codec 测试。

---

*报告由分区并行扫描汇总，行号基于扫描时源码状态，修复前请以当前文件为准。*
