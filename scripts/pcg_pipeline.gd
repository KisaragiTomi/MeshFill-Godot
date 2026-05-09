class_name PCGPipeline
extends RefCounted

var _layers: Dictionary = {}
var _sorted_layers: Array[PCGLayer] = []
var _connections: Dictionary = {}


func add_layer(layer: PCGLayer) -> void:
	_layers[layer.layer_name] = layer


func connect_port(target_layer: String, target_port: String, source_layer: String, source_port: String) -> void:
	_connections[target_layer + "/" + target_port] = {
		"layer": source_layer,
		"port": source_port,
	}


func set_layer_order(order: Array[String]) -> void:
	_sorted_layers.clear()
	for name in order:
		if _layers.has(name):
			_sorted_layers.append(_layers[name])


func execute(dirty_rect: Rect2i = Rect2i(), texture_size: int = 0) -> void:
	var current_dirty := dirty_rect
	for layer in _sorted_layers:
		for port_key: String in _connections:
			var parts: PackedStringArray = port_key.split("/")
			if parts.size() != 2:
				continue
			if parts[0] != layer.layer_name:
				continue
			var port_name: String = parts[1]
			var source: Dictionary = _connections[port_key]
			var src_layer_name: String = source["layer"]
			var src_port: String = source["port"]
			if _layers.has(src_layer_name):
				var src_layer: PCGLayer = _layers[src_layer_name]
				if src_layer.final_outputs.has(src_port):
					layer.inputs[port_name] = src_layer.final_outputs[src_port]

		layer.generate(current_dirty)
		layer.composite()

		if layer.dirty_margin > 0 and current_dirty.size.x > 0:
			current_dirty = current_dirty.grow(layer.dirty_margin)
			if texture_size > 0:
				current_dirty = current_dirty.intersection(Rect2i(0, 0, texture_size, texture_size))


func get_layer(name: String) -> PCGLayer:
	return _layers.get(name)


func get_output(layer_name: String, port_name: String) -> Image:
	if _layers.has(layer_name):
		var layer: PCGLayer = _layers[layer_name]
		if layer.final_outputs.has(port_name):
			return layer.final_outputs[port_name]
	return null
