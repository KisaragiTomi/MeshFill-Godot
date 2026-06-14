# GPU Buffer 生命周期分类报告

> **SceneVoxel Source Fusion (SVSF)** 是 `AutoSV` + `BrushSV` + `LandscapeSV` → `BlendSV` / committed `SceneVoxel` 的正式流程名，本文档中 resolve + commit 合并即为其 GPU 侧实现。
>
> 审计日期: 2026-06-10 (更新)
> 范围: 所有 `.gd` / `.glsl` 代码文件
> 基类 Buffer 工厂: `godot_compute_shader_base.gd`

---

## Buffer 生命周期说明

| Scope | 生命周期 | 释放方式 | 典型用途 |
|-------|----------|----------|----------|
| `SCOPE_FRAME` | 当前帧内 | 基类自动在帧末 `gc_frame()` 回收 | 临时计算输入输出、stats、counter |
| `SCOPE_PERSISTENT` | 跨帧存活 | 手动调用 `release_rid()`，或通过 `dispose()` → `_on_before_dispose()` 释放。`NOTIFICATION_PREDELETE` 自动触发 `dispose()` 作为 GC 安全网 | 常驻数据：tile records、autoobject 运行时状态 |
| `SCOPE_PASS` | 单次 compute pass | uniform set 自身管理 | dispatch 期间的 uniform binding |

---

## 一、PERSISTENT 缓冲区（跨帧常驻）

### 1.1 SceneVoxel Tile 系统 (`scene_voxel_committer.gd`)

| Buffer 名称 | 常量标识 | Stride (bytes) | 容量 | 作用 | 必要性 |
|-------------|----------|----------------|------|------|--------|
| Tile Records | `SCENE_VOXEL_TILE_RECORD_BUFFER` | 128 | `tile_count` | 存储每个 SceneVoxelTile 的元数据（网格坐标、bounds min/max、尺寸）。GPU shader `update_scene_voxel_tile_summary_ranges.glsl` (binding 4) 读取它来确定每个 tile 在体素空间中的覆盖范围，是 CPU-GPU tile 元数据通道 | **必要** — 没有它 GPU 无法定位 tile 的空间范围，摘要和评分均无法工作 |
| Tile Summaries | `SCENE_VOXEL_TILE_SUMMARY_BUFFER` | 32 | `tile_count` | 每个 tile 的聚合统计（scene/collision min/max/count）。GPU shader 将密集 field 归约为摘要写入此 buffer。**GPU-First**: `expand_scene_voxel_tile_routes.glsl` 直接读取 `scene_count`/`collision_count` 字段跳过空 tile，无需 CPU readback；仅在 debug 模式下 `readback_scene_voxel_tile_debug_snapshot()` 才回读 | **必要** — tile 级快速查询索引，GPU-First 管线的空 tile 跳过输入，消除 CPU readback 瓶颈 |
| Dirty Indices | `SCENE_VOXEL_TILE_DIRTY_INDEX_BUFFER` | 4 | `dirty_tile_count` | 脏 tile 索引工作清单。增量更新时只有 bounds 或 field 数据发生变化的 tile 才出现在此列表，GPU 仅处理这些 tile 而不需要全量重算所有 tile 摘要 | **必要** — 增量更新的核心数据结构，避免每帧 O(N) 全量重算 |
| Object Refs | `SCENE_VOXEL_TILE_OBJECT_REF_BUFFER` | 4 | `tile_count × refs_per_tile` | 空间哈希查找表。GPU shader `scene_voxel_tile_object_ref_update.glsl` 通过 atomicCompSwap 将已放置对象的引用键写入对应 tile 区域。评分 shader `score_voxel_tile.glsl` (set 1 binding 12) 读取它来加速同 profile 对象间距检测：不启用 ObjectRef 时为 O(N×M) 全量扫描，启用后降为 O(N×K×S) 局部查找 | **条件必要** — 仅当启用同 profile 最小间距约束 (`scene_voxel_tile_object_ref_exclusion_enabled`) 时使用。若所有对象无间距需求或均为不同 profile，可省略 |
| Complexity Field | `SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER` | 4 | `resident_voxel_count` | 核心密集 3D 场景体素场，每体素存储 0.0-1.0 的场景占用/复杂度。被 3 个 shader 读取：`update_scene_voxel_tile_summary_ranges.glsl` (binding 0) 做摘要归约、`score_voxel_tile.glsl` (set 0 binding 0) 做候选评分、`reduce_scene_voxel_tile_summaries.glsl` 做二次归约 | **核心必要** — 评分系统的核心输入，几乎所有放置决策依赖此数据 |
| Collision Field | `SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER` | 4 | `resident_voxel_count` | 密集 3D 碰撞体素场，每体素存储碰撞/实体占用值。评分 shader 用它计算 solid_collision（实体碰撞惩罚项）和 support 检测（支撑面检测） | **条件必要** — 若所有对象均为纯装饰性放置无碰撞需求，可省略。但当前评分公式中 solid_collision 和 support_ratio 均为核心评分因子，省略会显著改变放置质量 |

**更新策略**:
- 完全上传: `ensure_scene_voxel_tile_buffers_uploaded()` (L2618) → 重建 `SCENE_VOXEL_TILE_GPU_BUFFER_NAMES` 中的全部 6 个 buffer
- 增量更新: `_update_scene_voxel_tile_dirty_ranges()` (L2806) → 仅更新 Summary/Record/DirtyIndex 的脏范围
- Field buffer (Complexity/Collision) 支持复用 (reuse) 而非重建

