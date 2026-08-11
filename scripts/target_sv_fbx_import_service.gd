@tool
extends RefCounted

## TargetSV FBX 导入 —— 把一份"每个三角形 = 一个体素"的 FBX 烘成 TargetSV 四件套。
##
## **通道规则不自带一套**，整个复用 asset overview 那一条（FbxVoxelImportService 的 v3
## 内嵌通道读取器，走它的列式出口 fine_columns_from_fbx）：每个三角形出一条样本 ——
## 位置取三角形重心，Cd 给 color.rgb，uv1.x 给 complexity，uv0.x 给 collision，
## uv8.x==1.0 是 fine 门。
##
## ⚠ 通道值**只读三角形的第一个角**：本链路的体素三角形由 Houdini 逐三角形赋值，三个角
## 按构造同值，逐角比对是纯开销（2026-08-11 按导出方约定去掉）。因此这条路不再守"三角
## 同值"——烘错了会静默按第一个角取值。要那道守卫走读取器的逐三角形出口，判定归它所有
## （EmbeddedProfileSampleCodec.fine_corner_disagreement），本模块不复制一份。
##
## **空间契约照搬点云转换器**（demos/target-sv-point-cloud-conversion-c 记录的那一份，也是
## 现存 assets/target_sv 的产出规则），只把载体从点换成三角形重心：
##   * texture_size 取自高度图宽度（必须是方图），不是随便取的常数
##   * capture_size 缺省 = max(X 跨度, Z 跨度)
##   * vertical_span 缺省 = max(16, ceil(max 相对高 / 8) * 8)
##   * P.y **是世界绝对高度**（height_mode 缺省 absolute）：落格前减掉该列地形高度
##     = 高度图采样 × height_scale；减完 y < 0 的压到底层切片并计数，
##     y >= span 计入 clipped 并压到顶层切片
##   * Houdini +Z 与高度图行序相反 ⇒ 默认翻转 Z
##   * 同格聚合：complexity / collision 取 max，颜色按 max(complexity, collision, 0.001) 加权平均
##   * 缓冲下标 = (slice * ts + z) * ts + x，即 VoxelGeneral.voxel_index 在网格 (ts, slices, ts) 下的式子
##
## ⚠ **翻转 Z 与 P.y 的高度语义这两条必须逐份 FBX 对过高度图再信**。判据：算「每列最低占用
## 切片」与 scene_height_0_1.png 的相关系数。相关性高 ⇒ 切片位置几乎只在编码地形自身的起伏，
## 说明 P.y 是**世界绝对**高度，必须走 height_mode=absolute；按 relative 读会把整份切片预算
## 花在地形量程上，每列只剩一两层装内容，三角形成片塌进同一格。
## targetsv0.fbx 实测 0.988、回归 切片高度 ≈ 高度图 × 118.7 ⇒ 缺省已定为 absolute
## （2026-08-11）。Z 对不上就传 flip_z=false 重来。
## 本模块把用到的每个参数都回报出去，不留隐式默认。
##
## 产出格式 = SceneVoxelTileCodec 的规范场对（rgba8_unorm / r8_unorm），与其余 volume 同一套。

const FbxVoxelImportServiceScript := preload("res://scripts/fbx_voxel_import_service.gd")
const BufferUtils := preload("res://scripts/utils/buffer_utils.gd")

const DEFAULT_HEIGHT_TEXTURE := "res://textures/scene_height_0_1.png"
const DEFAULT_SLICE_COUNT := 16
const DEFAULT_HEIGHT_SCALE := 120.0
const MIN_VERTICAL_SPAN := 16.0
const VERTICAL_SPAN_QUANTUM := 8.0
const WEIGHT_FLOOR := 0.001
const DEFAULT_OCCUPANCY_EPSILON := 0.001
const EXTENT_EPSILON := 0.0001
const HEIGHT_MODE_RELATIVE := "relative"
const HEIGHT_MODE_ABSOLUTE := "absolute"


