class_name MeshDataAsset
extends Resource

# Legacy compatibility resource. New rock assets should be saved as
# AutoRock/AutoCliffRock scene prototypes.

@export var mesh: Mesh
@export var source_mesh: Mesh
@export var source_mesh_path: String = ""
@export var mesh_height_texture: Texture2D
@export var mesh_size: float = 1.0
@export var voxel_profile: AutoVoxelProfile
@export var voxel_color: Color = Color(0.55, 0.50, 0.45, 1.0)
@export_range(0.0, 1.0) var voxel_complexity: float = 1.0
@export var affected_bands: Array[Dictionary] = []
@export var collision_voxels: Array[Dictionary] = []
@export var random_rotate: Vector2 = Vector2(0.0, 0.0)
@export var random_scale: Vector2 = Vector2(1.0, 1.0)
@export var random_height_offset: Vector2 = Vector2(0.0, 0.0)


func get_voxel_color() -> Color:
	if _should_read_profile_average():
		return voxel_profile.get_color()
	var result := voxel_color
	result.a = get_voxel_complexity()
	return result


func get_voxel_complexity() -> float:
	if _should_read_profile_average():
		return voxel_profile.get_complexity()
	return clampf(voxel_complexity, 0.0, 1.0)


func get_affected_bands(default_radius: float) -> Array[Dictionary]:
	if not affected_bands.is_empty():
		return AutoVoxelProfile.normalize_affected_bands(affected_bands, default_radius, get_voxel_color(), get_voxel_complexity())
	if voxel_profile != null:
		var bands := voxel_profile.get_affected_bands(default_radius)
		if not bands.is_empty():
			return bands
	return AutoVoxelProfile.make_all_band_entries(get_voxel_color(), get_voxel_complexity(), default_radius)


func get_collision_voxels(default_radius: float = 0.0) -> Array[Dictionary]:
	if not collision_voxels.is_empty():
		return AutoVoxelProfile.normalize_collision_voxels(collision_voxels, default_radius)
	if voxel_profile != null:
		return voxel_profile.get_collision_voxels(default_radius)
	return []


func get_source_mesh() -> Mesh:
	if not source_mesh_path.is_empty() and (source_mesh == null or source_mesh == mesh):
		var loaded_source_mesh := AutoAssetFactory.load_source_mesh(source_mesh_path)
		if loaded_source_mesh != null:
			source_mesh = loaded_source_mesh
			return source_mesh
	if source_mesh != null:
		return source_mesh
	return mesh


func _should_read_profile_average() -> bool:
	return (
		voxel_profile != null
		and voxel_color == Color(0.55, 0.50, 0.45, 1.0)
		and is_equal_approx(voxel_complexity, 1.0)
	)
