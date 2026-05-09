---
description: 从 Godot 4.x 场景俯视捕获正交深度图。提供可配置长宽和分辨率的 GDScript 工具。 当用户需要生成场景深度图、高度图、正交俯视渲染、terrain capture、depth capture、 或提到"深度图"、"高度图"、"depth map"、"height map"、"orthographic capture"时使用。
---

# Godot 正交深度图捕获工具

## 概述

将 `scripts/depth_capture_tool.gd` 复制到目标项目的 `scripts/` 目录下使用。
该脚本使用 SubViewport + 正交 Camera3D + 深度着色器，从场景正上方渲染深度图。

## 快速使用

### 1. 复制文件到项目

将以下文件复制到目标 Godot 项目：
- [scripts/depth_capture_tool.gd](scripts/depth_capture_tool.gd) → 项目 `scripts/` 目录
- [scripts/depth_capture_shader.gdshader](scripts/depth_capture_shader.gdshader) → 项目 `shaders/` 目录

### 2. 在代码中调用

```gdscript
var capture := DepthCaptureTool.new()
add_child(capture)

# 基本用法：中心 (0,0,0)，30m×30m 范围，256×256 分辨率
var depth_img := await capture.capture_depth(30.0, 30.0, 256)
depth_img.save_png("user://scene_depth.png")

# 指定中心点和最大高度
var depth_img2 := await capture.capture_depth(50.0, 50.0, 512, Vector3(100, 0, 100), 200.0)

# 保存为 RGBAF .raw 格式（兼容 MeshFill 等工具）
capture.save_depth_raw(depth_img2, "user://scene_depth.raw")

capture.queue_free()
```

### 3. 参数说明

`capture_depth(width, height, resolution, center, max_height)`:

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `width` | float | 必填 | 捕获区域宽度（米，X 轴） |
| `height` | float | 必填 | 捕获区域高度（米，Z 轴） |
| `resolution` | int | 256 | 输出纹理分辨率（正方形） |
| `center` | Vector3 | (0,0,0) | 捕获中心世界坐标 |
| `max_height` | float | 100.0 | 最大高度范围（Y 轴） |

### 4. 输出格式

- **Image (FORMAT_RF)**: 单通道浮点高度图，值范围 `[0, max_height]`
  - 0 = 最低点，max_height = 最高点
- **PNG**: 灰度归一化到 0-255
- **RAW**: RGBAF 格式，R 通道存储高度值（兼容 MeshFill）

## 工作原理

1. 创建 SubViewport，设置为指定分辨率
2. 正交 Camera3D 朝下（-Y），size = max(width, height)/2
3. ShaderMaterial 覆盖：将线性深度编码为颜色输出
4. 渲染两帧后读取 viewport 纹理
5. 从颜色解码回深度值，转换为高度

## 注意事项

- 需要在场景树中运行（add_child 后 await）
- 捕获时会临时创建/销毁 SubViewport，不影响主场景
- 大分辨率（>1024）可能需要较长渲染时间
- 不捕获透明物体（深度着色器限制）