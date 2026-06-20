# ScenePlacementActor (SPA) 测试场景

源文档：`res://demos/core-scene-placement-actor/scene-placement-actor.md`  
测试场景：`res://demos/core-scene-placement-actor/core-scene-placement-actor.tscn`  
测试脚本：`res://demos/core-scene-placement-actor/spa_test.gd`

## 运行方式

> **@tool 编辑器模式，禁止 F6。**
>
> 在 Godot 编辑器中双击打开 `.tscn` 场景文件即可。`spa_test.gd` 在编辑器视口中自动运行 9 项 SPA 功能测试。
> F6（Run Current Scene）和 F5（Run Project）被 `core_demo_contract_fixture.gd` 守卫代码禁止。

## 测试触发

**方式 A — 编辑器自动运行**：打开 `core-scene-placement-actor.tscn`，`_ready()` 自动调用 `run_all_tests()`，结果输出到 Godot Output 面板和场景内 `ResultLabel`（Label3D）。

**方式 B — MCP 远程调用**：Godot 编辑器运行中，通过 Godot MCP 的 `game_call_method` 调用 `run_all_tests()`，返回结果字典。

#### 禁止 F6/F5 和 --script

所有 demo 场景禁止通过 F6（Run Current Scene）、F5（Run Project）或 `--script` 命令行运行。运行时守卫会触发 `assert(false)` 强制崩溃。GPU 测试依赖 RenderingDevice，`--headless` 同样不可用。

## 测试覆盖

| # | 测试名 | 覆盖功能 |
|---|---|---|
| 1 | `test_lifecycle` | `initialize()` / `is_initialized()` / `dispose()` 生命周期 |
| 2 | `test_asset_registration` | `register_asset()` / `get_asset_count()` / `clear_assets()` / `get_profile_id_for_asset()` |
| 3 | `test_gpu_readiness` | `is_gpu_ready()` / `get_gpu_readiness_report()` |
| 4 | `test_gpu_buffer_access` | `get_probe_records_buffer()` / `get_profile_table_buffer()` / `get_pivot_records_buffer()` RID 有效性 |
| 5 | `test_mesh_description` | `get_mesh_description_gpu_buffer_summary()` gpu_first / `readback_mesh_description_debug_snapshot()` |
| 6 | `test_external_references` | `get_sv_committer()` / `get_gpu_runtime()` / `get_runtime_profile_container()` 初始状态 |
| 7 | `test_brush_sv_metadata` | `set_brush_sv_persistence_metadata()` / `update_brush_sv_lifecycle_state()` / `clear_brush_sv_persistence_metadata()` |
| 8 | `test_pipeline_error_paths` | 未初始化 / 空注册表时 `run_placement_pipeline()` 返回 `ok=false` |
| 9 | `test_merged_gpu_summary` | `get_merged_gpu_buffer_summary()` 聚合报告 |

## 验收标准

- SPA 是 descriptor 注册、GPU profile buffer 生命周期和 placement pipeline 的统一入口。
- `AutoVoxelRuntimeProfileContainer` 由 SPA 创建、管理和释放，profile/probe/collision/pivot buffers 必须 GPU resident。
- `SceneVoxelCommitter`、`GPUAutoObjectRuntime` 和 `TargetSV_B` read buffers 由外部 owner 提供，SPA 不复制它们的权威状态。
- 缺少 `RenderingDevice`、profile container 未 ready 或 VPG contract blocked 时只能报告 blocked / SKIP，不能改走 CPU 替代路径。
- `gpu_first=true`，`cpu_fallback=false` 在所有 GPU buffer summary 中显式声明。
- BrushSV persistence metadata 只保存控制面元数据（`control_plane_only=true`），不镜像体素内容。
