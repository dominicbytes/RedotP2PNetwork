extends SceneTree

const FIXTURE_TIMEOUT_SECONDS: float = 10.0

var _role: String = ""
var _transport_name: String = "enet"
var _port: int = 32_877
var _network: RedotP2PCompatibilityNetwork = null
var _lobby: RedotP2PCompatibilityLobby = null
var _finished: bool = false


func _initialize() -> void:
	call_deferred("_start")


func _start() -> void:
	if not _parse_arguments():
		_fail("invalid_arguments")
		return
	_network = root.get_node_or_null("P2PNetwork") as RedotP2PCompatibilityNetwork
	if _network == null:
		_network = RedotP2PCompatibilityNetwork.new()
		_network.name = "P2PNetwork"
		root.add_child(_network)
		await process_frame
	_network.peer_connected.connect(func(peer_id: int) -> void: print("FACADE_TRACE peer_connected=%d" % peer_id))
	_network.message_received.connect(
		func(peer_id: int, message_type: String, _payload: PackedByteArray) -> void:
			print("FACADE_TRACE message peer=%d type=%s" % [peer_id, message_type])
	)
	_network.message_rejected.connect(
		func(peer_id: int, reason_code: String) -> void:
			print("FACADE_TRACE rejected peer=%d reason=%s" % [peer_id, reason_code])
	)
	_lobby = root.get_node_or_null("P2PLobby") as RedotP2PCompatibilityLobby
	if _lobby == null:
		_lobby = RedotP2PCompatibilityLobby.new()
		_lobby.name = "P2PLobby"
		root.add_child(_lobby)
		await process_frame
	_lobby.lobby_error.connect(_on_lobby_error)
	_lobby.lobby_joined.connect(_on_lobby_joined)
	_lobby.chat_message_received.connect(_on_chat_message)
	create_timer(FIXTURE_TIMEOUT_SECONDS).timeout.connect(_on_timeout)
	var start_error: Error
	if _transport_name == "enet":
		start_error = _network.host_enet(_port, 4, "127.0.0.1") if _role == "host" else _network.join_enet("127.0.0.1", _port)
	else:
		start_error = (
			_network.host_websocket(_port, 4, "127.0.0.1", null, true)
			if _role == "host"
			else _network.join_websocket("127.0.0.1", _port, null, true)
		)
	if start_error != OK:
		_fail("transport_start_failed_%d" % start_error)
		return
	if _role == "host":
		var lobby_data: LobbyData = LobbyData.new(7_001, "Fixture Pond", 0, 4, 1)
		if not _lobby.create_lobby(lobby_data):
			_fail("lobby_create_failed")
			return
		print("%s_FACADE_HOST_READY" % _transport_name.to_upper())


func _parse_arguments() -> bool:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--role="):
			_role = argument.trim_prefix("--role=")
		elif argument.begins_with("--transport="):
			_transport_name = argument.trim_prefix("--transport=").to_lower()
		elif argument.begins_with("--port="):
			_port = int(argument.trim_prefix("--port="))
	return _role in ["host", "client"] and _transport_name in ["enet", "websocket"] and _port >= 1 and _port <= 65_535


func _on_lobby_joined(lobby_id: int) -> void:
	if _finished or _role != "client":
		return
	if lobby_id != 7_001 or _lobby.get_owner_id() != 1:
		_fail("invalid_lobby_snapshot")
		return
	if not _lobby.send_message("hello authority"):
		_fail("client_chat_send_failed")


func _on_chat_message(from_peer_id: int, message: String) -> void:
	if _finished:
		return
	if _role == "host" and message == "hello authority":
		if from_peer_id <= 1 or not _lobby.send_message("welcome angler", from_peer_id):
			_fail("host_chat_reply_failed")
			return
		print("%s_FACADE_HOST_PASS" % _transport_name.to_upper())
		_finish_after_flush()
	elif _role == "client" and message == "welcome angler" and from_peer_id == 1:
		print("%s_FACADE_CLIENT_PASS" % _transport_name.to_upper())
		_finish_after_flush()


func _on_lobby_error(reason_code: String) -> void:
	if not _finished:
		_fail("lobby_error_%s" % reason_code)


func _on_timeout() -> void:
	if not _finished:
		_fail("timeout")


func _finish_after_flush() -> void:
	_finished = true
	await create_timer(0.3).timeout
	_network.stop("FIXTURE_COMPLETE")
	quit(0)


func _fail(reason: String) -> void:
	if _finished:
		return
	_finished = true
	push_error("%s_FACADE_%s_FAIL %s" % [_transport_name.to_upper(), _role.to_upper(), reason])
	if _network != null:
		_network.stop("FIXTURE_FAILED")
	quit(1)
