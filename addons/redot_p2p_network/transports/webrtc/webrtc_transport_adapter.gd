class_name RedotP2PWebRTCTransportAdapter
extends RedotP2PTransportAdapter

const MAX_SDP_BYTES: int = 65_536
const MAX_ICE_CANDIDATE_BYTES: int = 4096
const MAX_ICE_MEDIA_BYTES: int = 128
const MAX_CONFIGURED_PEERS: int = 4095

var _signaling: RedotP2PWebRTCSignalingProvider = null
var _ice_provider: RedotP2PIceServerProvider = null
var _peer_factory: RedotP2PWebRTCPeerFactory = null
var _peer: WebRTCMultiplayerPeer = null
var _connections: Dictionary = {}
var _generations: Dictionary = {}
var _authority: bool = false
var _signals_connected: bool = false
var _maximum_peers: int = 0
var _disconnect_reasons: Dictionary = {}
var _reported_disconnections: Dictionary = {}
var _inside_transport_process: bool = false
var _stop_pending: bool = false
var _pending_stop_reason: String = RedotP2PStatusCodes.CONNECTION_CLOSED


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(_state != State.STOPPED)


func set_providers(
	signaling: RedotP2PWebRTCSignalingProvider,
	ice_provider: RedotP2PIceServerProvider,
	peer_factory: RedotP2PWebRTCPeerFactory
) -> Error:
	if _state != State.STOPPED:
		return ERR_ALREADY_IN_USE
	if signaling == null or ice_provider == null or peer_factory == null:
		return ERR_INVALID_PARAMETER
	_signaling = signaling
	_ice_provider = ice_provider
	_peer_factory = peer_factory
	return OK


func get_capabilities() -> RedotP2PTransportCapabilities:
	var capabilities: RedotP2PTransportCapabilities = RedotP2PTransportCapabilities.new()
	capabilities.transport_name = "webrtc"
	capabilities.available = (
		ClassDB.class_exists("WebRTCMultiplayerPeer")
		and _signaling != null
		and _signaling.is_available()
		and _ice_provider != null
		and _peer_factory != null
		and _peer_factory.is_available()
	)
	capabilities.supports_host = capabilities.available
	capabilities.supports_client = capabilities.available
	capabilities.supports_reliable = capabilities.available
	capabilities.supports_unreliable = capabilities.available
	capabilities.supports_ordered_unreliable = capabilities.available
	capabilities.supports_channels = capabilities.available
	capabilities.supports_web = capabilities.available
	capabilities.exposes_trusted_peer_address = false
	capabilities.reason_code = RedotP2PStatusCodes.OK if capabilities.available else RedotP2PStatusCodes.PROVIDER_UNAVAILABLE
	return capabilities


func host(endpoint: String, port: int, max_peers: int) -> Error:
	if _state != State.STOPPED:
		return ERR_ALREADY_IN_USE
	if endpoint.is_empty() or port < 0 or port > 65_535 or max_peers < 1 or max_peers > MAX_CONFIGURED_PEERS:
		return ERR_INVALID_PARAMETER
	if not get_capabilities().available:
		return _fail_start(ERR_UNAVAILABLE, RedotP2PStatusCodes.PROVIDER_UNAVAILABLE)
	set_process(true)
	_set_state(State.STARTING, RedotP2PStatusCodes.OK)
	_peer = WebRTCMultiplayerPeer.new()
	var create_error: Error = _peer.create_server()
	if create_error != OK:
		_peer = null
		return _fail_start(create_error, RedotP2PStatusCodes.TRANSPORT_FAILURE)
	var signaling_error: Error = _signaling.start_authority(endpoint, port, max_peers)
	if signaling_error != OK or _signaling.get_local_peer_id() != 1:
		_peer = null
		_signaling.stop()
		return _fail_start(ERR_CANT_CONNECT, RedotP2PStatusCodes.CONNECTION_FAILED)
	_authority = true
	_maximum_peers = max_peers
	_connect_signals()
	_set_state(State.LISTENING, RedotP2PStatusCodes.OK)
	return OK


