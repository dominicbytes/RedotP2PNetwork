class_name RedotP2PModerationService
extends Node

signal enforcement_changed(enabled: bool)
signal ban_added(kind: int, target: String, expires_unix: int)
signal ban_removed(kind: int, target: String)
signal peer_denied(peer_id: int, reason_code: String)

const DEFAULT_IPV4_MIN_PREFIX: int = 24
const DEFAULT_IPV6_MIN_PREFIX: int = 64
const ABSOLUTE_IPV4_MIN_PREFIX: int = 16
const ABSOLUTE_IPV6_MIN_PREFIX: int = 48
const MAX_REASON_BYTES: int = 256
const MAX_BANS: int = 4096

var _network: RedotP2PNetworkService = null
var _enforcement_enabled: bool = false
var _cidr_enabled: bool = false
var _ipv4_min_prefix: int = DEFAULT_IPV4_MIN_PREFIX
var _ipv6_min_prefix: int = DEFAULT_IPV6_MIN_PREFIX
var _exact_address_bans: Dictionary = {}
var _identity_bans: Dictionary = {}
var _cidr_bans: Array[RedotP2PBanRecord] = []
var _connected_peers: Dictionary = {}


func attach(network: RedotP2PNetworkService) -> Error:
	if network == null:
		return ERR_INVALID_PARAMETER
	if _network != null and _network != network:
		return ERR_ALREADY_IN_USE
	_network = network
	if not _network.peer_connected.is_connected(_on_peer_connected):
		_network.peer_connected.connect(_on_peer_connected)
	if not _network.peer_disconnected.is_connected(_on_peer_disconnected):
		_network.peer_disconnected.connect(_on_peer_disconnected)
	if not _network.transport_state_changed.is_connected(_on_transport_state_changed):
		_network.transport_state_changed.connect(_on_transport_state_changed)
	_reevaluate_peers()
	return OK


func set_enforcement_enabled(enabled: bool) -> void:
	if _enforcement_enabled == enabled:
		return
	_enforcement_enabled = enabled
	enforcement_changed.emit(enabled)
	if enabled:
		_reevaluate_peers()


func is_enforcement_enabled() -> bool:
	return _enforcement_enabled


func configure_cidr(enabled: bool, ipv4_min_prefix: int = 24, ipv6_min_prefix: int = 64) -> Error:
	if ipv4_min_prefix < ABSOLUTE_IPV4_MIN_PREFIX or ipv4_min_prefix > 32:
		return ERR_INVALID_PARAMETER
	if ipv6_min_prefix < ABSOLUTE_IPV6_MIN_PREFIX or ipv6_min_prefix > 128:
		return ERR_INVALID_PARAMETER
	_cidr_enabled = enabled
	_ipv4_min_prefix = maxi(ipv4_min_prefix, DEFAULT_IPV4_MIN_PREFIX)
	_ipv6_min_prefix = maxi(ipv6_min_prefix, DEFAULT_IPV6_MIN_PREFIX)
	return OK


func ban_exact_address(address: String, reason: String, expires_unix: int = 0) -> Error:
	if _ban_count() >= MAX_BANS or not _valid_reason(reason) or not _valid_expiry(expires_unix):
		return ERR_INVALID_PARAMETER
	var normalized: String = RedotP2PIPAddress.normalize(address)
	if normalized.is_empty():
		return ERR_INVALID_PARAMETER
	var record: RedotP2PBanRecord = RedotP2PBanRecord.new()
	record.kind = RedotP2PBanRecord.Kind.EXACT_ADDRESS
	record.target = normalized
	record.reason = reason
	record.expires_unix = expires_unix
	_exact_address_bans[normalized] = record
	ban_added.emit(record.kind, record.target, record.expires_unix)
	_reevaluate_peers()
	return OK


