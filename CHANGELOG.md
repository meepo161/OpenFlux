# Changelog

All notable changes to the OpenFlux core. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