func join(endpoint: String, port: int) -> Error:
	if _state != State.STOPPED:
		return ERR_ALREADY_IN_USE
	if endpoint.is_empty() or port < 0 or port > 65_535:
		return ERR_INVALID_PARAMETER
	if not get_capabilities().available:
		return _fail_start(ERR_UNAVAILABLE, RedotP2PStatusCodes.PROVIDER_UNAVAILABLE)
	set_process(true)
	_set_state(State.STARTING, RedotP2PStatusCodes.OK)
	var signaling_error: Error = _signaling.start_client(endpoint, port)
	var local_peer_id: int = _signaling.get_local_peer_id()
	if signaling_error != OK or local_peer_id <= 1:
		_signaling.stop()
		return _fail_start(ERR_CANT_CONNECT, RedotP2PStatusCodes.CONNECTION_FAILED)
	_peer = WebRTCMultiplayerPeer.new()
	var create_error: Error = _peer.create_client(local_peer_id)
	if create_error != OK:
		_peer = null
		_signaling.stop()
		return _fail_start(create_error, RedotP2PStatusCodes.TRANSPORT_FAILURE)
	_authority = false
	_connect_signals()
	_set_state(State.CONNECTING, RedotP2PStatusCodes.OK)
	return OK


func send_packet(peer_id: int, packet: PackedByteArray, channel: int, delivery: int) -> Error:
	if _peer == null or _state in [State.STOPPED, State.STOPPING, State.FAILED]:
		return ERR_UNCONFIGURED
	if peer_id < 0 or packet.is_empty() or packet.size() > _limits.max_frame_bytes:
		return ERR_INVALID_PARAMETER
	if channel < 0 or channel >= _limits.max_channels:
		return ERR_INVALID_PARAMETER
	var native_delivery: int = _to_native_delivery(delivery)
	if native_delivery < 0:
		return ERR_INVALID_PARAMETER
	_peer.set_target_peer(peer_id)
	_peer.set_transfer_channel(channel)
	_peer.set_transfer_mode(native_delivery as MultiplayerPeer.TransferMode)
	return _peer.put_packet(packet)


func disconnect_peer(peer_id: int, reason_code: String = RedotP2PStatusCodes.CONNECTION_CLOSED) -> Error:
	if _peer == null or peer_id <= 0:
		return ERR_INVALID_PARAMETER
	if not _authority and peer_id != 1:
		return ERR_UNAUTHORIZED
	_disconnect_reasons[peer_id] = reason_code
	_signaling.disconnect_peer(peer_id, reason_code)
	_peer.remove_peer(peer_id)
	_connections.erase(peer_id)
	_generations.erase(peer_id)
	_emit_peer_disconnected_once(peer_id, reason_code)
	return OK


func get_local_peer_id() -> int:
	return 0 if _signaling == null else _signaling.get_local_peer_id()


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
	if _signaling != null:
		_signaling.stop()
	_peer = null
	set_process(false)
	_connections.clear()
	_generations.clear()
	_disconnect_reasons.clear()
	_reported_disconnections.clear()
	_authority = false
	_signals_connected = false
	_maximum_peers = 0
	_stop_pending = false
	_pending_stop_reason = RedotP2PStatusCodes.CONNECTION_CLOSED
	_set_state(State.STOPPED, reason_code)


func _process(_delta: float) -> void:
	if _peer == null or _signaling == null:
		return
	_inside_transport_process = true
	if _signaling.poll() != OK:
		transport_error.emit(RedotP2PStatusCodes.PROVIDER_UNAVAILABLE)
		stop(RedotP2PStatusCodes.PROVIDER_UNAVAILABLE)
	_peer.poll()
	for connection_value: Variant in _connections.values():
		if connection_value is WebRTCPeerConnection:
			(connection_value as WebRTCPeerConnection).poll()
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
			transport_error.emit(RedotP2PStatusCodes.MESSAGE_DELIVERY_INVALID)
			continue
		packet_received.emit(sender_id, packet, packet_channel, packet_delivery)
		if _stop_pending:
			break
	_inside_transport_process = false
	_apply_pending_stop()