**生命周期流程**:
```
_init_gpu() → ensure_scene_voxel_tile_buffers_uploaded()
   ↓                                    ↓
SceneVoxel Tile buffers 创建    释放链: dispose() → _on_before_dispose() → _release_scene_voxel_tile_gpu_buffers()
                                 或: NOTIFICATION_PREDELETE → dispose()（GC 安全网）
```

**数据流关系图**:
```
CPU 写入                      GPU Compute                     GPU 读取（评分）
Tile Records ──────────────→ update_summary_ranges.glsl
Dirty Indices ─────────────→       │
Complexity Field ───────────────→       ├─→ tile_summaries (GPU-first: expand_scene_voxel_tile_routes.glsl 直读)
Collision Field ───────────→       │     (CPU 回读仅用于 debug snapshot)
Object Refs ←── scene_voxel_tile_object_ref_update.glsl ←── score_voxel_tile.glsl (spacing)
                                   │                              ↑
                                   └──────────────────────────────┘
                                             (field 采样)
```

---

### 1.2 Committed Payload 缓冲区 (`scene_voxel_committer.gd`)

| Buffer | 变量名 | 创建 | 释放 | 作用 | 必要性 |
|--------|--------|------|------|------|--------|
| Payload Output | `_committed_scene_voxel_payload_buffer` | `_try_resolve_scene_voxel_source_candidates_gpu()` (L6261) | `_release_committed_scene_voxel_payload_buffer()` L4845 | **合并的 resolve+commit 输出**。`resolve_scene_voxel_sources.glsl` 在 per-source-key 级别选出 auto/brush winner 并完成混合，直接输出 committed payload 格式（12 floats per key, SCOPE_PERSISTENT）。CPU 端读回后生成最终 voxel 放置 | **必要** — commit 管线的最终输出 |
| Key Coord | `_committed_scene_voxel_key_coord_buffer` | 同上 | `_release_committed_scene_voxel_key_coord_buffer()` L4855 | 存储每个 commit key 对应的 3D 体素坐标，配套 Payload Output 使用，CPU 端据此将 payload 值写入正确的空间位置 | **条件必要** — 如果 key→coord 映射可在 CPU 端通过 `_scene_voxel_source_key_coord()` 独立计算且无歧义，可省略。但当前 commit 管线依赖 GPU 侧 key index 对齐 |

**生命周期**: 每次 commit 重建，旧 buffer 先释放再分配。保持最新一次 commit 的结果。

**数据流**:
```
Candidate Records/Ranges → resolve_scene_voxel_sources.glsl (resolve + auto/brush blend merged)
                                       ↓
                             Committed Payload Buffer (12 floats per key)
                                       ↓
                             blend_scene_voxel_fields.glsl → Dense Complexity Field
                                       ↓
                             _rebuild_sv() → _sv snapshot (complexity/color/collision)
```

---

### 1.3 Source Candidate Resident 缓冲区 (`scene_voxel_committer.gd`)

| Buffer | 创建 | 释放 | 作用 | 必要性 |
|--------|------|------|------|--------|
| Candidate Records | `_flush_pending_scene_voxel_source_candidates` → storage buffer | `_release_scene_voxel_source_candidate_resident_buffers()` L5814 | 存储待处理 source candidate 的记录数据（priority, complexity, source type）。`resolve_scene_voxel_sources.glsl` (binding 0) 读取这些记录进行 winner 选择 | **必要** — source 解析管线的输入，候选者数据的 GPU 侧表示 |
| Candidate Ranges | 同上 | 同上 | 存储每个 source key 的 auto/brush 候选者范围（uvec4: auto_start, auto_count, brush_start, brush_count）。`resolve_scene_voxel_sources.glsl` (binding 1) 读取合并后的 per-source-key 范围 | **必要** — 与 Candidate Records 配套，定义 per-source-key 的 auto+brush 候选边界 |

---

### 1.4 GPUAutoObjectRuntime 对象状态缓冲区 (`gpu_autoobject_runtime.gd`)

