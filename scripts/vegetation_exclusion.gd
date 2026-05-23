class_name SceneVoxelCommitter
extends "res://scripts/godot_compute_shader_base.gd"

const VOXEL_OCCUPIED_EPSILON := 0.01
const SCENE_VOXEL_RUNTIME_TILE_SIZE := 16
const CHANNEL_COUNT := 4
const CHANNEL_ENTRIES_KEY := "channel_entries"
const SharedPropertyTypeScript := preload("res://scripts/shared_property_type.gd")

var _base_res: int  ## Base resolution for world↔pixel coordinate mapping
var _capture_size: float

## Packed RGBA occupancy: one value per explicit channel.
var _occupancy: Image

## Coarse solid collision field for mutually exclusive final placement.
## This is intentionally separate from channel occupancy.
var _collision_field: Image

## GPU resources
var _sampler: RID
var _shader_import: RID
var _pipeline_import: RID
var _shader_filter: RID
var _pipeline_filter: RID
var _gpu_ready: bool = false


func _init(base_resolution: int, capture_size: float, enable_gpu: bool = true) -> void:
	_base_res = base_resolution
	_capture_size = capture_size
	_occupancy = Image.create(_base_res, _base_res, false, Image.FORMAT_RGBAH)
	_occupancy.fill(Color(0.0, 0.0, 0.0, 0.0))
	_collision_field = Image.create(_base_res, _base_res, false, Image.FORMAT_RF)
	_collision_field.fill(Color(0.0, 0.0, 0.0, 0.0))
	if enable_gpu:
		_init_gpu()


func _init_gpu() -> void:
	log_name = "SceneVoxelCommitter"
	if not ensure_device(true, false):
		_gpu_fatal("Failed to create RenderingDevice — GPU compute required")
		return

	_sampler = create_linear_sampler()

	_shader_import = load_compute_shader("res://shaders/channel_import_mask.glsl")
	if _shader_import.is_valid():
		_pipeline_import = create_compute_pipeline(_shader_import)

	_shader_filter = load_compute_shader("res://shaders/channel_filter_candidates.glsl")
	if _shader_filter.is_valid():
		_pipeline_filter = create_compute_pipeline(_shader_filter)

	_gpu_ready = _shader_import.is_valid() and _shader_filter.is_valid()
	if _gpu_ready:
		print("[SceneVoxelCommitter] GPU compute ready (2 shaders loaded)")
	else:
		_gpu_fatal("One or more compute shaders failed to compile")


func _gpu_fatal(msg: String) -> void:
	var full := "[SceneVoxelCommitter] GPU ERROR: %s" % msg
	push_error(full)
	OS.alert(full, "SceneVoxelCommitter — GPU Required")
	_gpu_ready = false


func _free_gpu() -> void:
	dispose()
	_pipeline_import = RID()
	_shader_import = RID()
	_pipeline_filter = RID()
	_shader_filter = RID()
	_sampler = RID()
	_gpu_ready = false


func _is_valid_channel(channel: int) -> bool:
	return channel >= 0 and channel < CHANNEL_COUNT


func import_mask_channel(channel: int, mask_img: Image, complexity: float = 1.0) -> void:
	assert(_gpu_ready, "[SceneVoxelCommitter] GPU not ready — cannot import mask")
	if not _is_valid_channel(channel):
		push_error("[SceneVoxelCommitter] Invalid channel: %d" % channel)
		return
	_gpu_import_mask(channel, clampf(complexity, 0.0, 1.0), mask_img)


func _gpu_import_mask(channel: int, complexity: float, mask_img: Image) -> void:
	var tex_src := upload_texture_2d(mask_img)
	var tex_occ := create_rw_texture_2d(_base_res, _base_res, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT)
	# Upload current occupancy into rw texture
	var occ_rgba := _occupancy.duplicate()
	if occ_rgba.get_format() != Image.FORMAT_RGBAH:
		occ_rgba.convert(Image.FORMAT_RGBAH)
	_rd.texture_update(tex_occ, 0, occ_rgba.get_data())

	var set0 := create_uniform_set([make_sampler_uniform(0, _sampler, tex_src)], _shader_import, 0)
	var set1 := create_uniform_set([make_image_uniform(0, tex_occ)], _shader_import, 1)

	var push := PackedByteArray()
	push.resize(16)
	push.encode_s32(0, channel)
	push.encode_float(4, complexity)
	push.encode_float(8, 0.01)  # threshold
	push.encode_s32(12, _base_res)

	var groups := ceili(float(_base_res) / 32.0)
	var cl := begin_compute_list()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline_import)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_bind_uniform_set(cl, set1, 1)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, groups, groups, 1)
	end_compute_list()
	submit_and_sync()

	# Read back packed occupancy
	var data := _rd.texture_get_data(tex_occ, 0)
	_occupancy = Image.create_from_data(_base_res, _base_res, false, Image.FORMAT_RGBAH, data)

	gc_frame()


static func profile_channel(
	channel: int,
	radius: float = 0.2,
	color: Color = Color.WHITE,
	complexity: float = 1.0,
	y_min: float = 0.0,
	y_max: float = 1.0,
	subdivisions: int = 1
) -> Array[Dictionary]:
	var c := color
	var v := clampf(complexity, 0.0, 1.0)
	c.a = v
	return [{
		"channel": clampi(channel, 0, CHANNEL_COUNT - 1),
		"radius": radius,
		"color": c,
		"complexity": v,
		"y_min": y_min,
		"y_max": y_max,
		"subdivisions": maxi(subdivisions, 1),
	}]


static func profile_custom(entries: Array[Dictionary]) -> Array[Dictionary]:
	return entries


static func _profile_entry_color(entry: Dictionary, fallback: Color = Color.WHITE) -> Color:
	var color := SharedPropertyTypeScript.color_from_value(entry.get("color", fallback), fallback)
	var complexity := clampf(float(entry.get("complexity", color.a)), 0.0, 1.0)
	color.a = complexity
	return color


static func _profile_entry_complexity(entry: Dictionary, fallback: float = 1.0) -> float:
	if entry.has("complexity"):
		return clampf(float(entry.complexity), 0.0, 1.0)
	if entry.has("color"):
		return clampf(_profile_entry_color(entry, Color(1.0, 1.0, 1.0, fallback)).a, 0.0, 1.0)
	return clampf(fallback, 0.0, 1.0)


## Create a coarse collision voxel entry for rigid trunk-like parts.
## The effective radius is opened by erosion first, then expanded by dilation.
static func collision_trunk(
	radius: float,
	y_min: float = 0.0,
	y_max: float = 2.0,
	erosion_radius: float = 0.0,
	dilation_radius: float = 0.0
) -> Array[Dictionary]:
	return [{
		"shape": "cylinder",
		"radius": radius,
		"y_min": y_min,
		"y_max": y_max,
		"erosion_radius": erosion_radius,
		"dilation_radius": dilation_radius,
		"value": 1.0,
	}]


## ─── Core Operations (GPU only) ───

## Build a vec4 profile mask from a profile: 1.0 in channels this profile uses.
func _profile_to_mask(profile: Array[Dictionary]) -> Color:
	var mask := Color(0.0, 0.0, 0.0, 0.0)
	for entry in profile:
		var ch := int(entry.get("channel", -1))
		if _is_valid_channel(ch):
			mask[ch] = 1.0
	return mask


## Convert world-meter radius to pixels at base resolution.
func _radius_to_px(radius_m: float) -> int:
	var pixel_size := _capture_size / float(_base_res)
	return maxi(1, ceili(radius_m / pixel_size))


func _collision_effective_radius(collision: Dictionary) -> float:
	var radius := maxf(float(collision.get("radius", 0.0)), 0.0)
	var erosion := maxf(float(collision.get("erosion_radius", 0.0)), 0.0)
	var dilation := maxf(float(collision.get("dilation_radius", 0.0)), 0.0)
	if erosion > 0.0 and radius <= erosion:
		return 0.0
	return maxf(radius - erosion, 0.0) + dilation


func _is_float_collision_voxel(collision: Dictionary) -> bool:
	return collision.has("voxel") or collision.has("local_pos") or collision.has("voxel_offset")


func _vector3i_from_value(value, fallback: Vector3i = Vector3i.ZERO) -> Vector3i:
	if value is Vector3i:
		return value as Vector3i
	if value is Vector3:
		var v := value as Vector3
		return Vector3i(roundi(v.x), roundi(v.y), roundi(v.z))
	if value is Array:
		var arr := value as Array
		if arr.size() >= 3:
			return Vector3i(int(arr[0]), int(arr[1]), int(arr[2]))
	if value is Dictionary:
		var dict := value as Dictionary
		return Vector3i(
			int(dict.get("x", fallback.x)),
			int(dict.get("y", fallback.y)),
			int(dict.get("z", fallback.z))
		)
	return fallback


func _collision_local_voxel(collision: Dictionary) -> Vector3i:
	return _vector3i_from_value(collision.get("voxel", collision.get("local_pos", collision.get("voxel_offset", Vector3i.ZERO))), Vector3i.ZERO)


func _collision_layer_base_px(base_px: Vector2i, collision: Dictionary) -> Vector2i:
	if not _is_float_collision_voxel(collision):
		return base_px
	var local := _collision_local_voxel(collision)
	return Vector2i(
		clampi(base_px.x + local.x, 0, _base_res - 1),
		clampi(base_px.y + local.z, 0, _base_res - 1)
	)


func _collision_radius_px(collision: Dictionary) -> int:
	if _is_float_collision_voxel(collision):
		return maxi(int(collision.get("radius_px", 0)), 0)
	if collision.has("radius_px"):
		return maxi(int(collision.radius_px), 1)
	return maxi(1, _radius_to_px(_collision_effective_radius(collision)))


func _normalize_collision_voxels(collision_voxels: Array, base_px: Vector2i = Vector2i(-1, -1)) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for raw_collision in collision_voxels:
		if not raw_collision is Dictionary:
			continue
		var collision := (raw_collision as Dictionary).duplicate(true)
		if not bool(collision.get("enabled", true)):
			continue
		if _is_float_collision_voxel(collision):
			var local := _collision_local_voxel(collision)
			collision["voxel"] = local
			collision["local_pos"] = local
			if not collision.has("value") and collision.has("collision_degree"):
				collision["value"] = clampf(float(collision.get("collision_degree", 255)) / 255.0, 0.0, 1.0)
			collision["value"] = clampf(float(collision.get("value", 1.0)), 0.0, 1.0)
			collision["radius_px"] = maxi(int(collision.get("radius_px", 0)), 0)
			collision["effective_radius"] = 0.0
			if not collision.has("slice_index"):
				collision["slice_index"] = local.y
			if base_px.x >= 0 and base_px.y >= 0:
				collision["base_pixel"] = _collision_layer_base_px(base_px, collision)
			result.append(collision)
			continue
		var effective_radius := _collision_effective_radius(collision)
		if effective_radius <= 0.0:
			continue
		collision["shape"] = str(collision.get("shape", "cylinder"))
		collision["radius"] = maxf(float(collision.get("radius", effective_radius)), 0.0)
		collision["effective_radius"] = effective_radius
		collision["radius_px"] = _radius_to_px(effective_radius)
		collision["value"] = clampf(float(collision.get("value", 1.0)), 0.0, 1.0)
		if not collision.has("y_min"):
			collision["y_min"] = 0.0
		if not collision.has("y_max"):
			collision["y_max"] = 2.0
		if base_px.x >= 0 and base_px.y >= 0:
			collision["base_pixel"] = base_px
		result.append(collision)
	return result


