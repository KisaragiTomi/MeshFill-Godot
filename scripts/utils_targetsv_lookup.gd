@tool
extends RefCounted


static func find_setup(
	owner: Node,
	edited_scene_root: Node = null,
	prefer_edited_root: bool = true,
	climb_direct_parents: bool = false,
	search_parent_recursive: bool = true
) -> Node:
	if owner == null:
		return null
	if prefer_edited_root:
		var edited_setup := _find_setup_under(edited_scene_root)
		if edited_setup != null:
			return edited_setup
	if climb_direct_parents:
		var parent := owner.get_parent()
		while parent != null:
			var direct := parent.get_node_or_null("TargetSVSetup")
			if direct != null:
				return direct
			parent = parent.get_parent()
	if not prefer_edited_root:
		var fallback_edited_setup := _find_setup_under(edited_scene_root)
		if fallback_edited_setup != null:
			return fallback_edited_setup
	if search_parent_recursive and owner.get_parent() != null:
		var sibling := owner.get_parent().find_child("TargetSVSetup", true, false)
		if sibling != null:
			return sibling
	return owner.find_child("TargetSVSetup", true, false)


static func _find_setup_under(root: Node) -> Node:
	return root.find_child("TargetSVSetup", true, false) if root != null else null
