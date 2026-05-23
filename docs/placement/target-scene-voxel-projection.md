# TargetSceneVoxel Projection — Stamp 画布与 Anchor 投影

本文定义 `TargetSceneVoxel`（简称 `TargetSV`）的语义边界、当前 GPU 生成/持久化路径，以及后续 stamp、VDB 导入和 anchor projection cache 的计划。本文只描述目标场和候选路由输入，不把目标场当作最终 `SceneVoxel` 或资产选择结果。当前命名约定中，`TargetSV` 保留源目标画布，`BrushSV` 保留目标画布的笔刷 delta / override，`TargetSV_B` 表示 `TargetSV + BrushSV` 的 brush-composited 目标画布，并作为 prefilter / routing / scoring 的实际读取输入。

## 目标边界

`TargetSceneVoxel` 是目标视觉效果画布。它表达“希望最终场景看起来是什么样”，而不是“当前已经放置了哪个 asset”。

允许写入 `TargetSV` 的信息：

| 字段 | 含义 |
| --- | --- |
| `color.rgb` | 目标视觉颜色 |
| `complexity` / `value` | 目标复杂度或占用强度 |
| `collision` / `solid_intent` | 目标碰撞 / solid 倾向 |

不应写入 `TargetSV` 的信息：

| 禁止字段 | 原因 |
| --- | --- |
| `asset_type = tree` | 资产类型属于 routing 结果，不是目标画布内容 |
| `asset_group = rock` | 会把中性目标场污染为资产标签 |
| `placement_role = canopy` | role 应由 probe / projection / matcher 推断 |

## 当前实现状态

当前实现已接入 GPU 生成、持久化和调试显示：

![当前 TargetSV GPU 生成、持久化与调试显示流程](../graphs/target-scene-voxel-current.svg)

| 项 | 当前实现 |
| --- | --- |
| 生成脚本 | `scripts/target_scene_voxel_generator.gd` |
| Compute shader | `shaders/target_scene_voxel.glsl` |
| 数据形态 | `texture_size × slice_count × texture_size` 的 3D flat buffer |
| visual buffer | `target_scene_voxel_visual.rgba32f`，每 voxel 为 `vec4(color.rgb, complexity/value)` |
| collision buffer | `target_scene_voxel_collision.r32f`，每 voxel 为 `collision_peak` |
| preview | `target_scene_voxel_preview.png`，用于 Godot 调试显示 |
| metadata | `target_scene_voxel.json` |
| brush source layer | `BrushSV` delta / override；需要独立保存，不能只烘进 `TargetSV_B` |
| brush-composited variant | `target_scene_voxel_b_visual.rgba32f`、`target_scene_voxel_b_collision.r32f`、`target_scene_voxel_b_preview.png`、`target_scene_voxel_b.json` |
| 保存目录 | `user://target_scene_voxel/` |

当前 `TargetSceneVoxelGenerator.generate()` 输入：

| 输入 | 来源 | 用途 |
| --- | --- | --- |
| `scene_depth_img` | runtime terrain texture `scene_depth` | 推导地形高度和支撑上下文 |
| `target_height_img` | 源 target height 或 brush-composited target height | 推导目标高度差和体积意图；源输入写 `TargetSV`，笔刷合成输入写 `TargetSV_B` |
| `rock_mask_img` | 当前 rock mask，可为空 | 增强 cliff / rock 目标信号 |
| `dirty_rect` | 默认为整张图 | 限定 GPU dispatch 范围 |

当前 `main.gd` 交互：

| 输入 | 行为 |
| --- | --- |
| `Ctrl+J` | 全量重新计算并保存源 `TargetSV`，再与已保存 / 当前 `BrushSV` 合成并保存 `TargetSV_B` |
| `J` | 显示 / 隐藏已持久化的 `TargetSV_B` preview overlay |

## 数据契约

