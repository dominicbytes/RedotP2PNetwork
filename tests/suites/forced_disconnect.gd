extends RedotP2PTestSuite

const RELIABLE: int = RedotP2PTransportAdapter.Delivery.RELIABLE


func run(tree: SceneTree) -> void:
	_test_encoder_bound()
	await _test_session_guards_and_quarantine(tree)
	await _test_live_disconnect(tree, false, 32951)
	await _test_live_disconnect(tree, true, 32952)


func _test_encoder_bound() -> void:
	_expect_true(not _frame("fixture.input", PackedByteArray(), 4_294_967_295, 0).is_empty(), "u32 maximum encodes")
	for sequence: int in [0, -1, 4_294_967_296, 4_294_967_297]:
		_expect_true(_frame("fixture.input", PackedByteArray(), sequence, 0).is_empty(), "out-of-range sequence is rejected")


func _test_session_guards_and_quarantine(tree: SceneTree) -> void:
	var network: RedotP2PNetworkService = RedotP2PNetworkService.new()
	tree.root.add_child(network)
	var transport: RedotP2PFakeTransportAdapter = RedotP2PFakeTransportAdapter.new()
	_expect_equal(network.set_transport(transport), OK, "guard transport attaches")
	_expect_equal(network.host("*", 7777, 4), OK, "guard session starts")
	var hits: Array[int] = []
	_expect_equal(network.register_message(_definition("fixture.input", func(id: int, _data: PackedByteArray) -> void: hits.append(id), true, true, 0, RELIABLE, 100.0, 100)), OK, "guard message registers")
	var packet: PackedByteArray = _frame("fixture.input", PackedByteArray(), 1, 0)
	transport.inject_packet(2, packet, 0, RELIABLE)
	_expect_equal(network.host("*", 7777, 4), ERR_ALREADY_IN_USE, "active host is rejected")
	transport.inject_packet(2, packet, 0, RELIABLE)
	_expect_equal(hits.size(), 1, "active host preserves replay state")
	_expect_equal(network.join("fixture", 7777), ERR_ALREADY_IN_USE, "active join is rejected")
	transport.inject_packet(2, packet, 0, RELIABLE)
	_expect_equal(hits.size(), 1, "active join preserves replay state")
	for index: int in 4:
		transport.inject_packet(3, PackedByteArray([1]), 0, RELIABLE)
	transport.inject_packet(3, packet, 0, RELIABLE)
	_expect_equal(hits.size(), 1, "queued valid frame cannot escape synchronous disconnect cleanup")
	transport.inject_packet(3, PackedByteArray([1]), 0, RELIABLE)
	_expect_equal(transport.disconnected_peers.size(), 1, "quarantined frames do not disconnect again")
	transport.inject_peer_connected(3)
	transport.inject_packet(3, packet, 0, RELIABLE)
	_expect_equal(hits.size(), 2, "new connection clears quarantine")
	for index: int in 4:
		transport.inject_packet(4, PackedByteArray([1]), 0, RELIABLE)
	network.stop()
	_expect_equal(network.host("*", 7777, 4), OK, "new session starts")
	transport.inject_packet(4, packet, 0, RELIABLE)
	_expect_equal(hits.size(), 3, "session reset clears quarantine")
	network.stop()
	network.queue_free()
	await tree.process_frame


func _adapter(websocket: bool) -> RedotP2PTransportAdapter:
	if websocket:
		var adapter: RedotP2PWebSocketTransportAdapter = RedotP2PWebSocketTransportAdapter.new()
		adapter.enable_plaintext_loopback_development(true)
		return adapter
	return RedotP2PEnetTransportAdapter.new()


func _wait_for(tree: SceneTree, condition: Callable) -> bool:
	var deadline: int = Time.get_ticks_msec() + 4000
	while not condition.call() and Time.get_ticks_msec() < deadline:
		await tree.process_frame
	return bool(condition.call())


