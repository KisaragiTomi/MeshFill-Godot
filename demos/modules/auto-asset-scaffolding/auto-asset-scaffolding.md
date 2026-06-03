# Auto Asset Scaffolding 模块测试场景

模块：scripted asset scaffolding  
场景：`res://demos/modules/auto-asset-scaffolding/auto-asset-scaffolding.tscn`

## 覆盖源文档

- `res://docs/core/auto-asset-scripting.md`
- `res://docs/core/asset-properties.md`

## 测试方法

1. 打开场景，确认该模块覆盖 rock scene asset、vegetation descriptor resource 和 runtime config handoff。
2. 运行脚手架测试：

```bash
<godot> --headless --path . --script tools/test_auto_asset_scripting.gd
<godot> --headless --path . --script tools/validate_test_leaf_asset.gd
```

3. 如果需要完整命令验证，使用临时输出路径运行 `tools/scaffold_auto_asset.gd`，避免覆盖正式资产。

## 验收标准

- rock scaffold 输出 `AutoRock` scene，并保留 mesh、height texture、随机参数和 descriptor-backed shared fields。
- vegetation scaffold 输出 `AutoVoxelDescriptor` `.tres`，实例化时能创建对应 `AutoVegetation` 子类。
- `make_instance_config()` 和 runtime metadata 不把资产语义复制成第二套权威字段。

