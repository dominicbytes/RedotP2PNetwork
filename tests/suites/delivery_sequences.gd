extends RedotP2PTestSuite

const RELIABLE: int = RedotP2PTransportAdapter.Delivery.RELIABLE
const ORDERED: int = RedotP2PTransportAdapter.Delivery.UNRELIABLE_ORDERED
const UNORDERED: int = RedotP2PTransportAdapter.Delivery.UNRELIABLE

var _network: RedotP2PNetworkService
var _transport: RedotP2PFakeTransportAdapter
var _hits: Array[int] = []
var _rejections: Array[String] = []


func run(tree: SceneTree) -> void:
	_start(tree)
	_inject(2, 10, 0, UNORDERED)
	_inject(2, 1, 0, RELIABLE)
	_inject(2, 1, 0, ORDERED)
	_inject(2, 2, 0, RELIABLE)
	_expect_equal(_hits.size(), 4, "overtaken reliable and ordered frames use independent sequence spaces")
	for sequence: int in [9, 8, 7, 6]:
		_inject(2, sequence, 0, UNORDERED)
	_expect_equal(_hits.size(), 8, "four delayed unseen unordered frames dispatch")
	_expect_true(_rejections.is_empty(), "honest reordering emits no rejection")
	_expect_true(_transport.disconnected_peers.is_empty(), "honest reordering cannot disconnect")
	_inject(2, 1, 0, ORDERED)
	_inject(2, 10, 0, UNORDERED)
	_expect_equal(_hits.size(), 8, "unreliable duplicates do not dispatch")
	_expect_true(_rejections.is_empty(), "unreliable replays drop silently")
	_inject(2, 1, 0, RELIABLE)
	_expect_equal(_rejections, [RedotP2PStatusCodes.MESSAGE_REPLAYED], "reliable replay remains a violation")
	await _finish(tree)
	await _test_window(tree)
	await _test_isolation_and_cleanup(tree)
	await _test_outbound(tree)
	await _test_reliable_threshold(tree)
	for delivery: int in [RELIABLE, ORDERED, UNORDERED]:
		await _test_rate_limit(tree, delivery)


func _start(tree: SceneTree, rate: float = 1000.0, burst: int = 1000) -> void:
	_hits.clear()
	_rejections.clear()
	_network = RedotP2PNetworkService.new()
	tree.root.add_child(_network)
	_transport = RedotP2PFakeTransportAdapter.new()
	_expect_equal(_network.set_transport(_transport), OK, "sequence transport attaches")
	_expect_equal(_network.host("*", 7777, 8), OK, "sequence session starts")
	_network.message_rejected.connect(func(_id: int, reason: String) -> void: _rejections.append(reason))
	_expect_equal(_network.register_message(_definition("fixture.sequence", func(id: int, _data: PackedByteArray) -> void: _hits.append(id), true, true, -1, -1, rate, burst)), OK, "sequence message registers")


func _finish(tree: SceneTree) -> void:
	_network.stop()
	_network.queue_free()
	await tree.process_frame


func _inject(peer_id: int, sequence: int, channel: int, delivery: int) -> void:
	_transport.inject_packet(peer_id, _frame("fixture.sequence", PackedByteArray(), sequence, channel, delivery), channel, delivery)


func _test_window(tree: SceneTree) -> void:
	_start(tree)
	_inject(2, 100, 0, UNORDERED)
	_inject(2, 37, 0, UNORDERED)
	_expect_equal(_hits.size(), 2, "bit 63 accepts unseen frame")
	_inject(2, 37, 0, UNORDERED)
	_inject(2, 36, 0, UNORDERED)
	_expect_equal(_hits.size(), 2, "bit 63 duplicate and distance 64 drop")
	_inject(2, 101, 0, UNORDERED)
	_inject(2, 37, 0, UNORDERED)
	_inject(2, 100, 0, UNORDERED)
	_expect_equal(_hits.size(), 3, "window shift evicts old bit and preserves recent duplicate")
	_inject(2, 1000, 0, UNORDERED)
	_inject(2, 999, 0, UNORDERED)
	_expect_equal(_hits.size(), 5, "large jump resets window without shift wrap")
	_inject(2, 4_294_967_295, 0, UNORDERED)
	_inject(2, 4_294_967_232, 0, UNORDERED)
	_inject(2, 4_294_967_231, 0, UNORDERED)
	_expect_equal(_hits.size(), 7, "window boundary works at u32 maximum")
	_expect_true(_rejections.is_empty(), "stale unordered traffic has no violation penalty")
	await _finish(tree)


