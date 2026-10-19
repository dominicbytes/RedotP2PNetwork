extends SceneTree

var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_protocol_limits()
	_test_envelope_round_trip_and_rejections()
	_test_token_bucket()
	_test_ip_address_normalization()
	_test_optional_transports_fail_closed()
	await _test_transport_lifecycle_guards()
	await _test_network_service_guards()
	await _test_replicated_state_flow()
	await _test_entity_replication_flow()
	await _test_moderation_enforcement()
	await _run_discovered_suites()
	if _failures.is_empty():
		print("UNIT_TESTS_PASS")
		quit(0)
		return
	for failure: String in _failures:
		push_error(failure)
	print("UNIT_TESTS_FAIL count=%d" % _failures.size())
	quit(1)


func _run_discovered_suites() -> void:
	var files: PackedStringArray = DirAccess.get_files_at("res://tests/suites")
	files.sort()
	for file: String in files:
		if not file.ends_with(".gd"):
			continue
		var script: Script = load("res://tests/suites/" + file) as Script
		if script == null or not script.can_instantiate():
			_failures.append("suite cannot be loaded: %s" % file)
			continue
		var suite: RedotP2PTestSuite = script.new() as RedotP2PTestSuite
		if suite == null:
			_failures.append("suite must extend RedotP2PTestSuite: %s" % file)
			continue
		await suite.run(self)
		_failures.append_array(suite.failures)


func _test_protocol_limits() -> void:
	var limits: RedotP2PProtocolLimits = RedotP2PProtocolLimits.new()
	_expect_equal(limits.validate(), OK, "default protocol limits are valid")
	limits.max_channels = RedotP2PProtocolLimits.HARD_MAX_CHANNELS + 1
	_expect_equal(limits.validate(), ERR_INVALID_PARAMETER, "channel hard cap is enforced")
	limits = RedotP2PProtocolLimits.new()
	limits.max_payload_bytes = limits.max_frame_bytes
	_expect_equal(limits.validate(), ERR_INVALID_PARAMETER, "payload must leave room for framing")


func _test_envelope_round_trip_and_rejections() -> void:
	var limits: RedotP2PProtocolLimits = RedotP2PProtocolLimits.new()
	var envelope: RedotP2PMessageEnvelope = RedotP2PMessageEnvelope.new()
	envelope.message_type = "fixture.ping"
	envelope.payload = "hello".to_utf8_buffer()
	envelope.channel = 2
	envelope.sequence = 7
	envelope.delivery = RedotP2PTransportAdapter.Delivery.RELIABLE
	var frame: PackedByteArray = envelope.encode(limits)
	_expect_true(not frame.is_empty(), "valid envelope encodes")
	var decoded: RedotP2PEnvelopeDecodeResult = RedotP2PMessageEnvelope.decode(frame, limits)
	_expect_true(decoded.is_ok(), "valid envelope decodes")
	if decoded.is_ok():
		_expect_equal(decoded.envelope.message_type, envelope.message_type, "message type round-trips")
		_expect_equal(decoded.envelope.payload, envelope.payload, "payload round-trips")
		_expect_equal(decoded.envelope.channel, envelope.channel, "channel round-trips")
		_expect_equal(decoded.envelope.sequence, envelope.sequence, "sequence round-trips")

	var corrupted: PackedByteArray = frame.duplicate()
	corrupted[0] = 0
	_expect_decode_status(corrupted, limits, RedotP2PStatusCodes.FRAME_MAGIC_INVALID, "bad magic is rejected")
	corrupted = frame.duplicate()
	corrupted[4] = 99
	_expect_decode_status(corrupted, limits, RedotP2PStatusCodes.FRAME_VERSION_UNSUPPORTED, "unknown version is rejected")
	corrupted = frame.duplicate()
	corrupted[5] = 0x80
	_expect_decode_status(corrupted, limits, RedotP2PStatusCodes.FRAME_FLAGS_INVALID, "reserved flags are rejected")
	corrupted = frame.duplicate()
	corrupted[RedotP2PMessageEnvelope.HEADER_BYTES] = 0x41
	_expect_decode_status(corrupted, limits, RedotP2PStatusCodes.MESSAGE_TYPE_INVALID, "noncanonical message type is rejected")
	corrupted = frame.slice(0, frame.size() - 1)
	_expect_decode_status(corrupted, limits, RedotP2PStatusCodes.FRAME_LENGTH_INVALID, "truncated payload is rejected")
	_expect_decode_status(PackedByteArray([1, 2, 3]), limits, RedotP2PStatusCodes.FRAME_TOO_SMALL, "short frame is rejected")