func _make_source_collision_voxels(base_px: Vector2i, collision_voxels: Array, rec: Dictionary = {}) -> Array[Dictionary]:
	var updated: Array[Dictionary] = []
	var source_type := _source_type_from_record(rec)
	if source_type == "TargetSceneVoxel":
		return updated
	var xz_res := _base_res
	if not _volume.is_empty():
		xz_res = int(_volume.get("xz_res", _base_res))
	var layers := _normalize_collision_voxels(collision_voxels, base_px)
	for layer in layers:
		var value := clampf(float(layer.get("value", 1.0)), 0.0, 1.0)
		var radius_px := _collision_radius_px(layer)
		var layer_base_px := _collision_layer_base_px(base_px, layer)
		var source_layer := layer.duplicate(true)
		source_layer["type"] = "CollisionVoxel"
		source_layer["occupied"] = value > VOXEL_OCCUPIED_EPSILON
		source_layer["value"] = value
		source_layer["base_pixel"] = layer_base_px
		source_layer["voxel_xz"] = _volume_px_from_base(layer_base_px, xz_res)
		source_layer["volume_xz_resolution"] = xz_res
		source_layer["radius_px"] = radius_px
		source_layer["collision_shape"] = str(layer.get("shape", "voxel" if _is_float_collision_voxel(layer) else "cylinder"))
		source_layer["collision_radius"] = layer.get("radius", 0.0)
		source_layer["effective_radius"] = layer.get("effective_radius", 0.0)
		source_layer["source_voxel_type"] = source_type
		source_layer["source_kind"] = _source_kind_from_record(rec)
		source_layer["producer_stage"] = _producer_stage_from_record(rec)
		source_layer["record_id"] = str(rec.get("id", ""))
		source_layer["auto_object_id"] = str(rec.get("auto_object_id", rec.get("auto_id", rec.get("id", ""))))
		source_layer["auto_instance_id"] = int(rec.get("auto_instance_id", rec.get("instance_id", 0)))
		source_layer["instance_mesh_id"] = int(rec.get("instance_mesh_id", rec.get("mesh_instance_id", rec.get("instance_id", 0))))
		source_layer["collision_buffer_applied"] = false
		updated.append(source_layer)
	return updated


func _collision_area_blocked(base_px: Vector2i, collision_voxels: Array) -> bool:
	var layers := _normalize_collision_voxels(collision_voxels, base_px)
	if layers.is_empty():
		return false
	for layer in layers:
		var radius_px := _collision_radius_px(layer)
		var layer_base_px := _collision_layer_base_px(base_px, layer)
		for dy in range(-radius_px, radius_px + 1):
			for dx in range(-radius_px, radius_px + 1):
				if dx * dx + dy * dy > radius_px * radius_px:
					continue
				var tx := clampi(layer_base_px.x + dx, 0, _base_res - 1)
				var ty := clampi(layer_base_px.y + dy, 0, _base_res - 1)
				if _collision_field.get_pixelv(Vector2i(tx, ty)).r > 0.01:
					return true
	return false


func _collision_voxel_key(px: Vector2i) -> String:
	return "collision:%d:%d" % [px.x, px.y]


func _ensure_volume_collision_layer() -> void:
	if _volume.is_empty():
		return
	var xz_res: int = _volume.xz_res
	if not _volume.has("collision_field"):
		var img := Image.create(xz_res, xz_res, false, Image.FORMAT_RF)
		img.fill(Color(0.0, 0.0, 0.0, 0.0))
		_volume["collision_field"] = img
	if not _volume.has("collision_voxels"):
		_volume["collision_voxels"] = {}


func _resample_collision_field(xz_res: int) -> Image:
	var img := Image.create(xz_res, xz_res, false, Image.FORMAT_RF)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	for z in range(xz_res):
		for x in range(xz_res):
			var bx := clampi(int(float(x) / float(xz_res) * float(_base_res)), 0, _base_res - 1)
			var bz := clampi(int(float(z) / float(xz_res) * float(_base_res)), 0, _base_res - 1)
			var v := _collision_field.get_pixelv(Vector2i(bx, bz)).r
			img.set_pixelv(Vector2i(x, z), Color(v, 0.0, 0.0, 0.0))
	return img


func _stamp_collision_volume(base_px: Vector2i, radius_px: int, value: float, rec: Dictionary, layer: Dictionary) -> Vector2i:
	if _volume.is_empty():
		return base_px
	_ensure_volume_collision_layer()
	var xz_res: int = _volume.xz_res
	var collision_img: Image = _volume.collision_field
	var voxel_px := _volume_px_from_base(base_px, xz_res)
	var radius_vol := _volume_radius_from_base_radius(radius_px, xz_res)
	var collision_voxels: Dictionary = _volume.collision_voxels
	for dz in range(-radius_vol, radius_vol + 1):
		for dx in range(-radius_vol, radius_vol + 1):
			if dx * dx + dz * dz > radius_vol * radius_vol:
				continue
			var tx := clampi(voxel_px.x + dx, 0, xz_res - 1)
			var tz := clampi(voxel_px.y + dz, 0, xz_res - 1)
			var px := Vector2i(tx, tz)
			var current := collision_img.get_pixelv(px).r
			if value > current:
				collision_img.set_pixelv(px, Color(value, 0.0, 0.0, 0.0))
				var scene_collision := {
					"type": "CollisionVoxel",
					"occupied": true,
					"value": value,
					"base_pixel": base_px,
					"voxel_xz": px,
					"slice_index": int(layer.get("slice_index", 0)),
					"radius_px": radius_px,
					"collision_shape": str(layer.get("shape", "voxel" if _is_float_collision_voxel(layer) else "cylinder")),
					"collision_radius": layer.get("radius", 0.0),
					"effective_radius": layer.get("effective_radius", 0.0),
					"source_voxel_type": str(layer.get("source_voxel_type", rec.get("source_voxel_type", ""))),
					"source_kind": str(layer.get("source_kind", rec.get("source_kind", ""))),
					"producer_stage": str(layer.get("producer_stage", rec.get("producer_stage", ""))),
					"record_id": str(layer.get("record_id", rec.get("id", ""))),
					"auto_object_id": str(rec.get("auto_object_id", rec.get("auto_id", rec.get("id", "")))),
					"auto_instance_id": int(rec.get("auto_instance_id", rec.get("instance_id", 0))),
					"instance_mesh_id": int(rec.get("instance_mesh_id", rec.get("mesh_instance_id", 0))),
				}
				collision_voxels[_collision_voxel_key(px)] = scene_collision
				_mark_scene_voxel_runtime_tile_dirty(int(scene_collision.slice_index), px, "collision")
	_volume["collision_field"] = collision_img
	_volume["collision_voxels"] = collision_voxels
	return voxel_px


func _stamp_collision_voxel_layer(base_px: Vector2i, source_layer: Dictionary, rec: Dictionary = {}) -> Dictionary:
	var normalized := _normalize_collision_voxels([source_layer], base_px)
	if normalized.is_empty():
		return {}
	var layer := normalized[0]
	var radius_px := _collision_radius_px(layer)
	var value := clampf(float(layer.get("value", 1.0)), 0.0, 1.0)
	var layer_base_px := _collision_layer_base_px(base_px, layer)
	for dy in range(-radius_px, radius_px + 1):
		for dx in range(-radius_px, radius_px + 1):
			if dx * dx + dy * dy > radius_px * radius_px:
				continue
			var tx := clampi(layer_base_px.x + dx, 0, _base_res - 1)
			var ty := clampi(layer_base_px.y + dy, 0, _base_res - 1)
			var px := Vector2i(tx, ty)
			var cur := _collision_field.get_pixelv(px).r
			if value > cur:
				_collision_field.set_pixelv(px, Color(value, 0.0, 0.0, 0.0))
	var voxel_px := _stamp_collision_volume(layer_base_px, radius_px, value, rec, layer)
	layer["base_pixel"] = layer_base_px
	layer["voxel_xz"] = voxel_px
	layer["volume_xz_resolution"] = int(_volume.xz_res) if not _volume.is_empty() else _base_res
	layer["collision_buffer_applied"] = true
	return layer


func _stamp_collision_voxels(base_px: Vector2i, collision_voxels: Array, rec: Dictionary = {}) -> Array[Dictionary]:
	var updated: Array[Dictionary] = []
	var layers := _normalize_collision_voxels(collision_voxels, base_px)
	for layer in layers:
		var stamped := _stamp_collision_voxel_layer(base_px, layer, rec)
		if not stamped.is_empty():
			updated.append(stamped)
	return updated


func _clear_collision_cache() -> void:
	_collision_field.fill(Color(0.0, 0.0, 0.0, 0.0))
	if _volume.is_empty():
		return
	var xz_res: int = _volume.xz_res
	var img := Image.create(xz_res, xz_res, false, Image.FORMAT_RF)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	_volume["collision_field"] = img
	_volume["collision_voxels"] = {}


func _rebuild_collision_cache_from_scene_voxels(scene_voxels: Dictionary) -> void:
	_clear_collision_cache()
	if _volume.is_empty():
		return
	var stamped_footprints: Dictionary = {}
	for key in scene_voxels.keys():
		var scene_voxel = scene_voxels[key]
		if not scene_voxel is Dictionary:
			continue
		var voxel := scene_voxel as Dictionary
		var collision_layers: Array = voxel.get("collision_voxels", [])
		if collision_layers.is_empty():
			continue
		var base_px = voxel.get("base_pixel", voxel.get("voxel_xz", Vector2i.ZERO))
		if not base_px is Vector2i:
			continue
		var stamp_key := "%d:%d:%s" % [base_px.x, base_px.y, str(collision_layers)]
		if stamped_footprints.has(stamp_key):
			continue
		stamped_footprints[stamp_key] = true
		_stamp_collision_voxels(base_px, collision_layers, voxel)


func _stamp_occupancy_channel(base_px: Vector2i, channel: int, radius_px: int, complexity: float) -> void:
	if not _is_valid_channel(channel):
		return
	var v := clampf(complexity, 0.0, 1.0)
	var r_px := maxi(radius_px, 1)
	for dy in range(-r_px, r_px + 1):
		for dx in range(-r_px, r_px + 1):
			if dx * dx + dy * dy > r_px * r_px:
				continue
			var tx := clampi(base_px.x + dx, 0, _base_res - 1)
			var ty := clampi(base_px.y + dy, 0, _base_res - 1)
			var cur: Color = _occupancy.get_pixelv(Vector2i(tx, ty))
			cur[channel] = maxf(cur[channel], v)
			_occupancy.set_pixelv(Vector2i(tx, ty), cur)


func _stamp_occupancy(base_px: Vector2i, profile: Array[Dictionary]) -> void:
	for entry in profile:
		var ch := int(entry.get("channel", -1))
		if not _is_valid_channel(ch):
			continue
		var complexity := _profile_entry_complexity(entry, 1.0)
		var r_px := _radius_to_px(float(entry.get("radius", 0.0)))
		_stamp_occupancy_channel(base_px, ch, r_px, complexity)


## ─── GPU Candidate Filtering ───

## Returns an Image at _base_res where R = 1.0 if candidate, 0.0 if blocked.
func _gpu_filter_candidates(profile: Array[Dictionary]) -> Image:
	var tex_occ := upload_texture_2d(_occupancy)
	var tex_out := create_rw_texture_2d(_base_res, _base_res, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT)

	var set0 := create_uniform_set([make_sampler_uniform(0, _sampler, tex_occ)], _shader_filter, 0)
	var set1 := create_uniform_set([make_image_uniform(0, tex_out)], _shader_filter, 1)

	var pmask := _profile_to_mask(profile)
	var push := PackedByteArray()
	push.resize(32)
	push.encode_float(0, pmask.r)
	push.encode_float(4, pmask.g)
	push.encode_float(8, pmask.b)
	push.encode_float(12, pmask.a)
	push.encode_float(16, 0.01)  # block_threshold
	push.encode_s32(20, _base_res)
	push.encode_s32(24, 0)  # pad0
	push.encode_s32(28, 0)  # pad1

	var groups := ceili(float(_base_res) / 32.0)
	var cl := begin_compute_list()
	_rd.compute_list_bind_compute_pipeline(cl, _pipeline_filter)
	_rd.compute_list_bind_uniform_set(cl, set0, 0)
	_rd.compute_list_bind_uniform_set(cl, set1, 1)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, groups, groups, 1)
	end_compute_list()
	submit_and_sync()

	var data := _rd.texture_get_data(tex_out, 0)
	var result := Image.create_from_data(_base_res, _base_res, false, Image.FORMAT_RGBAH, data)

	gc_frame()
	return result


