@tool
class_name DebugBufferSet
extends RefCounted

## GPU↔CPU debug 承载的统一设施（《统一Debug承载与输出字典精简方案.md》方案一）。
##
## 项目里自发长出多套同构的 GPU debug 缓冲机制——命名计数槽（score_contract_debug 48 字、
## candidate_route_binding_debug 16 字）与逐体素通道场（debug_voxel 8 通道）——每套都把
## 「GLSL 声明 + 槽位名表 + reset 打包 + readback + 名表解码」手写一遍。本类把这条链收敛成
## 一个由 **单一 schema** 驱动的设施：schema 在 GDScript 侧是唯一真源，GLSL 声明块由
## [method emit_glsl_block] 生成后以 `// @@GEN debug_set <name> … // @@END debug_set <name>`
## 标记粘进 `.glsl`（本项目走 shader_compile_spirv_from_source 直读原始串、绕过预处理器，
## 因此 `#include` 不参与编译——共享一律走 codegen 生成块，见 [RouteTileSharedGLSL]）。
## tools/verify_glsl_gen_blocks.gd 是对应的 desync guard。
##
## 与 [PushConstantLayout]（push 打包器）同款「有序字段表→机器强制布局」思路，只是这里管的是
## 一个 storage buffer 的观测承载而非 push constant。本类完全通过 owner（[GodotComputeShaderBase]
## 或子类）的公开方法组合——storage_buffer_from_bytes / storage_buffer_zero / make_storage_uniform
## / read_buffer_bytes——既不继承也不修改 base，对 base 的并发改动免疫。
##
## 两种形态（不做万能 buffer）：
##   [b]stat_slots[/b]：`[可选 magic 头] + N 个命名 u32 槽`，写侧 atomicAdd（计数）/ atomicMax（峰值）
##       / q1000（定点量化）。覆盖 contract debug、route debug、TARGET_STATS_*。
##   [b]channel_field[/b]：`元素数 × 通道数` float 场，直接写、按声明的 index_space 寻址。覆盖
##       debug_voxel 8 通道。schema [b]必须[/b]声明 index_space（本项目现存 voxel_dense_xzy /
##       tile / sparse 三种索引约定并存，配错即乱码）。
##
## contract 与 debug 分实例：score_contract_debug 是[b]契约守卫[/b]（magic/enabled 判定
## contract_blocked），承载形态用 stat_slots 但语义 always-on，不可与可 gate 的观测槽混进一个
## buffer——本类只提供机制，是否 gate 由各家 buffer 各自的 schema/实例决定。

const BufferUtils := preload("res://scripts/utils/buffer_utils.gd")

const KIND_STAT_SLOTS := "stat_slots"
const KIND_CHANNEL_FIELD := "channel_field"

# 每槽 decode 变换（仅 readback 的 shaped 视图用；raw values 一律原样 int）。
const DECODE_INT := "int"
const DECODE_BOOL := "bool"
const DECODE_Q1000 := "q1000"   # float(word) / 1000.0（写侧 q1000 定点，[0,1] 或非负域）

# ── schema 单一真源（SSOT）：每个 buffer 一份，GLSL 声明与 GDScript 解码都从这里派生 ──

