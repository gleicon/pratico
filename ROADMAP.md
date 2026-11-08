# Pratico Roadmap

## Version 0.1.0 — Docker Daemon + Menubar MVP (3 months)
**Goal**: Docker Remote API daemon + macOS menubar app with dual compatibility

### Core Deliverable
- [ ] **pratico-daemon** — Docker Remote API daemon listening on `unix://~/.pratico/docker.sock`
- [ ] **Docker API compliance** — Implement core Docker API endpoints (containers, images, volumes, networks)
- [ ] **pratico-menubar** — macOS menubar app (SwiftUI) with status menu
- [ ] **Container lifecycle** — create, start, stop, restart, kill, remove via Apple Virtualization
- [ ] **Image management** — pull, push, inspect, prune via OCI store
- [ ] **Basic virtualization** — Lightweight VM per container using macOS Virtualization framework
- [ ] **Config file** — `~/.pratico/config.toml` with daemon socket path, menubar defaults
- [ ] **DOCKER_HOST setup** — `pratico system start` configures socket for client connection

### Dual Compatibility
- [ ] **Docker CLI**: `docker version` reports client/server; `docker pull && docker run` works
- [ ] **Apple container CLI**: `container system status` integrates with pratico menubar
- [ ] **Menubar status** shows both Docker and Apple container state

### Acceptance Criteria
- Standard `docker` CLI (v20.10+) can connect to `unix://~/.pratico/docker.sock`
- `docker pull alpine && docker run --rm alpine echo hello` works end-to-end
- `pratico-menubar` appears in macOS menu bar on login
- Menubar click shows container state overview
- `pratico system start` is stable across restarts

### Risks & Mitigations
- **Risk**: Docker API implementation gaps prevent client compatibility
  - **Mitigation**: Start with subset of v1.25 API; test against `docker` CLI regularly
- **Risk**: Menubar app complexity on different macOS versions
  - **Mitigation**: SwiftUI StatusBar; target macOS 13+ (Ventura)+
- **Risk**: Dual compatibility (Docker + Apple CLI) creates confusion
  - **Mitigation**: Clear separation; menubar shows both; config toggles

---

## Version 0.2.0 — Docker API Completeness + Menubar Enhancements (3 months)
**Goal**: Feature-complete Docker Remote API and menubar with Apple container integration

### API Endpoints
- [ ] **Container API v1.36+** — Full create/start/stop/restart/kill/remove
- [ ] **Image API v1.30+** — Full pull/push/inspect/remove
- [ ] **Volume API v1.32+** — Create, inspect, remove volumes
- [ ] **Network API v1.34+** — Create custom networks, connect/disconnect containers
- [ ] **Stats API** — `docker stats` with CPU, memory, network, disk I/O
- [ ] **Events API** — Container state change events
- [ ] **Container exec API** — `docker exec` command execution
- [ ] **Logs API** — `docker logs` with tail/follow support

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
- [ ] `docker cp` copies files to/from containers
- [ ] `docker exec -it <container> bash` drops into shell
- [ ] Resource limits `--cpu`, `--memory` actually enforced
- [ ] Restart policies `--restart` supported
- [ ] Environment variables `-e` passed through to containers

### Acceptance Criteria
- `docker build`, `docker pull`, `docker run`, `docker ps`, `docker rm` all work
- `docker exec -it <container> bash` drops into shell
- `docker cp <container>:<path> <host>` works
- Menubar shows Docker container count and Apple container count
- Clicking menubar item reveals detailed status

### Risks & Mitigations
- **Risk**: BuildKit integration complexity on Apple silicon
  - **Mitigation**: Use apple/containerization BuildKit fork; internet access via vmnet
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
- **Reliability**: `pratico system start/stop` works across restarts; no socket leaks
- **Security**: Per-container VM isolation; no host kernel sharing; Keychain auth
- **Usability**: Migration from Docker/Colima: `pratico system start`; menubar auto-starts
- **Dual compat**: Both `docker` CLI and `container` CLI workflows work

### Release Criteria
- Zero critical bugs in 2-week beta with real-world Docker workflows
- All `docker compose up` basic workloads work
- Menubar app stable across macOS point releases
- Documentation complete and reviewed

### Stretch: 1.1
- Full docker-compose.yaml v2 support (via daemon-level orchestration)
- Kubernetes-like network model (custom bridge networks)
- Registry authentication via Keychain (login/logout/status)
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