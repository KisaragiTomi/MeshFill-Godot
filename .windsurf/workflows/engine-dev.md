---
description: 引擎开发统一技能：软件路径解析、Godot 编译/运行/Compute Shader/RenderDoc 调试/源码导航、 UE 编译/调试/源码导航/Material Custom Node。当用户进行任何引擎相关开发时使用。触发词： Godot, UE, Unreal, 编译, build, scons, compute shader, GLSL, HLSL, RenderingDevice, RenderDoc, 抓帧, GPU 调试, buffer, dispatch, barrier, push constant, Vulkan, MassEntity, MassCrowd, Niagara, Material, Custom Node, 路径, 环境变量, path, env var, GODOT_SOURCE, UE_ROOT, UE_SOURCE, FluidCrowd, 源码, 渲染管线, 调试, debug, 断点, breakpoint, attach, launch, cppvsdbg, natvis。
---

# 引擎开发统一技能

## 路径解析

所有路径通过环境变量管理，先运行脚本获取当前机器的实际值：

```powershell
powershell -ExecutionPolicy Bypass -File "D:\.aidata\skills\engine-dev\resolve-paths.ps1"
# -Validate: 检查路径存在性 | -Json: JSON 输出
```

Shell 命令用 `$env:VAR_NAME`，Read/Grep/Glob 用脚本返回的实际路径。


## Godot: 编译引擎

```powershell
& "$env:GODOT_SOURCE\build.bat"                     # 编译编辑器
& "$env:GODOT_SOURCE\compile.bat"                   # 编译导出模板
# 手动: cd $env:GODOT_SOURCE && scons -j24 target=editor platform=windows
```

选项：`target=editor|template_release|template_debug`、`dev_build=yes`、`debug_symbols=yes`、`compiledb=yes`

## Godot: 运行项目

```powershell
& "$env:GODOT_SOURCE\bin\godot.windows.editor.x86_64.exe" --path $env:FLUID_CROWD
& "$env:GODOT_SOURCE\bin\godot.windows.editor.x86_64.console.exe" --path $env:FLUID_CROWD --main-scene
```

## Godot: Compute Shader

### Shader 结构

```glsl
#[compute]
#version 450
layout(local_size_x = 64) in;
layout(set = 0, binding = 0, std430) restrict readonly  buffer B0 { float data_in[];  };
layout(set = 0, binding = 1, std430) restrict writeonly buffer B1 { float data_out[]; };
layout(push_constant, std430) uniform Params { int count; float dt; };

void main() {
    uint i = gl_GlobalInvocationID.x;
    if (int(i) >= count) return;
    data_out[i] = data_in[i] * dt;
}
```

### 共享内存 (Shared Memory)

**硬件限制**：Vulkan 规范最低保证 `maxComputeSharedMemorySize = 16384` 字节 (16 KB)。
桌面 GPU 通常 32–48 KB，移动端可能仅 16 KB。**必须在分配前计算总量**。

```glsl
// 共享内存声明 — 同一 shader 中所有 shared 变量之和 ≤ maxComputeSharedMemorySize
shared float tile_data[256];       // 256 * 4 = 1024 bytes
shared vec4  tile_colors[64];      // 64 * 16 = 1024 bytes
shared uint  tile_counts[128];     // 128 * 4 =  512 bytes
// 合计: 2560 bytes ✓

// ❌ 危险示例 — 超限会导致管线创建失败或 GPU 挂起
// shared float huge_buf[8192];    // 8192 * 4 = 32768 bytes — 已达桌面上限
```

**计算公式**：`总量 = Σ(元素数 × sizeof(类型))` — 所有 `shared` 变量累加

| 类型 | sizeof | 常见陷阱 |
|------|--------|----------|
| `float / int / uint` | 4 | — |
| `vec2 / ivec2` | 8 | — |
| `vec3` | **16** | std430 对齐到 16 字节，不是 12 |
| `vec4 / mat2` | 16 | — |
| `mat4` | 64 | 大矩阵数组极易超限 |

**GDScript 查询设备限制**：

```gdscript
var rd := RenderingServer.get_rendering_device()
var limit := rd.limit_get(RenderingDevice.LIMIT_MAX_COMPUTE_WORKGROUP_SIZE) # 非共享内存
# Godot 4.x 暂无直接查询 shared memory limit 的 API，
# 保守按 16 KB 设计，桌面可放宽到 32 KB 并做运行时校验
```

**最佳实践**：
1. 声明 shared 变量后立即用注释标注字节数，文件顶部写总量
2. `local_size` × 每线程 shared 用量 不能超过限制（shared 是 workgroup 级别，不是 per-thread）
3. 需要更多数据时，分多次 dispatch 或改用 SSBO
4. `barrier()` / `memoryBarrierShared()` 确保 workgroup 内同步

## Godot: RenderDoc 调试

环境变量：`$env:RENDERDOC_SOURCE`（源码）、`$env:RENDERDOC_ROOT`（安装目录）

**前提**：需使用修改后的 Godot 引擎（swapchain 修复 + RenderDoc capture API）。

### CLI 自动截帧（compute dispatch）

```powershell
renderdoccmd capture --wait-for-exit --opt-ref-all-resources `
  "$env:GODOT_SOURCE\bin\godot.windows.editor.x86_64.console.exe" `
  --path <project> --main-scene --rendering-driver vulkan -- --meshfill-capture
```

