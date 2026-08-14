## TargetSVLoader -- 公用 TargetSV 共享资源加载器 (GPU-first)
##
## 所有模块通过此 loader 访问 assets/target_sv/ 下的统一 TargetSV 数据。
## 序列化文件 (.rgba8 / .r8) 是 canonical 8bit GPU-native 字节布局，经 decode() GPU 解码。
##
## 用法:
##   const TargetSVLoader := preload("res://scripts/target_sv_loader.gd")
##   var meta   := TargetSVLoader.metadata()         # Dictionary
##   var visual := TargetSVLoader.visual_bytes()      # PackedByteArray (GPU-native)
##   var coll   := TargetSVLoader.collision_bytes()   # PackedByteArray (GPU-native)
##   var decoded := TargetSVLoader.decode()            # GPU 解码 + readback
class_name TargetSVLoader
extends RefCounted


const SHARED_DIR := "res://assets/target_sv"
const META_NAME := "target_sv_point_cloud.json"
const VISUAL_NAME := "target_sv_point_cloud_visual.rgba8"
const COLLISION_NAME := "target_sv_point_cloud_collision.r8"
const PREVIEW_NAME := "target_sv_point_cloud_preview.png"
const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")

## 数据集自描述的三个缓冲路径键。⚠ 必须由元数据显式声明：以前用 `get(默认文件名)` 兜底，
## 元数据指向别处的数据集时会静默读回目录里的同名旧文件。
const DATASET_PATH_KEYS := ["visual_path", "collision_path", "preview_path"]
## 解码整块体素场所需的框架键。任一项缺失都说明资产与读取端版本不一致；用 256/16/32.0
## 之类的硬编码顶上，会按错误的网格尺寸解码整块体素场（几何全错却不报错）。
##
## ⚠ 这两份清单曾在**三处**各写一遍字面量（本文件的 `_ensure_loaded` 与 `import_dataset`、
## 以及 `TargetSVSetup._ensure_loaded`），而 `import_dataset` 那份恰好等于两者相加 ——
## 三份之间没有任何东西保证同步。2026-08-12 收敛到这里，消费方一律引用常量。
const DATASET_FRAME_KEYS := ["texture_size", "slice_count", "voxel_count",
	"capture_size", "vertical_span", "max_height"]

static var _metadata: Dictionary
static var _visual_bytes: PackedByteArray
static var _collision_bytes: PackedByteArray
static var _decoded: Dictionary
static var _loaded := false
## 静态字节内容的代号：每次真正从磁盘装载（首次或 reload()）都取一个新值。
## 取递增时钟而非自增计数，是为了让编辑器脚本重载把 static 清零后的新代号也不会
## 与重载前发出去的旧代号相撞——消费方可能是重载中存活下来的实例（如 VoxelPickGPU
## 按此代号缓存已上传的 TargetSV 体素缓冲）。int 型 static 不受 Object 型初始化器
## 被重置为 null 的陷阱影响。
static var _content_generation := 0


## 当前静态字节内容的代号。任何按内容缓存 visual_bytes()/collision_bytes() 派生结果的
## 消费方都应把它纳入缓存键：节点自身的 content_revision 只反映该节点首次加载，
## 而这里的静态字节可被任意另一个 TargetSVSetup 的 reload() 整体换掉。
static func content_generation() -> int:
	_ensure_loaded()
	return _content_generation


static func _ensure_loaded() -> bool:
	if _loaded:
		return not _metadata.is_empty()
	_loaded = true
	_content_generation = Time.get_ticks_usec()

	var meta_path := SHARED_DIR.path_join(META_NAME)
	var file := FileAccess.open(meta_path, FileAccess.READ)
	if file == null:
		push_error("[TargetSVLoader] 缺少元数据: %s（FileAccess 错误码 %d）" % [meta_path, FileAccess.get_open_error()])
		assert(false, "TargetSVLoader: target_sv metadata file missing")
		return false

	var parsed = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary:
		_metadata = parsed
	else:
		push_error("[TargetSVLoader] 元数据 JSON 无效: %s（解析结果 typeof=%d）" % [meta_path, typeof(parsed)])
		assert(false, "TargetSVLoader: target_sv metadata JSON invalid")
		return false

	for path_key in DATASET_PATH_KEYS:
		if not _metadata.has(path_key):
			push_error("[TargetSVLoader] 元数据缺少 '%s'（%s）—— 以前会静默回退到默认文件名，可能读到与元数据不匹配的旧缓冲" % [path_key, meta_path])
			assert(false, "TargetSVLoader: target_sv metadata missing path key")
			return false

	# ⚠ 这里曾还有 `_preview_image = _read_image(preview_path)`（连同 `_read_image()` 与
	# 公开的 `preview_image()` 访问器）。preview.png 是给人看的产物，**全仓零消费方**——
	# 每次加载/reload 白解一张 256² PNG。2026-08-12 三者一并删除；文件本身照写照拷，
	# `preview_path` 也仍是必需键（`import_dataset` 要按它搬运）。
	_visual_bytes = _read_file_bytes(str(_metadata["visual_path"]))
	_collision_bytes = _read_file_bytes(str(_metadata["collision_path"]))
	return not _metadata.is_empty()


