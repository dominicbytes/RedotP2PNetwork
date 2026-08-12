class_name RedotP2PTransportCapabilities
extends RefCounted

var transport_name: String = "unavailable"
var available: bool = false
var supports_host: bool = false
var supports_client: bool = false
var supports_reliable: bool = false
var supports_unreliable: bool = false
var supports_ordered_unreliable: bool = false
var supports_channels: bool = false
var supports_web: bool = false
var exposes_trusted_peer_address: bool = false
var reason_code: String = RedotP2PStatusCodes.TRANSPORT_UNAVAILABLE


func as_dictionary() -> Dictionary:
	return {
		"transport_name": transport_name,
		"available": available,
		"supports_host": supports_host,
		"supports_client": supports_client,
		"supports_reliable": supports_reliable,
		"supports_unreliable": supports_unreliable,
		"supports_ordered_unreliable": supports_ordered_unreliable,
		"supports_channels": supports_channels,
		"supports_web": supports_web,
		"exposes_trusted_peer_address": exposes_trusted_peer_address,
		"reason_code": reason_code,
	}
