extends "res://scripts/utils/scene_tree_test.gd"

const VolumeScoreProviderRegistry := preload("res://scripts/volume_score_provider_registry.gd")


class TestProvider extends RefCounted:
	var refresh_count := 0

	func reload_and_rescore() -> Dictionary:
		refresh_count += 1
		return {"ok": true}


func _init() -> void:
	run_suite("VolumeScoreProviderRegistry", [
		Callable(self, "_test_register_refresh_unregister"),
	])


func fail(message: String) -> bool:
	push_error("  FAIL: %s" % message)
	return false


func _test_register_refresh_unregister() -> bool:
	var provider := TestProvider.new()
	var initial_count := VolumeScoreProviderRegistry.live_provider_count()
	if not VolumeScoreProviderRegistry.register(provider):
		return fail("first provider registration should succeed")
	if VolumeScoreProviderRegistry.register(provider):
		VolumeScoreProviderRegistry.unregister(provider)
		return fail("duplicate provider registration should be ignored")
	if VolumeScoreProviderRegistry.live_provider_count() != initial_count + 1:
		VolumeScoreProviderRegistry.unregister(provider)
		return fail("registry should contain the newly registered provider")

	var refreshed := VolumeScoreProviderRegistry.refresh_all_after_descriptor_bake()
	if refreshed < 1 or provider.refresh_count != 1:
		VolumeScoreProviderRegistry.unregister(provider)
		return fail("registered provider should refresh exactly once")
	if not VolumeScoreProviderRegistry.unregister(provider):
		return fail("provider unregister should succeed")
	if VolumeScoreProviderRegistry.live_provider_count() != initial_count:
		return fail("registry should return to its initial provider count")
	return true
