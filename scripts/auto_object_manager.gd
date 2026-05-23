class_name AutoObjectManager
extends Node

@export var spatial_cell_size: float = 8.0

var records_by_id: Dictionary = {}
var records_by_instance_id: Dictionary = {}
var objects_by_instance_id: Dictionary = {}
var spatial_cells: Dictionary = {}
var spatial_cells_by_instance_id: Dictionary = {}
var spatial_radius_by_instance_id: Dictionary = {}


func register_object(auto_object: AutoObject, record: Dictionary = {}) -> Dictionary:
	if auto_object == null:
		return {}

	var rec := record.duplicate(true)
	var instance_id := auto_object.refresh_instance_id()
	if auto_object.auto_id.is_empty():
		auto_object.auto_id = auto_object.name
	auto_object.refresh_bound_spacing()

	rec["id"] = str(rec.get("id", auto_object.auto_id))
	rec["instance_id"] = instance_id
	rec["auto_id"] = auto_object.auto_id
	rec["auto_object_id"] = auto_object.auto_id
	rec["auto_instance_id"] = instance_id
	rec["instance_mesh_id"] = int(rec.get("instance_mesh_id", rec.get("mesh_instance_id", instance_id)))
	rec["mesh_instance_id"] = int(rec.instance_mesh_id)
	rec["auto_source"] = str(rec.get("auto_source", auto_object.auto_source))
	rec["object_type"] = str(rec.get("object_type", auto_object.object_type))
	rec["object_subtype"] = str(rec.get("object_subtype", auto_object.object_subtype))
	rec["bound_min_length"] = float(rec.get("bound_min_length", auto_object.bound_min_length))
	rec["min_spacing"] = float(rec.get("min_spacing", auto_object.min_spacing))
	rec["min_spacing_auto"] = bool(rec.get("min_spacing_auto", auto_object.min_spacing_auto))
	if auto_object.is_inside_tree():
		rec["node_path"] = str(auto_object.get_path())

	records_by_id[rec.id] = rec
	records_by_instance_id[instance_id] = rec
	objects_by_instance_id[instance_id] = auto_object
	_index_object(auto_object, rec)
	auto_object.set_meta("auto_manager_registered", true)
	return rec.duplicate(true)


func unregister_object(auto_object: AutoObject) -> void:
	if auto_object == null:
		return
	var instance_id := auto_object.refresh_instance_id()
	_unindex_instance(instance_id)
	records_by_instance_id.erase(instance_id)
	objects_by_instance_id.erase(instance_id)
	if not auto_object.auto_id.is_empty():
		records_by_id.erase(auto_object.auto_id)
	var meta_record := _get_asset_voxel_record_meta(auto_object)
	if not meta_record.is_empty():
		records_by_id.erase(str(meta_record.get("id", "")))
	auto_object.set_meta("auto_manager_registered", false)


func configure_spatial_index(cell_size: float) -> void:
	spatial_cell_size = maxf(cell_size, 0.001)
	rebuild_spatial_index()


func rebuild_spatial_index() -> void:
	spatial_cells.clear()
	spatial_cells_by_instance_id.clear()
	spatial_radius_by_instance_id.clear()
	for instance_id in objects_by_instance_id.keys():
		var raw_object = objects_by_instance_id[instance_id]
		if not is_instance_valid(raw_object) or not raw_object is AutoObject:
			continue
		var auto_object := raw_object as AutoObject
		var record := get_record_by_instance_id(int(instance_id))
		_index_object(auto_object, record)


func reindex_object(auto_object: AutoObject) -> void:
	if auto_object == null:
		return
	var instance_id := auto_object.refresh_instance_id()
	var record := get_record_by_instance_id(instance_id)
	if record.is_empty():
		record = _get_asset_voxel_record_meta(auto_object)
	_unindex_instance(instance_id)
	objects_by_instance_id[instance_id] = auto_object
	_index_object(auto_object, record)


func _get_asset_voxel_record_meta(auto_object: AutoObject) -> Dictionary:
	for key in AutoObject.asset_voxel_record_meta_keys():
		if not auto_object.has_meta(key):
			continue
		var raw_record = auto_object.get_meta(key)
		if raw_record is Dictionary:
			return (raw_record as Dictionary).duplicate(true)
	return {}


func world_to_cell(world_pos: Vector3) -> Vector3i:
	var size := maxf(spatial_cell_size, 0.001)
	return Vector3i(floori(world_pos.x / size), _spatial_y_layer(world_pos.y), floori(world_pos.z / size))


func get_objects_in_cell(cell) -> Array[AutoObject]:
	var result: Array[AutoObject] = []
	var cell_key := _normalize_spatial_cell(cell)
	var ids: Array = spatial_cells.get(cell_key, [])
	for raw_id in ids:
		var instance_id := int(raw_id)
		var raw_object = objects_by_instance_id.get(instance_id, null)
		if is_instance_valid(raw_object) and raw_object is AutoObject:
			result.append(raw_object as AutoObject)
	return result


func get_objects_in_world_cell(world_pos: Vector3) -> Array[AutoObject]:
	return get_objects_in_cell(world_to_cell(world_pos))


