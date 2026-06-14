## TargetSVLoader -- 公用 TargetSV 共享资源加载器
##
## 所有模块通过此 loader 访问 assets/target_sv/ 下的统一 TargetSV 数据。
## 转换后的产物自动覆盖该文件夹，无需修改各模块的引用路径。
##
## 用法:
##   const TargetSVLoader := preload("res://scripts/target_sv_loader.gd")
##   var meta := TargetSVLoader.metadata()                     # 返回 Dictionary
##   var visual := TargetSVLoader.visual_bytes()               # 返回 PackedByteArray
##   var collision := TargetSVLoader.collision_bytes()         # 返回 PackedByteArray
##   var preview := TargetSVLoader.preview_image()             # 返回 Image
##   var decoded := TargetSVLoader.decode()                    # 返回 decoded Dictionary
class_name TargetSVLoader
extends RefCounted


const SHARED_DIR := "res://assets/target_sv"
const META_NAME := "target_sv_point_cloud.json"
const VISUAL_NAME := "target_sv_point_cloud_visual.rgba32f"
const COLLISION_NAME := "target_sv_point_cloud_collision.r32f"
const PREVIEW_NAME := "target_sv_point_cloud_preview.png"

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


## 返回 TargetSV 元数据 Dictionary
static func metadata() -> Dictionary:
	if _ensure_loaded():
		return _metadata.duplicate(true)
	return {}


## 返回 visual 缓冲区（rgba32f, 每个体素 16 字节）
static func visual_bytes() -> PackedByteArray:
	_ensure_loaded()
	return _visual_bytes


## 返回 collision 缓冲区（r32f, 每个体素 4 字节）
static func collision_bytes() -> PackedByteArray:
	_ensure_loaded()
	return _collision_bytes


## 返回预览图 Image，失败返回 null
static func preview_image() -> Image:
	_ensure_loaded()
	return _preview_image


## 使用 TargetSceneVoxelGenerator 解码 visual+collision 缓冲区
## 返回 Dictionary: { valid: bool, target_occupancy: PackedFloat32Array, target_color: PackedColorArray, ... }
static func decode() -> Dictionary:
	if not _decoded.is_empty():
		return _decoded.duplicate(true)

	_ensure_loaded()
	if _metadata.is_empty() or _visual_bytes.is_empty() or _collision_bytes.is_empty():
		_decoded = {}
		return {}

	var texture_size := int(_metadata.get("texture_size", 1))
	var slice_count := int(_metadata.get("slice_count", 1))
	var TargetSceneVoxelGeneratorScript := load("res://scripts/target_scene_voxel_generator.gd")
	var result: Dictionary = TargetSceneVoxelGeneratorScript.decode_target_read_buffers(
		_visual_bytes, _collision_bytes, texture_size, slice_count
	)
	_decoded = result
	return result.duplicate(true)


## 强制重新加载（点云更新后调用）
static func reload() -> void:
	_metadata = {}
	_visual_bytes = PackedByteArray()
	_collision_bytes = PackedByteArray()
	_preview_image = null
	_decoded = {}
	_loaded = false
	_ensure_loaded()