class_name GodotComputeShaderBase
extends RefCounted

const SCOPE_PERSISTENT := "persistent"
const SCOPE_FRAME := "frame"
const SCOPE_PASS := "pass"
const SCOPE_SCRATCH := "scratch"

const KIND_BUFFER := "buffer"
const KIND_TEXTURE := "texture"
const KIND_SAMPLER := "sampler"
const KIND_SHADER := "shader"
const KIND_PIPELINE := "pipeline"
const KIND_UNIFORM_SET := "uniform_set"
const KIND_OTHER := "other"

const OWNED := true
const BORROWED := false
const _BUFFER_ZERO_UPDATE_CHUNK_BYTES := 1048576

const _DEFAULT_GC_ORDER := {
	KIND_UNIFORM_SET: 10,
	KIND_PIPELINE: 20,
	KIND_SHADER: 30,
	KIND_SAMPLER: 40,
	KIND_TEXTURE: 50,
	KIND_BUFFER: 60,
	KIND_OTHER: 100,
}

var log_name := "GodotComputeShaderBase"
var sync_global_device := false

var _rd: RenderingDevice
var _owns_rendering_device := false
var _disposed := true
var _compute_list_active := false
var _buffer_zero_scratch := PackedByteArray()

var _resources: Array[Dictionary] = []
var _scope_stack: Array[String] = [SCOPE_PERSISTENT]
var _deferred_gc_scopes: Array[String] = []
var _kind_disposers: Dictionary = {}
var _kind_orders: Dictionary = _DEFAULT_GC_ORDER.duplicate()
var _next_resource_id := 1


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if not _disposed:
			dispose()


## 共有的 RenderingDevice 获取逻辑：优先创建本地 device（owns=true），否则回退到
## 全局 device（owns=false）；两者都失败时 rd 为 null。以静态形式暴露，供本基类的
## ensure_device() 与不继承本基类的 GPU 持有者（如 AutoVoxelRuntimeProfileContainer）
## 共用，避免各处重复实现 create_local + global-fallback 的获取代码。
static func acquire_rendering_device(prefer_local_device: bool = true, allow_global_fallback: bool = true) -> Dictionary:
	var rd: RenderingDevice = null
	if prefer_local_device:
		rd = RenderingServer.create_local_rendering_device()
	if rd != null:
		return {"rd": rd, "owns": true}
	if allow_global_fallback:
		rd = RenderingServer.get_rendering_device()
	return {"rd": rd, "owns": false}


func ensure_device(prefer_local_device: bool = true, allow_global_fallback: bool = true) -> bool:
	if _rd != null:
		return true

	var acquired := acquire_rendering_device(prefer_local_device, allow_global_fallback)
	_rd = acquired["rd"]
	_owns_rendering_device = acquired["owns"]

	if _rd == null:
		if DisplayServer.get_name() == "headless":
			push_error("%s: no RenderingDevice — 当前以 --headless 启动，GPU 路径不可用。请改用 --rendering-driver vulkan 运行（参见 tools/run_test.ps1）。" % log_name)
		else:
			push_error("%s: no RenderingDevice available" % log_name)
		return false

	_disposed = false
	_on_device_ready()
	return true


func attach_rendering_device(rendering_device: RenderingDevice, owns_device: bool = false) -> bool:
	if rendering_device == null:
		push_error("%s: external RenderingDevice is null" % log_name)
		return false

	if _rd != null and _rd != rendering_device:
		push_warning("%s: replacing an active RenderingDevice; call dispose() first if it owns resources" % log_name)

	_rd = rendering_device
	_owns_rendering_device = owns_device
	_disposed = false
	_on_device_ready()
	return true


func get_rendering_device() -> RenderingDevice:
	return _rd


func owns_rendering_device() -> bool:
	return _owns_rendering_device


## 从任意协作对象读取其 RenderingDevice：对象非 null 且暴露 get_rendering_device() 时返回该设备，
## 否则返回 null。共有静态形式，供各处以鸭子类型方式借用 committer/runtime/profile 容器的设备，
## 收敛重复的 has_method("get_rendering_device") + call(...) 样板。
## 注意：返回 null 无法区分“对象无此方法”与“方法返回 null”；需要区分二者的调用点
## （如 GPUAutoObjectRuntime 里带专属 reason 的契约校验）应保留各自独立的 has_method() 判断。
static func rendering_device_of(object: Object) -> RenderingDevice:
	if object != null and object.has_method("get_rendering_device"):
		return object.call("get_rendering_device")
	return null


