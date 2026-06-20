# SPA + AutoObject GPU Runtime — 统一交互测试场景

源文档：
- [`scene-placement-actor.md`](scene-placement-actor.md) — SPA 编排契约
- [`autoobject-gpu-runtime-architecture.md`](autoobject-gpu-runtime-architecture.md) — GPU Runtime 架构

测试场景：`res://demos/core-SPA-scene-placement-actor/core-scene-placement-actor.tscn`

## 测试方法

1. 在编辑器中打开 `core-scene-placement-actor.tscn`，`@tool` 脚本会自动在编辑器视口中生成 AutoObject 实例和线框 AABB 预览（无需 F6 运行游戏）。
2. 验证地形正确加载（双面渲染，正确高度）。
3. 确认每个 AutoObject 上方显示彩色线框 AABB + profile_id 标签。
4. 交互测试（F6 运行游戏时可用，编辑器模式下跳过）：
   - LMB 点击选中物体（黄色高亮）
   - LMB 拖拽移动物体（释放后 terrain-snap）
   - Delete 删除选中物体
   - Ctrl+D 复制选中物体
   - 1-4 在视口中心生成新物体
   - G 打印 GPU readiness report
   - Space 重新注册所有资产

5. GPU 验收测试：

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

所有 GPU 测试均依赖 RenderingDevice，使用 --headless 会导致测试无法访问 GPU。

6. 人工检查文档中的 `GPUAutoObjectRuntime`、`AutoVoxelRuntimeProfileContainer`、per-voxel object refs 和 no-RD 测试语义：无 RenderingDevice 时只能 SKIP GPU upload / placement，不能改走 CPU 替代路径。VPG 的 contract validation 必须把 shared-RD runtime/profile buffers bound 并在 placement pass 中 consumed；缺 buffer 时返回 `contract_blocked=true`、`cpu_fallback=false`。

## 验收标准

- SPA 初始化成功，`is_gpu_ready() == true`。
- `register_asset()` 后 profile_id 有效且 GPU buffers resident。
- 线框 AABB 正确反映每个 AutoObject 的网格尺寸。
- 点选、拖拽、删除、复制、生成均正常工作。
- 地形双面渲染正常（使用 `common_terrain_material.tres`）。
- `AutoVoxelRuntimeProfileContainer` 由 SPA 创建、管理和释放。
- `GPUAutoObjectRuntime` 拥有 runtime object state、profile id、bounds / exclusion inputs 和 dirty object delta；per-voxel object refs 与 `SceneVoxelTile` dirty 仍归 SV owner。
- `SceneVoxelCommitter` / SV owner 仍拥有 SV grid、commit、`SceneVoxelTile` dirty 和 resident buffers。
- VPG contract validation 通过后必须使用已 bound/consumed 的 `GPUAutoObjectRuntime` 和 `AutoVoxelRuntimeProfileContainer` buffers；只验证不绑定不算通过。
- implementation status 与当前源码入口一致，不出现第二套 SceneVoxel source of truth。
- 缺少 `RenderingDevice` 时报告 SKIP，不走 CPU 替代路径。
