# Supported Redot engines

The alpha supports Redot 26.2 LTS (`26.2.stable.official.4f5b14aba`) and
Redot 26.3-stable (`26.3.stable.official.85e520394`). Windows CI downloads
checksum-pinned official builds and runs the same conformance suite on each.
This is local protocol and loopback transport qualification, not Internet
security or optional native-provider certification.

On both engines, validation covers editor import and addon class registration,
the unit/security suite, real ENet packet/byte work budgets, two-process ENet
and WebSocket core and compatibility-facade fixtures, a bounded quickstart run,
and addon packaging. WebSocket facade repetitions also check disconnect-time
broadcasts for closing-socket errors. No removed, renamed, or changed API used
by the addon was found in the 26.2-to-26.3 compatibility review.

## Temporary 26.3 editor-import tolerance

The official 26.3-stable Windows headless editor leaks Canvas, CanvasItem,
viewport, dummy texture, shaped text, font, and ObjectDB allocations during
shutdown, including in an empty project without this addon. Short editor runs
can also exit with access violation `-1073741819`. An engine fix has been
submitted. Remove the harness exception and its allowlist entries as soon as a
fixed engine build is pinned in CI.

`tests/known_engine_diagnostics.txt` contains tight, commented
`[26.3][editor-import]` regexes only for those known shutdown lines. They apply
only when the engine version starts with `26.3` and the harness is checking the
editor-import step. The known access-violation exit is accepted only there,
after a fresh script class cache lists every addon `class_name`. Stale cache
evidence is removed before import. Missing classes, timeouts, unrelated
errors/warnings, and other nonzero exits still fail.

The 26.2 effective tracked allowlist is empty. Unit tests, transport fixtures,
and the quickstart remain fully strict on both engines. Environment-specific
exceptions may be passed locally with `-ExtraAllowedDiagnosticsFile`; CI never
uses that option.

## Optional RedotSteam provider

The optional RedotSteam provider is not yet qualified on 26.3 because no
published binary is available. The GDExtension API version is identical, so
loading is expected but unverified. Without the extension, the provider fails
closed with `PROVIDER_UNAVAILABLE` / `ERR_UNAVAILABLE`. A live private-App-ID
authentication fixture and headless game-server integration also remain
unqualified. See [transport status](../transports.md).
