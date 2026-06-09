# AutoVoxelDescriptor

`AutoVoxelDescriptor` 是 MeshFill 中描述资产“是什么”的统一 descriptor。它应该能描述所有种类的可放置物体；rock、vegetation、typed asset、scaffold preset 或导入资源只是不同 authoring façade，不应该各自再定义一套资产默认语义。

源码事实以 [`scripts/auto_voxel_descriptor.gd`](../../scripts/auto_voxel_descriptor.gd) 为准。export 字段逐项含义维护在源码声明旁；本文维护跨文档共享的职责、边界和生命周期，避免在其它 core 文档重复定义 descriptor。

## 核心契约

- `AutoVoxelDescriptor` 是资产默认语义的 canonical source：`color`、`complexity`、`collision`、pivot、semantic probes、mesh/import 信息和可选 scatter/visual 配置都从这里进入运行时。
- `AutoVoxelProfile` 只作为 imported preset / fallback source 进入同一归一化路径，不替代 descriptor。
- `AutoObject` 上的同名字段只是 Inspector / config mirror；运行时读取必须走 descriptor-backed getter。
- `instance_stamp_write_spec`（`ISWS`）只描述本轮实例 stamp 的写入上下文，不是资产默认语义容器。
- `AutoVoxelRuntimeProfileContainer` 保存 descriptor 编译后的 GPU resident profile/probe/collision/pivot buffers，不反过来成为 authoring source of truth。
- `object_type` / `object_subtype` 只做 grouping、debug 或 compatibility metadata；更细的资产差异应进入 descriptor 字段或 runtime `profile_id`。

## 责任、输入和输出

| 项 | 当前契约 |
| --- | --- |
| 职责 | 保存所有资产种类的默认体素语义、footprint、anchor、probe、mesh/import 和实例化辅助配置。 |
| 输入 | Inspector resource、脚手架 JSON、typed asset façade、imported `AutoVoxelProfile` fallback、mesh/source mesh。 |
| 输出 | descriptor-backed shared fields、pivot/probe/collision profile、`make_instance_config()` 配置、GPU profile registration payload。 |
| 生命周期 | author/import/scaffold -> descriptor resource -> `AutoObject` getter 或 SPA asset registry -> profile container upload -> prefilter / placement / `ISWS` 构造 -> source write / commit。 |
| Source of truth | descriptor resource 和源码归一化函数；metadata、`ISWS`、runtime profile 和 debug snapshot 都不是第二套资产默认值。 |
| 当前消费者 | `AutoObject`、`AutoAssetFactory`、`ScenePlacementActor`、`AutoVoxelRuntimeProfileContainer`、`AutoObjectProbePrefilterGPU`、`VoxelPlacementGenerator`。 |

## 字段分组

| 组 | 字段 / API | 归属 |
| --- | --- | --- |
| Shared semantic fields | `color`、`complexity`、`collision`、`get_color()`、`get_complexity()`、`get_collision()` | 写入 shared fields、`ISWS`、source voxel 和 committed `SceneVoxel` 的默认语义来源。 |
| Placement shape | `collision`、`normalize_collision()`、`pivot_variants`、`auto_generate_vertical_pivots`、`get_pivot_variants()` | placement footprint、anchor/pivot variants 和 profile collision records。 |
| Semantic probes | `semantic_probe_profile`、`semantic_probe_density`、`context_sensing_radius`、`get_semantic_probes()` | prefilter 对 `anchor x asset` 打分的 descriptor-backed probes。 |
| Asset identity / grouping | `asset_id`、`object_type`、`object_subtype` | asset/debug/profile lookup 和粗分组；不表达新的资产语义层级。 |
| Profile fallback | `voxel_profile`、`from_profile()` | 导入或旧 preset 的 shared-field fallback；不覆盖显式 descriptor 字段。 |
| Mesh / import | `mesh`、`source_mesh`、`source_mesh_path`、`mesh_create_method`、`get_mesh()`、`get_source_mesh()` | 资产显示、probe 生成、导入重建和轻量 wrapper 输入。 |
| Scatter / visual helper | `scatter_min_distance`、`scatter_max_count`、`scatter_max_scale`、`visual_layer`、`group`、`material` | 当前多用于 vegetation façade / 实例化辅助；不进入 committed `SceneVoxel` accepted fields。 |

