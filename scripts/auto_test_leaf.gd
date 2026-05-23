class_name AutoTestLeaf
extends AutoVegetation

const DEFAULT_SUBTYPE := "test_leaf"
const DEFAULT_CHANNEL := 1
const DEFAULT_RADIUS := 1.0
const DEFAULT_GROUP := "placed_test_leaves"


func configure_test_leaf(config: Dictionary) -> void:
	configure_asset(config)


func configure_asset(config: Dictionary) -> void:
	var cfg := config.duplicate(true)
	cfg["object_subtype"] = DEFAULT_SUBTYPE
	cfg["channel"] = DEFAULT_CHANNEL
	cfg["radius"] = DEFAULT_RADIUS
	if not cfg.has("group") and not DEFAULT_GROUP.is_empty():
		cfg["group"] = DEFAULT_GROUP
	configure_vegetation(cfg)