## 只读校验：这份 FBX 能不能当 TargetSV 用。**不写任何文件**。
##
## 分两级，是因为深读要把整份网格过一遍并试算落格。先做便宜的结构扫描（只问每个 surface
## 的顶点数、索引数、各通道在不在），把规模摆出来；deep=true 时才做那趟完整读取与落格试算
## （走 dry_run，与真正导入同一条列式路径，数字因此逐项一致）。
##
## 结构级判定的依据就是 fine 通道的构成：Cd（顶点色）、uv0、uv1 必须在，且必须存在 uv8
## 槽位（fine 门 uv8.x 的载体）。缺任何一项，这份 FBX 一个体素都出不来。
static func validate_fbx(fbx_path: String, opts: Dictionary = {}) -> Dictionary:
	var res: Variant = ResourceLoader.load(fbx_path)
	if res == null:
		return {"ok": false, "reason": "load_failed", "fbx": fbx_path}
	var surfaces: Array = []
	if res is Mesh:
		_collect_surface_structure(res as Mesh, "(root Mesh)", surfaces)
	elif res is PackedScene:
		var root := (res as PackedScene).instantiate()
		if root == null:
			return {"ok": false, "reason": "instantiate_failed", "fbx": fbx_path}
		_collect_structure_from_node(root, surfaces)
		root.free()
	else:
		return {"ok": false, "reason": "not_scene_or_mesh", "resource_type": res.get_class()}

	var triangle_total := 0
	var vertex_total := 0
	var missing: Array = []
	for surface in surfaces:
		triangle_total += int(surface["triangle_count"])
		vertex_total += int(surface["vertex_count"])
		var lacks := PackedStringArray()
		if not bool(surface["has_color"]): lacks.append("Cd")
		if not bool(surface["has_uv0"]): lacks.append("uv0(collision)")
		if not bool(surface["has_uv1"]): lacks.append("uv1(complexity)")
		if not bool(surface["has_uv8"]): lacks.append("uv8(fine gate)")
		if not bool(surface["is_triangles"]): lacks.append("PRIMITIVE_TRIANGLES")
		if not lacks.is_empty():
			missing.append({"surface": surface["name"], "index": surface["index"],
				"missing": lacks, "primitive": surface["primitive_name"]})

	var report := {
		"ok": true,
		"reason": "structure_ok" if missing.is_empty() else "channels_missing",
		"fbx": fbx_path,
		"resource_type": res.get_class(),
		"surface_count": surfaces.size(),
		"vertex_count": vertex_total,
		"triangle_count": triangle_total,
		"surfaces": surfaces,
		"channels_missing": missing,
		"deep": false,
	}
	if not missing.is_empty():
		report["ok"] = false
		return report
	if not bool(opts.get("deep", false)):
		return report

	# 深读：走完整通道读取 + 落格试算，但**不写文件**。返回的数字与真正导入时一致。
	var deep := import_fbx_as_target_sv(fbx_path, _merged_dry_run_opts(opts))
	deep["structure"] = report
	deep["deep"] = true
	return deep


static func _merged_dry_run_opts(opts: Dictionary) -> Dictionary:
	var merged := opts.duplicate()
	merged.erase("deep")
	merged["dry_run"] = true
	return merged


static func _collect_structure_from_node(node: Node, out: Array) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		_collect_surface_structure((node as MeshInstance3D).mesh, str(node.name), out)
	for child in node.get_children():
		_collect_structure_from_node(child, out)


## 只取尺寸与"通道在不在"，不建任何逐三角形结构——这是本校验便宜的原因。
static func _collect_surface_structure(mesh: Mesh, node_name: String, out: Array) -> void:
	for surface_index in range(mesh.get_surface_count()):
		var primitive: int = mesh.surface_get_primitive_type(surface_index)
		var arrays := mesh.surface_get_arrays(surface_index)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX] if arrays[Mesh.ARRAY_VERTEX] != null else PackedVector3Array()
		var indices = arrays[Mesh.ARRAY_INDEX]
		var index_count: int = indices.size() if indices != null else 0
		var corner_count := index_count if index_count > 0 else vertices.size()
		var colors = arrays[Mesh.ARRAY_COLOR]
		var uv_info := FbxVoxelImportServiceScript.logical_uv_sets_from_surface_arrays(arrays, vertices.size())
		out.append({
			"name": node_name,
			"index": surface_index,
			"primitive_name": _primitive_name(primitive),
			"is_triangles": primitive == Mesh.PRIMITIVE_TRIANGLES,
			"vertex_count": vertices.size(),
			"index_count": index_count,
			"triangle_count": corner_count / 3 if primitive == Mesh.PRIMITIVE_TRIANGLES else 0,
			"has_color": colors != null and colors.size() > 0,
			"has_uv0": int(uv_info["uv0_source_count"]) > 0,
			"has_uv1": int(uv_info["uv1_source_count"]) > 0,
			"has_uv8": int(uv_info["uv8_set_index"]) >= 0,
			"uv8_set_index": int(uv_info["uv8_set_index"]),
		})


static func _primitive_name(primitive: int) -> String:
	match primitive:
		Mesh.PRIMITIVE_TRIANGLES: return "TRIANGLES"
		Mesh.PRIMITIVE_TRIANGLE_STRIP: return "TRIANGLE_STRIP"
		Mesh.PRIMITIVE_POINTS: return "POINTS"
		Mesh.PRIMITIVE_LINES: return "LINES"
	return "OTHER(%d)" % primitive


