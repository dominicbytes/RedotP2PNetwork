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
