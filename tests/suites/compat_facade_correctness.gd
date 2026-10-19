extends RedotP2PTestSuite

const RELIABLE: int = RedotP2PTransportAdapter.Delivery.RELIABLE

var _network: RedotP2PCompatibilityNetwork = null
var _lobby: RedotP2PCompatibilityLobby = null


func run(tree: SceneTree) -> void:
	_network = tree.root.get_node("P2PNetwork") as RedotP2PCompatibilityNetwork
	_lobby = tree.root.get_node("P2PLobby") as RedotP2PCompatibilityLobby
	_test_local_player_id()
	_test_lobby_session_lifecycle()
	_test_chat_membership()
	_test_unicode_lobby_names()
	_test_departed_member()
	await _test_node_registration_ownership(tree)
	_network.stop()
	_lobby.leave_lobby()


func _start_session(client: bool = false) -> RedotP2PFakeTransportAdapter:
	_network.stop()
	_lobby.leave_lobby()
	var transport: RedotP2PFakeTransportAdapter = RedotP2PFakeTransportAdapter.new()
	_expect_equal(_network.use_transport(transport), OK, "compat transport attaches")
	if client:
		_expect_equal(_network.get_service().join("fixture", 7777), OK, "compat client starts")
	else:
		_expect_equal(_network.get_service().host("*", 7777, 8), OK, "compat authority starts")
	return transport


func _test_local_player_id() -> void:
	_network.stop()
	_lobby.leave_lobby()
	_expect_equal(_lobby.get_id(), 0, "lobby player ID is zero without a local peer")
	_start_session()
	_expect_true(_lobby.create_lobby(LobbyData.new(7001)), "ID fixture lobby creates")
	_expect_equal(_lobby.get_id(), 1, "lobby get_id returns the local player ID")
	_expect_equal(_lobby.get_lobby_id(), 7001, "lobby ID stays distinct from player ID")
	_expect_equal(_lobby.get_id(), _lobby.get_self().network_id, "lobby player ID matches self")
	var transport: RedotP2PFakeTransportAdapter = _start_session(true)
	_inject(transport, RedotP2PCompatibilityLobby.LOBBY_SNAPSHOT, _snapshot(), 1)
	_expect_equal(_lobby.get_id(), 2, "client lobby get_id returns its own player ID")
	_expect_equal(_lobby.get_lobby_id(), 7001, "client retains the authority lobby ID")


func _test_lobby_session_lifecycle() -> void:
	_start_session()
	_expect_true(_lobby.create_lobby(LobbyData.new(7001)), "stop fixture lobby creates")
	var departures: Array[int] = []
	var callback: Callable = func(peer_id: int) -> void:
		departures.append(peer_id)
		_expect_true(not _lobby.in_lobby(), "departure callback observes cleared lobby")
		if not _lobby.in_lobby():
			_lobby.leave_lobby()
	_lobby.player_left_lobby.connect(callback)
	_network.stop()
	_expect_true(not _lobby.in_lobby(), "network stop clears the current lobby")
	_expect_equal(departures, [1], "network stop emits each lobby departure once")
	_lobby.player_left_lobby.disconnect(callback)
	_lobby.leave_lobby()
	_start_session()
	_expect_true(_lobby.create_lobby(LobbyData.new(7002)), "lobby can be recreated after stop")
	departures.clear()
	var session_ends: Array[bool] = []
	var ended_callback: Callable = func() -> void: session_ends.append(true)
	_network.disconnect.connect(ended_callback)
	_lobby.player_left_lobby.connect(callback)
	_lobby.leave_lobby()
	_expect_equal(_network.get_service().get_transport().get_state(),
		RedotP2PTransportAdapter.State.STOPPED, "leaving lobby stops the direct session")
	_expect_equal(departures, [1], "recursive leave emits each lobby departure once")
	_expect_equal(session_ends.size(), 1, "recursive leave ends the session once")
	_lobby.leave_lobby()
	_expect_equal(session_ends.size(), 1, "repeated leave does not end the session again")
	_lobby.player_left_lobby.disconnect(callback)
	_network.disconnect.disconnect(ended_callback)
	var transport: RedotP2PFakeTransportAdapter = _start_session(true)
	_inject(transport, RedotP2PCompatibilityLobby.LOBBY_SNAPSHOT, _snapshot(), 1)
	_expect_true(_lobby.in_lobby(), "authority loss fixture receives its lobby")
	transport.peer_disconnected.emit(1, RedotP2PStatusCodes.AUTHORITY_LOST)
	_expect_true(not _lobby.in_lobby(), "authority loss clears the current lobby")
	transport = _start_session(true)
	_inject(transport, RedotP2PCompatibilityLobby.LOBBY_SNAPSHOT, _snapshot(), 1)
	_lobby.leave_lobby()
	_expect_equal(transport.get_state(), RedotP2PTransportAdapter.State.STOPPED,
		"client leaving lobby stops its direct session")


