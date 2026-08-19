@tool
class_name DemoAssets
extends RefCounted

const GEO_PATHS := [
	"res://geo/SM_TestLeaf_Test2.FBX",
	"res://geo/cliff_01.FBX",
	"res://geo/cliff_02.FBX",
]

const SUPPORTED_GEO_EXTENSIONS := ["fbx", "glb", "gltf", "obj", "dae", "blend", "mesh", "res", "tscn", "scn"]

const ASSET_NAMES := ["Leaf", "Cliff01", "Cliff02"]

const WIRE_COLORS := [
	Color(0.2, 0.9, 0.3, 0.7),
	Color(0.9, 0.4, 0.2, 0.7),
	Color(0.2, 0.5, 1.0, 0.7),
]


static func count() -> int:
	return GEO_PATHS.size()


static func asset_names() -> Array:
	return ASSET_NAMES.duplicate()


static func discover_geo_files(root_path: String, supported_extensions: Array = []) -> Array[String]:
	var results: Array[String] = []
	var dir := DirAccess.open(root_path)
	if dir == null:
		return results
	var extensions := SUPPORTED_GEO_EXTENSIONS if supported_extensions.is_empty() else supported_extensions
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if file_name.begins_with("."):
			file_name = dir.get_next()
			continue
		var path := root_path.path_join(file_name)
		if dir.current_is_dir():
			results.append_array(discover_geo_files(path, extensions))
		elif is_supported_geo_file(path, extensions):
			results.append(path)
		file_name = dir.get_next()
	dir.list_dir_end()
	results.sort()
	return results


static func is_supported_geo_file(path: String, supported_extensions: Array = []) -> bool:
	if path.to_lower().ends_with(".import"):
		return false
	var extensions := SUPPORTED_GEO_EXTENSIONS if supported_extensions.is_empty() else supported_extensions
	return extensions.has(path.get_extension().to_lower())


static func load_mesh(mesh_path: String) -> Mesh:
	var info := load_mesh_info(mesh_path)
	return info.get("mesh", null)


static func load_mesh_info(mesh_path: String, include_collision_helpers_fallback: bool = true) -> Dictionary:
	if mesh_path.is_empty():
		return {}
	var resource = load(mesh_path)
	if resource is Mesh:
		return {
			"mesh": resource as Mesh,
			"mesh_transform": Transform3D.IDENTITY,
			"transform": Transform3D.IDENTITY,
		}
	if resource is PackedScene:
		var instance := (resource as PackedScene).instantiate()
		var info := find_mesh_info_in_tree(instance)
		if info.is_empty() and include_collision_helpers_fallback:
			info = find_mesh_info_in_tree(instance, Transform3D.IDENTITY, true)
		if instance != null:
			instance.free()
		return info
	return {}


static func find_mesh_info_in_tree(
	node: Node,
	parent_transform: Transform3D = Transform3D.IDENTITY,
	allow_collision_helpers: bool = false
) -> Dictionary:
	if node == null:
		return {}
	var node_transform := parent_transform
	if node is Node3D:
		node_transform = parent_transform * (node as Node3D).transform
	if allow_collision_helpers or not is_collision_helper_node(node):
		if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
			return {
				"mesh": (node as MeshInstance3D).mesh,
				"mesh_transform": node_transform,
				"transform": node_transform,
			}
		if node is ImporterMeshInstance3D:
			var importer_mesh = node.get("mesh")
			if importer_mesh != null and importer_mesh.has_method("get_mesh"):
				var converted = importer_mesh.get_mesh()
				if converted is Mesh:
					return {
						"mesh": converted as Mesh,
						"mesh_transform": node_transform,
						"transform": node_transform,
					}
	for child in node.get_children():
		var info := find_mesh_info_in_tree(child, node_transform, allow_collision_helpers)
		if not info.is_empty():
			return info
	return {}


static func is_collision_helper_node(node: Node) -> bool:
	return is_collision_helper_name(str(node.name))


## 字符串版：给只拿得到 node_name 的调用方用（FbxVoxelImportService 的通道读取按它
## 豁免碰撞辅助网格——UCX 等本就不带 uv8 数据通道，不该按"缺 8 个 UV set"报错）。
static func is_collision_helper_name(raw_name: String) -> bool:
	var node_name := raw_name.to_upper()
	return node_name.begins_with("UCX_") \
		or node_name.begins_with("UBX_") \
		or node_name.begins_with("UCP_") \
		or node_name.begins_with("USP_") \
		or node_name.begins_with("MCDCX_")


# Bake xform into mesh vertex positions (and normals) so the caller can set
# MeshInstance3D.transform = IDENTITY while the mesh displays identically.
# Returns source unchanged when xform is identity. Preserves surface materials
# and primitive types. bake_tangents=true 时同时变换切线(运行时法线贴图路径需要,
# 原 AutoAssetFactory._bake_mesh_transform 行为);默认 false 走 demo 显示的轻量路径。
static func bake_mesh_xform(source: Mesh, xform: Transform3D, bake_tangents: bool = false) -> Mesh:
	if source == null:
		return null
	if xform.is_equal_approx(Transform3D.IDENTITY):
		return source
	var normal_basis := xform.basis.inverse().transposed()
	var result := ArrayMesh.new()
	for surf_idx in range(source.get_surface_count()):
		var arrays := source.surface_get_arrays(surf_idx)
		if arrays.is_empty():
			continue
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for i in range(verts.size()):
			verts[i] = xform * verts[i]
		arrays[Mesh.ARRAY_VERTEX] = verts
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		if normals.size() == verts.size():
			for i in range(normals.size()):
				normals[i] = (normal_basis * normals[i]).normalized()
			arrays[Mesh.ARRAY_NORMAL] = normals
		if bake_tangents and arrays[Mesh.ARRAY_TANGENT] != null:
			var tangents: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
			if tangents.size() > 0:
				var baked_tangents := tangents.duplicate()
				for tangent_index in range(0, tangents.size(), 4):
					var tangent := Vector3(
						tangents[tangent_index],
						tangents[tangent_index + 1],
						tangents[tangent_index + 2]
					)
					tangent = (normal_basis * tangent).normalized()
					baked_tangents[tangent_index] = tangent.x
					baked_tangents[tangent_index + 1] = tangent.y
					baked_tangents[tangent_index + 2] = tangent.z
				arrays[Mesh.ARRAY_TANGENT] = baked_tangents
		result.add_surface_from_arrays(source.surface_get_primitive_type(surf_idx), arrays)
		result.surface_set_material(surf_idx, source.surface_get_material(surf_idx))
	return result
