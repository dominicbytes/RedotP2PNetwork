class_name P2PNode
extends Node

@export var entity_id: String = ""
@export var sync_priority: int = RedotP2PCompatibilityNetwork.SYNC_PRIORITY.LOW
@export var destroy_on_disconnect: bool = true

var _network: RedotP2PCompatibilityNetwork = null


func _ready() -> void:
	_network = get_node_or_null("/root/P2PNetwork") as RedotP2PCompatibilityNetwork
	if _network == null or entity_id.is_empty():
		return
	var definition: RedotP2PReplicatedEntityDefinition = RedotP2PReplicatedEntityDefinition.new()
	definition.entity_id = entity_id
	definition.collect_state = collect_replication_state
	definition.apply_state = apply_replication_state
	definition.validate_intent = validate_replication_intent
	definition.apply_intent = apply_replication_intent
	definition.despawn_handler = _on_network_despawn
	var register_error: Error = _network.replication.register_entity(definition)
	if register_error != OK and register_error != ERR_ALREADY_EXISTS:
		push_warning("RedotP2PNetwork could not register entity '%s': Error %d" % [entity_id, register_error])
	_network.periodic_sync.connect(_on_periodic_sync)
	_network.disconnect.connect(_on_network_disconnect)


func _exit_tree() -> void:
	if _network != null and _network.replication != null and not entity_id.is_empty():
		_network.replication.unregister_entity(entity_id)


func collect_replication_state() -> Dictionary:
	return {}


func apply_replication_state(_state: Dictionary) -> void:
	pass


func validate_replication_intent(_peer_id: int, _intent: Dictionary) -> bool:
	return false


func apply_replication_intent(_peer_id: int, _intent: Dictionary) -> void:
	pass


func submit_replication_intent(intent: Dictionary) -> Error:
	if _network == null or _network.replication == null:
		return ERR_UNCONFIGURED
	return _network.replication.submit_intent(entity_id, intent)


func publish_replication_state() -> Error:
	if _network == null or _network.replication == null:
		return ERR_UNCONFIGURED
	return _network.replication.publish_entity(entity_id)


func _on_periodic_sync(priority: int) -> void:
	if priority == sync_priority and _network != null and _network.is_server():
		publish_replication_state()


func _on_network_despawn() -> void:
	if is_inside_tree():
		queue_free()


func _on_network_disconnect() -> void:
	if destroy_on_disconnect and is_inside_tree():
		queue_free()
