@tool
class_name DemoDebugVisuals
extends RefCounted

## Demo 侧 debug 可视化共享工厂：无光照透明调试材质 + 单位线框盒。
## 之前在 SPA / asset-descriptor / probe-prefilter / volume-score / scenevoxeltile
## 各 demo 内联重复；站点特有属性（emission 等）由调用方拿到返回值后再补赋。


## 创建无光照透明调试材质。默认值即 StandardMaterial3D 默认（背面剔除、深度测试开）。
static func make_unshaded_material(albedo: Color, use_vertex_color := false, no_depth_test := false, cull_disabled := false) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = albedo
	mat.vertex_color_use_as_albedo = use_vertex_color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED if cull_disabled else BaseMaterial3D.CULL_BACK
	mat.no_depth_test = no_depth_test
	return mat


## 创建单位立方体线框 Mesh；调用方通过 MeshInstance scale 控制实际尺寸。
static func make_unit_wire_box_mesh() -> ImmediateMesh:
	var half := 0.5
	var corners := [
		Vector3(-half, -half, -half),
		Vector3(half, -half, -half),
		Vector3(half, -half, half),
		Vector3(-half, -half, half),
		Vector3(-half, half, -half),
		Vector3(half, half, -half),
		Vector3(half, half, half),
		Vector3(-half, half, half),
	]
	var edges := [
		[0, 1], [1, 2], [2, 3], [3, 0],
		[4, 5], [5, 6], [6, 7], [7, 4],
		[0, 4], [1, 5], [2, 6], [3, 7],
	]
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for edge in edges:
		mesh.surface_add_vertex(corners[int(edge[0])])
		mesh.surface_add_vertex(corners[int(edge[1])])
	mesh.surface_end()
	return mesh
