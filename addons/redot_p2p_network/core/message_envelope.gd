class_name RedotP2PMessageEnvelope
extends RefCounted

const MAGIC_0: int = 0x52
const MAGIC_1: int = 0x50
const MAGIC_2: int = 0x32
const MAGIC_3: int = 0x50
const PROTOCOL_VERSION: int = 1
const HEADER_BYTES: int = 18
const DELIVERY_MASK: int = 0x03
const RESERVED_FLAGS_MASK: int = 0xFC

var message_type: String = ""
var payload: PackedByteArray = PackedByteArray()
var channel: int = 0
var sequence: int = 0
var delivery: int = RedotP2PTransportAdapter.Delivery.RELIABLE


func encode(limits: RedotP2PProtocolLimits) -> PackedByteArray:
	if limits == null or limits.validate() != OK:
		return PackedByteArray()
	var type_bytes: PackedByteArray = message_type.to_utf8_buffer()
	if not _is_valid_message_type(type_bytes, limits.max_message_type_bytes):
		return PackedByteArray()
	if payload.size() > limits.max_payload_bytes:
		return PackedByteArray()
	if channel < 0 or channel >= limits.max_channels:
		return PackedByteArray()
	if sequence <= 0:
		return PackedByteArray()
	if delivery < RedotP2PTransportAdapter.Delivery.UNRELIABLE or delivery > RedotP2PTransportAdapter.Delivery.RELIABLE:
		return PackedByteArray()
	var total_bytes: int = HEADER_BYTES + type_bytes.size() + payload.size()
	if total_bytes > limits.max_frame_bytes:
		return PackedByteArray()
	var frame: PackedByteArray = PackedByteArray()
	frame.resize(total_bytes)
	frame[0] = MAGIC_0
	frame[1] = MAGIC_1
	frame[2] = MAGIC_2
	frame[3] = MAGIC_3
	frame[4] = PROTOCOL_VERSION
	frame[5] = delivery & DELIVERY_MASK
	frame.encode_u16(6, channel)
	frame.encode_u32(8, sequence)
	frame.encode_u16(12, type_bytes.size())
	frame.encode_u32(14, payload.size())
	for index: int in type_bytes.size():
		frame[HEADER_BYTES + index] = type_bytes[index]
	var payload_offset: int = HEADER_BYTES + type_bytes.size()
	for index: int in payload.size():
		frame[payload_offset + index] = payload[index]
	return frame


static func decode(frame: PackedByteArray, limits: RedotP2PProtocolLimits) -> RedotP2PEnvelopeDecodeResult:
	var result: RedotP2PEnvelopeDecodeResult = RedotP2PEnvelopeDecodeResult.new()
	if limits == null or limits.validate() != OK:
		result.status_code = RedotP2PStatusCodes.INVALID_ARGUMENT
		return result
	if frame.size() < HEADER_BYTES:
		result.status_code = RedotP2PStatusCodes.FRAME_TOO_SMALL
		return result
	if frame.size() > limits.max_frame_bytes:
		result.status_code = RedotP2PStatusCodes.FRAME_TOO_LARGE
		return result
	if frame[0] != MAGIC_0 or frame[1] != MAGIC_1 or frame[2] != MAGIC_2 or frame[3] != MAGIC_3:
		result.status_code = RedotP2PStatusCodes.FRAME_MAGIC_INVALID
		return result
	if frame[4] != PROTOCOL_VERSION:
		result.status_code = RedotP2PStatusCodes.FRAME_VERSION_UNSUPPORTED
		return result
	var flags: int = frame[5]
	if (flags & RESERVED_FLAGS_MASK) != 0 or (flags & DELIVERY_MASK) > RedotP2PTransportAdapter.Delivery.RELIABLE:
		result.status_code = RedotP2PStatusCodes.FRAME_FLAGS_INVALID
		return result
	var decoded_channel: int = frame.decode_u16(6)
	var decoded_sequence: int = frame.decode_u32(8)
	var type_length: int = frame.decode_u16(12)
	var payload_length: int = frame.decode_u32(14)
	if decoded_channel < 0 or decoded_channel >= limits.max_channels or decoded_sequence <= 0:
		result.status_code = RedotP2PStatusCodes.FRAME_LENGTH_INVALID
		return result
	if type_length < 1 or type_length > limits.max_message_type_bytes:
		result.status_code = RedotP2PStatusCodes.MESSAGE_TYPE_INVALID
		return result
	if payload_length < 0 or payload_length > limits.max_payload_bytes:
		result.status_code = RedotP2PStatusCodes.PAYLOAD_TOO_LARGE
		return result
	var expected_size: int = HEADER_BYTES + type_length + payload_length
	if expected_size != frame.size():
		result.status_code = RedotP2PStatusCodes.FRAME_LENGTH_INVALID
		return result
	var type_bytes: PackedByteArray = frame.slice(HEADER_BYTES, HEADER_BYTES + type_length)
	if not _is_valid_message_type(type_bytes, limits.max_message_type_bytes):
		result.status_code = RedotP2PStatusCodes.MESSAGE_TYPE_INVALID
		return result
	var decoded: RedotP2PMessageEnvelope = RedotP2PMessageEnvelope.new()
	decoded.message_type = type_bytes.get_string_from_utf8()
	decoded.payload = frame.slice(HEADER_BYTES + type_length, expected_size)
	decoded.channel = decoded_channel
	decoded.sequence = decoded_sequence
	decoded.delivery = flags & DELIVERY_MASK
	result.status_code = RedotP2PStatusCodes.OK
	result.envelope = decoded
	return result


static func _is_valid_message_type(type_bytes: PackedByteArray, max_bytes: int) -> bool:
	if type_bytes.is_empty() or type_bytes.size() > max_bytes:
		return false
	for byte_value: int in type_bytes:
		var is_lowercase: bool = byte_value >= 0x61 and byte_value <= 0x7A
		var is_digit: bool = byte_value >= 0x30 and byte_value <= 0x39
		var is_separator: bool = byte_value == 0x2E or byte_value == 0x2D or byte_value == 0x5F
		if not is_lowercase and not is_digit and not is_separator:
			return false
	return true