func dispose(sync_before_free: bool = false) -> void:
	if _disposed:
		return
	_disposed = true

	_on_before_dispose()
	if sync_before_free:
		submit_and_sync(sync_global_device)
	gc_all(false)

	if _rd != null and _owns_rendering_device:
		_rd.free()

	_rd = null
	_owns_rendering_device = false
	_compute_list_active = false
	_deferred_gc_scopes.clear()
	_scope_stack = [SCOPE_PERSISTENT]
	_on_after_dispose()


func submit_and_sync(include_global_device: bool = false) -> void:
	if _rd == null:
		return
	if _owns_rendering_device or include_global_device:
		_rd.submit()
		_rd.sync()


func begin_scope(scope: String) -> String:
	if scope.is_empty():
		scope = SCOPE_SCRATCH
	_scope_stack.append(scope)
	return scope


func end_scope(free_now: bool = true) -> void:
	if _scope_stack.size() <= 1:
		return
	var scope: String = _scope_stack.pop_back()
	if free_now:
		gc_scope(scope)


func current_scope() -> String:
	return _scope_stack.back()


func track_rid(
	rid: RID,
	kind: String = KIND_OTHER,
	scope: String = "",
	label: String = "",
	disposer: Callable = Callable(),
	owned: bool = OWNED
) -> RID:
	if not rid.is_valid():
		return rid

	var resolved_scope: String = scope
	if resolved_scope.is_empty():
		resolved_scope = current_scope()

	for entry in _resources:
		if bool(entry.get("alive", false)) and entry.get("rid", RID()) == rid:
			entry["kind"] = kind
			entry["scope"] = resolved_scope
			entry["label"] = label
			entry["disposer"] = disposer
			entry["owned"] = owned
			return rid

	_resources.append({
		"id": _next_resource_id,
		"rid": rid,
		"kind": kind,
		"scope": resolved_scope,
		"label": label,
		"disposer": disposer,
		"owned": owned,
		"alive": true,
	})
	_next_resource_id += 1
	return rid


func track_borrowed_rid(
	rid: RID,
	kind: String = KIND_OTHER,
	scope: String = SCOPE_PERSISTENT,
	label: String = ""
) -> RID:
	return track_rid(rid, kind, scope, label, Callable(), BORROWED)


func is_tracked_rid_owned(rid: RID) -> bool:
	for entry in _resources:
		if bool(entry.get("alive", false)) and entry.get("rid", RID()) == rid:
			return bool(entry.get("owned", OWNED))
	return false


func untrack_rid(rid: RID) -> RID:
	for entry in _resources:
		if bool(entry.get("alive", false)) and entry.get("rid", RID()) == rid:
			entry["alive"] = false
			break
	_compact_dead_resources()
	return rid


func release_rid(rid: RID, defer_if_busy: bool = true) -> void:
	if not rid.is_valid():
		return
	if _compute_list_active and defer_if_busy:
		var scope: String = "_rid_%d" % _next_resource_id
		for entry in _resources:
			if bool(entry.get("alive", false)) and entry.get("rid", RID()) == rid:
				entry["scope"] = scope
				_queue_gc_scope(scope)
				return
		track_rid(rid, KIND_OTHER, scope, "deferred_untracked")
		_queue_gc_scope(scope)
		return

	for entry in _resources:
		if bool(entry.get("alive", false)) and entry.get("rid", RID()) == rid:
			_free_entry(entry)
			_compact_dead_resources()
			return
	if _rd != null:
		_rd.free_rid(rid)


func gc_scope(scope: String, defer_if_busy: bool = true) -> void:
	if scope.is_empty():
		return
	if _compute_list_active and defer_if_busy:
		_queue_gc_scope(scope)
		return
	_collect_entries(func(entry: Dictionary) -> bool:
		return str(entry.get("scope", "")) == scope
	)


func gc_frame() -> void:
	gc_scope(SCOPE_PASS)
	gc_scope(SCOPE_FRAME)


func gc_all(defer_if_busy: bool = true) -> void:
	if _compute_list_active and defer_if_busy:
		for entry in _resources:
			if bool(entry.get("alive", false)):
				_queue_gc_scope(str(entry.get("scope", "")))
		return
	_collect_entries(func(_entry: Dictionary) -> bool:
		return true
	)


func flush_deferred_gc() -> void:
	if _compute_list_active:
		return
	var scopes: Array[String] = _deferred_gc_scopes.duplicate()
	_deferred_gc_scopes.clear()
	for scope in scopes:
		gc_scope(scope, false)


func register_kind_disposer(kind: String, disposer: Callable, order: int = 100) -> void:
	_kind_disposers[kind] = disposer
	_kind_orders[kind] = order