## ─── Scatter ───

## GPU filter → CPU Poisson disk → stamp.
## Returns Array[Dictionary] compatible with VegetationScatter output.
func scatter(
	profile: Array[Dictionary],
	scene_depth_img: Image,
	max_height: float,
	min_dist: float = 3.0,
	max_scale: float = 4.0,
	max_count: int = 500,
	veg_type: String = "tree",
	collision_voxels: Array[Dictionary] = []
) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var pixel_size := _capture_size / float(_base_res)
	var min_dist_px := min_dist / pixel_size
	var min_dist_sq := min_dist_px * min_dist_px

	var placed_positions: Array[Vector2] = []
	var candidates: Array[Vector2i] = []

	# Step 1: GPU candidate filtering (occupancy only)
	assert(_gpu_ready, "[SceneVoxelCommitter] GPU not ready — cannot scatter")
	var cand_img := _gpu_filter_candidates(profile)
	for y in range(_base_res):
		for x in range(_base_res):
			if cand_img.get_pixelv(Vector2i(x, y)).r > 0.5:
				candidates.append(Vector2i(x, y))

	candidates.shuffle()

	# Step 2: Poisson-disk placement (CPU — inherently sequential)
	for cpx in candidates:
		if results.size() >= max_count:
			break
		var pos2 := Vector2(float(cpx.x), float(cpx.y))

		var too_close := false
		for placed in placed_positions:
			if pos2.distance_squared_to(placed) < min_dist_sq:
				too_close = true
				break
		if too_close:
			continue

		if _collision_area_blocked(cpx, collision_voxels):
			continue

		# Re-check: read packed occupancy directly for profiled channels
		var occ_val: Color = _occupancy.get_pixelv(cpx)
		var pmask := _profile_to_mask(profile)
		var blocked := false
		for ch in range(4):
			if pmask[ch] > 0.0 and occ_val[ch] > 0.01:
				blocked = true
				break
		if blocked:
			continue

		placed_positions.append(pos2)
		_stamp_occupancy(cpx, profile)
		var mesh_id := "%s_%d" % [veg_type, _mesh_asset_voxel_records.size()]
		var source_collision_record := {
			"id": mesh_id,
			"type": veg_type,
			"source_voxel_type": "AutoSceneVoxel",
			"source_kind": "scatter",
			"producer_stage": "vegetation_scatter",
		}
		_stamp_collision_voxels(cpx, collision_voxels, source_collision_record)
		var inst_collision_voxels := _make_source_collision_voxels(cpx, collision_voxels, source_collision_record)

		var terrain_h := max_height - scene_depth_img.get_pixelv(cpx).r
		var scale_val := randf_range(max_scale * 0.4, max_scale)

		var half := _capture_size / 2.0
		var world_pos := Vector3(
			float(cpx.x) / float(_base_res) * _capture_size - half,
			terrain_h,
			float(cpx.y) / float(_base_res) * _capture_size - half
		)

		var inst_channel_entries: Array[Dictionary] = []
		var inst_color := Color(0.0, 0.0, 0.0, 0.0)
		var inst_complexity := 0.0
		for entry in profile:
			var ch := int(entry.get("channel", -1))
			if not _is_valid_channel(ch):
				continue
			var entry_color := _profile_entry_color(entry)
			var entry_complexity := _profile_entry_complexity(entry, entry_color.a)
			entry_color.a = entry_complexity
			var channel_entry := entry.duplicate(true)
			channel_entry["channel"] = ch
			channel_entry["radius"] = float(entry.get("radius", 0.0))
			channel_entry["complexity"] = entry_complexity
			channel_entry["color"] = entry_color
			if not channel_entry.has("y_min"):
				channel_entry["y_min"] = 0.0
			if not channel_entry.has("y_max"):
				channel_entry["y_max"] = 1.0
			if not channel_entry.has("subdivisions"):
				channel_entry["subdivisions"] = 1
			inst_channel_entries.append(channel_entry)
			inst_color += entry_color
			inst_complexity = maxf(inst_complexity, entry_complexity)
		if inst_channel_entries.size() > 0:
			inst_color /= float(inst_channel_entries.size())
			inst_color.a = inst_complexity

		var voxel_write_spec := _register_mesh_asset_voxel_record(_make_mesh_asset_voxel_record(
			mesh_id,
			veg_type,
			cpx,
			world_pos,
			inst_color,
			inst_complexity,
			inst_channel_entries,
			scale_val,
			inst_collision_voxels
		))

		var rotation_y := randf_range(0.0, 360.0)
		results.append({
			"id": mesh_id,
			"position": world_pos,
			"rotation_mode": "Y",
			"rotation_degrees": Vector3(0.0, rotation_y, 0.0),
			"rotation_y": rotation_y,
			"scale": Vector3.ONE * scale_val,
			"type": veg_type,
			"color": inst_color,
			"complexity": inst_complexity,
			"collision_voxels": inst_collision_voxels,
			"voxel_write_spec": voxel_write_spec,
			"channel_entries": voxel_write_spec.get(CHANNEL_ENTRIES_KEY, []),
		})

	return results


func scatter_from_mask(
	profile: Array[Dictionary],
	candidate_mask_img: Image,
	scene_depth_img: Image,
	max_height: float,
	min_dist: float = 3.0,
	max_scale: float = 4.0,
	max_count: int = 500,
	veg_type: String = "tree",
	collision_voxels: Array[Dictionary] = [],
	min_mask_value: float = 0.01
) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if candidate_mask_img == null:
		return results
	var mask_w := candidate_mask_img.get_width()
	var mask_h := candidate_mask_img.get_height()
	if mask_w <= 0 or mask_h <= 0:
		return results

	var pixel_size := _capture_size / float(_base_res)
	var min_dist_px := min_dist / pixel_size
	var min_dist_sq := min_dist_px * min_dist_px

	var placed_positions: Array[Vector2] = []
	var candidates: Array[Vector2i] = []
	for y in range(_base_res):
		for x in range(_base_res):
			var sx := clampi(floori(float(x) / float(_base_res) * float(mask_w)), 0, mask_w - 1)
			var sy := clampi(floori(float(y) / float(_base_res) * float(mask_h)), 0, mask_h - 1)
			if candidate_mask_img.get_pixelv(Vector2i(sx, sy)).r > min_mask_value:
				candidates.append(Vector2i(x, y))

	candidates.shuffle()

	for cpx in candidates:
		if results.size() >= max_count:
			break
		var pos2 := Vector2(float(cpx.x), float(cpx.y))

		var too_close := false
		for placed in placed_positions:
			if pos2.distance_squared_to(placed) < min_dist_sq:
				too_close = true
				break
		if too_close:
			continue

		if _collision_area_blocked(cpx, collision_voxels):
			continue

		var occ_val: Color = _occupancy.get_pixelv(cpx)
		var pmask := _profile_to_mask(profile)
		var blocked := false
		for ch in range(4):
			if pmask[ch] > 0.0 and occ_val[ch] > 0.01:
				blocked = true
				break
		if blocked:
			continue

		placed_positions.append(pos2)
		_stamp_occupancy(cpx, profile)
		var mesh_id := "%s_%d" % [veg_type, _mesh_asset_voxel_records.size()]
		var source_collision_record := {
			"id": mesh_id,
			"type": veg_type,
			"source_voxel_type": "AutoSceneVoxel",
			"source_kind": "scatter",
			"producer_stage": "vegetation_scatter",
		}
		_stamp_collision_voxels(cpx, collision_voxels, source_collision_record)
		var inst_collision_voxels := _make_source_collision_voxels(cpx, collision_voxels, source_collision_record)

		var terrain_h := max_height - scene_depth_img.get_pixelv(cpx).r
		var scale_val := randf_range(max_scale * 0.4, max_scale)

		var half := _capture_size / 2.0
		var world_pos := Vector3(
			float(cpx.x) / float(_base_res) * _capture_size - half,
			terrain_h,
			float(cpx.y) / float(_base_res) * _capture_size - half
		)

		var inst_channel_entries: Array[Dictionary] = []
		var inst_color := Color(0.0, 0.0, 0.0, 0.0)
		var inst_complexity := 0.0
		for entry in profile:
			var ch := int(entry.get("channel", -1))
			if not _is_valid_channel(ch):
				continue
			var entry_color := _profile_entry_color(entry)
			var entry_complexity := _profile_entry_complexity(entry, entry_color.a)
			entry_color.a = entry_complexity
			var channel_entry := entry.duplicate(true)
			channel_entry["channel"] = ch
			channel_entry["radius"] = float(entry.get("radius", 0.0))
			channel_entry["complexity"] = entry_complexity
			channel_entry["color"] = entry_color
			if not channel_entry.has("y_min"):
				channel_entry["y_min"] = 0.0
			if not channel_entry.has("y_max"):
				channel_entry["y_max"] = 1.0
			if not channel_entry.has("subdivisions"):
				channel_entry["subdivisions"] = 1
			inst_channel_entries.append(channel_entry)
			inst_color += entry_color
			inst_complexity = maxf(inst_complexity, entry_complexity)
		if inst_channel_entries.size() > 0:
			inst_color /= float(inst_channel_entries.size())
			inst_color.a = inst_complexity

		var voxel_write_spec := _register_mesh_asset_voxel_record(_make_mesh_asset_voxel_record(
			mesh_id,
			veg_type,
			cpx,
			world_pos,
			inst_color,
			inst_complexity,
			inst_channel_entries,
			scale_val,
			inst_collision_voxels
		))

		var rotation_y := randf_range(0.0, 360.0)
		results.append({
			"id": mesh_id,
			"position": world_pos,
			"rotation_mode": "Y",
			"rotation_degrees": Vector3(0.0, rotation_y, 0.0),
			"rotation_y": rotation_y,
			"scale": Vector3.ONE * scale_val,
			"type": veg_type,
			"color": inst_color,
			"complexity": inst_complexity,
			"collision_voxels": inst_collision_voxels,
			"voxel_write_spec": voxel_write_spec,
			"channel_entries": voxel_write_spec.get(CHANNEL_ENTRIES_KEY, []),
		})

	return results


## ─── Query & Debug ───


func get_occupancy() -> Image:
	return _occupancy


## Get the coarse collision field image.
func get_collision_field() -> Image:
	return _collision_field


func query_collision_voxel(wx: float, wz: float) -> Dictionary:
	var half := _capture_size / 2.0
	if _volume.is_empty():
		var base_px := Vector2i(
			clampi(int((wx + half) / _capture_size * float(_base_res)), 0, _base_res - 1),
			clampi(int((wz + half) / _capture_size * float(_base_res)), 0, _base_res - 1)
		)
		var base_v := _collision_field.get_pixelv(base_px).r
		return {
			"type": "CollisionVoxel",
			"occupied": base_v > 0.01,
			"value": base_v,
			"base_pixel": base_px,
			"voxel_xz": base_px,
			"volume_xz_resolution": _base_res,
		}

	var xz_res: int = _volume.xz_res
	var voxel_px := Vector2i(
		clampi(int((wx + half) / _capture_size * float(xz_res)), 0, xz_res - 1),
		clampi(int((wz + half) / _capture_size * float(xz_res)), 0, xz_res - 1)
	)
	var collision_img: Image = _volume.get("collision_field", _resample_collision_field(xz_res))
	var v := collision_img.get_pixelv(voxel_px).r
	var collision_voxels: Dictionary = _volume.get("collision_voxels", {})
	var key := _collision_voxel_key(voxel_px)
	if collision_voxels.has(key) and collision_voxels[key] is Dictionary:
		var collision := (collision_voxels[key] as Dictionary).duplicate(true)
		collision["occupied"] = v > 0.01
		collision["value"] = v
		return collision
	return {
		"type": "CollisionVoxel",
		"occupied": v > 0.01,
		"value": v,
		"voxel_xz": voxel_px,
		"volume_xz_resolution": xz_res,
	}


## Get every placed mesh's voxel_write_spec.
func get_mesh_asset_voxel_records() -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	for record in _mesh_asset_voxel_records:
		var typed_record := record as Dictionary
		records.append(typed_record.duplicate(true))
	return records