## fbx_path: res:// 下的 FBX。opts 见下方 _resolved_options，缺省值即上面注释里那套契约。
## opts.dry_run=true 时算到落格为止就返回，**不写任何文件**（validate_fbx 的深读用的就是它）。
## 返回 {ok, reason, ...}；ok=true 且非 dry_run 时，assets/target_sv 下四个文件已被覆盖写入。
static func import_fbx_as_target_sv(fbx_path: String, opts: Dictionary = {}) -> Dictionary:
	var settings := _resolved_options(opts)

	var height_image := _load_height_image(str(settings["height_texture"]))
	if height_image == null:
		return {"ok": false, "reason": "height_texture_unavailable",
			"height_texture": settings["height_texture"]}
	var texture_size := height_image.get_width()
	if texture_size <= 0 or height_image.get_height() != texture_size:
		return {"ok": false, "reason": "height_texture_not_square",
			"width": height_image.get_width(), "height": height_image.get_height()}

	# 读取器读不到通道时自己 push_error 并返回 ok=false。这里把"一个 fine 三角形都没有"
	# 当硬失败：那样的 FBX 烘出来就是一整块空场，静默写出去会把现有 TargetSV 换成全空，
	# 且没有任何迹象。
	var read_started := Time.get_ticks_msec()
	var columns: Dictionary = FbxVoxelImportServiceScript.fine_columns_from_fbx(fbx_path)
	if not bool(columns.get("ok", false)):
		return {"ok": false, "reason": str(columns.get("reason", "fine_columns_read_failed")),
			"fbx": fbx_path}
	if int(columns["gated_triangle_count"]) == 0:
		return {"ok": false, "reason": "no_fine_score_triangles", "fbx": fbx_path,
			"triangle_count": int(columns["triangle_count"]),
			"hint": "每个体素三角形需要三角同值的 uv8.x=1（fine 门）、Cd、uv0.x(collision)、uv1.x(complexity)"}
	var positions: PackedVector3Array = columns["positions"]
	var colors: PackedColorArray = columns["colors"]
	var collisions: PackedFloat32Array = columns["collision"]
	if positions.is_empty():
		return {"ok": false, "reason": "no_valid_fine_samples", "fbx": fbx_path,
			"triangle_count": int(columns["gated_triangle_count"]),
			"rejected_triangle_count": int(columns["rejected_triangle_count"]),
			"hint": "三角形都被读取器判废：fine 门 uv8.x 需为 1，且三个角的 Cd / uv0.x / uv1.x 必须同值"}
	positions = _scaled_positions(positions, float(settings["position_scale"]))
	var read_ms := Time.get_ticks_msec() - read_started

	var bin_started := Time.get_ticks_msec()
	var bounds := _sample_bounds(positions)
	var span_x: float = maxf(bounds["max"].x - bounds["min"].x, EXTENT_EPSILON)
	var span_z: float = maxf(bounds["max"].z - bounds["min"].z, EXTENT_EPSILON)
	var capture_size: float = float(settings["capture_size"])
	if capture_size <= 0.0:
		capture_size = maxf(span_x, span_z)

	var height_mode := str(settings["height_mode"])
	if height_mode != HEIGHT_MODE_RELATIVE and height_mode != HEIGHT_MODE_ABSOLUTE:
		return {"ok": false, "reason": "invalid_height_mode", "height_mode": height_mode}

	var grid_columns := {
		"texture_size": texture_size,
		"flip_z": bool(settings["flip_z"]),
		"min": bounds["min"],
		"span_x": span_x,
		"span_z": span_z,
	}
	# 相对高度先算出来：absolute 模式下 vertical_span 必须由**减掉地形之后**的高度推，
	# 拿原始世界 Y 推会得到整个地形量程那么高的跨度，切片全部浪费在地形起伏上。
	var relative := _relative_heights(positions, grid_columns, height_image,
		height_mode, float(settings["height_scale"]))
	var vertical_span: float = float(settings["vertical_span"])
	if vertical_span <= 0.0:
		vertical_span = maxf(MIN_VERTICAL_SPAN,
			ceilf(float(relative["max_value"]) / VERTICAL_SPAN_QUANTUM) * VERTICAL_SPAN_QUANTUM)

	var slice_count := int(settings["slice_count"])
	if slice_count <= 0:
		return {"ok": false, "reason": "invalid_slice_count", "slice_count": slice_count}
	var voxel_count := texture_size * texture_size * slice_count

	var frame := grid_columns.duplicate()
	frame["slice_count"] = slice_count
	frame["voxel_count"] = voxel_count
	frame["vertical_span"] = vertical_span
	var binned := _bin_samples(positions, colors, collisions, relative["values"], frame)
	binned["relative_height_max"] = relative["max_value"]
	binned["height_mode"] = height_mode
	var bin_ms := Time.get_ticks_msec() - bin_started

	# dry_run 在写盘之前收尾：落格统计与推出来的框架参数已经齐了，那正是校验要的东西。
	if bool(settings["dry_run"]):
		return _binning_report(fbx_path, columns, binned, {
			"texture_size": texture_size, "slice_count": slice_count, "voxel_count": voxel_count,
			"capture_size": capture_size, "vertical_span": vertical_span,
			"flip_z": bool(settings["flip_z"]), "height_texture": settings["height_texture"],
			"position_scale": float(settings["position_scale"]),
			"height_mode": height_mode,
			"bounds": bounds,
			"timings_ms": {"read": read_ms, "bin": bin_ms, "write": 0},
		}, {"ok": true, "written": PackedStringArray(), "non_empty_voxel_count": -1, "dry_run": true})

	var write_started := Time.get_ticks_msec()
	var write_result := _write_dataset(binned, height_image, {
		"fbx": fbx_path,
		"texture_size": texture_size,
		"slice_count": slice_count,
		"voxel_count": voxel_count,
		"capture_size": capture_size,
		"vertical_span": vertical_span,
		"height_scale": float(settings["height_scale"]),
		"height_texture": str(settings["height_texture"]),
		"flip_z": bool(settings["flip_z"]),
		"occupancy_epsilon": float(settings["occupancy_epsilon"]),
		"bounds": bounds,
	})
	if not bool(write_result.get("ok", false)):
		return write_result

	return _binning_report(fbx_path, columns, binned, {
		"texture_size": texture_size, "slice_count": slice_count, "voxel_count": voxel_count,
		"capture_size": capture_size, "vertical_span": vertical_span,
		"flip_z": bool(settings["flip_z"]), "height_texture": settings["height_texture"],
		"position_scale": float(settings["position_scale"]),
		"height_mode": height_mode,
		"bounds": bounds,
		"timings_ms": {
			"read": read_ms, "bin": bin_ms,
			"write": Time.get_ticks_msec() - write_started,
		},
	}, write_result)


