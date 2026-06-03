# docs/graphs/README.md 测试场景

源文档：`res://docs/graphs/README.md`  
测试场景：`res://demos/graphs-readme/graphs-readme.tscn`

## 测试方法

1. 在 Godot 中打开 `graphs-readme.tscn`，确认场景说明的是 graph inventory，而不是某个单独架构流程。
2. 对 `docs/graphs/README.md` 中列出的 SVG 逐个运行渲染检查，示例：

```bash
python tools/verify_svg_render.py docs/graphs/scene-voxel-flow.svg --out docs/graphs/qa/scene-voxel-flow.qa.png
python tools/verify_svg_render.py docs/graphs/target-scene-voxel-current.svg --out docs/graphs/qa/target-scene-voxel-current.qa.png
```

3. 检查每个图表条目都有对应的 owning markdown 文档。

## 验收标准

- `docs/graphs/README.md` 的每个 SVG 路径都存在。
- `tools/verify_svg_render.py` 输出 `ok: True`，生成 PNG 非空。
- 图表清单中的 owning doc 与专题文档引用互相一致。

