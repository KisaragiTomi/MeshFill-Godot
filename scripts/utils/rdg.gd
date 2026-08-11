@tool
class_name RDG
extends RefCounted

## UE 的 Render Dependency Graph（FRDGBuilder）在 Godot RenderingDevice 上的移植。
## 本文件是命名空间门面：访问语义枚举、资源描述符、以及声明 pass 参数用的 read/write 助手。
##
## Godot 没有暴露 per-resource barrier，唯一手段 compute_list_add_barrier() 实际是把
## compute list **切成两段**，真正的 barrier 由引擎自己的 RenderingDeviceGraph 按两段登记的
## ResourceUsage 推导。同一段内引擎不插任何 barrier，段内冲突由应用负责。
## 所以本移植要解决的是"在哪里切段"，不是"插什么 barrier"。
##
## 与现有 [ComputePassChain] 的关系：那条路是"位置数组绑定 + 相邻 pass 无条件切段"，
## 本层是"虚拟资源 + 访问语义 → 图自己推依赖/剔除/切段/池化"。两者并存，现有调用点不受影响。
## 设备、RID 跟踪与 GC 全部复用 [GodotComputeShaderBase]（组合，不继承）——
## 本家族没有自己的设备封装。

## 资源访问语义。决定依赖建边（RAW/WAR/WAW）与剔除时的存活性。
enum Access {
	READ,        ## 只读（UE: SRV）。建 RAW 边；不会让生产者存活以外的任何 pass 存活。
	WRITE,       ## 整块覆盖写（UE: UAV，不读旧值）。建 WAW/WAR 边。
	READ_WRITE,  ## 读改写 / 原子累加（UE: UAV）。同时建读边与写边。
	INDIRECT,    ## 作为 dispatch_indirect 的间接参数被读取。语义上是读。
}

enum Kind {
	BUFFER,
	TEXTURE,
}

## 资源在图中的来源。决定是否可以进瞬态池、以及是否天然是图的输出根。
enum Origin {
	TRANSIENT,  ## 图内创建、图结束即失效 -> 可进池复用
	EXTERNAL,   ## 外部注册的既有 RID -> 写它是可观测副作用，永不入池、生产者永不被剔除
}


## —— 描述符 ——————————————————————————————————————————————————

## 缓冲描述符（UE: FRDGBufferDesc）。
class BufferDesc extends RefCounted:
	var size_bytes := 0

	## RenderingDevice.StorageBufferUsage 位。目前只有
	## STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT (1<<0) 一个可选位，它在恒有的 STORAGE 位之上
	## 追加 BUFFER_USAGE_INDIRECT_BIT。要当 dispatch_indirect 参数用的 buffer 必须带上它，
	## 否则建出来的资源根本不能喂给 compute_list_dispatch_indirect。
	var usage := 0

	func _init(p_size_bytes := 0, p_usage := 0) -> void:
		size_bytes = p_size_bytes
		usage = p_usage

	## 池化桶：向上取到 2 的幂（下限 256B）。UE 的 pooled buffer 同样是"物理 >= 请求"，
	## 精确按 size 建 key 会让复用率塌到几乎为零（每个中间量尺寸都略有不同）。
	func pool_bucket() -> int:
		var n := 256
		while n < size_bytes:
			n <<= 1
		return n

	## usage 必须进 key：usage 位不同的 buffer 底层 VkBuffer 标志不同，不能互换复用。
	func pool_key() -> String:
		return "buf:%d:u%d" % [pool_bucket(), usage]

	func describe() -> String:
		var u := "" if usage == 0 else " usage=%d" % usage
		return "Buffer(%dB%s)" % [size_bytes, u]


