@tool
class_name BufferDescriptor
extends RefCounted

## 单个 GPU buffer 的**声明式描述**（《GPU_Buffer_Debug_Plan.md》阶段 1）。
##
## 项目里 ~48 个 GPU buffer 的元信息（stride / 容量 / 格式 / set·binding / 怎么解一条记录）
## 目前散在各自的创建点与 ad-hoc `read_buffer_bytes` 调用点上，每个 debug 现场都要重抄一遍。
## 本类把这些元信息收敛成一份**纯数据、纯 CPU**的描述对象：不持有 RID、不碰 RenderingDevice、
## 不 dispatch，只回答「这块 buffer 是什么形状、第 i 条记录怎么读」。运行时查询工具
## （DebugProbe，阶段 4）在此之上构建，本文件不涉及。
##
## 两个正交维度（计划 §1.2）——两者都必须显式声明，缺一不可：
##   [b]数据排布[/b] `kind`：SOA_ARRAY（分 buffer 一维数组）/ AOS_ARRAY（单 buffer 结构体数组）
##       / VOXEL_FIELD（线性化多维体素场）/ TILE_METADATA（瓦片元数据）/ SCALAR（单字/计数器）。
##   [b]覆盖范围[/b] `density`：DENSE（全网格/全容量都有效数据）/ SPARSE（固定分配但仅部分活跃，
##       如 `alive[idx]==0` 的空槽、只有 stamp 过的瓦片才非零）。
## 二者独立：稠密体素场是 VOXEL_FIELD+DENSE，瓦片记录是 TILE_METADATA+SPARSE，
## SoA 对象数组是 SOA_ARRAY+SPARSE。
##
## 字段名一律取自计划 §3.2 的结构定义；计划把 scope/kind/density/readback_policy 写作 `int`
## 枚举，本实现落成**字符串常量**——这是本项目既有惯例（[GodotComputeShaderBase] 的
## `SCOPE_PERSISTENT := "persistent"` 等、[DebugBufferSet] 的 `KIND_STAT_SLOTS := "stat_slots"`），
## 字符串在 golden 文本与错误信息里自解释，且 `scope` 可以原样传给
## `storage_buffer_zero(bytes, scope, label)`。字段**名**未做任何改动。
##
## 标注 [补充推断] 的常量/方法是计划未写死、按 [DebugBufferSet] 既有惯例补齐的部分。
##
## 用法：
##   var d := BufferDescriptor.new({
##       "name": "alive", "kind": BufferDescriptor.KIND_SOA_ARRAY,
##       "density": BufferDescriptor.DENSITY_SPARSE, "scope": BufferDescriptor.SCOPE_PERSISTENT,
##       "element_format": "int32", "element_count": max_objects,
##       "glsl_set": 0, "glsl_binding": 1, "glsl_type": "int[]",
##       "owner_class": "GPUAutoObjectRuntime", "purpose": "对象槽存活位",
##   })
##   d.byte_size()                      # → max_objects * 4
##   d.decode_record(bytes, 7)          # → {buffer, index, byte_offset, stride, fields:{value: 1}}

## 依赖一律限于**纯静态、纯 CPU**的原语，复用而不重抄。计算基类仍**不** preload
## （那会把 RenderingDevice 拖进来），故 SCOPE_* 常量是逐字副本，见下。
##   * BufferUtils      —— 字节原语（RGBA8 拆包等）
##   * VoxelGeneralScript —— 规范体素索引式的唯一实现（见 voxel_index()）；
##     它的依赖链是 profile_record_schema → buffer_utils / variant_utils，同样不碰 RD。
const BufferUtils := preload("res://scripts/utils/buffer_utils.gd")
const VoxelGeneralScript := preload("res://scripts/utils/voxel_general.gd")

# ── scope（与 GodotComputeShaderBase.SCOPE_* 逐字相同；此处不 preload 计算基类，保持本类不依赖 RD，
#    新增 scope 时两处必须同步）──
const SCOPE_PERSISTENT := "persistent"
const SCOPE_FRAME := "frame"
const SCOPE_PASS := "pass"
const SCOPE_SCRATCH := "scratch"
const SCOPES := [SCOPE_PERSISTENT, SCOPE_FRAME, SCOPE_PASS, SCOPE_SCRATCH]

# ── kind：数据排布（计划 §1.3 的四种模式 + 标量）──
const KIND_SOA_ARRAY := "soa_array"        # A. 分 buffer 一维数组，按 index 关联
const KIND_AOS_ARRAY := "aos_array"        # B. 单 buffer 连续结构体
const KIND_VOXEL_FIELD := "voxel_field"    # C. 线性化多维体素场
const KIND_TILE_METADATA := "tile_metadata"  # D. 稀疏瓦片元数据
const KIND_SCALAR := "scalar"              # 单字/计数器 buffer（dirty_count 等）
const KINDS := [KIND_SOA_ARRAY, KIND_AOS_ARRAY, KIND_VOXEL_FIELD, KIND_TILE_METADATA, KIND_SCALAR]

