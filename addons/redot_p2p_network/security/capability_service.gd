class_name RedotP2PCapabilityService
extends Node

signal role_changed(peer_id: int, previous_role: String, current_role: String)
signal capability_changed(peer_id: int, capability: String, granted: bool)

const ROLE_OWNER: String = "owner"
const ROLE_MODERATOR: String = "moderator"
const ROLE_PLAYER: String = "player"
const ROLE_SPECTATOR: String = "spectator"
const MAX_CUSTOM_CAPABILITIES_PER_PEER: int = 64

const ROLE_CAPABILITIES: Dictionary = {
	ROLE_OWNER: ["*"],
	ROLE_MODERATOR: [
		"chat.mute", "peer.kick", "report.review", "session.ban", "session.rate_limit",
	],
	ROLE_PLAYER: ["chat.send", "personal.block", "report.submit", "state.player.write"],
	ROLE_SPECTATOR: ["personal.block", "report.submit"],
}

var _network: RedotP2PNetworkService = null
var _roles: Dictionary = {}
var _custom_capabilities: Dictionary = {}


func attach(network: RedotP2PNetworkService) -> Error:
	if network == null:
		return ERR_INVALID_PARAMETER
	if _network != null and _network != network:
		return ERR_ALREADY_IN_USE
	_network = network
	_network.set_capability_checker(has_capability)
	if not _network.peer_connected.is_connected(_on_peer_connected):
		_network.peer_connected.connect(_on_peer_connected)
	if not _network.peer_disconnected.is_connected(_on_peer_disconnected):
		_network.peer_disconnected.connect(_on_peer_disconnected)
	_roles[1] = ROLE_OWNER
	return OK


func get_role(peer_id: int) -> String:
	return str(_roles.get(peer_id, ROLE_PLAYER))


func assign_role(peer_id: int, role: String) -> Error:
	if not _can_manage() or peer_id <= 0 or not ROLE_CAPABILITIES.has(role):
		return ERR_UNAUTHORIZED
	if peer_id == 1 and role != ROLE_OWNER:
		return ERR_UNAUTHORIZED
	var previous: String = get_role(peer_id)
	if previous == role:
		return OK
	_roles[peer_id] = role
	role_changed.emit(peer_id, previous, role)
	return OK


func grant_capability(peer_id: int, capability: String) -> Error:
	if not _can_manage() or peer_id <= 0 or not _valid_capability(capability) or capability == "*":
		return ERR_UNAUTHORIZED
	var capabilities: Dictionary = _get_custom_capabilities(peer_id)
	if not capabilities.has(capability) and capabilities.size() >= MAX_CUSTOM_CAPABILITIES_PER_PEER:
		return ERR_OUT_OF_MEMORY
	capabilities[capability] = true
	_custom_capabilities[peer_id] = capabilities
	capability_changed.emit(peer_id, capability, true)
	return OK


func revoke_capability(peer_id: int, capability: String) -> bool:
	if not _can_manage() or peer_id <= 0:
		return false
	var capabilities: Dictionary = _get_custom_capabilities(peer_id)
	var removed: bool = capabilities.erase(capability)
	if capabilities.is_empty():
		_custom_capabilities.erase(peer_id)
	else:
		_custom_capabilities[peer_id] = capabilities
	if removed:
		capability_changed.emit(peer_id, capability, false)
	return removed


func has_capability(peer_id: int, capability: String) -> bool:
	if peer_id <= 0 or not _valid_capability(capability):
		return false
	var role: String = get_role(peer_id)
	var role_values: Variant = ROLE_CAPABILITIES.get(role)
	if role_values is Array:
		var role_capabilities: Array = role_values as Array
		if role_capabilities.has("*") or role_capabilities.has(capability):
			return true
	return _get_custom_capabilities(peer_id).has(capability)


func clear_peer(peer_id: int) -> void:
	if peer_id == 1:
		return
	_roles.erase(peer_id)
	_custom_capabilities.erase(peer_id)


func _on_peer_connected(peer_id: int) -> void:
	if peer_id == 1:
		_roles[peer_id] = ROLE_OWNER
	elif not _roles.has(peer_id):
		_roles[peer_id] = ROLE_PLAYER


func _on_peer_disconnected(peer_id: int, _reason_code: String) -> void:
	clear_peer(peer_id)


func _get_custom_capabilities(peer_id: int) -> Dictionary:
	var value: Variant = _custom_capabilities.get(peer_id)
	return (value as Dictionary).duplicate() if value is Dictionary else {}


func _can_manage() -> bool:
	if _network == null:
		return false
	var transport: RedotP2PTransportAdapter = _network.get_transport()
	return transport == null or transport.get_state() in [
		RedotP2PTransportAdapter.State.STOPPED,
		RedotP2PTransportAdapter.State.FAILED,
	] or _network.is_authority()


func _valid_capability(capability: String) -> bool:
	var bytes: PackedByteArray = capability.to_utf8_buffer()
	if bytes.is_empty() or bytes.size() > 64:
		return false
	for byte_value: int in bytes:
		var allowed: bool = (
			(byte_value >= 0x61 and byte_value <= 0x7A)
			or (byte_value >= 0x30 and byte_value <= 0x39)
			or byte_value in [0x2D, 0x2E, 0x5F]
		)
		if not allowed:
			return false
	return true