static func _read_file_bytes(path: String) -> PackedByteArray:
	if path.is_empty():
		push_error("[TargetSVLoader] 缓冲区路径为空字符串 —— 元数据里的路径键取值不可用")
		assert(false, "TargetSVLoader: empty buffer path")
		return PackedByteArray()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[TargetSVLoader] 缺少缓冲区: %s（FileAccess 错误码 %d）" % [path, FileAccess.get_open_error()])
		assert(false, "TargetSVLoader: target_sv buffer file missing")
		return PackedByteArray()
	return f.get_buffer(f.get_length())


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


## 缺 texture_size/slice_count 时硬失败返回 0：以前静默返回 1，
## voxel_count 会缩成 1（或 texture_size²），后续所有缓冲尺寸校验都按错误量级通过。
static func texture_size() -> int:
	_ensure_loaded()
	if not _metadata.has("texture_size"):
		push_error("[TargetSVLoader] 元数据缺少 texture_size（%s）—— 以前静默返回 1" % SHARED_DIR.path_join(META_NAME))
		assert(false, "TargetSVLoader: metadata missing texture_size")
		return 0
	return int(_metadata["texture_size"])


static func slice_count() -> int:
	_ensure_loaded()
	if not _metadata.has("slice_count"):
		push_error("[TargetSVLoader] 元数据缺少 slice_count（%s）—— 以前静默返回 1" % SHARED_DIR.path_join(META_NAME))
		assert(false, "TargetSVLoader: metadata missing slice_count")
		return 0
	return int(_metadata["slice_count"])


static func voxel_count() -> int:
	return texture_size() * texture_size() * slice_count()


# ⚠ 这里曾有 `upload_to_gpu()`（60 行：磁盘字节直传 SSBO）。全仓唯一调用方是
# TargetSVSetup 的同名包装，而那个包装自身零调用（生产上传走
# ScenePlacementActor._prepare_target_read_buffers 的常驻通路）——两层一起删除
# （2026-08-10，链路死码清除）。连带释放本文件的 ComputeShaderBaseScript preload。


## GPU 解码 visual+collision 缓冲区并 readback 到 CPU。
## 优先 GPU 路径；GPU 不可用时回退 CPU。
## 返回值是内部静态缓存的借用引用（不再深拷贝：16MiB+ 字段每次 duplicate 代价过高）。
## 调用方只读：不得增删改字典键；数组值整体赋值/append 受 PackedXxxArray CoW 保护，
## 但不得通过共享引用逐元素写入。
static func decode() -> Dictionary:
	if not _decoded.is_empty():
		return _decoded

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
		var gpu_result: Dictionary = TargetSceneVoxelGeneratorScript.decode_target_read_buffers_gpu(
			_visual_bytes, _collision_bytes, ts, sc
		)
		if bool(gpu_result.get("valid", false)):
			_decoded = gpu_result
			return _decoded
		# 以前是 push_warning + 回退 CPU 解码：有 RenderingDevice 却解码失败说明缓冲/
		# 格式本身有问题，CPU 路径只会把同一份坏数据再解一遍并被当成正常结果缓存。
		push_error("[TargetSVLoader] GPU 解码失败（texture_size=%d slice_count=%d visual=%d 字节 collision=%d 字节 原因=%s）—— 拒绝回退 CPU 解码" % [ts, sc, _visual_bytes.size(), _collision_bytes.size(), str(gpu_result.get("reason", "unknown"))])
		assert(false, "TargetSVLoader: GPU decode failed")
		_decoded = {}
		return {}

	# 无 RenderingDevice（本项目正常运行路径下不应出现）时仍走 CPU 解码。
	var result: Dictionary = TargetSceneVoxelGeneratorScript.decode_target_read_buffers(
		_visual_bytes, _collision_bytes, ts, sc
	)
	_decoded = result
	return _decoded


static func reload() -> void:
	_metadata = {}
	_visual_bytes = PackedByteArray()
	_collision_bytes = PackedByteArray()
	_decoded = {}
	_loaded = false
	_ensure_loaded()