func _connect_signals() -> void:
	if _signals_connected or _peer == null or _signaling == null:
		return
	_peer.peer_connected.connect(_on_peer_connected)
	_peer.peer_disconnected.connect(_on_peer_disconnected)
	_signaling.peer_negotiation_requested.connect(_on_peer_negotiation_requested)
	_signaling.session_description_received.connect(_on_session_description_received)
	_signaling.ice_candidate_received.connect(_on_ice_candidate_received)
	_signaling.peer_left.connect(_on_signaling_peer_left)
	_signaling.signaling_error.connect(_on_signaling_error)
	_signals_connected = true


func _on_peer_negotiation_requested(peer_id: int, generation: int, create_offer: bool) -> void:
	if _peer == null or peer_id <= 0 or peer_id == get_local_peer_id() or generation <= 0:
		return
	if _authority and _connections.size() >= _maximum_peers:
		_signaling.disconnect_peer(peer_id, RedotP2PStatusCodes.CAPACITY_EXCEEDED)
		return
	var previous_generation: int = int(_generations.get(peer_id, 0))
	if generation <= previous_generation:
		return
	_reported_disconnections.erase(peer_id)
	if _connections.has(peer_id):
		_peer.remove_peer(peer_id)
		_connections.erase(peer_id)
	var configuration: Dictionary = _ice_provider.get_configuration().duplicate(true)
	var connection: WebRTCPeerConnection = _peer_factory.create_peer(configuration)
	if connection == null:
		_signaling.disconnect_peer(peer_id, RedotP2PStatusCodes.PROVIDER_UNAVAILABLE)
		return
	connection.session_description_created.connect(_on_local_session_description.bind(peer_id, generation))
	connection.ice_candidate_created.connect(_on_local_ice_candidate.bind(peer_id, generation))
	var add_error: Error = _peer.add_peer(connection, peer_id)
	if add_error != OK:
		_signaling.disconnect_peer(peer_id, RedotP2PStatusCodes.TRANSPORT_FAILURE)
		return
	_connections[peer_id] = connection
	_generations[peer_id] = generation
	if create_offer and connection.create_offer() != OK:
		disconnect_peer(peer_id, RedotP2PStatusCodes.CONNECTION_FAILED)


func _on_local_session_description(
	description_type: String,
	sdp: String,
	peer_id: int,
	generation: int
) -> void:
	var connection: WebRTCPeerConnection = _get_current_connection(peer_id, generation)
	if connection == null or not _valid_description(description_type, sdp):
		return
	if connection.set_local_description(description_type, sdp) != OK:
		disconnect_peer(peer_id, RedotP2PStatusCodes.CONNECTION_FAILED)
		return
	if _signaling.send_session_description(peer_id, description_type, sdp, generation) != OK:
		disconnect_peer(peer_id, RedotP2PStatusCodes.PROVIDER_UNAVAILABLE)


func _on_session_description_received(
	peer_id: int,
	description_type: String,
	sdp: String,
	generation: int
) -> void:
	var connection: WebRTCPeerConnection = _get_current_connection(peer_id, generation)
	if connection == null or not _valid_description(description_type, sdp):
		return
	if connection.set_remote_description(description_type, sdp) != OK:
		disconnect_peer(peer_id, RedotP2PStatusCodes.CONNECTION_FAILED)