| Buffer | 变量名 | Stride | 容量因子 | 作用 | 必要性 |
|--------|--------|--------|----------|------|--------|
| Alive | `_alive_buffer` | `OBJECT_SCALAR_STRIDE_BYTES` | `max_objects` | 对象存活标志（0/1）。GPU shader 快速跳过已销毁对象，是 O(N×M) 遍历的第一个 early-out 条件。`score_voxel_tile.glsl` (set 1 binding 0) 和 `autoobject_apply_accepted_placements.glsl` 均读取 | **核心必要** — 所有 GPU 对象遍历的入口条件，没有它无法区分活跃/已销毁对象 |
| Generation | `_generation_buffer` | 同上 | `max_objects` | 对象代数/版本号。每次对象创建/更新递增，用于检测对象是否在帧间发生变化（ABBA 问题防护） | **条件必要** — 如果对象 ID 永不复用，可省略。但当前系统使用对象池复用，generation 是避免重名冲突的关键 |
| Type | `_type_buffer` | 同上 | `max_objects` | 对象类型 ID。`score_voxel_tile.glsl` (set 1 binding 2) 读取，决定对象的行为类别（如装饰物 vs 碰撞体） | **条件必要** — 如果所有对象类型相同且行为一致，可省略 |
| Profile | `_profile_buffer` | 同上 | `max_objects` | 对象的 asset profile ID。`score_voxel_tile.glsl` (set 1 binding 3) 用于同 profile 间距检测和 profile table 匹配。`runtime_same_profile_min_spacing_hit` 依赖此字段判断对象是否属于同一 asset | **条件必要** — 仅当启用同 profile 间距约束时使用。若无多 asset 类型管理需求，可省略 |
| Flags | `_flags_buffer` | 同上 | `max_objects` | 对象标记位集合（自动/碰撞/场景/目标等标志位）。用于快速判断对象涉及的子系统，降低不必要的 buffer 读取 | **条件必要** — 如果有独立的 flags 查询需求（如判断对象是否有碰撞），可省略但会降低查询效率 |
| Bounds Min | `_bounds_min_buffer` | `OBJECT_BOUNDS_STRIDE_BYTES` | `max_objects` | 对象 AABB 最小角（xyz + pad）。`score_voxel_tile.glsl` (set 1 binding 4) 用于 `runtime_bounds_overlap_origin` 检测候选放置是否与已有对象重叠 | **核心必要** — 重叠检测的基础数据，几乎所有运行时碰撞/避让逻辑依赖 |
| Bounds Max | `_bounds_max_buffer` | 同上 | `max_objects` | 对象 AABB 最大角。与 Bounds Min 配对使用 | **核心必要** — 同上 |
| Previous Bounds Min | `_previous_bounds_min_buffer` | 同上 | `max_objects` | 上一帧的 AABB 最小角。用于 `scene_voxel_tile_object_ref_update.glsl` 中 object-ref 更新：通过比较新旧 bounds 决定从哪些 tile 中移除对象引用 | **条件必要** — 若不需要增量 object-ref 更新（每帧全量重建 tile ref），可省略。但全量重建的代价远高于保留此 buffer |
| Previous Bounds Max | `_previous_bounds_max_buffer` | 同上 | `max_objects` | 上一帧的 AABB 最大角。与 Previous Bounds Min 配对 | **条件必要** — 同上 |
| Transform | `_transform_buffer` | `OBJECT_TRANSFORM_STRIDE_BYTES` | `max_objects` | 对象完整变换矩阵（位置/旋转/缩放）。CPU 写入，用于渲染和后续 GPU 计算 | **条件必要** — 如果对象变换仅用于渲染（不走 GPU compute），可省略。但当前 object-ref 更新依赖它计算新 bounds |
| Dirty Delta | `_dirty_delta_buffer` | `DIRTY_DELTA_STRIDE_BYTES` | `dirty_delta_capacity` | 对象变化的增量记录（old/new bounds, removed flag, alive status, dirty flags）。`scene_voxel_tile_object_ref_update.glsl` (binding 0) 读取此 buffer 来更新 object-ref 空间哈希表 | **核心必要** — 增量 object-ref 更新的输入，记录帧间对象变化 |
| Dirty Count | `_dirty_count_buffer` | `OBJECT_SCALAR_STRIDE_BYTES` | 1 | 当前帧的脏对象数量计数器。GPU 根据此值确定需要处理的 delta 数量 | **必要** — 控制脏 delta 遍历范围，没有它 GPU 无法知道处理多少个 delta |

**生命周期**: `_ready()` → 分配；`_exit_tree()` → 释放。跨帧常驻，通过 `buffer_update` 增量更新。

**数据流**:
```
CPU 写入 _dirty_delta_buffer ───→ scene_voxel_tile_object_ref_update.glsl
                                       ↓
                              Object Refs (空间哈希更新)
                                       ↓
                              score_voxel_tile.glsl (spacing 检测)
                                       ↑
                  Runtime states (alive/bounds/profile/...) ─┘
```

---

### 1.5 Prefilter Persistent 缓冲区 (`autoobject_probe_prefilter_gpu.gd`)

| Buffer | 变量名 | 创建 | 释放 | 作用 | 必要性 |
|--------|--------|------|------|------|--------|
| GPUPack Record | `_candidate_route_gpu_pack_record_buf` | `_run_candidate_route_gpu_pack_pass()` L498, `SCOPE_PERSISTENT` | `_release_candidate_route_gpu_pack_payload_buffers()` L727 或 `_on_after_dispose()` L1405 | 存储打包后的候选路由记录（`uvec4: tile_id,0,0,0`），输出给 `voxel_placement_generator.gd` 的 resident route 适配链。`score_voxel_tile.glsl` (set 2 binding 0) 读取，决定每个 tile group 可选哪些 asset | **条件必要** — 如果 asset 选择逻辑完全由 CPU 控制（不走 GPU route），可省略 |
| GPUPack Range | `_candidate_route_gpu_pack_range_buf` | `_run_candidate_route_gpu_pack_pass()` L498, `SCOPE_PERSISTENT` | 同上 | 存储每个 asset 的路由范围（record_start, record_count 布局）。与 GPUPack Record 配套，通过 `resident_route_range_rid` 移交给 VPG | **条件必要** — 同上 |

**数据流**: GPUPack Record/Range 由 `_run_candidate_route_gpu_pack_pass()` 创建，payload 通过 `resident_route_record_rid` / `resident_route_range_rid` 传递给 `scene_placement_actor.gd`（由 `track_rid()` 持久化管理），最终供 `voxel_placement_generator.gd` 读取。

---

## 二、FRAME 级缓冲区（帧内临时）

### 2.1 `scene_voxel_committer.gd`

