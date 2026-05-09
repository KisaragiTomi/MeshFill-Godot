class_name AutoGrass
extends AutoVegetation


func configure_grass(config: Dictionary) -> void:
	var cfg := config.duplicate(true)
	cfg["object_subtype"] = "grass"
	cfg["band"] = "ground"
	if not cfg.has("group"):
		cfg["group"] = "placed_grass"
	configure_vegetation(cfg)
