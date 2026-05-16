# Architecture Graphs

本目录保存 MeshFill 文档引用的架构图、流程图和 QA 预览图。图文件用于辅助理解，不是 schema 的唯一权威来源；字段、接口和运行时行为仍以 `scripts/`、`shaders/` 和相邻 Markdown 文档为准。

## 图谱清单

| 文件 | 说明 | 关联文档 |
| --- | --- | --- |
| `autoobject_asset_properties.svg` | `AutoObject`、`AutoVoxelDescriptor`、legacy 字段、`voxel_record` 和 metadata 的归属图 | `docs/core/asset-properties.md` |
| `meshfill_current_framework.svg` | 当前 MeshFill 框架、运行时模块和数据流概览 | `docs/core/meshfill-framework.md` |
| `meshfill_compute_shader_3d_placement.svg` | 3D voxel placement compute shader pipeline | `docs/history/voxel-3d-migration-plan.md` |
| `autoobject_probe_scoring_logic.svg` | AutoObject semantic probe scoring 和 GPU prefilter 逻辑 | `docs/placement/autoobject-probe-prefilter.md` |
| `target-scene-voxel-current.svg` | 当前 `TargetSceneVoxel` GPU 生成、持久化和调试显示流程 | `docs/placement/target-scene-voxel-projection.md` |
| `voxel-semantic-routing.svg` | 候选资产路由、candidate voxel region 输出和 physical scoring 边界 | `docs/placement/voxel-semantic-routing.md` |

## QA 预览

| 文件 | 说明 |
| --- | --- |
| `autoobject_asset_properties.qa.png` | `autoobject_asset_properties.svg` 的渲染检查图 |
| `autoobject_probe_scoring_logic.qa.png` | `autoobject_probe_scoring_logic.svg` 的渲染检查图 |

## 维护规则

- 修改 SVG 后，应同步检查对应 Markdown 文档中的字段名和术语。
- 图中不要引入未在代码或文档中定义的新 schema 字段。
- 高层候选区域使用 `voxel_region` 术语；底层 8×8×8 物理块、shader workgroup 和 buffer index 可以继续使用 `tile` / `tile_id`。
- `collision_voxels` 应画成与 `color` / `complexity` 同级的语义字段；`collision_occupancy` 应标注为由 committed `SceneVoxel.collision_voxels` 重建的派生查询视图，不要画成 `SceneVoxel` 子层级或并列顶层语义状态。
- `AutoVoxelDescriptor` 是资产体素语义的唯一权威来源；`AutoObject` 上重复字段只表示 legacy / Inspector / 配置兼容入口。
