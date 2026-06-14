@tool
extends Node3D

const TargetSceneVoxelGeneratorScript := preload("res://scripts/target_scene_voxel_generator.gd")
const TargetSVLoader := preload("res://scripts/target_sv_loader.gd")
const TerrainInitializerScript := preload("res://scripts/terrain_initializer.gd")
const SceneVoxelScript := preload("res://scripts/scene_voxel.gd")
const SceneVoxelSourceRecordScript := preload("res://scripts/scene_voxel_source_record.gd")
const SceneVoxelTargetScript := preload("res://scripts/scene_voxel_target.gd")
const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")

const HEIGHT_PATH := "res://textures/scene_height_0_1.png"
const GENERATED_GROUP := "target_sv_point_cloud_generated"
const PROJECT_VOXEL_BOX_NODE := "ProjectVoxelBoxes"
const PROJECT_VOXEL_TILE_SIZE := Vector3i(4, 4, 4)
const BOX_VIEW_COLOR := "color"
const BOX_VIEW_COMPLEXITY := "complexity"
const BOX_VIEW_COLLISION := "collision"

@export var display_scale := 0.03
@export var terrain_stride := 4
@export var occupancy_threshold := 0.001
@export var project_voxel_box_scale := 0.42
@export var build_project_voxels_on_ready := true

var _metadata: Dictionary = {}
var _visual_bytes := PackedByteArray()
var _collision_bytes := PackedByteArray()
var _height_image: Image
var _height_luma_bytes := PackedByteArray()
var _height_width := 0
var _height_height := 0
var _decoded_target_sv: Dictionary = {}
var _project_voxel_sv: Dictionary = {}
var _project_voxel_box_view := BOX_VIEW_COLOR
var _target_voxels_built := false


func _ready() -> void:
	_rebuild_visualization()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if not event.shift_pressed:
			return
		match event.keycode:
			KEY_R:
				_set_project_voxel_box_view(BOX_VIEW_COLOR)
				_mark_input_as_handled()
			KEY_T:
				_set_project_voxel_box_view(BOX_VIEW_COMPLEXITY)
				_mark_input_as_handled()
			KEY_Y:
				_set_project_voxel_box_view(BOX_VIEW_COLLISION)
				_mark_input_as_handled()


func _mark_input_as_handled() -> void:
	var viewport := get_viewport()
	if viewport != null:
		viewport.set_input_as_handled()


func _set_project_voxel_box_view(view_mode: String) -> void:
	if not [BOX_VIEW_COLOR, BOX_VIEW_COMPLEXITY, BOX_VIEW_COLLISION].has(view_mode):
		return
	_project_voxel_box_view = view_mode
	_build_project_voxel_boxes()
	_build_labels()


func _toggle_target_voxels() -> void:
	if _target_voxels_built:
		var existing := get_node_or_null("TargetSVVoxels")
		if existing != null:
			existing.free()
		_target_voxels_built = false
	else:
		_build_target_voxels()
		_target_voxels_built = true
	_build_labels()


func ensure_test_terrain_initialized() -> Dictionary:
	if not is_inside_tree():
		return {"ok": true, "skipped": true, "reason": "not_in_tree"}
	return TerrainInitializerScript.ensure_shared_terrain(self, {
		"visible": false,
	})


func get_project_scene_voxel_snapshot() -> Dictionary:
	return _project_voxel_sv.duplicate(true)


func get_target_sv_scene_voxel() -> Dictionary:
	return get_project_scene_voxel_snapshot()


func get_target_sv_scene_voxel_snapshot() -> Dictionary:
	return get_project_scene_voxel_snapshot()


func get_project_voxel_box_view() -> String:
	return _project_voxel_box_view


func _rebuild_visualization() -> void:
	var terrain_contract := ensure_test_terrain_initialized()
	if not bool(terrain_contract.get("ok", false)):
		push_error("[TargetSVPointCloudDemo] Terrain initialization failed: %s" % str(terrain_contract.get("reason", "unknown")))
	_clear_generated_visuals()
	_target_voxels_built = false
	_load_fixture()
	if _metadata.is_empty():
		return
	_build_terrain()
	_build_project_scene_voxel_snapshot()
	if build_project_voxels_on_ready:
		_build_project_voxel_boxes()
	_build_labels()