| Buffer | 用途 | 创建位置 | 作用 | 必要性 |
|--------|------|----------|------|--------|
| `auto_buffer` (冷启动) | CPU pack → GPU commit auto source | L5135 `storage_buffer_from_floats` | 当没有 resident resolved source 时的 CPU 回退路径：将 CPU 侧 packed source 数据上传为临时 GPU buffer 供 commit shader 使用 | **条件必要** — 仅在首次 commit 或 resolved source 失效时使用。正常热路径不经过此 buffer |
| `brush_buffer` (冷启动) | CPU pack → GPU commit brush source | L5136 `storage_buffer_from_floats` | 同上，brush 版本 | **条件必要** — 同上 |
| GPU stamp output buffers | 磁盘 stamp 结果 | `_stamp_scalar_image_disc_gpu()` 等 | 将 scalar image 数据 stamp 到 disc（RGBA32F 纹理）的临时输出 | **条件必要** — 仅在需要从标量场生成 disc 纹理时使用 |
| Pixel collect buffers | `collect_disc_pixels.glsl` 输出 | `_collect_disc_pixels_gpu()` | 从 disc 纹理中收集有效像素（密度>阈值），输出为紧凑 pixel 列表 | **条件必要** — 仅在需要从 disc 中提取像素时使用 |
| Sample pixel buffers | `_sample_scalar_image_pixel_gpu()` 输出 | `storage_buffer_zero(4, SCOPE_FRAME)` | 从 R32 格式纹理中采样单个像素值（output_buffer，标签 "sample_r32_pixel_out"） | **条件必要** — 仅在需要从 R32 纹理中读取单个像素时使用 |

### 2.2 `scripts/main.gd`

| Buffer | 用途 | Stride | 创建位置 | 作用 | 必要性 |
|--------|------|--------|----------|------|--------|
| `stats_buf` | Height diff stats | `group_count × 64` | L2127 | 高度差异统计输出（每个 workgroup 的聚合结果），GPU reduce 后 CPU 读回用于调试/可视化 | **条件必要** — 仅在需要 terrain height 差异分析时使用 |
| `minmax_buf` | Grayscale minmax | 特定 | L2900 | 灰度图 min/max 值归约输出 | **条件必要** — 仅在需要灰度图范围分析时使用 |
| `avg_buffer` | Terrain avg sum/count | 8 | L3301 | 地形平均高度计算（sum 和 count 两个 float） | **条件必要** — 仅在需要 terrain 统计时使用 |
| `minmax_buf` (delta) | Delta stats | 8 | L3602 | 高度变化量统计 | **条件必要** — 仅在 delta 分析时使用 |
| `absmax_buf` | Delta heatmap absmax | 特定 | L3718 | Delta 热力图绝对值最大值 | **条件必要** — 仅在热力图分析时使用 |
| `counter_buf` | Clear override tile counter | 4 | L4254 | 清除覆盖 tile 的原子计数器 | **条件必要** — 仅在覆盖清除操作时使用 |
| `counter_buf` | Override invalidation counter | 4 | L4452 | 覆盖失效计数器 | **条件必要** — 仅在覆盖失效操作时使用 |
| `counter_buf` | Mask has pixels counter | 4 | L4561 | Mask 像素存在性计数器 | **条件必要** — 仅在 mask 检测时使用 |
| `counter_buf` | Capture rock mask counter | 4 | L4935 | 岩石 mask 捕获计数器 | **条件必要** — 仅在岩石 mask 捕获时使用 |
| `stats_buf` | Height stats minmax | 12 | L5403 | 高度统计 min/max 输出 | **条件必要** — 仅在高度分析时使用 |

### 2.3 `autoobject_probe_prefilter_gpu.gd`

| Buffer | 用途 | Scope | 作用 | 必要性 |
|--------|------|-------|------|--------|
| `scene_collision_buf` | Scene+Collision merged field upload | FRAME | 将 complexity field 和 collision field 合并为 interleaved vec2 buffer（`.x` = scene, `.y` = collision），单次上传。被 `collect_sv_anchors.glsl` (binding 0) 和 `score_anchor_asset_probes.glsl` (binding 3) 读取 | **必要** — prefilter 管线的核心输入 |
| `target_field_buf` | Target SV requirement field upload | FRAME | 目标体素需求场（每体素 vec4：color RGBA + completely，即 `max(complexity, collision)` 表示体素完全度）。支持借入（borrowed RID）或从 `target_field_bytes` 上传 | **条件必要** — 如果 prefilter 无 target guidance 可省略 |
| `dirty_tile_buf` | Dirty tile worklist | FRAME | 需要处理的脏 tile 工作清单（PackedInt32Array） | **必要** — 增量 prefilter 的调度输入 |
| `anchor_buf` | Anchor collection output | FRAME | prefilter 选出的锚点候选者输出（uvec4: x,y,z,reserved），容量 `ANCHOR_CAPACITY=65536` | **必要** — prefilter 的核心输出 |
| `anchor_count_buf` | Anchor counter | FRAME | 锚点数量原子计数器（单 u32），通过 `buffer_get_data` 读回 | **必要** — GPU 并行输出数量统计 |
| `probe_data_buf` | Probe data upload | FRAME | Asset probe 数据上传（碰撞/颜色/复杂度特征）。支持从 `RuntimeProfileContainer` 借入或从 `probe_pack.probe_bytes` 上传 | **必要** — probe matching 的输入 |
| `probe_range_buf` | Probe range upload | FRAME | Probe 数据范围定义（uvec2: start, count per asset） | **必要** — 与 probe_data 配套 |
| `asset_scores_buf` | Asset score output | FRAME | 每个 (anchor × asset) 对的中间评分输出，Dispatch 2 写入、Dispatch 3 读取。大小: `ANCHOR_CAPACITY × MAX_ASSETS × 4` 字节 | **必要** — asset 选择的中间输出 |
| `topk_buf` | Top-K select output | FRAME | 每个 anchor 的 Top-K 最佳 asset 选择结果（uvec2 per entry），Dispatch 3 写入、Dispatch 4 读取。大小: `ANCHOR_CAPACITY × TOPK × 8` 字节 | **必要** — 最终 asset 选择输出 |
| `voxel_sparse_votes_buf` | Sparse vote output | FRAME | 稀疏体素投票结果（每 (asset × tile) 对一个 float），Dispatch 4 写入。可选读回，也传入 route pack pass | **条件必要** — 如果使用密集投票可省略 |
| `route_radius_buf` | Route profile radii | FRAME | 每个 asset 的路由扩展半径（uvec4: rx,ry,rz,pad），在 `_run_candidate_route_gpu_pack_pass()` 中创建 | **条件必要** — 如果路由不需要半径参数可省略 |
| `route_mark_buf` | Route tile marks | FRAME | 路由扩展期间的 tile 标记 buffer（u32 per candidate tile），在 `_run_candidate_route_gpu_pack_pass()` 中创建 | **条件必要** — 如果路由不需要 tile 标记可省略 |
| `debug_buf` | Debug + stats output | FRAME | 合并后的诊断 buffer（64 bytes = 16 u32）。layout: `[0:3]` = counts (record_count, positive_vote_count, duplicate_tile_id_count, overflow_count), `[4:9]` = debug diagnostics (magic, asset_count, tile_count, record_capacity, written_records, skipped_empty_tiles) | **条件必要** — 调试/统计用途，release 可移除 |

