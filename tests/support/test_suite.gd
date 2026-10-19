class_name RedotP2PTestSuite
extends RefCounted

var failures: Array[String] = []


func run(_tree: SceneTree) -> void:
	pass


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


func _frame(
	message_type: String, payload: PackedByteArray, sequence: int, channel: int,
	delivery: int = RedotP2PTransportAdapter.Delivery.RELIABLE
) -> PackedByteArray:
	var envelope: RedotP2PMessageEnvelope = RedotP2PMessageEnvelope.new()
	envelope.message_type = message_type
	envelope.payload = payload
	envelope.sequence = sequence
	envelope.channel = channel
	envelope.delivery = delivery
	return envelope.encode(RedotP2PProtocolLimits.new())


func _expect_true(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)


func _expect_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		failures.append("%s (expected %s, got %s)" % [label, str(expected), str(actual)])
