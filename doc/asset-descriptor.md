# AssetDescriptor

`AssetDescriptor` 是 MeshFill 中描述资产“是什么”的统一 descriptor。它应该能描述所有种类的可放置物体；object、vegetation、scaffold preset 或导入资源只是不同 authoring entry，不应该各自再定义一套资产默认语义。

源码事实以 [`scripts/asset_descriptor.gd`](../scripts/asset_descriptor.gd) 为准。export 字段逐项含义维护在源码声明旁；本文维护跨文档共享的职责、边界和生命周期，避免在其它 core 文档重复定义 descriptor。

## 核心契约

- `AssetDescriptor` 是资产默认语义的 canonical source：`color`、`complexity`、`collision`、pivot、semantic probes、mesh/import 信息和可选 scatter/visual 配置都从这里进入运行时。
- `AutoVoxelProfile` 只作为 imported preset / fallback source 进入同一归一化路径，不替代 descriptor。
- `AutoObject` 上的同名字段只是 Inspector / config mirror；运行时读取必须走 descriptor-backed getter。
- `instance_stamp_write_spec`（`ISWS`）只描述本轮实例 stamp 的写入上下文，不是资产默认语义容器。
- `AutoVoxelRuntimeProfileContainer` 保存 descriptor 编译后的 GPU resident profile/probe/collision/pivot buffers，不反过来成为 authoring source of truth。
- `object_type` 只做 grouping、debug 或 compatibility metadata；更细的资产差异应进入 descriptor 字段或 runtime `profile_id`。`object_subtype` 已不是 descriptor 导出字段，只作为 placement record 的哈希输入残留在 `scripts/scene_placement_runtime.gd`。

## 责任、输入和输出

| 项 | 当前契约 |
| --- | --- |
| 职责 | 保存所有资产种类的默认体素语义、collision 采样、anchor、probe、mesh/import 和实例化辅助配置。 |
| 输入 | Inspector resource、脚手架 JSON、descriptor-backed asset、imported `AutoVoxelProfile` fallback、mesh/source mesh。 |
| 输出 | descriptor-backed shared fields、pivot/probe/collision profile、`make_instance_config()` 配置、GPU profile registration payload。 |
| 生命周期 | author/import/scaffold -> descriptor resource -> `AutoObject` getter 或 SPA asset registry -> profile container upload -> prefilter / placement / `ISWS` 构造 -> source write / commit。 |
| Source of truth | descriptor resource 和源码归一化函数；metadata、`ISWS`、runtime profile 和 debug snapshot 都不是第二套资产默认值。 |
| 当前消费者 | `AutoObject`、`AutoAssetFactory`、`ScenePlacementActor`、`AutoVoxelRuntimeProfileContainer`、`AutoObjectProbePrefilterGPU`、`VoxelPlacementGenerator`。 |

## 字段分组

| 组 | 字段 / API | 归属 |
| --- | --- | --- |
| Shared semantic fields | `color`、`complexity`、`collision`、`get_color()`、`get_complexity()`、`get_collision()` | 写入 shared fields、`ISWS`、source voxel 和 committed `SceneVoxel` 的默认语义来源。 |
| Placement shape | `collision`、`VoxelGeneral.normalize_collision_samples()`、`pivot_variants`、`get_pivot_variants()` | placement collision 采样、anchor/pivot variants 和 profile collision records。 |
| Placement spacing | `spacing_radius_scale` | 逐资产互斥半径乘数。`ScenePlacementActor._build_placement_asset_defs()` 算 `spacing_radius_world = mesh AABB 的 XZ 半长 × 本乘数`，reduce（`shaders/invalidate_anchor_conflicts.glsl`）按 `dist < max(min_distance_voxels, (r_a + r_b) * asset_spacing_factor)` 淘汰。Asset Overview 面板的「exclusion radius ×」写它，同一个值也是那里互斥球的半径。 |
| Semantic probes | `semantic_probe_generator`、`semantic_probe_density`、`context_sensing_radius`、`get_semantic_probes()` | prefilter 对 `anchor x asset` 打分的 descriptor-backed probes。 |
| Asset identity / grouping | `asset_id`、`object_type` | asset/debug/profile lookup 和粗分组；不表达新的资产语义层级。 |
| Profile fallback | `voxel_profile`、`from_profile()` | 导入或旧 preset 的 shared-field fallback；不覆盖显式 descriptor 字段。 |
| Mesh / import | `mesh`、`source_mesh`、`source_mesh_path`、`mesh_create_method`、`get_mesh()`、`get_source_mesh()` | 资产显示、probe 生成、导入重建和轻量 wrapper 输入。 |
| Visual helper | `visual_layer`、`group`、`material` | 实例化辅助；不进入 committed `SceneVoxel` accepted fields。 |

`SharedPropertyType.SHARED_FIELD_KEYS` 当前只包含 `color`、`complexity` 和 `collision`。`channel`、scatter radius、source type、pixel、slice、transform、runtime object id 等字段属于写入上下文、placement context、debug 或 runtime state，不属于 descriptor 的 shared semantic fields。

## 归一化入口

```text
AssetDescriptor
  -> get_color() / get_complexity()
  -> get_collision()
  -> get_pivot_variants()
  -> get_semantic_probes()
  -> AutoVoxelRuntimeProfileContainer.register_descriptor()
  -> GPU profile/probe/collision/pivot buffers
```

（record 化的 `to_record_fields()` 已删除——生产注册直接走 `register_descriptor()`，shared fields 由 `SharedPropertyType.from_descriptor()` 输出。）