## score_contract_debug（score_voxel_tile.glsl set1 binding8，48 字，magic "MFPR"）。
## 契约守卫，always-on。48 个 decode 名与 GLSL 常量名部分不同（如 ENABLED vs contract_enabled），
## 故每槽同时携带 name（decode 键，= 原 SCORE_CONTRACT_DEBUG_NAMES）与 glsl（GLSL 常量名，仅有
## 常量的槽携带；debug_max 通道用单个 DEBUG_MAX_BASE 基址寻址，故 24–30 无独立常量）。
const SCORE_CONTRACT_STATS := {
	"name": "score_contract_stats",
	"kind": KIND_STAT_SLOTS,
	"glsl_struct": "ScoreRuntimeProfileDebug",
	"glsl_array": "score_contract_debug",
	"set": 1,
	"binding": 8,
	"word_count": 48,
	"magic": 0x4D465052,        # "MFPR": MeshFill placement runtime/profile
	"magic_word": 0,
	"magic_const": "SCORE_CONTRACT_MAGIC",  # shader/CPU 现有名（非派生的 *_DEBUG_MAGIC）
	"reset_magic": true,        # CPU reset 写 magic；enabled 等由 shader 写
	"const_prefix": "SCORE_DEBUG_",
	"slots": [
		{"index": 0, "name": "magic", "glsl": "SCORE_DEBUG_MAGIC"},
		{"index": 1, "name": "contract_enabled", "glsl": "SCORE_DEBUG_ENABLED", "decode": DECODE_BOOL},
		{"index": 2, "name": "runtime_object_capacity", "glsl": "SCORE_DEBUG_RUNTIME_OBJECT_CAPACITY"},
		{"index": 3, "name": "profile_count", "glsl": "SCORE_DEBUG_PROFILE_COUNT"},
		{"index": 4, "name": "alive_object_reads", "glsl": "SCORE_DEBUG_ALIVE_OBJECT_READS", "op": "add"},
		{"index": 5, "name": "profile_records_matched", "glsl": "SCORE_DEBUG_PROFILE_RECORDS_MATCHED", "op": "add"},
		{"index": 6, "name": "runtime_overlap_tests", "glsl": "SCORE_DEBUG_RUNTIME_OVERLAP_TESTS", "op": "add"},
		{"index": 7, "name": "runtime_overlap_hits", "glsl": "SCORE_DEBUG_RUNTIME_OVERLAP_HITS", "op": "add"},
		{"index": 8, "name": "profile_table_reads", "glsl": "SCORE_DEBUG_PROFILE_TABLE_READS", "op": "add"},
		{"index": 9, "name": "asset_profile_id", "glsl": "SCORE_DEBUG_ASSET_PROFILE_ID"},
		{"index": 10, "name": "candidate_invocations", "glsl": "SCORE_DEBUG_CANDIDATE_INVOCATIONS", "op": "add"},
		{"index": 11, "name": "profile_complexity_q1000", "glsl": "SCORE_DEBUG_PROFILE_COMPLEXITY_Q1000", "decode": DECODE_Q1000},
		{"index": 12, "name": "runtime_profile_reads", "glsl": "SCORE_DEBUG_RUNTIME_PROFILE_READS", "op": "add"},
		{"index": 13, "name": "runtime_profile_matches", "glsl": "SCORE_DEBUG_RUNTIME_PROFILE_MATCHES", "op": "add"},
		{"index": 14, "name": "probe_record_reads", "glsl": "SCORE_DEBUG_PROBE_RECORD_READS", "op": "add"},
		{"index": 15, "name": "reserved_profile_side_read"},
		{"index": 16, "name": "pivot_record_reads", "glsl": "SCORE_DEBUG_PIVOT_RECORD_READS", "op": "add"},
		{"index": 17, "name": "probe_weight_q1000", "glsl": "SCORE_DEBUG_PROBE_WEIGHT_Q1000", "op": "max", "decode": DECODE_Q1000},
		{"index": 18, "name": "reserved_profile_side_metric"},
		{"index": 19, "name": "pivot_bias_q1000", "glsl": "SCORE_DEBUG_PIVOT_BIAS_Q1000", "op": "max", "decode": DECODE_Q1000},
		{"index": 20, "name": "profile_probe_count", "glsl": "SCORE_DEBUG_PROFILE_PROBE_COUNT", "op": "max"},
		{"index": 21, "name": "reserved_profile_side_count"},
		{"index": 22, "name": "profile_pivot_count", "glsl": "SCORE_DEBUG_PROFILE_PIVOT_COUNT", "op": "max"},
		{"index": 23, "name": "debug_max_target_coverage_q1000", "glsl": "SCORE_DEBUG_DEBUG_MAX_BASE", "op": "max", "decode": DECODE_Q1000},
		{"index": 24, "name": "debug_max_target_complexity_fit_q1000", "op": "max", "decode": DECODE_Q1000},
		{"index": 25, "name": "debug_max_target_color_fit_q1000", "op": "max", "decode": DECODE_Q1000},
		{"index": 26, "name": "debug_max_target_density_q1000", "op": "max", "decode": DECODE_Q1000},
		{"index": 27, "name": "debug_max_placement_score_q1000", "op": "max", "decode": DECODE_Q1000},
		{"index": 28, "name": "debug_max_best_rotation_slot", "op": "max", "decode": DECODE_Q1000},
		{"index": 29, "name": "debug_max_solid_collision_q1000", "op": "max", "decode": DECODE_Q1000},
		{"index": 30, "name": "debug_max_clearance_overlap_q1000", "op": "max", "decode": DECODE_Q1000},
		{"index": 31, "name": "runtime_spacing_tests", "glsl": "SCORE_DEBUG_RUNTIME_SPACING_TESTS", "op": "add"},
		{"index": 32, "name": "runtime_spacing_profile_matches", "glsl": "SCORE_DEBUG_RUNTIME_SPACING_PROFILE_MATCHES", "op": "add"},
		{"index": 33, "name": "runtime_spacing_rejections", "glsl": "SCORE_DEBUG_RUNTIME_SPACING_REJECTIONS", "op": "add"},
		{"index": 34, "name": "runtime_spacing_min_distance_q1000", "glsl": "SCORE_DEBUG_RUNTIME_SPACING_MIN_DISTANCE_Q1000", "op": "max", "decode": DECODE_Q1000},
		{"index": 35, "name": "scene_voxel_tile_object_ref_enabled", "glsl": "SCORE_DEBUG_OBJECT_REF_ENABLED", "decode": DECODE_BOOL},
		{"index": 36, "name": "scene_voxel_tile_object_ref_tile_reads", "glsl": "SCORE_DEBUG_OBJECT_REF_TILE_READS", "op": "add"},
		{"index": 37, "name": "scene_voxel_tile_object_ref_slot_reads", "glsl": "SCORE_DEBUG_OBJECT_REF_SLOT_READS", "op": "add"},
		{"index": 38, "name": "scene_voxel_tile_object_ref_object_reads", "glsl": "SCORE_DEBUG_OBJECT_REF_OBJECT_READS", "op": "add"},
		{"index": 39, "name": "scene_voxel_tile_object_ref_duplicate_reads", "glsl": "SCORE_DEBUG_OBJECT_REF_DUPLICATE_READS", "op": "add"},
		{"index": 40, "name": "reserved40"},
		{"index": 41, "name": "reserved41"},
		{"index": 42, "name": "reserved42"},
		{"index": 43, "name": "reserved43"},
		{"index": 44, "name": "reserved44"},
		{"index": 45, "name": "reserved45"},
		{"index": 46, "name": "reserved46"},
		{"index": 47, "name": "reserved47"},
	],
}

