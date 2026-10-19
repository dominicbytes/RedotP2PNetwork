extends RedotP2PTestSuite

const RELIABLE: int = RedotP2PTransportAdapter.Delivery.RELIABLE
const UNRELIABLE: int = RedotP2PTransportAdapter.Delivery.UNRELIABLE


func run(tree: SceneTree) -> void:
	await _test_receive_metadata(tree)
	await _test_enet_work_budget(tree, true)
	await _test_enet_work_budget(tree, false)


func _test_receive_metadata(tree: SceneTree) -> void:
	# Wildcard definitions isolate envelope/transport checks from definition checks.
	var cases: Array[Dictionary] = [
		{"label": "transport channel", "channel": 1, "native_channel": 2,
			"delivery": RELIABLE, "native_delivery": RELIABLE,
			"required_channel": -1, "required_delivery": -1,
			"reason": RedotP2PStatusCodes.MESSAGE_CHANNEL_INVALID},
		{"label": "transport delivery", "channel": 1, "native_channel": 1,
			"delivery": UNRELIABLE, "native_delivery": RELIABLE,
			"required_channel": -1, "required_delivery": -1,
			"reason": RedotP2PStatusCodes.MESSAGE_DELIVERY_INVALID},
		{"label": "registered channel", "channel": 2, "native_channel": 2,
			"delivery": RELIABLE, "native_delivery": RELIABLE,
			"required_channel": 1, "required_delivery": -1,
			"reason": RedotP2PStatusCodes.MESSAGE_CHANNEL_INVALID},
		{"label": "registered delivery", "channel": 1, "native_channel": 1,
			"delivery": UNRELIABLE, "native_delivery": UNRELIABLE,
			"required_channel": -1, "required_delivery": RELIABLE,
			"reason": RedotP2PStatusCodes.MESSAGE_DELIVERY_INVALID},
	]
	for test_case: Dictionary in cases:
		var label: String = str(test_case["label"])
		var service: RedotP2PNetworkService = RedotP2PNetworkService.new()
		tree.root.add_child(service)
		var transport: RedotP2PFakeTransportAdapter = RedotP2PFakeTransportAdapter.new()
		_expect_equal(service.set_transport(transport), OK, label + " transport attaches")
		_expect_equal(service.host("*", 7777, 4), OK, label + " authority starts")
		var handled: Array[int] = []
		var rejected: Array[String] = []
		service.message_rejected.connect(
			func(_peer_id: int, reason: String) -> void: rejected.append(reason)
		)
		var definition: RedotP2PMessageDefinition = _definition(
			"fixture.metadata",
			func(peer_id: int, _payload: PackedByteArray) -> void: handled.append(peer_id),
			true, false, int(test_case["required_channel"]), int(test_case["required_delivery"]), 8.0, 8
		)
		_expect_equal(service.register_message(definition), OK, label + " definition registers")
		transport.inject_packet(2,
			_frame("fixture.metadata", PackedByteArray([1]), 1, int(test_case["channel"]), int(test_case["delivery"])),
			int(test_case["native_channel"]), int(test_case["native_delivery"]))
		_expect_equal(handled.size(), 0, label + " mismatch never reaches the handler")
		_expect_equal(rejected, [test_case["reason"]], label + " mismatch has the exact rejection reason")
		# A rejected frame must not consume sequence state or the valid delivery path.
		transport.inject_packet(2, _frame("fixture.metadata", PackedByteArray([1]), 1, 1), 1, RELIABLE)
		_expect_equal(handled.size(), 1, label + " valid control reaches the handler")
		service.stop()
		service.queue_free()
		await tree.process_frame


func _test_enet_work_budget(tree: SceneTree, packet_budget: bool) -> void:
	var label: String = "ENet packet budget" if packet_budget else "ENet byte budget"
	var limits: RedotP2PProtocolLimits = RedotP2PProtocolLimits.new()
	limits.max_frame_bytes = 256
	limits.max_payload_bytes = 220
	limits.max_packets_per_tick = 1 if packet_budget else 64
	limits.max_bytes_per_tick = 4096 if packet_budget else 256
	var host: RedotP2PEnetTransportAdapter = RedotP2PEnetTransportAdapter.new()
	var client: RedotP2PEnetTransportAdapter = RedotP2PEnetTransportAdapter.new()
	tree.root.add_child(host)
	tree.root.add_child(client)
	await tree.process_frame
	_expect_equal(host.configure(limits), OK, label + " configures")
	# Use dedicated loopback ports, separate from the two-process fixtures.
	_expect_equal(host.host("127.0.0.1", 33891 if packet_budget else 33892, 2), OK, label + " host starts")
	_expect_equal(client.join("127.0.0.1", 33891 if packet_budget else 33892), OK, label + " client starts")
	host.set_process(false)
	client.set_process(false)
	var deadline: int = Time.get_ticks_msec() + 3000
	while client.get_state() != RedotP2PTransportAdapter.State.CONNECTED and Time.get_ticks_msec() < deadline:
		host._process(0.0)
		client._process(0.0)
		await tree.create_timer(0.005).timeout
	_expect_equal(client.get_state(), RedotP2PTransportAdapter.State.CONNECTED, label + " connects")
	var received: Array[PackedByteArray] = []
	host.packet_received.connect(
		func(_peer_id: int, packet: PackedByteArray, _channel: int, _delivery: int) -> void:
			received.append(packet)
	)
	var packet: PackedByteArray = PackedByteArray()
	packet.resize(256)
	packet.fill(7)
	for index: int in range(3):
		_expect_equal(client.send_packet(1, packet, 0, RELIABLE), OK, label + " packet %d sends" % index)
	# Poll the native queue without draining through the adapter: all three packets
	# must be pending before a single adapter tick can prove its work bound.
	deadline = Time.get_ticks_msec() + 3000
	while host._peer.get_available_packet_count() < 3 and Time.get_ticks_msec() < deadline:
		client._peer.poll()
		host._peer.poll()
		await tree.create_timer(0.005).timeout
	_expect_equal(host._peer.get_available_packet_count(), 3, label + " has a queued burst")
	for tick: int in range(1, 4):
		host._process(0.0)
		_expect_equal(received.size(), tick, label + " drains one packet per tick")
		_expect_equal(host._peer.get_available_packet_count(), 3 - tick, label + " preserves pending packets")
	client.stop()
	host.stop()
	client.queue_free()
	host.queue_free()
	await tree.process_frame
