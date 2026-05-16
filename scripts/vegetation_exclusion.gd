class_name VegetationExclusion
extends "res://scripts/godot_compute_shader_base.gd"
## Height-band occupancy system for vegetation placement.
##
## The space above terrain is divided into height bands, each a 2D occupancy mask
## at its own resolution. Higher bands use lower resolution (larger effective voxel).
##
## Each vegetation type declares a VegetationProfile: which bands it occupies and
## with what radius. Conflict only occurs when two plants share the SAME band AND
## overlap at that band's resolution.
##
## Example:
##   Band 0 "ground"     (0-0.3m,  256×256) — trunk base, grass roots
##   Band 1 "understory" (0.3-2m,  128×128) — bush foliage, small plant crowns
##   Band 2 "midstory"   (2-6m,    128×128) — small tree crowns, tall bushes
##   Band 3 "canopy"     (6m+,      64×64)  — large tree crowns
##
##   Tree profile:  ground(r=1) + canopy(r=4)
##   Bush profile:  ground(r=1) + understory(r=2)
##   Grass profile: ground(r=1) only
##
##   → Grass under tree canopy: grass checks ground band only, tree canopy is in
##     band 3, no overlap → grass grows freely under trees ✓
##   → Two tree crowns: both in canopy band → overlap detected → mutually exclusive ✓
##   → Bush next to tree trunk: both in ground band, but small radius → only blocked
##     at trunk pixel, free 1m away ✓

const VOXEL_OCCUPIED_EPSILON := 0.01
const GLOBAL_VOXEL_TILE_SIZE := 16
const DEPRECATED_SENCE_LAYER_VOXEL_KEY := "SenceLayerVoxel"
const DEPRECATED_VOXEL_LAYERS_KEY := "voxel_layers"

## ─── Height Band ───

var _bands: Array[Dictionary] = []
## Each band: { "name": String, "min_h": float, "max_h": float, "res": int, "color": Color }
## color = (R, G, B, complexity). RGB = debug visualization, A = complexity 0.0-1.0.
##
## GPU layout: all bands packed into a single RGBA16F texture at _base_res.
##   R = ground (band 0), G = understory (band 1), B = midstory (band 2), A = canopy (band 3)
## Pixel value = 0.0 (empty) or color.a (occupied). One float4 carries all bands.

var _band_index: Dictionary = {}  ## band_name → channel index (0-3)

var _base_res: int  ## Base resolution for world↔pixel coordinate mapping
var _capture_size: float

## Packed RGBA occupancy: all bands in one Image at base_res
var _occupancy: Image

## Coarse solid collision occupancy for mutually exclusive final placement.
## This is intentionally separate from height-band foliage occupancy: only rigid
## parts such as thick trunks should write here.
var _collision_occupancy: Image

## GPU resources
var _sampler: RID
var _shader_import: RID
var _pipeline_import: RID
var _shader_filter: RID
var _pipeline_filter: RID
var _shader_stamp: RID
var _pipeline_stamp: RID
var _gpu_ready: bool = false


func _init(base_resolution: int, capture_size: float, enable_gpu: bool = true) -> void:
	_base_res = base_resolution
	_capture_size = capture_size
	_occupancy = Image.create(_base_res, _base_res, false, Image.FORMAT_RGBAH)
	_occupancy.fill(Color(0.0, 0.0, 0.0, 0.0))
	_collision_occupancy = Image.create(_base_res, _base_res, false, Image.FORMAT_RF)
	_collision_occupancy.fill(Color(0.0, 0.0, 0.0, 0.0))
	if enable_gpu:
		_init_gpu()


func _init_gpu() -> void:
	log_name = "VegetationExclusion"
	if not ensure_device(true, false):
		_gpu_fatal("Failed to create RenderingDevice — GPU compute required")
		return

	_sampler = create_linear_sampler()

	_shader_import = load_compute_shader("res://shaders/band_import_mask.glsl")
	if _shader_import.is_valid():
		_pipeline_import = create_compute_pipeline(_shader_import)

	_shader_filter = load_compute_shader("res://shaders/band_filter_candidates.glsl")
	if _shader_filter.is_valid():
		_pipeline_filter = create_compute_pipeline(_shader_filter)

	_shader_stamp = load_compute_shader("res://shaders/band_stamp.glsl")
	if _shader_stamp.is_valid():
		_pipeline_stamp = create_compute_pipeline(_shader_stamp)

	_gpu_ready = _shader_import.is_valid() and _shader_filter.is_valid() and _shader_stamp.is_valid()
	if _gpu_ready:
		print("[VegetationExclusion] GPU compute ready (3 shaders loaded)")
	else:
		_gpu_fatal("One or more compute shaders failed to compile")


func _gpu_fatal(msg: String) -> void:
	var full := "[VegetationExclusion] GPU ERROR: %s" % msg
	push_error(full)
	OS.alert(full, "VegetationExclusion — GPU Required")
	_gpu_ready = false


func _free_gpu() -> void:
	dispose()
	_pipeline_import = RID()
	_shader_import = RID()
	_pipeline_filter = RID()
	_shader_filter = RID()
	_pipeline_stamp = RID()
	_shader_stamp = RID()
	_sampler = RID()
	_gpu_ready = false


## Add a height band. Bands should be added from lowest to highest (max 4).
## All bands share a single packed RGBA texture at _base_res.
## Channel mapping: band 0→R, 1→G, 2→B, 3→A.
## color: Color(R, G, B, complexity). RGB = debug color, A = complexity 0.0-1.0.
func add_band(
	band_name: String, min_height: float, max_height: float, resolution: int,
	color: Color = Color(1.0, 1.0, 1.0, 1.0)
) -> void:
	if _bands.size() >= 4:
		push_error("[VegetationExclusion] Max 4 bands (RGBA channels)")
		return
	var channel := _bands.size()
	var band := {
		"name": band_name,
		"min_h": min_height,
		"max_h": max_height,
		"res": resolution,
		"color": Color(color.r, color.g, color.b, clampf(color.a, 0.0, 1.0)),
		"channel": channel,
	}
	_band_index[band_name] = channel
	_bands.append(band)


## Import an existing mask (e.g., rock_mask) into a specific band's channel.
func import_mask(band_name: String, mask_img: Image) -> void:
	assert(_gpu_ready, "[VegetationExclusion] GPU not ready — cannot import mask")
	if not _band_index.has(band_name):
		push_error("[VegetationExclusion] Unknown band: %s" % band_name)
		return
	var ch: int = _band_index[band_name]
	var band: Dictionary = _bands[ch]
	_gpu_import_mask(ch, band.color.a, mask_img)


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


## ─── Vegetation Profile ───
## A profile describes how a vegetation type occupies space across bands.
## Format: Array[Dictionary], each entry: { "band": String, "radius": float }
## radius is in world meters, converted to band pixels internally.
##
## Each vegetation type usually occupies one foliage height band. Rigid parts
## that should be mutually exclusive are described separately as collision voxels.
##   grass        → ground     (0.0–0.3m)
##   bush         → understory (0.3–2.0m)
##   midstory_tree → midstory  (2.0–6.0m)
##   canopy_tree  → canopy     (6.0m+)

## Create a profile for grass: occupies ground band only.
static func profile_grass(radius: float = 0.2) -> Array[Dictionary]:
	return [{"band": "ground", "radius": radius}]


## Create a profile for bush: occupies understory band only.
static func profile_bush(radius: float = 1.0) -> Array[Dictionary]:
	return [{"band": "understory", "radius": radius}]


## Create a profile for midstory tree: occupies midstory band only.
static func profile_midstory(radius: float = 2.0) -> Array[Dictionary]:
	return [{"band": "midstory", "radius": radius}]