## candidate_route_binding_debug（16 字，无 magic；word0=enabled、word1=range_count 由 CPU 播种）。
## 由 score_voxel_tile.glsl（set2 binding2，低字 0–7）与 candidate_route_sparse_adapter.glsl
## （set0 binding3，高字 8–14）共同写入，VPG 回读解码。原本 16 个槽名只以内联字典键存在于解码器
## 里（无名表、无常量）——这里收敛为 schema：GLSL 声明 + 常量块 + GDScript 解码名一处定义。
const CANDIDATE_ROUTE_BINDING_STATS := {
	"name": "candidate_route_binding_stats",
	"kind": KIND_STAT_SLOTS,
	"glsl_struct": "CandidateRouteBindingDebug",
	"glsl_array": "candidate_route_binding_debug",
	# set/binding 因 shader 而异（score set2/b2、adapter set0/b3），emit 时按 consumer 覆盖。
	"set": 2,
	"binding": 2,
	"word_count": 16,
	"const_prefix": "CANDIDATE_ROUTE_BINDING_",
	"slots": [
		{"index": 0, "name": "enabled", "glsl": "CANDIDATE_ROUTE_BINDING_ENABLED"},
		{"index": 1, "name": "range_count", "glsl": "CANDIDATE_ROUTE_BINDING_RANGE_COUNT"},
		{"index": 2, "name": "range_reads", "glsl": "CANDIDATE_ROUTE_BINDING_RANGE_READS", "op": "add"},
		{"index": 3, "name": "record_reads", "glsl": "CANDIDATE_ROUTE_BINDING_RECORD_READS", "op": "add"},
		{"index": 4, "name": "first_range_start", "glsl": "CANDIDATE_ROUTE_BINDING_FIRST_RANGE_START"},
		{"index": 5, "name": "first_range_count", "glsl": "CANDIDATE_ROUTE_BINDING_FIRST_RANGE_COUNT"},
		{"index": 6, "name": "first_record_x", "glsl": "CANDIDATE_ROUTE_BINDING_FIRST_RECORD_X"},
		{"index": 7, "name": "first_record_y", "glsl": "CANDIDATE_ROUTE_BINDING_FIRST_RECORD_Y"},
		{"index": 8, "name": "sparse_adapter_candidate_count", "glsl": "CANDIDATE_ROUTE_BINDING_SPARSE_ADAPTER_CANDIDATE_COUNT", "op": "add"},
		{"index": 9, "name": "sparse_adapter_record_reads", "glsl": "CANDIDATE_ROUTE_BINDING_SPARSE_ADAPTER_RECORD_READS", "op": "add"},
		{"index": 10, "name": "sparse_adapter_range_index", "glsl": "CANDIDATE_ROUTE_BINDING_SPARSE_ADAPTER_RANGE_INDEX"},
		{"index": 11, "name": "sparse_adapter_output_capacity", "glsl": "CANDIDATE_ROUTE_BINDING_SPARSE_ADAPTER_OUTPUT_CAPACITY"},
		{"index": 12, "name": "sparse_adapter_range_start", "glsl": "CANDIDATE_ROUTE_BINDING_SPARSE_ADAPTER_RANGE_START"},
		{"index": 13, "name": "sparse_adapter_range_count", "glsl": "CANDIDATE_ROUTE_BINDING_SPARSE_ADAPTER_RANGE_COUNT"},
		{"index": 14, "name": "sparse_adapter_record_capacity", "glsl": "CANDIDATE_ROUTE_BINDING_SPARSE_ADAPTER_RECORD_CAPACITY"},
		{"index": 15, "name": "reserved15"},
	],
}

