# Threat model

## Protected boundary

RedotP2PNetwork assumes remote peers, message payloads, timing, order, display
names, platform handles, and client address claims are hostile. The authority
owns gameplay state and decides which messages, roles, capabilities, player
intents, lobby changes, and moderation actions are allowed.

Before dispatch, the core verifies:

1. frame magic, protocol version, reserved flags, lengths, and limits;
2. locally registered message type;
3. transport channel and delivery consistency;
4. allowed sender direction and authority relationship;
5. an optional scoped capability;
6. strictly increasing peer/channel sequence;
7. a per-peer, per-message token bucket.

Repeated protocol violations disconnect the sender. Input work and retained
state have fixed configurable bounds.

## Explicitly prohibited remote authority

A peer cannot choose a local NodePath, method, signal, property, scene path,
resource, or object type. Network frames contain a bounded ASCII message type
and opaque bytes; they never use arbitrary Variant/object deserialization.
Entity replication registers local callbacks against explicit entity IDs.

## Moderation boundary

Moderation is optional and disabled by default. Address bans use only a direct
address observed by the authority transport. Missing or relay-hidden addresses
remain unavailable. Exact normalized addresses are the default; CIDR requires
explicit enablement and breadth controls. Steam IDs and other provider handles
are not authenticated identities merely because a transport reports them.

## Out of scope for the alpha

- Game-specific semantic validation. A syntactically valid movement or item
  intent may still be cheating; the game must validate it.
- Encryption or player authentication for ENet. Use trusted networking or add
  an admission provider before Internet deployment.
- Certified production WSS termination, proxy configuration, or denial-of-
  service capacity at the operating-system/network edge.
- Completed Steam ticket authentication and private-App-ID qualification.
- A bundled WebRTC backend, signaling deployment, STUN/TURN operation, or TURN
  credential issuer.
- Persistent bans, abuse reports, account linking, anti-cheat, or a global
  moderation database.
- Public lobby discovery and join authorization.
- Protection of a compromised authority process or malicious game code.

## Application responsibilities

Keep secrets outside project resources and logs; authenticate players before
granting sensitive capabilities; validate every game intent against current
authoritative state; rate-limit admission at the infrastructure boundary; use
TLS for WebSocket production; patch Redot and providers; and test exported
builds on every supported platform.
