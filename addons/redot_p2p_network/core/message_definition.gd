class_name RedotP2PMessageDefinition
extends RefCounted

var message_type: String = ""
var handler: Callable = Callable()
var max_payload_bytes: int = 4096
var required_channel: int = -1
var required_delivery: int = -1
var allow_from_client: bool = false
var allow_from_authority: bool = true
var per_peer_rate: float = 8.0
var per_peer_burst: int = 16
var required_capability: String = ""


func validate(limits: RedotP2PProtocolLimits) -> Error:
	if limits == null or limits.validate() != OK:
		return ERR_INVALID_PARAMETER
	if not handler.is_valid():
		return ERR_INVALID_PARAMETER
	var type_bytes: PackedByteArray = message_type.to_utf8_buffer()
	if type_bytes.is_empty() or type_bytes.size() > limits.max_message_type_bytes:
		return ERR_INVALID_PARAMETER
	if max_payload_bytes < 0 or max_payload_bytes > limits.max_payload_bytes:
		return ERR_INVALID_PARAMETER
	if required_channel < -1 or required_channel >= limits.max_channels:
		return ERR_INVALID_PARAMETER
	if required_delivery < -1 or required_delivery > RedotP2PTransportAdapter.Delivery.RELIABLE:
		return ERR_INVALID_PARAMETER
	if not allow_from_client and not allow_from_authority:
		return ERR_INVALID_PARAMETER
	if per_peer_rate <= 0.0 or per_peer_burst < 1 or per_peer_burst > 1024:
		return ERR_INVALID_PARAMETER
	return OK