## candidate_route_debug（pack_candidate_route_records_from_votes.glsl set0 binding5，
## 16 字，magic "GPRP" 在 word4）。此 buffer [b]只写不回读[/b]（CPU 从不解码），故仅把
## [b]声明[/b]收敛为 codegen；magic 与逐槽写入留在 shader 手写（不生成常量、不进 magic）。
## slots 仅作布局文档。（原 expand_scene_voxel_tile_routes.glsl 消费者已并入 pack——
## summary 空 tile 过滤成为同一 shader 的 use_summary_filter 开关。）
const CANDIDATE_ROUTE_DEBUG := {
	"name": "candidate_route_debug",
	"kind": KIND_STAT_SLOTS,
	"glsl_struct": "CandidateRouteDebug",
	"glsl_array": "candidate_route_debug",
	"set": 0,
	"binding": 5,
	"word_count": 16,
	# 写侧布局文档（不生成 GLSL 常量；magic@4 因 shader 而异，不入 schema）：
	"slots": [
		{"index": 0, "name": "written_records", "op": "store"},
		{"index": 1, "name": "positive_votes", "op": "store"},
		{"index": 2, "name": "duplicate_marks", "op": "store"},
		{"index": 3, "name": "overflow_records", "op": "store"},
		{"index": 4, "name": "magic"},
		{"index": 5, "name": "asset_count"},
		{"index": 6, "name": "tile_count"},
		{"index": 7, "name": "record_capacity"},
		{"index": 8, "name": "written_records_echo"},
		{"index": 9, "name": "skipped_empty_tiles"},
	],
}

