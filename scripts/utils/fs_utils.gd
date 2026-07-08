@tool
extends RefCounted

# 文件系统 / 资源 IO 辅助。
# 从 auto_asset_factory / terrain_initializer / 编辑器插件等处抽取的重复逻辑，避免多份实现漂移。


## 确保 path 的父目录存在（递归创建）。res:// 与 user:// 会先 globalize。
## 父目录为空或为 "." 时返回 OK；否则返回 DirAccess.make_dir_recursive_absolute 的错误码。
static func ensure_parent_dir(path: String) -> int:
	var dir := path.get_base_dir()
	if dir.is_empty() or dir == ".":
		return OK
	var abs_dir := ProjectSettings.globalize_path(dir) if dir.begins_with("res://") or dir.begins_with("user://") else dir
	return DirAccess.make_dir_recursive_absolute(abs_dir)


## 从 .raw 文件加载 RGBAF（float32 × 4 通道）纹理。
## 期望字节数 = width * height * 4 通道 * 4 字节；不匹配返回 null 并按 error_prefix 报错。
## 原 AutoAssetFactory.load_raw_texture / TerrainInitializer.load_raw_texture（近乎逐字重复）。
static func load_raw_rgbaf_texture(path: String, width: int, height: int, error_prefix: String = "FsUtils") -> ImageTexture:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var expected_size := width * height * 4 * 4
	var data := file.get_buffer(expected_size)
	file.close()
	if data.size() != expected_size:
		push_error("%s: raw texture size mismatch for %s: got %d, expected %d" % [error_prefix, path, data.size(), expected_size])
		return null
	var image := Image.create_from_data(width, height, false, Image.FORMAT_RGBAF, data)
	return ImageTexture.create_from_image(image)
