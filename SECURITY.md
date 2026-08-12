# Security policy

## Supported versions

Security fixes target the latest RedotP2PNetwork release. Backports are not
promised, but may be made when a critical issue affects a materially deployed
older release and a safe backport is practical.

The current `0.1.0-dev` tree is an alpha. ENet and loopback WebSocket have local
conformance evidence; Steam, WebRTC, production WSS, public lobby discovery,
and persistent moderation are not yet production-certified.

## Report a vulnerability

Please use GitHub's private vulnerability-reporting feature on the downstream
repository. Do not open a public issue with exploit details, credentials,
tokens, private App IDs, player addresses, or personal data.

Include the affected commit or release, Redot version, transport, platform, a
minimal reproduction, expected impact, and any proposed mitigation. Redact
secrets and real player data.

There is currently no response-time SLA, bug bounty, or disclosure timeline.
Maintainers will coordinate disclosure based on severity, exploitability,
affected releases, and the availability of a verified fix.

## Security boundary

Applications remain responsible for validating game semantics, protecting
operator and platform credentials, configuring TLS, securing dedicated hosts,
and deciding moderation/privacy policy. Never treat a display name, client-
supplied address, NodePath, method name, or unverified platform handle as an
authorization identity.
