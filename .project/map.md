# Project Map: pratico

## Overview

Pratico is a Docker Remote API daemon plus SwiftUI menubar app for Apple silicon Macs. It serves the Docker API (1.55, min 1.44) on `unix://~/.pratico/docker.sock` and runs each container in its own lightweight VM, so developers keep `docker` / `docker compose` without Docker Desktop. Two runtimes exist: the default, embedded runtime links apple/containerization and runs each VM in a `pratico-shim` process; `PRATICO_RUNTIME=container` drives Apple's `container` CLI (`AppleContainer.swift`) until its removal.

## Stack

- Swift 6.2 (swift-tools-version 6.2), macOS 26, Apple silicon; SwiftPM via `Package.swift`
- Dependency: `apple/containerization` 0.54.0 (products Containerization, ContainerizationOCI, ContainerizationExtras)
- Runtime assets: Kata 3.28.0 kernel + `vminit:0.54.0`, fetched by `scripts/fetch-runtime-assets.sh`
- Build: `make build | assets | app | dmg | install | release`
- Test: `make test` (Swift Testing), `make e2e`, `make e2e-embedded`, `make e2e-registry`, `make probe`

## Repo map

| Path | Holds |
|------|-------|
| `Sources/PraticoDaemonKit/` | Daemon library: `Daemon.swift` (routing), `HTTP.swift` (Unix-socket HTTP server), `Containers.swift`, `Images.swift` + `ImageBackend.swift`, `Networks.swift`, `Exec.swift`, `Archive.swift`, `Logs.swift`, `Events.swift`, `Health.swift`, `Stats.swift`, `Scan.swift`, `Registry.swift`, `AppleContainer.swift` (CLI adapter), `Embedded.swift` + `Shim.swift` (embedded runtime) |
| `Sources/pratico-daemon/` | Daemon executable (`main.swift`, `--home`) |
| `Sources/pratico-shim/` | Per-container VM owner for the embedded runtime |
| `Sources/pratico-runtime-probe/` | Dev-only: boots one VM (`make probe`) |
| `Sources/pratico-menubar/` | SwiftUI menubar app (`PraticoMenubarApp.swift`, `DaemonController.swift`) |
| `Sources/PraticoCore/` | Config (`config.toml`), paths, version, daemon probe |
| `Tests/` | Unit tests for PraticoCore and PraticoDaemonKit |
| `e2e/` | `run.sh`, `embedded.sh`, `registry.sh`, `pty.py`, `fakes/` (scanners, KEV) |
| `scripts/` | `fetch-runtime-assets.sh`, `release.sh` |
| `Support/` | Info.plist, entitlements, launch agent plist, DMG readme |
| `docs/design/` | `runtime.md`, `image-scanning.md` |
| `README.md`, `START.md` | Overview and build/test; user quick start |
| `SPEC.md` | Requirements, acceptance criteria, decisions D-1–D-28 (`SPEC.v0.md` superseded) |
| `ROADMAP.md` | Version-level plan; task checklist in `.project/roadmap.md` |
| `DS-HANDOFF.md` | Historical design handoff (2026-11-07) |