## 纹理描述符（UE: FRDGTextureDesc）。本移植覆盖 compute 用的 storage image
## （imageLoad/imageStore）与带采样器的纹理（texture()）两种读法。
class TextureDesc extends RefCounted:
	## 默认 usage。**必须带 SAMPLING 位**：STORAGE 与 SAMPLING 是互不覆盖的两个位，
	## 只给 STORAGE 的纹理绑到 UNIFORM_TYPE_SAMPLER_WITH_TEXTURE 上会被 Godot 直接拒掉。
	## 而池发出来的纹理是按 desc 建的 —— 这个默认值决定了「池里的纹理能不能被采样」。
	const DEFAULT_USAGE := (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)

	var width := 1
	var height := 1
	var depth := 1
	var format := RenderingDevice.DATA_FORMAT_R32_SFLOAT
	var texture_type := RenderingDevice.TEXTURE_TYPE_2D

	## RenderingDevice.TextureUsageBits。默认见 DEFAULT_USAGE；只在明确要收窄能力时才传别的值。
	var usage := DEFAULT_USAGE

	func _init(p_w := 1, p_h := 1, p_d := 1, p_format := RenderingDevice.DATA_FORMAT_R32_SFLOAT,
			p_usage := DEFAULT_USAGE) -> void:
		width = p_w
		height = p_h
		depth = p_d
		format = p_format
		usage = p_usage
		texture_type = RenderingDevice.TEXTURE_TYPE_3D if p_d > 1 else RenderingDevice.TEXTURE_TYPE_2D

	## 纹理不做尺寸向上取整（格式/维度不匹配就没法复用），按全字段精确建 key。
	## usage 同样必须进 key（与 BufferDesc 的 DISPATCH_INDIRECT 位同理）：usage 位不同的纹理
	## 底层 VkImage 标志不同，互换复用的话，一张没有 SAMPLING 位的纹理会被发给需要采样的 pass，
	## 而 pool_key 相同意味着图完全看不出这件事。
	func pool_key() -> String:
		return "tex:%d:%d:%d:%d:%d:u%d" % [width, height, depth, format, texture_type, usage]

	func describe() -> String:
		var u := "" if usage == DEFAULT_USAGE else " usage=%d" % usage
		return "Texture(%dx%dx%d fmt=%d%s)" % [width, height, depth, format, u]


## —— 描述符构造助手 ————————————————————————————————————————

static func buffer(size_bytes: int, usage := 0) -> BufferDesc:
	return BufferDesc.new(size_bytes, usage)


## dispatch_indirect 的参数缓冲：3 个 uint32（groups x/y/z）。
static func indirect_args_buffer() -> BufferDesc:
	return BufferDesc.new(12, RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT)


static func texture_2d(w: int, h: int, format := RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		usage := TextureDesc.DEFAULT_USAGE) -> TextureDesc:
	return TextureDesc.new(w, h, 1, format, usage)


static func texture_3d(w: int, h: int, d: int, format := RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		usage := TextureDesc.DEFAULT_USAGE) -> TextureDesc:
	return TextureDesc.new(w, h, d, format, usage)


## —— pass 参数声明 ————————————————————————————————————————
## 每一项都带访问语义，图才推导得出依赖 —— 这正是相对「位置数组绑定」的关键差别。
## 绑定位置规则（单 set 扁平数组 / 多 set 嵌套数组）见 [method RDGBuilder.add_pass]。
## 返回 Dictionary 而非自定义类，是为了避开 RDG -> RDGResource -> RDG 的解析循环引用。

static func read(res) -> Dictionary:
	return {"res": res, "access": Access.READ}


static func write(res) -> Dictionary:
	return {"res": res, "access": Access.WRITE}


static func read_write(res) -> Dictionary:
	return {"res": res, "access": Access.READ_WRITE}


static func indirect(res) -> Dictionary:
	return {"res": res, "access": Access.INDIRECT}


## 带采样器的纹理读（GLSL 的 `sampler2D` + `texture()`，对应 UNIFORM_TYPE_SAMPLER_WITH_TEXTURE）。
##
## 语义上**完全等同** [method read]：建 RAW 边、要求资源已初始化、[method is_read] 为真。
## 所以这里刻意复用 Access.READ 而不是新增枚举值 —— 新增的话建边、剔除、生命周期、dump
## 全都要跟着加分支，漏掉任何一处就是静默的依赖丢失（图会认为这个 pass 不需要上游的数据）。
##
## 采样器只是多带一个键：它属于**绑定**而不是**资源**。同一张纹理可以被不同 pass 配不同采样器，
## 所以 sampler RID 既不进 [RDGResource]、也不进池的分桶 key。
## 但被采样的纹理必须带 TEXTURE_USAGE_SAMPLING_BIT，那是**资源**属性，进 [method TextureDesc.pool_key]。
static func sample(res, sampler: RID) -> Dictionary:
	return {"res": res, "access": Access.READ, "sampler": sampler}


static func access_name(a: int) -> String:
	match a:
		Access.READ: return "R"
		Access.WRITE: return "W"
		Access.READ_WRITE: return "RW"
		Access.INDIRECT: return "IND"
	return "?"


## 该访问是否构成"读"（建 RAW 边、要求资源已初始化）。
static func is_read(a: int) -> bool:
	return a == Access.READ or a == Access.READ_WRITE or a == Access.INDIRECT


## 该访问是否构成"写"（建 WAW/WAR 边、把资源标记为已初始化、让 pass 成为该资源的生产者）。
static func is_write(a: int) -> bool:
	return a == Access.WRITE or a == Access.READ_WRITE
