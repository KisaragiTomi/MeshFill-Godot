@tool
class_name FbxTransformBakeService
extends RefCounted
## S2 上游授权工具：把 geo 资产节点的 scale/rotation 冻结进源 .FBX。
## Godot 侧负责坐标数学：每个 FBX 经 per-file 转换 C（子 "Mesh" 节点 transform）导入，
## 烘进 FBX 自身控制点空间的矩阵是 M = C⁻¹ · T · C（T = 用户选定通道的变换）。
## python 后端 = tools/bake_fbx_transform.py（Autodesk FBX SDK）。
## P1 纪律：覆写源文件前**强制备份**（服务侧无条件先拷贝，失败即拒绝烘焙），
## 备份点由本服务唯一持有，python 侧的 --backup 条件分支不再使用。

const GeoAssetScanServiceScript := preload("res://scripts/geo_asset_scan_service.gd")

const BAKE_SCRIPT_PATH := "res://tools/bake_fbx_transform.py"
const BAKE_BACKUP_DIR := "res://backup/geo"
const BAKE_PYTHON_SETTING := "meshfill_editor/bake_fbx_python"


## 注册 ProjectSettings 项（原 demo _ensure_bake_setting 逐字，含 editor_hint 守卫）。
static func ensure_editor_setting() -> void:
	if not Engine.is_editor_hint():
		return
	if not ProjectSettings.has_setting(BAKE_PYTHON_SETTING):
		ProjectSettings.set_setting(BAKE_PYTHON_SETTING, "python")
	ProjectSettings.set_initial_value(BAKE_PYTHON_SETTING, "python")
	ProjectSettings.add_property_info({
		"name": BAKE_PYTHON_SETTING,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_GLOBAL_FILE,
		"hint_string": "*.exe,*",
	})


## M = C⁻¹ · T · C（原 demo _do_bake 的基变换段逐字）。
static func compute_bake_basis(node: Node3D, bake_rotation: bool, bake_scale: bool) -> Basis:
	# C = the per-file import conversion (child Mesh node transform).
	var mesh_inst := node.get_node_or_null("Mesh") as Node3D
	if mesh_inst == null:
		# 原行为：C 退化为 IDENTITY，M = T —— 会把一个**错误的**矩阵烘进用户的源 .FBX。
		# 返回类型是 Basis 无法返回 null；真正的硬失败在 bake_node_transform 的前置守卫，
		# 那里在调用 python 之前就拒绝烘焙。
		push_error("[FbxTransformBakeService] compute_bake_basis(): 节点 %s 缺少 \"Mesh\" 子节点 —— 拿不到 per-file 导入转换矩阵 C，烘焙矩阵不可信" % node.name)
		assert(false, "FbxTransformBakeService.compute_bake_basis: missing Mesh child")
	var c_basis: Basis = mesh_inst.transform.basis if mesh_inst != null else Basis.IDENTITY
	# T = the user's transform, restricted to the chosen channels.
	var node_basis := node.transform.basis
	var rot_b := Basis(node_basis.get_rotation_quaternion())
	var scl := node_basis.get_scale()
	var t := Basis.IDENTITY
	if bake_rotation:
		t = rot_b
	if bake_scale:
		t = t * Basis.IDENTITY.scaled(scl)
	# M = C^-1 * T * C, expressed in the FBX's own control-point space.
	return c_basis.inverse() * t * c_basis


