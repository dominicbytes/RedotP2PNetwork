# Upstream API compatibility

The compatibility goal is source-level familiarity where the behavior can be
implemented safely. The new protocol is intentionally not wire-compatible with
GodotP2PNetwork.

| Upstream surface | RedotP2PNetwork status | Migration note |
|---|---|---|
| `P2PNetwork` autoload and common connection signals | Compatible facade | Added secure transport, message, status, and capability surfaces. |
| `P2PLobby`, `LobbyData`, `NetPeer`, `NetworkData` | Compatible core names | Authority owns lobby snapshots and roster. Discovery currently returns only the current/direct lobby. Existing upstream spelling fields such as `max_memebers` and `visablity` remain for source compatibility. |
| `P2PGlobalData` / `globalData` | Safe replacement | Bounded JSON-safe authority state and client requests for only the caller's player state. Exact IDs/revisions should be decimal strings. |
| `P2PNode` | Safe replacement | Register an explicit `entity_id` and override collect/apply/validate callbacks. Remote peers cannot choose properties or paths. |
| Arbitrary `rpc_method` | Rejected online | Register a bounded message and local handler. |
| Arbitrary `rpc_emit_signal` | Rejected online | Decode a registered message, validate it, then emit a local typed signal. |
| Arbitrary `rpc_remove_node` | Rejected online | Register a local entity and let the authority issue an explicit despawn. |
| Free-form `rpc_sync` and property whitelist | Replaced | Use `P2PNode`, `RedotP2PReplicationService`, or `RedotP2PReplicatedStateService`. |
| Remote scene/path cache and object creation | Removed | Scene construction remains local game logic after an authority-approved typed event. |
| Steam implementation | Replaced | Uses a narrow dynamic RedotSteam provider and fails closed when absent or unhealthy. |
| Upstream threading/logger/config UI helpers | Not ported | They are not required for the secure transport contract; games may use their own diagnostics and configuration UI. |
| Specialized `P2PNode2D`, `P2PCharacterBody2D`, `P2PRigidBody2D` | Not ported | Compose the general `P2PNode` behavior into game-specific nodes and validate intents on the authority. |

Unsafe compatibility calls set `P2PNetwork.last_status_code` to
`UNSAFE_LEGACY_API_REJECTED` and emit `network_error` while a session is active.
Offline local-only behavior remains for a narrow subset so existing setup code
does not needlessly break.
