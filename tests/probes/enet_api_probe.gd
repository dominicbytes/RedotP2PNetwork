extends SceneTree


func _initialize() -> void:
	var peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
	var required_methods: Array[String] = [
		"poll",
		"get_connection_status",
		"get_unique_id",
		"put_packet",
		"get_available_packet_count",
		"set_target_peer",
		"set_transfer_channel",
		"set_transfer_mode",
	]
	for method_name: String in required_methods:
		if not peer.has_method(method_name):
			push_error("Missing ENetMultiplayerPeer method: %s" % method_name)
			quit(1)
			return
	var signal_names: Array[String] = []
	for signal_data: Dictionary in peer.get_signal_list():
		signal_names.append(str(signal_data.get("name", "")))
	if not signal_names.has("peer_connected") or not signal_names.has("peer_disconnected"):
		push_error("ENetMultiplayerPeer is missing direct connection signals")
		quit(1)
		return
	print("ENET_API_PROBE_PASS")
	quit(0)
