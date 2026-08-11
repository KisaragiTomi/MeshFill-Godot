@tool
class_name BakedAssetLoader
extends RefCounted
## Asset Overview Bake 产物的唯一发现与校验入口（固定槽位Profile共享Buffer实施计划 §6）。
##
## Bake 输出目录在这里定死（`BAKED_DESCRIPTOR_DIR`），加载器**只扫这一个目录、不递归**，
## 因此项目里散落的测试资源与历史 descriptor 不会被顺带吃进运行时。
##
## 职责边界：只负责"从磁盘找出哪些 descriptor 该进 Arena、它们合不合法、按什么顺序排"。
## 不碰 GPU、不建 Buffer、不算字节偏移——Arena 布局归 [ProfileArenaLayout]，CPU 打包与
## GPU 生命周期归 AutoVoxelRuntimeProfileContainer，事务式替换归 ScenePlacementRuntime。
##
## 稳定顺序（§6）：asset_id → 规范化资源路径 → 资源 UID。同一批 Bake 产物因此永远得到
## 同一组 profile_index，也就是同一组 Arena slot —— 这是"相同输入产生相同 Arena 字节"
## 这条验证项（§12）的前提。

const AssetDescriptorScript := preload("res://scripts/asset_descriptor.gd")
const ProfileArenaLayoutScript := preload("res://scripts/utils/profile_arena_layout.gd")
const ProfileRecordSchemaScript := preload("res://scripts/utils/profile_record_schema.gd")

## Bake 输出目录的单一真值来源。Asset Overview 写入这里，SPA 从这里加载。
const BAKED_DESCRIPTOR_DIR := "res://scenes/asset-overview/baked_descriptors"
const DESCRIPTOR_SUFFIX := "_descriptor.tres"

## slot 状态（§11.2 的 "Ready / Full" 列）。
const SLOT_STATE_READY := "Ready"
const SLOT_STATE_FULL := "Full"        # 用满 ≥90% 固定容量，还能装但没剩多少余量
const SLOT_STATE_OVER := "Over"        # 超过固定上限 —— 该资产无法加载
const SLOT_STATE_INVALID := "Invalid"  # 资源本身有问题（读不出 / 无 asset_id / mesh 无效）


## 扫描 Bake 输出目录，返回排序前的 descriptor 资源路径（只扫本级，不递归）。
static func scan_descriptor_paths(dir_path: String = BAKED_DESCRIPTOR_DIR) -> PackedStringArray:
	var paths := PackedStringArray()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return paths
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if not dir.current_is_dir() and file_name.ends_with(DESCRIPTOR_SUFFIX):
			paths.append(dir_path.path_join(file_name))
		file_name = dir.get_next()
	dir.list_dir_end()
	paths.sort()
	return paths