# ── density：覆盖范围（计划 §1.2）──
const DENSITY_DENSE := "dense"
const DENSITY_SPARSE := "sparse"
## [补充推断] 计划 §5 的清单里，标量/计数器 buffer 的 D/S 列写作 "—"（稀疏稠密不适用）。
const DENSITY_NA := "na"
const DENSITIES := [DENSITY_DENSE, DENSITY_SPARSE, DENSITY_NA]

# ── readback 策略（计划 §3.2 的 ENABLED | DEBUG_ONLY | DISABLED）──
const READBACK_ENABLED := "enabled"        # 常规路径也读（fail-loud 诊断、契约守卫）
const READBACK_DEBUG_ONLY := "debug_only"  # 仅 debug 开关打开时读
const READBACK_DISABLED := "disabled"      # 从不 CPU 读回（纯 GPU 内部状态）
const READBACK_POLICIES := [READBACK_ENABLED, READBACK_DEBUG_ONLY, READBACK_DISABLED]

# ── decode 变换（计划 §3.2 列出 none / q1000 / rgba8_unpack / unorm8_to_float / custom）──
const DECODE_NONE := "none"
const DECODE_Q1000 := "q1000"                    # word / 1000
const DECODE_RGBA8_UNPACK := "rgba8_unpack"      # u32 → Color（低字节 = r）
const DECODE_UNORM8_TO_FLOAT := "unorm8_to_float"  # (word & 0xFF) / 255
## [补充推断] 以下三种取自 DebugBufferSet 既有 decode 名，计划归在 "custom" 里。
const DECODE_Q1000000 := "q1000000"              # word / 1000000（shader quantize_unit）
const DECODE_BOOL := "bool"                      # word != 0
const DECODE_INVERTED_MIN := "inverted_min"      # atomicMax(BASE - q) 反转 min；需 base，word 0 → 0.0
const DECODES := [
	DECODE_NONE, DECODE_Q1000, DECODE_RGBA8_UNPACK, DECODE_UNORM8_TO_FLOAT,
	DECODE_Q1000000, DECODE_BOOL, DECODE_INVERTED_MIN,
]

# ── 体素场索引空间。计划 §3.2 写 "xzy" | "xyz"；DebugBufferSet 的 schema 用全名
#    "voxel_dense_xzy"，两者视作同一约定（normalize_index_space 归一）。
#    [补充推断] "tile" / "sparse" 也在项目里出现（见 DebugBufferSet 头注），此处允许声明，
#    但 voxel_index() 不为它们提供公式——寻址由各自的所有者负责。
const INDEX_SPACE_XZY := "xzy"
const INDEX_SPACE_XYZ := "xyz"
const INDEX_SPACE_VOXEL_DENSE_XZY := "voxel_dense_xzy"
const INDEX_SPACE_TILE := "tile"
const INDEX_SPACE_SPARSE := "sparse"
const INDEX_SPACES := [
	INDEX_SPACE_XZY, INDEX_SPACE_XYZ, INDEX_SPACE_VOXEL_DENSE_XZY,
	INDEX_SPACE_TILE, INDEX_SPACE_SPARSE,
]

## element_format → {size 字节数, enc 编码, n 分量数}。名字用计划 §3.2 举的格式名
## （"int32" / "float32" / "ivec4" / "mat4" / "rgba8" / "u32_unorm8"）；
## [补充推断] uint32 / vec2·ivec2·uvec2 / vec4·uvec4 按项目现存 buffer 补齐。
const FORMATS := {
	"int32": {"size": 4, "enc": "s32", "n": 1},
	"uint32": {"size": 4, "enc": "u32", "n": 1},
	"float32": {"size": 4, "enc": "f32", "n": 1},
	"rgba8": {"size": 4, "enc": "u32", "n": 1},       # 打包在 u32 里的 4×unorm8 颜色
	"u32_unorm8": {"size": 4, "enc": "u32", "n": 1},  # u32 低字节承载 unorm8 强度
	"vec2": {"size": 8, "enc": "f32", "n": 2},
	"ivec2": {"size": 8, "enc": "s32", "n": 2},
	"uvec2": {"size": 8, "enc": "u32", "n": 2},
	"vec4": {"size": 16, "enc": "f32", "n": 4},
	"ivec4": {"size": 16, "enc": "s32", "n": 4},
	"uvec4": {"size": 16, "enc": "u32", "n": 4},
	"mat4": {"size": 64, "enc": "f32", "n": 16},
}