## Create a profile for canopy tree: occupies canopy band only.
static func profile_canopy_tree(radius: float = 3.0) -> Array[Dictionary]:
	return [{"band": "canopy", "radius": radius}]


## Create a custom profile (multi-band).
static func profile_custom(entries: Array[Dictionary]) -> Array[Dictionary]:
	return entries


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
		if _band_index.has(entry.band):
			mask[_band_index[entry.band]] = 1.0
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
				if _collision_occupancy.get_pixelv(Vector2i(tx, ty)).r > 0.01:
					return true
	return false


func _collision_voxel_key(px: Vector2i) -> String:
	return "collision:%d:%d" % [px.x, px.y]


func _ensure_volume_collision_layer() -> void:
	if _volume.is_empty():
		return
	var xz_res: int = _volume.xz_res
	if not _volume.has("collision_occupancy"):
		var img := Image.create(xz_res, xz_res, false, Image.FORMAT_RF)
		img.fill(Color(0.0, 0.0, 0.0, 0.0))
		_volume["collision_occupancy"] = img
	if not _volume.has("collision_voxels"):
		_volume["collision_voxels"] = {}


func _resample_collision_occupancy(xz_res: int) -> Image:
	var img := Image.create(xz_res, xz_res, false, Image.FORMAT_RF)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	for z in range(xz_res):
		for x in range(xz_res):
			var bx := clampi(int(float(x) / float(xz_res) * float(_base_res)), 0, _base_res - 1)
			var bz := clampi(int(float(z) / float(xz_res) * float(_base_res)), 0, _base_res - 1)
			var v := _collision_occupancy.get_pixelv(Vector2i(bx, bz)).r
			img.set_pixelv(Vector2i(x, z), Color(v, 0.0, 0.0, 0.0))
	return img


func _stamp_collision_volume(base_px: Vector2i, radius_px: int, value: float, rec: Dictionary, layer: Dictionary) -> Vector2i:
	if _volume.is_empty():
		return base_px
	_ensure_volume_collision_layer()
	var xz_res: int = _volume.xz_res
	var collision_img: Image = _volume.collision_occupancy
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
				_mark_global_tile_dirty(int(scene_collision.slice_index), px, "collision")
	_volume["collision_occupancy"] = collision_img
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
			var cur := _collision_occupancy.get_pixelv(px).r
			if value > cur:
				_collision_occupancy.set_pixelv(px, Color(value, 0.0, 0.0, 0.0))
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
	_collision_occupancy.fill(Color(0.0, 0.0, 0.0, 0.0))
	if _volume.is_empty():
		return
	var xz_res: int = _volume.xz_res
	var img := Image.create(xz_res, xz_res, false, Image.FORMAT_RF)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	_volume["collision_occupancy"] = img
	_volume["collision_voxels"] = {}


func _rebuild_collision_cache_from_scene_voxels(scene_voxels: Dictionary) -> void:
	_clear_collision_cache()
	if _volume.is_empty():
		return
	var stamped_records: Dictionary = {}
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
		var stamp_key := str(voxel.get("record_id", ""))
		if stamp_key.is_empty():
			stamp_key = str(key)
		stamp_key = "%s:%d:%d" % [stamp_key, base_px.x, base_px.y]
		if stamped_records.has(stamp_key):
			continue
		stamped_records[stamp_key] = true
		_stamp_collision_voxels(base_px, collision_layers, voxel)


func _stamp_occupancy_channel(base_px: Vector2i, channel: int, radius_px: int, complexity: float) -> void:
	if channel < 0 or channel >= _bands.size():
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


## Stamp a plant's footprint into the packed RGBA occupancy (CPU, for Poisson re-check).
func _stamp_occupancy(base_px: Vector2i, profile: Array[Dictionary]) -> void:
	for entry in profile:
		if not _band_index.has(entry.band):
			continue
		var ch: int = _band_index[entry.band]
		var complexity: float = _bands[ch].color.a
		var r_px := _radius_to_px(entry.radius)
		_stamp_occupancy_channel(base_px, ch, r_px, complexity)


## ─── GPU Candidate Filtering ───

## Use compute shader to produce a candidate mask (band unblocked only).
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

