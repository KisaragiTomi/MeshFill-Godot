---
description: 为 Godot 4.x 项目提供默认飞行相机和三点光照系统。当用户创建新的 Godot 3D 场景、 需要可移动相机、调试场景光照、或提到"相机"、"光照"、"camera"、"lighting"、 "fly camera"、"场景浏览"时使用。
---

# Godot 默认相机 & 光照系统

## Agent 工作流

1. 从 `$GODOT_SOURCE/misc/shared_scripts/fly_camera.gd` 复制到项目 `scripts/fly_camera.gd`，挂到 Camera3D
2. 在项目 `scripts/` 创建 `default_lighting.gd`（参考下方代码），挂到 Node3D 节点
3. 在 `.tscn` 中配置节点引用

> **fly_camera.gd 规范源**位于 `$GODOT_SOURCE/misc/shared_scripts/fly_camera.gd`，
> 详细用法和参数见 `godot-project-setup` 技能。修改应在源码中进行，项目通过复制引用。

---

## 飞行相机 — fly_camera.gd（速查）

挂到 Camera3D 节点。完整代码见 `$GODOT_SOURCE/misc/shared_scripts/fly_camera.gd`。

| 输入 | 动作 |
|------|------|
| 右键按住 + 鼠标 | 旋转视角 |
| WASD | 前后左右移动 |
| E / 空格 | 上升 |
| Q | 下降 |
| Shift | 加速 (move_speed × 2.5) |
| 滚轮上 | 增加移动速度 |
| 滚轮下 | 减少移动速度 |

| @export 参数 | 默认值 | 说明 |
|--------------|--------|------|
| `move_speed` | 15.0 | 普通移动速度（滚轮动态调整） |
| `fast_move_speed` | 40.0 | Shift 加速速度（自动 = move_speed × 2.5） |
| `mouse_sensitivity` | 0.003 | 鼠标灵敏度 |
| `speed_scroll_step` | 5.0 | 滚轮每档速度变化量 |
| `min_speed` | 1.0 | 最小移动速度 |
| `max_speed` | 200.0 | 最大移动速度 |

---

## 三点光照 — default_lighting.gd

挂到 Node3D 节点，自动在 `_ready()` 创建 SunLight + FillLight + WorldEnvironment。
也可通过 `DefaultLighting.create_default(parent)` 在代码中动态创建。

### 光照参数速查

| 参数 | 主光源 (Sun) | 补光 (Fill) | 说明 |
|------|-------------|-------------|------|
| 色温 | 暖色 (1, 0.95, 0.85) | 冷色 (0.6, 0.7, 0.9) | 模拟日光 + 天空漫反射 |
| 能量 | 1.2 – 1.6 | 0.3 – 0.5 | 约 3:1 主补比 |
| 阴影 | 开启 | 关闭 | 单阴影源避免交叉阴影 |
| 环境光 | — | — | 0.4 – 0.7 填充暗部 |

### 完整代码

```gdscript
class_name DefaultLighting
extends Node3D

@export_group("Sun (Key Light)")
@export var sun_color: Color = Color(1.0, 0.95, 0.85)
@export var sun_energy: float = 1.4
@export var sun_rotation_deg: Vector3 = Vector3(-30.0, -30.0, 0.0)
@export var sun_shadow: bool = true
@export var sun_shadow_bias: float = 0.03
@export var sun_shadow_distance: float = 200.0

@export_group("Fill Light")
@export var fill_color: Color = Color(0.6, 0.7, 0.9)
@export var fill_energy: float = 0.4
@export var fill_rotation_deg: Vector3 = Vector3(-30.0, 150.0, 0.0)

@export_group("Environment")
@export var bg_color: Color = Color(0.45, 0.55, 0.72)
@export var ambient_color: Color = Color(0.7, 0.75, 0.85)
@export var ambient_energy: float = 0.6
@export var use_ssao: bool = true
@export var use_ssil: bool = true
@export var fog_enabled: bool = true
@export var fog_density: float = 0.002

var sun_light: DirectionalLight3D
var fill_light: DirectionalLight3D
var world_env: WorldEnvironment


func _ready() -> void:
	setup(self)


func setup(parent: Node) -> void:
	_create_environment(parent)
	_create_sun(parent)
	_create_fill(parent)


func _create_environment(parent: Node) -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = bg_color
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = ambient_color
	env.ambient_light_energy = ambient_energy
	env.tonemap_mode = Environment.TONE_MAP_ACES
	env.ssao_enabled = use_ssao
	env.ssil_enabled = use_ssil
	env.fog_enabled = fog_enabled
	if fog_enabled:
		env.fog_light_color = ambient_color
		env.fog_density = fog_density

	world_env = WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	world_env.environment = env
	parent.add_child(world_env)


func _create_sun(parent: Node) -> void:
	sun_light = DirectionalLight3D.new()
	sun_light.name = "SunLight"
	sun_light.light_color = sun_color
	sun_light.light_energy = sun_energy
	sun_light.shadow_enabled = sun_shadow
	sun_light.shadow_bias = sun_shadow_bias
	sun_light.directional_shadow_max_distance = sun_shadow_distance
	sun_light.rotation_degrees = sun_rotation_deg
	parent.add_child(sun_light)


func _create_fill(parent: Node) -> void:
	fill_light = DirectionalLight3D.new()
	fill_light.name = "FillLight"
	fill_light.light_color = fill_color
	fill_light.light_energy = fill_energy
	fill_light.shadow_enabled = false
	fill_light.rotation_degrees = fill_rotation_deg
	parent.add_child(fill_light)


static func create_default(parent: Node) -> DefaultLighting:
	var rig := DefaultLighting.new()
	parent.add_child(rig)
	return rig
```

---

## .tscn 场景模板（无需脚本）

直接在 `.tscn` 中写入节点配置：

```
[sub_resource type="Environment" id="env"]
background_mode = 1
background_color = Color(0.45, 0.55, 0.72, 1)
ambient_light_source = 2
ambient_light_color = Color(0.7, 0.75, 0.85, 1)
ambient_light_energy = 0.6
tonemap_mode = 2
ssao_enabled = true

[node name="SunLight" type="DirectionalLight3D" parent="."]
transform = Transform3D(0.866, -0.25, 0.433, 0, 0.866, 0.5, -0.5, -0.433, 0.75, 0, 50, 0)
light_color = Color(1, 0.95, 0.85, 1)
light_energy = 1.4
shadow_enabled = true

[node name="FillLight" type="DirectionalLight3D" parent="."]
transform = Transform3D(0.866, 0.25, -0.433, 0, 0.866, 0.5, 0.5, -0.433, 0.75, 0, 50, 0)
light_color = Color(0.6, 0.7, 0.9, 1)
light_energy = 0.4

[node name="WorldEnvironment" type="WorldEnvironment" parent="."]
environment = SubResource("env")
```
