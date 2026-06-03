# Docs Index And Graphs 模块测试场景

模块：documentation index / graph inventory  
场景：`res://demos/modules/docs-index-and-graphs/docs-index-and-graphs.tscn`

## 覆盖源文档

- `res://docs/README.md`
- `res://docs/graphs/README.md`

## 测试方法

1. 打开场景，确认 `metadata/source_docs` 指向 docs index 和 graph index。
2. 对比 `rg --files docs -g '*.md'` 与 `docs/README.md` 的文件清单。
3. 对代表性 SVG 执行渲染检查：

```bash
python tools/verify_svg_render.py docs/graphs/meshfill_current_framework.svg --out docs/graphs/qa/meshfill_current_framework.qa.png
python tools/verify_svg_render.py docs/graphs/scene-voxel-flow.svg --out docs/graphs/qa/scene-voxel-flow.qa.png
python tools/verify_svg_render.py docs/graphs/target-scene-voxel-current.svg --out docs/graphs/qa/target-scene-voxel-current.qa.png
```

## 验收标准

- `docs/README.md` 中的文档路径全部存在，新增专题文档后索引同步更新。
- `docs/graphs/README.md` 中的 SVG 路径全部存在，并且每个图表都能追溯到 owning markdown。
- 渲染得到的 QA PNG 非空，图内文字不重叠、不裁剪。