func _test_chat_membership() -> void:
	var transport: RedotP2PFakeTransportAdapter = _start_session()
	var messages: Array[String] = []
	var callback: Callable = func(_peer_id: int, message: String) -> void: messages.append(message)
	_lobby.chat_message_received.connect(callback)
	_inject(transport, RedotP2PCompatibilityLobby.CHAT_REQUEST, "hello".to_utf8_buffer(), 1, 2)
	_expect_equal(transport.sent_packets.size(), 0, "chat without a lobby is not broadcast")
	_expect_true(messages.is_empty(), "chat without a lobby emits no chat signal")
	_expect_true(_lobby.create_lobby(LobbyData.new(7001, "fixture", 0, 2)), "chat fixture lobby creates")
	transport.inject_peer_connected(2)
	transport.inject_peer_connected(3)
	_expect_true(_lobby.get_lobby_member(2) != null, "chat fixture admits member")
	_expect_true(_lobby.get_lobby_member(3) == null, "chat fixture refuses excess member")
	transport.sent_packets.clear()
	_inject(transport, RedotP2PCompatibilityLobby.CHAT_REQUEST, "outsider".to_utf8_buffer(), 1, 3)
	_expect_equal(transport.sent_packets.size(), 0, "non-member chat is not broadcast")
	_expect_true(messages.is_empty(), "non-member chat emits no chat signal")
	_inject(transport, RedotP2PCompatibilityLobby.CHAT_REQUEST, "member".to_utf8_buffer(), 2, 2)
	_expect_equal(transport.sent_packets.size(), 1, "member chat is broadcast once")
	_expect_equal(messages, ["member"], "member chat emits one chat signal")
	transport.sent_packets.clear()
	for payload: PackedByteArray in [PackedByteArray([0]), "x".repeat(513).to_utf8_buffer()]:
		_lobby._on_chat_request(2, payload)
	_expect_true(transport.sent_packets.is_empty(), "malformed and oversized member chat is dropped")
	_expect_equal(messages, ["member"], "invalid member chat emits no chat signal")
	transport.peer_disconnected.emit(2, RedotP2PStatusCodes.CONNECTION_CLOSED)
	transport.sent_packets.clear()
	_inject(transport, RedotP2PCompatibilityLobby.CHAT_REQUEST, "departed".to_utf8_buffer(), 3, 2)
	_expect_true(transport.sent_packets.is_empty(), "departed member chat is not broadcast")
	_expect_equal(messages, ["member"], "departed member chat emits no chat signal")
	_lobby.chat_message_received.disconnect(callback)


func _test_unicode_lobby_names() -> void:
	var cjk: String = String.chr(0x754C)
	var emoji: String = String.chr(0x1F30D)
	var cases: Array[Dictionary] = [
		{"name": cjk.repeat(33), "expected": cjk.repeat(32)},
		{"name": "a".repeat(95) + cjk, "expected": "a".repeat(95)},
		{"name": emoji.repeat(25), "expected": emoji.repeat(24)},
		{"name": "a".repeat(97), "expected": "a".repeat(96)},
	]
	for test_case: Dictionary in cases:
		var transport: RedotP2PFakeTransportAdapter = _start_session()
		var lobby_data: LobbyData = LobbyData.new(7001, str(test_case["name"]))
		_expect_equal(lobby_data.lobby_name, test_case["expected"], "lobby name truncates at a UTF-8 boundary")
		_expect_true(lobby_data.lobby_name.to_utf8_buffer().size() <= 96, "lobby name fits the byte limit")
		_expect_true(_lobby.create_lobby(lobby_data), "Unicode lobby creates")
		var payload: PackedByteArray = PackedByteArray()
		if not transport.sent_packets.is_empty():
			var decoded: RedotP2PEnvelopeDecodeResult = RedotP2PMessageEnvelope.decode(
				transport.sent_packets[-1]["packet"], RedotP2PProtocolLimits.new())
			if decoded.is_ok():
				payload = decoded.envelope.payload
		transport = _start_session(true)
		_inject(transport, RedotP2PCompatibilityLobby.LOBBY_SNAPSHOT, payload, 1)
		_expect_true(_lobby.in_lobby(), "Unicode authority snapshot joins on the client")
	_start_session()
	var mutated: LobbyData = LobbyData.new(7001)
	mutated.lobby_name = cjk.repeat(33)
	_expect_true(not _lobby.create_lobby(mutated), "creation rejects a mutated over-byte-limit name")
	var transport: RedotP2PFakeTransportAdapter = _start_session(true)
	var oversized: Dictionary = _snapshot_data()
	oversized["name"] = cjk.repeat(33)
	_inject(transport, RedotP2PCompatibilityLobby.LOBBY_SNAPSHOT, JSON.stringify(oversized).to_utf8_buffer(), 1)
	_expect_true(not _lobby.in_lobby(), "client rejects an over-byte-limit wire name")


