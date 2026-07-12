# 统一 Debug 承载与输出字典精简方案

项目 debug 相关代码 GDScript 侧约 375 处、GLSL 侧约 166 处，并已自发长出多套互不相通的 GPU debug 机制；同时管线输出字典（`run_minimal` 输出、writeback 报告、route contract 等）键数膨胀，大量条目冗余。两个问题一体两面：**GPU→CPU 的 debug 承载没有统一约定，CPU→调用方的报告也没有统一 schema**。本方案给出两层设计：`DebugBufferSet`（GPU↔CPU 承载）与 `ReportSchema`（输出字典分级），共享同一条原则——约定由机器强制，观测数据按需产出。

关联：`项目冗余与共有逻辑优化方案.md`（批次 2 的 dict 去重条目由本方案收编）、mem `refactor-stability-playbook`（codegen SSOT 与 golden-master）。

> **执行进度（2026-07-12 三代理审计核实，主体落地于 `c878ae9` + `b0ff085`）**
>
> - **步骤 1 ✅** `debug_buffer_set.gd` 全面落地：4 个 schema SSOT（`SCORE_CONTRACT_STATS` / `CANDIDATE_ROUTE_BINDING_STATS` / `CANDIDATE_ROUTE_DEBUG` / `VOXEL_DEBUG_CHANNELS`）+ allocate/reset/make_uniforms/readback/decode_shaped（q1000、bool）/golden_snapshot/emit_glsl_block + `CONSUMERS` 注册表；desync 门禁 `tools/verify_glsl_gen_blocks.gd` headless 实测 `checked=12 failures=0`。
> - **步骤 2 ✅** 试点 route debug 家族完成：`@@GEN` 块进 `score_voxel_tile` / `candidate_route_sparse_adapter` / `pack_candidate_route_records_from_votes`（原第 3 个消费者 expand 已并入 pack）；VPG 端分配与解码全走设施。
> - **步骤 3 ◐** score_contract 半边 ✅（gen-block set1/b8，reset/readback 走设施，always-on 保持，**contract 与 observability 已分实例分 buffer**）；debug_voxel 半边只差 VPG 端——schema 已声明 `index_space=voxel_dense_xzy`、gen-block 已进 shader、demo 端已按 schema 解码，但 VPG 仍手写分配（本地 `NUM_DEBUG_CHANNELS := 8`，未从 schema 推导）与 `_decode_float_array` 手写解码。
> - **步骤 4 ◐** `report_schema.gd` ✅ 落地，`fail()` 已收编 SPA ×7 失败字典；但 **`build()` 全项目零调用**——writeback 报告仍手工组装（`WRITEBACK_REPORT` 仅文档化），VPG run 输出已按六类冗余手工精简（含 blocked 变体对齐）但无 schema 强制、无 `include_diagnostics` 分级门。
> - **步骤 5 ✗** `TARGET_STATS_*` 三处声明原样未迁（`target_scene_voxel.glsl` / `target_sv_pack_read_buffers.glsl` / `target_scene_voxel_generator.gd`）；⚠ 其 q1000000 量化与 `MIN_PACK_BASE` 反转-min 编码需先给 DebugBufferSet 加新 decode kind。
> - **步骤 6 ◐** 生产端 ✅（`b0ff085`：`golden_snapshot` 挂 VPG 输出，settings 键 `debug_read_golden_snapshot`；桥现行 call_method 即可取，不加专用桥方法）；消费端 ✗——无 `goldens/` 目录、无存储/对比客户端，前后对照流程尚不可用。
> - 成本约定未落的一条：**写侧门控未实现**（config SSBO `debug_enabled` + 禁用绑 dummy buffer），当前仅 readback 门控、shader 恒写观测通道。
>
> **剩余工作（按价值排序）**：① VPG debug_voxel 收编 ChannelField 实例（删本地通道常量与手写解码）② writeback 报告走 `ReportSchema.build`（expand/migrate/contract 三步）③ VPG run 输出定义 schema + diag 分级 ④ TARGET_STATS 迁移（先加 decode kind）⑤ golden-master 消费链（tools/ 桥客户端 + `goldens/` 存储对比）⑥ 观测实例写侧门控（顺带解决 Open Question 1 的 bitmask 粒度）。

## 现状

### GPU debug 承载：三套同构机制各写一遍

| 现有机制 | 形态 | 重复情况 |
| --- | --- | --- |
| `score_contract_debug[]`（48 words，`SCORE_DEBUG_*` 名表，atomicAdd/atomicMax，q1000 定点，magic 头） | 命名计数槽 | 声明/名表/reset/解码全套手写 |
| `candidate_route_debug[]` / `candidate_route_binding_debug[]`（16 words，magic+诊断） | 命名计数槽 | 同一布局在 3 个 route shader + VPG 解码端重复声明 |
| `debug_voxel[]`（voxel_count × 8 通道 float，`DEBUG_CHANNEL_NAMES`） | 逐元素通道场 | 空构造/通道名/解码在 VPG 内重复 3 处 |