## Get one placed mesh's voxel_write_spec by id.
func get_mesh_asset_voxel_record(mesh_id: String) -> Dictionary:
	if not _mesh_asset_voxel_record_index.has(mesh_id):
		return {}
	var idx: int = _mesh_asset_voxel_record_index[mesh_id]
	var record: Dictionary = _mesh_asset_voxel_records[idx]
	return record.duplicate(true)


func get_mesh_asset_voxel_record_count() -> int:
	return _mesh_asset_voxel_records.size()


func _channel_entry_channel(entry: Dictionary) -> int:
	var ch := int(entry.get("channel", -1))
	if not _is_valid_channel(ch):
		return -1
	return ch


func _channel_entry_radius_px(entry: Dictionary) -> int:
	if entry.has("radius_px"):
		return maxi(int(entry.radius_px), 1)
	if entry.has("radius"):
		return _radius_to_px(float(entry.radius))
	return 1


func _volume_px_from_base(base_px: Vector2i, xz_res: int) -> Vector2i:
	return Vector2i(
		clampi(int(float(base_px.x) / float(_base_res) * float(xz_res)), 0, xz_res - 1),
		clampi(int(float(base_px.y) / float(_base_res) * float(xz_res)), 0, xz_res - 1)
	)


func _volume_radius_from_base_radius(radius_px: int, xz_res: int) -> int:
	if radius_px <= 0:
		return 0
	return maxi(1, ceili(float(radius_px) / float(_base_res) * float(xz_res)))


func _next_write_tick() -> int:
	return _generation_tick if _generation_tick > _committed_tick else _committed_tick + 1


func begin_generation_tick(tick: int = -1) -> int:
	var write_tick := tick if tick >= 0 else _next_write_tick()
	_generation_tick = write_tick
	_scene_voxel_runtime_dirty = true
	return write_tick


func _is_brush_source_kind(source_kind: String) -> bool:
	return ["brush", "manual_edit", "erase", "lock"].has(source_kind.to_lower())


func _is_target_source_kind(source_kind: String) -> bool:
	return ["target", "heightfield_target", "flood_target", "guidance"].has(source_kind.to_lower())


func _source_kind_from_record(record: Dictionary) -> String:
	var source_kind := str(record.get("source_kind", record.get("auto_source", record.get("placement_source", "")))).to_lower()
	if not source_kind.is_empty():
		return source_kind
	var record_type := str(record.get("type", ""))
	match record_type:
		"rock":
			return "rock_placement"
		"vegetation", "grass", "bush", "tree", "midstory_tree", "canopy_tree":
			return "scatter"
		_:
			return "auto"


func _source_type_from_record(record: Dictionary) -> String:
	var source_type := str(record.get("source_voxel_type", ""))
	if source_type == "AutoSceneVoxel" or source_type == "BrushSceneVoxel" or source_type == "TargetSceneVoxel":
		return source_type
	var kind := _source_kind_from_record(record)
	if _is_brush_source_kind(kind):
		return "BrushSceneVoxel"
	if _is_target_source_kind(kind):
		return "TargetSceneVoxel"
	return "AutoSceneVoxel"


func _producer_stage_from_record(record: Dictionary) -> String:
	var producer_stage := str(record.get("producer_stage", ""))
	if not producer_stage.is_empty():
		return producer_stage
	var source_kind := _source_kind_from_record(record)
	match source_kind:
		"rock_placement":
			return "rock_placement"
		"scatter":
			return "vegetation_scatter"
		"brush", "manual_edit", "erase", "lock":
			return "brush_edit"
		"target", "heightfield_target", "flood_target", "guidance":
			return "target_pipeline"
		_:
			return "meshfill"


func _prepare_source_record(record: Dictionary, tick: int) -> Dictionary:
	var rec := SharedPropertyTypeScript.apply_to_record(
		record,
		SharedPropertyTypeScript.normalize_shared_fields(record)
	)
	var write_tick := maxi(tick, 0)
	var max_read_tick := maxi(write_tick - 1, 0)
	var source_type := _source_type_from_record(rec)
	rec["source_voxel_type"] = source_type
	rec["source_kind"] = _source_kind_from_record(rec)
	rec["producer_stage"] = _producer_stage_from_record(rec)
	rec["generation_tick"] = write_tick
	rec["read_tick"] = clampi(int(rec.get("read_tick", max_read_tick)), 0, max_read_tick)
	rec["write_tick"] = write_tick
	if source_type == "BrushSceneVoxel":
		rec["auto_mix"] = clampf(float(rec.get("auto_mix", 0.0)), 0.0, 1.0)
		if not rec.has("modified_voxels"):
			rec["modified_voxels"] = []
	if source_type == "TargetSceneVoxel":
		rec["target_mix"] = clampf(float(rec.get("target_mix", 1.0)), 0.0, 1.0)
		rec["target_pipeline"] = str(rec.get("target_pipeline", rec.get("source_kind", "guidance")))
	return rec


func _source_priority(source_voxel: Dictionary) -> float:
	if source_voxel.has("priority"):
		return float(source_voxel.priority)
	var st := str(source_voxel.get("source_voxel_type", source_voxel.get("type", "")))
	if st == "BrushSceneVoxel":
		return 100.0
	return 10.0


func _source_beats_current(source_voxel: Dictionary, current) -> bool:
	if not current is Dictionary:
		return true
	var current_voxel := current as Dictionary
	var next_priority := _source_priority(source_voxel)
	var current_priority := _source_priority(current_voxel)
	if next_priority > current_priority:
		return true
	if next_priority < current_priority:
		return false
	return float(source_voxel.get("value", 0.0)) >= float(current_voxel.get("value", 0.0))


func _source_modifies_key(source_voxel: Dictionary, key: String) -> bool:
	var modified: Array = source_voxel.get("modified_voxels", [])
	if modified.is_empty():
		return true
	for item in modified:
		if item is String and str(item) == key:
			return true
		if item is Dictionary:
			var item_dict := item as Dictionary
			if str(item_dict.get("key", "")) == key:
				return true
			var item_slice := int(item_dict.get("slice_index", source_voxel.get("slice_index", -1)))
			var item_px = item_dict.get("voxel_xz", Vector2i(-1, -1))
			if item_px is Vector2i and _scene_voxel_key(item_slice, item_px) == key:
				return true
		if item is Vector2i:
			var item_key := _scene_voxel_key(int(source_voxel.get("slice_index", -1)), item)
			if item_key == key:
				return true
	return false


func _slice_indices_for_channel_entry(entry: Dictionary, channel: int) -> Array[int]:
	var indices: Array[int] = []
	if _volume.is_empty():
		return indices

	if entry.has("slice_indices"):
		var raw_indices: Array = entry.slice_indices
		for idx in raw_indices:
			var si := int(idx)
			if si >= 0 and si < int(_volume.total_slices):
				indices.append(si)

	if indices.is_empty():
		var meta: Array = _volume.slice_meta
		for si in range(meta.size()):
			var m: Dictionary = meta[si]
			if int(m.channel) == channel:
				indices.append(si)

	return indices


func _scene_voxel_key(slice_index: int, voxel_px: Vector2i) -> String:
	return "%d:%d:%d" % [slice_index, voxel_px.x, voxel_px.y]


func _scene_voxel_runtime_tile_key(slice_index: int, voxel_px: Vector2i, layer: String = "scene", tile_size: int = SCENE_VOXEL_RUNTIME_TILE_SIZE) -> String:
	var tile_x := int(voxel_px.x / tile_size)
	var tile_y := int(voxel_px.y / tile_size)
	if layer == "collision":
		return "%d:collision:%d:%d" % [slice_index, tile_x, tile_y]
	return "%d:%d:%d" % [slice_index, tile_x, tile_y]


func _scene_voxel_runtime_tile_bounds(voxel_px: Vector2i, tile_size: int = SCENE_VOXEL_RUNTIME_TILE_SIZE) -> Rect2i:
	return Rect2i(
		Vector2i(int(voxel_px.x / tile_size) * tile_size, int(voxel_px.y / tile_size) * tile_size),
		Vector2i(tile_size, tile_size)
	)


func _mark_scene_voxel_runtime_tile_dirty(slice_index: int, voxel_xz: Vector2i, layer: String = "scene", tile_size: int = SCENE_VOXEL_RUNTIME_TILE_SIZE) -> void:
	if _volume.is_empty():
		return
	var xz_res := int(_volume.get("xz_res", _base_res))
	if xz_res <= 0:
		return
	var px := Vector2i(
		clampi(voxel_xz.x, 0, xz_res - 1),
		clampi(voxel_xz.y, 0, xz_res - 1)
	)
	var key := _scene_voxel_runtime_tile_key(slice_index, px, layer, tile_size)
	_scene_voxel_runtime_dirty_tiles[key] = {
		"tile_id": key,
		"clip_level": 0,
		"layer": layer,
		"slice_index": slice_index,
		"tile_size": tile_size,
		"bounds": _scene_voxel_runtime_tile_bounds(px, tile_size),
		"write_tick": _generation_tick,
		"commit_tick": _committed_tick,
		"dirty": true,
	}
	_scene_voxel_runtime_dirty = true


func _clip_base_rect(rect: Rect2i) -> Rect2i:
	return rect.intersection(Rect2i(0, 0, _base_res, _base_res))


func _mark_scene_voxel_runtime_rect_dirty(base_rect: Rect2i, slice_indices: Array = [], include_collision: bool = true) -> void:
	var clipped := _clip_base_rect(base_rect)
	if clipped.size.x <= 0 or clipped.size.y <= 0:
		return
	_scene_voxel_runtime_dirty_rects.append(clipped)
	if _volume.is_empty():
		_scene_voxel_runtime_dirty = true
		return

	var xz_res := int(_volume.get("xz_res", _base_res))
	var start_px := _volume_px_from_base(clipped.position, xz_res)
	var end_base := Vector2i(
		clipped.position.x + clipped.size.x - 1,
		clipped.position.y + clipped.size.y - 1
	)
	var end_px := _volume_px_from_base(end_base, xz_res)
	var tile_min_x := int(mini(start_px.x, end_px.x) / SCENE_VOXEL_RUNTIME_TILE_SIZE)
	var tile_min_y := int(mini(start_px.y, end_px.y) / SCENE_VOXEL_RUNTIME_TILE_SIZE)
	var tile_max_x := int(maxi(start_px.x, end_px.x) / SCENE_VOXEL_RUNTIME_TILE_SIZE)
	var tile_max_y := int(maxi(start_px.y, end_px.y) / SCENE_VOXEL_RUNTIME_TILE_SIZE)

	var slices: Array[int] = []
	if slice_indices.is_empty():
		var total_slices := int(_volume.get("total_slices", 0))
		for si in range(total_slices):
			slices.append(si)
	else:
		for raw_slice in slice_indices:
			var si := int(raw_slice)
			if si >= 0 and si < int(_volume.get("total_slices", 0)):
				slices.append(si)

	for si in slices:
		for ty in range(tile_min_y, tile_max_y + 1):
			for tx in range(tile_min_x, tile_max_x + 1):
				var tile_px := Vector2i(tx * SCENE_VOXEL_RUNTIME_TILE_SIZE, ty * SCENE_VOXEL_RUNTIME_TILE_SIZE)
				_mark_scene_voxel_runtime_tile_dirty(si, tile_px, "scene")
				if include_collision:
					_mark_scene_voxel_runtime_tile_dirty(si, tile_px, "collision")


func _voxel_value(voxel: Dictionary) -> float:
	return clampf(float(voxel.get("value", voxel.get("complexity", 0.0))), 0.0, 1.0)


func _voxel_is_occupied(voxel: Dictionary) -> bool:
	return bool(voxel.get("occupied", _voxel_value(voxel) > VOXEL_OCCUPIED_EPSILON)) and _voxel_value(voxel) > VOXEL_OCCUPIED_EPSILON