## VOXEL_FIELD 的通道格式 → 该格式蕴含的 decode 变换。项目里稠密体素场并非只有 float：
## complexity_field 是 rgba8 打包色、collision_field 是 u32 低字节承载 unorm8（计划 §1.3）。
## **逐通道解码一律经此表分派**——不在表内的 element_format 属于"没人声明过怎么解"，
## decode_record 直接拒绝解码，绝不退回 decode_float（把 0x00FF8040 解成 2.3e-38 次正规数，
## 无任何报错，正是本类要消灭的失败模式）。
const VOXEL_FIELD_CHANNEL_DECODES := {
	"float32": DECODE_NONE,                  # 原样 float
	"rgba8": DECODE_RGBA8_UNPACK,            # u32 打包色 → Color（低字节 = r）
	"u32_unorm8": DECODE_UNORM8_TO_FLOAT,    # u32 低字节 unorm8 → [0,1] float
}

## element_count 取此值 = 容量在描述期未知（随 dispatch 参数变化），byte_size() 返回 -1。
const COUNT_DYNAMIC := -1


# ── 字段（名字逐一对应计划 §3.2；purpose 为唯一新增，见下）──

var name: String = ""                    ## buffer 名（"alive"、"scene_voxel_tile_records"…）
## [补充推断] 计划 §3.2 无此字段，但 §1.4 的统一视图要求描述"用途"，且 tags 承载不了一句话说明。
var purpose: String = ""                 ## 一句话用途（人读，出现在 describe()）
var scope: String = SCOPE_FRAME          ## SCOPE_*：生命周期（与 GodotComputeShaderBase 一致）
var kind: String = KIND_SOA_ARRAY        ## KIND_*：数据排布
var density: String = DENSITY_NA         ## DENSITY_*：覆盖范围（稠密/稀疏）
var element_stride: int = 0              ## 每条记录字节数；<=0 时由 element_format 推导
var element_count: int = COUNT_DYNAMIC   ## 记录数；COUNT_DYNAMIC(-1) = 动态
var element_format: String = ""          ## FORMATS 里的格式名（AoS 逐字段格式见 aos_fields）
var glsl_set: int = 0                    ## shader set 编号
var glsl_binding: int = 0                ## shader binding 编号
var glsl_qualifier: String = ""          ## "std430 restrict" / "std430 restrict readonly" …
var glsl_type: String = ""               ## GLSL 侧类型名（"int[]"、"uint[]"、"mat4[]"…）
var owner_class: String = ""             ## 创建/持有这块 buffer 的 GDScript 类名
var tags: Array[String] = []             ## ["runtime", "debug", "stats", "field"] 之类的检索标签

# AOS 专用：一条记录内的字段表 [{name, offset, type, size, decode?, base?}, …]
var aos_fields: Array = []

# VOXEL_FIELD 专用
var field_dims: Vector3i = Vector3i.ZERO       ## 场维度（grid_size）
var field_index_space: String = ""             ## INDEX_SPACE_*
var field_channels: int = 0                    ## 每元素通道数（AoS-of-channels）
var field_channel_names: Array[String] = []

# 读回控制
var readback_policy: String = READBACK_DEBUG_ONLY
var decode_transform: String = DECODE_NONE     ## 单值记录的整体解码变换


## 从 {字段名: 值} 构造。未给的键保持默认值；未知键会被忽略但报错（拼错字段名是本类最容易犯的错，
## 静默吞掉会产出一个"看着合法、实际缺了一半信息"的描述）。
func _init(config: Dictionary = {}) -> void:
	if config.is_empty():
		return
	for key in config:
		var key_name := str(key)
		match key_name:
			"name": name = str(config[key])
			"purpose": purpose = str(config[key])
			"scope": scope = str(config[key])
			"kind": kind = str(config[key])
			"density": density = str(config[key])
			"element_stride": element_stride = int(config[key])
			"element_count": element_count = int(config[key])
			"element_format": element_format = str(config[key])
			"glsl_set": glsl_set = int(config[key])
			"glsl_binding": glsl_binding = int(config[key])
			"glsl_qualifier": glsl_qualifier = str(config[key])
			"glsl_type": glsl_type = str(config[key])
			"owner_class": owner_class = str(config[key])
			"tags": tags = _to_string_array(config[key])
			"aos_fields": aos_fields = (config[key] as Array) if config[key] is Array else []
			"field_dims": field_dims = config[key] if config[key] is Vector3i else Vector3i.ZERO
			"field_index_space": field_index_space = str(config[key])
			"field_channels": field_channels = int(config[key])
			"field_channel_names": field_channel_names = _to_string_array(config[key])
			"readback_policy": readback_policy = str(config[key])
			"decode_transform": decode_transform = str(config[key])
			_:
				push_error("BufferDescriptor('%s')._init: 未知配置键 '%s' —— 该值不会生效" % [
					str(config.get("name", "")), key_name])
				assert(false, "BufferDescriptor._init: unknown config key")


