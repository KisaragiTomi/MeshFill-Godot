@tool
extends RefCounted

const EmbeddedProfileSampleCodecScript := preload("res://scripts/utils/embedded_profile_sample_codec.gd")
const DemoAssetsScript := preload("res://scripts/utils/demo_assets.gd")

# FBX-embedded Fine Score / Probe channel reader (v3).
#
# UV set 0 and UV set 1 retain their existing collision/probe application data.
# uv8 is strictly the 8th imported UV slot (index 7 → ARRAY_CUSTOM2.zw). Fine
# Score owns vertex color plus uv8.x; Probe owns normal plus uv8.y. Godot flips
# imported UV V, so only the Probe boundary restores FBX uv8.y with 1-y.
# Missing UV slots are represented by reader-local placeholders; imported mesh
# arrays are never changed. Raw corner records remain available for inspection,
# while the production result contains only validated ProfileSample records.
#
# ⚠ 不足 8 个 UV set = 报错，不回退（2026-08-17 用户裁定）。旧规则"取最后一个有效
# 槽当 uv8"会在只有贴图/lightmap UV 的普通网格上把 uv0/uv1 当门控通道读：三个角
# 恰好压在 UV 边界线（u==1，或 FBX v==1）上的三角形被误判成数据三角形，再被
# strip_embedded_data_triangles 从生产几何里静默剥掉。现存五个 geo 资产与
# targetsv0.fbx 实测 uv8 全部落在 index 7（descriptor 的 provenance 与桥上
# validate_fbx 双向证实），严格第 8 槽对两条链都无行为差异；差异只落在
# 不合规网格上——它们现在会在生产读取路径被点名报错（碰撞辅助节点 UCX_ 等豁免）。
#
# Legacy fallback: one FBX carries two extra mesh objects recognised by name:
#   MF_Voxels  — one vertex per occupied voxel; per-vertex data packed as
#                P   = local position (metres)            -> voxel grid coord
#                Cd  = color.rgb, Cd.a = complexity
#                uv0 = (collision, weight)
#                uv1 = (flags, cell_size)                  (cell_size same on every vertex)
#   MF_Probes  — optional; P = offset, Cd.rgb/a = expected color/complexity.
#
# The legacy MF_Voxels reader remains available at this importer boundary for
# migration diagnostics. Bake AD consumes canonical v3 ProfileSamples directly
# and never reinterprets them as dense voxels.
#
const VOXELS_NODE := "MF_Voxels"
const PROBES_NODE := "MF_Probes"
const FINE_SCORE_UV_X := 1.0
const PROBE_UV_Y := 1.0
const MAX_IMPORTED_UV_SETS := 8
const CHANNEL_EPSILON := 0.0001
const DEGENERATE_CROSS_EPSILON_SQUARED := 1.0e-20


# ── Verification / inspection ────────────────────────────────────────────────
# Load an FBX and report exactly what Godot's importer produced: every mesh
# node, its surfaces' primitive type, vertex count, which per-vertex arrays
# survived, and a few sample vertices. Run this on a throwaway test FBX to lock
# the convention (points vs prims, sRGB/V-flip) before trusting the reader.
static func inspect_fbx(fbx_path: String, opts := {}) -> Dictionary:
	var res: Variant = ResourceLoader.load(fbx_path)
	if res == null:
		return {"ok": false, "reason": "load_failed", "path": fbx_path}
	var report := {
		"ok": true,
		"path": fbx_path,
		"resource_type": res.get_class(),
		"payload_schema": "profile_sample_v1",
		"meshes": [],
	}
	if res is Mesh:
		report["meshes"].append(_inspect_mesh("(root Mesh)", res as Mesh, Transform3D.IDENTITY, opts))
		_add_channel_summary(report)
		return report
	if res is PackedScene:
		var root := (res as PackedScene).instantiate()
		if root != null:
			var meshes: Array = report["meshes"]
			walk_mesh_instances(root, Transform3D.IDENTITY,
				func(node_name: String, mesh: Mesh, mesh_transform: Transform3D) -> void:
					meshes.append(_inspect_mesh(node_name, mesh, mesh_transform, opts)),
				true)
			root.free()
		_add_channel_summary(report)
		return report
	return {"ok": false, "reason": "not_scene_or_mesh", "resource_type": res.get_class()}


## 唯一的递归 mesh 遍历器：累积节点变换，对每个带 mesh 的 MeshInstance3D 调
## per_mesh(node_name, mesh, mesh_transform)。
## ⚠ 这里曾有**四份**逐字相同的递归骨架（inspection / channel records / fine columns 各一份，
## 外加 TargetSVFbxImportService 的结构收集），只差 per-mesh 那一行——2026-08-17 收敛到此。
## is_scene_root=true 跳过根节点自身的 transform（场景根不属于 FBX 内容，与旧四份同口径）。
static func walk_mesh_instances(
	node: Node,
	parent_transform: Transform3D,
	per_mesh: Callable,
	is_scene_root: bool = false
) -> void:
	var node_transform := parent_transform
	if node is Node3D and not is_scene_root:
		node_transform = parent_transform * (node as Node3D).transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		per_mesh.call(str(node.name), (node as MeshInstance3D).mesh, node_transform)
	for child in node.get_children():
		walk_mesh_instances(child, node_transform, per_mesh)


