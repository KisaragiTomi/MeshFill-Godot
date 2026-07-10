class_name AutoAssetFactory
extends RefCounted

const DemoAssets := preload("res://scripts/utils/demo_assets.gd")


static func load_mesh(mesh_path: String) -> Mesh:
	if mesh_path.is_empty():
		return null
	var resource = load(mesh_path)
	if resource is Mesh:
		return resource as Mesh
	if resource is PackedScene:
		var instance := (resource as PackedScene).instantiate()
		var mesh_info := _find_mesh_info_in_tree(instance)
		if mesh_info.is_empty():
			mesh_info = _find_mesh_info_in_tree(instance, Transform3D.IDENTITY, true)
		var mesh: Mesh = mesh_info.get("mesh", null)
		var mesh_transform: Transform3D = mesh_info.get("transform", Transform3D.IDENTITY)
		instance.free()
		if mesh == null:
			return null
		return _bake_mesh_transform(mesh, mesh_transform)
	return null


static func load_source_mesh(mesh_path: String) -> Mesh:
	if mesh_path.is_empty():
		return null
	var resource = load(mesh_path)
	if resource is Mesh:
		return resource as Mesh
	if resource is PackedScene:
		var instance := (resource as PackedScene).instantiate()
		var mesh_info := _find_mesh_info_in_tree(instance)
		if mesh_info.is_empty():
			mesh_info = _find_mesh_info_in_tree(instance, Transform3D.IDENTITY, true)
		var mesh: Mesh = mesh_info.get("mesh", null)
		instance.free()
		return mesh
	return null


## 网格树查找 / UE 碰撞辅助体过滤 / 变换烘焙已与 DemoAssets 合并(原三份近逐字重复)。
## 委托版差异均为更安全方向:identity 变换直接返回源网格、空 surface 跳过、法线尺寸校验更严。
static func _find_mesh_info_in_tree(
	node: Node,
	parent_transform: Transform3D = Transform3D.IDENTITY,
	allow_collision_helpers: bool = false
) -> Dictionary:
	return DemoAssets.find_mesh_info_in_tree(node, parent_transform, allow_collision_helpers)


static func _is_ue_collision_helper(node: Node) -> bool:
	return DemoAssets.is_collision_helper_node(node)


static func _bake_mesh_transform(src_mesh: Mesh, mesh_transform: Transform3D) -> Mesh:
	return DemoAssets.bake_mesh_xform(src_mesh, mesh_transform, true)
