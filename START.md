# Pratico Quick Start

## Philosophy

**Pratico is a Docker daemon + macOS menubar app.** The primary deliverable is:
1. A **Docker Remote API daemon** listening on `unix://~/.pratico/docker.sock`
2. A **menubar app** (`pratico-menubar`) that integrates with Apple's `container` CLI

Once the daemon is running, **any Docker-compatible client** can connect. And the menubar gives you quick access to both worlds.

---

## Installation

```bash
# Using Homebrew (once available)
brew install pratico/tap/pratico

# Or download from releases (Apple silicon only)
curl -L https://github.com/apple/container/releases/latest/download/container-macos-arm64.tar.gz -o container.tar.gz
tar -xzf container.tar.gz
sudo mv container /usr/local/bin/container

# Build from source (Swift)
swift build --release
# Then: sudo cp .build/release/pratico-* /usr/local/bin/
```

---

## Starting the Service

### Start the daemon + menubar

```bash
# Method 1: Launch both daemon and menubar
pratico system start

# Method 2: Just the daemon (menubar starts on login)
pratico daemon start

# Method 3: Menubar only (if daemon already running)
pratico menubar start
```

### Verify everything is running

```bash
# Check daemon is listening
docker version

# Check menubar is active (look at top-right of screen)
# Or:
pratico menubar status

# Apple container CLI should also work:
container system status
```

---

## Using the Docker CLI (via DOCKER_HOST)

```bash
# The daemon automatically sets DOCKER_HOST
# Or manually export:
export DOCKER_HOST="unix://${HOME}/.pratico/docker.sock"

# Now use standard Docker CLI:
docker pull alpine
docker run --rm alpine echo "hello from pratico!"

# Full workflow:
docker pull nginx:latest
docker run -d -p 8080:80 nginx
docker ps
docker images
docker build -t myapp .
docker exec -it <container_id> bash
docker cp <container_id>:/etc/hosts /local/hosts
docker logs <container_id>
docker system prune
```

---

## Using Apple's container CLI

The menubar app integrates with Apple's `container` tool:

```bash
# Check status from menubar or CLI:
container system status

# Run a container via Apple's tool (interoperable):
container run --rm alpine echo "hello from apple container!"

# The pratico daemon can also run these images:
docker run --rm alpine echo "hello from pratico!"
```

### Menubar integration

Click the pratico menubar icon to see:
- **Docker status** — container count, resource usage
- **Apple container status** — `container` system status
- **Quick actions**:
  - `Run Alpine` — quick test container (uses pratico daemon)
  - `Prune unused` — clean up stopped containers/untagged images
  - `Open Stats` — detailed resource usage
  - `Preferences` — configure socket path, defaults
  - `Quit` — stop the daemon

---

## Basic Usage Examples

### Run a container (Docker CLI way)

```bash
# Pull and run
docker pull alpine
docker run --rm alpine echo "Hello, Pratico!"

# With resources
docker run -c 1.0 -m 512m alpine echo "limited resources"

# With volume mount
docker run -v /tmp/data:/data -it alpine bash

# With port mapping
docker run -p 8080:80 -d nginx
# Access at: http://localhost:8080
```

### Run a container (Apple CLI way, via menubar)

```bash
# Via menubar "Run Alpine" quick action
# Or from terminal:
container run --rm alpine echo "Hello from Apple's container!"
```

### Manage containers

```bash
# List running containers
docker ps

# List all containers (including stopped)
docker ps -a

# Inspect a container
docker inspect <container_id>

# Stop a running container
docker stop <container_id>

# Remove a container
docker rm <container_id>

# Remove all stopped containers
docker container prune

# Remove an image
docker rmi <image_name>:<tag>

# Clean up everything
docker system prune -a
```

### Working with images

```bash
# Pull an image
docker pull nginx:latest

# Pull with specific platform
docker pull --platform linux/arm64 alpine

# List images
docker images

# Tag an image
docker tag nginx:latest myregistry/nginx:latest

# Push an image
docker push myregistry/nginx:latest
```

