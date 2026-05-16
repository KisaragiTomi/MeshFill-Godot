class_name SparseTileDispatch
extends "res://scripts/godot_compute_shader_base.gd"

const ACTIVITY_ABS_GT := 0
const ACTIVITY_GT := 1
const ACTIVITY_LT := 2
const ACTIVITY_NONZERO := 3

var grid_w: int
var grid_h: int
var tile_size: int
var expand_pixels: int
var threshold: float
var mask_threshold: float
var activity_mode: int
var use_mask := false

var groups_x: int
var groups_y: int
var max_tiles: int

var buf_compact_counter: RID
var buf_compact_tile_coords: RID
var buf_indirect_args: RID

var _shader_compact: RID
var _pipeline_compact: RID
var _shader_finalize: RID
var _pipeline_finalize: RID
var _uset_compact: RID
var _uset_finalize: RID

var _activity_buf: RID
var _mask_buf: RID
var _dummy_mask_buf: RID


func _init(
	rendering_device: RenderingDevice = null,
	gw: int = 1,
	gh: int = 1,
	p_tile_size: int = 8,
	p_expand: int = 1,
	p_threshold: float = 0.001,
	p_mask_threshold: float = 0.5,
	p_activity_mode: int = ACTIVITY_ABS_GT
) -> void:
	log_name = "SparseTileDispatch"
	_rd = rendering_device
	_owns_rendering_device = false
	configure(gw, gh, p_tile_size, p_expand, p_threshold, p_mask_threshold, p_activity_mode)


func configure(
	gw: int,
	gh: int,
	p_tile_size: int = 8,
	p_expand: int = 1,
	p_threshold: float = 0.001,
	p_mask_threshold: float = 0.5,
	p_activity_mode: int = ACTIVITY_ABS_GT
) -> void:
	grid_w = maxi(1, gw)
	grid_h = maxi(1, gh)
	tile_size = maxi(1, p_tile_size)
	expand_pixels = maxi(0, p_expand)
	threshold = p_threshold
	mask_threshold = p_mask_threshold
	activity_mode = p_activity_mode
	use_mask = false

	groups_x = ceil_div(grid_w, tile_size)
	groups_y = ceil_div(grid_h, tile_size)
	max_tiles = groups_x * groups_y

	if groups_x > 65535 or groups_y > 65535:
		push_error("SparseTileDispatch packs tile coordinates into 16 bits per axis.")


func setup(prefer_local_device: bool = true, allow_global_fallback: bool = true) -> bool:
	if _rd == null and not ensure_device(prefer_local_device, allow_global_fallback):
		return false
	if _rd == null:
		push_error("%s: no RenderingDevice available" % log_name)
		return false

	_create_buffers()
	_load_shaders()
	return _shader_compact.is_valid() and _pipeline_compact.is_valid() \
		and _shader_finalize.is_valid() and _pipeline_finalize.is_valid()


func set_activity_buffers(activity_buf: RID, mask_buf: RID = RID()) -> void:
	_activity_buf = activity_buf
	if mask_buf.is_valid():
		_mask_buf = mask_buf
		use_mask = true
	else:
		_mask_buf = _dummy_mask_buf
		use_mask = false
	_build_uniform_sets()


func set_scan_options(
	p_expand: int,
	p_threshold: float,
	p_mask_threshold: float = 0.5,
	p_activity_mode: int = ACTIVITY_ABS_GT
) -> void:
	expand_pixels = maxi(0, p_expand)
	threshold = p_threshold
	mask_threshold = p_mask_threshold
	activity_mode = p_activity_mode


func reset_counter() -> void:
	if _rd == null:
		return
	var z4 := PackedByteArray()
	z4.resize(4)
	z4.fill(0)
	_rd.buffer_update(buf_compact_counter, 0, 4, z4)

	var z12 := PackedByteArray()
	z12.resize(12)
	z12.fill(0)
	_rd.buffer_update(buf_indirect_args, 0, 12, z12)


