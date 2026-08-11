class_name VoxelFieldDisplayGPU
extends "res://scripts/utils/voxel_multimesh_writer_gpu.gd"

# All-GPU voxel field renderer. Takes per-voxel field arrays (occupancy /
# collision / color / terrain height) plus grid params, and drives a MultiMesh
# whose instance transforms + colors are written DIRECTLY into the MultiMesh
# buffer by a compute pass on the MAIN RenderingDevice. There is no GPU->CPU
# readback: the field is uploaded once, the instance buffer is filled GPU-side,
# and the renderer draws it via a known custom AABB (empty cells collapse to a
# zero basis on the GPU and rasterize to nothing).
#
# One instance per grid cell (full grid). Hold the returned instance alive for
# as long as the MultiMesh is shown; freeing it releases the scratch GPU
# resources on the render thread. Shared device/pipeline/scratch lifecycle lives
# in VoxelMultiMeshWriterGPU.

const SHADER_PATH := "res://shaders/voxel_field_instances.glsl"
const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")

const VIEW_TARGET_COLOR := 0
const VIEW_PROJECT_COLOR := 1
const VIEW_COMPLEXITY := 2
const VIEW_COLLISION := 3


func _shader_path() -> String:
	return SHADER_PATH


# fields: { occupancy, collision, color_rgba (float CPU views; uploaded as
#           R8/R8/RGBA8), terrain_height }. params: { grid_size (Vector3i),
#           grid_origin (Vector3), voxel_size (Vector3), view_mode, display_scale,
#           height_span, threshold }.
# 坐标词汇与其余 volume 同款（grid_size / grid_origin / voxel_size）：实例位置
# = grid_origin + (voxel + 0.5) * voxel_size，Y 再加 terrain * display_scale。
# 旧的 xz_res / capture_size / vertical_span 三元组已退役——它编码的是「XZ 必须方形」
# 加「端点铺开式」两条隐含假设。
# Dispatches the field->instance compute write on the render thread. Zero readback.
func write_field(fields: Dictionary, params: Dictionary) -> bool:
	if not _ready:
		_last_reason = "writer_not_bound"
		return false
	if not _buffer_rid.is_valid():
		_last_reason = "writer_not_bound"
		return false

	var occupancy: PackedFloat32Array = fields.get("occupancy", PackedFloat32Array())
	var collision: PackedFloat32Array = fields.get("collision", PackedFloat32Array())
	var color_rgba: PackedFloat32Array = fields.get("color_rgba", PackedFloat32Array())
	var terrain_height: PackedFloat32Array = fields.get("terrain_height", PackedFloat32Array())

	if occupancy.size() != _instance_count:
		_last_reason = "occupancy_size_mismatch"
		return false
	# occupancy / color_rgba 尺寸不符是硬失败，collision 原先却被静默换成全零数组
	# （= 整场判无碰撞）——同族字段用同一条尺寸门。
	if collision.size() != _instance_count:
		push_error("VoxelFieldDisplayGPU.write_field: collision 长度 %d 与实例数 %d 不符 —— 拒绝零填充为「无碰撞」" % [collision.size(), _instance_count])
		assert(false, "VoxelFieldDisplayGPU.write_field: collision size mismatch")
		_last_reason = "collision_size_mismatch"
		return false
	if color_rgba.size() != _instance_count * 4:
		_last_reason = "color_rgba_size_mismatch"
		return false
	if terrain_height.is_empty():
		terrain_height = PackedFloat32Array()
		terrain_height.resize(1)

	# Everything that touches the rendering device must run on the render thread,
	# where the MultiMesh buffer RID is usable as a storage buffer.
	RenderingServer.call_on_render_thread(
		_render_thread_write.bind(occupancy, collision, color_rgba, terrain_height, params.duplicate(true))
	)
	_last_reason = "dispatched"
	return true


