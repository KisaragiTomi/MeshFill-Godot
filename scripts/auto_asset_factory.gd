class_name AutoAssetFactory
extends RefCounted

const DemoAssets := preload("res://scripts/utils/demo_assets.gd")


static func load_mesh(mesh_path: String) -> Mesh:
	var mesh_info := DemoAssets.load_mesh_info(mesh_path)
	var mesh: Mesh = mesh_info.get("mesh", null)
	if mesh == null:
		return null
	return _bake_mesh_transform(mesh, mesh_info.get("transform", Transform3D.IDENTITY))


static func load_source_mesh(mesh_path: String) -> Mesh:
	return DemoAssets.load_mesh(mesh_path)


## source mesh 解析共用核心(原 AssetDescriptor/AutoObject.get_source_mesh 逐字重复)。
## 返回 {"mesh": Mesh, "cache": bool}；cache=true 时调用方负责写回 source_mesh 缓存。
static func resolve_source_mesh(
	source_mesh_path: String,
	cached_source_mesh: Mesh,
	current_mesh: Mesh,
	fallback_mesh: Mesh
) -> Dictionary:
	if not source_mesh_path.is_empty() and (cached_source_mesh == null or cached_source_mesh == current_mesh):
		var loaded := load_source_mesh(source_mesh_path)
		if loaded != null:
			return {"mesh": loaded, "cache": true}
	if cached_source_mesh != null:
		return {"mesh": cached_source_mesh, "cache": false}
	return {"mesh": fallback_mesh, "cache": false}


## resolve_source_mesh + 命中缓存时回写 owner.source_mesh 的共享收尾
## （原 AssetDescriptor.get_source_mesh / AutoObject.get_source_mesh 逐行重复的解析+缓存舞步）。
## owner 需有 source_mesh_path / source_mesh 属性（鸭子类型，两个调用方均满足）。
static func resolve_cached_source_mesh(owner: Object, current_mesh: Mesh, fallback_mesh: Mesh) -> Mesh:
	var resolved := resolve_source_mesh(owner.source_mesh_path, owner.source_mesh, current_mesh, fallback_mesh)
	var resolved_mesh: Mesh = resolved.get("mesh", null)
	if resolved.get("cache", false):
		owner.source_mesh = resolved_mesh
	return resolved_mesh


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