func _test_token_bucket() -> void:
	var bucket: RedotP2PTokenBucket = RedotP2PTokenBucket.new()
	_expect_equal(bucket.configure(2.0, 2, 1_000), OK, "token bucket configures")
	_expect_true(bucket.allow(1.0, 1_000), "first burst token is available")
	_expect_true(bucket.allow(1.0, 1_000), "second burst token is available")
	_expect_true(not bucket.allow(1.0, 1_000), "burst exhaustion is enforced")
	_expect_true(bucket.allow(1.0, 1_500), "tokens refill deterministically")
	_expect_true(not bucket.allow(3.0, 2_000), "cost above burst is rejected")


func _test_ip_address_normalization() -> void:
	_expect_equal(RedotP2PIPAddress.normalize("127.000.0.1"), "127.0.0.1", "IPv4 is canonicalized")
	_expect_equal(
		RedotP2PIPAddress.normalize("2001:DB8::1"),
		"2001:0db8:0000:0000:0000:0000:0000:0001",
		"IPv6 compression and case are canonicalized"
	)
	_expect_equal(
		RedotP2PIPAddress.normalize("::ffff:192.0.2.1"),
		"0000:0000:0000:0000:0000:ffff:c000:0201",
		"embedded IPv4 is canonicalized"
	)
	_expect_equal(RedotP2PIPAddress.normalize("300.1.1.1"), "", "invalid IPv4 is rejected")
	_expect_equal(RedotP2PIPAddress.normalize("2001::db8::1"), "", "multiple IPv6 gaps are rejected")
	var network: PackedByteArray = RedotP2PIPAddress.network_bytes("192.168.4.99", 24)
	_expect_true(RedotP2PIPAddress.matches_network("192.168.4.200", network, 24), "CIDR member matches")
	_expect_true(not RedotP2PIPAddress.matches_network("192.168.5.1", network, 24), "CIDR outsider is rejected")


func _test_optional_transports_fail_closed() -> void:
	var websocket: RedotP2PWebSocketTransportAdapter = RedotP2PWebSocketTransportAdapter.new()
	_expect_equal(
		websocket.host("0.0.0.0", 39_991, 4),
		ERR_UNAUTHORIZED,
		"plaintext WebSocket cannot bind a non-loopback address by default"
	)
	var steam: RedotP2PSteamTransportAdapter = RedotP2PSteamTransportAdapter.new()
	_expect_true(not steam.get_capabilities().available, "Steam is unavailable without an explicit RedotSteam provider")
	var webrtc: RedotP2PWebRTCTransportAdapter = RedotP2PWebRTCTransportAdapter.new()
	_expect_true(not webrtc.get_capabilities().available, "WebRTC is unavailable without signaling, ICE, and peer providers")
	websocket.free()
	steam.free()
	webrtc.free()


func _test_transport_lifecycle_guards() -> void:
	var adapters: Array[RedotP2PTransportAdapter] = [
		RedotP2PEnetTransportAdapter.new(),
		RedotP2PWebSocketTransportAdapter.new(),
		RedotP2PSteamTransportAdapter.new(),
		RedotP2PWebRTCTransportAdapter.new(),
	]
	for adapter: RedotP2PTransportAdapter in adapters:
		root.add_child(adapter)
		await process_frame
		_expect_true(
			not adapter.is_processing(),
			"stopped %s adapter does not poll every frame" % adapter.get_capabilities().transport_name
		)

	var webrtc: RedotP2PWebRTCTransportAdapter = adapters[-1] as RedotP2PWebRTCTransportAdapter
	var disconnected_peers: Array[int] = []
	webrtc.peer_disconnected.connect(
		func(peer_id: int, _reason_code: String) -> void: disconnected_peers.append(peer_id)
	)
	webrtc._emit_peer_disconnected_once(7, RedotP2PStatusCodes.CONNECTION_CLOSED)
	webrtc._emit_peer_disconnected_once(7, RedotP2PStatusCodes.AUTHORITY_LOST)
	_expect_equal(disconnected_peers.size(), 1, "duplicate WebRTC disconnect sources emit one public event")

	for adapter: RedotP2PTransportAdapter in adapters:
		adapter.queue_free()
	await process_frame


