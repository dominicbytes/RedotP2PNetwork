extends RedotP2PTestSuite


func run(tree: SceneTree) -> void:
	await _test_churn(tree, false)
	await _test_churn(tree, true)
	await _test_exact_entity_cleanup(tree, false)
	await _test_exact_entity_cleanup(tree, true)
	await _test_reused_id_budget(tree)
	await _test_received_despawn(tree)


func _fixture(tree: SceneTree) -> RedotP2PReplicationService:
	var network: RedotP2PNetworkService = RedotP2PNetworkService.new()
	tree.root.add_child(network)
	_expect_equal(network.set_transport(RedotP2PFakeTransportAdapter.new()), OK, "intent fixture transport attaches")
	var replication: RedotP2PReplicationService = RedotP2PReplicationService.new()
	network.add_child(replication)
	_expect_equal(replication.attach(network), OK, "intent fixture schemas register")
	_expect_equal(network.host("*", 7777, 8), OK, "intent fixture authority starts")
	return replication


func _entity(entity_id: String, applied: Array[String]) -> RedotP2PReplicatedEntityDefinition:
	var definition: RedotP2PReplicatedEntityDefinition = RedotP2PReplicatedEntityDefinition.new()
	definition.entity_id = entity_id
	definition.collect_state = func() -> Dictionary: return {"x": "0"}
	definition.apply_state = func(_state: Dictionary) -> void: pass
	definition.validate_intent = func(_peer_id: int, _intent: Dictionary) -> bool: return true
	definition.apply_intent = func(_peer_id: int, _intent: Dictionary) -> void: applied.append(entity_id)
	definition.intent_rate = 0.01
	definition.intent_burst = 1
	return definition


func _intent(replication: RedotP2PReplicationService, peer_id: int, entity_id: String) -> void:
	# Isolate entity budgets from the separate per-message transport budget.
	replication._on_intent(peer_id, JSON.stringify({"entity_id": entity_id, "intent": {}}).to_utf8_buffer())


func _test_churn(tree: SceneTree, despawn: bool) -> void:
	var replication: RedotP2PReplicationService = _fixture(tree)
	var applied: Array[String] = []
	for index: int in range(1100):
		var entity_id: String = "churn:%d" % index
		_expect_equal(replication.register_entity(_entity(entity_id, applied)), OK, "churn entity registers")
		_intent(replication, 2, entity_id)
		if despawn:
			_expect_equal(replication.despawn_entity(entity_id), OK, "churn entity despawns")
		else:
			_expect_true(replication.unregister_entity(entity_id), "churn entity unregisters")
	_expect_equal(applied.size(), 1100, "each churn entity accepts its first intent")
	_expect_equal(replication._entities.size(), 0, "churn leaves no active entities")
	_expect_equal(replication._intent_buckets.size(), 0, "churn releases every entity intent bucket")
	replication._network.stop()
	replication._network.queue_free()
	await tree.process_frame


func _test_exact_entity_cleanup(tree: SceneTree, despawn: bool) -> void:
	var replication: RedotP2PReplicationService = _fixture(tree)
	var applied: Array[String] = []
	var ids: Array[String] = ["unit", "player:unit", "unit:extra", ":unit", "other:player:unit"]
	for entity_id: String in ids:
		_expect_equal(replication.register_entity(_entity(entity_id, applied)), OK, "colon fixture entity registers")
		_intent(replication, 2, entity_id)
		_intent(replication, 3, entity_id)
	var retained: Variant = replication._intent_buckets.get("2:unit:extra")
	_expect_true(not replication.unregister_entity("missing"), "unknown unregister reports no entity")
	_expect_equal(replication.despawn_entity("missing"), ERR_UNAUTHORIZED, "unknown despawn is rejected")
	for entity_id: String in ["unit", "player:unit"]:
		if despawn:
			_expect_equal(replication.despawn_entity(entity_id), OK, "exact entity despawns")
		else:
			_expect_true(replication.unregister_entity(entity_id), "exact entity unregisters")
		for peer_id: int in [2, 3]:
			_expect_true(not replication._intent_buckets.has("%d:%s" % [peer_id, entity_id]),
				"removed entity releases every peer bucket")
	_expect_equal(replication._intent_buckets.size(), 6, "cleanup preserves unrelated colon-containing ids")
	_expect_true(replication._intent_buckets.get("2:unit:extra") == retained, "unrelated bucket retains its budget")
	_intent(replication, 2, "unit:extra")
	_expect_equal(applied.size(), 10, "unrelated exhausted budget is not reset by cleanup")
	for entity_id: String in ["unit:extra", ":unit", "other:player:unit"]:
		_expect_true(replication._intent_buckets.has("2:%s" % entity_id), "unrelated bucket survives exact matching")
	var transport: RedotP2PFakeTransportAdapter = replication._network.get_transport() as RedotP2PFakeTransportAdapter
	transport.disconnect_peer(2)
	_expect_equal(replication._intent_buckets.size(), 3, "peer disconnect still releases only that peer's buckets")
	replication._network.stop()
	replication._network.queue_free()
	await tree.process_frame


func _test_reused_id_budget(tree: SceneTree) -> void:
	var replication: RedotP2PReplicationService = _fixture(tree)
	var applied: Array[String] = []
	for index: int in range(4):
		var definition: RedotP2PReplicatedEntityDefinition = _entity("reused:unit", applied)
		_expect_equal(replication.register_entity(definition), OK, "reused id registers")
		_intent(replication, 2, definition.entity_id)
		_intent(replication, 2, definition.entity_id)
		_expect_equal(applied.size(), index + 1, "new entity gets a fresh budget that still rejects excess intents")
		if index % 2 == 0:
			replication.unregister_entity(definition.entity_id)
		else:
			replication.despawn_entity(definition.entity_id)
	_expect_equal(replication._intent_buckets.size(), 0, "reused id leaves no stale budget")
	replication._network.stop()
	replication._network.queue_free()
	await tree.process_frame


func _test_received_despawn(tree: SceneTree) -> void:
	var replication: RedotP2PReplicationService = _fixture(tree)
	var applied: Array[String] = []
	for entity_id: String in ["unit", "player:unit"]:
		replication.register_entity(_entity(entity_id, applied))
		_intent(replication, 2, entity_id)
	var transport: RedotP2PFakeTransportAdapter = replication._network.get_transport() as RedotP2PFakeTransportAdapter
	replication._network.stop()
	replication._network.join("fixture", 7777)
	var despawned: Array[String] = []
	replication.entity_despawned.connect(func(entity_id: String) -> void: despawned.append(entity_id))
	var channel: int = RedotP2PReplicationService.REPLICATION_CHANNEL
	var reliable: int = RedotP2PTransportAdapter.Delivery.RELIABLE
	transport.inject_packet(1, _frame(RedotP2PReplicationService.DESPAWN_MESSAGE,
		"unit".to_utf8_buffer(), 1, channel), channel, reliable)
	_expect_equal(despawned, ["unit"], "received authority despawn applies once")
	_expect_true(not replication._intent_buckets.has("2:unit"), "received despawn releases intent buckets")
	_expect_true(replication._intent_buckets.has("2:player:unit"), "received despawn preserves the full other entity id")
	replication._network.stop()
	replication._network.queue_free()
	await tree.process_frame