## dry_run 与真正写盘两条路共用一份报告，免得校验看到的数字和导入时的对不上。
static func _binning_report(
	fbx_path: String,
	columns: Dictionary,
	binned: Dictionary,
	frame: Dictionary,
	write_result: Dictionary
) -> Dictionary:
	var bounds: Dictionary = frame["bounds"]
	var report := {
		"ok": true, "reason": "ok",
		"dry_run": bool(write_result.get("dry_run", false)),
		"source_fbx": fbx_path,
		"triangle_count": int(columns["gated_triangle_count"]),
		"valid_triangle_count": (columns["positions"] as PackedVector3Array).size(),
		"rejected_triangle_count": int(columns["rejected_triangle_count"]),
		# 读取器整趟看到的三角形数（含没过 fine 门的），与退化面数一起报出来：
		# "读了三十万面只有几千面过门"是通道没烘对的第一现场，以前这两个数字断在读取器里。
		"read_triangle_count": int(columns["triangle_count"]),
		"degenerate_triangle_count": int(columns["degenerate_triangle_count"]),
		"missing_payload_count": int(columns["missing_payload_count"]),
		"timings_ms": frame.get("timings_ms", {}),
		"used_triangle_count": int(binned["used_count"]),
		# 落进了多少个**不同**的体素。used 与它的比值 = 平均几个三角形挤一格，
		# 那是"源里一面一格、烘出来却少了很多"的唯一成因（门禁只计数不丢弃了）。
		"distinct_voxel_count": int(binned["distinct_voxel_count"]),
		# 压到最底层切片的数量（以前是丢弃，现在只计数）。
		"below_terrain_count": int(binned["below_terrain_count"]),
		"dropped_out_of_bounds": int(binned["dropped_out_of_bounds"]),
		"clipped_height_count": int(binned["clipped_height_count"]),
		# dry_run 不遍历体素场，占用格数留 -1 表示"没算"，不是 0（0 会被读成"空场"）。
		"non_empty_voxel_count": int(write_result["non_empty_voxel_count"]),
		"texture_size": int(frame["texture_size"]),
		"slice_count": int(frame["slice_count"]),
		"voxel_count": int(frame["voxel_count"]),
		"capture_size": frame["capture_size"],
		"vertical_span": frame["vertical_span"],
		# 用到的假设一律回报，别让调用方去猜生效的是哪套默认。
		"flip_z": frame["flip_z"],
		"position_scale": frame["position_scale"],
		"height_mode": frame["height_mode"],
		# absolute 模式下这是**减掉地形之后**的最大高度，vertical_span 就是按它推的。
		"relative_height_max": binned.get("relative_height_max", 0.0),
		"height_texture": frame["height_texture"],
		"source_bounds": [bounds["min"].x, bounds["max"].x,
			bounds["min"].y, bounds["max"].y, bounds["min"].z, bounds["max"].z],
		"written": write_result["written"],
	}
	# 一个三角形都没落进网格 ⇒ 多半是 FBX 的空间尺度/轴向与本契约不符（比如资产级 FBX
	# 而非场景级），真写盘时写出去的就是一整块空场。照常返回，但把结论喊出来。
	if int(binned["used_count"]) == 0:
		push_warning("[TargetSVFbxImport] %s 没有任何三角形落进网格（越界 %d / 低于地形 %d）—— 检查 FBX 是否为场景尺度、height_mode 与 P.y 的高度语义是否对得上" % [
			fbx_path, int(binned["dropped_out_of_bounds"]), int(binned["below_terrain_count"])])
		report["reason"] = "no_samples_in_grid"
	return report


