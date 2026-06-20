## TargetSVLoader -- 公用 TargetSV 共享资源加载器 (GPU-first)
##
## 所有模块通过此 loader 访问 assets/target_sv/ 下的统一 TargetSV 数据。
## 序列化文件 (.rgba32f / .r32f) 是 GPU-native 字节布局，
## 可通过 upload_to_gpu() 零拷贝上传 SSBO，或通过 decode() GPU 解码。
##
## 用法:
##   const TargetSVLoader := preload("res://scripts/target_sv_loader.gd")
##   var meta   := TargetSVLoader.metadata()         # Dictionary
##   var visual := TargetSVLoader.visual_bytes()      # PackedByteArray (GPU-native)
##   var coll   := TargetSVLoader.collision_bytes()   # PackedByteArray (GPU-native)
##   var gpu    := TargetSVLoader.upload_to_gpu(compute_base)  # 直接上传 SSBO
##   var decoded := TargetSVLoader.decode()            # GPU 解码 + readback
class_name TargetSVLoader
extends RefCounted


const SHARED_DIR := "res://assets/target_sv"
const META_NAME := "target_sv_point_cloud.json"
const VISUAL_NAME := "target_sv_point_cloud_visual.rgba32f"
const COLLISION_NAME := "target_sv_point_cloud_collision.r32f"
const PREVIEW_NAME := "target_sv_point_cloud_preview.png"
const ComputeShaderBaseScript := preload("res://scripts/godot_compute_shader_base.gd")

static var _metadata: Dictionary
static var _visual_bytes: PackedByteArray
static var _collision_bytes: PackedByteArray
static var _preview_image: Image
static var _decoded: Dictionary
static var _loaded := false


static func _ensure_loaded() -> bool:
	if _loaded:
		return not _metadata.is_empty()
	_loaded = true

	var meta_path := SHARED_DIR.path_join(META_NAME)
	var file := FileAccess.open(meta_path, FileAccess.READ)
	if file == null:
		push_error("[TargetSVLoader] 缺少元数据: %s" % meta_path)
		return false

	var parsed = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary:
		_metadata = parsed
	else:
		push_error("[TargetSVLoader] 元数据 JSON 无效: %s" % meta_path)
		return false

	_visual_bytes = _read_file_bytes(str(_metadata.get("visual_path", "")))
	_collision_bytes = _read_file_bytes(str(_metadata.get("collision_path", "")))
	_preview_image = _read_image(str(_metadata.get("preview_path", "")))
	return not _metadata.is_empty()


static func _read_file_bytes(path: String) -> PackedByteArray:
	if path.is_empty():
		return PackedByteArray()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[TargetSVLoader] 缺少缓冲区: %s" % path)
		return PackedByteArray()
	return f.get_buffer(f.get_length())


static func _read_image(path: String) -> Image:
	if path.is_empty():
		return null
	var img := Image.load_from_file(path)
	if img != null:
		return img
	var texture := load(path) as Texture2D
	if texture != null:
		return texture.get_image()
	push_error("[TargetSVLoader] 无法加载预览图: %s" % path)
	return null


static func metadata() -> Dictionary:
	if _ensure_loaded():
		return _metadata.duplicate(true)
	return {}


static func visual_bytes() -> PackedByteArray:
	_ensure_loaded()
	return _visual_bytes


static func collision_bytes() -> PackedByteArray:
	_ensure_loaded()
	return _collision_bytes


static func preview_image() -> Image:
	_ensure_loaded()
	return _preview_image


static func texture_size() -> int:
	_ensure_loaded()
	return int(_metadata.get("texture_size", 1))


static func slice_count() -> int:
	_ensure_loaded()
	return int(_metadata.get("slice_count", 1))


static func voxel_count() -> int:
	return texture_size() * texture_size() * slice_count()


## 将序列化文件直接上传为 GPU SSBO，零 CPU 解码。
## compute_base: 已 ensure_device 的 GodotComputeShaderBase 实例。
## 返回 Dictionary:
##   { ok, visual_rid, collision_rid, texture_size, slice_count, voxel_count }
static func upload_to_gpu(compute_base, scope: String = ComputeShaderBaseScript.SCOPE_FRAME) -> Dictionary:
	_ensure_loaded()
	if _metadata.is_empty() or _visual_bytes.is_empty() or _collision_bytes.is_empty():
		return {"ok": false, "reason": "target_sv_data_not_loaded"}

	var ts := texture_size()
	var sc := slice_count()
	var vc := ts * ts * sc
	var expected_visual := vc * 16
	var expected_collision := vc * 4
	if _visual_bytes.size() < expected_visual or _collision_bytes.size() < expected_collision:
		return {
			"ok": false, "reason": "target_sv_buffer_size_mismatch",
			"expected_visual": expected_visual, "actual_visual": _visual_bytes.size(),
			"expected_collision": expected_collision, "actual_collision": _collision_bytes.size(),
		}

	var visual_rid: RID = compute_base.storage_buffer_from_bytes(
		_visual_bytes.slice(0, expected_visual), scope, "target_sv_visual_rgba32f")
	var collision_rid: RID = compute_base.storage_buffer_from_bytes(
		_collision_bytes.slice(0, expected_collision), scope, "target_sv_collision_r32f")
	if not visual_rid.is_valid() or not collision_rid.is_valid():
		return {"ok": false, "reason": "gpu_buffer_create_failed"}

	return {
		"ok": true,
		"visual_rid": visual_rid,
		"collision_rid": collision_rid,
		"texture_size": ts,
		"slice_count": sc,
		"voxel_count": vc,
		"visual_format": "rgba32f",
		"collision_format": "r32f",
		"visual_stride_bytes": 16,
		"collision_stride_bytes": 4,
		"source": "target_sv_loader_direct_upload",
	}


## GPU 解码 visual+collision 缓冲区并 readback 到 CPU。
## 优先 GPU 路径；GPU 不可用时回退 CPU。
static func decode() -> Dictionary:
	if not _decoded.is_empty():
		return _decoded.duplicate(true)

	_ensure_loaded()
	if _metadata.is_empty() or _visual_bytes.is_empty() or _collision_bytes.is_empty():
		_decoded = {}
		return {}

	var ts := texture_size()
	var sc := slice_count()
	var TargetSceneVoxelGeneratorScript := load("res://scripts/target_scene_voxel_generator.gd")

	var rd := RenderingServer.create_local_rendering_device()
	if rd != null:
		rd.free()
		var result: Dictionary = TargetSceneVoxelGeneratorScript.decode_target_read_buffers_gpu(
			_visual_bytes, _collision_bytes, ts, sc
		)
		if bool(result.get("valid", false)):
			_decoded = result
			return result.duplicate(true)
		push_warning("[TargetSVLoader] GPU decode failed, falling back to CPU")

	var result: Dictionary = TargetSceneVoxelGeneratorScript.decode_target_read_buffers(
		_visual_bytes, _collision_bytes, ts, sc
	)
	_decoded = result
	return result.duplicate(true)


static func reload() -> void:
	_metadata = {}
	_visual_bytes = PackedByteArray()
	_collision_bytes = PackedByteArray()
	_preview_image = null
	_decoded = {}
	_loaded = false
	_ensure_loaded()
