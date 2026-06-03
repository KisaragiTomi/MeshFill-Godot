---
name: compute-shader-authoring
description: >-
  Author and debug Godot 4.x RenderingDevice compute shader pipelines for GLSL,
  GPU buffers, image passes, sparse pixel or tile work, thread remapping, voxel
  occupancy, reusable compute-shader base classes, extensible GPU resource
  garbage collection, and multi-pass placement/generation systems. Use when
  writing, refactoring, optimizing, or debugging compute shaders, dispatch
  dimensions, barriers, push constants, sparse dispatch, voxel updates,
  RenderingDevice RID lifetimes, or MeshFill-style GPU pipelines. Trigger terms:
  compute shader, GLSL, RenderingDevice, dispatch, barrier, push constant,
  sparse pixel, sparse tile, thread remapping, voxel, GC, resource lifetime,
  线程重映射, 稀疏像素, 稀疏调度, 稀疏瓦片, 体素,
  线程重映射, 稀疏像素, 稀疏调度, 体素.
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
8. Use the reusable base template when a pipeline owns multiple shaders, pipelines, buffers, textures, samplers, or transient uniform sets.
9. Verify with CPU readback, debug overlays, or RenderDoc before tuning performance.

## Reusable Godot Base

For new or refactored Godot compute owners, copy
`assets/godot_compute_shader_base.gd` into the project, usually as
`res://scripts/godot_compute_shader_base.gd`, then derive pipeline classes from
`GodotComputeShaderBase`.

The base centralizes:

- RenderingDevice resolution with local-device preference and global fallback.
- External RenderingDevice attachment for project-owned devices.
- Shader source loading for `.glsl` files with Godot's `#[compute]` marker stripped.
- Pipeline, uniform set, storage buffer, 2D/3D texture, sampler, and dispatch helpers.
- RID tracking by scope: `persistent`, `frame`, `pass`, and `scratch`.
- Owned versus borrowed RID tracking so shared buffers/textures can be referenced
  without being freed by the borrowing pipeline.
- Extensible garbage collection with custom kind disposers, free ordering, deferred
  cleanup while a compute list is active, and lifecycle hooks.

Minimal derived class shape:

```gdscript
class_name MyGpuPipeline
extends "res://scripts/godot_compute_shader_base.gd"

var _shader: RID
var _pipeline: RID

func run(input: PackedFloat32Array) -> PackedByteArray:
	log_name = "MyGpuPipeline"
	if not ensure_device():
		return PackedByteArray()

	_shader = load_compute_shader("res://shaders/my_pass.glsl")
	_pipeline = create_compute_pipeline(_shader)
	if not _pipeline.is_valid():
		dispose()
		return PackedByteArray()

	var data_buffer := storage_buffer_from_floats(input, SCOPE_FRAME, "input")
	var set0 := create_uniform_set([make_storage_uniform(0, data_buffer)], _shader, 0)

	var cl := begin_compute_list()
	get_rendering_device().compute_list_bind_compute_pipeline(cl, _pipeline)
	get_rendering_device().compute_list_bind_uniform_set(cl, set0, 0)
	get_rendering_device().compute_list_dispatch(cl, ceil_div(input.size(), 64), 1, 1)
	end_compute_list()

	submit_and_sync()
	var out := get_rendering_device().buffer_get_data(data_buffer)
	gc_frame()
	dispose()
	return out
```

Use `track_rid(rid, kind, scope, label)` immediately for every RID created outside
the helper methods. Use `attach_rendering_device(rd, false)` when a parent scene,
manager, or subsystem owns the `RenderingDevice`; `dispose()` will then free only
tracked owned RIDs and leave the device alive. Use `track_borrowed_rid(rid, kind,
scope, label)` for externally owned buffers or textures that a uniform set
references but this pipeline must not free. Override `_should_free_resource(entry)`
only for project-specific policies beyond the built-in owned/borrowed flag, and
use `register_kind_disposer(kind, callable, order)` for non-standard cleanup
policies such as pooled resources, delayed destruction, or debug logging.

Shared-device derived class shape:

```gdscript
class_name MySharedGpuPass
extends "res://scripts/godot_compute_shader_base.gd"

var rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _borrowed_input: RID

func _init(external_rd: RenderingDevice, input_buffer: RID) -> void:
	log_name = "MySharedGpuPass"
	if not attach_rendering_device(external_rd, false):
		return
	rd = get_rendering_device()
	_borrowed_input = track_borrowed_rid(input_buffer, KIND_BUFFER, SCOPE_PERSISTENT, "input")
	_shader = load_compute_shader("res://shaders/my_pass.glsl")
	_pipeline = create_compute_pipeline(_shader)

func cleanup() -> void:
	dispose()
	rd = null
```

### 3D Base Helper Pattern

Use the same `GodotComputeShaderBase` for 2D image passes and 3D voxel passes. The RenderingDevice, shader, pipeline, storage buffer, uniform set, and RID lifecycle helpers are dimension-neutral. Use `upload_texture_3d()` or `create_rw_texture_3d()` only when the GLSL pass declares `texture3D` or `image3D`; prefer storage buffers for sparse voxel placement, structured records, or random-write tile data.

Flatten dense voxel buffers as:

```text
index = z * grid_w * grid_h + y * grid_w + x
```

```gdscript
var voxel_buf := storage_buffer_zero_3d(grid_w, grid_h, grid_d, 4, SCOPE_FRAME, "voxel_field")
var groups := dispatch_groups_3d(grid_w, grid_h, grid_d, 8, 8, 1)

var cl := begin_compute_list()
get_rendering_device().compute_list_bind_compute_pipeline(cl, voxel_pipeline)
get_rendering_device().compute_list_bind_uniform_set(cl, voxel_set, 0)
get_rendering_device().compute_list_dispatch(cl, groups.x, groups.y, groups.z)
end_compute_list()
```

For dense 3D image workflows, pack z slices in order into one `PackedByteArray` and upload with `upload_texture_3d(width, height, depth, bytes)`, or pass equally sized `Image` slices to `upload_texture_3d_from_images()`.

## Scripted Install

For a Godot project, install the reusable compute assets with:

```powershell
python D:\.aidata\skills\compute-shader-authoring\scripts\install_godot_compute_assets.py <PROJECT_ROOT>
```

This copies:

- `godot_compute_shader_base.gd` to `<PROJECT_ROOT>/scripts/`
- `sparse_tile_dispatch.gd` and `sparse_tile_dispatch_3d.gd` to `<PROJECT_ROOT>/scripts/`
- `std_compact_generic.glsl`, `std_compact_generic_3d.glsl`, and `std_finalize_compact.glsl` to `<PROJECT_ROOT>/shaders/`

Use `--dry-run` to preview, `--force` to overwrite existing files, `--base-only`
to install only the GC base, and `--sparse-only` to install only the thread
remapping assets. Use `--godot <exe> --import --check` when Godot should import
the shader files and parse-check the installed GDScript files.

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

MeshFill-Godot memory source: the project uses `scripts/placement_fitting_generator.gd`
plus the current voxel placement path to manage heightfield fitting, candidate-region scoring,
stamping, and BlendSV-backed `instance_stamp_write_spec` / `ISWS` output over SV / TargetSV_B resident fields; `voxel_write_spec` is a legacy compatibility alias.

## Sparse Pixel And Thread Remapping

Use sparse dispatch when a large 2D grid or 3D voxel volume has many
empty/inactive regions and later passes do expensive work per pixel, cell, or
voxel. Activity is usually represented as `float[]` plus an optional mask buffer.

1. Scan the activity field into compact tile coordinates.
2. Finalize an indirect dispatch args buffer from active tile count.
3. Dispatch the consumer shader with `compute_list_dispatch_indirect`.
4. In the consumer shader, map `gl_WorkGroupID.x` through `compact_tile_coords`.

Install the bundled implementation with:

```powershell
python D:\.aidata\skills\compute-shader-authoring\scripts\install_godot_compute_assets.py <PROJECT_ROOT> --sparse-only
```

The installed sparse scripts derive from `godot_compute_shader_base.gd`, so their
shader, pipeline, buffer, uniform set, and indirect-args RIDs share the same GC
mechanism as regular compute owners.

### 2D Flow

```gdscript
var sparse := SparseTileDispatch.new(rd, grid_w, grid_h, 8, 1, 0.001)
sparse.setup(false, false) # rd is externally owned
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

Runtime options:

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

### 2D Consumer Remapping

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

### 3D Flow

Use `SparseTileDispatch3D` for voxel grids. Buffers are flattened as:

```text
index = z * grid_w * grid_h + y * grid_w + x
```

```gdscript
var sparse3d := SparseTileDispatch3D.new(rd, grid_w, grid_h, grid_d, 4, 1, 0.001)
sparse3d.setup(false, false) # rd is externally owned
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

### 3D Consumer Remapping

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

### Sparse Debug

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

## Voxel Occupancy Rules

For voxel generation or scatter exclusion:

- Keep visual/ecological height-band occupancy separate from rigid collision occupancy.
- Store persistent voxel defaults on the object when possible: `voxel_color`, `voxel_complexity`, and `collision` / `collision_strength`.
- Treat shared voxel profiles as presets/fallbacks, not the only source of truth.
- Write only coarse solid parts to `collision`, such as trunks or large rock masses.
- Avoid writing grass, leaves, and thin branches into rigid collision.
- Use erosion followed by dilation when a collision footprint needs thin-part removal plus conservative blocking.
- Make occupancy writes idempotent with max-style writes or monotonic masks.

MeshFill-Godot memory source: `collision` is the rigid collision semantic and
`collision_strength` is the per-sample/per-voxel intensity; crowns can overlap
across visual bands, but trunks cannot occupy the same rigid collision space.

## Godot Gotchas

- Godot `RenderingDevice` push constant state can carry across pipeline bindings inside a compute list. If one pipeline has push constants and the next declares none, bind compatible push constants or use a small parameter buffer.
- Keep shared memory conservative. Vulkan guarantees at least 16 KB per workgroup; calculate every `shared` array's byte cost.
- `vec3` alignment is often effectively 16 bytes in buffer layouts; prefer `vec4` or explicit padding for structured data.
- Always guard edges when dimensions are not exact multiples of `local_size`.
- Read back tiny buffers or debug textures after each new pass before composing the full pipeline.