`TargetSV` 是源目标画布，不是 committed scene state。`BrushSV` 是目标画布的笔刷 delta / override，同样需要持久化。真正传给 placement / prefilter 的目标查询输入是 `TargetSV_B`；当没有笔刷覆盖时，`TargetSV_B` 可以与源 `TargetSV` 内容相同或回退到源 `TargetSV`。

| 数据 | 归属 | 消费者 |
| --- | --- | --- |
| `target_occupancy` | 从 `TargetSV_B` 读取的目标复杂度 / 占用强度 | `score_voxel_tile.glsl`、`score_anchor_asset_probes.glsl` |
| `target_color` | 从 `TargetSV_B` 读取的 packed RGBA8 目标颜色和复杂度 | `score_voxel_tile.glsl`、`score_anchor_asset_probes.glsl` |
| `target_scene_voxel_visual.rgba32f` | 持久化源 `TargetSV` visual buffer | source target / debug / import 回查 |
| `target_scene_voxel_collision.r32f` | 持久化源 `TargetSV` collision intent | source target / debug / import 回查 |
| `BrushSV` delta / override | 持久化目标画布笔刷层 | 与源 `TargetSV` 重新合成 `TargetSV_B`；undo / redo / debug 回查 |
| `target_scene_voxel_b_visual.rgba32f` | 持久化 `TargetSV_B` visual buffer | prefilter / routing / scoring / debug 默认输入 |
| `target_scene_voxel_b_collision.r32f` | 持久化 `TargetSV_B` collision intent | prefilter / routing / scoring / debug 默认输入 |

`TargetSV` / `BrushSV` / `TargetSV_B` 都不参与 committed SceneVoxel source write 或 `blend_scene_voxels()` 合成；`TargetSV_B` 只作为 routing、target fit 和 scoring 的输入。最终 `collision_field` 仍由 committed `SceneVoxel.collision_voxels` 重建为派生查询视图。

## Anchor 语义

当前 GPU prefilter 从两个位置来源提取 anchor，但写入同一个 position-only `anchor_buffer`。`anchor_kind` 不再作为字段存储；anchor 的 voxel 位置本身表达它来自支撑面还是目标顶部 / 上层目标信号。

| 位置来源 | 当前 shader 定义 |
| --- | --- |
| 支撑面 position | 当前 voxel 满足 target 阈值、scene/collision 阈值，并且下方 support 足够 |
| target-top position | 每个底层 dirty tile 的局部 XZ column 中最高的 target-occupied voxel；不强制 support，因为它是语义对齐点 |

实现位置：

| 文件 | 职责 |
| --- | --- |
| `shaders/collect_sv_anchors.glsl` | 从底层 dirty tiles 收集 position-only anchors |
| `shaders/score_anchor_asset_probes.glsl` | 按 asset probe 对 position-only anchors 评分 |
| `scripts/autoobject_probe_prefilter_gpu.gd` | 生成 GPU `AnchorState` / candidate route buffer；`autoobject_candidate_voxel_sparses` 只作为兼容 / debug readback 视图 |

target-top position 不是资产类型，也不是最终 placement 点。它只是候选位置来源，表示目标场顶部或上层强信号附近存在可被 probe 匹配的候选位置。

## Candidate voxel region 边界

高层路由输出使用 `voxel region` 术语；当前实现中的 `voxel_sparse` / `candidate_voxel_sparses*` 只作为兼容 API 名称保留：

```text
upstream prefilter
  -> GPU AnchorState(score/topK)
  -> candidate route buffer
  -> candidate voxel regions
  -> candidate_voxel_sparses_by_asset compat/debug view
  -> score_voxel_tile.glsl
```

底层 shader 和 buffer 仍可以使用 `tile_id`：

| 术语 | 使用层级 | 说明 |
| --- | --- | --- |
| `voxel region` | public routing / placement prose | 候选或 dirty 的高层区域；当前通常映射到 `8×8×8` block。 |
| `candidate_voxel_sparses*` / `voxel_sparse` | 当前兼容 API | 历史命名，语义上表示 candidate voxel regions。 |
| `tile_id` | shader / buffer / storage key | 同一个 block 的物理索引和 workgroup key。 |
| `dirty_tile_ids` | 底层兼容 API | 表示 dirty voxel regions 的 tile id 列表。 |

