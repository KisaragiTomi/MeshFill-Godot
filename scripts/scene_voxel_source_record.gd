extends RefCounted

## source record 归一化入口 prepare_source_record() 已随 CPU 入口盖章链删除（2026-08-10）；
## 本文件只剩 committed SV 投影键的单一命名源。

static func scene_voxel_key(slice_index: int, voxel_px: Vector2i) -> String:
	return "%d:%d:%d" % [slice_index, voxel_px.x, voxel_px.y]
