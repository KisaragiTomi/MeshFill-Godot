# docs/core/asset-properties.md 测试场景

源文档：`res://docs/core/asset-properties.md`
测试场景：`res://demos/core-asset-properties/core-asset-properties.tscn`

## 测试方法

1. 打开 `core-asset-properties.tscn`，确认场景 focus 为 descriptor/shared-field contract。
2. 运行资产字段相关测试：

```bash
<godot> --headless --path . --script tools/test_asset_properties_descriptor_contract.gd
<godot> --headless --path . --script tools/test_markdown_contracts.gd
<godot> --headless --path . --script tools/test_auto_asset_scripting.gd
```

3. 检查 `scripts/auto_object.gd`、`scripts/auto_voxel_descriptor.gd`、`scripts/shared_property_type.gd` 是否仍以 `color`、`complexity`、`collision` 为共享字段。

## 验收标准

- `AutoVoxelDescriptor` 是资产默认语义主来源，`AutoObject` 同名字段只作为 Inspector / 兼容入口。
- `collision` 使用 canonical 字段名，`channel` / `vegetation_channel` 不进入 shared semantics。
- metadata 只保存 query/debug handle，不镜像资产语义字段。
