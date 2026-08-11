@tool
class_name GeoAssetScanService
extends RefCounted
## S2 上游编排：res://geo FBX 库的增量扫描 / 分类 / 节点工厂 / 摆放。
## 自 asset-descriptor demo 下沉（demo场景真实链重设计方案 新家 6）。纯编辑器服务：
## 全部入口 static、以 host（场景根）+ options 驱动，不持有状态。
## 编辑器选择的谓词祖先游走（原 demo _resolve_selected_* 共用逻辑）也住在这里。

const DemoAssets := preload("res://scripts/utils/demo_assets.gd")
const DemoDebugVisuals := preload("res://scripts/utils/demo_debug_visuals.gd")
const VoxelDebugLabel := preload("res://scripts/utils/voxel_debug_label.gd")
const FbxVoxelImportService := preload("res://scripts/fbx_voxel_import_service.gd")

# —— 场景/资源契约常量（.tscn 已持久化这些 meta 键与节点名，字符串冻结）——
const GEO_ASSET_ROOT := "Assets/Geo"
const GEO_SOURCE_META := "geo_source_path"
const GEO_MTIME_META := "geo_modified_time"
const GEO_BOUND_SIZE_META := "geo_bound_size"
const GEO_BOUND_LONGEST_META := "geo_bound_longest"
const GEO_KIND_META := "geo_asset_kind"
const GEO_EMBEDDED_DATA_TRIANGLES_META := "geo_embedded_data_triangles_removed"
const GEO_FINE_SCORE_TRIANGLES_META := "geo_fine_score_triangles_removed"
const GEO_PROBE_TRIANGLES_META := "geo_probe_triangles_removed"
const GEO_SCAN_EXTENSIONS := ["fbx"]

const DEFAULT_GEO_LIBRARY_PATH := "res://geo"
const DEFAULT_LAYOUT_ORIGIN := Vector3(-7.0, 0.0, 5.0)
const DEFAULT_LAYOUT_ROW_WIDTH := 14.0
const DEFAULT_BOUND_BOX_COLOR := Color(1.0, 0.08, 0.04, 0.85)
# kind_colors 缺省兜底（调用方通常显式传入自己的分类配色）
const DEFAULT_KIND_COLOR := Color(0.48, 0.42, 0.35, 0.7)


## 发现 FBX 库中的全部文件，再交给单文件/多文件共用的 import_files() 处理。
static func scan(host: Node3D, full_rescan: bool, options := {}) -> Dictionary:
	refresh_editor_filesystem()
	var extensions: Array = options.get("extensions", GEO_SCAN_EXTENSIONS)
	var root_path := str(options.get("root_path", DEFAULT_GEO_LIBRARY_PATH))
	var files := DemoAssets.discover_geo_files(root_path, extensions)
	if files.is_empty():
		# 扫描一个都没找到就静默返回空、让上游当"没有新增"继续跑，是最难查的一类兜底。
		push_error("[GeoAssetScanService] scan(): 在 %s 下未发现任何 %s 文件 —— 资产库路径无效或为空，扫描中止" % [
			root_path, str(extensions)])
		assert(false, "GeoAssetScanService.scan: geo library is empty")
		return {
			"full": full_rescan,
			"added": 0,
			"updated": 0,
			"unchanged": 0,
			"skipped": 0,
			"total": geo_asset_nodes(host).size(),
		}
	return import_files(host, files, full_rescan, options)


