@tool
class_name ProfileArenaLayout
extends RefCounted
## 固定槽位 Profile 单一 Arena Buffer 的布局单一真值源（固定槽位Profile共享Buffer实施计划 §3）。
##
## 全部 Profile 数据（Header / Samples / Pivots）住在一个 GPU
## storage buffer 里，每个 slot 定长、连续、完整。CPU 打包、GPU 分配、局部更新偏移、
## GLSL 常量与访问器、Debug 解码、内存预算报告全部从这里取数，Host 与 Shader 都
## **不得**自行复制这些数字（§3 末段）。
##
## ══ slot 寻址索引 = profile_index，不是 profile_id ═══════════════════════════
## 计划正文写的是 `profile_base = profile_id × SLOT_STRIDE`，前提是 profile_id 稠密。
## 本工程的 profile_id 由 AutoVoxelRuntimeProfileContainer._profile_id_from_hash()
## 从 profile_hash 派生（u31 hash + 线性探测），值域是整个 u31，**不能**当地址用。
## 稠密下标是同一容器里的 `profile_index`（= 注册顺序 _profile_order.size()），也正是
## score/stamp shader 现在索引 runtime_profile_table 用的那个下标。故 Arena 一律以
## `slot_index`（≡ profile_index）寻址，profile_id 仍原样存在 slot header 第 0 个 u32
## 里供校验与调试。计划的地址语义不变，只是把"哪个索引"钉死。
##
## ══ 容量依据（2026-08-04 实测 scenes/asset-overview/baked_descriptors/*.tres）══
##   asset_id                coarse(probe)  fine(voxel)  total
##   geo_sm_ground_grass                 1          112     113
##   geo_sm_testleaf_test2               9          458     467
##   geo_cliff_01                       25         3460    3485
##   geo_cliff_02                       26        12325   12351   ← 实测最大
##   geo_stone_01                        4          210     214
##   profiles=5  max=12351  avg=2772  合计 16630；pivot 实测最大 1
##   （三变体自动生成已于 2026-08-05 删除；pivot_variants 为空 ⇒ 恒 1 条零偏移 bottom。
##    MAX_PIVOTS_PER_PROFILE 仍保留余量，供作者显式写多条 pivot_variants 的资产用。）
##
## ══ 容量取值是**压力测试上限**，不是按当前资产量调优的生产值 ═══════════════════
## 下面三个常量刻意取到远高于实测需求的水位，用来给固定槽位方案本身加压：验证 32 MiB
## 量级的单 Buffer 分配/上传、满容量寻址、编译期容量守卫、单槽局部更新在极限尺寸下都
## 成立。因此 **98.4% 的浪费率是预期结果，不是待修的调优疏漏**——当前 5 个资产的有效
## 字节只占 Arena 的 ~1.6%，正是"槽位远大于实际内容"这个被测场景的定义。
##
## 该代价始终可测量（budget_report() / Inspector 的 Arena 状态面板），三个常量就是唯一
## 调节旋钮：压力测试结论确认后想换成生产水位，只改这里，收紧 PROFILE_CAPACITY 直接
## 线性省显存，布局偏移与 GLSL 常量全部自动重新推导，无需改动任何调用点或 shader 逻辑。

const ProfileRecordSchemaScript := preload("res://scripts/utils/profile_record_schema.gd")

# ══ 固定容量（§4）—— 压力测试水位，见类首「容量取值是压力测试上限」════════════
const PROFILE_CAPACITY := 64            # slot 数上限；实测需 5，取 12.8× 压测冗余
const MAX_SAMPLES_PER_PROFILE := 16384  # 每 slot 样本上限；实测最大 12806，2^14 便于对齐寻址
const MAX_PIVOTS_PER_PROFILE := 8       # 每 slot pivot 上限；实测最大 3

