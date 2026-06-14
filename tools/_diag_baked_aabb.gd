extends SceneTree

const Factory := preload("res://scripts/auto_asset_factory.gd")


func _initialize() -> void:
	for p in [
		"res://geo/SM_TestLeaf_Test2.FBX",
		"res://geo/cliff_01.FBX",
		"res://geo/cliff_02.FBX",
	]:
		var mesh := Factory.load_mesh(p)
		if mesh == null:
			print(p, " -> NULL")
			continue
		var aabb := mesh.get_aabb()
		print(p, " baked_aabb_pos=", aabb.position, " size=", aabb.size,
			" y_min=", aabb.position.y, " y_max=", aabb.position.y + aabb.size.y)
	quit()