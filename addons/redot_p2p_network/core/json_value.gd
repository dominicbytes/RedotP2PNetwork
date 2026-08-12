class_name RedotP2PJsonValue
extends RefCounted

const MAX_DEPTH: int = 4
const MAX_COLLECTION_ITEMS: int = 128
const MAX_STRING_BYTES: int = 1024


static func is_safe(value: Variant, depth: int = 0) -> bool:
	if depth > MAX_DEPTH:
		return false
	if value == null or value is bool or value is int:
		return true
	if value is float:
		return is_finite(float(value))
	if value is String:
		return (value as String).to_utf8_buffer().size() <= MAX_STRING_BYTES
	if value is Array:
		var values: Array = value as Array
		if values.size() > MAX_COLLECTION_ITEMS:
			return false
		for child: Variant in values:
			if not is_safe(child, depth + 1):
				return false
		return true
	if value is Dictionary:
		var values: Dictionary = value as Dictionary
		if values.size() > MAX_COLLECTION_ITEMS:
			return false
		for key: Variant in values.keys():
			if not key is String or not _valid_key(key as String):
				return false
			if not is_safe(values[key], depth + 1):
				return false
		return true
	return false


static func _valid_key(key: String) -> bool:
	var bytes: PackedByteArray = key.to_utf8_buffer()
	if bytes.is_empty() or bytes.size() > 64:
		return false
	for byte_value: int in bytes:
		var allowed: bool = (
			(byte_value >= 0x61 and byte_value <= 0x7A)
			or (byte_value >= 0x30 and byte_value <= 0x39)
			or byte_value in [0x2D, 0x2E, 0x3A, 0x5F]
		)
		if not allowed:
			return false
	return true