## @tool 软重载后，本次重载新增的成员会是 nil（声明初始化器不重跑）。所有读容器成员的公开方法
## 先过这里；判空一律用 `is`（`== null` 对静态类型已知的操作数会被编成恒 false）。
func _repair_soft_reloaded_members() -> void:
	if not (name is String): name = ""
	if not (purpose is String): purpose = ""
	if not (scope is String): scope = SCOPE_FRAME
	if not (kind is String): kind = KIND_SOA_ARRAY
	if not (density is String): density = DENSITY_NA
	if not (element_stride is int): element_stride = 0
	if not (element_count is int): element_count = COUNT_DYNAMIC
	if not (element_format is String): element_format = ""
	if not (glsl_set is int): glsl_set = 0
	if not (glsl_binding is int): glsl_binding = 0
	if not (glsl_qualifier is String): glsl_qualifier = ""
	if not (glsl_type is String): glsl_type = ""
	if not (owner_class is String): owner_class = ""
	if not (tags is Array):
		var fresh_tags: Array[String] = []
		tags = fresh_tags
	if not (aos_fields is Array): aos_fields = []
	if not (field_dims is Vector3i): field_dims = Vector3i.ZERO
	if not (field_index_space is String): field_index_space = ""
	if not (field_channels is int): field_channels = 0
	if not (field_channel_names is Array):
		var fresh_names: Array[String] = []
		field_channel_names = fresh_names
	if not (readback_policy is String): readback_policy = READBACK_DEBUG_ONLY
	if not (decode_transform is String): decode_transform = DECODE_NONE


# ── 形状查询 ──

## 一条记录的实际字节数：显式 element_stride 优先；否则 VOXEL_FIELD 按 通道数×通道格式，
## 其余按 element_format。推不出来返回 0（validate() 会把它报成错）。
func effective_stride() -> int:
	_repair_soft_reloaded_members()
	if element_stride > 0:
		return element_stride
	var unit := format_size(element_format)
	if kind == KIND_VOXEL_FIELD:
		var chans := maxi(field_channels, field_channel_names.size())
		return unit * maxi(chans, 0)
	return unit


## 总字节数；element_count 为 COUNT_DYNAMIC 时返回 -1（容量未知，不猜）。
func byte_size() -> int:
	_repair_soft_reloaded_members()
	if element_count < 0:
		return -1
	return effective_stride() * element_count


## 体素坐标 → 线性 index，按本描述声明的索引空间。
func field_voxel_index(p: Vector3i) -> int:
	_repair_soft_reloaded_members()
	return voxel_index(p, field_dims, field_index_space)


## 线性化公式（与 shader voxel_index() 对称）：
##   xzy（含别名 voxel_dense_xzy）：p.x + dims.x * (p.z + dims.z * p.y)
##   xyz                          ：p.x + dims.x * (p.y + dims.y * p.z)
## 其余索引空间没有通用公式，返回 -1（由所有者自行寻址）。
##
## ⚠ xzy 分支**转发**到 VoxelGeneral.voxel_index()，别改回本地重写一遍算式。
## 那条 xzy 式就是全仓的规范索引式（《AutoVolume 公用体积基类计划》§0 要求「全仓唯一」），
## 22 个业务调用点走的都是 VoxelGeneral 那一份；本类此前另存了一份逐字相同的副本，
## 两份都对时看不出问题，一旦有人只改一份，症状是「某些消费方解出隔壁体素」——
## 不崩、不报错，只有坐标静默偏移。转发让「改一处即全仓生效」成为结构保证。
## 反向不可行：VoxelGeneral.voxel_index 进过 sort_custom 比较器
## （volume_score_fine_selection.gd:509，O(n log n) 次调用），让它去走本函数的
## normalize_index_space 字符串分派是白付出的代价。所以算式留在热的那一侧，冷的一侧转发。
static func voxel_index(p: Vector3i, dims: Vector3i, index_space: String = INDEX_SPACE_XZY) -> int:
	match normalize_index_space(index_space):
		INDEX_SPACE_XZY:
			return VoxelGeneralScript.voxel_index(p, dims)
		INDEX_SPACE_XYZ:
			return p.x + dims.x * (p.y + dims.y * p.z)
		_:
			return -1


## "voxel_dense_xzy" → "xzy"，空串 → "xzy"（项目默认稠密体素约定）；其余原样。
static func normalize_index_space(index_space: String) -> String:
	if index_space.is_empty() or index_space == INDEX_SPACE_VOXEL_DENSE_XZY:
		return INDEX_SPACE_XZY
	return index_space


static func format_size(format_name: String) -> int:
	var entry: Dictionary = FORMATS.get(format_name, {})
	return int(entry.get("size", 0))


# ── 解码：如何读一条记录 ──

