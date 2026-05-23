class_name AutoGrass
extends AutoVegetation


func configure_grass(config: Dictionary) -> void:
	var cfg := config.duplicate(true)
	cfg["object_subtype"] = "grass"
	cfg["channel"] = 0
	cfg["radius"] = 0.2
	if not cfg.has("group"):
		cfg["group"] = "placed_grass"
	configure_vegetation(cfg)
