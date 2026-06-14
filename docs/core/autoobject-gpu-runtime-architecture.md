# AutoObject GPU Runtime Architecture

本文整理百万级 `AutoObject` 的 GPU-first 运行时契约。`GPUAutoObjectRuntime`、`AutoVoxelRuntimeProfileContainer`、GPU object allocator、per-voxel object refs 和 exclusion 边界共同组成 runtime contract；运行时对象以 GPU-resident SoA buffers 为权威。CPU 只负责 authoring、profile 注册、命令提交、staging、debug readback 和 snapshot，不保留 CPU placement/runtime 替代实现。

**SPA**（`ScenePlacementActor`）是 MeshFill 运行时编排器，拥有 `AutoVoxelRuntimeProfileContainer` 的完整生命周期，借用 `GPUAutoObjectRuntime` 和 `SceneVoxelCommitter` 引用。所有模块通过 SPA 访问 profile container 的 GPU buffers，不直接操作容器实例；详见 [`scene-placement-actor.md`](scene-placement-actor.md)。

本文是 runtime contract / architecture 文档。当前 `scripts/gpu_autoobject_runtime.gd`、`scripts/auto_voxel_runtime_profile_container.gd`、`scripts/auto_object.gd`、`scripts/scene_voxel_committer.gd`、`scripts/autoobject_probe_prefilter_gpu.gd`、`scripts/voxel_placement_generator.gd` 和 `scripts/scene_placement_actor.gd` 提供 GPU-first command/staging/debug 入口；GDScript 字典、snapshot 和 debug range 只用于上传准备或回查，不是验收用的 CPU 替代路径。跨框架总览见 [`meshfill-framework.md`](meshfill-framework.md)；`AssetDescriptor` 定义见 [`auto-voxel-descriptor.md`](auto-voxel-descriptor.md)；SV commit / resident state 见 [`scene-voxel-field-system.md`](scene-voxel-field-system.md)；tile dirty 规则见 [`scenevoxeltile.md`](scenevoxeltile.md)。

![AutoObject GPU runtime architecture](../graphs/autoobject_gpu_runtime_architecture.svg)

## 核心契约

- 当前 GPU-first contract 中，`GPUAutoObjectRuntime` 拥有 runtime object state：`object_id`、`object_type`、transform、`profile_id`、bounds、flags 和 previous/current bounds delta。空间索引由 per-voxel object refs（SV sidecar / GPU resident buffer）承担，不再由 `GPUAutoObjectRuntime` 维护独立的 spatial hash。
- CPU 是 control plane：注册 descriptor/profile、提交 spawn/update/free command、准备 staging payload、保存 snapshot、读取 selected/debug summary；不得为了 debug 长期保留 `BrushSV` / `AutoSV` 的等价内容副本。
- [`AssetDescriptor`](auto-voxel-descriptor.md) 是资产默认语义来源；descriptor 编译为 `AutoVoxelRuntimeProfileContainer` 后，runtime object 只持有 `object_type`、`profile_id` 和实例上下文。descriptor 通过 SPA.register_asset() 注册并即时上传 GPU。
- `object_type` 只用于粗分组、dispatch/exclusion 和 debug；资产差异、probe、collision、pivot 和默认 source 语义由 `profile_id` 指向的 profile 表达。
- `AutoObject` 和 descriptor-backed prototype 只作为 authoring、prototype、import 或 debug 入口；百万级 runtime 不依赖每实例 Godot `Node`。
- `SV` / `SceneVoxelCommitter` 拥有 grid 参数、坐标转换、committed `SceneVoxel`、`SceneVoxelTile` dirty sidecar 和 SV resident `complexity_field` / `collision_field`；GPU AutoObject 只输出 dirty object delta，由 SV owner 映射为 `SceneVoxelTile` dirty 后进入 source range rebuild 和 commit 边界。
- CPU object manager、per-instance Node runtime state、AutoObject direct committed SV write、direct SV resident field upload 和 per-frame full SV flush 都是 deprecated path，不可作为无 RenderingDevice 时的替代通过条件。维护性全量重建必须表达为 mark all `SceneVoxelTile` dirty。

