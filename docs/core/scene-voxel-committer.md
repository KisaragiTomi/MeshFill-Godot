# SceneVoxelCommitter 源码导览

本文按源码职责展示 [`scripts/scene_voxel_committer.gd`](../../scripts/scene_voxel_committer.gd) 的主要内容。它不是替代契约文档；`AutoVoxelDescriptor` 资产默认语义见 [`auto-voxel-descriptor.md`](auto-voxel-descriptor.md)，`SceneVoxel` source 写入 / 已提交 payload 见 [`scene-voxel-field-system.md`](scene-voxel-field-system.md)，`SceneVoxelTile` dirty 和常驻 buffer 细节见 [`scenevoxeltile.md`](scenevoxeltile.md)，框架级所有权见 [`meshfill-framework.md`](meshfill-framework.md)。

`SceneVoxelCommitter` 是 MeshFill 的 SV 运行时所有者 / 提交器。它持有 grid 参数、source 写入暂存、已提交 `SceneVoxel`、SV 常驻 `scene_field` / `collision_field`、`SceneVoxelTile` dirty sidecar、GPU storage buffer 和调试 readback 边界。

## 本文范围

- 快速定位 `scene_voxel_committer.gd` 中的代码块。
- 展示脚本维护的状态域、GPU shader 阶段、buffer 和主要 API。
- 说明 `build_voxel_volume()`、`apply_voxel_write_spec()`、`blend_scene_voxels()`、`_rebuild_sv()`、`ensure_scene_voxel_tile_buffers_uploaded()` 的数据流。
- 标明当前 GPU-first 边界：GDScript Dictionary 多用于控制 / 暂存 / 调试，不是运行时权威数据源。

源码按功能模块划分，详见 `scene_voxel_committer.gd` 源码注释。主要功能域：

- **初始化与 GPU pipeline**：shader/pipeline 创建、dispatch helper、资源释放
- **Grid 与坐标转换**：world/voxel/pixel 映射、collision image 合成
- **SceneVoxelTile 管理**：record/summary 构造、GPU buffer 上传、readback、dirty 兼容
- **Source 写入与合成**：`ISWS` 归一化、Auto/Brush source stream、`blend_scene_voxels()` 发布
- **SV 状态与查询**：volume 构建、occupancy 查询、feedback scoring、dirty API

## 状态域

| 状态域 | 字段 / 常量 | 用途 |
| --- | --- | --- |
| 网格 / volume | `grid_size`、`voxel_size`、`grid_origin`、`_base_res`、`_capture_size` | world / voxel / pixel 映射和 SV grid 权威状态。 |
| Occupancy / collision 图像 | `_occupancy`、`_source_collision_field`、`_terrain_base_collision_field`、`_collision_field` | channel occupancy、source collision、terrain base collision 和合成 collision image。 |
| GPU 资源 | `_shader_*`、`_pipeline_*`、`_sampler`、`_gpu_ready` | 启动 shader pipeline 和惰性 compute helper 的 `RenderingDevice` 状态。 |
| 已提交 volume | `_volume`、`_scene_state_by_tick` | voxel slice、slice metadata、已提交 `scene_voxels`、collision record 和逐 tick snapshot。 |
| Source 写入暂存 | `_voxel_write_specs`、`_auto_scene_voxel_sources`、`_brush_scene_voxel_sources`、pending candidate maps | `ISWS` / legacy `voxel_write_spec` 归一化、Auto / Brush source stream 和同 key candidate 仲裁。 |
| SV snapshot | `_sv`、`_sv_dirty`、`_sv_dirty_tiles`、`_sv_dirty_rects` | 已发布 SV 常驻状态和 legacy dirty 兼容存储。 |
| `SceneVoxelTile` 暂存 | `_scene_voxel_tiles`、`_scene_voxel_tile_gpu_autoobject_refs`、debug id arrays | named tile dirty record、object/source debug range 和 GPU AutoObject dirty delta bridge。 |
| `SceneVoxelTile` GPU buffers | `_scene_voxel_tile_gpu_buffers`、byte sizes、record counts、hashes、revision fields | tile record / summary / dirty index / ref / resident field 的 storage buffer 生命周期。 |
| Tick | `_generation_tick`、`_committed_tick` | source 写入 tick、commit promotion 和 stable read tick。 |

