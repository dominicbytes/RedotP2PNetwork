class_name RedotP2PNetworkService
extends Node

signal transport_state_changed(previous_state: int, current_state: int, reason_code: String)
signal peer_connected(peer_id: int)
signal peer_disconnected(peer_id: int, reason_code: String)
signal message_received(peer_id: int, message_type: String, payload: PackedByteArray)
signal message_rejected(peer_id: int, reason_code: String)
signal service_error(reason_code: String)

var _limits: RedotP2PProtocolLimits = RedotP2PProtocolLimits.new()
var _transport: RedotP2PTransportAdapter = null
var _definitions: Dictionary = {}
var _inbound_buckets: Dictionary = {}
var _last_sequences: Dictionary = {}
var _outbound_sequences: Dictionary = {}
var _violations: Dictionary = {}
var _quarantined_peers: Dictionary = {}
var _capability_checker: Callable = Callable()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func configure(limits: RedotP2PProtocolLimits) -> Error:
	if _transport != null and _transport.get_state() != RedotP2PTransportAdapter.State.STOPPED:
		return ERR_ALREADY_IN_USE
	if limits == null or limits.validate() != OK:
		return ERR_INVALID_PARAMETER
	_limits = limits.duplicate()
	return OK


func set_capability_checker(checker: Callable) -> Error:
	if checker.is_valid() and checker.get_argument_count() < 2:
		return ERR_INVALID_PARAMETER
	_capability_checker = checker
	return OK


func set_transport(adapter: RedotP2PTransportAdapter) -> Error:
	if adapter == null:
		return ERR_INVALID_PARAMETER
	if _transport != null and _transport.get_state() != RedotP2PTransportAdapter.State.STOPPED:
		return ERR_ALREADY_IN_USE
	_disconnect_transport_signals()
	_transport = adapter
	var configure_error: Error = _transport.configure(_limits)
	if configure_error != OK:
		_transport = null
		return configure_error
	if _transport.get_parent() == null:
		add_child(_transport)
	_connect_transport_signals()
	return OK


func get_transport() -> RedotP2PTransportAdapter:
	return _transport


func get_transport_capabilities() -> RedotP2PTransportCapabilities:
	if _transport == null:
		return RedotP2PTransportCapabilities.new()
	return _transport.get_capabilities()


func host(bind_address: String, port: int, max_peers: int) -> Error:
	if _transport == null:
		return ERR_UNCONFIGURED
	if _transport.get_state() != RedotP2PTransportAdapter.State.STOPPED:
		return ERR_ALREADY_IN_USE
	_reset_session_state()
	return _transport.host(bind_address, port, max_peers)


func join(address: String, port: int) -> Error:
	if _transport == null:
		return ERR_UNCONFIGURED
	if _transport.get_state() != RedotP2PTransportAdapter.State.STOPPED:
		return ERR_ALREADY_IN_USE
	_reset_session_state()
	return _transport.join(address, port)


func stop(reason_code: String = RedotP2PStatusCodes.CONNECTION_CLOSED) -> void:
	if _transport != null:
		_transport.stop(reason_code)
	_reset_session_state()


func register_message(definition: RedotP2PMessageDefinition) -> Error:
	if definition == null or definition.validate(_limits) != OK:
		return ERR_INVALID_PARAMETER
	var validation_envelope: RedotP2PMessageEnvelope = RedotP2PMessageEnvelope.new()
	validation_envelope.message_type = definition.message_type
	validation_envelope.sequence = 1
	if validation_envelope.encode(_limits).is_empty():
		return ERR_INVALID_PARAMETER
	if _definitions.has(definition.message_type):
		return ERR_ALREADY_EXISTS
	_definitions[definition.message_type] = definition
	return OK


func unregister_message(message_type: String) -> bool:
	return _definitions.erase(message_type)


func has_registered_message(message_type: String) -> bool:
	return _definitions.has(message_type)


