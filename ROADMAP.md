# Pratico Roadmap

Version-level plan. The task checklist being worked is
[`.project/roadmap.md`](.project/roadmap.md); requirements and acceptance criteria are in
[`SPEC.md`](SPEC.md).

## Version 0.1.0 — Docker Daemon + Menubar MVP
**Goal**: Docker Remote API daemon + macOS menubar app, one VM per container, nothing
else to install.

### Done (v0.1.0-alpha.1 and since)
- [x] **pratico-daemon** serving Docker API 1.55 (min 1.44) on `unix://~/.pratico/docker.sock`
- [x] **Container lifecycle**: create, start, stop, restart, kill, pause/unpause, wait, rm, list, inspect, attach
- [x] **exec** (TTY and pipes), **cp**, **logs** (tail/follow/timestamps, 100 MiB cap), **stats**, **events**, **healthchecks**
- [x] **Images**: pull (with progress), list, inspect, tag, rm, prune, save, push, private registries
- [x] **Networks**: `bridge`, `none`, custom networks with name resolution ([SPEC D-25](SPEC.md))
- [x] **Image scanning**: osv-scanner, grype, CISA KEV; serious findings stop and block the image
- [x] **Config file** `~/.pratico/config.toml` (overrides only)
- [x] **Release pipeline**: `make dmg`, `make release` with semver tags and GitHub releases
- [x] **Embedded runtime, steps 1–2**: bundled kernel and init, own image store, per-container shim ([design](docs/design/runtime.md))

### Remaining
- [ ] **Embedded runtime** becomes the only runtime: stdin/attach, exec/cp/stats on the guest agent, pratico-net (switch, DNS, Swift uplink, ports), hot connect/disconnect, registry auth, egress intercept; then the Apple `container` CLI backend is removed
- [ ] **Volumes**
- [ ] **Menubar**: container list, usage, alerts, preferences, start at login
- [ ] **Snapshot / restore** of container, network, and volume definitions
- [ ] **Bounds and performance** targets (SPEC AC-44–AC-49)

### Acceptance Criteria
- Standard `docker` CLI connects to `unix://~/.pratico/docker.sock` (API 1.44 or later)
- `docker pull alpine && docker run --rm alpine echo hello` works end-to-end with nothing but Pratico.app installed
- `pratico-menubar` starts the daemon and shows container state
- Daemon start/stop from the menubar is reliable across restarts

### Risks & Mitigations
- **Risk**: Docker API gaps break clients
  - **Mitigation**: every acceptance criterion is an e2e check driving the real `docker` CLI
- **Risk**: apple/containerization is pre-1.0 and changes
  - **Mitigation**: pinned version (0.54.0); upgrades are deliberate and run both e2e suites
- **Risk**: user-space networking (Swift TCP endpoint) is new code on the hot path
  - **Mitigation**: soak tests (bulk, many short connections, loss) before it replaces anything

---

## Version 0.2.0 — Docker API Completeness + Menubar Enhancements (3 months)
**Goal**: Feature-complete Docker Remote API and menubar with Apple container integration

### API Endpoints
- [ ] **Container API v1.36+** — Full create/start/stop/restart/kill/remove
- [ ] **Image API v1.30+** — Full pull/push/inspect/remove
- [ ] **Volume API v1.32+** — Create, inspect, remove volumes
- [x] **Network API** — custom networks, connect/disconnect (in v0.1.0)
- [x] **Stats API** — `docker stats` (in v0.1.0)
- [x] **Events API** — container, image, network events (in v0.1.0)
- [x] **Container exec API** — `docker exec` (in v0.1.0)
- [x] **Logs API** — `docker logs` with tail/follow (in v0.1.0)

### Menubar Enhancements
- [ ] **Container state overview** — Running count, resource usage summary
- [ ] **Quick actions** — Start/stop system, run alpine, prune, open stats
- [ ] **Apple container integration** — Show `container` CLI status alongside Docker
- [ ] **Preferences panel** — Configurable from menubar ⌘,
- [ ] **Status menu about** — Version, build info, links

