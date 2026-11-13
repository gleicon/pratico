# settled

- No paid Apple Developer Program account (2026-11-08). Ad-hoc signing only; Developer ID signing + notarization are optional `make dmg` paths used only when an identity is configured. See `SPEC.md` D-10.
- No restricted entitlements (e.g. `com.apple.vm.networking`): macOS kills binaries carrying them without a provisioning profile, and user approval cannot override that. Networking must work without them. See `SPEC.md` D-11.
- Users approve downloaded builds through Gatekeeper ("Open Anyway" or `xattr -dr com.apple.quarantine`); the app cannot prompt for this itself because Gatekeeper blocks before any code runs. A helper script inside the DMG does not help: it is quarantined too.
- v0.1.0 is built via Makefiles and shipped as a `.dmg` (`SPEC.md` D-9).
- No pratico CLI (SPEC D-12). Pratico is a Mac app: menubar item, config window, listeners. `docker` is the CLI. Daemon control lives in the menubar.
- Listeners run in `pratico-daemon`, a background helper bundled in `Pratico.app` and started by a launch agent the menubar writes to `~/Library/LaunchAgents` (SPEC D-13).
- Users must not need Apple's `container` installed (2026-11-09). The embedded runtime (SPEC D-26, `docs/design/runtime.md`) replaced the CLI backend, removed 2026-11-12; limitations of the CLI are bugs to remove, not documented behavior.
- Behave like Docker by default and go beyond it where that helps (agents especially); never ship a weaker approximation because an acceptance criterion is literally met.
- Embedded networking is pure Swift with no extra binaries (SPEC D-27). Kernel and `vminit` are bundled, not downloaded by users.
- pratico runs no shell and no external program (2026-11-12): native Swift and system APIs only (tar through ContainerizationArchive, daemon start by `posix_spawn` of its own binary, stop by SIGTERM). Spawning pratico's own binaries (`pratico-daemon`, `pratico-shim`) is fine. Scanners are the exception: external tools by design (SPEC D-24), checked by the menubar's Scanners menu.
- Every removal the user can trigger asks first (cleanup, logins, alerts).

# hazards

- `pratico-shim` needs `com.apple.security.virtualization`. A plain `swift build` drops it; use `make build`, which re-signs. Symptom: `exit.json` says the process lacks the entitlement, exit 127.
- Shim sockets live in `<home>/run/<short id>.sock`; anything under `containers/<64-hex id>/` exceeds the 104-byte Unix socket limit.
- `blocking { }` (ImageBackend.swift) waits on a semaphore; call it only from the daemon's connection threads or plain threads, never from a Swift concurrency context.
- Swift `case A, B where cond:` applies `where` to `B` only. A route written that way matched `A` unconditionally and sent no response, hanging `docker cp`.
- `make probe` and an embedded daemon without `--home` use `~/.pratico`, which the installed app also uses. Test with a temporary `--home`.
- Virtualization.framework allows 4 network devices per VM (`VZErrorDomain Code=2 "The number of network devices is greater than the maximum number supported"`); `ShimNIC.slots` is 4 for that reason.
- `spec.json`'s `nics` is a `NICSlots` object (`slots`, `primary`). `NICSlots.init(from:)` still reads the older plain array, and its per-NIC `primary` flag, for VMs started by an older daemon; keep it while such VMs may still run.
- The shim's `GuestAddresses`, not the daemon, records which addresses a guest slot holds: the shim outlives daemon restarts, and vminitd's `addressAdd` (netlink `NLM_F_EXCL`) fails on a duplicate without an errno the daemon can see.
- vminitd has no address or route delete RPC: a hot-disconnected slot keeps its address on a down link. The switch, not the guest, is what cuts traffic; keep every delivery path behind its port registry (`NetSwitch.deliver`).
- `SSL_CERT_FILE` replaces the daemon registry client's trust roots (Docker Hub stops verifying). macOS rejects a self-signed CA cert used directly as a TLS server cert; test registries need a CA plus a leaf.
- Never run pratico code as root from `Pratico.app`: the bundle is the user's (drag install), `/Applications` is group-writable by `admin`, and ad-hoc signing gives launchd nothing to verify, so a root job with `BundleProgram` is a user-to-root escalation. For `/var/run/docker.sock` (D-30) pratico only shows `sudo` commands; the user runs them (2026-11-12: keep it simple, no admin prompt from the app).
- The daemon refuses to start while another answers on its socket (`DaemonError.alreadyServing`, no `daemon.err` written); it used to unlink the socket and take over. The menubar spawns it (own session, reaped by `waitpid`), and launchd starts it at login from `~/Library/LaunchAgents/dev.pratico.daemon.plist`.
- Do not go back to `SMAppService` for the daemon while builds are ad-hoc signed: its Background Task Management record pins the daemon's code signature, and after a rebuild, a move, or an update launchd refuses it (`OS_REASON_CODESIGNING | Launch Constraint Violation`, job `spawn failed`, `needs LWCR update`). The menubar just showed "starting…" forever. `LaunchAgent.start()` still unregisters an old SMAppService registration of the same label.
- `bash` reads scripts while running: never edit `e2e/*.sh` during a run.