## 主流程

```text
_init(base_resolution, capture_size)
  -> 分配 occupancy / collision image
  -> _init_gpu()
  -> 要求 RenderingDevice 和启动 compute pipeline 可用
```

```text
build_voxel_volume(xz_resolution, channel_profiles)
  -> 收集 channel descriptor
  -> 构建 occupancy slice
  -> _apply_volume_grid_metadata()
  -> 为新 volume 重建 source record
  -> blend_scene_voxels()
  -> _rebuild_sv()
```

```text
apply_voxel_write_spec(record)
  -> SceneVoxelSourceRecord.prepare_source_record()
  -> target guidance record 只标记 target dirty
  -> stamp occupancy / collision shared field
  -> 排队 AutoSceneVoxel 或 BrushSceneVoxel source candidate
  -> 按需执行 blend_scene_voxels(write_tick)
```

```text
blend_scene_voxels(tick)
  -> 通过 resolve_scene_voxel_sources.glsl flush pending source candidate
  -> 选择 full source scan 或 dirty SceneVoxelTile scope
  -> commit_scene_voxel_payloads.glsl 合并 Auto / Brush payload
  -> 写入已提交 _volume["scene_voxels"]
  -> _rebuild_sv() 发布常驻 scene/collision field 和 tile snapshot
```

```text
ensure_scene_voxel_tile_buffers_uploaded(force)
  -> 打包 tile record、summary、dirty id、object ref、source ref
  -> 打包常驻 scene_field 和 collision_field
  -> resident buffer 可复用时更新 dirty range
  -> 否则创建完整 GPU storage buffer
  -> 将 uploaded_revision 推进到 staging_revision
```

## GPU 计算阶段

启动时 `_init_gpu()` 加载 18 个 compute shader。少数 helper 会在需要时惰性加载额外 shader。

| Shader | 调用点 / 职责 |
| --- | --- |
| `channel_import_mask.glsl` | `import_mask_channel()` 将 mask 导入 occupancy channel。 |
| `channel_filter_candidates.glsl` | `_gpu_filter_candidates()` 按 channel occupancy 过滤 candidate pixel。 |
| `max_collision_images.glsl` | `_max_collision_images_gpu()` 发布 `max(source, terrain)` collision image。 |
| `blend_scene_voxel_fields.glsl` | `_try_make_sv_scene_field_from_source_streams_gpu_result()` 写入密集常驻 `scene_field`。 |
| `commit_scene_voxel_payloads.glsl` | `_try_blend_scene_voxel_commit_payloads_gpu()` 合并 Auto / Brush source payload。 |
| `resolve_scene_voxel_sources.glsl` | `_try_resolve_scene_voxel_source_candidates_gpu()` 为每个 source key 选择 winner candidate。 |
| `stamp_r32_disc.glsl` | `_stamp_scalar_image_disc_gpu()` 写入 scalar RF disc value。 |
| `stamp_rgba_channel_disc.glsl` | `_gpu_import_mask()` / `_stamp_occupancy_channel()` 更新 RGBA occupancy channel。 |
| `merge_sv_collision_records.glsl` | `_merge_sv_collision_records_gpu()` 合并 collision record field。 |
| `score_scene_voxel_feedback.glsl` | `_score_blendsv_feedback_against_target_gpu()` 比较已提交 BlendSV 和 target occupancy。 |
| `reduce_scene_voxel_stats.glsl` | `_reduce_scene_voxel_stats_gpu()` 计算 per-slice occupancy 和 collision count。 |
| `reduce_scene_voxel_tile_summaries.glsl` | `_reduce_scene_voxel_tile_summaries_gpu()` reduce tile scene/collision summary。 |
| `init_scene_voxel_tile_summaries.glsl` | 为 summary reduce 初始化 tile summary buffer。 |
| `compact_scene_voxel_tile_summaries.glsl` | 将 summary 输出 compact 成 CPU 可读的 tile summary record。 |
| `update_scene_voxel_tile_summary_ranges.glsl` | 为 dirty tile upload 更新 summary range。 |
| `scene_voxel_tile_object_ref_update.glsl` | 可选 fixed-per-tile object-ref update pass。 |
| `collect_disc_pixels.glsl` | `_collect_disc_pixels_gpu()` 收集被 stamp 的 source pixel。 |
| `sample_r32_pixel.glsl` | `_sample_scalar_image_pixel_gpu()` 为 query 采样 scalar image pixel。 |
| `resample_collision_field.glsl` | 惰性加载的 collision image resample helper。 |
| `terrain_collision_volume.glsl` | 惰性加载的 terrain base collision volume helper。 |
| `occupancy_slice_image.glsl` | 惰性加载的 occupancy channel slice image helper。 |

