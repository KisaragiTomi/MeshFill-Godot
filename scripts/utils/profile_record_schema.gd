@tool
class_name ProfileRecordSchema
extends RefCounted
## ProfileSample CPU contract and GPU ABI single source of truth.

const BufferUtils := preload("res://scripts/utils/buffer_utils.gd")
const VariantUtils := preload("res://scripts/utils/variant_utils.gd")

# ══ 局部体素坐标（审计发现 2：voxel/local_pos/voxel_offset 三名并存）══
# canonical 键 `voxel` 在先；legacy 别名只在读入口兜底一次，内部构造一律只写 canonical。
# 语义拆分：`voxel` = Vector3i 网格坐标（collision sample / asset voxel 域）；
# `local_pos` = Vector3 网格中心（baker interior sample / probe 候选域）。
const LOCAL_POSITION_KEYS: Array[String] = ["voxel", "local_pos", "voxel_offset"]

# ══ collision 标量（审计发现 1：跨域缺省三向分叉，收敛为两域两缺省）══
const COLLISION_STRENGTH_KEY := "collision_strength"  # descriptor 域 canonical 强度键
const LEGACY_COLLISION_KEY := "collision"             # voxelizer 结果域约定键；descriptor 域仅作 legacy 兜底
const DEFAULT_COLLISION_STRENGTH := 1.0               # descriptor 域缺省 = 满碰撞
const VOXELIZER_ABSENT_COLLISION := 0.0               # voxelizer 结果域缺省 = 无碰撞（占用判定）

# ══ probe record（审计发现 4：expected_collision 的 legacy 别名）══
const PROBE_EXPECTED_COLLISION_KEY := "expected_collision"
const DEFAULT_PROBE_EXPECTED_COLLISION := 0.0

const DEFAULT_SAMPLE_WEIGHT := 1.0

const SAMPLE_FLAG_COARSE := 1 << 0
const SAMPLE_FLAG_FINE := 1 << 1
const SAMPLE_FLAG_CLEARANCE := 1 << 2
const SAMPLE_FLAG_STAMP_WRITE := 1 << 3
const SAMPLE_FLAG_SCORE_ONLY := 1 << 4
const SAMPLE_FLAG_STAGE_MASK := SAMPLE_FLAG_COARSE | SAMPLE_FLAG_FINE
const SAMPLE_FLAG_KNOWN_MASK := (
	SAMPLE_FLAG_STAGE_MASK
	| SAMPLE_FLAG_CLEARANCE
	| SAMPLE_FLAG_STAMP_WRITE
	| SAMPLE_FLAG_SCORE_ONLY
)

# legacy asset_voxel 旧 flags 的 clearance 位（历史约定值 2；与新格式 SAMPLE_FLAG_CLEARANCE = 1 << 2 = 4 编码不同，勿混用）
const LEGACY_CLEARANCE_FLAG := 2


## 按 LOCAL_POSITION_KEYS 顺序返回局部坐标原始值（Vector3i 或 Vector3），全部缺失返回 default_value。
static func local_position_value(entry: Dictionary, default_value = null) -> Variant:
	for key in LOCAL_POSITION_KEYS:
		if entry.has(key):
			return entry[key]
	return default_value


## 是否含任一局部坐标键（点采样类型判定）。
static func has_local_position(entry: Dictionary) -> bool:
	for key in LOCAL_POSITION_KEYS:
		if entry.has(key):
			return true
	return false


## descriptor 域 collision 强度：canonical collision_strength → legacy collision → absent_default，clamp 0..1。
static func collision_strength(entry: Dictionary, absent_default: float = DEFAULT_COLLISION_STRENGTH) -> float:
	return clampf(float(entry.get(COLLISION_STRENGTH_KEY, entry.get(LEGACY_COLLISION_KEY, absent_default))), 0.0, 1.0)


## voxelizer 结果域 collision 标量（占用判定语义：缺失 = 无碰撞；不 clamp，上游以 >0 判占用）。
static func voxelizer_collision(voxel: Dictionary) -> float:
	return float(voxel.get(LEGACY_COLLISION_KEY, VOXELIZER_ABSENT_COLLISION))


