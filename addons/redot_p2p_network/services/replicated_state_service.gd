class_name RedotP2PReplicatedStateService
extends Node

signal player_data_updated(peer_id: int, key: String)
signal game_data_updated(key: String)
signal state_rejected(peer_id: int, reason_code: String)

const PLAYER_REQUEST: String = "state.player.request"
const PLAYER_DELTA: String = "state.player.delta"
const GAME_DELTA: String = "state.game.delta"
const SNAPSHOT: String = "state.snapshot"
const STATE_CHANNEL: int = 2
const MAX_DELTA_BYTES: int = 4096
const MAX_SNAPSHOT_BYTES: int = 49_152
const MAX_GAME_KEYS: int = 128
const MAX_PLAYER_KEYS: int = 32
const MAX_TOTAL_PLAYER_KEYS: int = 4096

var _network: RedotP2PNetworkService = null
var _game_data: Dictionary = {}
var _player_data: Dictionary = {}
var _revisions: Dictionary = {}


func attach(network: RedotP2PNetworkService) -> Error:
	if network == null:
		return ERR_INVALID_PARAMETER
	if _network != null and _network != network:
		return ERR_ALREADY_IN_USE
	_network = network
	var definitions: Array[RedotP2PMessageDefinition] = [
		_definition(PLAYER_REQUEST, _on_player_request, MAX_DELTA_BYTES, true, false, 8.0, 16),
		_definition(PLAYER_DELTA, _on_player_delta, MAX_DELTA_BYTES, false, true, 32.0, 64),
		_definition(GAME_DELTA, _on_game_delta, MAX_DELTA_BYTES, false, true, 16.0, 32),
		_definition(SNAPSHOT, _on_snapshot, MAX_SNAPSHOT_BYTES, false, true, 1.0, 2),
	]
	for definition: RedotP2PMessageDefinition in definitions:
		var register_error: Error = _network.register_message(definition)
		if register_error != OK and register_error != ERR_ALREADY_EXISTS:
			return register_error
	if not _network.peer_connected.is_connected(_on_peer_connected):
		_network.peer_connected.connect(_on_peer_connected)
	return OK


func set_game_data(key: String, value: Variant) -> Error:
	if not _valid_key_value(key, value):
		return ERR_INVALID_PARAMETER
	if not _is_local_authority():
		return ERR_UNAUTHORIZED
	if not _game_data.has(key) and _game_data.size() >= MAX_GAME_KEYS:
		return ERR_OUT_OF_MEMORY
	var next_revision: int = _next_revision("g:%s" % key)
	var delta: Dictionary = {"key": key, "value": value, "revision": str(next_revision)}
	if not _would_fit_state("game", 0, key, value):
		return ERR_OUT_OF_MEMORY
	_apply_game_delta(delta)
	if _is_network_active():
		return _send_json(GAME_DELTA, delta, 0, MAX_DELTA_BYTES)
	return OK


func set_player_data(key: String, value: Variant) -> Error:
	if not _valid_key_value(key, value) or _network == null:
		return ERR_INVALID_PARAMETER
	var local_peer_id: int = _network.get_local_peer_id()
	if not _is_network_active():
		local_peer_id = 0
	if _is_local_authority():
		return _set_authoritative_player_data(local_peer_id, key, value)
	var request: Dictionary = {"key": key, "value": value}
	return _send_json(PLAYER_REQUEST, request, 1, MAX_DELTA_BYTES)


func get_game_data(key: String, default_value: Variant = null) -> Variant:
	return _game_data.get(key, default_value)


func get_player_data(peer_id: int, key: String, default_value: Variant = null) -> Variant:
	var peer_value: Variant = _player_data.get(peer_id)
	if not peer_value is Dictionary:
		return default_value
	return (peer_value as Dictionary).get(key, default_value)


func get_game_snapshot() -> Dictionary:
	return _game_data.duplicate(true)


func get_player_snapshot() -> Dictionary:
	return _player_data.duplicate(true)


func reset() -> void:
	_game_data.clear()
	_player_data.clear()
	_revisions.clear()


func _set_authoritative_player_data(peer_id: int, key: String, value: Variant) -> Error:
	var peer_state: Dictionary = _get_player_state(peer_id)
	if not peer_state.has(key) and peer_state.size() >= MAX_PLAYER_KEYS:
		return ERR_OUT_OF_MEMORY
	if not peer_state.has(key) and _total_player_keys() >= MAX_TOTAL_PLAYER_KEYS:
		return ERR_OUT_OF_MEMORY
	if not _would_fit_state("player", peer_id, key, value):
		return ERR_OUT_OF_MEMORY
	var revision_key: String = "p:%d:%s" % [peer_id, key]
	var delta: Dictionary = {
		"peer_id": str(peer_id),
		"key": key,
		"value": value,
		"revision": str(_next_revision(revision_key)),
	}
	_apply_player_delta(delta)
	if _is_network_active():
		return _send_json(PLAYER_DELTA, delta, 0, MAX_DELTA_BYTES)
	return OK