static func _resolved_options(opts: Dictionary) -> Dictionary:
	return {
		"height_texture": opts.get("height_texture", DEFAULT_HEIGHT_TEXTURE),
		"slice_count": opts.get("slice_count", DEFAULT_SLICE_COUNT),
		"capture_size": opts.get("capture_size", 0.0),      # <= 0 ⇒ 由源包围盒推
		"vertical_span": opts.get("vertical_span", 0.0),    # <= 0 ⇒ 由源最大相对高推
		"height_scale": opts.get("height_scale", DEFAULT_HEIGHT_SCALE),
		"flip_z": opts.get("flip_z", true),
		"occupancy_epsilon": opts.get("occupancy_epsilon", DEFAULT_OCCUPANCY_EPSILON),
		"dry_run": opts.get("dry_run", false),
		# FBX 的单位换算旋钮。Houdini 按厘米导出、Godot 再折回米时，几何会整体缩到 1/100，
		# 于是 capture_size / vertical_span 这些**按源包围盒推**的量全部跟着缩水，
		# 竖直方向尤其致命（所有样本挤进最底下一两个切片）。持久的修法是改导出单位，
		# 这个旋钮是为了不重新导出也能先验证。
		"position_scale": float(opts.get("position_scale", 1.0)),
		# "absolute"（**缺省**）：P.y 是世界绝对高度，落格前先减掉该列地形高度
		#            （高度图采样值 × height_scale）。Houdini 直接导世界坐标就是这个。
		# "relative"：P.y 已是地形相对高度（点云链路的口径）。
		#
		# 2026-08-11 把缺省从 relative 翻成 absolute：拿 targetsv0.fbx 做模块头要求的那遍
		# 高度图对照，实测「每列最低占用切片」与 scene_height_0_1.png 的相关系数 0.988，
		# 回归出 切片高度 ≈ 高度图 × 118.9 —— P.y 携带的就是世界绝对高度。按 relative 读时
		# 16 层切片全花在编码地形自身的起伏上，每列只剩 1.66 层装内容，35.9 万个三角形塌进
		# 7.58 万格（4.74 面/格）。翻成 absolute 后同样 16 层出 13.0 万格（2.77 面/格）。
		"height_mode": str(opts.get("height_mode", HEIGHT_MODE_ABSOLUTE)),
	}


## 高度图是已导入资源，必须经资源加载器读（直接 Image.load_from_file 对 res:// 会警告，
## 且导出版本读不到）——同 TargetSVLoader._read_image 的理由。
static func _load_height_image(path: String) -> Image:
	var texture := load(path) as Texture2D
	if texture == null:
		push_error("[TargetSVFbxImport] 高度图无法加载: %s" % path)
		return null
	return texture.get_image()


## 读取器交回来的是**列式** fine 通道（FbxVoxelImportService.fine_columns_from_fbx）：
## positions / colors(a=complexity) / collision 三列下标对齐。门与判废都归读取器，本模块
## 不复制一份，只取结果并把数量报给用户——"读了多少面、多少面过了 fine 门"是这份 FBX 的
## 通道有没有按约定烘对的第一现场（三角同值已不再校验，见本文件头那条约定）。
##
## 三列携带的量与 Bake AD 消费的 canonical ProfileSample 逐项同源：
## local_offset_world（三角形重心）/ color / complexity / collision，只是不再逐三角形
## 装进字典（三十万面上那是几百 MB 与分钟级的来源）。
##
## position_scale != 1 时整列换算位置（见 _resolved_options 里那条单位说明）。
static func _scaled_positions(
	positions: PackedVector3Array, position_scale: float = 1.0
) -> PackedVector3Array:
	if is_equal_approx(position_scale, 1.0):
		return positions
	var scaled := PackedVector3Array()
	scaled.resize(positions.size())
	for index in range(positions.size()):
		scaled[index] = positions[index] * position_scale
	return scaled


static func _sample_bounds(positions: PackedVector3Array) -> Dictionary:
	var min_v := Vector3(INF, INF, INF)
	var max_v := Vector3(-INF, -INF, -INF)
	for p in positions:
		min_v = Vector3(minf(min_v.x, p.x), minf(min_v.y, p.y), minf(min_v.z, p.z))
		max_v = Vector3(maxf(max_v.x, p.x), maxf(max_v.y, p.y), maxf(max_v.z, p.z))
	return {"min": min_v, "max": max_v}


