class_name RedotP2PCompatibilityLobby
extends Node

signal player_joined_lobby(network_id: int)
signal player_left_lobby(network_id: int)
signal lobby_created(lobby_id: int)
signal lobby_joined(lobby_id: int)
signal lobby_join_requested(lobby_id: int)
signal lobby_owner_changed(previous_owner: int, new_owner: int)
signal lobby_data_updated(network_id: int)
signal chat_message_received(from_network_id: int, message: String)
signal found_lobbies(lobbies: Array[LobbyData])
signal avatar_loaded(network_id: int)
signal lobby_error(reason_code: String)

const CHAT_REQUEST: String = "lobby.chat.request"
const CHAT_EVENT: String = "lobby.chat.event"
const CHAT_CHANNEL: int = 1
const CHAT_MAX_BYTES: int = 512
const LOBBY_SNAPSHOT: String = "lobby.snapshot"
const LOBBY_MEMBER_JOINED: String = "lobby.member.joined"
const LOBBY_MEMBER_LEFT: String = "lobby.member.left"
const LOBBY_SNAPSHOT_MAX_BYTES: int = 8192
const LOBBY_EVENT_MAX_BYTES: int = 32
const P2P_NETWORK_SCRIPT: Script = preload("res://addons/redot_p2p_network/compat/p2p_network.gd")

var _lobby: LobbyData = null
var _network: P2P_NETWORK_SCRIPT = null


func _ready() -> void:
	_network = get_node_or_null("/root/P2PNetwork") as P2P_NETWORK_SCRIPT
	if _network == null:
		lobby_error.emit(RedotP2PStatusCodes.INTERNAL_INVARIANT_FAILED)
		return
	_network.peer_connected.connect(_on_peer_connected)
	_network.peer_disconnected.connect(_on_peer_disconnected)
	_network.disconnect.connect(_clear_lobby)
	_register_chat_messages()
	_register_lobby_messages()


func get_self() -> NetPeer:
	return null if _network == null else _network.network_data.get_current_peer()


func get_id() -> int:
	var current_peer: NetPeer = get_self()
	return 0 if current_peer == null else current_peer.network_id


func create_lobby(lobby: LobbyData) -> bool:
	if lobby == null or lobby.max_memebers < 1 or lobby.lobby_name.to_utf8_buffer().size() > 96:
		return false
	if _is_network_active() and not _network.is_server():
		return false
	if not RedotP2PJsonValue.is_safe(lobby.meta) or JSON.stringify(lobby.meta).to_utf8_buffer().size() > 2048:
		return false
	if _lobby != null:
		return false
	_lobby = lobby
	if _lobby.lobby_id <= 0:
		_lobby.lobby_id = int(Time.get_ticks_usec() & 0x7FFFFFFF)
	var current_peer: NetPeer = get_self()
	if current_peer != null:
		_lobby.set_self(current_peer)
		_lobby.set_lobby_owner(current_peer)
	lobby_created.emit(_lobby.lobby_id)
	lobby_joined.emit(_lobby.lobby_id)
	if _is_network_active():
		_broadcast_lobby_snapshot()
	return true


func join_lobby(lobby_id: int) -> bool:
	if _lobby == null or _lobby.lobby_id != lobby_id:
		lobby_error.emit(RedotP2PStatusCodes.PROVIDER_UNAVAILABLE)
		return false
	lobby_joined.emit(lobby_id)
	return true


func leave_lobby() -> void:
	_clear_lobby(true)


func _clear_lobby(stop_session: bool = false) -> void:
	if _lobby == null:
		return
	var member_ids: Array[int] = []
	for member_id_value: Variant in _lobby.get_members().keys():
		member_ids.append(int(member_id_value))
	_lobby = null
	if stop_session and _network != null:
		_network.stop()
	for member_id: int in member_ids:
		player_left_lobby.emit(member_id)


func get_lobby_id() -> int:
	return 0 if _lobby == null else _lobby.lobby_id


func in_lobby() -> bool:
	return _lobby != null


func get_lobby_member(id: int) -> NetPeer:
	return null if _lobby == null else _lobby.get_member(id)


func get_lobby_members() -> Dictionary:
	return {} if _lobby == null else _lobby.get_members()


func get_lobby_list() -> void:
	var lobbies: Array[LobbyData] = []
	if _lobby != null:
		lobbies.append(_lobby)
	found_lobbies.emit(lobbies)


func get_owner_id() -> int:
	if _lobby == null or _lobby.get_lobby_owner() == null:
		return 0
	return _lobby.get_lobby_owner().network_id


func is_lobby_owner() -> bool:
	var current_peer: NetPeer = get_self()
	return current_peer != null and current_peer.network_id == get_owner_id()


