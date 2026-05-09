import struct, sys
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

path = r'D:\KeLuwang_PC-KeLuWang_1851\Lycoris_main\Content\BP_Test.uasset'
with open(path, 'rb') as f:
    data = f.read()

# From previous parse: name indices
# bHasCompilerMessage=8, ErrorType=42, ErrorMsg=41
# BoolProperty=15, IntProperty=55, StrProperty=88, TextProperty=92

# Dump bytes around bHasCompilerMessage=True (offset 21341)
start = 21300
end = min(21500, len(data))
print(f"--- Raw bytes around bHasCompilerMessage (21341) ---")
for off in range(start, end, 4):
    vals = data[off:off+4]
    u32 = struct.unpack_from('<I', data, off)[0]
    s32 = struct.unpack_from('<i', data, off)[0]
    hex_str = ' '.join(f'{b:02X}' for b in vals)
    ascii_str = ''.join(chr(b) if 32 <= b < 127 else '.' for b in vals)
    marker = ""
    if off == 21341:
        marker = " <-- bHasCompilerMessage start"
    if off == 21366:
        marker = " <-- ErrorType start"
    print(f"  [{off:5d}] {hex_str}  {u32:10d}  {ascii_str}{marker}")

# Also search for ErrorMsg + TextProperty pattern (92 instead of StrProperty 88)
print(f"\n--- Searching ErrorMsg + TextProperty ---")
errormsg_idx = 41
textprop_idx = 92
pattern = struct.pack('<IIII', errormsg_idx, 0, textprop_idx, 0)
pos = 0
while True:
    idx = data.find(pattern, pos)
    if idx < 0:
        break
    print(f"  Found ErrorMsg+TextProperty at offset {idx}")
    off = idx + 16
    if off + 20 <= len(data):
        for o in range(off, min(off + 40, len(data)), 4):
            v = struct.unpack_from('<I', data, o)[0]
            hex_str = ' '.join(f'{b:02X}' for b in data[o:o+4])
            print(f"    [{o}] {hex_str} = {v}")
    pos = idx + 1

# Search for ALL property tags (look for patterns where second u32 is 0)
print(f"\n--- All property tags in export area (offset > 4499) ---")
known_types = {15: 'BoolProperty', 88: 'StrProperty', 55: 'IntProperty', 
               69: 'ObjectProperty', 90: 'StructProperty', 4: 'ArrayProperty',
               48: 'FloatProperty', 40: 'EnumProperty', 92: 'TextProperty',
               19: 'ByteProperty', 61: 'NameProperty', 87: 'SoftObjectPath'}

# For each name index, try to find it followed by zero and a known type
for name_idx, name_str in [(41, 'ErrorMsg'), (42, 'ErrorType'), (8, 'bHasCompilerMessage')]:
    for type_idx, type_name in known_types.items():
        pattern = struct.pack('<IIII', name_idx, 0, type_idx, 0)
        pos = 0
        while True:
            idx = data.find(pattern, pos)
            if idx < 0:
                break
            off = idx + 16
            size = struct.unpack_from('<i', data, off)[0] if off + 4 <= len(data) else -1
            print(f"  [{idx}] {name_str} as {type_name}, Size={size}")
            # dump a few more bytes
            for o in range(off, min(off + 24, len(data)), 4):
                v = struct.unpack_from('<I', data, o)[0]
                hex_str = ' '.join(f'{b:02X}' for b in data[o:o+4])
                print(f"    [{o}] {hex_str} = {v}")
            pos = idx + 1
