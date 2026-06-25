class_name VoxelDisplay
extends RefCounted

const VoxelFieldDisplayGPUScript := preload("res://scripts/voxel_field_display_gpu.gd")
const BrushVoxelDisplayGPUScript := preload("res://scripts/brush_voxel_display_gpu.gd")

# Unified voxel-grid visualization helper.
#
# Every voxel display in the project reduces to the same shape: a set of cell
# centers, one cubic cell size, and per-cell (or uniform) color, rendered as a
# single MultiMesh of boxes. This script is the single authority for that, so
# collision previews, occupancy buffers, and any future voxel debug all look
# identical and share one tuning surface.

# Fraction of a full cell the rendered box occupies. < 1.0 leaves a gap between
# cells so the grid reads as discrete voxels rather than a solid block.
const DEFAULT_FILL := 0.9


# Per-voxel color box MultiMesh. colors.size() must match centers.
static func build_colored(
	centers: PackedVector3Array,
	cell_size: Vector3,
	colors: PackedColorArray,
	options: Dictionary = {}
) -> MultiMeshInstance3D:
	return _build_internal(centers, cell_size, Color.WHITE, colors, options)


# Per-instance transform MultiMesh. transforms must be Array[Transform3D],
# colors.size() must match transforms. Uses a unit BoxMesh; scale/rotation
# come from the per-instance transforms. Set options.unshaded=true for
# flat debug overlays, options.no_depth_test=true to skip depth writes.
static func build_from_transforms(
	transforms: Array,  # Array[Transform3D]
	colors: PackedColorArray,
	options: Dictionary = {}
) -> MultiMeshInstance3D:
	if transforms.is_empty():
		return null
	var count := transforms.size()
	var use_colors := colors.size() == count

	var box := BoxMesh.new()
	box.size = Vector3.ONE
	_apply_voxel_material(box, use_colors, Color.WHITE, options)

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = use_colors
	mm.mesh = box
	mm.instance_count = count
	for i in range(count):
		mm.set_instance_transform(i, transforms[i])
		if use_colors:
			mm.set_instance_color(i, colors[i])

	var node := MultiMeshInstance3D.new()
	node.name = str(options.get("name", "VoxelDisplay"))
	node.multimesh = mm
	return node


static func _build_internal(
	centers: PackedVector3Array,
	cell_size: Vector3,
	uniform_color: Color,
	colors: PackedColorArray,
	options: Dictionary
) -> MultiMeshInstance3D:
	if centers.is_empty():
		return null

	var fill := float(options.get("fill", DEFAULT_FILL))
	var use_colors := colors.size() == centers.size()

	var cell := BoxMesh.new()
	cell.size = cell_size * fill
	_apply_voxel_material(cell, use_colors, uniform_color, options)

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = use_colors
	mm.mesh = cell
	mm.instance_count = centers.size()
	for i in range(centers.size()):
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, centers[i]))
		if use_colors:
			mm.set_instance_color(i, colors[i])

	var node := MultiMeshInstance3D.new()
	node.name = str(options.get("name", "VoxelDisplay"))
	node.multimesh = mm
	return node


# --- All-GPU field renderer ------------------------------------------------
# Render a full voxel field with zero GPU->CPU readback. A box MultiMesh is
# allocated with one instance per grid cell; a VoxelFieldDisplayGPU writer fills
# the instance transforms + colors directly in the MultiMesh buffer on the main
# RenderingDevice. Empty cells collapse to a zero basis on the GPU. The custom
# AABB is derived from the known grid bounds, so nothing reads back from the GPU
# to make the MultiMesh visible.
#
# fields / params are forwarded to VoxelFieldDisplayGPU.write_field(); world_aabb
# is the precomputed local-space bounds of the voxel grid. The writer is parented
# to the returned node (kept alive with it). Returns null when the field cannot
# be driven on the GPU.
static func build_field_gpu(
	voxel_count: int,
	cell_size: Vector3,
	world_aabb: AABB,
	fields: Dictionary,
	params: Dictionary,
	options: Dictionary = {}
) -> MultiMeshInstance3D:
	if voxel_count <= 0:
		return null

	var fill := float(options.get("fill", DEFAULT_FILL))
	var cell := BoxMesh.new()
	cell.size = cell_size * fill
	_apply_voxel_material(cell, true, Color.WHITE, options)

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = cell
	mm.instance_count = voxel_count

	var node := MultiMeshInstance3D.new()
	node.name = str(options.get("name", "VoxelDisplay"))
	node.multimesh = mm
	node.custom_aabb = world_aabb

	var writer = VoxelFieldDisplayGPUScript.new()
	if not writer.is_ready():
		push_warning("VoxelDisplay.build_field_gpu skipped: %s" % writer.last_reason())
		writer.dispose()
		node.free()
		return null
	if not writer.bind_multimesh(mm.get_rid(), voxel_count):
		push_warning("VoxelDisplay.build_field_gpu skipped: %s" % writer.last_reason())
		writer.dispose()
		node.free()
		return null
	if not writer.write_field(fields, params):
		push_error("VoxelDisplay.build_field_gpu: %s" % writer.last_reason())
		writer.dispose()
		node.free()
		return null

	# Free the writer's GPU resources while the node (and writer) are still alive,
	# on the render thread during a normal frame. Deferring this to the writer's
	# PREDELETE would bind a half-destructed object and leak.
	node.tree_exiting.connect(writer.dispose)

	# Keep the writer (and its GPU resources) alive for the node's lifetime.
	node.set_meta("voxel_field_writer", writer)
	return node