func _on_player_request(peer_id: int, payload: PackedByteArray) -> void:
	if not _is_local_authority():
		return
	var request: Dictionary = _decode_dictionary(payload, MAX_DELTA_BYTES)
	if request.size() != 2 or not request.has("key") or not request.has("value"):
		state_rejected.emit(peer_id, RedotP2PStatusCodes.MESSAGE_TYPE_INVALID)
		return
	var key: String = str(request.get("key", ""))
	var value: Variant = request.get("value")
	if not _valid_key_value(key, value):
		state_rejected.emit(peer_id, RedotP2PStatusCodes.MESSAGE_TYPE_INVALID)
		return
	var update_error: Error = _set_authoritative_player_data(peer_id, key, value)
	if update_error != OK:
		state_rejected.emit(peer_id, RedotP2PStatusCodes.CAPACITY_EXCEEDED)


func _on_player_delta(_peer_id: int, payload: PackedByteArray) -> void:
	if _is_local_authority():
		return
	var delta: Dictionary = _decode_dictionary(payload, MAX_DELTA_BYTES)
	if _valid_player_delta(delta):
		_apply_player_delta(delta)


func _on_game_delta(_peer_id: int, payload: PackedByteArray) -> void:
	if _is_local_authority():
		return
	var delta: Dictionary = _decode_dictionary(payload, MAX_DELTA_BYTES)
	if _valid_game_delta(delta):
		_apply_game_delta(delta)


func _on_snapshot(_peer_id: int, payload: PackedByteArray) -> void:
	if _is_local_authority():
		return
	var snapshot: Dictionary = _decode_dictionary(payload, MAX_SNAPSHOT_BYTES)
	if snapshot.size() != 3 or not snapshot.has("game") or not snapshot.has("players") or not snapshot.has("revisions"):
		return
	var game_value: Variant = snapshot["game"]
	var players_value: Variant = snapshot["players"]
	var revisions_value: Variant = snapshot["revisions"]
	if not game_value is Dictionary or not players_value is Dictionary or not revisions_value is Dictionary:
		return
	if not RedotP2PJsonValue.is_safe(game_value) or not RedotP2PJsonValue.is_safe(players_value) or not RedotP2PJsonValue.is_safe(revisions_value):
		return
	_game_data = (game_value as Dictionary).duplicate(true)
	_player_data.clear()
	for peer_key: Variant in (players_value as Dictionary).keys():
		if not peer_key is String or not _is_decimal_string(peer_key as String, true):
			reset()
			return
		_player_data[int(peer_key)] = (players_value as Dictionary)[peer_key]
	_revisions.clear()
	for revision_key: Variant in (revisions_value as Dictionary).keys():
		var revision_value: Variant = (revisions_value as Dictionary)[revision_key]
		if not revision_key is String or not revision_value is String or not _is_decimal_string(revision_value as String, false):
			reset()
			return
		_revisions[revision_key] = int(revision_value)


func _on_peer_connected(peer_id: int) -> void:
	if not _is_local_authority():
		return
	var players_wire: Dictionary = {}
	for peer_id_value: Variant in _player_data.keys():
		players_wire[str(int(peer_id_value))] = _player_data[peer_id_value]
	var revisions_wire: Dictionary = {}
	for revision_key: Variant in _revisions.keys():
		revisions_wire[str(revision_key)] = str(int(_revisions[revision_key]))
	var snapshot: Dictionary = {
		"game": _game_data,
		"players": players_wire,
		"revisions": revisions_wire,
	}
	_send_json(SNAPSHOT, snapshot, peer_id, MAX_SNAPSHOT_BYTES)


func _apply_player_delta(delta: Dictionary) -> void:
	if not _valid_player_delta(delta):
		return
	var peer_id: int = int(delta["peer_id"])
	var key: String = str(delta["key"])
	var revision: int = int(delta["revision"])
	var revision_key: String = "p:%d:%s" % [peer_id, key]
	if revision <= int(_revisions.get(revision_key, 0)):
		return
	var peer_state: Dictionary = _get_player_state(peer_id)
	peer_state[key] = delta["value"]
	_player_data[peer_id] = peer_state
	_revisions[revision_key] = revision
	player_data_updated.emit(peer_id, key)


func _apply_game_delta(delta: Dictionary) -> void:
	if not _valid_game_delta(delta):
		return
	var key: String = str(delta["key"])
	var revision: int = int(delta["revision"])
	var revision_key: String = "g:%s" % key
	if revision <= int(_revisions.get(revision_key, 0)):
		return
	_game_data[key] = delta["value"]
	_revisions[revision_key] = revision
	game_data_updated.emit(key)