体素与计算术语参见顶层 [`README.md`](../README.md#voxel-and-compute-terminology)。`SPA` 即 `ScenePlacementActor`，详见 [`scene-placement-actor.md`](scene-placement-actor.md)。

## 权威边界

| 数据 | 权威来源 | 当前状态 / 说明 |
| --- | --- | --- |
| 资产默认语义 | `AssetDescriptor` | 编辑器和导入侧源数据；字段定义见 [`auto-voxel-descriptor.md`](auto-voxel-descriptor.md)。不直接进入每实例 GPU record；通过 SPA.register_asset() 注册到 runtime。 |
| Runtime profile | `AutoVoxelRuntimeProfileContainer`（SPA 拥有） | descriptor / profile 去重、`profile_id`、`profile_table`、`probe_records`、`collision_records` 和 `pivot_records` GPU resident storage；`get_gpu_buffer_summary().runtime_ready` 和 valid buffer RID 是通过条件。SPA 创建并管理 container 生命周期，通过 `get_probe_records_buffer()` 等接口暴露 buffer RID。 |
| Runtime object state | `GPUAutoObjectRuntime`（SPA 借用） | 运行时对象池、transform、profile id、bounds、flags 和 dirty object delta；`SceneVoxelCommitter.apply_gpu_autoobject_dirty_delta()` 只是 SV owner 接收 dirty delta 的入口。 |
| Grid / coordinate | `SV` / `SceneVoxelCommitter`（SPA 借用） | `grid_origin`、`voxel_size`、`grid_size`、SV resident fields、tick promotion；GPU runtime 不保存第二套 grid authority。 |
| Dirty tile / commit | `SceneVoxelCommitter` / SV owner | `SceneVoxelTile` dirty flags、source/object range rebuild、SV resident field 发布和 `blend_scene_voxels()` 发布。 |
| Source writes | placement / VPG source write path | Auto / brush source streams 在 commit 时合并到 committed `SceneVoxel`。 |
| Debug / editor lookup | CPU control plane | id 映射、标签、selected readback、profile/source path；不镜像资产默认语义。 |

## Debug Ownership: BrushSV / AutoSV

`BrushSV` 常驻于 SPA 编排生命周期内，并作为 SPA 持久化 / 序列化内容的一部分保存。`AutoSV` 流程输出 debug buffer 作为调试观察面，用于查看运行时生成、source write 和提交结果。

因此，调试能力不再依赖 CPU 侧保留一份 `BrushSV` / `AutoSV` 的完整内容镜像。内容型 source of truth 以 SPA 常驻数据、source write / commit 输出和 GPU debug buffer 为准。

CPU 侧如需保留状态，只能保存控制面元数据：

- 资源句柄或引用。
- 生命周期状态。
- dirty 标记。
- 序列化入口信息。
- 必要的 readback 索引或调试定位键。

这些 CPU 元数据不是 `BrushSV` / `AutoSV` 内容本体的权威来源。

## Current GPU-First Contract Points

| Boundary | Current entry | Input | Output |
| --- | --- | --- | --- |
| Authoring entry | `AutoObject.make_instance_stamp_write_spec()` / legacy `make_voxel_write_spec()` | descriptor-backed fields、placement context、source metadata | `ISWS` / source write record；不是资产默认语义来源。 |
| Probe prefilter | `AutoObjectProbePrefilterGPU.run_probe_prefilter()` | `SV[t - 1]` fields、`TargetSV_B` read buffers、AutoObjects、dirty tile ids | anchors、candidate voxel-region votes、docs-facing `candidate_voxel_regions_by_asset`；legacy `candidate_voxel_sparses_by_asset` 仅兼容/debug。SPA 构建 autoobjects 数组并注入 profile_container 的 borrowed probe_records buffer。 |
| Physical placement | `VoxelPlacementGenerator.run_multi_asset()` | scene/collision fields、asset defs、grid、routed candidate regions、optional runtime/profile GPU buffers | accepted placements、stamp deltas、updated temp scene/collision fields；`write_accepted_placements_to_gpu_runtime=true` 时，VPG 还会把 accepted placements 写入 `GPUAutoObjectRuntime` 并回报 `gpu_autoobject_runtime_writeback`；显式传入 `scene_voxel_committer` + `create_voxel_write_spec=true` 时，同一 accepted placement 会生成 `ISWS` / source record 并回报 `instance_stamp_writeback`。GPU runtime/profile contract enabled 时，VPG 必须完成 contract validation、borrow/bind 对象和 profile buffers，并在 placement pass 中 consumed。SPA 注入 profile_container 和 gpu_runtime 到 placement settings。 |
| Dirty delta handoff | `SceneVoxelCommitter.apply_gpu_autoobject_dirty_delta()` | object id、old/new voxel bounds、dirty flags | affected `SceneVoxelTile` dirty set and debug object refs. |
| Commit | `SceneVoxelCommitter.blend_scene_voxels()` | current auto / brush source streams | committed `SceneVoxel` and `SV[tick]` resident fields. |

## Runtime Model

`object_id` 直接作为 GPU object buffers 的稳定 uint 索引（离线决策确认）。删除对象只清 `alive` 并把 id 放回 free list。`generation` 打包存入 `alive_and_generation_buffer` 的高 24 bit，低 1 bit 为 alive flag，单次 load 同时获取生命周期和 stale handle 检测所需数据。当前不新增 `object_subtype`，更细的资产差异由 `profile_id` / descriptor profile 表达。

```text
object_id              stable uint buffer index（直接索引，无间接层）
generation             packed in alive_and_generation high 24 bits
object_type            coarse routing / exclusion / debug type
profile_id             index into AutoVoxelRuntimeProfileContainer
object_flags           visible, selected, locked, dirty, source, collision flags
```

## Profile Container

`AssetDescriptor` 先归一化为 profile，再注册到 GPU resident profile container：

```text
AssetDescriptor
  -> AutoVoxelRuntimeProfile
  -> AutoVoxelRuntimeProfileContainer
       profile_table_buffer
       probe_buffer
       collision_buffer
       pivot_buffer
       descriptor_hash_to_profile_id
```

每个 runtime object 只保存 `object_type + profile_id + transform + bounds/flags`。百万个对象不重复存储 probes、collision samples、pivot variants 或 descriptor semantic fields。

### 通过 SPA 访问 Profile Container

**Profile container 由 SPA 拥有**，其他模块不直接创建或管理 `AutoVoxelRuntimeProfileContainer` 实例。访问路径：

```text
SPA (ScenePlacementActor)  ← 唯一 owner
  ├── register_asset(descriptor, mesh?)  → 注册到 asset registry + upload_profiles()
  ├── get_probe_records_buffer()         → 返回 profile_container 的 probe_buffer RID
  ├── get_profile_table_buffer()         → 返回 profile_table RID
  ├── get_collision_records_buffer()     → 返回 collision_buffer RID
  ├── get_pivot_records_buffer()         → 返回 pivot_buffer RID
  └── is_gpu_ready()                     → runtime_ready 检查

<消费者通过 SPA 间接访问>
Prefilter.run_probe_prefilter()  ← SPA 传入 profile_container 引用
Placer.run_multi_asset()         ← SPA 在 placement_settings 中注入 profile_container + gpu_runtime
```

Profile container 规则：

- `descriptor_hash_to_profile_id` 是 descriptor/profile 去重入口；`profile_id` 的持久化稳定性由 snapshot / load 流程维护，runtime 不把它当作资产默认语义。
- descriptor / profile 热更新先标记 dirty profile，再把 `AutoVoxelRuntimeProfileContainer.get_dirty_profile_ids()` / `dirty_profile_ids` 交给 `GPUAutoObjectRuntime.mark_profile_objects_dirty()` 反查引用该 `profile_id` 的 object ids，最后由 SV owner 把 affected bounds 转成 `SceneVoxelTile` dirty。
- `object_type` 不反推资产默认语义，也不替代 descriptor/profile；当前不新增 `object_subtype`。
- 当前 `AutoVoxelRuntimeProfileContainer` 负责 descriptor/profile 归一化、去重、profile id、GPU resident storage buffer upload、`get_gpu_buffer_summary()` 和 `readback_debug_snapshot()`；不能用未上传状态或非 resident debug snapshot 当作通过条件。

## Runtime Flow

```text
SPA (ScenePlacementActor) 编排层  [顶层入口]
  → initialize(RD, sv_committer, gpu_runtime)
  → register_asset(descriptor, mesh) × N  [即时 GPU 上传]
  → is_gpu_ready()?  [统一就绪检查]
  → run_placement_pipeline()  [每帧 pipeline]

CPU authoring / import
  -> register descriptors into profile container  [通过 SPA.register_asset()]
  -> enqueue spawn/update/free commands
  -> GPU allocator assigns or reuses object_id
  -> update object buffers
  -> SV owner updates per-voxel + per-tile object refs from bounds
  -> emit dirty object delta with old/new voxel bounds
  -> SV owner maps bounds to affected SceneVoxelTile ids
  -> rebuild dirty tile object/source ranges
  -> route / prefilter / placement / same-type exclusion
     prefilter 和 placer 通过 SPA 注入的 profile_container 访问 borrowed GPU buffers
  -> write AutoSceneVoxel source stream or VPG temp buffers
  -> blend_scene_voxels() publishes committed SceneVoxel and SV[tick] fields
  -> selected-object readback / debug summary when requested
```

## 与 SceneVoxel / Placement 的边界

- GPU AutoObject 是 runtime object pool，不是 committed `SceneVoxel`。
- Placement / scoring 读取 object buffers、profile buffers、SV resident fields 和 TargetSV_B buffers。
- 被接受的对象写入 Auto source stream 或 VPG temp duplicate buffers；最终由 `blend_scene_voxels()` 发布 committed `SceneVoxel`。
- `SV[t - 1].complexity_field` / `SV[t - 1].collision_field` 是本 tick 稳定采样输入；`SV[tick].complexity_field` / `SV[tick].collision_field` 由 commit 后发布并在下一 tick promoted。
- Same-batch temporary write buffers 留在 placement/VPG 内部，不放进 SV 作为正式 working field。

## Runtime IO Contract

| Producer | Input | Output | Consumer |
| --- | --- | --- | --- |
| CPU authoring / import | descriptor path、asset defaults、debug labels | profile registration command、spawn/update/free command | `GPUAutoObjectRuntime` command queue |
| `AutoVoxelRuntimeProfileContainer`（SPA 拥有） | normalized descriptor/profile data | `profile_id`、probe/collision/pivot/profile buffers | object runtime、prefilter、placement shaders（通过 SPA 暴露的 buffer RID 访问） |
| `GPUAutoObjectRuntime`（SPA 借用） | command queue、profile ids、transform updates | object buffers、dirty object delta | SV owner、placement / exclusion shaders |
| `SceneVoxelCommitter` / SV owner（SPA 借用） | dirty object delta、SV grid params | `SceneVoxelTile` dirty set、source/object ranges、committed `SV[tick]` | prefilter、placement、debug query |
| Placement / VPG | routed candidate regions、object/profile buffers、`SV[t - 1]`、`TargetSV_B` | accepted placements、temp duplicate buffers；可选 `gpu_autoobject_runtime_writeback` / `instance_stamp_writeback` | source write path / `blend_scene_voxels()` |

所有以下阶段均已落地实现，运行时严格遵守 GPU-first contract。GDScript sidecar、staging table 和 debug readback 只用于上传准备、状态查询或验证边界，不作为 CPU runtime 实现。


> **禁止 --headless**：本模块的所有 GPU 测试依赖 RenderingDevice，必须在 Vulkan 驱动下运行（--rendering-driver vulkan），使用 --headless 会导致测试无法访问 GPU，CPU fallback 不得作为通过条件。

## 测试场景

| 场景 | 说明 | Godot 场景 |
| --- | --- | --- |
| [GPU Runtime 总览](../../demos/core-autoobject-gpu-runtime-architecture/core-autoobject-gpu-runtime-architecture.md) | 测试方法与验收标准 | [`../../demos/core-autoobject-gpu-runtime-architecture/core-autoobject-gpu-runtime-architecture.tscn`](../../demos/core-autoobject-gpu-runtime-architecture/core-autoobject-gpu-runtime-architecture.tscn) |
| [GPU AutoObject Runtime Plan](../../demos/modules/gpu-autoobject-runtime-plan/gpu-autoobject-runtime-plan.md) | 测试方法与验收标准 | [`../../demos/modules/gpu-autoobject-runtime-plan/gpu-autoobject-runtime-plan.tscn`](../../demos/modules/gpu-autoobject-runtime-plan/gpu-autoobject-runtime-plan.tscn) |
| [SceneVoxelTile Dirty](../../demos/modules/scenevoxel-tile-dirty/scenevoxel-tile-dirty.md) | 测试方法与验收标准 | [`../../demos/modules/scenevoxel-tile-dirty/scenevoxel-tile-dirty.tscn`](../../demos/modules/scenevoxel-tile-dirty/scenevoxel-tile-dirty.tscn) |
