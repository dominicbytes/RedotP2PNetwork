# Transport status

All adapters implement `RedotP2PTransportAdapter` and feed the same validated
message service. A transport connection is not automatically an authenticated
player identity or a grant of gameplay authority.

| Transport | Native support | Security posture | Alpha evidence |
|---|---|---|---|
| ENet | Desktop native | Exposes the authority-observed remote address. ENet does not provide application authentication or confidentiality here; add an admission/identity layer before exposing an Internet service. | Windows two-process core and compatibility-facade fixtures on Redot 26.2. |
| WebSocket | Native and web-capable API | Reliable only. Production defaults to WSS/TLS. Plain WS requires explicit loopback development mode and rejects non-loopback hosts. Reverse-proxy trust remains the game's deployment responsibility. | Windows loopback two-process core and facade fixtures. WSS deployment is not yet certified. |
| Steam | Desktop provider | Dynamically borrows an already initialized, matching RedotSteam client context and never initializes or shuts down global Steam. No address is exposed. Transport identity is not yet a completed authenticated-admission profile. | Compiles and fails closed without a provider. Live private-App-ID and headless game-server fixtures remain open. |
| WebRTC | Native/web provider surface | Authority-star topology. SDP/ICE and negotiation generations are bounded. No public STUN/TURN service is bundled and ICE candidates never become IP-ban evidence. | Compiles and fails closed until signaling, ICE, and an available peer factory/backend are supplied. No real backend fixture is currently certified. |

## Adapter contract

Adapters report capabilities instead of making callers infer support. The
shared contract covers host/join, reliable or unreliable delivery, logical
channels, peer disconnect, local peer ID, authority role, observed address, and
provider identity. Unsupported capabilities return stable status/error results.

The addon manually polls its transport peer and does not replace the project's
`SceneTree.multiplayer` object. This keeps the addon composable with other Redot
systems and prevents remote scene-RPC behavior from bypassing its validator.

## WebSocket TLS

Supply `TLSOptions` before hosting or joining. The addon does not create,
persist, or ship certificates or private keys. Hostname validation and a
trusted certificate chain are required for production clients. There is no
automatic downgrade from WSS to WS.

## Steam provider

The built-in dynamic provider targets
[`dominicbytes/redot-steam`](https://github.com/dominicbytes/redot-steam). It
keeps the core addon loadable when that dependency is absent. The adapter can
own the single callback pump for its borrowed context or use an explicitly
external pump; multiple implicit callback owners are rejected.

The current provider is a client/listen-host integration surface. Pure
headless Steam GameServer support remains unavailable until RedotSteam exposes
and qualifies the separate game-server lifecycle and authentication API.

## WebRTC providers

Games must provide:

- a `RedotP2PWebRTCSignalingProvider` that assigns peer IDs and relays bounded
  SDP/ICE for one authority session;
- a `RedotP2PIceServerProvider` that returns developer-approved ICE servers;
- a `RedotP2PWebRTCPeerFactory` backed by an available WebRTC implementation.

Signaling and TURN are infrastructure, not gameplay authorities. A production
Internet profile needs a qualified TURN path and short-lived credentials.