## 扫描 + 加载 + 校验 + 稳定排序。返回：
##   ok              — 是否全部合法（有任何一条错误即 false，调用方不得部分加载）
##   dir             — 实际扫描的目录
##   descriptors     — 按稳定序排好的 AssetDescriptor（ok=false 时仍返回已成功加载的，
##                     仅供界面展示；**不得**拿去注册）
##   entries         — 逐资产摘要（Inspector 只读列表用，见 §11.2）
##   errors          — 人类可读的失败原因列表，每条都点名具体资产与超限数值（§11.4）
##   scanned_count   — 目录里发现的 descriptor 文件数
static func load_baked_descriptors(dir_path: String = BAKED_DESCRIPTOR_DIR) -> Dictionary:
	var errors := PackedStringArray()
	var entries: Array[Dictionary] = []
	var descriptors: Array[AssetDescriptor] = []

	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(dir_path)):
		errors.append("Bake 输出目录不存在：%s" % dir_path)
		return _result(false, dir_path, descriptors, entries, errors, 0)

	var paths := scan_descriptor_paths(dir_path)
	if paths.is_empty():
		# 空目录不是"错误的目录"，但也确实没东西可加载——按 §11.1「没有 Bake 产物时
		# 按钮仍可点击，但必须返回明确提示」处理。
		errors.append("Bake 输出目录里没有 %s：%s" % [DESCRIPTOR_SUFFIX, dir_path])
		return _result(false, dir_path, descriptors, entries, errors, 0)

	# ── 逐个加载与校验 ─────────────────────────────────────────────────────────
	var seen_asset_ids := {}
	for path in paths:
		var entry := _inspect_descriptor(path)
		entries.append(entry)
		var asset_id := str(entry.get("asset_id", ""))
		var entry_errors: PackedStringArray = entry.get("errors", PackedStringArray())
		if not entry_errors.is_empty():
			errors.append_array(entry_errors)
			continue
		if seen_asset_ids.has(asset_id):
			var duplicate_error := "asset_id 重复：'%s' 同时出现在 %s 与 %s" % [
				asset_id, str(seen_asset_ids[asset_id]), path]
			errors.append(duplicate_error)
			entry["errors"] = PackedStringArray([duplicate_error])
			entry["slot_state"] = SLOT_STATE_INVALID
			continue
		seen_asset_ids[asset_id] = path
		descriptors.append(entry["descriptor"] as AssetDescriptor)

	# ── 稳定排序：asset_id → 规范化路径 → UID ────────────────────────────────
	var sort_keys := {}
	for entry in entries:
		var descriptor = entry.get("descriptor")
		if descriptor != null:
			sort_keys[descriptor] = [
				str(entry.get("asset_id", "")),
				str(entry.get("path", "")).simplify_path(),
				str(entry.get("uid", "")),
			]
	descriptors.sort_custom(func(a, b) -> bool:
		var ka: Array = sort_keys.get(a, ["", "", ""])
		var kb: Array = sort_keys.get(b, ["", "", ""])
		for i in range(ka.size()):
			if str(ka[i]) != str(kb[i]):
				return str(ka[i]) < str(kb[i])
		return false)
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ka := [str(a.get("asset_id", "")), str(a.get("path", "")).simplify_path(), str(a.get("uid", ""))]
		var kb := [str(b.get("asset_id", "")), str(b.get("path", "")).simplify_path(), str(b.get("uid", ""))]
		for i in range(ka.size()):
			if str(ka[i]) != str(kb[i]):
				return str(ka[i]) < str(kb[i])
		return false)

	# 排完序才知道每条最终落在哪个 slot（profile_index 就是这个顺序）。
	for i in range(entries.size()):
		entries[i]["slot_index"] = i if str(entries[i].get("slot_state", "")) != SLOT_STATE_INVALID else -1

	# ── 总量：profile 数不得超过固定 Arena 容量（§6 末条）─────────────────────
	if descriptors.size() > ProfileArenaLayoutScript.PROFILE_CAPACITY:
		errors.append("Profile 总数 %d 超过 PROFILE_CAPACITY %d —— 请收紧 Bake 产物或调高容量常量" % [
			descriptors.size(), ProfileArenaLayoutScript.PROFILE_CAPACITY])

	return _result(errors.is_empty(), dir_path, descriptors, entries, errors, paths.size())


## 单个 descriptor 的加载 + 校验 + 用量统计。
static func _inspect_descriptor(path: String) -> Dictionary:
	var errors := PackedStringArray()
	var entry := {
		"path": path,
		"uid": _uid_text(path),
		"asset_id": "",
		"descriptor": null,
		"coarse_sample_count": 0,
		"fine_sample_count": 0,
		"sample_count": 0,
		"sample_limit": ProfileArenaLayoutScript.MAX_SAMPLES_PER_PROFILE,
		"pivot_count": 0,
		"pivot_limit": ProfileArenaLayoutScript.MAX_PIVOTS_PER_PROFILE,
		"mesh_valid": false,
		"slot_index": -1,
		"slot_state": SLOT_STATE_INVALID,
		"errors": errors,
	}

	var resource := ResourceLoader.load(path)
	var descriptor := resource as AssetDescriptor
	if descriptor == null:
		errors.append("%s：无法作为 AssetDescriptor 加载" % path)
		entry["errors"] = errors
		return entry
	entry["descriptor"] = descriptor

	var asset_id := str(descriptor.asset_id).strip_edges()
	entry["asset_id"] = asset_id
	if asset_id.is_empty():
		errors.append("%s：asset_id 为空" % path)

	entry["mesh_valid"] = descriptor.get_mesh() != null
	if not bool(entry["mesh_valid"]):
		errors.append("%s（%s）：mesh 引用无效（mesh 与 mesh_create_method 都取不到网格）" % [path, asset_id])

	# 样本用量按容器的注册口径统计：coarse 与 fine 各自成段，同时带两个 stage flag 的
	# 样本会被写进 slot 两次，所以固定 slot 的占用是 coarse + fine 而不是去重条数。
	var coarse_count := 0
	var fine_count := 0
	var samples: Array = descriptor.get_profile_samples()
	for i in range(samples.size()):
		var raw = samples[i]
		if not (raw is Dictionary):
			errors.append("%s（%s）：ProfileSample[%d] 不是 Dictionary —— 采样格式无效" % [path, asset_id, i])
			break
		var sample := raw as Dictionary
		var reason := ProfileRecordSchemaScript.profile_sample_validation_error(sample)
		if not reason.is_empty():
			errors.append("%s（%s）：ProfileSample[%d] 非法（%s）" % [path, asset_id, i, reason])
			break
		var flags := int(sample.get("flags", 0))
		if (flags & ProfileRecordSchemaScript.SAMPLE_FLAG_COARSE) != 0:
			coarse_count += 1
		if (flags & ProfileRecordSchemaScript.SAMPLE_FLAG_FINE) != 0:
			fine_count += 1
	entry["coarse_sample_count"] = coarse_count
	entry["fine_sample_count"] = fine_count
	entry["sample_count"] = coarse_count + fine_count
	entry["pivot_count"] = descriptor.get_pivot_variants().size()

	# 超限一律明确失败并报出实际数量与允许上限，绝不静默裁剪（§6 / §11.4）。
	var over_limit := false
	if int(entry["sample_count"]) > ProfileArenaLayoutScript.MAX_SAMPLES_PER_PROFILE:
		errors.append("%s（%s）：sample 数 %d（coarse %d + fine %d）超过每 Profile 上限 %d" % [
			path, asset_id, int(entry["sample_count"]), coarse_count, fine_count,
			ProfileArenaLayoutScript.MAX_SAMPLES_PER_PROFILE])
		over_limit = true
	if int(entry["pivot_count"]) > ProfileArenaLayoutScript.MAX_PIVOTS_PER_PROFILE:
		errors.append("%s（%s）：pivot 数 %d 超过每 Profile 上限 %d" % [
			path, asset_id, int(entry["pivot_count"]),
			ProfileArenaLayoutScript.MAX_PIVOTS_PER_PROFILE])
		over_limit = true

	entry["errors"] = errors
	entry["slot_state"] = _slot_state(entry, errors, over_limit)
	return entry


