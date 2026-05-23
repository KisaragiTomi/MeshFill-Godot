class_name AutoBush
extends AutoVegetation


func configure_bush(config: Dictionary) -> void:
	var cfg := config.duplicate(true)
	cfg["object_subtype"] = "bush"
	cfg["channel"] = 1
	cfg["radius"] = 1.0
	if not cfg.has("group"):
		cfg["group"] = "placed_bushes"
	configure_vegetation(cfg)