func ban_identity(identity: String, reason: String, expires_unix: int = 0) -> Error:
	var normalized: String = identity.strip_edges().to_lower()
	if _ban_count() >= MAX_BANS or not _valid_identity(normalized) or not _valid_reason(reason) or not _valid_expiry(expires_unix):
		return ERR_INVALID_PARAMETER
	var record: RedotP2PBanRecord = RedotP2PBanRecord.new()
	record.kind = RedotP2PBanRecord.Kind.IDENTITY
	record.target = normalized
	record.reason = reason
	record.expires_unix = expires_unix
	_identity_bans[normalized] = record
	ban_added.emit(record.kind, record.target, record.expires_unix)
	_reevaluate_peers()
	return OK


func ban_cidr(cidr: String, reason: String, expires_unix: int, high_risk_confirmed: bool = false) -> Error:
	if not _cidr_enabled or _ban_count() >= MAX_BANS or not _valid_reason(reason) or not _valid_expiry(expires_unix):
		return ERR_UNAUTHORIZED
	var parts: PackedStringArray = cidr.strip_edges().split("/", true)
	if parts.size() != 2 or parts[1].is_empty():
		return ERR_INVALID_PARAMETER
	var normalized_address: String = RedotP2PIPAddress.normalize(parts[0])
	if normalized_address.is_empty() or not _is_decimal(parts[1]):
		return ERR_INVALID_PARAMETER
	var prefix: int = int(parts[1])
	if parts[0].contains(":") and not normalized_address.contains(":"):
		if prefix < 96 or prefix > 128:
			return ERR_INVALID_PARAMETER
		prefix -= 96
	var is_ipv6: bool = normalized_address.contains(":")
	var normal_minimum: int = _ipv6_min_prefix if is_ipv6 else _ipv4_min_prefix
	var absolute_minimum: int = ABSOLUTE_IPV6_MIN_PREFIX if is_ipv6 else ABSOLUTE_IPV4_MIN_PREFIX
	var maximum: int = 128 if is_ipv6 else 32
	if prefix < absolute_minimum or prefix > maximum:
		return ERR_INVALID_PARAMETER
	if prefix < normal_minimum and not high_risk_confirmed:
		return ERR_UNAUTHORIZED
	var network: PackedByteArray = RedotP2PIPAddress.network_bytes(normalized_address, prefix)
	if network.is_empty():
		return ERR_INVALID_PARAMETER
	var record: RedotP2PBanRecord = RedotP2PBanRecord.new()
	record.kind = RedotP2PBanRecord.Kind.CIDR
	record.network = network
	record.prefix_length = prefix
	record.target = "%s/%d" % [_bytes_key(network), prefix]
	record.reason = reason
	record.expires_unix = expires_unix
	_cidr_bans.append(record)
	ban_added.emit(record.kind, record.target, record.expires_unix)
	_reevaluate_peers()
	return OK


func unban_exact_address(address: String) -> bool:
	var normalized: String = RedotP2PIPAddress.normalize(address)
	var removed: bool = _exact_address_bans.erase(normalized)
	if removed:
		ban_removed.emit(RedotP2PBanRecord.Kind.EXACT_ADDRESS, normalized)
	return removed


func unban_identity(identity: String) -> bool:
	var normalized: String = identity.strip_edges().to_lower()
	var removed: bool = _identity_bans.erase(normalized)
	if removed:
		ban_removed.emit(RedotP2PBanRecord.Kind.IDENTITY, normalized)
	return removed


func check_address(address: String, now_unix: int = -1) -> String:
	_prune_expired(now_unix)
	var normalized: String = RedotP2PIPAddress.normalize(address)
	if normalized.is_empty():
		return RedotP2PStatusCodes.ADDRESS_UNAVAILABLE
	if _exact_address_bans.has(normalized):
		return RedotP2PStatusCodes.PEER_BANNED
	for record: RedotP2PBanRecord in _cidr_bans:
		if RedotP2PIPAddress.matches_network(normalized, record.network, record.prefix_length):
			return RedotP2PStatusCodes.PEER_BANNED
	return RedotP2PStatusCodes.OK


