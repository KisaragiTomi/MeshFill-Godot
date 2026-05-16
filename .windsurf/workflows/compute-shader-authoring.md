---
description: Author and debug Godot 4.x RenderingDevice compute shader pipelines for GLSL, GPU buffers, image passes, sparse pixel or tile work, thread remapping, voxel occupancy, and multi-pass placement/generation systems. Use when writing, refactoring, optimizing, or debugging compute shaders, dispatch dimensions, barriers, push constants, sparse dispatch, voxel updates, or MeshFill-style GPU pipelines. Trigger terms: compute shader, GLSL, RenderingDevice, dispatch, barrier, push constant, sparse pixel, sparse tile, thread remapping, voxel, 线程重映射, 稀疏像素, 稀疏调度, 体素.
---

# Compute Shader Authoring

Use this skill for Godot 4.x compute shader work, especially MeshFill-style GPU
pipelines that move data through multiple passes before reading compact results
back to GDScript.

## Workflow

1. Inspect the current GDScript owner and shader pass chain before editing.
2. Name every pass by its input, output, and synchronization contract.
3. Keep buffer/image formats explicit: element type, dimensions, stride, and valid ranges.
4. Match GLSL `set`/`binding` declarations to the `RDUniform` order in GDScript.
5. Compute dispatch group counts from data dimensions and local size, then guard out-of-bounds invocations.
6. Add barriers between passes that read data written by earlier passes in the same command flow.
7. Prefer small storage buffers for frequently changed parameters when push constant size/state is uncertain.
8. Verify with CPU readback, debug overlays, or RenderDoc before tuning performance.

## Godot Shader Skeleton

```glsl
#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer B0 {
    float input_data[];
};

layout(set = 0, binding = 1, std430) restrict buffer B1 {
    float output_data[];
};

layout(push_constant, std430) uniform Params {
    int width;
    int height;
    float threshold;
    int mode;
};

void main() {
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    if (p.x >= width || p.y >= height) {
        return;
    }

    int i = p.y * width + p.x;
    output_data[i] = input_data[i] > threshold ? input_data[i] : 0.0;
}
```

## MeshFill Pattern

For terrain/object placement pipelines, treat the GPU work as a staged solver:

- `init`: normalize source depth, normal, mask, and occupancy inputs.
- `target_height`: propagate or estimate target surfaces.
- `blur/filter`: stabilize noisy fields before scoring.
- `extent_mask`: grow candidate regions or exclusion masks.
- `fill/score`: evaluate each pixel or voxel candidate.
- `find`: reduce to best pixel, tile, object, or placement.
- `update`: write current height, occupancy, mask, and compact result records.

MeshFill-Godot memory source: the project uses `scripts/cliff_generator.gd` to
manage `init -> target_height -> blur -> extent_mask -> fill -> find -> update`
over depth, normal, target-height, rock-mask, and result textures.

## Sparse Pixel And Thread Remapping

Use sparse dispatch when a large 2D grid has many inactive pixels/tiles.

1. Scan the activity field into compact tile coordinates.
2. Finalize an indirect dispatch args buffer from active tile count.
3. Dispatch the consumer shader with `compute_list_dispatch_indirect`.
4. In the consumer shader, map `gl_WorkGroupID.x` through `compact_tile_coords`.

Consumer shader pattern:

```glsl
layout(set = 0, binding = 5, std430) restrict readonly buffer CompactTiles {
    uint compact_tile_coords[];
};

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

ivec2 p = ivec2(tile_x * 8 + int(gl_LocalInvocationID.x),
                tile_y * 8 + int(gl_LocalInvocationID.y));
```

For a ready Godot implementation, also use the `sparse-tile-dispatch` skill.

## Voxel Occupancy Rules

For voxel generation or scatter exclusion:

- Keep visual/ecological height-band occupancy separate from rigid collision occupancy.
- Store persistent voxel defaults on the object when possible: `voxel_color`, `voxel_complexity`, and `collision_voxels`.
- Treat shared voxel profiles as presets/fallbacks, not the only source of truth.
- Write only coarse solid parts to collision voxels, such as trunks or large rock masses.
- Avoid writing grass, leaves, and thin branches into rigid collision voxels.
- Use erosion followed by dilation when a collision footprint needs thin-part removal plus conservative blocking.
- Make occupancy writes idempotent with max-style writes or monotonic masks.

MeshFill-Godot memory source: collision voxels are a separate layer from RGBA
height-band occupancy; crowns can overlap across bands, but trunks cannot occupy
the same collision voxel.

## Godot Gotchas

- Godot `RenderingDevice` push constant state can carry across pipeline bindings inside a compute list. If one pipeline has push constants and the next declares none, bind compatible push constants or use a small parameter buffer.
- Keep shared memory conservative. Vulkan guarantees at least 16 KB per workgroup; calculate every `shared` array's byte cost.
- `vec3` alignment is often effectively 16 bytes in buffer layouts; prefer `vec4` or explicit padding for structured data.
- Always guard edges when dimensions are not exact multiples of `local_size`.
- Read back tiny buffers or debug textures after each new pass before composing the full pipeline.