func send_message(message: String, to: int = -1) -> bool:
	if _lobby == null:
		return false
	var message_bytes: PackedByteArray = _encode_chat_text(message)
	if message_bytes.is_empty():
		return false
	if _network == null:
		return false
	if _network.is_server():
		var sender_id: int = _network.get_network_id()
		_broadcast_chat(sender_id, message_bytes, to)
		return true
	var send_error: Error = _network.send_message(
		CHAT_REQUEST,
		message_bytes,
		1,
		CHAT_CHANNEL,
		RedotP2PTransportAdapter.Delivery.RELIABLE
	)
	return send_error == OK


func _register_chat_messages() -> void:
	if _network == null:
		return
	var request_error: Error = _network.register_message(
		CHAT_REQUEST,
		_on_chat_request,
		CHAT_MAX_BYTES,
		true,
		false,
		CHAT_CHANNEL,
		RedotP2PTransportAdapter.Delivery.RELIABLE,
		2.0,
		4
	)
	if request_error != OK and request_error != ERR_ALREADY_EXISTS:
		lobby_error.emit(RedotP2PStatusCodes.INTERNAL_INVARIANT_FAILED)
	var event_error: Error = _network.register_message(
		CHAT_EVENT,
		_on_chat_event,
		CHAT_MAX_BYTES + 4,
		false,
		true,
		CHAT_CHANNEL,
		RedotP2PTransportAdapter.Delivery.RELIABLE,
		16.0,
		32
	)
	if event_error != OK and event_error != ERR_ALREADY_EXISTS:
		lobby_error.emit(RedotP2PStatusCodes.INTERNAL_INVARIANT_FAILED)


func _register_lobby_messages() -> void:
	if _network == null:
		return
	var snapshot_error: Error = _network.register_message(
		LOBBY_SNAPSHOT,
		_on_lobby_snapshot,
		LOBBY_SNAPSHOT_MAX_BYTES,
		false,
		true,
		CHAT_CHANNEL,
		RedotP2PTransportAdapter.Delivery.RELIABLE,
		2.0,
		4
	)
	var joined_error: Error = _network.register_message(
		LOBBY_MEMBER_JOINED,
		_on_lobby_member_joined,
		LOBBY_EVENT_MAX_BYTES,
		false,
		true,
		CHAT_CHANNEL,
		RedotP2PTransportAdapter.Delivery.RELIABLE,
		16.0,
		32
	)
	var left_error: Error = _network.register_message(
		LOBBY_MEMBER_LEFT,
		_on_lobby_member_left,
		LOBBY_EVENT_MAX_BYTES,
		false,
		true,
		CHAT_CHANNEL,
		RedotP2PTransportAdapter.Delivery.RELIABLE,
		16.0,
		32
	)
	for register_error: Error in [snapshot_error, joined_error, left_error]:
		if register_error != OK and register_error != ERR_ALREADY_EXISTS:
			lobby_error.emit(RedotP2PStatusCodes.INTERNAL_INVARIANT_FAILED)


func _on_chat_request(sender_id: int, payload: PackedByteArray) -> void:
	if _network == null or not _network.is_server() or _lobby == null or _lobby.get_member(sender_id) == null:
		return
	var text: String = _decode_chat_text(payload)
	if text.is_empty():
		return
	_broadcast_chat(sender_id, payload)


func _broadcast_chat(sender_id: int, text_bytes: PackedByteArray, target_peer: int = -1) -> void:
	var event_payload: PackedByteArray = PackedByteArray()
	event_payload.resize(4 + text_bytes.size())
	event_payload.encode_u32(0, sender_id)
	for index: int in text_bytes.size():
		event_payload[4 + index] = text_bytes[index]
	var target: int = 0 if target_peer < 0 else target_peer
	if _network == null:
		return
	_network.send_message(
		CHAT_EVENT,
		event_payload,
		target,
		CHAT_CHANNEL,
		RedotP2PTransportAdapter.Delivery.RELIABLE
	)
	chat_message_received.emit(sender_id, text_bytes.get_string_from_utf8())


func _on_chat_event(_transport_sender_id: int, payload: PackedByteArray) -> void:
	if _network == null or _network.is_server() or payload.size() < 5 or payload.size() > CHAT_MAX_BYTES + 4:
		return
	var sender_id: int = payload.decode_u32(0)
	var text_bytes: PackedByteArray = payload.slice(4)
	var text: String = _decode_chat_text(text_bytes)
	if text.is_empty():
		return
	chat_message_received.emit(sender_id, text)