func _test_departed_member() -> void:
	var transport: RedotP2PFakeTransportAdapter = _start_session(true)
	_inject(transport, RedotP2PCompatibilityLobby.LOBBY_SNAPSHOT, _snapshot(), 1)
	_inject(transport, RedotP2PCompatibilityLobby.LOBBY_MEMBER_JOINED, "3".to_utf8_buffer(), 2)
	var departed: NetPeer = _network.network_data.get_peer(3)
	_expect_true(departed != null and departed.connected, "client synthesizes the remote member")
	var departures: Array[int] = []
	var callback: Callable = func(peer_id: int) -> void:
		departures.append(peer_id)
		_expect_true(not _network.network_data.is_peer_connected(peer_id), "departure callback sees disconnected peer")
	_lobby.player_left_lobby.connect(callback)
	_inject(transport, RedotP2PCompatibilityLobby.LOBBY_MEMBER_LEFT, "3".to_utf8_buffer(), 3)
	_expect_true(_lobby.get_lobby_member(3) == null, "departed member leaves lobby roster")
	_expect_true(not _network.network_data.has_peer(3), "departed member leaves network roster")
	_expect_true(departed != null and not departed.connected, "retained departed peer is marked disconnected")
	_inject(transport, RedotP2PCompatibilityLobby.LOBBY_MEMBER_LEFT, "3".to_utf8_buffer(), 4)
	_expect_equal(departures, [3], "duplicate member-left event emits no duplicate departure")
	_expect_true(_network.network_data.is_peer_connected(1), "member-left preserves authority")
	_expect_true(_network.network_data.is_peer_connected(2), "member-left preserves local peer")
	_lobby.player_left_lobby.disconnect(callback)


func _test_node_registration_ownership(tree: SceneTree) -> void:
	_start_session()
	var original: P2PNode = P2PNode.new()
	original.entity_id = "fixture.original"
	tree.root.add_child(original)
	var duplicate: P2PNode = P2PNode.new()
	duplicate.entity_id = original.entity_id
	# Only the deliberate synchronous registration failure may emit a warning.
	var print_errors: bool = Engine.print_error_messages
	Engine.print_error_messages = false
	tree.root.add_child(duplicate)
	Engine.print_error_messages = print_errors
	_expect_true(not _network.periodic_sync.is_connected(duplicate._on_periodic_sync),
		"duplicate registration does not subscribe to sync")
	_expect_true(not _network.disconnect.is_connected(duplicate._on_network_disconnect),
		"duplicate registration does not subscribe to disconnect")
	_expect_equal(duplicate.publish_replication_state(), ERR_UNCONFIGURED, "duplicate cannot publish original state")
	_expect_true(not _network.rpc_sync(duplicate), "compat sync rejects the unregistered duplicate")
	_expect_equal(duplicate.submit_replication_intent({}), ERR_UNCONFIGURED, "duplicate cannot submit original intents")
	duplicate.free()
	_expect_equal(original.publish_replication_state(), OK, "freeing duplicate preserves original registration")
	original.entity_id = "fixture.changed"
	_expect_equal(original.publish_replication_state(), OK, "node publishes the ID it actually registered")
	_expect_true(_network.rpc_sync(original), "compat sync uses the owned registration after configuration changes")
	original.free()
	_expect_equal(_network.replication.publish_entity("fixture.original"), ERR_DOES_NOT_EXIST,
		"freeing original unregisters its original ID after configuration changes")
	var invalid: P2PNode = P2PNode.new()
	invalid.entity_id = "invalid entity"
	Engine.print_error_messages = false
	tree.root.add_child(invalid)
	Engine.print_error_messages = print_errors
	_expect_true(not _network.periodic_sync.is_connected(invalid._on_periodic_sync),
		"invalid registration does not subscribe to sync")
	_expect_equal(invalid.publish_replication_state(), ERR_UNCONFIGURED, "invalid registration cannot publish")
	invalid.free()
	await tree.process_frame


func _snapshot_data() -> Dictionary:
	return {
		"lobby_id": "7001", "name": "fixture", "visibility": "0",
		"max_members": "4", "min_members": "1", "auto_start": "-1",
		"owner_id": "1", "members": ["1", "2"], "meta": {},
	}


func _snapshot() -> PackedByteArray:
	return JSON.stringify(_snapshot_data()).to_utf8_buffer()


func _inject(
	transport: RedotP2PFakeTransportAdapter, message_type: String,
	payload: PackedByteArray, sequence: int, sender_id: int = 1
) -> void:
	transport.inject_packet(sender_id,
		_frame(message_type, payload, sequence, RedotP2PCompatibilityLobby.CHAT_CHANNEL),
		RedotP2PCompatibilityLobby.CHAT_CHANNEL, RELIABLE)
