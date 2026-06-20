extends SceneTree

const AutoAssetFactory := preload("res://scripts/auto_asset_factory.gd")
const MeshVoxelizerGpuScript := preload("res://scripts/mesh_voxelizer_gpu.gd")

const LEAF_FBX_PATH := "res://geo/SM_TestLeaf_Test2.FBX"
const CLIFF1_FBX_PATH := "res://geo/cliff_01.FBX"


func _init() -> void:
	_diag("TREE", LEAF_FBX_PATH, Color(0.35, 0.58, 0.24, 0.55), 2)
	_diag("ROCK", CLIFF1_FBX_PATH, Color(0.48, 0.42, 0.35, 0.7), 6)
	quit()


func _diag(label: String, path: String, color: Color, min_neighbors: int) -> void:
	var mesh := AutoAssetFactory.load_mesh(path)
	if mesh == null:
		print(label, " mesh load FAILED: ", path)
		return
	var aabb := mesh.get_aabb()
	print("\n==== ", label, " (min_neighbors=", min_neighbors, ") ====")
	print(label, " aabb_pos=", aabb.position, " size=", aabb.size)
	var voxelizer = MeshVoxelizerGpuScript.new()
	var result := voxelizer.voxelize(mesh, 28, color, 0.9, min_neighbors)
	if not bool(result.get("ok", false)):
		print(label, " voxelize FAILED: ", result.get("reason", "?"))
		return
	var grid: Vector3i = result["grid"]
	var voxels: Array = result["voxels"]
	print(label, " grid=", grid, " cell=", result["cell_size"], " solid=", voxels.size())

	var solid_by_y := {}
	var coll_by_y := {}
	var coll_total := 0
	for v in voxels:
		var y: int = v["voxel"].y
		solid_by_y[y] = int(solid_by_y.get(y, 0)) + 1
		if float(v["collision"]) > 0.0:
			coll_by_y[y] = int(coll_by_y.get(y, 0)) + 1
			coll_total += 1
	print(label, " collision_total=", coll_total, " / solid=", voxels.size())
	var ys: Array = solid_by_y.keys()
	ys.sort()
	for y in ys:
		print("  y=%2d solid=%4d coll=%4d" % [y, int(solid_by_y[y]), int(coll_by_y.get(y, 0))])