func check_identity(identity: String, now_unix: int = -1) -> String:
	_prune_expired(now_unix)
	var normalized: String = identity.strip_edges().to_lower()
	if normalized.is_empty():
		return RedotP2PStatusCodes.PROVIDER_UNAVAILABLE
	return RedotP2PStatusCodes.PEER_BANNED if _identity_bans.has(normalized) else RedotP2PStatusCodes.OK


func _on_peer_connected(peer_id: int) -> void:
	_connected_peers[peer_id] = true
	_check_peer(peer_id)


func _on_peer_disconnected(peer_id: int, _reason_code: String) -> void:
	_connected_peers.erase(peer_id)


func _on_transport_state_changed(_previous_state: int, current_state: int, _reason_code: String) -> void:
	if current_state in [RedotP2PTransportAdapter.State.STOPPED, RedotP2PTransportAdapter.State.FAILED]:
		_connected_peers.clear()


func _reevaluate_peers() -> void:
	for peer_id: int in _connected_peers.keys():
		_check_peer(peer_id)


func _check_peer(peer_id: int) -> void:
	if not _connected_peers.has(peer_id):
		return
	if not _enforcement_enabled or _network == null or not _network.is_authority():
		return
	var identity: String = _network.get_peer_identity(peer_id)
	if not identity.is_empty() and check_identity(identity) == RedotP2PStatusCodes.PEER_BANNED:
		_deny(peer_id)
		return
	var observed_address: String = _network.get_observed_address(peer_id)
	if not observed_address.is_empty() and check_address(observed_address) == RedotP2PStatusCodes.PEER_BANNED:
		_deny(peer_id)


func _deny(peer_id: int) -> void:
	_connected_peers.erase(peer_id)
	peer_denied.emit(peer_id, RedotP2PStatusCodes.PEER_BANNED)
	_network.disconnect_peer(peer_id, RedotP2PStatusCodes.PEER_BANNED)


func _prune_expired(now_unix: int) -> void:
	var current_unix: int = int(Time.get_unix_time_from_system()) if now_unix < 0 else now_unix
	for key: Variant in _exact_address_bans.keys():
		var record: RedotP2PBanRecord = _exact_address_bans[key] as RedotP2PBanRecord
		if record != null and record.is_expired(current_unix):
			_exact_address_bans.erase(key)
	for key: Variant in _identity_bans.keys():
		var record: RedotP2PBanRecord = _identity_bans[key] as RedotP2PBanRecord
		if record != null and record.is_expired(current_unix):
			_identity_bans.erase(key)
	var active_cidr: Array[RedotP2PBanRecord] = []
	for record: RedotP2PBanRecord in _cidr_bans:
		if not record.is_expired(current_unix):
			active_cidr.append(record)
	_cidr_bans = active_cidr


func _ban_count() -> int:
	return _exact_address_bans.size() + _identity_bans.size() + _cidr_bans.size()


func _valid_reason(reason: String) -> bool:
	var bytes: PackedByteArray = reason.strip_edges().to_utf8_buffer()
	return not bytes.is_empty() and bytes.size() <= MAX_REASON_BYTES


func _valid_expiry(expires_unix: int) -> bool:
	return expires_unix == 0 or expires_unix > int(Time.get_unix_time_from_system())


func _valid_identity(identity: String) -> bool:
	var bytes: PackedByteArray = identity.to_utf8_buffer()
	if bytes.is_empty() or bytes.size() > 256:
		return false
	for byte_value: int in bytes:
		var allowed: bool = (
			(byte_value >= 0x61 and byte_value <= 0x7A)
			or (byte_value >= 0x30 and byte_value <= 0x39)
			or byte_value in [0x2D, 0x2E, 0x3A, 0x5F]
		)
		if not allowed:
			return false
	return true


func _is_decimal(value: String) -> bool:
	for index: int in value.length():
		var codepoint: int = value.unicode_at(index)
		if codepoint < 0x30 or codepoint > 0x39:
			return false
	return not value.is_empty()


func _bytes_key(bytes: PackedByteArray) -> String:
	return bytes.hex_encode()