## probe 期望 collision：canonical expected_collision → legacy collision → 0.0，clamp 0..1。
static func probe_expected_collision(probe: Dictionary) -> float:
	return clampf(float(probe.get(PROBE_EXPECTED_COLLISION_KEY, probe.get(LEGACY_COLLISION_KEY, DEFAULT_PROBE_EXPECTED_COLLISION))), 0.0, 1.0)


## canonical collision sample 构造器（原 AutoVoxelProfile.make_collision_sample）。
## 只写 canonical `voxel`——旧的 local_pos 双写补丁随读链统一（LOCAL_POSITION_KEYS）退役。
static func make_collision_sample(
	voxel: Vector3i,
	strength: float = DEFAULT_COLLISION_STRENGTH,
	weight: float = DEFAULT_SAMPLE_WEIGHT
) -> Dictionary:
	return {
		"voxel": voxel,
		COLLISION_STRENGTH_KEY: clampf(strength, 0.0, 1.0),
		"weight": maxf(weight, 0.0),
	}


## baker interior sample 构造器（probe 生成消费）：局部 Vector3 网格中心 + canonical collision_strength。
## voxelizer 域的 `collision` 旧键止步于 baker 边界，不再透传给 probe 生成。
static func make_interior_sample(
	local_pos: Vector3,
	color: Color,
	complexity: float,
	strength: float
) -> Dictionary:
	return {
		"local_pos": local_pos,
		"color": color,
		"complexity": complexity,
		COLLISION_STRENGTH_KEY: strength,
	}


## pivot variant 构造器（name/offset/score_bias 三键）。
static func make_pivot_variant(pivot_name: String, offset: Vector3, score_bias: float = 0.0) -> Dictionary:
	return {"name": pivot_name, "offset": offset, "score_bias": score_bias}


## 缺省 bottom pivot（pivot_variants 为空时的回退记录）。
static func default_bottom_pivot() -> Dictionary:
	return make_pivot_variant("bottom", Vector3.ZERO, 0.0)


## instance config 键表驱动合并（数据契约收紧计划 T1d）。
## spec = {"key": String, "get": Callable, 可选 "allow_null": bool}。
## 仅当 cfg 缺键时求值 getter（保持原 if 链的惰性）；getter 返回 null 且未
## allow_null 时跳过写入（对应原 if 链中 "值无效则不设键" 的条件分支）。
static func merge_instance_config(cfg: Dictionary, specs: Array) -> Dictionary:
	for raw_spec in specs:
		var spec: Dictionary = raw_spec
		var key: String = spec["key"]
		if cfg.has(key):
			continue
		var value = (spec["get"] as Callable).call()
		if value == null and not bool(spec.get("allow_null", false)):
			continue
		cfg[key] = value
	return cfg


## Builds the canonical CPU record used by coarse scoring, fine scoring and stamp.
static func make_profile_sample(
	local_offset_world: Vector3,
	color: Color,
	collision: float,
	flags: int,
	sample_weight: float = DEFAULT_SAMPLE_WEIGHT,
	w_color: float = 1.0,
	w_complexity: float = 1.0,
	w_collision: float = 1.0,
	source_channel: StringName = &"runtime",
	provenance: Dictionary = {}
) -> Dictionary:
	var canonical_color := color
	canonical_color.a = clampf(color.a, 0.0, 1.0)
	return {
		"local_offset_world": local_offset_world,
		"color": canonical_color,
		"complexity": canonical_color.a,
		"collision": clampf(collision, 0.0, 1.0),
		"sample_weight": sample_weight,
		"w_color": w_color,
		"w_complexity": w_complexity,
		"w_collision": w_collision,
		"flags": flags,
		"source_channel": source_channel,
		# 绝大多数样本 provenance 为空（只有 FBX 内嵌通道导入才带溯源元数据）；
		# 空字典的深拷贝等价于新建空字典，直接短路掉 duplicate 遍历。
		# 仍然逐样本新建独立字典，不共享引用——可变性契约不变。
		"provenance": {} if provenance.is_empty() else provenance.duplicate(true),
	}