func begin_compute_list() -> int:
	if _rd == null:
		return -1
	_compute_list_active = true
	return _rd.compute_list_begin()


func end_compute_list() -> void:
	if _rd == null:
		_compute_list_active = false
		return
	_rd.compute_list_end()
	_compute_list_active = false
	flush_deferred_gc()


func load_compute_shader(path: String, scope: String = SCOPE_PERSISTENT, label: String = "") -> RID:
	if _rd == null:
		push_error("%s: load_compute_shader called before ensure_device" % log_name)
		return RID()

	var spirv: RDShaderSPIRV
	var source_text: String = read_compute_shader_source(path)
	if not source_text.is_empty():
		var source: RDShaderSource = RDShaderSource.new()
		source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
		source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, source_text)
		spirv = _rd.shader_compile_spirv_from_source(source)
	else:
		var shader_file: RDShaderFile = load(path) as RDShaderFile
		if shader_file != null:
			spirv = shader_file.get_spirv()

	if spirv == null:
		push_error("%s: failed to compile compute shader: %s" % [log_name, path])
		return RID()

	var err_msg: String = spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not err_msg.is_empty():
		push_error("%s GLSL compile error [%s]: %s" % [log_name, path, err_msg])
		return RID()

	var shader: RID = _rd.shader_create_from_spirv(spirv)
	if not shader.is_valid():
		push_error("%s: SPIR-V create failed: %s" % [log_name, path])
		return RID()

	var resolved_label: String = label if not label.is_empty() else path.get_file()
	return track_rid(shader, KIND_SHADER, scope, resolved_label)


func create_compute_pipeline(shader: RID, scope: String = SCOPE_PERSISTENT, label: String = "") -> RID:
	if _rd == null or not shader.is_valid():
		return RID()
	var pipeline: RID = _rd.compute_pipeline_create(shader)
	return track_rid(pipeline, KIND_PIPELINE, scope, label)


func read_compute_shader_source(path: String) -> String:
	var absolute_path: String = ProjectSettings.globalize_path(path)
	var source_text: String = FileAccess.get_file_as_string(absolute_path)
	if source_text.is_empty():
		source_text = FileAccess.get_file_as_string(path)
	if source_text.is_empty():
		return ""

	var lines: PackedStringArray = source_text.split("\n")
	var filtered: Array[String] = []
	for line in lines:
		if line.strip_edges() == "#[compute]":
			continue
		filtered.append(line)
	return "\n".join(filtered)


func create_uniform_set(
	uniforms: Array,
	shader: RID,
	set_index: int,
	scope: String = SCOPE_PASS,
	label: String = ""
) -> RID:
	if _rd == null:
		return RID()
	var uniform_set: RID = _rd.uniform_set_create(uniforms, shader, set_index)
	return track_rid(uniform_set, KIND_UNIFORM_SET, scope, label)


func make_storage_uniform(binding: int, buffer: RID) -> RDUniform:
	var uniform: RDUniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform


func make_image_uniform(binding: int, texture: RID) -> RDUniform:
	var uniform: RDUniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = binding
	uniform.add_id(texture)
	return uniform


func make_sampler_uniform(binding: int, sampler: RID, texture: RID) -> RDUniform:
	var uniform: RDUniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = binding
	uniform.add_id(sampler)
	uniform.add_id(texture)
	return uniform


func storage_buffer_from_bytes(bytes: PackedByteArray, scope: String = SCOPE_FRAME, label: String = "") -> RID:
	if _rd == null:
		return RID()
	var safe: PackedByteArray = bytes
	if safe.size() <= 0:
		safe = PackedByteArray()
		safe.resize(4)
	return track_rid(_rd.storage_buffer_create(safe.size(), safe), KIND_BUFFER, scope, label)


func storage_buffer_from_floats(values: PackedFloat32Array, scope: String = SCOPE_FRAME, label: String = "") -> RID:
	return storage_buffer_from_bytes(pack_float_array(values), scope, label)


func storage_buffer_zero(byte_count: int, scope: String = SCOPE_FRAME, label: String = "") -> RID:
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(maxi(byte_count, 4))
	return storage_buffer_from_bytes(bytes, scope, label)


func buffer_zero(rid: RID, byte_count: int) -> bool:
	if _rd == null or not rid.is_valid():
		return false
	if byte_count < 0:
		return false
	if byte_count == 0:
		return true
	if _compute_list_active:
		push_error("%s: buffer_zero called while compute list is active" % log_name)
		return false

	var remaining := byte_count
	var offset := 0
	while remaining > 0:
		var chunk_size := mini(remaining, _BUFFER_ZERO_UPDATE_CHUNK_BYTES)
		if _rd.buffer_update(rid, offset, chunk_size, _buffer_zero_bytes(chunk_size)) != OK:
			return false
		offset += chunk_size
		remaining -= chunk_size
	return true


