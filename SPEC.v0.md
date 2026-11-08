# Cocker Specification

## Overview

**Cocker** is a macOS container management daemon built with Swift that leverages Apple's container technology (https://github.com/apple/container) to provide a high-performance, native Docker daemon for macOS. It serves as a drop-in replacement for the Docker daemon while also integrating with Apple's `container` CLI.

### Dual Compatibility Philosophy

**v1 Focus: Docker + Apple Container Dual Compatibility**. Cocker serves two masters:

1. **Docker CLI compatibility** — The daemon listens on `unix://~/.cocker/docker.sock`, enabling existing Docker clients (Docker CLI, docker-compose, tools expecting `/var/run/docker.sock`) to work without modification.

2. **Apple container CLI compatibility** — The daemon also exposes integration points with Apple's `container` CLI (`container run`, `container system start`, etc.), allowing users to leverage both ecosystems.

This approach:
- Leverages existing Docker CLI, docker-compose, and tooling without reimplementation
- Provides immediate compatibility with the Docker ecosystem
- Allows cocker's superior isolation (one-VM-per-container) to be used by any Docker-compatible tool
- Integrates with Apple's native `container` tooling for a seamless macOS experience

### Key Differentiators

| Feature | Docker Desktop | Colima | Cocker |
|---------|---------------|--------|--------|
| Architecture | Shared VM + gRPC FUSE | Lima/QEMU + containerd | One-VM-per-container |
| Container Isolation | Shared kernel | Shared kernel | Full VM isolation per container |
| Performance | Good, but heavy | Good, vz backend fast | Comparable to colima, better isolation |
| Native macOS | Yes (Electron-based) | Yes (shell-based) | Yes (Swift-native) |
| Drop-in compatibility | Yes | Yes (via docker.sock) | Yes (full API compatibility) |
| Image build support | Yes | Yes (via BuildKit) | Yes (optimized for Apple silicon) |
| Resource overhead | High | Medium | Low per-container, shared image store |

## Architecture

### High-Level Design

Cocker consists of three primary components:

```
cocker/
├── cocker-daemon       # Docker Remote API daemon (core)
│   - Listens on unix socket (~/.cocker/docker.sock) or TCP
│   - Implements Docker Remote API specification
│   - Manages container lifecycle via Apple Virtualization
│   - Handles image storage and distribution
│   - Exposes network configuration
│   - XPC helpers for per-container runtime
├── cocker-menubar      # macOS menubar app (SwiftUI)
│   - Status menu with container state overview
│   - Quick actions: start/stop system, run alpine, prune
│   - Integration with `container` CLI status
│   - Open container URLs in browser
│   - System preferences panel
│   - Updates and about panel
│   - Optional: hide/show daemon status
├── cocker-cli          # Convenience CLI (optional, docker-compatible)
│   - Thin wrappers that set DOCKER_HOST and call docker CLI
│   - Or direct subcommands for quick operations
└── Config              # `~/.cocker/config.toml`
```

### Component Details

1. **cocker-daemon** - Docker Remote API daemon (core)
   - **Listens** on `unix://~/.cocker/docker.sock` by default
   - **Implements** the Docker Remote API specification (versioned endpoints)
   - **Manages** container lifecycle: create, start, stop, restart, kill, remove
   - **Handles** image operations: pull, push, build, remove, import, export, tag, untag
   - **Provides** container info: `docker ps`, `docker images`, `docker inspect`
   - **Manages** networks: create, connect, disconnect, list networks
   - **Statistic**s: `docker stats`, `docker events`
   - **Authenticates** via Keychain for registry access
   - **Excludes** data from Time Machine backups
   - **Uses** macOS Virtualization framework for container VMs
   - **Uses** vmnet framework for per-container networking
   - **Integrates** with Keychain for credential management
   - **Communicates** with menubar app via UserDefaults or XPC

