---
description: 通过 JetBrains MCP 操控 Rider 以 Debug 模式编译、启动和调试 UE 项目。 当用户提到 "Rider 调试"、"Rider debug"、"debug UE"、"Rider 编译"、 "Rider 启动 UE"、"Rider build"、"debug mode"、"DebugGame" 时使用。
---

# Rider Debug UE（通过 MCP）

## 前提条件

- Rider 已打开 UE 项目（`.uproject` 或 `.sln`）
- JetBrains MCP 服务已连接（`user-jetbrains` server）
- UE 项目已配置好引擎路径

## 快速流程

### Step 1: 查询运行配置

```
CallMcpTool: user-jetbrains / get_run_configurations
arguments: { "projectPath": "<项目路径>" }
```

典型 UE 项目配置：
- `<ProjectName>` — C/C++ 项目配置（**用这个**）
- `UE5` — 引擎本身
- `UnrealBuildTool` / `AutomationTool` — .NET 构建工具

### Step 2: 编译项目

```
CallMcpTool: user-jetbrains / build_project
arguments: {
  "projectPath": "<项目路径>",
  "timeout": 300000
}
```

- `timeout` 建议 300000ms（5分钟），大型项目可设更高
- 返回 `isSuccess` 和 `problems` 数组
- 如有编译错误，`problems` 包含文件路径、行号、错误信息

### Step 3: 启动 UE Editor

```
CallMcpTool: user-jetbrains / execute_run_configuration
arguments: {
  "configurationName": "<ProjectName>",
  "projectPath": "<项目路径>",
  "timeout": 10000
}
```

- `timeout` 设较短值（10s），因为 UE Editor 是长驻进程，会 timedOut=true 但进程已启动
- 如果需要 **Debug 模式**（附带调试器），用户需在 Rider 中手动按 **Shift+F9**
  （JetBrains MCP 的 `execute_run_configuration` 仅支持 Run 模式，不支持 Debug 模式）

### Step 4: 附加调试器（已运行的 UE）

如果 UE Editor 已经在运行，在 Rider 中：
1. Run → Attach to Process（Ctrl+Alt+P）
2. 搜索 `UnrealEditor` 进程并附加

## 编译配置选择

| 配置 | 用途 | 调试符号 |
|------|------|----------|
| Development Editor | 日常开发，平衡性能和调试 | 部分（有内联优化） |
| DebugGame Editor | 调试专用，完整符号 | 完整（推荐调试时用） |

切换方法：Rider 顶部工具栏配置下拉 → 选择对应配置。

## 完整 MCP 自动化示例

以下为 Agent 执行的典型调用序列：

```
1. get_run_configurations → 确认配置名
2. build_project → 编译（检查 isSuccess）
3. execute_run_configuration → 启动 UE Editor
4. （用户在 Rider 中 Shift+F9 或 Attach）
```

## 其他有用的 MCP 工具

| 工具 | 用途 |
|------|------|
| `get_project_modules` | 查看解决方案中的所有项目/模块 |
| `get_file_problems` | 查看指定文件的代码问题 |
| `execute_terminal_command` | 在 Rider 终端执行命令 |
| `open_file_in_editor` | 在 Rider 中打开指定文件 |
| `get_symbol_info` | 查询符号定义和引用 |

## 常见问题

**Q: execute_run_configuration 超时了？**
A: 正常现象。UE Editor 是长驻进程，设 10s timeout 让 MCP 调用返回即可，进程已在后台运行。

**Q: 编译报错找不到引擎头文件？**
A: 检查 Rider 的引擎路径设置：File → Settings → Build, Execution, Deployment → Toolset → Unreal Engine。

**Q: 如何切换 DebugGame 配置？**
A: Rider 顶部工具栏的配置下拉菜单中选择，或通过 `.Build.cs` 文件配置。
