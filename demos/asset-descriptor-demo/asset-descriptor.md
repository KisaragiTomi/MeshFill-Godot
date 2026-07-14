# AssetDescriptor

`AssetDescriptor` 是 MeshFill 中描述资产“是什么”的统一 descriptor。它应该能描述所有种类的可放置物体；object、vegetation、scaffold preset 或导入资源只是不同 authoring entry，不应该各自再定义一套资产默认语义。

源码事实以 [`scripts/asset_descriptor.gd`](../../scripts/asset_descriptor.gd) 为准。export 字段逐项含义维护在源码声明旁；本文维护跨文档共享的职责、边界和生命周期，避免在其它 core 文档重复定义 descriptor。

## 核心契约

- `AssetDescriptor` 是资产默认语义的 canonical source：`color`、`complexity`、`collision`、pivot、semantic probes、mesh/import 信息和可选 scatter/visual 配置都从这里进入运行时。
- `AutoVoxelProfile` 只作为 imported preset / fallback source 进入同一归一化路径，不替代 descriptor。
- `AutoObject` 上的同名字段只是 Inspector / config mirror；运行时读取必须走 descriptor-backed getter。
- `instance_stamp_write_spec`（`ISWS`）只描述本轮实例 stamp 的写入上下文，不是资产默认语义容器。
- `AutoVoxelRuntimeProfileContainer` 保存 descriptor 编译后的 GPU resident profile/probe/collision/pivot buffers，不反过来成为 authoring source of truth。
- `object_type` / `object_subtype` 只做 grouping、debug 或 compatibility metadata；更细的资产差异应进入 descriptor 字段或 runtime `profile_id`。

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
| Placement shape | `collision`、`VoxelGeneral.normalize_collision_samples()`、`pivot_variants`、`auto_generate_vertical_pivots`、`get_pivot_variants()` | placement collision 采样、anchor/pivot variants 和 profile collision records。 |
| Semantic probes | `semantic_probe_generator`、`semantic_probe_density`、`context_sensing_radius`、`get_semantic_probes()` | prefilter 对 `anchor x asset` 打分的 descriptor-backed probes。 |
| Asset identity / grouping | `asset_id`、`object_type`、`object_subtype` | asset/debug/profile lookup 和粗分组；不表达新的资产语义层级。 |
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
  -> to_record_fields()
  -> AutoVoxelRuntimeProfileContainer.register_descriptor()
  -> GPU profile/probe/collision/pivot buffers
