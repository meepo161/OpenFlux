# Changelog

All notable changes to the OpenFlux core. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.3.2] / node-v1.2.2 - 2026-09-30 (meepo161/OpenFlux)

### Fixed

- A node set up by the wizard (.conf carriers) or with --transports served
  Session clients only: a client that speaks classic, such as the iOS app,
  was dropped on every carrier ("serves Session peers only") and never got
  through. Such an exit now also serves classic clients on any of its
  carriers, as a --transport=X exit does; --negotiate stays Session-only.
  The exit serves one client at a time, and a classic client is answered
  only while no Session client is active on the channel.

## [0.3.1] / node-v1.2.1 - 2026-09-29 (meepo161/OpenFlux)

### Fixed

- A full packet batch queue now waits for capacity instead of dropping data.
  A batch rejected by a temporarily full or disconnected carrier is retried
  in order until it is accepted or the tunnel stops.

### Added

- Tunnel diagnostics report queue waits, carrier send retries and TCP
  retransmissions every 30 seconds when any of those counters increases.

## [0.3.0] / node-v1.2.0 - 2026-09-29 (meepo161/OpenFlux)

The fork on p1neappleXpress/OpenFlux 0.2.0 (one protocol for every client,
links made and read by the core) with the node wizard's transport choice
and self-updating nodes (p1neappleXpress/OpenFlux#125) and the Accounts
core side (`mobile.OfferExitCookies`). The node core is `node-v1.2.0`.

## [0.2.0] / node-v1.1.0 - 2026-09-28 (meepo161/OpenFlux)

Releases of the meepo161 fork: the core with the node wizard's transport
choice and self-updating nodes (p1neappleXpress/OpenFlux#125), wired to
this fork.

### Changed

- `deploy/node-install.sh` installs the core from this fork's `node-v*`
  releases and its updater follows them (`RELEASE_REPO=meepo161/OpenFlux`).
- The node wizard (`--node-wizard` `connect`, `mobile.NodeConnect`) takes a
  `source`: `fork` (default) installs this fork's core, `official` the same
  script following p1neappleXpress/OpenFlux (`provision.PinnedFor`).


### Added

- The node wizard (`--node-wizard`, `mobile.Node*`) lets a new channel use
  any mix of a Yandex document, a Mail.ru public document and cups.online
  rooms besides direct (`provision.ChannelTransport`); the rooms are created
  by the app (`cupsonline.CreateRoomList`) so the node keeps them, and its
  link, across restarts. `provision.ShareLink` builds the link from the same
  priorities and encryption context `node-install.sh` writes to node.conf.
- `node-install.sh update` and the optional `openflux-node-update.timer`:
  the node moves itself to the newest `node-v*` release, verified against
  that release's `node-install.sh` and `SHA256SUMS`, and rolls back if a
  channel does not stay up. An app with an older pinned script no longer
  downgrades a server the updater has moved on.

## [0.2.0] - 2026-09-28

Every client now behaves alike: peers of different builds and modes find
each other instead of dropping every packet in silence. The node wizard
(desktop and Android) installs this core as `node-v1.1.0`.

### Added

- Classic compatibility inside the Session (`PROTOCOL_NEGOTIATION.md`):
  a classic setup with a key (`--transport=X`, the apps' classic profiles)
  runs a Session and speaks classic to an exit that does not answer the
  handshake, switching once it does; a classic-configured exit serves
  classic and Session clients. `--negotiate` stays strict; exits configured
  as a Session (wizard, `.conf`, `--transports`) serve Session clients only.
- Codec fallback: the classic codec decodes batch-v2 and legacy frames,
  sends what the peer sends, and the client tries the other framing when
  the peer is silent. `--codec` is a preference now, not a requirement.
- KDF context fallback: one rule for the context (`transport.KDFContexts`)
  and alternates for what other builds derive; a record that fails under
  the current keys is tried under them, the exit answers under the
  client's context, a silent client cycles through them.
- `mobile/ios`: the iOS C library (`build_ios.sh`) on package `mobile`,
  replacing the root `export_ios*.go`: the calls the iOS app makes, plus
  Session profiles (`OpenFluxShareDecode` returns one ready to start),
  mode and captcha calls. An app that links this core as a submodule gets
  the same Session, links and fallbacks as Android.
- `mobile`: `ShareSessionSpecs`, `SetInitialCookies`, `SetLowMemory`
  (Volga's new `SlimVolgaConfig` for the iOS extension), `ReadTimeout`,
  `ConnectionMode`.
- Links are read and made by the core only. `share.Read` / `share.Make`
  answer every entry point with the same JSON (`--parse-link`, new
  `--make-link`, `mobile.ReadShareLink` / `MakeShareLink`, the iOS
  `OpenFluxShareDecode` / `OpenFluxShareEncode`): the configuration and
  its context, the link, or an error `code` (and `param`) that the apps
  put in their own words. `share.Make` normalizes what apps spell
  differently (the default codec is left out, an encrypted link always
  names its context, by the one rule when not given), so one
  configuration gives one link on every client; the node wizard's link,
  desktop and Android, comes from one `share.NodeConfig`.
- Logs a user can act on without `-dd`: key or context mismatch, the peer
  running the other layering, codec and context fallbacks, a second client
  taking over the exit, carriers failing to start, documents dropping, and
  a diagnosis when the handshake does not complete.

### Fixed

- A classic cupsonline client given the rooms as `--url` derived another
  key than the exit that created them: nothing got through.
- boards sent engine.io pings from the client, which an EIO=4 server
  answers by closing the socket: the board dropped every 20 seconds.
- A Session client's cupsonline carrier was built as an exit: with no or
  dead rooms it created rooms of its own and waited in them.
- openflux:// links: base64 padding, the standard alphabet, whitespace and
  line breaks are accepted; secrets are counted in characters as Kotlin
  counts them, not bytes.
- Carrier names that differ between the two sides no longer break cookie
  exchange and exit checks (messages carry the document URL).
- yandex / mailru: a socket whose keepalive failed is closed so the
  reconnect runs; writes are bounded.
- `utils.Infof` reaches the apps' log screens.
- A Session stopped each carrier twice.

## [0.1.0] - 2026-09-27

First release from the current `main` line (encrypted-logging + the
maintainer's multi-transport work folded together) and the first cut by
`release.yml` instead of a manual build.

### Added

- `mobile/`: the Android/iOS gomobile bridge now lives in this repository
  (moved from `meepo161/openfluxfork`, full history and authorship
  preserved), so building the mobile clients needs only this checkout.
- `.github/workflows/release.yml`: a `v*` tag cross-compiles the CLI for
  Linux (amd64/arm/arm64), Windows (386/amd64/arm64) and macOS
  (amd64/arm64) and publishes it with `SHA256SUMS.txt`. Replaces the
  ad-hoc manually-built `0.0.x` releases.
- `deploy/node-install.sh` now downloads the exit-node core from this
  repository's own `node-v*` releases instead of `meepo161/openfluxfork`;
  `provision/pin.go`'s pinned script commit/hash points here too.

### Fixed

- `main.go`: bench-send/bench-sink never resolved to the exit-side session
  role under `--negotiate`, so a negotiated session between two bench
  processes hung retrying the handshake and derived encryption keys in the
  same direction on both sides instead of swapped.
- `main.go`: the startup banner still printed the project's pre-rename
  name (`=== Universal Bypass Tool ===`) instead of `=== OpenFlux ===`.
- `.github/workflows/node-release.yml`: the pinned Go version (1.26.8) had
  drifted from `go.mod` (1.26.4), so its "reproducible" build didn't
  actually reproduce the hashes `deploy/node-install.sh` expects.

### Credits

`androidApp`/`desktopApp`/`shared` for [OpenFluxAndroid](https://github.com/p1neappleXpress/OpenFluxAndroid)
and [OpenFluxDesktop](https://github.com/p1neappleXpress/OpenFluxDesktop) now
run the Compose Multiplatform app built by [@meepo161](https://github.com/meepo161)
in [OpenFluxClient](https://github.com/meepo161/OpenFluxClient), moved into
those repositories with his agreement.

## [0.0.1] - [0.0.5]

Manually built and published cross-platform CLI binaries, before this
CHANGELOG and the automated release workflow existed.
