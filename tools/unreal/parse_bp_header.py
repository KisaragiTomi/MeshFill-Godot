import struct, sys, os

sys.stdout.reconfigure(encoding='utf-8', errors='replace')

def read_fstring(data, pos):
    slen = struct.unpack_from('<i', data, pos)[0]
    pos += 4
    if slen == 0:
        return '', pos
    if slen > 0:
        s = data[pos:pos+slen-1].decode('utf-8', errors='replace')
        pos += slen
    else:
        actual = -slen
        s = data[pos:pos+actual*2-2].decode('utf-16-le', errors='replace')
        pos += actual * 2
    return s, pos

def parse_header(data):
    tag = struct.unpack_from('<I', data, 0)[0]
    assert tag == 0x9E2A83C1, f"Not a valid uasset: tag=0x{tag:08X}"
    lfv = struct.unpack_from('<i', data, 4)[0]
    pos = 8
    if lfv != -4:
        pos += 4  # LegacyUE3Version
    file_ver_ue4 = struct.unpack_from('<i', data, pos)[0]; pos += 4
    file_ver_ue5 = 0
    if lfv <= -8:
        file_ver_ue5 = struct.unpack_from('<i', data, pos)[0]; pos += 4
    file_ver_licensee = struct.unpack_from('<i', data, pos)[0]; pos += 4
    custom_count = 0
    if lfv <= -2:
        custom_count = struct.unpack_from('<i', data, pos)[0]; pos += 4
        if 0 < custom_count < 500:
            pos += custom_count * 20
    total_header_size = struct.unpack_from('<i', data, pos)[0]; pos += 4
    folder, pos = read_fstring(data, pos)
    pkg_flags = struct.unpack_from('<I', data, pos)[0]; pos += 4
    name_count = struct.unpack_from('<i', data, pos)[0]
    name_offset = struct.unpack_from('<i', data, pos+4)[0]; pos += 8
    sop_count = struct.unpack_from('<i', data, pos)[0]
    sop_offset = struct.unpack_from('<i', data, pos+4)[0]; pos += 8
    loc_id, pos = read_fstring(data, pos)
    gtd_count = struct.unpack_from('<i', data, pos)[0]
    gtd_offset = struct.unpack_from('<i', data, pos+4)[0]; pos += 8
    export_count = struct.unpack_from('<i', data, pos)[0]
    export_offset = struct.unpack_from('<i', data, pos+4)[0]; pos += 8
    import_count = struct.unpack_from('<i', data, pos)[0]
    import_offset = struct.unpack_from('<i', data, pos+4)[0]; pos += 8
    depends_offset = struct.unpack_from('<i', data, pos)[0]; pos += 4

    return {
        'lfv': lfv, 'ue4_ver': file_ver_ue4, 'ue5_ver': file_ver_ue5,
        'name_count': name_count, 'name_offset': name_offset,
        'export_count': export_count, 'export_offset': export_offset,
        'import_count': import_count, 'import_offset': import_offset,
        'total_header_size': total_header_size,
    }

def parse_names(data, name_offset, name_count):
    names = []
    pos = name_offset
    for i in range(name_count):
        if pos + 4 > len(data):
            break
        slen = struct.unpack_from('<i', data, pos)[0]; pos += 4
        if slen == 0:
            names.append(''); pos += 4; continue
        if slen > 0 and slen < 2000:
            name = data[pos:pos+slen-1].decode('utf-8', errors='replace'); pos += slen
        elif slen < 0 and slen > -2000:
            actual = -slen
            name = data[pos:pos+actual*2-2].decode('utf-16-le', errors='replace'); pos += actual * 2
        else:
            break
        pos += 4
        names.append(name)
    return names