### Executing in running containers

```bash
# Execute a command
docker exec -it <container_id> bash

# Execute without TTY
docker exec <container_id> ls /tmp

# Copy files from container
docker cp <container_id>:/etc/hosts /local/hosts

# View container logs
docker logs <container_id>

# Follow container logs
docker logs -f <container_id>
```

### System commands (via menubar or CLI)

```bash
# Show version and build info
pratico version     # or: docker version

# Reset/cleanup
pratico system reset     # or: docker system reset

# Configure from menubar ⌘,
# Or edit: ~/.pratico/config.toml
```

---

## Configuration

Config file: `~/.pratico/config.toml`

```toml
# Enable/Disable menubar app
menubar_enabled = true

# Daemon socket path
daemon_socket = "unix://${HOME}/.pratico/docker.sock"

# Default resource allocation per container
default_cpus = 2.0
default_memory = 2048

# Use virtioFS for volume mounts (better performance)
mount_type = "virtiofs"

# Network setup
[network]
use_vmnet = true
default_network = "bridge"

# Registry configuration
[registries]
default = "docker.io"

# Apple container CLI path (auto-detected, but can override)
container_cli_path = "/usr/local/bin/container"

# Authentication (uses Keychain)
[auth]
username = "your-registry-username"
# password stored in Keychain, not in config
```

### Menubar behavior

- `menubar_enabled = true` (default): pratico-menubar starts with system
- `menubar_enabled = false`: daemon only, no menubar
- Menubar auto-starts on login (adds itself to Login Items)
- Menubar can be hidden in preferences
- Click behavior configurable (toggle details, open URL, etc.)

---

## Full Development Workflow

```bash
# 1. Start pratico (daemon + menubar)
pratico system start

# 2. Verify Docker CLI works
docker version
# Should show: Client: Docker Engine - Community, Server: Pratico

# 3. Pull a base image
docker pull golang:1.21-alpine

# 4. Build your app (BuildKit, Apple silicon optimized)
docker build -t myapp:latest .

# 5. Run with volume mount for hot-reload
#    -v $(pwd):/app makes code changes immediate
docker run -p 8080:8080 -v $(pwd):/app -d myapp:latest

# 6. Access your app at http://localhost:8080

# 7. Inspect running container from menubar
#    - Click menubar icon → see container details

# 8. View logs
docker logs myapp_container

# 9. When done, stop and remove
docker stop myapp_container
docker rm myapp_container

# 10. Stop the system (menubar auto-hides or quit from menu)
pratico system stop
```

---

## Troubleshooting

### Common issues

1. **`pratico system start` fails**
   - Ensure macOS 13+ (Ventura) with Apple silicon
   - Check Virtualization framework is enabled (System Settings → Privacy & Security)
   - View logs: `pratico system logs` or check console.app

2. **`docker version` shows error connecting to socket**
   - Verify: `export DOCKER_HOST="unix://${HOME}/.pratico/docker.sock"`
   - Verify daemon: `pratico daemon status`
   - Check socket exists: `ls -la ~/.pratico/docker.sock`

3. **Menubar doesn't appear**
   - Ensure `menubar_enabled = true` in config
   - Check System Settings → Users & Groups → Login Items
   - Try: `pratico menubar start`

4. **Container won't start**
   - Check resources: `docker ps` shows status
   - Verify image is cached: `docker images`
   - Check: `docker logs <container_id>`

5. **Volume mounts not working**
   - Try `mount_type = "virtiofs"` in config
   - Ensure host path exists and is readable
   - Check permissions: `chmod 755 /tmp/data`

6. **Apple container CLI not integrating**
   - Verify `container_cli_path` in config points to `/usr/local/bin/container`
   - Ensure `container` CLI is installed and executable
   - Check: `container --help`

### Getting help

```bash
pratico --help            # CLI help
pratico daemon --help     # Daemon help
pratico menubar --help    # Menubar help

# Apple's container CLI
container --help

# Standard Docker help
docker --help
docker pull --help
docker run --help
```