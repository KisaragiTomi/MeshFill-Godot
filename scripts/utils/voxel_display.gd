class_name VoxelDisplay
extends RefCounted

const VoxelFieldDisplayGPUScript := preload("res://scripts/utils/voxel_field_display_gpu.gd")
const BrushVoxelDisplayGPUScript := preload("res://scripts/utils/brush_voxel_display_gpu.gd")
const VoxelInstanceDisplayGPUScript := preload("res://scripts/utils/voxel_instance_display_gpu.gd")

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
	if centers.is_empty():
		return null
	var fill := float(options.get("fill", DEFAULT_FILL))
	var cell := BoxMesh.new()
	cell.size = cell_size * fill
	return _build_gpu_instances(
		cell,
		_pack_center_transforms(centers),
		_pack_colors(colors, centers.size()),
		_aabb_for_centers(centers, cell.size),
		options
	)


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

	var box := BoxMesh.new()
	box.size = Vector3.ONE

	return _build_gpu_instances(
		box,
		_pack_transforms(transforms),
		_pack_colors(colors, transforms.size()),
		_aabb_for_transforms(transforms),
		options
	)


static func _build_gpu_instances(
	mesh: Mesh,
	transform_floats: PackedFloat32Array,
	color_floats: PackedFloat32Array,
	world_aabb: AABB,
	options: Dictionary
) -> MultiMeshInstance3D:
	var count := int(transform_floats.size() / VoxelInstanceDisplayGPUScript.TRANSFORM_FLOATS)
	if count <= 0:
		return null
	_apply_voxel_material(mesh, true, Color.WHITE, options)
	var writer = VoxelInstanceDisplayGPUScript.new()
	return _build_writer_node(
		mesh,
		count,
		world_aabb,
		options,
		writer,
		writer.write_instances.bind(transform_floats, color_floats),
		"VoxelDisplay GPU instance build skipped: %s",
		"VoxelDisplay GPU instance build failed: %s",
		"voxel_instance_writer"
	)


# Shared orchestration for GPU-backed voxel display nodes. write_call must be
# bound to the same writer passed here so writing and disposal share ownership.
static func _build_writer_node(
	mesh: Mesh,
	instance_count: int,
	world_aabb: AABB,
	options: Dictionary,
	writer,
	write_call: Callable,
	warn_fmt: String,
	fail_fmt: String,
	meta_key: String,
	extra_meta: Dictionary = {}
) -> MultiMeshInstance3D:

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = instance_count
	mm.custom_aabb = world_aabb

	var node := MultiMeshInstance3D.new()
	node.name = str(options.get("name", "VoxelDisplay"))
	node.multimesh = mm
	node.custom_aabb = world_aabb

	if not writer.is_ready():
		push_warning(warn_fmt % writer.last_reason())
		writer.dispose()
		node.free()
		return null
	if not writer.bind_multimesh(mm.get_rid(), instance_count):
		push_warning(warn_fmt % writer.last_reason())
		writer.dispose()
		node.free()
		return null
	if not write_call.call():
		push_error(fail_fmt % writer.last_reason())
		writer.dispose()
		node.free()
		return null

	# Release GPU resources while the writer is still fully alive. PREDELETE
	# cannot safely bind a half-destructed object for render-thread cleanup.
	node.tree_exiting.connect(writer.dispose)

	# Retain the writer and its GPU resources for the display node's lifetime.
	node.set_meta(meta_key, writer)
	for key in extra_meta:
		node.set_meta(key, extra_meta[key])
	return node


static func _pack_center_transforms(centers: PackedVector3Array) -> PackedFloat32Array:
	var packed := PackedFloat32Array()
	packed.resize(centers.size() * VoxelInstanceDisplayGPUScript.TRANSFORM_FLOATS)
	for i in range(centers.size()):
		var base := i * VoxelInstanceDisplayGPUScript.TRANSFORM_FLOATS
		var center := centers[i]
		packed[base + 0] = 1.0
		packed[base + 3] = center.x
		packed[base + 5] = 1.0
		packed[base + 7] = center.y
		packed[base + 10] = 1.0
		packed[base + 11] = center.z
	return packed


static func _pack_transforms(transforms: Array) -> PackedFloat32Array:
	var packed := PackedFloat32Array()
	packed.resize(transforms.size() * VoxelInstanceDisplayGPUScript.TRANSFORM_FLOATS)
	for i in range(transforms.size()):
		var t: Transform3D = transforms[i]
		var base := i * VoxelInstanceDisplayGPUScript.TRANSFORM_FLOATS
		packed[base + 0] = t.basis.x.x
		packed[base + 1] = t.basis.y.x
		packed[base + 2] = t.basis.z.x
		packed[base + 3] = t.origin.x
		packed[base + 4] = t.basis.x.y
		packed[base + 5] = t.basis.y.y
		packed[base + 6] = t.basis.z.y
		packed[base + 7] = t.origin.y
		packed[base + 8] = t.basis.x.z
		packed[base + 9] = t.basis.y.z
		packed[base + 10] = t.basis.z.z
		packed[base + 11] = t.origin.z
	return packed


