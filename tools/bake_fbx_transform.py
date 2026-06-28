#!/usr/bin/env python
r"""Bake a linear transform (scale + rotation) into the geometry of an FBX file.

This is the Python backend for the Godot editor tool "Bake -> FBX". Godot
computes the transform to apply -- already converted into the FBX file's own
coordinate space -- and passes it here as three basis columns. This script
applies it to every mesh's control points (and fixes normals/tangents), then
re-exports the FBX in place. The source is backed up first.

WHY GODOT DOES THE COORDINATE MATH
----------------------------------
Each FBX imports into Godot through a per-file axis/unit conversion `C`
(e.g. Z-up Max/Houdini files come in rotated -90 deg about X; Y-up files come in
identity). The transform the user dialed in lives in Godot space as `T_node`.
To bake it into the FBX's native control-point space we need:

        M = C^-1 * T_node * C

Godot already knows `C` (the imported mesh's transform), so it computes `M` and
hands us only the final 3x3 basis. This script therefore needs *no* knowledge of
axis systems -- it just multiplies points by `M` and normals by the
inverse-transpose of `M`. Translation is never baked (scale + rotation only).

ASSUMPTION: the mesh's control points live directly in the imported mesh's local
space (identity FBX node/geometric transforms). That holds for this project's
geo/*.FBX assets (verified: pure axis conversion, no node transforms). The
script prints each node's local transform so any deviation is visible.

INSTALLING THE FBX PYTHON SDK
-----------------------------
This needs the Autodesk FBX Python SDK (the `fbx` module), which is NOT on PyPI.
The 2020.3.7 Windows installer bundles a pip wheel built for CPython 3.10, so the
clean install is (Python 3.11/3.12 will NOT work -- the wheel is cp310-only):

  1. Download (no Autodesk login required):
     https://damassets.autodesk.net/content/dam/autodesk/www/files/fbx202037_fbxpythonsdk_win.exe
  2. Extract it (7-Zip opens the installer directly):
     7z x fbx202037_fbxpythonsdk_win.exe -oout
  3. pip-install the bundled wheel into a Python 3.10:
     <py310>\python.exe -m pip install out\fbx-2020.3.7-cp310-none-win_amd64.whl
  4. Verify:  <py310>\python.exe -c "import fbx; print('fbx ok')"
  5. Point the Godot setting `meshfill_editor/bake_fbx_python` at that python.exe.

On this machine it is already installed into D:\Python310 and the setting is
preset to D:/Python310/python.exe in project.godot.

USAGE
-----
  python bake_fbx_transform.py --fbx <abs.FBX> \
      --basis-cols "x.x,x.y,x.z,y.x,y.y,y.z,z.x,z.y,z.z" \
      [--backup <dir>] [--ascii] [--label <name>] [--dry-run]

Exit codes: 0 ok, 2 fbx module missing, 3 bad args, 4 load/save failure.
"""

import argparse
import os
import shutil
import sys
import time


def eprint(*args):
    print(*args, file=sys.stderr)


def import_fbx():
    """Import the fbx module or exit(2) with actionable instructions."""
    try:
        import fbx  # noqa: F401
        return fbx
    except ImportError as exc:
        eprint("=" * 68)
        eprint("[bake_fbx] FATAL: the Autodesk FBX Python SDK ('fbx') is not")
        eprint("           importable by this interpreter:")
        eprint("             %s  (Python %s)" % (sys.executable,
                                                 sys.version.split()[0]))
        eprint("           ImportError: %s" % exc)
        eprint("-" * 68)
        eprint("The FBX SDK is not on PyPI. The 2020.3.7 installer bundles a")
        eprint("CPython 3.10 wheel (Python 3.11/3.12 will NOT work). Steps:")
        eprint("  1. Download (no login):")
        eprint("     https://damassets.autodesk.net/content/dam/autodesk/www/files/fbx202037_fbxpythonsdk_win.exe")
        eprint("  2. 7z x fbx202037_fbxpythonsdk_win.exe -oout")
        eprint("  3. <py310> -m pip install out/fbx-2020.3.7-cp310-none-win_amd64.whl")
        eprint("  4. Point Godot setting 'meshfill_editor/bake_fbx_python' at <py310>.")
        eprint("=" * 68)
        sys.exit(2)


# --- tiny 3x3 linear algebra (no numpy dependency) -------------------------

def parse_basis_cols(text):
    """Parse 9 comma floats (col0 xyz, col1 xyz, col2 xyz) into row matrix M.

    Godot sends basis columns B.x, B.y, B.z. A point transforms as
    new = B.x*p.x + B.y*p.y + B.z*p.z, i.e. M[i][j] = col_j[i].
    Returns M as 3 rows [[m00,m01,m02],[m10,m11,m12],[m20,m21,m22]].
    """
    parts = [s for s in text.replace(" ", "").split(",") if s != ""]
    if len(parts) != 9:
        eprint("[bake_fbx] --basis-cols needs exactly 9 floats, got %d" % len(parts))
        sys.exit(3)
    v = [float(x) for x in parts]
    col0 = (v[0], v[1], v[2])
    col1 = (v[3], v[4], v[5])
    col2 = (v[6], v[7], v[8])
    m = [
        [col0[0], col1[0], col2[0]],
        [col0[1], col1[1], col2[1]],
        [col0[2], col1[2], col2[2]],
    ]
    return m


