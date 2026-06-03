# VegetationScatter 源码导览

本文按源码职责展示 [`scripts/vegetation_scatter.gd`](../../scripts/vegetation_scatter.gd) 的主要内容。它不是新的植被运行时架构文档；植被资产脚手架见 [`auto-asset-scripting.md`](auto-asset-scripting.md)，`SceneVoxel` 写入边界见 [`scene-voxel-field-system.md`](scene-voxel-field-system.md)。

`VegetationScatter` 是一个 `RefCounted` 静态 helper，当前复用已有自动资产脚手架语义，主要维护两类能力：内置植被 mesh 工厂，以及从 RGBAH occupancy 生成植被 mask / count 的 GPU readback helper。

## 本文范围

- 快速定位 `vegetation_scatter.gd` 中的代码块。
- 展示内置植被 mesh 工厂、visual layer 常量和当前调用边界。
- 展示 GPU mask / count helper 的输入、输出、失败返回和 shader 对应关系。
- 标明当前 GPU-first 边界：这些 helper 返回 `Image` / count，适合工具、验证和 debug readback；高频运行时循环应改为输出 reusable buffer RID 或并入主 pipeline。

## 源码地图

| 范围 | 内容 |
| --- | --- |
| `1-21` | `VegetationScatter` 类声明、compute shader 路径、`32x32` local size 和植被 visual layer 常量。 |
| `24-119` | `create_tree_mesh()`、`create_midstory_mesh()`、`create_bush_mesh()`、`create_flower_mesh()` 内置 mesh 工厂。 |
| `122-208` | `_add_cylinder()`、`_add_cone()`、`_add_sphere()`、`_add_petal()` 私有 SurfaceTool primitive builder。 |
| `211-535` | 单通道 occupancy mask、mask pixel count、单通道 mask + count 双 pass helper。 |
| `538-862` | 四通道 count、RGBAH all-channel mask、all-channel mask + count 双 pass helper。 |
| `865-1109` | 拆分 RGBA 四个 R32F mask，以及拆分 mask + 四通道 count 的单 dispatch helper。 |
| `1112-1120` | `_decode_u32()` 小端 `u32` readback decode。 |

## 语义边界

- 本文档归类为 `reuse`：它展示已有 `VegetationScatter` 职责，不引入新的模块、concept 或 source of truth。
- `mesh_create_method` 只是在 descriptor / scaffold 中选择内置 mesh 的小白名单，不是植被语义权威；默认语义仍由 `AutoVoxelDescriptor` / descriptor-backed 字段维护。
- GPU helper 缺少 `RenderingDevice`、shader、pipeline、texture 或 buffer 时必须返回失败值；不要补 CPU fallback 后把 GPU path 报告为通过。
- 返回的 `Image`、`PackedInt32Array` 和计数是 readback 结果，适合测试、调试和工具链。正常 runtime 需要百万级循环时，不应依赖这些 CPU readback 作为主数据流。

## Mesh 工厂

| API | 输出 | 当前用途 |
| --- | --- | --- |
| `create_tree_mesh()` | trunk cylinder + 两层 cone crown，绿色 vertex-color material。 | `AutoVoxelDescriptor.get_mesh()` 的 `mesh_create_method`，以及 `main.gd` tree mesh cache。 |
| `create_midstory_mesh()` | 较矮 trunk + 单层 cone crown。 | `mesh_create_method` 白名单。 |
| `create_bush_mesh()` | 多个椭球灌木团块。 | `mesh_create_method` 白名单，测试和 placement record commit 场景。 |
| `create_flower_mesh()` | 细 stem、小 bloom 和 6 个 petal。 | `mesh_create_method` 白名单和脚手架示例。 |

Visual layer 常量只描述可视层，不描述 occupancy channel：

| 常量 | 值 | 用途 |
| --- | --- | --- |
| `TREE_VISUAL_LAYER` | `11` | tree instance visual layer。 |
| `BUSH_VISUAL_LAYER` | `12` | bush instance visual layer。 |
| `MIDSTORY_VISUAL_LAYER` | `13` | midstory instance visual layer。 |
| `GRASS_VISUAL_LAYER` | `14` | grass / flower instance visual layer。 |

当前 `main.gd` 的 mask 同步调用把 occupancy channel 映射为 `grass=0`、`bush=1`、`midstory=2`、`tree=3`。这是 caller 侧约定，不是 `VegetationScatter` 内部常量。

## GPU 输入输出契约

GPU mask helper 都读取 `Image.FORMAT_RGBAH` occupancy，并上传为 `R16G16B16A16_SFLOAT`。`output_size == Vector2i.ZERO` 时使用输入尺寸；输出尺寸大于输入时，shader 会让源范围外像素保持空值。

```gdscript
var mask := VegetationScatter.make_vegetation_channel_mask_from_occupancy_gpu(
	occupancy,             # Image.FORMAT_RGBAH
	2,                     # RGBA channel index
	0.01,                  # active threshold
	Vector2i(12, 10)       # output size, or Vector2i.ZERO for source size
)
```