## 与 AutoObject 的边界

`AutoObject` 是运行时节点、prototype、debug entry 和 legacy API 兼容入口。它可以持有 `asset_descriptor`，也可以通过 Inspector / config 接收 mirror 字段，但默认语义读取必须收敛到 descriptor-backed getter：

```text
AutoObject config / Inspector mirror
  -> configure_auto_object()
  -> asset_descriptor
  -> get_voxel_color() / get_voxel_complexity() / get_collision() / get_semantic_probes()
```

不要在 `AutoObject` 上新增与 descriptor 同义的资产默认字段。新增资产语义时，先判断它是否属于 descriptor；只有实例位置、transform、source 分类、pixel/slice、channel 或本轮 stamp 上下文才进入 `ISWS` / runtime record。

## 与运行时 Profile 的边界

SPA 通过 `register_asset(descriptor, mesh?)` 注册 descriptor，并立即上传到 `AutoVoxelRuntimeProfileContainer`。profile container 可以缓存、去重并提供 GPU resident buffers，但它只是运行时编译结果：

```text
AssetDescriptor resource
  -> normalize / hash
  -> AutoVoxelRuntimeProfileContainer
  -> profile_id + profile_table/probe/collision/pivot buffers
  -> GPUAutoObjectRuntime object stores only profile_id + runtime state
```

`profile_id` 是运行时索引，不是 authoring schema。debug readback、staging Dictionary 或未上传 profile 不能作为 GPU-required path 的通过条件。

## Authoring 规则

- 所有资产种类默认都应能落到 `AssetDescriptor`，descriptor-backed authoring entry 只负责更方便地编辑或实例化。
- 新增资产语义字段时，优先加入 descriptor，并同步源码旁注释和本文字段分组。
- 新增 runtime-only 字段时，放入 `ISWS`、placement record、GPU object state、source/debug buffer 或 `SceneVoxel` 专题文档，不要写进 descriptor。
- 新增 profile / metadata / debug 字段时，明确它只做查询、去重、索引或调试，不要写成语义来源。
- `collision` 是 canonical 字段；新 config、descriptor record 和 shared fields 不应重新引入 `collision_voxels` 等别名。

## Demo 场景

场景：[`asset-overview.tscn`](../scenes/asset-overview/asset-overview.tscn)（`res://scenes/asset-overview/asset-overview.tscn`），脚本
[`asset_overview.gd`](../scenes/asset-overview/asset_overview.gd) 以 `@tool` 在编辑器视口内运行。

### 场景构成

- `Assets/Geo` 下 5 个资产节点（`Geo_SM_Ground_Grass`、`Geo_SM_TestLeaf_Test2`、`Geo_cliff_01`、
  `Geo_cliff_02`、`Geo_stone_01`），每个节点各挂一个 `Mesh` (`MeshInstance3D`)，并用
  `metadata/geo_source_path` 等 metadata 记录 FBX 来源与包围盒。
- `GeoTools` (`CanvasLayer`)：`ScanUpdatedGeo` / `FullRescanGeo` 两个扫描按钮。
- 场景**不含**相机、灯光或 `WorldEnvironment`——取景与照明由编辑器视口提供。

### 快捷键

快捷键映射以 `asset_overview.gd` 的 `_editor_viewport_input()` match 分支为准（数字键会先把
`KEY_KP_0..KP_9` 折回 `KEY_0..KEY_9`）：

| 键 | `EDITOR_ACTION_*` | 功能 |
| --- | --- | --- |
| `1` | `probes` | 切换 semantic probe 标记 |
| `2` | `voxel_color` | 切换体素 color 通道显示 |
| `3` | `voxel_complexity` | 切换体素 complexity 通道显示 |
| `4` | `voxel_collision` | 切换体素 collision 通道显示 |
| `5` | `pivots` | 切换 pivot 标记 |
| `G` | `toggle_assets` | 显示 / 隐藏资产节点 |
| `C` | `clear_debug` | 清除所有调试节点 |

### 验收标准

- `AssetDescriptor` 是资产默认语义的唯一主来源；`AutoObject` 同名字段只作 Inspector / 兼容入口。
- `color` / `complexity` / `collision` 为 canonical 共享字段。
- 探针 marker 颜色按 `shape_source` 区分，分层优先级 `convex > voxel_interior > surface > context`。
- 碰撞采样的半径、高度、中心与 descriptor `get_collision()` 的定义一致。

## 相关文档

- [`asset-properties.md`](asset-properties.md)（`res://doc/asset-properties.md`）：descriptor、shared fields、metadata 和 `ISWS` 的字段归属边界。
- [`auto-asset-scripting.md`](auto-asset-scripting.md)（`res://doc/auto-asset-scripting.md`）：脚手架 JSON 如何写入 descriptor / descriptor-backed asset。
- [`asset-semantic-probes.md`](asset-semantic-probes.md)（`res://doc/asset-semantic-probes.md`）：descriptor-backed semantic probes。
- [`scene-placement-actor.md`](scene-placement-actor.md)：descriptor 注册、GPU profile buffer 生命周期和 SPA 访问入口。
- [`auto-object-gpu-runtime-architecture.md`](auto-object-gpu-runtime-architecture.md)：profile container、GPU object pool 和 runtime contract。
- [`scene-voxel-field-system.md`](scene-voxel-field-system.md)：`ISWS`、source write、committed `SceneVoxel` 和 SV resident state。