# ══ 记录步长（转发 ProfileRecordSchema，不另立数字）═════════════════════════════
# slot header 直接复用 profile_table 记录（同 64B 同字段），Phase A 因此不动 shader 解码语义。
const PROFILE_HEADER_STRIDE_BYTES := ProfileRecordSchemaScript.PROFILE_TABLE_STRIDE_BYTES
const PROFILE_SAMPLE_STRIDE_BYTES := ProfileRecordSchemaScript.PROFILE_SAMPLE_RECORD_STRIDE_BYTES
const PROFILE_PIVOT_STRIDE_BYTES := ProfileRecordSchemaScript.PIVOT_RECORD_STRIDE_BYTES
const PROFILE_MESH_STRIDE_BYTES := 128  # = ScenePlacementRuntime.MESH_DESCRIPTION_STRIDE_BYTES

const ALIGNMENT_BYTES := 16             # 所有区域至少 16B 对齐（§2 末段）

# ══ 全局 Arena Header（§10）════════════════════════════════════════════════════
# magic / layout_version / slot_stride / loaded_profile_count / arena_byte_count
# + 三个容量常量，恰好铺满 32B。Slot 区从对齐后的 PROFILE_SLOTS_OFFSET_BYTES 起算。
const ARENA_MAGIC := 0x50524146          # 'PRAF' — Profile aRena Arena Format
const ARENA_LAYOUT_VERSION := 1
const ARENA_HEADER_STRIDE_BYTES := 32

const ARENA_HEADER_LAYOUT := {
	"title": "profile arena global header (GLSL: read through profile_arena_header_word)",
	"stride_bytes": ARENA_HEADER_STRIDE_BYTES,
	"fields": [
		{"offset": 0, "encode": "u32", "name": "magic"},
		{"offset": 4, "encode": "u32", "name": "layout_version"},
		{"offset": 8, "encode": "u32", "name": "slot_stride_bytes"},
		{"offset": 12, "encode": "u32", "name": "loaded_profile_count"},
		{"offset": 16, "encode": "u32", "name": "arena_byte_count"},
		{"offset": 20, "encode": "u32", "name": "profile_capacity"},
		{"offset": 24, "encode": "u32", "name": "max_samples_per_profile"},
		{"offset": 28, "encode": "u32", "name": "max_pivots_per_profile"},
	],
}

# ══ 派生偏移（§2）══════════════════════════════════════════════════════════════
# 全部由上面的容量/步长按 align16 推导，没有一个手写魔数；verify_layout() 用独立的
# align16() 重算一遍并比对，防止有人把某个 const 就地改成字面量。
const PROFILE_SLOTS_OFFSET_BYTES := (ARENA_HEADER_STRIDE_BYTES + ALIGNMENT_BYTES - 1) & ~(ALIGNMENT_BYTES - 1)

const PROFILE_HEADER_OFFSET_BYTES := 0
const PROFILE_SAMPLE_OFFSET_BYTES := (
	PROFILE_HEADER_OFFSET_BYTES + PROFILE_HEADER_STRIDE_BYTES + ALIGNMENT_BYTES - 1
) & ~(ALIGNMENT_BYTES - 1)
const PROFILE_PIVOT_OFFSET_BYTES := (
	PROFILE_SAMPLE_OFFSET_BYTES + MAX_SAMPLES_PER_PROFILE * PROFILE_SAMPLE_STRIDE_BYTES
	+ ALIGNMENT_BYTES - 1
) & ~(ALIGNMENT_BYTES - 1)
const PROFILE_MESH_OFFSET_BYTES := (
	PROFILE_PIVOT_OFFSET_BYTES + MAX_PIVOTS_PER_PROFILE * PROFILE_PIVOT_STRIDE_BYTES
	+ ALIGNMENT_BYTES - 1
) & ~(ALIGNMENT_BYTES - 1)
const PROFILE_SLOT_STRIDE_BYTES := (
	PROFILE_MESH_OFFSET_BYTES + PROFILE_MESH_STRIDE_BYTES + ALIGNMENT_BYTES - 1
) & ~(ALIGNMENT_BYTES - 1)

