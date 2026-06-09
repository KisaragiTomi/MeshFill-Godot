# Asset Properties

![AutoObject asset properties map](../graphs/autoobject_asset_properties.svg)

![AutoObject and AutoVoxelDescriptor relationship](../graphs/autoobject_descriptor_relationship.svg)

![AutoAssetFactory relationships](../graphs/autoassetfactory_relationships.svg)

本文是资产字段、descriptor 入口、runtime write record 和 metadata 边界的速查。`AutoVoxelDescriptor` 的统一定义见 [`auto-voxel-descriptor.md`](auto-voxel-descriptor.md)；源码已在 export 字段旁维护逐项含义，本页只写跨层契约和归属边界。

## 核心规则

- [`AutoVoxelDescriptor`](auto-voxel-descriptor.md) 是所有资产种类默认体素语义的 canonical source；`AutoVoxelProfile` 只作为已有资产 / 导入 preset fallback 进入同一 shared-field 归一化路径。
- `AutoVoxelDescriptor.collision` 是权威字段；新 config、descriptor record 和 shared fields 只读写 `collision`。
- `SharedPropertyType.SHARED_FIELD_KEYS == ["color", "complexity", "collision"]`。
- `channel` 不进入共享语义；`vegetation_channel` / `vegetation_radius` 只属于植被 scatter profile。
- `AutoObject` 上的同名 mirror 和 metadata 只用于 Inspector、查询和调试；语义读取走 descriptor-backed getters。
- `instance_stamp_write_spec`（`ISWS`）是本轮实例 / stamp 写入 `SV` / `SceneVoxel` 的 payload 和查询 handle，不是资产默认语义容器；当前源码提供 canonical `instance_stamp_write_spec` metadata / wrapper，并保留 `voxel_write_spec` 变量、函数和 metadata key 作为 legacy-named accessors。
- committed `SceneVoxel` 只接受 `complexity` / `color` / `collision`，可选 `auto_mix`；`channel`、`occupied`、`type`、`source_type`、`commit_tick` 和 record id 留在 source/debug buffers、object-ref index 或 debug view。
- `AutoVoxelRuntimeProfileContainer` 是 GPU-first profile 注册 / staging / upload 入口；CPU 只负责 descriptor 归一化、staging 和 debug readback，不能把未上传或非 resident debug snapshot 写成 runtime resident success。

## 范围与生命周期

| 项 | 当前契约 |
| --- | --- |
| 职责 | 说明 asset defaults、descriptor-backed getter、shared fields、`ISWS` 和 metadata 的字段归属。 |
| 输入 | `.tres` / `.tscn` 资产、脚手架 JSON、Inspector config、`AutoVoxelProfile` fallback。 |
| 输出 | descriptor-backed shared fields、runtime `ISWS` record、metadata handle、committed `SceneVoxel` accepted fields。 |
| 生命周期 | author / scaffold -> descriptor 或 typed asset 保存 -> `AutoObject` 读取 descriptor -> 构造 `ISWS` -> source write -> `blend_scene_voxels()` 发布 committed `SceneVoxel`。 |
| Source of truth | 资产默认值在 `AutoVoxelDescriptor`；shared schema 在 `SharedPropertyType`；committed runtime read model 在 `SceneVoxelCommitter`。 |
| Placement 边界 | placement 读取 descriptor-backed asset defs、collision footprint、candidate regions 和 `ISWS`，但不定义资产默认字段，也不把 candidate regions 当作 committed `SceneVoxel`。 |
| Core runtime 边界 | `SceneVoxel` source / commit / resident buffers 由 `scene-voxel-field-system.md` 维护；本文只维护资产字段到 runtime record 的交接。 |
| GPU runtime 边界 | GPU runtime 通过 descriptor-backed getters、profile staging、prefilter packing 和 VPG runtime/profile contract 消费资产语义；profile container 不能替代 descriptor/profile source assets。 |

## 类型边界

