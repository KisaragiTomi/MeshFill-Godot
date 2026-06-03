# docs/core/asset-semantic-probes.md 测试场景

源文档：`res://docs/core/asset-semantic-probes.md`  
测试场景：`res://demos/core-asset-semantic-probes/core-asset-semantic-probes.tscn`

## 测试方法

1. 打开 `core-asset-semantic-probes.tscn`，确认场景 focus 指向 descriptor-backed probes。
2. 运行 probe 生成、debug mesh 和 prefilter 测试：

```bash
<godot> --headless --path . --script tools/test_semantic_probe_generation.gd
<godot> --headless --path . --script tools/test_semantic_probe_debug_mesh.gd
<godot> --headless --path . --script tools/test_autoobject_probe_prefilter.gd
```

3. 对照文档中的 probe 数据结构，检查 `scripts/semantic_probe_profile.gd` 和 `scripts/auto_voxel_descriptor.gd` 的字段来源。

## 验收标准

- probe 记录由 descriptor / profile 维护，`AutoObject` 只读取或生成调试显示。
- `expected_color` / `expected_complexity` / `flags` / `weight` 等字段能进入 prefilter 测试路径。
- 文档只把 semantic rerank 写成候选内验证计划，不能写成全资产库主路径。

