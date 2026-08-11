# TargetSV Point Cloud Conversion

源数据：`res://landscape/TargetSV_PT.bgeo.sc`、`res://textures/scene_height_0_1.png`

## 用途

本文记录外部 Houdini 点云到 `TargetSceneVoxel` 的转换路径。转换工具读取点云中的 `Cd`、`complex`、`collision` 和 `P`，把 `P.y` 作为相对地形高度，采样 `scene_height_0_1.png` 生成可视化位置，同时输出 TargetSV 的 `rgba8` visual buffer 与 `r8` collision buffer。

Houdini 的 +Z 方向与高度纹理的行顺序相反，因此转换器在 Z 轴上翻转点云网格，使体素列与 `scene_height_0_1.png` 对齐（实测相关性 0.95+）。（转换脚本本身当前不在仓库内，本节只记录产物契约。）

## 产物

转换产物位于 `res://assets/target_sv/`：

| File | Purpose |
| --- | --- |
| `target_sv_point_cloud.json` | TargetSV metadata、源属性映射、点数和 voxel 统计 |
| `target_sv_point_cloud_visual.rgba8` | `rgba8(color.rgb, complexity)` flat buffer |
| `target_sv_point_cloud_collision.r8` | `collision` r8 flat buffer |
| `target_sv_point_cloud_preview.png` | XZ preview，用于场景中的半透明叠层 |

## 验收标准

- `Cd` 写入 TargetSV `color.rgb`，`complex` 写入 canonical `complexity`，`collision` 写入独立 collision buffer。
- `P.y` 按相对地形高度映射到 vertical slice；地形高度只用于世界位置可视化，不把 TargetSV 写入 committed `SceneVoxel`。
- metadata 保持 `target_guidance_only=true`、`height_buffer_applied=false`、`collision_buffer_applied=false`；即 TargetSV 是 guidance-only 输入，转换阶段不把 source buffers 标记为 applied。