2. **cocker-menubar** - macOS menubar app (SwiftUI)
   - **Status menu** showing container state (running count, memory/CPU usage)
   - **Quick actions**:
     - `Start System` / `Stop System`
     - `Run Alpine` (quick test)
     - `Prune unused`
     - `Open Stats`
   - **Integration with `container` CLI**:
     - Show `container system status`
     - Display Apple container info alongside Docker info
   - **Preferences panel** (accessed via ⌘, in menu):
     - Daemon socket configuration
     - Default resource allocation
     - Mount type (virtiofs/bind)
     - Network settings
   - **Click behavior**:
     - Clicking main item → toggle container details
     - Option-click → open cocker config folder
     - Right-click → full menu
   - **Uses** SwiftUI StatusBar API
   - **Uses** Combine for state management
   - **Native menubar** appearance matching macOS

3. **cocker-cli** - Convenience CLI (optional; thin wrapper approach)
   - Can invoke: `cocker run`, `cocker start`, `cocker stop`, etc.
   - For v1, these are **thin wrappers** that set `DOCKER_HOST` and delegate to the system `docker` binary
   - Example: `cocker run ...` sets `DOCKER_HOST=unix://~/.cocker/docker.sock` then calls `docker run ...`
   - Full `docker` CLI compatibility via environment variable injection
   - Optional direct subcommands for quick operations without invoking system docker

4. **Configuration** - `~/.cocker/config.toml`
   - `daemon_socket` - Socket path for API listener
   - `menubar_enabled` - Whether to show menubar app (default: true)
   - `default_cpus`, `default_memory` - Resource defaults
   - `mount_type` - virtiofs vs bind mount
   - Network DNS, search domains
   - Registry configuration
   - `container_cli_path` - Path to Apple's `container` binary (auto-detected)

### Container Lifecycle

```
Container Creation:
1. CLI sends request to apiserver
2. Apiserver checks image store, pulls if needed
3. Apiserver launches cocker-runtime-linux helper
4. Runtime creates lightweight VM via Virtualization framework
5. Container kernel boots, filesystem layers applied
6. Process starts inside container
7. CLI receives container ID, reports ready state

Container Runtime:
- Each container runs in its own lightweight VM
- Full process isolation from host and other containers
- Network isolation with dedicated virtual IP
- Mounted volumes via virtioFS or bind mounts
- Resource limits (CPU, memory) enforced via VM settings

Container Termination:
1. CLI sends kill signal to container process
2. Graceful shutdown with timeout
3. VM stopped, filesystem snapshotted (optional)
4. Resources reclaimed
5. Container state persisted to disk (for restart)
```

### Image Format

- OCI-compatible (images from any registry work)
- Compressed with zstd for faster transfer
- Local cache with content-addressable storage
- Image snapshots excluded from Time Machine backups

### Configuration

Default config at `~/.cocker/config.toml`:

```toml
# Cocker configuration
[general]
# Use virtioFS for volume mounts (better performance)
mount_type = "virtiofs"

# Default CPU allocation per container
default_cpus = 2.0

# Default memory allocation per container (in MB)
default_memory = 2048

# Enable/k8s support
enable_k8s = false

# DNS configuration
[dns]
nameservers = ["1.1.1.1", "8.8.8.8"]
search_domains = ["local"]
options = ["ndots:0"]

# Image store path
[image_store]
path = "~/.cocker/store"

# Network configuration
[network]
# Use vmnet for per-container networking
use_vmnet = true

# Default network type
default_network = "bridge"

# Registry configuration
[registries]
default = "docker.io"

[auth]
username = ""
password = ""
```

## Goals

### Primary Goals

1. **Drop-in Docker Compatibility** - `cocker` should accept the same CLI arguments as `docker` and produce equivalent results. Users should be able to replace `docker` with `cocker` in their scripts with minimal changes.

2. **Better Performance Than Colima** - Achieve comparable or superior performance to colima (which currently is the fastest free option) while providing full VM isolation per container.

3. **Native macOS Experience** - Built with Swift and optimized for Apple silicon, integrating with macOS frameworks (Virtualization, vmnet, Keychain, unified logging).

4. **Strong Isolation** - Each container in its own VM boundary, unlike colima/Docker Desktop which share a kernel.

5. **Apple Silicon Optimized** - All performance paths tuned for M-series chips, including Rosetta 2 support for amd64 containers.

### Stretch Goals

6. **Docker Compose Support** - Native or near-native docker-compose.yaml support.

7. **Kubernetes Integration** - `cocker cluster` subcommand for managing multi-node clusters.

8. **DevContainer Support** - Full devcontainer.json compatibility for VS Code.

