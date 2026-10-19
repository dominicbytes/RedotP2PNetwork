# Changelog

All notable changes will be documented here. The project follows semantic
versioning after its public alpha begins.

## [Unreleased]

### Added

- Redot 26.3-stable support alongside 26.2 LTS, with a pinned Windows CI matrix.

- Secure, bounded, versioned message envelope and transport-neutral service.
- ENet and WebSocket adapters with two-process conformance fixtures.
- Provider-gated Steam and WebRTC adapter surfaces.
- `P2PNetwork` and `P2PLobby` compatibility autoloads.
- Authority-owned lobby chat, replicated state, and explicit entity
  replication.
- Roles, scoped capabilities, optional exact-address and identity bans, and
  guarded CIDR bans.
- Quickstart project, test runner, package script, migration guide, security
  documentation, and fork provenance.

### Fixed

- WebSocket disconnect broadcasts no longer send through closing sockets.

### Changed

- Test harnesses reject unexpected engine diagnostics and missing completion
  markers, require usable exit codes, and bound engine processes.
- Isolated test suites cover receive metadata rejection and ENet work budgets.

- Replaced the upstream trust and synchronization model rather than preserving
  wire compatibility.
- Unsafe arbitrary remote method, signal, property, scene, and node operations
  fail closed while online.

### Fixed

- Scope sequence counters by logical channel and delivery mode, with a 64-frame
  replay window for unordered unreliable delivery, so reordering cannot discard
  reliable traffic or disconnect honest peers.
- Drop stale unreliable frames silently and report rate limits without counting
  them as protocol violations; throttled sequences remain consumed.

### Security

- Network frames never deserialize arbitrary Variants or objects.
- Direction, authority, channel, delivery, sequence, size, rate, and capability
  checks run before local message dispatch.