func _make_scene_voxel(
	record: Dictionary,
	layer: Dictionary,
	slice_index: int,
	voxel_px: Vector2i,
	complexity: float
) -> Dictionary:
	var shared_fields := SharedPropertyTypeScript.normalize_shared_fields(layer, record, complexity)
	var value := float(shared_fields.complexity)
	var scene_voxel := {
		"type": "SceneVoxel",
		"occupied": value > VOXEL_OCCUPIED_EPSILON,
		"value": value,
		"channel": int(layer.get("channel", -1)),
		"slice_index": slice_index,
		"voxel_xz": voxel_px,
		"base_pixel": layer.get("base_pixel", record.get("base_pixel", Vector2i.ZERO)),
	}
	return SharedPropertyTypeScript.apply_to_scene_voxel(scene_voxel, shared_fields, value, false)


func _make_source_scene_voxel(
	record: Dictionary,
	layer: Dictionary,
	slice_index: int,
	voxel_px: Vector2i,
	complexity: float
) -> Dictionary:
	var source_voxel := _make_scene_voxel(record, layer, slice_index, voxel_px, complexity)
	var source_type := _source_type_from_record(record)
	source_voxel["type"] = source_type
	source_voxel["source_voxel_type"] = source_type
	source_voxel["source_kind"] = _source_kind_from_record(record)
	source_voxel["producer_stage"] = _producer_stage_from_record(record)
	var source_write_tick := int(record.get("write_tick", _generation_tick))
	var max_read_tick := maxi(source_write_tick - 1, 0)
	source_voxel["generation_tick"] = source_write_tick
	source_voxel["read_tick"] = clampi(int(record.get("read_tick", max_read_tick)), 0, max_read_tick)
	source_voxel["write_tick"] = source_write_tick
	if source_type != "TargetSceneVoxel":
		var collision_layers: Array = record.get("collision_voxels", [])
		if not collision_layers.is_empty():
			source_voxel = SharedPropertyTypeScript.apply_to_scene_voxel(
				source_voxel,
				{"collision_voxels": collision_layers},
				float(source_voxel.get("complexity", 1.0))
			)
	if source_type == "BrushSceneVoxel":
		source_voxel["brush_stroke_id"] = str(record.get("brush_stroke_id", record.get("id", "")))
		source_voxel["auto_mix"] = clampf(float(record.get("auto_mix", 0.0)), 0.0, 1.0)
		var modified_voxels: Array = record.get("modified_voxels", [])
		source_voxel["modified_voxels"] = modified_voxels.duplicate(true)
	if source_type == "TargetSceneVoxel":
		source_voxel["target_mix"] = clampf(float(record.get("target_mix", 1.0)), 0.0, 1.0)
		source_voxel["target_pipeline"] = str(record.get("target_pipeline", record.get("source_kind", "guidance")))
	return source_voxel


func _finalize_scene_voxel_from_source(source_voxel: Dictionary, commit_tick: int) -> Dictionary:
	var source_type := _source_type_from_scene_voxel(source_voxel)
	var value := _voxel_value(source_voxel)
	var scene_voxel := {
		"type": "SceneVoxel",
		"occupied": value > VOXEL_OCCUPIED_EPSILON,
		"value": value,
		"source_type": source_type,
		"channel": int(source_voxel.get("channel", -1)),
		"slice_index": int(source_voxel.get("slice_index", -1)),
		"base_pixel": source_voxel.get("base_pixel", source_voxel.get("voxel_xz", Vector2i.ZERO)),
		"commit_tick": commit_tick,
	}
	var voxel_xz = source_voxel.get("voxel_xz", Vector2i(-1, -1))
	if voxel_xz is Vector2i:
		scene_voxel["voxel_xz"] = voxel_xz
	var auto_mix := clampf(float(source_voxel.get("auto_mix", -1.0)), 0.0, 1.0)
	if auto_mix > 0.0 and auto_mix < 1.0:
		scene_voxel["auto_mix"] = auto_mix
	return SharedPropertyTypeScript.apply_to_scene_voxel(scene_voxel, source_voxel, value, source_voxel.has("collision_voxels"))


func _source_type_from_scene_voxel(scene_voxel: Dictionary) -> String:
	var compact_source_type := str(scene_voxel.get("source_type", ""))
	if compact_source_type == "AutoSceneVoxel" or compact_source_type == "BrushSceneVoxel":
		return compact_source_type
	var source_type := str(scene_voxel.get("source_voxel_type", ""))
	if source_type == "AutoSceneVoxel" or source_type == "BrushSceneVoxel":
		return source_type
	var scene_type := str(scene_voxel.get("type", ""))
	if scene_type == "BrushSceneVoxel":
		return "BrushSceneVoxel"
	return "AutoSceneVoxel"


func _scene_voxel_as_source(scene_voxel: Dictionary) -> Dictionary:
	var source_voxel := scene_voxel.duplicate(true)
	var source_type := _source_type_from_scene_voxel(source_voxel)
	source_voxel["type"] = source_type
	source_voxel["source_voxel_type"] = source_type
	return source_voxel


func _blend_color(a: Color, b: Color, mix_ratio: float) -> Color:
	var ratio := clampf(mix_ratio, 0.0, 1.0)
	return a.lerp(b, ratio)


func _merge_voxel_sources(auto_voxel: Dictionary, brush_voxel: Dictionary, commit_tick: int) -> Dictionary:
	if auto_voxel.is_empty() and brush_voxel.is_empty():
		return {}
	if auto_voxel.is_empty():
		return _finalize_scene_voxel_from_source(brush_voxel, commit_tick)
	if brush_voxel.is_empty():
		var result := _finalize_scene_voxel_from_source(auto_voxel, commit_tick)
		result["source_type"] = "AutoSceneVoxel"
		return result

	var auto_mix := clampf(float(brush_voxel.get("auto_mix", 0.0)), 0.0, 1.0)
	if auto_mix <= 0.0:
		var brush_only := _finalize_scene_voxel_from_source(brush_voxel, commit_tick)
		brush_only["source_type"] = "BrushSceneVoxel"
		return brush_only
	if auto_mix >= 1.0:
		var auto_only := _finalize_scene_voxel_from_source(auto_voxel, commit_tick)
		auto_only["source_type"] = "AutoSceneVoxel"
		return auto_only

	var blended := _finalize_scene_voxel_from_source(brush_voxel, commit_tick)
	blended["type"] = "SceneVoxel"
	blended["source_type"] = "BrushSceneVoxel" if auto_mix < 0.5 else "AutoSceneVoxel"
	blended["auto_mix"] = auto_mix
	var brush_value := float(brush_voxel.get("value", 0.0))
	var auto_value := float(auto_voxel.get("value", brush_value))
	var final_value := clampf(brush_value * (1.0 - auto_mix) + auto_value * auto_mix, 0.0, 1.0)
	blended["value"] = final_value
	blended["complexity"] = final_value
	var brush_color: Color = brush_voxel.get("color", Color.WHITE)
	var auto_color: Color = auto_voxel.get("color", brush_color)
	var final_color := _blend_color(brush_color, auto_color, auto_mix)
	final_color.a = final_value
	blended = SharedPropertyTypeScript.apply_to_scene_voxel(blended, {"color": final_color, "complexity": final_value}, final_value, blended.has("collision_voxels"))
	blended["occupied"] = final_value > VOXEL_OCCUPIED_EPSILON
	return blended


func _write_source_scene_voxel(source_voxel: Dictionary, commit_tick: int = -1) -> void:
	if source_voxel.is_empty():
		return
	var source_type := str(source_voxel.get("source_voxel_type", source_voxel.get("type", "AutoSceneVoxel")))
	if source_type == "TargetSceneVoxel":
		return
	var slice_index := int(source_voxel.get("slice_index", -1))
	var voxel_xz = source_voxel.get("voxel_xz", Vector2i(-1, -1))
	if slice_index < 0 or not voxel_xz is Vector2i:
		return
	var key := _scene_voxel_key(slice_index, voxel_xz)
	if source_type == "BrushSceneVoxel" and not _source_modifies_key(source_voxel, key):
		return
	var write_tick := int(source_voxel.get("write_tick", _generation_tick))
	var resolved_commit_tick := commit_tick if commit_tick >= 0 else write_tick
	var scene_voxels: Dictionary = _volume.get("scene_voxels", {})
	var current_value = scene_voxels.get(key, {})
	var next_scene_voxel := {}
	if current_value is Dictionary:
		var current_voxel := current_value as Dictionary
		var current_tick := int(current_voxel.get("commit_tick", current_voxel.get("write_tick", -1)))
		if current_tick == resolved_commit_tick:
			var current_source := _scene_voxel_as_source(current_voxel)
			var current_source_type := _source_type_from_scene_voxel(current_voxel)
			if source_type == "BrushSceneVoxel" and current_source_type == "AutoSceneVoxel":
				next_scene_voxel = _merge_voxel_sources(current_source, source_voxel, resolved_commit_tick)
			elif source_type == "AutoSceneVoxel" and current_source_type == "BrushSceneVoxel":
				next_scene_voxel = _merge_voxel_sources(source_voxel, current_source, resolved_commit_tick)
			elif _source_beats_current(source_voxel, current_source):
				next_scene_voxel = _finalize_scene_voxel_from_source(source_voxel, resolved_commit_tick)
			else:
				return
		else:
			next_scene_voxel = _finalize_scene_voxel_from_source(source_voxel, resolved_commit_tick)
	else:
		next_scene_voxel = _finalize_scene_voxel_from_source(source_voxel, resolved_commit_tick)
	scene_voxels[key] = next_scene_voxel
	_volume["scene_voxels"] = scene_voxels
	_mark_scene_voxel_runtime_tile_dirty(slice_index, voxel_xz, "scene")


func _rebuild_scene_voxel_runtime(tile_size: int = SCENE_VOXEL_RUNTIME_TILE_SIZE) -> Dictionary:
	if _volume.is_empty():
		_scene_voxel_runtime = {}
		return {}
	var xz_res: int = _volume.xz_res
	var scene_voxels: Dictionary = _volume.get("scene_voxels", {})
	var collision_voxels: Dictionary = _volume.get("collision_voxels", {})
	var dirty_tiles_snapshot := _scene_voxel_runtime_dirty_tiles.duplicate(true)
	var dirty_rects_snapshot := _scene_voxel_runtime_dirty_rects.duplicate(true)
	var tiles: Dictionary = {}
	for key in scene_voxels.keys():
		var scene_voxel = scene_voxels[key]
		if not scene_voxel is Dictionary:
			continue
		var voxel := scene_voxel as Dictionary
		if not _voxel_is_occupied(voxel):
			continue
		var voxel_xz = voxel.get("voxel_xz", Vector2i.ZERO)
		if not voxel_xz is Vector2i:
			continue
		var px: Vector2i = voxel_xz
		var tile_key := _scene_voxel_runtime_tile_key(int(voxel.get("slice_index", 0)), px, "scene", tile_size)
		var tile: Dictionary = tiles.get(tile_key, {
			"tile_id": tile_key,
			"clip_level": 0,
			"layer": "scene",
			"tile_size": tile_size,
			"bounds": _scene_voxel_runtime_tile_bounds(px, tile_size),
			"dirty": false,
			"updated_this_commit": dirty_tiles_snapshot.has(tile_key),
			"distance_or_occupancy": "occupancy",
			"scene_voxel_count": 0,
			"collision_voxel_count": 0,
			"max_value": 0.0,
		})
		tile["scene_voxel_count"] = int(tile.get("scene_voxel_count", 0)) + 1
		tile["max_value"] = maxf(float(tile.get("max_value", 0.0)), float(voxel.get("value", 0.0)))
		tiles[tile_key] = tile

	for key in collision_voxels.keys():
		var collision_voxel = collision_voxels[key]
		if not collision_voxel is Dictionary:
			continue
		var voxel := collision_voxel as Dictionary
		if not _voxel_is_occupied(voxel):
			continue
		var voxel_xz = voxel.get("voxel_xz", Vector2i.ZERO)
		if not voxel_xz is Vector2i:
			continue
		var px: Vector2i = voxel_xz
		var tile_key := _scene_voxel_runtime_tile_key(int(voxel.get("slice_index", 0)), px, "collision", tile_size)
		var tile: Dictionary = tiles.get(tile_key, {
			"tile_id": tile_key,
			"clip_level": 0,
			"layer": "collision",
			"tile_size": tile_size,
			"bounds": _scene_voxel_runtime_tile_bounds(px, tile_size),
			"dirty": false,
			"updated_this_commit": dirty_tiles_snapshot.has(tile_key),
			"distance_or_occupancy": "occupancy",
			"scene_voxel_count": 0,
			"collision_voxel_count": 0,
			"max_value": 0.0,
		})
		tile["collision_voxel_count"] = int(tile.get("collision_voxel_count", 0)) + 1
		tile["max_value"] = maxf(float(tile.get("max_value", 0.0)), float(voxel.get("value", 0.0)))
		tiles[tile_key] = tile

	_scene_voxel_runtime = {
		"type": "SceneVoxelLocal",
		"tile_size": tile_size,
		"clip_level": 0,
		"bounds": Rect2i(Vector2i.ZERO, Vector2i(xz_res, xz_res)),
		"dirty": false,
		"distance_or_occupancy": "occupancy",
		"commit_tick": _committed_tick,
		"generation_tick": _generation_tick,
		"tile_count": tiles.size(),
		"scene_voxel_count": scene_voxels.size(),
		"collision_voxel_count": collision_voxels.size(),
		"dirty_tile_count": dirty_tiles_snapshot.size(),
		"dirty_tiles": dirty_tiles_snapshot,
		"dirty_rects": dirty_rects_snapshot,
		"tiles": tiles,
	}
	_scene_voxel_runtime_dirty_tiles.clear()
	_scene_voxel_runtime_dirty_rects.clear()
	_scene_voxel_runtime_dirty = false
	return _scene_voxel_runtime.duplicate(true)


