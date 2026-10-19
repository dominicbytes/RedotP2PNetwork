extends RedotP2PTestSuite

const CONNECTION_SCRIPT: Script = preload("res://tests/support/webrtc_connection_double.gd")


class SignalingDouble extends RedotP2PWebRTCSignalingProvider:
	var local_id: int = 1
	var rejected: Array[int] = []


	func is_available() -> bool:
		return true


	func start_authority(_endpoint: String, _port: int, _max_peers: int) -> Error:
		local_id = 1
		return OK


	func start_client(_endpoint: String, _port: int) -> Error:
		local_id = 2
		return OK


	func get_local_peer_id() -> int:
		return local_id


	func disconnect_peer(peer_id: int, _reason_code: String) -> Error:
		rejected.append(peer_id)
		return OK


class FactoryDouble extends RedotP2PWebRTCPeerFactory:
	func is_available() -> bool:
		return true


	func create_peer(_configuration: Dictionary) -> WebRTCPeerConnection:
		return CONNECTION_SCRIPT.new()


func run(_tree: SceneTree) -> void:
	_test_signaling_lifecycle()
	_test_capacity()
	for channel_count: int in [1, 8, RedotP2PProtocolLimits.HARD_MAX_CHANNELS]:
		_test_channels(false, channel_count)
		_test_channels(true, channel_count)


func _adapter(signaling: SignalingDouble) -> RedotP2PWebRTCTransportAdapter:
	var adapter: RedotP2PWebRTCTransportAdapter = RedotP2PWebRTCTransportAdapter.new()
	_expect_equal(adapter.set_providers(signaling, RedotP2PIceServerProvider.new(), FactoryDouble.new()), OK, "WebRTC doubles attach")
	return adapter


func _expect_signal_count(signaling: SignalingDouble, count: int) -> void:
	for signal_name: StringName in [
		&"peer_negotiation_requested", &"session_description_received", &"ice_candidate_received",
		&"peer_left", &"signaling_error",
	]:
		_expect_equal(signaling.get_signal_connection_list(signal_name).size(), count, "%s has %d adapter connections" % [signal_name, count])


func _test_signaling_lifecycle() -> void:
	var old_signaling: SignalingDouble = SignalingDouble.new()
	var adapter: RedotP2PWebRTCTransportAdapter = _adapter(old_signaling)
	_expect_equal(adapter.host("fixture", 0, 1), OK, "WebRTC authority starts")
	_expect_signal_count(old_signaling, 1)
	adapter.stop()
	_expect_signal_count(old_signaling, 0)
	_expect_equal(adapter.host("fixture", 0, 1), OK, "WebRTC restarts with the same signaling provider")
	_expect_signal_count(old_signaling, 1)
	adapter.stop()
	var new_signaling: SignalingDouble = SignalingDouble.new()
	_expect_equal(adapter.set_providers(new_signaling, RedotP2PIceServerProvider.new(), FactoryDouble.new()), OK, "WebRTC switches signaling while stopped")
	_expect_equal(adapter.host("fixture", 0, 1), OK, "WebRTC starts with replacement signaling")
	old_signaling.signaling_error.emit(RedotP2PStatusCodes.CONNECTION_FAILED)
	_expect_equal(adapter.get_state(), RedotP2PTransportAdapter.State.LISTENING, "old signaling cannot stop the new session")
	adapter.stop()
	_expect_signal_count(new_signaling, 0)
	adapter.free()


func _test_capacity() -> void:
	var signaling: SignalingDouble = SignalingDouble.new()
	var adapter: RedotP2PWebRTCTransportAdapter = _adapter(signaling)
	_expect_equal(adapter.host("fixture", 0, 1), OK, "capacity-one authority starts")
	signaling.peer_negotiation_requested.emit(2, 1, false)
	var original: WebRTCPeerConnection = adapter._connections.get(2) as WebRTCPeerConnection
	_expect_true(original != null, "first peer occupies the slot")
	signaling.peer_negotiation_requested.emit(2, 1, false)
	_expect_equal(adapter._connections.get(2), original, "duplicate generation preserves the connection")
	signaling.peer_negotiation_requested.emit(2, 2, false)
	_expect_equal(signaling.rejected.size(), 0, "full authority permits an existing peer to renegotiate")
	_expect_equal(adapter._generations.get(2), 2, "new generation replaces the existing connection")
	signaling.peer_negotiation_requested.emit(2, 1, false)
	_expect_equal(adapter._generations.get(2), 2, "stale generation cannot replace the connection")
	signaling.peer_negotiation_requested.emit(3, 1, false)
	_expect_equal(signaling.rejected, [3], "only a new peer is rejected at capacity")
	_expect_equal(adapter._connections.size(), 1, "renegotiation retains one occupied slot")
	adapter.stop()
	adapter.free()


