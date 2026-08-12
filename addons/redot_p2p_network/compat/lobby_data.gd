class_name LobbyData
extends RefCounted

var lobby_id: int = 0
var lobby_name: String = "default"
var lobby_mode: String = "default"
var max_memebers: int = 4
var min_members: int = 1
var current_members: int = 0
var auto_start: int = -1
var visablity: int = 0
var meta: Dictionary = {}

var _my_self: NetPeer = null
var _lobby_host: NetPeer = null
var _members: Dictionary = {}


func _init(
	id: int = 0,
	name: String = "default",
	visibility: int = 0,
	max_members: int = 4,
	minimum_members: int = 1,
	auto_start_count: int = -1,
	lobby_meta: Dictionary = {}
) -> void:
	lobby_id = id
	lobby_name = name.left(96)
	visablity = visibility
	max_memebers = clampi(max_members, 1, 128)
	min_members = clampi(minimum_members, 1, max_memebers)
	auto_start = auto_start_count
	meta = lobby_meta.duplicate(true)


func send_data() -> void:
	pass


func can_start_game() -> bool:
	return _members.size() >= min_members


func join(member: NetPeer) -> bool:
	if member == null or _members.size() >= max_memebers:
		return false
	return set_member(member)


func leave(member: NetPeer) -> bool:
	if member == null:
		return false
	var removed: bool = _members.erase(member.network_id)
	current_members = _members.size()
	if _lobby_host != null and _lobby_host.network_id == member.network_id:
		_lobby_host = null
	return removed


func is_ready() -> bool:
	if not can_start_game():
		return false
	for peer_value: Variant in _members.values():
		if not peer_value is NetPeer:
			return false
		var member: NetPeer = peer_value as NetPeer
		if not member.connected or member.status < NetPeer.ConnectionStatus.READY:
			return false
	return true


func add_meta_value(key: String, value: Variant) -> bool:
	if not _valid_meta_key(key) or meta.has(key) or meta.size() >= 32:
		return false
	meta[key] = value
	return true


func set_meta_value(key: String, value: Variant) -> bool:
	if not _valid_meta_key(key) or (not meta.has(key) and meta.size() >= 32):
		return false
	meta[key] = value
	return true


func get_member(id: int) -> NetPeer:
	var member_value: Variant = _members.get(id)
	return member_value as NetPeer if member_value is NetPeer else null


func update_lobby_members() -> void:
	current_members = _members.size()


func set_lobby_owner(member: NetPeer) -> bool:
	if member == null:
		return false
	_lobby_host = member
	member.host = true
	return set_member(member)


func get_lobby_owner() -> NetPeer:
	return _lobby_host


func get_self() -> NetPeer:
	return _my_self


func set_self(member: NetPeer) -> void:
	_my_self = member
	if member != null:
		set_member(member)


func set_member(member: NetPeer) -> bool:
	if member == null or member.network_id <= 0:
		return false
	if not _members.has(member.network_id) and _members.size() >= max_memebers:
		return false
	_members[member.network_id] = member
	current_members = _members.size()
	return true


func get_members() -> Dictionary:
	return _members.duplicate()


func string() -> String:
	return "[%s] %s \t(%d/%d)" % [lobby_mode, lobby_name, current_members, max_memebers]


func _valid_meta_key(key: String) -> bool:
	var bytes: PackedByteArray = key.to_utf8_buffer()
	return not bytes.is_empty() and bytes.size() <= 64