## 把指定 FBX 文件接入 host 场景。Import FBX 与 Import All 的唯一差异是 paths；
## 节点创建、增量判断、内嵌数据剥离、布局和 dirty 标记均走本函数。
## options: extensions / kind_colors {kind: Color} / arrange_assets (default true) /
##          layout_origin / layout_row_width / show_helpers (default false) / bound_box_color
## 返回 {"full","added","updated","unchanged","skipped","total"}（插件 toolbar 契约键，勿改名）。
static func import_files(
	host: Node3D,
	paths: Array,
	full_rescan: bool = false,
	options := {}
) -> Dictionary:
	var geo_root := _get_or_create_geo_asset_root(host)
	if full_rescan:
		for child in geo_root.get_children():
			if child is Node:
				(child as Node).free()

	var existing := _geo_nodes_by_source_path(geo_root)
	var extensions: Array = options.get("extensions", GEO_SCAN_EXTENSIONS)
	var allowed_extensions := {}
	for extension in extensions:
		allowed_extensions[str(extension).to_lower()] = true
	var files: Array[String] = []
	var seen := {}
	var skipped := 0
	for raw_path in paths:
		var path := str(raw_path).replace("\\", "/")
		if path.is_empty() or seen.has(path) \
				or not allowed_extensions.has(path.get_extension().to_lower()):
			skipped += 1
			continue
		seen[path] = true
		files.append(path)
	files.sort()
	var added := 0
	var updated := 0
	var unchanged := 0

	for path in files:
		var modified := _file_modified_time(path)
		var existing_node: Node3D = existing.get(path, null)
		if existing_node != null and int(existing_node.get_meta(GEO_MTIME_META, -1)) == modified:
			# ⚠ 免重建 ≠ 免可见。这条快路径整个跳过 `_rebuild_geo_asset_node`，
			# 那里的 `visible = true` 也就不会跑 ⇒ 一个此前被隐藏的节点原样留在隐藏态，
			# 用户看到的是"点了导入毫无反应"。导入碰过的节点一律显出来。
			existing_node.visible = true
			unchanged += 1
			continue
		var info := DemoAssets.load_mesh_info(path)
		var mesh: Mesh = info.get("mesh", null)
		if mesh == null:
			skipped += 1
			push_error("[GeoAssetScanService] import_files(): %s 未解析出 Mesh —— FBX 导入失败或场景内无 MeshInstance3D，该资产被跳过" % path)
			assert(false, "GeoAssetScanService.import_files: FBX yielded no mesh")
			continue
		if existing_node != null:
			_rebuild_geo_asset_node(existing_node, path, modified, info, options)
			set_owned_by_scene(host, existing_node)
			updated += 1
		else:
			var node := _create_geo_asset_node(path, modified, info, options)
			geo_root.add_child(node)
			set_owned_by_scene(host, node)
			added += 1

	if bool(options.get("arrange_assets", true)):
		arrange_geo_asset_nodes(host, options)
	else:
		reset_geo_asset_positions(host)
	mark_scene_unsaved()
	return {
		"full": full_rescan,
		"added": added,
		"updated": updated,
		"unchanged": unchanged,
		"skipped": skipped,
		"total": geo_asset_nodes(host).size(),
	}


## 扫描摘要格式化（原 demo _format_geo_scan_result 逐字；demo 冻结名一行委托到这里）。
static func format_scan_result(result: Dictionary) -> String:
	return "Geo scan: added=%d updated=%d unchanged=%d skipped=%d total=%d" % [
		int(result.get("added", 0)),
		int(result.get("updated", 0)),
		int(result.get("unchanged", 0)),
		int(result.get("skipped", 0)),
		int(result.get("total", 0)),
	]


static func geo_asset_nodes(host: Node) -> Array[Node3D]:
	var nodes: Array[Node3D] = []
	var root := host.get_node_or_null(GEO_ASSET_ROOT)
	if root == null:
		return nodes
	for child in root.get_children():
		if child is Node3D:
			nodes.append(child as Node3D)
	return nodes


static func arrange_geo_asset_nodes(host: Node3D, options := {}) -> void:
	var nodes := geo_asset_nodes(host)
	nodes.sort_custom(func(a: Node3D, b: Node3D) -> bool:
		var la := float(a.get_meta(GEO_BOUND_LONGEST_META, 0.0))
		var lb := float(b.get_meta(GEO_BOUND_LONGEST_META, 0.0))
		if not is_equal_approx(la, lb):
			return la > lb
		return str(a.get_meta(GEO_SOURCE_META, "")) < str(b.get_meta(GEO_SOURCE_META, ""))
	)
	var layout_origin: Vector3 = options.get("layout_origin", DEFAULT_LAYOUT_ORIGIN)
	var layout_row_width := float(options.get("layout_row_width", DEFAULT_LAYOUT_ROW_WIDTH))
	var row_start_x := layout_origin.x
	var row_limit_x := layout_origin.x + layout_row_width
	var cursor_x := row_start_x
	var row_z := layout_origin.z
	var row_depth := 0.0

	for node in nodes:
		var bounds := _geo_node_local_aabb(node)
		var size := bounds.size
		if cursor_x > row_start_x and cursor_x + size.x > row_limit_x:
			cursor_x = row_start_x
			row_z += row_depth * 2.0
			row_depth = 0.0
		node.scale = Vector3.ONE
		# 排列时 Y 轴归零：容器原点固定在布局基线（layout_origin.y，默认 0）。
		# 网格保留 FBX 原生轴心（cliff 为几何中心），物体以该轴心居中于 y=0。
		node.position = Vector3(
			cursor_x - bounds.position.x,
			layout_origin.y,
			row_z - (bounds.position.z + bounds.size.z * 0.5)
		)
		cursor_x += size.x * 2.0
		row_depth = maxf(row_depth, size.z)
		set_owned_by_scene(host, node)


static func reset_geo_asset_positions(host: Node3D) -> void:
	for node in geo_asset_nodes(host):
		node.position = Vector3.ZERO
		set_owned_by_scene(host, node)