`SharedPropertyType.SHARED_FIELD_KEYS` 当前只包含 `color`、`complexity` 和 `collision`。`channel`、scatter radius、source type、pixel、slice、transform、runtime object id 等字段属于写入上下文、placement context、debug 或 runtime state，不属于 descriptor 的 shared semantic fields。

## 归一化入口

```text
AutoVoxelDescriptor
  -> get_color() / get_complexity()
  -> get_collision()
  -> get_pivot_variants()
  -> get_semantic_probes()
  -> to_record_fields()
  -> AutoVoxelRuntimeProfileContainer.register_descriptor()
  -> GPU profile/probe/collision/pivot buffers
```

`to_record_fields()` 先通过 `SharedPropertyType.from_descriptor()` 输出 shared fields，再追加 pivot、vertical-pivot 标记、probe density 和已存在的 `semantic_probes`。`get_scatter_profile()` 只输出 scatter helper 需要的颜色 / 强度配置，不把 scatter 字段写入 shared schema。

## 与 AutoObject 的边界

`AutoObject` 是运行时节点、prototype、debug façade 和 legacy API 兼容入口。它可以持有 `voxel_descriptor`，也可以通过 Inspector / config 接收 mirror 字段，但默认语义读取必须收敛到 descriptor-backed getter：

```text
AutoObject config / Inspector mirror
  -> configure_auto_object()
  -> voxel_descriptor
  -> get_voxel_color() / get_voxel_complexity() / get_collision() / get_semantic_probes()
```

不要在 `AutoObject` 上新增与 descriptor 同义的资产默认字段。新增资产语义时，先判断它是否属于 descriptor；只有实例位置、transform、source 分类、pixel/slice、channel 或本轮 stamp 上下文才进入 `ISWS` / runtime record。

## 与运行时 Profile 的边界

SPA 通过 `register_asset(descriptor, mesh?)` 注册 descriptor，并立即上传到 `AutoVoxelRuntimeProfileContainer`。profile container 可以缓存、去重并提供 GPU resident buffers，但它只是运行时编译结果：

```text
AutoVoxelDescriptor resource
  -> normalize / hash
  -> AutoVoxelRuntimeProfileContainer
  -> profile_id + profile_table/probe/collision/pivot buffers
  -> GPUAutoObjectRuntime object stores only profile_id + runtime state
```

`profile_id` 是运行时索引，不是 authoring schema。debug readback、staging Dictionary 或未上传 profile 不能作为 GPU-required path 的通过条件。

## Authoring 规则

- 所有资产种类默认都应能落到 `AutoVoxelDescriptor`，typed façade 只负责更方便地编辑或实例化。
- 新增资产语义字段时，优先加入 descriptor，并同步源码旁注释和本文字段分组。
- 新增 runtime-only 字段时，放入 `ISWS`、placement record、GPU object state、source/debug buffer 或 `SceneVoxel` 专题文档，不要写进 descriptor。
- 新增 profile / metadata / debug 字段时，明确它只做查询、去重、索引或调试，不要写成语义来源。
- `collision` 是 canonical 字段；新 config、descriptor record 和 shared fields 不应重新引入 `collision_voxels` 等别名。

## 相关文档

- [`asset-properties.md`](asset-properties.md)：descriptor、shared fields、metadata 和 `ISWS` 的字段归属边界。
- [`auto-asset-scripting.md`](auto-asset-scripting.md)：脚手架 JSON 如何写入 descriptor / typed façade。
- [`asset-semantic-probes.md`](asset-semantic-probes.md)：descriptor-backed semantic probes。
- [`scene-placement-actor.md`](scene-placement-actor.md)：descriptor 注册、GPU profile buffer 生命周期和 SPA 访问入口。
- [`autoobject-gpu-runtime-architecture.md`](autoobject-gpu-runtime-architecture.md)：profile container、GPU object pool 和 runtime contract。
- [`scene-voxel-field-system.md`](scene-voxel-field-system.md)：`ISWS`、source write、committed `SceneVoxel` 和 SV resident state。
