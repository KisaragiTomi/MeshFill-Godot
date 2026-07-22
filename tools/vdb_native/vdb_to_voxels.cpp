// Native OpenVDB (.vdb) -> voxel-cache reader for the MeshFill AssetDescriptor demo.
// This is the FAST backend for the editor tool "Import VDB": it links Houdini's bundled
// OpenVDB (openvdb_sesi) and reads a .vdb in milliseconds, with no Houdini engine init
// and no license checkout — replacing the ~5s-per-import hython path
// (tools/convert_vdb_to_voxels.py, which stays as a fallback and writes JSON instead).
//
// Output is a COMPACT BINARY cache (see the layout comment near the fwrites below).
// VdbVoxelImportService.load_voxel_result auto-detects it via the "MFV1" magic and
// bulk-decodes each SoA array — far faster than JSON.parse + per-voxel dict building,
// which dominated import time for large assets (~108k voxels). local_center is not
// stored (the reader derives it). The Python fallback still writes JSON; the reader
// accepts either.
//
// OCCUPANCY (which voxels form the asset body) comes from the complexity grid's ACTIVE
// TOPOLOGY — the first available of complexity -> collision -> color — NOT from the
// collision VALUE. A soft asset (grass) has collision == 0 on every voxel, so gating on
// collision would drop the whole body. collision / complexity / colour are read as
// per-voxel VALUES with constant fallbacks (collision=1, complexity=1, colour=white)
// when a grid is absent. This matches the fixed Python _read_with_hou semantics.
//
// CLI (identical flags to convert_vdb_to_voxels.py so the service calls it the same way):
//   vdb_to_voxels --input a.vdb --output a.json
//                 [--grid-collision collision] [--grid-complexity complexity]
//                 [--grid-color Cd] [--scale 1.0] [--max-voxels 4000000]
// --scale multiplies cell_size / aabb only (and thus the derived local_center); units
// reconcile, e.g. cm->m. Voxel indices and the 5-dim values are never scaled.
// Diagnostics + errors are written to "<output>.log" (the service reads it), mirroring
// the Python sidecar-log convention. Exit code 0 = ok, non-zero = failure.

#include <openvdb/openvdb.h>
#include <openvdb/io/File.h>

#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <string>
#include <vector>

namespace {

FILE* g_log = nullptr;

void logf(const char* fmt, ...) {
    va_list ap;
    if (g_log) {
        va_start(ap, fmt);
        std::vfprintf(g_log, fmt, ap);
        va_end(ap);
        std::fflush(g_log);
    }
    va_start(ap, fmt);
    std::vfprintf(stderr, fmt, ap);
    va_end(ap);
}

int fail(const char* msg) {
    logf("[vdb_to_voxels] %s\n", msg);
    return 2;
}

std::string arg_value(int argc, char** argv, const std::string& key, const std::string& def) {
    for (int i = 1; i + 1 < argc; ++i)
        if (key == argv[i]) return argv[i + 1];
    return def;
}

// Collect every ACTIVE voxel coord of a typed grid (true VDB topology). Active TILES
// (rare for rasterized grids) are expanded to individual voxels. GridBase has no value
// iterator, so this is templated on the concrete grid type.
template <typename GridT>
void collect_active(const typename GridT::Ptr& g, std::vector<openvdb::Coord>& out) {
    for (auto it = g->cbeginValueOn(); it; ++it) {
        if (it.isVoxelValue()) {
            out.push_back(it.getCoord());
        } else {
            openvdb::CoordBBox tb;
            it.getBoundingBox(tb);
            for (int i = tb.min()[0]; i <= tb.max()[0]; ++i)
                for (int j = tb.min()[1]; j <= tb.max()[1]; ++j)
                    for (int k = tb.min()[2]; k <= tb.max()[2]; ++k)
                        out.push_back(openvdb::Coord(i, j, k));
        }
    }
}

}  // namespace