## debug_voxel（score_voxel_tile.glsl set0 binding7，8 通道 float 场）。
## index_space = voxel_dense_xzy（稠密体素空间，x 最快 → z → y 最外；voxel_index() 计算
## p.x + gx*(p.z + gz*p.y)）。读侧默认关闭（settings debug_read_voxel_channels），是可 gate
## 的观测数据（非契约守卫）。
const VOXEL_DEBUG_CHANNELS := {
	"name": "voxel_debug_channels",
	"kind": KIND_CHANNEL_FIELD,
	"glsl_struct": "DebugVoxelOutput",
	"glsl_array": "debug_voxel",
	"set": 0,
	"binding": 7,
	"index_space": "voxel_dense_xzy",
	"channel_count_const": "NUM_DEBUG_CHANNELS",
	"channel_const_prefix": "DEBUG_CH_",
	"channels": [
		{"name": "target_coverage", "glsl": "DEBUG_CH_TARGET_COVERAGE"},
		{"name": "target_complexity_fit", "glsl": "DEBUG_CH_TARGET_COMPLEXITY_FIT"},
		{"name": "target_color_fit", "glsl": "DEBUG_CH_TARGET_COLOR_FIT"},
		{"name": "target_density", "glsl": "DEBUG_CH_TARGET_DENSITY"},
		{"name": "placement_score", "glsl": "DEBUG_CH_PLACEMENT_SCORE"},
		{"name": "best_rotation_slot", "glsl": "DEBUG_CH_BEST_ROTATION_SLOT"},
		{"name": "solid_collision", "glsl": "DEBUG_CH_SOLID_COLLISION"},
		{"name": "clearance_overlap", "glsl": "DEBUG_CH_CLEARANCE_OVERLAP"},
	],
}

## 每个生成块被哪些 shader 承载（供 verify_glsl_gen_blocks.gd 扫描；set/binding 按 shader 覆盖）。
## 每项：{schema, overrides:{set,binding}}。marker 名统一 debug_set <schema.name>。
const CONSUMERS := [
	# candidate_route_binding_debug —— pilot：decl+consts 一体块（binding 处无既有独立常量段）。
	{"schema": CANDIDATE_ROUTE_BINDING_STATS, "shader": "res://shaders/score_voxel_tile.glsl", "set": 2, "binding": 2},
	{"schema": CANDIDATE_ROUTE_BINDING_STATS, "shader": "res://shaders/candidate_route_sparse_adapter.glsl", "set": 0, "binding": 3},
	# candidate_route_debug —— 只写不回读，仅声明入 codegen。
	{"schema": CANDIDATE_ROUTE_DEBUG, "shader": "res://shaders/pack_candidate_route_records_from_votes.glsl", "set": 0, "binding": 5},
	# score_contract_debug —— decl 与 consts 分处两段（binding 扎堆区 / 常量扎堆区），故分 section。
	{"schema": SCORE_CONTRACT_STATS, "shader": "res://shaders/score_voxel_tile.glsl", "section": SECTION_DECL},
	{"schema": SCORE_CONTRACT_STATS, "shader": "res://shaders/score_voxel_tile.glsl", "section": SECTION_CONSTS},
	# debug_voxel —— 同样 decl / consts 分处两段。
	{"schema": VOXEL_DEBUG_CHANNELS, "shader": "res://shaders/score_voxel_tile.glsl", "section": SECTION_DECL},
	{"schema": VOXEL_DEBUG_CHANNELS, "shader": "res://shaders/score_voxel_tile.glsl", "section": SECTION_CONSTS},
]


# ── 实例状态 ──
var schema: Dictionary
var buffer := RID()
var _element_count := 0


func _init(schema_dict: Dictionary = {}) -> void:
	schema = schema_dict


# ── introspection ──

func kind() -> String:
	return str(schema.get("kind", KIND_STAT_SLOTS))


func word_count() -> int:
	return int(schema.get("word_count", 0))


func channel_list() -> Array:
	return schema.get("channels", [])


func channel_count() -> int:
	return channel_list().size()


func channel_names() -> PackedStringArray:
	var names := PackedStringArray()
	for ch in channel_list():
		names.append(str(ch.get("name", "")))
	return names


## 通道名 → 通道索引（channel_field）；未知名返回 -1。消费者据此免去硬编码通道号。
func channel_index(channel_name: String) -> int:
	var channels := channel_list()
	for i in range(channels.size()):
		if str(channels[i].get("name", "")) == channel_name:
			return i
	return -1


## voxel_dense_xzy 索引空间的扁平化（x 最快 → z → y 最外），与 shader voxel_index() 对称：
## p.x + grid.x * (p.z + grid.z * p.y)。channel_field 消费者在 CPU 侧定位体素时用此，避免各处
## 重抄这条公式（现存 shader voxel_index + demo CPU 侧两抄）。
static func voxel_dense_xzy_index(p: Vector3i, grid: Vector3i) -> int:
	return p.x + grid.x * (p.z + grid.z * p.y)


