# Examples

Each script talks to `~/.pratico/docker.sock` (set `PRATICO_SOCK` for another), uses
names starting with `pratico-example`, and removes what it creates.

| Script | Shows |
|---|---|
| `01-hello.sh` | a Docker context for pratico, the VM's own kernel, `/pratico/status` |
| `02-volumes.sh` | postgres on a disk volume, shares, copy-up, `nocopy`, tmpfs |
| `03-cp-stopped.sh` | `docker cp` into a created container and out of an exited one |
| `04-apple-container.sh` | moving images to and from Apple's `container` as OCI archives |
| `05-scanning.sh` | installed scanners, scan summary, findings with EPSS, SBOMs |
| `06-snapshot.sh` | taking a snapshot and a dry-run restore |
| `07-cleanup.sh` | disk use, cleanup plans, prune filters (`--prune` to act) |
| `08-networks.sh` | one NIC with an address per network, five networks on one container, moving the default route |
| `09-agents.sh` | the MCP endpoint as an agent calls it: image check, a throwaway run, a kept service |
| `10-build.sh` | `docker build` through buildx: a multi-stage build loaded and scanned |
| `11-egress.sh` | a container's connections, threat feeds, an allowlist |
| `compose-private-networks/` | a Compose project with a private and an internal network |
| `custom-scanner/my-scanner` | the custom scanner contract (`scan_custom`) |

pratico's own endpoints, used here with `curl`:

| Endpoint | |
|---|---|
| `GET /pratico/status` | version, pid, socket, container counts, change counter |
| `GET /pratico/containers` | running containers with ports, health, CPU, memory |
| `GET /pratico/disk` | disk use by kind and the cleanup plans |
| `GET /pratico/scanners` | scanners and SBOM tool found, with versions |
| `GET /pratico/scans`, `/pratico/scans/summary` | findings per image; counts |
| `POST /pratico/scans` | rescan every image |
| `POST /pratico/scans/{id}/allow` | allow a blocked image (`scan_allow`) |
| `GET /pratico/scans/{id}/sbom?format=spdx\|cyclonedx` | SBOM written by syft |
| `POST /pratico/snapshots`, `GET /pratico/snapshots` | take, list snapshots |
| `POST /pratico/snapshots/restore?path=…[&dry_run=1][&start=1]` | restore |
| `DELETE /pratico/alerts` | clear alerts |