func _buffer_zero_bytes(byte_count: int) -> PackedByteArray:
	if _buffer_zero_scratch.size() != byte_count:
		_buffer_zero_scratch.resize(byte_count)
	return _buffer_zero_scratch


func dispatch_indirect_args_buffer_zero(scope: String = SCOPE_FRAME, label: String = "dispatch_indirect_args") -> RID:
	if _rd == null:
		return RID()
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(12)
	return track_rid(
		_rd.storage_buffer_create(
			bytes.size(),
			bytes,
			RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT
		),
		KIND_BUFFER,
		scope,
		label
	)


func create_linear_sampler(scope: String = SCOPE_PERSISTENT, label: String = "linear_sampler") -> RID:
	if _rd == null:
		return RID()
	var state: RDSamplerState = RDSamplerState.new()
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	return track_rid(_rd.sampler_create(state), KIND_SAMPLER, scope, label)


func upload_texture_2d(
	image: Image,
	format: int = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
	image_format: int = Image.FORMAT_RGBAH,
	usage_bits: int = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
	scope: String = SCOPE_FRAME,
	label: String = ""
) -> RID:
	if _rd == null or image == null:
		return RID()

	var img: Image = image
	if img.get_format() != image_format:
		img = img.duplicate()
		img.convert(image_format)

	var texture_format: RDTextureFormat = _texture_format_2d(img.get_width(), img.get_height(), format, usage_bits)
	var texture: RID = _rd.texture_create(texture_format, RDTextureView.new(), [img.get_data()])
	return track_rid(texture, KIND_TEXTURE, scope, label)


func create_rw_texture_2d(
	width: int,
	height: int,
	format: int = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
	usage_bits: int = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	),
	scope: String = SCOPE_FRAME,
	label: String = ""
) -> RID:
	if _rd == null:
		return RID()
	var texture_format: RDTextureFormat = _texture_format_2d(width, height, format, usage_bits)
	var texture: RID = _rd.texture_create(texture_format, RDTextureView.new())
	return track_rid(texture, KIND_TEXTURE, scope, label)


func upload_texture_3d(
	width: int,
	height: int,
	depth: int,
	bytes: PackedByteArray,
	format: int = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
	usage_bits: int = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
	scope: String = SCOPE_FRAME,
	label: String = ""
) -> RID:
	if _rd == null or width <= 0 or height <= 0 or depth <= 0 or bytes.is_empty():
		return RID()
	var texture_format: RDTextureFormat = _texture_format_3d(width, height, depth, format, usage_bits)
	var texture: RID = _rd.texture_create(texture_format, RDTextureView.new(), [bytes])
	return track_rid(texture, KIND_TEXTURE, scope, label)


func upload_texture_3d_from_images(
	images: Array,
	format: int = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
	image_format: int = Image.FORMAT_RGBAH,
	usage_bits: int = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
	scope: String = SCOPE_FRAME,
	label: String = ""
) -> RID:
	if _rd == null or images.is_empty():
		return RID()
	var first: Image = images[0] as Image
	if first == null:
		return RID()
	var width: int = first.get_width()
	var height: int = first.get_height()
	var depth: int = images.size()
	var bytes: PackedByteArray = PackedByteArray()
	for raw_image in images:
		var img: Image = raw_image as Image
		if img == null:
			return RID()
		if img.get_width() != width or img.get_height() != height:
			push_error("%s: 3D texture slices must have matching dimensions" % log_name)
			return RID()
		if img.get_format() != image_format:
			img = img.duplicate()
			img.convert(image_format)
		bytes.append_array(img.get_data())
	return upload_texture_3d(width, height, depth, bytes, format, usage_bits, scope, label)


func create_rw_texture_3d(
	width: int,
	height: int,
	depth: int,
	format: int = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
	usage_bits: int = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	),
	scope: String = SCOPE_FRAME,
	label: String = ""
) -> RID:
	if _rd == null or width <= 0 or height <= 0 or depth <= 0:
		return RID()
	var texture_format: RDTextureFormat = _texture_format_3d(width, height, depth, format, usage_bits)
	var texture: RID = _rd.texture_create(texture_format, RDTextureView.new())
	return track_rid(texture, KIND_TEXTURE, scope, label)


func pack_float_array(values: PackedFloat32Array) -> PackedByteArray:
	return values.to_byte_array()


func pack_u32_array(values: PackedInt32Array) -> PackedByteArray:
	return values.to_byte_array()


