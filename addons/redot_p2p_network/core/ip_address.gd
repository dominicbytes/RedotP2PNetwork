class_name RedotP2PIPAddress
extends RefCounted


static func normalize(address: String) -> String:
	var value: String = address.strip_edges().to_lower()
	if value.begins_with("[") and value.ends_with("]"):
		value = value.substr(1, value.length() - 2)
	if value.contains("%"):
		return ""
	if value.contains(":"):
		var groups: Array[int] = _parse_ipv6_groups(value)
		if groups.size() != 8:
			return ""
		if groups[0] == 0 and groups[1] == 0 and groups[2] == 0 and groups[3] == 0 and groups[4] == 0 and groups[5] == 0xFFFF:
			return "%d.%d.%d.%d" % [groups[6] >> 8, groups[6] & 0xFF, groups[7] >> 8, groups[7] & 0xFF]
		var parts: PackedStringArray = PackedStringArray()
		for group: int in groups:
			parts.append("%04x" % group)
		return ":".join(parts)
	var ipv4: PackedByteArray = _parse_ipv4(value)
	if ipv4.size() != 4:
		return ""
	return "%d.%d.%d.%d" % [ipv4[0], ipv4[1], ipv4[2], ipv4[3]]


static func to_bytes(address: String) -> PackedByteArray:
	var normalized: String = normalize(address)
	if normalized.is_empty():
		return PackedByteArray()
	if not normalized.contains(":"):
		return _parse_ipv4(normalized)
	var groups: Array[int] = _parse_ipv6_groups(normalized)
	var output: PackedByteArray = PackedByteArray()
	output.resize(16)
	for index: int in groups.size():
		output[index * 2] = (groups[index] >> 8) & 0xFF
		output[index * 2 + 1] = groups[index] & 0xFF
	return output


static func network_bytes(address: String, prefix_length: int) -> PackedByteArray:
	var bytes: PackedByteArray = to_bytes(address)
	if bytes.is_empty() or prefix_length < 0 or prefix_length > bytes.size() * 8:
		return PackedByteArray()
	var result: PackedByteArray = bytes.duplicate()
	for bit_index: int in range(prefix_length, result.size() * 8):
		var byte_index: int = bit_index / 8
		var bit_in_byte: int = 7 - (bit_index % 8)
		result[byte_index] &= ~(1 << bit_in_byte)
	return result


static func matches_network(address: String, expected_network: PackedByteArray, prefix_length: int) -> bool:
	var bytes: PackedByteArray = to_bytes(address)
	if bytes.size() != expected_network.size() or bytes.is_empty():
		return false
	if prefix_length < 0 or prefix_length > bytes.size() * 8:
		return false
	var full_bytes: int = prefix_length / 8
	for index: int in full_bytes:
		if bytes[index] != expected_network[index]:
			return false
	var remaining_bits: int = prefix_length % 8
	if remaining_bits == 0:
		return true
	var mask: int = (0xFF << (8 - remaining_bits)) & 0xFF
	return (bytes[full_bytes] & mask) == (expected_network[full_bytes] & mask)


static func _parse_ipv4(value: String) -> PackedByteArray:
	var parts: PackedStringArray = value.split(".", true)
	if parts.size() != 4:
		return PackedByteArray()
	var output: PackedByteArray = PackedByteArray()
	for part: String in parts:
		if part.is_empty() or part.length() > 3 or not _is_decimal(part):
			return PackedByteArray()
		var number: int = int(part)
		if number < 0 or number > 255:
			return PackedByteArray()
		output.append(number)
	return output


static func _parse_ipv6_groups(value: String) -> Array[int]:
	var expanded_value: String = value
	if expanded_value.contains("."):
		var last_colon: int = expanded_value.rfind(":")
		if last_colon < 0:
			return []
		var ipv4: PackedByteArray = _parse_ipv4(expanded_value.substr(last_colon + 1))
		if ipv4.size() != 4:
			return []
		expanded_value = "%s:%x:%x" % [
			expanded_value.substr(0, last_colon),
			(ipv4[0] << 8) | ipv4[1],
			(ipv4[2] << 8) | ipv4[3],
		]
	if expanded_value.count("::") > 1:
		return []
	var has_gap: bool = expanded_value.contains("::")
	var sides: PackedStringArray = expanded_value.split("::", true, 1)
	var left: Array[int] = _parse_ipv6_side(sides[0])
	if left.is_empty() and not sides[0].is_empty():
		return []
	var right: Array[int] = []
	if sides.size() == 2:
		right = _parse_ipv6_side(sides[1])
		if right.is_empty() and not sides[1].is_empty():
			return []
	if not has_gap:
		return left if left.size() == 8 else []
	var missing: int = 8 - left.size() - right.size()
	if missing < 1:
		return []
	var groups: Array[int] = left.duplicate()
	for _index: int in missing:
		groups.append(0)
	groups.append_array(right)
	return groups if groups.size() == 8 else []


static func _parse_ipv6_side(value: String) -> Array[int]:
	var groups: Array[int] = []
	if value.is_empty():
		return groups
	for part: String in value.split(":", true):
		if part.is_empty() or part.length() > 4 or not _is_hex(part):
			return []
		groups.append(part.hex_to_int())
	return groups


static func _is_decimal(value: String) -> bool:
	for index: int in value.length():
		var codepoint: int = value.unicode_at(index)
		if codepoint < 0x30 or codepoint > 0x39:
			return false
	return true


static func _is_hex(value: String) -> bool:
	for index: int in value.length():
		var codepoint: int = value.unicode_at(index)
		var digit: bool = codepoint >= 0x30 and codepoint <= 0x39
		var lowercase: bool = codepoint >= 0x61 and codepoint <= 0x66
		if not digit and not lowercase:
			return false
	return true
