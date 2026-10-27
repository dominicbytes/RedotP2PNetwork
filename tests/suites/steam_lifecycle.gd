extends RedotP2PTestSuite

const LANE_SETTING: StringName = &"steam/multiplayer_peer/max_channels"


class PeerDouble extends MultiplayerPeerExtension:
	var sent_channels: Array[int] = []
	var channel: int = 0
	var closed: bool = false


	func _set_target_peer(_peer_id: int) -> void:
		pass


	func _set_transfer_channel(value: int) -> void:
		channel = value


	func _set_transfer_mode(_mode: MultiplayerPeer.TransferMode) -> void:
		pass


	func _put_packet_script(_buffer: PackedByteArray) -> Error:
		sent_channels.append(channel)
		return OK


	func _get_max_packet_size() -> int:
		return 65_536


	func _close() -> void:
		closed = true


class ReceiveDouble extends MultiplayerPeerExtension:
	var queue: Array[Dictionary] = []


	func _get_available_packet_count() -> int:
		return queue.size()


	func _get_packet_peer() -> int:
		return int(queue[0]["sender"])


	func _get_packet_channel() -> int:
		return 0


	func _get_packet_mode() -> MultiplayerPeer.TransferMode:
		return MultiplayerPeer.TRANSFER_MODE_RELIABLE


	func _get_packet_script() -> PackedByteArray:
		return queue.pop_front()["data"] as PackedByteArray


	func _get_max_packet_size() -> int:
		return 65_536


	func _close() -> void:
		pass


func run(tree: SceneTree) -> void:
	_test_free_outside_tree()
	_test_tree_exit(tree)
	await _test_queue_free(tree)
	_test_stop_idempotence()
	_test_channels()
	_test_unknown_sender()


func _seed_lease(adapter: RedotP2PSteamTransportAdapter, external: bool = false) -> RedotP2PRedotSteamProvider:
	var provider: RedotP2PRedotSteamProvider = RedotP2PRedotSteamProvider.new()
	_expect_equal(provider.configure(1, RedotP2PRedotSteamProvider.CallbackPumpMode.EXTERNAL if external else RedotP2PRedotSteamProvider.CallbackPumpMode.ADAPTER_OWNED), OK, "lease fixture provider configures")
	_expect_equal(adapter.set_provider(provider), OK, "lease fixture provider attaches")
	provider._lease_owner_id = adapter.get_instance_id()
	provider._last_completed_pump_msec = 1
	if not external:
		RedotP2PRedotSteamProvider._adapter_pump_owner_id = adapter.get_instance_id()
	adapter._state = RedotP2PTransportAdapter.State.CONNECTED
	return provider


func _expect_released(provider: RedotP2PRedotSteamProvider, label: String) -> void:
	_expect_equal(provider._lease_owner_id, 0, label + " clears the provider lease")
	_expect_equal(RedotP2PRedotSteamProvider._adapter_pump_owner_id, 0, label + " clears the process pump lease")
	_expect_equal(provider._last_completed_pump_msec, 0, label + " clears the pump timestamp")
	# Keep later cases independent when exercising the broken baseline.
	provider.release(provider._lease_owner_id)


func _test_free_outside_tree() -> void:
	for external: bool in [false, true]:
		var adapter: RedotP2PSteamTransportAdapter = RedotP2PSteamTransportAdapter.new()
		var provider: RedotP2PRedotSteamProvider = _seed_lease(adapter, external)
		adapter.free()
		_expect_released(provider, "free outside the tree")


func _test_tree_exit(tree: SceneTree) -> void:
	var adapter: RedotP2PSteamTransportAdapter = RedotP2PSteamTransportAdapter.new()
	tree.root.add_child(adapter)
	var provider: RedotP2PRedotSteamProvider = _seed_lease(adapter)
	var peer: PeerDouble = PeerDouble.new()
	adapter._peer = peer
	adapter._inside_transport_process = true
	tree.root.remove_child(adapter)
	_expect_released(provider, "tree exit during a transport callback")
	_expect_true(peer.closed, "tree exit closes the native peer")
	_expect_equal(adapter.get_state(), RedotP2PTransportAdapter.State.STOPPED, "tree exit stops synchronously")
	adapter.free()


func _test_queue_free(tree: SceneTree) -> void:
	var adapter: RedotP2PSteamTransportAdapter = RedotP2PSteamTransportAdapter.new()
	tree.root.add_child(adapter)
	var provider: RedotP2PRedotSteamProvider = _seed_lease(adapter)
	adapter.queue_free()
	await tree.process_frame
	_expect_released(provider, "queue_free")