func _test_isolation_and_cleanup(tree: SceneTree) -> void:
	_start(tree)
	_inject(2, 100, 0, UNORDERED)
	_inject(3, 1, 0, UNORDERED)
	_inject(2, 1, 1, UNORDERED)
	_inject(3, 1, 1, UNORDERED)
	_expect_equal(_hits.size(), 4, "replay windows isolate peer and channel")
	_transport.disconnect_peer(2)
	_transport.inject_peer_connected(2)
	_inject(2, 1, 0, UNORDERED)
	_inject(2, 1, 1, UNORDERED)
	_expect_equal(_hits.size(), 6, "disconnect clears every peer window")
	_inject(3, 1, 0, UNORDERED)
	_expect_equal(_hits.size(), 6, "other peer window survives disconnect")
	_network.stop()
	_expect_equal(_network.host("*", 7777, 8), OK, "window session restarts")
	_inject(3, 1, 0, UNORDERED)
	_expect_equal(_hits.size(), 7, "session reset clears replay windows")
	await _finish(tree)


func _test_outbound(tree: SceneTree) -> void:
	_start(tree)
	for delivery: int in [RELIABLE, ORDERED, UNORDERED, RELIABLE]:
		_expect_equal(_network.send_message("fixture.sequence", PackedByteArray(), 2, 0, delivery), OK, "outbound delivery sends")
	var sequences: Array[int] = []
	for packet: Dictionary in _transport.sent_packets:
		var result: RedotP2PEnvelopeDecodeResult = RedotP2PMessageEnvelope.decode(packet["packet"], RedotP2PProtocolLimits.new())
		_expect_true(result.is_ok(), "outbound frame decodes")
		if result.is_ok():
			sequences.append(result.envelope.sequence)
	_expect_equal(sequences, [1, 1, 1, 2], "outbound sequences are scoped by delivery")
	_expect_equal(_network.send_message("fixture.sequence", PackedByteArray(), 2, 1, RELIABLE), OK, "other channel sends")
	var other: RedotP2PEnvelopeDecodeResult = RedotP2PMessageEnvelope.decode(_transport.sent_packets[-1]["packet"], RedotP2PProtocolLimits.new())
	_expect_equal(other.envelope.sequence, 1, "outbound channel counter is independent")
	await _finish(tree)


func _test_reliable_threshold(tree: SceneTree) -> void:
	_start(tree)
	_inject(2, 1, 0, RELIABLE)
	for index: int in 4:
		_inject(2, 1, 0, RELIABLE)
	_expect_equal(_transport.disconnected_peers.size(), 1, "four reliable replays disconnect")
	_expect_equal(_rejections.size(), 4, "each reliable replay counts as a violation")
	_inject(2, 2, 0, RELIABLE)
	_expect_equal(_hits.size(), 1, "reliable threshold quarantines queued traffic")
	await _finish(tree)


func _test_rate_limit(tree: SceneTree, delivery: int) -> void:
	_start(tree, 0.001, 1)
	_inject(2, 1, 0, delivery)
	for sequence: int in [2, 3, 4, 5]:
		_inject(2, sequence, 0, delivery)
	_expect_equal(_hits.size(), 1, "rate exhaustion blocks dispatch")
	_expect_equal(_rejections, [RedotP2PStatusCodes.MESSAGE_RATE_LIMITED, RedotP2PStatusCodes.MESSAGE_RATE_LIMITED, RedotP2PStatusCodes.MESSAGE_RATE_LIMITED, RedotP2PStatusCodes.MESSAGE_RATE_LIMITED], "rate exhaustion emits status for each frame")
	_expect_true(_transport.disconnected_peers.is_empty(), "four throttled frames do not disconnect")
	_expect_true(_network._violations.is_empty(), "throttling does not accumulate protocol violations")
	_inject(2, 2, 0, delivery)
	_expect_equal(_hits.size(), 1, "throttled sequence cannot dispatch again")
	_expect_equal(_rejections.size(), 5 if delivery == RELIABLE else 4, "throttled sequence is consumed before rate check")
	if delivery == RELIABLE:
		_expect_equal(_rejections[-1], RedotP2PStatusCodes.MESSAGE_REPLAYED, "throttled reliable sequence cannot be reused")
	await _finish(tree)