## 已打包输入的写入口：三块**已经是 shader 输入格式**的字节直接上传，跳过 float→打包那一步。
##
## 给 `SceneSV` 用。它的常驻场对本来就是这两种格式：
##   * complexity 场 = `rgba8_unorm`，`scatter_sv_field_records.glsl` 的
##     `pack_rgba8` 写成 `r<<24 | g<<16 | b<<8 | complexity`
##     ——注意 **complexity 在低字节**（那个 shader 的注释明写，也是它用 32 次
##     `atomicCompSwap` 而不是裸 `atomicMax` 的原因）；
##   * collision 场 = `unorm8_u32`，强度在低字节。
## 而本 shader 的 `unpack_rgba8` 是 `(>>24)=r (>>16)=g (>>8)=b (>>0)=a`、
## `unpack_r8` 取低字节 —— 与写入侧**逐位相同**。
##
## ⇒ 因此 `occupancy` 与 `color_rgba8` 两个 binding 可以**绑同一块 complexity 场**：
## binding 0 按低字节读出 complexity 当占据度，binding 2 按 rgba8 解出颜色。零转换、零 CPU 解码。
##
## ⚠ 别拿它走 TargetSV：TargetSV 的数据是从烘焙资产解出来的 float 数组，
## 它该走 `write_field()`（那条会调 codec 打包）。两条口的差别只在"输入已经打好包了没有"。
func write_packed_field(
	occupancy_u32_bytes: PackedByteArray,
	collision_u32_bytes: PackedByteArray,
	color_rgba8_bytes: PackedByteArray,
	terrain_height: PackedFloat32Array,
	params: Dictionary
) -> bool:
	if not _ready or not _buffer_rid.is_valid():
		_last_reason = "writer_not_bound"
		return false
	# 三块都是每**体素** 4 字节。尺寸不符一律硬失败——静默补零会让整场判成"空/无碰撞"，
	# 而那与"这一块场确实是空的"在画面上完全一样。
	#
	# ⚠ 期望长度按**体素数**算，不是实例数。两者只在全网格（恒等映射）模式下相等：
	# 紧凑模式（`use_index_map`）的实例数是非空砖里的格子数，而三块场仍是整块全网格
	# ——着色器按 `instance_voxel_index[idx]` 去场里取，取的是**体素**下标。
	# 旧写法固定用 `_instance_count`，于是 SV 一有内容就 100% 撞这道门（实测
	# 4,194,304 B 场 vs 462,336 实例），表现是"SV 开了显示却什么都没建出来"。
	var use_index_map := bool(params.get("use_index_map", false))
	var grid: Vector3i = params.get("grid_size", Vector3i.ZERO)
	var field_elements := _instance_count
	if use_index_map:
		field_elements = maxi(grid.x, 0) * maxi(grid.y, 0) * maxi(grid.z, 0)
		if field_elements <= 0:
			push_error("VoxelFieldDisplayGPU.write_packed_field: 紧凑模式缺少可用的 grid_size（%s）—— 无从判定场的期望长度。" % str(grid))
			assert(false, "VoxelFieldDisplayGPU.write_packed_field: index-map mode without grid_size")
			_last_reason = "index_map_without_grid_size"
			return false
		# 映射表长度必须**恰好**是实例数：短了着色器越界读（Vulkan 上是 0 或垃圾，
		# 画出零基向量或错格子），长了说明调用方的实例数与表不是同一批。两种都静默。
		var index_map: PackedInt32Array = params.get("instance_voxel_index", PackedInt32Array())
		if index_map.size() != _instance_count:
			push_error("VoxelFieldDisplayGPU.write_packed_field: 映射表长度 %d 与实例数 %d 不符 —— 着色器会按实例序越界读表。" % [
				index_map.size(), _instance_count])
			assert(false, "VoxelFieldDisplayGPU.write_packed_field: index map length mismatch")
			_last_reason = "index_map_length_mismatch"
			return false
	var expected := field_elements * 4
	for named in [
		["occupancy", occupancy_u32_bytes], ["collision", collision_u32_bytes], ["color_rgba8", color_rgba8_bytes],
	]:
		var field_name: String = named[0]
		var bytes: PackedByteArray = named[1]
		if bytes.size() != expected:
			push_error("VoxelFieldDisplayGPU.write_packed_field: %s 字节数 %d 与体素数 %d（期望 %d 字节；实例数 %d，紧凑模式=%s）不符 —— 拒绝补零。" % [
				field_name, bytes.size(), field_elements, expected, _instance_count, str(use_index_map)])
			assert(false, "VoxelFieldDisplayGPU.write_packed_field: packed field size mismatch")
			_last_reason = "%s_size_mismatch" % field_name
			return false
	if terrain_height.is_empty():
		terrain_height = PackedFloat32Array()
		terrain_height.resize(1)
	RenderingServer.call_on_render_thread(
		_render_thread_write_packed.bind(
			occupancy_u32_bytes, collision_u32_bytes, color_rgba8_bytes,
			terrain_height, params.duplicate(true))
	)
	_last_reason = "dispatched"
	return true


func _render_thread_write(
	occupancy: PackedFloat32Array,
	collision: PackedFloat32Array,
	color_rgba: PackedFloat32Array,
	terrain_height: PackedFloat32Array,
	params: Dictionary
) -> void:
	_free_scratch()
	if not _ensure_pipeline():
		return

	_dispatch_packed(
		SceneVoxelTileCodecScript.pack_collision_field_u32_bytes(occupancy, _instance_count),
		SceneVoxelTileCodecScript.pack_collision_field_u32_bytes(collision, _instance_count),
		SceneVoxelTileCodecScript.pack_complexity_field_rgba8_bytes(color_rgba, _instance_count),
		terrain_height,
		params)