func _clear_generated_visuals() -> void:
	for child in get_children():
		if child.is_in_group(GENERATED_GROUP):
			remove_child(child)
			child.free()


func _add_generated_child(node: Node) -> void:
	node.add_to_group(GENERATED_GROUP)
	add_child(node)


func _load_fixture() -> void:
	_decoded_target_sv = {}
	_project_voxel_sv = {}
	TargetSVLoader.reload()
	_metadata = TargetSVLoader.metadata()
	_visual_bytes = TargetSVLoader.visual_bytes()
	_collision_bytes = TargetSVLoader.collision_bytes()
	if _metadata.is_empty():
		push_error("[TargetSVPointCloudDemo] TargetSVLoader metadata is empty")
		return

	var terrain_height_texture := load(HEIGHT_PATH) as Texture2D
	_height_image = terrain_height_texture.get_image() if terrain_height_texture != null else Image.load_from_file(HEIGHT_PATH)
	if _height_image != null and _height_image.get_format() != Image.FORMAT_L8:
		_height_image.convert(Image.FORMAT_L8)
	if _height_image != null and not _height_image.is_empty():
		_height_width = _height_image.get_width()
		_height_height = _height_image.get_height()
		_height_luma_bytes = _height_image.get_data()


func _build_terrain() -> void:
	if _height_image == null or _metadata.is_empty():
		return
	var texture_size := int(_metadata.get("texture_size", _height_image.get_width()))
	var capture_size := float(_metadata.get("capture_size", 1.0))
	var height_span := _terrain_height_world_span()
	var stride := maxi(terrain_stride, 1)
	var steps := int(ceil(float(texture_size - 1) / float(stride)))

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for z_step in range(steps):
		for x_step in range(steps):
			var x0 := mini(x_step * stride, texture_size - 1)
			var z0 := mini(z_step * stride, texture_size - 1)
			var x1 := mini((x_step + 1) * stride, texture_size - 1)
			var z1 := mini((z_step + 1) * stride, texture_size - 1)
			_add_terrain_triangle(st, x0, z0, x1, z0, x1, z1, texture_size, capture_size, height_span)
			_add_terrain_triangle(st, x0, z0, x1, z1, x0, z1, texture_size, capture_size, height_span)
	st.generate_normals()

	var terrain := MeshInstance3D.new()
	terrain.name = "HeightTextureTerrain"
	terrain.mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.28, 0.34, 0.28, 1.0)
	mat.roughness = 0.9
	terrain.material_override = mat
	_add_generated_child(terrain)


func _terrain_height_world_span() -> float:
	return float(_metadata.get("max_height", 120.0))


func _add_terrain_triangle(st: SurfaceTool, ax: int, az: int, bx: int, bz: int, cx: int, cz: int, texture_size: int, capture_size: float, height_span: float) -> void:
	for p in [Vector2i(ax, az), Vector2i(bx, bz), Vector2i(cx, cz)]:
		var uv := Vector2(float(p.x) / float(texture_size - 1), float(p.y) / float(texture_size - 1))
		st.set_uv(uv)
		st.add_vertex(_pixel_to_world(p.x, p.y, texture_size, capture_size, _height_at_pixel(p.x, p.y) * height_span))


