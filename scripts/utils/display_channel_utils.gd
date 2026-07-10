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


## Builds the translucent rim/fresnel material used for guidance voxels.
## Returns a fresh StandardMaterial3D byte-identical to the previous inline copies.
static func create_fresnel_rim_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	mat.vertex_color_use_as_albedo = true
	mat.rim_enabled = true
	mat.rim = 0.65
	mat.rim_tint = 0.25
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
