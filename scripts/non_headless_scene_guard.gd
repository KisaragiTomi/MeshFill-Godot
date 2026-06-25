extends Node

const HEADLESS_DISPLAY_NAME := "headless"
const HEADLESS_SCENE_ERROR := "Scene launch requires a graphical display backend. Remove --headless and start Godot in non-headless mode."
static var _headless_scene_rejected := false

static func reject_scene_launch_if_headless(tree: SceneTree) -> bool:
	if DisplayServer.get_name() != HEADLESS_DISPLAY_NAME:
		return false
	if not _headless_scene_rejected:
		_headless_scene_rejected = true
		push_error(HEADLESS_SCENE_ERROR)
	if tree != null:
		tree.quit(1)
	return true

func _enter_tree() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_enforce_headless_scene_policy()

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_enforce_headless_scene_policy()
	call_deferred("_enforce_headless_scene_policy")

func _process(_delta: float) -> void:
	_enforce_headless_scene_policy()

func _enforce_headless_scene_policy() -> void:
	if _headless_scene_rejected:
		return
	if DisplayServer.get_name() != HEADLESS_DISPLAY_NAME:
		set_process(false)
		return
	if _is_script_launch() and not _has_running_scene():
		return

	reject_scene_launch_if_headless(get_tree())

func _is_script_launch() -> bool:
	for argument in OS.get_cmdline_args():
		if argument == "--script" or argument == "-s":
			return true
	return false

func _has_running_scene() -> bool:
	var tree := get_tree()
	if tree == null:
		return false
	if tree.current_scene != null:
		return true
	if tree.root == null:
		return false

	for child in tree.root.get_children():
		if _node_or_descendant_has_scene_file(child):
			return true
	return false

func _node_or_descendant_has_scene_file(node: Node) -> bool:
	if node == self:
		return false
	if node.scene_file_path != "":
		return true
	for child in node.get_children():
		if _node_or_descendant_has_scene_file(child):
			return true
	return false
