# 统一 Debug 承载与输出字典精简方案

项目 debug 相关代码 GDScript 侧约 375 处、GLSL 侧约 166 处，并已自发长出多套互不相通的 GPU debug 机制；同时管线输出字典（`run_minimal` 输出、writeback 报告、route contract 等）键数膨胀，大量条目冗余。两个问题一体两面：**GPU→CPU 的 debug 承载没有统一约定，CPU→调用方的报告也没有统一 schema**。本方案给出两层设计：`DebugBufferSet`（GPU↔CPU 承载）与 `ReportSchema`（输出字典分级），共享同一条原则——约定由机器强制，观测数据按需产出。

关联：`项目冗余与共有逻辑优化方案.md`（批次 2 的 dict 去重条目由本方案收编）、mem `refactor-stability-playbook`（codegen SSOT 与 golden-master）。

> **执行进度（2026-07-12 三代理审计核实，主体落地于 `c878ae9` + `b0ff085`）**
>
> - **步骤 1 ✅** `debug_buffer_set.gd` 全面落地：4 个 schema SSOT（`SCORE_CONTRACT_STATS` / `CANDIDATE_ROUTE_BINDING_STATS` / `CANDIDATE_ROUTE_DEBUG` / `VOXEL_DEBUG_CHANNELS`）+ allocate/reset/make_uniforms/readback/decode_shaped（q1000、bool）/golden_snapshot/emit_glsl_block + `CONSUMERS` 注册表；desync 门禁 `tools/verify_glsl_gen_blocks.gd` headless 实测 `checked=12 failures=0`。
> - **步骤 2 ✅** 试点 route debug 家族完成：`@@GEN` 块进 `score_voxel_tile` / `candidate_route_sparse_adapter` / `pack_candidate_route_records_from_votes`（原第 3 个消费者 expand 已并入 pack）；VPG 端分配与解码全走设施。
> - **步骤 3 ✅** score_contract 半边 ✅（gen-block set1/b8，reset/readback 走设施，always-on 保持，**contract 与 observability 已分实例分 buffer**）；debug_voxel 半边 ✅（`e496ac4`）——VPG 分配/解码/golden_snapshot 全走 `DebugBufferSet(VOXEL_DEBUG_CHANNELS)` 实例，通道数 schema 推导，本地 `NUM_DEBUG_CHANNELS` 与 `_decode_float_array` 已删；uniform 接线与 profiler 传输计时 readback 有意保留手工（对齐 route_debug_set 先例）。
> - **步骤 4 ◐** `report_schema.gd` ✅ 落地，`fail()` 已收编 SPA ×7 失败字典；**writeback 报告三步走完 ✅（expand `cb95a1b` → migrate/contract `774e1fa`）**——`WRITEBACK_REPORT` 分级定稿 core 7 / contract 26 / diag 9（gpu_first、cpu_fallback、readback_source、runtime_read_source、accepted_placement_record_source、accepted_placement_origin_record_source、cpu_batch_bridge、runtime_summary、profile_summary，逐键新鲜 grep 零消费者后降级）；**diag 请求口径已定（Open Question 2 解决）= placement settings 键 `include_diagnostics`（默认 false）**，10 个发射点 + merge 后突变全部门控，flag-on 输出与旧全集逐字节一致；恒定 provenance 键暂留 diag、整删是单独决定；⚠此家族失败路径发全骨架、勿套 `fail()`。**VPG run 输出三步走完 ✅（expand `8a21d7e` → migrate `6f891c4`）**——`VPG_RUN_REPORT` 分级定稿 core 15 / contract 12 / diag 15（15 个候选逐键复核零读者后全降；同名键在 tile-store/route-adapter/prefilter/committer 等其他家族的读取均已甄别）；`include_diagnostics` 贯通 11 个发射点，extras 在 build 前并入 values 不绕门；golden_snapshot/score_timing_profile 留 core 用自身 settings 门。**步骤 4 至此全部完成**（run_multi_asset 输出家族有意独立未迁，恒定 provenance 键整删是单独决定）。
> - **步骤 5 ✅（`e281670`）** `TARGET_STATS_*` 三处声明收编完成：DebugBufferSet 新增 `q1000000`/`inverted_min`（base 随槽位声明）decode kind + `extra_consts` 生成段；双 shader `@@GEN` 块（set/binding 不变，槽位因 magic+version 头 +2）、generator 10 个手写常量删除、9 个输出键名逐字保留；guard 14/14；运行期证据=TargetSV 缓存行 `non_empty=136632` 迁移前后一致。新 shader/新报告默认走两套设施的约定自此无手写 stats 样板可循。
> - **步骤 6 ✅（生产 `b0ff085` + 消费 `89d9c4d`）** 消费链闭环：`volume_score_demo.run_golden_snapshot()`（桥 call_method 直达，确定性——score_ms 刻意排除）+ `tools/golden_snapshot_check.js`（BASELINE CREATED / GOLDEN PASS / GOLDEN DIFF+unified diff）+ `goldens/volume_score_golden.approved.txt` 首基线（179 行，3 资产 ×64 锚点）已进 git；端到端两跑验证过。⚠ 基线是机器/驱动本地的——换 GPU/驱动或评分逻辑正当变更后 re-approve。
> - **写侧门控 ✅（`b559a2e`）**：ScoreConfig SSBO 80→96B 加 `cfg_debug_write_mask`（bit0=voxel 通道写使能，未来家族占后续位——**Open Question 1 就此解决：按 pass 的 config SSBO 承载 per-family bitmask**）；启用条件与读回门同一 `debug_read_voxel_channels` 表达式不可能脱钩；禁用时绑 1 元素 dummy、写成本归零；golden check 迁移后仍 PASS（flag-on 路径逐位不变的硬证据）。
>
> **🎉 方案六步 + 全部剩余工作至此执行完毕（2026-07-12）**：~~①~~（`e496ac4`）~~②~~（`cb95a1b`+`774e1fa`）~~③~~（`8a21d7e`+`6f891c4`）~~④~~（`e281670`）~~⑤~~（`89d9c4d`）~~⑥~~（`b559a2e`）。后续为机会主义项：恒定 provenance 键整删、run_multi_asset 输出家族迁移、`debug_read_*` 散点开关归并、writeback merge 后再发射的硬门——均低优先级，未来轮次或需要时再做。

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

统一解码（带名、q1000 反量化、稳定键序）产出的 dict 即 golden 快照素材：桥跑固定 demo → `readback()` → 存 `goldens/*.approved.txt` → 大扫前后 diff。承载统一后这条链只需一个桥方法。消费链入口：`node tools/golden_snapshot_check.js`（经桥 `call_method` 调 placement-score-3d 的 `VolumeScore.run_golden_snapshot()`，首跑写基线 `goldens/volume_score_golden.approved.txt`，再跑输出 GOLDEN PASS / GOLDEN DIFF）。

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

- ✅ ~~observability 实例的 gate 粒度~~：已定为**按 pass 的 config SSBO 承载 per-family bitmask**（`b559a2e`，bit0=voxel 通道，后续家族占后续位）。
- ✅ ~~`diag` 请求口径~~：已定为 placement settings 键 `include_diagnostics`（默认 false，`774e1fa`）；与 `debug_read_*` 散点开关的归并留给各报告家族迁移时机会主义处理。
- ✅ ~~VPG run 输出零读者键定级~~：migrate 轮逐键 grep 完成，15 键降 diag（`6f891c4`，名单见 `VPG_RUN_REPORT` schema 注释）。