| 类型 | 职责 | 文件 |
| --- | --- | --- |
| `AutoVoxelDescriptor` | 所有资产种类的默认语义 descriptor；字段定义见 [`auto-voxel-descriptor.md`](auto-voxel-descriptor.md) | `scripts/auto_voxel_descriptor.gd` |
| `AutoObject` | 运行时节点、实例身份、descriptor 入口、placement helper、legacy-named `voxel_write_spec` / `ISWS` 构造 | `scripts/auto_object.gd` |
| `AutoRock` | 岩石资产和生成原型 | `scripts/auto_rock.gd` |
| Generated vegetation script | typed `AutoObject` façade；由 descriptor / scaffold config 实例化或配置 | `tools/scaffold_auto_asset.gd` / generated script |
| `SharedPropertyType` | `color` / `complexity` / `collision` 的归一化、record 和 `SceneVoxel` 传播 | `scripts/shared_property_type.gd` |
| `AutoAssetFactory` | 脚手架和导入 helper；创建 descriptor / profile / typed asset；通过当前 helper 输出 `ISWS` record | `scripts/auto_asset_factory.gd` |

## Descriptor 字段

Descriptor 字段、归一化入口和 authoring 规则统一维护在 [`auto-voxel-descriptor.md`](auto-voxel-descriptor.md)。本页只保留跨层交接：descriptor 输出 shared fields / profile payload；`AutoObject`、metadata、`ISWS`、runtime profile 和 committed `SceneVoxel` 都不能反向成为资产默认语义来源。

## AutoObject 边界

`AutoObject` 可以接收已有 config 和 Inspector 字段，但运行时语义读取必须通过 descriptor-backed getter。

`AutoObject` export / runtime 字段的逐项含义已迁移到 `scripts/auto_object.gd` 顶部声明；getter 的 descriptor-backed 读取来源保留在对应函数体中。

当前边界：

- `configure_auto_object()` 接收 `color` / `complexity` / `collision`，归一化后同步到 descriptor。
- `get_voxel_color()`、`get_voxel_complexity()`、`get_collision()`、`get_semantic_probes()` 是运行时读取语义的稳定入口。
- `make_instance_stamp_write_spec()` / `set_instance_stamp_write_spec()` / `get_instance_stamp_write_spec()` 是 canonical wrapper；`make_voxel_write_spec()` / `set_voxel_write_spec()` / `get_voxel_write_spec()` 是 legacy API name。它们操作的是同一个 `ISWS` record。
- `source_voxel_type`、`source_kind`、`producer_stage`、`position`、`rotation_degrees`、`scale`、`base_pixel` 和 `channel` 属于 write record 上下文，不是 descriptor 默认语义。

不要在新逻辑中把 `voxel_color`、`voxel_complexity`、metadata 或 `ISWS` 当作 descriptor 的替代来源。

## 共享字段契约

当前共享字段只包含 `color`、`complexity` 和 `collision`；逐项注释维护在 `scripts/shared_property_type.gd` 的 `SHARED_FIELD_KEYS` 声明旁。

`SharedPropertyType.normalize_shared_fields()` 会同步 `color.a == complexity` 并归一化 `collision`。`apply_to_record()` 和 `apply_to_scene_voxel()` 只传播这些共享字段。

| 不共享字段 | 原因 |
| --- | --- |
| `channel` | single-voxel channel tag，不是资产默认语义。 |
| `vegetation_channel` / `vegetation_radius` | descriptor scatter 参数，只用于 `get_scatter_profile()` / 植被散布。 |

## ISWS 与 SceneVoxel 边界

`ISWS` 是实例本轮写入场景体素系统的 stamp payload / record，不是资产默认值表，也不是 profile cache。当前数据流保持为：

```text
AutoVoxelDescriptor / AutoVoxelProfile
  -> SharedPropertyType
  -> ISWS record
  -> source voxel write path
  -> committed SceneVoxel
```

`AutoObject.make_profile_voxel_write_spec()` 会先把 profile / descriptor-backed shared fields 写入 record，再追加实例上下文和 source 分类。`channel` 可作为 rock 或 vegetation placement 的 write context 出现在 record 中，但不因此变成 shared field。prefilter 传入的 candidate regions 只限制 placement 搜索范围；只有 source write 和 `blend_scene_voxels()` 才会发布 committed `SceneVoxel`。

committed `SceneVoxel` 的 accepted fields 是 `complexity`、`color`、`collision`，可选 `auto_mix`。`channel` 只作为 write context / scatter profile 输入，不进入 committed read model；查询缓存、占用状态、source 类型、commit tick 和 record id 属于 SV resident state、source/debug buffers、object-ref index 或 debug view。

