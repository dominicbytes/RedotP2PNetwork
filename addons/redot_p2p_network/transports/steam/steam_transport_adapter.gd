class_name RedotP2PSteamTransportAdapter
extends RedotP2PTransportAdapter

const MAX_CONFIGURED_PEERS: int = 4095
const STEAM_PROVIDER_SCRIPT: Script = preload("res://addons/redot_p2p_network/providers/steam/redot_steam_provider.gd")

var _provider: STEAM_PROVIDER_SCRIPT = null
var _peer: MultiplayerPeer = null
var _authority: bool = false
var _signals_connected: bool = false
var _maximum_peers: int = 0
var _connected_peers: Dictionary = {}
var _disconnect_reasons: Dictionary = {}
var _inside_transport_process: bool = false
var _stop_pending: bool = false
var _pending_stop_reason: String = RedotP2PStatusCodes.CONNECTION_CLOSED


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(_state != State.STOPPED)


func set_provider(provider: STEAM_PROVIDER_SCRIPT) -> Error:
	if _state != State.STOPPED:
		return ERR_ALREADY_IN_USE
	if provider == null:
		return ERR_INVALID_PARAMETER
	_provider = provider
	return OK


func get_capabilities() -> RedotP2PTransportCapabilities:
	var capabilities: RedotP2PTransportCapabilities = RedotP2PTransportCapabilities.new()
	capabilities.transport_name = "steam"
	var provider_status: String = RedotP2PStatusCodes.PROVIDER_UNAVAILABLE
	if _provider != null:
		provider_status = _provider.get_availability_status()
	capabilities.available = provider_status == RedotP2PStatusCodes.OK
	capabilities.supports_host = capabilities.available
	capabilities.supports_client = capabilities.available
	capabilities.supports_reliable = capabilities.available
	capabilities.supports_unreliable = capabilities.available
	capabilities.supports_ordered_unreliable = false
	capabilities.supports_channels = capabilities.available
	capabilities.supports_web = false
	capabilities.exposes_trusted_peer_address = false
	capabilities.reason_code = RedotP2PStatusCodes.OK if capabilities.available else provider_status
	return capabilities


func host(_bind_address: String, virtual_port: int, max_peers: int) -> Error:
	if _state != State.STOPPED:
		return ERR_ALREADY_IN_USE
	if virtual_port < 0 or virtual_port > 65_535 or max_peers < 1 or max_peers > MAX_CONFIGURED_PEERS:
		return ERR_INVALID_PARAMETER
	var start_error: Error = _begin_start()
	if start_error != OK:
		return start_error
	set_process(true)
	_set_state(State.STARTING, RedotP2PStatusCodes.OK)
	var create_value: Variant = _peer.call("create_host", virtual_port)
	var create_error: Error = int(create_value) as Error
	if create_error != OK:
		_cleanup_failed_start()
		return _fail_start(create_error, RedotP2PStatusCodes.TRANSPORT_FAILURE)
	_authority = true
	_maximum_peers = max_peers
	_connect_peer_signals()
	_set_state(State.LISTENING, RedotP2PStatusCodes.OK)
	return OK


func join(host_steam_id: String, virtual_port: int) -> Error:
	if _state != State.STOPPED:
		return ERR_ALREADY_IN_USE
	if virtual_port < 0 or virtual_port > 65_535 or not _is_valid_steam_id(host_steam_id):
		return ERR_INVALID_PARAMETER
	var start_error: Error = _begin_start()
	if start_error != OK:
		return start_error
	set_process(true)
	_set_state(State.STARTING, RedotP2PStatusCodes.OK)
	var create_value: Variant = _peer.call("create_client", int(host_steam_id), virtual_port)
	var create_error: Error = int(create_value) as Error
	if create_error != OK:
		_cleanup_failed_start()
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
	var native_delivery: int = _to_native_delivery(delivery)
	if native_delivery < 0:
		return ERR_UNAVAILABLE
	_peer.set_target_peer(peer_id)
	_peer.set_transfer_channel(channel)
	_peer.set_transfer_mode(native_delivery as MultiplayerPeer.TransferMode)
	return _peer.put_packet(packet)