func query_objects_in_radius(center: Vector3, radius: float, include_overlap: bool = true) -> Array[AutoObject]:
	var query_radius := maxf(radius, 0.0)
	var min_cell := world_to_cell(center - Vector3(query_radius, 0.0, query_radius))
	var max_cell := world_to_cell(center + Vector3(query_radius, 0.0, query_radius))
	var seen: Dictionary = {}
	var result: Array[AutoObject] = []
	var center_xz := Vector2(center.x, center.z)

	for y in range(min_cell.y, max_cell.y + 1):
		for z in range(min_cell.z, max_cell.z + 1):
			for x in range(min_cell.x, max_cell.x + 1):
				var cell := Vector3i(x, y, z)
				var ids: Array = spatial_cells.get(cell, [])
				for raw_id in ids:
					var instance_id := int(raw_id)
					if seen.has(instance_id):
						continue
					seen[instance_id] = true
					var raw_object = objects_by_instance_id.get(instance_id, null)
					if not is_instance_valid(raw_object) or not raw_object is AutoObject:
						continue
					var auto_object := raw_object as AutoObject
					var object_radius := float(spatial_radius_by_instance_id.get(instance_id, 0.0)) if include_overlap else 0.0
					var object_pos := _object_index_position(auto_object)
					var object_xz := Vector2(object_pos.x, object_pos.z)
					if object_xz.distance_to(center_xz) <= query_radius + object_radius:
						result.append(auto_object)
	return result


func query_records_in_radius(center: Vector3, radius: float, include_overlap: bool = true) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	for auto_object in query_objects_in_radius(center, radius, include_overlap):
		var record := get_record_by_instance_id(auto_object.refresh_instance_id())
		if not record.is_empty():
			records.append(record)
	return records


func query_same_type_objects(
	center: Vector3,
	radius: float,
	object_type: String = "",
	object_subtype: String = "",
	include_overlap: bool = true
) -> Array[AutoObject]:
	var result: Array[AutoObject] = []
	for auto_object in query_objects_in_radius(center, radius, include_overlap):
		var record := get_record_by_instance_id(auto_object.refresh_instance_id())
		if _matches_object_type(auto_object, record, object_type, object_subtype):
			result.append(auto_object)
	return result


func find_same_type_exclusion(
	candidate_position: Vector3,
	object_type: String = "",
	object_subtype: String = "",
	candidate_min_spacing: float = 0.0,
	search_radius: float = -1.0
) -> Dictionary:
	var candidate_spacing := maxf(candidate_min_spacing, 0.0)
	var radius := search_radius
	if radius < 0.0:
		radius = maxf(candidate_spacing + spatial_cell_size, spatial_cell_size)
	var center_xz := Vector2(candidate_position.x, candidate_position.z)
	for auto_object in query_same_type_objects(candidate_position, radius, object_type, object_subtype, true):
		var instance_id := auto_object.refresh_instance_id()
		var record := get_record_by_instance_id(instance_id)
		var object_pos := _object_index_position(auto_object)
		var object_xz := Vector2(object_pos.x, object_pos.z)
		var neighbor_spacing := _object_spacing(auto_object, record)
		var required_distance := candidate_spacing + neighbor_spacing
		if required_distance <= 0.0:
			continue
		var distance := center_xz.distance_to(object_xz)
		if distance < required_distance:
			return {
				"blocked": true,
				"neighbor": auto_object,
				"neighbor_instance_id": instance_id,
				"neighbor_id": str(record.get("id", auto_object.auto_id)),
				"distance": distance,
				"required_distance": required_distance,
				"candidate_min_spacing": candidate_spacing,
				"neighbor_min_spacing": neighbor_spacing,
				"object_type": object_type,
				"object_subtype": object_subtype,
			}
	return {"blocked": false}


func can_place_same_type(
	candidate_position: Vector3,
	object_type: String = "",
	object_subtype: String = "",
	candidate_min_spacing: float = 0.0,
	search_radius: float = -1.0
) -> bool:
	return not bool(find_same_type_exclusion(
		candidate_position,
		object_type,
		object_subtype,
		candidate_min_spacing,
		search_radius
	).get("blocked", false))


func get_spatial_stats() -> Dictionary:
	return {
		"cell_size": spatial_cell_size,
		"cell_key_type": "Vector3i",
		"cell_count": spatial_cells.size(),
		"object_count": objects_by_instance_id.size(),
		"y_layer_count": 1,
	}


func get_record_by_id(record_id: String) -> Dictionary:
	var record = records_by_id.get(record_id, {})
	if record is Dictionary:
		return (record as Dictionary).duplicate(true)
	return {}


func get_record_by_instance_id(instance_id: int) -> Dictionary:
	var record = records_by_instance_id.get(instance_id, {})
	if record is Dictionary:
		return (record as Dictionary).duplicate(true)
	return {}


func get_all_records() -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	for key in records_by_id.keys():
		var record = records_by_id[key]
		if record is Dictionary:
			records.append((record as Dictionary).duplicate(true))
	return records


