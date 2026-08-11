class_name AutoAssetFactory
extends RefCounted

const DemoAssets := preload("res://scripts/utils/demo_assets.gd")


static func load_mesh(mesh_path: String) -> Mesh:
	var mesh_info := DemoAssets.load_mesh_info(mesh_path)
	var mesh: Mesh = mesh_info.get("mesh", null)
	if mesh == null:
		push_error("[AutoAssetFactory] load_mesh(): %s 未解析出任何 Mesh —— 路径不存在 / 导入失败 / 场景内无 MeshInstance3D" % mesh_path)
		assert(false, "AutoAssetFactory.load_mesh: no mesh resolved")
		return null
	if not mesh_info.has("transform"):
		push_error("[AutoAssetFactory] load_mesh(): %s 的 mesh_info 缺 \"transform\" 键 —— DemoAssets.load_mesh_info 契约被破坏，无法烘焙导入变换" % mesh_path)
		assert(false, "AutoAssetFactory.load_mesh: mesh_info missing transform")
		return null
	return _bake_mesh_transform(mesh, mesh_info["transform"])


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
		if loaded == null:
			# 显式配了 source_mesh_path 却加载不出来 = 数据本应存在却缺失，
			# 不能悄悄退回 cached/fallback mesh 冒充 source mesh。
			push_error("[AutoAssetFactory] resolve_source_mesh(): source_mesh_path=\"%s\" 加载失败 —— 不再退回 cached/fallback mesh" % source_mesh_path)
			assert(false, "AutoAssetFactory.resolve_source_mesh: source_mesh_path load failed")
			return {"mesh": null, "cache": false}
		return {"mesh": loaded, "cache": true}
	if cached_source_mesh != null:
		return {"mesh": cached_source_mesh, "cache": false}
	# 未配 source_mesh_path 且无缓存 —— fallback_mesh 是调用方显式传入的契约默认值（API 设计），不是错误兜底。
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
static func _bake_mesh_transform(src_mesh: Mesh, mesh_transform: Transform3D) -> Mesh:
	return DemoAssets.bake_mesh_xform(src_mesh, mesh_transform, true)
