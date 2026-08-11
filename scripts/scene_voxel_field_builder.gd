class_name SceneVoxelFieldBuilder

## committer 的 field 构建工具箱(原 SceneVoxelCollisionField，2026-07-12 更名归位——
## collision 已与 color/complexity 同级为普通逐体素通道，不再独占一个"子系统"名义)。
## V1 后内容（2D occupancy/slices 盖章机器已退役；write-spec collision 层规范化/rec 富化簇
## 随 CPU 入口盖章链于 2026-08-10 删除）：
## - terrain-base collision：2D 底图存储/重采样(常驻碰撞场种子的分辨率适配) + 3D 体积场生成
##   (tile_store 碰撞常驻场种子)；
## - 记录→tile 摘要 merge(merge_sv_collision_records pass；现役输入为空记录集的契约形状)。
## committer 通过同名转发属性(_terrain_base_collision_field)对外暴露。
extends "res://scripts/godot_compute_shader_base.gd"

const VOXEL_OCCUPIED_EPSILON := VoxelGeneral.VOXEL_OCCUPIED_EPSILON

## --- push-constant schemas (std430; migrated from manual encode sequences) ---
const RESAMPLE_COLLISION_PUSH := [
	["dst_x", "int"], ["dst_y", "int"], ["src_w", "int"], ["src_h", "int"],
	["base_res", "int"], ["_pad0", "int"], ["_pad1", "int"], ["_pad2", "int"],
]
## 网格用规范三元组（grid_x/y/z），与 scatter/pick/score 同一套索引式；
## voxel_count 在着色器里由 gx*gy*gz 导出，不再单独占一个字。
## ⚠ 本文件其余部分仍以 (xz_res, total_slices) 两个数流转 —— 那是 SceneSV 侧最后一处
## 「XZ 必须方形」的 CPU 词汇，收口点集中在下面两个 pack 调用（Vector3i(xz, slices, xz)）。
const MERGE_SV_COLLISION_PUSH := [
	["grid_x", "int"], ["grid_y", "int"], ["grid_z", "int"], ["record_count", "int"],
]
const TERRAIN_COLLISION_VOLUME_PUSH := [
	["grid_x", "int"], ["grid_y", "int"], ["grid_z", "int"], ["src_w", "int"],
	["src_h", "int"], ["epsilon", "float"], ["_pad0", "float"], ["_pad1", "float"],
]

const SharedPropertyTypeScript := preload("res://scripts/shared_property_type.gd")
const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")
const VoxelGeneralScript := preload("res://scripts/utils/voxel_general.gd")


## committer 只提供 stamp 协调回调；网格元数据直接读取 SPA owner。
var _committer: SceneVoxelCommitter = null
var _grid_owner: Object = null
var _gpu_ready: bool = false

## --- terrain-base collision field 真实存储(从 committer 迁入；committer 留转发属性) ---
var _terrain_base_collision_field: Image

## 本组件自有的线性采样器(collision 重采样/terrain 种子 GPU 采样用)
var _sampler: RID

## --- collision compute shader 管线(本组件拥有) ---
var _shader_merge_sv_collision_records: RID
var _pipeline_merge_sv_collision_records: RID


func setup(committer, grid_owner: Object = null) -> void:
	_committer = committer
	_grid_owner = grid_owner
	log_name = "SceneVoxelFieldBuilder"
	_init_collision_gpu()

func _init_collision_gpu() -> void:
	_sampler = create_linear_sampler()
	_shader_merge_sv_collision_records = load_compute_shader("res://shaders/merge_sv_collision_records.glsl")
	if _shader_merge_sv_collision_records.is_valid():
		_pipeline_merge_sv_collision_records = create_compute_pipeline(_shader_merge_sv_collision_records)
	_gpu_ready = _sampler.is_valid() \
		and _shader_merge_sv_collision_records.is_valid() \
		and _pipeline_merge_sv_collision_records.is_valid()
	if not _gpu_ready:
		# 以前静默留 _gpu_ready=false：之后每条 GPU 路径都返回 null/空，
		# 表现为"碰撞场莫名全空"，真正的着色器编译失败无人知晓。
		push_error("[SceneVoxelFieldBuilder] _init_collision_gpu: GPU 资源未就绪（sampler=%s shader=%s pipeline=%s，shader=res://shaders/merge_sv_collision_records.glsl）" % [str(_sampler.is_valid()), str(_shader_merge_sv_collision_records.is_valid()), str(_pipeline_merge_sv_collision_records.is_valid())])
		assert(false, "SceneVoxelFieldBuilder: collision GPU resources not ready")