def mat_apply(m, x, y, z):
    return (
        m[0][0] * x + m[0][1] * y + m[0][2] * z,
        m[1][0] * x + m[1][1] * y + m[1][2] * z,
        m[2][0] * x + m[2][1] * y + m[2][2] * z,
    )


def mat_det(m):
    return (
        m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
        - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
        + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
    )


def mat_inverse_transpose(m):
    """Return (M^-1)^T, used to transform normals. None if singular."""
    det = mat_det(m)
    if abs(det) < 1e-12:
        return None
    inv_det = 1.0 / det
    # cofactor / adjugate -> inverse, then transpose.
    inv = [[0.0] * 3 for _ in range(3)]
    inv[0][0] = (m[1][1] * m[2][2] - m[1][2] * m[2][1]) * inv_det
    inv[0][1] = (m[0][2] * m[2][1] - m[0][1] * m[2][2]) * inv_det
    inv[0][2] = (m[0][1] * m[1][2] - m[0][2] * m[1][1]) * inv_det
    inv[1][0] = (m[1][2] * m[2][0] - m[1][0] * m[2][2]) * inv_det
    inv[1][1] = (m[0][0] * m[2][2] - m[0][2] * m[2][0]) * inv_det
    inv[1][2] = (m[0][2] * m[1][0] - m[0][0] * m[1][2]) * inv_det
    inv[2][0] = (m[1][0] * m[2][1] - m[1][1] * m[2][0]) * inv_det
    inv[2][1] = (m[0][1] * m[2][0] - m[0][0] * m[2][1]) * inv_det
    inv[2][2] = (m[0][0] * m[1][1] - m[0][1] * m[1][0]) * inv_det
    # transpose
    return [[inv[j][i] for j in range(3)] for i in range(3)]


def normalize3(x, y, z):
    n = (x * x + y * y + z * z) ** 0.5
    if n < 1e-20:
        return (x, y, z)
    return (x / n, y / n, z / n)


# --- FBX traversal & baking -------------------------------------------------

def iter_nodes(node):
    yield node
    for i in range(node.GetChildCount()):
        for n in iter_nodes(node.GetChild(i)):
            yield n


def control_point_bounds(mesh):
    n = mesh.GetControlPointsCount()
    if n == 0:
        return None
    lo = [float("inf")] * 3
    hi = [float("-inf")] * 3
    for i in range(n):
        cp = mesh.GetControlPointAt(i)
        for a in range(3):
            lo[a] = min(lo[a], cp[a])
            hi[a] = max(hi[a], cp[a])
    return (tuple(lo), tuple(hi))


def fmt_bounds(b):
    if b is None:
        return "(empty)"
    lo, hi = b
    size = tuple(hi[a] - lo[a] for a in range(3))
    return "min(%.3f,%.3f,%.3f) size(%.3f,%.3f,%.3f)" % (lo + size)


def transform_direction_array(fbx, da, mat, do_normalize):
    for i in range(da.GetCount()):
        v = da.GetAt(i)
        nx, ny, nz = mat_apply(mat, v[0], v[1], v[2])
        if do_normalize:
            nx, ny, nz = normalize3(nx, ny, nz)
        da.SetAt(i, fbx.FbxVector4(nx, ny, nz, v[3]))


def bake_mesh(fbx, mesh, m_point, m_normal, label):
    count = mesh.GetControlPointsCount()
    for i in range(count):
        cp = mesh.GetControlPointAt(i)
        nx, ny, nz = mat_apply(m_point, cp[0], cp[1], cp[2])
        mesh.SetControlPointAt(fbx.FbxVector4(nx, ny, nz, cp[3]), i)

    # Normals -> inverse-transpose (so they stay perpendicular under non-uniform
    # scale); tangents/binormals are surface directions -> use the point matrix.
    for li in range(mesh.GetElementNormalCount()):
        transform_direction_array(fbx, mesh.GetElementNormal(li).GetDirectArray(),
                                   m_normal, True)
    for li in range(mesh.GetElementTangentCount()):
        transform_direction_array(fbx, mesh.GetElementTangent(li).GetDirectArray(),
                                   m_point, True)
    for li in range(mesh.GetElementBinormalCount()):
        transform_direction_array(fbx, mesh.GetElementBinormal(li).GetDirectArray(),
                                   m_point, True)
    return count


def node_transform_str(node):
    t = node.LclTranslation.Get()
    r = node.LclRotation.Get()
    s = node.LclScaling.Get()
    return "T(%.3f,%.3f,%.3f) R(%.2f,%.2f,%.2f) S(%.3f,%.3f,%.3f)" % (
        t[0], t[1], t[2], r[0], r[1], r[2], s[0], s[1], s[2])