## 解出第 index 条记录。返回稳定键序的 dict：
##   {buffer, index, byte_offset, stride, fields}
## fields 的构成按 kind：
##   AOS_ARRAY / TILE_METADATA（声明了 aos_fields）→ {字段名: 已 decode 的值}
##   VOXEL_FIELD → {通道名: 按 element_format 解出的值}（float32/u32_unorm8 → float，rgba8 → Color）
##   其余（SoA / SCALAR / 无字段表的 AoS）          → {"value": 已 decode 的值}
## 越界或 stride 非法时**不返回半成品**：报错 + 断言 + 返回空 dict（与本项目 fail-loud 惯例一致）。
func decode_record(bytes: PackedByteArray, index: int) -> Dictionary:
	_repair_soft_reloaded_members()
	var stride := effective_stride()
	if stride <= 0:
		push_error("BufferDescriptor('%s').decode_record: 无法确定 stride（element_stride=%d, format='%s'）—— 拒绝解码" % [
			name, element_stride, element_format])
		assert(false, "BufferDescriptor.decode_record: unresolved stride")
		return {}
	var offset := index * stride
	if index < 0 or offset + stride > bytes.size():
		push_error("BufferDescriptor('%s').decode_record: 第 %d 条记录越界（需要 [%d,%d)，实得 %d 字节）—— 拒绝零填充解码" % [
			name, index, offset, offset + stride, bytes.size()])
		assert(false, "BufferDescriptor.decode_record: out of range")
		return {}
	var fields := {}
	if kind == KIND_VOXEL_FIELD:
		if not VOXEL_FIELD_CHANNEL_DECODES.has(element_format):
			push_error("BufferDescriptor('%s').decode_record: VOXEL_FIELD 的 element_format '%s' 不在通道格式表 %s 内 —— 拒绝按 float 解（打包字会被解成次正规数）" % [
				name, element_format, str(VOXEL_FIELD_CHANNEL_DECODES.keys())])
			assert(false, "BufferDescriptor.decode_record: unsupported voxel field format")
			return {}
		var unit := format_size(element_format)
		var chans := maxi(field_channels, field_channel_names.size())
		if unit <= 0 or chans <= 0 or chans * unit > stride:
			push_error("BufferDescriptor('%s').decode_record: 通道跨度非法（%d 通道 × %d 字节 越出 stride %d）—— 拒绝越界解码" % [
				name, chans, unit, stride])
			assert(false, "BufferDescriptor.decode_record: channel span exceeds stride")
			return {}
		for c in range(chans):
			var ch_name := field_channel_names[c] if c < field_channel_names.size() else "channel_%d" % c
			fields[ch_name] = decode_field_channel(bytes, offset + c * unit, element_format)
	elif not aos_fields.is_empty():
		for f in aos_fields:
			if not (f is Dictionary):
				continue
			var entry: Dictionary = f
			var f_name := str(entry.get("name", ""))
			var f_format := str(entry.get("type", element_format))
			var f_offset := offset + int(entry.get("offset", 0))
			var raw: Variant = _read_format(bytes, f_offset, f_format)
			fields[f_name] = apply_decode(raw, str(entry.get("decode", DECODE_NONE)), float(entry.get("base", 0.0)))
	else:
		fields["value"] = apply_decode(_read_format(bytes, offset, element_format), decode_transform, 0.0)
	return {
		"buffer": name,
		"index": index,
		"byte_offset": offset,
		"stride": stride,
		"fields": fields,
	}


## 按 decode 变换把原始字/向量转成人读值。未知变换原样返回（调用方可自带 custom 变换）。
static func apply_decode(raw: Variant, transform: String, base: float = 0.0) -> Variant:
	match transform:
		DECODE_BOOL:
			return int(raw) != 0
		DECODE_Q1000:
			return float(raw) / 1000.0
		DECODE_Q1000000:
			return float(raw) / 1000000.0
		DECODE_UNORM8_TO_FLOAT:
			return float(int(raw) & 0xFF) / 255.0
		DECODE_RGBA8_UNPACK:
			# 低字节 = r 的打包约定与 shader 侧一致；拆包原语复用 BufferUtils，不在此重抄位移。
			return BufferUtils.semantic_rgba8_word_to_color(int(raw))
		DECODE_INVERTED_MIN:
			# atomicMax(BASE - q)：word 0 = 未写 → 0.0；否则 (BASE - word) / (BASE - 1)
			var word := float(raw)
			return (base - word) / maxf(base - 1.0, 1.0) if word > 0.0 else 0.0
		_:
			return raw


## 按 element_format 解体素场的一个通道：先按格式的编码读原始字，再套该格式蕴含的 decode 变换
## （float32 → 原样 float，rgba8 → Color，u32_unorm8 → [0,1] float）。
## 未登记的格式返回 null（TYPE_NIL）——调用方必须 fail-loud，**不得**默认按 float 解。
static func decode_field_channel(bytes: PackedByteArray, offset: int, format_name: String) -> Variant:
	if not VOXEL_FIELD_CHANNEL_DECODES.has(format_name):
		return null
	var entry: Dictionary = FORMATS.get(format_name, {})
	var raw: Variant = _read_scalar(bytes, offset, str(entry.get("enc", "u32")))
	return apply_decode(raw, str(VOXEL_FIELD_CHANNEL_DECODES[format_name]))


