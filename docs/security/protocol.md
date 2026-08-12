# Protocol version 1

The core frame is a fixed 18-byte header followed by a message-type byte string
and opaque payload. All integers are unsigned little-endian.

| Offset | Bytes | Field |
|---:|---:|---|
| 0 | 4 | ASCII magic `RP2P` |
| 4 | 1 | Protocol version (`1`) |
| 5 | 1 | Delivery value in bits 0-1; bits 2-7 must be zero |
| 6 | 2 | Logical channel |
| 8 | 4 | Sequence, greater than zero |
| 12 | 2 | Message-type byte length |
| 14 | 4 | Payload byte length |
| 18 | variable | Message type, then payload |

Message types are 1-64 bytes by default and contain only lowercase ASCII
letters, digits, `.`, `-`, or `_`. The default limits are 65,536 frame bytes,
60,000 payload bytes, eight channels, 64 packets per tick, 262,144 bytes per
tick, and four protocol violations before disconnect. Hard ceilings in
`RedotP2PProtocolLimits` prevent an application from configuring unbounded
values.

Delivery values match the adapter enum: unreliable (`0`), ordered-unreliable
(`1`), and reliable (`2`). A transport may support only a subset. WebSocket
uses native reliable delivery on channel zero but preserves and validates the
logical channel in this header.

Sequences are scoped to one sender and logical channel and must increase
strictly. Gaps are allowed; duplicates and older frames are rejected. A sender
must reconnect before the unsigned 32-bit sequence space is exhausted. This is
replay/reordering containment within a live session, not cryptographic replay
protection across authenticated sessions.

The frame provides framing and validation, not encryption, authentication, or
integrity against an active network attacker. Those properties must come from
the transport/deployment and an admission identity layer.
