# docs/core/auto-asset-scripting.md 测试场景

源文档：`res://docs/core/auto-asset-scripting.md`  
测试场景：`res://demos/core-auto-asset-scripting/core-auto-asset-scripting.tscn`

## 测试方法

1. 打开 `core-auto-asset-scripting.tscn`，确认场景覆盖 rock / vegetation 脚手架，而不是运行时 placement。
2. 运行资产脚手架和 test leaf 验证：

```bash
<godot> --headless --path . --script tools/test_auto_asset_scripting.gd
<godot> --headless --path . --script tools/validate_test_leaf_asset.gd
```

3. 如需验证命令行入口，使用 `tools/scaffold_auto_asset.gd` 和 `tools/assets/sm_test_leaf_test2.json` 在临时输出路径执行一次生成。

## 验收标准

- rock 输出为 `AutoRock` scene，vegetation 输出为 descriptor-backed resource。
- 共享字段只通过 descriptor / `AutoVoxelProfile` 归一化，不由 metadata 重新定义。
- `instance_stamp_write_spec` / legacy `voxel_write_spec` 的兼容关系与测试一致。