GPU dispatch 失败会在对应路径中报告失败或返回空结果。脚本不会把 CPU staging 当作 GPU-required 操作的成功 runtime fallback。

## GPU Buffer 清单

| Buffer name | Stride | 内容 |
| --- | --- | --- |
| `scene_voxel_tile_records` | `128` bytes | packed tile metadata、bounds、range 和 flag。 |
| `scene_voxel_tile_summaries` | `32` bytes | packed tile scene/collision summary。 |
| `scene_voxel_tile_dirty_indices` | `4` bytes | 当前 upload / readback scope 内的 dirty tile index。 |
| `scene_voxel_tile_object_refs` | `4` bytes | fixed-per-tile object ref id；当前默认每 tile `8` 个 ref。 |
| `scene_voxel_tile_source_refs` | `4` bytes | debug source ref hash / id。 |
| `scene_voxel_tile_scene_field` | `4` bytes | 密集常驻 scene complexity field。 |
| `scene_voxel_tile_collision_field` | `4` bytes | 密集常驻 collision field。 |

只有所有必需 buffer RID 有效且 `uploaded_revision == staging_revision` 时，`get_scene_voxel_tile_gpu_buffer_summary()` 才报告 `runtime_ready`。buffer 过期时，read source 字段返回 `none`，不会把 CPU staging 当成运行时数据。

## 对外 API

| 领域 | API | 说明 |
| --- | --- | --- |
| 网格 | `configure_scene_voxel_grid()`、`configure_from_sv()` | 更新 grid authority；metadata 变化时标记 full rebuild / staging dirty。 |
| 坐标转换 | `world_to_voxel()`、`voxel_to_world()`、`world_to_volume_pixel()`、`volume_pixel_to_world()` | 通过当前 grid metadata 转换 world、voxel 和 XZ volume pixel 坐标。 |
| Generation tick | `begin_generation_tick()`、`get_generation_tick()`、`get_committed_tick()` | 控制 source 写入 tick，并暴露 commit promotion。 |
| Source 写入 | `apply_voxel_write_spec()`、`apply_instance_stamp_write_spec()` | 应用一个归一化 runtime stamp / ISWS；target record 只标记 guidance dirty。 |
| 批量 source 写入 | `apply_voxel_write_specs()`、`apply_instance_stamp_write_specs()` | 批量 apply；除非 defer，否则只 blend 一次。 |
| Commit | `blend_scene_voxels()` | 发布已提交 public `SceneVoxel` payload，并重建 SV 常驻状态。 |
| Volume | `build_voxel_volume()`、`reset_occupancy()` | 构建 / 清理 volume slice、metadata、source stream 和常驻状态。 |
| 查询 | `query_voxel()`、`get_scene_voxel()`、`get_scene_voxels()` | 读取已提交 scene voxel payload 或直接采样 voxel 数据。 |
| Slice | `get_voxel_slice()`、`get_voxel_slice_meta()`、`get_voxel_slice_count()`、`get_voxel_column()` | 为 debug / validation 访问 volume slice 数据。 |
| SV | `get_sv()` | 返回已发布 SV snapshot；必要时重建或自动上传 tile buffer。 |
| Terrain collision | `set_terrain_base_collision_field()`、`get_terrain_base_collision_field()` | terrain base collision 变化会标记全部 `SceneVoxelTile` dirty。 |
| Dirty tile | `mark_scene_voxel_tile_dirty()`、`mark_scene_voxel_tile_bounds_dirty()`、`mark_all_scene_voxel_tiles_dirty()` | 推荐使用的 named dirty API。 |
| Legacy dirty | `invalidate_sv_tile()`、`invalidate_sv_rect()`、`get_sv_dirty_tiles()` | legacy `_sv_dirty_tiles` / `_sv_dirty_rects` 的兼容层。 |
| Tile GPU buffer | `ensure_scene_voxel_tile_buffers_uploaded()`、`get_scene_voxel_tile_gpu_buffer_summary()`、`readback_scene_voxel_tile_debug_snapshot()` | 上传、汇总并 readback tile metadata 和 resident field。 |
| 自动 upload | `set_scene_voxel_tile_gpu_auto_upload()`、`is_scene_voxel_tile_gpu_auto_upload_enabled()` | SV publish / getter 路径中的可选 upload。 |
| GPU AutoObject delta | `apply_gpu_autoobject_dirty_delta()`、`apply_gpu_autoobject_dirty_deltas()` | 把 object 新旧 voxel bounds 映射成 dirty `SceneVoxelTile` record。 |
| Object-ref update pass | `try_apply_gpu_autoobject_object_ref_update_pass()`、`try_apply_gpu_autoobject_object_ref_update_pass_from_buffer()` | 带 diagnostics 的可选 resident object-ref update pass。 |
| 统计 / 验证 | `get_voxel_stats()`、`validate_voxel()` | GPU reduce occupancy、collision 和 validation metrics。 |

