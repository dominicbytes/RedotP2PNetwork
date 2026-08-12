class_name RedotP2PNativeWebRTCPeerFactory
extends RedotP2PWebRTCPeerFactory

var _availability_probed: bool = false
var _available: bool = false


func is_available() -> bool:
	if not _availability_probed:
		var peer: WebRTCPeerConnection = create_peer({})
		_available = peer != null
		_availability_probed = true
	return _available


func create_peer(configuration: Dictionary) -> WebRTCPeerConnection:
	if not ClassDB.class_exists("WebRTCPeerConnection"):
		return null
	var peer: WebRTCPeerConnection = WebRTCPeerConnection.new()
	if peer == null or peer.initialize(configuration) != OK:
		return null
	return peer