func _on_peer_connected(peer_id: int) -> void:
	if _lobby == null:
		return
	if _network == null:
		return
	if not _network.is_server():
		return
	var peer: NetPeer = _network.network_data.get_peer(peer_id)
	if peer != null and _lobby.join(peer):
		player_joined_lobby.emit(peer_id)
		lobby_data_updated.emit(peer_id)
		_send_lobby_member_event(LOBBY_MEMBER_JOINED, peer_id, 0)
		_broadcast_lobby_snapshot(peer_id)


func _on_peer_disconnected(peer_id: int, _reason_code: String) -> void:
	if _lobby == null:
		return
	var member: NetPeer = _lobby.get_member(peer_id)
	if member != null and _lobby.leave(member):
		player_left_lobby.emit(peer_id)
		lobby_data_updated.emit(peer_id)
		if _network != null and _network.is_server():
			_send_lobby_member_event(LOBBY_MEMBER_LEFT, peer_id, 0)


func _broadcast_lobby_snapshot(target_peer: int = 0) -> void:
	if _network == null or not _network.is_server() or _lobby == null:
		return
	var member_ids: Array[String] = []
	for member_id_value: Variant in _lobby.get_members().keys():
		member_ids.append(str(int(member_id_value)))
	member_ids.sort()
	var snapshot: Dictionary = {
		"lobby_id": str(_lobby.lobby_id),
		"name": _lobby.lobby_name,
		"visibility": str(_lobby.visablity),
		"max_members": str(_lobby.max_memebers),
		"min_members": str(_lobby.min_members),
		"auto_start": str(_lobby.auto_start),
		"owner_id": str(get_owner_id()),
		"members": member_ids,
		"meta": _lobby.meta,
	}
	var payload: PackedByteArray = JSON.stringify(snapshot).to_utf8_buffer()
	if payload.is_empty() or payload.size() > LOBBY_SNAPSHOT_MAX_BYTES:
		lobby_error.emit(RedotP2PStatusCodes.CAPACITY_EXCEEDED)
		return
	_network.send_message(
		LOBBY_SNAPSHOT,
		payload,
		target_peer,
		CHAT_CHANNEL,
		RedotP2PTransportAdapter.Delivery.RELIABLE
	)


func _on_lobby_snapshot(_peer_id: int, payload: PackedByteArray) -> void:
	if _network == null or _network.is_server():
		return
	var snapshot: Dictionary = _decode_json_dictionary(payload, LOBBY_SNAPSHOT_MAX_BYTES)
	if not _valid_lobby_snapshot(snapshot):
		return
	var lobby_id: int = int(snapshot["lobby_id"])
	var previous_owner: int = get_owner_id()
	var received_lobby: LobbyData = LobbyData.new(
		lobby_id,
		str(snapshot["name"]),
		int(snapshot["visibility"]),
		int(snapshot["max_members"]),
		int(snapshot["min_members"]),
		int(snapshot["auto_start"]),
		(snapshot["meta"] as Dictionary).duplicate(true)
	)
	var self_peer: NetPeer = get_self()
	if self_peer != null:
		received_lobby.set_self(self_peer)
	for member_id_value: Variant in snapshot["members"] as Array:
		var member_id: int = int(member_id_value)
		var member: NetPeer = _network.network_data.get_peer(member_id)
		if member == null:
			member = NetPeer.new(member_id)
			member.connected = true
			member.host = member_id == 1
			_network.network_data.set_peer(member)
		received_lobby.set_member(member)
	var owner_id: int = int(snapshot["owner_id"])
	var owner: NetPeer = received_lobby.get_member(owner_id)
	if owner != null:
		received_lobby.set_lobby_owner(owner)
	var was_in_lobby: bool = _lobby != null and _lobby.lobby_id == lobby_id
	_lobby = received_lobby
	if not was_in_lobby:
		lobby_joined.emit(lobby_id)
	if previous_owner != owner_id:
		lobby_owner_changed.emit(previous_owner, owner_id)
	lobby_data_updated.emit(owner_id)


func _on_lobby_member_joined(_peer_id: int, payload: PackedByteArray) -> void:
	if _network == null or _network.is_server() or _lobby == null:
		return
	var member_id: int = _decode_peer_id(payload)
	if member_id <= 0 or _lobby.get_member(member_id) != null:
		return
	var member: NetPeer = _network.network_data.get_peer(member_id)
	if member == null:
		member = NetPeer.new(member_id)
		member.connected = true
		_network.network_data.set_peer(member)
	if _lobby.join(member):
		player_joined_lobby.emit(member_id)
		lobby_data_updated.emit(member_id)


