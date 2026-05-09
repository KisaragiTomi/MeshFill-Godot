class_name AutoCanopyTree
extends AutoVegetation


func configure_canopy_tree(config: Dictionary) -> void:
	var cfg := config.duplicate(true)
	cfg["object_subtype"] = "canopy_tree"
	cfg["band"] = "canopy"
	if not cfg.has("group"):
		cfg["group"] = "placed_canopy_trees"
	configure_vegetation(cfg)