Candidate voxel regions 必须偏向召回。Routing 阶段不要过早剔除；footprint、support、collision、clearance 和 target fit 由 `score_voxel_tile.glsl` 精筛。

## Stamp 系统计划

Stamp 系统负责把目标视觉效果绘制到 `TargetSV`，不是直接生成真实 asset。

```text
landscape slope / masks / procedural rules
  -> target stamp scheduler
  -> stamp rasterizer
  -> TargetSV color + complexity + collision intent
```

示例 stamp：

| Stamp | 触发来源 | 写入 TargetSV 的中性结果 |
| --- | --- | --- |
| `CliffRockStamp` | 高坡度、悬崖 mask、侵蚀噪声 | 灰 / 土色、高 complexity、高 collision，体积相对地表升高 |
| `GrassPatchStamp` | 绿地 mask、草地权重、低坡度区域 | 贴地绿色、低 / 中 complexity、低 collision |
| `TrunkStamp` | 树意图点、森林 mask、规则撒点 | 棕色竖向体积、中 complexity、高 collision |
| `CanopyStamp` | 树意图点上方、冠层规则 | 上空绿色团块、高 complexity、低 / 中 collision |

Stamp 名称只属于生成器或编辑器内部，不应写入 `TargetSV` buffer。写入后的 `TargetSV` 仍然只包含颜色、复杂度、占用 / 碰撞意图。

### Stamp record

计划中的 stamp record：

| Field | Meaning |
| --- | --- |
| `origin_voxel` | stamp 锚点，通常来自 landscape surface 或支撑点 |
| `basis` | stamp 局部坐标，可由 world-up、坡面法线或 cliff tangent 生成 |
| `bounds` | stamp 影响的 voxel AABB |
| `source_voxels` | 可选的 AutoObject 烘焙局部 `voxel_write_spec` samples |
| `opacity` | visual 混合权重 |
| `collision_opacity` | collision intent 混合权重 |
| `scale` | stamp 缩放 |
| `priority` | 多 stamp 冲突时的优先级 |

## Blend 规则

visual 和 collision 应分开混合。颜色和复杂度可以加权平均；collision / solid intent 不应被普通平均稀释。

```text
target.rgb        = weighted_average(target.rgb, source.rgb, opacity)
target.complexity = weighted_average(target.complexity, source.complexity, opacity)
target.collision  = max(target.collision, source.collision * collision_opacity)
```

原因：

- 草和树叶可以持续影响颜色 / complexity。
- 树干、岩石、墙体等强 collision intent 不应被后续低碰撞 stamp 稀释。
- 如果后续需要表达整体倾向和强峰值，可拆成 `collision_avg` 与 `collision_peak`。

## 外部 VDB 导入计划

状态：计划中。当前仓库还没有 VDB 转换脚本或 Godot 侧外部 TargetSV 加载接口。

目标流程：

```text
Houdini / DCC
  -> export VDB grids
  -> offline converter
  -> target_scene_voxel_visual.rgba32f
  -> target_scene_voxel_collision.r32f
  -> target_scene_voxel.json
  -> Godot runtime loads TargetSV buffers
```

计划支持的 VDB grid：

| Grid | TargetSV 映射 |
| --- | --- |
| `Cd.x` / `color.r` | `visual[].r` |
| `Cd.y` / `color.g` | `visual[].g` |
| `Cd.z` / `color.b` | `visual[].b` |
| `density` / `value` | `visual[].a` |
| `collision` | `collision[]` |

导入规则：

- 外部 VDB 应离线重采样到运行时 TargetSV 网格。
- 运行时不直接加载高分辨率 dense VDB。
- visual 使用加权平均或 box filter。
- collision 使用 `max` 或 high percentile，保留强 solid intent。
- metadata 应记录 source files、grid dimensions、coordinate transform 和版本。

