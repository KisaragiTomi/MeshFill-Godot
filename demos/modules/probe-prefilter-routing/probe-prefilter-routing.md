# Probe Prefilter Routing 模块测试场景

模块：AutoObject probe prefilter / route vote expansion  
场景：`res://demos/modules/probe-prefilter-routing/probe-prefilter-routing.tscn`

## 覆盖源文档

- `res://docs/placement/autoobject-probe-prefilter.md`
- `res://docs/core/asset-semantic-probes.md`
- `res://docs/placement/target-scene-voxel-projection.md`

## 测试方法

1. 打开场景，确认该模块覆盖 anchor collection、probe scoring、candidate route profile。
2. 运行 prefilter / route expansion 测试：

```bash
<godot> --headless --path . --script tools/test_autoobject_probe_prefilter.gd
<godot> --headless --path . --script tools/test_markdown_contracts.gd
```

3. 检查 `scripts/autoobject_probe_prefilter_gpu.gd`、`shaders/collect_sv_anchors.glsl`、`shaders/score_anchor_asset_probes.glsl` 的字段名与文档一致。

## 验收标准

- prefilter 读取 `SV[t - 1]` scene/collision 和 `TargetSV_B` target buffers，输出 anchors、route votes 和 debug route profiles。
- candidate voxel regions 按 footprint、probe offset、context radius 和 interpolation guard 保守扩张。
- prefilter 不做 final physical placement，也不写 committed `SceneVoxel`。