func _build_target_voxels() -> void:
	if _metadata.is_empty() or _visual_bytes.is_empty() or _collision_bytes.is_empty():
		return
	var texture_size := int(_metadata.get("texture_size", 1))
	var slice_count := int(_metadata.get("slice_count", 1))
	var capture_size := float(_metadata.get("capture_size", 1.0))
	var vertical_span := float(_metadata.get("vertical_span", 16.0))
	var height_span := _terrain_height_world_span()
	var decoded := TargetSceneVoxelGeneratorScript.decode_target_read_buffers(_visual_bytes, _collision_bytes, texture_size, slice_count)
	var occupancy: PackedFloat32Array = decoded.get("target_occupancy", PackedFloat32Array())
	var target_color: PackedColorArray = decoded.get("target_color", PackedColorArray())
	if occupancy.is_empty() or target_color.is_empty():
		push_error("[TargetSVPointCloudDemo] TargetSV decode failed: %s" % str(decoded))
		return
	var collision_values := _collision_float_values(texture_size * texture_size * slice_count)

	var non_empty := PackedInt32Array()
	for i in range(occupancy.size()):
		if occupancy[i] > occupancy_threshold:
			non_empty.append(i)
	var instance_count := non_empty.size()

	var box := BoxMesh.new()
	var cell_size := capture_size / maxf(float(texture_size - 1), 1.0) * display_scale * 0.72
	var slice_height := vertical_span / maxf(float(slice_count), 1.0) * display_scale * 0.72
	box.size = Vector3(cell_size, maxf(slice_height, 0.02), cell_size)

	var multi_mesh := MultiMesh.new()
	multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
	multi_mesh.use_colors = true
	multi_mesh.mesh = box
	multi_mesh.instance_count = instance_count

	var slice_voxel_count := texture_size * texture_size
	for write_index in range(instance_count):
		var idx := non_empty[write_index]
		var slice_index := idx / slice_voxel_count
		var rem := idx % slice_voxel_count
		var z := rem / texture_size
		var x := rem % texture_size
		var local_y := (float(slice_index) + 0.5) / float(slice_count) * vertical_span
		var terrain_y := _height_at_pixel(x, z) * height_span
		var pos := _pixel_to_world(x, z, texture_size, capture_size, terrain_y + local_y)
		multi_mesh.set_instance_transform(write_index, Transform3D(Basis(), pos))
		var color := target_color[idx]
		var collision := collision_values[idx] if idx < collision_values.size() else 0.0
		color = color.lerp(Color(0.82, 0.78, 0.68, 1.0), clampf(collision * 0.45, 0.0, 1.0))
		color.a = clampf(maxf(occupancy[idx], 0.35), 0.35, 1.0)
		multi_mesh.set_instance_color(write_index, color)

	var instance := MultiMeshInstance3D.new()
	instance.name = "TargetSVVoxels"
	instance.multimesh = multi_mesh
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.6
	instance.material_override = mat
	_add_generated_child(instance)


func _build_labels() -> void:
	var existing_label := get_node_or_null("Summary")
	if existing_label != null:
		existing_label.free()
	var label := Label3D.new()
	label.name = "Summary"
	label.transform.origin = Vector3(-15.0, 4.5, -14.5)
	label.font_size = 26
	label.pixel_size = 0.018
	label.outline_size = 5
	label.text = "\n".join([
		"TargetSV Point Cloud Conversion",
		"source: TargetSV_PT.bgeo.sc + scene_height_0_1.png",
		"attrs: %s" % str(_metadata.get("attribute_map", {})),
		"points: %d / %d   voxels: %d" % [
			int(_metadata.get("used_point_count", 0)),
			int(_metadata.get("point_count", 0)),
			int(_metadata.get("non_empty_voxel_count", 0)),
		],
		"grid: %dx%dx%d   vertical_span: %.1f" % [
			int(_metadata.get("texture_size", 0)),
			int(_metadata.get("texture_size", 0)),
			int(_metadata.get("slice_count", 0)),
			float(_metadata.get("vertical_span", 0.0)),
		],
		"project SV: %d voxels   %d tiles   box view: %s" % [
			int(_project_voxel_sv.get("scene_voxel_count", 0)),
			int(_project_voxel_sv.get("scene_voxel_tile_count", 0)),
			_project_voxel_box_view,
		],
		"[Shift+R] Color   [Shift+T] Complexity   [Shift+Y] Collision",
	])
	_add_generated_child(label)


func _decode_target_sv_buffers() -> Dictionary:
	if not _decoded_target_sv.is_empty():
		return _decoded_target_sv
	if _metadata.is_empty() or _visual_bytes.is_empty() or _collision_bytes.is_empty():
		return {}
	var texture_size := int(_metadata.get("texture_size", 1))
	var slice_count := int(_metadata.get("slice_count", 1))
	var decoded := TargetSceneVoxelGeneratorScript.decode_target_read_buffers(_visual_bytes, _collision_bytes, texture_size, slice_count)
	if not bool(decoded.get("valid", false)):
		push_error("[TargetSVPointCloudDemo] TargetSV decode failed: %s" % str(decoded))
		return decoded
	_decoded_target_sv = decoded
	return _decoded_target_sv