func _test_network_service_guards() -> void:
	var service: RedotP2PNetworkService = RedotP2PNetworkService.new()
	root.add_child(service)
	var transport: RedotP2PFakeTransportAdapter = RedotP2PFakeTransportAdapter.new()
	_expect_equal(service.set_transport(transport), OK, "fake transport attaches")
	_expect_equal(service.host("*", 7777, 4), OK, "fake authority starts")

	var handled_messages: Array[Dictionary] = []
	var rejected_reasons: Array[String] = []
	service.message_rejected.connect(
		func(_peer_id: int, reason_code: String) -> void: rejected_reasons.append(reason_code)
	)
	var definition: RedotP2PMessageDefinition = _definition(
		"fixture.input",
		func(peer_id: int, payload: PackedByteArray) -> void:
			handled_messages.append({"peer_id": peer_id, "payload": payload.duplicate()}),
		true,
		false,
		0,
		RedotP2PTransportAdapter.Delivery.RELIABLE,
		1.0,
		1
	)
	_expect_equal(service.register_message(definition), OK, "allowlisted message registers")
	_expect_equal(service.register_message(definition), ERR_ALREADY_EXISTS, "duplicate registration is rejected")
	_expect_equal(
		service.send_message("fixture.input", PackedByteArray([1]), 2),
		ERR_UNAUTHORIZED,
		"authority cannot send a client-only message"
	)

	var first_frame: PackedByteArray = _frame("fixture.input", PackedByteArray([10]), 1, 0)
	transport.inject_packet(2, first_frame, 0, RedotP2PTransportAdapter.Delivery.RELIABLE)
	_expect_equal(handled_messages.size(), 1, "valid client message reaches its local handler")
	transport.inject_packet(2, first_frame, 0, RedotP2PTransportAdapter.Delivery.RELIABLE)
	_expect_true(rejected_reasons.has(RedotP2PStatusCodes.MESSAGE_REPLAYED), "replayed sequence is rejected")

	var second_frame: PackedByteArray = _frame("fixture.input", PackedByteArray([11]), 2, 0)
	transport.inject_packet(2, second_frame, 0, RedotP2PTransportAdapter.Delivery.RELIABLE)
	_expect_true(rejected_reasons.has(RedotP2PStatusCodes.MESSAGE_RATE_LIMITED), "per-peer message rate is enforced")

	var access_control: RedotP2PCapabilityService = RedotP2PCapabilityService.new()
	root.add_child(access_control)
	_expect_equal(access_control.attach(service), OK, "capability checker attaches")
	var capability_hits: Array[int] = []
	var capability_definition: RedotP2PMessageDefinition = _definition(
		"fixture.capability",
		func(peer_id: int, _payload: PackedByteArray) -> void: capability_hits.append(peer_id),
		true,
		false,
		0,
		RedotP2PTransportAdapter.Delivery.RELIABLE,
		8.0,
		8
	)
	capability_definition.required_capability = "fixture.use"
	_expect_equal(service.register_message(capability_definition), OK, "capability-gated message registers")
	transport.inject_packet(
		2,
		_frame("fixture.capability", PackedByteArray([1]), 3, 0),
		0,
		RedotP2PTransportAdapter.Delivery.RELIABLE
	)
	_expect_equal(capability_hits.size(), 0, "missing capability blocks local dispatch")
	_expect_equal(access_control.grant_capability(2, "fixture.use"), OK, "authority grants a scoped capability")
	transport.inject_packet(
		2,
		_frame("fixture.capability", PackedByteArray([1]), 4, 0),
		0,
		RedotP2PTransportAdapter.Delivery.RELIABLE
	)
	_expect_equal(capability_hits.size(), 1, "granted capability permits local dispatch")

	var malformed: PackedByteArray = PackedByteArray([1, 2, 3])
	transport.inject_packet(3, malformed, 0, RedotP2PTransportAdapter.Delivery.RELIABLE)
	transport.inject_packet(3, malformed, 0, RedotP2PTransportAdapter.Delivery.RELIABLE)
	transport.inject_packet(3, malformed, 0, RedotP2PTransportAdapter.Delivery.RELIABLE)
	transport.inject_packet(3, malformed, 0, RedotP2PTransportAdapter.Delivery.RELIABLE)
	_expect_equal(transport.disconnected_peers.size(), 1, "violation threshold disconnects once")
	if not transport.disconnected_peers.is_empty():
		_expect_equal(
			transport.disconnected_peers[0].get("reason_code"),
			RedotP2PStatusCodes.FRAME_TOO_SMALL,
			"disconnect retains the machine-readable violation reason"
		)

	service.stop()
	access_control.queue_free()
	service.queue_free()
	await process_frame


