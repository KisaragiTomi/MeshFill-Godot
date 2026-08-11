class_name VoxelDisplay
extends RefCounted

const VoxelFieldDisplayGPUScript := preload("res://scripts/utils/voxel_field_display_gpu.gd")
const BrushVoxelDisplayGPUScript := preload("res://scripts/utils/brush_voxel_display_gpu.gd")
const VoxelInstanceDisplayGPUScript := preload("res://scripts/utils/voxel_instance_display_gpu.gd")
## 三个 writer 的共同基类。这里只取它的 MULTIMESH_INSTANCE_FLOATS —— 本文件是全仓唯一
## 分配体素显示 MultiMesh 的地方，布局硬门（_assert_multimesh_layout）必须拿 writer 侧的
## stride 事实源来比，而不是在这里另写一个 16。
const VoxelMultiMeshWriterGPUScript := preload("res://scripts/utils/voxel_multimesh_writer_gpu.gd")

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

# 单元格几何形状。**形状即域标识**：一眼能看出点到的是哪个域，不必去读 pick id。
# 现行分配（设计意图见「点选重构-可视化即拾取几何.md」）：
#   TargetSV = 方盒、SV = 四面体、SVTile = 八面体、Brush = 四面体。
# 三者都贴合同一个 cell 包围盒（`cell_size * fill`），所以换形状不改变体素的占位与间距，
# 只改变轮廓——密集网格下形状差异仍然可辨，因为相邻体素之间留着 1 - fill 的缝。
const SHAPE_BOX := "box"
const SHAPE_TETRA := "tetra"
const SHAPE_OCTA := "octa"