func _build_project_scene_voxel_snapshot() -> Dictionary:
	_project_voxel_sv = {}
	var decoded := _decode_target_sv_buffers()
	if not bool(decoded.get("valid", false)):
		return {}

	var texture_size := int(_metadata.get("texture_size", 1))
	var slice_count := int(_metadata.get("slice_count", 1))
	var voxel_count := texture_size * texture_size * slice_count
	var capture_size := float(_metadata.get("capture_size", 1.0))
	var vertical_span := float(_metadata.get("vertical_span", 16.0))
	var max_height := float(_metadata.get("max_height", 120.0))
	var height_span := _terrain_height_world_span()
	var grid_size := Vector3i(texture_size, slice_count, texture_size)
	var voxel_size := Vector3(
		capture_size / maxf(float(texture_size - 1), 1.0),
		vertical_span / maxf(float(slice_count), 1.0),
		capture_size / maxf(float(texture_size - 1), 1.0)
	)
	var grid_origin := Vector3(-capture_size * 0.5, 0.0, -capture_size * 0.5)
	var occupancy: PackedFloat32Array = decoded.get("target_occupancy", PackedFloat32Array())
	var target_color: PackedColorArray = decoded.get("target_color", PackedColorArray())
	var collision_field := _collision_float_values(voxel_count)
	if occupancy.size() != voxel_count or target_color.size() != voxel_count or collision_field.size() != voxel_count:
		push_error("[TargetSVPointCloudDemo] TargetSV field sizes do not match grid")
		return {}

	var complexity_field := PackedFloat32Array()
	complexity_field.resize(voxel_count)
	var scene_voxels := {}
	var scene_voxel_tiles := {}
	var source_record := _make_project_target_sv_source_record(grid_size, voxel_size, grid_origin)
	var active_count := 0
	var collision_count := 0
	var slice_voxel_count := texture_size * texture_size
	for idx in range(voxel_count):
		var complexity := clampf(occupancy[idx], 0.0, 1.0)
		var collision_strength := clampf(collision_field[idx], 0.0, 1.0)
		complexity_field[idx] = complexity
		if maxf(complexity, collision_strength) <= occupancy_threshold:
			continue

		var slice_index := int(idx / slice_voxel_count)
		var rem := idx % slice_voxel_count
		var z := int(rem / texture_size)
		var x := rem % texture_size
		var voxel_xz := Vector2i(x, z)
		var color := target_color[idx]
		color.a = complexity
		var scene_voxel := SceneVoxelScript.accepted_internal({
			"complexity": complexity,
			"color": color,
			"collision": collision_strength,
			"slice_index": slice_index,
			"voxel_xz": voxel_xz,
			"base_pixel": voxel_xz,
		})
		var key := SceneVoxelSourceRecordScript.scene_voxel_key(slice_index, voxel_xz)
		scene_voxels[key] = scene_voxel
		_accumulate_project_scene_voxel_tile(
			scene_voxel_tiles,
			Vector3i(x, slice_index, z),
			complexity,
			collision_strength,
			grid_size,
			source_record
		)
		active_count += 1
		if collision_strength > occupancy_threshold:
			collision_count += 1

	var tile_ids := SceneVoxelTileCodecScript.sorted_tile_ids(scene_voxel_tiles)
	var dirty_index := SceneVoxelTileCodecScript.pack_dirty_index_bytes(tile_ids, scene_voxel_tiles)
	var tile_grid_size := SceneVoxelTileCodecScript.tile_grid_size(grid_size, PROJECT_VOXEL_TILE_SIZE)
	var terrain_height_field := _make_project_terrain_height_field(texture_size, height_span)
	_project_voxel_sv = {
		"type": "SV",
		"source_voxel_type": SceneVoxelTargetScript.TARGET_TYPE,
		"target_role": str(_metadata.get("target_role", "TargetSV")),
		"target_pipeline": "guidance",
		"target_guidance_only": bool(_metadata.get("target_guidance_only", true)),
		"target_dirty_flags": SceneVoxelTargetScript.target_dirty_flags(),
		"height_relative": bool(_metadata.get("height_relative", true)),
		"height_buffer_applied": bool(_metadata.get("height_buffer_applied", false)),
		"collision_buffer_applied": bool(_metadata.get("collision_buffer_applied", false)),
		"gpu_first": false,
		"cpu_fallback": false,
		"runtime_read_source": "target_sv_point_cloud_fixture",
		"complexity_field_source": "target_sv_visual_collision_decode",
		"collision_field_runtime_read_source": "target_sv_collision_buffer_decode",
		"complexity_field_staging_source": "target_sv_point_cloud_snapshot",
		"collision_field_staging_source": "target_sv_point_cloud_snapshot",
		"distance_or_occupancy": "occupancy",
		"bounds": Rect2i(Vector2i.ZERO, Vector2i(texture_size, texture_size)),
		"grid_size": grid_size,
		"voxel_size": voxel_size,
		"grid_origin": grid_origin,
		"complexity_field": complexity_field,
		"collision_field": collision_field,
		"terrain_height_field": terrain_height_field,
		"terrain_height_source": HEIGHT_PATH,
		"max_height": max_height,
		"terrain_height_span": height_span,
		"capture_size": capture_size,
		"vertical_span": vertical_span,
		"texture_size": texture_size,
		"slice_count": slice_count,
		"scene_voxels": scene_voxels,
		"scene_voxel_count": scene_voxels.size(),
		"collision_cell_count": collision_count,
		"target_active_voxel_count": active_count,
		"target_collision_voxel_count": collision_count,
		"scene_voxel_tile_size": PROJECT_VOXEL_TILE_SIZE,
		"scene_voxel_tile_grid_size": tile_grid_size,
		"scene_voxel_tile_count": scene_voxel_tiles.size(),
		"scene_voxel_tiles": scene_voxel_tiles,
		"scene_voxel_tile_ids": tile_ids,
		"scene_voxel_tile_record_bytes": SceneVoxelTileCodecScript.pack_record_bytes(tile_ids, scene_voxel_tiles, PROJECT_VOXEL_TILE_SIZE),
		"scene_voxel_tile_summary_bytes": SceneVoxelTileCodecScript.pack_summary_bytes(tile_ids, scene_voxel_tiles),
		"scene_voxel_dirty_tile_index_bytes": dirty_index.get("bytes", PackedByteArray()),
		"dirty_scene_voxel_tile_count": 0,
		"dirty_scene_voxel_tiles": {},
		"tile_size": PROJECT_VOXEL_TILE_SIZE.x,
		"tile_grid_size": tile_grid_size,
		"tile_count": scene_voxel_tiles.size(),
		"total_tiles": tile_grid_size.x * tile_grid_size.y * tile_grid_size.z,
		"tiles": scene_voxel_tiles,
		"dirty": false,
		"dirty_tile_count": 0,
		"dirty_tiles": {},
		"tile_summary_gpu_dispatched": false,
		"scene_voxel_tile_summary_source": "target_sv_point_cloud_cpu_summary",
		"legacy_tile_summary_source": "target_sv_point_cloud_cpu_summary",
		"target_scene_voxel_source_record": source_record,
		"source_metadata": _metadata.duplicate(true),
	}
	return _project_voxel_sv


