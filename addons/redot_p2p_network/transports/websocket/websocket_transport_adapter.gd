class_name RedotP2PWebSocketTransportAdapter
extends RedotP2PTransportAdapter

const MAX_CONFIGURED_PEERS: int = 4095

var _peer: WebSocketMultiplayerPeer = null
var _authority: bool = false
var _signals_connected: bool = false
var _allow_plaintext_loopback: bool = false
var _server_tls_options: TLSOptions = null
var _client_tls_options: TLSOptions = null
var _maximum_peers: int = 0
var _connected_peers: Dictionary = {}
var _disconnect_reasons: Dictionary = {}
var _inside_transport_process: bool = false
var _stop_pending: bool = false
var _pending_stop_reason: String = RedotP2PStatusCodes.CONNECTION_CLOSED


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(_state != State.STOPPED)


func enable_plaintext_loopback_development(enabled: bool) -> Error:
	if _state != State.STOPPED:
		return ERR_ALREADY_IN_USE
	_allow_plaintext_loopback = enabled
	return OK


func set_server_tls_options(options: TLSOptions) -> Error:
	if _state != State.STOPPED:
		return ERR_ALREADY_IN_USE
	_server_tls_options = options
	return OK


func set_client_tls_options(options: TLSOptions) -> Error:
	if _state != State.STOPPED:
		return ERR_ALREADY_IN_USE
	_client_tls_options = options
	return OK


func get_capabilities() -> RedotP2PTransportCapabilities:
	var capabilities: RedotP2PTransportCapabilities = RedotP2PTransportCapabilities.new()
	capabilities.transport_name = "websocket"
	capabilities.available = ClassDB.class_exists("WebSocketMultiplayerPeer")
	capabilities.supports_host = capabilities.available
	capabilities.supports_client = capabilities.available
	capabilities.supports_reliable = capabilities.available
	capabilities.supports_unreliable = false
	capabilities.supports_ordered_unreliable = false
	capabilities.supports_channels = capabilities.available
	capabilities.supports_web = capabilities.available
	capabilities.exposes_trusted_peer_address = capabilities.available
	capabilities.reason_code = RedotP2PStatusCodes.OK if capabilities.available else RedotP2PStatusCodes.TRANSPORT_UNAVAILABLE
	return capabilities


func host(bind_address: String, port: int, max_peers: int) -> Error:
	if not get_capabilities().available:
		return _fail_start(ERR_UNAVAILABLE, RedotP2PStatusCodes.TRANSPORT_UNAVAILABLE)
	if _state != State.STOPPED:
		return ERR_ALREADY_IN_USE
	if not _is_valid_port(port) or max_peers < 1 or max_peers > MAX_CONFIGURED_PEERS:
		return ERR_INVALID_PARAMETER
	var normalized_bind: String = bind_address.strip_edges()
	if normalized_bind.is_empty():
		normalized_bind = "*"
	if _server_tls_options == null and (not _allow_plaintext_loopback or not _is_loopback_host(normalized_bind)):
		return _fail_start(ERR_UNAUTHORIZED, RedotP2PStatusCodes.PLAINTEXT_NOT_ALLOWED)
	set_process(true)
	_set_state(State.STARTING, RedotP2PStatusCodes.OK)
	_peer = WebSocketMultiplayerPeer.new()
	_configure_peer_bounds()
	var create_error: Error = _peer.create_server(port, normalized_bind, _server_tls_options)
	if create_error != OK:
		_peer = null
		return _fail_start(create_error, RedotP2PStatusCodes.TRANSPORT_FAILURE)
	_authority = true
	_maximum_peers = max_peers
	_connect_peer_signals()
	_set_state(State.LISTENING, RedotP2PStatusCodes.OK)
	return OK


func join(address: String, port: int) -> Error:
	if not get_capabilities().available:
		return _fail_start(ERR_UNAVAILABLE, RedotP2PStatusCodes.TRANSPORT_UNAVAILABLE)
	if _state != State.STOPPED:
		return ERR_ALREADY_IN_USE
	var url: String = _build_client_url(address, port)
	if url.is_empty():
		return ERR_INVALID_PARAMETER
	if url.to_lower().begins_with("ws://"):
		var host_name: String = _extract_url_host(url)
		if not _allow_plaintext_loopback or not _is_loopback_host(host_name):
			return _fail_start(ERR_UNAUTHORIZED, RedotP2PStatusCodes.PLAINTEXT_NOT_ALLOWED)
	set_process(true)
	_set_state(State.STARTING, RedotP2PStatusCodes.OK)
	_peer = WebSocketMultiplayerPeer.new()
	_configure_peer_bounds()
	var create_error: Error = _peer.create_client(url, _client_tls_options)
	if create_error != OK:
		_peer = null
		return _fail_start(create_error, RedotP2PStatusCodes.CONNECTION_FAILED)
	_authority = false
	_connect_peer_signals()
	_set_state(State.CONNECTING, RedotP2PStatusCodes.OK)
	return OK