```

`to_record_fields()` 先通过 `SharedPropertyType.from_descriptor()` 输出 shared fields，再追加 pivot、vertical-pivot 标记、probe density 和已存在的 `semantic_probes`。

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

## 测试方法

### 运行方式

所有测试脚本位于 `tools/` 目录，命名规则为 `test_<主题>.gd`。每个测试是一个 `extends SceneTree` 的独立脚本，入口为 `_init()`。

按是否需要 RenderingDevice 分为两种驱动模式：

- **非 GPU 测试**（不涉及 RenderingDevice、compute shader、storage buffer 或 GPU readback）：

```powershell
godot --headless --path . --script tools/test_semantic_probe_generation.gd
```

- **GPU / Vulkan 测试**（需要 RenderingDevice，禁止 `--headless`）：

```powershell
godot --path . --rendering-driver vulkan --script tools/test_auto_voxel_runtime_profile_container.gd
```

驱动模式由 `tools/test_markdown_contracts.gd` 中的 `DEMO_CPU_ONLY_TEST_SCRIPTS` / `DEMO_GPU_TEST_SCRIPTS` 列表合约强制执行，使用错误驱动模式会被报错。所有测试通过时 `quit(0)`，失败时 `quit(1)`。

### 相关测试文件

| 测试文件 | 覆盖范围 | 驱动模式 |
| --- | --- | --- |
| [`test_auto_voxel_runtime_profile_container.gd`](../../tools/test_auto_voxel_runtime_profile_container.gd) | descriptor 注册、profile 分阶段、GPU 上传/回读、等效 descriptor 去重、dirty profile 标记、profile 容器边界 | GPU (vulkan) |
| [`test_markdown_contracts.gd`](../../tools/test_markdown_contracts.gd) | `SHARED_FIELD_KEYS`、descriptor-backed getter 权威性、`ISWS` record 携带 collision、`apply_to_scene_voxel` 传播、zero-complexity 不擦除 terrain collision、channel 排除、候选 region 别名 | GPU (vulkan) |

### 关键测试场景

以下场景覆盖本文档定义的核心契约，应在新增 descriptor 字段或修改归一化路径后验证：

**1. Shared fields 边界**

- 验证 `SHARED_FIELD_KEYS == ["color", "complexity", "collision"]`
- 验证 `normalize_shared_fields()` 保持 collision、传播 complexity alpha
- 验证 `to_record_fields()` 包含 collision key
- 验证 channel、scatter 字段、transform 等不进入 shared fields

**2. Descriptor backed getter 权威性**

- 用 `AssetDescriptor.new()` 裸构造，手动设置 `color` / `complexity` / `collision`
- 传入 `AutoObject.configure_auto_object()`，验证 getter 返回 descriptor 值而非 Inspector mirror
- 验证 `configure_auto_object()` 保留已有 descriptor 值，不被 config 覆盖

**3. Collision canonical 字段**

- 验证 descriptor `get_collision()` 对非 terrain 类型返回 `[(`
- 验证 `make_instance_stamp_write_spec` record 携带 descriptor collision（含体素坐标）
- 验证 `apply_to_record()` / `apply_to_scene_voxel()` 正确传播 collision
- 验证 zero-complexity plain write 不擦除 terrain collision field
- 验证不存在 `collision_voxels` 等旧别名

**4. Profile fallback 边界**

- 从 `AutoVoxelProfile` 导入 descriptor，验证 fallback 填充 shared fields
- 验证显式 descriptor 字段覆盖 imported profile 值

**5. GPU profile 注册与生命周期**

- 注册 descriptor 到 `AutoVoxelRuntimeProfileContainer`
- 验证等效 descriptor 去重（返回相同 `profile_id`）
- 验证 dirty profile 标记和重新上传
- 验证 profile container 不入侵 GPU object 生命周期
- 缺少 RenderingDevice 时必须跳过（`print("  SKIP: ...") + return true`），绝不 fallback 到 CPU

### 测试结构模式

新增 非 GPU 测试时遵循以下模板：

```gdscript
extends SceneTree

const AssetDescriptor := preload("res://scripts/asset_descriptor.gd")

func _init() -> void:
    var ok := true
    ok = ok and _test_descriptor_shared_fields()
    ok = ok and _test_descriptor_backed_getter()
    # ...

    if ok:
        print("[AssetDescriptorTest( ALL TESTS PASSED")
        quit(0)
    else:
        push_error("[AssetDescriptorTest( SOME TESTS FAILED")
        quit(1)

func _test_descriptor_shared_fields() -> bool:
    print("[AssetDescriptorTest( test_descriptor_shared_fields...")
    var desc := AssetDescriptor.new()
    # setup, act, assert
    if some_condition_fails:
        push_error("  FAIL: reason")
        desc.free()
        return false
    print("  OK: result summary")
    return true
```

GPU 测试额外包含 RenderingDevice 检查和跳过逻辑：

```gdscript
func _has_rendering_device() -> bool:
    if RenderingServer.get_rendering_device():
        return true
    var rd := RenderingServer.create_local_rendering_device()
    if rd:
        rd.free()
        return true
    return false

func _test_profile_upload_or_skip() -> bool:
    if not _has_rendering_device():
        print("  SKIP: no RenderingDevice available")
        return true
    # ... GPU logic ...
```

### 合约测试

项目在两层运行合约验证：

1. **Demo 合约**（`test_core_demo_contracts.gd`）：解析核心知识文档（`_list_core_docs` 清单，位于 `demos/` 各子目录）中的测试场景表格，验证引用的 demo 文档、场景文件和元数据一致性
2. **Markdown/源码合约**（`test_markdown_contracts.gd`）：跨 `docs/`、源码和测试文件进行深度正则/文本合约验证，包括 GPU-first 措辞、共享字段边界、候选区域别名等

新增 descriptor 字段或修改本文契约后，必须同步更新 `test_markdown_contracts.gd` 中对应的合约断言。

## Demo 场景

场景：`res://demos/asset-descriptor-demo/asset-descriptor-demo.tscn`

### 运行方式

> **@tool 编辑器模式，禁止 F6。**
>
> 在 Godot 编辑器中双击打开 `.tscn` 场景文件即可。脚本在编辑器视口中实时运行，探针和体素通道的快捷键均在视口内操作。

### 场景构成

- 4 棵树 + 4 块岩石，从 FBX 加载首个 mesh 并 `duplicate(true)`；加载失败时回退到 `BoxMesh`。
- 飞航相机、三点光照（Sun 暖光 + Fill 冷补光 + Rim 轮廓光）。
- `WorldEnvironment` 开启 SSAO 与 Fog。

### 快捷键

| 键 | 功能 |
| --- | --- |
| `1` | 切换树木探针调试 |
| `2` | 切换岩石探针调试 |
| `3` | 切换全部探针 |
| `C` | 清除所有调试节点 |
| `B` | 切换 Buffer Info 叠加层 |

### 契约测试

descriptor 资产属性契约（descriptor-backed getter 权威性、`ISWS` record 携带 collision、channel 排除）已并入 `tools/test_markdown_contracts.gd`；连同核心 demo 契约必须用 Vulkan 驱动运行，禁止 `--headless`：

```bash
godot --path . --rendering-driver vulkan --script tools/test_core_demo_contracts.gd
godot --path . --rendering-driver vulkan --script tools/test_markdown_contracts.gd
```

### Demo 验收标准

- `AssetDescriptor` 是资产默认语义的唯一主来源；`AutoObject` 同名字段只作 Inspector / 兼容入口。
- `color` / `complexity` / `collision` 为 canonical 共享字段。
- 探针 marker 颜色按 `shape_source` 区分，分层优先级 `convex > voxel_interior > surface > context`。
- 碰撞柱体的半径、高度、中心与 `collision` 定义一致。

## 测试场景

| 场景 | 说明 | Godot 场景 |
| --- | --- | --- |
| [AssetDescriptor 统一 Demo](res://demos/asset-descriptor-demo/asset-descriptor.md) | 本文即该 demo 的测试文档 | [`asset-descriptor-demo.tscn`](res://demos/asset-descriptor-demo/asset-descriptor-demo.tscn) |

## 相关文档

- [`asset-properties.md`](asset-properties.md)（`res://demos/asset-descriptor-demo/asset-properties.md`）：descriptor、shared fields、metadata 和 `ISWS` 的字段归属边界。
- [`auto-asset-scripting.md`](auto-asset-scripting.md)（`res://demos/asset-descriptor-demo/auto-asset-scripting.md`）：脚手架 JSON 如何写入 descriptor / descriptor-backed asset。
- [`asset-semantic-probes.md`](asset-semantic-probes.md)（`res://demos/asset-descriptor-demo/asset-semantic-probes.md`）：descriptor-backed semantic probes。
- [`scene-placement-actor.md`](../core-SPA-scene-placement-actor/scene-placement-actor.md)：descriptor 注册、GPU profile buffer 生命周期和 SPA 访问入口。
- [`autoobject-gpu-runtime-architecture.md`](../core-SPA-scene-placement-actor/autoobject-gpu-runtime-architecture.md)：profile container、GPU object pool 和 runtime contract。
- [`scene-voxel-field-system.md`](../core-scene-voxel-field-system/scene-voxel-field-system.md)：`ISWS`、source write、committed `SceneVoxel` 和 SV resident state。