static func _inspect_mesh(
	node_name: String, mesh: Mesh, mesh_transform: Transform3D, opts: Dictionary
) -> Dictionary:
	var out := {"node": node_name, "class": mesh.get_class(), "surfaces": []}
	for s in range(mesh.get_surface_count()):
		var prim: int = mesh.surface_get_primitive_type(s)
		var arrays := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX] if arrays[Mesh.ARRAY_VERTEX] != null else PackedVector3Array()
		var colors = arrays[Mesh.ARRAY_COLOR]
		var uv_info := logical_uv_sets_from_surface_arrays(arrays, verts.size())
		var uv0: PackedVector2Array = uv_info["uv0"]
		var uv1: PackedVector2Array = uv_info["uv1"]
		var uv8: PackedVector2Array = uv_info["uv8"]
		var uv0_source_count := int(uv_info["uv0_source_count"])
		var uv1_source_count := int(uv_info["uv1_source_count"])
		var uv8_source_count := int(uv_info["uv8_source_count"])
		var uv8_set_index := int(uv_info["uv8_set_index"])
		var has_uv8 := uv8_set_index >= 0
		var idx = arrays[Mesh.ARRAY_INDEX]
		# Value ranges across ALL verts — reveals whether data actually rides the
		# channels (vs everything defaulting to white / zero).
		var c_lo := Vector4(9, 9, 9, 9)
		var c_hi := Vector4(-9, -9, -9, -9)
		var c_nonwhite := 0
		if colors != null:
			for c in colors:
				c_lo = Vector4(minf(c_lo.x, c.r), minf(c_lo.y, c.g), minf(c_lo.z, c.b), minf(c_lo.w, c.a))
				c_hi = Vector4(maxf(c_hi.x, c.r), maxf(c_hi.y, c.g), maxf(c_hi.z, c.b), maxf(c_hi.w, c.a))
				if not (is_equal_approx(c.r, 1.0) and is_equal_approx(c.g, 1.0) and is_equal_approx(c.b, 1.0)):
					c_nonwhite += 1
		var u_lo := Vector2(9, 9)
		var u_hi := Vector2(-9, -9)
		for i in range(uv0_source_count):
			var u := uv0[i]
			u_lo = Vector2(minf(u_lo.x, u.x), minf(u_lo.y, u.y))
			u_hi = Vector2(maxf(u_hi.x, u.x), maxf(u_hi.y, u.y))
		var godot_u8_lo := Vector2(9, 9)
		var godot_u8_hi := Vector2(-9, -9)
		var fbx_u8_lo := Vector2(9, 9)
		var fbx_u8_hi := Vector2(-9, -9)
		if has_uv8:
			for i in range(uv8_source_count):
				var u := uv8[i]
				godot_u8_lo = Vector2(minf(godot_u8_lo.x, u.x), minf(godot_u8_lo.y, u.y))
				godot_u8_hi = Vector2(maxf(godot_u8_hi.x, u.x), maxf(godot_u8_hi.y, u.y))
				var fbx_y := _restore_fbx_uv8_y_at_probe_boundary(u.y)
				fbx_u8_lo = Vector2(minf(fbx_u8_lo.x, u.x), minf(fbx_u8_lo.y, fbx_y))
				fbx_u8_hi = Vector2(maxf(fbx_u8_hi.x, u.x), maxf(fbx_u8_hi.y, fbx_y))
		var channels := _surface_channel_data(prim, arrays, mesh_transform, node_name, s, opts)
		var samples: Array = []
		for i in range(mini(4, verts.size())):
			var fbx_uv8_sample: Variant = null
			if has_uv8 and i < uv8_source_count:
				fbx_uv8_sample = [uv8[i].x, _restore_fbx_uv8_y_at_probe_boundary(uv8[i].y)]
			samples.append({
				"P": [verts[i].x, verts[i].y, verts[i].z],
				"color": ([colors[i].r, colors[i].g, colors[i].b, colors[i].a] if colors != null and i < colors.size() else null),
				"uv0": ([uv0[i].x, uv0[i].y] if i < uv0_source_count else null),
				"uv1": ([uv1[i].x, uv1[i].y] if i < uv1_source_count else null),
				"uv8_fbx": fbx_uv8_sample,
				"godot_uv8": ([uv8[i].x, uv8[i].y] if has_uv8 and i < uv8_source_count else null),
			})
		out["surfaces"].append({
			"index": s,
			"primitive": prim,
			"primitive_name": _prim_name(prim),
			"vertex_count": verts.size(),
			"index_count": (idx.size() if idx != null else 0),
			"has_color": colors != null and colors.size() > 0,
			"has_normal": arrays[Mesh.ARRAY_NORMAL] != null and arrays[Mesh.ARRAY_NORMAL].size() > 0,
			"has_uv": uv0_source_count > 0,
			"has_uv2": uv1_source_count > 0,
			"has_uv8": has_uv8,
			"uv8_set_index": uv8_set_index,
			"uv8_source": str(uv_info["uv8_source"]),
			"uv_placeholder_indices": uv_info["placeholder_indices"],
			"color_range": ([c_lo.x, c_lo.y, c_lo.z, c_lo.w, c_hi.x, c_hi.y, c_hi.z, c_hi.w] if colors != null and colors.size() > 0 else null),
			"color_nonwhite": c_nonwhite,
			"uv_range": ([u_lo.x, u_lo.y, u_hi.x, u_hi.y] if uv0_source_count > 0 else null),
			"uv8_fbx_range": ([fbx_u8_lo.x, fbx_u8_lo.y, fbx_u8_hi.x, fbx_u8_hi.y] if has_uv8 else null),
			"godot_uv8_range": ([godot_u8_lo.x, godot_u8_lo.y, godot_u8_hi.x, godot_u8_hi.y] if has_uv8 else null),
			"fine_score_triangle_count": (channels["fine_score_records"] as Array).size(),
			"probe_triangle_count": (channels["probe_records"] as Array).size(),
			"fine_score_marked_triangle_count": int(channels["fine_score_marked_triangle_count"]),
			"probe_marked_triangle_count": int(channels["probe_marked_triangle_count"]),
			"fine_score_missing_payload_count": int(channels["fine_score_missing_payload_count"]),
			"probe_missing_payload_count": int(channels["probe_missing_payload_count"]),
			"profile_sample_count": (channels["profile_samples"] as Array).size(),
			"profile_sample_error_count": (channels["profile_sample_errors"] as Array).size(),
			"profile_sample_errors": (channels["profile_sample_errors"] as Array).slice(0, 8),
			"degenerate_data_triangle_count": int(channels["degenerate_data_triangle_count"]),
			"fine_score_position_samples": _record_position_samples(channels["fine_score_records"], 4),
			"probe_position_samples": _record_position_samples(channels["probe_records"], 4),
			"samples": samples,
		})
	return out


# 三个 reader 视图：uv0 / uv1 / uv8。
#
# uv8 **严格取第 8 个 UV 槽**（index 7 = Houdini uv8 → ARRAY_CUSTOM2.zw；现存资产与
# targetsv0.fbx 实测全部落在这里，见文件头）。缺第 8 槽时 uv8_set_index = -1，uv8 给
# 全长禁用占位（Godot 空间 (0,1) → 还原到 FBX (0,0)，fine 与 probe 两道门都不可能武装）；
# **是否报错归门控消费方**（生产读取路径报错、碰撞辅助节点豁免），本函数保持纯计算。
#
# ⚠ 这里曾把 8 个槽位全部物化成全长数组再挑一个：uv0/uv1 各一趟逐元素拷贝循环、
# uv2..uv7 各一趟 CUSTOM 解交错循环，其中 5 趟的产物直接丢弃——108 万角的场景级 FBX 上
# 是每 surface 约 8 趟百万级 GDScript 循环 + ~8 份全长数组分配，TargetSV 导入读段的
# 主要浪费。现在只物化真正被消费的三份：uv0/uv1 覆盖满 vertex_count 时直接引用源数组
# （CoW 零拷贝），只有 uv8 需要一趟 CUSTOM 解交错。
#
# uv8 必须是全长数组：fine/probe 门按顶点下标直索引（不经 source_count 守卫）。
# 占位与补齐一律用 (0,1)——旧实现对"源比顶点短"的畸形面补的是零，而 Godot 空间 (0,0)
# 还原到 FBX v=1 会**武装 probe 门**，(0,1) 才是真禁用。
static func logical_uv_sets_from_surface_arrays(arrays: Array, vertex_count: int) -> Dictionary:
	var safe_vertex_count := maxi(vertex_count, 0)
	var source_counts := PackedInt32Array()
	var placeholder_indices := PackedInt32Array()
	var populated_set_count := 0
	for uv_set_index in range(MAX_IMPORTED_UV_SETS):
		var source_count := _uv_slot_source_count(arrays, uv_set_index, safe_vertex_count)
		source_counts.append(source_count)
		if source_count > 0:
			populated_set_count += 1
		else:
			placeholder_indices.append(uv_set_index)
	var uv8_slot := MAX_IMPORTED_UV_SETS - 1
	var uv8_source_count := source_counts[uv8_slot]
	var uv8_set_index := uv8_slot if uv8_source_count > 0 else -1
	var uv8 := PackedVector2Array()
	uv8.resize(safe_vertex_count)
	uv8.fill(Vector2(0.0, 1.0))
	if uv8_source_count > 0:
		_extract_custom_uv_pairs_into(uv8, arrays, uv8_slot, uv8_source_count)
	return {
		"placeholder_indices": placeholder_indices,
		"populated_set_count": populated_set_count,
		"uv0": _tex_uv_view(arrays, Mesh.ARRAY_TEX_UV, source_counts[0], safe_vertex_count),
		"uv1": _tex_uv_view(arrays, Mesh.ARRAY_TEX_UV2, source_counts[1], safe_vertex_count),
		"uv8": uv8,
		"uv0_source_count": source_counts[0],
		"uv1_source_count": source_counts[1],
		"uv8_source_count": uv8_source_count,
		"uv8_set_index": uv8_set_index,
		"uv8_source": _uv_set_source_label(uv8_set_index),
	}


