# TargetSV Point Cloud Conversion

源场景：`res://demos/target-sv-point-cloud-conversion-c/target-sv-point-cloud-conversion.tscn`  
源数据：`res://landscape/TargetSV_PT.bgeo.sc`、`res://textures/scene_height_0_1.png`

## 运行方式

> **@tool 编辑器模式，禁止 F6。**
>
> 在 Godot 编辑器中双击打开 `.tscn` 场景文件即可。脚本在编辑器视口中实时运行，Shift+R/T/Y 视图切换在视口内操作。
> F6（Run Current Scene）和 F5（Run Project）被守卫代码禁止。

## 用途

该 demo 验证外部 Houdini 点云到 `TargetSceneVoxel` 的转换路径。转换工具读取点云中的 `Cd`、`complex`、`collision` 和 `P`，把 `P.y` 作为相对地形高度，采样 `scene_height_0_1.png` 生成可视化位置，同时输出 TargetSV 的 `rgba32f` visual buffer 与 `r32f` collision buffer。

Houdini 的 +Z 方向与高度纹理的行顺序相反，因此转换器默认在 Z 轴上翻转点云网格，使体素列与 `scene_height_0_1.png` 对齐（实测相关性 0.95+）。调试时可用 `--no-flip-z` 关闭该翻转。

## 生成

```bash
python -m pip install blosc2 numpy pillow
python tools/convert_target_sv_point_cloud.py
```

输出文件位于 `res://assets/target_sv/`：

| File | Purpose |
| --- | --- |
| `target_sv_point_cloud.json` | TargetSV metadata、源属性映射、点数和 voxel 统计 |
| `target_sv_point_cloud_visual.rgba32f` | `vec4(color.rgb, complexity)` flat buffer |
| `target_sv_point_cloud_collision.r32f` | `collision` flat buffer |
| `target_sv_point_cloud_preview.png` | XZ preview，用于场景中的半透明叠层 |

## 验收标准

- `Cd` 写入 TargetSV `color.rgb`，`complex` 写入 canonical `complexity`，`collision` 写入独立 collision buffer。
- `P.y` 按相对地形高度映射到 vertical slice；地形高度只用于世界位置可视化，不把 TargetSV 写入 committed `SceneVoxel`。
- metadata 保持 `target_guidance_only=true`、`height_buffer_applied=false`、`collision_buffer_applied=false`；即 TargetSV 是 guidance-only 输入，转换阶段不把 source buffers 标记为 applied。

## 测试

```bash
<godot> --headless --path . --script tools/test_target_sv_point_cloud_conversion.gd
```
