#!/usr/bin/env python
r"""Convert an OpenVDB (.vdb) volume into the voxel-cache JSON the MeshFill
AssetDescriptor demo reads.

This is the Python backend for the Godot editor tool "Import VDB" (see
scripts/vdb_voxel_import_service.gd). Godot cannot read .vdb natively, so it
shells out here — mirroring the "Bake -> FBX" tool (tools/bake_fbx_transform.py).
This reads the collision / complexity / color grids and emits one JSON entry per
active voxel with its 5-dim values, which then REPLACE the mesh voxelization as
the asset's per-voxel source.

TWO BACKENDS (auto-selected by which interpreter runs this script):
  1. pyopenvdb  — used if importable (conda `openvdb`, or older Houdini hython).
  2. Houdini hou — FALLBACK when pyopenvdb is absent (Houdini 20+ dropped the
     standalone pyopenvdb bindings). Run this script with Houdini's `hython`;
     it reads the .vdb via `hou.Geometry().loadFromFile`. Point the ProjectSetting
     `meshfill_editor/vdb_python` at hython.exe.
Whichever imports first wins; if neither imports, the script fails with guidance.

OUTPUT JSON (consumed by VdbVoxelImportService.load_voxel_result):
  {
    "cell_size": <float>,                 # uniform world voxel edge (after --scale)
    "aabb_min":  [x, y, z],               # world lower corner of the voxel grid
    "aabb_size": [x, y, z],               # world size of the voxel grid
    "grid":      [nx, ny, nz],            # voxel counts per axis (active bbox)
    "voxels": [
      { "voxel": [i, j, k],               # 0-based grid coord (bbox-relative)
        "local_center": [x, y, z],        # world center of the voxel (after --scale)
        "color": [r, g, b],               # 0..1
        "complexity": <float>,            # 0..1
        "collision": <float> },           # 0..1
      ...
    ]
  }

COORDINATE ASSUMPTION: the .vdb is authored in the asset's local space (voxel
world positions equal mesh-local positions), with a uniform, axis-aligned voxel
size. "world" above is therefore mesh-local in Godot.

--scale: uniform multiplier applied to cell_size / aabb / local_center (NOT to
voxel indices or the 5-dim values). Use it to reconcile a units mismatch — e.g.
a .vdb authored in Houdini centimetres feeding a Godot mesh imported in metres
needs --scale 0.01. Set project-wide via ProjectSetting
`meshfill_editor/vdb_import_scale`.

GRID NAMES: passed in by Godot (defaults collision / complexity / Cd). A missing
grid falls back to a constant (collision=1, complexity=1, color=white). OCCUPANCY
(which voxels form the asset body) is taken from the complexity grid — the first
available of complexity -> collision -> color — NOT from collision. A soft asset
(grass) legitimately has collision == 0 on every voxel, so gating occupancy on
"collision != 0" would drop the whole asset; collision is read as a per-voxel
value instead. (complexity's non-zero set equals the grid's activeVoxelCount for
the pipeline's assets, so it faithfully recovers the body.)

INSTALLING pyopenvdb (only needed for backend #1)
-------------------------------------------------
  - A conda env: `conda install -c conda-forge openvdb` (provides pyopenvdb)
  - Older Houdini hython (pre-20) bundled pyopenvdb.
Modern Houdini (20+) no longer ships pyopenvdb — use backend #2 (plain hython).
"""

import argparse
import json
import sys


def _fail(msg, code=2):
    sys.stderr.write("[convert_vdb_to_voxels] %s\n" % msg)
    sys.exit(code)


def _redirect_native_output(log_path):
    """Point OS-level stdout/stderr (fds 1 & 2) at a log file before importing a
    backend. Houdini's hython spawns a persistent license daemon (hserver) that
    INHERITS these descriptors; when they are Godot's captured OS.execute pipe,
    the editor's blocking read of that pipe never sees EOF (the daemon keeps the
    write end open) and the whole editor HANGS. Writing to a file instead lets
    the pipe close when this process exits. Cross-platform; harmless for the
    plain-CPython (pyopenvdb) path. The service reads this .log for diagnostics."""
    import os
    try:
        sys.stdout.flush()
        sys.stderr.flush()
    except Exception:
        pass
    try:
        fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    except Exception:
        return
    try:
        os.dup2(fd, 1)
        os.dup2(fd, 2)
    finally:
        os.close(fd)
    try:
        sys.stdout = os.fdopen(1, "w", encoding="utf-8", closefd=False)
        sys.stderr = os.fdopen(2, "w", encoding="utf-8", closefd=False)
    except Exception:
        pass


