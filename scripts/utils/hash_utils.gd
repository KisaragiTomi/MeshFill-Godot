@tool
extends RefCounted


static func stable_u32_from_string(value: String) -> int:
	var h := 2166136261
	for i in range(value.length()):
		h = (h ^ value.unicode_at(i)) & 0xffffffff
		h = (h * 16777619) & 0xffffffff
	return h


static func stable_u31_from_string(value: String) -> int:
	var h := stable_u32_from_string(value) & 0x7fffffff
	return h if h > 0 else 1


static func stable_hex_from_string(value: String) -> String:
	return "%08x" % stable_u32_from_string(value)


## 对字节序列做 FNV-1a 32 位哈希（与 stable_u32_from_string 同算法，输入为字节而非字符）。
static func stable_u32_from_bytes(bytes: PackedByteArray) -> int:
	var h := 2166136261
	for b in bytes:
		h = (h ^ int(b)) & 0xffffffff
		h = (h * 16777619) & 0xffffffff
	return h


## 将十六进制字符串逐字符折叠为 u32（忽略非 hex 字符）。stable_hex_from_string 的逆向配套,
## 用于把 profile_hash 之类的 hex 串写回 GPU u32。原 AutoVoxelRuntimeProfileContainer._hex_to_u32。
static func u32_from_hex(hex_value: String) -> int:
	var result := 0
	for i in range(hex_value.length()):
		var c := hex_value.unicode_at(i)
		var nibble := -1
		if c >= 48 and c <= 57:
			nibble = c - 48
		elif c >= 65 and c <= 70:
			nibble = c - 65 + 10
		elif c >= 97 and c <= 102:
			nibble = c - 97 + 10
		if nibble < 0:
			continue
		result = ((result << 4) | nibble) & 0xffffffff
	return result