func _make_project_target_sv_source_record(grid_size: Vector3i, voxel_size: Vector3, grid_origin: Vector3) -> Dictionary:
	var record := SceneVoxelSourceRecordScript.prepare_source_record({
		"id": "target_sv_point_cloud",
		"source_id": str(_metadata.get("source_point_cloud", "TargetSV_PT.bgeo.sc")),
		"source_voxel_type": SceneVoxelTargetScript.TARGET_TYPE,
		"target_mix": 1.0,
		"target_pipeline": "guidance",
		"target_guidance_only": bool(_metadata.get("target_guidance_only", true)),
		"height_relative": bool(_metadata.get("height_relative", true)),
		"height_buffer_applied": bool(_metadata.get("height_buffer_applied", false)),
		"collision_buffer_applied": bool(_metadata.get("collision_buffer_applied", false)),
		"voxel_min": Vector3i.ZERO,
		"voxel_max": grid_size,
		"grid_size": grid_size,
		"voxel_size": voxel_size,
		"grid_origin": grid_origin,
	}, 1)
	SceneVoxelTargetScript.prepare_target_record(record, 1)
	return record


func _make_project_scene_voxel_tile_record(tile_coord: Vector3i, grid_size: Vector3i, source_record: Dictionary) -> Dictionary:
	var bounds := SceneVoxelTileCodecScript.tile_bounds(tile_coord, grid_size, PROJECT_VOXEL_TILE_SIZE)
	var tile_id := SceneVoxelTileCodecScript.tile_id(tile_coord)
	return {
		"scene_voxel_tile_id": tile_id,
		"tile_id": tile_id,
		"tile_coord": tile_coord,
		"tile_size": bounds.tile_size,
		"voxel_min": bounds.voxel_min,
		"voxel_max": bounds.voxel_max,
		"base_rect": bounds.base_rect,
		"dirty_flags": SceneVoxelTargetScript.target_dirty_flags(),
		"epoch": 1,
		"last_commit_tick": 1,
		"write_tick": 1,
		"scene_minmax": Vector2.ZERO,
		"collision_minmax": Vector2.ZERO,
		"object_range_start": 0,
		"object_range_count": 0,
		"object_debug_range_start": 0,
		"object_debug_range_count": 1,
		"auto_object_ids_debug": [str(source_record.get("id", "target_sv_point_cloud"))],
		"scene_voxel_count": 0,
		"collision_cell_count": 0,
		"summary": {
			"scene_minmax": Vector2.ZERO,
			"collision_minmax": Vector2.ZERO,
			"scene_voxel_count": 0,
			"collision_cell_count": 0,
		},
		"dirty": false,
		"updated_this_commit": false,
	}


