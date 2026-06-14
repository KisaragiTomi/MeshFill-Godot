extends SceneTree
func _initialize():
    var s = load("res://geo/SM_TestLeaf_Test2.FBX")
    if s:
        var i = s.instantiate()
        print("LEAF_NODE_TREE=", _describe(i, 0))
    quit()
func _describe(n, depth):
    var s = "["+n.get_class()+"] "+n.name
    if n is MeshInstance3D: s += " surfaces="+str(n.mesh.get_surface_count())+" aabb="+str(n.mesh.get_aabb())
    for c in n.get_children():
        s += "\n" + "  ".repeat(depth+1) + _describe(c, depth+1)
    return s