func teardown() -> void:
	dispose()
	_committer = null
	_grid_owner = null

func _grid_size() -> Vector3i:
	if _grid_owner != null:
		return _grid_owner.grid_size
	if _committer != null:
		return _committer.grid_size
	# 以前静默返回 Vector3i.ONE：所有 xz_res/体素数换算按 1x1x1 走，场内容全错位。
	push_error("[SceneVoxelFieldBuilder] _grid_size(): _grid_owner 与 _committer 均为空 —— 无法确定体素网格尺寸（曾静默降级为 Vector3i.ONE）")
	assert(false, "SceneVoxelFieldBuilder: no grid size owner (_grid_owner/_committer both null)")
	return Vector3i.ZERO

func _base_resolution() -> int:
	if _grid_owner != null:
		return int(_grid_owner.base_resolution)
	if _committer != null:
		return _committer._base_res
	# 以前静默返回 1：base_px→volume_px 的换算比例整体失真。
	push_error("[SceneVoxelFieldBuilder] _base_resolution(): _grid_owner 与 _committer 均为空 —— 无法确定基础分辨率（曾静默降级为 1）")
	assert(false, "SceneVoxelFieldBuilder: no base resolution owner (_grid_owner/_committer both null)")
	return 0

## 重采样碰撞场到指定 XZ 分辨率
## （V1 保留最小版：tile_store._seed_collision_field_base_bytes 的 base_res→grid 分辨率适配仍需要）。
## 源图为 null/空 或 xz_res<=0 = 没有可重采样的内容，返回空白图（合法的"无地形基底"）；
## 源图有效但 GPU 重采样失败则硬失败返回 null —— 以前这里 push_error 后仍返回一张
## 空白图，调用方拿到的是"全无碰撞的地形"，错误被洗成看似正常的数据。

func _resample_collision_field(source_img: Image, xz_res: int) -> Image:
	if source_img == null or source_img.is_empty() or xz_res <= 0:
		return VoxelGeneralScript.create_r32_image(maxi(xz_res, 1))
	var gpu_img := _resample_collision_field_gpu(source_img, xz_res)
	if gpu_img != null and not gpu_img.is_empty():
		return gpu_img
	push_error("[SceneVoxelFieldBuilder] _resample_collision_field: 碰撞场 GPU 重采样失败（源 %dx%d → 目标 %dx%d）—— 拒绝返回空白图顶替" % [source_img.get_width(), source_img.get_height(), xz_res, xz_res])
	assert(false, "SceneVoxelFieldBuilder: collision field resample GPU compute failed")
	return null


## GPU 将碰撞场重采样到目标 XZ 分辨率

func _resample_collision_field_gpu(source_img: Image, xz_res: int) -> Image:
	if source_img == null or source_img.is_empty() or xz_res <= 0:
		return null
	if not _gpu_ready or _rd == null or not _sampler.is_valid():
		return null

	var kernel := ensure_shader_kernel("res://shaders/resample_collision_field.glsl", "resample_collision_field")
	var shader: RID = kernel.get("shader", RID())
	var pipeline: RID = kernel.get("pipeline", RID())
	if not shader.is_valid() or not pipeline.is_valid():
		gc_frame()
		return null

	var src_tex := upload_texture_2d(
		source_img,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		Image.FORMAT_RF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		SCOPE_FRAME,
		"resample_collision_src_r32f"
	)
	var out_tex := create_rw_texture_2d(
		xz_res,
		xz_res,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT,
		SCOPE_FRAME,
		"resample_collision_out_r32f"
	)
	if not src_tex.is_valid() or not out_tex.is_valid():
		gc_frame()
		return null

	var set0 := create_uniform_set([
		make_sampler_uniform(0, _sampler, src_tex),
	], shader, 0, SCOPE_PASS, "resample_collision_src")
	var set1 := create_uniform_set([
		make_image_uniform(0, out_tex),
	], shader, 1, SCOPE_PASS, "resample_collision_out")
	if not set0.is_valid() or not set1.is_valid():
		gc_frame()
		return null

	var push := PushConstantLayout.new(RESAMPLE_COLLISION_PUSH).pack({
		dst_x = xz_res,
		dst_y = xz_res,
		src_w = source_img.get_width(),
		src_h = source_img.get_height(),
		base_res = _base_resolution(),
	})

	var groups := dispatch_groups_2d(xz_res, xz_res, 32, 32)
	if not _gpu_dispatch_and_sync(pipeline, [set0, set1], push, groups):
		gc_frame()
		return null

	var data := _rd.texture_get_data(out_tex, 0)
	var result := Image.create_from_data(xz_res, xz_res, false, Image.FORMAT_RF, data)
	gc_frame()
	return result