## 按格式读一个元素：单分量返回 int/float，多分量返回分量 Array（mat4 = 16 个 float，列主序）。
static func _read_format(bytes: PackedByteArray, offset: int, format_name: String) -> Variant:
	var entry: Dictionary = FORMATS.get(format_name, {})
	if entry.is_empty():
		return bytes.decode_u32(offset)  # 未声明格式时按原始字返回，交由 validate() 报错
	var enc := str(entry.get("enc", "u32"))
	var n := int(entry.get("n", 1))
	if n == 1:
		return _read_scalar(bytes, offset, enc)
	var out: Array = []
	for i in range(n):
		out.append(_read_scalar(bytes, offset + i * 4, enc))
	return out


static func _read_scalar(bytes: PackedByteArray, offset: int, enc: String) -> Variant:
	match enc:
		"f32":
			return bytes.decode_float(offset)
		"s32":
			return bytes.decode_s32(offset)
		_:
			return bytes.decode_u32(offset)


# ── 自检 / 可读输出 ──

## 结构自检：返回问题描述列表（空 = 合法）。纯 CPU、无副作用，不 push_error——
## 调用方（注册处、tools 测试）决定是报错还是仅告警。
func validate() -> PackedStringArray:
	_repair_soft_reloaded_members()
	var problems := PackedStringArray()
	if name.is_empty():
		problems.append("name 为空")
	if not KINDS.has(kind):
		problems.append("未知 kind '%s'" % kind)
	if not SCOPES.has(scope):
		problems.append("未知 scope '%s'" % scope)
	if not DENSITIES.has(density):
		problems.append("未知 density '%s'" % density)
	if not READBACK_POLICIES.has(readback_policy):
		problems.append("未知 readback_policy '%s'" % readback_policy)
	if not DECODES.has(decode_transform):
		problems.append("未知 decode_transform '%s'" % decode_transform)
	if not element_format.is_empty() and not FORMATS.has(element_format):
		problems.append("未知 element_format '%s'" % element_format)
	if effective_stride() <= 0:
		problems.append("stride 推导不出（element_stride=%d, element_format='%s'）" % [element_stride, element_format])
	if element_count < COUNT_DYNAMIC:
		problems.append("element_count=%d 非法（>=0 或 COUNT_DYNAMIC）" % element_count)
	if glsl_set < 0 or glsl_binding < 0:
		problems.append("glsl set/binding 为负（%d/%d）" % [glsl_set, glsl_binding])
	var stride := effective_stride()
	var seen_offsets := {}
	for f in aos_fields:
		if not (f is Dictionary):
			problems.append("aos_fields 含非 Dictionary 条目")
			continue
		var entry: Dictionary = f
		var f_name := str(entry.get("name", ""))
		if f_name.is_empty():
			problems.append("aos_fields 条目缺 name")
		var f_format := str(entry.get("type", element_format))
		if not FORMATS.has(f_format):
			problems.append("字段 '%s' 的 type '%s' 未知" % [f_name, f_format])
			continue
		var f_offset := int(entry.get("offset", -1))
		var f_size := int(entry.get("size", format_size(f_format)))
		if f_offset < 0:
			problems.append("字段 '%s' 缺 offset" % f_name)
		elif stride > 0 and f_offset + f_size > stride:
			problems.append("字段 '%s' 越出记录边界（%d+%d > stride %d）" % [f_name, f_offset, f_size, stride])
		if seen_offsets.has(f_offset):
			problems.append("字段 '%s' 与 '%s' 偏移重叠（%d）" % [f_name, str(seen_offsets[f_offset]), f_offset])
		else:
			seen_offsets[f_offset] = f_name
		var f_decode := str(entry.get("decode", DECODE_NONE))
		if not DECODES.has(f_decode):
			problems.append("字段 '%s' 的 decode '%s' 未知" % [f_name, f_decode])
	if kind == KIND_VOXEL_FIELD:
		if not INDEX_SPACES.has(field_index_space):
			problems.append("VOXEL_FIELD 必须声明合法 field_index_space（实得 '%s'）" % field_index_space)
		if field_channels <= 0:
			problems.append("VOXEL_FIELD 的 field_channels 必须 > 0")
		elif not field_channel_names.is_empty() and field_channel_names.size() != field_channels:
			problems.append("field_channel_names 数量 %d 与 field_channels %d 不符" % [
				field_channel_names.size(), field_channels])
		# 逐通道解码按 element_format 分派；不在通道格式表内 = 没人声明过怎么解，decode_record 会拒绝。
		if not VOXEL_FIELD_CHANNEL_DECODES.has(element_format):
			problems.append("VOXEL_FIELD 的 element_format 必须是通道格式之一 %s（实得 '%s'）" % [
				str(VOXEL_FIELD_CHANNEL_DECODES.keys()), element_format])
		else:
			var unit := format_size(element_format)
			var chans := maxi(field_channels, field_channel_names.size())
			if stride > 0 and unit > 0 and chans > 0 and chans * unit > stride:
				problems.append("VOXEL_FIELD 通道跨度越出 stride（%d 通道 × %d 字节 > %d）" % [chans, unit, stride])
	return problems