## 槽名 → 字索引；未知名返回 -1。
func slot_index(slot_name: String) -> int:
	for slot in schema.get("slots", []):
		if str(slot.get("name", "")) == slot_name:
			return int(slot.get("index", -1))
	return -1


## 承载缓冲区的字节数。channel_field 需要 element_count（元素数）。
func byte_count(element_count: int = 0) -> int:
	if kind() == KIND_CHANNEL_FIELD:
		var elems := element_count if element_count > 0 else _element_count
		return maxi(elems, 0) * channel_count() * 4
	return word_count() * 4


# ── 生命周期（组合 GodotComputeShaderBase owner）──

## 分配承载缓冲区并写入初始头（stat_slots 写 magic + 播种字；channel_field 全零）。
## seed：stat_slots 的 CPU 播种字 {slot_name: u32_value}（如 binding_debug 的 enabled/range_count）。
## 返回 buffer RID（同时缓存在 self.buffer）。owner 须已 ensure_device。
func allocate(owner, element_count: int = 0, seed: Dictionary = {}, scope: String = GodotComputeShaderBase.SCOPE_FRAME, label: String = "") -> RID:
	var resolved_label := label if not label.is_empty() else str(schema.get("name", "debug_buffer_set"))
	if kind() == KIND_CHANNEL_FIELD:
		_element_count = maxi(element_count, 0)
		buffer = owner.storage_buffer_zero(byte_count(_element_count), scope, resolved_label)
	else:
		buffer = owner.storage_buffer_from_bytes(reset_bytes(seed), scope, resolved_label)
	return buffer


## stat_slots 的 reset 字节：全零，按需写 magic（reset_magic 时）与 CPU 播种字。
func reset_bytes(seed: Dictionary = {}) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(word_count() * 4)  # resize 后全零
	if schema.has("magic") and bool(schema.get("reset_magic", true)):
		bytes.encode_u32(int(schema.get("magic_word", 0)) * 4, int(schema["magic"]))
	if schema.has("version") and int(schema.get("version_word", 1)) >= 0:
		bytes.encode_u32(int(schema.get("version_word", 1)) * 4, int(schema["version"]))
	for slot_name in seed:
		var idx := slot_index(str(slot_name))
		if idx >= 0:
			bytes.encode_u32(idx * 4, int(seed[slot_name]))
		else:
			push_error("DebugBufferSet(%s).reset_bytes: 未知播种槽 '%s'" % [str(schema.get("name", "")), slot_name])
	return bytes


## 在 schema 声明的 set 内为本承载生成 uniform（binding 取 schema.binding，或 override）。
func make_uniform(owner, binding_override: int = -1) -> RDUniform:
	var binding := binding_override if binding_override >= 0 else int(schema.get("binding", 0))
	return owner.make_storage_uniform(binding, buffer)


## 与方案接口骨架一致：返回单元素数组（本承载占一个 binding）。
func make_uniforms(owner, binding_override: int = -1) -> Array[RDUniform]:
	var out: Array[RDUniform] = []
	out.append(make_uniform(owner, binding_override))
	return out


## 按需 readback（贵的是 submit_and_sync + buffer_get_data，默认不读；调用方决定何时读）。
## byte_data 为空时从 self.buffer 拉取。返回带名、稳定键序的解码 dict：
##   stat_slots  → {kind, name, word_count, words, values{name:raw_int}, magic_ok}
##   channel_field → {kind, name, index_space, channel_count, channel_names, element_count, data}
func readback(owner, byte_data: PackedByteArray = PackedByteArray()) -> Dictionary:
	var bytes := byte_data
	if bytes.is_empty() and buffer.is_valid():
		bytes = owner.read_buffer_bytes(buffer, 0, byte_count())
	if kind() == KIND_CHANNEL_FIELD:
		return _readback_channel_field(bytes)
	return _readback_stat_slots(bytes)