每套机制的完整链路 = GLSL binding 声明 + GDScript 槽位名常量 + reset 打包 + buffer 分配 + uniform 接线 + readback + 名表解码 + dict 组装，约 50–100 行/套。`TARGET_STATS_*` 统计块（2 shader + GDScript 三处声明）同属此形态。

### 输出字典：六类冗余

以 `voxel_placement_generator.gd:1578` 的 run 输出为样本：

| 冗余类别 | 样本 | 处置 |
| --- | --- | --- |
| 恒定 provenance 键 | `"stamp_bounds_source": "stamp_shader_storage_buffer"`（值永不变化） | 删除；只保留真正多路径的 source |
| 提升重复 | `full_field_readback` 整体嵌入后又把 `complexity_field_out_source` 等 4 键拷到顶层；`score_contract_debug` 整体嵌入 + `debug_channel_max` 提升 | 只嵌套一次，不提升拷贝 |
| 可推导键 | `candidate_count = candidate_voxel_sparse_count * top_k`；`debug_channel_count = names.size()` | 删除，推导式写进 schema 注释 |
| schema 回显 | `debug_channel_names` 每次输出（是布局元数据，不是本次结果） | 移到 schema 查询接口，不随结果发 |
| 空占位 | 禁用时仍输出空 `PackedFloat32Array` + `"disabled"` 源字符串 | 禁用时整键不输出，消费者以 `has()` 判断 |
| 输入 echo | route settings 合并回输出 | 不回显输入，消费者自持 |

根因相同：dict 是隐式 API——没有 schema，生产端防御性全量输出（不知道谁在消费），消费端不知道哪些键承重，键只增不减。

## 方案一：DebugBufferSet（GPU↔CPU 统一承载）

### 两种形态，不做万能 buffer

| 形态 | 布局 | 写侧约定 | 覆盖现存用例 |
| --- | --- | --- | --- |
| `StatSlots` | `magic + schema_version + N 个命名 u32 槽` | `atomicAdd`（计数）/ `atomicMax`（峰值）/ q1000（定点量化） | contract debug、route debug、`TARGET_STATS_*` |
| `ChannelField` | `元素数 × 通道数` float 场 | 直接写，按声明的索引空间寻址 | `debug_voxel` 8 通道 |

`ChannelField` 的 schema **必须声明索引空间**（`voxel_dense_xzy` / `tile` / sparse 重映射线程）——项目现存三种索引约定并存，配错索引空间解码即乱码。将来需要事件流再加 RecordRing 形态，第一期不做。

### 约定由 codegen 强制，不是文档约定

- schema 在 GDScript 侧单一真源定义（`PushConstantLayout` 同款字段表），GLSL 声明块由 `emit_glsl_block()` 生成后粘进 `.glsl`，以 `// @@GEN debug_set ... @@END` 标记进 git。
- **不要用 `#include`**：本项目走 `shader_compile_spirv_from_source()` 直读原始字符串、绕过 RDShaderFile 预处理器，`#include` 不参与编译。
- buffer 头部固定 `magic + schema_version`，CPU 解码先验头再信数据（推广 `SCORE_CONTRACT_MAGIC` 现行做法）。

### contract 与 debug 分实例

`score_contract_debug` 是契约守卫（`contract_enabled`/magic 判定 `contract_blocked`），不是可关闭的观测数据。承载形态统一为 `StatSlots`，但**建两个实例**：contract 实例 always-on，observability 实例可 gate。禁止把两类槽混进一个 buffer，防止"关 debug"连带关掉契约守卫。

### 成本约定

- 写侧留在 shader（`debug_enabled` 标志放 config SSBO，**不进 push**——128B 预算金贵；禁用时绑 16 字节 dummy buffer，分支跳过 atomics）。
- **readback 按需**：统一 API 默认不读回，按请求读（推广 `read_debug_voxel` 现行做法）。贵的是 `submit_and_sync` + `buffer_get_data`，不是 GPU 侧写入。
- debug set 占用**固定 set 序号**（建议最后一个 set），与 `ComputeKernel.make_pass_sets` 组合时不重排现有 binding；`score_voxel_tile` 现散在 set0/1/2 的 debug 绑定迁移时收拢。

### 接口骨架

```gdscript
# scripts/utils/debug_buffer_set.gd — composes with a GodotComputeShaderBase owner.
class_name DebugBufferSet
extends RefCounted

# Schema is the single source of truth; GLSL block is generated from it.
const SCORE_STATS := {
	"magic": 0x53434F52,                    # header word 0, validated on decode
	"version": 3,                           # header word 1, bumped on layout change
	"kind": "stat_slots",                   # stat_slots | channel_field
	"slots": [
		{"name": "probe_record_reads", "op": "add"},
		{"name": "probe_weight_q1000", "op": "max", "decode": "q1000"},
	],
}

const VOXEL_CHANNELS := {
	"kind": "channel_field",
	"index_space": "voxel_dense_xzy",       # REQUIRED: dense x,z,y flatten order
	"channels": ["score_total", "best_rotation_slot"],
}

func allocate(owner, element_count: int = 0) -> void: pass   # buffers via owner scopes
func reset(owner) -> void: pass                              # zero + write header
func make_uniforms() -> Array[RDUniform]: pass               # bind at reserved set index
func readback(owner) -> Dictionary: pass                     # on demand only; named + dequantized
static func emit_glsl_block(schema: Dictionary) -> String: pass  # @@GEN block for the .glsl
```