func _valid_player_delta(delta: Dictionary) -> bool:
	if delta.size() != 4 or not delta.has("peer_id") or not delta.has("key") or not delta.has("value") or not delta.has("revision"):
		return false
	return (
		delta["peer_id"] is String
		and _is_decimal_string(delta["peer_id"] as String, true)
		and delta["revision"] is String
		and _is_decimal_string(delta["revision"] as String, false)
		and _valid_key_value(str(delta["key"]), delta["value"])
	)


func _valid_game_delta(delta: Dictionary) -> bool:
	if delta.size() != 3 or not delta.has("key") or not delta.has("value") or not delta.has("revision"):
		return false
	return (
		delta["revision"] is String
		and _is_decimal_string(delta["revision"] as String, false)
		and _valid_key_value(str(delta["key"]), delta["value"])
	)


func _definition(
	message_type: String,
	handler: Callable,
	max_payload: int,
	allow_from_client: bool,
	allow_from_authority: bool,
	rate: float,
	burst: int
) -> RedotP2PMessageDefinition:
	var definition: RedotP2PMessageDefinition = RedotP2PMessageDefinition.new()
	definition.message_type = message_type
	definition.handler = handler
	definition.max_payload_bytes = max_payload
	definition.required_channel = STATE_CHANNEL
	definition.required_delivery = RedotP2PTransportAdapter.Delivery.RELIABLE
	definition.allow_from_client = allow_from_client
	definition.allow_from_authority = allow_from_authority
	definition.per_peer_rate = rate
	definition.per_peer_burst = burst
	return definition


func _send_json(message_type: String, data: Dictionary, peer_id: int, maximum_bytes: int) -> Error:
	var payload: PackedByteArray = JSON.stringify(data).to_utf8_buffer()
	if payload.is_empty() or payload.size() > maximum_bytes:
		return ERR_OUT_OF_MEMORY
	return _network.send_message(
		message_type,
		payload,
		peer_id,
		STATE_CHANNEL,
		RedotP2PTransportAdapter.Delivery.RELIABLE
	)


func _decode_dictionary(payload: PackedByteArray, maximum_bytes: int) -> Dictionary:
	if payload.is_empty() or payload.size() > maximum_bytes:
		return {}
	var text: String = payload.get_string_from_utf8()
	if text.to_utf8_buffer() != payload:
		return {}
	var decoded: Variant = JSON.parse_string(text)
	if not decoded is Dictionary or not RedotP2PJsonValue.is_safe(decoded):
		return {}
	return decoded as Dictionary


func _would_fit_state(kind: String, peer_id: int, key: String, value: Variant) -> bool:
	var game_copy: Dictionary = _game_data.duplicate(true)
	var player_copy: Dictionary = _player_data.duplicate(true)
	if kind == "game":
		game_copy[key] = value
	else:
		var peer_state: Dictionary = {}
		var peer_value: Variant = player_copy.get(peer_id)
		if peer_value is Dictionary:
			peer_state = (peer_value as Dictionary).duplicate(true)
		peer_state[key] = value
		player_copy[peer_id] = peer_state
	var players_wire: Dictionary = {}
	for peer_id_value: Variant in player_copy.keys():
		players_wire[str(int(peer_id_value))] = player_copy[peer_id_value]
	var revisions_wire: Dictionary = {}
	for revision_key: Variant in _revisions.keys():
		revisions_wire[str(revision_key)] = str(int(_revisions[revision_key]))
	var candidate: Dictionary = {"game": game_copy, "players": players_wire, "revisions": revisions_wire}
	return JSON.stringify(candidate).to_utf8_buffer().size() <= MAX_SNAPSHOT_BYTES


func _valid_key_value(key: String, value: Variant) -> bool:
	return RedotP2PJsonValue._valid_key(key) and RedotP2PJsonValue.is_safe(value)


func _get_player_state(peer_id: int) -> Dictionary:
	var value: Variant = _player_data.get(peer_id)
	return (value as Dictionary).duplicate(true) if value is Dictionary else {}


func _total_player_keys() -> int:
	var total: int = 0
	for value: Variant in _player_data.values():
		if value is Dictionary:
			total += (value as Dictionary).size()
	return total


func _next_revision(key: String) -> int:
	return int(_revisions.get(key, 0)) + 1


func _is_decimal_string(value: String, allow_zero: bool) -> bool:
	if value.is_empty() or value.length() > 19 or (value.length() > 1 and value.begins_with("0")):
		return false
	for index: int in value.length():
		var codepoint: int = value.unicode_at(index)
		if codepoint < 0x30 or codepoint > 0x39:
			return false
	var parsed: int = int(value)
	return parsed >= 0 if allow_zero else parsed > 0


func _is_network_active() -> bool:
	if _network == null or _network.get_transport() == null:
		return false
	return _network.get_transport().get_state() not in [
		RedotP2PTransportAdapter.State.STOPPED,
		RedotP2PTransportAdapter.State.FAILED,
	]


func _is_local_authority() -> bool:
	return _network != null and (not _is_network_active() or _network.is_authority())