func _test_moderation_enforcement() -> void:
	var service: RedotP2PNetworkService = RedotP2PNetworkService.new()
	root.add_child(service)
	var transport: RedotP2PFakeTransportAdapter = RedotP2PFakeTransportAdapter.new()
	_expect_equal(service.set_transport(transport), OK, "moderation fixture transport attaches")
	_expect_equal(service.host("*", 7777, 8), OK, "moderation fixture authority starts")
	var moderation: RedotP2PModerationService = RedotP2PModerationService.new()
	root.add_child(moderation)
	_expect_equal(moderation.attach(service), OK, "moderation attaches to the authority service")
	_expect_equal(moderation.ban_exact_address("203.0.113.9", "fixture ban"), OK, "exact address ban is accepted")
	transport.observed_addresses[9] = "203.0.113.9"
	transport.inject_peer_connected(9)
	_expect_equal(transport.disconnected_peers.size(), 0, "moderation remains off by default")
	moderation.set_enforcement_enabled(true)
	transport.inject_peer_connected(9)
	_expect_equal(transport.disconnected_peers.size(), 1, "enabled exact-address enforcement disconnects the peer")
	if not transport.disconnected_peers.is_empty():
		_expect_equal(
			transport.disconnected_peers[0].get("reason_code"),
			RedotP2PStatusCodes.PEER_BANNED,
			"ban disconnect uses a stable reason code"
		)

	transport.peer_identities[10] = "steam:76561198000000000"
	_expect_equal(
		moderation.ban_identity("steam:76561198000000000", "identity fixture"),
		OK,
		"transport identity ban is accepted"
	)
	transport.inject_peer_connected(10)
	_expect_equal(transport.disconnected_peers.size(), 2, "identity enforcement disconnects the peer")

	var expires_unix: int = int(Time.get_unix_time_from_system()) + 3600
	_expect_equal(
		moderation.ban_cidr("198.51.100.0/24", "disabled fixture", expires_unix),
		ERR_UNAUTHORIZED,
		"CIDR bans are disabled by default"
	)
	_expect_equal(moderation.configure_cidr(true), OK, "CIDR enforcement can be explicitly enabled")
	_expect_equal(
		moderation.ban_cidr("198.51.100.0/24", "range fixture", expires_unix),
		OK,
		"normal /24 range is accepted after opt-in"
	)
	_expect_equal(
		moderation.check_address("198.51.100.77"),
		RedotP2PStatusCodes.PEER_BANNED,
		"CIDR member is denied"
	)
	_expect_equal(
		moderation.ban_cidr("198.51.0.0/16", "high risk fixture", expires_unix),
		ERR_UNAUTHORIZED,
		"broad CIDR needs explicit high-risk confirmation"
	)
	_expect_equal(
		moderation.ban_cidr("198.51.0.0/16", "high risk fixture", expires_unix, true),
		OK,
		"confirmed CIDR at the absolute IPv4 ceiling is accepted"
	)
	_expect_equal(
		moderation.ban_cidr("198.0.0.0/8", "too broad fixture", expires_unix, true),
		ERR_INVALID_PARAMETER,
		"CIDR wider than the absolute ceiling is rejected"
	)

	service.stop()
	moderation.queue_free()
	service.queue_free()
	await process_frame