func _write_scene_voxel(scene_voxel: Dictionary) -> void:
	if _volume.is_empty() or scene_voxel.is_empty():
		return
	if not _volume.has("scene_voxels"):
		_volume["scene_voxels"] = {}
	var scene_voxels: Dictionary = _volume.scene_voxels
	var key := _scene_voxel_key(int(scene_voxel.slice_index), scene_voxel.voxel_xz)
	scene_voxels[key] = scene_voxel.duplicate(true)
	_volume["scene_voxels"] = scene_voxels
	_mark_scene_voxel_runtime_tile_dirty(int(scene_voxel.slice_index), scene_voxel.voxel_xz, "scene")
	_scene_voxel_runtime_dirty = true


func _stamp_volume_slices(
	base_px: Vector2i,
	radius_px: int,
	complexity: float,
	slice_indices: Array[int],
	scene_voxel_template: Dictionary = {},
	write_to_scene_voxel: bool = false,
	write_tick: int = -1
) -> Vector2i:
	if _volume.is_empty() or slice_indices.is_empty():
		return base_px

	var xz_res: int = _volume.xz_res
	var voxel_px := _volume_px_from_base(base_px, xz_res)
	var radius_vol := _volume_radius_from_base_radius(radius_px, xz_res)
	var v := clampf(complexity, 0.0, 1.0)
	var slices: Array = _volume.slices

	for si in slice_indices:
		var img: Image = slices[si]
		for dz in range(-radius_vol, radius_vol + 1):
			for dx in range(-radius_vol, radius_vol + 1):
				if dx * dx + dz * dz > radius_vol * radius_vol:
					continue
				var tx := clampi(voxel_px.x + dx, 0, xz_res - 1)
				var tz := clampi(voxel_px.y + dz, 0, xz_res - 1)
				var px := Vector2i(tx, tz)
				var cur := img.get_pixelv(px).r
				if v > cur:
					img.set_pixelv(px, Color(v, 0.0, 0.0, 0.0))
				var source_type := str(scene_voxel_template.get("source_voxel_type", scene_voxel_template.get("type", "")))
				var source_kind := str(scene_voxel_template.get("source_kind", "")).to_lower()
				var force_source_write := source_type == "BrushSceneVoxel" or source_kind == "erase" or bool(scene_voxel_template.get("write_empty_voxels", false))
				var should_write_source := force_source_write or (v > VOXEL_OCCUPIED_EPSILON and v + 0.00001 >= cur)
				if not scene_voxel_template.is_empty() and should_write_source:
					var scene_voxel := scene_voxel_template.duplicate(true)
					scene_voxel["slice_index"] = si
					scene_voxel["voxel_xz"] = px
					scene_voxel["value"] = v
					scene_voxel["occupied"] = v > VOXEL_OCCUPIED_EPSILON
					scene_voxel = SharedPropertyTypeScript.apply_to_scene_voxel(scene_voxel, scene_voxel, v, scene_voxel.has("collision_voxels"))
					if write_to_scene_voxel:
						scene_voxel = _prepare_source_record(scene_voxel, write_tick if write_tick >= 0 else _generation_tick)
						_write_source_scene_voxel(scene_voxel)
					else:
						_write_scene_voxel(scene_voxel)
		slices[si] = img

	_volume["slices"] = slices
	return voxel_px


## Apply an actual placed mesh's voxel_write_spec into SceneVoxel and buffers.
## This keeps runtime MeshInstance3D placement and the occupancy/voxel volume in sync.
func apply_mesh_asset_voxel_record(record: Dictionary, defer_blend: bool = false, generation_tick: int = -1) -> Dictionary:
	if record.is_empty():
		return {}

	var write_tick := generation_tick if generation_tick >= 0 else _next_write_tick()
	var rec := _prepare_source_record(record, write_tick)
	var record_id := str(rec.get("id", "mesh_%d" % _mesh_asset_voxel_records.size()))
	rec["id"] = record_id
	var channel_entries: Array = rec.get(CHANNEL_ENTRIES_KEY, [])

	var updated_channel_entries: Array[Dictionary] = []
	var applied_channels: Array[int] = []
	var rec_base_px: Vector2i = rec.get("base_pixel", Vector2i.ZERO)
	var collision_layers: Array = rec.get("collision_voxels", [])
	var updated_collision_layers := _make_source_collision_voxels(rec_base_px, collision_layers, rec)
	rec["collision_voxels"] = updated_collision_layers

	for entry_raw in channel_entries:
		if not entry_raw is Dictionary:
			continue
		var source_entry := entry_raw as Dictionary
		var entry := source_entry.duplicate(true)
		var ch := _channel_entry_channel(entry)
		if ch < 0:
			updated_channel_entries.append(entry)
			continue

		var base_px: Vector2i = entry.get("base_pixel", rec_base_px)
		var radius_px := _channel_entry_radius_px(entry)
		var complexity := clampf(float(entry.get("complexity", rec.get("complexity", 1.0))), 0.0, 1.0)
		var color := SharedPropertyTypeScript.color_from_value(entry.get("color", rec.get("color", Color.WHITE)), Color.WHITE)
		color.a = complexity
		var slice_indices := _slice_indices_for_channel_entry(entry, ch)
		var source_voxel_template := {}
		if not _volume.is_empty():
			var template_voxel_px := _volume_px_from_base(base_px, int(_volume.xz_res))
			source_voxel_template = _make_source_scene_voxel(rec, entry, -1, template_voxel_px, complexity)

		_stamp_occupancy_channel(base_px, ch, radius_px, complexity)
		var voxel_px := _stamp_volume_slices(
			base_px,
			radius_px,
			complexity,
			slice_indices,
			source_voxel_template,
			true,
			write_tick
		)

		entry["channel"] = ch
		entry["base_pixel"] = base_px
		entry["voxel_xz"] = voxel_px
		entry["radius_px"] = radius_px
		entry["complexity"] = complexity
		entry["color"] = color
		entry["slice_indices"] = slice_indices
		entry["height_buffer_applied"] = true
		updated_channel_entries.append(entry)

		if not applied_channels.has(ch):
			applied_channels.append(ch)

	rec["base_pixel"] = rec_base_px
	if _volume.is_empty():
		rec["voxel_xz"] = rec_base_px
		rec["volume_xz_resolution"] = _base_res
	else:
		rec["voxel_xz"] = _volume_px_from_base(rec_base_px, int(_volume.xz_res))
		rec["volume_xz_resolution"] = int(_volume.xz_res)
	rec[CHANNEL_ENTRIES_KEY] = updated_channel_entries
	rec["collision_voxels"] = updated_collision_layers
	rec["height_buffer_applied"] = not applied_channels.is_empty()
	rec["height_buffer_channels"] = applied_channels
	rec["collision_source_attached"] = not updated_collision_layers.is_empty()
	rec["collision_buffer_applied"] = false

	if _mesh_asset_voxel_record_index.has(record_id):
		var idx: int = _mesh_asset_voxel_record_index[record_id]
		_mesh_asset_voxel_records[idx] = rec
	else:
		_mesh_asset_voxel_record_index[record_id] = _mesh_asset_voxel_records.size()
		_mesh_asset_voxel_records.append(rec)

	if not defer_blend and not _volume.is_empty():
		blend_scene_voxels(write_tick)

	return rec


func clear_all() -> void:
	_occupancy.fill(Color(0.0, 0.0, 0.0, 0.0))
	_volume = {}
	_mesh_asset_voxel_records.clear()
	_mesh_asset_voxel_record_index.clear()
	_scene_state_by_tick.clear()
	_scene_voxel_runtime.clear()
	_scene_voxel_runtime_dirty_tiles.clear()
	_scene_voxel_runtime_dirty_rects.clear()
	_generation_tick = 1
	_committed_tick = 0
	_scene_voxel_runtime_dirty = true


## ─── 3D Voxel Volume ───
##
## Aggregates all 2D channel occupancy into a unified 3D voxel grid.

var _volume: Dictionary = {}

## Per placed mesh voxel_write_spec entries. These connect runtime MeshInstance3D nodes back
## to the voxel channel data that was stamped for them.
var _mesh_asset_voxel_records: Array[Dictionary] = []
var _mesh_asset_voxel_record_index: Dictionary = {}
var _scene_state_by_tick: Dictionary = {}
var _scene_voxel_runtime: Dictionary = {}
var _scene_voxel_runtime_dirty_tiles: Dictionary = {}
var _scene_voxel_runtime_dirty_rects: Array[Rect2i] = []
var _generation_tick: int = 1
var _committed_tick: int = 0
var _scene_voxel_runtime_dirty: bool = true


func _make_mesh_asset_voxel_record(
	mesh_id: String,
	mesh_type: String,
	base_px: Vector2i,
	world_pos: Vector3,
	inst_color: Color,
	inst_complexity: float,
	inst_channel_entries: Array[Dictionary],
	scale_value: float,
	collision_voxels: Array[Dictionary] = []
) -> Dictionary:
	var channel_entries: Array[Dictionary] = []
	for entry in inst_channel_entries:
		var ch: int = int(entry.get("channel", -1))
		if not _is_valid_channel(ch):
			continue
		var entry_color := _profile_entry_color(entry, inst_color)
		var entry_complexity := _profile_entry_complexity(entry, entry_color.a)
		entry_color.a = entry_complexity
		var y_min := float(entry.get("y_min", 0.0))
		var y_max := float(entry.get("y_max", y_min + 1.0))
		if y_max <= y_min:
			y_max = y_min + 1.0
		channel_entries.append({
			"channel": ch,
			"base_pixel": base_px,
			"radius": float(entry.get("radius", 0.0)),
			"radius_px": _radius_to_px(float(entry.get("radius", 0.0))),
			"y_min": y_min,
			"y_max": y_max,
			"color": entry_color,
			"complexity": entry_complexity,
			"subdivisions": maxi(int(entry.get("subdivisions", 1)), 1),
			"slice_indices": [],
		})

	var record := {
		"id": mesh_id,
		"type": mesh_type,
		"source_voxel_type": "AutoSceneVoxel",
		"source_kind": "scatter",
		"producer_stage": "vegetation_scatter",
		"position": world_pos,
		"base_pixel": base_px,
		"voxel_xz": base_px,
		"volume_xz_resolution": _base_res,
		"scale": Vector3.ONE * scale_value,
		"color": inst_color,
		"complexity": inst_complexity,
		"collision_voxels": collision_voxels.duplicate(true),
	}
	record[CHANNEL_ENTRIES_KEY] = channel_entries
	return record