func _readback_stat_slots(bytes: PackedByteArray) -> Dictionary:
	var total := word_count()
	var available_bytes := mini(bytes.size(), total * 4)
	available_bytes -= available_bytes % 4
	var available_words := int(available_bytes / 4)
	var words := PackedInt32Array()
	words.resize(total)
	for i in range(available_words):
		words[i] = bytes.decode_s32(i * 4)
	var values := {}
	for slot in schema.get("slots", []):
		var idx := int(slot.get("index", -1))
		if idx >= 0 and idx < total:
			values[str(slot.get("name", ""))] = words[idx]
	var magic_ok := true
	if schema.has("magic"):
		magic_ok = int(words[int(schema.get("magic_word", 0))]) == int(schema["magic"])
	return {
		"kind": KIND_STAT_SLOTS,
		"name": str(schema.get("name", "")),
		"word_count": total,
		"words": words,
		"values": values,
		"magic_ok": magic_ok,
	}


func _readback_channel_field(bytes: PackedByteArray) -> Dictionary:
	var chans := channel_count()
	var value_count := 0
	if _element_count > 0:
		value_count = _element_count * chans
	else:
		value_count = int(bytes.size() / 4)
	return {
		"kind": KIND_CHANNEL_FIELD,
		"name": str(schema.get("name", "")),
		"index_space": str(schema.get("index_space", "")),
		"channel_count": chans,
		"channel_names": channel_names(),
		"element_count": _element_count,
		"data": BufferUtils.decode_float_buffer(bytes, value_count),
	}


# ── q1000 定点解码（与 shader q1000() 对称：word / 1000）。稳定键序的 golden 快照素材。──

## 把 stat_slots 的原始 words 按每槽 decode 变换成 shaped 视图 {slot_name: 值}。
## decode 变换取自 slot.decode（默认 int）；调用方据此免去手写「哪个槽 /1000、哪个转 bool」。
func decode_shaped(words: PackedInt32Array) -> Dictionary:
	var out := {}
	var total := words.size()
	for slot in schema.get("slots", []):
		var idx := int(slot.get("index", -1))
		if idx < 0 or idx >= total:
			continue
		var raw := int(words[idx])
		match str(slot.get("decode", DECODE_INT)):
			DECODE_BOOL:
				out[str(slot.get("name", ""))] = raw != 0
			DECODE_Q1000:
				out[str(slot.get("name", ""))] = float(raw) / 1000.0
			_:
				out[str(slot.get("name", ""))] = raw
	return out


# ── golden-master 素材：带名、q1000 反量化、稳定键序的确定性文本快照 ──
#
# 方案一「与 golden-master 协同」：统一解码产出的 dict 即 golden 快照素材——桥跑固定 demo →
# readback() → 存 goldens/*.approved.txt → 大扫前后 diff。承载统一后这条链只需一个方法。
# stat_slots 用 decode_shaped（q1000 反量化）；两种形态均按 schema 声明顺序（稳定键序）输出。

func golden_snapshot(owner, byte_data: PackedByteArray = PackedByteArray()) -> String:
	var decoded := readback(owner, byte_data)
	var lines: Array[String] = []
	if kind() == KIND_CHANNEL_FIELD:
		lines.append("%s channel_field index_space=%s channels=%d element_count=%d" % [
			str(schema.get("name", "")), str(decoded.get("index_space", "")),
			int(decoded.get("channel_count", 0)), int(decoded.get("element_count", 0))])
		for ch_name in channel_names():
			lines.append("  channel %s" % ch_name)
	else:
		lines.append("%s stat_slots magic_ok=%s word_count=%d" % [
			str(schema.get("name", "")), str(decoded.get("magic_ok", true)), int(decoded.get("word_count", 0))])
		var shaped := decode_shaped(decoded.get("words", PackedInt32Array()))
		for slot in schema.get("slots", []):
			var slot_name := str(slot.get("name", ""))
			if shaped.has(slot_name):
				lines.append("  %s=%s" % [slot_name, str(shaped[slot_name])])
	return "\n".join(lines)


# ── codegen：从 schema 生成 GLSL 声明块 ──
#
# section 让一份 schema 喂两个分离的 @@GEN 区（shader 里 binding 声明扎堆、常量扎堆，各在一处）：
#   "decl"   —— 仅 layout buffer 声明块
#   "consts" —— 仅 magic + 逐槽/逐通道常量
#   "all"    —— 声明 + 常量（pilot 用，binding 处无既有独立常量段时最省）

