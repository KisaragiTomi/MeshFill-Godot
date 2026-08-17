# TargetSV Brush Overlay

源契约：[`target-scene-voxel-projection.md`](target-scene-voxel-projection.md)
源数据：`res://assets/target_sv/`（经 `TargetSVLoader` 加载）、`res://assets/target_sv/scene_height_0_1.png`

## 用途

本文描述把 TargetSV 引导场与鼠标手绘笔刷**叠加**显示，用于直观对比两者的空间分布：

- TargetSV 引导场（`target_guidance_only`）通过 `TargetSVLoader` 加载并解码，以 **box 体素** 经 `VoxelDisplay.build_colored` 上屏。
- 鼠标在地形上手绘的笔刷体素以 **四面体** 经 `VoxelDisplay.build_brush_tetra_gpu` 上屏，与 box 引导场在视觉上区分开。

两条数据流相互独立，仅做视觉叠加，不做任何数值混合。

## 数据流

```
鼠标 LMB 拖动 → 屏幕射线交 y=0 平面 → 体素 XZ → 笔刷范围累积体素列表
                                                        ↓ 落笔/松开
        笔刷坐标 + 地形高度上传到主 RenderingDevice（一次）
                                                        ↓ 渲染线程
        compute 直写四面体 MultiMesh 的实例缓冲（transform+color），零回读
```

## GPU 契约

笔刷体素的每实例 transform 与 color 由 compute shader `res://shaders/brush_voxel_instances.glsl` 在 GPU 上生成，写入 `MULTIMESH_TRANSFORM_3D + use_colors` 布局（16 floats/instance）的实例缓冲。`res://scripts/utils/brush_voxel_display_gpu.gd`（`BrushVoxelDisplayGPU`）继承 `VoxelMultiMeshWriterGPU`（`scripts/utils/voxel_multimesh_writer_gpu.gd`）；拿实例缓冲 RID 的 `multimesh_get_buffer_rd_rid()` 调用在**基类** `bind_multimesh()` 里（`voxel_multimesh_writer_gpu.gd:70-71`），不在 `BrushVoxelDisplayGPU` 上。写入在**主 RenderingDevice** 的渲染线程用 compute 直接完成，**无 `submit_and_sync`、无 `buffer_get_data`、无 `multimesh_set_buffer`**。`custom_aabb` 由 `VoxelDisplay`（`scripts/utils/voxel_display.gd:121,126`）按已知网格尺寸设置，避免实例缓冲填充前被视锥剔除。利用 Godot 4.6 已修复的 issue #105100（compute 可直写 MultiMesh 缓冲）。

GPU 路径走 Vulkan RenderingDevice。无主 RenderingDevice 时直写路径只能 SKIP，不改走任何替代路径。

## 验收标准

- TargetSV 引导场以 box 体素显示，笔刷体素以四面体显示，两者节点分离（`SPA/Volumes/TargetSV/TargetSVVoxels` 与 `SPA/Interaction/MeshFillBrush/BrushTetraVoxels`），无数值混合；引导场的加载、解码和显示以 `scripts/utils/target_sv_setup.gd` 为权威，生命周期归场景常驻 SPA。
- 笔刷实例缓冲由 compute（Vulkan 主 RD）在渲染线程**直写** MultiMesh 缓冲，无回读、无 `multimesh_set_buffer`；生成的实例数等于累积的笔刷体素数。
- 无主 RenderingDevice 时直写路径 SKIP，不做 CPU 替代路径。
