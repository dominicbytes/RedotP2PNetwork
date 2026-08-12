class_name RedotP2PProtocolLimits
extends RefCounted

const HARD_MAX_FRAME_BYTES: int = 262_144
const HARD_MAX_PAYLOAD_BYTES: int = 65_536
const HARD_MAX_MESSAGE_TYPE_BYTES: int = 64
const HARD_MAX_CHANNELS: int = 16
const HARD_MAX_PACKETS_PER_TICK: int = 256
const HARD_MAX_BYTES_PER_TICK: int = 1_048_576

var max_frame_bytes: int = 65_536
var max_payload_bytes: int = 60_000
var max_message_type_bytes: int = 64
var max_channels: int = 8
var max_packets_per_tick: int = 64
var max_bytes_per_tick: int = 262_144
var max_protocol_violations: int = 4


func validate() -> Error:
	if max_frame_bytes < 18 or max_frame_bytes > HARD_MAX_FRAME_BYTES:
		return ERR_INVALID_PARAMETER
	if max_payload_bytes < 0 or max_payload_bytes > HARD_MAX_PAYLOAD_BYTES:
		return ERR_INVALID_PARAMETER
	if max_payload_bytes > max_frame_bytes - 18:
		return ERR_INVALID_PARAMETER
	if max_message_type_bytes < 1 or max_message_type_bytes > HARD_MAX_MESSAGE_TYPE_BYTES:
		return ERR_INVALID_PARAMETER
	if max_channels < 1 or max_channels > HARD_MAX_CHANNELS:
		return ERR_INVALID_PARAMETER
	if max_packets_per_tick < 1 or max_packets_per_tick > HARD_MAX_PACKETS_PER_TICK:
		return ERR_INVALID_PARAMETER
	if max_bytes_per_tick < max_frame_bytes or max_bytes_per_tick > HARD_MAX_BYTES_PER_TICK:
		return ERR_INVALID_PARAMETER
	if max_protocol_violations < 1 or max_protocol_violations > 32:
		return ERR_INVALID_PARAMETER
	return OK


func duplicate() -> RedotP2PProtocolLimits:
	var copy: RedotP2PProtocolLimits = RedotP2PProtocolLimits.new()
	copy.max_frame_bytes = max_frame_bytes
	copy.max_payload_bytes = max_payload_bytes
	copy.max_message_type_bytes = max_message_type_bytes
	copy.max_channels = max_channels
	copy.max_packets_per_tick = max_packets_per_tick
	copy.max_bytes_per_tick = max_bytes_per_tick
	copy.max_protocol_violations = max_protocol_violations
	return copy
