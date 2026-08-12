class_name NetPeer
extends RefCounted

enum ConnectionStatus {
	DISCONNECTED,
	CONNECTED,
	READY,
	LOADING,
	LOADED,
}

var status: int = ConnectionStatus.DISCONNECTED
var connected: bool = false:
	set(value):
		connected = value
		if connected and status < ConnectionStatus.CONNECTED:
			status = ConnectionStatus.CONNECTED
		elif not connected:
			status = ConnectionStatus.DISCONNECTED
var host: bool = false
var network_id: int = 0
var profile_name: String = ""
var color: Color = Color.DARK_CYAN
var meta: Dictionary = {}


func _init(peer_network_id: int, _data: PackedByteArray = PackedByteArray()) -> void:
	network_id = peer_network_id
	profile_name = "Peer %d" % peer_network_id


func get_profile_name() -> String:
	return profile_name


func get_color() -> Color:
	return color


func get_color_hex() -> String:
	return "#%02x%02x%02x" % [color.r8, color.g8, color.b8]
