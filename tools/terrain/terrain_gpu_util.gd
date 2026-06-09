## Shared GPU-terrain utilities: common _blocked and _is_virtual_path
## factored out of duplicated definitions across terrain/*.gd files.

static func gpu_blocked(reason: String, width: int = 0, height: int = 0) -> Dictionary:
	return {
		"ok": false,
		"reason": reason,
		"gpu_first": true,
		"cpu_fallback": false,
		"width": width,
		"height": height,
	}


static func is_virtual_path(path: String) -> bool:
	return path.begins_with("res://") or path.begins_with("user://")
