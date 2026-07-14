class_name SceneVoxelFieldBuilder

## committer 的 field 构建工具箱(原 SceneVoxelCollisionField，2026-07-12 更名归位——
## collision 已与 color/complexity 同级为普通逐体素通道，不再独占一个"子系统"名义)。
## V1 后内容（2D occupancy/slices 盖章机器已退役）：
## - terrain-base collision：2D 底图存储/重采样(常驻碰撞场种子的分辨率适配) + 3D 体积场生成
##   (tile_store 碰撞常驻场种子)；
## - write-spec collision 点采样层规范化/rec 富化(_stamp_shared_field_layer(s)/_make_source_collision)
##   与记录→tile 摘要 merge(merge_sv_collision_records pass)。
## committer 通过同名转发属性(_terrain_base_collision_field)对外暴露。
extends "res://scripts/godot_compute_shader_base.gd"

const VOXEL_OCCUPIED_EPSILON := VoxelGeneral.VOXEL_OCCUPIED_EPSILON

## --- push-constant schemas (std430; migrated from manual encode sequences) ---
const RESAMPLE_COLLISION_PUSH := [
	["dst_x", "int"], ["dst_y", "int"], ["src_w", "int"], ["src_h", "int"],
	["base_res", "int"], ["_pad0", "int"], ["_pad1", "int"], ["_pad2", "int"],
]
const MERGE_SV_COLLISION_PUSH := [
	["xz_res", "int"], ["total_slices", "int"], ["voxel_count", "int"], ["record_count", "int"],
]
const TERRAIN_COLLISION_VOLUME_PUSH := [
	["xz_res", "int"], ["total_slices", "int"], ["src_w", "int"], ["src_h", "int"],
	["voxel_count", "int"], ["epsilon", "float"], ["_pad0", "float"], ["_pad1", "float"],
]

const SharedPropertyTypeScript := preload("res://scripts/shared_property_type.gd")
const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")
const VoxelGeneralScript := preload("res://scripts/utils/voxel_general.gd")


## committer 反向引用(读 grid_size/_base_res/_sv_dirty，调 _volume_px_from_base)。
var _committer: SceneVoxelCommitter = null
var _gpu_ready: bool = false

## --- terrain-base collision field 真实存储(从 committer 迁入；committer 留转发属性) ---
var _terrain_base_collision_field: Image

## 本组件自有的线性采样器(collision 重采样/terrain 种子 GPU 采样用)
var _sampler: RID

## --- collision compute shader 管线(本组件拥有) ---
var _shader_merge_sv_collision_records: RID
var _pipeline_merge_sv_collision_records: RID


func setup(committer, base_resolution: int) -> void:
	_committer = committer
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

func teardown() -> void:
	dispose()
	_committer = null

## --- 迁移自 committer 的 collision 函数 ---
func _create_collision_image(resolution: int) -> Image:

	return VoxelGeneralScript.create_r32_image(resolution)

## 规范化共享场层列表。collision 只有 per-voxel 点采样一种形态
## （collision_from_fields → normalize_collision_samples 已在上游过滤并警告非点条目，
## 旧 cylinder/box 分支 2026-07-12 移除）。
func _normalize_shared_field_layers(field_layers: Array, base_px: Vector2i = Vector2i(-1, -1)) -> Array[Dictionary]:

	var result: Array[Dictionary] = []

	var canonical_layers: Array[Dictionary] = SharedPropertyTypeScript.collision_from_fields({SharedPropertyTypeScript.COLLISION_KEY: field_layers})

	for collision_entry in canonical_layers:

		if not bool(collision_entry.get("enabled", true)):

			continue

		var local: Vector3i = collision_entry["voxel"]

		collision_entry["local_pos"] = local

		collision_entry["radius_px"] = maxi(int(collision_entry.get("radius_px", 0)), 0)

		collision_entry["effective_radius"] = 0.0

		if not collision_entry.has("slice_index"):

			collision_entry["slice_index"] = local.y

		if base_px.x >= 0 and base_px.y >= 0:

			collision_entry["base_pixel"] = VoxelGeneralScript.collision_layer_base_px(base_px, collision_entry, _committer._base_res)

		result.append(collision_entry)

	return result

## 碰撞记录共享元数据推导（_make_source_collision 与 _stamp_shared_field_layer 共用）。
## radius_px 恒为 0：collision 是逐体素点采样，记录不携带形状半径。
## source_voxel_type/record_id 两处回退序不同，均由调用方算好传入。