生成的 GLSL 块形如：

```glsl
// @@GEN debug_set score_stats v3 — generated from debug_buffer_set.gd, do not edit
layout(set = 3, binding = 0, std430) restrict buffer ScoreStats {
    uint score_stats[];   // [0]=magic [1]=version, slots follow
};
void dbg_add(uint slot, uint v) { atomicAdd(score_stats[2u + slot], v); }
void dbg_max(uint slot, uint v) { atomicMax(score_stats[2u + slot], v); }
// @@END
```

### 与 golden-master 协同

统一解码（带名、q1000 反量化、稳定键序）产出的 dict 即 golden 快照素材：桥跑固定 demo → `readback()` → 存 `goldens/*.approved.txt` → 大扫前后 diff。承载统一后这条链只需一个桥方法。

## 方案二：ReportSchema（输出字典分级精简）

### 键分四级

| 级别 | 定义 | 输出时机 |
| --- | --- | --- |
| `core` | 下游代码消费的结果与 `ok`/`reason`（沿用现行约定） | 总是 |
| `contract` | 契约测试 / 桥客户端逐字断言的键（冻结名单，改名须同 commit 改测试） | 总是 |
| `diag` | 人看的诊断（source 溯源、统计、快照） | 仅 `include_diagnostics` 请求时 |
| `derived` | 可由其他键推导 | 不输出，推导式写在 schema 注释 |

判定规则：grep 全项目消费者（`.gd` + tools + 桥客户端脚本），零读者的键直接进 `derived` 或删除；被 `test_markdown_contracts` / `test_autoobject_probe_prefilter` 等逐字断言的进 `contract`。

### 构建器

```gdscript
# scripts/utils/report_schema.gd — one schema per report family.
# Precedent: candidate_route_schema.gd already holds shared schema constants.
const WRITEBACK_REPORT := {
	"core": ["ok", "reason", "total_placed", "results"],
	"contract": ["accepted_placement_record_source"],    # frozen: asserted by tests
	"diag": ["dispatch_stats", "buffer_summaries"],      # emitted only on request
	# derived: candidate_count = candidate_voxel_sparse_count * top_k
}

static func build(schema: Dictionary, values: Dictionary, include_diagnostics := false) -> Dictionary:
	pass   # emits core+contract always, diag on flag; push_error on undeclared keys

static func fail(schema: Dictionary, reason: String) -> Dictionary:
	pass   # canonical {ok:false, reason} + schema's failure defaults
```

`build()` 对未声明键报 `push_error` 是**键膨胀的 authoring-time 刹车**——今后想加键必须先进 schema，一处可见。`fail()` 直接收编审计发现的重复失败 dict（SPA ×7、writeback 骨架 ×2、`_gpu_contract_blocked_minimal_output`/`_empty_prefilter_output` 仅差 3 键、route contract dict ×3）。

### 嵌套与溯源规则

- 子系统 contract dict **只嵌套一次**，不再把字段提升拷贝到顶层；消费者要浅路径就改消费者或加 accessor。
- 恒定值 source 键删除；真正多路径的 source 收拢进一个 `sources` 子字典，归 `diag` 级。
- 禁用/未请求的数据整键不发（消费者用 `has()`），不发空数组 + `"disabled"` 字符串对。

### 迁移纪律

按 parallel change 三步走，避免"改一半消费者"的旧伤：

1. **expand**：schema + `build()` 落地，新旧键并发（旧键标 `deprecated`）。
2. **migrate**：按 grep 名单逐个改消费者与契约测试（同 commit）；桥客户端（`tools/editor_bridge_probe.js` 等）也算消费者。
3. **contract**：删除 deprecated 键；`-e` + 桥用例回归。

## 落地顺序

1. `debug_buffer_set.gd`（schema + alloc/bind/readback/decode + `emit_glsl_block`，约 200 行）。
2. 试点 = candidate route debug 家族：3 个 shader 共享一个 16-word 布局，面积最小、离契约最远。
3. 迁 `score_contract_debug` 的样板（语义不动、always-on 不变），再迁 `debug_voxel`（补索引空间声明）。
4. `report_schema.gd` 落地，首个 schema 选 writeback 报告（骨架 ×2 现成收益），随后 VPG run 输出按四级重排。
5. 新 shader / 新报告默认走两套设施；`TARGET_STATS_*` 等旧 stats 块机会主义迁移。
6. golden-master 桥方法接 `readback()` 输出，作为后续大扫的前后对照。

## Open Questions

- observability 实例的 gate 粒度：全局单开关，还是按 shader 家族分开关（config SSBO 一个 bitmask 即可承载）。
- `diag` 请求口径：沿用 settings key（如 `include_diagnostics`）还是桥方法参数；需与现有 `debug_read_target_read_buffer_bytes` 等散点开关归并。
- VPG run 输出中哪些键实际有零读者，待 migrate 阶段逐键 grep 后定级（本方案不预判名单）。
