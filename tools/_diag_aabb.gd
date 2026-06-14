extends SceneTree
func _initialize():
    var s = load("res://geo/SM_TestLeaf_Test2.FBX")
    if s:
        var i = s.instantiate()
        var mi = _find_mi(i)
        if mi: print("LEAF_AABB=", mi.mesh.get_aabb())
    var s2 = load("res://geo/cliff_01.FBX")
    if s2:
        var i2 = s2.instantiate()
        var mi2 = _find_mi(i2)
        if mi2: print("CLIFF_AABB=", mi2.mesh.get_aabb())
    quit()
func _find_mi(n):
    if n is MeshInstance3D: return n
    for c in n.get_children():
        var r = _find_mi(c)
        if r: return r
    return null