### 2.4 `tools/terrain/*.gd`

| Buffer | 文件 | 用途 | 作用 | 必要性 |
|--------|------|------|------|--------|
| `raw_buf` | `height_image_to_raw_gpu.gd` | RGBA32F raw output | 高度图原始 RGBA32F 数据输出 | **必要** — 地形工具的核心输出 |
| `stats_buf` | `height_image_to_raw_gpu.gd` | Stats u32 | 高度统计输出（min/max height + active pixel count） | **条件必要** — 调试/验证用途 |
| `height_buf` | `height_normal_from_height_gpu.gd` | Height input | 高度图输入数据 | **必要** — 法线计算工具的核心输入 |
| `normal_buf` | `height_normal_from_height_gpu.gd` | Normal output | 法线图 RGBA32F 输出数据 | **必要** — 法线计算工具的核心输出 |
| `stats_buf` | `height_normal_from_height_gpu.gd` | Stats u32 | 法线统计输出（steep count + min/max NZ） | **条件必要** — 调试/验证用途 |
| `height_buf` | `height_to_scene_depth_gpu.gd` | Height input | 高度输入数据（R32F 或 RGBA32F） | **必要** — 场景深度转换的核心输入 |
| `scene_depth_buf` | `height_to_scene_depth_gpu.gd` | Scene depth output | 场景深度 RGBA32F 输出 | **必要** — 场景深度转换的核心输出 |
| `stats_buf` | `height_to_scene_depth_gpu.gd` | Stats u32 | 深度统计（min/max depth + min/max height） | **条件必要** — 调试/验证用途 |
| `mask_buf` | `height_threshold_mask_gpu.gd` | Threshold mask output | 高度阈值掩码 u32 输出 | **必要** — 阈值掩码工具的核心输出 |
| `stats_buf` | `height_threshold_mask_gpu.gd` | Stats u32 | 激活像素计数 + min/max height | **条件必要** — 调试/验证用途 |
| `r_buf/g_buf/b_buf/a_buf` | `terrain_raw_pack_gpu.gd` | Channel inputs | R/G/B/A 单通道 R32F 输入数据 | **必要** — 多通道打包工具的输入 |
| `out_buf` | `terrain_raw_pack_gpu.gd` | Packed output | 打包后的 RGBA32F 输出 | **必要** — 多通道打包工具的核心输出 |
| `stats_buf` | `terrain_raw_pack_gpu.gd` | Stats u32 | R 通道 min/max + active pixel count | **条件必要** — 调试/验证用途 |
| `data_buf` | `invert_height_raw_gpu.gd` | In-place height data | 原地高度反演（输入输出同一 buffer） | **必要** — 高度反演工具的核心缓冲区 |
| `stats_buf` | `invert_height_raw_gpu.gd` | Stats u32 | 峰值键 + active pixels + min/max keys | **条件必要** — 调试/验证用途 |
| `minmax_buf` | `tools/convert_exr_to_png.gd` | Raw depth minmax | 深度图 min/max uint 归约输出（2×u32） | **条件必要** — 仅在 EXR→PNG 转换时需要范围信息 |

### 2.5 `tools/test_*.gd`

| Buffer | 文件 | 用途 | 作用 | 必要性 |
|--------|------|------|------|--------|
| `record_rid` / `range_rid` | `test_voxel_candidate_routing_contract.gd` | 测试路由缓冲区 | 单元测试中验证 candidate routing 的 contract 正确性 | **条件必要** — 仅测试用途 |
| `dirty_delta_buf` 等 5 个 | `test_scene_voxel_tile_object_ref_update.gd` | Object ref update 测试 | 测试 object ref update shader 的正确性 | **条件必要** — 仅测试用途 |
| `resident_color/occupancy` | `test_scene_placement_target_read_buffers_gpu.gd` | 测试读回 | 验证 GPU buffer 读回功能的测试（occupancy 即 completely 值） | **条件必要** — 仅测试用途 |

---

## 三、SCOPE_PASS 缓冲区（单次 compute 绑定）