static func _pack_colors(colors: PackedColorArray, count: int) -> PackedFloat32Array:
	var packed := PackedFloat32Array()
	packed.resize(count * VoxelInstanceDisplayGPUScript.COLOR_FLOATS)
	for i in range(count):
		var c := colors[i] if i < colors.size() else Color.WHITE
		var base := i * VoxelInstanceDisplayGPUScript.COLOR_FLOATS
		packed[base + 0] = clampf(c.r, 0.0, 1.0)
		packed[base + 1] = clampf(c.g, 0.0, 1.0)
		packed[base + 2] = clampf(c.b, 0.0, 1.0)
		packed[base + 3] = clampf(c.a, 0.0, 1.0)
	return packed


static func _aabb_for_centers(centers: PackedVector3Array, cell_size: Vector3) -> AABB:
	var half := cell_size * 0.5
	var box := AABB(centers[0] - half, cell_size)
	for i in range(1, centers.size()):
		box = box.merge(AABB(centers[i] - half, cell_size))
	return box


static func _aabb_for_transforms(transforms: Array) -> AABB:
	var first: Transform3D = transforms[0]
	var box := _aabb_for_transform(first)
	for i in range(1, transforms.size()):
		box = box.merge(_aabb_for_transform(transforms[i]))
	return box


static func _aabb_for_transform(t: Transform3D) -> AABB:
	var extents := Vector3(
		absf(t.basis.x.x) + absf(t.basis.y.x) + absf(t.basis.z.x),
		absf(t.basis.x.y) + absf(t.basis.y.y) + absf(t.basis.z.y),
		absf(t.basis.x.z) + absf(t.basis.y.z) + absf(t.basis.z.z)
	) * 0.5
	return AABB(t.origin - extents, extents * 2.0)


# --- All-GPU field renderer ------------------------------------------------
# Render a full voxel field with zero GPU->CPU readback. A box MultiMesh is
# allocated with one instance per grid cell; a VoxelFieldDisplayGPU writer fills
# the instance transforms + colors directly in the MultiMesh buffer on the main
# RenderingDevice. Empty cells collapse to a zero basis on the GPU. The custom
# AABB is derived from the known grid bounds, so nothing reads back from the GPU
# to make the MultiMesh visible.
#
# fields / params are forwarded to VoxelFieldDisplayGPU.write_field(); world_aabb
# is the precomputed local-space bounds of the voxel grid. The writer is retained
# on the returned node metadata. Returns null when the field cannot be driven on
# the GPU.
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
	var writer = VoxelFieldDisplayGPUScript.new()
	return _build_writer_node(
		cell,
		voxel_count,
		world_aabb,
		options,
		writer,
		writer.write_field.bind(fields, params),
		"VoxelDisplay.build_field_gpu skipped: %s",
		"VoxelDisplay.build_field_gpu: %s",
		"voxel_field_writer",
		{"voxel_display_backend": "gpu", "voxel_display_reason": "ok"}
	)


# --- All-GPU brush tetra renderer ------------------------------------------
# Render a sparse list of painted brush voxels as tetrahedra with zero GPU->CPU
# readback. A tetra MultiMesh is allocated with one instance per painted voxel;
# a BrushVoxelDisplayGPU writer fills the instance transforms + colors directly
# in the MultiMesh buffer on the main RenderingDevice. The custom AABB is derived
# from the known grid bounds so nothing reads back to make the MultiMesh visible.
#
# brush_voxels is laid out as (voxel_x, slice, voxel_z, 0) per voxel; params are
# forwarded to BrushVoxelDisplayGPU.write_brush(). world_aabb is the precomputed
# local-space grid bounds. The writer is retained on the returned node metadata.
# Returns null when the brush cannot be driven on the GPU.
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
	var writer = BrushVoxelDisplayGPUScript.new()
	return _build_writer_node(
		mesh,
		instance_count,
		world_aabb,
		options,
		writer,
		writer.write_brush.bind(brush_voxels, params),
		"VoxelDisplay.build_brush_tetra_gpu skipped: %s",
		"VoxelDisplay.build_brush_tetra_gpu: %s",
		"voxel_brush_writer"
	)


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