func _render_thread_write_packed(
	occupancy_u32_bytes: PackedByteArray,
	collision_u32_bytes: PackedByteArray,
	color_rgba8_bytes: PackedByteArray,
	terrain_height: PackedFloat32Array,
	params: Dictionary
) -> void:
	_free_scratch()
	if not _ensure_pipeline():
		return
	_dispatch_packed(occupancy_u32_bytes, collision_u32_bytes, color_rgba8_bytes, terrain_height, params)


## 两条写入口的共同尾巴：三块**已打包**字节 + 高度场 → scratch buffer → uniform set → dispatch。
## ⚠ 只能在渲染线程上调（`_free_scratch()` 是同步释放，`_buffer_rid` 也只在那里可用）。
func _dispatch_packed(
	occupancy_u32_bytes: PackedByteArray,
	collision_u32_bytes: PackedByteArray,
	color_rgba8_bytes: PackedByteArray,
	terrain_height: PackedFloat32Array,
	params: Dictionary
) -> void:
	var occ_buf := _make_buffer(occupancy_u32_bytes)
	var coll_buf := _make_buffer(collision_u32_bytes)
	var color_buf := _make_buffer(color_rgba8_bytes)
	var height_buf := _make_buffer(terrain_height.to_byte_array())
	# 紧凑模式的实例序 → 体素下标映射。全网格模式下着色器不读它，但 Vulkan 要求
	# 已声明的 binding 必须有绑定，所以那种情况绑一块 4 字节占位（_make_buffer 自带补齐）。
	var index_map: PackedInt32Array = params.get("instance_voxel_index", PackedInt32Array())
	var index_buf := _make_buffer(index_map.to_byte_array())
	if not occ_buf.is_valid() or not coll_buf.is_valid() or not color_buf.is_valid() \
			or not height_buf.is_valid() or not index_buf.is_valid():
		_last_reason = "scratch_buffer_create_failed"
		return

	var uniforms: Array[RDUniform] = [
		_storage_uniform(0, occ_buf),
		_storage_uniform(1, coll_buf),
		_storage_uniform(2, color_buf),
		_storage_uniform(3, height_buf),
		_storage_uniform(4, _buffer_rid),
		_storage_uniform(5, index_buf),
	]
	var set0 := _rd.uniform_set_create(uniforms, _shader, 0)
	if not set0.is_valid():
		_last_reason = "uniform_set_create_failed"
		return
	_uniform_set = set0

	params["terrain_len"] = terrain_height.size()
	var push := _pack_push(params)
	var groups := int(ceil(float(_instance_count) / float(LOCAL_SIZE)))

	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, groups, 1, 1)
	_rd.compute_list_end()
	_last_reason = "ok"


func _pack_push(params: Dictionary) -> PackedByteArray:
	var grid: Vector3i = params.get("grid_size", Vector3i.ONE)
	var grid_origin: Vector3 = params.get("grid_origin", Vector3.ZERO)
	var voxel_size: Vector3 = params.get("voxel_size", Vector3.ONE)
	var push := PackedByteArray()
	push.resize(64)
	push.encode_s32(0, _instance_count)
	push.encode_s32(4, maxi(grid.x, 1))
	push.encode_s32(8, maxi(grid.y, 1))
	push.encode_s32(12, maxi(grid.z, 1))
	push.encode_s32(16, int(params.get("view_mode", VIEW_TARGET_COLOR)))
	push.encode_s32(20, int(params.get("terrain_len", 1)))
	push.encode_float(24, float(params.get("display_scale", 1.0)))
	push.encode_float(28, float(params.get("threshold", 0.0)))
	push.encode_float(32, grid_origin.x)
	push.encode_float(36, grid_origin.y)
	push.encode_float(40, grid_origin.z)
	push.encode_float(44, voxel_size.x)
	push.encode_float(48, voxel_size.y)
	push.encode_float(52, voxel_size.z)
	# 56 = use_index_map（原 pad0）：0 全网格（实例序 == 体素下标），非 0 走
	# instance_voxel_index[] 映射。⚠ 开了它，pick 载荷解码必须走同一张表。
	push.encode_s32(56, 1 if bool(params.get("use_index_map", false)) else 0)
	# 60 仍是对齐补白：push constant 尺寸必须是 16 的整数倍。
	push.encode_float(60, 0.0)
	return push
