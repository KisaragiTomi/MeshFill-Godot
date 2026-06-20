class_name MeshVoxelizerGpu
extends "res://scripts/godot_compute_shader_base.gd"

# GPU solid mesh voxelizer.
#
# Pipeline:
#   1) voxelize_mesh_solid.glsl   -> occupancy (bit0 = solid) + RGBA8 color field
#   2) voxel_collision_erode.glsl -> collision strength field (coarse core only)
#
# Resolution is grid-count driven: the longest mesh AABB axis is split into
# `grid_count` cells, and the cell size is shared across all three axes so voxels
# stay cubic. The other two axes get however many cells fit that span.
#
# voxelize() returns a structured result the caller can render channel by channel:
#   {
#     "ok": bool,
#     "reason": String,             # ok / no-mesh / no-RD / dispatch-failed
#     "grid": Vector3i,             # voxel counts per axis
#     "cell_size": float,           # world-space cubic cell edge
#     "aabb_min": Vector3,          # mesh-local AABB min (voxel grid origin)
#     "voxels": Array[Dictionary],  # one entry per solid voxel
#   }
#
# Each voxel entry:
#   {
#     "voxel": Vector3i,        # grid coordinate
#     "local_center": Vector3,  # mesh-local center of the cell
#     "color": Color,           # RGBA8 color channel (rgb + complexity in alpha)
#     "complexity": float,      # visual strength channel = color.a
#     "collision": float,       # collision channel (0 outside coarse core)
#   }
#
# collision_min_neighbors controls the erosion strictness of the collision pass:
#   6 (default) keeps only fully-enclosed cores (large rock bodies); thin parts
#   such as a 1-voxel trunk are dropped. Lower values keep structures that stay
#   connected along fewer axes, so a thin but vertically continuous trunk earns
#   collision while fully isolated single voxels (drifting leaves) still drop.

const VOXELIZE_SHADER := "res://shaders/voxelize_mesh_solid.glsl"
const COLLISION_SHADER := "res://shaders/voxel_collision_erode.glsl"

const MAX_TRIANGLES := 20000
const MAX_GRID_AXIS := 96

var _voxelize_shader: RID
var _voxelize_pipeline: RID
var _collision_shader: RID
var _collision_pipeline: RID


func voxelize(
	mesh: Mesh,
	grid_count: int,
	asset_color: Color,
	collision_strength: float = 1.0,
	collision_min_neighbors: int = 6
) -> Dictionary:
	log_name = "MeshVoxelizerGpu"
	var empty := {"ok": false, "reason": "no-mesh", "grid": Vector3i.ZERO, "cell_size": 0.0, "aabb_min": Vector3.ZERO, "voxels": []}
	if mesh == null:
		return empty

	var triangles := _collect_triangle_floats(mesh)
	if triangles.is_empty():
		return empty
	var tri_count := triangles.size() / 12

	var aabb := mesh.get_aabb()
	var grid_setup := _resolve_grid(aabb, grid_count)
	var grid: Vector3i = grid_setup["grid"]
	var cell_size: float = grid_setup["cell_size"]
	var aabb_min: Vector3 = grid_setup["aabb_min"]
	if grid.x <= 0 or grid.y <= 0 or grid.z <= 0:
		return empty

	if not ensure_device():
		return {"ok": false, "reason": "no-RD", "grid": grid, "cell_size": cell_size, "aabb_min": aabb_min, "voxels": []}

	var result := _run_gpu(triangles, tri_count, grid, cell_size, aabb_min, asset_color, collision_strength, collision_min_neighbors)
	dispose()
	return result


func _run_gpu(
	triangles: PackedFloat32Array,
	tri_count: int,
	grid: Vector3i,
	cell_size: float,
	aabb_min: Vector3,
	asset_color: Color,
	collision_strength: float,
	collision_min_neighbors: int
) -> Dictionary:
	var fail := {"ok": false, "reason": "dispatch-failed", "grid": grid, "cell_size": cell_size, "aabb_min": aabb_min, "voxels": []}

	_voxelize_shader = load_compute_shader(VOXELIZE_SHADER)
	_voxelize_pipeline = create_compute_pipeline(_voxelize_shader)
	_collision_shader = load_compute_shader(COLLISION_SHADER)
	_collision_pipeline = create_compute_pipeline(_collision_shader)
	if not _voxelize_pipeline.is_valid() or not _collision_pipeline.is_valid():
		return fail

	var voxel_count := grid.x * grid.y * grid.z
	var tri_buf := storage_buffer_from_floats(triangles, SCOPE_FRAME, "triangles")
	var occupancy_buf := storage_buffer_zero(voxel_count * 4, SCOPE_FRAME, "occupancy")
	var color_buf := storage_buffer_zero(voxel_count * 4, SCOPE_FRAME, "color_field")
	var collision_buf := storage_buffer_zero(voxel_count * 4, SCOPE_FRAME, "collision_field")

	var voxelize_set := create_uniform_set([
		make_storage_uniform(0, tri_buf),
		make_storage_uniform(1, occupancy_buf),
		make_storage_uniform(2, color_buf),
	], _voxelize_shader, 0)
	var collision_set := create_uniform_set([
		make_storage_uniform(0, occupancy_buf),
		make_storage_uniform(1, collision_buf),
	], _collision_shader, 0)

	var voxelize_push := _voxelize_push_constant(grid, tri_count, aabb_min, cell_size, asset_color)
	var collision_push := _collision_push_constant(grid, collision_strength, collision_min_neighbors)
	var groups := dispatch_groups_3d(grid.x, grid.y, grid.z, 4, 4, 4)
	var rd := get_rendering_device()

	var cl := begin_compute_list()
	rd.compute_list_bind_compute_pipeline(cl, _voxelize_pipeline)
	rd.compute_list_bind_uniform_set(cl, voxelize_set, 0)
	rd.compute_list_set_push_constant(cl, voxelize_push, voxelize_push.size())
	rd.compute_list_dispatch(cl, groups.x, groups.y, groups.z)
	rd.compute_list_add_barrier(cl)
	rd.compute_list_bind_compute_pipeline(cl, _collision_pipeline)
	rd.compute_list_bind_uniform_set(cl, collision_set, 0)
	rd.compute_list_set_push_constant(cl, collision_push, collision_push.size())
	rd.compute_list_dispatch(cl, groups.x, groups.y, groups.z)
	end_compute_list()

	submit_and_sync()

	var occupancy_bytes := rd.buffer_get_data(occupancy_buf)
	var color_bytes := rd.buffer_get_data(color_buf)
	var collision_bytes := rd.buffer_get_data(collision_buf)
	gc_frame()

	var voxels := _decode_voxels(grid, cell_size, aabb_min, occupancy_bytes, color_bytes, collision_bytes)
	return {"ok": true, "reason": "ok", "grid": grid, "cell_size": cell_size, "aabb_min": aabb_min, "voxels": voxels}