def backup_file(src, backup_dir):
    os.makedirs(backup_dir, exist_ok=True)
    base = os.path.basename(src)
    stem, ext = os.path.splitext(base)
    stamp = time.strftime("%Y%m%d_%H%M%S")
    dest = os.path.join(backup_dir, "%s__%s%s" % (stem, stamp, ext))
    i = 1
    while os.path.exists(dest):
        dest = os.path.join(backup_dir, "%s__%s_%d%s" % (stem, stamp, i, ext))
        i += 1
    shutil.copy2(src, dest)
    return dest


def main():
    ap = argparse.ArgumentParser(description="Bake scale+rotation into FBX geometry.")
    ap.add_argument("--fbx", required=True, help="absolute path to the FBX to modify")
    ap.add_argument("--basis-cols", required=True,
                    help="9 comma floats: col0 xyz, col1 xyz, col2 xyz (Godot basis)")
    ap.add_argument("--backup", default="", help="dir to copy the original into first")
    ap.add_argument("--ascii", action="store_true", help="write ASCII FBX (default binary)")
    ap.add_argument("--label", default="", help="cosmetic label for logging")
    ap.add_argument("--dry-run", action="store_true", help="parse + report, do not write")
    args = ap.parse_args()

    fbx = import_fbx()

    src = os.path.abspath(args.fbx)
    if not os.path.isfile(src):
        eprint("[bake_fbx] file not found: %s" % src)
        sys.exit(3)

    m_point = parse_basis_cols(args.basis_cols)
    m_normal = mat_inverse_transpose(m_point)
    if m_normal is None:
        eprint("[bake_fbx] transform is singular (zero scale?) -- aborting")
        sys.exit(3)
    det = mat_det(m_point)

    print("[bake_fbx] %s%s" % (args.label + " " if args.label else "", src))
    print("[bake_fbx] point matrix rows: %s" % m_point)
    print("[bake_fbx] determinant: %.6f%s" % (
        det, "  (NEGATIVE -> mirrored; winding not flipped)" if det < 0 else ""))

    manager = fbx.FbxManager.Create()
    try:
        ios = fbx.FbxIOSettings.Create(manager, fbx.IOSROOT)
        manager.SetIOSettings(ios)

        importer = fbx.FbxImporter.Create(manager, "")
        if not importer.Initialize(src, -1, manager.GetIOSettings()):
            eprint("[bake_fbx] importer init failed: %s"
                   % importer.GetStatus().GetErrorString())
            sys.exit(4)
        scene = fbx.FbxScene.Create(manager, "bakeScene")
        if not importer.Import(scene):
            eprint("[bake_fbx] import failed: %s"
                   % importer.GetStatus().GetErrorString())
            sys.exit(4)
        importer.Destroy()

        total_meshes = 0
        total_points = 0
        root = scene.GetRootNode()
        for node in iter_nodes(root):
            mesh = node.GetMesh()
            if mesh is None:
                continue
            before = control_point_bounds(mesh)
            print("[bake_fbx]   node '%s'  %s" % (node.GetName(), node_transform_str(node)))
            print("[bake_fbx]     before: %s" % fmt_bounds(before))
            n = bake_mesh(fbx, mesh, m_point, m_normal, node.GetName())
            after = control_point_bounds(mesh)
            print("[bake_fbx]     after : %s" % fmt_bounds(after))
            total_meshes += 1
            total_points += n

        if total_meshes == 0:
            eprint("[bake_fbx] no mesh nodes found in scene -- nothing baked")
            sys.exit(4)

        print("[bake_fbx] baked %d mesh(es), %d control points" % (total_meshes, total_points))

        if args.dry_run:
            print("[bake_fbx] dry-run: not writing")
            return

        if args.backup:
            dest = backup_file(src, os.path.abspath(args.backup))
            print("[bake_fbx] backup: %s" % dest)

        registry = manager.GetIOPluginRegistry()
        if args.ascii:
            fmt = registry.FindWriterIDByDescription("FBX ascii (*.fbx)")
            if fmt < 0:
                fmt = registry.GetNativeWriterFormat()
        else:
            fmt = registry.GetNativeWriterFormat()  # binary FBX
        exporter = fbx.FbxExporter.Create(manager, "")
        if not exporter.Initialize(src, fmt, manager.GetIOSettings()):
            eprint("[bake_fbx] exporter init failed: %s"
                   % exporter.GetStatus().GetErrorString())
            sys.exit(4)
        if not exporter.Export(scene):
            eprint("[bake_fbx] export failed: %s"
                   % exporter.GetStatus().GetErrorString())
            sys.exit(4)
        exporter.Destroy()
        print("[bake_fbx] wrote: %s" % src)
    finally:
        manager.Destroy()


if __name__ == "__main__":
    main()
