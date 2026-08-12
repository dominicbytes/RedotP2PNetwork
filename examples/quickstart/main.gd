extends Control

var _network: RedotP2PCompatibilityNetwork = null
var _lobby: RedotP2PCompatibilityLobby = null
var _address_input: LineEdit = null
var _port_input: SpinBox = null
var _chat_input: LineEdit = null
var _status_output: RichTextLabel = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_network = get_node_or_null("/root/P2PNetwork") as RedotP2PCompatibilityNetwork
	_lobby = get_node_or_null("/root/P2PLobby") as RedotP2PCompatibilityLobby
	_build_interface()
	if _network == null or _lobby == null:
		_set_status(tr("The RedotP2PNetwork autoloads are unavailable."))
		return
	_network.transport_state_changed.connect(_on_transport_state_changed)
	_network.peer_connected.connect(func(peer_id: int) -> void: _append_status(tr("Peer connected: %d") % peer_id))
	_network.peer_disconnected.connect(
		func(peer_id: int, reason_code: String) -> void:
			_append_status(tr("Peer disconnected: %d (%s)") % [peer_id, reason_code])
	)
	_network.message_rejected.connect(
		func(peer_id: int, reason_code: String) -> void:
			_append_status(tr("Rejected message from %d: %s") % [peer_id, reason_code])
	)
	_lobby.lobby_joined.connect(func(lobby_id: int) -> void: _append_status(tr("Joined lobby %d") % lobby_id))
	_lobby.chat_message_received.connect(
		func(peer_id: int, message: String) -> void:
			_append_status(tr("Peer %d: %s") % [peer_id, message])
	)
	_set_status(tr("Idle. Host one copy, then join from another copy on the same computer."))


func _build_interface() -> void:
	var margin: MarginContainer = MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 32)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_right", 32)
	margin.add_theme_constant_override("margin_bottom", 24)
	add_child(margin)

	var layout: VBoxContainer = VBoxContainer.new()
	layout.add_theme_constant_override("separation", 12)
	margin.add_child(layout)

	var title: Label = Label.new()
	title.text = tr("RedotP2PNetwork Quickstart")
	title.add_theme_font_size_override("font_size", 28)
	layout.add_child(title)

	var explanation: Label = Label.new()
	explanation.text = tr("ENet is the reference transport. WebSocket below is explicit loopback-only development mode; production games must use WSS.")
	explanation.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(explanation)

	var connection_row: HBoxContainer = HBoxContainer.new()
	connection_row.add_theme_constant_override("separation", 8)
	layout.add_child(connection_row)
	_address_input = LineEdit.new()
	_address_input.text = "127.0.0.1"
	_address_input.placeholder_text = tr("Authority address")
	_address_input.tooltip_text = tr("Address of the listen host. Plain WebSocket accepts loopback only in this demo.")
	_address_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	connection_row.add_child(_address_input)
	_port_input = SpinBox.new()
	_port_input.min_value = 1
	_port_input.max_value = 65_535
	_port_input.value = 7777
	_port_input.tooltip_text = tr("Network port")
	connection_row.add_child(_port_input)

	var transport_row: HBoxContainer = HBoxContainer.new()
	transport_row.add_theme_constant_override("separation", 8)
	layout.add_child(transport_row)
	transport_row.add_child(_button(tr("Host ENet"), _host_enet))
	transport_row.add_child(_button(tr("Join ENet"), _join_enet))
	transport_row.add_child(_button(tr("Host WebSocket (loopback)"), _host_websocket))
	transport_row.add_child(_button(tr("Join WebSocket (loopback)"), _join_websocket))
	transport_row.add_child(_button(tr("Stop"), _stop_network))

	var chat_row: HBoxContainer = HBoxContainer.new()
	chat_row.add_theme_constant_override("separation", 8)
	layout.add_child(chat_row)
	_chat_input = LineEdit.new()
	_chat_input.placeholder_text = tr("Chat message (512 UTF-8 bytes maximum)")
	_chat_input.max_length = 512
	_chat_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_input.text_submitted.connect(func(_text: String) -> void: _send_chat())
	chat_row.add_child(_chat_input)
	chat_row.add_child(_button(tr("Send chat"), _send_chat))

	_status_output = RichTextLabel.new()
	_status_output.bbcode_enabled = false
	_status_output.fit_content = false
	_status_output.scroll_active = true
	_status_output.selection_enabled = true
	_status_output.custom_minimum_size = Vector2(0, 280)
	_status_output.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_status_output.tooltip_text = tr("Connection, validation, and chat status")
	layout.add_child(_status_output)


func _button(label: String, callback: Callable) -> Button:
	var button: Button = Button.new()
	button.text = label
	button.tooltip_text = label
	button.pressed.connect(callback)
	return button


func _host_enet() -> void:
	var start_error: Error = _network.host_enet(_selected_port(), 16, "127.0.0.1")
	_after_host(start_error)


func _join_enet() -> void:
	_report_start_result(_network.join_enet(_address_input.text.strip_edges(), _selected_port()))


func _host_websocket() -> void:
	var start_error: Error = _network.host_websocket(_selected_port(), 16, "127.0.0.1", null, true)
	_after_host(start_error)


func _join_websocket() -> void:
	_report_start_result(_network.join_websocket(_address_input.text.strip_edges(), _selected_port(), null, true))


func _after_host(start_error: Error) -> void:
	_report_start_result(start_error)
	if start_error != OK or _lobby.in_lobby():
		return
	var lobby: LobbyData = LobbyData.new(1, "Quickstart Pond", 0, 16, 1)
	if not _lobby.create_lobby(lobby):
		_append_status(tr("Lobby creation failed."))


func _stop_network() -> void:
	_network.stop("USER_REQUESTED_STOP")
	_set_status(tr("Network stopped."))


func _send_chat() -> void:
	var message: String = _chat_input.text
	if not _lobby.send_message(message):
		_append_status(tr("Chat was not sent. Join a lobby and use a valid bounded message."))
		return
	_chat_input.clear()


func _selected_port() -> int:
	return int(_port_input.value)


func _report_start_result(start_error: Error) -> void:
	if start_error == OK:
		_append_status(tr("Transport started."))
	else:
		_append_status(tr("Transport start failed with Error %d.") % start_error)


func _on_transport_state_changed(_previous_state: int, current_state: int, reason_code: String) -> void:
	_append_status(tr("Transport state %d (%s)") % [current_state, reason_code])


func _set_status(message: String) -> void:
	if _status_output != null:
		_status_output.text = message


func _append_status(message: String) -> void:
	if _status_output == null:
		return
	if not _status_output.text.is_empty():
		_status_output.append_text("\n")
	_status_output.append_text(message)
