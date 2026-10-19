extends WebRTCDataChannelExtension

var options: Dictionary = {}
var packets_sent: int = 0
var packets_available: int = 0


func _get_ready_state() -> int:
	return WebRTCDataChannel.STATE_OPEN


func _put_packet(_buffer: int, _size: int) -> Error:
	packets_sent += 1
	return OK


func _get_available_packet_count() -> int:
	return packets_available


# GDScript cannot populate PacketPeer's native output pointers. This double
# exposes availability for metadata inspection, then drains without payload.
func _get_packet(_buffer: int, _size: int) -> Error:
	packets_available = 0
	return ERR_UNAVAILABLE


func _get_max_packet_size() -> int:
	return 65_536


func _close() -> void:
	pass
