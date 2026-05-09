import struct
import sys
import os

def read_fstring(f):
    length = struct.unpack('<i', f.read(4))[0]
    if length == 0:
        return ""
    if length > 0:
        raw = f.read(length)
        return raw[:-1].decode('utf-8', errors='replace')
    else:
        char_count = -length
        raw = f.read(char_count * 2)
        return raw.decode('utf-16-le', errors='replace').rstrip('\x00')

def parse_uasset(filepath):
    result = []
    filesize = os.path.getsize(filepath)
    result.append(f"# UAsset Analysis: {os.path.basename(filepath)}")
    result.append(f"\n**File Size**: {filesize:,} bytes ({filesize/1024/1024:.2f} MB)")
    result.append(f"**File Path**: `{filepath}`\n")

    with open(filepath, 'rb') as f:
        magic = struct.unpack('<I', f.read(4))[0]
        result.append("## Header")
        result.append(f"- **Magic**: 0x{magic:08X} ({'Valid UAsset' if magic == 0x9E2A83C1 else 'INVALID'})")

        if magic != 0x9E2A83C1:
            result.append("\n> Not a valid UAsset file!")
            return "\n".join(result)

        legacy_version = struct.unpack('<i', f.read(4))[0]
        result.append(f"- **Legacy File Version**: {legacy_version}")

        if legacy_version < -7:
            legacy_ue3_version = struct.unpack('<i', f.read(4))[0]
            result.append(f"- **Legacy UE3 Version**: {legacy_ue3_version}")

        file_version_ue4 = struct.unpack('<i', f.read(4))[0]
        result.append(f"- **UE4 File Version**: {file_version_ue4}")

        file_version_ue5 = 0
        if legacy_version <= -8:
            file_version_ue5 = struct.unpack('<i', f.read(4))[0]
            result.append(f"- **UE5 File Version**: {file_version_ue5}")

        file_version_licensee = struct.unpack('<i', f.read(4))[0]
        result.append(f"- **Licensee Version**: {file_version_licensee}")

        if legacy_version <= -2:
            custom_version_count = struct.unpack('<i', f.read(4))[0]
            result.append(f"- **Custom Versions Count**: {custom_version_count}")
            for i in range(min(custom_version_count, 200)):
                f.read(16 + 4)

        total_header_size = struct.unpack('<i', f.read(4))[0]
        result.append(f"- **Total Header Size**: {total_header_size:,} bytes")

        folder_name = read_fstring(f)
        result.append(f"- **Folder Name**: `{folder_name}`")

        package_flags = struct.unpack('<I', f.read(4))[0]
        result.append(f"- **Package Flags**: 0x{package_flags:08X}")

        name_count = struct.unpack('<i', f.read(4))[0]
        name_offset = struct.unpack('<i', f.read(4))[0]
        result.append(f"- **Name Count**: {name_count}")
        result.append(f"- **Name Offset**: {name_offset}")

        # UE5: SoftObjectPaths
        soft_object_count = 0
        if file_version_ue5 >= 1:
            soft_object_count = struct.unpack('<i', f.read(4))[0]
            soft_object_offset = struct.unpack('<i', f.read(4))[0]
            result.append(f"- **Soft Object Paths Count**: {soft_object_count}")

        # Localization ID (FString)
        if file_version_ue4 >= 459:
            loc_id = read_fstring(f)

        # Gatherable text
        if file_version_ue4 >= 459:
            gatherable_count = struct.unpack('<i', f.read(4))[0]
            gatherable_offset = struct.unpack('<i', f.read(4))[0]

        export_count = struct.unpack('<i', f.read(4))[0]
        export_offset = struct.unpack('<i', f.read(4))[0]
        result.append(f"- **Export Count**: {export_count}")
        result.append(f"- **Export Offset**: {export_offset}")

        import_count = struct.unpack('<i', f.read(4))[0]
        import_offset = struct.unpack('<i', f.read(4))[0]
        result.append(f"- **Import Count**: {import_count}")
        result.append(f"- **Import Offset**: {import_offset}")

        depends_offset = struct.unpack('<i', f.read(4))[0]

        if file_version_ue4 >= 384:
            string_ref_count = struct.unpack('<i', f.read(4))[0]
            string_ref_offset = struct.unpack('<i', f.read(4))[0]

        if file_version_ue4 >= 510:
            searchable_names_offset = struct.unpack('<i', f.read(4))[0]

        thumbnail_table_offset = struct.unpack('<i', f.read(4))[0]

        guid_bytes = f.read(16)
        guid_str = '-'.join([
            guid_bytes[0:4].hex().upper(),
            guid_bytes[4:6].hex().upper(),
            guid_bytes[6:8].hex().upper(),
            guid_bytes[8:10].hex().upper(),
            guid_bytes[10:16].hex().upper()
        ])
        result.append(f"- **Package GUID**: {guid_str}")

        # Read names table
        result.append("\n## Name Table (first 50)")
        result.append("| Index | Name |")
        result.append("|-------|------|")
        f.seek(name_offset)
        names = []
        for i in range(min(name_count, 300)):
            try:
                name = read_fstring(f)
                hash1 = struct.unpack('<H', f.read(2))[0]
                hash2 = struct.unpack('<H', f.read(2))[0]
                names.append(name)
                if i < 50:
                    result.append(f"| {i} | `{name}` |")
            except:
                break
        if name_count > 50:
            result.append(f"| ... | *({name_count - 50} more names)* |")

        # Validate export/import counts
        if export_count < 0 or export_count > 100000:
            result.append(f"\n> **Warning**: Export count ({export_count}) looks invalid, skipping tables.")
        else:
            # Read imports
            result.append(f"\n## Import Table ({import_count} entries)")
            result.append("| Index | Class Package | Class Name | Object Name |")
            result.append("|-------|--------------|------------|-------------|")
            f.seek(import_offset)
            for i in range(min(import_count, 50)):
                try:
                    class_pkg_idx = struct.unpack('<q', f.read(8))[0]
                    class_name_idx = struct.unpack('<q', f.read(8))[0]
                    outer_index = struct.unpack('<i', f.read(4))[0]
                    obj_name_idx = struct.unpack('<q', f.read(8))[0]
                    if file_version_ue4 >= 0:
                        f.read(4)

                    pkg_name = names[int(class_pkg_idx)] if 0 <= class_pkg_idx < len(names) else f"#{class_pkg_idx}"
                    cls_name = names[int(class_name_idx)] if 0 <= class_name_idx < len(names) else f"#{class_name_idx}"
                    obj_name = names[int(obj_name_idx)] if 0 <= obj_name_idx < len(names) else f"#{obj_name_idx}"
                    result.append(f"| {i} | `{pkg_name}` | `{cls_name}` | `{obj_name}` |")
                except:
                    result.append(f"| {i} | *parse error* | | |")
                    break

            # Read exports
            result.append(f"\n## Export Table ({export_count} entries)")
            result.append("| Index | Class | Object Name | Serial Size | Serial Offset |")
            result.append("|-------|-------|-------------|------------|---------------|")
            f.seek(export_offset)
            for i in range(min(export_count, 30)):
                try:
                    class_index = struct.unpack('<q', f.read(8))[0]
                    super_index = struct.unpack('<q', f.read(8))[0]
                    if file_version_ue4 >= 508:
                        template_index = struct.unpack('<i', f.read(4))[0]
                    outer_index = struct.unpack('<i', f.read(4))[0]
                    obj_name_idx = struct.unpack('<q', f.read(8))[0]
                    obj_flags = struct.unpack('<I', f.read(4))[0]
                    serial_size = struct.unpack('<q', f.read(8))[0]
                    serial_offset = struct.unpack('<q', f.read(8))[0]

                    obj_name = names[int(obj_name_idx)] if 0 <= obj_name_idx < len(names) else f"#{obj_name_idx}"

                    cls_name = ""
                    if class_index < 0:
                        cls_name = f"Import[{-class_index - 1}]"
                    elif class_index > 0:
                        cls_name = f"Export[{class_index-1}]"
                    else:
                        cls_name = "Class"

                    result.append(f"| {i} | {cls_name} | `{obj_name}` | {serial_size:,} bytes | {serial_offset} |")
                    f.read(4 + 4 + 4 + 4 + 8 + 4 + 8 + 8)
                    if file_version_ue4 >= 511:
                        f.read(1)
                except:
                    result.append(f"| {i} | *parse error* | | | |")
                    break

        # Detailed analysis from names
        result.append("\n## Asset Content Analysis")

        has_static_mesh = any("StaticMesh" in n for n in names)
        result.append(f"- **Asset Type**: {'Static Mesh (Merged)' if has_static_mesh else 'Unknown'}")

        material_names = [n for n in names if n.startswith("M_") or n.startswith("MI_") or n.startswith("/Game/") and "Material" in n.lower()]
        material_refs = [n for n in names if "Material" in n and not n.startswith("b") and "Slot" not in n and "Interface" not in n]
        all_materials = set()
        for n in names:
            if n.startswith("M_") or n.startswith("MI_"):
                all_materials.add(n)
            if "/Game/" in n and ("MI_" in n or "M_" in n):
                all_materials.add(n)

        result.append(f"\n### Materials ({len(all_materials)})")
        for m in sorted(all_materials):
            result.append(f"- `{m}`")

        mesh_related = [n for n in names if "SM_" in n or n.startswith("/Game/SM_")]
        result.append(f"\n### Mesh References")
        for m in sorted(set(mesh_related)):
            result.append(f"- `{m}`")

        path_refs = [n for n in names if n.startswith("/Game/") or n.startswith("/Engine/") or n.startswith("/Script/")]
        result.append(f"\n### Path References ({len(path_refs)})")
        for p in sorted(set(path_refs)):
            result.append(f"- `{p}`")

        build_props = [n for n in names if n.startswith("b") and n[1:2].isupper()]
        result.append(f"\n### Build Properties ({len(build_props)})")
        for p in sorted(build_props):
            result.append(f"- `{p}`")

        lod_names = [n for n in names if "LOD" in n.upper()]
        collision_names = [n for n in names if "Collision" in n or "collision" in n or "BodySetup" in n or "AggGeom" in n or "Convex" in n]
        result.append(f"\n### LOD Info")
        for l in sorted(set(lod_names)):
            result.append(f"- `{l}`")

        result.append(f"\n### Collision Setup")
        for c in sorted(set(collision_names)):
            result.append(f"- `{c}`")

        # Vertex/triangle cache info from names
        vert_tri_names = [n for n in names if "Vertices" in n or "Triangles" in n or "Cache" in n]
        if vert_tri_names:
            result.append(f"\n### Geometry Cache")
            for v in sorted(set(vert_tri_names)):
                result.append(f"- `{v}`")

        result.append(f"\n## Summary")
        result.append(f"- **Type**: Merged Static Mesh Actor (UE5 format)")
        result.append(f"- **UE Version**: UE4={file_version_ue4}, UE5={file_version_ue5}")
        result.append(f"- **Names**: {name_count}")
        result.append(f"- **Exports**: {export_count}")
        result.append(f"- **Imports**: {import_count}")
        result.append(f"- **Materials**: {', '.join(sorted(all_materials))}")
        result.append(f"- **Header**: {total_header_size:,} bytes")
        result.append(f"- **Payload**: {filesize - total_header_size:,} bytes ({(filesize - total_header_size)/filesize*100:.1f}%)")
        result.append(f"- **Content path**: `{folder_name}`")

    return "\n".join(result)


if __name__ == "__main__":
    filepath = r"D:\KeLuwang_PC-KeLuWang_1851\Lycoris_main\Content\SM_MERGED_StaticMeshActor_10.uasset"
    md_content = parse_uasset(filepath)
    output_path = r"D:\MyWork\UnrealProject\AITest\MeshFill-Godot\SM_MERGED_StaticMeshActor_10.md"
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(md_content)
    print(f"Analysis saved to: {output_path}")
    print(f"Content length: {len(md_content)} chars")
