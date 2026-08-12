class_name RedotP2PBanRecord
extends RefCounted

enum Kind {
	EXACT_ADDRESS,
	CIDR,
	IDENTITY,
}

var kind: int = Kind.EXACT_ADDRESS
var target: String = ""
var network: PackedByteArray = PackedByteArray()
var prefix_length: int = -1
var reason: String = ""
var expires_unix: int = 0


func is_expired(now_unix: int = -1) -> bool:
	var current_unix: int = int(Time.get_unix_time_from_system()) if now_unix < 0 else now_unix
	return expires_unix > 0 and current_unix >= expires_unix