func _collision_record_meta(layer: Dictionary, rec: Dictionary, collision_strength: float, layer_base_px: Vector2i, voxel_px: Vector2i, source_voxel_type: String, record_id: String) -> Dictionary:

	return {
		"collision_strength": collision_strength,
		"base_pixel": layer_base_px,
		"voxel_xz": voxel_px,
		"radius_px": 0,
		"collision_shape": str(layer.get("shape", "point")),
		"collision_radius": layer.get("radius", 0.0),
		"effective_radius": layer.get("effective_radius", 0.0),
		"source_voxel_type": source_voxel_type,
		"record_id": record_id,
		"instance_id": int(rec.get("instance_id", rec.get("auto_instance_id", rec.get("instance_mesh_id", rec.get("mesh_instance_id", 0))))),
	}

## 根据基础像素与碰撞层生成源碰撞层列表，跳过目标体素类型

func _make_source_collision(base_px: Vector2i, collision_layers: Array, rec: Dictionary = {}) -> Array[Dictionary]:

	var updated: Array[Dictionary] = []

	var source_type := str(rec.get("source_voxel_type", ""))

	if source_type == "TargetSceneVoxel":

		return updated

	var xz_res := maxi(_committer.grid_size.x, 1)

	var record_id := str(rec.get("id", ""))

	var layers := _normalize_shared_field_layers(collision_layers, base_px)

	for layer in layers:

		var collision_strength := clampf(float(layer.get("collision_strength", 1.0)), 0.0, 1.0)

		var layer_base_px := VoxelGeneralScript.collision_layer_base_px(base_px, layer, _committer._base_res)

		var source_layer := layer.duplicate(true)

		source_layer.merge(_collision_record_meta(
			layer, rec, collision_strength, layer_base_px,
			_committer._volume_px_from_base(layer_base_px, xz_res),
			source_type, record_id
		), true)

		source_layer["volume_xz_resolution"] = xz_res

		source_layer["collision_buffer_applied"] = false

		updated.append(source_layer)

	return updated

## 重采样碰撞场到指定 XZ 分辨率，GPU 失败时返回空白图像
## （V1 保留最小版：tile_store._seed_collision_field_base_bytes 的 base_res→grid 分辨率适配仍需要）

func _resample_collision_field(source_img: Image, xz_res: int) -> Image:
	var gpu_img := _resample_collision_field_gpu(source_img, xz_res)
	if gpu_img != null and not gpu_img.is_empty():
		return gpu_img
	var img := _create_collision_image(maxi(xz_res, 1))
	if source_img != null and not source_img.is_empty() and xz_res > 0:
		push_error("[SceneVoxelCommitter] Collision field resample GPU compute failed")
	return img


## GPU 将碰撞场重采样到目标 XZ 分辨率

func _resample_collision_field_gpu(source_img: Image, xz_res: int) -> Image:
	if source_img == null or source_img.is_empty() or xz_res <= 0:
		return null
	if not _gpu_ready or _rd == null or not _sampler.is_valid():
		return null

	var shader := load_compute_shader("res://shaders/resample_collision_field.glsl", SCOPE_FRAME, "resample_collision_field")
	var pipeline := create_compute_pipeline(shader, SCOPE_FRAME, "resample_collision_field")
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
		base_res = _committer._base_res,
	})

	var groups := dispatch_groups_2d(xz_res, xz_res, 32, 32)
	if not _gpu_dispatch_and_sync(pipeline, [set0, set1], push, groups):
		gc_frame()
		return null

	var data := _rd.texture_get_data(out_tex, 0)
	var result := Image.create_from_data(xz_res, xz_res, false, Image.FORMAT_RF, data)
	gc_frame()
	return result


## 盖印单个共享场层：collision 是逐体素点采样。V1 后只做 rec 富化半边
## （规范化 + 强度钳制 + grid 地址字段）；2D cell map 直写已退役——常驻场写入由
## committer 的 collision-only field 散射记录承担，tile 脏标记由 committer 直调 3D API。
## 返回更新后的层字典。

func _stamp_shared_field_layer(base_px: Vector2i, source_layer: Dictionary, rec: Dictionary = {}) -> Dictionary:

	var normalized := _normalize_shared_field_layers([source_layer], base_px)

	if normalized.is_empty():

		return {}

	var layer := normalized[0]

	var collision_strength := clampf(float(layer.get("collision_strength", 1.0)), 0.0, 1.0)

	layer["collision_strength"] = collision_strength

	var layer_base_px := VoxelGeneralScript.collision_layer_base_px(base_px, layer, _committer._base_res)

	var xz_res := maxi(_committer.grid_size.x, 1)

	layer["base_pixel"] = layer_base_px

	layer["voxel_xz"] = _committer._volume_px_from_base(layer_base_px, xz_res)

	layer["volume_xz_resolution"] = xz_res

	layer["collision_buffer_applied"] = true

	return layer

## 盖印多个共享场层，返回更新后的层列表

