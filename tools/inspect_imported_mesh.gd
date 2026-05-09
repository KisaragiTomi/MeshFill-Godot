extends SceneTree


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var mesh_path := args[0] if args.size() > 0 else ""
	if mesh_path.is_empty():
		push_error("Usage: --script tools/inspect_imported_mesh.gd -- res://path/to/model")
		quit(ERR_INVALID_PARAMETER)
		return

	var resource := load(mesh_path)
	if resource == null:
		push_error("Cannot load %s" % mesh_path)
		quit(ERR_FILE_CANT_OPEN)
		return

	var meshes: Array[Mesh] = []
	if resource is Mesh:
		meshes.append(resource as Mesh)
	elif resource is PackedScene:
		var root := (resource as PackedScene).instantiate()
		_print_node_tree(root)
		_collect_meshes(root, meshes)
		root.free()

	print("resource=%s type=%s mesh_count=%d" % [mesh_path, resource.get_class(), meshes.size()])
	for i in range(meshes.size()):
		var mesh := meshes[i]
		var aabb := mesh.get_aabb()
		print("mesh[%d] class=%s surfaces=%d aabb_pos=%s aabb_size=%s" % [
			i,
			mesh.get_class(),
			mesh.get_surface_count(),
			aabb.position,
			aabb.size,
		])
		for surface_index in range(mesh.get_surface_count()):
			var material := mesh.surface_get_material(surface_index)
			var mat_name := "<none>"
			var albedo := ""
			if material != null:
				mat_name = material.resource_name
				if material is StandardMaterial3D:
					albedo = " albedo=%s" % [(material as StandardMaterial3D).albedo_color]
			print("  surface[%d] material=%s%s" % [surface_index, mat_name, albedo])
	quit(OK)


func _collect_meshes(node: Node, meshes: Array[Mesh]) -> void:
	if node is MeshInstance3D:
		var mesh := (node as MeshInstance3D).mesh
		if mesh != null:
			meshes.append(mesh)
	elif node is ImporterMeshInstance3D:
		var importer_mesh = node.get("mesh")
		if importer_mesh != null and importer_mesh.has_method("get_mesh"):
			var converted = importer_mesh.get_mesh()
			if converted is Mesh:
				meshes.append(converted as Mesh)

	for child in node.get_children():
		_collect_meshes(child, meshes)


func _print_node_tree(node: Node, depth: int = 0) -> void:
	var indent := ""
	for i in range(depth):
		indent += "  "
	var details := ""
	if node is Node3D:
		var node_3d := node as Node3D
		details = " pos=%s rot=%s scale=%s" % [
			node_3d.position,
			node_3d.rotation_degrees,
			node_3d.scale,
		]
	if node is MeshInstance3D or node is ImporterMeshInstance3D:
		details += " mesh_node=true"
	print("%s%s class=%s%s" % [indent, node.name, node.get_class(), details])
	for child in node.get_children():
		_print_node_tree(child, depth + 1)
