# RedotP2PNetwork addon

Copy this `redot_p2p_network` directory into a Redot project's `addons/`
directory, then enable **RedotP2PNetwork** under Project Settings > Plugins.

The editor plugin registers the compatibility autoloads `P2PNetwork` and
`P2PLobby` only when those names are not already configured. Internally, the
autoloads delegate to scoped services and never expose arbitrary node paths,
method names, signals, scene paths, or Variant object decoding to remote peers.

Current development capability status is published in the repository README.
Unavailable transports fail with stable status codes and do not prevent ENet or
the shared core from loading.
