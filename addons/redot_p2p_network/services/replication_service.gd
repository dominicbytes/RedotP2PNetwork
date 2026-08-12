class_name RedotP2PReplicationService
extends Node

signal entity_state_applied(entity_id: String, revision: int)
signal entity_despawned(entity_id: String)
signal replication_rejected(peer_id: int, entity_id: String, reason_code: String)

const INTENT_MESSAGE: String = "replication.intent"
const STATE_MESSAGE: String = "replication.state"
const DESPAWN_MESSAGE: String = "replication.despawn"
const REPLICATION_CHANNEL: int = 3
const MAX_WIRE_BYTES: int = 16_384
const MAX_ENTITIES: int = 1024

var _network: RedotP2PNetworkService = null
var _entities: Dictionary = {}
var _revisions: Dictionary = {}
var _intent_buckets: Dictionary = {}


func attach(network: RedotP2PNetworkService) -> Error:
	if network == null:
		return ERR_INVALID_PARAMETER
	if _network != null and _network != network:
		return ERR_ALREADY_IN_USE
	_network = network
	var definitions: Array[RedotP2PMessageDefinition] = [
		_definition(INTENT_MESSAGE, _on_intent, true, false, 64.0, 128),
		_definition(STATE_MESSAGE, _on_state, false, true, 128.0, 256),
		_definition(DESPAWN_MESSAGE, _on_despawn, false, true, 32.0, 64),
	]
	for definition: RedotP2PMessageDefinition in definitions:
		var register_error: Error = _network.register_message(definition)
		if register_error != OK and register_error != ERR_ALREADY_EXISTS:
			return register_error
	if not _network.peer_connected.is_connected(_on_peer_connected):
		_network.peer_connected.connect(_on_peer_connected)
	if not _network.peer_disconnected.is_connected(_on_peer_disconnected):
		_network.peer_disconnected.connect(_on_peer_disconnected)
	return OK


func register_entity(definition: RedotP2PReplicatedEntityDefinition) -> Error:
	if definition == null or definition.validate() != OK:
		return ERR_INVALID_PARAMETER
	if _entities.has(definition.entity_id):
		return ERR_ALREADY_EXISTS
	if _entities.size() >= MAX_ENTITIES:
		return ERR_OUT_OF_MEMORY
	_entities[definition.entity_id] = definition
	return OK


func unregister_entity(entity_id: String) -> bool:
	_revisions.erase(entity_id)
	return _entities.erase(entity_id)


func publish_entity(entity_id: String, target_peer: int = 0) -> Error:
	if not _is_authority():
		return ERR_UNAUTHORIZED
	var definition: RedotP2PReplicatedEntityDefinition = _get_entity(entity_id)
	if definition == null:
		return ERR_DOES_NOT_EXIST
	var state_value: Variant = definition.collect_state.call()
	if not state_value is Dictionary or not RedotP2PJsonValue.is_safe(state_value):
		return ERR_INVALID_DATA
	var state: Dictionary = state_value as Dictionary
	var revision: int = int(_revisions.get(entity_id, 0)) + 1
	var wire: Dictionary = {
		"entity_id": entity_id,
		"revision": str(revision),
		"state": state,
	}
	var payload: PackedByteArray = _encode_wire(wire, mini(MAX_WIRE_BYTES, definition.max_state_bytes + 256))
	if payload.is_empty():
		return ERR_INVALID_DATA
	var send_error: Error = _network.send_message(
		STATE_MESSAGE,
		payload,
		target_peer,
		REPLICATION_CHANNEL,
		_replication_delivery()
	)
	if send_error == OK:
		_revisions[entity_id] = revision
	return send_error


func submit_intent(entity_id: String, intent: Dictionary) -> Error:
	var definition: RedotP2PReplicatedEntityDefinition = _get_entity(entity_id)
	if definition == null or not definition.validate_intent.is_valid() or not RedotP2PJsonValue.is_safe(intent):
		return ERR_INVALID_PARAMETER
	if _is_authority():
		return _apply_intent(_network.get_local_peer_id(), definition, intent)
	var wire: Dictionary = {"entity_id": entity_id, "intent": intent}
	var payload: PackedByteArray = _encode_wire(wire, mini(MAX_WIRE_BYTES, definition.max_intent_bytes + 128))
	if payload.is_empty():
		return ERR_INVALID_DATA
	return _network.send_message(
		INTENT_MESSAGE,
		payload,
		1,
		REPLICATION_CHANNEL,
		_replication_delivery()
	)