# 槽位覆盖数（不物化数据）。0/1 = TEX_UV/TEX_UV2；2..7 = CUSTOM 通道的成对分量。
# 判据与旧实现逐位相同：PackedFloat32Array、按 vertex_count 整除出 stride、
# stride 盖住分量对才算在场。
static func _uv_slot_source_count(arrays: Array, uv_set_index: int, vertex_count: int) -> int:
	if uv_set_index <= 1:
		var array_index := Mesh.ARRAY_TEX_UV if uv_set_index == 0 else Mesh.ARRAY_TEX_UV2
		if arrays.size() > array_index and arrays[array_index] is PackedVector2Array:
			return mini((arrays[array_index] as PackedVector2Array).size(), vertex_count)
		return 0
	var custom_array_index := Mesh.ARRAY_CUSTOM0 + ((uv_set_index - 2) / 2)
	var component_offset := ((uv_set_index - 2) % 2) * 2
	if arrays.size() <= custom_array_index or not (arrays[custom_array_index] is PackedFloat32Array):
		return 0
	var source: PackedFloat32Array = arrays[custom_array_index]
	if vertex_count <= 0 or source.size() % vertex_count != 0:
		return 0
	var stride := source.size() / vertex_count
	if stride < component_offset + 2:
		return 0
	return mini(vertex_count, source.size() / stride)


# TEX_UV / TEX_UV2 的 reader 视图。全覆盖时直接引用源数组（消费方只读，CoW 安全）；
# 源比顶点短的畸形面 duplicate+resize 补零到全长（C++ 快路径，无 GDScript 循环）——
# 越过 source_count 的下标不会被任何消费方索引，补齐只为直索引路径不越界。
# 缺席给空数组：uv0/uv1 的全部消费方都按 source_count 守卫，不会索引进去。
static func _tex_uv_view(
	arrays: Array, array_index: int, source_count: int, vertex_count: int
) -> PackedVector2Array:
	if source_count <= 0:
		return PackedVector2Array()
	var source: PackedVector2Array = arrays[array_index]
	if source.size() >= vertex_count:
		return source
	var padded := source.duplicate()
	padded.resize(vertex_count)
	return padded


# 从 CUSTOM 通道解交错出成对分量，写进已按禁用占位预填充的全长数组。
# 前置条件：_uv_slot_source_count 已判定该槽在场（stride 整除且盖住分量对）。
static func _extract_custom_uv_pairs_into(
	target: PackedVector2Array, arrays: Array, uv_set_index: int, source_count: int
) -> void:
	var custom_array_index := Mesh.ARRAY_CUSTOM0 + ((uv_set_index - 2) / 2)
	var component_offset := ((uv_set_index - 2) % 2) * 2
	var source: PackedFloat32Array = arrays[custom_array_index]
	var stride := source.size() / source_count
	for i in range(source_count):
		var base := i * stride + component_offset
		target[i] = Vector2(source[base], source[base + 1])


static func _uv_set_source_label(uv_set_index: int) -> String:
	if uv_set_index < 0:
		return "reader_placeholder_disabled"
	if uv_set_index == 0:
		return "ARRAY_TEX_UV"
	if uv_set_index == 1:
		return "ARRAY_TEX_UV2"
	var custom_index := (uv_set_index - 2) / 2
	var components := "xy" if (uv_set_index - 2) % 2 == 0 else "zw"
	return "ARRAY_CUSTOM%d.%s" % [custom_index, components]
static func _add_channel_summary(report: Dictionary) -> void:
	var fine_positions: Array = []
	var probe_positions: Array = []
	var fine_count := 0
	var probe_count := 0
	var fine_marked_count := 0
	var probe_marked_count := 0
	var fine_missing_count := 0
	var probe_missing_count := 0
	var profile_sample_count := 0
	var profile_sample_errors: Array = []
	var degenerate_count := 0
	for mesh in report.get("meshes", []):
		for surface in (mesh as Dictionary).get("surfaces", []):
			var surface_report := surface as Dictionary
			fine_count += int(surface_report.get("fine_score_triangle_count", 0))
			probe_count += int(surface_report.get("probe_triangle_count", 0))
			fine_marked_count += int(surface_report.get("fine_score_marked_triangle_count", 0))
			probe_marked_count += int(surface_report.get("probe_marked_triangle_count", 0))
			fine_missing_count += int(surface_report.get("fine_score_missing_payload_count", 0))
			probe_missing_count += int(surface_report.get("probe_missing_payload_count", 0))
			profile_sample_count += int(surface_report.get("profile_sample_count", 0))
			profile_sample_errors.append_array(surface_report.get("profile_sample_errors", []))
			degenerate_count += int(surface_report.get("degenerate_data_triangle_count", 0))
			fine_positions.append_array(surface_report.get("fine_score_position_samples", []))
			probe_positions.append_array(surface_report.get("probe_position_samples", []))
	report["fine_score_triangle_count"] = fine_count
	report["probe_triangle_count"] = probe_count
	report["fine_score_marked_triangle_count"] = fine_marked_count
	report["probe_marked_triangle_count"] = probe_marked_count
	report["fine_score_missing_payload_count"] = fine_missing_count
	report["probe_missing_payload_count"] = probe_missing_count
	report["profile_sample_count"] = profile_sample_count
	report["profile_sample_error_count"] = profile_sample_errors.size()
	report["profile_sample_errors"] = profile_sample_errors
	report["degenerate_data_triangle_count"] = degenerate_count
	report["fine_score_position_samples"] = fine_positions.slice(0, mini(16, fine_positions.size()))
	report["probe_position_samples"] = probe_positions.slice(0, mini(16, probe_positions.size()))


static func _record_position_samples(records: Array, limit: int) -> Array:
	var samples: Array = []
	for i in range(mini(records.size(), limit)):
		var p: Vector3 = (records[i] as Dictionary).get("position", Vector3.ZERO)
		samples.append([p.x, p.y, p.z])
	return samples


static func _prim_name(prim: int) -> String:
	match prim:
		Mesh.PRIMITIVE_POINTS: return "POINTS"
		Mesh.PRIMITIVE_LINES: return "LINES"
		Mesh.PRIMITIVE_LINE_STRIP: return "LINE_STRIP"
		Mesh.PRIMITIVE_TRIANGLES: return "TRIANGLES"
		Mesh.PRIMITIVE_TRIANGLE_STRIP: return "TRIANGLE_STRIP"
	return "UNKNOWN(%d)" % prim


# Read both v3 channels and decode validated ProfileSample records.
static func embedded_channels_from_fbx(fbx_path: String, opts := {}) -> Dictionary:
	var res: Variant = ResourceLoader.load(fbx_path)
	if res == null:
		push_error("[FbxVoxelImportService] embedded_channels_from_fbx(): 无法加载 %s —— 文件不存在或导入失败" % fbx_path)
		assert(false, "FbxVoxelImportService.embedded_channels_from_fbx: load failed")
		return {"ok": false, "reason": "load_failed", "path": fbx_path}
	if res is Mesh:
		var mesh_result := embedded_channels_from_mesh(res as Mesh, Transform3D.IDENTITY, opts)
		mesh_result["path"] = fbx_path
		return mesh_result
	if not (res is PackedScene):
		push_error("[FbxVoxelImportService] embedded_channels_from_fbx(): %s 导入结果既不是 PackedScene 也不是 Mesh（%s）" % [fbx_path, res.get_class()])
		assert(false, "FbxVoxelImportService.embedded_channels_from_fbx: not scene or mesh")
		return {"ok": false, "reason": "not_scene_or_mesh", "path": fbx_path}
	var root := (res as PackedScene).instantiate()
	if root == null:
		push_error("[FbxVoxelImportService] embedded_channels_from_fbx(): %s 的 PackedScene 实例化失败" % fbx_path)
		assert(false, "FbxVoxelImportService.embedded_channels_from_fbx: instantiate failed")
		return {"ok": false, "reason": "instantiate_failed", "path": fbx_path}
	var result := embedded_channels_from_node(root, opts)
	result["path"] = fbx_path
	root.free()
	return result


