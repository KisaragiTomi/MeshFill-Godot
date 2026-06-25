# SPA + AutoObject GPU Runtime — 统一交互 / 测试场景

源文档：
- [`scene-placement-actor.md`](scene-placement-actor.md) — SPA 编排契约
- [`autoobject-gpu-runtime-architecture.md`](autoobject-gpu-runtime-architecture.md) — GPU Runtime 架构

测试场景：`res://demos/core-SPA-scene-placement-actor/core-scene-placement-actor.tscn`（交互 Demo，挂 `spa_interactive_demo.gd`）
MCP 测试脚本：`res://demos/core-SPA-scene-placement-actor/spa_test.gd`（9 项 SPA 断言套件，供 `game_call_method` 调用）

## 运行方式

> **@tool 编辑器模式，禁止 F6 / F5 / `--script`。**
>
> 在 Godot 编辑器中打开 `core-scene-placement-actor.tscn`，`@tool` 脚本自动在编辑器视口中注册资产并执行 GPU SVTile AutoObject 批量放置，渲染点云热力图概览，无需运行游戏。
> F6（Run Current Scene）、F5（Run Project）和 `--script` 均被 `core_demo_contract_fixture.gd` 守卫禁止，触发 `assert(false)` 强制崩溃。GPU 测试依赖 RenderingDevice，`--headless` 同样不可用。

## 测试方法

1. 在编辑器中打开 `core-scene-placement-actor.tscn`，`@tool` 脚本会自动在编辑器视口中注册资产并执行 GPU SVTile AutoObject 批量放置，渲染点云概览（无需 F6 运行游戏）。
2. 验证地形正确加载（双面渲染，正确高度）。
3. 确认 HUD 显示 `GPU ready: YES`、SVTile 压力测试 `PASS`，点云概览正确反映放置分布。
4. 交互测试：
   - LMB 点选 GPU AutoObject（黄色高亮标记）
   - LMB 点选数据记录（SVTile / SV / Anchor / TargetSV）
   - Shift+0~5 切换选择模式（Mixed / AutoObject / SVTile / Anchor / SV / TargetSV）
   - G 打印 GPU readiness report
   - Space 重新注册所有资产并重跑 SVTile 压力测试
   - Escape 取消选中
5. MCP 远程调用：Godot 编辑器运行中，通过 Godot MCP 的 `game_call_method` 调用 `spa_test.gd` 的 `run_all_tests()`，返回结果字典。

### spa_test.gd 测试覆盖

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

6. GPU 验收测试（必须在非 headless Vulkan 驱动下运行）：

```bash
<godot> --path . --rendering-driver vulkan --script tools/test_auto_voxel_runtime_profile_container.gd
<godot> --path . --rendering-driver vulkan --script tools/test_core_demo_contracts.gd
<godot> --path . --rendering-driver vulkan --script tools/test_autoobject_probe_prefilter.gd
<godot> --path . --rendering-driver vulkan --script tools/test_gpu_autoobject_runtime_bridge.gd
<godot> --path . --rendering-driver vulkan --script tools/test_voxel_dirty_tile_upload.gd
<godot> --path . --rendering-driver vulkan --script tools/test_voxel_multi_asset.gd
<godot> --path . --rendering-driver vulkan --script tools/test_markdown_contracts.gd
```

#### 禁止 `--headless`

所有 GPU 测试均依赖 RenderingDevice，必须在非 headless Vulkan 驱动下运行；使用 --headless 会导致测试无法访问 GPU，CPU 替代路径不得作为通过条件。

7. 人工检查文档中的 `GPUAutoObjectRuntime`、`AutoVoxelRuntimeProfileContainer`、per-voxel object refs 和 no-RD 测试语义：无 RenderingDevice 时只能 SKIP GPU upload / placement，不能改走 CPU 替代路径。VPG 的 contract validation 必须把 shared-RD runtime/profile buffers bound 并在 placement pass 中 consumed；缺 buffer 时返回 `contract_blocked=true`、`cpu_fallback=false`。

## 验收标准

- SPA 初始化成功，`is_gpu_ready() == true`。
- `register_asset()` 后 profile_id 有效且 GPU buffers resident。
- GPU SVTile AutoObject 批量放置成功，HUD 报告 SVTile 压力测试 `PASS`，点云概览正确反映放置分布。
- GPU AutoObject 点选与数据记录（SVTile / SV / Anchor / TargetSV）选择在各模式下均正常工作。
- 地形双面渲染正常（使用 `common_terrain_material.tres`）。
- `AutoVoxelRuntimeProfileContainer` 由 SPA 创建、管理和释放。
- `GPUAutoObjectRuntime` 拥有 runtime object state、profile id、bounds / exclusion inputs 和 dirty object delta；per-voxel object refs 与 `SceneVoxelTile` dirty 仍归 SV owner。
- `SceneVoxelCommitter` / SV owner 仍拥有 SV grid、commit、`SceneVoxelTile` dirty 和 resident buffers。
- VPG contract validation 通过后必须使用已 bound/consumed 的 `GPUAutoObjectRuntime` 和 `AutoVoxelRuntimeProfileContainer` buffers；只验证不绑定不算通过。
- BrushSV persistence metadata 只保存控制面元数据（`control_plane_only=true`），不镜像体素内容。
- implementation status 与当前源码入口一致，不出现第二套 SceneVoxel source of truth。
- 缺少 `RenderingDevice` 时报告 SKIP，不走 CPU 替代路径。
