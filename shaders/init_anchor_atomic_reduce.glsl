#[compute]
#version 450

// Select exactly one Fine Score candidate per live Anchor and build the two
// direct XZ-pixel lookup maps used by the one-pass atomic Reduce.
//
// The anchor collector guarantees at most one Anchor per (x,z) column. Seeds
// are accepted results from earlier batches and therefore obey the same
// unique-XZ contract. Map entries store index + 1 so zero-filled buffers are
// already valid empty maps.

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer FineCandidates {
    vec4 fine_candidates[];
};

layout(set = 0, binding = 1, std430) restrict readonly buffer AnchorCountBuf {
    uint anchor_count_dyn[];
};

layout(set = 0, binding = 2, std430) restrict writeonly buffer AnchorCandidateRef {
    uint anchor_candidate_ref[]; // candidate slot + 1; zero = no valid candidate
};

layout(set = 0, binding = 3, std430) restrict buffer AnchorValid {
    uint anchor_valid[];
};

layout(set = 0, binding = 4, std430) restrict writeonly buffer AnchorAtPixel {
    uint anchor_at_pixel[]; // anchor id + 1; zero = empty
};

layout(set = 0, binding = 5, std430) restrict readonly buffer SeedPlacements {
    vec4 seed_placements[]; // xyz = voxel origin, w = asset index
};

layout(set = 0, binding = 6, std430) restrict writeonly buffer SeedAtPixel {
    uint seed_at_pixel[]; // seed id + 1; zero = empty
};

layout(push_constant, std430) uniform Params {
    ivec4 counts; // topk, anchor_capacity, seed_count, grid_x
    ivec4 grid;   // grid_z, unused x3
};

const uint RECORD_STRIDE = 4u;

bool in_pixel_grid(ivec2 p, int grid_x, int grid_z) {
    return p.x >= 0 && p.y >= 0 && p.x < grid_x && p.y < grid_z;
}

void main() {
    uint i = gl_GlobalInvocationID.x;
    uint topk = uint(max(counts.x, 1));
    uint anchor_capacity = uint(max(counts.y, 0));
    uint anchor_count = min(anchor_count_dyn[0], anchor_capacity);
    uint seed_count = uint(max(counts.z, 0));
    int grid_x = max(counts.w, 1);
    int grid_z = max(grid.x, 1);

    if (i < anchor_count) {
        uint best_slot = 0xFFFFFFFFu;
        float best_score = -3.402823466e+38;
        for (uint k = 0u; k < topk; k++) {
            uint slot = i * topk + k;
            uint base = slot * RECORD_STRIDE;
            if (fine_candidates[base + 3u].y < 0.5) {
                continue;
            }
            float score = fine_candidates[base + 0u].w;
            if (isnan(score)) {
                continue;
            }
            // Keep the tie-break explicit: within one Anchor, a smaller slot
            // is the smaller k because slots are laid out anchor * topk + k.
            if (best_slot == 0xFFFFFFFFu || score > best_score
                    || (score == best_score && slot < best_slot)) {
                best_slot = slot;
                best_score = score;
            }
        }
        if (best_slot != 0xFFFFFFFFu) {
            anchor_candidate_ref[i] = best_slot + 1u;
            anchor_valid[i] = 1u;
            vec3 origin = fine_candidates[best_slot * RECORD_STRIDE + 0u].xyz;
            ivec2 pixel = ivec2(round(origin.x), round(origin.z));
            if (in_pixel_grid(pixel, grid_x, grid_z)) {
                anchor_at_pixel[pixel.x + grid_x * pixel.y] = i + 1u;
            } else {
                // An out-of-grid candidate cannot participate safely.
                anchor_candidate_ref[i] = 0u;
                anchor_valid[i] = 0u;
            }
        }
    }

    if (i < seed_count) {
        ivec2 pixel = ivec2(round(seed_placements[i].x), round(seed_placements[i].z));
        if (in_pixel_grid(pixel, grid_x, grid_z)) {
            seed_at_pixel[pixel.x + grid_x * pixel.y] = i + 1u;
        }
    }
}
