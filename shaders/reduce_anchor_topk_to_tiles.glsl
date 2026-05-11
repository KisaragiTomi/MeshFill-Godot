#[compute]
#version 450

// Reduce anchor top-K results into per-asset tile vote scores.
// Single workgroup, serial scan — anchor counts are moderate (< 100K).
//
// For each anchor's top-K asset selections, compute which tile the anchor
// belongs to, and accumulate score into tile_votes[asset_id * tile_count + tile_id].
//
// Output is read back to CPU to produce per-asset sorted tile lists.

layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

// Input: anchors buffer (x, y, z, kind) — needed for tile_id computation
layout(set = 0, binding = 0, std430) restrict readonly buffer AnchorBuf {
    uvec4 anchors[];
};

// Input: top-K results from Pass B
layout(set = 0, binding = 1, std430) restrict readonly buffer TopKIn {
    uvec2 anchor_topk[];
};

// Output: tile vote scores per asset
// Layout: tile_votes[asset_id * tile_count + tile_id] += score
layout(set = 0, binding = 2, std430) restrict buffer TileVotes {
    float tile_votes[];
};

layout(push_constant, std430) uniform Params {
    ivec4 tile_grid_size_pad;   // xyz = tile grid dims, w = tile_count
    uint  anchor_count;
    uint  asset_count;
    uint  topk;
    uint  _pad0;
};

const uint TILE_SIZE = 8u;

int tile_id_from_voxel(ivec3 p) {
    int tx = p.x / int(TILE_SIZE);
    int ty = p.y / int(TILE_SIZE);
    int tz = p.z / int(TILE_SIZE);
    return tx + tile_grid_size_pad.x * (tz + tile_grid_size_pad.z * ty);
}

void main() {
    uint tile_count = uint(tile_grid_size_pad.w);
    uint ac = min(anchor_count, 100000u);
    uint k_max = min(topk, 8u);
    uint a_count = min(asset_count, 256u);

    for (uint ai = 0u; ai < ac; ai++) {
        uvec4 anchor = anchors[ai];
        int tid = tile_id_from_voxel(ivec3(anchor.xyz));
        if (tid < 0 || uint(tid) >= tile_count) continue;

        for (uint k = 0u; k < k_max; k++) {
            uvec2 entry = anchor_topk[ai * k_max + k];
            uint asset_id = entry.x;
            float score = uintBitsToFloat(entry.y);
            if (asset_id >= a_count || score < 0.0) continue;

            uint vote_idx = asset_id * tile_count + uint(tid);
            tile_votes[vote_idx] += score;
        }
    }
}
