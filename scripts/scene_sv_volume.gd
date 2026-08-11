@tool
class_name SceneSVVolume
extends "res://scripts/auto_volume_field.gd"

## `SPA/Volumes/SceneSV` 的节点脚本（《AutoVolume 公用体积基类计划》V1）。
##
## 取代的是一个**裸 `Node`**：`_ensure_owned_tree()` 建它、`get_volume_ownership_report()`
## 拿它算 owner_path 与 instance_id，除此之外全仓没有任何地方读它——它唯一的存在理由
## 就是让当时的 `spa_checks.test_owned_tree` 的 `direct_component_instance_id != 0` 通过
## （该套件已于 2026-08-07 删除）。
## 换成本类之后它才第一次真的代表"SceneSV 这个域"。
##
## ── 场对 Buffer 的所有权：`SceneSVFieldStore`（V3 劈开后），本类不转发读口 ──────
## 节点侧曾有 `field_rid()` / `has_resident_fields()` 转发——**全仓零调用点**，
## 已随基类的同款包装一起删除（2026-08-10，成因见 AutoVolumeField 类注释）。
## 管线读场对走 store / runtime 自己的通路，从来不经过本节点。
##
## ── 显示：正四面体，紧凑实例表（《点选统一》§5.4 第 2 行；§2.5-5 / §7.3）──────
## SV 域此前**没有任何可视化节点**。现在走与 TargetSV 同一条 GPU 通路
## （`voxel_field_instances.glsl`），只换形状（TargetSV 方盒 / SV 正四面体）与数据来源，
## 且只画**非空砖**里的体素（`build_compact_instance_list()`，粒度是砖不是体素）。
##
## ⚠ **必须先回读**，这不是可以省掉的一步：SPA 的 GPU 栈跑在**本地 RenderingDevice**
## （committer 的 `ensure_device(true, false)` —— 本地设备且禁止回退全局），而显示 writer
## 绑的是 `RenderingServer.get_rendering_device()`（**主设备**）。RID 不能跨设备。
##
## ⚠ 但回读之后**零 CPU 解码**：常驻场对本来就是 shader 的输入格式
## （complexity 场 = rgba8 且 complexity 在低字节，collision 场 = unorm8 在低字节；
## `scatter_sv_field_records.glsl` 的 `pack_rgba8` 与本 shader 的 `unpack_rgba8` 逐位相同）。
## 因此 `occupancy` 与 `color_rgba8` 两个 binding **绑同一块 complexity 场**：
## 前者按低字节读出 complexity 当占据度，后者按 rgba8 解出颜色。
##
## 代价：每次重建 2 × 4 MiB 回读。由 `revision()` 门控（内容没变就不重建），不是每帧。

## 瓦片域的类型（`_svtile_volume()` 判型用）。
## ⚠ 这里曾是"只为拿两个常量"的横向 preload（瓦片尺寸设置键 + 摘要 buffer 名），
## 那意味着本域自己解一遍摘要。现在改为**问瓦片域要**非空砖表与覆盖范围，
## preload 只剩类型判定这一个用途。
const SVTileVolumeScript := preload("res://scripts/svtile_volume.gd")

const DISPLAY_NODE := "SceneSVVoxels"

## SV 显示的填充比。比 TargetSV（0.72）小一点：两者常常叠在同一格上，
## 正四面体本身体积只有同 cell 方盒的 1/3，再收一点让底下的 TargetSV 方盒仍可辨。
const DISPLAY_FILL_RATIO := 0.66

## 空格判定阈值。与 `VoxelGeneral.VOXEL_OCCUPIED_EPSILON` 同源：
## complexity/collision 任一超过它即视为非空（shader 里是 `max(occ, coll) > threshold`）。
const OCCUPANCY_THRESHOLD := 0.01

# ⚠ 不要在这里重新 preload SPAEditorContract / VoxelGeneral / TerrainInitializer /
# TerrainConfig / VoxelDisplay / SceneVoxelTileCodec：它们由 PickableDomain / AutoVolumeField
# 声明，GDScript 的常量是继承下来的，重声明会直接报 "member already exists in parent class"。