static func embedded_channels_from_mesh(
	mesh: Mesh, mesh_transform := Transform3D.IDENTITY, opts := {}
) -> Dictionary:
	var result := _empty_channel_result()
	if mesh == null:
		result["ok"] = false
		result["reason"] = "null_mesh"
		return result
	_append_mesh_channel_records(mesh, mesh_transform, "(root Mesh)", result, opts)
	return result


static func embedded_channels_from_node(scene_root: Node, opts := {}) -> Dictionary:
	var result := _empty_channel_result()
	if scene_root == null:
		result["ok"] = false
		result["reason"] = "null_scene_root"
		return result
	walk_mesh_instances(scene_root, Transform3D.IDENTITY,
		func(node_name: String, mesh: Mesh, mesh_transform: Transform3D) -> void:
			_append_mesh_channel_records(mesh, mesh_transform, node_name, result, opts),
		true)
	return result


static func fine_score_records_from_fbx(fbx_path: String, opts := {}) -> Array:
	var result := embedded_channels_from_fbx(fbx_path, _channel_read_opts(opts, true, false))
	return _channel_records_or_fail(result, "fine_score_records", fbx_path)


## fine 通道的**列式**读取：每个三角形只往三个 Packed 列里各写一个值 —— 不建角记录、
## 不建 provenance、不建 ProfileSample。
##
## 存在的理由是规模。逐三角形那条路（fine_score_records_from_fbx）每个三角形要建 4 个三元
## Packed 切片、1 个 provenance 字典、1 个 12 键角记录，外加 make_profile_sample 的样本字典
## （其中 provenance 还要深拷贝一份）；三十万面的场景级 FBX 上那是数百万次堆分配与几百 MB
## 常驻，正是 TargetSV 导入耗时的主要来源。角记录本身只有 asset overview 的诊断在看，
## TargetSV 导入一个字段都不读。
##
## ⚠ **通道值只读三角形的第一个角**（2026-08-11，按导出方的约定）。本链路的体素三角形由
## Houdini 逐三角形赋值，三个角在 Cd / uv0.x / uv1.x / uv8.x 上按构造同值，逐角比对是纯
## 开销。代价是这条路**不再守"三角同值"**：某版 FBX 真烘错了会被静默按第一个角取值，而不是
## 判废报出来。要那道守卫就走 fine_score_records_from_fbx —— 那条路仍由
## EmbeddedProfileSampleCodec.fine_corner_disagreement 逐角判定，asset overview 的诊断用的
## 就是它。位置仍取三角形重心（三个角的位置本来就不同值，不在"同值"这条约定之内）。
##
## 缺 Cd 的 surface 与逐三角形那条路一样整面记进 missing_payload_count 并跳过；退化面判据
## 同源。返回的三列下标彼此对齐：第 i 项属于同一个通过的三角形。color.a 已按
## decode_fine_triangle 的口径写成 complexity（uv1.x），collision 单独成列（uv0.x）——两者
## 都是 clamp 前的原值，与逐三角形那条路一样由消费方 clamp。
static func fine_columns_from_fbx(fbx_path: String, opts := {}) -> Dictionary:
	var res: Variant = ResourceLoader.load(fbx_path)
	if res == null:
		push_error("[FbxVoxelImportService] fine_columns_from_fbx(): 无法加载 %s" % fbx_path)
		return {"ok": false, "reason": "load_failed", "path": fbx_path}
	var columns := _empty_fine_columns()
	if res is Mesh:
		_append_mesh_fine_columns(res as Mesh, Transform3D.IDENTITY, "(root Mesh)", columns, opts)
	elif res is PackedScene:
		var root := (res as PackedScene).instantiate()
		if root == null:
			push_error("[FbxVoxelImportService] fine_columns_from_fbx(): %s 的 PackedScene 实例化失败" % fbx_path)
			return {"ok": false, "reason": "instantiate_failed", "path": fbx_path}
		walk_mesh_instances(root, Transform3D.IDENTITY,
			func(node_name: String, mesh: Mesh, mesh_transform: Transform3D) -> void:
				_append_mesh_fine_columns(mesh, mesh_transform, node_name, columns, opts),
			true)
		root.free()
	else:
		push_error("[FbxVoxelImportService] fine_columns_from_fbx(): %s 既不是 PackedScene 也不是 Mesh（%s）" % [
			fbx_path, res.get_class()])
		return {"ok": false, "reason": "not_scene_or_mesh", "resource_type": res.get_class()}
	columns["path"] = fbx_path
	return columns


static func _empty_fine_columns() -> Dictionary:
	return {
		"ok": true,
		"reason": "ok",
		"positions": PackedVector3Array(),
		"colors": PackedColorArray(),
		"collision": PackedFloat32Array(),
		# gated = 过了 fine 门且 surface 带 Cd 的三角形数，即逐三角形那条路会产出的角记录数。
		"gated_triangle_count": 0,
		"rejected_triangle_count": 0,
		"degenerate_triangle_count": 0,
		"missing_payload_count": 0,
		"triangle_count": 0,
	}


static func _append_mesh_fine_columns(
	mesh: Mesh, mesh_transform: Transform3D, node_name: String, columns: Dictionary, opts: Dictionary
) -> void:
	for surface in range(mesh.get_surface_count()):
		_append_surface_fine_columns(
			mesh.surface_get_primitive_type(surface),
			mesh.surface_get_arrays(surface),
			mesh_transform,
			node_name,
			surface,
			columns,
			opts
		)


