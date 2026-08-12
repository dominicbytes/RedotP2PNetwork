class_name RedotP2PFakeTransportAdapter
extends RedotP2PTransportAdapter

var authority: bool = true
var local_peer_id: int = 1
var sent_packets: Array[Dictionary] = []
var disconnected_peers: Array[Dictionary] = []
var observed_addresses: Dictionary = {}
var peer_identities: Dictionary = {}


func get_capabilities() -> RedotP2PTransportCapabilities:
	var capabilities: RedotP2PTransportCapabilities = RedotP2PTransportCapabilities.new()
	capabilities.transport_name = "fake"
	capabilities.available = true
	capabilities.supports_host = true
	capabilities.supports_client = true
	capabilities.supports_reliable = true
	capabilities.supports_unreliable = true
	capabilities.supports_ordered_unreliable = true
	capabilities.supports_channels = true
	capabilities.reason_code = RedotP2PStatusCodes.OK
	return capabilities


func host(_bind_address: String, _port: int, _max_peers: int) -> Error:
	authority = true
	local_peer_id = 1
	_set_state(State.LISTENING, RedotP2PStatusCodes.OK)
	return OK


func join(_address: String, _port: int) -> Error:
	authority = false
	local_peer_id = 2
	_set_state(State.CONNECTED, RedotP2PStatusCodes.OK)
	return OK


func send_packet(peer_id: int, packet: PackedByteArray, channel: int, delivery: int) -> Error:
	sent_packets.append({
		"peer_id": peer_id,
		"packet": packet.duplicate(),
		"channel": channel,
		"delivery": delivery,
	})
	return OK


func disconnect_peer(peer_id: int, reason_code: String = RedotP2PStatusCodes.CONNECTION_CLOSED) -> Error:
	disconnected_peers.append({"peer_id": peer_id, "reason_code": reason_code})
	peer_disconnected.emit(peer_id, reason_code)
	return OK


func get_local_peer_id() -> int:
	return local_peer_id


func get_observed_address(peer_id: int) -> String:
	return str(observed_addresses.get(peer_id, ""))


func get_peer_identity(peer_id: int) -> String:
	return str(peer_identities.get(peer_id, ""))


func is_authority() -> bool:
	return authority


func inject_packet(peer_id: int, packet: PackedByteArray, channel: int, delivery: int) -> void:
	packet_received.emit(peer_id, packet, channel, delivery)


func inject_peer_connected(peer_id: int) -> void:
	peer_connected.emit(peer_id)
