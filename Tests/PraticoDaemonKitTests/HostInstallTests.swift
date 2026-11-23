import Foundation
import Testing

@testable import PraticoDaemonKit

private func host(_ edit: (inout HostInstall.Host) -> Void = { _ in }) -> HostInstall.Host {
    var h = HostInstall.Host(isRoot: true, machine: HostInstall.buildMachine, hasSystemd: true, kvmGroup: "kvm", kvmGroupWritable: true,
                             apparmor: true, dockerSocket: .absent, hasDockerCLI: true, sudoUser: "ana", source: "/home/ana/pratico-0.3.0-linux-arm64")
    edit(&h)
    return h
}

@Test func installRefusesHostsPraticoCannotServe() {
    #expect(throws: Never.self) { try HostInstall.check(host()) }
    for (edit, says) in [
        ({ (h: inout HostInstall.Host) in h.isRoot = false }, "as root"),
        ({ $0.machine = "riscv64" }, "riscv64"),
        ({ $0.hasSystemd = false }, "systemd"),
        ({ $0.kvmGroup = nil }, "/dev/kvm"),
        ({ $0.kvmGroupWritable = false }, "not open to its group"),
        ({ $0.kvmGroup = "root" }, "not open to its group"),
        ({ $0.source = HostInstall.prefix }, "extracted release"),
    ] as [((inout HostInstall.Host) -> Void, String)] {
        do {
            try HostInstall.check(host(edit))
            Issue.record("accepted a host that \(says)")
        } catch {
            #expect("\(error)".contains(says))
        }
    }
}

@Test func installPlanLinksTheDockerSocketOnlyWhenItIsFree() {
    let free = HostInstall.plan(host())
    #expect(free.files.first { $0.path.hasSuffix("tmpfiles.d/pratico.conf") }?.contents.contains("L /run/docker.sock - - - - /run/pratico/docker.sock") == true)
    #expect(!free.notes.contains { $0.contains("another engine") })

    let taken = HostInstall.plan(host { $0.dockerSocket = .other })
    #expect(taken.files.first { $0.path.hasSuffix("tmpfiles.d/pratico.conf") }?.contents.contains("/run/docker.sock") == false)
    #expect(taken.notes.contains { $0.contains("another engine") })
}

@Test func installPlanFollowsTheHost() {
    let p = HostInstall.plan(host())
    #expect(p.files.map(\.path).contains("/etc/apparmor.d/pratico-shim"))
    #expect(p.commands.contains(["apparmor_parser", "--replace", "/etc/apparmor.d/pratico-shim"]))
    #expect(p.files.first { $0.path == "/etc/sysusers.d/pratico-members.conf" }?.contents.contains("m ana pratico") == true)
    #expect(p.commands.last == ["systemctl", "restart", "pratico.service"])

    let plain = HostInstall.plan(host { $0.apparmor = false; $0.sudoUser = nil; $0.kvmGroup = "hypervisor"; $0.hasDockerCLI = false })
    #expect(!plain.files.map(\.path).contains("/etc/apparmor.d/pratico-shim"))
    #expect(!plain.commands.contains { $0.first == "apparmor_parser" })
    #expect(!plain.files.map(\.path).contains("/etc/sysusers.d/pratico-members.conf"))
    #expect(plain.files.first { $0.path.hasSuffix("sysusers.d/pratico.conf") }?.contents.contains("m pratico hypervisor") == true)
    // No docker on the host: pratico's own answers `docker system dial-stdio`.
    #expect(plain.links.map(\.path) == ["/usr/local/bin/docker"] && plain.links.first?.target == "/usr/lib/pratico/pratico-daemon")
    let withDocker = HostInstall.plan(host { $0.hasDockerCLI = true })
    #expect(withDocker.links.isEmpty)
    #expect(withDocker.notes.contains { $0.contains("docker CLI is already installed") })
}

@Test func installedUnitRunsUnprivilegedWithOnlyWhatVMsNeed() {
    let unit = HostInstall.unitFile()
    for line in ["User=pratico", "ExecStart=/usr/lib/pratico/pratico-daemon --home /var/lib/pratico --socket /run/pratico/docker.sock",
                 "KillMode=process", "NoNewPrivileges=yes", "RestrictNamespaces=user net mnt pid", "DevicePolicy=closed",
                 "DeviceAllow=/dev/kvm rw", "DeviceAllow=/dev/net/tun rw", "StateDirectoryMode=0700"] {
        #expect(unit.contains(line + "\n"), "unit lacks \(line)")
    }
    #expect(!unit.contains("AmbientCapabilities"))
    // Each mounts over part of /proc, and virtiofsd's sandbox then cannot mount its own.
    for overmount in ["ProtectKernelTunables=", "ProtectKernelLogs=", "ProtectHostname="] {
        #expect(!unit.contains("\n" + overmount), "unit sets \(overmount)")
    }
}

