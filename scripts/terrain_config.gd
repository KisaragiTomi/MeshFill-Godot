class_name TerrainConfig
extends RefCounted

## 地形比例规范 -- 全工程唯一真值源
##
## 所有需要地形比例 / 尺度的场景与脚本都引用此处的常量，
## 不再各自硬编码。改这里即可全局生效。
##
## 比例基准: geo/TargetLandscape.bgeo.sc (256x256 grid, 已校验包围盒)
##   水平 x/z 范围 [-512, +512] -> 边长 1024 (CAPTURE_SIZE)
##   竖直 y   范围 [0, 120]     -> 跨度 120  (MAX_HEIGHT)
##   水平 : 竖直 = 1024 : 120 ≈ 8.53 : 1
##
## 任何地形 (运行时生成或编辑期 bake) 都必须满足该比例:
##   capture_size / max_height == 1024.0 / 120.0
## 否则视为不合规, 需要重新 bake (tools/bake_utils_terrain.gd)。

## 采样窗口 / 地形水平边长 (世界单位); 对应 bgeo x/z 跨度 1024。
const CAPTURE_SIZE := 1024.0

## 地形竖直跨度 (世界单位); 对应 bgeo y 跨度 120。
const MAX_HEIGHT := 120.0

## 地形水平:竖直 标准比例 (= CAPTURE_SIZE / MAX_HEIGHT)。
const ASPECT_RATIO := CAPTURE_SIZE / MAX_HEIGHT

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