## ⚠ 刻意默认**不显示**（基类 READY 时应用）：SV 是非空砖 × 512 实例 + 每次重建
## 2 × 4 MiB 回读，默认开着会让每次开场景都白付这笔。由显示开关按需打开。
func default_display_visible() -> bool:
	return false


func domain_key() -> String:
	return SPAEditorContractScript.SELECTION_DOMAIN_SV


func display_node_name() -> String:
	return DISPLAY_NODE


func display_fill_ratio() -> float:
	return DISPLAY_FILL_RATIO


## 建 SV 显示（基类 `rebuild_display()` 模板的钩子；早退守卫与 RD / SPA 双守卫在基类）。
func _build_display_node() -> MultiMeshInstance3D:
	var spa := scene_placement_actor()
	var frame := grid_frame()
	var voxel_count := element_capacity()
	if voxel_count <= 0:
		return null
	# 紧凑实例表（§2.5-5 / §7.3）。空表 = 整场没有非空砖，不必建显示。
	var index_map := get_instance_list()
	if index_map.is_empty():
		return null
	# 回读两块常驻场（本地设备 → CPU 字节）。它们已经是 shader 的输入格式，不做任何解码。
	var complexity_bytes := spa.read_svtile_gpu_buffer_bytes(
		SceneVoxelTileCodecScript.SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER)
	var collision_bytes := spa.read_svtile_gpu_buffer_bytes(
		SceneVoxelTileCodecScript.SCENE_VOXEL_TILE_COLLISION_FIELD_BUFFER)
	var expected := voxel_count * 4
	if complexity_bytes.size() != expected or collision_bytes.size() != expected:
		# 尺寸不符说明常驻场还没建好或网格对不上。静默画一块空的会与"场景确实是空的"
		# 完全一样，所以如实跳过并留下原因，不补零。
		push_warning("[SceneSVVolume] SV 显示跳过：常驻场字节数不符（complexity=%d collision=%d 期望 %d，voxel_count=%d）" % [
			complexity_bytes.size(), collision_bytes.size(), expected, voxel_count])
		return null
	return VoxelDisplayScript.build_field_gpu_packed(
		# ⚠ 实例数是**紧凑表长度**，不是网格体素总数。
		# 这同时决定 PickIdPass 分配多少个 pick_id（它按 mm.instance_count 整段分配）。
		index_map.size(),
		display_cell_size(),
		display_aabb(),
		{
			# ⚠ occupancy 与 color 绑**同一块** complexity 场，见类注释。
			"occupancy_u32": complexity_bytes,
			"collision_u32": collision_bytes,
			"color_rgba8": complexity_bytes,
			# ⚠ 必须与 `voxel_center_world()` 读的是**同一份数组**（基类缓存保证：
			# 每次重建时重采一份、marker 惰性读同一份）。各采一次的表现是
			# 选中框与四面体在斜坡上错位，而两个数都合法、都不报错。
			"terrain_height": display_terrain_height_field(),
		},
		{
			"grid_size": frame["grid_size"],
			"grid_origin": frame["grid_origin"],
			"voxel_size": frame["voxel_size"],
			# VIEW_PROJECT_COLOR：按 max(occ, coll) 过阈值判可见，取场里存的真实颜色。
			"view_mode": 1,
			"display_scale": 1.0,
			"height_span": display_height_span(),
			"threshold": OCCUPANCY_THRESHOLD,
			# 紧凑模式：实例序经映射表取体素下标。⚠ 与下面 resolve_pick 的解码必须同表。
			"use_index_map": true,
			"instance_voxel_index": index_map,
		},
		{"name": DISPLAY_NODE, "shape": VoxelDisplayScript.SHAPE_TETRA, "fill": 1.0}
	)


# ⚠ `voxel_center_world()`（marker 与显示同式的格心）已上提 `AutoVolumeField`
# （2026-08-10，BrushSV 的选中框与本域同式）。本域直接继承，别加回本地副本。