# Per-voxel color box MultiMesh. colors.size() must match centers.
static func build_colored(
	centers: PackedVector3Array,
	cell_size: Vector3,
	colors: PackedColorArray,
	options: Dictionary = {}
) -> MultiMeshInstance3D:
	if centers.is_empty():
		return null
	# colors 短于 centers 时原先由 _pack_colors 逐个补 Color.WHITE：多出来的体素会以
	# 「纯白」参与显示，看起来是一份合法的调试图，实际是缺色数据。
	if colors.size() != centers.size():
		push_error("VoxelDisplay.build_colored: colors 数量 %d 与 centers 数量 %d 不一致 —— 拒绝以白色补齐" % [colors.size(), centers.size()])
		assert(false, "VoxelDisplay.build_colored: color/center count mismatch")
		return null
	var fill := float(options.get("fill", DEFAULT_FILL))
	# 走同一个形状分派：四个构建入口全部经 _make_cell_mesh，没有旁路。
	var cell := _make_cell_mesh(str(options.get("shape", SHAPE_BOX)), cell_size, fill)
	if cell == null:
		return null
	return _build_gpu_instances(
		cell,
		_pack_center_transforms(centers),
		_pack_colors(colors, centers.size()),
		_aabb_for_centers(centers, cell_size * fill),
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
	if colors.size() != transforms.size():
		push_error("VoxelDisplay.build_from_transforms: colors 数量 %d 与 transforms 数量 %d 不一致 —— 拒绝以白色补齐" % [colors.size(), transforms.size()])
		assert(false, "VoxelDisplay.build_from_transforms: color/transform count mismatch")
		return null

	# 单位 cell 几何：逐实例变换自带缩放，所以本体固定为 1×1×1（方盒即 ±0.5，
	# 八面体六顶点同样落在 ±0.5 的面心上，两者外接盒一致 ⇒ 换形状不改变占位）。
	var cell := _make_cell_mesh(str(options.get("shape", SHAPE_BOX)), Vector3.ONE, 1.0)
	if cell == null:
		return null

	return _build_gpu_instances(
		cell,
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
	# 布局与可见性盒的硬门。放在这里是因为这是全仓**唯一**分配体素显示 MultiMesh 的地方
	# （writer 侧 bind_multimesh 只拿得到 RID，查不到格式开关）。mesh 是 Resource，
	# 判死时直接返回即可，无需手动释放；writer 尚未构造，也没有 GPU 资源要回收。
	if not _assert_multimesh_layout(mm, world_aabb, str(options.get("name", "VoxelDisplay"))):
		return null

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


# 体素显示 MultiMesh 的两条资源级硬门。都是**静默**失败模式，所以必须在这里判死：
#
# 1) 实例 stride。三个 writer 着色器都按 VoxelMultiMeshWriterGPU.MULTIMESH_INSTANCE_FLOATS
#    （= 16）步进直写 multimesh_get_buffer_rd_rid，而引擎侧对 compute 直写**没有任何尺寸校验**
#    （只有 multimesh.set_buffer() 那条路有 ERR_FAIL_COND）。谁把 use_custom_data 打开、
#    或把 transform_format 改成 2D，引擎的 stride 就变了（mesh_storage.cpp:1573-1576：
#    stride = 12 + colors*4 + custom*4，2D 时基数是 8），而着色器仍按 16 写 ——
#    表现是满屏乱变换，last_reason() 依旧是 "ok"。
#    ⚠ 最阴的一种是「只开 use_custom_data、不开 use_colors」：stride 同样是 16，撞上同一个数
#    却是完全不同的布局（custom 落 12 而不是 16），逐字段错位而总长度对得上。
#    所以这里比的不是 stride 数值，是**两个开关 + 格式**三项本身。
#
# 2) custom_aabb 非空。空 AABB 会让整批实例被视锥剔除掉，且 PickIdPass.prepare() 对
#    这种 drawable 是静默跳过（只记进 skipped 数组，不报错）——界面表现是「这个域画不出来、
#    也怎么点都点不中」，没有任何提示。《AutoVolume 公用体积基类计划》§2.5-3 要求登记时校验，
#    这里是它的落点。只判「三轴全为 0」这种真退化，不判 has_volume()：
#    薄片显示（voxel_size.y 很小）是合法形态，不该被误杀。
static func _assert_multimesh_layout(mm: MultiMesh, world_aabb: AABB, display_name: String) -> bool:
	if mm.transform_format != MultiMesh.TRANSFORM_3D or not mm.use_colors or mm.use_custom_data:
		push_error("VoxelDisplay: \"%s\" 的 MultiMesh 布局与 writer 着色器不符（transform_format=%d 需 TRANSFORM_3D(%d)，use_colors=%s 需 true，use_custom_data=%s 需 false）—— 着色器按 %d float/实例 直写，布局一变就是整体错位且不报错。" % [
			display_name, mm.transform_format, MultiMesh.TRANSFORM_3D,
			str(mm.use_colors), str(mm.use_custom_data),
			VoxelMultiMeshWriterGPUScript.MULTIMESH_INSTANCE_FLOATS])
		assert(false, "VoxelDisplay._assert_multimesh_layout: multimesh layout diverges from writer stride")
		return false
	if world_aabb.size == Vector3.ZERO:
		push_error("VoxelDisplay: \"%s\" 的 custom_aabb 为空（position=%s size=%s）—— 整批实例会被视锥剔除，且 PickIdPass 对空盒 drawable 是静默跳过，表现为「画不出也点不中」。" % [
			display_name, str(world_aabb.position), str(world_aabb.size)])
		assert(false, "VoxelDisplay._assert_multimesh_layout: empty custom_aabb")
		return false
	return true


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
	# 数量一致性由两个公开入口（build_colored / build_from_transforms）硬门保证。
	if colors.size() < count:
		push_error("VoxelDisplay._pack_colors: colors 数量 %d 少于实例数 %d —— 拒绝以白色补齐" % [colors.size(), count])
		assert(false, "VoxelDisplay._pack_colors: color count mismatch")
		return PackedFloat32Array()
	for i in range(count):
		var c := colors[i]
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
	# 默认方盒：TargetSV（唯一的既有调用方，target_sv_setup.gd:244）不传 shape，行为不变。
	var cell := _make_cell_mesh(str(options.get("shape", SHAPE_BOX)), cell_size, fill)
	if cell == null:
		return null
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


# --- All-GPU field renderer（已打包输入）-------------------------------------
# 与 build_field_gpu 同一条通路，区别只有一个：三块场**已经是 shader 的输入格式**，
# 直接上传，不再经 codec 从 float 数组打包。
#
# 给 SceneSV 用。它的常驻场对天生就是这两种格式（complexity = rgba8 且 complexity 在低字节、
# collision = unorm8 在低字节），与本 shader 的 unpack 逐位相同。
#
# ⚠ SPA 的 GPU 栈跑在**本地 RenderingDevice**（committer 的 ensure_device(true, false)），
# 而本条通路的 writer 绑的是**主设备** —— RID 不能跨设备，所以调用方必须先把常驻场
# 回读成字节再传进来。这不是可以省掉的一步。
static func build_field_gpu_packed(
	voxel_count: int,
	cell_size: Vector3,
	world_aabb: AABB,
	packed_fields: Dictionary,
	params: Dictionary,
	options: Dictionary = {}
) -> MultiMeshInstance3D:
	if voxel_count <= 0:
		return null
	var fill := float(options.get("fill", DEFAULT_FILL))
	var cell := _make_cell_mesh(str(options.get("shape", SHAPE_BOX)), cell_size, fill)
	if cell == null:
		return null
	_apply_voxel_material(cell, true, Color.WHITE, options)
	var writer = VoxelFieldDisplayGPUScript.new()
	return _build_writer_node(
		cell,
		voxel_count,
		world_aabb,
		options,
		writer,
		writer.write_packed_field.bind(
			packed_fields.get("occupancy_u32", PackedByteArray()),
			packed_fields.get("collision_u32", PackedByteArray()),
			packed_fields.get("color_rgba8", PackedByteArray()),
			packed_fields.get("terrain_height", PackedFloat32Array()),
			params),
		"VoxelDisplay.build_field_gpu_packed skipped: %s",
		"VoxelDisplay.build_field_gpu_packed: %s",
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
	# 走同一个形状分派：笔刷的四面体与 SV 的四面体从此是同一段代码，
	# 形状定义不会在两处各自漂移。默认值即 SHAPE_TETRA，调用方可覆盖。
	var mesh := _make_cell_mesh(str(options.get("shape", SHAPE_TETRA)), cell_size, fill)
	if mesh == null:
		return null
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


# 按形状名构建单元格网格。未知形状**判死**而不是回落方盒：形状是域的视觉标识，
# 静默换成方盒会让两个域看起来一模一样，而这正是本项目要消灭的那类"看着对、实则错"。
static func _make_cell_mesh(shape: String, cell_size: Vector3, fill: float) -> Mesh:
	match shape:
		SHAPE_BOX:
			var box := BoxMesh.new()
			box.size = cell_size * fill
			return box
		SHAPE_TETRA:
			return _make_tetra_mesh(cell_size, fill)
		SHAPE_OCTA:
			return _make_octa_mesh(cell_size, fill)
	push_error("VoxelDisplay._make_cell_mesh: 未知形状 \"%s\"（可选 %s / %s / %s）——不回落方盒。" % [
		shape, SHAPE_BOX, SHAPE_TETRA, SHAPE_OCTA])
	assert(false, "VoxelDisplay._make_cell_mesh: unknown shape")
	return null


# 贴合 cell 的八面体：六个顶点各自落在 cell 的一个面心上（±X / ±Y / ±Z），八个三角面。
# 与 _make_tetra_mesh 同规格——同一个 cell 包围盒、逐面平法线、无 UV、朝向固定
#（体素不携带朝向语义）。体积约为同 cell 方盒的 1/6，比四面体（1/3）更小更"尖"，
# 因此 SVTile 这类聚合视图即使默认显示也不会糊住底下的单体素。
static func _make_octa_mesh(cell_size: Vector3, fill: float) -> ArrayMesh:
	var h := cell_size * fill * 0.5
	var verts := PackedVector3Array([
		Vector3(h.x, 0.0, 0.0),    # 0 +X
		Vector3(-h.x, 0.0, 0.0),   # 1 -X
		Vector3(0.0, h.y, 0.0),    # 2 +Y
		Vector3(0.0, -h.y, 0.0),   # 3 -Y
		Vector3(0.0, 0.0, h.z),    # 4 +Z
		Vector3(0.0, 0.0, -h.z),   # 5 -Z
	])
	# 绕序统一为「从外部看逆时针」，法线因此朝外。上下各四面。
	var faces := [
		[2, 4, 0], [2, 1, 4], [2, 5, 1], [2, 0, 5],
		[3, 0, 4], [3, 4, 1], [3, 1, 5], [3, 5, 0],
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