| API | 输出 | 失败返回 |
| --- | --- | --- |
| `make_vegetation_channel_mask_from_occupancy_gpu()` | `Image.FORMAT_RF`，选中 channel 的 R32F mask。 | `null` |
| `count_mask_pixels_gpu()` | `int`，R32F mask 中高于 threshold 的像素数。 | `-1` |
| `make_vegetation_channel_mask_with_count_gpu()` | `{ "mask": Image, "active_count": int }` | `{}` |
| `count_vegetation_channels_gpu()` | `PackedInt32Array([r, g, b, a])` | empty `PackedInt32Array` |
| `make_vegetation_all_channel_mask_gpu()` | `Image.FORMAT_RGBAH`，threshold 后的四通道 mask。 | `null` |
| `make_vegetation_all_channel_mask_with_counts_gpu()` | `{ "mask": Image, "channel_counts": PackedInt32Array }` | `{}` |
| `make_vegetation_split_channel_masks_gpu()` | `Array[Image]`，RGBA 顺序的 4 张 `Image.FORMAT_RF` mask。 | `[]` |
| `make_vegetation_split_channel_masks_with_counts_gpu()` | `{ "masks": Array[Image], "channel_counts": PackedInt32Array }` | `{}` |

## Shader Passes

| Shader | API | 输出 |
| --- | --- | --- |
| `vegetation_channel_mask.glsl` | `make_vegetation_channel_mask_from_occupancy_gpu()`、`make_vegetation_channel_mask_with_count_gpu()` | 单张 R32F selected-channel mask。 |
| `mask_has_pixels.glsl` | `count_mask_pixels_gpu()`、双 pass count 阶段 | `u32` active pixel count。 |
| `vegetation_channel_counts.glsl` | `count_vegetation_channels_gpu()`、all-channel count 阶段 | `u32x4` RGBA active counts。 |
| `vegetation_all_channel_mask.glsl` | `make_vegetation_all_channel_mask_gpu()`、all-channel combined path | 一张 thresholded RGBAH mask。 |
| `vegetation_split_channel_masks.glsl` | `make_vegetation_split_channel_masks_gpu()` | 四张 R32F mask，RGBA 顺序。 |
| `vegetation_split_channel_masks_with_counts.glsl` | `make_vegetation_split_channel_masks_with_counts_gpu()` | 四张 R32F mask + `u32x4` active counts。 |

所有 dispatch 通过 `ComputeShaderBaseScript.dispatch_groups_2d()` 计算 workgroup，local size 当前均为 `32x32`。

## Compute Flow

```text
make_vegetation_channel_mask_with_count_gpu()
  -> upload RGBAH occupancy
  -> create R32F mask texture + u32 counter buffer
  -> dispatch vegetation_channel_mask.glsl
  -> barrier
  -> dispatch mask_has_pixels.glsl
  -> read back Image.FORMAT_RF + active_count
```

```text
make_vegetation_split_channel_masks_with_counts_gpu()
  -> upload RGBAH occupancy
  -> create four R32F output textures + u32x4 counter buffer
  -> dispatch vegetation_split_channel_masks_with_counts.glsl
  -> read back four Image.FORMAT_RF masks + channel_counts
```

## 维护规则

- 新增内置 `mesh_create_method` 时，同时检查 `scripts/auto_asset_factory.gd`、`scripts/auto_voxel_descriptor.gd`、`tools/test_auto_asset_scripting.gd` 和 [`auto-asset-scripting.md`](auto-asset-scripting.md)。
- 修改 GPU helper 的返回契约时，同步更新 `tools/test_vegetation_scatter_channel_mask_gpu.gd`。
- 修改 shader texture format、push constant layout 或 output size 规则时，同步检查对应 `.glsl` 和 readback `Image.create_from_data()` format。
- GPU-required path 缺少 `RenderingDevice` 时必须 skip 或 fail 明确，不要新增 CPU fallback 后报告 GPU path passing。

## Validation Entry Points

Use the Vulkan rendering driver for tests that touch `RenderingDevice`, compute shaders, storage buffers or GPU readback.

```powershell
godot --path . --rendering-driver vulkan --script tools/test_vegetation_scatter_channel_mask_gpu.gd
```

## 相关文档

- [`auto-asset-scripting.md`](auto-asset-scripting.md)：`mesh_create_method` 白名单、植被 descriptor 和脚手架输入。
- [`asset-properties.md`](asset-properties.md)：descriptor-backed fields、metadata 和 `ISWS` 边界。
- [`scene-voxel-field-system.md`](scene-voxel-field-system.md)：occupancy / source voxel / committed `SceneVoxel` 数据流。
- [`../placement/voxel-semantic-routing.md`](../placement/voxel-semantic-routing.md)：prefilter、routing 和 placement 的 candidate voxel-region 消费边界。