const ARENA_BYTE_COUNT := PROFILE_SLOTS_OFFSET_BYTES + PROFILE_CAPACITY * PROFILE_SLOT_STRIDE_BYTES
const ARENA_WORD_COUNT := ARENA_BYTE_COUNT / 4


## 向上对齐到 ALIGNMENT_BYTES（verify_layout 用它独立复算派生偏移）。
static func align16(value: int) -> int:
	return (value + ALIGNMENT_BYTES - 1) & ~(ALIGNMENT_BYTES - 1)


## slot 起始字节地址（slot_index ≡ profile_index，见类首寻址说明）。
static func slot_base_bytes(slot_index: int) -> int:
	return PROFILE_SLOTS_OFFSET_BYTES + slot_index * PROFILE_SLOT_STRIDE_BYTES


static func header_address(slot_index: int) -> int:
	return slot_base_bytes(slot_index) + PROFILE_HEADER_OFFSET_BYTES


static func sample_address(slot_index: int, sample_index: int) -> int:
	return (slot_base_bytes(slot_index) + PROFILE_SAMPLE_OFFSET_BYTES
		+ sample_index * PROFILE_SAMPLE_STRIDE_BYTES)


static func pivot_address(slot_index: int, pivot_index: int) -> int:
	return (slot_base_bytes(slot_index) + PROFILE_PIVOT_OFFSET_BYTES
		+ pivot_index * PROFILE_PIVOT_STRIDE_BYTES)


static func mesh_address(slot_index: int) -> int:
	return slot_base_bytes(slot_index) + PROFILE_MESH_OFFSET_BYTES


## 单 Profile 局部更新的字节范围（§8.3）：整槽覆盖，不做子区间部分写。
static func slot_update_range(slot_index: int) -> Dictionary:
	return {
		"offset_bytes": slot_base_bytes(slot_index),
		"size_bytes": PROFILE_SLOT_STRIDE_BYTES,
	}


## 内存预算报告（§5）：把固定槽位的浪费量做成可查询数字，而不是"心里有数"。
static func budget_report(
	loaded_profile_count: int,
	valid_sample_count: int,
	valid_pivot_count: int
) -> Dictionary:
	# Mesh 区不计入有效字节：它是保留占位、恒为零（mesh 是每资产的、slot 是每 profile
	# 的，基数不同），算进来会把浪费量报小。
	var valid_bytes := (
		loaded_profile_count * PROFILE_HEADER_STRIDE_BYTES
		+ valid_sample_count * PROFILE_SAMPLE_STRIDE_BYTES
		+ valid_pivot_count * PROFILE_PIVOT_STRIDE_BYTES
	)
	var wasted_bytes := ARENA_BYTE_COUNT - valid_bytes
	return {
		"loaded_profile_count": loaded_profile_count,
		"profile_capacity": PROFILE_CAPACITY,
		"arena_byte_count": ARENA_BYTE_COUNT,
		"slot_stride_bytes": PROFILE_SLOT_STRIDE_BYTES,
		"valid_sample_count": valid_sample_count,
		"sample_capacity": PROFILE_CAPACITY * MAX_SAMPLES_PER_PROFILE,
		"max_samples_per_profile": MAX_SAMPLES_PER_PROFILE,
		"valid_pivot_count": valid_pivot_count,
		"pivot_capacity": PROFILE_CAPACITY * MAX_PIVOTS_PER_PROFILE,
		"max_pivots_per_profile": MAX_PIVOTS_PER_PROFILE,
		"valid_bytes": valid_bytes,
		"wasted_bytes": wasted_bytes,
		"wasted_ratio": (float(wasted_bytes) / float(ARENA_BYTE_COUNT)) if ARENA_BYTE_COUNT > 0 else 0.0,
	}