## editor_selection_utils 并入点：从编辑器当前选择沿父链上行，返回第一个令谓词为真的祖先。
## predicate: Callable(Node) -> bool。非编辑器 / 无选择返回 null。
static func selected_node_matching(predicate: Callable) -> Node3D:
	if not Engine.is_editor_hint():
		return null
	var selection := EditorInterface.get_selection()
	if selection == null:
		return null
	for sel in selection.get_selected_nodes():
		var cur: Node = sel
		while cur != null:
			if cur is Node3D and bool(predicate.call(cur)):
				return cur as Node3D
			cur = cur.get_parent()
	return null


static func refresh_editor_filesystem() -> void:
	if not Engine.is_editor_hint():
		return
	var fs = EditorInterface.get_resource_filesystem()
	if fs != null and fs.has_method("scan"):
		fs.scan()


static func mark_scene_unsaved() -> void:
	if Engine.is_editor_hint() and EditorInterface.has_method("mark_scene_as_unsaved"):
		EditorInterface.mark_scene_as_unsaved()


static func set_owned_by_scene(host: Node, node: Node) -> void:
	var scene_owner: Node = host
	if host.is_inside_tree():
		var tree := host.get_tree()
		if tree != null and tree.edited_scene_root != null:
			scene_owner = tree.edited_scene_root
	for item in _node_and_descendants(node):
		item.owner = scene_owner


# —— 内部 —— ---------------------------------------------------------------

static func _get_or_create_geo_asset_root(host: Node3D) -> Node3D:
	var root := host.get_node_or_null(GEO_ASSET_ROOT) as Node3D
	if root != null:
		return root
	var assets := host.get_node_or_null("Assets") as Node3D
	if assets == null:
		assets = Node3D.new()
		assets.name = "Assets"
		host.add_child(assets)
		set_owned_by_scene(host, assets)
	root = Node3D.new()
	root.name = "Geo"
	assets.add_child(root)
	set_owned_by_scene(host, root)
	return root


static func _geo_nodes_by_source_path(root: Node) -> Dictionary:
	var result := {}
	for child in root.get_children():
		if not child is Node3D:
			continue
		var node := child as Node3D
		var path := str(node.get_meta(GEO_SOURCE_META, ""))
		if path.is_empty():
			continue
		if result.has(path):
			node.free()
		else:
			result[path] = node
	return result


static func _create_geo_asset_node(path: String, modified: int, info: Dictionary, options: Dictionary) -> Node3D:
	var node := Node3D.new()
	node.name = _geo_node_name_for_path(path)
	_rebuild_geo_asset_node(node, path, modified, info, options)
	return node


static func _rebuild_geo_asset_node(node: Node3D, path: String, modified: int, info: Dictionary, options: Dictionary) -> void:
	for child in node.get_children():
		(child as Node).free()

	var mesh: Mesh = info.get("mesh", null)
	if not info.has("mesh_transform"):
		push_error("[GeoAssetScanService] _rebuild_geo_asset_node(): %s 的 mesh_info 缺 \"mesh_transform\" 键 —— DemoAssets.load_mesh_info 契约被破坏" % path)
		assert(false, "GeoAssetScanService: mesh_info missing mesh_transform")
		return
	var mesh_transform: Transform3D = info["mesh_transform"]
	var strip_result := FbxVoxelImportService.strip_embedded_data_triangles(mesh)
	if not bool(strip_result.get("ok", false)):
		push_error("[GeoAssetScanService] _rebuild_geo_asset_node(): %s 剥离内嵌数据三角形失败（reason=%s）" % [
			path, str(strip_result.get("reason", "unknown"))])
		assert(false, "GeoAssetScanService: strip_embedded_data_triangles failed")
		return
	var render_mesh: Mesh = strip_result.get("mesh", null)
	if render_mesh == null:
		push_error("[GeoAssetScanService] _rebuild_geo_asset_node(): %s 剥离后没有可渲染 mesh —— 原行为退回未剥离的源 mesh，会把内嵌数据三角形当几何渲染" % path)
		assert(false, "GeoAssetScanService: stripped mesh is null")
		return
	var bounds := mesh_transform * render_mesh.get_aabb()
	var color: Color = DEFAULT_KIND_COLOR

	node.name = _geo_node_name_for_path(path)
	node.scale = Vector3.ONE  # 1:1 — geo assets use their true imported FBX scale
	# 导入的产物必须看得见。Import All 走全量重扫（旧节点先 free 再新建，天然可见），
	# 但 Import FBX 单文件与增量 updated 走的是"就地重建已有节点"，`visible` 不在重建范围内
	# ⇒ 一个此前被隐藏的节点重新导入后仍然是隐藏的，表现为"点了导入但什么都没出现"。
	# ⚠ 隐藏来源不止一处：AssetOverview 的 G 开关会写 visible=false，而编辑器保存场景会把它
	# 落进 .tscn（本场景的五个资产就是这么被腌成 visible=false 的）。所以这行不是防御性冗余，
	# 是导入契约的一部分：导入过的节点一定可见。
	node.visible = true
	node.set_meta(GEO_SOURCE_META, path)
	node.set_meta(GEO_MTIME_META, modified)
	node.set_meta(GEO_BOUND_SIZE_META, bounds.size)
	node.set_meta(GEO_BOUND_LONGEST_META, bounds.get_longest_axis_size())
	node.set_meta(GEO_EMBEDDED_DATA_TRIANGLES_META, int(strip_result.get("removed_data_triangle_count", 0)))
	node.set_meta(GEO_FINE_SCORE_TRIANGLES_META, int(strip_result.get("removed_fine_score_triangle_count", 0)))
	node.set_meta(GEO_PROBE_TRIANGLES_META, int(strip_result.get("removed_probe_triangle_count", 0)))

	var mesh_node := MeshInstance3D.new()
	mesh_node.name = "Mesh"
	# Bake only the import conversion (mesh_transform) into geometry so the Mesh child
	# stays at Transform3D.IDENTITY with clean axes. The mesh keeps its native FBX
	# pivot (cliffs: geometric center), so the container origin sits at that pivot.
	# The same stripped mesh is the only geometry exposed to render or any later
	# collision builder attached to this production asset node.
	mesh_node.mesh = DemoAssets.bake_mesh_xform(render_mesh, mesh_transform)
	mesh_node.transform = Transform3D.IDENTITY
	mesh_node.material_override = _make_geo_asset_material(color)
	node.add_child(mesh_node)

	if bool(options.get("show_helpers", false)):
		var label := VoxelDebugLabel.make(
			"%s\nbound %.2f" % [path.get_file().get_basename(), bounds.get_longest_axis_size()],
			Color.WHITE, 18, 0.0, 0.01, 3, false
		)
		label.name = "AssetLabel"
		label.position = Vector3(0.0, bounds.position.y + bounds.size.y + 0.6, 0.0)
		node.add_child(label)

		var bound_box := _make_geo_bound_box(bounds, options)
		node.add_child(bound_box)