func send_message(
	message_type: String,
	payload: PackedByteArray,
	peer_id: int = 0,
	channel: int = 0,
	delivery: int = RedotP2PTransportAdapter.Delivery.RELIABLE
) -> Error:
	if _transport == null:
		return ERR_UNCONFIGURED
	var definition_value: Variant = _definitions.get(message_type)
	if not definition_value is RedotP2PMessageDefinition:
		return ERR_DOES_NOT_EXIST
	var definition: RedotP2PMessageDefinition = definition_value as RedotP2PMessageDefinition
	if payload.size() > definition.max_payload_bytes:
		return ERR_INVALID_DATA
	if definition.required_channel >= 0 and channel != definition.required_channel:
		return ERR_INVALID_PARAMETER
	if definition.required_delivery >= 0 and delivery != definition.required_delivery:
		return ERR_INVALID_PARAMETER
	if _transport.is_authority():
		if not definition.allow_from_authority:
			return ERR_UNAUTHORIZED
	elif not definition.allow_from_client:
		return ERR_UNAUTHORIZED
	var target_peer: int = peer_id
	if not _transport.is_authority() and target_peer == 0:
		target_peer = 1
	var next_sequence: int = _next_outbound_sequence(channel)
	if next_sequence <= 0:
		service_error.emit(RedotP2PStatusCodes.INTERNAL_INVARIANT_FAILED)
		return ERR_OUT_OF_MEMORY
	var envelope: RedotP2PMessageEnvelope = RedotP2PMessageEnvelope.new()
	envelope.message_type = message_type
	envelope.payload = payload
	envelope.channel = channel
	envelope.sequence = next_sequence
	envelope.delivery = delivery
	var frame: PackedByteArray = envelope.encode(_limits)
	if frame.is_empty():
		return ERR_INVALID_DATA
	return _transport.send_packet(target_peer, frame, channel, delivery)


func get_observed_address(peer_id: int) -> String:
	if _transport == null:
		return ""
	return _transport.get_observed_address(peer_id)


func get_peer_identity(peer_id: int) -> String:
	if _transport == null:
		return ""
	return _transport.get_peer_identity(peer_id)


func disconnect_peer(peer_id: int, reason_code: String = RedotP2PStatusCodes.CONNECTION_CLOSED) -> Error:
	if _transport == null:
		return ERR_UNCONFIGURED
	return _transport.disconnect_peer(peer_id, reason_code)


func is_authority() -> bool:
	return _transport != null and _transport.is_authority()


func get_local_peer_id() -> int:
	return 0 if _transport == null else _transport.get_local_peer_id()


func _on_packet_received(peer_id: int, packet: PackedByteArray, channel: int, delivery: int) -> void:
	if _quarantined_peers.has(peer_id):
		return
	var decoded: RedotP2PEnvelopeDecodeResult = RedotP2PMessageEnvelope.decode(packet, _limits)
	if not decoded.is_ok():
		_reject(peer_id, decoded.status_code)
		return
	var envelope: RedotP2PMessageEnvelope = decoded.envelope
	if envelope.channel != channel:
		_reject(peer_id, RedotP2PStatusCodes.MESSAGE_CHANNEL_INVALID)
		return
	if envelope.delivery != delivery:
		_reject(peer_id, RedotP2PStatusCodes.MESSAGE_DELIVERY_INVALID)
		return
	var definition_value: Variant = _definitions.get(envelope.message_type)
	if not definition_value is RedotP2PMessageDefinition:
		_reject(peer_id, RedotP2PStatusCodes.MESSAGE_UNREGISTERED)
		return
	var definition: RedotP2PMessageDefinition = definition_value as RedotP2PMessageDefinition
	if envelope.payload.size() > definition.max_payload_bytes:
		_reject(peer_id, RedotP2PStatusCodes.PAYLOAD_TOO_LARGE)
		return
	if definition.required_channel >= 0 and envelope.channel != definition.required_channel:
		_reject(peer_id, RedotP2PStatusCodes.MESSAGE_CHANNEL_INVALID)
		return
	if definition.required_delivery >= 0 and envelope.delivery != definition.required_delivery:
		_reject(peer_id, RedotP2PStatusCodes.MESSAGE_DELIVERY_INVALID)
		return
	if not _is_sender_allowed(peer_id, definition):
		_reject(peer_id, RedotP2PStatusCodes.MESSAGE_UNAUTHORIZED)
		return
	if not definition.required_capability.is_empty() and not _has_capability(peer_id, definition.required_capability):
		_reject(peer_id, RedotP2PStatusCodes.MESSAGE_UNAUTHORIZED)
		return
	if not _accept_sequence(peer_id, envelope.channel, envelope.sequence):
		_reject(peer_id, RedotP2PStatusCodes.MESSAGE_REPLAYED)
		return
	if not _consume_rate_budget(peer_id, definition):
		_reject(peer_id, RedotP2PStatusCodes.MESSAGE_RATE_LIMITED)
		return
	definition.handler.call(peer_id, envelope.payload)
	message_received.emit(peer_id, envelope.message_type, envelope.payload)


