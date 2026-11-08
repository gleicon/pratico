# Project Map: pratico

## Overview

Pratico (formerly "cocker") is a planned Docker Remote API daemon plus SwiftUI menubar app for Apple silicon Macs. It serves the Docker API on `unix://~/.pratico/docker.sock` and runs each container as an Apple `container` VM. That lets developers keep the `docker` / `docker compose` toolchain without Docker Desktop's shared Linux VM. The repo currently holds specification documents only; no source code, manifests, or build files exist yet.

## Stack

Planned per `SPEC.md` § Technical Profile and § Constraints. None of this exists in the repo yet.

- Language: Swift 6.x, built on Apple's `Containerization` package
- Runtime: macOS 26+, Apple silicon only, Virtualization framework (no external hypervisor)
- Build: Swift Package Manager (`swift build --release`); Xcode for the menubar app bundle
- Test: Swift Testing for unit tests; end-to-end suite driving the real `docker` CLI against the socket
- Planned components: `pratico-daemon` (Docker Remote API), `pratico-menubar` (SwiftUI status item), `pratico` CLI (`system start|stop|status`)
- Config: `~/.pratico/config.toml`

## Repo map

| Path | Holds |
|------|-------|
| `SPEC.md` | Authoritative v0.1.0 spec: problem, scope, requirements, interfaces, constraints, acceptance criteria, closed decisions |
| `SPEC.v0.md` | Superseded long-form spec under old name "cocker"; `SPEC.md` wins on conflict |
| `ROADMAP.md` | Versioned plan: v0.1.0 MVP, v0.2.0, v1.0, v2.0 |
| `START.md` | User-facing quick start: install, start daemon, `DOCKER_HOST`, `container` CLI usage, troubleshooting |
| `DS-HANDOFF.md` | Session handoff from 2026-11-07 spec phase: done, remaining, decisions, next commands |
| `.project/` | Session tooling (`map.md`, `state.md`) |