def _as_rgb(value):
    """Coerce a grid value into an [r, g, b] list (scalar -> replicated)."""
    if isinstance(value, (tuple, list)):
        seq = list(value)
        while len(seq) < 3:
            seq.append(seq[-1] if seq else 0.0)
        return [float(seq[0]), float(seq[1]), float(seq[2])]
    v = float(value)
    return [v, v, v]


# ── Backend 1: pyopenvdb ────────────────────────────────────────────────────
def _iter_active_coords_vdb(grid):
    """Yield every active voxel coord (i, j, k), expanding active tiles."""
    for item in grid.citerOnValues():
        imin = item.min
        imax = item.max
        if imin == imax:
            yield imin
            continue
        for i in range(imin[0], imax[0] + 1):
            for j in range(imin[1], imax[1] + 1):
                for k in range(imin[2], imax[2] + 1):
                    yield (i, j, k)


def _read_with_pyopenvdb(vdb, args):
    try:
        grids = vdb.readAll(args.input)[0]
    except Exception as exc:
        _fail("failed to read %r: %r" % (args.input, exc))

    by_name = {}
    for g in grids:
        by_name[g.name] = g
    if not by_name:
        _fail("no grids found in %r" % args.input)

    collision_grid = by_name.get(args.grid_collision)
    complexity_grid = by_name.get(args.grid_complexity)
    color_grid = by_name.get(args.grid_color)
    # OCCUPANCY = the asset body, independent of collision STRENGTH (grass has
    # collision == 0 everywhere). Iterate the complexity grid's active topology;
    # collision is a physics subset that can be legitimately empty. Prefer
    # complexity -> collision -> color.
    primary = complexity_grid or collision_grid or color_grid or grids[0]
    sys.stderr.write(
        "[convert_vdb_to_voxels] backend=pyopenvdb grids=%s | primary=%s | "
        "collision=%s complexity=%s color=%s\n"
        % (sorted(by_name.keys()), primary.name,
           getattr(collision_grid, "name", None),
           getattr(complexity_grid, "name", None),
           getattr(color_grid, "name", None)))

    transform = primary.transform
    vsize = transform.voxelSize()
    cell_size = float(vsize[0])
    if cell_size <= 0.0:
        _fail("primary grid %r has non-positive voxel size %r" % (primary.name, vsize))

    acc_collision = collision_grid.getConstAccessor() if collision_grid is not None else None
    acc_complexity = complexity_grid.getConstAccessor() if complexity_grid is not None else None
    acc_color = color_grid.getConstAccessor() if color_grid is not None else None

    coords = []
    min_i = min_j = min_k = None
    max_i = max_j = max_k = None
    for (i, j, k) in _iter_active_coords_vdb(primary):
        coords.append((i, j, k))
        if min_i is None:
            min_i, min_j, min_k = i, j, k
            max_i, max_j, max_k = i, j, k
        else:
            min_i, min_j, min_k = min(min_i, i), min(min_j, j), min(min_k, k)
            max_i, max_j, max_k = max(max_i, i), max(max_j, j), max(max_k, k)
        if len(coords) > args.max_voxels:
            _fail("active voxel count exceeds --max-voxels (%d). Downsample the "
                  "VDB or raise the limit." % args.max_voxels)
    if not coords:
        _fail("primary grid %r has no active voxels" % primary.name)

    grid_dims = [max_i - min_i + 1, max_j - min_j + 1, max_k - min_k + 1]
    min_center = transform.indexToWorld((min_i, min_j, min_k))
    aabb_min = [float(min_center[t]) - 0.5 * float(vsize[t]) for t in range(3)]
    aabb_size = [grid_dims[t] * float(vsize[t]) for t in range(3)]

    voxels = []
    for (i, j, k) in coords:
        collision = float(acc_collision.getValue((i, j, k))) if acc_collision is not None else 1.0
        complexity = float(acc_complexity.getValue((i, j, k))) if acc_complexity is not None else 1.0
        color = _as_rgb(acc_color.getValue((i, j, k))) if acc_color is not None else [1.0, 1.0, 1.0]
        center = transform.indexToWorld((i, j, k))
        voxels.append({
            "voxel": [i - min_i, j - min_j, k - min_k],
            "local_center": [float(center[0]), float(center[1]), float(center[2])],
            "color": color, "complexity": complexity, "collision": collision,
        })
    return {"cell_size": cell_size, "aabb_min": aabb_min,
            "aabb_size": aabb_size, "grid": grid_dims, "voxels": voxels}