# ⚠ 这里曾有 `resolve_pick()`。点选零派生后（2026-08-10）由基类统一实现：
# 本域是紧凑显示（`display_is_compact()` 默认 true），实例序经 `get_instance_list()`
# 解回体素下标——与建显示时喂给 shader 的是**同一张表**（按 `revision()` 缓存，
# 内容没变就不重算），所以两侧恒等这条不变量不再依赖任何本域代码。


## 紧凑实例表：只列**非空砖**里的体素下标。
##
## ⚠ 不做逐体素扫描。1,048,576 次 GDScript 循环读字节是几百毫秒级的开销，而瓦片摘要里
## 已经有 `scene_voxel_count` / `collision_voxel_count`（每砖一条，共 2048 条）——
## 非空砖识别是**白送**的（计划 §7.3）。
##
## 粒度是**砖**不是体素：一砖 8³ = 512 格，非空砖里的空格仍会进实例表，由 shader 按
## `max(occ, coll) > threshold` 塌成零基向量。这已经把 10^6 降到「非空砖数 × 512」，
## 而按体素精确紧凑还要一趟逐体素扫描——不划算。
func build_compact_instance_list() -> PackedInt32Array:
	var out := PackedInt32Array()
	var spa := scene_placement_actor()
	if spa == null:
		return out
	var frame := grid_frame()
	if frame.is_empty():
		return out
	var grid: Vector3i = frame["grid_size"]
	# ⚠ 非空砖表**问瓦片域要**，不自己再算一遍（2026-08-10）。
	# 此前这里逐字重复了瓦片支的五件事：瓦片尺寸/网格换算、摘要 buffer 回读、短读判空、
	# 逐砖判非空、末排夹紧——外加为拿两个常量而横向 preload SVTileVolume。
	# 「SVTile 是 SV 的一个视图」（unified_pick_gpu 的既有裁定）⇒ 同一份摘要不该解两遍：
	# 两域的 `revision()` 本就同源（都是 tile store 的 gpu_revision），所以那张表按修订号
	# 缓存之后，两侧恒等这条不变量由**同一份缓存**保证，而不是靠两处判据"碰巧一致"。
	var tile_volume := _svtile_volume()
	if tile_volume == null:
		return out
	var live_tiles := tile_volume.get_instance_list()
	if live_tiles.is_empty():
		_warn_if_summaries_are_stale(spa, VoxelGeneralScript.voxel_count(grid))
		return out
	for tile_index in live_tiles:
		# 覆盖范围也走瓦片域的寻址口（末排瓦片不满一块，夹紧算式只此一份）。
		var tile_range: Dictionary = tile_volume.voxel_range_of(tile_index)
		if tile_range.is_empty():
			continue
		var origin: Vector3i = tile_range["min"]
		var end_voxel: Vector3i = tile_range["max_exclusive"]
		for vy in range(origin.y, end_voxel.y):
			for vz in range(origin.z, end_voxel.z):
				for vx in range(origin.x, end_voxel.x):
					out.append(VoxelGeneralScript.voxel_index(Vector3i(vx, vy, vz), grid))
	return out


## `SPA/Volumes/SVTile` 卷节点（非空砖表与瓦片寻址的来源）。
## 拿不到 = 装配坏了（两个域都由 `_ensure_owned_tree()` 建在同一个 Volumes 下），如实判死。
func _svtile_volume() -> SVTileVolumeScript:
	var spa := scene_placement_actor()
	if spa == null:
		return null
	var node := spa.get_volume(&"SVTile")
	if node is SVTileVolumeScript:
		return node as SVTileVolumeScript
	push_error("[SceneSVVolume] SPA/Volumes/SVTile 不是 SVTileVolume（实得 %s）—— 非空砖表无来源，SV 显示建不出。" % [
		node.get_class() if node != null else "<null>"])
	assert(false, "SceneSVVolume: SVTile volume node missing or wrong type")
	return null