## Normalizes legacy probe/voxel aliases at one migration boundary.
static func normalize_profile_sample(raw: Dictionary, legacy_voxel_size: Vector3 = Vector3.ONE) -> Dictionary:
	var offset := Vector3.ZERO
	if raw.has("local_offset_world"):
		offset = VariantUtils.vector3_from_value(raw["local_offset_world"], Vector3.ZERO)
	elif raw.has("offset"):
		offset = VariantUtils.vector3_from_value(raw["offset"], Vector3.ZERO)
	elif raw.has("position"):
		offset = VariantUtils.vector3_from_value(raw["position"], Vector3.ZERO)
	elif raw.has("voxel"):
		var voxel := VariantUtils.vector3_from_value(raw["voxel"], Vector3.ZERO)
		offset = voxel * legacy_voxel_size
	var color := VariantUtils.color_from_value(
		raw.get("color", raw.get("expected_color", Color.WHITE)), Color.WHITE)
	var complexity := clampf(float(raw.get(
		"complexity", raw.get("expected_complexity", color.a))), 0.0, 1.0)
	color.a = complexity
	var collision := float(raw.get(
		"collision",
		raw.get("expected_collision", raw.get(COLLISION_STRENGTH_KEY, 0.0))))
	# 单次查表：原写法 `raw.get("provenance", {}) is Dictionary` 三元式要查两次表、
	# 建两个临时空字典；缺键或非字典时结果同样是空字典。
	var raw_provenance = raw.get("provenance", null)
	return make_profile_sample(
		offset,
		color,
		collision,
		int(raw.get("flags", 0)),
		float(raw.get("sample_weight", raw.get("weight", DEFAULT_SAMPLE_WEIGHT))),
		float(raw.get("w_color", 1.0)),
		float(raw.get("w_complexity", 1.0)),
		float(raw.get("w_collision", 1.0)),
		StringName(raw.get("source_channel", raw.get("source", "runtime"))),
		raw_provenance if raw_provenance is Dictionary else {}
	)


static func profile_samples_from_legacy_probes(raw_probes: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for raw_probe in raw_probes:
		if not raw_probe is Dictionary:
			continue
		var source := (raw_probe as Dictionary).duplicate(true)
		source["flags"] = SAMPLE_FLAG_COARSE | SAMPLE_FLAG_SCORE_ONLY
		source["sample_weight"] = DEFAULT_SAMPLE_WEIGHT
		source["source_channel"] = StringName(source.get("source", "legacy_probe"))
		var sample := normalize_profile_sample(source)
		if is_valid_profile_sample(sample):
			result.append(sample)
	return result


static func profile_samples_from_legacy_voxels(
	raw_voxels: Array,
	fallback_collision: Array,
	fallback_color: Color,
	fallback_complexity: float,
	voxel_size: Vector3,
	legacy_clearance_flag: int = LEGACY_CLEARANCE_FLAG
) -> Array[Dictionary]:
	var source := raw_voxels if not raw_voxels.is_empty() else fallback_collision
	var baked: Array[Dictionary] = []
	var top_by_xz := {}
	for raw_entry in source:
		if not raw_entry is Dictionary:
			continue
		var entry := raw_entry as Dictionary
		if not bool(entry.get("enabled", true)):
			continue
		var raw_voxel := VariantUtils.vector3_from_value(
			local_position_value(entry, Vector3.ZERO), Vector3.ZERO)
		var voxel := Vector3i(roundi(raw_voxel.x), roundi(raw_voxel.y), roundi(raw_voxel.z))
		var color := VariantUtils.color_from_value(entry.get("color", fallback_color), fallback_color)
		var complexity := clampf(float(entry.get(
			"complexity", color.a if entry.has("color") else fallback_complexity)), 0.0, 1.0)
		color.a = complexity
		var strength := collision_strength(entry)
		baked.append({
			"voxel": voxel,
			"color": color,
			"complexity": complexity,
			"collision": strength,
			"sample_weight": maxf(float(entry.get("sample_weight", entry.get("weight", 1.0))), 0.0),
			"legacy_flags": int(entry.get("flags", 0)),
		})
		if strength > 0.0:
			var column_key := Vector2i(voxel.x, voxel.z)
			if not top_by_xz.has(column_key) or voxel.y > (top_by_xz[column_key] as Vector3i).y:
				top_by_xz[column_key] = voxel
	for raw_top in top_by_xz.values():
		var top := raw_top as Vector3i
		baked.append({
			"voxel": Vector3i(top.x, top.y + 1, top.z),
			"color": Color(0.0, 0.0, 0.0, 0.0),
			"complexity": 0.0,
			"collision": 0.0,
			"sample_weight": 0.5,
			"legacy_flags": legacy_clearance_flag,
		})
	var by_voxel := {}
	for entry in baked:
		var voxel: Vector3i = entry["voxel"]
		if not by_voxel.has(voxel):
			by_voxel[voxel] = entry
			continue
		var existing := by_voxel[voxel] as Dictionary
		if float(entry["complexity"]) > float(existing["complexity"]):
			existing["color"] = entry["color"]
			existing["complexity"] = entry["complexity"]
		existing["collision"] = maxf(float(existing["collision"]), float(entry["collision"]))
		existing["sample_weight"] = maxf(float(existing["sample_weight"]), float(entry["sample_weight"]))
		existing["legacy_flags"] = int(existing["legacy_flags"]) | int(entry["legacy_flags"])
	var result: Array[Dictionary] = []
	for raw_entry in by_voxel.values():
		var entry := raw_entry as Dictionary
		var is_clearance := (int(entry["legacy_flags"]) & legacy_clearance_flag) != 0
		var flags := SAMPLE_FLAG_FINE
		if is_clearance:
			flags |= SAMPLE_FLAG_CLEARANCE | SAMPLE_FLAG_SCORE_ONLY
		else:
			flags |= SAMPLE_FLAG_STAMP_WRITE
		result.append(make_profile_sample(
			Vector3(entry["voxel"]) * voxel_size,
			entry["color"],
			float(entry["collision"]),
			flags,
			float(entry["sample_weight"]),
			1.0,
			1.0,
			1.0,
			&"legacy_asset_voxel"
		))
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var av: Vector3 = a["local_offset_world"]
		var bv: Vector3 = b["local_offset_world"]
		if not is_equal_approx(av.y, bv.y):
			return av.y < bv.y
		if not is_equal_approx(av.z, bv.z):
			return av.z < bv.z
		return av.x < bv.x)
	return result