## 人读单行摘要（确定性，可直接进 golden 文本）。
func describe() -> String:
	_repair_soft_reloaded_members()
	var count_text := "dynamic" if element_count < 0 else str(element_count)
	var bytes_text := "?" if byte_size() < 0 else str(byte_size())
	return "%s [%s/%s] scope=%s stride=%d count=%s bytes=%s format=%s set=%d binding=%d readback=%s owner=%s" % [
		name, kind, density, scope, effective_stride(), count_text, bytes_text,
		element_format if not element_format.is_empty() else "-",
		glsl_set, glsl_binding, readback_policy,
		owner_class if not owner_class.is_empty() else "-",
	]


func _aos_field_names() -> PackedStringArray:
	var out := PackedStringArray()
	for f in aos_fields:
		if f is Dictionary:
			out.append(str(f.get("name", "")))
	return out


func _to_string_array(value: Variant) -> Array[String]:
	var out: Array[String] = []
	if value is Array:
		for v in (value as Array):
			out.append(str(v))
	return out


# ── 最小自检（纯 CPU、纯静态：无 RenderingDevice / 无 owner / 不构造实例 / 无副作用）──
#
# 只覆盖本类的**静态面**：常量表自洽性、索引空间线性化、decode 变换、按格式读字节、
# 体素场通道按 element_format 分派解码。
# 这部分不需要任何实例，故可在 _static_init 里跑（脚本一加载就自检，编辑器里当场报错）。
# 需要实例的断言（stride/byte_size 推导、decode_record、validate 的拦截能力、schema→descriptor
# 派生）在 tools/test_buffer_descriptor.gd（已于 2026-08-07 删除） —— 本文件内无法用 `BufferDescriptor.new()` 自引用：
# class_name 要等编辑器导入后才进 global_script_class_cache，`--check-only` 解析门下解析不到。
#
# 返回 {ok, checked, failures}；不 push_error，任何上下文都能安全调用。