@Test func uninstallKeepsImagesAndVolumesUnlessPurged() {
    #expect(!HostInstall.removals(host: host(), purge: false).contains(HostInstall.home))
    #expect(HostInstall.removals(host: host(), purge: true).contains(HostInstall.home))
    #expect(!HostInstall.removals(host: host(), purge: false).contains(HostInstall.dockerSocket))
    #expect(HostInstall.removals(host: host { $0.dockerSocket = .pratico }, purge: false).contains(HostInstall.dockerSocket))
}

#if os(Linux)
/// Ubuntu's own parser accepts the profile (scripts/linux-check.sh installs it). Parsed only,
/// not loaded: the test host's kernel has no AppArmor (docs/linux-hosts.md).
@Test func shimAppArmorProfileParses() throws {
    let parser = "/usr/sbin/apparmor_parser"
    #expect(FileManager.default.isExecutableFile(atPath: parser), "apparmor_parser missing")
    let file = FileManager.default.temporaryDirectory.appending(path: "pratico-shim-\(getpid())")
    try Data(HostInstall.apparmorFile().utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let p = Process()
    p.executableURL = URL(filePath: parser)
    p.arguments = ["--skip-kernel-load", "--skip-cache", "--preprocess", file.path]
    p.standardOutput = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    #expect(p.terminationStatus == 0)
}
#endif

private func hardening(_ edit: (inout HostHardening.State) -> Void = { _ in }) -> HostHardening.State {
    var h = HostHardening.State(sshPorts: [22], otherListeners: [], missingPackages: [], ufwActive: false)
    edit(&h)
    return h
}

@Test func hardeningIsOptInAndTouchesNothingWithNoHarden() {
    let plain = HostInstall.plan(host())
    #expect(!plain.files.map(\.path).contains("/etc/sysctl.d/90-pratico-hardening.conf"))
    #expect(!plain.commands.contains { $0.first == "ufw" || $0.first == "sysctl" })
    let hardened = HostInstall.plan(host(), hardening: hardening())
    #expect(hardened.files.map(\.path).contains("/etc/sysctl.d/90-pratico-hardening.conf"))
    #expect(hardened.commands.contains(["sysctl", "--system"]))
    #expect(hardened.commands.contains(["systemctl", "enable", "--now", "fail2ban.service"]))
}

@Test func hardeningSysctlsOnlyTighten() {
    let s = HostHardening.sysctlFileContents()
    for line in ["kernel.kptr_restrict = 2", "kernel.unprivileged_bpf_disabled = 1", "net.core.bpf_jit_harden = 2", "kernel.kexec_load_disabled = 1"] {
        #expect(s.contains(line + "\n"))
    }
    // Ubuntu's perf_event_paranoid is 4, stricter than upstream's 3: never set lower.
    #expect(!s.contains("\nkernel.perf_event_paranoid"))
    // User namespaces stay: each VM's network needs one (the shim's AppArmor profile allows it).
    #expect(!s.contains("userns"))
}

@Test func firewallNeverCutsOffAServiceItDoesNotKnow() {
    let web = HostHardening.State.Listener(proto: "tcp", port: 443, program: "nginx")
    let cut = HostInstall.plan(host(), hardening: hardening { $0.otherListeners = [web] })
    #expect(!cut.commands.contains { $0.first == "ufw" })
    #expect(cut.notes.contains { $0.contains("443/tcp (nginx)") && $0.contains("--allow-port") })
    #expect(!cut.files.map(\.path).contains("/etc/pratico/firewall-enabled-by-pratico"))

    let allowed = HostInstall.plan(host(), hardening: hardening { $0.otherListeners = [web]; $0.sshPorts = [22, 2222] }, allow: [443])
    #expect(allowed.commands.contains(["ufw", "allow", "22/tcp"]) && allowed.commands.contains(["ufw", "allow", "2222/tcp"]))
    #expect(!allowed.commands.contains { $0.first == "ufw" && $0.dropFirst().first == "limit" })  // docker over ssh opens many connections
    #expect(allowed.commands.contains(["ufw", "allow", "443"]))
    #expect(allowed.commands.last == ["ufw", "--force", "enable"])
    #expect(allowed.files.map(\.path).contains("/etc/pratico/firewall-enabled-by-pratico"))

    let admins = HostInstall.plan(host(), hardening: hardening { $0.ufwActive = true })
    #expect(!admins.commands.contains { $0.first == "ufw" })
}

@Test func hardeningInstallsOnlyMissingPackages() {
    #expect(!HostInstall.plan(host(), hardening: hardening()).commands.contains { $0.first == "apt-get" })
    let p = HostInstall.plan(host(), hardening: hardening { $0.missingPackages = ["fail2ban"] })
    #expect(p.commands.contains(["apt-get", "-q", "install", "-y", "--no-install-recommends", "fail2ban"]))
}
