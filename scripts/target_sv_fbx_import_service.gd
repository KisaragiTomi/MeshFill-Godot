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
## **空间契约照搬点云转换器**（doc/target-sv-point-cloud-conversion.md 记录的那一份，也是
## 现存 assets/target_sv 的产出规则），只把载体从点换成三角形重心：
##   * texture_size 取自高度图宽度（必须是方图），不是随便取的常数
##   * capture_size 缺省 = `TerrainConfig.CAPTURE_SIZE`（世界网格的固定跨度）
##   * vertical_span 缺省 = vertical_floor + slice_count × `DEFAULT_SLICE_HEIGHT`
##     （层高恒定 3.0；量程盖不住源时报警，见 `_warn_if_band_clips_source`，不静默夹）
##
## ── ⚠ 落格按**体素的世界范围**，不按源包围盒（2026-08-12 用户裁定）────────────
## 网格是一块**固定的世界分区**：XZ 由 capture_size 居中铺开成 texture_size² 格，
## Y 是地形相对带 [vertical_floor, vertical_span) 切成 slice_count 层。样本按自己的
## 世界坐标被分进格子（`_prepare_samples` = `floor((P.xz - grid_origin.xz) / voxel_size.xz)`），
## **源包围盒不参与任何换算**，只用于回报 `source_bounds`。
## 这条保证「同一个世界位置永远落进同一格」，与资产自己多大、导了几次都无关。
##
## ── ⚠ 本服务**不依赖 SPA**（同上裁定）──────────────────────────────────────
## 世界网格按 `TerrainConfig` 自己推。SPA 在这条链上只负责触发烘焙、并把结果交给
## TargetSV；两边框架是否一致由**接收端** `TargetSVSetup._assert_target_frame_matches_bake()`
## 逐项比对并硬失败，不是靠谁给谁注入参数来"保证"。
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
## 世界网格的上游事实源。⚠ 刻意取 `TerrainConfig` 而**不是**问 SPA 要：
## 导入是一条离线数据转换，不该依赖场景里有没有活的 SPA 节点、它当时配成什么样。
## SPA 的 `capture_size` 导出本来也是 `TerrainConfigScript.CAPTURE_SIZE`，两者同源，
## 所以"不经过 SPA"并不会让两边的框架分家——真分家了由 TargetSVSetup 的接收门禁拦。
const TerrainConfigScript := preload("res://scripts/terrain_config.gd")

## ⚠ 必须落在资源系统看得见的目录里。本文件曾指向 `res://textures/`，而那整个目录带
## `.gdignore` —— 导入器根本不扫它，下面 `_load_height_image()` 的 `load()` 只是碰巧还能
## 命中「加 `.gdignore` 之前遗留的 `.import` + `.godot/imported` 缓存」；缓存一失效
## （换机器、清 `.godot/`、重导入）整条链就断在 `height_texture_unavailable`。
## 2026-08-17 迁到 `assets/target_sv/`（TargetSV 输入的既有归属目录，无 `.gdignore`），
## 与 `targetsv0.fbx` / 点云产物同住，导入链因此是真的活着而不是靠陈缓存。
const DEFAULT_HEIGHT_TEXTURE := "res://assets/target_sv/scene_height_0_1.png"
const DEFAULT_SLICE_COUNT := 24
const DEFAULT_HEIGHT_SCALE := 120.0

## 每切片的世界高度。2026-08-12 起量程改成「层高恒定、上界由层数推」，本值才是这条链上
## 真正不变的量：`vertical_span = vertical_floor + slice_count * 本值`。
##
## ⚠ 旧口径是反过来的——量程按**源的最高相对高度**推
## （`max(16, ceil(max / 8) * 8)`，常量 MIN_VERTICAL_SPAN / VERTICAL_SPAN_QUANTUM 已随之删除），
## 层数固定 16 ⇒ 层高 = 量程 / 16 每换一份 FBX 都可能变，SPA 的 `voxel_size.y` 得跟着改，
## 忘了改就是一份按常数比例竖直错位的 TargetSV。现在层高钉死，只有层数/下界变时才要动 SPA。
const DEFAULT_SLICE_HEIGHT := 3.0

