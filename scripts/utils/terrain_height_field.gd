@tool
extends RefCounted

## 地形高度场采样（批2 自 spa_interactive_demo.gd 平移）。
## 输入全部显式传参：height_field = res×res 行主序高度数组（TerrainInitializer
## terrain_height_field_from_mesh 产物），capture_size = 世界 XZ 捕获边长（原点居中）。
## 无场景依赖、无成员状态。
##
## ⚠ 本文件曾是「地形**射线**工具」：`ray_to_height_field()`（步进+二分求精）及其三个几何
## 辅助（`ray_capture_interval` / `ray_xz_plane` / `position_in_capture_xz`）、两个迭代次数常量
## （`RAY_MARCH_STEPS` / `RAY_BISECT_STEPS`），以及把那两个常量发射成 GLSL 侧
## `const int STEPS / BISECT_STEPS` 的整套区块 SSOT。
##
## 它们服务的是**旧点选**：SV / SVTile / TargetSV 三个域都从同一条地形射线取值，因屏幕距离
## 恒等而无法互比，只能靠偏好顺序仲裁。三角形 ID 成为唯一命中方式后（2026-08-10）那条射线
## 不复存在——每个域画在自己的位置上，深度测试即仲裁；偏好表当时已删，射线本体与其唯一调用者
## `SPASelectionHost._ray_to_terrain()` 漏网，2026-08-10 一并清除。
##
## 将来若要恢复 CPU 侧地形射线（例如给不进 ID pass 的域做落点），照 git 历史取回即可；
## 若同时需要 GLSL 侧共享常量，照 `PlacementSharedGLSL` 的形状重建区块 SSOT。
##
## ⚠ 本文件旧名 `terrain_raycast.gd`（2026-08-12 改名）：射线本体删干净之后，旧名会让读者
## 以为这里还有一条 CPU 地形射线——而它现在只有一个高度场查表。改名连同 `.uid` 一起搬，
## 文件无 `class_name`、仅被 preload 按路径引用，故只有一个引入点需要跟着改。


## 采样世界 XZ 位置的地形高度。
static func sample_height(
		height_field: PackedFloat32Array,
		field_res: int,
		capture_size: float,
		wx: float,
		wz: float
) -> float:
	if field_res <= 0 or height_field.is_empty():
		return 0.0
	var u := clampf((wx / capture_size) + 0.5, 0.0, 1.0)
	var v := clampf((wz / capture_size) + 0.5, 0.0, 1.0)
	var px := clampi(int(u * float(field_res - 1)), 0, field_res - 1)
	var pz := clampi(int(v * float(field_res - 1)), 0, field_res - 1)
	var idx := pz * field_res + px
	# px/pz 已按 field_res 双向 clamp，idx 必落在 [0, field_res²)。越界 ⟹ 高度场长度与
	# field_res 不一致（生产端与消费端分辨率不匹配），返回 0.0 会把这一点伪装成「地面在原点高度」。
	if idx >= height_field.size():
		push_error("TerrainHeightField.sample_height: 高度场长度与分辨率不符 field_res=%d 需要 %d 元素 实际 %d（idx=%d）" % [field_res, field_res * field_res, height_field.size(), idx])
		assert(false, "TerrainHeightField.sample_height: height_field/field_res mismatch")
		return 0.0
	return height_field[idx]