## 样本 → 网格列 (x, z)。越界返回 (-1, -1)。落格与地形高度采样共用这一处换算，
## 免得两边各写一份、日后只改了一边（尤其 flip_z 这种改一处就整体镜像的量）。
static func _column_of(position: Vector3, columns: Dictionary) -> Vector2i:
	var texture_size := int(columns["texture_size"])
	var origin: Vector3 = columns["min"]
	var x := int(roundf((position.x - origin.x) / float(columns["span_x"]) * float(texture_size - 1)))
	var z := int(roundf((position.z - origin.z) / float(columns["span_z"]) * float(texture_size - 1)))
	if bool(columns["flip_z"]):
		z = texture_size - 1 - z
	if x < 0 or x >= texture_size or z < 0 or z >= texture_size:
		return Vector2i(-1, -1)
	return Vector2i(x, z)


## 每个样本的**地形相对高度**。
##   relative 模式：P.y 原样（点云链路口径）。
##   absolute 模式：P.y − 该列地形高度，地形高度 = 高度图采样(0..1) × height_scale。
## 采样点用的是**翻转之后**的列坐标——高度图行序与体素网格 z 序必须同口径，
## 这也是点云转换器当年的做法（先翻 z 再拿它去查高度图）。
## 越界样本给 -INF，落格阶段照常按"低于地形/越界"丢弃。
static func _relative_heights(
	positions: PackedVector3Array,
	columns: Dictionary,
	height_image: Image,
	height_mode: String,
	height_scale: float
) -> Dictionary:
	var values := PackedFloat32Array()
	values.resize(positions.size())
	var max_value := -INF
	var absolute := height_mode == HEIGHT_MODE_ABSOLUTE
	for index in range(positions.size()):
		var position := positions[index]
		var relative := position.y
		if absolute:
			var column := _column_of(position, columns)
			if column.x < 0:
				values[index] = -INF
				continue
			# 高度图是 0..1 的相对量程，乘 height_scale 还原成世界高度——与
			# TargetSVSetup 显示端 (terrain_height * display_scale) 同一套换算。
			relative = position.y - height_image.get_pixel(column.x, column.y).r * height_scale
		values[index] = relative
		if relative > max_value:
			max_value = relative
	if max_value == -INF:
		max_value = 0.0
	return {"values": values, "max_value": max_value}


## 逐三角形落格。complexity / collision 取 max，颜色按 max(complexity, collision, 0.001)
## 加权平均 —— 与点云转换器同一套聚合，换载体不换规则。
## relative_heights 由 _relative_heights 预先算好（两种高度语义的差异只体现在那里）。
static func _bin_samples(
	positions: PackedVector3Array,
	colors: PackedColorArray,
	collisions: PackedFloat32Array,
	relative_heights: PackedFloat32Array,
	frame: Dictionary
) -> Dictionary:
	var texture_size := int(frame["texture_size"])
	var slice_count := int(frame["slice_count"])
	var voxel_count := int(frame["voxel_count"])
	var vertical_span: float = frame["vertical_span"]

	var complexity_field := PackedFloat32Array(); complexity_field.resize(voxel_count)
	var collision_field := PackedFloat32Array(); collision_field.resize(voxel_count)
	var color_sum_r := PackedFloat32Array(); color_sum_r.resize(voxel_count)
	var color_sum_g := PackedFloat32Array(); color_sum_g.resize(voxel_count)
	var color_sum_b := PackedFloat32Array(); color_sum_b.resize(voxel_count)
	var color_weight := PackedFloat32Array(); color_weight.resize(voxel_count)

	var used_count := 0
	var distinct_voxel_count := 0
	var below_terrain_count := 0
	var dropped_out_of_bounds := 0
	var clipped_height_count := 0
	var slice_scale := float(slice_count) / maxf(vertical_span, EXTENT_EPSILON)
	var span_ceiling := vertical_span - EXTENT_EPSILON

	for sample_index in range(positions.size()):
		var p := positions[sample_index]
		var relative_height := relative_heights[sample_index]
		# 坐标非有限 = 读不出位置，落不了格。这不是门禁，是算不出下标。
		if not (is_finite(p.x) and is_finite(p.z) and is_finite(relative_height)):
			dropped_out_of_bounds += 1
			continue
		# 相对高度为负 = 钻进地形以下。点云链路当年直接丢弃，现在**压到最底层切片**并计数
		# ——"有三角形就要转成 TargetSV"，地形下那一层同样是源里烘出来的内容。
		if relative_height < 0.0:
			below_terrain_count += 1
			relative_height = 0.0
		var column := _column_of(p, frame)
		if column.x < 0:
			dropped_out_of_bounds += 1
			continue
		var x := column.x
		var z := column.y
		if relative_height >= vertical_span:
			clipped_height_count += 1
		var slice_index := clampi(int(floorf(minf(relative_height, span_ceiling) * slice_scale)), 0, slice_count - 1)
		var index := (slice_index * texture_size + z) * texture_size + x

		# color.a 就是 complexity（读取器按 decode_fine_triangle 的口径写进 a），
		# collision 单独成列。两者在这里才 clamp——与逐三角形那条路在 make_profile_sample
		# 里 clamp 的取值等价。
		var color := colors[sample_index]
		var complexity := clampf(color.a, 0.0, 1.0)
		var collision := clampf(collisions[sample_index], 0.0, 1.0)
		var weight := maxf(maxf(complexity, collision), WEIGHT_FLOOR)

		# weight 有 WEIGHT_FLOOR 兜底，恒 > 0，所以 color_weight 还是 0 就等于这一格
		# 第一次被碰到。distinct 与 used 的差就是"几个三角形挤进了同一格"——
		# 网格分辨率够不够，看的是这两个数的比值，不是那几道门禁。
		if color_weight[index] == 0.0:
			distinct_voxel_count += 1

		complexity_field[index] = maxf(complexity_field[index], complexity)
		collision_field[index] = maxf(collision_field[index], collision)
		color_sum_r[index] += clampf(color.r, 0.0, 1.0) * weight
		color_sum_g[index] += clampf(color.g, 0.0, 1.0) * weight
		color_sum_b[index] += clampf(color.b, 0.0, 1.0) * weight
		color_weight[index] += weight
		used_count += 1

	return {
		"complexity": complexity_field,
		"collision": collision_field,
		"color_sum_r": color_sum_r,
		"color_sum_g": color_sum_g,
		"color_sum_b": color_sum_b,
		"color_weight": color_weight,
		"used_count": used_count,
		"distinct_voxel_count": distinct_voxel_count,
		"below_terrain_count": below_terrain_count,
		"dropped_out_of_bounds": dropped_out_of_bounds,
		"clipped_height_count": clipped_height_count,
		"texture_size": texture_size,
		"slice_count": slice_count,
		"voxel_count": voxel_count,
	}