## 冻结入口。成功时把已烘通道从节点上清零（rotation → ZERO / scale → ONE），
## 场景标脏与 reimport 由调用方负责（编辑器编排职责）。
## 返回 {"ok": bool, "reason": String, "exit_code": int, "log": String,
##       "source": String(res://), "backup_path": String(abs), "command": String}
## reason ∈ ok / nothing_to_bake / missing_node / no_source_meta / script_missing /
##          backup_failed / bake_failed
static func bake_node_transform(node: Node3D, bake_rotation: bool, bake_scale: bool) -> Dictionary:
	var result := {"ok": false, "reason": "", "exit_code": -1, "log": "",
		"source": "", "backup_path": "", "command": ""}
	if node == null:
		result["reason"] = "missing_node"
		return result
	if not bake_rotation and not bake_scale:
		result["reason"] = "nothing_to_bake"
		return result
	var src_res := str(node.get_meta(GeoAssetScanServiceScript.GEO_SOURCE_META, ""))
	result["source"] = src_res
	if src_res.is_empty():
		result["reason"] = "no_source_meta"
		push_error("[FbxTransformBakeService] 节点 %s 缺少 %s meta —— 不知道要覆写哪个源 .FBX，拒绝烘焙" % [
			node.name, GeoAssetScanServiceScript.GEO_SOURCE_META])
		assert(false, "FbxTransformBakeService: no source meta")
		return result
	# 前置守卫：缺 "Mesh" 子节点就拿不到导入转换矩阵 C，M = C⁻¹·T·C 不成立 ——
	# 在 python 被调用、源 .FBX 被覆写**之前**硬失败，绝不用 IDENTITY 顶替 C。
	if node.get_node_or_null("Mesh") as Node3D == null:
		result["reason"] = "missing_mesh_child"
		push_error("[FbxTransformBakeService] 节点 %s（源 %s）缺少 \"Mesh\" 子节点 —— 无法求导入转换矩阵 C，拒绝烘焙" % [node.name, src_res])
		assert(false, "FbxTransformBakeService: missing Mesh child")
		return result

	var m := compute_bake_basis(node, bake_rotation, bake_scale)
	var parts := PackedStringArray()
	for v in [m.x, m.y, m.z]:
		parts.append("%.10f" % v.x)
		parts.append("%.10f" % v.y)
		parts.append("%.10f" % v.z)
	var basis_arg := ",".join(parts)

	var python := str(ProjectSettings.get_setting(BAKE_PYTHON_SETTING, "python"))
	var script_abs := ProjectSettings.globalize_path(BAKE_SCRIPT_PATH)
	var src_abs := ProjectSettings.globalize_path(src_res)
	if not FileAccess.file_exists(script_abs):
		result["reason"] = "script_missing"
		push_error("[FbxTransformBakeService] python 后端脚本缺失：%s（来自 %s）—— 拒绝烘焙" % [script_abs, BAKE_SCRIPT_PATH])
		assert(false, "FbxTransformBakeService: bake script missing")
		return result

	# P1：覆写前强制备份 —— 失败即拒绝，python 不会被调用。
	var backup_path := _mandatory_backup(src_abs, ProjectSettings.globalize_path(BAKE_BACKUP_DIR))
	if backup_path.is_empty():
		result["reason"] = "backup_failed"
		push_error("[FbxTransformBakeService] Backup failed for %s — bake refused (P1: backup before overwrite)." % src_res)
		return result
	result["backup_path"] = backup_path

	var args := PackedStringArray([
		script_abs,
		"--fbx", src_abs,
		"--basis-cols", basis_arg,
		"--label", str(node.name),
	])
	result["command"] = "%s %s" % [python, " ".join(args)]
	var out := []
	var code := OS.execute(python, args, out, true)
	var log_text := ""
	for chunk in out:
		log_text += str(chunk)
	result["exit_code"] = code
	result["log"] = log_text

	if code != 0:
		result["reason"] = "bake_failed"
		push_error("[FbxTransformBakeService] FBX bake failed (exit %d): %s" % [code, log_text])
		return result

	# 几何已携带变换 —— 清掉已烘通道，避免 reimport 后二次叠加（原 demo 行为）。
	if bake_rotation:
		node.rotation = Vector3.ZERO
	if bake_scale:
		node.scale = Vector3.ONE
	result["ok"] = true
	result["reason"] = "ok"
	return result


## 强制备份：时间戳文件名（与 python 侧 backup_file 同约定 stem__YYYYmmdd_HHMMSS.ext），
## 冲突追加 _N。成功返回绝对路径，任何失败返回 ""。
static func _mandatory_backup(src_abs: String, backup_dir_abs: String) -> String:
	if not FileAccess.file_exists(src_abs):
		return ""
	var mk_err := DirAccess.make_dir_recursive_absolute(backup_dir_abs)
	if mk_err != OK and mk_err != ERR_ALREADY_EXISTS:
		return ""
	var stem := src_abs.get_file().get_basename()
	var ext := src_abs.get_extension()
	var dt := Time.get_datetime_dict_from_system()
	var stamp := "%04d%02d%02d_%02d%02d%02d" % [dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second]
	var dest := backup_dir_abs.path_join("%s__%s.%s" % [stem, stamp, ext])
	var i := 1
	while FileAccess.file_exists(dest):
		dest = backup_dir_abs.path_join("%s__%s_%d.%s" % [stem, stamp, i, ext])
		i += 1
	if DirAccess.copy_absolute(src_abs, dest) != OK:
		return ""
	return dest