### Step 模式（交互截帧）

1. RenderDoc GUI 启动 Godot，传入 `--meshfill-step`
2. **C** = 截帧一次迭代，**R** = 运行一步，**F** = 运行全部

### GDScript API

```gdscript
rd.renderdoc_is_available()    # 检查 RenderDoc 是否加载
rd.renderdoc_capture_begin()   # 开始截帧
rd.renderdoc_capture_end()     # 结束截帧，返回 bool
rd.renderdoc_is_capturing()    # 是否正在截帧
```

| 排查目标 | CLI 方法 | RenderDoc 方法 |
|----------|---------|---------------|
| Buffer I/O | `buffer_get_data()` + 控制台 | dispatch 前后对比 buffer |
| 多 Pass | 日志中确认 barrier | Event Browser |
| 全零输出 | 检查 JSON 输出 | SPIR-V 反编译 |

> 详细指南见 [renderdoc-guide.md](renderdoc-guide.md)

## Godot: 源码导航

追踪链：`rendering_device.h` → `.cpp` → `rendering_device_driver.h` → `drivers/vulkan/...`

```powershell
rg "compute_pipeline" "$env:GODOT_SOURCE\servers" --type cpp --type h
rg "#\[compute\]" "$env:GODOT_SOURCE\servers\rendering\renderer_rd\shaders" --glob "*.glsl"
```

---

## UE: 编译项目（仅编译，不启动）

```powershell
powershell -ExecutionPolicy Bypass -File "D:\.aidata\skills\engine-dev\build-ue.ps1"
# 自动发现 .uproject，调用 Build.bat 编译 Editor Target
# -ProjectDir "D:\path\to\project" : 指定项目路径（默认当前目录）
# -Config Development|DebugGame    : 编译配置（默认 Development）
# -Clean    : 仅清理（不编译）
# -Rebuild  : 先清理再编译（完全重编）
```

## UE: 启动项目

```powershell
powershell -ExecutionPolicy Bypass -File "D:\.aidata\skills\engine-dev\launch-ue.ps1"
# 自动发现 .uproject，用 UE_ROOT 找到 UnrealEditor.exe 并启动
# -ProjectDir "D:\path\to\project" : 指定项目路径（默认当前目录）
# -Game     : 以独立游戏模式启动
# -Log      : 启用日志窗口
# -NoSplash : 跳过启动画面
# -Map "MapName" : 直接打开指定地图
# -ExecCmds "cmd1,cmd2" : 启动后执行控制台命令
```

## UE: 调试项目（一键编译+启动+附加）

```powershell
powershell -ExecutionPolicy Bypass -File "D:\.aidata\skills\engine-dev\debug-ue.ps1"
# 自动: 生成调试配置(如缺失) → 编译 → 启动 UE Editor(-debug) → 打印 PID
# -ProjectDir "D:\path\to\project" : 指定项目路径
# -Config DebugGame : 使用 DebugGame 配置（更完整的调试符号）
# -SkipBuild : 跳过编译，直接启动
# -SetupConfigs : 强制重新生成 .vscode 配置文件
```

启动后在 Cursor 中 `Ctrl+Shift+D` → 选择 "Attach to UE Editor" → F5 附加。

## UE: 调试配置生成（单独使用）

```powershell
powershell -ExecutionPolicy Bypass -File "D:\.aidata\skills\engine-dev\setup-ue-debug.ps1"
# 生成 .vscode/launch.json + tasks.json + c_cpp_properties.json
# -ProjectDir "D:\path\to\project" : 指定项目路径
# -Force : 覆盖已有配置
```

前提：安装扩展 `vadimcn.vscode-lldb`（CodeLLDB）和 `anysphere.cpptools`。
配置使用 `lldb` 调试类型（Cursor 不支持 `cppvsdbg`）。

### 调试方式

| 方式 | 脚本 / 操作 | 适用场景 |
|------|-------------|----------|
| **脚本一键** | `debug-ue.ps1` | 编译+启动+Attach（推荐） |
| **F5 Launch** | Cursor F5 | 从头调试，自动编译 |
| **F5 No Build** | Cursor F5 (选 No Build) | 代码未改，快速重启 |
| **Attach** | Ctrl+Shift+D → Attach | 挂到已运行的 UE Editor |

### 调试技巧

- DebugGame 配置有更完整的调试符号（Development 会内联优化部分函数）
- 条件断点：右键断点 → Edit Condition → 输入 C++ 表达式
- Watch 窗口支持 UE 类型（需加载 natvis）
- Attach 模式可以调试 PIE（Play In Editor）运行时

## UE: 源码搜索

```powershell
rg "FComputeShader|IMPLEMENT_GLOBAL_SHADER" "$env:UE_SOURCE\Engine\Source\Runtime\Renderer" --type cpp -l
rg "Avoidance|Steering" "$env:UE_SOURCE\Engine\Plugins\AI\MassCrowd" --type cpp
rg "Fluid|SPH" "$env:UE_SOURCE\Engine\Plugins\FX\NiagaraFluids" --type cpp
rg "\[numthreads" "$env:UE_SOURCE\Engine\Shaders" --glob "*.usf"
```

## UE: Material Custom Node（MCP）

通过 `POST http://localhost:8090/api/editor/execute_script` 执行 Python：