## ─── Query & Debug ───

## 设置地形基础碰撞场（TerrainBase 层，常驻碰撞场的种子输入）并标记 SV 脏

func set_terrain_base_collision_field(base_collision: Image) -> void:

	var resampled := _resample_collision_field(base_collision, _base_resolution())

	if resampled == null:
		# _resample_collision_field 已 push_error/assert；此处只做硬失败传播：
		# 不把一张空白图写成"新的地形基底"（那等于静默宣布整张地形没有碰撞）。
		return

	_terrain_base_collision_field = resampled

	_committer._sv_dirty = true

## 生成仅含碰撞记录摘要的碰撞场(不含地形基底)

func _make_sv_collision_record_summary_field(collision: Dictionary, xz_res: int, total_slices: int) -> PackedFloat32Array:
	var voxel_count := xz_res * xz_res * total_slices
	var field := PackedFloat32Array()
	field.resize(maxi(voxel_count, 0))
	if voxel_count <= 0 or collision.is_empty():
		return field

	var merged_field := _merge_sv_collision_records_gpu(field, collision, xz_res, total_slices)
	if merged_field.size() == voxel_count:
		return merged_field

	# 以前失败后返回全零 field：tile 摘要会把所有有碰撞的格子报告成空。
	push_error("[SceneVoxelFieldBuilder] _make_sv_collision_record_summary_field: 碰撞记录合并失败（xz_res=%d total_slices=%d 记录数=%d 期望 %d 个体素，实际得到 %d）—— 拒绝返回全零场" % [xz_res, total_slices, collision.size(), voxel_count, merged_field.size()])
	assert(false, "SceneVoxelFieldBuilder: sv collision summary record merge failed")
	return PackedFloat32Array()

## 在 GPU 上构建碰撞记录摘要缓冲并保留输出 RID

func _make_sv_collision_record_summary_gpu_buffer(
	collision: Dictionary,
	xz_res: int,
	total_slices: int,
	output_buffer_scope: String
) -> Dictionary:
	var voxel_count := xz_res * xz_res * total_slices
	if voxel_count <= 0 or output_buffer_scope.is_empty():
		return {}
	if not _gpu_ready or _rd == null:
		return {}

	var field_buffer := storage_buffer_zero(
		SceneVoxelTileCodecScript.u32_field_byte_count(voxel_count),
		output_buffer_scope,
		"sv_collision_record_summary_u32"
	)
	if not field_buffer.is_valid():
		return {}

	var result := {
		"collision_field_buffer": field_buffer,
		"voxel_count": voxel_count,
	}
	if collision.is_empty():
		return result

	var collision_records := _pack_sv_collision_records(collision, xz_res, total_slices)
	var record_count := int(collision_records.size() / 4)
	if record_count <= 0:
		return result

	if not _shader_merge_sv_collision_records.is_valid() or not _pipeline_merge_sv_collision_records.is_valid():
		gc_scope(output_buffer_scope)
		return {}

	var record_buffer := storage_buffer_from_floats(collision_records, SCOPE_FRAME, "sv_collision_record_summary_merge_records")
	if not record_buffer.is_valid():
		gc_scope(output_buffer_scope)
		gc_frame()
		return {}

	if not _dispatch_merge_sv_collision_records(
			field_buffer, record_buffer, xz_res, total_slices, voxel_count, record_count,
			"sv_collision_record_summary_merge"):
		gc_scope(output_buffer_scope)
		gc_frame()
		return {}

	gc_frame()
	return result


