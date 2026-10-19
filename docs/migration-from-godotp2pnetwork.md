# Migrating from GodotP2PNetwork

## 1. Change the addon path

Install `addons/redot_p2p_network` and enable `RedotP2PNetwork`. The plugin adds
`P2PNetwork` and `P2PLobby` autoloads only if those names are free. Remove the
old addon/autoload entries first; do not load both implementations together.

## 2. Choose a transport explicitly

Use `host_enet`/`join_enet`, `host_websocket`/`join_websocket`, or a configured
provider adapter. Check `P2PNetwork.get_transport_capabilities()` before
showing a platform-specific option. Do not assume Steam or WebRTC is present.

## 3. Replace arbitrary RPCs

For each old `rpc_method` or remote signal:

1. define one lowercase message type;
2. set a maximum payload size, sender direction, channel, delivery mode, rate,
   burst, and optional capability;
3. register one local handler;
4. parse only the expected payload schema;
5. validate game semantics on the authority before changing state.

Online arbitrary method/signal calls now fail closed by design.

## 4. Replace free-form node synchronization

Use a `P2PNode` with a stable explicit `entity_id`, or register a
`RedotP2PReplicatedEntityDefinition`. The authority collects state and validates
client intents. Clients apply authority state; they do not select local node
paths or property names. Scene spawning remains a local allowlisted game action.

## 5. Migrate global data

`P2PNetwork.globalData` remains available, backed by bounded authority-owned
replicated state. Values must be JSON-safe and fit the service limits. Use
canonical decimal strings for network IDs, large counters, and revisions that
must remain exact across JSON encoding.

## 6. Rebuild lobby discovery separately

Local/direct lobby creation, roster, and chat are present. Public lobby search
needs a platform provider or the future optional directory provider. Never
trust a client to author the canonical lobby roster or chat sender ID.

`P2PLobby.get_id()` is the local player's network ID (`0` without a local
peer); use `get_lobby_id()` to identify the lobby. The facade has one direct
session: leaving the lobby ends that session, including all client connections
when the host leaves. Network stop and authority loss clear the lobby before
departure callbacks.

`LobbyData` names are capped at **96 UTF-8 bytes**, truncating at a complete
character boundary during construction. A name modified afterward to exceed
that limit causes `create_lobby()` to return `false`. Only admitted roster
members may send lobby chat; transport connection alone is insufficient.

## 7. Add admission and deployment security

The addon validates protocol messages but does not magically authenticate ENet
players. Add an identity/admission layer before granting sensitive
capabilities. Use WSS with valid TLS for production WebSocket. Qualify the exact
Redot, addon, RedotSteam/WebRTC provider, and export artifacts you ship.

## 8. Test hostile cases

Run the included suite, then add game-level tests for unauthorized actions,
oversized payloads, reconnect, authority loss, late join, rate bursts, and
malformed game schemas. A successful connection is not proof that a peer is
authorized to perform gameplay actions.