## 发布的 SV Snapshot

`_rebuild_sv()` 将 `_sv` 发布为控制快照，包含常驻 field、grid metadata、dirty snapshot 和 tile 调试数据。

```gdscript
{
	"type": "SV",                                      # 快照类型
	"gpu_first": true,                                # GPU 路径是必需路径
	"cpu_fallback": false,                            # CPU staging 不是 runtime fallback
	"scene_field": PackedFloat32Array(),              # 密集常驻 complexity field
	"collision_field": PackedFloat32Array(),          # 密集常驻 collision field
	"grid_size": grid_size,                           # SV grid 尺寸
	"voxel_size": voxel_size,                         # 世界空间 voxel 尺寸
	"grid_origin": grid_origin,                       # 世界空间原点
	"commit_tick": _committed_tick,                   # 已提交 SV epoch
	"generation_tick": _generation_tick,              # 当前 generation tick
	"scene_voxel_tiles": _scene_voxel_tiles,          # tile 控制/调试 snapshot
	"dirty_scene_voxel_tiles": dirty_snapshot,        # named dirty tile
	"dirty_tiles": legacy_dirty_tiles,                # legacy 兼容 dirty storage
	"scene_voxel_tile_gpu_buffer_summary": summary,   # GPU summary 发布后补入
}
```

`scene_field` 和 `collision_field` 是从 committed state 派生的 resident read input，不是第二套 source write model。

## Source 写入边界

- 可接受的 source record 是 `AutoSceneVoxel` 或 `BrushSceneVoxel`。
- `TargetSceneVoxel` / `TargetSV_B` record 只属于 guidance：它们标记 target / routing / feedback dirty，但跳过 source stream commit。
- `_pending_auto_scene_voxel_source_candidates` 和 `_pending_brush_scene_voxel_source_candidates` 会暂存同 tick candidate，直到 `resolve_scene_voxel_sources.glsl` 选出 winner。
- `blend_scene_voxels()` 通过 `SceneVoxelPayloadScript.public_map()` 发布最小化的 committed public payload。
- Dirty-limited commit 会复制上一版 committed scene voxel，只重新计算 dirty `SceneVoxelTile` scope 内的 source key。

## `SceneVoxelTile` 边界

`SceneVoxelCommitter` 拥有 `SceneVoxelTile` dirty state，但 tile record 仍是内部 runtime metadata。

