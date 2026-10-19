extends RedotP2PTestSuite


func run(tree: SceneTree) -> void:
	await _test_connected_peers(tree)
	await _test_authority_and_reattachment(tree)
	_test_addresses_and_floors()


func _test_connected_peers(tree: SceneTree) -> void:
	var service: RedotP2PNetworkService = RedotP2PNetworkService.new()
	tree.root.add_child(service)
	var transport: RedotP2PFakeTransportAdapter = RedotP2PFakeTransportAdapter.new()
	_expect_equal(service.set_transport(transport), OK, "fixture transport attaches")
	_expect_equal(service.host("*", 7777, 8), OK, "fixture authority starts")
	var moderation: RedotP2PModerationService = RedotP2PModerationService.new()
	tree.root.add_child(moderation)
	_expect_equal(moderation.attach(service), OK, "fixture moderation attaches")
	var connected: Array[int] = []
	var denied: Array[int] = []
	service.peer_connected.connect(func(peer_id: int) -> void: connected.append(peer_id))
	moderation.peer_denied.connect(func(peer_id: int, _reason: String) -> void: denied.append(peer_id))
	transport.observed_addresses[2] = "203.0.113.9"
	transport.inject_peer_connected(2)
	_expect_equal(moderation.ban_exact_address("203.0.113.9", "fixture"), OK, "disabled ban records")
	_expect_equal(denied.size(), 0, "disabled enforcement preserves connected peer")
	moderation.set_enforcement_enabled(true)
	_expect_equal(denied, [2], "enabling enforcement immediately denies existing banned peer")
	_expect_equal(transport.disconnected_peers.size(), 1, "enable disconnects without another connect event")
	transport.observed_addresses[3] = "::ffff:203.0.113.10"
	transport.peer_identities[4] = "fixture:identity"
	transport.observed_addresses[5] = "::FFFF:C633:644D"
	transport.observed_addresses[6] = "192.0.2.6"
	for peer_id: int in [3, 4, 5, 6]:
		transport.inject_peer_connected(peer_id)
	_expect_equal(moderation.ban_exact_address("203.0.113.10", "fixture"), OK, "late exact ban records")
	_expect_true(denied.has(3), "late exact ban immediately denies mapped connected peer")
	_expect_equal(moderation.ban_identity("fixture:identity", "fixture"), OK, "late identity ban records")
	_expect_true(denied.has(4), "late identity ban immediately denies connected peer")
	_expect_equal(moderation.configure_cidr(true), OK, "range enforcement enables")
	_expect_equal(moderation.ban_cidr("198.51.100.0/24", "fixture", 0), OK, "late range ban records")
	_expect_true(denied.has(5), "late range ban immediately denies mapped connected peer")
	_expect_true(not denied.has(6), "unmatched connected peer remains allowed")
	_expect_equal(connected, [2, 3, 4, 5, 6], "rechecks do not emit connection events")
	_expect_equal(moderation.attach(service), OK, "reattachment is idempotent")
	moderation.set_enforcement_enabled(false)
	moderation.set_enforcement_enabled(true)
	_expect_equal(denied.size(), 4, "rechecks do not deny disconnected peers again")
	for record: Dictionary in transport.disconnected_peers:
		_expect_equal(record.get("reason_code"), RedotP2PStatusCodes.PEER_BANNED, "stable denial reason")
	transport.peer_disconnected.emit(6, RedotP2PStatusCodes.CONNECTION_CLOSED)
	_expect_equal(moderation.ban_exact_address("192.0.2.6", "fixture"), OK, "departed peer ban records")
	_expect_true(not denied.has(6), "departed peer is not disconnected again")
	transport.inject_peer_connected(6)
	_expect_true(denied.has(6), "reconnected banned peer is tracked and denied")
	_expect_true(moderation.unban_exact_address("192.0.2.6"), "tracking fixture unbans")
	transport.inject_peer_connected(6)
	var before_stop: int = denied.size()
	service.stop()
	_expect_equal(service.host("*", 7777, 8), OK, "authority restarts")
	_expect_equal(moderation.ban_exact_address("192.0.2.6", "fixture"), OK, "stopped-session ban records")
	_expect_equal(denied.size(), before_stop, "STOPPED clears tracked peers")
	_expect_true(moderation.unban_exact_address("192.0.2.6"), "failure fixture unbans")
	transport.inject_peer_connected(6)
	transport._set_state(RedotP2PTransportAdapter.State.FAILED, RedotP2PStatusCodes.CONNECTION_CLOSED)
	var before_failure: int = denied.size()
	_expect_equal(moderation.ban_exact_address("192.0.2.6", "fixture"), OK, "failed-session ban records")
	_expect_equal(denied.size(), before_failure, "FAILED clears tracked peers")
	service.stop()
	moderation.queue_free()
	service.queue_free()
	await tree.process_frame


