# Transport status

All adapters implement `RedotP2PTransportAdapter` and feed the same validated
message service. A transport connection is not automatically an authenticated
player identity or a grant of gameplay authority.

| Transport | Native support | Security posture | Alpha evidence |
|---|---|---|---|
| ENet | Desktop native | Exposes the authority-observed remote address. ENet does not provide application authentication or confidentiality here; add an admission/identity layer before exposing an Internet service. | Windows two-process core and compatibility-facade fixtures on Redot 26.2 LTS and 26.3-stable. |
| WebSocket | Native and web-capable API | Reliable only. Production defaults to WSS/TLS. Plain WS requires explicit loopback development mode and rejects non-loopback hosts. Reverse-proxy trust remains the game's deployment responsibility. | Windows loopback two-process core and facade fixtures on Redot 26.2 LTS and 26.3-stable. WSS deployment is not yet certified. |
| Steam | Desktop provider | Dynamically borrows an already initialized, matching RedotSteam client context and never initializes or shuts down global Steam. No address is exposed. Transport identity is not yet a completed authenticated-admission profile. | Compiles on both supported engines and fails closed without a provider; the optional RedotSteam binary is not yet qualified on 26.3. Live private-App-ID and headless game-server fixtures remain open. |
| WebRTC | Native/web provider surface | Authority-star topology. SDP/ICE and negotiation generations are bounded. No public STUN/TURN service is bundled and ICE candidates never become IP-ban evidence. | Compiles on both supported engines and fails closed until signaling, ICE, and an available peer factory/backend are supplied. No real backend fixture is currently certified. |

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

### Steam lifecycle and lanes

Stopping, removing the adapter from the scene tree, or freeing it releases
its callback-pump lease. Cleanup is synchronous on tree exit and destruction,
including during a transport callback. It closes the transport peer
without shutting down the global Steam context.

Steam lanes are configured by `steam/multiplayer_peer/max_channels` (default
4). The provider's `get_max_channels()` reads this setting, including feature
overrides, without requiring a live Steam client. The adapter accepts channels
below both that lane count and the protocol's `max_channels` limit. Sending on
a negative or out-of-range channel returns `ERR_INVALID_PARAMETER` before
calling the native peer; an invalid nonpositive lane count allows no sends.
The default supports channels 0 through 3 used by the built-in services.
Configure lanes before starting a Steam session.

The capability model reports channel support as a boolean and has no numeric
channel-count field. Live Steam lane delivery, callback pumping, and client
reinitialization still require a matching RedotSteam context and Steam client.

## WebRTC providers

Games must provide:

- a `RedotP2PWebRTCSignalingProvider` that assigns peer IDs and relays bounded
  SDP/ICE for one authority session;
- a `RedotP2PIceServerProvider` that returns developer-approved ICE servers;
- a `RedotP2PWebRTCPeerFactory` backed by an available WebRTC implementation.

Signaling and TURN are infrastructure, not gameplay authorities. A production
Internet profile needs a qualified TURN path and short-lived credentials.

### WebRTC channel mapping

Each logical channel has separate reliable, ordered-unreliable, and unordered
unreliable native data channels. Logical channel 0 uses the engine's three
default channels; each additional logical channel configures three extra
channels through `create_server(channels_config)` or
`create_client(peer_id, channels_config)`. Both endpoints must use the same
`max_channels` limit.

A configured native channel has one fixed delivery mode: changing the native
transfer mode does not change that channel's reliability or ordering. The
adapter therefore maps each logical channel/delivery pair to its own native
channel and maps native receive metadata back to the logical channel. This
keeps independent ordering between logical channels and preserves the message
service's envelope channel/delivery cross-check. It avoids trusting envelope
metadata to choose the observed delivery mode.

Stopping disconnects the adapter's handlers from the externally owned
signaling provider before closing the session. Restarting may reuse that
provider or replace it without retaining callbacks from the previous session.

See [engine compatibility](compatibility/redot-versions.md) for the validation
scope and temporary 26.3 editor-import tolerance.