const SECTION_ALL := "all"
const SECTION_DECL := "decl"
const SECTION_CONSTS := "consts"


## marker 名（`// @@GEN <marker> … // @@END <marker>`）。section 非 all 时带后缀。
static func marker_name(schema_dict: Dictionary, section: String = SECTION_ALL) -> String:
	var base := "debug_set " + str(schema_dict.get("name", "unnamed"))
	return base if section == SECTION_ALL else "%s %s" % [base, section]


## 生成完整 @@GEN 块（含 marker 行），可直接粘进 shader。set/binding 用 overrides 覆盖
## （同一 schema 被多 shader 以不同 set/binding 承载时，见 CONSUMERS）。
static func emit_glsl_block(schema_dict: Dictionary, overrides: Dictionary = {}, section: String = SECTION_ALL) -> String:
	var marker := marker_name(schema_dict, section)
	var body := emit_glsl_body(schema_dict, overrides, section)
	return "// @@GEN %s\n%s\n// @@END %s" % [marker, body, marker]


## 仅生成块正文（不含 marker 行）——desync guard 比对的就是这段。
static func emit_glsl_body(schema_dict: Dictionary, overrides: Dictionary = {}, section: String = SECTION_ALL) -> String:
	if str(schema_dict.get("kind", KIND_STAT_SLOTS)) == KIND_CHANNEL_FIELD:
		return _emit_channel_field_body(schema_dict, overrides, section)
	return _emit_stat_slots_body(schema_dict, overrides, section)


static func _emit_stat_slots_body(schema_dict: Dictionary, overrides: Dictionary, section: String) -> String:
	var set_index := int(overrides.get("set", schema_dict.get("set", 0)))
	var binding := int(overrides.get("binding", schema_dict.get("binding", 0)))
	var glsl_struct := str(schema_dict.get("glsl_struct", "DebugStats"))
	var glsl_array := str(schema_dict.get("glsl_array", "debug_stats"))
	var decl_lines: Array[String] = [
		"layout(set = %d, binding = %d, std430) restrict buffer %s {" % [set_index, binding, glsl_struct],
		"    uint %s[];" % glsl_array,
		"};",
	]
	var const_lines: Array[String] = []
	if schema_dict.has("magic"):
		var magic_const := str(schema_dict.get("magic_const", glsl_array.to_upper() + "_MAGIC"))
		const_lines.append("const uint %s = 0x%08Xu;" % [magic_const, int(schema_dict["magic"])])
	for slot in schema_dict.get("slots", []):
		if slot.has("glsl"):
			const_lines.append("const uint %s = %du;" % [str(slot["glsl"]), int(slot.get("index", 0))])
	return _join_sections(decl_lines, const_lines, section)


static func _emit_channel_field_body(schema_dict: Dictionary, overrides: Dictionary, section: String) -> String:
	var set_index := int(overrides.get("set", schema_dict.get("set", 0)))
	var binding := int(overrides.get("binding", schema_dict.get("binding", 0)))
	var glsl_struct := str(schema_dict.get("glsl_struct", "DebugField"))
	var glsl_array := str(schema_dict.get("glsl_array", "debug_field"))
	var channels: Array = schema_dict.get("channels", [])
	var decl_lines: Array[String] = [
		"layout(set = %d, binding = %d, std430) restrict buffer %s {" % [set_index, binding, glsl_struct],
		"    float %s[];  // %d channels/element, index space: %s" % [glsl_array, channels.size(), str(schema_dict.get("index_space", "?"))],
		"};",
	]
	var const_lines: Array[String] = []
	if schema_dict.has("channel_count_const"):
		const_lines.append("const uint %s = %du;" % [str(schema_dict["channel_count_const"]), channels.size()])
	for i in range(channels.size()):
		var ch: Dictionary = channels[i]
		if ch.has("glsl"):
			const_lines.append("const uint %s = %du;" % [str(ch["glsl"]), i])
	return _join_sections(decl_lines, const_lines, section)


static func _join_sections(decl_lines: Array[String], const_lines: Array[String], section: String) -> String:
	match section:
		SECTION_DECL:
			return "\n".join(decl_lines)
		SECTION_CONSTS:
			return "\n".join(const_lines)
		_:
			return "\n".join(decl_lines + const_lines)
