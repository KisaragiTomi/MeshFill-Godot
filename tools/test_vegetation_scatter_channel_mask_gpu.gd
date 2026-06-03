extends SceneTree


func _init() -> void:
	var occupancy := Image.create(8, 8, false, Image.FORMAT_RGBAH)
	occupancy.fill(Color(0.0, 0.0, 0.0, 0.0))
	occupancy.set_pixelv(Vector2i(1, 2), Color(0.1, 0.2, 0.75, 0.4))
	occupancy.set_pixelv(Vector2i(2, 1), Color(0.1, 0.2, 0.005, 0.4))
	occupancy.set_pixelv(Vector2i(3, 3), Color(0.0, 0.3, 0.0, 0.0))

	var mask := VegetationScatter.make_vegetation_channel_mask_from_occupancy_gpu(occupancy, 2, 0.01, Vector2i(12, 10))
	if mask == null:
		print("[VegetationScatterChannelMaskGPU] SKIP: no RenderingDevice available for GPU channel mask")
		quit(0)
		return
	if mask.is_empty() or mask.get_width() != 12 or mask.get_height() != 10 or mask.get_format() != Image.FORMAT_RF:
		push_error("[VegetationScatterChannelMaskGPU] R32F output size/format contract failed")
		quit(1)
		return
	if mask.get_pixelv(Vector2i(1, 2)).r <= 0.7:
		push_error("[VegetationScatterChannelMaskGPU] selected channel was not copied")
		quit(1)
		return
	if mask.get_pixelv(Vector2i(2, 1)).r > 0.001:
		push_error("[VegetationScatterChannelMaskGPU] below-threshold value was not zeroed")
		quit(1)
		return
	if mask.get_pixelv(Vector2i(7, 7)).r > 0.001:
		push_error("[VegetationScatterChannelMaskGPU] empty source pixels should remain zero")
		quit(1)
		return
	if mask.get_pixelv(Vector2i(10, 8)).r > 0.001:
		push_error("[VegetationScatterChannelMaskGPU] pixels outside source bounds should remain zero")
		quit(1)
		return

	var count := VegetationScatter.count_mask_pixels_gpu(mask, 0.01)
	if count != 1:
		push_error("[VegetationScatterChannelMaskGPU] expected one active mask pixel, got %d" % count)
		quit(1)
		return
	var high_threshold_count := VegetationScatter.count_mask_pixels_gpu(mask, 0.8)
	if high_threshold_count != 0:
		push_error("[VegetationScatterChannelMaskGPU] high threshold should filter all pixels, got %d" % high_threshold_count)
		quit(1)
		return
	var combined := VegetationScatter.make_vegetation_channel_mask_with_count_gpu(occupancy, 2, 0.01, Vector2i(12, 10))
	if combined.is_empty():
		push_error("[VegetationScatterChannelMaskGPU] combined mask/count path failed")
		quit(1)
		return
	var combined_mask: Image = combined.get("mask", null)
	if combined_mask == null or combined_mask.is_empty() or int(combined.get("active_count", -1)) != 1:
		push_error("[VegetationScatterChannelMaskGPU] combined path output contract failed")
		quit(1)
		return
	if combined_mask.get_pixelv(Vector2i(1, 2)).r <= 0.7 or combined_mask.get_pixelv(Vector2i(10, 8)).r > 0.001:
		push_error("[VegetationScatterChannelMaskGPU] combined path mask values are incorrect")
		quit(1)
		return
	var channel_counts := VegetationScatter.count_vegetation_channels_gpu(occupancy, 0.01)
	if channel_counts.size() != 4:
		push_error("[VegetationScatterChannelMaskGPU] channel counts path failed")
		quit(1)
		return
	if channel_counts[0] != 2 or channel_counts[1] != 3 or channel_counts[2] != 1 or channel_counts[3] != 2:
		push_error("[VegetationScatterChannelMaskGPU] channel counts mismatch: %s" % str(Array(channel_counts)))
		quit(1)
		return
	var high_channel_counts := VegetationScatter.count_vegetation_channels_gpu(occupancy, 0.5)
	if high_channel_counts.size() != 4 or high_channel_counts[0] != 0 or high_channel_counts[1] != 0 or high_channel_counts[2] != 1 or high_channel_counts[3] != 0:
		push_error("[VegetationScatterChannelMaskGPU] high-threshold channel counts mismatch: %s" % str(Array(high_channel_counts)))
		quit(1)
		return
	var all_mask := VegetationScatter.make_vegetation_all_channel_mask_gpu(occupancy, 0.01, Vector2i(12, 10))
	if all_mask == null or all_mask.is_empty() or all_mask.get_width() != 12 or all_mask.get_height() != 10 or all_mask.get_format() != Image.FORMAT_RGBAH:
		push_error("[VegetationScatterChannelMaskGPU] all-channel mask output contract failed")
		quit(1)
		return
	var all_p := all_mask.get_pixelv(Vector2i(1, 2))
	if all_p.r <= 0.09 or all_p.g <= 0.19 or all_p.b <= 0.7 or all_p.a <= 0.39:
		push_error("[VegetationScatterChannelMaskGPU] all-channel mask should preserve active channels")
		quit(1)
		return
	if all_mask.get_pixelv(Vector2i(2, 1)).b > 0.001:
		push_error("[VegetationScatterChannelMaskGPU] all-channel mask should zero below-threshold blue")
		quit(1)
		return
	if all_mask.get_pixelv(Vector2i(10, 8)) != Color(0.0, 0.0, 0.0, 0.0):
		push_error("[VegetationScatterChannelMaskGPU] all-channel mask should clear pixels outside source bounds")
		quit(1)
		return
	var all_combined := VegetationScatter.make_vegetation_all_channel_mask_with_counts_gpu(occupancy, 0.01, Vector2i(12, 10))
	if all_combined.is_empty():
		push_error("[VegetationScatterChannelMaskGPU] all-channel combined path failed")
		quit(1)
		return
	var all_combined_mask: Image = all_combined.get("mask", null)
	var all_combined_counts: PackedInt32Array = all_combined.get("channel_counts", PackedInt32Array())
	if all_combined_mask == null or all_combined_mask.is_empty() or all_combined_counts.size() != 4:
		push_error("[VegetationScatterChannelMaskGPU] all-channel combined output contract failed")
		quit(1)
		return
	if all_combined_counts[0] != 2 or all_combined_counts[1] != 3 or all_combined_counts[2] != 1 or all_combined_counts[3] != 2:
		push_error("[VegetationScatterChannelMaskGPU] all-channel combined counts mismatch: %s" % str(Array(all_combined_counts)))
		quit(1)
		return
	if all_combined_mask.get_pixelv(Vector2i(1, 2)).b <= 0.7 or all_combined_mask.get_pixelv(Vector2i(10, 8)) != Color(0.0, 0.0, 0.0, 0.0):
		push_error("[VegetationScatterChannelMaskGPU] all-channel combined mask values are incorrect")
		quit(1)
		return
	var split_masks := VegetationScatter.make_vegetation_split_channel_masks_gpu(occupancy, 0.01, Vector2i(12, 10))
	if split_masks.size() != 4:
		push_error("[VegetationScatterChannelMaskGPU] split channel masks path failed")
		quit(1)
		return
	for split_mask in split_masks:
		if split_mask == null or split_mask.is_empty() or split_mask.get_width() != 12 or split_mask.get_height() != 10 or split_mask.get_format() != Image.FORMAT_RF:
			push_error("[VegetationScatterChannelMaskGPU] split channel mask output contract failed")
			quit(1)
			return
	if split_masks[0].get_pixelv(Vector2i(1, 2)).r <= 0.09 or split_masks[1].get_pixelv(Vector2i(3, 3)).r <= 0.29:
		push_error("[VegetationScatterChannelMaskGPU] split masks should preserve active red/green channels")
		quit(1)
		return
	if split_masks[2].get_pixelv(Vector2i(1, 2)).r <= 0.7 or split_masks[3].get_pixelv(Vector2i(1, 2)).r <= 0.39:
		push_error("[VegetationScatterChannelMaskGPU] split masks should preserve active blue/alpha channels")
		quit(1)
		return
	if split_masks[2].get_pixelv(Vector2i(2, 1)).r > 0.001:
		push_error("[VegetationScatterChannelMaskGPU] split masks should zero below-threshold blue")
		quit(1)
		return
	if split_masks[0].get_pixelv(Vector2i(10, 8)).r > 0.001 or split_masks[3].get_pixelv(Vector2i(10, 8)).r > 0.001:
		push_error("[VegetationScatterChannelMaskGPU] split masks should clear pixels outside source bounds")
		quit(1)
		return
	var split_combined := VegetationScatter.make_vegetation_split_channel_masks_with_counts_gpu(occupancy, 0.01, Vector2i(12, 10))
	if split_combined.is_empty():
		push_error("[VegetationScatterChannelMaskGPU] split masks/counts path failed")
		quit(1)
		return
	var split_combined_masks: Array = split_combined.get("masks", [])
	var split_combined_counts: PackedInt32Array = split_combined.get("channel_counts", PackedInt32Array())
	if split_combined_masks.size() != 4 or split_combined_counts.size() != 4:
		push_error("[VegetationScatterChannelMaskGPU] split masks/counts output contract failed")
		quit(1)
		return
	if split_combined_counts[0] != 2 or split_combined_counts[1] != 3 or split_combined_counts[2] != 1 or split_combined_counts[3] != 2:
		push_error("[VegetationScatterChannelMaskGPU] split masks/counts mismatch: %s" % str(Array(split_combined_counts)))
		quit(1)
		return
	if (split_combined_masks[2] as Image).get_pixelv(Vector2i(1, 2)).r <= 0.7 or (split_combined_masks[3] as Image).get_pixelv(Vector2i(10, 8)).r > 0.001:
		push_error("[VegetationScatterChannelMaskGPU] split masks/counts mask values are incorrect")
		quit(1)
		return

	print("[VegetationScatterChannelMaskGPU] OK: selected channel copied, thresholded, counted, combined, channel-counted, all-channel-masked, all-channel-combined, split-masked, split-counted, bounded, and read back")
	quit(0)