# ── Backend 2: Houdini hou ──────────────────────────────────────────────────
def _read_with_hou(hou, args):
    geo = hou.Geometry()
    try:
        geo.loadFromFile(args.input)
    except Exception as exc:
        _fail("hou failed to load %r: %r" % (args.input, exc))
    by_name = {}
    for p in geo.prims():
        if p.type() == hou.primType.VDB:
            by_name[p.stringAttribValue("name")] = p
    if not by_name:
        _fail("no VDB grids found in %r" % args.input)

    coll = by_name.get(args.grid_collision)
    cplx = by_name.get(args.grid_complexity)
    col = by_name.get(args.grid_color)

    # OCCUPANCY (which voxels make up the asset body) must be independent of collision
    # STRENGTH. A soft asset — grass — has collision == 0 on every voxel, so gating
    # occupancy on "collision != 0" wrongly drops the whole asset ("no active voxels").
    # The complexity grid carries visual substance and is non-zero across the entire body
    # (its non-zero set equals activeVoxelCount for grass / leaf / rock), so it — not
    # collision — is the occupancy reference; occupancy is then the union of non-zero
    # complexity OR non-zero collision. Colour is excluded from occupancy (its background
    # can bleed non-zero). collision / complexity / colour are read as per-voxel VALUES.
    ref = cplx or coll or col
    if ref is None:
        _fail("none of the requested grids exist (complexity=%r collision=%r color=%r); "
              "grids present: %s" % (args.grid_complexity, args.grid_collision,
                                     args.grid_color, sorted(by_name)))
    sys.stderr.write(
        "[convert_vdb_to_voxels] backend=hou grids=%s | occupancy_ref=%s | "
        "collision=%s complexity=%s color=%s\n"
        % (sorted(by_name.keys()), ref.stringAttribValue("name"),
           coll is not None, cplx is not None, col is not None))

    cell_size = float(ref.voxelSize()[0])
    if cell_size <= 0.0:
        _fail("occupancy grid has non-positive voxel size %r" % ref.voxelSize())

    # resolution() is authoritative for the grid dims. activeVoxelBoundingBox().maxvec()
    # is off-by-one relative to it (it reports lo+res, not lo+res-1), so derive dims from
    # resolution(), NOT from max-min — otherwise we walk a phantom trailing slab of
    # background voxels and over-report grid size by 1 per axis.
    bb = ref.activeVoxelBoundingBox()
    lo = tuple(int(round(bb.minvec()[t])) for t in range(3))
    rx, ry, rz = ref.resolution()
    dims = [rx, ry, rz]
    n = rx * ry * rz

    # ONE batch fetch per grid over the active bbox — flat, x-fastest ordering
    # (index = a + b*rx + c*rx*ry). This replaces a per-voxel Python .voxel()/.samplev()
    # loop that fired hundreds of thousands of hou calls for a large asset (the "import is
    # slow" cause). A missing grid stays None and falls back to a constant below.
    flat_cplx = cplx.voxelRangeAsFloat(bb) if cplx is not None else None
    flat_coll = coll.voxelRangeAsFloat(bb) if coll is not None else None
    flat_col = col.voxelRangeAsVector3(bb) if col is not None else None

    # Voxel centres are analytic: origin (world centre of the lo voxel) + index * cell_size.
    # Exact for the uniform, axis-aligned grids this pipeline authors (verified centre error
    # == 0 vs indexToPos), and avoids a per-voxel indexToPos() call.
    pos_lo = ref.indexToPos(lo)
    origin = [float(pos_lo[t]) for t in range(3)]

    color_only = (flat_cplx is None and flat_coll is None)
    voxels = []
    idx = 0  # sequential because the loop nests c(outer)/b/a(inner) == a + b*rx + c*rx*ry
    for c in range(rz):
        for b in range(ry):
            for a in range(rx):
                cx = flat_cplx[idx] if flat_cplx is not None else 0.0
                cc = flat_coll[idx] if flat_coll is not None else 0.0
                occupied = (abs(cx) > 1e-6) or (abs(cc) > 1e-6)
                if color_only:
                    v = flat_col[idx]
                    occupied = (abs(v[0]) + abs(v[1]) + abs(v[2])) > 1e-6
                if occupied:
                    complexity = float(cx) if flat_cplx is not None else 1.0
                    # collision defaults to solid (1.0) ONLY when no collision grid exists;
                    # a present grid's real value wins even when it is 0 (grass).
                    collision = float(cc) if flat_coll is not None else 1.0
                    if flat_col is not None:
                        cv = flat_col[idx]
                        color = [float(cv[0]), float(cv[1]), float(cv[2])]
                    else:
                        color = [1.0, 1.0, 1.0]
                    voxels.append({
                        "voxel": [a, b, c],
                        "local_center": [origin[0] + a * cell_size,
                                         origin[1] + b * cell_size,
                                         origin[2] + c * cell_size],
                        "color": color, "complexity": complexity, "collision": collision,
                    })
                    if len(voxels) > args.max_voxels:
                        _fail("active voxel count exceeds --max-voxels (%d)." % args.max_voxels)
                idx += 1
    if not voxels:
        _fail("occupancy grid %r has no active voxels" % ref.stringAttribValue("name"))

    active = ref.activeVoxelCount()
    if len(voxels) != active:
        sys.stderr.write("[convert_vdb_to_voxels] note: recorded %d voxels vs "
                         "activeVoxelCount %d\n" % (len(voxels), active))

    aabb_min = [origin[t] - 0.5 * cell_size for t in range(3)]
    aabb_size = [dims[t] * cell_size for t in range(3)]
    return {"cell_size": cell_size, "aabb_min": aabb_min,
            "aabb_size": aabb_size, "grid": dims, "voxels": voxels}