## 摘要说"一块非空砖都没有"时，分辨这是**事实**还是**摘要过期**。
##
## ⚠ 两者在摘要里长得一模一样，而后果完全不同：事实 ⇒ 本来就不该画；过期 ⇒ 场里有内容却
## 一个体素都不画，且**零提示**。落地时正是踩到这一条——放置了 5437 个物体之后紧凑表仍为空。
##
## 成因（查证）：placement 的 GPU state-chain stamp 是**原位**写常驻场对的，而瓦片摘要要靠
## 单独的 reduce pass；那趟 reduce 只在 `SceneVoxelCommitter._rebuild_sv()` 里跑。
##
## ⚠ placement 路径上本来**有**一个触发点——`scene_placement_runtime.gd` 的
## `_commit_accepted_placements()` 会调 `commit_scene_voxels()`——但它的门写的是
## `bool(placement_result.get("ok", false))`，而 VPG 的成功变体按
## `ReportSchema.VPG_MULTI_ASSET_REPORT` 的约定**刻意不发 `ok` 键**
##（原话：「成功变体故意不发 ok——SPA 的 ok 门现状即靠缺席走 false 分支，勿补发」）。
## ⇒ 门恒 false，每一次成功放置之后摘要都不会被刷新。
## 修复挂点是 `ScenePlacementActor.run_place()` 批循环里的
## `_sv_committer.refresh_scene_voxel_tile_summaries()`——**不是**去补发 `ok`
##（那会同时打开一条从未验证过的 GPU 写路径）。
## 本探测器保留：刷新失败时它仍是唯一会喊的地方。
##
## 判据：对复杂度场做**抽样**扫描（每 64 格取一格）。有 5437 个物体的场几乎不可能在
## 1/64 抽样里全为零，所以抽到非零 = 摘要确定过期。抽样成本约 16k 次读，可忽略。
## ⚠ `spa` 必须显式标注类型：不标注则方法返回 Variant，`:=` 触发 INFERENCE_ON_VARIANT
## ——引擎默认表里那是 ERROR 级，直接打红门禁。
func _warn_if_summaries_are_stale(spa: ScenePlacementActor, voxel_count: int) -> void:
	var complexity_bytes := spa.read_svtile_gpu_buffer_bytes(
		SceneVoxelTileCodecScript.SCENE_VOXEL_TILE_COMPLEXITY_FIELD_BUFFER)
	if complexity_bytes.size() != voxel_count * 4:
		return
	var step := 64
	var index := 0
	while index < voxel_count:
		# 低字节 = complexity（scatter 的 pack_rgba8 把 complexity 放在低字节）。
		if (complexity_bytes.decode_u32(index * 4) & 0xFF) != 0:
			# ⚠ 只 push_error，**不 assert**。本仓的 assert 约定是「调用方违约」，
			# 而摘要过期是一个**在提交管线修好之前每次 Place 之后都会发生**的既有状态
			# （见任务：瓦片摘要在 placement stamp 之后不刷新）。
			# 对它断言的实测后果：编辑器在这次 bridge 调用里当场被断言打死——
			# 比它要取代的「静默画不出东西」更糟。
			push_error("[SceneSVVolume] 瓦片摘要过期：所有砖都报 scene_voxel_count == 0，但复杂度场在抽样中命中非零（体素 %d）。SV 显示会一个体素都画不出来。成因：placement 的 stamp 原位写场对，而摘要 reduce 只在 SceneVoxelCommitter._rebuild_sv() 里跑，它只被 commit_scene_voxels() 调用 —— stamp 之后没有任何东西刷新摘要。" % index)
			return
		index += step


## SceneSV 的内容修订号来自 SVTile 的 GPU 修订号——两者今天是同一个对象的两半，
## 场对一变瓦片摘要必然跟着重算。V3 劈开后本域自己持有。
##
## ⚠ 基类的 `_revision` 在本域是**不用**的：它没有独立的递增点，用它会得到一个恒 0 的数，
## 而消费方会把恒 0 当成"内容从没变过"并永久复用旧缓存。
func revision() -> int:
	var spa := scene_placement_actor()
	if spa == null:
		return 0
	return int(spa.get_svtile_gpu_status().get("gpu_revision", 0))
