## CommonTerrain -- 运行时地形加载 autoload
##
## 在 current_scene 就绪后，查找或创建公共 Terrain 节点。
## 如果场景已有 Terrain 则复用；否则从共享资源加载并创建。
extends Node

const TerrainInitializerScript := preload("res://scripts/terrain_initializer.gd")
const TerrainConfigScript := preload("res://scripts/terrain_config.gd")
const HEADLESS_DISPLAY_NAME := "headless"

const SHARED_MESH_PATH := "res://assets/terrain/common_terrain_mesh.res"
const SHARED_MATERIAL_PATH := "res://assets/terrain/common_terrain_material.tres"

var _injected := false


func _ready() -> void:
	if DisplayServer.get_name() == HEADLESS_DISPLAY_NAME:
		return
	_inject.call_deferred()


func _inject() -> void:
	if _injected:
		return
	var tree := get_tree()
	if tree == null:
		return
	var root := tree.current_scene
	if root == null:
		return

	var result := TerrainInitializerScript.reuse_shared_terrain(root)

	if bool(result.get("ok", false)):
		_injected = true
		return

	var terrain := _create_terrain_from_shared_resources()
	if terrain == null:
		push_warning("[CommonTerrain] 无法从共享资源创建地形")
		return

	root.add_child(terrain)
	terrain.owner = root
	_injected = true


func _create_terrain_from_shared_resources() -> MeshInstance3D:
	var mesh_res = load(SHARED_MESH_PATH)
	if mesh_res == null or not (mesh_res is Mesh):
		push_error("[CommonTerrain] 无法加载共享地形 mesh: %s" % SHARED_MESH_PATH)
		return null

	var mat_res = load(SHARED_MATERIAL_PATH)

	var terrain := MeshInstance3D.new()
	terrain.name = TerrainConfigScript.TERRAIN_NAME
	terrain.mesh = mesh_res as Mesh
	if mat_res is Material:
		terrain.material_override = mat_res as Material
	terrain.visible = true
	terrain.add_to_group(TerrainInitializerScript.TERRAIN_GROUP)
	terrain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	terrain.set_meta("meshfill_common_terrain_initialized", true)
	terrain.set_meta("meshfill_common_terrain_baked", true)
	terrain.set_meta("terrain_capture_size", TerrainConfigScript.CAPTURE_SIZE)
	terrain.set_meta("terrain_resolution", TerrainConfigScript.TEXTURE_SIZE)
	terrain.set_meta("terrain_height_stats", Vector2(0.0, TerrainConfigScript.MAX_HEIGHT))

	return terrain
