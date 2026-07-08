# Core SPA UI 点击测试方案

需要使用电脑操控功能控制电脑进行点击测试

# 使用每一种体素选择模式测试体素点击， 整体需要执行三次，确保来回切换选项也能保持正确结果

## 验收标准

- 选择bound是否出现了，避免实心bound
- 对应物体的头顶是否有信息展示， 让信息面朝摄像机
- Mixed 模式拾取优先级稳定：GPU AutoObject → volume-score anchor → TargetSV → SVTile；普通 `Anchor` candidate 和 committed `SV` 不属于 Mixed data fallback。
- 空白点击、释放事件、滚轮事件和 disabled 工具栏都不产生重复选择或错误状态。
- `Anchors`、`Score`、anchor LMB 和滚轮 top-k 能完成一条 volume-score 点击闭环。
- Inspector 参数改变后，视口点击行为与参数语义一致。
- 所有 UI 点击测试均保持 GPU-first 语义；`pick_backend=cpu_fallback` 只能表示屏幕点击定位 fallback，不能替代 `RenderingDevice`、GPU AutoObject runtime 或 placement 验收。
