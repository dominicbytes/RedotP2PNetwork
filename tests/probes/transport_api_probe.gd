extends SceneTree


func _initialize() -> void:
	var class_names: Array[String] = [
		"WebSocketMultiplayerPeer",
		"WebSocketPeer",
		"WebRTCMultiplayerPeer",
		"WebRTCPeerConnection",
	]
	for class_name_value: String in class_names:
		print("CLASS %s exists=%s" % [class_name_value, str(ClassDB.class_exists(class_name_value))])
		if not ClassDB.class_exists(class_name_value):
			continue
		var instance: Object = ClassDB.instantiate(class_name_value)
		if instance == null:
			continue
		for method_data: Dictionary in instance.get_method_list():
			var method_name: String = str(method_data.get("name", ""))
			if method_name in [
				"create_client",
				"create_server",
				"initialize",
				"add_peer",
				"remove_peer",
				"create_data_channel",
				"poll",
				"set_outbound_buffer_size",
				"set_inbound_buffer_size",
				"set_max_queued_packets",
				"get_peer",
				"get_connected_host",
				"get_connected_port",
				"get_ready_state",
				"get_buffered_amount",
				"create_offer",
				"set_local_description",
				"set_remote_description",
				"add_ice_candidate",
				"get_connection_state",
			]:
				print("METHOD %s.%s %s" % [class_name_value, method_name, JSON.stringify(method_data)])
		for signal_data: Dictionary in instance.get_signal_list():
			var signal_name: String = str(signal_data.get("name", ""))
			if signal_name in ["session_description_created", "ice_candidate_created"]:
				print("SIGNAL %s.%s %s" % [class_name_value, signal_name, JSON.stringify(signal_data)])
	quit(0)