func _accumulate_project_scene_voxel_tile(
	scene_voxel_tiles: Dictionary,
	voxel_coord: Vector3i,
	complexity: float,
	collision_strength: float,
	grid_size: Vector3i,
	source_record: Dictionary
) -> void:
	var tile_coord := SceneVoxelTileCodecScript.tile_coord_from_voxel(voxel_coord, grid_size, PROJECT_VOXEL_TILE_SIZE)
	var tile_id := SceneVoxelTileCodecScript.tile_id(tile_coord)
	var tile: Dictionary = scene_voxel_tiles.get(tile_id, _make_project_scene_voxel_tile_record(tile_coord, grid_size, source_record))
	var scene_count := int(tile.get("scene_voxel_count", 0))
	var scene_minmax: Vector2 = tile.get("scene_minmax", Vector2(complexity, complexity))
	if scene_count <= 0:
		scene_minmax = Vector2(complexity, complexity)
	else:
		scene_minmax = Vector2(minf(scene_minmax.x, complexity), maxf(scene_minmax.y, complexity))
	tile["scene_voxel_count"] = scene_count + 1
	tile["scene_minmax"] = scene_minmax

	if collision_strength > occupancy_threshold:
		var collision_count := int(tile.get("collision_cell_count", 0))
		var collision_minmax: Vector2 = tile.get("collision_minmax", Vector2(collision_strength, collision_strength))
		if collision_count <= 0:
			collision_minmax = Vector2(collision_strength, collision_strength)
		else:
			collision_minmax = Vector2(minf(collision_minmax.x, collision_strength), maxf(collision_minmax.y, collision_strength))
		tile["collision_cell_count"] = collision_count + 1
		tile["collision_minmax"] = collision_minmax

	tile["summary"] = {
		"scene_minmax": tile.get("scene_minmax", Vector2.ZERO),
		"collision_minmax": tile.get("collision_minmax", Vector2.ZERO),
		"scene_voxel_count": int(tile.get("scene_voxel_count", 0)),
		"collision_cell_count": int(tile.get("collision_cell_count", 0)),
	}
	scene_voxel_tiles[tile_id] = tile


func _make_project_terrain_height_field(texture_size: int, height_span: float) -> PackedFloat32Array:
	var field := PackedFloat32Array()
	field.resize(texture_size * texture_size)
	for z in range(texture_size):
		for x in range(texture_size):
			field[z * texture_size + x] = _height_at_pixel(x, z) * height_span
	return field


