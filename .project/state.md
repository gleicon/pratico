# settled

- No paid Apple Developer Program account (2026-11-08). Ad-hoc signing only; Developer ID signing + notarization are optional `make dmg` paths used only when an identity is configured. See `SPEC.md` D-10.
- No restricted entitlements (e.g. `com.apple.vm.networking`): macOS kills binaries carrying them without a provisioning profile, and user approval cannot override that. Networking must work without them. See `SPEC.md` D-11.
- Users approve downloaded builds through Gatekeeper ("Open Anyway" or `xattr -dr com.apple.quarantine`); the app cannot prompt for this itself because Gatekeeper blocks before any code runs. A helper script inside the DMG does not help: it is quarantined too.
- v0.1.0 is built via Makefiles and shipped as a `.dmg` (`SPEC.md` D-9).

- No pratico CLI (SPEC D-12). Pratico is a Mac app: menubar item, config window, listeners. `docker` and Apple `container` are the CLIs. Daemon control lives in the menubar.
- Listeners run in `pratico-daemon`, a background helper bundled in `Pratico.app` and registered via `SMAppService` (SPEC D-13).

# hazards

- Unverified whether Apple `Containerization` networking on macOS 26 needs `com.apple.vm.networking`. Check at the first networking task (roadmap: default `bridge` network). If it does, networking must route through the Apple-signed `container` runtime or another unrestricted path.
- Daemon backend shells out to the `container` CLI (`AppleContainer.swift`). Each running container is supervised by a `container start --attach` child: the Apple runtime reports no exit codes, but that process exits with the container's code and carries separate stdout/stderr.
- After a daemon restart, containers still running have no supervisor; a poller marks them exited with exit code 0 (real code unknown). Fixing it needs a runtime source of exit codes.
- `container start --attach` refuses already-running containers, and `container stop` during VM boot is a no-op. `start` therefore blocks until the runtime reports `running` (30 s bound); keep that or restart races return.
- `START.md` and `ROADMAP.md` (top-level) still describe `pratico system ...` commands; superseded by SPEC D-12.
- Never leave an Apple container frozen without the daemon's pause agent (D-15). `container stop`, `kill`, and `rm -f` all hang on a frozen VM. The only recovery found is killing its `container-runtime-linux` process. Pause does not survive a daemon restart, unlike Docker: the container thaws instead.
