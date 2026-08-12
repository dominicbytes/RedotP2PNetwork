extends SceneTree

const DEFAULT_PORT: int = 32_777
const FIXTURE_TIMEOUT_SECONDS: float = 10.0
const MESSAGE_CHANNEL: int = 0
const PING_MESSAGE: String = "fixture.ping"
const PONG_MESSAGE: String = "fixture.pong"
const ACK_MESSAGE: String = "fixture.ack"

var _role: String = ""
var _transport_name: String = "enet"
var _port: int = DEFAULT_PORT
var _service: RedotP2PNetworkService = null
var _finished: bool = false


func _initialize() -> void:
	call_deferred("_start")


func _start() -> void:
	if not _parse_arguments():
		_fail("invalid_arguments")
		return
	_service = RedotP2PNetworkService.new()
	root.add_child(_service)
	_service.service_error.connect(_on_service_error)
	_service.transport_state_changed.connect(_on_transport_state_changed)
	if _register_messages() != OK:
		_fail("message_registration_failed")
		return
	var adapter: RedotP2PTransportAdapter = _create_transport()
	if adapter == null:
		_fail("transport_unavailable")
		return
	var transport_error: Error = _service.set_transport(adapter)
	if transport_error != OK:
		_fail("transport_setup_failed_%d" % transport_error)
		return
	get_root().get_tree().create_timer(FIXTURE_TIMEOUT_SECONDS).timeout.connect(_on_timeout)
	if _role == "host":
		var host_error: Error = _service.host("127.0.0.1", _port, 4)
		if host_error != OK:
			_fail("host_failed_%d" % host_error)
			return
		print("%s_HOST_READY port=%d" % [_marker_prefix(), _port])
		return
	var join_error: Error = _service.join("127.0.0.1", _port)
	if join_error != OK:
		_fail("join_failed_%d" % join_error)


func _parse_arguments() -> bool:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--role="):
			_role = argument.trim_prefix("--role=")
		elif argument.begins_with("--port="):
			_port = int(argument.trim_prefix("--port="))
		elif argument.begins_with("--transport="):
			_transport_name = argument.trim_prefix("--transport=").to_lower()
	return _role in ["host", "client"] and _transport_name in ["enet", "websocket"] and _port >= 1 and _port <= 65_535


func _create_transport() -> RedotP2PTransportAdapter:
	if _transport_name == "enet":
		return RedotP2PEnetTransportAdapter.new()
	var websocket_adapter: RedotP2PWebSocketTransportAdapter = RedotP2PWebSocketTransportAdapter.new()
	if websocket_adapter.enable_plaintext_loopback_development(true) != OK:
		return null
	return websocket_adapter


func _register_messages() -> Error:
	var ping_error: Error = _service.register_message(
		_definition(PING_MESSAGE, _on_ping, true, false)
	)
	if ping_error != OK:
		return ping_error
	var pong_error: Error = _service.register_message(
		_definition(PONG_MESSAGE, _on_pong, false, true)
	)
	if pong_error != OK:
		return pong_error
	return _service.register_message(_definition(ACK_MESSAGE, _on_ack, true, false))


func _definition(
	message_type: String,
	handler: Callable,
	allow_from_client: bool,
	allow_from_authority: bool
) -> RedotP2PMessageDefinition:
	var definition: RedotP2PMessageDefinition = RedotP2PMessageDefinition.new()
	definition.message_type = message_type
	definition.handler = handler
	definition.max_payload_bytes = 16
	definition.required_channel = MESSAGE_CHANNEL
	definition.required_delivery = RedotP2PTransportAdapter.Delivery.RELIABLE
	definition.allow_from_client = allow_from_client
	definition.allow_from_authority = allow_from_authority
	definition.per_peer_rate = 8.0
	definition.per_peer_burst = 8
	return definition


func _on_transport_state_changed(_previous_state: int, current_state: int, reason_code: String) -> void:
	if _finished:
		return
	if current_state == RedotP2PTransportAdapter.State.FAILED:
		_fail("transport_failed_%s" % reason_code)
		return
	if _role == "client" and current_state == RedotP2PTransportAdapter.State.CONNECTED:
		var send_error: Error = _service.send_message(
			PING_MESSAGE,
			"ping".to_utf8_buffer(),
			1,
			MESSAGE_CHANNEL,
			RedotP2PTransportAdapter.Delivery.RELIABLE
		)
		if send_error != OK:
			_fail("ping_send_failed_%d" % send_error)


func _on_ping(peer_id: int, payload: PackedByteArray) -> void:
	if _role != "host" or payload.get_string_from_utf8() != "ping":
		_fail("invalid_ping")
		return
	var send_error: Error = _service.send_message(
		PONG_MESSAGE,
		"pong".to_utf8_buffer(),
		peer_id,
		MESSAGE_CHANNEL,
		RedotP2PTransportAdapter.Delivery.RELIABLE
	)
	if send_error != OK:
		_fail("pong_send_failed_%d" % send_error)


func _on_pong(_peer_id: int, payload: PackedByteArray) -> void:
	if _role != "client" or payload.get_string_from_utf8() != "pong":
		_fail("invalid_pong")
		return
	var send_error: Error = _service.send_message(
		ACK_MESSAGE,
		"ack".to_utf8_buffer(),
		1,
		MESSAGE_CHANNEL,
		RedotP2PTransportAdapter.Delivery.RELIABLE
	)
	if send_error != OK:
		_fail("ack_send_failed_%d" % send_error)
		return
	print("%s_CLIENT_PASS" % _marker_prefix())
	_finish_after_flush()


func _on_ack(_peer_id: int, payload: PackedByteArray) -> void:
	if _role != "host" or payload.get_string_from_utf8() != "ack":
		_fail("invalid_ack")
		return
	print("%s_HOST_PASS" % _marker_prefix())
	_finish(0)


func _finish_after_flush() -> void:
	_finished = true
	await create_timer(0.2).timeout
	_finish(0)


func _on_service_error(reason_code: String) -> void:
	if not _finished:
		_fail("service_error_%s" % reason_code)


func _on_timeout() -> void:
	if not _finished:
		_fail("timeout")


func _fail(reason: String) -> void:
	if _finished:
		return
	_finished = true
	push_error("%s_%s_FAIL %s" % [_marker_prefix(), _role.to_upper(), reason])
	_finish(1)


func _finish(exit_code: int) -> void:
	if _service != null:
		_service.stop("FIXTURE_COMPLETE")
	quit(exit_code)


func _marker_prefix() -> String:
	return _transport_name.to_upper()