func _test_replicated_state_flow() -> void:
	var authority_service: RedotP2PNetworkService = RedotP2PNetworkService.new()
	root.add_child(authority_service)
	var authority_transport: RedotP2PFakeTransportAdapter = RedotP2PFakeTransportAdapter.new()
	_expect_equal(authority_service.set_transport(authority_transport), OK, "state authority transport attaches")
	var authority_state: RedotP2PReplicatedStateService = RedotP2PReplicatedStateService.new()
	root.add_child(authority_state)
	_expect_equal(authority_state.attach(authority_service), OK, "state authority registers its message schema")
	_expect_equal(authority_service.host("*", 7777, 8), OK, "state authority starts")
	_expect_equal(authority_state.set_game_data("world.seed", 42), OK, "authority game state is accepted")
	_expect_equal(authority_state.get_game_data("world.seed"), 42, "authority game state is stored")
	_expect_equal(
		authority_state.set_game_data("Bad Key", 1),
		ERR_INVALID_PARAMETER,
		"noncanonical state keys are rejected"
	)
	_expect_true(not RedotP2PJsonValue.is_safe(Vector2.ONE), "engine objects are rejected from replicated JSON values")

	var client_service: RedotP2PNetworkService = RedotP2PNetworkService.new()
	root.add_child(client_service)
	var client_transport: RedotP2PFakeTransportAdapter = RedotP2PFakeTransportAdapter.new()
	client_transport.authority = false
	client_transport.local_peer_id = 2
	_expect_equal(client_service.set_transport(client_transport), OK, "state client transport attaches")
	var client_state: RedotP2PReplicatedStateService = RedotP2PReplicatedStateService.new()
	root.add_child(client_state)
	_expect_equal(client_state.attach(client_service), OK, "state client registers its message schema")
	_expect_equal(client_service.join("fixture", 7777), OK, "state client starts")
	_expect_equal(client_state.set_player_data("profile.title", "angler"), OK, "client emits a bounded player-state request")
	_expect_equal(client_transport.sent_packets.size(), 1, "client produced one player-state request frame")
	if not client_transport.sent_packets.is_empty():
		var request_frame: PackedByteArray = client_transport.sent_packets[0].get("packet", PackedByteArray())
		authority_transport.inject_packet(
			2,
			request_frame,
			RedotP2PReplicatedStateService.STATE_CHANNEL,
			RedotP2PTransportAdapter.Delivery.RELIABLE
		)
	_expect_equal(
		authority_state.get_player_data(2, "profile.title"),
		"angler",
		"authority applies player data only to the sending peer"
	)
	_expect_true(authority_transport.sent_packets.size() >= 2, "authority emits game and player deltas")
	if authority_transport.sent_packets.size() >= 2:
		var player_delta_frame: PackedByteArray = authority_transport.sent_packets[-1].get("packet", PackedByteArray())
		client_transport.inject_packet(
			1,
			player_delta_frame,
			RedotP2PReplicatedStateService.STATE_CHANNEL,
			RedotP2PTransportAdapter.Delivery.RELIABLE
		)
	_expect_equal(
		client_state.get_player_data(2, "profile.title"),
		"angler",
		"validated authority delta reaches the client store"
	)

	authority_service.stop()
	client_service.stop()
	authority_state.queue_free()
	client_state.queue_free()
	authority_service.queue_free()
	client_service.queue_free()
	await process_frame