## 竖直量程的**下界**（地形相对，≤ 0）。地形以下这一段此前根本不存在：量程只按
## `relative["max_value"]` 往上推，负的相对高度被压进 slice 0（`below_terrain_count`），
## 于是「地下内容」既没被丢弃、也永远画在地表那一层、被地形网格挡住。
##
## ⚠ 它必须与 SPA 的 `grid_origin.y` 逐位相等，且
## `voxel_size.y == (vertical_span - vertical_floor) / slice_count`——
## 落格用的是本文件这套数，摆放用的是 SPA 那套框架，两边对不上不会报错，
## 只会让整份 TargetSV 按一个常数比例竖直错位（本值引入前实测 40/16 vs 2.0 = 0.8×）。
## 改这里就要同步改 `ScenePlacementActor` 的两个 @export，反之亦然。
##
## ⚠ 取值必须**盖住源自己的最深面**，否则更深的内容会被 `_bin_samples` 夹进最底层切片——
## 那不是「压平一点」而是整段深度塌成一片、再被地形网格挡住，肉眼就是「导入的东西不见了」。
## 2026-08-12 把 -8 改成 -36：targetsv0.fbx 实测相对高度区间 [-34.45, +35.19]，
## 旧值把下面整整 26.4 个单位漏在量程外，65650 个地形以下的面（18.3%）里更深的那批
## 全塌进 slice 0（实测该层仅 1516 格，陡坡列触底率 18.4% vs 平地 0.01%）。
const DEFAULT_VERTICAL_FLOOR := -36.0
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
## 槽位（fine 门 uv8.x 的载体；**严格第 8 槽** index 7——读取器 2026-08-17 起不足
## 8 个 UV set 即报错，不再把"最后一个有效槽"当 uv8）。缺任何一项，这份 FBX 一个体素都出不来。
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
		FbxVoxelImportServiceScript.walk_mesh_instances(root, Transform3D.IDENTITY,
			func(node_name: String, mesh: Mesh, _mesh_transform: Transform3D) -> void:
				_collect_surface_structure(mesh, node_name, surfaces),
			true)
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


# ⚠ 这里曾有 `_collect_structure_from_node()`——全仓四份逐字相同的递归 mesh 遍历骨架
# 之一，2026-08-17 并入 FbxVoxelImportService.walk_mesh_instances（本收集不消费变换）。


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
			"primitive_name": FbxVoxelImportServiceScript._prim_name(primitive),
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