func _test_authority_and_reattachment(tree: SceneTree) -> void:
	var service: RedotP2PNetworkService = RedotP2PNetworkService.new()
	tree.root.add_child(service)
	var transport: RedotP2PFakeTransportAdapter = RedotP2PFakeTransportAdapter.new()
	_expect_equal(service.set_transport(transport), OK, "client fixture transport attaches")
	_expect_equal(service.join("fixture", 7777), OK, "client fixture starts")
	var moderation: RedotP2PModerationService = RedotP2PModerationService.new()
	tree.root.add_child(moderation)
	_expect_equal(moderation.attach(service), OK, "client moderation attaches")
	moderation.set_enforcement_enabled(true)
	transport.observed_addresses[3] = "203.0.113.9"
	transport.inject_peer_connected(3)
	_expect_equal(moderation.ban_exact_address("203.0.113.9", "fixture"), OK, "client stores a local ban")
	_expect_equal(transport.disconnected_peers.size(), 0, "non-authority does not enforce bans")
	transport.authority = true
	_expect_equal(moderation.attach(service), OK, "authority reattaches moderation")
	_expect_equal(transport.disconnected_peers.size(), 1, "reattachment rechecks tracked peers")
	service.stop()
	moderation.queue_free()
	service.queue_free()
	await tree.process_frame


func _test_addresses_and_floors() -> void:
	_expect_equal(RedotP2PIPAddress.normalize("[::ffff:203.0.113.9]"), "203.0.113.9", "mapped dotted address normalizes to IPv4")
	_expect_equal(RedotP2PIPAddress.normalize("::FFFF:C633:644D"), "198.51.100.77", "mapped hex address normalizes to IPv4")
	_expect_equal(RedotP2PIPAddress.to_bytes("::ffff:203.0.113.9"), PackedByteArray([203, 0, 113, 9]), "mapped bytes use IPv4 width")
	_expect_equal(RedotP2PIPAddress.normalize("::203.0.113.9"), "0000:0000:0000:0000:0000:0000:cb00:7109", "nonmapped IPv6 stays IPv6")
	_expect_equal(RedotP2PIPAddress.normalize("::ffff:300.0.113.9"), "", "malformed mapped input is rejected")
	var moderation: RedotP2PModerationService = RedotP2PModerationService.new()
	_expect_equal(moderation.ban_exact_address("::ffff:203.0.113.9", "fixture"), OK, "mapped exact ban records")
	_expect_equal(moderation.check_address("203.0.113.9"), RedotP2PStatusCodes.PEER_BANNED, "mapped ban denies plain IPv4")
	_expect_true(moderation.unban_exact_address("203.0.113.9"), "plain IPv4 removes mapped ban")
	_expect_equal(moderation.configure_cidr(true), OK, "mapped range enforcement enables")
	_expect_equal(moderation.ban_cidr("::ffff:198.51.100.0/120", "fixture", 0), OK, "mapped /120 translates to IPv4 /24")
	_expect_equal(moderation.check_address("198.51.100.77"), RedotP2PStatusCodes.PEER_BANNED, "mapped range denies IPv4")
	_expect_equal(moderation.check_address("::ffff:c633:644d"), RedotP2PStatusCodes.PEER_BANNED, "mapped range denies hex form")
	_expect_equal(moderation.check_address("198.51.101.77"), RedotP2PStatusCodes.OK, "mapped range excludes outsider")
	_expect_equal(moderation.ban_cidr("::ffff:198.51.0.0/112", "fixture", 0), ERR_UNAUTHORIZED, "mapped /112 needs IPv4 high-risk confirmation")
	_expect_equal(moderation.ban_cidr("::ffff:198.51.0.0/112", "fixture", 0, true), OK, "confirmed mapped /112 uses IPv4 floor")
	_expect_equal(moderation.ban_cidr("::ffff:192.0.2.1/128", "fixture", 0), OK, "mapped /128 translates to an IPv4 host")
	_expect_equal(moderation.check_address("192.0.2.1"), RedotP2PStatusCodes.PEER_BANNED, "mapped host range matches IPv4")
	_expect_equal(moderation.check_address("192.0.2.2"), RedotP2PStatusCodes.OK, "mapped host range excludes adjacent IPv4")
	for prefix: int in [24, 95, 96, 104, 111, 129]:
		_expect_equal(moderation.ban_cidr("::ffff:0:0/%d" % prefix, "fixture", 0, true), ERR_INVALID_PARAMETER, "invalid or overly broad mapped prefix /%d is rejected" % prefix)
	_expect_equal(moderation.configure_cidr(true, 16, 48), OK, "loose configuration is clamped")
	for cidr: String in ["198.51.0.0/16", "2001:db8::/48"]:
		_expect_equal(moderation.ban_cidr(cidr, "fixture", 0), ERR_UNAUTHORIZED, "loose configuration cannot waive confirmation for %s" % cidr)
		_expect_equal(moderation.ban_cidr(cidr, "fixture", 0, true), OK, "confirmed absolute floor is accepted for %s" % cidr)
	for cidr: String in ["198.50.0.0/15", "2001:db8::/47"]:
		_expect_equal(moderation.ban_cidr(cidr, "fixture", 0, true), ERR_INVALID_PARAMETER, "absolute floor cannot be bypassed for %s" % cidr)
	_expect_equal(moderation.configure_cidr(true, 28, 80), OK, "stricter thresholds configure")
	for cidr: String in ["203.0.113.0/24", "2001:db8:1::/64"]:
		_expect_equal(moderation.ban_cidr(cidr, "fixture", 0), ERR_UNAUTHORIZED, "stricter threshold requires confirmation for %s" % cidr)
	moderation.free()