## Returns an empty string when a canonical sample is safe to bake.
static func profile_sample_validation_error(sample: Dictionary) -> String:
	var flags := int(sample.get("flags", 0))
	if (flags & SAMPLE_FLAG_STAGE_MASK) == 0:
		return "missing_stage_flag"
	if (flags & ~SAMPLE_FLAG_KNOWN_MASK) != 0:
		return "unknown_flags"
	if (flags & SAMPLE_FLAG_CLEARANCE) != 0 and (flags & SAMPLE_FLAG_STAMP_WRITE) != 0:
		return "clearance_cannot_stamp"
	if (flags & SAMPLE_FLAG_SCORE_ONLY) != 0 and (flags & SAMPLE_FLAG_STAMP_WRITE) != 0:
		return "score_only_cannot_stamp"
	var sample_weight := float(sample.get("sample_weight", DEFAULT_SAMPLE_WEIGHT))
	if not is_finite(sample_weight) or sample_weight < 0.0:
		return "invalid_sample_weight"
	for key in ["w_color", "w_complexity", "w_collision"]:
		var weight := float(sample.get(key, 1.0))
		if not is_finite(weight) or weight < -1.0 or weight > 1.0:
			return "%s_out_of_snorm8_range" % key
	return ""


static func is_valid_profile_sample(sample: Dictionary) -> bool:
	return profile_sample_validation_error(sample).is_empty()


static func pack_snorm8(value: float) -> int:
	return clampi(roundi(value * 127.0), -127, 127) & 0xFF


static func unpack_snorm8(bits: int) -> float:
	var signed_value := bits & 0xFF
	if signed_value >= 128:
		signed_value -= 256
	return clampf(float(signed_value) / 127.0, -1.0, 1.0)


static func pack_profile_sample_metrics(
	collision: float, w_color: float, w_complexity: float, w_collision: float
) -> int:
	return (
		BufferUtils.quantize_unorm8(collision)
		| (pack_snorm8(w_color) << 8)
		| (pack_snorm8(w_complexity) << 16)
		| (pack_snorm8(w_collision) << 24)
	)