static func self_check() -> Dictionary:
	var failures := PackedStringArray()
	var checked := 0

	# 1) 常量表自洽：枚举值不重复，FORMATS 的 size 与分量数一致、编码名合法。
	checked += 1
	var enum_tables := {
		"KINDS": KINDS, "DENSITIES": DENSITIES, "SCOPES": SCOPES,
		"READBACK_POLICIES": READBACK_POLICIES, "DECODES": DECODES, "INDEX_SPACES": INDEX_SPACES,
	}
	for table_name in enum_tables:
		var table: Array = enum_tables[table_name]
		var seen := {}
		for value in table:
			if seen.has(value):
				failures.append("%s 含重复值 '%s'" % [table_name, str(value)])
			seen[value] = true
		if table.is_empty():
			failures.append("%s 为空" % table_name)

	checked += 1
	for format_name in FORMATS:
		var entry: Dictionary = FORMATS[format_name]
		var size := int(entry.get("size", 0))
		var n := int(entry.get("n", 0))
		var enc := str(entry.get("enc", ""))
		if size != n * 4:
			failures.append("格式 '%s' 的 size %d != 分量数 %d × 4" % [str(format_name), size, n])
		if not ["s32", "u32", "f32"].has(enc):
			failures.append("格式 '%s' 的 enc '%s' 未知" % [str(format_name), enc])
		if format_size(str(format_name)) != size:
			failures.append("format_size('%s') 与表内 size 不一致" % str(format_name))
	if format_size("float128") != 0:
		failures.append("未知格式的 format_size 应为 0")

	# 2) 索引空间：xzy 与 shader voxel_index() 对称，别名归一，未知空间不猜公式。
	checked += 1
	var dims := Vector3i(4, 5, 6)
	var probe := Vector3i(2, 3, 1)
	var expect_xzy := probe.x + dims.x * (probe.z + dims.z * probe.y)
	var expect_xyz := probe.x + dims.x * (probe.y + dims.y * probe.z)
	if voxel_index(probe, dims, INDEX_SPACE_XZY) != expect_xzy:
		failures.append("xzy 线性化错误：期望 %d 实得 %d" % [expect_xzy, voxel_index(probe, dims, INDEX_SPACE_XZY)])
	if voxel_index(probe, dims, INDEX_SPACE_VOXEL_DENSE_XZY) != expect_xzy:
		failures.append("voxel_dense_xzy 别名未归一到 xzy")
	if voxel_index(probe, dims, "") != expect_xzy:
		failures.append("空 index_space 应按项目默认 xzy 归一")
	if voxel_index(probe, dims, INDEX_SPACE_XYZ) != expect_xyz:
		failures.append("xyz 线性化错误")
	if voxel_index(probe, dims, INDEX_SPACE_TILE) != -1:
		failures.append("无通用公式的索引空间应返回 -1，而非猜一个 index")
	if normalize_index_space(INDEX_SPACE_SPARSE) != INDEX_SPACE_SPARSE:
		failures.append("normalize_index_space 不应改写非别名空间")

	# 3) decode 变换。
	checked += 1
	if apply_decode(0, DECODE_BOOL) != false or apply_decode(3, DECODE_BOOL) != true:
		failures.append("bool 解码错误")
	if not is_equal_approx(float(apply_decode(1500, DECODE_Q1000)), 1.5):
		failures.append("q1000 解码错误")
	if not is_equal_approx(float(apply_decode(500000, DECODE_Q1000000)), 0.5):
		failures.append("q1000000 解码错误")
	if not is_equal_approx(float(apply_decode(0x1FF, DECODE_UNORM8_TO_FLOAT)), 1.0):
		failures.append("unorm8 解码应只取低字节")
	var color: Color = apply_decode(0xFF804020, DECODE_RGBA8_UNPACK)
	if not (is_equal_approx(color.r, float(0x20) / 255.0) and is_equal_approx(color.g, float(0x40) / 255.0) 			and is_equal_approx(color.b, float(0x80) / 255.0) and is_equal_approx(color.a, 1.0)):
		failures.append("rgba8 拆包错误（低字节应为 r）：%s" % str(color))
	if not is_equal_approx(float(apply_decode(0, DECODE_INVERTED_MIN, 1000001.0)), 0.0):
		failures.append("inverted_min 的 word 0（未写）应解出 0.0")
	if not is_equal_approx(float(apply_decode(1, DECODE_INVERTED_MIN, 1000001.0)), 1.0):
		failures.append("inverted_min 的满量程编码应解出 1.0")
	if int(apply_decode(7, "some_custom_transform")) != 7:
		failures.append("未知 decode 变换应原样返回，交由调用方自带变换")

	# 4) 按格式读字节：单分量 / 多分量 / mat4。
	checked += 1
	var bytes := PackedByteArray()
	bytes.resize(64)
	bytes.encode_s32(0, -7)
	bytes.encode_float(4, 0.25)
	bytes.encode_u32(8, 4000000000)
	if int(_read_format(bytes, 0, "int32")) != -7:
		failures.append("int32 读取错误")
	if not is_equal_approx(float(_read_format(bytes, 4, "float32")), 0.25):
		failures.append("float32 读取错误")
	if int(_read_format(bytes, 8, "uint32")) != 4000000000:
		failures.append("uint32 读取错误（可能被当成有符号）")
	var quad: Array = _read_format(bytes, 0, "ivec4")
	if quad.size() != 4 or int(quad[0]) != -7:
		failures.append("ivec4 应读出 4 个分量")
	var mat: Array = _read_format(bytes, 0, "mat4")
	if mat.size() != 16:
		failures.append("mat4 应读出 16 个 float")

	# 5) 体素场通道解码按 element_format 分派：打包格式不得被当成 float 解，未知格式不得静默通过。
	checked += 1
	for channel_format in VOXEL_FIELD_CHANNEL_DECODES:
		if not FORMATS.has(channel_format):
			failures.append("通道格式 '%s' 不在 FORMATS 表内" % str(channel_format))
		if not DECODES.has(str(VOXEL_FIELD_CHANNEL_DECODES[channel_format])):
			failures.append("通道格式 '%s' 映射到未知 decode 变换" % str(channel_format))
	var packed_bytes := PackedByteArray()
	packed_bytes.resize(12)
	packed_bytes.encode_float(0, 0.25)
	packed_bytes.encode_u32(4, 0x00FF8040)   # rgba8 打包色：r=0x40 g=0x80 b=0xFF a=0x00
	packed_bytes.encode_u32(8, 0x0000FF7F)   # u32_unorm8：低字节 0x7F
	if not is_equal_approx(float(decode_field_channel(packed_bytes, 0, "float32")), 0.25):
		failures.append("float32 通道解码错误")
	var packed_color: Variant = decode_field_channel(packed_bytes, 4, "rgba8")
	if not (packed_color is Color) or not is_equal_approx((packed_color as Color).r, float(0x40) / 255.0):
		failures.append("rgba8 通道应拆包成 Color 而非被当作 float 解出次正规数：%s" % str(packed_color))
	if not is_equal_approx(float(decode_field_channel(packed_bytes, 8, "u32_unorm8")), float(0x7F) / 255.0):
		failures.append("u32_unorm8 通道解码错误")
	if typeof(decode_field_channel(packed_bytes, 0, "int32")) != TYPE_NIL:
		failures.append("未登记为通道格式的 element_format 必须解不出值（交调用方 fail-loud），不得默认按 float 解")

	return {"ok": failures.is_empty(), "checked": checked, "failures": failures}


## 脚本加载即自检：静态面一旦被改坏（常量表打错、索引公式写反、decode 变换漂移），编辑器里当场报错，
## 不等到某个 debug 现场读出一堆"看着合法、实际全错"的数字。纯常量运算，代价可忽略。
static func _static_init() -> void:
	var result := self_check()
	if not bool(result.get("ok", false)):
		for failure in result.get("failures", PackedStringArray()):
			push_error("BufferDescriptor.self_check: %s" % str(failure))