def _apply_scale(payload, scale):
    if scale == 1.0:
        return payload
    payload["cell_size"] *= scale
    payload["aabb_min"] = [x * scale for x in payload["aabb_min"]]
    payload["aabb_size"] = [x * scale for x in payload["aabb_size"]]
    for v in payload["voxels"]:
        v["local_center"] = [x * scale for x in v["local_center"]]
    return payload


def main():
    parser = argparse.ArgumentParser(description="Convert a .vdb into voxel-cache JSON.")
    parser.add_argument("--input", required=True, help="Source .vdb path")
    parser.add_argument("--output", required=True, help="Destination .json path")
    parser.add_argument("--grid-collision", default="collision")
    parser.add_argument("--grid-complexity", default="complexity")
    parser.add_argument("--grid-color", default="Cd")
    parser.add_argument("--scale", type=float, default=1.0,
                        help="Uniform multiplier for cell_size/aabb/local_center (units reconcile)")
    parser.add_argument("--max-voxels", type=int, default=4_000_000)
    args = parser.parse_args()

    # MUST precede any backend import (esp. hou → hserver daemon). See docstring.
    _redirect_native_output(args.output + ".log")

    payload = None
    try:
        import pyopenvdb as vdb  # noqa: F401
        payload = _read_with_pyopenvdb(vdb, args)
    except ImportError:
        try:
            import hou  # noqa: F401
        except ImportError:
            _fail(
                "neither pyopenvdb nor hou is importable with this interpreter.\n"
                "Point the ProjectSetting 'meshfill_editor/vdb_python' at either a "
                "conda env with openvdb (pyopenvdb), or Houdini's hython.exe (hou). "
                "See the header of this script for details.")
        payload = _read_with_hou(hou, args)

    payload = _apply_scale(payload, args.scale)

    try:
        with open(args.output, "w", encoding="utf-8") as fh:
            json.dump(payload, fh)
    except Exception as exc:
        _fail("failed to write %r: %r" % (args.output, exc))

    sys.stderr.write(
        "[convert_vdb_to_voxels] wrote %d voxels (grid=%s cell=%.4f scale=%.4g) -> %s\n"
        % (len(payload["voxels"]), payload["grid"], payload["cell_size"], args.scale, args.output))


if __name__ == "__main__":
    main()