## Metadata 规则

Metadata 只保留索引、回查和调试入口。当前 `AutoObject._sync_auto_metadata()` 写入 `auto_id`、`auto_instance_id` / `instance_id` 和 `instance_mesh_id`；`set_voxel_write_spec()` / `set_instance_stamp_write_spec()` 同时通过 canonical metadata key `instance_stamp_write_spec` 和 legacy key `voxel_write_spec` 暴露同一个 `ISWS` handle。

`auto_source`、`object_type`、`object_subtype` 等来源 / 分组字段可以存在于 `ISWS` record 或 debug record 中，但不要新增一套 metadata 语义镜像。新增资产语义字段时优先进入 [`AutoVoxelDescriptor`](auto-voxel-descriptor.md)。

`object_type` 保留为 placement、same-type exclusion、GPU runtime record 和 debug record 的粗粒度类型字段。已有 `object_subtype` 只作为 compatibility / debug metadata；新 schema 不新增 `object_subtype`，更细的资产差异应进入 `AutoVoxelDescriptor` / runtime `profile_id`。

## Runtime Profile Contract

`AutoVoxelRuntimeProfileContainer` 负责把 descriptor/profile 数据归一化为 profile id、probe/collision/pivot ranges 和 staging/debug table。它属于 GPU-first runtime contract 的 profile 入口；GDScript 字典、数组和 debug snapshot 只用于上传准备或回查，不是 CPU 替代路径。

当前 GPU-first profile flow：

```text
AutoVoxelDescriptor
  -> build / normalize
AutoVoxelRuntimeProfile
  -> register / pack
AutoVoxelRuntimeProfileContainer
  -> GPU storage buffer upload / readback debug snapshot
shader / SV 通过 profile_id 采样资产 profile
```

热更新时，`AutoVoxelRuntimeProfileContainer.dirty_profile_ids` 交给 `GPUAutoObjectRuntime.mark_profile_objects_dirty()` 反查 GPU live object refs，并以 dirty delta 交给 `SceneVoxelCommitter.apply_gpu_autoobject_dirty_delta()` 映射为 `SceneVoxelTile` dirty。该路径仍只把 CPU 用作 control / debug plane，不恢复 CPU runtime fallback。

开放问题：

- 常驻策略是加载即注册、场景引用注册，还是按 asset library 预热。
- 无 RenderingDevice 时只能 SKIP GPU upload / placement 验证，不能改走 CPU 替代路径。

## 相关文档

- `auto-voxel-descriptor.md`：`AutoVoxelDescriptor` 的统一定义、字段分组和 authoring 规则。
- `meshfill-framework.md`：框架数据归属和主流程。
- `scene-voxel-field-system.md`：`instance_stamp_write_spec` / `ISWS`、source voxel、committed `SceneVoxel` 和 SV resident collision field。
- `asset-semantic-probes.md`：descriptor-backed semantic probes。
- `auto-asset-scripting.md`：`AutoAssetFactory` 和 `tools/scaffold_auto_asset.gd` 的 JSON 输入。

## 测试场景

| 场景 | 说明 | Godot 场景 |
| --- | --- | --- |
| [资产字段总览](../../demos/core-asset-properties/core-asset-properties.md) | 测试方法与验收标准 | [`../../demos/core-asset-properties/core-asset-properties.tscn`](../../demos/core-asset-properties/core-asset-properties.tscn) |
| [Asset Defaults Descriptor](../../demos/modules/asset-defaults-descriptor/asset-defaults-descriptor.md) | 测试方法与验收标准 | [`../../demos/modules/asset-defaults-descriptor/asset-defaults-descriptor.tscn`](../../demos/modules/asset-defaults-descriptor/asset-defaults-descriptor.tscn) |
| [Auto Asset Scaffolding](../../demos/modules/auto-asset-scaffolding/auto-asset-scaffolding.md) | 测试方法与验收标准 | [`../../demos/modules/auto-asset-scaffolding/auto-asset-scaffolding.tscn`](../../demos/modules/auto-asset-scaffolding/auto-asset-scaffolding.tscn) |
