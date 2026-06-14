# Asset Descriptor 合并演示场景

把 `core-asset-properties.tscn` 的「资产属性契约」与 `asset-defaults-descriptor.tscn` 的「AssetDescriptor 语义主来源」两个测试合并到一个可交互场景，用真实树/岩石资产同时验证：默认语义归属、共享字段、语义探针生成、碰撞体范围、buffer 统计显示。

- 场景：`res://demos/asset-descriptor-demo/asset-descriptor-demo.tscn`
- 脚本：`res://demos/asset-descriptor-demo/asset_descriptor_demo.gd`（继承 `core_demo_contract_fixture.gd`）

## 覆盖源文档

| 文档 | 关注点 |
| --- | --- |
| `res://docs/core/asset-properties.md` | 共享字段 `color` / `complexity` / `collision` 的契约 |
| `res://docs/core/auto-asset-scripting.md` | `AutoObject` 同名字段作为 Inspector / 兼容入口 |
| `res://docs/core/asset-semantic-probes.md` | `SemanticProbeProfile` 探针分层采样与优先级 |

`metadata/source_docs` 与 `metadata/focus` 已合并写入根节点，仅作查询/调试 handle，不镜像资产语义默认值。

## 场景构成

- 4 棵树 + 4 块岩石，从 FBX 加载首个 mesh 并 `duplicate(true)`；加载失败时回退到 `BoxMesh`。
- 飞航相机（`fly_camera.gd`）、三点光照（Sun 暖光 + Fill 冷补光 + Rim 轮廓光）。
- `WorldEnvironment` 开启 SSAO 与 Fog；深色参考地面 `PlaneMesh(14×10)`。
- 资产来源 FBX：

```text
res://geo/SM_TestLeaf_Test2.FBX   # 树
res://geo/cliff_01.FBX            # 岩石
res://geo/cliff_02.FBX            # 岩石
```

## 资产语义参数

这些常量代表 `AssetDescriptor` 提供的默认语义，是探针与碰撞体的唯一输入来源。

```gdscript
TREE_COLOR       = Color(0.35, 0.58, 0.24, 0.55)  # 共享字段 color，alpha 同步 complexity
TREE_COMPLEXITY  = 0.45                            # 共享字段 complexity
TREE_COLLISION   = [{ shape="cylinder", radius=0.35, y_min=-0.5, y_max=1.2, collision_strength=0.7 }]

ROCK_COLOR       = Color(0.48, 0.42, 0.35, 0.7)
ROCK_COMPLEXITY  = 0.75
ROCK_COLLISION   = [{ shape="cylinder", radius=0.55, y_min=-0.4, y_max=0.8, collision_strength=0.9 }]
```

`color` / `complexity` / `collision` 是 canonical 共享字段；`channel` 等路由字段不属于共享语义。

## 探针调试

探针由 `SemanticProbeProfile.generate_from_mesh(mesh, collision, color, complexity, density, max_markers)` 生成，按 `shape_source` 分优先级分层 top-k 采样：

| shape_source | 优先级 | 来源 | marker 颜色 |
| --- | --- | --- | --- |
| `convex` | 3（最高） | 凸包表面点 | 黄 `Color(1.0, 0.85, 0.1)` |
| `voxel_interior` | 2 | 碰撞体内部采样点 | 蓝 `Color(0.15, 0.75, 1.0)` |
| `surface` | 1 | Poisson 表面采样 | 绿 `Color(0.4, 1.0, 0.4)` |
| `context` | 0（最低） | AABB 外环境感知（本场景未启用） | 绿（默认色） |

每个资产生成一个调试子节点，附 `probes=N` 计数标签。受 `probe_density`（默认 1.0）与 `max_probe_markers`（默认 96）约束。

## 碰撞体可视化

按资产 `collision` 定义生成半透明 `CylinderMesh`，位置/半径/高度与采样几何一致。

```gdscript
height   = y_max - y_min          # 树=1.7，岩石=1.2
position.y = (y_min + y_max) * 0.5 # 柱体中心对齐
```

- 树：蓝色半透明 `Color(0.1, 0.65, 1.0, 0.25)`
- 岩石：橙色半透明 `Color(1.0, 0.4, 0.1, 0.25)`

## Buffer Info 叠加层

`Label3D` 文本显示资产数量、探针总数、`color` / `complexity` 参数、`density`、`max_markers`，用于核对 buffer 写入预期。

## 快捷键

| 键 | 功能 |
| --- | --- |
| `1` | 切换树木探针调试 |
| `2` | 切换岩石探针调试 |
| `3` | 切换全部探针（任一组可见时则清空全部） |
| `C` | 清除所有调试节点（探针 + 碰撞 + buffer info） |
| `V` | 切换碰撞柱体可视化 |
| `B` | 切换 Buffer Info 叠加层 |

## 验证步骤

1. 在 Godot 打开场景，确认 4 树 + 4 岩石及参考地面正常渲染。
2. 按 `1` / `2` / `3`，确认探针球贴合资产几何，且 `convex`（黄）/ `voxel_interior`（蓝）/ `surface`（绿）颜色区分正确。
3. 按 `V`，确认柱体半径/高度/中心与 `collision` 定义一致（树高 1.7、岩石高 1.2）。
4. 按 `B`，确认叠加层显示资产数量与 `color` / `complexity` / `density` 参数。
5. 按 `C`，确认所有调试节点被清除、再次按键可重新生成。

## 契约测试

`AssetDescriptor` 资产属性契约为纯 CPU 校验，可用 `--headless`：

```bash
godot --headless --path . --script tools/test_asset_properties_descriptor_contract.gd
```

核心 demo 契约与 markdown 契约包含 GPU/Vulkan 校验环节，必须用 Vulkan 驱动运行，禁止 `--headless`：

```bash
godot --path . --rendering-driver vulkan --script tools/test_core_demo_contracts.gd
godot --path . --rendering-driver vulkan --script tools/test_markdown_contracts.gd
```

GPU 路径缺少 `RenderingDevice` 必须显式 skip 或 fail，不得以 CPU fallback 报告通过。

## 验收标准

- `AssetDescriptor` 是资产默认语义的唯一主来源；`AutoObject` 同名字段只作 Inspector / 兼容入口。
- `color` / `complexity` / `collision` 为 canonical 共享字段；`channel` 等路由字段不在其中。
- 探针 marker 颜色按 `shape_source` 区分，分层优先级 `convex > voxel_interior > surface > context`。
- 碰撞柱体的半径、高度、中心与 `collision` 定义一致。
- `metadata` 仅保存 query/debug handle，不镜像资产语义默认值。