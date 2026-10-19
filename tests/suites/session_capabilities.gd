extends RedotP2PTestSuite


func run(tree: SceneTree) -> void:
	var network: RedotP2PNetworkService = RedotP2PNetworkService.new()
	tree.root.add_child(network)
	var transport: RedotP2PFakeTransportAdapter = RedotP2PFakeTransportAdapter.new()
	_expect_equal(network.set_transport(transport), OK, "capability transport attaches")
	var access: RedotP2PCapabilityService = RedotP2PCapabilityService.new()
	tree.root.add_child(access)
	_expect_equal(access.attach(network), OK, "session capabilities attach")
	_expect_equal(access.attach(network), OK, "repeated attachment is safe")
	_expect_equal(network.host("*", 7777, 4), OK, "capability session starts")
	var disconnects: Array[int] = []
	network.peer_disconnected.connect(func(id: int, _reason: String) -> void: disconnects.append(id))
	transport.inject_peer_connected(2)
	_seed(access)
	network.stop()
	_expect_true(disconnects.is_empty(), "session stop needs no individual disconnect events")
	_assert_reset(access, "stopped session")
	_expect_equal(network.host("*", 7777, 4), OK, "capability session rehosts")
	transport.inject_peer_connected(2)
	_assert_reset(access, "recycled peer id")
	_seed(access)
	transport._set_state(RedotP2PTransportAdapter.State.FAILED, RedotP2PStatusCodes.TRANSPORT_FAILURE)
	_assert_reset(access, "failed session")
	network.stop()
	_seed(access)
	transport._set_state(RedotP2PTransportAdapter.State.STARTING, RedotP2PStatusCodes.OK)
	_assert_reset(access, "new session start")
	network.stop()
	_expect_equal(network.join("fixture", 7777), OK, "capability client joins")
	transport.inject_peer_connected(1)
	_expect_equal(network.get_local_peer_id(), 2, "client uses non-authority local id")
	_expect_equal(access.get_role(1), RedotP2PCapabilityService.ROLE_OWNER, "authority retains owner role on client")
	_expect_equal(access.get_role(2), RedotP2PCapabilityService.ROLE_PLAYER, "local client does not become owner")
	network.stop()
	access.queue_free()
	network.queue_free()
	await tree.process_frame


func _seed(access: RedotP2PCapabilityService) -> void:
	_expect_equal(access.assign_role(2, RedotP2PCapabilityService.ROLE_MODERATOR), OK, "moderator role assigns")
	_expect_equal(access.grant_capability(2, "fixture.use"), OK, "custom grant assigns")
	_expect_equal(access.grant_capability(1, "fixture.owner"), OK, "authority custom grant assigns")
	_expect_true(access.has_capability(2, "peer.kick"), "moderator capability is active before reset")
	_expect_true(access.has_capability(2, "fixture.use"), "custom capability is active before reset")


func _assert_reset(access: RedotP2PCapabilityService, label: String) -> void:
	_expect_equal(access.get_role(2), RedotP2PCapabilityService.ROLE_PLAYER, label + " clears elevated role")
	_expect_true(not access.has_capability(2, "peer.kick"), label + " clears moderator capability")
	_expect_true(not access.has_capability(2, "fixture.use"), label + " clears custom grant")
	_expect_true(access._custom_capabilities.is_empty(), label + " clears authority custom grants too")
	_expect_equal(access.get_role(1), RedotP2PCapabilityService.ROLE_OWNER, label + " restores authority owner role")
	_expect_true(access.has_capability(1, "peer.kick"), label + " preserves owner capabilities")
