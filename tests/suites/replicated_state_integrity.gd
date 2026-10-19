extends RedotP2PTestSuite

const CHANNEL: int = RedotP2PReplicatedStateService.STATE_CHANNEL
const RELIABLE: int = RedotP2PTransportAdapter.Delivery.RELIABLE
const REMOVED: String = "state.player.removed"


class FailingTransport extends RedotP2PFakeTransportAdapter:
	var fail_sends: bool = true


	func send_packet(peer_id: int, packet: PackedByteArray, channel: int, delivery: int) -> Error:
		if fail_sends:
			return ERR_UNAVAILABLE
		return super.send_packet(peer_id, packet, channel, delivery)


func run(tree: SceneTree) -> void:
	await _test_disconnects(tree)
	await _test_removal_validation(tree)
	await _test_snapshot_admission(tree)
	await _test_snapshot_bytes(tree)
	await _test_failed_sends(tree)


func _fixture(tree: SceneTree, authority: bool = true, online: bool = true,
		transport: RedotP2PFakeTransportAdapter = null) -> RedotP2PReplicatedStateService:
	var network: RedotP2PNetworkService = RedotP2PNetworkService.new()
	tree.root.add_child(network)
	var limits: RedotP2PProtocolLimits = RedotP2PProtocolLimits.new()
	# Keep the negative-case burst below the session disconnect threshold.
	limits.max_protocol_violations = 16
	_expect_equal(network.configure(limits), OK, "state fixture limits configure")
	if transport == null:
		transport = RedotP2PFakeTransportAdapter.new()
	_expect_equal(network.set_transport(transport), OK, "state fixture transport attaches")
	var state: RedotP2PReplicatedStateService = RedotP2PReplicatedStateService.new()
	network.add_child(state)
	_expect_equal(state.attach(network), OK, "state fixture schemas register")
	if online:
		_expect_equal(network.host("*", 7777, 8) if authority else network.join("fixture", 7777),
			OK, "state fixture session starts")
	return state


func _inject(transport: RedotP2PFakeTransportAdapter, sender: int, message: String,
		payload: PackedByteArray, sequence: int) -> void:
	transport.inject_packet(sender, _frame(message, payload, sequence, CHANNEL), CHANNEL, RELIABLE)


func _request(transport: RedotP2PFakeTransportAdapter, peer_id: int, key: String,
		value: Variant, sequence: int = 1) -> void:
	_inject(transport, peer_id, RedotP2PReplicatedStateService.PLAYER_REQUEST,
		JSON.stringify({"key": key, "value": value}).to_utf8_buffer(), sequence)


func _relay(source: RedotP2PFakeTransportAdapter, target: RedotP2PFakeTransportAdapter) -> void:
	for packet: Dictionary in source.sent_packets:
		target.inject_packet(1, packet["packet"], int(packet["channel"]), int(packet["delivery"]))
	source.sent_packets.clear()


