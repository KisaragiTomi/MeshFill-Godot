class_name TerrainInitializer
extends RefCounted

const TerrainConfigScript := preload("res://scripts/terrain_config.gd")
const DEFAULT_TEXTURE_SIZE := TerrainConfigScript.TEXTURE_SIZE
const DEFAULT_CAPTURE_SIZE := TerrainConfigScript.CAPTURE_SIZE
const DEFAULT_MAX_HEIGHT := TerrainConfigScript.MAX_HEIGHT
const DEFAULT_TERRAIN_NAME := TerrainConfigScript.TERRAIN_NAME
const TERRAIN_GROUP := "meshfill_utils_terrain"


static func reuse_shared_terrain(host: Node, overrides := {}) -> Dictionary:
	if host == null:
		return {"ok": false, "reason": "missing_host"}
	var options := TerrainConfigScript.terrain_options(overrides)
	var terrain_name := str(options.get("terrain_name", DEFAULT_TERRAIN_NAME))
	var existing := find_edit_time_terrain(host, terrain_name)
	if existing is MeshInstance3D and (existing as MeshInstance3D).mesh != null:
		return _terrain_result(existing as MeshInstance3D, false, terrain_name)
	if existing != null:
		return {
			"ok": false,
			"reason": "terrain_node_is_not_mesh_instance",
			"terrain_name": terrain_name,
			"node_type": existing.get_class(),
		}
	return {
		"ok": false,
		"reason": "missing_edit_time_terrain",
		"terrain_name": terrain_name,
	}


static func find_edit_time_terrain(host: Node, terrain_name: String = DEFAULT_TERRAIN_NAME) -> Node:
	if host == null:
		return null

	var candidates: Array[Node] = []
	_add_unique_node(candidates, host)

	if host.is_inside_tree():
		var tree := host.get_tree()
		if tree != null:
			_add_unique_node(candidates, tree.current_scene)

	var owner := host.owner
	while owner != null:
		_add_unique_node(candidates, owner)
		owner = owner.owner

	var parent := host.get_parent()
	while parent != null:
		_add_unique_node(candidates, parent)
		parent = parent.get_parent()

	for root in candidates:
		var direct := root.get_node_or_null(NodePath(terrain_name))
		if direct != null:
			return direct

	for root in candidates:
		var by_group := _find_terrain_in_group(root)
		if by_group != null:
			return by_group

	for root in candidates:
		var recursive := _find_child_by_name(root, terrain_name)
		if recursive != null:
			return recursive

	return null


static func terrain_height_field_from_mesh(terrain: MeshInstance3D, texture_size: int = DEFAULT_TEXTURE_SIZE, fallback_max_height: float = DEFAULT_MAX_HEIGHT) -> PackedFloat32Array:
	var res := maxi(texture_size, 1)
	var field := PackedFloat32Array()
	field.resize(res * res)
	if terrain == null or terrain.mesh == null:
		return field

	var capture_size := float(terrain.get_meta("terrain_capture_size", DEFAULT_CAPTURE_SIZE))
	var height_stats = terrain.get_meta("terrain_height_stats", Vector2(0.0, fallback_max_height))
	var min_height := 0.0
	var max_height := fallback_max_height
	if typeof(height_stats) == TYPE_VECTOR2:
		min_height = float((height_stats as Vector2).x)
		max_height = float((height_stats as Vector2).y)
	var y_fallback := maxf(absf(min_height), absf(max_height))

	var source_res := int(terrain.get_meta("terrain_resolution", 0))
	if source_res <= 0:
		source_res = _infer_square_vertex_resolution(terrain.mesh)
	if source_res <= 0:
		source_res = res

	var source := PackedFloat32Array()
	source.resize(source_res * source_res)
	var source_hit := PackedByteArray()
	source_hit.resize(source_res * source_res)

	for surface_index in range(terrain.mesh.get_surface_count()):
		var arrays := terrain.mesh.surface_get_arrays(surface_index)
		if arrays.is_empty():
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for v in vertices:
			var local := v
			var px := clampi(int(round(((local.x / maxf(capture_size, 0.0001)) + 0.5) * float(source_res - 1))), 0, source_res - 1)
			var pz := clampi(int(round(((local.z / maxf(capture_size, 0.0001)) + 0.5) * float(source_res - 1))), 0, source_res - 1)
			var idx := pz * source_res + px
			if source_hit[idx] == 0:
				source[idx] = local.y
				source_hit[idx] = 1
			else:
				source[idx] = maxf(source[idx], local.y)

	for z in range(res):
		var src_z := int(round(float(z) / maxf(float(res - 1), 1.0) * float(source_res - 1)))
		for x in range(res):
			var src_x := int(round(float(x) / maxf(float(res - 1), 1.0) * float(source_res - 1)))
			var idx := src_z * source_res + src_x
			field[z * res + x] = source[idx] if source_hit[idx] != 0 else 0.0

	if y_fallback > 0.0 and _field_max_abs(field) > y_fallback * 4.0:
		for i in range(field.size()):
			field[i] /= maxf(terrain.scale.y, 0.0001)

	return field


static func _add_unique_node(nodes: Array[Node], node: Node) -> void:
	if node == null:
		return
	if nodes.has(node):
		return
	nodes.append(node)


static func _find_terrain_in_group(root: Node) -> Node:
	if root == null:
		return null
	if root.is_in_group(TERRAIN_GROUP):
		return root
	for child in root.get_children():
		var found := _find_terrain_in_group(child)
		if found != null:
			return found
	return null


static func _find_child_by_name(root: Node, terrain_name: String) -> Node:
	if root == null:
		return null
	if root.name == terrain_name:
		return root
	for child in root.get_children():
		var found := _find_child_by_name(child, terrain_name)
		if found != null:
			return found
	return null


static func _infer_square_vertex_resolution(mesh: Mesh) -> int:
	if mesh == null:
		return 0
	var max_vertices := 0
	for surface_index in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(surface_index)
		if arrays.is_empty():
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		max_vertices = maxi(max_vertices, vertices.size())
	var res := int(round(sqrt(float(max_vertices))))
	return res if res * res == max_vertices else 0


static func _field_max_abs(field: PackedFloat32Array) -> float:
	var max_value := 0.0
	for value in field:
		max_value = maxf(max_value, absf(value))
	return max_value


static func ensure_shared_terrain(host: Node, overrides := {}) -> Dictionary:
	return reuse_shared_terrain(host, overrides)


static func ensure_terrain_initialized(root: Node, options := {}) -> Dictionary:
	if root == null:
		return {"ok": false, "reason": "missing_root"}
	return reuse_shared_terrain(root, options)


static func _terrain_result(terrain: MeshInstance3D, created: bool, terrain_name: String) -> Dictionary:
	var height_stats := Vector2.ZERO
	if terrain.has_meta("terrain_height_stats"):
		height_stats = terrain.get_meta("terrain_height_stats")
	return {
		"ok": true,
		"created": created,
		"terrain": terrain,
		"terrain_name": terrain_name,
		"resolution": int(terrain.get_meta("terrain_resolution", 0)),
		"height_stats": height_stats,
		"visible": terrain.visible,
	}