`SCOPE_PASS` 缓冲区通过 `create_uniform_set()` 的 scope 参数管理，伴随 uniform set 的创建和自动销毁。在所有 `_gpu_dispatch_and_sync` 和 `_gpu_dispatch_pipeline` 调用中均有出现。

> 这些 buffer 是 uniform set 绑定的一部分，生命周期极短（单个 dispatch 期间），无需独立评估必要性。

---

## 四、生命周期总结

| 生命周期类别 | Buffer 数量 | 占内存比例（估计） | 管理复杂度 |
|-------------|------------|-------------------|-----------|
| PERSISTENT（跨帧） | ~25 | >90% | 中（手动 release_rid，有 NOTIFICATION_PREDELETE GC 安全网） |
| FRAME（帧内） | ~20 | <10% | 低（基类自动 gc_frame） |
| PASS（单次） | ~N×4 | 可忽略 | 自动 |

---

## 五、必要性评估汇总

### 核心必要（必须保留）

| Buffer | 所属系统 | 理由 |
|--------|----------|------|
| Tile Records | SceneVoxelTile | GPU 定位 tile 空间范围的唯一通道 |
| Tile Summaries | SceneVoxelTile | tile 级快速查询索引，避免回读完整 field |
| Dirty Indices | SceneVoxelTile | 增量更新的调度核心 |
| Complexity Field | SceneVoxelTile | 评分系统的唯一场景数据输入 |
| Payload Output | CommittedPayload | commit 管线的最终输出 |
| Candidate Records | SourceCandidate | source 解析管线的 GPU 输入 |
| Candidate Ranges | SourceCandidate | source 解析管线的分组定义 |
| Alive | GPUAutoObjectRuntime | 所有 GPU 对象遍历的入口条件 |
| Bounds Min | GPUAutoObjectRuntime | 重叠检测的基础数据 |
| Bounds Max | GPUAutoObjectRuntime | 重叠检测的基础数据 |
| Dirty Delta | GPUAutoObjectRuntime | 增量 object-ref 更新的输入 |
| Dirty Count | GPUAutoObjectRuntime | 脏 delta 遍历范围控制 |

### 条件必要（取决于功能需求）

| Buffer | 激活条件 |
|--------|----------|
| Object Refs | 启用同 profile 最小间距约束 |
| Collision Field | 需要碰撞感知的放置评分 |
| Key Coord | commit key→coord 无法在 CPU 端独立计算 |
| Previous Bounds Min/Max | 需要增量 object-ref 更新 |
| Profile | 启用同 profile 间距约束或多 asset 管理 |
| Generation | 使用对象池复用对象 ID |
| Type / Flags | 有不同类型的对象行为 |
| Transform | 渲染或后续 GPU 计算需要变换数据 |
| GPUPack Record/Ranges | GPU 侧 asset 选择逻辑 |

---

## 六、Buffer 涉及的流程一览

Buffer 并非独立存在，而是嵌入在多个 GPU Compute 管线中作为数据载体。以下按系统梳理每个流程的 Buffer 参与角色。

### 6.1 SceneVoxelTile 摘要更新流程

**目标**: 将 CPU 侧的 tile 元数据和密集体素场归约为每个 tile 的汇总统计，供 CPU 快速判断哪些 tile 有内容需要处理。

```
CPU 写入                              GPU Compute                            CPU 读取
─────────                             ──────────                             ────────
Tile Records    ──────────────────┐
Dirty Indices   ──────────────┐   │
Complexity Field     ──────────┐   │   │
Collision Field ──────┐   │   │   │
                      │   │   │   │
                      ▼   ▼   ▼   ▼
                  update_scene_voxel_tile_summary_ranges.glsl
                                  │
                                  ▼
                          Tile Summaries ──────────────────────────→ 回读 tile 统计
                                  │                                  (场景/碰撞 min/max/count)
                                  ▼
                  reduce_scene_voxel_tile_summaries.glsl
                                  │
                                  ▼
                          二次归约统计 ────────────────────────────→ 全局 min/max
```

| 流程阶段 | 参与 Buffer | 角色 | Binding |
|---------|------------|------|---------|
| 输入 | Tile Records | tile 元数据（网格坐标、bounds、尺寸） | set 0 binding 4 |
| 输入 | Dirty Indices | 脏 tile 工作清单，增量时仅处理变化的 tile | set 0 binding 3（索引表） |
| 输入 | Complexity Field | 密集 3D 场景体素场，归约的源数据 | set 0 binding 0 |
| 输入 | Collision Field | 密集 3D 碰撞体素场，归约的源数据 | set 0 binding 1 |
| 输出 | Tile Summaries | 每个 tile 的聚合统计（min/max/count） | set 0 binding 5 |

**调度方式**: 全量上传 (`ensure_scene_voxel_tile_buffers_uploaded`) 或增量更新 (`_update_scene_voxel_tile_dirty_ranges`)，由 Dirty Indices 是否存在决定。

---

### 6.2 Source 解析 + Commit 合并流程（Resolve + Commit Sources）

**目标**: 在每个 source key 的多个候选者（candidate）中选出 winner（优先级最高或评分最佳），直接完成 auto/brush 混合并输出 committed payload 格式，一次 dispatch 完成 winner 选取 + auto/brush 混合。不再需要中间 resolved auto/brush buffer。

