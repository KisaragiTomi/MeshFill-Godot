# docs/README.md 测试场景

源文档：`res://docs/README.md`  
测试场景：`res://demos/docs-readme/docs-readme.tscn`

## 测试方法

1. 在 Godot 中打开 `docs-readme.tscn`，确认根节点 metadata 指向 `res://docs/README.md`。
2. 对照 `rg --files docs -g '*.md'` 的结果，检查 `docs/README.md` 是否覆盖当前核心文档、placement 文档、graph 索引和 history 文档。
3. 运行文档契约测试：

```bash
<godot> --headless --path . --script tools/test_markdown_contracts.gd
```

## 验收标准

- `docs/README.md` 中列出的文件路径都存在，新增或删除文档后索引同步更新。
- `volume`、`voxel`、`tile`、`SceneVoxelTile`、`voxel region` 的定义与专题文档保持一致。
- `tools/test_markdown_contracts.gd` 通过；若运行环境缺少 GPU 相关能力，只允许测试脚本显式报告跳过，不允许失败。

