extends SceneTree

const SCENE := "res://demos/asset-descriptor-demo/asset-descriptor-demo.tscn"


func _initialize() -> void:
	_run()


func _run() -> void:
	var packed: PackedScene = load(SCENE)
	var inst := packed.instantiate()
	root.add_child(inst)
	for i in range(5):
		await process_frame

	var rows := {"tree": [], "rock": []}
	for ch in inst.get_children():
		var n := ch.name
		if not (n.begins_with("tree_") or n.begins_with("rock_")):
			continue
		var mi := ch.get_node_or_null("Mesh") as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var aabb: AABB = mi.mesh.get_aabb()
		var xf := mi.global_transform
		# World-space AABB by transforming all 8 corners.
		var mn := Vector3(INF, INF, INF)
		var mx := Vector3(-INF, -INF, -INF)
		for cx in [aabb.position.x, aabb.position.x + aabb.size.x]:
			for cy in [aabb.position.y, aabb.position.y + aabb.size.y]:
				for cz in [aabb.position.z, aabb.position.z + aabb.size.z]:
					var wp := xf * Vector3(cx, cy, cz)
					mn = mn.min(wp)
					mx = mx.max(wp)
		var size := mx - mn
		var upright := size.y >= size.x and size.y >= size.z
		var key := "tree" if n.begins_with("tree_") else "rock"
		rows[key].append({
			"cx": (mn.x + mx.x) * 0.5,
			"hx": size.x * 0.5,
			"hz": size.z * 0.5,
			"y_min": mn.y,
			"y_max": mx.y,
			"upright": upright,
		})
		print("%s world_size=%s y_min=%.3f y_max=%.3f upright=%s" % [n, size, mn.y, mx.y, upright])

	for key in ["tree", "rock"]:
		var items: Array = rows[key]
		items.sort_custom(func(a, b): return a["cx"] < b["cx"])
		print("--- %s spacing (sorted by x) ---" % key)
		for i in range(items.size() - 1):
			var a: Dictionary = items[i]
			var b: Dictionary = items[i + 1]
			var gap: float = (float(b["cx"]) - float(a["cx"])) - (float(a["hx"]) + float(b["hx"]))
			print("  pair %d-%d center_dx=%.3f x_gap=%.3f %s" % [
				i, i + 1, float(b["cx"]) - float(a["cx"]), gap, "OVERLAP" if gap < 0.0 else "clear"])
	quit()