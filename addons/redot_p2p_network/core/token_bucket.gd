class_name RedotP2PTokenBucket
extends RefCounted

var _rate_per_second: float = 1.0
var _burst: float = 1.0
var _tokens: float = 1.0
var _last_msec: int = 0


func configure(rate_per_second: float, burst: int, now_msec: int = -1) -> Error:
	if rate_per_second <= 0.0 or burst < 1:
		return ERR_INVALID_PARAMETER
	_rate_per_second = rate_per_second
	_burst = float(burst)
	_tokens = _burst
	_last_msec = Time.get_ticks_msec() if now_msec < 0 else now_msec
	return OK


func allow(cost: float = 1.0, now_msec: int = -1) -> bool:
	if cost <= 0.0 or cost > _burst:
		return false
	var current_msec: int = Time.get_ticks_msec() if now_msec < 0 else now_msec
	if current_msec < _last_msec:
		_last_msec = current_msec
	var elapsed_seconds: float = float(current_msec - _last_msec) / 1000.0
	_tokens = minf(_burst, _tokens + elapsed_seconds * _rate_per_second)
	_last_msec = current_msec
	if _tokens < cost:
		return false
	_tokens -= cost
	return true


func available_tokens(now_msec: int = -1) -> float:
	var current_msec: int = Time.get_ticks_msec() if now_msec < 0 else now_msec
	var elapsed_seconds: float = maxf(0.0, float(current_msec - _last_msec) / 1000.0)
	return minf(_burst, _tokens + elapsed_seconds * _rate_per_second)
