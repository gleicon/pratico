import Foundation
import Testing

@testable import PraticoDaemonKit

private func host(_ edit: (inout HostInstall.Host) -> Void = { _ in }) -> HostInstall.Host {
    var h = HostInstall.Host(isRoot: true, machine: "aarch64", hasSystemd: true, kvmGroup: "kvm", kvmGroupWritable: true,
                             apparmor: true, dockerSocket: .absent, hasDockerCLI: true, sudoUser: "ana", source: "/home/ana/pratico-0.3.0-linux-arm64")
    edit(&h)
    return h
}

@Test func installRefusesHostsPraticoCannotServe() {
    #expect(throws: Never.self) { try HostInstall.check(host()) }
    for (edit, says) in [
        ({ (h: inout HostInstall.Host) in h.isRoot = false }, "as root"),
        ({ $0.machine = "x86_64" }, "x86_64"),
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
    #expect(plain.notes.contains { $0.contains("docker CLI") })
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