func despawn_entity(entity_id: String) -> Error:
	if not _is_authority() or _get_entity(entity_id) == null:
		return ERR_UNAUTHORIZED
	var payload: PackedByteArray = entity_id.to_utf8_buffer()
	var send_error: Error = _network.send_message(
		DESPAWN_MESSAGE,
		payload,
		0,
		REPLICATION_CHANNEL,
		RedotP2PTransportAdapter.Delivery.RELIABLE
	)
	if send_error == OK:
		_apply_despawn(entity_id)
	return send_error


func _on_intent(peer_id: int, payload: PackedByteArray) -> void:
	if not _is_authority():
		return
	var wire: Dictionary = _decode_wire(payload)
	if wire.size() != 2 or not wire.has("entity_id") or not wire.has("intent"):
		_reject(peer_id, "", RedotP2PStatusCodes.MESSAGE_TYPE_INVALID)
		return
	var entity_id: String = str(wire["entity_id"])
	var definition: RedotP2PReplicatedEntityDefinition = _get_entity(entity_id)
	if definition == null or not wire["intent"] is Dictionary or not definition.validate_intent.is_valid():
		_reject(peer_id, entity_id, RedotP2PStatusCodes.MESSAGE_UNREGISTERED)
		return
	var intent: Dictionary = wire["intent"] as Dictionary
	if not RedotP2PJsonValue.is_safe(intent) or JSON.stringify(intent).to_utf8_buffer().size() > definition.max_intent_bytes:
		_reject(peer_id, entity_id, RedotP2PStatusCodes.PAYLOAD_TOO_LARGE)
		return
	if not _consume_intent_budget(peer_id, definition):
		_reject(peer_id, entity_id, RedotP2PStatusCodes.MESSAGE_RATE_LIMITED)
		return
	var apply_error: Error = _apply_intent(peer_id, definition, intent)
	if apply_error != OK:
		_reject(peer_id, entity_id, RedotP2PStatusCodes.MESSAGE_UNAUTHORIZED)


func _on_state(_peer_id: int, payload: PackedByteArray) -> void:
	if _is_authority():
		return
	var wire: Dictionary = _decode_wire(payload)
	if wire.size() != 3 or not wire.has("entity_id") or not wire.has("revision") or not wire.has("state"):
		return
	var entity_id: String = str(wire["entity_id"])
	var definition: RedotP2PReplicatedEntityDefinition = _get_entity(entity_id)
	if definition == null or not wire["revision"] is String or not _valid_positive_decimal(wire["revision"] as String):
		return
	if not wire["state"] is Dictionary or not RedotP2PJsonValue.is_safe(wire["state"]):
		return
	if JSON.stringify(wire["state"]).to_utf8_buffer().size() > definition.max_state_bytes:
		return
	var revision: int = int(wire["revision"])
	if revision <= int(_revisions.get(entity_id, 0)):
		return
	definition.apply_state.call((wire["state"] as Dictionary).duplicate(true))
	_revisions[entity_id] = revision
	entity_state_applied.emit(entity_id, revision)


func _on_despawn(_peer_id: int, payload: PackedByteArray) -> void:
	if _is_authority() or payload.is_empty() or payload.size() > 64:
		return
	var entity_id: String = payload.get_string_from_utf8()
	if entity_id.to_utf8_buffer() != payload or not RedotP2PReplicatedEntityDefinition._valid_entity_id(entity_id):
		return
	_apply_despawn(entity_id)


func _apply_intent(
	peer_id: int,
	definition: RedotP2PReplicatedEntityDefinition,
	intent: Dictionary
) -> Error:
	var validation_value: Variant = definition.validate_intent.call(peer_id, intent.duplicate(true))
	if not validation_value is bool or not bool(validation_value):
		return ERR_UNAUTHORIZED
	definition.apply_intent.call(peer_id, intent.duplicate(true))
	return OK


