@tool
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
const SceneVoxelTileCodecScript := preload("res://scripts/scene_voxel_tile_codec.gd")
const BufferUtils := preload("res://scripts/utils/buffer_utils.gd")

const MAX_TRIANGLES := 20000
const MAX_GRID_AXIS := 96

# push_constant 布局（std430；字节序与原 _voxelize_push_constant / _collision_push_constant 完全一致：
# 4×int 后接 float，即 BufferUtils.pack_push_ints_floats 的拼接顺序）。
const VOXELIZE_PUSH := [
	["grid_x", "int"], ["grid_y", "int"], ["grid_z", "int"], ["tri_count", "int"],
	["aabb_min_x", "float"], ["aabb_min_y", "float"], ["aabb_min_z", "float"], ["cell_size", "float"],
	["color_r", "float"], ["color_g", "float"], ["color_b", "float"], ["color_a", "float"],
]
const COLLISION_PUSH := [
	["grid_x", "int"], ["grid_y", "int"], ["grid_z", "int"], ["min_neighbors", "int"],
	["strength", "float"], ["_pad0", "float"], ["_pad1", "float"], ["_pad2", "float"],
]


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

	var result := _run_gpu(triangles, tri_count, grid, cell_size, aabb_min, aabb.size, asset_color, collision_strength, collision_min_neighbors)
	dispose()
	return result


func _run_gpu(
	triangles: PackedFloat32Array,
	tri_count: int,
	grid: Vector3i,
	cell_size: float,
	aabb_min: Vector3,
	aabb_size: Vector3,
	asset_color: Color,
	collision_strength: float,
	collision_min_neighbors: int
) -> Dictionary:
	var fail := {"ok": false, "reason": "dispatch-failed", "grid": grid, "cell_size": cell_size, "aabb_min": aabb_min, "voxels": []}

	var voxelize_kernel := ComputeKernel.create(self, VOXELIZE_SHADER, VOXELIZE_PUSH, "voxelize_mesh_solid")
	var collision_kernel := ComputeKernel.create(self, COLLISION_SHADER, COLLISION_PUSH, "voxel_collision_erode")
	if not voxelize_kernel.is_valid() or not collision_kernel.is_valid():
		return fail

	var voxel_count := VoxelGeneral.voxel_count(grid)
	var tri_buf := storage_buffer_from_floats(triangles, SCOPE_FRAME, "triangles")
	var occupancy_buf := storage_buffer_zero(voxel_count * 4, SCOPE_FRAME, "occupancy")
	var color_buf := storage_buffer_zero(voxel_count * 4, SCOPE_FRAME, "color_field")
	var collision_buf := storage_buffer_zero(SceneVoxelTileCodecScript.u32_field_byte_count(voxel_count), SCOPE_FRAME, "collision_field_u32")

	var groups := dispatch_groups_3d(grid.x, grid.y, grid.z, 4, 4, 4)
	var chain_ok := ComputePassChain.run(self, [
		voxelize_kernel.make_pass([tri_buf, occupancy_buf, color_buf], {
			grid_x = grid.x, grid_y = grid.y, grid_z = grid.z, tri_count = tri_count,
			aabb_min_x = aabb_min.x, aabb_min_y = aabb_min.y, aabb_min_z = aabb_min.z, cell_size = cell_size,
			color_r = asset_color.r, color_g = asset_color.g, color_b = asset_color.b, color_a = asset_color.a,
		}, groups),
		collision_kernel.make_pass([occupancy_buf, collision_buf], {
			grid_x = grid.x, grid_y = grid.y, grid_z = grid.z, min_neighbors = clampi(collision_min_neighbors, 1, 6),
			strength = clampf(collision_strength, 0.0, 1.0),
		}, groups),
	])
	if not chain_ok:
		return fail

	var rd := get_rendering_device()
	var occupancy_bytes := rd.buffer_get_data(occupancy_buf)
	var color_bytes := rd.buffer_get_data(color_buf)
	var collision_bytes := rd.buffer_get_data(collision_buf)
	gc_frame()

	var voxels := _decode_voxels(grid, cell_size, aabb_min, occupancy_bytes, color_bytes, collision_bytes)
	return {
		"ok": true,
		"reason": "ok",
		"grid": grid,
		"cell_size": cell_size,
		"aabb_min": aabb_min,
		"aabb_size": aabb_size,
		"voxels": voxels,
	}


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
	var voxel_count := VoxelGeneral.voxel_count(grid)
	var collision := SceneVoxelTileCodecScript.decode_collision_field_u32_bytes(collision_bytes, voxel_count)
	if occupancy.size() < voxel_count:
		return voxels

	for y in range(grid.y):
		for z in range(grid.z):
			for x in range(grid.x):
				var index := VoxelGeneral.voxel_index(Vector3i(x, y, z), grid)
				if (occupancy[index] & 1) == 0:
					continue
				var packed := int(color[index]) & 0xFFFFFFFF
				var c := BufferUtils.semantic_rgba8_word_to_color(packed)
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
	var longest := VoxelGeneral.aabb_longest_axis(aabb)
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
				floats.append_array([verts[i].x, verts[i].y, verts[i].z, 0.0, verts[i + 1].x, verts[i + 1].y, verts[i + 1].z, 0.0, verts[i + 2].x, verts[i + 2].y, verts[i + 2].z, 0.0])
				tri_count += 1
		else:
			for i in range(0, indices.size() - 2, 3):
				if tri_count >= MAX_TRIANGLES:
					return floats
				floats.append_array([verts[indices[i]].x, verts[indices[i]].y, verts[indices[i]].z, 0.0, verts[indices[i + 1]].x, verts[indices[i + 1]].y, verts[indices[i + 1]].z, 0.0, verts[indices[i + 2]].x, verts[indices[i + 2]].y, verts[indices[i + 2]].z, 0.0])
				tri_count += 1
	return floats