func ceil_div(value: int, divisor: int) -> int:
	if divisor <= 0:
		return 0
	return int((value + divisor - 1) / divisor)


func dispatch_groups_1d(element_count: int, local_size_x: int) -> Vector3i:
	return Vector3i(ceil_div(element_count, local_size_x), 1, 1)


func dispatch_groups_2d(width: int, height: int, local_size_x: int, local_size_y: int) -> Vector3i:
	return Vector3i(ceil_div(width, local_size_x), ceil_div(height, local_size_y), 1)


func dispatch_groups_3d(width: int, height: int, depth: int, local_size_x: int, local_size_y: int, local_size_z: int) -> Vector3i:
	return Vector3i(ceil_div(width, local_size_x), ceil_div(height, local_size_y), ceil_div(depth, local_size_z))


func cell_count_3d(width: int, height: int, depth: int) -> int:
	return maxi(width, 0) * maxi(height, 0) * maxi(depth, 0)


func byte_size_3d(width: int, height: int, depth: int, bytes_per_cell: int = 4) -> int:
	return cell_count_3d(width, height, depth) * maxi(bytes_per_cell, 1)


func storage_buffer_zero_3d(width: int, height: int, depth: int, bytes_per_cell: int = 4, scope: String = SCOPE_FRAME, label: String = "") -> RID:
	return storage_buffer_zero(byte_size_3d(width, height, depth, bytes_per_cell), scope, label)


func flatten_index_3d(x: int, y: int, z: int, width: int, height: int) -> int:
	return z * width * height + y * width + x


func _texture_format_2d(width: int, height: int, format: int, usage_bits: int) -> RDTextureFormat:
	var texture_format: RDTextureFormat = RDTextureFormat.new()
	texture_format.width = width
	texture_format.height = height
	texture_format.depth = 1
	texture_format.array_layers = 1
	texture_format.mipmaps = 1
	texture_format.format = format
	texture_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	texture_format.usage_bits = usage_bits
	return texture_format


func _texture_format_3d(width: int, height: int, depth: int, format: int, usage_bits: int) -> RDTextureFormat:
	var texture_format: RDTextureFormat = RDTextureFormat.new()
	texture_format.width = width
	texture_format.height = height
	texture_format.depth = depth
	texture_format.array_layers = 1
	texture_format.mipmaps = 1
	texture_format.format = format
	texture_format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	texture_format.usage_bits = usage_bits
	return texture_format


func _collect_entries(predicate: Callable) -> void:
	var to_free: Array[Dictionary] = []
	for entry in _resources:
		if bool(entry.get("alive", false)) and bool(predicate.call(entry)):
			to_free.append(entry)

	to_free.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ao: int = int(_kind_orders.get(str(a.get("kind", KIND_OTHER)), 100))
		var bo: int = int(_kind_orders.get(str(b.get("kind", KIND_OTHER)), 100))
		if ao == bo:
			return int(a.get("id", 0)) > int(b.get("id", 0))
		return ao < bo
	)

	for entry in to_free:
		_free_entry(entry)
	_compact_dead_resources()


func _free_entry(entry: Dictionary) -> void:
	if not bool(entry.get("alive", false)):
		return

	var rid: RID = entry.get("rid", RID())
	entry["alive"] = false
	if _rd == null or not rid.is_valid():
		return
	if not _should_free_resource(entry):
		return

	_on_before_free_resource(entry)

	var disposer: Callable = entry.get("disposer", Callable())
	if disposer.is_valid():
		disposer.call(_rd, rid, entry)
	else:
		var kind: String = str(entry.get("kind", KIND_OTHER))
		var kind_disposer: Callable = _kind_disposers.get(kind, Callable())
		if kind_disposer.is_valid():
			kind_disposer.call(_rd, rid, entry)
		else:
			_rd.free_rid(rid)

	_on_after_free_resource(entry)


func _queue_gc_scope(scope: String) -> void:
	if scope.is_empty() or _deferred_gc_scopes.has(scope):
		return
	_deferred_gc_scopes.append(scope)


func _compact_dead_resources() -> void:
	var alive: Array[Dictionary] = []
	for entry in _resources:
		if bool(entry.get("alive", false)):
			alive.append(entry)
	_resources = alive


func _on_device_ready() -> void:
	pass


func _on_before_dispose() -> void:
	pass


func _on_after_dispose() -> void:
	pass


func _should_free_resource(_entry: Dictionary) -> bool:
	return bool(_entry.get("owned", OWNED))


func _on_before_free_resource(_entry: Dictionary) -> void:
	pass


func _on_after_free_resource(_entry: Dictionary) -> void:
	pass
