class_name RedotP2PRedotSteamProvider
extends RefCounted

enum CallbackPumpMode {
	ADAPTER_OWNED,
	EXTERNAL,
}

const MAX_CALLBACK_GAP_MSEC: int = 1000

static var _adapter_pump_owner_id: int = 0

var _expected_app_id: int = 0
var _pump_mode: int = CallbackPumpMode.ADAPTER_OWNED
var _steam: Object = null
var _lease_owner_id: int = 0
var _last_completed_pump_msec: int = 0


func configure(expected_app_id: int, pump_mode: int = CallbackPumpMode.ADAPTER_OWNED) -> Error:
	if _lease_owner_id != 0:
		return ERR_ALREADY_IN_USE
	if expected_app_id <= 0 or pump_mode not in [CallbackPumpMode.ADAPTER_OWNED, CallbackPumpMode.EXTERNAL]:
		return ERR_INVALID_PARAMETER
	_expected_app_id = expected_app_id
	_pump_mode = pump_mode
	return OK


func get_availability_status() -> String:
	if _expected_app_id <= 0:
		return RedotP2PStatusCodes.INVALID_ARGUMENT
	if not ClassDB.class_exists("SteamMultiplayerPeer") or not Engine.has_singleton("Steam"):
		return RedotP2PStatusCodes.PROVIDER_UNAVAILABLE
	var steam: Object = Engine.get_singleton("Steam")
	if steam == null or not _has_required_methods(steam):
		return RedotP2PStatusCodes.PROVIDER_UNAVAILABLE
	if not bool(steam.call("isSteamRunning")) or not bool(steam.call("loggedOn")):
		return RedotP2PStatusCodes.PROVIDER_UNAVAILABLE
	if int(steam.call("getAppID")) != _expected_app_id:
		return RedotP2PStatusCodes.PROVIDER_CONTEXT_MISMATCH
	return RedotP2PStatusCodes.OK


func acquire(owner_id: int) -> Error:
	if owner_id <= 0 or _lease_owner_id != 0:
		return ERR_ALREADY_IN_USE
	var availability: String = get_availability_status()
	if availability != RedotP2PStatusCodes.OK:
		return ERR_UNAVAILABLE
	if _pump_mode == CallbackPumpMode.ADAPTER_OWNED and _adapter_pump_owner_id not in [0, owner_id]:
		return ERR_ALREADY_IN_USE
	_steam = Engine.get_singleton("Steam")
	_lease_owner_id = owner_id
	_last_completed_pump_msec = Time.get_ticks_msec()
	if _pump_mode == CallbackPumpMode.ADAPTER_OWNED:
		_adapter_pump_owner_id = owner_id
	return OK


func release(owner_id: int) -> void:
	if owner_id <= 0 or owner_id != _lease_owner_id:
		return
	if _pump_mode == CallbackPumpMode.ADAPTER_OWNED and _adapter_pump_owner_id == owner_id:
		_adapter_pump_owner_id = 0
	_lease_owner_id = 0
	_last_completed_pump_msec = 0
	_steam = null


func pump_callbacks(owner_id: int) -> Error:
	if owner_id != _lease_owner_id or _steam == null:
		return ERR_UNAUTHORIZED
	if _pump_mode == CallbackPumpMode.ADAPTER_OWNED:
		_steam.call("run_callbacks")
		_last_completed_pump_msec = Time.get_ticks_msec()
	return OK if is_pump_healthy(owner_id) else ERR_TIMEOUT


func notify_external_pump_completed(owner_id: int) -> Error:
	if _pump_mode != CallbackPumpMode.EXTERNAL or owner_id != _lease_owner_id:
		return ERR_UNAUTHORIZED
	_last_completed_pump_msec = Time.get_ticks_msec()
	return OK


func is_pump_healthy(owner_id: int) -> bool:
	if owner_id != _lease_owner_id or _last_completed_pump_msec <= 0:
		return false
	return Time.get_ticks_msec() - _last_completed_pump_msec <= MAX_CALLBACK_GAP_MSEC


func get_local_steam_id() -> int:
	if _steam == null:
		return 0
	return int(_steam.call("getSteamID"))


func get_expected_app_id() -> int:
	return _expected_app_id


func get_callback_pump_mode() -> int:
	return _pump_mode


func _has_required_methods(steam: Object) -> bool:
	for method_name: String in ["isSteamRunning", "loggedOn", "getAppID", "getSteamID", "run_callbacks"]:
		if not steam.has_method(method_name):
			return false
	return true