## Projection cache 计划

Projection cache 是面向 candidate anchors 的压缩特征，不是原始 `TargetSV` 数据，也不是资产标签。

计划缓存：

```text
target_anchor_projection_rgba8[anchor]
```

第一版可以按垂直柱压缩：

```text
for each (x, z) column:
  read TargetSV color / complexity / collision over y
  pool into configured vertical channels
  write summary to nearest supported anchor or ground anchor
```

推荐 pooling：

| 方法 | 用途 |
| --- | --- |
| `complexity ^ gamma` 加权颜色 | 高复杂度目标主导颜色 |
| `peak complexity` | 保留强目标信号 |
| `mass` | 表示该 channel 目标总量 |
| `occupancy_ratio` | 区分真实结构和单点噪声 |

推荐默认：

```text
gamma = 2
```

Projection cache 只能用于候选 route 的验证、rerank 或 pruning，不能绕过 upstream prefilter，也不能从全资产库生成新候选。

## 与 semantic routing 的关系

当前主线：

```text
dirty / active voxel regions
  -> collect anchors
  -> AutoObject probe prefilter
  -> autoobject candidate voxel regions
  -> candidate_voxel_sparses_by_asset compat view
  -> score_voxel_tile.glsl physical scoring
```

可选 route validation 可以读取：

| 数据 | 用途 |
| --- | --- |
| `target_occupancy` | target coverage / value fit |
| `target_color` | target color fit |
| `target_anchor_projection_rgba8` | 后续 projection rerank |
| asset semantic probes | 候选资产内部验证，不遍历全资产库 |

`score_voxel_tile.glsl` 当前只读取 `target_occupancy` 和 `target_color`，不读取 projection cache。

## Dirty 更新计划

Stamp 是 `TargetSV` 的生产者，因此 dirty 更新应从 stamp bounds 开始：

```text
dirty landscape / mask / brush
  -> reschedule affected stamps
  -> clear and rerasterize affected TargetSV bounds
  -> mark dirty target bounds
  -> update target anchor projection for affected anchor regions
  -> rerun prefilter / route validation for affected voxel regions
```

保守规则：

- TargetSV dirty bounds 应包含 stamp bounds 和最大 stamp radius。
- Projection dirty bounds 可能大于 TargetSV dirty bounds，因为高处目标会投影到下方 anchor。
- Public prose 使用 `dirty_voxel_region_*` / dirty voxel region 术语；当前兼容 API 仍可能保留 `dirty_voxel_sparse_*` 或底层 `dirty_tile_ids`。

## 推荐阶段

| Phase | 目标 |
| --- | --- |
| 0 | 保持当前 GPU TargetSV 生成和持久化稳定 |
| 1 | 修复 `target_top` anchor 预期和测试，明确 target-top collection 规则 |
| 2 | 添加 stamp record / rasterizer 的 CPU debug 版本 |
| 3 | 将 stamp rasterizer 迁移到 compute shader |
| 4 | 添加垂直 column projection cache |
| 5 | 添加水平扩散、多 anchor contribution 或 learned matcher |
| 6 | 增加外部 VDB 离线导入 |

## 验收标准

- `TargetSceneVoxel` 不包含 asset 类型标签。
- `TargetSceneVoxel` 表达目标颜色、复杂度、占用 / 碰撞意图。
- target-top position 定义与 `collect_sv_anchors.glsl` 一致；不再存 `anchor_kind` 字段。
- 高层候选区域使用 `voxel region` 术语；`voxel_sparse` 只作为兼容 API 名称。
- 底层 shader 的 `tile_id` 只作为物理 storage / workgroup key。
- `score_voxel_tile.glsl` 不读取 projection cache。
- 未启用 projection 时，routing 回退到当前 `target_occupancy` / `target_color` 路径。