# Red wireframe AABB box. Centered on the mesh's actual AABB in container space, so it
# tracks the native pivot (cliffs: geometric center) wherever the mesh sits.
static func _make_geo_bound_box(bounds: AABB, options: Dictionary) -> MeshInstance3D:
	var color: Color = options.get("bound_box_color", DEFAULT_BOUND_BOX_COLOR)
	var mat := DemoDebugVisuals.make_unshaded_material(color, false, true, true)
	var box := MeshInstance3D.new()
	box.name = "BoundBox"
	box.mesh = DemoDebugVisuals.make_unit_wire_box_mesh()
	box.material_override = mat
	box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	box.position = bounds.position + bounds.size * 0.5
	box.scale = bounds.size
	return box


static func _make_geo_asset_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color.r, color.g, color.b, 1.0)
	mat.roughness = 0.85
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


static func _geo_node_local_aabb(node: Node3D) -> AABB:
	var mi := node.get_node_or_null("Mesh") as MeshInstance3D
	if mi == null or mi.mesh == null:
		# 原行为：捏一个单位立方 AABB 顶上，布局按假尺寸排开，肉眼看不出资产坏了。
		push_error("[GeoAssetScanService] _geo_node_local_aabb(): geo 资产节点 %s 缺少 \"Mesh\" 子节点或其 mesh 为空 —— 无法取得包围盒" % node.name)
		assert(false, "GeoAssetScanService._geo_node_local_aabb: missing Mesh child or mesh")
		return AABB()
	return mi.transform * mi.mesh.get_aabb()


static func _geo_node_name_for_path(path: String) -> String:
	var base := path.get_file().get_basename()
	var safe := ""
	for i in range(base.length()):
		var c := base.substr(i, 1)
		if c.is_valid_identifier() or c.is_valid_int():
			safe += c
		else:
			safe += "_"
	if safe.is_empty():
		safe = "GeoAsset"
	return "Geo_%s" % safe


static func _file_modified_time(path: String) -> int:
	var modified := FileAccess.get_modified_time(path)
	if modified <= 0:
		modified = FileAccess.get_modified_time(ProjectSettings.globalize_path(path))
	if modified <= 0:
		# res:// 与绝对路径都读不到 mtime = 文件不存在/不可读，增量判断的输入本应存在。
		push_error("[GeoAssetScanService] _file_modified_time(): 无法读取 %s 的修改时间（res:// 与绝对路径均失败）—— 文件缺失或不可读" % path)
		assert(false, "GeoAssetScanService._file_modified_time: mtime unavailable")
	return int(modified)


static func _node_and_descendants(node: Node) -> Array[Node]:
	var result: Array[Node] = [node]
	for child in node.get_children():
		result.append_array(_node_and_descendants(child))
	return result
