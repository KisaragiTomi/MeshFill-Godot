@tool
class_name VolumeScoreProviderRegistry
extends RefCounted

const REFRESH_METHOD := &"reload_and_rescore"

static var _live_providers: Array[Object] = []


static func register(provider: Object) -> bool:
	_prune_invalid()
	if provider == null or _live_providers.has(provider):
		return false
	_live_providers.append(provider)
	return true


static func unregister(provider: Object) -> bool:
	var index := _live_providers.find(provider)
	if index < 0:
		return false
	_live_providers.remove_at(index)
	return true


## Refreshes all currently live providers after descriptor data changes.
## Providers remain scene-owned and only need to implement reload_and_rescore().
static func refresh_all_after_descriptor_bake() -> int:
	var refreshed := 0
	for provider in _live_providers.duplicate():
		if not is_instance_valid(provider) or not provider.has_method(REFRESH_METHOD):
			_live_providers.erase(provider)
			continue
		provider.call(REFRESH_METHOD)
		refreshed += 1
	return refreshed


static func live_provider_count() -> int:
	_prune_invalid()
	return _live_providers.size()


static func _prune_invalid() -> void:
	for provider in _live_providers.duplicate():
		if not is_instance_valid(provider):
			_live_providers.erase(provider)