```
CPU 写入                              GPU Compute                            GPU/CPU 后续使用
─────────                             ──────────                             ────────────────
Candidate Records ───────────────┐
Candidate Ranges ────────────────┤
                                 │
                                 ▼
                    resolve_scene_voxel_sources.glsl
                    (resolve + auto/brush blend merged)
                                 │
                                 ▼
                          Committed Payload Buffer
                          (12 floats per key, PERSISTENT)
                                 │
                    ┌────────────┴────────────┐
                    ▼                         ▼
           blend_scene_voxel_fields.glsl    CPU 读回 → 最终 voxel 放置
           → Dense Complexity Field
```

---

### 6.4 Object Ref 增量更新流程

**目标**: 维护空间哈希表 `Object Refs`，跟踪已放置对象在 tile 网格中的位置，加速评分阶段的同 profile 间距检测。

```
CPU 写入                              GPU Compute                            后续使用
─────────                             ──────────                             ────────
Dirty Delta ─────────────────────┐
Dirty Count ─────────────────────┤
Alive ───────────────────────────┤  (验证对象是否存活)
Previous Bounds ─────────────────┤  (旧 bounds 用于移除旧 ref)
Bounds Min/Max ──────────────────┤  (新 bounds 用于添加新 ref)
Transform ───────────────────────┤  (计算变换后 bounds)
Generation ──────────────────────┤  (ABBA 防重名)
                                 │
                                 ▼
                 scene_voxel_tile_object_ref_update.glsl
                                 │
                                 ▼
                           Object Refs（空间哈希更新）
                                 │
                                 ▼
                    score_voxel_tile.glsl（流程 6.5，spacing 检测）
```

| 流程阶段 | 参与 Buffer | 角色 | Binding |
|---------|------------|------|---------|
| 输入 | Dirty Delta | 帧间对象变化记录（old/new bounds, removed, alive, flags） | binding 0 |
| 输入 | Dirty Count | 当前帧脏对象数量，控制遍历范围 | binding 0（push constant 或其他） |
| 输入 | Alive | 对象存活标志，early-out 条件 | set 1 binding 0 |
| 输入 | Previous Bounds Min/Max | 上一帧 AABB，用于从旧 tile 中移除 ref | set 1 binding 8/9 |
| 输入 | Bounds Min/Max | 当前帧 AABB，用于在新 tile 中添加 ref | set 1 binding 4/5 |
| 输入 | Transform | 对象完整变换矩阵 | set 1 binding 10 |
| 输入 | Generation | 对象代数，ABBA 问题防护 | set 1 binding 1 |
| 读写 | Object Refs | 空间哈希表，通过 atomicCompSwap 原子更新 | set 1 binding 12 |

**增量逻辑**: 比较 old/new bounds 覆盖的 tile 集合，从交集中移除旧 ref、向交集中添加新 ref，避免全量重建。

---

### 6.5 评分流程（Score Voxel Tile）

**目标**: 对候选放置位置进行评分，综合考虑场景占用、碰撞检测、对象间距、profile 匹配等因素。

```
GPU Compute（评分 shader）                      输入来源
─────────────────────────                      ────────
                    ┌─── Complexity Field ───────────── 流程 6.1 输出（FLOAT buffer）
                    ├─── Collision Field ────────── 流程 6.1 输出（FLOAT buffer）
                    ├─── Tile Records ───────────── 流程 6.1 PERSISTENT
                    ├─── Tile Summaries ─────────── 流程 6.1 输出
                    ├─── Alive ──────────────────── GPUAutoObjectRuntime
                    ├─── Profile ────────────────── GPUAutoObjectRuntime
                    ├─── Bounds Min/Max ─────────── GPUAutoObjectRuntime
                    ├─── Object Refs ────────────── 流程 6.4 输出
                    ├─── GPUPack Record ──────────── Prefilter PERSISTENT
                    ├─── GPUPack Range ───────────── Prefilter PERSISTENT
                    │
                    ▼
             score_voxel_tile.glsl
                    │
                    ▼
              评分结果输出（供 CPU 选最佳候选）
```

| 流程阶段 | 参与 Buffer | 角色 | 来源 |
|---------|------------|------|------|
| 输入（Set 0） | Complexity Field | 场景占用/复杂度采样 | SceneVoxelTile |
| 输入（Set 0） | Collision Field | 碰撞检测 + support 检测 | SceneVoxelTile |
| 输入（Set 0） | Tile Summaries | tile 级快速过滤 | SceneVoxelTile |
| 输入（Set 1） | Alive | 对象存活 early-out | GPUAutoObjectRuntime |
| 输入（Set 1） | Profile / Type / Flags | 对象分类和间距约束 | GPUAutoObjectRuntime |
| 输入（Set 1） | Bounds Min/Max | 重叠检测 | GPUAutoObjectRuntime |
| 输入（Set 1） | Object Refs | 同 profile 间距加速查找 | 流程 6.4 |
| 输入（Set 2） | GPUPack Record/Ranges | group→profile→asset 映射 | Prefilter |

**评分因子**: scene_complexity, solid_collision, support_ratio, runtime_bounds_overlap, runtime_same_profile_min_spacing 等。

---

### 6.6 Prefilter 流程（Probe Prefilter）

**目标**: 对场景体素场进行预过滤，选出锚点候选者，通过 probe matching 和 asset 评分选出最佳放置。

```
CPU 上传                              GPU Compute                            输出
────────                              ──────────                             ────
Complexity Field ──────────────────────┐
Collision Field ──────────────────┤
Target Completely ─────────────────┤
Target Color ─────────────────────┤  (可选)
Dirty Tile ───────────────────────┤
Probe Data ───────────────────────┤
Probe Range ──────────────────────┤
Route Radius / Mark ──────────────┤  (可选)
                                  │
                                  ▼
                    probe_prefilter → anchor_collection
                                  │
                                  ▼
                          Anchor Output + Anchor Count
                                  │
                                  ▼
                    probe_matching → asset_scores
                                  │
                                  ▼
                    top_k_select → Top-K Output
                                  │
                                  ▼
                    sparse_votes → Sparse Vote Output（可选）
```

