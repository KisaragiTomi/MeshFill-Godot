---
description: GPU Sparse Tile Dispatch for Godot 4.x. Compacts active 2D tiles or 3D voxel tiles and generates indirect dispatch args for thread remapping. Use when implementing compute shader pipelines that process large sparse grids, sparse pixels, voxel volumes, SWE, fluid sim, density fields, occupancy masks, or GPU placement. Trigger terms: sparse dispatch, tile compaction, indirect dispatch, thread remapping, sparse pixel, sparse tile, sparse voxel, compute shader optimization, 稀疏调度, 线程重映射, 稀疏像素, 体素.
---

# Sparse Tile Dispatch (Godot 4.x)

GPU-driven sparse dispatch for skipping empty grid regions. A compact pass scans
the source activity field, emits only active tile coordinates, then writes
`indirect_args` for `compute_list_dispatch_indirect()`. Consumer shaders remap
their 1D workgroup index through the compact tile list.

## When To Use

- A large 2D grid or 3D voxel volume has many empty/inactive regions.
- Later compute passes do expensive work per pixel, cell, or voxel.
- Activity can be represented as `float[]` plus an optional mask buffer.
- You need thread remapping, sparse pixels, sparse tiles, or sparse voxels.

## Template Files

```powershell
$skill = "D:\.aidata\skills\sparse-tile-dispatch\template"
$proj  = "<PROJECT_ROOT>"

Copy-Item "$skill\sparse_tile_dispatch.gd" "$proj\scripts\"
Copy-Item "$skill\sparse_tile_dispatch_3d.gd" "$proj\scripts\"
Copy-Item "$skill\std_compact_generic.glsl" "$proj\shaders\"
Copy-Item "$skill\std_compact_generic_3d.glsl" "$proj\shaders\"
Copy-Item "$skill\std_finalize_compact.glsl" "$proj\shaders\"
```

Run `godot --path <project> --import` after copying shader files.

## 2D Flow

```gdscript
var sparse := SparseTileDispatch.new(rd, grid_w, grid_h, 8, 1, 0.001)
sparse.set_activity_buffers(activity_buf, mask_buf) # mask is optional

sparse.reset_counter() # before compute_list_begin
var cl := rd.compute_list_begin()

# Earlier passes write activity_buf.
sparse.dispatch_compact(cl)

rd.compute_list_bind_compute_pipeline(cl, consumer_pipeline)
rd.compute_list_bind_uniform_set(cl, consumer_uset, 0)
rd.compute_list_set_push_constant(cl, consumer_push, consumer_push.size())
sparse.dispatch_indirect(cl)

rd.compute_list_end()
rd.submit()
rd.sync()
```

What happens:

1. `std_compact_generic.glsl` scans one logical tile per workgroup.
2. If any unmasked activity is found, it appends `x | (y << 16)` to `compact_tile_coords`.
3. `std_finalize_compact.glsl` writes `(tile_count, 1, 1)` into `indirect_args`.
4. The consumer pass dispatches only `tile_count` workgroups.

## Flexible Options

`SparseTileDispatch` supports runtime options:

```gdscript
sparse.set_scan_options(
    2,                                  # expand_pixels
    0.05,                               # threshold
    0.5,                                # mask_threshold
    SparseTileDispatch.ACTIVITY_ABS_GT) # activity mode
```

Activity modes:

- `ACTIVITY_ABS_GT`: `abs(value) > threshold`
- `ACTIVITY_GT`: `value > threshold`
- `ACTIVITY_LT`: `value < threshold`
- `ACTIVITY_NONZERO`: `value != 0.0`

`tile_size` is flexible for compaction. In consumer shaders, either make
`local_size_x/y` match the tile size or use a linear loop over the tile area.
The 2D compact list packs tile x/y into 16 bits each, so each tile axis must stay
under `65536`.

## 2D Consumer Remapping