## merge_sv_collision_records 的共享派发序列（uniform set → push 打包 → 1D 组数 → dispatch）。
## 本文件两个调用点（record summary 与 field merge）此前逐字重复该序列；
## 二者唯一的差异是 uniform set 的调试标签（set_label 参数）与各自的失败清理策略，
## 后者仍留在调用点：本函数只返回 bool，不做任何 gc_scope / gc_frame。
## 绑定顺序（0 = field, 1 = records）、push 四字段取值与 groups 计算在两处本就完全一致。
func _dispatch_merge_sv_collision_records(
	field_buffer: RID,
	record_buffer: RID,
	xz_res: int,
	total_slices: int,
	voxel_count: int,
	record_count: int,
	set_label: String
) -> bool:
	var set0 := create_uniform_set([
		make_storage_uniform(0, field_buffer),
		make_storage_uniform(1, record_buffer),
	], _shader_merge_sv_collision_records, 0, SCOPE_PASS, set_label)
	if not set0.is_valid():
		return false

	# (xz_res, total_slices) → 规范网格：XZ 方形是**本文件的** CPU 假设，在这里显式写出来，
	# 而不是编进着色器的寻址式里。
	var push := PushConstantLayout.new(MERGE_SV_COLLISION_PUSH).pack({
		grid_x = xz_res,
		grid_y = total_slices,
		grid_z = xz_res,
		record_count = record_count,
	})

	var groups := dispatch_groups_1d(record_count, 64)
	return _gpu_dispatch_and_sync(_pipeline_merge_sv_collision_records, [set0], push, groups)

## 将碰撞字典打包为 GPU 合并所需的扁平浮点记录数组

func _pack_sv_collision_records(collision: Dictionary, xz_res: int, total_slices: int) -> PackedFloat32Array:

	var records := PackedFloat32Array()

	for key in collision.keys():

		var collision_cell = collision[key]

		if not collision_cell is Dictionary:

			continue

		var voxel := collision_cell as Dictionary

		var collision_strength := clampf(float(voxel.get("collision_strength", 0.0)), 0.0, 1.0)

		if collision_strength <= VOXEL_OCCUPIED_EPSILON:

			continue

		var voxel_xz = voxel.get("voxel_xz", Vector2i.ZERO)

		if not voxel_xz is Vector2i:

			continue

		var px: Vector2i = voxel_xz

		var slice_index := int(voxel.get("slice_index", 0))

		if px.x < 0 or px.x >= xz_res or px.y < 0 or px.y >= xz_res or slice_index < 0 or slice_index >= total_slices:

			continue

		records.append(float(px.x))
		records.append(float(px.y))
		records.append(float(slice_index))
		records.append(collision_strength)

	return records

## 在 GPU 上将碰撞记录合并进基础碰撞场并回读结果

func _merge_sv_collision_records_gpu(base_field: PackedFloat32Array, collision: Dictionary, xz_res: int, total_slices: int) -> PackedFloat32Array:

	var voxel_count := xz_res * xz_res * total_slices

	if voxel_count <= 0 or base_field.size() != voxel_count:

		return PackedFloat32Array()

	var collision_records := _pack_sv_collision_records(collision, xz_res, total_slices)

	var record_count := int(collision_records.size() / 4)

	if record_count <= 0:

		return base_field

	if not _gpu_ready or _rd == null or not _shader_merge_sv_collision_records.is_valid() or not _pipeline_merge_sv_collision_records.is_valid():

		return PackedFloat32Array()

	var field_buffer := storage_buffer_from_bytes(
		SceneVoxelTileCodecScript.pack_collision_field_u32_bytes(base_field, voxel_count),
		SCOPE_FRAME,
		"sv_collision_field_merge_u32"
	)

	var record_buffer := storage_buffer_from_floats(collision_records, SCOPE_FRAME, "sv_collision_record_merge")

	if not field_buffer.is_valid() or not record_buffer.is_valid():

		gc_frame()

		return PackedFloat32Array()

	if not _dispatch_merge_sv_collision_records(
			field_buffer, record_buffer, xz_res, total_slices, voxel_count, record_count,
			"merge_sv_collision_records"):
		gc_frame()
		return PackedFloat32Array()

	var output_bytes := _rd.buffer_get_data(field_buffer, 0, SceneVoxelTileCodecScript.u32_field_byte_count(voxel_count))

	var merged_field := SceneVoxelTileCodecScript.decode_collision_field_u32_bytes(output_bytes, voxel_count)

	gc_frame()

	return merged_field


## 生成地形基础碰撞体素场,失败时返回空场

func _make_terrain_base_collision_volume_field(terrain_base_img: Image, xz_res: int, total_slices: int) -> PackedFloat32Array:
	if terrain_base_img == null or terrain_base_img.is_empty():
		var empty_field := PackedFloat32Array()
		empty_field.resize(maxi(xz_res * xz_res * total_slices, 0))
		return empty_field

	var gpu_field := _make_terrain_base_collision_volume_field_gpu(terrain_base_img, xz_res, total_slices)
	if gpu_field.is_empty() and xz_res * xz_res * total_slices > 0:
		push_error("[SceneVoxelCommitter] Terrain collision volume compute failed")
	return gpu_field


