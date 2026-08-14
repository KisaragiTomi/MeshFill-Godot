@tool
class_name AssetDescriptorBaker
extends RefCounted

const AssetDescriptorScript := preload("res://scripts/asset_descriptor.gd")
## Builds a descriptor from the canonical ProfileSamples decoded by Asset Overview.
## Coarse probes, fine-score samples, and stamp records already share this format, so
## Bake AD does not regenerate or merge any legacy probe/voxel representation.
static func descriptor_from_profile_samples(
	mesh: Mesh,
	config: Dictionary = {}
) -> AssetDescriptor:
	if mesh == null:
		push_error("[AssetDescriptorBaker] descriptor_from_profile_samples(): mesh 为 null（asset_id=%s）—— 无法烘焙 descriptor" % str(config.get("asset_id", "")))
		assert(false, "AssetDescriptorBaker: null mesh")
		return null
	var profile_samples: Array = config.get("profile_samples", [])
	if profile_samples.is_empty():
		push_error("[AssetDescriptorBaker] descriptor_from_profile_samples(): config.profile_samples 为空（asset_id=%s, source_mesh_path=%s）—— FBX 内嵌通道没解出任何 canonical ProfileSample" % [
			str(config.get("asset_id", "")), str(config.get("source_mesh_path", ""))])
		assert(false, "AssetDescriptorBaker: empty profile_samples")
		return null

	var color: Color = config.get("color", Color.WHITE)
	var complexity := clampf(float(config.get("complexity", color.a)), 0.0, 1.0)

	var descriptor: AssetDescriptor = AssetDescriptorScript.new()
	descriptor.mesh = mesh
	descriptor.set_color_and_complexity(color, complexity)
	descriptor.asset_id = str(config.get("asset_id", ""))
	descriptor.object_type = str(config.get("object_type", ""))
	descriptor.source_mesh_path = str(config.get("source_mesh_path", ""))
	descriptor.set_profile_samples(profile_samples)
	if descriptor.profile_samples.is_empty():
		push_error("[AssetDescriptorBaker] descriptor_from_profile_samples(): 传入 %d 条 ProfileSample 但校验后一条不剩（asset_id=%s）—— 采样数据非法" % [
			profile_samples.size(), str(config.get("asset_id", ""))])
		assert(false, "AssetDescriptorBaker: all ProfileSamples rejected")
		return null
	if config.has("pivot_variants"):
		descriptor.set_pivot_variants(config.get("pivot_variants", []))
	return descriptor


## 批量烘焙落盘入口（全仓唯一的 descriptor ResourceSaver.save 点）。
## 场景侧负责 canonical ProfileSample 请求组装，本方法负责 descriptor 构建 + 持久化。
## requests 每项: {"name": String, "mesh": Mesh, "config": Dictionary}
##   —— mesh 或有效 ProfileSample 缺失时计 failed。
## 返回 {"ok","baked","failed","total","dir","paths"}（插件 Bake AD toolbar 契约键，勿改名）。
static func bake_and_save_batch(requests: Array, output_dir: String) -> Dictionary:
	var output_dir_abs := ProjectSettings.globalize_path(output_dir)
	var dir_err := DirAccess.make_dir_recursive_absolute(output_dir_abs)
	if dir_err != OK and dir_err != ERR_ALREADY_EXISTS:
		push_error("[AssetDescriptorBaker] bake_and_save_batch(): 无法创建输出目录 %s（err %d）—— 拒绝烘焙" % [output_dir_abs, dir_err])
		assert(false, "AssetDescriptorBaker: output dir creation failed")
		return {
			"ok": false,
			"baked": 0,
			"failed": requests.size(),
			"total": requests.size(),
			"dir": output_dir,
			"paths": ([] as Array[String]),
		}
	var baked := 0
	var failed := 0
	var saved_paths: Array[String] = []
	for request_index in range(requests.size()):
		var raw_request = requests[request_index]
		if not raw_request is Dictionary:
			failed += 1
			push_error("[AssetDescriptorBaker] bake_and_save_batch(): requests[%d] 不是 Dictionary（typeof=%d）—— 请求列表损坏" % [request_index, typeof(raw_request)])
			assert(false, "AssetDescriptorBaker: non-Dictionary bake request")
			continue
		var request := raw_request as Dictionary
		var request_name := str(request.get("name", ""))
		var descriptor := descriptor_from_profile_samples(
			request.get("mesh", null), request.get("config", {}))
		if descriptor == null or request_name.is_empty():
			failed += 1
			push_error("[AssetDescriptorBaker] bake_and_save_batch(): requests[%d] 烘焙失败（name=\"%s\", descriptor=%s）—— 缺 mesh / 有效 ProfileSample，或 name 为空" % [
				request_index, request_name, "null" if descriptor == null else "ok"])
			assert(false, "AssetDescriptorBaker: bake request produced no descriptor")
			continue
		var path := "%s/%s_descriptor.tres" % [output_dir, request_name]
		# Preserve per-asset authored overrides across re-bakes: a fresh bake rebuilds
		# the descriptor from canonical samples/config and would reset these to their
		# defaults（score 覆盖 → -1 继承全局；spacing_radius_scale → 1.0 无缩放）。
		if ResourceLoader.exists(path):
			var old_descriptor: Resource = load(path)
			if old_descriptor == null:
				failed += 1
				push_error("[AssetDescriptorBaker] bake_and_save_batch(): 既有 descriptor %s 存在但加载失败 —— 无法继承 per-asset score 覆盖，拒绝用一份丢失覆盖的新 descriptor 覆写它" % path)
				assert(false, "AssetDescriptorBaker: existing descriptor load failed")
				continue
			# 旧 .tres 无该字段时 get() 返回 null → 跳过 → 留新 descriptor 的默认值。
			# 这是 legacy 迁移契约（见 asset_descriptor.gd 的 Score Params 注释），不是兜底。
			# ⚠ spacing_radius_scale 也在列：它是**手调**值（Asset Overview 面板写入），
			# 不在 bake 请求的 config 里重建 —— 漏掉这一项，每次重扫烘焙都会把用户调好的
			# 互斥半径悄悄打回 1.0。
			for prop in ["score_min_match_fraction", "score_dim_weight_collision",
					"score_dim_weight_complexity", "score_dim_weight_color",
					"score_color_match_max_l1", "score_collision_match_max",
					"score_complexity_overfill_percent", "spacing_radius_scale"]:
				var carried = old_descriptor.get(prop)
				if carried != null:
					descriptor.set(prop, carried)
		var save_err := ResourceSaver.save(descriptor, path)
		if save_err != OK:
			failed += 1
			push_error("[AssetDescriptorBaker] Failed to save descriptor for %s (err %d)" % [request_name, save_err])
			continue
		baked += 1
		saved_paths.append(path)
	return {
		"ok": failed == 0 and baked > 0,
		"baked": baked,
		"failed": failed,
		"total": requests.size(),
		"dir": output_dir,
		"paths": saved_paths,
	}