static func unpack_profile_sample_metrics(packed: int) -> Vector4:
	return Vector4(
		float(packed & 0xFF) / 255.0,
		unpack_snorm8(packed >> 8),
		unpack_snorm8(packed >> 16),
		unpack_snorm8(packed >> 24)
	)


static func pack_profile_sample_records(records: Array) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(records.size() * PROFILE_SAMPLE_RECORD_STRIDE_BYTES)
	for i in range(records.size()):
		if not records[i] is Dictionary:
			# 原先静默返回空字节：调用方只看到「这份 profile 没有样本」，不知道是被整批丢弃。
			push_error("ProfileRecordSchema.pack_profile_sample_records: 记录 [%d] 不是 Dictionary（类型 %d），共 %d 条 —— 整批打包作废" % [i, typeof(records[i]), records.size()])
			assert(false, "ProfileRecordSchema.pack_profile_sample_records: non-dictionary record")
			return PackedByteArray()
		var sample := records[i] as Dictionary
		var validation_error := profile_sample_validation_error(sample)
		if not validation_error.is_empty():
			push_error("ProfileRecordSchema.pack_profile_sample_records: 记录 [%d] 校验失败 '%s'（共 %d 条）—— 整批打包作废" % [i, validation_error, records.size()])
			assert(false, "ProfileRecordSchema.pack_profile_sample_records: invalid sample")
			return PackedByteArray()
		var offset := VariantUtils.vector3_from_value(
			sample.get("local_offset_world", Vector3.ZERO), Vector3.ZERO)
		var color := VariantUtils.color_from_value(sample.get("color", Color.WHITE), Color.WHITE)
		color.a = clampf(float(sample.get("complexity", color.a)), 0.0, 1.0)
		var base := i * PROFILE_SAMPLE_RECORD_STRIDE_BYTES
		BufferUtils.encode_vec4(bytes, base, offset, float(sample.get("sample_weight", 1.0)))
		bytes.encode_u32(base + 16, BufferUtils.pack_shader_rgba8_word(color))
		bytes.encode_u32(base + 20, pack_profile_sample_metrics(
			float(sample.get("collision", 0.0)),
			float(sample.get("w_color", 1.0)),
			float(sample.get("w_complexity", 1.0)),
			float(sample.get("w_collision", 1.0))))
		bytes.encode_u32(base + 24, int(sample.get("flags", 0)))
		bytes.encode_u32(base + 28, int(sample.get("reserved", 0)))
	return bytes


static func decode_profile_sample_records(bytes: PackedByteArray) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	# 字节数不是 stride 的整数倍 ⟹ 回读被截断或 ABI 与 GLSL 侧不一致；原先整除截尾，
	# 静默少解一条记录（或把错位数据当成合法样本）。
	if bytes.size() % PROFILE_SAMPLE_RECORD_STRIDE_BYTES != 0:
		push_error("ProfileRecordSchema.decode_profile_sample_records: 字节数 %d 不是 stride %d 的整数倍 —— 回读截断或 ABI 不一致" % [bytes.size(), PROFILE_SAMPLE_RECORD_STRIDE_BYTES])
		assert(false, "ProfileRecordSchema.decode_profile_sample_records: byte count not a multiple of stride")
		return result
	var count := bytes.size() / PROFILE_SAMPLE_RECORD_STRIDE_BYTES
	for i in range(count):
		var base := i * PROFILE_SAMPLE_RECORD_STRIDE_BYTES
		var metrics := unpack_profile_sample_metrics(int(bytes.decode_u32(base + 20)))
		var color := BufferUtils.shader_rgba8_word_to_color(int(bytes.decode_u32(base + 16)))
		result.append(make_profile_sample(
			Vector3(
				bytes.decode_float(base + 0),
				bytes.decode_float(base + 4),
				bytes.decode_float(base + 8)),
			color,
			metrics.x,
			int(bytes.decode_u32(base + 24)),
			bytes.decode_float(base + 12),
			metrics.y,
			metrics.z,
			metrics.w,
			&"gpu_readback"
		))
		result[-1]["reserved"] = int(bytes.decode_u32(base + 28))
	return result