## 自检（§3 末条）：派生偏移与 align16 独立复算一致、各区不重叠、全部 16B 对齐、
## slot 装得下四个区、Arena 字节数是 4 的倍数（uint words[] 视图要求）。
## 返回错误列表（空 = 通过）。
static func verify_layout() -> PackedStringArray:
	var errors := PackedStringArray()

	var regions: Array = [
		["header", PROFILE_HEADER_OFFSET_BYTES, PROFILE_HEADER_STRIDE_BYTES, 1],
		["samples", PROFILE_SAMPLE_OFFSET_BYTES, PROFILE_SAMPLE_STRIDE_BYTES, MAX_SAMPLES_PER_PROFILE],
		["pivots", PROFILE_PIVOT_OFFSET_BYTES, PROFILE_PIVOT_STRIDE_BYTES, MAX_PIVOTS_PER_PROFILE],
		["mesh", PROFILE_MESH_OFFSET_BYTES, PROFILE_MESH_STRIDE_BYTES, 1],
	]

	# 1) 独立复算派生偏移：任何一个 const 被改成手写字面量都会在这里露馅。
	var expected_offset := 0
	for region in regions:
		var region_name: String = region[0]
		var offset: int = region[1]
		if offset != align16(expected_offset):
			errors.append("%s: offset %d, expected align16(%d) = %d" % [
				region_name, offset, expected_offset, align16(expected_offset)])
		expected_offset = offset + int(region[2]) * int(region[3])
	if PROFILE_SLOT_STRIDE_BYTES != align16(expected_offset):
		errors.append("slot_stride: %d, expected align16(%d) = %d" % [
			PROFILE_SLOT_STRIDE_BYTES, expected_offset, align16(expected_offset)])

	# 2) 对齐 + 相邻区不重叠（regions 已按偏移升序声明，逐对比较即可覆盖全部组合）。
	for i in range(regions.size()):
		var region_name: String = regions[i][0]
		var offset: int = regions[i][1]
		if offset % ALIGNMENT_BYTES != 0:
			errors.append("%s: offset %d 未按 %d 字节对齐" % [region_name, offset, ALIGNMENT_BYTES])
		if int(regions[i][2]) % 4 != 0:
			errors.append("%s: stride %d 不是 4 的倍数（uint words[] 视图要求）" % [
				region_name, int(regions[i][2])])
		var region_end: int = offset + int(regions[i][2]) * int(regions[i][3])
		if region_end > PROFILE_SLOT_STRIDE_BYTES:
			errors.append("%s: 区末 %d 越过 slot stride %d" % [
				region_name, region_end, PROFILE_SLOT_STRIDE_BYTES])
		if i + 1 < regions.size() and region_end > int(regions[i + 1][1]):
			errors.append("%s 与 %s 重叠（%s 区末 %d > %s 起点 %d）" % [
				region_name, regions[i + 1][0], region_name, region_end,
				regions[i + 1][0], int(regions[i + 1][1])])

	# 3) 全局 header 与 slot 区。
	if PROFILE_SLOTS_OFFSET_BYTES < ARENA_HEADER_STRIDE_BYTES:
		errors.append("slots_offset %d 压在 arena header（%d 字节）上" % [
			PROFILE_SLOTS_OFFSET_BYTES, ARENA_HEADER_STRIDE_BYTES])
	if PROFILE_SLOTS_OFFSET_BYTES % ALIGNMENT_BYTES != 0:
		errors.append("slots_offset %d 未按 %d 字节对齐" % [PROFILE_SLOTS_OFFSET_BYTES, ALIGNMENT_BYTES])
	var header_expected := 0
	for field in ARENA_HEADER_LAYOUT["fields"]:
		if int(field["offset"]) != header_expected:
			errors.append("arena_header.%s: offset %d, expected %d" % [
				String(field["name"]), int(field["offset"]), header_expected])
		header_expected = int(field["offset"]) + 4
	if header_expected != ARENA_HEADER_STRIDE_BYTES:
		errors.append("arena_header: 字段止于 %d B，stride 为 %d B" % [
			header_expected, ARENA_HEADER_STRIDE_BYTES])

	# 4) Arena 总量。
	if ARENA_BYTE_COUNT % 4 != 0:
		errors.append("arena_byte_count %d 不是 4 的倍数" % ARENA_BYTE_COUNT)
	if PROFILE_CAPACITY <= 0 or MAX_SAMPLES_PER_PROFILE <= 0 or MAX_PIVOTS_PER_PROFILE <= 0:
		errors.append("容量常量必须为正（capacity=%d samples=%d pivots=%d）" % [
			PROFILE_CAPACITY, MAX_SAMPLES_PER_PROFILE, MAX_PIVOTS_PER_PROFILE])

	# 5) 与 ProfileRecordSchema 的步长必须同源（转发常量被就地改写时露馅）。
	if PROFILE_HEADER_STRIDE_BYTES != ProfileRecordSchemaScript.PROFILE_TABLE_STRIDE_BYTES:
		errors.append("header stride 与 ProfileRecordSchema.PROFILE_TABLE_STRIDE_BYTES 不一致")
	if PROFILE_SAMPLE_STRIDE_BYTES != ProfileRecordSchemaScript.PROFILE_SAMPLE_RECORD_STRIDE_BYTES:
		errors.append("sample stride 与 ProfileRecordSchema.PROFILE_SAMPLE_RECORD_STRIDE_BYTES 不一致")
	if PROFILE_PIVOT_STRIDE_BYTES != ProfileRecordSchemaScript.PIVOT_RECORD_STRIDE_BYTES:
		errors.append("pivot stride 与 ProfileRecordSchema.PIVOT_RECORD_STRIDE_BYTES 不一致")

	return errors