func _stamp_shared_field_layers(base_px: Vector2i, field_layers: Array, rec: Dictionary = {}) -> Array[Dictionary]:

	var updated: Array[Dictionary] = []

	for raw_layer in field_layers:

		if not raw_layer is Dictionary:

			continue

		var stamped := _stamp_shared_field_layer(base_px, raw_layer, rec)

		if not stamped.is_empty():

			updated.append(stamped)

	return updated

## ─── Query & Debug ───

## 设置地形基础碰撞场（TerrainBase 层，常驻碰撞场的种子输入）并标记 SV 脏

func set_terrain_base_collision_field(base_collision: Image) -> void:

	_terrain_base_collision_field = _resample_collision_field(base_collision, _committer._base_res)

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

	push_error("[SceneVoxelCommitter] SV collision summary record merge compute failed")
	return field

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

	var set0 := create_uniform_set([
		make_storage_uniform(0, field_buffer),
		make_storage_uniform(1, record_buffer),
	], _shader_merge_sv_collision_records, 0, SCOPE_PASS, "sv_collision_record_summary_merge")

	if not set0.is_valid():
		gc_scope(output_buffer_scope)
		gc_frame()
		return {}

	var push := PushConstantLayout.new(MERGE_SV_COLLISION_PUSH).pack({
		xz_res = xz_res,
		total_slices = total_slices,
		voxel_count = voxel_count,
		record_count = record_count,
	})

	var groups := dispatch_groups_1d(record_count, 64)
	if not _gpu_dispatch_and_sync(_pipeline_merge_sv_collision_records, [set0], push, groups):
		gc_scope(output_buffer_scope)
		gc_frame()
		return {}

	gc_frame()
	return result

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

	var set0 := create_uniform_set([
		make_storage_uniform(0, field_buffer),
		make_storage_uniform(1, record_buffer),
	], _shader_merge_sv_collision_records, 0, SCOPE_PASS, "merge_sv_collision_records")

	if not set0.is_valid():

		gc_frame()

		return PackedFloat32Array()

	var push := PushConstantLayout.new(MERGE_SV_COLLISION_PUSH).pack({
		xz_res = xz_res,
		total_slices = total_slices,
		voxel_count = voxel_count,
		record_count = record_count,
	})

	var groups := dispatch_groups_1d(record_count, 64)

	if not _gpu_dispatch_and_sync(_pipeline_merge_sv_collision_records, [set0], push, groups):
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
	var voxel_count := xz_res * xz_res * total_slices
	if terrain_base_img == null or terrain_base_img.is_empty() or voxel_count <= 0:
		return PackedFloat32Array()
	if not _gpu_ready or _rd == null or not _sampler.is_valid():
		return PackedFloat32Array()

	var shader := load_compute_shader("res://shaders/terrain_collision_volume.glsl", SCOPE_FRAME, "terrain_collision_volume")
	var pipeline := create_compute_pipeline(shader, SCOPE_FRAME, "terrain_collision_volume")
	if not shader.is_valid() or not pipeline.is_valid():
		gc_frame()
		return PackedFloat32Array()

	var src_tex := upload_texture_2d(
		terrain_base_img,
		RenderingDevice.DATA_FORMAT_R32_SFLOAT,
		Image.FORMAT_RF,
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT,
		SCOPE_FRAME,
		"terrain_collision_volume_src_r32f"
	)
	var output_buffer := storage_buffer_zero(
		SceneVoxelTileCodecScript.u32_field_byte_count(voxel_count),
		SCOPE_FRAME,
		"terrain_collision_volume_out_u32"
	)
	if not src_tex.is_valid() or not output_buffer.is_valid():
		gc_frame()
		return PackedFloat32Array()

	var set0 := create_uniform_set([
		make_sampler_uniform(0, _sampler, src_tex),
		make_storage_uniform(1, output_buffer),
	], shader, 0, SCOPE_PASS, "terrain_collision_volume")
	if not set0.is_valid():
		gc_frame()
		return PackedFloat32Array()

	var push := PushConstantLayout.new(TERRAIN_COLLISION_VOLUME_PUSH).pack({
		xz_res = xz_res,
		total_slices = total_slices,
		src_w = terrain_base_img.get_width(),
		src_h = terrain_base_img.get_height(),
		voxel_count = voxel_count,
		epsilon = VOXEL_OCCUPIED_EPSILON,
	})

	var groups := dispatch_groups_1d(voxel_count, 64)
	if not _gpu_dispatch_and_sync(pipeline, [set0], push, groups):
		gc_frame()
		return PackedFloat32Array()

	var output_bytes := _rd.buffer_get_data(output_buffer, 0, SceneVoxelTileCodecScript.u32_field_byte_count(voxel_count))
	var field := SceneVoxelTileCodecScript.decode_collision_field_u32_bytes(output_bytes, voxel_count)
	gc_frame()
	return field