9. **Image Building with Network Access** - BuildKit support with internet access for `apk add`, `apt-get install`, etc.

10. **Resource Sharing** - Shared image store across containers to reduce disk usage (similar to `container --shared-image-store`).

## Non-Goals (for v1.0)

- Windows support (macOS only, Apple silicon first)
- GPU passthrough
- x86_64 host support (Apple silicon only)
- Full Docker Enterprise features
- Swarm mode
- GUI interface (CLI-only, with optional status monitoring)

## Requirements

### Functional Requirements

| ID | Requirement |
|----|-------------|
| FR-001 | `cocker run --rm alpine echo hello` must work out of the box |
| FR-002 | `cocker pull nginx` must pull and cache OCI images |
| FR-003 | `cocker build -t myapp .` must build images using BuildKit |
| FR-004 | `cocker ps` must list running containers |
| FR-005 | `cocker images` must list cached images |
| FR-006 | `cocker rm <container>` must remove stopped containers |
| FR-007 | `cocker exec -it <container> <cmd>` must execute commands in running container |
| FR-008 | `cocker logs <container>` must show container logs |
| FR-009 | `cocker system start/stop` must start/stop the cocker service |
| FR-010 | `cocker cp <container>:<path> <local-path>` must copy files from container |
| FR-011 | `cocker kill <container>` must kill a running container |
| FR-012 | Container resources (CPU, memory) must be configurable via CLI flags |
| FR-013 | `cocker run -v <host>:<container>` must mount host directories |
| FR-014 | `cocker run -p <host>:<container>` must publish container ports |
| FR-015 | Container must be accessible via `localhost:<host_port>` after `-p` |

### Non-Functional Requirements

