# TargetSV Brush Overlay

源场景：`res://demos/target-sv-point-cloud-conversion-c/target-sv-point-cloud-conversion.tscn`
源契约：`res://demos/target-sv-point-cloud-conversion-c/target-scene-voxel-projection.md`
源数据：`res://assets/target_sv/`（经 `TargetSVLoader` 加载）、`res://textures/scene_height_0_1.png`

## 运行方式

> **@tool 编辑器模式，禁止 F6。**
>
> 在 Godot 编辑器中双击打开 `.tscn` 场景文件即可。脚本在编辑器视口中实时运行，笔刷绘制、快捷键交互均在视口内完成。
> F6（Run Current Scene）和 F5（Run Project）被守卫代码禁止，运行时会输出 `push_error` 并跳过初始化。

## 用途

该 demo 把 TargetSV 引导场与鼠标手绘笔刷**叠加**显示，用于直观对比两者的空间分布：

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

笔刷体素的每实例 transform 与 color 由 compute shader `res://shaders/brush_voxel_instances.glsl` 在 GPU 上生成，写入 `MULTIMESH_TRANSFORM_3D + use_colors` 布局（16 floats/instance）的实例缓冲。`res://scripts/utils/brush_voxel_display_gpu.gd`（`BrushVoxelDisplayGPU`）在**主 RenderingDevice** 上经 `multimesh_get_buffer_rd_rid()` 拿到真实实例缓冲 RID，在渲染线程用 compute 直接写入，**无 `submit_and_sync`、无 `buffer_get_data`、无 `multimesh_set_buffer`**。MultiMesh 用已知网格尺寸设 `custom_aabb`，避免实例缓冲填充前被视锥剔除。利用 Godot 4.6 已修复的 issue #105100（compute 可直写 MultiMesh 缓冲）。

GPU 路径走 Vulkan RenderingDevice。无主 RenderingDevice 时直写路径只能 SKIP，不改走任何替代路径。

## 交互

- `[LMB 拖动]` 在地形上手绘笔刷体素（四面体）。FlyCamera 用右键拖动看视角，与左键落笔不冲突。
- `[Shift+B]` 切换笔刷体素可见性。
- `[Shift+C]` 清空笔刷体素。
- `[Shift +]` / `[Shift -]` 调整笔刷的 XZ 尺寸。

## 验收标准

- TargetSV 引导场以 box 体素显示，笔刷体素以四面体显示，两者节点分离（`GuidanceVoxels` 与 `BrushTetraVoxels`），无数值混合。
- 笔刷实例缓冲由 compute（Vulkan 主 RD）在渲染线程**直写** MultiMesh 缓冲，无回读、无 `multimesh_set_buffer`；生成的实例数等于累积的笔刷体素数。
- 无主 RenderingDevice 时直写路径 SKIP，不做 CPU 替代路径。

## 测试

```bash
<godot> --path . --rendering-driver vulkan --script tools/test_targetsv_brush_overlay.gd
```

无 RenderingDevice（如 `--headless`）时，GPU 子项按契约 SKIP。