func _apply_despawn(entity_id: String) -> void:
	var definition: RedotP2PReplicatedEntityDefinition = _get_entity(entity_id)
	if definition == null:
		return
	if definition.despawn_handler.is_valid():
		definition.despawn_handler.call()
	_entities.erase(entity_id)
	_revisions.erase(entity_id)
	entity_despawned.emit(entity_id)


func _on_peer_connected(peer_id: int) -> void:
	if not _is_authority():
		return
	for entity_id_value: Variant in _entities.keys():
		publish_entity(str(entity_id_value), peer_id)


func _on_peer_disconnected(peer_id: int, _reason_code: String) -> void:
	var prefix: String = "%d:" % peer_id
	for key_value: Variant in _intent_buckets.keys():
		if str(key_value).begins_with(prefix):
			_intent_buckets.erase(key_value)


func _consume_intent_budget(peer_id: int, definition: RedotP2PReplicatedEntityDefinition) -> bool:
	var key: String = "%d:%s" % [peer_id, definition.entity_id]
	var bucket_value: Variant = _intent_buckets.get(key)
	var bucket: RedotP2PTokenBucket
	if bucket_value is RedotP2PTokenBucket:
		bucket = bucket_value as RedotP2PTokenBucket
	else:
		bucket = RedotP2PTokenBucket.new()
		if bucket.configure(definition.intent_rate, definition.intent_burst) != OK:
			return false
		_intent_buckets[key] = bucket
	return bucket.allow()


func _definition(
	message_type: String,
	handler: Callable,
	allow_from_client: bool,
	allow_from_authority: bool,
	rate: float,
	burst: int
) -> RedotP2PMessageDefinition:
	var definition: RedotP2PMessageDefinition = RedotP2PMessageDefinition.new()
	definition.message_type = message_type
	definition.handler = handler
	definition.max_payload_bytes = MAX_WIRE_BYTES
	definition.required_channel = REPLICATION_CHANNEL
	definition.required_delivery = (
		RedotP2PTransportAdapter.Delivery.RELIABLE
		if message_type == DESPAWN_MESSAGE
		else -1
	)
	definition.allow_from_client = allow_from_client
	definition.allow_from_authority = allow_from_authority
	definition.per_peer_rate = rate
	definition.per_peer_burst = burst
	return definition


func _encode_wire(wire: Dictionary, maximum_bytes: int) -> PackedByteArray:
	if not RedotP2PJsonValue.is_safe(wire):
		return PackedByteArray()
	var payload: PackedByteArray = JSON.stringify(wire).to_utf8_buffer()
	return payload if not payload.is_empty() and payload.size() <= maximum_bytes else PackedByteArray()


func _decode_wire(payload: PackedByteArray) -> Dictionary:
	if payload.is_empty() or payload.size() > MAX_WIRE_BYTES:
		return {}
	var text: String = payload.get_string_from_utf8()
	if text.to_utf8_buffer() != payload:
		return {}
	var decoded: Variant = JSON.parse_string(text)
	return decoded as Dictionary if decoded is Dictionary and RedotP2PJsonValue.is_safe(decoded) else {}


func _get_entity(entity_id: String) -> RedotP2PReplicatedEntityDefinition:
	var value: Variant = _entities.get(entity_id)
	return value as RedotP2PReplicatedEntityDefinition if value is RedotP2PReplicatedEntityDefinition else null


func _is_authority() -> bool:
	return _network != null and _network.is_authority()


func _replication_delivery() -> int:
	if _network != null and _network.get_transport_capabilities().supports_ordered_unreliable:
		return RedotP2PTransportAdapter.Delivery.UNRELIABLE_ORDERED
	return RedotP2PTransportAdapter.Delivery.RELIABLE


func _valid_positive_decimal(value: String) -> bool:
	if value.is_empty() or value.length() > 19 or value.begins_with("0"):
		return false
	for index: int in value.length():
		var codepoint: int = value.unicode_at(index)
		if codepoint < 0x30 or codepoint > 0x39:
			return false
	return int(value) > 0


func _reject(peer_id: int, entity_id: String, reason_code: String) -> void:
	replication_rejected.emit(peer_id, entity_id, reason_code)