# ══ GLSL 代码生成（§3 / §9）════════════════════════════════════════════════════
# 消费 shader 用 `// @@GEN profile_arena_layout <block> ... // @@END` 锚块承载下面的
# 发射文本；scripts/checks/glsl_gen_block_checks.gd 按 CONSUMERS 校验锚块与发射文本一致。
# 与 ProfileRecordSchema / PlacementSharedGLSL 同形（block_names() + block() + CONSUMERS）。
#
# 绑定声明本身仍由各 shader 手写（set/binding 逐 shader 不同），但**实例名必须是
# `profile_arena`、成员必须是 `words`**，否则下面的访问器编译不过：
#     layout(set = S, binding = B, std430) restrict readonly buffer ProfileArena {
#         uint words[];
#     } profile_arena;

#
# 锚块按**依赖的 struct** 拆开，因为各 shader 声明的记录结构体并不相同
# （probes 只有 ProfileSampleRecord，results_to_world 只有 RuntimePivotRecord）：
#   constants       — 纯常量，无依赖
#   accessors       — 字级访问器，无依赖
#   sample_accessor — 需 ProfileSampleRecord
#   table_accessor  — 需 RuntimeProfileTableRecord
#   pivot_accessor  — 需 RuntimePivotRecord
# 记录级访问器一律**返回与迁移前同形的结构体**，因此下游解码代码一行不用改。
const CONSUMERS := {
	"profile_arena_layout constants": [
		"res://shaders/score_anchor_asset_probes.glsl",
		"res://shaders/score_anchor_asset_residual.glsl",
		"res://shaders/stamp_asset_voxels.glsl",
		"res://shaders/placement_results_to_world.glsl",
	],
	"profile_arena_layout accessors": [
		"res://shaders/score_anchor_asset_probes.glsl",
		"res://shaders/score_anchor_asset_residual.glsl",
		"res://shaders/stamp_asset_voxels.glsl",
		"res://shaders/placement_results_to_world.glsl",
	],
	"profile_arena_layout sample_accessor": [
		"res://shaders/score_anchor_asset_probes.glsl",
		"res://shaders/score_anchor_asset_residual.glsl",
		"res://shaders/stamp_asset_voxels.glsl",
	],
	"profile_arena_layout table_accessor": [
		"res://shaders/score_anchor_asset_residual.glsl",
		"res://shaders/stamp_asset_voxels.glsl",
	],
	"profile_arena_layout pivot_accessor": [
		"res://shaders/score_anchor_asset_residual.glsl",
		"res://shaders/stamp_asset_voxels.glsl",
		"res://shaders/placement_results_to_world.glsl",
	],
}