func _build_project_voxel_boxes() -> void:
	var existing := get_node_or_null(PROJECT_VOXEL_BOX_NODE)
	if existing != null:
		existing.free()
	if _project_voxel_sv.is_empty():
		return
	var scene_voxels: Dictionary = _project_voxel_sv.get("scene_voxels", {})
	if scene_voxels.is_empty():
		return

	var texture_size := int(_project_voxel_sv.get("texture_size", 1))
	var capture_size := float(_project_voxel_sv.get("capture_size", 1.0))
	var vertical_span := float(_project_voxel_sv.get("vertical_span", 1.0))
	var height_span := float(_project_voxel_sv.get("terrain_height_span", _project_voxel_sv.get("max_height", 1.0)))
	var slice_count := int(_project_voxel_sv.get("slice_count", 1))
	var voxel_size: Vector3 = _project_voxel_sv.get("voxel_size", Vector3.ONE)
	var visual_size := Vector3(
		maxf(voxel_size.x * display_scale * project_voxel_box_scale, 0.01),
		maxf(voxel_size.y * display_scale * project_voxel_box_scale, 0.01),
		maxf(voxel_size.z * display_scale * project_voxel_box_scale, 0.01)
	)

	var box := BoxMesh.new()
	box.size = visual_size
	var multi_mesh := MultiMesh.new()
	multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
	multi_mesh.use_colors = true
	multi_mesh.mesh = box
	multi_mesh.instance_count = scene_voxels.size()

	var write_index := 0
	for key in scene_voxels.keys():
		var scene_voxel = scene_voxels[key]
		if not scene_voxel is Dictionary:
			continue
		var voxel := scene_voxel as Dictionary
		var voxel_xz = voxel.get("voxel_xz", Vector2i(-1, -1))
		if not voxel_xz is Vector2i:
			continue
		var px: Vector2i = voxel_xz
		var slice_index := int(voxel.get("slice_index", 0))
		var local_y := (float(slice_index) + 0.5) / maxf(float(slice_count), 1.0) * vertical_span
		var terrain_y := _height_at_pixel(px.x, px.y) * height_span
		var pos := _pixel_to_world(px.x, px.y, texture_size, capture_size, terrain_y + local_y)
		multi_mesh.set_instance_transform(write_index, Transform3D(Basis(), pos))
		var color := _project_voxel_box_color(voxel)
		multi_mesh.set_instance_color(write_index, color)
		write_index += 1

	if write_index < multi_mesh.instance_count:
		multi_mesh.instance_count = write_index
	var instance := MultiMeshInstance3D.new()
	instance.name = PROJECT_VOXEL_BOX_NODE
	instance.multimesh = multi_mesh
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.5
	instance.material_override = mat
	_add_generated_child(instance)


func _project_voxel_box_color(voxel: Dictionary) -> Color:
	var complexity := clampf(float(voxel.get("complexity", 0.0)), 0.0, 1.0)
	var collision_strength := clampf(float(voxel.get("collision", 0.0)), 0.0, 1.0)
	match _project_voxel_box_view:
		BOX_VIEW_COMPLEXITY:
			return Color(complexity, complexity, complexity, clampf(maxf(complexity, 0.55), 0.55, 1.0))
		BOX_VIEW_COLLISION:
			var collision_color := Color(0.12, 0.12, 0.14, 0.55).lerp(Color(1.0, 0.18, 0.02, 1.0), collision_strength)
			collision_color.a = clampf(maxf(collision_strength, 0.22), 0.22, 1.0)
			return collision_color
		_:
			var color: Color = voxel.get("color", Color(0.3, 0.75, 1.0, 1.0))
			color.a = clampf(maxf(complexity, 0.55), 0.55, 1.0)
			return color


func _height_at_pixel(x: int, z: int) -> float:
	if _height_width <= 0 or _height_height <= 0 or _height_luma_bytes.is_empty():
		return 0.0
	var sx := clampi(x, 0, _height_width - 1)
	var sz := clampi(z, 0, _height_height - 1)
	var byte_index := sz * _height_width + sx
	return float(_height_luma_bytes[byte_index]) / 255.0 if byte_index < _height_luma_bytes.size() else 0.0


func _collision_float_values(voxel_count: int) -> PackedFloat32Array:
	var expected_bytes := maxi(voxel_count, 1) * 4
	var available_bytes := mini(_collision_bytes.size(), expected_bytes)
	available_bytes -= available_bytes % 4
	var values := _collision_bytes.slice(0, available_bytes).to_float32_array()
	values.resize(voxel_count)
	return values


func _pixel_to_world(x: int, z: int, texture_size: int, capture_size: float, height: float) -> Vector3:
	var fx := (float(x) / maxf(float(texture_size - 1), 1.0) - 0.5) * capture_size * display_scale
	var fz := (float(z) / maxf(float(texture_size - 1), 1.0) - 0.5) * capture_size * display_scale
	return Vector3(fx, height * display_scale, fz)