| 流程阶段 | 参与 Buffer | 角色 |
|---------|------------|------|
| 输入 | SceneCollision Field (merged vec2) | 场景+碰撞数据输入（单 buffer，`.x`=scene `.y`=collision） |
| 输入 | Target Completely / Color | 目标引导数据（可选，completely = `max(complexity, collision)` 表示体素完全度） |
| 输入 | Dirty Tile | 增量处理工作清单 |
| 输入 | Probe Data / Probe Range | Asset probe 特征数据 |
| 输入 | Route Radius / Route Mark | 路由配置（可选） |
| 中间输出 | Anchor Output + Anchor Count | 锚点候选者 |
| 中间输出 | Asset Scores | 每个 asset 的匹配评分 |
| 最终输出 | Top-K Output | 最佳 asset 选择结果 |
| 辅助 | Debug (merged count+debug) | 统计和调试 |

---

### 6.7 Disc Stamp 流程

**目标**: 将标量场数据转换为 disc 纹理，再从 disc 中收集有效像素。

```
CPU 输入                              GPU Compute                            输出
────────                              ──────────                             ────
Scalar Field ────────────────────┐
                                 │
                                 ▼
                    stamp_scalar_image_disc_gpu
                                 │
                                 ▼
                          Disc Texture（RGBA32F）
                                 │
                                 ▼
                    collect_disc_pixels
                                 │
                                 ▼
                          Pixel Collect Buffer → CPU 读回有效像素列表
```

| 流程阶段 | 参与 Buffer | 角色 |
|---------|------------|------|
| 输入 | Scalar Field（FRAME buffer） | 标量场数据 |
| 中间 | Disc Texture（image2D） | 转换后的 disc 纹理 |
| 输出 | Pixel Collect Buffer（FRAME） | 收集的有效像素 |

---

### 6.8 地形工具流程

**目标**: 高度图 → 原始数据/法线图/场景深度/掩码 的 GPU 加速转换。共 6 个工具文件。

```
输入                                 GPU Compute                            输出
────                                 ──────────                             ────
Height Image ───────────────────┐
                                │
                                ▼
                   height_image_to_raw_gpu
                                │
                                ▼
                          Raw Buffer + Stats
                                │
                    ┌───────────┼───────────┐
                    ▼           ▼           ▼
        height_normal     height_to      height_threshold
        _from_height      _scene_depth   _mask
                    │           │           │
                    ▼           ▼           ▼
          Normal + Stats  SceneDepth+Stats  Mask + Stats
                    │           │
                    │           ▼
                    │     terrain_raw_pack_gpu
                    │     (r_buf/g_buf/b_buf/a_buf → out_buf)
                    │           │
                    ▼           ▼
              invert_height_raw_gpu
              (data_buf 原地反演) + Stats
```

| 流程阶段 | 参与 Buffer | 角色 |
|---------|------------|------|
| 输入 | Height Image（texture） | 高度图纹理 |
| 输出 | Raw Buffer（FRAME） | 原始 RGBA32F 数据 |
| 输入/输出 | Height Buffer → Normal Buffer（FRAME） | 高度 → 法线转换 |
| 输入/输出 | Height Buffer → Scene Depth Buffer（FRAME） | 高度 → 场景深度转换 |
| 输入/输出 | Mask Buffer（FRAME） | 高度阈值掩码 |
| 输入/输出 | R/G/B/A Channel Buffers → Packed Output（FRAME） | 多通道打包 |
| 输入/输出 | Data Buffer（FRAME，in-place） | 高度原地反演 |
| 辅助 | Stats / MinMax（FRAME） | 统计验证 |

---

### 6.9 流程间 Buffer 依赖关系总图

```
                        SceneVoxelTile 系统（PERSISTENT）
                               │
          ┌────────────────────┼────────────────────┐
          ▼                    ▼                    ▼
     Tile Records       Complexity Field          Collision Field
     Dirty Indices      (核心输入)            (核心输入)
     Tile Summaries         │                    │
          │                 │                    │
          └─────────┬───────┴────────┬───────────┘
                    ▼                ▼
            6.1 摘要更新       6.5 评分流程
                    │                │
                    │    ┌───────────┴──────────────┐
                    │    │                          │
                    │    ▼                          ▼
                    │  GPUAutoObjectRuntime      Prefilter
                    │  (Alive/Bounds/Profile/     (Route Records/Ranges)
                    │   Dirty Delta/Transform)         │
                    │    │                          │
                    │    ▼                          ▼
                    │  6.4 Object Ref 更新    6.6 Probe Prefilter
                    │    │                          │
                    │    ▼                          │
                    │  Object Refs ←───────────────┘
                    │    │
                    │    └──────→ 6.5 评分流程（spacing 检测）
                    │
                    ▼
              Source Candidate (Records/Ranges)
                    │
                    ▼
              6.2 Resolve + Commit 合并流程
              (resolve_scene_voxel_sources.glsl)
                    │
                    ├──→ Committed Payload Buffer (12 floats per key)
                    │         │
                    │         ├──→ blend_scene_voxel_fields.glsl → Dense Complexity Field
                    │         └──→ CPU 读回 → _rebuild_sv() → SV snapshot
                    │
                    └──→ Payload Output + Key Coord → CPU 读回 → 最终放置
```

---

