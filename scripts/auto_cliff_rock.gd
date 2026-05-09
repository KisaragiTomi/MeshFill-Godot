class_name AutoCliffRock
extends AutoRock


func configure_asset(config: Dictionary) -> void:
	configure_cliff(config)


func configure_cliff(config: Dictionary) -> void:
	var cfg := config.duplicate(true)
	cfg["object_subtype"] = "cliff"
	configure_rock(cfg)
