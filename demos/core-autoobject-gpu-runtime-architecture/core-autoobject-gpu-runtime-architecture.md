# docs/core/autoobject-gpu-runtime-architecture.md 测试场景

源文档：`res://docs/core/autoobject-gpu-runtime-architecture.md`  
测试场景：`res://demos/core-autoobject-gpu-runtime-architecture/core-autoobject-gpu-runtime-architecture.tscn`

## 测试方法

1. 打开场景，确认该 fixture 验证 GPU-first runtime contract：CPU 只做 command / staging / debug readback，SV ownership 不被 runtime 复制。
2. 先运行 headless smoke；无 `RenderingDevice` 时 GPU upload / placement 子项只能 SKIP：

```bash
<godot> --headless --path . --script tools/test_autoobject_probe_prefilter.gd
<godot> --headless --path . --script tools/test_auto_voxel_runtime_profile_container.gd
<godot> --headless --path . --script tools/test_gpu_autoobject_runtime_bridge.gd
<godot> --headless --path . --script tools/test_voxel_dirty_tile_upload.gd
<godot> --headless --path . --script tools/test_voxel_multi_asset.gd
<godot> --headless --path . --script tools/test_markdown_contracts.gd
```

3. 再运行非 headless Vulkan 验收，确认真实 `RenderingDevice`、GPU buffer 和 readback 路径：

```bash
<godot> --path . --rendering-driver vulkan --script tools/test_auto_voxel_runtime_profile_container.gd
<godot> --path . --rendering-driver vulkan --script tools/test_gpu_autoobject_runtime_bridge.gd
<godot> --path . --rendering-driver vulkan --script tools/test_voxel_multi_asset.gd
```

4. 人工检查文档中的 `GPUAutoObjectRuntime`、`AutoVoxelRuntimeProfileContainer`、per-voxel object refs 和 no-RD 测试语义：无 RenderingDevice 时只能 SKIP GPU upload / placement，不能改走 CPU 替代路径。VPG 的 contract validation 必须把 shared-RD runtime/profile buffers bound 并在 placement pass 中 consumed；缺 buffer 时返回 `contract_blocked=true`、`cpu_fallback=false`。

## 验收标准

- `GPUAutoObjectRuntime` 拥有 runtime object state、profile id、bounds / exclusion inputs 和 dirty object delta；per-voxel object refs 与 `SceneVoxelTile` dirty 仍归 SV owner。
- `AutoVoxelRuntimeProfileContainer` 提供 profile id、profile staging、GPU storage buffer upload 和 debug readback，不替代 descriptor source of truth。
- `SceneVoxelCommitter` / SV owner 仍拥有 SV grid、commit、`SceneVoxelTile` dirty 和 resident buffers。
- VPG contract validation 通过后必须使用已 bound/consumed 的 `GPUAutoObjectRuntime` 和 `AutoVoxelRuntimeProfileContainer` buffers；只验证不绑定不算通过。
- implementation status 与当前源码入口一致，不出现第二套 SceneVoxel source of truth。