func disconnect_peer(peer_id: int, reason_code: String = RedotP2PStatusCodes.CONNECTION_CLOSED) -> Error:
	if _peer == null or peer_id <= 0:
		return ERR_INVALID_PARAMETER
	if not _authority and peer_id != 1:
		return ERR_UNAUTHORIZED
	if not _connected_peers.has(peer_id):
		return ERR_DOES_NOT_EXIST
	_disconnect_reasons[peer_id] = reason_code
	_peer.disconnect_peer(peer_id, true)
	_on_peer_disconnected(peer_id)
	return OK


func get_peer_identity(peer_id: int) -> String:
	if _peer == null or peer_id <= 0 or not _peer.has_method("get_steam_id_for_peer_id"):
		return ""
	var steam_id: int = int(_peer.call("get_steam_id_for_peer_id", peer_id))
	return "steam:%d" % steam_id if steam_id > 0 else ""


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
	if _provider != null:
		_provider.release(get_instance_id())
	_stop_pending = false
	_pending_stop_reason = RedotP2PStatusCodes.CONNECTION_CLOSED
	_set_state(State.STOPPED, reason_code)


func _process(_delta: float) -> void:
	if _peer == null:
		return
	_inside_transport_process = true
	if _provider == null or _provider.pump_callbacks(get_instance_id()) != OK:
		transport_error.emit(RedotP2PStatusCodes.PROVIDER_PUMP_UNHEALTHY)
		stop(RedotP2PStatusCodes.PROVIDER_PUMP_UNHEALTHY)
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
			transport_error.emit(RedotP2PStatusCodes.MESSAGE_DELIVERY_INVALID)
			continue
		packet_received.emit(sender_id, packet, packet_channel, packet_delivery)
		if _stop_pending:
			break
	_inside_transport_process = false
	_apply_pending_stop()


func _begin_start() -> Error:
	if _provider == null or _provider.get_availability_status() != RedotP2PStatusCodes.OK:
		return _fail_start(ERR_UNAVAILABLE, RedotP2PStatusCodes.PROVIDER_UNAVAILABLE)
	var lease_error: Error = _provider.acquire(get_instance_id())
	if lease_error != OK:
		return _fail_start(lease_error, RedotP2PStatusCodes.PROVIDER_UNAVAILABLE)
	var instance: Object = ClassDB.instantiate("SteamMultiplayerPeer")
	if not instance is MultiplayerPeer:
		_provider.release(get_instance_id())
		return _fail_start(ERR_CANT_CREATE, RedotP2PStatusCodes.PROVIDER_UNAVAILABLE)
	_peer = instance as MultiplayerPeer
	return OK


func _cleanup_failed_start() -> void:
	if _peer != null:
		_peer.close()
	_peer = null
	if _provider != null:
		_provider.release(get_instance_id())


func _connect_peer_signals() -> void:
	if _signals_connected or _peer == null:
		return
	_peer.peer_connected.connect(_on_peer_connected)
	_peer.peer_disconnected.connect(_on_peer_disconnected)
	_signals_connected = true


func _on_peer_connected(peer_id: int) -> void:
	if _authority and _connected_peers.size() >= _maximum_peers:
		_peer.disconnect_peer(peer_id, true)
		return
	_connected_peers[peer_id] = true
	peer_connected.emit(peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	if not _connected_peers.erase(peer_id):
		return
	var reason_code: String = str(_disconnect_reasons.get(peer_id, RedotP2PStatusCodes.CONNECTION_CLOSED))
	if not _authority and peer_id == 1 and not _disconnect_reasons.has(peer_id):
		reason_code = RedotP2PStatusCodes.AUTHORITY_LOST
	_disconnect_reasons.erase(peer_id)
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
		_on_peer_disconnected(1)
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


func _is_valid_steam_id(value: String) -> bool:
	var normalized: String = value.strip_edges()
	if normalized.is_empty() or normalized.length() > 20:
		return false
	for index: int in normalized.length():
		var codepoint: int = normalized.unicode_at(index)
		if codepoint < 0x30 or codepoint > 0x39:
			return false
	return int(normalized) > 0


func _to_native_delivery(delivery: int) -> int:
	match delivery:
		Delivery.UNRELIABLE:
			return MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
		Delivery.RELIABLE:
			return MultiplayerPeer.TRANSFER_MODE_RELIABLE
		_:
			return -1


func _from_native_delivery(delivery: int) -> int:
	match delivery:
		MultiplayerPeer.TRANSFER_MODE_UNRELIABLE:
			return Delivery.UNRELIABLE
		MultiplayerPeer.TRANSFER_MODE_RELIABLE:
			return Delivery.RELIABLE
		_:
			return -1
