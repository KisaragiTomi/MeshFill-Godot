class_name AutoObjectManager
extends Node

var records_by_id: Dictionary = {}
var records_by_instance_id: Dictionary = {}


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
	auto_object.set_meta("auto_manager_registered", true)
	return rec.duplicate(true)


func unregister_object(auto_object: AutoObject) -> void:
	if auto_object == null:
		return
	var instance_id := auto_object.refresh_instance_id()
	records_by_instance_id.erase(instance_id)
	if not auto_object.auto_id.is_empty():
		records_by_id.erase(auto_object.auto_id)
	if auto_object.has_meta("voxel_record"):
		var raw_record = auto_object.get_meta("voxel_record")
		if raw_record is Dictionary:
			var record := raw_record as Dictionary
			records_by_id.erase(str(record.get("id", "")))
	auto_object.set_meta("auto_manager_registered", false)


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
