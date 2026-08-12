class_name RedotP2PEnvelopeDecodeResult
extends RefCounted

var status_code: String = RedotP2PStatusCodes.INTERNAL_INVARIANT_FAILED
var envelope: RedotP2PMessageEnvelope = null


func is_ok() -> bool:
	return status_code == RedotP2PStatusCodes.OK and envelope != null