static func block_names() -> Array:
	return CONSUMERS.keys()


static func block(name: String) -> String:
	var key := name.trim_prefix("profile_arena_layout ").strip_edges()
	match key:
		"constants":
			return glsl_constants_block().strip_edges()
		"accessors":
			return glsl_accessors_block().strip_edges()
		"sample_accessor":
			return glsl_profile_sample_accessor_block().strip_edges()
		"table_accessor":
			return glsl_profile_table_accessor_block().strip_edges()
		"pivot_accessor":
			return glsl_pivot_accessor_block().strip_edges()
		_:
			push_error("ProfileArenaLayout.block: 未知锚块名 '%s'（已知: %s）" % [
				name, str(["constants", "accessors", "sample_accessor", "table_accessor", "pivot_accessor"])])
			assert(false, "ProfileArenaLayout.block: unknown block name")
			return ""


## 发射 GLSL 常量：Shader 不得自行复制这些数字（§3 末段）。
static func glsl_constants_block() -> String:
	var lines: Array[String] = [
		"// SSOT: ProfileArenaLayout — 由 glsl_constants_block() 发射，勿手改。",
		"// slot 寻址索引 = profile_index（稠密），不是 hash 派生的 profile_id。",
		"const uint PROFILE_ARENA_MAGIC = %du;" % ARENA_MAGIC,
		"const uint PROFILE_ARENA_LAYOUT_VERSION = %du;" % ARENA_LAYOUT_VERSION,
		"const uint PROFILE_CAPACITY = %du;" % PROFILE_CAPACITY,
		"const uint MAX_SAMPLES_PER_PROFILE = %du;" % MAX_SAMPLES_PER_PROFILE,
		"const uint MAX_PIVOTS_PER_PROFILE = %du;" % MAX_PIVOTS_PER_PROFILE,
		"const uint PROFILE_HEADER_STRIDE_BYTES = %du;" % PROFILE_HEADER_STRIDE_BYTES,
		"const uint PROFILE_SAMPLE_STRIDE_BYTES = %du;" % PROFILE_SAMPLE_STRIDE_BYTES,
		"const uint PROFILE_PIVOT_STRIDE_BYTES = %du;" % PROFILE_PIVOT_STRIDE_BYTES,
		"const uint PROFILE_MESH_STRIDE_BYTES = %du;" % PROFILE_MESH_STRIDE_BYTES,
		"const uint PROFILE_ARENA_HEADER_STRIDE_BYTES = %du;" % ARENA_HEADER_STRIDE_BYTES,
		"const uint PROFILE_SLOTS_OFFSET_BYTES = %du;" % PROFILE_SLOTS_OFFSET_BYTES,
		"const uint PROFILE_HEADER_OFFSET_BYTES = %du;" % PROFILE_HEADER_OFFSET_BYTES,
		"const uint PROFILE_SAMPLE_OFFSET_BYTES = %du;" % PROFILE_SAMPLE_OFFSET_BYTES,
		"const uint PROFILE_PIVOT_OFFSET_BYTES = %du;" % PROFILE_PIVOT_OFFSET_BYTES,
		"const uint PROFILE_MESH_OFFSET_BYTES = %du;" % PROFILE_MESH_OFFSET_BYTES,
		"const uint PROFILE_SLOT_STRIDE_BYTES = %du;" % PROFILE_SLOT_STRIDE_BYTES,
		"const uint PROFILE_ARENA_BYTE_COUNT = %du;" % ARENA_BYTE_COUNT,
		"const uint PROFILE_ARENA_WORD_COUNT = %du;" % ARENA_WORD_COUNT,
	]
	return "\n".join(lines)


