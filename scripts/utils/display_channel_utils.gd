@tool
class_name DisplayChannelUtils
extends RefCounted

## Shared TargetSV guidance-display helpers.
##
## The meshfill brush (addons/meshfill_editor/meshfill_brush.gd) and the
## TargetSV setup util (scripts/utils/target_sv_setup.gd) both drive the same
## guidance voxel display: an identical display-channel enumeration, a
## fresnel/rim material, and a channel -> VoxelFieldDisplayGPU.VIEW_* mapping.
## Those three pieces live here so the two owners share one definition.

const VoxelFieldDisplayGPUScript := preload("res://scripts/utils/voxel_field_display_gpu.gd")

## Display-channel values (byte-identical to the old inline DisplayChannel enum).
const CHANNEL_COLOR := 0
const CHANNEL_COMPLEXITY := 1
const CHANNEL_COLLISION := 2


## Builds the translucent material used for guidance voxels.
## Unshaded: the vertex color (target Cd) IS the final color, so guidance voxels
## faithfully show their data color regardless of scene lights. The previous
## lit + fresnel-rim setup (rim 0.65, white-ish rim_tint 0.25) blew low-albedo
## voxels (the grey cliff/terrain) out to near-white at grazing angles — the very
## "cliff shows white" artifact. Kept translucent + double-sided so the overlay
## still reads as a see-through guidance field.
static func create_fresnel_rim_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	# Cd is copied from the source field as a linear rendering value. Marking it
	# as sRGB would decode it a second time (0.5 -> ~0.214) and make the copied
	# color substantially darker than the source mesh.
	mat.vertex_color_is_srgb = false
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return mat


## Maps a display channel to the VoxelFieldDisplayGPU VIEW_* mode.
static func channel_to_view_mode(channel: int) -> int:
	match channel:
		CHANNEL_COMPLEXITY:
			return VoxelFieldDisplayGPUScript.VIEW_COMPLEXITY
		CHANNEL_COLLISION:
			return VoxelFieldDisplayGPUScript.VIEW_COLLISION
	return VoxelFieldDisplayGPUScript.VIEW_TARGET_COLOR
