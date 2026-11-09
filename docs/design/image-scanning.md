# Image scanning — design

Status: implemented (SPEC D-24) except where marked follow-up. Backlog item "Automatic image scanning".

## Goal

Every image that reaches pratico through `docker pull` (and, later, `docker build`) is
checked for known vulnerabilities, known-malicious packages, and malicious files, using
free sources only. Pulls are never slowed down. When a scan finds a **serious** problem,
running containers from that image are stopped and the user is warned.

## Decisions taken

- Scans run in the background after a pull completes; the pull itself is unaffected.
- A serious finding stops the image's running containers and warns the user.
- Scanners: osv-scanner and grype. No paid services. Snyk is out.
- Look beyond package CVEs: the image's bill of materials (SBOM) and content hashes.

## Pipeline

```
pull completes
  → export image to a Docker archive          (same code path as `docker save`, D-23)
  → SBOM: syft → CycloneDX JSON               (one inventory, reused by every scanner)
  → osv-scanner on the SBOM                    vulnerabilities + OpenSSF MAL- advisories
  → grype on the SBOM                          vulnerabilities, offline DB
  → unpack layers → spotter -offline -r        file hashes (MalwareBazaar), URLs
                                               (URLhaus/PhishTank/OpenPhish), ClamAV if present
  → enrich: CISA KEV, FIRST EPSS               "is this CVE exploited in the wild?"
  → verdict → store → enforce → warn
```

Implemented today: export → osv-scanner → grype → KEV → verdict → store → enforce → warn.
SBOM via syft, spotter, and EPSS are follow-ups.

Each step is optional: a scanner that is not installed is skipped and the report says so.
No scanner means no verdict, never a false "clean".

## Sources (all free)

| Source | What it answers | Access |
|---|---|---|
| OSV.dev (osv-scanner) | CVEs across ecosystems + OpenSSF Malicious Packages (`MAL-*`) | API, no key |
| Grype DB (Anchore) | distro + language CVEs, offline | downloaded DB |
| GitHub Advisory DB | language CVEs | via OSV |
| CISA KEV | CVEs known to be exploited | JSON feed, no key |
| FIRST EPSS | exploit probability per CVE | API, no key |
| MalwareBazaar | known-malware file hashes | via spotter (local DB + optional lookup) |
| URLhaus / PhishTank / OpenPhish | malicious URLs embedded in files | via spotter |
| ClamAV | signature-based malware | local, optional |
| Artifact Hub | security reports for images it lists | API, no key; low coverage, enrichment only |

Image or layer digests are not useful reputation keys: no free feed indexes them. Content
is identified by the SBOM (packages) and per-file hashes (spotter).

## Verdict

Configurable with `scan_block` (default `kev`):

| `scan_block` | serious (stop + block) |
|---|---|
| `off` | nothing; everything warns |
| `malware` | `MAL-*` advisories, malware hits |
| `kev` (default) | the above + CVEs in CISA KEV |
| `critical` | the above + Critical CVEs (CVSS ≥ 9.0) |

Anything found below the threshold, plus High CVEs, is a **warning**. The default does not
block on Critical alone: at the time of writing `alpine:latest` carries a Critical zlib CVE
(fix released upstream, not yet in the image, not in KEV), and blocking it would stop most
containers. **ok**: nothing found above Medium. **unknown**: no scanner ran.

## Storage

`~/.pratico/scans/<image-id>.json`: findings (id, aliases, package, version, fixed
versions, severity, CVSS, sources, malicious, KEV), the package list (BOM), which scanners
ran (or why not), the KEV feed date, and the scan time. The verdict is not stored: it is
recomputed from findings under the current `scan_block`. Scans are keyed by
image ID, so a re-tag reuses the result; a new digest gets a new scan. Excluded from Time
Machine like the rest of the store. No credentials are involved.

## Enforcement (agreed)

On a **serious** verdict:

1. Stop running Docker containers created from that image ID (`docker stop` semantics,
   10 s grace; Docker's own `kill`/`die`/`stop` events follow).
2. Refuse to start containers from it (`409`, message names the finding), until the user
   allows the image.
3. Warn: menubar alert naming image, finding, and affected containers.

Allowing an image: `config.toml` `scan_allow = ["<image-id>"]` (applied at daemon start);
a menubar action is a follow-up. Kill switch: `scan_block = "off"`; `scan = false` disables
scanning.

Containers from `container` CLI are never touched (FR-28).

## Rescans

Advisories change after the pull. Every image is rescanned once its report is a day old
(checked hourly), so an image that becomes serious later is caught. Rescanning stored SBOMs
without re-exporting is a possible optimization.

## Follow-ups

- spotter: v0.1.0 scans only documents and archives (PDF, Office, ZIP), so on an image it
  sees `.jar`s but not ELF binaries. Needed: an all-files, hash-only mode (MalwareBazaar)
  and a documented JSON schema. Also, its `.gitignore` entry `spotter` hides `cmd/spotter/`,
  so the CLI source is not in the repository and `go install` fails.
- EPSS for warnings; Artifact Hub enrichment; syft SBOMs in CycloneDX/SPDX (today the BOM
  is osv-scanner's package list).
- Menubar action to allow a blocked image.

## Not in scope yet

Build-time scanning (no `docker build` yet), registry-side policies, signing/provenance
(cosign, SLSA) — candidates for later.
