extends WebRTCPeerConnectionExtension

const CHANNEL_SCRIPT: Script = preload("res://tests/support/webrtc_channel_double.gd")

var state: int = WebRTCPeerConnection.STATE_NEW
var channels: Array[WebRTCDataChannel] = []


func _get_connection_state() -> int:
	return state


func _create_data_channel(_label: String, options: Dictionary) -> WebRTCDataChannel:
	var channel: WebRTCDataChannel = CHANNEL_SCRIPT.new()
	channel.set("options", options.duplicate(true))
	channels.append(channel)
	return channel


func _poll() -> Error:
	return OK


func _create_offer() -> Error:
	return OK


func _close() -> void:
	state = WebRTCPeerConnection.STATE_CLOSED