func _on_local_ice_candidate(
	media: String,
	index: int,
	candidate: String,
	peer_id: int,
	generation: int
) -> void:
	if _get_current_connection(peer_id, generation) == null or not _valid_ice(media, index, candidate):
		return
	if _signaling.send_ice_candidate(peer_id, media, index, candidate, generation) != OK:
		disconnect_peer(peer_id, RedotP2PStatusCodes.PROVIDER_UNAVAILABLE)


func _on_ice_candidate_received(
	peer_id: int,
	media: String,
	index: int,
	candidate: String,
	generation: int
) -> void:
	var connection: WebRTCPeerConnection = _get_current_connection(peer_id, generation)
	if connection == null or not _valid_ice(media, index, candidate):
		return
	if connection.add_ice_candidate(media, index, candidate) != OK:
		disconnect_peer(peer_id, RedotP2PStatusCodes.CONNECTION_FAILED)


func _on_peer_connected(peer_id: int) -> void:
	_reported_disconnections.erase(peer_id)
	peer_connected.emit(peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	_connections.erase(peer_id)
	_generations.erase(peer_id)
	var reason_code: String = str(_disconnect_reasons.get(peer_id, RedotP2PStatusCodes.CONNECTION_CLOSED))
	_disconnect_reasons.erase(peer_id)
	_emit_peer_disconnected_once(peer_id, reason_code)
	if not _authority and peer_id == 1:
		stop(RedotP2PStatusCodes.AUTHORITY_LOST)


func _on_signaling_peer_left(peer_id: int, generation: int) -> void:
	if int(_generations.get(peer_id, 0)) != generation:
		return
	if _peer != null:
		_peer.remove_peer(peer_id)
	_connections.erase(peer_id)
	_generations.erase(peer_id)
	_emit_peer_disconnected_once(peer_id, RedotP2PStatusCodes.CONNECTION_CLOSED)


func _on_signaling_error(reason_code: String) -> void:
	transport_error.emit(reason_code)
	stop(reason_code)


func _update_client_connection_state() -> void:
	if _peer == null or _authority:
		return
	var connection_status: int = _peer.get_connection_status()
	if _state == State.CONNECTING and connection_status == MultiplayerPeer.CONNECTION_CONNECTED:
		_set_state(State.CONNECTED, RedotP2PStatusCodes.OK)
	elif _state in [State.CONNECTING, State.CONNECTED] and connection_status == MultiplayerPeer.CONNECTION_DISCONNECTED:
		transport_error.emit(RedotP2PStatusCodes.CONNECTION_FAILED)
		stop(RedotP2PStatusCodes.CONNECTION_FAILED)


func _get_current_connection(peer_id: int, generation: int) -> WebRTCPeerConnection:
	if int(_generations.get(peer_id, 0)) != generation:
		return null
	var value: Variant = _connections.get(peer_id)
	return value as WebRTCPeerConnection if value is WebRTCPeerConnection else null


func _valid_description(description_type: String, sdp: String) -> bool:
	return description_type in ["offer", "answer"] and not sdp.is_empty() and sdp.to_utf8_buffer().size() <= MAX_SDP_BYTES


func _valid_ice(media: String, index: int, candidate: String) -> bool:
	return (
		index >= 0
		and media.to_utf8_buffer().size() <= MAX_ICE_MEDIA_BYTES
		and not candidate.is_empty()
		and candidate.to_utf8_buffer().size() <= MAX_ICE_CANDIDATE_BYTES
	)


func _apply_pending_stop() -> void:
	if not _stop_pending:
		return
	var reason_code: String = _pending_stop_reason
	_stop_pending = false
	_stop_now(reason_code)


func _emit_peer_disconnected_once(peer_id: int, reason_code: String) -> void:
	if _reported_disconnections.has(peer_id):
		return
	_reported_disconnections[peer_id] = true
	peer_disconnected.emit(peer_id, reason_code)


func _fail_start(error_code: Error, reason_code: String) -> Error:
	set_process(false)
	_set_state(State.FAILED, reason_code)
	transport_error.emit(reason_code)
	return error_code


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