func _test_stop_idempotence() -> void:
	var adapter: RedotP2PSteamTransportAdapter = RedotP2PSteamTransportAdapter.new()
	var provider: RedotP2PRedotSteamProvider = _seed_lease(adapter)
	adapter.stop()
	adapter.stop()
	_expect_released(provider, "repeated stop")
	adapter.free()
	_expect_released(provider, "free after stop")


func _test_channels() -> void:
	var had_setting: bool = ProjectSettings.has_setting(LANE_SETTING)
	var old_value: Variant = ProjectSettings.get_setting(LANE_SETTING) if had_setting else null
	ProjectSettings.set_setting(LANE_SETTING, null)
	_check_channels(4, 8, "default Steam lanes")
	for lane_count: int in [1, 2, 8, 0, -1]:
		ProjectSettings.set_setting(LANE_SETTING, lane_count)
		_check_channels(maxi(lane_count, 0), 8, "configured Steam lanes")
	ProjectSettings.set_setting(LANE_SETTING, 8)
	_check_channels(8, 2, "protocol channel limit")
	ProjectSettings.set_setting(LANE_SETTING, old_value if had_setting else null)


func _check_channels(lanes: int, protocol_channels: int, label: String) -> void:
	var adapter: RedotP2PSteamTransportAdapter = RedotP2PSteamTransportAdapter.new()
	var provider: RedotP2PRedotSteamProvider = RedotP2PRedotSteamProvider.new()
	_expect_equal(adapter.set_provider(provider), OK, label + " provider attaches without Steam")
	_expect_true(not adapter.get_capabilities().available, label + " does not claim live Steam availability")
	var limits: RedotP2PProtocolLimits = RedotP2PProtocolLimits.new()
	limits.max_channels = protocol_channels
	_expect_equal(adapter.configure(limits), OK, label + " protocol limit configures")
	var peer: PeerDouble = PeerDouble.new()
	adapter._peer = peer
	adapter._state = RedotP2PTransportAdapter.State.CONNECTED
	for channel: int in range(-1, protocol_channels + 1):
		for delivery: int in [RedotP2PTransportAdapter.Delivery.UNRELIABLE, RedotP2PTransportAdapter.Delivery.RELIABLE]:
			var valid: bool = channel >= 0 and channel < mini(lanes, protocol_channels)
			var count_before: int = peer.sent_channels.size()
			_expect_equal(adapter.send_packet(2, PackedByteArray([1]), channel, delivery), OK if valid else ERR_INVALID_PARAMETER, "%s channel %d delivery %d" % [label, channel, delivery])
			_expect_equal(peer.sent_channels.size(), count_before + (1 if valid else 0), label + " invalid channel never reaches the native peer")
			if valid:
				_expect_equal(peer.sent_channels[-1], channel, label + " preserves the lane")
	_expect_equal(adapter.send_packet(2, PackedByteArray([1]), 0, RedotP2PTransportAdapter.Delivery.UNRELIABLE_ORDERED), ERR_UNAVAILABLE if lanes > 0 else ERR_INVALID_PARAMETER, label + " ordered unreliable remains unsupported")
	adapter.stop()
	adapter.free()


func _test_unknown_sender() -> void:
	var adapter: RedotP2PSteamTransportAdapter = RedotP2PSteamTransportAdapter.new()
	var provider: RedotP2PRedotSteamProvider = RedotP2PRedotSteamProvider.new()
	_expect_equal(adapter.set_provider(provider), OK, "unknown sender provider attaches")
	_expect_equal(adapter.configure(RedotP2PProtocolLimits.new()), OK, "unknown sender limits configure")
	var peer: ReceiveDouble = ReceiveDouble.new()
	adapter._peer = peer
	adapter._state = RedotP2PTransportAdapter.State.CONNECTED
	adapter._connected_peers[2] = true
	peer.queue = [
		{"sender": -1, "data": PackedByteArray([1])},
		{"sender": 7, "data": PackedByteArray([2])},
		{"sender": 2, "data": PackedByteArray([3])},
	]
	var received: Array[int] = []
	var errors: Array[String] = []
	adapter.packet_received.connect(func(sender_id: int, _packet: PackedByteArray, _channel: int, _delivery: int) -> void: received.append(sender_id))
	adapter.transport_error.connect(func(code: String) -> void: errors.append(code))
	adapter._drain_packets()
	_expect_equal(received, [2] as Array[int], "only connected senders reach packet_received")
	_expect_equal(errors.count(RedotP2PStatusCodes.MESSAGE_UNAUTHORIZED), 2, "unknown senders are reported")
	_expect_equal(peer.queue.size(), 0, "unknown-sender packets are consumed, not left at the queue head")
	adapter.stop()
	adapter.free()
