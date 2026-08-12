@tool
extends EditorPlugin

const P2P_NETWORK_PATH: String = "res://addons/redot_p2p_network/compat/p2p_network.gd"
const P2P_LOBBY_PATH: String = "res://addons/redot_p2p_network/compat/p2p_lobby.gd"

var _added_network_autoload: bool = false
var _added_lobby_autoload: bool = false


func _enter_tree() -> void:
	_added_network_autoload = _add_autoload_if_missing("P2PNetwork", P2P_NETWORK_PATH)
	_added_lobby_autoload = _add_autoload_if_missing("P2PLobby", P2P_LOBBY_PATH)


func _exit_tree() -> void:
	if _added_lobby_autoload:
		remove_autoload_singleton("P2PLobby")
	if _added_network_autoload:
		remove_autoload_singleton("P2PNetwork")
	_added_lobby_autoload = false
	_added_network_autoload = false


func _add_autoload_if_missing(autoload_name: String, script_path: String) -> bool:
	if ProjectSettings.has_setting("autoload/%s" % autoload_name):
		return false
	if not ResourceLoader.exists(script_path, "Script"):
		push_error("RedotP2PNetwork could not register %s: script is missing." % autoload_name)
		return false
	add_autoload_singleton(autoload_name, script_path)
	return true