func _is_sender_allowed(peer_id: int, definition: RedotP2PMessageDefinition) -> bool:
	if _transport == null or peer_id <= 0:
		return false
	if _transport.is_authority():
		return peer_id != 1 and definition.allow_from_client
	return peer_id == 1 and definition.allow_from_authority


func _has_capability(peer_id: int, capability: String) -> bool:
	if not _capability_checker.is_valid():
		return false
	var allowed_value: Variant = _capability_checker.call(peer_id, capability)
	return allowed_value is bool and bool(allowed_value)


func _accept_sequence(peer_id: int, channel: int, sequence: int) -> bool:
	var key: String = "%d:%d" % [peer_id, channel]
	var previous: int = int(_last_sequences.get(key, 0))
	if sequence <= previous:
		return false
	_last_sequences[key] = sequence
	return true


func _consume_rate_budget(peer_id: int, definition: RedotP2PMessageDefinition) -> bool:
	var key: String = "%d:%s" % [peer_id, definition.message_type]
	var bucket_value: Variant = _inbound_buckets.get(key)
	var bucket: RedotP2PTokenBucket
	if bucket_value is RedotP2PTokenBucket:
		bucket = bucket_value as RedotP2PTokenBucket
	else:
		bucket = RedotP2PTokenBucket.new()
		if bucket.configure(definition.per_peer_rate, definition.per_peer_burst) != OK:
			return false
		_inbound_buckets[key] = bucket
	return bucket.allow()


func _next_outbound_sequence(channel: int) -> int:
	var previous: int = int(_outbound_sequences.get(channel, 0))
	if previous >= 4_294_967_295:
		return -1
	var next_sequence: int = previous + 1
	_outbound_sequences[channel] = next_sequence
	return next_sequence


func _reject(peer_id: int, reason_code: String) -> void:
	message_rejected.emit(peer_id, reason_code)
	var count: int = int(_violations.get(peer_id, 0)) + 1
	_violations[peer_id] = count
	if count >= _limits.max_protocol_violations and _transport != null:
		_quarantined_peers[peer_id] = true
		_transport.disconnect_peer(peer_id, reason_code)


func _on_peer_connected(peer_id: int) -> void:
	_quarantined_peers.erase(peer_id)
	peer_connected.emit(peer_id)


func _on_peer_disconnected(peer_id: int, reason_code: String) -> void:
	_remove_peer_state(peer_id)
	peer_disconnected.emit(peer_id, reason_code)


func _on_transport_error(reason_code: String) -> void:
	service_error.emit(reason_code)


func _connect_transport_signals() -> void:
	if _transport == null:
		return
	_transport.state_changed.connect(_on_transport_state_changed)
	_transport.peer_connected.connect(_on_peer_connected)
	_transport.peer_disconnected.connect(_on_peer_disconnected)
	_transport.packet_received.connect(_on_packet_received)
	_transport.transport_error.connect(_on_transport_error)


func _disconnect_transport_signals() -> void:
	if _transport == null:
		return
	if _transport.state_changed.is_connected(_on_transport_state_changed):
		_transport.state_changed.disconnect(_on_transport_state_changed)
	if _transport.peer_connected.is_connected(_on_peer_connected):
		_transport.peer_connected.disconnect(_on_peer_connected)
	if _transport.peer_disconnected.is_connected(_on_peer_disconnected):
		_transport.peer_disconnected.disconnect(_on_peer_disconnected)
	if _transport.packet_received.is_connected(_on_packet_received):
		_transport.packet_received.disconnect(_on_packet_received)
	if _transport.transport_error.is_connected(_on_transport_error):
		_transport.transport_error.disconnect(_on_transport_error)


func _on_transport_state_changed(previous_state: int, current_state: int, reason_code: String) -> void:
	transport_state_changed.emit(previous_state, current_state, reason_code)


func _remove_peer_state(peer_id: int) -> void:
	_violations.erase(peer_id)
	var sequence_prefix: String = "%d:" % peer_id
	for key_value: Variant in _last_sequences.keys():
		var key: String = str(key_value)
		if key.begins_with(sequence_prefix):
			_last_sequences.erase(key_value)
	var bucket_prefix: String = "%d:" % peer_id
	for key_value: Variant in _inbound_buckets.keys():
		var key: String = str(key_value)
		if key.begins_with(bucket_prefix):
			_inbound_buckets.erase(key_value)


func _reset_session_state() -> void:
	_inbound_buckets.clear()
	_last_sequences.clear()
	_outbound_sequences.clear()
	_violations.clear()
	_quarantined_peers.clear()
