@tool
extends RefCounted

## 合并自 auto_voxel_fixture.gd / scene_voxel_fixture.gd / target_sv_buffer_fixture.gd。
## 各 demo/test 的体素相关测试数据构造器统一收敛于此。

const AssetDescriptorScript := preload("res://scripts/asset_descriptor.gd")
const AutoVoxelProfileScript := preload("res://scripts/auto_voxel_profile.gd")
const SemanticProbeProfileScript := preload("res://scripts/semantic_probe_profile.gd")
const BufferUtils := preload("res://scripts/utils/buffer_utils.gd")

const DEFAULT_TILE_SIZE := VoxelGeneral.DEFAULT_TILE_SIZE


# ============================================================
# AssetDescriptor / AutoVoxelProfile 测试构造器（原 auto_voxel_fixture.gd）
# ============================================================

static func make_runtime_profile_descriptor() -> AssetDescriptor:
	var descriptor: AssetDescriptor = AssetDescriptorScript.new()
	descriptor.set_color_and_complexity(Color(0.2, 0.4, 0.6, 1.0), 0.5)
	descriptor.set_collision([])
	descriptor.set_pivot_variants([{
		"name": "root",
		"offset": Vector3(0.0, -0.25, 0.0),
		"score_bias": 0.1,
	}])
	descriptor.semantic_probe_density = 1.0
	descriptor.context_sensing_radius = 0.5
	descriptor.set_semantic_probes([SemanticProbeProfileScript.make_probe(
		Vector3(0.25, 0.5, -0.25),
		Color(0.2, 0.4, 0.6, 0.5),
		0.3,
		1.0, 1.0, 1.0,
		"manual"
	)])
	return descriptor


static func make_runtime_profile() -> AutoVoxelProfile:
	var profile: AutoVoxelProfile = AutoVoxelProfileScript.new()
	profile.color = Color(0.15, 0.25, 0.35, 1.0)
	profile.complexity = 0.65
	profile.collision = []
	return profile


static func make_spa_test_descriptor(id_name: String) -> AssetDescriptor:
	var descriptor: AssetDescriptor = AssetDescriptorScript.new()
	descriptor.asset_id = id_name
	descriptor.object_type = "vegetation"
	descriptor.color = Color(0.3, 0.7, 0.4, 0.8)
	descriptor.complexity = 0.8
	descriptor.set_collision([{"offset": Vector3.ZERO, "radius": 0.2, "height": 0.5}])
	descriptor.mesh_create_method = "create_sample_autoobject_mesh"
	return descriptor


static func make_mesh_description_descriptor(
	asset_id: String,
	mesh: Mesh,
	source_mesh: Mesh,
	source_mesh_path: String
) -> AssetDescriptor:
	var descriptor: AssetDescriptor = AssetDescriptorScript.new()
	descriptor.asset_id = asset_id
	descriptor.object_type = "vegetation"
	descriptor.mesh = mesh
	descriptor.source_mesh = source_mesh
	descriptor.source_mesh_path = source_mesh_path
	descriptor.set_color_and_complexity(Color(0.2, 0.7, 0.3, 1.0), 0.6)
	descriptor.set_collision([])
	descriptor.set_pivot_variants([{
		"name": "root",
		"offset": Vector3.ZERO,
		"score_bias": 0.0,
	}])
	descriptor.set_semantic_probes([SemanticProbeProfileScript.make_probe(
		Vector3.ZERO,
		Color(0.2, 0.7, 0.3, 0.6),
		0.5,
		1.0, 0.0, 0.0,
		"manual"
	)])
	return descriptor


# ============================================================
# SV 字典测试构造器（原 scene_voxel_fixture.gd）
# ============================================================

static func make_sv(
	grid_size: Vector3i,
	voxel_size: Vector3,
	grid_origin: Vector3,
	complexity_field: PackedFloat32Array,
	collision_field: PackedFloat32Array,
	tile_size: int = DEFAULT_TILE_SIZE,
	dirty_tiles: Dictionary = {}
) -> Dictionary:
	var tile_grid_size := VoxelGeneral.tile_grid_size_for_grid(grid_size, tile_size)
	return {
		"type": "SV",
		"grid_size": grid_size,
		"voxel_size": voxel_size,
		"grid_origin": grid_origin,
		"complexity_field": complexity_field,
		"collision_field": collision_field,
		"tile_grid_size": tile_grid_size,
		"total_tiles": tile_grid_size.x * tile_grid_size.y * tile_grid_size.z,
		"dirty_tiles": dirty_tiles.duplicate(true),
	}


static func make_flat_ground_sv(
	grid_size: Vector3i,
	voxel_size: Vector3,
	tile_size: int = DEFAULT_TILE_SIZE,
	grid_origin: Vector3 = Vector3.ZERO
) -> Dictionary:
	var count := VoxelGeneral.voxel_count(grid_size)
	var complexity_field := PackedFloat32Array()
	var collision_field := PackedFloat32Array()
	complexity_field.resize(count)
	collision_field.resize(count)
	for z in range(maxi(grid_size.z, 0)):
		for x in range(maxi(grid_size.x, 0)):
			var index := VoxelGeneral.voxel_index(Vector3i(x, 0, z), grid_size)
			if index >= 0 and index < complexity_field.size():
				complexity_field[index] = 1.0
	return make_sv(
		grid_size,
		voxel_size,
		grid_origin,
		complexity_field,
		collision_field,
		tile_size
	)


# ============================================================
# TargetSV 线性读取缓冲构造器（原 target_sv_buffer_fixture.gd）
# ============================================================

static func make_linear_read_buffers(
	tex_size: int = 2,
	slice_count: int = 2,
	visual_alpha: float = 0.25,
	base_collision: float = 0.1,
	strong_collision_idx: int = 5,
	strong_collision: float = 0.8
) -> Dictionary:
	var voxel_count := maxi(tex_size, 0) * maxi(tex_size, 0) * maxi(slice_count, 0)
	var visual := PackedByteArray()
	var collision := PackedByteArray()
	visual.resize(voxel_count * 4)
	collision.resize(voxel_count)

	for i in range(voxel_count):
		visual.encode_u32(i * 4, BufferUtils.pack_shader_rgba8_word(Color(
			float(i) / 10.0,
			float(i + 1) / 10.0,
			float(i + 2) / 10.0,
			visual_alpha
		)))
		collision[i] = BufferUtils.quantize_unorm8(base_collision)

	if strong_collision_idx >= 0 and strong_collision_idx < voxel_count:
		collision[strong_collision_idx] = BufferUtils.quantize_unorm8(strong_collision)

	return {
		"tex_size": tex_size,
		"slice_count": slice_count,
		"voxel_count": voxel_count,
		"visual": visual,
		"collision": collision,
		"strong_collision_idx": strong_collision_idx,
		"strong_collision": strong_collision,
		"visual_alpha": visual_alpha,
		"base_collision": base_collision,
		"visual_format": "rgba8",
		"collision_format": "r8_unorm",
	}