func _register_mesh_asset_voxel_record(record: Dictionary) -> Dictionary:
	var record_id: String = str(record.get("id", "mesh_%d" % _mesh_asset_voxel_records.size()))
	record["id"] = record_id
	_mesh_asset_voxel_record_index[record_id] = _mesh_asset_voxel_records.size()
	_mesh_asset_voxel_records.append(record)
	return record


func _update_mesh_asset_voxel_records_for_volume() -> void:
	if _volume.is_empty():
		return
	var xz_res: int = _volume.xz_res
	var meta: Array = _volume.slice_meta
	for ri in range(_mesh_asset_voxel_records.size()):
		var record: Dictionary = _mesh_asset_voxel_records[ri]
		var base_px: Vector2i = record.get("base_pixel", Vector2i.ZERO)
		var vx := clampi(int(float(base_px.x) / float(_base_res) * float(xz_res)), 0, xz_res - 1)
		var vz := clampi(int(float(base_px.y) / float(_base_res) * float(xz_res)), 0, xz_res - 1)
		record["voxel_xz"] = Vector2i(vx, vz)
		record["volume_xz_resolution"] = xz_res

		var channel_entries: Array = record.get(CHANNEL_ENTRIES_KEY, [])
		for li in range(channel_entries.size()):
			var entry: Dictionary = channel_entries[li]
			var slice_indices: Array[int] = []
			for si in range(meta.size()):
				var m: Dictionary = meta[si]
				if int(m.channel) == int(entry.channel):
					slice_indices.append(si)
			entry["voxel_xz"] = Vector2i(vx, vz)
			entry["slice_indices"] = slice_indices
			channel_entries[li] = entry
		record[CHANNEL_ENTRIES_KEY] = channel_entries
		var collision_layers: Array = record.get("collision_voxels", [])
		for ci in range(collision_layers.size()):
			if not collision_layers[ci] is Dictionary:
				continue
			var collision_layer := (collision_layers[ci] as Dictionary).duplicate(true)
			collision_layer["voxel_xz"] = Vector2i(vx, vz)
			collision_layer["volume_xz_resolution"] = xz_res
			collision_layers[ci] = collision_layer
		record["collision_voxels"] = collision_layers
		_mesh_asset_voxel_records[ri] = record
		_mesh_asset_voxel_record_index[str(record.id)] = ri


func _rebuild_scene_voxels_from_records() -> void:
	if _volume.is_empty():
		return
	var write_tick := _next_write_tick()
	begin_generation_tick(write_tick)
	_volume["scene_voxels"] = {}
	var records := get_mesh_asset_voxel_records()
	for record in records:
		apply_mesh_asset_voxel_record(record, true, write_tick)


func blend_scene_voxels(tick: int = -1) -> Dictionary:
	if _volume.is_empty():
		return {}

	var commit_tick := tick if tick >= 0 else _generation_tick
	var final_scene_voxels: Dictionary = _volume.get("scene_voxels", {}).duplicate(true)
	for key in final_scene_voxels.keys():
		var scene_voxel = final_scene_voxels[key]
		if not scene_voxel is Dictionary:
			continue
		var typed_scene_voxel := (scene_voxel as Dictionary).duplicate(true)
		var voxel_commit_tick := int(typed_scene_voxel.get("commit_tick", commit_tick))
		final_scene_voxels[key] = _finalize_scene_voxel_from_source(typed_scene_voxel, voxel_commit_tick)

	_volume["scene_voxels"] = final_scene_voxels
	_rebuild_collision_cache_from_scene_voxels(final_scene_voxels)
	_scene_state_by_tick[commit_tick] = final_scene_voxels.duplicate(true)
	_committed_tick = max(_committed_tick, commit_tick)
	_generation_tick = max(_generation_tick, commit_tick + 1)
	_scene_voxel_runtime_dirty = true
	_rebuild_scene_voxel_runtime()
	return final_scene_voxels.duplicate(true)


func _channel_descriptor_from_entry(entry: Dictionary, default_subdivisions: int = 1) -> Dictionary:
	var ch := int(entry.get("channel", -1))
	var color := _profile_entry_color(entry)
	var complexity := _profile_entry_complexity(entry, color.a)
	color.a = complexity
	var y_min := float(entry.get("y_min", entry.get("min_height", 0.0)))
	var y_max := float(entry.get("y_max", entry.get("max_height", y_min + 1.0)))
	if y_max <= y_min:
		y_max = y_min + 1.0
	return {
		"channel": ch,
		"y_min": y_min,
		"y_max": y_max,
		"color": color,
		"complexity": complexity,
		"subdivisions": maxi(int(entry.get("subdivisions", default_subdivisions)), 1),
	}


func _collect_channel_descriptors(channel_profiles) -> Array[Dictionary]:
	var descriptors_by_channel: Dictionary = {}
	if channel_profiles is int:
		var subs := maxi(int(channel_profiles), 1)
		for ch in range(CHANNEL_COUNT):
			descriptors_by_channel[ch] = _channel_descriptor_from_entry({"channel": ch}, subs)
	elif channel_profiles is Array:
		var raw_profiles := channel_profiles as Array
		var has_explicit_descriptors := false
		for raw_profile in raw_profiles:
			if raw_profile is Dictionary:
				has_explicit_descriptors = true
				var descriptor := _channel_descriptor_from_entry(raw_profile as Dictionary, 1)
				var ch := int(descriptor.channel)
				if _is_valid_channel(ch):
					descriptors_by_channel[ch] = descriptor
		if not has_explicit_descriptors:
			for ch in range(mini(raw_profiles.size(), CHANNEL_COUNT)):
				descriptors_by_channel[ch] = _channel_descriptor_from_entry({"channel": ch}, maxi(int(raw_profiles[ch]), 1))

	for record in _mesh_asset_voxel_records:
		if not record is Dictionary:
			continue
		var rec := record as Dictionary
		var entries: Array = rec.get(CHANNEL_ENTRIES_KEY, [])
		for raw_entry in entries:
			if not raw_entry is Dictionary:
				continue
			var entry := raw_entry as Dictionary
			var ch := _channel_entry_channel(entry)
			if ch < 0 or descriptors_by_channel.has(ch):
				continue
			descriptors_by_channel[ch] = _channel_descriptor_from_entry(entry, maxi(int(entry.get("subdivisions", 1)), 1))

	if descriptors_by_channel.is_empty():
		for ch in range(CHANNEL_COUNT):
			descriptors_by_channel[ch] = _channel_descriptor_from_entry({"channel": ch}, 1)

	var descriptors: Array[Dictionary] = []
	for ch in range(CHANNEL_COUNT):
		if descriptors_by_channel.has(ch):
			descriptors.append((descriptors_by_channel[ch] as Dictionary).duplicate(true))
	return descriptors


func build_voxel_volume(
	xz_resolution: int = -1,
	channel_profiles = 1,
) -> Dictionary:
	var xz_res := xz_resolution if xz_resolution > 0 else maxi(_base_res / 2, 32)
	var descriptors := _collect_channel_descriptors(channel_profiles)
	var slices: Array[Image] = []
	var slice_meta: Array[Dictionary] = []

	for descriptor in descriptors:
		var ch := int(descriptor.channel)
		if not _is_valid_channel(ch):
			continue
		var subs := maxi(int(descriptor.get("subdivisions", 1)), 1)
		var y_min_base := float(descriptor.get("y_min", 0.0))
		var y_max_base := float(descriptor.get("y_max", y_min_base + 1.0))
		if y_max_base <= y_min_base:
			y_max_base = y_min_base + 1.0
		var thickness := y_max_base - y_min_base
		var color: Color = descriptor.get("color", Color.WHITE)
		var complexity := clampf(float(descriptor.get("complexity", color.a)), 0.0, 1.0)
		color.a = complexity

		for si in range(subs):
			var y_min: float = y_min_base + thickness * float(si) / float(subs)
			var y_max: float = y_min_base + thickness * float(si + 1) / float(subs)
			var slice_img := Image.create(xz_res, xz_res, false, Image.FORMAT_RF)
			slice_img.fill(Color(0.0, 0.0, 0.0, 0.0))

			for z in range(xz_res):
				for x in range(xz_res):
					var sx := clampi(int(float(x) / float(xz_res) * float(_base_res)), 0, _base_res - 1)
					var sz := clampi(int(float(z) / float(xz_res) * float(_base_res)), 0, _base_res - 1)
					var v: float = _occupancy.get_pixelv(Vector2i(sx, sz))[ch]
					if v > VOXEL_OCCUPIED_EPSILON:
						slice_img.set_pixelv(Vector2i(x, z), Color(v, 0.0, 0.0, 0.0))

			slices.append(slice_img)
			slice_meta.append({
				"channel": ch,
				"y_min": y_min,
				"y_max": y_max,
				"complexity": complexity,
				"color": color,
			})

	_volume = {
		"xz_res": xz_res,
		"total_slices": slices.size(),
		"slices": slices,
		"slice_meta": slice_meta,
		"scene_voxels": {},
		"collision_field": _resample_collision_field(xz_res),
		"collision_voxels": {},
	}
	var pending_dirty_rects := _scene_voxel_runtime_dirty_rects.duplicate()
	_scene_voxel_runtime_dirty_rects.clear()
	for dirty_rect in pending_dirty_rects:
		if dirty_rect is Rect2i:
			var typed_dirty_rect: Rect2i = dirty_rect
			_mark_scene_voxel_runtime_rect_dirty(typed_dirty_rect)
	_update_mesh_asset_voxel_records_for_volume()
	_rebuild_scene_voxels_from_records()
	blend_scene_voxels(_generation_tick)
	return _volume


func query_voxel(wx: float, wz: float, height_above_terrain: float) -> Dictionary:
	if _volume.is_empty():
		return {"occupied": false, "value": 0.0, "channel": -1, "color": Color.BLACK, "complexity": 0.0}

	var xz_res: int = _volume.xz_res
	var half := _capture_size / 2.0
	var px := clampi(int((wx + half) / _capture_size * float(xz_res)), 0, xz_res - 1)
	var pz := clampi(int((wz + half) / _capture_size * float(xz_res)), 0, xz_res - 1)

	var slices: Array = _volume.slices
	var meta: Array = _volume.slice_meta
	for i in range(meta.size()):
		var m: Dictionary = meta[i]
		if height_above_terrain >= m.y_min and height_above_terrain < m.y_max:
			var img: Image = slices[i]
			var v: float = img.get_pixelv(Vector2i(px, pz)).r
			var color: Color = m.color
			color.a = v
			var voxel_key := _scene_voxel_key(i, Vector2i(px, pz))
			var scene_voxels: Dictionary = _volume.get("scene_voxels", {})
			if scene_voxels.has(voxel_key):
				var scene_voxel = scene_voxels[voxel_key]
				if scene_voxel is Dictionary:
					var typed_scene_voxel := (scene_voxel as Dictionary).duplicate(true)
					var committed_value := clampf(float(typed_scene_voxel.get("value", v)), 0.0, 1.0)
					typed_scene_voxel["occupied"] = committed_value > 0.01
					typed_scene_voxel["value"] = committed_value
					typed_scene_voxel = SharedPropertyTypeScript.apply_to_scene_voxel(typed_scene_voxel, typed_scene_voxel, committed_value, typed_scene_voxel.has("collision_voxels"))
					typed_scene_voxel["channel"] = int(typed_scene_voxel.get("channel", m.channel))
					typed_scene_voxel["slice_index"] = i
					typed_scene_voxel["voxel_xz"] = Vector2i(px, pz)
					return typed_scene_voxel
			var query_voxel_record := {
				"type": "SceneVoxel",
				"occupied": v > 0.01,
				"value": v,
				"channel": int(m.channel),
				"slice_index": i,
				"voxel_xz": Vector2i(px, pz),
			}
			return SharedPropertyTypeScript.apply_to_scene_voxel(query_voxel_record, {"color": color, "complexity": v}, v, false)

	return {"occupied": false, "value": 0.0, "channel": -1, "color": Color.BLACK, "complexity": 0.0}


