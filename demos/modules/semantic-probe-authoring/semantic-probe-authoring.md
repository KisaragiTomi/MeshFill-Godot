# Semantic Probe Authoring 模块测试场景

模块：asset-side semantic probe authoring  
场景：`res://demos/modules/semantic-probe-authoring/semantic-probe-authoring.tscn`

## 覆盖源文档

- `res://docs/core/asset-semantic-probes.md`
- `res://docs/placement/autoobject-probe-prefilter.md`

## 测试方法

1. 打开场景，确认该模块只覆盖资产侧 probe schema / generation / debug，不覆盖 final placement。
2. 运行 probe authoring 测试：

```bash
<godot> --headless --path . --script tools/test_semantic_probe_generation.gd
<godot> --headless --path . --script tools/test_semantic_probe_debug_mesh.gd
<godot> --headless --path . --script tools/validate_test_leaf_asset.gd
```

3. 对照 `scripts/semantic_probe_profile.gd` 检查 `expected_color`、`expected_complexity`、`weight`、`flags`、`kind` 等字段。

## 验收标准

- probe 记录可以由 descriptor/profile 保存或自动生成，并通过 `AutoObject` 读取。
- debug mesh 能区分 source mesh、probe mesh、convex marker 和颜色/透明度。
- probe 只作为 prefilter / candidate validation 的输入，不直接写 committed `SceneVoxel`。

