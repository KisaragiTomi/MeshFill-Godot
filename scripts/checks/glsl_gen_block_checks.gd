@tool
extends RefCounted

## Codegen-shared GLSL 区块的去同步守卫（非生产层，住 scripts/checks/）。
##
## 六个 SSOT 各自发射 `// @@GEN <name> ... // @@END <name>` 生成区块，本套件对每个
## 已声明的 (区块, 消费方 shader) 组合，比对 shader 里的区块正文与 SSOT 的发射文本
## （行尾无关、首尾空白无关）。任一处缺失或漂移即失败。
##
##   - [PlacementSharedGLSL]：逐字共享块（区块名 = SSOT 键名）。
##   - [ProfileRecordSchema]：GPU profile-record 字节布局锚注释，区块名
##     `profile_record_layout <record>`，从 `RECORD_LAYOUTS` 发射。
##   - [ProfileArenaLayout]：profile arena 的容器布局锚注释。
##     （曾有 [TerrainRaycast] 的 ray-march / bisect 迭代次数，随 CPU 侧地形射线一并删除。）
##   - [UnifiedPickGPU]：统一点选的 record / config 字长布局。CPU 按这套偏移解码、
##     GLSL 按这套偏移写入；单边改一处不会崩，只会读到邻接字段的值。
##   - [AutoObjectInstanceRenderer]：instance_render / instance_pick / batch_header
##     字长布局，失败模式同上 —— 渲染载荷与拾取 OBB 共用同一趟 scatter，
##     单边改偏移会静默把点选打歪。
##   - [DebugBufferSet]：按 schema 生成的 GPU 调试载体声明，区块名
##     `debug_set <schema.name>`，set/binding 逐消费方覆盖。
##
## **只在编辑器带 `--glsl-gen-check` 启动时才跑**，由 meshfill_editor_plugin 触发：
##
##     & '<godot>' --path '<repo>' -e --rendering-driver vulkan -- --glsl-gen-check
##
## 日常开编辑器一行都不跑、一个字都不打印。本套件纯读文件、不碰 RenderingDevice，
## 但仍走 `-e` 而不给 runtime 入口：CLAUDE.md 禁止一切 `--headless` / `--script` /
## 场景路径启动，`-e` + 插件 flag 是本仓唯一合规的自检形式（同 [RDGSelfTest]）。
##
## 刻意不声明 `class_name`：那会把本文件连同下面 7 个 preload 一起塞进全局类表，
## 每次编辑器启动都解析编译一遍，而这里在意的正是默认启动路径的零成本。
## 调用方用 `load()` 取（见 meshfill_editor_plugin.GLSL_GEN_CHECK_SCRIPT）。

const PlacementSharedGLSL := preload("res://scripts/utils/placement_shared_glsl.gd")
const ProfileRecordSchemaScript := preload("res://scripts/utils/profile_record_schema.gd")
const ProfileArenaLayoutScript := preload("res://scripts/utils/profile_arena_layout.gd")
# ⚠ 这里曾有 `TerrainRaycastScript` 与 `UnifiedPickGPUScript` 两个 SSOT preload。
# 它们各自守着的生成区块（`terrain_ray_march_steps` / `pick_record_layout`）唯一的消费者是
# `shaders/pick_scene_voxel.glsl` 与 `shaders/pick_unified.glsl` —— 两个着色器连同
# `voxel_pick_gpu.gd` / `unified_pick_gpu.gd` 已随旧点选路径整体删除（2026-08-10，
# 三角形 ID 唯一路）⇒ 没有可比对的着色器了，守卫本身成为零次比对的空转。
# `terrain_raycast.gd` 本体**保留**：它的 CPU 侧 `sample_height()` 仍有消费者
# （`SPASelectionHost.sample_height()`）。⚠ 同文件的 `ray_to_height_field()` 与两个迭代次数
# 常量已于 2026-08-10 一并删除——它们的唯一调用者 `_ray_to_terrain()` 是旧点选那条地形射线的
# 残留，随偏好表退役后已无消费者。
const AutoObjectInstanceRendererScript := preload("res://scripts/auto_object_instance_renderer.gd")
const DebugBufferSet := preload("res://scripts/utils/debug_buffer_set.gd")

## 同形 SSOT：都提供 `block_names()` / `block(name)` / `CONSUMERS: Dictionary`。
const BLOCK_SSOTS := [
	PlacementSharedGLSL,
	ProfileRecordSchemaScript,
	ProfileArenaLayoutScript,
	AutoObjectInstanceRendererScript,
]

var lines: Array = []
var passed := 0
var failed := 0
## 声明了区块、却没有任何消费方登记的 SSOT 键。不判失败（可能是尚未接线的 SSOT，
## 如今天的 UnifiedPickGPU），但必须报出来 —— 这类条目在门禁里是**零次比对**，
## 一个写错的 CONSUMERS 键名会让整块布局静默失去守卫。
var orphans: Array = []


