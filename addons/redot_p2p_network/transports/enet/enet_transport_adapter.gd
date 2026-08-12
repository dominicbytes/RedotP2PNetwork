class_name RedotP2PEnetTransportAdapter
extends RedotP2PTransportAdapter

var _peer: ENetMultiplayerPeer = null
var _authority: bool = false
var _signals_connected: bool = false
var _disconnect_reasons: Dictionary = {}
var _inside_transport_process: bool = false
var _stop_pending: bool = false
var _pending_stop_reason: String = RedotP2PStatusCodes.CONNECTION_CLOSED


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(_state != State.STOPPED)


func get_capabilities() -> RedotP2PTransportCapabilities:
	var capabilities: RedotP2PTransportCapabilities = RedotP2PTransportCapabilities.new()
	capabilities.transport_name = "enet"
	capabilities.available = not OS.has_feature("web")
	capabilities.supports_host = capabilities.available
	capabilities.supports_client = capabilities.available
	capabilities.supports_reliable = capabilities.available
	capabilities.supports_unreliable = capabilities.available
	capabilities.supports_ordered_unreliable = capabilities.available
	capabilities.supports_channels = capabilities.available
	capabilities.supports_web = false
	capabilities.exposes_trusted_peer_address = capabilities.available
	capabilities.reason_code = RedotP2PStatusCodes.OK if capabilities.available else RedotP2PStatusCodes.TRANSPORT_UNAVAILABLE
	return capabilities


func host(bind_address: String, port: int, max_peers: int) -> Error:
	if not get_capabilities().available:
		_set_state(State.FAILED, RedotP2PStatusCodes.TRANSPORT_UNAVAILABLE)
		return ERR_UNAVAILABLE
	if _state != State.STOPPED:
		return ERR_ALREADY_IN_USE
	if not _is_valid_port(port) or max_peers < 1 or max_peers > 4095:
		return ERR_INVALID_PARAMETER
	set_process(true)
	_set_state(State.STARTING, RedotP2PStatusCodes.OK)
	_peer = ENetMultiplayerPeer.new()
	if not bind_address.is_empty() and bind_address != "*":
		_peer.set_bind_ip(bind_address)
	var create_error: Error = _peer.create_server(port, max_peers, _limits.max_channels)
	if create_error != OK:
		_peer = null
		set_process(false)
		_set_state(State.FAILED, RedotP2PStatusCodes.TRANSPORT_FAILURE)
		transport_error.emit(RedotP2PStatusCodes.TRANSPORT_FAILURE)
		return create_error
	_authority = true
	_attach_peer()
	_set_state(State.LISTENING, RedotP2PStatusCodes.OK)
	return OK


func join(address: String, port: int) -> Error:
	if not get_capabilities().available:
		_set_state(State.FAILED, RedotP2PStatusCodes.TRANSPORT_UNAVAILABLE)
		return ERR_UNAVAILABLE
	if _state != State.STOPPED:
		return ERR_ALREADY_IN_USE
	if address.is_empty() or not _is_valid_port(port):
		return ERR_INVALID_PARAMETER
	set_process(true)
	_set_state(State.STARTING, RedotP2PStatusCodes.OK)
	_peer = ENetMultiplayerPeer.new()
	var create_error: Error = _peer.create_client(address, port, _limits.max_channels)
	if create_error != OK:
		_peer = null
		set_process(false)
		_set_state(State.FAILED, RedotP2PStatusCodes.CONNECTION_FAILED)
		transport_error.emit(RedotP2PStatusCodes.CONNECTION_FAILED)
		return create_error
	_authority = false
	_attach_peer()
	_set_state(State.CONNECTING, RedotP2PStatusCodes.OK)
	return OK


func send_packet(peer_id: int, packet: PackedByteArray, channel: int, delivery: int) -> Error:
	if _peer == null or _state == State.STOPPED or _state == State.FAILED:
		return ERR_UNCONFIGURED
	if peer_id < 0 or packet.is_empty() or packet.size() > _limits.max_frame_bytes:
		return ERR_INVALID_PARAMETER
	if channel < 0 or channel >= _limits.max_channels:
		return ERR_INVALID_PARAMETER
	var native_mode: int = _to_native_delivery(delivery)
	if native_mode < 0:
		return ERR_INVALID_PARAMETER
	_peer.set_target_peer(peer_id)
	_peer.set_transfer_channel(channel)
	_peer.set_transfer_mode(native_mode as MultiplayerPeer.TransferMode)
	return _peer.put_packet(packet)


func disconnect_peer(peer_id: int, reason_code: String = RedotP2PStatusCodes.CONNECTION_CLOSED) -> Error:
	if _peer == null or peer_id <= 0:
		return ERR_INVALID_PARAMETER
	if not _authority and peer_id != 1:
		return ERR_UNAUTHORIZED
	_disconnect_reasons[peer_id] = reason_code
	_peer.disconnect_peer(peer_id, true)
	return OK


func get_observed_address(peer_id: int) -> String:
	if _peer == null or not _authority or peer_id <= 1:
		return ""
	var packet_peer: Object = _peer.get_peer(peer_id)
	if packet_peer == null or not packet_peer.has_method("get_remote_address"):
		return ""
	var address_value: Variant = packet_peer.call("get_remote_address")
	if address_value is String:
		return address_value as String
	return ""


