class_name P2PGlobalData
extends Node

signal player_data_updated(player_id: int, key: String)
signal game_data_updated(key: String)

var _state: RedotP2PReplicatedStateService = null


func attach(state: RedotP2PReplicatedStateService) -> Error:
	if state == null:
		return ERR_INVALID_PARAMETER
	_state = state
	if not _state.player_data_updated.is_connected(_on_player_data_updated):
		_state.player_data_updated.connect(_on_player_data_updated)
	if not _state.game_data_updated.is_connected(_on_game_data_updated):
		_state.game_data_updated.connect(_on_game_data_updated)
	return OK


func set_player_data(key: String, value: Variant) -> Error:
	return ERR_UNCONFIGURED if _state == null else _state.set_player_data(key, value)


func set_game_data(key: String, value: Variant) -> Error:
	return ERR_UNCONFIGURED if _state == null else _state.set_game_data(key, value)


func get_game_data(key: String, default_value: Variant = null) -> Variant:
	return default_value if _state == null else _state.get_game_data(key, default_value)


func get_player_data(peer_id: int, key: String, default_value: Variant = null) -> Variant:
	return default_value if _state == null else _state.get_player_data(peer_id, key, default_value)


func reset() -> void:
	if _state != null:
		_state.reset()


func _on_player_data_updated(peer_id: int, key: String) -> void:
	player_data_updated.emit(peer_id, key)


func _on_game_data_updated(key: String) -> void:
	game_data_updated.emit(key)