## Scatter vegetation using height-band occupancy for conflict detection.
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
	assert(_gpu_ready, "[VegetationExclusion] GPU not ready — cannot scatter")
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
		var mesh_id := "%s_%d" % [veg_type, _mesh_voxel_records.size()]
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

		# Build per-instance properties from profile + band config
		var inst_bands: Array[Dictionary] = []
		var inst_color := Color(0.0, 0.0, 0.0, 0.0)
		var inst_complexity := 0.0
		for entry in profile:
			if not _band_index.has(entry.band):
				continue
			var bi: int = _band_index[entry.band]
			var band: Dictionary = _bands[bi]
			inst_bands.append({
				"band": entry.band,
				"channel": bi,
				"radius": entry.radius,
				"complexity": band.color.a,
				"color": band.color,
			})
			inst_color += band.color
			inst_complexity = maxf(inst_complexity, band.color.a)
		if inst_bands.size() > 0:
			inst_color /= float(inst_bands.size())
			inst_color.a = inst_complexity

		var voxel_record := _register_mesh_voxel_record(_make_mesh_voxel_record(
			mesh_id,
			veg_type,
			cpx,
			world_pos,
			inst_color,
			inst_complexity,
			inst_bands,
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
			"affected_bands": inst_bands,
			"collision_voxels": inst_collision_voxels,
			"voxel_record": voxel_record,
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
		var mesh_id := "%s_%d" % [veg_type, _mesh_voxel_records.size()]
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

		var inst_bands: Array[Dictionary] = []
		var inst_color := Color(0.0, 0.0, 0.0, 0.0)
		var inst_complexity := 0.0
		for entry in profile:
			if not _band_index.has(entry.band):
				continue
			var bi: int = _band_index[entry.band]
			var band: Dictionary = _bands[bi]
			inst_bands.append({
				"band": entry.band,
				"channel": bi,
				"radius": entry.radius,
				"complexity": band.color.a,
				"color": band.color,
			})
			inst_color += band.color
			inst_complexity = maxf(inst_complexity, band.color.a)
		if inst_bands.size() > 0:
			inst_color /= float(inst_bands.size())
			inst_color.a = inst_complexity

		var voxel_record := _register_mesh_voxel_record(_make_mesh_voxel_record(
			mesh_id,
			veg_type,
			cpx,
			world_pos,
			inst_color,
			inst_complexity,
			inst_bands,
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
			"affected_bands": inst_bands,
			"collision_voxels": inst_collision_voxels,
			"voxel_record": voxel_record,
		})

	return results


## ─── Query & Debug ───

## Get the packed RGBA occupancy image (all bands in one texture).
func get_occupancy() -> Image:
	return _occupancy


## Get the coarse collision occupancy image.
func get_collision_occupancy() -> Image:
	return _collision_occupancy


func query_collision_voxel(wx: float, wz: float) -> Dictionary:
	var half := _capture_size / 2.0
	if _volume.is_empty():
		var base_px := Vector2i(
			clampi(int((wx + half) / _capture_size * float(_base_res)), 0, _base_res - 1),
			clampi(int((wz + half) / _capture_size * float(_base_res)), 0, _base_res - 1)
		)
		var base_v := _collision_occupancy.get_pixelv(base_px).r
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
	var collision_img: Image = _volume.get("collision_occupancy", _resample_collision_occupancy(xz_res))
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


## Get every placed mesh's voxel record.
func get_mesh_voxel_records() -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	for record in _mesh_voxel_records:
		var typed_record := record as Dictionary
		records.append(typed_record.duplicate(true))
	return records


## Get one placed mesh's voxel record by id.
func get_mesh_voxel_record(mesh_id: String) -> Dictionary:
	if not _mesh_voxel_record_index.has(mesh_id):
		return {}
	var idx: int = _mesh_voxel_record_index[mesh_id]
	var record: Dictionary = _mesh_voxel_records[idx]
	return record.duplicate(true)


func get_mesh_voxel_record_count() -> int:
	return _mesh_voxel_records.size()


func _layer_channel(layer: Dictionary) -> int:
	var ch := int(layer.get("channel", -1))
	if ch < 0:
		var band_name := str(layer.get("band", ""))
		if _band_index.has(band_name):
			ch = _band_index[band_name]
	if ch < 0 or ch >= _bands.size():
		return -1
	return ch


func _layer_radius_px(layer: Dictionary) -> int:
	if layer.has("radius_px"):
		return maxi(int(layer.radius_px), 1)
	if layer.has("radius"):
		return _radius_to_px(float(layer.radius))
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
	_source_voxel_deltas[write_tick] = {
		"auto": {},
		"brush": {},
	}
	_global_field_dirty = true
	return write_tick


func _ensure_source_delta_tick(tick: int) -> Dictionary:
	if not _source_voxel_deltas.has(tick):
		_source_voxel_deltas[tick] = {
			"auto": {},
			"brush": {},
			"target": {},
		}
	return _source_voxel_deltas[tick]


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
	var rec := record.duplicate(true)
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


func _source_delta_branch(source_type: String) -> String:
	if source_type == "BrushSceneVoxel":
		return "brush"
	if source_type == "TargetSceneVoxel":
		return "target"
	return "auto"


func _source_priority(source_voxel: Dictionary) -> float:
	if source_voxel.has("priority"):
		return float(source_voxel.priority)
	var st := str(source_voxel.get("source_voxel_type", source_voxel.get("type", "")))
	if st == "BrushSceneVoxel":
		return 100.0
	if st == "TargetSceneVoxel":
		return 50.0
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


func _slice_indices_for_layer(layer: Dictionary, channel: int) -> Array[int]:
	var indices: Array[int] = []
	if _volume.is_empty():
		return indices

	if layer.has("slice_indices"):
		var raw_indices: Array = layer.slice_indices
		for idx in raw_indices:
			var si := int(idx)
			if si >= 0 and si < int(_volume.total_slices):
				indices.append(si)

	if indices.is_empty():
		var meta: Array = _volume.slice_meta
		for si in range(meta.size()):
			var m: Dictionary = meta[si]
			if int(m.band_idx) == channel:
				indices.append(si)

	return indices


func _scene_voxel_key(slice_index: int, voxel_px: Vector2i) -> String:
	return "%d:%d:%d" % [slice_index, voxel_px.x, voxel_px.y]


func _global_tile_key(slice_index: int, voxel_px: Vector2i, layer: String = "scene", tile_size: int = GLOBAL_VOXEL_TILE_SIZE) -> String:
	var tile_x := int(voxel_px.x / tile_size)
	var tile_y := int(voxel_px.y / tile_size)
	if layer == "collision":
		return "%d:collision:%d:%d" % [slice_index, tile_x, tile_y]
	return "%d:%d:%d" % [slice_index, tile_x, tile_y]


func _global_tile_bounds(voxel_px: Vector2i, tile_size: int = GLOBAL_VOXEL_TILE_SIZE) -> Rect2i:
	return Rect2i(
		Vector2i(int(voxel_px.x / tile_size) * tile_size, int(voxel_px.y / tile_size) * tile_size),
		Vector2i(tile_size, tile_size)
	)


func _mark_global_tile_dirty(slice_index: int, voxel_xz: Vector2i, layer: String = "scene", tile_size: int = GLOBAL_VOXEL_TILE_SIZE) -> void:
	if _volume.is_empty():
		return
	var xz_res := int(_volume.get("xz_res", _base_res))
	if xz_res <= 0:
		return
	var px := Vector2i(
		clampi(voxel_xz.x, 0, xz_res - 1),
		clampi(voxel_xz.y, 0, xz_res - 1)
	)
	var key := _global_tile_key(slice_index, px, layer, tile_size)
	_global_dirty_tiles[key] = {
		"tile_id": key,
		"clip_level": 0,
		"layer": layer,
		"slice_index": slice_index,
		"tile_size": tile_size,
		"bounds": _global_tile_bounds(px, tile_size),
		"write_tick": _generation_tick,
		"commit_tick": _committed_tick,
		"dirty": true,
	}
	_global_field_dirty = true


func _clip_base_rect(rect: Rect2i) -> Rect2i:
	return rect.intersection(Rect2i(0, 0, _base_res, _base_res))


func _mark_global_rect_dirty(base_rect: Rect2i, slice_indices: Array = [], include_collision: bool = true) -> void:
	var clipped := _clip_base_rect(base_rect)
	if clipped.size.x <= 0 or clipped.size.y <= 0:
		return
	_global_dirty_rects.append(clipped)
	if _volume.is_empty():
		_global_field_dirty = true
		return

	var xz_res := int(_volume.get("xz_res", _base_res))
	var start_px := _volume_px_from_base(clipped.position, xz_res)
	var end_base := Vector2i(
		clipped.position.x + clipped.size.x - 1,
		clipped.position.y + clipped.size.y - 1
	)
	var end_px := _volume_px_from_base(end_base, xz_res)
	var tile_min_x := int(mini(start_px.x, end_px.x) / GLOBAL_VOXEL_TILE_SIZE)
	var tile_min_y := int(mini(start_px.y, end_px.y) / GLOBAL_VOXEL_TILE_SIZE)
	var tile_max_x := int(maxi(start_px.x, end_px.x) / GLOBAL_VOXEL_TILE_SIZE)
	var tile_max_y := int(maxi(start_px.y, end_px.y) / GLOBAL_VOXEL_TILE_SIZE)

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
				var tile_px := Vector2i(tx * GLOBAL_VOXEL_TILE_SIZE, ty * GLOBAL_VOXEL_TILE_SIZE)
				_mark_global_tile_dirty(si, tile_px, "scene")
				if include_collision:
					_mark_global_tile_dirty(si, tile_px, "collision")


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
	var color: Color = layer.get("color", record.get("color", Color.WHITE))
	var value := clampf(complexity, 0.0, 1.0)
	color.a = value
	var auto_object_id := str(record.get("auto_object_id", record.get("auto_id", record.get("id", ""))))
	var auto_instance_id := int(record.get("auto_instance_id", record.get("instance_id", 0)))
	var instance_mesh_id := int(record.get("instance_mesh_id", record.get("mesh_instance_id", record.get("instance_id", auto_instance_id))))
	return {
		"type": "SceneVoxel",
		"occupied": value > VOXEL_OCCUPIED_EPSILON,
		"value": value,
		"color": color,
		"complexity": value,
		"auto_id": auto_object_id,
		"auto_object_id": auto_object_id,
		"auto_instance_id": auto_instance_id,
		"instance_id": auto_instance_id,
		"instance_mesh_id": instance_mesh_id,
		"mesh_instance_id": instance_mesh_id,
		"record_id": str(record.get("id", "")),
		"mesh_name": str(record.get("mesh_name", "")),
		"node_path": str(record.get("node_path", "")),
		"object_type": str(record.get("object_type", record.get("type", ""))),
		"object_subtype": str(record.get("object_subtype", "")),
		"auto_source": str(record.get("auto_source", record.get("placement_source", ""))),
		"band": str(layer.get("band", "")),
		"channel": int(layer.get("channel", -1)),
		"slice_index": slice_index,
		"voxel_xz": voxel_px,
		"base_pixel": layer.get("base_pixel", record.get("base_pixel", Vector2i.ZERO)),
		"volume_xz_resolution": int(_volume.get("xz_res", _base_res)),
	}


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
			source_voxel["collision_voxels"] = collision_layers.duplicate(true)
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
	var scene_voxel := source_voxel.duplicate(true)
	var source_type := str(scene_voxel.get("source_voxel_type", scene_voxel.get("type", "AutoSceneVoxel")))
	var value := _voxel_value(scene_voxel)
	scene_voxel["type"] = "SceneVoxel"
	scene_voxel["value"] = value
	scene_voxel["complexity"] = value
	scene_voxel["occupied"] = value > VOXEL_OCCUPIED_EPSILON
	var color: Color = scene_voxel.get("color", Color.WHITE)
	color.a = value
	scene_voxel["color"] = color
	scene_voxel["source_voxel_types"] = [source_type]
	scene_voxel["dominant_source_type"] = source_type
	scene_voxel["blend_mode"] = str(scene_voxel.get("blend_mode", "copy"))
	scene_voxel["commit_tick"] = commit_tick
	scene_voxel.erase("source_voxel_type")
	return scene_voxel


func _blend_color(a: Color, b: Color, mix_ratio: float) -> Color:
	var ratio := clampf(mix_ratio, 0.0, 1.0)
	return a.lerp(b, ratio)


func _merge_target_with_auto(target_voxel: Dictionary, auto_voxel: Dictionary, commit_tick: int) -> Dictionary:
	if target_voxel.is_empty() and auto_voxel.is_empty():
		return {}
	if target_voxel.is_empty():
		return auto_voxel
	if auto_voxel.is_empty():
		return target_voxel
	var target_mix := clampf(float(target_voxel.get("target_mix", 1.0)), 0.0, 1.0)
	if target_mix >= 1.0:
		var merged := target_voxel.duplicate(true)
		merged["_has_target"] = true
		merged["_has_auto"] = true
		return merged
	if target_mix <= 0.0:
		var merged := auto_voxel.duplicate(true)
		merged["_has_target"] = true
		merged["_has_auto"] = true
		return merged
	var merged := target_voxel.duplicate(true)
	var target_value := float(target_voxel.get("value", 0.0))
	var auto_value := float(auto_voxel.get("value", target_value))
	var final_value := clampf(target_value * target_mix + auto_value * (1.0 - target_mix), 0.0, 1.0)
	merged["value"] = final_value
	merged["complexity"] = final_value
	var target_color: Color = target_voxel.get("color", Color.WHITE)
	var auto_color: Color = auto_voxel.get("color", target_color)
	var final_color := _blend_color(auto_color, target_color, target_mix)
	final_color.a = final_value
	merged["color"] = final_color
	merged["_has_target"] = true
	merged["_has_auto"] = true
	return merged


func _merge_voxel_sources(auto_voxel: Dictionary, brush_voxel: Dictionary, commit_tick: int, target_voxel: Dictionary = {}) -> Dictionary:
	var effective_auto := _merge_target_with_auto(target_voxel, auto_voxel, commit_tick)
	if effective_auto.is_empty() and brush_voxel.is_empty():
		return {}
	if effective_auto.is_empty():
		return _finalize_scene_voxel_from_source(brush_voxel, commit_tick)
	if brush_voxel.is_empty():
		var result := _finalize_scene_voxel_from_source(effective_auto, commit_tick)
		var types: Array = []
		if effective_auto.get("_has_target", false) or not target_voxel.is_empty():
			types.append("TargetSceneVoxel")
		if effective_auto.get("_has_auto", false) or not auto_voxel.is_empty():
			types.append("AutoSceneVoxel")
		if types.is_empty():
			types.append(str(effective_auto.get("source_voxel_type", "AutoSceneVoxel")))
		result["source_voxel_types"] = types
		result["dominant_source_type"] = types[0]
		return result

	var auto_mix := clampf(float(brush_voxel.get("auto_mix", 0.0)), 0.0, 1.0)
	if auto_mix <= 0.0:
		var brush_only := _finalize_scene_voxel_from_source(brush_voxel, commit_tick)
		brush_only["source_voxel_types"] = ["BrushSceneVoxel"]
		brush_only["dominant_source_type"] = "BrushSceneVoxel"
		brush_only["blend_mode"] = "brush"
		return brush_only
	if auto_mix >= 1.0:
		var auto_only := _finalize_scene_voxel_from_source(effective_auto, commit_tick)
		var types: Array = []
		if not target_voxel.is_empty():
			types.append("TargetSceneVoxel")
		if not auto_voxel.is_empty():
			types.append("AutoSceneVoxel")
		if types.is_empty():
			types.append("AutoSceneVoxel")
		auto_only["source_voxel_types"] = types
		auto_only["dominant_source_type"] = types[0]
		auto_only["blend_mode"] = "auto"
		return auto_only

	var blended := _finalize_scene_voxel_from_source(brush_voxel, commit_tick)
	blended["type"] = "SceneVoxel"
	var types: Array = []
	if not target_voxel.is_empty():
		types.append("TargetSceneVoxel")
	if not auto_voxel.is_empty():
		types.append("AutoSceneVoxel")
	types.append("BrushSceneVoxel")
	blended["source_voxel_types"] = types
	blended["dominant_source_type"] = "BrushSceneVoxel" if auto_mix < 0.5 else types[0]
	blended["blend_mode"] = "mix"
	blended["auto_mix"] = auto_mix
	var brush_value := float(brush_voxel.get("value", 0.0))
	var effective_value := float(effective_auto.get("value", brush_value))
	var final_value := clampf(brush_value * (1.0 - auto_mix) + effective_value * auto_mix, 0.0, 1.0)
	blended["value"] = final_value
	blended["complexity"] = final_value
	var brush_color: Color = brush_voxel.get("color", Color.WHITE)
	var effective_color: Color = effective_auto.get("color", brush_color)
	var final_color := _blend_color(brush_color, effective_color, auto_mix)
	final_color.a = final_value
	blended["color"] = final_color
	blended["occupied"] = final_value > VOXEL_OCCUPIED_EPSILON
	return blended


func _write_source_voxel_delta(source_voxel: Dictionary) -> void:
	if source_voxel.is_empty():
		return
	var tick := int(source_voxel.get("write_tick", _generation_tick))
	var delta := _ensure_source_delta_tick(tick)
	var branch := _source_delta_branch(str(source_voxel.get("source_voxel_type", source_voxel.get("type", "AutoSceneVoxel"))))
	var bucket: Dictionary = delta.get(branch, {})
	var slice_index := int(source_voxel.get("slice_index", -1))
	var voxel_xz = source_voxel.get("voxel_xz", Vector2i(-1, -1))
	if slice_index < 0 or not voxel_xz is Vector2i:
		return
	var key := _scene_voxel_key(slice_index, voxel_xz)
	if not bucket.has(key) or _source_beats_current(source_voxel, bucket.get(key, {})):
		bucket[key] = source_voxel.duplicate(true)
		_mark_global_tile_dirty(slice_index, voxel_xz, "scene")
	delta[branch] = bucket
	_source_voxel_deltas[tick] = delta


func _rebuild_global_voxel_field(tile_size: int = GLOBAL_VOXEL_TILE_SIZE) -> Dictionary:
	if _volume.is_empty():
		_global_voxel_field = {}
		return {}
	var xz_res: int = _volume.xz_res
	var scene_voxels: Dictionary = _volume.get("scene_voxels", {})
	var collision_voxels: Dictionary = _volume.get("collision_voxels", {})
	var dirty_tiles_snapshot := _global_dirty_tiles.duplicate(true)
	var dirty_rects_snapshot := _global_dirty_rects.duplicate(true)
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
		var tile_key := _global_tile_key(int(voxel.get("slice_index", 0)), px, "scene", tile_size)
		var tile: Dictionary = tiles.get(tile_key, {
			"tile_id": tile_key,
			"clip_level": 0,
			"layer": "scene",
			"tile_size": tile_size,
			"bounds": _global_tile_bounds(px, tile_size),
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
		var tile_key := _global_tile_key(int(voxel.get("slice_index", 0)), px, "collision", tile_size)
		var tile: Dictionary = tiles.get(tile_key, {
			"tile_id": tile_key,
			"clip_level": 0,
			"layer": "collision",
			"tile_size": tile_size,
			"bounds": _global_tile_bounds(px, tile_size),
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

	_global_voxel_field = {
		"type": "GlobalVoxelField",
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
	_global_dirty_tiles.clear()
	_global_dirty_rects.clear()
	_global_field_dirty = false
	return _global_voxel_field.duplicate(true)


func _write_scene_voxel(scene_voxel: Dictionary) -> void:
	if _volume.is_empty() or scene_voxel.is_empty():
		return
	if not _volume.has("scene_voxels"):
		_volume["scene_voxels"] = {}
	var scene_voxels: Dictionary = _volume.scene_voxels
	var key := _scene_voxel_key(int(scene_voxel.slice_index), scene_voxel.voxel_xz)
	scene_voxels[key] = scene_voxel.duplicate(true)
	_volume["scene_voxels"] = scene_voxels
	_mark_global_tile_dirty(int(scene_voxel.slice_index), scene_voxel.voxel_xz, "scene")
	_global_field_dirty = true


func _stamp_volume_slices(
	base_px: Vector2i,
	radius_px: int,
	complexity: float,
	slice_indices: Array[int],
	scene_voxel_template: Dictionary = {},
	write_to_source_delta: bool = false,
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
					scene_voxel["complexity"] = v
					scene_voxel["occupied"] = v > VOXEL_OCCUPIED_EPSILON
					var color: Color = scene_voxel.get("color", Color.WHITE)
					color.a = v
					scene_voxel["color"] = color
					if write_to_source_delta:
						scene_voxel = _prepare_source_record(scene_voxel, write_tick if write_tick >= 0 else _generation_tick)
						_write_source_voxel_delta(scene_voxel)
					else:
						_write_scene_voxel(scene_voxel)
		slices[si] = img

	_volume["slices"] = slices
	return voxel_px


func _fallback_layers_from_record(record: Dictionary) -> Array[Dictionary]:
	var layers: Array[Dictionary] = []
	var base_px: Vector2i = record.get("base_pixel", Vector2i.ZERO)
	var affected: Array = record.get("affected_bands", [])
	for entry_raw in affected:
		if not entry_raw is Dictionary:
			continue
		var entry := entry_raw as Dictionary
		var ch := _layer_channel(entry)
		if ch < 0:
			continue
		var band: Dictionary = _bands[ch]
		layers.append({
			"band": band.name,
			"channel": ch,
			"base_pixel": base_px,
			"radius": entry.get("radius", 0.0),
			"radius_px": _layer_radius_px(entry),
			"y_min": band.min_h,
			"y_max": band.max_h,
			"color": entry.get("color", band.color),
			"complexity": entry.get("complexity", record.get("complexity", band.color.a)),
			"slice_indices": [],
		})
	return layers


## Apply an actual placed mesh's voxel record into source deltas and buffers.
## This keeps runtime MeshInstance3D placement and the occupancy/voxel volume in sync.
func apply_mesh_voxel_record(record: Dictionary, defer_blend: bool = false, generation_tick: int = -1) -> Dictionary:
	if record.is_empty():
		return {}

	var write_tick := generation_tick if generation_tick >= 0 else _next_write_tick()
	_ensure_source_delta_tick(write_tick)
	var rec := _prepare_source_record(record, write_tick)
	var record_id := str(rec.get("id", "mesh_%d" % _mesh_voxel_records.size()))
	rec["id"] = record_id
	var layers: Array = rec.get(DEPRECATED_SENCE_LAYER_VOXEL_KEY, rec.get(DEPRECATED_VOXEL_LAYERS_KEY, []))
	if layers.is_empty():
		layers = _fallback_layers_from_record(rec)

	var updated_layers: Array[Dictionary] = []
	var applied_channels: Array[int] = []
	var rec_base_px: Vector2i = rec.get("base_pixel", Vector2i.ZERO)
	var collision_layers: Array = rec.get("collision_voxels", [])
	var updated_collision_layers := _make_source_collision_voxels(rec_base_px, collision_layers, rec)
	rec["collision_voxels"] = updated_collision_layers

	for layer_raw in layers:
		if not layer_raw is Dictionary:
			continue
		var source_layer := layer_raw as Dictionary
		var layer := source_layer.duplicate(true)
		var ch := _layer_channel(layer)
		if ch < 0:
			updated_layers.append(layer)
			continue

		var band: Dictionary = _bands[ch]
		var base_px: Vector2i = layer.get("base_pixel", rec_base_px)
		var radius_px := _layer_radius_px(layer)
		var complexity := clampf(float(layer.get("complexity", rec.get("complexity", band.color.a))), 0.0, 1.0)
		var slice_indices := _slice_indices_for_layer(layer, ch)
		var source_voxel_template := {}
		if not _volume.is_empty():
			var template_voxel_px := _volume_px_from_base(base_px, int(_volume.xz_res))
			source_voxel_template = _make_source_scene_voxel(rec, layer, -1, template_voxel_px, complexity)

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

		layer["band"] = band.name
		layer["channel"] = ch
		layer["base_pixel"] = base_px
		layer["voxel_xz"] = voxel_px
		layer["radius_px"] = radius_px
		layer["complexity"] = complexity
		layer["color"] = layer.get("color", band.color)
		layer["slice_indices"] = slice_indices
		layer["height_buffer_applied"] = true
		updated_layers.append(layer)

		if not applied_channels.has(ch):
			applied_channels.append(ch)

	rec["base_pixel"] = rec_base_px
	if _volume.is_empty():
		rec["voxel_xz"] = rec_base_px
		rec["volume_xz_resolution"] = _base_res
	else:
		rec["voxel_xz"] = _volume_px_from_base(rec_base_px, int(_volume.xz_res))
		rec["volume_xz_resolution"] = int(_volume.xz_res)
	rec[DEPRECATED_SENCE_LAYER_VOXEL_KEY] = updated_layers
	rec.erase(DEPRECATED_VOXEL_LAYERS_KEY)
	rec["collision_voxels"] = updated_collision_layers
	rec["height_buffer_applied"] = not applied_channels.is_empty()
	rec["height_buffer_channels"] = applied_channels
	rec["collision_source_attached"] = not updated_collision_layers.is_empty()
	rec["collision_buffer_applied"] = false

	if _mesh_voxel_record_index.has(record_id):
		var idx: int = _mesh_voxel_record_index[record_id]
		_mesh_voxel_records[idx] = rec
	else:
		_mesh_voxel_record_index[record_id] = _mesh_voxel_records.size()
		_mesh_voxel_records.append(rec)

	if not defer_blend and not _volume.is_empty():
		blend_scene_voxels(write_tick)

	return rec


## Get a band's color (RGBA). RGB = debug color, A = complexity.
func get_band_color(band_name: String) -> Color:
	if not _band_index.has(band_name):
		return Color.WHITE
	return _bands[_band_index[band_name]].color


## Get a band's complexity value (0.0-1.0). Shorthand for color.a.
func get_band_complexity(band_name: String) -> float:
	if not _band_index.has(band_name):
		return 0.0
	return _bands[_band_index[band_name]].color.a


## Extract a single band's occupancy channel as a single-channel Image at base_res.
func get_band_occupancy(band_name: String) -> Image:
	if not _band_index.has(band_name):
		return Image.create(1, 1, false, Image.FORMAT_RF)
	var ch: int = _band_index[band_name]
	var mask := Image.create(_base_res, _base_res, false, Image.FORMAT_RF)
	for y in range(_base_res):
		for x in range(_base_res):
			var v: float = _occupancy.get_pixelv(Vector2i(x, y))[ch]
			if v > 0.01:
				mask.set_pixelv(Vector2i(x, y), Color(v, 0.0, 0.0, 0.0))
	return mask


## Alias: extract band occupancy at base resolution.
func get_band_mask_at_base_res(band_name: String) -> Image:
	return get_band_occupancy(band_name)


## Get a combined debug visualization using each band's assigned color.
## Reads directly from the packed RGBA _occupancy texture.
func get_combined_debug_image() -> Image:
	var vis := Image.create(_base_res, _base_res, false, Image.FORMAT_RGBAF)
	vis.fill(Color(0.0, 0.0, 0.0, 0.0))
	for bi in range(_bands.size()):
		var bc: Color = _bands[bi].color
		for y in range(_base_res):
			for x in range(_base_res):
				var v: float = _occupancy.get_pixelv(Vector2i(x, y))[bi]
				if v > 0.01:
					var c: Color = vis.get_pixelv(Vector2i(x, y))
					c.r = maxf(c.r, bc.r * v)
					c.g = maxf(c.g, bc.g * v)
					c.b = maxf(c.b, bc.b * v)
					c.a = maxf(c.a, v)
					vis.set_pixelv(Vector2i(x, y), c)
	return vis


## Clear a specific band's channel in the packed occupancy.
func clear_band(band_name: String) -> void:
	if not _band_index.has(band_name):
		return
	var ch: int = _band_index[band_name]
	for y in range(_base_res):
		for x in range(_base_res):
			var c: Color = _occupancy.get_pixelv(Vector2i(x, y))
			c[ch] = 0.0
			_occupancy.set_pixelv(Vector2i(x, y), c)


## Clear all bands.
func clear_all() -> void:
	_occupancy.fill(Color(0.0, 0.0, 0.0, 0.0))
	_volume = {}
	_mesh_voxel_records.clear()
	_mesh_voxel_record_index.clear()
	_source_voxel_deltas.clear()
	_scene_state_by_tick.clear()
	_global_voxel_field.clear()
	_global_dirty_tiles.clear()
	_global_dirty_rects.clear()
	_generation_tick = 1
	_committed_tick = 0
	_global_field_dirty = true


## Get band info for debug printing.
func get_band_stats() -> Array[Dictionary]:
	var stats: Array[Dictionary] = []
	for bi in range(_bands.size()):
		var band: Dictionary = _bands[bi]
		var occupied := 0
		var total: int = _base_res * _base_res
		for y in range(_base_res):
			for x in range(_base_res):
				if _occupancy.get_pixelv(Vector2i(x, y))[bi] > 0.01:
					occupied += 1
		stats.append({
			"name": band.name,
			"height_range": "%.1f-%.1fm" % [band.min_h, band.max_h],
			"resolution": "%d×%d" % [_base_res, _base_res],
			"color": band.color,
			"occupied": "%d/%d (%.1f%%)" % [occupied, total, float(occupied) / float(total) * 100.0],
		})
	return stats


## ─── 3D Voxel Volume ───
##
## Aggregates all 2D band occupancy layers into a unified 3D voxel grid.
## Axes: X = terrain X, Z = terrain Z, Y = height above terrain.
## Each band can be subdivided into multiple Y-slices for finer vertical resolution.
## All slices share the same XZ resolution (resampled from each band's native res).
##
## Volume layout (Y-axis, bottom to top):
##   band "ground"     → slices 0..n0-1
##   band "understory" → slices n0..n0+n1-1
##   ...
## Each voxel stores: occupancy (float), band_index (int), color (Color),
## and complexity (float).

## Cached voxel volume data.
var _volume: Dictionary = {}
## { "xz_res": int, "slices": Array[Image], "slice_meta": Array[Dictionary] }
## slice_meta[i] = { "band_idx": int, "band_name": String, "y_min": float,
##                   "y_max": float, "complexity": float, "color": Color }
## scene_voxels["slice:x:z"] = { "type": "SceneVoxel", "color": Color,
##                               "complexity": float, "auto_object_id": String,
##                               "instance_mesh_id": int, ... }

## Per placed mesh voxel records. These connect runtime MeshInstance3D nodes back
## to the voxel/band data that was stamped for them.
var _mesh_voxel_records: Array[Dictionary] = []
var _mesh_voxel_record_index: Dictionary = {}
var _source_voxel_deltas: Dictionary = {}
var _scene_state_by_tick: Dictionary = {}
var _global_voxel_field: Dictionary = {}
var _global_dirty_tiles: Dictionary = {}
var _global_dirty_rects: Array[Rect2i] = []
var _generation_tick: int = 1
var _committed_tick: int = 0
var _global_field_dirty: bool = true


func _make_mesh_voxel_record(
	mesh_id: String,
	mesh_type: String,
	base_px: Vector2i,
	world_pos: Vector3,
	inst_color: Color,
	inst_complexity: float,
	inst_bands: Array[Dictionary],
	scale_value: float,
	collision_voxels: Array[Dictionary] = []
) -> Dictionary:
	var layers: Array[Dictionary] = []
	for entry in inst_bands:
		var bi: int = int(entry.channel)
		var band: Dictionary = _bands[bi]
		layers.append({
			"band": band.name,
			"channel": bi,
			"base_pixel": base_px,
			"radius": entry.radius,
			"radius_px": _radius_to_px(float(entry.radius)),
			"y_min": band.min_h,
			"y_max": band.max_h,
			"color": band.color,
			"complexity": band.color.a,
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
		"affected_bands": inst_bands.duplicate(true),
		"collision_voxels": collision_voxels.duplicate(true),
	}
	record[DEPRECATED_SENCE_LAYER_VOXEL_KEY] = layers
	return record


func _register_mesh_voxel_record(record: Dictionary) -> Dictionary:
	var record_id: String = str(record.get("id", "mesh_%d" % _mesh_voxel_records.size()))
	record["id"] = record_id
	_mesh_voxel_record_index[record_id] = _mesh_voxel_records.size()
	_mesh_voxel_records.append(record)
	return record


func _update_mesh_voxel_records_for_volume() -> void:
	if _volume.is_empty():
		return
	var xz_res: int = _volume.xz_res
	var meta: Array = _volume.slice_meta
	for ri in range(_mesh_voxel_records.size()):
		var record: Dictionary = _mesh_voxel_records[ri]
		var base_px: Vector2i = record.get("base_pixel", Vector2i.ZERO)
		var vx := clampi(int(float(base_px.x) / float(_base_res) * float(xz_res)), 0, xz_res - 1)
		var vz := clampi(int(float(base_px.y) / float(_base_res) * float(xz_res)), 0, xz_res - 1)
		record["voxel_xz"] = Vector2i(vx, vz)
		record["volume_xz_resolution"] = xz_res

		var layers: Array = record.get(DEPRECATED_SENCE_LAYER_VOXEL_KEY, record.get(DEPRECATED_VOXEL_LAYERS_KEY, []))
		for li in range(layers.size()):
			var layer: Dictionary = layers[li]
			var slice_indices: Array[int] = []
			for si in range(meta.size()):
				var m: Dictionary = meta[si]
				if int(m.band_idx) == int(layer.channel):
					slice_indices.append(si)
			layer["voxel_xz"] = Vector2i(vx, vz)
			layer["slice_indices"] = slice_indices
			layers[li] = layer
		record[DEPRECATED_SENCE_LAYER_VOXEL_KEY] = layers
		record.erase(DEPRECATED_VOXEL_LAYERS_KEY)
		var collision_layers: Array = record.get("collision_voxels", [])
		for ci in range(collision_layers.size()):
			if not collision_layers[ci] is Dictionary:
				continue
			var collision_layer := (collision_layers[ci] as Dictionary).duplicate(true)
			collision_layer["voxel_xz"] = Vector2i(vx, vz)
			collision_layer["volume_xz_resolution"] = xz_res
			collision_layers[ci] = collision_layer
		record["collision_voxels"] = collision_layers
		_mesh_voxel_records[ri] = record
		_mesh_voxel_record_index[str(record.id)] = ri


func _rebuild_scene_voxels_from_records() -> void:
	if _volume.is_empty():
		return
	var write_tick := _next_write_tick()
	begin_generation_tick(write_tick)
	_volume["scene_voxels"] = {}
	var records := get_mesh_voxel_records()
	for record in records:
		apply_mesh_voxel_record(record, true, write_tick)


func blend_scene_voxels(tick: int = -1) -> Dictionary:
	if _volume.is_empty():
		return {}

	var commit_tick := tick if tick >= 0 else _generation_tick
	var delta: Dictionary = _source_voxel_deltas.get(commit_tick, {})
	var auto_sources: Dictionary = delta.get("auto", {})
	var brush_sources: Dictionary = delta.get("brush", {})
	var target_sources: Dictionary = delta.get("target", {})
	var final_scene_voxels: Dictionary = _volume.get("scene_voxels", {}).duplicate(true)
	var keys: Dictionary = {}

	for key in auto_sources.keys():
		keys[key] = true
	for key in brush_sources.keys():
		keys[key] = true
	for key in target_sources.keys():
		keys[key] = true

	for key in keys.keys():
		var auto_voxel: Dictionary = auto_sources.get(key, {})
		var brush_voxel: Dictionary = brush_sources.get(key, {})
		var target_voxel: Dictionary = target_sources.get(key, {})
		if not brush_voxel.is_empty() and _source_modifies_key(brush_voxel, key):
			final_scene_voxels[key] = _merge_voxel_sources(auto_voxel, brush_voxel, commit_tick, target_voxel)
		elif not target_voxel.is_empty() or not auto_voxel.is_empty():
			final_scene_voxels[key] = _merge_voxel_sources(auto_voxel, {}, commit_tick, target_voxel)
		elif not brush_voxel.is_empty():
			final_scene_voxels[key] = _finalize_scene_voxel_from_source(brush_voxel, commit_tick)

	_volume["scene_voxels"] = final_scene_voxels
	_rebuild_collision_cache_from_scene_voxels(final_scene_voxels)
	_scene_state_by_tick[commit_tick] = final_scene_voxels.duplicate(true)
	_committed_tick = max(_committed_tick, commit_tick)
	_generation_tick = max(_generation_tick, commit_tick + 1)
	_global_field_dirty = true
	_rebuild_global_voxel_field()
	return final_scene_voxels.duplicate(true)


## Build a 3D voxel volume from all band occupancy data.
## xz_resolution: common XZ size for all slices (default = base_res / 2).
## subdivisions_per_band: how many Y-slices per band (default = 1; use more for
##   thicker bands like "understory" to get finer vertical detail).
##   Can be a single int (same for all bands) or an Array[int] per band.
func build_voxel_volume(
	xz_resolution: int = -1,
	subdivisions_per_band = 1,  # int or Array[int]
) -> Dictionary:
	var xz_res := xz_resolution if xz_resolution > 0 else maxi(_base_res / 2, 32)

	var sub_array: Array[int] = []
	if subdivisions_per_band is int:
		for _i in range(_bands.size()):
			sub_array.append(subdivisions_per_band as int)
	else:
		sub_array.assign(subdivisions_per_band)
	while sub_array.size() < _bands.size():
		sub_array.append(1)

	var slices: Array[Image] = []
	var slice_meta: Array[Dictionary] = []

	for bi in range(_bands.size()):
		var band: Dictionary = _bands[bi]
		var subs: int = maxi(sub_array[bi], 1)
		var band_thickness: float = band.max_h - band.min_h

		for si in range(subs):
			var y_min: float = band.min_h + band_thickness * float(si) / float(subs)
			var y_max: float = band.min_h + band_thickness * float(si + 1) / float(subs)

			# Resample from packed RGBA channel bi to common xz_res
			var slice_img := Image.create(xz_res, xz_res, false, Image.FORMAT_RF)
			slice_img.fill(Color(0.0, 0.0, 0.0, 0.0))

			for z in range(xz_res):
				for x in range(xz_res):
					var sx := clampi(int(float(x) / float(xz_res) * float(_base_res)), 0, _base_res - 1)
					var sz := clampi(int(float(z) / float(xz_res) * float(_base_res)), 0, _base_res - 1)
					var v: float = _occupancy.get_pixelv(Vector2i(sx, sz))[bi]
					if v > 0.01:
						slice_img.set_pixelv(Vector2i(x, z), Color(v, 0.0, 0.0, 0.0))

			slices.append(slice_img)
			slice_meta.append({
				"band_idx": bi,
				"band_name": band.name,
				"y_min": y_min,
				"y_max": y_max,
				"complexity": band.color.a,
				"color": band.color,
			})

	_volume = {
		"xz_res": xz_res,
		"total_slices": slices.size(),
		"slices": slices,
		"slice_meta": slice_meta,
		"scene_voxels": {},
		"collision_occupancy": _resample_collision_occupancy(xz_res),
		"collision_voxels": {},
	}
	var pending_dirty_rects := _global_dirty_rects.duplicate()
	_global_dirty_rects.clear()
	for dirty_rect in pending_dirty_rects:
		if dirty_rect is Rect2i:
			var typed_dirty_rect: Rect2i = dirty_rect
			_mark_global_rect_dirty(typed_dirty_rect)
	_update_mesh_voxel_records_for_volume()
	_rebuild_scene_voxels_from_records()
	blend_scene_voxels(_generation_tick)
	return _volume


## Query voxel occupancy at a world-space position (relative to terrain surface).
## height_above_terrain: meters above local terrain at (wx, wz).
## Returns: { "occupied": bool, "value": float, "band_name": String,
##            "color": Color, "complexity": float }
func query_voxel(wx: float, wz: float, height_above_terrain: float) -> Dictionary:
	if _volume.is_empty():
		return {"occupied": false, "value": 0.0, "band_name": "", "color": Color.BLACK, "complexity": 0.0}

	var xz_res: int = _volume.xz_res
	var half := _capture_size / 2.0
	var px := clampi(int((wx + half) / _capture_size * float(xz_res)), 0, xz_res - 1)
	var pz := clampi(int((wz + half) / _capture_size * float(xz_res)), 0, xz_res - 1)

	# Find which slice this height falls into
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
					typed_scene_voxel["complexity"] = committed_value
					var scene_color: Color = typed_scene_voxel.get("color", color)
					scene_color.a = committed_value
					typed_scene_voxel["color"] = scene_color
					typed_scene_voxel["band_name"] = str(typed_scene_voxel.get("band", m.band_name))
					typed_scene_voxel["slice_index"] = i
					typed_scene_voxel["voxel_xz"] = Vector2i(px, pz)
					return typed_scene_voxel
			return {
				"type": "SceneVoxel",
				"occupied": v > 0.01,
				"value": v,
				"band_name": m.band_name,
				"color": color,
				"complexity": v,
				"auto_id": "",
				"auto_object_id": "",
				"auto_instance_id": 0,
				"instance_mesh_id": 0,
				"mesh_instance_id": 0,
				"slice_index": i,
				"voxel_xz": Vector2i(px, pz),
			}

	return {"occupied": false, "value": 0.0, "band_name": "", "color": Color.BLACK, "complexity": 0.0}


func get_scene_voxels() -> Dictionary:
	if _volume.is_empty():
		return {}
	var scene_voxels: Dictionary = _volume.get("scene_voxels", {})
	return scene_voxels.duplicate(true)


func get_source_voxel_deltas(tick: int = -1) -> Dictionary:
	var read_tick := tick if tick >= 0 else _committed_tick
	var delta: Dictionary = _source_voxel_deltas.get(read_tick, {})
	return delta.duplicate(true)


func get_global_voxel_field() -> Dictionary:
	if _global_field_dirty and not _volume.is_empty():
		_rebuild_global_voxel_field()
	return _global_voxel_field.duplicate(true)


func invalidate_global_voxel_tile(slice_index: int, voxel_xz: Vector2i, layer: String = "scene") -> void:
	_mark_global_tile_dirty(slice_index, voxel_xz, layer)


func invalidate_global_voxel_rect(base_rect: Rect2i, slice_indices: Array = [], include_collision: bool = true) -> void:
	_mark_global_rect_dirty(base_rect, slice_indices, include_collision)


func get_global_voxel_dirty_tiles() -> Dictionary:
	return _global_dirty_tiles.duplicate(true)


func clear_global_voxel_dirty() -> void:
	_global_dirty_tiles.clear()
	_global_dirty_rects.clear()
	if not _global_voxel_field.is_empty():
		_global_voxel_field["dirty_tile_count"] = 0
		_global_voxel_field["dirty_tiles"] = {}
		_global_voxel_field["dirty_rects"] = []


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
			"band": m.band_name,
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
				"band": m.band_name,
				"y_range": "%.2f-%.2fm" % [m.y_min, m.y_max],
				"occupied": "%d/%d (%.1f%%)" % [count, total, float(count) / float(total) * 100.0],
				"color": m.color,
				"complexity": m.complexity,
			}

	var collision_img: Image = _volume.get("collision_occupancy", _resample_collision_occupancy(xz_res))
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
		"collision_occupancy_pct": "%.1f%%" % [float(collision_voxels) / float(xz_res * xz_res) * 100.0] if xz_res > 0 else "0%",
		"scene_voxels": int(_volume.get("scene_voxels", {}).size()),
		"global_voxel_tiles": int(get_global_voxel_field().get("tile_count", 0)),
		"generation_tick": _generation_tick,
		"committed_tick": _committed_tick,
		"occupancy_pct": "%.1f%%" % [float(occupied_voxels) / float(total_voxels) * 100.0] if total_voxels > 0 else "0%",
		"per_slice": per_slice,
	}


## Reset occupancy to empty (preserves band config and GPU state).
## Used when looping back for re-generation.
func reset_occupancy() -> void:
	_occupancy.fill(Color(0.0, 0.0, 0.0, 0.0))
	_collision_occupancy.fill(Color(0.0, 0.0, 0.0, 0.0))
	_volume = {}
	_mesh_voxel_records.clear()
	_mesh_voxel_record_index.clear()
	_source_voxel_deltas.clear()
	_scene_state_by_tick.clear()
	_global_voxel_field.clear()
	_global_dirty_tiles.clear()
	_global_dirty_rects.clear()
	_generation_tick = 1
	_committed_tick = 0
	_global_field_dirty = true


## Validate the 3D voxel volume against quality criteria.
## Returns { "passed": bool, "reason": String, "metrics": Dictionary }
##
## Criteria (configurable via params):
##   - min_ground_occupancy: minimum % of ground band occupied (vegetation exists)
##   - max_ground_occupancy: maximum % (not over-saturated)
##   - max_canopy_occupancy: canopy shouldn't fill too much
##   - min_diversity_score: at least N bands have meaningful occupancy
func validate_voxel(params: Dictionary = {}) -> Dictionary:
	if _volume.is_empty():
		return {"passed": false, "reason": "No voxel volume built", "metrics": {}}

	var min_ground_occ: float = params.get("min_ground_occupancy", 5.0)
	var max_ground_occ: float = params.get("max_ground_occupancy", 85.0)
	var max_canopy_occ: float = params.get("max_canopy_occupancy", 60.0)
	var min_diversity: int = params.get("min_diversity_score", 2)

	# Calculate per-band occupancy percentages
	var band_occ: Array[float] = []
	var xz_res: int = _volume.xz_res
	var slices: Array = _volume.slices
	var meta: Array = _volume.slice_meta
	var scene_voxels: Dictionary = _volume.get("scene_voxels", {})

	# Aggregate occupancy per band (may have multiple slices per band)
	var band_counts: Array[int] = []
	var band_totals: Array[int] = []
	for _i in range(_bands.size()):
		band_counts.append(0)
		band_totals.append(0)

	for i in range(slices.size()):
		var m: Dictionary = meta[i]
		var bi: int = m.band_idx
		var total := xz_res * xz_res
		band_totals[bi] += total

	if not scene_voxels.is_empty():
		for key in scene_voxels.keys():
			var scene_voxel = scene_voxels[key]
			if not scene_voxel is Dictionary:
				continue
			var voxel := scene_voxel as Dictionary
			if not bool(voxel.get("occupied", float(voxel.get("value", 0.0)) > 0.01)):
				continue
			var channel := int(voxel.get("channel", -1))
			if channel < 0:
				var band_name := str(voxel.get("band", voxel.get("band_name", "")))
				if _band_index.has(band_name):
					channel = int(_band_index[band_name])
			if channel >= 0 and channel < band_counts.size():
				band_counts[channel] += 1
	else:
		for i in range(slices.size()):
			var img: Image = slices[i]
			var m: Dictionary = meta[i]
			var bi: int = m.band_idx
			for z in range(xz_res):
				for x in range(xz_res):
					if img.get_pixelv(Vector2i(x, z)).r > 0.01:
						band_counts[bi] += 1

	for bi in range(_bands.size()):
		var pct := float(band_counts[bi]) / float(band_totals[bi]) * 100.0 if band_totals[bi] > 0 else 0.0
		band_occ.append(pct)

	var diversity := 0
	for pct in band_occ:
		if pct > 1.0:
			diversity += 1

	var metrics := {
		"band_occupancy_pct": band_occ,
		"band_names": _bands.map(func(b): return b.name),
		"diversity_score": diversity,
	}

	# Validate
	var ground_occ: float = band_occ[0] if band_occ.size() > 0 else 0.0
	var canopy_occ: float = band_occ[3] if band_occ.size() > 3 else 0.0

	if ground_occ < min_ground_occ:
		return {"passed": false, "reason": "Ground occupancy too low: %.1f%% < %.1f%%" % [ground_occ, min_ground_occ], "metrics": metrics}
	if ground_occ > max_ground_occ:
		return {"passed": false, "reason": "Ground occupancy too high: %.1f%% > %.1f%%" % [ground_occ, max_ground_occ], "metrics": metrics}
	if canopy_occ > max_canopy_occ:
		return {"passed": false, "reason": "Canopy occupancy too high: %.1f%% > %.1f%%" % [canopy_occ, max_canopy_occ], "metrics": metrics}
	if diversity < min_diversity:
		return {"passed": false, "reason": "Diversity too low: %d < %d bands active" % [diversity, min_diversity], "metrics": metrics}

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
			"band": m.band_name,
			"y_min": m.y_min,
			"y_max": m.y_max,
			"value": v,
			"occupied": v > 0.01,
			"color": m.color,
			"complexity": m.complexity,
		})
	return column