func _test_entity_replication_flow() -> void:
	var authority_service: RedotP2PNetworkService = RedotP2PNetworkService.new()
	root.add_child(authority_service)
	var authority_transport: RedotP2PFakeTransportAdapter = RedotP2PFakeTransportAdapter.new()
	_expect_equal(authority_service.set_transport(authority_transport), OK, "replication authority transport attaches")
	var authority_replication: RedotP2PReplicationService = RedotP2PReplicationService.new()
	root.add_child(authority_replication)
	_expect_equal(authority_replication.attach(authority_service), OK, "replication authority attaches")
	_expect_equal(authority_service.host("*", 7777, 8), OK, "replication authority starts")
	var authority_state: Dictionary = {"x": "5"}
	var authority_definition: RedotP2PReplicatedEntityDefinition = RedotP2PReplicatedEntityDefinition.new()
	authority_definition.entity_id = "fixture.entity"
	authority_definition.collect_state = func() -> Dictionary: return authority_state.duplicate(true)
	authority_definition.apply_state = func(_state: Dictionary) -> void: pass
	authority_definition.validate_intent = (
		func(peer_id: int, intent: Dictionary) -> bool:
			return peer_id == 2 and intent.size() == 1 and intent.get("dx") is String and absi(int(intent["dx"])) <= 4
	)
	authority_definition.apply_intent = (
		func(_peer_id: int, intent: Dictionary) -> void:
			authority_state["x"] = str(int(authority_state["x"]) + int(intent["dx"]))
	)
	_expect_equal(authority_replication.register_entity(authority_definition), OK, "authority entity schema registers")

	var client_service: RedotP2PNetworkService = RedotP2PNetworkService.new()
	root.add_child(client_service)
	var client_transport: RedotP2PFakeTransportAdapter = RedotP2PFakeTransportAdapter.new()
	client_transport.authority = false
	client_transport.local_peer_id = 2
	_expect_equal(client_service.set_transport(client_transport), OK, "replication client transport attaches")
	var client_replication: RedotP2PReplicationService = RedotP2PReplicationService.new()
	root.add_child(client_replication)
	_expect_equal(client_replication.attach(client_service), OK, "replication client attaches")
	_expect_equal(client_service.join("fixture", 7777), OK, "replication client starts")
	var client_state: Dictionary = {}
	var client_definition: RedotP2PReplicatedEntityDefinition = RedotP2PReplicatedEntityDefinition.new()
	client_definition.entity_id = "fixture.entity"
	client_definition.collect_state = func() -> Dictionary: return client_state.duplicate(true)
	client_definition.apply_state = (
		func(state: Dictionary) -> void:
			client_state.clear()
			client_state.merge(state, true)
	)
	client_definition.validate_intent = func(_peer_id: int, _intent: Dictionary) -> bool: return false
	client_definition.apply_intent = func(_peer_id: int, _intent: Dictionary) -> void: pass
	_expect_equal(client_replication.register_entity(client_definition), OK, "client entity schema registers")

	_expect_equal(authority_replication.publish_entity("fixture.entity", 2), OK, "authority publishes registered entity state")
	var first_state_packet: Dictionary = authority_transport.sent_packets[-1]
	client_transport.inject_packet(
		1,
		first_state_packet.get("packet", PackedByteArray()),
		int(first_state_packet.get("channel", 0)),
		int(first_state_packet.get("delivery", 0))
	)
	_expect_equal(client_state.get("x"), "5", "client applies the allowlisted authority state callback")

	_expect_equal(
		client_replication.submit_intent("fixture.entity", {"dx": "2"}),
		OK,
		"client submits a bounded entity intent"
	)
	var intent_packet: Dictionary = client_transport.sent_packets[-1]
	authority_transport.inject_packet(
		2,
		intent_packet.get("packet", PackedByteArray()),
		int(intent_packet.get("channel", 0)),
		int(intent_packet.get("delivery", 0))
	)
	_expect_equal(authority_state.get("x"), "7", "authority validator applies the sender-bound intent")
	_expect_equal(authority_replication.publish_entity("fixture.entity", 2), OK, "authority publishes the reconciled state")
	var reconciled_packet: Dictionary = authority_transport.sent_packets[-1]
	client_transport.inject_packet(
		1,
		reconciled_packet.get("packet", PackedByteArray()),
		int(reconciled_packet.get("channel", 0)),
		int(reconciled_packet.get("delivery", 0))
	)
	_expect_equal(client_state.get("x"), "7", "client receives authority reconciliation")

	authority_service.stop()
	client_service.stop()
	authority_replication.queue_free()
	client_replication.queue_free()
	authority_service.queue_free()
	client_service.queue_free()
	await process_frame


func _definition(
	message_type: String,
	handler: Callable,
	allow_from_client: bool,
	allow_from_authority: bool,
	channel: int,
	delivery: int,
	rate: float,
	burst: int
) -> RedotP2PMessageDefinition:
	var definition: RedotP2PMessageDefinition = RedotP2PMessageDefinition.new()
	definition.message_type = message_type
	definition.handler = handler
	definition.allow_from_client = allow_from_client
	definition.allow_from_authority = allow_from_authority
	definition.required_channel = channel
	definition.required_delivery = delivery
	definition.per_peer_rate = rate
	definition.per_peer_burst = burst
	return definition


func _frame(message_type: String, payload: PackedByteArray, sequence: int, channel: int) -> PackedByteArray:
	var envelope: RedotP2PMessageEnvelope = RedotP2PMessageEnvelope.new()
	envelope.message_type = message_type
	envelope.payload = payload
	envelope.sequence = sequence
	envelope.channel = channel
	envelope.delivery = RedotP2PTransportAdapter.Delivery.RELIABLE
	return envelope.encode(RedotP2PProtocolLimits.new())


func _expect_decode_status(
	frame: PackedByteArray,
	limits: RedotP2PProtocolLimits,
	expected_status: String,
	label: String
) -> void:
	var decoded: RedotP2PEnvelopeDecodeResult = RedotP2PMessageEnvelope.decode(frame, limits)
	_expect_equal(decoded.status_code, expected_status, label)


func _expect_true(condition: bool, label: String) -> void:
	if not condition:
		_failures.append(label)


func _expect_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		_failures.append("%s (expected %s, got %s)" % [label, str(expected), str(actual)])