static func _slot_state(entry: Dictionary, errors: PackedStringArray, over_limit: bool) -> String:
	if over_limit:
		return SLOT_STATE_OVER
	if not errors.is_empty():
		return SLOT_STATE_INVALID
	var sample_limit := int(entry["sample_limit"])
	var pivot_limit := int(entry["pivot_limit"])
	var sample_ratio := float(int(entry["sample_count"])) / float(maxi(sample_limit, 1))
	var pivot_ratio := float(int(entry["pivot_count"])) / float(maxi(pivot_limit, 1))
	return SLOT_STATE_FULL if maxf(sample_ratio, pivot_ratio) >= 0.9 else SLOT_STATE_READY


static func _uid_text(path: String) -> String:
	var uid := ResourceLoader.get_resource_uid(path)
	return ResourceUID.id_to_text(uid) if uid != ResourceUID.INVALID_ID else ""


static func _result(
	ok: bool,
	dir_path: String,
	descriptors: Array[AssetDescriptor],
	entries: Array[Dictionary],
	errors: PackedStringArray,
	scanned_count: int
) -> Dictionary:
	return {
		"ok": ok,
		"dir": dir_path,
		"descriptors": descriptors,
		"entries": entries,
		"errors": errors,
		"scanned_count": scanned_count,
		"loadable_count": descriptors.size(),
	}


## Inspector 只读资产列表的文本（§11.2）。
##     Loaded Assets (5)
##     ├─ geo_cliff_01   Profile 0   3485 / 16384 samples   3 / 8 pivots   mesh:ok   Ready
static func format_asset_list(entries: Array, title: String = "Loaded Assets") -> String:
	if entries.is_empty():
		return "%s (0)\n  <no baked descriptors>" % title
	var lines: Array[String] = ["%s (%d)" % [title, entries.size()]]
	for i in range(entries.size()):
		var entry: Dictionary = entries[i]
		var branch := "└─" if i == entries.size() - 1 else "├─"
		var slot_index := int(entry.get("slot_index", -1))
		var slot_text := "Profile %d" % slot_index if slot_index >= 0 else "Profile   -"
		lines.append("%s %-24s %-11s %6d / %-6d samples   %d / %d pivots   mesh:%s   %s" % [
			branch,
			str(entry.get("asset_id", "?")),
			slot_text,
			int(entry.get("sample_count", 0)),
			int(entry.get("sample_limit", 0)),
			int(entry.get("pivot_count", 0)),
			int(entry.get("pivot_limit", 0)),
			"ok" if bool(entry.get("mesh_valid", false)) else "BAD",
			str(entry.get("slot_state", "?")),
		])
		var entry_errors: PackedStringArray = entry.get("errors", PackedStringArray())
		for error_text in entry_errors:
			lines.append("      ! %s" % error_text)
	return "\n".join(lines)
