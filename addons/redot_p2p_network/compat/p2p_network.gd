class_name RedotP2PCompatibilityNetwork
extends Node

signal peer_status_updated(network_id: int, status: int)
signal peer_session_failure(network_id: int, reason: String)
signal all_peers_connected
signal disconnect
signal periodic_sync(priority: int)
signal recived_obj(network_id: int, path: NodePath)

signal transport_state_changed(previous_state: int, current_state: int, reason_code: String)
signal peer_connected(peer_id: int)
signal peer_disconnected(peer_id: int, reason_code: String)
signal message_received(peer_id: int, message_type: String, payload: PackedByteArray)
signal message_rejected(peer_id: int, reason_code: String)
signal network_error(reason_code: String)

enum P2P_SEND_TYPE {
	UNRELIABLE,
	UNRELIABLE_NO_DELAY,
	RELIABLE,
	RELIABLE_WITH_BUFFERING,
}

enum RPC_TYPE {
	CLIENT,
	ALL_CLIENTS,
	SERVER,
	ALL,
	SYNC,
	ALL_INCLUDING_SELF,
}

enum SYNC_PRIORITY {
	LOW,
	MEDIUM,
	HIGH,
}

@export_range(0.1, 60.0, 0.1) var periodic_interval_low: float = 1.0
@export_range(0.01, 1.0, 0.01) var periodic_interval_high: float = 0.05

var network_data: NetworkData = NetworkData.new()
var moderation: RedotP2PModerationService = null
var access_control: RedotP2PCapabilityService = null
var replicated_state: RedotP2PReplicatedStateService = null
var replication: RedotP2PReplicationService = null
var globalData: P2PGlobalData = null
var global_data: P2PGlobalData = null
var last_status_code: String = RedotP2PStatusCodes.OK

var _service: RedotP2PNetworkService = null
var _low_timer: Timer = null
var _high_timer: Timer = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_service = RedotP2PNetworkService.new()
	_service.name = "NetworkService"
	add_child(_service)
	_service.transport_state_changed.connect(_on_transport_state_changed)
	_service.peer_connected.connect(_on_peer_connected)
	_service.peer_disconnected.connect(_on_peer_disconnected)
	_service.message_received.connect(_on_message_received)
	_service.message_rejected.connect(_on_message_rejected)
	_service.service_error.connect(_on_service_error)
	access_control = RedotP2PCapabilityService.new()
	access_control.name = "CapabilityService"
	add_child(access_control)
	access_control.attach(_service)
	moderation = RedotP2PModerationService.new()
	moderation.name = "ModerationService"
	add_child(moderation)
	moderation.attach(_service)
	replicated_state = RedotP2PReplicatedStateService.new()
	replicated_state.name = "ReplicatedStateService"
	add_child(replicated_state)
	replicated_state.attach(_service)
	replication = RedotP2PReplicationService.new()
	replication.name = "ReplicationService"
	add_child(replication)
	replication.attach(_service)
	globalData = P2PGlobalData.new()
	globalData.name = "GlobalData"
	add_child(globalData)
	globalData.attach(replicated_state)
	global_data = globalData
	_create_periodic_timers()


func configure(limits: RedotP2PProtocolLimits) -> Error:
	return _service.configure(limits)


func use_transport(adapter: RedotP2PTransportAdapter) -> Error:
	return _service.set_transport(adapter)


func host_enet(port: int = 7777, max_peers: int = 16, bind_address: String = "*") -> Error:
	var adapter_error: Error = _ensure_enet_transport()
	if adapter_error != OK:
		return adapter_error
	var host_error: Error = _service.host(bind_address, port, max_peers)
	if host_error == OK:
		_update_current_peer()
	return host_error


func join_enet(address: String, port: int = 7777) -> Error:
	var adapter_error: Error = _ensure_enet_transport()
	if adapter_error != OK:
		return adapter_error
	return _service.join(address, port)


func host_websocket(
	port: int = 7778,
	max_peers: int = 16,
	bind_address: String = "*",
	server_tls_options: TLSOptions = null,
	allow_plaintext_loopback: bool = false
) -> Error:
	var adapter_value: Variant = _ensure_websocket_transport()
	if not adapter_value is RedotP2PWebSocketTransportAdapter:
		return int(adapter_value) as Error
	var adapter: RedotP2PWebSocketTransportAdapter = adapter_value as RedotP2PWebSocketTransportAdapter
	var tls_error: Error = adapter.set_server_tls_options(server_tls_options)
	if tls_error != OK:
		return tls_error
	var plaintext_error: Error = adapter.enable_plaintext_loopback_development(allow_plaintext_loopback)
	if plaintext_error != OK:
		return plaintext_error
	var host_error: Error = _service.host(bind_address, port, max_peers)
	if host_error == OK:
		_update_current_peer()
	return host_error


