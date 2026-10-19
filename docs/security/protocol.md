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

Sequences are scoped to one sender, logical channel, and delivery mode. Senders
maintain independent counters for each (channel, delivery) pair; receivers keep
independent state for each (peer, channel, delivery) tuple. Reliable and
ordered-unreliable sequences must increase strictly. Gaps are allowed.

Unordered unreliable delivery uses a 64-entry sliding replay bitmap. Unseen
frames up to 63 sequence values behind the highest observed value are accepted;
duplicates and older frames are dropped. A forward jump of 64 or more resets
the bitmap. Rejected unordered and ordered-unreliable sequences drop silently
without a protocol violation. Reliable replays remain protocol violations and
count toward the configured disconnect threshold.

Rate-limited frames emit `MESSAGE_RATE_LIMITED` without a protocol violation.
Their sequence is consumed before the rate check, so a throttled frame cannot
be reused. Other validation failures retain their protocol violation policy.

A sender must reconnect before any unsigned 32-bit counter is exhausted. This
is replay/reordering containment within a live session, not cryptographic
replay protection across authenticated sessions. The version-1 wire format is
unchanged, but both endpoints need these delivery-scoped sequence semantics
when mixing delivery modes on a logical channel.

The frame provides framing and validation, not encryption, authentication, or
integrity against an active network attacker. Those properties must come from
the transport/deployment and an admission identity layer.
