# Image scanning — design

Status: draft for review. Backlog item "Automatic image scanning".

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

- **serious**: any `MAL-*` advisory; any malware hit from spotter/ClamAV; any CVE in CISA
  KEV; any CVE rated Critical (CVSS ≥ 9.0).
- **warning**: High severity, or EPSS ≥ 0.1.
- **ok**: nothing above. **unknown**: no scanner ran.

## Storage

`~/.pratico/scans/<image-id>.json`: verdict, findings (id, package, version, fixed
version, severity, source), scanner versions, database dates, time. Scans are keyed by
image ID, so a re-tag reuses the result; a new digest gets a new scan. Excluded from Time
Machine like the rest of the store. No credentials are involved.

## Enforcement (needs sign-off)

On a **serious** verdict:

1. Stop running Docker containers created from that image ID (`docker stop` semantics,
   10 s grace), emitting a pratico event.
2. Refuse to start containers from it (`409`, message names the finding), until the user
   allows the image.
3. Warn: menubar alert naming image, finding, and affected containers.

Allowing an image: a menubar action, or `config.toml` `scan_allow = ["<image-id>"]`.
Kill switch: `scan_enforce = false` (scan and warn only).

Containers from `container` CLI are never touched (FR-28).

## Rescans

Advisories change after the pull. Rescan stored SBOMs daily (cheap: no re-export), so an
image that becomes serious later is caught.

## Not in scope yet

Build-time scanning (no `docker build` yet), registry-side policies, signing/provenance
(cosign, SLSA) — candidates for later.