## 发射 GLSL 访问器（§9）。容量守卫（§10）全部用编译期常量：Arena 是定长的，
## 所以越界判定不需要 host 传 capacity —— 这正是固定槽位换来的好处之一。
## 越界一律返回 0（= 零初始化槽位的读值），不会读到别的 slot 的数据。
static func glsl_accessors_block() -> String:
	var lines: Array[String] = [
		"// SSOT: ProfileArenaLayout — 由 glsl_accessors_block() 发射，勿手改。",
		"// 依赖：绑定实例名 `profile_arena`，成员 `uint words[]`。",
		"",
		"uint profile_arena_word_at(uint byte_offset) {",
		"    uint word_index = byte_offset >> 2u;",
		"    if (word_index >= PROFILE_ARENA_WORD_COUNT) return 0u;",
		"    return profile_arena.words[word_index];",
		"}",
		"",
		"uint profile_slot_base_bytes(uint slot_index) {",
		"    if (slot_index >= PROFILE_CAPACITY) return PROFILE_ARENA_BYTE_COUNT;",
		"    return PROFILE_SLOTS_OFFSET_BYTES + slot_index * PROFILE_SLOT_STRIDE_BYTES;",
		"}",
		"",
		"uint profile_word(uint slot_index, uint local_byte_offset) {",
		"    return profile_arena_word_at(profile_slot_base_bytes(slot_index) + local_byte_offset);",
		"}",
		"",
		"float profile_float(uint slot_index, uint local_byte_offset) {",
		"    return uintBitsToFloat(profile_word(slot_index, local_byte_offset));",
		"}",
		"",
		"uint profile_arena_header_word(uint field_byte_offset) {",
		"    return profile_arena_word_at(field_byte_offset);",
		"}",
		"",
		"uint profile_header_word(uint slot_index, uint field_byte_offset) {",
		"    return profile_word(slot_index, PROFILE_HEADER_OFFSET_BYTES + field_byte_offset);",
		"}",
		"",
		"uint profile_sample_word(uint slot_index, uint sample_index, uint field_byte_offset) {",
		"    if (sample_index >= MAX_SAMPLES_PER_PROFILE) return 0u;",
		"    return profile_word(slot_index,",
		"        PROFILE_SAMPLE_OFFSET_BYTES + sample_index * PROFILE_SAMPLE_STRIDE_BYTES + field_byte_offset);",
		"}",
		"",
		"uint profile_pivot_word(uint slot_index, uint pivot_index, uint field_byte_offset) {",
		"    if (pivot_index >= MAX_PIVOTS_PER_PROFILE) return 0u;",
		"    return profile_word(slot_index,",
		"        PROFILE_PIVOT_OFFSET_BYTES + pivot_index * PROFILE_PIVOT_STRIDE_BYTES + field_byte_offset);",
		"}",
		"",
		"uint profile_mesh_word(uint slot_index, uint field_byte_offset) {",
		"    return profile_word(slot_index, PROFILE_MESH_OFFSET_BYTES + field_byte_offset);",
		"}",
	]
	return "\n".join(lines)


## 记录级访问器共同的前言（说明字段偏移的出处）。
static func _record_accessor_preamble(record_name: String) -> Array[String]:
	return [
		"// SSOT: ProfileArenaLayout — 由 glsl_%s_accessor_block() 发射，勿手改。" % record_name,
		"// 字段偏移取自 ProfileRecordSchema.RECORD_LAYOUTS[\"%s\"]（见本文件的" % record_name,
		"// `@@GEN profile_record_layout %s` 锚块）。返回的结构体与迁移前同形，" % record_name,
		"// 下游解码代码不受影响。",
	]