static func _append_surface_fine_columns(
	primitive: int,
	arrays: Array,
	mesh_transform: Transform3D,
	node_name: String,
	surface_index: int,
	columns: Dictionary,
	opts: Dictionary
) -> void:
	if primitive != Mesh.PRIMITIVE_TRIANGLES or arrays.size() <= Mesh.ARRAY_INDEX:
		return
	var vertices: PackedVector3Array = (
		arrays[Mesh.ARRAY_VERTEX] if arrays[Mesh.ARRAY_VERTEX] != null else PackedVector3Array())
	if vertices.is_empty():
		return
	var vertex_count := vertices.size()
	var uv_info := logical_uv_sets_from_surface_arrays(arrays, vertex_count)
	if int(uv_info["uv8_set_index"]) < 0:
		_report_missing_uv8_slot(node_name, surface_index, uv_info, vertex_count)
		return
	var uv0: PackedVector2Array = uv_info["uv0"]
	var uv1: PackedVector2Array = uv_info["uv1"]
	var uv8: PackedVector2Array = uv_info["uv8"]
	var uv0_source_count := int(uv_info["uv0_source_count"])
	var uv1_source_count := int(uv_info["uv1_source_count"])
	var colors := PackedColorArray()
	if arrays[Mesh.ARRAY_COLOR] != null:
		colors = arrays[Mesh.ARRAY_COLOR]
	var indices: PackedInt32Array = (
		arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array())
	var indexed := not indices.is_empty()
	var element_count := indices.size() if indexed else vertex_count
	var surface_triangles := element_count / 3
	columns["triangle_count"] = int(columns["triangle_count"]) + surface_triangles

	var fine_marker_value := float(opts.get(
		"fine_score_uv_x", opts.get("marker_uv_x", FINE_SCORE_UV_X)))
	var epsilon := maxf(float(opts.get(
		"channel_epsilon", opts.get("marker_uv_epsilon", CHANNEL_EPSILON))), 0.0)
	var degenerate_epsilon_squared := maxf(float(opts.get(
		"degenerate_cross_epsilon_squared", DEGENERATE_CROSS_EPSILON_SQUARED)), 0.0)
	# Cd 整面缺失：逐三角形那条路是逐个三角形记一次 missing_payload，这里照同一口径记满整面。
	var has_color := colors.size() >= vertex_count

	var positions: PackedVector3Array = columns["positions"]
	var out_colors: PackedColorArray = columns["colors"]
	var out_collision: PackedFloat32Array = columns["collision"]
	var gated := 0
	var rejected := 0
	var degenerate := 0
	var missing_payload := 0

	# ⚠ 这条路**不过滤任何三角形**：每个三角形都出一条样本（"有三角形就要转成 TargetSV"）。
	# 原来的四道门（fine 门 / 退化面 / 缺 Cd / uv 覆盖）改成**只计数不丢弃**——它们仍是
	# "这份 FBX 烘对没有"的第一现场，但不再决定谁进不进网格。缺通道的那几条按中性缺省补：
	# 没 Cd 给白色，没 uv0/uv1 给 0（既不占碰撞也不占复杂度，等价于"只有位置"）。
	for base in range(0, element_count - 2, 3):
		var i0 := indices[base] if indexed else base
		var i1 := indices[base + 1] if indexed else base + 1
		var i2 := indices[base + 2] if indexed else base + 2
		# 下标越界不是门禁，是读不出顶点——只有这一种情况仍然跳过。
		if i0 < 0 or i1 < 0 or i2 < 0:
			continue
		if i0 >= vertex_count or i1 >= vertex_count or i2 >= vertex_count:
			continue
		if absf(uv8[i0].x - fine_marker_value) <= epsilon:
			gated += 1
		var p0 := vertices[i0]
		var p1 := vertices[i1]
		var p2 := vertices[i2]
		if (p1 - p0).cross(p2 - p0).length_squared() <= degenerate_epsilon_squared:
			degenerate += 1
		var color := Color.WHITE
		if has_color:
			color = colors[i0]
		else:
			missing_payload += 1
		var collision_value := 0.0
		if i0 < uv0_source_count and i0 < uv1_source_count:
			color.a = uv1[i0].x
			collision_value = uv0[i0].x
		else:
			color.a = 0.0
			rejected += 1
		positions.append(mesh_transform * ((p0 + p1 + p2) / 3.0))
		out_colors.append(color)
		out_collision.append(collision_value)

	columns["positions"] = positions
	columns["colors"] = out_colors
	columns["collision"] = out_collision
	columns["gated_triangle_count"] = int(columns["gated_triangle_count"]) + gated
	columns["rejected_triangle_count"] = int(columns["rejected_triangle_count"]) + rejected
	columns["degenerate_triangle_count"] = int(columns["degenerate_triangle_count"]) + degenerate
	columns["missing_payload_count"] = int(columns["missing_payload_count"]) + missing_payload


static func probe_records_from_fbx(fbx_path: String, opts := {}) -> Array:
	var result := embedded_channels_from_fbx(fbx_path, _channel_read_opts(opts, false, true))
	return _channel_records_or_fail(result, "probe_records", fbx_path)


## 通道读取失败时原来被 `.get(key, [])` 吞成空数组，上游看不出区别。
## 现在失败即报错并硬失败（返回空是"读不到"的唯一表示，但错误已在第一现场喊出来）。
static func _channel_records_or_fail(result: Dictionary, key: String, fbx_path: String) -> Array:
	if not bool(result.get("ok", false)):
		push_error("[FbxVoxelImportService] %s 读取 %s 失败（reason=%s）—— 不再静默返回空数组" % [
			fbx_path, key, str(result.get("reason", "unknown"))])
		assert(false, "FbxVoxelImportService: embedded channel read failed")
		return []
	if not result.has(key):
		push_error("[FbxVoxelImportService] %s 的通道结果缺少 \"%s\" 键 —— 读取结果契约被破坏" % [fbx_path, key])
		assert(false, "FbxVoxelImportService: channel result missing key")
		return []
	return result[key]


static func _empty_channel_result() -> Dictionary:
	return {
		"ok": true,
		"payload_schema": "profile_sample_v1",
		"fine_score_records": [],
		"probe_records": [],
		"profile_samples": [],
		"profile_sample_errors": [],
		"fine_score_marked_triangle_count": 0,
		"probe_marked_triangle_count": 0,
		"fine_score_missing_payload_count": 0,
		"probe_missing_payload_count": 0,
		"degenerate_data_triangle_count": 0,
	}


static func _channel_read_opts(opts: Dictionary, read_fine_score: bool, read_probe: bool) -> Dictionary:
	var channel_opts := opts.duplicate()
	channel_opts["_read_fine_score"] = read_fine_score
	channel_opts["_read_probe"] = read_probe
	return channel_opts


## 不足 8 个 UV set 的统一报错口（fine columns 与 channel records 两条生产读取路径共用）。
## 碰撞辅助节点（UCX_ 等）本就不带数据通道，静默跳过不报。
static func _report_missing_uv8_slot(
	node_name: String, surface_index: int, uv_info: Dictionary, vertex_count: int
) -> void:
	if DemoAssetsScript.is_collision_helper_name(node_name):
		return
	push_error("[FbxVoxelImportService] %s / surface %d 缺第 8 个 UV 槽（实到 %d 个 UV set，vertex_count=%d）—— uv8 门控无处可读，该 surface 不产出任何数据三角形。数据 FBX 必须携带完整 uv..uv8 八个 UV set（2026-08-17 起不足即报错，不再回退到最后一个有效槽）" % [
		node_name, surface_index, int(uv_info["populated_set_count"]), vertex_count])


static func _append_mesh_channel_records(
	mesh: Mesh,
	mesh_transform: Transform3D,
	node_name: String,
	out: Dictionary,
	opts: Dictionary
) -> void:
	for surface in range(mesh.get_surface_count()):
		var channels := _surface_channel_data(
			mesh.surface_get_primitive_type(surface),
			mesh.surface_get_arrays(surface),
			mesh_transform,
			node_name,
			surface,
			opts
		)
		(out["fine_score_records"] as Array).append_array(channels["fine_score_records"])
		(out["probe_records"] as Array).append_array(channels["probe_records"])
		(out["profile_samples"] as Array).append_array(channels["profile_samples"])
		(out["profile_sample_errors"] as Array).append_array(channels["profile_sample_errors"])
		for key in [
			"fine_score_marked_triangle_count",
			"probe_marked_triangle_count",
			"fine_score_missing_payload_count",
			"probe_missing_payload_count",
			"degenerate_data_triangle_count",
		]:
			out[key] = int(out[key]) + int(channels[key])