| ID | Requirement |
|----|-------------|
| NFR-001 | Container startup time < 500ms (measured from `cocker run` to process running) |
| NFR-002 | Memory overhead per container < 200MB when idle |
| NFR-003 | CPU overhead per container < 5% when idle |
| NFR-004 | Image pull speed comparable to `container` tool (Apple's tool) |
| NFR-005 | `cocker` CLI must accept same flags as `docker` equivalents |
| NFR-006 | Configuration stored in `~/.cocker/config.toml` (TOML format) |
| NFR-007 | No external hypervisor required (uses macOS Virtualization framework) |
| NFR-008 | OCI image format compliance (spec compliance) |
| NFR-009 | Exclude container data from Time Machine backups where appropriate |
| NFR-010 | Swift 5.9+, Xcode 15+ compatibility |

### Technical Requirements

- Written in Swift (leveraging Apple's Containerization package)
- Uses macOS Virtualization framework for container VMs
- Uses vmnet framework for per-container networking
- XPC-based inter-service communication
- OCI image format compliance
- Keychain integration for registry credentials
- Unified logging system integration
- Launchd service management

## API Design

### CLI Interface

The `cocker` CLI should mimic `docker` as closely as possible:

```
Usage: cocker [command]

Basic commands:
  cocker run        Run a command in a container
  cocker start      Start a stopped container
  cocker stop       Stop a running container
  cocker rm         Remove one or more containers
  cocker ps         List containers
  cocker images     List images
  cocker rmi        Remove one or more images
  cocker pull       Pull an image from a registry
  cocker push       Push an image to a registry
  cocker build      Build an image from a Dockerfile
  cocker exec       Execute a command in a running container
  cocker logs       Fetch container output
  cocker stats      Display container(s) resource usage

System commands:
  cocker system start    Start the cocker system service
  cocker system stop     Stop the cocker system service
  cocker system reset    Reset/cleanup system state

  cocker version       Show version information
  cocker context       Manage contexts

Flags (Docker-compatible):
  --help               Show help for a command
  --rm                 Remove container when it exits
  -it                  Allocate TTY and keep STDIN open
  -d                   Run in detached mode
  -c                   CPU allocation (e.g., -c 2.0)
  -m                   Memory allocation (e.g., -m 1024)
  -v                   Bind mount volume (e.g., -v /host:/container)
  -p                   Publish port (e.g., -p 8080:80)
  -e                   Environment variable (e.g., -e KEY=value)
  -w                   Working directory (e.g., -w /app)
  -k                   Keep STDIN open without TTY
  -N                   Network mode (e.g., -N bridge)
  -H                   Docker host (e.g., -H unix:///path/to/sock)
```

### XPC API

Internal API between CLI and services:

```
cocker-apiserver exposes:

- CreateContainer(request: CreateContainerRequest) -> ContainerID
- StartContainer(id: ContainerID) -> StartResult
- StopContainer(id: ContainerID, signal: Signal) -> StopResult
- RemoveContainer(id: ContainerID) -> RemoveResult
- ListContainers(filters: [String: String]) -> [ContainerInfo]
- GetContainer(id: ContainerID) -> ContainerInfo
- PullImage(request: PullImageRequest) -> ImageProgress
- BuildImage(request: BuildImageRequest) -> BuildProgress
- RemoveImage(id: ImageID) -> RemoveResult
- ListImages(filters: [String: String]) -> [ImageInfo]
- CreateNetwork(request: CreateNetworkRequest) -> NetworkID
- ConnectContainerToNetwork(id: ContainerID, networkID: NetworkID) -> ConnectResult
- DisconnectContainerFromNetwork(id: ContainerID, networkID: NetworkID) -> DisconnectResult
- GetContainerLogs(id: ContainerID, tail: Int) -> String
- GetContainerStats(id: ContainerID) -> ContainerStats
```

## Configuration and State

### Directories

- `~/.cocker/` - User configuration and state
- `~/.cocker/config.toml` - TOML configuration file
- `~/.cocker/store/` - Local OCI image store
- `~/.cocker/containers/` - Container runtime state
- `~/.cocker/logs/` - Container and system logs

### State Management

- Container state persisted to disk for restart support
- Image layers stored in content-addressable store
- Network configuration persisted per cluster/node
- Lease-based locks for concurrent access

### Time Machine Exclusion

Container data should be excluded from Time Machine backups via com.apple.backup restarter Info.plist or equivalent mechanism. Specifically:
- Image store directory
- Container filesystem snapshots
- Temporary build containers

## Security Model

### Isolation Properties

1. **Per-Container VM** - Each container runs in its own lightweight VM, providing hardware-level isolation
2. **No Shared Kernel** - Unlike Docker Desktop/Podman rootless, cocker does not share the host kernel
3. **Network Isolation** - Each container has its own virtual network interface with dedicated IP
4. **Filesystem Isolation** - Container filesystem is separate from host and other containers
5. **Resource Limits** - CPU and memory limits enforced per-container via VM settings

### Data Privacy

- Only necessary host data is mounted into each container VM
- Default: no host data mounted unless explicitly requested via `-v`
- Mounted volumes are read-only by default unless `rw` specified
- Keychain used for registry credentials (not stored in plain text)

### Attack Surface Reduction

- Minimal core utilities inside each container VM
- Only essential dynamic libraries included
- XPC helpers run with least privilege
- Container VMs have no inbound network access by default (outbound only via published ports)

## Performance Optimizations

### Virtualization Framework Usage

- Use macOS Virtualization framework (not QEMU/KVM layer)
- Sub-second container boot times (target: < 500ms)
- Memory ballooning support (partial - acknowledge limitation)
- CPU pinning to physical cores

### Storage Optimizations

- VirtioFS for volume mounts (when available, ~80% faster than sshfs)
- zstd-compressed image layers
- Overlay filesystem for container layers
- Local cache avoid redundant downloads

### Network Optimizations

- vmnet for per-container virtual networking
- DNS resolver configured for container names
- Minimal latency for port-forwarded connections
- C2C throughput competitive with OrbStack

### Build Optimizations

- BuildKit integration optimized for Apple silicon
- Layer caching for faster rebuilds
- Parallel build steps
- No internet required for re-builds (cached layers)

## Roadmap

### Phase 1: MVP (3 months)
- [ ] Basic `cocker run` with alpine image
- [ ] Image pull and cache
- [ ] Container start/stop/rm
- [ ] `cocker ps`, `cocker images`
- [ ] Basic `-v` and `-p` flag support
- [ ] Config file at `~/.cocker/config.toml`
- [ ] `cocker system start/stop`

### Phase 2: Core Features (3 months)
- [ ] `cocker build` with BuildKit
- [ ] `cocker pull`/`push` to registries
- [ ] `cocker exec` command execution
- [ ] `cocker logs` fetch
- [ ] `cocker stats` resource display
- [ ] VirtioFS volume mount support
- [ ] DNS configuration for containers
- [ ] Time Machine exclusion

### Phase 3: Performance & Integration (3 months)
- [ ] Container startup < 500ms
- [ ] Image build performance comparable to Docker Desktop
- [ ] Improved C2C networking via vmnet
- [ ] Shared image store across containers
- [ ] Better resource default settings
- [ ] Enhanced error messages and DX

### Phase 4: Ecosystem (3 months)
- [ ] Docker Compose support (basic)
- [ ] Kubernetes cluster management
- [ ] DevContainer integration
- [ ] Resource visualization GUI (optional)
- [ ] Plugin system for extensibility
- [ ] Multi-architecture support (arm64 + amd64 via Rosetta 2)

### Phase 5: Polish (2 months)
- [ ] Comprehensive documentation
- [ ] Migration guide from Docker/Colima
- [ ] Troubleshooting guide
- [ ] Performance benchmarking suite
- [ ] Community contributions process

## Success Metrics

### v1.0 Success Criteria

1. **Functional Compatibility**: 90% of common Docker CLI commands work identically
2. **Container Startup**: < 500ms from `cocker run` to running process
3. **Memory Overhead**: < 200MB per container when idle
4. **Image Pull Speed**: Within 20% of `container` (Apple's tool) speeds
5. **Build Success**: `cocker build -t test .` with simple Dockerfile works
6. **Volume Mounts**: `-v` flags work for both read-only and read-write mounts
7. **Port Mapping**: `-p` flags make container services accessible on localhost
8. **System Service**: `cocker system start` works and persists across restarts

### v1.1 Success Criteria (added)
1. Docker Compose file support (up to docker-compose v2 basic)
2. Kubernetes-like network model
3. Shared image store reduces disk usage by 30%+
4. Container restart works persistently
5. Registry authentication via Keychain

### v2.0 Success Criteria (stretch)
1. Full docker-compose.yaml compatibility
2. Multi-node cluster support
3. GPU support (future)
4. Performance within 10% of native metal for I/O workloads
5. CLI `cocker` fully replaces `docker` in CI/CD pipelines

## Known Limitations (v1.0)

1. **No Docker Compose v3 support** - Basic compose file v2 support only
2. **No GPU passthrough** - Apple silicon GPU not exposed to containers
3. **Memory ballooning not fully supported** - Pages freed to Linux VM not relinquished to host
4. **BuildKit without internet** - `apk add`, `apt-get install` may fail without network
5. **No Windows support** - macOS Apple silicon only
6. **Colima profile compatibility** - `--profile` flags not supported
7. **Kata kernel dependency** - Requires specific Kata Containers kernel version

## Open Questions

1. **Shared image store**: Should cocker share OCI image layers across containers by default, or keep them isolated?
2. **Network model**: Default bridge network vs. custom vmnet-based model?
3. **Resource defaults**: What are sensible default CPU/memory allocations for containers?
4. **BuildKit network access**: How to handle builds that need internet access?
5. **Docker Compose complexity**: Which levels of docker-compose.yaml are supported?
6. **Debugging experience**: How to surface container logs and diagnostics to users?
7. **Error handling**: What error format to use (Docker-compatible vs. custom)?

## Prior Art & Inspiration

### Direct Inspiration

- **apple/container** - Core technology, VM-per-container architecture, Swift implementation
- **colima** - Docker socket proxy, Lima VM management, virtioFS support
- **container-diff** - Image management and storage concepts

### Indirect Inspiration

- **Docker Desktop** - CLI compatibility model, BuildKit integration, resource management
- **OrbStack** - Performance characteristics, networking, container startup speed
- **Podman** - Rootless container concepts, rootless socket management
- **nerdctl** - Container CLI implementation patterns

### macOS Technologies Leveraged

- **Virtualization framework** - Container VM management
- **vmnet** - Per-container virtual networking
- **Keychain** - Registry credential storage
- **Unified logging** - Container log collection
- **Launchd** - Service lifecycle management
- **Swift Concurrency** - Async CLI operations