# docs/placement/autoobject-probe-prefilter.md 测试场景

源文档：`res://docs/placement/autoobject-probe-prefilter.md`  
测试场景：`res://demos/placement-autoobject-probe-prefilter/placement-autoobject-probe-prefilter.tscn`

## 测试方法

1. 打开 `placement-autoobject-probe-prefilter.tscn`，确认场景 focus 为 GPU prefilter 和 route expansion。
2. 运行 prefilter 与 candidate routing 测试：

```bash
<godot> --path . --rendering-driver vulkan --script tools/test_autoobject_probe_prefilter.gd
<godot> --path . --rendering-driver vulkan --script tools/test_voxel_candidate_routing_contract.gd
```

#### 禁止 `--headless`

所有 GPU 测试均依赖 RenderingDevice，使用 --headless 会导致测试无法访问 GPU。GPU 测试必须在 Vulkan 驱动下运行，CPU fallback 不得作为通过条件。

3. 对照 `scripts/autoobject_probe_prefilter_gpu.gd` 和 `shaders/score_anchor_asset_probes.glsl`，检查输入输出字段与文档表格一致。

## 验收标准

- prefilter 读取 `SV[t - 1]` scene/collision 和 `TargetSV_B` target buffers，不写入最终 `SceneVoxel`。
- anchor 只表达 position，`candidate_route_profiles` 保存 footprint / probe / context / interpolation guard 的扩张信息。
- route validation / semantic rerank / MLP 仍只作为候选内后续计划。