# ⚠ 这里曾有 `_primitive_name()`——与 FbxVoxelImportService._prim_name 同功能的第二份
# （仅未知枚举的文案差一个词），2026-08-17 删除，调用点直用读取器那份。


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
	# ⚠ 这里曾有 `positions.is_empty()` → "no_valid_fine_samples" 分支，hint 还在讲
	# "三个角必须同值"——那是读取器还会判废三角形的旧时代。改成"只计数不丢弃"后，
	# gated 只对已产出样本的三角形计数（越界 continue 在计数之前），
	# gated > 0 ⇒ positions 非空，上面的 no_fine_score_triangles 门已盖住空集，
	# 该分支不可达且文案误导排障方向，2026-08-17 删除。
	positions = _scaled_positions(positions, float(settings["position_scale"]))
	var read_ms := Time.get_ticks_msec() - read_started

	var bin_started := Time.get_ticks_msec()
	var height_mode := str(settings["height_mode"])
	if height_mode != HEIGHT_MODE_RELATIVE and height_mode != HEIGHT_MODE_ABSOLUTE:
		return {"ok": false, "reason": "invalid_height_mode", "height_mode": height_mode}

	var slice_count := int(settings["slice_count"])
	if slice_count <= 0:
		return {"ok": false, "reason": "invalid_slice_count", "slice_count": slice_count}

	# ── 世界网格：本服务自己按 TerrainConfig 推，不问 SPA ──────────────────────
	# 网格是**固定的世界分区**（XZ 由 capture_size 居中铺开，Y 是地形相对带
	# [vertical_floor, vertical_span)），样本按自己的世界坐标被分进格子。
	# 源包围盒不再参与任何换算——它只用于回报 source_bounds。
	var capture_size: float = float(settings["capture_size"])
	if capture_size <= 0.0:
		capture_size = TerrainConfigScript.CAPTURE_SIZE
	var vertical_floor: float = minf(float(settings["vertical_floor"]), 0.0)
	var vertical_span: float = float(settings["vertical_span"])
	if vertical_span <= 0.0:
		# 层高恒定 ⇒ 上界由「下界 + 层数 × 层高」推，不再按源的最高面推。
		# ⚠ 这里曾先跑一趟 `_relative_heights` 探针只为拿源的 max —— 三十万样本上白付一遍
		# 逐样本的落格换算与高度图采样。现在量程与源无关，那趟探针整个不需要了；
		# 量程盖不盖得住源改由下面 `_warn_if_band_clips_source` 按真正那一趟的极值判定。
		vertical_span = vertical_floor + float(slice_count) * DEFAULT_SLICE_HEIGHT

	var cell_xz := capture_size / float(texture_size)
	var grid_origin := Vector3(-0.5 * capture_size, vertical_floor, -0.5 * capture_size)
	var voxel_size := Vector3(cell_xz, (vertical_span - vertical_floor) / float(slice_count), cell_xz)

	var grid_columns := {
		"texture_size": texture_size,
		"flip_z": bool(settings["flip_z"]),
		"grid_origin": grid_origin,
		"voxel_size": voxel_size,
	}
	# 列下标 + 相对高度 + 源包围盒一趟算齐。absolute 模式下高度是**减掉该列地形之后**的，
	# 拿原始世界 Y 落格会把切片全花在地形起伏上。
	var prepared := _prepare_samples(positions, grid_columns, height_image,
		height_mode, float(settings["height_scale"]))
	_warn_if_band_clips_source(fbx_path, prepared, vertical_floor, vertical_span, slice_count)

	var voxel_count := texture_size * texture_size * slice_count

	var frame := grid_columns.duplicate()
	frame["slice_count"] = slice_count
	frame["voxel_count"] = voxel_count
	frame["vertical_span"] = vertical_span
	frame["vertical_floor"] = vertical_floor
	var binned := _bin_samples(prepared, colors, collisions, frame)
	binned["relative_height_max"] = prepared["max_value"]
	binned["relative_height_min"] = prepared["min_value"]
	binned["height_mode"] = height_mode
	var bin_ms := Time.get_ticks_msec() - bin_started

	# ⚠ 这一份描述以前在三个地方各写一遍字面量（dry_run 分支的报告、`_write_dataset` 的 info、
	# 写盘后的报告），十来个键逐字重复 —— 正是三份之间悄悄漂移的来源。现在只构造一次：
	# 写盘那条路只往副本里补三个它独有的键，写完回填耗时。
	var report_frame := {
		"texture_size": texture_size, "slice_count": slice_count, "voxel_count": voxel_count,
		"capture_size": capture_size, "vertical_span": vertical_span,
		"vertical_floor": vertical_floor,
		"flip_z": bool(settings["flip_z"]), "height_texture": str(settings["height_texture"]),
		"position_scale": float(settings["position_scale"]),
		"height_mode": height_mode,
		"bounds": prepared["bounds"],
		"timings_ms": {"read": read_ms, "bin": bin_ms, "write": 0},
	}

	# dry_run 在写盘之前收尾：落格统计与推出来的框架参数已经齐了，那正是校验要的东西。
	if bool(settings["dry_run"]):
		return _binning_report(fbx_path, columns, binned, report_frame,
			{"ok": true, "written": PackedStringArray(), "non_empty_voxel_count": -1, "dry_run": true})

	# ⚠ 写前硬门（2026-08-17）：一个三角形都没落进网格还写盘，写出去的就是一整块空场，
	# 会把现有 TargetSV 静默换掉且没有备份可回。此前这个判定在 `_binning_report` 里、
	# 发生在 `_write_dataset` **之后**——警告喊出来的时候好数据已经被盖了。与上面
	# `no_fine_score_triangles` 的写前硬失败同一条哲学；dry_run 不受影响（校验就是要看数字）。
	if int(binned["used_count"]) == 0:
		var aborted := _binning_report(fbx_path, columns, binned, report_frame,
			{"ok": true, "written": PackedStringArray(), "non_empty_voxel_count": -1, "dry_run": false})
		aborted["ok"] = false
		return aborted

	var write_started := Time.get_ticks_msec()
	var write_info := report_frame.duplicate()
	write_info["fbx"] = fbx_path
	write_info["height_scale"] = float(settings["height_scale"])
	write_info["occupancy_epsilon"] = float(settings["occupancy_epsilon"])
	var write_result := _write_dataset(binned, write_info)
	if not bool(write_result.get("ok", false)):
		return write_result

	report_frame["timings_ms"]["write"] = Time.get_ticks_msec() - write_started
	return _binning_report(fbx_path, columns, binned, report_frame, write_result)


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
		# ⚠ 这里曾另有 `valid_triangle_count`（= positions.size()）。读取器改成「不过滤任何
		# 三角形」之后它恒等于 read_triangle_count 减去索引越界那几条（实际恒为 0），
		# 而"落进网格多少"由 used_triangle_count 说了 —— 全仓零消费方，2026-08-12 删除。
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
		# 地表以下的样本数。2026-08-12 量程带上 vertical_floor 之后，它们**按真实深度落格**，
		# 本数字自此只是信息量，不再意味着精度损失。
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
		"vertical_floor": frame.get("vertical_floor", 0.0),
		# 用到的假设一律回报，别让调用方去猜生效的是哪套默认。
		"flip_z": frame["flip_z"],
		"position_scale": frame["position_scale"],
		"height_mode": frame["height_mode"],
		# absolute 模式下这是**减掉地形之后**的最大高度，vertical_span 就是按它推的。
		"relative_height_max": binned.get("relative_height_max", 0.0),
		# 负值 = 源里最深的那个面在地形以下多远。竖直量程只按 max 推 ⇒ 这一头**没有被任何
		# 参数吸收**，全部被压进 slice 0（数量见 below_terrain_count）。要往下扩多少就看它。
		"relative_height_min": binned.get("relative_height_min", 0.0),
		"height_texture": frame["height_texture"],
		"source_bounds": [bounds["min"].x, bounds["max"].x,
			bounds["min"].y, bounds["max"].y, bounds["min"].z, bounds["max"].z],
		"written": write_result["written"],
	}
	# 一个三角形都没落进网格 ⇒ 多半是 FBX 的空间尺度/轴向与本契约不符（比如资产级 FBX
	# 而非场景级）。写盘路径已被 import_fbx_as_target_sv 的写前硬门拦下（2026-08-17，
	# ok=false 且不落一个字节）；本报告带此 reason 的只有 dry_run 与那条被拦的路径。
	if int(binned["used_count"]) == 0:
		push_warning("[TargetSVFbxImport] %s 没有任何三角形落进网格（越界 %d / 低于地形 %d）—— 检查 FBX 是否为场景尺度、height_mode 与 P.y 的高度语义是否对得上" % [
			fbx_path, int(binned["dropped_out_of_bounds"]), int(binned["below_terrain_count"])])
		report["reason"] = "no_samples_in_grid"
	return report