func get_local_peer_id() -> int:
	if _peer == null:
		return 0
	var local_peer_id: int = _peer.get_unique_id()
	return local_peer_id if local_peer_id > 0 else 0


func is_authority() -> bool:
	return _authority


func stop(reason_code: String = RedotP2PStatusCodes.CONNECTION_CLOSED) -> void:
	if _state == State.STOPPED:
		return
	if _inside_transport_process:
		_stop_pending = true
		_pending_stop_reason = reason_code
		_set_state(State.STOPPING, reason_code)
		return
	_stop_now(reason_code)


func _stop_now(reason_code: String) -> void:
	_set_state(State.STOPPING, reason_code)
	if _peer != null:
		_peer.close()
	_peer = null
	set_process(false)
	_authority = false
	_signals_connected = false
	_disconnect_reasons.clear()
	_stop_pending = false
	_pending_stop_reason = RedotP2PStatusCodes.CONNECTION_CLOSED
	_set_state(State.STOPPED, reason_code)


func _process(_delta: float) -> void:
	if _peer == null:
		return
	_inside_transport_process = true
	_peer.poll()
	_update_client_connection_state()
	if _stop_pending:
		_inside_transport_process = false
		_apply_pending_stop()
		return
	var packet_count: int = 0
	var byte_count: int = 0
	while _peer.get_available_packet_count() > 0:
		if packet_count >= _limits.max_packets_per_tick or byte_count >= _limits.max_bytes_per_tick:
			break
		var sender_id: int = _peer.get_packet_peer()
		var packet_channel: int = _peer.get_packet_channel()
		var packet_delivery: int = _from_native_delivery(_peer.get_packet_mode())
		var packet: PackedByteArray = _peer.get_packet()
		packet_count += 1
		byte_count += packet.size()
		if packet.is_empty() or packet.size() > _limits.max_frame_bytes:
			transport_error.emit(RedotP2PStatusCodes.FRAME_TOO_LARGE)
			if sender_id > 0:
				disconnect_peer(sender_id, RedotP2PStatusCodes.FRAME_TOO_LARGE)
			continue
		if packet_channel < 0 or packet_channel >= _limits.max_channels or packet_delivery < 0:
			transport_error.emit(RedotP2PStatusCodes.MESSAGE_CHANNEL_INVALID)
			continue
		packet_received.emit(sender_id, packet, packet_channel, packet_delivery)
		if _stop_pending:
			break
	_inside_transport_process = false
	_apply_pending_stop()


func _apply_pending_stop() -> void:
	if not _stop_pending:
		return
	var reason_code: String = _pending_stop_reason
	_stop_pending = false
	_stop_now(reason_code)


func _attach_peer() -> void:
	_connect_peer_signals()


func _connect_peer_signals() -> void:
	if _signals_connected or _peer == null:
		return
	_peer.peer_connected.connect(_on_peer_connected)
	_peer.peer_disconnected.connect(_on_peer_disconnected)
	_signals_connected = true


func _on_peer_connected(peer_id: int) -> void:
	peer_connected.emit(peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	var reason_code: String = str(_disconnect_reasons.get(peer_id, RedotP2PStatusCodes.CONNECTION_CLOSED))
	_disconnect_reasons.erase(peer_id)
	if not _authority and peer_id == 1:
		reason_code = RedotP2PStatusCodes.AUTHORITY_LOST
	peer_disconnected.emit(peer_id, reason_code)
	if not _authority and peer_id == 1:
		stop(reason_code)


func _update_client_connection_state() -> void:
	if _peer == null or _authority:
		return
	var connection_status: int = _peer.get_connection_status()
	if _state == State.CONNECTING:
		if connection_status == MultiplayerPeer.CONNECTION_CONNECTED:
			_set_state(State.CONNECTED, RedotP2PStatusCodes.OK)
		elif connection_status == MultiplayerPeer.CONNECTION_DISCONNECTED:
			_set_state(State.FAILED, RedotP2PStatusCodes.CONNECTION_FAILED)
			transport_error.emit(RedotP2PStatusCodes.CONNECTION_FAILED)
	elif _state == State.CONNECTED and connection_status == MultiplayerPeer.CONNECTION_DISCONNECTED:
		peer_disconnected.emit(1, RedotP2PStatusCodes.AUTHORITY_LOST)
		stop(RedotP2PStatusCodes.AUTHORITY_LOST)


func _is_valid_port(port: int) -> bool:
	return port >= 1 and port <= 65_535


func _to_native_delivery(delivery: int) -> int:
	match delivery:
		Delivery.UNRELIABLE:
			return MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
		Delivery.UNRELIABLE_ORDERED:
			return MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED
		Delivery.RELIABLE:
			return MultiplayerPeer.TRANSFER_MODE_RELIABLE
		_:
			return -1


func _from_native_delivery(delivery: int) -> int:
	match delivery:
		MultiplayerPeer.TRANSFER_MODE_UNRELIABLE:
			return Delivery.UNRELIABLE
		MultiplayerPeer.TRANSFER_MODE_UNRELIABLE_ORDERED:
			return Delivery.UNRELIABLE_ORDERED
		MultiplayerPeer.TRANSFER_MODE_RELIABLE:
			return Delivery.RELIABLE
		_:
			return -1