- `DEFAULT_SCENE_VOXEL_TILE_SIZE` 是 `Vector3i(4, 4, 4)`。
- Project setting key 是 `meshfill/scene_voxel_tile/size_voxels`。
- Dirty flag 与 `scene`、`collision`、`auto`、`brush`、`target`、`routing`、`scoring`、`feedback`、`object_refs` 和 `mask` category 按 bit 兼容。
- Tile metadata 和 debug range 不进入 committed per-voxel `SceneVoxel` payload。
- Runtime-ready tile read source 要求 GPU storage buffer 有效，并且 revision 匹配。

## GPU AutoObject Dirty Delta

`apply_gpu_autoobject_dirty_delta()` 接收 GPU AutoObject ownership 传来的 dirty delta，并映射到 previous / current bounds：

```gdscript
{
	"object_id": "42",                         # 接受的 alias 包含 auto id key
	"previous_voxel_min": Vector3i(4, 0, 8),   # 旧 bounds min
	"previous_voxel_max": Vector3i(8, 4, 12),  # 旧 bounds max
	"voxel_min": Vector3i(8, 0, 8),            # 新 bounds min
	"voxel_max": Vector3i(12, 4, 12),          # 新 bounds max
	"dirty_flags": {"auto": true},             # auto/object_refs 会被强制置 true
}
```

该方法会同时标记 previous bounds 和 current bounds dirty。removed object 只保留 previous-bounds dirty，并擦除暂存的 object ref record。

## 最小使用示例

```gdscript
var committer := SceneVoxelCommitter.new(128, 512.0)
committer.configure_scene_voxel_grid(Vector3i(64, 8, 64), Vector3(1.0, 0.5, 1.0))
committer.build_voxel_volume(64, channel_profiles)

var applied := committer.apply_instance_stamp_write_spec(record)
var committed := committer.blend_scene_voxels()
var sv := committer.get_sv()

committer.ensure_scene_voxel_tile_buffers_uploaded(true)
var gpu_summary := committer.get_scene_voxel_tile_gpu_buffer_summary()
```

## 验证入口

触及 `RenderingDevice`、compute shader、storage buffer 或 GPU readback 的测试需要使用 Vulkan rendering driver。

```powershell
godot --path . --rendering-driver vulkan --script tools/test_scene_voxel_field.gd
godot --path . --rendering-driver vulkan --script tools/test_scene_voxel_source_resolve.gd
godot --path . --rendering-driver vulkan --script tools/test_scene_voxel_resident_source_candidate_buffer.gd
godot --path . --rendering-driver vulkan --script tools/test_voxel_dirty_tile_upload.gd
godot --path . --rendering-driver vulkan --script tools/test_update_scene_voxel_tile_summary_ranges.gd
godot --path . --rendering-driver vulkan --script tools/test_scene_voxel_tile_object_ref_update.gd
godot --path . --rendering-driver vulkan --script tools/test_voxel_placement_record_commit.gd
godot --path . --rendering-driver vulkan --script tools/test_blendsv_feedback_score.gd
```

## 维护规则

- 修改 source write / public payload 时，同时检查 [`scene-voxel-field-system.md`](scene-voxel-field-system.md)。
- 修改 tile dirty、buffer pack / decode 或 readback 时，同时检查 [`scenevoxeltile.md`](scenevoxeltile.md)。
- 修改运行时 ownership 或 SPA 调用路径时，同时检查 [`scene-placement-actor.md`](scene-placement-actor.md) 和 [`autoobject-gpu-runtime-architecture.md`](autoobject-gpu-runtime-architecture.md)。
- `scatter()` / `scatter_from_mask()` 已完全删除；placement 必须通过 `AutoObjectProbePrefilterGPU` + `VoxelPlacementGenerator`。
- 不要把 `_sv`、`_scene_voxel_tiles` 或 `_scene_source_metadata` 写成运行时权威数据源；它们是 SV owner 的控制 / 调试平面。
- GPU-required path 缺少 `RenderingDevice` 时必须明确 skip 或 fail，不要新增 CPU fallback 后报告 GPU path passing。
