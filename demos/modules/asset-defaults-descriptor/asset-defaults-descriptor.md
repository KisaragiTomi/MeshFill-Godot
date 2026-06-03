# Asset Defaults Descriptor 模块测试场景

模块：asset defaults / descriptor authority  
场景：`res://demos/modules/asset-defaults-descriptor/asset-defaults-descriptor.tscn`

## 覆盖源文档

- `res://docs/core/asset-properties.md`
- `res://docs/core/auto-asset-scripting.md`
- `res://docs/core/asset-semantic-probes.md`

## 测试方法

1. 打开场景，确认该模块覆盖 descriptor 权威、shared fields 和 metadata 边界。
2. 运行字段契约测试：

```bash
<godot> --headless --path . --script tools/test_asset_properties_descriptor_contract.gd
<godot> --headless --path . --script tools/test_markdown_contracts.gd
<godot> --headless --path . --script tools/test_auto_asset_scripting.gd
```

3. 人工检查 `scripts/auto_object.gd`、`scripts/auto_voxel_descriptor.gd`、`scripts/shared_property_type.gd` 的字段注释和文档表格是否一致。

## 验收标准

- `AutoVoxelDescriptor` 是资产默认语义主来源；`AutoObject` 同名字段只作为 Inspector / config / legacy mirror。
- `color`、`complexity`、`collision` 是 canonical shared fields；`channel` / `vegetation_channel` 不进入 shared semantics。
- metadata 只保存 query/debug handle，不镜像资产语义默认值。

