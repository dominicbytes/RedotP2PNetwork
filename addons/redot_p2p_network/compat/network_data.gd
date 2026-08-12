class_name NetworkData
extends RefCounted

var _peers: Dictionary = {}
var _current_peer: NetPeer = null


func get_peers_with_status(status: int = NetPeer.ConnectionStatus.READY, greater_than: bool = false) -> Array[NetPeer]:
	var matches: Array[NetPeer] = []
	for peer_value: Variant in _peers.values():
		if not peer_value is NetPeer:
			continue
		var peer: NetPeer = peer_value as NetPeer
		if peer.status == status or (greater_than and peer.status >= status):
			matches.append(peer)
	return matches


func do_all_peers_have_status(status: int = NetPeer.ConnectionStatus.READY, greater_than: bool = false) -> bool:
	if _peers.is_empty():
		return false
	return get_peers_with_status(status, greater_than).size() == _peers.size()


func set_current_peer(current_peer: NetPeer) -> void:
	_current_peer = current_peer
	if current_peer != null:
		set_peer(current_peer)


func get_current_peer() -> NetPeer:
	return _current_peer


func get_network_id() -> int:
	return 0 if _current_peer == null else _current_peer.network_id


func is_server() -> bool:
	return get_network_id() == 1


func get_server_network_peer() -> NetPeer:
	return get_peer(1)


func clear() -> void:
	_peers.clear()
	_current_peer = null


func get_peer_network_ids() -> Array[int]:
	var result: Array[int] = []
	for peer_id_value: Variant in _peers.keys():
		result.append(int(peer_id_value))
	return result


func has_peer(network_id: int) -> bool:
	return _peers.has(network_id)


func add_peer(peer: NetPeer) -> bool:
	if peer == null or peer.network_id <= 0 or _peers.has(peer.network_id):
		return false
	_peers[peer.network_id] = peer
	return true


func set_peer(peer: NetPeer) -> bool:
	if peer == null or peer.network_id <= 0:
		return false
	_peers[peer.network_id] = peer
	return true


func remove_peer(network_id: int) -> void:
	_peers.erase(network_id)
	if _current_peer != null and _current_peer.network_id == network_id:
		_current_peer = null


func get_peer(network_id: int) -> NetPeer:
	var peer_value: Variant = _peers.get(network_id)
	return peer_value as NetPeer if peer_value is NetPeer else null


func is_peer_connected(network_id: int) -> bool:
	var peer: NetPeer = get_peer(network_id)
	return peer != null and peer.connected


func peers_connected() -> bool:
	for peer_value: Variant in _peers.values():
		if peer_value is NetPeer and not (peer_value as NetPeer).connected:
			return false
	return not _peers.is_empty()


func get_connected_peer(network_id: int) -> NetPeer:
	var peer: NetPeer = get_peer(network_id)
	return peer if peer != null and peer.connected else null
