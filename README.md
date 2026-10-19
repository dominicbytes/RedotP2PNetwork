# RedotP2PNetwork

RedotP2PNetwork is a security-first Redot adaptation of
[DawnGroveStudios/GodotP2PNetwork](https://github.com/DawnGroveStudios/GodotP2PNetwork).
It provides a transport-neutral multiplayer service, compatibility facades for
the original `P2PNetwork` and `P2PLobby` names, bounded lobby chat, replicated
state, explicit entity replication, capability checks, and optional IP or
identity bans.

This repository is an **alpha implementation for Redot 26.2 LTS and 26.3-stable**. It is suitable
for development and local integration testing, not a claim that every planned
transport or production deployment profile is certified.

## Current capability status

| Surface | Status | Evidence and limits |
|---|---|---|
| Secure protocol core | Implemented | Strict binary envelope, registered message allowlist, sender direction, receive-side channel/delivery rejection, replay rejection, per-peer rate limits, and violation disconnects are unit tested. ENet loopback tests exercise packet and byte work budgets; other adapters' work budgets are not directly qualified. |
| ENet | Implemented | Native two-process core and facade fixtures pass on Windows with Redot 26.2 and 26.3. |
| WebSocket | Implemented | Native two-process core and facade fixtures pass on Windows loopback with Redot 26.2 and 26.3. Plain `ws://` is loopback-only and opt-in; production requires TLS/WSS and deployment qualification. |
| Steam | Provider-gated alpha | Adapter and dynamic `dominicbytes/redot-steam` provider compile without making RedotSteam mandatory. A live private-App-ID authentication fixture is not yet certified. |
| WebRTC | Provider-gated alpha | Authority-star adapter and replaceable signaling, ICE, and peer-factory contracts are present. The installed Redot build has no usable default WebRTC backend, so a real provider fixture is still required. |
| Lobby discovery directory | Not implemented | Direct/current-lobby behavior works. Public discovery and the optional self-hostable directory remain later milestones. |
| Persistent moderation | Not implemented | In-memory exact address, identity, and guarded CIDR bans are implemented. Persistence and report storage require future provider contracts. |

See [transport status](docs/transports.md), the
[upstream compatibility matrix](docs/compatibility/upstream-api.md), and the
[threat model](docs/security/threat-model.md) before adopting the alpha.

## Install

1. Copy `addons/redot_p2p_network` into the target Redot project's `addons/`
   directory.
2. Enable **RedotP2PNetwork** in **Project Settings > Plugins**.
3. Confirm the plugin registered the `P2PNetwork` and `P2PLobby` autoloads. It
   will not overwrite autoloads that already use those names.

The development project in this repository opens a keyboard-operable
quickstart scene with ENet and explicit loopback WebSocket controls.

## Minimal ENet session

```gdscript
# Listen host.
var error: Error = P2PNetwork.host_enet(7777, 16, "*")

# Client.
var error: Error = P2PNetwork.join_enet("127.0.0.1", 7777)
```

## Register messages explicitly

Remote peers cannot select a NodePath, method, signal, property, or scene. A
game registers every accepted message and its limits locally:

```gdscript
func _ready() -> void:
	P2PNetwork.register_message(
		"game.chat",
		_on_chat,
		512, # payload bytes
		true, # accepted from clients by the authority
		false, # not accepted from the authority by clients
		1,
		RedotP2PTransportAdapter.Delivery.RELIABLE,
		2.0, # messages per second per peer
		4, # burst
		"chat.send"
	)


func _on_chat(peer_id: int, payload: PackedByteArray) -> void:
	# Decode and validate the game's own bounded payload here.
	pass
```

The authority assigns roles or scoped capabilities through
`P2PNetwork.access_control`. Client input still needs game-specific semantic
validation; this addon supplies the trust boundary, not game rules.

## Secure defaults

- Incoming message types are deny-by-default.
- Raw Variant/object deserialization is not used on network frames.
- Client messages cannot invoke arbitrary methods, signals, properties, or
  scene creation.
- The listen host or dedicated server is authoritative.
- Frames, payloads, channels, packets per tick, bytes per tick, chat, lobby
  state, entity state, and intent rates are bounded.
- Replayed or reordered sequence numbers are rejected per peer/channel.
- Plain WebSocket is rejected except for explicitly enabled loopback
  development.
- Moderation enforcement and CIDR banning are optional and off by default.
- Address bans use only the authority-observed transport address. Relay-hidden
  transports return no address rather than trusting a client claim.
- Exact address bans are the normal mode. CIDR requires explicit enablement;
  ranges broader than IPv4 `/24` or IPv6 `/64` require high-risk confirmation,
  and `/16` or `/48` are absolute limits.

JSON-backed compatibility state accepts only bounded JSON-safe values. Store
network IDs and revision-like integers as canonical decimal strings when exact
integer fidelity matters, because JSON numbers are decoded as floating-point
values by the engine.

## Upstream compatibility

The familiar classes and facade names remain where they can be made safe.
Legacy arbitrary `rpc_method`, remote signal emission, arbitrary node removal,
and free-form node synchronization are rejected while online with the stable
status `UNSAFE_LEGACY_API_REJECTED`. Use registered messages, `P2PNode`, or the
replication services instead. Wire compatibility with the upstream addon is not
provided.

## Development and tests

Set `REDOT_BIN` to a supported Redot 26.2 or 26.3 console executable, then run:

```powershell
./tools/run_tests.ps1 -RedotBin $env:REDOT_BIN
```

Build a reviewable addon archive without publishing it:

```powershell
./tools/package_addon.ps1
```

CI tests both pinned engines on Windows. The suite rejects engine diagnostics,
missing completion markers, nonzero exits, and timeouts. Only the known 26.3
headless editor shutdown defect has a temporary import-only exception; unit
tests, fixtures, and quickstart remain strict. See the
[supported engine versions](docs/compatibility/redot-versions.md) for evidence,
exception removal conditions, and optional provider limits.

Generated test artifacts and packages are ignored by Git. See
[CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).

## Fork provenance

- Upstream: `DawnGroveStudios/GodotP2PNetwork`
- Upstream baseline: `54256e434c4735f38bbfbaae7d01fb6a47bc0c8b`
- Intended downstream: `dominicbytes/RedotP2PNetwork`
- License: MIT; see [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md)

The repository retains upstream Git ancestry. The addon path and protocol were
changed intentionally for Redot and for safer defaults.

## About Dominic Bytes

Greetings! I am Dominic Bytes, the synth walker. I hail from the distant future. Where brains occupy robot bodies, time travel is a trip to the corner store, and the neon glow of our attire is powered by the light of our souls. Join me on a 1.21 gigawatt powered journey of chill vibes with gaming, anime, movies, and more!

- [Website](https://dominicbytes.carrd.co/)
- [X](https://x.com/DominicBytes)
- [Twitch](https://www.twitch.tv/dominicbytes)
- [YouTube](http://www.youtube.com/@DominicBytes)
- [Kick](https://kick.com/dominicbytes)