static func _surface_channel_data(
	primitive: int,
	arrays: Array,
	mesh_transform: Transform3D,
	node_name: String,
	surface_index: int,
	opts: Dictionary
) -> Dictionary:
	var result := {
		"fine_score_records": [],
		"probe_records": [],
		"profile_samples": [],
		"profile_sample_errors": [],
		"fine_score_marked_triangle_count": 0,
		"probe_marked_triangle_count": 0,
		"fine_score_missing_payload_count": 0,
		"probe_missing_payload_count": 0,
		"degenerate_data_triangle_count": 0,
		"data_triangle_indices": [],
		"fine_score_triangle_indices": [],
		"probe_triangle_indices": [],
		"triangle_count": 0,
	}
	if primitive != Mesh.PRIMITIVE_TRIANGLES or arrays.size() <= Mesh.ARRAY_INDEX:
		return result
	var vertices: PackedVector3Array = (
		arrays[Mesh.ARRAY_VERTEX] if arrays[Mesh.ARRAY_VERTEX] != null else PackedVector3Array())
	if vertices.is_empty():
		return result
	var uv_info := logical_uv_sets_from_surface_arrays(arrays, vertices.size())
	# 缺第 8 槽 = 门控通道不存在，报错并整面跳过（见 _report_missing_uv8_slot；uv8 此时是
	# 禁用占位，就算继续扫也一个门都开不了——早退只是省掉那趟必然空手的逐三角形循环）。
	if int(uv_info["uv8_set_index"]) < 0:
		_report_missing_uv8_slot(node_name, surface_index, uv_info, vertices.size())
		return result
	var uv0: PackedVector2Array = uv_info["uv0"]
	var uv1: PackedVector2Array = uv_info["uv1"]
	var uv8: PackedVector2Array = uv_info["uv8"]
	var uv0_source_count := int(uv_info["uv0_source_count"])
	var uv1_source_count := int(uv_info["uv1_source_count"])
	var read_fine_score := bool(opts.get("_read_fine_score", true))
	var read_probe := bool(opts.get("_read_probe", true))
	var colors := PackedColorArray()
	if read_fine_score and arrays[Mesh.ARRAY_COLOR] != null:
		colors = arrays[Mesh.ARRAY_COLOR]
	var normals := PackedVector3Array()
	if read_probe and arrays[Mesh.ARRAY_NORMAL] != null:
		normals = arrays[Mesh.ARRAY_NORMAL]
	var indices: PackedInt32Array = (
		arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array())
	var element_count := indices.size() if not indices.is_empty() else vertices.size()
	result["triangle_count"] = element_count / 3
	var fine_marker_value := float(opts.get(
		"fine_score_uv_x", opts.get("marker_uv_x", FINE_SCORE_UV_X)))
	var probe_marker_value := float(opts.get("probe_uv_y", PROBE_UV_Y))
	var epsilon := maxf(float(opts.get(
		"channel_epsilon", opts.get("marker_uv_epsilon", CHANNEL_EPSILON))), 0.0)
	var degenerate_epsilon_squared := maxf(float(opts.get(
		"degenerate_cross_epsilon_squared", DEGENERATE_CROSS_EPSILON_SQUARED)), 0.0)
	for base in range(0, element_count - 2, 3):
		var i0 := indices[base] if not indices.is_empty() else base
		var i1 := indices[base + 1] if not indices.is_empty() else base + 1
		var i2 := indices[base + 2] if not indices.is_empty() else base + 2
		if i0 < 0 or i1 < 0 or i2 < 0:
			continue
		if i0 >= vertices.size() or i1 >= vertices.size() or i2 >= vertices.size():
			continue
		var triangle_index := base / 3
		var fine_enabled := false
		if read_fine_score:
			fine_enabled = (
				absf(uv8[i0].x - fine_marker_value) <= epsilon
				and absf(uv8[i1].x - fine_marker_value) <= epsilon
				and absf(uv8[i2].x - fine_marker_value) <= epsilon
			)
		var probe_uv8_y := PackedFloat32Array()
		var probe_enabled := false
		if read_probe:
			probe_uv8_y = _probe_fbx_uv8_y_values(uv8, i0, i1, i2)
			probe_enabled = (
				absf(probe_uv8_y[0] - probe_marker_value) <= epsilon
				and absf(probe_uv8_y[1] - probe_marker_value) <= epsilon
				and absf(probe_uv8_y[2] - probe_marker_value) <= epsilon
			)
		if not fine_enabled and not probe_enabled:
			continue
		(result["data_triangle_indices"] as Array).append(triangle_index)
		if fine_enabled:
			result["fine_score_marked_triangle_count"] += 1
			(result["fine_score_triangle_indices"] as Array).append(triangle_index)
		if probe_enabled:
			result["probe_marked_triangle_count"] += 1
			(result["probe_triangle_indices"] as Array).append(triangle_index)
		var p0 := vertices[i0]
		var p1 := vertices[i1]
		var p2 := vertices[i2]
		if (p1 - p0).cross(p2 - p0).length_squared() <= degenerate_epsilon_squared:
			result["degenerate_data_triangle_count"] += 1
			continue
		var centroid := (p0 + p1 + p2) / 3.0
		var corner_indices := PackedInt32Array([i0, i1, i2])
		var corner_positions := PackedVector3Array([p0, p1, p2])
		var local_offset_world := mesh_transform * centroid
		var corner_uv0 := PackedVector2Array()
		var corner_uv1 := PackedVector2Array()
		if i0 < uv0_source_count and i1 < uv0_source_count and i2 < uv0_source_count:
			corner_uv0 = PackedVector2Array([uv0[i0], uv0[i1], uv0[i2]])
		if i0 < uv1_source_count and i1 < uv1_source_count and i2 < uv1_source_count:
			corner_uv1 = PackedVector2Array([uv1[i0], uv1[i1], uv1[i2]])
		var provenance := {
			"mesh_node": node_name,
			"surface_index": surface_index,
			"triangle_index": triangle_index,
			"vertex_indices": corner_indices,
			"uv8_set_index": int(uv_info["uv8_set_index"]),
			"uv8_source": str(uv_info["uv8_source"]),
		}
		if fine_enabled:
			if colors.size() < vertices.size():
				result["fine_score_missing_payload_count"] += 1
			else:
				var fine_colors := PackedColorArray([colors[i0], colors[i1], colors[i2]])
				var fine_gate := PackedFloat32Array([uv8[i0].x, uv8[i1].x, uv8[i2].x])
				var fine_record := {
					"position": local_offset_world,
					"position_mesh_local": centroid,
					"corner_positions_mesh_local": corner_positions,
					"colors": fine_colors,
					"uv0": corner_uv0,
					"uv1": corner_uv1,
					"uv8_x": fine_gate,
					"uv8_set_index": int(uv_info["uv8_set_index"]),
					"uv8_source": str(uv_info["uv8_source"]),
					"mesh_node": node_name,
					"surface_index": surface_index,
					"triangle_index": triangle_index,
					"vertex_indices": corner_indices,
				}
				var fine_decoded := EmbeddedProfileSampleCodecScript.decode_fine_triangle(
					fine_colors, fine_gate, corner_uv0, corner_uv1, local_offset_world, provenance)
				fine_record["decoded_profile_sample"] = fine_decoded.get("sample", {})
				(result["fine_score_records"] as Array).append(fine_record)
				_append_decoded_profile_sample(result, fine_decoded, provenance, "fine")
		if probe_enabled:
			if normals.size() < vertices.size():
				result["probe_missing_payload_count"] += 1
			else:
				var probe_normals := PackedVector3Array([normals[i0], normals[i1], normals[i2]])
				var probe_record := {
					"position": local_offset_world,
					"position_mesh_local": centroid,
					"corner_positions_mesh_local": corner_positions,
					"normals_mesh_local": probe_normals,
					"uv0": corner_uv0,
					"uv1": corner_uv1,
					"uv8_y": probe_uv8_y,
					"uv8_set_index": int(uv_info["uv8_set_index"]),
					"uv8_source": str(uv_info["uv8_source"]),
					"mesh_node": node_name,
					"surface_index": surface_index,
					"triangle_index": triangle_index,
					"vertex_indices": corner_indices,
				}
				var probe_decoded := EmbeddedProfileSampleCodecScript.decode_probe_triangle(
					probe_normals, probe_uv8_y,
					_restore_fbx_uv_y_at_probe_boundary(corner_uv0),
					_restore_fbx_uv_y_at_probe_boundary(corner_uv1),
					local_offset_world, provenance)
				probe_record["decoded_profile_sample"] = probe_decoded.get("sample", {})
				(result["probe_records"] as Array).append(probe_record)
				_append_decoded_profile_sample(result, probe_decoded, provenance, "probe")
	return result