func _on_lobby_member_left(_peer_id: int, payload: PackedByteArray) -> void:
	if _network == null or _network.is_server() or _lobby == null:
		return
	var member_id: int = _decode_peer_id(payload)
	var member: NetPeer = _lobby.get_member(member_id)
	if member != null and _lobby.leave(member):
		member.connected = false
		_network.network_data.remove_peer(member_id)
		player_left_lobby.emit(member_id)
		lobby_data_updated.emit(member_id)


func _send_lobby_member_event(message_type: String, peer_id: int, target_peer: int) -> void:
	if _network == null or not _network.is_server() or peer_id <= 0:
		return
	_network.send_message(
		message_type,
		str(peer_id).to_utf8_buffer(),
		target_peer,
		CHAT_CHANNEL,
		RedotP2PTransportAdapter.Delivery.RELIABLE
	)


func _decode_peer_id(payload: PackedByteArray) -> int:
	if payload.is_empty() or payload.size() > LOBBY_EVENT_MAX_BYTES:
		return 0
	var text: String = payload.get_string_from_utf8()
	if text.to_utf8_buffer() != payload or not _is_decimal(text, false):
		return 0
	return int(text)


func _decode_json_dictionary(payload: PackedByteArray, maximum_bytes: int) -> Dictionary:
	if payload.is_empty() or payload.size() > maximum_bytes:
		return {}
	var text: String = payload.get_string_from_utf8()
	if text.to_utf8_buffer() != payload:
		return {}
	var decoded: Variant = JSON.parse_string(text)
	if not decoded is Dictionary or not RedotP2PJsonValue.is_safe(decoded):
		return {}
	return decoded as Dictionary


func _valid_lobby_snapshot(snapshot: Dictionary) -> bool:
	var expected_keys: Array[String] = [
		"lobby_id", "name", "visibility", "max_members", "min_members",
		"auto_start", "owner_id", "members", "meta",
	]
	if snapshot.size() != expected_keys.size():
		return false
	for key: String in expected_keys:
		if not snapshot.has(key):
			return false
	if not snapshot["name"] is String or (snapshot["name"] as String).to_utf8_buffer().size() > 96:
		return false
	for key: String in ["lobby_id", "visibility", "max_members", "min_members", "owner_id"]:
		if not snapshot[key] is String or not _is_decimal(snapshot[key] as String, key == "visibility"):
			return false
	if not snapshot["auto_start"] is String or not _is_signed_decimal(snapshot["auto_start"] as String):
		return false
	if int(snapshot["max_members"]) < 1 or int(snapshot["max_members"]) > 128:
		return false
	if int(snapshot["min_members"]) < 1 or int(snapshot["min_members"]) > int(snapshot["max_members"]):
		return false
	if not snapshot["members"] is Array or (snapshot["members"] as Array).size() > int(snapshot["max_members"]):
		return false
	for member_id: Variant in snapshot["members"] as Array:
		if not member_id is String or not _is_decimal(member_id as String, false):
			return false
	return snapshot["meta"] is Dictionary and RedotP2PJsonValue.is_safe(snapshot["meta"])


func _is_decimal(value: String, allow_zero: bool) -> bool:
	if value.is_empty() or value.length() > 19 or (value.length() > 1 and value.begins_with("0")):
		return false
	for index: int in value.length():
		var codepoint: int = value.unicode_at(index)
		if codepoint < 0x30 or codepoint > 0x39:
			return false
	var parsed: int = int(value)
	return parsed >= 0 if allow_zero else parsed > 0


func _is_signed_decimal(value: String) -> bool:
	if value.begins_with("-"):
		return value == "-1"
	return _is_decimal(value, true)


func _is_network_active() -> bool:
	if _network == null or _network.get_service() == null:
		return false
	var transport: RedotP2PTransportAdapter = _network.get_service().get_transport()
	return transport != null and transport.get_state() not in [
		RedotP2PTransportAdapter.State.STOPPED,
		RedotP2PTransportAdapter.State.FAILED,
	]


func _encode_chat_text(message: String) -> PackedByteArray:
	var normalized: String = message.strip_edges()
	if normalized.is_empty() or _contains_nul(normalized):
		return PackedByteArray()
	var bytes: PackedByteArray = normalized.to_utf8_buffer()
	if bytes.size() > CHAT_MAX_BYTES:
		return PackedByteArray()
	return bytes


func _decode_chat_text(payload: PackedByteArray) -> String:
	if payload.is_empty() or payload.size() > CHAT_MAX_BYTES:
		return ""
	var text: String = payload.get_string_from_utf8()
	if text.to_utf8_buffer() != payload or _contains_nul(text):
		return ""
	return text.strip_edges()


func _contains_nul(text: String) -> bool:
	for index: int in text.length():
		if text.unicode_at(index) == 0:
			return true
	return false
