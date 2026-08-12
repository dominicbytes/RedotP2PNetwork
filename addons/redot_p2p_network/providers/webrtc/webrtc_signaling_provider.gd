class_name RedotP2PWebRTCSignalingProvider
extends RefCounted

signal peer_negotiation_requested(peer_id: int, generation: int, create_offer: bool)
signal session_description_received(peer_id: int, description_type: String, sdp: String, generation: int)
signal ice_candidate_received(peer_id: int, media: String, index: int, candidate: String, generation: int)
signal peer_left(peer_id: int, generation: int)
signal signaling_error(reason_code: String)


func is_available() -> bool:
	return false


func start_authority(_endpoint: String, _port: int, _max_peers: int) -> Error:
	return ERR_UNAVAILABLE


func start_client(_endpoint: String, _port: int) -> Error:
	return ERR_UNAVAILABLE


func get_local_peer_id() -> int:
	return 0


func send_session_description(
	_peer_id: int,
	_description_type: String,
	_sdp: String,
	_generation: int
) -> Error:
	return ERR_UNAVAILABLE


func send_ice_candidate(
	_peer_id: int,
	_media: String,
	_index: int,
	_candidate: String,
	_generation: int
) -> Error:
	return ERR_UNAVAILABLE


func disconnect_peer(_peer_id: int, _reason_code: String) -> Error:
	return ERR_UNAVAILABLE


func poll() -> Error:
	return OK


func stop() -> void:
	pass
