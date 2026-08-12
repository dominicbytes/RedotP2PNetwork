class_name RedotP2PReplicatedEntityDefinition
extends RefCounted

var entity_id: String = ""
var collect_state: Callable = Callable()
var apply_state: Callable = Callable()
var validate_intent: Callable = Callable()
var apply_intent: Callable = Callable()
var despawn_handler: Callable = Callable()
var max_state_bytes: int = 4096
var max_intent_bytes: int = 2048
var intent_rate: float = 16.0
var intent_burst: int = 32


func validate() -> Error:
	if not _valid_entity_id(entity_id) or not collect_state.is_valid() or not apply_state.is_valid():
		return ERR_INVALID_PARAMETER
	if validate_intent.is_valid() != apply_intent.is_valid():
		return ERR_INVALID_PARAMETER
	if max_state_bytes < 2 or max_state_bytes > 16_384 or max_intent_bytes < 2 or max_intent_bytes > 8192:
		return ERR_INVALID_PARAMETER
	if intent_rate <= 0.0 or intent_rate > 128.0 or intent_burst < 1 or intent_burst > 256:
		return ERR_INVALID_PARAMETER
	return OK


static func _valid_entity_id(value: String) -> bool:
	var bytes: PackedByteArray = value.to_utf8_buffer()
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