func _test_disconnects(tree: SceneTree) -> void:
	var host: RedotP2PReplicatedStateService = _fixture(tree)
	var client: RedotP2PReplicatedStateService = _fixture(tree, false)
	var transport: RedotP2PFakeTransportAdapter = host._network.get_transport() as RedotP2PFakeTransportAdapter
	var client_transport: RedotP2PFakeTransportAdapter = client._network.get_transport() as RedotP2PFakeTransportAdapter
	_expect_equal(host.set_game_data("seed", 7), OK, "game data seeds disconnect fixture")
	_request(transport, 2, "profile:title", "departing")
	_request(transport, 20, "profile:title", "remaining")
	_relay(transport, client_transport)
	_expect_equal(client.get_player_data(2, "profile:title"), "departing", "client receives departing player")
	transport.disconnect_peer(2)
	_expect_true(not host.get_player_snapshot().has(2), "disconnect releases authority player state")
	_expect_true(not host._revisions.has("p:2:profile:title"), "disconnect releases authority player revisions")
	_expect_true(host._revisions.has("p:20:profile:title"), "disconnect preserves other peer revisions")
	_expect_equal(transport.sent_packets.size(), 1, "disconnect broadcasts one removal")
	_relay(transport, client_transport)
	_expect_true(not client.get_player_snapshot().has(2), "authority removal clears client player state")
	_expect_true(not client._revisions.has("p:2:profile:title"), "authority removal clears client revisions")
	_expect_equal(client.get_player_data(20, "profile:title"), "remaining", "removal preserves other players")
	_request(transport, 2, "profile:title", "rejoined")
	_relay(transport, client_transport)
	_expect_equal(client.get_player_data(2, "profile:title"), "rejoined", "reused peer id accepts revision one")
	transport.disconnect_peer(2)
	transport.disconnect_peer(20)
	var accepted_cycles: int = 0
	for index: int in range(3000):
		var peer_id: int = index + 100
		transport.inject_peer_connected(peer_id)
		_request(transport, peer_id, "title", "cycling")
		if host.get_player_data(peer_id, "title") == "cycling":
			accepted_cycles += 1
		transport.disconnect_peer(peer_id)
		transport.sent_packets.clear()
	_expect_equal(accepted_cycles, 3000, "all reconnect cycles retain snapshot capacity")
	_expect_equal(host.get_player_snapshot().size(), 0, "player churn leaves no retained players")
	_expect_equal(host._revisions.size(), 1, "player churn leaves only game revisions")
	client_transport.disconnect_peer(1, RedotP2PStatusCodes.AUTHORITY_LOST)
	_expect_equal(client.get_player_snapshot(), {}, "authority loss clears every client player")
	_expect_equal(client.get_game_snapshot(), {}, "authority loss clears client game data")
	_expect_equal(client._revisions, {}, "authority loss clears client revisions")
	host._network.stop()
	_expect_equal(host.get_game_snapshot(), {}, "session stop clears authority state")
	_expect_equal(host._revisions.size(), 0, "session stop clears authority revisions")
	host._network.queue_free()
	client._network.queue_free()
	await tree.process_frame
	client = _fixture(tree, false)
	client._on_snapshot(1, _snapshot_payload({"seed": 1}, {"2": {"title": "old"}}, {"g:seed": "1", "p:2:title": "1"}))
	client._network.get_transport()._set_state(RedotP2PTransportAdapter.State.FAILED, RedotP2PStatusCodes.AUTHORITY_LOST)
	_expect_equal(client.get_player_snapshot(), {}, "failed session clears client players")
	_expect_equal(client._revisions, {}, "failed session clears client revisions")
	client._network.queue_free()
	await tree.process_frame


func _test_removal_validation(tree: SceneTree) -> void:
	var client: RedotP2PReplicatedStateService = _fixture(tree, false)
	var transport: RedotP2PFakeTransportAdapter = client._network.get_transport() as RedotP2PFakeTransportAdapter
	client._on_snapshot(1, _snapshot_payload({}, {"2": {"title": "keep"}}, {"p:2:title": "1"}))
	var sequence: int = 1
	for payload: PackedByteArray in ["02".to_utf8_buffer(), "-2".to_utf8_buffer(),
		"2.0".to_utf8_buffer(), "2 ".to_utf8_buffer(), "9223372036854775808".to_utf8_buffer(),
		"2".repeat(20).to_utf8_buffer(), PackedByteArray([0xFF]), PackedByteArray()]:
		_inject(transport, 1, REMOVED, payload, sequence)
		sequence += 1
	_expect_equal(client.get_player_data(2, "title"), "keep", "malformed removals preserve client state")
	_inject(transport, 3, REMOVED, "2".to_utf8_buffer(), sequence)
	_expect_equal(client.get_player_data(2, "title"), "keep", "non-authority cannot remove a player")
	transport.inject_packet(1, _frame(REMOVED, "2".to_utf8_buffer(), sequence, 1), 1, RELIABLE)
	transport.inject_packet(1, _frame(REMOVED, "2".to_utf8_buffer(), sequence, CHANNEL,
		RedotP2PTransportAdapter.Delivery.UNRELIABLE), CHANNEL, RedotP2PTransportAdapter.Delivery.UNRELIABLE)
	_expect_equal(client.get_player_data(2, "title"), "keep", "removal requires reliable state channel")
	_inject(transport, 1, REMOVED, "2".to_utf8_buffer(), sequence)
	_expect_equal(client.get_player_snapshot(), {}, "valid authority removal is applied")
	client._on_snapshot(1, _snapshot_payload({}, {"2": {"title": "rejoined"}}, {"p:2:title": "1"}))
	_inject(transport, 1, REMOVED, "2".to_utf8_buffer(), sequence)
	_expect_equal(client.get_player_data(2, "title"), "rejoined", "replayed removal is rejected")
	client._network.stop()
	_expect_equal(client.get_player_snapshot(), {}, "explicit client stop clears replicated players")
	client._network.queue_free()
	await tree.process_frame
	var host: RedotP2PReplicatedStateService = _fixture(tree)
	transport = host._network.get_transport() as RedotP2PFakeTransportAdapter
	_request(transport, 2, "title", "keep")
	_inject(transport, 2, REMOVED, "2".to_utf8_buffer(), 2)
	_expect_equal(host.get_player_data(2, "title"), "keep", "client removal request is rejected by authority")
	host._network.stop()
	host._network.queue_free()
	await tree.process_frame