def search_property_patterns(data, names, export_offset, total_header_size):
    """Search for error-related property serializations in binary"""
    name_to_idx = {n: i for i, n in enumerate(names)}

    # Get important name indices
    errormsg_idx = name_to_idx.get('ErrorMsg', -1)
    errortype_idx = name_to_idx.get('ErrorType', -1)
    hascompilermsg_idx = name_to_idx.get('bHasCompilerMessage', -1)
    strprop_idx = name_to_idx.get('StrProperty', -1)
    intprop_idx = name_to_idx.get('IntProperty', -1)
    boolprop_idx = name_to_idx.get('BoolProperty', -1)

    print(f"\n--- Name indices ---")
    print(f"  ErrorMsg={errormsg_idx}, ErrorType={errortype_idx}, bHasCompilerMessage={hascompilermsg_idx}")
    print(f"  StrProperty={strprop_idx}, IntProperty={intprop_idx}, BoolProperty={boolprop_idx}")

    errors_found = []

    # Search for ErrorMsg StrProperty pattern in binary
    if errormsg_idx >= 0 and strprop_idx >= 0:
        # Pattern: [errormsg_idx as u32][0 as u32][strprop_idx as u32][0 as u32]
        pattern = struct.pack('<IIII', errormsg_idx, 0, strprop_idx, 0)
        pos = 0
        while True:
            idx = data.find(pattern, pos)
            if idx < 0:
                break
            # Read size and array index
            off = idx + 16
            if off + 8 <= len(data):
                size = struct.unpack_from('<i', data, off)[0]
                arr_idx = struct.unpack_from('<i', data, off+4)[0]
                off += 8
                # Read FString value
                if size > 0 and off + 4 <= len(data):
                    str_len = struct.unpack_from('<i', data, off)[0]
                    if str_len > 0 and off + 4 + str_len <= len(data):
                        msg = data[off+4:off+4+str_len-1].decode('utf-8', errors='replace')
                        if msg.strip():
                            errors_found.append(('ErrorMsg', msg, idx))
                            print(f"  Found ErrorMsg at offset {idx}: \"{msg[:200]}\"")
                    elif str_len < 0:
                        actual = -str_len
                        msg = data[off+4:off+4+actual*2-2].decode('utf-16-le', errors='replace')
                        if msg.strip():
                            errors_found.append(('ErrorMsg', msg, idx))
                            print(f"  Found ErrorMsg at offset {idx}: \"{msg[:200]}\"")
            pos = idx + 1

    # Search for bHasCompilerMessage BoolProperty
    if hascompilermsg_idx >= 0 and boolprop_idx >= 0:
        pattern = struct.pack('<IIII', hascompilermsg_idx, 0, boolprop_idx, 0)
        pos = 0
        while True:
            idx = data.find(pattern, pos)
            if idx < 0:
                break
            off = idx + 16
            if off + 9 <= len(data):
                size = struct.unpack_from('<i', data, off)[0]
                arr_idx = struct.unpack_from('<i', data, off+4)[0]
                val = data[off+8]
                if val:
                    errors_found.append(('bHasCompilerMessage', True, idx))
                    print(f"  Found bHasCompilerMessage=True at offset {idx}")
            pos = idx + 1

    # Search for ErrorType IntProperty
    if errortype_idx >= 0 and intprop_idx >= 0:
        pattern = struct.pack('<IIII', errortype_idx, 0, intprop_idx, 0)
        pos = 0
        while True:
            idx = data.find(pattern, pos)
            if idx < 0:
                break
            off = idx + 16
            if off + 12 <= len(data):
                size = struct.unpack_from('<i', data, off)[0]
                arr_idx = struct.unpack_from('<i', data, off+4)[0]
                val = struct.unpack_from('<i', data, off+8)[0]
                errors_found.append(('ErrorType', val, idx))
                print(f"  Found ErrorType={val} at offset {idx}")
            pos = idx + 1

    return errors_found


path = r'D:\KeLuwang_PC-KeLuWang_1851\Lycoris_main\Content\BP_Test.uasset'
with open(path, 'rb') as f:
    data = f.read()

print(f"File: {path}")
print(f"Size: {len(data)} bytes")

hdr = parse_header(data)
print(f"UE4={hdr['ue4_ver']}, UE5={hdr['ue5_ver']}, Exports={hdr['export_count']}, Imports={hdr['import_count']}")

names = parse_names(data, hdr['name_offset'], hdr['name_count'])
print(f"Parsed {len(names)} names")

# Check if it's a Blueprint
is_bp = any(n in ('Blueprint', 'WidgetBlueprint', 'AnimBlueprint') for n in names)
print(f"Is Blueprint: {is_bp}")

errors = search_property_patterns(data, names, hdr['export_offset'], hdr['total_header_size'])
print(f"\n=== RESULT ===")
if not errors:
    print("No compilation errors detected in binary data")
else:
    err_msgs = [e for e in errors if e[0] == 'ErrorMsg']
    print(f"Found {len(err_msgs)} error message(s), {len(errors)} total error indicators")
    for e in err_msgs:
        print(f"  ERROR: {e[1][:300]}")