func get_scene_voxels() -> Dictionary:
	if _volume.is_empty():
		return {}
	var scene_voxels: Dictionary = _volume.get("scene_voxels", {})
	return scene_voxels.duplicate(true)


func get_scene_voxel_runtime() -> Dictionary:
	if _scene_voxel_runtime_dirty and not _volume.is_empty():
		_rebuild_scene_voxel_runtime()
	return _scene_voxel_runtime.duplicate(true)


func invalidate_scene_voxel_runtime_tile(slice_index: int, voxel_xz: Vector2i, layer: String = "scene") -> void:
	_mark_scene_voxel_runtime_tile_dirty(slice_index, voxel_xz, layer)


func invalidate_global_voxel_tile(slice_index: int, voxel_xz: Vector2i, layer: String = "scene") -> void:
	invalidate_scene_voxel_runtime_tile(slice_index, voxel_xz, layer)


func invalidate_scene_voxel_runtime_rect(base_rect: Rect2i, slice_indices: Array = [], include_collision: bool = true) -> void:
	_mark_scene_voxel_runtime_rect_dirty(base_rect, slice_indices, include_collision)


func invalidate_global_voxel_rect(base_rect: Rect2i, slice_indices: Array = [], include_collision: bool = true) -> void:
	invalidate_scene_voxel_runtime_rect(base_rect, slice_indices, include_collision)


func get_scene_voxel_runtime_dirty_tiles() -> Dictionary:
	return _scene_voxel_runtime_dirty_tiles.duplicate(true)


func get_global_voxel_dirty_tiles() -> Dictionary:
	return get_scene_voxel_runtime_dirty_tiles()


func clear_scene_voxel_runtime_dirty() -> void:
	_scene_voxel_runtime_dirty_tiles.clear()
	_scene_voxel_runtime_dirty_rects.clear()
	if not _scene_voxel_runtime.is_empty():
		_scene_voxel_runtime["dirty_tile_count"] = 0
		_scene_voxel_runtime["dirty_tiles"] = {}
		_scene_voxel_runtime["dirty_rects"] = []


func clear_global_voxel_dirty() -> void:
	clear_scene_voxel_runtime_dirty()


func get_committed_tick() -> int:
	return _committed_tick


func get_generation_tick() -> int:
	return _generation_tick


func get_scene_voxel(slice_index: int, voxel_xz: Vector2i) -> Dictionary:
	if _volume.is_empty():
		return {}
	var scene_voxels: Dictionary = _volume.get("scene_voxels", {})
	var key := _scene_voxel_key(slice_index, voxel_xz)
	var scene_voxel = scene_voxels.get(key, {})
	if scene_voxel is Dictionary:
		return (scene_voxel as Dictionary).duplicate(true)
	return {}


## Get a specific Y-slice Image from the volume.
func get_voxel_slice(slice_index: int) -> Image:
	if _volume.is_empty() or slice_index < 0 or slice_index >= _volume.total_slices:
		return Image.create(1, 1, false, Image.FORMAT_RF)
	return _volume.slices[slice_index]


## Get metadata for a specific slice.
func get_voxel_slice_meta(slice_index: int) -> Dictionary:
	if _volume.is_empty() or slice_index < 0 or slice_index >= _volume.total_slices:
		return {}
	return _volume.slice_meta[slice_index]


## Get total number of slices in the volume.
func get_voxel_slice_count() -> int:
	if _volume.is_empty():
		return 0
	return _volume.total_slices


## Get full volume stats for debug.
func get_voxel_stats() -> Dictionary:
	if _volume.is_empty():
		return {}
	var xz_res: int = _volume.xz_res
	var total_voxels := 0
	var occupied_voxels := 0
	var collision_voxels := 0
	var per_slice: Array[Dictionary] = []
	var scene_voxels: Dictionary = _volume.get("scene_voxels", {})

	var slices: Array = _volume.slices
	var meta: Array = _volume.slice_meta
	for i in range(slices.size()):
		var img: Image = slices[i]
		var m: Dictionary = meta[i]
		var count := 0
		for z in range(xz_res):
			for x in range(xz_res):
				if img.get_pixelv(Vector2i(x, z)).r > 0.01:
					count += 1
		var total := xz_res * xz_res
		total_voxels += total
		occupied_voxels += count
		per_slice.append({
			"slice": i,
			"channel": int(m.channel),
			"y_range": "%.2f-%.2fm" % [m.y_min, m.y_max],
			"occupied": "%d/%d (%.1f%%)" % [count, total, float(count) / float(total) * 100.0],
			"color": m.color,
			"complexity": m.complexity,
		})

	if not scene_voxels.is_empty():
		occupied_voxels = 0
		var per_slice_counts: Dictionary = {}
		for key in scene_voxels.keys():
			var scene_voxel = scene_voxels[key]
			if not scene_voxel is Dictionary:
				continue
			var voxel := scene_voxel as Dictionary
			if not bool(voxel.get("occupied", float(voxel.get("value", 0.0)) > 0.01)):
				continue
			occupied_voxels += 1
			var slice_index := int(voxel.get("slice_index", -1))
			if slice_index >= 0:
				per_slice_counts[slice_index] = int(per_slice_counts.get(slice_index, 0)) + 1
		for slice_key in per_slice_counts.keys():
			var slice_index := int(slice_key)
			if slice_index < 0 or slice_index >= per_slice.size():
				continue
			var m: Dictionary = meta[slice_index]
			var count := int(per_slice_counts[slice_key])
			var total := xz_res * xz_res
			per_slice[slice_index] = {
				"slice": slice_index,
				"channel": int(m.channel),
				"y_range": "%.2f-%.2fm" % [m.y_min, m.y_max],
				"occupied": "%d/%d (%.1f%%)" % [count, total, float(count) / float(total) * 100.0],
				"color": m.color,
				"complexity": m.complexity,
			}

	var collision_img: Image = _volume.get("collision_field", _resample_collision_field(xz_res))
	for z in range(xz_res):
		for x in range(xz_res):
			if collision_img.get_pixelv(Vector2i(x, z)).r > 0.01:
				collision_voxels += 1

	return {
		"xz_resolution": xz_res,
		"total_slices": slices.size(),
		"voxel_size_xz": "%.2fm" % [_capture_size / float(xz_res)],
		"total_voxels": total_voxels,
		"occupied_voxels": occupied_voxels,
		"collision_voxels": collision_voxels,
		"collision_field_pct": "%.1f%%" % [float(collision_voxels) / float(xz_res * xz_res) * 100.0] if xz_res > 0 else "0%",
		"scene_voxels": int(_volume.get("scene_voxels", {}).size()),
		"scene_voxel_runtime_tiles": int(get_scene_voxel_runtime().get("tile_count", 0)),
		"generation_tick": _generation_tick,
		"committed_tick": _committed_tick,
		"occupancy_pct": "%.1f%%" % [float(occupied_voxels) / float(total_voxels) * 100.0] if total_voxels > 0 else "0%",
		"per_slice": per_slice,
	}


func reset_occupancy() -> void:
	_occupancy.fill(Color(0.0, 0.0, 0.0, 0.0))
	_collision_field.fill(Color(0.0, 0.0, 0.0, 0.0))
	_volume = {}
	_mesh_asset_voxel_records.clear()
	_mesh_asset_voxel_record_index.clear()
	_scene_state_by_tick.clear()
	_scene_voxel_runtime.clear()
	_scene_voxel_runtime_dirty_tiles.clear()
	_scene_voxel_runtime_dirty_rects.clear()
	_generation_tick = 1
	_committed_tick = 0
	_scene_voxel_runtime_dirty = true


func validate_voxel(params: Dictionary = {}) -> Dictionary:
	if _volume.is_empty():
		return {"passed": false, "reason": "No voxel volume built", "metrics": {}}

	var min_channel_occupancy: Dictionary = params.get("min_channel_occupancy", {})
	var max_channel_occupancy: Dictionary = params.get("max_channel_occupancy", {})
	var min_diversity: int = params.get("min_diversity_score", 2)

	var channel_occ: Array[float] = []
	var xz_res: int = _volume.xz_res
	var slices: Array = _volume.slices
	var meta: Array = _volume.slice_meta
	var scene_voxels: Dictionary = _volume.get("scene_voxels", {})

	var channel_counts: Array[int] = []
	var channel_totals: Array[int] = []
	for _i in range(CHANNEL_COUNT):
		channel_counts.append(0)
		channel_totals.append(0)

	for i in range(slices.size()):
		var m: Dictionary = meta[i]
		var ch: int = int(m.channel)
		var total := xz_res * xz_res
		if ch >= 0 and ch < channel_totals.size():
			channel_totals[ch] += total

	if not scene_voxels.is_empty():
		for key in scene_voxels.keys():
			var scene_voxel = scene_voxels[key]
			if not scene_voxel is Dictionary:
				continue
			var voxel := scene_voxel as Dictionary
			if not bool(voxel.get("occupied", float(voxel.get("value", 0.0)) > 0.01)):
				continue
			var channel := int(voxel.get("channel", -1))
			if channel >= 0 and channel < channel_counts.size():
				channel_counts[channel] += 1
	else:
		for i in range(slices.size()):
			var img: Image = slices[i]
			var m: Dictionary = meta[i]
			var ch: int = int(m.channel)
			if ch < 0 or ch >= channel_counts.size():
				continue
			for z in range(xz_res):
				for x in range(xz_res):
					if img.get_pixelv(Vector2i(x, z)).r > 0.01:
						channel_counts[ch] += 1

	for ch in range(CHANNEL_COUNT):
		var pct := float(channel_counts[ch]) / float(channel_totals[ch]) * 100.0 if channel_totals[ch] > 0 else 0.0
		channel_occ.append(pct)

	var diversity := 0
	for pct in channel_occ:
		if pct > 1.0:
			diversity += 1

	var metrics := {
		"channel_occupancy_pct": channel_occ,
		"channels": range(CHANNEL_COUNT),
		"diversity_score": diversity,
	}

	for raw_channel in min_channel_occupancy.keys():
		var ch := int(raw_channel)
		var min_occ := float(min_channel_occupancy[raw_channel])
		var occ := channel_occ[ch] if ch >= 0 and ch < channel_occ.size() else 0.0
		if occ < min_occ:
			return {"passed": false, "reason": "Channel %d occupancy too low: %.1f%% < %.1f%%" % [ch, occ, min_occ], "metrics": metrics}

	for raw_channel in max_channel_occupancy.keys():
		var ch := int(raw_channel)
		var max_occ := float(max_channel_occupancy[raw_channel])
		var occ := channel_occ[ch] if ch >= 0 and ch < channel_occ.size() else 0.0
		if occ > max_occ:
			return {"passed": false, "reason": "Channel %d occupancy too high: %.1f%% > %.1f%%" % [ch, occ, max_occ], "metrics": metrics}

	if diversity < min_diversity:
		return {"passed": false, "reason": "Diversity too low: %d < %d channels active" % [diversity, min_diversity], "metrics": metrics}

	return {"passed": true, "reason": "OK", "metrics": metrics}

## Export the volume as a vertical column at pixel (px, pz) for debug.
## Returns Array[Dictionary], one per slice from bottom to top.
func get_voxel_column(px: int, pz: int) -> Array[Dictionary]:
	var column: Array[Dictionary] = []
	if _volume.is_empty():
		return column
	var xz_res: int = _volume.xz_res
	px = clampi(px, 0, xz_res - 1)
	pz = clampi(pz, 0, xz_res - 1)

	var slices: Array = _volume.slices
	var meta: Array = _volume.slice_meta
	for i in range(slices.size()):
		var img: Image = slices[i]
		var m: Dictionary = meta[i]
		var v: float = img.get_pixelv(Vector2i(px, pz)).r
		column.append({
			"slice": i,
			"channel": int(m.channel),
			"y_min": m.y_min,
			"y_max": m.y_max,
			"value": v,
			"occupied": v > 0.01,
			"color": m.color,
			"complexity": m.complexity,
		})
	return column