func _test_snapshot_admission(tree: SceneTree) -> void:
	var state: RedotP2PReplicatedStateService = _fixture(tree, true, false)
	_expect_true(state.set_game_data("k".repeat(64), 1) != OK, "64-byte game key cannot poison revision keys")
	_expect_true(state.set_player_data("k".repeat(64), 1) != OK, "64-byte player key cannot poison revision keys")
	_expect_true(state.set_game_data("deep", [[["leaf"]]]) != OK, "game nesting includes snapshot wrappers")
	_expect_true(state.set_player_data("deep", [["leaf"]]) != OK, "player nesting includes snapshot wrappers")
	_expect_equal(state.get_game_snapshot().size(), 0, "rejected values leave game state empty")
	_expect_equal(state.get_player_snapshot().size(), 0, "rejected values leave player state empty")
	_expect_equal(state._revisions.size(), 0, "rejected values do not advance revisions")
	state.reset()
	_expect_equal(state.set_game_data("k".repeat(62), [["leaf"]]), OK, "maximum wrapped game key and depth fit")
	_expect_equal(state.set_player_data("k".repeat(60), ["leaf"]), OK, "maximum wrapped player key and depth fit")
	state._network.host("*", 7777, 8)
	var transport: RedotP2PFakeTransportAdapter = state._network.get_transport() as RedotP2PFakeTransportAdapter
	var client: RedotP2PReplicatedStateService = _fixture(tree, false)
	transport.inject_peer_connected(2)
	_relay(transport, client._network.get_transport() as RedotP2PFakeTransportAdapter)
	_expect_equal(client.get_game_snapshot(), state.get_game_snapshot(), "boundary game data round-trips through snapshot")
	_expect_equal(client.get_player_snapshot(), state.get_player_snapshot(), "boundary player data round-trips through snapshot")
	_expect_equal(client._revisions, state._revisions, "boundary revisions round-trip through snapshot")
	state._network.stop()
	state.reset()
	for index: int in range(127):
		_expect_equal(state.set_game_data("key%d" % index, str(index)), OK, "combined revision budget accepts key %d" % index)
	_expect_equal(state.set_player_data("title", "last"), OK, "128th combined revision fits")
	var before: Dictionary = state.get_player_snapshot()
	_expect_true(state.set_player_data("extra", "overflow") != OK, "129th combined revision is rejected")
	_expect_equal(state.get_player_snapshot(), before, "revision overflow does not mutate state")
	_expect_equal(state._revisions.size(), 128, "revision overflow does not mutate revisions")
	state._network.host("*", 7777, 8)
	client._network.stop()
	client._network.join("fixture", 7777)
	transport.inject_peer_connected(2)
	_relay(transport, client._network.get_transport() as RedotP2PFakeTransportAdapter)
	_expect_equal(client.get_game_snapshot(), state.get_game_snapshot(), "128 revisions remain snapshot-decodable")
	_expect_equal(client._revisions.size(), 128, "snapshot retains exactly 128 revisions")
	state._network.stop()
	client._network.stop()
	state._network.queue_free()
	client._network.queue_free()
	await tree.process_frame


