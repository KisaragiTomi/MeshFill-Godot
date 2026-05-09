# UE 风格的场景体素场系统

这份文档描述 MeshFill-Godot 当前已经落地的 UE 式两层：`AutoObject` 负责局部资产场，`SceneVoxel` / `GlobalVoxelField` 负责全局合并场。目标是把“物体是什么”和“物体放在哪里”分开，避免对象字段直接覆盖最终场景结果。

## 目标

- 资产只保存默认语义，不直接修改最终场景。
- 实例先生成来源体素，再进入统一混合。
- 全局查询走缓存，局部写入走 source delta。
- 如果需要更像 UE，就把全局缓存做成多分辨率 `clipmap`；如果先求可用，可以先做稀疏 `tile` occupancy。

## 分层

| 层 | UE 类比 | MeshFill 角色 | 读写原则 |
| --- | --- | --- | --- |
| 资产场 | `Mesh Distance Field` | `AutoObject` + `AutoVoxelProfile` | 只保存对象默认值 |
| 来源场 | 单个 mesh instance 的距离场 | `AutoSceneVoxel` / `BrushSceneVoxel` | 只写当前 tick 的 delta |
| 逻辑结果 | 混合后的场景体素 | `SceneVoxel` | 统一 commit 后的最终结果 |
| 物理缓存 | `Global Distance Field` | `GlobalVoxelField` / scene voxel cache | 只读快照 + dirty 重建 |
| 互斥层 | 独立 blocker | `CollisionVoxel` | 不和生态/可视 band 混用 |

## 数据流

```text
AutoObject fields
  -> make_*_scene_voxel_record()
  -> AutoSceneVoxel / BrushSceneVoxel
  -> blend_scene_voxels()
  -> SceneVoxel
  -> rebuild_global_voxel_field()
  -> GlobalVoxelField sparse occupancy tiles
```

## 字段职责

| 层 | 关键字段 | 说明 |
| --- | --- | --- |
| `AutoObject` | `voxel_color`、`voxel_complexity`、`affected_bands`、`collision_voxels`、`min_spacing`、`bound_min_length` | 持久化默认值和原型语义 |
| `SourceSceneVoxel` | `source_voxel_type`、`source_kind`、`producer_stage`、`generation_tick`、`read_tick`、`write_tick` | 描述本次来源体素的生成上下文 |
| `SceneVoxel` | `source_voxel_types`、`dominant_source_type`、`blend_mode`、`priority`、`commit_tick` | 描述最终混合结果 |
| `GlobalVoxelField` | `tile_id`、`clip_level`、`bounds`、`dirty`、`updated_this_commit`、`dirty_tiles`、`dirty_rects`、`distance_or_occupancy` | 当前为 sparse occupancy tile cache，后续可升级 signed distance |

## 体素写入规则

当前运行时代码把 UE 式全局写入规则收敛到 `scripts/vegetation_exclusion.gd`：

| 规则 | 代码入口 | 结果 |
| --- | --- | --- |
| source 只写当前 tick | `apply_mesh_voxel_record()`、`_prepare_source_record()` | 重复提交旧 `voxel_record` 时会把 `generation_tick` 和 `write_tick` 重新绑定到本次 tick，避免写回旧 delta |
| 同 key 冲突按来源优先级处理 | `_write_source_voxel_delta()`、`_source_beats_current()` | `BrushSceneVoxel` 默认优先级高于 `AutoSceneVoxel`；同优先级取更高 `value` |
| brush 只接管声明范围 | `_source_modifies_key()`、`modified_voxels` | `modified_voxels` 为空表示本次 stamp footprint 全接管；非空时只影响列出的 voxel key |
| 0 值主动编辑也要写 source | `_stamp_volume_slices()` | `erase` / `BrushSceneVoxel` 可以写入 `value = 0.0` 的来源体素，用未占用 `SceneVoxel` 覆盖上一轮结果 |
| target 复杂度 0 表示不放置 | `_merge_target_with_auto()`、`score_voxel_tile.glsl` | `TargetSceneVoxel` / `target_occupancy` 的 `value` 或 `complexity` 为 `0` 时，作为 placement mask 排除候选起点 |
| 最终状态只在 blend 发布 | `blend_scene_voxels()` | 只有 `SceneVoxel[commit_tick]` 暴露给查询、验证和全局缓存 |
| 全局缓存只读 committed sparse occupancy | `_rebuild_global_voxel_field()` | 只把已占用 `SceneVoxel` 和 `CollisionVoxel` 放入 tile cache；空体素保留在 `SceneVoxel` 中用于遮罩查询，但不进入 sparse tile |
| dirty tile/rect 只描述缓存失效范围 | `invalidate_global_voxel_tile()`、`invalidate_global_voxel_rect()`、`get_global_voxel_dirty_tiles()` | source / collision 写入会合并到 dirty tiles；重建后的 `GlobalVoxelField.dirty_tiles` 记录本次更新足迹，tile 用 `updated_this_commit` 标出 |

这些规则对应 UE 的“局部对象场先写入 update region，全局场再统一合并”的取舍：MeshFill 当前没有做 signed distance clipmap，但已经把写入边界、dirty tile 和最终只读快照分开。

## 当前实现

- `AutoObject` 只负责产出局部对象语义，不直接改最终场景体素。
- `main.gd` 中的 `_make_cliff_voxel_record()`、`_attach_vegetation_voxel_record()`、`register_brush_vegetation()` 会先构建 source 语义，再交给 `blend_scene_voxels()`。
- `blend_scene_voxels()` 是最终提交点，之后 `build_voxel_volume()`、`validate_voxel()` 和查询都读已提交结果。
- `vegetation_exclusion.gd` 现在同时承载 source delta、`SceneVoxel` commit、dirty tile/rect API 和 `GlobalVoxelField` 的 sparse tile cache。
- `CollisionVoxel` 保持独立，不并入生态 band。

## UE 式取舍

当前实现先走 sparse occupancy tile cache：`GlobalVoxelField` 记录 committed `SceneVoxel` 的 tile、bounds 和 dirty 状态，便于查询和重建。后续如果要更接近 UE，再把缓存升级成 signed distance narrow band。

场景修改当前不要求高实时性，所以暂不决定整个 `SceneVoxel` 或 `GlobalVoxelField` 是否常驻显存。当前只保留 CPU 侧权威状态和 dirty tile/rect 边界；如果后续 compute、预览或验证出现性能瓶颈，再决定是常驻 GPU、按需上传，还是升级成 clipmap / signed distance。

## 后续升级顺序

1. 保持 `AutoObject` 作为默认值主归属。
2. 保持 `blend_scene_voxels()` 为唯一提交点。
3. 已扩展 `GlobalVoxelField` 的 dirty rect / tile invalidation API。
4. 需要更高精度时，再把缓存升级成 clipmap / signed distance 版本。
