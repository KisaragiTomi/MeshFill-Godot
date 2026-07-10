@tool
class_name RouteTileSharedGLSL
extends RefCounted

## SSOT (single source of truth) for GLSL blocks shared VERBATIM between
##   shaders/pack_candidate_route_records_from_votes.glsl
##   shaders/expand_scene_voxel_tile_routes.glsl
##
## This project compiles shaders from raw source strings via
## shader_compile_spirv_from_source() (no RDShaderFile preprocessor), so `#include`
## is NOT honoured. Shared code is therefore COPIED into each .glsl between
##   // @@GEN <name>
##   ...
##   // @@END <name>
## markers, and this file is the authority those copies are generated from.
##
## The desync guard tools/verify_glsl_gen_blocks.gd asserts each marked region in
## every shader equals block(<name>) (whitespace-trimmed). CI / a manual run fails
## if a shader's copy drifts from this SSOT.
##
## To change shared route-tile logic: edit it HERE, paste block(<name>) back into
## both shaders' marked regions, then run the verify tool.
##
## Currently shared: the route tile-id codec (encode/decode of the packed
## x + gx*(z + gz*y) tile id from tile_grid_asset_count) — the exact convention
## whose accidental divergence the 2026-07-10 audit flagged as a desync risk.

const BLOCKS := {
	"route_tile_id_codec":
"""ivec3 tile_pos_from_id(uint tile_id) {
    int x = int(tile_id % uint(tile_grid_asset_count.x));
    int z = int((tile_id / uint(tile_grid_asset_count.x)) % uint(tile_grid_asset_count.z));
    int y = int(tile_id / uint(tile_grid_asset_count.x * tile_grid_asset_count.z));
    return ivec3(x, y, z);
}

uint tile_id_from_pos(ivec3 p) {
    return uint(p.x + tile_grid_asset_count.x * (p.z + tile_grid_asset_count.z * p.y));
}

bool tile_in_bounds(ivec3 p) {
    return p.x >= 0 && p.x < tile_grid_asset_count.x
        && p.y >= 0 && p.y < tile_grid_asset_count.y
        && p.z >= 0 && p.z < tile_grid_asset_count.z;
}""",
}

## Shaders that carry each block, for the verify tool to scan.
const CONSUMERS := {
	"route_tile_id_codec": [
		"res://shaders/pack_candidate_route_records_from_votes.glsl",
		"res://shaders/expand_scene_voxel_tile_routes.glsl",
	],
}


static func block(name: String) -> String:
	return String(BLOCKS.get(name, "")).strip_edges()


static func block_names() -> Array:
	return BLOCKS.keys()