static func _append_decoded_profile_sample(
	result: Dictionary, decoded: Dictionary, provenance: Dictionary, channel: String
) -> void:
	if bool(decoded.get("ok", false)):
		(result["profile_samples"] as Array).append(decoded.get("sample", {}))
		return
	var error := provenance.duplicate(true)
	error["channel"] = channel
	error["reason"] = str(decoded.get("reason", "decode_failed"))
	(result["profile_sample_errors"] as Array).append(error)


# This helper is the sole Godot-V -> FBX-V restoration boundary. Inspection
# consumes the same reader value so all public uv8.y values remain FBX-space.
static func _restore_fbx_uv8_y_at_probe_boundary(godot_uv8_y: float) -> float:
	return 1.0 - godot_uv8_y


static func _probe_fbx_uv8_y_values(
	uv8: PackedVector2Array, i0: int, i1: int, i2: int
) -> PackedFloat32Array:
	return PackedFloat32Array([
		_restore_fbx_uv8_y_at_probe_boundary(uv8[i0].y),
		_restore_fbx_uv8_y_at_probe_boundary(uv8[i1].y),
		_restore_fbx_uv8_y_at_probe_boundary(uv8[i2].y),
	])


## Probe 载荷（collision = uv0.y / complexity = uv1.y）和 uv8.y 一样被 Godot 导入的
## V 翻转改写过（fbx_document.cpp::_process_uv_set 对每个 UV set 都做 y = 1 - y）。
## 门控值 uv8.y 一直有 _restore_fbx_uv8_y_at_probe_boundary 还原，这两条载荷以前漏了，
## 于是整个 COARSE 侧的 collision/complexity 都被读成 1 - 真值：cliff 烘出 0.0（FBX 写的
## 是 1.0）、grass 烘出 1.0/0.9（FBX 写的是 0.0/0.1）。FINE 侧读 .x 不受翻转影响，所以
## 同一份载荷 FINE 读对、COARSE 读反——leaf 的 0.64/0.75 对 0.36/0.25 是该现象的实证。
## x 分量原样保留：它是 FINE 的槽位，probe 解码不读它。
static func _restore_fbx_uv_y_at_probe_boundary(values: PackedVector2Array) -> PackedVector2Array:
	var restored := PackedVector2Array()
	for value in values:
		restored.append(Vector2(value.x, _restore_fbx_uv8_y_at_probe_boundary(value.y)))
	return restored


# Remove the union of Fine Score and Probe data triangles from render/collision
# source geometry. Vertex/color/normal/UV arrays are never mutated in place.
#
# 剥离后的生产网格同时**丢掉 CUSTOM0..3 通道**（uv3..uv8 的载体）：数据三角形已移除，
# 这些通道对保留几何没有任何消费方，留着只是把每顶点多出的浮点列一路胀进 descriptor
# .tres 与顶点缓冲。⚠ 重建的 surface 不携带导入器 LOD（ArrayMesh 没有逐 surface 的
# LOD 读回口）；下游 DemoAssets.bake_mesh_xform 重建时本就同样丢弃，且放置端走
# MultiMesh 渲染不消费 mesh LOD——不在此补。
static func strip_embedded_data_triangles(mesh: Mesh, opts := {}) -> Dictionary:
	if mesh == null:
		return {"ok": false, "reason": "null_mesh", "mesh": null}
	var stripped := ArrayMesh.new()
	if mesh is ArrayMesh:
		var source_array_mesh := mesh as ArrayMesh
		for blend_shape in range(source_array_mesh.get_blend_shape_count()):
			stripped.add_blend_shape(source_array_mesh.get_blend_shape_name(blend_shape))
		stripped.set_blend_shape_mode(source_array_mesh.get_blend_shape_mode())
	var removed_data := 0
	var removed_fine := 0
	var removed_probe := 0
	var source_triangles := 0
	var retained_triangles := 0
	var omitted_surfaces := 0
	for surface in range(mesh.get_surface_count()):
		var primitive: int = mesh.surface_get_primitive_type(surface)
		var arrays := mesh.surface_get_arrays(surface)
		if arrays.is_empty():
			continue
		var channels := _surface_channel_data(
			primitive, arrays, Transform3D.IDENTITY, "(strip)", surface, opts)
		var data_triangles: Array = channels["data_triangle_indices"]
		if primitive == Mesh.PRIMITIVE_TRIANGLES:
			source_triangles += int(channels["triangle_count"])
		removed_data += data_triangles.size()
		removed_fine += (channels["fine_score_triangle_indices"] as Array).size()
		removed_probe += (channels["probe_triangle_indices"] as Array).size()
		var output_arrays := arrays
		var output_lods := {}
		if primitive == Mesh.PRIMITIVE_TRIANGLES and not data_triangles.is_empty():
			output_arrays = arrays.duplicate()
			var source_indices: PackedInt32Array = (
				arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array())
			var vertex_count: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			var filtered_indices := _filter_triangle_elements(
				source_indices, vertex_count, data_triangles)
			retained_triangles += filtered_indices.size() / 3
			if filtered_indices.is_empty():
				omitted_surfaces += 1
				continue
			output_arrays[Mesh.ARRAY_INDEX] = filtered_indices
		elif primitive == Mesh.PRIMITIVE_TRIANGLES:
			retained_triangles += int(channels["triangle_count"])
		_add_surface_copy(stripped, mesh, surface, primitive, output_arrays, output_lods)
	return {
		"ok": true,
		"mesh": (stripped if removed_data > 0 else mesh),
		"removed_data_triangle_count": removed_data,
		"removed_fine_score_triangle_count": removed_fine,
		"removed_probe_triangle_count": removed_probe,
		"source_triangle_count": source_triangles,
		"retained_triangle_count": retained_triangles,
		"omitted_surface_count": omitted_surfaces,
	}


static func _filter_triangle_elements(
	indices: PackedInt32Array, vertex_count: int, removed_triangles: Array
) -> PackedInt32Array:
	var removed := {}
	for triangle_index in removed_triangles:
		removed[int(triangle_index)] = true
	var element_count := indices.size() if not indices.is_empty() else vertex_count
	var filtered := PackedInt32Array()
	for base in range(0, element_count - 2, 3):
		if removed.has(base / 3):
			continue
		filtered.append(indices[base] if not indices.is_empty() else base)
		filtered.append(indices[base + 1] if not indices.is_empty() else base + 1)
		filtered.append(indices[base + 2] if not indices.is_empty() else base + 2)
	return filtered


static func _add_surface_copy(
	target: ArrayMesh,
	source: Mesh,
	surface: int,
	primitive: int,
	arrays: Array,
	lods: Dictionary
) -> void:
	var blend_shapes: Array = source.surface_get_blend_shape_arrays(surface)
	var source_format := 0
	if source is ArrayMesh:
		source_format = (source as ArrayMesh).surface_get_format(surface)
	var format_flags: int = source_format & ~((1 << Mesh.ARRAY_MAX) - 1)
	# 剥掉 CUSTOM 通道（uv3..uv8 载体，见 strip_embedded_data_triangles 注释）。
	# 对应的 3-bit 格式字段必须一起清：格式声明了通道而 arrays 里没有，add_surface 会报废。
	var output_arrays := arrays
	var arrays_copied := false
	for custom_channel in range(4):
		var array_index := Mesh.ARRAY_CUSTOM0 + custom_channel
		if arrays.size() > array_index and arrays[array_index] != null:
			if not arrays_copied:
				output_arrays = arrays.duplicate()
				arrays_copied = true
			output_arrays[array_index] = null
		format_flags &= ~(Mesh.ARRAY_FORMAT_CUSTOM_MASK << (
			Mesh.ARRAY_FORMAT_CUSTOM_BASE + custom_channel * Mesh.ARRAY_FORMAT_CUSTOM_BITS))
	var target_surface := target.get_surface_count()
	target.add_surface_from_arrays(primitive, output_arrays, blend_shapes, lods, format_flags)
	target.surface_set_material(target_surface, source.surface_get_material(surface))
	var surface_name := ""
	if source.has_method("surface_get_name"):
		surface_name = str(source.call("surface_get_name", surface))
	if not surface_name.is_empty():
		target.surface_set_name(target_surface, surface_name)