# --- All-GPU brush tetra renderer ------------------------------------------
# Render a sparse list of painted brush voxels as tetrahedra with zero GPU->CPU
# readback. A tetra MultiMesh is allocated with one instance per painted voxel;
# a BrushVoxelDisplayGPU writer fills the instance transforms + colors directly
# in the MultiMesh buffer on the main RenderingDevice. The custom AABB is derived
# from the known grid bounds so nothing reads back to make the MultiMesh visible.
#
# brush_voxels is laid out as (voxel_x, slice, voxel_z, 0) per voxel; params are
# forwarded to BrushVoxelDisplayGPU.write_brush(). world_aabb is the precomputed
# local-space grid bounds. The writer is parented to the returned node (kept
# alive with it). Returns null when the brush cannot be driven on the GPU.
static func build_brush_tetra_gpu(
	brush_voxels: PackedInt32Array,
	cell_size: Vector3,
	world_aabb: AABB,
	params: Dictionary,
	options: Dictionary = {}
) -> MultiMeshInstance3D:
	var instance_count := brush_voxels.size() / 4
	if instance_count <= 0:
		return null

	var fill := float(options.get("fill", DEFAULT_FILL))
	var mesh := _make_tetra_mesh(cell_size, fill)
	_apply_voxel_material(mesh, true, Color.WHITE, options)

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = instance_count

	var node := MultiMeshInstance3D.new()
	node.name = str(options.get("name", "VoxelDisplay"))
	node.multimesh = mm
	node.custom_aabb = world_aabb

	var writer = BrushVoxelDisplayGPUScript.new()
	if not writer.is_ready():
		push_warning("VoxelDisplay.build_brush_tetra_gpu skipped: %s" % writer.last_reason())
		writer.dispose()
		node.free()
		return null
	if not writer.bind_multimesh(mm.get_rid(), instance_count):
		push_warning("VoxelDisplay.build_brush_tetra_gpu skipped: %s" % writer.last_reason())
		writer.dispose()
		node.free()
		return null
	if not writer.write_brush(brush_voxels, params):
		push_error("VoxelDisplay.build_brush_tetra_gpu: %s" % writer.last_reason())
		writer.dispose()
		node.free()
		return null

	node.tree_exiting.connect(writer.dispose)
	node.set_meta("voxel_brush_writer", writer)
	return node


# Shared material setup for box and tetra voxel meshes.
static func _apply_voxel_material(
	mesh: Mesh,
	use_colors: bool,
	uniform_color: Color,
	options: Dictionary
) -> void:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if bool(options.get("unshaded", false)):
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	else:
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	if bool(options.get("no_depth_test", false)):
		mat.no_depth_test = true
	if use_colors:
		mat.vertex_color_use_as_albedo = true
	else:
		mat.albedo_color = uniform_color
	if mesh is ArrayMesh:
		mesh.surface_set_material(0, mat)
	else:
		mesh.set("material", mat)


# Build a single regular-ish tetrahedron centered on the cell origin, inset by
# fill. Orientation is fixed; brush voxels do not carry orientation meaning.
static func _make_tetra_mesh(cell_size: Vector3, fill: float) -> ArrayMesh:
	var h := cell_size * fill * 0.5
	var verts := PackedVector3Array([
		Vector3(0.0, h.y, 0.0),
		Vector3(-h.x, -h.y, h.z),
		Vector3(h.x, -h.y, h.z),
		Vector3(0.0, -h.y, -h.z),
	])
	var faces := [
		[0, 1, 2],
		[0, 2, 3],
		[0, 3, 1],
		[1, 3, 2],
	]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for face in faces:
		var a: Vector3 = verts[face[0]]
		var b: Vector3 = verts[face[1]]
		var c: Vector3 = verts[face[2]]
		var normal := (b - a).cross(c - a).normalized()
		for v in [a, b, c]:
			st.set_normal(normal)
			st.add_vertex(v)
	return st.commit()


# --- All-GPU brush tetra renderer ------------------------------------------
