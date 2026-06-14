## CommonTerrain -- 地形自动注入 autoload
##
## 所有 .tscn 启动时自动在此场景的 root 下挂载公共地形。
## 场景如需自定义地形，调用 TerrainInitializer.ensure_terrain_initialized()
## 并传入 replace_existing=true 即可覆盖。
##
## 默认参数:
##   capture_size = 120.0
##   max_height   = 120.0
##   visible      = true (编辑器预览友好)
extends Node

const TerrainInitializerScript := preload("res://scripts/terrain_initializer.gd")

var _injected := false


func _ready() -> void:
	_inject.call_deferred()


func _inject() -> void:
	if _injected:
		return
	var tree := get_tree()
	if tree == null:
		return
	var root := tree.root
	if root == null:
		return

	var result := TerrainInitializerScript.ensure_shared_terrain(root, {
		"visible": true,
	})

	if not bool(result.get("ok", false)):
		push_warning("[CommonTerrain] 地形自动注入失败: %s" % str(result.get("reason", "未知")))
		return

	_injected = true
	if bool(result.get("created", false)):
		print("[CommonTerrain] 自动创建公共地形: %dx%d, height %.0f" % [
			int(result.get("resolution", 0)),
			int(result.get("resolution", 0)),
			float(result.get("height_stats", Vector2.ZERO).y),
		])