static func resolve_profile_sample_voxel(
	local_offset_world: Vector3,
	anchor_voxel: Vector3i,
	pivot_world: Vector3,
	yaw_radians: float,
	voxel_size: Vector3
) -> Vector3i:
	var local_world := local_offset_world - pivot_world
	var ca := cos(yaw_radians)
	var sa := sin(yaw_radians)
	var rotated := Vector3(
		ca * local_world.x + sa * local_world.z,
		local_world.y,
		-sa * local_world.x + ca * local_world.z)
	var safe_voxel_size := Vector3(
		maxf(absf(voxel_size.x), 1.0e-6),
		maxf(absf(voxel_size.y), 1.0e-6),
		maxf(absf(voxel_size.z), 1.0e-6))
	return anchor_voxel + Vector3i(
		roundi(rotated.x / safe_voxel_size.x),
		roundi(rotated.y / safe_voxel_size.y),
		roundi(rotated.z / safe_voxel_size.z))


# ══ GPU record 字节布局 LAYOUT 表（数据契约收紧计划 T2：ABI 定义单点，不改任何实际布局）══
# CPU pack/decode（AutoVoxelRuntimeProfileContainer._pack_* / _decode_profile_table_bytes）与
# GLSL structs (RuntimeProfileTableRecord / RuntimePivotRecord / ProfileSampleRecord)
# 裸偏移读取）都必须与本表一致；GLSL 侧以 `// @@GEN profile_record_layout <record>` 锚块承载
# 本表发射文本，scripts/checks/glsl_gen_block_checks.gd 校验锚块与 layout_anchor_block() 输出一致。
# 多字节向量按 4 字节标量字段展开（vec3 → *_x/*_y/*_z），字段全部 4B 对齐。

const PROFILE_TABLE_STRIDE_BYTES := 64
const PIVOT_RECORD_STRIDE_BYTES := 32
const PROFILE_SAMPLE_RECORD_STRIDE_BYTES := 32

const RECORD_LAYOUTS := {
	"profile_table": {
		"title": "runtime profile_table record (GLSL RuntimeProfileTableRecord: uvec4 ids / uvec4 ranges / vec4 color_complexity / vec4 density_radius_hash_pad)",
		"stride_bytes": PROFILE_TABLE_STRIDE_BYTES,
		"fields": [
			{"offset": 0, "encode": "u32", "name": "profile_id"},
			{"offset": 4, "encode": "u32", "name": "profile_index"},
			{"offset": 8, "encode": "u32", "name": "coarse_sample_start"},
			{"offset": 12, "encode": "u32", "name": "coarse_sample_count"},
			{"offset": 16, "encode": "u32", "name": "fine_sample_start"},
			{"offset": 20, "encode": "u32", "name": "fine_sample_count"},
			{"offset": 24, "encode": "u32", "name": "pivot_start"},
			{"offset": 28, "encode": "u32", "name": "pivot_count"},
			{"offset": 32, "encode": "f32", "name": "color_r"},
			{"offset": 36, "encode": "f32", "name": "color_g"},
			{"offset": 40, "encode": "f32", "name": "color_b"},
			{"offset": 44, "encode": "f32", "name": "complexity"},
			{"offset": 48, "encode": "f32", "name": "semantic_probe_density"},
			{"offset": 52, "encode": "f32", "name": "context_sensing_radius"},
			{"offset": 56, "encode": "u32", "name": "profile_hash_u32"},
			{"offset": 60, "encode": "u32", "name": "reserved"},
		],
	},
	"pivot": {
		"title": "runtime pivot record (GLSL RuntimePivotRecord: vec4 offset_bias / uvec4 ids_pad)",
		"stride_bytes": PIVOT_RECORD_STRIDE_BYTES,
		"fields": [
			{"offset": 0, "encode": "f32", "name": "offset_x"},
			{"offset": 4, "encode": "f32", "name": "offset_y"},
			{"offset": 8, "encode": "f32", "name": "offset_z"},
			{"offset": 12, "encode": "f32", "name": "score_bias"},
			{"offset": 16, "encode": "u32", "name": "name_hash_u32"},
			{"offset": 20, "encode": "u32", "name": "reserved0"},
			{"offset": 24, "encode": "u32", "name": "reserved1"},
			{"offset": 28, "encode": "u32", "name": "reserved2"},
		],
	},
	"profile_sample": {
		"title": "runtime profile sample record (GLSL ProfileSampleRecord: vec4 offset_weight / uvec4 payload)",
		"stride_bytes": PROFILE_SAMPLE_RECORD_STRIDE_BYTES,
		"fields": [
			{"offset": 0, "encode": "f32", "name": "offset_x"},
			{"offset": 4, "encode": "f32", "name": "offset_y"},
			{"offset": 8, "encode": "f32", "name": "offset_z"},
			{"offset": 12, "encode": "f32", "name": "sample_weight"},
			{"offset": 16, "encode": "u32", "name": "rgba8"},
			{"offset": 20, "encode": "u32", "name": "packed_metrics"},
			{"offset": 24, "encode": "u32", "name": "flags"},
			{"offset": 28, "encode": "u32", "name": "reserved"},
		],
	},
}