int main(int argc, char** argv) {
    const std::string input = arg_value(argc, argv, "--input", "");
    const std::string output = arg_value(argc, argv, "--output", "");
    const std::string g_coll = arg_value(argc, argv, "--grid-collision", "collision");
    const std::string g_cplx = arg_value(argc, argv, "--grid-complexity", "complexity");
    const std::string g_col = arg_value(argc, argv, "--grid-color", "Cd");
    const double scale = std::atof(arg_value(argc, argv, "--scale", "1.0").c_str());
    const size_t max_voxels = static_cast<size_t>(
        std::atoll(arg_value(argc, argv, "--max-voxels", "4000000").c_str()));

    if (input.empty() || output.empty()) {
        std::fprintf(stderr, "[vdb_to_voxels] --input and --output are required\n");
        return 2;
    }
    // Diagnostics go to "<output>.log" (service reads it), like the Python backend.
    g_log = std::fopen((output + ".log").c_str(), "w");

    openvdb::initialize();

    openvdb::GridPtrVecPtr grids;
    try {
        openvdb::io::File file(input);
        file.open();
        grids = file.getGrids();
        file.close();
    } catch (const std::exception& e) {
        return fail((std::string("failed to read '") + input + "': " + e.what()).c_str());
    }
    if (!grids || grids->empty())
        return fail((std::string("no grids found in '") + input + "'").c_str());

    std::map<std::string, openvdb::GridBase::Ptr> by_name;
    std::string names;
    for (const auto& g : *grids) {
        by_name[g->getName()] = g;
        names += (names.empty() ? "" : ",") + g->getName();
    }

    openvdb::FloatGrid::Ptr coll = openvdb::gridPtrCast<openvdb::FloatGrid>(
        by_name.count(g_coll) ? by_name[g_coll] : nullptr);
    openvdb::FloatGrid::Ptr cplx = openvdb::gridPtrCast<openvdb::FloatGrid>(
        by_name.count(g_cplx) ? by_name[g_cplx] : nullptr);
    openvdb::Vec3SGrid::Ptr col = openvdb::gridPtrCast<openvdb::Vec3SGrid>(
        by_name.count(g_col) ? by_name[g_col] : nullptr);

    // Occupancy reference: complexity -> collision -> color. (See file header.)
    openvdb::GridBase::Ptr occ_base;
    std::string occ_name;
    if (cplx) { occ_base = cplx; occ_name = g_cplx; }
    else if (coll) { occ_base = coll; occ_name = g_coll; }
    else if (col) { occ_base = col; occ_name = g_col; }
    if (!occ_base)
        return fail((std::string("none of the requested grids exist (complexity/collision/color); "
                                 "grids present: ") + names).c_str());

    logf("[vdb_to_voxels] backend=native(openvdb) grids=[%s] | occupancy_ref=%s | "
         "collision=%s complexity=%s color=%s\n",
         names.c_str(), occ_name.c_str(),
         coll ? "true" : "false", cplx ? "true" : "false", col ? "true" : "false");

    const openvdb::math::Transform& xform = occ_base->transform();
    const double cell = xform.voxelSize()[0];
    if (cell <= 0.0)
        return fail("occupancy grid has non-positive voxel size");

    openvdb::CoordBBox bbox = occ_base->evalActiveVoxelBoundingBox();
    if (bbox.empty())
        return fail((std::string("occupancy grid '") + occ_name + "' has no active voxels").c_str());
    const openvdb::Coord lo = bbox.min();
    const openvdb::Coord dim = bbox.dim();  // max - min + 1

    // Persistent empty grids back the fallback accessors so they never dangle (an
    // accessor holds a reference to its grid's tree). The accessors are only queried
    // when the matching grid actually exists (guarded in emit), but must stay valid.
    openvdb::FloatGrid::Ptr empty_f = openvdb::FloatGrid::create();
    openvdb::Vec3SGrid::Ptr empty_v = openvdb::Vec3SGrid::create();
    openvdb::FloatGrid::ConstAccessor acc_coll = (coll ? coll : empty_f)->getConstAccessor();
    openvdb::FloatGrid::ConstAccessor acc_cplx = (cplx ? cplx : empty_f)->getConstAccessor();
    openvdb::Vec3SGrid::ConstAccessor acc_col = (col ? col : empty_v)->getConstAccessor();

    // Collect per-voxel data as SoA for a compact BINARY cache (see layout below) instead
    // of a 13MB JSON string: the GDScript reader bulk-decodes each array
    // (to_int32_array/to_float32_array) rather than running JSON.parse + building one dict
    // per voxel, which dominated import time for big assets (~108k voxels => ~1s). Emitting
    // per ACTIVE coord of the occupancy grid (true VDB topology). local_center is OMITTED —
    // the reader derives it from voxel index + cell_size + aabb_min (exactly equal for the
    // uniform, axis-aligned grids this pipeline authors), so it need not be stored.
    std::vector<int32_t> ijk;        // 3N: i,j,k per voxel (bbox-relative)
    std::vector<float> rgb;          // 3N: r,g,b
    std::vector<float> cplx_vals;    // N
    std::vector<float> coll_vals;    // N
    size_t count = 0;
    auto emit = [&](const openvdb::Coord& c) -> bool {
        const float complexity = cplx ? static_cast<float>(acc_cplx.getValue(c)) : 1.0f;
        // collision defaults to solid (1) only when NO collision grid exists; a present
        // grid's real value wins even when it is 0 (grass).
        const float collision = coll ? static_cast<float>(acc_coll.getValue(c)) : 1.0f;
        float r = 1.0f, g = 1.0f, b = 1.0f;
        if (col) { const openvdb::Vec3s cv = acc_col.getValue(c); r = cv[0]; g = cv[1]; b = cv[2]; }
        ijk.push_back(c[0] - lo[0]); ijk.push_back(c[1] - lo[1]); ijk.push_back(c[2] - lo[2]);
        rgb.push_back(r); rgb.push_back(g); rgb.push_back(b);
        cplx_vals.push_back(complexity);
        coll_vals.push_back(collision);
        ++count;
        return count <= max_voxels;
    };

    // Active coords of the occupancy grid (same complexity->collision->color priority as
    // occ_base above, so it iterates that grid's true topology).
    std::vector<openvdb::Coord> coords;
    if (cplx) collect_active<openvdb::FloatGrid>(cplx, coords);
    else if (coll) collect_active<openvdb::FloatGrid>(coll, coords);
    else collect_active<openvdb::Vec3SGrid>(col, coords);

    for (const openvdb::Coord& c : coords)
        if (!emit(c)) return fail("active voxel count exceeds --max-voxels");
    if (count == 0)
        return fail((std::string("occupancy grid '") + occ_name + "' has no active voxels").c_str());

    const openvdb::Vec3d min_center = xform.indexToWorld(lo);
    const float cell_size_f = static_cast<float>(cell * scale);
    const float aabb_min_f[3] = {static_cast<float>((min_center[0] - 0.5 * cell) * scale),
                                 static_cast<float>((min_center[1] - 0.5 * cell) * scale),
                                 static_cast<float>((min_center[2] - 0.5 * cell) * scale)};
    const float aabb_size_f[3] = {static_cast<float>(dim[0] * cell * scale),
                                  static_cast<float>(dim[1] * cell * scale),
                                  static_cast<float>(dim[2] * cell * scale)};
    const int32_t grid_i[3] = {dim[0], dim[1], dim[2]};
    const uint32_t n = static_cast<uint32_t>(count);
    const uint32_t version = 1;

    // Binary layout (all little-endian): "MFV1" | u32 version | f32 cell_size |
    // f32[3] aabb_min | f32[3] aabb_size | i32[3] grid | u32 count |
    // i32[3N] ijk | f32[3N] rgb | f32[N] complexity | f32[N] collision.
    FILE* fh = std::fopen(output.c_str(), "wb");
    if (!fh)
        return fail((std::string("failed to open output '") + output + "'").c_str());
    std::fwrite("MFV1", 1, 4, fh);
    std::fwrite(&version, 4, 1, fh);
    std::fwrite(&cell_size_f, 4, 1, fh);
    std::fwrite(aabb_min_f, 4, 3, fh);
    std::fwrite(aabb_size_f, 4, 3, fh);
    std::fwrite(grid_i, 4, 3, fh);
    std::fwrite(&n, 4, 1, fh);
    std::fwrite(ijk.data(), 4, ijk.size(), fh);
    std::fwrite(rgb.data(), 4, rgb.size(), fh);
    std::fwrite(cplx_vals.data(), 4, cplx_vals.size(), fh);
    std::fwrite(coll_vals.data(), 4, coll_vals.size(), fh);
    std::fclose(fh);

    logf("[vdb_to_voxels] wrote %zu voxels (grid=[%d,%d,%d] cell=%.4f scale=%.4g) -> %s\n",
         count, dim[0], dim[1], dim[2], cell * scale, scale, output.c_str());
    if (g_log) std::fclose(g_log);
    return 0;
}