func _test_snapshot_bytes(tree: SceneTree) -> void:
	var state: RedotP2PReplicatedStateService = _fixture(tree, true, false)
	for index: int in range(47):
		_expect_equal(state.set_game_data("key%d" % index, "x".repeat(1000)), OK, "snapshot byte fixture accepts base key")
	var game: Dictionary = state.get_game_snapshot()
	game["edge"] = ""
	var revisions: Dictionary = {}
	for key: Variant in state._revisions:
		revisions[key] = str(int(state._revisions[key]))
	var base_size: int = _snapshot_payload(game, {}, revisions).size()
	var padding: int = RedotP2PReplicatedStateService.MAX_SNAPSHOT_BYTES - base_size
	_expect_true(padding >= 0 and padding <= 1024, "snapshot byte boundary uses a permitted string")
	if padding >= 0 and padding <= 1024:
		_expect_true(state.set_game_data("edge", "x".repeat(padding)) != OK, "snapshot budget includes prospective revision bytes")
		_expect_true(not state.get_game_snapshot().has("edge"), "snapshot byte overflow does not commit")
		_expect_true(not state._revisions.has("g:edge"), "snapshot byte overflow does not advance revision")
		revisions["g:edge"] = "1"
		var overhead: int = _snapshot_payload(game, {}, revisions).size() - base_size
		_expect_equal(state.set_game_data("edge", "x".repeat(padding - overhead)), OK, "complete snapshot at byte ceiling fits")
	state._network.host("*", 7777, 8)
	var client: RedotP2PReplicatedStateService = _fixture(tree, false)
	var transport: RedotP2PFakeTransportAdapter = state._network.get_transport() as RedotP2PFakeTransportAdapter
	transport.inject_peer_connected(2)
	_relay(transport, client._network.get_transport() as RedotP2PFakeTransportAdapter)
	_expect_equal(client.get_game_snapshot(), state.get_game_snapshot(), "snapshot byte ceiling round-trips")
	_expect_equal(client._revisions, state._revisions, "snapshot byte ceiling retains revisions")
	state._network.stop()
	client._network.stop()
	state._network.queue_free()
	client._network.queue_free()
	await tree.process_frame


func _test_failed_sends(tree: SceneTree) -> void:
	var transport: FailingTransport = FailingTransport.new()
	var state: RedotP2PReplicatedStateService = _fixture(tree, true, true, transport)
	var signals: Array[String] = []
	state.game_data_updated.connect(func(key: String) -> void: signals.append(key))
	state.player_data_updated.connect(func(_peer_id: int, key: String) -> void: signals.append(key))
	_expect_equal(state.set_game_data("title", "game"), ERR_UNAVAILABLE, "game transport failure is returned")
	_expect_equal(state.set_player_data("title", "player"), ERR_UNAVAILABLE, "player transport failure is returned")
	_expect_equal(state.get_game_snapshot(), {}, "failed game send does not commit")
	_expect_equal(state.get_player_snapshot(), {}, "failed player send does not commit")
	_expect_equal(state._revisions, {}, "failed sends do not advance revisions")
	_expect_equal(signals, [], "failed sends emit no update signals")
	state.reset()
	transport.fail_sends = false
	_expect_equal(state.set_game_data("title", "game"), OK, "game retry succeeds")
	_expect_equal(state.set_player_data("title", "player"), OK, "player retry succeeds")
	_expect_equal(state._revisions, {"g:title": 1, "p:1:title": 1}, "first successful sends use revision one")
	transport.sent_packets.clear()
	signals.clear()
	var value: Array[String] = ["x".repeat(1024), "x".repeat(1024), "x".repeat(1024), ""]
	var request: Dictionary = {"key": "large", "value": value}
	value[3] = "x".repeat(4089 - JSON.stringify(request).to_utf8_buffer().size())
	var payload: PackedByteArray = JSON.stringify(request).to_utf8_buffer()
	_expect_equal(payload.size(), 4089, "oversize delta fixture has a permitted inbound size")
	_expect_true(RedotP2PJsonValue.is_safe(request), "oversize delta fixture has permitted JSON values")
	_request(transport, 2, "large", value)
	_expect_equal(state.get_player_data(2, "large"), null, "oversized outgoing player delta does not commit")
	_expect_true(state.set_game_data("large", value) != OK, "oversized outgoing game delta is rejected")
	_expect_equal(state.get_game_data("large"), null, "oversized outgoing game delta does not commit")
	_expect_equal(state._revisions, {"g:title": 1, "p:1:title": 1}, "oversized deltas leave revisions unchanged")
	_expect_equal(signals, [], "oversized deltas emit no update signals")
	_expect_equal(transport.sent_packets.size(), 0, "oversized deltas emit no packets")
	state._network.stop()
	state._network.queue_free()
	await tree.process_frame


func _snapshot_payload(game: Dictionary, players: Dictionary, revisions: Dictionary) -> PackedByteArray:
	return JSON.stringify({"game": game, "players": players, "revisions": revisions}).to_utf8_buffer()