static func _resolved_options(opts: Dictionary) -> Dictionary:
	return {
		"height_texture": opts.get("height_texture", DEFAULT_HEIGHT_TEXTURE),
		"slice_count": opts.get("slice_count", DEFAULT_SLICE_COUNT),
		"capture_size": opts.get("capture_size", 0.0),      # <= 0 ⇒ 取 TerrainConfig.CAPTURE_SIZE
		# <= 0 ⇒ 由 vertical_floor + slice_count × DEFAULT_SLICE_HEIGHT 推（层高恒定）
		"vertical_span": opts.get("vertical_span", 0.0),
		# 地形以下要覆盖多深（≤ 0）。缺省 -36 = 盖住 targetsv0.fbx 的最深面（-34.45）；
		# 配 24 层 × 3.0 得量程 [-36, 36)，两头都盖得住 [-34.45, +35.19]。
		# 取 0 即回到"地下全部压进 slice 0"的旧行为（那正是「地下内容看不见」的成因）。
		"vertical_floor": minf(float(opts.get("vertical_floor", DEFAULT_VERTICAL_FLOOR)), 0.0),
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


## 高度图是已导入资源，必须经资源加载器读：res:// 导出后只保留被导入的纹理（.ctex），
## 原始 PNG 不随包发布 —— 直接对 res:// 调 `Image.load_from_file` 会打印
## "will not work on export" 警告，且导出版本会加载失败。
static func _load_height_image(path: String) -> Image:
	var texture := load(path) as Texture2D
	if texture == null:
		push_error("[TargetSVFbxImport] 高度图无法加载: %s" % path)
		return null
	var image := texture.get_image()
	if image == null:
		push_error("[TargetSVFbxImport] 高度图取不出 Image: %s" % path)
		return null
	# 导入设置若被翻成 VRAM 压缩，压缩 Image 上的 get_pixel 会对每个样本各刷一条错误
	# （场景级 FBX 上是六位数条）。统一在入口解压，导入参数漂移就只在这里响一次。
	if image.is_compressed():
		var decompress_error := image.decompress()
		if decompress_error != OK:
			push_error("[TargetSVFbxImport] 高度图解压失败（err=%d，格式=%d）: %s" % [
				decompress_error, image.get_format(), path])
			return null
	return image


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


## 单趟过一遍样本，一次产出落格要的三样东西：**扁平列下标**、**地形相对高度**、**源包围盒**。
##
## ⚠ 这三样以前是三个函数、两趟遍历，而且**列坐标每个样本算两次**——`_relative_heights`
## 为了采样高度图算一次，`_bin_samples` 落格再算一次，同一串除法/floor/翻转/边界判定在
## 三十万样本上跑两遍。合并后列下标存成扁平式 `z * texture_size + x`（越界 -1），
## 落格时体素下标就是 `slice * texture_size² + column`，`_bin_samples` 不必再碰位置。
##
## 列的语义：**样本落在哪个体素的世界范围里就归哪一格**，
## `floor((P.xz - grid_origin.xz) / voxel_size.xz)`，与 `VoxelGeneral.world_to_voxel` 的
## XZ 半段逐位相同。网格格子是固定的世界分区，资产自己的跨度不参与任何换算。
## ⚠ 这里曾有一条**源包围盒归一化**的路（`round((P.xz - bounds.min.xz) / span * (ts - 1))`），
## 把 FBX 的包围盒拉伸铺满整张网格 ⇒ 落点取决于资产跨度而非世界坐标，换一份 FBX 就整体缩放；
## 本资产 bbox 恰好 ±510 与 256×4.0 的格心范围几乎相等才看着像 1:1，纯属凑巧
## （同款警告见 `VoxelGeneral.grid_frame_from_capture_endpoints`）。2026-08-12 整条删除，
## **不留兜底**——留着就是一条会静默改变落点的回退路径。
##
## 相对高度：relative 模式取 P.y 原样（点云链路口径）；absolute 模式减掉该列地形高度
## （高度图采样 0..1 × height_scale，与显示端 `terrain_height * display_scale` 同一套换算）。
## 采样点用**翻转之后**的列坐标——高度图行序与体素网格 z 序必须同口径。
##
## ⚠ 极值只统计**落进网格的**样本。以前 absolute 模式就是这样（越界即 continue），
## relative 模式却把越界样本也算进极值——两种模式判据不同是无意的，这里统一成前者：
## 越界样本根本不进烘焙，不该把量程覆盖判定（`_warn_if_band_clips_source`）带偏。
## `bounds` 反过来统计**全部**样本：它回报的就是源自己的包围盒，与落不落格无关。
static func _prepare_samples(
	positions: PackedVector3Array,
	frame: Dictionary,
	height_image: Image,
	height_mode: String,
	height_scale: float
) -> Dictionary:
	var texture_size := int(frame["texture_size"])
	var grid_origin: Vector3 = frame["grid_origin"]
	var voxel_size: Vector3 = frame["voxel_size"]
	var flip_z := bool(frame["flip_z"])
	var absolute := height_mode == HEIGHT_MODE_ABSOLUTE
	# 倒数预乘：逐样本两次除法在三十万样本上是白付的。
	var inv_cell_x := 1.0 / maxf(voxel_size.x, EXTENT_EPSILON)
	var inv_cell_z := 1.0 / maxf(voxel_size.z, EXTENT_EPSILON)
	# 高度图预展平成每列一个数（已乘 height_scale）：get_pixel 每次调用都带格式分派开销，
	# 逐样本查 36 万次远贵过先按 6.5 万个像素铺一遍；展平下标 = z * ts + x，与列下标同式。
	# ⚠ 必须存 Float64：GDScript 浮点运算全程 double，`r × height_scale` 的乘积截成 fp32
	# 再相减会让切片边界上的样本翻进邻格——实测 targetsv0.fbx 上 distinct 漂 125 格、
	# below_terrain 漂 297 条。Float64 逐位还原原式 `p.y - r * scale` 的运算顺序与精度。
	var column_heights := PackedFloat64Array()
	if absolute:
		column_heights.resize(texture_size * texture_size)
		for pixel_z in range(texture_size):
			var row_base := pixel_z * texture_size
			for pixel_x in range(texture_size):
				column_heights[row_base + pixel_x] = height_image.get_pixel(pixel_x, pixel_z).r * height_scale

	var sample_count := positions.size()
	var columns := PackedInt32Array(); columns.resize(sample_count)
	var heights := PackedFloat32Array(); heights.resize(sample_count)
	var min_value := INF
	var max_value := -INF
	var bounds_min := Vector3(INF, INF, INF)
	var bounds_max := Vector3(-INF, -INF, -INF)

	for index in range(sample_count):
		var p := positions[index]
		bounds_min = Vector3(minf(bounds_min.x, p.x), minf(bounds_min.y, p.y), minf(bounds_min.z, p.z))
		bounds_max = Vector3(maxf(bounds_max.x, p.x), maxf(bounds_max.y, p.y), maxf(bounds_max.z, p.z))
		columns[index] = -1
		heights[index] = 0.0
		# 坐标非有限 = 读不出位置，算不出下标。这不是门禁，落格阶段按越界计数。
		if not (is_finite(p.x) and is_finite(p.z)):
			continue
		var x := int(floorf((p.x - grid_origin.x) * inv_cell_x))
		var z := int(floorf((p.z - grid_origin.z) * inv_cell_z))
		if flip_z:
			z = texture_size - 1 - z
		if x < 0 or x >= texture_size or z < 0 or z >= texture_size:
			continue
		var column := z * texture_size + x
		var relative := p.y
		if absolute:
			relative = p.y - column_heights[column]
		if not is_finite(relative):
			continue
		columns[index] = column
		heights[index] = relative
		if relative > max_value:
			max_value = relative
		if relative < min_value:
			min_value = relative

	# 一个样本都没落进网格时 ±INF 会污染下游的量程判定与报告，归零。
	if max_value == -INF:
		max_value = 0.0
	if min_value == INF:
		min_value = 0.0
	return {
		"columns": columns,
		"heights": heights,
		# ⚠ min 与 max 一样必须回报：只有 max 时，**负的那一头没有任何数字能说明它有多深**，
		# "地形以下有多少内容、量程要往下扩多少"就在报告里查不到
		# （`below_terrain_count` 只说了有多少个面在地下，说不出有多深）。
		"max_value": max_value,
		"min_value": min_value,
		"bounds": {"min": bounds_min, "max": bounds_max},
	}


## 量程盖不住源时**喊出来**。夹取本身仍在（`_bin_samples` 两头各有兜底），但它是静默的：
## 底下那一头把整段深度塌成最底层一片、再被地形网格挡住 ⇒ 看起来就是「导入的东西不见了」，
## 且陡坡列受害最重（那里同一列的几何竖直跨度最大）。顶上那一头有 clipped_height_count 记数，
## 但那个数字要等报告出来才看得到，来不及提醒正在烘的人。
##
## 判据用源自己的相对高度极值，顺带把「按当前层高要几层才盖得住」算好——盖不住时调用方
## 需要的正是这个数（改 slice_count 就要同步改 SPA 的 grid_size.y，别让人自己反推）。
static func _warn_if_band_clips_source(
	fbx_path: String,
	prepared: Dictionary,
	vertical_floor: float,
	vertical_span: float,
	slice_count: int
) -> void:
	var source_min := float(prepared["min_value"])
	var source_max := float(prepared["max_value"])
	if source_min >= vertical_floor and source_max < vertical_span:
		return
	var cell_y := (vertical_span - vertical_floor) / float(maxi(slice_count, 1))
	var needed_floor := -ceilf(maxf(-source_min, 0.0) / cell_y) * cell_y
	var needed_slices := ceili((source_max - needed_floor) / cell_y)
	push_warning(("[TargetSVFbxImport] %s 的相对高度区间 [%.2f, %.2f] 超出量程 [%.2f, %.2f)"
		+ " —— 超出的部分会被夹进最底/最顶层切片（整段塌成一片，地下那头还会被地形挡住）。\n"
		+ "  按当前层高 %.2f 盖住它需要 vertical_floor=%.1f、slice_count=%d"
		+ "（并同步 ScenePlacementActor 的 grid_origin.y / grid_size.y）。") % [
			fbx_path, source_min, source_max, vertical_floor, vertical_span,
			cell_y, needed_floor, needed_slices])


## 逐三角形落格。complexity / collision 取 max，颜色按 max(complexity, collision, 0.001)
## 加权平均 —— 与点云转换器同一套聚合，换载体不换规则。
## 列下标与相对高度由 `_prepare_samples` 一趟算好（越界样本的列下标为 -1），本函数不再碰位置，
## 也不再重算一遍列坐标——两种高度语义的差异同样只体现在那一趟里。
static func _bin_samples(
	prepared: Dictionary,
	colors: PackedColorArray,
	collisions: PackedFloat32Array,
	frame: Dictionary
) -> Dictionary:
	var texture_size := int(frame["texture_size"])
	var slice_count := int(frame["slice_count"])
	var voxel_count := int(frame["voxel_count"])
	var vertical_span: float = frame["vertical_span"]
	# 缺席 = 老调用方（量程只有地上那半段）。取 0.0 即逐位退回旧行为。
	var vertical_floor: float = minf(float(frame.get("vertical_floor", 0.0)), 0.0)

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
	# 量程是 [vertical_floor, vertical_span)，落格前先把相对高度平移到 [0, band)。
	# ⚠ 分母是**带宽**而不是 vertical_span：写成后者会让地板以下的那一段白占刻度，
	# 表现是整份 TargetSV 竖直被压扁一个 band/span 的比例（且不报错）。
	var band := maxf(vertical_span - vertical_floor, EXTENT_EPSILON)
	var slice_scale := float(slice_count) / band
	var band_ceiling := band - EXTENT_EPSILON
	# 缓冲下标 = slice * texture_size² + column，即 VoxelGeneral.voxel_index 在网格
	# (ts, slices, ts) 下的式子——列下标已是扁平的 z * ts + x，这里只补上切片那一维。
	var plane := texture_size * texture_size

	var sample_columns: PackedInt32Array = prepared["columns"]
	var relative_heights: PackedFloat32Array = prepared["heights"]
	for sample_index in range(sample_columns.size()):
		# 列下标 -1 = 坐标非有限、或落在网格外。判定归 `_prepare_samples`，这里只计数。
		var column := sample_columns[sample_index]
		if column < 0:
			dropped_out_of_bounds += 1
			continue
		var relative_height := relative_heights[sample_index]
		# 相对高度为负 = 钻进地形以下。**只要还在地板以上就按真实深度落格**（2026-08-12
		# 起量程带上了 vertical_floor）；本计数从此只是"有多少内容在地表以下"的信息量，
		# 不再意味着丢失精度。⚠ 越界样本不计入——它们根本没进烘焙。
		if relative_height < 0.0:
			below_terrain_count += 1
		# 比地板还深的那部分仍然压到最底层切片——地板是有限的，总得有个兜底。
		if relative_height < vertical_floor:
			relative_height = vertical_floor
		if relative_height >= vertical_span:
			clipped_height_count += 1
		# 平移到 [0, band) 再落格：band_ceiling 挡住上界，clampi 挡住浮点边界。
		var banded_height := minf(relative_height - vertical_floor, band_ceiling)
		var slice_index := clampi(int(floorf(banded_height * slice_scale)), 0, slice_count - 1)
		var index := slice_index * plane + column

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


## ⚠ 曾多收一个 `height_image` 形参，函数体一次都没用过（高度图只在落格阶段被采样）。
static func _write_dataset(binned: Dictionary, info: Dictionary) -> Dictionary:
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
		# 竖直量程的下界（地形相对，≤ 0）。消费端据它推 grid_origin.y 与 voxel_size.y；
		# 缺席 = 2026-08-12 之前烘的资产，按 0.0 读（那时地下内容全压在 slice 0）。
		"vertical_floor": info.get("vertical_floor", 0.0),
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