func _decode_voxels(
	grid: Vector3i,
	cell_size: float,
	aabb_min: Vector3,
	occupancy_bytes: PackedByteArray,
	color_bytes: PackedByteArray,
	collision_bytes: PackedByteArray
) -> Array[Dictionary]:
	var voxels: Array[Dictionary] = []
	var occupancy := occupancy_bytes.to_int32_array()
	var color := color_bytes.to_int32_array()
	var collision := collision_bytes.to_float32_array()
	var voxel_count := grid.x * grid.y * grid.z
	if occupancy.size() < voxel_count:
		return voxels

	for y in range(grid.y):
		for z in range(grid.z):
			for x in range(grid.x):
				var index := x + grid.x * (z + grid.z * y)
				if (occupancy[index] & 1) == 0:
					continue
				var packed := int(color[index]) & 0xFFFFFFFF
				var c := _unpack_rgba8(packed)
				voxels.append({
					"voxel": Vector3i(x, y, z),
					"local_center": aabb_min + (Vector3(x, y, z) + Vector3(0.5, 0.5, 0.5)) * cell_size,
					"color": c,
					"complexity": c.a,
					"collision": clampf(collision[index], 0.0, 1.0),
				})
	return voxels


func _resolve_grid(aabb: AABB, grid_count: int) -> Dictionary:
	var size := aabb.size
	var longest := maxf(size.x, maxf(size.y, size.z))
	if longest <= 0.00001:
		return {"grid": Vector3i.ZERO, "cell_size": 0.0, "aabb_min": aabb.position}
	var count := clampi(grid_count, 1, MAX_GRID_AXIS)
	var cell_size := longest / float(count)
	var gx := clampi(ceili(size.x / cell_size), 1, MAX_GRID_AXIS)
	var gy := clampi(ceili(size.y / cell_size), 1, MAX_GRID_AXIS)
	var gz := clampi(ceili(size.z / cell_size), 1, MAX_GRID_AXIS)
	return {"grid": Vector3i(gx, gy, gz), "cell_size": cell_size, "aabb_min": aabb.position}


func _collect_triangle_floats(mesh: Mesh) -> PackedFloat32Array:
	var floats := PackedFloat32Array()
	var tri_count := 0
	for surface_index in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(surface_index)
		if arrays.is_empty() or arrays[Mesh.ARRAY_VERTEX] == null:
			continue
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		if indices.is_empty():
			for i in range(0, verts.size() - 2, 3):
				if tri_count >= MAX_TRIANGLES:
					return floats
				_append_triangle(floats, verts[i], verts[i + 1], verts[i + 2])
				tri_count += 1
		else:
			for i in range(0, indices.size() - 2, 3):
				if tri_count >= MAX_TRIANGLES:
					return floats
				_append_triangle(floats, verts[indices[i]], verts[indices[i + 1]], verts[indices[i + 2]])
				tri_count += 1
	return floats


func _append_triangle(floats: PackedFloat32Array, a: Vector3, b: Vector3, c: Vector3) -> void:
	floats.append_array([a.x, a.y, a.z, 0.0, b.x, b.y, b.z, 0.0, c.x, c.y, c.z, 0.0])


func _voxelize_push_constant(grid: Vector3i, tri_count: int, aabb_min: Vector3, cell_size: float, asset_color: Color) -> PackedByteArray:
	var ints := PackedInt32Array([grid.x, grid.y, grid.z, tri_count])
	var floats := PackedFloat32Array([
		aabb_min.x, aabb_min.y, aabb_min.z, cell_size,
		asset_color.r, asset_color.g, asset_color.b, asset_color.a,
	])
	var bytes := ints.to_byte_array()
	bytes.append_array(floats.to_byte_array())
	return bytes


func _collision_push_constant(grid: Vector3i, collision_strength: float, min_neighbors: int) -> PackedByteArray:
	var ints := PackedInt32Array([grid.x, grid.y, grid.z, clampi(min_neighbors, 1, 6)])
	var floats := PackedFloat32Array([clampf(collision_strength, 0.0, 1.0), 0.0, 0.0, 0.0])
	var bytes := ints.to_byte_array()
	bytes.append_array(floats.to_byte_array())
	return bytes


func _unpack_rgba8(packed: int) -> Color:
	var r := float(packed & 0xFF) / 255.0
	var g := float((packed >> 8) & 0xFF) / 255.0
	var b := float((packed >> 16) & 0xFF) / 255.0
	var a := float((packed >> 24) & 0xFF) / 255.0
	return Color(r, g, b, a)