func dispatch_compact(cl: int) -> void:
	if _rd == null:
		return

	var push := PackedByteArray()
	push.resize(32)
	push.encode_s32(0, grid_w)
	push.encode_s32(4, grid_h)
	push.encode_s32(8, tile_size)
	push.encode_s32(12, expand_pixels)
	push.encode_s32(16, activity_mode)
	push.encode_s32(20, 1 if use_mask else 0)
	push.encode_float(24, threshold)
	push.encode_float(28, mask_threshold)

	_rd.compute_list_bind_compute_pipeline(cl, _pipeline_compact)
	_rd.compute_list_bind_uniform_set(cl, _uset_compact, 0)
	_rd.compute_list_set_push_constant(cl, push, 32)
	_rd.compute_list_dispatch(cl, groups_x, groups_y, 1)
	_rd.compute_list_add_barrier(cl)

	var dummy_push := PackedByteArray()
	dummy_push.resize(16)
	dummy_push.fill(0)
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline_finalize)
	_rd.compute_list_bind_uniform_set(cl, _uset_finalize, 0)
	_rd.compute_list_set_push_constant(cl, dummy_push, 16)
	_rd.compute_list_dispatch(cl, 1, 1, 1)
	_rd.compute_list_add_barrier(cl)


func dispatch_indirect(cl: int) -> void:
	if _rd != null:
		_rd.compute_list_dispatch_indirect(cl, buf_indirect_args, 0)


func readback_tile_count() -> int:
	if _rd == null:
		return 0
	var data := _rd.buffer_get_data(buf_compact_counter, 0, 4)
	return data.decode_u32(0)


func readback_tile_coords(count: int) -> PackedInt32Array:
	if _rd == null or count <= 0:
		return PackedInt32Array()
	var clamped := mini(count, max_tiles)
	var bytes := _rd.buffer_get_data(buf_compact_tile_coords, 0, clamped * 4)
	var result := PackedInt32Array()
	result.resize(clamped)
	for i in range(clamped):
		result[i] = bytes.decode_u32(i * 4)
	return result


func cleanup() -> void:
	dispose()


func _create_buffers() -> void:
	buf_compact_counter = storage_buffer_zero(4, SCOPE_PERSISTENT, "compact_counter")
	_dummy_mask_buf = storage_buffer_zero(4, SCOPE_PERSISTENT, "dummy_mask")
	buf_compact_tile_coords = storage_buffer_zero(max_tiles * 4, SCOPE_PERSISTENT, "compact_tile_coords")

	var z12 := PackedByteArray()
	z12.resize(12)
	z12.fill(0)
	buf_indirect_args = track_rid(
		_rd.storage_buffer_create(
			12,
			z12,
			RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT
		),
		KIND_BUFFER,
		SCOPE_PERSISTENT,
		"indirect_args"
	)


func _load_shaders() -> void:
	_shader_compact = load_compute_shader("res://shaders/std_compact_generic.glsl")
	if _shader_compact.is_valid():
		_pipeline_compact = create_compute_pipeline(_shader_compact, SCOPE_PERSISTENT, "compact")

	_shader_finalize = load_compute_shader("res://shaders/std_finalize_compact.glsl")
	if _shader_finalize.is_valid():
		_pipeline_finalize = create_compute_pipeline(_shader_finalize, SCOPE_PERSISTENT, "finalize")


func _build_uniform_sets() -> void:
	if not _shader_compact.is_valid() or not _shader_finalize.is_valid():
		return
	if _uset_compact.is_valid():
		release_rid(_uset_compact)
	if _uset_finalize.is_valid():
		release_rid(_uset_finalize)

	_uset_compact = create_uniform_set([
		make_storage_uniform(0, _activity_buf),
		make_storage_uniform(1, _mask_buf),
		make_storage_uniform(2, buf_compact_counter),
		make_storage_uniform(3, buf_compact_tile_coords),
	], _shader_compact, 0, SCOPE_PERSISTENT, "compact_set")

	_uset_finalize = create_uniform_set([
		make_storage_uniform(0, buf_compact_counter),
		make_storage_uniform(1, buf_indirect_args),
	], _shader_finalize, 0, SCOPE_PERSISTENT, "finalize_set")
