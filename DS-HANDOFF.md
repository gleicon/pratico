# Pratico Handoff Document

**Generated**: Sat Nov 07 2026
**Session**: Pratico specification and design grind

## Current Goal
Design and specification of "pratico", a Docker daemon + macOS menubar app that leverages Apple's container technology (https://github.com/apple/container) to provide a high-performance, native Docker daemon for macOS with integration Apple's `container` CLI.

## What Is Done

### Specification Files Created (in `/Users/gleicon/code/markdown/pratico/`)

1. **SPEC.md** (22KB) — Core specification covering:
   - Dual compatibility philosophy: Docker daemon + menubar app with Apple `container` CLI integration
   - Three-component architecture: `pratico-daemon` (Docker Remote API), `pratico-menubar` (SwiftUI menubar), `pratico-cli` (convenience wrappers, deprecated in favor of `docker` + `container` CLIs)
   - Docker Remote API daemon listening on `unix://~/.pratico/docker.sock`, implementing Docker API spec
   - Menubar app with unified mixed view (Docker+Apple breakdown), quick actions (start/stop/pause/snapshot/logs/alerts)
   - Configuration: `~/.pratico/config.toml` with sensible defaults + override-only pattern
   - Container lifecycle, image format, security model, performance optimizations
   - 5-phase roadmap from v0.1.0 MVP to v2.0 future vision

2. **ROADMAP.md** (7KB) — Versioned plan:
   - v0.1.0 (3 months): Docker daemon + menubar MVP with dual compatibility
   - v0.2.0 (3 months): API completeness + menubar enhancements
   - v1.0 (3 months): Stable release
   - v2.0 (6+ months): Beyond Docker platform

3. **START.md** (8KB) — Quick start guide:
   - Installation and startup commands
   - Using `docker` CLI via `DOCKER_HOST` environment variable
   - Using Apple's `container` CLI through menubar integration
   - Full development workflow example
   - Troubleshooting for both CLI and menubar

### Design Decisions Resolved (via ds-grill-me)

| Decision | Resolution |
|----------|-----------|
| **Menubar view type** | Unified mixed view: shows '2 Docker + 1 Apple' breakdown; click reveals both quick action sets |
| **Quick actions** | Daemon management: start/stop/pause, snapshot (metadata+config state restore), logs, alerts |
| **Config model** | Sensible defaults + override only in `~/.pratico/config.toml`; panel shows "override this value" |
| **Docker API scope** | Broad coverage: create/start/stop/rm, pull/inspect/push, network create/connect/list, volume create/inspect, stats, events, exec, logs, cp, tag/untag, remove, network/volume remove |
| **Snapshot metadata** | Stores metadata/config to emulate Docker; "all containers will be Apple containers, we are just storing metadata and config to emulate Docker" |
| **No separate pratico-cli** | Use `docker` CLI (via DOCKER_HOST) + Apple `container` CLI directly |
| **Menubar config panel** | Comprehensive but with "sensible defaults + override only" pattern |
| **v0.1.0 MVP scope** | Core + Apple integration: daemon+menubar start/stop, docker pull+run--rm alpine, container system status integration, menubar Docker+Apple breakdown, quick actions (start/stop/pause/snapshot/logs/alerts), config.toml overrides, broad Docker API |

### Key Artifacts
- `~/.pratico/config.toml` — TOML configuration file (not yet created on disk; spec defines format)
- `~/.pratico/docker.sock` — Unix socket for Docker Remote API (started by `pratico system start`)
- `~/.pratico/store/` — Local OCI image store (per spec)
- `~/.pratico/menubar/` — Menubar app SwiftUI state and preferences

## What Remains

### Implementation Phase (post-spec)
- **Swift daemon implementation** (`pratico-daemon`): Docker Remote API endpoints, Apple Virtualization framework integration, vmnet networking, Keychain auth, Time Machine exclusion
- **Swift menubar app** (`pratico-menubar`): SwiftUI StatusBar, mixed Docker+Apple view, quick actions menu, preferences panel (⌘,), `container` CLI status integration
- **Config file creation**: `~/.pratico/config.toml` with sensible defaults
- **Daemon start/stop**: `pratico system start` / `pratico system stop`
- **Test against Docker CLI**: Verify `docker version`, `docker pull`, `docker run` workflows
- **Test Apple CLI integration**: Verify `container system status` appears in menubar

### Post-MVP
- v0.2.0: API completeness, BuildKit integration, virtioFS volume mounts, environment variables, restart policies
- v1.0: Stable release, comprehensive documentation, migration guide, beta with real-world workflows

## Key Decisions Summary

1. **Docker daemon focus** — Leverages existing Docker CLI/tooling; immediate compatibility
2. **Menubar app** (SwiftUI) — Native macOS experience; unified Docker+Apple view
3. **Sensible defaults + override config** — Minimal config.toml entries; most from built-in defaults
4. **Broad Docker API v1** — Comprehensive endpoint coverage for v0.1.0
5. **Dual compatibility** — Docker CLI + Apple container CLI; menubar unifies both
6. **Metadata-driven snapshot** — Config + metadata to emulate Docker, not full binary state
7. **Apple silicon + macOS 13+** — Virtualization framework, SwiftUI StatusBar

## Open Questions / Deferred

- Snapshot metadata field definitions (deferred; "use whatever is needed")
- Exact config.toml section breakdown (deferred; "sensible defaults + override only")
- Menubar config panel granularity (deferred; hybrid approach selected)
- Apple container CLI exact integration points (depends on installed `container` version)
- Time Machine exclusion implementation details
- BuildKit internet access handling for image builds

## Suggested Next Commands (for continuing session)

```bash
# 1. Create the project directory and initialize
mkdir -p /Users/gleicon/code/markdown/pratico
# (files already exist from spec phase)

# 2. Start Swift implementation
# - Create Package.swift for pratico-daemon target
# - Create Package.swift for pratico-menubar target
# - Implement Docker Remote API core endpoints
# - Implement SwiftUI menubar status item

# 3. Test Docker CLI connection
export DOCKER_HOST="unix://${HOME}/.pratico/docker.sock"
docker version

# 4. Verify menubar integration
pratico system start
# Check menubar appears top-right; click shows Docker+Apple breakdown

# 5. Run acceptance test
docker pull alpine
docker run --rm alpine echo "hello from pratico!"

# 6. Check Apple container status
container system status
```