func _test_channels(client: bool, channel_count: int) -> void:
	var signaling: SignalingDouble = SignalingDouble.new()
	var adapter: RedotP2PWebRTCTransportAdapter = _adapter(signaling)
	var limits: RedotP2PProtocolLimits = RedotP2PProtocolLimits.new()
	limits.max_channels = channel_count
	_expect_equal(adapter.configure(limits), OK, "WebRTC channel limits configure")
	if client:
		_expect_equal(adapter.join("fixture", 0), OK, "WebRTC client starts")
	else:
		_expect_equal(adapter.host("fixture", 0, 1), OK, "WebRTC channel authority starts")
	var remote_id: int = 1 if client else 2
	signaling.peer_negotiation_requested.emit(remote_id, 1, false)
	var connection: WebRTCPeerConnection = adapter._connections.get(remote_id) as WebRTCPeerConnection
	if connection == null:
		_expect_true(false, "WebRTC channel connection exists")
		adapter.stop()
		adapter.free()
		return
	connection.set("state", WebRTCPeerConnection.STATE_CONNECTED)
	adapter._process(0.0)
	var channels: Array = connection.get("channels")
	var used_channel_ids: Dictionary = {}
	for logical_channel: int in limits.max_channels:
		for delivery: int in [0, 1, 2]:
			var frame: PackedByteArray = _channel_frame(logical_channel, delivery)
			_expect_equal(adapter.send_packet(remote_id, frame, logical_channel, delivery), OK, "channel %d delivery %d sends" % [logical_channel, delivery])
			var matching: Array[WebRTCDataChannel] = []
			for channel: WebRTCDataChannel in channels:
				if int(channel.get("packets_sent")) > 0:
					matching.append(channel)
			_expect_equal(matching.size(), 1, "one native data channel carries each frame")
			if matching.size() != 1:
				continue
			var native_channel: WebRTCDataChannel = matching[0]
			var options: Dictionary = native_channel.get("options")
			_expect_equal(bool(options.get("ordered", true)), delivery != 0, "native ordering matches delivery")
			_expect_equal(options.has("maxPacketLifetime"), delivery != 2, "native reliability matches delivery")
			_expect_true(not used_channel_ids.has(options["id"]), "each channel/delivery pair uses an independent native channel")
			used_channel_ids[options["id"]] = true
			native_channel.set("packets_sent", 0)
			native_channel.set("packets_available", 1)
			adapter._peer.poll()
			var observed_channel: int = adapter._from_native_channel(adapter._peer.get_packet_channel())
			var observed_delivery: int = adapter._from_native_delivery(adapter._peer.get_packet_mode())
			_expect_equal(observed_channel, logical_channel, "native receive metadata maps to logical channel")
			_expect_equal(observed_delivery, delivery, "native receive metadata retains delivery")
			_test_metadata_rejections(observed_channel, observed_delivery, limits.max_channels)
			adapter._peer.get_packet()
	_expect_equal(adapter.send_packet(remote_id, PackedByteArray([1]), -1, 2), ERR_INVALID_PARAMETER, "negative WebRTC channel rejected")
	_expect_equal(adapter.send_packet(remote_id, PackedByteArray([1]), limits.max_channels, 2), ERR_INVALID_PARAMETER, "WebRTC channel ceiling rejected")
	_expect_equal(adapter.send_packet(remote_id, PackedByteArray([1]), 0, 99), ERR_INVALID_PARAMETER, "invalid WebRTC delivery rejected")
	adapter.stop()
	adapter.free()


func _test_metadata_rejections(channel: int, delivery: int, channel_count: int) -> void:
	var service: RedotP2PNetworkService = RedotP2PNetworkService.new()
	var limits: RedotP2PProtocolLimits = RedotP2PProtocolLimits.new()
	limits.max_channels = channel_count
	_expect_equal(service.configure(limits), OK, "metadata limits configure")
	var rejected: Array[String] = []
	service.message_rejected.connect(
		func(_peer_id: int, reason: String) -> void: rejected.append(reason)
	)
	if channel_count > 1:
		var wrong_channel: int = (channel + 1) % channel_count
		service._on_packet_received(2, _channel_frame(wrong_channel, delivery), channel, delivery)
		_expect_equal(rejected, [RedotP2PStatusCodes.MESSAGE_CHANNEL_INVALID], "envelope cannot override native channel")
		rejected.clear()
	var wrong_delivery: int = (delivery + 1) % 3
	service._on_packet_received(2, _channel_frame(channel, wrong_delivery), channel, delivery)
	_expect_equal(rejected, [RedotP2PStatusCodes.MESSAGE_DELIVERY_INVALID], "envelope cannot override native delivery")
	service.free()


func _channel_frame(channel: int, delivery: int) -> PackedByteArray:
	var envelope: RedotP2PMessageEnvelope = RedotP2PMessageEnvelope.new()
	envelope.message_type = "fixture.channel"
	envelope.payload = PackedByteArray([1])
	envelope.sequence = 1
	envelope.channel = channel
	envelope.delivery = delivery
	var limits: RedotP2PProtocolLimits = RedotP2PProtocolLimits.new()
	limits.max_channels = RedotP2PProtocolLimits.HARD_MAX_CHANNELS
	return envelope.encode(limits)