### Local Endpoint Gateway (workers)
- [ ] **Internal API + MCP gateway** — `pratico-daemon` exposes a local management API and an MCP server, so scripts and AI agents can list, run, and attach containers
- [ ] **Attach container to local endpoint** — bind a container to a local route (e.g. `http://localhost:<port>/<route>` or `<name>.pratico.localhost`); each incoming request is forwarded to the container
- [ ] **On-demand workers** — a request to an attached endpoint starts the container if it is stopped and the container stops again after a configurable idle timeout (scale to zero)
- [ ] **Worker limits** — per-endpoint bounds on concurrent requests, request body size, and request timeout; over-limit requests get a clear error, never unbounded queueing
- Acceptance: attach an image that answers HTTP to a route; first request starts it and returns its response; after the idle timeout the container is stopped; the next request starts it again
- Open: endpoint naming scheme, MCP tool set, and whether the gateway reuses the Docker socket auth model

### Workflow Improvements
- [ ] `docker build -t .` builds images via BuildKit (Apple silicon optimized)
- [x] `docker cp` copies files to/from containers (in v0.1.0)
- [x] `docker exec -it <container> bash` drops into shell (in v0.1.0)
- [x] Resource limits `--cpus`, `--memory` enforced as VM size (in v0.1.0)
- [ ] Restart policies `--restart` supported
- [x] Environment variables `-e` passed through to containers (in v0.1.0)

### Acceptance Criteria
- `docker build`, `docker pull`, `docker run`, `docker ps`, `docker rm` all work
- `docker exec -it <container> bash` drops into shell
- `docker cp <container>:<path> <host>` works
- Menubar shows Docker container count and Apple container count
- Clicking menubar item reveals detailed status

### Risks & Mitigations
- **Risk**: BuildKit integration complexity on Apple silicon
  - **Mitigation**: Use apple/containerization's builder; internet access via pratico-net
- **Risk**: API version skew causes client failures
  - **Mitigation**: Document supported Docker API version; semver the daemon

---

## Version 1.0 — Stable Docker Daemon + Menubar Release (3 months)
**Goal**: Production-ready Docker daemon replacement with menubar

### Refinements
- [ ] **Performance optimization** — All paths tuned for Apple silicon
- [ ] **Error handling** — User-friendly messages matching Docker errors
- [ ] **Documentation** — Migration guide from Docker/Colima, API reference, menubar guide
- [ ] **Telemetry (opt-in)** — Usage statistics for prioritization (no personal data)
- [ ] **Backup/restore** — Container state export/import via daemon API
- [ ] **Multi-user support** — Different users can have isolated container sets via socket groups
- [ ] **Menubar enhancements** — Custom menus, deep linking, preferences persistence

### Acceptance Criteria
- **Functional**: Standard Docker CLI (v20.10+) fully works with pratico daemon
- **Performance**: Container startup < 1s from cold start; < 200ms from warm
- **Reliability**: daemon start/stop from the menubar works across restarts; no socket leaks
- **Security**: Per-container VM isolation; no host kernel sharing; Keychain auth
- **Usability**: Migration from Docker/Colima: install the app, set `DOCKER_HOST` or a docker context; menubar auto-starts
- **Coexistence**: Apple `container` CLI workflows keep working next to pratico

### Release Criteria
- Zero critical bugs in 2-week beta with real-world Docker workflows
- All `docker compose up` basic workloads work
- Menubar app stable across macOS point releases
- Documentation complete and reviewed

### Stretch: 1.1
- Full docker-compose.yaml v2 support (via daemon-level orchestration)
- Kubernetes-like network model (custom bridge networks)
- Registry authentication in pratico's own Keychain item (embedded runtime)
- Menubar deep linking to specific containers

---

## Version 2.0 — Enhanced Daemon Platform (6+ months)
**Goal**: Beyond Docker API — native container platform on Apple infrastructure

### Platform Features
- **Shared image store** — Native deduplication across all containers managed by daemon
- **Advanced resource scheduling** — CPU pinning, memory QoS, auto-scaling based on workload
- **Multi-tenant isolation** — Per-tenant socket paths for SaaS platforms
- **GraphQL API** — Supplemental API for complex orchestration scenarios
- **Edge deployment** — Same container images deploy to iOS/macOS apps

### Innovations
- **Native Swift APIs** — First-class Swift interfaces for container management
- **Swift Concurrency integration** — async/await for container operations
- **Live activity integration** — Container progress in Dynamic Island/Live Activities
- **Metal shader sharing** — GPU compute sharing between host and containers (future)

### Success Metrics
- Docker CLI compatibility: 100% of common workflows work identically
- Performance: within 20% of native metal for I/O workloads
- Stability: weeks-long container runs without daemon restart
- Security: third-party audit passed
- Menubar: 5-star satisfaction rating, optional but highly used