---
description: 将深度学习模型集成到 UE 插件中。覆盖三条路线：Python 外部进程（快速原型）、 ONNX Runtime（推荐，~200MB）、纯 C++ 重写（极致体积）。自动评估模型是否 可转 ONNX，选择最优路线。当用户提到 "深度学习"、"AI模型"、"推理"、 "inference"、"PyTorch"、"ONNX"、"转C++"、"模型部署"、"NNE"、 "python to cpp"、"model deployment" 时使用。
---

# UE 深度学习模型集成（Python → C++ 全路线）

## 路线选择决策树

```
模型能否导出为标准 ONNX？
├─ 能（无自定义算子） → 路线 B: ONNX Runtime  (~200MB, 推荐)
├─ 部分能（有自定义算子但可拆分） → 路线 B+C 混合
└─ 不能（大量自定义 CUDA op） → 路线 A: Python 外部进程  (3-5GB)
                                  └─ 后期可投资 → 路线 C: 纯 C++ 重写
```

### 快速判断模型能否转 ONNX

```python
# 测试脚本：尝试导出，看是否报错
import torch
model.eval()
dummy = torch.randn(1, 3, 224, 224).cuda()
torch.onnx.export(model, dummy, "test.onnx", opset_version=17)
# 成功 → 路线 B；报 unsupported op → 检查哪些算子不支持
```

常见不支持 ONNX 的情况：
- 自定义 CUDA 内核（稀疏卷积、VDB 操作等）
- 动态图操作（循环迭代次数依赖输入）
- 非微分后处理（Marching Cubes、NMS 等几何算法）

---

## 路线 A：Python 外部进程（快速原型）

**适用**：模型复杂、有自定义算子、需快速出结果
**体积**：3-5 GB（内嵌 Python + PyTorch）
**延迟**：5-15 秒

### 插件结构

```
Plugins/AITool/
├── AITool.uplugin              # Type: "Editor"（不进游戏包）
├── setup_python.ps1            # 一键准备嵌入式 Python 环境
├── Scripts/<Model>/
│   └── inference.py            # 精简推理脚本 (<10KB)
├── ThirdParty/Python/          # 嵌入式 Python + 依赖（setup 生成）
└── Source/AIModule/
```

### Python 脚本约束

- 最后一行 stdout 必须是 JSON：`{"status":"ok",...}` 或 `{"status":"error","message":"..."}`
- 通过 `--model-package` 参数指定包路径，不硬编码
- 异常时 exit code 非零

### C++ 调用模式

```cpp
FPlatformProcess::ExecProcess(*PythonPath, *Args, &ReturnCode, &StdOut, &StdErr);
// 解析 StdOut 最后一行 JSON
```

### 分发方式

运行 `setup_python.ps1` → 压缩 `AITool/` → 对方解压到 `Plugins/`

---

## 路线 B：ONNX Runtime（推荐）

**适用**：标准前馈模型（分类、分割、检测、生成）
**体积**：50-200 MB（ONNX Runtime + 模型文件）
**延迟**：<1 秒

### 模型转换

```python
import torch, onnx

model.eval()
dummy = torch.randn(1, 3, H, W).cuda()
torch.onnx.export(
    model, dummy, "model.onnx",
    opset_version=17,
    input_names=["input"],
    output_names=["output"],
    dynamic_axes={"input": {0: "batch", 2: "height", 3: "width"},
                  "output": {0: "batch"}}
)

# 验证
onnx_model = onnx.load("model.onnx")
onnx.checker.check_model(onnx_model)
```

### UE 集成方式（两种）

**方式 1：UE NNE 插件**（UE 5.4+）

```cpp
// Build.cs: "NNE", "NNERuntimeORT"
#include "NNE.h"

TUniquePtr<UE::NNE::IModelInstance> ModelInstance;
// 加载 .onnx → CreateModelInstance → RunSync
```

NNE 优点：UE 原生支持，生命周期管理好
NNE 限制：API 可能在版本间变化

**方式 2：直接链接 ONNX Runtime C++ API**

```cpp
// Build.cs 中添加 ONNX Runtime include/lib
#include "onnxruntime_cxx_api.h"

Ort::Env env(ORT_LOGGING_LEVEL_WARNING, "AITool");
Ort::Session session(env, L"model.onnx", Ort::SessionOptions{});
// 构建输入 tensor → session.Run → 读取输出
```

### 插件结构

```
Plugins/AITool/
├── AITool.uplugin
├── Models/<Model>.onnx              # 导出的 ONNX 模型
├── ThirdParty/OnnxRuntime/          # ONNX Runtime DLL + headers
│   ├── include/
│   └── lib/
└── Source/AIModule/
```

### Build.cs（ONNX Runtime 直接链接）

```csharp
string OrtRoot = Path.Combine(PluginRoot, "ThirdParty", "OnnxRuntime");
PublicIncludePaths.Add(Path.Combine(OrtRoot, "include"));
PublicAdditionalLibraries.Add(Path.Combine(OrtRoot, "lib", "onnxruntime.lib"));
RuntimeDependencies.Add("$(PluginDir)/ThirdParty/OnnxRuntime/lib/onnxruntime.dll");
```

---

## 路线 C：纯 C++ 重写（极致方案）

**适用**：性能关键路径、需要每帧推理、极致体积控制
**体积**：<50 MB
**延迟**：最低

### 方法

1. **libtorch C++ API**：用 PyTorch 的 C++ 前端，TorchScript 序列化
2. **手写推理**：直接实现矩阵运算和网络层
3. **GPU Compute Shader**：在 UE 的 RDG/Compute Shader 中实现

### TorchScript 路线示例

```python
# Python: 导出 TorchScript
scripted = torch.jit.trace(model, dummy_input)
scripted.save("model.pt")
```

```cpp
// C++: libtorch 加载
#include <torch/script.h>
torch::jit::script::Module module = torch::jit::load("model.pt");
auto output = module.forward({input_tensor});
```

### 适用场景

- 简单 MLP/CNN（<100 行推理代码）
- 已有 C++ 参考实现的算法
- 需要逐帧运行的实时推理

---

## 体积对比

| 路线 | 插件体积 | 目标机依赖 | 开发周期 |
|------|---------|-----------|---------|
| A: Python | 3-5 GB | NVIDIA 驱动 + CUDA | 1-2 天 |
| B: ONNX | 50-200 MB | NVIDIA 驱动 | 1-2 周 |
| C: C++ | <50 MB | NVIDIA 驱动 | 2-4 周 |

## 通用 Editor-only 配置

```json
// .uplugin — 不进游戏包
{ "Modules": [{ "Name": "AIModule", "Type": "Editor" }] }
```

## JSON 通信协议（路线 A 专用）

Python → C++ stdout 最后一行：
```json
{"status":"ok","output":"/path/result.obj","vertices":1234,"faces":5678}
{"status":"error","message":"CUDA out of memory"}
```

C++ 解析：`FJsonSerializer::Deserialize` + `HasField`/`GetStringField`