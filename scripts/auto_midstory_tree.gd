class_name AutoMidstoryTree
extends AutoVegetation


func configure_midstory_tree(config: Dictionary) -> void:
	var cfg := config.duplicate(true)
	cfg["object_subtype"] = "midstory_tree"
	cfg["channel"] = 2
	cfg["radius"] = 2.0
	if not cfg.has("group"):
		cfg["group"] = "placed_midstory_trees"
	configure_vegetation(cfg)