static func _write_dataset(binned: Dictionary, height_image: Image, info: Dictionary) -> Dictionary:
	var texture_size := int(info["texture_size"])
	var slice_count := int(info["slice_count"])
	var voxel_count := int(info["voxel_count"])
	var epsilon: float = info["occupancy_epsilon"]

	var complexity: PackedFloat32Array = binned["complexity"]
	var collision: PackedFloat32Array = binned["collision"]
	var color_sum_r: PackedFloat32Array = binned["color_sum_r"]
	var color_sum_g: PackedFloat32Array = binned["color_sum_g"]
	var color_sum_b: PackedFloat32Array = binned["color_sum_b"]
	var color_weight: PackedFloat32Array = binned["color_weight"]

	var visual_bytes := PackedByteArray(); visual_bytes.resize(voxel_count * 4)
	var collision_bytes := PackedByteArray(); collision_bytes.resize(voxel_count)
	# preview 是各切片的峰值投影（XZ 俯视），与点云链路同口径。
	var peak_complexity := PackedFloat32Array(); peak_complexity.resize(texture_size * texture_size)
	var peak_collision := PackedFloat32Array(); peak_collision.resize(texture_size * texture_size)
	var peak_color := PackedColorArray(); peak_color.resize(texture_size * texture_size)
	var non_empty := 0

	var pixel_count := texture_size * texture_size
	for index in range(voxel_count):
		var weight := color_weight[index]
		var complexity_value := complexity[index]
		var collision_value := collision[index]
		# 绝大多数格子是空的（这份场景约 96%）。两个缓冲都由 resize() 零填充过，空格
		# 逐字节写 0 与不写等价，峰值投影也不会被 0 改写——直接跳过，把这趟 100 万次
		# 的遍历压到只处理真正有内容的那几万格。
		if weight <= 0.0 and complexity_value <= 0.0 and collision_value <= 0.0:
			continue
		var r := 0.0
		var g := 0.0
		var b := 0.0
		if weight > 0.0:
			r = color_sum_r[index] / weight
			g = color_sum_g[index] / weight
			b = color_sum_b[index] / weight
		# ⚠ 必须走规范打包器，**不能**逐字节写 [r,g,b,a]。
		# 规范字是 pack_shader_rgba8_word 的 r<<24|g<<16|b<<8|a，经小端 encode_u32 落盘后
		# 字节序是 [a,b,g,r]；消费端（SceneVoxelTileCodec.decode_complexity_field_rgba8_color_at
		# 与各着色器的 target_field_rgba8[i] & 0xFFu）解的就是这个字。以前这里逐字节写
		# [r,g,b,complexity]，整份缓冲是反的：complexity 被读成 r、r 被读成 complexity、
		# g 与 b 对调——TargetSV 颜色全错的成因，且用同一套错字节序去核对只会自洽。
		visual_bytes.encode_u32(index * 4,
			BufferUtils.pack_shader_rgba8_word(Color(r, g, b, complexity_value)))
		collision_bytes[index] = BufferUtils.quantize_unorm8(collision_value)
		if maxf(complexity_value, collision_value) > epsilon:
			non_empty += 1
		var pixel := index % pixel_count
		if complexity_value > peak_complexity[pixel]:
			peak_complexity[pixel] = complexity_value
			peak_color[pixel] = Color(r, g, b)
		peak_collision[pixel] = maxf(peak_collision[pixel], collision_value)

	var written := PackedStringArray()
	var visual_path := TargetSVLoader.SHARED_DIR.path_join(TargetSVLoader.VISUAL_NAME)
	var collision_path := TargetSVLoader.SHARED_DIR.path_join(TargetSVLoader.COLLISION_NAME)
	var preview_path := TargetSVLoader.SHARED_DIR.path_join(TargetSVLoader.PREVIEW_NAME)
	var metadata_path := TargetSVLoader.SHARED_DIR.path_join(TargetSVLoader.META_NAME)

	var buffer_error := _store_bytes(visual_path, visual_bytes)
	if not buffer_error.is_empty():
		return {"ok": false, "reason": "visual_write_failed", "detail": buffer_error}
	written.append(visual_path)
	buffer_error = _store_bytes(collision_path, collision_bytes)
	if not buffer_error.is_empty():
		return {"ok": false, "reason": "collision_write_failed", "detail": buffer_error}
	written.append(collision_path)

	# 逐像素 set_pixel 在 256² 上有六位数次调用开销，直接铺字节再 create_from_data。
	var preview_bytes := PackedByteArray()
	preview_bytes.resize(pixel_count * 4)
	for pixel in range(pixel_count):
		var base_color := peak_color[pixel]
		var collision_peak := peak_collision[pixel]
		# 碰撞占比高的格子往砂色偏，与点云链路的 preview 着色一致。
		var tint := 0.35 * collision_peak
		var pixel_base := pixel * 4
		preview_bytes[pixel_base] = BufferUtils.quantize_unorm8(
			base_color.r * (1.0 - tint) + 0.72 * tint)
		preview_bytes[pixel_base + 1] = BufferUtils.quantize_unorm8(
			base_color.g * (1.0 - tint) + 0.68 * tint)
		preview_bytes[pixel_base + 2] = BufferUtils.quantize_unorm8(
			base_color.b * (1.0 - tint) + 0.60 * tint)
		preview_bytes[pixel_base + 3] = BufferUtils.quantize_unorm8(
			maxf(peak_complexity[pixel], collision_peak))
	# 缓冲下标 pixel = z * texture_size + x，正是 RGBA8 图像的行主序，无需再转置。
	var preview := Image.create_from_data(
		texture_size, texture_size, false, Image.FORMAT_RGBA8, preview_bytes)
	var preview_error := preview.save_png(ProjectSettings.globalize_path(preview_path))
	if preview_error != OK:
		return {"ok": false, "reason": "preview_write_failed", "error": preview_error}
	written.append(preview_path)

	var bounds: Dictionary = info["bounds"]
	var metadata := {
		"valid": true,
		"target_role": "TargetSV",
		"generator": "TargetSVFbxTriangleImporter",
		"source_fbx": info["fbx"],
		"source_height": info["height_texture"],
		"height_relative": true,
		"target_guidance_only": true,
		"height_buffer_applied": false,
		"collision_buffer_applied": false,
		"texture_size": texture_size,
		"slice_count": slice_count,
		"voxel_count": voxel_count,
		"max_height": info["height_scale"],
		"capture_size": info["capture_size"],
		"vertical_span": info["vertical_span"],
		"visual_format": "rgba8_unorm",
		"collision_format": "r8_unorm",
		"flip_z": info["flip_z"],
		"attribute_map": {
			"position": "triangle_centroid",
			"color": "fbx_vertex_color",
			"complexity": "fbx_uv1_x",
			"collision": "fbx_uv0_x",
		},
		"source_bounds": [bounds["min"].x, bounds["max"].x,
			bounds["min"].y, bounds["max"].y, bounds["min"].z, bounds["max"].z],
		"triangle_count": int(binned["used_count"]),
		"clipped_height_count": int(binned["clipped_height_count"]),
		"non_empty_voxel_count": non_empty,
		"visual_path": visual_path,
		"collision_path": collision_path,
		"preview_path": preview_path,
	}
	var metadata_file := FileAccess.open(metadata_path, FileAccess.WRITE)
	if metadata_file == null:
		return {"ok": false, "reason": "metadata_write_failed", "path": metadata_path,
			"file_error": FileAccess.get_open_error()}
	metadata_file.store_string(JSON.stringify(metadata, "\t"))
	metadata_file.close()
	written.append(metadata_path)

	return {"ok": true, "written": written, "non_empty_voxel_count": non_empty}


static func _store_bytes(path: String, bytes: PackedByteArray) -> String:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return "%s (FileAccess 错误码 %d)" % [path, FileAccess.get_open_error()]
	file.store_buffer(bytes)
	file.close()
	return ""