## 用 GPU compute 着色器从地形图像生成三维碰撞体素场

func _make_terrain_base_collision_volume_field_gpu(terrain_base_img: Image, xz_res: int, total_slices: int) -> PackedFloat32Array:
	var output_bytes := _make_terrain_base_collision_volume_bytes_gpu(
		terrain_base_img, xz_res, total_slices)
	var voxel_count := xz_res * xz_res * total_slices
	if output_bytes.size() != SceneVoxelTileCodecScript.u32_field_byte_count(voxel_count):
		return PackedFloat32Array()
	return SceneVoxelTileCodecScript.decode_collision_field_u32_bytes(output_bytes, voxel_count)


## Generates terrain collision volume bytes in the resident u32 field format.
func _make_terrain_base_collision_volume_bytes_gpu(terrain_base_img: Image, xz_res: int, total_slices: int) -> PackedByteArray:
	var voxel_count := xz_res * xz_res * total_slices
	if terrain_base_img == null or terrain_base_img.is_empty() or voxel_count <= 0:
		return PackedByteArray()
	if not _gpu_ready or _rd == null or not _sampler.is_valid():
		return PackedByteArray()
	var output_buffer := storage_buffer_uninitialized(
		SceneVoxelTileCodecScript.u32_field_byte_count(voxel_count),
		SCOPE_FRAME,
		"terrain_collision_volume_out_u32"
	)
	if not output_buffer.is_valid():
		gc_frame()
		return PackedByteArray()
	if not _dispatch_terrain_base_collision_volume_gpu(
			terrain_base_img, xz_res, total_slices, output_buffer):
		gc_frame()
		return PackedByteArray()
	var output_bytes := _rd.buffer_get_data(
		output_buffer, 0, SceneVoxelTileCodecScript.u32_field_byte_count(voxel_count))
	gc_frame()
	return output_bytes


## Writes the complete terrain collision volume into a caller-owned storage buffer.
func _write_terrain_base_collision_volume_buffer_gpu(
		terrain_base_img: Image,
		xz_res: int,
		total_slices: int,
		output_buffer: RID
) -> bool:
	var ok := _dispatch_terrain_base_collision_volume_gpu(
		terrain_base_img, xz_res, total_slices, output_buffer)
	gc_frame()
	return ok


func _dispatch_terrain_base_collision_volume_gpu(
		terrain_base_img: Image,
		xz_res: int,
		total_slices: int,
		output_buffer: RID
) -> bool:
	var voxel_count := xz_res * xz_res * total_slices
	if terrain_base_img == null or terrain_base_img.is_empty() or voxel_count <= 0:
		return false
	if not _gpu_ready or _rd == null or not _sampler.is_valid() or not output_buffer.is_valid():
		return false

	var kernel := ensure_shader_kernel("res://shaders/terrain_collision_volume.glsl", "terrain_collision_volume")
	var shader: RID = kernel.get("shader", RID())
	var pipeline: RID = kernel.get("pipeline", RID())
	if not shader.is_valid() or not pipeline.is_valid():
		return false

	var src_tex := upload_texture_2d(
		terrain_base_img,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		Image.FORMAT_RF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		SCOPE_FRAME,
		"terrain_collision_volume_src_r32f"
	)
	if not src_tex.is_valid() or not output_buffer.is_valid():
		return false

	var set0 := create_uniform_set([
		make_sampler_uniform(0, _sampler, src_tex),
		make_storage_uniform(1, output_buffer),
	], shader, 0, SCOPE_PASS, "terrain_collision_volume")
	if not set0.is_valid():
		return false

	# 同 MERGE_SV_COLLISION_PUSH：XZ 方形是本文件的 CPU 假设，显式写在这里。
	var push := PushConstantLayout.new(TERRAIN_COLLISION_VOLUME_PUSH).pack({
		grid_x = xz_res,
		grid_y = total_slices,
		grid_z = xz_res,
		src_w = terrain_base_img.get_width(),
		src_h = terrain_base_img.get_height(),
		epsilon = VOXEL_OCCUPIED_EPSILON,
	})

	var groups := dispatch_groups_1d(voxel_count, 64)
	return _gpu_dispatch_and_sync(pipeline, [set0], push, groups)
