class_name TerrainConfig
extends RefCounted

## 地形比例设定 -- 全工程唯一真值源
##
## 所有需要地形比例 / 尺度的场景与脚本都引用此处的常量，
## 不再各自硬编码。改这里即可全局生效。
##
## 经 geo/TargetLandscape.bgeo.sc 校验:
##   水平范围 x/z [-512, 512] -> 这里以 capture_size 表示采样窗口边长
##   垂直范围 y [0, 120]      -> MAX_HEIGHT = 120.0 (地形真实竖直跨度)

## 采样窗口边长 (世界单位, 水平)
const CAPTURE_SIZE := 120.0

## 地形竖直跨度 (世界单位)
const MAX_HEIGHT := 120.0

## 高度 / 纹理分辨率 (边长像素数)
const TEXTURE_SIZE := 256

## 公共地形节点默认名
const TERRAIN_NAME := "Terrain"


## 返回一份标准地形 options, 供 TerrainInitializer.ensure_terrain_initialized 使用。
## overrides 可覆盖任意字段 (如 visible / replace_existing / terrain_name)。
static func terrain_options(overrides := {}) -> Dictionary:
	var options := {
		"terrain_name": TERRAIN_NAME,
		"capture_size": CAPTURE_SIZE,
		"max_height": MAX_HEIGHT,
		"texture_size": TEXTURE_SIZE,
	}
	for key in overrides.keys():
		options[key] = overrides[key]
	return options