## ProfileSampleRecord 读取器（需 shader 已声明该 struct）。
static func glsl_profile_sample_accessor_block() -> String:
	var lines: Array[String] = _record_accessor_preamble("profile_sample")
	lines.append_array([
		"ProfileSampleRecord profile_arena_sample(uint slot_index, uint sample_index) {",
		"    ProfileSampleRecord record;",
		"    record.offset_weight = vec4(",
		"        uintBitsToFloat(profile_sample_word(slot_index, sample_index, 0u)),",
		"        uintBitsToFloat(profile_sample_word(slot_index, sample_index, 4u)),",
		"        uintBitsToFloat(profile_sample_word(slot_index, sample_index, 8u)),",
		"        uintBitsToFloat(profile_sample_word(slot_index, sample_index, 12u)));",
		"    record.payload = uvec4(",
		"        profile_sample_word(slot_index, sample_index, 16u),",
		"        profile_sample_word(slot_index, sample_index, 20u),",
		"        profile_sample_word(slot_index, sample_index, 24u),",
		"        profile_sample_word(slot_index, sample_index, 28u));",
		"    return record;",
		"}",
	])
	return "\n".join(lines)


## RuntimeProfileTableRecord（= slot header）读取器（需 shader 已声明该 struct）。
## ⚠ 取回的 ranges 是**槽内局部**下标：coarse 从 0 起、fine 紧随其后、pivot 从 0 起。
static func glsl_profile_table_accessor_block() -> String:
	var lines: Array[String] = _record_accessor_preamble("profile_table")
	lines.append_array([
		"// ⚠ ids.zw / ranges.xy / ranges.zw 是**槽内局部**下标（迁移前是全局累计下标）：",
		"//   coarse 恒从 0 起，fine 紧随 coarse，pivot 恒从 0 起。",
		"RuntimeProfileTableRecord profile_arena_table_record(uint slot_index) {",
		"    RuntimeProfileTableRecord record;",
		"    record.ids = uvec4(",
		"        profile_header_word(slot_index, 0u),",
		"        profile_header_word(slot_index, 4u),",
		"        profile_header_word(slot_index, 8u),",
		"        profile_header_word(slot_index, 12u));",
		"    record.ranges = uvec4(",
		"        profile_header_word(slot_index, 16u),",
		"        profile_header_word(slot_index, 20u),",
		"        profile_header_word(slot_index, 24u),",
		"        profile_header_word(slot_index, 28u));",
		"    record.color_complexity = vec4(",
		"        uintBitsToFloat(profile_header_word(slot_index, 32u)),",
		"        uintBitsToFloat(profile_header_word(slot_index, 36u)),",
		"        uintBitsToFloat(profile_header_word(slot_index, 40u)),",
		"        uintBitsToFloat(profile_header_word(slot_index, 44u)));",
		"    record.density_radius_hash_pad = vec4(",
		"        uintBitsToFloat(profile_header_word(slot_index, 48u)),",
		"        uintBitsToFloat(profile_header_word(slot_index, 52u)),",
		"        uintBitsToFloat(profile_header_word(slot_index, 56u)),",
		"        uintBitsToFloat(profile_header_word(slot_index, 60u)));",
		"    return record;",
		"}",
	])
	return "\n".join(lines)


## RuntimePivotRecord 读取器（需 shader 已声明该 struct）。
## pivot_index 是**槽内局部**下标，不再是跨 profile 的全局累计下标。
static func glsl_pivot_accessor_block() -> String:
	var lines: Array[String] = _record_accessor_preamble("pivot")
	lines.append_array([
		"RuntimePivotRecord profile_arena_pivot(uint slot_index, uint pivot_index) {",
		"    RuntimePivotRecord record;",
		"    record.offset_bias = vec4(",
		"        uintBitsToFloat(profile_pivot_word(slot_index, pivot_index, 0u)),",
		"        uintBitsToFloat(profile_pivot_word(slot_index, pivot_index, 4u)),",
		"        uintBitsToFloat(profile_pivot_word(slot_index, pivot_index, 8u)),",
		"        uintBitsToFloat(profile_pivot_word(slot_index, pivot_index, 12u)));",
		"    record.ids_pad = uvec4(",
		"        profile_pivot_word(slot_index, pivot_index, 16u),",
		"        profile_pivot_word(slot_index, pivot_index, 20u),",
		"        profile_pivot_word(slot_index, pivot_index, 24u),",
		"        profile_pivot_word(slot_index, pivot_index, 28u));",
		"    return record;",
		"}",
	])
	return "\n".join(lines)