```glsl
layout(set = 0, binding = N, std430) restrict readonly buffer CompactTiles {
    uint compact_tile_coords[];
};

layout(push_constant, std430) uniform Params {
    int width;
    int height;
    int tile_size;
    int sparse_mode;
};

void main() {
    int tile_x;
    int tile_y;
    if (sparse_mode != 0) {
        uint packed = compact_tile_coords[gl_WorkGroupID.x];
        tile_x = int(packed & 0xFFFFu);
        tile_y = int(packed >> 16u);
    } else {
        tile_x = int(gl_WorkGroupID.x);
        tile_y = int(gl_WorkGroupID.y);
    }

    uint worker_count = gl_WorkGroupSize.x * gl_WorkGroupSize.y * gl_WorkGroupSize.z;
    uint tile_cells = uint(tile_size * tile_size);
    for (uint i = gl_LocalInvocationIndex; i < tile_cells; i += worker_count) {
        ivec2 local_p = ivec2(int(i % uint(tile_size)), int(i / uint(tile_size)));
        ivec2 p = ivec2(tile_x, tile_y) * tile_size + local_p;
        if (p.x >= width || p.y >= height) {
            continue;
        }

        // Process p.
    }
}
```

## 3D Flow

Use `SparseTileDispatch3D` for voxel grids. Buffers are flattened as:

```text
index = z * grid_w * grid_h + y * grid_w + x
```

```gdscript
var sparse3d := SparseTileDispatch3D.new(rd, grid_w, grid_h, grid_d, 4, 1, 0.001)
sparse3d.set_activity_buffers(voxel_activity_buf, voxel_mask_buf)

sparse3d.reset_counter()
var cl := rd.compute_list_begin()
sparse3d.dispatch_compact(cl)

rd.compute_list_bind_compute_pipeline(cl, voxel_pipeline)
rd.compute_list_bind_uniform_set(cl, voxel_uset, 0)
rd.compute_list_set_push_constant(cl, voxel_push, voxel_push.size())
sparse3d.dispatch_indirect(cl)
```

The 3D compact buffer stores one `uvec4` per active tile: `(tile_x, tile_y,
tile_z, 0)`. This avoids 16-bit packing limits. In consumer shaders, either make
`local_size_x/y/z` match the tile size or use a linear loop over the voxel tile.

## 3D Consumer Remapping

```glsl
layout(set = 0, binding = N, std430) restrict readonly buffer CompactTiles3D {
    uvec4 compact_tile_coords[];
};

layout(push_constant, std430) uniform Params {
    int grid_w;
    int grid_h;
    int grid_d;
    int tile_size;
    int sparse_mode;
};

void main() {
    ivec3 tile_coord;
    if (sparse_mode != 0) {
        tile_coord = ivec3(compact_tile_coords[gl_WorkGroupID.x].xyz);
    } else {
        tile_coord = ivec3(gl_WorkGroupID.xyz);
    }

    uint worker_count = gl_WorkGroupSize.x * gl_WorkGroupSize.y * gl_WorkGroupSize.z;
    uint tile_cells = uint(tile_size * tile_size * tile_size);
    for (uint i = gl_LocalInvocationIndex; i < tile_cells; i += worker_count) {
        int lx = int(i % uint(tile_size));
        int ly = int((i / uint(tile_size)) % uint(tile_size));
        int lz = int(i / uint(tile_size * tile_size));
        ivec3 p = tile_coord * tile_size + ivec3(lx, ly, lz);
        if (p.x >= grid_w || p.y >= grid_h || p.z >= grid_d) {
            continue;
        }

        int idx = p.z * grid_w * grid_h + p.y * grid_w + p.x;
        // Process voxel idx.
    }
}
```

## Debug

```gdscript
var tile_count := sparse.readback_tile_count()
var total_tiles := sparse.groups_x * sparse.groups_y
print("Active: %d / %d (%.1f%%)" % [
    tile_count,
    total_tiles,
    100.0 * float(tile_count) / float(total_tiles)
])

var tile_data := sparse.readback_tile_coords(tile_count)
```

For 3D, `readback_tile_coords()` returns `Array[Vector3i]`.

## Godot Gotchas

- Call `reset_counter()` before `compute_list_begin()`.
- The finalizer writes `indirect_args[0] = tile_count`; zero active tiles means zero consumer workgroups.
- Every pipeline in the same compute list should declare and set compatible push constants, including tiny dummy constants, because Godot can carry push constant state across pipeline bindings.
- Add a barrier after compaction and after finalization before consumers read the buffers.
- Use a small debug readback before trusting performance results.