# ── Legacy named-node readers ────────────────────────────────────────────────
# v3 raw channels are never converted to voxels or semantic probes. These APIs
# now read only the explicitly named MF_Voxels / MF_Probes legacy nodes.
static func voxel_result_from_fbx(fbx_path: String, opts := {}) -> Dictionary:
	var arrays := _read_named_surface_arrays(fbx_path, VOXELS_NODE)
	if arrays.is_empty():
		return {}
	var verts: PackedVector3Array = (
		arrays[Mesh.ARRAY_VERTEX] if arrays[Mesh.ARRAY_VERTEX] != null else PackedVector3Array())
	var colors: PackedColorArray = (
		arrays[Mesh.ARRAY_COLOR] if arrays[Mesh.ARRAY_COLOR] != null else PackedColorArray())
	var uv: PackedVector2Array = (
		arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array())
	var uv2: PackedVector2Array = (
		arrays[Mesh.ARRAY_TEX_UV2] if arrays[Mesh.ARRAY_TEX_UV2] != null else PackedVector2Array())
	if verts.is_empty():
		return {}

	var color_srgb_inverse := bool(opts.get("color_srgb_inverse", false))
	var uv_vflip := bool(opts.get("uv_vflip", false))

	# cell_size: opts override > uv1.y (per-point, constant)。
	# MF_Voxels 格式里 uv1.y 就是 cell_size，缺了 = 载荷损坏；原来最后那句
	# `cell_size = 1.0` 会把整份体素网格按错误尺度解读且完全看不出来。
	var cell_size := float(opts.get("cell_size", 0.0))
	if cell_size <= 0.0 and uv2.size() > 0:
		var cs := uv2[0]
		cell_size = maxf(1.0 - cs.y if uv_vflip else cs.y, 0.0)
	if cell_size <= 0.0:
		push_error("[FbxVoxelImportService] voxel_result_from_fbx(): %s 的 %s 未给出 cell_size（opts 无覆盖，uv1.y 缺失或 <=0，uv2.size=%d）—— 不再按 1.0 兜底解读体素网格" % [
			fbx_path, VOXELS_NODE, uv2.size()])
		assert(false, "FbxVoxelImportService.voxel_result_from_fbx: missing cell_size")
		return {}

	# Dedup by integer grid coord — collapses coincident verts (degenerate-prim
	# encoding) and is a no-op for a true point cloud.
	var by_cell := {}
	for i in range(verts.size()):
		var p := verts[i]
		var gc := Vector3i(roundi(p.x / cell_size), roundi(p.y / cell_size), roundi(p.z / cell_size))
		var col: Color = colors[i] if i < colors.size() else Color.WHITE
		if color_srgb_inverse:
			col = col.linear_to_srgb()
		var uv0: Vector2 = uv[i] if i < uv.size() else Vector2.ZERO
		var uv1: Vector2 = uv2[i] if i < uv2.size() else Vector2.ZERO
		if uv_vflip:
			uv0.y = 1.0 - uv0.y
			uv1.y = 1.0 - uv1.y
		var complexity := clampf(col.a, 0.0, 1.0)
		col.a = complexity
		by_cell[gc] = {
			"voxel": gc,
			"color": col,
			"complexity": complexity,
			"collision": clampf(uv0.x, 0.0, 1.0),
			"weight": maxf(uv0.y, 0.0),
			"flags": int(round(uv1.x)),
		}

	if by_cell.is_empty():
		return {}

	# Shift the explicit legacy MF_Voxels payload to a 0-based grid for the baker.
	var min_g := Vector3i(0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF)
	var max_g := Vector3i(-0x7FFFFFFF, -0x7FFFFFFF, -0x7FFFFFFF)
	for gc in by_cell.keys():
		min_g = Vector3i(mini(min_g.x, gc.x), mini(min_g.y, gc.y), mini(min_g.z, gc.z))
		max_g = Vector3i(maxi(max_g.x, gc.x), maxi(max_g.y, gc.y), maxi(max_g.z, gc.z))
	var voxels: Array = []
	for gc in by_cell.keys():
		var v: Dictionary = by_cell[gc]
		v["voxel"] = Vector3i(gc.x - min_g.x, gc.y - min_g.y, gc.z - min_g.z)
		voxels.append(v)
	return {
		"grid": Vector3i(max_g.x - min_g.x + 1, max_g.y - min_g.y + 1, max_g.z - min_g.z + 1),
		"cell_size": cell_size,
		"aabb_min": Vector3(min_g) * cell_size,
		"voxels": voxels,
	}


# Read only the explicitly named legacy MF_Probes payload.
static func probes_from_fbx(fbx_path: String, opts := {}) -> Array:
	var arrays := _read_named_surface_arrays(fbx_path, PROBES_NODE)
	if arrays.is_empty():
		return []
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX] if arrays[Mesh.ARRAY_VERTEX] != null else PackedVector3Array()
	if verts.is_empty():
		return []
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR] if arrays[Mesh.ARRAY_COLOR] != null else PackedColorArray()
	var color_srgb_inverse := bool(opts.get("color_srgb_inverse", false))
	var seen := {}
	var probes: Array = []
	for i in range(verts.size()):
		var p := verts[i]
		# Dedup coincident verts (degenerate-prim encoding) at mm resolution.
		var key := Vector3i(roundi(p.x * 1000.0), roundi(p.y * 1000.0), roundi(p.z * 1000.0))
		if seen.has(key):
			continue
		seen[key] = true
		var col: Color = colors[i] if i < colors.size() else Color.WHITE
		if color_srgb_inverse:
			col = col.linear_to_srgb()
		var complexity := clampf(col.a, 0.0, 1.0)
		probes.append({
			"offset": p,
			"expected_color": Color(col.r, col.g, col.b, complexity),
			"expected_complexity": complexity,
		})
	return probes


# ── Internals ────────────────────────────────────────────────────────────────
# Instantiate the FBX scene, find the named mesh node, copy out surface 0's
# arrays (PackedArrays are value types, so safe after freeing the instance).
static func _read_named_surface_arrays(fbx_path: String, node_name: String) -> Array:
	var res: Variant = ResourceLoader.load(fbx_path)
	if not (res is PackedScene):
		return []
	var root := (res as PackedScene).instantiate()
	if root == null:
		return []
	var node := _find_mesh_node(root, node_name)
	var arrays: Array = []
	if node != null and node.mesh != null and node.mesh.get_surface_count() > 0:
		arrays = node.mesh.surface_get_arrays(0)
	root.free()
	return arrays


static func _find_mesh_node(node: Node, node_name: String) -> MeshInstance3D:
	if node is MeshInstance3D and String(node.name) == node_name:
		return node as MeshInstance3D
	for child in node.get_children():
		var found := _find_mesh_node(child, node_name)
		if found != null:
			return found
	return null