## 把一份外部 TargetSV 数据集导入 SHARED_DIR —— **覆盖**当前那一份。
##
## 导入单位是元数据 json：三个缓冲路径由它自己声明，只有它是自描述的（同 _ensure_loaded
## 的路径键硬门）。落地后 json 里那三个键会被改写成 SHARED_DIR 下的规范文件名——不改写
## 的话，复制进来的缓冲没人读、loader 仍按源路径取数，源一旦被删改就读到与 json 不一致
## 的数据，正是那道硬门当初要防的情形。
##
## 只动磁盘，**不碰本类的静态缓存**：换新交给调用方紧接着的 TargetSVSetup.reimport()
## （它内部会 reload()），省掉一次 5 MiB 级的重复读盘。
##
## 源 json 里的缓冲路径：res:// 与 user:// 按原样解析，其余按 json 自身所在目录解析。
static func import_dataset(src_meta_path: String) -> Dictionary:
	var src_file := FileAccess.open(src_meta_path, FileAccess.READ)
	if src_file == null:
		return {"ok": false, "reason": "source_metadata_unreadable",
			"path": src_meta_path, "file_error": FileAccess.get_open_error()}
	var src_text := src_file.get_as_text()
	src_file.close()   # 选中的可能就是 SHARED_DIR 里那一份，下面要以 WRITE 打开同一路径
	var parsed = JSON.parse_string(src_text)
	if not (parsed is Dictionary):
		return {"ok": false, "reason": "source_metadata_not_json",
			"path": src_meta_path, "parsed_type": typeof(parsed)}
	var meta: Dictionary = parsed
	# 与 _ensure_loaded / TargetSVSetup._ensure_loaded 同一套必需字段，在**动手覆盖之前**先拦：
	# 否则一份缺字段的 json 会先把原数据集盖掉，之后才在加载期报错，原数据已经找不回来了。
	for required_key in DATASET_FRAME_KEYS + DATASET_PATH_KEYS:
		if not meta.has(required_key):
			return {"ok": false, "reason": "source_metadata_missing_key", "key": required_key,
				"path": src_meta_path, "source_keys": meta.keys()}

	var src_dir := src_meta_path.get_base_dir()
	var transfers := [
		{"key": "visual_path", "dst": SHARED_DIR.path_join(VISUAL_NAME)},
		{"key": "collision_path", "dst": SHARED_DIR.path_join(COLLISION_NAME)},
		{"key": "preview_path", "dst": SHARED_DIR.path_join(PREVIEW_NAME)},
	]
	# 三个源缓冲先整体验在，再开始复制：不允许"复制到一半失败"的半份数据集落地。
	for transfer in transfers:
		var src_buffer := _resolve_dataset_path(str(meta[transfer["key"]]), src_dir)
		if not FileAccess.file_exists(src_buffer):
			return {"ok": false, "reason": "source_buffer_missing",
				"key": transfer["key"], "path": src_buffer, "metadata": src_meta_path}
		transfer["src"] = src_buffer

	var dst_meta := SHARED_DIR.path_join(META_NAME)
	var replaced := _describe_existing_dataset(dst_meta, transfers)
	var copied := PackedStringArray()
	for transfer in transfers:
		# 路径键无条件改写成规范目标，源就是目标时也照写（元数据可能本来指向别处）。
		meta[transfer["key"]] = transfer["dst"]
		if transfer["src"] == transfer["dst"]:
			continue   # 选中的就是当前这一份：自我复制会把文件截成 0 字节
		var err := DirAccess.copy_absolute(str(transfer["src"]), str(transfer["dst"]))
		if err != OK:
			return {"ok": false, "reason": "buffer_copy_failed", "key": transfer["key"],
				"src": transfer["src"], "dst": transfer["dst"], "error": err,
				"copied_before_failure": copied}
		copied.append(str(transfer["dst"]))

	var out := FileAccess.open(dst_meta, FileAccess.WRITE)
	if out == null:
		return {"ok": false, "reason": "metadata_write_failed", "path": dst_meta,
			"file_error": FileAccess.get_open_error(), "copied": copied}
	# 由已解析的 Dictionary 重新序列化：JSON 数字会统一成浮点写法（256 → 256.0），
	# 读取端一律经 int()/float() 取值，取值不受影响。
	out.store_string(JSON.stringify(meta, "\t"))
	out.close()
	copied.append(dst_meta)

	return {
		"ok": true, "reason": "ok",
		"source": src_meta_path,
		"same_dataset": src_meta_path == dst_meta,
		"copied": copied,
		"replaced": replaced,
		"texture_size": int(meta["texture_size"]),
		"slice_count": int(meta["slice_count"]),
		"voxel_count": int(meta["voxel_count"]),
	}


static func _resolve_dataset_path(path: String, base_dir: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://") or path.is_absolute_path():
		return path
	return base_dir.path_join(path)


## 覆盖前把将被替换的文件记下来（存在的才记）：导入是破坏性的，事后至少能说清盖掉了什么。
static func _describe_existing_dataset(dst_meta: String, transfers: Array) -> Array:
	var described: Array = []
	var paths := [dst_meta]
	for transfer in transfers:
		paths.append(str(transfer["dst"]))
	for path in paths:
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			continue
		described.append({"path": path, "bytes": file.get_length()})
		file.close()
	return described