## GLSL 锚块消费面（scripts/checks/glsl_gen_block_checks.gd 按此扫描）。
const CONSUMERS := {
	"profile_record_layout profile_table": [
		"res://shaders/score_anchor_asset_residual.glsl",
		"res://shaders/stamp_asset_voxels.glsl",
	],
	"profile_record_layout pivot": [
		"res://shaders/score_anchor_asset_residual.glsl",
		"res://shaders/stamp_asset_voxels.glsl",
		"res://shaders/placement_results_to_world.glsl",
	],
	"profile_record_layout profile_sample": [
		"res://shaders/score_anchor_asset_probes.glsl",
		"res://shaders/score_anchor_asset_residual.glsl",
		"res://shaders/stamp_asset_voxels.glsl",
	],
}


## 从 LAYOUT 表发射 GLSL 锚块正文（纯注释行，零编译影响；格式确定性、无对齐填充）。
static func layout_anchor_block(record_name: String) -> String:
	var layout: Dictionary = RECORD_LAYOUTS.get(record_name, {})
	# 返回空串会让 glsl_gen_block_checks 把「锚块名写错」误判成「锚块正文恰好为空」。
	if layout.is_empty():
		push_error("ProfileRecordSchema.layout_anchor_block: 未知的 record 名 '%s'（已知: %s）" % [record_name, str(RECORD_LAYOUTS.keys())])
		assert(false, "ProfileRecordSchema.layout_anchor_block: unknown record name")
		return ""
	var lines: Array[String] = []
	lines.append("// %s — stride %d B" % [String(layout["title"]), int(layout["stride_bytes"])])
	lines.append("// SSOT: ProfileRecordSchema.RECORD_LAYOUTS[\"%s\"] — CPU pack/decode and this GLSL side must match." % record_name)
	for field in layout["fields"]:
		lines.append("// offset %d %s %s" % [int(field["offset"]), String(field["encode"]), String(field["name"])])
	return "\n".join(lines)


## glsl_gen_block_checks 的 SSOT 接口（与 PlacementSharedGLSL 同形）。
static func block_names() -> Array:
	return CONSUMERS.keys()


static func block(name: String) -> String:
	return layout_anchor_block(name.trim_prefix("profile_record_layout ").strip_edges()).strip_edges()


## 自检：每个 LAYOUT 表字段须 4B 对齐、连续、恰好铺满 stride；返回错误列表（空 = 通过）。
static func verify_record_layouts() -> PackedStringArray:
	var errors := PackedStringArray()
	for record_name in RECORD_LAYOUTS:
		var layout: Dictionary = RECORD_LAYOUTS[record_name]
		var expected_offset := 0
		for field in layout["fields"]:
			if int(field["offset"]) != expected_offset:
				errors.append("%s.%s: offset %d, expected %d" % [record_name, field["name"], int(field["offset"]), expected_offset])
			expected_offset = int(field["offset"]) + 4
		if expected_offset != int(layout["stride_bytes"]):
			errors.append("%s: fields end at %d B, stride is %d B" % [record_name, expected_offset, int(layout["stride_bytes"])])
	return errors