func join_websocket(
	address: String,
	port: int = 7778,
	client_tls_options: TLSOptions = null,
	allow_plaintext_loopback: bool = false
) -> Error:
	var adapter_value: Variant = _ensure_websocket_transport()
	if not adapter_value is RedotP2PWebSocketTransportAdapter:
		return int(adapter_value) as Error
	var adapter: RedotP2PWebSocketTransportAdapter = adapter_value as RedotP2PWebSocketTransportAdapter
	var tls_error: Error = adapter.set_client_tls_options(client_tls_options)
	if tls_error != OK:
		return tls_error
	var plaintext_error: Error = adapter.enable_plaintext_loopback_development(allow_plaintext_loopback)
	if plaintext_error != OK:
		return plaintext_error
	return _service.join(address, port)


func host_steam(
	expected_app_id: int,
	virtual_port: int = 0,
	max_peers: int = 16,
	callback_pump_mode: int = RedotP2PRedotSteamProvider.CallbackPumpMode.ADAPTER_OWNED
) -> Error:
	var adapter_error: Error = _ensure_steam_transport(expected_app_id, callback_pump_mode)
	if adapter_error != OK:
		return adapter_error
	var host_error: Error = _service.host("", virtual_port, max_peers)
	if host_error == OK:
		_update_current_peer()
	return host_error


func join_steam(
	host_steam_id: String,
	expected_app_id: int,
	virtual_port: int = 0,
	callback_pump_mode: int = RedotP2PRedotSteamProvider.CallbackPumpMode.ADAPTER_OWNED
) -> Error:
	var adapter_error: Error = _ensure_steam_transport(expected_app_id, callback_pump_mode)
	if adapter_error != OK:
		return adapter_error
	return _service.join(host_steam_id, virtual_port)


func stop(reason_code: String = RedotP2PStatusCodes.CONNECTION_CLOSED) -> void:
	_service.stop(reason_code)
	network_data.clear()
	if replicated_state != null:
		replicated_state.reset()
	disconnect.emit()


func register_message(
	message_type: String,
	handler: Callable,
	max_payload_bytes: int = 4096,
	allow_from_client: bool = false,
	allow_from_authority: bool = true,
	channel: int = -1,
	delivery: int = -1,
	per_peer_rate: float = 8.0,
	per_peer_burst: int = 16,
	required_capability: String = ""
) -> Error:
	var definition: RedotP2PMessageDefinition = RedotP2PMessageDefinition.new()
	definition.message_type = message_type
	definition.handler = handler
	definition.max_payload_bytes = max_payload_bytes
	definition.allow_from_client = allow_from_client
	definition.allow_from_authority = allow_from_authority
	definition.required_channel = channel
	definition.required_delivery = delivery
	definition.per_peer_rate = per_peer_rate
	definition.per_peer_burst = per_peer_burst
	definition.required_capability = required_capability
	return _service.register_message(definition)


func unregister_message(message_type: String) -> bool:
	return _service.unregister_message(message_type)


func send_message(
	message_type: String,
	payload: PackedByteArray,
	peer_id: int = 0,
	channel: int = 0,
	delivery: int = RedotP2PTransportAdapter.Delivery.RELIABLE
) -> Error:
	return _service.send_message(message_type, payload, peer_id, channel, delivery)


func get_transport_capabilities() -> Dictionary:
	return _service.get_transport_capabilities().as_dictionary()


func get_observed_address(peer_id: int) -> String:
	return _service.get_observed_address(peer_id)


func get_peer_identity(peer_id: int) -> String:
	return _service.get_peer_identity(peer_id)


func is_server() -> bool:
	return _service.is_authority()


func get_network_id() -> int:
	return _service.get_local_peer_id()


func get_service() -> RedotP2PNetworkService:
	return _service


func rpc_emit_signal(obj: Node, signal_name: String, args: Array = [], _peer: NetPeer = null) -> bool:
	if _is_network_active():
		_reject_unsafe_legacy_call()
		return false
	if obj == null or not obj.has_signal(signal_name):
		return false
	obj.emit_signal.bindv(args).call(signal_name)
	return true


func rpc_method(method: Callable, rpc_type: int = RPC_TYPE.ALL, _send_type: int = P2P_SEND_TYPE.RELIABLE) -> bool:
	if _is_network_active():
		_reject_unsafe_legacy_call()
		return false
	if rpc_type == RPC_TYPE.ALL_INCLUDING_SELF and method.is_valid():
		method.call()
		return true
	return false


func rpc_sync(_obj: Node, _send_type: int = P2P_SEND_TYPE.RELIABLE, _peer: NetPeer = null) -> bool:
	if _obj is P2PNode and replication != null:
		if not _is_network_active():
			return true
		var sync_node: P2PNode = _obj as P2PNode
		return sync_node.publish_replication_state() == OK
	if _is_network_active():
		_reject_unsafe_legacy_call()
		return false
	return true


func rpc_remove_node(caller: Node) -> bool:
	if _is_network_active():
		_reject_unsafe_legacy_call()
		return false
	if caller == null or caller == self or not caller.is_inside_tree():
		return false
	caller.queue_free()
	return true