func _test_live_disconnect(tree: SceneTree, websocket: bool, port: int) -> void:
	var network: RedotP2PNetworkService = RedotP2PNetworkService.new()
	tree.root.add_child(network)
	var host: RedotP2PTransportAdapter = _adapter(websocket)
	_expect_equal(network.set_transport(host), OK, "live host attaches")
	var access: RedotP2PCapabilityService = RedotP2PCapabilityService.new()
	tree.root.add_child(access)
	access.attach(network)
	var connected: Array[int] = []
	var disconnected: Array[Dictionary] = []
	network.peer_connected.connect(func(id: int) -> void: connected.append(id))
	network.peer_disconnected.connect(func(id: int, reason: String) -> void: disconnected.append({"id": id, "reason": reason}))
	var hits: Array[int] = []
	network.register_message(_definition("fixture.input", func(id: int, _data: PackedByteArray) -> void: hits.append(id), true, false, 0, RELIABLE, 100.0, 100))
	_expect_equal(network.host("127.0.0.1", port, 1), OK, "live host starts")
	_expect_equal(network.disconnect_peer(999999), ERR_DOES_NOT_EXIST, "unknown live peer is rejected")
	var client: RedotP2PTransportAdapter = _adapter(websocket)
	tree.root.add_child(client)
	_expect_equal(client.join("127.0.0.1", port), OK, "live client starts")
	var admitted: bool = await _wait_for(tree, func() -> bool: return connected.size() == 1 and client.get_state() == RedotP2PTransportAdapter.State.CONNECTED)
	_expect_true(admitted, "live client is admitted")
	if admitted and websocket:
		var excess: RedotP2PTransportAdapter = _adapter(true)
		tree.root.add_child(excess)
		_expect_equal(excess.join("127.0.0.1", port), OK, "excess client starts")
		_expect_true(await _wait_for(tree, func() -> bool: return excess.get_state() in [RedotP2PTransportAdapter.State.STOPPED, RedotP2PTransportAdapter.State.FAILED]), "capacity rejects excess client")
		_expect_equal(connected.size(), 1, "excess client is never admitted")
		_expect_equal(disconnected.size(), 0, "unadmitted client emits no public disconnect")
		excess.stop()
		excess.queue_free()
		await tree.process_frame
	if admitted:
		var id: int = connected[0]
		access.assign_role(id, RedotP2PCapabilityService.ROLE_MODERATOR)
		access.grant_capability(id, "fixture.use")
		var packet: PackedByteArray = _frame("fixture.input", PackedByteArray(), 1, 0)
		client.send_packet(1, packet, 0, RELIABLE)
		_expect_true(await _wait_for(tree, func() -> bool: return hits.size() == 1), "live frame dispatches")
		client.send_packet(1, packet, 0, RELIABLE)
		_expect_true(await _wait_for(tree, func() -> bool: return not network._violations.is_empty()), "live replay seeds violation state")
		_expect_equal(network.disconnect_peer(id, RedotP2PStatusCodes.PEER_BANNED), OK, "forced live removal succeeds")
		_expect_equal(disconnected.size(), 1, "forced removal emits immediately once")
		if not disconnected.is_empty():
			_expect_equal(disconnected[0], {"id": id, "reason": RedotP2PStatusCodes.PEER_BANNED}, "forced removal retains supplied reason")
		_expect_true(network._last_sequences.is_empty(), "forced removal clears replay state")
		_expect_true(network._inbound_buckets.is_empty(), "forced removal clears rate state")
		_expect_true(network._violations.is_empty(), "forced removal clears violation state")
		_expect_equal(access.get_role(id), RedotP2PCapabilityService.ROLE_PLAYER, "forced removal clears role")
		_expect_true(not access.has_capability(id, "fixture.use"), "forced removal clears grant")
		host.call("_on_peer_disconnected", id)
		_expect_equal(disconnected.size(), 1, "late native disconnect is suppressed")
		_expect_equal(network.disconnect_peer(id), ERR_DOES_NOT_EXIST, "repeated forced removal is rejected")
	client.stop()
	client.queue_free()
	await tree.process_frame
	var replacement: RedotP2PTransportAdapter = _adapter(websocket)
	tree.root.add_child(replacement)
	_expect_equal(replacement.join("127.0.0.1", port), OK, "replacement client starts")
	_expect_true(await _wait_for(tree, func() -> bool: return connected.size() == 2 and replacement.get_state() == RedotP2PTransportAdapter.State.CONNECTED), "replacement fits capacity-one host")
	var client_disconnects: Array[String] = []
	replacement.peer_disconnected.connect(func(_id: int, reason: String) -> void: client_disconnects.append(reason))
	_expect_equal(replacement.disconnect_peer(1, RedotP2PStatusCodes.PEER_BANNED), OK, "client can force authority removal")
	_expect_equal(client_disconnects, [RedotP2PStatusCodes.PEER_BANNED], "client forced disconnect retains reason exactly once")
	replacement.stop()
	network.stop()
	replacement.queue_free()
	access.queue_free()
	network.queue_free()
	await tree.process_frame
