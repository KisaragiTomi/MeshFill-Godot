import struct, sys, re
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

path = r'D:\KeLuwang_PC-KeLuWang_1851\Lycoris_main\Content\BP_Test.uasset'
with open(path, 'rb') as f:
    data = f.read()

print(f"File: {path}")
print(f"Size: {len(data)} bytes\n")

# Extract all readable strings from the binary (both UTF-8 and UTF-16LE)
# UE serializes FString as: int32 length + chars (null-terminated)

print("=== Searching for FString instances in binary ===\n")

pos = 0
strings_found = []
while pos + 4 < len(data):
    slen = struct.unpack_from('<i', data, pos)[0]

    # UTF-8 FString
    if 4 < slen < 5000 and pos + 4 + slen <= len(data):
        raw = data[pos+4:pos+4+slen]
        if raw[-1:] == b'\x00':
            try:
                s = raw[:-1].decode('utf-8', errors='strict')
                if len(s) > 10 and all(c.isprintable() or c in '\n\r\t' for c in s):
                    strings_found.append((pos, s, 'utf8'))
            except:
                pass

    # UTF-16LE FString (negative length)
    if -5000 < slen < -4 and pos + 4 + (-slen)*2 <= len(data):
        actual = -slen
        raw = data[pos+4:pos+4+actual*2]
        if raw[-2:] == b'\x00\x00':
            try:
                s = raw[:-2].decode('utf-16-le', errors='strict')
                if len(s) > 10 and all(c.isprintable() or c in '\n\r\t' for c in s):
                    strings_found.append((pos, s, 'utf16'))
            except:
                pass

    pos += 1

# Print error-related strings
print("--- Error-related strings ---")
error_keywords = ['error', 'fail', 'cannot', 'unable', 'missing', 'invalid',
                  'unresolved', 'broken', 'deprecated', 'compile', 'warning']
err_strings = []
for off, s, enc in strings_found:
    sl = s.lower()
    if any(k in sl for k in error_keywords):
        err_strings.append((off, s, enc))
        print(f"  [{off}] ({enc}) {s[:300]}")

print(f"\n--- Strings near export data (offset > 4000) ---")
for off, s, enc in strings_found:
    if off > 4000:
        print(f"  [{off}] ({enc}) {s[:200]}")

print(f"\nTotal strings found: {len(strings_found)}")
print(f"Error-related strings: {len(err_strings)}")
