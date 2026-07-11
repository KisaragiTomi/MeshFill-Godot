#[compute]
#version 450

// Packs dense per-asset tile votes into schema-v1 candidate route records/ranges.
// Inputs:
//   asset_tile_votes[asset_id * tile_count + tile_id] = vote score
//   route_extent_radii[asset_id].xyz = route expansion radius in tile units
//   tile_summaries[] (optional)      = 8 uints per tile; when use_summary_filter != 0,
//                                      vote centers whose summary has no scene/collision
//                                      content are skipped (a dummy buffer is bound and
//                                      the filter disabled when no resident summaries exist)
// Outputs:
//   candidate_route_records[] = uvec4(tile_id, 0, 0, 0)
//   candidate_route_ranges[]  = uvec4(record_start, record_count, 0, 0)
//
// This producer pass preserves candidate sets, but writes each asset range
// in ascending tile_id order. It intentionally does not claim CPU score ordering.

layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer VoxelRegionVotes {
    float asset_tile_votes[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer RouteExtentRadii {
    uvec4 route_extent_radii[];
};

layout(set = 0, binding = 2, std430) restrict buffer RouteTileMarks {
    uint route_tile_marks[];
};

layout(set = 0, binding = 3, std430) restrict buffer CandidateRouteRecords {
    uvec4 candidate_route_records[];
};

layout(set = 0, binding = 4, std430) restrict buffer CandidateRouteRanges {
    uvec4 candidate_route_ranges[];
};

// @@GEN debug_set candidate_route_debug
layout(set = 0, binding = 5, std430) restrict buffer CandidateRouteDebug {
    uint candidate_route_debug[];
};
// @@END debug_set candidate_route_debug

layout(set = 0, binding = 6, std430) restrict readonly buffer TileSummaries {
    uint tile_summaries[];
};

layout(push_constant, std430) uniform Params {
    ivec4 tile_grid_asset_count; // xyz = tile grid dims, w = asset_count
    uint tile_count;
    uint record_capacity;
    float vote_threshold;
    uint summary_stride_uints;   // 8 = SCENE_VOXEL_TILE_SUMMARY_STRIDE_BYTES / 4
    uint use_summary_filter;     // 1 = skip vote centers whose tile summary is empty
    uint _pad0;
    uint _pad1;
    uint _pad2;
};

const uint SUMMARY_SCENE_COUNT_OFFSET = 4u;
const uint SUMMARY_COLLISION_COUNT_OFFSET = 5u;

// Returns true if the tile has scene or collision content
// (max(scene_count, collision_count) > 0). Empty tiles are pointless to
// expand — the score shader would discard them anyway.
bool tile_has_content(uint tile_id) {
    uint base = tile_id * summary_stride_uints;
    return tile_summaries[base + SUMMARY_SCENE_COUNT_OFFSET] > 0u
        || tile_summaries[base + SUMMARY_COLLISION_COUNT_OFFSET] > 0u;
}

// @@GEN route_tile_id_codec — SSOT scripts/utils/route_tile_shared_glsl.gd (regen; verify: tools/verify_glsl_gen_blocks.gd)
ivec3 tile_pos_from_id(uint tile_id) {
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
}
// @@END route_tile_id_codec

void main() {
    uint asset_count = uint(max(tile_grid_asset_count.w, 0));
    uint written_records = 0u;
    uint positive_votes = 0u;
    uint duplicate_marks = 0u;
    uint overflow_records = 0u;
    uint skipped_empty_tiles = 0u; // diagnostic: vote centers skipped by the summary filter

    if (asset_count == 0u || tile_count == 0u || record_capacity == 0u
        || (use_summary_filter != 0u && summary_stride_uints < 8u)) {
        candidate_route_debug[0] = 0u;
        candidate_route_debug[1] = 0u;
        candidate_route_debug[2] = 0u;
        candidate_route_debug[3] = 0u;
        return;
    }

    for (uint asset_id = 0u; asset_id < asset_count; asset_id++) {
        uint asset_base = asset_id * tile_count;
        for (uint tid = 0u; tid < tile_count; tid++) {
            route_tile_marks[asset_base + tid] = 0u;
        }

        uvec4 raw_radius = route_extent_radii[asset_id];
        ivec3 radius = ivec3(raw_radius.xyz);
        for (uint center_id = 0u; center_id < tile_count; center_id++) {
            if (use_summary_filter != 0u && !tile_has_content(center_id)) {
                skipped_empty_tiles++;
                continue;
            }

            float vote = asset_tile_votes[asset_base + center_id];
            if (vote <= vote_threshold) continue;
            positive_votes++;

            ivec3 center = tile_pos_from_id(center_id);
            for (int dz = -radius.z; dz <= radius.z; dz++) {
                for (int dy = -radius.y; dy <= radius.y; dy++) {
                    for (int dx = -radius.x; dx <= radius.x; dx++) {
                        ivec3 p = center + ivec3(dx, dy, dz);
                        if (!tile_in_bounds(p)) continue;
                        uint route_tid = tile_id_from_pos(p);
                        uint mark_index = asset_base + route_tid;
                        if (route_tile_marks[mark_index] != 0u) {
                            duplicate_marks++;
                        }
                        route_tile_marks[mark_index] = 1u;
                    }
                }
            }
        }

        uint range_start = written_records;
        uint range_count = 0u;
        for (uint tid = 0u; tid < tile_count; tid++) {
            if (route_tile_marks[asset_base + tid] == 0u) continue;
            if (written_records < record_capacity) {
                candidate_route_records[written_records] = uvec4(tid, 0u, 0u, 0u);
                written_records++;
                range_count++;
            } else {
                overflow_records++;
            }
        }
        candidate_route_ranges[asset_id] = uvec4(range_start, range_count, 0u, 0u);
    }

    candidate_route_debug[0] = written_records;
    candidate_route_debug[1] = positive_votes;
    candidate_route_debug[2] = duplicate_marks;
    candidate_route_debug[3] = overflow_records;

    candidate_route_debug[4] = 0x47505250u; // "GPRP"
    candidate_route_debug[5] = asset_count;
    candidate_route_debug[6] = tile_count;
    candidate_route_debug[7] = record_capacity;
    candidate_route_debug[8] = written_records;
    candidate_route_debug[9] = skipped_empty_tiles; // 0 when the summary filter is off
}