func _ensure_enet_transport() -> Error:
	var current: RedotP2PTransportAdapter = _service.get_transport()
	if current != null and current.get_state() != RedotP2PTransportAdapter.State.STOPPED:
		return ERR_ALREADY_IN_USE
	if current is RedotP2PEnetTransportAdapter:
		return OK
	return _service.set_transport(RedotP2PEnetTransportAdapter.new())


func _ensure_websocket_transport() -> Variant:
	var current: RedotP2PTransportAdapter = _service.get_transport()
	if current != null and current.get_state() != RedotP2PTransportAdapter.State.STOPPED:
		return ERR_ALREADY_IN_USE
	if current is RedotP2PWebSocketTransportAdapter:
		return current
	var adapter: RedotP2PWebSocketTransportAdapter = RedotP2PWebSocketTransportAdapter.new()
	var transport_error: Error = _service.set_transport(adapter)
	return adapter if transport_error == OK else transport_error


func _ensure_steam_transport(expected_app_id: int, callback_pump_mode: int) -> Error:
	var current: RedotP2PTransportAdapter = _service.get_transport()
	if current != null and current.get_state() != RedotP2PTransportAdapter.State.STOPPED:
		return ERR_ALREADY_IN_USE
	var provider: RedotP2PRedotSteamProvider = RedotP2PRedotSteamProvider.new()
	var provider_error: Error = provider.configure(expected_app_id, callback_pump_mode)
	if provider_error != OK:
		return provider_error
	var adapter: RedotP2PSteamTransportAdapter
	if current is RedotP2PSteamTransportAdapter:
		adapter = current as RedotP2PSteamTransportAdapter
	else:
		adapter = RedotP2PSteamTransportAdapter.new()
		var transport_error: Error = _service.set_transport(adapter)
		if transport_error != OK:
			return transport_error
	return adapter.set_provider(provider)


func _is_network_active() -> bool:
	var transport: RedotP2PTransportAdapter = _service.get_transport()
	return transport != null and transport.get_state() not in [
		RedotP2PTransportAdapter.State.STOPPED,
		RedotP2PTransportAdapter.State.FAILED,
	]


func _reject_unsafe_legacy_call() -> void:
	last_status_code = RedotP2PStatusCodes.UNSAFE_LEGACY_API_REJECTED
	network_error.emit(last_status_code)


func _create_periodic_timers() -> void:
	_high_timer = Timer.new()
	_high_timer.name = "HighPrioritySyncTimer"
	_high_timer.wait_time = periodic_interval_high
	_high_timer.autostart = true
	_high_timer.timeout.connect(func() -> void: periodic_sync.emit(SYNC_PRIORITY.HIGH))
	add_child(_high_timer)
	_low_timer = Timer.new()
	_low_timer.name = "LowPrioritySyncTimer"
	_low_timer.wait_time = periodic_interval_low
	_low_timer.autostart = true
	_low_timer.timeout.connect(func() -> void: periodic_sync.emit(SYNC_PRIORITY.LOW))
	add_child(_low_timer)


func _update_current_peer() -> void:
	var local_peer_id: int = _service.get_local_peer_id()
	if local_peer_id <= 0:
		return
	var peer: NetPeer = network_data.get_peer(local_peer_id)
	if peer == null:
		peer = NetPeer.new(local_peer_id)
	peer.connected = true
	peer.host = local_peer_id == 1
	network_data.set_current_peer(peer)


func _on_transport_state_changed(previous_state: int, current_state: int, reason_code: String) -> void:
	last_status_code = reason_code
	if current_state == RedotP2PTransportAdapter.State.CONNECTED or current_state == RedotP2PTransportAdapter.State.LISTENING:
		_update_current_peer()
	transport_state_changed.emit(previous_state, current_state, reason_code)


func _on_peer_connected(peer_id: int) -> void:
	var peer: NetPeer = network_data.get_peer(peer_id)
	if peer == null:
		peer = NetPeer.new(peer_id)
	peer.connected = true
	peer.host = peer_id == 1
	network_data.set_peer(peer)
	peer_status_updated.emit(peer_id, peer.status)
	peer_connected.emit(peer_id)
	all_peers_connected.emit()


func _on_peer_disconnected(peer_id: int, reason_code: String) -> void:
	network_data.remove_peer(peer_id)
	peer_status_updated.emit(peer_id, NetPeer.ConnectionStatus.DISCONNECTED)
	peer_disconnected.emit(peer_id, reason_code)
	if peer_id == 1 and not is_server():
		disconnect.emit()


func _on_message_received(peer_id: int, message_type: String, payload: PackedByteArray) -> void:
	message_received.emit(peer_id, message_type, payload)


func _on_message_rejected(peer_id: int, reason_code: String) -> void:
	last_status_code = reason_code
	message_rejected.emit(peer_id, reason_code)


func _on_service_error(reason_code: String) -> void:
	last_status_code = reason_code
	network_error.emit(reason_code)
