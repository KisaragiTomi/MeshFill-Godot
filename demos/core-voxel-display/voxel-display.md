# Voxel Display: 统一体素显示

本文记录 `scripts/voxel_display.gd`（`class_name VoxelDisplay`）的约定。它是项目里所有体素栅格可视化的唯一渲染权威：碰撞预览、occupancy buffer、工程体素盒以及未来任何体素调试，都归约成同一套数据并共享一个调参面，确保外观一致。

## 核心模型

每种体素显示都归约为：一组格子中心点 + 一个立方格尺寸 + 颜色（统一色或逐格色），用单个 `MultiMesh` 批量渲染立方体盒。

| 项 | 规则 |
| --- | --- |
| 渲染单元 | 一个 `BoxMesh`（笔刷体素用四面体 `ArrayMesh`），由 `MultiMesh` 批量实例化，每个体素一个 instance transform。GPU 直写路径（`build_field_gpu` / `build_brush_tetra_gpu`）在渲染线程把实例 transform+color 写进 `MultiMesh` 缓冲，零回读。 |
| 中心点 | `centers: PackedVector3Array`，体素格子中心，局部空间。 |
| 格子尺寸 | `cell_size: Vector3`，每轴体素全尺寸；实际盒体按 `fill` 内缩。 |
| `fill` | 盒体占满整格的比例，默认 `DEFAULT_FILL = 0.9`，`< 1.0` 留缝，使栅格读起来是离散体素而非实心块。 |
| 颜色模式 | 统一色走 `albedo_color`；逐格色走 `MultiMesh.use_colors` + `vertex_color_use_as_albedo`。 |
| 空输入 | `centers` 为空时返回 `null`，调用方需自行判空。 |

## 公开接口

| 方法 | 用途 |
| --- | --- |
| `build(centers, cell_size, color, options)` | 统一颜色渲染，返回 `MultiMeshInstance3D` 或 `null`。 |
| `build_colored(centers, cell_size, colors, options)` | 逐格颜色渲染，`colors.size()` 必须等于 `centers.size()`，否则退回统一色路径。 |
| `build_tetra(centers, cell_size, colors, options)` | 与 `build_colored` 同构，但渲染单元是四面体而非 box，用于区分笔刷体素与普通 box 体素（CPU 直填）。 |
| `build_field_gpu(voxel_count, cell_size, world_aabb, fields, params, options)` | 全 GPU 渲染满网格 box：分配 `MultiMesh`，compute 在渲染线程直写实例缓冲，零回读；空体素写零基坍缩隐藏，AABB 由已知网格尺寸给出。 |
| `build_brush_tetra_gpu(brush_voxels, cell_size, world_aabb, params, options)` | 全 GPU 渲染稀疏笔刷四面体：每个已绘体素一个 instance，compute 在渲染线程直写实例缓冲，零回读；AABB 由已知网格尺寸给出。 |
| `collision_centers(collision, cell_size)` | 把 AutoObject 风格的碰撞条目（cylinder / box）栅格化成规则体素中心点（局部空间）。 |

`options` 字段：

| 键 | 默认 | 含义 |
| --- | --- | --- |
| `name` | `"VoxelDisplay"` | 生成节点名。 |
| `fill` | `0.9` | 盒体占格比例。 |
| `unshaded` | `false` | `true` 用 `SHADING_MODE_UNSHADED`，否则 `SHADING_MODE_PER_PIXEL`。 |

## 碰撞栅格化

`collision_centers()` 读取碰撞条目的 `radius` / `y_min` / `y_max` / `shape`，按固定 `cell_size` 切分三维网格：

- `shape == "box"` / `"cube"`：按 `abs(x) > radius` 或 `abs(z) > radius` 裁剪（方形足迹）。
- 其他（默认 cylinder）：按 XZ 平面到中心距离 `> radius` 裁剪（圆形足迹）。
- Y 方向从 `y_min` 到 `y_max` 按格高切分，`y_max < y_min` 时自动交换。

## 当前消费者

| 调用方 | 用法 |
| --- | --- |
| [`demos/asset-descriptor-demo/asset_descriptor_demo.gd`](../../demos/asset-descriptor-demo/asset_descriptor_demo.gd) | 碰撞展示：`collision_centers()` 生成中心点，`build()` 用统一蓝/橙半透明色渲染。 |
| [`demos/target-sv-point-cloud-conversion-c/target_sv_point_cloud_demo.gd`](../../demos/target-sv-point-cloud-conversion-c/target_sv_point_cloud_demo.gd) | TargetSV occupancy 体素和工程体素盒：`build_field_gpu()` 全 GPU 直写，零回读；两个消费者共享一份满网格场，只在 `view_mode` / 格尺寸 / AABB 上有差异。 |
| [`demos/target-sv-point-cloud-conversion-c/targetsv_brush_overlay_demo.gd`](../../demos/target-sv-point-cloud-conversion-c/targetsv_brush_overlay_demo.gd) | TargetSV 引导场用 `build_colored()` 显示 box；鼠标笔刷体素用 `build_brush_tetra_gpu()` 全 GPU 直写四面体，compute 在渲染线程填实例缓冲，零回读，四面体区分于 box。 |

## 规则

- 所有体素栅格可视化必须经过 `VoxelDisplay`，不要在各 demo 自建 `MultiMesh` / `BoxMesh` / `CylinderMesh` 体素渲染。
- 通过全局 `VoxelDisplay` 类名引用，不要在 demo 里 `preload` 该脚本。
- 体素外观（间距/着色/光照）只在 `VoxelDisplay` 这一处调整，保持所有显示一致。
- 当前消费者传 `"fill": 1.0`（贴合无缝）；若要离散留缝观感，去掉该项走默认 `0.9`。