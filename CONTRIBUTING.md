# Contributing

RedotP2PNetwork is security-sensitive infrastructure. Keep changes small,
typed, transport-neutral where possible, and covered by a failing-then-passing
test or fixture.

## Development baseline

- Redot 26.2 stable
- GDScript only for the core addon
- Windows is the currently exercised local fixture platform
- The distributable addon lives only under `addons/redot_p2p_network`

Set `REDOT_BIN` to the Redot console executable and run:

```powershell
./tools/run_tests.ps1 -RedotBin $env:REDOT_BIN
```

Before proposing a change:

1. Preserve the stable message/status contract or document a deliberate break.
2. Keep remote input bounded and deny-by-default.
3. Do not add arbitrary Variant/object decoding or peer-selected NodePaths,
   methods, signals, properties, resources, or scenes.
4. Add negative cases for malformed, unauthorized, replayed, and oversized
   input when the change touches a trust boundary.
5. Run the complete local suite and `git diff --check`.
6. Update the transport or compatibility matrix when support changes.

Do not commit credentials, Steam tickets, private App IDs, certificates,
private keys, player addresses, generated packages, or test logs.

## Test suites

Add a script under `tests/suites/` extending `RedotP2PTestSuite` and implement
`func run(tree: SceneTree) -> void` (it may await). The runner discovers `.gd`
files in sorted order; new suites require no shared-file edit. Reuse
`_expect_true`, `_expect_equal`, `_definition`, and `_frame` from the base.
Commit each new script's engine-generated `.gd.uid` alongside it.

The harness requires completion markers and rejects engine errors and warnings
in both output streams, even with exit code zero. Every engine run has frame
and wall-clock bounds; timeouts kill the process tree. The tracked
`tests/known_engine_diagnostics.txt` starts empty; each future regex needs an
explanatory comment and may use a version prefix such as `[26.3]`.
For local environment issues only, pass `-ExtraAllowedDiagnosticsFile` with an
untracked allowlist in the same format. Never use that option in CI.