func run(_opts := {}) -> Dictionary:
	lines.append("═══ GLSL 生成区块去同步守卫 ═══")

	for ssot in BLOCK_SSOTS:
		for block_name in ssot.block_names():
			var consumers: Array = ssot.CONSUMERS.get(block_name, [])
			if consumers.is_empty():
				orphans.append(block_name)
				continue
			var expected: String = ssot.block(block_name)
			for shader_path in consumers:
				_compare(String(shader_path), String(block_name), expected)

	# DebugBufferSet：一个 (schema, shader, section) 一块；set/binding 逐消费方覆盖。
	for entry in DebugBufferSet.CONSUMERS:
		var schema: Dictionary = entry.get("schema", {})
		var shader_path: String = str(entry.get("shader", ""))
		var section: String = str(entry.get("section", DebugBufferSet.SECTION_ALL))
		var overrides := {}
		if entry.has("set"):
			overrides["set"] = int(entry["set"])
		if entry.has("binding"):
			overrides["binding"] = int(entry["binding"])
		_compare(
			shader_path,
			DebugBufferSet.marker_name(schema, section),
			DebugBufferSet.emit_glsl_body(schema, overrides, section),
		)

	if not orphans.is_empty():
		lines.append("  ⚠ 无消费方登记（本轮零次比对）：%s" % ", ".join(orphans))
	return _result()


## 比对单个 (shader, 区块) 并记账。
func _compare(shader_path: String, block_name: String, expected: String) -> void:
	var actual = _extract_block(shader_path, block_name)
	if actual == null:
		failed += 1
		lines.append("  ✗ %s :: %s —— @@GEN 区块未找到" % [shader_path, block_name])
	elif _norm(String(actual)) != _norm(expected):
		failed += 1
		lines.append("  ✗ %s :: %s —— 区块与 SSOT 已漂移" % [shader_path, block_name])
	else:
		passed += 1
		lines.append("  ✓ %s :: %s" % [shader_path, block_name])


func _result() -> Dictionary:
	lines.append("═══ 结果：%d 通过 / %d 失败 / %d 无消费方 ═══" % [passed, failed, orphans.size()])
	return {
		"ok": failed == 0,
		"passed": passed,
		"failed": failed,
		"orphans": orphans,
		"report": lines,
	}


## 比对前的归一化：行尾无关（本仓经 autocrlf 混用 CRLF/LF）、行尾空白无关、
## **公共缩进**无关。
##
## 去公共缩进是必需的：同一个生成区块可能落在不同作用域 —— `pick_unified.glsl` 把
## 地形迭代次数放在文件作用域（零缩进），`pick_scene_voxel.glsl` 的同一份拷贝在函数体内
## （缩进 4 空格）。只去掉**所有非空行共有**的那部分缩进，行与行之间的相对缩进原样保留，
## 所以真正的结构漂移照样抓得到。
func _norm(s: String) -> String:
	var raw := s.replace("\r\n", "\n").replace("\r", "\n").split("\n")
	var rows: Array = []
	for line in raw:
		# 只去右侧空白：左侧缩进是下面要统一测量的对象。
		rows.append(String(line).rstrip(" \t"))
	while not rows.is_empty() and String(rows[0]).is_empty():
		rows.remove_at(0)
	while not rows.is_empty() and String(rows[-1]).is_empty():
		rows.remove_at(rows.size() - 1)

	var common := -1
	for row in rows:
		var text := String(row)
		if text.is_empty():
			continue
		var indent := text.length() - text.lstrip(" \t").length()
		if common < 0 or indent < common:
			common = indent
	if common <= 0:
		return "\n".join(rows)

	var out: Array = []
	for row in rows:
		var text := String(row)
		out.append("" if text.is_empty() else text.substr(common))
	return "\n".join(out)


## 取出 shader 里 `// @@GEN <block_name>` 与 `// @@END <block_name>` 之间的正文。
## 返回 null = 区块缺失（与"正文为空"区分开）。
func _extract_block(shader_path: String, block_name: String):
	var f := FileAccess.open(shader_path, FileAccess.READ)
	if f == null:
		return null
	var text := f.get_as_text()
	f.close()
	var begin := "// @@GEN " + block_name
	var end := "// @@END " + block_name
	var collecting := false
	var out: Array = []
	for line in text.split("\n"):
		var stripped := String(line).strip_edges()
		if not collecting:
			if _marker_matches(stripped, begin):
				collecting = true
			continue
		if _marker_matches(stripped, end):
			return "\n".join(out)
		out.append(line)
	return null


## 标记行是否**正好**是这个区块的标记。
##
## 不能用裸 `begins_with`：区块名之间存在前缀关系（`debug_set target_stats` 是
## `debug_set target_stats decl` 的前缀），那样短名会认领长名的区块 —— 抓到别人的正文
## 后比对失败，或更糟，抓到一段恰好相同的正文而静默放行。允许的尾巴只有标记注释
## （`// @@GEN <name> — generated from <path>, do not edit`），它以 em-dash 起头，
## 与"下一段区块名"区分得开。
func _marker_matches(stripped: String, marker: String) -> bool:
	if not stripped.begins_with(marker):
		return false
	var rest := stripped.substr(marker.length())
	return rest.is_empty() or rest.begins_with(" —") or rest.begins_with(" --")