func send_packet(peer_id: int, packet: PackedByteArray, channel: int, delivery: int) -> Error:
	if _peer == null or _state in [State.STOPPED, State.STOPPING, State.FAILED]:
		return ERR_UNCONFIGURED
	if peer_id < 0 or packet.is_empty() or packet.size() > _limits.max_frame_bytes:
		return ERR_INVALID_PARAMETER
	if channel < 0 or channel >= _limits.max_channels:
		return ERR_INVALID_PARAMETER
	if delivery != Delivery.RELIABLE:
		return ERR_UNAVAILABLE
	_peer.set_target_peer(peer_id)
	_peer.set_transfer_channel(0)
	_peer.set_transfer_mode(MultiplayerPeer.TRANSFER_MODE_RELIABLE)
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
	var socket_peer: WebSocketPeer = _peer.get_peer(peer_id)
	if socket_peer == null:
		return ""
	return socket_peer.get_connected_host()


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
	_maximum_peers = 0
	_connected_peers.clear()
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
		var _native_packet_channel: int = _peer.get_packet_channel()
		var packet_delivery: int = _from_native_delivery(_peer.get_packet_mode())
		var packet: PackedByteArray = _peer.get_packet()
		var packet_channel: int = packet.decode_u16(6) if packet.size() >= 8 else 0
		packet_count += 1
		byte_count += packet.size()
		if packet.is_empty() or packet.size() > _limits.max_frame_bytes:
			transport_error.emit(RedotP2PStatusCodes.FRAME_TOO_LARGE)
			if sender_id > 0:
				disconnect_peer(sender_id, RedotP2PStatusCodes.FRAME_TOO_LARGE)
			continue
		if packet_channel < 0 or packet_channel >= _limits.max_channels or packet_delivery != Delivery.RELIABLE:
			transport_error.emit(RedotP2PStatusCodes.MESSAGE_DELIVERY_INVALID)
			continue
		packet_received.emit(sender_id, packet, packet_channel, packet_delivery)
		if _stop_pending:
			break
	_inside_transport_process = false
	_apply_pending_stop()


func _configure_peer_bounds() -> void:
	if _peer == null:
		return
	_peer.set_inbound_buffer_size(_limits.max_bytes_per_tick)
	_peer.set_outbound_buffer_size(_limits.max_bytes_per_tick)
	_peer.set_max_queued_packets(mini(1024, _limits.max_packets_per_tick * 4))


func _connect_peer_signals() -> void:
	if _signals_connected or _peer == null:
		return
	_peer.peer_connected.connect(_on_peer_connected)
	_peer.peer_disconnected.connect(_on_peer_disconnected)
	_signals_connected = true


func _on_peer_connected(peer_id: int) -> void:
	if _authority and _connected_peers.size() >= _maximum_peers:
		disconnect_peer(peer_id, RedotP2PStatusCodes.CAPACITY_EXCEEDED)
		return
	_connected_peers[peer_id] = true
	peer_connected.emit(peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	_connected_peers.erase(peer_id)
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


func _apply_pending_stop() -> void:
	if not _stop_pending:
		return
	var reason_code: String = _pending_stop_reason
	_stop_pending = false
	_stop_now(reason_code)


func _fail_start(error_code: Error, reason_code: String) -> Error:
	set_process(false)
	_set_state(State.FAILED, reason_code)
	transport_error.emit(reason_code)
	return error_code


func _build_client_url(address: String, port: int) -> String:
	var normalized: String = address.strip_edges()
	var lowered: String = normalized.to_lower()
	if lowered.begins_with("ws://") or lowered.begins_with("wss://"):
		return normalized if not _extract_url_host(normalized).is_empty() else ""
	if normalized.is_empty() or not _is_valid_port(port) or normalized.contains("/") or normalized.contains("@"):
		return ""
	var host_part: String = "[%s]" % normalized if normalized.contains(":") and not normalized.begins_with("[") else normalized
	var scheme: String = "wss" if _client_tls_options != null else "ws"
	return "%s://%s:%d" % [scheme, host_part, port]


func _extract_url_host(url: String) -> String:
	var lowered: String = url.to_lower()
	var scheme_length: int = 0
	if lowered.begins_with("ws://"):
		scheme_length = 5
	elif lowered.begins_with("wss://"):
		scheme_length = 6
	else:
		return ""
	var authority_part: String = url.substr(scheme_length).split("/", true, 1)[0]
	if authority_part.is_empty() or authority_part.contains("@"):
		return ""
	if authority_part.begins_with("["):
		var closing_bracket: int = authority_part.find("]")
		return "" if closing_bracket <= 1 else authority_part.substr(1, closing_bracket - 1)
	return authority_part.split(":", true, 1)[0]


func _is_loopback_host(host_name: String) -> bool:
	var normalized: String = host_name.strip_edges().to_lower()
	return normalized in ["127.0.0.1", "::1", "[::1]", "localhost"]


func _is_valid_port(port: int) -> bool:
	return port >= 1 and port <= 65_535


func _from_native_delivery(delivery: int) -> int:
	return Delivery.RELIABLE if delivery == MultiplayerPeer.TRANSFER_MODE_RELIABLE else -1
