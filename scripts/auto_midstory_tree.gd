class_name AutoMidstoryTree
extends AutoVegetation


func configure_midstory_tree(config: Dictionary) -> void:
	var cfg := config.duplicate(true)
	cfg["object_subtype"] = "midstory_tree"
	cfg["band"] = "midstory"
	if not cfg.has("group"):
		cfg["group"] = "placed_midstory_trees"
	configure_vegetation(cfg)
