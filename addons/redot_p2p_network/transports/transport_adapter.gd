class_name RedotP2PTransportAdapter
extends Node

signal state_changed(previous_state: int, current_state: int, reason_code: String)
signal peer_connected(peer_id: int)
signal peer_disconnected(peer_id: int, reason_code: String)
signal packet_received(peer_id: int, packet: PackedByteArray, channel: int, delivery: int)
signal transport_error(reason_code: String)

enum State {
	STOPPED,
	STARTING,
	LISTENING,
	CONNECTING,
	CONNECTED,
	STOPPING,
	FAILED,
}

enum Delivery {
	UNRELIABLE,
	UNRELIABLE_ORDERED,
	RELIABLE,
}

var _state: int = State.STOPPED
var _limits: RedotP2PProtocolLimits = RedotP2PProtocolLimits.new()


func configure(limits: RedotP2PProtocolLimits) -> Error:
	if _state != State.STOPPED:
		return ERR_ALREADY_IN_USE
	if limits == null or limits.validate() != OK:
		return ERR_INVALID_PARAMETER
	_limits = limits.duplicate()
	return OK


func get_state() -> int:
	return _state


func get_capabilities() -> RedotP2PTransportCapabilities:
	return RedotP2PTransportCapabilities.new()


func host(_bind_address: String, _port: int, _max_peers: int) -> Error:
	_set_state(State.FAILED, RedotP2PStatusCodes.TRANSPORT_UNAVAILABLE)
	return ERR_UNAVAILABLE


func join(_address: String, _port: int) -> Error:
	_set_state(State.FAILED, RedotP2PStatusCodes.TRANSPORT_UNAVAILABLE)
	return ERR_UNAVAILABLE


func send_packet(_peer_id: int, _packet: PackedByteArray, _channel: int, _delivery: int) -> Error:
	return ERR_UNAVAILABLE


func disconnect_peer(_peer_id: int, _reason_code: String = RedotP2PStatusCodes.CONNECTION_CLOSED) -> Error:
	return ERR_UNAVAILABLE


func get_observed_address(_peer_id: int) -> String:
	return ""


func get_peer_identity(_peer_id: int) -> String:
	return ""


func get_local_peer_id() -> int:
	return 0


func is_authority() -> bool:
	return false


func stop(reason_code: String = RedotP2PStatusCodes.CONNECTION_CLOSED) -> void:
	_set_state(State.STOPPED, reason_code)


func _set_state(next_state: int, reason_code: String) -> void:
	if _state == next_state:
		return
	var previous_state: int = _state
	_state = next_state
	state_changed.emit(previous_state, _state, reason_code)