func _index_object(auto_object: AutoObject, record: Dictionary = {}) -> void:
	if auto_object == null:
		return
	var instance_id := auto_object.refresh_instance_id()
	_unindex_instance(instance_id)
	var radius := _object_index_radius(auto_object, record)
	var center := _object_index_position(auto_object)
	var min_cell := world_to_cell(center - Vector3(radius, 0.0, radius))
	var max_cell := world_to_cell(center + Vector3(radius, 0.0, radius))
	var occupied_cells: Array[Vector3i] = []
	for y in range(min_cell.y, max_cell.y + 1):
		for z in range(min_cell.z, max_cell.z + 1):
			for x in range(min_cell.x, max_cell.x + 1):
				var cell := Vector3i(x, y, z)
				if not spatial_cells.has(cell):
					spatial_cells[cell] = []
				var ids: Array = spatial_cells[cell]
				if ids.find(instance_id) < 0:
					ids.append(instance_id)
				occupied_cells.append(cell)
	spatial_cells_by_instance_id[instance_id] = occupied_cells
	spatial_radius_by_instance_id[instance_id] = radius


func _unindex_instance(instance_id: int) -> void:
	var cells: Array = spatial_cells_by_instance_id.get(instance_id, [])
	for raw_cell in cells:
		var cell := _normalize_spatial_cell(raw_cell)
		if not spatial_cells.has(cell):
			continue
		var ids: Array = spatial_cells[cell]
		ids.erase(instance_id)
		if ids.is_empty():
			spatial_cells.erase(cell)
	spatial_cells_by_instance_id.erase(instance_id)
	spatial_radius_by_instance_id.erase(instance_id)


func _spatial_y_layer(_world_y: float) -> int:
	return 0


func _normalize_spatial_cell(cell) -> Vector3i:
	if cell is Vector3i:
		return cell as Vector3i
	if cell is Vector2i:
		var cell_xz := cell as Vector2i
		return Vector3i(cell_xz.x, 0, cell_xz.y)
	return Vector3i.ZERO


func _object_index_position(auto_object: AutoObject) -> Vector3:
	if auto_object.is_inside_tree():
		return auto_object.global_position
	return auto_object.position


func _matches_object_type(
	auto_object: AutoObject,
	record: Dictionary,
	object_type: String,
	object_subtype: String
) -> bool:
	var expected_subtype := object_subtype.strip_edges().to_lower()
	var expected_type := object_type.strip_edges().to_lower()
	if expected_subtype.is_empty() and expected_type.is_empty():
		return false

	var actual_subtype := str(record.get("object_subtype", auto_object.object_subtype)).strip_edges().to_lower()
	var actual_type := str(record.get("object_type", auto_object.object_type)).strip_edges().to_lower()
	if not expected_subtype.is_empty():
		return actual_subtype == expected_subtype
	return actual_type == expected_type


func _object_spacing(auto_object: AutoObject, record: Dictionary = {}) -> float:
	return maxf(float(record.get("min_spacing", auto_object.min_spacing)), auto_object.min_spacing)


func _object_index_radius(auto_object: AutoObject, record: Dictionary = {}) -> float:
	var radius := _object_spacing(auto_object, record)
	radius = maxf(radius, _mesh_xz_radius(auto_object))
	radius = maxf(radius, _collision_xz_radius(record))
	return maxf(radius, spatial_cell_size * 0.05)


func _mesh_xz_radius(auto_object: AutoObject) -> float:
	if auto_object.mesh == null:
		return 0.0
	var aabb := auto_object.mesh.get_aabb()
	var sx := absf(aabb.size.x * auto_object.scale.x) * 0.5
	var sz := absf(aabb.size.z * auto_object.scale.z) * 0.5
	var offset_x := absf((aabb.position.x + aabb.size.x * 0.5) * auto_object.scale.x)
	var offset_z := absf((aabb.position.z + aabb.size.z * 0.5) * auto_object.scale.z)
	return Vector2(sx + offset_x, sz + offset_z).length()


func _collision_xz_radius(record: Dictionary) -> float:
	var result := 0.0
	var collisions: Array = record.get("collision_voxels", [])
	for raw_collision in collisions:
		if not raw_collision is Dictionary:
			continue
		var collision := raw_collision as Dictionary
		var radius := maxf(float(collision.get("radius", 0.0)), 0.0)
		var dilation := maxf(float(collision.get("dilation_radius", 0.0)), 0.0)
		var offset := _vector3_from_value(collision.get("offset", collision.get("center", collision.get("position", Vector3.ZERO))), Vector3.ZERO)
		result = maxf(result, Vector2(offset.x, offset.z).length() + radius + dilation)
	return result


func _vector3_from_value(value, fallback: Vector3) -> Vector3:
	if value is Vector3:
		return value as Vector3
	if value is Array:
		var arr := value as Array
		if arr.size() >= 3:
			return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
	if value is Dictionary:
		var dict := value as Dictionary
		return Vector3(
			float(dict.get("x", fallback.x)),
			float(dict.get("y", fallback.y)),
			float(dict.get("z", fallback.z))
		)
	return fallback
