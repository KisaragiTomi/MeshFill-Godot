class_name PCGLayer
extends RefCounted

var layer_name: String = ""
var inputs: Dictionary = {}
var outputs: Dictionary = {}
var override_masks: Dictionary = {}
var override_deltas: Dictionary = {}
var final_outputs: Dictionary = {}
var dirty_margin: int = 0


func generate(_dirty_rect: Rect2i = Rect2i()) -> void:
	pass


func composite() -> void:
	for port_name in outputs:
		var gen_img: Image = outputs[port_name]
		if gen_img == null:
			continue
		if override_masks.has(port_name) and override_deltas.has(port_name):
			var mask: Image = override_masks[port_name]
			var delta: Image = override_deltas[port_name]
			if mask != null and delta != null:
				var final_img: Image = gen_img.duplicate()
				var w: int = gen_img.get_width()
				var h: int = gen_img.get_height()
				for y in range(h):
					for x in range(w):
						var px := Vector2i(x, y)
						var m: float = mask.get_pixelv(px).r
						if m > 0.01:
							var base: Color = final_img.get_pixelv(px)
							var d: Color = delta.get_pixelv(px)
							base.r += d.r * m
							final_img.set_pixelv(px, base)
				final_outputs[port_name] = final_img
			else:
				final_outputs[port_name] = gen_img
		else:
			final_outputs[port_name] = gen_img


func set_override(port: String, mask: Image, delta: Image) -> void:
	override_masks[port] = mask
	override_deltas[port] = delta


func clear_override(port: String) -> void:
	override_masks.erase(port)
	override_deltas.erase(port)


func save_overrides(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	for port_name in override_masks:
		var mask: Image = override_masks[port_name]
		var delta: Image = override_deltas.get(port_name)
		if mask != null:
			mask.save_png("%s/%s_%s_override_mask.png" % [dir, layer_name, port_name])
		if delta != null:
			delta.save_png("%s/%s_%s_override_delta.png" % [dir, layer_name, port_name])


func load_overrides(dir: String) -> void:
	for port_name in outputs:
		var mask_path := "%s/%s_%s_override_mask.png" % [dir, layer_name, port_name]
		var delta_path := "%s/%s_%s_override_delta.png" % [dir, layer_name, port_name]
		if FileAccess.file_exists(mask_path):
			override_masks[port_name] = Image.load_from_file(mask_path)
		if FileAccess.file_exists(delta_path):
			override_deltas[port_name] = Image.load_from_file(delta_path)
